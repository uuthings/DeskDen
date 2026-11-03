import Foundation
import LauncherCore

/// Synthetic models only: no workspace queries, windows, sampling or process actions.
@MainActor enum DeviceProcessPresentationChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let app = DeviceProcessApplication(bundlePath: "/Applications/Synthetic.app", bundleIdentifier: "test.process-projection",
                                           name: "Synthetic App", executablePath: "/Applications/Synthetic.app/Contents/MacOS/Synthetic")
        let time = Date(timeIntervalSinceReferenceDate: 100)
        func process(_ pid: Int32, _ name: String, cpu: Double, sample: Date? = nil, app: DeviceProcessApplication? = nil) -> DeviceProcess {
            .init(pid: pid, name: name, executablePath: "/synthetic/process-\(pid)", cpuPercent: cpu,
                  residentBytes: UInt64(pid) * 1_024, threadCount: 1, sampledAt: sample ?? time,
                  startedMicroseconds: 1, ownerUID: 501, application: app)
        }
        let model = DeviceProcessPresentationModel()
        let initial = [process(21, "First", cpu: 1), process(32, "Second", cpu: 9)]
        func update(_ values: [DeviceProcess], query: String = "", grouped: Bool = false,
                    filter: DeviceProcessFilter = .all, force: Bool = false) {
            model.update(processes: values, grouped: grouped, filter: filter, query: query,
                         sort: .cpu, ascending: false, forceReorder: force)
        }
        update(initial)
        await model.waitForPendingUpdateForChecks()
        check(model.snapshot.rows.map(\.name) == ["Second", "First"], "initial process presentation applies the selected sort")
        check(model.snapshot.matchingCount == 2 && model.snapshot.counts[.all]?.processCount == 2,
              "rows and filter counts are published from one reading")

        let changed = [process(21, "First", cpu: 95, sample: time.addingTimeInterval(2)),
                       process(32, "Second", cpu: 2, sample: time.addingTimeInterval(2))]
        update(changed)
        await model.waitForPendingUpdateForChecks()
        check(model.snapshot.rows.map(\.name) == ["Second", "First"] && model.snapshot.rows.map(\.cpuPercent) == [2, 95],
              "a new sample updates readings while retaining visible row order")

        update(changed, query: "First")
        update(changed, query: "does not exist")
        update(changed, query: "Second")
        await model.waitForPendingUpdateForChecks()
        check(model.snapshot.rows.map(\.name) == ["Second"] && model.snapshot.matchingCount == 1,
              "rapid search requests publish only the most recent query")
        check(model.snapshot.counts[.all]?.processCount == 2, "search results do not rewrite the unsearched filter totals")

        let applicationValues = [process(21, "Main", cpu: 3, app: app), process(32, "Helper", cpu: 4, app: app),
                                 process(43, "Independent", cpu: 1)]
        update(applicationValues, grouped: true)
        await model.waitForPendingUpdateForChecks()
        check(model.snapshot.grouped && model.snapshot.rows.count == 2 && model.snapshot.matchingCount == 3,
              "group mode and grouped rows change together in one published snapshot")
        check(model.snapshot.counts[.applications] == .init(groupCount: 1, processCount: 2),
              "application totals distinguish one group from its two real members")
        update(applicationValues, grouped: false)
        await model.waitForPendingUpdateForChecks()
        check(!model.snapshot.grouped && model.snapshot.rows.count == 3
              && model.snapshot.counts[.applications] == .init(groupCount: 2, processCount: 2),
              "individual mode retains all members and reports individual counts")

        update(initial, force: true)
        await model.waitForPendingUpdateForChecks()
        update(changed, force: true)
        let newest = [process(21, "First", cpu: 99, sample: time.addingTimeInterval(4)),
                      process(32, "Second", cpu: 1, sample: time.addingTimeInterval(4))]
        update(newest)
        await model.waitForPendingUpdateForChecks()
        check(model.snapshot.rows.map(\.name) == ["First", "Second"] && model.snapshot.rows.first?.cpuPercent == 99,
              "a new reading superseding an unfinished explicit reorder still applies the requested reorder")

        update(newest, filter: .highMemory)
        update(newest, query: "First")
        await model.waitForPendingUpdateForChecks()
        check(model.snapshot.rows.map(\.name) == ["First"], "a cancelled filter cannot later replace a newer matching search")
        update([])
        await model.waitForPendingUpdateForChecks()
        check(model.snapshot.rows.isEmpty && model.snapshot.totalCount == 0 && model.snapshot.matchingCount == 0,
              "a genuinely empty reading removes stale rows and counts")

        let key = DeviceProcessPresentationKey(processes: initial, grouped: false, filter: .all, query: "", sort: .cpu, ascending: false)
        let sameKey = DeviceProcessPresentationKey(processes: initial, grouped: false, filter: .all, query: "", sort: .cpu, ascending: false)
        let freshKey = DeviceProcessPresentationKey(processes: changed, grouped: false, filter: .all, query: "", sort: .cpu, ascending: false)
        check(key == sameKey && key != freshKey, "the view observation key stays stable on hover and changes for a new sample")

        let large = (1...1_324).map { index in
            process(Int32(index + 10), "Worker \(index)", cpu: Double(index % 13), app: index <= 400 ? app : nil)
        }
        let projection = DeviceProcessProjection(large, grouped: true)
        for filter in DeviceProcessFilter.allCases {
            for query in ["", "Worker 100", "132"] {
                let baseline = legacyGroups(large, filter: filter, query: query)
                let actual = projection.presentation(filter: filter, query: query, sort: .cpu, ascending: false)
                check(actual.rows.map(\.id) == baseline.map(\.id)
                      && actual.rows.map { $0.processes.map(\.identity) } == baseline.map { $0.processes.map(\.identity) },
                      "1,324-process projection matches previous grouping/search semantics for \(filter.rawValue), query \(query.isEmpty ? "empty" : query)")
            }
        }

        // Reproduce one old body pass: five separately regrouped sidebar totals
        // plus repeated result/header/footer accesses. Timing is diagnostic only.
        var oldTimes: [Double] = [], newTimes: [Double] = []
        var oldChecksum = 0, newChecksum = 0
        let clock = ContinuousClock()
        for _ in 0..<3 {
            let start = clock.now
            for filter in DeviceProcessFilter.allCases { oldChecksum += legacyGroups(large, filter: filter, query: "").count }
            for _ in 0..<4 { oldChecksum += legacyGroups(large, filter: .all, query: "").count }
            oldTimes.append(milliseconds(start.duration(to: clock.now)))
            let next = clock.now
            let projected = DeviceProcessProjection(large, grouped: true)
            let result = projected.presentation(filter: .all, query: "", sort: .cpu, ascending: false)
            for filter in DeviceProcessFilter.allCases { newChecksum += projected.counts[filter]?.groupCount ?? 0 }
            for _ in 0..<4 { newChecksum += result.rows.count }
            newTimes.append(milliseconds(next.duration(to: clock.now)))
        }
        check(oldChecksum == newChecksum, "timed legacy and cached paths cover the same counts and complete results")
        let oldMedian = oldTimes.sorted()[1], newMedian = newTimes.sorted()[1]
        print(String(format: "Process projection diagnostic: legacy body median %.2f ms; cached projection median %.2f ms; ratio %.2fx; 1324 synthetic processes, 3 rounds", oldMedian, newMedian, oldMedian / max(0.000_001, newMedian)))
        return (count, failures)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    /// Frozen pre-cache grouping path, intentionally independent of production
    /// projection code so the comparison cannot validate the same implementation.
    private struct LegacyGroup {
        let id: String
        let name: String
        let processes: [DeviceProcess]
        var cpu: Double? {
            guard processes.allSatisfy({ $0.cpuPercent?.isFinite == true }) else { return nil }
            return processes.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
        }
        var memory: UInt64 {
            processes.reduce(0) { value, process in
                let sum = value.addingReportingOverflow(process.residentBytes)
                return sum.overflow ? .max : sum.partialValue
            }
        }
    }
    private static func legacyGroups(_ processes: [DeviceProcess], filter: DeviceProcessFilter, query: String) -> [LegacyGroup] {
        var buckets: [String: [DeviceProcess]] = [:]
        for process in processes {
            let key = process.application.map { "app:" + $0.key } ?? "pid:" + process.identity
            buckets[key, default: []].append(process)
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return buckets.map { key, members in
            LegacyGroup(id: key, name: members.first?.application?.name ?? members[0].name,
                        processes: members.sorted { $0.pid < $1.pid })
        }.filter { group in
            let matches: Bool
            switch filter {
            case .all: matches = true
            case .applications: matches = group.processes.contains { $0.application != nil }
            case .background: matches = group.processes.allSatisfy { $0.application == nil }
            case .highCPU: matches = group.cpu.map { $0 >= DeviceProcessFilter.highCPUThreshold } ?? false
            case .highMemory: matches = group.memory >= DeviceProcessFilter.highMemoryThreshold
            }
            return matches && (term.isEmpty || group.name.localizedStandardContains(term)
                || group.processes.contains { $0.name.localizedStandardContains(term) || String($0.pid).contains(term) })
        }.sorted { a, b in
            if a.cpu != b.cpu { return (a.cpu ?? -1) > (b.cpu ?? -1) }
            return a.id < b.id
        }
    }
}
