import Foundation
import XCTest
@testable import LauncherCore

final class WorkbenchDateTextTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func date(_ text: String, zone: String = "Asia/Shanghai") -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    func testShortFormsOmitPaddingAndSpaces() {
        let value = date("2026-11-07 09:05")
        XCTAssertEqual(WorkbenchDateText.monthDay(value, calendar: calendar()), "11月7日")
        XCTAssertEqual(WorkbenchDateText.monthDayWeekday(value, calendar: calendar()), "11月7日 周六")
        XCTAssertEqual(WorkbenchDateText.yearMonth(value, calendar: calendar()), "2026年11月")
        XCTAssertEqual(WorkbenchDateText.axis(value, calendar: calendar()), "11/7")
    }

    func testFullFormsPadForAlignedLists() {
        let value = date("2026-11-07 09:05")
        XCTAssertEqual(WorkbenchDateText.full(value, calendar: calendar()), "2026年11月07日")
        XCTAssertEqual(WorkbenchDateText.fullWithTime(value, calendar: calendar()), "2026年11月07日 09:05")
    }

    func testRangesCarryYearsOnlyAcrossYears() {
        XCTAssertEqual(WorkbenchDateText.range(date("2026-11-01 00:00"), date("2026-11-30 12:00"), calendar: calendar()), "11月1日–11月30日")
        XCTAssertEqual(WorkbenchDateText.range(date("2026-12-28 00:00"), date("2027-01-03 12:00"), calendar: calendar()), "2026年12月28日–2027年1月3日")
    }

    func testFieldsFollowTheCalendarTimeZone() {
        // 16:30 in Los Angeles on 11-06 is already 11-07 in Shanghai.
        let value = date("2026-11-06 16:30", zone: "America/Los_Angeles")
        XCTAssertEqual(WorkbenchDateText.monthDay(value, calendar: calendar("America/Los_Angeles")), "11月6日")
        XCTAssertEqual(WorkbenchDateText.monthDayWeekday(value, calendar: calendar()), "11月7日 周六")
    }
}
