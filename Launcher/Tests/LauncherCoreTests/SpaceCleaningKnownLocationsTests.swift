import XCTest
@testable import LauncherCore

private struct KnownLocationMover: SpaceCleaningFileOperating {
    var directory: URL
    func moveToTrash(_ source: URL) throws -> URL {
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }
}

final class SpaceCleaningKnownLocationsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceCleaningKnown-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonical = try XCTUnwrap(SpaceCleaningScanner.canonicalURL(root))
        defer { try? FileManager.default.removeItem(at: canonical) }
        try body(canonical)
    }
    @discardableResult private func file(_ root: URL, _ relative: String, bytes: Int = 20) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: bytes).write(to: url)
        return url
    }
    private func scan(_ home: URL, _ relative: String, kind: SpaceCleaningScopeKind = .packageCache,
                      context: SpaceCleaningContext? = nil, options: SpaceCleaningOptions = .init()) -> SpaceCleaningReport {
        SpaceCleaningScanner.scan(scopes: [.init(directory: home.appendingPathComponent(relative), kind: kind)],
                                  context: context ?? .init(homeDirectory: home), options: options, now: now)
    }
    /// Sets the modification time of a path and every directory between it and `stop`.
    private func age(_ url: URL, to date: Date, through stop: URL) throws {
        var current = url
        while current.path.count > stop.path.count {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: current.path)
            current.deleteLastPathComponent()
        }
    }
    private func application(_ home: URL, _ name: String, identifier: String) throws -> URL {
        let url = home.appendingPathComponent("Running/" + name)
        let info = try file(home, "Running/\(name)/Contents/Info.plist")
        let plist: [String: String] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        return url
    }

    func testDedicatedScopesListToolCachesAndAssistantRecordsBeforeTheBroadCacheReview() throws {
        try fixture { home in
            let scopes = SpaceCleaningScanner.recommendedScopes(context: .init(homeDirectory: home))
            let paths = scopes.map { String($0.directory.path.dropFirst(home.path.count + 1)) }
            let broad = try XCTUnwrap(paths.firstIndex(of: "Library/Caches"))
            for path in ["Library/Caches/JetBrains", "Library/Caches/pypoetry"] {
                XCTAssertLessThan(try XCTUnwrap(paths.firstIndex(of: path)), broad, path)
            }
            for path in [".cache/uv", ".gradle/caches", ".cargo/registry", ".yarn/berry/cache"] {
                XCTAssertEqual(scopes.first { $0.directory.path.hasSuffix("/" + path) }?.kind, .packageCache, path)
            }
            for path in [".codex/sessions", ".codex/visualizations", ".claude/projects"] {
                XCTAssertEqual(scopes.first { $0.directory.path.hasSuffix("/" + path) }?.kind, .assistantData, path)
            }
            XCTAssertFalse(paths.contains(".codex"), "the assistant's settings and credentials are never a scope")
            XCTAssertFalse(paths.contains(".cache"), "unknown tools in ~/.cache are not offered wholesale")
        }
    }

    func testToolCacheItemsNameTheirToolAndKeepMarkersProtected() throws {
        try fixture { home in
            try file(home, ".cache/uv/archive-v0/abc/package/module.py", bytes: 64)
            try file(home, ".cache/uv/archive-v0/abc/.lock", bytes: 0)
            try file(home, ".cache/uv/wheels-v6/index/demo.whl", bytes: 32)
            try file(home, ".cache/uv/CACHEDIR.TAG", bytes: 43)
            try file(home, ".cache/uv/.lock", bytes: 0)
            let report = scan(home, ".cache/uv")
            let archive = try XCTUnwrap(report.candidates.first { $0.url.lastPathComponent == "archive-v0" })
            XCTAssertEqual(archive.title, "uv 缓存 · archive-v0")
            XCTAssertEqual(archive.kind, .packageCache)
            XCTAssertTrue(archive.isRecommendedForSelection, "lock files inside an idle tool cache belong to the cache")
            XCTAssertTrue(archive.impact.contains("重新下载"))
            for marker in ["CACHEDIR.TAG", ".lock"] {
                let item = try XCTUnwrap(report.candidates.first { $0.url.lastPathComponent == marker }, marker)
                XCTAssertFalse(item.canProcess, marker)
            }
        }
    }

    func testRunningOwnerKeepsItsCacheAndUnrelatedToolsDoNot() throws {
        try fixture { home in
            try file(home, ".cache/uv/archive-v0/abc/module.py")
            let busy = scan(home, ".cache/uv", context: .init(homeDirectory: home, activeToolNames: [SpaceCleaningToolActivity.uv]))
            XCTAssertEqual(busy.candidates.first?.kind, .runningApplication)
            XCTAssertFalse(busy.candidates.first?.canProcess ?? true)
            let other = scan(home, ".cache/uv", context: .init(homeDirectory: home, activeToolNames: [SpaceCleaningToolActivity.gradle]))
            XCTAssertTrue(other.candidates.first?.isRecommendedForSelection ?? false)
        }
    }

    func testYarnCacheWithUnpackedNodeModulesIsOneRecommendedItemButOtherCachesStayProtected() throws {
        try fixture { home in
            try file(home, "Library/Caches/Yarn/v6/npm-left-pad-1.3.0-abc-integrity/node_modules/left-pad/index.js", bytes: 50)
            try file(home, "Library/Caches/Yarn/v6/.tmp/lock", bytes: 0)
            try file(home, "Library/Caches/com.example.tool/node_modules/dep/index.js", bytes: 30)
            let report = scan(home, "Library/Caches", kind: .browserCache)
            let yarn = try XCTUnwrap(report.candidates.first { $0.url.lastPathComponent == "Yarn" })
            XCTAssertEqual(yarn.title, "Yarn 下载缓存")
            XCTAssertTrue(yarn.isRecommendedForSelection)
            let other = try XCTUnwrap(report.candidates.first { $0.url.lastPathComponent == "com.example.tool" })
            XCTAssertFalse(other.canProcess, "only fixed package caches may contain node_modules")
            XCTAssertTrue(SpaceCleaningKnownLocations.allowsProjectNames(yarn.url))
            XCTAssertFalse(SpaceCleaningKnownLocations.allowsProjectNames(other.url))
        }
    }

    func testUnpackedPackageCacheMovesThroughTheTransactionWithItsOwnProjectCheckIntact() throws {
        try fixture { home in
            try file(home, "Library/Caches/Yarn/v6/npm-left-pad-1.3.0-abc-integrity/node_modules/left-pad/index.js", bytes: 50)
            let trash = home.appendingPathComponent("Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let context = SpaceCleaningContext(homeDirectory: home)
            let report = scan(home, "Library/Caches", kind: .browserCache, context: context)
            let yarn = try XCTUnwrap(report.candidates.first { $0.url.lastPathComponent == "Yarn" })
            let record = SpaceCleaningTransaction.execute(candidate: yarn, operationID: UUID(), method: .trash, mover: KnownLocationMover(directory: trash),
                validatePolicy: { item in
                    SpaceCleaningScanner.revalidate(candidate: item, context: context) == .unchanged ? nil : "changed"
                }, persist: { _ in })
            XCTAssertEqual(record.state, .trashed, record.explanation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: yarn.url.path))
        }
    }

    func testOversizedToolCacheNamesItsOwnCleanupCommand() throws {
        try fixture { home in
            for index in 0..<12 { try file(home, "Library/Caches/Yarn/v6/npm-pkg-\(index)-integrity/node_modules/pkg/index.js") }
            let report = scan(home, "Library/Caches", kind: .browserCache, options: .init(maximumEntries: 20))
            let yarn = try XCTUnwrap(report.candidates.first { $0.url.lastPathComponent == "Yarn" })
            XCTAssertFalse(yarn.canProcess)
            XCTAssertEqual(yarn.title, "Yarn 下载缓存", "a protected cache keeps its readable name")
            XCTAssertTrue(yarn.reason.contains("yarn cache clean"), yarn.reason)
        }
    }

    func testJetBrainsOldVersionsArePreselectedAndTheCurrentVersionIsManual() throws {
        try fixture { home in
            try file(home, "Library/Caches/JetBrains/WebStorm2024.2/caches/index.dat")
            try file(home, "Library/Caches/JetBrains/WebStorm2025.1/caches/index.db")
            try file(home, "Library/Caches/JetBrains/PyCharm2025.1/caches/index.dat")
            try file(home, "Library/Caches/JetBrains/Toolbox/download/archive")
            let report = scan(home, "Library/Caches/JetBrains")
            func item(_ name: String) throws -> SpaceCleaningCandidate {
                try XCTUnwrap(report.candidates.first { $0.url.lastPathComponent == name }, name)
            }
            XCTAssertTrue(try item("WebStorm2024.2").isRecommendedForSelection)
            XCTAssertEqual(try item("WebStorm2024.2").title, "JetBrains 缓存 · WebStorm2024.2")
            let current = try item("WebStorm2025.1")
            XCTAssertTrue(current.canProcess && current.isCleanupSuggestion && !current.isRecommendedForSelection)
            XCTAssertFalse(try item("PyCharm2025.1").isRecommendedForSelection, "each product compares only with itself")
            let toolbox = try item("Toolbox")
            XCTAssertFalse(toolbox.isCleanupSuggestion)
            XCTAssertEqual(toolbox.group, .review)

            let ide = try application(home, "WebStorm.app", identifier: "com.jetbrains.WebStorm")
            let busy = scan(home, "Library/Caches/JetBrains", context: .init(homeDirectory: home, runningApplicationURLs: [ide]))
            XCTAssertEqual(busy.candidates.first { $0.url.lastPathComponent == "WebStorm2024.2" }?.kind, .runningApplication)
            let toolboxApp = try application(home, "JetBrains Toolbox.app", identifier: "com.jetbrains.toolbox")
            let background = scan(home, "Library/Caches/JetBrains", context: .init(homeDirectory: home, runningApplicationURLs: [toolboxApp]))
            XCTAssertTrue(background.candidates.first { $0.url.lastPathComponent == "WebStorm2024.2" }?.isRecommendedForSelection ?? false)
        }
    }

    func testCodexSessionsAreOfferedByMonthOnlyAfterTheyStopChanging() throws {
        try fixture { home in
            let old = try file(home, ".codex/sessions/2026/09/12/rollout-a.jsonl", bytes: 300)
            let recent = try file(home, ".codex/sessions/2026/10/20/rollout-b.jsonl", bytes: 200)
            let sessions = home.appendingPathComponent(".codex/sessions")
            try age(old, to: now.addingTimeInterval(-40 * 86_400), through: sessions.appendingPathComponent("2026"))
            try age(recent, to: now.addingTimeInterval(-40 * 86_400), through: sessions.appendingPathComponent("2026"))
            // A long-running thread started in October is still being written.
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3_600)], ofItemAtPath: recent.path)
            // Compressing an old record rewrites its folder; the file keeps its own time.
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3_600)], ofItemAtPath: old.deletingLastPathComponent().path)
            let report = scan(home, ".codex/sessions", kind: .assistantData)
            XCTAssertEqual(report.candidates.count, 2, "one item per month, not per file or year")
            let september = try XCTUnwrap(report.candidates.first { $0.url.lastPathComponent == "09" })
            XCTAssertEqual(september.title, "Codex 会话记录 · 2026 年 9 月")
            XCTAssertEqual(september.group, .review)
            XCTAssertTrue(september.isCleanupSuggestion)
            XCTAssertFalse(september.isRecommendedForSelection, "assistant records are never preselected")
            XCTAssertTrue(september.impact.contains("无法在 Codex 中继续"))
            let october = try XCTUnwrap(report.candidates.first { $0.url.lastPathComponent == "10" })
            XCTAssertFalse(october.canProcess, "a month with a file updated in the last three days stays protected")
            XCTAssertEqual(october.title, "Codex 会话记录 · 2026 年 10 月")
        }
    }

    func testClaudeProjectRecordsAreNamedByProjectFolder() throws {
        try fixture { home in
            let slug = home.path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
            let transcript = try file(home, ".claude/projects/\(slug)-Developer-App/session.jsonl", bytes: 120)
            try age(transcript, to: now.addingTimeInterval(-10 * 86_400), through: home.appendingPathComponent(".claude/projects"))
            let report = scan(home, ".claude/projects", kind: .assistantData)
            let project = try XCTUnwrap(report.candidates.first)
            XCTAssertEqual(project.title, "Claude Code 会话记录 · Developer-App")
            XCTAssertTrue(project.isCleanupSuggestion)
            XCTAssertEqual(SpaceCleaningKnownLocations.claudeProjectName(slug, homePath: home.path), "主目录")
        }
    }

    func testOldJetBrainsVersionWithBundledTypingsIsStillPreselected() throws {
        try fixture { home in
            try file(home, "Library/Caches/JetBrains/WebStorm2025.1/javascript/typings/lodash/4.17.21/node_modules/@types/lodash/index.d.ts")
            try file(home, "Library/Caches/JetBrains/WebStorm2026.1/caches/content.dat")
            let report = scan(home, "Library/Caches/JetBrains")
            let old = try XCTUnwrap(report.candidates.first { $0.url.lastPathComponent == "WebStorm2025.1" })
            XCTAssertTrue(old.isRecommendedForSelection, old.reason)
            XCTAssertTrue(SpaceCleaningKnownLocations.allowsProjectNames(old.url))
        }
    }

    func testDownloadedBrowsersAllowOnlyLinksThatStayInsideTheItem() throws {
        try fixture { home in
            let framework = "Library/Caches/ms-playwright/chromium-1100/chrome-mac/Chromium.app/Contents/Frameworks/Chromium Framework.framework"
            try file(home, framework + "/Versions/A/Chromium Framework", bytes: 64)
            try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(framework + "/Versions/Current").path, withDestinationPath: "A")
            let inside = scan(home, "Library/Caches", kind: .browserCache)
            let browsers = try XCTUnwrap(inside.candidates.first { $0.url.lastPathComponent == "ms-playwright" })
            XCTAssertTrue(browsers.canProcess && browsers.isCleanupSuggestion && !browsers.isRecommendedForSelection, browsers.reason)
            XCTAssertEqual(browsers.title, "Playwright 浏览器")
            try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(framework + "/Outside").path, withDestinationPath: "/usr/lib")
            let escaping = scan(home, "Library/Caches", kind: .browserCache)
            XCTAssertFalse(try XCTUnwrap(escaping.candidates.first { $0.url.lastPathComponent == "ms-playwright" }).canProcess)
        }
    }

    func testCodexPrototypesWithDependenciesAreOfferedAndOtherPersonalFoldersAreNot() throws {
        try fixture { home in
            let checks = try file(home, ".codex/visualizations/2026/09/18/thread/review/checks/node_modules/dep/index.js")
            try age(checks, to: now.addingTimeInterval(-20 * 86_400), through: home.appendingPathComponent(".codex/visualizations"))
            let report = scan(home, ".codex/visualizations", kind: .assistantData)
            let month = try XCTUnwrap(report.candidates.first)
            XCTAssertEqual(month.title, "Codex 可视化与截图 · 2026 年 9 月")
            XCTAssertTrue(month.isCleanupSuggestion, month.reason)
            XCTAssertTrue(SpaceCleaningKnownLocations.allowsProjectNames(month.url))
            XCTAssertFalse(SpaceCleaningKnownLocations.allowsProjectNames(home.appendingPathComponent("Developer/visualizations/2026/09")))
            XCTAssertFalse(SpaceCleaningKnownLocations.allowsProjectNames(home.appendingPathComponent(".codex/sessions/2026/09")),
                           "session records never contain project folders")
        }
    }

    func testReviewSuggestionFieldIsOptionalForOlderAndNewerReceipts() throws {
        try fixture { home in
            try file(home, ".cache/uv/archive-v0/abc/module.py")
            let candidate = try XCTUnwrap(scan(home, ".cache/uv").candidates.first)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any])
            json.removeValue(forKey: "isReviewSuggestion")
            let legacy = try JSONDecoder().decode(SpaceCleaningCandidate.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertNil(legacy.isReviewSuggestion)
            XCTAssertEqual(legacy.url, candidate.url)
        }
    }

    func testJetBrainsVersionAndMonthParsingRejectLookalikes() {
        XCTAssertEqual(SpaceCleaningKnownLocations.jetBrainsVersion("IntelliJIdea2025.2")?.product, "IntelliJIdea")
        XCTAssertEqual(SpaceCleaningKnownLocations.jetBrainsVersion("WebStorm2026.1")?.version, [2026, 1])
        XCTAssertNil(SpaceCleaningKnownLocations.jetBrainsVersion("Toolbox"))
        XCTAssertNil(SpaceCleaningKnownLocations.jetBrainsVersion("acp-agents"))
        XCTAssertNil(SpaceCleaningKnownLocations.jetBrainsVersion("2025.1"))
        XCTAssertNil(SpaceCleaningKnownLocations.jetBrainsVersion("Daemon25.1"))
        XCTAssertEqual(SpaceCleaningKnownLocations.monthTitle(year: "2026", month: "09"), "2026 年 9 月")
        XCTAssertNil(SpaceCleaningKnownLocations.monthTitle(year: "2026", month: "13"))
        XCTAssertNil(SpaceCleaningKnownLocations.monthTitle(year: "26", month: "01"))
    }
}
