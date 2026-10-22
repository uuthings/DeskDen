import XCTest
@testable import LauncherCore

final class StorageReviewCoreTests: XCTestCase {
    /// All test data is confined to this fresh temporary directory. No user directory is scanned.
    private func fixture(_ test: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Fangcun-StorageReviewTests-" + UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory)
    }
    @discardableResult private func file(_ root: URL, _ name: String, bytes: Int = 10) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: bytes).write(to: url)
        return url
    }
    func testExplicitScopeHasRealSizesProgressAndNoFilesystemWrites() throws {
        try fixture { root in
            let one = try file(root, "one.cache", bytes: 100)
            let two = try file(root, "nested/two.cache", bytes: 200)
            var events: [StorageReviewProgress] = []
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: root, kind: .rebuildableCache)], progress: { events.append($0) })
            XCTAssertEqual(report.stage, .report)
            XCTAssertEqual(report.candidates.count, 2)
            XCTAssertEqual(report.logicalBytes, 300)
            XCTAssertEqual(report.reviewableLogicalBytes, 300)
            XCTAssertEqual(events.last?.logicalBytes, 300)
            XCTAssertTrue(events.dropLast().allSatisfy { $0.currentScopeID != nil })
            XCTAssertEqual(try Data(contentsOf: one).count, 100)
            XCTAssertEqual(try Data(contentsOf: two).count, 200)
            XCTAssertTrue(report.candidates.allSatisfy { $0.disposition == .requiresReview && $0.explanation.contains("正在使用") })
        }
    }
    func testEmptyOrNonFileScopeIsRejectedBeforeScanning() throws {
        XCTAssertThrowsError(try StorageReviewScanner.scan(scopes: []))
        XCTAssertThrowsError(try StorageReviewScanner.scan(scopes: [.init(directory: URL(string: "https://example.com")!, kind: .userSelected)]))
    }
    func testPersonalFilesAreRetainedEvenWhenTheirNameLooksLikeCache() throws {
        try fixture { root in
            try file(root, "delete-safe-cache.log", bytes: 37)
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: root, kind: .userSelected)])
            XCTAssertEqual(report.candidates.first?.category, .personalFile)
            XCTAssertEqual(report.candidates.first?.disposition, .retain)
            XCTAssertEqual(report.reviewableLogicalBytes, 0)
            XCTAssertThrowsError(try StorageReviewTrashPlan(report: report, selectedCandidateIDs: [report.candidates[0].id]))
        }
    }
    func testDiagnosticClassificationUsesExtensionAndActualModificationAge() throws {
        try fixture { root in
            let now = Date()
            let old = try file(root, "old.log", bytes: 10)
            let recent = try file(root, "recent.crash", bytes: 20)
            try file(root, "report.txt", bytes: 30)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86_400)], ofItemAtPath: old.path)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-29 * 86_400)], ofItemAtPath: recent.path)
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: root, kind: .diagnosticRecords)], now: now)
            XCTAssertEqual(report.candidates(in: .oldDiagnostic).count, 1)
            XCTAssertEqual(report.candidates(in: .recentDiagnostic).count, 1)
            XCTAssertEqual(report.candidates(in: .personalFile).count, 1)
            XCTAssertEqual(report.reviewableLogicalBytes, 10)
        }
    }
    func testSymbolicLinksAreRecordedButTheirTargetsAreNeverTraversed() throws {
        try fixture { root in
            let inside = root.appendingPathComponent("inside", isDirectory: true)
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            try file(outside, "private.txt", bytes: 500)
            try FileManager.default.createSymbolicLink(at: inside.appendingPathComponent("redirect"), withDestinationURL: outside)
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: inside, kind: .rebuildableCache)])
            XCTAssertEqual(report.candidates.count, 1)
            XCTAssertEqual(report.candidates[0].category, .symbolicLink)
            XCTAssertEqual(report.candidates[0].disposition, .retain)
            XCTAssertEqual(report.logicalBytes, 0)
        }
    }
    func testApplicationPackagesAreRetainedWithoutReadingTheirChildren() throws {
        try fixture { root in
            try file(root, "Sample.app/Contents/cache.bin", bytes: 500)
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: root, kind: .rebuildableCache)])
            XCTAssertEqual(report.candidates.map(\.relativePath), ["Sample.app"])
            XCTAssertEqual(report.candidates.first?.category, .applicationPackage)
            XCTAssertEqual(report.logicalBytes, 0)
        }
    }
    func testHardLinkedFileIsRetainedAndNotDoubleCounted() throws {
        try fixture { root in
            let source = try file(root, "a", bytes: 100)
            try FileManager.default.linkItem(at: source, to: root.appendingPathComponent("b"))
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: root, kind: .rebuildableCache)])
            XCTAssertEqual(report.candidates.count, 1)
            XCTAssertEqual(report.logicalBytes, 100)
            XCTAssertEqual(report.candidates[0].disposition, .retain)
            XCTAssertEqual(report.issues.count, 1)
        }
    }
    func testCancellationRetainsHonestPartialReportAndDisallowsActionPlan() throws {
        try fixture { root in
            for index in 0..<10 { try file(root, "\(index).cache", bytes: 10) }
            var count = 0
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: root, kind: .rebuildableCache)],
                                                        isCancelled: { count >= 2 }, progress: { count = $0.recordedFiles })
            XCTAssertEqual(report.stage, .cancelled)
            XCTAssertEqual(report.candidates.count, 2)
            XCTAssertEqual(report.logicalBytes, 20)
            XCTAssertThrowsError(try StorageReviewTrashPlan(report: report, selectedCandidateIDs: [report.candidates[0].id]))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 10)
        }
    }
    func testBoundsProduceIncompleteReportAndDoNotPretendFullCoverage() throws {
        try fixture { root in
            for index in 0..<10 { try file(root, "\(index).cache", bytes: 10) }
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: root, kind: .rebuildableCache)], options: .init(maximumEntries: 3))
            XCTAssertEqual(report.checkedEntries, 3)
            XCTAssertTrue(report.reachedLimit)
            XCTAssertThrowsError(try StorageReviewTrashPlan(report: report, selectedCandidateIDs: [report.candidates[0].id]))
        }
    }
    func testOverlappingScopesAreNotCountedTwice() throws {
        try fixture { root in
            try file(root, "child/one", bytes: 100)
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: root, kind: .rebuildableCache), .init(directory: root.appendingPathComponent("child"), kind: .rebuildableCache)])
            XCTAssertEqual(report.scopes.count, 1)
            XCTAssertEqual(report.logicalBytes, 100)
            XCTAssertTrue(report.issues.contains { $0.reason.contains("重叠") })
        }
    }
    func testIdentityValidationRejectsChangedReplacedAndMissingFiles() throws {
        try fixture { root in
            let target = try file(root, "one.cache", bytes: 10)
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: root, kind: .rebuildableCache)])
            let candidate = report.candidates[0], scope = report.scopes[0]
            XCTAssertEqual(StorageReviewIdentityValidator.validate(candidate, scope: scope), .unchanged)
            try Data(repeating: 43, count: 11).write(to: target)
            XCTAssertEqual(StorageReviewIdentityValidator.validate(candidate, scope: scope), .changed)
            try FileManager.default.removeItem(at: target)
            XCTAssertEqual(StorageReviewIdentityValidator.validate(candidate, scope: scope), .missing)
            try file(root, "one.cache", bytes: 10)
            XCTAssertEqual(StorageReviewIdentityValidator.validate(candidate, scope: scope), .changed)
        }
    }
    func testIdentityValidationRejectsSymlinkReplacementAndTraversal() throws {
        try fixture { root in
            let target = try file(root, "one.cache", bytes: 10)
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: root, kind: .rebuildableCache)])
            var candidate = report.candidates[0]
            let scope = report.scopes[0]
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root)
            XCTAssertEqual(StorageReviewIdentityValidator.validate(candidate, scope: scope), .symbolicLink)
            candidate.relativePath = "../escape"
            XCTAssertEqual(StorageReviewIdentityValidator.validate(candidate, scope: scope), .outsideScope)
            XCTAssertNil(StorageReviewIdentityValidator.fileURL(candidate, scope: scope))
        }
    }
    func testReplacingContainingDirectoryCannotRedirectAReviewedPath() throws {
        try fixture { root in
            try file(root, "sub/one.cache", bytes: 10)
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: root, kind: .rebuildableCache)])
            let candidate = report.candidates[0]
            try FileManager.default.moveItem(at: root.appendingPathComponent("sub"), to: root.appendingPathComponent("moved"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sub"), withDestinationURL: root.appendingPathComponent("moved"))
            XCTAssertEqual(StorageReviewIdentityValidator.validate(candidate, scope: report.scopes[0]), .outsideScope)
        }
    }
    func testPlanContainsOnlyExplicitlySelectedReviewableItemsAndRoundTrips() throws {
        try fixture { root in
            try file(root, "one.cache", bytes: 10)
            try file(root, "two.cache", bytes: 20)
            let report = try StorageReviewScanner.scan(scopes: [.init(directory: root, kind: .rebuildableCache)])
            let selected = report.candidates[0]
            let plan = try StorageReviewTrashPlan(report: report, selectedCandidateIDs: [selected.id])
            XCTAssertEqual(plan.selectedCandidateIDs, [selected.id])
            XCTAssertEqual(plan.logicalBytes, selected.logicalBytes)
            let restored = try JSONDecoder().decode(StorageReviewReport.self, from: JSONEncoder().encode(report))
            XCTAssertEqual(restored, report)
            XCTAssertThrowsError(try StorageReviewTrashPlan(report: report, selectedCandidateIDs: []))
            XCTAssertThrowsError(try StorageReviewTrashPlan(report: report, selectedCandidateIDs: [UUID()]))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
        }
    }
    func testSuccessCannotBeSynthesisedWithoutTrashLocation() {
        let result = StorageReviewActionResult(candidateID: UUID(), state: .trashed, reason: "success")
        XCTAssertEqual(result.state, .failed)
        XCTAssertNil(result.trashURL)
    }
}
