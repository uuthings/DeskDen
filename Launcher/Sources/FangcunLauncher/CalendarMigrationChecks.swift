import AppKit
import LauncherCore
import SwiftUI

/// Native model checks use an in-memory EventKit adapter and notifier. They do
/// not request real calendar/notification access or change the user's reminders.
@MainActor enum CalendarMigrationChecks {
    static func run() async -> (count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ condition:Bool,_ name:String){count += 1;if !condition {failures += 1};print("\(condition ? "PASS":"FAIL") \(name)")}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-calendar-v5-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:directory)}
        do {
            var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"America/New_York")!
            let due=ReminderDue(date:Date().addingTimeInterval(86_400),includesTime:true,calendar:calendar)
            let on=ReminderItem(id:"on",title:"允许通知",due:due)
            let off=ReminderItem(id:"off",title:"不通知但保留",due:due,notificationsEnabled:false)
            var snapshot=ReminderSnapshot();snapshot.reminders=[on,off]
            snapshot.preferences.calendarConnected=true;snapshot.preferences.remindersConnected=true;snapshot.preferences.notificationsEnabled=true
            try ReminderStore(directory:directory).save(snapshot)
            let system=CalendarMigrationSystem(),notifier=CalendarMigrationNotifier()
            let near=Date().addingTimeInterval(2*86_400),far=ISO8601DateFormatter().date(from:"2032-06-15T12:00:00Z")!
            system.values=[CalendarEventItem(id:"near",title:"首页七天日程",start:near,end:near.addingTimeInterval(3600),calendarName:"个人",calendarID:"personal"),CalendarEventItem(id:"far",title:"远月日程",start:far,end:far.addingTimeInterval(3600),calendarName:"工作",calendarID:"work")]
            let model=CalendarModel(dataDirectory:directory,system:system,notifier:notifier)
            model.displayTimeZone=calendar.timeZone
            await model.refresh();await settle()
            check(model.overviewEvents.map(\.id) == ["near"],"calendar overview queries its independent upcoming seven days")
            model.displayedMonth=far;model.selectedDay=far
            await model.refresh();await settle()
            check(model.events.map(\.id) == ["far"] && model.overviewEvents.map(\.id) == ["near"],"browsing a distant month cannot remove near events from home")
            check(system.permissionRequests == 0 && model.calendarSources.count == 2,"calendar source inspection uses actual adapters without requesting permission")
            model.setSourceVisible("personal",false)
            check(model.overviewEvents.isEmpty && model.overviewEventValues.map(\.id) == ["near"],"source filtering hides displayed events while retaining their source data")
            let reloaded=CalendarModel(dataDirectory:directory,system:system,notifier:CalendarMigrationNotifier())
            check(!reloaded.isSourceVisible("personal"),"calendar source visibility survives an independent reload")
            model.setSourceVisible("personal",true)
            check(model.overviewEvents.map(\.id) == ["near"],"restoring source visibility restores the same read-only events")

            model.displayTimeZone=TimeZone(identifier:"Asia/Shanghai")!
            model.openReminder(off)
            var edited=model.editor!
            edited.item.title="只改标题"
            check(try edited.value().due == due && !edited.value().notificationsEnabled,"editing a title in another display zone preserves original due and opt-out")
            let before=try Data(contentsOf:ReminderStore(directory:directory).url)
            model.editor=nil
            check((try? Data(contentsOf:ReminderStore(directory:directory).url)) == before,"cancelling a calendar editor does not persist its candidate")
            model.openReminder(off);edited=model.editor!;edited.item.title="已更新标题"
            check(await model.saveDraft(edited),"calendar draft saves through the existing reminder service")
            await settle()
            check(model.localReminders.first{$0.id == "off"}?.due == due && model.localReminders.first{$0.id == "off"}?.notificationsEnabled == false,"saved edits retain source time zone and per-item notification preference")
            check(notifier.pending.map(\.title) == ["允许通知"],"native scheduling omits only the opted-out reminder")

            model.disableNotifications();await settle()
            check(notifier.pending.isEmpty && model.localReminders.count == 2,"global disable cancels pending local notifications without removing reminders")
            await model.enableNotifications();await settle()
            check(notifier.pending.map(\.title) == ["允许通知"] && model.localReminders.first{$0.id == "off"}?.notificationsEnabled == false,"global re-enable preserves each reminder's independent choice")
            let savedOff=model.localReminders.first{$0.id == "off"}!
            await model.toggle(savedOff);await settle()
            check(model.localReminders.first{$0.id == "off"}?.isCompleted == true,"calendar completion updates the actual local reminder")
            await model.undoLastChange();await settle()
            check(model.localReminders.first{$0.id == "off"}?.isCompleted == false && model.localReminders.first{$0.id == "off"}?.notificationsEnabled == false,"undo completion preserves the per-reminder notification choice")
            try await model.suspendOwnNotificationsForQuit()
            check(notifier.pending.isEmpty,"explicit quit suspends only the isolated local notification plan")
            model.resumeOwnNotificationsAfterCancelledQuit();await settle()
            check(notifier.pending.map(\.title) == ["允许通知"],"cancelled quit restores the same filtered notification plan")

            model.displayedMonth=far;model.changeMonth(1)
            check(model.displayCalendar.component(.month,from:model.selectedDay) == 7 && model.displayCalendar.component(.day,from:model.selectedDay) == 1,"month navigation selects a valid first day in the new month")
            let editorChecks=await checkEditorErrors(directory:directory.appendingPathComponent("editor-errors"))
            count += editorChecks.count;failures += editorChecks.failures
        } catch {check(false,"calendar migration fixture: \(error.localizedDescription)")}
        return(count,failures)
    }
    private static func checkEditorErrors(directory:URL) async ->(count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ condition:Bool,_ name:String){count += 1;if !condition {failures += 1};print("\(condition ? "PASS":"FAIL") \(name)")}
        do {
            let original=ReminderItem(id:"isolated-editor-error",title:"隔离提醒原始标题",notificationsEnabled:false)
            var initial=ReminderSnapshot();initial.reminders=[original]
            let store=ReminderStore(directory:directory);try store.save(initial)
            let system=CalendarMigrationSystem(),notifier=CalendarMigrationNotifier()
            let model=CalendarModel(dataDirectory:directory,system:system,notifier:notifier)
            let coordinator=WorkbenchModalCoordinator()
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:760),styleMask:[.borderless],backing:.buffered,defer:false)
            window.alphaValue=0;window.ignoresMouseEvents=true;window.isReleasedWhenClosed=false
            let host=NSHostingView(rootView:CalendarMigrationDialogRoot(model:model,coordinator:coordinator))
            window.contentView=host;coordinator.hostWindow=window;window.orderFront(nil)
            defer {coordinator.clear();window.orderOut(nil);window.contentView=nil;window.close()}
            model.openReminder(original)
            _=await wait(host){coordinator.presentations.count == 1}
            await settle(host)
            guard var draft=model.editor else {throw ReminderError.invalid("隔离编辑器未打开。")}
            let editorID=draft.id,presentationID=coordinator.top?.id,before=try Data(contentsOf:store.url)
            draft.item.title="   "
            let rejected=await model.saveDraft(draft)
            check(!rejected && model.errorMessage?.contains("提醒标题") == true && model.editor?.id == editorID &&
                  (try? Data(contentsOf:store.url)) == before,
                  "invalid calendar draft retains the editor and real validation error without changing reminder storage")
            _=await wait(host){!axElements(identifier:"fc.calendar.editor.inline-error",in:host).isEmpty}
            scrollToBottom(host)
            let inlineVisible=await wait(host){visibleAX(identifier:"fc.calendar.editor.inline-error",text:"提醒标题",in:host,window:window)}
            check(inlineVisible && presentationID != nil && coordinator.top?.id == presentationID && coordinator.presentations.count == 1 && window.attachedSheet == nil,
                  "the actual cached calendar editor displays its inline validation text without opening a second alert")
            draft.item.title="隔离提醒有效标题"
            let saved=await model.saveDraft(draft)
            let dismissed=await wait(host){coordinator.presentations.isEmpty}
            check(saved && model.errorMessage == nil && model.editor == nil && dismissed &&
                  model.localReminders.first{$0.id == original.id}?.title == draft.item.title,
                  "a valid calendar retry saves through the real service and clears both editor and prior error")
            check(axElements(identifier:"fc.calendar.editor.inline-error",in:host).isEmpty &&
                  axElements(identifier:"fc.calendar.error.dialog",in:host).isEmpty && window.attachedSheet == nil,
                  "successful calendar retry leaves no stale inline error, shared error modal or native alert")

            let afterSave=try Data(contentsOf:store.url)
            guard let savedItem=model.localReminders.first(where:{$0.id == original.id}) else {throw ReminderError.invalid("隔离已保存提醒未返回。")}
            model.openReminder(savedItem)
            _=await wait(host){coordinator.presentations.count == 1};await settle(host)
            guard var cancelled=model.editor else {throw ReminderError.invalid("隔离取消编辑器未打开。")}
            cancelled.item.title=""
            _=await model.saveDraft(cancelled)
            check(model.errorMessage != nil && model.editor != nil,"calendar cancellation fixture starts with a real failed validation attempt")
            model.cancelEditor()
            let cancelledClosed=await wait(host){coordinator.presentations.isEmpty}
            check(cancelledClosed && model.editor == nil && model.errorMessage == nil &&
                  axElements(identifier:"fc.calendar.error.dialog",in:host).isEmpty && (try? Data(contentsOf:store.url)) == afterSave,
                  "cancelling calendar editing clears its error without saving the invalid draft or opening an orphan error modal")

            let generic="隔离验证：提醒操作无法完成。"
            model.errorMessage=generic
            let genericMounted=await wait(host){visibleAX(identifier:"fc.calendar.error.dialog",text:generic,in:host,window:window)}
            check(genericMounted && coordinator.presentations.count == 1 && coordinator.top?.width == 470 && window.attachedSheet == nil && model.editor == nil,
                  "an independent calendar error appears as the real shared centered modal with its actual message")
            coordinator.dismissTop()
            let genericClosed=await wait(host){coordinator.presentations.isEmpty}
            check(genericClosed && model.errorMessage == nil && window.attachedSheet == nil,
                  "dismissing the shared calendar error clears its observed message and modal state")
            check(system.permissionRequests == 0 && notifier.permissionRequests == 0 && notifier.pending.isEmpty &&
                  model.localReminders.allSatisfy{!$0.notificationsEnabled && $0.due == nil},
                  "calendar editor fixtures use only isolated local reminders and never request system permissions or schedule real notifications")
        } catch {check(false,"calendar editor error fixture: \(error.localizedDescription)")}
        return(count,failures)
    }
    private static func axElements(identifier:String,in host:NSView)->[NSObject] {
        axObjects(host).filter{axString("accessibilityIdentifier",from:$0) == identifier}
    }
    private static func visibleAX(identifier:String,text:String,in host:NSView,window:NSWindow)->Bool {
        let bounds=window.convertToScreen(host.convert(host.bounds,to:nil)).insetBy(dx:-1,dy:-1)
        return axElements(identifier:identifier,in:host).contains {object in
            guard object.responds(to:NSSelectorFromString("accessibilityFrame")),let value=object.value(forKey:"accessibilityFrame") as? NSValue else{return false}
            let frame=value.rectValue
            guard frame.width>0,frame.height>0,bounds.contains(frame) else{return false}
            if let view=object as? NSView,view.isHiddenOrHasHiddenAncestor{return false}
            return axObjects(object).contains {node in
                [axString("accessibilityLabel",from:node),axString("accessibilityValue",from:node),axString("accessibilityTitle",from:node)]
                    .compactMap{$0}.contains{$0.contains(text)}
            }
        }
    }
    private static func axObjects(_ root:NSObject)->[NSObject] {
        var pending=[root],seen=Set<ObjectIdentifier>(),result:[NSObject]=[]
        while let object=pending.popLast(),seen.count<4096 {
            guard seen.insert(ObjectIdentifier(object)).inserted else{continue};result.append(object)
            if let view=object as? NSView {pending.append(contentsOf:view.subviews)}
            if object.responds(to:NSSelectorFromString("accessibilityChildren")),let children=object.value(forKey:"accessibilityChildren") as? [NSObject] {pending.append(contentsOf:children)}
        }
        return result
    }
    private static func axString(_ property:String,from object:NSObject)->String? {
        object.responds(to:NSSelectorFromString(property)) ? object.value(forKey:property) as? String:nil
    }
    private static func scrollToBottom(_ host:NSView) {
        for scroll in axObjects(host).compactMap({$0 as? NSScrollView}) {
            guard let document=scroll.documentView,document.bounds.height>scroll.contentView.bounds.height+1 else{continue}
            let y=document.isFlipped ? max(document.bounds.minY,document.bounds.maxY-20):document.bounds.minY
            _=document.scrollToVisible(NSRect(x:document.bounds.minX,y:y,width:document.bounds.width,height:20))
        }
    }
    private static func wait(_ host:NSView,until condition:()->Bool) async ->Bool {
        let deadline=ContinuousClock.now.advanced(by:.seconds(2))
        repeat {host.layoutSubtreeIfNeeded();if condition(){return true};try? await Task.sleep(for:.milliseconds(5))}while ContinuousClock.now<deadline
        return condition()
    }
    private static func settle(_ host:NSView) async {for _ in 0..<3 {host.layoutSubtreeIfNeeded();try? await Task.sleep(for:.milliseconds(25))}}
    private static func settle() async {for _ in 0..<16 {await Task.yield()}}
}

private struct CalendarMigrationDialogRoot:View {
    @ObservedObject var model:CalendarModel
    @ObservedObject var coordinator:WorkbenchModalCoordinator
    var body:some View {
        ZStack {CalendarDialogs(model:model);WorkbenchModalHost(coordinator:coordinator)}
            .environment(\.workbenchModals,coordinator)
            .workbenchThemeEnvironment(theme:.arWorld,opacity:0.70,backgroundMotion:false)
    }
}

@MainActor private final class CalendarMigrationSystem:CalendarSystemProviding {
    var values:[CalendarEventItem]=[]
    var permissionRequests=0
    func access(reminders:Bool)->CalendarAccess {.granted}
    func requestAccess(reminders:Bool) async throws -> Bool {permissionRequests += 1;return true}
    func events(in interval:DateInterval) throws -> [CalendarEventItem] {values.filter{$0.start < interval.end && $0.end > interval.start}}
    func calendarSources()->[CalendarSourceDescriptor] {[.init(id:"personal",title:"个人"),.init(id:"work",title:"工作")]}
    func reminders() async throws -> [ReminderItem] {[]}
    func writableReminderCalendars()->[ReminderCalendar] {[]}
    func saveReminder(_ item:ReminderItem,creating:Bool) throws -> ReminderItem {throw ReminderError.unavailable("此检查未启用系统提醒写入")}
    func deleteReminder(_ item:ReminderItem) throws {throw ReminderError.unavailable("此检查未启用系统提醒删除")}
}
@MainActor private final class CalendarMigrationNotifier:ReminderNotificationProviding {
    var pending:[ReminderNotification]=[]
    var permissionRequests=0
    func access() async -> CalendarAccess {.granted}
    func requestAccess() async throws -> Bool {permissionRequests += 1;return true}
    func replacePending(_ notifications:[ReminderNotification]) async throws {pending=notifications}
}
