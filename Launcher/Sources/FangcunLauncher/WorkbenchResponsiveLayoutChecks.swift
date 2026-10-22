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
        guard !model.modals.isPresented, model.health.phase == .overview, !model.device.isSampling else {
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
        let sizes: [(window: NSSize, page: CGFloat, sidebar: CGFloat, ring: CGFloat, button: CGFloat)] = [
            (.init(width: 1120, height: 758), 864, 184, 146, 126),
            (.init(width: 960, height: 720), 736, 160, 126, 120),
            (.init(width: 1728, height: 993), 1360, 248, 164, 126),
            (.init(width: 1920, height: 1080), 1360, 264, 164, 126),
            (.init(width: 960, height: 720), 736, 160, 126, 120)
        ]
        for sample in sizes {
            let label = "\(Int(sample.window.width))×\(Int(sample.window.height))"
            window.setContentSize(sample.window)
            model.ai.showOverview(); model.navigate(.ai)
            _ = await wait(window) {
                guard let left = frame("fc.ai.overview.tokens", in: host), let right = frame("fc.ai.overview.models", in: host) else { return false }
                return abs(left.width + right.width + 12 - sample.page) < 2
            }
            let left = frame("fc.ai.overview.tokens", in: host), right = frame("fc.ai.overview.models", in: host)
            let sidebar = frame("workbench-sidebar", in: host)
            check(sidebar.map { abs($0.width - sample.sidebar) < 1 } == true,
                  "mounted shared navigation uses the balanced \(Int(sample.sidebar)) pt width in \(label)")
            let ratio: CGFloat = sample.page < 800 ? 1.25 : 1.55
            let expectedLeft = (sample.page - 12) * ratio / (1 + ratio)
            check(left.map { abs($0.width - expectedLeft) < 2 } == true &&
                  right.map { abs($0.width - (sample.page - 12 - expectedLeft)) < 2 } == true,
                  "mounted AI Token/model columns use the frozen responsive widths in \(label)")
            let total = frame("fc.ai.tokens.total", in: host), parts = frame("fc.ai.tokens.parts", in: host)
            let summaryCorrect: Bool
            if let total, let parts {
                // Accessibility frames use AppKit screen coordinates: lower Y
                // is below the total, unlike the screenshot's top-down origin.
                summaryCorrect = sample.page < 800
                    ? parts.maxY <= total.minY - 5 && abs(parts.minX - total.minX) < 2
                    : parts.minY < total.maxY && total.minY < parts.maxY
            } else { summaryCorrect = false }
            check(summaryCorrect, "mounted AI token breakdown moves below its total only at compact width in \(label)")
            print("DETAIL responsive AI \(label) columns=\(String(describing: left)) / \(String(describing: right)) total=\(String(describing: total)) parts=\(String(describing: parts))")

            model.navigate(.health)
            // Frozen care.css places the halo at inset:-7% on every side of
            // the nominal ring. The combined accessibility element includes
            // that 114% geometric envelope, rounded to AppKit screen pixels.
            let haloInset: CGFloat = 0.07
            let ringEnvelope = sample.ring * (1 + 2 * haloInset)
            _ = await wait(window) {
                frame("health-overview-score", in: host).map {
                    abs($0.width - ringEnvelope) < 1 && abs($0.height - ringEnvelope) < 1
                } == true
            }
            let ring = frame("health-overview-score", in: host), start = frame("health-start", in: host)
            let workspace = frame("health-workspace", in: host)
            let hostScreenBounds = window.convertToScreen(host.convert(host.bounds, to: nil))
            let workspaceTop = workspace.map { hostScreenBounds.maxY - $0.maxY }
            // Frozen back row: 28 pt plus 12 pt gap, then the 54 pt
            // page heading and 18 pt gap. Keep this page-local.
            let expectedWorkspaceTop: CGFloat = sample.page > 1200 ? 189 : sample.page < 800 ? 179 : 181
            check(workspaceTop.map { abs($0 - expectedWorkspaceTop) < 1 } == true,
                  "mounted health workspace starts at the frozen \(Int(expectedWorkspaceTop)) pt top after its 28 pt return row in \(label)")
            check(ring.map { abs($0.width - ringEnvelope) < 1 && abs($0.height - ringEnvelope) < 1 } == true,
                  "mounted health overview score keeps its \(Int(sample.ring)) pt nominal ring with the frozen 7%-per-side halo envelope in \(label)")
            check(start.map { abs($0.width - sample.button) < 2 && abs($0.height - 32) < 1 } == true,
                  "mounted health start action has the frozen minimum width and 32 pt height in \(label)")
            let factor = frame("health-overview-factor-storage", in: host), value = frame("health-overview-value-storage", in: host)
            let inset: CGFloat = sample.page < 800 ? 12 : 14
            check(factor.flatMap { card in value.map { abs($0.minX - card.minX - inset) < 1.5 } } == true,
                  "mounted health factor uses the frozen compact/regular inner inset in \(label)")
            print("DETAIL responsive health \(label) workspaceTop=\(String(describing: workspaceTop)) ringNominal=\(sample.ring) haloInset=\(haloInset) expectedRingEnvelope=\(ringEnvelope) ring=\(String(describing: ring)) start=\(String(describing: start)) factor=\(String(describing: factor)) value=\(String(describing: value))")

            model.navigate(.overview)
            _ = await wait(window) { frame("fc.home.agenda", in: host) != nil }
            let events = frame("fc.home.agenda.events", in: host), reminders = frame("fc.home.agenda.reminders", in: host)
            let listHeight: CGFloat = sample.page > 1200 ? 160 : 112
            check(events.map { abs($0.height - listHeight) < 1 } == true && reminders.map { abs($0.height - listHeight) < 1 } == true,
                  "mounted home schedule and reminder scroll viewports keep their frozen independent height in \(label)")
            if sample.page > 1200 {
                let agenda = frame("fc.home.agenda", in: host)
                check(agenda.map { abs($0.height - 367) < 1 } == true,
                      "mounted large home agenda keeps the complete 367 pt card instead of the old 352 pt card")
                print("DETAIL responsive home \(label) agenda=\(String(describing: agenda)) events=\(String(describing: events)) reminders=\(String(describing: reminders))")
            }

            model.navigate(.network)
            _ = await wait(window) { !frames(prefix: "fc.network.day-label.", in: host).isEmpty }
            let dates = frames(prefix: "fc.network.day-label.", in: host)
            check(!dates.isEmpty && dates.allSatisfy { $0.width > 0 && $0.height <= 16 },
                  "mounted network day labels, including the current day marker, remain a single line in \(label)")
        }
        let scrolling = await checkFullPageScrolling(model: model, window: window, host: host)
        count += scrolling.count; failures += scrolling.failures
        check(WorkbenchShellMetrics(viewport: .init(width: 3840, height: 2160)).sidebarWidth == 280,
              "ultrawide navigation has a 280 pt upper bound instead of consuming unlimited content width")
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
            model.health.showOverview(); model.navigate(originalRoute)
            model.device.dashboardScrollOffset = originalDeviceOffset
            window.setFrame(originalFrame, display: false)
        }
        let routes: [(WorkbenchRoute, String)] = [(.overview, "fc.page.home"), (.device, "fc.page.device"), (.health, "health-center"), (.calendar, "fc.page.calendar"), (.ai, "fc.page.ai"), (.network, "fc.page.network"), (.vault, "fc.page.vault"), (.cards, ""), (.settings, "fc.page.settings.general")]
        let samples: [(NSSize, CGFloat)] = [(.init(width: 1120, height: 758), 184), (.init(width: 960, height: 720), 160), (.init(width: 1728, height: 993), 248)]
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
        _ = await wait(window) { frame("fc.page.ai", in: host) != nil && outerPageScrollView(in: host).map { scrollExtent($0) > 20 } == true }
        if let oldScroll = outerPageScrollView(in: host) {
            model.ai.manualDraft.note = "Unsaved scroll-regression draft"
            let draft = model.ai.manualDraft, aiIdentity = ObjectIdentifier(model.ai)
            let selectedPeriod = model.ai.selectedPeriod, selectedProvider = model.ai.selectedProvider
            let startedAtBottom = moveToBottom(oldScroll)
            check(startedAtBottom, "the real AI overview starts this regression at a nonzero bottom offset")
            let oldOffset = oldScroll.contentView.bounds.origin.y
            model.ai.show(.provider(.codex))
            let reset = await wait(window) { frame("fc.page.ai.codex", in: host) != nil && outerPageScrollView(in: host).map(isAtTop) == true }
            let detailScroll = outerPageScrollView(in: host)
            check(reset && detailScroll === oldScroll && window.contentView === host,
                  "opening Codex details resets the same mounted generic page viewport to the top")
            check(detailScroll.map { scrollExtent($0) > 20 } == true,
                  "Codex details remain scrollable, so the top reset cannot be explained by short-content clamping")
            check(ObjectIdentifier(model.ai) == aiIdentity && model.ai.manualDraft == draft
                  && model.ai.selectedPeriod == selectedPeriod && model.ai.selectedProvider == selectedProvider,
                  "AI detail navigation preserves the same model, unsaved form draft and activity filters")
            print("DETAIL ai-detail-scroll oldY=\(oldOffset) detailY=\(detailScroll?.contentView.bounds.origin.y ?? -1) detailExtent=\(detailScroll.map(scrollExtent) ?? -1)")
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
