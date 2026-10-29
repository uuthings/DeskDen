import XCTest
@testable import LauncherCore

final class ReminderDeadlineTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, in calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar()).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func resolve(_ count: String, from anchor: Date, _ rule: ReminderCountingRule = .init(), in calendar: Calendar? = nil) throws -> Date {
        try ReminderDeadlineCalculator.resolve(daysText: count, anchor: anchor, rule: rule, calendar: calendar ?? self.calendar())
    }
    private func assertDay(_ actual: Date, _ year: Int, _ month: Int, _ day: Int, in calendar: Calendar? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let parts = (calendar ?? self.calendar()).dateComponents([.year, .month, .day, .hour], from: actual)
        XCTAssertEqual(parts.year, year, file: file, line: line)
        XCTAssertEqual(parts.month, month, file: file, line: line)
        XCTAssertEqual(parts.day, day, file: file, line: line)
        XCTAssertEqual(parts.hour, 12, file: file, line: line)
    }

    func testNaturalDaysStartTomorrowAndDoNotTreatLateOpeningAsAnExtraDay() throws {
        assertDay(try resolve("1", from: date(2026, 10, 29, hour: 23)), 2026, 10, 30)
        assertDay(try resolve("10", from: date(2026, 10, 29, hour: 0)), 2026, 11, 8)
        assertDay(try resolve("10", from: date(2026, 10, 29, hour: 23)), 2026, 11, 8)
    }
    func testMonthLeapYearAndYearTransitions() throws {
        assertDay(try resolve("1", from: date(2026, 1, 31)), 2026, 2, 1)
        assertDay(try resolve("1", from: date(2024, 2, 28)), 2024, 2, 29)
        assertDay(try resolve("2", from: date(2024, 2, 28)), 2024, 3, 1)
        assertDay(try resolve("1", from: date(2026, 2, 28)), 2026, 3, 1)
        assertDay(try resolve("2", from: date(2026, 12, 30)), 2027, 1, 1)
    }
    func testWeekdaysSkipAnOrdinaryWeekend() throws {
        let rule = ReminderCountingRule(daysBasis: .weekdays)
        assertDay(try resolve("1", from: date(2026, 10, 23), rule), 2026, 10, 26)
        assertDay(try resolve("5", from: date(2026, 10, 23), rule), 2026, 10, 30)
    }
    func testNationalDayRulesHaveDistinctKnownDeadlines() throws {
        let start = date(2026, 9, 30)
        assertDay(try resolve("10", from: start), 2026, 10, 10)
        assertDay(try resolve("10", from: start, .init(daysBasis: .weekdays)), 2026, 10, 14)
        assertDay(try resolve("10", from: start, .init(daysBasis: .weekdays, skipHolidays: true, includeMakeupWorkdays: true)), 2026, 10, 20)
        assertDay(try resolve("10", from: start, .init(daysBasis: .weekdays, skipHolidays: true)), 2026, 10, 21)
        assertDay(try resolve("10", from: start, .init(skipHolidays: true)), 2026, 10, 17)
    }
    func testMakeupWorkdayIsIncludedOnlyWhenRequestedForWeekdays() throws {
        let start = date(2026, 10, 9)
        assertDay(try resolve("1", from: start, .init(daysBasis: .weekdays)), 2026, 10, 12)
        assertDay(try resolve("1", from: start, .init(daysBasis: .weekdays, includeMakeupWorkdays: true)), 2026, 10, 10)
        assertDay(try resolve("1", from: start), 2026, 10, 10)
    }
    func testHolidaySkippingWorksIndependentlyFromWeekendRule() throws {
        let start = date(2026, 10, 1)
        assertDay(try resolve("1", from: start, .init(daysBasis: .weekdays)), 2026, 10, 2)
        assertDay(try resolve("1", from: start, .init(skipHolidays: true)), 2026, 10, 8)
    }
    func testMissingHolidayYearBlocksInsteadOfPretendingItIsAWeekday() throws {
        let start = date(2026, 12, 30)
        for rule in [ReminderCountingRule(skipHolidays: true), .init(daysBasis: .weekdays, includeMakeupWorkdays: true), .init(daysBasis: .weekdays, skipHolidays: true, includeMakeupWorkdays: true)] {
            XCTAssertThrowsError(try resolve("2", from: start, rule)) { error in
                XCTAssertTrue(error.localizedDescription.contains("2027"))
                XCTAssertTrue(error.localizedDescription.contains("节假日数据"))
            }
        }
        assertDay(try resolve("2", from: start), 2027, 1, 1)
        assertDay(try resolve("2", from: start, .init(daysBasis: .weekdays)), 2027, 1, 1)
    }
    func testMissingYearOnlyMattersForCountedRangeNotExcludedAnchor() throws {
        assertDay(try resolve("1", from: date(2025, 12, 31), .init(skipHolidays: true)), 2026, 1, 4)
    }
    func testSpringAndFallUseCivilDaysRatherThanTwentyFourHourDurations() throws {
        let ny = calendar("America/New_York")
        let spring = date(2026, 3, 7, in: ny)
        let springDue = try resolve("2", from: spring, in: ny)
        assertDay(springDue, 2026, 3, 9, in: ny)
        XCTAssertEqual(springDue.timeIntervalSince(spring), 47 * 3600)
        let fall = date(2026, 10, 31, in: ny)
        let fallDue = try resolve("2", from: fall, in: ny)
        assertDay(fallDue, 2026, 11, 2, in: ny)
        XCTAssertEqual(fallDue.timeIntervalSince(fall), 49 * 3600)
    }
    func testAnchorUsesDraftTimeZoneAndProducesDateOnlyValue() throws {
        let instant = ISO8601DateFormatter().date(from: "2026-10-30T03:00:00Z")!
        let ny = calendar("America/New_York"), shanghai = calendar()
        let west = try resolve("10", from: instant, in: ny)
        let east = try resolve("10", from: instant, in: shanghai)
        assertDay(west, 2026, 11, 8, in: ny)
        assertDay(east, 2026, 11, 9, in: shanghai)
        let due = ReminderDue(date: west, includesTime: false, calendar: ny)
        XCTAssertFalse(due.hasTime)
        XCTAssertNil(due.hour)
        XCTAssertEqual(due.timeZoneIdentifier, "America/New_York")
    }
    func testInputRejectsZeroNegativeFractionsOverflowAndMixedText() {
        for input in ["", " ", "0", "-1", "+1", "1.5", "1e2", "10天", "1 0", "１", "3651", String(repeating: "9", count: 100)] {
            XCTAssertThrowsError(try ReminderDeadlineCalculator.dayCount(from: input), input)
        }
        XCTAssertEqual(try ReminderDeadlineCalculator.dayCount(from: " 010\n"), 10)
        XCTAssertEqual(try ReminderDeadlineCalculator.dayCount(from: "3650"), 3650)
    }
    func testLargeNaturalIntervalDoesNotRequireHolidayCoverage() throws {
        let start = date(2026, 1, 1)
        assertDay(try resolve("3650", from: start), 2035, 12, 30)
    }
    func testInvalidAndOutOfRangeAnchorsFailSafely() {
        for anchor in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .greatestFiniteMagnitude)] {
            XCTAssertThrowsError(try resolve("1", from: anchor))
        }
        XCTAssertThrowsError(try resolve("1", from: date(9999, 12, 31)))
    }
    func testRuleSwitchDoesNotChangeStoredAnchorOrDependOnWallClock() throws {
        let originalAnchor = date(2026, 9, 30, hour: 23)
        let natural = try resolve("10", from: originalAnchor)
        let business = try resolve("10", from: originalAnchor, .init(daysBasis: .weekdays, skipHolidays: true, includeMakeupWorkdays: true))
        XCTAssertNotEqual(natural, business)
        XCTAssertEqual(try resolve("10", from: originalAnchor), natural)
    }
}
