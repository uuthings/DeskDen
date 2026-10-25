import Foundation

/// Memory-only metering metadata. No source text is retained.
public struct AIUsageParsedFile: Sendable {
    public var records: [AITokenRecord]
    public var snapshots: [AIQuotaSnapshot]
    public var capacityLimited: Bool
    public init(records: [AITokenRecord], snapshots: [AIQuotaSnapshot], capacityLimited: Bool = false) {
        self.records = records; self.snapshots = snapshots; self.capacityLimited = capacityLimited
    }
    public func retained(at now: Date) -> Self {
        let cutoff = now.addingTimeInterval(-Double(AITokenLedger.retentionDays) * 86_400)
        return .init(records: records.filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(300) },
                     snapshots: snapshots.filter { $0.observedAt >= cutoff && $0.observedAt <= now.addingTimeInterval(300) },
                     capacityLimited: capacityLimited)
    }
}

/// The cost is a conservative metadata budget, not a measurement of process RSS.
/// Entry count, record count and estimated bytes all have independent limits.
public struct AIUsageParseCache: Sendable {
    private struct Entry: Sendable {
        var size: Int
        var modified: Date
        var value: AIUsageParsedFile
        var cost: Int
        var access: UInt64
    }
    private var entries: [String: Entry] = [:]
    private var access: UInt64 = 0
    public let maximumEntries: Int
    public let maximumCost: Int
    public let maximumItems: Int
    public var count: Int { entries.count }
    public var estimatedBytes: Int { entries.values.reduce(0) { $0 + $1.cost } }
    public var itemCount: Int { entries.values.reduce(0) { $0 + $1.value.records.count + $1.value.snapshots.count } }
    public init(maximumEntries: Int = 400, maximumCost: Int = 16 * 1_024 * 1_024, maximumItems: Int = 28_000) {
        self.maximumEntries = max(0, maximumEntries); self.maximumCost = max(0, maximumCost); self.maximumItems = max(0, maximumItems)
    }
    public mutating func value(for key: String, size: Int, modified: Date, now: Date) -> AIUsageParsedFile? {
        guard var entry = entries[key] else { return nil }
        guard entry.size == size, entry.modified == modified else { entries.removeValue(forKey: key); return nil }
        entry.value = entry.value.retained(at: now)
        entry.cost = Self.cost(key: key, value: entry.value)
        access &+= 1; entry.access = access; entries[key] = entry
        return entry.value
    }
    public mutating func insert(_ value: AIUsageParsedFile, for key: String, size: Int, modified: Date, now: Date) {
        entries.removeValue(forKey: key)
        let value = value.retained(at: now), cost = Self.cost(key: key, value: value)
        guard maximumEntries > 0, cost <= maximumCost, value.records.count + value.snapshots.count <= maximumItems else { return }
        access &+= 1
        entries[key] = .init(size: size, modified: modified, value: value, cost: cost, access: access)
        while entries.count > maximumEntries || estimatedBytes > maximumCost || itemCount > maximumItems {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            entries.removeValue(forKey: oldest)
        }
    }
    /// Only files actually eligible in the current authorized scan survive.
    /// Deleted files, changed roots, disabled sources and expired files disappear.
    public mutating func retain(keys: Set<String>, now: Date) {
        let cutoff = now.addingTimeInterval(-Double(AITokenLedger.retentionDays) * 86_400)
        entries = entries.filter { keys.contains($0.key) && $0.value.modified >= cutoff }
        for key in Array(entries.keys) {
            guard var entry = entries[key] else { continue }
            entry.value = entry.value.retained(at: now); entry.cost = Self.cost(key: key, value: entry.value)
            entries[key] = entry
        }
    }
    private static func cost(key: String, value: AIUsageParsedFile) -> Int {
        key.utf8.count + 256 + value.snapshots.count * 512 + value.records.reduce(0) { $0 + 256 + $1.id.utf8.count + $1.model.utf8.count }
    }
}
