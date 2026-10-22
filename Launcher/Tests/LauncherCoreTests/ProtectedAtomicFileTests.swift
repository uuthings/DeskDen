import Foundation
import XCTest
@testable import LauncherCore

final class ProtectedAtomicFileTests:XCTestCase {
    func testPrivatePermissionsAndReplacementLeaveOnlyCompleteDestination() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-protected-save-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("preferences.json")
        try ProtectedAtomicFile.write(Data("first".utf8),to:url)
        try ProtectedAtomicFile.write(Data("second complete value".utf8),to:url)
        XCTAssertEqual(try Data(contentsOf:url),Data("second complete value".utf8))
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["preferences.json"])
    }
    func testFailedReplacementPreservesExistingDestinationAndRemovesTemporaryFile() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-protected-save-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:root)}
        let target=root.appendingPathComponent("occupied",isDirectory:true)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        let previous=target.appendingPathComponent("retained")
        try Data("retained".utf8).write(to:previous)
        XCTAssertThrowsError(try ProtectedAtomicFile.write(Data("replacement".utf8),to:target))
        XCTAssertEqual(try Data(contentsOf:previous),Data("retained".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["occupied"])
    }
}
