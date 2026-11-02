import AppKit
import LauncherCore

/// Opt-in checks of the mounted production home, using the service-disabled
/// resize fixture and a disposable ReminderStore. No normal user data is read.
@MainActor enum WorkbenchFluidHomeChecks {
    private static var seededStore: ReminderStore?
    private static let reminderID = "fluid-home-dated"

    static func seedReminders(in directory: URL) throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().pathComponents
        guard directory.resolvingSymlinksInPath().pathComponents.starts(with: temporary) else {
            throw ReminderError.invalid("首页检查仅允许使用独立临时提醒目录")
        }
        let calendar = Calendar.current, today = Date()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        var snapshot = ReminderSnapshot()
        snapshot.reminders = [
            ReminderItem(id: reminderID, title: "核对本周设计文件", due: ReminderDue(date: today, includesTime: false, calendar: calendar), notificationsEnabled: false),
            ReminderItem(id: "fluid-home-next", title: "检查服务续费日期", due: ReminderDue(date: tomorrow, includesTime: false, calendar: calendar), notificationsEnabled: false),
            ReminderItem(id: "fluid-home-undated", title: "整理下载文件夹", notificationsEnabled: false)
        ]
        let store = ReminderStore(directory: directory)
        try store.save(snapshot); seededStore = store
    }

    static func run(model: WorkbenchAppModel, window: NSWindow, host: NSView) async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ description: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(description)")
        }
        guard let store = seededStore else {
            check(false, "fluid Home requires its disposable seeded ReminderStore")
            return (count, failures)
        }
        defer { seededStore = nil }
        let routes: [WorkbenchRoute] = [.overview, .device, .cleaning, .calendar, .ai, .network, .vault]
        let initialReminderIDs = Set(model.calendar.reminders.map(\.stableID))
        do {
            model.changeLight(true)
            check(await settle(window) { model.light && model.appearance == .light },
                  "the isolated Home starts in the approved light appearance")
            for sample in [(1120, 758, "regular"), (960, 720, "narrow"), (1728, 993, "wide"), (1120, 758, "returned")] {
                window.setContentSize(NSSize(width: CGFloat(sample.0), height: CGFloat(sample.1)))
                let ready = await settle(window) {
                    ["home-device-detail", "fc.home.calendar", "home-open-cleaning", "home-network-detail", "fc.home.reminders"].allSatisfy { frame($0, in: host) != nil }
                }
                check(ready, "fluid Home mounts all five useful regions in \(sample.2)")
                let navigation = routes.compactMap { element("navigation-" + $0.rawValue, in: host) }
                if sample.2 == "regular" {
                    for route in routes {
                        let id = "navigation-" + route.rawValue
                        guard let item = element(id, in: host) else {
                            print("DETAIL fluid Home nav \(id) missing")
                            continue
                        }
                        let role = string("accessibilityRole", of: item) ?? "unknown"
                        let label = string("accessibilityLabel", of: item) ?? ""
                        let supportsPress = item.responds(to: NSSelectorFromString("accessibilityPerformPress"))
                        print("DETAIL fluid Home nav \(id) role=\(role) label=\(label) supportsPress=\(supportsPress) frame=\(String(describing: rect(item)))")
                    }
                }
                let navFrames = navigation.compactMap(rect)
                check(navigation.count == 7 && navigation.allSatisfy { string("accessibilityRole", of: $0) == NSAccessibility.Role.button.rawValue }
                      && navFrames.count == 7 && (navFrames.map(\.midY).max() ?? 0) - (navFrames.map(\.midY).min() ?? 0) < 2
                      && element("workbench-sidebar", in: host) == nil,
                      "seven real top-navigation buttons share one row without the old sidebar in \(sample.2)")
                check(["home-welcome", "home-date-time", "home-weather"].allSatisfy { id in
                    frame(id, in: host).map { visible($0, window: window, host: host) } == true
                }, "welcome, date/time and weather remain visible in \(sample.2)")
                check(homeGeometry(host, window: window), "Mac and month sit above three readable, nonoverlapping cards in \(sample.2)")
                check(bottomCardsDocked(host, window: window),
                      "the compact bottom row follows the window's lower edge instead of the top row in \(sample.2)")
                let dayElements = objects(in: host).filter { identifier($0).hasPrefix("fc.home.calendar.day.") && rect($0) != nil }
                let days = Dictionary(dayElements.map { (identifier($0), rect($0)!) }, uniquingKeysWith: { first, _ in first }).values
                check(days.count == 42 && days.allSatisfy { $0.width >= 24 && $0.height >= 28 && visible($0, window: window, host: host) },
                      "all six calendar weeks are readable and unclipped in \(sample.2)")
                if sample.2 != "returned" { try NativeUIFixtureAccessibility.saveView(host, name: "home-fluid-\(sample.2).png") }
                print("DETAIL fluid Home \(sample.2) device=\(String(describing: frame("home-device-detail", in: host))) month=\(String(describing: frame("fc.home.calendar", in: host))) disk=\(String(describing: frame("home-open-cleaning", in: host))) network=\(String(describing: frame("home-network-detail", in: host))) reminders=\(String(describing: frame("fc.home.reminders", in: host)))")
            }

            check(press("fc.home.appearance.toggle", in: host), "the actual header appearance control accepts an AX press")
            check(await settle(window) {
                !model.light && model.appearance == .dark
                    && window.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }, "the header switches the real workbench and native window into dark appearance")
            check(try model.owner?.store.load()?.settings.workbenchAppearance == .dark,
                  "dark appearance survives a fresh read from the isolated configuration store")
            check(["home-device-detail", "home-open-cleaning", "home-network-detail", "fc.home.calendar", "fc.home.reminders", "home-welcome"].allSatisfy { frame($0, in: host) != nil },
                  "switching appearance preserves every Home region and the outlined welcome")
            try NativeUIFixtureAccessibility.saveView(host, name: "home-fluid-dark.png")
            check(press("fc.home.appearance.toggle", in: host), "the same header control returns to light appearance")
            check(await settle(window) { model.light && model.appearance == .light },
                  "light appearance is restored without replacing the window or Home data")
            check(try model.owner?.store.load()?.settings.workbenchAppearance == .light,
                  "the restored light choice is also persisted")

            if let account = objects(in: host).compactMap({ $0 as? WorkbenchFluidAccountMenuButton }).first {
                let menu = account.makeAccountMenu()
                check(menu.items.allSatisfy { $0.action == nil && !$0.isEnabled }
                      && menu.items.contains { $0.title == NSFullUserName() },
                      "the account menu identifies the local account without unrelated window or app-exit commands")
                check(menu.items.allSatisfy { $0.submenu == nil } && !model.confirmingQuit && !model.quitting,
                      "inspecting the compact native menu neither creates nested menus nor starts an exit")
            } else { check(false, "the mounted account control exposes its native arrowless menu") }

            let initialMonth = model.calendar.displayCalendar.component(.month, from: model.calendar.displayedMonth)
            check(press("fc.home.calendar.previous", in: host), "the mounted previous-month button accepts an AX press")
            check(await settle(window) { model.calendar.displayCalendar.component(.month, from: model.calendar.displayedMonth) != initialMonth },
                  "month navigation updates the actual calendar selection and query month")
            check(press("fc.home.calendar.today", in: host), "the mounted Today action accepts an AX press")
            check(await settle(window) { model.calendar.displayCalendar.isDate(model.calendar.selectedDay, inSameDayAs: Date()) },
                  "Today returns to the selected display timezone's actual day")
            let calendar = model.calendar.displayCalendar
            let selectedDate = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            let parts = calendar.dateComponents([.year, .month, .day], from: selectedDate)
            let selectedID = String(format: "fc.home.calendar.day.%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            let visibleWindows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            check(press(selectedID, in: host), "a calendar date is selected through its actual mounted button")
            check(await settle(window) {
                calendar.isDate(model.calendar.selectedDay, inSameDayAs: selectedDate)
                    && element("fc.home.calendar.dayDetails", in: host) != nil
                    && element(selectedID, in: host).flatMap { string("accessibilityValue", of: $0) } == "已选择"
            }, "date selection updates the selected state and mounts the compact agenda inside Home")
            check(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)) == visibleWindows
                  && !model.modals.isPresented && model.calendar.editor == nil && model.calendar.selectedEvent == nil,
                  "selecting a date opens no popover, extra window or modal editor")
            if let agenda = frame("fc.home.calendar.dayDetails", in: host), let day = frame(selectedID, in: host),
               let month = frame("fc.home.calendar", in: host) {
                check(agenda.maxY < day.minY && agenda.minX >= month.minX && agenda.maxX <= month.maxX,
                      "the selected day's agenda stays beneath the month inside the same calendar group")
            } else { check(false, "the inline agenda has measurable bounds within the calendar group") }
            check(initialReminderIDs == Set(model.calendar.reminders.map(\.stableID))
                  && pendingRemindersRemainVisible(in: host),
                  "browsing another month retains dated and undated home reminders")
            try NativeUIFixtureAccessibility.saveView(host, name: "home-fluid-inline-agenda.png")

            check(press("fc.home.reminders.add", in: host), "the home add button opens the real reminder editor")
            check(await settle(window) { model.calendar.editor?.creating == true && element("fc.calendar.editor.title", in: host) != nil },
                  "the shared production reminder form is mounted from Home")
            check(pressLabel("取消", in: host), "the mounted Cancel button dismisses the unchanged new reminder")
            check(await settle(window) { model.calendar.editor == nil && !model.modals.isPresented },
                  "cancelling a fresh reminder restores Home without a modal")
            check(Set(try store.load().reminders.map(\.stableID)) == initialReminderIDs,
                  "cancel leaves the disposable persisted reminders unchanged")

            check(press("fc.home.reminder.toggle.local:" + reminderID, in: host), "the real circular completion control accepts an AX press")
            check(await settle(window) { model.calendar.localReminders.first { $0.id == reminderID }?.isCompleted == true },
                  "completion changes the real model rather than a preview-only checked state")
            check(try store.load().reminders.first { $0.id == reminderID }?.isCompleted == true,
                  "completion persists in the isolated local ReminderStore")
            check(press("fc.home.reminders.undo", in: host), "the mounted Undo action is reachable after completion")
            check(await settle(window) { model.calendar.localReminders.first { $0.id == reminderID }?.isCompleted == false },
                  "Undo restores the same reminder identity and pending state")
            check(try store.load().reminders.first { $0.id == reminderID }?.isCompleted == false,
                  "Undo restores the persisted local reminder")

            check(press("navigation-device", in: host), "the actual top device navigation accepts an AX press")
            check(await settle(window) { model.route == .device }, "top navigation enters the existing device module")
            check(press("navigation-overview", in: host), "the actual top Home navigation accepts an AX press")
            check(await settle(window) { model.route == .overview && element("fc.home.calendar", in: host) != nil },
                  "returning Home preserves its functional calendar and reminders")
            check(press("navigation-settings", in: host), "the header Settings action accepts an AX press")
            check(await settle(window) { model.route == .settings && element("settings-navigation-general", in: host) != nil },
                  "Settings exposes the replacement category navigation")
            for tab in WorkbenchSettingsTab.allCases {
                let id = "settings-navigation-" + tab.rawValue
                let pressed = press(id, in: host)
                let mounted = await settle(window) { model.settingsTab == tab && element("fc.page.settings." + tab.rawValue, in: host) != nil }
                check(pressed && mounted, "the \(tab.rawValue) settings category remains reachable through its actual control")
            }
            if CommandLine.arguments.contains("--interface-fluid-check") {
                let result = try await checkModules(model: model, window: window, host: host)
                count += result.count; failures += result.failures
            }
            _ = press("navigation-overview", in: host)
            _ = await settle(window) { model.route == .overview && frame("fc.home.reminders", in: host) != nil }
            try NativeUIFixtureAccessibility.saveView(host, name: "home-fluid-after-interaction.png")
        } catch {
            check(false, "fluid Home fixture error: \(error.localizedDescription)")
        }
        return (count, failures)
    }

    /// Exercise the production route tree in both appearances, including real
    /// form presentation and title geometry. All data belongs to the fixture.
    private static func checkModules(model: WorkbenchAppModel, window: NSWindow, host: NSView) async throws -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(message)")
        }
        let routes: [(WorkbenchRoute, String)] = [(.device,"fc.page.device"),(.cleaning,"space-cleaning"),(.calendar,"fc.calendar.workspace"),(.ai,"fc.page.usage"),(.network,"fc.page.network"),(.vault,"fc.page.vault"),(.settings,"fc.page.settings.general")]
        for light in [true, false] {
            model.changeLight(light)
            for size in [NSSize(width:1120,height:758), NSSize(width:960,height:720), NSSize(width:1728,height:993)] {
                window.setContentSize(size)
                for (route, identifier) in routes {
                    model.settingsTab = .general
                    let pressed = press("navigation-" + route.rawValue, in: host)
                    let mounted = await settle(window) { model.route == route && element(identifier, in: host) != nil && frame("workbench-page-title", in: host) != nil }
                    let name = "\(route.rawValue) \(light ? "light" : "dark") \(Int(size.width))"
                    check(pressed && mounted, "\(name): real navigation mounts its existing content")
                    let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
                    let title = frame("workbench-page-title", in: host)
                    let brand = frame("window-brand", in: host)
                    check(title.map { visible($0, window: window, host: host) && abs($0.minX - viewport.minX - 25) < 2 && $0.height <= 28 } == true
                          && brand.map { abs($0.minX - viewport.minX - 25) < 2 && $0.height <= 28 } == true,
                          "\(name): title and compact brand align to the same 24-point content edge")
                    let navFrames = WorkbenchRoute.allCases.filter { $0 != .cards }.compactMap { frame("navigation-" + $0.rawValue, in: host) }
                    check(navFrames.count == 8 && navFrames.allSatisfy { visible($0, window:window, host:host) }, "\(name): every navigation control stays visible")
                    try NativeUIFixtureAccessibility.saveView(host, name:"interface-\(name.replacingOccurrences(of:" ",with:"-")).png")
                }
            }
            window.setContentSize(NSSize(width:1120,height:758))
            model.navigate(.network)
            _ = await settle(window) { element("fc.action.network.budget", in:host) != nil }
            check(press("fc.action.network.budget", in:host), "\(light): network budget opens from its actual control")
            check(await settle(window) { model.modals.isPresented }, "\(light): the existing budget form is hosted by the shared modal")
            try NativeUIFixtureAccessibility.saveView(host, name:"interface-budget-\(light ? "light" : "dark").png")
            model.cancelPresentedInteraction()
            check(await settle(window) { !model.modals.isPresented }, "\(light): Escape dismisses the unchanged budget form")
            model.navigate(.ai)
            _ = await settle(window) { element("fc.usage.configure", in:host) != nil }
            check(press("fc.usage.configure", in:host), "\(light): usage configuration opens from its actual control")
            check(await settle(window) { model.usagePresentation.connectionManager != nil && model.modals.isPresented }, "\(light): connection management preserves its real form")
            try NativeUIFixtureAccessibility.saveView(host, name:"interface-connections-\(light ? "light" : "dark").png")
            model.cancelPresentedInteraction()
            check(await settle(window) { !model.modals.isPresented }, "\(light): unchanged connection management dismisses cleanly")
            model.navigate(.device); model.deviceDetail = .memory
            check(await settle(window) { element("fc.page.device.memory", in:host) != nil }, "\(light): device details remain reachable with the shared surface")
            try NativeUIFixtureAccessibility.saveView(host, name:"interface-memory-\(light ? "light" : "dark").png")
            model.deviceDetail = nil
            model.navigate(.settings); model.settingsTab = .material
            check(await settle(window) { element("fc.page.settings.material", in:host) != nil }, "\(light): fixed paired appearance settings remain reachable")
            check(!objects(in:host).contains { $0 is NSSlider }, "\(light): retired opacity slider is not exposed")
            try NativeUIFixtureAccessibility.saveView(host, name:"interface-material-\(light ? "light" : "dark").png")
            if let owner = model.owner {
                if owner.panel == nil { owner.configurePanel() }
                owner.focusTransitionUntil = .distantFuture
                owner.show()
                _ = await settle(owner.panel) { owner.panel.isVisible }
                check(owner.panel.appearance?.bestMatch(from:[.aqua,.darkAqua]) == (light ? .aqua : .darkAqua), "\(light): launcher inherits the actual global appearance")
                check(WorkbenchFluidAssets.image(light:light) != nil && objects(in:owner.content).allSatisfy { string("accessibilityLabel",of:$0) != "全局透明度" }, "\(light): approved background is bundled and retired launcher opacity control is absent")
                try NativeUIFixtureAccessibility.saveView(owner.background, name:"interface-launcher-\(light ? "light" : "dark").png")
                let toggle = objects(in:owner.content).compactMap { $0 as? ActionButton }.first { $0.accessibilityLabel() == (light ? "切换深色外观" : "切换浅色外观") }
                toggle?.performClick(nil)
                check(await settle(owner.panel) { model.light != light && owner.configuration.settings.workbenchAppearance == (light ? .dark : .light) }, "\(light): launcher toggle changes both workbench preference and actual appearance")
                owner.hide(restore:false); window.makeKeyAndOrderFront(nil)
                model.changeLight(light)
                let advanced = LauncherSettingsWindowController(owner:owner, autosavesFrame:false)
                advanced.present()
                if let settingsWindow = advanced.window, let root = settingsWindow.contentView {
                    let appearancePopup = objects(in:root).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles == LauncherAppearance.allCases.map(\.title) }
                    check(appearancePopup?.titleOfSelectedItem == (light ? "浅色" : "深色"), "\(light): advanced launcher settings reflect the same appearance preference")
                    try NativeUIFixtureAccessibility.saveView(root, name:"interface-advanced-launcher-\(light ? "light" : "dark").png")
                    appearancePopup?.selectItem(withTitle:"跟随系统")
                    if let popup=appearancePopup, let action=popup.action { NSApp.sendAction(action,to:popup.target,from:popup) }
                    check(await settle(settingsWindow) { model.appearance == .system && owner.configuration.settings.workbenchAppearance == .system }, "\(light): the actual advanced settings control persists Follow System")
                } else { check(false,"advanced launcher settings create a native window") }
                advanced.close(); model.changeLight(light); window.makeKeyAndOrderFront(nil)
            }
        }
        return (count, failures)
    }

    private static func homeGeometry(_ host: NSView, window: NSWindow) -> Bool {
        guard let device = frame("home-device-detail", in: host), let month = frame("fc.home.calendar", in: host),
              let disk = frame("home-open-cleaning", in: host), let network = frame("home-network-detail", in: host),
              let reminders = frame("fc.home.reminders", in: host) else { return false }
        let bottom = [disk, network, reminders]
        // AX groups can report the union of children rather than their painted
        // padding. Check useful separation/readability, not synthetic CSS boxes.
        return device.maxX < month.minX
            && bottom.allSatisfy { visible($0, window: window, host: host) && $0.width > 220 && (190...242).contains($0.height) }
            && disk.maxX <= network.minX + 1 && network.maxX <= reminders.minX + 1
            && abs(disk.maxY - network.maxY) < 3 && abs(network.maxY - reminders.maxY) < 22
            && month.minY > disk.maxY && device.minY > disk.maxY
    }
    private static func bottomCardsDocked(_ host: NSView, window: NSWindow) -> Bool {
        let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
        guard let disk = frame("home-open-cleaning", in: host), let network = frame("home-network-detail", in: host),
              let reminders = frame("fc.home.reminders", in: host) else { return false }
        // A small footer holds the version. AX group bounds may omit their
        // painted padding, so keep enough tolerance for the reminder's 14 pt inset.
        return [disk, network, reminders].allSatisfy { (28...49).contains($0.minY - viewport.minY) }
            && abs(disk.minY - network.minY) < 3 && abs(network.minY - reminders.minY) < 17
    }
    private static func pendingRemindersRemainVisible(in host: NSView) -> Bool {
        guard let group = element("fc.home.reminders", in: host) else { return false }
        let ids = Set(objects(in: group).map(identifier))
        return [reminderID, "fluid-home-next", "fluid-home-undated"].allSatisfy {
            ids.contains("fc.home.reminder.toggle.local:" + $0)
        }
    }
    private static func visible(_ rect: NSRect, window: NSWindow, host: NSView) -> Bool {
        let viewport = window.convertToScreen(host.convert(host.bounds, to: nil)).insetBy(dx: -1, dy: -1)
        return viewport.contains(rect)
    }
    private static func objects(in root: NSObject) -> [NSObject] {
        var stack = [root], visited = Set<ObjectIdentifier>(), result: [NSObject] = []
        while let object = stack.popLast(), visited.count < 8192 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            if let view = object as? NSView { stack.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { stack.append(contentsOf: children) }
        }
        return result
    }
    private static func identifier(_ object: NSObject) -> String { string("accessibilityIdentifier", of: object) ?? "" }
    private static func string(_ key: String, of object: NSObject) -> String? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) as? String : nil
    }
    private static func rect(_ object: NSObject) -> NSRect? {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")), let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        let rect = value.rectValue
        return rect.width > 0 && rect.height > 0 && rect.width.isFinite && rect.height.isFinite ? rect : nil
    }
    private static func element(_ id: String, in host: NSView) -> NSObject? {
        objects(in: host).filter { identifier($0) == id && rect($0) != nil }.max { (rect($0)?.width ?? 0) < (rect($1)?.width ?? 0) }
    }
    private static func frame(_ id: String, in host: NSView) -> NSRect? { element(id, in: host).flatMap(rect) }
    private static func press(_ id: String, in host: NSView) -> Bool { element(id, in: host).map(performPress) ?? false }
    private static func pressLabel(_ label: String, in host: NSView) -> Bool {
        objects(in: host).first { string("accessibilityLabel", of: $0) == label && string("accessibilityRole", of: $0) == NSAccessibility.Role.button.rawValue }.map(performPress) ?? false
    }
    private static func performPress(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
    private static func settle(_ window: NSWindow, timeout: Duration = .seconds(2), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() {
                try? await Task.sleep(for: .milliseconds(35)); window.contentView?.layoutSubtreeIfNeeded()
                if condition() { return true }
            }
            try? await Task.sleep(for: .milliseconds(15))
        } while ContinuousClock.now < deadline
        return condition()
    }
}
