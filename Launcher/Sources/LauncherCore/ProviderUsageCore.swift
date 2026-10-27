import Foundation

public enum ProviderUsageKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case iproyal, bandwagon
    public var id: String { rawValue }
    public var title: String { self == .iproyal ? "IPRoyal" : "搬瓦工" }
}

public enum ProviderUsageDisplayUnit: String, Codable, Sendable {
    case decimalGB, binaryGB
    public var divisor: Double { self == .decimalGB ? 1_000_000_000 : 1_073_741_824 }
    public var title: String { "GB" }
    public var explanation: String { self == .decimalGB ? "1 GB = 1,000,000,000 字节" : "按服务商后台口径，1 GB = 1,073,741,824 字节" }
}

/// Connection metadata contains no password, token, cookie, or API key.
public struct ProviderUsageConfiguration: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: ProviderUsageKind
    public var name: String
    public var resourceID: String
    public var enabled: Bool
    public var refreshPolicy: ProviderUsageRefreshPolicy
    public var credentialID: UUID?
    public init(id: UUID = UUID(), kind: ProviderUsageKind, name: String, resourceID: String,
                enabled: Bool = true, refreshPolicy: ProviderUsageRefreshPolicy = .init(), credentialID: UUID? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.resourceID = resourceID
        self.enabled = enabled; self.refreshPolicy = refreshPolicy; self.credentialID = credentialID
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...20).contains(resourceID.count), resourceID.utf8.allSatisfy({ (48...57).contains($0) }),
              resourceID.first != "0" else { throw ProviderUsageFailure.invalidConfiguration }
        try refreshPolicy.validate()
    }
}

/// The provider's balance is authoritative. Local network bytes never alter it.
public struct ProviderUsageSnapshot: Codable, Equatable, Sendable {
    public var sourceID: UUID
    public var observedAt: Date
    public var usedBytes: UInt64
    public var limitBytes: UInt64
    public var remainingBytes: UInt64?
    public var resetsAt: Date?
    /// A provider date without a verified timezone must stay a date, not an invented UTC instant.
    public var resetDateText: String?
    public var displayUnit: ProviderUsageDisplayUnit
    public var sourceDescription: String
    public init(sourceID: UUID, observedAt: Date, usedBytes: UInt64, limitBytes: UInt64,
                remainingBytes: UInt64? = nil, resetsAt: Date? = nil, resetDateText: String? = nil,
                displayUnit: ProviderUsageDisplayUnit, sourceDescription: String) {
        self.sourceID = sourceID; self.observedAt = observedAt; self.usedBytes = usedBytes; self.limitBytes = limitBytes
        self.remainingBytes = remainingBytes; self.resetsAt = resetsAt; self.resetDateText = resetDateText
        self.displayUnit = displayUnit; self.sourceDescription = sourceDescription
    }
    public var usedPercent: Double { limitBytes == 0 ? 0 : Double(usedBytes) / Double(limitBytes) * 100 }
    public var remaining: UInt64 { remainingBytes ?? (limitBytes > usedBytes ? limitBytes - usedBytes : 0) }
    public func validate(now: Date = Date()) throws {
        guard limitBytes > 0, limitBytes <= Self.maximumBytes, usedBytes <= Self.maximumBytes,
              remainingBytes.map({ $0 <= Self.maximumBytes }) ?? true,
              Self.validDate(observedAt), observedAt <= now.addingTimeInterval(300),
              resetsAt.map(Self.validDate) ?? true,
              sourceDescription.count <= 160, !sourceDescription.isEmpty,
              !sourceDescription.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ProviderUsageFailure.invalidResponse }
        if let resetDateText {
            let components = resetDateText.split(separator: "-", omittingEmptySubsequences: false)
            guard resetDateText.count == 10, components.count == 3,
                  components[0].count == 4, components[1].count == 2, components[2].count == 2,
                  let year = Int(components[0]), let month = Int(components[1]), let day = Int(components[2]),
                  (2000...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { throw ProviderUsageFailure.invalidResponse }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { throw ProviderUsageFailure.invalidResponse }
        }
    }
    public static let maximumBytes: UInt64 = 9_000_000_000_000_000
    public static func validDate(_ value: Date) -> Bool {
        value.timeIntervalSince1970.isFinite && (0...253_402_300_799).contains(value.timeIntervalSince1970)
    }
}

public enum ProviderUsageStatus: String, Sendable {
    case pending, ready, stale, authenticationRequired, failed
    public var title: String {
        switch self { case .pending: "等待连接"; case .ready: "已更新"; case .stale: "等待更新"; case .authenticationRequired: "需要重新连接"; case .failed: "更新失败" }
    }
}

/// A change seen in provider responses, never an inferred billing instant or timezone.
public struct ProviderUsageResetObservation: Codable, Equatable, Sendable, Identifiable {
    public var previousResetDateText: String
    public var resetDateText: String
    public var lastOldObservedAt: Date
    public var firstNewObservedAt: Date
    public var confirmedAt: Date?
    public var limitBytes: UInt64
    public var firstNewUsedBytes: UInt64
    public var firstNewRemainingBytes: UInt64
    public var id: String { resetDateText + ":" + String(firstNewObservedAt.timeIntervalSince1970) }

    public init(previousResetDateText: String, resetDateText: String, lastOldObservedAt: Date,
                firstNewObservedAt: Date, confirmedAt: Date? = nil, limitBytes: UInt64,
                firstNewUsedBytes: UInt64, firstNewRemainingBytes: UInt64) {
        self.previousResetDateText = previousResetDateText; self.resetDateText = resetDateText
        self.lastOldObservedAt = lastOldObservedAt; self.firstNewObservedAt = firstNewObservedAt
        self.confirmedAt = confirmedAt; self.limitBytes = limitBytes
        self.firstNewUsedBytes = firstNewUsedBytes; self.firstNewRemainingBytes = firstNewRemainingBytes
    }

    public func validate(now: Date = Date()) throws {
        guard Self.validDateText(previousResetDateText), Self.validDateText(resetDateText),
              previousResetDateText < resetDateText,
              ProviderUsageSnapshot.validDate(lastOldObservedAt), ProviderUsageSnapshot.validDate(firstNewObservedAt),
              lastOldObservedAt < firstNewObservedAt, firstNewObservedAt <= now.addingTimeInterval(300),
              confirmedAt.map({ ProviderUsageSnapshot.validDate($0) && $0 > firstNewObservedAt && $0 <= now.addingTimeInterval(300) }) ?? true,
              limitBytes > 0, limitBytes <= ProviderUsageSnapshot.maximumBytes,
              firstNewUsedBytes <= ProviderUsageSnapshot.maximumBytes,
              firstNewRemainingBytes <= ProviderUsageSnapshot.maximumBytes else { throw ProviderUsageFailure.storage }
    }

    private static func validDateText(_ text: String) -> Bool {
        guard text.count == 10 else { return false }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (2000...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: .init(year: year, month: month, day: day)) else { return false }
        return calendar.component(.month, from: date) == month && calendar.component(.day, from: date) == day
    }
}

public struct ProviderUsageSourceState: Codable, Equatable, Sendable {
    public var snapshot: ProviderUsageSnapshot?
    public var refresh: ProviderUsageRefreshState
    public var message: String?
    public var resetObservations: [ProviderUsageResetObservation]
    public var pendingResetObservation: ProviderUsageResetObservation?
    public static let maximumResetObservations = 12
    public init(snapshot: ProviderUsageSnapshot? = nil, refresh: ProviderUsageRefreshState = .init(), message: String? = nil,
                resetObservations: [ProviderUsageResetObservation] = [], pendingResetObservation: ProviderUsageResetObservation? = nil) {
        self.snapshot = snapshot; self.refresh = refresh; self.message = message
        self.resetObservations = resetObservations; self.pendingResetObservation = pendingResetObservation
    }
    private enum CodingKeys: String, CodingKey { case snapshot, refresh, message, resetObservations, pendingResetObservation }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try values.decodeIfPresent(ProviderUsageSnapshot.self, forKey: .snapshot)
        refresh = try values.decode(ProviderUsageRefreshState.self, forKey: .refresh)
        message = try values.decodeIfPresent(String.self, forKey: .message)
        resetObservations = try values.decodeIfPresent([ProviderUsageResetObservation].self, forKey: .resetObservations) ?? []
        pendingResetObservation = try values.decodeIfPresent(ProviderUsageResetObservation.self, forKey: .pendingResetObservation)
        try validateResetObservations()
    }
    public func validateResetObservations(now: Date = Date()) throws {
        guard resetObservations.count <= Self.maximumResetObservations else { throw ProviderUsageFailure.storage }
        var previous: ProviderUsageResetObservation?
        for observation in resetObservations {
            try observation.validate(now: now)
            guard observation.confirmedAt != nil else { throw ProviderUsageFailure.storage }
            if let previous {
                guard previous.resetDateText < observation.resetDateText,
                      previous.firstNewObservedAt < observation.firstNewObservedAt else { throw ProviderUsageFailure.storage }
            }
            previous = observation
        }
        if let pendingResetObservation {
            try pendingResetObservation.validate(now: now)
            guard pendingResetObservation.confirmedAt == nil else { throw ProviderUsageFailure.storage }
            if let previous {
                guard previous.resetDateText < pendingResetObservation.resetDateText,
                      previous.firstNewObservedAt < pendingResetObservation.firstNewObservedAt else { throw ProviderUsageFailure.storage }
            }
        }
    }

    /// Call before replacing `snapshot`. A second coherent response confirms only
    /// that the new provider cycle was observed; polling cannot identify its timezone.
    public mutating func recordResetObservation(_ next: ProviderUsageSnapshot, kind: ProviderUsageKind) {
        guard kind == .iproyal, let old = snapshot, old.sourceID == next.sourceID,
              let oldDate = old.resetDateText, let newDate = next.resetDateText,
              old.resetsAt == nil, next.resetsAt == nil else { pendingResetObservation = nil; return }
        // A replay is not another observation and cannot confirm or discard one.
        guard next.observedAt > old.observedAt else { return }
        if var pending = pendingResetObservation {
            if newDate == pending.resetDateText, oldDate == pending.resetDateText,
               next.limitBytes == pending.limitBytes, next.usedBytes >= pending.firstNewUsedBytes,
               next.remaining <= pending.firstNewRemainingBytes,
               next.observedAt > pending.firstNewObservedAt {
                pending.confirmedAt = next.observedAt
                resetObservations.append(pending)
                resetObservations = Array(resetObservations.suffix(Self.maximumResetObservations))
                pendingResetObservation = nil
                return
            }
            pendingResetObservation = nil
        }
        guard newDate > oldDate, next.limitBytes == old.limitBytes,
              next.usedBytes < old.usedBytes, next.remaining > old.remaining,
              resetObservations.last.map({ $0.resetDateText < newDate }) ?? true else { return }
        let candidate = ProviderUsageResetObservation(previousResetDateText: oldDate, resetDateText: newDate,
            lastOldObservedAt: old.observedAt, firstNewObservedAt: next.observedAt, limitBytes: next.limitBytes,
            firstNewUsedBytes: next.usedBytes, firstNewRemainingBytes: next.remaining)
        guard (try? candidate.validate(now: next.observedAt)) != nil else { return }
        pendingResetObservation = candidate
    }
    public func status(at now: Date = Date(), maximumAge: TimeInterval = 21_600) -> ProviderUsageStatus {
        if refresh.authenticationRequired { return .authenticationRequired }
        if refresh.failureCount > 0 { return .failed }
        guard let snapshot else { return .pending }
        if now.timeIntervalSince(snapshot.observedAt) > maximumAge || snapshot.resetsAt.map({ $0 <= now }) == true { return .stale }
        return .ready
    }
}

public enum ProviderUsageFailure: Error, LocalizedError, Sendable, Equatable {
    case authentication, rateLimited(retryAfter: TimeInterval?), unavailable(String), invalidResponse
    case transport, server(Int), cancelled, invalidConfiguration, credentials, storage
    public var errorDescription: String? {
        switch self {
        case .authentication: "认证已失效，请重新连接此来源。"
        case .rateLimited: "服务商暂时限制查询频率，稍后将重试。"
        case .unavailable(let message): String(message.prefix(240))
        case .invalidResponse: "服务商返回的用量格式无效，已保留最后一次有效读数。"
        case .transport: "暂时无法连接服务商，稍后将重试。"
        case .server(let status): "服务商暂时无法提供用量（\(status)）。"
        case .cancelled: "本次查询已取消。"
        case .invalidConfiguration: "请检查名称、订单或实例编号及刷新设置。"
        case .credentials: "无法访问本机钥匙串，原连接未被替换。"
        case .storage: "用量配置或记录无法保存，原文件已保留。"
        }
    }
}
