import Foundation

public enum WorkbenchTopEntryMode: String, Codable, CaseIterable, Sendable {
    case workbench, summary
}

public struct WorkbenchTopEntryPreferences: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var enabled = true
    public var mode: WorkbenchTopEntryMode = .summary
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw LauncherError.storage("顶部入口设置版本无法读取，原文件已保留。") }
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
