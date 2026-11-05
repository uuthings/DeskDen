import XCTest
import Darwin
@testable import LauncherCore

final class SpaceCleaningHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var snapshot: URL { directory.appendingPathComponent("history.json") }
    private var journal: URL { directory.appendingPathComponent("history.journal") }
    private var archive: URL { directory.appendingPathComponent("history-archive.jsonl") }

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceCleaningHistory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = try XCTUnwrap(SpaceCleaningScanner.canonicalURL(root))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func record(_ state: SpaceCleaningRecordState, batch: UUID = UUID(), at date: Date = Date()) -> SpaceCleaningRecord {
        let identity = SpaceCleaningFileIdentity(device: 1, inode: UInt64.random(in: 1...1_000_000_000), sizeBytes: 8, allocatedBytes: 4_096,
                                                 modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0,
                                                 linkCount: 1, mode: 0o100644)
        let root = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)
        let name = UUID().uuidString + ".data"
        let candidate = SpaceCleaningCandidate(url: root.appendingPathComponent(name, isDirectory: false), rootURL: root,
                                               rootIdentity: identity, identity: identity, kind: .downloadedFile, group: .review,
                                               title: name, reason: "r", impact: "i", logicalBytes: 8, allocatedBytes: 4_096, isDirectory: false)
        var value = SpaceCleaningRecord(operationID: batch, candidate: candidate, method: .trash, at: date)
        value.state = state
        value.proof = .init(sha256: String(repeating: "a", count: 64), entryCount: 1, logicalBytes: 8, rootIdentity: identity)
        value.locationURL = URL(fileURLWithPath: "/Users/test/.Trash/" + name, isDirectory: false)
        if state == .restored { value.restoredURL = candidate.url }
        return value
    }
    private func lines(_ url: URL) throws -> [Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Data(contentsOf: url).split(separator: 0x0A).map { Data($0) }
    }
    private func appendRaw(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); try handle.close()
    }

    func testEachPersistAppendsOneLineAndCompactionFoldsTheJournalIntoTheSnapshot() throws {
        var limits = SpaceCleaningHistoryStore.Limits.production
        limits.compactionBytes = 8_192
        let store = try SpaceCleaningHistoryStore(fileURL: snapshot, limits: limits)
        var first = record(.prepared)
        try store.record(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertEqual(try lines(journal).count, 1)
        first.state = .skipped; first.explanation = "skipped"; first.updatedAt = Date()
        try store.record(first)
        XCTAssertEqual(try lines(journal).count, 2)
        XCTAssertEqual(try SpaceCleaningHistoryStore(fileURL: snapshot).records, [first])

        var written: Set<UUID> = [first.id]
        while !FileManager.default.fileExists(atPath: snapshot.path) {
            let next = record(.skipped); try store.record(next); written.insert(next.id)
        }
        XCTAssertTrue(try lines(journal).isEmpty)
        let folded = try JSONDecoder().decode([SpaceCleaningRecord].self, from: Data(contentsOf: snapshot))
        XCTAssertEqual(Set(folded.map(\.id)), written)
        let more = record(.skipped); try store.record(more); written.insert(more.id)
        XCTAssertEqual(try lines(journal).count, 1)
        XCTAssertEqual(Set(try SpaceCleaningHistoryStore(fileURL: snapshot).records.map(\.id)), written)
    }

    func testTornJournalTailIsIgnoredAndTrimmedByTheNextWrite() throws {
        let store = try SpaceCleaningHistoryStore(fileURL: snapshot)
        let kept = record(.skipped)
        try store.record(kept)
        try appendRaw(#"{"schema":1,"id":"#, to: journal)
        // The original store sees a file it did not write and stops.
        XCTAssertThrowsError(try store.record(record(.skipped)))
        let reopened = try SpaceCleaningHistoryStore(fileURL: snapshot)
        XCTAssertEqual(reopened.records, [kept])
        let added = record(.skipped)
        try reopened.record(added)
        XCTAssertEqual(try lines(journal).count, 2)
        XCTAssertEqual(Set(try SpaceCleaningHistoryStore(fileURL: snapshot).records.map(\.id)), [kept.id, added.id])
    }

    func testCorruptJournalLineBlocksLoadingAndIsRetained() throws {
        let store = try SpaceCleaningHistoryStore(fileURL: snapshot)
        try store.record(record(.skipped))
        try appendRaw("not-a-record\n", to: journal)
        let bytes = try Data(contentsOf: journal)
        XCTAssertThrowsError(try SpaceCleaningHistoryStore(fileURL: snapshot))
        XCTAssertThrowsError(try store.record(record(.skipped)))
        XCTAssertEqual(try Data(contentsOf: journal), bytes)
    }

    func testSnapshotRewrittenByAnEarlierReleaseMergesByUpdateTime() throws {
        let store = try SpaceCleaningHistoryStore(fileURL: snapshot)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let restoredLater = record(.trashed, at: start), trashedLater = record(.trashed, at: start)
        try store.record(restoredLater)
        try store.record(trashedLater)
        // An earlier release reads only the snapshot and rewrites it: one state is
        // newer than the journal, the other is stale.
        var newer = restoredLater
        newer.state = .restored; newer.restoredURL = newer.originalURL; newer.updatedAt = start.addingTimeInterval(60)
        var stale = trashedLater
        stale.state = .prepared; stale.updatedAt = start.addingTimeInterval(-60)
        try JSONEncoder().encode([newer, stale]).write(to: snapshot)
        let merged = try SpaceCleaningHistoryStore(fileURL: snapshot).records
        XCTAssertEqual(merged.first { $0.id == restoredLater.id }?.state, .restored)
        XCTAssertEqual(merged.first { $0.id == trashedLater.id }?.state, .trashed)
    }

    func testFinishedBatchesMoveToTheArchiveInsteadOfBlockingNewWork() throws {
        var limits = SpaceCleaningHistoryStore.Limits.production
        limits.liveRecords = 6; limits.archiveTarget = 3
        let store = try SpaceCleaningHistoryStore(fileURL: snapshot, limits: limits)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let oldBatch = UUID(), recentBatch = UUID()
        let finishedOld = (0..<3).map { record(.skipped, batch: oldBatch, at: base.addingTimeInterval(Double($0))) }
        let recoverable = record(.trashed, at: base.addingTimeInterval(-100))
        let finishedRecent = (0..<2).map { record(.deleted, batch: recentBatch, at: base.addingTimeInterval(100 + Double($0))) }
        for item in finishedOld + [recoverable] + finishedRecent { try store.record(item) }
        let newest = record(.prepared, at: base.addingTimeInterval(200))
        try store.record(newest)

        let live = Set(store.records.map(\.id))
        XCTAssertTrue(live.isDisjoint(with: finishedOld.map(\.id)))
        XCTAssertTrue(live.isSuperset(of: [recoverable.id, newest.id] + finishedRecent.map(\.id)))
        XCTAssertEqual(Set(try SpaceCleaningHistoryStore(fileURL: snapshot, limits: limits).records.map(\.id)), live)
        let archived = try lines(archive).map { try JSONDecoder().decode(SpaceCleaningRecord.self, from: $0).id }
        XCTAssertEqual(Set(archived), Set(finishedOld.map(\.id)))
    }

    func testRecoverableRecordsAreNeverArchivedAndTheLimitIsExplained() throws {
        var limits = SpaceCleaningHistoryStore.Limits.production
        limits.liveRecords = 2; limits.archiveTarget = 1
        let store = try SpaceCleaningHistoryStore(fileURL: snapshot, limits: limits)
        var trashed = record(.trashed)
        try store.record(trashed)
        try store.record(record(.needsReview))
        XCTAssertThrowsError(try store.record(record(.prepared))) { error in
            XCTAssertTrue(error.localizedDescription.contains("可恢复或待核对"), error.localizedDescription)
        }
        // Updating an existing record never needs new capacity.
        trashed.state = .restored; trashed.restoredURL = trashed.originalURL; trashed.updatedAt = Date()
        XCTAssertNoThrow(try store.record(trashed))
        XCTAssertEqual(store.records.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }
}
