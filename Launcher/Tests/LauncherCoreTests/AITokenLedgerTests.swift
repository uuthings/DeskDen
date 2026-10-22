import Foundation
import XCTest
@testable import LauncherCore

final class AITokenLedgerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_600_000)
    private func record(_ id: String, provider: AIProvider = .codex, seconds: Double = 0, input: Int64 = 10, output: Int64 = 3) -> AITokenRecord {
        .init(id: id, provider: provider, timestamp: now.addingTimeInterval(seconds), model: "test-model", tokens: .init(input: input, output: output))
    }

    func testNewStoreDoesNotWriteAnEmptyFileBeforeIngestion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AITokenLedgerStore(url: folder.appendingPathComponent("tokens.json"))
        XCTAssertTrue(try store.load(now: now).records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testDeduplicationKeepsProviderIdentityAndMaximumObservedCounters() throws {
        var ledger = AITokenLedger(now: now)
        try ledger.ingest([record("same", input: 10), record("same", provider: .claude, input: 20)], at: now)
        try ledger.ingest([record("same", input: 15), record("other", seconds: -10)], at: now)
        XCTAssertEqual(ledger.records.count, 3)
        XCTAssertEqual(ledger.records.first { $0.id == "same" && $0.provider == .codex }?.tokens.input, 15)
        XCTAssertEqual(ledger.records.first { $0.id == "same" && $0.provider == .claude }?.tokens.input, 20)
    }

    func testDisabledProviderIsExcludedFromCurrentTotalsButRetainedInHistory() throws {
        var ledger = AITokenLedger(now: now)
        try ledger.ingest([record("c"), record("a", provider: .claude)], at: now)
        let current = ledger.records(period: .today, enabledProviders: [.claude], now: now)
        XCTAssertEqual(current.map(\.provider), [.claude])
        XCTAssertEqual(ledger.records(period: .today, now: now).count, 2)
        try ledger.ingest([], at: now.addingTimeInterval(60))
        XCTAssertEqual(ledger.records.count, 2)
    }

    func testRetentionAndFutureSkewAreBoundedWithoutInventingRecords() throws {
        var ledger = AITokenLedger(now: now)
        let days = Double(AITokenLedger.retentionDays) * 86_400
        try ledger.ingest([record("old", seconds: -days - 1), record("edge", seconds: -days), record("future", seconds: 301), record("skew", seconds: 60)], at: now)
        XCTAssertEqual(Set(ledger.records.map(\.id)), ["edge", "skew"])
        XCTAssertTrue(ledger.records(period: .today, now: now).isEmpty)
        XCTAssertEqual(ledger.records(period: .today, now: now.addingTimeInterval(60)).map(\.id), ["skew"])
    }

    func testCapacityKeepsMostRecentRecordsAndReportsIncompleteHistory() throws {
        var ledger = AITokenLedger(now: now)
        try ledger.ingest((0..<6).map { record(String($0), seconds: Double($0 - 6)) }, at: now, maximumRecords: 3)
        XCTAssertEqual(ledger.records.map(\.id), ["3", "4", "5"])
        XCTAssertTrue(ledger.capacityLimited)
    }

    func testInvalidMetadataAndCountersLeaveThePreviousLedgerIntact() throws {
        var ledger = AITokenLedger(now: now)
        try ledger.ingest([record("good")], at: now)
        let original = ledger
        var negative = record("negative"); negative.tokens.input = -1
        var nonfinite = record("date"); nonfinite.timestamp = Date(timeIntervalSince1970: .infinity)
        var blank = record("blank"); blank.model = " "
        for invalid in [negative, nonfinite, blank, record("line\ncontent"), record(String(repeating: "x", count: 513))] {
            XCTAssertThrowsError(try ledger.ingest([invalid], at: now))
            XCTAssertEqual(ledger, original)
        }
    }

    func testOverflowAcrossValidRecordsCannotCrashAggregateViews() throws {
        var ledger = AITokenLedger(now: now)
        try ledger.ingest([record("maximum", input: .max, output: 0)], at: now)
        let previous = ledger
        XCTAssertThrowsError(try ledger.ingest([record("extra", input: 1, output: 0)], at: now))
        XCTAssertEqual(ledger, previous)
        // Maximum merging of two individually valid copies must also be checked.
        XCTAssertThrowsError(try ledger.ingest([record("maximum", input: 0, output: 1)], at: now))
        XCTAssertEqual(ledger, previous)
    }

    func testMetadataArchiveSurvivesRestartAndUsesPrivatePermissions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AITokenLedgerStore(url: folder.appendingPathComponent("tokens.json"))
        var ledger = AITokenLedger(now: now)
        try ledger.ingest([record("one")], at: now); try store.save(ledger)
        let previous = try Data(contentsOf: store.url)
        try ledger.ingest([record("two")], at: now); try store.save(ledger)
        XCTAssertEqual(try AITokenLedgerStore(url: store.url).load(), ledger)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), previous)
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testEncodedArchiveContainsOnlyUsageMetadata() throws {
        var ledger = AITokenLedger(now: now)
        try ledger.ingest([record("one")], at: now)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        let rows = try XCTUnwrap(object["records"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(rows.first).keys), ["id", "provider", "timestamp", "model", "tokens"])
        for forbidden in ["prompt", "response", "conversation", "path", "credential", "account", "message"] {
            XCTAssertNil(rows.first?[forbidden])
        }
    }

    func testCorruptFutureAndDuplicateArchivesArePreservedInsteadOfOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AITokenLedgerStore(url: folder.appendingPathComponent("tokens.json"))
        var ledger = AITokenLedger(now: now)
        try ledger.ingest([record("one")], at: now)
        var future = ledger; future.schemaVersion = 2
        var duplicate = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        let rows = try XCTUnwrap(duplicate["records"] as? [[String: Any]])
        duplicate["records"] = rows + rows
        for bytes in [Data("{broken".utf8), try JSONEncoder().encode(future), try JSONSerialization.data(withJSONObject: duplicate)] {
            try bytes.write(to: store.url)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(.init(now: now)))
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        }
    }

    func testSymbolicLinkArchiveCannotRedirectReadsOrWrites() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("target.json")
        let bytes = try JSONEncoder().encode(AITokenLedger(now: now)); try bytes.write(to: target)
        let link = folder.appendingPathComponent("tokens.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = AITokenLedgerStore(url: link)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(.init(now: now)))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testCoverageUsesActualProviderRecordsAndSourceState() {
        let coverage = AIUsageSourceCoverage(provider: .codex, scannedAt: now, enabled: false, sourceAvailable: false, scannedFiles: 0, skippedFiles: 0, records: [record("one", seconds: -10), record("two"), record("other", provider: .claude)])
        XCTAssertFalse(coverage.enabled)
        XCTAssertFalse(coverage.sourceAvailable)
        XCTAssertEqual(coverage.scannedFiles, 0)
        XCTAssertEqual(coverage.parsedRecords, 2)
        XCTAssertEqual(coverage.firstRecordAt, now.addingTimeInterval(-10))
        XCTAssertEqual(coverage.lastRecordAt, now)
    }
}
