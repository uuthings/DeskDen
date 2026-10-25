import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SpaceCleaningGroup: String, Codable, CaseIterable, Sendable { case rebuildable, review, protected }
public enum SpaceCleaningKind: String, Codable, CaseIterable, Sendable {
    case browserCache, packageCache, derivedData, oldDiagnostic, recentDiagnostic
    case downloadedFile, installerPackage, downloadedDiskImage, developmentFile, personalFile, testApplication, testArchive
    case unknownApplication, unknownArchive, releaseArchive, releaseMaterial, installedApplication
    case symbolicLink, hardLink, package, runningApplication, cloudPlaceholder, unsupported, developmentEnvironment
}
public enum SpaceCleaningScopeKind: String, Codable, Sendable {
    case browserCache, packageCache, derivedData, diagnostics, downloads, development, archives
    case releaseArchives, releaseArchiveDiscovery, installedApplications, custom
}
public enum SpaceCleaningScanPhase: String, Sendable { case discovering, verifying, finished }
public enum SpaceCleaningStage: String, Codable, Sendable { case caches, development, downloads, protection, complete, cancelled, failed }
public enum SpaceCleaningIssueKind: String, Codable, Sendable {
    case missing, permissionDenied, unreadable, unsafePath, changed, duplicate, depthLimit, entryLimit, cloudPlaceholder, cancelled
}
public struct SpaceCleaningScope: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var directory: URL
    public var kind: SpaceCleaningScopeKind
    public var title: String
    public init(id: UUID = UUID(), directory: URL, kind: SpaceCleaningScopeKind = .custom, title: String = "自选目录") {
        self.id = id; self.directory = directory; self.kind = kind; self.title = title
    }
}
public struct SpaceCleaningPathIdentity: Codable, Equatable, Sendable {
    public var url: URL
    public var identity: StorageReviewFileIdentity
    public init(url: URL, identity: StorageReviewFileIdentity) { self.url = url; self.identity = identity }
}
/// A declaration is bound to the exact reviewed object, including package contents.
/// Its existence does not override release protection, running applications or unsafe entries.
public struct SpaceCleaningTestDeclaration: Codable, Equatable, Sendable {
    public var url: URL
    public var identity: StorageReviewFileIdentity
    public var treeFingerprint: String?
    public init(url: URL, identity: StorageReviewFileIdentity, treeFingerprint: String?) {
        self.url = url; self.identity = identity; self.treeFingerprint = treeFingerprint
    }
    public init(candidate: SpaceCleaningCandidate) {
        self.init(url: candidate.url, identity: candidate.identity, treeFingerprint: candidate.treeFingerprint)
    }
}
public struct SpaceCleaningContext: Sendable {
    public var homeDirectory: URL
    public var runningApplicationURLs: [URL]
    public var protectedReleaseURLs: [URL]
    public var testDeclarations: [SpaceCleaningTestDeclaration]
    public var activeToolNames: Set<String>
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                runningApplicationURLs: [URL] = [], protectedReleaseURLs: [URL] = [],
                testDeclarations: [SpaceCleaningTestDeclaration] = [], activeToolNames: Set<String> = []) {
        self.homeDirectory = homeDirectory; self.runningApplicationURLs = runningApplicationURLs
        self.protectedReleaseURLs = protectedReleaseURLs; self.testDeclarations = testDeclarations
        self.activeToolNames = activeToolNames
    }
}
public enum SpaceCleaningScanMode: String, Codable, CaseIterable, Sendable { case cleanup, largeFiles }
public struct SpaceCleaningOptions: Equatable, Sendable {
    public var maximumEntries: Int
    public var maximumDepth: Int
    public var diagnosticMinimumAge: TimeInterval
    public var mode: SpaceCleaningScanMode
    public var minimumFileBytes: UInt64
    public var maximumFileBytes: UInt64?
    public init(maximumEntries: Int = 100_000, maximumDepth: Int = 32, diagnosticMinimumAge: TimeInterval = 30 * 86_400,
                mode: SpaceCleaningScanMode = .cleanup, minimumFileBytes: UInt64 = 100_000_000, maximumFileBytes: UInt64? = nil) {
        self.maximumEntries = min(1_000_000, max(1, maximumEntries))
        self.maximumDepth = min(128, max(1, maximumDepth))
        self.diagnosticMinimumAge = diagnosticMinimumAge.isFinite ? max(0, diagnosticMinimumAge) : 30 * 86_400
        let minimum = max(1, minimumFileBytes)
        self.mode = mode; self.minimumFileBytes = minimum
        self.maximumFileBytes = maximumFileBytes.map { max(minimum, $0) }
    }
}
public struct SpaceCleaningCandidate: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var scopeID: UUID
    public var url: URL
    public var rootURL: URL
    public var rootIdentity: StorageReviewFileIdentity
    public var identity: StorageReviewFileIdentity
    public var ancestorIdentities: [SpaceCleaningPathIdentity]
    public var kind: SpaceCleaningKind
    public var group: SpaceCleaningGroup
    public var title: String
    public var reason: String
    public var impact: String
    public var logicalBytes: UInt64
    public var allocatedBytes: UInt64
    public var isDirectory: Bool
    public var canConfirmTestPurpose: Bool
    public var treeFingerprint: String?
    public var sizeIsComplete: Bool
    public var canProcess: Bool { group != .protected && sizeIsComplete }
    /// Default selection requires positive reconstruction evidence, not just an
    /// age threshold or permission to delete. Personal and diagnostic files stay manual.
    public var isRecommendedForSelection: Bool {
        canProcess && group == .rebuildable && [.browserCache, .packageCache, .derivedData].contains(kind)
    }
    /// Useful cleanup candidates can require a user's choice. Recognizing an
    /// installer or download image does not establish that installation finished.
    public var isCleanupSuggestion: Bool {
        guard canProcess else { return false }
        return isRecommendedForSelection ||
            (group == .review && [.installerPackage, .downloadedDiskImage].contains(kind)) ||
            (group == .rebuildable && kind == .oldDiagnostic)
    }
    public init(id: UUID = UUID(), scopeID: UUID = UUID(), url: URL, rootURL: URL,
                rootIdentity: StorageReviewFileIdentity, identity: StorageReviewFileIdentity,
                ancestorIdentities: [SpaceCleaningPathIdentity] = [], kind: SpaceCleaningKind,
                group: SpaceCleaningGroup, title: String, reason: String, impact: String,
                logicalBytes: UInt64, allocatedBytes: UInt64, isDirectory: Bool,
                canConfirmTestPurpose: Bool = false, treeFingerprint: String? = nil, sizeIsComplete: Bool = true) {
        self.id = id; self.scopeID = scopeID; self.url = url; self.rootURL = rootURL
        self.rootIdentity = rootIdentity; self.identity = identity; self.ancestorIdentities = ancestorIdentities
        self.kind = kind; self.group = group; self.title = title; self.reason = reason; self.impact = impact
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes; self.isDirectory = isDirectory
        self.canConfirmTestPurpose = canConfirmTestPurpose; self.treeFingerprint = treeFingerprint; self.sizeIsComplete = sizeIsComplete
    }
}
public struct SpaceCleaningIssue: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var scopeID: UUID
    public var url: URL
    public var kind: SpaceCleaningIssueKind
    public var reason: String
    public init(id: UUID = UUID(), scopeID: UUID, url: URL, kind: SpaceCleaningIssueKind, reason: String) {
        self.id = id; self.scopeID = scopeID; self.url = url; self.kind = kind; self.reason = reason
    }
}
public struct SpaceCleaningProgress: Equatable, Sendable {
    public var stage: SpaceCleaningStage
    public var currentScopeID: UUID?
    public var currentPath: String?
    public var currentFileName: String?
    public var checkedEntries: Int
    public var recordedCandidates: Int
    public var logicalBytes: UInt64
    public var completedScopes: Int
    public var totalScopes: Int
    public var phase: SpaceCleaningScanPhase = .discovering
    public var completedItems: Int = 0
    public var totalItems: Int? = nil
}
public struct SpaceCleaningReport: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var scannedAt: Date
    public var finishedAt: Date
    public var ruleVersion: String
    public var scopes: [SpaceCleaningScope]
    public var candidates: [SpaceCleaningCandidate]
    public var issues: [SpaceCleaningIssue]
    public var stage: SpaceCleaningStage
    /// The run ended normally within its bounds. Coverage exceptions remain separately visible.
    public var complete: Bool
    public var coverageComplete: Bool
    public var reachedLimit: Bool
    public var checkedEntries: Int
    public var logicalBytes: UInt64 { candidates.reduce(0) { saturatingAdd($0, $1.logicalBytes) } }
    public var allocatedBytes: UInt64 { candidates.reduce(0) { saturatingAdd($0, $1.allocatedBytes) } }
    public func candidates(in group: SpaceCleaningGroup) -> [SpaceCleaningCandidate] { candidates.filter { $0.group == group } }
}
public enum SpaceCleaningValidation: String, Codable, Equatable, Sendable {
    case unchanged, missing, changed, scopeChanged, protected, incomplete, cancelled
}

public enum SpaceCleaningScanner {
    public static let ruleVersion = "2026-10-25.1"

    public static func developmentProtectionReason(at url: URL) -> String? {
        SpaceCleaningDevelopmentPolicy.reason(at: url)
    }

    /// Known locations are explicit. This never makes the home directory a cache scope.
    public static func recommendedScopes(context: SpaceCleaningContext = .init()) -> [SpaceCleaningScope] {
        let home = canonicalURL(context.homeDirectory) ?? context.homeDirectory
        let definitions: [(String, SpaceCleaningScopeKind, String)] = [
            ("Library/Caches/com.apple.Safari", .browserCache, "Safari 缓存"),
            ("Library/Containers/com.apple.Safari/Data/Library/Caches", .browserCache, "Safari 沙盒缓存"),
            ("Library/Caches/Google/Chrome", .browserCache, "Chrome 缓存"),
            ("Library/Caches/Firefox/Profiles", .browserCache, "Firefox 缓存"),
            (".npm/_cacache", .packageCache, "npm 下载缓存"),
            ("Library/Caches/Homebrew", .packageCache, "Homebrew 下载缓存"),
            ("Library/Caches/pip", .packageCache, "pip 下载缓存"),
            ("Library/Caches/org.swift.swiftpm", .packageCache, "Swift Package 缓存"),
            ("Library/Caches", .browserCache, "其他应用缓存复核"),
            ("Library/Logs/DiagnosticReports", .diagnostics, "诊断记录"),
            ("Library/Developer/Xcode/DerivedData", .derivedData, "Xcode 构建缓存"),
            ("Developer/Builds", .development, "本地开发构建"),
            ("Downloads", .downloads, "下载文件"),
            ("Library/Developer/Xcode/Archives", .archives, "Xcode 归档"),
            ("Library/Application Support", .releaseArchiveDiscovery, "发布档案核验")
        ]
        var scopes = definitions.map { SpaceCleaningScope(directory: home.appendingPathComponent($0.0), kind: $0.1, title: $0.2) }
        for protected in context.protectedReleaseURLs {
            if let identity = captureIdentity(at: protected), isDirectory(identity), !["app", "xcarchive"].contains(protected.pathExtension.lowercased()) {
                scopes.append(.init(directory: protected, kind: .releaseArchives, title: "受保护发布档案"))
            }
        }
        return scopes
    }

    /// One default pass across known cleanup locations and the user's personal
    /// folders. System data, other users and mounted volumes require separate consent.
    public static func globalScopes(context: SpaceCleaningContext = .init()) -> [SpaceCleaningScope] {
        let home = canonicalURL(context.homeDirectory) ?? context.homeDirectory
        var scopes = recommendedScopes(context: context)
        for name in ["Desktop", "Documents", "Movies", "Pictures", "Music", "Public", "Developer", "Applications"] {
            scopes.append(.init(directory: home.appendingPathComponent(name),
                                kind: name == "Applications" ? .installedApplications : .custom, title: name))
        }
        return scopes
    }

    /// Synchronous and read-only. Callers select their own executor and cancellation source.
    public static func scan(scopes: [SpaceCleaningScope], context: SpaceCleaningContext = .init(),
                            options: SpaceCleaningOptions = .init(), now: Date = Date(),
                            isCancelled: () -> Bool = { false },
                            progress: (SpaceCleaningProgress) -> Void = { _ in }) -> SpaceCleaningReport {
        scan(scopes: scopes, context: context, options: options, now: now, metadata: .live, isCancelled: isCancelled, progress: progress)
    }

    /// Internal metadata seam keeps cloud-placeholder tests independent of a cloud account.
    /// Tests supply metadata, never set filesystem cloud flags or materialize placeholder content.
    static func scan(scopes: [SpaceCleaningScope], context: SpaceCleaningContext, options: SpaceCleaningOptions = .init(),
                     now: Date = Date(), metadata: SpaceCleaningMetadataReader,
                     isCancelled: () -> Bool = { false }, progress: (SpaceCleaningProgress) -> Void = { _ in }) -> SpaceCleaningReport {
        withoutActuallyEscaping(isCancelled) { cancellation in
            withoutActuallyEscaping(progress) { updates in
                let worker = Worker(context: context, options: options, now: now, metadata: metadata, cancelled: cancellation, progress: updates)
                return worker.scan(scopes)
            }
        }
    }

    /// Recompute current policy and the complete directory snapshot immediately before processing.
    /// A successful result is a check, not a filesystem lease; the transaction must still bind its operation.
    public static func revalidate(candidate: SpaceCleaningCandidate, context: SpaceCleaningContext,
                                  options: SpaceCleaningOptions = .init(), isCancelled: () -> Bool = { false }) -> SpaceCleaningValidation {
        if isCancelled() { return .cancelled }
        guard candidate.canProcess else { return .protected }
        guard SpaceCleaningDevelopmentPolicy.reason(at: candidate.url) == nil else { return .protected }
        guard !isCloudPlaceholder(at: candidate.url), !candidate.ancestorIdentities.contains(where: { isCloudPlaceholder(at: $0.url) }) else { return .protected }
        guard let root = captureIdentity(at: candidate.rootURL), isDirectory(root),
              root.fileKey == candidate.rootIdentity.fileKey,
              canonicalURL(candidate.rootURL)?.path == candidate.rootURL.path else { return .scopeChanged }
        guard contains(candidate.url.path, in: candidate.rootURL.path), candidate.url.path != candidate.rootURL.path else { return .scopeChanged }
        let parent = candidate.url.deletingLastPathComponent()
        guard candidate.ancestorIdentities.first?.url.path == candidate.rootURL.path,
              candidate.ancestorIdentities.last?.url.path == parent.path,
              candidate.ancestorIdentities.count == parent.pathComponents.count - candidate.rootURL.pathComponents.count + 1 else { return .scopeChanged }
        for (index, ancestor) in candidate.ancestorIdentities.enumerated() {
            if index > 0 && ancestor.url.deletingLastPathComponent().path != candidate.ancestorIdentities[index - 1].url.path { return .scopeChanged }
            guard contains(ancestor.url.path, in: candidate.rootURL.path), let current = captureIdentity(at: ancestor.url),
                  isDirectory(current), current.fileKey == ancestor.identity.fileKey,
                  canonicalURL(ancestor.url)?.path == ancestor.url.path else { return .scopeChanged }
        }
        guard let identity = captureIdentity(at: candidate.url) else { return .missing }
        guard identity == candidate.identity, !isSymbolicLink(identity), canonicalURL(candidate.url)?.path == candidate.url.path else { return .changed }
        return withoutActuallyEscaping(isCancelled) { cancellation in
            let worker = Worker(context: context, options: options, now: Date(), cancelled: cancellation, progress: { _ in })
            guard worker.validRoot(candidate.rootURL), !worker.isPackage(candidate.rootURL), !worker.hasPackageAncestor(candidate.rootURL) else { return .protected }
            let scope = SpaceCleaningScope(id: candidate.scopeID, directory: candidate.rootURL)
            guard let fresh = worker.makeCandidate(candidate.url, identity: identity, scope: scope, root: candidate.rootURL,
                                                   rootIdentity: root, ancestors: candidate.ancestorIdentities) else { return .incomplete }
            if cancellation() { return .cancelled }
            guard fresh.sizeIsComplete else { return .incomplete }
            guard fresh.canProcess else { return .protected }
            guard fresh.kind == candidate.kind, fresh.group == candidate.group, fresh.treeFingerprint == candidate.treeFingerprint,
                  fresh.logicalBytes == candidate.logicalBytes, fresh.allocatedBytes == candidate.allocatedBytes else { return .changed }
            return .unchanged
        }
    }

    /// Recheck only the explicitly reviewed test package. Existing selections and
    /// unrelated archive protection must not change when a declaration is added.
    public static func reviewTestCandidate(_ candidate: SpaceCleaningCandidate, context: SpaceCleaningContext,
                                          isCancelled: () -> Bool = { false }) -> SpaceCleaningCandidate? {
        guard candidate.canConfirmTestPurpose, candidate.sizeIsComplete,
              context.testDeclarations.contains(.init(candidate: candidate)),
              captureIdentity(at: candidate.url) == candidate.identity,
              canonicalURL(candidate.url)?.path == candidate.url.path,
              candidate.ancestorIdentities.allSatisfy({
                  captureIdentity(at: $0.url)?.fileKey == $0.identity.fileKey && canonicalURL($0.url)?.path == $0.url.path
              }), let root = captureIdentity(at: candidate.rootURL), root.fileKey == candidate.rootIdentity.fileKey else { return nil }
        return withoutActuallyEscaping(isCancelled) { cancelled in
            let worker = Worker(context: context, options: .init(), now: Date(), cancelled: cancelled, progress: { _ in })
            guard var fresh = worker.makeCandidate(candidate.url, identity: candidate.identity,
                scope: .init(id: candidate.scopeID, directory: candidate.rootURL), root: candidate.rootURL,
                rootIdentity: root, ancestors: candidate.ancestorIdentities), !cancelled(),
                fresh.canProcess, [.testApplication, .testArchive].contains(fresh.kind),
                fresh.treeFingerprint == candidate.treeFingerprint,
                fresh.logicalBytes == candidate.logicalBytes, fresh.allocatedBytes == candidate.allocatedBytes else { return nil }
            fresh.id = candidate.id
            return fresh
        }
    }

    /// Policy-only check for a previously verified transaction receipt, including Trash purges.
    /// The original URL need not exist. This never verifies receipt integrity or the Trash object.
    public static func validatePolicy(candidate: SpaceCleaningCandidate, context: SpaceCleaningContext) -> SpaceCleaningValidation {
        guard candidate.canProcess else { return .protected }
        guard SpaceCleaningDevelopmentPolicy.reason(at: candidate.url) == nil else { return .protected }
        guard !isCloudPlaceholder(at: candidate.url), !candidate.ancestorIdentities.contains(where: { isCloudPlaceholder(at: $0.url) }) else { return .protected }
        let worker = Worker(context: context, options: .init(), now: Date(), cancelled: { false }, progress: { _ in })
        if worker.isReleaseProtected(candidate.url) || (candidate.url.pathExtension.lowercased() == "app" && worker.isInstalled(candidate.url)) ||
            worker.cacheOwnerIsRunning(candidate.url) || context.runningApplicationURLs.contains(where: {
                worker.overlaps(candidate.url.path, worker.canonicalPath($0))
            }) { return .protected }
        return .unchanged
    }

    public static func canonicalURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved))
        }
    }
    public static func isCloudPlaceholder(fileFlags: UInt32) -> Bool {
        #if canImport(Darwin)
        fileFlags & UInt32(SF_DATALESS) != 0
        #else
        false
        #endif
    }
    /// Only lstat metadata is read. No content open, download request or provider enumeration.
    public static func isCloudPlaceholder(at url: URL) -> Bool {
        fileFlags(at: url).map(isCloudPlaceholder(fileFlags:)) ?? false
    }
    static func fileFlags(at url: URL) -> UInt32? {
        guard url.isFileURL else { return nil }
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &value) } ?? -1 }) == 0 else { return nil }
        #if canImport(Darwin)
        return UInt32(value.st_flags)
        #else
        return 0
        #endif
    }
    public static func captureIdentity(at url: URL) -> StorageReviewFileIdentity? {
        guard url.isFileURL else { return nil }
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &value) } ?? -1 }) == 0 else { return nil }
        return identity(value)
    }
    fileprivate static func identity(_ value: stat) -> StorageReviewFileIdentity? {
        guard value.st_size >= 0, value.st_blocks >= 0 else { return nil }
        #if canImport(Darwin)
        let modified = value.st_mtimespec, changed = value.st_ctimespec
        #else
        let modified = value.st_mtim, changed = value.st_ctim
        #endif
        let allocated = UInt64(value.st_blocks).multipliedReportingOverflow(by: 512)
        return .init(device: UInt64(bitPattern: Int64(value.st_dev)), inode: UInt64(value.st_ino), sizeBytes: UInt64(value.st_size),
                     allocatedBytes: allocated.overflow ? .max : allocated.partialValue,
                     modifiedSeconds: Int64(modified.tv_sec), modifiedNanoseconds: Int64(modified.tv_nsec),
                     changedSeconds: Int64(changed.tv_sec), changedNanoseconds: Int64(changed.tv_nsec),
                     linkCount: UInt64(value.st_nlink), mode: UInt32(value.st_mode))
    }
    fileprivate static func contains(_ path: String, in root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    fileprivate static func isDirectory(_ value: StorageReviewFileIdentity) -> Bool { value.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    fileprivate static func isRegular(_ value: StorageReviewFileIdentity) -> Bool { value.mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
    fileprivate static func isSymbolicLink(_ value: StorageReviewFileIdentity) -> Bool { value.mode & UInt32(S_IFMT) == UInt32(S_IFLNK) }
}

struct SpaceCleaningMetadataReader {
    var flags: (URL) -> UInt32?
    var willEnumerate: (URL) -> Void = { _ in }
    static var live: Self { .init(flags: SpaceCleaningScanner.fileFlags(at:)) }
}

private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let sum = lhs.addingReportingOverflow(rhs); return sum.overflow ? .max : sum.partialValue
}

private final class Worker {
    typealias Scanner = SpaceCleaningScanner
    let context: SpaceCleaningContext
    let options: SpaceCleaningOptions
    let now: Date
    let cancelled: () -> Bool
    let progress: (SpaceCleaningProgress) -> Void
    let metadata: SpaceCleaningMetadataReader
    let home: URL
    let runningBundleIdentifiers: Set<String>
    var candidates: [SpaceCleaningCandidate] = []
    var issues: [SpaceCleaningIssue] = []
    var checked = 0
    var limit = false
    // Discovery cannot consume the capacity reserved for content verification.
    // Both phases remain independently bounded; checked is the actual total.
    var phaseChecked = 0
    var phaseLimited = false
    func markLimit() { limit = true; phaseLimited = true }
    var visitedFiles: Set<String> = []
    var visitedRoots: [String] = []
    var completedScopes = 0
    var totalScopes = 0
    var stage: SpaceCleaningStage = .caches
    var recordedBytes: UInt64 = 0
    var phase: SpaceCleaningScanPhase = .discovering
    var completedItems = 0
    struct PendingCandidate {
        let url: URL
        let identity: StorageReviewFileIdentity
        let scope: SpaceCleaningScope
        let root: URL
        let rootIdentity: StorageReviewFileIdentity
        let ancestors: [SpaceCleaningPathIdentity]
    }
    var pendingCandidates: [PendingCandidate] = []
    private var developmentLookup = SpaceCleaningDevelopmentPolicy.Lookup()
    private func developmentReason(_ url: URL, identity: StorageReviewFileIdentity? = nil) -> String? {
        developmentLookup.reason(at: url, identity: identity)
    }

    init(context: SpaceCleaningContext, options: SpaceCleaningOptions, now: Date, metadata: SpaceCleaningMetadataReader = .live,
         cancelled: @escaping () -> Bool, progress: @escaping (SpaceCleaningProgress) -> Void) {
        self.context = context; self.options = options; self.now = now; self.cancelled = cancelled; self.progress = progress
        self.metadata = metadata
        home = Scanner.canonicalURL(context.homeDirectory) ?? context.homeDirectory
        runningBundleIdentifiers = Set(context.runningApplicationURLs.compactMap { Bundle(url: $0)?.bundleIdentifier?.lowercased() })
    }

    func scan(_ scopes: [SpaceCleaningScope]) -> SpaceCleaningReport {
        totalScopes = scopes.count
        for scope in scopes {
            guard !cancelled(), !phaseLimited else { break }
            stage = stageFor(scope.kind)
            emit(scope: scope, url: scope.directory)
            guard scope.directory.isFileURL else { issue(scope, scope.directory, .unsafePath, "扫描范围必须是本机目录。"); continue }
            guard let original = Scanner.captureIdentity(at: scope.directory) else {
                let failure = errno
                issue(scope, scope.directory, failure == ENOENT ? .missing : failure == EACCES || failure == EPERM ? .permissionDenied : .unreadable,
                      failure == ENOENT ? "此位置不存在，本次未扫描。" : "无法读取此位置，本次未扫描。")
                completedScopes += 1; continue
            }
            if cloudPlaceholder(scope.directory) {
                let parent = scope.directory.deletingLastPathComponent()
                if let parentIdentity = Scanner.captureIdentity(at: parent),
                   Scanner.isDirectory(parentIdentity) {
                    pendingCandidates.append(.init(url: scope.directory, identity: original, scope: scope, root: parent,
                        rootIdentity: parentIdentity, ancestors: [.init(url: parent, identity: parentIdentity)]))
                }
                issue(scope, scope.directory, .cloudPlaceholder, "此目录尚未下载到本机，未读取其中内容。"); completedScopes += 1; continue
            }
            // Check the requested path before realpath can erase a dependency
            // name in a symbolic-link ancestor (node_modules -> shared location).
            let requestedDevelopmentReason = developmentReason(scope.directory, identity: original)
            guard Scanner.isDirectory(original), !Scanner.isSymbolicLink(original), let root = Scanner.canonicalURL(scope.directory),
                  validRoot(root), !isPackage(root), !hasPackageAncestor(root), let rootIdentity = Scanner.captureIdentity(at: root) else {
                issue(scope, scope.directory, .unsafePath, "范围是链接、受保护系统位置或不可读取的目录，已跳过。"); completedScopes += 1; continue
            }
            if requestedDevelopmentReason != nil && developmentReason(root, identity: rootIdentity) == nil {
                issue(scope, scope.directory, .unsafePath, "所选路径经过开发依赖或版本资料，已保留且未展开链接目标。")
                visitedRoots.append(root.path); completedScopes += 1; continue
            }
            guard !visitedRoots.contains(where: { Scanner.contains(root.path, in: $0) }) else {
                issue(scope, root, .duplicate, "与其他范围重叠，未重复扫描。"); completedScopes += 1; continue
            }
            if developmentReason(root, identity: rootIdentity) != nil {
                let parent = root.deletingLastPathComponent()
                if let parentIdentity = Scanner.captureIdentity(at: parent), Scanner.isDirectory(parentIdentity) {
                    pendingCandidates.append(.init(url: root, identity: rootIdentity, scope: scope, root: parent,
                        rootIdentity: parentIdentity, ancestors: [.init(url: parent, identity: parentIdentity)]))
                }
            } else if scope.kind == .releaseArchiveDiscovery {
                discoverReleaseArchives(scope, root: root, rootIdentity: rootIdentity)
            } else {
                walk(scope, directory: root, root: root, rootIdentity: rootIdentity, ancestors: [.init(url: root, identity: rootIdentity)], depth: 0)
            }
            // The discovery scope reads only ReleaseArchives children, not all Application Support.
            if scope.kind != .releaseArchiveDiscovery { visitedRoots.append(root.path) }
            completedScopes += 1
        }
        phase = .verifying; phaseChecked = 0; phaseLimited = false
        emit(scope: nil, url: nil)
        // A large protected or unknown directory must not consume the verification
        // budget before positively identified rebuildable content has been checked.
        // Preserve discovery order within each priority and keep the same total bound.
        var rebuildableCandidates: [PendingCandidate] = [], otherCandidates: [PendingCandidate] = []
        for pending in pendingCandidates {
            guard !cancelled() else { break }
            if verificationPriority(pending) == 0 { rebuildableCandidates.append(pending) }
            else { otherCandidates.append(pending) }
        }
        for pending in rebuildableCandidates + otherCandidates {
            guard !cancelled() else { break }
            stage = stageFor(pending.scope.kind)
            emit(scope: pending.scope, url: pending.url)
            if Scanner.captureIdentity(at: pending.url) == pending.identity,
               pending.ancestors.allSatisfy({
                   Scanner.captureIdentity(at: $0.url)?.fileKey == $0.identity.fileKey && Scanner.canonicalURL($0.url)?.path == $0.url.path
               }) {
                if let candidate = makeCandidate(pending.url, identity: pending.identity, scope: pending.scope,
                    root: pending.root, rootIdentity: pending.rootIdentity, ancestors: pending.ancestors) {
                    candidates.append(candidate)
                    recordedBytes = saturatingAdd(recordedBytes, candidate.logicalBytes)
                }
            } else {
                issue(pending.scope, pending.url, .changed, "发现后文件发生变化，已跳过；请重新扫描。")
            }
            completedItems += 1
            emit(scope: pending.scope, url: pending.url)
        }
        let wasCancelled = cancelled()
        phase = .finished
        if wasCancelled, let scope = scopes.first { issue(scope, scope.directory, .cancelled, "扫描已停止，结果不完整。") }
        stage = wasCancelled ? .cancelled : scopes.isEmpty ? .failed : .complete
        let complete = !wasCancelled && !limit && !scopes.isEmpty
        let coverageComplete = complete && !issues.contains { ![.missing, .duplicate].contains($0.kind) }
        emit(scope: nil, url: nil)
        return .init(id: UUID(), scannedAt: now, finishedAt: max(Date(), now), ruleVersion: Scanner.ruleVersion,
                     scopes: scopes, candidates: candidates, issues: issues, stage: stage, complete: complete,
                     coverageComplete: coverageComplete, reachedLimit: limit, checkedEntries: checked)
    }

    func verificationPriority(_ pending: PendingCandidate) -> Int {
        guard cacheKind(pending.url) != nil else { return 1 }
        let classification = classify(pending.url, identity: pending.identity)
        return classification.group == .rebuildable ? 0 : 1
    }

    func walk(_ scope: SpaceCleaningScope, directory: URL, root: URL, rootIdentity: StorageReviewFileIdentity,
              ancestors: [SpaceCleaningPathIdentity], depth: Int) {
        // Iteration avoids retaining a maximum-sized sibling array at every recursion depth.
        var pending: [(URL, [SpaceCleaningPathIdentity], Int)] = [(directory, ancestors, depth)]
        while let (current, chain, currentDepth) = pending.popLast() {
            guard !cancelled(), !phaseLimited else { return }
            guard currentDepth <= options.maximumDepth else { markLimit(); issue(scope, current, .depthLimit, "已到达扫描深度上限。"); return }
            guard let children = readChildren(current, scope: scope) else { continue }
            for child in children {
                if visitedRoots.contains(where: { Scanner.contains(child.path, in: $0) }) { continue }
                guard visit(child, scope: scope) else { break }
                guard let identity = Scanner.captureIdentity(at: child) else { issue(scope, child, .unreadable, "文件已消失或无法读取元数据。"); continue }
                if options.mode == .largeFiles, Scanner.isRegular(identity),
                   developmentReason(child, identity: identity) == nil, !cloudPlaceholder(child),
                   (identity.sizeBytes < options.minimumFileBytes || options.maximumFileBytes.map({ identity.sizeBytes > $0 }) == true) { continue }
                if Scanner.isDirectory(identity), !Scanner.isSymbolicLink(identity), !cloudPlaceholder(child), !shouldAggregate(child, scope: scope, identity: identity) {
                    guard identity.device == rootIdentity.device, Scanner.canonicalURL(child)?.path == child.path else {
                        issue(scope, child, .unsafePath, "跨卷目录或路径已变化，未继续扫描。"); continue
                    }
                    pending.append((child, chain + [.init(url: child, identity: identity)], currentDepth + 1))
                } else {
                    pendingCandidates.append(.init(url: child, identity: identity, scope: scope, root: root,
                                                   rootIdentity: rootIdentity, ancestors: chain))
                }
                emit(scope: scope, url: child)
            }
        }
    }

    func discoverReleaseArchives(_ scope: SpaceCleaningScope, root: URL, rootIdentity: StorageReviewFileIdentity) {
        guard let children = readChildren(root, scope: scope) else { return }
        for appFolder in children {
            guard visit(appFolder, scope: scope) else { break }
            guard let identity = Scanner.captureIdentity(at: appFolder), Scanner.isDirectory(identity) else { continue }
            if cloudPlaceholder(appFolder) {
                issue(scope, appFolder, .cloudPlaceholder, "此目录尚未下载到本机，未核验其中的发布档案。")
                continue
            }
            guard
                  Scanner.canonicalURL(appFolder)?.path == appFolder.path else { continue }
            let archive = appFolder.lastPathComponent == "ReleaseArchives" ? appFolder : appFolder.appendingPathComponent("ReleaseArchives")
            guard let archiveIdentity = Scanner.captureIdentity(at: archive), Scanner.isDirectory(archiveIdentity),
                  !Scanner.isSymbolicLink(archiveIdentity) else { continue }
            let ancestors: [SpaceCleaningPathIdentity] = [.init(url: root, identity: rootIdentity)] +
                (archive == appFolder ? [] : [.init(url: appFolder, identity: identity)])
            pendingCandidates.append(.init(url: archive, identity: archiveIdentity, scope: scope, root: root,
                                           rootIdentity: rootIdentity, ancestors: ancestors))
            visitedRoots.append(archive.path)
        }
    }

    struct Classification { var kind: SpaceCleaningKind; var group: SpaceCleaningGroup; var reason: String; var impact: String; var testable = false }
    struct Measurement { var logical: UInt64 = 0; var allocated: UInt64 = 0; var fingerprint: String?; var complete = true; var unsafe = false; var releaseContent = false; var cloudContent = false; var developmentContent = false }

    func makeCandidate(_ url: URL, identity: StorageReviewFileIdentity, scope: SpaceCleaningScope, root: URL,
                       rootIdentity: StorageReviewFileIdentity, ancestors: [SpaceCleaningPathIdentity]) -> SpaceCleaningCandidate? {
        let directory = Scanner.isDirectory(identity)
        if !directory && !Scanner.isSymbolicLink(identity), !visitedFiles.insert(identity.fileKey).inserted {
            issue(scope, url, .duplicate, "同一文件身份已记录，不重复计算容量。"); return nil
        }
        var classification = classify(url, identity: identity)
        var measurement = Measurement()
        if classification.kind == .developmentEnvironment {
            measurement.complete = false
        } else if classification.kind == .cloudPlaceholder {
            measurement.complete = false; measurement.cloudContent = true
            issue(scope, url, .cloudPlaceholder, "内容尚未下载到本机，未读取或计入可清理容量。")
        } else if directory, options.mode == .largeFiles {
            // Large-file discovery does not unpack application/document packages or
            // count protected directory contents as a single large regular file.
            measurement.complete = false
        } else if directory {
            measurement = measure(url, rootIdentity: identity, scope: scope, allowBundleLinks: ["app", "xcarchive"].contains(url.pathExtension.lowercased()),
                                  protectedBudget: classification.group == .protected && !classification.testable)
        } else if Scanner.isRegular(identity) {
            measurement.logical = identity.sizeBytes; measurement.allocated = identity.allocatedBytes
        }
        if measurement.developmentContent {
            classification = .init(kind: .developmentEnvironment, group: .protected,
                                   reason: "目录含有开发环境或版本资料，已停止展开并保留整个目录。", impact: "不拆分清理依赖；已读取的容量不代表整个目录大小。")
            measurement.complete = false
        } else if classification.kind == .developmentEnvironment {
            classification.group = .protected
        } else if directory && options.mode == .largeFiles {
            classification.group = .protected; classification.testable = false
            classification.reason += "大文件扫描不展开此类目录，未统计内部容量。"
        } else if measurement.cloudContent {
            classification = .init(kind: .cloudPlaceholder, group: .protected,
                                   reason: directory ? "目录含有尚未下载到本机的内容，未展开或处理占位内容。" : "云端内容尚未下载到本机，本次保留。",
                                   impact: "不触发下载，不计入本机可清理容量。")
            measurement.complete = false
        } else if !measurement.complete {
            let alreadyProtected = classification.group == .protected && !classification.testable
            classification.group = .protected
            classification.reason = alreadyProtected ? classification.reason + "仅完成部分容量统计。" : "内容核验未完成，本次保留；可缩小扫描范围后重试。"
            classification.testable = false
        } else if measurement.releaseContent && classification.group != .protected {
            classification = .init(kind: .releaseMaterial, group: .protected, reason: "目录包含发布材料，保留整个目录。", impact: "请单独核对原件与副本。")
        } else if measurement.unsafe && classification.group != .protected {
            let reason = classification.kind == .derivedData
                ? "构建产物包含需单独核验的链接或特殊内容，本次保留整个目录。"
                : "目录包含链接、特殊文件或正在使用的数据，保留整个目录。"
            classification = .init(kind: .unsupported, group: .protected, reason: reason, impact: "处理前需要单独核验。")
        }
        if classification.testable, measurement.complete, !measurement.unsafe, !measurement.releaseContent,
           context.testDeclarations.contains(where: { $0.url.path == url.path && $0.identity == identity && $0.treeFingerprint == measurement.fingerprint }) {
            classification = .init(kind: classification.kind == .unknownArchive ? .testArchive : .testApplication, group: .review,
                                   reason: "你已确认此副本仅用于测试，仍需手动选择。", impact: "删除后需要重新构建或重新归档。")
        }
        if measurement.unsafe || measurement.releaseContent { classification.testable = false }
        return .init(scopeID: scope.id, url: url, rootURL: root, rootIdentity: rootIdentity, identity: identity,
                     ancestorIdentities: ancestors, kind: classification.kind, group: classification.group,
                     title: url.lastPathComponent, reason: classification.reason, impact: classification.impact,
                     logicalBytes: measurement.logical, allocatedBytes: measurement.allocated, isDirectory: directory,
                     canConfirmTestPurpose: classification.testable, treeFingerprint: measurement.fingerprint, sizeIsComplete: measurement.complete)
    }

    func classify(_ url: URL, identity: StorageReviewFileIdentity) -> Classification {
        if Scanner.isSymbolicLink(identity) { return .init(kind: .symbolicLink, group: .protected, reason: "符号链接默认保留，未跟随目标。", impact: "链接大小不代表目标占用。") }
        if cloudPlaceholder(url) { return .init(kind: .cloudPlaceholder, group: .protected, reason: "云端内容尚未下载到本机，本次保留。", impact: "不触发下载，不计入本机可清理容量。") }
        if let reason = developmentReason(url, identity: identity) {
            return .init(kind: .developmentEnvironment, group: .protected, reason: reason,
                         impact: "依赖仍可能用于构建或调试，不提供内部文件清理。")
        }
        if isReleaseProtected(url) { return .init(kind: url.pathExtension.lowercased() == "xcarchive" ? .releaseArchive : .releaseMaterial,
                                                  group: .protected, reason: "正式发布档案或关联材料，保留原件。", impact: "用于发布、更新和问题定位。") }
        if context.runningApplicationURLs.contains(where: { overlaps(url.path, canonicalPath($0)) }) || cacheOwnerIsRunning(url) {
            return .init(kind: .runningApplication, group: .protected, reason: "关联应用或开发工具正在运行，本次保留。", impact: "退出相关应用后重新扫描。")
        }
        if Scanner.isRegular(identity), identity.linkCount > 1 { return .init(kind: .hardLink, group: .protected, reason: "文件存在多个硬链接，默认保留。", impact: "删除一个路径不等于释放对应空间。") }
        let ext = url.pathExtension.lowercased()
        if ext == "app" {
            if isInstalled(url) { return .init(kind: .installedApplication, group: .protected, reason: "已安装应用，需通过单独卸载流程处理。", impact: "不纳入文件清理。") }
            return .init(kind: .unknownApplication, group: .protected, reason: "尚未确认是测试副本还是需要保留的导出 App。", impact: "不能仅凭名称、签名或公证状态判断用途。", testable: true)
        }
        if ext == "xcarchive" { return .init(kind: .unknownArchive, group: .protected, reason: "归档用途待确认，默认保留。", impact: "确认仅用于测试且不是需保留的唯一归档后，可手动复核。", testable: true) }
        if let known = cacheKind(url) {
            if unsafeCacheFileName(url.lastPathComponent) {
                return .init(kind: .unsupported, group: .protected, reason: "缓存中的数据库、事务边车或锁文件默认保留。", impact: "需要先核实应用状态与数据一致性。")
            }
            return .init(kind: known, group: .rebuildable, reason: known == .derivedData ? "已识别的 Xcode 可重建内容。" : "来自已知的可重建缓存位置。",
                         impact: known == .derivedData ? "下次构建或索引可能更慢。" : "相关内容可能需要重新下载或生成。")
        }
        if Scanner.isRegular(identity), ext == "pkg" {
            return .init(kind: .installerPackage, group: .review,
                         reason: "PKG 安装包，可在不再需要安装或保留此版本时选择清理。",
                         impact: "尚未核验安装是否完成；清理后如需安装，需重新获取此安装包。")
        }
        if Scanner.isRegular(identity), ext == "dmg", within(url, "Downloads") || within(url, "Desktop") {
            return .init(kind: .downloadedDiskImage, group: .review,
                         reason: "下载或桌面中的磁盘映像，可核对用途后选择清理。",
                         impact: "磁盘映像也可能包含个人文件；尚未核验其内容或安装状态。")
        }
        if isPackage(url) { return .init(kind: .package, group: .protected, reason: "应用资源或文稿包默认保留。", impact: "不会拆开包选择内部文件。") }
        if Scanner.isRegular(identity), within(url, "Library/Logs/DiagnosticReports") {
            if ["log", "crash", "ips", "diag", "trace"].contains(ext) {
                let age = now.timeIntervalSince1970 - Double(identity.modifiedSeconds) - Double(identity.modifiedNanoseconds) / 1_000_000_000
                return age >= options.diagnosticMinimumAge
                    ? .init(kind: .oldDiagnostic, group: .rebuildable, reason: "达到保留期限的诊断记录。", impact: "如正在排查历史问题，建议保留。")
                    : .init(kind: .recentDiagnostic, group: .protected, reason: "尚未达到诊断记录保留期限。", impact: "保留近期问题定位资料。")
            }
        }
        if !Scanner.isDirectory(identity) && !Scanner.isRegular(identity) { return .init(kind: .unsupported, group: .protected, reason: "特殊文件默认保留。", impact: "不在普通文件处理范围内。") }
        if within(url, "Downloads") { return .init(kind: .downloadedFile, group: .review, reason: "下载内容，请确认是否仍需保留。", impact: "不会仅因体积大或时间久而推荐删除。") }
        if within(url, "Developer") { return .init(kind: .developmentFile, group: .review, reason: "开发目录中的文件，需要人工确认。", impact: "可能包含项目源码或独有构建材料。") }
        return .init(kind: .personalFile, group: .review, reason: "自选范围中的文件，需要人工复核。", impact: "文件名和修改时间不代表可安全删除。")
    }

    func measure(_ root: URL, rootIdentity: StorageReviewFileIdentity, scope: SpaceCleaningScope, allowBundleLinks: Bool,
                 protectedBudget: Bool) -> Measurement {
        var result = Measurement(), hash = SHA256()
        var pending: [(URL, Int)] = [(root, 0)]
        var identities: [(URL, StorageReviewFileIdentity)] = []
        var localSeen: Set<String> = []
        let generated = cacheKind(root) == .derivedData
        let strongRoot = isStrongReleaseProtected(root)
        let measurementLimit = protectedBudget ? min(10_000, options.maximumEntries) : options.maximumEntries
        var measuredEntries = 0
        measurementLoop: while let (directory, depth) = pending.popLast() {
            guard !cancelled(), !phaseLimited else { result.complete = false; break }
            if cloudPlaceholder(directory) {
                result.complete = false; result.cloudContent = true
                issue(scope, directory, .cloudPlaceholder, "目录尚未下载到本机，未读取其中内容。"); continue
            }
            guard depth <= options.maximumDepth else {
                if !protectedBudget { markLimit() }
                result.complete = false; issue(scope, directory, .depthLimit, "已到达目录内容核验深度上限。"); break
            }
            guard let identity = Scanner.captureIdentity(at: directory), Scanner.isDirectory(identity), identity.device == rootIdentity.device,
                  Scanner.canonicalURL(directory)?.path == directory.path else { result.complete = false; break }
            identities.append((directory, identity))
            guard let children = readChildren(directory, scope: scope, maximumNames: measurementLimit - measuredEntries + 1) else { result.complete = false; break }
            for child in children {
                guard measuredEntries < measurementLimit else {
                    result.complete = false
                    if !protectedBudget { markLimit() }
                    issue(scope, root, .entryLimit, protectedBudget ? "受保护目录仅完成有界容量统计，文件继续保留。" : "目录内容超出本次核验上限。")
                    break measurementLoop
                }
                guard visit(child, scope: scope) else { result.complete = false; break }
                measuredEntries += 1
                guard let childIdentity = Scanner.captureIdentity(at: child) else { result.complete = false; break }
                if developmentReason(child, identity: childIdentity) != nil {
                    result.complete = false; result.unsafe = true; result.developmentContent = true
                    continue
                }
                let relative = String(child.path.dropFirst(root.path.count + 1))
                let record = "\(relative.utf8.count):\(relative):\(childIdentity.device):\(childIdentity.inode):\(childIdentity.sizeBytes):\(childIdentity.allocatedBytes):\(childIdentity.modifiedSeconds):\(childIdentity.modifiedNanoseconds):\(childIdentity.changedSeconds):\(childIdentity.changedNanoseconds):\(childIdentity.linkCount):\(childIdentity.mode)\n"
                hash.update(data: Data(record.utf8))
                if cloudPlaceholder(child) {
                    result.complete = false; result.cloudContent = true
                    issue(scope, child, .cloudPlaceholder, "内容尚未下载到本机，未展开、读取或计入容量。")
                    continue
                }
                if childIdentity.device != rootIdentity.device { result.unsafe = true; continue }
                if strongRoot || isStrongReleaseProtected(child) || (!generated && !allowBundleLinks && isReleaseProtected(child)) { result.releaseContent = true }
                if Scanner.isSymbolicLink(childIdentity) {
                    let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: child.path)) ?? ""
                    hash.update(data: Data("link:\(target.utf8.count):\(target)\n".utf8))
                    if !allowBundleLinks || target.isEmpty || target.hasPrefix("/") ||
                        !(Scanner.canonicalURL(child).map { Scanner.contains($0.path, in: root.path) } ?? false) { result.unsafe = true }
                } else if Scanner.isDirectory(childIdentity) {
                    pending.append((child, depth + 1))
                } else if Scanner.isRegular(childIdentity) {
                    if childIdentity.linkCount > 1 { result.unsafe = true }
                    if localSeen.insert(childIdentity.fileKey).inserted, visitedFiles.insert(childIdentity.fileKey).inserted {
                        result.logical = saturatingAdd(result.logical, childIdentity.sizeBytes)
                        result.allocated = saturatingAdd(result.allocated, childIdentity.allocatedBytes)
                    }
                    if !allowBundleLinks && unsafeCacheFileName(child.lastPathComponent) { result.unsafe = true }
                } else { result.unsafe = true }
                emit(scope: scope, url: child)
            }
        }
        if result.complete {
            for (url, identity) in identities where Scanner.captureIdentity(at: url) != identity { result.complete = false; break }
            if Scanner.captureIdentity(at: root) != rootIdentity { result.complete = false }
        }
        result.fingerprint = result.complete ? hash.finalize().map { String(format: "%02x", $0) }.joined() : nil
        return result
    }

    func shouldAggregate(_ url: URL, scope: SpaceCleaningScope, identity: StorageReviewFileIdentity) -> Bool {
        if developmentReason(url, identity: identity) != nil { return true }
        if isPackage(url) || isReleaseProtected(url) { return true }
        if options.mode == .largeFiles { return false }
        if cacheKind(url) != nil { return true }
        if url.deletingLastPathComponent().path == home.appendingPathComponent("Library/Caches").path,
           !["Google", "Firefox"].contains(url.lastPathComponent),
           !visitedRoots.contains(where: { Scanner.contains($0, in: url.path) }) { return true }
        // Directories in Downloads/custom locations remain navigable, never wholesale inferred junk.
        return false
    }
    func cacheKind(_ url: URL) -> SpaceCleaningKind? {
        let roots = ["Library/Caches/com.apple.Safari", "Library/Containers/com.apple.Safari/Data/Library/Caches", "Library/Caches/Google/Chrome"]
        if roots.contains(where: { within(url, $0) }) { return .browserCache }
        if within(url, "Library/Caches/Firefox/Profiles") {
            let components = relativeComponents(url, "Library/Caches/Firefox/Profiles")
            if components.count >= 2 && components[1] == "cache2" { return .browserCache }
        }
        if within(url, ".npm/_cacache") { return .packageCache }
        if ["Library/Caches/Homebrew", "Library/Caches/pip", "Library/Caches/org.swift.swiftpm"].contains(where: { within(url, $0) }) { return .packageCache }
        if within(url, "Library/Developer/Xcode/DerivedData") {
            let parts = relativeComponents(url, "Library/Developer/Xcode/DerivedData")
            let topCaches: Set<String> = ["ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex", "SymbolCache.noindex"]
            if let first = parts.first, topCaches.contains(first) { return .derivedData }
            if parts.count >= 2 && parts[1] == "Index.noindex" { return .derivedData }
            if parts.count >= 3 && parts[1] == "Build" && ["Intermediates.noindex", "Products"].contains(parts[2]) { return .derivedData }
        }
        return nil
    }
    func cacheOwnerIsRunning(_ url: URL) -> Bool {
        if within(url, "Library/Caches"), let owner = relativeComponents(url, "Library/Caches").first,
           runningBundleIdentifiers.contains(owner.lowercased()) { return true }
        let running = context.runningApplicationURLs.map { $0.lastPathComponent.lowercased() }
        if within(url, "Library/Caches/com.apple.Safari") || within(url, "Library/Containers/com.apple.Safari") { return running.contains("safari.app") }
        if within(url, "Library/Caches/Google/Chrome") { return running.contains { $0.hasPrefix("google chrome") } }
        if within(url, "Library/Caches/Firefox") { return running.contains { $0.hasPrefix("firefox") } }
        if within(url, "Library/Developer/Xcode/DerivedData") { return running.contains { $0.hasPrefix("xcode") } || !context.activeToolNames.isDisjoint(with: ["xcodebuild", "swift", "swift-frontend", "clang", "clang++", "XCBBuildService"]) }
        if within(url, ".npm/_cacache") { return !context.activeToolNames.isDisjoint(with: ["npm", "npx"]) }
        if within(url, "Library/Caches/Homebrew") { return context.activeToolNames.contains("brew") }
        if within(url, "Library/Caches/pip") { return !context.activeToolNames.isDisjoint(with: ["pip", "pip3"]) }
        if within(url, "Library/Caches/org.swift.swiftpm") { return !context.activeToolNames.isDisjoint(with: ["swift", "swift-package", "xcodebuild", "XCBBuildService"]) }
        return false
    }
    func isReleaseProtected(_ url: URL) -> Bool {
        if isStrongReleaseProtected(url) { return true }
        let ext = url.pathExtension.lowercased(), name = url.lastPathComponent.lowercased()
        return ext == "dsym" || ["appcast.xml", "appcast.json", "sha256sums", "sha256sums.txt", "checksums.txt", "distribution-summary.plist"].contains(name)
    }
    func isStrongReleaseProtected(_ url: URL) -> Bool {
        if context.protectedReleaseURLs.contains(where: { overlaps(url.path, canonicalPath($0)) }) || url.pathComponents.contains(where: { $0.lowercased() == "releasearchives" }) { return true }
        var parent = url
        while parent.path != "/" {
            if parent.pathExtension.lowercased() == "xcarchive", archiveHasDistributionRecords(parent) { return true }
            let next = parent.deletingLastPathComponent()
            if next.path == parent.path { break }
            parent = next
        }
        return false
    }
    func archiveHasDistributionRecords(_ archive: URL) -> Bool {
        // These are Organizer distribution records, not an inference from an App's
        // signature, notarization ticket, filename or age. Never traverse a redirect.
        for name in ["Distributions", "Submissions", "DistributionSummary.plist", "distribution-summary.plist"] {
            let record = archive.appendingPathComponent(name)
            if let identity = Scanner.captureIdentity(at: record), !Scanner.isSymbolicLink(identity),
               Scanner.canonicalURL(record)?.path == record.path,
               (Scanner.isDirectory(identity) || Scanner.isRegular(identity)) { return true }
        }
        return false
    }
    func unsafeCacheFileName(_ value: String) -> Bool {
        let name = value.lowercased()
        return name.hasSuffix("-wal") || name.hasSuffix("-shm") || name.hasSuffix("-journal") || name.hasSuffix(".lock") ||
            name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite3") || name.hasSuffix(".db") || name == "lock"
    }
    func cloudPlaceholder(_ url: URL) -> Bool { metadata.flags(url).map(Scanner.isCloudPlaceholder(fileFlags:)) ?? false }
    func isInstalled(_ url: URL) -> Bool {
        Scanner.contains(url.path, in: "/Applications") || Scanner.contains(url.path, in: "/System/Applications") || within(url, "Applications")
    }
    func isPackage(_ url: URL) -> Bool {
        ["app", "xcarchive", "dsym", "pkg", "bundle", "framework", "plugin", "photoslibrary", "photolibrary", "rtfd", "pages", "numbers", "key", "xcodeproj", "xcworkspace"].contains(url.pathExtension.lowercased()) ||
            (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
    func hasPackageAncestor(_ url: URL) -> Bool {
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            if isPackage(parent) { return true }
            let next = parent.deletingLastPathComponent()
            if next.path == parent.path { break }
            parent = next
        }
        return false
    }
    func within(_ url: URL, _ relative: String) -> Bool { Scanner.contains(url.path, in: home.appendingPathComponent(relative).path) }
    func relativeComponents(_ url: URL, _ relative: String) -> [String] {
        let root = home.appendingPathComponent(relative).path
        return url.path == root ? [] : String(url.path.dropFirst(root.count + 1)).split(separator: "/").map(String.init)
    }
    func canonicalPath(_ url: URL) -> String { Scanner.canonicalURL(url)?.path ?? url.standardizedFileURL.path }
    func overlaps(_ path: String, _ other: String) -> Bool { Scanner.contains(path, in: other) || Scanner.contains(other, in: path) }
    func validRoot(_ url: URL) -> Bool {
        url.path != "/" && !["/System", "/bin", "/sbin", "/usr", "/dev", "/private/etc", "/private/var/db"].contains { Scanner.contains(url.path, in: $0) }
    }
    func stageFor(_ kind: SpaceCleaningScopeKind) -> SpaceCleaningStage {
        switch kind {
        case .browserCache, .packageCache, .diagnostics: .caches
        case .derivedData, .development: .development
        case .downloads, .custom: .downloads
        case .archives, .releaseArchives, .releaseArchiveDiscovery, .installedApplications: .protection
        }
    }
    func issue(_ scope: SpaceCleaningScope, _ url: URL, _ kind: SpaceCleaningIssueKind, _ reason: String) {
        issues.append(.init(scopeID: scope.id, url: url, kind: kind, reason: reason))
    }
    func visit(_ url: URL, scope: SpaceCleaningScope) -> Bool {
        guard !cancelled() else { return false }
        guard phaseChecked < options.maximumEntries else {
            if !phaseLimited { issue(scope, url, .entryLimit, "已到达本次扫描条目上限，结果不完整。") }
            markLimit(); return false
        }
        checked += 1; phaseChecked += 1; emit(scope: scope, url: url); return true
    }
    func emit(scope: SpaceCleaningScope?, url: URL?) {
        progress(.init(stage: stage, currentScopeID: scope?.id, currentPath: url?.deletingLastPathComponent().path,
                       currentFileName: url?.lastPathComponent, checkedEntries: checked, recordedCandidates: candidates.count,
                       logicalBytes: recordedBytes, completedScopes: completedScopes, totalScopes: totalScopes,
                       phase: phase, completedItems: completedItems,
                       totalItems: phase == .discovering ? nil : pendingCandidates.count))
    }
    /// Directory reads are descriptor-bound and capped before retaining names in memory.
    func readChildren(_ url: URL, scope: SpaceCleaningScope, maximumNames: Int? = nil) -> [URL]? {
        guard !cloudPlaceholder(url) else { issue(scope, url, .cloudPlaceholder, "目录尚未下载到本机，未枚举其内容。"); return nil }
        guard !cancelled(), !phaseLimited, Scanner.canonicalURL(url)?.path == url.path else { return nil }
        #if canImport(Darwin)
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK
        #else
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        #endif
        let descriptor = url.path.withCString { open($0, flags) }
        guard descriptor >= 0 else {
            issue(scope, url, errno == EACCES || errno == EPERM ? .permissionDenied : .unreadable, "无法读取目录，本次未扫描其中内容。"); return nil
        }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { close(descriptor); issue(scope, url, .unreadable, "目录句柄不可用。"); return nil }
        #if canImport(Darwin)
        guard !Scanner.isCloudPlaceholder(fileFlags: UInt32(before.st_flags)) else {
            close(descriptor); issue(scope, url, .cloudPlaceholder, "目录尚未下载到本机，未枚举其内容。"); return nil
        }
        #endif
        guard let beforeIdentity = Scanner.identity(before),
              let handle = fdopendir(descriptor) else { close(descriptor); issue(scope, url, .unreadable, "目录句柄不可用。"); return nil }
        defer { closedir(handle) }
        metadata.willEnumerate(url)
        var children: [URL] = []
        while true {
            if cancelled() { return nil }
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 { issue(scope, url, .unreadable, "目录读取未完成。"); return nil }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if children.count >= min(options.maximumEntries - phaseChecked + 1, maximumNames ?? options.maximumEntries + 1) {
                // The extra name is a sentinel: visiting it reports the bound after
                // genuinely checking the retained entries, rather than claiming work.
                break
            }
            children.append(url.appendingPathComponent(name))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, Scanner.identity(after) == beforeIdentity,
              Scanner.captureIdentity(at: url) == beforeIdentity, Scanner.canonicalURL(url)?.path == url.path else {
            issue(scope, url, .changed, "读取期间目录发生变化，已跳过。"); return nil
        }
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
