import Foundation

public enum DevicePressure: String, Codable, Sendable { case normal, warning, critical, unknown }
public enum DeviceThermalState: String, Codable, Sendable { case nominal, fair, serious, critical, unknown }

public enum DeviceBatteryCycleCount {
    /// IOPMPowerSource publishes CycleCount as an unsigned 32-bit CFNumber.
    /// A missing source/property must remain distinct from a measured zero.
    public static func resolve(internalBatteryCount: Int, installedCycleCounts: [Any?]) -> Int? {
        guard internalBatteryCount == 1, installedCycleCounts.count == 1,
              let number = installedCycleCounts[0] as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= Double(UInt32.max), value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
}

public enum DeviceTemperatureValidation {
    /// M2 CPU sensors can intermittently return broken low/high samples. This is the
    /// empirical range used for that hardware family by Stats' SensorsReader:
    /// https://github.com/exelban/stats/blob/master/Modules/Sensors/readers.swift
    /// Reject the sample instead of clamping it or presenting an earlier value as current.
    /// This is a sensor validity policy, not a hardware operating-temperature guarantee.
    public static func celsius(_ value: Double?, chipName: String, isCPU: Bool) -> Double? {
        guard let value, value.isFinite, value > 0, value < 130 else { return nil }
        if isCPU && chipName.contains("Apple M2") && !(10...120).contains(value) { return nil }
        return value
    }
}

public struct DeviceCPUTicks: Equatable, Sendable {
    public var user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32 = 0) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
    /// Mach host counters are unsigned 32-bit ticks; subtraction deliberately handles wrap.
    public func percentages(since previous: Self) -> (user: Double, system: Double, total: Double)? {
        let u = Double(user &- previous.user) + Double(nice &- previous.nice)
        let s = Double(system &- previous.system), i = Double(idle &- previous.idle)
        let total = u + s + i
        guard total > 0 else { return nil }
        return (u / total * 100, s / total * 100, (u + s) / total * 100)
    }
}

public struct DeviceNetworkCounter: Codable, Equatable, Sendable {
    public var received: UInt64, sent: UInt64
    public init(received: UInt64 = 0, sent: UInt64 = 0) { self.received = received; self.sent = sent }
}

public struct DeviceNetworkDay: Codable, Equatable, Sendable {
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
    public var coveredSeconds: TimeInterval = 0
    public var firstSample: Date?
    public var lastSample: Date?
    public var excludedIntervals: Int = 0
    public init() {}
}

public enum DeviceNetworkLedgerError: LocalizedError {
    case invalidFields
    public var errorDescription: String? { "网络记录包含无效的日期、覆盖时长或间隔计数。" }
}

public struct DeviceNetworkLedger: Codable, Equatable, Sendable {
    public var days: [String: DeviceNetworkDay] = [:]
    public var recordingStartedAt: Date
    public var recordingReceived: UInt64 = 0
    public var recordingSent: UInt64 = 0
    public var recordingCoveredSeconds: TimeInterval = 0
    public var selectedInterfaceIDs: [String]? // nil: physical Wi-Fi / Ethernet, []: none
    public init(now: Date = Date()) { recordingStartedAt = now }
    public func validated() throws -> Self {
        func validDate(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite && abs(date.timeIntervalSince1970) <= 100_000_000_000 }
        func validSeconds(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= 1_000_000_000_000 }
        guard validDate(recordingStartedAt), validSeconds(recordingCoveredSeconds), days.count <= 400 else { throw DeviceNetworkLedgerError.invalidFields }
        for (key, day) in days {
            guard key.count == 10, key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  validSeconds(day.coveredSeconds), (0...1_000_000_000).contains(day.excludedIntervals),
                  day.firstSample.map(validDate) ?? true, day.lastSample.map(validDate) ?? true else { throw DeviceNetworkLedgerError.invalidFields }
            let parts = key.split(separator: "-").compactMap { Int($0) }
            let calendar = Calendar(identifier: .gregorian)
            guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  Self.dayKey(date, calendar: calendar) == key else { throw DeviceNetworkLedgerError.invalidFields }
            if let first = day.firstSample, let last = day.lastSample, first > last { throw DeviceNetworkLedgerError.invalidFields }
        }
        return self
    }
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    public func today(at date: Date = Date(), calendar: Calendar = .current) -> DeviceNetworkDay {
        days[Self.dayKey(date, calendar: calendar)] ?? DeviceNetworkDay()
    }
    public mutating func beginRecording(at date: Date) {
        recordingStartedAt = date; recordingReceived = 0; recordingSent = 0; recordingCoveredSeconds = 0
    }
}

public struct DeviceNetworkDelta: Equatable, Sendable {
    public var received: UInt64, sent: UInt64, seconds: TimeInterval
    public var downloadBytesPerSecond: Double { Double(received) / seconds }
    public var uploadBytesPerSecond: Double { Double(sent) / seconds }
}

/// Credits only two consecutive valid observations of the same interface scope.
/// A restart, sleep gap, interface reset, selection change or midnight is a new baseline.
/// Midnight-straddling intervals are excluded instead of inventing a per-day distribution.
public struct DeviceNetworkAccumulator: Sendable {
    public private(set) var ledger: DeviceNetworkLedger
    private var previous: (date: Date, counters: [String: DeviceNetworkCounter])?
    public init(ledger: DeviceNetworkLedger = .init()) { self.ledger = ledger }
    public mutating func breakContinuity() { previous = nil }
    public mutating func selectInterfaces(_ ids: [String]?) {
        ledger.selectedInterfaceIDs = ids.map { Array(Set($0)).sorted() }; breakContinuity()
    }
    public mutating func beginRecording(at date: Date) { ledger.beginRecording(at: date); breakContinuity() }
    public mutating func ingest(_ counters: [String: DeviceNetworkCounter], at date: Date,
                                maximumGap: TimeInterval, calendar: Calendar = .current) -> DeviceNetworkDelta? {
        guard date.timeIntervalSince1970.isFinite, abs(date.timeIntervalSince1970) <= 100_000_000_000, maximumGap.isFinite, maximumGap > 0 else { previous = nil; return nil }
        defer {
            previous = (date, counters)
            for obsolete in ledger.days.keys.sorted().dropLast(400) { ledger.days.removeValue(forKey: obsolete) }
        }
        guard let old = previous else {
            // A decoded ledger intentionally contains no counter baseline. Record the uncovered restart
            // interval rather than silently treating the persisted totals as uninterrupted collection.
            if let last = ledger.days.values.compactMap(\.lastSample).max(), date > last {
                let key = DeviceNetworkLedger.dayKey(date, calendar: calendar)
                var day = ledger.days[key] ?? .init(); day.excludedIntervals = Self.increment(day.excludedIntervals); ledger.days[key] = day
            }
            return nil
        }
        let dt = date.timeIntervalSince(old.date), key = DeviceNetworkLedger.dayKey(date, calendar: calendar)
        let sameDay = key == DeviceNetworkLedger.dayKey(old.date, calendar: calendar)
        let valid = dt > 0 && dt <= maximumGap && sameDay && !counters.isEmpty && counters.keys.sorted() == old.counters.keys.sorted()
        guard valid else {
            if dt > 0 { var day = ledger.days[key] ?? .init(); day.excludedIntervals = Self.increment(day.excludedIntervals); ledger.days[key] = day }
            return nil
        }
        var received: UInt64 = 0, sent: UInt64 = 0
        for (name, value) in counters {
            guard let before = old.counters[name], value.received >= before.received, value.sent >= before.sent else {
                var day = ledger.days[key] ?? .init(); day.excludedIntervals = Self.increment(day.excludedIntervals); ledger.days[key] = day
                return nil
            }
            received = Self.add(received, value.received - before.received)
            sent = Self.add(sent, value.sent - before.sent)
        }
        var day = ledger.days[key] ?? .init()
        day.received = Self.add(day.received, received); day.sent = Self.add(day.sent, sent)
        day.coveredSeconds = Self.addSeconds(day.coveredSeconds, dt); day.firstSample = day.firstSample ?? old.date; day.lastSample = date
        ledger.days[key] = day
        ledger.recordingReceived = Self.add(ledger.recordingReceived, received)
        ledger.recordingSent = Self.add(ledger.recordingSent, sent); ledger.recordingCoveredSeconds = Self.addSeconds(ledger.recordingCoveredSeconds, dt)
        return .init(received: received, sent: sent, seconds: dt)
    }
    private static func increment(_ value: Int) -> Int { value < Int.max ? max(0, value) + 1 : .max }
    private static func addSeconds(_ a: Double, _ b: Double) -> Double { min(1_000_000_000_000, (a.isFinite ? max(0, a) : 0) + b) }
    private static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let result = a.addingReportingOverflow(b); return result.overflow ? .max : result.partialValue
    }
}

public enum DeviceProcessSort: String, CaseIterable, Sendable { case cpu, memory, name, pid }
public struct DeviceProcessApplication: Equatable, Hashable, Sendable {
    public var bundlePath: String
    public var bundleIdentifier: String
    public var name: String
    public var executablePath: String
    public var key: String { bundlePath + "|" + bundleIdentifier }
    public init(bundlePath: String, bundleIdentifier: String, name: String, executablePath: String) {
        self.bundlePath = bundlePath; self.bundleIdentifier = bundleIdentifier; self.name = name; self.executablePath = executablePath
    }
}

public struct DeviceProcess: Identifiable, Equatable, Sendable {
    public var id: Int32 { pid }
    public var identity: String { "\(pid):\(startedMicroseconds)" }
    public var pid: Int32
    public var name: String
    public var executablePath: String?
    public var cpuPercent: Double?
    public var residentBytes: UInt64
    public var threadCount: Int
    public var sampledAt: Date
    public var startedMicroseconds: UInt64
    public var parentPID: Int32
    public var ownerUID: UInt32?
    public var application: DeviceProcessApplication?
    public var isApplicationMain: Bool { application.map { $0.executablePath == executablePath } ?? false }
    public init(pid: Int32, name: String, executablePath: String? = nil, cpuPercent: Double? = nil,
                residentBytes: UInt64, threadCount: Int, sampledAt: Date, startedMicroseconds: UInt64 = 0,
                parentPID: Int32 = 0, ownerUID: UInt32? = nil, application: DeviceProcessApplication? = nil) {
        self.pid = pid; self.name = name; self.executablePath = executablePath; self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes; self.threadCount = threadCount; self.sampledAt = sampledAt
        self.startedMicroseconds = startedMicroseconds; self.parentPID = parentPID; self.ownerUID = ownerUID; self.application = application
    }
    public static func filtered(_ processes: [Self], query: String, sort: DeviceProcessSort) -> [Self] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return processes.filter { term.isEmpty || $0.name.localizedStandardContains(term) || String($0.pid).contains(term) }
            .sorted { a, b in
                switch sort {
                case .cpu: if a.cpuPercent != b.cpuPercent { return (a.cpuPercent ?? -1) > (b.cpuPercent ?? -1) }
                case .memory: if a.residentBytes != b.residentBytes { return a.residentBytes > b.residentBytes }
                case .name: if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                case .pid: return a.pid < b.pid
                }
                return a.pid < b.pid
            }
    }
}

/// proc_taskinfo CPU times use Mach absolute ticks, unlike nanosecond rusage counters.
public enum DeviceProcessCPU {
    public static func percent(ticks: UInt64, nanosecondsPerTick: Double, elapsed: TimeInterval, logicalCores: Int) -> Double? {
        guard elapsed.isFinite, elapsed > 0, nanosecondsPerTick.isFinite, nanosecondsPerTick > 0, logicalCores > 0 else { return nil }
        return min(100, Double(ticks) * nanosecondsPerTick / 1_000_000_000 / elapsed / Double(logicalCores) * 100)
    }
}
