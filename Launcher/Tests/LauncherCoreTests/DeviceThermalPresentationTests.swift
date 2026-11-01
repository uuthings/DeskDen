import XCTest
@testable import LauncherCore

final class DeviceThermalPresentationTests: XCTestCase {
    func testDefaultThresholdsRemainVisibleWithoutNotifications() {
        let rule = DeviceTemperatureRule()
        XCTAssertFalse(rule.enabled)
        XCTAssertFalse(rule.notificationsEnabled)
        let below = DeviceThermalPresentation(cpu: 84.99, gpu: 79.99, state: .nominal, rule: rule)
        XCTAssertEqual(below.level, .normal)
        let cpu = DeviceThermalPresentation(cpu: 85, gpu: 70, state: .nominal, rule: rule)
        XCTAssertEqual(cpu.level, .warning)
        XCTAssertEqual(cpu.cpuLevel, .warning)
        XCTAssertEqual(cpu.gpuLevel, .normal)
        XCTAssertEqual(cpu.title, "温度偏高")
        XCTAssertEqual(DeviceThermalPresentation(cpu: 60, gpu: 80, state: .nominal).gpuLevel, .warning)
    }

    func testSystemThermalPressureOverridesCustomTemperatureThresholds() {
        var rule = DeviceTemperatureRule()
        rule.cpuThreshold = 110; rule.gpuThreshold = 110
        for state in [DeviceThermalState.serious, .critical] {
            let status = DeviceThermalPresentation(cpu: 70, gpu: 60, state: state, rule: rule)
            XCTAssertEqual(status.level, .critical)
            XCTAssertEqual(status.cpuLevel, .critical)
            XCTAssertEqual(status.gpuLevel, .critical)
            XCTAssertEqual(status.symbol, "exclamationmark.triangle")
        }
        XCTAssertEqual(DeviceThermalPresentation(cpu: 60, gpu: 50, state: .fair).level, .warning)
    }

    func testUnknownOrInvalidSensorsNeverBecomeNormalZeroReadings() {
        for value: Double? in [nil, .nan, .infinity, -1, 0, 151] {
            let status = DeviceThermalPresentation(cpu: value, gpu: 60, state: .nominal)
            XCTAssertEqual(status.cpuLevel, .unknown)
            XCTAssertEqual(status.level, .normal)
            XCTAssertEqual(status.title, "系统正常")
            XCTAssertTrue(status.detail.contains("CPU"))
            XCTAssertTrue(status.detail.contains("不能据此判断"))
        }
        let critical = DeviceThermalPresentation(cpu: nil, gpu: nil, state: .critical)
        XCTAssertEqual(critical.level, .critical)
        XCTAssertEqual(critical.cpuLevel, .unknown)
        XCTAssertEqual(critical.gpuLevel, .unknown)
        let temperaturesOnly = DeviceThermalPresentation(cpu: 60, gpu: 50, state: .unknown)
        XCTAssertEqual(temperaturesOnly.level, .normal)
        XCTAssertEqual(temperaturesOnly.title, "温度正常")
        XCTAssertTrue(temperaturesOnly.detail.contains("macOS 热压力状态暂不可用"))
    }

    func testKnownSystemStateAndMissingTemperaturesHaveSeparateEvidence() {
        let systemOnly = DeviceThermalPresentation(cpu: nil, gpu: nil, state: .nominal,
                                                 unavailableReason: "AppleSMC 传感器连接不可用。")
        XCTAssertEqual(systemOnly.title, "系统正常")
        XCTAssertEqual(systemOnly.level, .normal)
        XCTAssertEqual(systemOnly.cpuLevel, .unknown)
        XCTAssertEqual(systemOnly.gpuLevel, .unknown)
        XCTAssertTrue(systemOnly.detail.contains("AppleSMC"))
        let partial = DeviceThermalPresentation(cpu: 60, gpu: nil, state: .unknown)
        XCTAssertEqual(partial.title, "温度正常")
        XCTAssertEqual(partial.gpuLevel, .unknown)
        XCTAssertTrue(partial.detail.contains("仅依据已读到"))
        XCTAssertTrue(partial.detail.contains("GPU"))
        XCTAssertEqual(DeviceThermalPresentation(cpu: 85, gpu: nil, state: .unknown).level, .warning)
    }

    func testInitializationEndsInUnknownWhenNeitherSourceReturnsEvidence() {
        let loading = DeviceThermalPresentation(cpu: nil, gpu: nil, state: .unknown, isLoading: true)
        XCTAssertEqual(loading.title, "读取中")
        XCTAssertEqual(loading.level, .unknown)
        let failed = DeviceThermalPresentation(cpu: nil, gpu: nil, state: .unknown, isLoading: false,
                                             unavailableReason: "传感器连接不可用。")
        XCTAssertEqual(failed.title, "状态未知")
        XCTAssertEqual(failed.level, .unknown)
        XCTAssertTrue(failed.detail.contains("传感器连接不可用"))
        XCTAssertEqual(DeviceThermalPresentation(cpu: nil, gpu: nil, state: .critical, isLoading: true).level, .critical)
    }

    func testCustomThresholdChangesPresentationWithoutChangingSystemState() {
        var rule = DeviceTemperatureRule()
        rule.cpuThreshold = 95; rule.gpuThreshold = 90
        XCTAssertEqual(DeviceThermalPresentation(cpu: 90, gpu: 85, state: .nominal, rule: rule).level, .normal)
        rule.cpuThreshold = 75
        XCTAssertEqual(DeviceThermalPresentation(cpu: 80, gpu: 60, state: .nominal, rule: rule).level, .warning)
    }
}
