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
    @Published var selectedIDs = Set<UUID>() {
        didSet { if selectedIDs != oldValue { selectionChanged() } }
    }
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
    @Published private(set) var diskUpdatedAt: Date?
    @Published private(set) var coverageIssues: [String] = []
    @Published private(set) var coverageNotes: [String] = []
    /// Protected entries summarized in the scope notes instead of listed rows.
    @Published private(set) var summarizedProtectedCount = 0
    private var scanReachedLimit = false
    @Published private(set) var currentBatch: CleaningHistoryBatchDisplay?
    @Published private(set) var batches: [CleaningHistoryBatchDisplay] = []
    @Published private(set) var processingCompleted = 0
    @Published private(set) var processingTotal = 0
    @Published private(set) var processingItem = ""
    @Published private(set) var requiresRescan = false
    /// Results acted on since the scan; they leave the list while the rest
    /// stay selectable (see `retireResults`).
    @Published private(set) var retiredResultCount = 0
    @Published private(set) var isReconcilingHistory = false
    weak var hostWindow: NSWindow?

    let dataDirectory: URL
    let homeDirectory: URL
    private let preferenceURL: URL
    @Published private(set) var customDirectories: [URL] = []
    @Published private(set) var selectedScopeGroups: Set<CleaningScopeGroup> = []
    @Published private(set) var draftScopeGroups: Set<CleaningScopeGroup> = []
    @Published var draftScope: CleaningScopeChoice = .global
    @Published private(set) var draftDirectories: [URL] = []
    @Published var resultTab: CleaningResultTab = .recommended {
        didSet { if resultTab != oldValue { refreshResultProjection() } }
    }
    @Published private(set) var recommendedIDs = Set<UUID>()
    @Published private(set) var automaticallySelectedIDs = Set<UUID>()
    @Published var sortKey: CleaningSortKey = .size {
        didSet { if sortKey != oldValue { refreshResultProjection() } }
    }
    @Published var sortAscending = false {
        didSet { if sortAscending != oldValue { refreshResultProjection() } }
    }
    @Published var searchText = "" {
        didSet {
            if searchText != oldValue {
                resultScrollID = nil
                refreshResultProjection()
            }
        }
    }
    @Published var onlySelected = false {
        didSet { if onlySelected != oldValue { refreshResultProjection() } }
    }
    /// A programmatic scroll request only. Interactive scroll position belongs
    /// to the result view and must never invalidate the complete result model.
    var resultScrollID: UUID? { didSet { resultScrollResetID = UUID() } }
    @Published private(set) var resultScrollResetID = UUID()
    @Published private(set) var visibleItems: [CleaningItemDisplay] = []
    @Published private(set) var isUpdatingResults = false
    private(set) var visibleSelectableIDs = Set<UUID>()
    private(set) var allVisibleSelected = false
    private(set) var someVisibleSelected = false
    var visibleSelectableCount: Int { visibleSelectableIDs.count }
    private(set) var resultProjectionBuildCount = 0
    @Published private(set) var scanPhase: SpaceCleaningScanPhase = .discovering
    @Published private(set) var scanCompletedItems = 0
    @Published private(set) var scanTotalItems: Int?
    @Published private(set) var scanDirectory = ""
    @Published private(set) var scanItem = ""
    @Published private(set) var scanRecordedCandidates = 0
    @Published private(set) var scanLogicalBytes: UInt64 = 0
    @Published private(set) var scanCompletedScopes = 0
    @Published private(set) var scanTotalScopes = 0
    @Published private(set) var scanRecentPaths: [String] = []
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
    private var resultIndex = CleaningResultsIndex()
    private var resultProjectionCache: [CleaningResultsQuery: CleaningResultsProjection] = [:]
    private var resultProjectionOrder: [CleaningResultsQuery] = []
    private var resultProjectionTask: Task<Void, Never>?
    private var resultProjectionWork: Task<CleaningResultsProjection?, Never>?
    private var resultProjectionGeneration: UInt64 = 0
    private var selectionRevision: UInt64 = 0
    private var selectedItemCache: [CleaningItemDisplay] = []
    private var selectedByteCache: UInt64 = 0
    private var selectedAllocatedByteCache: UInt64 = 0
    private var suspendsResultProjection = false

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

    var detail: CleaningItemDisplay? { detailID.flatMap { resultIndex.item($0) } }
    var pendingHistoryItems: [CleaningHistoryItemDisplay] { batches.flatMap(\.items).filter { pendingHistoryIDs.contains($0.id) } }
    var selectedItems: [CleaningItemDisplay] { selectedItemCache }
    var selectedBytes: UInt64 { selectedByteCache }
    var selectedAllocatedBytes: UInt64 { selectedAllocatedByteCache }
    var selectedCount: Int { selectedItemCache.count }
    var isBusy: Bool { task != nil }
    var canProcess: Bool { !isBusy && !frozenForQuit && !requiresRescan && historyError == nil && selectedCount > 0 }
    var animationActive: Bool { windowVisible && [.start, .scope, .scanning].contains(screen) && !reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && dialog == nil }
    var scopeSummary: String {
        let custom = [selectedScopeGroups.isEmpty ? nil : "\(selectedScopeGroups.count) 类位置",
                      customDirectories.isEmpty ? nil : "\(customDirectories.count) 个文件夹"].compactMap { $0 }.joined(separator: " · ")
        return (scanMode == .largeFiles ? "大文件 · " : "") + (scopeChoice == .global ? "全局扫描 · 当前用户可访问位置" : "自定义范围 · " + (custom.isEmpty ? "未选择位置" : custom))
    }
    var canScanScope: Bool { scopeChoice == .global || !selectedScopeGroups.isEmpty || !customDirectories.isEmpty }
    var canApplyScope: Bool { draftScope == .global || !draftScopeGroups.isEmpty || !draftDirectories.isEmpty }
    func includesScopeGroup(_ group: CleaningScopeGroup, draft: Bool = false) -> Bool {
        (draft ? draftScope : scopeChoice) == .global || (draft ? draftScopeGroups : selectedScopeGroups).contains(group)
    }
    func setDraftScopeGroup(_ group: CleaningScopeGroup, selected: Bool) {
        guard screen == .scope, !isBusy, !frozenForQuit, draftScope == .custom else { return }
        if selected { draftScopeGroups.insert(group) } else { draftScopeGroups.remove(group) }
    }
    func toggleDraftScopeGroup(_ group: CleaningScopeGroup) {
        setDraftScopeGroup(group, selected: !draftScopeGroups.contains(group))
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
    var reviewableItems: [CleaningItemDisplay] { resultIndex.reviewableItems }
    var recommendedItems: [CleaningItemDisplay] { resultIndex.recommendedItems }
    var otherItems: [CleaningItemDisplay] { resultIndex.otherItems }
    var protectedItems: [CleaningItemDisplay] { resultIndex.protectedItems }
    var recommendedAllocatedBytes: UInt64 { resultIndex.recommendedAllocatedBytes }
    var reviewableAllocatedBytes: UInt64 { resultIndex.reviewableAllocatedBytes }
    var protectedAllocatedBytes: UInt64 { resultIndex.protectedAllocatedBytes }

    private func selectionChanged() {
        guard !suspendsResultProjection else { return }
        selectionRevision &+= 1
        rebuildSelectionCache()
        if onlySelected { refreshResultProjection() }
        else { updateVisibleSelection() }
    }
    private func rebuildSelectionCache() {
        selectedItemCache = resultIndex.selectedItems(selectedIDs)
        selectedByteCache = selectedItemCache.reduce(0) { $0 &+ $1.bytes }
        selectedAllocatedByteCache = selectedItemCache.reduce(0) { $0 &+ $1.allocatedBytes }
    }
    private func updateVisibleSelection() {
        let selected = selectedItemCache.reduce(0) { $0 + (visibleSelectableIDs.contains($1.id) ? 1 : 0) }
        allVisibleSelected = !visibleSelectableIDs.isEmpty && selected == visibleSelectableIDs.count
        someVisibleSelected = selected > 0 && !allVisibleSelected
    }
    private func cancelResultProjection() {
        resultProjectionGeneration &+= 1
        resultProjectionWork?.cancel(); resultProjectionTask?.cancel()
        resultProjectionWork = nil; resultProjectionTask = nil
    }
    /// Installs immutable presentation metadata; transaction candidates remain
    /// separately indexed and are always revalidated before file operations.
    func installResultIndex(_ index: CleaningResultsIndex) {
        cancelResultProjection()
        resultIndex = index
        resultProjectionCache.removeAll(); resultProjectionOrder.removeAll()
        items = index.items
        rebuildSelectionCache()
        refreshResultProjection()
    }
    private var resultQuery: CleaningResultsQuery {
        .init(tab: resultTab == .recommended ? 0 : resultTab == .reviewable ? 1 : 2,
              sort: sortKey.rawValue, ascending: sortAscending,
              search: searchText, selectedRevision: onlySelected ? selectionRevision : nil)
    }
    private func refreshResultProjection() {
        guard !suspendsResultProjection else { return }
        cancelResultProjection()
        let query = resultQuery
        if let cached = resultProjectionCache[query] {
            applyResultProjection(cached); return
        }
        if query.isDefault, let cached = resultIndex.defaultProjections[query.tab] {
            applyResultProjection(cached); return
        }
        let index = resultIndex, selection = onlySelected ? selectedIDs : nil
        let count = selection?.count ?? index.count(for: query.tab)
        resultProjectionBuildCount += 1
        if count <= 1_000 {
            if let projection = CleaningResultsProjection.make(index.entries(for: query.tab, selectedIDs: selection), query: query) {
                acceptResultProjection(projection, query: query)
            }
            return
        }
        // A query change cannot leave old-category rows selectable while its
        // replacement is being prepared. This task never touches file contents.
        applyResultProjection(.init())
        isUpdatingResults = true
        let run = resultProjectionGeneration
        let work = Task.detached(priority: .userInitiated) {
            CleaningResultsProjection.make(index.entries(for: query.tab, selectedIDs: selection), query: query)
        }
        resultProjectionWork = work
        resultProjectionTask = Task { [weak self] in
            let projection = await work.value
            guard let self, self.resultProjectionGeneration == run,
                  !Task.isCancelled, let projection else { return }
            self.resultProjectionTask = nil; self.resultProjectionWork = nil
            self.acceptResultProjection(projection, query: query)
        }
    }
    private func acceptResultProjection(_ projection: CleaningResultsProjection, query: CleaningResultsQuery) {
        if resultProjectionCache[query] == nil {
            resultProjectionOrder.append(query)
            if resultProjectionOrder.count > 6 {
                resultProjectionCache.removeValue(forKey: resultProjectionOrder.removeFirst())
            }
        }
        resultProjectionCache[query] = projection
        applyResultProjection(projection)
    }
    private func applyResultProjection(_ projection: CleaningResultsProjection) {
        visibleSelectableIDs = projection.selectableIDs
        visibleItems = projection.items
        isUpdatingResults = false
        updateVisibleSelection()
    }
    func waitForResultProjection() async {
        while let task = resultProjectionTask {
            let run = resultProjectionGeneration
            await task.value
            if resultProjectionGeneration == run { return }
        }
    }
    func sortResults(by key: CleaningSortKey) {
        guard !isBusy, dialog != .confirm else { return }
        if sortKey == key { sortAscending.toggle() }
        else { sortKey = key; sortAscending = ![.modified, .size].contains(key) }
        resultScrollID = nil
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
        if retiredResultCount > 0 { return "已处理或受影响的 \(retiredResultCount) 项已移出列表；建议整理的内容已全部处理，其他文件可自行选择。" }
        if scanReachedLimit { return "本次扫描达到覆盖边界；已完整核验的内容中暂未发现建议整理的项目。" }
        let inUse = resultIndex.runningApplicationCount
        if inUse > 0 { return "有 \(inUse) 项关联应用或工具正在使用，已保留。其他文件由你选择。" }
        if !coverageIssues.isEmpty { return "部分位置未能完整检查；已检查内容中暂未发现符合整理规则的项目。" }
        return "暂未发现可重建缓存、待整理安装介质或过期诊断记录；其他文件可自行选择。"
    }
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
    /// The remaining verified results stay available after a batch.
    var canReturnToResults: Bool { !items.isEmpty }
    func returnToResults() { guard !isBusy, canReturnToResults else { return }; closeDialog(); screen = .results }
    var reportSummary: String {
        if requiresRescan { return "文件状态已变化，请重新扫描后再选择" }
        if screen == .scanning { return "已检查 \(checkedCount) 项 · 逐项核验用途与保护规则" }
        if scanMode == .largeFiles { return "找到 \(reviewableItems.count) 个符合大小范围的文件 · 均需手动选择" + (scanReachedLimit ? " · 覆盖范围有限" : "") }
        if recommendedIDs.isEmpty { return noRecommendationsSummary }
        if retiredResultCount > 0 {
            return "已处理或受影响的 \(retiredResultCount) 项已移出列表 · 剩余 \(recommendedIDs.count) 项建议整理内容，可继续选择" + (scanReachedLimit ? " · 覆盖范围有限" : "")
        }
        let manualCount = recommendedIDs.subtracting(automaticallySelectedIDs).count
        let selection = automaticallySelectedIDs.isEmpty
            ? "这 \(manualCount) 项需确认后手动选择"
            : "\(automaticallySelectedIDs.count) 项可重建缓存已预选" + (manualCount > 0 ? "，另有 \(manualCount) 项需手动选择" : "")
        return "找到 \(recommendedIDs.count) 项建议整理内容 · " + selection + (scanReachedLimit ? " · 覆盖范围有限" : "")
    }
    /// Listed as a cleanup suggestion but never preselected: the row says so.
    func needsManualSelection(_ item: CleaningItemDisplay) -> Bool {
        scanMode == .cleanup && item.isSelectable && recommendedIDs.contains(item.id) && !automaticallySelectedIDs.contains(item.id)
    }
    func toggleItem(_ id: UUID) {
        guard !isBusy, !requiresRescan, resultIndex.item(id)?.isSelectable == true else { return }
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }
    func selectRecommended() {
        guard !isBusy, !requiresRescan, scanMode == .cleanup else { return }
        let context = makeContext()
        selectedIDs.formUnion(candidates.values.filter {
            $0.isRecommendedForSelection && SpaceCleaningScanner.validatePolicy(candidate: $0, context: context) == .unchanged
        }.map(\.id))
    }
    func showDetail(_ id: UUID) {
        guard resultIndex.item(id) != nil else { return }
        if detailID != id, case .purpose = dialog { closeDialog() }
        detailID = id
    }
    func closeDetail() {
        if case .purpose = dialog { closeDialog() }
        detailID = nil
    }
    func showHistory() {
        guard !isBusy else { return }
        previousScreen = screen; screen = .history
        if historyError != nil { reloadHistoryIfNeeded() } else { reconcileHistory() }
    }
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
        draftDirectories = customDirectories; draftScopeGroups = selectedScopeGroups; screen = .scope
    }
    func cancelScope() {
        guard !isBusy else { return }
        draftScope = scopeChoice; draftDirectories = customDirectories; draftScopeGroups = selectedScopeGroups
        releaseUnusedScopeAccess(); screen = scopeOrigin
    }
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
        guard screen == .scope, !isBusy, canApplyScope else { return }
        let changed = draftScope != scopeChoice || (draftScope == .custom && (draftDirectories != customDirectories || draftScopeGroups != selectedScopeGroups))
        scopeChoice = draftScope; customDirectories = draftDirectories; selectedScopeGroups = draftScopeGroups
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
        installResultIndex(.init())
        selectedIDs = []; recommendedIDs = []; automaticallySelectedIDs = []; detailID = nil; resultScrollID = nil; candidates = [:]; items = []
        directorySizes = [:]; measuringDirectoryID = nil
        requiresRescan = false; retiredResultCount = 0; screen = .start; message = historyError
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
        guard !isBusy, !requiresRescan, resultIndex.item(id)?.needsPurposeConfirmation == true else { return }
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
    func waitUntilIdle() async { if let task { await task.value }; await waitForResultProjection() }
    func prepareForQuit() async {
        frozenForQuit = true; cancelAll()
        cancelResultProjection()
        if let task { await task.value }
        securityScopedDirectories.forEach { $0.stopAccessingSecurityScopedResource() }; securityScopedDirectories = []
    }
    func resumeAfterCancelledQuit() { frozenForQuit = false; refreshResultProjection() }
    func refreshDisk() {
        let root = homeDirectory
        Task { [weak self] in
            let capacity = await Task.detached(priority: .utility) { DeviceStorageCapacity.read(at: root) }.value
            guard let self else { return }
            self.diskVolumeName = capacity?.volumeName; self.diskTotal = capacity?.total; self.diskAvailable = capacity?.available
            self.diskImmediatelyFree = capacity?.immediatelyFree; self.diskReclaimableEstimate = capacity?.reclaimableEstimate
            self.diskUpdatedAt = capacity == nil ? nil : Date()
        }
    }
    func reveal(_ id: UUID) {
        guard let item = resultIndex.item(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
    func preview(_ id: UUID) {
        guard let item = resultIndex.item(id), FileManager.default.fileExists(atPath: item.url.path) else { message = "文件已不在原位置，请重新扫描。"; return }
        previewURL = item.url as NSURL
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL }

    func startScan() {
        guard !isBusy, !frozenForQuit else { return }
        reloadHistoryIfNeeded()
        // A successful reload reconciles uncertain records first; scan after that.
        guard !isBusy else { message = "正在核对清理记录，完成后再开始扫描。"; return }
        guard canScanScope else { message = "请先选择要扫描的范围或目录。"; return }
        guard largeFileRangeError == nil else { message = largeFileRangeError; return }
        let context = makeContext()
        let options = SpaceCleaningOptions(mode: scanMode, minimumFileBytes: fileSizeBytes(minimumFileSize) ?? 100_000_000,
                                           maximumFileBytes: fileSizeBytes(maximumFileSize))
        let scopes = selectedScopes(context)
        guard !scopes.isEmpty else { message = "请先选择要扫描的目录。"; return }
        generation = UUID(); let run = generation
        cancellation = SpaceCleaningCancellation(); let token = cancellation
        installResultIndex(.init())
        selectedIDs = []; confirmedIDs = []; detailID = nil; resultScrollID = nil; searchText = ""; onlySelected = false; resultTab = .recommended; items = []; recommendedIDs = []; automaticallySelectedIDs = []; candidates = [:]
        directorySizes = [:]; measuringDirectoryID = nil
        if scanMode == .largeFiles { resultTab = .reviewable; sortKey = .size; sortAscending = false }
        coverageIssues = []; coverageNotes = []; summarizedProtectedCount = 0; scanReachedLimit = false; requiresRescan = false; retiredResultCount = 0; checkedCount = 0; scanPhase = .discovering; scanCompletedItems = 0; scanTotalItems = nil; scanDirectory = ""; scanItem = ""
        scanRecordedCandidates = 0; scanLogicalBytes = 0; scanCompletedScopes = 0; scanTotalScopes = scopes.count; scanRecentPaths = []
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
            let selectionContext = self.makeContext(), home = self.homeDirectory
            let prepared = await Task.detached(priority: .userInitiated) {
                Self.prepareResults(report, context: selectionContext, options: options, home: home)
            }.value
            guard self.generation == run else { return }
            self.checkedCount = report.checkedEntries
            self.coverageIssues = report.issues.filter { ![.missing, .duplicate].contains($0.kind) }.map { $0.url.path.replacingOccurrences(of: self.homeDirectory.path, with: "~") + " · " + $0.reason }
            self.coverageNotes = report.scopes.map { $0.title + " · " + $0.directory.path.replacingOccurrences(of: self.homeDirectory.path, with: "~") }
            self.coverageNotes.append("开发依赖、Git 资料与虚拟环境默认保留，未展开的目录不计入已知容量。")
            if options.mode == .largeFiles {
                self.coverageNotes.append("普通文件大小 ≥ " + SpaceCleaningFormat.bytes(options.minimumFileBytes) +
                    (options.maximumFileBytes.map { "，且 ≤ " + SpaceCleaningFormat.bytes($0) } ?? "；无上限") + "。包与受保护目录不展开。")
            }
            self.coverageNotes += report.issues.filter { [.missing, .duplicate].contains($0.kind) }.map { $0.url.path.replacingOccurrences(of: self.homeDirectory.path, with: "~") + " · " + $0.reason }
            self.coverageNotes += prepared.summaryNotes
            self.summarizedProtectedCount = prepared.summarizedCount
            self.suspendsResultProjection = true
            self.candidates = prepared.candidates
            self.recommendedIDs = prepared.recommendedIDs
            self.automaticallySelectedIDs = prepared.automaticallySelectedIDs
            self.selectedIDs = prepared.automaticallySelectedIDs
            self.selectionRevision &+= 1
            self.suspendsResultProjection = false
            self.installResultIndex(prepared.index)
            self.requiresRescan = [.cancelled, .failed].contains(report.stage)
            self.scanReachedLimit = report.reachedLimit
            self.lastScanDate = report.finishedAt
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
                self.candidates[id] = fresh
                var updated = self.items; updated[index] = Self.display(fresh)
                let updatedItems = updated, recommended = self.recommendedIDs
                let resultIndex = await Task.detached(priority: .userInitiated) {
                    CleaningResultsIndex(items: updatedItems, recommendedIDs: recommended)
                }.value
                self.installResultIndex(resultIndex)
                self.resultTab = .reviewable; self.onlySelected = false; self.searchText = ""; self.resultScrollID = id
            } else {
                self.declarations.removeAll { $0.url == candidate.url }
                self.message = "文件身份、内容或保护状态已变化，继续保留；请重新扫描。"
            }
            self.task = nil; self.purposeReviewID = nil; self.closeDialog()
        }
    }
    private nonisolated static func prepareResults(_ report: SpaceCleaningReport, context: SpaceCleaningContext,
                                                   options: SpaceCleaningOptions, home: URL) -> PreparedCleaningResults {
        let mode = options.mode
        let candidates = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.id, $0) })
        let recommended: Set<UUID> = mode == .cleanup && report.stage == .complete ? Set(report.candidates.filter {
            $0.isCleanupSuggestion && SpaceCleaningScanner.validatePolicy(candidate: $0, context: context) == .unchanged
        }.map(\.id)) : []
        let automatic = Set(report.candidates.filter { recommended.contains($0.id) && $0.isRecommendedForSelection }.map(\.id))
        // Tiny protected entries that can never be processed are summarized
        // instead of listed one by one; their protection does not change.
        let summarized = report.candidates.filter { isSummarizedProtection($0, options: options) }
        let hidden = Set(summarized.map(\.id))
        let items = report.candidates.filter { !hidden.contains($0.id) }.map(Self.display).sorted {
            if $0.group != $1.group { return CleaningResultGroup.allCases.firstIndex(of: $0.group)! < CleaningResultGroup.allCases.firstIndex(of: $1.group)! }
            return $0.bytes == $1.bytes ? $0.url.path < $1.url.path : $0.bytes > $1.bytes
        }
        return .init(candidates: candidates, recommendedIDs: recommended, automaticallySelectedIDs: automatic,
                     index: .init(items: items, recommendedIDs: recommended),
                     summarizedCount: summarized.count, summaryNotes: summaryNotes(summarized, home: home))
    }
    /// Symbolic links are never followed or counted; in large-file mode the
    /// protected placeholders, development markers and special files below the
    /// size bound are not large files either.
    nonisolated static func isSummarizedProtection(_ candidate: SpaceCleaningCandidate, options: SpaceCleaningOptions) -> Bool {
        guard !candidate.canProcess, candidate.group == .protected else { return false }
        if candidate.kind == .symbolicLink { return true }
        return options.mode == .largeFiles && !candidate.isDirectory &&
            [.cloudPlaceholder, .developmentEnvironment, .unsupported].contains(candidate.kind) &&
            candidate.identity.sizeBytes < options.minimumFileBytes
    }
    private nonisolated static func summaryNotes(_ summarized: [SpaceCleaningCandidate], home: URL) -> [String] {
        func short(_ url: URL) -> String { url.path.replacingOccurrences(of: home.path, with: "~") }
        let links = Dictionary(grouping: summarized.filter { $0.kind == .symbolicLink }, by: { $0.url.deletingLastPathComponent() })
            .sorted { $0.value.count == $1.value.count ? $0.key.path < $1.key.path : $0.value.count > $1.value.count }
        var notes = links.prefix(20).map { short($0.key) + " · 已保留 \($0.value.count) 个符号链接，未跟随目标，不计入容量，未逐项列出。" }
        if links.count > 20 {
            notes.append("另有 \(links.count - 20) 个目录中的 \(links.dropFirst(20).reduce(0) { $0 + $1.value.count }) 个符号链接同样保留，未逐项列出。")
        }
        let small = summarized.filter { $0.kind != .symbolicLink }.count
        if small > 0 { notes.append("另有 \(small) 个小于下限的受保护项目（云端占位、开发标记或特殊文件）未逐项列出，仍保持保留。") }
        return notes
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
            var attempted: [SpaceCleaningCandidate] = []
            for candidate in selected {
                // Stop between items. An item already started completes its verified
                // transaction; an irreversible directory deletion is never cut in half.
                guard !token.isCancelled, persistence.error == nil else { break }
                let cancelledBeforeItem = false
                self?.processingItem = candidate.title
                attempted.append(candidate)
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
            // Items never started keep their selection, so stopping can be resumed.
            let started = Set(attempted.map(\.id))
            self.finishProcessing(error: persistence.error, touched: attempted.map(\.url),
                                  resume: Set(selected.map(\.id)).subtracting(started))
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
            var touched: [URL] = []
            for record in selected {
                guard !token.isCancelled else { break }
                self?.processingItem = record.candidate.title
                touched.append(record.originalURL)
                let restored = await Task.detached(priority: .utility) {
                    SpaceCleaningTransaction.restore(record: record, conflict: renameConflicts ? .rename : .skip,
                        isCancelled: { false }, validatePolicy: { candidate in
                            let context = Self.context(home: home, runtime: runtime, declarations: declarations)
                            return record.locationURL.map { Self.runningAt($0, context: context) } == true ? "项目正在废纸篓中运行，请先退出相关应用。" : nil
                        }, persist: persistence.record)
                }.value
                if let destination = restored.restoredURL { touched.append(destination) }
                self?.acceptRecord(restored); self?.processingCompleted += 1
                if persistence.error != nil { break }
            }
            self?.finishProcessing(error: persistence.error, touched: touched)
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
            self?.finishProcessing(error: persistence.error, touched: selected.compactMap(\.locationURL))
        }
    }
    private func beginProcessing(count: Int) {
        cancellation = SpaceCleaningCancellation(); selectedIDs = []; detailID = nil
        currentBatch = nil; processingCompleted = 0; processingTotal = count; processingItem = "正在核验所选项目"; screen = .processing
    }
    private func finishProcessing(error: String?, touched: [URL], resume: Set<UUID> = []) {
        if let error { historyError = error; message = "处理记录未能安全保存，已暂停后续操作。" + error }
        else if cancellation.isCancelled { message = "已停止后续处理。另有 \(max(0, processingTotal - processingCompleted)) 项未开始；实际处理结果与可恢复项目见下方记录。" }
        else { message = nil }
        retireResults(touching: touched, resume: resume)
        rebuildBatches(); task = nil; screen = operationDestination; refreshDisk()
    }
    /// A batch makes only the results it acted on stale: those items, plus any
    /// result nested inside or containing them, leave the list. Everything else
    /// keeps its verified snapshot and stays selectable, so cleanup can continue
    /// without a rescan. Every later operation still revalidates identity,
    /// content, running state and protection before touching a file.
    private func retireResults(touching urls: [URL], resume: Set<UUID>) {
        let retired = Self.overlappingResultIDs(candidates.lazy.map { ($0.key, $0.value.url) }, touching: urls)
        suspendsResultProjection = true
        if !retired.isEmpty {
            for id in retired { candidates[id] = nil; directorySizes[id] = nil }
            recommendedIDs.subtract(retired); automaticallySelectedIDs.subtract(retired)
            retiredResultCount += items.reduce(0) { $0 + (retired.contains($1.id) ? 1 : 0) }
        }
        selectedIDs = resume.filter { candidates[$0] != nil }
        selectionRevision &+= 1
        resultScrollID = nil
        suspendsResultProjection = false
        if retired.isEmpty { rebuildSelectionCache(); refreshResultProjection() }
        else { installResultIndex(CleaningResultsIndex(items: items.filter { !retired.contains($0.id) }, recommendedIDs: recommendedIDs)) }
    }
    /// Results whose path equals, contains or lies inside any touched path.
    nonisolated static func overlappingResultIDs(_ results: some Sequence<(UUID, URL)>, touching urls: [URL]) -> Set<UUID> {
        let touched = Set(urls.map { $0.standardizedFileURL.path })
        guard !touched.isEmpty else { return [] }
        var ancestors = Set<String>()
        for path in touched {
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count > 1, ancestors.insert(parent).inserted { parent = (parent as NSString).deletingLastPathComponent }
        }
        var overlapping = Set<UUID>()
        for (id, url) in results {
            let path = url.standardizedFileURL.path
            if touched.contains(path) || ancestors.contains(path) { overlapping.insert(id); continue }
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count > 1 {
                if touched.contains(parent) { overlapping.insert(id); break }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return overlapping
    }
    private func loadHistory() {
        do {
            let store = try SpaceCleaningHistoryStore(fileURL: dataDirectory.appendingPathComponent("history.json"))
            historyStore = store; records = store.records; rebuildBatches()
            reconcileHistory()
        } catch { historyError = error.localizedDescription; message = "清理历史无法读取，原文件已保留；扫描仍可使用，文件处理已暂停。" }
    }
    /// After a failed load or write, reopen the durable history instead of
    /// requiring a restart. Disk is the source of truth: records are reloaded
    /// and uncertain ones reconciled exactly as after launch. An unchanged
    /// problem (corrupt or externally modified files) keeps processing paused.
    func reloadHistoryIfNeeded() {
        guard historyError != nil, !isBusy, !frozenForQuit else { return }
        let previous = message
        do {
            let store = try SpaceCleaningHistoryStore(fileURL: dataDirectory.appendingPathComponent("history.json"))
            historyStore = store; records = store.records; historyError = nil
            if previous != nil { message = nil }
            rebuildBatches(); reconcileHistory()
        } catch {
            historyError = error.localizedDescription
            message = "清理记录仍无法可靠读取，原文件已保留；扫描仍可使用，文件处理继续暂停。"
        }
    }
    private func reconcileHistory() {
        guard !isBusy, !frozenForQuit, historyError == nil, let store = historyStore else { return }
        let uncertain = records.filter {
            [.prepared, .isolated, .trashed, .deleting, .restoring].contains($0.state) || SpaceCleaningTransaction.canReverify($0)
        }
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
                        originalURL: record.originalURL, resultURL: record.restoredURL ?? record.locationURL,
                        isDirectory: record.candidate.isDirectory)
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
    func selectedScopes(_ context: SpaceCleaningContext) -> [SpaceCleaningScope] {
        let global = SpaceCleaningScanner.globalScopes(context: context)
        guard scopeChoice == .custom else { return global }
        // Preserve the original ordering and kind of specialized scopes before
        // any broad parent or extra user folder can encounter the same files.
        let grouped = global.filter { scope in selectedScopeGroups.contains { $0.includes(scope, home: context.homeDirectory) } }
        var paths = Set<String>(), discoveryPaths = Set<String>()
        return (grouped + customDirectories.map { .init(directory: $0, title: $0.lastPathComponent) }).filter {
            let path = $0.directory.standardizedFileURL.path
            // Discovery inspects only ReleaseArchives children. It cannot
            // replace an explicitly selected scan of the same parent folder.
            if $0.kind == .releaseArchiveDiscovery { return discoveryPaths.insert(path).inserted }
            return paths.insert(path).inserted
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
              activeToolNames: SpaceCleaningToolActivity.currentIdentities(),
              runningExecutablePaths: SpaceCleaningToolActivity.currentExecutablePaths())
    }
    private func acceptProgress(_ progress: SpaceCleaningProgress) {
        checkedCount = progress.checkedEntries; scanPhase = progress.phase
        scanCompletedItems = progress.completedItems; scanTotalItems = progress.totalItems
        scanRecordedCandidates = progress.recordedCandidates
        scanLogicalBytes = progress.logicalBytes
        scanCompletedScopes = progress.completedScopes; scanTotalScopes = progress.totalScopes
        if let path = progress.currentPath {
            let url = URL(fileURLWithPath: path)
            scanDirectory = shortPath(url)
            scanItem = progress.currentFileName ?? url.lastPathComponent
            let recent = shortPath(progress.currentFileName.map { url.appendingPathComponent($0) } ?? url)
            if scanRecentPaths.first != recent {
                scanRecentPaths = [recent] + scanRecentPaths.filter { $0 != recent }.prefix(3)
            }
        }
    }
    private struct ScopePreference: Codable {
        var format = 1; var choice: CleaningScopeChoice; var bookmarks: [Data]
        var requestedPaths: [String]? = nil
        var groups: [CleaningScopeGroup]? = nil
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
            // Older custom selections contain only their bookmarked folders.
            selectedScopeGroups = Set(saved.groups ?? [])
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
            try JSONEncoder().encode(ScopePreference(choice: scopeChoice, bookmarks: bookmarks, requestedPaths: customDirectories.map(\.path), groups: CleaningScopeGroup.allCases.filter { selectedScopeGroups.contains($0) })).write(to: scopePreferenceURL, options: .atomic)
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

private struct PreparedCleaningResults: Sendable {
    let candidates: [UUID: SpaceCleaningCandidate]
    let recommendedIDs: Set<UUID>
    let automaticallySelectedIDs: Set<UUID>
    let index: CleaningResultsIndex
    let summarizedCount: Int
    let summaryNotes: [String]
}

struct CleaningResultsQuery: Hashable, Sendable {
    let tab: Int
    let sort: String
    let ascending: Bool
    let search: String
    let selectedRevision: UInt64?
    var isDefault: Bool { sort == "size" && !ascending && search.isEmpty && selectedRevision == nil }
}

/// Metadata is prepared once when the scan completes, not while a row scrolls.
/// Parent path and type strings are cached before sorting; no file I/O or system
/// icon lookup is part of this index or any result query.
struct CleaningResultsEntry: Sendable {
    let item: CleaningItemDisplay
    let position: Int
    let path: String
    let directory: String
    let type: String
    let identity: String
    init(_ item: CleaningItemDisplay, position: Int) {
        self.item = item; self.position = position
        path = item.url.standardizedFileURL.path
        directory = item.subtitle; type = item.typeTitle; identity = item.id.uuidString
    }
    static func precedes(_ lhs: Self, _ rhs: Self, query: CleaningResultsQuery) -> Bool {
        let comparison: ComparisonResult
        switch query.sort {
        case "name": comparison = lhs.item.name.localizedStandardCompare(rhs.item.name)
        case "directory": comparison = lhs.directory.localizedStandardCompare(rhs.directory)
        case "type": comparison = lhs.type.localizedStandardCompare(rhs.type)
        case "modified": comparison = lhs.item.modifiedDate == rhs.item.modifiedDate ? .orderedSame : lhs.item.modifiedDate < rhs.item.modifiedDate ? .orderedAscending : .orderedDescending
        default: comparison = lhs.item.bytes == rhs.item.bytes ? .orderedSame : lhs.item.bytes < rhs.item.bytes ? .orderedAscending : .orderedDescending
        }
        if comparison != .orderedSame { return comparison == (query.ascending ? .orderedAscending : .orderedDescending) }
        // Reverse only the requested column. Equal values keep an ascending
        // identity order, preserving stable row identity in either direction.
        let pathComparison = lhs.path.localizedStandardCompare(rhs.path)
        if pathComparison != .orderedSame { return pathComparison == .orderedAscending }
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.identity < rhs.identity
    }
}

struct CleaningResultsProjection: Sendable {
    var items: [CleaningItemDisplay] = []
    var selectableIDs = Set<UUID>()

    static func make(_ input: [CleaningResultsEntry], query: CleaningResultsQuery) -> Self? {
        var source: [CleaningResultsEntry] = []
        source.reserveCapacity(input.count)
        for (index, entry) in input.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return nil }
            if query.search.isEmpty || entry.item.name.localizedStandardContains(query.search) || entry.path.localizedStandardContains(query.search) {
                source.append(entry)
            }
        }
        // Bottom-up merge sort has cancellation points within a long pass, so
        // obsolete searches release their large arrays promptly when typing.
        if source.count > 1 {
            var destination = source, width = 1
            while width < source.count {
                if Task.isCancelled { return nil }
                for start in stride(from: 0, to: source.count, by: width * 2) {
                    let middle = min(start + width, source.count), end = min(start + width * 2, source.count)
                    var left = start, right = middle
                    for output in start..<end {
                        if output.isMultiple(of: 256), Task.isCancelled { return nil }
                        if left < middle && (right == end || !CleaningResultsEntry.precedes(source[right], source[left], query: query)) {
                            destination[output] = source[left]; left += 1
                        } else {
                            destination[output] = source[right]; right += 1
                        }
                    }
                }
                swap(&source, &destination); width *= 2
            }
        }
        if Task.isCancelled { return nil }
        return .init(items: source.map(\.item), selectableIDs: Set(source.lazy.filter { $0.item.isSelectable }.map { $0.item.id }))
    }
}

struct CleaningResultsIndex: Sendable {
    let items: [CleaningItemDisplay]
    let reviewableItems: [CleaningItemDisplay]
    let recommendedItems: [CleaningItemDisplay]
    let otherItems: [CleaningItemDisplay]
    let protectedItems: [CleaningItemDisplay]
    let recommendedAllocatedBytes: UInt64
    let reviewableAllocatedBytes: UInt64
    let protectedAllocatedBytes: UInt64
    let runningApplicationCount: Int
    let defaultProjections: [Int: CleaningResultsProjection]
    private let allEntries: [CleaningResultsEntry]
    private let positions: [UUID: Int]
    private let categories: [[CleaningResultsEntry]]

    init(items: [CleaningItemDisplay] = [], recommendedIDs: Set<UUID> = []) {
        self.items = items
        let entries = items.enumerated().map { CleaningResultsEntry($0.element, position: $0.offset) }
        var recommended: [CleaningResultsEntry] = [], other: [CleaningResultsEntry] = [], protected: [CleaningResultsEntry] = []
        var reviewable: [CleaningItemDisplay] = []
        var recommendedBytes: UInt64 = 0, reviewableBytes: UInt64 = 0, protectedBytes: UInt64 = 0, running = 0
        for entry in entries {
            let item = entry.item
            if item.kind == .runningApplication { running += 1 }
            if item.group == .protected { protected.append(entry); protectedBytes &+= item.allocatedBytes }
            else {
                reviewable.append(item); reviewableBytes &+= item.allocatedBytes
                if recommendedIDs.contains(item.id) { recommended.append(entry); recommendedBytes &+= item.allocatedBytes }
                else { other.append(entry) }
            }
        }
        allEntries = entries
        positions = Dictionary(uniqueKeysWithValues: entries.map { ($0.item.id, $0.position) })
        let grouped = [recommended, other, protected]
        categories = grouped
        reviewableItems = reviewable; recommendedItems = recommended.map(\.item)
        otherItems = other.map(\.item); protectedItems = protected.map(\.item)
        recommendedAllocatedBytes = recommendedBytes; reviewableAllocatedBytes = reviewableBytes
        protectedAllocatedBytes = protectedBytes; runningApplicationCount = running
        defaultProjections = Dictionary(uniqueKeysWithValues: grouped.enumerated().map { tab, entries in
            let query = CleaningResultsQuery(tab: tab, sort: "size", ascending: false, search: "", selectedRevision: nil)
            return (tab, CleaningResultsProjection.make(entries, query: query) ?? .init())
        })
    }
    func item(_ id: UUID) -> CleaningItemDisplay? { positions[id].map { items[$0] } }
    func count(for tab: Int) -> Int { categories[tab].count }
    func entries(for tab: Int, selectedIDs: Set<UUID>?) -> [CleaningResultsEntry] {
        guard let selectedIDs else { return categories[tab] }
        return selectedEntries(selectedIDs)
    }
    func selectedItems(_ ids: Set<UUID>) -> [CleaningItemDisplay] { selectedEntries(ids).map(\.item) }
    private func selectedEntries(_ ids: Set<UUID>) -> [CleaningResultsEntry] {
        if ids.count > items.count / 4 {
            return allEntries.filter { ids.contains($0.item.id) && $0.item.isSelectable }
        }
        return ids.compactMap { positions[$0] }.sorted().compactMap {
            let entry = allEntries[$0]; return entry.item.isSelectable ? entry : nil
        }
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
