import AppKit
import LauncherCore

/// Called only with the existing isolated, service-disabled workbench fixture.
/// Measures mounted production views, including resize transitions, rather than
/// checking constants from the implementation. No pointer events are injected.
@MainActor
enum WorkbenchResponsiveLayoutChecks {
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
        // Alternate widths in the same hosting view. A stale initial 864 pt
        // state therefore fails the actual compact ratio and summary checks.
        let sizes: [(window: NSSize, page: CGFloat)] = [
            (.init(width: 1120, height: 758), 864),
            (.init(width: 960, height: 720), 704),
            (.init(width: 1349, height: 900), 1093),
            (.init(width: 1350, height: 900), 1094),
            (.init(width: 1351, height: 900), 1095),
            (.init(width: 1728, height: 993), 1360),
            (.init(width: 1920, height: 1080), 1360),
            (.init(width: 1120, height: 758), 864),
            (.init(width: 960, height: 720), 704)
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
                model.navigate(route)
                _ = await wait(window) {
                    frame("workbench-sidebar", in: host) != nil && frame("workbench-chrome", in: host) != nil
                        && frame(route == .settings ? "settings-navigation-general" : "navigation-" + route.rawValue, in: host) != nil
                        && (route != .settings || model.settingsTab != .general || frame("updates-current-version", in: host) != nil)
                }
                let chrome = frame("workbench-chrome", in: host), sidebar = frame("workbench-sidebar", in: host)
                let navigation = frames(prefix: route == .settings ? "settings-navigation-" : "navigation-", in: host)
                let hostScreen = window.convertToScreen(host.convert(host.bounds, to: nil))
                // SwiftUI exposes a containing AX group's children as its
                // frame, so the chrome's accessibility height can be its 32 pt
                // controls rather than the full surface. Measure the real
                // content boundary below it, independent of the control glyphs.
                let chromeHeight = sidebar.map { hostScreen.maxY - $0.maxY - 1 }
                let chromeSurface = sidebar.map { CGRect(x: hostScreen.minX + 1, y: $0.maxY,
                    width: hostScreen.width - 2, height: hostScreen.maxY - $0.maxY - 1) }
                check(chromeHeight.map { abs($0 - 46) < 1 } == true
                      && sidebar.map { abs($0.width - 184) < 1 && abs($0.minX - hostScreen.minX - 1) < 1 } == true
                      && chromeSurface.flatMap { surface in chrome.map { surface.insetBy(dx: -0.5, dy: -0.5).contains($0) } } == true,
                      "\(route.rawValue) preserves its 46 pt chrome and 184 pt sidebar across resize in \(label)")
                let outerViewport = route == .cleaning ? nil : outerPageScrollView(in: host).map { $0.convert($0.bounds, to: host) }
                print("DETAIL responsive shell \(route.rawValue) \(label) hostScreen=\(hostScreen) chromeAX=\(String(describing: chrome)) sidebarAX=\(String(describing: sidebar)) measuredChromeHeight=\(String(describing: chromeHeight)) outerViewport=\(String(describing: outerViewport))")
                check(!navigation.isEmpty && navigation.allSatisfy { abs($0.height - 42) < 1 },
                      "\(route.rawValue) keeps 42 pt navigation rows across resize in \(label)")
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
                guard let status = frame("home-device-summary", in: host), let metrics = frame("home-device-metrics", in: host),
                      frame("home-memory-ring", in: host) != nil, frame("home-pressure-summary", in: host) != nil else { return false }
                return sample.page < 760 ? abs(status.width - sample.page) < 2 && abs(metrics.width - sample.page) < 2
                    : abs(status.width + metrics.width + 12 - sample.page) < 3
            }
            let status = frame("home-device-summary", in: host), metrics = frame("home-device-metrics", in: host)
            let memoryRing = frame("home-memory-ring", in: host), pressure = frame("home-pressure-summary", in: host)
            let temperature = frame("home-temperature-readout", in: host), fans = frame("home-fan-readout", in: host)
            check(metrics.flatMap { card in temperature.flatMap { readings in fans.map { fanReadings in
                card.insetBy(dx: -1, dy: -1).contains(readings) && card.insetBy(dx: -1, dy: -1).contains(fanReadings)
            } } } == true && frame("home-storage-readout", in: host) == nil && frame("home-memory-readout", in: host) == nil,
                  "home device summary fits temperature and fan readings without repeating storage or memory in \(label)")
            check(memoryRing.flatMap { ring in pressure.map { text in
                ring.maxX + 12 <= text.minX && min(ring.maxY, text.maxY) - max(ring.minY, text.minY) > 24
            } } == true, "home memory ring and pressure explanation remain beside each other without vertical stacking in \(label)")
            check(status.flatMap { card in memoryRing.flatMap { ring in pressure.map { text in
                card.insetBy(dx: -1, dy: -1).contains(ring) && card.insetBy(dx: -1, dy: -1).contains(text)
            } } } == true, "home memory ring and explanation stay inside their actual card in \(label)")
            if sample.page < 760 {
                check(status.flatMap { top in metrics.map { bottom in
                    abs(top.width - sample.page) < 2 && abs(bottom.width - sample.page) < 2
                        && abs(top.minX - bottom.minX) < 1 && bottom.maxY <= top.minY - 10
                } } == true, "compact home reflows its two summary cards into full-width nonoverlapping rows in \(label)")
            } else {
                check(status.flatMap { left in metrics.map { right in
                    abs(left.maxY - right.maxY) < 1 && abs(right.minX - left.maxX - 12) < 1
                        && abs(left.width + right.width + 12 - sample.page) < 3
                } } == true, "home summary cards share a top edge and a 12 pt horizontal gap in \(label)")
            }
            print("DETAIL home-summary \(label) status=\(String(describing: status)) metrics=\(String(describing: metrics)) ring=\(String(describing: memoryRing)) pressure=\(String(describing: pressure))")
            let events = frame("fc.home.agenda.events", in: host), reminders = frame("fc.home.agenda.reminders", in: host)
            let listHeight: CGFloat = 112
            check(events.map { abs($0.height - listHeight) < 1 } == true && reminders.map { abs($0.height - listHeight) < 1 } == true,
                  "mounted home schedule and reminder scroll viewports keep their independent 112 pt height in \(label)")
            if sample.page > 1200 {
                let agenda = frame("fc.home.agenda", in: host)
                check(agenda.flatMap { card in
                    frame("fc.home.calendar.strip", in: host).map { strip in card.contains(strip) &&
                        events.map { card.contains($0) } == true && reminders.map { card.contains($0) } == true }
                } == true, "large home agenda fits the shared date tiles and both independent lists without clipping")
                print("DETAIL responsive home \(label) agenda=\(String(describing: agenda)) events=\(String(describing: events)) reminders=\(String(describing: reminders))")
            }

            let day = model.calendar.displayCalendar.dateComponents([.year, .month, .day], from: Date())
            let dayKey = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
            let homeDay = frame("fc.home.calendar.day." + dayKey, in: host)
            model.calendar.goToToday(); model.calendar.presentationMode = .month
            model.navigate(.calendar)
            _ = await wait(window) {
                guard let month = frame("fc.calendar.monthCard", in: host), let side = frame("fc.calendar.sideColumn", in: host),
                      frame("fc.calendar.day." + dayKey, in: host) != nil else { return false }
                if sample.page < 760 { return abs(month.width - sample.page) < 2 && abs(side.width - sample.page) < 2 && side.maxY < month.minY }
                return abs(month.width + side.width + 12 - sample.page) < 3 && (0.31...0.37).contains(side.width / (sample.page - 12))
            }
            let month = frame("fc.calendar.monthCard", in: host), side = frame("fc.calendar.sideColumn", in: host)
            let monthDay = frame("fc.calendar.day." + dayKey, in: host)
            check(homeDay.flatMap { home in monthDay.map { month in
                home.height >= 54 && month.height >= 54 &&
                (1.0...1.7).contains(home.width / home.height) && (1.0...1.7).contains(month.width / month.height) &&
                abs(home.width / home.height - month.width / month.height) < 0.30
            } } == true, "home and main calendar date cells retain comparable readable proportions in \(label)")
            if sample.page >= 760, let month, let side {
                calendarWidths.append((sample.page, month.width, side.width))
                check(abs(month.width + side.width + 12 - sample.page) < 3 &&
                      (0.31...0.37).contains(side.width / (sample.page - 12)),
                      "calendar and agenda share the available width in \(label)")
            } else {
                check(month.flatMap { top in side.map { bottom in abs(top.width - bottom.width) < 2 && bottom.maxY <= top.minY - 10 } } == true,
                      "compact calendar reflows both side cards below its month without squeezing the date grid")
            }
            print("DETAIL calendar proportions \(label) month=\(String(describing: month)) side=\(String(describing: side)) homeDay=\(String(describing: homeDay)) monthDay=\(String(describing: monthDay))")

            model.navigate(.network)
            _ = await wait(window) { !frames(prefix: "fc.network.day-label.", in: host).isEmpty }
            let dates = frames(prefix: "fc.network.day-label.", in: host)
            check(!dates.isEmpty && dates.allSatisfy { $0.width > 0 && $0.height <= 16 },
                  "mounted network day labels, including the current day marker, remain a single line in \(label)")
        }
        if let regular = calendarWidths.first(where: { $0.page == 864 }), let large = calendarWidths.first(where: { $0.page == 1360 }) {
            check(large.side > regular.side + 140 && large.month > regular.month + 280,
                  "enlarging the workbench grows both calendar and agenda columns rather than freezing the agenda width")
        } else { check(false, "calendar width verification covers both normal and large windows") }
        let scrolling = await checkFullPageScrolling(model: model, window: window, host: host)
        count += scrolling.count; failures += scrolling.failures
        check(WorkbenchRoute(rawValue: "health") == nil, "the obsolete health route is removed from the navigation model")
        print("Responsive layout checks: \(count - failures)/\(count) passed")
        return (count, failures)
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
        let routes: [(WorkbenchRoute, String)] = [(.overview, "fc.page.home"), (.device, "fc.page.device"), (.calendar, "fc.page.calendar"), (.ai, "fc.page.usage"), (.network, "fc.page.network"), (.vault, "fc.page.vault"), (.cards, ""), (.settings, "fc.page.settings.general")]
        let samples: [(NSSize, CGFloat)] = [(.init(width: 1120, height: 758), 184), (.init(width: 960, height: 720), 184), (.init(width: 1728, height: 993), 184)]
        for (size, sidebarWidth) in samples {
            window.setContentSize(size)
            let label = "\(Int(size.width))×\(Int(size.height))"
            for (route, identifier) in routes {
                model.deviceDetail = nil; model.ai.showOverview(); model.settingsTab = .general
                model.calendar.showSources = false; model.vault.showingProtection = false
                model.navigate(route)
                let mounted = await wait(window) {
                    guard let scroll = outerPageScrollView(in: host) else { return false }
                    if identifier.isEmpty {
                        return scroll.documentView.map { containsAccessibilityText("把常用信息留在桌面，也可设为悬浮显示", in: $0) } == true
                    }
                    return frame(identifier, in: host) != nil
                }
                guard mounted, let scroll = outerPageScrollView(in: host) else {
                    check(false, "\(route.rawValue) mounts its actual outer scroll viewport in \(label)"); continue
                }
                let viewport = scroll.convert(scroll.bounds, to: host)
                check(abs(viewport.minX - (host.bounds.minX + sidebarWidth + 1)) <= 1
                      && abs(viewport.maxX - (host.bounds.maxX - 1)) <= 1,
                      "\(route.rawValue) viewport spans from the sidebar to the window edge, allowing only its 1 pt border in \(label)")
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

    private static func wait(_ window: NSWindow, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
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
