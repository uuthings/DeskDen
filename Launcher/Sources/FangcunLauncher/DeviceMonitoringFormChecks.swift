import AppKit
import SwiftUI
import LauncherCore

@MainActor enum DeviceMonitoringFormChecks {
    static func run() async -> Int {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let legacyBattery = DeviceBatterySnapshot(percent: 77, isCharging: false, isPluggedIn: false, timeRemainingMinutes: nil, health: nil, maximumCapacityPercent: nil)
        check(legacyBattery.cycleCount == nil, "legacy battery initialization keeps unavailable cycle count distinct from zero")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-device-forms-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = FormCheckNotifications()
        let model = DeviceStatusModel(dataDirectory: dir, notifications: service)
        let drafts = DeviceMonitoringDrafts(); drafts.load(model)
        check(!drafts.budgetDirty && !drafts.temperatureDirty, "monitoring forms start from persisted rules without a dirty state")
        check(service.requests == 0, "loading form drafts never prompts for notification permission")
        check(DeviceBudgetDraft.number(DeviceBudgetDraft.numberText(100.123456)) == 100.123456, "form reload preserves legal numeric precision")
        check(DeviceTrafficDisplay.gigabytes(1_800_000) != DeviceTrafficDisplay.gigabytes(0), "small measured traffic is not formatted as zero GB")
        drafts.budget.enabled = true; drafts.budget.limit = "10abc"; drafts.budget.warning = "80.5"
        await drafts.saveBudget(model)
        check(drafts.budgetErrors["limit"] != nil && drafts.budgetErrors["warning"] != nil, "form validation rejects numeric suffixes and fractional warning percentages")
        check(!model.budget.enabled, "invalid budget draft does not change the active rule")
        check(DeviceBudgetDraft.number("nan")?.isFinite == false && DeviceBudgetDraft.number("1abc") == nil, "whole-string number parser never accepts a numeric prefix")
        drafts.budget.limit = "0.01"; drafts.budget.warning = "99"; drafts.budget.period = .week; drafts.budget.scope = .wifi
        drafts.budget.notifications = false
        await drafts.saveBudget(model)
        check(model.budget.enabled && model.budget.limitGB == 0.01 && model.budget.period == .week && model.budget.scope == .wifi, "minimum legal budget and selected period/scope save to the real model")
        check(!drafts.budgetDirty && drafts.budgetStatus == "设置已保存", "successful budget save establishes a new clean baseline")
        check(service.requests == 0, "saving with notifications off does not request system permission")
        drafts.budget.limit = "12.5"
        check(DeviceRuleActions.statusText(dirty: drafts.budgetDirty, saving: false, status: drafts.budgetStatus) == "有未保存的修改", "editing again after a successful save shows unsaved changes")
        drafts.load(model)
        check(drafts.budget.limit == "12.5", "repeat view/size appearance preserves unsaved form values")
        drafts.restoreBudget(model)
        check(!drafts.budgetDirty && drafts.budget.limit == "0.01", "cancel restores the current saved budget")
        drafts.budget.enabled = false; drafts.budget.limit = "invalid"
        await drafts.saveBudget(model)
        check(!model.budget.enabled && model.budget.limitGB == 0.01, "disabling a budget preserves its saved numeric parameters")
        drafts.budget.enabled = true; drafts.budget.limit = "20"; drafts.budget.period = .month
        drafts.budget.usesAnchor = true
        let calendar = drafts.budget.calendar
        drafts.budget.anchor = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!
        await drafts.saveBudget(model)
        check(model.budget.cycleAnchor == .init(year: 2026, month: 10, day: 15), "billing anchor date saves without conversion into the machine's current timezone")
        check(model.trafficSummary.periodStart == model.budget.interval(at: model.trafficSummary.measuredAt, calendar: calendar).start,
              "saved billing rules refresh the dashboard's real accounting interval immediately")
        drafts.budget.period = .custom
        drafts.budget.customStart = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!
        drafts.budget.customEnd = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))!
        await drafts.saveBudget(model)
        check(drafts.budgetErrors["dates"] != nil && model.budget.period == .month, "reversed custom dates remain a draft and never replace the active billing rule")
        drafts.budget.customEnd = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14))!
        await drafts.saveBudget(model)
        check(model.budget.period == .custom && model.budget.customEndInclusive == .init(year: 2026, month: 11, day: 14),
              "custom ending day is stored inclusively and reloaded by the form")
        check(model.trafficSummary.periodEnd == calendar.date(from: DateComponents(year: 2026, month: 11, day: 15))!,
              "custom saved summary counts through the end of the selected ending day")
        drafts.budget.customEnd = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        drafts.restoreBudget(model)
        check(DeviceBudgetDate(drafts.budget.customEnd, calendar: calendar) == .init(year: 2026, month: 11, day: 14), "cancel restores the saved inclusive ending date")
        drafts.temperature.enabled = true; drafts.temperature.cpu = "NaN"; drafts.temperature.duration = "3.5"
        await drafts.saveTemperature(model)
        check(drafts.temperatureErrors["cpu"] != nil && drafts.temperatureErrors["duration"] != nil && !model.temperatureRule.enabled, "invalid temperature values never become active monitoring rules")
        drafts.temperature.cpu = "40"; drafts.temperature.gpu = "110"; drafts.temperature.duration = "3600"; drafts.temperature.cooldown = "1440"
        drafts.temperature.notifications = false
        await drafts.saveTemperature(model)
        check(model.temperatureRule.enabled && model.temperatureRule.sustainedSeconds == 3600 && model.temperatureRule.cooldownMinutes == 1440, "temperature editor accepts the same legal limits as the core rule")
        drafts.temperature.gpu = "90"; drafts.restoreTemperature(model)
        check(!drafts.temperatureDirty && drafts.temperature.gpu == "110", "temperature cancel restores the saved rule")
        let restored = DeviceStatusModel(dataDirectory: dir, notifications: service)
        check(restored.budget == model.budget && restored.temperatureRule == model.temperatureRule, "rules saved by forms survive model recreation")
        drafts.temperature.notifications = true
        await drafts.saveTemperature(model)
        check(service.requests == 1 && model.notificationPermission == .denied && !drafts.temperatureDirty, "explicit notification enabling saves rules even when authorization is denied")
        service.state = .authorized
        await model.refreshNotificationPermission()
        check(model.notificationPermission == .authorized, "permission status recovers after a system-settings change")
        #if DEBUG
        if CommandLine.arguments.contains("--form-check") {
            let current = drafts.budget
            for period: DeviceBudgetPeriod in [.week, .month, .custom] {
                drafts.budget.period = period
                let view = NSHostingView(rootView: DeviceBudgetSettingsView(model: model, drafts: drafts).preferredColorScheme(.dark))
                view.frame = NSRect(x: 0, y: 0, width: 365, height: 900)
                view.layoutSubtreeIfNeeded()
                print("Budget sizing diagnostic: \(period.rawValue) = \(view.fittingSize.width) pt")
                let budgetView = DeviceBudgetSettingsView(model: model, drafts: drafts)
                for (name, part) in budgetView.sizingPartsForChecks {
                    let partView = NSHostingView(rootView: part)
                    partView.frame = NSRect(x: 0, y: 0, width: 337, height: 900)
                    partView.layoutSubtreeIfNeeded()
                    print("  \(name): \(partView.fittingSize.width) pt")
                }
            }
            drafts.budget = current
        }
        #endif
        for width: CGFloat in [365, 438, 554] {
            let view = NSHostingView(rootView: DeviceBudgetSettingsView(model: model, drafts: drafts).preferredColorScheme(.dark))
            view.frame = NSRect(x: 0, y: 0, width: width, height: 650)
            view.layoutSubtreeIfNeeded()
            let fittingWidth = view.fittingSize.width
            if fittingWidth > width + 1 { print("Budget form measured \(fittingWidth) pt for available \(width) pt") }
            check(fittingWidth <= width + 1, "budget form remains horizontally contained at \(Int(width)) pt")
        }
        let savedDraft = drafts.budget
        for period: DeviceBudgetPeriod in [.week, .month, .quarter, .year] {
            drafts.budget.period = period
            let view = NSHostingView(rootView: DeviceBudgetSettingsView(model: model, drafts: drafts).preferredColorScheme(.dark))
            view.frame = NSRect(x: 0, y: 0, width: 365, height: 900); view.layoutSubtreeIfNeeded()
            check(view.fittingSize.width <= 366, "\(period.rawValue) budget form and cycle help remain contained at 365 pt")
        }
        drafts.budget = savedDraft
        for year in [2020, 2030] {
            drafts.budget.customStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
            drafts.budget.customEnd = calendar.date(from: DateComponents(year: year, month: 1, day: 31))!
            let view = NSHostingView(rootView: DeviceBudgetSettingsView(model: model, drafts: drafts).preferredColorScheme(.dark))
            view.frame = NSRect(x: 0, y: 0, width: 365, height: 900); view.layoutSubtreeIfNeeded()
            check(view.fittingSize.width <= 366, "custom \(year) budget status explanation remains contained at 365 pt")
        }
        drafts.budget = savedDraft
        print("Device monitoring form checks: \(count - failures)/\(count) passed")
        return failures
    }
}

@MainActor private final class FormCheckNotifications: DeviceNotificationProviding {
    var state: DeviceNotificationPermission = .notDetermined
    var requests = 0
    func permission() async -> DeviceNotificationPermission { state }
    func requestPermission() async throws -> Bool { requests += 1; state = .denied; return false }
    func deliver(_ event: DeviceMonitoringEvent, budget: DeviceTrafficBudget, rule: DeviceTemperatureRule) async throws { }
}
