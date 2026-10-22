import XCTest
@testable import LauncherCore

final class WorkbenchTopEntryTests: XCTestCase {
    func testDefaultIsEnabledSummaryAndStoredDirectPreferenceIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkbenchTopEntryStore(url: directory.appendingPathComponent("top-entry.json"))
        XCTAssertEqual(try store.load(), .init())
        XCTAssertTrue(try store.load().enabled)
        XCTAssertEqual(try store.load().mode, .summary)
        var preference = WorkbenchTopEntryPreferences()
        preference.mode = .workbench
        preference.enabled = false
        try store.save(preference)
        XCTAssertEqual(try store.load(), preference)
    }
    func testCorruptPreferencesAreNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("top-entry.json")
        let original = Data("broken".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try WorkbenchTopEntryStore(url: url).save(.init()))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testDwellAndLeaveToRearm() {
        var gate = WorkbenchTopEntryGate()
        XCTAssertFalse(gate.update(inside: true, allowed: true, at: 0), "Launch under the notch must not activate.")
        XCTAssertFalse(gate.update(inside: false, allowed: true, at: 1))
        XCTAssertFalse(gate.update(inside: true, allowed: true, at: 2))
        XCTAssertTrue(gate.isDwelling)
        XCTAssertFalse(gate.update(inside: true, allowed: true, at: 2.11))
        XCTAssertTrue(gate.update(inside: true, allowed: true, at: 2.13))
        XCTAssertFalse(gate.isDwelling)
        XCTAssertFalse(gate.update(inside: true, allowed: true, at: 3))
        XCTAssertFalse(gate.update(inside: false, allowed: true, at: 4))
        XCTAssertFalse(gate.update(inside: true, allowed: true, at: 5))
        XCTAssertTrue(gate.update(inside: true, allowed: true, at: 5.13))
    }
    func testDragOrProtectedInteractionRequiresExitBeforeTriggering() {
        var gate = WorkbenchTopEntryGate()
        _ = gate.update(inside: false, allowed: true, at: 0)
        _ = gate.update(inside: true, allowed: true, at: 1)
        XCTAssertFalse(gate.update(inside: true, allowed: false, at: 1.1))
        XCTAssertFalse(gate.update(inside: true, allowed: true, at: 2))
        _ = gate.update(inside: false, allowed: true, at: 3)
        _ = gate.update(inside: true, allowed: true, at: 4)
        XCTAssertTrue(gate.update(inside: true, allowed: true, at: 4.13))
    }
    func testScreenGeometrySupportsNotchAndExternalDisplayOrigins() {
        XCTAssertEqual(WorkbenchTopEntryGate.activationRect(screen: .init(x: 0, y: 0, width: 1728, height: 1117), safeTop: 37, notchWidth: 180), .init(x: 764, y: 1072, width: 200, height: 45))
        XCTAssertEqual(WorkbenchTopEntryGate.activationRect(screen: .init(x: -1920, y: 200, width: 1920, height: 1080), safeTop: 0, notchWidth: nil), .init(x: -1060, y: 1272, width: 200, height: 8))
    }
    func testPhysicalTopEdgeIsIncludedWithoutExpandingTheActivationZone() {
        let zone = WorkbenchTopEntryGate.activationRect(screen: .init(x: 0, y: 0, width: 1728, height: 1117), safeTop: 37, notchWidth: 180)
        XCTAssertTrue(WorkbenchTopEntryGate.contains(.init(x: zone.midX, y: zone.maxY), in: zone))
        XCTAssertTrue(WorkbenchTopEntryGate.contains(.init(x: zone.midX, y: zone.minY), in: zone))
        XCTAssertFalse(WorkbenchTopEntryGate.contains(.init(x: zone.midX, y: zone.maxY + 0.1), in: zone))
        XCTAssertFalse(WorkbenchTopEntryGate.contains(.init(x: zone.midX, y: zone.minY - 0.1), in: zone))
        XCTAssertFalse(WorkbenchTopEntryGate.contains(.init(x: zone.maxX + 0.1, y: zone.midY), in: zone))
        XCTAssertFalse(WorkbenchTopEntryGate.contains(.init(x: .nan, y: zone.midY), in: zone))
    }
}
