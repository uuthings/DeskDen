import Foundation

/// Product rules for an explainable state summary, not a hardware diagnostic.
/// No CPU utilisation, cache size or action count contributes to the score.
public enum DeviceHealthRules {
    public static let version = "2026-10-21.1"
    public static let maximumSampleAge: TimeInterval = 60
    public static let futureClockTolerance: TimeInterval = 5
    public static let sustainedPressureSeconds: TimeInterval = 60
    public static let sustainedThermalSeconds: TimeInterval = 60
    public static let storageWarningFraction = 0.15
    public static let storageCriticalFraction = 0.05
    public static let storageWarningBytes: UInt64 = 20_000_000_000
    public static let storageCriticalBytes: UInt64 = 5_000_000_000

    public static func explanation(for factor: DeviceHealthFactor) -> String {
        switch factor {
        case .storage:
            return "余量 <\(Int(storageCriticalFraction * 100))% 或 <\(storageCriticalBytes / 1_000_000_000) GB 扣40；<\(Int(storageWarningFraction * 100))% 或 <\(storageWarningBytes / 1_000_000_000) GB 扣16；其余不扣分"
        case .memory:
            return "正常不扣分；持续\(Int(sustainedPressureSeconds))秒警告扣14；持续\(Int(sustainedPressureSeconds))秒严重扣35"
        case .thermal:
            return "正常与略高不扣分；持续\(Int(sustainedThermalSeconds))秒严重扣15；持续\(Int(sustainedThermalSeconds))秒临界扣25"
        case .battery:
            return "电池健康只作状态提示，不参与总分；无电池或健康数据缺失不扣分。"
        }
    }
}

public enum DeviceHealthInputState: String, Codable, Equatable, Sendable {
    case available, missing, permissionDenied, failed, cancelled
}

/// A source must explicitly provide absence or failure. A nil value never means healthy.
public struct DeviceHealthReading<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var state: DeviceHealthInputState
    public var value: Value?
    public var sampledAt: Date?
    public var source: String
    public var detail: String?

    public init(value: Value, sampledAt: Date, source: String) {
        state = .available; self.value = value; self.sampledAt = sampledAt; self.source = source
    }
    public init(unavailable state: DeviceHealthInputState = .missing, source: String, detail: String? = nil) {
        self.state = state == .available ? .missing : state
        value = nil; sampledAt = nil; self.source = source; self.detail = detail
    }
}

public struct DeviceHealthMemoryReading: Codable, Equatable, Sendable {
    public var pressure: DevicePressure
    /// Continuous duration at this pressure, with sampling gaps excluded by the source.
    public var sustainedSeconds: TimeInterval
    public var swapUsedBytes: UInt64?
    public init(pressure: DevicePressure, sustainedSeconds: TimeInterval, swapUsedBytes: UInt64? = nil) {
        self.pressure = pressure; self.sustainedSeconds = sustainedSeconds; self.swapUsedBytes = swapUsedBytes
    }
}

public struct DeviceHealthStorageReading: Codable, Equatable, Sendable {
    public var totalBytes: UInt64
    public var availableBytes: UInt64
    public var volumeName: String
    public init(totalBytes: UInt64, availableBytes: UInt64, volumeName: String) {
        self.totalBytes = totalBytes; self.availableBytes = availableBytes; self.volumeName = volumeName
    }
}

public struct DeviceHealthThermalReading: Codable, Equatable, Sendable {
    public var state: DeviceThermalState
    public var sustainedSeconds: TimeInterval
    public init(state: DeviceThermalState, sustainedSeconds: TimeInterval) {
        self.state = state; self.sustainedSeconds = sustainedSeconds
    }
}

public enum DeviceHealthBatteryCondition: String, Codable, Equatable, Sendable {
    case normal, serviceRecommended, unavailable
}

public struct DeviceHealthSnapshot: Codable, Equatable, Sendable {
    public var memory: DeviceHealthReading<DeviceHealthMemoryReading>
    public var storage: DeviceHealthReading<DeviceHealthStorageReading>
    public var thermal: DeviceHealthReading<DeviceHealthThermalReading>
    public var battery: DeviceHealthReading<DeviceHealthBatteryCondition>
    public init(memory: DeviceHealthReading<DeviceHealthMemoryReading>, storage: DeviceHealthReading<DeviceHealthStorageReading>,
                thermal: DeviceHealthReading<DeviceHealthThermalReading>,
                battery: DeviceHealthReading<DeviceHealthBatteryCondition> = .init(unavailable: .missing, source: "电池来源")) {
        self.memory = memory; self.storage = storage; self.thermal = thermal; self.battery = battery
    }
}

public enum DeviceHealthFactor: String, Codable, CaseIterable, Equatable, Sendable {
    case storage, memory, thermal, battery
    public var isRequiredForScore: Bool { self != .battery }
    public var title: String {
        switch self { case .storage: "存储空间"; case .memory: "内存压力"; case .thermal: "系统热状态"; case .battery: "电池健康" }
    }
    /// Fixed weights are never redistributed when a source is absent.
    public var maximumDeduction: Int {
        switch self { case .storage: 40; case .memory: 35; case .thermal: 25; case .battery: 0 }
    }
}

public enum DeviceHealthCheckState: String, Codable, Equatable, Sendable {
    case evaluated, observing, missing, permissionDenied, stale, cancelled, failed
}
public enum DeviceHealthSeverity: String, Codable, Equatable, Sendable { case good, watch, urgent, unknown }
public enum DeviceHealthStage: String, Codable, Equatable, Sendable { case ready, checking, report, cancelled, failed }

public struct DeviceHealthEvidence: Codable, Equatable, Sendable {
    public var key: String
    public var value: String
    public init(_ key: String, _ value: String) { self.key = key; self.value = value }
}

public struct DeviceHealthFactorResult: Identifiable, Codable, Equatable, Sendable {
    public var id: DeviceHealthFactor { factor }
    public var factor: DeviceHealthFactor
    public var state: DeviceHealthCheckState
    public var severity: DeviceHealthSeverity
    public var source: String
    public var sampledAt: Date?
    public var summary: String
    public var explanation: String
    /// Nil means not evaluated, not a zero deduction or an implicit pass.
    public var deduction: Int?
    public var evidence: [DeviceHealthEvidence]
    public var suggestedRoute: String
}

public struct DeviceHealthReport: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var ruleVersion: String
    public var startedAt: Date
    public var finishedAt: Date
    public var stage: DeviceHealthStage
    public var factors: [DeviceHealthFactorResult]
    public var score: Int?
    public var evaluatedRequiredCount: Int { factors.filter { $0.factor.isRequiredForScore && $0.state == .evaluated }.count }
    public var requiredCount: Int { DeviceHealthFactor.allCases.filter(\.isRequiredForScore).count }
    public var evaluatedCount: Int { factors.filter { $0.state == .evaluated }.count }
    public var severity: DeviceHealthSeverity {
        guard let score else { return .unknown }
        return score >= 90 ? .good : score >= 75 ? .watch : .urgent
    }
    public var summary: String {
        guard stage == .report else { return stage == .cancelled ? "体检已取消" : "体检未完成" }
        guard let score else { return "信息不足，暂不打分" }
        return score >= 90 ? "整体状态良好" : score >= 75 ? "有需要留意的状态" : "建议优先复核设备状态"
    }
    public func isCurrent(at date: Date, maximumAge: TimeInterval = 300) -> Bool {
        let age = date.timeIntervalSince(finishedAt)
        return stage == .report && age.isFinite && maximumAge.isFinite && maximumAge >= 0 && age >= 0 && age <= maximumAge
    }
    /// Validate persisted summaries before displaying their score as a current assessment.
    public func validated() throws -> Self {
        guard ruleVersion == DeviceHealthRules.version, Self.validDate(startedAt), Self.validDate(finishedAt),
              finishedAt >= startedAt, factors.count == DeviceHealthFactor.allCases.count,
              Set(factors.map(\.factor)).count == factors.count else { throw DeviceHealthPersistenceError.invalidReport }
        for item in factors {
            guard item.sampledAt.map(Self.validDate) ?? true,
                  item.state == .evaluated ? item.deduction != nil : item.deduction == nil,
                  item.deduction.map({ (0...item.factor.maximumDeduction).contains($0) }) ?? true else { throw DeviceHealthPersistenceError.invalidReport }
        }
        let expected: Int? = stage == .report && evaluatedRequiredCount == requiredCount
            ? 100 - factors.filter { $0.factor.isRequiredForScore }.compactMap(\.deduction).reduce(0, +) : nil
        guard score == expected else { throw DeviceHealthPersistenceError.invalidReport }
        return self
    }
    private static func validDate(_ value: Date) -> Bool { value.timeIntervalSince1970.isFinite && abs(value.timeIntervalSince1970) < 100_000_000_000 }
}

public enum DeviceHealthPersistenceError: LocalizedError {
    case invalidReport
    public var errorDescription: String? { "体检记录的规则版本、覆盖范围或结果不一致。" }
}

/// Codable history is deliberately independent of the filesystem and the UI.
public struct DeviceHealthHistory: Codable, Equatable, Sendable {
    public private(set) var reports: [DeviceHealthReport]
    public init() { reports = [] }
    public mutating func append(_ report: DeviceHealthReport) throws {
        let checked = try report.validated()
        reports.removeAll { $0.id == checked.id }; reports.append(checked)
        reports.sort { $0.finishedAt > $1.finishedAt }
        reports = Array(reports.prefix(30))
    }
    public func validated() throws -> Self {
        guard reports.count <= 30, Set(reports.map(\.id)).count == reports.count else { throw DeviceHealthPersistenceError.invalidReport }
        for item in reports { _ = try item.validated() }
        return self
    }
}

public enum DeviceHealthAssessor {
    /// Each progress callback represents a completed rule evaluation, not an animation timer.
    public static func evaluate(_ snapshot: DeviceHealthSnapshot, at now: Date = Date(), id: UUID = UUID(),
                                isCancelled: () -> Bool = { false },
                                progress: (DeviceHealthFactorResult) -> Void = { _ in }) -> DeviceHealthReport {
        var results: [DeviceHealthFactorResult] = []
        var cancelled = false
        for factor in DeviceHealthFactor.allCases {
            cancelled = cancelled || isCancelled()
            let result: DeviceHealthFactorResult
            if cancelled {
                result = unavailable(factor, state: .cancelled, source: source(factor, snapshot), sampledAt: nil, detail: "本次检查已取消")
            } else {
                switch factor {
                case .storage: result = storage(snapshot.storage, now: now)
                case .memory: result = memory(snapshot.memory, now: now)
                case .thermal: result = thermal(snapshot.thermal, now: now)
                case .battery: result = battery(snapshot.battery, now: now)
                }
            }
            results.append(result); progress(result)
        }
        cancelled = cancelled || isCancelled()
        let enough = results.filter { $0.factor.isRequiredForScore && $0.state == .evaluated }.count == 3
        let score = !cancelled && enough ? 100 - results.filter { $0.factor.isRequiredForScore }.compactMap(\.deduction).reduce(0, +) : nil
        return .init(id: id, ruleVersion: DeviceHealthRules.version, startedAt: now, finishedAt: now,
                     stage: cancelled ? .cancelled : .report, factors: results, score: score)
    }

    private static func source(_ factor: DeviceHealthFactor, _ input: DeviceHealthSnapshot) -> String {
        switch factor { case .storage: input.storage.source; case .memory: input.memory.source; case .thermal: input.thermal.source; case .battery: input.battery.source }
    }
    private static func route(_ factor: DeviceHealthFactor) -> String {
        switch factor { case .storage: "device/storage"; case .memory: "device/memory"; case .thermal, .battery: "device/thermal" }
    }
    private static func unavailable(_ factor: DeviceHealthFactor, state: DeviceHealthCheckState, source: String, sampledAt: Date?, detail: String) -> DeviceHealthFactorResult {
        let summary: String
        switch state {
        case .missing: summary = "尚未读取"
        case .permissionDenied: summary = "未获授权"
        case .stale: summary = "读数已过期"
        case .cancelled: summary = "已取消"
        case .observing: summary = "继续观察"
        case .failed: summary = "读取失败"
        case .evaluated: summary = "尚未评价"
        }
        return .init(factor: factor, state: state, severity: .unknown, source: source, sampledAt: sampledAt,
                     summary: summary, explanation: detail, deduction: nil, evidence: [], suggestedRoute: route(factor))
    }
    private static func checked<T>(_ input: DeviceHealthReading<T>, factor: DeviceHealthFactor, now: Date) -> DeviceHealthFactorResult? {
        guard input.state == .available else {
            let state: DeviceHealthCheckState
            switch input.state { case .missing, .available: state = .missing; case .permissionDenied: state = .permissionDenied; case .failed: state = .failed; case .cancelled: state = .cancelled }
            return unavailable(factor, state: state, source: input.source, sampledAt: input.sampledAt, detail: input.detail ?? "来源未提供可评价的数据，不计入评分。")
        }
        guard input.value != nil, let sampled = input.sampledAt, !input.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              now.timeIntervalSince1970.isFinite, sampled.timeIntervalSince1970.isFinite else {
            return unavailable(factor, state: .failed, source: input.source, sampledAt: input.sampledAt, detail: "来源、时间或读数无效，不计入评分。")
        }
        let age = now.timeIntervalSince(sampled)
        if age < -DeviceHealthRules.futureClockTolerance {
            return unavailable(factor, state: .failed, source: input.source, sampledAt: sampled, detail: "采样时间晚于本次检查，需核对时钟。")
        }
        if age > DeviceHealthRules.maximumSampleAge {
            return unavailable(factor, state: .stale, source: input.source, sampledAt: sampled, detail: "读数超过 60 秒有效期，等待新采样。")
        }
        return nil
    }
    private static func result<T>(_ factor: DeviceHealthFactor, input: DeviceHealthReading<T>, severity: DeviceHealthSeverity,
                                  deduction: Int, summary: String, explanation: String, evidence: [DeviceHealthEvidence]) -> DeviceHealthFactorResult {
        .init(factor: factor, state: .evaluated, severity: severity, source: input.source, sampledAt: input.sampledAt,
              summary: summary, explanation: explanation, deduction: deduction, evidence: evidence, suggestedRoute: route(factor))
    }
    private static func storage(_ input: DeviceHealthReading<DeviceHealthStorageReading>, now: Date) -> DeviceHealthFactorResult {
        if let issue = checked(input, factor: .storage, now: now) { return issue }
        let value = input.value!
        guard value.totalBytes > 0, value.availableBytes <= value.totalBytes else {
            return unavailable(.storage, state: .failed, source: input.source, sampledAt: input.sampledAt, detail: "可用空间与总容量不一致，不计入评分。")
        }
        let fraction = Double(value.availableBytes) / Double(value.totalBytes)
        let urgent = fraction < DeviceHealthRules.storageCriticalFraction || value.availableBytes < DeviceHealthRules.storageCriticalBytes
        let watch = fraction < DeviceHealthRules.storageWarningFraction || value.availableBytes < DeviceHealthRules.storageWarningBytes
        return result(.storage, input: input, severity: urgent ? .urgent : watch ? .watch : .good,
                      deduction: urgent ? 40 : watch ? 16 : 0,
                      summary: urgent ? "存储余量较少" : watch ? "留意存储增长" : "存储余量充足",
                      explanation: "按可用空间占比与绝对余量判断；扫描到多少缓存不参与评分。",
                      evidence: [.init("volume", value.volumeName), .init("totalBytes", String(value.totalBytes)),
                                 .init("availableBytes", String(value.availableBytes)), .init("availableFraction", String(fraction)),
                                 .init("rule", DeviceHealthRules.explanation(for: .storage))])
    }
    private static func memory(_ input: DeviceHealthReading<DeviceHealthMemoryReading>, now: Date) -> DeviceHealthFactorResult {
        if let issue = checked(input, factor: .memory, now: now) { return issue }
        let value = input.value!
        guard value.pressure != .unknown else { return unavailable(.memory, state: .missing, source: input.source, sampledAt: input.sampledAt, detail: "系统未提供内存压力；不从内存使用比例推断。") }
        guard validDuration(value.sustainedSeconds) else { return unavailable(.memory, state: .failed, source: input.source, sampledAt: input.sampledAt, detail: "连续观测时长无效。") }
        if value.pressure != .normal && value.sustainedSeconds < DeviceHealthRules.sustainedPressureSeconds {
            var item = unavailable(.memory, state: .observing, source: input.source, sampledAt: input.sampledAt, detail: "压力刚刚升高，需连续观察满 60 秒；当前不据短峰扣分。")
            item.evidence = [.init("pressure", value.pressure.rawValue), .init("sustainedSeconds", String(value.sustainedSeconds))]
            return item
        }
        var evidence = [DeviceHealthEvidence("pressure", value.pressure.rawValue), .init("sustainedSeconds", String(value.sustainedSeconds)),
                        .init("rule", DeviceHealthRules.explanation(for: .memory))]
        if let swap = value.swapUsedBytes { evidence.append(.init("swapUsedBytes", String(swap))) }
        return result(.memory, input: input, severity: value.pressure == .normal ? .good : value.pressure == .warning ? .watch : .urgent,
                      deduction: value.pressure == .normal ? 0 : value.pressure == .warning ? 14 : 35,
                      summary: value.pressure == .normal ? "内存压力正常" : "内存压力持续偏高",
                      explanation: "依据系统压力及连续观测时长。高占用与交换量本身不直接扣分；无需为了缓存主动退出应用。", evidence: evidence)
    }
    private static func thermal(_ input: DeviceHealthReading<DeviceHealthThermalReading>, now: Date) -> DeviceHealthFactorResult {
        if let issue = checked(input, factor: .thermal, now: now) { return issue }
        let value = input.value!
        guard value.state != .unknown else { return unavailable(.thermal, state: .missing, source: input.source, sampledAt: input.sampledAt, detail: "系统热状态不可用；传感器缺失不代表过热或正常。") }
        guard validDuration(value.sustainedSeconds) else { return unavailable(.thermal, state: .failed, source: input.source, sampledAt: input.sampledAt, detail: "连续观测时长无效。") }
        let high = value.state == .serious || value.state == .critical
        if high && value.sustainedSeconds < DeviceHealthRules.sustainedThermalSeconds {
            var item = unavailable(.thermal, state: .observing, source: input.source, sampledAt: input.sampledAt, detail: "热状态刚刚升高，需连续观察满 60 秒；当前不据短峰扣分。")
            item.evidence = [.init("thermalState", value.state.rawValue), .init("sustainedSeconds", String(value.sustainedSeconds))]
            return item
        }
        return result(.thermal, input: input, severity: value.state == .critical ? .urgent : high || value.state == .fair ? .watch : .good,
                      deduction: value.state == .critical ? 25 : value.state == .serious ? 15 : 0,
                      summary: high ? "系统热压力持续偏高" : value.state == .fair ? "系统热状态略高" : "系统热状态正常",
                      explanation: "依据 macOS 热状态及连续观测时长，不以单个 CPU/GPU 温度值断言硬件健康。",
                      evidence: [.init("thermalState", value.state.rawValue), .init("sustainedSeconds", String(value.sustainedSeconds)),
                                 .init("rule", DeviceHealthRules.explanation(for: .thermal))])
    }
    private static func battery(_ input: DeviceHealthReading<DeviceHealthBatteryCondition>, now: Date) -> DeviceHealthFactorResult {
        if let issue = checked(input, factor: .battery, now: now) { return issue }
        guard input.value != .unavailable else { return unavailable(.battery, state: .missing, source: input.source, sampledAt: input.sampledAt, detail: "来源未提供电池健康；台式设备也可能没有电池。") }
        let service = input.value == .serviceRecommended
        return result(.battery, input: input, severity: service ? .watch : .good, deduction: 0,
                      summary: service ? "系统建议检修电池" : "系统电池状态正常", explanation: "电池作为独立提示，不纳入本版设备状态评分。",
                      evidence: [.init("condition", input.value!.rawValue), .init("rule", DeviceHealthRules.explanation(for: .battery))])
    }
    private static func validDuration(_ value: TimeInterval) -> Bool { value.isFinite && value >= 0 && value <= 31_536_000 }
}

/// Tracks an actual uninterrupted state. Gaps and backwards clocks reset duration.
/// The adapter maps its unknown state to nil, which also resets continuity.
public struct DeviceHealthContinuity<Value: Equatable & Sendable>: Sendable {
    public private(set) var value: Value?
    public private(set) var startedAt: Date?
    public private(set) var sampledAt: Date?
    public init() {}
    @discardableResult public mutating func ingest(_ value: Value?, at date: Date, maximumGap: TimeInterval) -> TimeInterval {
        guard date.timeIntervalSince1970.isFinite, maximumGap.isFinite, maximumGap > 0, let value else { reset(); return 0 }
        let gap = sampledAt.map { date.timeIntervalSince($0) }
        if self.value != value || gap == nil || gap! <= 0 || gap! > maximumGap { startedAt = date }
        self.value = value; sampledAt = date
        return max(0, date.timeIntervalSince(startedAt ?? date))
    }
    public mutating func reset() { value = nil; startedAt = nil; sampledAt = nil }
}
