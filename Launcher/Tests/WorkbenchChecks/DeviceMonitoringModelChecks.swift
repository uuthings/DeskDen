import Foundation
import LauncherCore

@main struct DeviceMonitoringModelChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-monitoring-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures = 0, checks = 0
        func check(_ value: Bool, _ title: String) { checks += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") \(title)") }
        let notifier = MonitoringCheckNotifications(), model = DeviceStatusModel(dataDirectory: directory, notifications: notifier)
        let now = Date(), c = DeviceTrafficLedger().calendar
        var ledger = DeviceTrafficLedger(now: now, timeZone: c.timeZone), day = DeviceNetworkDay()
        day.received = 9_000_000; day.coveredSeconds = 2; day.firstSample = now; day.lastSample = now
        ledger.scopes[.all]?.days[DeviceNetworkLedger.dayKey(now, calendar: c)] = day
        var snapshot = DeviceSnapshot(); snapshot.sampledAt = now
        await model.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now)
        check(notifier.permissionRequests == 0 && notifier.delivered.isEmpty, "startup does not request permission or emit notifications")
        var budget = DeviceTrafficBudget(); budget.enabled = true; budget.notificationsEnabled = true; budget.limitGB = 0.01
        notifier.access = .denied
        check(await model.saveBudget(budget), "denied notification permission does not prevent saving a budget")
        await model.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(2))
        check(notifier.attempts == 0 && model.notificationPermission == .denied, "denied permission never marks an alert delivered")
        notifier.access = .authorized; await model.refreshNotificationPermission()
        check(model.monitoringError == nil, "restored notification permission clears only its prior permission warning")
        notifier.failNext = true
        await model.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(4))
        check(notifier.attempts == 1 && notifier.delivered.isEmpty, "failed budget delivery stays unacknowledged")
        await model.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(6))
        await model.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(8))
        check(notifier.attempts == 2 && notifier.delivered == [.budgetWarning(percent: 80)], "failed budget notification retries once then deduplicates")
        let restored = DeviceStatusModel(dataDirectory: directory, notifications: notifier)
        await restored.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(10))
        check(notifier.attempts == 2 && restored.budget == budget, "saved rule and alert acknowledgement survive restart")
        var invalid = budget; invalid.warningPercent = 100
        check(!(await model.saveBudget(invalid)) && model.budget == budget, "validation failure preserves the saved rule")
        var thermal = DeviceTemperatureRule(); thermal.enabled = true; thermal.notificationsEnabled = true; thermal.sustainedSeconds = 5
        check(await model.saveTemperatureRule(thermal), "temperature rule saves without changing budget")
        snapshot.cpuTemperature = 90; snapshot.gpuTemperature = 90
        for i in [12, 14, 16, 18] { await model.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(Double(i))) }
        check(notifier.delivered.filter { if case .temperature = $0 { true } else { false } }.count == 2, "CPU and GPU alert independently after continuous duration")
        for i in [20, 22, 24] { await model.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(Double(i))) }
        check(notifier.delivered.count == 3, "sustained heat does not repeat without recovery")
        var changedCycle = budget; changedCycle.warningPercent = 82
        _ = await model.saveBudget(changedCycle); notifier.failNext = true
        let beforeRetry = notifier.delivered.count
        await model.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(25))
        await model.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(26))
        check(notifier.delivered.count == beforeRetry + 1 && notifier.delivered.last == .budgetWarning(percent: 82), "failed notification for changed budget does not inherit a prior cycle acknowledgement")
        // Suspend notification delivery and edit configuration while the model is reentrant.
        var racing = budget; racing.warningPercent = 85
        check(await model.saveBudget(racing), "new threshold prepares a new evaluation")
        notifier.onDeliver = { [weak model] in
            guard let model else { return }
            var disabled = model.budget; disabled.enabled = false
            _ = await model.saveBudget(disabled)
        }
        await model.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(28))
        let afterRace = DeviceStatusModel(dataDirectory: directory, notifications: notifier)
        check(!model.budget.enabled && !afterRace.budget.enabled, "an awaited old alert cannot overwrite newer saved settings")
        let thermalNotifier = MonitoringCheckNotifications()
        // Use a separate injected notifier to test a partial CPU/GPU delivery failure.
        let partial = DeviceStatusModel(dataDirectory: directory.appendingPathComponent("partial-delivery"), notifications: thermalNotifier)
        _ = await partial.saveTemperatureRule(thermal)
        thermalNotifier.failSensor = "CPU"
        for i in [0, 2, 4, 6] { await partial.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(Double(i))) }
        check(thermalNotifier.delivered == [.temperature(sensor: "GPU", value: 90)], "CPU delivery failure does not discard the successfully delivered GPU acknowledgement")
        for i in [8, 10, 12, 14] { await partial.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(Double(i))) }
        check(thermalNotifier.delivered == [.temperature(sensor: "GPU", value: 90), .temperature(sensor: "CPU", value: 90)], "failed CPU retries after a new sustained interval without duplicating GPU")
        let crossBudgetNotifier = MonitoringCheckNotifications()
        let crossBudgetDir = directory.appendingPathComponent("budget-delivery-temperature-save")
        let crossBudget = DeviceStatusModel(dataDirectory: crossBudgetDir, notifications: crossBudgetNotifier)
        _ = await crossBudget.saveBudget(budget)
        crossBudgetNotifier.onDeliver = { [weak crossBudget] in
            guard let crossBudget else { return }
            var differentRule = crossBudget.temperatureRule; differentRule.cpuThreshold = 95
            _ = await crossBudget.saveTemperatureRule(differentRule)
        }
        await crossBudget.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now)
        await crossBudget.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(2))
        let crossBudgetRestored = DeviceStatusModel(dataDirectory: crossBudgetDir, notifications: crossBudgetNotifier)
        await crossBudgetRestored.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now.addingTimeInterval(4))
        check(crossBudgetNotifier.delivered == [.budgetWarning(percent: 80)] && crossBudgetRestored.temperatureRule.cpuThreshold == 95,
              "temperature edit during budget delivery preserves the budget acknowledgement across restart")
        let crossThermalNotifier = MonitoringCheckNotifications()
        let crossThermalDir = directory.appendingPathComponent("temperature-delivery-budget-save")
        let crossThermal = DeviceStatusModel(dataDirectory: crossThermalDir, notifications: crossThermalNotifier)
        _ = await crossThermal.saveTemperatureRule(thermal)
        crossThermalNotifier.onDeliver = { [weak crossThermal] in
            guard let crossThermal else { return }
            var differentBudget = crossThermal.budget; differentBudget.limitGB = 200
            _ = await crossThermal.saveBudget(differentBudget)
        }
        var cpuOnly = snapshot; cpuOnly.gpuTemperature = nil
        for i in [0, 2, 4, 6, 8, 10, 12, 14] { await crossThermal.evaluateMonitoringForChecks(snapshot: cpuOnly, ledger: ledger, at: now.addingTimeInterval(Double(i))) }
        let crossThermalRestored = DeviceStatusModel(dataDirectory: crossThermalDir, notifications: crossThermalNotifier)
        for i in [16, 18, 20, 22] { await crossThermalRestored.evaluateMonitoringForChecks(snapshot: cpuOnly, ledger: ledger, at: now.addingTimeInterval(Double(i))) }
        check(crossThermalNotifier.delivered == [.temperature(sensor: "CPU", value: 90)] && crossThermalRestored.budget.limitGB == 200,
              "budget edit during temperature delivery preserves the sensor acknowledgement across restart")
        let permissionDir = directory.appendingPathComponent("permission")
        let freshNotifier = MonitoringCheckNotifications(); freshNotifier.access = .notDetermined
        let fresh = DeviceStatusModel(dataDirectory: permissionDir, notifications: freshNotifier)
        await fresh.refreshNotificationPermission(); check(freshNotifier.permissionRequests == 0, "reading permission status is nonprompting")
        check(await fresh.saveBudget(DeviceTrafficBudget()), "disabled default budget persists")
        check(freshNotifier.permissionRequests == 0, "saving a disabled rule does not request permission")
        check(await fresh.saveBudget(budget), "explicit notification enable saves")
        check(freshNotifier.permissionRequests == 1 && fresh.notificationPermission == .authorized, "explicit enable requests permission exactly once")
        let corruptDir = directory.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptURL = corruptDir.appendingPathComponent("monitoring-rules.json"), corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: corruptURL)
        let protected = DeviceStatusModel(dataDirectory: corruptDir, notifications: notifier)
        let protectedSave = await protected.saveBudget(budget), retainedData = try Data(contentsOf: corruptURL)
        check(!protectedSave && retainedData == corrupt, "unreadable configuration is preserved and never silently replaced")
        let asymmetricDir = directory.appendingPathComponent("invalid-temperature")
        try FileManager.default.createDirectory(at: asymmetricDir, withIntermediateDirectories: true)
        let asymmetricURL = asymmetricDir.appendingPathComponent("monitoring-rules.json")
        let validSaved = try Data(contentsOf: permissionDir.appendingPathComponent("monitoring-rules.json"))
        var asymmetric = try JSONSerialization.jsonObject(with: validSaved) as! [String: Any]
        var invalidTemperature = asymmetric["temperatureRule"] as! [String: Any]
        invalidTemperature["enabled"] = true; invalidTemperature["sustainedSeconds"] = 0
        asymmetric["temperatureRule"] = invalidTemperature
        let asymmetricBytes = try JSONSerialization.data(withJSONObject: asymmetric, options: [.sortedKeys])
        try asymmetricBytes.write(to: asymmetricURL)
        let asymmetricNotifier = MonitoringCheckNotifications()
        let asymmetricModel = DeviceStatusModel(dataDirectory: asymmetricDir, notifications: asymmetricNotifier)
        check(!asymmetricModel.budget.enabled && !asymmetricModel.temperatureRule.enabled,
              "one invalid rule prevents activation of every rule in the same document")
        await asymmetricModel.evaluateMonitoringForChecks(snapshot: snapshot, ledger: ledger, at: now)
        check(asymmetricNotifier.attempts == 0 && asymmetricNotifier.permissionRequests == 0,
              "partially valid enabled budget never requests permission or sends alerts")
        let asymmetricSave = await asymmetricModel.saveBudget(budget)
        let retainedAsymmetric = try Data(contentsOf: asymmetricURL)
        check(!asymmetricSave && retainedAsymmetric == asymmetricBytes,
              "asymmetrically invalid rules retain their original bytes and remain protected")
        let invalidLedgerDir = directory.appendingPathComponent("invalid-ledger")
        try FileManager.default.createDirectory(at: invalidLedgerDir, withIntermediateDirectories: true)
        let invalidLedgerURL = invalidLedgerDir.appendingPathComponent("device-traffic.json")
        var invalidLedger = ledger, invalidDay = day
        invalidDay.excludedIntervals = Int.max
        invalidLedger.scopes[.all]?.days[DeviceNetworkLedger.dayKey(now, calendar: c)] = invalidDay
        let invalidLedgerBytes = try JSONEncoder().encode(invalidLedger)
        try invalidLedgerBytes.write(to: invalidLedgerURL)
        let invalidLedgerModel = DeviceStatusModel(dataDirectory: invalidLedgerDir, notifications: notifier)
        let invalidLedgerError = await invalidLedgerModel.inspectTrafficStorageForChecks()
        let retainedLedgerBytes = try Data(contentsOf: invalidLedgerURL)
        check(invalidLedgerError != nil && retainedLedgerBytes == invalidLedgerBytes,
              "valid JSON containing an overflowing ledger count is protected without overwriting or crashing")
        let legacyLedgerDir = directory.appendingPathComponent("invalid-legacy-ledger")
        try FileManager.default.createDirectory(at: legacyLedgerDir, withIntermediateDirectories: true)
        let legacyLedgerURL = legacyLedgerDir.appendingPathComponent("device-network.json")
        let invalidLegacyBytes = try JSONEncoder().encode(invalidLedger.scopes[.all]!)
        try invalidLegacyBytes.write(to: legacyLedgerURL)
        let legacyModel = DeviceStatusModel(dataDirectory: legacyLedgerDir, notifications: notifier)
        let legacyError = await legacyModel.inspectTrafficStorageForChecks()
        let retainedLegacyBytes = try Data(contentsOf: legacyLedgerURL)
        check(legacyError != nil && retainedLegacyBytes == invalidLegacyBytes,
              "legacy session ledger uses the same protected invalid-field handling")
        print("Device monitoring model checks: \(checks - failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
@MainActor final class MonitoringCheckNotifications: DeviceNotificationProviding {
    var access: DeviceNotificationPermission = .authorized
    var permissionRequests = 0, attempts = 0
    var delivered: [DeviceMonitoringEvent] = []
    var failNext = false
    var failSensor: String?
    var onDeliver: (() async -> Void)?
    func permission() async -> DeviceNotificationPermission { access }
    func requestPermission() async throws -> Bool { permissionRequests += 1; access = .authorized; return true }
    func deliver(_ event: DeviceMonitoringEvent, budget: DeviceTrafficBudget, rule: DeviceTemperatureRule) async throws {
        attempts += 1
        if failNext { failNext = false; throw NSError(domain: "FixtureDelivery", code: 1) }
        if case .temperature(let sensor, _) = event, sensor == failSensor { failSensor = nil; throw NSError(domain: "FixtureDelivery", code: 2) }
        if let action = onDeliver { onDeliver = nil; await action() }
        delivered.append(event)
    }
}
