import XCTest
@testable import LauncherCore

final class ReminderTests:XCTestCase {
    private var utc:Calendar { var calendar=Calendar(identifier:.gregorian); calendar.timeZone=TimeZone(secondsFromGMT:0)!; return calendar }
    private func date(_ year:Int,_ month:Int,_ day:Int,_ hour:Int = 12,_ minute:Int = 0) -> Date { utc.date(from:DateComponents(year:year,month:month,day:day,hour:hour,minute:minute))! }
    private func due(_ day:Int,hour:Int? = nil,minute:Int? = nil) -> ReminderDue { ReminderDue(year:2026,month:10,day:day,hour:hour,minute:minute,timeZoneIdentifier:"GMT") }
    private func directory() throws -> URL { let url=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-reminder-test-\(UUID().uuidString)"); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url }

    func testCivilDateRejectsInvalidLeapDayAndIncompleteTime() throws {
        XCTAssertThrowsError(try ReminderDue(year:2025,month:2,day:29).validate())
        XCTAssertNoThrow(try ReminderDue(year:2024,month:2,day:29).validate())
        XCTAssertThrowsError(try ReminderDue(year:2026,month:10,day:18,hour:9).validate())
        XCTAssertThrowsError(try ReminderDue(year:2026,month:10,day:18,hour:24,minute:0).validate())
        XCTAssertThrowsError(try ReminderDue(year:2026,month:10,day:18,timeZoneIdentifier:"missing-zone").validate())
    }
    func testNonexistentDSTTimeIsRejectedInsteadOfMovingReminder() {
        XCTAssertThrowsError(try ReminderDue(year:2026,month:3,day:8,hour:2,minute:30,timeZoneIdentifier:"America/New_York").validate())
        XCTAssertNoThrow(try ReminderDue(year:2026,month:3,day:8,hour:3,minute:30,timeZoneIdentifier:"America/New_York").validate())
    }
    func testDayOnlyAndUndatedRoundTripRemainDistinct() throws {
        var snapshot=ReminderSnapshot()
        try snapshot.upsert(ReminderItem(title:"无日期"))
        try snapshot.upsert(ReminderItem(title:"全天",due:due(18)))
        try snapshot.upsert(ReminderItem(title:"具体时间",due:due(18,hour:9,minute:30)))
        let decoded=try JSONDecoder().decode(ReminderSnapshot.self,from:JSONEncoder().encode(snapshot))
        XCTAssertNil(decoded.reminders[0].due)
        XCTAssertFalse(decoded.reminders[1].due!.hasTime)
        XCTAssertEqual(decoded.reminders[2].due?.hour,9)
    }
    func testTitleAndNotesValidationDoesNotLoseOriginal() throws {
        let raw=ReminderItem(title:"   安排事项 \n",notes:"  备注  ")
        let cleaned=try raw.validated(); XCTAssertEqual(cleaned.title,"安排事项"); XCTAssertEqual(cleaned.notes,"备注")
        XCTAssertEqual(raw.notes,"  备注  ")
        XCTAssertThrowsError(try ReminderItem(title:" \n ").validated())
        XCTAssertThrowsError(try ReminderItem(title:String(repeating:"字",count:121)).validated())
        XCTAssertThrowsError(try ReminderItem(title:"有效",notes:String(repeating:"字",count:1001)).validated())
    }
    func testDayFilterIncludesSpanningEventsButNotExclusiveEndDay() {
        let reminder=ReminderItem(title:"当天",due:due(18))
        let other=ReminderItem(title:"其他",due:due(19))
        let done=ReminderItem(title:"完成",due:due(18),isCompleted:true)
        let event=CalendarEventItem(id:"trip",title:"跨日日程",start:date(2026,10,17,9),end:date(2026,10,19,0),calendarName:"测试日历")
        XCTAssertEqual(ReminderQueries.entries(reminders:[reminder,other,done],events:[event],filter:.day,day:date(2026,10,18),calendar:utc).count,2)
        XCTAssertFalse(event.occurs(on:date(2026,10,19),calendar:utc))
    }
    func testCompletedAndUndatedFiltersDoNotMixEventsOrCompletedTasks() {
        let items=[ReminderItem(title:"待定"),ReminderItem(title:"完成待定",isCompleted:true),ReminderItem(title:"安排",due:due(18))]
        let event=CalendarEventItem(id:"e",title:"事件",start:date(2026,10,18),end:date(2026,10,18,13),calendarName:"测试")
        XCTAssertEqual(ReminderQueries.entries(reminders:items,events:[event],filter:.undated,day:date(2026,10,18),calendar:utc).map(\.title),["待定"])
        XCTAssertEqual(ReminderQueries.entries(reminders:items,events:[event],filter:.completed,day:date(2026,10,18),calendar:utc).map(\.title),["完成待定"])
    }
    func testSearchIncludesNotesAndSourceAndFoldsCaseAndAccents() {
        let item=ReminderItem(origin:.system,calendarName:"工作",title:"Café",notes:"Review draft")
        for query in ["cafe","REVIEW","工作","ＣＡＦＥ"] {
            XCTAssertEqual(ReminderQueries.entries(reminders:[item],events:[],filter:.all,day:Date(),search:query).count,1,query)
        }
        XCTAssertTrue(ReminderQueries.entries(reminders:[item],events:[],filter:.all,day:Date(),search:"不存在").isEmpty)
    }
    func testMonthCalendarStartsMondayAndIncludesAdjacentDays() {
        let days=ReminderQueries.monthDays(containing:date(2026,10,18),calendar:utc)
        XCTAssertEqual(days.count,35)
        XCTAssertEqual(utc.component(.weekday,from:days.first!),2)
        XCTAssertEqual(utc.component(.month,from:days.first!),9)
        XCTAssertEqual(utc.component(.day,from:days.last!),1)
        XCTAssertEqual(utc.component(.month,from:days.last!),11)
        XCTAssertEqual(ReminderQueries.monthDays(containing:date(2026,3,15),calendar:utc).count,42)
    }
    func testUpcomingSortsDueBeforeUndatedAndOmitsCompleted() {
        let result=ReminderQueries.upcoming([ReminderItem(title:"未定"),ReminderItem(title:"明天",due:due(19)),ReminderItem(title:"今天",due:due(18)),ReminderItem(title:"完成",due:due(17),isCompleted:true)])
        XCTAssertEqual(result.map(\.title),["今天","明天","未定"])
        XCTAssertEqual(ReminderQueries.upcoming(result,limit:2).count,2)
    }
    func testNotificationPlanOnlySchedulesFutureTimedLocalIncompleteReminders() {
        let now=date(2026,10,18,10)
        let values=[ReminderItem(id:"future",title:"未来",due:due(18,hour:11,minute:0)),ReminderItem(title:"已过",due:due(18,hour:9,minute:0)),ReminderItem(title:"全天",due:due(18)),ReminderItem(title:"未定"),ReminderItem(origin:.system,title:"系统",due:due(18,hour:12,minute:0)),ReminderItem(title:"完成",due:due(18,hour:12,minute:0),isCompleted:true)]
        let plan=ReminderNotificationPlan.pending(values,now:now)
        XCTAssertEqual(plan.count,1); XCTAssertEqual(plan[0].id,ReminderNotificationPlan.prefix+"future")
        XCTAssertEqual(plan[0].due.hour,11)
    }
    func testNotificationPlanLimitsEarliestAndReflectsEditsAndCompletion() {
        var items=(0..<65).map { ReminderItem(id:"\($0)",title:"提醒\($0)",due:ReminderDue(date:date(2026,10,18).addingTimeInterval(Double($0+1)*60),includesTime:true,calendar:utc)) }
        XCTAssertEqual(ReminderNotificationPlan.pending(Array(items.reversed()),now:date(2026,10,18)).map(\.id).first,ReminderNotificationPlan.prefix+"0")
        XCTAssertEqual(ReminderNotificationPlan.pending(items,now:date(2026,10,18)).count,60)
        items[0].isCompleted=true; items[1].title="改后的标题"
        let updated=ReminderNotificationPlan.pending(items,now:date(2026,10,18))
        XCTAssertEqual(updated.first?.title,"改后的标题"); XCTAssertFalse(updated.contains{$0.id.hasSuffix(".0")})
    }
    func testStoreRoundTripAndBackupRecoveryPreserveDamagedBytes() throws {
        let directory=try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=ReminderStore(directory:directory); XCTAssertTrue(try store.load().reminders.isEmpty)
        var first=ReminderSnapshot(); try first.upsert(ReminderItem(id:"a",title:"原提醒",due:due(18)))
        try store.save(first)
        var second=first; second.reminders[0].title="修改后"; try store.save(second)
        XCTAssertEqual(try store.load(),second)
        let damaged=Data("broken reminder file".utf8); try damaged.write(to:store.url)
        XCTAssertThrowsError(try store.save(first))
        XCTAssertEqual(try Data(contentsOf:store.url),damaged)
        XCTAssertEqual(try store.recoverBackup(),first)
        let preserved=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.contains("preserved-")}
        XCTAssertEqual(preserved.count,1); XCTAssertEqual(try Data(contentsOf:preserved[0]),damaged)
    }
    func testDuplicateIDsSystemDataAndFutureSchemaAreRejected() throws {
        var snapshot=ReminderSnapshot(); let item=ReminderItem(id:"same",title:"提醒")
        snapshot.reminders=[item,item]; XCTAssertThrowsError(try snapshot.validate())
        snapshot.reminders=[ReminderItem(origin:.system,title:"系统")]; XCTAssertThrowsError(try snapshot.validate())
        snapshot.reminders=[]; snapshot.version=2; XCTAssertThrowsError(try snapshot.validate())
    }
    @MainActor func testLocalCRUDAndUndoNeverRequestSystemPermission() async throws {
        let directory=try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let fake=FakeReminderSystem(), store=ReminderStore(directory:directory)
        let service=try ReminderService(store:store,system:fake)
        let original=ReminderItem(id:"a",title:"本机",due:due(18))
        _=try service.save(original,creating:true)
        var changed=original; changed.isCompleted=true; changed.completedAt=Date()
        _=try service.save(changed,creating:false); XCTAssertTrue(service.snapshot.reminders[0].isCompleted)
        _=try service.save(original,creating:false); XCTAssertFalse(service.snapshot.reminders[0].isCompleted)
        try service.delete(original); XCTAssertTrue(try store.load().reminders.isEmpty)
        _=try service.save(original,creating:true); XCTAssertEqual(try store.load().reminders,[original])
        XCTAssertEqual(fake.requests,0); XCTAssertEqual(fake.saves,0); XCTAssertEqual(fake.deletes,0)
    }
    @MainActor func testDeniedSystemWriteDoesNotBecomeLocalDuplicate() async throws {
        let directory=try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let fake=FakeReminderSystem(); let service=try ReminderService(store:ReminderStore(directory:directory),system:fake)
        var prefs=ReminderPreferences(); prefs.remindersConnected=true; try service.setPreferences(prefs)
        XCTAssertThrowsError(try service.save(ReminderItem(origin:.system,title:"系统"),creating:true))
        XCTAssertTrue(service.snapshot.reminders.isEmpty); XCTAssertEqual(fake.saves,0); XCTAssertEqual(fake.requests,0)
    }
    @MainActor func testSystemCRUDUsesProviderAndPreservesLocalStoreBoundary() async throws {
        let directory=try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let fake=FakeReminderSystem(); fake.status = .granted
        let service=try ReminderService(store:ReminderStore(directory:directory),system:fake)
        var prefs=ReminderPreferences(); prefs.remindersConnected=true; try service.setPreferences(prefs)
        let item=try service.save(ReminderItem(origin:.system,title:"系统"),creating:true)
        XCTAssertEqual(item.id,"system-1"); XCTAssertTrue(service.snapshot.reminders.isEmpty)
        try service.delete(item); XCTAssertEqual(fake.deletes,1)
        let restored=try service.save(item,creating:true); XCTAssertEqual(restored.id,"system-2")
        XCTAssertEqual(fake.requests,0)
    }
    @MainActor func testFailedPersistenceDoesNotMutateServiceMemory() async throws {
        let directory=try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=ReminderStore(directory:directory), service=try ReminderService(store:store,system:FakeReminderSystem())
        let item=ReminderItem(title:"保留"); _=try service.save(item,creating:true)
        try Data("damaged".utf8).write(to:store.url)
        XCTAssertThrowsError(try service.delete(item)); XCTAssertEqual(service.snapshot.reminders,[item])
        var prefs=service.snapshot.preferences; prefs.notificationsEnabled=true
        XCTAssertThrowsError(try service.setPreferences(prefs)); XCTAssertFalse(service.snapshot.preferences.notificationsEnabled)
    }
}

@MainActor private final class FakeReminderSystem:CalendarSystemProviding {
    var status:CalendarAccess = .denied
    var requests=0, saves=0, deletes=0
    func access(reminders:Bool) -> CalendarAccess { status }
    func requestAccess(reminders:Bool) async throws -> Bool { requests += 1; return status == .granted }
    func events(in interval:DateInterval) throws -> [CalendarEventItem] { [] }
    func reminders() async throws -> [ReminderItem] { [] }
    func writableReminderCalendars() -> [ReminderCalendar] { [ReminderCalendar(id:"test",title:"测试列表")] }
    func saveReminder(_ item:ReminderItem,creating:Bool) throws -> ReminderItem { saves += 1; var saved=item; if creating { saved.id="system-\(saves)" }; return saved }
    func deleteReminder(_ item:ReminderItem) throws { deletes += 1 }
}
