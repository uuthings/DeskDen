import Foundation

/// Resource thresholds use the same whole-machine CPU and resident-memory measurements as the table.
public enum DeviceProcessFilter: String, CaseIterable, Sendable {
    case all, applications, background, highCPU, highMemory
    public static let highCPUThreshold = 5.0
    public static let highMemoryThreshold: UInt64 = 500 * 1_024 * 1_024
    public func includes(_ process: DeviceProcess) -> Bool {
        switch self {
        case .all: true
        case .applications: process.application != nil
        case .background: process.application == nil
        case .highCPU: process.cpuPercent.map { $0.isFinite && $0 >= Self.highCPUThreshold } ?? false
        case .highMemory: process.residentBytes >= Self.highMemoryThreshold
        }
    }
}

public struct DeviceProcessGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var application: DeviceProcessApplication?
    public var processes: [DeviceProcess]
    public var cpuPercent: Double? {
        guard processes.allSatisfy({ $0.cpuPercent?.isFinite == true }) else { return nil }
        return processes.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
    }
    public var residentBytes: UInt64 {
        processes.reduce(0) { value, process in
            let sum = value.addingReportingOverflow(process.residentBytes)
            return sum.overflow ? .max : sum.partialValue
        }
    }
    public var mainProcess: DeviceProcess? { processes.first(where: \.isApplicationMain) }
}

public enum DeviceProcessExplorer {
    public static func results(_ processes: [DeviceProcess], filter: DeviceProcessFilter,
                               query: String, sort: DeviceProcessSort, ascending: Bool) -> [DeviceProcess] {
        let values = DeviceProcess.filtered(processes.filter(filter.includes), query: query, sort: sort)
        let naturallyAscending = sort == .name || sort == .pid
        return ascending == naturallyAscending ? values : values.reversed()
    }

    /// An association comes only from a real bundle or a verified same-owner ancestor, never the process name.
    public static func inheritApplications(_ processes: [DeviceProcess]) -> [DeviceProcess] {
        let lookup = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return processes.map { process in
            guard process.application == nil else { return process }
            var result = process, current = process, visited: Set<Int32> = [process.pid]
            while let parent = lookup[current.parentPID], visited.insert(parent.pid).inserted,
                  parent.ownerUID != nil, parent.ownerUID == process.ownerUID,
                  parent.startedMicroseconds > 0, parent.startedMicroseconds <= current.startedMicroseconds {
                if let application = parent.application { result.application = application; break }
                current = parent
            }
            return result
        }
    }

    public static func groups(_ processes: [DeviceProcess], grouped: Bool, filter: DeviceProcessFilter,
                              query: String, sort: DeviceProcessSort, ascending: Bool) -> [DeviceProcessGroup] {
        var buckets: [String: [DeviceProcess]] = [:]
        for process in processes {
            let key = grouped ? process.application.map { "app:" + $0.key } ?? "pid:" + process.identity : "pid:" + process.identity
            buckets[key, default: []].append(process)
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = buckets.map { key, members in
            let application = grouped ? members.first?.application : nil
            return DeviceProcessGroup(id: key, name: application?.name ?? members[0].name,
                                      application: application, processes: members.sorted { $0.pid < $1.pid })
        }.filter { group in
            let match: Bool
            switch filter {
            case .all: match = true
            case .applications: match = group.processes.contains { $0.application != nil }
            case .background: match = group.processes.allSatisfy { $0.application == nil }
            case .highCPU: match = group.cpuPercent.map { $0 >= DeviceProcessFilter.highCPUThreshold } ?? false
            case .highMemory: match = group.residentBytes >= DeviceProcessFilter.highMemoryThreshold
            }
            return match && (term.isEmpty || group.name.localizedStandardContains(term) || group.processes.contains { $0.name.localizedStandardContains(term) || String($0.pid).contains(term) })
        }
        return values.sorted { a, b in
            switch sort {
            case .cpu:
                if a.cpuPercent != b.cpuPercent { return ascending ? (a.cpuPercent ?? -1) < (b.cpuPercent ?? -1) : (a.cpuPercent ?? -1) > (b.cpuPercent ?? -1) }
            case .memory:
                if a.residentBytes != b.residentBytes { return ascending ? a.residentBytes < b.residentBytes : a.residentBytes > b.residentBytes }
            case .name:
                if a.name != b.name { return ascending ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.name.localizedStandardCompare(b.name) == .orderedDescending }
            case .pid:
                let pa = a.processes.map(\.pid).min() ?? 0, pb = b.processes.map(\.pid).min() ?? 0
                if pa != pb { return ascending ? pa < pb : pa > pb }
            }
            return a.id < b.id
        }
    }

    /// Live values keep their row positions. New identities append; explicit sort changes reset the order.
    public static func stableOrder(_ incoming: [String], previous: [String]) -> [String] {
        let present = Set(incoming), old = Set(previous)
        return previous.filter(present.contains) + incoming.filter { !old.contains($0) }
    }
}

public enum DeviceProcessActionMode: Sendable { case quit, force }
public enum DeviceProcessOperation: Sendable { case quitApplication, terminate, forceTerminate }
public struct DeviceProcessActionRequest: Identifiable, Sendable {
    public let id = UUID()
    public var name: String
    public var processes: [DeviceProcess]
    public var mode: DeviceProcessActionMode
    public var wholeApplication: Bool
    public init(name: String, processes: [DeviceProcess], mode: DeviceProcessActionMode, wholeApplication: Bool = false) {
        self.name = name; self.processes = processes; self.mode = mode; self.wholeApplication = wholeApplication
    }
}
public enum DeviceProcessActionError: LocalizedError, Equatable {
    case protectedProcess, staleProcess, missingApplicationMain, failed(String), invalidGroup
    public var errorDescription: String? {
        switch self {
        case .protectedProcess: "此进程属于系统、其他用户或方寸自身，不能在此结束。"
        case .staleProcess: "进程已经退出或身份已变化，请重新选择。"
        case .missingApplicationMain: "应用主进程暂不可读，无法请求整个应用退出；可以展开后选择可操作的进程。"
        case .failed(let message): message
        case .invalidGroup: "应用归属已变化，请重新选择。"
        }
    }
}

public enum DeviceProcessActions {
    public static func isAllowed(_ process: DeviceProcess, currentUID: UInt32, currentPID: Int32, currentApplicationPath: String? = nil) -> Bool {
        guard process.pid > 1, process.pid != currentPID, process.startedMicroseconds > 0,
              process.ownerUID == currentUID, currentUID != 0, let path = process.executablePath, !path.isEmpty else { return false }
        if let currentApplicationPath, process.application?.bundlePath == currentApplicationPath { return false }
        let protected = ["/System/Library/", "/usr/", "/bin/", "/sbin/"]
        return !protected.contains(where: path.hasPrefix)
    }

    /// Every identity is captured before confirmation and revalidated immediately before dispatch.
    /// The injected operations make tests exercise real policy without terminating the test host or other apps.
    @discardableResult
    public static func perform(_ request: DeviceProcessActionRequest, currentUID: UInt32, currentPID: Int32,
                               currentApplicationPath: String? = nil, reread: (Int32) -> DeviceProcess?, dispatch: (DeviceProcess, DeviceProcessOperation) throws -> Void) throws -> Int {
        guard !request.processes.isEmpty else { throw DeviceProcessActionError.staleProcess }
        if request.wholeApplication {
            guard let application = request.processes.first?.application,
                  request.processes.allSatisfy({ $0.application == application }) else { throw DeviceProcessActionError.invalidGroup }
        }
        let targets: [DeviceProcess]
        if request.wholeApplication && request.mode == .quit {
            guard let main = request.processes.first(where: \.isApplicationMain) else { throw DeviceProcessActionError.missingApplicationMain }
            targets = [main]
        } else { targets = request.processes.sorted { !$0.isApplicationMain && $1.isApplicationMain } }
        func validated(_ selected: DeviceProcess) throws -> DeviceProcess {
            guard isAllowed(selected, currentUID: currentUID, currentPID: currentPID, currentApplicationPath: currentApplicationPath) else { throw DeviceProcessActionError.protectedProcess }
            guard let fresh = reread(selected.pid), fresh.identity == selected.identity,
                  fresh.ownerUID == selected.ownerUID, fresh.executablePath == selected.executablePath else { throw DeviceProcessActionError.staleProcess }
            guard isAllowed(fresh, currentUID: currentUID, currentPID: currentPID, currentApplicationPath: currentApplicationPath) else { throw DeviceProcessActionError.protectedProcess }
            if request.wholeApplication && fresh.application != selected.application { throw DeviceProcessActionError.invalidGroup }
            return fresh
        }
        // Reject invalid selection before dispatching anything, then recheck at each operation.
        for selected in targets { _ = try validated(selected) }
        for selected in targets {
            let fresh = try validated(selected)
            let operation: DeviceProcessOperation = request.mode == .force ? .forceTerminate : fresh.isApplicationMain ? .quitApplication : .terminate
            try dispatch(fresh, operation)
        }
        return targets.count
    }
}
