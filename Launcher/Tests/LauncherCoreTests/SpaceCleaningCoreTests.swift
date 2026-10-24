import XCTest
import Darwin
@testable import LauncherCore

final class SpaceCleaningCoreTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceCleaningTests-" + UUID().uuidString)
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
    private func scan(_ root: URL, at relative: String = "", context: SpaceCleaningContext? = nil,
                      options: SpaceCleaningOptions = .init()) -> SpaceCleaningReport {
        SpaceCleaningScanner.scan(scopes: [.init(directory: root.appendingPathComponent(relative))],
                                  context: context ?? .init(homeDirectory: root), options: options)
    }

    func testRecommendedScopesAreKnownUserLocationsAndKeepInjectedHomeIsolated() throws {
        try fixture { home in
            let scopes = SpaceCleaningScanner.recommendedScopes(context: .init(homeDirectory: home))
            XCTAssertTrue(scopes.allSatisfy { $0.directory.path.hasPrefix(home.path + "/") })
            XCTAssertFalse(scopes.contains { $0.directory == home })
            XCTAssertTrue(scopes.contains { $0.directory == home.appendingPathComponent("Downloads") })
            XCTAssertTrue(scopes.contains { $0.kind == .releaseArchiveDiscovery })
            XCTAssertTrue(scopes.contains { $0.directory.lastPathComponent == "DerivedData" })
            XCTAssertTrue(scopes.contains { $0.directory.lastPathComponent == "Homebrew" })
            XCTAssertFalse(scopes.contains { $0.kind == .installedApplications })
        }
    }

    func testKnownLocationsHaveRealSizesAndOrdinaryCacheNamedDirectoryIsNotRecommended() throws {
        try fixture { home in
            try file(home, "Library/Caches/com.apple.Safari/item", bytes: 123)
            try file(home, "ordinary-cache/old.cache", bytes: 45)
            let report = SpaceCleaningScanner.scan(scopes: [
                .init(directory: home.appendingPathComponent("Library/Caches/com.apple.Safari"), kind: .browserCache),
                .init(directory: home.appendingPathComponent("ordinary-cache"), kind: .browserCache)
            ], context: .init(homeDirectory: home))
            XCTAssertTrue(report.complete)
            XCTAssertEqual(report.logicalBytes, 168)
            XCTAssertEqual(report.candidates.first?.group, .rebuildable)
            XCTAssertEqual(report.candidates.last?.group, .review)
            XCTAssertTrue(report.candidates.allSatisfy { $0.canProcess })
        }
    }

    func testDefaultDiscoveryFindsReleaseArchivesWithoutWalkingOtherApplicationSupportData() throws {
        try fixture { home in
            try file(home, "Library/Application Support/Example/ReleaseArchives/1.0/Example.dmg", bytes: 231)
            try file(home, "Library/Application Support/Other/private.db", bytes: 999)
            try file(home, "Downloads/package.dmg", bytes: 111)
            let context = SpaceCleaningContext(homeDirectory: home)
            let report = SpaceCleaningScanner.scan(scopes: SpaceCleaningScanner.recommendedScopes(context: context), context: context)
            XCTAssertEqual(report.logicalBytes, 342)
            XCTAssertEqual(report.candidates.filter { $0.group == .protected }.count, 1)
            XCTAssertEqual(report.candidates.first { $0.group == .protected }?.title, "ReleaseArchives")
            XCTAssertFalse(report.candidates.contains { $0.url.lastPathComponent == "private.db" })
            XCTAssertTrue(report.issues.contains { $0.kind == .missing })
            XCTAssertTrue(report.complete)
        }
    }

    func testRemainingCacheFoldersRequireReviewAndRunningOwnerIsProtected() throws {
        try fixture { home in
            try file(home, "Library/Caches/com.example.Editor/content", bytes: 80)
            try file(home, "Library/Caches/com.apple.Safari/content", bytes: 40)
            let context = SpaceCleaningContext(homeDirectory: home, runningApplicationURLs: [home.appendingPathComponent("Safari.app")])
            let report = scan(home, at: "Library/Caches", context: context)
            XCTAssertEqual(report.candidates.first { $0.url.path.contains("com.example") }?.group, .review)
            XCTAssertEqual(report.candidates.first { $0.url.path.contains("com.apple.Safari") }?.kind, .runningApplication)
            XCTAssertEqual(report.logicalBytes, 120)
        }
    }

    func testRunningGenericApplicationProtectsItsBundleIdentifierCache() throws {
        try fixture { home in
            let app = home.appendingPathComponent("Apps/Example.app")
            let info = try file(home, "Apps/Example.app/Contents/Info.plist")
            let plist: [String: String] = ["CFBundleIdentifier": "com.example.Editor", "CFBundlePackageType": "APPL", "CFBundleName": "Example"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
            try file(home, "Library/Caches/com.example.Editor/content", bytes: 80)
            try file(home, "Library/Caches/com.example.Other/content", bytes: 40)
            let idle = scan(home, at: "Library/Caches")
            let candidate = try XCTUnwrap(idle.candidates.first { $0.title == "com.example.Editor" })
            XCTAssertTrue(candidate.canProcess)
            let busyContext = SpaceCleaningContext(homeDirectory: home, runningApplicationURLs: [app])
            let busy = scan(home, at: "Library/Caches", context: busyContext)
            XCTAssertEqual(busy.candidates.first { $0.title == "com.example.Editor" }?.kind, .runningApplication)
            XCTAssertFalse(busy.candidates.first { $0.title == "com.example.Editor" }?.canProcess ?? true)
            XCTAssertEqual(busy.candidates.first { $0.title == "com.example.Other" }?.group, .review)
            XCTAssertEqual(SpaceCleaningScanner.revalidate(candidate: candidate, context: busyContext), .protected)
            XCTAssertEqual(SpaceCleaningScanner.validatePolicy(candidate: candidate, context: busyContext), .protected)
        }
    }

    func testCloudPlaceholderFlagUsesOnlyDatalessMetadataBit() throws {
        XCTAssertTrue(SpaceCleaningScanner.isCloudPlaceholder(fileFlags: UInt32(SF_DATALESS)))
        XCTAssertTrue(SpaceCleaningScanner.isCloudPlaceholder(fileFlags: UInt32(SF_DATALESS | UF_HIDDEN)))
        XCTAssertFalse(SpaceCleaningScanner.isCloudPlaceholder(fileFlags: UInt32(UF_HIDDEN)))
        XCTAssertFalse(SpaceCleaningScanner.isCloudPlaceholder(fileFlags: 0))
        try fixture { home in
            let local = try file(home, "local.txt", bytes: 39)
            let before = try XCTUnwrap(SpaceCleaningScanner.captureIdentity(at: local))
            XCTAssertFalse(SpaceCleaningScanner.isCloudPlaceholder(at: local))
            XCTAssertEqual(SpaceCleaningScanner.captureIdentity(at: local), before)
        }
    }

    func testCloudMetadataSkipsPlaceholderFilesAndDirectoriesWithoutEnumeratingThem() throws {
        try fixture { home in
            let local = try file(home, "Downloads/local.txt", bytes: 10)
            let cloudFile = try file(home, "Downloads/cloud.txt", bytes: 500)
            try file(home, "Downloads/CloudFolder/hidden.txt", bytes: 900)
            let cloudDirectory = home.appendingPathComponent("Downloads/CloudFolder")
            let flagged = Set([cloudFile.path, cloudDirectory.path])
            var enumerated: [URL] = []
            // These are ordinary temporary files with injected metadata, not real cloud items.
            let metadata = SpaceCleaningMetadataReader(flags: { flagged.contains($0.path) ? UInt32(SF_DATALESS) : 0 },
                                                       willEnumerate: { enumerated.append($0) })
            let report = SpaceCleaningScanner.scan(scopes: [.init(directory: home.appendingPathComponent("Downloads"))],
                                                    context: .init(homeDirectory: home), metadata: metadata)
            XCTAssertEqual(report.candidates.count, 3)
            XCTAssertEqual(report.logicalBytes, 10)
            XCTAssertTrue(report.candidates.filter { flagged.contains($0.url.path) }.allSatisfy {
                $0.kind == .cloudPlaceholder && $0.group == .protected && !$0.canProcess && !$0.canConfirmTestPurpose && !$0.sizeIsComplete
            })
            XCTAssertTrue(report.candidates.first { $0.url == local }?.canProcess ?? false)
            XCTAssertFalse(enumerated.contains(cloudDirectory))
            XCTAssertFalse(report.candidates.contains { $0.title == "hidden.txt" })
            XCTAssertTrue(report.issues.contains { $0.kind == .cloudPlaceholder })
            XCTAssertFalse(report.coverageComplete)
            XCTAssertEqual(SpaceCleaningScanner.captureIdentity(at: cloudFile)?.sizeBytes, 500)
        }
    }

    func testCloudMetadataInsidePackageProtectsWholePackageAndBlocksTestDeclaration() throws {
        try fixture { home in
            try file(home, "Builds/Test.app/Contents/local", bytes: 10)
            try file(home, "Builds/Test.app/Contents/CloudResources/hidden", bytes: 900)
            let root = home.appendingPathComponent("Builds")
            let cloud = root.appendingPathComponent("Test.app/Contents/CloudResources")
            let original = try XCTUnwrap(scan(home, at: "Builds").candidates.first)
            var enumerated: [URL] = []
            let metadata = SpaceCleaningMetadataReader(flags: { $0 == cloud ? UInt32(SF_DATALESS) : 0 },
                                                       willEnumerate: { enumerated.append($0) })
            let report = SpaceCleaningScanner.scan(scopes: [.init(directory: root)],
                context: .init(homeDirectory: home, testDeclarations: [.init(candidate: original)]), metadata: metadata)
            let candidate = try XCTUnwrap(report.candidates.first)
            XCTAssertEqual(candidate.kind, .cloudPlaceholder)
            XCTAssertFalse(candidate.canProcess)
            XCTAssertFalse(candidate.canConfirmTestPurpose)
            XCTAssertFalse(candidate.sizeIsComplete)
            XCTAssertEqual(candidate.logicalBytes, 10)
            XCTAssertFalse(enumerated.contains(cloud))
        }
    }

    func testCloudMetadataAtScanRootAvoidsAnyEnumeration() throws {
        try fixture { home in
            try file(home, "CloudRoot/hidden", bytes: 900)
            let root = home.appendingPathComponent("CloudRoot")
            var enumerated: [URL] = []
            let metadata = SpaceCleaningMetadataReader(flags: { $0 == root ? UInt32(SF_DATALESS) : 0 },
                                                       willEnumerate: { enumerated.append($0) })
            let report = SpaceCleaningScanner.scan(scopes: [.init(directory: root)],
                context: .init(homeDirectory: home), metadata: metadata)
            XCTAssertTrue(enumerated.isEmpty)
            XCTAssertEqual(report.candidates.count, 1)
            XCTAssertEqual(report.candidates.first?.kind, .cloudPlaceholder)
            XCTAssertEqual(report.logicalBytes, 0)
            XCTAssertFalse(report.candidates.first?.canProcess ?? true)
        }
    }

    func testDerivedDataRecognizesOnlyDefinedGeneratedSubtrees() throws {
        try fixture { home in
            let relative = "Library/Developer/Xcode/DerivedData"
            try file(home, relative + "/Example/Build/Intermediates.noindex/unit.o", bytes: 10)
            try file(home, relative + "/Example/Build/Products/Debug/Example.app/Contents/MacOS/Example", bytes: 20)
            try file(home, relative + "/Example/source.swift", bytes: 30)
            try file(home, relative + "/ModuleCache.noindex/module.pcm", bytes: 40)
            let report = scan(home, at: relative)
            XCTAssertEqual(report.candidates.filter { $0.kind == .derivedData }.count, 3)
            XCTAssertEqual(report.candidates.first { $0.title == "source.swift" }?.group, .review)
            XCTAssertEqual(report.logicalBytes, 100)
            XCTAssertEqual(report.candidates.first { $0.title == "Products" }?.group, .rebuildable)
            let busy = scan(home, at: relative, context: .init(homeDirectory: home, activeToolNames: ["xcodebuild"]))
            XCTAssertTrue(busy.candidates.allSatisfy { $0.group == .protected })
        }
    }

    func testArchivesAndAppsRequireIdentityBoundTestDeclaration() throws {
        try fixture { home in
            try file(home, "Builds/Test.app/Contents/MacOS/Test", bytes: 10)
            try file(home, "Builds/Test.xcarchive/dSYMs/Test.app.dSYM/Contents/Info.plist", bytes: 20)
            let original = scan(home, at: "Builds")
            XCTAssertEqual(original.candidates.count, 2)
            XCTAssertTrue(original.candidates.allSatisfy { $0.group == .protected && $0.canConfirmTestPurpose })
            let declarations = original.candidates.map(SpaceCleaningTestDeclaration.init(candidate:))
            let context = SpaceCleaningContext(homeDirectory: home, testDeclarations: declarations)
            let declared = scan(home, at: "Builds", context: context)
            XCTAssertEqual(Set(declared.candidates.map(\.kind)), [.testApplication, .testArchive])
            XCTAssertTrue(declared.candidates.allSatisfy { $0.canProcess && !$0.canConfirmTestPurpose })
            XCTAssertEqual(SpaceCleaningScanner.revalidate(candidate: declared.candidates[0], context: context), .unchanged)
            try file(home, "Builds/Test.app/Contents/MacOS/Test", bytes: 11)
            let rescanned = scan(home, at: "Builds", context: context)
            XCTAssertEqual(rescanned.candidates.first { $0.title == "Test.app" }?.group, .protected)
            XCTAssertNotEqual(SpaceCleaningScanner.revalidate(candidate: declared.candidates[0], context: context), .unchanged)
        }
    }

    func testReleaseProtectionOverridesTestDeclarationAndGeneratedCacheRule() throws {
        try fixture { home in
            let app = home.appendingPathComponent("Builds/Test.app")
            try file(home, "Builds/Test.app/Contents/MacOS/Test")
            let candidate = try XCTUnwrap(scan(home, at: "Builds").candidates.first)
            let protected = scan(home, at: "Builds", context: .init(homeDirectory: home, protectedReleaseURLs: [app],
                                                                    testDeclarations: [.init(candidate: candidate)]))
            XCTAssertEqual(protected.candidates.first?.group, .protected)
            XCTAssertFalse(protected.candidates.first?.canConfirmTestPurpose ?? true)
            let cache = "Library/Developer/Xcode/DerivedData/Example/Build/Products"
            let release = try file(home, cache + "/ReleaseArchives/important.dmg")
            let report = scan(home, at: "Library/Developer/Xcode/DerivedData")
            XCTAssertEqual(report.candidates.first?.kind, .releaseMaterial)
            XCTAssertEqual(report.candidates.first?.group, .protected)
            XCTAssertTrue(FileManager.default.fileExists(atPath: release.path))
        }
    }

    func testInstalledApplicationAndReleaseMaterialsAreVisibleAndProtected() throws {
        try fixture { home in
            try file(home, "Applications/Example.app/Contents/MacOS/Example", bytes: 10)
            try file(home, "Downloads/Example.dSYM/Contents/info", bytes: 20)
            try file(home, "Downloads/appcast.xml", bytes: 30)
            let report = scan(home)
            XCTAssertEqual(report.logicalBytes, 60)
            XCTAssertTrue(report.candidates.allSatisfy { $0.group == .protected })
            XCTAssertEqual(report.candidates.first { $0.title == "Example.app" }?.kind, .installedApplication)
        }
    }

    func testOrganizerDistributionRecordsProtectArchivesOutsideReleaseArchives() throws {
        try fixture { home in
            let relative = "Library/Developer/Xcode/Archives/2026-01-01/Example.xcarchive"
            try file(home, relative + "/Products/Applications/Example.app/Contents/MacOS/Example", bytes: 70)
            let original = try XCTUnwrap(scan(home, at: "Library/Developer/Xcode/Archives").candidates.first)
            XCTAssertTrue(original.canConfirmTestPurpose)
            let context = SpaceCleaningContext(homeDirectory: home, testDeclarations: [.init(candidate: original)])
            let declared = try XCTUnwrap(scan(home, at: "Library/Developer/Xcode/Archives", context: context).candidates.first)
            XCTAssertTrue(declared.canProcess)
            try file(home, relative + "/Distributions/record.plist", bytes: 30)
            let protected = try XCTUnwrap(scan(home, at: "Library/Developer/Xcode/Archives", context: context).candidates.first)
            XCTAssertEqual(protected.kind, .releaseArchive)
            XCTAssertFalse(protected.canConfirmTestPurpose)
            XCTAssertFalse(protected.canProcess)
            // Even a fresh user declaration cannot override an Organizer release record.
            let attempted = SpaceCleaningContext(homeDirectory: home, testDeclarations: [.init(candidate: protected)])
            XCTAssertFalse(try XCTUnwrap(scan(home, at: "Library/Developer/Xcode/Archives", context: attempted).candidates.first).canProcess)
            XCTAssertEqual(SpaceCleaningScanner.validatePolicy(candidate: declared, context: context), .protected)
        }
    }

    func testCacheDatabaseAndTransactionSidecarsAreRetainedAsOneDirectory() throws {
        try fixture { home in
            try file(home, "Library/Caches/com.apple.Safari/Session/cache.db", bytes: 10)
            try file(home, "Library/Caches/com.apple.Safari/Session/cache.db-wal", bytes: 20)
            let candidate = try XCTUnwrap(scan(home, at: "Library/Caches/com.apple.Safari").candidates.first)
            XCTAssertEqual(candidate.group, .protected)
            XCTAssertEqual(candidate.logicalBytes, 30)
        }
    }

    func testSymlinkTargetsAreNotCountedOrTraversedAndCacheDirectoryWithLinkCannotProcess() throws {
        try fixture { home in
            let source = try file(home, "outside/secret", bytes: 999)
            let cache = home.appendingPathComponent("Library/Caches/com.apple.Safari/entry")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("link"), withDestinationURL: source)
            let report = scan(home, at: "Library/Caches/com.apple.Safari")
            XCTAssertEqual(report.logicalBytes, 0)
            XCTAssertEqual(report.candidates.first?.group, .protected)
            XCTAssertFalse(report.candidates.first?.canProcess ?? true)
            XCTAssertEqual(try Data(contentsOf: source).count, 999)
        }
    }

    func testTestBundleAllowsInternalRelativeLinkButRejectsEscape() throws {
        try fixture { home in
            try file(home, "Builds/Test.app/Contents/target", bytes: 10)
            let link = home.appendingPathComponent("Builds/Test.app/Contents/link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target")
            let candidate = try XCTUnwrap(scan(home, at: "Builds").candidates.first)
            XCTAssertTrue(candidate.canConfirmTestPurpose)
            let context = SpaceCleaningContext(homeDirectory: home, testDeclarations: [.init(candidate: candidate)])
            XCTAssertTrue(try XCTUnwrap(scan(home, at: "Builds", context: context).candidates.first).canProcess)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../outside")
            let changed = try XCTUnwrap(scan(home, at: "Builds").candidates.first)
            XCTAssertFalse(changed.canConfirmTestPurpose)
            XCTAssertFalse(changed.canProcess)
        }
    }

    func testDerivedDataProductWithNestedBundleLinkStaysProtectedWithExplicitReason() throws {
        try fixture { home in
            let relative = "Library/Developer/Xcode/DerivedData/Example/Build/Products/Debug/Example.app/Contents"
            try file(home, relative + "/target")
            try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(relative + "/link").path, withDestinationPath: "target")
            let candidate = try XCTUnwrap(scan(home, at: "Library/Developer/Xcode/DerivedData").candidates.first)
            XCTAssertEqual(candidate.group, .protected)
            XCTAssertTrue(candidate.reason.contains("构建产物"))
            XCTAssertTrue(candidate.reason.contains("链接"))
        }
    }

    func testHardLinksAreProtectedAndDeduplicated() throws {
        try fixture { home in
            let one = try file(home, "Library/Caches/com.apple.Safari/one", bytes: 100)
            try FileManager.default.linkItem(at: one, to: one.deletingLastPathComponent().appendingPathComponent("two"))
            let report = scan(home, at: "Library/Caches/com.apple.Safari")
            XCTAssertEqual(report.candidates.count, 1)
            XCTAssertEqual(report.logicalBytes, 100)
            XCTAssertEqual(report.candidates.first?.kind, .hardLink)
            XCTAssertTrue(report.issues.contains { $0.kind == .duplicate })
        }
    }

    func testOverlappingScopesKeepOrderAndDoNotDuplicateFiles() throws {
        try fixture { home in
            try file(home, "parent/child/one", bytes: 10)
            try file(home, "parent/two", bytes: 20)
            let report = SpaceCleaningScanner.scan(scopes: [
                .init(directory: home.appendingPathComponent("parent/child")),
                .init(directory: home.appendingPathComponent("parent"))
            ], context: .init(homeDirectory: home))
            XCTAssertEqual(report.logicalBytes, 30)
            XCTAssertEqual(report.candidates.count, 2)
        }
    }

    func testCancellationAndEntryBoundsKeepHonestIncompleteReports() throws {
        try fixture { home in
            for index in 0..<20 { try file(home, "scope/\(index)") }
            let scope = SpaceCleaningScope(directory: home.appendingPathComponent("scope"))
            var checked = 0
            var events: [SpaceCleaningProgress] = []
            let report = SpaceCleaningScanner.scan(scopes: [scope], context: .init(homeDirectory: home),
                                                    isCancelled: { checked >= 3 }, progress: { checked = $0.checkedEntries; events.append($0) })
            XCTAssertFalse(report.complete)
            XCTAssertEqual(report.stage, .cancelled)
            XCTAssertEqual(report.checkedEntries, 3)
            XCTAssertTrue(events.contains { $0.currentFileName != nil && $0.checkedEntries > 0 })
            let bounded = scan(home, at: "scope", options: .init(maximumEntries: 4))
            XCTAssertFalse(bounded.complete)
            XCTAssertTrue(bounded.reachedLimit)
            XCTAssertEqual(bounded.checkedEntries, 4)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scope.directory.path).count, 20)
        }
    }

    func testDepthLimitAndPackageRootCannotTurnPartialTreeIntoDeletableCandidate() throws {
        try fixture { home in
            try file(home, "Builds/Test.app/Contents/nested/deeper/file")
            let limited = scan(home, at: "Builds", options: .init(maximumDepth: 1))
            XCTAssertFalse(limited.complete)
            XCTAssertFalse(limited.candidates.first?.canProcess ?? true)
            XCTAssertFalse(limited.candidates.first?.sizeIsComplete ?? true)
            let packageRoot = scan(home, at: "Builds/Test.app")
            XCTAssertTrue(packageRoot.candidates.isEmpty)
            XCTAssertTrue(packageRoot.issues.contains { $0.kind == .unsafePath })
        }
    }

    func testProtectedArchiveDepthBoundDoesNotStopLaterReviewableScope() throws {
        try fixture { home in
            try file(home, "ReleaseArchives/1.0/nested/deeper/important.dmg")
            try file(home, "Downloads/package.dmg", bytes: 55)
            let report = SpaceCleaningScanner.scan(scopes: [
                .init(directory: home.appendingPathComponent("ReleaseArchives"), kind: .releaseArchives),
                .init(directory: home.appendingPathComponent("Downloads"), kind: .downloads)
            ], context: .init(homeDirectory: home), options: .init(maximumDepth: 1))
            XCTAssertTrue(report.complete)
            XCTAssertFalse(report.coverageComplete)
            XCTAssertFalse(report.candidates.first { $0.group == .protected }?.sizeIsComplete ?? true)
            XCTAssertTrue(report.candidates.first { $0.title == "package.dmg" }?.canProcess ?? false)
        }
    }

    func testIdentityAndAncestorReplacementInvalidateSelectedFile() throws {
        try fixture { home in
            let path = try file(home, "scope/sub/item")
            let candidate = try XCTUnwrap(scan(home, at: "scope").candidates.first)
            let context = SpaceCleaningContext(homeDirectory: home)
            XCTAssertEqual(candidate.ancestorIdentities.map { $0.url.lastPathComponent }, ["scope", "sub"])
            XCTAssertEqual(SpaceCleaningScanner.revalidate(candidate: candidate, context: context), .unchanged)
            try FileManager.default.moveItem(at: path.deletingLastPathComponent(), to: home.appendingPathComponent("moved"))
            try FileManager.default.createSymbolicLink(at: path.deletingLastPathComponent(), withDestinationURL: home.appendingPathComponent("moved"))
            XCTAssertEqual(SpaceCleaningScanner.revalidate(candidate: candidate, context: context), .scopeChanged)
        }
    }

    func testCustomScopeInsideAppOrArchiveCannotExposePackageInternalsForDeletion() throws {
        try fixture { home in
            try file(home, "Builds/Test.app/Contents/Resources/file")
            try file(home, "Builds/Test.xcarchive/dSYMs/file")
            for relative in ["Builds/Test.app/Contents/Resources", "Builds/Test.xcarchive/dSYMs"] {
                let report = scan(home, at: relative)
                XCTAssertTrue(report.candidates.isEmpty)
                XCTAssertTrue(report.issues.contains { $0.kind == .unsafePath })
            }
            try file(home, "Library/Application Support/Example/ReleaseArchives/1.0/package.dmg")
            let release = scan(home, at: "Library/Application Support/Example/ReleaseArchives/1.0")
            XCTAssertEqual(release.candidates.first?.group, .protected)
        }
    }

    func testPolicyOnlyValidationWorksAfterTrashAndBlocksNewReleaseProtection() throws {
        try fixture { home in
            let url = try file(home, "Downloads/package.dmg")
            let candidate = try XCTUnwrap(scan(home, at: "Downloads").candidates.first)
            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(SpaceCleaningScanner.validatePolicy(candidate: candidate, context: .init(homeDirectory: home)), .unchanged)
            XCTAssertEqual(SpaceCleaningScanner.validatePolicy(candidate: candidate, context: .init(homeDirectory: home, protectedReleaseURLs: [url])), .protected)
            XCTAssertEqual(SpaceCleaningScanner.revalidate(candidate: candidate, context: .init(homeDirectory: home)), .missing)
        }
    }

    func testDiagnosticAgeUsesMetadataAndReportsRoundTrip() throws {
        try fixture { home in
            let old = try file(home, "Library/Logs/DiagnosticReports/old.ips")
            try file(home, "Library/Logs/DiagnosticReports/recent.log")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86_400)], ofItemAtPath: old.path)
            let report = scan(home, at: "Library/Logs/DiagnosticReports")
            XCTAssertEqual(report.candidates.first { $0.title == "old.ips" }?.kind, .oldDiagnostic)
            XCTAssertEqual(report.candidates.first { $0.title == "recent.log" }?.kind, .recentDiagnostic)
            XCTAssertTrue(try XCTUnwrap(report.candidates.first { $0.title == "old.ips" }).isCleanupSuggestion)
            XCTAssertFalse(try XCTUnwrap(report.candidates.first { $0.title == "recent.log" }).isCleanupSuggestion)
            XCTAssertEqual(try JSONDecoder().decode(SpaceCleaningReport.self, from: JSONEncoder().encode(report)), report)
        }
    }

    func testMissingScopeAndSymbolicScopeAreDistinguished() throws {
        try fixture { home in
            let missing = scan(home, at: "missing")
            XCTAssertEqual(missing.issues.first?.kind, .missing)
            try file(home, "real/file")
            let link = home.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("real"))
            let linked = scan(home, at: "link")
            XCTAssertTrue(linked.candidates.isEmpty)
            XCTAssertEqual(linked.issues.first?.kind, .unsafePath)
            XCTAssertFalse(linked.coverageComplete)
        }
    }

    func testUnreadableScopeReportsCoverageExceptionWithoutPretendingSuccess() throws {
        try fixture { home in
            let privateFile = try file(home, "restricted/private")
            let directory = privateFile.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            if FileManager.default.isReadableFile(atPath: directory.path) { throw XCTSkip("The current test account can bypass directory permissions.") }
            let report = scan(home, at: "restricted")
            XCTAssertTrue(report.complete)
            XCTAssertFalse(report.coverageComplete)
            XCTAssertTrue(report.candidates.isEmpty)
            XCTAssertTrue(report.issues.contains { $0.kind == .permissionDenied })
        }
    }

    func testRevalidationRejectsIncompleteAncestorChain() throws {
        try fixture { home in
            try file(home, "scope/nested/item")
            var candidate = try XCTUnwrap(scan(home, at: "scope").candidates.first)
            candidate.ancestorIdentities.removeLast()
            XCTAssertEqual(SpaceCleaningScanner.revalidate(candidate: candidate, context: .init(homeDirectory: home)), .scopeChanged)
        }
    }
    func testGlobalScopeCoversPersonalAndDevelopmentFoldersWithoutOtherUsers() throws {
        try fixture { home in
            for name in ["Desktop", "Documents", "Movies", "Pictures", "Music", "Public", "Developer"] {
                try file(home, name + "/personal.data")
            }
            try file(home, "Downloads/installer.dmg")
            try file(home, "Library/Caches/pip/http-v2/cache")
            let context = SpaceCleaningContext(homeDirectory: home)
            let scopes = SpaceCleaningScanner.globalScopes(context: context)
            XCTAssertTrue(scopes.allSatisfy { $0.directory.path.hasPrefix(home.path + "/") })
            let report = SpaceCleaningScanner.scan(scopes: scopes, context: context)
            XCTAssertEqual(report.candidates.count, 9)
            XCTAssertEqual(report.candidates.filter(\.isRecommendedForSelection).count, 1)
            XCTAssertFalse(report.candidates.filter { $0.kind == .personalFile }.contains(where: \.isRecommendedForSelection))
        }
    }

    func testProgressHasUnknownDiscoveryTotalAndRealVerificationDenominator() throws {
        try fixture { home in
            for index in 0..<5 { try file(home, "Downloads/file-\(index)") }
            var events: [SpaceCleaningProgress] = []
            let report = SpaceCleaningScanner.scan(scopes: [.init(directory: home.appendingPathComponent("Downloads"))],
                context: .init(homeDirectory: home), progress: { events.append($0) })
            XCTAssertTrue(report.complete)
            XCTAssertTrue(events.filter { $0.phase == .discovering }.allSatisfy { $0.totalItems == nil })
            let verifying = events.filter { $0.phase == .verifying }
            XCTAssertFalse(verifying.isEmpty)
            XCTAssertTrue(verifying.allSatisfy { $0.totalItems == 5 && $0.completedItems <= 5 })
            XCTAssertEqual(verifying.map(\.completedItems), verifying.map(\.completedItems).sorted())
            XCTAssertEqual(events.last?.completedItems, 5)
            XCTAssertEqual(events.last?.phase, .finished)
        }
    }

    func testDiscoveryToVerificationRejectsAncestorReplacement() throws {
        try fixture { home in
            try file(home, "Downloads/nested/file")
            var changed = false
            let report = SpaceCleaningScanner.scan(scopes: [.init(directory: home.appendingPathComponent("Downloads"))],
                context: .init(homeDirectory: home), progress: { progress in
                    guard progress.phase == .verifying, !changed else { return }
                    changed = true
                    let old = home.appendingPathComponent("Downloads/nested")
                    let moved = home.appendingPathComponent("moved")
                    try! FileManager.default.moveItem(at: old, to: moved)
                    try! FileManager.default.createSymbolicLink(at: old, withDestinationURL: moved)
                })
            XCTAssertTrue(report.candidates.isEmpty)
            XCTAssertTrue(report.issues.contains { $0.kind == .changed })
        }
    }

    func testRecommendationExcludesDiagnosticsAndIncompleteOrProtectedCaches() throws {
        try fixture { home in
            let old = try file(home, "Library/Logs/DiagnosticReports/old.crash")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -40 * 86400)], ofItemAtPath: old.path)
            try file(home, "Library/Caches/pip/http-v2/data")
            let report = scan(home)
            let diagnostic = try XCTUnwrap(report.candidates.first { $0.kind == .oldDiagnostic })
            XCTAssertTrue(diagnostic.isCleanupSuggestion)
            XCTAssertFalse(diagnostic.isRecommendedForSelection)
            var cache = try XCTUnwrap(report.candidates.first { $0.kind == .packageCache })
            XCTAssertTrue(cache.isRecommendedForSelection)
            XCTAssertTrue(cache.isCleanupSuggestion)
            cache.sizeIsComplete = false
            XCTAssertFalse(cache.isRecommendedForSelection)
            XCTAssertFalse(cache.isCleanupSuggestion)
            cache.sizeIsComplete = true; cache.group = .protected
            XCTAssertFalse(cache.isRecommendedForSelection)
            XCTAssertFalse(cache.isCleanupSuggestion)
        }
    }

    func testInstallerSuggestionsStayManualAndDoNotAbsorbPersonalImagesOrArchives() throws {
        try fixture { home in
            for relative in ["Downloads/Setup.dmg", "Desktop/nested/Setup.DMG", "Custom/Setup.pkg",
                             "Documents/Private.dmg", "Downloads/Files.zip", "Downloads/Private.sparseimage",
                             "Documents/Notes.txt", "Downloads/Private.sparsebundle/bands/data"] {
                try file(home, relative)
            }
            let report = scan(home)
            let suggestions = report.candidates.filter(\.isCleanupSuggestion)
            XCTAssertEqual(Set(suggestions.map { $0.url.path.replacingOccurrences(of: home.path + "/", with: "") }),
                           ["Downloads/Setup.dmg", "Desktop/nested/Setup.DMG", "Custom/Setup.pkg"])
            XCTAssertEqual(suggestions.filter { $0.kind == .downloadedDiskImage }.count, 2)
            XCTAssertEqual(suggestions.filter { $0.kind == .installerPackage }.count, 1)
            XCTAssertTrue(suggestions.allSatisfy { $0.group == .review && $0.canProcess && !$0.isRecommendedForSelection })
            XCTAssertTrue(report.candidates.filter { !suggestions.map(\.id).contains($0.id) }.allSatisfy { !$0.isCleanupSuggestion })
            XCTAssertEqual(try JSONDecoder().decode(SpaceCleaningReport.self, from: JSONEncoder().encode(report)), report)
        }
    }

    func testDirectoryInstallerPackageRemainsProtectedAsOneObject() throws {
        try fixture { home in
            try file(home, "Downloads/Legacy.pkg/Contents/Archive.pax.gz")
            let report = scan(home, at: "Downloads")
            XCTAssertEqual(report.candidates.count, 1)
            let candidate = try XCTUnwrap(report.candidates.first)
            XCTAssertEqual(candidate.title, "Legacy.pkg")
            XCTAssertEqual(candidate.kind, .package)
            XCTAssertEqual(candidate.group, .protected)
            XCTAssertFalse(candidate.isCleanupSuggestion)
            XCTAssertFalse(candidate.isRecommendedForSelection)
            XCTAssertFalse(candidate.canProcess)
        }
    }

    func testKnownRebuildableCacheRulesTakePrecedenceOverInstallerPresentation() throws {
        try fixture { home in
            try file(home, "Library/Caches/Homebrew/Setup.pkg", bytes: 31)
            try file(home, "Library/Caches/Homebrew/Legacy.pkg/Contents/Archive.pax.gz", bytes: 47)
            let contents = scan(home, at: "Library/Caches/Homebrew")
            XCTAssertEqual(contents.candidates.count, 2)
            XCTAssertTrue(contents.candidates.allSatisfy {
                $0.kind == .packageCache && $0.group == .rebuildable && $0.isCleanupSuggestion && $0.isRecommendedForSelection
            })
            XCTAssertTrue(contents.candidates.contains { $0.title == "Legacy.pkg" && $0.isDirectory })
            let aggregate = scan(home, at: "Library/Caches")
            XCTAssertEqual(aggregate.candidates.count, 1)
            let cache = try XCTUnwrap(aggregate.candidates.first)
            XCTAssertEqual(cache.kind, .packageCache)
            XCTAssertEqual(cache.logicalBytes, 78)
            XCTAssertTrue(cache.isCleanupSuggestion)
            XCTAssertTrue(cache.isRecommendedForSelection)
        }
    }

    func testReleaseAndHardLinkProtectionOverrideInstallerSuggestions() throws {
        try fixture { home in
            let explicitRelease = try file(home, "Downloads/Published.pkg")
            try file(home, "Desktop/ReleaseArchives/Published.dmg")
            let source = try file(home, "Documents/Original.dmg")
            let linked = home.appendingPathComponent("Downloads/Linked.dmg")
            try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: source, to: linked)
            let report = SpaceCleaningScanner.scan(scopes: [
                .init(directory: home.appendingPathComponent("Downloads")),
                .init(directory: home.appendingPathComponent("Desktop"))
            ], context: .init(homeDirectory: home, protectedReleaseURLs: [explicitRelease]))
            XCTAssertTrue(report.candidates.allSatisfy { !$0.isCleanupSuggestion && !$0.isRecommendedForSelection })
            XCTAssertEqual(report.candidates.first { $0.url == explicitRelease }?.kind, .releaseMaterial)
            XCTAssertEqual(report.candidates.first { $0.url == linked }?.kind, .hardLink)
            XCTAssertTrue(report.candidates.contains { $0.kind == .releaseMaterial && $0.url.path.contains("ReleaseArchives") })
        }
    }

    func testInstallerCloudPlaceholderAndIncompleteSnapshotCannotBeSuggested() throws {
        try fixture { home in
            let image = try file(home, "Downloads/Cloud.dmg")
            let package = try file(home, "Downloads/Setup.pkg")
            let report = SpaceCleaningScanner.scan(scopes: [.init(directory: home.appendingPathComponent("Downloads"))],
                context: .init(homeDirectory: home), metadata: .init(flags: { $0 == image ? UInt32(SF_DATALESS) : 0 }))
            let cloud = try XCTUnwrap(report.candidates.first { $0.url == image })
            XCTAssertEqual(cloud.kind, .cloudPlaceholder)
            XCTAssertFalse(cloud.isCleanupSuggestion)
            XCTAssertFalse(cloud.canProcess)
            var installer = try XCTUnwrap(report.candidates.first { $0.url == package })
            XCTAssertTrue(installer.isCleanupSuggestion)
            installer.sizeIsComplete = false
            XCTAssertFalse(installer.isCleanupSuggestion)
            XCTAssertFalse(installer.isRecommendedForSelection)
        }
    }

    func testInstallerPolicyRevalidationAndReceiptPolicyRemainDistinct() throws {
        try fixture { home in
            for relative in ["Downloads/Setup.dmg", "Custom/Setup.pkg"] {
                let url = try file(home, relative)
                let candidate = try XCTUnwrap(scan(home, at: url.deletingLastPathComponent().lastPathComponent).candidates.first)
                let context = SpaceCleaningContext(homeDirectory: home)
                XCTAssertTrue(candidate.isCleanupSuggestion)
                XCTAssertFalse(candidate.isRecommendedForSelection)
                XCTAssertEqual(SpaceCleaningScanner.revalidate(candidate: candidate, context: context), .unchanged)
                try FileManager.default.removeItem(at: url)
                XCTAssertEqual(SpaceCleaningScanner.validatePolicy(candidate: candidate, context: context), .unchanged)
                XCTAssertEqual(SpaceCleaningScanner.revalidate(candidate: candidate, context: context), .missing)
                XCTAssertEqual(SpaceCleaningScanner.validatePolicy(candidate: candidate,
                    context: .init(homeDirectory: home, protectedReleaseURLs: [url])), .protected)
            }
        }
    }

    func testIndividualTestReviewPreservesIdentityAndRejectsMutatedOrReleasedPackage() throws {
        try fixture { home in
            try file(home, "Builds/Test.app/Contents/MacOS/Test")
            let original = try XCTUnwrap(scan(home, at: "Builds").candidates.first)
            var context = SpaceCleaningContext(homeDirectory: home, testDeclarations: [.init(candidate: original)])
            let reviewed = try XCTUnwrap(SpaceCleaningScanner.reviewTestCandidate(original, context: context))
            XCTAssertEqual(reviewed.id, original.id)
            XCTAssertEqual(reviewed.kind, .testApplication)
            XCTAssertFalse(reviewed.isRecommendedForSelection)
            context.protectedReleaseURLs = [original.url]
            XCTAssertNil(SpaceCleaningScanner.reviewTestCandidate(original, context: context))
            context.protectedReleaseURLs = []
            try file(home, "Builds/Test.app/Contents/new-file")
            XCTAssertNil(SpaceCleaningScanner.reviewTestCandidate(original, context: context))
        }
    }

    func testLargeDiscoveryDoesNotStarvePreviouslyFoundCacheVerification() throws {
        try fixture { home in
            try file(home, "Library/Caches/pip/http-v2/data")
            for index in 0..<20 { try file(home, "Downloads/personal-\(index)") }
            let report = SpaceCleaningScanner.scan(scopes: [
                .init(directory: home.appendingPathComponent("Library/Caches/pip")),
                .init(directory: home.appendingPathComponent("Downloads"))
            ], context: .init(homeDirectory: home), options: .init(maximumEntries: 8))
            XCTAssertTrue(report.reachedLimit)
            XCTAssertFalse(report.complete)
            XCTAssertLessThanOrEqual(report.checkedEntries, 16)
            XCTAssertTrue(try XCTUnwrap(report.candidates.first { $0.kind == .packageCache }).isRecommendedForSelection)
            XCTAssertTrue(report.issues.contains { $0.kind == .entryLimit })
        }
    }

    func testCustomCacheParentPreservesNestedKnownBrowserRules() throws {
        try fixture { home in
            try file(home, "Library/Caches/Google/Chrome/Default/Cache/data", bytes: 31)
            try file(home, "Library/Caches/Firefox/Profiles/profile/cache2/entries/data", bytes: 47)
            try file(home, "Library/Caches/Google/Other/personal.data", bytes: 53)
            let report = scan(home, at: "Library/Caches")
            XCTAssertTrue(report.complete)
            XCTAssertEqual(report.candidates.filter(\.isRecommendedForSelection).count, 2)
            XCTAssertEqual(report.candidates.filter(\.isRecommendedForSelection).reduce(0) { $0 + $1.logicalBytes }, 78)
            XCTAssertFalse(try XCTUnwrap(report.candidates.first { $0.title == "personal.data" }).isRecommendedForSelection)
            XCTAssertEqual(report.logicalBytes, 131)
        }
    }

    func testProtectedBrowserCannotStarveLaterRebuildableCacheVerification() throws {
        try fixture { home in
            for index in 0..<20 { try file(home, "Library/Caches/Google/Chrome/Default/cache-\(index)") }
            try file(home, "Library/Caches/pip/http-v2/data", bytes: 73)
            let context = SpaceCleaningContext(homeDirectory: home,
                runningApplicationURLs: [home.appendingPathComponent("Google Chrome.app")])
            let report = SpaceCleaningScanner.scan(scopes: [
                .init(directory: home.appendingPathComponent("Library/Caches/Google/Chrome")),
                .init(directory: home.appendingPathComponent("Library/Caches/pip"))
            ], context: context, options: .init(maximumEntries: 8))
            let candidate = try XCTUnwrap(report.candidates.first { $0.kind == .packageCache })
            XCTAssertTrue(candidate.isRecommendedForSelection)
            XCTAssertEqual(candidate.logicalBytes, 73)
            XCTAssertEqual(SpaceCleaningScanner.revalidate(candidate: candidate, context: context), .unchanged)
            XCTAssertTrue(report.candidates.filter { $0.kind == .runningApplication }.allSatisfy { !$0.canProcess })
            XCTAssertTrue(report.reachedLimit)
            XCTAssertLessThanOrEqual(report.checkedEntries, 16)
        }
    }

}
