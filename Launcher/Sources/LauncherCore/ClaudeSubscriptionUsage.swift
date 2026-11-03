import Foundation

public enum ClaudeSubscriptionReading: Equatable, Sendable {
    case ready(AIQuotaSnapshot)
    case loginRequired(String)
    case unavailable(String)
    case failed(String)
}

public protocol ClaudeSubscriptionProviding: Sendable {
    func fetch() async -> ClaudeSubscriptionReading
    func refresh() async -> ClaudeSubscriptionReading
    func login() async -> ClaudeSubscriptionReading
}

public extension ClaudeSubscriptionProviding {
    func refresh() async -> ClaudeSubscriptionReading { await fetch() }
}

/// Only documented metering fields and the authentication category cross this boundary.
/// Account identifiers, local paths, server prose and credentials are never retained.
public enum ClaudeSubscriptionUsage {
    public enum Authentication: Equatable, Sendable { case subscription, apiKey, signedOut, other }
    public static let maximumResponseBytes = 262_144
    public static let rateLimitedMessage = "Claude 暂时限制额度查询，请等待几分钟后重试。"

    public static func authentication(_ data: Data) -> Authentication? {
        struct Status: Decodable { let loggedIn: Bool; let authMethod: String }
        guard data.count <= maximumResponseBytes, let value = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        guard value.loggedIn else { return .signedOut }
        switch value.authMethod {
        case "claude.ai": return .subscription
        case "api_key", "api_key_helper": return .apiKey
        default: return .other
        }
    }

    /// The official CLI's experimental get_usage response uses percentages in 0...100
    /// and ISO 8601 reset times; statusLine's epoch-second representation is separate.
    /// https://github.com/anthropics/claude-agent-sdk-typescript/releases/tag/v0.3.169
    public static func decode(_ data: Data, observedAt: Date) -> ClaudeSubscriptionReading {
        guard data.count <= maximumResponseBytes else { return .failed("Claude 返回的数据过大，请更新官方客户端后重试。") }
        do {
            let value = try JSONDecoder().decode(Response.self, from: data)
            guard value.rate_limits_available else {
                return .loginRequired("当前 Claude Code 登录没有提供会员额度。请连接 Claude 会员，保留现有 API 配置。")
            }
            guard let rates = value.rate_limits else {
                return .unavailable("Claude 已登录，但官方客户端暂未返回额度。请稍后刷新，或在 Claude Code 中查看 /usage。")
            }
            let short = try window(rates.five_hour ?? rates.row(kind: "session"), minutes: 300, now: observedAt)
            let weekly = try window(rates.seven_day ?? rates.row(kind: "weekly_all"), minutes: 10_080, now: observedAt)
            guard short != nil || weekly != nil else {
                return .unavailable("Claude 暂未提供有效的五小时或每周额度，请稍后刷新。缺失窗口不会按零计算。")
            }
            let snapshot = AIQuotaSnapshot(provider: .claude, observedAt: observedAt, source: .claudeCLI,
                shortWindow: short, weeklyWindow: weekly, accountPlan: value.subscription_type.flatMap(AIAccountPlan.init(rawValue:)))
            try snapshot.validate(now: observedAt)
            return .ready(snapshot)
        } catch {
            return .failed("Claude 额度格式暂不受支持，请更新官方 Claude Code 后重试。")
        }
    }

    /// Do not expose server-controlled errors, login URLs, account names or paths.
    public static func failure(from data: Data) -> ClaudeSubscriptionReading {
        let text = String(decoding: data.prefix(maximumResponseBytes), as: UTF8.self).lowercased()
        if text.contains("429") || text.contains("rate_limit") || text.contains("rate limit") || text.contains("too many requests") {
            return .unavailable(rateLimitedMessage)
        }
        if text.contains("401") || text.contains("403") || text.contains("unauthorized") || text.contains("login expired") || text.contains("not logged in") {
            return .loginRequired("Claude 授权已失效或不足，请重新连接会员。现有 API 配置会保留。")
        }
        if text.contains("not supported") || text.contains("unknown option") || text.contains("unknown command") || text.contains("unrecognized") {
            return .unavailable("当前 Claude Code 不支持额度读取，请更新官方客户端后重试。")
        }
        return .failed("暂时无法读取 Claude 额度，请检查网络后重试。")
    }

    private struct Response: Decodable {
        let rate_limits_available: Bool
        let subscription_type: String?
        let rate_limits: Rates?
    }
    private struct Meter: Decodable {
        let utilization: Double?
        let resets_at: String?
    }
    private struct Row: Decodable {
        let kind: String
        let percent: Double?
        let resets_at: String?
        private enum CodingKeys: String, CodingKey { case kind, percent, resets_at }
        init(from decoder: Decoder) throws {
            // Future/unrelated meters can have a different schema. Decode only
            // the two known meter kinds, retaining strict values for those kinds.
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            kind = (try? container?.decode(String.self, forKey: .kind)) ?? ""
            guard let container, kind == "session" || kind == "weekly_all" else {
                percent = nil; resets_at = nil; return
            }
            percent = try container.decode(Double.self, forKey: .percent)
            resets_at = try container.decodeIfPresent(String.self, forKey: .resets_at)
        }
    }
    private struct Rates: Decodable {
        let five_hour: Meter?
        let seven_day: Meter?
        let limits: [Row]?
        func row(kind: String) -> Meter? {
            guard let rows = limits, rows.count <= 64, let row = rows.first(where: { $0.kind == kind }), let percent = row.percent else { return nil }
            return Meter(utilization: percent, resets_at: row.resets_at)
        }
    }
    private static func window(_ meter: Meter?, minutes: Int, now: Date) throws -> AIQuotaWindow? {
        guard let meter, let percent = meter.utilization else { return nil }
        let reset: Date?
        if let text = meter.resets_at {
            guard text.utf8.count <= 100, let date = AIUsageLogParser.date(text) else { throw AIUsageError.invalid("invalid reset") }
            reset = date
            // A window that already reset is absent, never an invented fresh 0%.
            if date <= now { return nil }
        } else { reset = nil }
        return try AIQuotaWindow(usedPercent: percent, durationMinutes: minutes, resetsAt: reset)
    }
}
