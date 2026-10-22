import XCTest
@testable import LauncherCore

final class WorkbenchDateCoreTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func testDisplayZoneChangesDayWithoutChangingAbsoluteInstant() throws {
        let instant = date("2026-10-21T03:30:00Z")
        let newYork = try WorkbenchDateContext(timeZoneIdentifier: "America/New_York").display(at: instant)
        let shanghai = try WorkbenchDateContext(timeZoneIdentifier: "Asia/Shanghai").display(at: instant)
        XCTAssertEqual(newYork.dayKey, "2026-10-20")
        XCTAssertEqual(shanghai.dayKey, "2026-10-21")
        XCTAssertEqual(newYork.instant, shanghai.instant)
        XCTAssertEqual(shanghai.timeText, "11:30")
    }
    func testSpringForwardUsesActualTwentyThreeHourDayAndDSTOffset() throws {
        let context = try WorkbenchDateContext(timeZoneIdentifier: "America/New_York")
        let value = try context.display(at: date("2026-03-08T07:30:00Z"))
        XCTAssertEqual(value.timeText, "03:30")
        XCTAssertEqual(value.secondsFromGMT, -4 * 3600)
        XCTAssertEqual(value.dayInterval.duration, 23 * 3600)
    }
    func testFallBackUsesTwentyFiveHourDayAndSeparatesRepeatedLocalTimeByInstant() throws {
        let context = try WorkbenchDateContext(timeZoneIdentifier: "America/New_York")
        let earlier = try context.display(at: date("2026-11-01T05:30:00Z"))
        let later = try context.display(at: date("2026-11-01T06:30:00Z"))
        XCTAssertEqual(earlier.timeText, "01:30"); XCTAssertEqual(later.timeText, "01:30")
        XCTAssertEqual(earlier.secondsFromGMT, -4 * 3600); XCTAssertEqual(later.secondsFromGMT, -5 * 3600)
        XCTAssertEqual(later.dayInterval.duration, 25 * 3600)
        XCTAssertNotEqual(earlier.instant, later.instant)
    }
    func testCalendarDayAdditionPreservesLocalTimeAcrossDSTRatherThanAdding86400() throws {
        let context = try WorkbenchDateContext(timeZoneIdentifier: "America/New_York")
        let before = date("2026-03-07T17:00:00Z")
        let after = try XCTUnwrap(context.addingDays(1, to: before))
        XCTAssertEqual(after.timeIntervalSince(before), 23 * 3600)
        XCTAssertEqual(try context.display(at: after).timeText, "12:00")
    }
    func testLunarDateUsesSystemChineseCalendarAndKnown2026Festivals() throws {
        let context = try WorkbenchDateContext(timeZoneIdentifier: "Asia/Shanghai")
        XCTAssertEqual(try context.display(at: date("2026-02-17T04:00:00Z")).lunarDate?.displayText, "正月初一")
        XCTAssertEqual(try context.display(at: date("2026-09-25T04:00:00Z")).lunarDate?.displayText, "八月十五")
    }
    func testOfficial2026DataHasExactlyThirtyThreeOffAndSixAdjustedWorkingDays() {
        XCTAssertEqual(WorkbenchChinaHolidays.entries.values.filter { $0.kind == .holiday }.count, 33)
        XCTAssertEqual(WorkbenchChinaHolidays.entries.values.filter { $0.kind == .workingDay }.count, 6)
        if case .recorded(let day) = WorkbenchChinaHolidays.lookup(dayKey: "2026-02-23") { XCTAssertEqual(day.name, "春节"); XCTAssertEqual(day.kind, .holiday) }
        else { XCTFail("Expected official holiday") }
        if case .recorded(let day) = WorkbenchChinaHolidays.lookup(dayKey: "2026-09-20") { XCTAssertEqual(day.kind, .workingDay) }
        else { XCTFail("Expected adjusted working day") }
        XCTAssertEqual(WorkbenchChinaHolidays.lookup(dayKey: "2026-10-21"), .noSpecialArrangement)
        XCTAssertTrue(WorkbenchChinaHolidays.sourceURL.host?.hasSuffix("gov.cn") == true)
    }
    func testUnsupportedYearsAndInvalidDatesAreNotInferredFromWeekdays() {
        XCTAssertEqual(WorkbenchChinaHolidays.lookup(dayKey: "2027-01-01"), .yearNotIncluded)
        XCTAssertEqual(WorkbenchChinaHolidays.lookup(dayKey: "2025-10-01"), .yearNotIncluded)
        XCTAssertEqual(WorkbenchChinaHolidays.lookup(dayKey: "2026-02-30"), .invalidDate)
        XCTAssertEqual(WorkbenchChinaHolidays.lookup(dayKey: "2026-02-14"), .recorded(.init(dayKey: "2026-02-14", name: "春节调休上班", kind: .workingDay)))
    }
    func testInvalidTimeZoneRejectedOnInitialisationAndPersistenceDecode() throws {
        XCTAssertThrowsError(try WorkbenchDateContext(timeZoneIdentifier: "Not/AZone"))
        XCTAssertThrowsError(try JSONDecoder().decode(WorkbenchDateContext.self, from: Data(#"{"timeZoneIdentifier":"Not/AZone"}"#.utf8)))
        let context = try WorkbenchDateContext(timeZoneIdentifier: "Asia/Shanghai")
        XCTAssertEqual(try JSONDecoder().decode(WorkbenchDateContext.self, from: JSONEncoder().encode(context)), context)
    }
}
