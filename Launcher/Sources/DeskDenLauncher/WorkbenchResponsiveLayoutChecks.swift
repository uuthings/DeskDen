import AppKit
import LauncherCore

/// Called only with the existing isolated, service-disabled workbench fixture.
/// Measures mounted production views, including resize transitions, rather than
/// checking constants from the implementation. No pointer events are injected.
@MainActor
enum WorkbenchResponsiveLayoutChecks {
    /// Explicit foreground-only entry: mounts the production window with no
    /// real calendar, AI session paths, network services or shortcut setup.
    /// It runs only the persistent Home sequence, never the broad route suite.
    static func runHomeResizeFixture(fluidHome:Bool = false) async -> (count:Int,failures:Int) {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-home-resize-\(UUID().uuidString)")
        let priorApplication=NSWorkspace.shared.frontmostApplication
        let priorPolicy=NSApp.activationPolicy()
        let oldPalette=(Palette.workbenchTheme,Palette.isLight,Palette.glassOpacity)
        defer {
            Palette.workbenchTheme=oldPalette.0;Palette.isLight=oldPalette.1;Palette.glassOpacity=oldPalette.2
            NSApp.setActivationPolicy(priorPolicy)
            if priorApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {priorApplication?.activate(options:[])}
            try? FileManager.default.removeItem(at:directory)
        }
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let owner=LauncherController(dataDirectory:directory.appendingPathComponent("Launcher"))
            owner.scanning=true
            owner.configuration.settings.workbenchHotKey=nil;owner.configuration.settings.applicationViewHotKey=nil
            owner.configuration.settings.launcherHotKey=nil;owner.configuration.settings.directLaunchPrefix=nil
            owner.configuration.bindingHotKeys=[:]
            owner.configuration.settings.backgroundMotionEnabled=false;owner.configuration.settings.reduceMotion=true
            try owner.store.save(owner.configuration)
            let aiDirectory=directory.appendingPathComponent("AI"),sourcesDirectory=aiDirectory.appendingPathComponent("AIUsage")
            try FileManager.default.createDirectory(at:sourcesDirectory,withIntermediateDirectories:true)
            let sources=AIProvider.allCases.map {provider in
                AIUsageSourceConfiguration(provider:provider,enabled:false,sessionsPath:directory.appendingPathComponent("disabled-"+provider.rawValue).path,quotaPath:nil,manualSnapshot:nil)
            }
            try JSONEncoder().encode(sources).write(to:sourcesDirectory.appendingPathComponent("sources.json"))
            let system=HomeResizeCalendar(),notifications=HomeResizeNotifications()
            let calendarDirectory=directory.appendingPathComponent("Calendar")
            if fluidHome {try WorkbenchFluidHomeChecks.seedReminders(in:calendarDirectory)}
            let calendar=CalendarModel(dataDirectory:calendarDirectory,system:system,notifier:notifications)
            let ai=AIUsageModel(dataDirectory:aiDirectory,startServices:false,notifications:HomeResizeAINotifications(),claudeSettingsDirectory:directory.appendingPathComponent("DisabledClaude"))
            let model=WorkbenchAppModel(owner:owner,calendar:calendar,ai:ai,startServices:false)
            let controller=WorkbenchWindowController(owner:owner,model:model,autosavesFrame:false)
            owner.workbenchController=controller
            defer {
                model.modals.clear();model.shutdown()
                controller.window?.orderOut(nil);controller.window?.delegate=nil
                controller.window?.contentView=nil;controller.window?.close()
                owner.workbenchController=nil
                owner.hotKey.unregister();owner.bindingHotKeys.unregister();owner.toastTask?.cancel()
            }
            guard let window=controller.window,let host=window.contentView else {
                print("FAIL isolated Home resize fixture creates its production native window")
                return (1,1)
            }
            controller.present(route:.overview)
            let ready=await NativeUIFixtureWindow.prepare(window:window) {
                frame("home-device-detail",in:host) != nil && frame("home-open-cleaning",in:host) != nil && frame("home-network-detail",in:host) != nil
            }
            guard ready else {
                print("FAIL isolated Home resize fixture becomes foreground with its actual accessibility tree")
                return (1,1)
            }
            let result: (count:Int,failures:Int)
            if fluidHome {result=await WorkbenchFluidHomeChecks.run(model:model,window:window,host:host)}
            else {result=await checkPersistentHomeResizing(model:model,window:window,host:host)}
            let isolated = !model.device.isSampling && !ai.isRefreshing && model.providerUsage.refreshing.isEmpty && model.apiBalance.refreshing.isEmpty
                && system.permissionRequests == 0 && system.writes == 0 && notifications.permissionRequests == 0
            print("\(isolated ? "PASS":"FAIL") isolated Home resize fixture keeps sampling, real sources and permission requests disabled")
            return (result.count+1,result.failures+(isolated ? 0:1))
        } catch {
            print("FAIL isolated Home resize fixture: \(error.localizedDescription)")
            return (1,1)
        }
    }

    static func run(model: WorkbenchAppModel, window: NSWindow) async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        guard let host = window.contentView else {
            check(false, "responsive layout fixture has a mounted workbench")
            return (count, failures)
        }
        guard !model.modals.isPresented, !model.device.isSampling else {
            check(false, "responsive layout fixture is idle with services disabled and no open modal")
            return (count, failures)
        }
        let originalFrame = window.frame, originalRoute = model.route
        let originalAIDestination = model.ai.destination
        defer {
            model.ai.show(originalAIDestination); model.navigate(originalRoute)
            window.setFrame(originalFrame, display: false)
        }
        let persistentHome = await checkPersistentHomeResizing(model:model,window:window,host:host)
        count += persistentHome.count; failures += persistentHome.failures
        // These route checks intentionally remount pages. The separate Home
        // sequence above keeps its state alive throughout every size transition.
        // 现行规范 6.1: the page is the window width less its 1 pt border and
        // 24 pt side margins, at most 1360 pt; 1409–1411 straddle that limit.
        let sizes: [(window: NSSize, page: CGFloat)] = [
            (.init(width: 1120, height: 758), 1070),
            (.init(width: 960, height: 720), 910),
            (.init(width: 1409, height: 900), 1359),
            (.init(width: 1410, height: 900), 1360),
            (.init(width: 1411, height: 900), 1360),
            (.init(width: 1728, height: 993), 1360),
            (.init(width: 1920, height: 1080), 1360),
            (.init(width: 1120, height: 758), 1070),
            (.init(width: 960, height: 720), 910)
        ]
        var calendarWidths: [(page: CGFloat, month: CGFloat, side: CGFloat)] = []
        for sample in sizes {
            let label = "\(Int(sample.window.width))×\(Int(sample.window.height))"
            window.setContentSize(sample.window)
            model.openUsageOverview()
            _ = await wait(window) {
                frame("fc.page.usage", in: host).map { abs($0.width - sample.page) < 2 } == true
            }
            check(frame("fc.page.usage", in: host).map { abs($0.width - sample.page) < 2 } == true,
                  "mounted usage overview follows the shared \(Int(sample.page)) pt content boundary in \(label)")
            for route in WorkbenchRoute.allCases {
                let effectiveRoute:WorkbenchRoute = route == .cards ? .settings : route
                model.navigate(route)
                _ = await wait(window) {
                    frame("workbench-top-navigation", in: host) != nil && frame("workbench-chrome", in: host) != nil
                        && frame(effectiveRoute == .settings ? "settings-navigation-general" : "navigation-" + route.rawValue, in: host) != nil
                        && (effectiveRoute != .settings || model.settingsTab != .general || frame("updates-current-version", in: host) != nil)
                }
                let chrome = frame("workbench-chrome", in: host), strip = frame("workbench-top-navigation", in: host)
                let navigation = frames(prefix: effectiveRoute == .settings ? "settings-navigation-" : "navigation-", in: host)
                let hostScreen = window.convertToScreen(host.convert(host.bounds, to: nil))
                // 现行规范 6.1/6.2: a 58 pt top navigation inside the window's
                // 1 pt border, its content limited to the page's centred width.
                // SwiftUI reports the chrome group as the union of its 32 pt
                // controls, so measure where they sit within that band.
                let bar = CGRect(x: hostScreen.minX + 1, y: hostScreen.maxY - 59, width: hostScreen.width - 2, height: 58)
                check(frame("workbench-sidebar", in: host) == nil
                      && chrome.map { bar.insetBy(dx: -0.5, dy: -0.5).contains($0) && abs($0.midY - bar.midY) < 1
                          && abs($0.width - sample.page) < 2 && abs($0.midX - bar.midX) < 1 } == true
                      && strip.map { abs($0.midY - bar.midY) < 1 && abs($0.midX - bar.midX) < 1 } == true,
                      "\(route.rawValue) keeps the 58 pt top navigation within the centred page width and no sidebar in \(label)")
                let outerViewport = route == .cleaning ? nil : outerPageScrollView(in: host).map { $0.convert($0.bounds, to: host) }
                print("DETAIL responsive shell \(route.rawValue) \(label) hostScreen=\(hostScreen) chromeAX=\(String(describing: chrome)) navigationAX=\(String(describing: strip)) outerViewport=\(String(describing: outerViewport))")
                check(!navigation.isEmpty && navigation.allSatisfy { abs($0.height - 32) < 1 },
                      "\(route.rawValue) keeps 32 pt navigation controls across resize in \(label)")
                check(frame("navigation-cards", in: host) == nil && (effectiveRoute != .settings || frame("settings-navigation-widgets", in: host) != nil),
                      "desktop widgets live only in Settings across resize in \(label)")
                check(frame("navigation-health", in: host) == nil && !containsAccessibilityText("体检中心", in: host),
                      "\(route.rawValue) exposes no obsolete health navigation or page in \(label)")
                let version = "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                check(accessibilityText("window-brand", in: host).contains(version),
                      "\(route.rawValue) keeps the version's lowercase v prefix in the shared brand in \(label)")
                if route == .settings && model.settingsTab == .general {
                    check(accessibilityText("updates-current-version", in: host).contains("方寸 " + version),
                          "software update settings show the same lowercase version prefix in \(label)")
                }
            }

            model.navigate(.overview)
            _ = await wait(window) {
                ["home-open-cleaning","home-device-detail","home-network-detail","fc.home.calendar","fc.home.reminders"].allSatisfy { frame($0,in:host) != nil }
            }
            let homeDevice=frame("home-device-detail",in:host),homeDisk=frame("home-open-cleaning",in:host),homeNetwork=frame("home-network-detail",in:host)
            let homeMonth=frame("fc.home.calendar",in:host),homeReminders=frame("fc.home.reminders",in:host)
            // 现行规范 4.2 and 8: a whole-card action is labelled with where it
            // leads and states its readings in words; the bars inside it are
            // part of that one element rather than separately labelled.
            let deviceText=accessibilityText("home-device-detail",in:host),diskText=accessibilityText("home-open-cleaning",in:host)
            check(diskText.contains("打开空间清理") && diskText.contains("磁盘已用") && diskText.contains("可用")
                  && deviceText.contains("查看设备状态") && deviceText.contains("内存"),
                  "home whole-card actions name their destination and state disk and memory use in words in \(label)")
            // 现行规范 9.1 (H1): both home rows share three equal columns with
            // 12 pt gaps. This Mac sits over the disk card and the month over
            // the reminders, at least 12 pt above the lower row. The grouped
            // month and reminder cards may report their children's union, so
            // they only have to stay inside the third column.
            let homeViewport=window.convertToScreen(host.convert(host.bounds,to:nil))
            let pageLeft=homeViewport.midX-sample.page/2,pageRight=pageLeft+sample.page,column=(sample.page-24)/3
            check(homeDevice.flatMap { top in homeDisk.flatMap { left in homeNetwork.flatMap { middle in homeMonth.flatMap { upper in homeReminders.map { right in
                abs(left.minX-pageLeft)<1 && abs(left.width-column)<1 && abs(middle.width-column)<1
                    && abs(middle.minX-left.maxX-12)<1 && abs(middle.minY-left.minY)<1
                    && right.minX>=middle.maxX+11 && right.maxX<=pageRight+1
                    && abs(top.minX-left.minX)<1 && abs(top.width-column)<1 && top.minY>=left.maxY+11
                    && upper.minX>=middle.maxX+11 && upper.maxX<=pageRight+1 && upper.minY>=right.maxY+11
            } } } } } == true,
                  "home aligns This Mac and the month with the equal three-column disk, network and reminder row in \(label)")
            let networkText=accessibilityText("home-network-detail",in:host)
            check(deviceText.contains("CPU") && deviceText.contains("GPU") && deviceText.contains("内存")
                  && ["正在充电","已连接电源","使用电池","电源读数不可用"].contains { deviceText.contains($0) }
                  && networkText.contains("下载") && networkText.contains("上传"),
                  "home detail cards retain their real thermal, battery and live network labels in \(label)")
            // 现行规范 9.1: the home month lays out its six weeks in 36 pt rows.
            let homeRows=Set(frames(prefix:"fc.home.calendar.day.2",in:host).map { ($0.midY*2).rounded()/2 }).sorted()
            let homeRowPitch=zip(homeRows,homeRows.dropFirst()).map { $1-$0 }
            print("DETAIL home-summary \(label) device=\(String(describing:homeDevice)) month=\(String(describing:homeMonth)) disk=\(String(describing:homeDisk)) network=\(String(describing:homeNetwork)) reminders=\(String(describing:homeReminders)) dateRows=\(homeRows)")

            let day = model.calendar.displayCalendar.dateComponents([.year, .month, .day], from: Date())
            let dayKey = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
            model.calendar.goToToday(); model.calendar.presentationMode = .month
            model.navigate(.calendar)
            _ = await wait(window) {
                guard let month = frame("fc.calendar.monthCard", in: host),
                      let selected = frame("fc.calendar.selectedAgenda", in: host),
                      let upcoming = frame("fc.calendar.upcomingAgenda", in: host),
                      let pending = frame("fc.calendar.pendingReminders", in: host),
                      frame("fc.calendar.day." + dayKey, in: host) != nil else { return false }
                if sample.page < 760 {
                    return [month,selected,upcoming,pending].allSatisfy { abs($0.width-sample.page)<2 }
                        && selected.maxY < month.minY && upcoming.maxY < selected.minY && pending.maxY < upcoming.minY
                }
                guard let side = frame("fc.calendar.sideColumn", in: host) else { return false }
                return abs(month.width + side.width + 12 - sample.page) < 3
                    && abs(month.width/(sample.page-12)-0.45)<0.01
                    && abs(upcoming.maxY-month.maxY)<2 && pending.maxY < upcoming.minY
            }
            let month = frame("fc.calendar.monthCard", in: host), side = frame("fc.calendar.sideColumn", in: host)
            let monthDay = frame("fc.calendar.day." + dayKey, in: host)
            check(homeRows.count == 6 && homeRowPitch.allSatisfy { abs($0 - 36) < 1 } && monthDay.map { month in
                month.height >= 54 && month.height <= 72 && (0.85...1.4).contains(month.width / month.height)
            } == true, "home uses 36 pt date rows while the full calendar retains readable proportions in \(label)")
            let selected=frame("fc.calendar.selectedAgenda",in:host)
            let upcoming=frame("fc.calendar.upcomingAgenda",in:host)
            let pending=frame("fc.calendar.pendingReminders",in:host)
            if sample.page >= 760, let month, let side {
                calendarWidths.append((sample.page, month.width, side.width))
                check(abs(month.width + side.width + 12 - sample.page) < 3 &&
                      abs(month.width/(sample.page-12)-0.45)<0.01 && month.height <= 600,
                      "calendar and agenda retain the accepted 45/55 split and bounded month height in \(label)")
                check(selected.map{abs($0.width-month.width)<2 && abs($0.maxY-month.minY+12)<2 && $0.height>=160} == true,
                      "the selected day's complete agenda stays below its calendar in \(label)")
                check(upcoming.flatMap { recent in pending.map { longTerm in
                    abs(recent.maxY-month.maxY)<2 && abs(recent.width-side.width)<2
                        && abs(longTerm.width-side.width)<2 && abs(longTerm.maxY-recent.minY+12)<2
                        && (203...229).contains(longTerm.height) && abs(longTerm.minY-side.minY)<2
                        && selected.map{abs($0.minY-side.minY)<2} == true
                } } == true, "seven-day arrangements stay above long-term reminders and both columns align in \(label)")
            } else {
                check(month.flatMap { top in selected.flatMap { day in upcoming.flatMap { recent in pending.map { longTerm in
                    [top,day,recent,longTerm].allSatisfy {abs($0.width-sample.page)<2}
                        && abs(day.maxY-top.minY+12)<2 && abs(recent.maxY-day.minY+12)<2
                        && abs(longTerm.maxY-recent.minY+12)<2
                } } } } == true,
                      "compact calendar stacks month, selected day, seven-day arrangements and long-term reminders in order")
            }
            print("DETAIL calendar proportions \(label) month=\(String(describing: month)) side=\(String(describing: side)) monthDay=\(String(describing: monthDay))")

            model.navigate(.network)
            _ = await wait(window) { !frames(prefix: "fc.network.day-label.", in: host).isEmpty }
            let dates = frames(prefix: "fc.network.day-label.", in: host)
            check(!dates.isEmpty && dates.allSatisfy { $0.width > 0 && $0.height <= 16 },
                  "mounted network day labels, including the current day marker, remain a single line in \(label)")
        }
        if let regular = calendarWidths.first(where: { $0.page == 1070 }), let large = calendarWidths.first(where: { $0.page == 1360 }) {
            // The ordinary page is now 1070 pt rather than 864, so the extra
            // width up to 1360 pt is smaller; the agenda still gains more of it.
            let monthGrowth = large.month - regular.month, agendaGrowth = large.side - regular.side
            check(large.month <= 610 && monthGrowth > 0 && agendaGrowth > monthGrowth,
                  "wide workbenches preserve the bounded calendar and allocate the larger share to the agenda")
        } else { check(false, "calendar width verification covers both normal and large windows") }
        let scrolling = await checkFullPageScrolling(model: model, window: window, host: host)
        count += scrolling.count; failures += scrolling.failures
        check(WorkbenchRoute(rawValue: "health") == nil, "the obsolete health route is removed from the navigation model")
        print("Responsive layout checks: \(count - failures)/\(count) passed")
        return (count, failures)
    }

    /// Keep the same Home mounted. Switching routes between sizes would discard
    /// its measured-width state and conceal the wide-row feedback regression.
    /// The fixture is already a foreground native window: zoom and full-screen
    /// below use its actual AppKit controls, rather than assigning a model flag.
    private static func checkPersistentHomeResizing(model:WorkbenchAppModel,window:NSWindow,host:NSView) async -> (count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ name:String) {count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") \(name)")}
        model.navigate(.overview)
        window.setContentSize(.init(width:1120,height:758))
        _ = await wait(window) {frame("fc.page.home",in:host) != nil}
        let calendar=model.context.dateContext.calendar
        func dayID(_ date:Date)->String {
            let parts=calendar.dateComponents([.year,.month,.day],from:date)
            return String(format:"fc.home.calendar.day.%04d-%02d-%02d",parts.year ?? 0,parts.month ?? 0,parts.day ?? 0)
        }
        let today=Date(),selectedDate=calendar.date(byAdding:.day,value:1,to:today) ?? today
        let selectedID=dayID(selectedDate)
        check(press(selectedID,in:host),"persistent Home resize selects a day through its mounted calendar action")
        _ = await wait(window) {accessibilityText(selectedID,in:host).contains("已选择")}
        // 现行规范 6.1 and 9.1: the page keeps 24 pt side margins inside the
        // window's 1 pt border, is at most 1360 pt wide and centred. From the
        // 840 pt home breakpoint up, both rows share three equal columns with
        // 12 pt gaps: This Mac sits over the disk card, the network card
        // follows it, and the rows stay at least 12 pt apart.
        func fitsViewport()->Bool {
            guard window.contentView === host,
                  abs(host.bounds.width-window.contentRect(forFrameRect:window.frame).width)<1,
                  let device=frame("home-device-detail",in:host),let disk=frame("home-open-cleaning",in:host),let network=frame("home-network-detail",in:host),
                  let scroll=outerPageScrollView(in:host) else {return false}
            let page=min(1360,max(0,host.bounds.width-2-48))
            let viewport=window.convertToScreen(host.convert(host.bounds,to:nil))
            let left=viewport.midX-page/2
            guard [device,disk,network].allSatisfy({$0.minX>=left-1 && $0.maxX<=left+page+1}),
                  (scroll.documentView?.bounds.width ?? .infinity)<=scroll.contentSize.width+1 else {return false}
            guard page>=840 else {return true}
            let column=(page-24)/3
            return abs(disk.minX-left)<1 && abs(disk.width-column)<1 && abs(network.width-column)<1
                && abs(network.minX-disk.maxX-12)<1 && abs(network.minY-disk.minY)<1
                && abs(device.minX-disk.minX)<1 && abs(device.width-disk.width)<1 && device.minY>=disk.maxY+11
        }
        let sizes:[NSSize]=[
            .init(width:1120,height:758),.init(width:1920,height:1080),.init(width:1728,height:993),
            .init(width:1351,height:900),.init(width:1349,height:900),.init(width:1120,height:758),
            .init(width:960,height:720),.init(width:900,height:620),.init(width:1120,height:758)
        ]
        for size in sizes {
            window.setContentSize(size)
            let fitted=await wait(window,until:fitsViewport)
            check(fitted,"same mounted Home follows actual \(Int(size.width))×\(Int(size.height)) viewport without horizontal overflow")
            check(accessibilityText(selectedID,in:host).contains("已选择"),"Home resize preserves the selected day instead of rebuilding the page")
            print("DETAIL persistent-home requested=\(size) host=\(host.bounds) device=\(String(describing:frame("home-device-detail",in:host))) disk=\(String(describing:frame("home-open-cleaning",in:host))) network=\(String(describing:frame("home-network-detail",in:host)))")
        }
        // Coalesce several drag-sized changes without awaiting a completed
        // layout at every step, then verify the final actual viewport settles.
        for width:CGFloat in [1728,1600,1480,1360,1240,1120] {
            window.setContentSize(.init(width:width,height:758));host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        check(await wait(window,until:fitsViewport),"rapid continuous shrinking converges without a route change or view reset")
        let ordinarySize=host.bounds.size
        window.zoom(nil)
        check(await wait(window,until:fitsViewport),"native window zoom lays out Home from the actual enlarged viewport")
        window.zoom(nil)
        check(await wait(window) {fitsViewport() && abs(host.bounds.width-ordinarySize.width)<1},
              "a second native window zoom restores the ordinary-width cards in place")
        if let controller=window.delegate as? WorkbenchWindowController {
            controller.requestToggleFullScreen()
            let entered=await wait(window,timeout:.seconds(10)) {
                window.styleMask.contains(.fullScreen) && !controller.isFullScreenTransitioning && model.isFullScreen && fitsViewport()
            }
            check(entered,"native full-screen entry finishes with Home fitted to its actual hosting viewport")
            if window.styleMask.contains(.fullScreen) {
                controller.requestToggleFullScreen()
                check(await wait(window,timeout:.seconds(10)) {
                    !window.styleMask.contains(.fullScreen) && !controller.isFullScreenTransitioning && !model.isFullScreen
                        && fitsViewport() && abs(host.bounds.width-ordinarySize.width)<1
                },"native full-screen exit restores ordinary Home card widths without remounting")
            } else {check(false,"native full-screen resize fixture completes both transition boundaries")}
        } else {check(false,"persistent Home full-screen check uses the production native window controller")}
        check(accessibilityText(selectedID,in:host).contains("已选择"),"zoom and native full-screen round trips preserve the same Home state")
        _ = press(dayID(today),in:host)
        print("Persistent Home resize checks: \(count-failures)/\(count) passed")
        return (count,failures)
    }

    /// Reading gutters belong to the document canvas, never to its scroll viewport.
    /// Only owned NSClipView offsets are changed; nested lists are not selected.
    private static func checkFullPageScrolling(model: WorkbenchAppModel, window: NSWindow, host: NSView) async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") full-page scroll: \(name)")
        }
        let originalFrame = window.frame, originalRoute = model.route, originalDetail = model.deviceDetail
        let originalDestination = model.ai.destination, originalSettingsTab = model.settingsTab
        let originalCalendarSources = model.calendar.showSources, originalVaultProtection = model.vault.showingProtection
        let originalManualDraft = model.ai.manualDraft, originalDeviceOffset = model.device.dashboardScrollOffset
        defer {
            model.deviceDetail = originalDetail; model.ai.manualDraft = originalManualDraft
            model.ai.show(originalDestination); model.settingsTab = originalSettingsTab
            model.calendar.showSources = originalCalendarSources; model.vault.showingProtection = originalVaultProtection
            model.navigate(originalRoute)
            model.device.dashboardScrollOffset = originalDeviceOffset
            window.setFrame(originalFrame, display: false)
        }
        // Cleaning is a viewport-sized workspace with a fixed page header and
        // footer. Its intentional card-internal scroll regions have separate checks.
        let routes: [(WorkbenchRoute, String)] = [(.overview, "fc.page.home"), (.device, "fc.page.device"), (.calendar, "fc.page.calendar"), (.ai, "fc.page.usage"), (.network, "fc.page.network"), (.vault, "fc.page.vault"), (.cards, "fc.page.settings.widgets"), (.settings, "fc.page.settings.general")]
        let samples: [NSSize] = [.init(width: 1120, height: 758), .init(width: 960, height: 720), .init(width: 1728, height: 993)]
        for size in samples {
            window.setContentSize(size)
            let label = "\(Int(size.width))×\(Int(size.height))"
            for (route, identifier) in routes {
                model.deviceDetail = nil; model.ai.showOverview(); model.settingsTab = .general
                model.calendar.showSources = false; model.vault.showingProtection = false
                model.navigate(route)
                let mounted = await wait(window) {
                    guard let scroll = outerPageScrollView(in: host) else { return false }
                    return frame(identifier, in: host) != nil
                        && (route != .cards || (model.route == .settings && model.settingsTab == .widgets))
                }
                guard mounted, let scroll = outerPageScrollView(in: host) else {
                    check(false, "\(route.rawValue) mounts its actual outer scroll viewport in \(label)"); continue
                }
                let viewport = scroll.convert(scroll.bounds, to: host)
                // 现行规范 6.1: the page scroller fills the content area below
                // the 58 pt navigation (and Settings' category row), leaving
                // only the window's 1 pt border, so its overlay scrollbar sits
                // at the window's right edge.
                let screen = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                let hostScreen = window.convertToScreen(host.convert(host.bounds, to: nil))
                let settingsTabs = frames(prefix: "settings-navigation-", in: host)
                let belowNavigation = route == .settings || route == .cards
                    ? hostScreen.maxY - screen.maxY > 59 && !settingsTabs.isEmpty && settingsTabs.allSatisfy { $0.minY >= screen.maxY - 0.5 }
                    : abs(hostScreen.maxY - screen.maxY - 59) <= 1
                check(abs(screen.minX - hostScreen.minX - 1) <= 1 && abs(hostScreen.maxX - screen.maxX - 1) <= 1
                      && abs(screen.minY - hostScreen.minY - 1) <= 1 && belowNavigation,
                      "\(route.rawValue) viewport fills the window below the 58 pt navigation, allowing only its 1 pt border in \(label)")
                check(scroll.hasVerticalScroller && scroll.scrollerStyle == .overlay,
                      "\(route.rawValue) uses the outer overlay scrollbar rather than reserving a card-edge track in \(label)")
                let track = scroll.verticalScroller.map { $0.convert($0.bounds, to: host) }
                print("DETAIL full-page-scroll \(route.rawValue) \(label) viewport=\(viewport) host=\(host.bounds) track=\(String(describing: track)) document=\(String(describing: scroll.documentView?.bounds)) nested=\(hasScrollAncestor(scroll, below: host))")
            }
        }

        // The compact production window makes both source pages genuinely scrollable.
        // Destinations are entered on the same mounted module and model objects.
        window.setContentSize(.init(width: 960, height: 620))
        model.deviceDetail = nil; model.navigate(.device)
        _ = await wait(window) { frame("fc.page.device", in: host) != nil && outerPageScrollView(in: host).map { scrollExtent($0) > 20 } == true }
        if let oldScroll = outerPageScrollView(in: host) {
            let layout = model.device.dashboardLayout, deviceIdentity = ObjectIdentifier(model.device)
            let startedAtBottom = moveToBottom(oldScroll)
            check(startedAtBottom, "the real device overview starts this regression at a nonzero bottom offset")
            let oldOffset = oldScroll.contentView.bounds.origin.y
            model.deviceDetail = .storage
            let reset = await wait(window) { frame("fc.page.device.storage", in: host) != nil && outerPageScrollView(in: host).map(isAtTop) == true }
            let detailScroll = outerPageScrollView(in: host)
            check(reset && detailScroll === oldScroll && window.contentView === host,
                  "opening storage details resets the same mounted outer viewport to the top")
            check(ObjectIdentifier(model.device) == deviceIdentity && model.device.dashboardLayout == layout && model.deviceDetail == .storage,
                  "storage navigation retains the original device model and every saved card preference")
            print("DETAIL device-detail-scroll oldY=\(oldOffset) detailY=\(detailScroll?.contentView.bounds.origin.y ?? -1) detailExtent=\(detailScroll.map(scrollExtent) ?? -1) destinationStillScrollable=\(detailScroll.map { scrollExtent($0) > 20 } ?? false)")
        } else { check(false, "device detail-reset fixture has its real outer scroll viewport") }

        // The unified overview is intentionally compact with only two source
        // cards. Create actual isolated service records so this regression starts
        // with a genuinely scrollable card grid, not an artificial spacer.
        let scrollingSources = (1...3).map { index in
            ProviderUsageConfiguration(kind: .iproyal, name: "Scroll fixture \(index)", resourceID: String(900_000 + index), enabled: false)
        }
        var sourceFixtureReady = true
        for source in scrollingSources {
            var accepting = source; accepting.enabled = true
            let saved = await model.providerUsage.save(accepting)
            let snapshot = ProviderUsageSnapshot(sourceID: source.id, observedAt: Date(), usedBytes: 200_000_000,
                limitBytes: 1_000_000_000, remainingBytes: 800_000_000, displayUnit: .decimalGB, sourceDescription: "Isolated scroll fixture")
            let accepted = model.providerUsage.acceptBrowserSnapshot(snapshot, for: source.id)
            let disabled = await model.providerUsage.save(source)
            sourceFixtureReady = accepted && saved && disabled && sourceFixtureReady
        }
        check(sourceFixtureReady && scrollingSources.allSatisfy { source in model.providerUsage.sources.contains { $0.id == source.id } },
              "AI scroll regression uses real isolated source records and snapshots with automatic queries disabled")
        model.deviceDetail = nil; model.ai.showOverview(); model.navigate(.ai)
        _ = await wait(window) { frame("fc.page.usage", in: host) != nil && outerPageScrollView(in: host).map { scrollExtent($0) > 20 } == true }
        if let oldScroll = outerPageScrollView(in: host) {
            model.ai.manualDraft.note = "Unsaved scroll-regression draft"
            let draft = model.ai.manualDraft, aiIdentity = ObjectIdentifier(model.ai)
            let selectedPeriod = model.ai.selectedPeriod, selectedProvider = model.ai.selectedProvider
            let startedAtBottom = moveToBottom(oldScroll)
            check(startedAtBottom, "the real AI overview starts this regression at a nonzero bottom offset")
            let oldOffset = oldScroll.contentView.bounds.origin.y
            model.ai.show(.provider(.codex))
            // The unified usage container owns the outer page AX identifier;
            // use the actual provider quota card to identify the mounted detail.
            let reset = await wait(window) { frame("fc.ai.detail.quota.codex", in: host) != nil && outerPageScrollView(in: host).map(isAtTop) == true }
            let detailScroll = outerPageScrollView(in: host)
            check(reset && detailScroll === oldScroll && window.contentView === host,
                  "opening Codex details resets the same mounted generic page viewport to the top")
            check(detailScroll.map { scrollExtent($0) > 20 } == true,
                  "Codex details remain scrollable, so the top reset cannot be explained by short-content clamping")
            check(ObjectIdentifier(model.ai) == aiIdentity && model.ai.manualDraft == draft
                  && model.ai.selectedPeriod == selectedPeriod && model.ai.selectedProvider == selectedProvider,
                  "AI detail navigation preserves the same model, unsaved form draft and activity filters")
            print("DETAIL ai-detail-scroll oldY=\(oldOffset) detailY=\(detailScroll?.contentView.bounds.origin.y ?? -1) detailExtent=\(detailScroll.map(scrollExtent) ?? -1) providerCard=\(String(describing: frame("fc.ai.detail.quota.codex", in: host))) sameScroll=\(detailScroll === oldScroll) sameHost=\(window.contentView === host)")
        } else { check(false, "AI detail-reset fixture has its real outer scroll viewport") }
        var removedScrollingSources = true
        for source in scrollingSources { let removed = await model.providerUsage.remove(id: source.id); removedScrollingSources = removed && removedScrollingSources }
        check(removedScrollingSources && scrollingSources.allSatisfy { source in !model.providerUsage.sources.contains { $0.id == source.id } },
              "AI scroll regression removes only the temporary sources it created")

        model.calendar.showSources = false; model.navigate(.calendar)
        _ = await wait(window) { frame("fc.page.calendar", in: host) != nil && outerPageScrollView(in: host).map { scrollExtent($0) > 20 } == true }
        if let oldScroll = outerPageScrollView(in: host) {
            let calendarIdentity = ObjectIdentifier(model.calendar)
            check(moveToBottom(oldScroll), "the calendar main page is at its actual outer bottom before opening sources")
            model.calendar.showSources = true
            let reset = await wait(window) { frame("fc.page.calendar.sources", in: host) != nil && outerPageScrollView(in: host).map(isAtTop) == true }
            check(reset && outerPageScrollView(in: host) === oldScroll && ObjectIdentifier(model.calendar) == calendarIdentity,
                  "calendar source details return the same viewport to the top without replacing the calendar model")
        } else { check(false, "calendar source-reset fixture has its real outer scroll viewport") }
        return (count, failures)
    }

    private static func outerPageScrollView(in host: NSView) -> NSScrollView? {
        var pending = [host], candidates: [NSScrollView] = []
        while let view = pending.popLast() {
            pending.append(contentsOf: view.subviews)
            guard let scroll = view as? NSScrollView, scroll.window === host.window,
                  !scroll.isHiddenOrHasHiddenAncestor, scroll.bounds.width > 0, scroll.bounds.height > 0,
                  scroll.documentView != nil, !hasScrollAncestor(scroll, below: host) else { continue }
            let rect = scroll.convert(scroll.bounds, to: host)
            if rect.intersects(host.bounds) { candidates.append(scroll) }
        }
        return candidates.max { lhs, rhs in
            let left = lhs.convert(lhs.bounds, to: host), right = rhs.convert(rhs.bounds, to: host)
            return left.width * left.height < right.width * right.height
        }
    }
    private static func hasScrollAncestor(_ scroll: NSScrollView, below host: NSView) -> Bool {
        var ancestor = scroll.superview
        while let view = ancestor, view !== host {
            if view is NSScrollView { return true }
            ancestor = view.superview
        }
        return false
    }
    private static func scrollExtent(_ scroll: NSScrollView) -> CGFloat {
        max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
    }
    private static func topOffset(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return 0 }
        return document.isFlipped ? document.bounds.minY : max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
    }
    private static func isAtTop(_ scroll: NSScrollView) -> Bool {
        abs(scroll.contentView.bounds.origin.y - topOffset(scroll)) <= 1
    }
    private static func moveToBottom(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView, scrollExtent(scroll) > 20 else { return false }
        let target = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height) : document.bounds.minY
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.origin.x, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        return abs(scroll.contentView.bounds.origin.y - target) <= 1 && abs(target - topOffset(scroll)) > 20
    }
    private static func containsAccessibilityText(_ text: String, in root: NSView) -> Bool {
        var pending: [NSObject] = [root], seen = Set<ObjectIdentifier>()
        while let object = pending.popLast(), seen.count < 8_192 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            for selector in ["accessibilityLabel", "accessibilityValue"] where object.responds(to: NSSelectorFromString(selector)) {
                if object.value(forKey: selector) as? String == text { return true }
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return false
    }

    private static func accessibilityText(_ identifier: String, in root: NSView) -> String {
        var pending: [NSObject] = [root], seen = Set<ObjectIdentifier>(), result: [String] = []
        while let object = pending.popLast(), seen.count < 8_192 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier {
                for selector in ["accessibilityLabel", "accessibilityValue"] where object.responds(to: NSSelectorFromString(selector)) {
                    if let text = object.value(forKey: selector) as? String { result.append(text) }
                }
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return result.joined(separator: " ")
    }

    private static func wait(_ window: NSWindow, timeout:Duration = .seconds(2), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() {
                // Geometry readers write their measured state on the next UI
                // turn; do not inspect the first pre-update layout pass.
                try? await Task.sleep(for: .milliseconds(30))
                window.contentView?.layoutSubtreeIfNeeded()
                return condition()
            }
            try? await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return condition()
    }
    private static func press(_ identifier:String,in root:NSView)->Bool {
        var pending:[NSObject]=[root],seen=Set<ObjectIdentifier>()
        let selector=NSSelectorFromString("accessibilityPerformPress")
        while let object=pending.popLast(),seen.count<8_192 {
            guard seen.insert(ObjectIdentifier(object)).inserted else {continue}
            if object.responds(to:NSSelectorFromString("accessibilityIdentifier")),object.value(forKey:"accessibilityIdentifier") as? String == identifier,object.responds(to:selector) {
                typealias Press = @convention(c) (AnyObject,Selector)->Bool
                return unsafeBitCast(object.method(for:selector),to:Press.self)(object,selector)
            }
            if let view=object as? NSView {pending.append(contentsOf:view.subviews)}
            if object.responds(to:NSSelectorFromString("accessibilityChildren")),let children=object.value(forKey:"accessibilityChildren") as? [NSObject] {pending.append(contentsOf:children)}
        }
        return false
    }
    private static func frame(_ identifier: String, in root: NSView) -> NSRect? {
        frames(matching: { $0 == identifier }, in: root).max { $0.width * $0.height < $1.width * $1.height }
    }
    private static func frames(prefix: String, in root: NSView) -> [NSRect] {
        frames(matching: { $0.hasPrefix(prefix) }, in: root)
    }
    private static func frames(matching matches: (String) -> Bool, in root: NSView) -> [NSRect] {
        var pending: [NSObject] = [root], seen = Set<ObjectIdentifier>(), result: [NSRect] = []
        while let object = pending.popLast(), seen.count < 8_192 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               let identifier = object.value(forKey: "accessibilityIdentifier") as? String, matches(identifier),
               object.responds(to: NSSelectorFromString("accessibilityFrame")),
               let value = object.value(forKey: "accessibilityFrame") as? NSValue {
                let rect = value.rectValue
                if rect.width > 0 && rect.height > 0 && rect.width.isFinite && rect.height.isFinite { result.append(rect) }
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return result
    }
}

@MainActor private final class HomeResizeCalendar:CalendarSystemProviding {
    var permissionRequests=0,writes=0
    func access(reminders:Bool)->CalendarAccess {.notDetermined}
    func requestAccess(reminders:Bool) async throws->Bool {permissionRequests += 1;return false}
    func events(in interval:DateInterval) throws->[CalendarEventItem] {[]}
    func reminders() async throws->[ReminderItem] {[]}
    func writableReminderCalendars()->[ReminderCalendar] {[]}
    func saveReminder(_ item:ReminderItem,creating:Bool) throws->ReminderItem {writes += 1;throw ReminderError.unavailable("Isolated resize fixture")}
    func deleteReminder(_ item:ReminderItem) throws {writes += 1;throw ReminderError.unavailable("Isolated resize fixture")}
}
@MainActor private final class HomeResizeNotifications:ReminderNotificationProviding {
    var permissionRequests=0
    func access() async->CalendarAccess {.notDetermined}
    func requestAccess() async throws->Bool {permissionRequests += 1;return false}
    func replacePending(_ notifications:[ReminderNotification]) async throws {}
}
@MainActor private final class HomeResizeAINotifications:AIQuotaNotificationProviding {
    func permission() async->AIQuotaNotificationPermission {.denied}
    func requestPermission() async throws->Bool {false}
    func deliver(_ event:AIQuotaAlertEvent) async throws {throw AIUsageError.invalid("Isolated resize fixture")}
}
