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
    public let detail: String

    public init(cpu: Double?, gpu: Double?, state: DeviceThermalState, rule: DeviceTemperatureRule = .init(),
                isLoading: Bool = false, unavailableReason: String? = nil) {
        let severe = state == .serious || state == .critical
        cpuLevel = Self.sensorLevel(cpu, threshold: rule.cpuThreshold, severe: severe)
        gpuLevel = Self.sensorLevel(gpu, threshold: rule.gpuThreshold, severe: severe)
        let hasTemperature = cpuLevel != .unknown || gpuLevel != .unknown
        let completeTemperatures = cpuLevel != .unknown && gpuLevel != .unknown
        let basis: String
        if severe {
            level = .critical
            title = state == .critical ? "严重高温" : "系统高温"
            basis = "macOS 报告\(state == .critical ? "临界" : "严重")热压力；请降低持续负载并保持散热通畅。"
        } else if cpuLevel == .warning || gpuLevel == .warning {
            level = .warning; title = "温度偏高"
            basis = "有效温度读数已达到 DeskDen 的自定义提醒阈值；此阈值不是 Apple 安全上限。"
        } else if state == .fair {
            level = .warning; title = "轻度升温"
            basis = "macOS 报告轻度热压力；系统正在自动调节散热。"
        } else if state == .nominal {
            level = .normal; title = completeTemperatures ? "正常" : "系统正常"
            basis = completeTemperatures ? "macOS 热压力正常，CPU 与 GPU 温度均未达到提醒阈值。" :
                "macOS 热压力正常；缺失的温度读数仍不可用，不能据此判断对应传感器是否达到提醒阈值。"
        } else if hasTemperature {
            level = .normal; title = "温度正常"
            basis = "仅依据已读到的有效温度判断，均未达到提醒阈值；macOS 热压力状态暂不可用。"
        } else {
            level = .unknown; title = isLoading ? "读取中" : "状态未知"
            basis = isLoading ? "正在读取温度传感器与 macOS 热压力状态。" : "温度与 macOS 热压力均不可用，无法判断散热状态。"
        }
        let missing = [("CPU", cpuLevel), ("GPU", gpuLevel)].compactMap { $0.1 == .unknown ? $0.0 : nil }
        let missingDetail = missing.isEmpty || (isLoading && state == .unknown && !hasTemperature) ? nil :
            (unavailableReason?.isEmpty == false ? unavailableReason : "\(missing.joined(separator: "、")) 温度传感器未返回有效读数。")
        detail = [basis, missingDetail].compactMap { $0 }.joined(separator: "\n")
        symbol = level == .critical ? "exclamationmark.triangle" : level == .unknown ? "questionmark.circle" : "thermometer.medium"
    }

    private static func sensorLevel(_ value: Double?, threshold: Double, severe: Bool) -> DeviceThermalLevel {
        guard let value, value.isFinite, value > 0, value <= 150 else { return .unknown }
        if severe { return .critical }
        return value >= threshold ? .warning : .normal
    }
}
