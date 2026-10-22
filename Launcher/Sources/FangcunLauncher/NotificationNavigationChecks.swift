import AppKit
import LauncherCore

/// Startup and notification navigation use the production controller with fake
/// calendar, AI and device-notification services in a disposable profile.
@MainActor enum NotificationNavigationChecks {
    static func run() async -> (count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ message:String){count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") \(message)")}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-notification-navigation-\(UUID().uuidString)")
        let owner=LauncherController(dataDirectory:directory.appendingPathComponent("Launcher"))
        let center=NotificationCenter()
        var testedRouter:WorkbenchNotificationRouter?
        defer {
            testedRouter?.stop();owner.workbenchController?.model.modals.clear();owner.workbenchController?.model.shutdown()
            owner.workbenchController?.window?.orderOut(nil);owner.workbenchController?.window?.close();owner.panel?.orderOut(nil)
            owner.workbenchController=nil;owner.hotKey.unregister();owner.bindingHotKeys.unregister();owner.toastTask?.cancel()
            try? FileManager.default.removeItem(at:directory)
        }
        do {
            owner.configurePanel();owner.scanning=true
            let aiDirectory=directory.appendingPathComponent("AI"),sourceDirectory=aiDirectory.appendingPathComponent("AIUsage")
            try FileManager.default.createDirectory(at:sourceDirectory,withIntermediateDirectories:true)
            let sources=AIProvider.allCases.map{AIUsageSourceConfiguration(provider:$0,enabled:false,sessionsPath:directory.appendingPathComponent("disabled-"+$0.rawValue).path)}
            try JSONEncoder().encode(sources).write(to:sourceDirectory.appendingPathComponent("sources.json"))
            let aiNotifications=NotificationCheckAI(),deviceNotifications=NotificationCheckDevice(),calendarNotifications=NotificationCheckReminders(),system=NotificationCheckCalendar()
            let ai=AIUsageModel(dataDirectory:aiDirectory,startServices:false,notifications:aiNotifications)
            let calendarDirectory=directory.appendingPathComponent("Calendar")
            let reminder=ReminderItem(id:"notification-reminder",title:"通知定位提醒",due:ReminderDue(date:Date().addingTimeInterval(86_400),includesTime:true),notificationsEnabled:false)
            var snapshot=ReminderSnapshot();snapshot.reminders=[reminder]
            try ReminderStore(directory:calendarDirectory).save(snapshot)
            let calendar=CalendarModel(dataDirectory:calendarDirectory,system:system,notifier:calendarNotifications)
            let device=DeviceStatusModel(dataDirectory:directory.appendingPathComponent("Device"),notifications:deviceNotifications)
            let model=WorkbenchAppModel(owner:owner,calendar:calendar,ai:ai,device:device,startServices:false)
            var creations=0
            owner.performStartupPresentation(.background,makeController:{owner in creations += 1;return WorkbenchWindowController(owner:owner,model:model,autosavesFrame:false)})
            check(creations == 1 && owner.workbenchController?.model === model && owner.workbenchController?.window?.isVisible == false && !model.windowVisible && !owner.panel.isVisible,
                  "background startup creates one service owner and leaves all interfaces hidden")
            _=owner.prepareWorkbenchServices(makeController:{_ in creations += 1;fatalError("existing controller must be reused")})
            check(creations == 1,"subsequent service preparation reuses the original hidden controller")
            check(!device.isSampling && device.snapshot.sampledAt == nil && ai.records.isEmpty && sources.allSatisfy{!$0.enabled},
                  "startup fixture never starts real sensor or account collection")

            check(owner.openNotificationTarget(.ai(.codex)) && model.route == .ai && model.ai.destination == .provider(.codex),
                  "AI notification opens its exact valid account")
            await settle()
            check(owner.openNotificationTarget(.ai(nil)) && model.ai.destination == .overview && model.toast?.contains("账户") == true,
                  "invalid AI account notification opens the module with explicit fallback state")
            check(owner.openNotificationTarget(.thermal) && model.route == .device && model.deviceDetail == .thermal,
                  "temperature notification opens the real thermal readings")
            await settle()
            check(owner.openNotificationTarget(.networkBudget) && model.route == .network,
                  "traffic budget notification opens the independent network monitor")
            await settle()
            check(model.modals.top?.width == 470 && owner.workbenchController?.window?.attachedSheet == nil,
                  "network notification opens the actual shared budget form")
            model.modals.dismissTop();await settle()
            check(!model.modals.isPresented,"unchanged notification budget form closes without a draft loss")

            check(owner.openNotificationTarget(.reminder(reminder.id)) && model.route == .calendar && model.calendar.editor?.item.id == reminder.id,
                  "reminder notification opens the existing local reminder editor")
            await settle()
            testedRouter=WorkbenchNotificationRouter(owner:owner,center:center,isApplicationActive:{true})
            center.post(name:.fangcunNotificationActivated,object:FangcunNotificationTarget.ai(.claude))
            check(model.route == .calendar && model.calendar.editor?.item.id == reminder.id,
                  "notification received during an editor preserves its current route and draft")
            model.calendar.editor=nil;await settle()
            try? await Task.sleep(for:.milliseconds(350))
            check(model.route == .ai && model.ai.destination == .provider(.claude),
                  "queued notification navigates after the existing editor safely finishes")
            check(model.calendar.localReminders.first?.isCompleted == false && model.calendar.localReminders.first?.notificationsEnabled == false,
                  "notification navigation never completes or changes the reminder")

            check(owner.openNotificationTarget(.reminder("removed-id")) && model.route == .calendar && model.calendar.editor == nil && model.toast?.contains("已删除") == true,
                  "missing reminder opens calendar with an explicit unavailable state")
            testedRouter?.stop()
            center.post(name:.fangcunNotificationActivated,object:FangcunNotificationTarget.ai(.codex))
            check(model.route == .calendar,"stopped notification routing cannot reopen another module")
            check(system.permissionRequests == 0 && system.reads == 0 && aiNotifications.deliveries == 0 && deviceNotifications.deliveries == 0,
                  "navigation fixture requests no real permissions and sends no notifications")
            check(ai.configurations.allSatisfy{!$0.enabled && $0.sessionsPath.hasPrefix(directory.path)} && device.snapshot.sampledAt == nil,
                  "rendered notification destinations retain isolated sources and disabled sampling")
        } catch {check(false,"notification navigation fixture: "+error.localizedDescription)}
        return(count,failures)
    }
    private static func settle() async {for _ in 0..<4 {try? await Task.sleep(for:.milliseconds(30))}}
}

@MainActor private final class NotificationCheckCalendar:CalendarSystemProviding {
    var permissionRequests=0,reads=0
    func access(reminders:Bool)->CalendarAccess {.notDetermined}
    func requestAccess(reminders:Bool) async throws -> Bool {permissionRequests += 1;return false}
    func events(in interval:DateInterval) throws -> [CalendarEventItem] {reads += 1;return []}
    func reminders() async throws -> [ReminderItem] {reads += 1;return []}
    func writableReminderCalendars()->[ReminderCalendar] {[]}
    func saveReminder(_ item:ReminderItem,creating:Bool) throws -> ReminderItem {throw ReminderError.unavailable("通知路由检查不写系统提醒")}
    func deleteReminder(_ item:ReminderItem) throws {throw ReminderError.unavailable("通知路由检查不删系统提醒")}
}
@MainActor private final class NotificationCheckReminders:ReminderNotificationProviding {
    func access() async -> CalendarAccess {.denied}
    func requestAccess() async throws -> Bool {false}
    func replacePending(_ notifications:[ReminderNotification]) async throws {}
}
@MainActor private final class NotificationCheckAI:AIQuotaNotificationProviding {
    var deliveries=0
    func permission() async -> AIQuotaNotificationPermission {.denied}
    func requestPermission() async throws -> Bool {false}
    func deliver(_ event:AIQuotaAlertEvent) async throws {deliveries += 1}
}
@MainActor private final class NotificationCheckDevice:DeviceNotificationProviding {
    var deliveries=0
    func permission() async -> DeviceNotificationPermission {.denied}
    func requestPermission() async throws -> Bool {false}
    func deliver(_ event:DeviceMonitoringEvent,budget:DeviceTrafficBudget,rule:DeviceTemperatureRule) async throws {deliveries += 1}
}
