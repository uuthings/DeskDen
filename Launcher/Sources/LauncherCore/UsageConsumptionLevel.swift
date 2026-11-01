import Foundation

/// Shared visual state for consumed quota and occupied capacity. Notification
/// thresholds, system pressure, battery charge and task completion are separate.
public enum UsageConsumptionLevel: Int, Equatable, Sendable {
    case unknown = -1
    case normal = 0
    case warning = 1
    case critical = 2

    public static let warningPercent = 70.0
    public static let criticalPercent = 90.0

    public static func classify(percent: Double?) -> Self {
        guard let percent, percent.isFinite, percent >= 0 else { return .unknown }
        if percent >= criticalPercent { return .critical }
        if percent >= warningPercent { return .warning }
        return .normal
    }
}

/// Integer labels must never announce a consumption boundary before the raw
/// reading reaches it. Keep the raw percentage for bar length and severity.
public enum UsagePercentage {
    public static func valueText(_ percent: Double?) -> String {
        guard let percent, percent.isFinite, percent >= 0 else { return "—" }
        if percent > 0, percent < 1 { return "<1" }
        return String(format: "%.0f", percent.rounded(.down))
    }

    public static func text(_ percent: Double?) -> String {
        let value = valueText(percent)
        return value == "—" ? value : value + "%"
    }
}

/// Elapsed observation age is independent of the display calendar and never
/// causes a provider refresh. Truncate each displayed unit rather than rounding.
public enum UsageObservationAge {
    public static func text(since observedAt: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(observedAt)
        guard interval.isFinite, observedAt.timeIntervalSinceReferenceDate.isFinite else { return "时间不可用" }
        if interval < 1 { return "刚刚" }
        let seconds = Int(min(interval, Double(Int.max / 2)))
        if seconds < 60 { return "\(seconds)秒前" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分钟前" }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)小时" + (minutes % 60 > 0 ? "\(minutes % 60)分钟" : "") + "前"
        }
        return "\(hours / 24)天" + (hours % 24 > 0 ? "\(hours % 24)小时" : "") + "前"
    }
}
