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
    /// Conversation records and outputs that coding assistants keep for the user.
    case assistantData
    /// The current user's Xcode simulator devices, one item per device.
    case simulators
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
    public var identity: SpaceCleaningFileIdentity
    public init(url: URL, identity: SpaceCleaningFileIdentity) { self.url = url; self.identity = identity }
}
/// A declaration is bound to the exact reviewed object, including package contents.
/// Its existence does not override release protection, running applications or unsafe entries.
public struct SpaceCleaningTestDeclaration: Codable, Equatable, Sendable {
    public var url: URL
    public var identity: SpaceCleaningFileIdentity
    public var treeFingerprint: String?
    public init(url: URL, identity: SpaceCleaningFileIdentity, treeFingerprint: String?) {
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
    /// Executables of running processes: an item that contains one stays protected.
    public var runningExecutablePaths: [String]
    /// Simulator UDIDs and `name=` device names that running processes refer to
    /// (see `SpaceCleaningSimulators.references`); a referenced simulator stays protected.
    public var simulatorReferences: Set<String>
    /// Xcode's simulator tool is installed. Without it simulators stay protected,
    /// since they are deleted only through that tool.
    public var simulatorToolAvailable: Bool
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                runningApplicationURLs: [URL] = [], protectedReleaseURLs: [URL] = [],
                testDeclarations: [SpaceCleaningTestDeclaration] = [], activeToolNames: Set<String> = [],
                runningExecutablePaths: [String] = [], simulatorReferences: Set<String> = [],
                simulatorToolAvailable: Bool = true) {
        self.homeDirectory = homeDirectory; self.runningApplicationURLs = runningApplicationURLs
        self.protectedReleaseURLs = protectedReleaseURLs; self.testDeclarations = testDeclarations
        self.activeToolNames = activeToolNames; self.runningExecutablePaths = runningExecutablePaths
        self.simulatorReferences = simulatorReferences; self.simulatorToolAvailable = simulatorToolAvailable
    }
}
public enum SpaceCleaningScanMode: String, Codable, CaseIterable, Sendable { case cleanup, largeFiles }
public struct SpaceCleaningOptions: Equatable, Sendable {
    /// Discovery bound, and the bound for verifying any single directory candidate.
    public var maximumEntries: Int
    /// Total entries the verification phase may read across all candidates.
    /// One oversized candidate only stays unverified itself; this bound keeps
    /// the overall work limited.
    public var maximumVerificationEntries: Int
    public var maximumDepth: Int
    /// Entry bound for one whole-folder item (build output or large tool cache).
    public var maximumBulkEntries = SpaceCleaningTreeProof.maximumMetadataEntries
    public var diagnosticMinimumAge: TimeInterval
    public var mode: SpaceCleaningScanMode
    public var minimumFileBytes: UInt64
    public var maximumFileBytes: UInt64?
    public init(maximumEntries: Int = 100_000, maximumVerificationEntries: Int? = nil, maximumDepth: Int = 32,
                diagnosticMinimumAge: TimeInterval = 30 * 86_400, mode: SpaceCleaningScanMode = .cleanup,
                minimumFileBytes: UInt64 = 100_000_000, maximumFileBytes: UInt64? = nil) {
        self.maximumEntries = min(1_000_000, max(1, maximumEntries))
        self.maximumVerificationEntries = min(5_000_000, max(self.maximumEntries, maximumVerificationEntries ?? self.maximumEntries * 5))
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
    public var rootIdentity: SpaceCleaningFileIdentity
    public var identity: SpaceCleaningFileIdentity
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
    /// A recognized location worth a look, such as old assistant records or a
    /// test browser download. It is listed with suggestions, never preselected.
    /// Optional so receipts written before or after this field stay readable.
    public var isReviewSuggestion: Bool?
    /// Verified as one folder (identity, owner, size and file times) instead of
    /// file by file; the transaction then uses a metadata-only proof.
    public var isBulkVerified: Bool?
    /// The Xcode simulator this item stands for. It is deleted only through
    /// Xcode's own tool and never moved to the Trash. Optional so receipts stay
    /// readable across versions; the item's kind stays one released builds know.
    public var simulator: SpaceCleaningSimulatorDevice?
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
            (group == .review && ([.installerPackage, .downloadedDiskImage, .oldDiagnostic].contains(kind) || isReviewSuggestion == true))
    }
    public init(id: UUID = UUID(), scopeID: UUID = UUID(), url: URL, rootURL: URL,
                rootIdentity: SpaceCleaningFileIdentity, identity: SpaceCleaningFileIdentity,
                ancestorIdentities: [SpaceCleaningPathIdentity] = [], kind: SpaceCleaningKind,
                group: SpaceCleaningGroup, title: String, reason: String, impact: String,
                logicalBytes: UInt64, allocatedBytes: UInt64, isDirectory: Bool,
                canConfirmTestPurpose: Bool = false, treeFingerprint: String? = nil, sizeIsComplete: Bool = true,
                isReviewSuggestion: Bool? = nil, isBulkVerified: Bool? = nil, simulator: SpaceCleaningSimulatorDevice? = nil) {
        self.id = id; self.scopeID = scopeID; self.url = url; self.rootURL = rootURL
        self.rootIdentity = rootIdentity; self.identity = identity; self.ancestorIdentities = ancestorIdentities
        self.kind = kind; self.group = group; self.title = title; self.reason = reason; self.impact = impact
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes; self.isDirectory = isDirectory
        self.canConfirmTestPurpose = canConfirmTestPurpose; self.treeFingerprint = treeFingerprint; self.sizeIsComplete = sizeIsComplete
        self.isReviewSuggestion = isReviewSuggestion; self.isBulkVerified = isBulkVerified; self.simulator = simulator
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
            ("Library/Caches/Firefox/Profiles", .browserCache, "Firefox 缓存")
        ] + SpaceCleaningKnownLocations.dedicatedScopes.map {
            ($0.path, $0.category == .assistantRecord ? SpaceCleaningScopeKind.assistantData : SpaceCleaningScopeKind.packageCache, $0.scopeTitle ?? $0.title)
        } + [
            ("Library/Caches", .browserCache, "其他应用缓存复核"),
            ("Library/Logs/DiagnosticReports", .diagnostics, "诊断记录"),
            ("Library/Developer/Xcode/DerivedData", .derivedData, "Xcode 构建缓存"),
            (SpaceCleaningSimulators.deviceSetPath, .simulators, "Xcode 模拟器"),
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
            if let device = candidate.simulator {
                // A simulator is re-read from its own record: the same device,
                // still shut down, unused since the scan and not referenced.
                let fresh = worker.classify(candidate.url, identity: identity)
                guard fresh.group != .protected else { return .protected }
                return fresh.simulator == device && fresh.kind == candidate.kind ? .unchanged : .changed
            }
            if candidate.isBulkVerified == true {
                // Whole-folder items re-check identity, rule and owners here; the
                // transaction re-walks the tree for its metadata proof.
                let fresh = worker.classify(candidate.url, identity: identity)
                guard fresh.group != .protected else { return .protected }
                return fresh.kind == candidate.kind && fresh.bulk ? .unchanged : .changed
            }
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
        if let device = candidate.simulator {
            guard let identity = captureIdentity(at: candidate.url) else { return .missing }
            let fresh = worker.classify(candidate.url, identity: identity)
            return fresh.group == .protected || fresh.simulator != device ? .protected : .unchanged
        }
        if worker.isReleaseProtected(candidate.url) || (candidate.url.pathExtension.lowercased() == "app" && worker.isInstalled(candidate.url)) ||
            worker.cacheOwnerIsRunning(candidate.url) || worker.overlapsRunningApplication(candidate.url) { return .protected }
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
    public static func captureIdentity(at url: URL) -> SpaceCleaningFileIdentity? {
        guard url.isFileURL else { return nil }
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &value) } ?? -1 }) == 0 else { return nil }
        return identity(value)
    }
    fileprivate static func identity(_ value: stat) -> SpaceCleaningFileIdentity? {
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
    fileprivate static func isDirectory(_ value: SpaceCleaningFileIdentity) -> Bool { value.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    fileprivate static func isRegular(_ value: SpaceCleaningFileIdentity) -> Bool { value.mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
    fileprivate static func isSymbolicLink(_ value: SpaceCleaningFileIdentity) -> Bool { value.mode & UInt32(S_IFMT) == UInt32(S_IFLNK) }
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
    /// Resolved once per worker: every classification compares against them.
    let runningPaths: [String]
    let protectedReleasePaths: [String]
    let homePath: String
    let libraryCachesPath: String
    /// Absolute roots of the known locations, longest first.
    let knownRoots: [(rule: SpaceCleaningKnownLocation, root: String)]
    var candidates: [SpaceCleaningCandidate] = []
    var issues: [SpaceCleaningIssue] = []
    var checked = 0
    var limit = false
    // Discovery cannot consume the capacity reserved for content verification.
    // Both phases remain independently bounded; checked is the actual total.
    var phaseChecked = 0
    var phaseLimited = false
    func markLimit() { limit = true; phaseLimited = true }
    var phaseBudget: Int { phase == .discovering ? options.maximumEntries : options.maximumVerificationEntries }
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
        let identity: SpaceCleaningFileIdentity
        let scope: SpaceCleaningScope
        let root: URL
        let rootIdentity: SpaceCleaningFileIdentity
        let ancestors: [SpaceCleaningPathIdentity]
    }
    var pendingCandidates: [PendingCandidate] = []
    var gitWorkTreeCache: [String: Bool] = [:]
    var buildOutputCache: [String: SpaceCleaningBuildOutputs.Kind?] = [:]
    /// Build output recognized by its contents, outside ~/Library (whose
    /// derived data and caches keep their own rules).
    func buildOutputKind(_ url: URL) -> SpaceCleaningBuildOutputs.Kind? {
        if let cached = buildOutputCache[url.path] { return cached }
        let name = url.lastPathComponent.lowercased()
        var result: SpaceCleaningBuildOutputs.Kind?
        if !within(url, "Library"), name.hasSuffix(".xcresult") || name == ".build" || name == "build" || name.contains("deriveddata") ||
            SpaceCleaningBuildOutputs.moduleCacheNames.contains(name) {
            result = SpaceCleaningBuildOutputs.kind(of: url)
        }
        buildOutputCache[url.path] = result
        return result
    }
    private var developmentLookup = SpaceCleaningDevelopmentPolicy.Lookup()
    private func developmentReason(_ url: URL, identity: SpaceCleaningFileIdentity? = nil) -> String? {
        developmentLookup.reason(at: url, identity: identity)
    }

    init(context: SpaceCleaningContext, options: SpaceCleaningOptions, now: Date, metadata: SpaceCleaningMetadataReader = .live,
         cancelled: @escaping () -> Bool, progress: @escaping (SpaceCleaningProgress) -> Void) {
        self.context = context; self.options = options; self.now = now; self.cancelled = cancelled; self.progress = progress
        self.metadata = metadata
        home = Scanner.canonicalURL(context.homeDirectory) ?? context.homeDirectory
        runningBundleIdentifiers = Set(context.runningApplicationURLs.compactMap { Bundle(url: $0)?.bundleIdentifier?.lowercased() })
        func resolved(_ url: URL) -> String { Scanner.canonicalURL(url)?.path ?? url.standardizedFileURL.path }
        runningPaths = context.runningApplicationURLs.map(resolved) + context.runningExecutablePaths
        homePath = home.path
        libraryCachesPath = (homePath == "/" ? "" : homePath) + "/Library/Caches"
        protectedReleasePaths = context.protectedReleaseURLs.map(resolved)
        let base = homePath == "/" ? "" : homePath
        knownRoots = SpaceCleaningKnownLocations.all.map { ($0, base + "/" + $0.path) }.sorted { $0.root.count > $1.root.count }
    }
    /// The known location whose root is or contains this URL.
    func knownLocation(_ url: URL) -> (rule: SpaceCleaningKnownLocation, root: String)? {
        let path = url.path
        return knownRoots.first { Scanner.contains(path, in: $0.root) }
    }
    /// Components below a known root (empty for the root itself).
    func knownComponents(_ url: URL, root: String) -> [Substring] {
        url.path == root ? [] : url.path.dropFirst(root.count + 1).split(separator: "/")
    }
    func overlapsRunningApplication(_ url: URL) -> Bool { runningPaths.contains { overlaps(url.path, $0) } }

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
            } else if scope.kind == .simulators || root.path == simulatorDeviceSetPath {
                // Simulators are whole devices, never large files; the large-file
                // scan leaves the device set alone.
                if options.mode == .cleanup { discoverSimulators(scope, root: root, rootIdentity: rootIdentity) }
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
        measureSimulators(pendingCandidates)
        var rebuildableCandidates: [PendingCandidate] = [], otherCandidates: [PendingCandidate] = []
        for pending in pendingCandidates {
            guard !cancelled() else { break }
            if verificationPriority(pending) == 0 { rebuildableCandidates.append(pending) }
            else { otherCandidates.append(pending) }
        }
        for pending in rebuildableCandidates + otherCandidates {
            guard !cancelled() else { break }
            // The scan is one synchronous call, so nothing drains the caller's pool
            // until it returns. A pool per candidate keeps Foundation temporaries
            // from path and identity checks bounded to that candidate.
            autoreleasepool {
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

    func walk(_ scope: SpaceCleaningScope, directory: URL, root: URL, rootIdentity: SpaceCleaningFileIdentity,
              ancestors: [SpaceCleaningPathIdentity], depth: Int) {
        // Iteration avoids retaining a maximum-sized sibling array at every recursion depth.
        var pending: [(URL, [SpaceCleaningPathIdentity], Int)] = [(directory, ancestors, depth)]
        while let (current, chain, currentDepth) = pending.popLast() {
            // A pool per directory: path and identity checks on its entries leave
            // Foundation temporaries that would otherwise last until the scan returns.
            // The closure returns false to stop the whole walk.
            let proceed = autoreleasepool { () -> Bool in
                guard !cancelled(), !phaseLimited else { return false }
                // A deep directory is skipped on its own; its siblings and later scopes
                // are still discovered, and the report keeps the coverage gap visible.
                guard currentDepth <= options.maximumDepth else {
                    limit = true; issue(scope, current, .depthLimit, "已到达扫描深度上限，未展开此目录。"); return true
                }
                guard let children = readChildren(current, scope: scope) else { return true }
                // In cleanup mode a project tree is searched for recognized items
                // (build output, test results, environments, release folders and
                // installers); individual source files are neither cleanup targets
                // nor allowed to exhaust the shared discovery budget.
                let projectTree = options.mode == .cleanup && within(current, "Developer")
                for child in children {
                    if visitedRoots.contains(where: { Scanner.contains(child.path, in: $0) }) { continue }
                    if projectTree {
                        if !child.hasDirectoryPath, !["pkg", "dmg"].contains(child.pathExtension.lowercased()) { checked += 1; continue }
                        guard visitProjectEntry(child, scope: scope) else { return false }
                    } else {
                        guard visit(child, scope: scope) else { break }
                    }
                    guard let identity = Scanner.captureIdentity(at: child) else { issue(scope, child, .unreadable, "文件已消失或无法读取元数据。"); continue }
                    if child.path == simulatorDeviceSetPath, Scanner.isDirectory(identity), !Scanner.isSymbolicLink(identity) {
                        if options.mode == .cleanup, identity.device == rootIdentity.device, Scanner.canonicalURL(child)?.path == child.path {
                            discoverSimulators(scope, root: child, rootIdentity: identity)
                        }
                        visitedRoots.append(child.path); continue
                    }
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
                return true
            }
            guard proceed else { return }
        }
    }

    var simulatorDeviceSetPath: String { homeRelative(SpaceCleaningSimulators.deviceSetPath) }
    var simulatorSizes: [String: (identity: SpaceCleaningFileIdentity, size: SpaceCleaningSimulators.Size)] = [:]
    /// Devices are separate folder trees and are measured in parallel: walking
    /// close to a million simulator files one by one dominated the scan.
    func measureSimulators(_ pending: [PendingCandidate]) {
        let devices = pending.filter { $0.url.deletingLastPathComponent().path == simulatorDeviceSetPath && Scanner.isDirectory($0.identity) }
        guard !devices.isEmpty, !cancelled() else { return }
        final class Results: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int: SpaceCleaningSimulators.Size] = [:]
            func set(_ index: Int, _ size: SpaceCleaningSimulators.Size) { lock.lock(); values[index] = size; lock.unlock() }
            func get(_ index: Int) -> SpaceCleaningSimulators.Size? { lock.lock(); defer { lock.unlock() }; return values[index] }
        }
        let results = Results(), progress = SpaceCleaningSimulators.Progress(), group = DispatchGroup()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let limit = options.maximumBulkEntries
        for (index, device) in devices.enumerated() {
            let url = device.url, identity = device.identity
            group.enter()
            queue.addOperation {
                results.set(index, SpaceCleaningSimulators.measure(url, expected: identity, limit: limit, progress: progress))
                group.leave()
            }
        }
        let base = checked
        while group.wait(timeout: .now() + 0.2) == .timedOut {
            if cancelled() { progress.stop() }
            checked = base + progress.entries
            emit(scope: devices[0].scope, url: devices[0].root)
        }
        checked = base + progress.entries
        for (index, device) in devices.enumerated() {
            if let size = results.get(index) { simulatorSizes[device.url.path] = (device.identity, size) }
        }
    }
    /// The record of a device folder directly inside the user's device set.
    func simulatorRecord(_ url: URL) -> (device: SpaceCleaningSimulatorDevice, written: Date)? {
        url.deletingLastPathComponent().path == simulatorDeviceSetPath ? SpaceCleaningSimulators.record(at: url) : nil
    }
    /// One item per device folder with a valid record. The device set's own
    /// files and anything unrecognized are left alone.
    func discoverSimulators(_ scope: SpaceCleaningScope, root: URL, rootIdentity: SpaceCleaningFileIdentity) {
        guard let children = readChildren(root, scope: scope) else { return }
        for child in children {
            guard visit(child, scope: scope) else { break }
            guard UUID(uuidString: child.lastPathComponent) != nil, let identity = Scanner.captureIdentity(at: child),
                  Scanner.isDirectory(identity), !Scanner.isSymbolicLink(identity), identity.device == rootIdentity.device,
                  Scanner.canonicalURL(child)?.path == child.path else { continue }
            guard simulatorRecord(child) != nil else {
                issue(scope, child, .unreadable, "无法读取这台模拟器的设备记录，未列出。"); continue
            }
            pendingCandidates.append(.init(url: child, identity: identity, scope: scope, root: root, rootIdentity: rootIdentity,
                                           ancestors: [.init(url: root, identity: rootIdentity)]))
        }
    }
    func simulatorClassification(_ url: URL, _ entry: (device: SpaceCleaningSimulatorDevice, written: Date)) -> Classification {
        let assessment = SpaceCleaningSimulators.assess(entry.device, written: entry.written, now: now,
            referenced: SpaceCleaningSimulators.isReferenced(entry.device, by: context.simulatorReferences),
            runningInside: overlapsRunningApplication(url), toolAvailable: context.simulatorToolAvailable)
        var result = Classification(kind: assessment.kind, group: assessment.group, reason: assessment.reason, impact: assessment.impact,
                                    title: SpaceCleaningSimulators.title(entry.device), suggestion: assessment.suggestion)
        result.simulator = entry.device
        return result
    }

    func discoverReleaseArchives(_ scope: SpaceCleaningScope, root: URL, rootIdentity: SpaceCleaningFileIdentity) {
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

    struct Classification {
        var kind: SpaceCleaningKind; var group: SpaceCleaningGroup; var reason: String; var impact: String; var testable = false
        /// Overrides the file name, such as "npm 下载缓存 · content-v2".
        var title: String? = nil
        /// Listed with suggestions while it stays reviewable; never preselected.
        var suggestion = false
        /// Measured and later verified as one folder (see `bulkMeasure`).
        var bulk = false
        /// An Xcode simulator device, deleted only through Xcode's own tool.
        var simulator: SpaceCleaningSimulatorDevice? = nil
    }
    struct Measurement { var logical: UInt64 = 0; var allocated: UInt64 = 0; var fingerprint: String?; var complete = true; var unsafe = false; var releaseContent = false; var cloudContent = false; var developmentContent = false; var exceededItemBound = false; var latestModified: Int64 = 0 }

    func makeCandidate(_ url: URL, identity: SpaceCleaningFileIdentity, scope: SpaceCleaningScope, root: URL,
                       rootIdentity: SpaceCleaningFileIdentity, ancestors: [SpaceCleaningPathIdentity]) -> SpaceCleaningCandidate? {
        let directory = Scanner.isDirectory(identity)
        if !directory && !Scanner.isSymbolicLink(identity), !visitedFiles.insert(identity.fileKey).inserted {
            issue(scope, url, .duplicate, "同一文件身份已记录，不重复计算容量。"); return nil
        }
        var classification = classify(url, identity: identity)
        if let device = classification.simulator {
            // Sizes only: CoreSimulator owns the files, and the device is deleted
            // as a whole through Xcode's tool, never file by file.
            let size: SpaceCleaningSimulators.Size
            if let measured = simulatorSizes[url.path], measured.identity == identity { size = measured.size }
            else { size = SpaceCleaningSimulators.measure(url, expected: identity, limit: options.maximumBulkEntries, progress: .init()) }
            var group = classification.group, reason = classification.reason
            if !size.complete, group != .protected { group = .protected; reason = "模拟器文件数量超过统计上限或无法完整读取，本次保留。" }
            return .init(scopeID: scope.id, url: url, rootURL: root, rootIdentity: rootIdentity, identity: identity,
                         ancestorIdentities: ancestors, kind: classification.kind, group: group,
                         title: classification.title ?? url.lastPathComponent, reason: reason, impact: classification.impact,
                         logicalBytes: size.logical, allocatedBytes: size.allocated, isDirectory: true, sizeIsComplete: size.complete,
                         isReviewSuggestion: classification.suggestion && group == .review ? true : nil, simulator: device)
        }
        // Later protections replace the classification but keep its readable name.
        let knownTitle = classification.title
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
        } else if directory, classification.bulk {
            let bulk = bulkMeasure(url, rootIdentity: identity, scope: scope)
            measurement.logical = bulk.logical; measurement.allocated = bulk.allocated; measurement.complete = bulk.complete
            measurement.latestModified = bulk.latestModified; measurement.releaseContent = bulk.releaseContent
            measurement.unsafe = bulk.unsafe; measurement.cloudContent = bulk.cloudContent
        } else if directory {
            // Cache folders keep cache semantics: no package links, database and lock checks apply.
            let bundle = ["app", "xcarchive"].contains(url.pathExtension.lowercased()) && !isApplicationCacheFolder(url)
            measurement = measure(url, rootIdentity: identity, scope: scope, allowBundleLinks: bundle,
                                  protectedBudget: classification.group == .protected && !classification.testable)
        } else if Scanner.isRegular(identity) {
            measurement.logical = identity.sizeBytes; measurement.allocated = identity.allocatedBytes
        }
        let known = knownLocation(url)
        if classification.bulk, classification.group == .review, measurement.complete, !measurement.releaseContent,
           !measurement.unsafe, !measurement.cloudContent, let kind = buildOutputKind(url) {
            let days = max(0, Int((now.timeIntervalSince1970 - Double(measurement.latestModified)) / 86_400))
            classification.reason = SpaceCleaningBuildOutputs.reason(kind, days: days)
            if Double(measurement.latestModified) > now.timeIntervalSince1970 - SpaceCleaningBuildOutputs.recentWindow {
                classification.group = .protected; classification.suggestion = false
                classification.reason += "最近 7 天内仍有构建或测试，本次保留。"
                classification.impact = "停止使用满 7 天后再整理，避免影响正在进行的构建与测试。"
            }
        }
        if classification.bulk, measurement.releaseContent, classification.group != .protected {
            classification = .init(kind: .releaseMaterial, group: .protected, reason: "目录中包含安装包、Xcode 归档或发布档案，保留整个目录。",
                                   impact: "请先确认这些文件已另行保存，再在 Finder 中处理。")
        }
        if known?.rule.category == .assistantRecord, classification.group == .review, measurement.complete,
           Double(measurement.latestModified) > now.timeIntervalSince1970 - SpaceCleaningKnownLocations.quietPeriod {
            // An assistant may still be writing here; only quiet folders are offered.
            classification.group = .protected; classification.suggestion = false
            classification.reason += "其中有最近 3 天内仍在更新的内容，本次保留。"
            classification.impact = "停止更新满 3 天后再整理，避免影响正在进行的会话。"
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
            classification.reason = alreadyProtected ? classification.reason + "仅完成部分容量统计。"
                : measurement.exceededItemBound ? "此目录内容超过单项核验上限，本次保留；其他项目不受影响。" +
                    (known?.rule.cleanCommand.map { "也可以在终端运行 \($0) 清理。" } ?? "")
                : classification.bulk ? "文件数量超过整体核验上限或无法完整读取，本次保留。" +
                    (known?.rule.cleanCommand.map { "也可以在终端运行 \($0) 清理。" } ?? "")
                : "内容核验未完成，本次保留；可缩小扫描范围后重试。"
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
                     title: classification.title ?? knownTitle ?? url.lastPathComponent, reason: classification.reason, impact: classification.impact,
                     logicalBytes: measurement.logical, allocatedBytes: measurement.allocated, isDirectory: directory,
                     canConfirmTestPurpose: classification.testable, treeFingerprint: measurement.fingerprint, sizeIsComplete: measurement.complete,
                     isReviewSuggestion: classification.suggestion && classification.group == .review ? true : nil,
                     isBulkVerified: classification.bulk && measurement.complete ? true : nil)
    }

    func classify(_ url: URL, identity: SpaceCleaningFileIdentity) -> Classification {
        if Scanner.isSymbolicLink(identity) { return .init(kind: .symbolicLink, group: .protected, reason: "符号链接默认保留，未跟随目标。", impact: "链接大小不代表目标占用。") }
        if cloudPlaceholder(url) { return .init(kind: .cloudPlaceholder, group: .protected, reason: "云端内容尚未下载到本机，本次保留。", impact: "不触发下载，不计入本机可清理容量。") }
        if Scanner.isDirectory(identity), let entry = simulatorRecord(url) { return simulatorClassification(url, entry) }
        if within(url, SpaceCleaningSimulators.serviceDataPath) {
            return .init(kind: .unsupported, group: .protected, reason: "Xcode 模拟器服务的内部数据，保留。",
                         impact: "模拟器在「开发与归档」范围中按设备列出，只能整台删除。")
        }
        if let reason = developmentReason(url, identity: identity) {
            return .init(kind: .developmentEnvironment, group: .protected, reason: reason,
                         impact: "依赖仍可能用于构建或调试，不提供内部文件清理。")
        }
        if isReleaseProtected(url) { return .init(kind: url.pathExtension.lowercased() == "xcarchive" ? .releaseArchive : .releaseMaterial,
                                                  group: .protected, reason: "正式发布档案或关联材料，保留原件。", impact: "用于发布、更新和问题定位。") }
        if overlapsRunningApplication(url) || cacheOwnerIsRunning(url) {
            var running = Classification(kind: .runningApplication, group: .protected, reason: "关联应用或开发工具正在运行，本次保留。", impact: "退出相关应用后重新扫描。")
            // Keep the readable name and the whole-folder measurement of a recognized item.
            if Scanner.isDirectory(identity), let kind = buildOutputKind(url) {
                running.title = SpaceCleaningBuildOutputs.title(kind, label: buildOutputLabel(url, kind: kind)); running.bulk = true
            } else if let known = knownLocation(url), known.rule.category != .assistantRecord {
                running.title = knownClassification(url, identity: identity, known: known)?.title; running.bulk = known.rule.bulk
            }
            return running
        }
        if Scanner.isRegular(identity), identity.linkCount > 1 { return .init(kind: .hardLink, group: .protected, reason: "文件存在多个硬链接，默认保留。", impact: "删除一个路径不等于释放对应空间。") }
        let ext = url.pathExtension.lowercased()
        // A cache folder named like a bundle identifier (`cn.example.app`) is not an application.
        let cacheFolder = isApplicationCacheFolder(url)
        if ext == "app", !cacheFolder {
            if isInstalled(url) { return .init(kind: .installedApplication, group: .protected, reason: "已安装应用，需通过单独卸载流程处理。", impact: "不纳入文件清理。") }
            return .init(kind: .unknownApplication, group: .protected, reason: "尚未确认是测试副本还是需要保留的导出 App。", impact: "不能仅凭名称、签名或公证状态判断用途。", testable: true)
        }
        if ext == "xcarchive", !cacheFolder { return .init(kind: .unknownArchive, group: .protected, reason: "归档用途待确认，默认保留。", impact: "确认仅用于测试且不是需保留的唯一归档后，可手动复核。", testable: true) }
        if Scanner.isDirectory(identity), let kind = buildOutputKind(url) {
            // Age and size are filled in after the whole-folder measurement.
            return .init(kind: .developmentFile, group: .review, reason: SpaceCleaningBuildOutputs.reason(kind, days: 0),
                         impact: SpaceCleaningBuildOutputs.impact(kind), title: SpaceCleaningBuildOutputs.title(kind, label: buildOutputLabel(url, kind: kind)),
                         suggestion: true, bulk: true)
        }
        if let known = knownLocation(url), let classification = knownClassification(url, identity: identity, known: known) {
            return classification
        }
        if let known = cacheKind(url) {
            if unsafeCacheFileName(url.lastPathComponent) {
                return .init(kind: .unsupported, group: .protected, reason: "缓存中的数据库、事务边车或锁文件默认保留。", impact: "需要先核实应用状态与数据一致性。")
            }
            return .init(kind: known, group: .rebuildable, reason: known == .derivedData ? "已识别的 Xcode 可重建内容。" : "来自已知的可重建缓存位置。",
                         impact: known == .derivedData ? "下次构建或索引可能更慢。" : "相关内容可能需要重新下载或生成。")
        }
        let installerMedia = Scanner.isRegular(identity) && (ext == "pkg" || (ext == "dmg" && (within(url, "Downloads") || within(url, "Desktop"))))
        if installerMedia, isInsideDevelopmentWorkspace(url) {
            return .init(kind: .developmentFile, group: .review,
                         reason: "开发项目、构建产物或依赖中的\(ext.uppercased()) 文件，可能是测试资源或构建输出，不作为安装介质推荐。",
                         impact: "确认不再需要后再手动选择。")
        }
        if installerMedia, ext == "pkg" {
            return .init(kind: .installerPackage, group: .review,
                         reason: "PKG 安装包，可在不再需要安装或保留此版本时选择清理。",
                         impact: "尚未核验安装是否完成；清理后如需安装，需重新获取此安装包。")
        }
        if installerMedia {
            return .init(kind: .downloadedDiskImage, group: .review,
                         reason: "下载或桌面中的磁盘映像，可核对用途后选择清理。",
                         impact: "磁盘映像也可能包含个人文件；尚未核验其内容或安装状态。")
        }
        if cacheFolder || isBrowserCacheSibling(url), Scanner.isDirectory(identity) {
            return .init(kind: .personalFile, group: .review, reason: "其他应用的缓存目录，需确认相关应用不再需要后手动选择。",
                         impact: "应用可能重新下载或生成这些内容；正在使用时清理可能影响其运行。")
        }
        if isPackage(url) { return .init(kind: .package, group: .protected, reason: "应用资源或文稿包默认保留。", impact: "不会拆开包选择内部文件。") }
        if Scanner.isRegular(identity), within(url, "Library/Logs/DiagnosticReports") {
            if ["log", "crash", "ips", "diag", "trace"].contains(ext) {
                let age = now.timeIntervalSince1970 - Double(identity.modifiedSeconds) - Double(identity.modifiedNanoseconds) / 1_000_000_000
                // Diagnostics reached their retention age; their history cannot be rebuilt.
                return age >= options.diagnosticMinimumAge
                    ? .init(kind: .oldDiagnostic, group: .review, reason: "达到保留期限的诊断记录，历史内容删除后无法重新生成。", impact: "如正在排查历史问题，建议保留。")
                    : .init(kind: .recentDiagnostic, group: .protected, reason: "尚未达到诊断记录保留期限。", impact: "保留近期问题定位资料。")
            }
        }
        if !Scanner.isDirectory(identity) && !Scanner.isRegular(identity) { return .init(kind: .unsupported, group: .protected, reason: "特殊文件默认保留。", impact: "不在普通文件处理范围内。") }
        if within(url, Self.derivedDataRoot) {
            return .init(kind: .developmentFile, group: .review, reason: "DerivedData 中未单独识别的内容，需要人工确认。",
                         impact: "多为 Xcode 生成的日志、索引或依赖副本；删除后可能需要重新解析或构建。")
        }
        if within(url, "Downloads") { return .init(kind: .downloadedFile, group: .review, reason: "下载内容，请确认是否仍需保留。", impact: "不会仅因体积大或时间久而推荐删除。") }
        if within(url, "Developer") { return .init(kind: .developmentFile, group: .review, reason: "开发目录中的文件，需要人工确认。", impact: "可能包含项目源码或独有构建材料。") }
        return .init(kind: .personalFile, group: .review, reason: "未匹配整理规则的文件，需要人工复核。", impact: "文件名和修改时间不代表可安全删除。")
    }

    func measure(_ root: URL, rootIdentity: SpaceCleaningFileIdentity, scope: SpaceCleaningScope, allowBundleLinks: Bool,
                 protectedBudget: Bool) -> Measurement {
        var result = Measurement(), hash = SHA256()
        var pending: [(URL, Int)] = [(root, 0)]
        var identities: [(URL, SpaceCleaningFileIdentity)] = []
        var localSeen: Set<String> = []
        // Debug symbols and checksums inside DerivedData are build output or
        // downloaded artifacts; strong release evidence still applies there.
        let generated = cacheKind(root) == .derivedData || within(root, Self.derivedDataRoot)
        // Inside a known package cache, unpacked `node_modules` and lock files are
        // cache structure; the owner was confirmed idle before measuring.
        let known = knownLocation(root).map(\.rule)
        let allowsDevelopmentNames = known?.allowsDevelopmentNames == true
        let allowsLockFiles = known.map { $0.category != .assistantRecord && $0.allowsLockFiles } == true
        // Only the link rule relaxes here; release names and lock files keep their own checks.
        let allowsInternalLinks = allowBundleLinks || known?.allowsInternalLinks == true
        let strongRoot = isStrongReleaseProtected(root)
        let measurementLimit = protectedBudget ? min(10_000, options.maximumEntries) : options.maximumEntries
        var measuredEntries = 0
        while let (directory, depth) = pending.popLast() {
            // A pool per directory, as in discovery: one candidate can hold many
            // thousands of entries. The closure returns false to end the measurement.
            let proceed = autoreleasepool { () -> Bool in
                guard !cancelled(), !phaseLimited else { result.complete = false; return false }
                if cloudPlaceholder(directory) {
                    result.complete = false; result.cloudContent = true
                    issue(scope, directory, .cloudPlaceholder, "目录尚未下载到本机，未读取其中内容。"); return true
                }
                // A per-item bound leaves only this candidate unverified; the shared
                // verification budget (visit) still stops the phase when exhausted.
                guard depth <= options.maximumDepth else {
                    if !protectedBudget { limit = true; result.exceededItemBound = true }
                    result.complete = false; issue(scope, directory, .depthLimit, "已到达目录内容核验深度上限。"); return false
                }
                guard let identity = Scanner.captureIdentity(at: directory), Scanner.isDirectory(identity), identity.device == rootIdentity.device,
                      Scanner.canonicalURL(directory)?.path == directory.path else { result.complete = false; return false }
                identities.append((directory, identity))
                guard let children = readChildren(directory, scope: scope, maximumNames: measurementLimit - measuredEntries + 1) else { result.complete = false; return false }
                for child in children {
                    guard measuredEntries < measurementLimit else {
                        result.complete = false
                        if !protectedBudget { limit = true; result.exceededItemBound = true }
                        issue(scope, root, .entryLimit, protectedBudget ? "受保护目录仅完成有界容量统计，文件继续保留。" : "此目录内容超过单项核验上限，本次保留；其他项目继续核验。")
                        return false
                    }
                    guard visit(child, scope: scope) else { result.complete = false; break }
                    measuredEntries += 1
                    guard let childIdentity = Scanner.captureIdentity(at: child) else { result.complete = false; break }
                    // Files, not folders: compressing old records rewrites folders
                    // while each file keeps its own modification time.
                    if Scanner.isRegular(childIdentity) { result.latestModified = max(result.latestModified, childIdentity.modifiedSeconds) }
                    if !allowsDevelopmentNames, developmentReason(child, identity: childIdentity) != nil {
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
                    if strongRoot || entryAddsStrongReleaseProtection(child) || (!generated && !allowBundleLinks && hasReleaseMaterialName(child)) { result.releaseContent = true }
                    if Scanner.isSymbolicLink(childIdentity) {
                        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: child.path)) ?? ""
                        hash.update(data: Data("link:\(target.utf8.count):\(target)\n".utf8))
                        if !allowsInternalLinks || target.isEmpty || target.hasPrefix("/") ||
                            !(Scanner.canonicalURL(child).map { Scanner.contains($0.path, in: root.path) } ?? false) { result.unsafe = true }
                    } else if Scanner.isDirectory(childIdentity) {
                        pending.append((child, depth + 1))
                    } else if Scanner.isRegular(childIdentity) {
                        if childIdentity.linkCount > 1 { result.unsafe = true }
                        if localSeen.insert(childIdentity.fileKey).inserted, visitedFiles.insert(childIdentity.fileKey).inserted {
                            result.logical = saturatingAdd(result.logical, childIdentity.sizeBytes)
                            result.allocated = saturatingAdd(result.allocated, childIdentity.allocatedBytes)
                        }
                        if !allowBundleLinks && !allowsLockFiles && unsafeCacheFileName(child.lastPathComponent) { result.unsafe = true }
                    } else { result.unsafe = true }
                    emit(scope: scope, url: child)
                }
                return true
            }
            guard proceed else { break }
        }
        if result.complete {
            for (url, identity) in identities where Scanner.captureIdentity(at: url) != identity { result.complete = false; break }
            if Scanner.captureIdentity(at: root) != rootIdentity { result.complete = false }
        }
        result.fingerprint = result.complete ? hash.finalize().map { String(format: "%02x", $0) }.joined() : nil
        return result
    }

    struct BulkMeasurement {
        var logical: UInt64 = 0; var allocated: UInt64 = 0; var entries = 0; var latestModified: Int64 = 0
        var complete = true; var releaseContent = false; var unsafe = false; var cloudContent = false
    }
    /// Sizes a whole-folder item from metadata alone, without content reads or
    /// the shared verification budget. Links are never followed or counted, a
    /// hard-linked file counts once, and another volume inside marks it unsafe.
    func bulkMeasure(_ root: URL, rootIdentity: SpaceCleaningFileIdentity, scope: SpaceCleaningScope) -> BulkMeasurement {
        var result = BulkMeasurement(), hardLinked = Set<UInt64>()
        let limit = options.maximumBulkEntries
        let rootFD = root.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) } ?? -1 }
        guard rootFD >= 0 else { result.complete = false; return result }
        defer { close(rootFD) }
        var opened = stat()
        guard fstat(rootFD, &opened) == 0, UInt64(bitPattern: Int64(opened.st_dev)) == rootIdentity.device,
              UInt64(opened.st_ino) == rootIdentity.inode else { result.complete = false; return result }
        result.latestModified = 0
        func walk(_ descriptor: Int32, depth: Int) -> Bool {
            guard depth <= 128 else { result.complete = false; return false }
            let copy = dup(descriptor)
            guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; result.complete = false; return false }
            defer { closedir(stream) }
            while let item = readdir(stream) {
                let name = withUnsafePointer(to: &item.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                result.entries += 1
                if result.entries % 4_096 == 0 {
                    checked += 4_096; emit(scope: scope, url: root)
                    if cancelled() { result.complete = false; return false }
                }
                guard result.entries <= limit else { result.complete = false; return false }
                var info = stat()
                guard name.withCString({ fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else { result.complete = false; return false }
                guard UInt64(bitPattern: Int64(info.st_dev)) == rootIdentity.device else { result.unsafe = true; continue }
                if Scanner.isCloudPlaceholder(fileFlags: UInt32(info.st_flags)) { result.cloudContent = true; continue }
                let type = info.st_mode & S_IFMT
                if SpaceCleaningFilesystem.isReleaseLikeName(name, isDirectory: type == S_IFDIR) { result.releaseContent = true }
                if type == S_IFREG {
                    result.logical = saturatingAdd(result.logical, UInt64(max(0, info.st_size)))
                    result.latestModified = max(result.latestModified, Int64(info.st_mtimespec.tv_sec))
                    if info.st_nlink <= 1 || hardLinked.insert(UInt64(info.st_ino)).inserted {
                        result.allocated = saturatingAdd(result.allocated, UInt64(max(0, info.st_blocks)) * 512)
                    }
                } else if type == S_IFDIR {
                    let child = name.withCString { openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
                    guard child >= 0 else { result.complete = false; return false }
                    defer { close(child) }
                    guard walk(child, depth: depth + 1) else { return false }
                } else if type != S_IFLNK {
                    result.unsafe = true
                }
            }
            return true
        }
        _ = walk(rootFD, depth: 0)
        return result
    }
    /// Project-relative label: the project for a SwiftPM build folder
    /// (`DeskDen/Launcher`), the folder itself otherwise (`Cards/build/DerivedData`).
    func buildOutputLabel(_ url: URL, kind: SpaceCleaningBuildOutputs.Kind) -> String {
        let target = kind == .swiftPackage ? url.deletingLastPathComponent() : url
        let developer = homeRelative("Developer")
        let base = Scanner.contains(target.path, in: developer) && target.path != developer ? developer : homePath
        let relative = target.path.dropFirst(base.count).split(separator: "/").map(String.init)
        let label = relative.suffix(4).joined(separator: "/")
        return kind == .testResult ? (label as NSString).deletingPathExtension : label
    }
    func shouldAggregate(_ url: URL, scope: SpaceCleaningScope, identity: SpaceCleaningFileIdentity) -> Bool {
        // CoreSimulator's files are never listed one by one; only its own folder
        // is opened so that a wider scope still reaches the device set.
        if within(url, SpaceCleaningSimulators.serviceDataPath) { return url.path != homeRelative(SpaceCleaningSimulators.serviceDataPath) }
        if developmentReason(url, identity: identity) != nil { return true }
        if isPackage(url) || isReleaseProtected(url) { return true }
        if options.mode == .largeFiles { return false }
        if buildOutputKind(url) != nil { return true }
        if cacheKind(url) != nil { return true }
        if isApplicationCacheFolder(url), !["Google", "Firefox"].contains(url.lastPathComponent),
           !visitedRoots.contains(where: { Scanner.contains($0, in: url.path) }) { return true }
        // Siblings of the known browser caches (for example Google/Chrome-headless)
        // are separate cache folders; the known roots keep their own rules.
        if isBrowserCacheSibling(url), !visitedRoots.contains(where: { Scanner.contains($0, in: url.path) }) { return true }
        // DerivedData subfolders that no rule recognizes (logs, package checkouts,
        // text indexes) are reviewed as one item instead of file by file.
        if within(url, Self.derivedDataRoot) {
            let parts = relativeComponents(url, Self.derivedDataRoot)
            if parts.count == 2 && parts[1] != "Build" { return true }
            if parts.count == 3 && parts[1] == "Build" { return true }
        }
        // Known locations list one item per child (or per YYYY/MM month folder).
        if let known = knownLocation(url) {
            let depth = knownComponents(url, root: known.root).count
            switch known.rule.granularity {
            case .children: if depth == 1 { return true }
            case .months: if depth == 2 { return true }
            case .root: break
            }
        }
        // Directories in Downloads/custom locations remain navigable, never wholesale inferred junk.
        return false
    }
    static let derivedDataRoot = "Library/Developer/Xcode/DerivedData"
    func isBrowserCacheSibling(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().path
        guard parent == homeRelative("Library/Caches/Google") || parent == homeRelative("Library/Caches/Firefox") else { return false }
        return ![homeRelative("Library/Caches/Google/Chrome"), homeRelative("Library/Caches/Firefox/Profiles")].contains(url.path)
    }
    private static let workspaceComponents: Set<String> = [".build", "SourcePackages", "checkouts", "DerivedData"]
    /// Installers and disk images inside a project, its build output or a
    /// dependency checkout are usually test resources or build products, not
    /// downloads. A `.git` entry below the home folder marks a working tree;
    /// one in the home folder itself (a dotfiles repository) does not count.
    func isInsideDevelopmentWorkspace(_ url: URL) -> Bool {
        if url.pathComponents.contains(where: { Self.workspaceComponents.contains($0) }) { return true }
        var directory = url.deletingLastPathComponent(), visited: [String] = [], result = false
        while true {
            let path = directory.path
            if path == "/" || path == homePath || path.isEmpty { break }
            if let cached = gitWorkTreeCache[path] { result = cached; break }
            visited.append(path)
            if Scanner.captureIdentity(at: directory.appendingPathComponent(".git", isDirectory: false)) != nil { result = true; break }
            directory.deleteLastPathComponent()
        }
        for path in visited { gitWorkTreeCache[path] = result }
        return result
    }
    func cacheKind(_ url: URL) -> SpaceCleaningKind? {
        let roots = ["Library/Caches/com.apple.Safari", "Library/Containers/com.apple.Safari/Data/Library/Caches", "Library/Caches/Google/Chrome"]
        if roots.contains(where: { within(url, $0) }) { return .browserCache }
        if within(url, "Library/Caches/Firefox/Profiles") {
            let components = relativeComponents(url, "Library/Caches/Firefox/Profiles")
            if components.count >= 2 && components[1] == "cache2" { return .browserCache }
        }
        if let known = knownLocation(url), known.rule.category != .assistantRecord {
            // Unversioned JetBrains folders (Toolbox, daemons) are not IDE caches.
            if known.rule.path == "Library/Caches/JetBrains", let first = knownComponents(url, root: known.root).first,
               SpaceCleaningKnownLocations.jetBrainsVersion(String(first)) == nil { return nil }
            return .packageCache
        }
        if within(url, Self.derivedDataRoot) {
            let parts = relativeComponents(url, Self.derivedDataRoot)
            // Generated module, SDK and compilation caches live at the top level
            // and again inside custom -derivedDataPath roots and project folders.
            let generated: Set<String> = ["ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex",
                                          "SymbolCache.noindex", "SDKExplicitPrecompiledModules"]
            if let first = parts.first, generated.contains(first) { return .derivedData }
            if parts.count >= 2 && (parts[1] == "Index.noindex" || generated.contains(parts[1])) { return .derivedData }
            if parts.count >= 3 && parts[1] == "Build" && ["Intermediates.noindex", "Products"].contains(parts[2]) { return .derivedData }
        }
        return nil
    }
    func cacheOwnerIsRunning(_ url: URL) -> Bool {
        if within(url, "Library/Caches"), let owner = relativeComponents(url, "Library/Caches").first,
           runningBundleIdentifiers.contains(owner.lowercased()) { return true }
        // Browsers and Xcode match by bundle identifier as well as bundle name:
        // a renamed app keeps its identifier, and either signal keeps the cache.
        let running = context.runningApplicationURLs.map { $0.lastPathComponent.lowercased() }
        func identifier(_ matches: (String) -> Bool) -> Bool { runningBundleIdentifiers.contains(where: matches) }
        let tools = context.activeToolNames
        if within(url, "Library/Caches/com.apple.Safari") || within(url, "Library/Containers/com.apple.Safari") {
            return running.contains("safari.app") || identifier { $0 == "com.apple.safari" }
        }
        if within(url, "Library/Caches/Google/Chrome") {
            return running.contains { $0.hasPrefix("google chrome") } || identifier { $0.hasPrefix("com.google.chrome") }
        }
        if within(url, "Library/Caches/Firefox") {
            return running.contains { $0.hasPrefix("firefox") } || identifier { $0.hasPrefix("org.mozilla.firefox") || $0 == "org.mozilla.nightly" }
        }
        if within(url, "Library/Developer/Xcode/DerivedData") {
            return running.contains { $0.hasPrefix("xcode") } || identifier { $0 == "com.apple.dt.xcode" } ||
                !tools.isDisjoint(with: ["xcodebuild", "swift", "swift-frontend", "swift-driver", "clang", "clang++", "XCBBuildService", "SWBBuildService"])
        }
        // Tool identities come from SpaceCleaningToolActivity, which reads the
        // launch script of interpreted tools; raw names remain accepted.
        if let kind = buildOutputKind(url) { return !SpaceCleaningBuildOutputs.owners(kind).isDisjoint(with: tools) }
        if let known = knownLocation(url), known.rule.category != .assistantRecord {
            if !known.rule.tools.isDisjoint(with: tools) { return true }
            // JetBrains Toolbox stays open in the background and never uses IDE caches.
            return known.rule.bundlePrefixes.contains { prefix in
                identifier { $0.hasPrefix(prefix.lowercased()) && $0 != "com.jetbrains.toolbox" }
            }
        }
        return false
    }
    /// Names what a known location is and what removing it costs. Returns nil
    /// for entries the rule does not describe, which keep the generic rules.
    func knownClassification(_ url: URL, identity: SpaceCleaningFileIdentity,
                             known: (rule: SpaceCleaningKnownLocation, root: String)) -> Classification? {
        let rule = known.rule, parts = knownComponents(url, root: known.root)
        let name = url.lastPathComponent
        switch rule.category {
        case .assistantRecord:
            guard Scanner.isDirectory(identity) else { return nil }
            let label: String
            switch rule.granularity {
            case .months:
                guard parts.count == 2, let month = SpaceCleaningKnownLocations.monthTitle(year: String(parts[0]), month: String(parts[1])) else { return nil }
                label = month
            case .children:
                guard parts.count == 1 else { return nil }
                label = SpaceCleaningKnownLocations.claudeProjectName(name, homePath: homePath)
            case .root:
                guard parts.isEmpty else { return nil }
                label = ""
            }
            return .init(kind: .personalFile, group: .review, reason: rule.reason, impact: rule.impact,
                         title: label.isEmpty ? rule.title : rule.title + " · " + label, suggestion: true)
        case .toolCache, .toolDownload:
            let depth = rule.granularity == .root ? 0 : 1
            guard parts.count == depth else { return nil }
            if depth == 1, !Scanner.isDirectory(identity),
               unsafeCacheFileName(name) || ["cachedir.tag", ".gitignore", "readme", "readme.md", "readme.txt"].contains(name.lowercased()) {
                return .init(kind: .unsupported, group: .protected, reason: "缓存目录的标记或锁文件，保留。", impact: "体积很小，用于协调缓存的读写。")
            }
            let title = depth == 0 ? rule.title : rule.title + " · " + name
            if rule.path == "Library/Caches/JetBrains" {
                guard let version = SpaceCleaningKnownLocations.jetBrainsVersion(name) else {
                    return .init(kind: .personalFile, group: .review, reason: "JetBrains 目录中的其他缓存（例如 Toolbox 或后台服务）。",
                                 impact: "相关应用可能重新下载或生成这些内容；正在使用时清理可能影响其运行。", title: title)
                }
                if isNewestJetBrainsVersion(url, version: version) {
                    return .init(kind: .packageCache, group: .review, reason: "当前 \(version.product) 版本的缓存与索引。",
                                 impact: rule.impact, title: title, suggestion: true)
                }
                return .init(kind: .packageCache, group: .rebuildable,
                             reason: "旧版本 \(version.product) 留下的缓存与索引，新版本不会再使用。",
                             impact: "如仍在使用这个旧版本，下次打开项目时会重新建立索引。", title: title)
            }
            return .init(kind: .packageCache, group: rule.category == .toolCache ? .rebuildable : .review,
                         reason: rule.reason, impact: rule.bulk ? rule.impact + SpaceCleaningBuildOutputs.wholeFolderNote : rule.impact,
                         title: title, suggestion: rule.category == .toolDownload, bulk: rule.bulk)
        }
    }
    /// Product folders of the same name compare by version; the newest is current.
    func isNewestJetBrainsVersion(_ url: URL, version: (product: String, version: [Int])) -> Bool {
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return !siblings.contains { sibling in
            guard let other = SpaceCleaningKnownLocations.jetBrainsVersion(sibling), other.product == version.product else { return false }
            return other.version.lexicographicallyPrecedes(version.version) == false && other.version != version.version
        }
    }
    func isReleaseProtected(_ url: URL) -> Bool { isStrongReleaseProtected(url) || hasReleaseMaterialName(url) }
    func hasReleaseMaterialName(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased(), name = url.lastPathComponent.lowercased()
        return ext == "dsym" || ["appcast.xml", "appcast.json", "sha256sums", "sha256sums.txt", "checksums.txt", "distribution-summary.plist"].contains(name)
    }
    func isStrongReleaseProtected(_ url: URL) -> Bool {
        let path = url.path
        if protectedReleasePaths.contains(where: { overlaps(path, $0) }) { return true }
        // An ASCII-lowercased substring test only skips work; the component rules decide.
        let lowered = path.lowercased()
        if lowered.contains("releasearchives"), url.pathComponents.contains(where: { $0.lowercased() == "releasearchives" }) { return true }
        guard lowered.contains(".xcarchive") else { return false }
        var parent = url
        while parent.path != "/" {
            if parent.pathExtension.lowercased() == "xcarchive", archiveHasDistributionRecords(parent) { return true }
            let next = parent.deletingLastPathComponent()
            if next.path == parent.path { break }
            parent = next
        }
        return false
    }
    /// Per-entry form used while measuring a tree whose root was already checked
    /// with isStrongReleaseProtected: every in-tree ancestor is checked when it
    /// is visited, so only the entry's own name and records are new evidence.
    func entryAddsStrongReleaseProtection(_ url: URL) -> Bool {
        if url.lastPathComponent.lowercased() == "releasearchives" { return true }
        if url.pathExtension.lowercased() == "xcarchive", archiveHasDistributionRecords(url) { return true }
        return !protectedReleasePaths.isEmpty && protectedReleasePaths.contains { overlaps(url.path, $0) }
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
        // Per-app cache folders are named after bundle identifiers such as
        // `org.swift.swiftpm`, which Launch Services may report as a package.
        guard !isApplicationCacheFolder(url) else { return false }
        return ["app", "xcarchive", "dsym", "pkg", "bundle", "framework", "plugin", "photoslibrary", "photolibrary", "rtfd", "pages", "numbers", "key", "xcodeproj", "xcworkspace"].contains(url.pathExtension.lowercased()) ||
            (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
    /// A direct child of ~/Library/Caches: one application's cache folder.
    func isApplicationCacheFolder(_ url: URL) -> Bool { url.deletingLastPathComponent().path == libraryCachesPath }
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
    /// Joins strings: appendingPathComponent without a hint would stat each call.
    func homeRelative(_ relative: String) -> String { (homePath == "/" ? "" : homePath) + "/" + relative }
    func within(_ url: URL, _ relative: String) -> Bool { Scanner.contains(url.path, in: homeRelative(relative)) }
    func relativeComponents(_ url: URL, _ relative: String) -> [String] {
        let root = homeRelative(relative)
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
        case .derivedData, .development, .assistantData, .simulators: .development
        case .downloads, .custom: .downloads
        case .archives, .releaseArchives, .releaseArchiveDiscovery, .installedApplications: .protection
        }
    }
    func issue(_ scope: SpaceCleaningScope, _ url: URL, _ kind: SpaceCleaningIssueKind, _ reason: String) {
        issues.append(.init(scopeID: scope.id, url: url, kind: kind, reason: reason))
    }
    func visit(_ url: URL, scope: SpaceCleaningScope) -> Bool {
        guard !cancelled() else { return false }
        guard phaseChecked < phaseBudget else {
            if !phaseLimited {
                issue(scope, url, .entryLimit, phase == .discovering ? "已到达本次扫描条目上限，结果不完整。" : "已到达本次核验总量上限，其余项目保留。")
            }
            markLimit(); return false
        }
        checked += 1; phaseChecked += 1; emit(scope: scope, url: url); return true
    }
    /// Project-tree directories have their own bound so that a large Developer
    /// folder cannot starve later scopes; reaching it still marks the scan partial.
    var projectEntriesVisited = 0
    func visitProjectEntry(_ url: URL, scope: SpaceCleaningScope) -> Bool {
        guard !cancelled() else { return false }
        guard projectEntriesVisited < options.maximumBulkEntries else {
            if !limit { issue(scope, url, .entryLimit, "开发目录数量超过本次查找上限，结果不完整。") }
            limit = true; return false
        }
        projectEntriesVisited += 1; checked += 1
        if projectEntriesVisited % 256 == 0 { emit(scope: scope, url: url) }
        return true
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
        var names: [(name: String, type: UInt8)] = []
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
            if names.count >= min(phaseBudget - phaseChecked + 1, maximumNames ?? phaseBudget + 1) {
                // The extra name is a sentinel: visiting it reports the bound after
                // genuinely checking the retained entries, rather than claiming work.
                break
            }
            names.append((name, entry.pointee.d_type))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, Scanner.identity(after) == beforeIdentity,
              Scanner.captureIdentity(at: url) == beforeIdentity, Scanner.canonicalURL(url)?.path == url.path else {
            issue(scope, url, .changed, "读取期间目录发生变化，已跳过。"); return nil
        }
        // A bare appendingPathComponent stats every name to decide on a trailing
        // slash. readdir already reports the (no-follow) type; only an unknown
        // type falls back to that lookup, so the URLs keep their usual form.
        return names.sorted { $0.name < $1.name }.map { entry in
            entry.type == UInt8(DT_UNKNOWN) ? url.appendingPathComponent(entry.name)
                : url.appendingPathComponent(entry.name, isDirectory: entry.type == UInt8(DT_DIR))
        }
    }
}
