import Foundation

/// A reset instant and optional source-calendar metadata. A UNIX timestamp or
/// an ISO 8601 offset alone never establishes the provider's billing timezone.
public struct UsageResetTime: Equatable, Sendable {
    public var resetsAt: Date?
    public var dateText: String?
    public var sourceTimeZoneIdentifier: String?

    public init(resetsAt: Date?, dateText: String? = nil, sourceTimeZoneIdentifier: String? = nil) {
        self.resetsAt = resetsAt
        self.dateText = dateText
        self.sourceTimeZoneIdentifier = sourceTimeZoneIdentifier
    }

    public init(window: AIQuotaWindow) {
        self.init(resetsAt: window.resetsAt, sourceTimeZoneIdentifier: window.resetTimeZoneIdentifier)
    }

    public init(snapshot: ProviderUsageSnapshot) {
        self.init(resetsAt: snapshot.resetsAt, dateText: snapshot.resetDateText,
                  sourceTimeZoneIdentifier: snapshot.resetTimeZoneIdentifier)
    }

    public enum State: Equatable, Sendable {
        case unavailable, dateOnly, relative, absolute, imminent, waiting
    }

    public struct Details: Equatable, Sendable {
        public var state: State
        public var summary: String
        public var workbenchValue: String
        public var workbenchZone: String?
        public var sourceLabel: String
        public var sourceValue: String
        public var sourceZone: String?
        public var explanation: String
    }

    public func state(at now: Date, timeZone: TimeZone) -> State {
        guard let reset = validInstant else { return validDateText == nil ? .unavailable : .dateOnly }
        let remaining = reset.timeIntervalSince(now)
        if remaining <= 0 { return .waiting }
        if remaining < 60 { return .imminent }
        return .relative
    }

    public func summary(at now: Date = Date(), timeZone: TimeZone) -> String {
        switch state(at: now, timeZone: timeZone) {
        case .unavailable: return "未提供重置时间"
        case .dateOnly: return Self.shortDate(validDateText!) + "重置 · 具体时间未提供"
        case .waiting: return "已到重置时间，等待更新"
        case .imminent: return "即将重置"
        case .relative, .absolute:
            let minutes = Int(validInstant!.timeIntervalSince(now) / 60)
            let hours = minutes / 60
            if hours >= 24 {
                let days = hours / 24, remainder = hours % 24
                return "\(days)天" + (remainder > 0 ? "\(remainder)小时" : "") + "后重置"
            }
            let remainder = minutes % 60
            return (hours > 0 ? "\(hours)小时" : "") + (remainder > 0 ? "\(remainder)分钟" : "") + "后重置"
        }
    }

    public func details(at now: Date = Date(), timeZone: TimeZone) -> Details {
        let state = state(at: now, timeZone: timeZone)
        let summary = summary(at: now, timeZone: timeZone)
        let sourceZone = Self.sourceTimeZone(identifier: sourceTimeZoneIdentifier)
        guard let reset = validInstant else {
            if let date = validDateText {
                return .init(state: state, summary: summary, workbenchValue: "暂无法换算", workbenchZone: timeZone.identifier,
                             sourceLabel: "服务商日期", sourceValue: date,
                             sourceZone: sourceZone.map { $0.identifier + " · 具体时间未提供" } ?? "具体时间与来源时区未提供",
                             explanation: "服务商仅提供日期，保留原始日期。")
            }
            return .init(state: state, summary: summary, workbenchValue: "未提供重置时间", workbenchZone: timeZone.identifier,
                         sourceLabel: "来源时间", sourceValue: "未提供", sourceZone: sourceZone?.identifier,
                         explanation: "取得准确重置时刻后，再显示剩余时间与时区换算。")
        }
        return .init(state: state, summary: summary,
                     workbenchValue: Self.timestamp(reset, timeZone: timeZone),
                     workbenchZone: Self.timeZoneDescription(timeZone, at: reset),
                     sourceLabel: "来源时间",
                     sourceValue: sourceZone.map { Self.timestamp(reset, timeZone: $0) } ?? "来源时区未提供",
                     sourceZone: sourceZone.map { Self.timeZoneDescription($0, at: reset) },
                     explanation: sourceZone == nil
                        ? "按工作台时区显示；来源时区未提供。切换显示时区不会改变剩余时长。"
                        : "两个时区对应同一重置时刻；切换工作台时区不会改变剩余时长。")
    }

    public func help(at now: Date = Date(), timeZone: TimeZone) -> String {
        let value = details(at: now, timeZone: timeZone)
        return [value.summary, "工作台时间：" + value.workbenchValue,
                value.workbenchZone, value.sourceLabel + "：" + value.sourceValue, value.sourceZone]
            .compactMap { $0 }.joined(separator: "\n")
    }

    /// Accept only a named timezone explicitly supplied as source metadata.
    /// Abbreviations and serialized timestamp offsets are not billing calendars.
    public static func sourceTimeZone(identifier: String?) -> TimeZone? {
        guard let identifier, identifier.count <= 128,
              identifier == "UTC" || identifier == "GMT" || TimeZone.knownTimeZoneIdentifiers.contains(identifier) else { return nil }
        return TimeZone(identifier: identifier)
    }

    public static func timestamp(_ date: Date, timeZone: TimeZone, includeYear: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = includeYear ? "yyyy年M月d日 HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    public static func timeZoneDescription(_ timeZone: TimeZone, at date: Date) -> String {
        let offset = timeZone.secondsFromGMT(for: date), magnitude = abs(offset)
        let utc = String(format: "UTC%@%02d:%02d", offset >= 0 ? "+" : "−", magnitude / 3600, (magnitude % 3600) / 60)
        return timeZone.identifier + " · " + utc
    }

    private var validInstant: Date? {
        resetsAt.flatMap { ProviderUsageSnapshot.validDate($0) ? $0 : nil }
    }

    private var validDateText: String? {
        guard let dateText, dateText.count == 10 else { return nil }
        let parts = dateText.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (2000...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: .init(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        return dateText
    }

    private static func shortDate(_ value: String) -> String {
        let parts = value.split(separator: "-")
        return "\(Int(parts[1])!)月\(Int(parts[2])!)日"
    }
}
