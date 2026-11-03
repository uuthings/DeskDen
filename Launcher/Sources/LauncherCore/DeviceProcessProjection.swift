import Foundation

public struct DeviceProcessFilterCount: Equatable, Sendable {
    public var groupCount: Int = 0
    public var processCount: Int = 0
    public init(groupCount: Int = 0, processCount: Int = 0) {
        self.groupCount = groupCount; self.processCount = processCount
    }
}

public struct DeviceProcessPresentation: Equatable, Sendable {
    public var rows: [DeviceProcessGroup]
    public var counts: [DeviceProcessFilter: DeviceProcessFilterCount]
    public var matchingCount: Int
    public var totalCount: Int
    public var grouped: Bool
    public init(rows: [DeviceProcessGroup] = [], counts: [DeviceProcessFilter: DeviceProcessFilterCount] = [:], matchingCount: Int = 0, totalCount: Int = 0, grouped: Bool = true) {
        self.rows = rows; self.counts = counts; self.matchingCount = matchingCount; self.totalCount = totalCount; self.grouped = grouped
    }
}

/// Built once per reading and display mode. Counts and sort keys share the same
/// aggregates; rendering a row or a filter must not regroup the process list.
public struct DeviceProcessProjection: Sendable {
    private struct Entry: Sendable {
        let group: DeviceProcessGroup
        let cpu: Double?
        let memory: UInt64
        let minimumPID: Int32
        let hasApplication: Bool
        func includes(_ filter: DeviceProcessFilter) -> Bool {
            switch filter {
            case .all: true
            case .applications: hasApplication
            case .background: !hasApplication
            case .highCPU: cpu.map { $0 >= DeviceProcessFilter.highCPUThreshold } ?? false
            case .highMemory: memory >= DeviceProcessFilter.highMemoryThreshold
            }
        }
    }
    private let entries: [Entry]
    public let counts: [DeviceProcessFilter: DeviceProcessFilterCount]
    public let totalCount: Int
    public let grouped: Bool

    public init(_ processes: [DeviceProcess], grouped: Bool) {
        var buckets: [String: [DeviceProcess]] = [:]
        buckets.reserveCapacity(processes.count)
        for process in processes {
            let key = grouped ? process.application.map { "app:" + $0.key } ?? "pid:" + process.identity : "pid:" + process.identity
            buckets[key, default: []].append(process)
        }
        var totals = Dictionary(uniqueKeysWithValues: DeviceProcessFilter.allCases.map { ($0, DeviceProcessFilterCount()) })
        entries = buckets.map { key, members in
            let application = grouped ? members.first?.application : nil
            let group = DeviceProcessGroup(id: key, name: application?.name ?? members[0].name,
                                           application: application, processes: members.sorted { $0.pid < $1.pid })
            let entry = Entry(group: group, cpu: group.cpuPercent, memory: group.residentBytes,
                              minimumPID: group.processes.first?.pid ?? 0,
                              hasApplication: members.contains { $0.application != nil })
            for filter in DeviceProcessFilter.allCases where entry.includes(filter) {
                totals[filter, default: .init()].groupCount += 1
                totals[filter, default: .init()].processCount += members.count
            }
            return entry
        }
        counts = totals; totalCount = processes.count; self.grouped = grouped
    }

    /// Existing identities retain their order while readings change. Only new
    /// identities need sorting; an explicit sort/filter change passes no order.
    public func presentation(filter: DeviceProcessFilter, query: String, sort: DeviceProcessSort,
                             ascending: Bool, previousOrder: [String] = []) -> DeviceProcessPresentation {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = entries.filter { entry in
            entry.includes(filter) && (term.isEmpty || entry.group.name.localizedStandardContains(term)
                || entry.group.processes.contains { $0.name.localizedStandardContains(term) || String($0.pid).contains(term) })
        }
        func precedes(_ a: Entry, _ b: Entry) -> Bool {
            switch sort {
            case .cpu:
                if a.cpu != b.cpu { return ascending ? (a.cpu ?? -1) < (b.cpu ?? -1) : (a.cpu ?? -1) > (b.cpu ?? -1) }
            case .memory:
                if a.memory != b.memory { return ascending ? a.memory < b.memory : a.memory > b.memory }
            case .name:
                if a.group.name != b.group.name { return ascending ? a.group.name.localizedStandardCompare(b.group.name) == .orderedAscending : a.group.name.localizedStandardCompare(b.group.name) == .orderedDescending }
            case .pid:
                if a.minimumPID != b.minimumPID { return ascending ? a.minimumPID < b.minimumPID : a.minimumPID > b.minimumPID }
            }
            return a.group.id < b.group.id
        }
        let rows: [DeviceProcessGroup]
        if previousOrder.isEmpty {
            rows = matches.sorted(by: precedes).map(\.group)
        } else {
            var lookup = Dictionary(uniqueKeysWithValues: matches.map { ($0.group.id, $0) })
            let retained = previousOrder.compactMap { lookup.removeValue(forKey: $0)?.group }
            rows = retained + lookup.values.sorted(by: precedes).map(\.group)
        }
        return .init(rows: rows, counts: counts, matchingCount: matches.reduce(0) { $0 + $1.group.processes.count }, totalCount: totalCount, grouped: grouped)
    }
}
