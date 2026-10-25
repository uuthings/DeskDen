import Foundation
import LauncherCore

/// Exercises the production model, scanner, transaction, persistence and quit
/// barrier. All source objects, history and the injected Trash are temporary
/// fixtures; this never invokes the system Trash or scans the user's home.
@MainActor enum SpaceCleaningModelChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let rawRoot = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-cleaning-model-" + UUID().uuidString)
        var movers: [SpaceCleaningCheckMover] = []
        var models: [SpaceCleaningModel] = []
        defer { movers.forEach { $0.release() }; try? FileManager.default.removeItem(at: rawRoot) }
        do {
            try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
            guard let root = SpaceCleaningScanner.canonicalURL(rawRoot) else { throw CheckError.missing }
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
        return (count, failures)
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
            let rawRoot = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-cleaning-system-trash-" + UUID().uuidString)
            defer {
                if retainEvidence { print("System Trash check evidence retained at \(rawRoot.path)") }
                else { try? FileManager.default.removeItem(at: rawRoot) }
            }
            do {
                try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
                guard let root = SpaceCleaningScanner.canonicalURL(rawRoot) else { throw CheckError.missing }
                let source = root.appendingPathComponent("selected")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                let file = source.appendingPathComponent("Fangcun-owned-check-" + UUID().uuidString + ".data")
                let app = source.appendingPathComponent("Fangcun-owned-check-" + UUID().uuidString + ".app")
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
