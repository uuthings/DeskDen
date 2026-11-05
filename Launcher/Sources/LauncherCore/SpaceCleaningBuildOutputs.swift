import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Regenerable build output recognized by its contents, never by a folder
/// name alone: agents also keep logs, screenshots, release candidates and
/// assets in folders called `build` or `.build`. Only these exact layouts are
/// items, and each is verified as one folder (see `metadataSnapshot`).
enum SpaceCleaningBuildOutputs {
    enum Kind: Equatable, Sendable {
        /// A `.build` beside `Package.swift` holding only SwiftPM's own entries.
        case swiftPackage
        /// An Xcode derived-data folder outside `~/Library/Developer` (`-derivedDataPath`).
        case derivedData
        /// A standalone compiler module cache.
        case moduleCache
        /// An Xcode test result bundle.
        case testResult
    }

    /// Items with a file modified more recently than this stay protected.
    static let recentWindow: TimeInterval = 7 * 24 * 60 * 60

    static let swiftPackageEntries: Set<String> = [
        ".buildsystem_debug", ".buildsystem_release", ".lock", "cachedir.tag", "artifacts", "checkouts", "repositories",
        "debug", "release", "manifest.pif", "out", "workspace-state.json", "build.db", "debug.yaml", "release.yaml",
        "plugins", "index-build", "prebuilts", "plugin-tools.yaml", "description.json", ".ds_store"
    ]
    static let derivedDataEntries: Set<String> = [
        "build", "index.noindex", "modulecache.noindex", "logs", "info.plist", "compilationcache.noindex",
        "sdkstatcaches.noindex", "sourcepackages", "sdkexplicitprecompiledmodules", "textindex", "symbolcache.noindex",
        "explicitprecompiledmodules", ".ds_store"
    ]
    static let moduleCacheNames: Set<String> = ["modulecache", "swiftmodulecache", "modulecache.noindex", "compilationcache.noindex"]

    /// Reads at most one directory listing and one sibling lookup.
    static func kind(of url: URL) -> Kind? {
        let name = url.lastPathComponent, lower = name.lowercased()
        guard let children = listing(url) else { return nil }
        if (lower as NSString).pathExtension == "xcresult" {
            return children.contains("info.plist") ? .testResult : nil
        }
        if moduleCacheNames.contains(lower) { return children.isEmpty ? nil : .moduleCache }
        if lower == ".build", isRegularFile(url.deletingLastPathComponent().appendingPathComponent("Package.swift", isDirectory: false)),
           !children.isEmpty, children.allSatisfy({ swiftPackageEntries.contains($0) || isTargetTriple($0) }) {
            return .swiftPackage
        }
        if lower.contains("deriveddata") || lower == "build" || lower == ".build",
           children.contains("info.plist"), !children.isDisjoint(with: ["build", "index.noindex", "modulecache.noindex"]),
           children.allSatisfy(derivedDataEntries.contains) {
            return .derivedData
        }
        return nil
    }

    /// `arm64-apple-macosx`, `x86_64-unknown-linux-gnu` and similar build folders.
    static func isTargetTriple(_ name: String) -> Bool {
        let parts = name.split(separator: "-")
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty } &&
            ["apple", "unknown", "pc", "none"].contains(String(parts[1])) && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    static func title(_ kind: Kind, label: String) -> String {
        switch kind {
        case .swiftPackage: "Swift 构建产物 · " + label
        case .derivedData: "Xcode 构建产物 · " + label
        case .moduleCache: "编译模块缓存 · " + label
        case .testResult: "Xcode 测试结果 · " + label
        }
    }
    static func reason(_ kind: Kind, days: Int) -> String {
        let age = days <= 0 ? "今天" : "\(days) 天前"
        switch kind {
        case .swiftPackage: return "Swift Package Manager 的构建产物与依赖副本，最后构建于\(age)。"
        case .derivedData: return "项目内的 Xcode 构建目录（编译产物、索引与依赖副本），最后构建于\(age)。"
        case .moduleCache: return "编译器生成的模块缓存，最后更新于\(age)。"
        case .testResult: return "Xcode 运行测试时保存的结果包（日志、截图与覆盖率），生成于\(age)。"
        }
    }
    static let wholeFolderNote = "按整个文件夹核验：只核对文件夹身份、相关工具未运行和总大小，不逐个比对文件内容。"
    static func impact(_ kind: Kind) -> String {
        switch kind {
        case .swiftPackage: "删除后下次构建会重新下载依赖并完整编译。" + wholeFolderNote
        case .derivedData: "删除后下次构建或打开项目会重新编译并建立索引。" + wholeFolderNote
        case .moduleCache: "下次编译时自动重建。" + wholeFolderNote
        case .testResult: "删除后无法再查看这次测试的详细结果；需要时重新运行测试。" + wholeFolderNote
        }
    }
    /// Tools that write each kind while they run.
    static func owners(_ kind: Kind) -> Set<String> {
        switch kind {
        case .swiftPackage: ["swift", "swift-build", "swift-package", "swift-test", "swift-run", "swift-frontend", "swift-driver", "sourcekit-lsp"]
        case .derivedData, .moduleCache: ["xcodebuild", "swift-frontend", "swift-driver", "clang"]
        case .testResult: ["xcodebuild"]
        }
    }

    private static func listing(_ url: URL) -> Set<String>? {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &info) } ?? -1 }) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        return Set(names.map { $0.lowercased() })
    }
    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &info) } ?? -1 }) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
}
