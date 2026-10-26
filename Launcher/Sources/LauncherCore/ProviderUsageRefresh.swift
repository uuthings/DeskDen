import Foundation

public struct ProviderUsageRefreshPolicy: Codable, Equatable, Sendable {
    public var byteThreshold: UInt64
    public var minimumInterval: TimeInterval
    public var maximumInterval: TimeInterval
    public init(byteThreshold: UInt64 = 1_000_000_000, minimumInterval: TimeInterval = 3_600, maximumInterval: TimeInterval = 21_600) {
        self.byteThreshold = byteThreshold; self.minimumInterval = minimumInterval; self.maximumInterval = maximumInterval
    }
    public func validate() throws {
        guard (1_000_000...10_000_000_000_000).contains(byteThreshold), minimumInterval.isFinite, maximumInterval.isFinite,
              (60...604_800).contains(minimumInterval), (minimumInterval...604_800).contains(maximumInterval) else { throw ProviderUsageFailure.invalidConfiguration }
    }
}

/// A stable physical-network ledger, independent of display interfaces or budget periods.
public struct ProviderPhysicalTrafficCounter: Codable, Equatable, Sendable {
    public var epoch: Date
    public var received: UInt64
    public var sent: UInt64
    public init(epoch: Date, received: UInt64, sent: UInt64) { self.epoch = epoch; self.received = received; self.sent = sent }
}

public struct ProviderUsageRefreshState: Codable, Equatable, Sendable {
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    public var retryNotBefore: Date?
    public var rateLimitUntil: Date?
    public var lastResetChecked: Date?
    public var failureCount: Int = 0
    public var authenticationRequired = false
    public var pendingBytes: UInt64 = 0
    public var trafficCheckpoint: ProviderPhysicalTrafficCounter?
    public init() {}
    public mutating func ingest(_ counter: ProviderPhysicalTrafficCounter) {
        defer { trafficCheckpoint = counter }
        guard let old = trafficCheckpoint, counter.epoch == old.epoch,
              counter.received >= old.received, counter.sent >= old.sent else { return }
        pendingBytes = Self.add(pendingBytes, Self.add(counter.received - old.received, counter.sent - old.sent))
    }
    public func isDue(at now: Date, policy: ProviderUsageRefreshPolicy, manual: Bool = false, resetAt: Date? = nil) -> Bool {
        guard !authenticationRequired, retryNotBefore.map({ now >= $0 }) ?? true,
              rateLimitUntil.map({ now >= $0 }) ?? true else { return false }
        if manual { return true }
        guard let success = lastSuccessAt else {
            return (lastAttemptAt.map({ now.timeIntervalSince($0) >= policy.minimumInterval }) ?? true) || retryNotBefore != nil
        }
        let elapsed = now.timeIntervalSince(success)
        guard elapsed >= policy.minimumInterval else { return false }
        let resetDue = resetAt.map { $0 <= now && $0 != lastResetChecked } ?? false
        return resetDue || failureCount > 0 || elapsed >= policy.maximumInterval || pendingBytes >= policy.byteThreshold
    }
    /// Returns the amount acknowledged only if this request succeeds.
    public mutating func begin(at now: Date) -> UInt64 {
        lastAttemptAt = now
        return pendingBytes
    }
    public mutating func succeeded(at now: Date, acknowledgedBytes: UInt64, checkedReset: Date? = nil) {
        pendingBytes = pendingBytes >= acknowledgedBytes ? pendingBytes - acknowledgedBytes : 0
        lastSuccessAt = now; failureCount = 0; retryNotBefore = nil; authenticationRequired = false
        if let checkedReset, checkedReset <= now { lastResetChecked = checkedReset }
        if rateLimitUntil.map({ $0 <= now }) == true { rateLimitUntil = nil }
    }
    public mutating func failed(_ failure: ProviderUsageFailure, at now: Date) {
        if failure == .cancelled { return }
        failureCount = min(20, failureCount + 1)
        authenticationRequired = failure == .authentication
        let backoff = min(21_600, 300 * pow(2, Double(min(7, max(0, failureCount - 1)))))
        if case .rateLimited(let delay) = failure {
            let delay = delay.flatMap { $0.isFinite ? min(604_800, max(0, $0)) : nil } ?? 0
            let until = now.addingTimeInterval(max(backoff, delay))
            retryNotBefore = until; rateLimitUntil = max(rateLimitUntil ?? now, until)
        } else { retryNotBefore = now.addingTimeInterval(backoff) }
    }
    public mutating func reconnect() { authenticationRequired = false; retryNotBefore = nil; failureCount = 0; lastAttemptAt = nil }
    public func validate() throws {
        guard (0...20).contains(failureCount), [lastSuccessAt, lastAttemptAt, retryNotBefore, rateLimitUntil, lastResetChecked].compactMap({ $0 }).allSatisfy(ProviderUsageSnapshot.validDate),
              trafficCheckpoint.map({ ProviderUsageSnapshot.validDate($0.epoch) }) ?? true else { throw ProviderUsageFailure.storage }
    }
    private static func add(_ a: UInt64, _ b: UInt64) -> UInt64 { let (value, overflow) = a.addingReportingOverflow(b); return overflow ? .max : value }
}
