import Foundation

/// Dates written on workbench pages (现行规范 5.3). A full date carries the
/// year and pads month and day for aligned lists; a short date (G2) omits the
/// year, does not pad and puts no spaces between digits and characters.
/// Every function reads fields in the calendar's own time zone.
public enum WorkbenchDateText {
    private static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// 「11月7日」
    public static func monthDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    /// 「周六」
    public static func weekday(_ date: Date, calendar: Calendar) -> String {
        weekdays[(calendar.component(.weekday, from: date) + 6) % 7]
    }

    /// 「11月7日 周六」
    public static func monthDayWeekday(_ date: Date, calendar: Calendar) -> String {
        monthDay(date, calendar: calendar) + " " + weekday(date, calendar: calendar)
    }

    /// 「2026年11月」
    public static func yearMonth(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return "\(parts.year ?? 0)年\(parts.month ?? 0)月"
    }

    /// 「2026年11月07日」
    public static func full(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d年%02d月%02d日", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 「2026年11月07日 10:50」, the list form with date and time on one line.
    public static func fullWithTime(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return full(date, calendar: calendar) + String(format: " %02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// 「11月1日–11月30日」 with an inclusive end. Both ends carry the year
    /// when the range crosses a year boundary, or when a form asks for it.
    public static func range(_ start: Date, _ end: Date, calendar: Calendar, withYear: Bool = false) -> String {
        let first = calendar.component(.year, from: start), last = calendar.component(.year, from: end)
        guard first != last || withYear else { return monthDay(start, calendar: calendar) + "–" + monthDay(end, calendar: calendar) }
        return "\(first)年" + monthDay(start, calendar: calendar) + "–" + "\(last)年" + monthDay(end, calendar: calendar)
    }

    /// 「11/7」 for chart axes and other compact places.
    public static func axis(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }
}
