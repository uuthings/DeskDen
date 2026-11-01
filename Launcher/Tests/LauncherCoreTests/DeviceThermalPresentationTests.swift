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
            XCTAssertEqual(status.level, .unknown)
        }
        let critical = DeviceThermalPresentation(cpu: nil, gpu: nil, state: .critical)
        XCTAssertEqual(critical.level, .critical)
        XCTAssertEqual(critical.cpuLevel, .unknown)
        XCTAssertEqual(critical.gpuLevel, .unknown)
        XCTAssertEqual(DeviceThermalPresentation(cpu: 60, gpu: 50, state: .unknown).level, .unknown)
    }

    func testCustomThresholdChangesPresentationWithoutChangingSystemState() {
        var rule = DeviceTemperatureRule()
        rule.cpuThreshold = 95; rule.gpuThreshold = 90
        XCTAssertEqual(DeviceThermalPresentation(cpu: 90, gpu: 85, state: .nominal, rule: rule).level, .normal)
        rule.cpuThreshold = 75
        XCTAssertEqual(DeviceThermalPresentation(cpu: 80, gpu: 60, state: .nominal, rule: rule).level, .warning)
    }
}
