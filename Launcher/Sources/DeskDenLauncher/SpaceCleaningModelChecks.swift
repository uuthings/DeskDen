import Foundation
import LauncherCore

/// Exercises the production model, scanner, transaction, persistence and quit
/// barrier. All source objects, history and the injected Trash are temporary
/// fixtures; this never invokes the system Trash or scans the user's home.
@MainActor enum SpaceCleaningModelChecks {
    /// Focused scope-selection checks; all scans use owned temporary folders.
    static func runScopeGroups() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let fm = FileManager.default
        let rawRoot = fm.temporaryDirectory.appendingPathComponent("deskden-cleaning-groups-" + UUID().uuidString)
        var models: [SpaceCleaningModel] = []
        defer { try? fm.removeItem(at: rawRoot) }
        do {
            try fm.createDirectory(at: rawRoot, withIntermediateDirectories: true)
            guard let root = SpaceCleaningScanner.canonicalURL(rawRoot) else { throw CheckError.missing }
            let home = root.appendingPathComponent("Home"), state = root.appendingPathComponent("State")
            // realpath-backed scanner URLs and Foundation/bookmark URLs can use
            // different /var aliases or directory hints for the same fixture.
            func path(_ url: URL) -> String { url.standardizedFileURL.path }
            func relativePath(_ url: URL) -> String {
                let prefix = path(home) + "/", value = path(url)
                return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : "<outside fixture home>"
            }
            func itemDetails(_ items: [CleaningItemDisplay]) -> String {
                items.map { relativePath($0.url) + "|" + $0.kind.rawValue + "|" + $0.group.rawValue }.sorted().joined(separator: ", ")
            }
            let relativeFiles = ["Downloads/download.txt", "Documents/document.txt", "Public/shared.txt", "Desktop/desktop.txt",
                                 "Pictures/photo.txt", "Music/audio.txt", "Movies/movie.txt", "Extra/selected.txt",
                                 "Library/Caches/pip/http-v2/cache", "Developer/Project/node_modules/library/index.js",
                                 "Applications/Keep.app/Contents/keep.data", "ReleaseArchives/release.dmg",
                                 "Library/Application Support/ScopeApp/user-note.txt",
                                 "Library/Application Support/ScopeApp/ReleaseArchives/1.0/release.dmg"]
            for path in relativeFiles {
                let file = home.appendingPathComponent(path)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("owned-scope-check".utf8).write(to: file)
            }
            let mover = SpaceCleaningCheckMover(root: root, trash: root.appendingPathComponent("UnusedTrash"))
            let model = SpaceCleaningModel(dataDirectory: state, homeDirectory: home, mover: mover); models.append(model)
            await model.waitUntilIdle()
            let context = SpaceCleaningContext(homeDirectory: home, protectedReleaseURLs: [home.appendingPathComponent("ReleaseArchives")])
            let global = SpaceCleaningScanner.globalScopes(context: context)
            func descriptors(_ scopes: [SpaceCleaningScope]) -> [String] {
                scopes.map { $0.directory.standardizedFileURL.path + "|" + $0.kind.rawValue + "|" + $0.title }
            }
            check(CleaningScopeGroup.allCases.count == 6 && model.canScanScope && model.selectedScopeGroups.isEmpty &&
                  CleaningScopeGroup.allCases.allSatisfy { model.includesScopeGroup($0) },
                  "global scanning displays all six groups without creating a custom selection")
            check(descriptors(model.selectedScopes(context)) == descriptors(global) && global.allSatisfy { scope in
                CleaningScopeGroup.allCases.filter { $0.includes(scope, home: home) }.count == 1
            }, "the six presentation groups partition the complete unchanged global scope definitions")
            check(CleaningScopeGroup.documents.detailPaths.contains("~/Public") &&
                  global.filter { CleaningScopeGroup.caches.includes($0, home: home) }.allSatisfy { [.browserCache, .packageCache, .diagnostics].contains($0.kind) } &&
                  global.filter { $0.kind == .derivedData || $0.kind == .releaseArchives || $0.kind == .installedApplications }.allSatisfy { CleaningScopeGroup.development.includes($0, home: home) },
                  "group mapping includes Public and preserves cache, build, archive and application policies")
            model.editScope(custom: true)
            check(!model.canApplyScope && model.draftScopeGroups.isEmpty && !model.includesScopeGroup(.downloads, draft: true),
                  "an empty custom draft does not silently inherit all global groups")
            model.applyScope()
            check(model.scopeChoice == .global && model.screen == .scope && !fm.fileExists(atPath: state.appendingPathComponent("scope.json").path),
                  "saving an empty custom draft cannot replace or persist the active global range")
            model.toggleDraftScopeGroup(.downloads)
            check(model.canApplyScope && model.draftScopeGroups == [.downloads] && model.selectedScopeGroups.isEmpty,
                  "group toggles update only the editable draft")
            model.cancelScope()
            check(model.scopeChoice == .global && model.screen == .start && model.selectedScopeGroups.isEmpty &&
                  !fm.fileExists(atPath: state.appendingPathComponent("scope.json").path),
                  "cancelling the group draft preserves the active range and saved configuration")
            model.editScope(custom: true)
            model.setDraftScopeGroup(.downloads, selected: true); model.setDraftScopeGroup(.documents, selected: true)
            model.addDraftDirectories([home.appendingPathComponent("Extra"), home.appendingPathComponent("Downloads"), home.appendingPathComponent("Downloads")])
            model.applyScope()
            let chosen = model.selectedScopes(context)
            check(model.scopeChoice == .custom && model.selectedScopeGroups == [.downloads, .documents] && model.canScanScope && model.customDirectories.count == 2,
                  "saving combines selected groups with bookmarked arbitrary folders without starting a scan")
            check(chosen.filter { $0.directory.lastPathComponent == "Downloads" }.map(\.kind) == [.downloads] &&
                  Set(chosen.map { $0.directory.lastPathComponent }) == ["Downloads", "Documents", "Public", "Extra"],
                  "duplicate extra folders cannot replace a selected built-in scope or change its kind")
            model.startScan(); await model.waitUntilIdle()
            let expectedFiles = Set(["Downloads/download.txt", "Documents/document.txt", "Public/shared.txt", "Extra/selected.txt"].map { home.appendingPathComponent($0) })
            let savedRangeMatches = Set(model.items.map { path($0.url) }) == Set(expectedFiles.map(path)) &&
                model.items.first { $0.name == "download.txt" }?.kind == .downloadedFile && mover.moveCount == 0
            check(savedRangeMatches,
                  "the production scanner reads exactly the saved groups and extra folder without scanning unchecked categories or moving files")
            if !savedRangeMatches {
                print("DETAIL saved-range actual=[\(itemDetails(model.items))]; expected=[\(expectedFiles.map(relativePath).sorted().joined(separator: ", "))]")
            }
            let resultIDs = model.items.map(\.id)
            model.editScope()
            for group in CleaningScopeGroup.allCases { model.setDraftScopeGroup(group, selected: false) }
            for directory in model.draftDirectories { model.removeDraftDirectory(directory) }
            model.applyScope()
            check(!model.canApplyScope && model.screen == .scope && model.selectedScopeGroups == [.downloads, .documents] && model.items.map(\.id) == resultIDs,
                  "clearing every draft choice cannot overwrite the saved range or discard existing results")
            model.cancelScope()
            check(model.screen == .results && model.draftScopeGroups == model.selectedScopeGroups && model.items.map(\.id) == resultIDs,
                  "cancel restores the saved group selection and returns to the unchanged results")
            let savedData = try Data(contentsOf: state.appendingPathComponent("scope.json"))
            let saved = try JSONSerialization.jsonObject(with: savedData) as! [String: Any]
            check((saved["bookmarks"] as? [String])?.count == 2 && Set(saved["groups"] as? [String] ?? []) == ["downloads", "documents"],
                  "scope persistence retains security bookmarks alongside explicit group identifiers")
            let reload = SpaceCleaningModel(dataDirectory: state, homeDirectory: home, mover: mover); models.append(reload)
            await reload.waitUntilIdle()
            check(reload.selectedScopeGroups == [.downloads, .documents] && reload.customDirectories == model.customDirectories &&
                  descriptors(reload.selectedScopes(context)) == descriptors(chosen),
                  "saved groups and existing security-scoped folders restore to the same actual scan definitions")
            reload.selectScope(.global)
            check(descriptors(reload.selectedScopes(context)) == descriptors(global) && reload.selectedScopeGroups == [.downloads, .documents],
                  "returning to global restores every original scope while remembering the custom choice")

            let legacyState = root.appendingPathComponent("LegacyState")
            try fm.createDirectory(at: legacyState, withIntermediateDirectories: true)
            var legacy = saved; legacy.removeValue(forKey: "groups")
            try JSONSerialization.data(withJSONObject: legacy).write(to: legacyState.appendingPathComponent("scope.json"))
            let legacyModel = SpaceCleaningModel(dataDirectory: legacyState, homeDirectory: home, mover: mover); models.append(legacyModel)
            await legacyModel.waitUntilIdle()
            check(legacyModel.scopeChoice == .custom && legacyModel.selectedScopeGroups.isEmpty && legacyModel.customDirectories == model.customDirectories &&
                  Set(legacyModel.selectedScopes(context).map(\.directory)) == Set(model.customDirectories),
                  "legacy custom settings without a groups field restore only their previously authorized directories")
            let emptyState = root.appendingPathComponent("EmptyLegacyState")
            try fm.createDirectory(at: emptyState, withIntermediateDirectories: true)
            let empty: [String: Any] = ["format": 1, "choice": "custom", "bookmarks": [], "requestedPaths": []]
            try JSONSerialization.data(withJSONObject: empty).write(to: emptyState.appendingPathComponent("scope.json"))
            let emptyModel = SpaceCleaningModel(dataDirectory: emptyState, homeDirectory: home, mover: mover); models.append(emptyModel)
            emptyModel.startScan()
            check(!emptyModel.canScanScope && !emptyModel.isBusy && emptyModel.items.isEmpty && emptyModel.selectedScopes(context).isEmpty,
                  "an empty restored custom scope cannot trigger a global scan")

            model.editScope(custom: true)
            for group in CleaningScopeGroup.allCases { model.setDraftScopeGroup(group, selected: true) }
            for directory in model.draftDirectories { model.removeDraftDirectory(directory) }
            model.applyScope()
            check(descriptors(model.selectedScopes(context)) == descriptors(global),
                  "selecting all six groups produces the original global scope order and policies exactly")
            let groupedScopes = model.selectedScopes(context)
            let report = await Task.detached(priority: .utility) {
                SpaceCleaningScanner.scan(scopes: groupedScopes, context: context)
            }.value
            check(report.candidates.contains { $0.kind == .packageCache && $0.group == .rebuildable } &&
                  report.candidates.contains { $0.kind == .developmentEnvironment && $0.group == .protected } &&
                  report.candidates.contains { $0.url.path.contains("/ReleaseArchives/") && $0.group == .protected } &&
                  report.candidates.contains { $0.url.lastPathComponent == "Keep.app" && $0.group == .protected },
                  "real grouped scanning preserves recognized caches, dependency boundaries, release archives and installed-app protection")
            let applicationSupport = home.appendingPathComponent("Library/Application Support")
            let supportUserFile = applicationSupport.appendingPathComponent("ScopeApp/user-note.txt")
            let supportArchive = applicationSupport.appendingPathComponent("ScopeApp/ReleaseArchives")
            check(!report.candidates.contains { path($0.url) == path(supportUserFile) },
                  "release-archive discovery alone never scans unrelated Application Support user content")
            model.editScope(custom: true)
            for group in CleaningScopeGroup.allCases { model.setDraftScopeGroup(group, selected: group == .development) }
            model.addDraftDirectories([applicationSupport, applicationSupport])
            model.applyScope()
            let supportScopes = model.selectedScopes(context).filter { path($0.directory) == path(applicationSupport) }
            let supportScopesMatch = supportScopes.map(\.kind) == [.releaseArchiveDiscovery, .custom]
            check(supportScopesMatch,
                  "same-root archive discovery and an explicit custom folder both remain in scan order without duplicating ordinary scopes")
            if !supportScopesMatch {
                print("DETAIL support scopes=[\(model.selectedScopes(context).map { relativePath($0.directory) + "|" + $0.kind.rawValue }.joined(separator: ", "))]")
            }
            model.startScan(); await model.waitUntilIdle()
            let supportContentMatches = model.items.contains { path($0.url) == path(supportUserFile) && $0.kind == .personalFile && $0.group == .review && !$0.isDirectory } &&
                model.items.contains { path($0.url) == path(supportArchive) && $0.kind == .releaseMaterial && $0.group == .protected && !$0.isSelectable } &&
                fm.fileExists(atPath: supportArchive.appendingPathComponent("1.0/release.dmg").path)
            check(supportContentMatches,
                  "an explicit Application Support scan finds user content while its discovered release archives remain protected")
            if !supportContentMatches { print("DETAIL support scan=[\(itemDetails(model.items))]") }
            check(mover.moveCount == 0 && expectedFiles.allSatisfy { fm.fileExists(atPath: $0.path) },
                  "scope selection and verification never perform cleanup transactions")
        } catch { check(false, "scope-group fixture setup or execution: " + error.localizedDescription) }
        for model in models { await model.prepareForQuit() }
        return (count, failures)
    }

    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let rawRoot = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-cleaning-model-" + UUID().uuidString)
        var movers: [SpaceCleaningCheckMover] = []
        var models: [SpaceCleaningModel] = []
        defer { movers.forEach { $0.release() }; try? FileManager.default.removeItem(at: rawRoot) }
        do {
            try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
            guard let root = SpaceCleaningScanner.canonicalURL(rawRoot) else { throw CheckError.missing }
            // Eighty thousand immutable metadata rows exercise the same result
            // index as production without scanning or creating eighty thousand
            // files. Candidate transactions remain a separate empty index.
            let largeIndex = await Task.detached(priority: .utility) {
                let rows = (0..<80_000).map { index in
                    let protected = index % 10 == 9
                    let name = String(format: "item-%06d.data", index)
                    let parent = root.appendingPathComponent("uncreated-results/group-\(index % 17)")
                    return CleaningItemDisplay(id: UUID(), name: name, url: parent.appendingPathComponent(name),
                        bytes: UInt64(index + 1) * 100, allocatedBytes: UInt64(index + 1) * 128, sizeIsComplete: true,
                        group: protected ? .protected : .review, subtitle: parent.path, reason: "Synthetic metadata",
                        impact: "No file exists", isSelectable: !protected, needsPurposeConfirmation: false,
                        kind: protected ? .developmentEnvironment : .downloadedFile, isDirectory: false,
                        modifiedDate: Date(timeIntervalSince1970: Double(index)))
                }
                let recommendations = Set(rows.prefix(42).filter(\.isSelectable).map(\.id))
                return CleaningResultsIndex(items: rows, recommendedIDs: recommendations)
            }.value
            let bulk = SpaceCleaningModel(dataDirectory: root.appendingPathComponent("bulk-metadata-state"), homeDirectory: root)
            models.append(bulk); await bulk.waitUntilIdle()
            bulk.installResultIndex(largeIndex)
            check(bulk.items.count == 80_000 && bulk.recommendedItems.count == 38 && bulk.protectedItems.count == 8_000 &&
                  bulk.otherItems.count == 71_962 && bulk.reviewableItems.count == 72_000,
                  "eighty-thousand-row classification is prepared once with exact cached category counts")
            check(bulk.recommendedAllocatedBytes == bulk.recommendedItems.reduce(0, { $0 &+ $1.allocatedBytes }) &&
                  bulk.reviewableAllocatedBytes == bulk.reviewableItems.reduce(0, { $0 &+ $1.allocatedBytes }),
                  "cached result totals preserve exact scanned disk allocation")
            let buildsBeforeReads = bulk.resultProjectionBuildCount
            for _ in 0..<1_000 {
                _ = bulk.visibleItems.count; _ = bulk.visibleSelectableCount
                _ = bulk.recommendedItems.count; _ = bulk.otherItems.count; _ = bulk.protectedItems.count
                _ = bulk.selectedCount; _ = bulk.selectedBytes; _ = bulk.selectedAllocatedBytes
            }
            check(bulk.resultProjectionBuildCount == buildsBeforeReads,
                  "repeated view and scrolling readouts never rebuild or sort the full result set")
            bulk.showResults(.reviewable)
            check(!bulk.isUpdatingResults && bulk.visibleItems.count == 71_962 && bulk.resultProjectionBuildCount == buildsBeforeReads,
                  "switching a large default tab uses its ready projection without waiting for a scan or sort")
            let selectedBulk = bulk.otherItems[12], protectedBulk = bulk.protectedItems[3]
            bulk.toggleItem(selectedBulk.id); bulk.toggleItem(protectedBulk.id)
            check(bulk.selectedItems.map(\.id) == [selectedBulk.id] && bulk.selectedAllocatedBytes == selectedBulk.allocatedBytes &&
                  bulk.someVisibleSelected && !bulk.allVisibleSelected,
                  "ID-indexed selection keeps cached totals and excludes protected rows")
            let queryStarted = ProcessInfo.processInfo.systemUptime
            bulk.sortResults(by: .name)
            bulk.searchText = "item-0000"
            bulk.searchText = "item-079998"
            let schedulingSeconds = ProcessInfo.processInfo.systemUptime - queryStarted
            check(bulk.isUpdatingResults && bulk.visibleItems.isEmpty && bulk.visibleSelectableIDs.isEmpty,
                  "large filtering runs asynchronously and never leaves the previous category actionable")
            await bulk.waitForResultProjection()
            check(bulk.visibleItems.map(\.name) == ["item-079998.data"] && !bulk.isUpdatingResults &&
                  bulk.selectedIDs == [selectedBulk.id],
                  "the newest rapid search wins while obsolete large sorts cannot overwrite it or clear hidden selection")
            print("DETAIL large-result query scheduling seconds=\(schedulingSeconds); immutable rows=80000; no filesystem enumeration")
            bulk.searchText = "item-079997"; await bulk.waitForResultProjection()
            let buildsBeforeCacheHit = bulk.resultProjectionBuildCount
            bulk.searchText = "item-079998"; await bulk.waitForResultProjection()
            check(bulk.resultProjectionBuildCount == buildsBeforeCacheHit && bulk.visibleItems.first?.name == "item-079998.data",
                  "revisiting an unchanged completed query reuses its bounded cache")
            bulk.toggleSelectedFilter(); await bulk.waitForResultProjection()
            check(bulk.visibleItems.map(\.id) == [selectedBulk.id] && bulk.searchText.isEmpty,
                  "selected-only projection uses real selected identities and clears an unrelated search")
            let replacementBulk = bulk.otherItems[24]
            bulk.selectedIDs = [replacementBulk.id]
            await bulk.waitForResultProjection()
            check(bulk.visibleItems.map(\.id) == [replacementBulk.id] && bulk.selectedCount == 1 &&
                  bulk.selectedBytes == replacementBulk.bytes && bulk.allVisibleSelected,
                  "selection revisions invalidate selected-only caches without reviving removed selections")
            let cancelledQuery = CleaningResultsQuery(tab: 1, sort: "name", ascending: true, search: "", selectedRevision: nil)
            let cancelledWork = Task.detached(priority: .utility) {
                CleaningResultsProjection.make(largeIndex.entries(for: 1, selectedIDs: nil), query: cancelledQuery)
            }
            cancelledWork.cancel()
            check(await cancelledWork.value == nil, "an obsolete eighty-thousand-row query cooperatively cancels before publishing a projection")
            check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("uncreated-results").path),
                  "large-result classification, filtering, sorting and selection never read or create source files")
            let largeFixture = try fixture(root.appendingPathComponent("large-file-policy"), names: ["large.data", "small.data"])
            try Data(repeating: 1, count: 200).write(to: largeFixture.home.appendingPathComponent("Downloads/large.data"))
            let largeCache = largeFixture.home.appendingPathComponent(".npm/_cacache/large.cache")
            let dependency = largeFixture.home.appendingPathComponent("Developer/Project/node_modules/library/index.js")
            for url in [largeCache, dependency] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 1, count: 150).write(to: url)
            }
            let largeMover = SpaceCleaningCheckMover(root: largeFixture.home, trash: largeFixture.trash); movers.append(largeMover)
            let largeModel = SpaceCleaningModel(dataDirectory: largeFixture.data, homeDirectory: largeFixture.home, mover: largeMover); models.append(largeModel)
            largeModel.selectScanMode(.largeFiles)
            largeModel.minimumFileSize = "0.0001"; largeModel.maximumFileSize = "0.0002"; largeModel.scanSettingsChanged()
            largeModel.startScan(); await largeModel.waitUntilIdle()
            check(largeModel.resultTab == .reviewable && largeModel.reviewableItems.count == 2 && largeModel.selectedIDs.isEmpty &&
                  largeModel.automaticallySelectedIDs.isEmpty && largeModel.recommendedIDs.isEmpty && largeMover.moveCount == 0,
                  "large-file mode filters early and never preselects even a recognized cache")
            check(largeModel.visibleItems.map(\.bytes) == [200, 150] && largeModel.items.contains { $0.kind == .developmentEnvironment && !$0.isSelectable } &&
                  !largeModel.items.contains { $0.url == dependency }, "large-file results sort by logical size and exclude protected dependency contents")
            guard let protectedDirectory = largeModel.items.first(where: { $0.kind == .developmentEnvironment }) else { throw CheckError.missing }
            let itemIDsBeforeMeasurement = largeModel.items.map(\.id)
            largeModel.measureDirectorySize(protectedDirectory.id); await largeModel.waitUntilIdle()
            check(largeModel.directorySizes[protectedDirectory.id]?.complete == true && largeModel.directorySizes[protectedDirectory.id]?.logicalBytes == 150 &&
                  largeModel.items.map(\.id) == itemIDsBeforeMeasurement && largeModel.selectedIDs.isEmpty &&
                  largeModel.items.first(where: { $0.id == protectedDirectory.id })?.isSelectable == false,
                  "explicit directory size inquiry reports capacity without adding dependency files or removing protection")
            largeModel.measureDirectorySize(protectedDirectory.id); largeModel.cancelDirectorySize(); await largeModel.waitUntilIdle()
            check(largeModel.directorySizes[protectedDirectory.id]?.cancelled == true && largeModel.directorySizes[protectedDirectory.id]?.complete == false &&
                  largeModel.measuringDirectoryID == nil && !largeModel.isBusy, "directory size inquiry can be cancelled without changing scan candidates")
            largeModel.selectRecommended()
            check(largeModel.selectedIDs.isEmpty, "recommendation action cannot preselect large-file results")
            largeModel.toggleVisibleSelection()
            check(largeModel.selectedItems.count == 2 && largeModel.selectedItems.allSatisfy { $0.sizeIsComplete }, "manual large-file selection excludes protected boundaries")
            let largeReload = SpaceCleaningModel(dataDirectory: largeFixture.data, homeDirectory: largeFixture.home, mover: largeMover); models.append(largeReload)
            check(largeReload.scanMode == .largeFiles && largeReload.minimumFileSize == "0.0001" && largeReload.maximumFileSize == "0.0002" &&
                  largeReload.fileSizeUnit == .mb && largeReload.items.isEmpty && !largeReload.isBusy, "large-file range preferences restore without scanning")
            largeReload.maximumFileSize = "0.00001"; largeReload.startScan()
            check(largeReload.largeFileRangeError != nil && !largeReload.isBusy && largeReload.items.isEmpty, "reversed file-size ranges block scanning")
            for invalid in ["0", "-1", "nan", "99999999999999999999999999"] {
                largeReload.minimumFileSize = invalid
                check(largeReload.largeFileRangeError != nil, "invalid or overflowing file-size input is rejected")
            }
            largeReload.setLargeFilePreset("1", unit: .gb)
            check(largeReload.largeFileRangeError == nil && largeReload.maximumFileSize.isEmpty && largeReload.fileSizeUnit == .gb,
                  "large-file preset resets the optional upper limit and selects its unit")
            let sparseFixture = try fixture(root.appendingPathComponent("sparse-display"), names: [])
            let sparseURL = sparseFixture.home.appendingPathComponent("Downloads/sparse.data")
            try Data().write(to: sparseURL)
            let sparseHandle = try FileHandle(forWritingTo: sparseURL)
            try sparseHandle.truncate(atOffset: 1_048_576); try sparseHandle.close()
            guard let sparseIdentity = SpaceCleaningScanner.captureIdentity(at: sparseURL) else { throw CheckError.missing }
            let sparseMover = SpaceCleaningCheckMover(root: sparseFixture.home, trash: sparseFixture.trash); movers.append(sparseMover)
            let sparseModel = SpaceCleaningModel(dataDirectory: sparseFixture.data, homeDirectory: sparseFixture.home, mover: sparseMover); models.append(sparseModel)
            sparseModel.selectScanMode(.largeFiles); sparseModel.setLargeFilePreset("1", unit: .mb)
            sparseModel.startScan(); await sparseModel.waitUntilIdle(); sparseModel.toggleVisibleSelection()
            check(sparseModel.selectedBytes == 1_048_576 && sparseModel.selectedAllocatedBytes == sparseIdentity.allocatedBytes &&
                  sparseModel.selectedAllocatedBytes < sparseModel.selectedBytes, "sparse-file selection distinguishes logical size from disk allocation")
            sparseModel.requestCleanup(); await sparseModel.waitUntilIdle()
            check(sparseModel.currentBatch?.bytes == 1_048_576 && sparseModel.currentBatch?.successfulAllocatedBytes == sparseIdentity.allocatedBytes &&
                  sparseModel.currentBatch?.items.first?.state == .trashed, "sparse-file completion uses recorded disk allocation rather than logical length")
            let sparseReload = SpaceCleaningModel(dataDirectory: sparseFixture.data, homeDirectory: sparseFixture.home, mover: sparseMover); models.append(sparseReload)
            await sparseReload.waitUntilIdle()
            check(sparseReload.batches.first?.allocatedBytes == sparseIdentity.allocatedBytes && sparseReload.batches.first?.items.first?.bytes == 1_048_576 &&
                  sparseReload.batches.first?.items.first?.allocatedBytes == sparseIdentity.allocatedBytes, "sparse-file history preserves both size measures after reload")
            let aliasFixture = try fixture(root.appendingPathComponent("scope-alias-policy"), names: [])
            let shared = aliasFixture.home.appendingPathComponent("Downloads/library/subdirectory")
            let alias = aliasFixture.home.appendingPathComponent("Developer/Project/node_modules")
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("protected through selected alias".utf8).write(to: shared.appendingPathComponent("keep.js"))
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: aliasFixture.home.appendingPathComponent("Downloads"))
            let aliasMover = SpaceCleaningCheckMover(root: aliasFixture.home, trash: aliasFixture.trash); movers.append(aliasMover)
            let aliasModel = SpaceCleaningModel(dataDirectory: aliasFixture.data, homeDirectory: aliasFixture.home, mover: aliasMover); models.append(aliasModel)
            aliasModel.editScope(custom: true); aliasModel.addDraftDirectories([alias.appendingPathComponent("library/subdirectory")]); aliasModel.applyScope()
            aliasModel.startScan(); await aliasModel.waitUntilIdle()
            check(aliasModel.items.isEmpty && !aliasModel.coverageIssues.isEmpty, "a selected dependency-link ancestor cannot expose its physical target as cleanup files")
            let aliasReload = SpaceCleaningModel(dataDirectory: aliasFixture.data, homeDirectory: aliasFixture.home, mover: aliasMover); models.append(aliasReload)
            aliasReload.startScan(); await aliasReload.waitUntilIdle()
            check(aliasReload.scopeChoice == .custom && aliasReload.customDirectories.first?.path.contains("/node_modules/") == true &&
                  aliasReload.items.isEmpty && !aliasReload.coverageIssues.isEmpty, "saved scope bookmarks preserve the original dependency boundary after reload")
            let scopeFixture = try fixture(root.appendingPathComponent("scope-policy"), names: ["manual.data", "installer.pkg"])
            let cacheFile = scopeFixture.home.appendingPathComponent("Library/Caches/pip/http-v2/cache")
            let testFile = scopeFixture.home.appendingPathComponent("Developer/Builds/OnlyTest.app/Contents/MacOS/OnlyTest")
            for url in [cacheFile, testFile] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("owned fixture".utf8).write(to: url)
            }
            let manualFile = scopeFixture.home.appendingPathComponent("Downloads/manual.data")
            let modifiedDate = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: modifiedDate], ofItemAtPath: manualFile.path)
            let scopeMover = SpaceCleaningCheckMover(root: scopeFixture.home, trash: scopeFixture.trash); movers.append(scopeMover)
            let scopeModel = SpaceCleaningModel(dataDirectory: scopeFixture.data, homeDirectory: scopeFixture.home, mover: scopeMover); models.append(scopeModel)
            scopeModel.startScan(); await scopeModel.waitUntilIdle()
            let ids = scopeModel.items.map(\.id), defaults = scopeModel.selectedIDs
            check(defaults.count == 1 && scopeModel.selectedItems.allSatisfy { $0.group == .rebuildable } && scopeMover.moveCount == 0,
                  "complete scan defaults only verified cache into selection and never starts cleanup")
            guard let installer = scopeModel.items.first(where: { $0.kind == .installerPackage }) else { throw CheckError.missing }
            check(scopeModel.resultTab == .recommended && scopeModel.recommendedIDs == defaults.union([installer.id]) &&
                  Set(scopeModel.visibleItems.map(\.id)) == scopeModel.recommendedIDs && scopeModel.recommendedItems.count == 2 &&
                  scopeModel.automaticallySelectedIDs == defaults && !scopeModel.selectedIDs.contains(installer.id) && installer.needsSuggestionReview,
                  "recommendations include an installer for manual selection while only verified cache is preselected")
            check(scopeModel.reportSummary.contains("1 项可重建缓存已预选") && scopeModel.reportSummary.contains("1 项需手动选择"),
                  "report distinguishes cleanup suggestions from the smaller automatic selection")
            scopeModel.showResults(.reviewable)
            check(scopeModel.visibleItems.contains { $0.url == manualFile } &&
                  scopeModel.visibleItems.allSatisfy { !scopeModel.recommendedIDs.contains($0.id) } && scopeModel.selectedIDs == defaults,
                  "other-files filtering excludes recommendations and preserves the user's selection")
            scopeModel.toggleVisibleSelection()
            check(scopeModel.selectedIDs.isSuperset(of: defaults) && scopeModel.selectedCount == 2,
                  "selecting visible manual files keeps the recommended selection from the other filter")
            scopeModel.searchText = "no-matching-file"
            scopeModel.toggleSelectedFilter()
            check(scopeModel.searchText.isEmpty && scopeModel.visibleItems.count == scopeModel.selectedCount,
                  "viewing selected files clears an unrelated search and shows the entire cleanup selection")
            scopeModel.toggleSelectedFilter()
            scopeModel.toggleVisibleSelection(); scopeModel.showResults(.recommended)
            check(scopeModel.selectedIDs == defaults, "deselecting the visible manual files does not clear recommendations")
            guard let metadata = scopeModel.items.first(where: { $0.url == manualFile }) else { throw CheckError.missing }
            check(metadata.kind == .downloadedFile && !metadata.isDirectory && !metadata.typeTitle.isEmpty &&
                  abs(metadata.modifiedDate.timeIntervalSince(modifiedDate)) < 0.001 &&
                  metadata.subtitle == manualFile.deletingLastPathComponent().path,
                  "result metadata exposes the scanned modification date, file type and parent folder without repeating the file name")
            scopeModel.editScope(custom: true); scopeModel.applyScope()
            check(scopeModel.screen == .scope && scopeModel.scopeChoice == .global, "an empty custom draft cannot replace global scanning")
            let downloads = scopeFixture.home.appendingPathComponent("Downloads"), developer = scopeFixture.home.appendingPathComponent("Developer")
            scopeModel.addDraftDirectories([downloads, developer, developer.appendingPathComponent("Builds"), downloads])
            check(scopeModel.draftDirectories.count == 2, "custom directory draft deduplicates repeated and nested paths")
            scopeModel.cancelScope()
            check(scopeModel.screen == .results && scopeModel.items.map(\.id) == ids && scopeModel.selectedIDs == defaults,
                  "cancelling custom scope preserves identities, selection and results")
            scopeModel.editScope(); scopeModel.applyScope()
            check(scopeModel.screen == .results && scopeModel.selectedIDs == defaults, "saving unchanged scope preserves the review")
            guard let test = scopeModel.items.first(where: \.needsPurposeConfirmation) else { throw CheckError.missing }
            scopeModel.requestTestPurpose(test.id); scopeModel.acknowledgement = true; scopeModel.confirmTestPurpose(test.id)
            await scopeModel.waitUntilIdle()
            check(scopeModel.items.first { $0.id == test.id }?.isSelectable == true && scopeModel.selectedIDs == defaults && scopeModel.items.map(\.id) == ids,
                  "individual test declaration rechecks one package without selecting it or replacing other identities")
            scopeModel.editScope(custom: true); scopeModel.addDraftDirectories([downloads, developer]); scopeModel.applyScope()
            check(scopeModel.screen == .start && scopeModel.items.isEmpty && scopeModel.selectedIDs.isEmpty && scopeModel.scopeChoice == .custom,
                  "committing changed scope clears stale results and returns home without scanning")
            let scopeReload = SpaceCleaningModel(dataDirectory: scopeFixture.data, homeDirectory: scopeFixture.home, mover: scopeMover); models.append(scopeReload)
            await scopeReload.waitUntilIdle()
            check(scopeReload.scopeChoice == .custom && scopeReload.customDirectories.count == 2,
                  "security-scoped custom directory bookmarks survive a model restart")
            scopeReload.startScan(); await scopeReload.waitUntilIdle()
            check(scopeReload.items.count == 3 && scopeReload.selectedIDs.isEmpty && scopeMover.moveCount == 0 &&
                  scopeReload.recommendedItems.count == 1 && scopeReload.recommendedItems.first?.kind == .installerPackage,
                  "restored custom scope scans both folders without including global cache locations")
            scopeReload.selectScope(.global)
            check(scopeReload.screen == .start && scopeReload.scopeChoice == .global && scopeReload.customDirectories.count == 2,
                  "switching back to global keeps remembered custom folders available")

            let installerFixture = try fixture(root.appendingPathComponent("installer-only"), names: ["download.dmg"])
            let installerMover = SpaceCleaningCheckMover(root: installerFixture.home, trash: installerFixture.trash); movers.append(installerMover)
            let installerModel = SpaceCleaningModel(dataDirectory: installerFixture.data, homeDirectory: installerFixture.home, mover: installerMover); models.append(installerModel)
            installerModel.startScan(); await installerModel.waitUntilIdle()
            check(installerModel.recommendedItems.count == 1 && installerModel.otherItems.isEmpty && installerModel.selectedIDs.isEmpty &&
                  installerModel.automaticallySelectedIDs.isEmpty && installerModel.reportSummary.contains("手动选择"),
                  "an installer-only scan presents a useful suggestion without claiming automatic selection or completed installation")
            installerModel.requestCleanup()
            check(installerMover.moveCount == 0 && !installerModel.isBusy, "an unselected installation image is never processed")
            installerModel.toggleVisibleSelection(); installerModel.requestCleanup(); await installerModel.waitUntilIdle()
            check(try installerMover.moveCount == 1 && read(installerFixture.data).first?.state == .trashed,
                  "a manually selected installation image follows the same verified recoverable transaction")

            let sortingFixture = try fixture(root.appendingPathComponent("sorting"), names: [])
            let aFolder = sortingFixture.home.appendingPathComponent("A"), zFolder = sortingFixture.home.appendingPathComponent("Z")
            for directory in [aFolder, zFolder] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            let sortingFiles: [(URL, Int, TimeInterval)] = [
                (aFolder.appendingPathComponent("alpha.txt"), 30, 3_000),
                (aFolder.appendingPathComponent("same.data"), 20, 2_000),
                (zFolder.appendingPathComponent("beta.data"), 40, 4_000),
                (zFolder.appendingPathComponent("same.data"), 20, 2_000)
            ]
            for (url, size, date) in sortingFiles {
                try Data(repeating: 0x41, count: size).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: url.path)
            }
            let sortingMover = SpaceCleaningCheckMover(root: sortingFixture.home, trash: sortingFixture.trash); movers.append(sortingMover)
            let sortingModel = SpaceCleaningModel(dataDirectory: sortingFixture.data, homeDirectory: sortingFixture.home, mover: sortingMover); models.append(sortingModel)
            sortingModel.editScope(custom: true); sortingModel.addDraftDirectories([aFolder, zFolder]); sortingModel.applyScope()
            sortingModel.startScan(); await sortingModel.waitUntilIdle(); sortingModel.showResults(.reviewable)
            guard let selectedSortItem = sortingModel.items.first(where: { $0.url == zFolder.appendingPathComponent("same.data") }) else { throw CheckError.missing }
            sortingModel.toggleItem(selectedSortItem.id)
            let sortingIDs = Set(sortingModel.items.map(\.id)), sortingSelection = sortingModel.selectedIDs
            check(sortingIDs.count == 4 && sortingModel.sortKey == .size && !sortingModel.sortAscending,
                  "fresh results use descending file size without changing the candidate identities")
            func sortingPaths() -> [String] {
                sortingModel.visibleItems.map { $0.url.path.replacingOccurrences(of: sortingFixture.home.path + "/", with: "") }
            }
            let sortingExpectations: [(CleaningSortKey, [String], [String])] = [
                (.name, ["A/alpha.txt", "Z/beta.data", "A/same.data", "Z/same.data"], ["A/same.data", "Z/same.data", "Z/beta.data", "A/alpha.txt"]),
                (.directory, ["A/alpha.txt", "A/same.data", "Z/beta.data", "Z/same.data"], ["Z/beta.data", "Z/same.data", "A/alpha.txt", "A/same.data"]),
                (.type, ["A/same.data", "Z/beta.data", "Z/same.data", "A/alpha.txt"], ["A/alpha.txt", "A/same.data", "Z/beta.data", "Z/same.data"]),
                (.modified, ["A/same.data", "Z/same.data", "A/alpha.txt", "Z/beta.data"], ["Z/beta.data", "A/alpha.txt", "A/same.data", "Z/same.data"]),
                (.size, ["A/same.data", "Z/same.data", "A/alpha.txt", "Z/beta.data"], ["Z/beta.data", "A/alpha.txt", "A/same.data", "Z/same.data"])
            ]
            for (key, ascending, descending) in sortingExpectations {
                sortingModel.sortResults(by: key)
                check(sortingModel.sortKey == key && sortingModel.sortAscending == ![CleaningSortKey.modified, .size].contains(key),
                      "choosing \(key.rawValue) uses its expected initial sort direction")
                if !sortingModel.sortAscending { sortingModel.sortResults(by: key) }
                check(sortingPaths() == ascending, "\(key.rawValue) ascending follows scanned metadata with stable equal-key paths")
                sortingModel.sortResults(by: key)
                check(!sortingModel.sortAscending && sortingPaths() == descending,
                      "clicking \(key.rawValue) again reverses its primary order without shuffling equal-key files")
            }
            sortingModel.searchText = "alpha"
            check(sortingPaths() == ["A/alpha.txt"] && sortingModel.selectedIDs == sortingSelection,
                  "search filters sorted results while preserving selection of a hidden file")
            sortingModel.toggleSelectedFilter()
            check(sortingModel.visibleItems.map(\.id) == [selectedSortItem.id] && sortingModel.searchText.isEmpty && sortingModel.sortKey == .size,
                  "viewing selected items preserves sorting and clears an unrelated search")
            sortingModel.showResults(.protected)
            check(sortingModel.visibleItems.isEmpty && sortingModel.selectedIDs == sortingSelection,
                  "changing result tabs never clears a selected file from another category")
            sortingModel.showResults(.reviewable)
            check(sortingPaths() == sortingExpectations.last!.2 && Set(sortingModel.items.map(\.id)) == sortingIDs && sortingMover.moveCount == 0,
                  "sorting and filtering are presentation-only and retain all original candidates without processing files")

            let preferenceFixture = try fixture(root.appendingPathComponent("method-preference"), names: [])
            let preferenceMover = SpaceCleaningCheckMover(root: preferenceFixture.home, trash: preferenceFixture.trash); movers.append(preferenceMover)
            let preferenceModel = SpaceCleaningModel(dataDirectory: preferenceFixture.data, homeDirectory: preferenceFixture.home, mover: preferenceMover); models.append(preferenceModel)
            preferenceModel.chooseMethod(.permanent); preferenceModel.setRememberMethod(true)
            let preferenceReload = SpaceCleaningModel(dataDirectory: preferenceFixture.data, homeDirectory: preferenceFixture.home, mover: preferenceMover); models.append(preferenceReload)
            check(preferenceReload.method == .permanent && preferenceReload.rememberMethod && !preferenceReload.acknowledgement && preferenceMover.moveCount == 0,
                  "the standalone remember checkbox saves immediately without requiring any cleanup or consenting to deletion")
            preferenceModel.chooseMethod(.trash)
            let trashPreferenceReload = SpaceCleaningModel(dataDirectory: preferenceFixture.data, homeDirectory: preferenceFixture.home, mover: preferenceMover); models.append(trashPreferenceReload)
            check(trashPreferenceReload.method == .trash && trashPreferenceReload.rememberMethod,
                  "changing a remembered method updates the next-session preference immediately")
            preferenceModel.chooseMethod(.permanent); preferenceModel.setRememberMethod(false)
            let forgottenPreference = SpaceCleaningModel(dataDirectory: preferenceFixture.data, homeDirectory: preferenceFixture.home, mover: preferenceMover); models.append(forgottenPreference)
            check(preferenceModel.method == .permanent && !preferenceModel.rememberMethod && forgottenPreference.method == .trash && !forgottenPreference.rememberMethod,
                  "unchecking remember keeps the current method but restores Trash as the next-session default")

            let first = try fixture(root.appendingPathComponent("restore"), names: ["first.data", "second.data"])
            let mover = SpaceCleaningCheckMover(root: first.home, trash: first.trash); movers.append(mover)
            let model = SpaceCleaningModel(dataDirectory: first.data, homeDirectory: first.home, mover: mover); models.append(model)
            check(model.scopeChoice == .global && model.screen == .start && model.method == .trash,
                  "space cleaning opens with default Mac scope and recoverable Trash method")
            model.startScan(); await model.waitUntilIdle()
            check(model.screen == .results && model.items.count == 2 && model.selectedIDs.isEmpty && mover.moveCount == 0,
                  "default production scan finds fixture downloads without selecting or moving any file")
            let detailItem = model.items[0]
            model.showDetail(detailItem.id); model.showDetail(detailItem.id)
            check(model.detailID == detailItem.id && model.selectedIDs.isEmpty,
                  "reselecting a detail keeps its sidebar open without selecting a cleanup target")
            model.closeDetail()
            check(model.detailID == nil && model.selectedIDs.isEmpty,
                  "collapsing details preserves the independent cleanup selection")
            check(model.scanRecordedCandidates > 0 && model.scanTotalScopes > 0 && model.scanRecentPaths.count <= 4,
                  "scan presentation retains real candidate and scope counts with a bounded recent-path list")
            check(model.recommendedItems.isEmpty && model.recommendedIDs.isEmpty &&
                  !model.reportSummary.contains("已默认选中"),
                  "a scan containing only personal files does not claim that recommendations were automatically selected")
            model.executeConfirmed(permanent: false, remember: false)
            model.requestCleanup()
            check(mover.moveCount == 0 && !model.isBusy, "cleanup remains inert without any selected file")
            model.items.forEach { model.toggleItem($0.id) }; model.requestCleanup()
            check(model.dialog == nil && model.screen == .processing && model.isBusy,
                  "the cleanup action starts the selected Trash transaction directly without a second review screen")
            await model.waitUntilIdle()
            let trashed = try read(first.data)
            check(trashed.count == 2 && trashed.allSatisfy { $0.state == .trashed && $0.canRestore } && mover.moveCount == 2,
                  "verified production moves persist exactly one recoverable receipt per selected item")
            check(model.batches.first?.items.allSatisfy { $0.isDirectory == false && $0.bytes > 0 && $0.originalURL.path.hasPrefix(first.home.path) } == true,
                  "history presentation retains each recorded file's identity, original path and size")
            check(model.screen == .completed && model.requiresRescan && model.selectedIDs.isEmpty && model.currentBatch?.items.count == 2,
                  "processing enters a dedicated completion state with actual receipts and consumes the stale scan selection")
            model.goHome()
            check(model.screen == .start && model.batches.count == 1 && model.currentBatch?.items.count == 2 && model.selectedIDs.isEmpty,
                  "explicit return home preserves cleanup history without restarting a scan or restoring stale selection")
            guard let batch = model.batches.first, let conflicted = trashed.first else { throw CheckError.missing }
            try Data("new occupant".utf8).write(to: conflicted.originalURL)
            model.requestRestore(batch.id); model.executeRestore(batchID: batch.id, renameConflicts: false); await model.waitUntilIdle()
            let afterSkip = try read(first.data)
            check(afterSkip.filter { $0.state == .restored }.count == 1 && afterSkip.filter { $0.state == .trashed }.count == 1,
                  "batch restore skips a name conflict while restoring other verified items")
            check(try String(contentsOf: conflicted.originalURL, encoding: .utf8) == "new occupant",
                  "conflict skipping never overwrites the current file")
            model.requestRestoreItem(conflicted.id)
            check(model.pendingHistoryItems.map(\.id) == [conflicted.id], "history supports selecting a single receipt for restoration")
            model.executeRestore(batchID: batch.id, renameConflicts: true); await model.waitUntilIdle()
            guard let renamed = try read(first.data).first(where: { $0.id == conflicted.id }), let destination = renamed.restoredURL else { throw CheckError.missing }
            check(renamed.state == .restored && destination != conflicted.originalURL && destination.pathExtension == "data",
                  "single-item restore uses an available name while preserving the file extension")
            check(try String(contentsOf: destination, encoding: .utf8) == "payload-" + conflicted.candidate.title &&
                  String(contentsOf: conflicted.originalURL, encoding: .utf8) == "new occupant",
                  "renamed restoration preserves both the original selected content and the new occupant")
            let oldIDs = model.items.map(\.id); oldIDs.forEach { model.toggleItem($0) }; model.requestCleanup()
            check(model.selectedIDs.isEmpty && model.dialog == nil && model.requiresRescan,
                  "restored files cannot be processed again using stale candidate identities")
            let reloaded = SpaceCleaningModel(dataDirectory: first.data, homeDirectory: first.home, mover: mover); models.append(reloaded)
            await reloaded.waitUntilIdle()
            check(reloaded.batches.count == 1 && reloaded.batches.first?.restorableCount == 0 && mover.moveCount == 2,
                  "history reload preserves restored outcomes without repeating any move")

            let permanent = try fixture(root.appendingPathComponent("permanent"), names: ["remove.data"])
            let permanentMover = SpaceCleaningCheckMover(root: permanent.home, trash: permanent.trash); movers.append(permanentMover)
            let permanentModel = SpaceCleaningModel(dataDirectory: permanent.data, homeDirectory: permanent.home, mover: permanentMover); models.append(permanentModel)
            permanentModel.startScan(); await permanentModel.waitUntilIdle()
            guard let permanentItem = permanentModel.items.first else { throw CheckError.missing }
            permanentModel.toggleItem(permanentItem.id); permanentModel.method = .permanent
            permanentModel.rememberMethod = true; permanentModel.requestCleanup()
            check(permanentModel.dialog == .confirm && !permanentModel.isBusy && !permanentModel.acknowledgement,
                  "the permanent cleanup action still opens an explicit irreversible confirmation")
            permanentModel.executeConfirmed(permanent: true, remember: true)
            check(!permanentModel.isBusy && FileManager.default.fileExists(atPath: permanentItem.url.path),
                  "choosing permanent deletion or remember preference never bypasses the irreversible-action acknowledgement")
            permanentModel.acknowledgement = true; permanentModel.executeConfirmed(permanent: true, remember: true); await permanentModel.waitUntilIdle()
            let permanentRecords = try read(permanent.data)
            check(permanentModel.screen == .completed && permanentModel.currentBatch?.restorableCount == 0,
                  "permanent deletion also presents completion without offering recoverable receipts")
            check(permanentRecords.count == 1 && permanentRecords.first?.state == .deleted && permanentMover.moveCount == 0,
                  "confirmed permanent deletion uses its own verified path and creates no recoverable Trash receipt")
            let remembered = SpaceCleaningModel(dataDirectory: permanent.data, homeDirectory: permanent.home, mover: permanentMover); models.append(remembered)
            await remembered.waitUntilIdle()
            check(remembered.method == .permanent && remembered.rememberMethod && !remembered.acknowledgement && remembered.dialog == nil,
                  "remembered method survives restart while confirmation and acknowledgement remain required")

            try Data("new removable fixture".utf8).write(to: permanentItem.url)
            remembered.startScan(); await remembered.waitUntilIdle()
            if let item = remembered.items.first {
                remembered.toggleItem(item.id); remembered.method = .trash; remembered.rememberMethod = false
                remembered.requestCleanup(); await remembered.waitUntilIdle()
            }
            let clearedPreference = SpaceCleaningModel(dataDirectory: permanent.data, homeDirectory: permanent.home, mover: permanentMover)
            models.append(clearedPreference); await clearedPreference.waitUntilIdle()
            check(clearedPreference.method == .trash && !clearedPreference.rememberMethod,
                  "unchecking remember removes the prior permanent preference and restores the default Trash choice")

            let purgeFixture = try fixture(root.appendingPathComponent("purge"), names: ["batch-one.data"])
            let purgeMover = SpaceCleaningCheckMover(root: purgeFixture.home, trash: purgeFixture.trash); movers.append(purgeMover)
            let purgeModel = SpaceCleaningModel(dataDirectory: purgeFixture.data, homeDirectory: purgeFixture.home, mover: purgeMover); models.append(purgeModel)
            try await scanAndTrash(purgeModel)
            guard let firstBatchID = purgeModel.batches.first?.id else { throw CheckError.missing }
            try Data("second batch".utf8).write(to: purgeFixture.home.appendingPathComponent("Downloads/batch-two.data"))
            try await scanAndTrash(purgeModel)
            let unrelated = purgeFixture.trash.appendingPathComponent("unrelated.data")
            try Data("keep".utf8).write(to: unrelated)
            purgeModel.requestPurge(firstBatchID); purgeModel.executePurge(batchID: firstBatchID)
            check(try !purgeModel.isBusy && read(purgeFixture.data).allSatisfy { $0.state == .trashed },
                  "batch purge requires its own explicit irreversible-action acknowledgement")
            purgeModel.acknowledgement = true; purgeModel.executePurge(batchID: firstBatchID); await purgeModel.waitUntilIdle()
            let purged = try read(purgeFixture.data)
            check(purged.filter { $0.operationID == firstBatchID }.allSatisfy { $0.state == .deleted } &&
                  purged.filter { $0.operationID != firstBatchID }.allSatisfy { $0.state == .trashed },
                  "permanent purge affects only receipts belonging to the selected batch")
            check(try String(contentsOf: unrelated, encoding: .utf8) == "keep", "batch purge leaves unrelated Trash content untouched")

            let corrupt = try fixture(root.appendingPathComponent("corrupt"), names: ["keep.data"])
            try FileManager.default.createDirectory(at: corrupt.data, withIntermediateDirectories: true)
            let corruptURL = corrupt.data.appendingPathComponent("history.json"), invalid = Data("invalid-history".utf8)
            try invalid.write(to: corruptURL)
            let corruptMover = SpaceCleaningCheckMover(root: corrupt.home, trash: corrupt.trash); movers.append(corruptMover)
            let corruptModel = SpaceCleaningModel(dataDirectory: corrupt.data, homeDirectory: corrupt.home, mover: corruptMover); models.append(corruptModel)
            corruptModel.startScan(); await corruptModel.waitUntilIdle()
            corruptModel.items.forEach { corruptModel.toggleItem($0.id) }; corruptModel.requestCleanup()
            check(corruptModel.items.count == 1 && !corruptModel.canProcess && corruptModel.dialog == nil && corruptMover.moveCount == 0,
                  "invalid history keeps scanning available but blocks destructive operations")
            check(try Data(contentsOf: corruptURL) == invalid, "invalid history is retained verbatim instead of silently replaced")

            let recovering = try fixture(root.appendingPathComponent("recover"), names: ["recover.data"])
            let recoveringMover = SpaceCleaningCheckMover(root: recovering.home, trash: recovering.trash); movers.append(recoveringMover)
            let recoveringModel = SpaceCleaningModel(dataDirectory: recovering.data, homeDirectory: recovering.home, mover: recoveringMover); models.append(recoveringModel)
            recoveringModel.startScan(); await recoveringModel.waitUntilIdle()
            try FileManager.default.createDirectory(at: recovering.data, withIntermediateDirectories: true)
            chmod(recovering.data.path, 0o500)
            recoveringModel.items.forEach { recoveringModel.toggleItem($0.id) }; recoveringModel.method = .trash
            recoveringModel.requestCleanup(); await recoveringModel.waitUntilIdle()
            let pausedAfterFailedWrite = !recoveringModel.canProcess && recoveringMover.moveCount == 0 &&
                FileManager.default.fileExists(atPath: recovering.home.appendingPathComponent("Downloads/recover.data").path)
            chmod(recovering.data.path, 0o700)
            recoveringModel.startScan(); await recoveringModel.waitUntilIdle()
            if recoveringModel.items.isEmpty { recoveringModel.startScan(); await recoveringModel.waitUntilIdle() }
            recoveringModel.items.forEach { recoveringModel.toggleItem($0.id) }
            check(pausedAfterFailedWrite && recoveringModel.canProcess,
                  "a failed history write pauses processing, and the next scan reopens the history without a restart")

            let quitFixture = try fixture(root.appendingPathComponent("quit"), names: ["first.data", "second.data"])
            let gated = SpaceCleaningCheckMover(root: quitFixture.home, trash: quitFixture.trash, gateFirst: true); movers.append(gated)
            let quitModel = SpaceCleaningModel(dataDirectory: quitFixture.data, homeDirectory: quitFixture.home, mover: gated); models.append(quitModel)
            quitModel.startScan(); await quitModel.waitUntilIdle()
            quitModel.items.forEach { quitModel.toggleItem($0.id) }; quitModel.requestCleanup()
            let entered = await wait { gated.entered }
            var returned = false
            let quitting = Task { await quitModel.prepareForQuit(); returned = true }
            try? await Task.sleep(for: .milliseconds(30))
            check(entered && !returned && quitModel.isBusy && gated.moveCount == 1,
                  "quit waits for the current transaction and its durable result before returning")
            gated.release(); await quitting.value
            let quitRecords = try read(quitFixture.data)
            check(returned && !quitModel.isBusy && gated.moveCount == 1 && quitRecords.count == 1 && quitRecords.first?.state == .trashed,
                  "quit completes the current verified Trash move and does not start the next selected item")
            let remaining = try FileManager.default.contentsOfDirectory(at: quitFixture.home.appendingPathComponent("Downloads"), includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
            check(remaining.count == 1 && !gated.timedOut, "the unstarted item remains intact after cancellation during a move")
        } catch {
            check(false, "space cleaning model check setup or execution: \(error.localizedDescription)")
        }
        for model in models { await model.prepareForQuit() }
        let groups = await runScopeGroups()
        return (count + groups.count, failures + groups.failures)
    }

    /// Opt-in, separate from the routine fixture suite. Creates exactly two own
    /// temporary objects and moves them via the real OS Trash adapter, then
    /// restores them. It never enumerates or empties the system Trash. If macOS
    /// denies verification/restoration, retain the journal and report it.
    static func runSystemTrash() async -> (count: Int, failures: Int) {
        await Task.detached(priority: .utility) {
            var count = 0, failures = 0, retainEvidence = false
            func check(_ condition: Bool, _ label: String) {
                count += 1; if !condition { failures += 1 }
                print("\(condition ? "PASS" : "FAIL") \(label)")
            }
            let rawRoot = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-cleaning-system-trash-" + UUID().uuidString)
            defer {
                if retainEvidence { print("System Trash check evidence retained at \(rawRoot.path)") }
                else { try? FileManager.default.removeItem(at: rawRoot) }
            }
            do {
                try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
                guard let root = SpaceCleaningScanner.canonicalURL(rawRoot) else { throw CheckError.missing }
                let source = root.appendingPathComponent("selected")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                let file = source.appendingPathComponent("DeskDen-owned-check-" + UUID().uuidString + ".data")
                let app = source.appendingPathComponent("DeskDen-owned-check-" + UUID().uuidString + ".app")
                try Data("owned-system-trash-file".utf8).write(to: file)
                try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
                try Data("owned-system-trash-package".utf8).write(to: app.appendingPathComponent("Contents/Resources/check.data"))
                let scope = SpaceCleaningScope(directory: source)
                var context = SpaceCleaningContext(homeDirectory: root)
                let unknown = SpaceCleaningScanner.scan(scopes: [scope], context: context)
                guard let package = unknown.candidates.first(where: { $0.url.path == app.path }) else { throw CheckError.missing }
                context.testDeclarations = [.init(candidate: package)]
                let report = SpaceCleaningScanner.scan(scopes: [scope], context: context)
                let history = try SpaceCleaningHistoryStore(fileURL: root.appendingPathComponent("state/history.json"))
                for candidate in report.candidates {
                    let moved = SpaceCleaningTransaction.execute(candidate: candidate, operationID: UUID(), method: .trash,
                        mover: SpaceCleaningAppFileOperations(), validatePolicy: {
                            SpaceCleaningScanner.revalidate(candidate: $0, context: context) == .unchanged ? nil : "Fixture identity changed"
                        }, persist: history.record)
                    check(moved.state == .trashed, "system Trash move verifies complete \(candidate.isDirectory ? "package" : "file") using the held content lease: \(moved.explanation)")
                    guard moved.canRestore else {
                        if !FileManager.default.fileExists(atPath: candidate.url.path) { retainEvidence = true }
                        continue
                    }
                    retainEvidence = true
                    let restored = SpaceCleaningTransaction.restore(record: moved, conflict: .skip, persist: history.record)
                    check(restored.state == .restored, "system Trash restores owned \(candidate.isDirectory ? "package" : "file") without overwrite: \(restored.explanation)")
                    if restored.state == .restored { retainEvidence = history.records.contains { $0.state == .trashed || $0.state == .needsReview } }
                }
                check(history.records.count == 2 && history.records.allSatisfy { $0.state == .restored },
                      "both owned system Trash fixtures have durable restored receipts; no unrelated Trash operation")
                retainEvidence = retainEvidence || history.records.contains { $0.state == .trashed || $0.state == .needsReview }
            } catch { check(false, "system Trash fixture check: \(error.localizedDescription)"); retainEvidence = true }
            return (count, failures)
        }.value
    }

    private enum CheckError: Error { case missing }
    private struct Fixture { var home: URL; var data: URL; var trash: URL }
    private static func fixture(_ home: URL, names: [String]) throws -> Fixture {
        let downloads = home.appendingPathComponent("Downloads"), trash = home.appendingPathComponent("fake-trash")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        for name in names { try Data(("payload-" + name).utf8).write(to: downloads.appendingPathComponent(name)) }
        return .init(home: home, data: home.appendingPathComponent("state"), trash: trash)
    }
    private static func read(_ directory: URL) throws -> [SpaceCleaningRecord] {
        try SpaceCleaningHistoryStore(fileURL: directory.appendingPathComponent("history.json")).records
    }
    private static func scanAndTrash(_ model: SpaceCleaningModel) async throws {
        model.startScan(); await model.waitUntilIdle()
        guard !model.items.isEmpty else { throw CheckError.missing }
        model.items.forEach { model.toggleItem($0.id) }; model.method = .trash
        model.requestCleanup(); await model.waitUntilIdle()
    }
    private static func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<300 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return predicate()
    }
}

private final class SpaceCleaningCheckMover: SpaceCleaningFileOperating, @unchecked Sendable {
    private let root: URL
    private let trash: URL
    private let gateFirst: Bool
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private var reached = false
    private var expired = false
    init(root: URL, trash: URL, gateFirst: Bool = false) { self.root = root; self.trash = trash; self.gateFirst = gateFirst }
    var moveCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return reached }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    func release() { gate.signal() }
    func moveToTrash(_ source: URL) throws -> URL {
        guard source.path.hasPrefix(root.path + "/"), trash.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
        lock.lock(); calls += 1; let shouldWait = gateFirst && calls == 1; if shouldWait { reached = true }; lock.unlock()
        if shouldWait, gate.wait(timeout: .now() + 10) == .timedOut {
            lock.lock(); expired = true; lock.unlock(); throw CocoaError(.fileWriteUnknown)
        }
        let destination = trash.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }
}
