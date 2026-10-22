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
        let suite = "test.fangcun-updates.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return (1, 1) }
        defer { defaults.removePersistentDomain(forName: suite) }
        let information: [String: Any] = [
            "SUFeedURL": "https://example.com/fangcun/appcast.xml",
            "SUPublicEDKey": Data((0..<32).map(UInt8.init)).base64EncodedString(),
            "SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": false,
            "SUAllowsAutomaticUpdates": false, "SUVerifyUpdateBeforeExtraction": true, "SURequireSignedFeed": true
        ]
        let factory = UpdateCheckEngineFactory(defaults: defaults)
        let updates = AppUpdateController(defaults: defaults, information: information, engineFactory: factory.make)
        updates.startAutomaticCheckingIfEnabled()
        check(factory.engines.isEmpty && !updates.automaticallyChecks && updates.canCheck && defaults.object(forKey: "SUEnableAutomaticChecks") == nil,
              "fresh manual mode constructs no update engine, performs no check and writes no automatic-check preference")
        updates.checkForUpdates()
        guard let first = factory.engines.first else {
            check(false, "manual update check creates an injected engine"); return (count, failures)
        }
        check(factory.engines.count == 1 && first.starts == 1 && first.checks == 1 && !updates.canCheck && !updates.hasError,
              "one explicit manual update action starts the lazy engine once and requests exactly one check")
        updates.checkForUpdates(); updates.checkForUpdates()
        check(factory.engines.count == 1 && first.starts == 1 && first.checks == 1,
              "busy update checking rejects repeated actions instead of creating engines or overlapping checks")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        first.complete(at: date)
        check(updates.canCheck && updates.lastChecked == date, "engine changes restore availability and publish the actual last-check date")
        updates.checkForUpdates()
        check(first.checks == 2 && first.starts == 1 && !updates.canCheck,
              "a later explicit manual action reuses the same engine after the prior check completes")
        first.complete(at: date)
        check(first.automaticWrites == 0 && defaults.object(forKey: "SUEnableAutomaticChecks") == nil,
              "manual checks and observed engine changes never enable automatic checking")

        updates.setAutomaticallyChecks(true)
        check(updates.automaticallyChecks && first.automaticWrites == 1 && defaults.bool(forKey: "SUEnableAutomaticChecks") && first.checks == 2,
              "only explicit preference changes enable automatic checks using Sparkle's own persisted preference key")
        let restoredFactory = UpdateCheckEngineFactory(defaults: defaults)
        let restored = AppUpdateController(defaults: defaults, information: information, engineFactory: restoredFactory.make)
        check(restored.automaticallyChecks && restoredFactory.engines.isEmpty,
              "restoring an enabled preference stays lazy until the launch hook is called")
        restored.startAutomaticCheckingIfEnabled(); restored.startAutomaticCheckingIfEnabled()
        check(restoredFactory.engines.count == 1 && restoredFactory.engines[0].starts == 1 && restoredFactory.engines[0].automaticallyChecksForUpdates,
              "launch restores the same automatic-check preference and starts only one engine")
        restored.setAutomaticallyChecks(false)
        let manualFactory = UpdateCheckEngineFactory(defaults: defaults)
        let manual = AppUpdateController(defaults: defaults, information: information, engineFactory: manualFactory.make)
        manual.startAutomaticCheckingIfEnabled()
        check(!restored.automaticallyChecks && !manual.automaticallyChecks && manualFactory.engines.isEmpty && defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool == false,
              "an explicit opt-out survives recreation and prevents subsequent launch-time updater startup")
        defaults.set(date, forKey: "SULastCheckTime")
        let history = AppUpdateController(defaults: defaults, information: information, engineFactory: manualFactory.make)
        check(history.lastChecked == date && manualFactory.engines.isEmpty, "displaying the saved last-check time requires no engine or network request")

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
        invalidValue("SUEnableAutomaticChecks", true, "automatic checking enabled by build default")
        invalidValue("SUAutomaticallyUpdate", true, "automatic installation enabled")
        invalidValue("SUAllowsAutomaticUpdates", true, "automatic installation allowed")
        invalidValue("SUVerifyUpdateBeforeExtraction", false, "pre-extraction verification disabled")
        invalidValue("SURequireSignedFeed", false, "unsigned feed allowed")
        invalidValue("SURequireSignedFeed", nil, "missing signed-feed requirement")
        for (label, entry) in invalid {
            let spy = UpdateCheckEngineFactory(defaults: defaults)
            let controller = AppUpdateController(defaults: defaults, information: entry, engineFactory: spy.make)
            controller.startAutomaticCheckingIfEnabled(); controller.setAutomaticallyChecks(true); controller.checkForUpdates()
            check(!AppUpdateController.configurationIsValid(entry) && !controller.canCheck && controller.hasError
                    && spy.engines.isEmpty && defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool == false,
                  "update configuration rejects \(label) before constructing or starting an engine")
        }
        let blockedFactory = UpdateCheckEngineFactory(defaults: defaults)
        let blocked = AppUpdateController(defaults: defaults, information: information, allowsStarting: false, engineFactory: blockedFactory.make)
        blocked.checkForUpdates(); blocked.setAutomaticallyChecks(true)
        check(blockedFactory.engines.isEmpty && !blocked.automaticallyChecks,
              "an explicitly disabled updater environment cannot construct an engine through manual checks or opt-in")
        let retryFactory = UpdateCheckEngineFactory(defaults: defaults); retryFactory.failingStarts = 1
        let retry = AppUpdateController(defaults: defaults, information: information, engineFactory: retryFactory.make)
        retry.setAutomaticallyChecks(true)
        check(retry.hasError && !retry.automaticallyChecks && retryFactory.engines.count == 1 && retryFactory.engines[0].checks == 0
                && defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool == false,
              "a failed engine start preserves manual preference and never dispatches a check")
        retry.checkForUpdates()
        check(!retry.hasError && retryFactory.engines.count == 2 && retryFactory.engines[1].starts == 1 && retryFactory.engines[1].checks == 1,
              "a failed updater start can be retried with a fresh engine and one explicit manual check")
        let optInRetryFactory = UpdateCheckEngineFactory(defaults: defaults); optInRetryFactory.failingStarts = 1
        let optInRetry = AppUpdateController(defaults: defaults, information: information, engineFactory: optInRetryFactory.make)
        optInRetry.setAutomaticallyChecks(true)
        check(optInRetry.hasError && !optInRetry.automaticallyChecks, "a failed explicit opt-in reports its start error without saving an enabled preference")
        optInRetry.setAutomaticallyChecks(true)
        check(!optInRetry.hasError && optInRetry.automaticallyChecks && optInRetryFactory.engines.count == 2
                && optInRetryFactory.engines[1].checks == 0 && defaults.bool(forKey: "SUEnableAutomaticChecks"),
              "retrying explicit automatic-check opt-in clears the prior start failure without dispatching a manual check")

        let abortFactory = UpdateCheckEngineFactory(defaults: defaults)
        let aborted = AppUpdateController(defaults: defaults, information: information, engineFactory: abortFactory.make)
        aborted.recordAbort(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        check(aborted.hasError, "an actual feed transport failure remains an update error")
        aborted.recordAbort(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        let cancellationStatus = aborted.status
        check(!aborted.hasError && cancellationStatus == "已取消更新，当前版本继续使用" && abortFactory.engines.isEmpty,
              "cancelling Sparkle installation authorization clears a previous channel error and reports a normal cancellation without an engine or installer")
        aborted.recordAbort(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        check(!aborted.hasError && aborted.status == cancellationStatus,
              "the no-update completion still preserves the status already published by its specific delegate callback")
        aborted.recordAbort(NSError(domain: NSURLErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        check(aborted.hasError && abortFactory.engines.isEmpty,
              "a coincidentally equal error code from another domain cannot hide a real update failure")

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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-update-relaunch-\(UUID().uuidString)").resolvingSymlinksInPath()
        var apps: [UpdateCheckApp] = [], movers: [UpdateCheckMover] = [], services: [StorageReviewService] = []
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

            let transaction = root.appendingPathComponent("gated-processing"), source = transaction.appendingPathComponent("source"), trash = transaction.appendingPathComponent("fake-trash"), data = transaction.appendingPathComponent("storage")
            for url in [source, trash, data] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            for name in ["a.cache", "b.cache"] { try Data(("synthetic update " + name).utf8).write(to: source.appendingPathComponent(name)) }
            let mover = UpdateCheckMover(root: transaction, trash: trash); movers.append(mover)
            let storage = StorageReviewService(dataDirectory: data, mover: mover); services.append(storage)
            try storage.registerScope(.init(directory: source, kind: .rebuildableCache)); storage.scan(kinds: [.rebuildableCache])
            guard await wait({ !storage.isScanning && storage.report?.stage == .report }), let report = storage.report else { throw UpdateCheckError.missingFixture }
            storage.selectAll(report.candidates); storage.prepareProcessing(); storage.executeConfirmedPlan()
            guard await wait({ mover.entered }) else { throw UpdateCheckError.missingFixture }
            let installed = try makeApp(transaction.appendingPathComponent("app"), storage: storage); apps.append(installed)
            _ = await wait { !installed.notifier.pending.isEmpty }
            installed.notifier.armClear()
            var installReplies: [Bool] = [], terminations = 0
            installed.owner.replyToSystemTermination = { installReplies.append($0) }; installed.owner.terminateApplication = { terminations += 1 }
            installed.owner.preparingUpdateRelaunch = true
            let installReply = installed.owner.applicationShouldTerminate(NSApp)
            _ = await wait { installed.model.calendar.ownNotificationsSuspendedForQuit }
            check(installReply == .terminateLater && installed.model.quitting && !installed.model.confirmingQuit
                    && installed.owner.systemTerminationPending && installReplies.isEmpty && !installed.notifier.clearEntered && storage.isProcessing,
                  "explicit Install and Relaunch skips generic quit consent but waits for the current health transaction before notifications")
            let repeated = installed.owner.applicationShouldTerminate(NSApp)
            check(repeated == .terminateLater && !installed.model.confirmingQuit && installReplies.isEmpty,
                  "a repeated native termination request during update preparation cannot start another confirmation or reply early")
            mover.release()
            guard await wait({ installed.notifier.clearEntered }) else { throw UpdateCheckError.missingFixture }
            let receipts = try JSONDecoder().decode([StorageReviewReceipt].self, from: Data(contentsOf: data.appendingPathComponent("storage-actions.json")))
            check(!storage.isProcessing && mover.moves == 1 && receipts == storage.receipts && receipts.count == 1 && installReplies.isEmpty,
                  "update relaunch waits for a durable health receipt, cancels the next file and still defers its OS reply for notification clearing")
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
        for service in services { await service.stopForQuit() }
        try? FileManager.default.removeItem(at: root)
        return (count, failures)
    }

    private struct UpdateCheckApp {
        let owner: LauncherController; let model: WorkbenchAppModel; let notifier: UpdateCheckReminderNotifications
        let device: DeviceStatusModel; let system: UpdateCheckCalendar
        let deviceNotifications: UpdateCheckDeviceNotifications; let aiNotifications: UpdateCheckAINotifications
    }
    private static func makeApp(_ directory: URL, storage: StorageReviewService? = nil) throws -> UpdateCheckApp {
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
        let health = HealthCenterModel(device: device, dataDirectory: directory.appendingPathComponent("Health"), storageService: storage)
        let ai = AIUsageModel(dataDirectory: aiDirectory, startServices: false, notifications: aiNotifications)
        let model = WorkbenchAppModel(owner: owner, calendar: calendar, ai: ai, device: device, health: health, startServices: false)
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
    var starts = 0, checks = 0, automaticWrites = 0
    var canCheckForUpdates = true
    var lastUpdateCheckDate: Date?
    private var automatic: Bool
    private var changed: (@MainActor () -> Void)?
    init(defaults: UserDefaults, failsStart: Bool) {
        self.defaults = defaults; self.failsStart = failsStart; automatic = defaults.bool(forKey: "SUEnableAutomaticChecks")
    }
    var automaticallyChecksForUpdates: Bool {
        get { automatic }
        set { automaticWrites += 1; automatic = newValue; defaults.set(newValue, forKey: "SUEnableAutomaticChecks"); changed?() }
    }
    func start() throws { starts += 1; if failsStart { throw UpdateCheckError.engineStart } }
    func checkForUpdates() { checks += 1; canCheckForUpdates = false; changed?() }
    func observeChanges(_ changed: @escaping @MainActor () -> Void) -> Set<AnyCancellable> { self.changed = changed; return [] }
    func complete(at date: Date) { canCheckForUpdates = true; lastUpdateCheckDate = date; changed?() }
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
private final class UpdateCheckMover: StorageReviewFileMoving, @unchecked Sendable {
    private let condition = NSCondition(), root: URL, trash: URL
    private var released = false, enteredValue = false, movesValue = 0, timedOutValue = false
    init(root: URL, trash: URL) { self.root = root.resolvingSymlinksInPath(); self.trash = trash }
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return enteredValue }
    var moves: Int { condition.lock(); defer { condition.unlock() }; return movesValue }
    var timedOut: Bool { condition.lock(); defer { condition.unlock() }; return timedOutValue }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func moveToTrash(_ source: URL) throws -> URL {
        guard source.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw UpdateCheckError.unsafePath }
        condition.lock(); movesValue += 1; enteredValue = true
        let deadline = Date().addingTimeInterval(12)
        while !released { if !condition.wait(until: deadline), !released { timedOutValue = true; condition.unlock(); throw UpdateCheckError.timedOut } }
        condition.unlock()
        let destination = trash.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: source, to: destination); return destination
    }
    func moveBack(_ source: URL, to destination: URL) throws {
        guard source.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"), destination.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw UpdateCheckError.unsafePath }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
