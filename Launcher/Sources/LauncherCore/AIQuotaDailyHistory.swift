import Foundation

/// One real observation, not a computed total of a day's quota consumption.
public struct AIQuotaDailyReading: Equatable, Sendable {
    public var observedAt: Date
    public var source: AIQuotaSource
    public var window: AIQuotaWindow
}

public struct AIQuotaDailyCell: Identifiable, Equatable, Sendable {
    public var date: Date
    /// Calendar alignment includes padding outside the retained display range.
    public var isInRange: Bool
    public var reading: AIQuotaDailyReading?
    public var id: Date { date }
}

public struct AIQuotaDailyWindowSeries: Identifiable, Equatable, Sendable {
    public var durationMinutes: Int
    public var days: [AIQuotaDailyCell]
    public var id: Int { durationMinutes }
    public var observedDayCount: Int { days.filter { $0.reading != nil }.count }
    public var title: String {
        durationMinutes == 10_080 ? "每周窗口" : durationMinutes % 60 == 0 ? "\(durationMinutes / 60) 小时窗口" : "\(durationMinutes) 分钟窗口"
    }
}

/// A day is shaded by its last valid observed reading of an actual window
/// duration. Resets and source switches remain in that reading's provenance;
/// snapshots are never added, interpolated, or converted into daily usage.
public struct AIQuotaDailyHistory: Equatable, Sendable {
    public var startDate: Date
    public var endDate: Date
    public var days: [AIQuotaDailyCell]
    public var series: [AIQuotaDailyWindowSeries]

    public static func build(_ snapshots: [AIQuotaSnapshot], provider: AIProvider,
                             now: Date = Date(), calendar: Calendar = .current,
                             dayCount: Int = 31) -> Self {
        let today = calendar.startOfDay(for: now)
        guard (1...366).contains(dayCount),
              let first = calendar.date(byAdding: .day, value: 1 - dayCount, to: today),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: first),
              let lastWeek = calendar.dateInterval(of: .weekOfYear, for: today) else {
            return .init(startDate: today, endDate: today, days: [], series: [])
        }
        var days: [AIQuotaDailyCell] = []
        var date = firstWeek.start
        while date < lastWeek.end {
            days.append(.init(date: date, isInRange: date >= first && date <= today, reading: nil))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }
        var readings: [Int: [Date: AIQuotaDailyReading]] = [:]
        // The source tie-break keeps rendering stable for simultaneous imports.
        let ordered = snapshots.filter {
            $0.provider == provider && $0.observedAt.timeIntervalSince1970.isFinite &&
                $0.observedAt.timeIntervalSince1970 > 0 && $0.observedAt >= first && $0.observedAt <= now
        }.sorted {
            $0.observedAt == $1.observedAt ? $0.source.rawValue < $1.source.rawValue : $0.observedAt < $1.observedAt
        }
        for snapshot in ordered {
            let day = calendar.startOfDay(for: snapshot.observedAt)
            var seenDurations = Set<Int>()
            for window in snapshot.availableWindows {
                guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                      (1...525_600).contains(window.durationMinutes),
                      window.resetsAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= snapshot.observedAt }) ?? true,
                      seenDurations.insert(window.durationMinutes).inserted else { continue }
                readings[window.durationMinutes, default: [:]][day] = .init(observedAt: snapshot.observedAt,
                    source: snapshot.source, window: window)
            }
        }
        let series = readings.keys.sorted().map { duration in
            AIQuotaDailyWindowSeries(durationMinutes: duration, days: days.map { cell in
                var value = cell
                value.reading = readings[duration]?[cell.date]
                return value
            })
        }
        return .init(startDate: first, endDate: today, days: days, series: series)
    }
}

/// Daily token metadata is independent from account quota snapshots. An absent
/// day stays nil: a directory scan does not establish whole-account coverage.
public enum AIDailyTokenHistory {
    public static func totals(_ records: [AITokenRecord], provider: AIProvider,
                              now: Date = Date(), calendar: Calendar = .current,
                              dayCount: Int = 31) -> [Date: AITokenCounts] {
        guard (1...366).contains(dayCount),
              let first = calendar.date(byAdding: .day, value: 1 - dayCount, to: calendar.startOfDay(for: now)) else { return [:] }
        var result: [Date: AITokenCounts] = [:]
        for record in AIUsageAggregation.deduplicate(records) where record.provider == provider &&
            record.timestamp >= first && record.timestamp <= now {
            let day = calendar.startOfDay(for: record.timestamp)
            result[day] = (result[day] ?? AITokenCounts()) + record.tokens
        }
        return result
    }
}
