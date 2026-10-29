import AppKit
import Combine
import Foundation
import LauncherCore

enum UsageConnectionService: String, CaseIterable, Identifiable {
    case codex, claude, deepseek, iproyal, bandwagon
    var id: String { rawValue }
    var title: String {
        switch self { case .codex: "Codex 订阅"; case .claude: "Claude 订阅"; case .deepseek: "DeepSeek API"; case .iproyal: "IPRoyal"; case .bandwagon: "搬瓦工" }
    }
    var defaultName: String {
        switch self { case .codex: "Codex"; case .claude: "Claude"; default: title }
    }
    var aiProvider: AIProvider? { self == .codex ? .codex : self == .claude ? .claude : nil }
    var trafficKind: ProviderUsageKind? { self == .iproyal ? .iproyal : self == .bandwagon ? .bandwagon : nil }
}

struct UsageConnectionDraft: Equatable {
    var service: UsageConnectionService?
    var name = ""
    var appearance = UsageCardAppearance(categoryID: "uncategorized")
    var resourceID = ""
    var secret = ""
    var declaredPlan: AIAccountPlan?
    var enabled = true
    var thresholdMB = "1000"
    var minimumHours = "1"
    var maximumHours = "6"
}

struct UsageManagedConnection: Identifiable {
    let id: String
    let name: String
    let detail: String
    let service: UsageConnectionService
    let appearance: UsageCardAppearance
    let connected: Bool
}

/// The editor owns only a short-lived draft. Credentials are passed directly to
/// existing verified connection models and are never part of display settings.
@MainActor final class UsageConnectionManager: ObservableObject, Identifiable {
    let id = UUID()
    let initialSourceID: String?
    @Published var draft = UsageConnectionDraft()
    @Published private(set) var selectedSourceID: String?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var confirmingDiscard = false
    @Published var discardTitle = "放弃未保存的修改？"
    @Published var discardDetail = "本次连接修改尚未保存。"
    private var original = UsageConnectionDraft()
    private var originalTraffic: ProviderUsageConfiguration?
    private var originalAPI: APIBalanceConfiguration?
    private var newIdentifier = UUID()
    private var initialized = false
    private var pendingAction: (() -> Void)?
    private var verifiedOrder: ProviderUsageSnapshot?
    private var verifiedResourceID: String?

    init(sourceID: String? = nil) { initialSourceID = sourceID }
    var hasChanges: Bool { draft != original }
    var isNew: Bool { selectedSourceID == nil }
    var existingSubscriptionID: String? {
        guard isNew, let provider = draft.service?.aiProvider else { return nil }
        // Each local CLI has one built-in subscription source. A new card must
        // not silently overwrite its appearance or declared membership plan.
        return UsagePresentationSourceID.ai(provider)
    }
    var canKeepTrafficCredential: Bool {
        guard let source = originalTraffic else { return false }
        return source.credentialID != nil && draft.service?.trafficKind == source.kind
            && draft.resourceID.trimmingCharacters(in: .whitespacesAndNewlines) == source.resourceID
    }
    var primaryTitle: String {
        if busy { return "正在处理…" }
        if draft.service == .deepseek && (originalAPI == nil || !draft.secret.isEmpty) { return "验证并保存" }
        if draft.service == .bandwagon && (!canKeepTrafficCredential || !draft.secret.isEmpty) { return "验证并保存" }
        return isNew ? "添加连接" : "保存修改"
    }

    func prepare(app: WorkbenchAppModel) {
        guard !initialized else { return }; initialized = true
        if let initialSourceID { load(initialSourceID, app: app) }
    }
    func connections(app: WorkbenchAppModel) -> [UsageManagedConnection] {
        var entries = AIProvider.allCases.map { provider -> UsageManagedConnection in
            let key = UsagePresentationSourceID.ai(provider), appearance = app.usageAppearance.appearance(for: key)
            let summary = app.ai.providerSummaries.first { $0.provider == provider }
            let connected = app.ai.configuration(for: provider).enabled && summary?.state == .ready
            return .init(id: key, name: appearance.displayName ?? provider.title,
                         detail: summary?.effectiveAccountPlan?.title ?? (connected ? "本机来源" : "尚未读取"),
                         service: provider == .codex ? .codex : .claude, appearance: appearance, connected: connected)
        }
        entries += app.providerUsage.sources.map { source in
            let key = UsagePresentationSourceID.service(source.id), appearance = app.usageAppearance.appearance(for: key)
            let state = app.providerUsage.state(for: source.id)
            return .init(id: key, name: appearance.displayName ?? source.name,
                         detail: (source.kind == .iproyal ? "订单 " : "实例 ") + source.resourceID,
                         service: source.kind == .iproyal ? .iproyal : .bandwagon, appearance: appearance,
                         connected: state.snapshot != nil && state.message == nil)
        }
        entries += app.apiBalance.sources.map { source in
            let key = UsagePresentationSourceID.api(source.id), appearance = app.usageAppearance.appearance(for: key)
            let state = app.apiBalance.state(for: source.id)
            return .init(id: key, name: appearance.displayName ?? source.name, detail: "DeepSeek API",
                         service: .deepseek, appearance: appearance, connected: state.snapshot != nil && state.message == nil)
        }
        return entries
    }
    func select(_ sourceID: String, app: WorkbenchAppModel) {
        guard sourceID != selectedSourceID else { return }
        requestTransition { [weak self, weak app] in if let app { self?.load(sourceID, app: app) } }
    }
    func add() { requestTransition { [weak self] in self?.reset() } }
    func requestClose(_ close: @escaping () -> Void) {
        requestTransition { [weak self] in self?.clearSecret(); close() }
    }
    func keepEditing() { pendingAction = nil; confirmingDiscard = false }
    func discardChanges() {
        let action = pendingAction; pendingAction = nil; confirmingDiscard = false
        clearSecret(); action?()
    }
    func selectService(_ service: UsageConnectionService?) {
        guard !busy, selectedSourceID == nil, draft.service != service else { return }
        let change = { [weak self] in
            guard let self else { return }
            let old = self.draft.service
            if self.draft.name.isEmpty || self.draft.name == old?.defaultName { self.draft.name = service?.defaultName ?? "" }
            self.draft.service = service; self.draft.resourceID = ""; self.draft.secret = ""
            self.draft.declaredPlan = nil; self.draft.enabled = true
            self.draft.minimumHours = "1"; self.draft.maximumHours = "6"; self.draft.thresholdMB = "1000"
            self.verifiedOrder = nil; self.verifiedResourceID = nil; self.error = nil; self.notice = nil
        }
        if !draft.resourceID.isEmpty || !draft.secret.isEmpty {
            discardTitle = "更换连接服务？"; discardDetail = "当前订单、实例编号和未保存的密钥会清空，名称、图标与分类保留。"
            pendingAction = change; confirmingDiscard = true
        } else { change() }
    }
    func reconcileCategories(_ categories: [UsageCardCategory]) {
        let valid = Set(categories.map(\.id))
        if let category = draft.appearance.categoryID, !valid.contains(category) { draft.appearance.categoryID = "uncategorized" }
        if let category = original.appearance.categoryID, !valid.contains(category) { original.appearance.categoryID = "uncategorized" }
    }

    func connectSubscription(app: WorkbenchAppModel) {
        guard !busy, let provider = draft.service?.aiProvider else { return }
        error = nil; notice = nil
        if app.ai.setEnabled(true, provider: provider) {
            app.ai.refresh(); notice = "已启用本机读取，连接状态和额度以实际读数为准。"
        } else { error = app.ai.errorMessage ?? "本机来源未能启用，请稍后重试。" }
    }
    func enableClaudeSync(app: WorkbenchAppModel) {
        guard !busy, draft.service == .claude else { return }
        error = nil
        if app.ai.enableClaudeQuotaSync() { notice = app.ai.claudeQuotaSyncMessage; app.ai.refresh() }
        else { error = app.ai.errorMessage ?? "额度同步未启用。" }
    }
    func checkBrowser(app: WorkbenchAppModel) {
        guard !busy else { return }
        error = nil
        notice = app.providerBrowser.isConnected ? "已检测到 Chrome 连接器，可以读取订单。" : "尚未检测到连接器，请打开连接指南完成安装并保持 Chrome 运行。"
    }
    func verifyOrder(app: WorkbenchAppModel) {
        guard !busy, draft.service == .iproyal else { return }
        let candidate: ProviderUsageConfiguration
        do { candidate = try trafficConfiguration() } catch { self.error = error.localizedDescription; return }
        busy = true; error = nil; notice = nil
        Task { @MainActor [weak self, weak app] in
            guard let self, let app else { return }
            defer { self.busy = false }
            do {
                let snapshot = try await app.providerBrowser.request(configuration: candidate)
                self.verifiedOrder = snapshot; self.verifiedResourceID = candidate.resourceID
                self.notice = "已读取订单额度，保存后添加到卡片列表。"
            } catch { self.error = error.localizedDescription }
        }
    }
    func save(app: WorkbenchAppModel) {
        guard !busy, let service = draft.service else { return }
        guard existingSubscriptionID == nil else { error = "此本机订阅已有连接，请选择编辑已有连接。"; return }
        guard app.usageAppearance.storageError == nil else { error = app.usageAppearance.storageError; return }
        var display = draft.appearance
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "请填写卡片名称。"; return }
        display.displayName = name
        do {
            try display.validate()
            guard let category = display.categoryID, app.usageAppearance.preferences.categories.contains(where: { $0.id == category }) else { throw UsagePresentationError.invalid }
            let prospectiveKey = service.aiProvider.map(UsagePresentationSourceID.ai)
                ?? (service == .deepseek ? UsagePresentationSourceID.api(originalAPI?.id ?? newIdentifier) : UsagePresentationSourceID.service(originalTraffic?.id ?? newIdentifier))
            var preferences = app.usageAppearance.preferences
            preferences.cards[prospectiveKey] = display
            if !preferences.sourceOrder.contains(prospectiveKey) { preferences.sourceOrder.append(prospectiveKey) }
            try preferences.validate()
        } catch { self.error = error.localizedDescription; return }
        error = nil; notice = nil; busy = true
        Task { @MainActor [weak self, weak app] in
            guard let self, let app else { return }
            defer { self.busy = false }
            var previousPlan: AIAccountPlan?
            var changedPlanProvider: AIProvider?
            do {
                let key: String
                if let provider = service.aiProvider {
                    key = UsagePresentationSourceID.ai(provider)
                    previousPlan = app.ai.configuration(for: provider).declaredPlan
                    guard app.ai.setDeclaredPlan(self.draft.declaredPlan, provider: provider) else {
                        throw AIUsageError.invalid(app.ai.errorMessage ?? "会员显示设置未能保存。")
                    }
                    changedPlanProvider = provider
                } else if service == .deepseek {
                    let source = try await app.apiBalance.validateAndSave(name: name, key: self.draft.secret, editingID: self.originalAPI?.id)
                    self.originalAPI = source; key = UsagePresentationSourceID.api(source.id)
                } else {
                    let candidate = try self.trafficConfiguration()
                    let resourceChanged = self.originalTraffic?.resourceID != candidate.resourceID
                    if service == .iproyal, resourceChanged, self.verifiedResourceID != candidate.resourceID {
                        throw ProviderUsageFailure.unavailable("请先读取此订单的额度，确认连接有效。")
                    }
                    guard await app.providerUsage.save(candidate, secret: self.draft.secret.isEmpty ? nil : self.draft.secret) else {
                        throw ProviderUsageFailure.unavailable(app.providerUsage.errorMessage ?? "连接未保存，请重试。")
                    }
                    self.originalTraffic = app.providerUsage.sources.first { $0.id == candidate.id }
                    key = UsagePresentationSourceID.service(candidate.id)
                    if let snapshot = self.verifiedOrder, self.verifiedResourceID == candidate.resourceID, candidate.enabled {
                        _ = app.providerUsage.acceptBrowserSnapshot(snapshot, for: candidate.id)
                    }
                }
                self.selectedSourceID = key; self.draft.secret = ""
                guard app.usageAppearance.saveAppearance(display, for: key) else {
                    throw UsagePresentationError.storage
                }
                changedPlanProvider = nil
                _ = app.usageAppearance.registerSources([key])
                self.load(key, app: app); self.notice = "修改已保存。"
            } catch {
                if let provider = changedPlanProvider { _ = app.ai.setDeclaredPlan(previousPlan, provider: provider) }
                self.error = error.localizedDescription
                if self.selectedSourceID != nil, self.draft != self.original { self.notice = "请检查当前设置；已保存的连接会保留。" }
            }
        }
    }

    func trafficConfiguration() throws -> ProviderUsageConfiguration {
        guard let kind = draft.service?.trafficKind,
              let threshold = Double(draft.thresholdMB), threshold.isFinite, threshold >= 1, threshold <= 10_000_000,
              let minimum = Double(draft.minimumHours), let maximum = Double(draft.maximumHours) else { throw ProviderUsageFailure.invalidConfiguration }
        var candidate = originalTraffic ?? .init(id: newIdentifier, kind: kind, name: "", resourceID: "")
        candidate.kind = kind; candidate.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.resourceID = draft.resourceID.trimmingCharacters(in: .whitespacesAndNewlines); candidate.enabled = draft.enabled
        candidate.refreshPolicy = .init(byteThreshold: UInt64((threshold * 1_000_000).rounded()), minimumInterval: minimum * 3600, maximumInterval: maximum * 3600)
        try candidate.validate(); return candidate
    }
    private func requestTransition(_ action: @escaping () -> Void) {
        guard !busy else { return }
        if hasChanges {
            discardTitle = "放弃未保存的修改？"; discardDetail = "本次连接修改尚未保存。"
            pendingAction = action; confirmingDiscard = true
        } else { action() }
    }
    private func clearSecret() { draft.secret = "" }
    private func reset() {
        clearSecret(); draft = .init(); original = draft; selectedSourceID = nil
        originalTraffic = nil; originalAPI = nil; newIdentifier = UUID(); verifiedOrder = nil; verifiedResourceID = nil
        error = nil; notice = nil
    }
    private func load(_ key: String, app: WorkbenchAppModel) {
        reset()
        guard let entry = connections(app: app).first(where: { $0.id == key }) else { return }
        selectedSourceID = key; draft.service = entry.service; draft.name = entry.name
        draft.appearance = entry.appearance
        let defaultID = entry.service.aiProvider != nil ? "ai-subscription" : entry.service == .deepseek ? "api-balance" : entry.service == .iproyal ? "static-isp" : "vps-traffic"
        draft.appearance.categoryID = app.usageAppearance.categoryID(for: key, defaultID: defaultID)
        if let provider = entry.service.aiProvider { draft.declaredPlan = app.ai.configuration(for: provider).declaredPlan }
        if let source = app.providerUsage.sources.first(where: { UsagePresentationSourceID.service($0.id) == key }) {
            originalTraffic = source; draft.resourceID = source.resourceID; draft.enabled = source.enabled
            draft.thresholdMB = ProviderUsageEditor.number(Double(source.refreshPolicy.byteThreshold) / 1_000_000)
            draft.minimumHours = ProviderUsageEditor.number(source.refreshPolicy.minimumInterval / 3600)
            draft.maximumHours = ProviderUsageEditor.number(source.refreshPolicy.maximumInterval / 3600)
        }
        originalAPI = app.apiBalance.sources.first { UsagePresentationSourceID.api($0.id) == key }
        original = draft
    }
}
