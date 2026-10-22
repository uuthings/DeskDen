import XCTest
@testable import LauncherCore

final class DeviceDashboardTests: XCTestCase {
    func testAcceptedV5DefaultPackingMatchesFrozenOrdinaryWindow() {
        let values = DeviceDashboardGrid.placements(.init(), width: 864)
        let frames = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0.frame) })
        XCTAssertEqual(values.count, 8)
        XCTAssertEqual(frames[.profile], CGRect(x: 0, y: 0, width: 280, height: 444))
        XCTAssertEqual(frames[.memory], CGRect(x: 292, y: 0, width: 280, height: 216))
        XCTAssertEqual(frames[.storage], CGRect(x: 584, y: 0, width: 280, height: 216))
        XCTAssertEqual(frames[.thermal], CGRect(x: 292, y: 228, width: 280, height: 216))
        XCTAssertEqual(frames[.traffic], CGRect(x: 584, y: 228, width: 280, height: 216))
        for (index, id) in [DeviceCardID.cpu, .network, .processes].enumerated() {
            XCTAssertEqual(frames[id], CGRect(x: CGFloat(index) * 292, y: 456, width: 280, height: 240))
        }
        XCTAssertEqual(DeviceDashboardGrid.height(.init(), width: 864), 696)
    }
    func testAcceptedV5WideLayoutKeepsSummaryAndProfileSizes() {
        let layout = DeviceDashboardLayout()
        let values = DeviceDashboardGrid.placements(layout, width: 1360, minimumHeight: 800, expanded: true)
        let frames = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0.frame) })
        XCTAssertEqual(frames[.profile]?.height, 444)
        XCTAssertEqual(frames[.profile]!.width, (1360 - 24) / 3, accuracy: 0.001)
        for id in [DeviceCardID.memory, .storage, .thermal, .traffic] { XCTAssertEqual(frames[id]?.height, 216) }
        for id in [DeviceCardID.cpu, .network, .processes] { XCTAssertEqual(frames[id]?.height, 272); XCTAssertEqual(frames[id]?.minY, 456) }
        XCTAssertEqual(values.map(\.frame.maxY).max(), 728)
        let metrics = DeviceDashboardGrid.metrics(layout, width: 1360, minimumHeight: 800, expanded: true)
        XCTAssertEqual(metrics.scale, 1); XCTAssertEqual(metrics.gap, 12)
        XCTAssertEqual(layout, .init())
    }
    func testAcceptedV5CompactProjectionUsesTwoColumnsAndFullWidthProfile() {
        let layout = DeviceDashboardLayout(), values = DeviceDashboardGrid.placements(.init(), width: 736)
        let frames = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0.frame) })
        XCTAssertEqual(frames[.profile], CGRect(x: 0, y: 0, width: 736, height: 224.5))
        XCTAssertEqual(frames[.memory], CGRect(x: 0, y: 236.5, width: 362, height: 216))
        XCTAssertEqual(frames[.storage], CGRect(x: 374, y: 236.5, width: 362, height: 216))
        XCTAssertEqual(frames[.thermal], CGRect(x: 0, y: 464.5, width: 362, height: 216))
        XCTAssertEqual(frames[.traffic], CGRect(x: 374, y: 464.5, width: 362, height: 216))
        XCTAssertEqual(frames[.processes], CGRect(x: 0, y: 944.5, width: 736, height: 240))
        XCTAssertEqual(DeviceDashboardGrid.height(layout, width: 736), 1184.5)
        XCTAssertEqual(layout.cards, DeviceDashboardLayout.defaultCards)
    }
    func testSummaryBandsHaveTwelvePointGapsWithoutRewritingPreferences() {
        let layout = DeviceDashboardLayout()
        for width in [CGFloat(864), CGFloat(1360)] {
            let values = DeviceDashboardGrid.placements(layout, width: width)
            let frames = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0.frame) })
            for id in [DeviceCardID.memory, .storage, .thermal, .traffic] { XCTAssertEqual(frames[id]?.height, DeviceDashboardGrid.summaryHeight) }
            XCTAssertEqual(frames[.memory]?.minY, frames[.storage]?.minY)
            XCTAssertEqual(frames[.thermal]?.minY, frames[.traffic]?.minY)
            XCTAssertEqual(frames[.storage]!.minX - frames[.memory]!.maxX, 12, accuracy: 0.001)
            XCTAssertEqual(frames[.thermal]!.minY - frames[.memory]!.maxY, 12)
            XCTAssertEqual(frames[.cpu]!.minY - frames[.profile]!.maxY, 12)
        }
        XCTAssertEqual(layout.cards, DeviceDashboardLayout.defaultCards)
    }
    func testSummaryCompactionDoesNotShrinkMixedTrendOrExpandedCards() {
        var mixed = DeviceDashboardLayout()
        mixed.cards = [.init(.memory, columns: 3), .init(.cpu, columns: 9)] + mixed.cards.filter { $0.id != .memory && $0.id != .cpu }.map {
            var card = $0; card.visible = false; return card
        }
        let values = DeviceDashboardGrid.placements(mixed, width: 1360, expanded: true)
        XCTAssertEqual(values.first { $0.id == .memory }?.frame.height, 236)
        XCTAssertEqual(values.first { $0.id == .cpu }?.frame.height, 236)
        var expanded = DeviceDashboardLayout()
        expanded.update(.memory) { $0.columns = 6; $0.rows = 5 }
        let before = expanded
        let large = DeviceDashboardGrid.placements(expanded, width: 1360, expanded: true)
        XCTAssertEqual(large.first { $0.id == .memory }?.frame.height, 298)
        XCTAssertEqual(expanded, before)
    }
    func testEveryPresetPacksWithoutOverlapAcrossWindowSizes() {
        for id in DeviceCardID.allCases {
            for size in id.sizes {
                var layout = DeviceDashboardLayout()
                layout.update(id) { $0.columns = size.columns; $0.rows = size.rows }
                for width in stride(from: 320, through: 1600, by: 53) {
                    let values = DeviceDashboardGrid.placements(layout, width: CGFloat(width), minimumHeight: 740)
                    for a in values {
                        XCTAssertGreaterThanOrEqual(a.frame.minX, 0)
                        XCTAssertLessThanOrEqual(a.frame.maxX, CGFloat(width) + 0.001)
                        XCTAssertGreaterThanOrEqual(a.frame.height, a.id == .profile && width > 560 ? 100 : 156)
                        for b in values where a.id != b.id { XCTAssertFalse(a.frame.intersects(b.frame), "\(width): \(id) \(a.id) / \(b.id)") }
                    }
                }
            }
        }
    }
    func testCompactProjectionKeepsPreferencesAndGivesProcessListFullRow() {
        var layout = DeviceDashboardLayout()
        layout.update(.memory) { $0.columns = 6; $0.rows = 5; $0.meter = .ring }
        let before = layout
        let compact = DeviceDashboardGrid.placements(layout, width: 728)
        let process = compact.first { $0.id == .processes }!
        XCTAssertEqual(process.frame.width, 728)
        XCTAssertEqual(DeviceDashboardGrid.renderedColumns(3, width: 728), 6)
        _ = DeviceDashboardGrid.placements(layout, width: 1360, minimumHeight: 740, expanded: true)
        XCTAssertEqual(DeviceDashboardGrid.placements(layout, width: 728), compact)
        XCTAssertEqual(layout, before)
    }
    func testSparseAndTallCustomLayoutsDoNotStretchIndefinitely() {
        var sparse = DeviceDashboardLayout()
        for id in DeviceCardID.allCases where id != .cpu { sparse.update(id) { $0.visible = false } }
        XCTAssertEqual(DeviceDashboardGrid.placements(sparse, width: 1360, minimumHeight: 2000, expanded: true).first?.frame.height, 272)
        var tall = DeviceDashboardLayout()
        for id in DeviceCardID.allCases { tall.update(id) { $0.columns = 12; $0.rows = 9 } }
        let base = DeviceDashboardGrid.height(tall, width: 1360, expanded: true)
        XCTAssertGreaterThan(base, 740)
        XCTAssertEqual(DeviceDashboardGrid.height(tall, width: 1360, minimumHeight: 2000, expanded: true), base)
    }
    func testDiscreteResizePresetsRespectDirectionAndContentMinimums() {
        let normalCPU = DeviceCardPreference(.cpu, columns: 4, rows: 4)
        XCTAssertEqual(DeviceCardID.cpu.resized(from: normalCPU, horizontal: true, growing: true), .init(8, 5, "完整趋势"))
        XCTAssertEqual(DeviceCardID.cpu.resized(from: normalCPU, horizontal: false, growing: true), .init(8, 5, "完整趋势"))
        XCTAssertNil(DeviceCardID.cpu.resized(from: normalCPU, horizontal: true, growing: false))
        XCTAssertEqual(DeviceCardID.thermal.resized(from: .init(.thermal, columns: 3, rows: 4), horizontal: false, growing: false), .init(6, 3, "横向摘要"))
        var layout = DeviceDashboardLayout()
        layout.update(.memory) { $0.columns = 6; $0.rows = 3 }
        XCTAssertTrue(DeviceCardID.memory.sizes.contains { $0.columns == layout.cards[1].columns && $0.rows == layout.cards[1].rows })
    }
    func testInsertionReordersInsteadOfSwapping() {
        var layout = DeviceDashboardLayout()
        layout.move(.cpu, before: .profile)
        XCTAssertEqual(Array(layout.cards.prefix(3).map(\.id)), [.cpu, .profile, .memory])
        layout.move(.cpu, before: .network)
        XCTAssertEqual(layout, DeviceDashboardLayout())
    }
    func testHiddenCardsRetainSizesStyleAndOrder() {
        var layout = DeviceDashboardLayout()
        layout.update(.memory) { $0.columns = 6; $0.rows = 5; $0.meter = .ring; $0.visible = false }
        XCTAssertFalse(DeviceDashboardGrid.placements(layout, width: 1000).contains { $0.id == .memory })
        layout.update(.memory) { $0.visible = true }
        XCTAssertEqual(layout.cards[1], DeviceCardPreference(.memory, columns: 6, rows: 5, meter: .ring))
    }
    func testBoundsClampAndAllHiddenLayout() {
        var layout = DeviceDashboardLayout()
        for id in DeviceCardID.allCases { layout.update(id) { $0.columns = -3; $0.rows = 100; $0.visible = false } }
        XCTAssertNoThrow(try layout.validate())
        XCTAssertTrue(DeviceDashboardGrid.placements(layout, width: 900).isEmpty)
        XCTAssertEqual(DeviceDashboardGrid.height(layout, width: 900), 180)
    }
    func testOldDefaultMigratesAndCustomizedLayoutIsPreserved() throws {
        let old: [DeviceCardPreference] = [.init(.cpu, columns: 7, rows: 3), .init(.thermal, columns: 5, rows: 6), .init(.network, columns: 7, rows: 3), .init(.profile, columns: 3, rows: 3), .init(.memory, columns: 3, rows: 3), .init(.storage, columns: 3, rows: 3), .init(.processes, columns: 3, rows: 3)]
        func decode(_ cards: [DeviceCardPreference]) throws -> DeviceDashboardLayout {
            let object: [String: Any] = ["schemaVersion": 1, "cards": try JSONSerialization.jsonObject(with: JSONEncoder().encode(cards))]
            return try JSONDecoder().decode(DeviceDashboardLayout.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertEqual(try decode(old), DeviceDashboardLayout())
        var customized = old
        customized[4].visible = false; customized[4].meter = .ring; customized[0].columns = 9
        customized.swapAt(0, 2)
        let migrated = try decode(customized)
        XCTAssertEqual(Array(migrated.cards.prefix(7)), customized)
        XCTAssertEqual(migrated.cards.last, .init(.traffic, columns: 3, rows: 4, visible: false))
        XCTAssertEqual(try JSONDecoder().decode(DeviceDashboardLayout.self, from: JSONEncoder().encode(migrated)), migrated)
    }
    func testVersionTwoDefaultMigratesWhileCustomizedPreferencesRemainExact() throws {
        let old: [DeviceCardPreference] = [.init(.profile, columns: 12, rows: 2), .init(.memory, columns: 3), .init(.storage, columns: 3), .init(.thermal, columns: 3), .init(.traffic, columns: 3), .init(.cpu, columns: 4), .init(.network, columns: 4), .init(.processes, columns: 4)]
        func decode(_ cards: [DeviceCardPreference]) throws -> DeviceDashboardLayout {
            let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "cards": try JSONSerialization.jsonObject(with: JSONEncoder().encode(cards))])
            return try JSONDecoder().decode(DeviceDashboardLayout.self, from: data)
        }
        XCTAssertEqual(try decode(old), DeviceDashboardLayout())
        var custom = old
        custom.swapAt(0, 5); custom[1].meter = .ring; custom[2].visible = false
        custom[3].columns = 6; custom[3].rows = 3
        let migrated = try decode(custom)
        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertEqual(migrated.cards, custom)
        XCTAssertEqual(try JSONDecoder().decode(DeviceDashboardLayout.self, from: JSONEncoder().encode(migrated)), migrated)
    }
    func testResizeAnchorsAllFourEdgesAndCorners() {
        let original = CGRect(x: 100, y: 200, width: 300, height: 250)
        for edge in DeviceResizeEdge.allCases {
            let frame = edge.preview(origin: original, delta: CGSize(width: 31, height: 47), minimum: CGSize(width: 100, height: 100), maximum: CGSize(width: 1000, height: 1000))
            if edge.rawValue.contains("w") { XCTAssertEqual(frame.maxX, original.maxX) } else { XCTAssertEqual(frame.minX, original.minX) }
            if edge.rawValue.contains("n") { XCTAssertEqual(frame.maxY, original.maxY) } else { XCTAssertEqual(frame.minY, original.minY) }
            if !edge.horizontal { XCTAssertEqual(frame.width, original.width) }
            if !edge.vertical { XCTAssertEqual(frame.height, original.height) }
        }
    }
    func testResizeLimitsKeepOppositeEdgeStable() {
        let rect = DeviceResizeEdge.nw.preview(origin: CGRect(x: 50, y: 100, width: 300, height: 300), delta: CGSize(width: 900, height: 900), minimum: CGSize(width: 140, height: 180), maximum: CGSize(width: 1200, height: 700))
        XCTAssertEqual(rect, CGRect(x: 210, y: 220, width: 140, height: 180))
    }
    func testStoreRoundTripAndPreviousVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DeviceLayoutStore(url: directory.appendingPathComponent("layout.json"))
        try store.save(.init())
        var changed = DeviceDashboardLayout(); changed.update(.thermal) { $0.columns = 6; $0.rows = 3 }
        try store.save(changed)
        XCTAssertEqual(try store.load(), changed)
        XCTAssertEqual(try JSONDecoder().decode(DeviceDashboardLayout.self, from: Data(contentsOf: store.url.appendingPathExtension("previous"))), DeviceDashboardLayout())
    }
    func testInvalidOrCorruptLayoutCannotOverwriteSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DeviceLayoutStore(url: directory.appendingPathComponent("layout.json")), damaged = Data("damaged fixture".utf8)
        try damaged.write(to: store.url)
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(.init()))
        XCTAssertEqual(try Data(contentsOf: store.url), damaged)
        var duplicate = DeviceDashboardLayout(); duplicate.cards[1] = duplicate.cards[0]
        XCTAssertThrowsError(try duplicate.validate())
    }
    func testSMCDecoderAcceptsRealZeroAndRejectsMalformedValues() {
        XCTAssertEqual(DeviceSensorValue.decode(type: "fpe2", bytes: [0x1C,0x70]), 1820)
        XCTAssertEqual(DeviceSensorValue.decode(type: "fpe2", bytes: [0,0]), 0)
        XCTAssertEqual(DeviceSensorValue.decode(type: "ui8 ", bytes: [0]), 0)
        XCTAssertEqual(DeviceSensorValue.decode(type: "sp78", bytes: [0x36,0x80]), 54.5)
        XCTAssertEqual(DeviceSensorValue.decode(type: "flt ", bytes: [0,0,0x58,0x42]), 54)
        XCTAssertNil(DeviceSensorValue.decode(type: "flt ", bytes: [0,0,0x80,0x7f]))
        XCTAssertNil(DeviceSensorValue.decode(type: "fpe2", bytes: [0]))
        XCTAssertNil(DeviceSensorValue.decode(type: "invalid", bytes: [0,1,2,3]))
    }
}
