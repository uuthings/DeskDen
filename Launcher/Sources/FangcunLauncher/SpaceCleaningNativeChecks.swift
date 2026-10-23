import AppKit
import SwiftUI
import LauncherCore

/// Mounts the production shell and cleaning view with a disposable home. File
/// actions use real transactions but a temporary Trash directory, never the
/// user's Trash. AX geometry and owned-view renders are not external UI tests.
@MainActor enum SpaceCleaningNativeChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let manager = FileManager.default
        let rawRoot = manager.temporaryDirectory.appendingPathComponent("fangcun-space-native-\(UUID().uuidString)")
        let output = ProcessInfo.processInfo.environment["FANGCUN_SPACE_CLEANING_VISUAL_DIR"].map { URL(fileURLWithPath: $0) }
            ?? manager.temporaryDirectory.appendingPathComponent("fangcun-space-visual-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: rawRoot) }
        do {
            try manager.createDirectory(at: rawRoot, withIntermediateDirectories: true)
            guard let root = SpaceCleaningScanner.canonicalURL(rawRoot) else { throw SpaceCleaningFixtureError.invalid("fixture root is unavailable") }
            let home = root.appendingPathComponent("Home")
            let cache = home.appendingPathComponent("Library/Caches/pip/http-v2/rebuildable.cache")
            let download = home.appendingPathComponent("Downloads/installer.dmg")
            let otherDownload = home.appendingPathComponent("Downloads/screen-recording.mov")
            let testApp = home.appendingPathComponent("Developer/Builds/Fixture.app/Contents/Info.plist")
            let release = home.appendingPathComponent("Library/Application Support/Fixture/ReleaseArchives/1.0/release.dmg")
            for (url, bytes) in [(cache, 48_000), (download, 64_000), (otherDownload, 96_000), (testApp, 128), (release, 32_000)] {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x41, count: bytes).write(to: url)
            }
            for index in 0..<32 {
                try Data("isolated review file".utf8).write(to: home.appendingPathComponent("Downloads/review-\(index).data"))
            }
            try manager.createDirectory(at: output, withIntermediateDirectories: true)
            let cleaning = SpaceCleaningModel(dataDirectory: root.appendingPathComponent("Cleaning"), homeDirectory: home,
                                             mover: SpaceCleaningFixtureTrash(root: root, destination: root.appendingPathComponent("Trash")))
            let calendarSystem = SpaceCleaningFixtureCalendar()
            let calendarNotifications = SpaceCleaningFixtureCalendarNotifications()
            let calendar = CalendarModel(dataDirectory: root.appendingPathComponent("Calendar"), system: calendarSystem, notifier: calendarNotifications)
            let ai = AIUsageModel(dataDirectory: root.appendingPathComponent("AI"), startServices: false, notifications: SpaceCleaningFixtureAINotifications())
            let owner = LauncherController(dataDirectory: root.appendingPathComponent("Launcher"))
            owner.configuration.settings.workbenchTheme = .qingbiMist
            owner.configuration.settings.workbenchAppearance = .dark
            owner.configuration.settings.glassOpacity = 0.70
            owner.configuration.settings.backgroundMotionEnabled = false
            owner.configuration.settings.reduceMotion = true
            owner.configurePanel(); owner.scanning = true; owner.panel.isReleasedWhenClosed = false
            let app = WorkbenchAppModel(owner: owner, calendar: calendar, ai: ai, cleaning: cleaning, startServices: false)
            let controller = WorkbenchWindowController(owner: owner, model: app, autosavesFrame: false)
            owner.workbenchController = controller
            defer {
                app.shutdown(); controller.window?.orderOut(nil); controller.window?.delegate = nil
                controller.window?.contentView = nil; controller.window?.close()
                owner.panel?.orderOut(nil); owner.panel?.delegate = nil; owner.panel?.close()
                owner.hotKey.unregister(); owner.bindingHotKeys.unregister(); owner.toastTask?.cancel()
                owner.workbenchController = nil
            }
            guard let window = controller.window, let host = window.contentView else { throw SpaceCleaningFixtureError.invalid("production host missing") }
            app.navigate(.cleaning); app.setWindowVisible(true); app.syncAppearance()
            window.setContentSize(NSSize(width: 1120, height: 758)); window.ignoresMouseEvents = true
            let mounted = await NativeUIFixtureWindow.prepare(window: window) { exists("space-cleaning-start", in: host) }
            check(mounted, "space cleaning mounts inside the production workbench shell")
            check(cleaning.screen == .start && cleaning.items.isEmpty && cleaning.selectedCount == 0 && !cleaning.isBusy,
                  "opening cleaning does not scan, select or process files")
            check(exists("navigation-cleaning", in: host) && exists("window-brand-trigger", in: host) && exists("workbench-sidebar", in: host),
                  "cleaning retains the real brand, navigation and window shell")

            let sizes: [(String, NSSize)] = [("window", .init(width: 1120, height: 758)), ("compact", .init(width: 900, height: 620)), ("large", .init(width: 1728, height: 978))]
            for (name, size) in sizes {
                window.setContentSize(size)
                _ = await settle(window) { exists("space-cleaning-start", in: host) }
                let metrics = WorkbenchShellMetrics(viewport: size)
                let contentWidth = min(1360, size.width - metrics.sidebarWidth - 2 - metrics.contentGutter * 2)
                let module = frame("space-cleaning", in: host)
                check(module.map { abs($0.width - contentWidth) < 3 } == true,
                      "\(name) cleaning uses the shared content width without a second gutter")
                check(frame("workbench-sidebar", in: host).map { abs($0.width - metrics.sidebarWidth) < 2 } == true,
                      "\(name) cleaning preserves the production sidebar width")
                check(host.bounds.size == size, "\(name) cleaning keeps the native viewport size")
                try capture(host: host, name: "start-\(name)", output: output)
            }
            window.setContentSize(NSSize(width: 1120, height: 758))
            for theme in LauncherTheme.allCases {
                owner.configuration.settings.workbenchTheme = theme; app.syncAppearance()
                _ = await settle(window) { exists("space-cleaning-start", in: host) }
                check(app.theme == theme && exists("space-cleaning-disk", in: host), "\(theme.rawValue) cleaning inherits the shared theme and readable disk header")
            }
            owner.configuration.settings.workbenchTheme = .qingbiMist; app.syncAppearance()
            cleaning.startScan()
            check(cleaning.screen == .scanning && cleaning.selectedCount == 0, "explicit scan begins without selecting any candidate")
            await cleaning.waitUntilIdle()
            _ = await settle(window) { exists("space-cleaning-group-protected", in: host) }
            check(cleaning.screen == .results && cleaning.selectedCount == 0 && cleaning.checkedCount > 0,
                  "real isolated scan publishes checked entries with zero automatic selections")
            check(cleaning.items.allSatisfy { $0.url.path.hasPrefix(home.path + "/") }, "injected home keeps recommended scanning out of actual user directories")
            check(Set(cleaning.items.map(\.group)) == Set(CleaningResultGroup.allCases), "isolated cache, download and release fixtures populate all three real result groups")
            check(["rebuildable", "review", "protected"].allSatisfy { exists("space-cleaning-group-" + $0, in: host) }, "production results expose all three classified group controls")
            check(cleaning.expandedGroup == nil, "a completed scan starts with all three result groups collapsed")
            try capture(host: host, name: "results-window", output: output)
            guard let item = cleaning.items.first(where: { $0.url == download && $0.isSelectable }) else { throw SpaceCleaningFixtureError.invalid("download candidate unavailable") }
            guard let page = pageScroll(in: host) else { throw SpaceCleaningFixtureError.invalid("production page scroll missing") }
            let viewport = visiblePageFrame(page, in: host)
            check(frame("space-cleaning-selection-footer", in: host).map { $0.minY > viewport.minY + 10 } == true,
                  "short results keep the selection footer inside their natural surface")
            let sidebarBefore = frame("workbench-sidebar", in: host)
            cleaning.toggleGroup(.review); cleaning.toggleItem(item.id)
            _ = await settle(window) { (page.documentView?.bounds.height ?? 0) > page.contentView.bounds.height * 2 }
            move(page, fraction: 0.45)
            _ = await settle(window) {
                frame("space-cleaning-selection-footer", in: host).map { abs($0.minY - viewport.minY) < 3 } == true
            }
            check(frame("space-cleaning-selection-footer", in: host).map { abs($0.minY - viewport.minY) < 3 && $0.height >= 66 } == true,
                  "long results pin the same selection footer to the document viewport while scrolling")
            check(enabled("space-cleaning-review-continue", in: host) == true && frame("space-cleaning-review-continue", in: host).map(viewport.contains) == true,
                  "the selected-file action remains visible and enabled after scrolling the long list")
            check(frame("workbench-sidebar", in: host) == sidebarBefore && objects(host).compactMap { $0 as? NSScrollView }.count == 1,
                  "sticky selection preserves the fixed native shell and the single page scroll view")
            try capture(host: host, name: "results-long-list-scrolled", output: output)
            for (name, size) in sizes.dropFirst() {
                window.setContentSize(size)
                _ = await settle(window) { host.bounds.size == size }
                move(page, fraction: 0.45)
                _ = await settle(window) {
                    let visible = visiblePageFrame(page, in: host)
                    return frame("space-cleaning-selection-footer", in: host).map { abs($0.minY - visible.minY) < 3 } == true
                }
                let visible = visiblePageFrame(page, in: host)
                print("DETAIL sticky \(name) viewport=\(visible) footer=\(String(describing: frame("space-cleaning-selection-footer", in: host))) action=\(String(describing: frame("space-cleaning-review-continue", in: host))) clip=\(page.contentView.bounds)")
                check(frame("space-cleaning-selection-footer", in: host).map { abs($0.minY - visible.minY) < 3 } == true &&
                      frame("space-cleaning-review-continue", in: host).map(visible.contains) == true,
                      "\(name) long results keep the selection and continue action in the current viewport")
                try capture(host: host, name: "results-long-list-" + name, output: output)
            }
            window.setContentSize(NSSize(width: 1120, height: 758))
            move(page, fraction: 0); cleaning.toggleGroup(.review); cleaning.toggleItem(item.id)
            _ = await settle(window) { cleaning.selectedCount == 0 && exists("space-cleaning-group-protected", in: host) }
            cleaning.showDetail(item.id)
            _ = await settle(window) { exists("space-cleaning-file-detail", in: host) }
            check(frame("space-cleaning-file-detail", in: host).map { abs($0.width - 280) < 2 } == true, "normal-window file review uses the approved 280 pt side panel")
            check(host.bounds.size == NSSize(width: 1120, height: 758), "opening file review cannot grow the native window")
            try capture(host: host, name: "file-review-window", output: output)
            window.setContentSize(NSSize(width: 900, height: 620))
            _ = await settle(window) { exists("space-cleaning-file-detail", in: host) }
            check(frame("space-cleaning-file-detail", in: host).map { $0.width > 600 } == true, "compact file review reflows within the shared content column")
            try capture(host: host, name: "file-review-compact", output: output)
            window.setContentSize(NSSize(width: 1120, height: 758)); cleaning.closeDetail()
            cleaning.toggleItem(item.id); cleaning.method = .permanent; cleaning.requestConfirmation()
            _ = await settle(window) { exists("space-cleaning-confirm-execute", in: host) }
            check(enabled("space-cleaning-confirm-execute", in: host) == false && !cleaning.acknowledgement,
                  "permanent confirmation is visibly disabled before explicit acknowledgement")
            cleaning.executeConfirmed(permanent: true, remember: false)
            check(manager.fileExists(atPath: download.path) && cleaning.dialog == .confirm && !cleaning.isBusy,
                  "model also rejects unacknowledged permanent deletion independently of disabled UI")
            cleaning.acknowledgement = true
            _ = await settle(window) { enabled("space-cleaning-confirm-execute", in: host) == true }
            check(enabled("space-cleaning-confirm-execute", in: host) == true, "acknowledgement enables the mounted permanent action")
            try capture(host: host, name: "permanent-confirmation", output: output)
            cleaning.closeDialog()
            check(manager.fileExists(atPath: download.path), "cancelling confirmation leaves the selected file unchanged")

            cleaning.method = .trash; cleaning.requestConfirmation(); cleaning.executeConfirmed(permanent: false, remember: false)
            await cleaning.waitUntilIdle()
            _ = await settle(window) { cleaning.screen == .finished }
            guard let batch = cleaning.currentBatch, let record = batch.items.first(where: \.canRestore) else { throw SpaceCleaningFixtureError.invalid("isolated Trash transaction produced no recoverable record") }
            check(!manager.fileExists(atPath: download.path) && record.resultURL.map { $0.path.hasPrefix(root.path + "/Trash/") } == true,
                  "real transaction moves only the selected fixture into the injected temporary Trash")
            check(manager.fileExists(atPath: otherDownload.path) && manager.fileExists(atPath: release.path),
                  "unselected download and protected release materials remain untouched")
            cleaning.showHistory()
            await cleaning.waitUntilIdle()
            _ = await settle(window) { exists("space-cleaning", in: host) }
            try capture(host: host, name: "history-window", output: output)
            try Data("existing destination".utf8).write(to: download)
            cleaning.requestRestoreItem(record.id)
            _ = await settle(window) { exists("space-cleaning-restore-dialog", in: host) }
            check(cleaning.pendingHistoryItems.count == 1 && exists("space-cleaning-confirm-restore", in: host), "per-item history opens its real restore conflict dialog")
            try capture(host: host, name: "restore-conflict", output: output)
            cleaning.executeRestore(batchID: batch.id, renameConflicts: true)
            await cleaning.waitUntilIdle()
            let restored = cleaning.batches.first(where: { $0.id == batch.id })?.items.first(where: { $0.id == record.id })
            check(try Data(contentsOf: download) == Data("existing destination".utf8) && restored?.resultURL != download && restored?.canRestore == false,
                  "restoring a fixture preserves the existing namesake and records a different restored path")
            check(cleaning.requiresRescan && cleaning.selectedCount == 0, "restoration invalidates stale cleanup selection")
            check(calendarSystem.requests == 0 && calendarNotifications.requests == 0 && !app.device.isSampling,
                  "cleaning UI fixtures do not request calendar access or start device sampling")
            await cleaning.prepareForQuit()
            print("DETAIL space-cleaning owned-view evidence=\(output.path); real fixture scan and transactions; no actual user Trash; manual screenshot review remains separate")
        } catch { check(false, "space cleaning native fixture: \(error.localizedDescription)") }
        return (count, failures)
    }

    private static func settle(_ window: NSWindow, until predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if predicate() { try? await Task.sleep(for: .milliseconds(50)); window.contentView?.layoutSubtreeIfNeeded(); return predicate() }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return predicate()
    }
    private static func objects(_ root: NSObject) -> [NSObject] {
        var pending = [root], result: [NSObject] = [], visited = Set<ObjectIdentifier>()
        while let object = pending.popLast(), visited.count < 8192 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }; result.append(object)
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return result
    }
    private static func element(_ identifier: String, in root: NSView) -> NSObject? {
        objects(root).first { $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey: "accessibilityIdentifier") as? String == identifier }
    }
    private static func exists(_ identifier: String, in root: NSView) -> Bool { frame(identifier, in: root) != nil }
    private static func frame(_ identifier: String, in root: NSView) -> NSRect? {
        let frames = objects(root).compactMap { object -> NSRect? in
            guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")), object.value(forKey: "accessibilityIdentifier") as? String == identifier,
                  object.responds(to: NSSelectorFromString("accessibilityFrame")), let rect = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
                  rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else { return nil }
            return rect
        }
        return frames.max { $0.width * $0.height < $1.width * $1.height }
    }
    private static func enabled(_ identifier: String, in root: NSView) -> Bool? {
        guard let object = element(identifier, in: root), object.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return nil }
        return object.value(forKey: "accessibilityEnabled") as? Bool
    }
    private static func pageScroll(in host: NSView) -> NSScrollView? {
        objects(host).compactMap { $0 as? NSScrollView }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.documentView != nil }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
    private static func visiblePageFrame(_ scroll: NSScrollView, in host: NSView) -> NSRect {
        guard let window = host.window else { return .zero }
        // Only the part inside the root's clipping bounds is visible, even if
        // AppKit's child layout is still larger during a resize.
        return window.convertToScreen(scroll.convert(scroll.bounds, to: nil).intersection(host.convert(host.bounds, to: nil)))
    }
    private static func move(_ scroll: NSScrollView, fraction: CGFloat) {
        guard let document = scroll.documentView else { return }
        let extent = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let y = document.bounds.minY + extent * (document.isFlipped ? fraction : 1 - fraction)
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private static func capture(host: NSView, name: String, output: URL) throws {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SpaceCleaningFixtureError.invalid("could not allocate owned-view image") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 1000 else { throw SpaceCleaningFixtureError.invalid("empty owned-view image") }
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

private enum SpaceCleaningFixtureError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}
private struct SpaceCleaningFixtureTrash: SpaceCleaningFileOperating {
    let root: URL
    let destination: URL
    func moveToTrash(_ source: URL) throws -> URL {
        guard source.path.hasPrefix(root.path + "/"), destination.path.hasPrefix(root.path + "/") else { throw SpaceCleaningFixtureError.invalid("fixture cannot touch a nonfixture path") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }
}
@MainActor private final class SpaceCleaningFixtureCalendar: CalendarSystemProviding {
    var requests = 0
    func access(reminders: Bool) -> CalendarAccess { .denied }
    func requestAccess(reminders: Bool) async throws -> Bool { requests += 1; return false }
    func events(in interval: DateInterval) throws -> [CalendarEventItem] { [] }
    func reminders() async throws -> [ReminderItem] { [] }
    func writableReminderCalendars() -> [ReminderCalendar] { [] }
    func saveReminder(_ item: ReminderItem, creating: Bool) throws -> ReminderItem { throw ReminderError.unavailable("isolated cleaning fixture") }
    func deleteReminder(_ item: ReminderItem) throws { throw ReminderError.unavailable("isolated cleaning fixture") }
}
@MainActor private final class SpaceCleaningFixtureCalendarNotifications: ReminderNotificationProviding {
    var requests = 0
    func access() async -> CalendarAccess { .denied }
    func requestAccess() async throws -> Bool { requests += 1; return false }
    func replacePending(_ values: [ReminderNotification]) async throws { }
}
@MainActor private final class SpaceCleaningFixtureAINotifications: AIQuotaNotificationProviding {
    func permission() async -> AIQuotaNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func deliver(_ event: AIQuotaAlertEvent) async throws { throw AIUsageError.invalid("isolated cleaning fixture") }
}
