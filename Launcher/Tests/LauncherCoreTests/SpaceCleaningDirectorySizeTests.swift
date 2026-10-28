import XCTest
@testable import LauncherCore

final class SpaceCleaningDirectorySizeTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DeskDenDirectorySize-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = try XCTUnwrap(SpaceCleaningScanner.canonicalURL(temporary))
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    @discardableResult private func file(_ root: URL, _ path: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }
    private func identity(_ url: URL) throws -> SpaceCleaningFileIdentity { try XCTUnwrap(SpaceCleaningScanner.captureIdentity(at: url)) }

    func testCompleteMeasurementDeduplicatesHardLinksAndNeverFollowsSymlinks() throws {
        try fixture { root in
            let first = try file(root, "node_modules/a.bin", bytes: 12)
            let second = try file(root, "node_modules/nested/b.bin", bytes: 24)
            let external = try file(root, "outside/secret.bin", bytes: 900)
            let directory = root.appendingPathComponent("node_modules")
            try FileManager.default.linkItem(at: first, to: directory.appendingPathComponent("hard-link"))
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("external-file"), withDestinationURL: external)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("external-directory"), withDestinationURL: external.deletingLastPathComponent())
            let expected = try identity(directory)
            let result = SpaceCleaningDirectorySizeScanner.measure(directory: directory, expectedIdentity: expected)
            XCTAssertTrue(result.complete, result.reason ?? "")
            XCTAssertFalse(result.cancelled)
            XCTAssertEqual(result.logicalBytes, 36)
            XCTAssertEqual(result.allocatedBytes, try identity(first).allocatedBytes + identity(second).allocatedBytes)
            XCTAssertEqual(result.checkedEntries, 6)
            XCTAssertEqual(try identity(directory), expected)
            XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        }
    }

    func testSparseFileUsesLogicalSizeAndActualAllocationSeparately() throws {
        try fixture { root in
            let url = try file(root, "node_modules/sparse.bin", bytes: 0)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 1_048_576); try handle.close()
            let directory = url.deletingLastPathComponent()
            let result = SpaceCleaningDirectorySizeScanner.measure(directory: directory, expectedIdentity: try identity(directory))
            XCTAssertTrue(result.complete)
            XCTAssertEqual(result.logicalBytes, 1_048_576)
            XCTAssertEqual(result.allocatedBytes, try identity(url).allocatedBytes)
            XCTAssertLessThan(result.allocatedBytes, result.logicalBytes)
        }
    }

    func testDirectAndAncestorSymlinkRootsAreRejectedBeforeEnumeration() throws {
        try fixture { root in
            try file(root, "real/nested/keep.bin", bytes: 80)
            let link = root.appendingPathComponent("node_modules")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real"))
            for directory in [link, link.appendingPathComponent("nested")] {
                let result = SpaceCleaningDirectorySizeScanner.measure(directory: directory, expectedIdentity: try identity(directory))
                XCTAssertFalse(result.complete)
                XCTAssertNotNil(result.reason)
                XCTAssertEqual(result.checkedEntries, 0)
                XCTAssertEqual(result.logicalBytes, 0)
            }
        }
    }

    func testEntryAndDepthLimitsReturnPartialMeasurements() throws {
        try fixture { root in
            for index in 0..<4 { try file(root, "many/file-\(index)", bytes: 10) }
            let many = root.appendingPathComponent("many")
            let bounded = SpaceCleaningDirectorySizeScanner.measure(directory: many, expectedIdentity: try identity(many), maximumEntries: 1)
            XCTAssertFalse(bounded.complete)
            XCTAssertEqual(bounded.checkedEntries, 1)
            XCTAssertEqual(bounded.logicalBytes, 10)
            XCTAssertNotNil(bounded.reason)
            try file(root, "deep/local.bin", bytes: 5)
            try file(root, "deep/nested/keep.bin", bytes: 100)
            let deep = root.appendingPathComponent("deep")
            let shallow = SpaceCleaningDirectorySizeScanner.measure(directory: deep, expectedIdentity: try identity(deep), maximumDepth: 0)
            XCTAssertFalse(shallow.complete)
            XCTAssertEqual(shallow.logicalBytes, 5)
            XCTAssertNotNil(shallow.reason)
        }
    }

    func testCancellationReturnsPartialProgressAndLeavesFilesUntouched() throws {
        try fixture { root in
            for index in 0..<4 { try file(root, "node_modules/file-\(index)", bytes: 10) }
            let directory = root.appendingPathComponent("node_modules"), expected = try identity(directory)
            var stop = false, updates: [SpaceCleaningDirectorySize] = []
            let result = SpaceCleaningDirectorySizeScanner.measure(directory: directory, expectedIdentity: expected,
                isCancelled: { stop }, progress: { updates.append($0); if $0.checkedEntries > 0 { stop = true } })
            XCTAssertTrue(result.cancelled)
            XCTAssertFalse(result.complete)
            XCTAssertEqual(result.checkedEntries, 1)
            XCTAssertEqual(updates.last, result)
            XCTAssertTrue(updates.allSatisfy { !$0.complete })
            XCTAssertEqual(try identity(directory), expected)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 4)
        }
    }

    func testStaleIdentityAndDirectoryReplacementCannotReportComplete() throws {
        try fixture { root in
            try file(root, "data/first.bin", bytes: 10)
            let directory = root.appendingPathComponent("data"), stale = try identity(directory)
            try file(root, "data/second.bin", bytes: 20)
            let rejected = SpaceCleaningDirectorySizeScanner.measure(directory: directory, expectedIdentity: stale)
            XCTAssertFalse(rejected.complete)
            XCTAssertEqual(rejected.checkedEntries, 0)

            var moved = false
            let result = SpaceCleaningDirectorySizeScanner.measure(directory: directory, expectedIdentity: try identity(directory), progress: { value in
                if !moved && value.checkedEntries > 0 {
                    moved = true
                    try? FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("moved"))
                }
            })
            XCTAssertTrue(moved)
            XCTAssertFalse(result.complete)
            XCTAssertNotNil(result.reason)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("moved/first.bin").path))
        }
    }
}
