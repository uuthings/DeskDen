import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SpaceCleaningDirectorySize: Equatable, Sendable {
    public var logicalBytes: UInt64
    public var allocatedBytes: UInt64
    public var checkedEntries: Int
    public var complete: Bool
    public var cancelled: Bool
    public var reason: String?
    public init(logicalBytes: UInt64 = 0, allocatedBytes: UInt64 = 0, checkedEntries: Int = 0,
                complete: Bool = false, cancelled: Bool = false, reason: String? = nil) {
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes; self.checkedEntries = checkedEntries
        self.complete = complete; self.cancelled = cancelled; self.reason = reason
    }
}

/// An explicit, metadata-only size inquiry. It never creates cleanup candidates
/// or changes protection. Totals cover regular files, deduplicating hard links;
/// symlink targets and filesystem metadata are not counted as reclaimable space.
public enum SpaceCleaningDirectorySizeScanner {
    public static func measure(directory: URL, expectedIdentity: StorageReviewFileIdentity,
                               maximumEntries: Int = 100_000, maximumDepth: Int = 32,
                               isCancelled: () -> Bool = { false },
                               progress: (SpaceCleaningDirectorySize) -> Void = { _ in }) -> SpaceCleaningDirectorySize {
        let entryLimit = min(1_000_000, max(1, maximumEntries)), depthLimit = min(128, max(0, maximumDepth))
        var result = SpaceCleaningDirectorySize(), seen = Set<String>()
        var stopped = false, lastProgress = Date.distantPast
        func partial(_ reason: String) { if result.reason == nil { result.reason = reason } }
        func cancelled() -> Bool {
            if isCancelled() {
                result.cancelled = true; result.reason = "统计已取消，保留已读取的部分容量。"; stopped = true
            }
            return result.cancelled
        }
        func emit() {
            let now = Date()
            if result.checkedEntries == 1 || now.timeIntervalSince(lastProgress) >= 0.1 {
                lastProgress = now; progress(result)
            }
        }
        func walk(_ descriptor: Int32, at url: URL, expected: StorageReviewFileIdentity, depth: Int) {
            guard !stopped, !cancelled() else { close(descriptor); return }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, identity(opened) == expected,
                  !cloud(opened), SpaceCleaningScanner.captureIdentity(at: url) == expected,
                  SpaceCleaningScanner.canonicalURL(url)?.path == url.path else {
                close(descriptor); partial("目录在读取前已变化，未继续统计此位置。"); return
            }
            guard let handle = fdopendir(descriptor) else { close(descriptor); partial("无法读取部分目录，容量统计不完整。"); return }
            defer { closedir(handle) }
            while !stopped && !cancelled() {
                errno = 0
                guard let entry = readdir(handle) else {
                    if errno != 0 { partial("部分目录未能读完，容量统计不完整。") }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                guard result.checkedEntries < entryLimit else { partial("已达到统计条目上限，显示已读取的部分容量。"); stopped = true; break }
                result.checkedEntries += 1
                var info = stat()
                guard name.withCString({ fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                    partial("部分项目无法读取或已消失，容量统计不完整。"); emit(); continue
                }
                let child = url.appendingPathComponent(name), value = identity(info), type = info.st_mode & S_IFMT
                if cloud(info) {
                    partial("部分内容尚未下载到本机，未触发下载，容量统计不完整。")
                } else if value.device != expectedIdentity.device {
                    partial("部分目录位于其他卷，未跨卷统计。")
                } else if type == S_IFREG {
                    if seen.insert(value.fileKey).inserted {
                        result.logicalBytes = add(result.logicalBytes, value.sizeBytes)
                        result.allocatedBytes = add(result.allocatedBytes, value.allocatedBytes)
                    }
                } else if type == S_IFDIR {
                    if depth >= depthLimit {
                        partial("已达到目录深度上限，显示已读取的部分容量。")
                    } else {
                        let childFD = name.withCString { openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
                        if childFD >= 0 { walk(childFD, at: child, expected: value, depth: depth + 1) }
                        else { partial("部分目录无法安全打开，容量统计不完整。") }
                    }
                } else if type != S_IFLNK {
                    partial("目录含有特殊文件，仅统计可读取的普通文件。")
                }
                emit()
            }
            var after = stat()
            if fstat(descriptor, &after) != 0 || identity(after) != expected || cloud(after) ||
                SpaceCleaningScanner.captureIdentity(at: url) != expected || SpaceCleaningScanner.canonicalURL(url)?.path != url.path {
                partial("统计期间目录发生变化，结果仅供参考。")
            }
        }

        // Keep the caller's canonical spelling: standardizedFileURL rewrites
        // /private/var on macOS. A redirecting root or ancestor is never opened.
        if cancelled() {
            progress(result); return result
        }
        guard directory.isFileURL, expectedIdentity.mode & UInt32(S_IFMT) == UInt32(S_IFDIR),
              SpaceCleaningScanner.captureIdentity(at: directory) == expectedIdentity,
              SpaceCleaningScanner.canonicalURL(directory)?.path == directory.path,
              !SpaceCleaningScanner.isCloudPlaceholder(at: directory) else {
            result.reason = "目录已变化、经过链接或尚未下载到本机，未开始统计。"
            progress(result); return result
        }
        #if canImport(Darwin)
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK
        #else
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        #endif
        let descriptor = directory.path.withCString { open($0, flags) }
        guard descriptor >= 0 else {
            result.reason = "目录无法安全打开，未开始统计。"; progress(result); return result
        }
        walk(descriptor, at: directory, expected: expectedIdentity, depth: 0)
        _ = cancelled()
        result.complete = !result.cancelled && result.reason == nil
        progress(result)
        return result
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let sum = lhs.addingReportingOverflow(rhs); return sum.overflow ? .max : sum.partialValue
    }
    private static func cloud(_ value: stat) -> Bool {
        #if canImport(Darwin)
        SpaceCleaningScanner.isCloudPlaceholder(fileFlags: UInt32(value.st_flags))
        #else
        false
        #endif
    }
    private static func identity(_ value: stat) -> StorageReviewFileIdentity {
        #if canImport(Darwin)
        let modified = value.st_mtimespec, changed = value.st_ctimespec
        #else
        let modified = value.st_mtim, changed = value.st_ctim
        #endif
        let allocated = UInt64(max(0, value.st_blocks)).multipliedReportingOverflow(by: 512)
        return .init(device: UInt64(bitPattern: Int64(value.st_dev)), inode: UInt64(value.st_ino), sizeBytes: UInt64(max(0, value.st_size)),
                     allocatedBytes: allocated.overflow ? .max : allocated.partialValue,
                     modifiedSeconds: Int64(modified.tv_sec), modifiedNanoseconds: Int64(modified.tv_nsec),
                     changedSeconds: Int64(changed.tv_sec), changedNanoseconds: Int64(changed.tv_nsec),
                     linkCount: UInt64(value.st_nlink), mode: UInt32(value.st_mode))
    }
}
