import XCTest
import Darwin
@testable import LauncherCore

private struct TransactionFixtureMover: StorageReviewFileMoving {
    var trashDirectory: URL
    var beforeTrash: (@Sendable (URL) throws -> Void)?
    var afterTrash: (@Sendable (URL, URL) throws -> Void)?
    var beforeRestore: (@Sendable (URL, URL) throws -> Void)?
    var rejectRestore = false
    func moveToTrash(_ source: URL) throws -> URL {
        try beforeTrash?(source)
        let destination = trashDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: source, to: destination)
        try afterTrash?(source, destination)
        return destination
    }
    func moveBack(_ source: URL, to destination: URL) throws {
        if rejectRestore { throw CocoaError(.fileWriteNoPermission) }
        try beforeRestore?(source, destination)
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

final class StorageReviewTransactionTests: XCTestCase {
    private struct Fixture {
        var root: URL
        var source: URL
        var fakeTrash: URL
        var candidate: StorageReviewCandidate
        var scope: StorageReviewScopeRecord
        var mover: TransactionFixtureMover { .init(trashDirectory: fakeTrash) }
        var original: URL { scope.canonicalDirectory.appendingPathComponent(candidate.relativePath) }
    }
    private func fixture(nested: Bool = false, _ run: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Fangcun-TransactionTests-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("selected"), fakeTrash = root.appendingPathComponent("fake-trash")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let file = source.appendingPathComponent(nested ? "sub/item.cache" : "item.cache")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("selected-A".utf8).write(to: file)
        let report = try StorageReviewScanner.scan(scopes: [.init(directory: source, kind: .rebuildableCache)])
        try run(.init(root: root, source: source, fakeTrash: fakeTrash, candidate: try XCTUnwrap(report.candidates.first), scope: try XCTUnwrap(report.scopes.first)))
    }
    private func text(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }
    func testVerifiedMovePersistsIntentBeforeMoveAndChecksActualReturnedResource() throws {
        try fixture { value in
            var events: [StorageReviewMoveIntent] = []
            let result = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: value.mover,
                persist: { events.append($0) })
            XCTAssertEqual(events.map(\.stage), [.prepared, .moved, .verified])
            XCTAssertEqual(result.state, .trashed)
            XCTAssertNotNil(result.automaticRestoreIdentity)
            XCTAssertFalse(FileManager.default.fileExists(atPath: value.original.path))
            XCTAssertEqual(try text(XCTUnwrap(result.intent.resultingURL)), "selected-A")
            XCTAssertTrue(value.candidate.identity.matchesMovedResource(try XCTUnwrap(result.automaticRestoreIdentity)))
        }
    }
    func testMovedResourceComparisonIgnoresRenameCTimeButRejectsIDSizeOrModtimeChanges() throws {
        try fixture { value in
            let identity = value.candidate.identity
            var renamed = identity; renamed.changedSeconds += 1; renamed.allocatedBytes += 512
            XCTAssertTrue(identity.matchesMovedResource(renamed))
            var changed = renamed; changed.inode += 1; XCTAssertFalse(identity.matchesMovedResource(changed))
            changed = renamed; changed.sizeBytes += 1; XCTAssertFalse(identity.matchesMovedResource(changed))
            changed = renamed; changed.modifiedNanoseconds += 1; XCTAssertFalse(identity.matchesMovedResource(changed))
        }
    }
    func testIntentWriteFailurePreventsAnyMove() throws {
        try fixture { value in
            let result = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: value.mover,
                persist: { _ in throw CocoaError(.fileWriteOutOfSpace) })
            XCTAssertEqual(result.state, .failed); XCTAssertNil(result.automaticRestoreIdentity)
            XCTAssertEqual(try text(value.original), "selected-A")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: value.fakeTrash.path).isEmpty)
        }
    }
    func testCancellationAfterIntentDoesNotMoveAndIsNotReportedSuccessful() throws {
        try fixture { value in
            var cancelled = false, events: [StorageReviewMoveIntent] = []
            let result = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: value.mover,
                isCancelled: { cancelled }, persist: { event in events.append(event); if event.stage == .prepared { cancelled = true } })
            XCTAssertEqual(result.state, .cancelled); XCTAssertEqual(events.last?.stage, .cancelled)
            XCTAssertEqual(try text(value.original), "selected-A")
        }
    }
    func testReplacementBetweenPreflightAndTrashIsSafelyRolledBackAndNeverGetsRestoreAuthority() throws {
        try fixture { value in
            let retained = value.root.appendingPathComponent("concurrently-moved-selected-A")
            var mover = value.mover
            mover.beforeTrash = { source in try FileManager.default.moveItem(at: source, to: retained); try Data("replacement-B".utf8).write(to: source) }
            var events: [StorageReviewMoveIntent] = []
            let result = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: mover, persist: { events.append($0) })
            XCTAssertEqual(result.state, .rolledBack); XCTAssertNil(result.automaticRestoreIdentity)
            XCTAssertEqual(try text(value.original), "replacement-B")
            XCTAssertEqual(try text(retained), "selected-A")
            XCTAssertEqual(events.last?.stage, .rolledBack)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: value.fakeTrash.path).isEmpty)
        }
    }
    func testReplacementAndNewOriginalNeverOverwritesTheNewFileOrRestoresWrongResource() throws {
        try fixture { value in
            let retained = value.root.appendingPathComponent("selected-A-retained")
            var mover = value.mover
            mover.beforeTrash = { source in try FileManager.default.moveItem(at: source, to: retained); try Data("replacement-B".utf8).write(to: source) }
            mover.afterTrash = { source, _ in try Data("new-original-C".utf8).write(to: source) }
            let result = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: mover, persist: { _ in })
            XCTAssertEqual(result.state, .needsReview); XCTAssertNil(result.automaticRestoreIdentity)
            XCTAssertEqual(try text(value.original), "new-original-C")
            XCTAssertEqual(try text(XCTUnwrap(result.intent.resultingURL)), "replacement-B")
            XCTAssertEqual(try text(retained), "selected-A")
        }
    }
    func testChangedContentAfterMoveIsNotMistakenForTheSelectedSnapshot() throws {
        try fixture { value in
            var mover = value.mover
            mover.afterTrash = { _, destination in try Data("content-changed-by-another-writer".utf8).write(to: destination) }
            let result = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: mover, persist: { _ in })
            XCTAssertEqual(result.state, .rolledBack); XCTAssertNil(result.automaticRestoreIdentity)
            XCTAssertEqual(try text(value.original), "content-changed-by-another-writer")
        }
    }
    func testFailureToPersistVerificationRollsBackActualMove() throws {
        try fixture { value in
            var events: [StorageReviewMoveIntent] = []
            let result = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: value.mover,
                persist: { event in if event.stage == .verified { throw CocoaError(.fileWriteOutOfSpace) }; events.append(event) })
            XCTAssertEqual(result.state, .rolledBack)
            XCTAssertEqual(try text(value.original), "selected-A")
            XCTAssertEqual(events.last?.stage, .rolledBack)
        }
    }
    func testRollbackFailurePreservesActualLocationAsManualReviewAndNeverClaimsSuccess() throws {
        try fixture { value in
            var mover = value.mover; mover.rejectRestore = true
            mover.afterTrash = { _, destination in try Data("changed".utf8).write(to: destination) }
            let result = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: mover, persist: { _ in })
            XCTAssertEqual(result.state, .needsReview); XCTAssertNil(result.automaticRestoreIdentity)
            XCTAssertEqual(result.intent.stage, .needsReview)
            XCTAssertEqual(try text(XCTUnwrap(result.intent.resultingURL)), "changed")
        }
    }
    func testAPIThrowAfterMoveIsUncertainRatherThanInventingSafeFailure() throws {
        try fixture { value in
            var mover = value.mover; mover.afterTrash = { _, _ in throw CocoaError(.fileWriteUnknown) }
            var events: [StorageReviewMoveIntent] = []
            let result = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: mover, persist: { events.append($0) })
            XCTAssertEqual(result.state, .needsReview); XCTAssertNil(result.automaticRestoreIdentity)
            XCTAssertEqual(events.last?.stage, .needsReview)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: value.fakeTrash.path).count, 1)
        }
    }
    func testPreparedInterruptionWithMissingSourceDoesNotInferSuccessOrRepeatMove() throws {
        try fixture { value in
            let prepared = StorageReviewMoveIntent(operationID: UUID(), candidate: value.candidate, scope: value.scope)
            _ = try value.mover.moveToTrash(value.original) // Simulates process death before OS destination is recorded.
            let outcome = StorageReviewMoveTransaction.reconcile(prepared)
            XCTAssertEqual(outcome.state, .needsReview); XCTAssertEqual(outcome.intent.stage, .needsReview)
            XCTAssertNil(outcome.automaticRestoreIdentity)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: value.fakeTrash.path).count, 1)
        }
    }
    func testMovedInterruptionRecoversOnlyTheRecordedSelectedIdentity() throws {
        try fixture { value in
            var event = StorageReviewMoveIntent(operationID: UUID(), candidate: value.candidate, scope: value.scope)
            event.resultingURL = try value.mover.moveToTrash(value.original)
            event.resultingIdentity = StorageReviewIdentityValidator.captureRegularFileIdentity(at: event.resultingURL!)
            event.stage = .moved
            XCTAssertEqual(StorageReviewMoveTransaction.reconcile(event).state, .trashed)
            try FileManager.default.removeItem(at: event.resultingURL!)
            try Data("another-file".utf8).write(to: event.resultingURL!)
            let changed = StorageReviewMoveTransaction.reconcile(event)
            XCTAssertEqual(changed.state, .needsReview); XCTAssertNil(changed.automaticRestoreIdentity)
        }
    }
    func testIntentStoreRoundTripsAndRejectsInvalidUpdateWithoutReplacingPreviousData() throws {
        try fixture { value in
            let url = value.root.appendingPathComponent("journal/intents.json")
            let store = try StorageReviewIntentStore(fileURL: url)
            let event = StorageReviewMoveIntent(operationID: UUID(), candidate: value.candidate, scope: value.scope)
            try store.record(event); let originalBytes = try Data(contentsOf: url)
            var invalid = event; invalid.candidate.relativePath = "../private"
            XCTAssertThrowsError(try store.record(invalid))
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
            XCTAssertEqual(try StorageReviewIntentStore(fileURL: url).pending, [event])
            try store.remove(event.id); XCTAssertTrue(store.pending.isEmpty)
        }
    }
    func testRestoreVerifiesSelectedResourceAndDoesNotOverwriteExistingLocation() throws {
        try fixture { value in
            let trashed = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: value.mover, persist: { _ in })
            var persisted = false
            let restored = StorageReviewRestoreTransaction.execute(candidate: value.candidate, scope: value.scope, trashURL: try XCTUnwrap(trashed.intent.resultingURL),
                verifiedIdentity: try XCTUnwrap(trashed.automaticRestoreIdentity), mover: value.mover, persistIntent: { persisted = true })
            XCTAssertTrue(persisted); XCTAssertEqual(restored.state, .restored)
            XCTAssertEqual(try text(value.original), "selected-A")
        }
    }
    func testRestoreRaceReturnsTheWrongMovedItemToTrashWithoutMarkingItRestored() throws {
        try fixture { value in
            let trashed = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: value.mover, persist: { _ in })
            let trashURL = try XCTUnwrap(trashed.intent.resultingURL)
            let retained = value.root.appendingPathComponent("selected-retained-before-restore")
            var mover = value.mover
            mover.beforeRestore = { source, _ in
                if source == trashURL { try FileManager.default.moveItem(at: source, to: retained); try Data("replacement-B".utf8).write(to: source) }
            }
            let result = StorageReviewRestoreTransaction.execute(candidate: value.candidate, scope: value.scope, trashURL: trashURL,
                verifiedIdentity: try XCTUnwrap(trashed.automaticRestoreIdentity), mover: mover, persistIntent: {})
            XCTAssertEqual(result.state, .rolledBack)
            XCTAssertFalse(FileManager.default.fileExists(atPath: value.original.path))
            XCTAssertEqual(try text(trashURL), "replacement-B")
            XCTAssertEqual(try text(retained), "selected-A")
        }
    }
    func testMissingLeafUnderReplacedParentCannotAuthorizeRestoreOutsideScope() throws {
        try fixture(nested: true) { value in
            let trashed = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: value.mover, persist: { _ in })
            let parent = value.original.deletingLastPathComponent(), movedParent = value.root.appendingPathComponent("old-parent"), outside = value.root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: parent, to: movedParent)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
            XCTAssertEqual(StorageReviewIdentityValidator.validate(value.candidate, scope: value.scope), .outsideScope)
            let result = StorageReviewRestoreTransaction.execute(candidate: value.candidate, scope: value.scope, trashURL: try XCTUnwrap(trashed.intent.resultingURL),
                verifiedIdentity: try XCTUnwrap(trashed.automaticRestoreIdentity), mover: value.mover, persistIntent: { XCTFail("Must not persist an unauthorized restore") })
            XCTAssertEqual(result.state, .notMoved)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }
    func testInterruptedRestoreReconcilesActualIdentityWithoutRepeatingMovement() throws {
        try fixture { value in
            let trashed = StorageReviewMoveTransaction.execute(candidate: value.candidate, scope: value.scope, operationID: UUID(), mover: value.mover, persist: { _ in })
            let trashURL = try XCTUnwrap(trashed.intent.resultingURL), expected = try XCTUnwrap(trashed.automaticRestoreIdentity)
            XCTAssertEqual(StorageReviewRestoreTransaction.reconcile(candidate: value.candidate, scope: value.scope, trashURL: trashURL, verifiedIdentity: expected,contentProof:trashed.intent.contentProof).state, .notMoved)
            try value.mover.moveBack(trashURL, to: value.original) // Simulates death before final restoration receipt.
            XCTAssertEqual(StorageReviewRestoreTransaction.reconcile(candidate: value.candidate, scope: value.scope, trashURL: trashURL, verifiedIdentity: expected,contentProof:trashed.intent.contentProof).state, .restored)
            XCTAssertEqual(try text(value.original), "selected-A")
        }
    }
    private func changeOnlyCTime(_ url:URL) throws {
        let name="com.fangcun.restore-proof-check"
        let status=url.withUnsafeFileSystemRepresentation {path in
            name.withCString {key in var byte:UInt8=42;return withUnsafePointer(to:&byte){setxattr(path!,key,$0,1,0,0)}}
        }
        guard status == 0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
    }
    private func restoreMTime(_ identity:StorageReviewFileIdentity,at url:URL) throws {
        var times=[timespec(tv_sec:Int(identity.modifiedSeconds),tv_nsec:Int(identity.modifiedNanoseconds)),timespec(tv_sec:Int(identity.modifiedSeconds),tv_nsec:Int(identity.modifiedNanoseconds))]
        let status=url.withUnsafeFileSystemRepresentation {utimensat(AT_FDCWD,$0,&times,AT_SYMLINK_NOFOLLOW)}
        guard status == 0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
    }
    func testSelectedContentProofIsDurableBeforeMoveAndSurvivesIntentReload() throws {
        try fixture {value in
            let store=try StorageReviewIntentStore(fileURL:value.root.appendingPathComponent("intents.json"))
            var prepared:StorageReviewMoveIntent?
            let outcome=StorageReviewMoveTransaction.execute(candidate:value.candidate,scope:value.scope,operationID:UUID(),mover:value.mover,persist:{intent in
                try store.record(intent)
                if intent.stage == .prepared {prepared=try StorageReviewIntentStore(fileURL:value.root.appendingPathComponent("intents.json")).pending.first}
            })
            XCTAssertEqual(outcome.state,.trashed)
            XCTAssertTrue(try XCTUnwrap(prepared?.contentProof).isValid)
            XCTAssertEqual(prepared?.contentProof,outcome.intent.contentProof)
            XCTAssertEqual(try StorageReviewIntentStore(fileURL:value.root.appendingPathComponent("intents.json")).pending.first?.contentProof,outcome.intent.contentProof)
            var invalid=outcome.intent;invalid.contentProof?.sha256="invalid"
            let bytes=try Data(contentsOf:value.root.appendingPathComponent("intents.json"))
            XCTAssertThrowsError(try store.record(invalid))
            XCTAssertEqual(try Data(contentsOf:value.root.appendingPathComponent("intents.json")),bytes)
        }
    }
    func testNewProofRestoresRealCTimeOnlyTrashChangeWithoutChangingContents() throws {
        try fixture {value in
            let moved=StorageReviewMoveTransaction.execute(candidate:value.candidate,scope:value.scope,operationID:UUID(),mover:value.mover,persist:{_ in})
            let trash=try XCTUnwrap(moved.intent.resultingURL),expected=try XCTUnwrap(moved.automaticRestoreIdentity)
            try changeOnlyCTime(trash)
            let changed=try XCTUnwrap(StorageReviewIdentityValidator.captureRegularFileIdentity(at:trash))
            XCTAssertNotEqual(changed,expected)
            XCTAssertTrue(expected.matchesContentResource(changed))
            let proof=try XCTUnwrap(moved.intent.contentProof)
            let currentLease=try StorageReviewIdentityValidator.openContent(at:trash,expected:expected,allowChangedTime:true)
            let currentProof=try currentLease.contentProof()
            XCTAssertEqual(currentProof,proof)
            XCTAssertTrue(currentLease.matchesPath(trash))
            var persisted=false
            let result=StorageReviewRestoreTransaction.execute(candidate:value.candidate,scope:value.scope,trashURL:trash,verifiedIdentity:expected,mover:value.mover,
                contentProof:try XCTUnwrap(moved.intent.contentProof),persistIntent:{persisted=true})
            XCTAssertTrue(persisted);XCTAssertEqual(result.state,.restored)
            XCTAssertEqual(try text(value.original),"selected-A")
            XCTAssertFalse(FileManager.default.fileExists(atPath:trash.path))
        }
    }
    func testLegacyReceiptAndPendingIntentNeverGainProofAfterCTimeChanges() throws {
        try fixture {value in
            let moved=StorageReviewMoveTransaction.execute(candidate:value.candidate,scope:value.scope,operationID:UUID(),mover:value.mover,persist:{_ in})
            let trash=try XCTUnwrap(moved.intent.resultingURL),expected=try XCTUnwrap(moved.automaticRestoreIdentity)
            var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(moved.intent)) as? [String:Any]);json.removeValue(forKey:"contentProof")
            let legacy=try JSONDecoder().decode(StorageReviewMoveIntent.self,from:JSONSerialization.data(withJSONObject:json))
            XCTAssertNil(legacy.contentProof)
            XCTAssertEqual(StorageReviewMoveTransaction.reconcile(legacy).state,.trashed)
            try changeOnlyCTime(trash)
            let result=StorageReviewRestoreTransaction.execute(candidate:value.candidate,scope:value.scope,trashURL:trash,verifiedIdentity:expected,mover:value.mover,persistIntent:{XCTFail("Legacy changed metadata cannot authorize a move")})
            XCTAssertEqual(result.state,.notMoved)
            XCTAssertTrue(result.explanation.contains("Finder"))
            XCTAssertEqual(StorageReviewRestoreTransaction.reconcile(candidate:value.candidate,scope:value.scope,trashURL:trash,verifiedIdentity:expected).state,.needsReview)
            let reconciled=StorageReviewMoveTransaction.reconcile(legacy)
            XCTAssertEqual(reconciled.state,.needsReview);XCTAssertNil(reconciled.intent.contentProof)
            XCTAssertEqual(reconciled.intent.resultingIdentity,expected)
            XCTAssertEqual(try text(trash),"selected-A")
        }
    }
    func testSameSizeContentRewriteWithRestoredMTimeCannotRestoreOrReconcile() throws {
        try fixture {value in
            let moved=StorageReviewMoveTransaction.execute(candidate:value.candidate,scope:value.scope,operationID:UUID(),mover:value.mover,persist:{_ in})
            let trash=try XCTUnwrap(moved.intent.resultingURL),expected=try XCTUnwrap(moved.automaticRestoreIdentity),proof=try XCTUnwrap(moved.intent.contentProof)
            try Data("attacker-B".utf8).write(to:trash);try restoreMTime(expected,at:trash)
            let changed=try XCTUnwrap(StorageReviewIdentityValidator.captureRegularFileIdentity(at:trash))
            XCTAssertTrue(expected.matchesContentResource(changed))
            let result=StorageReviewRestoreTransaction.execute(candidate:value.candidate,scope:value.scope,trashURL:trash,verifiedIdentity:expected,mover:value.mover,contentProof:proof,persistIntent:{XCTFail("A content mismatch cannot authorize an intent")})
            XCTAssertEqual(result.state,.notMoved)
            XCTAssertFalse(FileManager.default.fileExists(atPath:value.original.path))
            XCTAssertEqual(StorageReviewMoveTransaction.reconcile(moved.intent).state,.needsReview)
            XCTAssertEqual(StorageReviewRestoreTransaction.reconcile(candidate:value.candidate,scope:value.scope,trashURL:trash,verifiedIdentity:expected,contentProof:proof).state,.needsReview)
        }
    }
    func testContentProofRejectsChangedPermissionsHardLinksSymlinksAndReplacementInodes() throws {
        for mutation in ["mode","link","symlink","inode"] {
            try fixture {value in
                let moved=StorageReviewMoveTransaction.execute(candidate:value.candidate,scope:value.scope,operationID:UUID(),mover:value.mover,persist:{_ in})
                let trash=try XCTUnwrap(moved.intent.resultingURL),expected=try XCTUnwrap(moved.automaticRestoreIdentity),proof=try XCTUnwrap(moved.intent.contentProof)
                let retained=value.root.appendingPathComponent("retained")
                switch mutation {
                case "mode":try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:trash.path)
                case "link":try FileManager.default.linkItem(at:trash,to:retained)
                case "symlink":try FileManager.default.moveItem(at:trash,to:retained);try FileManager.default.createSymbolicLink(at:trash,withDestinationURL:retained)
                default:try FileManager.default.moveItem(at:trash,to:retained);try Data("selected-A".utf8).write(to:trash);try restoreMTime(expected,at:trash)
                }
                let result=StorageReviewRestoreTransaction.execute(candidate:value.candidate,scope:value.scope,trashURL:trash,verifiedIdentity:expected,mover:value.mover,contentProof:proof,persistIntent:{XCTFail("\(mutation) must not authorize restore")})
                XCTAssertEqual(result.state,.notMoved,mutation)
                XCTAssertFalse(FileManager.default.fileExists(atPath:value.original.path),mutation)
            }
        }
    }
    func testProofRetainsSecurityMetadataAndRejectsUntrustedDigest() throws {
        try fixture {value in
            let lease=try StorageReviewIdentityValidator.openContent(at:value.original,expected:value.candidate.identity)
            let proof=try lease.contentProof()
            var changed=proof;changed.ownerID &+= 1
            XCTAssertFalse(StorageReviewIdentityValidator.contentMatches(at:value.original,expected:value.candidate.identity,proof:changed))
            changed=proof;changed.groupID &+= 1
            XCTAssertFalse(StorageReviewIdentityValidator.contentMatches(at:value.original,expected:value.candidate.identity,proof:changed))
            changed=proof;changed.flags ^= 1
            XCTAssertFalse(StorageReviewIdentityValidator.contentMatches(at:value.original,expected:value.candidate.identity,proof:changed))
            changed=proof;changed.sha256="Z"+String(proof.sha256.dropFirst())
            XCTAssertFalse(changed.isValid)
        }
    }
    func testHashReadsAreCancellableAndDetectMutationOrChangedPathBinding() throws {
        try fixture {value in
            try Data(repeating:65,count:2_097_153).write(to:value.original)
            let identity=try XCTUnwrap(StorageReviewIdentityValidator.captureRegularFileIdentity(at:value.original))
            let lease=try StorageReviewIdentityValidator.openContent(at:value.original,expected:identity)
            var cancelled=false
            XCTAssertThrowsError(try lease.contentProof(isCancelled:{cancelled},onRead:{_ in cancelled=true}))
            var changed=false
            XCTAssertThrowsError(try lease.contentProof(onRead:{_ in if !changed {changed=true;try? Data(repeating:66,count:2_097_153).write(to:value.original)}}))
            let current=try XCTUnwrap(StorageReviewIdentityValidator.captureRegularFileIdentity(at:value.original))
            let next=try StorageReviewIdentityValidator.openContent(at:value.original,expected:current)
            var renamed=false
            XCTAssertThrowsError(try next.contentProof(onRead:{_ in if !renamed {renamed=true;try? FileManager.default.moveItem(at:value.original,to:value.root.appendingPathComponent("retained-open-file"));try? Data(repeating:66,count:2_097_153).write(to:value.original)}}))
            XCTAssertFalse(next.matchesPath(value.original))
        }
    }
    func testRestoreRechecksDigestAfterPersistingIntentAndCancellationDoesNotMove() throws {
        for cancel in [false,true] {
            try fixture {value in
                let moved=StorageReviewMoveTransaction.execute(candidate:value.candidate,scope:value.scope,operationID:UUID(),mover:value.mover,persist:{_ in})
                let trash=try XCTUnwrap(moved.intent.resultingURL),expected=try XCTUnwrap(moved.automaticRestoreIdentity),proof=try XCTUnwrap(moved.intent.contentProof)
                var cancelled=false
                let result=StorageReviewRestoreTransaction.execute(candidate:value.candidate,scope:value.scope,trashURL:trash,verifiedIdentity:expected,mover:value.mover,contentProof:proof,isCancelled:{cancelled},persistIntent:{
                    if cancel {cancelled=true} else {try Data("attacker-B".utf8).write(to:trash);try self.restoreMTime(expected,at:trash)}
                })
                XCTAssertEqual(result.state,.notMoved)
                XCTAssertFalse(FileManager.default.fileExists(atPath:value.original.path))
                XCTAssertEqual(try text(trash),cancel ? "selected-A":"attacker-B")
            }
        }
    }
    func testDigestReconciliationAcceptsOnlyRecordedProofAfterCTimeChangeAndInterruptedRestore() throws {
        try fixture {value in
            let moved=StorageReviewMoveTransaction.execute(candidate:value.candidate,scope:value.scope,operationID:UUID(),mover:value.mover,persist:{_ in})
            let trash=try XCTUnwrap(moved.intent.resultingURL),expected=try XCTUnwrap(moved.automaticRestoreIdentity),proof=try XCTUnwrap(moved.intent.contentProof)
            try changeOnlyCTime(trash)
            let replay=StorageReviewMoveTransaction.reconcile(try JSONDecoder().decode(StorageReviewMoveIntent.self,from:JSONEncoder().encode(moved.intent)))
            XCTAssertEqual(replay.state,.trashed);XCTAssertEqual(replay.intent.contentProof,proof)
            XCTAssertEqual(StorageReviewRestoreTransaction.reconcile(candidate:value.candidate,scope:value.scope,trashURL:trash,verifiedIdentity:expected,contentProof:proof).state,.notMoved)
            try value.mover.moveBack(trash,to:value.original)
            XCTAssertEqual(StorageReviewRestoreTransaction.reconcile(candidate:value.candidate,scope:value.scope,trashURL:trash,verifiedIdentity:expected,contentProof:proof).state,.restored)
            try Data("attacker-B".utf8).write(to:value.original);try restoreMTime(expected,at:value.original)
            XCTAssertEqual(StorageReviewRestoreTransaction.reconcile(candidate:value.candidate,scope:value.scope,trashURL:trash,verifiedIdentity:expected,contentProof:proof).state,.needsReview)
        }
    }
}
