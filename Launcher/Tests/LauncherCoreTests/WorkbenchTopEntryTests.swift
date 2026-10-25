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
        XCTAssertEqual(try store.load().visibleSections, [.context, .agenda, .device, .ai])
        var preference = WorkbenchTopEntryPreferences()
        preference.mode = .workbench
        preference.enabled = false
        try store.save(preference)
        XCTAssertEqual(try store.load(), preference)
    }
    func testLegacyPreferencesGainSectionsWithoutChangingEntryChoice() throws {
        let original = Data(#"{"schemaVersion":1,"enabled":false,"mode":"workbench"}"#.utf8)
        let preference = try JSONDecoder().decode(WorkbenchTopEntryPreferences.self, from: original)
        try preference.validate()
        XCTAssertFalse(preference.enabled)
        XCTAssertEqual(preference.mode, .workbench)
        XCTAssertEqual(preference.visibleSections, [.context, .agenda, .device, .ai])
    }
    func testSectionChoicesAndAllHiddenRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkbenchTopEntryStore(url: directory.appendingPathComponent("top-entry.json"))
        var preference = WorkbenchTopEntryPreferences()
        preference.visibleSections = [.agenda, .ai]
        try store.save(preference)
        XCTAssertEqual(try store.load(), preference)
        preference.visibleSections = []
        try store.save(preference)
        XCTAssertEqual(try store.load().visibleSections, [])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testInvalidSectionsCannotReplaceSavedPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkbenchTopEntryStore(url: directory.appendingPathComponent("top-entry.json"))
        try store.save(.init())
        let original = try Data(contentsOf: store.url)
        var duplicate = WorkbenchTopEntryPreferences()
        duplicate.visibleSections = [.context, .context]
        XCTAssertThrowsError(try store.save(duplicate))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        for invalid in [#"["context","context"]"#, #"["unknown"]"#, "null"] {
            let data = Data("{\"schemaVersion\":1,\"enabled\":true,\"mode\":\"summary\",\"visibleSections\":\(invalid)}".utf8)
            try data.write(to: store.url)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(.init()))
            XCTAssertEqual(try Data(contentsOf: store.url), data)
        }
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
