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
        check(WorkbenchShellMetrics(viewport: .init(width: 3840, height: 2160)).sidebarWidth == 280,
              "ultrawide navigation has a 280 pt upper bound instead of consuming unlimited content width")
        print("Responsive layout checks: \(count - failures)/\(count) passed")
        return (count, failures)
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
