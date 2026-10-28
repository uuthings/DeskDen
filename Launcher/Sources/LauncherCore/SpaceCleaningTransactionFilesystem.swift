import Foundation
import CryptoKit
import Darwin

/// All mutating operations are relative to directory descriptors opened without
/// following symbolic links. A saved path alone never authorizes a mutation.
enum SpaceCleaningFilesystem {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
    final class Directory {
        let descriptor: Int32
        let url: URL
        let identity: SpaceCleaningFileIdentity
        init(_ url: URL) throws {
            guard url.isFileURL else { throw Failure(message: "位置不是本机目录。") }
            var before = stat()
            guard url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &before) } ?? -1 }) == 0,
                  !isCloudPlaceholder(flags: UInt32(before.st_flags)) else { throw Failure(message: "目录未下载到本机或无法安全访问。") }
            self.url = url
            descriptor = url.withUnsafeFileSystemRepresentation {
                $0.map { open($0, O_SEARCH | O_CLOEXEC | O_NOFOLLOW_ANY) } ?? -1
            }
            guard descriptor >= 0 else { throw Failure(message: "目录已变化或无法安全访问。") }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  !isCloudPlaceholder(flags: UInt32(info.st_flags)) else {
                close(descriptor); throw Failure(message: "目录身份无法核验。")
            }
            identity = SpaceCleaningFilesystem.identity(info)
        }
        deinit { close(descriptor) }
        func stillAtPath() -> Bool {
            var info = stat()
            guard url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &info) } ?? -1 }) == 0,
                  !isCloudPlaceholder(flags: UInt32(info.st_flags)) else { return false }
            let actual = SpaceCleaningFilesystem.identity(info)
            return actual.device == identity.device && actual.inode == identity.inode && actual.mode == identity.mode
        }
        func entry(_ name: String) -> SpaceCleaningFileIdentity? {
            guard validName(name) else { return nil }
            var info = stat()
            guard name.withCString({ fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
                  !isCloudPlaceholder(flags: UInt32(info.st_flags)) else { return nil }
            return SpaceCleaningFilesystem.identity(info)
        }
    }

    struct Node {
        var path: String
        var identity: SpaceCleaningFileIdentity
        var owner: UInt32
        var group: UInt32
        var flags: UInt32
        var digest: String?
        var link: String?
    }
    struct Snapshot {
        var proof: SpaceCleaningTreeProof
        var nodes: [Node]
        var lease: ObjectLease
    }
    /// Kept open across the rename/Trash operation. macOS may allow metadata
    /// lookup of a known Trash item while denying a new content open there.
    final class ObjectLease {
        let descriptor: Int32
        init(_ url: URL, expected: SpaceCleaningFileIdentity) throws {
            // lstat is metadata-only. Refuse a dataless object before any content
            // open could ask a File Provider to download it on our behalf.
            var before = stat()
            guard url.isFileURL, url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &before) } ?? -1 }) == 0,
                  expected == SpaceCleaningFilesystem.identity(before), !isCloudPlaceholder(flags: UInt32(before.st_flags)) else {
                throw Failure(message: "项目尚未下载到本机、已变化或无法安全访问，未读取内容。")
            }
            descriptor = url.withUnsafeFileSystemRepresentation {
                $0.map { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK) } ?? -1
            }
            guard descriptor >= 0 else { throw Failure(message: "无法安全打开所选项目内容。") }
            var info = stat()
            guard fstat(descriptor, &info) == 0, expected == SpaceCleaningFilesystem.identity(info),
                  !isCloudPlaceholder(flags: UInt32(info.st_flags)),
                  info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG else {
                close(descriptor); throw Failure(message: "打开的项目与所选身份不一致。")
            }
        }
        deinit { close(descriptor) }
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
    static func isCloudPlaceholder(flags: UInt32) -> Bool { SpaceCleaningScanner.isCloudPlaceholder(fileFlags: flags) }
    static func identity(_ info: stat) -> SpaceCleaningFileIdentity {
        .init(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
              sizeBytes: UInt64(max(0, info.st_size)), allocatedBytes: UInt64(max(0, info.st_blocks)) * 512,
              modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
              changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec),
              linkCount: UInt64(info.st_nlink), mode: UInt32(info.st_mode))
    }
    static func capture(_ url: URL) -> SpaceCleaningFileIdentity? {
        var info = stat()
        guard url.isFileURL, url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &info) } ?? -1 }) == 0 else { return nil }
        return identity(info)
    }
    static func absent(_ url: URL) -> Bool {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &info) } ?? -1 }
        return result != 0 && errno == ENOENT
    }
    static func sameDirectory(_ left: SpaceCleaningFileIdentity, _ right: SpaceCleaningFileIdentity) -> Bool {
        left.device == right.device && left.inode == right.inode && left.mode == right.mode && right.mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
    }
    static func validateAncestors(_ candidate: SpaceCleaningCandidate) -> Bool {
        let root = candidate.rootURL.path, path = candidate.url.path
        guard root != "/", path.hasPrefix(root + "/"),
              !candidate.ancestorIdentities.isEmpty,
              candidate.ancestorIdentities.first?.url.path == root,
              candidate.ancestorIdentities.last?.url.path == candidate.url.deletingLastPathComponent().path,
              let first = candidate.ancestorIdentities.first,
              sameDirectory(first.identity, candidate.rootIdentity) else { return false }
        for (index, ancestor) in candidate.ancestorIdentities.enumerated() {
            if index > 0, ancestor.url.deletingLastPathComponent().path != candidate.ancestorIdentities[index - 1].url.path { return false }
            guard let directory = try? Directory(ancestor.url), sameDirectory(directory.identity, ancestor.identity), directory.stillAtPath() else { return false }
        }
        return true
    }
    static func move(_ source: URL, to destination: URL, expected: SpaceCleaningFileIdentity) throws {
        let from = try Directory(source.deletingLastPathComponent())
        let to = try Directory(destination.deletingLastPathComponent())
        guard validName(source.lastPathComponent), validName(destination.lastPathComponent),
              from.stillAtPath(), to.stillAtPath(),
              let actual = from.entry(source.lastPathComponent), expected.matchesMovedResource(actual), expected.mode == actual.mode else {
            throw Failure(message: "移动前文件或父目录已变化。")
        }
        let result = source.lastPathComponent.withCString { old in
            destination.lastPathComponent.withCString { new in
                renameatx_np(from.descriptor, old, to.descriptor, new, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw Failure(message: "未覆盖现有项目；无法完成移动：" + POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription) }
        guard from.stillAtPath(), to.stillAtPath(),
              to.entry(destination.lastPathComponent).map(expected.matchesMovedResource) == true,
              from.entry(source.lastPathComponent) == nil else {
            throw Failure(message: "移动完成后位置发生变化，需要手动核对。")
        }
    }
    static func makeIsolation(_ url: URL, candidate: SpaceCleaningCandidate? = nil) throws {
        if let candidate, !validateAncestors(candidate) { throw Failure(message: "扫描后的父目录已变化，未处理文件。") }
        let parent = try Directory(url.deletingLastPathComponent())
        guard parent.stillAtPath(), validName(url.lastPathComponent) else { throw Failure(message: "隔离目录的父位置无法核验。") }
        guard url.lastPathComponent.withCString({ mkdirat(parent.descriptor, $0, 0o700) }) == 0 else {
            throw Failure(message: "无法创建本次操作专用的隔离目录。")
        }
        guard parent.stillAtPath() else { throw Failure(message: "隔离目录创建期间父位置发生变化。") }
    }
    static func removeEmptyIsolation(_ url: URL) {
        guard let parent = try? Directory(url.deletingLastPathComponent()), parent.stillAtPath(),
              let child = parent.entry(url.lastPathComponent), child.mode & UInt32(S_IFMT) == UInt32(S_IFDIR),
              url.lastPathComponent.hasPrefix(".deskden-cleaning-") else { return }
        _ = url.lastPathComponent.withCString { unlinkat(parent.descriptor, $0, AT_REMOVEDIR) }
    }

    /// Reads complete content only for explicitly selected objects. Symbolic links
    /// are never followed for reading; package-local links are recorded as links.
    static func snapshot(_ url: URL, expected: SpaceCleaningFileIdentity, allowRename: Bool,
                         isCancelled: () -> Bool, maximumNodes: Int = 100_000, lease suppliedLease: ObjectLease? = nil) throws -> Snapshot {
        guard !isCancelled() else { throw Failure(message: "操作已取消。") }
        let parent = try Directory(url.deletingLastPathComponent())
        guard let initial = parent.entry(url.lastPathComponent),
              allowRename ? expected.matchesMovedResource(initial) && expected.mode == initial.mode : expected == initial,
              parent.stillAtPath() else { throw Failure(message: "所选项目已变化。") }
        let lease = try suppliedLease ?? ObjectLease(url, expected: initial)
        var nodes: [Node] = [], logicalBytes: UInt64 = 0
        let package = ["app", "xcarchive"].contains(url.pathExtension.lowercased())
        func inspect(parentFD: Int32, name: String, relative: String, depth: Int) throws {
            guard !isCancelled(), nodes.count < maximumNodes, depth <= 128 else {
                throw Failure(message: isCancelled() ? "操作已取消。" : "完整核验达到安全上限，未处理项目。")
            }
            var info = stat()
            guard name.withCString({ fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
                  info.st_size >= 0, UInt64(bitPattern: Int64(info.st_dev)) == initial.device else {
                throw Failure(message: "项目内容已变化、无法读取或跨越其他卷。")
            }
            guard !isCloudPlaceholder(flags: UInt32(info.st_flags)) else {
                throw Failure(message: "包含尚未下载到本机的云端项目，保留整个项目且不触发下载。")
            }
            let before = identity(info), type = info.st_mode & S_IFMT
            var node = Node(path: relative, identity: before, owner: UInt32(info.st_uid), group: UInt32(info.st_gid), flags: UInt32(info.st_flags))
            if type == S_IFREG {
                guard info.st_nlink == 1 else { throw Failure(message: "包含多重硬链接，保留此项目。") }
                let descriptor = relative.isEmpty ? dup(lease.descriptor) : name.withCString { openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
                guard descriptor >= 0 else { throw Failure(message: "无法完整读取所选项目内容。") }
                defer { close(descriptor) }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, identity(opened) == before,
                      !isCloudPlaceholder(flags: UInt32(opened.st_flags)), lseek(descriptor, 0, SEEK_SET) == 0 else { throw Failure(message: "文件在读取前已被替换或已变为云端占位项。") }
                var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1_048_576), total: UInt64 = 0
                while true {
                    guard !isCancelled() else { throw Failure(message: "内容核验已取消。") }
                    var reading = stat()
                    guard fstat(descriptor, &reading) == 0, !isCloudPlaceholder(flags: UInt32(reading.st_flags)) else { throw Failure(message: "文件已变为云端占位项，停止读取。") }
                    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                    if count < 0 { if errno == EINTR { continue }; throw Failure(message: "文件内容读取失败。") }
                    if count == 0 { break }
                    total += UInt64(count)
                    guard total <= before.sizeBytes else { throw Failure(message: "文件正在写入，已保留。") }
                    buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                }
                var after = stat(), atPath = stat()
                guard total == before.sizeBytes, fstat(descriptor, &after) == 0, identity(after) == before,
                      after.st_uid == info.st_uid, after.st_gid == info.st_gid, after.st_flags == info.st_flags,
                      name.withCString({ fstatat(parentFD, $0, &atPath, AT_SYMLINK_NOFOLLOW) }) == 0, identity(atPath) == before else {
                    throw Failure(message: "文件正在变化，已保留。")
                }
                node.digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                logicalBytes += total
                nodes.append(node)
            } else if type == S_IFDIR {
                let descriptor = relative.isEmpty ? dup(lease.descriptor) : name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
                guard descriptor >= 0 else { throw Failure(message: "无法完整读取所选目录。") }
                defer { close(descriptor) }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, identity(opened) == before,
                      !isCloudPlaceholder(flags: UInt32(opened.st_flags)) else { throw Failure(message: "目录在读取前已被替换或尚未下载到本机。") }
                nodes.append(node)
                let names = try children(descriptor)
                for child in names {
                    try inspect(parentFD: descriptor, name: child, relative: relative.isEmpty ? child : relative + "/" + child, depth: depth + 1)
                }
                var after = stat(), atPath = stat()
                guard fstat(descriptor, &after) == 0, identity(after) == before,
                      after.st_uid == info.st_uid, after.st_gid == info.st_gid, after.st_flags == info.st_flags,
                      try children(descriptor) == names,
                      name.withCString({ fstatat(parentFD, $0, &atPath, AT_SYMLINK_NOFOLLOW) }) == 0, identity(atPath) == before else {
                    throw Failure(message: "目录内容正在变化，已保留。")
                }
            } else if type == S_IFLNK {
                guard package, !relative.isEmpty else { throw Failure(message: "含有符号链接，未跟随或清理链接目标。") }
                var buffer = [CChar](repeating: 0, count: 16_385)
                let count = name.withCString { readlinkat(parentFD, $0, &buffer, 16_384) }
                guard count > 0, count < 16_384 else { throw Failure(message: "包内链接无法核验。") }
                let target = String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard !target.hasPrefix("/"), safeLocalLink(relative: relative, target: target) else {
                    throw Failure(message: "包内存在指向外部的链接，保留整个包。")
                }
                var after = stat()
                guard name.withCString({ fstatat(parentFD, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0, identity(after) == before else { throw Failure(message: "包内链接发生变化。") }
                node.link = target; nodes.append(node)
            } else { throw Failure(message: "包含特殊文件，保留整个项目。") }
        }
        try inspect(parentFD: parent.descriptor, name: url.lastPathComponent, relative: "", depth: 0)
        guard parent.stillAtPath(), parent.entry(url.lastPathComponent) == initial else { throw Failure(message: "核验期间项目位置已变化。") }
        // Length-prefixed fields prevent path/content delimiter ambiguities.
        var aggregate = SHA256()
        func append(_ value: String) { let bytes = Data(value.utf8); var length = UInt64(bytes.count).bigEndian; withUnsafeBytes(of: &length) { aggregate.update(bufferPointer: $0) }; aggregate.update(data: bytes) }
        for node in nodes.sorted(by: { $0.path < $1.path }) {
            append(node.path)
            let identity = node.identity
            for number in [identity.device, identity.inode, identity.sizeBytes, UInt64(bitPattern: identity.modifiedSeconds), UInt64(bitPattern: identity.modifiedNanoseconds), identity.linkCount, UInt64(identity.mode), UInt64(node.owner), UInt64(node.group), UInt64(node.flags)] { append(String(number)) }
            append(node.digest ?? ""); append(node.link ?? "")
        }
        return .init(proof: .init(sha256: aggregate.finalize().map { String(format: "%02x", $0) }.joined(),
                                  entryCount: nodes.count, logicalBytes: logicalBytes, rootIdentity: initial), nodes: nodes, lease: lease)
    }
    private static func safeLocalLink(relative: String, target: String) -> Bool {
        var components = relative.split(separator: "/").dropLast().map(String.init)
        for piece in target.split(separator: "/") {
            if piece == "." { continue }
            if piece == ".." { guard !components.isEmpty else { return false }; components.removeLast() }
            else { components.append(String(piece)) }
        }
        return !components.isEmpty
    }
    private static func children(_ descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw Failure(message: "目录无法枚举。") }
        defer { closedir(stream) }
        rewinddir(stream)
        var values: [String] = []
        errno = 0
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: &item.pointee.d_name) { ptr in ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if name != "." && name != ".." { guard validName(name) else { throw Failure(message: "目录项名称无法核验。") }; values.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw Failure(message: "目录读取未完整结束。") }
        return values.sorted()
    }

    /// Only invoked inside this operation's private, unique quarantine. Every
    /// child is checked against the just-recomputed content snapshot. Cancellation
    /// can leave a partial tree; callers must retain its location as needsReview.
    static func removeVerified(_ url: URL, snapshot: Snapshot, isCancelled: () -> Bool) throws {
        let expected = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.path, $0) })
        var childNames: [String: [String]] = [:]
        for node in snapshot.nodes where !node.path.isEmpty {
            let parts = node.path.split(separator: "/")
            childNames[parts.dropLast().joined(separator: "/"), default: []].append(String(parts.last!))
        }
        for key in childNames.keys { childNames[key]?.sort() }
        let parent = try Directory(url.deletingLastPathComponent())
        guard parent.stillAtPath() else { throw Failure(message: "隔离位置发生变化。") }
        func remove(parentFD: Int32, name: String, relative: String) throws {
            guard !isCancelled(), let node = expected[relative] else { throw Failure(message: isCancelled() ? "已停止，部分内容可能已永久删除。" : "发现未核验的新内容，已停止。") }
            var info = stat()
            guard name.withCString({ fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
                  node.identity == identity(info), UInt32(info.st_uid) == node.owner, UInt32(info.st_gid) == node.group, UInt32(info.st_flags) == node.flags,
                  !isCloudPlaceholder(flags: UInt32(info.st_flags)) else {
                throw Failure(message: "永久删除过程中项目发生变化，已停止。")
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                let descriptor = name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
                guard descriptor >= 0 else { throw Failure(message: "隔离目录无法读取，已停止。") }
                defer { close(descriptor) }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, identity(opened) == node.identity,
                      !isCloudPlaceholder(flags: UInt32(opened.st_flags)) else { throw Failure(message: "隔离目录身份或本地下载状态发生变化。") }
                let names = try children(descriptor)
                let prefix = relative.isEmpty ? "" : relative + "/"
                let planned = childNames[relative] ?? []
                guard names == planned else { throw Failure(message: "隔离目录内容发生变化，已停止。") }
                for child in names { try remove(parentFD: descriptor, name: child, relative: prefix + child) }
                guard !isCancelled(), try children(descriptor).isEmpty else { throw Failure(message: "隔离目录仍有内容，已停止。") }
                var after = stat()
                guard name.withCString({ fstatat(parentFD, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0,
                      after.st_dev == opened.st_dev, after.st_ino == opened.st_ino, after.st_mode == opened.st_mode,
                      !isCloudPlaceholder(flags: UInt32(after.st_flags)), UInt32(after.st_flags) == node.flags,
                      name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) }) == 0 else { throw Failure(message: "目录未能完整移除，保留未完成记录。") }
            } else {
                // Re-hash each regular file immediately before unlinking. Files
                // may still be open elsewhere even after their parent was moved.
                if info.st_mode & S_IFMT == S_IFREG {
                    let descriptor = name.withCString { openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
                    guard descriptor >= 0 else { throw Failure(message: "删除前无法重读内容。") }
                    defer { close(descriptor) }
                    var before = stat()
                    guard fstat(descriptor, &before) == 0, identity(before) == node.identity,
                          !isCloudPlaceholder(flags: UInt32(before.st_flags)) else { throw Failure(message: "删除前文件被替换或已变为云端占位项。") }
                    var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1_048_576)
                    while true {
                        guard !isCancelled() else { throw Failure(message: "已停止，部分内容可能已永久删除。") }
                        var reading = stat()
                        guard fstat(descriptor, &reading) == 0, !isCloudPlaceholder(flags: UInt32(reading.st_flags)) else { throw Failure(message: "文件已变为云端占位项，已停止永久删除。") }
                        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                        if count < 0 { if errno == EINTR { continue }; throw Failure(message: "删除前内容核验失败。") }
                        if count == 0 { break }
                        buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                    }
                    var after = stat(), pathInfo = stat()
                    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == node.digest,
                          fstat(descriptor, &after) == 0, identity(after) == node.identity,
                          name.withCString({ fstatat(parentFD, $0, &pathInfo, AT_SYMLINK_NOFOLLOW) }) == 0, identity(pathInfo) == node.identity else {
                        throw Failure(message: "删除前内容仍在变化，已停止。")
                    }
                }
                guard !isCancelled(), name.withCString({ unlinkat(parentFD, $0, 0) }) == 0 else { throw Failure(message: "文件未能移除，保留未完成记录。") }
            }
        }
        try remove(parentFD: parent.descriptor, name: url.lastPathComponent, relative: "")
        guard parent.stillAtPath(), parent.entry(url.lastPathComponent) == nil else { throw Failure(message: "删除后位置核验未通过。") }
    }
}
