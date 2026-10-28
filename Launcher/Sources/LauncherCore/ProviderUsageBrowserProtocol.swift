import Foundation

/// The browser bridge carries only bounded quota readings. It never carries authentication material.
public enum ProviderUsageBrowserProtocol {
    public static let version = 1
    public static let maximumMessageBytes = 16_384
    public static let maximumPendingRequests = 16
    public static let hostName = "com.uuthings.deskden.iproyal"
    public static let extensionID = "dbgielekmbgphidnnfidmlobjmdblagf"
    public static let extensionOrigin = "chrome-extension://" + extensionID + "/"
    public static func validOrderID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 20 && value.first != "0" && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    public static func validResetDate(_ value: String) -> Bool {
        guard value.utf8.count == 10 else { return false }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), (2000...9999).contains(y) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == y && actual.month == m && actual.day == d
    }
}

public struct ProviderUsageBrowserRequestMessage: Codable, Equatable, Sendable {
    public var version: Int = ProviderUsageBrowserProtocol.version
    public var requestID: UUID
    public var sourceID: UUID
    public var orderID: String
    public var createdAt: Double
    public var expiresAt: Double
    public init(requestID: UUID = UUID(), sourceID: UUID, orderID: String, at date: Date, lifetime: TimeInterval = 180) {
        self.requestID = requestID; self.sourceID = sourceID; self.orderID = orderID
        createdAt = date.timeIntervalSince1970; expiresAt = createdAt + lifetime
    }
    public func isValid(at date: Date) -> Bool {
        let now = date.timeIntervalSince1970
        return version == ProviderUsageBrowserProtocol.version && ProviderUsageBrowserProtocol.validOrderID(orderID) &&
            createdAt.isFinite && expiresAt.isFinite && createdAt <= now + 5 && expiresAt > now &&
            expiresAt > createdAt && expiresAt - createdAt <= 300
    }
}

public enum ProviderUsageBrowserResultStatus: String, Codable, Sendable {
    case success, authentication, unavailable, timeout, invalidResponse, rateLimited
}

public struct ProviderUsageBrowserResultMessage: Codable, Equatable, Sendable {
    public var version: Int = ProviderUsageBrowserProtocol.version
    public var requestID: UUID
    public var sourceID: UUID
    public var orderID: String
    public var status: ProviderUsageBrowserResultStatus
    public var observedAt: Double
    public var documentID: String?
    public var generation: UUID?
    public var gbLimit: Double?
    public var gbUsed: Double?
    public var gbBalance: Double?
    public var resetDateText: String?
    public var retryAfterSeconds: TimeInterval?
    public init(request: ProviderUsageBrowserRequestMessage, status: ProviderUsageBrowserResultStatus, observedAt: Date,
                documentID: String? = nil, generation: UUID? = nil, gbLimit: Double? = nil, gbUsed: Double? = nil,
                gbBalance: Double? = nil, resetDateText: String? = nil, retryAfterSeconds: TimeInterval? = nil) {
        requestID = request.requestID; sourceID = request.sourceID; orderID = request.orderID; self.status = status
        self.observedAt = observedAt.timeIntervalSince1970; self.documentID = documentID; self.generation = generation
        self.gbLimit = gbLimit; self.gbUsed = gbUsed; self.gbBalance = gbBalance; self.resetDateText = resetDateText
        self.retryAfterSeconds = retryAfterSeconds
    }
    public func isValid(for request: ProviderUsageBrowserRequestMessage, at date: Date) -> Bool {
        let now = date.timeIntervalSince1970
        return hasValidPayload && requestID == request.requestID && sourceID == request.sourceID &&
            orderID == request.orderID && request.isValid(at: date) &&
            observedAt >= request.createdAt - 5 && observedAt <= now + 5
    }
    /// Payload validation is independent of whether its request was cancelled or expired.
    public var hasValidPayload: Bool {
        guard version == ProviderUsageBrowserProtocol.version, ProviderUsageBrowserProtocol.validOrderID(orderID),
              observedAt.isFinite, (0...253_402_300_799).contains(observedAt),
              documentID.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("\n") }) ?? true,
              resetDateText.map(ProviderUsageBrowserProtocol.validResetDate) ?? true else { return false }
        guard retryAfterSeconds.map({ $0.isFinite && (0...604_800).contains($0) }) ?? true,
              status == .rateLimited || retryAfterSeconds == nil else { return false }
        if status != .success { return gbLimit == nil && gbUsed == nil && gbBalance == nil && resetDateText == nil }
        guard let documentID, !documentID.isEmpty, generation != nil,
              let limit = gbLimit, let used = gbUsed, let balance = gbBalance,
              [limit, used, balance].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 9_000_000 }), limit > 0,
              balance <= limit + 0.002, abs(max(0, limit - used) - balance) <= 0.002 else { return false }
        return true
    }
}

/// Strict envelope checking rejects unexpected fields before Codable can discard them.
public enum ProviderUsageBrowserJSON {
    public static func decodeRequest(_ data: Data) throws -> ProviderUsageBrowserRequestMessage {
        try keys(data, allowed: ["version", "requestID", "sourceID", "orderID", "createdAt", "expiresAt"])
        return try JSONDecoder().decode(ProviderUsageBrowserRequestMessage.self, from: data)
    }
    public static func decodeResult(_ data: Data) throws -> ProviderUsageBrowserResultMessage {
        try keys(data, allowed: ["version", "requestID", "sourceID", "orderID", "status", "observedAt", "documentID", "generation", "gbLimit", "gbUsed", "gbBalance", "resetDateText", "retryAfterSeconds"])
        return try JSONDecoder().decode(ProviderUsageBrowserResultMessage.self, from: data)
    }
    public static func keys(_ data: Data, allowed: Set<String>) throws {
        guard !data.isEmpty, data.count <= ProviderUsageBrowserProtocol.maximumMessageBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys).isSubset(of: allowed) else {
            throw ProviderUsageBrowserProtocolError.invalidMessage
        }
    }
}

public enum ProviderUsageBrowserProtocolError: Error { case invalidMessage, insecureMailbox, io, queueFull }
