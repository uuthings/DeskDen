import AppKit
import SwiftUI
import LauncherCore

@MainActor enum DeviceMonitoringFormChecks {
    static func run() async -> Int {
        let menus = await DeviceProcessActionMenuChecks.run()
        var count = menus.count, failures = menus.failures
        func check(_ condition: Bool, _ label: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let legacyBattery = DeviceBatterySnapshot(percent: 77, isCharging: false, isPluggedIn: false, timeRemainingMinutes: nil, health: nil, maximumCapacityPercent: nil)
        check(legacyBattery.cycleCount == nil, "legacy battery initialization keeps unavailable cycle count distinct from zero")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-device-forms-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = FormCheckNotifications()
        let model = DeviceStatusModel(dataDirectory: dir, notifications: service)
        let drafts = DeviceMonitoringDrafts(); drafts.load(model)
        check(!drafts.budgetDirty && !drafts.temperatureDirty, "monitoring forms start from persisted rules without a dirty state")
        check(service.requests == 0, "loading form drafts never prompts for notification permission")
        check(DeviceBudgetDraft.number(DeviceBudgetDraft.numberText(100.123456)) == 100.123456, "form reload preserves legal numeric precision")
        check(DeviceTrafficDisplay.gigabytes(1_800_000) != DeviceTrafficDisplay.gigabytes(0), "small measured traffic is not formatted as zero GB")
        drafts.budget.enabled = true; drafts.budget.limit = "10abc"; drafts.budget.warning = "80.5"
        await drafts.saveBudget(model)
        check(drafts.budgetErrors["limit"] != nil && drafts.budgetErrors["warning"] != nil, "form validation rejects numeric suffixes and fractional warning percentages")
        check(!model.budget.enabled, "invalid budget draft does not change the active rule")
        check(DeviceBudgetDraft.number("nan")?.isFinite == false && DeviceBudgetDraft.number("1abc") == nil, "whole-string number parser never accepts a numeric prefix")
        drafts.budget.limit = "0.01"; drafts.budget.warning = "99"; drafts.budget.period = .week; drafts.budget.scope = .wifi
        drafts.budget.notifications = false
        await drafts.saveBudget(model)
        check(model.budget.enabled && model.budget.limitGB == 0.01 && model.budget.period == .week && model.budget.scope == .wifi, "minimum legal budget and selected period/scope save to the real model")
        check(!drafts.budgetDirty && drafts.budgetStatus == "设置已保存", "successful budget save establishes a new clean baseline")
        check(service.requests == 0, "saving with notifications off does not request system permission")
        drafts.budget.limit = "12.5"
        check(DeviceRuleActions.statusText(dirty: drafts.budgetDirty, saving: false, status: drafts.budgetStatus) == "有未保存的修改", "editing again after a successful save shows unsaved changes")
        drafts.load(model)
        check(drafts.budget.limit == "12.5", "repeat view/size appearance preserves unsaved form values")
        drafts.restoreBudget(model)
        check(!drafts.budgetDirty && drafts.budget.limit == "0.01", "cancel restores the current saved budget")
        drafts.budget.enabled = false; drafts.budget.limit = "invalid"
        await drafts.saveBudget(model)
        check(!model.budget.enabled && model.budget.limitGB == 0.01, "disabling a budget preserves its saved numeric parameters")
        drafts.budget.enabled = true; drafts.budget.limit = "20"; drafts.budget.period = .month
        drafts.budget.usesAnchor = true
        let calendar = drafts.budget.calendar
        let januaryEnd = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12))!
        let february = NetworkBudgetDateSelection.replacing(.month, with: 2, in: januaryEnd, calendar: calendar)
        check(DeviceBudgetDate(february, calendar: calendar) == .init(year: 2026, month: 2, day: 28),
              "budget month dropdown clamps January 31 to February's last real day instead of overflowing to March")
        let leapDay = calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 12))!
        check(DeviceBudgetDate(NetworkBudgetDateSelection.replacing(.year, with: 2025, in: leapDay, calendar: calendar), calendar: calendar) == .init(year: 2025, month: 2, day: 28),
              "budget year dropdown clamps a leap day while preserving the ledger calendar timezone")
        let selectedDay = NetworkBudgetDateSelection.replacing(.day, with: 15, in: januaryEnd, calendar: calendar)
        check(DeviceBudgetDate(selectedDay, calendar: calendar) == .init(year: 2026, month: 1, day: 15),
              "budget day dropdown changes the chosen civil day without replacing its year or month")
        let canvas = CGSize(width: 420, height: 154), tooltip = CGSize(width: 218, height: 112)
        let tallTip = NetworkTrafficTooltipPlacement.frame(anchor: CGRect(x: 8, y: 0, width: 20, height: 130), canvas: canvas, size: tooltip)
        let middleTip = NetworkTrafficTooltipPlacement.frame(anchor: CGRect(x: 390, y: 60, width: 20, height: 70), canvas: canvas, size: tooltip)
        check(CGRect(origin: .zero, size: canvas).contains(tallTip) && CGRect(origin: .zero, size: canvas).contains(middleTip) && tallTip.minX == 0 && middleTip.maxX == canvas.width,
              "network hover details stay inside the chart at both edge columns")
        check(tallTip.minY != middleTip.minY,
              "network hover details use each column's painted height rather than one shared tallest-column anchor")
        drafts.budget.anchor = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!
        await drafts.saveBudget(model)
        check(model.budget.cycleAnchor == .init(year: 2026, month: 10, day: 15), "billing anchor date saves without conversion into the machine's current timezone")
        check(model.trafficSummary.periodStart == model.budget.interval(at: model.trafficSummary.measuredAt, calendar: calendar).start,
              "saved billing rules refresh the dashboard's real accounting interval immediately")
        drafts.budget.period = .custom
        drafts.budget.customStart = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!
        drafts.budget.customEnd = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))!
        await drafts.saveBudget(model)
        check(drafts.budgetErrors["dates"] != nil && model.budget.period == .month, "reversed custom dates remain a draft and never replace the active billing rule")
        drafts.budget.customEnd = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14))!
        await drafts.saveBudget(model)
        check(model.budget.period == .custom && model.budget.customEndInclusive == .init(year: 2026, month: 11, day: 14),
              "custom ending day is stored inclusively and reloaded by the form")
        check(model.trafficSummary.periodEnd == calendar.date(from: DateComponents(year: 2026, month: 11, day: 15))!,
              "custom saved summary counts through the end of the selected ending day")
        drafts.budget.customEnd = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        drafts.restoreBudget(model)
        check(DeviceBudgetDate(drafts.budget.customEnd, calendar: calendar) == .init(year: 2026, month: 11, day: 14), "cancel restores the saved inclusive ending date")
        drafts.temperature.enabled = true; drafts.temperature.cpu = "NaN"; drafts.temperature.duration = "3.5"
        await drafts.saveTemperature(model)
        check(drafts.temperatureErrors["cpu"] != nil && drafts.temperatureErrors["duration"] != nil && !model.temperatureRule.enabled, "invalid temperature values never become active monitoring rules")
        drafts.temperature.cpu = "40"; drafts.temperature.gpu = "110"; drafts.temperature.duration = "3600"; drafts.temperature.cooldown = "1440"
        drafts.temperature.notifications = false
        await drafts.saveTemperature(model)
        check(model.temperatureRule.enabled && model.temperatureRule.sustainedSeconds == 3600 && model.temperatureRule.cooldownMinutes == 1440, "temperature editor accepts the same legal limits as the core rule")
        drafts.temperature.gpu = "90"; drafts.restoreTemperature(model)
        check(!drafts.temperatureDirty && drafts.temperature.gpu == "110", "temperature cancel restores the saved rule")
        let restored = DeviceStatusModel(dataDirectory: dir, notifications: service)
        check(restored.budget == model.budget && restored.temperatureRule == model.temperatureRule, "rules saved by forms survive model recreation")
        drafts.temperature.notifications = true
        await drafts.saveTemperature(model)
        check(service.requests == 1 && model.notificationPermission == .denied && !drafts.temperatureDirty, "explicit notification enabling saves rules even when authorization is denied")
        service.state = .authorized
        await model.refreshNotificationPermission()
        check(model.notificationPermission == .authorized, "permission status recovers after a system-settings change")
        #if DEBUG
        if CommandLine.arguments.contains("--form-check") {
            let current = drafts.budget
            for period: DeviceBudgetPeriod in [.week, .month, .custom] {
                drafts.budget.period = period
                let view = NSHostingView(rootView: DeviceBudgetSettingsView(model: model, drafts: drafts).preferredColorScheme(.dark).nativeCheckAccessibility())
                view.frame = NSRect(x: 0, y: 0, width: 365, height: 900)
                view.layoutSubtreeIfNeeded()
                print("Budget sizing diagnostic: \(period.rawValue) = \(view.fittingSize.width) pt")
                let budgetView = DeviceBudgetSettingsView(model: model, drafts: drafts)
                for (name, part) in budgetView.sizingPartsForChecks {
                    let partView = NSHostingView(rootView: part.nativeCheckAccessibility())
                    partView.frame = NSRect(x: 0, y: 0, width: 337, height: 900)
                    partView.layoutSubtreeIfNeeded()
                    print("  \(name): \(partView.fittingSize.width) pt")
                }
            }
            drafts.budget = current
        }
        #endif
        for width: CGFloat in [365, 438, 554] {
            let view = NSHostingView(rootView: DeviceBudgetSettingsView(model: model, drafts: drafts).preferredColorScheme(.dark).nativeCheckAccessibility())
            view.frame = NSRect(x: 0, y: 0, width: width, height: 650)
            view.layoutSubtreeIfNeeded()
            let fittingWidth = view.fittingSize.width
            if fittingWidth > width + 1 { print("Budget form measured \(fittingWidth) pt for available \(width) pt") }
            check(fittingWidth <= width + 1, "budget form remains horizontally contained at \(Int(width)) pt")
        }
        let savedDraft = drafts.budget
        for period: DeviceBudgetPeriod in [.week, .month, .quarter, .year] {
            drafts.budget.period = period
            let view = NSHostingView(rootView: DeviceBudgetSettingsView(model: model, drafts: drafts).preferredColorScheme(.dark).nativeCheckAccessibility())
            view.frame = NSRect(x: 0, y: 0, width: 365, height: 900); view.layoutSubtreeIfNeeded()
            check(view.fittingSize.width <= 366, "\(period.rawValue) budget form and cycle help remain contained at 365 pt")
        }
        drafts.budget = savedDraft
        for year in [2020, 2030] {
            drafts.budget.customStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
            drafts.budget.customEnd = calendar.date(from: DateComponents(year: year, month: 1, day: 31))!
            let view = NSHostingView(rootView: DeviceBudgetSettingsView(model: model, drafts: drafts).preferredColorScheme(.dark).nativeCheckAccessibility())
            view.frame = NSRect(x: 0, y: 0, width: 365, height: 900); view.layoutSubtreeIfNeeded()
            check(view.fittingSize.width <= 366, "custom \(year) budget status explanation remains contained at 365 pt")
        }
        drafts.budget = savedDraft
        let budgetControl = await checkBudgetControl(model: model, drafts: drafts)
        count += budgetControl.count; failures += budgetControl.failures
        let networkHover = await checkNetworkHover()
        count += networkHover.count; failures += networkHover.failures
        print("Device monitoring form checks: \(count - failures)/\(count) passed")
        return failures
    }

    /// Mount the actual dialog rather than a lookalike Toggle. Changing the
    /// switch edits a draft only; model persistence still requires Save.
    private static func checkBudgetControl(model: DeviceStatusModel, drafts: DeviceMonitoringDrafts) async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        drafts.restoreBudget(model)
        let saved = model.budget
        let host = NSHostingView(rootView: DeviceBudgetDialog(model: model, drafts: drafts, dismiss: {})
            .background(WorkbenchMaterialSurface(kind: .panel, radius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.70, backgroundMotion: false)
            .preferredColorScheme(.dark).nativeCheckAccessibility())
        let window = NativeUIFixtureWindow(contentRect: NSRect(x: 260, y: 160, width: 470, height: 670), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close(); drafts.restoreBudget(model) }
        let ready = await NativeUIFixtureWindow.prepare(window: window) {
            let controls = budgetSwitches(in: host)
            return controls.count == 1 && controls[0].window === window
                && !controls[0].isHiddenOrHasHiddenAncestor && controls[0].bounds.width > 0 && controls[0].bounds.height > 0
        }
        check(ready, "the budget dialog has an active key-capable visible host with its real native switch before interaction checks")
        if !ready { describeBudgetHost(host, window: window) }
        let controls = budgetSwitches(in: host)
        check(controls.count == 1, "the actual production budget dialog mounts exactly one typed native NSSwitch")
        if ProcessInfo.processInfo.environment["FANGCUN_HOVER_VISUAL_DIR"] != nil {
            check(captureNetworkEvidence(host, name: "network-budget-date-selectors"),
                  "the production budget dialog exports its actual year/month/day dropdown layout")
        }
        if controls.count == 1, let control = controls.first, control.window === window {
            let rect = window.convertToScreen(control.convert(control.bounds, to: nil))
            let root = window.convertToScreen(host.convert(host.bounds, to: nil))
            print("DETAIL native budget control type=\(type(of: control)) controlSize=\(control.controlSize.rawValue) state=\(control.state.rawValue) root=\(NSStringFromRect(root)) switch=\(NSStringFromRect(rect))")
            check(control.controlSize == .mini && rect.width >= 24 && rect.width <= 38 && rect.height >= 14 && rect.height <= 24,
                  "the real budget enable switch uses compact native dimensions without a stretched Toggle label")
            check(abs(rect.maxX - (root.maxX - 18)) <= 2,
                  "the actual budget enable switch sits at the far-right 18-point dialog content boundary")
            let before = drafts.budget.enabled
            let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            }
            if let down = mouse(.leftMouseDown), let up = mouse(.leftMouseUp) {
                // Native controls can track synchronously inside mouseDown.
                // Queue mouseUp first so that tracking has a real release event.
                NSApp.postEvent(up, atStart: false)
                NSApp.sendEvent(down)
            }
            for _ in 0..<30 {
                if drafts.budget.enabled != before { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            check(drafts.budget.enabled != before && control.state == (drafts.budget.enabled ? .on : .off)
                    && drafts.budgetDirty && model.budget == saved,
                  "clicking the mounted real budget switch changes only the draft, preserving the active saved rule")
        } else {
            if ready { describeBudgetHost(host, window: window) }
            check(false, "the actual budget dialog exposes its native enabled switch after mounting")
        }
        return (count, failures)
    }

    /// Real production chart plus a disposable measured ledger. The pointer
    /// enters the painted bottoms of two unequal bars; no click or action
    /// closure can open the details and accidentally satisfy this regression.
    private static func checkNetworkHover() async -> (count: Int, failures: Int) {
        #if DEBUG
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-network-hover-\(UUID().uuidString)")
        let notifications = FormCheckNotifications()
        let model = DeviceStatusModel(dataDirectory: directory, notifications: notifications)
        let pointerBefore = CGEvent(source: nil)?.location
        let keyBefore = NSApp.keyWindow, mainBefore = NSApp.mainWindow
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NativeUIFixtureWindow(contentRect: NSRect(x: visible.midX - 492, y: visible.midY - 380, width: 984, height: 760),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
        defer {
            model.stop(); window.orderOut(nil); window.contentView = nil; window.close()
            if let mainBefore, mainBefore.isVisible { mainBefore.makeMain() }
            if let keyBefore, keyBefore.isVisible { keyBefore.makeKey() }
            if let pointerBefore { postNetworkPointer(pointerBefore) }
            try? FileManager.default.removeItem(at: directory)
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
        var accumulator = DeviceTrafficAccumulator(ledger: .init(now: first, timeZone: calendar.timeZone))
        var received: UInt64 = 100, sent: UInt64 = 100
        let totals: [UInt64] = [50_000_000, 200_000_000, 20_000_000, 80_000_000]
        for (index, total) in totals.enumerated() {
            let start = calendar.date(byAdding: .day, value: index, to: first)!
            accumulator.breakContinuity()
            accumulator.ingest(wifi: ["synthetic-network": .init(received: received, sent: sent)], ethernet: [:], at: start, maximumGap: 6)
            received += total * 3 / 4; sent += total / 4
            accumulator.ingest(wifi: ["synthetic-network": .init(received: received, sent: sent)], ethernet: [:], at: start.addingTimeInterval(2), maximumGap: 6)
        }
        let observed = calendar.date(byAdding: .day, value: 3, to: first)!.addingTimeInterval(2)
        var snapshot = DeviceSnapshot(); snapshot.sampledAt = observed
        await model.evaluateMonitoringForChecks(snapshot: snapshot, ledger: accumulator.ledger, at: observed)
        let originalSummary = model.trafficSummary
        let highDate = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: first)!)
        let lowDate = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 2, to: first)!)
        let highID = "fc.network.day-bar." + String(Int(highDate.timeIntervalSince1970))
        let lowID = "fc.network.day-bar." + String(Int(lowDate.timeIntervalSince1970))
        let host = NSHostingView(rootView: NetworkMonitorView(model: model)
            .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.70, backgroundMotion: false)
            .preferredColorScheme(.dark).nativeCheckAccessibility())
        window.contentView = host
        let mounted = await NativeUIFixtureWindow.prepare(window: window) {
            networkFrame(highID, in: host) != nil && networkFrame(lowID, in: host) != nil
        }
        check(mounted && model.trafficSummary.dailyUsage.contains { $0.totalBytes == 200_000_000 } &&
              model.trafficSummary.dailyUsage.contains { $0.totalBytes == 20_000_000 },
              "production network chart mounts distinct high and low measured columns in its isolated native host")
        guard mounted, let high = networkFrame(highID, in: host), let low = networkFrame(lowID, in: host) else { return (count, failures) }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        func move(_ screen: NSPoint) async {
            postNetworkPointer(CGPoint(x: screen.x, y: primaryTop - screen.y))
            try? await Task.sleep(for: .milliseconds(160)); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        func waitForTip(_ date: Date) async -> NSRect? {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = calendar.timeZone; formatter.dateFormat = "M 月 d 日"
            let dateText = formatter.string(from: date)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            repeat {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let hasDate = networkObjects(host).contains { object in
                    ["accessibilityLabel", "accessibilityValue"].contains { field in networkString(field, from: object) == dateText }
                }
                if hasDate, let frame = networkFrame("fc.network.day-tooltip", in: host) { return frame }
                try? await Task.sleep(for: .milliseconds(25))
            } while ContinuousClock.now < deadline
            return nil
        }
        await move(NSPoint(x: window.frame.minX + 8, y: window.frame.minY + 8))
        check(networkFrame("fc.network.day-tooltip", in: host) == nil,
              "network chart starts without any selected or visible hover tooltip")
        await move(NSPoint(x: high.midX, y: high.minY + 4))
        let highTip = await waitForTip(highDate)
        check(highTip != nil, "OS hover alone opens the high column's dated traffic details without a mouse click")
        if ProcessInfo.processInfo.environment["FANGCUN_HOVER_VISUAL_DIR"] != nil {
            check(captureNetworkEvidence(host, name: "network-hover-high"), "high-column native hover exports its actual chart screenshot")
        }
        await move(NSPoint(x: low.midX, y: low.minY + 4))
        let lowTip = await waitForTip(lowDate)
        check(lowTip != nil, "moving the OS pointer to the low column replaces the tooltip with that day's details without a click")
        let hostBounds = window.convertToScreen(host.convert(host.bounds, to: nil))
        let barBounds = networkObjects(host).compactMap { object -> NSRect? in
            guard let identifier = networkString("accessibilityIdentifier", from: object),
                  identifier.hasPrefix("fc.network.day-bar.") else { return nil }
            return networkObjectFrame(object)
        }.reduce(NSRect.null) { $0.union($1) }
        // A full bar target excludes the day-label line beneath it. Its actual
        // plot bounds plus that short label line are the chart canvas.
        let chartBounds = NSRect(x: barBounds.minX, y: barBounds.minY - 24, width: barBounds.width, height: barBounds.height + 24)
        check(highTip.flatMap { h in lowTip.map { l in
            abs(h.minY - l.minY) > 8 && hostBounds.contains(h) && hostBounds.contains(l) &&
                chartBounds.insetBy(dx: -1, dy: -1).contains(h) && chartBounds.insetBy(dx: -1, dy: -1).contains(l)
        } } == true, "actual high and low hover panels follow different painted heights and remain inside chart and window bounds")
        print("DETAIL network real hover highBar=\(high) lowBar=\(low) highTip=\(String(describing: highTip)) lowTip=\(String(describing: lowTip)) chart=\(chartBounds)")
        if ProcessInfo.processInfo.environment["FANGCUN_HOVER_VISUAL_DIR"] != nil {
            check(captureNetworkEvidence(host, name: "network-hover-low"), "low-column native hover exports its actual chart screenshot")
        }
        check(!model.isSampling && model.trafficSummary == originalSummary && notifications.requests == 0,
              "native chart hover neither starts sensors nor changes measured totals or requests permissions")
        return (count, failures)
        #else
        return (0, 0)
        #endif
    }

    private static func postNetworkPointer(_ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    private static func networkObjects(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = [], pending = [root], visited = Set<ObjectIdentifier>()
        while let object = pending.popLast(), visited.count < 8192 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }; result.append(object)
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending += children }
        }
        return result
    }
    private static func networkString(_ key: String, from object: NSObject) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        let value = object.value(forKey: key)
        return (value as? String) ?? (value as? NSAttributedString)?.string
    }
    private static func networkObjectFrame(_ object: NSObject) -> NSRect? {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")), let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        let frame = value.rectValue
        return frame.width > 0 && frame.height > 0 && frame.width.isFinite && frame.height.isFinite ? frame : nil
    }
    private static func networkFrame(_ id: String, in host: NSView) -> NSRect? {
        networkObjects(host).filter { networkString("accessibilityIdentifier", from: $0) == id }.compactMap(networkObjectFrame).max { $0.width * $0.height < $1.width * $1.height }
    }
    private static func captureNetworkEvidence(_ host: NSView, name: String) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["FANGCUN_HOVER_VISUAL_DIR"],
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count > 1000 else { return false }
        do {
            let output = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent(name + ".png")); return true
        } catch { print("DETAIL network native screenshot failed: \(error.localizedDescription)"); return false }
    }

    private static func describeBudgetHost(_ root: NSView, window: NSWindow) {
        var native: [String] = [], stack: [(NSView, Int)] = [(root, 0)]
        while let (view, depth) = stack.popLast(), native.count < 80 {
            native.append("\(depth):\(type(of: view)) isNSSwitch=\(view is NSSwitch) frame=\(NSStringFromRect(view.frame)) hidden=\(view.isHidden) axElement=\(view.isAccessibilityElement()) id=\(view.accessibilityIdentifier()) axChildren=\(view.accessibilityChildren()?.count ?? -1)")
            stack.append(contentsOf: view.subviews.reversed().map { ($0, depth + 1) })
        }
        var ax: [String] = [], pending: [(NSObject, Int)] = [(root, 0)], visited = Set<ObjectIdentifier>()
        while let (object, depth) = pending.popLast(), visited.count < 4096 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            func value(_ key: String) -> String {
                guard object.responds(to: NSSelectorFromString(key)) else { return "n/a" }
                return String(describing: object.value(forKey: key) ?? "nil")
            }
            if ax.count < 80 { ax.append("\(depth):\(type(of: object)) role=\(value("accessibilityRole")) id=\(value("accessibilityIdentifier")) label=\(value("accessibilityLabel")) frame=\(value("accessibilityFrame"))") }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews.reversed().map { ($0, depth + 1) }) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children.reversed().map { ($0, depth + 1) }) }
        }
        print("DETAIL budget host policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) visible=\(window.isVisible) key=\(window.isKeyWindow) canKey=\(window.canBecomeKey) occlusion=\(window.occlusionState.rawValue) window=\(NSStringFromRect(window.frame)) host=\(NSStringFromRect(root.frame)) axVisited=\(visited.count)")
        print("DETAIL budget native tree " + native.joined(separator: " | "))
        print("DETAIL budget AX tree " + ax.joined(separator: " | "))
    }

    /// SwiftUI's virtual AX identifiers are lazy without an external AX client.
    /// Its actual AppKit switch is already mounted and supports public geometry
    /// and mouse events, so inspect that real control without creating AX peers.
    private static func budgetSwitches(in root: NSView) -> [NSSwitch] {
        var pending = [root], controls: [NSSwitch] = []
        while let view = pending.popLast() {
            if let control = view as? NSSwitch { controls.append(control) }
            pending.append(contentsOf: view.subviews)
        }
        return controls
    }
}

@MainActor private final class FormCheckNotifications: DeviceNotificationProviding {
    var state: DeviceNotificationPermission = .notDetermined
    var requests = 0
    func permission() async -> DeviceNotificationPermission { state }
    func requestPermission() async throws -> Bool { requests += 1; state = .denied; return false }
    func deliver(_ event: DeviceMonitoringEvent, budget: DeviceTrafficBudget, rule: DeviceTemperatureRule) async throws { }
}
