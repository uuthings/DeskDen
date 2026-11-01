import AppKit
import Combine
import LauncherCore
import Sparkle
import SwiftUI

/// All update engines, notification services and OS termination boundaries are
/// injected. No Sparkle updater, network request, installer or real quit is used.
@MainActor enum AppUpdateChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let suite = "test.deskden-updates.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return (1, 1) }
        defer { defaults.removePersistentDomain(forName: suite) }
        let information: [String: Any] = [
            "SUFeedURL": "https://example.com/deskden/appcast.xml",
            "SUPublicEDKey": Data((0..<32).map(UInt8.init)).base64EncodedString(),
            "SUEnableAutomaticChecks": true, "SUAutomaticallyUpdate": false,
            "SUAllowsAutomaticUpdates": false, "SUVerifyUpdateBeforeExtraction": true, "SURequireSignedFeed": true
        ]
        var date = Date(timeIntervalSince1970: 1_790_000_000)
        let factory = UpdateCheckEngineFactory(defaults: defaults)
        let updates = AppUpdateController(defaults: defaults, information: information, now: { date }, engineFactory: factory.make)
        check(updates.automaticallyChecks && factory.engines.isEmpty, "fresh installations default to automatic checks without eagerly starting a service")
        updates.startAutomaticCheckingIfEnabled()
        guard let first = factory.engines.first else { check(false, "launch creates an injected update engine"); return (count, failures) }
        check(first.starts == 1 && first.backgroundChecks == 1 && !updates.isDialogPresented && defaults.object(forKey: "SUEnableAutomaticChecks") == nil,
              "launch performs one silent due check without rewriting the automatic-check preference")
        updates.startAutomaticCheckingIfEnabled(); updates.checkAutomaticallyIfDue(reconnected: true)
        check(first.backgroundChecks == 1 && first.starts == 1, "duplicate launch/wake/connectivity triggers do not overlap a running check")
        first.complete(at: date); updates.foundNoUpdate()
        date = date.addingTimeInterval(86_399); updates.checkAutomaticallyIfDue()
        check(first.backgroundChecks == 1, "the daily interval is measured from the real last check")
        date = date.addingTimeInterval(1); updates.checkAutomaticallyIfDue()
        check(first.backgroundChecks == 2 && !updates.isDialogPresented, "a due daily trigger starts another silent check")
        first.complete(at: date)
        updates.recordAbort(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        check(updates.hasError && !updates.isDialogPresented, "background transport failure records status without opening a dialog")
        date = date.addingTimeInterval(61); updates.checkAutomaticallyIfDue(reconnected: true)
        check(first.backgroundChecks == 3, "restored connectivity retries a failed due check without waiting another day")
        first.complete(at: date)
        updates.setAutomaticallyChecks(false)
        let manualFactory = UpdateCheckEngineFactory(defaults: defaults)
        let manual = AppUpdateController(defaults: defaults, information: information, engineFactory: manualFactory.make)
        manual.startAutomaticCheckingIfEnabled()
        check(!manual.automaticallyChecks && manualFactory.engines.isEmpty && defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool == false,
              "an explicit saved opt-out survives recreation and prevents launch-time checks")
        manual.checkForUpdates()
        guard let manualEngine = manualFactory.engines.first else { check(false, "manual check creates the engine"); return (count, failures) }
        check(manualEngine.checks == 1 && manual.isDialogPresented && !manual.canCheck, "an explicit check opens its dialog and starts exactly one user session")
        manual.checkForUpdates(); manual.checkForUpdates()
        check(manualEngine.checks == 1, "repeated check actions retain the existing session instead of overlapping")
        manualEngine.canCheckForUpdates = true
        manual.offerUpdate(.init(version: "2.0.0", publishedAt: nil, notes: [], downloadSize: nil, informationURL: nil, informationOnly: false), userInitiated: true) { _ in }
        manual.checkForUpdates()
        check(manualEngine.checks == 1 && manual.phase == .available, "Sparkle focus availability cannot restart or overwrite an active offered session")
        manualEngine.complete(at: date); manual.foundNoUpdate()
        check(manual.canCheck && manual.lastChecked == date && manual.phase == .upToDate && !manual.automaticallyChecks,
              "manual completion publishes the actual result and date without enabling automatic checks")
        manual.recordAbort(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        check(manual.hasError && manual.isDialogPresented && manual.phase == .failed, "manual check failures remain visibly actionable")

        var invalid: [(String, [String: Any])] = []
        func invalidValue(_ key: String, _ value: Any?, _ name: String) {
            var entry = information; entry[key] = value; invalid.append((name, entry))
        }
        invalidValue("SUFeedURL", "http://example.com/appcast.xml", "insecure HTTP")
        invalidValue("SUFeedURL", "https:///", "missing HTTPS host")
        invalidValue("SUFeedURL", "https://user:secret@example.com/appcast.xml", "embedded URL credentials")
        invalidValue("SUPublicEDKey", "invalid-key", "invalid public-key encoding")
        invalidValue("SUPublicEDKey", Data(repeating: 1, count: 31).base64EncodedString(), "wrong public-key length")
        invalidValue("SUPublicEDKey", nil, "missing update public key")
        invalidValue("SUEnableAutomaticChecks", false, "obsolete manual build default")
        invalidValue("SUAutomaticallyUpdate", true, "automatic installation enabled")
        invalidValue("SUAllowsAutomaticUpdates", true, "automatic installation allowed")
        invalidValue("SUVerifyUpdateBeforeExtraction", false, "pre-extraction verification disabled")
        invalidValue("SURequireSignedFeed", false, "unsigned feed allowed")
        for (label, entry) in invalid {
            let spy = UpdateCheckEngineFactory(defaults: defaults)
            let controller = AppUpdateController(defaults: defaults, information: entry, engineFactory: spy.make)
            controller.startAutomaticCheckingIfEnabled(); controller.setAutomaticallyChecks(true); controller.checkForUpdates()
            check(!AppUpdateController.configurationIsValid(entry) && !controller.canCheck && controller.hasError && spy.engines.isEmpty,
                  "update configuration rejects \(label) before constructing an engine")
        }
        let blockedFactory = UpdateCheckEngineFactory(defaults: defaults)
        let blocked = AppUpdateController(defaults: defaults, information: information, allowsStarting: false, engineFactory: blockedFactory.make)
        blocked.checkForUpdates(); blocked.setAutomaticallyChecks(true)
        check(blockedFactory.engines.isEmpty && !blocked.automaticallyChecks, "a disabled test environment cannot construct the real updater")
        let retryFactory = UpdateCheckEngineFactory(defaults: defaults); retryFactory.failingStarts = 1
        let retry = AppUpdateController(defaults: defaults, information: information, engineFactory: retryFactory.make)
        retry.setAutomaticallyChecks(true)
        check(retry.hasError && !retry.automaticallyChecks && retryFactory.engines[0].checks == 0,
              "failed opt-in does not overwrite the user's saved disabled preference")
        retry.checkForUpdates()
        check(!retry.hasError && retryFactory.engines.count == 2 && retryFactory.engines[1].checks == 1,
              "a failed updater start can be retried with one fresh manual session")

        let synthetic = AppUpdateRelease(version: "2.0.0", publishedAt: nil,
            notes: [.init(title: "Synthetic change", detail: "Synthetic explanation")], downloadSize: 100,
            informationURL: nil, informationOnly: false)
        let flow = AppUpdateController(defaults: defaults, information: information, allowsStarting: false)
        var choices: [SPUUserUpdateChoice] = [], cancellations = 0, completions = 0
        flow.offerUpdate(synthetic, userInitiated: false) { choices.append($0) }
        check(flow.release == synthetic && flow.phase == .available && !flow.isDialogPresented && choices.isEmpty,
              "a background offer only publishes a sidebar entry and never starts its download")
        flow.showUpdateDialog(); flow.dismissDialog()
        check(flow.release == synthetic && choices.isEmpty && !flow.isDialogPresented,
              "later keeps the actual offer and callback without accepting or skipping the release")
        flow.downloadUpdate()
        check(choices == [.install] && flow.phase == .downloading, "only the explicit download action accepts the Sparkle offer")
        flow.downloadStarted { cancellations += 1 }; flow.downloadExpected(100); flow.downloadReceived(55)
        check(flow.progress == 0.55 && flow.downloadedBytes == 55 && flow.canCancelUpdate, "download progress uses actual byte callbacks")
        flow.showUpdateDialog(); flow.dismissDialog()
        check(cancellations == 0 && flow.phase == .downloading, "closing a download dialog keeps its transfer running")
        flow.extractionStarted(); flow.readyToInstall { choices.append($0) }
        check(flow.phase == .readyToInstall && choices == [.install] && !flow.isDialogPresented,
              "download preparation waits for a separate installation decision without reopening a dismissed dialog")
        flow.prepareForOrdinaryTermination { completions += 1 }
        check(choices == [.install, .skip] && completions == 0, "ordinary quit cancels Sparkle's prepared install and waits for acknowledgement")
        flow.finishUpdateCycle(); flow.finishUpdateCycle()
        check(completions == 1 && flow.phase == .available, "ordinary quit resumes exactly once after installer cancellation completes")
        flow.extractionStarted(); flow.prepareForOrdinaryTermination { completions += 1 }
        check(completions == 1, "quit during extraction waits until the framework exposes a cancellation choice")
        flow.readyToInstall { choices.append($0) }; flow.finishUpdateCycle()
        check(choices.last == .skip && completions == 2, "extraction completion cancels preparation before approving ordinary quit")
        flow.readyToInstall { choices.append($0) }; flow.isDialogPresented = true; flow.installUpdate()
        flow.prepareForOrdinaryTermination { completions += 1 }
        check(choices.last == .install && completions == 3 && flow.phase == .installing && !flow.isDialogPresented,
              "explicit installation proceeds through normal termination and removes only its own dialog")
        var retries = 0
        flow.installing(retry: { retries += 1 }, applicationTerminated: false); flow.installUpdate()
        check(retries == 1 && flow.canRetryInstallation, "unsaved content can defer termination and the same installer can retry later")
        flow.recordAbort(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        check(!flow.hasError && flow.status == "已取消更新，当前版本继续使用", "installation cancellation is not misreported as a transport failure")
        flow.downloadStarted { cancellations += 1 }; flow.cancelUpdate()
        check(cancellations == 1 && flow.phase == .available && flow.release == synthetic, "cancel download retains the release entry for an explicit retry")
        flow.downloadStarted {}; flow.dismissDialog(); flow.recordAbort(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        check(flow.phase == .failed && flow.release == synthetic && !flow.isDialogPresented, "a backgrounded download failure remains in its existing update entry without stealing focus")
        let downloadRetryFactory = UpdateCheckEngineFactory(defaults: defaults)
        let downloadRetry = AppUpdateController(defaults: defaults, information: information, engineFactory: downloadRetryFactory.make)
        var retryChoices: [SPUUserUpdateChoice] = []
        downloadRetry.offerUpdate(synthetic, userInitiated: true) { retryChoices.append($0) }
        downloadRetry.downloadUpdate(); downloadRetry.downloadStarted {}
        let downloadError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        downloadRetry.recordAbort(downloadError); downloadRetry.recordAbort(downloadError)
        downloadRetry.retryUpdate()
        downloadRetry.offerUpdate(synthetic, userInitiated: true) { retryChoices.append($0) }
        check(downloadRetryFactory.engines.first?.checks == 1 && retryChoices == [.install, .install],
              "duplicate driver and delegate errors preserve download retry intent while revalidating the same release")
        defaults.set("1.0.0", forKey: "SUSkippedVersion")
        defaults.set("1", forKey: "SUSkippedMajorVersion")
        defaults.removeObject(forKey: "SUSkippedMajorSubreleaseVersion")
        flow.offerUpdate(synthetic, stage: .installing, userInitiated: false) { choice in
            choices.append(choice)
            if choice == .skip {
                // Sparkle 2.10's resumed offer writes its skip preferences before
                // aborting the session, unlike the later ready callback.
                defaults.set("2.0.0", forKey: "SUSkippedVersion")
                defaults.set("2", forKey: "SUSkippedMajorVersion")
                defaults.set("2.0.0", forKey: "SUSkippedMajorSubreleaseVersion")
            }
        }
        flow.prepareForOrdinaryTermination { completions += 1 }
        flow.recordAbort(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        flow.finishUpdateCycle()
        check(defaults.string(forKey: "SUSkippedVersion") == "1.0.0" && defaults.string(forKey: "SUSkippedMajorVersion") == "1"
              && defaults.object(forKey: "SUSkippedMajorSubreleaseVersion") == nil,
              "cancelling a resumed installer offer restores exact prior skipped-version preferences after error completion")
        let htmlNotes = AppUpdateController.releaseNotes("<p>Important &amp; verified</p><script>bad()</script><p>Keep compatibility warning</p>", format: "html")
        check(htmlNotes.map(\.title) == ["Important & verified", "Keep compatibility warning"], "verified HTML notes become bounded inert text without losing upgrade warnings")
        let pairedNotes = AppUpdateController.releaseNotes("启动器悬停反馈\n图标与按键框轻微上浮、放大。\n\n升级注意\n升级前请保存现有内容。", format: "plain-text")
        check(pairedNotes == [.init(title: "启动器悬停反馈", detail: "图标与按键框轻微上浮、放大。"), .init(title: "升级注意", detail: "升级前请保存现有内容。")],
              "release paragraphs keep a short heading and its explanatory text together")
        let listNotes = AppUpdateController.releaseNotes("- First change\n  Important details\n- Second change\n\nA standalone paragraph.", format: "plain-text")
        check(listNotes == [.init(title: "First change", detail: "Important details"), .init(title: "Second change", detail: nil), .init(title: "A standalone paragraph.", detail: nil)],
              "explicit bullet lists preserve item boundaries and standalone paragraphs without invented headings")
        check(AppUpdateController.allowedInformationURL(URL(string: "https://github.com/uuthings/DeskDen/releases/tag/v2.0.0")) != nil
              && AppUpdateController.allowedInformationURL(URL(string: "https://example.com/download")) == nil
              && AppUpdateController.allowedInformationURL(URL(string: "file:///tmp/update")) == nil,
              "informational release links permit only the product's trusted HTTPS destinations")

        let relaunch = await checkRelaunch()
        count += relaunch.count; failures += relaunch.failures
        print("App update checks: \(count - failures)/\(count) passed")
        return (count, failures)
    }

    private static func checkRelaunch() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-update-relaunch-\(UUID().uuidString)").resolvingSymlinksInPath()
        var apps: [UpdateCheckApp] = [], movers: [UpdateCheckMover] = [], services: [SpaceCleaningModel] = []
        do {
            let active = try makeApp(root.appendingPathComponent("active-dialog")); apps.append(active)
            active.owner.preparingUpdateRelaunch = true
            active.owner.updates.recordAbort(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
            check(!active.owner.preparingUpdateRelaunch && !active.owner.updates.hasError,
                  "cancelled installation authorization also revokes the earlier install-and-relaunch consent")
            var replies: [Bool] = [], presented = true
            active.owner.replyToSystemTermination = { replies.append($0) }
            let modal = UUID()
            active.model.modals.present(id: modal, parentID: nil, width: 470, content: AnyView(Text("Synthetic unsaved dialog")),
                requestDismiss: {}, isStillPresented: { presented }, invalidate: { presented = false })
            active.owner.preparingUpdateRelaunch = true
            let denied = active.owner.applicationShouldTerminate(NSApp)
            check(denied == .terminateCancel && active.model.modals.top?.id == modal && presented && replies.isEmpty
                    && !active.owner.systemTerminationPending && active.owner.preparingUpdateRelaunch && !active.model.quitting,
                  "install-and-relaunch preserves an active dialog and cancels termination without a second generic quit confirmation")
            presented = false; active.model.modals.remove(modal)
            let dialogRetry = active.owner.applicationShouldTerminate(NSApp)
            let dialogRetryFinished = await wait { replies == [true] }
            check(dialogRetry == .terminateLater && dialogRetryFinished && !active.model.confirmingQuit && active.model.quitting && replies == [true],
                  "after closing the blocking dialog, Sparkle's same relaunch intent retries the safety chain without a new delegate notification or generic quit prompt")

            let dirty = try makeApp(root.appendingPathComponent("dirty-launcher")); apps.append(dirty)
            dirty.owner.configuration.bindings["D"] = KeyBinding(target: LaunchTarget(kind: .web, name: "Synthetic draft", location: "https://example.com"))
            dirty.owner.configuration.bindingHotKeys["D"] = BindingHotKey(keyCode: 2, control: true, option: true, command: true)
            try dirty.owner.store.save(dirty.owner.configuration)
            let original = try Data(contentsOf: dirty.owner.store.url)
            dirty.owner.showBindingHotKey("D")
            guard let form = (dirty.owner.editorPanel?.contentView as? BindingPopoverSurface)?.card as? BindingHotKeyForm else { throw UpdateCheckError.missingFixture }
            form.subviews.compactMap { $0 as? ActionButton }.first { $0.title == "清除" }?.performClick(nil)
            var offeredDraftChoice = false, dirtyReplies: [Bool] = []
            dirty.owner.presentQuitDraftAlert = { alert in offeredDraftChoice = alert.buttons.map(\.title) == ["保存并退出", "继续编辑", "放弃并退出"]; return .alertSecondButtonReturn }
            dirty.owner.replyToSystemTermination = { dirtyReplies.append($0) }
            dirty.owner.preparingUpdateRelaunch = true
            let draftReply = dirty.owner.applicationShouldTerminate(NSApp)
            check(draftReply == .terminateCancel && offeredDraftChoice && form.hasChanges && dirtyReplies.isEmpty
                    && !dirty.model.quitting && !dirty.model.confirmingQuit && !dirty.owner.systemTerminationPending
                    && (try? Data(contentsOf: dirty.owner.store.url)) == original,
                  "install-and-relaunch honors Continue Editing and preserves a dirty launcher form and its persisted source")
            dirty.owner.updates.finishUpdateCycle()
            let cycleCleared = !dirty.owner.preparingUpdateRelaunch
            let ordinaryReply = dirty.owner.applicationShouldTerminate(NSApp)
            let ordinaryConfirmation = dirty.model.confirmingQuit && dirty.owner.systemTerminationPending && !dirty.model.quitting && dirtyReplies.isEmpty
            dirty.model.confirmingQuit = false
            check(cycleCleared && ordinaryReply == .terminateLater && ordinaryConfirmation && dirtyReplies == [false]
                    && !dirty.owner.systemTerminationPending && !dirty.model.confirmingQuit && !dirty.model.quitting
                    && form.hasChanges && (try? Data(contentsOf: dirty.owner.store.url)) == original,
                  "finishing a refused update cycle revokes its relaunch consent, so the next ordinary quit requires cancellable confirmation and preserves the unsaved draft")
            dirty.owner.closeOverlay(render: false)

            let vault = try makeApp(root.appendingPathComponent("pending-vault")); apps.append(vault)
            guard await vault.model.vault.create(password: "synthetic-update-password", confirmation: "synthetic-update-password") else { throw UpdateCheckError.missingFixture }
            vault.model.vault.newDocument(); guard vault.model.vault.flush() else { throw UpdateCheckError.missingFixture }
            let encrypted = try Data(contentsOf: vault.model.vault.vaultDataURL)
            let previous = vault.model.vault.vaultDataURL.appendingPathExtension("previous")
            try? FileManager.default.removeItem(at: previous); try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
            vault.model.vault.updateBody("Synthetic update write must be preserved")
            var offeredVaultChoice = false, vaultReplies: [Bool] = [], vaultAlerts = 0
            vault.owner.presentQuitDraftAlert = { alert in vaultAlerts += 1; offeredVaultChoice = alert.buttons.map(\.title) == ["返回重试", "放弃未保存修改并退出"]; return .alertFirstButtonReturn }
            vault.owner.replyToSystemTermination = { vaultReplies.append($0) }; vault.owner.preparingUpdateRelaunch = true
            let vaultReply = vault.owner.applicationShouldTerminate(NSApp)
            check(vaultReply == .terminateCancel && offeredVaultChoice && vault.model.vault.hasPendingSave
                    && !vault.model.quitting && vault.owner.preparingUpdateRelaunch && vaultReplies.isEmpty && (try? Data(contentsOf: vault.model.vault.vaultDataURL)) == encrypted,
                  "install-and-relaunch cannot discard encrypted pending text when a real atomic write fails and the user returns to retry")
            try FileManager.default.removeItem(at: previous)
            check(vault.model.vault.flush() && !vault.model.vault.hasPendingSave,
                  "a cancelled update relaunch preserves the latest encrypted revision for a successful save retry")
            let vaultRetry = vault.owner.applicationShouldTerminate(NSApp)
            let vaultRetryFinished = await wait { vaultReplies == [true] }
            check(vaultRetry == .terminateLater && vaultRetryFinished && vaultAlerts == 1 && !vault.model.confirmingQuit && vaultReplies == [true],
                  "after the encrypted save succeeds, Sparkle retries the retained relaunch intent and replies once without another save or generic quit prompt")

            let rawTransaction = root.appendingPathComponent("gated-processing")
            try FileManager.default.createDirectory(at: rawTransaction, withIntermediateDirectories: true)
            // Journal directories use the same POSIX-canonical spelling as the
            // production scanner; /var is a symlink and must not bypass its no-follow gate.
            guard let transaction = SpaceCleaningScanner.canonicalURL(rawTransaction) else { throw UpdateCheckError.missingFixture }
            let source = transaction.appendingPathComponent("home/Downloads"), trash = transaction.appendingPathComponent("fake-trash"), data = transaction.appendingPathComponent("storage")
            for url in [source, trash, data] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            for name in ["a.cache", "b.cache"] { try Data(("synthetic update " + name).utf8).write(to: source.appendingPathComponent(name)) }
            let mover = UpdateCheckMover(root: transaction, trash: trash); movers.append(mover)
            let storage = SpaceCleaningModel(dataDirectory: data, homeDirectory: transaction.appendingPathComponent("home"), mover: mover); services.append(storage)
            storage.startScan(); await storage.waitUntilIdle()
            guard storage.screen == .results, storage.items.count == 2 else { throw UpdateCheckError.missingFixture }
            storage.resultTab = .reviewable; storage.toggleVisibleSelection(); storage.requestCleanup()
            guard await wait({ mover.entered }) else { throw UpdateCheckError.missingFixture }
            let installed = try makeApp(transaction.appendingPathComponent("app"), cleaning: storage); apps.append(installed)
            _ = await wait { !installed.notifier.pending.isEmpty }
            installed.notifier.armClear()
            var installReplies: [Bool] = [], terminations = 0
            installed.owner.replyToSystemTermination = { installReplies.append($0) }; installed.owner.terminateApplication = { terminations += 1 }
            installed.owner.preparingUpdateRelaunch = true
            let installReply = installed.owner.applicationShouldTerminate(NSApp)
            _ = await wait { installed.model.calendar.ownNotificationsSuspendedForQuit }
            check(installReply == .terminateLater && installed.model.quitting && !installed.model.confirmingQuit
                    && installed.owner.systemTerminationPending && installReplies.isEmpty && !installed.notifier.clearEntered && storage.isBusy,
                  "explicit Install and Relaunch skips generic quit consent but waits for the current cleaning transaction before notifications")
            let repeated = installed.owner.applicationShouldTerminate(NSApp)
            check(repeated == .terminateLater && !installed.model.confirmingQuit && installReplies.isEmpty,
                  "a repeated native termination request during update preparation cannot start another confirmation or reply early")
            mover.release()
            guard await wait({ installed.notifier.clearEntered }) else { throw UpdateCheckError.missingFixture }
            let receipts = try SpaceCleaningHistoryStore(fileURL: data.appendingPathComponent("history.json")).records
            check(!storage.isBusy && mover.moves == 1 && receipts.count == 1 && receipts.first?.state == .trashed && storage.batches.flatMap(\.items).map(\.id) == receipts.map(\.id) && installReplies.isEmpty,
                  "update relaunch waits for a durable cleaning receipt, cancels the next file and still defers its OS reply for notification clearing")
            installed.notifier.releaseClear()
            let finished = await wait { installReplies == [true] }
            await installed.model.waitForQuitPreparation()
            check(finished && installReplies == [true] && terminations == 0 && !installed.owner.systemTerminationPending
                    && installed.model.quitting && installed.notifier.pending.isEmpty && !mover.timedOut,
                  "safe update preparation approves its pending native termination exactly once without another terminate call or installer")
            await installed.model.calendar.refresh(); await settle()
            check(installReplies == [true] && installed.notifier.pending.isEmpty && installed.model.calendar.ownNotificationsSuspendedForQuit,
                  "returning from the injected update termination boundary cannot duplicate replies or recreate pending notifications")
            check(apps.allSatisfy { !$0.device.isSampling && $0.system.permissionRequests == 0 && $0.deviceNotifications.requests == 0 && $0.aiNotifications.requests == 0 },
                  "all update relaunch fixtures avoid real sensors, system reminder authorization, notifications and OS termination")
        } catch { check(false, "update relaunch fixture: \(error.localizedDescription)") }
        for mover in movers { mover.release() }
        for app in apps {
            app.notifier.releaseClear(); app.owner.replyToSystemTermination = { _ in }; app.owner.terminateApplication = {}
            await app.model.waitForQuitPreparation(); app.model.confirmingQuit = false; app.model.shutdown()
            app.owner.workbenchController?.window?.delegate = nil; app.owner.workbenchController?.window?.close(); app.owner.workbenchController = nil
            app.owner.closeOverlay(render: false); app.owner.panel.orderOut(nil); app.owner.toastTask?.cancel()
        }
        for service in services { await service.prepareForQuit() }
        try? FileManager.default.removeItem(at: root)
        return (count, failures)
    }

    private struct UpdateCheckApp {
        let owner: LauncherController; let model: WorkbenchAppModel; let notifier: UpdateCheckReminderNotifications
        let device: DeviceStatusModel; let system: UpdateCheckCalendar
        let deviceNotifications: UpdateCheckDeviceNotifications; let aiNotifications: UpdateCheckAINotifications
    }
    private static func makeApp(_ directory: URL, cleaning: SpaceCleaningModel? = nil) throws -> UpdateCheckApp {
        let owner = LauncherController(dataDirectory: directory.appendingPathComponent("Launcher"))
        owner.configurePanel(); owner.scanning = true; try owner.store.save(owner.configuration)
        let system = UpdateCheckCalendar(), notifier = UpdateCheckReminderNotifications(), calendarDirectory = directory.appendingPathComponent("Calendar")
        var snapshot = ReminderSnapshot(); snapshot.preferences.notificationsEnabled = true
        snapshot.reminders = [ReminderItem(id: "update-relaunch", title: "Synthetic update reminder", due: ReminderDue(date: Date().addingTimeInterval(86_400), includesTime: true))]
        try ReminderStore(directory: calendarDirectory).save(snapshot)
        let calendar = CalendarModel(dataDirectory: calendarDirectory, system: system, notifier: notifier)
        let aiDirectory = directory.appendingPathComponent("AI"), sourcesDirectory = aiDirectory.appendingPathComponent("AIUsage")
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        let sources = AIProvider.allCases.map { AIUsageSourceConfiguration(provider: $0, enabled: false, sessionsPath: directory.appendingPathComponent("disabled-" + $0.rawValue).path) }
        try JSONEncoder().encode(sources).write(to: sourcesDirectory.appendingPathComponent("sources.json"))
        let deviceNotifications = UpdateCheckDeviceNotifications(), aiNotifications = UpdateCheckAINotifications()
        let device = DeviceStatusModel(dataDirectory: directory.appendingPathComponent("Device"), notifications: deviceNotifications)
        let ai = AIUsageModel(dataDirectory: aiDirectory, startServices: false, notifications: aiNotifications)
        let model = WorkbenchAppModel(owner: owner, calendar: calendar, ai: ai, device: device, cleaning: cleaning, startServices: false)
        model.route = .overview; owner.workbenchController = WorkbenchWindowController(owner: owner, model: model, autosavesFrame: false)
        owner.replyToSystemTermination = { _ in }; owner.terminateApplication = {}
        return .init(owner: owner, model: model, notifier: notifier, device: device, system: system, deviceNotifications: deviceNotifications, aiNotifications: aiNotifications)
    }
    private static func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        repeat { if condition() { return true }; try? await Task.sleep(for: .milliseconds(2)) } while ContinuousClock.now < deadline
        return condition()
    }
    private static func settle() async { for _ in 0..<20 { await Task.yield() } }
}

@MainActor private final class UpdateCheckEngineFactory {
    let defaults: UserDefaults
    var engines: [UpdateCheckEngine] = []
    var failingStarts = 0
    init(defaults: UserDefaults) { self.defaults = defaults }
    func make(_ controller: AppUpdateController) -> any AppUpdateEngine {
        let engine = UpdateCheckEngine(defaults: defaults, failsStart: failingStarts > 0)
        if failingStarts > 0 { failingStarts -= 1 }; engines.append(engine); return engine
    }
}
@MainActor private final class UpdateCheckEngine: AppUpdateEngine {
    let defaults: UserDefaults; let failsStart: Bool
    var starts = 0, checks = 0, backgroundChecks = 0, automaticWrites = 0
    var canCheckForUpdates = true
    var sessionInProgress = false
    var lastUpdateCheckDate: Date?
    private var automatic: Bool
    private var changed: (@MainActor () -> Void)?
    init(defaults: UserDefaults, failsStart: Bool) {
        self.defaults = defaults; self.failsStart = failsStart; automatic = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
    }
    var automaticallyChecksForUpdates: Bool {
        get { automatic }
        set { automaticWrites += 1; automatic = newValue; defaults.set(newValue, forKey: "SUEnableAutomaticChecks"); changed?() }
    }
    func start() throws { starts += 1; if failsStart { throw UpdateCheckError.engineStart } }
    func checkForUpdates() { checks += 1; canCheckForUpdates = false; sessionInProgress = true; changed?() }
    func checkForUpdatesInBackground() { backgroundChecks += 1; canCheckForUpdates = false; sessionInProgress = true; changed?() }
    func observeChanges(_ changed: @escaping @MainActor () -> Void) -> Set<AnyCancellable> { self.changed = changed; return [] }
    func complete(at date: Date) { canCheckForUpdates = true; sessionInProgress = false; lastUpdateCheckDate = date; changed?() }
}
private enum UpdateCheckError: Error { case engineStart, missingFixture, unsafePath, timedOut }
@MainActor private final class UpdateCheckReminderNotifications: ReminderNotificationProviding {
    var pending: [ReminderNotification] = [], clearEntered = false
    private var holdClear = false
    private var continuation: CheckedContinuation<Void, Error>?
    func armClear() { holdClear = true; clearEntered = false }
    func releaseClear() { holdClear = false; let waiting = continuation; continuation = nil; waiting?.resume() }
    func access() async -> CalendarAccess { .granted }
    func requestAccess() async throws -> Bool { true }
    func replacePending(_ notifications: [ReminderNotification]) async throws {
        if holdClear && notifications.isEmpty { clearEntered = true; try await withCheckedThrowingContinuation { continuation = $0 } }
        pending = notifications
    }
}
@MainActor private final class UpdateCheckCalendar: CalendarSystemProviding {
    var permissionRequests = 0
    func access(reminders: Bool) -> CalendarAccess { .notDetermined }
    func requestAccess(reminders: Bool) async throws -> Bool { permissionRequests += 1; return false }
    func events(in interval: DateInterval) throws -> [CalendarEventItem] { [] }
    func reminders() async throws -> [ReminderItem] { [] }
    func writableReminderCalendars() -> [ReminderCalendar] { [] }
    func saveReminder(_ item: ReminderItem, creating: Bool) throws -> ReminderItem { throw ReminderError.unavailable("Synthetic update check") }
    func deleteReminder(_ item: ReminderItem) throws { throw ReminderError.unavailable("Synthetic update check") }
}
@MainActor private final class UpdateCheckDeviceNotifications: DeviceNotificationProviding {
    var requests = 0
    func permission() async -> DeviceNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { requests += 1; return false }
    func deliver(_ event: DeviceMonitoringEvent, budget: DeviceTrafficBudget, rule: DeviceTemperatureRule) async throws {}
}
@MainActor private final class UpdateCheckAINotifications: AIQuotaNotificationProviding {
    var requests = 0
    func permission() async -> AIQuotaNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { requests += 1; return false }
    func deliver(_ event: AIQuotaAlertEvent) async throws {}
}
private final class UpdateCheckMover: SpaceCleaningFileOperating, @unchecked Sendable {
    private let condition = NSCondition(), root: URL, trash: URL
    private var released = false, enteredValue = false, movesValue = 0, timedOutValue = false
    init(root: URL, trash: URL) { self.root = root; self.trash = trash }
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return enteredValue }
    var moves: Int { condition.lock(); defer { condition.unlock() }; return movesValue }
    var timedOut: Bool { condition.lock(); defer { condition.unlock() }; return timedOutValue }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func moveToTrash(_ source: URL) throws -> URL {
        guard source.path.hasPrefix(root.path + "/"), trash.path.hasPrefix(root.path + "/") else { throw UpdateCheckError.unsafePath }
        condition.lock(); movesValue += 1; enteredValue = true
        let deadline = Date().addingTimeInterval(12)
        while !released { if !condition.wait(until: deadline), !released { timedOutValue = true; condition.unlock(); throw UpdateCheckError.timedOut } }
        condition.unlock()
        let destination = trash.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: source, to: destination); return destination
    }
}
