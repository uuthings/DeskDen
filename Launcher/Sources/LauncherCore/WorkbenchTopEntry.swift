import Foundation

public enum WorkbenchTopEntryMode: String, Codable, CaseIterable, Sendable {
    case workbench, summary
}

public enum WorkbenchMiniSection: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case context, agenda, device, ai
    public var id: String { rawValue }
}

/// Built-in cards and independently configured provider sources share stable
/// identifiers. A deleted provider can be absent without rewriting the layout.
public struct WorkbenchMiniCardID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public var rawValue: String
    public var id: String { rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let codex = Self(rawValue: "codex")
    public static let claude = Self(rawValue: "claude")
    public static let traffic = Self(rawValue: "traffic")
    public static let disk = Self(rawValue: "disk")
    public static let memory = Self(rawValue: "memory")
    public static let todo = Self(rawValue: "todo")
    public static let network = Self(rawValue: "network")
    public static let thermal = Self(rawValue: "thermal")
    public static let builtIn: [Self] = [.codex, .claude, .traffic, .disk, .memory, .todo, .network, .thermal]
    /// Leaves room for all configured sources and retained positions of removed
    /// sources, while keeping the serialized layout below the store size limit.
    public static let maximumLayoutCount = 256
    public static func provider(_ id: UUID) -> Self { .init(rawValue: "provider:" + id.uuidString.lowercased()) }
    public var providerID: UUID? {
        guard rawValue.hasPrefix("provider:") else { return nil }
        return UUID(uuidString: String(rawValue.dropFirst(9)))
    }
    public var isValid: Bool { Self.builtIn.contains(self) || providerID.map { Self.provider($0) == self } == true }
    /// Six units fit one column: three small cards or two medium cards.
    public var span: Int { self == .network || self == .thermal ? 3 : 2 }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
}

public struct WorkbenchMiniPlacement: Equatable, Sendable {
    public var card: WorkbenchMiniCardID
    public var column: Int
    public var row: Int
    public var span: Int { card.span }
}

/// Exact small/medium bin packing, preferring earlier cards and earlier columns.
/// Memoized symmetric states keep arbitrary user orders bounded and deterministic.
public enum WorkbenchMiniPacking {
    public static func pack(_ cards: [WorkbenchMiniCardID]) -> [WorkbenchMiniPlacement] {
        guard !cards.isEmpty, cards.count <= WorkbenchMiniCardID.maximumLayoutCount else { return [] }
        let total = cards.reduce(0) { $0 + $1.span }
        for count in max(1, (total + 5) / 6)...cards.count {
            var bins = Array(repeating: [WorkbenchMiniCardID](), count: count)
            var used = Array(repeating: 0, count: count)
            var failed = Set<String>()
            func place(_ index: Int) -> Bool {
                if index == cards.count { return true }
                let key = "\(index):" + used.sorted().map(String.init).joined(separator: ",")
                if failed.contains(key) { return false }
                let card = cards[index]
                var tried = Set<Int>()
                for column in bins.indices where used[column] + card.span <= 6 {
                    guard tried.insert(used[column]).inserted else { continue }
                    bins[column].append(card); used[column] += card.span
                    if place(index + 1) { return true }
                    used[column] -= card.span; bins[column].removeLast()
                }
                failed.insert(key)
                return false
            }
            if place(0) {
                return bins.enumerated().flatMap { column, cards -> [WorkbenchMiniPlacement] in
                    var row = 0
                    return cards.map { card in
                        defer { row += card.span }
                        return .init(card: card, column: column, row: row)
                    }
                }
            }
        }
        return []
    }
}

public struct WorkbenchTopEntryPreferences: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var enabled = true
    public var mode: WorkbenchTopEntryMode = .summary
    public var cardOrder = WorkbenchMiniCardID.builtIn
    public var visibleCards = WorkbenchMiniCardID.builtIn
    public var showDate = true
    public var showWeather = true
    public var showSeconds = false
    /// Compatibility for callers that still expose the earlier four groups.
    public var visibleSections: [WorkbenchMiniSection] {
        get {
            WorkbenchMiniSection.allCases.filter { section in
                switch section {
                case .context: showDate || showWeather
                case .agenda: visibleCards.contains(.todo)
                case .device: visibleCards.contains { [.traffic, .disk, .memory, .network, .thermal].contains($0) }
                case .ai: visibleCards.contains { $0 == .codex || $0 == .claude || $0.providerID != nil }
                }
            }
        }
        set {
            showDate = newValue.contains(.context); showWeather = showDate
            visibleCards = cardOrder.filter { card in
                if card == .todo { return newValue.contains(.agenda) }
                if card == .codex || card == .claude || card.providerID != nil { return newValue.contains(.ai) }
                return newValue.contains(.device)
            }
        }
    }
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, enabled, mode, visibleSections, cardOrder, visibleCards, showDate, showWeather, showSeconds
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard (1...2).contains(version) else { throw LauncherError.storage("顶部入口设置版本无法读取，原文件已保留。") }
        enabled = try values.decode(Bool.self, forKey: .enabled)
        mode = try values.decode(WorkbenchTopEntryMode.self, forKey: .mode)
        // This additive field keeps existing enabled/mode choices intact. An
        // explicit empty array means every section is hidden, not missing setup.
        if version == 1 {
            let sections = values.contains(.visibleSections)
                ? try values.decode([WorkbenchMiniSection].self, forKey: .visibleSections)
                : WorkbenchMiniSection.allCases
            guard Set(sections).count == sections.count else { throw LauncherError.storage("迷你信息显示设置包含重复项目，原文件已保留。") }
            visibleSections = sections
        } else {
            cardOrder = try values.decode([WorkbenchMiniCardID].self, forKey: .cardOrder)
            visibleCards = try values.decode([WorkbenchMiniCardID].self, forKey: .visibleCards)
            showDate = try values.decode(Bool.self, forKey: .showDate)
            showWeather = try values.decode(Bool.self, forKey: .showWeather)
        }
        showSeconds = try values.decodeIfPresent(Bool.self, forKey: .showSeconds) ?? false
        schemaVersion = 2
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(mode, forKey: .mode)
        try values.encode(cardOrder, forKey: .cardOrder)
        try values.encode(visibleCards, forKey: .visibleCards)
        try values.encode(showDate, forKey: .showDate)
        try values.encode(showWeather, forKey: .showWeather)
        try values.encode(showSeconds, forKey: .showSeconds)
    }
    public func validate() throws {
        guard schemaVersion == 2 else { throw LauncherError.storage("顶部入口设置版本无法读取，原文件已保留。") }
        guard cardOrder.count <= WorkbenchMiniCardID.maximumLayoutCount, Set(cardOrder).count == cardOrder.count,
              cardOrder.allSatisfy(\.isValid), Set(WorkbenchMiniCardID.builtIn).isSubset(of: Set(cardOrder)),
              Set(visibleCards).count == visibleCards.count, Set(visibleCards).isSubset(of: Set(cardOrder)) else {
            throw LauncherError.storage("迷你信息显示设置包含重复项目，原文件已保留。")
        }
    }
    public func activeCards(available: [WorkbenchMiniCardID]) -> [WorkbenchMiniCardID] {
        let selected = Set(visibleCards), valid = Set(available)
        return cardOrder.filter { selected.contains($0) && valid.contains($0) }
    }
    public mutating func setCard(_ card: WorkbenchMiniCardID, visible: Bool) {
        guard card.isValid else { return }
        if !cardOrder.contains(card), cardOrder.count < WorkbenchMiniCardID.maximumLayoutCount { cardOrder.append(card) }
        visibleCards.removeAll { $0 == card }
        if visible, cardOrder.contains(card) { visibleCards.append(card) }
    }
    public mutating func moveCard(_ card: WorkbenchMiniCardID, relativeTo target: WorkbenchMiniCardID, after: Bool) {
        guard card != target, cardOrder.contains(card), cardOrder.contains(target) else { return }
        cardOrder.removeAll { $0 == card }
        guard let index = cardOrder.firstIndex(of: target) else { return }
        cardOrder.insert(card, at: index + (after ? 1 : 0))
    }
}

public struct WorkbenchTopEntryStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> WorkbenchTopEntryPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let data = try Data(contentsOf: url)
        guard data.count < 65_536 else { throw LauncherError.storage("顶部入口设置过大，原文件已保留。") }
        let preferences = try JSONDecoder().decode(WorkbenchTopEntryPreferences.self, from: data)
        try preferences.validate()
        return preferences
    }
    public func save(_ preferences: WorkbenchTopEntryPreferences) throws {
        try preferences.validate()
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if manager.fileExists(atPath: url.path) { _ = try load() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// A short dwell distinguishes a deliberate hover from merely crossing the top edge.
/// Once fired or inhibited inside the zone, the pointer must leave before rearming.
public struct WorkbenchTopEntryGate: Sendable {
    public static let dwell: TimeInterval = 0.12
    private var armed = false
    private var enteredAt: TimeInterval?
    public init() {}
    /// Invisible intent confirmation. It never adds a separate expansion stage.
    public var isDwelling: Bool { armed && enteredAt != nil }
    public mutating func reset() { armed = false; enteredAt = nil }
    public mutating func update(inside: Bool, allowed: Bool, at time: TimeInterval) -> Bool {
        guard time.isFinite else { reset(); return false }
        guard inside else { armed = true; enteredAt = nil; return false }
        guard allowed else { reset(); return false }
        guard armed else { return false }
        guard let enteredAt else { self.enteredAt = time; return false }
        guard time >= enteredAt else { self.enteredAt = time; return false }
        guard time - enteredAt >= Self.dwell else { return false }
        reset()
        return true
    }

    public static func activationRect(screen: CGRect, safeTop: CGFloat, notchWidth: CGFloat?) -> CGRect {
        let inset = safeTop.isFinite ? max(0, min(safeTop, 80)) : 0
        let requestedWidth = notchWidth.flatMap { $0.isFinite && $0 > 0 ? $0 + 20 : nil } ?? 200
        let width = min(screen.width, max(180, min(300, requestedWidth)))
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - inset - 8, width: width, height: inset + 8)
    }

    /// AppKit may report a pointer flush with the display at exactly screen.maxY.
    /// CGRect.contains excludes that boundary, but the physical top edge belongs to this zone.
    public static func contains(_ point: CGPoint, in activationRect: CGRect) -> Bool {
        point.x.isFinite && point.y.isFinite
            && point.x >= activationRect.minX && point.x <= activationRect.maxX
            && point.y >= activationRect.minY && point.y <= activationRect.maxY
    }
}
