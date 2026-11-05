import Foundation

/// Fixed, home-anchored locations whose owner and consequence are known.
/// A rule names what the folder is, what removing it costs, which tools keep
/// it in use and, for caches too large to verify item by item, the owner's
/// own cleanup command. Nothing here makes a project workspace disposable.
struct SpaceCleaningKnownLocation: Sendable {
    enum Granularity: Sendable {
        /// The folder itself is one item; it is reached as a child of `Library/Caches`.
        case root
        /// Each direct child of the folder is one item; the folder gets its own scope.
        case children
        /// `YYYY/MM` folders below the folder are items; the folder gets its own scope.
        case months
    }
    enum Category: Sendable {
        /// Rebuildable download or build cache: preselected while its owner is idle.
        case toolCache
        /// Rebuildable, but restoring it needs an explicit step: listed, never preselected.
        case toolDownload
        /// Records an assistant keeps for the user: listed only after a quiet period.
        case assistantRecord
    }

    let path: String
    let granularity: Granularity
    let category: Category
    let title: String
    let reason: String
    let impact: String
    var tools: Set<String> = []
    var bundlePrefixes: [String] = []
    var cleanCommand: String?
    /// Lock, journal and database names belong to the cache itself; the owner
    /// is checked before scanning and again before any file operation.
    var allowsLockFiles = false
    /// Package managers store unpacked packages with `node_modules` or `.git`
    /// inside the cache; those names do not mark a project there.
    var allowsDevelopmentNames = false
    /// Downloaded browsers and runtimes are app bundles whose relative links
    /// stay inside the item; absolute or escaping links still protect it.
    var allowsInternalLinks = false
    /// Caches with too many files to verify one by one are measured and
    /// verified as whole folders instead (see `SpaceCleaningBuildOutputs`).
    var bulk = false
    var scopeTitle: String?

    var isDedicatedScope: Bool { granularity != .root }
}

enum SpaceCleaningKnownLocations {
    static let quietPeriod: TimeInterval = 3 * 24 * 60 * 60
    static let packageManagers: Set<String> = [SpaceCleaningToolActivity.npm, "npx", SpaceCleaningToolActivity.yarn, SpaceCleaningToolActivity.pnpm, SpaceCleaningToolActivity.bun]
    static let swiftBuild: Set<String> = ["swift", "swift-package", "swift-build", "xcodebuild", "XCBBuildService", "SWBBuildService"]

    static let all: [SpaceCleaningKnownLocation] = [
        .init(path: ".npm/_cacache", granularity: .children, category: .toolCache, title: "npm 下载缓存",
              reason: "npm 下载过的依赖包副本。", impact: "下次安装依赖时会重新下载，不影响已经安装好的项目。",
              tools: [SpaceCleaningToolActivity.npm, "npx"], cleanCommand: "npm cache clean --force"),
        .init(path: "Library/Caches/Homebrew", granularity: .children, category: .toolCache, title: "Homebrew 下载缓存",
              reason: "Homebrew 下载过的安装包与元数据。", impact: "重新安装或升级软件时会重新下载，已安装的软件不受影响。",
              tools: [SpaceCleaningToolActivity.homebrew], cleanCommand: "brew cleanup --prune=all"),
        .init(path: "Library/Caches/pip", granularity: .children, category: .toolCache, title: "pip 下载缓存",
              reason: "pip 下载过的 Python 包副本。", impact: "下次安装 Python 包时会重新下载，已安装的环境不受影响。",
              tools: [SpaceCleaningToolActivity.pip, "pip3"], cleanCommand: "pip cache purge"),
        .init(path: "Library/Caches/org.swift.swiftpm", granularity: .children, category: .toolCache, title: "Swift Package 缓存",
              reason: "Swift Package Manager 共享的依赖下载副本。", impact: "下次解析依赖时会重新下载。",
              tools: swiftBuild),
        .init(path: "Library/Caches/Yarn", granularity: .root, category: .toolCache, title: "Yarn 下载缓存",
              reason: "Yarn 1 下载并解压过的依赖包。", impact: "下次安装依赖时会重新下载，不影响已经安装好的项目。",
              tools: [SpaceCleaningToolActivity.yarn], cleanCommand: "yarn cache clean", allowsLockFiles: true, allowsDevelopmentNames: true, bulk: true),
        .init(path: ".yarn/berry/cache", granularity: .children, category: .toolCache, title: "Yarn 全局缓存",
              reason: "Yarn 2 及以上版本共享的依赖压缩包。", impact: "下次安装依赖时会重新下载；项目内的 .yarn/cache 不在此处。",
              tools: [SpaceCleaningToolActivity.yarn], cleanCommand: "yarn cache clean --all", allowsLockFiles: true, scopeTitle: "Yarn 全局缓存"),
        .init(path: "Library/Caches/pnpm", granularity: .root, category: .toolCache, title: "pnpm 元数据缓存",
              reason: "pnpm 查询过的包元数据与临时执行的工具。依赖文件本身保存在 pnpm store，不在这里。", impact: "下次安装或临时执行工具时会重新获取。",
              tools: [SpaceCleaningToolActivity.pnpm], allowsLockFiles: true, allowsDevelopmentNames: true, allowsInternalLinks: true),
        .init(path: ".cache/uv", granularity: .children, category: .toolCache, title: "uv 缓存",
              reason: "uv 下载和构建过的 Python 包。", impact: "下次创建环境或安装包时会重新下载或构建，已有虚拟环境不受影响。",
              tools: [SpaceCleaningToolActivity.uv], cleanCommand: "uv cache clean", allowsLockFiles: true, allowsDevelopmentNames: true,
              bulk: true, scopeTitle: "uv 缓存"),
        .init(path: "Library/Caches/JetBrains", granularity: .children, category: .toolCache, title: "JetBrains 缓存",
              reason: "JetBrains IDE 的缓存与索引。", impact: "IDE 下次打开项目时会重新建立索引，可能需要几分钟。",
              bundlePrefixes: ["com.jetbrains."], allowsLockFiles: true, allowsDevelopmentNames: true, scopeTitle: "JetBrains 缓存"),
        .init(path: "Library/Caches/pypoetry", granularity: .children, category: .toolCache, title: "Poetry 缓存",
              reason: "Poetry 下载过的包与构建产物。", impact: "下次安装依赖时会重新下载。",
              tools: [SpaceCleaningToolActivity.poetry], allowsLockFiles: true, scopeTitle: "Poetry 缓存"),
        .init(path: ".gradle/caches", granularity: .children, category: .toolCache, title: "Gradle 缓存",
              reason: "Gradle 下载的依赖与构建缓存。", impact: "下次构建时会重新下载依赖，首次构建会变慢。",
              tools: [SpaceCleaningToolActivity.gradle], allowsLockFiles: true, bulk: true, scopeTitle: "Gradle 缓存"),
        .init(path: ".gradle/wrapper/dists", granularity: .children, category: .toolCache, title: "Gradle 发行版",
              reason: "Gradle Wrapper 下载的 Gradle 版本。", impact: "使用对应版本的项目下次构建时会重新下载。",
              tools: [SpaceCleaningToolActivity.gradle], allowsLockFiles: true, scopeTitle: "Gradle 发行版"),
        .init(path: ".cargo/registry", granularity: .children, category: .toolCache, title: "Cargo 依赖缓存",
              reason: "Cargo 下载的 crate 索引、压缩包和解压源码。", impact: "下次构建 Rust 项目时会重新下载；已安装的命令行工具不在此处。",
              tools: [SpaceCleaningToolActivity.cargo], allowsLockFiles: true, bulk: true, scopeTitle: "Cargo 依赖缓存"),
        .init(path: "Library/Caches/go-build", granularity: .root, category: .toolCache, title: "Go 构建缓存",
              reason: "Go 编译和测试的中间结果。", impact: "下次构建或测试 Go 项目时会重新编译，首次会变慢。",
              tools: [SpaceCleaningToolActivity.go], cleanCommand: "go clean -cache", allowsLockFiles: true, bulk: true),
        .init(path: "Library/Caches/CocoaPods", granularity: .root, category: .toolCache, title: "CocoaPods 缓存",
              reason: "CocoaPods 下载过的依赖与规格仓库副本。", impact: "下次执行 pod install 时会重新下载。",
              tools: [SpaceCleaningToolActivity.cocoapods], cleanCommand: "pod cache clean --all", allowsLockFiles: true, allowsDevelopmentNames: true),
        .init(path: "Library/Caches/org.carthage.CarthageKit", granularity: .root, category: .toolCache, title: "Carthage 缓存",
              reason: "Carthage 下载过的依赖与二进制。", impact: "下次构建依赖时会重新下载。",
              tools: [SpaceCleaningToolActivity.carthage], allowsLockFiles: true, allowsDevelopmentNames: true),
        .init(path: "Library/Caches/deno", granularity: .root, category: .toolCache, title: "Deno 缓存",
              reason: "Deno 下载和编译过的模块。", impact: "下次运行相关脚本时会重新下载。",
              tools: [SpaceCleaningToolActivity.deno], allowsLockFiles: true),
        .init(path: "Library/Caches/composer", granularity: .root, category: .toolCache, title: "Composer 缓存",
              reason: "Composer 下载过的 PHP 依赖。", impact: "下次安装依赖时会重新下载。",
              tools: [SpaceCleaningToolActivity.composer], cleanCommand: "composer clear-cache", allowsLockFiles: true),
        .init(path: "Library/Caches/node-gyp", granularity: .root, category: .toolCache, title: "node-gyp 头文件缓存",
              reason: "编译 Node 原生模块时下载的 Node 头文件。", impact: "下次编译原生模块时会重新下载。",
              tools: packageManagers),
        .init(path: "Library/Caches/electron", granularity: .root, category: .toolCache, title: "Electron 下载缓存",
              reason: "安装 Electron 项目时下载的 Electron 程序包。", impact: "下次安装相关项目时会重新下载。",
              tools: packageManagers, allowsInternalLinks: true),
        .init(path: "Library/Caches/electron-builder", granularity: .root, category: .toolCache, title: "electron-builder 缓存",
              reason: "打包 Electron 应用时下载的工具与运行时。", impact: "下次打包时会重新下载。",
              tools: packageManagers, allowsInternalLinks: true),
        .init(path: "Library/Caches/ms-playwright", granularity: .root, category: .toolDownload, title: "Playwright 浏览器",
              reason: "Playwright 自动化测试下载的浏览器。", impact: "删除后需要先运行 npx playwright install 重新下载，测试才能继续运行。",
              tools: [SpaceCleaningToolActivity.playwright, SpaceCleaningToolActivity.testBrowser], allowsInternalLinks: true),
        .init(path: ".cache/puppeteer", granularity: .children, category: .toolDownload, title: "Puppeteer 浏览器",
              reason: "Puppeteer 下载的测试浏览器。", impact: "删除后需要重新安装 Puppeteer 浏览器，相关脚本才能继续运行。",
              tools: [SpaceCleaningToolActivity.testBrowser], allowsInternalLinks: true, scopeTitle: "Puppeteer 浏览器"),
        .init(path: ".codex/sessions", granularity: .months, category: .assistantRecord, title: "Codex 会话记录",
              reason: "Codex 保存的对话原文、工具调用与输出，按会话开始的月份汇总。",
              impact: "删除后无法在 Codex 中继续或回看这些对话；移入废纸篓期间仍可从清理记录恢复。", scopeTitle: "Codex 会话记录"),
        .init(path: ".codex/visualizations", granularity: .months, category: .assistantRecord, title: "Codex 可视化与截图",
              reason: "Codex 会话中生成的网页原型、截图和渲染结果，按月份汇总。",
              impact: "删除后，对应会话中的图片和原型无法再打开。", allowsDevelopmentNames: true, allowsInternalLinks: true,
              scopeTitle: "Codex 可视化与截图"),
        .init(path: ".claude/projects", granularity: .children, category: .assistantRecord, title: "Claude Code 会话记录",
              reason: "Claude Code 为这个项目保存的对话记录与工具输出。",
              impact: "删除后无法在 Claude Code 中继续或回看这些会话；记忆与设置不在此处。", scopeTitle: "Claude Code 会话记录")
    ]

    /// Dedicated scopes, scanned before the broad `Library/Caches` review.
    static var dedicatedScopes: [SpaceCleaningKnownLocation] { all.filter(\.isDedicatedScope) }

    /// Known caches verified as whole folders, matched on the item's own path.
    static func allowsBulk(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        return all.contains { rule in
            guard rule.bulk else { return false }
            switch rule.granularity {
            case .root: return url.path.hasSuffix("/" + rule.path)
            case .children: return parent.path.hasSuffix("/" + rule.path)
            case .months: return false
            }
        }
    }

    /// Items whose `node_modules`, `.git` or virtual environments are cache or
    /// assistant-output structure (unpacked packages, generated prototypes).
    /// Matched on the item's own path: the scanner only assigns these items
    /// under the home folder, and every other location keeps the
    /// transaction's independent project check.
    static func allowsProjectNames(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        return all.contains { rule in
            guard rule.allowsDevelopmentNames else { return false }
            switch rule.granularity {
            case .root: return url.path.hasSuffix("/" + rule.path)
            case .children: return parent.path.hasSuffix("/" + rule.path)
            case .months: return parent.deletingLastPathComponent().path.hasSuffix("/" + rule.path)
            }
        }
    }

    /// JetBrains keeps one cache folder per product version, such as `WebStorm2025.1`.
    static func jetBrainsVersion(_ name: String) -> (product: String, version: [Int])? {
        guard let index = name.firstIndex(where: \.isNumber), index != name.startIndex else { return nil }
        let product = String(name[..<index])
        guard product.allSatisfy(\.isLetter) else { return nil }
        let parts = name[index...].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }), parts[0].count == 4 else { return nil }
        return (product, parts.compactMap { Int($0) })
    }

    /// `-Users-name-Developer-App` names the project folder Claude Code was started in.
    static func claudeProjectName(_ slug: String, homePath: String) -> String {
        let home = homePath.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        if slug == home { return "主目录" }
        if slug.hasPrefix(home + "-") { return String(slug.dropFirst(home.count + 1)) }
        return slug
    }

    static func monthTitle(year: String, month: String) -> String? {
        guard year.count == 4, Int(year) != nil, let value = Int(month), (1...12).contains(value), month.count <= 2 else { return nil }
        return "\(year) 年 \(value) 月"
    }
}
