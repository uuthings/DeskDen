import AppKit
import Foundation
import LauncherCore

@main struct CalendarModelChecks {
    @MainActor static func main() async {
        _=NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-calendar-model-checks-\(UUID().uuidString)")
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
        model.openNewReminder()
        check(model.editor?.item.origin == .system && model.editor?.item.calendarID == "fixture",
              "connected reminders default new drafts to the provider's first writable list")
        var destinationDraft=model.editor!;destinationDraft.item.title="Synthetic destination validation"
        system.writableLists=[];await model.refresh()
        check(!(await model.saveDraft(destinationDraft)) && model.editor?.item.origin == .system
              && model.localReminders.count == 1 && system.writeCalls == 0,
              "an empty system list collection blocks saving without switching the draft to local storage")
        system.writableLists=[ReminderCalendar(id:"replacement",title:"Replacement list")];await model.refresh()
        check(!(await model.saveDraft(destinationDraft)) && model.editor?.item.calendarID == "fixture"
              && model.localReminders.count == 1 && system.writeCalls == 0,
              "a removed destination requires explicit reselection even when another writable list exists")
        system.writableLists=[ReminderCalendar(id:"fixture",title:"Synthetic fixture")];await model.refresh()
        var failedSystemDraft=model.editor!;failedSystemDraft.item.title="Synthetic rejected system reminder"
        system.failWrites=true
        check(!(await model.saveDraft(failedSystemDraft)) && model.editor?.id == failedSystemDraft.id && model.localReminders.count == 1 && system.items.isEmpty,
              "failed system save preserves its draft without creating a duplicate local reminder")
        system.failWrites=false;model.cancelEditor()
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
        model.openNewReminder()
        check(model.editor?.item.origin == .local && model.localReminders.count == 1,
              "disconnected reminder source offers an explicit local draft without migrating old content")
        model.cancelEditor()
        let connected=CalendarModel(dataDirectory:directory.appendingPathComponent("combined"),system:system,notifier:notifications)
        let beforeCombined=system.permissionRequests
        await connected.connectSystemSources()
        check(!connected.needsSystemConnection && connected.preferences.calendarConnected && connected.systemRemindersAvailable
              && system.permissionRequests == beforeCombined + 2,
              "explicit combined setup connects both independent system permissions")
        await connected.connectSystemSources()
        check(system.permissionRequests == beforeCombined + 2,"combined setup never requests already connected source permissions again")
        let partialSystem=CalendarCheckSystem();partialSystem.granted=true;partialSystem.calendarGranted=false
        let partial=CalendarModel(dataDirectory:directory.appendingPathComponent("partial"),system:partialSystem,notifier:notifications)
        await partial.connectSystemSources()
        check(!partial.preferences.calendarConnected && partial.systemRemindersAvailable && partialSystem.permissionRequests == 2
              && partial.errorMessage?.contains("未允许访问日历") == true,
              "denying Calendar still connects Reminders and reports the independently denied permission")
        model.disableNotifications(); await Task.yield()
        check(notifications.pending.isEmpty && !model.preferences.notificationsEnabled,"explicit notification disable cancels owned pending requests")
        check(system.calendarWrites == 0,"calendar integration never writes calendar events")

        var deadlineCalendar=Calendar(identifier:.gregorian);deadlineCalendar.timeZone=TimeZone(identifier:"Asia/Shanghai")!
        let deadlineAnchor=deadlineCalendar.date(from:DateComponents(year:2026,month:9,day:30,hour:23,minute:55))!
        let expectedDeadline=ReminderDue(year:2026,month:10,day:20,timeZoneIdentifier:"Asia/Shanghai")
        var relative=CalendarReminderDraft(item:ReminderItem(title:"Synthetic relative deadline"),creating:true,defaultDate:deadlineAnchor,calendar:deadlineCalendar,now:deadlineAnchor)
        relative.deadlineMode = .days;relative.deadlineDaysText="10"
        relative.countingRule=ReminderCountingRule(daysBasis:.weekdays,skipHolidays:true,includeMakeupWorkdays:true)
        relative.date=deadlineCalendar.date(from:DateComponents(year:2030,month:1,day:1))!
        relative.hasDate=true
        check(relative.deadlineMode == .days && relative.deadlineAnchor == deadlineAnchor,
              "legacy hasDate updates preserve relative mode and its fixed opening anchor")
        check((try? relative.value().due) == expectedDeadline,
              "relative draft resolves ten official working days independently from the specified-date field")
        let relativeDirectory=directory.appendingPathComponent("relative-deadline")
        let relativeSystem=CalendarCheckSystem(),relativeNotifications=CalendarCheckNotifications()
        let relativeModel=CalendarModel(dataDirectory:relativeDirectory,system:relativeSystem,notifier:relativeNotifications)
        await relativeModel.refresh();relativeModel.editor=relative
        check(await relativeModel.saveDraft(relative),"relative deadline saves through the real model and local store")
        check((try? ReminderStore(directory:relativeDirectory).load().reminders.first?.due) == expectedDeadline,
              "saved relative deadline is a fixed civil date in persistent storage")
        if let saved=relativeModel.localReminders.first {
            relativeModel.openReminder(saved)
            check(relativeModel.editor?.deadlineMode == .date && (try? relativeModel.editor?.value().due) == expectedDeadline,
                  "reopening a saved relative deadline uses its fixed date without counting again from today")
        } else {check(false,"saved relative deadline is available for editing")}
        var invalidRelative=relative;invalidRelative.deadlineDaysText="0";relativeModel.editor=invalidRelative
        check(!(await relativeModel.saveDraft(invalidRelative)) && relativeModel.editor?.id == invalidRelative.id
              && relativeModel.localReminders.count == 1 && relativeModel.errorMessage?.contains("整数天数") == true,
              "invalid day count preserves draft and does not create a reminder")
        invalidRelative.deadlineAnchor=deadlineCalendar.date(from:DateComponents(year:2026,month:12,day:30,hour:12))!
        invalidRelative.deadlineDaysText="2";relativeModel.editor=invalidRelative
        check(!(await relativeModel.saveDraft(invalidRelative)) && relativeModel.localReminders.count == 1
              && relativeModel.errorMessage?.contains("2027") == true,
              "missing official holiday data blocks saving without silently switching counting rules")
        let originalTimed=ReminderItem(title:"Synthetic imported reminder",due:ReminderDue(year:2026,month:10,day:3,hour:8,minute:45,timeZoneIdentifier:"Asia/Tokyo"))
        var timedRelative=CalendarReminderDraft(item:originalTimed,creating:false,defaultDate:deadlineAnchor,calendar:deadlineCalendar,now:deadlineAnchor)
        timedRelative.deadlineMode = .days;timedRelative.deadlineDaysText="1"
        let resolvedTimed=try? timedRelative.value()
        check(timedRelative.calendar.timeZone.identifier == "Asia/Tokyo" && resolvedTimed?.due?.day == 2
              && resolvedTimed?.due?.hour == 8 && resolvedTimed?.due?.minute == 45
              && resolvedTimed?.due?.timeZoneIdentifier == "Asia/Tokyo",
              "relative editing preserves imported time and timezone while using that zone's opening day")
        timedRelative.deadlineDaysText="invalid";timedRelative.hasDate=false
        check(timedRelative.deadlineMode == .none && (try? timedRelative.value())?.due == nil,
              "switching to no deadline clears the saved due without parsing stale day-count text")
        check(relativeSystem.permissionRequests == 0 && relativeNotifications.permissionRequests == 0 && relativeNotifications.pending.isEmpty,
              "relative deadlines neither request access nor schedule a notification for a date-only value")

        let delayedSystem=CalendarSuspendedCheckSystem()
        let delayedModel=CalendarModel(dataDirectory:directory.appendingPathComponent("suspended-reads"),system:delayedSystem,notifier:CalendarCheckNotifications())
        await delayedModel.refresh();await delayedModel.connect(reminders:true)
        for _ in 0..<5 {await Task.yield()}
        delayedSystem.suspends=true
        @MainActor func waitForPending(_ count:Int) async {
            for _ in 0..<2_000 {
                if delayedSystem.pendingCount >= count {return}
                try? await Task.sleep(for:.milliseconds(1))
            }
            check(false,"suspended system fixture receives its expected read");exit(1)
        }
        let beforeCompletion=Task {await delayedModel.refresh()}
        await waitForPending(1)
        await delayedModel.toggle(delayedModel.systemReminders[0])
        check(delayedModel.systemReminders[0].isCompleted && !delayedModel.isLoading,
              "successful completion revokes the pending read before publishing its saved state")
        let newerRead=Task {await delayedModel.refresh()}
        await waitForPending(2)
        delayedSystem.releaseFirst();await beforeCompletion.value
        check(delayedModel.systemReminders[0].isCompleted && delayedModel.isLoading,
              "an obsolete read neither reverses completion nor clears a newer read's loading state")
        delayedSystem.releaseFirst();await newerRead.value
        check(delayedModel.systemReminders[0].isCompleted && !delayedModel.isLoading,
              "the current read publishes fresh completion and releases its own loading state")

        let beforeDeletion=Task {await delayedModel.refresh()}
        await waitForPending(1)
        check(await delayedModel.delete(delayedModel.systemReminders[0]),"delete succeeds while an older read is suspended")
        delayedSystem.releaseFirst();await beforeDeletion.value
        check(delayedModel.systemReminders.isEmpty && !delayedModel.isLoading,
              "a pre-delete read cannot resurrect the deleted system reminder")
        let beforeRestore=Task {await delayedModel.refresh()}
        await waitForPending(1)
        await delayedModel.undoLastChange()
        delayedSystem.releaseFirst();await beforeRestore.value
        check(delayedModel.systemReminders.count == 1 && !delayedModel.isLoading,
              "an empty pre-undo read cannot remove a restored system reminder")

        await delayedModel.toggle(delayedModel.systemReminders[0])
        let beforeUndoCompletion=Task {await delayedModel.refresh()}
        await waitForPending(1)
        await delayedModel.undoLastChange()
        delayedSystem.releaseFirst();await beforeUndoCompletion.value
        check(delayedModel.systemReminders[0].isCompleted && !delayedModel.isLoading,
              "a read started before completion undo cannot overwrite the restored state")
        let beforeMiniCompletion=Task {await delayedModel.refreshMiniAgenda(timeZone:delayedModel.displayTimeZone)}
        await waitForPending(1)
        await delayedModel.toggle(delayedModel.systemReminders[0])
        delayedSystem.releaseFirst();await beforeMiniCompletion.value
        check(!delayedModel.systemReminders[0].isCompleted && !delayedModel.isLoading,
              "a pre-write Mini read also loses its right to publish old reminder state")

        delayedSystem.failWrites=true
        let beforeFailedWrite=Task {await delayedModel.refresh()}
        await waitForPending(1)
        await delayedModel.toggle(delayedModel.systemReminders[0])
        check(delayedModel.isLoading && !delayedModel.systemReminders[0].isCompleted,
              "a failed write preserves both the saved item and the valid pending read")
        delayedSystem.releaseFirst();await beforeFailedWrite.value;delayedSystem.failWrites=false
        check(!delayedModel.isLoading,"a valid read still finishes after a failed write")

        delayedSystem.items[0].isCompleted=true
        let cancelledRead=Task {await delayedModel.refresh()}
        await waitForPending(1);cancelledRead.cancel()
        delayedSystem.releaseFirst();await cancelledRead.value
        check(!delayedModel.systemReminders[0].isCompleted && !delayedModel.isLoading,
              "a cancelled read drops its captured snapshot and releases only its own loading state")
        delayedSystem.suspends=false;await delayedModel.refresh();delayedSystem.suspends=true
        delayedModel.errorMessage=nil
        let beforeStaleError=Task {await delayedModel.refresh()}
        await waitForPending(1)
        await delayedModel.toggle(delayedModel.systemReminders[0])
        delayedSystem.releaseFirst(error:ReminderError.unavailable("Synthetic obsolete read failure"));await beforeStaleError.value
        check(delayedModel.errorMessage == nil && !delayedModel.systemReminders[0].isCompleted && !delayedModel.isLoading,
              "an obsolete read failure cannot replace a successful write with an error")

        let beforeEdit=Task {await delayedModel.refresh()}
        await waitForPending(1)
        delayedModel.openReminder(delayedModel.systemReminders[0])
        var edited=delayedModel.editor!;edited.item.title="Synthetic updated title"
        let saving=Task {await delayedModel.saveDraft(edited)}
        await waitForPending(2)
        delayedSystem.releaseFirst();await beforeEdit.value
        check(delayedModel.systemReminders[0].title == edited.item.title && delayedModel.isLoading && delayedModel.isWorking,
              "a pre-edit read cannot overwrite a saved title or stop its follow-up refresh")
        delayedSystem.releaseFirst()
        check(await saving.value && delayedModel.systemReminders[0].title == edited.item.title && !delayedModel.isLoading && !delayedModel.isWorking,
              "the edit's fresh follow-up read completes normally after an obsolete read")
        print("Calendar model checks: \(checks-failures)/\(checks) passed")
        exit(failures == 0 ? 0:1)
    }
}
@MainActor final class CalendarCheckSystem:CalendarSystemProviding {
    var permissionRequests=0,calendarWrites=0
    var granted=false
    var calendarGranted:Bool?
    var failWrites=false
    var writeCalls=0
    var writableLists=[ReminderCalendar(id:"fixture",title:"Synthetic fixture")]
    var items:[ReminderItem] = []
    var calendarEvents:[CalendarEventItem] = []
    func access(reminders:Bool) -> CalendarAccess { (reminders ? granted:(calendarGranted ?? granted)) ? .granted:.denied }
    func requestAccess(reminders:Bool) async throws -> Bool { permissionRequests += 1; return access(reminders:reminders) == .granted }
    func events(in interval:DateInterval) throws -> [CalendarEventItem] { calendarEvents.filter { $0.start < interval.end && $0.end > interval.start } }
    func reminders() async throws -> [ReminderItem] { items }
    func writableReminderCalendars() -> [ReminderCalendar] {writableLists}
    func saveReminder(_ item:ReminderItem,creating:Bool) throws -> ReminderItem {
        writeCalls += 1
        if failWrites {throw ReminderError.unavailable("Synthetic write failure")}
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

@MainActor final class CalendarSuspendedCheckSystem:CalendarSystemProviding {
    private struct Pending {
        let snapshot:[ReminderItem]
        let continuation:CheckedContinuation<[ReminderItem],any Error>
    }
    private var pending:[Pending]=[]
    var pendingCount:Int {pending.count}
    var suspends=false
    var failWrites=false
    var items=[ReminderItem(id:"suspended-fixture",origin:.system,calendarID:"fixture",title:"Synthetic suspended read")]
    func access(reminders:Bool)->CalendarAccess {.granted}
    func requestAccess(reminders:Bool) async throws -> Bool {true}
    func events(in interval:DateInterval) throws -> [CalendarEventItem] {[]}
    func writableReminderCalendars()->[ReminderCalendar] {[.init(id:"fixture",title:"Synthetic fixture")]}
    func reminders() async throws -> [ReminderItem] {
        guard suspends else {return items}
        let snapshot=items
        return try await withCheckedThrowingContinuation {pending.append(Pending(snapshot:snapshot,continuation:$0))}
    }
    func releaseFirst(error:(any Error)?=nil) {
        let read=pending.removeFirst()
        if let error {read.continuation.resume(throwing:error)} else {read.continuation.resume(returning:read.snapshot)}
    }
    func saveReminder(_ item:ReminderItem,creating:Bool) throws -> ReminderItem {
        if failWrites {throw ReminderError.unavailable("Synthetic write failure")}
        var saved=item
        if creating {saved.id=UUID().uuidString}
        if let index=items.firstIndex(where:{$0.id == saved.id}) {items[index]=saved} else {items.append(saved)}
        return saved
    }
    func deleteReminder(_ item:ReminderItem) throws {items.removeAll {$0.id == item.id}}
}
