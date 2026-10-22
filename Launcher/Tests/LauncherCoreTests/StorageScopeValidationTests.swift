import XCTest
@testable import LauncherCore

final class StorageScopeValidationTests: XCTestCase {
    func testExplicitRegistrationAndScannerShareCanonicalDirectoryIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Fangcun-ScopeValidation-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("candidate.cache"), bytes = Data("isolated fixture".utf8)
        try bytes.write(to: file)
        let scope = StorageReviewScope(directory: root, kind: .rebuildableCache)
        let registered = try StorageReviewScanner.validatedScope(scope)
        let report = try StorageReviewScanner.scan(scopes: [scope])
        XCTAssertEqual(registered.canonicalDirectory, report.scopes.first?.canonicalDirectory)
        XCTAssertEqual(registered.directoryIdentity.device, report.scopes.first?.directoryIdentity.device)
        XCTAssertEqual(registered.directoryIdentity.inode, report.scopes.first?.directoryIdentity.inode)
        XCTAssertEqual(report.candidates.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testScopeRegistrationRejectsSameUnsafeInputsAsActualScanner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Fangcun-ScopeInvalid-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("regular.cache"), package = root.appendingPathComponent("Sample.app")
        try Data("fixture".utf8).write(to: file)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let invalid = [URL(string: "https://example.com")!, URL(fileURLWithPath: "/"), file, package, root.appendingPathComponent("missing")]
        for url in invalid {
            let scope = StorageReviewScope(directory: url, kind: .rebuildableCache)
            XCTAssertThrowsError(try StorageReviewScanner.validatedScope(scope)) { error in
                XCTAssertEqual(error as? StorageReviewError, .invalidScope)
            }
            if url.isFileURL {
                let report = try StorageReviewScanner.scan(scopes: [scope])
                XCTAssertTrue(report.scopes.isEmpty); XCTAssertTrue(report.candidates.isEmpty)
                XCTAssertEqual(report.issues.count, 1)
            } else { XCTAssertThrowsError(try StorageReviewScanner.scan(scopes: [scope])) }
        }
    }
}
