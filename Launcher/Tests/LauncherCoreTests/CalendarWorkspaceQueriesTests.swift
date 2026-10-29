import XCTest
@testable import LauncherCore

final class CalendarWorkspaceQueriesTests: XCTestCase {
    private var utc: Calendar { calendar("GMT") }
    private func calendar(_ zone: String) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }
    private func date(_ day: Int, hour: Int = 0, minute: Int = 0, month: Int = 10, in calendar: Calendar? = nil) -> Date {
        (calendar ?? utc).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private var interval: DateInterval { .init(start: date(20), end: date(27)) }
    private func reminder(_ id: String, day: Int? = nil, completed: Bool = false, origin: ReminderOrigin = .local, calendarID: String? = nil) -> ReminderItem {
        .init(id: id, origin: origin, calendarID: calendarID, calendarName: calendarID == nil ? nil : "工作", title: id,
              due: day.map { ReminderDue(year: 2026, month: 10, day: $0, timeZoneIdentifier: "GMT") }, isCompleted: completed)
    }
    private func event(_ id: String, start: Date, end: Date, calendarID: String? = "work") -> CalendarEventItem {
        .init(id: id, title: id, start: start, end: end, calendarName: "工作", calendarID: calendarID)
    }
    private func ids(_ entries: [CalendarAgendaEntry]) -> Set<String> { Set(entries.map(\.id)) }

    func testSelectedDayIncludesCompletedTasksAndEventsWithoutUndatedItems() {
        let items = [reminder("pending", day: 20), reminder("done", day: 20, completed: true), reminder("undated"), reminder("tomorrow", day: 21)]
        let events = [event("meeting", start: date(20, hour: 9), end: date(20, hour: 10))]
        let entries = CalendarWorkspaceQueries.selectedDay(reminders: items, events: events, day: date(20), calendar: utc)
        XCTAssertEqual(ids(entries), ["local:pending", "local:done", "event:meeting"])
        XCTAssertEqual(entries.filter(\.isCompleted).map(\.id), ["local:done"])
    }
    func testSelectedDayIncludesSpanningEventButExcludesItsMidnightEndDay() {
        let trip = event("trip", start: date(19, hour: 16), end: date(21))
        XCTAssertEqual(CalendarWorkspaceQueries.selectedDay(reminders: [], events: [trip], day: date(20), calendar: utc).map(\.id), ["event:trip"])
        XCTAssertTrue(CalendarWorkspaceQueries.selectedDay(reminders: [], events: [trip], day: date(21), calendar: utc).isEmpty)
    }
    func testSevenDayWindowIncludesTodayThroughSeventhDayAndExcludesEighth() {
        let items = [reminder("overdue", day: 19), reminder("today", day: 20), reminder("seventh", day: 26), reminder("eighth", day: 27),
                     reminder("completed", day: 20, completed: true), reminder("long-term")]
        let entries = CalendarWorkspaceQueries.upcoming(reminders: items, events: [], interval: interval, calendar: utc)
        XCTAssertEqual(entries.map(\.id), ["local:today", "local:seventh"])
    }
    func testTimedReminderBoundsAreHalfOpenAndIncludeTheFinalMinute() {
        let items = [("start", 20, 0, 0), ("last", 26, 23, 59), ("end", 27, 0, 0)].map { id, day, hour, minute in
            ReminderItem(id: id, title: id, due: .init(year: 2026, month: 10, day: day, hour: hour, minute: minute, timeZoneIdentifier: "GMT"))
        }
        XCTAssertEqual(CalendarWorkspaceQueries.upcoming(reminders: items, events: [], interval: interval, calendar: utc).map(\.id), ["local:start", "local:last"])
    }
    func testOverlappingEventsAreIncludedOnceAndExclusiveEndpointsAreRespected() {
        let events = [
            event("before", start: date(19), end: date(20)),
            event("cross-start", start: date(19), end: date(20, hour: 1)),
            event("span-all", start: date(18), end: date(30)),
            event("cross-end", start: date(26, hour: 23), end: date(28)),
            event("after", start: date(27), end: date(28))
        ]
        let entries = CalendarWorkspaceQueries.upcoming(reminders: [], events: events, interval: interval, calendar: utc)
        XCTAssertEqual(ids(entries), ["event:cross-start", "event:span-all", "event:cross-end"])
        XCTAssertEqual(entries.count, 3)
    }
    func testZeroDurationEventAtStartAppearsButAtEndDoesNot() {
        let events = [event("point-start", start: interval.start, end: interval.start), event("point-end", start: interval.end, end: interval.end)]
        XCTAssertEqual(CalendarWorkspaceQueries.upcoming(reminders: [], events: events, interval: interval, calendar: utc).map(\.id), ["event:point-start"])
        XCTAssertEqual(CalendarWorkspaceQueries.selectedDay(reminders: [], events: events, day: interval.start, calendar: utc).map(\.id), ["event:point-start"])
    }
    func testCalendarAndReminderSourcesWithSameIdentifierRemainDistinct() {
        let items = [reminder("system", day: 20, origin: .system, calendarID: "work"), reminder("local", day: 20)]
        let events = [event("meeting", start: date(20, hour: 9), end: date(20, hour: 10), calendarID: "work")]
        XCTAssertEqual(CalendarWorkspaceQueries.upcoming(reminders: items, events: events, interval: interval, source: "event:work", calendar: utc).map(\.id), ["event:meeting"])
        XCTAssertEqual(CalendarWorkspaceQueries.upcoming(reminders: items, events: events, interval: interval, source: "reminder:work", calendar: utc).map(\.id), ["system:system"])
        XCTAssertEqual(CalendarWorkspaceQueries.upcoming(reminders: items, events: events, interval: interval, source: "local", calendar: utc).map(\.id), ["local:local"])
    }
    func testUnknownSourceReturnsNoRowsAndAllReturnsEveryMatchingOrigin() {
        let items = [reminder("system", day: 20, origin: .system, calendarID: "work"), reminder("local", day: 20)]
        let events = [event("meeting", start: date(20), end: date(21))]
        XCTAssertTrue(CalendarWorkspaceQueries.upcoming(reminders: items, events: events, interval: interval, source: "missing", calendar: utc).isEmpty)
        XCTAssertEqual(CalendarWorkspaceQueries.upcoming(reminders: items, events: events, interval: interval, source: "all", calendar: utc).count, 3)
    }
    func testFilteringUpcomingDoesNotChangeSelectedDayOrInputRecords() {
        let items = [reminder("local", day: 20), reminder("system", day: 20, completed: true, origin: .system, calendarID: "work")]
        let events = [event("meeting", start: date(20), end: date(21))]
        let originalItems = items, originalEvents = events
        let before = CalendarWorkspaceQueries.selectedDay(reminders: items, events: events, day: date(20), calendar: utc)
        XCTAssertEqual(CalendarWorkspaceQueries.upcoming(reminders: items, events: events, interval: interval, source: "local", calendar: utc).count, 1)
        let after = CalendarWorkspaceQueries.selectedDay(reminders: items, events: events, day: date(20), calendar: utc)
        XCTAssertEqual(before, after)
        XCTAssertEqual(items, originalItems)
        XCTAssertEqual(events, originalEvents)
        XCTAssertEqual(after.count, 3)
    }
    func testDateOnlyRemindersKeepCivilDayWhileTimedRemindersProjectIntoDisplayZone() {
        let ny = calendar("America/New_York")
        let items = [
            ReminderItem(id: "civil", title: "civil", due: .init(year: 2026, month: 10, day: 20, timeZoneIdentifier: "Asia/Tokyo")),
            ReminderItem(id: "timed", title: "timed", due: .init(year: 2026, month: 10, day: 20, hour: 8, minute: 0, timeZoneIdentifier: "Asia/Tokyo"))
        ]
        XCTAssertEqual(CalendarWorkspaceQueries.selectedDay(reminders: items, events: [], day: date(20, in: ny), calendar: ny).map(\.id), ["local:civil"])
        XCTAssertEqual(CalendarWorkspaceQueries.selectedDay(reminders: items, events: [], day: date(19, in: ny), calendar: ny).map(\.id), ["local:timed"])
        let range = DateInterval(start: date(20, in: ny), end: date(27, in: ny))
        XCTAssertEqual(CalendarWorkspaceQueries.upcoming(reminders: items, events: [], interval: range, calendar: ny).map(\.id), ["local:civil"])
    }
    func testSevenCivilDaysSpanDSTWithoutLosingTheLastDay() {
        let ny = calendar("America/New_York"), start = date(30, in: calendar("America/New_York"))
        let end = ny.date(byAdding: .day, value: 7, to: start)!
        XCTAssertEqual(end.timeIntervalSince(start), 169 * 3600)
        let items = [
            ReminderItem(id: "seventh", title: "seventh", due: .init(year: 2026, month: 11, day: 5, timeZoneIdentifier: "GMT")),
            ReminderItem(id: "eighth", title: "eighth", due: .init(year: 2026, month: 11, day: 6, timeZoneIdentifier: "GMT"))
        ]
        XCTAssertEqual(CalendarWorkspaceQueries.upcoming(reminders: items, events: [], interval: .init(start: start, end: end), calendar: ny).map(\.id), ["local:seventh"])
    }
    func testEqualTimeOrderingIsStableAcrossProviderOrder() {
        let items = [reminder("b", day: 20), reminder("a", day: 20)]
        let events = [event("b", start: date(20, hour: 12), end: date(20, hour: 13)), event("a", start: date(20, hour: 12), end: date(20, hour: 13))]
        let forward = CalendarWorkspaceQueries.upcoming(reminders: items, events: events, interval: interval, calendar: utc)
        let reversed = CalendarWorkspaceQueries.upcoming(reminders: Array(items.reversed()), events: Array(events.reversed()), interval: interval, calendar: utc)
        XCTAssertEqual(forward.map(\.id), ["event:a", "event:b", "local:a", "local:b"])
        XCTAssertEqual(forward, reversed)
    }
    func testSourceTitlesIdentifyItemKindAndFallbackNamesWithoutIDs() {
        let eventEntry = CalendarAgendaEntry.event(event("meeting", start: date(20), end: date(21), calendarID: nil))
        let reminderEntry = CalendarAgendaEntry.reminder(ReminderItem(origin: .system, calendarName: "工作", title: "task"))
        XCTAssertEqual(CalendarWorkspaceQueries.sourceKey(eventEntry), "event:工作")
        XCTAssertEqual(CalendarWorkspaceQueries.sourceKey(reminderEntry), "reminder:工作")
        XCTAssertEqual(CalendarWorkspaceQueries.sourceTitle(eventEntry), "日程 · 工作")
        XCTAssertEqual(CalendarWorkspaceQueries.sourceTitle(reminderEntry), "待办 · 工作")
        XCTAssertEqual(CalendarWorkspaceQueries.sourceTitle(.reminder(reminder("local"))), "方寸本机")
    }
}
