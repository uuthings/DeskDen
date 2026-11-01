import Foundation

/// Presentation uses real sensor temperatures and macOS thermal pressure. It is
/// independent of notification opt-in and never treats temperature as a quota.
public enum DeviceThermalLevel: String, Equatable, Sendable {
    case normal, warning, critical, unknown
}

public struct DeviceThermalPresentation: Equatable, Sendable {
    public let level: DeviceThermalLevel
    public let cpuLevel: DeviceThermalLevel
    public let gpuLevel: DeviceThermalLevel
    public let title: String
    public let symbol: String

    public init(cpu: Double?, gpu: Double?, state: DeviceThermalState, rule: DeviceTemperatureRule = .init()) {
        let severe = state == .serious || state == .critical
        cpuLevel = Self.sensorLevel(cpu, threshold: rule.cpuThreshold, severe: severe)
        gpuLevel = Self.sensorLevel(gpu, threshold: rule.gpuThreshold, severe: severe)
        if severe {
            level = .critical
            title = state == .critical ? "严重高温" : "系统高温"
        } else if cpuLevel == .warning || gpuLevel == .warning {
            level = .warning; title = "温度偏高"
        } else if state == .fair {
            level = .warning; title = "轻度升温"
        } else if state == .unknown || cpuLevel == .unknown || gpuLevel == .unknown {
            level = .unknown; title = "状态未知"
        } else {
            level = .normal; title = "正常"
        }
        symbol = level == .critical ? "exclamationmark.triangle" : level == .unknown ? "questionmark.circle" : "thermometer.medium"
    }

    private static func sensorLevel(_ value: Double?, threshold: Double, severe: Bool) -> DeviceThermalLevel {
        guard let value, value.isFinite, value > 0, value <= 150 else { return .unknown }
        if severe { return .critical }
        return value >= threshold ? .warning : .normal
    }
}
