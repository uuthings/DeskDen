import AppKit
import Combine
import Foundation
import LauncherCore
import Quartz

@MainActor final class SpaceCleaningModel: NSObject, ObservableObject, @preconcurrency QLPreviewPanelDataSource {
    @Published var screen: CleaningScreen = .start
    @Published var scopeChoice: CleaningScopeChoice = .global
    @Published private(set) var scanMode: SpaceCleaningScanMode = .cleanup
    @Published var minimumFileSize = "100"
    @Published var maximumFileSize = ""
    @Published var fileSizeUnit: CleaningFileSizeUnit = .mb
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
    @Published private(set) var checkedCount = 0
    @Published private(set) var diskVolumeName: String?
    @Published private(set) var diskTotal: UInt64?
    @Published private(set) var diskAvailable: UInt64?
    @Published private(set) var diskImmediatelyFree: UInt64?
    @Published private(set) var diskReclaimableEstimate: UInt64?
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
    @Published private(set) var customDirectories: [URL] = []
    @Published var draftScope: CleaningScopeChoice = .global
    @Published private(set) var draftDirectories: [URL] = []
    @Published var resultTab: CleaningResultTab = .recommended
    @Published private(set) var recommendedIDs = Set<UUID>()
    @Published private(set) var automaticallySelectedIDs = Set<UUID>()
    @Published var sortKey: CleaningSortKey = .size
    @Published var sortAscending = false
    @Published var searchText = ""
    @Published var onlySelected = false
    @Published var resultScrollID: UUID?
    @Published private(set) var scanPhase: SpaceCleaningScanPhase = .discovering
    @Published private(set) var scanCompletedItems = 0
    @Published private(set) var scanTotalItems: Int?
    @Published private(set) var scanDirectory = ""
    @Published private(set) var scanItem = ""
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var purposeReviewID: UUID?
    @Published private(set) var measuringDirectoryID: UUID?
    @Published private(set) var directorySizes: [UUID: SpaceCleaningDirectorySize] = [:]
    private var securityScopedDirectories: [URL] = []
    private var scopeOrigin: CleaningScreen = .start
    private var operationDestination: CleaningScreen = .start
    private var scopePreferencesWritable = true
    private var task: Task<Void, Never>?
    private var cancellation = SpaceCleaningCancellation()
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
    private var hasSavedMethod = false
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
        loadScopePreference()
        loadScanPreference()
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
    var selectedAllocatedBytes: UInt64 { selectedItems.reduce(0) { $0 &+ $1.allocatedBytes } }
    var selectedCount: Int { selectedItems.count }
    var isBusy: Bool { task != nil }
    var canProcess: Bool { !isBusy && !frozenForQuit && !requiresRescan && historyError == nil && selectedCount > 0 }
    var animationActive: Bool { windowVisible && [.start, .scope, .scanning].contains(screen) && !reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && dialog == nil }
    var scopeSummary: String {
        (scanMode == .largeFiles ? "大文件 · " : "") + (scopeChoice == .global ? "全局扫描 · 当前用户可访问位置" : "自定义位置 · \(customDirectories.count) 个文件夹")
    }
    var largeFileRangeError: String? {
        guard scanMode == .largeFiles else { return nil }
        guard let minimum = fileSizeBytes(minimumFileSize) else { return "请输入大于 0 的有效最小大小。" }
        if !maximumFileSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let maximum = fileSizeBytes(maximumFileSize), maximum >= minimum else { return "最大大小须不小于最小大小，或留空表示不限。" }
        }
        return nil
    }
    private func fileSizeBytes(_ value: String) -> UInt64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let number = Double(trimmed), number.isFinite else { return nil }
        let bytes = (number * fileSizeUnit.bytes).rounded(.up)
        guard bytes >= 1, bytes < Double(UInt64.max) else { return nil }
        return UInt64(bytes)
    }
    func selectScanMode(_ mode: SpaceCleaningScanMode) {
        guard !isBusy, scanMode != mode else { return }
        scanMode = mode; invalidateResults(); saveScanPreference()
    }
    func setLargeFilePreset(_ minimum: String, unit: CleaningFileSizeUnit) {
        guard !isBusy else { return }
        minimumFileSize = minimum; maximumFileSize = ""; fileSizeUnit = unit
        scanSettingsChanged()
    }
    func scanSettingsChanged() {
        guard !isBusy else { return }
        if screen != .scope { invalidateResults() }
        saveScanPreference()
    }
    var reviewableItems: [CleaningItemDisplay] { items.filter { $0.group != .protected } }
    var recommendedItems: [CleaningItemDisplay] { items.filter { recommendedIDs.contains($0.id) } }
    var otherItems: [CleaningItemDisplay] { reviewableItems.filter { !recommendedIDs.contains($0.id) } }
    var protectedItems: [CleaningItemDisplay] { items.filter { $0.group == .protected } }
    var visibleItems: [CleaningItemDisplay] {
        let source: [CleaningItemDisplay]
        if onlySelected { source = selectedItems }
        else {
            switch resultTab {
            case .recommended: source = recommendedItems
            case .reviewable: source = otherItems
            case .protected: source = protectedItems
            }
        }
        return source.filter {
            searchText.isEmpty || $0.name.localizedStandardContains(searchText) || $0.url.path.localizedStandardContains(searchText)
        }.sorted(by: resultPrecedes)
    }
    func sortResults(by key: CleaningSortKey) {
        guard !isBusy, dialog != .confirm else { return }
        if sortKey == key { sortAscending.toggle() }
        else { sortKey = key; sortAscending = ![.modified, .size].contains(key) }
        resultScrollID = nil
    }
    private func resultPrecedes(_ lhs: CleaningItemDisplay, _ rhs: CleaningItemDisplay) -> Bool {
        let comparison: ComparisonResult
        switch sortKey {
        case .name: comparison = lhs.name.localizedStandardCompare(rhs.name)
        case .directory: comparison = lhs.url.deletingLastPathComponent().path.localizedStandardCompare(rhs.url.deletingLastPathComponent().path)
        case .type: comparison = lhs.typeTitle.localizedStandardCompare(rhs.typeTitle)
        case .modified: comparison = lhs.modifiedDate == rhs.modifiedDate ? .orderedSame : lhs.modifiedDate < rhs.modifiedDate ? .orderedAscending : .orderedDescending
        case .size: comparison = lhs.bytes == rhs.bytes ? .orderedSame : lhs.bytes < rhs.bytes ? .orderedAscending : .orderedDescending
        }
        if comparison != .orderedSame { return comparison == (sortAscending ? .orderedAscending : .orderedDescending) }
        // Equal primary values retain an ascending identity order even when
        // reversing the column, preventing selection and review rows jumping.
        let leftPath = lhs.url.standardizedFileURL.path, rightPath = rhs.url.standardizedFileURL.path
        let pathComparison = leftPath.localizedStandardCompare(rightPath)
        if pathComparison != .orderedSame { return pathComparison == .orderedAscending }
        if leftPath != rightPath { return leftPath < rightPath }
        return lhs.id.uuidString < rhs.id.uuidString
    }
    func showResults(_ tab: CleaningResultTab) {
        resultTab = tab; onlySelected = false; detailID = nil; resultScrollID = nil
        if case .purpose = dialog { closeDialog() }
    }
    func toggleSelectedFilter() {
        onlySelected.toggle()
        if onlySelected { searchText = "" }
        detailID = nil; resultScrollID = nil
    }
    var noRecommendationsSummary: String {
        if requiresRescan { return "本次扫描未完成，请重新扫描后再清理。" }
        if scanMode == .largeFiles { return scanReachedLimit ? "本次覆盖范围有限；已检查位置中未发现符合大小范围的可复核文件。" : "已检查位置中未发现符合大小范围的可复核文件。开发环境及受保护位置保持保留。" }
        if scanReachedLimit { return "本次扫描达到覆盖边界；已完整核验的内容中暂未发现建议整理的项目。" }
        let inUse = items.filter { $0.kind == .runningApplication }.count
        if inUse > 0 { return "有 \(inUse) 项关联应用或工具正在使用，已保留。其他文件由你选择。" }
        if !coverageIssues.isEmpty { return "部分位置未能完整检查；已检查内容中暂未发现符合整理规则的项目。" }
        return "暂未发现可重建缓存、待整理安装介质或过期诊断记录；其他文件可自行选择。"
    }
    var visibleSelectableIDs: Set<UUID> { Set(visibleItems.filter(\.isSelectable).map(\.id)) }
    var scanFraction: Double? { scanTotalItems.flatMap { $0 > 0 ? min(1, Double(scanCompletedItems) / Double($0)) : nil } }
    func shortPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path, home = homeDirectory.standardizedFileURL.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    func toggleVisibleSelection() {
        guard !isBusy, !requiresRescan else { return }
        let ids = visibleSelectableIDs
        if ids.isSubset(of: selectedIDs) { selectedIDs.subtract(ids) } else { selectedIDs.formUnion(ids) }
    }
    func clearSelection() { guard !isBusy else { return }; selectedIDs = [] }
    func goHome() { guard !isBusy else { return }; closeDialog(); screen = .start }
    var reportSummary: String {
        if requiresRescan { return "文件状态已变化，请重新扫描后再选择" }
        if screen == .scanning { return "已检查 \(checkedCount) 项 · 逐项核验用途与保护规则" }
        if scanMode == .largeFiles { return "找到 \(reviewableItems.count) 个符合大小范围的文件 · 均需手动选择" + (scanReachedLimit ? " · 覆盖范围有限" : "") }
        if recommendedIDs.isEmpty { return noRecommendationsSummary }
        let manualCount = recommendedIDs.subtracting(automaticallySelectedIDs).count
        let selection = automaticallySelectedIDs.isEmpty
            ? "这 \(manualCount) 项需确认后手动选择"
            : "\(automaticallySelectedIDs.count) 项可重建缓存已预选" + (manualCount > 0 ? "，另有 \(manualCount) 项需手动选择" : "")
        return "找到 \(recommendedIDs.count) 项建议整理内容 · " + selection + (scanReachedLimit ? " · 覆盖范围有限" : "")
    }
    func toggleItem(_ id: UUID) {
        guard !isBusy, !requiresRescan, items.contains(where: { $0.id == id && $0.isSelectable }) else { return }
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }
    func selectRecommended() {
        guard !isBusy, !requiresRescan, scanMode == .cleanup else { return }
        let context = makeContext()
        selectedIDs.formUnion(candidates.values.filter {
            $0.isRecommendedForSelection && SpaceCleaningScanner.validatePolicy(candidate: $0, context: context) == .unchanged
        }.map(\.id))
    }
    func showDetail(_ id: UUID) { detailID = detailID == id ? nil : id; acknowledgement = false; if case .purpose = dialog { closeDialog() } }
    func closeDetail() { detailID = nil }
    func showHistory() { guard !isBusy else { return }; previousScreen = screen; screen = .history; reconcileHistory() }
    var historyReturnTitle: String { "返回" + screenTitle(previousScreen == .history || requiresRescan ? .start : previousScreen) }
    var dialogReturnTitle: String { "返回" + screenTitle(screen) }
    private func screenTitle(_ screen: CleaningScreen) -> String {
        switch screen {
        case .history: "清理记录"
        case .results: "扫描结果"
        case .completed: "处理结果"
        case .scanning: "正在扫描"
        case .processing: "正在处理"
        case .start, .scope: "空间清理"
        }
    }
    func returnFromHistory() { guard !isBusy else { return }; screen = previousScreen == .history || requiresRescan ? .start : previousScreen }
    func closeDialog() { dialog = nil; confirmedIDs = []; pendingHistoryIDs = []; acknowledgement = false }
    func editScope(custom: Bool = false) {
        guard !isBusy else { return }
        scopeOrigin = screen; draftScope = custom ? .custom : scopeChoice
        draftDirectories = customDirectories; screen = .scope
    }
    func cancelScope() { guard !isBusy else { return }; draftDirectories = []; releaseUnusedScopeAccess(); screen = scopeOrigin }
    func selectScope(_ choice: CleaningScopeChoice) {
        guard !isBusy else { return }
        if choice == .custom { editScope(custom: true); return }
        guard scopeChoice != choice else { return }
        scopeChoice = choice; invalidateResults(); saveScopePreference()
    }
    func addDraftDirectories(_ urls: [URL]) {
        guard screen == .scope, !isBusy else { return }
        for url in urls where !draftDirectories.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            guard draftDirectories.count < 128 else { message = "最多选择 128 个位置。"; break }
            let normalized = url.standardizedFileURL
            guard normalized.isFileURL else { continue }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &directory), directory.boolValue,
                  (try? normalized.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            if !securityScopedDirectories.contains(url), url.startAccessingSecurityScopedResource() { securityScopedDirectories.append(url) }
            draftDirectories.append(url)
        }
        // Parent scopes already cover their descendants; never count or process twice.
        draftDirectories = draftDirectories.filter { child in
            !draftDirectories.contains { parent in parent != child && child.standardizedFileURL.path.hasPrefix(parent.standardizedFileURL.path + "/") }
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    func removeDraftDirectory(_ url: URL) { draftDirectories.removeAll { $0 == url } }
    func applyScope() {
        guard screen == .scope, !isBusy, draftScope == .global || !draftDirectories.isEmpty else { return }
        let changed = draftScope != scopeChoice || (draftScope == .custom && draftDirectories != customDirectories)
        scopeChoice = draftScope; customDirectories = draftDirectories
        if changed { invalidateResults() } else { screen = scopeOrigin }
        saveScopePreference(); releaseUnusedScopeAccess()
    }
    func chooseCustomDirectory() {
        guard !isBusy, !frozenForQuit, screen == .scope else { return }
        let panel = NSOpenPanel()
        panel.title = "添加扫描位置"; panel.prompt = "添加位置"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard result == .OK else { return }; self?.addDraftDirectories(panel.urls)
        }
        if let hostWindow { panel.beginSheetModal(for: hostWindow, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
    private func invalidateResults() {
        selectedIDs = []; recommendedIDs = []; automaticallySelectedIDs = []; detailID = nil; resultScrollID = nil; candidates = [:]; items = []
        directorySizes = [:]; measuringDirectoryID = nil
        requiresRescan = false; screen = .start; message = historyError
    }
    /// Selecting files and clicking the clearly named Trash action is the user's
    /// confirmation. Keep the same selection snapshot and verified transaction.
    func requestCleanup() {
        guard canProcess else { return }
        requestConfirmation()
        if method == .trash { executeConfirmed(permanent: false, remember: rememberMethod) }
    }
    func chooseMethod(_ choice: SpaceCleaningMethod) {
        guard !isBusy, !frozenForQuit, dialog != .confirm else { return }
        method = choice
        if rememberMethod { savePreference(choice) }
    }
    func setRememberMethod(_ remember: Bool) {
        guard !isBusy, !frozenForQuit, dialog != .confirm else { return }
        if remember { savePreference(method) }
        else if hasSavedMethod { clearPreference() }
        else { rememberMethod = false }
    }
    private func requestConfirmation() {
        guard canProcess else { return }
        confirmedIDs = Set(selectedItems.map(\.id)); acknowledgement = false; dialog = .confirm
    }
    func requestTestPurpose(_ id: UUID) {
        guard !isBusy, !requiresRescan, items.contains(where: { $0.id == id && $0.needsPurposeConfirmation }) else { return }
        detailID = id; acknowledgement = false; dialog = .purpose(id); resultScrollID = id
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
    func cancelDirectorySize() { cancellation.cancel() }
    func measureDirectorySize(_ id: UUID) {
        guard !isBusy, !frozenForQuit, let candidate = candidates[id], candidate.kind == .developmentEnvironment,
              candidate.isDirectory, candidate.group == .protected else { return }
        cancellation = SpaceCleaningCancellation(); let token = cancellation
        generation = UUID(); let run = generation
        measuringDirectoryID = id; directorySizes[id] = .init()
        task = Task { [weak self] in
            let size = await Task.detached(priority: .utility) {
                SpaceCleaningDirectorySizeScanner.measure(directory: candidate.url, expectedIdentity: candidate.identity,
                    isCancelled: { token.isCancelled }) { update in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == run, self.measuringDirectoryID == id else { return }
                            self.directorySizes[id] = update
                        }
                    }
            }.value
            guard let self, self.generation == run else { return }
            self.directorySizes[id] = size; self.measuringDirectoryID = nil; self.task = nil
        }
    }
    func cancelHistoryVerification() { cancellation.cancel(); message = "正在停止历史核验，原记录保持不变。" }
    func cancelProcessing() { cancellation.cancel(); message = "正在完成当前文件的安全收尾，其余项目将取消。" }
    func cancelAll() { cancellation.cancel(); closeDialog() }
    func waitUntilIdle() async { if let task { await task.value } }
    func prepareForQuit() async {
        frozenForQuit = true; cancelAll()
        if let task { await task.value }
        securityScopedDirectories.forEach { $0.stopAccessingSecurityScopedResource() }; securityScopedDirectories = []
    }
    func resumeAfterCancelledQuit() { frozenForQuit = false }
    func refreshDisk() {
        let root = homeDirectory
        Task { [weak self] in
            let capacity = await Task.detached(priority: .utility) { DeviceStorageCapacity.read(at: root) }.value
            guard let self else { return }
            self.diskVolumeName = capacity?.volumeName; self.diskTotal = capacity?.total; self.diskAvailable = capacity?.available
            self.diskImmediatelyFree = capacity?.immediatelyFree; self.diskReclaimableEstimate = capacity?.reclaimableEstimate
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
        guard largeFileRangeError == nil else { message = largeFileRangeError; return }
        let context = makeContext()
        let options = SpaceCleaningOptions(mode: scanMode, minimumFileBytes: fileSizeBytes(minimumFileSize) ?? 100_000_000,
                                           maximumFileBytes: fileSizeBytes(maximumFileSize))
        let scopes = selectedScopes(context)
        guard !scopes.isEmpty else { message = "请先选择要扫描的目录。"; return }
        generation = UUID(); let run = generation
        cancellation = SpaceCleaningCancellation(); let token = cancellation
        selectedIDs = []; confirmedIDs = []; detailID = nil; resultScrollID = nil; searchText = ""; onlySelected = false; resultTab = .recommended; items = []; recommendedIDs = []; automaticallySelectedIDs = []; candidates = [:]
        directorySizes = [:]; measuringDirectoryID = nil
        if scanMode == .largeFiles { resultTab = .reviewable; sortKey = .size; sortAscending = false }
        coverageIssues = []; coverageNotes = []; scanReachedLimit = false; requiresRescan = false; checkedCount = 0; scanPhase = .discovering; scanCompletedItems = 0; scanTotalItems = nil; scanDirectory = ""; scanItem = ""
        closeDialog(); message = historyError; screen = .scanning
        task = Task { [weak self] in
            let report = await Task.detached(priority: .utility) {
                var lastUpdate = Date.distantPast
                let report = SpaceCleaningScanner.scan(scopes: scopes, context: context, options: options, isCancelled: { token.isCancelled }) { progress in
                    guard Date().timeIntervalSince(lastUpdate) >= 0.08 || [.complete, .cancelled, .failed].contains(progress.stage) else { return }
                    lastUpdate = Date()
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == run, self.screen == .scanning else { return }
                        self.acceptProgress(progress)
                    }
                }
                return report
            }.value
            guard let self, self.generation == run else { return }
            self.checkedCount = report.checkedEntries
            self.coverageIssues = report.issues.filter { ![.missing, .duplicate].contains($0.kind) }.map { $0.url.path.replacingOccurrences(of: self.homeDirectory.path, with: "~") + " · " + $0.reason }
            self.coverageNotes = report.scopes.map { $0.title + " · " + $0.directory.path.replacingOccurrences(of: self.homeDirectory.path, with: "~") }
            self.coverageNotes.append("开发依赖、Git 资料与虚拟环境默认保留，未展开的目录不计入已知容量。")
            if options.mode == .largeFiles {
                self.coverageNotes.append("普通文件大小 ≥ " + SpaceCleaningFormat.bytes(options.minimumFileBytes) +
                    (options.maximumFileBytes.map { "，且 ≤ " + SpaceCleaningFormat.bytes($0) } ?? "；无上限") + "。包与受保护目录不展开。")
            }
            self.coverageNotes += report.issues.filter { [.missing, .duplicate].contains($0.kind) }.map { $0.url.path.replacingOccurrences(of: self.homeDirectory.path, with: "~") + " · " + $0.reason }
            self.candidates = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.id, $0) })
            self.items = report.candidates.map(Self.display).sorted {
                if $0.group != $1.group { return CleaningResultGroup.allCases.firstIndex(of: $0.group)! < CleaningResultGroup.allCases.firstIndex(of: $1.group)! }
                return $0.bytes == $1.bytes ? $0.url.path < $1.url.path : $0.bytes > $1.bytes
            }
            self.requiresRescan = [.cancelled, .failed].contains(report.stage)
            self.scanReachedLimit = report.reachedLimit
            self.lastScanDate = report.finishedAt
            if report.stage == .complete { self.selectRecommendedAfterScan(context: self.makeContext()) }
            if self.requiresRescan { self.message = report.stage == .cancelled ? "扫描已停止。当前结果仅供查看，请完成一次扫描后再清理。" : "扫描未完整结束，已保留检查结果。请调整范围后重新扫描。" }
            else if report.reachedLimit { self.message = "本次覆盖范围受限。仅完整核验且可处理的项目能够选择；缩小范围可继续查看其余内容。" }
            self.task = nil; self.screen = .results; self.refreshDisk()
        }
    }
    func confirmTestPurpose(_ id: UUID) {
        guard !isBusy, acknowledgement, dialog == .purpose(id), let candidate = candidates[id], candidate.canConfirmTestPurpose else { return }
        declarations.removeAll { $0.url == candidate.url }; declarations.append(.init(candidate: candidate))
        let context = makeContext(); cancellation = SpaceCleaningCancellation(); let token = cancellation
        purposeReviewID = id
        task = Task { [weak self] in
            let fresh = await Task.detached(priority: .utility) {
                SpaceCleaningScanner.reviewTestCandidate(candidate, context: context, isCancelled: { token.isCancelled })
            }.value
            guard let self else { return }
            if let fresh, let index = self.items.firstIndex(where: { $0.id == id }) {
                self.candidates[id] = fresh; self.items[index] = Self.display(fresh)
                self.resultTab = .reviewable; self.onlySelected = false; self.searchText = ""; self.resultScrollID = id
            } else {
                self.declarations.removeAll { $0.url == candidate.url }
                self.message = "文件身份、内容或保护状态已变化，继续保留；请重新扫描。"
            }
            self.task = nil; self.purposeReviewID = nil; self.closeDialog()
        }
    }
    private func selectRecommendedAfterScan(context: SpaceCleaningContext) {
        guard scanMode == .cleanup else { recommendedIDs = []; automaticallySelectedIDs = []; selectedIDs = []; return }
        recommendedIDs = Set(candidates.values.filter {
            $0.isCleanupSuggestion && SpaceCleaningScanner.validatePolicy(candidate: $0, context: context) == .unchanged
        }.map(\.id))
        automaticallySelectedIDs = Set(candidates.values.filter { recommendedIDs.contains($0.id) && $0.isRecommendedForSelection }.map(\.id))
        selectedIDs = automaticallySelectedIDs
    }
    func executeConfirmed(permanent: Bool, remember: Bool) {
        guard dialog == .confirm, canProcess, confirmedIDs == Set(selectedItems.map(\.id)),
              !permanent || acknowledgement, let historyStore else { return }
        let selected = selectedItems.compactMap { candidates[$0.id] }
        guard selected.count == confirmedIDs.count else { return }
        let chosen: SpaceCleaningMethod = permanent ? .permanent : .trash
        if remember { savePreference(chosen) } else if hasSavedMethod { clearPreference() }
        operationDestination = .completed; closeDialog(); beginProcessing(count: selected.count)
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
        operationDestination = .history; closeDialog(); beginProcessing(count: selected.count); currentOperationID = batchID
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
        operationDestination = .history; closeDialog(); beginProcessing(count: selected.count); currentOperationID = batchID
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
        cancellation = SpaceCleaningCancellation(); selectedIDs = []; requiresRescan = true; detailID = nil
        currentBatch = nil; processingCompleted = 0; processingTotal = count; processingItem = "正在核验所选项目"; screen = .processing
    }
    private func finishProcessing(error: String?) {
        if let error { historyError = error; message = "处理记录未能安全保存，已暂停后续操作。" + error }
        else if cancellation.isCancelled { message = "已停止后续处理。另有 \(max(0, processingTotal - processingCompleted)) 项未开始；实际处理结果与可恢复项目见下方记录。" }
        else { message = nil }
        rebuildBatches(); task = nil; screen = operationDestination; refreshDisk()
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
        cancellation = SpaceCleaningCancellation(); isReconcilingHistory = true
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
                        allocatedBytes: record.candidate.allocatedBytes,
                        state: record.state, statusText: Self.stateTitle(record.state), explanation: record.explanation + (record.state == .needsReview ? record.previousTrashURL.map { " 上次废纸篓位置：" + $0.path } ?? "" : ""),
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
        .init(id: item.id, name: item.title, url: item.url, bytes: item.logicalBytes, allocatedBytes: item.allocatedBytes, sizeIsComplete: item.sizeIsComplete,
              group: CleaningResultGroup(rawValue: item.group.rawValue) ?? .protected,
              subtitle: item.url.deletingLastPathComponent().path, reason: item.reason, impact: item.impact,
              isSelectable: item.canProcess, needsPurposeConfirmation: item.canConfirmTestPurpose,
              kind: item.kind, isDirectory: item.isDirectory,
              modifiedDate: Date(timeIntervalSince1970: Double(item.identity.modifiedSeconds) + Double(item.identity.modifiedNanoseconds) / 1_000_000_000))
    }
    private func selectedScopes(_ context: SpaceCleaningContext) -> [SpaceCleaningScope] {
        scopeChoice == .global ? SpaceCleaningScanner.globalScopes(context: context) :
            customDirectories.map { .init(directory: $0, title: $0.lastPathComponent) }
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
    private func acceptProgress(_ progress: SpaceCleaningProgress) {
        checkedCount = progress.checkedEntries; scanPhase = progress.phase
        scanCompletedItems = progress.completedItems; scanTotalItems = progress.totalItems
        if let path = progress.currentPath {
            let url = URL(fileURLWithPath: path)
            scanDirectory = shortPath(url)
            scanItem = progress.currentFileName ?? url.lastPathComponent
        }
    }
    private struct ScopePreference: Codable {
        var format = 1; var choice: CleaningScopeChoice; var bookmarks: [Data]
        var requestedPaths: [String]? = nil
    }
    private struct ScanPreference: Codable {
        var mode: SpaceCleaningScanMode; var minimum: String; var maximum: String; var unit: CleaningFileSizeUnit
    }
    private var scanPreferenceURL: URL { dataDirectory.appendingPathComponent("scan-options.json") }
    private var scanPreferencesWritable = true
    private func loadScanPreference() {
        guard FileManager.default.fileExists(atPath: scanPreferenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: scanPreferenceURL)
            guard data.count < 4096 else { throw CocoaError(.fileReadCorruptFile) }
            let value = try JSONDecoder().decode(ScanPreference.self, from: data)
            scanMode = value.mode; minimumFileSize = value.minimum; maximumFileSize = value.maximum; fileSizeUnit = value.unit
        } catch { scanPreferencesWritable = false; message = "扫描方式设置无法读取，原文件已保留；本次使用普通清理。" }
    }
    private func saveScanPreference() {
        guard scanPreferencesWritable else { return }
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let value = ScanPreference(mode: scanMode, minimum: minimumFileSize, maximum: maximumFileSize, unit: fileSizeUnit)
            try JSONEncoder().encode(value).write(to: scanPreferenceURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scanPreferenceURL.path)
        } catch { message = "扫描设置本次已生效，但未能保存。" }
    }
    private var scopePreferenceURL: URL { dataDirectory.appendingPathComponent("scope.json") }
    private func loadScopePreference() {
        guard FileManager.default.fileExists(atPath: scopePreferenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: scopePreferenceURL)
            guard data.count < 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let saved = try JSONDecoder().decode(ScopePreference.self, from: data)
            guard saved.format == 1, saved.bookmarks.count <= 128 else { throw CocoaError(.fileReadCorruptFile) }
            var resolved: [URL] = []
            for (index, bookmark) in saved.bookmarks.enumerated() {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                if url.startAccessingSecurityScopedResource() { securityScopedDirectories.append(url) }
                if let paths = saved.requestedPaths, paths.count == saved.bookmarks.count, paths[index].hasPrefix("/") {
                    let requested = URL(fileURLWithPath: paths[index], isDirectory: true)
                    // Preserve dependency names in a user-selected alias. A bookmark
                    // may resolve directly to its target and otherwise lose that policy.
                    if SpaceCleaningScanner.developmentProtectionReason(at: requested) != nil ||
                        SpaceCleaningScanner.canonicalURL(requested) == SpaceCleaningScanner.canonicalURL(url) {
                        resolved.append(requested)
                    } else { resolved.append(url) }
                } else { resolved.append(url) }
            }
            customDirectories = resolved; scopeChoice = saved.choice
        } catch {
            scopePreferencesWritable = false
            message = "扫描位置未能恢复，已保留原设置；本次使用全局扫描，可重新选择位置。"
        }
    }
    private func saveScopePreference() {
        guard scopePreferencesWritable else { return }
        do {
            let bookmarks = try customDirectories.map { try $0.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(ScopePreference(choice: scopeChoice, bookmarks: bookmarks, requestedPaths: customDirectories.map(\.path))).write(to: scopePreferenceURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scopePreferenceURL.path)
        } catch { message = "本次扫描位置已生效，但未能保存；下次需重新选择。" }
    }
    private func releaseUnusedScopeAccess() {
        func retained(_ url: URL) -> Bool {
            customDirectories.contains { $0 == url || (SpaceCleaningScanner.canonicalURL($0).map { $0 == SpaceCleaningScanner.canonicalURL(url) } ?? false) }
        }
        for url in securityScopedDirectories where !retained(url) { url.stopAccessingSecurityScopedResource() }
        securityScopedDirectories.removeAll { !retained($0) }
    }

    private struct Preferences: Codable { var format = 1; var method: SpaceCleaningMethod }
    private func loadPreferences() {
        guard FileManager.default.fileExists(atPath: preferenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: preferenceURL)
            guard data.count < 64 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let saved = try JSONDecoder().decode(Preferences.self, from: data)
            guard saved.format == 1 else { throw CocoaError(.fileReadCorruptFile) }
            method = saved.method; rememberMethod = true; hasSavedMethod = true
        } catch { preferencesWritable = false; message = "清理偏好无法读取，原文件已保留；本次默认移到废纸篓。" }
    }
    private func clearPreference() {
        guard preferencesWritable else { return }
        do {
            if FileManager.default.fileExists(atPath: preferenceURL.path) { try FileManager.default.removeItem(at: preferenceURL) }
            rememberMethod = false; hasSavedMethod = false
        } catch { message = "本次选择仍有效，但已保存的处理方式未能取消。" }
    }
    private func savePreference(_ method: SpaceCleaningMethod) {
        guard preferencesWritable else { message = "原偏好文件无法读取，本次选择不覆盖原文件。"; return }
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Preferences(method: method)).write(to: preferenceURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferenceURL.path)
            self.method = method; rememberMethod = true; hasSavedMethod = true
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
    let cancellation: SpaceCleaningCancellation
    private let lock = NSLock()
    private var problem: String?
    init(store: SpaceCleaningHistoryStore, cancellation: SpaceCleaningCancellation) { self.store = store; self.cancellation = cancellation }
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
