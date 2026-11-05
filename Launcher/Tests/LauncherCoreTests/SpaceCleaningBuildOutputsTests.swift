import XCTest
@testable import LauncherCore

private struct BuildOutputMover: SpaceCleaningFileOperating {
    var directory: URL
    func moveToTrash(_ source: URL) throws -> URL {
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }
}

final class SpaceCleaningBuildOutputsTests: XCTestCase {
    private let old = Date().addingTimeInterval(-30 * 86_400)

    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceCleaningBuild-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonical = try XCTUnwrap(SpaceCleaningScanner.canonicalURL(root))
        defer { try? FileManager.default.removeItem(at: canonical) }
        try body(canonical)
    }
    @discardableResult private func file(_ root: URL, _ relative: String, bytes: Int = 20) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }
    /// Ages every regular file below `url`; folders keep their own times.
    private func ageFiles(_ url: URL, to date: Date) throws {
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [])!
        for case let item as URL in items {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.path)
            }
        }
    }
    private func scan(_ home: URL, _ relative: String, context: SpaceCleaningContext? = nil, options: SpaceCleaningOptions = .init()) -> SpaceCleaningReport {
        SpaceCleaningScanner.scan(scopes: [.init(directory: home.appendingPathComponent(relative))],
                                  context: context ?? .init(homeDirectory: home), options: options)
    }
    private func item(_ report: SpaceCleaningReport, _ name: String) throws -> SpaceCleaningCandidate {
        try XCTUnwrap(report.candidates.first { $0.url.lastPathComponent == name }, name)
    }
    /// A SwiftPM `.build` with a dependency checkout, links and a hard link.
    private func swiftPackage(_ project: URL) throws -> URL {
        try file(project, "Package.swift", bytes: 40)
        let build = project.appendingPathComponent(".build")
        try file(build, "arm64-apple-macosx/debug/App", bytes: 400)
        try file(build, "checkouts/swift-collections/.git/HEAD", bytes: 30)
        try file(build, "checkouts/swift-collections/Sources/Deque.swift", bytes: 60)
        try file(build, "workspace-state.json", bytes: 50)
        try file(build, ".lock", bytes: 0)
        try FileManager.default.createSymbolicLink(atPath: build.appendingPathComponent("debug").path, withDestinationPath: "arm64-apple-macosx/debug")
        try FileManager.default.createSymbolicLink(atPath: build.appendingPathComponent("arm64-apple-macosx/debug/toolchain").path, withDestinationPath: "/usr/bin")
        try FileManager.default.linkItem(at: build.appendingPathComponent("arm64-apple-macosx/debug/App"),
                                         to: build.appendingPathComponent("arm64-apple-macosx/debug/App-copy"))
        try ageFiles(build, to: old)
        return build
    }

    func testPureSwiftPackageBuildIsOneManualWholeFolderItem() throws {
        try fixture { home in
            let project = home.appendingPathComponent("Developer/App")
            _ = try swiftPackage(project)
            let report = scan(home, "Developer")
            let build = try item(report, ".build")
            XCTAssertEqual(build.title, "Swift 构建产物 · App")
            XCTAssertTrue(build.canProcess && build.isCleanupSuggestion && !build.isRecommendedForSelection, build.reason)
            XCTAssertEqual(build.isBulkVerified, true)
            XCTAssertTrue(build.reason.contains("30 天前") || build.reason.contains("29 天前"), build.reason)
            XCTAssertEqual(build.allocatedBytes, try XCTUnwrap(scan(home, "Developer").candidates.first { $0.url == build.url }).allocatedBytes)
            XCTAssertFalse(report.candidates.contains { $0.url.path.hasPrefix(build.url.path + "/") }, "nothing inside the item is listed separately")
        }
    }

    func testBuildFoldersAreRecognizedByContentNotByName() throws {
        try fixture { home in
            // A `.build` used for probes and assets is not a SwiftPM build folder.
            let mixed = home.appendingPathComponent("Developer/Tool")
            try file(mixed, "Package.swift")
            try file(mixed, ".build/Probe.swift")
            try file(mixed, ".build/DerivedData/info.plist")
            try file(mixed, ".build/DerivedData/Build/Products/Debug/Tool", bytes: 90)
            try file(mixed, ".build/DerivedData/Index.noindex/DataStore/v5/units/a", bytes: 10)
            // A `build` folder that holds marketing assets beside real build output.
            let app = home.appendingPathComponent("Developer/Clip")
            try file(app, "Clip.xcodeproj/project.pbxproj")
            try file(app, "build/promo/trailer.mov", bytes: 300)
            try file(app, "build/ModuleCache/ABC/Foundation.pcm", bytes: 80)
            try file(app, "build/T1-unit.xcresult/Info.plist")
            try file(app, "build/T1-unit.xcresult/Data/data.0~abc", bytes: 120)
            try ageFiles(home.appendingPathComponent("Developer"), to: old)
            let report = scan(home, "Developer")
            XCTAssertFalse(report.candidates.contains { $0.url.path == mixed.appendingPathComponent(".build").path })
            XCTAssertEqual(try item(report, "DerivedData").title, "Xcode 构建产物 · Tool/.build/DerivedData")
            XCTAssertTrue(try item(report, "DerivedData").isCleanupSuggestion)
            XCTAssertEqual(try item(report, "ModuleCache").title, "编译模块缓存 · Clip/build/ModuleCache")
            let result = try item(report, "T1-unit.xcresult")
            XCTAssertEqual(result.title, "Xcode 测试结果 · Clip/build/T1-unit")
            XCTAssertTrue(result.canProcess && result.isCleanupSuggestion && !result.isRecommendedForSelection)
            XCTAssertFalse(report.candidates.contains { $0.url.lastPathComponent == "build" }, "a mixed build folder is never one item")
            XCTAssertFalse(report.candidates.contains { ["trailer.mov", "Probe.swift"].contains($0.url.lastPathComponent) },
                           "cleanup mode lists recognized items in project trees, not every file")
            var large = SpaceCleaningOptions(); large.mode = .largeFiles; large.minimumFileBytes = 200
            XCTAssertNotNil(scan(home, "Developer", options: large).candidates.first { $0.url.lastPathComponent == "trailer.mov" },
                            "large-file mode still lists big files in projects")
        }
    }

    func testRecentReleaseRunningAndUnanchoredBuildOutputsStayProtected() throws {
        try fixture { home in
            let build = try swiftPackage(home.appendingPathComponent("Developer/App"))
            try file(build, "arm64-apple-macosx/debug/fresh.o")
            XCTAssertFalse(try item(scan(home, "Developer"), ".build").canProcess, "a build in the last seven days keeps the folder")
            try ageFiles(build, to: old)
            XCTAssertTrue(try item(scan(home, "Developer"), ".build").canProcess)

            let busy = SpaceCleaningContext(homeDirectory: home, activeToolNames: ["swift-build"])
            XCTAssertEqual(try item(scan(home, "Developer", context: busy), ".build").kind, .runningApplication)
            let running = SpaceCleaningContext(homeDirectory: home, runningExecutablePaths: [build.appendingPathComponent("arm64-apple-macosx/debug/App").path])
            XCTAssertFalse(try item(scan(home, "Developer", context: running), ".build").canProcess, "a running program inside keeps the folder")

            let derived = home.appendingPathComponent("Developer/Site/DerivedData")
            try file(derived, "info.plist")
            try file(derived, "Build/Products/Release/Site.dmg", bytes: 70)
            try ageFiles(derived, to: old)
            let release = try item(scan(home, "Developer"), "DerivedData")
            XCTAssertEqual(release.kind, .releaseMaterial)
            XCTAssertFalse(release.canProcess)

            try file(home, "Library/Projects/Old/DerivedData/info.plist")
            try file(home, "Library/Projects/Old/DerivedData/Build/x")
            XCTAssertNil(scan(home, "Library/Projects").candidates.first { $0.isBulkVerified == true }, "~/Library keeps its own rules")
        }
    }

    func testWholeFolderTrashRestoreAndPermanentDeletion() throws {
        try fixture { home in
            let project = home.appendingPathComponent("Developer/App")
            let build = try swiftPackage(project)
            let trash = home.appendingPathComponent("Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let context = SpaceCleaningContext(homeDirectory: home)
            let candidate = try item(scan(home, "Developer", context: context), ".build")
            let policy: (SpaceCleaningCandidate) -> String? = { SpaceCleaningScanner.revalidate(candidate: $0, context: context) == .unchanged ? nil : "changed" }
            let trashed = SpaceCleaningTransaction.execute(candidate: candidate, operationID: UUID(), method: .trash,
                mover: BuildOutputMover(directory: trash), validatePolicy: policy, persist: { _ in })
            XCTAssertEqual(trashed.state, .trashed, trashed.explanation)
            XCTAssertEqual(trashed.proof?.metadataOnly, true)
            XCTAssertTrue(trashed.explanation.contains("整个文件夹"))
            let restored = SpaceCleaningTransaction.restore(record: trashed, conflict: .skip, persist: { _ in })
            XCTAssertEqual(restored.state, .restored, restored.explanation)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: build.appendingPathComponent("debug").path), "arm64-apple-macosx/debug")

            let again = try item(scan(home, "Developer", context: context), ".build")
            let deleted = SpaceCleaningTransaction.execute(candidate: again, operationID: UUID(), method: .permanent, permanentConfirmed: true,
                mover: BuildOutputMover(directory: trash), validatePolicy: policy, persist: { _ in })
            XCTAssertEqual(deleted.state, .deleted, deleted.explanation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: build.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: "/usr/bin"), "links inside are removed, never followed")
            XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("Package.swift").path))
        }
    }

    func testWholeFolderTransactionRefusesNewBuildsAndUnrecognizedFolders() throws {
        try fixture { home in
            let build = try swiftPackage(home.appendingPathComponent("Developer/App"))
            let context = SpaceCleaningContext(homeDirectory: home)
            let candidate = try item(scan(home, "Developer", context: context), ".build")
            // A nested file changes without touching the folder's own identity.
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: build.appendingPathComponent("checkouts/swift-collections/Sources/Deque.swift").path)
            let trash = home.appendingPathComponent("Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let refused = SpaceCleaningTransaction.execute(candidate: candidate, operationID: UUID(), method: .trash, mover: BuildOutputMover(directory: trash),
                validatePolicy: { SpaceCleaningScanner.revalidate(candidate: $0, context: context) == .unchanged ? nil : "changed" }, persist: { _ in })
            XCTAssertEqual(refused.state, .skipped)
            XCTAssertTrue(refused.explanation.contains("7 天"), refused.explanation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: build.path))

            // Only recognized locations may skip the content proof.
            let folder = home.appendingPathComponent("Documents/Notes")
            try file(folder, "notes.txt")
            var forged = candidate
            forged.url = folder; forged.rootURL = home.appendingPathComponent("Documents")
            forged.identity = try XCTUnwrap(SpaceCleaningScanner.captureIdentity(at: folder))
            let blocked = SpaceCleaningTransaction.execute(candidate: forged, operationID: UUID(), method: .permanent, permanentConfirmed: true,
                mover: BuildOutputMover(directory: trash), validatePolicy: { _ in nil }, persist: { _ in })
            XCTAssertEqual(blocked.state, .skipped)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path))
        }
    }

    func testMetadataRemovalStopsAtObjectsThatWereNotVerified() throws {
        try fixture { home in
            let tree = home.appendingPathComponent("Isolation/item")
            try file(tree, "a/b.txt")
            let identity = try XCTUnwrap(SpaceCleaningScanner.captureIdentity(at: tree))
            let snapshot = try SpaceCleaningFilesystem.metadataSnapshot(tree, expected: identity, allowRename: false, isCancelled: { false })
            let newcomer = try file(tree, "a/new.txt")
            XCTAssertThrowsError(try SpaceCleaningFilesystem.removeVerifiedObjects(tree, objects: try XCTUnwrap(snapshot.verifiedObjects),
                                                                                 device: identity.device, isCancelled: { false }))
            XCTAssertTrue(FileManager.default.fileExists(atPath: newcomer.path), "content added after verification is never deleted")
        }
    }

    func testMetadataProofsAreDistinctFromContentProofs() throws {
        let identity = SpaceCleaningFileIdentity(device: 1, inode: 2, sizeBytes: 0, allocatedBytes: 0, modifiedSeconds: 0, modifiedNanoseconds: 0,
                                                 changedSeconds: 0, changedNanoseconds: 0, linkCount: 1, mode: UInt32(S_IFDIR))
        let hash = String(repeating: "a", count: 64)
        let large = SpaceCleaningTreeProof(sha256: hash, entryCount: 250_000, logicalBytes: 1, rootIdentity: identity, metadataOnly: true)
        XCTAssertTrue(large.isValid)
        XCTAssertFalse(SpaceCleaningTreeProof(sha256: hash, entryCount: 250_000, logicalBytes: 1, rootIdentity: identity).isValid)
        let content = SpaceCleaningTreeProof(sha256: hash, entryCount: 10, logicalBytes: 1, rootIdentity: identity)
        var metadata = content; metadata.metadataOnly = true
        XCTAssertFalse(content.matches(metadata), "a metadata proof never stands in for a content proof")
        let legacy = try JSONDecoder().decode(SpaceCleaningTreeProof.self, from: JSONEncoder().encode(content))
        XCTAssertNil(legacy.metadataOnly)
    }

    /// Released builds validate `entryCount` against the content-proof bound and
    /// treat a failing record as a corrupt history. A large whole-folder record
    /// must stay within that bound so those builds can still open the history.
    func testLargeWholeFolderProofStaysReadableByReleasedBuilds() throws {
        let identity = SpaceCleaningFileIdentity(device: 1, inode: 2, sizeBytes: 0, allocatedBytes: 0, modifiedSeconds: 0, modifiedNanoseconds: 0,
                                                 changedSeconds: 0, changedNanoseconds: 0, linkCount: 1, mode: UInt32(S_IFDIR))
        let hash = String(repeating: "b", count: 64)
        let large = SpaceCleaningTreeProof(sha256: hash, entryCount: 300_000, logicalBytes: 9, rootIdentity: identity, metadataOnly: true)
        XCTAssertEqual(large.entryCount, SpaceCleaningTreeProof.maximumContentEntries)
        XCTAssertEqual(large.metadataEntryCount, 300_000)
        XCTAssertEqual(large.coveredEntries, 300_000)
        XCTAssertTrue(large.isValid)

        // The fields a released build reads: sha256, entryCount, logicalBytes, rootIdentity.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(large)) as? [String: Any])
        let releasedCount = try XCTUnwrap(object["entryCount"] as? Int)
        XCTAssertTrue((1...SpaceCleaningTreeProof.maximumContentEntries).contains(releasedCount))

        let decoded = try JSONDecoder().decode(SpaceCleaningTreeProof.self, from: JSONEncoder().encode(large))
        XCTAssertEqual(decoded, large)
        XCTAssertTrue(decoded.matches(large))
        var smaller = large; smaller.metadataEntryCount = 299_999
        XCTAssertFalse(smaller.matches(large), "the full count stays part of the proof")
        var tampered = large; tampered.entryCount = 5
        XCTAssertFalse(tampered.isValid, "the compatibility count must follow the full count")

        // Whole-folder records written before the full count was stored separately stay readable.
        var legacy = large; legacy.metadataEntryCount = nil; legacy.entryCount = 300_000
        XCTAssertTrue(legacy.isValid)
        XCTAssertEqual(legacy.coveredEntries, 300_000)
        XCTAssertTrue(legacy.matches(large))
        var content = SpaceCleaningTreeProof(sha256: hash, entryCount: 10, logicalBytes: 9, rootIdentity: identity)
        content.metadataEntryCount = 10
        XCTAssertFalse(content.isValid, "content proofs never carry a whole-folder count")
    }
}
