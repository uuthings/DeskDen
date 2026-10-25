import Foundation
import AppKit
import Combine
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import LauncherCore
import SystemConfiguration

struct DeviceMemorySnapshot: Sendable {
    var total: UInt64, used: UInt64, available: UInt64, application: UInt64, wired: UInt64
    var compressed: UInt64, cached: UInt64, swapUsed: UInt64?, pageIns: UInt64, pageOuts: UInt64
    var pressure: DevicePressure
    var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
}

struct DeviceDiskSnapshot: Sendable {
    var name: String, fileSystem: String
    var total: UInt64, used: UInt64, available: UInt64
    var readBytesPerSecond: Double?, writeBytesPerSecond: Double?
    var recordedRead: UInt64 = 0, recordedWrite: UInt64 = 0
    var immediatelyFree: UInt64? = nil, reclaimableEstimate: UInt64? = nil
    var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
}

struct DeviceBatterySnapshot: Sendable {
    var percent: Double
    var isCharging: Bool, isPluggedIn: Bool
    var timeRemainingMinutes: Int?
    var health: String?
    var maximumCapacityPercent: Double?
    var cycleCount: Int? = nil
}

struct DeviceNetworkInterface: Identifiable, Sendable {
    var id: String
    var name: String
    var isVirtual: Bool
    var isActive: Bool
    var isDefault: Bool
}

struct DeviceNetworkSnapshot: Sendable {
    var downloadBytesPerSecond: Double?, uploadBytesPerSecond: Double?
    var sessionDownload: UInt64 = 0, sessionUpload: UInt64 = 0
    var todayDownload: UInt64 = 0, todayUpload: UInt64 = 0
    var todayCoverageSeconds: TimeInterval = 0
    var sessionCoverageSeconds: TimeInterval = 0
    var recordedSince: Date?
    var todayFirstSample: Date?, todayLastSample: Date?
    var excludedIntervals: Int = 0
    var interfaceNames: [String] = []
}

struct DeviceSnapshot: Sendable {
    var sampledAt: Date?
    var performanceSampledAt: Date?
    var deviceName = "Mac"
    var modelIdentifier = "—"
    var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    var performanceCores: Int?
    var efficiencyCores: Int?
    var chipName = "正在读取"
    var logicalCPUCount = 0
    var physicalCPUCount = 0
    var uptime: TimeInterval = 0
    var cpuPercent: Double?, cpuUserPercent: Double?, cpuSystemPercent: Double?
    var gpuPercent: Double? = nil
    var cpuTemperature: Double? = nil
    var gpuTemperature: Double? = nil
    var fanRPM: [Double?]? = nil
    var sensorSource = "正在读取传感器"
    var cpuSensorKeys: [String] = []
    var gpuSensorKeys: [String] = []
    var memory: DeviceMemorySnapshot?
    var disk: DeviceDiskSnapshot?
    var network = DeviceNetworkSnapshot()
    var battery: DeviceBatterySnapshot?
    var thermalState: DeviceThermalState = .unknown
    var processes: [DeviceProcess] = []
    var processReadCount = 0
    var processTotalCount = 0
    var unavailableReasons: [String: String] = [
        "gpu": "macOS 未提供适用于此设备的公开 GPU 使用率接口。",
        "temperature": "当前硬件未返回有效温度读数。",
        "fan": "当前硬件未返回有效风扇读数；仍由系统自动控制。"
    ]
}

struct DeviceHistoryPoint: Identifiable, Sendable {
    var id: Date { date }
    var date: Date
    var segment: UUID
    var cpuPercent: Double?
    var downloadBytesPerSecond: Double?, uploadBytesPerSecond: Double?
    var cpuTemperature: Double? = nil
    var gpuTemperature: Double? = nil
    var memoryPercent: Double? = nil
}

/// One shared model serves the overview, device page and desktop widgets.
/// Hidden workbench windows retain low-frequency network accounting, without process scans or charts.
@MainActor
final class DeviceStatusModel: ObservableObject {
    @Published private(set) var snapshot = DeviceSnapshot()
    @Published private(set) var history: [DeviceHistoryPoint] = []
    @Published private(set) var interfaces: [DeviceNetworkInterface] = []
    @Published private(set) var selectedInterfaceIDs: [String]?
    @Published private(set) var isSampling = false
    @Published private(set) var isWindowVisible = true
    @Published private(set) var samplingInterval: TimeInterval = 2
    @Published private(set) var lastError: String?
    @Published private(set) var budget = DeviceTrafficBudget()
    @Published private(set) var temperatureRule = DeviceTemperatureRule()
    @Published private(set) var trafficSummary = DeviceTrafficLedger().summary(period: .month, scope: .all, at: Date())
    @Published private(set) var notificationPermission: DeviceNotificationPermission = .unknown
    @Published private(set) var monitoringError: String?
    private var trafficLedger = DeviceTrafficLedger()
    private var evaluator = DeviceMonitoringEvaluator()
    private let notifications: any DeviceNotificationProviding
    private let monitoringURL: URL
    private var monitoringProtected = false
    private var monitoringRevision = UUID()
    private var lastPermissionCheck = Date.distantPast
    @Published private(set) var dashboardLayout = DeviceDashboardLayout()
    @Published private(set) var layoutError: String?
    @Published private(set) var undoLayout: DeviceDashboardLayout?
    var dashboardScrollOffset: CGFloat = 0
    let layoutStore: DeviceLayoutStore
    private let sampler: DeviceSampler
    private var loop: Task<Void, Never>?
    private var samplingTask: Task<Void, Never>?
    private var generation = UUID()
    private var visibleWidgetConsumers = false
    private var visibleQuickSummary = false
    private var workspaceEvents = Set<AnyCancellable>()
    private var systemSleeping = false
    private var historySegment = UUID()
    private var lastHistoryDate: Date?
    private var resumeSamplingAfterCancelledQuit = false
    private var preparingForQuit = false

    init(dataDirectory: URL, notifications: (any DeviceNotificationProviding)? = nil) {
        self.notifications = notifications ?? DeviceAlertService()
        monitoringURL = dataDirectory.appendingPathComponent("monitoring-rules.json")
        sampler = DeviceSampler(dataDirectory: dataDirectory)
        layoutStore = DeviceLayoutStore(url: dataDirectory.appendingPathComponent("dashboard-layout.json"))
        do { dashboardLayout = try layoutStore.load() } catch { layoutError = error.localizedDescription }
        if FileManager.default.fileExists(atPath: monitoringURL.path) {
            do {
                let data = try JSONDecoder().decode(DeviceMonitoringConfiguration.self, from: Data(contentsOf: monitoringURL))
                // Validate the entire document before activating any rule. A partially valid
                // file must not leave an enabled budget behind when another rule is invalid.
                let validBudget = try data.budget.validated()
                let validTemperatureRule = try data.temperatureRule.validated()
                budget = validBudget; temperatureRule = validTemperatureRule
                evaluator = .init(state: data.state)
            } catch { monitoringProtected = true; monitoringError = "监测规则无法读取，已保留原文件且未启用规则：\(error.localizedDescription)" }
        }
        trafficSummary = trafficLedger.summary(budget: budget, at: Date())
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in self?.systemWillSleep() }
        }.store(in: &workspaceEvents)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        }.store(in: &workspaceEvents)
    }
    private func systemWillSleep() {
        let pendingLoop = loop, pendingSample = samplingTask
        systemSleeping = true; generation = UUID(); evaluator.breakContinuity()
        historySegment = UUID(); lastHistoryDate = nil; loop?.cancel(); loop = nil; samplingTask?.cancel(); samplingTask = nil
        Task { [weak self] in
            guard let self else { return }
            await pendingLoop?.value; await pendingSample?.value
            do { try await sampler.flush() } catch { lastError = "休眠前流量记录保存失败：\(error.localizedDescription)" }
        }
    }
    private func systemDidWake() {
        systemSleeping = false; generation = UUID(); evaluator.breakContinuity()
        if isSampling { scheduleLoop() }
    }
    func saveLayout(_ next: DeviceDashboardLayout) {
        guard next != dashboardLayout else { return }
        do { try layoutStore.save(next); undoLayout = dashboardLayout; dashboardLayout = next; layoutError = nil }
        catch { layoutError = "布局未能保存：\(error.localizedDescription)" }
    }
    func undoLayoutChange() {
        guard let previous = undoLayout else { return }
        do { try layoutStore.save(previous); dashboardLayout = previous; undoLayout = nil; layoutError = nil }
        catch { layoutError = "撤销未能保存：\(error.localizedDescription)" }
    }
    func changeCard(_ id: DeviceCardID, _ change: (inout DeviceCardPreference) -> Void) {
        var next = dashboardLayout; next.update(id, change); saveLayout(next)
    }
    deinit { loop?.cancel(); samplingTask?.cancel() }

    func start(interval: TimeInterval = 2) {
        guard !preparingForQuit else { return }
        samplingInterval = min(60, max(1, interval.isFinite ? interval : 2))
        guard !isSampling else { return }
        isSampling = true
        generation = UUID()
        scheduleLoop()
    }

    private func scheduleLoop() {
        loop?.cancel()
        guard !systemSleeping, !preparingForQuit else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.sampleAndNextInterval() else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    private func sampleAndNextInterval() async -> TimeInterval {
        await takeSample()
        return effectiveInterval
    }

    func stop() {
        isSampling = false; generation = UUID()
        loop?.cancel(); loop = nil; samplingTask?.cancel(); samplingTask = nil
        historySegment = UUID(); lastHistoryDate = nil; evaluator.breakContinuity()
        Task { [sampler] in try? await sampler.flush() }
    }

    /// Awaited by the common native/menu/update termination barrier, before OS termination.
    func prepareForQuit() async throws {
        resumeSamplingAfterCancelledQuit = isSampling; preparingForQuit = true
        let pendingLoop = loop, pendingSample = samplingTask
        stop()
        await pendingLoop?.value; await pendingSample?.value
        try await sampler.flush()
    }
    func resumeAfterCancelledQuit() {
        preparingForQuit = false
        if resumeSamplingAfterCancelledQuit { start(interval: samplingInterval) }
        resumeSamplingAfterCancelledQuit = false
    }

    func setWindowVisible(_ visible: Bool) {
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible
        historySegment = UUID(); lastHistoryDate = nil
        if isSampling { scheduleLoop() } else if visible { refresh() }
    }

    /// Widgets can keep current readings available while the workbench is hidden.
    /// Performance history is still appended only while the workbench itself is visible.
    func setWidgetsVisible(_ visible: Bool) {
        guard visible != visibleWidgetConsumers else { return }
        visibleWidgetConsumers = visible
        if isSampling { scheduleLoop() } else if visible { refresh() }
    }

    /// A transient top summary is an independent consumer; it never changes widget preferences.
    func setQuickSummaryVisible(_ visible: Bool) {
        guard visible != visibleQuickSummary else { return }
        visibleQuickSummary = visible
        if isSampling { scheduleLoop() } else if visible { refresh() }
    }

    func refresh() {
        guard samplingTask == nil, !preparingForQuit else { return }
        samplingTask = Task { [weak self] in
            guard let self else { return }
            await self.takeSample(); self.samplingTask = nil
        }
    }

    func setSelectedInterfaces(_ identifiers: [String]?) {
        selectedInterfaceIDs = identifiers.map { Array(Set($0)).sorted() }
        Task { [weak self] in
            guard let self else { return }
            await self.sampler.selectInterfaces(self.selectedInterfaceIDs)
            self.historySegment = UUID(); self.refresh()
        }
    }

    func beginNewNetworkRecording() {
        Task { [weak self] in
            guard let self else { return }
            await self.sampler.beginRecording(); self.refresh()
        }
    }

    func filteredProcesses(query: String, sort: DeviceProcessSort) -> [DeviceProcess] {
        DeviceProcess.filtered(snapshot.processes, query: query, sort: sort)
    }

    private var wantsPerformance: Bool { isWindowVisible || visibleWidgetConsumers || visibleQuickSummary }
    private var effectiveInterval: TimeInterval { wantsPerformance ? min(samplingInterval, temperatureRule.enabled ? 5 : 60) : temperatureRule.enabled ? min(5, samplingInterval) : max(10, samplingInterval) }
    var budgetProgressPercent: Double? { budget.enabled && budget.limitBytes > 0 ? Double(trafficSummary.totalBytes) / Double(budget.limitBytes) * 100 : nil }
    var budgetRemainingBytes: UInt64? { budget.enabled ? (budget.limitBytes > trafficSummary.totalBytes ? budget.limitBytes - trafficSummary.totalBytes : 0) : nil }
    var budgetExceededBytes: UInt64 { budget.enabled && trafficSummary.totalBytes > budget.limitBytes ? trafficSummary.totalBytes - budget.limitBytes : 0 }
    func trafficSummary(period: DeviceBudgetPeriod, scope: DeviceTrafficScope) -> DeviceTrafficSummary {
        trafficLedger.summary(period: period, scope: scope, at: snapshot.sampledAt ?? Date())
    }
    func trafficHistory(yearly: Bool) -> [DeviceTrafficRollup] {
        trafficLedger.history(scope: budget.scope, yearly: yearly, at: snapshot.sampledAt ?? Date())
    }
    func trafficPreview(_ rule: DeviceTrafficBudget) -> DeviceTrafficSummary {
        trafficLedger.summary(budget: rule, at: snapshot.sampledAt ?? Date())
    }
    @discardableResult func saveBudget(_ value: DeviceTrafficBudget) async -> Bool {
        do {
            let valid = try value.validated()
            try persistMonitoring(budget: valid, rule: temperatureRule, state: evaluator.state)
            budget = valid; monitoringRevision = UUID(); trafficSummary = trafficPreview(valid); monitoringError = nil
            if valid.enabled && valid.notificationsEnabled { await requestNotificationPermission() }
            return true
        } catch { monitoringError = error.localizedDescription; return false }
    }
    @discardableResult func saveTemperatureRule(_ value: DeviceTemperatureRule) async -> Bool {
        do {
            let valid = try value.validated(); var next = evaluator
            if valid != temperatureRule { next.resetTemperatureRule() }
            try persistMonitoring(budget: budget, rule: valid, state: next.state)
            temperatureRule = valid; evaluator = next; monitoringRevision = UUID(); monitoringError = nil
            if isSampling { scheduleLoop() }
            if valid.enabled && valid.notificationsEnabled { await requestNotificationPermission() }
            return true
        } catch { monitoringError = error.localizedDescription; return false }
    }
    func refreshNotificationPermission() async {
        notificationPermission = await notifications.permission(); lastPermissionCheck = Date()
        if notificationPermission == .authorized, let error = monitoringError,
           error.contains("系统尚未允许方寸通知") || error.contains("当前通知服务不可用") || error.hasPrefix("通知权限申请失败") {
            monitoringError = nil
        }
    }
    func requestNotificationPermission() async {
        await refreshNotificationPermission()
        if notificationPermission == .notDetermined {
            do { _ = try await notifications.requestPermission(); await refreshNotificationPermission() }
            catch { notificationPermission = .unavailable; monitoringError = "通知权限申请失败：\(error.localizedDescription)"; return }
        }
        if notificationPermission == .denied { monitoringError = "规则已保存；系统尚未允许方寸通知，可在系统设置中开启。" }
        else if notificationPermission == .unavailable { monitoringError = "规则已保存；当前通知服务不可用。" }
    }
    private func persistMonitoring(budget: DeviceTrafficBudget, rule: DeviceTemperatureRule, state: DeviceMonitoringState) throws {
        if monitoringProtected { throw NSError(domain: "DeviceMonitoring", code: 1, userInfo: [NSLocalizedDescriptionKey: "原监测规则文件无法读取，为保留原记录，暂不能覆盖保存。请检查本机数据目录。 "]) }
        try FileManager.default.createDirectory(at: monitoringURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let content = DeviceMonitoringConfiguration(budget: budget, temperatureRule: rule, state: state)
        try JSONEncoder().encode(content).write(to: monitoringURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: monitoringURL.path)
    }
    private func evaluateMonitoring(at date: Date, maximumGap: TimeInterval) async {
        let revision = monitoringRevision, sampleGeneration = generation
        let evaluatedBudget = budget, evaluatedRule = temperatureRule
        if date.timeIntervalSince(lastPermissionCheck) >= 60 { await refreshNotificationPermission() }
        guard revision == monitoringRevision, sampleGeneration == generation else { return }
        guard notificationPermission == .authorized else { evaluator.breakContinuity(); return }
        var next = evaluator
        let events = next.evaluateBudget(evaluatedBudget, summary: trafficSummary)
            + next.evaluateTemperature(evaluatedRule, cpu: snapshot.cpuTemperature, gpu: snapshot.gpuTemperature, at: date, maximumGap: min(maximumGap, effectiveInterval * 1.75))
        for event in events {
            guard revision == monitoringRevision, sampleGeneration == generation else { return }
            do {
                try await notifications.deliver(event, budget: evaluatedBudget, rule: evaluatedRule)
                // Delivery can suspend while the other rule is edited. Commit this event's
                // acknowledgement independently when its own rule is still unchanged.
                acknowledgeDelivered(event, evaluatedBudget: evaluatedBudget, evaluatedRule: evaluatedRule, candidate: next.state)
            }
            catch {
                guard revision == monitoringRevision, sampleGeneration == generation else { return }
                // Failed notifications remain eligible. Successfully delivered sensors are committed independently.
                switch event {
                case .budgetWarning, .budgetExceeded:
                    next.state.budgetCycle = evaluator.state.budgetCycle
                    next.state.budgetExceededSent = evaluator.state.budgetExceededSent
                    next.state.budgetWarningSent = evaluator.state.budgetWarningSent
                case .temperature(let sensor, _): if sensor == "CPU" { next.state.cpu = evaluator.state.cpu } else { next.state.gpu = evaluator.state.gpu }
                }
                monitoringError = "提醒未能发送：\(error.localizedDescription)"
            }
        }
        guard revision == monitoringRevision, sampleGeneration == generation else { return }
        if next.state != evaluator.state {
            do { try persistMonitoring(budget: budget, rule: temperatureRule, state: next.state) }
            catch { monitoringError = "提醒状态未能保存：\(error.localizedDescription)" }
        }
        evaluator = next
    }
    private func acknowledgeDelivered(_ event: DeviceMonitoringEvent, evaluatedBudget: DeviceTrafficBudget,
                                      evaluatedRule: DeviceTemperatureRule, candidate: DeviceMonitoringState) {
        var state = evaluator.state
        switch event {
        case .budgetWarning, .budgetExceeded:
            guard budget == evaluatedBudget else { return }
            state.budgetCycle = candidate.budgetCycle
            state.budgetWarningSent = candidate.budgetWarningSent
            state.budgetExceededSent = candidate.budgetExceededSent
        case .temperature(let sensor, _):
            guard temperatureRule == evaluatedRule else { return }
            if sensor == "CPU" { state.cpu = candidate.cpu } else { state.gpu = candidate.gpu }
        }
        guard state != evaluator.state else { return }
        evaluator.state = state
        do { try persistMonitoring(budget: budget, rule: temperatureRule, state: state) }
        catch { monitoringError = "提醒状态未能保存：\(error.localizedDescription)" }
    }
    #if DEBUG
    /// Deterministic fixtures are compiled only into debug checks; production always uses DeviceSampler.
    func inspectTrafficStorageForChecks() async -> String? { await sampler.inspectTrafficStorageForChecks() }
    func evaluateMonitoringForChecks(snapshot: DeviceSnapshot, ledger: DeviceTrafficLedger, at date: Date, maximumGap: TimeInterval = 3) async {
        self.snapshot = snapshot; trafficLedger = ledger
        trafficSummary = ledger.summary(budget: budget, at: date)
        await evaluateMonitoring(at: date, maximumGap: maximumGap)
    }
    #endif
    private var takingSample = false
    private func takeSample() async {
        guard !takingSample, !systemSleeping, !preparingForQuit else { return }
        takingSample = true; defer { takingSample = false }
        let token = generation, full = wantsPerformance
        let expectedInterval = effectiveInterval
        let maximumGap = max(6, expectedInterval * 2.5)
        let result = await sampler.sample(full: full, thermal: temperatureRule.enabled, token: token, maximumGap: maximumGap)
        guard generation == token, !Task.isCancelled else { return }
        snapshot = result.snapshot; interfaces = result.interfaces
        selectedInterfaceIDs = result.selection; lastError = result.error
        trafficLedger = result.trafficLedger; trafficSummary = trafficPreview(budget)
        await evaluateMonitoring(at: snapshot.sampledAt ?? Date(), maximumGap: maximumGap)
        guard generation == token, !Task.isCancelled else { return }
        guard isWindowVisible, full, let now = snapshot.sampledAt else { return }
        if let lastHistoryDate {
            let gap = now.timeIntervalSince(lastHistoryDate)
            if gap < 0 { history.removeAll(); historySegment = UUID() }
            else if gap > max(6, samplingInterval * 2.5) { historySegment = UUID() }
        }
        history.append(.init(date: now, segment: historySegment, cpuPercent: snapshot.cpuPercent,
                             downloadBytesPerSecond: snapshot.network.downloadBytesPerSecond,
                             uploadBytesPerSecond: snapshot.network.uploadBytesPerSecond, cpuTemperature: snapshot.cpuTemperature, gpuTemperature: snapshot.gpuTemperature, memoryPercent: snapshot.memory?.percent))
        history.removeAll { now.timeIntervalSince($0.date) > 3600 }
        lastHistoryDate = now
    }
}

private struct DeviceMonitoringConfiguration: Codable {
    var budget: DeviceTrafficBudget
    var temperatureRule: DeviceTemperatureRule
    var state: DeviceMonitoringState
}

private struct DeviceSampleResult: Sendable {
    var snapshot: DeviceSnapshot
    var interfaces: [DeviceNetworkInterface]
    var selection: [String]?
    var error: String?
    var trafficLedger: DeviceTrafficLedger
}

/// Actor-isolated synchronous system calls run on Swift's background executor, never MainActor.
private actor DeviceSampler {
    private let ledgerURL: URL
    private let trafficURL: URL
    private var trafficAccumulator = DeviceTrafficAccumulator()
    private var trafficProtected = false
    private var trafficError: String?
    private var accumulator = DeviceNetworkAccumulator()
    private var loaded = false
    private var persistenceError: String?
    private var networkProtected = false
    private var trafficWrites = DevicePersistenceSchedule()
    private var networkWrites = DevicePersistenceSchedule()
    private var scheduledFlush: Task<Void, Never>?
    private var snapshot = DeviceSnapshot()
    private var previousCPU: DeviceCPUTicks?
    private var previousProcesses: [Int32: (started: UInt64, ticks: UInt64)] = [:]
    private var previousPerformanceDate: Date?
    private var previousDisk: (date: Date, counters: [UInt64: DeviceNetworkCounter])?
    private var diskRead: UInt64 = 0, diskWrite: UInt64 = 0
    private var cachedDiskCapacity: DeviceStorageCapacity?
    private var diskCapacityReadUptime: TimeInterval?
    private var token: UUID?
    private var pressure: DevicePressure = .unknown
    private let timebase: Double = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return info.denom > 0 ? Double(info.numer) / Double(info.denom) : 1
    }()
    private var pressureSource: DispatchSourceMemoryPressure?
    private var interfaceMetadata: [String: (name: String, physical: Bool, scope: DeviceTrafficScope?)] = [:]
    private var lastMetadataDate = Date.distantPast
    private lazy var sensors = DeviceSensorReader()
    private var hardwareLoaded = false

    init(dataDirectory: URL) {
        ledgerURL = dataDirectory.appendingPathComponent("device-network.json")
        trafficURL = dataDirectory.appendingPathComponent("device-traffic.json")
    }

    #if DEBUG
    func inspectTrafficStorageForChecks() -> String? { load(); trafficWrites.markChanged(); networkWrites.markChanged(); persist(force: true); return [trafficError, persistenceError].compactMap { $0 }.joined(separator: "；").nilIfEmpty }
    #endif
    func selectInterfaces(_ ids: [String]?) { load(); accumulator.selectInterfaces(ids); networkWrites.markChanged(); persist(force: true) }
    func beginRecording() { load(); accumulator.beginRecording(at: Date()); networkWrites.markChanged(); persist(force: true) }
    func flush() throws {
        guard loaded else { return }
        scheduledFlush?.cancel(); scheduledFlush = nil
        persist(force: true)
        if (trafficWrites.dirty && !trafficProtected) || (networkWrites.dirty && !networkProtected) {
            throw NSError(domain: "Fangcun.NetworkPersistence", code: 1, userInfo: [NSLocalizedDescriptionKey:
                [trafficError, persistenceError].compactMap { $0 }.joined(separator: "；")])
        }
    }

    func sample(full: Bool, thermal: Bool, token: UUID, maximumGap: TimeInterval) -> DeviceSampleResult {
        load()
        let now = Date()
        if self.token != token {
            self.token = token; accumulator.breakContinuity(); trafficAccumulator.breakContinuity(); previousCPU = nil
            previousPerformanceDate = nil; previousProcesses.removeAll(); previousDisk = nil
        }
        if now.timeIntervalSince(lastMetadataDate) > 30 { refreshInterfaceMetadata(); lastMetadataDate = now }
        let read = networkCounters()
        let interfaces = read.map { id, entry in
            let meta = interfaceMetadata[id]
            return DeviceNetworkInterface(id: id, name: meta?.name ?? id,
                                          isVirtual: !(meta?.physical ?? id.hasPrefix("en")),
                                          isActive: entry.active,
                                          isDefault: meta?.physical ?? id.hasPrefix("en"))
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        let selected = accumulator.ledger.selectedInterfaceIDs.map(Set.init)
        let chosen = interfaces.filter { $0.isActive && (selected?.contains($0.id) ?? $0.isDefault) }
        let counters = Dictionary(uniqueKeysWithValues: chosen.compactMap { interface in
            read[interface.id].map { (interface.id, $0.counter) }
        })
        let physical = read.filter { $0.value.active && interfaceMetadata[$0.key]?.physical == true }
        let wifi = physical.filter { interfaceMetadata[$0.key]?.scope == .wifi }.mapValues(\.counter)
        let ethernet = physical.filter { interfaceMetadata[$0.key]?.scope == .ethernet }.mapValues(\.counter)
        trafficAccumulator.ingest(wifi: wifi, ethernet: ethernet, at: now, maximumGap: maximumGap)
        let delta = accumulator.ingest(counters, at: now, maximumGap: maximumGap)
        trafficWrites.markChanged(); networkWrites.markChanged()
        let ledger = accumulator.ledger, today = ledger.today(at: now)
        snapshot.network = .init(downloadBytesPerSecond: delta?.downloadBytesPerSecond,
                                 uploadBytesPerSecond: delta?.uploadBytesPerSecond,
                                 sessionDownload: ledger.recordingReceived, sessionUpload: ledger.recordingSent,
                                 todayDownload: today.received, todayUpload: today.sent,
                                 todayCoverageSeconds: today.coveredSeconds, sessionCoverageSeconds: ledger.recordingCoveredSeconds,
                                 recordedSince: ledger.recordingStartedAt, todayFirstSample: today.firstSample,
                                 todayLastSample: today.lastSample, excludedIntervals: today.excludedIntervals,
                                 interfaceNames: chosen.map { "\($0.name) · \($0.id)" })
        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        snapshot.sampledAt = now
        if full { samplePerformance(now: now, maximumGap: maximumGap) }
        else {
            previousCPU = nil; previousPerformanceDate = nil; previousProcesses.removeAll(); previousDisk = nil
            if thermal { sampleThermal() }
        }
        persist()
        return .init(snapshot: snapshot, interfaces: interfaces, selection: ledger.selectedInterfaceIDs, error: [persistenceError, trafficError].compactMap { $0 }.joined(separator: "；").nilIfEmpty, trafficLedger: trafficAccumulator.ledger)
    }

    private func load() {
        guard !loaded else { return }; loaded = true
        if FileManager.default.fileExists(atPath: trafficURL.path) {
            do { trafficAccumulator = .init(ledger: try JSONDecoder().decode(DeviceTrafficLedger.self, from: boundedHistoryData(trafficURL)).validated()) }
            catch { trafficProtected = true; trafficError = "流量历史无法读取，已保留原文件；当前仅显示本次运行记录。" }
        }
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            do { accumulator = DeviceNetworkAccumulator(ledger: try JSONDecoder().decode(DeviceNetworkLedger.self, from: boundedHistoryData(ledgerURL)).validated()) }
            catch {
                networkProtected = true
                persistenceError = "网络记录无法读取，已保留原文件；当前仅显示本次运行记录。"
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            let value: DevicePressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            Task { await self?.setPressure(value) }
        }
        pressureSource = source; source.resume()
    }

    private func setPressure(_ value: DevicePressure) { pressure = value }

    private func boundedHistoryData(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 4_194_305) ?? Data()
        guard data.count <= 4_194_304 else { throw DeviceNetworkLedgerError.invalidFields }
        return data
    }

    private func persist(force: Bool = false) {
        defer { schedulePendingFlush() }
        let uptime = ProcessInfo.processInfo.systemUptime
        if !trafficProtected, trafficWrites.beginWrite(at: uptime, force: force) {
            do {
                try FileManager.default.createDirectory(at: trafficURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(trafficAccumulator.ledger).write(to: trafficURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: trafficURL.path); trafficError = nil
                trafficWrites.didWrite()
            } catch { trafficError = "流量记录保存失败：\(error.localizedDescription)" }
        }
        guard !networkProtected, networkWrites.beginWrite(at: uptime, force: force) else { return }
        do {
            try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(accumulator.ledger)
            try data.write(to: ledgerURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
            networkWrites.didWrite()
            if persistenceError?.hasPrefix("网络记录保存失败") == true { persistenceError = nil }
        } catch { persistenceError = "网络记录保存失败：\(error.localizedDescription)" }
    }

    private func schedulePendingFlush() {
        let pending = (trafficWrites.dirty && !trafficProtected) || (networkWrites.dirty && !networkProtected)
        guard pending else { scheduledFlush?.cancel(); scheduledFlush = nil; return }
        guard scheduledFlush == nil else { return }
        scheduledFlush = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await self?.performScheduledFlush()
        }
    }
    private func performScheduledFlush() { scheduledFlush = nil; persist(force: true) }

    private func samplePerformance(now: Date, maximumGap: TimeInterval) {
        let elapsed = previousPerformanceDate.map { now.timeIntervalSince($0) }
        let continuous = elapsed.map { $0 > 0 && $0 <= maximumGap } ?? false
        if !hardwareLoaded {
            hardwareLoaded = true
            snapshot.modelIdentifier = sysctlString("hw.model") ?? "Mac"
            snapshot.deviceName = hardwareName() ?? snapshot.modelIdentifier
            snapshot.performanceCores = sysctlUInt64("hw.perflevel0.physicalcpu").map(Int.init)
            snapshot.efficiencyCores = sysctlUInt64("hw.perflevel1.physicalcpu").map(Int.init)
        }
        snapshot.chipName = sysctlString("machdep.cpu.brand_string") ?? "Mac 处理器"
        snapshot.logicalCPUCount = ProcessInfo.processInfo.activeProcessorCount
        snapshot.physicalCPUCount = Int(sysctlUInt64("hw.physicalcpu") ?? UInt64(snapshot.logicalCPUCount))
        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        if let current = cpuTicks() {
            let values = continuous ? previousCPU.flatMap { current.percentages(since: $0) } : nil
            snapshot.cpuPercent = values?.total; snapshot.cpuUserPercent = values?.user; snapshot.cpuSystemPercent = values?.system
            previousCPU = current
        } else { snapshot.cpuPercent = nil; snapshot.cpuUserPercent = nil; snapshot.cpuSystemPercent = nil }
        if let level = sysctlUInt64("kern.memorystatus_vm_pressure_level") {
            switch level { case 1: pressure = .normal; case 2: pressure = .warning; case 4: pressure = .critical; default: break }
        }
        snapshot.memory = memory()
        snapshot.disk = disk(now: now, maximumGap: maximumGap)
        snapshot.battery = battery()
        sampleThermal()
        snapshot.processes = processes(now: now, elapsed: continuous ? elapsed : nil)
        snapshot.performanceSampledAt = now; previousPerformanceDate = now
    }

    private func sampleThermal() {
        if snapshot.chipName == "正在读取" { snapshot.chipName = sysctlString("machdep.cpu.brand_string") ?? "Mac 处理器" }
        let thermal = sensors.read(chip: snapshot.chipName)
        snapshot.cpuTemperature = thermal.cpu; snapshot.gpuTemperature = thermal.gpu
        snapshot.fanRPM = thermal.fans; snapshot.sensorSource = thermal.source
        snapshot.cpuSensorKeys = thermal.cpuKeys; snapshot.gpuSensorKeys = thermal.gpuKeys
        snapshot.unavailableReasons["temperature"] = thermal.cpu == nil || thermal.gpu == nil ? "当前硬件未返回有效温度传感器读数。" : nil
        snapshot.unavailableReasons["fan"] = thermal.fans == nil ? "当前硬件未返回有效风扇读数。" : nil
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: snapshot.thermalState = .nominal
        case .fair: snapshot.thermalState = .fair
        case .serious: snapshot.thermalState = .serious
        case .critical: snapshot.thermalState = .critical
        @unknown default: snapshot.thermalState = .unknown
        }
    }

    private func hardwareName() -> String? {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPHardwareDataType", "-json", "-detailLevel", "mini"]
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard data.count < 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPHardwareDataType"] as? [[String: Any]] else { return nil }
        return items.first?["machine_name"] as? String
    }

    private func cpuTicks() -> DeviceCPUTicks? {
        var info = host_cpu_load_info(), count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return .init(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func memory() -> DeviceMemorySnapshot? {
        var vm = vm_statistics64(), count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0; guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let page = UInt64(pageSize), total = ProcessInfo.processInfo.physicalMemory
        let wired = UInt64(vm.wire_count) * page, compressed = UInt64(vm.compressor_page_count) * page
        let application = UInt64(vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0) * page
        let used = min(total, application + wired + compressed)
        var swap = xsw_usage(), size = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        return .init(total: total, used: used, available: total - used, application: application, wired: wired,
                     compressed: compressed, cached: UInt64(vm.external_page_count) * page,
                     swapUsed: swapOK ? swap.xsu_used : nil, pageIns: vm.pageins * page, pageOuts: vm.pageouts * page, pressure: pressure)
    }

    private func disk(now: Date, maximumGap: TimeInterval) -> DeviceDiskSnapshot? {
        // /System/Volumes/Data is the writable startup data volume on modern macOS.
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        let uptime = ProcessInfo.processInfo.systemUptime
        if diskCapacityReadUptime.map({ uptime < $0 || uptime - $0 >= 30 }) ?? true {
            cachedDiskCapacity = DeviceStorageCapacity.read(at: url); diskCapacityReadUptime = uptime
        }
        guard let capacity = cachedDiskCapacity else { return nil }
        var fs = statfs(); let ok = statfs(url.path, &fs) == 0
        let fsName = ok ? withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : "—"
        var reading: Double?, writing: Double?
        if let counters = diskCounters() {
            if let previousDisk, counters.keys.sorted() == previousDisk.counters.keys.sorted() {
                let dt = now.timeIntervalSince(previousDisk.date)
                if dt > 0, dt <= maximumGap {
                    var r: UInt64 = 0, w: UInt64 = 0; var valid = true
                    for (id, value) in counters {
                        guard let old = previousDisk.counters[id], value.received >= old.received, value.sent >= old.sent else { valid = false; break }
                        r += value.received - old.received; w += value.sent - old.sent
                    }
                    if valid { reading = Double(r) / dt; writing = Double(w) / dt; diskRead += r; diskWrite += w }
                }
            }
            previousDisk = (now, counters)
        } else { previousDisk = nil }
        return .init(name: capacity.volumeName ?? "启动卷", fileSystem: fsName.uppercased(), total: capacity.total, used: capacity.used,
                     available: capacity.available, readBytesPerSecond: reading, writeBytesPerSecond: writing,
                     recordedRead: diskRead, recordedWrite: diskWrite, immediatelyFree: capacity.immediatelyFree,
                     reclaimableEstimate: capacity.reclaimableEstimate)
    }

    private func diskCounters() -> [UInt64: DeviceNetworkCounter]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [UInt64: DeviceNetworkCounter] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let read = stats["Bytes (Read)"] as? NSNumber, let write = stats["Bytes (Write)"] as? NSNumber else { continue }
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS {
                result[id] = .init(received: read.uint64Value, sent: write.uint64Value)
            }
        }
        return result.isEmpty ? nil : result
    }

    private func battery() -> DeviceBatterySnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let internalBatteries = list.compactMap { source in
            IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
        }.filter { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType && ($0[kIOPSIsPresentKey] as? Bool ?? true) }
        for d in internalBatteries {
            guard let current = d[kIOPSCurrentCapacityKey] as? NSNumber, let max = d[kIOPSMaxCapacityKey] as? NSNumber,
                  max.doubleValue > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = (d[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? NSNumber)?.intValue
            // Current/max capacity can be normalized percentages. Only compare nominal/design when both are supplied in the same documented unit.
            let nominal = (d[kIOPSNominalCapacityKey] as? NSNumber)?.doubleValue
            let design = (d[kIOPSDesignCapacityKey] as? NSNumber)?.doubleValue
            let healthPercent: Double? = (nominal != nil && design != nil && design! > 0) ? min(100, nominal! / design! * 100) : nil
            return .init(percent: min(100, Swift.max(0, current.doubleValue / max.doubleValue * 100)),
                         isCharging: charging, isPluggedIn: plugged, timeRemainingMinutes: minutes.flatMap { $0 > 0 ? $0 : nil },
                         health: d[kIOPSBatteryHealthKey] as? String, maximumCapacityPercent: healthPercent,
                         cycleCount: batteryCycleCount(internalBatteryCount: internalBatteries.count))
        }
        return nil
    }

    private func batteryCycleCount(internalBatteryCount: Int) -> Int? {
        guard internalBatteryCount == 1 else { return nil }
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOPMPowerSource"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var installedCycleCounts: [Any?] = []
        while true {
            let source = IOIteratorNext(iterator)
            guard source != 0 else { break }
            defer { IOObjectRelease(source) }
            guard let installed = IORegistryEntryCreateCFProperty(source, kIOPMPSBatteryInstalledKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  CFGetTypeID(installed) == CFBooleanGetTypeID(), let isInstalled = installed as? Bool else { return nil }
            guard isInstalled else { continue }
            let count = IORegistryEntryCreateCFProperty(source, kIOPMPSCycleCountKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            installedCycleCounts.append(count)
        }
        return DeviceBatteryCycleCount.resolve(internalBatteryCount: internalBatteryCount, installedCycleCounts: installedCycleCounts)
    }

    private func processes(now: Date, elapsed: TimeInterval?) -> [DeviceProcess] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { snapshot.processTotalCount = 0; snapshot.processReadCount = 0; return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 128)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var next: [Int32: (started: UInt64, ticks: UInt64)] = [:], results: [DeviceProcess] = []
        var appCache: [String: DeviceProcessApplication] = [:], appMisses = Set<String>()
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 {
            var info = proc_taskallinfo()
            let bytes = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, Int32(MemoryLayout<proc_taskallinfo>.size))
            guard bytes == MemoryLayout<proc_taskallinfo>.size else { continue }
            let ticks = info.ptinfo.pti_total_user + info.ptinfo.pti_total_system
            let started = info.pbsd.pbi_start_tvsec * 1_000_000 + info.pbsd.pbi_start_tvusec
            var cpu: Double?
            if let old = previousProcesses[pid], old.started == started, ticks >= old.ticks, let elapsed {
                // XNU fill_taskprocinfo returns Mach absolute ticks. Convert using this machine’s timebase, then normalize to whole-machine capacity.
                cpu = DeviceProcessCPU.percent(ticks: ticks - old.ticks, nanosecondsPerTick: timebase, elapsed: elapsed, logicalCores: snapshot.logicalCPUCount)
            }
            next[pid] = (started, ticks)
            var name = withUnsafeBytes(of: info.pbsd.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name.isEmpty { name = withUnsafeBytes(of: info.pbsd.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
            // PROC_PIDPATHINFO_MAXSIZE is a C expression macro (4 * MAXPATHLEN), not imported by Swift.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathLength = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            let executable = pathLength > 0 ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
            results.append(.init(pid: pid, name: name.isEmpty ? "PID \(pid)" : name, executablePath: executable,
                                 cpuPercent: cpu, residentBytes: info.ptinfo.pti_resident_size,
                                 threadCount: Int(info.ptinfo.pti_threadnum), sampledAt: now, startedMicroseconds: started,
                                 parentPID: Int32(info.pbsd.pbi_ppid), ownerUID: info.pbsd.pbi_uid,
                                 application: DeviceProcessRuntime.application(for: executable, cache: &appCache, misses: &appMisses)))
        }
        previousProcesses = next; snapshot.processTotalCount = Int(count); snapshot.processReadCount = results.count
        return DeviceProcess.filtered(DeviceProcessExplorer.inheritApplications(results), query: "", sort: .cpu)
    }

    private func refreshInterfaceMetadata() {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
        interfaceMetadata = [:]
        for interface in all {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
            let physical = type == (kSCNetworkInterfaceTypeIEEE80211 as String) || type == (kSCNetworkInterfaceTypeEthernet as String)
            let label = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? name
            interfaceMetadata[name] = (label, physical, type == (kSCNetworkInterfaceTypeIEEE80211 as String) ? .wifi : type == (kSCNetworkInterfaceTypeEthernet as String) ? .ethernet : nil)
        }
    }

    private func networkCounters() -> [String: (counter: DeviceNetworkCounter, active: Bool)] {
        // NET_RT_IFLIST2 supplies true 64-bit counters; getifaddrs' if_data counters can wrap at 4 GiB.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_LINK, NET_RT_IFLIST2, 0], size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0, size < 16_777_216 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        let ok = buffer.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        guard ok == 0 else { return [:] }
        return buffer.withUnsafeBytes { bytes in
            var result: [String: (counter: DeviceNetworkCounter, active: Bool)] = [:], offset = 0
            while offset + 4 <= size {
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, offset + length <= size else { break }
                if bytes[offset + 3] == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if message.ifm_flags & IFF_LOOPBACK == 0 {
                        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                        if if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil {
                            let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                            result[name] = (.init(received: message.ifm_data.ifi_ibytes, sent: message.ifm_data.ifi_obytes),
                                            message.ifm_flags & IFF_UP != 0 && message.ifm_flags & IFF_RUNNING != 0)
                        }
                    }
                }
                offset += length
            }
            return result
        }
    }

    private func sysctlString(_ key: String) -> String? {
        var length = 0
        guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 0, length < 4096 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname(key, &buffer, &length, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    private func sysctlUInt64(_ key: String) -> UInt64? {
        var value: UInt64 = 0, size = MemoryLayout<UInt64>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }; return value
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }


/// System metadata and actions are isolated from view state. No shell commands or name-based kills.
@MainActor
struct DeviceProcessActionService {
    static func perform(_ request: DeviceProcessActionRequest) -> Result<String, Error> {
        do {
            let count = try DeviceProcessActions.perform(request, currentUID: getuid(), currentPID: getpid(), currentApplicationPath: Bundle.main.bundleURL.resolvingSymlinksInPath().path, reread: { pid in
                DeviceProcessRuntime.readWithAncestry(pid)
            }, dispatch: { process, operation in
                switch operation {
                case .quitApplication:
                    guard let application = NSRunningApplication(processIdentifier: process.pid),
                          application.bundleURL?.resolvingSymlinksInPath().path == process.application?.bundlePath,
                          application.terminate() else {
                        throw DeviceProcessActionError.failed("应用未接受退出请求。可能正在等待保存确认；如仍无响应，可单独选择强制结束。")
                    }
                case .terminate, .forceTerminate:
                    let signal = operation == .forceTerminate ? SIGKILL : SIGTERM
                    guard Darwin.kill(process.pid, signal) == 0 else {
                        throw DeviceProcessActionError.failed("结束请求未成功：\(String(cString: strerror(errno)))")
                    }
                }
            })
            return .success(request.mode == .force ? "已向 \(count) 个已确认进程发送强制结束请求。" : "已发送退出请求，等待进程结束或应用的保存确认。")
        } catch { return .failure(error) }
    }
}

private enum DeviceProcessRuntime {
    static func application(for executable: String?, cache: inout [String: DeviceProcessApplication], misses: inout Set<String>) -> DeviceProcessApplication? {
        guard let executable else { return nil }
        let url = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        var path = ""
        // The outermost genuine bundle contains helper .app bundles, e.g. browser renderers.
        for component in url.pathComponents {
            path = (path as NSString).appendingPathComponent(component)
            guard (component as NSString).pathExtension.lowercased() == "app" else { continue }
            if let value = cache[path] { return value }
            if misses.contains(path) { continue }
            guard let bundle = Bundle(path: path), let identifier = bundle.bundleIdentifier,
                  let main = bundle.executableURL?.resolvingSymlinksInPath().path else { misses.insert(path); continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? (component as NSString).deletingPathExtension
            let value = DeviceProcessApplication(bundlePath: path, bundleIdentifier: identifier, name: name, executablePath: main)
            cache[path] = value; return value
        }
        return nil
    }

    static func readWithAncestry(_ pid: Int32) -> DeviceProcess? {
        guard let process = read(pid) else { return nil }
        var ancestry = [process], visited: Set<Int32> = [pid], current = process
        while current.application == nil, current.parentPID > 1,
              visited.insert(current.parentPID).inserted, let parent = read(current.parentPID), ancestry.count < 64 {
            ancestry.append(parent); current = parent
        }
        return DeviceProcessExplorer.inheritApplications(ancestry).first
    }

    static func read(_ pid: Int32) -> DeviceProcess? {
        var info = proc_taskallinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, Int32(MemoryLayout<proc_taskallinfo>.size)) == MemoryLayout<proc_taskallinfo>.size else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        let executable = length > 0 ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        let name = withUnsafeBytes(of: info.pbsd.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var cache: [String: DeviceProcessApplication] = [:], misses = Set<String>()
        return DeviceProcess(pid: pid, name: name, executablePath: executable, residentBytes: info.ptinfo.pti_resident_size,
                             threadCount: Int(info.ptinfo.pti_threadnum), sampledAt: Date(),
                             startedMicroseconds: info.pbsd.pbi_start_tvsec * 1_000_000 + info.pbsd.pbi_start_tvusec,
                             parentPID: Int32(info.pbsd.pbi_ppid), ownerUID: info.pbsd.pbi_uid,
                             application: application(for: executable, cache: &cache, misses: &misses))
    }
}
