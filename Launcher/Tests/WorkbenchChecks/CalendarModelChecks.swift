import AppKit
import Foundation
import LauncherCore

@main struct CalendarModelChecks {
    @MainActor static func main() async {
        _=NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-calendar-model-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:directory) }
        var failures=0,checks=0
        func check(_ condition:Bool,_ message:String) { checks += 1; if !condition { failures += 1 }; print("\(condition ? "PASS":"FAIL") \(message)") }
        let system=CalendarCheckSystem(),notifications=CalendarCheckNotifications()
        let model=CalendarModel(dataDirectory:directory,system:system,notifier:notifications)
        await model.refresh()
        check(model.localReminders.isEmpty && model.events.isEmpty && model.systemReminders.isEmpty,"fresh calendar has no synthetic content")
        check(system.permissionRequests == 0 && notifications.permissionRequests == 0,"opening calendar never requests permissions")
        model.openNewReminder()
        var draft=model.editor!; draft.item.title="Synthetic local reminder"; draft.hasDate=true; draft.hasTime=true
        draft.date=Date().addingTimeInterval(86_400); draft.time=draft.date
        check(await model.saveDraft(draft),"local timed reminder saves")
        let item=model.localReminders[0]
        check((try? ReminderStore(directory:directory).load().reminders.count) == 1,"local reminder persists to temporary directory")
        await model.refresh(); await Task.yield()
        check(notifications.pending.isEmpty,"notifications stay off before explicit authorization")
        await model.enableNotifications(); await model.refresh(); await Task.yield()
        check(notifications.permissionRequests == 1 && notifications.pending.count == 1,"explicit enable schedules timed local reminder")
        await model.toggle(item); await Task.yield()
        check(model.localReminders[0].isCompleted && notifications.pending.isEmpty,"completion cancels pending local notification")
        await model.undoLastChange(); await Task.yield()
        check(!model.localReminders[0].isCompleted && notifications.pending.count == 1,"completion undo restores reminder and notification")
        check(await model.delete(item),"confirmed local deletion succeeds")
        check(model.localReminders.isEmpty,"deleted reminder leaves local list")
        await model.undoLastChange()
        check(model.localReminders.first?.id == item.id,"delete undo restores original local identity")
        await model.connect(reminders:true)
        check(!model.preferences.remindersConnected && model.localReminders.count == 1,"denied system access leaves local reminders usable")
        system.granted=true; await model.connect(reminders:true)
        check(model.preferences.remindersConnected && system.permissionRequests == 2,"explicit reconnect can enable system source")
        let todayStart=Calendar.current.startOfDay(for:Date())
        let futureMonth=Calendar.current.date(byAdding:.month,value:2,to:todayStart)!
        system.calendarEvents=[
            CalendarEventItem(id:"today-event",title:"Synthetic today event",start:todayStart.addingTimeInterval(3_600),end:todayStart.addingTimeInterval(7_200),calendarName:"Fixture"),
            CalendarEventItem(id:"future-event",title:"Synthetic future event",start:futureMonth.addingTimeInterval(3_600),end:futureMonth.addingTimeInterval(7_200),calendarName:"Fixture")
        ]
        await model.connect(reminders:false)
        let originalToday=model.todayItems.map(\.id)
        check(originalToday.contains("event:today-event"),"connected calendar supplies today's system event")
        model.displayedMonth=futureMonth; await model.refresh()
        check(model.events.map(\.id) == ["future-event"],"calendar browsing loads only the displayed month")
        check(model.todayItems.map(\.id) == originalToday,"cross-month browsing preserves overview and widget today items")
        check(model.todayEvents.map(\.id) == ["today-event"],"today system cache remains independent from browsing cache")
        await model.disconnect(reminders:false)
        check(model.events.isEmpty && model.todayEvents.isEmpty && !model.todayItems.contains{$0.id.hasPrefix("event:")},"disconnect clears calendar data from both month and today consumers")
        model.openNewReminder(); var external=model.editor!; external.item.title="Synthetic system reminder"; external.item.origin = .system; external.item.calendarID="fixture"
        check(await model.saveDraft(external),"system source save uses fake system adapter")
        check(model.systemReminders.count == 1 && model.localReminders.count == 1 && system.items.count == 1,"system saves do not become local duplicates")
        await model.disconnect(reminders:true)
        check(model.systemReminders.isEmpty && system.items.count == 1,"disconnect hides system source without deleting its items")
        model.disableNotifications(); await Task.yield()
        check(notifications.pending.isEmpty && !model.preferences.notificationsEnabled,"explicit notification disable cancels owned pending requests")
        check(system.calendarWrites == 0,"calendar integration never writes calendar events")
        print("Calendar model checks: \(checks-failures)/\(checks) passed")
        exit(failures == 0 ? 0:1)
    }
}
@MainActor final class CalendarCheckSystem:CalendarSystemProviding {
    var permissionRequests=0,calendarWrites=0
    var granted=false
    var items:[ReminderItem] = []
    var calendarEvents:[CalendarEventItem] = []
    func access(reminders:Bool) -> CalendarAccess { granted ? .granted:.denied }
    func requestAccess(reminders:Bool) async throws -> Bool { permissionRequests += 1; return granted }
    func events(in interval:DateInterval) throws -> [CalendarEventItem] { calendarEvents.filter { $0.start < interval.end && $0.end > interval.start } }
    func reminders() async throws -> [ReminderItem] { items }
    func writableReminderCalendars() -> [ReminderCalendar] { [ReminderCalendar(id:"fixture",title:"Synthetic fixture")] }
    func saveReminder(_ item:ReminderItem,creating:Bool) throws -> ReminderItem {
        var result=item; if creating { result.id=UUID().uuidString }
        if let i=items.firstIndex(where:{$0.id == result.id}) { items[i]=result } else { items.append(result) }; return result
    }
    func deleteReminder(_ item:ReminderItem) throws { items.removeAll{$0.id == item.id} }
}
@MainActor final class CalendarCheckNotifications:ReminderNotificationProviding {
    var permissionRequests=0
    var pending:[ReminderNotification] = []
    var granted=false
    func access() async -> CalendarAccess { granted ? .granted:.notDetermined }
    func requestAccess() async throws -> Bool { permissionRequests += 1; granted=true; return true }
    func replacePending(_ notifications:[ReminderNotification]) async throws { pending=notifications }
}
