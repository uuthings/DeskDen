import XCTest
import Darwin
@testable import LauncherCore

private struct SpaceCleaningFixtureMover: SpaceCleaningFileOperating {
    var directory: URL
    var before: (@Sendable (URL) throws -> Void)?
    var after: (@Sendable (URL) throws -> Void)?
    func moveToTrash(_ source: URL) throws -> URL {
        try before?(source)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: destination)
        try after?(destination)
        return destination
    }
}

final class SpaceCleaningTransactionTests: XCTestCase {
    private struct Fixture {
        var home: URL
        var root: URL
        var item: URL
        var trash: URL
        var context: SpaceCleaningContext
        var candidate: SpaceCleaningCandidate
        var mover: SpaceCleaningFixtureMover { .init(directory: trash) }
        func policy(_ candidate: SpaceCleaningCandidate) -> String? {
            let result = SpaceCleaningScanner.revalidate(candidate: candidate, context: context)
            return result == .unchanged ? nil : "重新核验：" + result.rawValue
        }
    }
    private func fixture(directory: Bool = false, app: Bool = false, nested: Bool = false, run: (Fixture) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Fangcun-SpaceTransaction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let home = try XCTUnwrap(SpaceCleaningScanner.canonicalURL(temporary))
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(directory ? ".npm/_cacache" : "selected"), trash = home.appendingPathComponent("fake-trash")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let item = root.appendingPathComponent((nested ? "nested/" : "") + (app ? "Sample.app" : directory ? "cache-folder" : "selected.data"))
        try FileManager.default.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
        if directory || app {
            try FileManager.default.createDirectory(at: item.appendingPathComponent("Contents/nested"), withIntermediateDirectories: true)
            try Data("selected-A".utf8).write(to: item.appendingPathComponent("Contents/a.data"))
            try Data("selected-B".utf8).write(to: item.appendingPathComponent("Contents/nested/b.data"))
        } else { try Data("selected-A".utf8).write(to: item) }
        var context = SpaceCleaningContext(homeDirectory: home)
        let scope = SpaceCleaningScope(directory: root, kind: directory ? .packageCache : .custom)
        var report = SpaceCleaningScanner.scan(scopes: [scope], context: context)
        var candidate = try XCTUnwrap(report.candidates.first { $0.url.path == SpaceCleaningScanner.canonicalURL(item)?.path }, "\(report.issues)")
        if app {
            context.testDeclarations = [.init(candidate: candidate)]
            report = SpaceCleaningScanner.scan(scopes: [scope], context: context)
            candidate = try XCTUnwrap(report.candidates.first { $0.url.path == SpaceCleaningScanner.canonicalURL(item)?.path })
        }
        try run(.init(home: home, root: candidate.rootURL, item: candidate.url, trash: try XCTUnwrap(SpaceCleaningScanner.canonicalURL(trash)), context: context, candidate: candidate))
    }
    private func clean(_ value: Fixture, method: SpaceCleaningMethod = .trash, confirmed: Bool = false,
                       persist: (SpaceCleaningRecord) throws -> Void = { _ in }) -> SpaceCleaningRecord {
        SpaceCleaningTransaction.execute(candidate: value.candidate, operationID: UUID(), method: method,
                                         permanentConfirmed: confirmed, mover: value.mover,
                                         validatePolicy: value.policy, persist: persist)
    }
    func testTrashPersistsBeforeMutationAndRestoresCompleteFile() throws {
        try fixture { fixture in
            var events: [SpaceCleaningRecordState] = []
            let moved = clean(fixture) { record in
                if events.isEmpty { XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.item.path)); XCTAssertEqual(record.state, .prepared) }
                events.append(record.state)
            }
            XCTAssertEqual(moved.state, .trashed, moved.explanation)
            XCTAssertTrue(moved.canRestore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.item.path))
            XCTAssertEqual(events, [.prepared, .isolated, .isolated, .trashed])
            let restored = SpaceCleaningTransaction.restore(record: moved, conflict: .skip, persist: { _ in })
            XCTAssertEqual(restored.state, .restored, restored.explanation)
            XCTAssertEqual(try String(contentsOf: fixture.item, encoding: .utf8), "selected-A")
            XCTAssertFalse(restored.canRestore)
        }
    }
    func testWholeDirectoryAndDeclaredTestApplicationMoveAndRestoreWithoutSplitting() throws {
        for app in [false, true] {
            try fixture(directory: true, app: app) { fixture in
                XCTAssertTrue(fixture.candidate.canProcess)
                let moved = clean(fixture)
                XCTAssertEqual(moved.state, .trashed, moved.explanation)
                XCTAssertEqual(moved.proof?.entryCount, 5)
                let restored = SpaceCleaningTransaction.restore(record: moved, conflict: .skip, persist: { _ in })
                XCTAssertEqual(restored.state, .restored, restored.explanation)
                XCTAssertEqual(try String(contentsOf: fixture.item.appendingPathComponent("Contents/nested/b.data"), encoding: .utf8), "selected-B")
            }
        }
    }
    func testPermanentRequiresSeparateConfirmationAndRemovesOnlySelectedTree() throws {
        try fixture(directory: true) { fixture in
            let sibling = fixture.root.appendingPathComponent("keep.data")
            try Data("keep".utf8).write(to: sibling)
            let unconfirmed = clean(fixture, method: .permanent)
            XCTAssertEqual(unconfirmed.state, .skipped)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.item.path))
            let removed = clean(fixture, method: .permanent, confirmed: true)
            XCTAssertEqual(removed.state, .deleted, removed.explanation)
            XCTAssertFalse(removed.canRestore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.item.path))
            XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "keep")
        }
    }
    func testPurgeOnlyOperatesOnSelectedReceiptAndNotOtherTrashEntries() throws {
        try fixture { fixture in
            let other = fixture.trash.appendingPathComponent("unrelated.data")
            try Data("unrelated".utf8).write(to: other)
            let moved = clean(fixture)
            XCTAssertEqual(moved.state, .trashed, moved.explanation)
            let unconfirmed = SpaceCleaningTransaction.purge(record: moved, permanentConfirmed: false, persist: { _ in })
            XCTAssertEqual(unconfirmed, moved)
            let deleted = SpaceCleaningTransaction.purge(record: moved, permanentConfirmed: true, persist: { _ in })
            XCTAssertEqual(deleted.state, .deleted, deleted.explanation)
            XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "unrelated")
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(moved.locationURL).path))
        }
    }
    func testRestoreConflictSkipsOrRenamesWithoutOverwrite() throws {
        try fixture { fixture in
            let moved = clean(fixture)
            XCTAssertEqual(moved.state, .trashed, moved.explanation)
            try Data("new-content".utf8).write(to: fixture.item)
            let skipped = SpaceCleaningTransaction.restore(record: moved, conflict: .skip, persist: { _ in })
            XCTAssertEqual(skipped.state, .trashed)
            XCTAssertTrue(skipped.canRestore)
            let renamed = SpaceCleaningTransaction.restore(record: skipped, conflict: .rename, persist: { _ in })
            XCTAssertEqual(renamed.state, .restored, renamed.explanation)
            XCTAssertNotEqual(renamed.restoredURL, fixture.item)
            XCTAssertEqual(renamed.restoredURL?.pathExtension, "data")
            XCTAssertEqual(try String(contentsOf: fixture.item, encoding: .utf8), "new-content")
            XCTAssertEqual(try String(contentsOf: XCTUnwrap(renamed.restoredURL), encoding: .utf8), "selected-A")
        }
    }
    func testChangedContentAndReplacedParentNeverMoveAnything() throws {
        try fixture(nested: true) { fixture in
            let parent = fixture.item.deletingLastPathComponent()
            let saved = fixture.root.appendingPathComponent("old-parent")
            try FileManager.default.moveItem(at: parent, to: saved)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data("replacement".utf8).write(to: fixture.item)
            let result = clean(fixture)
            XCTAssertEqual(result.state, .skipped)
            XCTAssertEqual(try String(contentsOf: fixture.item, encoding: .utf8), "replacement")
            XCTAssertEqual(try String(contentsOf: saved.appendingPathComponent("selected.data"), encoding: .utf8), "selected-A")
        }
        try fixture { fixture in
            try Data("updated".utf8).write(to: fixture.item)
            XCTAssertEqual(clean(fixture).state, .skipped)
            XCTAssertEqual(try String(contentsOf: fixture.item, encoding: .utf8), "updated")
        }
    }
    func testProtectedSelectionAndFreshRunningPolicyCannotBeBypassed() throws {
        try fixture { fixture in
            var candidate = fixture.candidate; candidate.group = .protected
            let protected = SpaceCleaningTransaction.execute(candidate: candidate, operationID: UUID(), method: .permanent, permanentConfirmed: true,
                                                             mover: fixture.mover, validatePolicy: { _ in nil }, persist: { _ in })
            XCTAssertEqual(protected.state, .skipped)
            let running = SpaceCleaningTransaction.execute(candidate: fixture.candidate, operationID: UUID(), method: .trash,
                                                           mover: fixture.mover, validatePolicy: { _ in "应用正在使用此项目。" }, persist: { _ in })
            XCTAssertEqual(running.state, .skipped)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.item.path))
        }
    }
    func testJournalFailureBeforeMoveKeepsOriginal() throws {
        try fixture { fixture in
            let result = clean(fixture) { _ in throw CocoaError(.fileWriteNoPermission) }
            XCTAssertEqual(result.state, .needsReview)
            XCTAssertEqual(try String(contentsOf: fixture.item, encoding: .utf8), "selected-A")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
        }
    }
    func testTrashDestinationContentMutationIsNotRecordedAsSuccess() throws {
        try fixture { fixture in
            let mover = SpaceCleaningFixtureMover(directory: fixture.trash, after: { url in try Data("changed".utf8).write(to: url) })
            let result = SpaceCleaningTransaction.execute(candidate: fixture.candidate, operationID: UUID(), method: .trash,
                                                          mover: mover, validatePolicy: fixture.policy, persist: { _ in })
            XCTAssertEqual(result.state, .needsReview)
            XCTAssertFalse(result.canRestore)
            XCTAssertEqual(try String(contentsOf: XCTUnwrap(result.locationURL), encoding: .utf8), "changed")
        }
    }
    func testChangedTrashNeverRestoresOrPurgesAReplacement() throws {
        try fixture { fixture in
            let moved = clean(fixture)
            let location = try XCTUnwrap(moved.locationURL)
            try Data("replacement".utf8).write(to: location)
            let restored = SpaceCleaningTransaction.restore(record: moved, conflict: .rename, persist: { _ in })
            XCTAssertEqual(restored.state, .needsReview)
            let removed = SpaceCleaningTransaction.purge(record: moved, permanentConfirmed: true, persist: { _ in })
            XCTAssertEqual(removed.state, .needsReview)
            XCTAssertEqual(try String(contentsOf: location, encoding: .utf8), "replacement")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.item.path))
        }
    }
    func testCancelledPermanentDeletionNeverClaimsSuccessOrResumesAfterRestart() throws {
        try fixture(directory: true) { fixture in
            var stop = false
            let result = SpaceCleaningTransaction.execute(candidate: fixture.candidate, operationID: UUID(), method: .permanent, permanentConfirmed: true,
                                                          mover: fixture.mover, isCancelled: { stop }, validatePolicy: fixture.policy,
                                                          persist: { if $0.state == .deleting { stop = true } })
            XCTAssertEqual(result.state, .needsReview)
            XCTAssertFalse(result.canRestore)
            let location = try XCTUnwrap(result.locationURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: location.path))
            let reconciled = SpaceCleaningTransaction.reconcile(result)
            XCTAssertEqual(reconciled.state, .needsReview)
            XCTAssertTrue(FileManager.default.fileExists(atPath: location.path))
        }
    }
    func testCancellationBeforeWorkHasNoFilesystemEffects() throws {
        try fixture { fixture in
            let result = SpaceCleaningTransaction.execute(candidate: fixture.candidate, operationID: UUID(), method: .trash,
                                                          mover: fixture.mover, isCancelled: { true }, validatePolicy: fixture.policy, persist: { _ in })
            XCTAssertEqual(result.state, .cancelled)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.item.path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
        }
    }
    func testHistoryRoundTripAndCorruptionProtection() throws {
        try fixture { fixture in
            let url = fixture.home.appendingPathComponent("history/actions.json")
            let store = try SpaceCleaningHistoryStore(fileURL: url)
            let result = clean(fixture, persist: store.record)
            XCTAssertEqual(result.state, .trashed, result.explanation)
            XCTAssertEqual(try SpaceCleaningHistoryStore(fileURL: url).records, [result])
            try Data("invalid-record".utf8).write(to: url)
            XCTAssertThrowsError(try SpaceCleaningHistoryStore(fileURL: url))
            XCTAssertThrowsError(try store.record(result))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "invalid-record")
        }
    }
    func testReconcileMissingTrashDisablesAutomaticActionsWithoutRepeatingMove() throws {
        try fixture { fixture in
            let moved = clean(fixture)
            let location = try XCTUnwrap(moved.locationURL)
            let elsewhere = fixture.home.appendingPathComponent("manual-restore.data")
            try FileManager.default.moveItem(at: location, to: elsewhere)
            let reconciled = SpaceCleaningTransaction.reconcile(moved)
            XCTAssertEqual(reconciled.state, .needsReview)
            XCTAssertFalse(reconciled.canRestore)
            XCTAssertFalse(reconciled.canPurge)
            XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "selected-A")
        }
    }
    func testActivityDetectedAfterIsolationRollsBackBeforePermanentDelete() throws {
        try fixture { fixture in
            let result = SpaceCleaningTransaction.execute(candidate: fixture.candidate, operationID: UUID(), method: .permanent,
                permanentConfirmed: true, mover: fixture.mover, validatePolicy: fixture.policy,
                validateActivity: { candidate, current in current.path == candidate.url.path ? nil : "项目刚开始运行。" }, persist: { _ in })
            XCTAssertEqual(result.state, .failed, result.explanation)
            XCTAssertEqual(try String(contentsOf: fixture.item, encoding: .utf8), "selected-A")
            XCTAssertFalse(result.canRestore)
        }
    }
    func testPartialPermanentCancellationRetainsRemainingTreeAndNeverClaimsSuccess() throws {
        try fixture(directory: true) { fixture in
            var isolated: URL?
            let result = SpaceCleaningTransaction.execute(candidate: fixture.candidate, operationID: UUID(), method: .permanent,
                permanentConfirmed: true, mover: fixture.mover, isCancelled: {
                    guard let isolated else { return false }
                    return !FileManager.default.fileExists(atPath: isolated.appendingPathComponent("Contents/a.data").path)
                }, validatePolicy: fixture.policy, persist: { if $0.state == .deleting { isolated = $0.locationURL } })
            XCTAssertEqual(result.state, .needsReview, result.explanation)
            let location = try XCTUnwrap(result.locationURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: location.appendingPathComponent("Contents/a.data").path))
            XCTAssertEqual(try String(contentsOf: location.appendingPathComponent("Contents/nested/b.data"), encoding: .utf8), "selected-B")
            XCTAssertEqual(SpaceCleaningTransaction.reconcile(result).state, .needsReview)
        }
    }
    func testLocalPackageLinksRemainLinksAndNeverReadOrRemoveExternalTargets() throws {
        try fixture(app: true) { fixture in
            let link = fixture.item.appendingPathComponent("Contents/current")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "nested")
            let scope = SpaceCleaningScope(directory: fixture.root)
            var context = fixture.context
            let unknown = try XCTUnwrap(SpaceCleaningScanner.scan(scopes: [scope], context: context).candidates.first)
            context.testDeclarations = [.init(candidate: unknown)]
            let candidate = try XCTUnwrap(SpaceCleaningScanner.scan(scopes: [scope], context: context).candidates.first)
            XCTAssertTrue(candidate.canProcess, candidate.reason)
            let moved = SpaceCleaningTransaction.execute(candidate: candidate, operationID: UUID(), method: .trash, mover: fixture.mover,
                validatePolicy: { SpaceCleaningScanner.revalidate(candidate: $0, context: context) == .unchanged ? nil : "已变化" }, persist: { _ in })
            XCTAssertEqual(moved.state, .trashed, moved.explanation)
            let restored = SpaceCleaningTransaction.restore(record: moved, conflict: .skip, persist: { _ in })
            XCTAssertEqual(restored.state, .restored, restored.explanation)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "nested")
        }
    }
    func testParentSymlinkSwapIsRejectedWithoutFollowingReplacement() throws {
        try fixture(nested: true) { fixture in
            let parent = fixture.item.deletingLastPathComponent(), old = fixture.root.appendingPathComponent("old-parent")
            let replacement = fixture.home.appendingPathComponent("replacement")
            try FileManager.default.moveItem(at: parent, to: old)
            try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: replacement.appendingPathComponent("selected.data"))
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: replacement)
            let result = clean(fixture, method: .permanent, confirmed: true)
            XCTAssertEqual(result.state, .skipped)
            XCTAssertEqual(try String(contentsOf: replacement.appendingPathComponent("selected.data"), encoding: .utf8), "outside")
            XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("selected.data"), encoding: .utf8), "selected-A")
        }
    }
    func testPurgeCrashAfterPreparedPersistKeepsOriginalTrashLocationAndRecoveryAuthority() throws {
        try fixture { fixture in
            let moved = clean(fixture)
            XCTAssertEqual(moved.state, .trashed, moved.explanation)
            let source = try XCTUnwrap(moved.locationURL)
            let journalURL = fixture.home.appendingPathComponent("interrupted-purge/history.json")
            let store = try SpaceCleaningHistoryStore(fileURL: journalURL)
            var recordedBoundary = false
            _ = SpaceCleaningTransaction.purge(record: moved, permanentConfirmed: true, persist: { record in
                if !recordedBoundary {
                    XCTAssertEqual(record.state, .prepared)
                    XCTAssertEqual(record.previousTrashURL, source)
                    try store.record(record)
                    recordedBoundary = true
                }
                // Simulate process interruption at the exact durable boundary:
                // no subsequent in-process catch/finalizer may rewrite the journal.
                throw CocoaError(.fileWriteNoPermission)
            })
            let pending = try XCTUnwrap(SpaceCleaningHistoryStore(fileURL: journalURL).records.first)
            XCTAssertEqual(pending.state, .prepared)
            XCTAssertEqual(pending.previousTrashURL, source)
            XCTAssertNotEqual(pending.locationURL, source)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(pending.locationURL).path))
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "selected-A")
            let recovered = SpaceCleaningTransaction.reconcile(pending)
            XCTAssertEqual(recovered.state, .trashed, recovered.explanation)
            XCTAssertEqual(recovered.locationURL, source)
            XCTAssertTrue(recovered.canRestore)
            XCTAssertTrue(recovered.canPurge)
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "selected-A")
            try store.record(recovered)
            let restored = SpaceCleaningTransaction.restore(record: recovered, conflict: .skip, persist: store.record)
            XCTAssertEqual(restored.state, .restored, restored.explanation)
            XCTAssertEqual(try String(contentsOf: fixture.item, encoding: .utf8), "selected-A")
        }
    }
    func testPurgePreparedRecoveryChecksBothPathsAndNeverResumesDeletion() throws {
        try fixture { fixture in
            let moved = clean(fixture)
            let source = try XCTUnwrap(moved.locationURL)
            var prepared: SpaceCleaningRecord?
            _ = SpaceCleaningTransaction.purge(record: moved, permanentConfirmed: true, persist: { record in
                if prepared == nil { prepared = record }
                throw CocoaError(.fileWriteNoPermission)
            })
            let pending = try XCTUnwrap(prepared)
            let isolation = try XCTUnwrap(pending.isolationURL), target = try XCTUnwrap(pending.locationURL)
            // This is the other side of the same crash window: atomic rename has
            // completed but the isolated receipt was not saved yet.
            try FileManager.default.createDirectory(at: isolation, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: source, to: target)
            let isolated = SpaceCleaningTransaction.reconcile(pending)
            XCTAssertEqual(isolated.state, .needsReview)
            XCTAssertEqual(isolated.locationURL, target)
            XCTAssertEqual(isolated.previousTrashURL, source)
            XCTAssertFalse(isolated.canRestore)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "selected-A")
            // A replacement at the old slot is preserved and cannot be used as
            // evidence that the selected object has returned there.
            try Data("unrelated".utf8).write(to: source)
            XCTAssertEqual(SpaceCleaningTransaction.reconcile(pending).state, .needsReview)
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "unrelated")
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "selected-A")
        }
    }
    func testSchemaOneReceiptsWithoutPreviousTrashURLRemainReadable() throws {
        try fixture { fixture in
            let record = clean(fixture)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
            object.removeValue(forKey: "previousTrashURL")
            let decoded = try JSONDecoder().decode(SpaceCleaningRecord.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(decoded.previousTrashURL)
            XCTAssertEqual(try decoded.validated(), record)
            XCTAssertTrue(decoded.canRestore)
        }
    }
    func testDatalessFlagPreventsContentAccessRegardlessOfOtherFileFlags() {
        // SF_DATALESS is a kernel/File Provider state. Do not create a fake cloud
        // object with chflags or request any real account download in tests.
        XCTAssertTrue(SpaceCleaningFilesystem.isCloudPlaceholder(flags: UInt32(SF_DATALESS)))
        XCTAssertTrue(SpaceCleaningFilesystem.isCloudPlaceholder(flags: UInt32(SF_DATALESS | UF_HIDDEN)))
        XCTAssertTrue(SpaceCleaningFilesystem.isCloudPlaceholder(flags: UInt32(SF_DATALESS | UF_NODUMP | UF_COMPRESSED)))
        XCTAssertFalse(SpaceCleaningFilesystem.isCloudPlaceholder(flags: 0))
        XCTAssertFalse(SpaceCleaningFilesystem.isCloudPlaceholder(flags: UInt32(UF_HIDDEN | UF_NODUMP | UF_COMPRESSED)))
    }
}
