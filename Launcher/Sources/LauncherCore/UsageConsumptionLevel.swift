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
