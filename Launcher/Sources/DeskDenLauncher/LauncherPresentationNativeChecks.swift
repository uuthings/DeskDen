import AppKit
import LauncherCore

/// Exercises physical-key routing against the real list viewport and popover.
@MainActor enum LauncherPresentationNativeChecks {
    static func run() async ->(count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ message:String){count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") \(message)")}
        let indexChecks=checkSearchIndexPersistence()
        count += indexChecks.count;failures += indexChecks.failures
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-launcher-presentation-\(UUID().uuidString)")
        let owner=LauncherController(dataDirectory:directory)
        owner.configurePanel();owner.scanning=true
        owner.configuration.bindings=[:]
        owner.configuration.settings.display = .list
        owner.configuration.settings.defaultView = .keys
        defer {owner.closeOverlay(render:false);owner.panel.orderOut(nil);owner.toastTask?.cancel();owner.hotKey.unregister();owner.bindingHotKeys.unregister();try? FileManager.default.removeItem(at:directory)}
        let hoverChecks=await checkHoverFeedback(owner:owner)
        count += hoverChecks.count;failures += hoverChecks.failures
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
            let deskDen=directory.appendingPathComponent("DeskDen.app")
            let deskDenContents=deskDen.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at:deskDenContents,withIntermediateDirectories:true)
            let deskDenMetadata=["CFBundleIdentifier":ApplicationNames.deskDenIdentifier,"CFBundleName":"DeskDen","CFBundleDisplayName":"DeskDen","CFBundlePackageType":"APPL"]
            try PropertyListSerialization.data(fromPropertyList:deskDenMetadata,format:.xml,options:0).write(to:deskDenContents.appendingPathComponent("Info.plist"))
            let renamed=LaunchTarget(kind:.app,name:ApplicationNames.name(for:deskDen),location:deskDen.path)
            owner.configuration.bindings["B"]=KeyBinding(target:renamed)
            owner.rebuildIndex()
            check(renamed.name == "DeskDen" && ["DeskDen","方寸"].allSatisfy {query in
                SearchEngine.search(owner.searchIndex,query:query).contains {$0.target.id == renamed.id}
            },"the launcher finds DeskDen by its current and former names")
            owner.configuration.bindings=[:];owner.rebuildIndex()
        } catch {check(false,"bound English metadata fixture is readable: \(error)")}
        owner.show()
        check(owner.panel.isVisible && owner.workbenchController == nil && owner.panel.firstResponder === owner.content,
              "showing the independent launcher takes keyboard focus without creating the workbench")
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
    /// Saves only isolated fixture data. No catalog scan, shown window, global
    /// shortcut, real application launch or account service is needed.
    static func checkSearchIndexPersistence()->(count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ message:String){count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") launcher index save: \(message)")}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-launcher-index-\(UUID().uuidString)")
        let owner=LauncherController(dataDirectory:directory)
        owner.configuration.settings.workbenchHotKey=nil
        owner.configurePanel();owner.scanning=true
        defer {owner.panel.orderOut(nil);owner.toastTask?.cancel();owner.hotKey.unregister();owner.bindingHotKeys.unregister();try? FileManager.default.removeItem(at:directory)}
        let alpha=LaunchTarget(kind:.app,name:"Alpha",location:directory.appendingPathComponent("Alpha.app").path)
        let beta=LaunchTarget(kind:.app,name:"Beta",location:directory.appendingPathComponent("Beta.app").path)
        let zulu=LaunchTarget(kind:.app,name:"Zulu",location:directory.appendingPathComponent("Zulu.app").path)
        let bound=LaunchTarget(kind:.web,name:"Bound fixture",location:"https://example.invalid/original")
        owner.applications=[zulu,alpha]
        owner.configuration.bindings["A"]=KeyBinding(target:bound,alias:"Original alias")
        do {
            try owner.store.save(owner.configuration)
            owner.rebuildIndex()
            // A result-only sentinel detects a rebuild without adding production
            // counters or relying on timing. It must survive a visual-only save.
            let sentinel=SearchEntry(target:LaunchTarget(kind:.web,name:"Cached index sentinel",location:"https://example.invalid/index-sentinel"))
            owner.appIndex.append(sentinel);owner.searchIndex.append(sentinel)
            let applicationIDs=owner.appIndex.map(\.id),searchTitles=owner.searchIndex.map(\.title)
            let savedAppearance=owner.updateSettings{$0.workbenchAppearance = .light;$0.lightAppearance=true}
            let persistedAppearance=try owner.store.load()?.settings.workbenchAppearance
            check(savedAppearance && owner.appIndex.map(\.id) == applicationIDs && owner.searchIndex.map(\.title) == searchTitles
                  && persistedAppearance == .light,
                  "theme-only saves persist the choice while retaining both existing indexes")
            let childViews=owner.content.subviews
            owner.refreshLauncherAppearance()
            check(!owner.panel.isVisible && owner.content.subviews.elementsEqual(childViews,by:{$0 === $1}),
                  "refreshing a hidden launcher's appearance preserves its view tree")
            owner.rebuildIndex()

            var candidate=owner.configuration
            candidate.bindings["A"]?.alias="Renamed bookmark"
            let renamed=owner.save(candidate)
            check(renamed && owner.searchIndex.contains{$0.key == "A" && $0.title == "Renamed bookmark"}
                  && SearchEngine.search(owner.searchIndex,query:"Renamed bookmark").contains{$0.id == bound.id},
                  "changing a binding alias refreshes its displayed and searchable name")
            let replacement=LaunchTarget(kind:.web,name:"Replacement target",location:"https://example.invalid/replacement")
            candidate=owner.configuration;candidate.bindings["A"]=KeyBinding(target:replacement)
            let replaced=owner.save(candidate)
            check(replaced && owner.searchIndex.contains{$0.id == replacement.id} && !owner.searchIndex.contains{$0.id == bound.id},
                  "changing a bound target removes the old search destination")

            candidate=owner.configuration;candidate.addedApplications=[beta]
            let added=owner.save(candidate)
            check(added && owner.appIndex.map(\.id) == [alpha.id,beta.id,zulu.id] && owner.searchIndex.contains{$0.id == beta.id},
                  "adding an application updates both application and query results")
            candidate=owner.configuration;candidate.hiddenApplications=[alpha.id]
            let hidden=owner.save(candidate)
            check(hidden && !owner.appIndex.contains{$0.id == alpha.id} && !owner.searchIndex.contains{$0.id == alpha.id},
                  "hiding an application removes it from both indexes")
            candidate=owner.configuration;candidate.hiddenApplications=[]
            let restored=owner.save(candidate)
            check(restored && owner.appIndex.first?.id == alpha.id && owner.searchIndex.contains{$0.id == alpha.id},
                  "restoring a hidden application restores its search entry")
            candidate=owner.configuration;candidate.starredApplications=[zulu.id]
            let starred=owner.save(candidate)
            check(starred && owner.appIndex.first?.id == zulu.id && owner.searchIndex.first?.id == zulu.id,
                  "starring an application updates ordering in both indexes")
            candidate=owner.configuration;candidate.starredApplications=[]
            let unstarred=owner.save(candidate)
            check(unstarred && owner.appIndex.first?.id == alpha.id,
                  "removing a star restores the selected name ordering")
            let sorted=owner.updateSettings{$0.appSort = .nameDescending}
            check(sorted && owner.appIndex.map(\.id) == [zulu.id,beta.id,alpha.id],
                  "changing the sorting preference immediately reorders applications")
            _=owner.updateSettings{$0.appSort = .custom}
            candidate=owner.configuration;candidate.applicationOrder=[beta.id,alpha.id,zulu.id]
            let reordered=owner.save(candidate)
            check(reordered && owner.appIndex.map(\.id) == [beta.id,alpha.id,zulu.id],
                  "changing only the custom order refreshes the application ranking")
            candidate=owner.configuration;candidate.settings.appSort = .usedNewest
            for (index,target) in [alpha,beta,zulu].enumerated() {
                candidate.applicationMetadata[target.id]=ApplicationMetadata(addedAt:Date(timeIntervalSince1970:0),lastUsedAt:Date(timeIntervalSince1970:Double(index+1)))
            }
            let metadataSetup=owner.save(candidate)
            candidate=owner.configuration;candidate.applicationMetadata[alpha.id]?.lastUsedAt=Date(timeIntervalSince1970:4)
            let metadataChanged=owner.save(candidate)
            check(metadataSetup && metadataChanged && owner.appIndex.first?.id == alpha.id && owner.searchIndex.first?.id == alpha.id,
                  "changing only usage metadata refreshes the selected recency order")
        } catch {check(false,"isolated configuration storage is available: \(error)")}
        return(count,failures)
    }
    private static func checkHoverFeedback(owner:LauncherController) async ->(count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ message:String){count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") launcher hover: \(message)")}
        let target=LaunchTarget(kind:.web,name:"Hover fixture",location:"https://example.invalid")
        let tile=KeyTile(key:"A",mode:.full,binding:KeyBinding(target:target),editing:false,frame:NSRect(x:80,y:80,width:80,height:98))
        owner.content.addSubview(tile)
        defer {tile.removeFromSuperview()}
        let originalFrame=tile.frame,originalBounds=tile.bounds
        let nameRect=NSRect(x:0,y:78,width:80,height:20)
        func pixels(_ rect:NSRect)->Data? {
            guard let bitmap=tile.bitmapImageRepForCachingDisplay(in:rect) else {return nil}
            tile.cacheDisplay(in:rect,to:bitmap)
            return bitmap.representation(using:.png,properties:[:])
        }
        func settle(until predicate:()->Bool) async -> Bool {
            // The production animation runs in a MainActor task. A synchronous
            // nested RunLoop keeps this actor job occupied, so it cannot drive
            // the animation; suspend the check instead of blocking its executor.
            let deadline=ContinuousClock.now.advanced(by:.seconds(1))
            repeat {
                try? await Task.sleep(for:.milliseconds(20))
                if predicate() {return true}
            } while ContinuousClock.now < deadline
            return predicate()
        }
        let entered=NSEvent.enterExitEvent(with:.mouseEntered,location:.zero,modifierFlags:[],timestamp:0,windowNumber:owner.panel.windowNumber,context:nil,eventNumber:1,trackingNumber:0,userData:nil)!
        let exited=NSEvent.enterExitEvent(with:.mouseExited,location:.zero,modifierFlags:[],timestamp:0,windowNumber:owner.panel.windowNumber,context:nil,eventNumber:2,trackingNumber:0,userData:nil)!
        let resting=pixels(tile.bounds),restingName=pixels(nameRect)
        tile.mouseEntered(with:entered)
        let expectedProgress:CGFloat=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0:1
        let animationSettled=await settle {tile.hoverProgress == expectedProgress}
        let raised=pixels(tile.bounds),raisedName=pixels(nameRect)
        let hit=tile.hitTest(NSPoint(x:120,y:120))
        print("DIAG launcher hover settled=\(animationSettled) progress=\(tile.hoverProgress) expected=\(expectedProgress) restingBytes=\(resting?.count ?? -1) raisedBytes=\(raised?.count ?? -1) faceChanged=\(resting != raised) nameStable=\(restingName != nil && restingName == raisedName) frameStable=\(tile.frame == originalFrame) boundsStable=\(tile.bounds == originalBounds) hit=\(hit.map{String(describing:type(of:$0))} ?? "nil") visible=\(owner.panel.isVisible)")
        check(animationSettled && resting != nil && raised != nil && resting != raised && restingName != nil && restingName == raisedName && tile.frame == originalFrame && tile.bounds == originalBounds && hit === tile,
              "hover changes the key face while the name pixels, layout and hit area remain stable")
        tile.mouseExited(with:exited);tile.mouseEntered(with:entered);tile.mouseExited(with:exited)
        let restored=await settle {tile.hoverProgress == 0}
        check(restored && !tile.hovered && pixels(tile.bounds) == resting,
              "rapid enter/exit returns to the original appearance without leaving a stale lift")
        tile.reduceMotion=true;tile.mouseEntered(with:entered)
        _=await settle {tile.hoverProgress == 0}
        check(tile.hovered && tile.hoverProgress == 0 && tile.frame == originalFrame && pixels(nameRect) == restingName,
              "reduced motion retains static hover feedback without moving the key or name")
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
        window.orderOut(nil);owner.show()
        check(owner.panel.isVisible && !window.isVisible && !window.isKeyWindow,
              "opening the launcher leaves an existing closed workbench closed")
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
