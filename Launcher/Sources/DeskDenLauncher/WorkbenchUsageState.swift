import LauncherCore
import SwiftUI

extension ThemePalette {
    /// Only consumed quotas and occupied capacity use this scale. Callers with
    /// a 0...1 fraction must convert it to a percentage explicitly.
    func usageColor(forPercent percent: Double?) -> Color {
        switch UsageConsumptionLevel.classify(percent: percent) {
        case .unknown: muted
        case .normal: accent
        case .warning: warning
        case .critical: critical
        }
    }
}
