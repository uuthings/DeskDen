import Foundation

public struct DeviceCardSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let title: String
    public init(_ columns: Int, _ rows: Int, _ title: String) { self.columns = columns; self.rows = rows; self.title = title }
}
public enum DeviceCardID: String, Codable, CaseIterable, Sendable {
    case cpu, thermal, network, traffic, profile, memory, storage, processes
    public var title: String {
        switch self { case .cpu: "CPU 使用率"; case .thermal: "散热与供电"; case .network: "网络速度"; case .traffic: "今日流量"; case .profile: "设备档案"; case .memory: "统一内存"; case .storage: "存储空间"; case .processes: "活跃进程" }
    }
    public var symbol: String {
        switch self { case .cpu: "cpu"; case .thermal: "fan"; case .network: "arrow.up.arrow.down"; case .traffic: "chart.bar"; case .profile: "laptopcomputer"; case .memory: "memorychip"; case .storage: "internaldrive"; case .processes: "macwindow" }
    }
    public var summary: String {
        switch self { case .cpu: "整机使用率与负载趋势"; case .thermal: "温度、风扇、供电与温度提醒"; case .network: "上下行速率与实时趋势"; case .traffic: "实时网速与今日已记录流量"; case .profile: "型号、芯片与硬件信息"; case .memory: "占用、可用与内存压力"; case .storage: "可用空间、已用容量与卷信息"; case .processes: "高占用进程与资源快照" }
    }
    public var sizes: [DeviceCardSize] {
        switch self {
        case .profile: [.init(4, 4, "紧凑档案"), .init(4, 8, "完整档案"), .init(12, 4, "横向档案"), .init(12, 3, "设备横条"), .init(12, 2, "信息条")]
        case .memory, .storage: [.init(4, 4, "摘要"), .init(6, 5, "展开信息")]
        case .thermal: [.init(4, 4, "摘要"), .init(6, 3, "横向摘要")]
        case .traffic: [.init(4, 4, "今日摘要"), .init(6, 4, "宽幅摘要")]
        case .cpu: [.init(4, 4, "趋势"), .init(6, 4, "宽幅趋势"), .init(8, 5, "完整趋势")]
        case .network: [.init(4, 4, "趋势"), .init(6, 5, "完整趋势")]
        case .processes: [.init(4, 4, "摘要"), .init(6, 4, "宽幅列表"), .init(6, 5, "扩展列表")]
        }
    }
    public var minimumColumns: Int { sizes.map(\.columns).min()! }
    public var minimumRows: Int { sizes.map(\.rows).min()! }
    public var maximumRows: Int { sizes.map(\.rows).max()! }
    public var supportsMeterStyle: Bool { self == .memory || self == .storage }
    /// One deliberate resize step, shared by edge gestures and keyboard controls.
    public func resized(from current: DeviceCardPreference, horizontal: Bool, growing: Bool) -> DeviceCardSize? {
        let original = horizontal ? current.columns : current.rows
        return sizes.filter { growing ? (horizontal ? $0.columns : $0.rows) > original : (horizontal ? $0.columns : $0.rows) < original }
            .min { abs((horizontal ? $0.columns : $0.rows) - original) < abs((horizontal ? $1.columns : $1.rows) - original) }
    }
}
public enum DeviceMeterStyle: String, Codable, CaseIterable, Sendable { case bar, ring }
public struct DeviceCardPreference: Codable, Equatable, Identifiable, Sendable {
    public var id: DeviceCardID
    public var columns: Int
    public var rows: Int
    public var visible: Bool
    public var meter: DeviceMeterStyle
    public init(_ id: DeviceCardID, columns: Int, rows: Int = 4, visible: Bool = true, meter: DeviceMeterStyle = .bar) {
        self.id = id; self.columns = columns; self.rows = rows; self.visible = visible; self.meter = meter
    }
}
public struct DeviceDashboardLayout: Codable, Equatable, Sendable {
    public var schemaVersion = 4
    public var cards: [DeviceCardPreference]
    public static var defaultCards: [DeviceCardPreference] {
        [.init(.profile, columns: 12, rows: 3), .init(.memory, columns: 4), .init(.storage, columns: 4), .init(.thermal, columns: 4), .init(.cpu, columns: 6), .init(.processes, columns: 6), .init(.traffic, columns: 4, visible: false), .init(.network, columns: 4, visible: false)]
    }
    private static var versionThreeDefault: [DeviceCardPreference] {
        [.init(.profile, columns: 4, rows: 8), .init(.memory, columns: 4), .init(.storage, columns: 4), .init(.thermal, columns: 4), .init(.traffic, columns: 4), .init(.cpu, columns: 4), .init(.network, columns: 4), .init(.processes, columns: 4)]
    }
    private static var versionTwoDefault: [DeviceCardPreference] {
        [.init(.profile, columns: 12, rows: 2), .init(.memory, columns: 3), .init(.storage, columns: 3), .init(.thermal, columns: 3), .init(.traffic, columns: 3), .init(.cpu, columns: 4), .init(.network, columns: 4), .init(.processes, columns: 4)]
    }
    private static var previousDefault: [DeviceCardPreference] {
        [.init(.cpu, columns: 7, rows: 3), .init(.thermal, columns: 5, rows: 6), .init(.network, columns: 7, rows: 3), .init(.profile, columns: 3, rows: 3), .init(.memory, columns: 3, rows: 3), .init(.storage, columns: 3, rows: 3), .init(.processes, columns: 3, rows: 3)]
    }
    public init(cards: [DeviceCardPreference] = Self.defaultCards) { self.cards = cards }
    private enum CodingKeys: String, CodingKey { case schemaVersion, cards }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        let decoded = try container.decode([DeviceCardPreference].self, forKey: .cards)
        guard (1...4).contains(version) else { throw LauncherError.storage("设备卡片布局版本暂不支持，原文件已保留。") }
        if version == 1 {
            let oldIDs = Set(DeviceCardID.allCases.filter { $0 != .traffic })
            guard decoded.count == oldIDs.count, Set(decoded.map(\.id)) == oldIDs,
                  decoded.allSatisfy({ (3...12).contains($0.columns) && (3...9).contains($0.rows) }) else { throw LauncherError.storage("旧版设备卡片布局格式无效，原文件已保留。") }
            // Preserve custom order, sizes, visibility and meter style. A new optional card is
            // hidden on customized layouts so migration does not unexpectedly rearrange them.
            cards = decoded == Self.previousDefault ? Self.defaultCards : decoded + [.init(.traffic, columns: 3, visible: false)]
        } else if version == 2, decoded == Self.versionTwoDefault {
            cards = Self.defaultCards
        } else if version == 3, decoded == Self.versionThreeDefault {
            cards = Self.defaultCards
        } else { cards = decoded }
        schemaVersion = 4
        try validate()
    }
    public func validate() throws {
        guard schemaVersion == 4, cards.count == DeviceCardID.allCases.count,
              Set(cards.map(\.id)) == Set(DeviceCardID.allCases),
              cards.allSatisfy({ (3...12).contains($0.columns) && (2...9).contains($0.rows) }) else {
            throw LauncherError.storage("设备卡片布局格式无效，原文件已保留。")
        }
    }
    public mutating func move(_ id: DeviceCardID, before target: DeviceCardID, after: Bool = false) {
        guard id != target, let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let card = cards.remove(at: index)
        guard let destination = cards.firstIndex(where: { $0.id == target }) else { cards.insert(card, at: index); return }
        cards.insert(card, at: destination + (after ? 1 : 0))
    }
    public mutating func update(_ id: DeviceCardID, _ change: (inout DeviceCardPreference) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let original = cards[index]; change(&cards[index])
        if original.columns != cards[index].columns || original.rows != cards[index].rows {
            let requested = cards[index]
            let size = id.sizes.min { a, b in
                abs(a.columns - requested.columns) + abs(a.rows - requested.rows) * 2 < abs(b.columns - requested.columns) + abs(b.rows - requested.rows) * 2
            }!
            cards[index].columns = size.columns; cards[index].rows = size.rows
        }
    }
}
public struct DeviceCardPlacement: Equatable, Sendable {
    public var id: DeviceCardID
    public var frame: CGRect
    public var column: Int
    public var row: Int
}
/// Twelve logical columns; compact projections and useful chart expansion never mutate preferences.
public enum DeviceDashboardGrid {
    public static let gap: CGFloat = 12
    public static let rowHeight: CGFloat = 44
    public static let summaryHeight: CGFloat = 200
    public static let compactProfileHeight: CGFloat = 224.5
    public struct Metrics: Equatable, Sendable {
        public let scale: CGFloat
        public let gap: CGFloat
        public let rowHeight: CGFloat
        public let columnStep: CGFloat
        public let expanded: Bool
        public let rowHeights: [CGFloat]
        public var rowStep: CGFloat { rowHeight + gap }
        func y(at row: Int) -> CGFloat { (0..<row).reduce(0) { $0 + (rowHeights.indices.contains($1) ? rowHeights[$1] : rowHeight) + gap } }
        func height(row: Int, rows: Int) -> CGFloat { (row..<(row + rows)).reduce(0) { $0 + (rowHeights.indices.contains($1) ? rowHeights[$1] : rowHeight) } + CGFloat(rows - 1) * gap }
    }
    private struct PackedCard { let id: DeviceCardID; let column: Int; let row: Int; let columns: Int; let rows: Int }
    public static func renderedColumns(_ columns: Int, width: CGFloat, scale: CGFloat = 1) -> Int {
        width < 520 ? 12 : width < 840 ? min(12, Int(ceil(Double(columns) / 6)) * 6) : columns
    }
    public static func metrics(_ layout: DeviceDashboardLayout, width: CGFloat, scale: CGFloat = 1, minimumHeight: CGFloat = 0, expanded: Bool? = nil) -> Metrics {
        let wide = expanded ?? (width >= 1100), gap = Self.gap, row: CGFloat = wide ? 50 : 44
        let cards = packed(layout, width: width)
        let rows = cards.map { $0.row + $0.rows }.max() ?? 0
        var heights = Array(repeating: row, count: rows)
        let summaries: Set<DeviceCardID> = [.memory, .storage, .thermal, .traffic]
        // Logical row spans preserve saved layouts. Summary bands use one shared
        // height; expansion is reserved for trend and process content.
        let useful: Set<DeviceCardID> = [.cpu, .network, .processes]
        for y in 0..<rows {
            let occupants = cards.filter { $0.row <= y && y < $0.row + $0.rows }
            guard !occupants.isEmpty else { continue }
            if occupants.count == 1, let card = occupants.first, card.id == .profile, card.columns == 12, card.rows == 3 {
                heights[y] = 44
            } else if occupants.allSatisfy({ ($0.id == .profile && $0.columns == 4 && $0.rows == 8) || (summaries.contains($0.id) && $0.rows == 4) }) {
                heights[y] = (summaryHeight - 3 * gap) / 4
            } else if width < 840, occupants.count == 1, let card = occupants.first,
                      card.id == .profile, card.rows == 4,
                      layout.cards.contains(where: { $0.id == .profile && $0.columns == 4 && $0.rows == 8 }) {
                heights[y] = (compactProfileHeight - 3 * gap) / 4
            } else if occupants.allSatisfy({ useful.contains($0.id) && $0.rows == 4 }) {
                heights[y] = ((wide ? 272 : 240) - 3 * gap) / 4
            }
        }
        return Metrics(scale: 1, gap: gap, rowHeight: row, columnStep: ((width.isFinite ? max(0, width) : 0) + gap) / 12, expanded: wide, rowHeights: heights)
    }
    private static func packed(_ layout: DeviceDashboardLayout, width: CGFloat) -> [PackedCard] {
        guard width.isFinite, width > 0 else { return [] }
        var occupied = Set<Int>(), result: [PackedCard] = []
        for card in layout.cards where card.visible {
            let compactProfile = width < 840 && card.id == .profile && card.columns == 4 && card.rows == 8
            let columns = width < 840 && (card.id == .processes || compactProfile) ? 12 : renderedColumns(card.columns, width: width)
            // Legacy short cards retain their saved size, but receive a readable projection.
            let rows = compactProfile ? 4 : card.id == .profile && columns >= 8 && width > 560 ? max(2, card.rows) : card.id == .profile && card.rows == 3 ? 6 : card.id == .thermal && columns >= 6 ? max(3, card.rows) : max(4, card.rows)
            var row = 0, column = 0
            search: for y in 0..<120 {
                for x in 0...(12 - columns) {
                    let free = (y..<(y + rows)).allSatisfy { yy in (x..<(x + columns)).allSatisfy { xx in !occupied.contains(yy * 12 + xx) } }
                    if free { row = y; column = x; break search }
                }
            }
            for y in row..<(row + rows) { for x in column..<(column + columns) { occupied.insert(y * 12 + x) } }
            result.append(PackedCard(id: card.id, column: column, row: row, columns: columns, rows: rows))
        }
        return result
    }
    public static func placements(_ layout: DeviceDashboardLayout, width: CGFloat, scale: CGFloat = 1, minimumHeight: CGFloat = 0, expanded: Bool? = nil) -> [DeviceCardPlacement] {
        placements(layout, width: width, metrics: metrics(layout, width: width, scale: scale, minimumHeight: minimumHeight, expanded: expanded))
    }
    public static func placements(_ layout: DeviceDashboardLayout, width: CGFloat, metrics: Metrics) -> [DeviceCardPlacement] {
        packed(layout, width: width).map { card in
            .init(id: card.id, frame: CGRect(x: CGFloat(card.column) * metrics.columnStep, y: metrics.y(at: card.row), width: CGFloat(card.columns) * metrics.columnStep - metrics.gap, height: metrics.height(row: card.row, rows: card.rows)), column: card.column, row: card.row)
        }
    }
    public static func height(_ layout: DeviceDashboardLayout, width: CGFloat, scale: CGFloat = 1, minimumHeight: CGFloat = 0, expanded: Bool? = nil) -> CGFloat {
        placements(layout, width: width, scale: scale, minimumHeight: minimumHeight, expanded: expanded).map(\.frame.maxY).max() ?? 180
    }
}
public struct DeviceLayoutStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> DeviceDashboardLayout {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let data = try Data(contentsOf: url)
        guard data.count < 65_536 else { throw LauncherError.storage("设备布局文件过大，原文件已保留。") }
        let layout = try JSONDecoder().decode(DeviceDashboardLayout.self, from: data); try layout.validate(); return layout
    }
    public func save(_ layout: DeviceDashboardLayout) throws {
        try layout.validate()
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: url.path) {
            _ = try load()
            try Data(contentsOf: url).write(to: url.appendingPathExtension("previous"), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.appendingPathExtension("previous").path)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(layout).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// SMC scalar decoding is kept separate from the read-only IOKit transport for deterministic testing.
public enum DeviceSensorValue {
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        let result: Double
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            result = Double(Float(bitPattern: bits))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            result = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }; result = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ": guard let byte = bytes.first else { return nil }; result = Double(byte)
        case "ui16": guard bytes.count >= 2 else { return nil }; result = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32": guard bytes.count >= 4 else { return nil }; result = Double(bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default: return nil
        }
        return result.isFinite ? result : nil
    }
}

public enum DeviceResizeEdge: String, CaseIterable, Sendable {
    case n, s, e, w, ne, nw, se, sw
    public var horizontal: Bool { rawValue.contains("e") || rawValue.contains("w") }
    public var vertical: Bool { rawValue.contains("n") || rawValue.contains("s") }
    public func preview(origin: CGRect, delta: CGSize, minimum: CGSize, maximum: CGSize) -> CGRect {
        let west = rawValue.contains("w"), north = rawValue.contains("n")
        let width = horizontal ? min(maximum.width, max(minimum.width, origin.width + delta.width * (west ? -1 : 1))) : origin.width
        let height = vertical ? min(maximum.height, max(minimum.height, origin.height + delta.height * (north ? -1 : 1))) : origin.height
        return CGRect(x: west ? origin.maxX - width : origin.minX, y: north ? origin.maxY - height : origin.minY, width: width, height: height)
    }
}
