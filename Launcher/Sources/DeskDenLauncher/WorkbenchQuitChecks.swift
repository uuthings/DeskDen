import AppKit
import LauncherCore

/// Production exit orchestration with isolated stores, a gated real file
/// transaction, fake notification APIs and injected OS termination boundaries.
@MainActor enum WorkbenchQuitChecks {
    static func run() async -> (count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ message:String){count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") \(message)")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-exit-lifecycle-\(UUID().uuidString)").resolvingSymlinksInPath()
        var apps:[QuitCheckApp]=[]
        var movers:[QuitCheckMover]=[]
        var services:[SpaceCleaningModel]=[]
        do {
            // Hold the actual cancellation API while a concurrent refresh and
            // activation callback try to replace the local notification plan.
            let calendarApp=try makeApp(root.appendingPathComponent("refresh-race"));apps.append(calendarApp)
            _=await wait {!calendarApp.notifier.pending.isEmpty}
            calendarApp.notifier.armClear()
            let suspension=Task {try await calendarApp.model.calendar.suspendOwnNotificationsForQuit()}
            let enteredClear=await wait {calendarApp.notifier.clearEntered}
            let calls=calendarApp.notifier.replacements
            await calendarApp.model.calendar.refresh()
            NotificationCenter.default.post(name:NSApplication.didBecomeActiveNotification,object:NSApp)
            await settle()
            check(enteredClear && calendarApp.model.calendar.ownNotificationsSuspendedForQuit && calendarApp.notifier.replacements == calls,
                  "quit notification gate rejects refresh and activation rescheduling while cancellation awaits")
            calendarApp.notifier.releaseClear()
            try await suspension.value
            await calendarApp.model.calendar.refresh();await settle()
            check(calendarApp.notifier.pending.isEmpty && calendarApp.model.calendar.localReminders.count == 1 && calendarApp.model.calendar.preferences.notificationsEnabled,
                  "completed suspension stays empty after refresh and preserves reminders and saved preference")
            calendarApp.model.calendar.resumeOwnNotificationsAfterCancelledQuit()
            let restored=await wait {calendarApp.notifier.pending.count == 1}
            check(restored && !calendarApp.model.calendar.ownNotificationsSuspendedForQuit,
                  "cancelled quit explicitly restores the prior local notification plan")

            let draft=try makeApp(root.appendingPathComponent("system-draft"));apps.append(draft)
            draft.owner.configuration.bindings["D"]=KeyBinding(target:LaunchTarget(kind:.web,name:"退出草稿检查",location:"https://example.com"))
            draft.owner.configuration.bindingHotKeys["D"]=BindingHotKey(keyCode:2,control:true,option:true,command:true)
            try draft.owner.store.save(draft.owner.configuration)
            let originalDraftBytes=try Data(contentsOf:draft.owner.store.url)
            draft.owner.showBindingHotKey("D")
            guard let form=(draft.owner.editorPanel?.contentView as? BindingPopoverSurface)?.card as? BindingHotKeyForm else {throw QuitCheckError.missingDraft}
            form.subviews.compactMap{$0 as? ActionButton}.first{$0.title == "清除"}?.performClick(nil)
            var draftReplies:[Bool]=[],askedToSave=false
            draft.owner.replyToSystemTermination={draftReplies.append($0)}
            draft.owner.presentQuitDraftAlert={alert in
                askedToSave=alert.buttons.map(\.title) == ["保存并退出","继续编辑","放弃并退出"]
                return .alertSecondButtonReturn
            }
            _=draft.owner.applicationShouldTerminate(NSApp);draft.model.confirmQuit()
            check(askedToSave && form.hasChanges && draftReplies == [false] && !draft.model.quitting && !draft.model.calendar.ownNotificationsSuspendedForQuit && (try? Data(contentsOf:draft.owner.store.url)) == originalDraftBytes,
                  "system quit preserves a dirty launcher form and honors Continue Editing before freezing services")
            draft.owner.closeOverlay(render:false)

            // The OS request must wait for both durable processing completion and
            // the notification cancellation boundary, without ending this process.
            let rawTransaction=root.appendingPathComponent("system-quit")
            try FileManager.default.createDirectory(at:rawTransaction,withIntermediateDirectories:true)
            guard let transactionRoot=SpaceCleaningScanner.canonicalURL(rawTransaction) else {throw QuitCheckError.missingReport}
            let source=transactionRoot.appendingPathComponent("home/Downloads"),trash=transactionRoot.appendingPathComponent("fake-trash"),data=transactionRoot.appendingPathComponent("storage")
            for url in [source,trash,data] {try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)}
            for name in ["a.cache","b.cache"] {try Data(("exit fixture "+name).utf8).write(to:source.appendingPathComponent(name))}
            let mover=QuitCheckMover(root:transactionRoot,trash:trash);movers.append(mover)
            let service=SpaceCleaningModel(dataDirectory:data,homeDirectory:transactionRoot.appendingPathComponent("home"),mover:mover);services.append(service)
            service.startScan();await service.waitUntilIdle()
            guard service.screen == .results,service.items.count == 2 else {throw QuitCheckError.missingReport}
            service.resultTab = .reviewable;service.toggleVisibleSelection();service.requestCleanup()
            let moving=await wait {mover.entered}
            let app=try makeApp(transactionRoot.appendingPathComponent("app"),cleaning:service);apps.append(app)
            _=await wait {!app.notifier.pending.isEmpty}
            var replies:[Bool]=[],terminateCalls=0
            app.owner.replyToSystemTermination={replies.append($0)}
            app.owner.terminateApplication={terminateCalls += 1}
            check(app.owner.applicationShouldTerminate(NSApp) == .terminateLater && app.model.confirmingQuit && app.owner.systemTerminationPending && replies.isEmpty,
                  "native system quit opens the shared confirmation and defers OS termination")
            app.model.confirmingQuit=false
            check(replies == [false] && !app.owner.systemTerminationPending && !app.model.quitting,
                  "cancelling system quit replies once and leaves the app available")
            replies=[];app.notifier.armClear()
            _=app.owner.applicationShouldTerminate(NSApp);app.model.confirmQuit();app.model.confirmQuit()
            await settle()
            await app.model.calendar.refresh();await settle()
            check(moving && app.model.quitting && app.model.calendar.ownNotificationsSuspendedForQuit && replies.isEmpty && !app.notifier.clearEntered && service.isBusy,
                  "confirmed system quit freezes notifications and waits for the current real cleaning transaction")
            mover.release()
            let cancellingNotifications=await wait {app.notifier.clearEntered}
            let savedReceipts=try SpaceCleaningHistoryStore(fileURL:data.appendingPathComponent("history.json")).records
            check(cancellingNotifications && !service.isBusy && savedReceipts.count == 1 && savedReceipts.first?.state == .trashed && service.batches.flatMap(\.items).map(\.id) == savedReceipts.map(\.id) && mover.moves == 1 && replies.isEmpty,
                  "system exit still waits for notifications after one durable receipt and skips the next file")
            app.notifier.releaseClear()
            let approved=await wait {replies == [true]}
            check(approved && terminateCalls == 0 && !app.owner.systemTerminationPending && app.model.quitting && app.notifier.pending.isEmpty,
                  "prepared system quit approves its existing request exactly once without another terminate call")
            await app.model.calendar.refresh();await settle()
            check(app.notifier.pending.isEmpty && app.model.calendar.ownNotificationsSuspendedForQuit && !mover.timedOut,
                  "return from the injected OS boundary cannot reopen UI or silently resume notifications")

            let failure=try makeApp(root.appendingPathComponent("cancel-failure"));apps.append(failure)
            _=await wait {!failure.notifier.pending.isEmpty}
            var failureReplies:[Bool]=[]
            failure.owner.replyToSystemTermination={failureReplies.append($0)}
            failure.notifier.armClear()
            _=failure.owner.applicationShouldTerminate(NSApp);failure.model.confirmQuit()
            _=await wait {failure.notifier.clearEntered}
            failure.notifier.releaseClear(failing:true)
            let recovered=await wait {!failure.model.quitting && !failure.model.calendar.ownNotificationsSuspendedForQuit && failure.notifier.pending.count == 1}
            let recoveryMessageShown = failure.model.message?.hasPrefix("退出前数据保存或提醒暂停未完成：") == true
            print("DETAIL quit-cancellation recovery=\(recovered) replies=\(failureReplies) confirming=\(failure.model.confirmingQuit) quitting=\(failure.model.quitting) notificationsSuspended=\(failure.model.calendar.ownNotificationsSuspendedForQuit) pending=\(failure.notifier.pending.count) message=\(failure.model.message ?? "<none>")")
            check(recovered && failureReplies == [false] && !failure.model.confirmingQuit && recoveryMessageShown,
                  "failed notification cancellation cancels native quit and restores the app and filtered schedule")

            let menu=try makeApp(root.appendingPathComponent("menu-quit"));apps.append(menu)
            var menuTerminations=0,permitReply:NSApplication.TerminateReply?
            menu.owner.terminateApplication={menuTerminations += 1;permitReply=menu.owner.applicationShouldTerminate(NSApp)}
            menu.model.requestQuit();menu.model.confirmQuit();menu.model.confirmQuit()
            let menuFinished=await wait {menuTerminations == 1}
            check(menuFinished && permitReply == .terminateNow && !menu.owner.systemTerminationPending && menu.model.calendar.ownNotificationsSuspendedForQuit && menu.notifier.pending.isEmpty,
                  "in-app confirmed quit prepares once then consumes one native termination permit")
            check(apps.allSatisfy{!$0.device.isSampling && $0.system.permissionRequests == 0 && $0.deviceNotifications.requests == 0 && $0.aiNotifications.requests == 0},
                  "exit lifecycle fixtures never start sensors or request real calendar or notification access")
        } catch {check(false,"exit lifecycle fixture: "+error.localizedDescription)}
        for mover in movers {mover.release()}
        for app in apps {
            app.notifier.releaseClear();app.owner.replyToSystemTermination={_ in};app.owner.terminateApplication={}
            await app.model.waitForQuitPreparation()
            app.model.confirmingQuit=false;app.model.shutdown()
            app.owner.workbenchController?.window?.delegate=nil;app.owner.workbenchController?.window?.close();app.owner.workbenchController=nil
            app.owner.closeOverlay(render:false);app.owner.panel.orderOut(nil);app.owner.toastTask?.cancel()
        }
        for service in services {await service.prepareForQuit()}
        try? FileManager.default.removeItem(at:root)
        return(count,failures)
    }
    private struct QuitCheckApp {
        let owner:LauncherController
        let model:WorkbenchAppModel
        let notifier:QuitCheckReminderNotifications
        let device:DeviceStatusModel
        let system:QuitCheckCalendar
        let deviceNotifications:QuitCheckDeviceNotifications
        let aiNotifications:QuitCheckAINotifications
    }
    private static func makeApp(_ directory:URL,cleaning:SpaceCleaningModel?=nil) throws -> QuitCheckApp {
        let owner=LauncherController(dataDirectory:directory.appendingPathComponent("Launcher"))
        owner.configurePanel();owner.scanning=true
        try owner.store.save(owner.configuration)
        let system=QuitCheckCalendar(),notifier=QuitCheckReminderNotifications()
        let calendarDirectory=directory.appendingPathComponent("Calendar")
        var snapshot=ReminderSnapshot();snapshot.preferences.notificationsEnabled=true
        snapshot.reminders=[ReminderItem(id:"exit-reminder",title:"隔离退出提醒",due:ReminderDue(date:Date().addingTimeInterval(86_400),includesTime:true))]
        try ReminderStore(directory:calendarDirectory).save(snapshot)
        let calendar=CalendarModel(dataDirectory:calendarDirectory,system:system,notifier:notifier)
        let aiDirectory=directory.appendingPathComponent("AI"),aiSources=aiDirectory.appendingPathComponent("AIUsage")
        try FileManager.default.createDirectory(at:aiSources,withIntermediateDirectories:true)
        let sources=AIProvider.allCases.map{AIUsageSourceConfiguration(provider:$0,enabled:false,sessionsPath:directory.appendingPathComponent("disabled-"+$0.rawValue).path)}
        try JSONEncoder().encode(sources).write(to:aiSources.appendingPathComponent("sources.json"))
        let deviceNotifications=QuitCheckDeviceNotifications(),aiNotifications=QuitCheckAINotifications()
        let device=DeviceStatusModel(dataDirectory:directory.appendingPathComponent("Device"),notifications:deviceNotifications)
        let ai=AIUsageModel(dataDirectory:aiDirectory,startServices:false,notifications:aiNotifications)
        let model=WorkbenchAppModel(owner:owner,calendar:calendar,ai:ai,device:device,cleaning:cleaning,startServices:false)
        model.route = .settings
        owner.workbenchController=WorkbenchWindowController(owner:owner,model:model,autosavesFrame:false)
        owner.replyToSystemTermination={_ in};owner.terminateApplication={}
        return .init(owner:owner,model:model,notifier:notifier,device:device,system:system,deviceNotifications:deviceNotifications,aiNotifications:aiNotifications)
    }
    private static func wait(_ condition:@MainActor ()->Bool) async -> Bool {
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        repeat {if condition(){return true};try? await Task.sleep(for:.milliseconds(2))}while ContinuousClock.now < deadline
        return condition()
    }
    private static func settle() async {for _ in 0..<20 {await Task.yield()}}
}

private enum QuitCheckError:Error {case missingReport,missingDraft,cancellationFailed,unsafePath,timeout}
@MainActor private final class QuitCheckReminderNotifications:ReminderNotificationProviding {
    var pending:[ReminderNotification]=[]
    var replacements=0
    var clearEntered=false
    private var holdClear=false
    private var continuation:CheckedContinuation<Void,Error>?
    func armClear(){holdClear=true;clearEntered=false}
    func releaseClear(failing:Bool=false){holdClear=false;let waiting=continuation;continuation=nil;if failing {waiting?.resume(throwing:QuitCheckError.cancellationFailed)}else{waiting?.resume()}}
    func access() async -> CalendarAccess {.granted}
    func requestAccess() async throws -> Bool {true}
    func replacePending(_ notifications:[ReminderNotification]) async throws {
        replacements += 1
        if holdClear && notifications.isEmpty {
            clearEntered=true
            try await withCheckedThrowingContinuation{(waiting:CheckedContinuation<Void,Error>) in continuation=waiting}
        }
        pending=notifications
    }
}
@MainActor private final class QuitCheckCalendar:CalendarSystemProviding {
    var permissionRequests=0
    func access(reminders:Bool)->CalendarAccess {.notDetermined}
    func requestAccess(reminders:Bool) async throws -> Bool {permissionRequests += 1;return false}
    func events(in interval:DateInterval) throws -> [CalendarEventItem] {[]}
    func reminders() async throws -> [ReminderItem] {[]}
    func writableReminderCalendars()->[ReminderCalendar] {[]}
    func saveReminder(_ item:ReminderItem,creating:Bool) throws -> ReminderItem {throw ReminderError.unavailable("退出检查不写系统提醒")}
    func deleteReminder(_ item:ReminderItem) throws {throw ReminderError.unavailable("退出检查不删系统提醒")}
}
@MainActor private final class QuitCheckDeviceNotifications:DeviceNotificationProviding {
    var requests=0
    func permission() async -> DeviceNotificationPermission {.denied}
    func requestPermission() async throws -> Bool {requests += 1;return false}
    func deliver(_ event:DeviceMonitoringEvent,budget:DeviceTrafficBudget,rule:DeviceTemperatureRule) async throws {}
}
@MainActor private final class QuitCheckAINotifications:AIQuotaNotificationProviding {
    var requests=0
    func permission() async -> AIQuotaNotificationPermission {.denied}
    func requestPermission() async throws -> Bool {requests += 1;return false}
    func deliver(_ event:AIQuotaAlertEvent) async throws {}
}
private final class QuitCheckMover:SpaceCleaningFileOperating,@unchecked Sendable {
    private let condition=NSCondition()
    private let root:URL,trash:URL
    private var released=false,enteredValue=false,timedOutValue=false,movesValue=0
    init(root:URL,trash:URL){self.root=root;self.trash=trash}
    var entered:Bool {condition.lock();defer{condition.unlock()};return enteredValue}
    var moves:Int {condition.lock();defer{condition.unlock()};return movesValue}
    var timedOut:Bool {condition.lock();defer{condition.unlock()};return timedOutValue}
    func release(){condition.lock();released=true;condition.broadcast();condition.unlock()}
    func moveToTrash(_ source:URL) throws -> URL {
        guard source.path.hasPrefix(root.path+"/"),trash.path.hasPrefix(root.path+"/") else {throw QuitCheckError.unsafePath}
        condition.lock();movesValue += 1;enteredValue=true
        let deadline=Date().addingTimeInterval(8)
        while !released {if !condition.wait(until:deadline),!released {timedOutValue=true;condition.unlock();throw QuitCheckError.timeout}}
        condition.unlock()
        let destination=trash.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at:source,to:destination);return destination
    }
}
