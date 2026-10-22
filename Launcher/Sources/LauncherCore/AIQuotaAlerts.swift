import Foundation

public struct AIQuotaAlertRule: Codable, Equatable, Sendable {
    public var enabled = false
    public var warningPercent = 75
    public var criticalPercent = 90
    public init() {}
    public func validate() throws {
        guard (1...99).contains(warningPercent), (1...99).contains(criticalPercent), warningPercent < criticalPercent else {
            throw AIUsageError.invalid("请设置递增且在 1–99% 之间的额度提醒阈值。")
        }
    }
}

public enum AIQuotaAlertLevel: Int, Codable, Comparable, Sendable {
    case warning = 1, critical = 2
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A window is identified by the provider's duration and reset instant, never
/// by a guessed Token conversion or the slot in which an API returns it.
public struct AIQuotaWindowIdentity: Codable, Hashable, Sendable {
    public var provider: AIProvider
    public var durationMinutes: Int
    public var resetsAt: Date?
    public init(provider: AIProvider, durationMinutes: Int, resetsAt: Date?) {
        self.provider = provider; self.durationMinutes = durationMinutes; self.resetsAt = resetsAt
    }
    public var id: String { provider.rawValue + ":" + String(durationMinutes) + ":" + (resetsAt.map { String($0.timeIntervalSince1970) } ?? "unknown-reset") }
    public var title: String { durationMinutes == 10_080 ? "每周额度" : durationMinutes % 60 == 0 ? "\(durationMinutes / 60) 小时额度" : "\(durationMinutes) 分钟额度" }
    fileprivate func validate() throws {
        guard (1...525_600).contains(durationMinutes), resetsAt.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 }) ?? true else {
            throw AIUsageError.invalid("额度窗口身份无效。")
        }
    }
}

public struct AIQuotaAlertEvent: Equatable, Identifiable, Sendable {
    public var window: AIQuotaWindowIdentity
    public var level: AIQuotaAlertLevel
    public var threshold: Int
    public var usedPercent: Double
    public var observedAt: Date
    public var source: AIQuotaSource
    public var id: String { "fangcun-ai:" + window.id + ":" + String(level.rawValue) }
    public var provider: AIProvider { window.provider }
}

public struct AIQuotaAlertDelivery: Codable, Equatable, Sendable {
    public var window: AIQuotaWindowIdentity
    public var level: AIQuotaAlertLevel
    public var deliveredAt: Date
}

public struct AIQuotaAlertState: Codable, Equatable, Sendable {
    public var deliveries: [AIQuotaAlertDelivery] = []
    public init() {}
    public func validate() throws {
        guard deliveries.count <= 128, Set(deliveries.map { $0.window }).count == deliveries.count else {
            throw AIUsageError.invalid("额度提醒状态过多或重复，原文件已保留。")
        }
        for delivery in deliveries {
            try delivery.window.validate()
            guard delivery.deliveredAt.timeIntervalSince1970.isFinite, delivery.deliveredAt.timeIntervalSince1970 > 0 else {
                throw AIUsageError.invalid("额度提醒投递时间无效。")
            }
        }
    }
}

/// Evaluation is read-only. The caller acknowledges only successfully delivered
/// events, so denied permission or a transient delivery failure cannot consume a
/// threshold. Unknown-reset sources remain deduplicated until a reset is known.
public struct AIQuotaAlertEvaluator: Sendable {
    public var state: AIQuotaAlertState
    public init(state: AIQuotaAlertState = .init()) { self.state = state }

    public func pendingEvents(rule: AIQuotaAlertRule, summaries: [AIProviderSummary], at now: Date) -> [AIQuotaAlertEvent] {
        guard rule.enabled, (try? rule.validate()) != nil, now.timeIntervalSince1970.isFinite else { return [] }
        var events: [AIQuotaAlertEvent] = [], seen = Set<AIQuotaWindowIdentity>()
        for summary in summaries {
            guard summary.state == .ready, let snapshot = summary.snapshot, summary.provider == snapshot.provider,
                  snapshot.observedAt <= now, now.timeIntervalSince(snapshot.observedAt) <= 900,
                  (try? snapshot.validate(now: now)) != nil else { continue }
            for window in [snapshot.shortWindow, snapshot.weeklyWindow].compactMap({ $0 }) {
                let identity = AIQuotaWindowIdentity(provider: summary.provider, durationMinutes: window.durationMinutes, resetsAt: window.resetsAt)
                guard (try? identity.validate()) != nil, seen.insert(identity).inserted,
                      window.resetsAt.map({ $0 > now }) ?? true else { continue }
                let level: AIQuotaAlertLevel
                let threshold: Int
                if window.usedPercent >= Double(rule.criticalPercent) { level = .critical; threshold = rule.criticalPercent }
                else if window.usedPercent >= Double(rule.warningPercent) { level = .warning; threshold = rule.warningPercent }
                else { continue }
                if let old = state.deliveries.first(where: { $0.window == identity }), old.level >= level { continue }
                events.append(.init(window: identity, level: level, threshold: threshold, usedPercent: window.usedPercent, observedAt: snapshot.observedAt, source: snapshot.source))
            }
        }
        return events
    }

    public mutating func recordDelivery(_ event: AIQuotaAlertEvent, at now: Date) {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0,
              event.observedAt <= now, now.timeIntervalSince(event.observedAt) <= 900,
              event.usedPercent.isFinite, (0...100).contains(event.usedPercent),
              (1...99).contains(event.threshold), event.usedPercent >= Double(event.threshold),
              (try? event.window.validate()) != nil else { return }
        let deliveredLevel = max(event.level, state.deliveries.first(where: { $0.window == event.window })?.level ?? event.level)
        state.deliveries.removeAll { delivery in
            if delivery.window == event.window { return true }
            if let reset = delivery.window.resetsAt { return reset <= now }
            return false
        }
        state.deliveries.append(.init(window: event.window, level: deliveredLevel, deliveredAt: now))
        if state.deliveries.count > 128 { state.deliveries = Array(state.deliveries.sorted { $0.deliveredAt < $1.deliveredAt }.suffix(128)) }
    }
}

public struct AIQuotaAlertConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var rule = AIQuotaAlertRule()
    public var state = AIQuotaAlertState()
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw AIUsageError.invalid("额度提醒格式来自更新版本，原文件已保留。") }
        try rule.validate(); try state.validate()
    }
}

public struct AIQuotaAlertStore: Sendable {
    public let url: URL
    public var backupURL: URL { url.appendingPathExtension("previous") }
    public init(url: URL) { self.url = url }
    public func load() throws -> AIQuotaAlertConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try decode(read(url))
    }
    public func save(_ value: AIQuotaAlertConfiguration) throws {
        try value.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 262_144 else { throw AIUsageError.invalid("额度提醒文件过大，原文件已保留。") }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if manager.fileExists(atPath: url.path) {
            let old = try read(url); _ = try decode(old)
            try old.write(to: backupURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func read(_ file: URL) throws -> Data {
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) <= 262_144 else {
            throw AIUsageError.invalid("额度提醒文件无法读取或过大，原文件已保留。")
        }
        return try Data(contentsOf: file)
    }
    private func decode(_ data: Data) throws -> AIQuotaAlertConfiguration {
        let value = try JSONDecoder().decode(AIQuotaAlertConfiguration.self, from: data)
        try value.validate(); return value
    }
}

/// History lines may connect only samples from the same actual reset window.
/// An absent reset, a long observation gap, or a backwards value starts another
/// segment instead of inventing a reset point or drawing through missing data.
public struct AIQuotaHistorySegment: Identifiable, Sendable {
    public var id: String
    public var window: AIQuotaWindowIdentity
    public var source: AIQuotaSource
    public var points: [AIQuotaHistoryPoint]
}
public struct AIQuotaHistoryPoint: Identifiable, Sendable {
    public var date: Date
    public var usedPercent: Double
    public var id: Date { date }
}
public enum AIQuotaHistorySegmentation {
    public static func segments(_ snapshots: [AIQuotaSnapshot], provider: AIProvider, maximumGap: TimeInterval = 900) -> [AIQuotaHistorySegment] {
        var result: [AIQuotaHistorySegment] = []
        var current: [String: Int] = [:]
        for snapshot in snapshots.filter({ $0.provider == provider }).sorted(by: { $0.observedAt < $1.observedAt }) {
            guard snapshot.observedAt.timeIntervalSince1970.isFinite else { continue }
            var seen = Set<AIQuotaWindowIdentity>()
            var activeKeys = Set<String>()
            for window in [snapshot.shortWindow, snapshot.weeklyWindow].compactMap({ $0 }) {
                let identity = AIQuotaWindowIdentity(provider: provider, durationMinutes: window.durationMinutes, resetsAt: window.resetsAt)
                guard (try? identity.validate()) != nil, window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                      window.resetsAt.map({ $0 >= snapshot.observedAt }) ?? true, seen.insert(identity).inserted else { continue }
                let key = identity.id + ":" + snapshot.source.rawValue
                activeKeys.insert(key)
                let point = AIQuotaHistoryPoint(date: snapshot.observedAt, usedPercent: window.usedPercent)
                if let index = current[key], let last = result[index].points.last,
                   identity.resetsAt != nil, snapshot.observedAt > last.date,
                   snapshot.observedAt.timeIntervalSince(last.date) <= maximumGap,
                   window.usedPercent >= last.usedPercent {
                    result[index].points.append(point)
                } else {
                    let id = key + ":" + String(snapshot.observedAt.timeIntervalSince1970) + ":" + String(result.count)
                    result.append(.init(id: id, window: identity, source: snapshot.source, points: [point]))
                    current[key] = result.count - 1
                }
            }
            current = current.filter { activeKeys.contains($0.key) }
        }
        return result
    }
}
