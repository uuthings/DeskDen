import Foundation

public enum ClaudeSubscriptionReading: Equatable, Sendable {
    case ready(AIQuotaSnapshot)
    case loginRequired(String, ClaudeLoginRemedy)
    case unavailable(String)
    case failed(String)
}

/// What a person can do about a missing membership login. Fangcun starts the official
/// login only where it replaces no other login; anything else stays the person's choice.
public enum ClaudeLoginRemedy: Equatable, Sendable {
    /// No usable membership login, so the official claude.ai login can be started.
    case signIn
    /// Claude Code keeps an Anthropic Console login, which only the person replaces in Terminal.
    case switchInTerminal
    /// A setting or another provider takes precedence; only a separate Fangcun login helps.
    case separateLogin
}

public protocol ClaudeSubscriptionProviding: Sendable {
    func fetch() async -> ClaudeSubscriptionReading
    func refresh() async -> ClaudeSubscriptionReading
    /// Starts the official claude.ai login for the configuration in use, unless it holds another kind of login.
    func login() async -> ClaudeSubscriptionReading
    /// A separate configuration for people who keep a different login in Terminal.
    func loginSeparately() async -> ClaudeSubscriptionReading
    /// Stops using the separate configuration and returns to the local Claude Code login.
    func useLocalLogin() async -> ClaudeSubscriptionReading
    func usesSeparateLogin() async -> Bool
}

public extension ClaudeSubscriptionProviding {
    func refresh() async -> ClaudeSubscriptionReading { await fetch() }
    func loginSeparately() async -> ClaudeSubscriptionReading { await login() }
    func useLocalLogin() async -> ClaudeSubscriptionReading { await refresh() }
    func usesSeparateLogin() async -> Bool { false }
}

/// Only documented metering fields and the authentication category cross this boundary.
/// Account identifiers, local paths, server prose and credentials are never retained.
public enum ClaudeSubscriptionUsage {
    public enum Authentication: Equatable, Sendable {
        case subscription, signedOut
        /// An Anthropic Console API key that `/login` created and stored.
        case consoleLogin
        /// `apiKeyHelper` or a configured API key takes precedence over the stored login.
        case configuredKey
        /// Bedrock, Vertex, Foundry or another non-Anthropic provider.
        case otherProvider
        case other
    }
    public static let maximumResponseBytes = 262_144
    public static let rateLimitedMessage = "Claude 暂时限制额度查询，请等待几分钟后重试。"
    /// Replaces a Console login with the official membership login in the default configuration.
    public static let terminalSwitchCommand = "claude auth logout && claude auth login --claudeai"

    public static func authentication(_ data: Data) -> Authentication? {
        struct Status: Decodable { let loggedIn: Bool; let authMethod: String; let apiProvider: String?; let apiKeySource: String? }
        guard data.count <= maximumResponseBytes, let value = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        guard value.loggedIn else { return .signedOut }
        if let provider = value.apiProvider, provider != "firstParty" { return .otherProvider }
        switch (value.authMethod, value.apiKeySource) {
        case ("claude.ai", _): return .subscription
        // Clients that omit the source report a stored Console key: environment
        // credentials never reach the official client from Fangcun.
        case ("api_key", "/login managed key"), ("api_key", nil): return .consoleLogin
        case ("api_key", _), ("api_key_helper", _): return .configuredKey
        default: return .other
        }
    }

    /// The reading for a login that provides no membership quota; nil for a membership login.
    public static func loginRequirement(_ authentication: Authentication) -> ClaudeSubscriptionReading? {
        switch authentication {
        case .subscription: nil
        case .signedOut:
            .loginRequired("本机 Claude Code 尚未登录会员。点击「登录 Claude 会员」，在官方网页完成授权后显示额度。", .signIn)
        case .consoleLogin:
            .loginRequired("本机 Claude Code 登录的是 Anthropic Console（API 计费）账号，不是会员登录；Claude 桌面版的会员登录不会同步到这里。请在终端切换为会员登录后重新检测。", .switchInTerminal)
        case .configuredKey:
            .loginRequired("Claude Code 设置中的 API Key 或 apiKeyHelper 优先于会员登录，无法读取会员额度。可移除该设置，或在「高级连接方式」中为方寸单独登录会员。", .separateLogin)
        case .otherProvider:
            .loginRequired("本机 Claude Code 当前通过 Bedrock、Vertex 等第三方平台使用，不提供会员额度。可在「高级连接方式」中为方寸单独登录会员。", .separateLogin)
        case .other:
            .loginRequired("当前 Claude Code 登录方式不提供会员额度。可在「高级连接方式」中为方寸单独登录会员。", .separateLogin)
        }
    }

    /// Fangcun reads only the login Claude Code stored. Credentials, provider switches and
    /// host-session variables inherited from whatever launched Fangcun are removed, so the
    /// result does not depend on how the app was started.
    public static func processEnvironment(_ inherited: [String: String], configurationDirectory: String?) -> [String: String] {
        var environment = inherited.filter { key, _ in
            !key.hasPrefix("ANTHROPIC_") && !key.hasPrefix("CLAUDE_CODE_") && key != "CLAUDECODE"
        }
        if let configurationDirectory { environment["CLAUDE_CONFIG_DIR"] = configurationDirectory }
        return environment
    }

    /// The official CLI's experimental get_usage response uses percentages in 0...100
    /// and ISO 8601 reset times; statusLine's epoch-second representation is separate.
    /// https://github.com/anthropics/claude-agent-sdk-typescript/releases/tag/v0.3.169
    public static func decode(_ data: Data, observedAt: Date) -> ClaudeSubscriptionReading {
        guard data.count <= maximumResponseBytes else { return .failed("Claude 返回的数据过大，请更新官方客户端后重试。") }
        do {
            let value = try JSONDecoder().decode(Response.self, from: data)
            // Reached only after a membership login was confirmed: the official client
            // withholds limits from a login without the profile scope.
            guard value.rate_limits_available else {
                return .loginRequired("Claude 会员登录缺少读取额度的权限，请重新登录 Claude 会员。", .signIn)
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
            return .loginRequired("Claude 会员登录已失效，请重新登录 Claude 会员。", .signIn)
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
