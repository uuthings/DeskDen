import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

/// One Xcode simulator in the user's default device set, read from the
/// device's own `device.plist`.
public struct SpaceCleaningSimulatorDevice: Codable, Equatable, Sendable {
    public var udid: String
    public var name: String
    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0`
    public var runtime: String
    public var deviceType: String
    /// CoreSimulator's state: 1 is shut down; 0, 2, 3 and 4 are creating,
    /// booting, booted and shutting down.
    public var state: Int
    public var lastUsedAt: Date?
    public init(udid: String, name: String, runtime: String, deviceType: String, state: Int, lastUsedAt: Date?) {
        self.udid = udid; self.name = name; self.runtime = runtime; self.deviceType = deviceType
        self.state = state; self.lastUsedAt = lastUsedAt
    }
    public var isShutdown: Bool { state == SpaceCleaningSimulators.shutdownState }
    public var runtimeTitle: String { SpaceCleaningSimulators.runtimeTitle(runtime) }
}

/// Simulators are listed one device per item and deleted only through Xcode's
/// own tool (`simctl delete`). The device set belongs to CoreSimulator, so the
/// cleaner never moves, renames or removes its folders itself, and a deleted
/// simulator cannot be restored from the Trash.
public enum SpaceCleaningSimulators {
    /// The current user's default device set, relative to the home folder.
    static let deviceSetPath = "Library/Developer/CoreSimulator/Devices"
    /// CoreSimulator's own data; nothing in it is listed file by file.
    static let serviceDataPath = "Library/Developer/CoreSimulator"
    static let shutdownState = 1
    /// A simulator unused this long is listed with suggestions.
    public static let suggestionAge: TimeInterval = 7 * 86_400
    /// Marks an unreadable process table: every simulator then counts as in use.
    public static let unknownReferences = "*"

    // MARK: Device records

    /// Reads `device.plist` without following links. The record must name the
    /// folder's own UDID and must not be marked deleted.
    public static func device(at url: URL) -> SpaceCleaningSimulatorDevice? { record(at: url)?.device }

    /// The device and the time its record was last written (the creation time
    /// of a simulator that has never been started).
    static func record(at url: URL) -> (device: SpaceCleaningSimulatorDevice, written: Date)? {
        let folder = url.lastPathComponent
        guard UUID(uuidString: folder) != nil else { return nil }
        let plist = url.appendingPathComponent("device.plist", isDirectory: false)
        let descriptor = plist.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) } ?? -1 }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 65_536 else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count == Int(info.st_size),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let udid = object["UDID"] as? String, udid.caseInsensitiveCompare(folder) == .orderedSame,
              let name = object["name"] as? String, !name.isEmpty,
              let runtime = object["runtime"] as? String, let deviceType = object["deviceType"] as? String,
              let state = (object["state"] as? NSNumber)?.intValue,
              (object["isDeleted"] as? Bool) != true else { return nil }
        let written = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        // Records written by older Xcode versions keep the last boot instead.
        let used = object["lastUsedAt"] as? Date ?? object["lastBootedAt"] as? Date
        return (.init(udid: udid.uppercased(), name: name, runtime: runtime, deviceType: deviceType, state: state,
                      lastUsedAt: used), written)
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `iOS 27.0`.
    public static func runtimeTitle(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = last.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let platform = parts.first, !platform.isEmpty,
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return last }
        return (platform == "xrOS" ? "visionOS" : platform) + " " + parts.dropFirst().joined(separator: ".")
    }

    public static func title(_ device: SpaceCleaningSimulatorDevice) -> String {
        "模拟器 · \(device.name)（\(device.runtimeTitle)）"
    }

    // MARK: Assessment

    struct Assessment: Equatable {
        var kind: SpaceCleaningKind
        var group: SpaceCleaningGroup
        var suggestion: Bool
        var reason: String
        var impact: String
    }
    static let deletionImpact = "删除后其中安装的 App、数据与设置一并移除，需要时可在 Xcode 中重新创建。通过 Xcode 的 simctl 删除，不进入废纸篓，无法恢复。"

    /// Running, referenced and recently used devices are never suggested; a
    /// device in use is never selectable.
    static func assess(_ device: SpaceCleaningSimulatorDevice, written: Date, now: Date, referenced: Bool,
                       runningInside: Bool, toolAvailable: Bool) -> Assessment {
        if !device.isShutdown {
            return .init(kind: .runningApplication, group: .protected, suggestion: false,
                         reason: "模拟器正在运行，或正在启动、关闭，本次保留。", impact: "在 Simulator 中关闭这台设备后重新扫描。")
        }
        if referenced || runningInside {
            return .init(kind: .runningApplication, group: .protected, suggestion: false,
                         reason: runningInside ? "模拟器中有程序正在运行，本次保留。" : "正在运行的构建或测试指定了这台模拟器，本次保留。",
                         impact: "构建或测试结束后重新扫描。")
        }
        if !toolAvailable {
            return .init(kind: .unsupported, group: .protected, suggestion: false,
                         reason: "未找到 Xcode 的模拟器工具（simctl），无法通过 Xcode 安全删除，本次保留。",
                         impact: "安装 Xcode，或用 xcode-select 选择 Xcode 后重新扫描。")
        }
        let platform = device.runtimeTitle
        guard let used = device.lastUsedAt else {
            let old = now.timeIntervalSince(written) >= suggestionAge
            return .init(kind: .developmentFile, group: .review, suggestion: old,
                         reason: old ? "Xcode 模拟器（\(platform)），创建后从未启动过。" : "新建的 Xcode 模拟器（\(platform)），尚未启动过，可能即将用于测试。",
                         impact: deletionImpact)
        }
        let days = max(0, Int(now.timeIntervalSince(used) / 86_400))
        if now.timeIntervalSince(used) >= suggestionAge {
            return .init(kind: .developmentFile, group: .review, suggestion: true,
                         reason: "Xcode 模拟器（\(platform)），已 \(days) 天未使用。", impact: deletionImpact)
        }
        return .init(kind: .developmentFile, group: .review, suggestion: false,
                     reason: "Xcode 模拟器（\(platform)），最后使用于\(days == 0 ? "今天" : " \(days) 天前")；可能仍在测试中，确认不再需要再选择。",
                     impact: deletionImpact)
    }

    // MARK: Size

    struct Size: Sendable, Equatable {
        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        var entries = 0
        var complete = true
    }
    /// Shared progress between parallel measurements.
    final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var stopped = false
        func add(_ value: Int) { lock.lock(); count += value; lock.unlock() }
        var entries: Int { lock.lock(); defer { lock.unlock() }; return count }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    /// Sizes of regular files under one device folder: links are never
    /// followed, another volume is never entered and a hard-linked file counts
    /// once. Thread-safe; devices are measured in parallel.
    static func measure(_ url: URL, expected: SpaceCleaningFileIdentity, limit: Int, progress: Progress) -> Size {
        var size = Size(), hardLinked = Set<UInt64>()
        let root = url.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) } ?? -1 }
        guard root >= 0 else { size.complete = false; return size }
        defer { close(root) }
        var opened = stat()
        guard fstat(root, &opened) == 0, UInt64(bitPattern: Int64(opened.st_dev)) == expected.device,
              UInt64(opened.st_ino) == expected.inode else { size.complete = false; return size }
        let volume = opened.st_dev
        let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!
        var reported = 0
        func walk(_ descriptor: Int32, depth: Int) -> Bool {
            guard depth <= 128 else { size.complete = false; return false }
            let copy = dup(descriptor)
            guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; size.complete = false; return false }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                let length = Int(entry.pointee.d_namlen)
                let name = UnsafeRawPointer(entry).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
                if (length == 1 && name[0] == 46) || (length == 2 && name[0] == 46 && name[1] == 46) { continue }
                size.entries += 1
                if size.entries - reported >= 4_096 {
                    progress.add(size.entries - reported); reported = size.entries
                    if progress.isStopped { size.complete = false; return false }
                }
                guard size.entries <= limit else { size.complete = false; return false }
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { size.complete = false; return false }
                guard info.st_dev == volume else { continue }
                let type = info.st_mode & S_IFMT
                if type == S_IFREG {
                    size.logical &+= UInt64(max(0, info.st_size))
                    if info.st_nlink <= 1 || hardLinked.insert(UInt64(info.st_ino)).inserted {
                        size.allocated &+= UInt64(max(0, info.st_blocks)) * 512
                    }
                } else if type == S_IFDIR {
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                    guard child >= 0 else { size.complete = false; return false }
                    defer { close(child) }
                    guard walk(child, depth: depth + 1) else { return false }
                }
            }
            return true
        }
        _ = walk(root, depth: 0)
        progress.add(size.entries - reported)
        return size
    }

    // MARK: Running references

    /// UDIDs and device names that a process passes to build, test and
    /// simulator tools: `-destination 'platform=iOS Simulator,id=…'` or
    /// `name=…`, `simctl boot <UDID or name>`, and the device paths that
    /// booted simulators run from. Names are returned as `name=<name>`.
    public static func references(executable: String, arguments: [String]) -> Set<String> {
        var result = Set<String>()
        for argument in arguments { result.formUnion(uuids(in: argument)) }
        for (index, argument) in arguments.enumerated() {
            let destination = argument.contains("platform=") || (index > 0 && arguments[index - 1] == "-destination")
            guard destination else { continue }
            for part in argument.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("name=") { result.insert("name=" + trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)) }
            }
        }
        // `simctl <command> <device> …` accepts a device name as well as a UDID.
        let tool = SpaceCleaningToolActivity.basename(executable)
        if let index = arguments.firstIndex(where: { SpaceCleaningToolActivity.basename($0) == "simctl" }) ?? (tool == "simctl" ? 0 : nil) {
            for argument in arguments.dropFirst(index + 1) where !argument.hasPrefix("-") { result.insert("name=" + argument) }
        }
        return result
    }

    static func isReferenced(_ device: SpaceCleaningSimulatorDevice, by references: Set<String>) -> Bool {
        references.contains(unknownReferences) || references.contains(device.udid.uppercased()) || references.contains("name=" + device.name)
    }

    static func uuids(in text: String) -> [String] {
        let bytes = Array(text.utf8)
        guard bytes.count >= 36 else { return [] }
        var found: [String] = []
        var index = 0
        while index + 36 <= bytes.count {
            if isUUID(bytes[index..<(index + 36)]) {
                found.append(String(decoding: bytes[index..<(index + 36)], as: UTF8.self).uppercased()); index += 36
            } else { index += 1 }
        }
        return found
    }
    private static func isUUID(_ bytes: ArraySlice<UInt8>) -> Bool {
        for (offset, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(offset) { if byte != UInt8(ascii: "-") { return false }; continue }
            let hex = (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
            if !hex { return false }
        }
        return true
    }

    // MARK: Deletion

    /// A record proof for a deleted simulator. It binds the device folder's
    /// identity and its CoreSimulator record (UDID, name, system, type, state
    /// and last use). Simulator records are never restored, so it is never
    /// matched against files; it stays within the bounds every build accepts.
    static func proof(for device: SpaceCleaningSimulatorDevice, identity: SpaceCleaningFileIdentity, logicalBytes: UInt64) -> SpaceCleaningTreeProof {
        let used = device.lastUsedAt.map { String($0.timeIntervalSince1970) } ?? "-"
        let text = ["deskden-simulator-1", device.udid, device.name, device.runtime, device.deviceType, String(device.state), used,
                    "\(identity.device):\(identity.inode)"].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(sha256: digest, entryCount: 1, logicalBytes: logicalBytes, rootIdentity: identity)
    }

    /// Xcode's `simctl`, found without `xcrun`: `xcrun` offers to install the
    /// command line tools when no developer folder exists.
    public static func toolURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var folders: [String] = []
        if let value = environment["DEVELOPER_DIR"], value.hasPrefix("/") {
            folders.append(value.hasSuffix(".app") ? value + "/Contents/Developer" : value)
        }
        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"), link.hasPrefix("/") {
            folders.append(link)
        }
        folders.append("/Applications/Xcode.app/Contents/Developer")
        for folder in folders {
            let tool = URL(fileURLWithPath: folder).appendingPathComponent("usr/bin/simctl", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: tool.path) { return tool }
        }
        return nil
    }

    /// Runs `simctl delete <UDID>` on the default device set. Returning
    /// normally means the tool reported success.
    public static func deleteWithXcode(udid: String, timeout: TimeInterval = 600) throws {
        guard UUID(uuidString: udid) != nil else { throw SpaceCleaningFilesystem.Failure(message: "模拟器标识无效，未删除。") }
        guard let tool = toolURL() else { throw SpaceCleaningFilesystem.Failure(message: "未找到 Xcode 的模拟器工具（simctl），未删除。") }
        let process = Process(), errors = Pipe()
        process.executableURL = tool; process.arguments = ["delete", udid]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        let output = ErrorOutput()
        try process.run()
        let reader = Thread { output.set(errors.fileHandleForReading.readDataToEndOfFile()) }
        reader.start()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            throw SpaceCleaningFilesystem.Failure(message: "simctl 删除超时，结果未确认。")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = output.firstLine(waiting: 2).map { "：" + $0 } ?? ""
            throw SpaceCleaningFilesystem.Failure(message: "simctl 未能删除模拟器（退出码 \(process.terminationStatus)）" + detail)
        }
    }
    private final class ErrorOutput: @unchecked Sendable {
        private let condition = NSCondition()
        private var data: Data?
        func set(_ value: Data) { condition.lock(); data = value.prefix(4_096); condition.broadcast(); condition.unlock() }
        func firstLine(waiting seconds: TimeInterval) -> String? {
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(seconds)
            while data == nil, condition.wait(until: deadline) {}
            guard let data else { return nil }
            return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
        }
    }
}
