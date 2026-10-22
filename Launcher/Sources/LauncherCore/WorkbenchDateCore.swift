import Foundation

public enum WorkbenchDateError: LocalizedError {
    case invalidTimeZone, invalidDate
    public var errorDescription: String? { self == .invalidTimeZone ? "展示时区无效，请选择有效的 IANA 时区。" : "无法计算所选日期。" }
}
public struct WorkbenchLunarDate: Equatable, Sendable {
    public var month: Int
    public var day: Int
    public var isLeapMonth: Bool
    public var displayText: String {
        let months = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
        let digits = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        guard (1...12).contains(month), (1...30).contains(day) else { return "农历不可用" }
        let dayText: String
        switch day { case 1...10: dayText = "初" + digits[day - 1]
        case 11...19: dayText = "十" + digits[day - 11]
        case 20: dayText = "二十"
        case 21...29: dayText = "廿" + digits[day - 21]
        default: dayText = "三十" }
        return (isLeapMonth ? "闰" : "") + months[month - 1] + "月" + dayText
    }
}
public struct WorkbenchDisplayDate: Equatable, Sendable {
    public var instant: Date
    public var dayKey: String
    public var dateText: String
    public var timeText: String
    public var weekdayText: String
    public var timeZoneIdentifier: String
    public var timeZoneAbbreviation: String
    public var secondsFromGMT: Int
    public var dayInterval: DateInterval
    public var lunarDate: WorkbenchLunarDate?
    public var holiday: WorkbenchHolidayLookup
}

/// A display-only calendar. It never edits ReminderDueDate or notification scheduling.
public struct WorkbenchDateContext: Equatable, Codable, Sendable {
    public let timeZoneIdentifier: String
    public init(timeZoneIdentifier: String) throws {
        guard TimeZone.knownTimeZoneIdentifiers.contains(timeZoneIdentifier) || timeZoneIdentifier == "GMT" || timeZoneIdentifier == "UTC" else { throw WorkbenchDateError.invalidTimeZone }
        self.timeZoneIdentifier = timeZoneIdentifier
    }
    private enum CodingKeys: String, CodingKey { case timeZoneIdentifier }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(timeZoneIdentifier: values.decode(String.self, forKey: .timeZoneIdentifier))
    }
    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier)! }
    public var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = timeZone; value.firstWeekday = 2; return value }
    public func display(at instant: Date = Date()) throws -> WorkbenchDisplayDate {
        guard instant.timeIntervalSince1970.isFinite, abs(instant.timeIntervalSince1970) < 100_000_000_000,
              let interval = calendar.dateInterval(of: .day, for: instant) else { throw WorkbenchDateError.invalidDate }
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: instant)
        guard let year = parts.year, let month = parts.month, let day = parts.day, let weekday = parts.weekday else { throw WorkbenchDateError.invalidDate }
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        var lunarCalendar = Calendar(identifier: .chinese); lunarCalendar.timeZone = timeZone
        let lunar = lunarCalendar.dateComponents([.month, .day, .isLeapMonth], from: instant)
        let lunarDate: WorkbenchLunarDate? = if let lm = lunar.month, let ld = lunar.day, (1...12).contains(lm), (1...30).contains(ld) {
            .init(month: lm, day: ld, isLeapMonth: lunar.isLeapMonth ?? false)
        } else { nil }
        return .init(instant: instant, dayKey: key, dateText: "\(year) 年 \(month) 月 \(day) 日", timeText: formatter.string(from: instant),
                     weekdayText: ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"][weekday - 1],
                     timeZoneIdentifier: timeZoneIdentifier, timeZoneAbbreviation: timeZone.abbreviation(for: instant) ?? timeZoneIdentifier,
                     secondsFromGMT: timeZone.secondsFromGMT(for: instant), dayInterval: interval, lunarDate: lunarDate,
                     holiday: WorkbenchChinaHolidays.lookup(dayKey: key))
    }
    public func isSameDisplayDay(_ lhs: Date, _ rhs: Date) -> Bool { calendar.isDate(lhs, inSameDayAs: rhs) }
    public func addingDays(_ count: Int, to date: Date) -> Date? { calendar.date(byAdding: .day, value: count, to: date) }
    public func validated() throws -> Self { try .init(timeZoneIdentifier: timeZoneIdentifier) }
}

public enum WorkbenchHolidayKind: String, Codable, Equatable, Sendable { case holiday, workingDay }
public struct WorkbenchHoliday: Codable, Equatable, Sendable {
    public var dayKey: String
    public var name: String
    public var kind: WorkbenchHolidayKind
}
public enum WorkbenchHolidayLookup: Equatable, Sendable {
    /// Only official mainland China annual arrangements are included, not a legal payroll calendar.
    case recorded(WorkbenchHoliday)
    case noSpecialArrangement
    case yearNotIncluded
    case invalidDate
}
public enum WorkbenchChinaHolidays {
    public static let datasetVersion = "CN-2026-2025-11-04.1"
    public static let includedYears: Set<Int> = [2026]
    public static let sourceTitle = "国务院办公厅关于2026年部分节假日安排的通知 · 国办发明电〔2025〕7号"
    public static let sourceURL = URL(string: "https://www.gov.cn/zhengce/content/202511/content_7047090.htm")!
    /// Official municipal republication verified 2026-10-21 when the central page returned 403.
    public static let verifiedMirrorURL = URL(string: "https://www.beijing.gov.cn/cs/gncs/zcwj/202603/t20260327_4568275.html")!
    public static func lookup(dayKey: String) -> WorkbenchHolidayLookup {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, dayKey.count == 10 else { return .invalidDate }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.component(.year, from: date) == parts[0], calendar.component(.month, from: date) == parts[1],
              calendar.component(.day, from: date) == parts[2] else { return .invalidDate }
        guard includedYears.contains(parts[0]) else { return .yearNotIncluded }
        if let entry = entries[dayKey] { return .recorded(entry) }
        return .noSpecialArrangement
    }
    public static let entries: [String: WorkbenchHoliday] = {
        var result: [String: WorkbenchHoliday] = [:]
        let ranges: [(Int, Int, Int, String)] = [(1, 1, 3, "元旦"), (2, 15, 23, "春节"), (4, 4, 6, "清明节"),
            (5, 1, 5, "劳动节"), (6, 19, 21, "端午节"), (9, 25, 27, "中秋节"), (10, 1, 7, "国庆节")]
        for (month, start, end, name) in ranges {
            for day in start...end {
                let key = String(format: "2026-%02d-%02d", month, day)
                result[key] = .init(dayKey: key, name: name, kind: .holiday)
            }
        }
        for (month, day, name) in [(1, 4, "元旦调休上班"), (2, 14, "春节调休上班"), (2, 28, "春节调休上班"),
                                    (5, 9, "劳动节调休上班"), (9, 20, "国庆节调休上班"), (10, 10, "国庆节调休上班")] {
            let key = String(format: "2026-%02d-%02d", month, day)
            result[key] = .init(dayKey: key, name: name, kind: .workingDay)
        }
        return result
    }()
}
