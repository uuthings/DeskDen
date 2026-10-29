import AppKit
import LauncherCore

/// Explicit foreground fixture for the mounted calendar only. All calendar,
/// reminder, notification and AI sources are disposable and service-disabled.
@MainActor enum CalendarLayoutNativeChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-calendar-layout-\(UUID())")
        let previousApplication = NSWorkspace.shared.frontmostApplication, previousPolicy = NSApp.activationPolicy()
        let previousPalette = (Palette.workbenchTheme, Palette.isLight, Palette.glassOpacity)
        defer {
            Palette.workbenchTheme = previousPalette.0; Palette.isLight = previousPalette.1; Palette.glassOpacity = previousPalette.2
            NSApp.setActivationPolicy(previousPolicy)
            if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication?.activate(options: []) }
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let owner = LauncherController(dataDirectory: directory.appendingPathComponent("Launcher"))
            owner.scanning = true
            owner.configuration.settings.workbenchHotKey = nil; owner.configuration.settings.applicationViewHotKey = nil
            owner.configuration.settings.launcherHotKey = nil; owner.configuration.settings.directLaunchPrefix = nil
            owner.configuration.bindingHotKeys = [:]
            owner.configuration.settings.backgroundMotionEnabled = false; owner.configuration.settings.reduceMotion = true
            try owner.store.save(owner.configuration)
            let aiDirectory = directory.appendingPathComponent("AI"), aiSources = aiDirectory.appendingPathComponent("AIUsage")
            try FileManager.default.createDirectory(at: aiSources, withIntermediateDirectories: true)
            try JSONEncoder().encode(AIProvider.allCases.map {
                AIUsageSourceConfiguration(provider: $0, enabled: false, sessionsPath: directory.appendingPathComponent("disabled-" + $0.rawValue).path)
            }).write(to: aiSources.appendingPathComponent("sources.json"))
            let calendarDirectory = directory.appendingPathComponent("Calendar")
            var snapshot = ReminderSnapshot()
            snapshot.preferences.calendarConnected = true; snapshot.preferences.remindersConnected = true
            try ReminderStore(directory: calendarDirectory).save(snapshot)
            let system = CalendarLayoutSystem(), notifier = CalendarLayoutNotifications()
            let calendar = CalendarModel(dataDirectory: calendarDirectory, system: system, notifier: notifier)
            let ai = AIUsageModel(dataDirectory: aiDirectory, startServices: false, notifications: CalendarLayoutAINotifications(),
                                  claudeSettingsDirectory: directory.appendingPathComponent("DisabledClaude"))
            let model = WorkbenchAppModel(owner: owner, calendar: calendar, ai: ai, startServices: false)
            let controller = WorkbenchWindowController(owner: owner, model: model, autosavesFrame: false)
            owner.workbenchController = controller
            defer {
                model.modals.clear(); model.shutdown()
                controller.window?.orderOut(nil); controller.window?.delegate = nil
                controller.window?.contentView = nil; controller.window?.close()
                owner.workbenchController = nil
                owner.hotKey.unregister(); owner.bindingHotKeys.unregister(); owner.toastTask?.cancel()
            }
            guard let window = controller.window, let host = window.contentView else {
                check(false, "calendar fixture creates its production native window"); return (count, failures)
            }
            controller.present(route: .calendar)
            guard await NativeUIFixtureWindow.prepare(window: window, until: { frame("fc.calendar.workspace", in: host) != nil }) else {
                check(false, "calendar fixture mounts its real accessibility tree"); return (count, failures)
            }
            await calendar.refresh()
            let display = calendar.displayCalendar
            func civil(_ year: Int, _ month: Int, _ day: Int) -> Date {
                display.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
            }
            let fiveWeekDay = civil(2026, 10, 15), sixWeekDay = civil(2026, 8, 15)
            calendar.displayedMonth = fiveWeekDay; calendar.selectedDay = fiveWeekDay; calendar.presentationMode = .month
            await calendar.refresh()
            for sample in [(1120, 758, "regular"), (960, 720, "narrow"), (1728, 993, "wide"), (1120, 758, "returned")] {
                window.setContentSize(.init(width: CGFloat(sample.0), height: CGFloat(sample.1)))
                let ready = await settle(window) { geometryFits(host) }
                check(ready, "calendar keeps bounded month, useful side width and readable dates in \(sample.0)×\(sample.1)")
                check(centered("fc.calendar.empty.add-action", in: "fc.calendar.selectedAgenda", host: host),
                      "empty-day add action is centered in \(sample.2)")
                check(centered("fc.calendar.pending.all-action", in: "fc.calendar.pendingReminders", host: host),
                      "empty-reminder all action is centered in \(sample.2)")
                if sample.2 != "returned" { try NativeUIFixtureAccessibility.saveView(host, name: "calendar-layout-\(sample.2).png") }
                print("DETAIL calendar layout \(sample.2) month=\(String(describing: frame("fc.calendar.monthCard", in: host))) side=\(String(describing: frame("fc.calendar.sideColumn", in: host))) upcoming=\(String(describing: frame("fc.calendar.upcomingAgenda", in: host)))")
            }
            check(calendar.monthDays.count == 35, "calendar fixture covers an actual five-week month")
            let fiveHeight = frame("fc.calendar.monthCard", in: host)?.height
            calendar.displayedMonth = sixWeekDay; calendar.selectedDay = sixWeekDay
            await calendar.refresh()
            check(await settle(window, until: { calendar.monthDays.count == 42 && geometryFits(host) }),
                  "six-week calendar preserves bounded geometry without compressing its last row")
            check(fiveHeight.flatMap { five in frame("fc.calendar.monthCard", in: host).map { $0.height > five && $0.height <= 600 } } == true,
                  "month height follows five or six real weeks within its maximum")
            try NativeUIFixtureAccessibility.saveView(host, name: "calendar-layout-six-weeks.png")

            let interval = calendar.overviewInterval
            check(calendar.overviewLoadedInterval.map { $0.start <= interval.start && $0.end >= interval.end } == true,
                  "recent agenda records the actual seven-day query coverage")
            let nextDay = display.date(byAdding: .day, value: 1, to: display.startOfDay(for: Date()))!
            let eventStart = display.date(byAdding: .hour, value: 14, to: nextDay)!
            system.eventsValue = [.init(id: "fixture-next", title: "隔离日程样本", start: eventStart,
                                        end: eventStart.addingTimeInterval(3600), calendarName: "隔离日历", calendarID: "fixture-calendar")]
            await calendar.refresh()
            check(await settle(window, until: { text("fc.calendar.upcomingAgenda", in: host).contains("隔离日程样本") }),
                  "recent agenda shows the loaded source event outside the month being browsed")
            check(!text("fc.calendar.upcoming.range", in: host).isEmpty, "recent agenda explicitly labels its seven-day range")
            calendar.setSourceVisible("fixture-calendar", false)
            check(await settle(window, until: { text("fc.calendar.upcoming.status", in: host).contains("暂无") }),
                  "hidden sources are excluded before a fully covered empty state is shown")
            calendar.setSourceVisible("fixture-calendar", true)
            system.failEvents = true
            await calendar.refresh(); calendar.errorMessage = nil; model.modals.clear()
            check(calendar.overviewLoadedInterval == nil && calendar.overviewReadError != nil,
                  "failed reads invalidate coverage instead of calling stale events a complete result")
            check(await settle(window, until: { text("fc.calendar.upcoming.status", in: host).contains("失败") }),
                  "recent agenda presents a read failure rather than an empty week")
            system.failEvents = false
            await calendar.refresh()
            let alternateZone = display.timeZone.identifier == "Pacific/Kiritimati" ? TimeZone(secondsFromGMT: -12 * 3600)! : TimeZone(identifier: "Pacific/Kiritimati")!
            await calendar.refreshMiniAgenda(timeZone: alternateZone)
            check(await settle(window, until: {
                let value = text("fc.calendar.upcoming.status", in: host)
                return value.contains("范围") || value.contains("完整") || value.contains("载入")
            }), "a differently bounded seven-day cache is reported as incomplete coverage")
            await calendar.refresh()

            system.remindersValue = (1...24).map { index in
                ReminderItem(id: "fixture-reminder-\(index)", origin: .system, calendarID: "fixture-list", calendarName: "隔离提醒",
                             title: String(format: "滚动待办 %02d", index), due: ReminderDue(date: nextDay, includesTime: false, calendar: display))
            }
            await calendar.refresh()
            check(await settle(window, until: { calendar.systemReminders.count == 24 && innerScroll("fc.calendar.pendingReminders", in: host).map { extent($0) > 100 } == true }),
                  "pending reminders keep more than three items in a real internal scrolling viewport")
            if let scroll = innerScroll("fc.calendar.pendingReminders", in: host) {
                let offset = scroll.contentView.bounds.origin.y
                let moved = moveToBottom(scroll)
                check(moved && abs(scroll.contentView.bounds.origin.y - offset) > 100,
                      "the reminder viewport scrolls its complete content independently")
                check(await settle(window, until: { text("fc.calendar.pendingReminders", in: host).contains("滚动待办 24") }),
                      "the last pending reminder is reachable instead of being truncated")
            } else { check(false, "pending reminder scroll has an actual native viewport") }

            system.remindersValue = []; await calendar.refresh()
            calendar.displayedMonth = fiveWeekDay; calendar.selectedDay = fiveWeekDay
            window.setContentSize(.init(width: 1120, height: 758))
            _ = await settle(window, until: { geometryFits(host) })
            let ordinarySize = host.bounds.size
            controller.requestToggleFullScreen()
            let entered = await settle(window, timeout: .seconds(10)) {
                window.styleMask.contains(.fullScreen) && !controller.isFullScreenTransitioning && model.isFullScreen && geometryFits(host)
            }
            check(entered, "calendar fits the actual native full-screen hosting viewport")
            if entered { try NativeUIFixtureAccessibility.saveView(host, name: "calendar-layout-fullscreen.png") }
            if window.styleMask.contains(.fullScreen) {
                controller.requestToggleFullScreen()
                check(await settle(window, timeout: .seconds(10)) {
                    !window.styleMask.contains(.fullScreen) && !controller.isFullScreenTransitioning && !model.isFullScreen
                        && abs(host.bounds.width - ordinarySize.width) < 1 && geometryFits(host)
                }, "native full-screen return restores the same calendar layout")
            } else { check(false, "calendar completes its native full-screen return boundary") }
            check(!model.device.isSampling && !ai.isRefreshing && model.providerUsage.refreshing.isEmpty && model.apiBalance.refreshing.isEmpty
                  && system.permissionRequests == 0 && system.writes == 0 && notifier.permissionRequests == 0 && notifier.nonemptyDeliveries == 0,
                  "calendar fixture never accesses real sources, requests permissions or schedules real notifications")
        } catch { check(false, "calendar layout fixture: \(error.localizedDescription)") }
        return (count, failures)
    }

    private static func geometryFits(_ host: NSView) -> Bool {
        let page = min(1360, max(0, host.bounds.width - 184 - 2 - 70))
        guard let month = frame("fc.calendar.monthCard", in: host), let side = frame("fc.calendar.sideColumn", in: host),
              month.width > 0, month.height <= 600.5 else { return false }
        // The current month may be deliberately outside today's date, so date
        // readability is checked on every mounted tile rather than requiring it.
        let tiles = objects(in: host).filter { identifier($0).hasPrefix("fc.calendar.day.") }.compactMap(rect)
        guard !tiles.isEmpty, tiles.allSatisfy({ $0.height >= 53.5 && $0.width > 0 }) else { return false }
        if page < 760 { return abs(month.width - page) < 2 && abs(side.width - page) < 2 && side.maxY <= month.minY - 10 }
        guard let recent = frame("fc.calendar.upcomingAgenda", in: host), let workspace = frame("fc.calendar.workspace", in: host) else { return false }
        let availableBottom = host.window.map { $0.convertToScreen(host.convert(host.bounds, to: nil)).minY + 16 } ?? 0
        return (499...721).contains(month.width) && side.width >= 247
            && abs(month.width + side.width + 12 - page) < 3
            && abs(side.maxY - month.maxY) < 2 && abs(side.minY - recent.minY) < 2
            && recent.maxY <= month.minY - 10 && workspace.minY <= availableBottom + 24
    }
    private static func centered(_ action: String, in card: String, host: NSView) -> Bool {
        guard let button = frame(action, in: host), let container = frame(card, in: host) else { return false }
        return button.width < container.width - 40 && abs(button.midX - container.midX) < 2
    }
    private static func objects(in root: NSObject) -> [NSObject] {
        var pending = [root], seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        while let object = pending.popLast(), seen.count < 16_384 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }; result.append(object)
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return result
    }
    private static func identifier(_ object: NSObject) -> String {
        object.responds(to: NSSelectorFromString("accessibilityIdentifier")) ? object.value(forKey: "accessibilityIdentifier") as? String ?? "" : ""
    }
    private static func rect(_ object: NSObject) -> NSRect? {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")), let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        let rect = value.rectValue
        return rect.width > 0 && rect.height > 0 && rect.width.isFinite && rect.height.isFinite ? rect : nil
    }
    private static func frame(_ id: String, in host: NSView) -> NSRect? {
        objects(in: host).filter { identifier($0) == id }.compactMap(rect).max { $0.width * $0.height < $1.width * $1.height }
    }
    private static func text(_ id: String, in host: NSView) -> String {
        objects(in: host).filter { identifier($0) == id }.flatMap { objects(in: $0) }.flatMap { object in
            ["accessibilityLabel", "accessibilityValue"].compactMap { key in
                object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) as? String : nil
            }
        }.joined(separator: " ")
    }
    private static func innerScroll(_ card: String, in host: NSView) -> NSScrollView? {
        guard let area = frame(card, in: host), let window = host.window else { return nil }
        return objects(in: host).compactMap { $0 as? NSScrollView }.filter { scroll in
            guard scroll.window === window, !scroll.isHiddenOrHasHiddenAncestor, scroll.documentView != nil else { return false }
            let rect = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            return rect.width > area.width * 0.8 && rect.width <= area.width + 2 && rect.height < area.height && area.insetBy(dx: -2, dy: -2).contains(rect)
        }.max { $0.bounds.height < $1.bounds.height }
    }
    private static func extent(_ scroll: NSScrollView) -> CGFloat { max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height) }
    private static func moveToBottom(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView, extent(scroll) > 20 else { return false }
        let offset = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height) : document.bounds.minY
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.origin.x, y: offset)); scroll.reflectScrolledClipView(scroll.contentView)
        return abs(scroll.contentView.bounds.origin.y - offset) < 1
    }
    private static func settle(_ window: NSWindow, timeout: Duration = .seconds(2), until predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if predicate() { try? await Task.sleep(for: .milliseconds(35)); window.contentView?.layoutSubtreeIfNeeded(); if predicate() { return true } }
            try? await Task.sleep(for: .milliseconds(15))
        } while ContinuousClock.now < deadline
        return predicate()
    }
}

@MainActor private final class CalendarLayoutSystem: CalendarSystemProviding {
    var permissionRequests = 0, writes = 0
    var failEvents = false
    var eventsValue: [CalendarEventItem] = [], remindersValue: [ReminderItem] = []
    func access(reminders: Bool) -> CalendarAccess { .granted }
    func requestAccess(reminders: Bool) async throws -> Bool { permissionRequests += 1; return true }
    func calendarSources() -> [CalendarSourceDescriptor] { [.init(id: "fixture-calendar", title: "隔离日历")] }
    func events(in interval: DateInterval) throws -> [CalendarEventItem] {
        if failEvents { throw ReminderError.unavailable("Isolated calendar read failure") }
        return eventsValue.filter { $0.start < interval.end && $0.end > interval.start }
    }
    func reminders() async throws -> [ReminderItem] { remindersValue }
    func writableReminderCalendars() -> [ReminderCalendar] { [.init(id: "fixture-list", title: "隔离提醒")] }
    func saveReminder(_ item: ReminderItem, creating: Bool) throws -> ReminderItem { writes += 1; throw ReminderError.unavailable("Isolated fixture does not write system reminders") }
    func deleteReminder(_ item: ReminderItem) throws { writes += 1; throw ReminderError.unavailable("Isolated fixture does not delete system reminders") }
}
@MainActor private final class CalendarLayoutNotifications: ReminderNotificationProviding {
    var permissionRequests = 0, nonemptyDeliveries = 0
    func access() async -> CalendarAccess { .denied }
    func requestAccess() async throws -> Bool { permissionRequests += 1; return false }
    func replacePending(_ notifications: [ReminderNotification]) async throws { if !notifications.isEmpty { nonemptyDeliveries += 1 } }
}
@MainActor private final class CalendarLayoutAINotifications: AIQuotaNotificationProviding {
    func permission() async -> AIQuotaNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func deliver(_ event: AIQuotaAlertEvent) async throws { throw AIUsageError.invalid("Isolated calendar fixture") }
}
