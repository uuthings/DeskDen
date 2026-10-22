import AppKit
import Combine
import Foundation
import LauncherCore

enum HealthCenterPhase: String { case overview, checking, report, processing, result }
enum HealthCenterAssessmentOutcome: Equatable { case none, completed, cancelled, failed }
enum HealthCenterResultKind: Hashable { case files, applications }
#if DEBUG
@MainActor final class HealthHistoryNavigationInspection {
    var actions: [HealthCenterResultKind: @MainActor () -> Void] = [:]
}
#endif
enum HealthCenterCategory: String, CaseIterable {
    case overview, cache, diagnostics, memory
    var title: String { switch self { case .overview: "健康发现"; case .cache: "可重建缓存"; case .diagnostics: "历史诊断记录"; case .memory: "应用内存" } }
    var symbol: String { switch self { case .overview: "heart.text.square"; case .cache: "square.3.layers.3d"; case .diagnostics: "doc.badge.clock"; case .memory: "memorychip" } }
}

struct HealthCenterEvidenceText: Equatable {
    var label: String
    var value: String
}

/// Presentation is derived solely from stored evidence. A parse failure remains
/// unavailable; it cannot become a zero capacity, normal pressure or zero seconds.
enum HealthCenterEvidenceDisplay {
    static func text(_ evidence: DeviceHealthEvidence) -> HealthCenterEvidenceText {
        let value: String
        let label: String
        switch evidence.key {
        case "volume": label = "磁盘宗卷"; value = evidence.value.isEmpty ? "未提供" : evidence.value
        case "totalBytes", "availableBytes", "swapUsedBytes":
            label = evidence.key == "totalBytes" ? "总容量" : evidence.key == "availableBytes" ? "可用空间" : "已用交换空间"
            value = UInt64(evidence.value).map { DeviceFormat.capacity($0) } ?? "读数不可用"
        case "availableFraction":
            label = "可用空间占比"
            if let fraction = Double(evidence.value), fraction.isFinite, (0...1).contains(fraction) { value = String(format: "%.1f%%", fraction * 100) }
            else { value = "读数不可用" }
        case "sustainedSeconds":
            label = "连续观测时长"
            if let seconds = Double(evidence.value), seconds.isFinite, seconds >= 0 {
                value = String(format: seconds.rounded() == seconds ? "%.0f 秒" : "%.1f 秒", seconds)
            } else { value = "读数不可用" }
        case "pressure":
            label = "内存压力"
            if let pressure = DevicePressure(rawValue: evidence.value) { value = pressure == .unknown ? "不可用" : DeviceFormat.pressure(pressure) }
            else { value = "未识别" }
        case "thermalState":
            label = "系统热状态"
            switch DeviceThermalState(rawValue: evidence.value) {
            case .nominal: value = "正常"
            case .fair: value = "略高"
            case .serious: value = "严重"
            case .critical: value = "临界"
            case .unknown, nil: value = "不可用"
            }
        case "condition":
            label = "电池健康"
            switch DeviceHealthBatteryCondition(rawValue: evidence.value) {
            case .normal: value = "正常"
            case .serviceRecommended: value = "系统建议检修"
            case .unavailable, nil: value = "不可用"
            }
        case "rule": label = "评分规则"; value = evidence.value
        default: label = "来源补充"; value = evidence.value
        }
        return .init(label: label, value: value)
    }
}

@MainActor final class HealthCenterModel: ObservableObject {
    let device: DeviceStatusModel
    let storage: StorageReviewService
    let applications: HealthApplicationReviewModel
    @Published private(set) var phase: HealthCenterPhase = .overview
    @Published private(set) var latestReport: DeviceHealthReport?
    @Published private(set) var completedFactors: [DeviceHealthFactorResult] = []
    @Published var category: HealthCenterCategory = .overview
    @Published var includeCache = true
    @Published var includeDiagnostics = true
    @Published var includeMemory = true
    @Published var reportExpanded = false
    @Published private(set) var storageError: String?
    @Published private(set) var waitingForFreshSample = false
    @Published private(set) var assessmentOutcome: HealthCenterAssessmentOutcome = .none
    @Published private(set) var resultKind: HealthCenterResultKind = .files
    /// The shell owns the actual return route/detail; this label survives module navigation.
    var returnContext = "首页"
    weak var hostWindow: NSWindow?
    #if DEBUG
    var historyNavigationInspection: HealthHistoryNavigationInspection?
    #endif
    private var memoryContinuity = DeviceHealthContinuity<DevicePressure>()
    private var thermalContinuity = DeviceHealthContinuity<DeviceThermalState>()
    private var memorySeconds: TimeInterval = 0
    private var thermalSeconds: TimeInterval = 0
    private var lastObservation: Date?
    private var recheckAfter: Date?
    private var pendingAssessment: DeviceHealthReport?
    private var history = DeviceHealthHistory()
    private let historyURL: URL
    private var historyProtected = false
    private var subscriptions = Set<AnyCancellable>()
    init(device: DeviceStatusModel, dataDirectory: URL, storageService: StorageReviewService? = nil,
         applicationReview: HealthApplicationReviewModel? = nil) {
        self.device = device; historyURL = dataDirectory.appendingPathComponent("health-history.json")
        storage = storageService ?? StorageReviewService(dataDirectory: dataDirectory)
        applications = applicationReview ?? HealthApplicationReviewModel()
        if FileManager.default.fileExists(atPath: historyURL.path) {
            do {
                let handle = try FileHandle(forReadingFrom: historyURL); defer { try? handle.close() }
                let data = try handle.read(upToCount: 1_048_577) ?? Data()
                guard data.count <= 1_048_576 else { throw DeviceHealthPersistenceError.invalidReport }
                history = try JSONDecoder().decode(DeviceHealthHistory.self, from: data).validated()
                latestReport = history.reports.first(where: { $0.stage == .report })
                if latestReport != nil { assessmentOutcome = .completed }
            } catch { historyProtected = true; storageError = "体检历史无法读取，原文件已保留；本次结果仅在当前会话显示。" }
        }
        storage.onScanFinished = { [weak self] in
            guard let self, self.phase == .checking else { return }
            if self.storage.report?.stage == .cancelled { self.abandonAssessment(.cancelled) }
            else if self.storage.report?.stage == .report { self.finishAssessment() }
            else { self.abandonAssessment(.failed) }
        }
        storage.onProcessingFinished = { [weak self] in
            guard let self else { return }; self.resultKind = .files; self.phase = .result; self.waitingForFreshSample = true; self.recheckAfter = Date()
        }
        storage.onRestored = { [weak self] in self?.waitingForFreshSample = true; self?.recheckAfter = Date() }
        applications.onProcessingStarted = { [weak self] in self?.resultKind = .applications; self?.phase = .processing }
        applications.onProcessingFinished = { [weak self] in
            guard let self else { return }
            self.phase = .result; self.waitingForFreshSample = true; self.recheckAfter = Date()
        }
        storage.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        applications.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        device.$snapshot.sink { [weak self] snapshot in Task { @MainActor in self?.applications.update(snapshot); self?.observe(snapshot) } }.store(in: &subscriptions)
    }
    var score: Int? { latestReport?.score }
    var summary: String { latestReport?.summary ?? (assessmentOutcome == .cancelled ? "体检已取消" : "尚未体检") }
    var showingPreviousReport: Bool { latestReport != nil && (assessmentOutcome == .cancelled || assessmentOutcome == .failed) }
    var assessmentNotice: String? {
        guard assessmentOutcome == .cancelled || assessmentOutcome == .failed else { return nil }
        let action = assessmentOutcome == .cancelled ? "本次体检已取消" : "本次文件检查未完整完成"
        return action + (latestReport == nil ? "，尚无已完成的体检结果。" : "，下方保留上次完成的体检结果。")
    }
    var coverageText: String { latestReport.map { "\($0.evaluatedRequiredCount) / \($0.requiredCount) 项可评价" } ?? "等待读取有效设备状态" }
    var assessmentDescription: String {
        guard let report = latestReport else { return "先检查设备状态，再决定是否处理。没有有效读数时保持未知。" }
        if report.score == nil { return "部分来源缺失、过期或仍在观察；可以查看已取得的证据，暂不生成精确分数。" }
        if report.severity == .good { return "当前已知指标整体正常。macOS 会利用空闲内存缓存，无需为了缓存主动退出应用。" }
        return "根据有效来源与持续状态发现需要复核的项目；按优先级逐项处理。"
    }
    func showOverview() {
        guard !storage.isProcessing, !applications.isProcessing else { return }
        if phase == .checking { cancelCheck(); return }
        phase = .overview; category = .overview
    }
    func showReport() { phase = .report; category = .overview }
    var canShowResults: Bool { !storage.isScanning && !storage.isProcessing && !applications.isProcessing }
    func showResults(kind: HealthCenterResultKind? = nil) {
        guard canShowResults else { return }
        // Persistent file receipts must remain reachable after a later application request.
        resultKind = kind ?? (!storage.receipts.isEmpty ? .files : applications.hasResults ? .applications : resultKind)
        phase = .result
    }
    func showCategory(_ next: HealthCenterCategory) { phase = .report; category = next }
    func startAssessment() {
        guard !storage.isScanning, !storage.isProcessing, !applications.isProcessing else { return }
        applications.clearSelection()
        beginAssessment()
        var kinds = Set<StorageReviewScopeKind>()
        if includeCache { kinds.insert(.rebuildableCache) }; if includeDiagnostics { kinds.insert(.diagnosticRecords) }
        if !kinds.isEmpty, storage.scopes.contains(where: { kinds.contains($0.kind) }) { storage.scan(kinds: kinds) }
        else { finishAssessment() }
    }
    private func beginAssessment() {
        phase = .checking; category = .overview; completedFactors = []; waitingForFreshSample = false
        // A manual assessment replaces the pending automatic recheck. It must not
        // silently run a second assessment when the next sample arrives.
        recheckAfter = nil; assessmentOutcome = .none
        storage.clearCurrentReport()
        observe(device.snapshot)
        pendingAssessment = DeviceHealthAssessor.evaluate(snapshot(), progress: { [weak self] item in self?.completedFactors.append(item) })
    }
    private func finishAssessment() {
        guard let report = pendingAssessment else { return }
        pendingAssessment = nil; latestReport = report; assessmentOutcome = .completed
        phase = .report; category = .overview; save(report)
    }
    private func abandonAssessment(_ outcome: HealthCenterAssessmentOutcome) {
        pendingAssessment = nil; assessmentOutcome = outcome; phase = .overview; category = .overview
    }
    func cancelCheck() {
        guard !storage.isProcessing else { return }
        storage.cancel(); abandonAssessment(.cancelled)
    }
    func beginProcessing() { resultKind = .files; storage.executeConfirmedPlan(); if storage.isProcessing { phase = .processing } }
    func cancelAll() { if phase == .checking { cancelCheck() } else { storage.cancel() }; applications.cancelRemaining() }
    func prepareForQuit() async { cancelAll(); await storage.stopForQuit(); await applications.stopForQuit() }
    func resumeAfterCancelledQuit() { applications.resumeAfterCancelledQuit() }
    func revealHistory() { NSWorkspace.shared.open(historyURL.deletingLastPathComponent()) }
    private func observe(_ value: DeviceSnapshot) {
        guard let at = value.performanceSampledAt else { memoryContinuity.reset(); thermalContinuity.reset(); memorySeconds = 0; thermalSeconds = 0; return }
        guard lastObservation != at else { return }
        lastObservation = at
        let maximumGap = max(8, device.samplingInterval * 3)
        let pressure = value.memory?.pressure
        memorySeconds = memoryContinuity.ingest(pressure == .unknown ? nil : pressure, at: at, maximumGap: maximumGap)
        thermalSeconds = thermalContinuity.ingest(value.thermalState == .unknown ? nil : value.thermalState, at: at, maximumGap: maximumGap)
        if let recheckAfter, at > recheckAfter {
            let report = DeviceHealthAssessor.evaluate(snapshot(), at: Date())
            latestReport = report; assessmentOutcome = .completed; save(report); self.recheckAfter = nil; waitingForFreshSample = false
        }
    }
    #if DEBUG
    /// Holds the production assessment's pending stage at the file-scan boundary.
    /// No scanner, panel, personal path or OS mover is invoked by this fixture.
    func beginAssessmentAwaitingScanForChecks() {
        guard !storage.isScanning, !storage.isProcessing else { return }; beginAssessment()
    }
    #endif
    private func snapshot() -> DeviceHealthSnapshot {
        let value = device.snapshot
        guard let sampledAt = value.performanceSampledAt else {
            return .init(memory: .init(source: "macOS 内存压力"), storage: .init(source: "macOS 文件系统"), thermal: .init(source: "macOS 系统热状态"))
        }
        let memory: DeviceHealthReading<DeviceHealthMemoryReading> = value.memory.map {
            .init(value: .init(pressure: $0.pressure, sustainedSeconds: memorySeconds, swapUsedBytes: $0.swapUsed), sampledAt: sampledAt, source: "macOS 内存压力 / Mach")
        } ?? .init(source: "macOS 内存压力")
        let storage: DeviceHealthReading<DeviceHealthStorageReading> = value.disk.map {
            .init(value: .init(totalBytes: $0.total, availableBytes: $0.available, volumeName: $0.name), sampledAt: sampledAt, source: "macOS 文件系统容量")
        } ?? .init(source: "macOS 文件系统容量")
        let thermal = DeviceHealthReading(value: DeviceHealthThermalReading(state: value.thermalState, sustainedSeconds: thermalSeconds), sampledAt: sampledAt, source: "ProcessInfo.thermalState")
        let battery: DeviceHealthReading<DeviceHealthBatteryCondition>
        if let health = value.battery?.health {
            let known: DeviceHealthBatteryCondition? = ["Good", "正常"].contains(health) ? .normal : ["Check Battery", "Poor", "Fair", "Service Recommended"].contains(health) ? .serviceRecommended : nil
            battery = known.map { .init(value: $0, sampledAt: sampledAt, source: "IOKit 电池健康") } ?? .init(source: "IOKit 电池健康", detail: "系统返回的电池状态未被当前规则识别。")
        } else { battery = .init(source: "IOKit 电池健康") }
        return .init(memory: memory, storage: storage, thermal: thermal, battery: battery)
    }
    private func save(_ report: DeviceHealthReport) {
        guard !historyProtected else { return }
        do {
            var next = history; try next.append(report)
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(next).write(to: historyURL, options: .atomic); history = next; storageError = nil
        } catch { storageError = "体检结果尚未写入磁盘，上次记录仍保留：\(error.localizedDescription)" }
    }
}
