import Foundation

/// Observed usage totals, not an assertion of complete account coverage.
public struct AITokenMonthSummary: Codable, Equatable, Identifiable, Sendable {
    public var provider: AIProvider
    public var month: Date
    public var tokens: AITokenCounts
    public var recordCount: Int
    public var id: String { provider.rawValue + ":" + String(month.timeIntervalSince1970) }
    public var title: String {
        let parts = Self.calendar.dateComponents([.year, .month], from: month)
        return "\(parts.year ?? 0)年\(parts.month ?? 0)月"
    }
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar
    }
    static func month(containing date: Date) throws -> Date {
        guard date.timeIntervalSince1970.isFinite, (0...100_000_000_000).contains(date.timeIntervalSince1970),
              let month = calendar.dateInterval(of: .month, for: date)?.start else {
            throw AIUsageError.invalid("Token 月度日期超出支持范围。")
        }
        return month
    }
    static func checkedAdd(_ lhs: AITokenCounts, _ rhs: AITokenCounts) throws -> AITokenCounts {
        func add(_ a: Int64, _ b: Int64) throws -> Int64 {
            let result = a.addingReportingOverflow(b)
            guard a >= 0, b >= 0, !result.overflow else { throw AIUsageError.invalid("Token 月度汇总超出支持范围。") }
            return result.partialValue
        }
        let result = try AITokenCounts(input: add(lhs.input, rhs.input), output: add(lhs.output, rhs.output),
                                       cacheRead: add(lhs.cacheRead, rhs.cacheRead), cacheWrite: add(lhs.cacheWrite, rhs.cacheWrite))
        _ = try [result.input, result.output, result.cacheRead, result.cacheWrite].reduce(Int64(0)) { try add($0, $1) }
        return result
    }
    static func merged(_ summaries: [Self], records: [AITokenRecord], now: Date) throws -> [Self] {
        var values = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        for record in records {
            let month = try month(containing: record.timestamp)
            var summary = Self(provider: record.provider, month: month, tokens: .init(), recordCount: 0)
            summary = values[summary.id] ?? summary
            summary.tokens = try checkedAdd(summary.tokens, record.tokens)
            let count = summary.recordCount.addingReportingOverflow(1)
            guard !count.overflow else { throw AIUsageError.invalid("Token 月度记录数超出支持范围。") }
            summary.recordCount = count.partialValue; values[summary.id] = summary
        }
        let currentMonth = try month(containing: now)
        guard let earliest = calendar.date(byAdding: .month, value: -(AITokenLedger.maximumSummaryMonths - 1), to: currentMonth) else {
            throw AIUsageError.invalid("Token 月度保留范围无效。")
        }
        return values.values.filter { $0.month >= earliest && $0.month <= currentMonth }.sorted {
            $0.month == $1.month ? $0.provider.rawValue < $1.provider.rawValue : $0.month < $1.month
        }
    }
}
