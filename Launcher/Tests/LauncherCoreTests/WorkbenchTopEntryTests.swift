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
        duplicate.visibleCards = [.codex, .codex]
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
    func testLegacyGroupsMigrateToIndependentCardsAndHeaderChoices() throws {
        let data = Data(#"{"schemaVersion":1,"enabled":true,"mode":"summary","visibleSections":["agenda","ai"]}"#.utf8)
        let value = try JSONDecoder().decode(WorkbenchTopEntryPreferences.self, from: data)
        XCTAssertEqual(value.schemaVersion, 2)
        XCTAssertFalse(value.showDate); XCTAssertFalse(value.showWeather)
        XCTAssertEqual(value.visibleCards, [.codex, .claude, .todo])
        let empty = Data(#"{"schemaVersion":1,"enabled":true,"mode":"summary","visibleSections":[]}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(WorkbenchTopEntryPreferences.self, from: empty).visibleCards.isEmpty)
    }
    func testModularOrderAndExternalSelectionSurviveRoundTripAndMissingSource() throws {
        var value = WorkbenchTopEntryPreferences()
        let external = WorkbenchMiniCardID.provider(UUID())
        value.setCard(external, visible: true)
        value.moveCard(.thermal, relativeTo: .codex, after: false)
        value.setCard(.memory, visible: false)
        value.showDate = false
        let decoded = try JSONDecoder().decode(WorkbenchTopEntryPreferences.self, from: JSONEncoder().encode(value))
        try decoded.validate()
        XCTAssertEqual(value, decoded)
        XCTAssertEqual(decoded.cardOrder.first, .thermal)
        XCTAssertTrue(decoded.visibleCards.contains(external))
        XCTAssertFalse(decoded.activeCards(available: WorkbenchMiniCardID.builtIn).contains(external))
        XCTAssertTrue(decoded.activeCards(available: WorkbenchMiniCardID.builtIn + [external]).contains(external))
        XCTAssertEqual(decoded.cardOrder, value.cardOrder, "A removed external source does not rewrite other saved positions.")
        XCTAssertEqual(decoded.showWeather, true)
    }
    func testAllSupportedExternalSourcesFitPersistedLayoutAndBoundedColumns() throws {
        var preferences = WorkbenchTopEntryPreferences()
        for _ in 0..<100 { preferences.setCard(.provider(UUID()), visible: true) }
        try preferences.validate()
        let placements = WorkbenchMiniPacking.pack(preferences.visibleCards)
        XCTAssertEqual(placements.count, 108)
        XCTAssertEqual(Set(placements.map(\.column)).count, 37)
        XCTAssertTrue(placements.allSatisfy { $0.row + $0.span <= 6 })
        XCTAssertLessThan(try JSONEncoder().encode(preferences).count, 65_536)
    }
    func testModularInvalidIDsOrdersAndFutureVersionsAreRejected() throws {
        var value = WorkbenchTopEntryPreferences()
        value.cardOrder.append(.init(rawValue: "provider:not-a-uuid"))
        XCTAssertThrowsError(try value.validate())
        value = .init(); value.visibleCards.append(.provider(UUID()))
        XCTAssertThrowsError(try value.validate())
        value = .init(); value.cardOrder.removeFirst()
        XCTAssertThrowsError(try value.validate())
        let future = Data(#"{"schemaVersion":99,"enabled":true,"mode":"summary"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WorkbenchTopEntryPreferences.self, from: future))
    }
    func testDefaultPackingIsThreeColumnsWithApprovedCardHeights() {
        let packed = WorkbenchMiniPacking.pack(WorkbenchMiniCardID.builtIn)
        XCTAssertEqual(packed.filter { $0.column == 0 }.map(\.card), [.codex, .claude, .traffic])
        XCTAssertEqual(packed.filter { $0.column == 1 }.map(\.card), [.disk, .memory, .todo])
        XCTAssertEqual(packed.filter { $0.column == 2 }.map(\.card), [.network, .thermal])
        XCTAssertEqual(packed.filter { $0.column == 0 }.map(\.row), [0, 2, 4])
        XCTAssertEqual(packed.filter { $0.column == 2 }.map(\.row), [0, 3])
    }
    func testAllCardSubsetsUseMinimumNonoverlappingColumns() {
        let all = WorkbenchMiniCardID.builtIn
        for mask in 0..<(1 << all.count) {
            let active = all.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil }
            for order in [active, active.reversed().map { $0 }] {
                let packed = WorkbenchMiniPacking.pack(order)
                XCTAssertEqual(Set(packed.map(\.card)), Set(active))
                let small = active.filter { $0.span == 2 }.count, medium = active.count - small
                // Independently enumerate pair/single-medium columns; every
                // remaining column holds at most three small cards.
                let minimum = (0...(medium / 2)).map { pairs in
                    let singles = medium - pairs * 2
                    return pairs + singles + max(0, small - singles + 2) / 3
                }.min() ?? 0
                XCTAssertEqual((packed.map(\.column).max() ?? -1) + 1, minimum, "mask \(mask)")
                for column in Set(packed.map(\.column)) {
                    let items = packed.filter { $0.column == column }.sorted { $0.row < $1.row }
                    XCTAssertLessThanOrEqual(items.last.map { $0.row + $0.span } ?? 0, 6)
                    for (a, b) in zip(items, items.dropFirst()) { XCTAssertLessThanOrEqual(a.row + a.span, b.row) }
                }
            }
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
