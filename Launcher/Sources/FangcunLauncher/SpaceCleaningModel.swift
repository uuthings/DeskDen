import AppKit
import Combine
import Foundation
import LauncherCore
import Quartz

@MainActor final class SpaceCleaningModel: NSObject, ObservableObject, @preconcurrency QLPreviewPanelDataSource {
    @Published var screen: CleaningScreen = .start
    @Published var scopeChoice: CleaningScopeChoice = .recommended
    @Published var expandedGroup: CleaningResultGroup?
    @Published var detailID: UUID?
    @Published var selectedIDs = Set<UUID>()
    @Published var dialog: CleaningDialog?
    @Published var method: SpaceCleaningMethod = .trash
    @Published var rememberMethod = false
    @Published var acknowledgement = false
    @Published var windowVisible = false
    @Published var reduceMotion = false
    @Published var message: String?
    @Published private(set) var items: [CleaningItemDisplay] = []
    @Published private(set) var lanes: [CleaningScanLane] = []
    @Published private(set) var checkedCount = 0
    @Published private(set) var completedStageCount = 0
    @Published private(set) var diskVolumeName: String?
    @Published private(set) var diskTotal: UInt64?
    @Published private(set) var diskAvailable: UInt64?
    @Published private(set) var coverageIssues: [String] = []
    @Published private(set) var coverageNotes: [String] = []
    private var scanReachedLimit = false
    @Published private(set) var currentBatch: CleaningHistoryBatchDisplay?
    @Published private(set) var batches: [CleaningHistoryBatchDisplay] = []
    @Published private(set) var processingCompleted = 0
    @Published private(set) var processingTotal = 0
    @Published private(set) var processingItem = ""
    @Published private(set) var requiresRescan = false
    @Published private(set) var isReconcilingHistory = false
    weak var hostWindow: NSWindow?

    let dataDirectory: URL
    let homeDirectory: URL
    private let preferenceURL: URL
    private var customDirectory: URL?
    private var securityScopedDirectory: URL?
    private var task: Task<Void, Never>?
    private var cancellation = StorageReviewCancellation()
    private var generation = UUID()
    private var frozenForQuit = false
    private var previousScreen: CleaningScreen = .start
    private var confirmedIDs = Set<UUID>()
    private var pendingHistoryIDs = Set<UUID>()
    private var previewURL: NSURL?
    private var candidates: [UUID: SpaceCleaningCandidate] = [:]
    private var declarations: [SpaceCleaningTestDeclaration] = []
    private var historyStore: SpaceCleaningHistoryStore?
    private var records: [SpaceCleaningRecord] = []
    private var currentOperationID: UUID?
    private var historyError: String?
    private var preferencesWritable = true
    private let mover: any SpaceCleaningFileOperating
    private let runtime = SpaceCleaningRuntimeContext()
    private var runtimeObservers: [NSObjectProtocol] = []

    init(dataDirectory: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         mover: any SpaceCleaningFileOperating = SpaceCleaningAppFileOperations()) {
        self.dataDirectory = dataDirectory
        self.homeDirectory = homeDirectory
        self.preferenceURL = dataDirectory.appendingPathComponent("preferences.json")
        self.mover = mover
        super.init()
        loadPreferences()
        updateRunningApplications()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            runtimeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateRunningApplications() }
            })
        }
        loadHistory()
        refreshDisk()
    }

    var detail: CleaningItemDisplay? { items.first { $0.id == detailID } }
    var pendingHistoryItems: [CleaningHistoryItemDisplay] { batches.flatMap(\.items).filter { pendingHistoryIDs.contains($0.id) } }
    var selectedItems: [CleaningItemDisplay] { items.filter { selectedIDs.contains($0.id) && $0.isSelectable } }
    var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 &+ $1.bytes } }
    var selectedCount: Int { selectedItems.count }
    var isBusy: Bool { task != nil }
    var canProcess: Bool { !isBusy && !frozenForQuit && !requiresRescan && historyError == nil && selectedCount > 0 }
    var animationActive: Bool { windowVisible && screen == .scanning && !reduceMotion }
    var scopeSummary: String {
        switch scopeChoice {
        case .recommended: "此 Mac · 当前用户常用位置"
        case .xcode: "Xcode · 构建缓存与归档"
        case .downloads: "下载文件夹"
        case .custom: customDirectory?.path.replacingOccurrences(of: homeDirectory.path, with: "~") ?? "尚未选择目录"
        }
    }
    var reportSummary: String {
        if requiresRescan { return "文件状态已变化，请重新扫描后再选择" }
        if screen == .scanning { return "已检查 \(checkedCount) 项 · 逐项核验用途与保护规则" }
        if scanReachedLimit { return "扫描已到达数量或深度边界 · 仅可选择已完整核验的项目" }
        return coverageIssues.isEmpty ? "扫描完成 · 所有项目均由你选择后处理" : "已检查 \(checkedCount) 项 · 有 \(coverageIssues.count) 处覆盖范围需要留意"
    }
    func toggleItem(_ id: UUID) {
        guard !isBusy, !requiresRescan, items.contains(where: { $0.id == id && $0.isSelectable }) else { return }
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }
    func selectRecommended() {
        guard !isBusy, !requiresRescan else { return }
        selectedIDs.formUnion(items.filter { $0.group == .rebuildable && $0.isSelectable }.map(\.id))
    }
    func toggleGroup(_ group: CleaningResultGroup) { expandedGroup = expandedGroup == group ? nil : group }
    func showDetail(_ id: UUID) { detailID = id }
    func closeDetail() { detailID = nil }
    func showHistory() { guard !isBusy else { return }; previousScreen = screen; screen = .history; reconcileHistory() }
    func returnFromHistory() { guard !isBusy else { return }; screen = previousScreen == .history ? .start : previousScreen }
    func closeDialog() { dialog = nil; confirmedIDs = []; pendingHistoryIDs = []; acknowledgement = false }
    func selectScope(_ choice: CleaningScopeChoice) {
        guard !isBusy else { return }
        if choice == .custom && customDirectory == nil { chooseCustomDirectory(); return }
        scopeChoice = choice; invalidateResults(); closeDialog()
    }
    func chooseCustomDirectory() {
        guard !isBusy, !frozenForQuit else { return }
        closeDialog()
        let panel = NSOpenPanel()
        panel.title = "选择要扫描的目录"; panel.prompt = "选择目录"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            self.securityScopedDirectory?.stopAccessingSecurityScopedResource()
            self.securityScopedDirectory = url.startAccessingSecurityScopedResource() ? url : nil
            self.customDirectory = url; self.scopeChoice = .custom; self.invalidateResults()
        }
        if let hostWindow { panel.beginSheetModal(for: hostWindow, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
    private func invalidateResults() {
        selectedIDs = []; detailID = nil; candidates = [:]; items = []; lanes = []
        requiresRescan = false; screen = .start; message = historyError
    }
    func requestConfirmation() {
        guard canProcess else { return }
        confirmedIDs = Set(selectedItems.map(\.id)); acknowledgement = false; dialog = .confirm
    }
    func requestTestPurpose(_ id: UUID) {
        guard !isBusy, !requiresRescan, items.contains(where: { $0.id == id && $0.needsPurposeConfirmation }) else { return }
        acknowledgement = false; dialog = .purpose(id)
    }
    func requestRestore(_ id: UUID) {
        guard !isBusy, !frozenForQuit, historyError == nil, batches.contains(where: { $0.id == id && $0.restorableCount > 0 }) else { return }
        pendingHistoryIDs = Set(records.filter { $0.operationID == id && $0.canRestore }.map(\.id))
        acknowledgement = false; dialog = .restore(id)
    }
    func requestRestoreItem(_ id: UUID) {
        guard !isBusy, !frozenForQuit, historyError == nil, let record = records.first(where: { $0.id == id && $0.canRestore }) else { return }
        pendingHistoryIDs = [id]; acknowledgement = false; dialog = .restore(record.operationID)
    }
    func requestPurge(_ id: UUID) {
        guard !isBusy, !frozenForQuit, historyError == nil, batches.contains(where: { $0.id == id && $0.purgeableCount > 0 }) else { return }
        acknowledgement = false; dialog = .purge(id)
    }
    func cancelScan() { cancellation.cancel(); message = "正在停止扫描，已检查内容会保留供查看。" }
    func cancelHistoryVerification() { cancellation.cancel(); message = "正在停止历史核验，原记录保持不变。" }
    func cancelProcessing() { cancellation.cancel(); message = "正在完成当前文件的安全收尾，其余项目将取消。" }
    func cancelAll() { cancellation.cancel(); closeDialog() }
    func waitUntilIdle() async { if let task { await task.value } }
    func prepareForQuit() async {
        frozenForQuit = true; cancelAll()
        if let task { await task.value }
        securityScopedDirectory?.stopAccessingSecurityScopedResource(); securityScopedDirectory = nil
    }
    func resumeAfterCancelledQuit() { frozenForQuit = false }
    func refreshDisk() {
        let root = homeDirectory
        Task { [weak self] in
            let values = await Task.detached(priority: .utility) { () -> (String?, UInt64?, UInt64?) in
                guard let value = try? root.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]) else { return (nil, nil, nil) }
                return (value.volumeName, value.volumeTotalCapacity.flatMap { $0 > 0 ? UInt64($0) : nil },
                        value.volumeAvailableCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil })
            }.value
            guard let self else { return }
            self.diskVolumeName = values.0; self.diskTotal = values.1; self.diskAvailable = values.2
        }
    }
    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
    func preview(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), FileManager.default.fileExists(atPath: item.url.path) else { message = "文件已不在原位置，请重新扫描。"; return }
        previewURL = item.url as NSURL
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL }

    func startScan() {
        guard !isBusy, !frozenForQuit else { return }
        let context = makeContext()
        let scopes = selectedScopes(context)
        guard !scopes.isEmpty else { message = "请先选择要扫描的目录。"; return }
        generation = UUID(); let run = generation
        cancellation = StorageReviewCancellation(); let token = cancellation
        selectedIDs = []; confirmedIDs = []; detailID = nil; expandedGroup = nil; items = []; candidates = [:]
        coverageIssues = []; coverageNotes = []; scanReachedLimit = false; requiresRescan = false; checkedCount = 0; completedStageCount = 0
        closeDialog(); message = historyError; screen = .scanning
        lanes = scanLanes(scopes)
        task = Task { [weak self] in
            let output = await Task.detached(priority: .utility) {
                var lastUpdate = Date.distantPast
                var lastCount = 0, stageCounts: [String: Int] = [:]
                let report = SpaceCleaningScanner.scan(scopes: scopes, context: context, isCancelled: { token.isCancelled }) { progress in
                    let increment = max(0, progress.checkedEntries - lastCount)
                    lastCount = progress.checkedEntries
                    stageCounts[progress.stage.rawValue, default: 0] += increment
                    let counts = stageCounts
                    guard Date().timeIntervalSince(lastUpdate) >= 0.08 || [.complete, .cancelled, .failed].contains(progress.stage) else { return }
                    lastUpdate = Date()
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == run, self.screen == .scanning else { return }
                        self.acceptProgress(progress, counts: counts)
                    }
                }
                return (report, stageCounts)
            }.value
            let report = output.0
            guard let self, self.generation == run else { return }
            self.checkedCount = report.checkedEntries
            self.coverageIssues = report.issues.filter { ![.missing, .duplicate].contains($0.kind) }.map { $0.url.path.replacingOccurrences(of: self.homeDirectory.path, with: "~") + " · " + $0.reason }
            self.coverageNotes = report.scopes.map { $0.title + " · " + $0.directory.path.replacingOccurrences(of: self.homeDirectory.path, with: "~") }
            self.coverageNotes += report.issues.filter { [.missing, .duplicate].contains($0.kind) }.map { $0.url.path.replacingOccurrences(of: self.homeDirectory.path, with: "~") + " · " + $0.reason }
            self.candidates = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.id, $0) })
            self.items = report.candidates.map(Self.display).sorted {
                if $0.group != $1.group { return CleaningResultGroup.allCases.firstIndex(of: $0.group)! < CleaningResultGroup.allCases.firstIndex(of: $1.group)! }
                return $0.bytes == $1.bytes ? $0.url.path < $1.url.path : $0.bytes > $1.bytes
            }
            self.requiresRescan = [.cancelled, .failed].contains(report.stage)
            self.scanReachedLimit = report.reachedLimit
            for index in self.lanes.indices {
                self.lanes[index].checkedCount = output.1[self.lanes[index].id] ?? 0
                if report.complete { self.lanes[index].state = .complete }
            }
            self.completedStageCount = self.lanes.filter { $0.state == .complete }.count
            if self.requiresRescan { self.message = report.stage == .cancelled ? "扫描已停止。当前结果仅供查看，请完成一次扫描后再清理。" : "扫描未完整结束，已保留检查结果。请调整范围后重新扫描。" }
            else if report.reachedLimit { self.message = "本次覆盖范围受限。仅完整核验且可处理的项目能够选择；缩小范围可继续查看其余内容。" }
            self.task = nil; self.screen = .results; self.refreshDisk()
        }
    }
    func confirmTestPurpose(_ id: UUID) {
        guard !isBusy, acknowledgement, dialog == .purpose(id), let candidate = candidates[id], candidate.canConfirmTestPurpose,
              SpaceCleaningScanner.captureIdentity(at: candidate.url) == candidate.identity else {
            message = "文件身份已变化，请重新扫描后确认用途。"; closeDialog(); return
        }
        declarations.removeAll { $0.url == candidate.url }
        declarations.append(.init(candidate: candidate))
        closeDialog(); startScan()
    }
    func executeConfirmed(permanent: Bool, remember: Bool) {
        guard dialog == .confirm, canProcess, confirmedIDs == Set(selectedItems.map(\.id)),
              !permanent || acknowledgement, let historyStore else { return }
        let selected = selectedItems.compactMap { candidates[$0.id] }
        guard selected.count == confirmedIDs.count else { return }
        let chosen: SpaceCleaningMethod = permanent ? .permanent : .trash
        if remember { savePreference(chosen) } else if rememberMethod { clearPreference() }
        closeDialog(); beginProcessing(count: selected.count)
        let operationID = UUID(); currentOperationID = operationID
        let token = cancellation, mover = mover, home = homeDirectory, declarations = declarations, runtime = runtime
        let persistence = SpaceCleaningPersistence(store: historyStore, cancellation: token)
        task = Task { [weak self] in
            for candidate in selected {
                // Stop between items. An item already started completes its verified
                // transaction; an irreversible directory deletion is never cut in half.
                guard !token.isCancelled, persistence.error == nil else { break }
                let cancelledBeforeItem = false
                self?.processingItem = candidate.title
                let record = await Task.detached(priority: .utility) {
                    SpaceCleaningTransaction.execute(candidate: candidate, operationID: operationID, method: chosen,
                        permanentConfirmed: permanent, mover: mover, isCancelled: { cancelledBeforeItem },
                        validatePolicy: { item in
                            let context = Self.context(home: home, runtime: runtime, declarations: declarations)
                            let validation = SpaceCleaningScanner.revalidate(candidate: item, context: context, isCancelled: { cancelledBeforeItem })
                            return validation == .unchanged ? nil : "文件内容、使用状态或保护规则已变化，已跳过；请重新扫描。"
                        }, validateActivity: { candidate, currentURL in
                            let context = Self.context(home: home, runtime: runtime, declarations: declarations)
                            if Self.runningAt(currentURL, context: context) { return "文件关联的应用正在运行，已保留项目。" }
                            return SpaceCleaningScanner.validatePolicy(candidate: candidate, context: context) == .unchanged ? nil : "使用状态或保护规则已变化，已保留项目。"
                        }, persist: persistence.record)
                }.value
                self?.acceptRecord(record); self?.processingCompleted += 1
                if persistence.error != nil { break }
            }
            guard let self else { return }
            self.finishProcessing(error: persistence.error)
        }
    }
    func executeRestore(batchID: UUID, renameConflicts: Bool) {
        guard dialog == .restore(batchID), !isBusy, !frozenForQuit, historyError == nil, let historyStore else { return }
        let selected = records.filter { $0.operationID == batchID && $0.canRestore && pendingHistoryIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        closeDialog(); beginProcessing(count: selected.count); currentOperationID = batchID
        let token = cancellation, persistence = SpaceCleaningPersistence(store: historyStore, cancellation: cancellation)
        let home = homeDirectory, runtime = runtime, declarations = declarations
        task = Task { [weak self] in
            for record in selected {
                guard !token.isCancelled else { break }
                self?.processingItem = record.candidate.title
                let restored = await Task.detached(priority: .utility) {
                    SpaceCleaningTransaction.restore(record: record, conflict: renameConflicts ? .rename : .skip,
                        isCancelled: { false }, validatePolicy: { candidate in
                            let context = Self.context(home: home, runtime: runtime, declarations: declarations)
                            return record.locationURL.map { Self.runningAt($0, context: context) } == true ? "项目正在废纸篓中运行，请先退出相关应用。" : nil
                        }, persist: persistence.record)
                }.value
                self?.acceptRecord(restored); self?.processingCompleted += 1
                if persistence.error != nil { break }
            }
            self?.finishProcessing(error: persistence.error)
        }
    }
    func executePurge(batchID: UUID) {
        guard dialog == .purge(batchID), acknowledgement, !isBusy, !frozenForQuit, historyError == nil, let historyStore else { return }
        let selected = records.filter { $0.operationID == batchID && $0.canPurge }
        guard !selected.isEmpty else { return }
        closeDialog(); beginProcessing(count: selected.count); currentOperationID = batchID
        let token = cancellation, persistence = SpaceCleaningPersistence(store: historyStore, cancellation: cancellation)
        let home = homeDirectory, runtime = runtime, declarations = declarations
        task = Task { [weak self] in
            for record in selected {
                guard !token.isCancelled else { break }
                self?.processingItem = record.candidate.title
                let purged = await Task.detached(priority: .utility) {
                    SpaceCleaningTransaction.purge(record: record, permanentConfirmed: true, isCancelled: { false },
                        validatePolicy: { candidate in
                            let context = Self.context(home: home, runtime: runtime, declarations: declarations)
                            if let location = record.locationURL, Self.runningAt(location, context: context) { return "项目正在废纸篓中运行，请先退出相关应用。" }
                            return SpaceCleaningScanner.validatePolicy(candidate: candidate, context: context) == .unchanged ? nil : "当前用途或运行状态受保护，未永久删除。"
                        }, persist: persistence.record)
                }.value
                self?.acceptRecord(purged); self?.processingCompleted += 1
                if persistence.error != nil { break }
            }
            self?.finishProcessing(error: persistence.error)
        }
    }
    private func beginProcessing(count: Int) {
        cancellation = StorageReviewCancellation(); selectedIDs = []; requiresRescan = true; detailID = nil
        currentBatch = nil; processingCompleted = 0; processingTotal = count; processingItem = "正在核验所选项目"; screen = .processing
    }
    private func finishProcessing(error: String?) {
        if let error { historyError = error; message = "处理记录未能安全保存，已暂停后续操作。" + error }
        else if cancellation.isCancelled { message = "已停止后续处理。另有 \(max(0, processingTotal - processingCompleted)) 项未开始；实际处理结果与可恢复项目见下方记录。" }
        else { message = nil }
        rebuildBatches(); task = nil; screen = .finished; refreshDisk()
    }
    private func loadHistory() {
        do {
            let store = try SpaceCleaningHistoryStore(fileURL: dataDirectory.appendingPathComponent("history.json"))
            historyStore = store; records = store.records; rebuildBatches()
            reconcileHistory()
        } catch { historyError = error.localizedDescription; message = "清理历史无法读取，原文件已保留；扫描仍可使用，文件处理已暂停。" }
    }
    private func reconcileHistory() {
        guard !isBusy, !frozenForQuit, historyError == nil, let store = historyStore else { return }
        let uncertain = records.filter { [.prepared, .isolated, .trashed, .deleting, .restoring].contains($0.state) }
        guard !uncertain.isEmpty else { return }
        cancellation = StorageReviewCancellation(); isReconcilingHistory = true
        let token = cancellation, persistence = SpaceCleaningPersistence(store: store, cancellation: cancellation)
        task = Task { [weak self] in
            for record in uncertain {
                guard !token.isCancelled else { break }
                let checked = await Task.detached(priority: .utility) {
                    SpaceCleaningTransaction.reconcile(record, isCancelled: { token.isCancelled })
                }.value
                guard !token.isCancelled else { break }
                if checked != record {
                    do { try persistence.record(checked) } catch { break }
                    self?.acceptRecord(checked)
                }
            }
            if let error = persistence.error { self?.historyError = error; self?.message = error; self?.rebuildBatches() }
            if token.isCancelled { self?.message = "历史核验已停止，原记录保持不变；执行恢复或删除前仍会重新核对。" }
            self?.task = nil; self?.isReconcilingHistory = false; self?.objectWillChange.send()
        }
        objectWillChange.send()
    }
    private func acceptRecord(_ record: SpaceCleaningRecord) {
        records.removeAll { $0.id == record.id }; records.append(record); rebuildBatches()
    }
    private func rebuildBatches() {
        batches = Dictionary(grouping: records, by: \.operationID).map { id, entries in
            let entries = entries.sorted { $0.createdAt < $1.createdAt }
            return CleaningHistoryBatchDisplay(id: id, date: entries.first!.createdAt, method: entries.first!.method,
                items: entries.map { record in
                    CleaningHistoryItemDisplay(id: record.id, name: record.candidate.title, bytes: record.candidate.logicalBytes,
                        statusText: Self.stateTitle(record.state), explanation: record.explanation + (record.state == .needsReview ? record.previousTrashURL.map { " 上次废纸篓位置：" + $0.path } ?? "" : ""),
                        canRestore: record.canRestore && historyError == nil, canPurge: record.canPurge && historyError == nil,
                        originalURL: record.originalURL, resultURL: record.restoredURL ?? record.locationURL)
                }, bytes: entries.reduce(0) { $0 &+ $1.candidate.logicalBytes })
        }.sorted { $0.date > $1.date }
        currentBatch = batches.first { $0.id == currentOperationID }
    }
    private static func stateTitle(_ state: SpaceCleaningRecordState) -> String {
        switch state {
        case .prepared: "等待核验"
        case .isolated: "等待核对"
        case .trashed: "在废纸篓"
        case .deleting: "等待核对"
        case .deleted: "已永久删除"
        case .restoring: "等待核对"
        case .restored: "已恢复"
        case .skipped: "已跳过"
        case .cancelled: "已取消"
        case .failed: "处理失败"
        case .needsReview: "需要手动核对"
        }
    }
    private nonisolated static func display(_ item: SpaceCleaningCandidate) -> CleaningItemDisplay {
        .init(id: item.id, name: item.title, url: item.url, bytes: item.logicalBytes, sizeIsComplete: item.sizeIsComplete,
              group: CleaningResultGroup(rawValue: item.group.rawValue) ?? .protected,
              subtitle: item.url.deletingLastPathComponent().path, reason: item.reason, impact: item.impact,
              isSelectable: item.canProcess, needsPurposeConfirmation: item.canConfirmTestPurpose)
    }
    private func selectedScopes(_ context: SpaceCleaningContext) -> [SpaceCleaningScope] {
        let scopes = SpaceCleaningScanner.recommendedScopes(context: context)
        switch scopeChoice {
        case .recommended: return scopes
        case .xcode: return scopes.filter { [.derivedData, .development, .archives, .releaseArchiveDiscovery, .releaseArchives].contains($0.kind) }
        case .downloads: return scopes.filter { $0.kind == .downloads }
        case .custom: return customDirectory.map { [.init(directory: $0, kind: .custom, title: $0.lastPathComponent)] } ?? []
        }
    }
    private nonisolated static func runningAt(_ url: URL, context: SpaceCleaningContext) -> Bool {
        let path = url.standardizedFileURL.path
        return context.runningApplicationURLs.contains {
            let running = $0.standardizedFileURL.path
            return running == path || running.hasPrefix(path + "/") || path.hasPrefix(running + "/")
        }
    }
    private func makeContext() -> SpaceCleaningContext { Self.context(home: homeDirectory, runtime: runtime, declarations: declarations) }
    private nonisolated static func context(home: URL, runtime: SpaceCleaningRuntimeContext, declarations: [SpaceCleaningTestDeclaration]) -> SpaceCleaningContext {
        .init(homeDirectory: home, runningApplicationURLs: runtime.runningURLs(), testDeclarations: declarations,
              activeToolNames: SpaceCleaningRuntimeContext.activeTools())
    }
    private func scanLanes(_ scopes: [SpaceCleaningScope]) -> [CleaningScanLane] {
        let definitions: [(SpaceCleaningStage, String, String)] = [(.caches, "应用缓存", "square.stack.3d.up"), (.development, "开发与构建", "hammer"), (.downloads, "下载与大文件", "arrow.down.doc"), (.protection, "归档与保护核验", "checkmark.shield")]
        let stages = Set(scopes.map(Self.stage))
        return definitions.filter { stages.contains($0.0) }.map {
            .init(id: $0.0.rawValue, title: $0.1, systemImage: $0.2, state: .pending, checkedCount: 0, path: "等待扫描", currentFile: "", decision: "")
        }
    }
    private nonisolated static func stage(_ scope: SpaceCleaningScope) -> SpaceCleaningStage {
        switch scope.kind {
        case .browserCache, .packageCache, .diagnostics: .caches
        case .derivedData, .development: .development
        case .downloads, .custom: .downloads
        case .archives, .releaseArchives, .releaseArchiveDiscovery, .installedApplications: .protection
        }
    }
    private func acceptProgress(_ progress: SpaceCleaningProgress, counts: [String: Int]) {
        checkedCount = progress.checkedEntries
        guard let index = lanes.firstIndex(where: { $0.id == progress.stage.rawValue }) else { return }
        for i in lanes.indices where i < index { lanes[i].state = .complete }
        lanes[index].state = .active
        for i in lanes.indices { lanes[i].checkedCount = counts[lanes[i].id] ?? 0 }
        lanes[index].path = progress.currentPath ?? "正在检查目录"
        lanes[index].currentFile = progress.currentFileName ?? ""
        lanes[index].decision = "已识别 \(progress.recordedCandidates) 项"
        completedStageCount = lanes.filter { $0.state == .complete }.count
    }

    private struct Preferences: Codable { var format = 1; var method: SpaceCleaningMethod }
    private func loadPreferences() {
        guard FileManager.default.fileExists(atPath: preferenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: preferenceURL)
            guard data.count < 64 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let saved = try JSONDecoder().decode(Preferences.self, from: data)
            guard saved.format == 1 else { throw CocoaError(.fileReadCorruptFile) }
            method = saved.method; rememberMethod = true
        } catch { preferencesWritable = false; message = "清理偏好无法读取，原文件已保留；本次默认移到废纸篓。" }
    }
    private func clearPreference() {
        guard preferencesWritable else { return }
        do {
            if FileManager.default.fileExists(atPath: preferenceURL.path) { try FileManager.default.removeItem(at: preferenceURL) }
            method = .trash; rememberMethod = false
        } catch { message = "本次选择仍有效，但已保存的处理方式未能取消。" }
    }
    private func savePreference(_ method: SpaceCleaningMethod) {
        guard preferencesWritable else { message = "原偏好文件无法读取，本次选择不覆盖原文件。"; return }
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Preferences(method: method)).write(to: preferenceURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferenceURL.path)
            self.method = method; rememberMethod = true
        } catch { message = "本次选择仍有效，但处理方式未能保存：\(error.localizedDescription)" }
    }
    private func updateRunningApplications() {
        runtime.setRunning(NSWorkspace.shared.runningApplications.compactMap(\.bundleURL))
    }
}

private final class SpaceCleaningRuntimeContext: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [URL] = []
    func setRunning(_ urls: [URL]) { lock.lock(); running = urls; lock.unlock() }
    func runningURLs() -> [URL] { lock.lock(); defer { lock.unlock() }; return running }
}

private final class SpaceCleaningPersistence: @unchecked Sendable {
    let store: SpaceCleaningHistoryStore
    let cancellation: StorageReviewCancellation
    private let lock = NSLock()
    private var problem: String?
    init(store: SpaceCleaningHistoryStore, cancellation: StorageReviewCancellation) { self.store = store; self.cancellation = cancellation }
    var error: String? { lock.lock(); defer { lock.unlock() }; return problem }
    func record(_ record: SpaceCleaningRecord) throws {
        do { try store.record(record) }
        catch { lock.lock(); problem = error.localizedDescription; lock.unlock(); cancellation.cancel(); throw error }
    }
}

extension SpaceCleaningRuntimeContext {
    static func activeTools() -> Set<String> {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0, estimate < 1_000_000 else { return ["xcodebuild", "npm"] }
        var ids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = ids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return ["xcodebuild", "npm"] }
        var result = Set<String>()
        for pid in ids.prefix(min(Int(count), ids.count)) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 1024)
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { result.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
        }
        return result
    }
}
