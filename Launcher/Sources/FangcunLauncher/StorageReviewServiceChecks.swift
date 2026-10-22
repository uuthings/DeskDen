import Foundation
import LauncherCore

/// Uses the production scanner, service, write-ahead journal, receipt loading,
/// restore and quit barrier. The injected mover is confined to this check's
/// temporary directory; it never calls AppKit Trash or accesses personal files.
@MainActor enum StorageReviewServiceChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-storage-service-\(UUID().uuidString)").resolvingSymlinksInPath()
        var movers: [StorageCheckMover] = []
        var services: [StorageReviewService] = []
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let fixture = try makeFixture(root.appendingPathComponent("quit"), names: ["a.cache", "b.cache"])
            let mover = StorageCheckMover(root: fixture.root, trash: fixture.trash, gateFirst: true)
            movers.append(mover)
            let service = StorageReviewService(dataDirectory: fixture.data, mover: mover); services.append(service)
            check(try service.registerScope(.init(directory: fixture.source, kind: .rebuildableCache)),
                  "storage service accepts an explicitly selected isolated directory through production scope validation")
            check(try !service.registerScope(.init(directory: fixture.source, kind: .rebuildableCache)) && service.scopes.count == 1,
                  "scope registration rejects canonical duplicates without duplicating scans")
            for url in [URL(string: "https://example.com")!, URL(fileURLWithPath: "/"), fixture.source.appendingPathComponent("missing"), fixture.source.appendingPathComponent("a.cache")] {
                let previousCount = service.scopes.count
                var rejected = false
                do { _ = try service.registerScope(.init(directory: url, kind: .rebuildableCache)) } catch { rejected = true }
                check(rejected && service.scopes.count == previousCount,
                      "scope registration rejects nonlocal, root, missing or regular-file input without inspecting contents")
            }
            service.scan(kinds: [.rebuildableCache])
            let scanned = await wait { !service.isScanning && service.report?.stage == .report }
            check(scanned && service.report?.candidates.count == 2 && mover.moveCount == 0,
                  "real isolated scan produces two candidates and never starts a move")
            guard let report = service.report else { throw StorageServiceCheckError.missingReport }
            guard var alteredCandidate=report.candidates.first else {throw StorageServiceCheckError.missingReport}
            alteredCandidate.explanation += " altered fixture copy"
            check(report.candidates.allSatisfy{service.canSelect($0) && service.candidateStatus(for:$0) == .pendingReview} &&
                  !service.canSelect(alteredCandidate) && service.candidateStatus(for:alteredCandidate) == .unavailable,
                  "selection accepts only exact current scan candidates, never an altered copy sharing the same candidate UUID")
            service.executeConfirmedPlan()
            check(!service.isProcessing && mover.moveCount == 0,
                  "calling execute without selection and distinct confirmation does nothing")
            service.selectAll(report.candidates); service.prepareProcessing()
            check(service.confirmingPlan?.selectedCandidateIDs.count == 2 && service.selectedBytes == report.candidates.reduce(0, { $0 + $1.logicalBytes }),
                  "real selected-file plan keeps the actual candidate count and logical byte total")
            guard let originalPlan=service.confirmingPlan else {throw StorageServiceCheckError.missingReport}
            service.executeConfirmedPlan()
            let entered = await wait { mover.enteredFirst }
            check(entered && service.isProcessing && service.processedCount == 0 && service.receipts.isEmpty,
                  "controlled mover holds the current real transaction before any success receipt exists")
            let activeIntents = try readIntents(fixture.data)
            check(activeIntents.count == 1 && activeIntents.first?.stage == .prepared,
                  "write-ahead intent is durably readable before the controlled OS-move boundary")
            var quitStarted = false, quitReturned = false
            let quit = Task { quitStarted = true; await service.stopForQuit(); quitReturned = true }
            let beganQuit = await wait { quitStarted }
            await settle()
            check(beganQuit && !quitReturned && service.isProcessing && mover.moveCount == 1,
                  "stopForQuit cannot return while the current move and its receipt are unfinished")
            check(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("a.cache").path) && FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("b.cache").path),
                  "gated quit has not prematurely hidden or removed either selected file")
            mover.release(); await quit.value
            check(quitReturned && !service.isProcessing && service.processedCount == 1 && service.plannedCount == 2 && mover.moveCount == 1 && !mover.timedOut,
                  "quit waits for the current transaction to finish and never begins the next selected item")
            guard let receipt = service.receipts.first else { throw StorageServiceCheckError.missingReceipt }
            check(service.receipts.count == 1 && receipt.result.state == .trashed && receipt.trashIdentity != nil && receipt.requiresManualReview != true,
                  "only the verified actual moved item gets a successful receipt and restoration identity")
            check(!FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("a.cache").path) && FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("b.cache").path),
                  "completed first item and untouched second item match the reported partial operation")
            check(try readReceipts(fixture.data) == service.receipts && readIntents(fixture.data).isEmpty,
                  "quit returns only after final receipt is readable and its resolved write-ahead intent is cleared")
            check(service.message?.contains("取消") == true && service.selectedIDs.count == 1,
                  "unstarted item stays selected and the result explicitly describes cancellation")
            service.toggle(receipt.candidate);service.selectAll([receipt.candidate])
            check(service.candidateStatus(for:receipt.candidate) == .movedToTrash &&
                  service.candidateStatus(for:receipt.candidate).label == "已移到废纸篓" && !service.canSelect(receipt.candidate) &&
                  !service.selectedIDs.contains(receipt.candidate.id) && service.selectedCandidateCount == 1,
                  "a successful receipt consumes its old candidate while toggle and select-all retain only the unattempted selection")
            service.selectedIDs=Set(report.candidates.map(\.id));service.prepareProcessing()
            check(service.confirmingPlan == nil && !service.selectedIDs.contains(receipt.candidate.id) &&
                  service.selectedCandidateCount == 1 && mover.moveCount == 1 && !service.isProcessing,
                  "a forged mixed selection is rejected as a whole and cleans consumed IDs without silently processing the remaining valid file")
            service.confirmingPlan=originalPlan;service.executeConfirmedPlan()
            check(service.confirmingPlan == nil && !service.isProcessing && service.receipts.count == 1 && mover.moveCount == 1,
                  "replaying a previously confirmed plan cannot move its already receipted candidate or the remaining file a second time")

            let reload = StorageReviewService(dataDirectory: fixture.data, mover: mover); services.append(reload)
            check(reload.receipts == service.receipts && mover.moveCount == 1,
                  "restarting the real service reads final receipts without repeating any move")
            reload.confirmingRestore = receipt.id; reload.restoreConfirmedItem()
            let reloadedRestoreFinished=await wait{!reload.isProcessing}
            check(reloadedRestoreFinished && reload.receipts.first?.restoredAt != nil && reload.receipts.first?.restoreStartedAt == nil && mover.restoreCount == 1,
                  "restoration through the restarted service verifies and records the actual move back")
            check(try Data(contentsOf: fixture.source.appendingPathComponent("a.cache")) == payload("a.cache") && receipt.result.trashURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true,
                  "restored fixture content and empty recorded trash slot agree with the restoration receipt")
            let restoredReload = StorageReviewService(dataDirectory: fixture.data, mover: mover); services.append(restoredReload)
            check(try restoredReload.receipts.first?.restoredAt != nil && mover.restoreCount == 1 && readReceipts(fixture.data).first?.restoredAt != nil,
                  "restored history survives another restart without repeating restoration")

            let partialFixture = try makeFixture(root.appendingPathComponent("partial"), names: ["a.cache", "b-failed.cache", "c.cache"])
            let partialMover = StorageCheckMover(root: partialFixture.root, trash: partialFixture.trash, failedNames: ["b-failed.cache"])
            movers.append(partialMover)
            let partial = StorageReviewService(dataDirectory: partialFixture.data, mover: partialMover); services.append(partial)
            try await scanAndConfirm(partial, source: partialFixture.source)
            guard let partialReport=partial.report,let partialPlan=partial.confirmingPlan else {throw StorageServiceCheckError.missingReport}
            partial.executeConfirmedPlan()
            let partialDone = await wait { !partial.isProcessing && partial.receipts.count == 3 }
            check(partialDone && partial.processedCount == 3 && partialMover.moveCount == 3,
                  "partial failure retains one outcome per attempted selected item")
            let successes = partial.receipts.filter { $0.result.state == .trashed }, failures = partial.receipts.filter { $0.result.state == .failed }
            check(successes.count == 2 && failures.count == 1 && failures.first?.candidate.relativePath == "b-failed.cache" && failures.first?.trashIdentity == nil && failures.first?.result.trashURL == nil,
                  "real service reports failure separately and never assigns its item success or restoration authority")
            check(successes.reduce(0, { $0 + $1.candidate.logicalBytes }) == UInt64(payload("a.cache").count + payload("c.cache").count),
                  "successful logical-byte accounting excludes the failed item's bytes and does not claim freed disk capacity")
            check(try Data(contentsOf: partialFixture.source.appendingPathComponent("b-failed.cache")) == payload("b-failed.cache") && readIntents(partialFixture.data).isEmpty,
                  "failed original remains intact and resolved partial-operation intents are durably cleared")
            guard let failedCandidate=failures.first?.candidate,let movedCandidate=successes.first?.candidate else {throw StorageServiceCheckError.missingReceipt}
            check(partial.candidateStatus(for:failedCandidate) == .attemptedNeedsRescan &&
                  partial.candidateStatus(for:failedCandidate).label == "需重新检查" &&
                  partial.candidateStatus(for:failedCandidate).explanation.contains("不代表处理成功") &&
                  partial.candidateStatus(for:movedCandidate) == .movedToTrash &&
                  !partial.canSelect(failedCandidate) && !partial.canSelect(movedCandidate),
                  "failed and successful receipts both consume old review identities while their labels retain the distinct truthful outcomes")
            partial.toggle(failedCandidate);partial.toggle(movedCandidate);partial.selectAll(partialReport.candidates)
            check(partial.selectedIDs.isEmpty && partial.selectedCandidateCount == 0 && partial.selectedBytes == 0,
                  "toggle and select-all cannot reselect any attempted item, including a failed move whose original file is still present")
            partial.selectedIDs=Set(partialReport.candidates.map(\.id));partial.prepareProcessing()
            let rejectedPartial=partial.confirmingPlan == nil && partial.selectedIDs.isEmpty
            partial.confirmingPlan=partialPlan;partial.executeConfirmedPlan()
            check(rejectedPartial && partial.confirmingPlan == nil && !partial.isProcessing &&
                  partial.receipts.count == 3 && partialMover.moveCount == 3,
                  "externally forged attempted selections and replayed old partial plans cannot dispatch another move")
            let partialReload = StorageReviewService(dataDirectory: partialFixture.data, mover: partialMover); services.append(partialReload)
            check(partialReload.receipts == partial.receipts && partialMover.moveCount == 3,
                  "partial success and failure restart with exact outcomes and no repeated action")
            guard let success = partialReload.receipts.first(where: { $0.result.state == .trashed }) else { throw StorageServiceCheckError.missingReceipt }
            let original = success.scope.canonicalDirectory.appendingPathComponent(success.candidate.relativePath)
            try Data("new occupant".utf8).write(to: original)
            partialReload.confirmingRestore = success.id; partialReload.restoreConfirmedItem()
            let refusedRestoreFinished=await wait{!partialReload.isProcessing}
            check(try refusedRestoreFinished && Data(contentsOf: original) == Data("new occupant".utf8) && partialReload.receipts.first(where: { $0.id == success.id })?.restoredAt == nil && partialMover.restoreCount == 0,
                  "restarted service refuses restoration over an existing file and keeps that file unchanged")
            try FileManager.default.removeItem(at: original)
            partialReload.confirmingRestore = success.id; partialReload.restoreConfirmedItem()
            let retriedRestoreFinished=await wait{!partialReload.isProcessing}
            check(try retriedRestoreFinished && Data(contentsOf: original) == payload(success.candidate.relativePath) && partialReload.receipts.first(where: { $0.id == success.id })?.restoredAt != nil,
                  "explicit retry restores the verified resource after the conflicting fixture is removed")

            // Simulates interruption after the verified write-ahead record, before
            // the app has written its final receipt. No process is killed.
            let recoveryFixture = try makeFixture(root.appendingPathComponent("recovery"), names: ["recover.cache"])
            let recoveryMover = StorageCheckMover(root: recoveryFixture.root, trash: recoveryFixture.trash); movers.append(recoveryMover)
            let recoveryReport = try StorageReviewScanner.scan(scopes: [.init(directory: recoveryFixture.source, kind: .rebuildableCache)])
            guard let candidate = recoveryReport.candidates.first, let scope = recoveryReport.scopes.first else { throw StorageServiceCheckError.missingReport }
            let intents = try StorageReviewIntentStore(fileURL: recoveryFixture.data.appendingPathComponent("storage-intents.json"))
            let moved = StorageReviewMoveTransaction.execute(candidate: candidate, scope: scope, operationID: UUID(), mover: recoveryMover, persist: { try intents.record($0) })
            check(moved.state == .trashed && !FileManager.default.fileExists(atPath: recoveryFixture.data.appendingPathComponent("storage-actions.json").path),
                  "interruption fixture has a real verified move and durable intent but no final app receipt")
            let recovered = StorageReviewService(dataDirectory: recoveryFixture.data, mover: recoveryMover); services.append(recovered)
            let recoveryFinished=await wait{!recovered.isProcessing}
            check(try recoveryFinished && recovered.receipts.count == 1 && recovered.receipts.first?.result.state == .trashed && recoveryMover.moveCount == 1 && readIntents(recoveryFixture.data).isEmpty,
                  "real service reconciles the recorded moved identity into one receipt without repeating the move")
            check(try readReceipts(recoveryFixture.data) == recovered.receipts,
                  "reconciled interruption receipt is committed before its intention is removed")

            let restoreFixture=try makeFixture(root.appendingPathComponent("restore-quit"),names:["restore.cache"])
            let restoreMover=StorageCheckMover(root:restoreFixture.root,trash:restoreFixture.trash,gateRestore:true);movers.append(restoreMover)
            let restoreService=StorageReviewService(dataDirectory:restoreFixture.data,mover:restoreMover);services.append(restoreService)
            try await scanAndConfirm(restoreService,source:restoreFixture.source);restoreService.executeConfirmedPlan()
            guard await wait({!restoreService.isProcessing}),let restoreReceipt=restoreService.receipts.first else {throw StorageServiceCheckError.missingReceipt}
            check(try restoreReceipt.contentProof?.isValid == true && readReceipts(restoreFixture.data).first?.contentProof == restoreReceipt.contentProof,
                  "a newly selected file persists its original content proof in the final receipt without storing its contents")
            restoreService.confirmingRestore=restoreReceipt.id;restoreService.restoreConfirmedItem()
            let restoreEntered=await wait{restoreMover.enteredRestore}
            check(try restoreEntered && restoreService.isProcessing && readReceipts(restoreFixture.data).first?.restoreStartedAt != nil && restoreService.receipts.first?.restoredAt == nil,
                  "the real restore worker remains off MainActor and durably marks its intent before the gated move-back boundary")
            var restoreQuitStarted=false,restoreQuitReturned=false
            let restoreQuit=Task {restoreQuitStarted=true;await restoreService.stopForQuit();restoreQuitReturned=true}
            _=await wait{restoreQuitStarted};await settle()
            check(!restoreQuitReturned && restoreService.isProcessing && restoreMover.restoreCount == 1,
                  "quit waits for an already dispatched restore and cannot discard its unfinished receipt")
            restoreMover.release();await restoreQuit.value
            check(try restoreQuitReturned && !restoreService.isProcessing && restoreService.receipts.first?.restoredAt != nil && restoreService.receipts.first?.restoreStartedAt == nil && readReceipts(restoreFixture.data) == restoreService.receipts && !restoreMover.timedOut,
                  "quit returns after the actual restored content and completed receipt are committed exactly once")
            check(restoreService.report?.candidates.contains(restoreReceipt.candidate) == true &&
                  restoreService.candidateStatus(for:restoreReceipt.candidate) == .restoredNeedsRescan &&
                  restoreService.candidateStatus(for:restoreReceipt.candidate).label == "已恢复 · 需重查" && !restoreService.canSelect(restoreReceipt.candidate),
                  "restoring a file keeps its old report candidate consumed and truthfully asks for a new scan")
            restoreService.toggle(restoreReceipt.candidate);restoreService.selectAll([restoreReceipt.candidate]);restoreService.prepareProcessing()
            check(restoreService.selectedIDs.isEmpty && restoreService.selectedCandidateCount == 0 && restoreService.confirmingPlan == nil &&
                  restoreMover.moveCount == 1 && restoreMover.restoreCount == 1,
                  "a restored file cannot be reselected or confirmed through its unchanged old report")
            restoreService.scan(kinds:[.rebuildableCache])
            guard await wait({!restoreService.isScanning && restoreService.report?.stage == .report}),
                  let freshRestoredCandidate=restoreService.report?.candidates.first(where:{$0.relativePath == restoreReceipt.candidate.relativePath}) else {throw StorageServiceCheckError.missingReport}
            check(freshRestoredCandidate.id != restoreReceipt.candidate.id && restoreService.canSelect(freshRestoredCandidate) &&
                  restoreService.candidateStatus(for:freshRestoredCandidate) == .pendingReview && !restoreService.canSelect(restoreReceipt.candidate) &&
                  restoreService.selectedIDs.isEmpty && restoreMover.moveCount == 1,
                  "only a real fresh scan creates a new selectable UUID for restored content without automatically selecting or moving it")
            restoreService.toggle(freshRestoredCandidate);restoreService.prepareProcessing()
            check(restoreService.selectedCandidateCount == 1 && restoreService.confirmingPlan?.selectedCandidateIDs == [freshRestoredCandidate.id] &&
                  restoreMover.moveCount == 1 && restoreMover.restoreCount == 1,
                  "newly scanned restored content still requires its own explicit selection and separate confirmation")
            restoreService.selectedIDs.removeAll();restoreService.confirmingPlan=nil
            var interruptedReceipt=restoreReceipt;interruptedReceipt.restoreStartedAt=Date()
            try JSONEncoder().encode([interruptedReceipt]).write(to:restoreFixture.data.appendingPathComponent("storage-actions.json"),options:.atomic)
            let resumedRestore=StorageReviewService(dataDirectory:restoreFixture.data,mover:restoreMover);services.append(resumedRestore)
            let restoreReconciled=await wait{!resumedRestore.isProcessing}
            check(try restoreReconciled && resumedRestore.receipts.first?.restoredAt != nil && resumedRestore.receipts.first?.restoreStartedAt == nil && resumedRestore.receipts.first?.contentProof == restoreReceipt.contentProof && restoreMover.restoreCount == 1 && readReceipts(restoreFixture.data) == resumedRestore.receipts,
                  "restart reconciles a real completed restore from the prior digest on its worker without repeating movement")

            let cancelRestoreFixture=try makeFixture(root.appendingPathComponent("restore-cancel"),names:["cancel.cache"])
            let cancelRestoreMover=StorageCheckMover(root:cancelRestoreFixture.root,trash:cancelRestoreFixture.trash);movers.append(cancelRestoreMover)
            let cancelRestore=StorageReviewService(dataDirectory:cancelRestoreFixture.data,mover:cancelRestoreMover);services.append(cancelRestore)
            try await scanAndConfirm(cancelRestore,source:cancelRestoreFixture.source);cancelRestore.executeConfirmedPlan()
            guard await wait({!cancelRestore.isProcessing}),let cancelReceipt=cancelRestore.receipts.first else {throw StorageServiceCheckError.missingReceipt}
            cancelRestore.confirmingRestore=cancelReceipt.id;cancelRestore.restoreConfirmedItem();await cancelRestore.stopForQuit()
            check(try !cancelRestore.isProcessing && cancelRestoreMover.restoreCount == 0 && cancelRestore.receipts.first?.restoredAt == nil && cancelRestore.receipts.first?.restoreStartedAt == nil && readReceipts(cancelRestoreFixture.data) == cancelRestore.receipts,
                  "cancellation before restore dispatch leaves the file in recorded Trash and clears only the durable unexecuted restore marker")
            guard let legacyTrash=cancelReceipt.result.trashURL,let legacyIdentity=cancelReceipt.trashIdentity else {throw StorageServiceCheckError.missingReceipt}
            try FileManager.default.setAttributes([.posixPermissions:Int(legacyIdentity.mode & 0o7777)],ofItemAtPath:legacyTrash.path)
            guard let legacyChanged=StorageReviewIdentityValidator.captureRegularFileIdentity(at:legacyTrash),legacyChanged != legacyIdentity else {throw StorageServiceCheckError.missingReceipt}
            guard var legacyJSON=try JSONSerialization.jsonObject(with:JSONEncoder().encode([cancelReceipt])) as? [[String:Any]],!legacyJSON.isEmpty else {throw StorageServiceCheckError.missingReceipt}
            legacyJSON[0].removeValue(forKey:"contentProof")
            try JSONSerialization.data(withJSONObject:legacyJSON).write(to:cancelRestoreFixture.data.appendingPathComponent("storage-actions.json"),options:.atomic)
            let legacyService=StorageReviewService(dataDirectory:cancelRestoreFixture.data,mover:cancelRestoreMover);services.append(legacyService)
            check(legacyService.receipts.first?.contentProof == nil,"pre-proof receipt JSON loads compatibly without inferring a digest from its current Trash file")
            legacyService.confirmingRestore=cancelReceipt.id;legacyService.restoreConfirmedItem()
            let legacyFinished=await wait{!legacyService.isProcessing}
            check(try legacyFinished && legacyService.receipts.first?.restoredAt == nil && legacyService.receipts.first?.contentProof == nil && cancelRestoreMover.restoreCount == 0 && legacyService.message?.contains("Finder") == true && Data(contentsOf:legacyTrash) == payload("cancel.cache") && readReceipts(cancelRestoreFixture.data).first?.contentProof == nil,
                  "a legacy receipt with changed ctime remains safely in Trash, explains Finder recovery and never gains automatic restore authority")

            #if DEBUG
            let healthFixture = try makeFixture(root.appendingPathComponent("health-quit"), names: ["a.cache", "b.cache"])
            let healthMover = StorageCheckMover(root: healthFixture.root, trash: healthFixture.trash, gateFirst: true); movers.append(healthMover)
            let storage = StorageReviewService(dataDirectory: healthFixture.data, mover: healthMover); services.append(storage)
            let device = DeviceStatusModel(dataDirectory: healthFixture.root.appendingPathComponent("device"), notifications: StorageCheckNotifications())
            let health = HealthCenterModel(device: device, dataDirectory: healthFixture.root.appendingPathComponent("health"), storageService: storage)
            try await scanAndConfirm(storage, source: healthFixture.source)
            health.beginProcessing()
            let healthEntered = await wait { healthMover.enteredFirst }
            var healthQuitStarted = false, healthQuitReturned = false
            let healthQuit = Task { healthQuitStarted = true; await health.prepareForQuit(); healthQuitReturned = true }
            _ = await wait { healthQuitStarted }; await settle()
            check(healthEntered && health.phase == .processing && !healthQuitReturned,
                  "HealthCenterModel prepareForQuit waits through its injected real storage service transaction")
            healthMover.release(); await healthQuit.value
            check(healthQuitReturned && health.phase == .result && health.waitingForFreshSample && health.score == nil && storage.receipts.count == 1 && healthMover.moveCount == 1,
                  "health quit resolves one actual receipt, skips the next item and retains unknown score until a later sample")
            check(try readReceipts(healthFixture.data) == storage.receipts && readIntents(healthFixture.data).isEmpty && !device.isSampling,
                  "health quit barrier finishes durable storage cleanup without starting hardware sampling")

            let cancelledFixture = try makeFixture(root.appendingPathComponent("health-cancel"), names: ["a.cache", "b.cache"])
            let cancelledMover = StorageCheckMover(root: cancelledFixture.root, trash: cancelledFixture.trash); movers.append(cancelledMover)
            let cancelledStorage = StorageReviewService(dataDirectory: cancelledFixture.data, mover: cancelledMover); services.append(cancelledStorage)
            try cancelledStorage.registerScope(.init(directory: cancelledFixture.source, kind: .rebuildableCache))
            let healthData = cancelledFixture.root.appendingPathComponent("health-history")
            try FileManager.default.createDirectory(at: healthData, withIntermediateDirectories: true)
            let now = Date()
            let oldReport = DeviceHealthAssessor.evaluate(.init(
                memory: .init(value: .init(pressure: .normal, sustainedSeconds: 0), sampledAt: now, source: "fixture pressure"),
                storage: .init(value: .init(totalBytes: 1_000_000_000_000, availableBytes: 200_000_000_000, volumeName: "fixture"), sampledAt: now, source: "fixture capacity"),
                thermal: .init(value: .init(state: .nominal, sustainedSeconds: 0), sampledAt: now, source: "fixture thermal")))
            var history = DeviceHealthHistory(); try history.append(oldReport)
            let historyURL = healthData.appendingPathComponent("health-history.json"), oldBytes = try JSONEncoder().encode(history)
            try oldBytes.write(to: historyURL)
            let cancelledHealth = HealthCenterModel(device: device, dataDirectory: healthData, storageService: cancelledStorage)
            cancelledHealth.startAssessment()
            check(cancelledHealth.phase == .checking && cancelledStorage.isScanning && cancelledHealth.latestReport == oldReport,
                  "health retains its valid previous report while the real selected-directory scan is pending")
            cancelledHealth.cancelCheck()
            let cancelFinished = await wait { !cancelledStorage.isScanning && cancelledStorage.report?.stage == .cancelled }
            check(cancelFinished && cancelledHealth.phase == .overview && cancelledHealth.assessmentOutcome == .cancelled && cancelledHealth.showingPreviousReport && cancelledHealth.latestReport == oldReport,
                  "cancelled real file scan preserves its honest cancelled stage and cannot publish a new health score")
            check(try Data(contentsOf: historyURL) == oldBytes && cancelledStorage.receipts.isEmpty && cancelledMover.moveCount == 0,
                  "cancelled scan leaves prior completed history bytes intact and never creates action receipts")
            check(try Data(contentsOf: cancelledFixture.source.appendingPathComponent("a.cache")) == payload("a.cache") && Data(contentsOf: cancelledFixture.source.appendingPathComponent("b.cache")) == payload("b.cache"),
                  "immediate scan cancellation leaves both selected temporary originals intact")
            #endif
        } catch { check(false, "storage service fixture setup: \(error.localizedDescription)") }
        // Release even when an assertion's setup threw, then await every worker
        // before deleting its isolated directory. No detached move outlives cleanup.
        for mover in movers { mover.release() }
        for service in services { await service.stopForQuit() }
        return (count, failures)
    }
    private struct Fixture { var root: URL; var source: URL; var trash: URL; var data: URL }
    private static func makeFixture(_ root: URL, names: [String]) throws -> Fixture {
        let source = root.appendingPathComponent("explicit-source"), trash = root.appendingPathComponent("fake-trash"), data = root.appendingPathComponent("service-data")
        for url in [source, trash, data] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        for name in names { try payload(name).write(to: source.appendingPathComponent(name)) }
        return .init(root: root, source: source, trash: trash, data: data)
    }
    private static func payload(_ name: String) -> Data { Data(("fixture-content:" + name).utf8) }
    private static func readReceipts(_ directory: URL) throws -> [StorageReviewReceipt] {
        try JSONDecoder().decode([StorageReviewReceipt].self, from: Data(contentsOf: directory.appendingPathComponent("storage-actions.json")))
    }
    private static func readIntents(_ directory: URL) throws -> [StorageReviewMoveIntent] {
        try StorageReviewIntentStore(fileURL: directory.appendingPathComponent("storage-intents.json")).pending
    }
    private static func scanAndConfirm(_ service: StorageReviewService, source: URL) async throws {
        try service.registerScope(.init(directory: source, kind: .rebuildableCache))
        service.scan(kinds: [.rebuildableCache])
        guard await wait({ !service.isScanning && service.report?.stage == .report }), let report = service.report else { throw StorageServiceCheckError.missingReport }
        service.selectAll(report.candidates); service.prepareProcessing()
        guard service.confirmingPlan != nil else { throw StorageServiceCheckError.missingReport }
    }
    private static func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat { if condition() { return true }; try? await Task.sleep(for: .milliseconds(1)) } while ContinuousClock.now < deadline
        return condition()
    }
    private static func settle() async { for _ in 0..<20 { await Task.yield() } }
}

private enum StorageServiceCheckError: Error { case missingReport, missingReceipt, unsafeFixturePath, gateTimedOut }

/// Synchronous gate blocks only the service's existing utility worker. Its lock
/// protects counters and the bounded condition wait; MainActor remains available.
private final class StorageCheckMover: StorageReviewFileMoving, @unchecked Sendable {
    private let condition = NSCondition()
    private let root: URL
    private let trash: URL
    private let gateFirst: Bool
    private let gateRestore:Bool
    private let failedNames: Set<String>
    private var released = false
    private var entered = false
    private var restoreEntered=false
    private var moves = 0
    private var restores = 0
    private var timeout = false
    init(root: URL, trash: URL, gateFirst: Bool = false, failedNames: Set<String> = [],gateRestore:Bool=false) {
        self.root = root.resolvingSymlinksInPath(); self.trash = trash; self.gateFirst = gateFirst; self.failedNames = failedNames;self.gateRestore=gateRestore
    }
    var enteredFirst: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    var moveCount: Int { condition.lock(); defer { condition.unlock() }; return moves }
    var restoreCount: Int { condition.lock(); defer { condition.unlock() }; return restores }
    var enteredRestore:Bool {condition.lock();defer{condition.unlock()};return restoreEntered}
    var timedOut: Bool { condition.lock(); defer { condition.unlock() }; return timeout }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func moveToTrash(_ source: URL) throws -> URL {
        try validate(source); try validate(trash)
        condition.lock(); moves += 1
        if gateFirst, moves == 1 {
            entered = true
            let deadline = Date().addingTimeInterval(5)
            while !released {
                if !condition.wait(until: deadline), !released { timeout = true; condition.unlock(); throw StorageServiceCheckError.gateTimedOut }
            }
        }
        condition.unlock()
        if failedNames.contains(source.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
        let destination = trash.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }
    func moveBack(_ source: URL, to destination: URL) throws {
        try validate(source); try validate(destination.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        condition.lock(); restores += 1
        if gateRestore {
            restoreEntered=true
            let deadline=Date().addingTimeInterval(5)
            while !released {
                if !condition.wait(until:deadline),!released {timeout=true;condition.unlock();throw StorageServiceCheckError.gateTimedOut}
            }
        }
        condition.unlock()
        try FileManager.default.moveItem(at: source, to: destination)
    }
    private func validate(_ url: URL) throws {
        guard url.isFileURL, url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw StorageServiceCheckError.unsafeFixturePath }
    }
}

@MainActor private final class StorageCheckNotifications: DeviceNotificationProviding {
    func permission() async -> DeviceNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func deliver(_ event: DeviceMonitoringEvent, budget: DeviceTrafficBudget, rule: DeviceTemperatureRule) async throws {}
}
