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

    func testPercentageLabelsNeverRoundIntoTheNextSeverity() {
        for (value, label, severity) in [(0.0, "0%", UsageConsumptionLevel.normal),
                                        (0.4, "<1%", .normal), (69.999, "69%", .normal),
                                        (70.0, "70%", .warning), (899.95 / 1000 * 100, "89%", .warning),
                                        (90.0, "90%", .critical), (116.25, "116%", .critical)] {
            XCTAssertEqual(UsagePercentage.text(value), label)
            XCTAssertEqual(UsageConsumptionLevel.classify(percent: value), severity)
        }
        let invalid: [Double?] = [nil, .nan, .infinity, -.infinity, -1]
        for value in invalid {
            XCTAssertEqual(UsagePercentage.text(value), "—")
        }
        XCTAssertEqual(UsagePercentage.valueText(89.995), "89")
    }

    func testObservationAgeAcrossSecondsMinutesHoursAndDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (seconds, expected) in [(0, "刚刚"), (1, "1秒前"), (59, "59秒前"),
                                    (60, "1分钟前"), (3599, "59分钟前"), (3600, "1小时前"),
                                    (3660, "1小时1分钟前"), (86399, "23小时59分钟前"),
                                    (86400, "1天前"), (183600, "2天3小时前")] {
            XCTAssertEqual(UsageObservationAge.text(since: now.addingTimeInterval(-Double(seconds)), now: now), expected)
        }
        XCTAssertEqual(UsageObservationAge.text(since: now.addingTimeInterval(20), now: now), "刚刚")
        XCTAssertEqual(UsageObservationAge.text(since: Date(timeIntervalSince1970: .nan), now: now), "时间不可用")
    }

    func testProviderByteRatiosPreserveExactIntegerPercentages() {
        func snapshot(_ used: UInt64, _ total: UInt64) -> ProviderUsageSnapshot {
            .init(sourceID: UUID(), observedAt: Date(), usedBytes: used, limitBytes: total,
                  displayUnit: .decimalGB, sourceDescription: "Synthetic percentage fixture")
        }
        let integerPercentages: [UInt64] = [29, 58, 70, 90]
        for percent in integerPercentages {
            let value = snapshot(percent, 100)
            XCTAssertEqual(value.usedPercent, Double(percent))
            XCTAssertEqual(UsagePercentage.text(value.usedPercent), "\(percent)%")
        }
        let nearBoundary = snapshot(899_950_000_000, 1_000_000_000_000)
        XCTAssertEqual(nearBoundary.usedPercent, 89.995, accuracy: 0.000_000_000_1)
        XCTAssertEqual(UsagePercentage.text(nearBoundary.usedPercent), "89%")
        XCTAssertEqual(UsageConsumptionLevel.classify(percent: nearBoundary.usedPercent), .warning)
        let justBelowNinety = snapshot(8_099_999_999_999_999, 9_000_000_000_000_000)
        XCTAssertLessThan(justBelowNinety.usedPercent, 90)
        XCTAssertEqual(UsagePercentage.text(justBelowNinety.usedPercent), "89%")
        XCTAssertTrue(snapshot(UInt64.max, 1).usedPercent.isFinite)
        XCTAssertEqual(snapshot(UInt64.max, 0).usedPercent, 0)
    }

    func testQuotaWindowUsesTheSameVisualThresholds() throws {
        for (percent, expected) in [(69.9, 0), (70.0, 1), (89.9, 1), (90.0, 2)] {
            let window = try AIQuotaWindow(usedPercent: percent, durationMinutes: 300, resetsAt: nil)
            XCTAssertEqual(window.severity, expected)
        }
    }
}
