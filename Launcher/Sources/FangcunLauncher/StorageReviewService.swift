import AppKit
import Combine
import Foundation
import LauncherCore
import Darwin

private struct StorageReviewAppTrashMover: StorageReviewFileMoving {
    private enum RestoreStage:String,Sendable {
        case sourceDirectory="无法搜索访问已记录文件所在目录"
        case destinationDirectory="无法搜索访问原目录"
        case move="无法将文件移回原目录"
    }
    private struct RestoreError:LocalizedError,CustomNSError {
        let stage:RestoreStage
        let code:Int32
        var errorDescription:String? {stage.rawValue+"："+POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO).localizedDescription}
        static var errorDomain:String {"local.fangcun.storage.restore"}
        var errorCode:Int {Int(code)}
        var errorUserInfo:[String:Any] {[NSLocalizedDescriptionKey:errorDescription ?? stage.rawValue,NSUnderlyingErrorKey:POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)]}
    }
    func moveToTrash(_ source: URL) throws -> URL {
        var destination: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
        guard let result = destination as URL? else { throw StorageReviewIntentError.invalidJournal }
        return result
    }
    func moveBack(_ source: URL, to destination: URL) throws {
        func parentDescriptor(_ url: URL,stage:RestoreStage) throws -> Int32 {
            // A known child's rename needs directory search, not enumeration.
            // Request no read capability for the Trash or destination directory.
            let descriptor:Int32=url.deletingLastPathComponent().withUnsafeFileSystemRepresentation { path in
                guard let path else {errno=EINVAL;return -1};return open(path,O_SEARCH | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
            guard descriptor >= 0 else {throw RestoreError(stage:stage,code:errno)}
            var info=stat()
            guard fstat(descriptor,&info) == 0 else {let code=errno;close(descriptor);throw RestoreError(stage:stage,code:code)}
            guard (info.st_mode & S_IFMT) == S_IFDIR else {close(descriptor);throw RestoreError(stage:stage,code:ENOTDIR)}
            return descriptor
        }
        let fromParent = try parentDescriptor(source,stage:.sourceDirectory)
        defer { close(fromParent) }
        let toParent = try parentDescriptor(destination,stage:.destinationDirectory)
        defer { close(toParent) }
        let result = source.lastPathComponent.withCString { from in destination.lastPathComponent.withCString { to in
            renameatx_np(fromParent, from, toParent, to, UInt32(RENAME_EXCL))
        } }
        guard result == 0 else { throw RestoreError(stage:.move,code:errno) }
    }
}

final class StorageReviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
struct StorageReviewReceipt: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var operationID: UUID
    var candidate: StorageReviewCandidate
    var scope: StorageReviewScopeRecord
    var result: StorageReviewActionResult
    var trashIdentity: StorageReviewFileIdentity?
    var contentProof: StorageReviewContentProof?
    var restoredAt: Date?
    var restoreStartedAt: Date?
    var requiresManualReview: Bool?
}

/// A scan candidate is a one-use review identity. Receipts remain historical
/// evidence after restoration; only a fresh scan can authorize another review.
enum StorageReviewCandidateStatus: Equatable {
    case pendingReview, retained, movedToTrash, restoredNeedsRescan, attemptedNeedsRescan, unavailable
    var isSelectable: Bool { self == .pendingReview }
    var label: String {
        switch self {
        case .pendingReview: "待复核"
        case .retained: "保留"
        case .movedToTrash: "已移到废纸篓"
        case .restoredNeedsRescan: "已恢复 · 需重查"
        case .attemptedNeedsRescan: "需重新检查"
        case .unavailable: "检查依据已失效"
        }
    }
    var explanation: String {
        switch self {
        case .pendingReview: "请逐项确认内容归属与可重建性；处理前还会重新核验文件身份。"
        case .retained: "此项不在可处理范围内，保持原有保护。"
        case .movedToTrash: "此候选已有移到废纸篓的回执，不能重复选择；恢复后也需重新检查。"
        case .restoredNeedsRescan: "文件已恢复；原扫描身份不再用于处理，请重新检查后再复核。"
        case .attemptedNeedsRescan: "此候选已有处理尝试记录，不代表处理成功；请核对回执并重新检查后再复核。"
        case .unavailable: "此候选不属于当前完整有效的检查报告，请重新检查后再复核。"
        }
    }
}

@MainActor final class StorageReviewService: ObservableObject {
    @Published private(set) var scopes: [StorageReviewScope] = []
    @Published private(set) var report: StorageReviewReport?
    @Published private(set) var progress: StorageReviewProgress?
    @Published private(set) var isScanning = false
    @Published private(set) var isProcessing = false
    @Published private(set) var receipts: [StorageReviewReceipt] = []
    @Published private(set) var processedCount = 0
    @Published private(set) var plannedCount = 0
    @Published private(set) var lastOperationIDs = Set<UUID>()
    @Published private(set) var lastOperationID: UUID?
    @Published var selectedIDs = Set<UUID>()
    @Published var message: String?
    @Published var confirmingPlan: StorageReviewTrashPlan?
    @Published var confirmingRestore: UUID?
    private var cancellation = StorageReviewCancellation()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let journalURL: URL
    private let intentStore: StorageReviewIntentStore?
    private let mover: any StorageReviewFileMoving
    private var journalProtected = false
    var onScanFinished: (() -> Void)?
    var onProcessingFinished: (() -> Void)?
    var onRestored: (() -> Void)?
    init(dataDirectory: URL, mover: (any StorageReviewFileMoving)? = nil) {
        self.mover = mover ?? StorageReviewAppTrashMover()
        journalURL = dataDirectory.appendingPathComponent("storage-actions.json")
        do { intentStore = try StorageReviewIntentStore(fileURL: dataDirectory.appendingPathComponent("storage-intents.json")) }
        catch { intentStore = nil; journalProtected = true; message = "处理意图记录无法读取，原文件已保留；本次暂停文件处理。" }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                let data = try Data(contentsOf: journalURL)
                guard data.count <= 16_777_216 else { throw StorageReviewError.invalidReport }
                receipts = try JSONDecoder().decode([StorageReviewReceipt].self, from: data)
                guard receipts.count <= 10_000, Set(receipts.map(\.id)).count == receipts.count,
                      receipts.allSatisfy({ $0.result.candidateID == $0.candidate.id && $0.scope.scope.id == $0.candidate.scopeID &&
                          !$0.candidate.relativePath.hasPrefix("/") && !$0.candidate.relativePath.split(separator: "/").contains("..") &&
                          ($0.result.trashURL?.isFileURL ?? true) && ($0.contentProof?.isValid ?? true) && ($0.result.state != .trashed || $0.result.trashURL != nil) }) else { throw StorageReviewError.invalidReport }
                var recoveredRestoration = false
                for index in receipts.indices where receipts[index].result.state == .trashed && receipts[index].restoredAt == nil {
                    if receipts[index].trashIdentity.map(receipts[index].candidate.identity.matchesMovedResource) != true {
                        receipts[index].requiresManualReview = true; receipts[index].trashIdentity = nil
                        receipts[index].result.state = .failed
                        receipts[index].result.reason = "此前记录缺少与所选文件一致的移动结果身份，未推定成功或授权自动恢复，请在 Finder 中核对。"
                        recoveredRestoration = true
                    }
                }
                if recoveredRestoration { try saveJournal() }
            } catch { journalProtected = true; message = "整理记录无法读取，原文件已保留。为保留恢复依据，本次暂停文件处理。" }
        }
        if !journalProtected, let intentStore {
            let pending=intentStore.pending
            if !pending.isEmpty || receipts.contains(where:{$0.restoreStartedAt != nil && $0.restoredAt == nil}) {reconcileInBackground(pending:pending)}
        }
    }
    /// Startup reconciliation only reads already recorded locations. Large
    /// selected-file proofs use the same cancellable worker and quit barrier.
    private func reconcileInBackground(pending:[StorageReviewMoveIntent]) {
        let previous=receipts,token=StorageReviewCancellation();cancellation=token;isProcessing=true
        task=Task { [weak self] in
            let evidence=await Task.detached(priority:.utility) {
                var restores:[UUID:StorageReviewRestoreOutcome]=[:],moves:[StorageReviewMoveOutcome]=[],resolved=Set<UUID>()
                for receipt in previous where receipt.restoreStartedAt != nil && receipt.restoredAt == nil {
                    if token.isCancelled {break}
                    guard let trash=receipt.result.trashURL,let expected=receipt.trashIdentity else {continue}
                    let result=StorageReviewRestoreTransaction.reconcile(candidate:receipt.candidate,scope:receipt.scope,trashURL:trash,
                        verifiedIdentity:expected,contentProof:receipt.contentProof,isCancelled:{token.isCancelled})
                    if !token.isCancelled {restores[receipt.id]=result}
                }
                for intent in pending {
                    if token.isCancelled {break}
                    if let existing=previous.first(where:{$0.id == intent.id}) {
                        if existing.requiresManualReview != true && (existing.result.state == .trashed || existing.restoredAt != nil || intent.stage != .needsReview && existing.result.trashURL == nil) {resolved.insert(intent.id)}
                        continue
                    }
                    let result=StorageReviewMoveTransaction.reconcile(intent,isCancelled:{token.isCancelled})
                    if !token.isCancelled {moves.append(result);if result.state != .needsReview {resolved.insert(intent.id)}}
                }
                return (restores,moves,resolved)
            }.value
            guard let self else {return}
            defer {self.isProcessing=false;self.task=nil}
            do {
                for (id,result) in evidence.0 {
                    guard let index=self.receipts.firstIndex(where:{$0.id == id}) else {continue}
                    if result.state == .restored {self.receipts[index].restoredAt=Date();self.receipts[index].restoreStartedAt=nil}
                    else if result.state == .notMoved {self.receipts[index].restoreStartedAt=nil}
                    else {self.receipts[index].requiresManualReview=true;self.receipts[index].trashIdentity=nil;self.receipts[index].result.reason=result.explanation}
                }
                for result in evidence.1 {
                    if result.state == .trashed || result.state == .needsReview {try self.intentStore?.record(result.intent)}
                    self.receipts.append(Self.receipt(from:result))
                }
                try self.saveJournal()
                for id in evidence.2 {try self.intentStore?.remove(id)}
                self.message=token.isCancelled ? "中断记录核验已取消，未移动文件；未完成的依据仍保留。":"发现上次中断的文件处理记录，已按身份与已有内容依据核对；未重复移动或自动恢复文件。"
            } catch {self.journalProtected=true;self.message="中断记录尚未完整写入，原意图与恢复记录均保留；请先核对处理记录。"}
        }
    }
    deinit { cancellation.cancel(); task?.cancel() }
    func chooseScope(_ kind: StorageReviewScopeKind, host: NSWindow?) {
        guard !isScanning, !isProcessing else { return }
        let panel = NSOpenPanel(); panel.title = kind == .rebuildableCache ? "选择明确要检查的缓存目录" : "选择要检查的诊断记录目录"
        panel.message = "只检查你选择的目录。文件不会自动删除；请确认这里的内容归属，再逐项复核。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                do { try self?.registerScope(.init(directory: url, kind: kind)) }
                catch { self?.message = error.localizedDescription }
            }
        }
        if let host { panel.beginSheetModal(for: host, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
    /// Called only after an explicit directory selection (or by isolated checks).
    /// Registration shares the scanner's metadata validation and reads no contents.
    @discardableResult func registerScope(_ scope: StorageReviewScope) throws -> Bool {
        guard !isScanning, !isProcessing else { return false }
        let accessed = scope.directory.startAccessingSecurityScopedResource()
        defer { if accessed { scope.directory.stopAccessingSecurityScopedResource() } }
        let record = try StorageReviewScanner.validatedScope(scope)
        guard !scopes.contains(where: { $0.kind == scope.kind && (try? StorageReviewScanner.validatedScope($0).canonicalDirectory) == record.canonicalDirectory }) else { return false }
        scopes.append(scope); return true
    }
    func removeScope(_ id: UUID) { guard !isScanning, !isProcessing else { return }; scopes.removeAll { $0.id == id } }
    func clearCurrentReport() {
        guard !isScanning, !isProcessing else { return }
        report = nil; progress = nil; selectedIDs.removeAll(); confirmingPlan = nil
        if !journalProtected { message = nil }
    }
    func scan(kinds: Set<StorageReviewScopeKind>) {
        guard !isScanning, !isProcessing else { return }
        let chosen = scopes.filter { kinds.contains($0.kind) }
        guard !chosen.isEmpty else { message = "尚未选择文件检查目录；本次仅检查设备状态。"; onScanFinished?(); return }
        cancellation.cancel(); cancellation = StorageReviewCancellation(); let token = cancellation
        generation = UUID(); let current = generation
        isScanning = true; progress = nil; report = nil; selectedIDs.removeAll(); message = nil
        let accessed = chosen.compactMap { $0.directory.startAccessingSecurityScopedResource() ? $0.directory : nil }
        task = Task { [weak self] in
            defer { for url in accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let report = try await Task.detached(priority: .utility) { [weak self] in
                    try StorageReviewScanner.scan(scopes: chosen, isCancelled: { token.isCancelled }, progress: { value in
                        if value.checkedEntries <= 1 || value.checkedEntries.isMultiple(of: 100) || value.currentScopeID == nil {
                            Task { @MainActor [weak self] in guard let self, self.generation == current else { return }; self.progress = value }
                        }
                    })
                }.value
                guard let self, self.generation == current else { return }
                self.report = report; self.isScanning = false
                if report.stage == .cancelled { self.message = "文件检查已取消，已完成部分保留；未处理任何文件。" }
                else if report.reachedLimit { self.message = "已达到本次检查上限，请缩小范围后重新检查。" }
                self.onScanFinished?()
            } catch {
                guard let self, self.generation == current else { return }
                self.isScanning = false; self.message = "文件检查失败：\(error.localizedDescription)"; self.onScanFinished?()
            }
        }
    }
    func cancel() { cancellation.cancel(); task?.cancel() }
    /// Await the current OS operation and its journal write before allowing process termination.
    func stopForQuit() async { cancel(); if let task { await task.value } }
    func candidateStatus(for candidate: StorageReviewCandidate) -> StorageReviewCandidateStatus {
        if let receipt = receipts.last(where: { $0.candidate.id == candidate.id }) {
            if receipt.restoredAt != nil { return .restoredNeedsRescan }
            if receipt.result.state == .trashed, receipt.requiresManualReview != true { return .movedToTrash }
            return .attemptedNeedsRescan
        }
        guard let report, report.candidates.contains(candidate) else { return .unavailable }
        if candidate.disposition == .retain { return .retained }
        guard report.stage == .report, !report.reachedLimit, report.ruleVersion == StorageReviewScanner.ruleVersion else { return .unavailable }
        return .pendingReview
    }
    func canSelect(_ candidate: StorageReviewCandidate) -> Bool {
        !isScanning && !isProcessing && !journalProtected && candidateStatus(for: candidate).isSelectable
    }
    private var selectedCandidates: [StorageReviewCandidate] {
        report?.candidates.filter { selectedIDs.contains($0.id) && candidateStatus(for: $0).isSelectable } ?? []
    }
    var selectedCandidateCount: Int { selectedCandidates.count }
    func toggle(_ candidate: StorageReviewCandidate) {
        guard canSelect(candidate) else { return }
        if selectedIDs.contains(candidate.id) { selectedIDs.remove(candidate.id) } else { selectedIDs.insert(candidate.id) }
    }
    func selectAll(_ candidates: [StorageReviewCandidate]) {
        for item in candidates where canSelect(item) { selectedIDs.insert(item.id) }
    }
    var selectedBytes: UInt64 { selectedCandidates.reduce(0) { partial, file in
        let result = partial.addingReportingOverflow(file.logicalBytes); return result.overflow ? .max : result.partialValue
    } }
    func prepareProcessing() {
        confirmingPlan = nil
        guard !isScanning, !isProcessing, !journalProtected, let report else { message = "缺少有效检查报告或恢复记录不可写。"; return }
        let validIDs = Set(report.candidates.filter(canSelect).map(\.id))
        guard selectedIDs.isSubset(of: validIDs) else {
            selectedIDs.formIntersection(validIDs)
            message = "部分所选文件已处理或检查依据已失效，请重新检查后再选择。"
            return
        }
        do { confirmingPlan = try .init(report: report, selectedCandidateIDs: selectedIDs) } catch { message = error.localizedDescription }
    }
    func executeConfirmedPlan() {
        guard !isScanning, !isProcessing, !journalProtected, let intentStore, let plan = confirmingPlan, let report, plan.reportID == report.id else { return }
        confirmingPlan = nil
        let selected = report.candidates.filter { plan.selectedCandidateIDs.contains($0.id) }
        guard selected.count == plan.selectedCandidateIDs.count, selected.allSatisfy(canSelect),
              (try? StorageReviewTrashPlan(report: report, selectedCandidateIDs: Set(plan.selectedCandidateIDs))) == plan else {
            message = "选择已变化或项目已有处理记录，请重新检查后再复核。"; return
        }
        guard receipts.count + selected.count <= 10_000 else { message = "恢复记录已达到容量上限，未处理任何新文件。"; return }
        do { try saveJournal() } catch { message = "无法保存恢复记录，未处理文件：\(error.localizedDescription)"; return }
        cancellation = StorageReviewCancellation(); let token = cancellation
        generation = UUID(); let current = generation
        isProcessing = true; processedCount = 0; plannedCount = selected.count; lastOperationIDs = Set(selected.map(\.id)); lastOperationID = current; message = nil
        let accessed = report.scopes.compactMap { $0.scope.directory.startAccessingSecurityScopedResource() ? $0.scope.directory : nil }
        let mover = self.mover
        task = Task { [weak self] in
            defer { for url in accessed { url.stopAccessingSecurityScopedResource() } }
            for candidate in selected {
                guard let self, self.generation == current else { return }
                guard let scope = report.scopes.first(where: { $0.scope.id == candidate.scopeID }) else { continue }
                if token.isCancelled { break }
                let outcome = await Task.detached(priority: .utility) {
                    StorageReviewMoveTransaction.execute(candidate: candidate, scope: scope, operationID: current,
                        mover: mover, isCancelled: { token.isCancelled }, persist: { try intentStore.record($0) })
                }.value
                let receipt = Self.receipt(from: outcome)
                self.receipts.append(receipt); self.processedCount += 1; self.selectedIDs.remove(candidate.id)
                do {
                    try self.saveJournal()
                    // Keep unresolved intention evidence for manual reconciliation.
                    if outcome.state != .needsReview { try intentStore.remove(outcome.intent.id) }
                } catch {
                    self.message = "处理记录保存失败，已停止后续处理。已完成项目仍可在当前界面恢复：\(error.localizedDescription)"; token.cancel()
                }
            }
            guard let self, self.generation == current else { return }
            self.isProcessing = false
            if token.isCancelled, self.message == nil { self.message = "后续处理已取消，已完成项目保留真实结果。" }
            self.onProcessingFinished?()
        }
    }
    private nonisolated static func receipt(from outcome: StorageReviewMoveOutcome) -> StorageReviewReceipt {
        let intent = outcome.intent
        var result: StorageReviewActionResult
        if outcome.state == .trashed, let destination = intent.resultingURL, outcome.automaticRestoreIdentity != nil {
            result = .init(candidateID: intent.candidate.id, trashURL: destination)
        } else {
            let state: StorageReviewActionState = outcome.state == .skipped ? .skipped : outcome.state == .cancelled ? .cancelled : .failed
            result = .init(candidateID: intent.candidate.id, state: state, reason: outcome.explanation)
            if outcome.state == .needsReview { result.trashURL = intent.resultingURL }
        }
        result.reason = outcome.explanation
        return StorageReviewReceipt(id: intent.id, operationID: intent.operationID, candidate: intent.candidate, scope: intent.scope,
            result: result, trashIdentity: outcome.automaticRestoreIdentity,contentProof:intent.contentProof, requiresManualReview: outcome.state == .needsReview)
    }
    func restoreConfirmedItem() {
        guard !isProcessing, !isScanning,!journalProtected, let id = confirmingRestore,
              let index = receipts.firstIndex(where: { $0.id == id }), receipts[index].restoredAt == nil else { return }
        confirmingRestore = nil; let receipt = receipts[index]
        guard receipt.requiresManualReview != true, let trash = receipt.result.trashURL, let expected = receipt.trashIdentity else {
            message = "原位置或废纸篓文件已经变化；为避免覆盖，未自动恢复。请在 Finder 中核对并移回原目录。"; return
        }
        // Commit the marker before dispatching any worker. The core's second
        // pre-move check still runs after this durable intent; no MainActor state
        // is captured by its synchronous persistence boundary.
        receipts[index].restoreStartedAt=Date()
        do {try saveJournal()} catch {receipts[index].restoreStartedAt=nil;message="恢复意图未能写入，未移动文件：\(error.localizedDescription)";return}
        let token=StorageReviewCancellation();cancellation=token;let mover=self.mover
        let accessed=receipt.scope.scope.directory.startAccessingSecurityScopedResource()
        isProcessing=true;message=nil
        task=Task { [weak self] in
            defer {if accessed {receipt.scope.scope.directory.stopAccessingSecurityScopedResource()}}
            let result=await Task.detached(priority:.utility) {
                StorageReviewRestoreTransaction.execute(candidate:receipt.candidate,scope:receipt.scope,trashURL:trash,
                    verifiedIdentity:expected,mover:mover,contentProof:receipt.contentProof,isCancelled:{token.isCancelled},persistIntent:{})
            }.value
            guard let self else {return}
            defer {self.isProcessing=false;self.task=nil}
            guard let index=self.receipts.firstIndex(where:{$0.id == id}) else {return}
            if result.state == .restored {self.receipts[index].restoredAt=Date();self.receipts[index].restoreStartedAt=nil;self.onRestored?()}
            else if result.state == .notMoved {self.receipts[index].restoreStartedAt=nil}
            else if result.state == .rolledBack {self.receipts[index].restoreStartedAt=nil;self.receipts[index].requiresManualReview=true;self.receipts[index].trashIdentity=nil}
            else {self.receipts[index].requiresManualReview=true;self.receipts[index].trashIdentity=nil}
            self.receipts[index].result.reason=result.explanation;self.message=result.explanation
            do {try self.saveJournal()} catch {self.message=result.explanation+" 恢复记录尚未写入；已保留先前的恢复意图供下次核对。"}
        }
    }
    func revealReceipt(_ receipt: StorageReviewReceipt) {
        if let url = receipt.result.trashURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    private func saveJournal() throws {
        guard !journalProtected, receipts.count <= 10_000 else { throw StorageReviewError.invalidReport }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(receipts); guard data.count <= 16_777_216 else { throw StorageReviewError.invalidReport }
        try data.write(to: journalURL, options: .atomic)
    }
}
