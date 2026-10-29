import AppKit
import SwiftUI
import LauncherCore

/// Exercises the mounted production editor with disposable local data. No real
/// EventKit permissions, reminder writes, notification delivery or global input.
@MainActor enum CalendarDeadlineEditorChecks {
    static func run() async -> (count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ condition:Bool,_ label:String) {count += 1;if !condition {failures += 1};print("\(condition ? "PASS":"FAIL") \(label)")}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-deadline-editor-\(UUID())")
        defer {try? FileManager.default.removeItem(at:directory)}
        do {
            var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Asia/Shanghai")!
            func civil(_ year:Int,_ month:Int,_ day:Int)->Date {calendar.date(from:DateComponents(year:year,month:month,day:day,hour:12))!}
            let anchor=civil(2026,9,30)
            try ReminderStore(directory:directory).save(ReminderSnapshot())
            let system=DeadlineEditorSystem(),notifier=DeadlineEditorNotifier()
            let model=CalendarModel(dataDirectory:directory,system:system,notifier:notifier)
            model.displayTimeZone=calendar.timeZone
            let coordinator=WorkbenchModalCoordinator()
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:760),styleMask:[.borderless],backing:.buffered,defer:false)
            window.alphaValue=0;window.ignoresMouseEvents=true;window.isReleasedWhenClosed=false
            let host=NSHostingView(rootView:DeadlineEditorCheckRoot(model:model,coordinator:coordinator).nativeCheckAccessibility())
            window.contentView=host;coordinator.hostWindow=window;window.orderFront(nil)
            defer {coordinator.clear();window.orderOut(nil);window.contentView=nil;window.close()}
            func newDraft(id:String,now:Date)->CalendarReminderDraft {
                CalendarReminderDraft(item:ReminderItem(id:id,title:"隔离期限待办",notificationsEnabled:false),creating:true,defaultDate:now,calendar:calendar,now:now)
            }
            model.editor=newDraft(id:"relative",now:anchor)
            _=await wait(host){coordinator.presentations.count == 1 && find("fc.calendar.editor.mode.none",in:host) != nil}
            try NativeUIFixtureAccessibility.saveView(host,name:"calendar-deadline-initial.png")
            check(coordinator.top?.width == 640 && summary(host).contains("没有任何期限限制"),"deadline editor opens at shared 640 width and gives no-deadline explanatory text")
            check(press("fc.calendar.editor.mode.date",in:host),"actual specified-date segment accepts an accessibility press")
            _=await wait(host){dateSurfaces(host).count == 1}
            check(dateSurfaces(host).first?.fields.count == 3 && summary(host).contains("截止"),"specified date mounts three independent editable year/month/day choices and a deadline summary")
            check(press("fc.calendar.editor.mode.none",in:host),"actual no-deadline segment accepts a press")
            _=await wait(host){dateSurfaces(host).isEmpty}
            check(dateSurfaces(host).isEmpty && summary(host).contains("没有任何期限限制"),"no deadline removes date choices while retaining the explanatory row")
            _=press("fc.calendar.editor.mode.days",in:host)
            _=await wait(host){daysField(host) != nil}
            check(summary(host).contains("10月10日") && daysField(host) != nil,"specified days resolves ten natural days from the pinned civil start day")
            if let field=daysField(host),let modeFrame=frame("fc.calendar.editor.deadline-mode",in:host) {
                let numberFrame=window.convertToScreen(field.convert(field.bounds,to:nil))
                check(abs(modeFrame.midY-numberFrame.midY)<3,"deadline segments and the number input share one horizontal control row")
            } else {check(false,"deadline control geometry is available")}
            setDays("0",in:host);await settle(host)
            check(text("fc.calendar.editor.deadline-error",in:host).contains("1 至 3650") && !enabled("fc.calendar.editor.save",in:host),"zero days shows the real validation error and disables creation")
            setDays("1.5",in:host);await settle(host)
            check(!enabled("fc.calendar.editor.save",in:host),"fractional days cannot be saved through the actual editor")
            setDays("10",in:host);await settle(host)
            check(find("fc.calendar.editor.deadline-error",in:host) == nil && enabled("fc.calendar.editor.save",in:host),"valid integer input restores creation without closing the editor")

            _=press("fc.calendar.editor.counting-settings",in:host)
            _=await wait(host){coordinator.presentations.count == 2}
            _=press("fc.calendar.counting.basis.weekdays",in:host)
            _=press("fc.calendar.counting.skip-holidays",in:host)
            _=pressLabel("取消",in:host)
            _=await wait(host){coordinator.presentations.count == 1}
            check(summary(host).contains("10月10日") && summary(host).contains("每天") && !summary(host).contains("跳过"),"cancelling counting settings discards the nested rule draft")
            _=press("fc.calendar.editor.counting-settings",in:host)
            _=await wait(host){coordinator.presentations.count == 2}
            _=press("fc.calendar.counting.basis.weekdays",in:host)
            _=press("fc.calendar.counting.skip-holidays",in:host)
            _=press("fc.calendar.counting.include-makeup",in:host)
            _=press("fc.calendar.counting.apply",in:host)
            _=await wait(host){coordinator.presentations.count == 1}
            check(summary(host).contains("10月20日") && summary(host).contains("调休"),"applying workdays, holiday exclusion and makeup days updates the real draft deadline")

            guard let noteScroll=notes(host),let noteEditor=noteScroll.documentView as? NSTextView else {throw ReminderError.unavailable("备注编辑器未挂载")}
            check(abs(noteScroll.bounds.height-48)<1 && noteScroll.scrollerStyle == .overlay && noteScroll.autohidesScrollers,"empty notes start at two full lines with the global overlay scrollbar policy")
            noteEditor.string="第一行\n第二行\n第三行";noteEditor.didChangeText();await settle(host)
            check(abs(noteScroll.bounds.height-64)<1,"notes grow to three complete lines as native text changes")
            noteEditor.string=(1...6).map{"第\($0)行"}.joined(separator:"\n");noteEditor.didChangeText();await settle(host)
            check(abs(noteScroll.bounds.height-112)<1,"notes grow to six complete lines")
            noteEditor.string=(1...10).map{"第\($0)行"}.joined(separator:"\n");noteEditor.didChangeText();await settle(host)
            check(abs(noteScroll.bounds.height-112)<1 && noteEditor.bounds.height>noteScroll.contentSize.height,"notes stop at six lines and retain additional lines in a scrollable document")
            noteEditor.string="";noteEditor.didChangeText();await settle(host)
            check(abs(noteScroll.bounds.height-48)<1,"clearing notes restores the two-line minimum")
            try NativeUIFixtureAccessibility.saveView(host,name:"calendar-deadline-editor.png")

            _=press("fc.calendar.editor.save",in:host)
            _=await wait(host){model.editor == nil && model.localReminders.count == 1}
            guard let saved=model.localReminders.first else {throw ReminderError.unavailable("实际创建未完成")}
            check(saved.due == ReminderDue(year:2026,month:10,day:20,timeZoneIdentifier:"Asia/Shanghai") && !saved.isCompleted,"actual Create resolves the workday rule to one fixed date in local reminder storage")
            model.openReminder(saved)
            _=await wait(host){coordinator.presentations.count == 1 && dateSurfaces(host).count == 1}
            check(model.editor?.deadlineMode == .date && daysField(host) == nil && summary(host).contains("10月20日"),"reopening a saved relative deadline uses its fixed specified date rather than rolling it forward")
            let beforeDiscard=try Data(contentsOf:ReminderStore(directory:directory).url)
            _=press("fc.calendar.editor.mode.days",in:host);await settle(host)
            _=pressLabel("取消",in:host)
            _=await wait(host){coordinator.presentations.count == 2}
            check(coordinator.presentations.count == 2 && model.editor != nil,"closing a changed deadline opens the shared unsaved-draft confirmation")
            _=pressLabel("继续编辑",in:host)
            _=await wait(host){coordinator.presentations.count == 1}
            check(daysField(host) != nil,"returning from discard confirmation preserves the selected deadline draft")
            _=pressLabel("取消",in:host);_=await wait(host){coordinator.presentations.count == 2}
            _=pressLabel("放弃修改",in:host);_=await wait(host){model.editor == nil && coordinator.presentations.isEmpty}
            check((try? Data(contentsOf:ReminderStore(directory:directory).url)) == beforeDiscard,"discarding the changed deadline leaves persisted reminder data unchanged")

            model.editor=newDraft(id:"undated",now:anchor);_=await wait(host){coordinator.presentations.count == 1}
            _=press("fc.calendar.editor.save",in:host);_=await wait(host){model.editor == nil && model.localReminders.count == 2}
            check(model.localReminders.first{$0.id == "undated"}?.due == nil,"creating no-deadline mode produces an actual long-term reminder without an invented date")
            model.editor=newDraft(id:"unknown-year",now:civil(2026,12,30))
            _=await wait(host){coordinator.presentations.count == 1}
            _=press("fc.calendar.editor.mode.days",in:host);await settle(host)
            _=press("fc.calendar.editor.counting-settings",in:host);_=await wait(host){coordinator.presentations.count == 2}
            _=press("fc.calendar.counting.skip-holidays",in:host);_=press("fc.calendar.counting.apply",in:host)
            _=await wait(host){coordinator.presentations.count == 1}
            check(text("fc.calendar.editor.deadline-error",in:host).contains("2027") && !enabled("fc.calendar.editor.save",in:host),"crossing an unrecorded holiday year blocks saving with an explicit year-specific error")
            check(!model.localReminders.contains{$0.id == "unknown-year"},"an unsupported holiday calculation never writes a guessed deadline")
            model.cancelEditor();_=await wait(host){coordinator.presentations.isEmpty}
            let timedDue=ReminderDue(year:2026,month:10,day:20,hour:15,minute:30,timeZoneIdentifier:calendar.timeZone.identifier)
            let timedItem=ReminderItem(id:"timed-mode-roundtrip",title:"保留指定时刻",due:timedDue,notificationsEnabled:false)
            let timedDraft=CalendarReminderDraft(item:timedItem,creating:true,defaultDate:anchor,calendar:calendar,now:anchor)
            let seeded=await model.saveDraft(timedDraft)
            guard seeded,let timed=model.localReminders.first(where:{$0.id == timedItem.id}) else {throw ReminderError.unavailable("指定时刻隔离样本未保存")}
            model.openReminder(timed)
            _=await wait(host){coordinator.presentations.count == 1 && timeSurfaces(host).count == 1}
            check(timeSurfaces(host).first?.fields.map{$0.field.stringValue} == ["15","30"],"editing an existing timed reminder mounts its original hour and minute")
            _=press("fc.calendar.editor.mode.none",in:host)
            _=await wait(host){dateSurfaces(host).isEmpty && timeSurfaces(host).isEmpty}
            _=press("fc.calendar.editor.mode.date",in:host)
            _=await wait(host){dateSurfaces(host).count == 1 && timeSurfaces(host).count == 1}
            check(timeSurfaces(host).first?.fields.map{$0.field.stringValue} == ["15","30"],"switching an existing timed reminder through no deadline back to a specified date retains its time")
            _=press("fc.calendar.editor.save",in:host)
            _=await wait(host){model.editor == nil && coordinator.presentations.isEmpty}
            guard let afterDate=model.localReminders.first(where:{$0.id == timedItem.id}) else {throw ReminderError.unavailable("指定日期切换后记录丢失")}
            check(afterDate.due == timedDue,"saving after the no-deadline/date roundtrip preserves the exact stored deadline and timezone")
            model.openReminder(afterDate)
            _=await wait(host){coordinator.presentations.count == 1 && timeSurfaces(host).count == 1}
            guard let daysAnchor=model.editor?.deadlineAnchor else {throw ReminderError.unavailable("指定天数起算日期丢失")}
            let expectedDay=calendar.date(byAdding:.day,value:10,to:daysAnchor)!
            var expectedTimedDue=ReminderDue(date:expectedDay,includesTime:false,calendar:calendar)
            expectedTimedDue.hour=15;expectedTimedDue.minute=30
            _=press("fc.calendar.editor.mode.none",in:host)
            _=await wait(host){timeSurfaces(host).isEmpty}
            _=press("fc.calendar.editor.mode.days",in:host)
            _=await wait(host){daysField(host) != nil && timeSurfaces(host).count == 1}
            check(timeSurfaces(host).first?.fields.map{$0.field.stringValue} == ["15","30"],"switching an existing timed reminder through no deadline to specified days retains its time")
            _=press("fc.calendar.editor.save",in:host)
            _=await wait(host){model.editor == nil && coordinator.presentations.isEmpty}
            guard let afterDays=model.localReminders.first(where:{$0.id == timedItem.id}) else {throw ReminderError.unavailable("指定天数切换后记录丢失")}
            check(afterDays.due == expectedTimedDue,"saving specified days after a no-deadline roundtrip keeps the original clock time on the computed date")
            model.openReminder(afterDays)
            _=await wait(host){coordinator.presentations.count == 1 && timeSurfaces(host).count == 1}
            _=press("fc.calendar.editor.mode.none",in:host)
            _=await wait(host){dateSurfaces(host).isEmpty && timeSurfaces(host).isEmpty}
            _=press("fc.calendar.editor.save",in:host)
            _=await wait(host){model.editor == nil && coordinator.presentations.isEmpty}
            check(model.localReminders.first{$0.id == timedItem.id}?.due == nil,"saving final no-deadline mode removes the persisted deadline despite retaining latent time while editing")
            check(system.permissionRequests == 0 && notifier.permissionRequests == 0 && notifier.pending.isEmpty,"deadline editor verification uses no real permissions, system reminder writes or notifications")
        } catch {check(false,"deadline editor fixture: \(error.localizedDescription)")}
        print("Deadline editor checks: \(count) checks, \(failures) failures")
        return(count,failures)
    }
    private static func objects(_ root:NSObject)->[NSObject] {
        var pending=[root],seen=Set<ObjectIdentifier>(),result:[NSObject]=[]
        while let node=pending.popLast(),seen.count<4096 {
            guard seen.insert(ObjectIdentifier(node)).inserted else{continue};result.append(node)
            if let view=node as? NSView {pending.append(contentsOf:view.subviews)}
            if node.responds(to:NSSelectorFromString("accessibilityChildren")),let children=node.value(forKey:"accessibilityChildren") as? [NSObject] {pending.append(contentsOf:children)}
        }
        return result
    }
    private static func property(_ key:String,_ node:NSObject)->String? {node.responds(to:NSSelectorFromString(key)) ? node.value(forKey:key) as? String:nil}
    private static func find(_ id:String,in host:NSView)->NSObject? {objects(host).first{property("accessibilityIdentifier",$0) == id}}
    private static func text(_ id:String,in host:NSView)->String {
        guard let node=find(id,in:host) else{return ""}
        return objects(node).flatMap{node in ["accessibilityLabel","accessibilityValue","accessibilityTitle"].compactMap{property($0,node)}}.joined(separator:" ")
    }
    private static func summary(_ host:NSView)->String {text("fc.calendar.editor.deadline-summary",in:host)}
    private static func frame(_ id:String,in host:NSView)->CGRect? {
        guard let node=find(id,in:host),node.responds(to:NSSelectorFromString("accessibilityFrame")) else{return nil}
        return (node.value(forKey:"accessibilityFrame") as? NSValue)?.rectValue
    }
    private static func enabled(_ id:String,in host:NSView)->Bool {
        guard let node=find(id,in:host),node.responds(to:NSSelectorFromString("isAccessibilityEnabled")) else{return false}
        return node.value(forKey:"accessibilityEnabled") as? Bool ?? false
    }
    @discardableResult private static func press(_ id:String,in host:NSView)->Bool {
        pressObject(objects(host).first{property("accessibilityIdentifier",$0) == id && $0.responds(to:NSSelectorFromString("accessibilityPerformPress"))})
    }
    @discardableResult private static func pressLabel(_ label:String,in host:NSView)->Bool {
        pressObject(objects(host).first{property("accessibilityLabel",$0) == label && $0.responds(to:NSSelectorFromString("accessibilityPerformPress")) && (!$0.responds(to:NSSelectorFromString("isAccessibilityEnabled")) || $0.value(forKey:"accessibilityEnabled") as? Bool == true)})
    }
    private static func pressObject(_ node:NSObject?)->Bool {
        let selector=NSSelectorFromString("accessibilityPerformPress")
        guard let node else{return false}
        typealias Press = @convention(c) (AnyObject,Selector)->Bool
        return unsafeBitCast(node.method(for:selector),to:Press.self)(node,selector)
    }
    private static func daysField(_ host:NSView)->NSTextField? {
        objects(host).compactMap{$0 as? NSTextField}.first{$0.isEditable && ($0.placeholderString == "10" || $0.accessibilityIdentifier() == "fc.calendar.editor.deadline-days")}
    }
    private static func setDays(_ value:String,in host:NSView) {
        guard let field=daysField(host) else{return}
        field.stringValue=value
        field.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:field))
    }
    private static func notes(_ host:NSView)->NSScrollView? {objects(host).compactMap{$0 as? NSScrollView}.first{$0.accessibilityIdentifier() == "fc.calendar.editor.notes"}}
    private static func dateSurfaces(_ host:NSView)->[WBDateInputSurface] {objects(host).compactMap{$0 as? WBDateInputSurface}.filter{$0.components == .date}}
    private static func timeSurfaces(_ host:NSView)->[WBDateInputSurface] {objects(host).compactMap{$0 as? WBDateInputSurface}.filter{$0.components == .time}}
    private static func wait(_ host:NSView,_ condition:()->Bool) async ->Bool {
        for _ in 0..<80 {host.layoutSubtreeIfNeeded();if condition(){await settle(host);return true};try? await Task.sleep(for:.milliseconds(10))};return condition()
    }
    private static func settle(_ host:NSView) async {for _ in 0..<8 {host.layoutSubtreeIfNeeded();try? await Task.sleep(for:.milliseconds(10))}}
}
private struct DeadlineEditorCheckRoot:View {
    @ObservedObject var model:CalendarModel
    @ObservedObject var coordinator:WorkbenchModalCoordinator
    var body:some View {
        ZStack {CalendarDialogs(model:model);WorkbenchModalHost(coordinator:coordinator)}
            .environment(\.workbenchModals,coordinator)
            .workbenchThemeEnvironment(theme:.arWorld,opacity:0.70,backgroundMotion:false)
    }
}
@MainActor private final class DeadlineEditorSystem:CalendarSystemProviding {
    var permissionRequests=0
    func access(reminders:Bool)->CalendarAccess {.notDetermined}
    func requestAccess(reminders:Bool) async throws ->Bool {permissionRequests += 1;return false}
    func events(in interval:DateInterval) throws ->[CalendarEventItem] {[]}
    func calendarSources()->[CalendarSourceDescriptor] {[]}
    func reminders() async throws ->[ReminderItem] {[]}
    func writableReminderCalendars()->[ReminderCalendar] {[]}
    func saveReminder(_ item:ReminderItem,creating:Bool) throws ->ReminderItem {throw ReminderError.unavailable("隔离验证禁止系统写入")}
    func deleteReminder(_ item:ReminderItem) throws {throw ReminderError.unavailable("隔离验证禁止系统删除")}
}
@MainActor private final class DeadlineEditorNotifier:ReminderNotificationProviding {
    var permissionRequests=0
    var pending:[ReminderNotification]=[]
    func access() async ->CalendarAccess {.notDetermined}
    func requestAccess() async throws ->Bool {permissionRequests += 1;return false}
    func replacePending(_ notifications:[ReminderNotification]) async throws {pending=notifications}
}
