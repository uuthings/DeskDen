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
                for result in homeLayoutChecks(in: host) { check(result.0, "\(name) global home " + result.1) }
                try capture(host: host, name: "start-\(name)", output: output)
            }
            cleaning.editScope(custom: true)
            cleaning.addDraftDirectories([home.appendingPathComponent("Downloads")]); cleaning.applyScope()
            for (name, size) in sizes {
                window.setContentSize(size)
                _ = await settle(window) { exists("space-cleaning-location-Downloads", in: host) }
                check(cleaning.scopeChoice == .custom && cleaning.customDirectories.count == 1 &&
                      exists("space-cleaning-home-locations", in: host) && exists("space-cleaning-location-Downloads", in: host),
                      "\(name) custom home displays its selected folder as a location card")
                for result in homeLayoutChecks(in: host) { check(result.0, "\(name) custom home " + result.1) }
                try capture(host: host, name: "home-custom-\(name)", output: output)
            }
            // Layout-only locations are siblings of Home, so they cannot change
            // the later global scan fixture or its classification counts.
            let locationsRoot = root.appendingPathComponent("HomeLayoutLocations")
            let locationNames = [
                "A Sample Folder With A Deliberately Long Name For Checking Directory Card Truncation",
                "Build Output", "Design Assets", "Media Export", "Project Snapshots", "Reference Files", "Temporary Samples"
            ]
            let locations = locationNames.map { locationsRoot.appendingPathComponent($0) }
            for location in locations { try manager.createDirectory(at: location, withIntermediateDirectories: true) }
            cleaning.editScope(custom: true)
            for location in cleaning.draftDirectories { cleaning.removeDraftDirectory(location) }
            cleaning.addDraftDirectories(locations); cleaning.applyScope()
            for (name, size) in sizes {
                window.setContentSize(size)
                _ = await settle(window) { exists("space-cleaning-location-" + locationNames[0], in: host) }
                check(cleaning.customDirectories.count == locations.count && exists("space-cleaning-manage-locations", in: host) &&
                      exists("space-cleaning-location-" + locationNames[0], in: host),
                      "\(name) multiple-location home retains every selected directory and displays its long-name card")
                for result in homeLayoutChecks(in: host) { check(result.0, "\(name) multiple-location home " + result.1) }
                try capture(host: host, name: "home-multiple-\(name)", output: output)
            }
            cleaning.selectScope(.global)
            // Restore the original empty custom draft for the existing scope
            // cancellation checks, without scanning the layout-only directories.
            cleaning.editScope()
            for location in cleaning.draftDirectories { cleaning.removeDraftDirectory(location) }
            cleaning.applyScope()
            check(cleaning.scopeChoice == .global && cleaning.customDirectories.isEmpty && cleaning.items.isEmpty && !cleaning.isBusy,
                  "home layout scenarios restore the original global scan without scanning their extra directories")
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
                  cleaning.recommendedItems.count == 2 && cleaning.selectedIDs.isStrictSubset(of: cleaning.recommendedIDs),
                  "initial recommendations include installer media while default selection remains limited to rebuildable cache")
            check(cleaning.recommendedItems.contains { $0.url == download && !cleaning.selectedIDs.contains($0.id) } &&
                  !cleaning.recommendedItems.contains { $0.url == otherDownload },
                  "downloaded disk images are visible suggestions without auto-selecting them or personal recordings")
            check(cleaning.method == .trash && !cleaning.rememberMethod &&
                  accessibilityValue("space-cleaning-method-trash", in: host) == "已选择" &&
                  accessibilityValue("space-cleaning-method-permanent", in: host) == "未选择",
                  "direct method choices visibly default to Trash with remembering off")
            check(cleaning.items.allSatisfy { $0.url.path.hasPrefix(home.path + "/") }, "global fixture scanning stays inside the injected home")
            check(Set(cleaning.items.map(\.group)) == Set(CleaningResultGroup.allCases), "real scanner retains distinct protection and review classifications")
            check(exists("space-cleaning-rescan", in: host) && exists("space-cleaning-edit-scope", in: host), "rescan and scope editing remain visible in the results header")
            check(enabled("space-cleaning-cleanup", in: host) == true,
                  "the default recommended selection exposes an enabled direct cleanup action")
            if let recommended = cleaning.recommendedItems.first {
                check(selectionAligned(item: recommended.id, in: host),
                      "the visible-selection control and recommended row checkbox share the same column")
            }
            for (name, size) in sizes {
                window.setContentSize(size)
                _ = await settle(window) { exists("space-cleaning-remember-method", in: host) }
                for result in footerLayoutChecks(in: host) { check(result.0, "\(name) recommended results " + result.1) }
                try capture(host: host, name: "results-" + name, output: output)
            }
            window.setContentSize(NSSize(width: 1120, height: 758))
            cleaning.showResults(.protected)
            _ = await settle(window) { cleaning.visibleItems.contains(where: \.needsPurposeConfirmation) }
            guard let testPackage = cleaning.visibleItems.first(where: \.needsPurposeConfirmation),
                  let releasePackage = cleaning.visibleItems.first(where: { $0.kind == .releaseMaterial }) else {
                throw SpaceCleaningFixtureError.invalid("purpose and release protection fixtures missing")
            }
            _ = await settle(window) { exists("space-cleaning-unlock-" + testPackage.id.uuidString, in: host) }
            check(exists("space-cleaning-unlock-" + testPackage.id.uuidString, in: host) &&
                  !exists("space-cleaning-unlock-" + releasePackage.id.uuidString, in: host),
                  "only purpose-reviewable packages expose the inline unlock action")
            try capture(host: host, name: "protected-results", output: output)
            cleaning.requestTestPurpose(testPackage.id)
            _ = await settle(window) { exists("space-cleaning-file-detail", in: host) }
            check(cleaning.detailID == testPackage.id && cleaning.dialog == .purpose(testPackage.id) && !cleaning.acknowledgement,
                  "the protection action opens its inline explanation and requires a fresh purpose declaration")
            _ = await settle(window) {
                frame("space-cleaning-result-list", in: host).flatMap { list in
                    frame("space-cleaning-confirm-test-purpose", in: host).map { list.contains($0) }
                } == true
            }
            check(frame("space-cleaning-result-list", in: host).flatMap { list in
                frame("space-cleaning-confirm-test-purpose", in: host).map { list.contains($0) }
            } == true, "opening purpose review scrolls its confirmation into the visible result list")
            try capture(host: host, name: "protected-purpose-review", output: output)
            cleaning.acknowledgement = true; cleaning.confirmTestPurpose(testPackage.id)
            await cleaning.waitUntilIdle()
            check(cleaning.items.first(where: { $0.id == testPackage.id })?.isSelectable == true &&
                  !cleaning.selectedIDs.contains(testPackage.id) &&
                  cleaning.items.first(where: { $0.id == releasePackage.id })?.isSelectable == false,
                  "verified test-purpose packages become manually selectable while release materials stay protected")
            cleaning.closeDetail(); cleaning.showResults(.recommended)
            cleaning.screen = .scanning
            _ = await settle(window) { exists("space-cleaning-scan", in: host) }
            try capture(host: host, name: "scan-layout", output: output)
            check(!cleaning.animationActive, "reduced motion pauses the scan illustration")
            cleaning.screen = .results
            _ = await settle(window) { exists("space-cleaning-result-list", in: host) }
            guard let item = cleaning.items.first(where: { $0.url == download && $0.isSelectable }),
                  let manualItem = cleaning.items.first(where: { $0.url == otherDownload && $0.isSelectable }) else {
                throw SpaceCleaningFixtureError.invalid("download candidates unavailable")
            }
            let recommendedSelection = cleaning.selectedIDs
            cleaning.showResults(.reviewable)
            _ = await settle(window) { exists("space-cleaning-select-" + manualItem.id.uuidString, in: host) }
            check(cleaning.selectedIDs == recommendedSelection && cleaning.visibleItems.allSatisfy { !cleaning.recommendedIDs.contains($0.id) },
                  "switching to other files preserves recommendations without repeating them in the manual list")
            cleaning.showResults(.recommended)
            cleaning.clearSelection(); cleaning.toggleItem(item.id)
            _ = await settle(window) { exists("space-cleaning-select-" + item.id.uuidString, in: host) }
            guard let page = pageScroll(in: host) else { throw SpaceCleaningFixtureError.invalid("internal result scroll missing") }
            let sidebarBefore = frame("workbench-sidebar", in: host)
            let surfaceBefore = frame("space-cleaning-results-surface", in: host)
            let footerBefore = frame("space-cleaning-selection-footer", in: host)
            cleaning.showDetail(item.id)
            _ = await settle(window) { exists("space-cleaning-file-detail", in: host) }
            check(frame("space-cleaning-file-detail", in: host).map { $0.width > 600 } == true, "file review expands inline across the list instead of opening a popup or side panel")
            check(frame("space-cleaning-results-surface", in: host) == surfaceBefore && frame("space-cleaning-selection-footer", in: host) == footerBefore,
                  "expanding a file preserves card geometry and the fixed selection footer")
            check(item.handlingNote != nil && cleaning.selectedIDs == [item.id],
                  "installer review explains its manual decision and only becomes selected through an explicit choice")
            try capture(host: host, name: "recommendation-installer-detail", output: output)
            cleaning.showResults(.reviewable); cleaning.showDetail(manualItem.id)
            _ = await settle(window) { exists("space-cleaning-file-detail", in: host) }
            try capture(host: host, name: "file-review-window", output: output)
            for (name, size) in sizes {
                window.setContentSize(size)
                _ = await settle(window) { host.bounds.size == size }
                cleaning.resultScrollID = manualItem.id
                _ = await settle(window) { exists("space-cleaning-select-" + manualItem.id.uuidString, in: host) }
                check(selectionAligned(item: manualItem.id, in: host),
                      "\(name) the visible-selection control aligns with the manual file checkbox")
                for result in footerLayoutChecks(in: host) { check(result.0, "\(name) selected results " + result.1) }
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
            check(frame("space-cleaning-home-surface", in: host).flatMap { card in
                frame("space-cleaning-scope-editor", in: host).map { card.contains($0) }
            } == true && exists("space-cleaning-home-heading", in: host),
                  "scope editing stays inside the same home launch card with its heading and animation")
            check(cleaning.draftDirectories.isEmpty && enabled("space-cleaning-apply-scope", in: host) == false,
                  "empty custom scope cannot replace an existing scan")
            cleaning.addDraftDirectories([home.appendingPathComponent("Downloads"), home.appendingPathComponent("Developer")])
            _ = await settle(window) { enabled("space-cleaning-apply-scope", in: host) == true }
            try capture(host: host, name: "custom-scope", output: output)
            cleaning.cancelScope()
            check(cleaning.screen == .results && cleaning.selectedIDs == selectedBefore && cleaning.scopeChoice == .global,
                  "cancelling the scope draft preserves the existing results and selection")
            cleaning.closeDetail(); cleaning.chooseMethod(.permanent); cleaning.setRememberMethod(true)
            _ = await settle(window) { accessibilityValue("space-cleaning-method-permanent", in: host) == "已选择" }
            check(cleaning.method == .permanent && cleaning.rememberMethod &&
                  accessibilityValue("space-cleaning-method-permanent", in: host) == "已选择" &&
                  accessibilityValue("space-cleaning-method-trash", in: host) == "未选择",
                  "changing the direct choice updates the selected state while remembering stays a separate option")
            for (name, size) in sizes {
                window.setContentSize(size)
                _ = await settle(window) { exists("space-cleaning-remember-method", in: host) }
                for result in footerLayoutChecks(in: host) { check(result.0, "\(name) remembered permanent choice " + result.1) }
                try capture(host: host, name: "results-permanent-remember-" + name, output: output)
            }
            window.setContentSize(NSSize(width: 1120, height: 758))
            cleaning.requestCleanup()
            _ = await settle(window) { exists("space-cleaning-confirm-execute", in: host) }
            check(enabled("space-cleaning-confirm-execute", in: host) == false && !cleaning.acknowledgement,
                  "permanent confirmation is visibly disabled before explicit acknowledgement")
            cleaning.chooseMethod(.trash); cleaning.setRememberMethod(false)
            check(cleaning.method == .permanent && cleaning.rememberMethod,
                  "pending permanent confirmation also rejects method and preference changes at the model boundary")
            check(cleaning.screen == .results && exists("space-cleaning-result-list", in: host),
                  "irreversible confirmation retains the result list instead of replacing it with another review page")
            cleaning.executeConfirmed(permanent: true, remember: false)
            check(manager.fileExists(atPath: download.path) && cleaning.dialog == .confirm && !cleaning.isBusy,
                  "model independently rejects unacknowledged permanent deletion")
            cleaning.acknowledgement = true
            _ = await settle(window) { enabled("space-cleaning-confirm-execute", in: host) == true }
            check(enabled("space-cleaning-confirm-execute", in: host) == true, "acknowledgement enables the mounted permanent action")
            for (name, size) in sizes {
                window.setContentSize(size)
                _ = await settle(window) { exists("space-cleaning-confirm-execute", in: host) }
                for result in footerLayoutChecks(in: host) { check(result.0, "\(name) permanent confirmation " + result.1) }
                check(!exists("space-cleaning-method-trash", in: host) &&
                      !exists("space-cleaning-method-permanent", in: host) &&
                      !exists("space-cleaning-remember-method", in: host),
                      "\(name) confirmation replaces redundant method controls to preserve list space")
                try capture(host: host, name: "permanent-confirmation-" + name, output: output)
            }
            window.setContentSize(NSSize(width: 1120, height: 758))
            cleaning.closeDialog()
            check(manager.fileExists(atPath: download.path), "cancelling confirmation leaves the selected file unchanged")
            cleaning.requestCleanup()
            _ = await settle(window) { exists("space-cleaning-confirm-execute", in: host) }
            check(cleaning.rememberMethod && cleaning.dialog == .confirm && !cleaning.acknowledgement &&
                  enabled("space-cleaning-confirm-execute", in: host) == false,
                  "remembering permanent deletion never reuses a previous acknowledgement")
            cleaning.closeDialog(); cleaning.setRememberMethod(false)
            cleaning.chooseMethod(.trash); cleaning.requestCleanup()
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
            for result in homeLayoutChecks(in: host) { check(result.0, "compact post-cleanup home " + result.1) }
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
            app.openHealth(); app.health.showOverview()
            _ = await settle(window) { exists("health-overview-factor-storage", in: host) }
            check(DeviceHealthFactor.allCases.allSatisfy {
                exists("health-factor-deduction-" + $0.rawValue, in: host) && exists("health-factor-basis-" + $0.rawValue, in: host)
            }, "each health factor exposes its own deduction state and scoring details")
            check(!objects(host).contains { object in
                guard object.responds(to: NSSelectorFromString("accessibilityLabel")),
                      let label = object.value(forKey: "accessibilityLabel") as? String else { return false }
                return label.contains("返回空间清理") || label.contains("返回设备状态")
            }, "health opened from cleaning has no cross-module return menu")
            try capture(host: host, name: "health-factor-deductions", output: output)
            app.health.scoreDetail = .storage
            _ = await settle(window) { exists("health-score-detail-storage", in: host) }
            check(exists("health-score-detail-storage", in: host), "storage scoring rules open in their own detail instead of expanding below the cards")
            try capture(host: host, name: "health-score-detail", output: output)
            app.health.scoreDetail = nil
            app.navigate(.cleaning)
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
    private static func accessibilityValue(_ identifier: String, in root: NSView) -> String? {
        guard let object = element(identifier, in: root), object.responds(to: NSSelectorFromString("accessibilityValue")) else { return nil }
        return object.value(forKey: "accessibilityValue") as? String
    }
    private static func footerLayoutChecks(in host: NSView) -> [(Bool, String)] {
        let footer = frame("space-cleaning-selection-footer", in: host)
        let module = frame("space-cleaning", in: host)
        if let confirm = frame("space-cleaning-confirm-execute", in: host),
           let acknowledgement = frame("space-cleaning-permanent-acknowledgement", in: host) {
            return [
                (footer.map { $0.contains(confirm) && $0.contains(acknowledgement) } ?? false,
                 "keeps acknowledgement and confirmation inside the footer"),
                (module.map { $0.contains(confirm) && $0.contains(acknowledgement) } ?? false,
                 "keeps permanent confirmation inside the viewport"),
                (frame("space-cleaning-result-list", in: host).map { $0.height >= 68 } ?? false,
                 "keeps at least one complete result row visible while confirming")
            ]
        }
        let controls = ["space-cleaning-method-trash", "space-cleaning-method-permanent", "space-cleaning-remember-method"]
        let frames = controls.compactMap { frame($0, in: host) }
        let contained = frames.count == controls.count && frames.allSatisfy { control in
            guard let footer, let module else { return false }
            return footer.insetBy(dx: -1, dy: -1).contains(control) && module.insetBy(dx: -1, dy: -1).contains(control)
        }
        let separate = frames.count == controls.count && frames.enumerated().allSatisfy { index, rect in
            frames.dropFirst(index + 1).allSatisfy { rect.intersection($0).isEmpty }
        }
        let action = frame("space-cleaning-confirm-execute", in: host) ?? frame("space-cleaning-cleanup", in: host)
        let actionVisible = action.flatMap { rect in module.map { $0.insetBy(dx: -1, dy: -1).contains(rect) } } ?? false
        return [
            (contained, "keeps both method choices and the independent checkbox inside the footer and viewport"),
            (separate, "keeps the two choices and remember checkbox from overlapping"),
            (frames.count == controls.count && frames.allSatisfy { abs($0.midY - frames[0].midY) < 2 },
             "keeps the remember checkbox on the same row as both deletion methods"),
            (actionVisible, "keeps the active cleanup or confirmation button fully visible")
        ]
    }
    private static func homeRulesStayWithCard(in host: NSView) -> Bool {
        guard let surface = frame("space-cleaning-home-surface", in: host),
              let rules = frame("space-cleaning-rules-link", in: host) else { return false }
        // AX frames are in screen coordinates, where the lower edge has minY.
        let gap = surface.minY - rules.maxY
        return gap >= -1 && gap <= 35
    }
    private static func homeLayoutChecks(in host: NSView) -> [(Bool, String)] {
        let surface = frame("space-cleaning-home-surface", in: host)
        let module = frame("space-cleaning", in: host)
        let start = frame("space-cleaning-start", in: host)
        let buttonContained = module.flatMap { outer in start.map { outer.insetBy(dx: -1, dy: -1).contains($0) } } ?? false
        return [
            (homeRulesStayWithCard(in: host), "keeps the rules link within 35 pt of the card"),
            (surface.flatMap { card in module.map { card.height >= min(360, $0.height * 0.65) } } ?? false,
             "gives the scan preparation card useful vertical space"),
            (buttonContained, "keeps the scan button inside the visible module"),
            (frame("space-cleaning-home-heading", in: host).map { $0.height >= 44 } ?? false,
             "keeps both lines of the home heading visible")
        ]
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
