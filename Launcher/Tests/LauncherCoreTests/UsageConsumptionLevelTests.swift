import XCTest
@testable import LauncherCore

final class UsageConsumptionLevelTests: XCTestCase {
    func testBoundariesUseUnroundedConsumedPercentage() {
        XCTAssertEqual(UsageConsumptionLevel.classify(percent: 0), .normal)
        XCTAssertEqual(UsageConsumptionLevel.classify(percent: 69.999), .normal)
        XCTAssertEqual(UsageConsumptionLevel.classify(percent: 70), .warning)
        XCTAssertEqual(UsageConsumptionLevel.classify(percent: 89.999), .warning)
        XCTAssertEqual(UsageConsumptionLevel.classify(percent: 90), .critical)
        XCTAssertEqual(UsageConsumptionLevel.classify(percent: 100), .critical)
    }

    func testOverageRetainsCriticalStateWithoutClampingTheReading() {
        XCTAssertEqual(UsageConsumptionLevel.classify(percent: 116.25), .critical)
        XCTAssertEqual(UsageConsumptionLevel.classify(percent: Double.greatestFiniteMagnitude), .critical)
    }

    func testUnavailableAndInvalidReadingsNeverBecomeNormalZero() {
        let values: [Double?] = [nil, -Double.leastNonzeroMagnitude, Double.nan, Double.infinity, -Double.infinity]
        for value in values {
            XCTAssertEqual(UsageConsumptionLevel.classify(percent: value), .unknown)
        }
    }

    func testQuotaWindowUsesTheSameVisualThresholds() throws {
        for (percent, expected) in [(69.9, 0), (70.0, 1), (89.9, 1), (90.0, 2)] {
            let window = try AIQuotaWindow(usedPercent: percent, durationMinutes: 300, resetsAt: nil)
            XCTAssertEqual(window.severity, expected)
        }
    }
}
