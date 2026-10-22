import Foundation

public enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude
    public var id: String { rawValue }
    public var title: String { self == .codex ? "Codex" : "Claude" }
}
public enum AIUsageState: String, Codable, Sendable {
    case ready, stale, unavailable, disconnected, error
    public var title: String {
        switch self { case .ready: "已更新"; case .stale: "数据过期"; case .unavailable: "额度不可用"; case .disconnected: "未连接"; case .error: "读取失败" }
    }
}
public enum AIQuotaSource: String, Codable, Sendable {
    case localSession, claudeStatusLine, imported, manual
    public var title: String {
        switch self { case .localSession: "Codex 本地会话额度"; case .claudeStatusLine: "Claude 官方状态栏读数"; case .imported: "用户导入的额度读数"; case .manual: "用户手动记录" }
    }
}
/// Only names directly exposed by the metering source are retained. A generic
/// Pro name does not establish a usage multiplier or a billing price.
public enum AIAccountPlan: String, Codable, Sendable {
    case free, go, plus, pro, team, business, enterprise, edu
    public var title: String {
        switch self {
        case .free: "Free"
        case .go: "Go"
        case .plus: "Plus"
        case .pro: "Pro"
        case .team: "Team"
        case .business: "Business"
        case .enterprise: "Enterprise"
        case .edu: "Edu"
        }
    }
}
public struct AIQuotaWindow: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var durationMinutes: Int
    public var resetsAt: Date?
    public init(usedPercent: Double, durationMinutes: Int, resetsAt: Date?) throws {
        guard usedPercent.isFinite, (0...100).contains(usedPercent), (1...525_600).contains(durationMinutes) else { throw AIUsageError.invalid("额度比例应在 0–100 之间，窗口时长必须大于 0。") }
        self.usedPercent = usedPercent; self.durationMinutes = durationMinutes; self.resetsAt = resetsAt
    }
    public var remainingPercent: Double { max(0, 100 - usedPercent) }
    public var title: String { durationMinutes == 10_080 ? "每周额度" : durationMinutes % 60 == 0 ? "\(durationMinutes / 60) 小时窗口" : "\(durationMinutes) 分钟窗口" }
    public var severity: Int { usedPercent >= 90 ? 2 : usedPercent >= 75 ? 1 : 0 }
}
public struct AIQuotaSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var provider: AIProvider
    public var observedAt: Date
    public var source: AIQuotaSource
    public var shortWindow: AIQuotaWindow?
    public var weeklyWindow: AIQuotaWindow?
    public var accountPlan: AIAccountPlan?
    public var id: String { "\(provider.rawValue):\(observedAt.timeIntervalSince1970):\(source.rawValue):\(shortWindow?.usedPercent ?? -1):\(weeklyWindow?.usedPercent ?? -1):\(accountPlan?.rawValue ?? "")" }
    public init(provider: AIProvider, observedAt: Date, source: AIQuotaSource, shortWindow: AIQuotaWindow?, weeklyWindow: AIQuotaWindow?, accountPlan: AIAccountPlan? = nil) {
        self.provider = provider; self.observedAt = observedAt; self.source = source; self.shortWindow = shortWindow; self.weeklyWindow = weeklyWindow; self.accountPlan = accountPlan
    }
    /// Slot names are storage compatibility only: their actual durations, not
    /// the presence of a primary/secondary slot, determine the displayed label.
    public var availableWindows: [AIQuotaWindow] {
        [shortWindow, weeklyWindow].compactMap { $0 }.sorted { $0.durationMinutes < $1.durationMinutes }
    }
    public func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(observedAt) > 900 || [shortWindow, weeklyWindow].compactMap { $0?.resetsAt }.contains { $0 <= now }
    }
    public func validate(now: Date = Date()) throws {
        guard observedAt <= now.addingTimeInterval(300), observedAt.timeIntervalSince1970 > 0, shortWindow != nil || weeklyWindow != nil else { throw AIUsageError.invalid("读数需要有效采集时间和至少一个额度窗口。") }
        for window in [shortWindow, weeklyWindow].compactMap({ $0 }) {
            _ = try AIQuotaWindow(usedPercent: window.usedPercent, durationMinutes: window.durationMinutes, resetsAt: window.resetsAt)
            if let reset = window.resetsAt, reset < observedAt { throw AIUsageError.invalid("重置时间不能早于读数采集时间。") }
        }
    }
}
public struct AITokenCounts: Codable, Equatable, Sendable {
    /// Input excludes cache reads/writes, so all four categories are disjoint.
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite: Int64 = 0
    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) {
        self.input = max(0, input); self.output = max(0, output); self.cacheRead = max(0, cacheRead); self.cacheWrite = max(0, cacheWrite)
    }
    public var total: Int64 { input + output + cacheRead + cacheWrite }
    public static func + (a: Self, b: Self) -> Self { .init(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite) }
    public func delta(from old: Self) -> Self { .init(input: input - old.input, output: output - old.output, cacheRead: cacheRead - old.cacheRead, cacheWrite: cacheWrite - old.cacheWrite) }
    public func maximum(_ other: Self) -> Self { .init(input: max(input, other.input), output: max(output, other.output), cacheRead: max(cacheRead, other.cacheRead), cacheWrite: max(cacheWrite, other.cacheWrite)) }
}
public struct AITokenRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: AIProvider
    public var timestamp: Date
    public var model: String
    public var tokens: AITokenCounts
    public init(id: String, provider: AIProvider, timestamp: Date, model: String, tokens: AITokenCounts) {
        self.id = id; self.provider = provider; self.timestamp = timestamp; self.model = String(model.prefix(100)); self.tokens = tokens
    }
}
public struct AIProviderSummary: Identifiable, Sendable {
    public var provider: AIProvider
    public var state: AIUsageState
    public var snapshot: AIQuotaSnapshot?
    public var detail: String
    public var id: String { provider.rawValue }
    public var title: String { provider.title }
    public var shortWindow: AIQuotaWindow? { snapshot?.shortWindow }
    public var weeklyWindow: AIQuotaWindow? { snapshot?.weeklyWindow }
    public var updatedAt: Date? { snapshot?.observedAt }
    public var sourceDescription: String { snapshot?.source.title ?? "尚无有效额度读数" }
    public var accountPlanDescription: String { snapshot?.accountPlan?.title ?? "来源未提供会员信息" }
    public init(provider: AIProvider, state: AIUsageState, snapshot: AIQuotaSnapshot?, detail: String) { self.provider = provider; self.state = state; self.snapshot = snapshot; self.detail = detail }
}
public enum AIUsageError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}
public enum AIUsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case today, week, month
    public var id: String { rawValue }
    public var title: String { self == .today ? "今天" : self == .week ? "7 天" : "30 天" }
    public func start(now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: self == .today ? 0 : self == .week ? -6 : -29, to: calendar.startOfDay(for: now)) ?? now
    }
}
public struct AITokenBucket: Identifiable, Sendable {
    public var date: Date
    public var tokens: AITokenCounts
    public var id: Date { date }
}
public enum AIUsageAggregation {
    public static func deduplicate(_ records: [AITokenRecord]) -> [AITokenRecord] {
        var unique: [String: AITokenRecord] = [:]
        for record in records {
            let key = record.provider.rawValue + ":" + record.id
            if var old = unique[key] {
                old.tokens = old.tokens.maximum(record.tokens)
                if record.timestamp > old.timestamp { old.timestamp = record.timestamp }
                unique[key] = old
            } else { unique[key] = record }
        }
        return unique.values.sorted { $0.timestamp < $1.timestamp }
    }
    public static func buckets(_ records: [AITokenRecord], period: AIUsagePeriod, now: Date, calendar: Calendar = .current) -> [AITokenBucket] {
        let start = period.start(now: now, calendar: calendar)
        let component: Calendar.Component = period == .today ? .hour : .day
        let count = period == .today ? 24 : period == .week ? 7 : 30
        var values: [Date: AITokenCounts] = [:]
        for record in records where record.timestamp >= start && record.timestamp <= now {
            guard let date = calendar.dateInterval(of: component, for: record.timestamp)?.start else { continue }
            values[date] = (values[date] ?? .init()) + record.tokens
        }
        return (0..<count).compactMap { index in
            guard let date = calendar.date(byAdding: component, value: index, to: start) else { return nil }
            return AITokenBucket(date: date, tokens: values[date] ?? .init())
        }
    }
}

/// Parses only known metering fields. Prompts, tool output, paths and credentials are never retained.
public struct AIUsageLogParser: Sendable {
    public var records: [AITokenRecord] = []
    public var snapshots: [AIQuotaSnapshot] = []
    private var model = "未标注模型"
    private var previousTotal: AITokenCounts?
    private var counter = 0
    public init() {}
    public mutating func consume(_ data: Data, provider: AIProvider, sourceID: String, fallbackDate: Date? = nil) {
        guard data.count <= 2_097_152, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if provider == .codex {
            if value["type"] as? String == "turn_context", let payload = value["payload"] as? [String: Any], let name = payload["model"] as? String { model = String(name.prefix(100)); return }
            guard value["type"] as? String == "event_msg", let payload = value["payload"] as? [String: Any], payload["type"] as? String == "token_count", let timestamp = Self.date(value["timestamp"]) ?? fallbackDate else { return }
            if let rates = payload["rate_limits"] as? [String: Any], (rates["limit_id"] as? String).map({ $0 == "codex" }) ?? true,
               let snapshot = Self.codexQuota(rates, date: timestamp, source: .localSession) { snapshots.append(snapshot) }
            guard let info = payload["info"] as? [String: Any], let totalJSON = info["total_token_usage"] as? [String: Any], let total = Self.codexCounts(totalJSON) else { return }
            let last = (info["last_token_usage"] as? [String: Any]).flatMap(Self.codexCounts)
            let delta: AITokenCounts
            if let previousTotal {
                if total == previousTotal { return }
                delta = total.total >= previousTotal.total ? total.delta(from: previousTotal) : (last ?? total)
            } else { delta = last ?? total }
            previousTotal = total; counter += 1
            if delta.total > 0 { records.append(.init(id: sourceID + ":" + String(counter) + ":" + String(total.total), provider: .codex, timestamp: timestamp, model: model, tokens: delta)) }
        } else {
            guard value["type"] as? String == "assistant", let message = value["message"] as? [String: Any], let usage = message["usage"] as? [String: Any], let timestamp = Self.date(value["timestamp"]) ?? fallbackDate else { return }
            guard let id = message["id"] as? String ?? value["uuid"] as? String, let counts = Self.claudeCounts(usage) else { return }
            let modelName = message["model"] as? String ?? "未标注模型"
            if counts.total > 0 { records.append(.init(id: id, provider: .claude, timestamp: timestamp, model: modelName, tokens: counts)) }
        }
    }
    public static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber, n.doubleValue.isFinite, n.doubleValue > 0 { return Date(timeIntervalSince1970: n.doubleValue) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: text)
    }
    private static func count(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 1_000_000_000_000 else { return nil }
        return number.int64Value
    }
    private static func codexCounts(_ json: [String: Any]) -> AITokenCounts? {
        guard let input = count(json["input_tokens"]), let output = count(json["output_tokens"]) else { return nil }
        let read = min(input, count(json["cached_input_tokens"]) ?? 0)
        let write = min(input - read, count(json["cache_write_input_tokens"]) ?? 0)
        return .init(input: input - read - write, output: output, cacheRead: read, cacheWrite: write)
    }
    private static func claudeCounts(_ json: [String: Any]) -> AITokenCounts? {
        guard let input = count(json["input_tokens"]), let output = count(json["output_tokens"]) else { return nil }
        return .init(input: input, output: output, cacheRead: count(json["cache_read_input_tokens"]) ?? 0, cacheWrite: count(json["cache_creation_input_tokens"]) ?? 0)
    }
    private static func window(_ json: [String: Any]?, percentKey: String, minutes: Int?) -> AIQuotaWindow? {
        guard let json, let percent = json[percentKey] as? NSNumber, CFGetTypeID(percent) != CFBooleanGetTypeID(), let duration = minutes else { return nil }
        return try? .init(usedPercent: percent.doubleValue, durationMinutes: duration, resetsAt: date(json["resets_at"] ?? json["resetsAt"]))
    }
    public static func codexQuota(_ json: [String: Any], date: Date, source: AIQuotaSource) -> AIQuotaSnapshot? {
        let primary = json["primary"] as? [String: Any], secondary = json["secondary"] as? [String: Any]
        let p = window(primary, percentKey: primary?["used_percent"] == nil ? "usedPercent" : "used_percent", minutes: (primary?["window_minutes"] ?? primary?["windowDurationMins"]) as? Int)
        let s = window(secondary, percentKey: secondary?["used_percent"] == nil ? "usedPercent" : "used_percent", minutes: (secondary?["window_minutes"] ?? secondary?["windowDurationMins"]) as? Int)
        guard p != nil || s != nil else { return nil }
        let plan = (json["plan_type"] ?? json["planType"]) as? String
        return .init(provider: .codex, observedAt: date, source: source, shortWindow: p, weeklyWindow: s, accountPlan: plan.flatMap(AIAccountPlan.init(rawValue:)))
    }
    public static func claudeQuota(_ json: [String: Any], date: Date) -> AIQuotaSnapshot? {
        let primary = window(json["five_hour"] as? [String: Any], percentKey: "used_percentage", minutes: 300)
        let secondary = window(json["seven_day"] as? [String: Any], percentKey: "used_percentage", minutes: 10_080)
        guard primary != nil || secondary != nil else { return nil }
        return .init(provider: .claude, observedAt: date, source: .claudeStatusLine, shortWindow: primary, weeklyWindow: secondary)
    }
}
import CoreFoundation

public enum AIQuotaImport {
    /// Explicit schema prevents context-window percentages being mistaken for account quotas.
    public static func decode(_ data: Data, now: Date = Date()) throws -> AIQuotaSnapshot {
        guard data.count <= 262_144 else { throw AIUsageError.invalid("额度 JSON 不得超过 256 KB。") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = AIUsageLogParser.date(text) else { throw AIUsageError.invalid("读数时间需为有效 ISO 8601 格式。") }
            return date
        }
        var snapshot: AIQuotaSnapshot
        do { snapshot = try decoder.decode(AIQuotaSnapshot.self, from: data) }
        catch { throw AIUsageError.invalid("JSON 格式不符。请按导出的模板填写 provider、observedAt 和额度窗口。") }
        snapshot.source = .imported
        try snapshot.validate(now: now)
        return snapshot
    }
    public static func encode(_ snapshot: AIQuotaSnapshot) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }
}

public struct AITokenPrice: Codable, Equatable, Identifiable, Sendable {
    public var provider: AIProvider
    public var model: String
    public var inputPerMillion: Double
    public var outputPerMillion: Double
    public var cacheReadPerMillion: Double
    public var cacheWritePerMillion: Double
    public var id: String { provider.rawValue + ":" + model }
    public init(provider: AIProvider, model: String, inputPerMillion: Double, outputPerMillion: Double, cacheReadPerMillion: Double, cacheWritePerMillion: Double) throws {
        let values = [inputPerMillion, outputPerMillion, cacheReadPerMillion, cacheWritePerMillion]
        guard !model.isEmpty, model.count <= 100, values.allSatisfy({ $0.isFinite && (0...100_000).contains($0) }) else { throw AIUsageError.invalid("请填写有效模型及 0–100000 USD / 百万 Token 的单价。") }
        self.provider = provider; self.model = model; self.inputPerMillion = inputPerMillion; self.outputPerMillion = outputPerMillion; self.cacheReadPerMillion = cacheReadPerMillion; self.cacheWritePerMillion = cacheWritePerMillion
    }
    public func estimate(_ counts: AITokenCounts) -> Double {
        (Double(counts.input) * inputPerMillion + Double(counts.output) * outputPerMillion + Double(counts.cacheRead) * cacheReadPerMillion + Double(counts.cacheWrite) * cacheWritePerMillion) / 1_000_000
    }
}
