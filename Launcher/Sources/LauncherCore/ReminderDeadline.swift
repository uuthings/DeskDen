import Foundation

public enum ReminderDeadlineMode: String, CaseIterable, Identifiable, Sendable {
    case none, date, days
    public var id: String { rawValue }
    public var title: String {
        switch self { case .none: "无期限"; case .date: "指定日期"; case .days: "指定天数" }
    }
}

public enum ReminderDayBasis: String, CaseIterable, Identifiable, Sendable {
    case everyday, weekdays
    public var id: String { rawValue }
    public var title: String { self == .everyday ? "每天" : "周一至周五" }
}

/// This is a draft input rule, not a moving deadline. Saving resolves it to ReminderDue.
public struct ReminderCountingRule: Equatable, Sendable {
    public var daysBasis: ReminderDayBasis
    public var skipHolidays: Bool
    public var includeMakeupWorkdays: Bool
    public init(daysBasis: ReminderDayBasis = .everyday, skipHolidays: Bool = false, includeMakeupWorkdays: Bool = false) {
        self.daysBasis = daysBasis
        self.skipHolidays = skipHolidays
        self.includeMakeupWorkdays = includeMakeupWorkdays
    }
    public var needsHolidayData: Bool { skipHolidays || includeMakeupWorkdays }
}

public enum ReminderDeadlineCalculator {
    public static let allowedDayCounts = 1...3650

    public static func dayCount(from text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(trimmed), allowedDayCounts.contains(value) else {
            throw ReminderError.invalid("请输入 1 至 3650 之间的整数天数。")
        }
        return value
    }

    /// Counts eligible civil days starting tomorrow in the draft's time zone.
    /// Noon is only a stable representative of the resulting day, not a reminder time.
    public static func resolve(daysText: String, anchor: Date, rule: ReminderCountingRule = .init(), calendar: Calendar = .current) throws -> Date {
        let count = try dayCount(from: daysText)
        guard anchor.timeIntervalSince1970.isFinite, abs(anchor.timeIntervalSince1970) < 1_000_000_000_000 else {
            throw ReminderError.invalid("起算日期无效。")
        }
        var civilCalendar = Calendar(identifier: .gregorian)
        civilCalendar.timeZone = calendar.timeZone
        let anchorParts = civilCalendar.dateComponents([.year, .month, .day], from: anchor)
        guard let year = anchorParts.year, (1...9999).contains(year),
              var cursor = civilCalendar.date(from: DateComponents(year: year, month: anchorParts.month, day: anchorParts.day, hour: 12)) else {
            throw ReminderError.invalid("起算日期无效。")
        }
        var remaining = count
        // Every weekday rule has at least five candidates each ordinary week. The
        // extra year makes a malformed future dataset fail rather than loop forever.
        for _ in 0..<(count * 7 + 366) {
            guard let next = civilCalendar.date(byAdding: .day, value: 1, to: cursor), next > cursor,
                  (1...9999).contains(civilCalendar.component(.year, from: next)) else {
                throw ReminderError.invalid("截止日期超出支持范围，请减少天数。")
            }
            cursor = next
            if try includes(cursor, rule: rule, calendar: civilCalendar) { remaining -= 1 }
            if remaining == 0 { return cursor }
        }
        throw ReminderError.invalid("无法按当前计日规则算出截止日期，请调整设置。")
    }

    private static func includes(_ day: Date, rule: ReminderCountingRule, calendar: Calendar) throws -> Bool {
        let weekday = calendar.component(.weekday, from: day)
        let ordinary = rule.daysBasis == .everyday || (2...6).contains(weekday)
        guard rule.needsHolidayData else { return ordinary }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let key = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        switch WorkbenchChinaHolidays.lookup(dayKey: key) {
        case .recorded(let holiday):
            if holiday.kind == .holiday && rule.skipHolidays { return false }
            if holiday.kind == .workingDay && rule.includeMakeupWorkdays { return true }
            return ordinary
        case .noSpecialArrangement: return ordinary
        case .yearNotIncluded:
            throw ReminderError.unavailable("尚无 \(parts.year!) 年中国大陆节假日数据。请关闭节假日和调休选项，或直接指定日期。")
        case .invalidDate: throw ReminderError.invalid("无法读取这个日期的节假日信息。")
        }
    }
}
