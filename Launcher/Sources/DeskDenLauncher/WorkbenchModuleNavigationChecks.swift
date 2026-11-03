import AppKit
import SwiftUI
import LauncherCore

/// Exercises module entry separately from deep links without mounting a window
/// or starting the account, sensor, calendar or notification services.
@MainActor enum WorkbenchModuleNavigationChecks {
    static func run() -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-module-navigation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let owner = LauncherController(dataDirectory: directory.appendingPathComponent("Launcher"))
            let calendar = CalendarModel(dataDirectory: directory.appendingPathComponent("Calendar"),
                system: ModuleNavigationCalendar(), notifier: ModuleNavigationNotifications())
            let ai = AIUsageModel(dataDirectory: directory.appendingPathComponent("AI"), startServices: false,
                claudeSettingsDirectory: directory.appendingPathComponent("DisabledClaude"))
            let cleaning = SpaceCleaningModel(dataDirectory: directory.appendingPathComponent("Cleaning"), homeDirectory: directory)
            let model = WorkbenchAppModel(owner: owner, calendar: calendar, ai: ai, cleaning: cleaning, startServices: false)
            defer { model.shutdown() }

            model.openDeviceReading(.processes)
            model.selectModule(.cleaning)
            check(model.selectModule(.device) && model.deviceDetail == nil,
                  "device → processes → cleaning → device returns to the device overview")
            model.openDeviceReading(.thermal, fromMini: true)
            check(model.route == .device && model.deviceDetail == .thermal && model.requestedReadingReturnTitle == "返回设备状态",
                  "Mini hardware deep links retain their detail and logical parent")
            check(model.selectModule(.device) && model.deviceDetail == nil,
                  "selecting the current device module also closes its detail")

            cleaning.screen = .results; cleaning.detailID = UUID()
            cleaning.searchText = "fixture"; cleaning.resultTab = .reviewable
            model.navigate(.cleaning); model.selectModule(.network)
            check(model.selectModule(.cleaning) && cleaning.screen == .start && cleaning.detailID == nil,
                  "cleaning results return to the cleaning start page through primary navigation")
            check(cleaning.searchText == "fixture" && cleaning.resultTab == .reviewable,
                  "returning to the cleaning root preserves its search and result filter")
            cleaning.screen = .history
            check(model.selectModule(.cleaning) && cleaning.screen == .start,
                  "selecting cleaning again leaves its history page")

            calendar.showSources = true; calendar.sourcesReturnToPrivacy = true
            calendar.showReminderList = true; calendar.search = "preserve"
            let selectedDay = calendar.selectedDay
            model.navigate(.calendar); model.selectModule(.network)
            check(model.selectModule(.calendar) && !calendar.showSources && !calendar.showReminderList && !calendar.sourcesReturnToPrivacy,
                  "calendar entry closes sources and reminder-list subpages")
            check(calendar.selectedDay == selectedDay && calendar.search == "preserve",
                  "calendar root entry preserves the chosen date and search")

            for destination in [AIUsageDestination.provider(.codex), .sources, .history, .prices] {
                model.navigate(.ai); ai.show(destination)
                model.usagePresentation.selectedSourceID = UUID(); model.usagePresentation.selectedAPIID = UUID()
                model.selectModule(.network)
                check(model.selectModule(.ai) && ai.destination == .overview
                      && model.usagePresentation.selectedSourceID == nil && model.usagePresentation.selectedAPIID == nil,
                      "usage root entry clears \(destination) and service details")
            }
            model.navigate(.settings); model.settingsTab = .privacy
            model.vault.showProtection(fromSettings: true); model.navigate(.vault)
            model.selectModule(.network)
            check(model.selectModule(.vault) && !model.vault.showingProtection && !model.vault.protectionFromSettings,
                  "private-space entry closes protection details without unlocking the vault")
            model.navigate(.settings); model.settingsTab = .launcher; model.launcherSection = 2
            check(model.selectModule(.settings) && model.settingsTab == .general && model.launcherSection == 0,
                  "settings button consistently opens general settings")

            model.navigate(.device); model.deviceDetail = .processes
            let modalID = UUID()
            model.modals.present(id: modalID, parentID: nil, width: 400, content: AnyView(Text("Fixture")),
                requestDismiss: {}, isStillPresented: { true }, invalidate: {})
            check(!model.selectModule(.device) && model.deviceDetail == .processes
                  && !model.selectModule(.cleaning) && model.route == .device,
                  "an active dialog blocks both current-module reset and cross-module navigation")
            model.modals.remove(modalID)

            model.navigate(.ai); ai.show(.prices); ai.priceDraft.input = "12345"
            check(!model.selectModule(.network) && model.route == .ai && ai.hasUnsavedPriceChanges && model.message != nil,
                  "unsaved inline prices cannot be hidden by primary navigation")
            model.message = nil; ai.discardPriceChanges(); model.selectModule(.cleaning)
            cleaning.editScope(custom: true)
            check(!model.selectModule(.network) && model.route == .cleaning && cleaning.screen == .scope && model.message != nil,
                  "an unapplied scan-scope draft remains visible and protected")
            model.message = nil; cleaning.cancelScope()

            model.navigate(.calendar)
            calendar.editor = CalendarReminderDraft(item: ReminderItem(title: "Fixture", notificationsEnabled: false),
                creating: true, defaultDate: Date(), calendar: Calendar.current)
            check(!model.selectModule(.device) && model.route == .calendar && calendar.editor != nil,
                  "a new reminder editor blocks navigation before its modal is mounted")
            calendar.editor = nil
            model.navigate(.ai); model.usagePresentation.showingConfiguration = true
            check(!model.selectModule(.network) && model.route == .ai,
                  "usage configuration blocks navigation before its modal is mounted")
            model.usagePresentation.showingConfiguration = false
            model.navigate(.vault); model.vault.sheet = .backup
            check(!model.selectModule(.device) && model.route == .vault && model.vault.sheet != nil,
                  "private-space editors are not dismissed by primary navigation")
            model.vault.sheet = nil
            model.selectModule(.overview)
            check(!model.windowVisible && !model.device.isSampling,
                  "navigation checks never open a window or start device sampling")
        } catch { check(false, "module navigation fixture setup: \(error.localizedDescription)") }
        return (count, failures)
    }
}

@MainActor private final class ModuleNavigationCalendar: CalendarSystemProviding {
    func access(reminders: Bool) -> CalendarAccess { .notDetermined }
    func requestAccess(reminders: Bool) async throws -> Bool { false }
    func events(in interval: DateInterval) throws -> [CalendarEventItem] { [] }
    func reminders() async throws -> [ReminderItem] { [] }
    func writableReminderCalendars() -> [ReminderCalendar] { [] }
    func saveReminder(_ item: ReminderItem, creating: Bool) throws -> ReminderItem { throw ReminderError.unavailable("Isolated fixture") }
    func deleteReminder(_ item: ReminderItem) throws { throw ReminderError.unavailable("Isolated fixture") }
}

@MainActor private final class ModuleNavigationNotifications: ReminderNotificationProviding {
    func access() async -> CalendarAccess { .notDetermined }
    func requestAccess() async throws -> Bool { false }
    func replacePending(_ notifications: [ReminderNotification]) async throws { }
}
