import AppKit
import CoreGraphics
import LauncherCore

/// Foreground checks exercise the production menu actions and WindowServer focus.
/// Stores and service providers are isolated; no real app targets are launched.
@MainActor enum WorkbenchWindowMenuChecks {
    static func run() async -> (count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ condition:Bool,_ message:String) {
            count += 1;if !condition {failures += 1}
            print("\(condition ? "PASS":"FAIL") window/menu: \(message)")
        }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-window-menu-\(UUID().uuidString)")
        let previousPolicy=NSApp.activationPolicy()
        let previousApp=NSWorkspace.shared.frontmostApplication
        let peer=previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? previousApp:
            NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.finder").first
        let owner=LauncherController(dataDirectory:directory.appendingPathComponent("Launcher"))
        owner.configurePanel();owner.scanning=true
        let system=WindowMenuCalendar(),notifications=WindowMenuNotifications()
        let calendar=CalendarModel(dataDirectory:directory.appendingPathComponent("Calendar"),system:system,notifier:notifications)
        let ai=AIUsageModel(dataDirectory:directory.appendingPathComponent("AI"),startServices:false)
        let model=WorkbenchAppModel(owner:owner,calendar:calendar,ai:ai,startServices:false)
        let controller=WorkbenchWindowController(owner:owner,model:model,autosavesFrame:false)
        owner.workbenchController=controller
        let menu=owner.makeStatusMenu()
        defer {
            controller.cancelPendingPresentationActivation()
            owner.closeOverlay(render:false);owner.panel.orderOut(nil);owner.toastTask?.cancel()
            owner.hotKey.unregister();owner.bindingHotKeys.unregister();model.shutdown()
            if let window=controller.window {
                if let sheet=window.attachedSheet {window.endSheet(sheet);sheet.orderOut(nil)}
                window.orderOut(nil);window.delegate=nil;window.contentView=nil;window.close()
            }
            owner.workbenchController=nil
            NSApp.setActivationPolicy(previousPolicy)
            if let previousApp,previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,!previousApp.isTerminated {_=previousApp.activate()}
            try? FileManager.default.removeItem(at:directory)
        }
        guard let window=controller.window,let peer else {
            check(false,"a native workbench and an existing external app are available for foreground verification")
            return(count,failures)
        }
        func activatePeer() async -> Bool {
            _=peer.activate()
            return await wait {NSWorkspace.shared.frontmostApplication?.processIdentifier == peer.processIdentifier && !NSApp.isActive}
        }
        func baseTitle(_ item:NSMenuItem) -> String {
            item.title.components(separatedBy:"\t")[0]
        }
        func invoke(_ title:String) -> Bool {
            guard let item=menu.items.first(where:{baseTitle($0) == title}),let action=item.action else {return false}
            return NSApp.sendAction(action,to:item.target,from:item)
        }
        func foreground() -> Bool {
            NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                && window.isVisible && window.isKeyWindow && NSApp.keyWindow === window
        }
        let expected=["打开工作台","打开启动器","设置","检查更新","退出方寸"]
        check(menu.items.filter{!$0.isSeparatorItem}.map(baseTitle) == expected && menu.items.filter(\.isSeparatorItem).count == 2,
              "the native menu has exactly five actions and two separators without duplicate settings or rescan")
        check(menu.items.prefix(2).allSatisfy{$0.keyEquivalent.isEmpty} && menu.items[0].attributedTitle?.string.contains(owner.configuration.settings.workbenchHotKey!.title) == true,
              "shortcut hints reflect configuration without registering another menu shortcut")
        let initialTitles=menu.items.map(\.title)
        let initialHints=menu.items.map{$0.attributedTitle?.string}
        owner.menuNeedsUpdate(menu);owner.menuNeedsUpdate(menu)
        check(menu.items.map(\.title) == initialTitles && menu.items.map{$0.attributedTitle?.string} == initialHints
              && menu.items.prefix(2).allSatisfy{$0.title.components(separatedBy:"\t").count == 2},
              "repeated menu updates keep exactly one shortcut hint per action")
        owner.configuration.settings.workbenchHotKey=nil
        owner.configuration.settings.launcherHotKey=BindingHotKey(keyCode:46,control:true,option:true)
        owner.menuNeedsUpdate(menu)
        owner.menuNeedsUpdate(menu)
        check(menu.items[0].title == "打开工作台" && menu.items[0].attributedTitle == nil
              && menu.items[1].attributedTitle?.string == "打开启动器\t⌃⌥M",
              "disabled and changed shortcuts are reflected when the menu updates")

        NSApp.setActivationPolicy(.accessory)
        window.orderOut(nil)
        let initiallyExternal=await activatePeer()
        check(initiallyExternal,"the first open starts with another application in the foreground")
        owner.menuWillOpen(menu)
        let firstAction=invoke("打开工作台")
        check(firstAction && !window.isVisible,"the menu action waits until its tracking session ends")
        owner.menuDidClose(menu)
        let firstForeground=await wait {foreground()}
        check(firstForeground && NSApp.activationPolicy() == .regular && window.level == .normal,
              "one first menu action activates and fronts the ordinary workbench at normal window level")
        let identity=ObjectIdentifier(window),frame=window.frame

        let backgrounded=await activatePeer()
        let foregroundPID=NSWorkspace.shared.frontmostApplication?.processIdentifier
        let baselineOrder=workbenchOrder(window,peerPID:peer.processIdentifier)
        owner.menuWillOpen(menu);let launcherAction=invoke("打开启动器");owner.menuDidClose(menu)
        let launcherVisible=await wait {owner.panel.isVisible && owner.panel.isKeyWindow}
        try? await Task.sleep(for:.milliseconds(80))
        let menuOrder=workbenchOrder(window,peerPID:peer.processIdentifier,peerWindowID:baselineOrder.peerID)
        // A nonactivating panel can make AppKit locally active for key input.
        // WindowServer's foreground PID and ordinary-window order determine
        // whether the external application and background workbench stayed put.
        let independentMenuLauncher=backgrounded && launcherAction && launcherVisible && !window.isKeyWindow
            && owner.panel.isVisible && owner.panel.isKeyWindow
            && NSApp.keyWindow === owner.panel && NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID
            && baselineOrder.behind && menuOrder.behind
        if !independentMenuLauncher {
            print("DETAIL menu launcher backgrounded=\(backgrounded) action=\(launcherAction) waitReady=\(launcherVisible) panelVisible=\(owner.panel.isVisible) panelKey=\(owner.panel.isKeyWindow) appActive=\(NSApp.isActive) workbenchKey=\(window.isKeyWindow) appKeyIsPanel=\(NSApp.keyWindow === owner.panel) frontPID=\(String(describing:NSWorkspace.shared.frontmostApplication?.processIdentifier)) beforePID=\(String(describing:foregroundPID)) ownPID=\(ProcessInfo.processInfo.processIdentifier) nonactivating=\(owner.panel.styleMask.contains(.nonactivatingPanel)) canBecomeKey=\(owner.panel.canBecomeKey)")
            print("DETAIL menu launcher order before=\(baselineOrder.detail) after=\(menuOrder.detail)")
        }
        check(independentMenuLauncher,
              "menu launcher takes panel input while the external app remains foreground and its ordinary window stays above the workbench")
        owner.hide(restore:false)
        owner.show()
        let hotkeyVisible=await wait {owner.panel.isVisible && owner.panel.isKeyWindow}
        try? await Task.sleep(for:.milliseconds(80))
        let hotkeyOrder=workbenchOrder(window,peerPID:peer.processIdentifier,peerWindowID:baselineOrder.peerID)
        let independentHotkeyLauncher=hotkeyVisible && !window.isKeyWindow && NSApp.keyWindow === owner.panel
            && owner.panel.isVisible && owner.panel.isKeyWindow
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID
            && baselineOrder.behind && hotkeyOrder.behind
        if !independentHotkeyLauncher {
            print("DETAIL hotkey launcher waitReady=\(hotkeyVisible) panelVisible=\(owner.panel.isVisible) panelKey=\(owner.panel.isKeyWindow) appActive=\(NSApp.isActive) workbenchKey=\(window.isKeyWindow) appKeyIsPanel=\(NSApp.keyWindow === owner.panel) frontPID=\(String(describing:NSWorkspace.shared.frontmostApplication?.processIdentifier)) beforePID=\(String(describing:foregroundPID)) ownPID=\(ProcessInfo.processInfo.processIdentifier) nonactivating=\(owner.panel.styleMask.contains(.nonactivatingPanel)) canBecomeKey=\(owner.panel.canBecomeKey)")
            print("DETAIL hotkey launcher order before=\(baselineOrder.detail) after=\(hotkeyOrder.detail)")
        }
        check(independentHotkeyLauncher,
              "the shared hotkey launcher path has the same independent activation behavior")
        owner.hide(restore:false)

        owner.menuWillOpen(menu);let settingsAction=invoke("设置");owner.menuDidClose(menu)
        let settingsForeground=await wait {foreground() && model.route == .settings && model.settingsTab == .general}
        check(settingsAction && settingsForeground && !owner.panel.isVisible && controller.window.map(ObjectIdentifier.init) == identity && window.frame == frame,
              "settings opens directly in the same foreground workbench without flashing the launcher")

        controller.requestMinimize()
        let minimized=await wait {window.isMiniaturized}
        owner.menuWillOpen(menu);_=invoke("打开工作台");owner.menuDidClose(menu)
        let restored=await wait {foreground() && !window.isMiniaturized}
        check(minimized && restored && controller.window.map(ObjectIdentifier.init) == identity,
              "one menu action restores the same minimized workbench and keyboard focus")

        model.closeWindow?()
        let closed=await wait {!window.isVisible}
        let externalAgain=await activatePeer()
        controller.present()
        model.closeWindow?()
        _=await wait {!window.isVisible}
        try? await Task.sleep(for:.milliseconds(180))
        check(closed && externalAgain && !window.isVisible && !NSApp.isActive,
              "closing before the queued activation completes cancels it without reviving or activating the app")
        owner.menuWillOpen(menu);_=invoke("打开工作台");owner.menuDidClose(menu)
        _=await wait {foreground()}
        let sheet=NSWindow(contentRect:NSRect(x:0,y:0,width:300,height:120),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false
        let text=NSTextField(string:"Unsaved fixture")
        text.frame=NSRect(x:20,y:45,width:260,height:24);sheet.contentView?.addSubview(text)
        window.beginSheet(sheet,completionHandler:nil)
        _=await activatePeer()
        owner.menuWillOpen(menu);_=invoke("打开工作台");owner.menuDidClose(menu)
        let sheetRestored=await wait {NSApp.isActive && sheet.isVisible && sheet.isKeyWindow}
        check(sheetRestored && window.attachedSheet === sheet && text.stringValue == "Unsaved fixture",
              "foreground restoration preserves the native sheet and returns keyboard focus to its unsaved form")
        window.endSheet(sheet);sheet.orderOut(nil);sheet.close()
        check(!model.device.isSampling && system.requests == 0 && system.reads == 0 && notifications.requests == 0,
              "window verification leaves real calendar access, reminders and hardware sampling untouched")
        return(count,failures)
    }
    /// Read only numeric WindowServer identity/order metadata. Titles and image
    /// content are neither inspected nor included in diagnostic output.
    private static func workbenchOrder(_ window:NSWindow,peerPID:Int32,peerWindowID:Int?=nil) -> (behind:Bool,peerID:Int?,detail:String) {
        let raw=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let windows=raw.compactMap { item -> (id:Int,pid:Int,layer:Int)? in
            guard let id=item[kCGWindowNumber as String] as? NSNumber,
                  let pid=item[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer=item[kCGWindowLayer as String] as? NSNumber else {return nil}
            return(id.intValue,pid.intValue,layer.intValue)
        }
        let own=windows.enumerated().first {$0.element.id == window.windowNumber && $0.element.pid == Int(ProcessInfo.processInfo.processIdentifier)}
        let peer=windows.enumerated().first {$0.element.pid == Int(peerPID) && $0.element.layer == 0 && (peerWindowID == nil || $0.element.id == peerWindowID)}
        let behind=own.flatMap { own in peer.map { peer in own.element.layer == 0 && own.offset > peer.offset } } ?? false
        let detail="workbenchID=\(window.windowNumber),index=\(String(describing:own?.offset)),layer=\(String(describing:own?.element.layer));peerPID=\(peerPID),ID=\(String(describing:peer?.element.id)),index=\(String(describing:peer?.offset)),layer=\(String(describing:peer?.element.layer))"
        return(behind,peer?.element.id,detail)
    }
    private static func wait(_ condition:()->Bool) async ->Bool {
        let deadline=ContinuousClock.now.advanced(by:.seconds(2))
        repeat {
            if condition() {return true}
            try? await Task.sleep(for:.milliseconds(20))
        } while ContinuousClock.now < deadline
        return condition()
    }
}

@MainActor private final class WindowMenuCalendar:CalendarSystemProviding {
    var requests=0,reads=0
    func access(reminders:Bool)->CalendarAccess {.denied}
    func requestAccess(reminders:Bool) async throws->Bool {requests += 1;return false}
    func events(in interval:DateInterval) throws->[CalendarEventItem] {reads += 1;return []}
    func reminders() async throws->[ReminderItem] {reads += 1;return []}
    func writableReminderCalendars()->[ReminderCalendar] {[]}
    func saveReminder(_ item:ReminderItem,creating:Bool) throws->ReminderItem {throw ReminderError.unavailable("Isolated window check")}
    func deleteReminder(_ item:ReminderItem) throws {throw ReminderError.unavailable("Isolated window check")}
}
@MainActor private final class WindowMenuNotifications:ReminderNotificationProviding {
    var requests=0
    func access() async->CalendarAccess {.denied}
    func requestAccess() async throws->Bool {requests += 1;return false}
    func replacePending(_ values:[ReminderNotification]) async throws {}
}
