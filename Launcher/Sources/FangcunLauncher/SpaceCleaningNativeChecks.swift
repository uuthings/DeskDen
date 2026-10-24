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
                check(app.theme == theme && exists("space-cleaning-start", in: host), "\(theme.rawValue) cleaning inherits the shared theme and readable disk header")
                try capture(host: host, name: "theme-" + theme.rawValue, output: output)
            }
            owner.configuration.settings.workbenchTheme = .qingbiMist; app.syncAppearance()
            cleaning.startScan()
            check(cleaning.screen == .scanning && cleaning.selectedCount == 0, "explicit scan begins without selecting any candidate")
            await cleaning.waitUntilIdle()
            _ = await settle(window) { exists("space-cleaning-result-list", in: host) }
            check(cleaning.screen == .results && cleaning.selectedCount == 1 && cleaning.selectedItems.allSatisfy { $0.group == .rebuildable },
                  "real scan selects only positively identified rebuildable cache by default")
            check(cleaning.resultTab == .recommended && Set(cleaning.visibleItems.map(\.id)) == cleaning.recommendedIDs &&
                  cleaning.selectedIDs == cleaning.recommendedIDs,
                  "the initial results filter displays the actual recommended and preselected files")
            check(cleaning.items.allSatisfy { $0.url.path.hasPrefix(home.path + "/") }, "global fixture scanning stays inside the injected home")
            check(Set(cleaning.items.map(\.group)) == Set(CleaningResultGroup.allCases), "real scanner retains distinct protection and review classifications")
            check(exists("space-cleaning-rescan", in: host) && exists("space-cleaning-edit-scope", in: host), "rescan and scope editing remain visible in the results header")
            check(enabled("space-cleaning-cleanup", in: host) == true,
                  "the default recommended selection exposes an enabled direct cleanup action")
            if let recommended = cleaning.recommendedItems.first {
                check(selectionAligned(item: recommended.id, in: host),
                      "the visible-selection control and recommended row checkbox share the same column")
            }
            try capture(host: host, name: "results-window", output: output)
            cleaning.screen = .scanning
            _ = await settle(window) { exists("space-cleaning-scan", in: host) }
            try capture(host: host, name: "scan-layout", output: output)
            check(!cleaning.animationActive, "reduced motion pauses the scan illustration")
            cleaning.screen = .results
            _ = await settle(window) { exists("space-cleaning-result-list", in: host) }
            guard let item = cleaning.items.first(where: { $0.url == download && $0.isSelectable }) else { throw SpaceCleaningFixtureError.invalid("download candidate unavailable") }
            let recommendedSelection = cleaning.selectedIDs
            cleaning.showResults(.reviewable)
            _ = await settle(window) { exists("space-cleaning-select-" + item.id.uuidString, in: host) }
            check(cleaning.selectedIDs == recommendedSelection && cleaning.visibleItems.allSatisfy { !cleaning.recommendedIDs.contains($0.id) },
                  "switching to other files preserves recommendations without repeating them in the manual list")
            cleaning.clearSelection(); cleaning.toggleItem(item.id)
            guard let page = pageScroll(in: host) else { throw SpaceCleaningFixtureError.invalid("internal result scroll missing") }
            let sidebarBefore = frame("workbench-sidebar", in: host)
            let surfaceBefore = frame("space-cleaning-results-surface", in: host)
            let footerBefore = frame("space-cleaning-selection-footer", in: host)
            cleaning.showDetail(item.id)
            _ = await settle(window) { exists("space-cleaning-file-detail", in: host) }
            check(frame("space-cleaning-file-detail", in: host).map { $0.width > 600 } == true, "file review expands inline across the list instead of opening a popup or side panel")
            check(frame("space-cleaning-results-surface", in: host) == surfaceBefore && frame("space-cleaning-selection-footer", in: host) == footerBefore,
                  "expanding a file preserves card geometry and the fixed selection footer")
            try capture(host: host, name: "file-review-window", output: output)
            for (name, size) in sizes {
                window.setContentSize(size)
                _ = await settle(window) { host.bounds.size == size }
                cleaning.resultScrollID = item.id
                _ = await settle(window) { exists("space-cleaning-select-" + item.id.uuidString, in: host) }
                check(selectionAligned(item: item.id, in: host),
                      "\(name) the visible-selection control aligns with the manual file checkbox")
                let footer = frame("space-cleaning-selection-footer", in: host)
                move(page, fraction: 0.55)
                _ = await settle(window) { frame("space-cleaning-selection-footer", in: host) == footer }
                check(frame("space-cleaning-selection-footer", in: host) == footer && enabled("space-cleaning-cleanup", in: host) == true,
                      "\(name) scrolling the results keeps the enabled cleanup action fixed")
                check(objects(host).compactMap { $0 as? NSScrollView }.filter { !$0.isHiddenOrHasHiddenAncestor }.count == 1,
                      "\(name) has only an internal result scroll, no outer Content scrollbar")
                try capture(host: host, name: "results-scrolled-" + name, output: output)
            }
            window.setContentSize(NSSize(width: 1120, height: 758))
            _ = await settle(window) { host.bounds.width == 1120 }
            check(frame("workbench-sidebar", in: host) == sidebarBefore, "result interactions preserve the existing shell navigation geometry")
            let selectedBefore = cleaning.selectedIDs
            cleaning.editScope(custom: true)
            _ = await settle(window) { exists("space-cleaning-scope-editor", in: host) }
            check(cleaning.draftDirectories.isEmpty && enabled("space-cleaning-apply-scope", in: host) == false,
                  "empty custom scope cannot replace an existing scan")
            cleaning.addDraftDirectories([home.appendingPathComponent("Downloads"), home.appendingPathComponent("Developer")])
            _ = await settle(window) { enabled("space-cleaning-apply-scope", in: host) == true }
            try capture(host: host, name: "custom-scope", output: output)
            cleaning.cancelScope()
            check(cleaning.screen == .results && cleaning.selectedIDs == selectedBefore && cleaning.scopeChoice == .global,
                  "cancelling the scope draft preserves the existing results and selection")
            cleaning.closeDetail(); cleaning.method = .permanent; cleaning.requestCleanup()
            _ = await settle(window) { exists("space-cleaning-confirm-execute", in: host) }
            check(enabled("space-cleaning-confirm-execute", in: host) == false && !cleaning.acknowledgement,
                  "permanent confirmation is visibly disabled before explicit acknowledgement")
            check(cleaning.screen == .results && exists("space-cleaning-result-list", in: host),
                  "irreversible confirmation retains the result list instead of replacing it with another review page")
            cleaning.executeConfirmed(permanent: true, remember: false)
            check(manager.fileExists(atPath: download.path) && cleaning.dialog == .confirm && !cleaning.isBusy,
                  "model independently rejects unacknowledged permanent deletion")
            cleaning.acknowledgement = true
            _ = await settle(window) { enabled("space-cleaning-confirm-execute", in: host) == true }
            check(enabled("space-cleaning-confirm-execute", in: host) == true, "acknowledgement enables the mounted permanent action")
            try capture(host: host, name: "permanent-confirmation", output: output)
            cleaning.closeDialog()
            check(manager.fileExists(atPath: download.path), "cancelling confirmation leaves the selected file unchanged")

            cleaning.method = .trash; cleaning.requestCleanup()
            check(cleaning.isBusy && cleaning.screen == .processing && cleaning.dialog == nil,
                  "the selected file enters its Trash transaction after one cleanup action")
            await cleaning.waitUntilIdle()
            _ = await settle(window) { cleaning.screen == .start }
            guard let batch = cleaning.currentBatch, let record = batch.items.first(where: \.canRestore) else { throw SpaceCleaningFixtureError.invalid("isolated Trash transaction produced no recoverable record") }
            check(!manager.fileExists(atPath: download.path) && record.resultURL.map { $0.path.hasPrefix(root.path + "/Trash/") } == true,
                  "real transaction moves only the selected fixture into the injected temporary Trash")
            check(manager.fileExists(atPath: otherDownload.path) && manager.fileExists(atPath: release.path),
                  "unselected download and protected release materials remain untouched")
            _ = await settle(window) { exists("space-cleaning-completion-receipt", in: host) }
            check(exists("space-cleaning-start", in: host) && exists("space-cleaning-completion-receipt", in: host), "cleanup returns to the home launch surface with a compact result receipt")
            try capture(host: host, name: "home-after-cleaning", output: output)
            window.setContentSize(NSSize(width: 900, height: 620))
            _ = await settle(window) { exists("space-cleaning-start", in: host) }
            try capture(host: host, name: "home-after-cleaning-compact", output: output)
            window.setContentSize(NSSize(width: 1120, height: 758))
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
    private static func selectionAligned(item: UUID, in host: NSView) -> Bool {
        guard let header = frame("space-cleaning-select-visible", in: host),
              let row = frame("space-cleaning-select-" + item.uuidString, in: host) else { return false }
        return abs(header.midX - row.midX) < 1 && abs(header.width - row.width) < 1 &&
            header.width >= 20 && header.width <= 28
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
