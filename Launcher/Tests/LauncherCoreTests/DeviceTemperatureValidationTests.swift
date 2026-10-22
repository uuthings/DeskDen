import XCTest
@testable import LauncherCore

final class DeviceTemperatureValidationTests: XCTestCase {
    func testKnownM2CPUInvalidSamplesAreRejectedRatherThanClamped() {
        for chip in ["Apple M2", "Apple M2 Pro", "Apple M2 Max", "Apple M2 Ultra"] {
            for value in [0.000_001, 6, 9.999, 120.001, 129] {
                XCTAssertNil(DeviceTemperatureValidation.celsius(value, chipName: chip, isCPU: true))
            }
            for value in [10, 54.625, 120] {
                XCTAssertEqual(DeviceTemperatureValidation.celsius(value, chipName: chip, isCPU: true), value)
            }
        }
    }

    func testValidityRuleDoesNotInventOrReuseSamples() {
        XCTAssertEqual(DeviceTemperatureValidation.celsius(60, chipName: "Apple M2 Max", isCPU: true), 60)
        XCTAssertNil(DeviceTemperatureValidation.celsius(6, chipName: "Apple M2 Max", isCPU: true))
        XCTAssertNil(DeviceTemperatureValidation.celsius(nil, chipName: "Apple M2 Max", isCPU: true))
        XCTAssertEqual(DeviceTemperatureValidation.celsius(61, chipName: "Apple M2 Max", isCPU: true), 61)
    }

    func testKnownM2CPUWorkaroundDoesNotChangeGPUOrOtherChipFamilies() {
        XCTAssertEqual(DeviceTemperatureValidation.celsius(6, chipName: "Apple M2 Max", isCPU: false), 6)
        XCTAssertEqual(DeviceTemperatureValidation.celsius(125, chipName: "Apple M2 Max", isCPU: false), 125)
        for chip in ["Intel Core i7", "Apple M1", "Apple M3", "Apple M4"] {
            XCTAssertEqual(DeviceTemperatureValidation.celsius(6, chipName: chip, isCPU: true), 6)
            XCTAssertEqual(DeviceTemperatureValidation.celsius(125, chipName: chip, isCPU: true), 125)
        }
    }

    func testMissingAndMalformedTemperaturesRemainUnavailable() {
        for value in [Double.nan, .infinity, -.infinity, -5, 0, 130, 1_000] {
            XCTAssertNil(DeviceTemperatureValidation.celsius(value, chipName: "Apple M2 Max", isCPU: true))
            XCTAssertNil(DeviceTemperatureValidation.celsius(value, chipName: "Apple M2 Max", isCPU: false))
        }
    }
}
