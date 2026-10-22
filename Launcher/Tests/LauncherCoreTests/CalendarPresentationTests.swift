import Foundation
import XCTest
@testable import LauncherCore

final class CalendarPresentationTests:XCTestCase {
    private func instant(_ text:String)->Date {ISO8601DateFormatter().date(from:text)!}
    private func calendar(_ zone:String)->Calendar {var value=Calendar(identifier:.gregorian);value.timeZone=TimeZone(identifier:zone)!;value.firstWeekday=2;return value}

    func testTimedReminderFollowsAbsoluteInstantButDayOnlyRetainsCivilDate() throws {
        let due=ReminderDue(year:2026,month:10,day:21,hour:23,minute:30,timeZoneIdentifier:"America/New_York")
        let timed=ReminderItem(title:"定时",due:due)
        let dayOnly=ReminderItem(title:"全天",due:ReminderDue(year:2026,month:10,day:21,timeZoneIdentifier:"America/New_York"))
        let ny=calendar("America/New_York"),shanghai=calendar("Asia/Shanghai")
        let october21=instant("2026-10-21T12:00:00Z"),october22=instant("2026-10-22T12:00:00Z")
        XCTAssertTrue(ReminderQueries.occurs(reminder:timed,on:october21,calendar:ny))
        XCTAssertFalse(ReminderQueries.occurs(reminder:timed,on:october21,calendar:shanghai))
        XCTAssertTrue(ReminderQueries.occurs(reminder:timed,on:october22,calendar:shanghai))
        XCTAssertTrue(ReminderQueries.occurs(reminder:dayOnly,on:october21,calendar:shanghai))
        XCTAssertFalse(ReminderQueries.occurs(reminder:dayOnly,on:october22,calendar:shanghai))
        XCTAssertEqual(timed.due,due)
        XCTAssertEqual(ReminderQueries.entries(reminders:[timed,dayOnly],events:[],filter:.day,day:october21,calendar:shanghai).map(\.title),["全天"])
    }

    func testDateOnlyDisplayGroupingDoesNotUseSourceNoonInAnotherZone() throws {
        let item=ReminderItem(title:"当天",due:ReminderDue(year:2026,month:10,day:21,timeZoneIdentifier:"Pacific/Kiritimati"))
        let display=calendar("America/Los_Angeles")
        let date=try XCTUnwrap(ReminderQueries.displayDate(for:.reminder(item),calendar:display))
        XCTAssertEqual(display.dateComponents([.year,.month,.day],from:date),DateComponents(year:2026,month:10,day:21))
        XCTAssertNotEqual(display.component(.day,from:item.due!.date!),21)
    }

    func testMonthRowsAndWeekCrossingYearStayDeterministic() {
        let display=calendar("America/New_York")
        let february=ReminderQueries.monthDays(containing:instant("2026-02-12T12:00:00Z"),calendar:display)
        let august=ReminderQueries.monthDays(containing:instant("2026-08-12T12:00:00Z"),calendar:display)
        XCTAssertEqual(february.count,35);XCTAssertEqual(august.count,42)
        XCTAssertEqual(display.component(.weekday,from:february[0]),2)
        let week=ReminderQueries.weekDays(containing:instant("2026-01-01T12:00:00Z"),calendar:display)
        XCTAssertEqual(week.count,7)
        XCTAssertEqual(display.dateComponents([.year,.month,.day],from:week[0]),DateComponents(year:2025,month:12,day:29))
        XCTAssertEqual(display.dateComponents([.year,.month,.day],from:week[6]),DateComponents(year:2026,month:1,day:4))
    }

    func testLegacyReminderDefaultsToExistingNotificationBehavior() throws {
        let item=ReminderItem(title:"旧提醒",due:ReminderDue(year:2030,month:1,day:1,hour:10,minute:0,timeZoneIdentifier:"UTC"))
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(item)) as? [String:Any])
        object.removeValue(forKey:"notificationsEnabled")
        let loaded=try JSONDecoder().decode(ReminderItem.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertTrue(loaded.notificationsEnabled)
        XCTAssertEqual(ReminderNotificationPlan.pending([loaded],now:instant("2029-12-31T12:00:00Z")).count,1)
    }

    func testPerItemNotificationOptOutPreservesReminderAndSurvivesGlobalGating() throws {
        let due=ReminderDue(year:2030,month:1,day:1,hour:10,minute:0,timeZoneIdentifier:"UTC")
        let enabled=ReminderItem(title:"通知",due:due)
        let disabled=ReminderItem(title:"只保存",due:due,notificationsEnabled:false)
        var snapshot=ReminderSnapshot();snapshot.reminders=[enabled,disabled];snapshot.preferences.notificationsEnabled=false
        let stored=try JSONDecoder().decode(ReminderSnapshot.self,from:JSONEncoder().encode(snapshot))
        XCTAssertEqual(stored.reminders.count,2)
        XCTAssertFalse(stored.reminders[1].notificationsEnabled)
        snapshot.preferences.notificationsEnabled=true
        let restored=try JSONDecoder().decode(ReminderSnapshot.self,from:JSONEncoder().encode(snapshot))
        XCTAssertFalse(restored.reminders[1].notificationsEnabled)
        XCTAssertEqual(ReminderNotificationPlan.pending(restored.reminders,now:instant("2029-12-31T12:00:00Z")).map(\.title),["通知"])
    }

    func testDisplayTimeZoneQueriesDoNotChangeNotificationDateOrCompletionRules() throws {
        let due=ReminderDue(year:2026,month:11,day:1,hour:1,minute:30,timeZoneIdentifier:"America/New_York")
        var item=ReminderItem(title:"夏令时",due:due)
        let now=instant("2026-10-31T00:00:00Z")
        let before=ReminderNotificationPlan.pending([item],now:now)
        for zone in ["America/New_York","Asia/Shanghai","Pacific/Honolulu"] {
            _=ReminderQueries.entries(reminders:[item],events:[],filter:.day,day:due.date!,calendar:calendar(zone))
        }
        XCTAssertEqual(ReminderNotificationPlan.pending([item],now:now),before)
        item.isCompleted=true
        XCTAssertTrue(ReminderNotificationPlan.pending([item],now:now).isEmpty)
        item.isCompleted=false;item.due=nil
        XCTAssertTrue(ReminderNotificationPlan.pending([item],now:now).isEmpty)
        XCTAssertTrue(ReminderNotificationPlan.pending([ReminderItem(title:"已过期",due:due)],now:instant("2026-11-02T00:00:00Z")).isEmpty)
    }
}
