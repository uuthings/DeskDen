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
    func testSecondsDefaultOffAndPersistWithoutChangingHeaderVisibility() throws {
        var original = WorkbenchTopEntryPreferences()
        original.showWeather = false
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "showSeconds")
        let migrated = try JSONDecoder().decode(WorkbenchTopEntryPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(migrated, original)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkbenchTopEntryStore(url: directory.appendingPathComponent("top-entry.json"))
        var selected = migrated
        selected.showSeconds = true
        try store.save(selected)
        XCTAssertEqual(try store.load(), selected)
        selected.showDate = false
        try store.save(selected)
        XCTAssertTrue(try store.load().showSeconds, "Hiding the clock preserves its display preference.")
        XCTAssertFalse(try store.load().showDate)
        XCTAssertFalse(try store.load().showWeather)
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
        XCTAssertEqual(value.schemaVersion, 3)
        XCTAssertFalse(value.showDate); XCTAssertFalse(value.showWeather)
        XCTAssertEqual(value.visibleCards, [.todo, .codex, .claude])
        let empty = Data(#"{"schemaVersion":1,"enabled":true,"mode":"summary","visibleSections":[]}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(WorkbenchTopEntryPreferences.self, from: empty).visibleCards.isEmpty)
    }
    func testModularOrderAndExternalSelectionSurviveRoundTripAndMissingSource() throws {
        var value = WorkbenchTopEntryPreferences()
        let external = WorkbenchMiniCardID.provider(UUID())
        value.setCard(external, visible: true)
        value.moveCard(.thermal, relativeTo: .network, after: false)
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
        XCTAssertEqual(placements.count, 107)
        XCTAssertEqual(Set(placements.map(\.column)).count, 53)
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
        let packed = WorkbenchMiniPacking.pack(WorkbenchMiniCardID.defaultVisible)
        XCTAssertEqual(packed.filter { $0.column == 0 }.map(\.card), [.network, .thermal])
        XCTAssertEqual(packed.filter { $0.column == 1 }.map(\.card), [.disk, .memory, .todo])
        XCTAssertEqual(packed.filter { $0.column == 2 }.map(\.card), [.codex, .claude])
        XCTAssertEqual(packed.filter { $0.column == 0 }.map(\.row), [0, 3])
        XCTAssertEqual(packed.filter { $0.column == 1 }.map(\.row), [0, 2, 4])
        XCTAssertEqual(packed.filter { $0.column == 2 }.map(\.row), [0, 3])
        XCTAssertFalse(packed.map(\.card).contains(.traffic))
    }
    func testAllCardSubsetsPreserveVisualOrderWithoutOverlap() {
        let all = WorkbenchMiniCardID.builtIn
        for mask in 0..<(1 << all.count) {
            let active = all.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil }
            for order in [active, active.reversed().map { $0 }] {
                let packed = WorkbenchMiniPacking.pack(order)
                XCTAssertEqual(Set(packed.map(\.card)), Set(active))
                let visualOrder = packed.sorted { ($0.column, $0.row) < ($1.column, $1.row) }.map(\.card)
                XCTAssertEqual(visualOrder, order, "mask \(mask): filling holes must not reorder cards")
                for column in Set(packed.map(\.column)) {
                    let items = packed.filter { $0.column == column }.sorted { $0.row < $1.row }
                    XCTAssertEqual(items.first?.row, 0)
                    XCTAssertLessThanOrEqual(items.last.map { $0.row + $0.span } ?? 0, 6)
                    for (a, b) in zip(items, items.dropFirst()) { XCTAssertLessThanOrEqual(a.row + a.span, b.row) }
                    if let last = items.last, let next = packed.first(where: { $0.column == column + 1 }) {
                        XCTAssertGreaterThan(last.row + last.span + next.span, 6, "a new column starts only when the next card cannot fit")
                    }
                }
            }
        }
    }
    func testLegacyDefaultMigratesWhileCustomizedOrderAndHiddenCardsRemain() throws {
        let legacyOrder = ["codex", "claude", "traffic", "disk", "memory", "todo", "network", "thermal"]
        func decode(order: [String], visible: [String]) throws -> WorkbenchTopEntryPreferences {
            let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "enabled": false, "mode": "workbench", "cardOrder": order, "visibleCards": visible, "showDate": false, "showWeather": true, "showSeconds": true])
            return try JSONDecoder().decode(WorkbenchTopEntryPreferences.self, from: data)
        }
        let migrated = try decode(order: legacyOrder, visible: legacyOrder)
        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertEqual(migrated.cardOrder, WorkbenchMiniCardID.builtIn)
        XCTAssertEqual(migrated.visibleCards, WorkbenchMiniCardID.defaultVisible)
        XCTAssertTrue(migrated.usesDefaultLayout)
        XCTAssertFalse(migrated.enabled); XCTAssertEqual(migrated.mode, .workbench)
        XCTAssertFalse(migrated.showDate); XCTAssertTrue(migrated.showWeather); XCTAssertTrue(migrated.showSeconds)
        let reversed = Array(legacyOrder.reversed())
        let custom = try decode(order: reversed, visible: legacyOrder.filter { $0 != "memory" })
        XCTAssertEqual(custom.cardOrder.map(\.rawValue), reversed)
        XCTAssertFalse(custom.visibleCards.contains(.memory)); XCTAssertFalse(custom.usesDefaultLayout)
    }
    func testDefaultSourcesFillFourthColumnAndCustomLayoutStopsAutoAdding() throws {
        let provider = WorkbenchMiniCardID.provider(UUID()), balance = WorkbenchMiniCardID.apiBalance(UUID())
        let available = WorkbenchMiniCardID.builtIn + [provider, balance]
        var value = WorkbenchTopEntryPreferences()
        let active = value.activeCards(available: available)
        XCTAssertEqual(active, WorkbenchMiniCardID.defaultVisible + [provider, balance])
        let packed = WorkbenchMiniPacking.pack(active)
        XCTAssertEqual(packed.filter { $0.column == 3 }.map(\.card), [provider, balance])
        XCTAssertEqual(packed.filter { $0.column == 3 }.map(\.span), [3, 3])
        value.materializeLayout(available: available)
        value.setCard(.codex, visible: false)
        try value.validate()
        XCTAssertFalse(value.usesDefaultLayout)
        XCTAssertTrue(value.activeCards(available: available).contains(balance))
        let later = WorkbenchMiniCardID.provider(UUID())
        XCTAssertFalse(value.activeCards(available: available + [later]).contains(later))
        XCTAssertEqual(try JSONDecoder().decode(WorkbenchTopEntryPreferences.self, from: JSONEncoder().encode(value)), value)
    }
    func testMaterializingFullLayoutReclaimsOnlyUnavailableHistoricalSources() throws {
        let oldSources = (0..<(WorkbenchMiniCardID.maximumLayoutCount - WorkbenchMiniCardID.builtIn.count))
            .map { _ in WorkbenchMiniCardID.provider(UUID()) }
        let retained = try XCTUnwrap(oldSources.first)
        let newProvider = WorkbenchMiniCardID.provider(UUID())
        let newBalance = WorkbenchMiniCardID.apiBalance(UUID())
        let available = WorkbenchMiniCardID.builtIn + [retained, newProvider, newBalance]
        var full = WorkbenchTopEntryPreferences()
        full.cardOrder += oldSources
        full.visibleCards = WorkbenchMiniCardID.defaultVisible.filter { $0 != .memory } + oldSources
        try full.validate()
        XCTAssertEqual(full.cardOrder.count, WorkbenchMiniCardID.maximumLayoutCount)

        full.materializeLayout(available: available)

        XCTAssertEqual(full.cardOrder, WorkbenchMiniCardID.builtIn + [retained, newProvider, newBalance])
        XCTAssertEqual(full.activeCards(available: available), WorkbenchMiniCardID.defaultVisible.filter { $0 != .memory } + [retained, newProvider, newBalance])
        XCTAssertFalse(full.visibleCards.contains(.memory), "Capacity recovery must preserve existing hidden choices.")
        XCTAssertTrue(Set(full.visibleCards).isSubset(of: Set(full.cardOrder)))
        XCTAssertLessThanOrEqual(full.cardOrder.count, WorkbenchMiniCardID.maximumLayoutCount)
        try full.validate()
        XCTAssertEqual(try JSONDecoder().decode(WorkbenchTopEntryPreferences.self, from: JSONEncoder().encode(full)), full)

        var withRoom = WorkbenchTopEntryPreferences()
        let temporarilyMissing = oldSources[1]
        withRoom.cardOrder.append(temporarilyMissing)
        withRoom.visibleCards.append(temporarilyMissing)
        withRoom.materializeLayout(available: WorkbenchMiniCardID.builtIn + [newProvider])
        XCTAssertTrue(withRoom.cardOrder.contains(temporarilyMissing), "Available capacity retains absent sources' saved positions.")
        XCTAssertFalse(withRoom.visibleCards.contains(temporarilyMissing))
        XCTAssertTrue(withRoom.visibleCards.contains(newProvider))
        try withRoom.validate()
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
