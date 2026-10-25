import Foundation

/// A compacted month retains measured totals and coverage, never fabricated daily samples.
public struct DeviceNetworkMonth: Codable, Equatable, Sendable {
    public var totals: DeviceNetworkDay
    public var firstDay: String
    public var lastDay: String
    public var recordedDays: Int

    init(day: String, value: DeviceNetworkDay) {
        totals = value; firstDay = day; lastDay = day
        recordedDays = value.coveredSeconds > 0 ? 1 : 0
    }
    mutating func append(day: String, value: DeviceNetworkDay) {
        totals.merge(value); firstDay = min(firstDay, day); lastDay = max(lastDay, day)
        if value.coveredSeconds > 0 { recordedDays += 1 }
    }
}

extension DeviceNetworkDay {
    mutating func merge(_ other: Self) {
        func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
            let result = a.addingReportingOverflow(b); return result.overflow ? .max : result.partialValue
        }
        received = add(received, other.received); sent = add(sent, other.sent)
        coveredSeconds = min(1_000_000_000_000, coveredSeconds + other.coveredSeconds)
        let excluded = excludedIntervals.addingReportingOverflow(other.excludedIntervals)
        excludedIntervals = excluded.overflow ? 1_000_000_000 : min(1_000_000_000, excluded.partialValue)
        firstSample = [firstSample, other.firstSample].compactMap { $0 }.min()
        lastSample = [lastSample, other.lastSample].compactMap { $0 }.max()
    }
}

extension DeviceNetworkLedger {
    mutating func compactHistory() {
        guard days.count > Self.maximumDailyRecords else { return }
        for key in days.keys.sorted().dropLast(Self.maximumDailyRecords) {
            guard let day = days.removeValue(forKey: key) else { continue }
            let month = String(key.prefix(7))
            if archivedMonths[month] != nil { archivedMonths[month]?.append(day: key, value: day) }
            else { archivedMonths[month] = .init(day: key, value: day) }
            compactedThroughDay = max(compactedThroughDay ?? key, key)
        }
        for key in archivedMonths.keys.sorted().dropLast(Self.maximumArchivedMonths) {
            archivedMonths.removeValue(forKey: key); olderHistoryExpired = true
        }
    }

    func validateArchivedMonths() throws {
        let calendar = Calendar(identifier: .gregorian)
        func validKey(_ key: String) -> Bool { Self.date(forDay: key, calendar: calendar) != nil }
        if let watermark = compactedThroughDay {
            guard validKey(watermark), days.keys.allSatisfy({ $0 > watermark }) else { throw DeviceNetworkLedgerError.invalidFields }
        } else if !archivedMonths.isEmpty { throw DeviceNetworkLedgerError.invalidFields }
        for (key, month) in archivedMonths {
            let total = month.totals
            guard key.count == 7, validKey(month.firstDay), validKey(month.lastDay), month.firstDay <= month.lastDay,
                  month.firstDay.hasPrefix(key + "-"), month.lastDay.hasPrefix(key + "-"),
                  month.lastDay <= (compactedThroughDay ?? ""), (0...31).contains(month.recordedDays),
                  total.coveredSeconds.isFinite, (0...1_000_000_000_000).contains(total.coveredSeconds),
                  (0...1_000_000_000).contains(total.excludedIntervals),
                  total.firstSample.map({ $0.timeIntervalSince1970.isFinite && abs($0.timeIntervalSince1970) <= 100_000_000_000 }) ?? true,
                  total.lastSample.map({ $0.timeIntervalSince1970.isFinite && abs($0.timeIntervalSince1970) <= 100_000_000_000 }) ?? true else {
                throw DeviceNetworkLedgerError.invalidFields
            }
            if let first = total.firstSample, let last = total.lastSample, first > last { throw DeviceNetworkLedgerError.invalidFields }
        }
    }

    public static func date(forDay key: String, calendar: Calendar) -> Date? {
        guard key.count == 10 else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = DeviceBudgetDate(year: parts[0], month: parts[1], day: parts[2]).date(in: calendar),
              dayKey(date, calendar: calendar) == key else { return nil }
        return date
    }
}

/// One bounded coalescing timer per store; failures remain dirty and retry at the next interval.
public struct DevicePersistenceSchedule: Sendable {
    public private(set) var dirty = false
    private var lastAttempt: TimeInterval?
    public init() {}
    public mutating func markChanged() { dirty = true }
    public mutating func beginWrite(at uptime: TimeInterval, force: Bool = false) -> Bool {
        guard dirty, force || (lastAttempt.map({ uptime < $0 || uptime - $0 >= 30 }) ?? true) else { return false }
        lastAttempt = uptime; return true
    }
    public mutating func didWrite() { dirty = false }
}
