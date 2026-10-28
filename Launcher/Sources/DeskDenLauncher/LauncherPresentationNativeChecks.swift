import AppKit
import LauncherCore

/// Exercises physical-key routing against the real list viewport and popover.
@MainActor enum LauncherPresentationNativeChecks {
    static func run()->(count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ message:String){count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") \(message)")}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-launcher-presentation-\(UUID().uuidString)")
        let owner=LauncherController(dataDirectory:directory)
        owner.configurePanel();owner.scanning=true
        owner.configuration.bindings=[:]
        owner.configuration.settings.display = .list
        owner.configuration.settings.defaultView = .keys
        defer {owner.closeOverlay(render:false);owner.panel.orderOut(nil);owner.toastTask?.cancel();owner.hotKey.unregister();owner.bindingHotKeys.unregister();try? FileManager.default.removeItem(at:directory)}
        let application=directory.appendingPathComponent("BoundFixture.app")
        let contents=application.appendingPathComponent("Contents")
        do {
            try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true)
            let metadata:[String:Any]=["CFBundleIdentifier":"test.deskden.bound-search","CFBundleName":"MountainEditor","CFBundleExecutable":"MountainEditor","CFBundlePackageType":"APPL"]
            try PropertyListSerialization.data(fromPropertyList:metadata,format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
            let target=LaunchTarget(kind:.app,name:"山间编辑",location:application.path,keywords:"自定义词")
            owner.configuration.bindings["A"]=KeyBinding(target:target,alias:"我的笔记")
            let saved=owner.configuration
            owner.rebuildIndex()
            check(SearchEngine.search(owner.searchIndex,query:"mountain").contains {$0.target.id == target.id},"bound apps outside scanned directories retain their actual English bundle name")
            check(SearchEngine.search(owner.searchIndex,query:"me").contains {$0.target.id == target.id} && SearchEngine.search(owner.searchIndex,query:"mnted").contains {$0.target.id == target.id},"outside-catalog English initials and bounded fuzzy search work in parallel")
            check(owner.configuration == saved && SearchEngine.search(owner.searchIndex,query:"我的笔记").contains {$0.target.id == target.id},"search enrichment preserves the saved alias, keywords and configuration")
            owner.configuration.bindings=[:];owner.rebuildIndex()
        } catch {check(false,"bound English metadata fixture is readable: \(error)")}
        owner.show()
        guard let list=owner.content.subviews.compactMap({$0 as? LauncherBindingListView}).first,
              let row=list.rows.first(where:{$0.key == "M"}) else {
            check(false,"physical-key list fixture has its real M row");return(count,failures)
        }
        // NSView.visibleRect can still contain its pre-layout value immediately
        // after the launcher is ordered. Establish a real clip viewport and a
        // known document origin, then compare both views in clip coordinates.
        owner.panel.contentView?.layoutSubtreeIfNeeded()
        list.tile();list.layoutSubtreeIfNeeded()
        let clip=list.contentView
        clip.scroll(to:.zero);list.reflectScrolledClipView(clip)
        let initialOrigin=clip.bounds.origin
        let initialFrame=row.convert(row.bounds,to:clip)
        let initiallyOutside=abs(initialOrigin.y) < 0.5 && !clip.bounds.isEmpty && clip.bounds.intersection(initialFrame).isEmpty
        if !initiallyOutside {print("DIAG launcher list before route: row=\(initialFrame), clip=\(clip.bounds), document=\(list.documentView?.frame ?? .zero)")}
        check(initiallyOutside,"last physical-key row begins outside the native list viewport")
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:owner.panel.windowNumber,context:nil,characters:"m",charactersIgnoringModifiers:"m",isARepeat:false,keyCode:46)!
        check(owner.route(event) && owner.editorPanel?.isVisible == true && owner.editor == nil,
              "unbound physical key opens the real type chooser in list mode")
        let revealedFrame=row.convert(row.bounds,to:clip)
        let intersection=clip.bounds.intersection(revealedFrame)
        let fullyRevealed=intersection.width >= revealedFrame.width-0.5 && intersection.height >= revealedFrame.height-0.5
        if !fullyRevealed {print("DIAG launcher list after route: row=\(revealedFrame), clip=\(clip.bounds), document=\(list.documentView?.frame ?? .zero), initialOrigin=\(initialOrigin)")}
        check(fullyRevealed && clip.bounds.origin.y > initialOrigin.y && owner.bindingPresentationAnchor(for:"M") === row,
              "keyboard chooser scrolls to and anchors to its matching real list row")
        let surface=owner.editorPanel?.contentView as? BindingPopoverSurface
        let choices=Set(surface?.card.subviews.compactMap{($0 as? NSButton)?.accessibilityLabel()} ?? [])
        let expectedChoices=Set([TargetKind.app,.file,.folder,.web,.shortcut,.shell].map{"绑定"+$0.title})
        check(choices == expectedChoices,
              "list keyboard chooser exposes the six supported user-binding target types")
        owner.closeOverlay(render:false)
        owner.configuration.settings.hideUnboundKeys=true;owner.render()
        check(owner.bindingPresentationAnchor(for:"M") == nil && owner.route(event) && owner.editorPanel?.isVisible == true,
              "hidden unbound physical keys remain configurable using the content anchor")
        owner.closeOverlay(render:false)
        let interactions=checkWorkbenchInteraction(owner:owner,directory:directory)
        count += interactions.count;failures += interactions.failures
        return(count,failures)
    }
    /// Posts only to this app's local queue and dispatches to an owned probe view.
    /// No system pointer, CGEvent, real picker, account source or launcher target is used.
    private static func checkWorkbenchInteraction(owner:LauncherController,directory:URL)->(count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ message:String){count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") local workbench click: \(message)")}
        let previousPolicy=NSApp.activationPolicy(),originalConfiguration=owner.configuration
        let previousFocusDeadline=owner.focusTransitionUntil
        // Isolate unrelated real-desktop activation callbacks. The production
        // local click monitor below does not consult this transition deadline.
        owner.focusTransitionUntil = .distantFuture
        let calendarSystem=LauncherInteractionCalendar(),calendarNotifications=LauncherInteractionNotifications()
        let calendar=CalendarModel(dataDirectory:directory.appendingPathComponent("InteractionCalendar"),system:calendarSystem,notifier:calendarNotifications)
        let ai=AIUsageModel(dataDirectory:directory.appendingPathComponent("InteractionAI"),startServices:false)
        let model=WorkbenchAppModel(owner:owner,calendar:calendar,ai:ai,startServices:false)
        let workbench=WorkbenchWindowController(owner:owner,model:model,autosavesFrame:false)
        owner.workbenchController=workbench
        let probe=LauncherInteractionClickProbe(frame:NSRect(x:300,y:100,width:24,height:24))
        defer {
            if let monitor=owner.eventMonitor {NSEvent.removeMonitor(monitor);owner.eventMonitor=nil}
            owner.localEventMonitorDidReceive=nil;owner.focusTransitionUntil=previousFocusDeadline
            owner.pickerActive=false;owner.menu=nil;owner.launchPending=false;owner.draft=nil
            owner.closeOverlay(render:false);owner.panel.orderOut(nil)
            probe.removeFromSuperview();model.shutdown()
            workbench.window?.orderOut(nil);workbench.window?.delegate=nil;workbench.window?.contentView=nil;workbench.window?.close()
            owner.workbenchController=nil;NSApp.setActivationPolicy(previousPolicy)
        }
        guard let window=workbench.window,let content=window.contentView else {
            check(false,"fixture owns the canonical native workbench window");return(count,failures)
        }
        workbench.present()
        let deadline=Date().addingTimeInterval(0.6)
        while window.alphaValue < 0.999 && Date() < deadline {_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        // NSHostingView owns its SwiftUI hit-test graph; an arbitrary native
        // subview added inside it is not a reliable independent event target.
        // Keep the real workbench surface mounted, with the owned probe as a
        // separate native sibling in the same canonical NSWindow.
        let container=NSView(frame:content.frame)
        window.contentView=container
        content.frame=container.bounds;content.autoresizingMask=[.width,.height]
        container.addSubview(content);container.addSubview(probe,positioned:.above,relativeTo:content)
        container.layoutSubtreeIfNeeded()
        var monitored:[Int]=[]
        owner.localEventMonitorDidReceive={event in if event.type == .leftMouseDown,event.window === window {monitored.append(event.eventNumber)}}
        owner.installLocalEventMonitor()
        owner.installLocalEventMonitor() // Reinstallation must replace, not stack, the handler.
        // AppKit's local queue preserves only the 16-bit mouse-event serial.
        // Keep this fixture's own sequence in that range so strict identity
        // checks compare the posted serial with the actual dequeued serial.
        var eventNumber=0x4600
        func click(_ phase:String)->Bool {
            let previous=probe.mouseDownCount,previousMonitored=monitored.count
            eventNumber += 1
            let point=probe.convert(NSPoint(x:12,y:12),to:nil)
            let hit=container.hitTest(container.convert(point,from:nil))
            guard let event=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:eventNumber,clickCount:1,pressure:1) else {print("DIAG local click \(phase): event creation failed");return false}
            NSApp.postEvent(event,atStart:true)
            guard let delivered=NSApp.nextEvent(matching:.leftMouseDown,until:Date().addingTimeInterval(0.2),inMode:.default,dequeue:true) else {print("DIAG local click \(phase): no queued event; posted=\(eventNumber), window=\(window.windowNumber)");return false}
            guard delivered.eventNumber == eventNumber,delivered.window === window else {print("DIAG local click \(phase): unexpected queue event; posted=\(eventNumber), received=\(delivered.eventNumber), expectedWindow=\(window.windowNumber), receivedWindow=\(delivered.windowNumber)");NSApp.postEvent(delivered,atStart:true);return false}
            NSApp.sendEvent(delivered)
            let monitorDelta=monitored.count-previousMonitored,probeDelta=probe.mouseDownCount-previous
            let passed=hit === probe && monitorDelta == 1 && monitored.last == eventNumber && probeDelta == 1
            print("DIAG local click \(phase): hit=\(hit.map{String(describing:type(of:$0))} ?? "nil"), monitorDelta=\(monitorDelta), probeDelta=\(probeDelta), event=\(eventNumber), launcher=\(owner.panel.isVisible), editor=\(owner.editorPanel != nil), dirty=\(owner.hasUnsavedLauncherChanges), picker=\(owner.pickerActive), menu=\(owner.menu != nil), pending=\(owner.launchPending), marked=\(owner.hasMarkedInput), canonical=\(workbench.presentationWindow === window), key=\(window.isKeyWindow), active=\(NSApp.isActive)")
            return passed
        }
        owner.show()
        let plainDelivered=click("plain")
        check(plainDelivered && !owner.panel.isVisible && window.isVisible && owner.workbenchController === workbench,
              "the production local monitor hides the launcher and delivers the original click once to the workbench")
        var draft=BindingEditor(owner.configuration.bindings)
        draft.set(.init(target:.init(kind:.web,name:"Unsaved local fixture",location:"https://example.invalid")),at:"M")
        owner.draft=draft;owner.show()
        let dirtyDelivered=click("dirty")
        check(dirtyDelivered && owner.panel.isVisible && owner.draft?.bindings == draft.bindings && owner.draft?.history == draft.history && owner.hasUnsavedLauncherChanges,
              "dirty launcher edits stay visible and unchanged while the workbench still receives its click")
        owner.draft=nil
        let form=BindingForm(owner:owner,key:"M",kind:.web,preselected:nil)
        owner.editor=form;owner.presentBindingCard(form,anchor:owner.content)
        form.aliasField.stringValue="未保存的网页名称"
        let editorPanel=owner.editorPanel,editorDelivered=click("editor")
        check(editorDelivered && owner.panel.isVisible && owner.editor === form && owner.editorPanel === editorPanel && editorPanel?.isVisible == true && form.hasChanges && form.aliasField.stringValue == "未保存的网页名称",
              "an active binding editor and its unsaved text survive the same workbench interaction")
        owner.closeOverlay(render:false)
        owner.pickerActive=true
        let pickerDelivered=click("picker")
        check(pickerDelivered && owner.panel.isVisible && owner.pickerActive,
              "an active picker session blocks launcher auto-dismissal without swallowing the workbench click")
        owner.pickerActive=false
        let menu=NSMenu(title:"Isolated menu guard");owner.menu=menu
        let menuDelivered=click("menu")
        check(menuDelivered && owner.panel.isVisible && owner.menu === menu,
              "a protected launcher menu remains intact while local click delivery continues")
        owner.menu=nil;owner.launchPending=true
        let launchDelivered=click("pending")
        check(launchDelivered && owner.panel.isVisible && owner.launchPending,
              "a pending launcher operation is not cancelled by clicking the workbench")
        owner.launchPending=false
        let finalDelivered=click("unguarded")
        check(finalDelivered && !owner.panel.isVisible && owner.configuration == originalConfiguration && !model.device.isSampling && calendarSystem.requests == 0 && calendarSystem.reads == 0 && calendarNotifications.requests == 0,
              "removing guards restores dismissal without saving drafts, launching targets, sampling hardware or accessing accounts")
        return(count,failures)
    }
}

@MainActor private final class LauncherInteractionClickProbe:NSView {
    var mouseDownCount=0
    override var mouseDownCanMoveWindow:Bool {false}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func mouseDown(with event:NSEvent) {mouseDownCount += 1}
}
@MainActor private final class LauncherInteractionCalendar:CalendarSystemProviding {
    var requests=0,reads=0
    func access(reminders:Bool)->CalendarAccess {.denied}
    func requestAccess(reminders:Bool) async throws->Bool {requests += 1;return false}
    func events(in interval:DateInterval) throws->[CalendarEventItem] {reads += 1;return []}
    func reminders() async throws->[ReminderItem] {reads += 1;return []}
    func writableReminderCalendars()->[ReminderCalendar] {[]}
    func saveReminder(_ item:ReminderItem,creating:Bool) throws->ReminderItem {throw ReminderError.unavailable("Isolated local event fixture")}
    func deleteReminder(_ item:ReminderItem) throws {throw ReminderError.unavailable("Isolated local event fixture")}
}
@MainActor private final class LauncherInteractionNotifications:ReminderNotificationProviding {
    var requests=0
    func access() async->CalendarAccess {.denied}
    func requestAccess() async throws->Bool {requests += 1;return false}
    func replacePending(_ values:[ReminderNotification]) async throws {}
}
