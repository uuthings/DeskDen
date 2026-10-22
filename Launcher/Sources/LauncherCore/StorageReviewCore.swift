import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum StorageReviewScopeKind: String, Codable, Equatable, Sendable {
    /// The app must obtain the user's explicit directory choice before constructing a scope.
    case rebuildableCache, diagnosticRecords, userSelected
}
public struct StorageReviewScope: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var directory: URL
    public var kind: StorageReviewScopeKind
    public init(id: UUID = UUID(), directory: URL, kind: StorageReviewScopeKind) {
        self.id = id; self.directory = directory; self.kind = kind
    }
}
public enum StorageReviewCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case cacheCandidate, oldDiagnostic, recentDiagnostic, personalFile, symbolicLink, applicationPackage, unsupported
}
public enum StorageReviewDisposition: String, Codable, Equatable, Sendable { case requiresReview, retain }
public enum StorageReviewStage: String, Codable, Equatable, Sendable { case scanning, report, cancelled, failed }

/// A path is only a location. Device, inode, change time and content metadata form the identity check.
public struct StorageReviewFileIdentity: Codable, Equatable, Hashable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var sizeBytes: UInt64
    public var allocatedBytes: UInt64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    public var changedSeconds: Int64
    public var changedNanoseconds: Int64
    public var linkCount: UInt64
    public var mode: UInt32
    public var fileKey: String { "\(device):\(inode)" }
}

/// Evidence is produced only while processing explicitly selected regular files.
/// It stores a digest and security metadata, never file contents.
public struct StorageReviewContentProof: Codable, Equatable, Sendable {
    public var sha256: String
    public var ownerID: UInt32
    public var groupID: UInt32
    public var flags: UInt32
    public var isValid: Bool { sha256.utf8.count == 64 && sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

public enum StorageReviewContentError: Error { case unavailable, changed, cancelled }

/// Holds the same opened resource across a rename. A later Trash path may not
/// be readable under macOS access protection even though this lease is readable.
public final class StorageReviewContentLease {
    private let descriptor: Int32
    public let openedIdentity: StorageReviewFileIdentity
    private let ownerID: UInt32
    private let groupID: UInt32
    private let flags: UInt32
    fileprivate init(descriptor: Int32, info: stat, identity: StorageReviewFileIdentity) {
        self.descriptor=descriptor;openedIdentity=identity;ownerID=UInt32(info.st_uid);groupID=UInt32(info.st_gid)
        #if canImport(Darwin)
        flags=UInt32(info.st_flags)
        #else
        flags=0
        #endif
    }
    deinit { close(descriptor) }
    public func currentIdentity() -> StorageReviewFileIdentity? {
        var info=stat()
        guard fstat(descriptor,&info) == 0, info.st_uid == ownerID, info.st_gid == groupID else {return nil}
        #if canImport(Darwin)
        guard UInt32(info.st_flags) == flags else {return nil}
        #endif
        return StorageReviewScanner.identity(info:info)
    }
    public func matchesPath(_ url:URL)->Bool {
        guard let current=currentIdentity() else {return false}
        return StorageReviewIdentityValidator.captureRegularFileIdentity(at:url) == current
    }
    /// Each read is bounded, cancellation-aware, and checked against the same
    /// descriptor before/after. Metadata is required to stay still while hashing.
    public func contentProof(isCancelled:()->Bool={false},onRead:(UInt64)->Void={_ in}) throws -> StorageReviewContentProof {
        guard !isCancelled() else {throw StorageReviewContentError.cancelled}
        guard let before=currentIdentity(),openedIdentity.matchesContentResource(before),lseek(descriptor,0,SEEK_SET) == 0 else {throw StorageReviewContentError.changed}
        var hash=SHA256(),buffer=[UInt8](repeating:0,count:1_048_576),total:UInt64=0
        while true {
            guard !isCancelled() else {throw StorageReviewContentError.cancelled}
            let count=buffer.withUnsafeMutableBytes{read(descriptor,$0.baseAddress,$0.count)}
            if count < 0 {if errno == EINTR {continue};throw StorageReviewContentError.unavailable}
            if count == 0 {break}
            let sum=total.addingReportingOverflow(UInt64(count))
            guard !sum.overflow,sum.partialValue <= before.sizeBytes else {throw StorageReviewContentError.changed}
            total=sum.partialValue
            buffer.withUnsafeBytes{hash.update(bufferPointer:UnsafeRawBufferPointer(rebasing:$0[..<count]))}
            onRead(total)
        }
        guard !isCancelled() else {throw StorageReviewContentError.cancelled}
        guard total == before.sizeBytes,currentIdentity() == before else {throw StorageReviewContentError.changed}
        return .init(sha256:hash.finalize().map{String(format:"%02x",$0)}.joined(),ownerID:ownerID,groupID:groupID,flags:flags)
    }
}

public struct StorageReviewCandidate: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var scopeID: UUID
    public var relativePath: String
    public var category: StorageReviewCategory
    public var disposition: StorageReviewDisposition
    public var explanation: String
    public var identity: StorageReviewFileIdentity
    /// These are scanned logical bytes. They are never labelled actual reclaimed disk space.
    public var logicalBytes: UInt64 { category == .symbolicLink || category == .applicationPackage ? 0 : identity.sizeBytes }
}
public struct StorageReviewIssue: Codable, Equatable, Sendable {
    public var scopeID: UUID
    public var relativePath: String
    public var reason: String
}
public struct StorageReviewScopeRecord: Codable, Equatable, Sendable {
    public var scope: StorageReviewScope
    public var canonicalDirectory: URL
    public var directoryIdentity: StorageReviewFileIdentity
}
public struct StorageReviewProgress: Equatable, Sendable {
    public var checkedEntries: Int
    public var recordedFiles: Int
    public var logicalBytes: UInt64
    public var currentScopeID: UUID?
    public var currentRelativePath: String?
}
public struct StorageReviewReport: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var scannedAt: Date
    public var finishedAt: Date
    public var ruleVersion: String
    public var stage: StorageReviewStage
    public var scopes: [StorageReviewScopeRecord]
    public var candidates: [StorageReviewCandidate]
    public var issues: [StorageReviewIssue]
    public var checkedEntries: Int
    public var reachedLimit: Bool
    public var logicalBytes: UInt64 { candidates.reduce(0) { Self.add($0, $1.logicalBytes) } }
    public var reviewableLogicalBytes: UInt64 { candidates.filter { $0.disposition == .requiresReview }.reduce(0) { Self.add($0, $1.logicalBytes) } }
    public func candidates(in category: StorageReviewCategory) -> [StorageReviewCandidate] { candidates.filter { $0.category == category } }
    private static func add(_ left: UInt64, _ right: UInt64) -> UInt64 { let result = left.addingReportingOverflow(right); return result.overflow ? .max : result.partialValue }
}
public struct StorageReviewOptions: Equatable, Sendable {
    public var maximumEntries: Int
    public var maximumDepth: Int
    public var diagnosticMinimumAge: TimeInterval
    public init(maximumEntries: Int = 100_000, maximumDepth: Int = 32, diagnosticMinimumAge: TimeInterval = 30 * 86_400) {
        self.maximumEntries = min(1_000_000, max(1, maximumEntries)); self.maximumDepth = min(128, max(1, maximumDepth))
        self.diagnosticMinimumAge = diagnosticMinimumAge.isFinite ? max(0, diagnosticMinimumAge) : 30 * 86_400
    }
}
public enum StorageReviewError: LocalizedError, Equatable {
    case noScopes, invalidScope, invalidReport, selectionEmpty, selectionInvalid
    public var errorDescription: String? {
        switch self {
        case .noScopes: "请先明确选择检查范围。"
        case .invalidScope: "检查范围必须是可读取的本机目录，且不能是系统根目录。"
        case .invalidReport: "检查尚未完整结束，请重新检查后复核。"
        case .selectionEmpty: "尚未选择要移到废纸篓的文件。"
        case .selectionInvalid: "所选文件不在可复核清单中。"
        }
    }
}

public enum StorageReviewScanner {
    public static let ruleVersion = "2026-10-21.1"
    /// Validate only the explicitly supplied directory's metadata. This never
    /// enumerates it; UI registration and scanning share exactly the same policy.
    public static func validatedScope(_ scope: StorageReviewScope) throws -> StorageReviewScopeRecord {
        guard scope.directory.isFileURL, let path = canonicalPath(scope.directory) else { throw StorageReviewError.invalidScope }
        let canonical = URL(fileURLWithPath: path, isDirectory: true)
        guard canonical.path != "/", !forbiddenSystemRoot(canonical.path), !isPackage(canonical),
              let directory = identity(at: canonical), isDirectory(directory), !isSymbolicLink(directory) else {
            throw StorageReviewError.invalidScope
        }
        return .init(scope: scope, canonicalDirectory: canonical, directoryIdentity: directory)
    }
    /// Synchronous so callers choose their task/queue. It reads only explicitly supplied directories.
    /// No file is auto-selected or deleted, and symlinks and packages are never traversed.
    public static func scan(scopes: [StorageReviewScope], options: StorageReviewOptions = .init(), now: Date = Date(),
                            isCancelled: () -> Bool = { false },
                            progress: (StorageReviewProgress) -> Void = { _ in }) throws -> StorageReviewReport {
        guard !scopes.isEmpty else { throw StorageReviewError.noScopes }
        guard Set(scopes.map(\.id)).count == scopes.count, now.timeIntervalSince1970.isFinite else { throw StorageReviewError.invalidScope }
        let manager = FileManager.default
        var report = StorageReviewReport(id: UUID(), scannedAt: now, finishedAt: now, ruleVersion: ruleVersion,
                                         stage: .scanning, scopes: [], candidates: [], issues: [], checkedEntries: 0, reachedLimit: false)
        let options = StorageReviewOptions(maximumEntries: options.maximumEntries, maximumDepth: options.maximumDepth,
                                           diagnosticMinimumAge: options.diagnosticMinimumAge)
        var seenFiles = Set<String>()
        var recordedBytes: UInt64 = 0
        var cancelled = false
        for scope in scopes {
            if isCancelled() { cancelled = true; break }
            guard scope.directory.isFileURL else { throw StorageReviewError.invalidScope }
            guard let record = try? validatedScope(scope) else {
                report.issues.append(.init(scopeID: scope.id, relativePath: "", reason: "范围不是可读取的普通目录，或属于受保护的系统范围。")); continue
            }
            let canonical = record.canonicalDirectory
            if report.scopes.contains(where: { contains(canonical.path, in: $0.canonicalDirectory.path) || contains($0.canonicalDirectory.path, in: canonical.path) }) {
                report.issues.append(.init(scopeID: scope.id, relativePath: "", reason: "与另一个范围重叠，本次未重复扫描。")); continue
            }
            report.scopes.append(record)
            var stack: [(URL, Int)] = [(canonical, 0)]
            while let (directory, depth) = stack.popLast() {
                if isCancelled() { cancelled = true; break }
                // Re-resolve before each directory read in case a directory has become a symlink.
                guard Self.canonicalPath(directory) == directory.path,
                      contains(directory.path, in: canonical.path), let current = Self.identity(at: directory), isDirectory(current), !isSymbolicLink(current) else {
                    report.issues.append(.init(scopeID: scope.id, relativePath: relative(directory, root: canonical), reason: "目录已变化或越过所选范围，已跳过。")); continue
                }
                let children: [URL]
                do { children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent } }
                catch { report.issues.append(.init(scopeID: scope.id, relativePath: relative(directory, root: canonical), reason: "无法读取目录：\(error.localizedDescription)")); continue }
                for listedChild in children {
                    // Foundation may return /private/var URLs for a /var parent. Re-anchor the name
                    // to the POSIX canonical directory rather than mixing either path spelling.
                    let child = directory.appendingPathComponent(listedChild.lastPathComponent)
                    if isCancelled() { cancelled = true; break }
                    guard report.checkedEntries < options.maximumEntries else { report.reachedLimit = true; break }
                    report.checkedEntries += 1
                    if report.checkedEntries == options.maximumEntries { report.reachedLimit = true }
                    let relativePath = relative(child, root: canonical)
                    guard let file = Self.identity(at: child) else {
                        report.issues.append(.init(scopeID: scope.id, relativePath: relativePath, reason: "文件已消失或无法读取元数据。")); continue
                    }
                    if isDirectory(file) && !isSymbolicLink(file) {
                        if isPackage(child) {
                            report.candidates.append(candidate(scope: scope, path: relativePath, identity: file, category: .applicationPackage, disposition: .retain,
                                                               explanation: "应用或文稿包默认保留，不读取内部内容。"))
                        } else if depth < options.maximumDepth {
                            stack.append((child, depth + 1))
                        } else {
                            report.issues.append(.init(scopeID: scope.id, relativePath: relativePath, reason: "已到达本次检查的目录深度上限。")); report.reachedLimit = true
                        }
                    } else if isSymbolicLink(file) {
                        report.candidates.append(candidate(scope: scope, path: relativePath, identity: file, category: .symbolicLink, disposition: .retain,
                                                           explanation: "符号链接默认保留，未读取链接目标。"))
                    } else if isRegularFile(file) {
                        guard seenFiles.insert(file.fileKey).inserted else {
                            report.issues.append(.init(scopeID: scope.id, relativePath: relativePath, reason: "相同文件身份已记录，不重复计算大小。")); continue
                        }
                        let classification = classify(scope: scope, url: child, identity: file, at: now, options: options)
                        report.candidates.append(candidate(scope: scope, path: relativePath, identity: file, category: classification.0,
                                                           disposition: classification.1, explanation: classification.2))
                        let added = recordedBytes.addingReportingOverflow(file.sizeBytes)
                        recordedBytes = added.overflow ? .max : added.partialValue
                    } else {
                        report.issues.append(.init(scopeID: scope.id, relativePath: relativePath, reason: "特殊文件默认保留。"))
                    }
                    progress(.init(checkedEntries: report.checkedEntries, recordedFiles: report.candidates.count, logicalBytes: recordedBytes,
                                   currentScopeID: scope.id, currentRelativePath: relativePath))
                }
                if cancelled || report.checkedEntries >= options.maximumEntries { break }
            }
            if cancelled || report.checkedEntries >= options.maximumEntries { break }
        }
        report.stage = cancelled ? .cancelled : report.scopes.isEmpty ? .failed : .report
        let finished = Date()
        report.finishedAt = finished >= now ? finished : now
        progress(.init(checkedEntries: report.checkedEntries, recordedFiles: report.candidates.count, logicalBytes: recordedBytes,
                       currentScopeID: nil, currentRelativePath: nil))
        return report
    }
    private static func candidate(scope: StorageReviewScope, path: String, identity: StorageReviewFileIdentity, category: StorageReviewCategory,
                                  disposition: StorageReviewDisposition, explanation: String) -> StorageReviewCandidate {
        .init(id: UUID(), scopeID: scope.id, relativePath: path, category: category, disposition: disposition, explanation: explanation, identity: identity)
    }
    private static func classify(scope: StorageReviewScope, url: URL, identity: StorageReviewFileIdentity, at date: Date, options: StorageReviewOptions) -> (StorageReviewCategory, StorageReviewDisposition, String) {
        if identity.linkCount > 1 { return (.personalFile, .retain, "文件存在多个硬链接，默认保留；移除一个路径不代表释放相同空间。") }
        switch scope.kind {
        case .rebuildableCache:
            return (.cacheCandidate, .requiresReview, "来自你选定的缓存范围；需逐项确认归属与可重建性，未确认文件是否正在使用。")
        case .diagnosticRecords:
            let extensions: Set<String> = ["log", "crash", "ips", "diag", "trace"]
            guard extensions.contains(url.pathExtension.lowercased()) else { return (.personalFile, .retain, "不符合诊断记录类型，默认保留。") }
            let age = date.timeIntervalSince1970 - Double(identity.modifiedSeconds) - Double(identity.modifiedNanoseconds) / 1_000_000_000
            return age >= options.diagnosticMinimumAge
                ? (.oldDiagnostic, .requiresReview, "达到选定保留期限的诊断记录；排查历史问题时建议保留，删除仍需逐项确认。")
                : (.recentDiagnostic, .retain, "尚未达到诊断记录保留期限，默认保留。")
        case .userSelected:
            return (.personalFile, .retain, "用户文件默认保留，不凭文件名判断可删除性。")
        }
    }
    fileprivate static func contains(_ path: String, in root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    fileprivate static func canonicalPath(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { input in
            guard let input, let resolved = realpath(input, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
    private static func forbiddenSystemRoot(_ path: String) -> Bool {
        ["/System", "/bin", "/sbin", "/usr", "/dev", "/private/etc", "/private/var/db"].contains { contains(path, in: $0) }
    }
    private static func relative(_ url: URL, root: URL) -> String { String(url.path.dropFirst(root.path.count + 1)) }
    private static func isPackage(_ url: URL) -> Bool {
        if ["app", "bundle", "framework", "plugin", "photoslibrary", "photolibrary", "rtfd", "pages", "numbers", "key"].contains(url.pathExtension.lowercased()) { return true }
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
    fileprivate static func isDirectory(_ value: StorageReviewFileIdentity) -> Bool { value.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    fileprivate static func isRegularFile(_ value: StorageReviewFileIdentity) -> Bool { value.mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
    fileprivate static func isSymbolicLink(_ value: StorageReviewFileIdentity) -> Bool { value.mode & UInt32(S_IFMT) == UInt32(S_IFLNK) }
    fileprivate static func identity(at url: URL) -> StorageReviewFileIdentity? {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ value in value.map { lstat($0, &info) } ?? -1 }) == 0 else {return nil}
        return identity(info:info)
    }
    fileprivate static func identity(info:stat) -> StorageReviewFileIdentity? {
        guard info.st_size >= 0, info.st_blocks >= 0 else { return nil }
        #if canImport(Darwin)
        let modified = info.st_mtimespec, changed = info.st_ctimespec
        #else
        let modified = info.st_mtim, changed = info.st_ctim
        #endif
        let allocated = UInt64(info.st_blocks).multipliedReportingOverflow(by: 512)
        return .init(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino), sizeBytes: UInt64(info.st_size),
                     allocatedBytes: allocated.overflow ? .max : allocated.partialValue,
                     modifiedSeconds: Int64(modified.tv_sec), modifiedNanoseconds: Int64(modified.tv_nsec),
                     changedSeconds: Int64(changed.tv_sec), changedNanoseconds: Int64(changed.tv_nsec),
                     linkCount: UInt64(info.st_nlink), mode: UInt32(info.st_mode))
    }
}

public enum StorageReviewRevalidation: String, Codable, Equatable, Sendable {
    case unchanged, missing, scopeChanged, outsideScope, symbolicLink, changed, notRegularFile
}
public enum StorageReviewIdentityValidator {
    /// No symbolic component may be followed on macOS. fstat and the final path
    /// comparison bind the read to the selected resource, not merely its name.
    public static func openContent(at url:URL,expected:StorageReviewFileIdentity,allowChangedTime:Bool=false) throws -> StorageReviewContentLease {
        // Foundation can rewrite /private/var URLs to the /var alias. Resolve
        // that spelling with POSIX, then open without following any components.
        // The original leaf must still be regular and point to this same fd.
        guard url.isFileURL,captureRegularFileIdentity(at:url) != nil,
              let path=StorageReviewScanner.canonicalPath(url) else {throw StorageReviewContentError.unavailable}
        #if canImport(Darwin)
        let flags=O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY
        #else
        let flags=O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW
        #endif
        let descriptor=path.withCString{open($0,flags)}
        guard descriptor >= 0 else {throw StorageReviewContentError.unavailable}
        var info=stat()
        guard fstat(descriptor,&info) == 0,let actual=StorageReviewScanner.identity(info:info),
              StorageReviewScanner.isRegularFile(actual),actual.linkCount == 1,
              allowChangedTime ? expected.matchesContentResource(actual):expected == actual,
              captureRegularFileIdentity(at:url) == actual else {close(descriptor);throw StorageReviewContentError.changed}
        return StorageReviewContentLease(descriptor:descriptor,info:info,identity:actual)
    }
    public static func contentMatches(at url:URL,expected:StorageReviewFileIdentity,proof:StorageReviewContentProof,isCancelled:()->Bool={false})->Bool {
        guard proof.isValid,!isCancelled(),let lease=try? openContent(at:url,expected:expected,allowChangedTime:true),
              let actual=try? lease.contentProof(isCancelled:isCancelled),actual == proof else {return false}
        return lease.matchesPath(url)
    }
    /// Capture the OS-returned trash item for a later restore. This does not approve any action.
    public static func captureRegularFileIdentity(at url: URL) -> StorageReviewFileIdentity? {
        guard url.isFileURL, let identity = StorageReviewScanner.identity(at: url),
              StorageReviewScanner.isRegularFile(identity), !StorageReviewScanner.isSymbolicLink(identity) else { return nil }
        return identity
    }
    /// Run immediately before requesting a recoverable trash operation. A prior match is not a lease.
    public static func validate(_ candidate: StorageReviewCandidate, scope: StorageReviewScopeRecord) -> StorageReviewRevalidation {
        guard candidate.scopeID == scope.scope.id, candidate.relativePath != "", !candidate.relativePath.hasPrefix("/"),
              !candidate.relativePath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return .outsideScope }
        // Foundation.standardizedFileURL can rewrite /private/var back to /var on macOS.
        // Retain the POSIX canonical spelling used during the scan.
        let root = scope.canonicalDirectory
        guard StorageReviewScanner.canonicalPath(root) == root.path,
              let directory = StorageReviewScanner.identity(at: root), StorageReviewScanner.isDirectory(directory),
              directory.device == scope.directoryIdentity.device, directory.inode == scope.directoryIdentity.inode else { return .scopeChanged }
        let target = root.appendingPathComponent(candidate.relativePath)
        guard StorageReviewScanner.contains(target.path, in: root.path), target.path != root.path else { return .outsideScope }
        let parent = target.deletingLastPathComponent()
        guard StorageReviewScanner.canonicalPath(parent) == parent.path,
              StorageReviewScanner.contains(parent.path, in: root.path) else { return .outsideScope }
        guard let current = StorageReviewScanner.identity(at: target) else { return .missing }
        guard !StorageReviewScanner.isSymbolicLink(current) else { return .symbolicLink }
        guard StorageReviewScanner.canonicalPath(target) == target.path else { return .outsideScope }
        guard StorageReviewScanner.isRegularFile(current) else { return .notRegularFile }
        return current == candidate.identity ? .unchanged : .changed
    }
    public static func fileURL(_ candidate: StorageReviewCandidate, scope: StorageReviewScopeRecord) -> URL? {
        guard validate(candidate, scope: scope) == .unchanged else { return nil }
        return scope.canonicalDirectory.appendingPathComponent(candidate.relativePath)
    }
}

/// This is a selection awaiting a distinct UI confirmation. Constructing it performs no filesystem writes.
public struct StorageReviewTrashPlan: Codable, Equatable, Sendable {
    public var reportID: UUID
    public var selectedCandidateIDs: [UUID]
    public var logicalBytes: UInt64
    public init(report: StorageReviewReport, selectedCandidateIDs: Set<UUID>) throws {
        guard report.stage == .report, !report.reachedLimit, report.ruleVersion == StorageReviewScanner.ruleVersion else { throw StorageReviewError.invalidReport }
        guard !selectedCandidateIDs.isEmpty else { throw StorageReviewError.selectionEmpty }
        let selected = report.candidates.filter { selectedCandidateIDs.contains($0.id) }
        guard selected.count == selectedCandidateIDs.count, selected.allSatisfy({ $0.disposition == .requiresReview }) else { throw StorageReviewError.selectionInvalid }
        reportID = report.id; self.selectedCandidateIDs = selected.map(\.id)
        logicalBytes = selected.reduce(0) { partial, file in let sum = partial.addingReportingOverflow(file.logicalBytes); return sum.overflow ? .max : sum.partialValue }
    }
}

public enum StorageReviewActionState: String, Codable, Equatable, Sendable { case trashed, skipped, failed, cancelled }
public struct StorageReviewActionResult: Codable, Equatable, Sendable {
    public var candidateID: UUID
    public var state: StorageReviewActionState
    public var reason: String
    public var trashURL: URL?
    /// A successful AppKit trash request supplies its actual resulting location. No synthetic success.
    public init(candidateID: UUID, trashURL: URL) {
        self.candidateID = candidateID; state = .trashed; reason = "已移到废纸篓，可从废纸篓恢复。"; self.trashURL = trashURL
    }
    public init(candidateID: UUID, state: StorageReviewActionState, reason: String) {
        self.candidateID = candidateID; self.state = state == .trashed ? .failed : state
        self.reason = state == .trashed ? "缺少废纸篓位置，不能确认处理成功。" : reason; trashURL = nil
    }
}
