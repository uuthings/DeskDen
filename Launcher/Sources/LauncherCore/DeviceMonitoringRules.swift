import Foundation

public enum DeviceTrafficScope: String, Codable, CaseIterable, Sendable {
    case all, wifi, ethernet
    public var title: String { switch self { case .all: "全部网络"; case .wifi: "Wi-Fi"; case .ethernet: "有线网络" } }
}
public enum DeviceBudgetPeriod: String, Codable, CaseIterable, Sendable {
    case day, week, month, quarter, year, custom
    public var title: String {
        switch self { case .day: "每日"; case .week: "每周"; case .month: "每月"; case .quarter: "每季"; case .year: "每年"; case .custom: "自定义日期" }
    }
    public var supportsAnchor: Bool { self == .month || self == .quarter || self == .year }
    public func interval(at date: Date, calendar: Calendar) -> DateInterval {
        let component: Calendar.Component = switch self {
        case .day, .custom: .day; case .week: .weekOfYear; case .month: .month; case .quarter: .quarter; case .year: .year
        }
        return calendar.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 0)
    }
}

/// A civil date, independent of the machine's current timezone. Budget boundaries are resolved
/// in the ledger's fixed recording timezone, including 23/25-hour DST days.
public struct DeviceBudgetDate: Codable, Equatable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 2001, month: c.month ?? 1, day: c.day ?? 1)
    }
    public func date(in calendar: Calendar) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let result = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              DeviceBudgetDate(result, calendar: calendar) == self else { return nil }
        return calendar.startOfDay(for: result)
    }
    fileprivate var key: String { "\(year)-\(month)-\(day)" }
}

public enum DeviceMonitoringValidationError: LocalizedError {
    case invalidBudget, invalidWarning, invalidTemperature, invalidDuration, invalidCooldown, invalidCycleDates
    public var errorDescription: String? {
        switch self {
        case .invalidBudget: "流量额度必须为 0.01–100000 GB 的有效数字。"
        case .invalidWarning: "提示阈值必须介于 1% 与 99%。"
        case .invalidTemperature: "CPU 和 GPU 温度阈值必须介于 40°C 与 110°C。"
        case .invalidDuration: "持续时间必须介于 5 秒与 3600 秒。"
        case .invalidCooldown: "提醒冷却时间必须介于 1 分钟与 1440 分钟。"
        case .invalidCycleDates: "请选择有效日期；自定义结束日期不能早于开始日期。"
        }
    }
}
public struct DeviceTrafficBudget: Codable, Equatable, Sendable {
    public var enabled = false
    public var period: DeviceBudgetPeriod = .month
    public var scope: DeviceTrafficScope = .all
    public var limitGB: Double = 100
    public var warningPercent: Int = 80
    public var notificationsEnabled = false
    /// nil preserves the original calendar-aligned day/week/month behavior.
    public var cycleAnchor: DeviceBudgetDate?
    public var customStart: DeviceBudgetDate?
    public var customEndInclusive: DeviceBudgetDate?
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case enabled, period, scope, limitGB, warningPercent, notificationsEnabled, cycleAnchor, customStart, customEndInclusive
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        period = try c.decode(DeviceBudgetPeriod.self, forKey: .period)
        scope = try c.decode(DeviceTrafficScope.self, forKey: .scope)
        limitGB = try c.decode(Double.self, forKey: .limitGB)
        warningPercent = try c.decode(Int.self, forKey: .warningPercent)
        notificationsEnabled = try c.decode(Bool.self, forKey: .notificationsEnabled)
        cycleAnchor = try c.decodeIfPresent(DeviceBudgetDate.self, forKey: .cycleAnchor)
        customStart = try c.decodeIfPresent(DeviceBudgetDate.self, forKey: .customStart)
        customEndInclusive = try c.decodeIfPresent(DeviceBudgetDate.self, forKey: .customEndInclusive)
    }
    /// Decimal GB matches the budget editor and network-provider convention.
    public var limitBytes: UInt64 { limitGB.isFinite && limitGB > 0 ? UInt64(min(limitGB * 1_000_000_000, Double(UInt64.max / 2))) : 0 }
    public func validated() throws -> Self {
        guard limitGB.isFinite, (0.01...100_000).contains(limitGB) else { throw DeviceMonitoringValidationError.invalidBudget }
        guard (1...99).contains(warningPercent) else { throw DeviceMonitoringValidationError.invalidWarning }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        if let cycleAnchor, cycleAnchor.date(in: calendar) == nil { throw DeviceMonitoringValidationError.invalidCycleDates }
        if let customStart, customStart.date(in: calendar) == nil { throw DeviceMonitoringValidationError.invalidCycleDates }
        if let customEndInclusive, customEndInclusive.date(in: calendar) == nil { throw DeviceMonitoringValidationError.invalidCycleDates }
        if period == .custom {
            guard let start = customStart?.date(in: calendar), let end = customEndInclusive?.date(in: calendar), end >= start,
                  calendar.date(byAdding: .day, value: 1, to: end) != nil else { throw DeviceMonitoringValidationError.invalidCycleDates }
        }
        return self
    }
    /// All accounting is half-open: [start, end). A date chosen as the custom ending day
    /// is included in full; its next local midnight is the exclusive boundary.
    public func interval(at date: Date, calendar: Calendar) -> DateInterval {
        if period == .custom {
            guard let start = customStart?.date(in: calendar), let last = customEndInclusive?.date(in: calendar), last >= start,
                  let end = calendar.date(byAdding: .day, value: 1, to: last) else { return .init(start: date, duration: 0) }
            return .init(start: start, end: end)
        }
        guard period.supportsAnchor, let anchor = cycleAnchor, let anchorDate = anchor.date(in: calendar),
              let anchorMonth = calendar.dateInterval(of: .month, for: anchorDate)?.start,
              let targetMonth = calendar.dateInterval(of: .month, for: date)?.start else { return period.interval(at: date, calendar: calendar) }
        let span = period == .month ? 1 : period == .quarter ? 3 : 12
        let months = calendar.dateComponents([.month], from: anchorMonth, to: targetMonth).month ?? 0
        var offset = Int(floor(Double(months) / Double(span))) * span
        func boundary(_ offset: Int) -> Date? {
            guard let month = calendar.date(byAdding: .month, value: offset, to: anchorMonth),
                  let days = calendar.range(of: .day, in: .month, for: month) else { return nil }
            return calendar.date(byAdding: .day, value: min(anchor.day, days.count) - 1, to: month)
        }
        guard var start = boundary(offset) else { return period.interval(at: date, calendar: calendar) }
        if start > date { offset -= span; guard let prior = boundary(offset) else { return .init(start: date, duration: 0) }; start = prior }
        guard let end = boundary(offset + span), end > start else { return .init(start: date, duration: 0) }
        return .init(start: start, end: end)
    }
    public var identity: String {
        let base = "\(period.rawValue):\(scope.rawValue):\(limitBytes):\(warningPercent)"
        if period == .custom { return "\(base):\(customStart?.key ?? ""):\(customEndInclusive?.key ?? "")" }
        if period.supportsAnchor, let cycleAnchor { return "\(base):\(cycleAnchor.key)" }
        // Preserve old cycle identities so upgrading does not resend acknowledged notifications.
        return base
    }
}
public struct DeviceTemperatureRule: Codable, Equatable, Sendable {
    public var enabled = false
    public var cpuThreshold: Double = 85
    public var gpuThreshold: Double = 80
    public var sustainedSeconds: Int = 30
    public var cooldownMinutes: Int = 15
    public var notificationsEnabled = false
    public init() {}
    public func validated() throws -> Self {
        guard cpuThreshold.isFinite, gpuThreshold.isFinite, (40...110).contains(cpuThreshold), (40...110).contains(gpuThreshold) else { throw DeviceMonitoringValidationError.invalidTemperature }
        guard (5...3600).contains(sustainedSeconds) else { throw DeviceMonitoringValidationError.invalidDuration }
        guard (1...1440).contains(cooldownMinutes) else { throw DeviceMonitoringValidationError.invalidCooldown }
        return self
    }
}
public struct DeviceTrafficDay: Identifiable, Equatable, Sendable {
    public var id: Date { date }
    public var date: Date
    public var received: UInt64
    public var sent: UInt64
    public var coveredSeconds: TimeInterval
    public var excludedIntervals: Int
    public var totalBytes: UInt64 { saturatedAdd(received, sent) }
}
public struct DeviceTrafficSummary: Equatable, Sendable {
    public var period: DeviceBudgetPeriod
    public var scope: DeviceTrafficScope
    public var periodStart: Date
    public var periodEnd: Date
    public var recordingStartedAt: Date
    public var timeZoneIdentifier: String
    public var measuredAt: Date
    public var received: UInt64
    public var sent: UInt64
    public var coveredSeconds: TimeInterval
    public var excludedIntervals: Int
    public var dailyUsage: [DeviceTrafficDay]
    public var totalBytes: UInt64 { saturatedAdd(received, sent) }
    public var isPartialPeriod: Bool {
        let elapsedEnd = min(measuredAt, periodEnd)
        return elapsedEnd > periodStart && (recordingStartedAt > periodStart || excludedIntervals > 0 ||
            coveredSeconds + 15 < max(0, elapsedEnd.timeIntervalSince(max(periodStart, recordingStartedAt))))
    }
    public var isActivePeriod: Bool { measuredAt >= periodStart && measuredAt < periodEnd }
    public var hasStarted: Bool { measuredAt >= periodStart }
}

/// Scope ledgers are collected concurrently. Switching the budget scope never relabels historical bytes.
/// Timezone is fixed when recording starts so travel cannot move recorded traffic into a different day.
public struct DeviceTrafficLedger: Codable, Equatable, Sendable {
    public var timeZoneIdentifier: String
    public var startedAt: Date
    public var scopes: [DeviceTrafficScope: DeviceNetworkLedger]
    public init(now: Date = Date(), timeZone: TimeZone = .current) {
        startedAt = now; timeZoneIdentifier = timeZone.identifier
        scopes = Dictionary(uniqueKeysWithValues: DeviceTrafficScope.allCases.map { ($0, DeviceNetworkLedger(now: now)) })
    }
    public func validated() throws -> Self {
        guard TimeZone(identifier: timeZoneIdentifier) != nil, startedAt.timeIntervalSince1970.isFinite,
              abs(startedAt.timeIntervalSince1970) <= 100_000_000_000,
              Set(scopes.keys) == Set(DeviceTrafficScope.allCases) else { throw DeviceNetworkLedgerError.invalidFields }
        for ledger in scopes.values { _ = try ledger.validated() }
        return self
    }
    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c
    }
    public func summary(period: DeviceBudgetPeriod, scope: DeviceTrafficScope, at date: Date) -> DeviceTrafficSummary {
        var budget = DeviceTrafficBudget(); budget.period = period; budget.scope = scope
        return summary(budget: budget, at: date)
    }
    public func summary(budget: DeviceTrafficBudget, at date: Date) -> DeviceTrafficSummary {
        let c = calendar, range = budget.interval(at: date, calendar: c), ledger = scopes[budget.scope] ?? .init(now: startedAt)
        let elapsedEnd = min(date, range.end)
        // Total every retained measured bucket inside the selected interval. A long custom range
        // must not fabricate history or silently exclude older retained days from its total.
        let included = ledger.days.filter { key, _ in
            let pieces = key.split(separator: "-").compactMap { Int($0) }
            guard pieces.count == 3, let day = DeviceBudgetDate(year: pieces[0], month: pieces[1], day: pieces[2]).date(in: c) else { return false }
            return day >= range.start && day < range.end && day <= date
        }.map(\.value)
        // Bound chart size independently of accounting. Histories longer than 400 calendar days
        // show the latest 400 days; omitted/missing collection remains explicit in the UI.
        let lastDay = c.startOfDay(for: min(date, range.end.addingTimeInterval(-0.001)))
        let chartStart = max(range.start, c.date(byAdding: .day, value: -399, to: lastDay) ?? range.start)
        var days: [DeviceTrafficDay] = [], cursor = chartStart
        while cursor < range.end && cursor <= elapsedEnd && days.count < 400 {
            let d = ledger.today(at: cursor, calendar: c)
            days.append(.init(date: cursor, received: d.received, sent: d.sent, coveredSeconds: d.coveredSeconds, excludedIntervals: d.excludedIntervals))
            guard let next = c.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }; cursor = next
        }
        return .init(period: budget.period, scope: budget.scope, periodStart: range.start, periodEnd: range.end, recordingStartedAt: startedAt,
                     timeZoneIdentifier: timeZoneIdentifier, measuredAt: date, received: included.reduce(0) { saturatedAdd($0, $1.received) },
                     sent: included.reduce(0) { saturatedAdd($0, $1.sent) }, coveredSeconds: included.reduce(0) { min(1_000_000_000_000, $0 + ($1.coveredSeconds.isFinite ? max(0, $1.coveredSeconds) : 0)) },
                     excludedIntervals: included.reduce(0) { saturatedCount($0, $1.excludedIntervals) }, dailyUsage: days)
    }
}
public struct DeviceTrafficAccumulator: Sendable {
    public private(set) var ledger: DeviceTrafficLedger
    private var accumulators: [DeviceTrafficScope: DeviceNetworkAccumulator]
    public init(ledger: DeviceTrafficLedger = .init()) {
        self.ledger = ledger
        accumulators = Dictionary(uniqueKeysWithValues: DeviceTrafficScope.allCases.map {
            ($0, DeviceNetworkAccumulator(ledger: ledger.scopes[$0] ?? .init(now: ledger.startedAt)))
        })
    }
    public mutating func breakContinuity() { for scope in DeviceTrafficScope.allCases { accumulators[scope]?.breakContinuity() } }
    public mutating func ingest(wifi: [String: DeviceNetworkCounter], ethernet: [String: DeviceNetworkCounter], at date: Date, maximumGap: TimeInterval) {
        let all = wifi.merging(ethernet) { first, _ in first }
        for scope in DeviceTrafficScope.allCases {
            let counters = switch scope { case .all: all; case .wifi: wifi; case .ethernet: ethernet }
            _ = accumulators[scope]?.ingest(counters, at: date, maximumGap: maximumGap, calendar: ledger.calendar)
            ledger.scopes[scope] = accumulators[scope]?.ledger
        }
    }
}

public enum DeviceMonitoringEvent: Equatable, Sendable {
    case budgetWarning(percent: Int), budgetExceeded, temperature(sensor: String, value: Double)
}
public struct DeviceMonitoringState: Codable, Equatable, Sendable {
    public var budgetCycle: String?
    public var budgetWarningSent = false
    public var budgetExceededSent = false
    public var cpu = DeviceTemperatureAlertState()
    public var gpu = DeviceTemperatureAlertState()
    public init() {}
}
public struct DeviceTemperatureAlertState: Codable, Equatable, Sendable {
    public var lastNotifiedAt: Date?
    public var awaitingRecovery = false
    public init() {}
}
/// Deterministic alert evaluation. The caller commits the resulting state only after successful delivery.
public struct DeviceMonitoringEvaluator: Sendable {
    public var state: DeviceMonitoringState
    private var cpuSince: Date?
    private var gpuSince: Date?
    private var previous: Date?
    public init(state: DeviceMonitoringState = .init()) { self.state = state }
    public mutating func breakContinuity() { cpuSince = nil; gpuSince = nil; previous = nil }
    public mutating func resetTemperatureRule() { breakContinuity(); state.cpu.awaitingRecovery = false; state.gpu.awaitingRecovery = false }
    public mutating func evaluateBudget(_ budget: DeviceTrafficBudget, summary: DeviceTrafficSummary) -> [DeviceMonitoringEvent] {
        guard budget.enabled, budget.notificationsEnabled, budget.limitBytes > 0, summary.scope == budget.scope, summary.period == budget.period,
              summary.isActivePeriod else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: summary.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        let expected = budget.interval(at: summary.measuredAt, calendar: calendar)
        guard expected.start == summary.periodStart, expected.end == summary.periodEnd else { return [] }
        let cycle = "\(budget.identity):\(summary.periodStart.timeIntervalSince1970)"
        if state.budgetCycle != cycle { state.budgetCycle = cycle; state.budgetWarningSent = false; state.budgetExceededSent = false }
        let ratio = Double(summary.totalBytes) / Double(budget.limitBytes) * 100
        if ratio >= 100, !state.budgetExceededSent {
            state.budgetWarningSent = true; state.budgetExceededSent = true; return [.budgetExceeded]
        }
        if ratio >= Double(budget.warningPercent), !state.budgetWarningSent {
            state.budgetWarningSent = true; return [.budgetWarning(percent: budget.warningPercent)]
        }
        return []
    }
    public mutating func evaluateTemperature(_ rule: DeviceTemperatureRule, cpu: Double?, gpu: Double?, at date: Date, maximumGap: TimeInterval) -> [DeviceMonitoringEvent] {
        guard rule.enabled, rule.notificationsEnabled else { breakContinuity(); return [] }
        if let previous, date <= previous || date.timeIntervalSince(previous) > maximumGap { cpuSince = nil; gpuSince = nil }
        previous = date
        var events: [DeviceMonitoringEvent] = []
        if let event = Self.temperature(sensor: "CPU", value: cpu, threshold: rule.cpuThreshold, rule: rule, at: date, since: &cpuSince, state: &state.cpu) { events.append(event) }
        if let event = Self.temperature(sensor: "GPU", value: gpu, threshold: rule.gpuThreshold, rule: rule, at: date, since: &gpuSince, state: &state.gpu) { events.append(event) }
        return events
    }
    private static func temperature(sensor: String, value: Double?, threshold: Double, rule: DeviceTemperatureRule, at date: Date, since: inout Date?, state: inout DeviceTemperatureAlertState) -> DeviceMonitoringEvent? {
        guard let value, value.isFinite, value > 0, value <= 150 else { since = nil; return nil }
        guard value >= threshold else { since = nil; state.awaitingRecovery = false; return nil }
        guard !state.awaitingRecovery else { since = nil; return nil }
        since = since ?? date
        guard date.timeIntervalSince(since!) >= Double(rule.sustainedSeconds) else { return nil }
        if let last = state.lastNotifiedAt, date.timeIntervalSince(last) < Double(rule.cooldownMinutes * 60) { return nil }
        state.lastNotifiedAt = date; state.awaitingRecovery = true; since = nil
        return .temperature(sensor: sensor, value: value)
    }
}
private func saturatedAdd(_ a: UInt64, _ b: UInt64) -> UInt64 { let r = a.addingReportingOverflow(b); return r.overflow ? .max : r.partialValue }

private func saturatedCount(_ a: Int, _ b: Int) -> Int { let r = max(0, a).addingReportingOverflow(max(0, b)); return r.overflow ? .max : r.partialValue }
