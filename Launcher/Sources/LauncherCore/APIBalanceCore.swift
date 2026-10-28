import Foundation

public enum APIBalanceProvider: String, Codable, Sendable { case deepseek; public var title: String { "DeepSeek" } }
public enum APIBalanceFailure: LocalizedError, Equatable, Sendable {
    case invalidConfiguration, invalidResponse, authentication, rateLimited(TimeInterval?), server(Int), transport, storage, credentials, cancelled, busy
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "请填写名称和有效的 API Key。"
        case .invalidResponse: "服务商没有返回有效余额，已保留上次读数。"
        case .authentication: "API Key 无效或已失效，请重新验证连接。"
        case .rateLimited: "服务商暂时限制查询频率，请稍后重试。"
        case .server(let status): "余额服务暂不可用（\(status)），已保留上次读数。"
        case .transport: "未能连接余额服务，请检查网络后重试。"
        case .storage: "API 余额文件无法保存，原有记录已保留。"
        case .credentials: "API Key 无法安全保存或读取，请检查本机钥匙串。"
        case .cancelled: "余额查询已取消。"
        case .busy: "请先完成当前 API 连接操作。"
        }
    }
}
public struct APIBalanceConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var provider: APIBalanceProvider
    public var name: String
    public var credentialID: UUID?
    public var createdAt: Date
    public var enabled: Bool
    public init(id: UUID = UUID(), provider: APIBalanceProvider = .deepseek, name: String, credentialID: UUID? = nil, createdAt: Date = Date(), enabled: Bool = true) {
        self.id = id; self.provider = provider; self.name = name; self.credentialID = credentialID; self.createdAt = createdAt; self.enabled = enabled
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), createdAt.timeIntervalSince1970.isFinite,
              createdAt.timeIntervalSince1970 >= 0 else { throw APIBalanceFailure.invalidConfiguration }
    }
}
/// Currency amounts remain exact decimal strings from the provider, never bytes
/// or binary floating-point quota percentages. Different currencies are not added.
public struct APIBalanceAmount: Codable, Equatable, Identifiable, Sendable {
    public var currency: String
    public var totalBalance: String
    public var grantedBalance: String
    public var toppedUpBalance: String
    public var id: String { currency }
    public var total: Decimal? { Self.decimal(totalBalance) }
    public var granted: Decimal? { Self.decimal(grantedBalance) }
    public var toppedUp: Decimal? { Self.decimal(toppedUpBalance) }
    public var formattedTotal: String { currency + " " + totalBalance }
    public init(currency: String, totalBalance: String, grantedBalance: String, toppedUpBalance: String) {
        self.currency = currency; self.totalBalance = totalBalance; self.grantedBalance = grantedBalance; self.toppedUpBalance = toppedUpBalance
    }
    public static func decimal(_ text: String) -> Decimal? {
        guard text.range(of: #"^-?[0-9]{1,18}(?:\.[0-9]{1,12})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
    public func validate() throws {
        guard ["CNY", "USD"].contains(currency), let total = Self.decimal(totalBalance),
              let granted = Self.decimal(grantedBalance), let toppedUp = Self.decimal(toppedUpBalance),
              total == granted + toppedUp else { throw APIBalanceFailure.invalidResponse }
    }
}
public struct APIBalanceSnapshot: Codable, Equatable, Sendable {
    public var sourceID: UUID
    public var observedAt: Date
    public var isAvailable: Bool
    public var balances: [APIBalanceAmount]
    public init(sourceID: UUID, observedAt: Date = Date(), isAvailable: Bool, balances: [APIBalanceAmount]) {
        self.sourceID = sourceID; self.observedAt = observedAt; self.isAvailable = isAvailable; self.balances = balances
    }
    public func validate(now: Date = Date()) throws {
        guard observedAt.timeIntervalSince1970.isFinite, observedAt.timeIntervalSince1970 >= 0,
              observedAt <= now.addingTimeInterval(300), (1...2).contains(balances.count),
              Set(balances.map(\.currency)).count == balances.count else { throw APIBalanceFailure.invalidResponse }
        for balance in balances { try balance.validate() }
    }
}
public struct APIBalanceSourceState: Codable, Equatable, Sendable {
    public var snapshot: APIBalanceSnapshot?
    public var lastAttempt: Date?
    public var message: String?
    public var nextRetryAt: Date?
    public var rateLimitUntil: Date?
    public var authenticationFailed = false
    public init(snapshot: APIBalanceSnapshot? = nil, lastAttempt: Date? = nil, message: String? = nil, nextRetryAt: Date? = nil, rateLimitUntil: Date? = nil, authenticationFailed: Bool = false) {
        self.snapshot = snapshot; self.lastAttempt = lastAttempt; self.message = message; self.nextRetryAt = nextRetryAt; self.rateLimitUntil = rateLimitUntil; self.authenticationFailed = authenticationFailed
    }
    public func isStale(at now: Date = Date()) -> Bool { snapshot.map { now.timeIntervalSince($0.observedAt) > 1800 } ?? true }
    public func statusTitle(now: Date = Date()) -> String {
        if message != nil { return snapshot == nil ? "连接需要检查" : "保留上次余额" }
        guard let snapshot else { return "尚未查询" }
        if isStale(at: now) { return "余额读数已过期" }
        return snapshot.isAvailable ? "余额可用" : "余额不足"
    }
}
public struct APIBalanceDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var sources: [APIBalanceConfiguration] = []
    public var states: [UUID: APIBalanceSourceState] = [:]
    public init() {}
    public func validate(now: Date = Date()) throws {
        guard schemaVersion == 1, sources.count <= 100, Set(sources.map(\.id)).count == sources.count,
              Set(states.keys).isSubset(of: Set(sources.map(\.id))) else { throw APIBalanceFailure.storage }
        for source in sources { try source.validate() }
        for (id, state) in states {
            if let snapshot = state.snapshot { guard snapshot.sourceID == id else { throw APIBalanceFailure.storage }; try snapshot.validate(now: now) }
            guard state.message.map({ $0.count <= 240 }) ?? true else { throw APIBalanceFailure.storage }
            for date in [state.lastAttempt, state.nextRetryAt, state.rateLimitUntil].compactMap({ $0 }) {
                guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0 else { throw APIBalanceFailure.storage }
            }
        }
    }
}
public struct APIBalanceStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    private func validatePath() throws {
        guard url.isFileURL else { throw APIBalanceFailure.storage }
        var target = url
        while target.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path) {
                let expected: FileAttributeType = target == url ? .typeRegular : .typeDirectory
                let type = attributes[.type] as? FileAttributeType
                // macOS publishes these protected system aliases. Permit only
                // their exact destinations; application-level links stay blocked.
                let systemAlias = ["/var": "/private/var", "/tmp": "/private/tmp"][target.path]
                let destination = type == .typeSymbolicLink ? try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) : nil
                let allowedAlias = systemAlias.map { destination == $0 || destination == String($0.dropFirst()) } ?? false
                guard type == expected || allowedAlias else { throw APIBalanceFailure.storage }
            }
            target.deleteLastPathComponent()
        }
    }
    public func load() throws -> APIBalanceDocument {
        try validatePath()
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let bytes = try file.read(upToCount: 2_097_153) ?? Data()
        guard bytes.count <= 2_097_152 else { throw APIBalanceFailure.storage }
        let value = try JSONDecoder().decode(APIBalanceDocument.self, from: bytes); try value.validate(); return value
    }
    public func save(_ value: APIBalanceDocument) throws {
        try value.validate(); try validatePath()
        if FileManager.default.fileExists(atPath: url.path) { _ = try load() }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 2_097_152 else { throw APIBalanceFailure.storage }
        try ProtectedAtomicFile.write(data, to: url)
    }
}
