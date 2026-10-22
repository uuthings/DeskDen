import Foundation

/// A read-only snapshot for health review. Only this policy creates selectable candidates;
/// execution still has to revalidate the captured process identities before requesting quit.
public struct HealthApplicationCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let application: DeviceProcessApplication?
    public let processes: [DeviceProcess]
    public let residentBytes: UInt64
    public let sampledAt: Date
    public let mainProcess: DeviceProcess?
    public let isEligible: Bool
    public let reason: String

    /// Health review never offers a signal to an individual worker or a force-quit fallback.
    public var request: DeviceProcessActionRequest? {
        guard isEligible, application != nil, mainProcess != nil else { return nil }
        return .init(name: name, processes: processes, mode: .quit, wholeApplication: true)
    }
}

public enum HealthApplicationReviewPolicy {
    /// Returns an initial memory ordering, not an assertion that high memory is unhealthy.
    /// A caller may preserve these IDs to retain the user's order across reading updates.
    public static func candidates(_ processes: [DeviceProcess], sourceAt: Date?, at: Date,
                                  currentUID: UInt32, currentPID: Int32,
                                  currentApplicationPath: String?, maximumAge: TimeInterval = 15) -> [HealthApplicationCandidate] {
        let buckets = Dictionary(grouping: processes, by: \.pid)
        let conflicts = Set(buckets.compactMap { pid, values -> Int32? in
            guard values.count > 1, let first = values.first else { return nil }
            return values.allSatisfy { $0 == first } ? nil : pid
        })
        // Identical duplicate rows count once. Conflicting PID snapshots cannot be used
        // as an ancestor or action target, regardless of their order in the source array.
        let unique = buckets.compactMap { pid, values in conflicts.contains(pid) ? nil : values.first }
            .sorted { $0.pid < $1.pid }
        var ambiguousApplications: Set<String> = []
        for process in processes where conflicts.contains(process.pid) {
            // Also protect an otherwise valid app if the conflicting row was its helper.
            // The clean ancestor set cannot contain a conflicting PID of its own.
            let inherited = DeviceProcessExplorer.inheritApplications(unique + [process]).last
            if let application = inherited?.application { ambiguousApplications.insert(application.key) }
        }
        let inherited = DeviceProcessExplorer.inheritApplications(unique)
        let groups = DeviceProcessExplorer.groups(inherited, grouped: true, filter: .all,
                                                   query: "", sort: .memory, ascending: false)
        return groups.map { group in
            let mains = group.processes.filter(\.isApplicationMain)
            let main = mains.count == 1 ? mains[0] : nil
            let reason = rejection(group, mains: mains, ambiguousApplications: ambiguousApplications,
                                   sourceAt: sourceAt, at: at, maximumAge: maximumAge,
                                   currentUID: currentUID, currentPID: currentPID,
                                   currentApplicationPath: currentApplicationPath)
            let dates = ([sourceAt].compactMap { $0 } + group.processes.map(\.sampledAt))
                .filter { $0.timeIntervalSinceReferenceDate.isFinite }
            return HealthApplicationCandidate(
                id: candidateID(group, mains: mains), name: displayName(group),
                application: group.application, processes: group.processes,
                residentBytes: group.residentBytes, sampledAt: dates.min() ?? .distantPast,
                mainProcess: main, isEligible: reason == nil,
                reason: reason ?? "可手动选择正常退出；内存占用不代表应用异常，请先保存未完成的工作。")
        }.sorted { lhs, rhs in
            lhs.residentBytes == rhs.residentBytes ? lhs.id < rhs.id : lhs.residentBytes > rhs.residentBytes
        }
    }

    private static func rejection(_ group: DeviceProcessGroup, mains: [DeviceProcess],
                                  ambiguousApplications: Set<String>, sourceAt: Date?, at: Date,
                                  maximumAge: TimeInterval, currentUID: UInt32, currentPID: Int32,
                                  currentApplicationPath: String?) -> String? {
        guard maximumAge.isFinite, maximumAge >= 0, at.timeIntervalSinceReferenceDate.isFinite else {
            return "采样时效无法核验，请重新读取。"
        }
        guard let sourceAt, isFresh(sourceAt, at: at, maximumAge: maximumAge) else {
            return "进程来源时间缺失、已过期或晚于当前时间，请重新读取。"
        }
        guard group.processes.allSatisfy({ isFresh($0.sampledAt, at: at, maximumAge: maximumAge) }) else {
            return "部分进程读数已过期或时间无效，请重新读取。"
        }
        guard let application = group.application else {
            return "独立后台进程仅供查看；此处只允许请求整个应用正常退出。"
        }
        guard !ambiguousApplications.contains(application.key) else {
            return "同一 PID 出现冲突身份，暂不能确认应用范围，请重新读取。"
        }
        guard completeIdentity(application), group.processes.allSatisfy({ $0.application == application }) else {
            return "应用包身份不完整或归属不一致，暂不能选择。"
        }
        guard mains.count == 1 else {
            return mains.isEmpty ? "未读取到应用主进程，暂不能请求整个应用退出。"
                : "存在多个应用主进程，无法确定退出目标，请重新读取。"
        }
        guard currentUID != 0, group.processes.allSatisfy({ process in
            guard let path = process.executablePath, isAbsoluteNormalizedPath(path),
                  !path.hasPrefix("/System/") else { return false }
            return DeviceProcessActions.isAllowed(process, currentUID: currentUID, currentPID: currentPID,
                                                  currentApplicationPath: currentApplicationPath)
        }) else {
            return "包含系统、其他用户、方寸自身或身份不完整的进程，仅供查看。"
        }
        return nil
    }

    private static func isFresh(_ date: Date, at: Date, maximumAge: TimeInterval) -> Bool {
        let age = at.timeIntervalSince(date)
        return age.isFinite && age >= 0 && age <= maximumAge
    }

    private static func completeIdentity(_ application: DeviceProcessApplication) -> Bool {
        let identifier = application.bundleIdentifier
        return isAbsoluteNormalizedPath(application.bundlePath)
            && (application.bundlePath as NSString).pathExtension.lowercased() == "app"
            && isAbsoluteNormalizedPath(application.executablePath)
            && application.executablePath.hasPrefix(application.bundlePath + "/")
            && !identifier.isEmpty
            && identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            && identifier.rangeOfCharacter(from: .controlCharacters) == nil
            && identifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    /// This is deliberately lexical: reviewing a sample never reads the filesystem or
    /// resolves a path through a symlink. The live action service performs its own reread.
    private static func isAbsoluteNormalizedPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        return path.components(separatedBy: "/").dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func candidateID(_ group: DeviceProcessGroup, mains: [DeviceProcess]) -> String {
        guard let application = group.application else {
            return "background:" + group.processes.map(\.identity).sorted().joined(separator: ",")
        }
        // Length-prefix bundle components rather than relying on the explorer's display
        // grouping separator. Readings and names are excluded; a restarted main is not.
        let bundle = [application.bundlePath, application.bundleIdentifier, application.executablePath]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: ";")
        let identities = (mains.isEmpty ? group.processes : mains).map(\.identity).sorted().joined(separator: ",")
        let kind = mains.count == 1 ? "main" : mains.isEmpty ? "missing-main" : "ambiguous-main"
        return "application:\(bundle);\(kind):\(identities)"
    }

    private static func displayName(_ group: DeviceProcessGroup) -> String {
        if !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return group.name }
        if let application = group.application {
            return ((application.bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return group.processes.first.map { "进程 \($0.pid)" } ?? "未知进程"
    }
}
