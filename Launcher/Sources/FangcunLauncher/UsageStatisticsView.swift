import AppKit
import SwiftUI
import LauncherCore

enum ProviderUsageFormatting {
    static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.locale = .current; formatter.timeZone = timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date) + " · " + (timeZone.abbreviation(for: date) ?? timeZone.identifier)
    }
    static func time(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.locale = .current; formatter.timeZone = timeZone
        var calendar = Calendar.current; calendar.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: Date()) ? "HH:mm" : "M/d HH:mm"
        return formatter.string(from: date)
    }
    static func resetDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.locale = .current; formatter.timeZone = timeZone
        formatter.dateFormat = "M 月 d 日 HH:mm"; return formatter.string(from: date)
    }
    static func zone(_ timeZone: TimeZone) -> String { timeZone.localizedName(for: .generic, locale: .current) ?? timeZone.identifier }
    static func amount(_ bytes: UInt64, unit: ProviderUsageDisplayUnit) -> String {
        (Double(bytes) / unit.divisor).formatted(.number.precision(.fractionLength(0...2)))
    }
    static func resetValue(_ snapshot: ProviderUsageSnapshot, timeZone: TimeZone) -> String {
        if let date = snapshot.resetsAt { return resetDate(date, timeZone: timeZone) }
        return snapshot.resetDateText ?? "未提供"
    }
    static func resetDetail(_ snapshot: ProviderUsageSnapshot, timeZone: TimeZone) -> String {
        if let date = snapshot.resetsAt { return timestamp(date, timeZone: timeZone) }
        if let date = snapshot.resetDateText { return date + " · 服务商日期，时区未提供" }
        return "未提供"
    }
    static func resetTimeZoneDescription(_ date: Date, timeZone: TimeZone) -> String {
        let offset = timeZone.secondsFromGMT(for: date), magnitude = abs(offset)
        let utc = String(format: "UTC%@%02d:%02d", offset >= 0 ? "+" : "−", magnitude / 3600, (magnitude % 3600) / 60)
        return timeZone.identifier + "（" + utc + "）"
    }
}

/// Presentation state survives navigation attempts and participates in the
/// workbench's existing shared modal/draft protection.
@MainActor final class ProviderUsagePresentation: ObservableObject {
    @Published var selectedSourceID: UUID?
    @Published var editor: ProviderUsageEditor?
    @Published var discardEditor = false
    @Published var removing: ProviderUsageConfiguration?
    @Published var isRemoving = false
    @Published var showingBrowserSetup = false
    @Published var showingConfiguration = false
    @Published var configurationGroup: UsageCardGroup = .ai
    @Published var aiEditor: UsageAIEditor?
    var blocksNavigation: Bool {
        editor != nil || aiEditor != nil || showingConfiguration || showingBrowserSetup || removing != nil
    }
    func edit(_ source: ProviderUsageConfiguration, appearance: UsageCardAppearance = .init()) {
        showingConfiguration = false; editor = ProviderUsageEditor(source: source, existing: true, appearance: appearance)
    }
    func add(_ kind: ProviderUsageKind) {
        showingConfiguration = false; editor = ProviderUsageEditor(source: .init(kind: kind, name: kind.title, resourceID: ""), existing: false)
    }
    func configure(_ group: UsageCardGroup = .ai) { configurationGroup = group; showingConfiguration = true }
    func editAI(_ provider: AIProvider, appearance: UsageCardAppearance) {
        showingConfiguration = false; aiEditor = UsageAIEditor(provider: provider, appearance: appearance)
    }
    func requestCloseEditor() {
        guard let editor, !editor.saving else { return }
        if editor.hasChanges { discardEditor = true } else { self.editor = nil }
    }
    func requestCloseAIEditor() {
        guard let aiEditor else { return }
        if aiEditor.hasChanges { discardEditor = true } else { self.aiEditor = nil }
    }
    func discard() { editor?.secret = ""; editor = nil; aiEditor = nil; discardEditor = false }
}

@MainActor final class ProviderUsageEditor: ObservableObject, Identifiable {
    let id = UUID()
    let original: ProviderUsageConfiguration
    let existing: Bool
    @Published var kind: ProviderUsageKind
    @Published var name: String
    @Published var resourceID: String
    @Published var enabled: Bool
    @Published var thresholdMB: String
    @Published var minimumHours: String
    @Published var maximumHours: String
    @Published var secret = ""
    @Published var saving = false
    @Published var error: String?
    @Published var cardAppearance: UsageCardAppearance
    let originalAppearance: UsageCardAppearance
    init(source: ProviderUsageConfiguration, existing: Bool, appearance: UsageCardAppearance = .init()) {
        original = source; self.existing = existing; kind = source.kind; name = source.name
        cardAppearance = appearance; originalAppearance = appearance
        resourceID = source.resourceID; enabled = source.enabled
        thresholdMB = Self.number(Double(source.refreshPolicy.byteThreshold) / 1_000_000)
        minimumHours = Self.number(source.refreshPolicy.minimumInterval / 3600)
        maximumHours = Self.number(source.refreshPolicy.maximumInterval / 3600)
    }
    static func number(_ value: Double) -> String { value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...6))) }
    var canKeepCredential: Bool {
        existing && original.credentialID != nil && kind == original.kind
            && resourceID.trimmingCharacters(in: .whitespacesAndNewlines) == original.resourceID
    }
    var credentialPlaceholder: String { canKeepCredential ? "留空保留现有凭据" : "填写此实例的 API Key" }
    var verifiesCredential: Bool {
        kind == .bandwagon && (!canKeepCredential || !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var saveTitle: String { verifiesCredential ? "验证并保存" : existing ? "保存修改" : "保存来源" }
    var savingTitle: String { verifiesCredential ? "正在验证连接" : existing ? "正在保存修改" : "正在保存来源" }
    var hasChanges: Bool {
        !secret.isEmpty || cardAppearance != originalAppearance || kind != original.kind || name != original.name || resourceID != original.resourceID || enabled != original.enabled
        || thresholdMB != Self.number(Double(original.refreshPolicy.byteThreshold) / 1_000_000)
        || minimumHours != Self.number(original.refreshPolicy.minimumInterval / 3600)
        || maximumHours != Self.number(original.refreshPolicy.maximumInterval / 3600)
    }
    func configuration() throws -> ProviderUsageConfiguration {
        guard let mb = Double(thresholdMB), mb.isFinite, mb >= 1, mb <= 10_000_000,
              let minimum = Double(minimumHours), let maximum = Double(maximumHours) else { throw ProviderUsageFailure.invalidConfiguration }
        var value = original
        value.kind = kind; value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.resourceID = resourceID.trimmingCharacters(in: .whitespacesAndNewlines); value.enabled = enabled
        value.refreshPolicy = .init(byteThreshold: UInt64((mb * 1_000_000).rounded()), minimumInterval: minimum * 3600, maximumInterval: maximum * 3600)
        try value.validate(); return value
    }
}

struct UsageStatisticsView: View {
    @ObservedObject var app: WorkbenchAppModel
    @ObservedObject var model: ProviderUsageModel
    @ObservedObject var ai: AIUsageModel
    @ObservedObject var presentation: ProviderUsagePresentation
    @ObservedObject var context: WorkbenchContextModel
    @ObservedObject var appearance: UsagePresentationModel
    @Environment(\.workbenchPalette) private var palette
    init(app: WorkbenchAppModel) {
        self.app = app; model = app.providerUsage; ai = app.ai; presentation = app.usagePresentation
        context = app.context; appearance = app.usageAppearance
    }
    private var visibleAI: [AIProvider] {
        AIProvider.allCases.filter { appearance.appearance(for: UsagePresentationSourceID.ai($0)).visible }
    }
    private var visibleServices: [ProviderUsageConfiguration] {
        model.sources.filter { appearance.appearance(for: UsagePresentationSourceID.service($0.id)).visible }
    }
    var body: some View {
        Group {
            if ai.destination != .overview { aiContent }
            else if let id = presentation.selectedSourceID, let source = model.sources.first(where: { $0.id == id }) { detail(source) }
            else { overview }
        }
        .workbenchModal(isPresented: $presentation.showingConfiguration, width: 600) {
            UsageConfigurationView(app: app, model: model, ai: ai, presentation: presentation, appearance: appearance)
        }
        .workbenchModal(item: $presentation.aiEditor, width: 560, onRequestDismiss: presentation.requestCloseAIEditor) { editor in
            UsageAIEditorView(editor: editor, presentation: presentation, appearance: appearance)
        }
        .workbenchModal(item: $presentation.editor, width: 560, onRequestDismiss: presentation.requestCloseEditor) { editor in
            ProviderUsageEditorView(editor: editor, model: model, presentation: presentation, appearance: appearance)
        }
        .workbenchModal(isPresented: $presentation.discardEditor, width: 420) {
            WorkbenchDialogFrame(title: "放弃此次编辑？", dismiss: { presentation.discardEditor = false }) {
                Text("尚未保存的修改会被丢弃，原连接保持不变。").font(.system(size: 12)).foregroundStyle(palette.secondary)
            } actions: {
                Spacer(); Button("继续编辑") { presentation.discardEditor = false }.buttonStyle(WBButtonStyle())
                Button("放弃修改") { presentation.discard() }.buttonStyle(WBButtonStyle(destructive: true))
            }
        }
        .workbenchModal(item: $presentation.removing, width: 440, onRequestDismiss: { if !presentation.isRemoving { presentation.removing = nil } }) { source in
            WorkbenchDialogFrame(title: "移除“\(source.name)”？", dismiss: { if !presentation.isRemoving { presentation.removing = nil } }) {
                Text("停止此来源的查询，并移除方寸保存的额度记录及对应凭据。不会注销、退订或修改服务商账户。").font(.system(size: 12)).foregroundStyle(palette.secondary)
                if let error = model.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning) }
            } actions: {
                if presentation.isRemoving { ProgressView().controlSize(.small) }
                Spacer(); Button("取消") { presentation.removing = nil }.buttonStyle(WBButtonStyle()).disabled(presentation.isRemoving)
                Button("移除来源") {
                    guard !presentation.isRemoving else { return }
                    presentation.isRemoving = true
                    Task { @MainActor in
                        if await model.remove(id: source.id) {
                            _ = appearance.removeAppearance(for: UsagePresentationSourceID.service(source.id))
                            presentation.removing = nil; presentation.selectedSourceID = nil
                        }
                        presentation.isRemoving = false
                    }
                }.buttonStyle(WBButtonStyle(destructive: true)).disabled(presentation.isRemoving)
            }
        }
        .workbenchModal(isPresented: $presentation.showingBrowserSetup, width: 540) {
            ProviderBrowserSetupView(app: app, close: { presentation.showingBrowserSetup = false })
        }
        .workbenchModal(isPresented: Binding(get: { overviewError != nil && presentation.editor == nil && presentation.aiEditor == nil && presentation.removing == nil && !presentation.showingConfiguration }, set: { if !$0 { clearOverviewError() } }), width: 470) {
            WorkbenchDialogFrame(title: "用量与额度", dismiss: clearOverviewError) {
                Text(overviewError ?? "").font(.system(size: 12)).foregroundStyle(palette.secondary)
            } actions: { Spacer(); Button("知道了", action: clearOverviewError).buttonStyle(WBButtonStyle(primary: true)) }
        }
        .onChange(of: model.sources.map(\.id)) { _, ids in
            if let selected = presentation.selectedSourceID, !ids.contains(selected) { presentation.selectedSourceID = nil }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("fc.page.usage")
    }
    private var overviewError: String? {
        model.errorMessage ?? appearance.errorMessage ?? (ai.destination == .overview ? ai.errorMessage : nil)
    }
    private func clearOverviewError() {
        model.errorMessage = nil; appearance.errorMessage = nil
        if ai.destination == .overview { ai.errorMessage = nil }
    }
    private var aiContent: some View {
        AIUsageModuleView(model: ai, openDesktopCards: { app.navigate(.cards) }, returnToSettingsPrivacy: { app.navigate(.settings); app.settingsTab = .privacy }, overviewTitle: "用量与额度")
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: "用量与额度", subtitle: "各来源独立计量，分别保留额度与重置周期") {
                HStack(spacing: 8) {
                    Button {
                        ai.refresh()
                        for source in model.sources where source.enabled { model.refresh(id: source.id, manual: true) }
                    } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        .buttonStyle(WBButtonStyle()).disabled(ai.isRefreshing || !model.refreshing.isEmpty)
                        .accessibilityIdentifier("fc.usage.refresh")
                    Button { presentation.configure() } label: { Label("配置用量", systemImage: "slider.horizontal.3") }
                        .buttonStyle(WBButtonStyle()).accessibilityIdentifier("fc.usage.configure")
                }
            }
            storageProtection
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    groupHeader(.ai, title: "AI 用量", count: visibleAI.count, summary: aiSummary) {
                        Button { presentation.selectedSourceID = nil; ai.selectedProvider = nil; ai.show(.history) } label: { Label("本机 Token 记录", systemImage: "chart.bar.xaxis") }
                            .buttonStyle(WBButtonStyle(compact: true)).accessibilityIdentifier("fc.usage.tokens")
                    }
                    if !appearance.isCollapsed(.ai) {
                        if visibleAI.isEmpty { emptyGroup("还没有显示的 AI 卡片", group: .ai) }
                        else {
                            UsageCardGrid {
                                ForEach(visibleAI) { provider in
                                    let display = appearance.appearance(for: UsagePresentationSourceID.ai(provider))
                                    Button { presentation.selectedSourceID = nil; ai.show(.provider(provider)) } label: {
                                        UsageAIQuotaCard(summary: summary(provider), display: display, appearance: appearance,
                                                         enabled: ai.configuration(for: provider).enabled, timeZone: context.dateContext.timeZone)
                                    }.buttonStyle(ClickablePlainButtonStyle())
                                        .accessibilityLabel((display.displayName ?? provider.title) + "，查看额度详情")
                                        .accessibilityIdentifier("fc.ai.provider." + provider.rawValue)
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    groupHeader(.service, title: "服务流量", count: visibleServices.count, summary: serviceSummary) { EmptyView() }
                    if !appearance.isCollapsed(.service) {
                        if visibleServices.isEmpty { emptyGroup("连接每笔订单或每台服务器，查看独立额度", group: .service) }
                        else {
                            UsageCardGrid {
                                ForEach(visibleServices) { source in
                                    Button { presentation.selectedSourceID = source.id } label: {
                                        ProviderQuotaCard(source: source, state: model.state(for: source.id), refreshing: model.refreshing.contains(source.id),
                                                          display: appearance.appearance(for: UsagePresentationSourceID.service(source.id)), appearance: appearance,
                                                          timeZone: context.dateContext.timeZone)
                                    }.buttonStyle(ClickablePlainButtonStyle())
                                        .accessibilityLabel(source.name + "，查看额度详情").accessibilityIdentifier("fc.usage.source." + source.id.uuidString)
                                }
                            }
                        }
                    }
                }
            }
            Text("本机网速与流量预算仍在「网络监控」").font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 22)
        }.frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(palette.text)
    }
    @ViewBuilder private var storageProtection: some View {
        if let error = model.storageError ?? appearance.storageError {
            WBCard(title: "用量记录需要恢复", symbol: "exclamationmark.shield") {
                Text(error).font(.system(size: 11)).foregroundStyle(palette.warning)
                Text("原文件已保留，修复前暂停对应记录的修改。").font(.system(size: 11)).foregroundStyle(palette.secondary)
            }.padding(.bottom, 12)
        }
        if !ai.storageReadErrors.isEmpty {
            WBCard(title: "本机 AI 文件需要恢复", symbol: "exclamationmark.shield") {
                Text(ai.storageReadErrors.keys.sorted().joined(separator: "、") + " 读取失败，原件已保留。").font(.system(size: 11)).foregroundStyle(palette.warning)
                Button("打开 AI 数据目录") { ai.revealDataDirectory() }.buttonStyle(WBButtonStyle(compact: true))
            }.padding(.bottom, 12)
        }
    }
    private func summary(_ provider: AIProvider) -> AIProviderSummary {
        ai.providerSummaries.first { $0.provider == provider } ?? .init(provider: provider, state: .unavailable, snapshot: nil, detail: "尚无有效额度读数。")
    }
    private var aiSummary: String {
        let missing = visibleAI.filter {
            let value = summary($0)
            return value.state != .ready || (value.snapshot?.availableWindows.contains { $0.usedPercent >= 90 } ?? false)
        }.count
        return missing == 0 ? "无提醒" : "\(missing) 个来源需留意"
    }
    private var serviceSummary: String {
        let pending = visibleServices.filter { model.state(for: $0.id).status(maximumAge: $0.refreshPolicy.maximumInterval) == .pending }.count
        let other = visibleServices.filter {
            let value = model.state(for: $0.id)
            let status = value.status(maximumAge: $0.refreshPolicy.maximumInterval)
            return status != .pending && (status != .ready || (value.snapshot?.usedPercent ?? 0) >= 90)
        }.count
        return pending > 0 ? "\(pending) 个待连接" + (other > 0 ? " · \(other) 个需留意" : "") : other > 0 ? "\(other) 个来源需留意" : "无提醒"
    }
    private func groupHeader<Trailing: View>(_ group: UsageCardGroup, title: String, count: Int, summary: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Button { _ = appearance.setCollapsed(!appearance.isCollapsed(group), group: group) } label: {
                HStack(spacing: 6) {
                    Image(systemName: appearance.isCollapsed(group) ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .medium))
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text("\(count) 个来源").font(.system(size: 11)).foregroundStyle(palette.muted)
                }.frame(minHeight: 28)
            }.buttonStyle(WBQuietButtonStyle()).accessibilityLabel((appearance.isCollapsed(group) ? "展开" : "折叠") + title)
                .accessibilityValue(appearance.isCollapsed(group) ? "已折叠" : "已展开").accessibilityIdentifier("fc.usage.group." + group.rawValue)
            if appearance.isCollapsed(group) {
                Text(summary).font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
            }
            Spacer(minLength: 4)
            trailing()
        }.frame(minHeight: 28)
    }
    private func emptyGroup(_ title: String, group: UsageCardGroup) -> some View {
        WBCard(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(palette.secondary)
            Button(group == .ai ? "配置 AI 卡片" : "添加服务流量") { presentation.configure(group) }.buttonStyle(WBButtonStyle(compact: true))
        }
    }
    private func detail(_ source: ProviderUsageConfiguration) -> some View {
        let state = model.state(for: source.id)
        let display = appearance.appearance(for: UsagePresentationSourceID.service(source.id))
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Button { presentation.selectedSourceID = nil } label: { Label("返回用量与额度", systemImage: "chevron.left") }.buttonStyle(WBButtonStyle(compact: true)); Spacer() }.padding(.bottom, 2)
            WBPageHeader(title: display.displayName ?? source.name, subtitle: source.kind.title + " · " + (source.kind == .iproyal ? "订单 " : "实例 ") + source.resourceID) {
                HStack(spacing: 8) {
                    Button("刷新") { model.refresh(id: source.id, manual: true) }.buttonStyle(WBButtonStyle()).disabled(model.refreshing.contains(source.id))
                    Button("配置用量") { presentation.configure(.service) }.buttonStyle(WBButtonStyle())
                }
            }
            serviceDetailSummary(state)
            if state.refresh.authenticationRequired {
                WBCard(title: "恢复连接", symbol: "person.crop.circle.badge.exclamationmark") {
                    Text(source.kind == .iproyal ? "在 Chrome 中恢复 IPRoyal 登录，再点击重新连接。登录会话由浏览器保留。" : "请核对实例编号与 API Key，在配置中重新验证。原有效读数会保留。")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                    Button("重新连接") { if source.kind == .iproyal { model.reconnect(id: source.id) } else { presentation.edit(source, appearance: display) } }.buttonStyle(WBButtonStyle(primary: true))
                }
            }
            WBCard(title: "周期与来源", spacing: 12) {
                if let snapshot = state.snapshot {
                    detailRow("下次重置", ProviderUsageFormatting.resetDetail(snapshot, timeZone: context.dateContext.timeZone))
                    if source.kind == .bandwagon, let reset = snapshot.resetsAt {
                        Text("重置时刻来自平台时间戳，按 " + ProviderUsageFormatting.resetTimeZoneDescription(reset, timeZone: context.dateContext.timeZone) + " 显示；以每次查询结果为准。")
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                            .accessibilityIdentifier("fc.usage.bandwagon.reset-explanation")
                    }
                    detailRow("计量来源", snapshot.sourceDescription)
                    detailRow("查询时间", ProviderUsageFormatting.timestamp(snapshot.observedAt, timeZone: context.dateContext.timeZone))
                    detailRow("单位口径", snapshot.displayUnit.explanation)
                }
                detailRow("连接方式", source.kind == .bandwagon ? "实例 API Key · 本机钥匙串" : "Chrome 网页助手 · 浏览器登录会话")
                if source.kind == .bandwagon {
                    detailRow("统计口径", "按服务商账单口径汇总")
                    Text("总额与用量使用平台系数换算，不额外乘倍。本机流量仅触发更新，不从此余额中扣除。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                        .accessibilityIdentifier("fc.usage.bandwagon.accounting-explanation")
                }
                detailRow("统计截止", "平台未提供")
                if let url = ProviderUsageExternalLinks.url(for: source) {
                    Button { NSWorkspace.shared.open(url) } label: { Label(ProviderUsageExternalLinks.title(for: source), systemImage: "arrow.up.right") }
                        .buttonStyle(WBButtonStyle(compact: true))
                        .accessibilityLabel(ProviderUsageExternalLinks.title(for: source))
                        .accessibilityIdentifier("fc.usage.order-link")
                }
                if source.kind == .iproyal { resetObservation(state) }
            }
            WBCard(title: "自动更新", spacing: 12) {
                detailRow("流量触发", "本机累计 " + ProviderUsageEditor.number(Double(source.refreshPolicy.byteThreshold) / 1_000_000) + " MB，且至少间隔 " + ProviderUsageEditor.number(source.refreshPolicy.minimumInterval / 3600) + " 小时")
                detailRow("低流量补查", "最长间隔 " + ProviderUsageEditor.number(source.refreshPolicy.maximumInterval / 3600) + " 小时")
                Text("本机流量只判断是否需要更新，不从服务商余额中扣除。休眠或断网期间不补造数据。").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            HStack {
                if source.kind == .iproyal { Button("浏览器连接设置") { presentation.showingBrowserSetup = true }.buttonStyle(WBButtonStyle(compact: true)) }
                Spacer()
                Button("编辑来源") { presentation.edit(source, appearance: display) }.buttonStyle(WBButtonStyle(compact: true))
                Button("移除来源") { model.errorMessage = nil; presentation.removing = source }.buttonStyle(WBButtonStyle(destructive: true))
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("fc.usage.detail")
    }
    private func serviceDetailSummary(_ state: ProviderUsageSourceState) -> some View {
        WBCard(spacing: 12) {
            if let snapshot = state.snapshot {
                HStack(alignment: .center, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("本周期剩余").font(.system(size: 11)).foregroundStyle(palette.muted)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(ProviderUsageFormatting.amount(snapshot.remaining, unit: snapshot.displayUnit)).font(.system(size: 32)).monospacedDigit()
                            Text("GB").font(.system(size: 12)).foregroundStyle(palette.secondary)
                        }
                    }.frame(minWidth: 190, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("本周期消耗"); Spacer(); Text(snapshot.usedPercent.formatted(.number.precision(.fractionLength(0...1))) + "%") }
                            .font(.system(size: 11)).foregroundStyle(palette.secondary)
                        WBProgress(value: min(1, max(0, snapshot.usedPercent / 100)), height: 4)
                        HStack {
                            Text(ProviderUsageFormatting.amount(snapshot.usedBytes, unit: snapshot.displayUnit) + " / " + ProviderUsageFormatting.amount(snapshot.limitBytes, unit: snapshot.displayUnit) + " GB")
                            Spacer()
                            Text("更新于 " + ProviderUsageFormatting.time(snapshot.observedAt, timeZone: context.dateContext.timeZone))
                        }.font(.system(size: 11)).foregroundStyle(palette.muted).monospacedDigit()
                    }
                }
            } else {
                Text("尚无有效读数").font(.system(size: 14, weight: .medium))
                Text("完成连接后显示此来源的实际读数。").font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
            if let message = state.message { Text(message).font(.system(size: 11)).foregroundStyle(palette.warning) }
        }
    }
    @ViewBuilder private func resetObservation(_ state: ProviderUsageSourceState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("周期变化记录").font(.system(size: 12, weight: .medium))
            if let observation = state.pendingResetObservation ?? state.resetObservations.last {
                detailRow("上次旧周期读数", ProviderUsageFormatting.timestamp(observation.lastOldObservedAt, timeZone: context.dateContext.timeZone))
                detailRow("首次看到新周期", ProviderUsageFormatting.timestamp(observation.firstNewObservedAt, timeZone: context.dateContext.timeZone))
                detailRow("后续确认", observation.confirmedAt.map { ProviderUsageFormatting.timestamp($0, timeZone: context.dateContext.timeZone) } ?? "等待下一次有效读数")
            } else { Text("尚未观测到周期变化").font(.system(size: 11)).foregroundStyle(palette.muted) }
            Text("记录查询时看到的变化。服务商统计可能延迟，实际重置时刻与时区尚未确认。").font(.system(size: 11)).foregroundStyle(palette.muted)
        }.padding(.top, 12).overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }
    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).foregroundStyle(palette.muted).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled); Spacer(minLength: 0)
        }.font(.system(size: 12))
    }
}

private struct ProviderUsageEditorView: View {
    @ObservedObject var editor: ProviderUsageEditor
    @ObservedObject var model: ProviderUsageModel
    @ObservedObject var presentation: ProviderUsagePresentation
    @ObservedObject var appearance: UsagePresentationModel
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchDialogFrame(title: editor.existing ? "配置用量来源" : "添加用量来源", dismiss: presentation.requestCloseEditor, maximumBodyHeight: 420) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    field("服务平台") { WBSelect("服务平台", selection: $editor.kind, options: ProviderUsageKind.allCases.map { (value: $0, title: $0.title) }).disabled(editor.existing) }
                    field("卡片名称") { TextField("自定义显示名称", text: $editor.name).textFieldStyle(ProviderUsageFieldStyle()) }
                }
                UsageIconPicker(selection: $editor.cardAppearance.icon, appearance: appearance, serviceKind: editor.kind)
                field(editor.kind == .bandwagon ? "实例编号 VEID" : "静态 ISP 订单编号") {
                    TextField(editor.kind == .bandwagon ? "KiwiVM 中的 VEID" : "订单详情中的编号", text: $editor.resourceID).textFieldStyle(ProviderUsageFieldStyle())
                        .accessibilityLabel(editor.kind == .bandwagon ? "实例编号 VEID" : "静态 ISP 订单编号")
                        .accessibilityIdentifier("fc.usage.editor.resource-id")
                }
                if editor.kind == .bandwagon {
                    field("API Key") {
                        SecureField(editor.credentialPlaceholder, text: $editor.secret).textFieldStyle(ProviderUsageFieldStyle())
                            .accessibilityLabel("API Key").accessibilityIdentifier("fc.usage.editor.api-key")
                    }
                    bandwagonConnectionHelp
                } else {
                    Text("使用 Chrome 网页助手连接现有 IPRoyal 登录；无需填写官方 API Token，也不需要修改 Google 登录方式。首次安装和流量读取仍需验证。").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                HStack(spacing: 12) {
                    field("累计阈值 · MB") { TextField("1000", text: $editor.thresholdMB).textFieldStyle(ProviderUsageFieldStyle()) }
                    field("最短间隔 · 小时") { TextField("1", text: $editor.minimumHours).textFieldStyle(ProviderUsageFieldStyle()) }
                    field("最长间隔 · 小时") { TextField("6", text: $editor.maximumHours).textFieldStyle(ProviderUsageFieldStyle()) }
                }
                Text("1 GB = 1000 MB。累计流量与时间共同触发；不同来源独立计算。").font(.system(size: 11)).foregroundStyle(palette.muted)
                Toggle("自动更新此来源", isOn: $editor.enabled).toggleStyle(.switch).controlSize(.small)
                Toggle("在概览中显示", isOn: $editor.cardAppearance.visible).toggleStyle(.switch).controlSize(.small)
                if let error = editor.error { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning).accessibilityIdentifier("fc.usage.editor.error") }
                if let error = appearance.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning) }
            }.padding(.vertical, 2).disabled(editor.saving)
        } actions: {
            if editor.saving { ProgressView().controlSize(.small); Text(editor.savingTitle).font(.system(size: 11)).foregroundStyle(palette.muted) }
            Spacer()
            Button("取消", action: presentation.requestCloseEditor).buttonStyle(WBButtonStyle()).disabled(editor.saving)
                .accessibilityIdentifier("fc.usage.editor.cancel")
            Button(editor.saveTitle) { save() }.buttonStyle(WBButtonStyle(primary: true)).disabled(editor.saving)
                .accessibilityIdentifier("fc.usage.editor.save")
        }
        .onChange(of: editor.kind) { old, new in if editor.name == old.title { editor.name = new.title }; editor.secret = ""; editor.error = nil }
        .accessibilityIdentifier("fc.usage.editor")
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 12)); content() }
    }
    private var bandwagonConnectionHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("获取连接信息").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Button {
                    NSWorkspace.shared.open(URL(string: "https://bandwagonhost.com/services")!)
                } label: { Label("打开搬瓦工服务", systemImage: "arrow.up.right") }
                    .buttonStyle(WBButtonStyle())
                    .accessibilityIdentifier("fc.usage.editor.bandwagon-services")
            }
            Text("登录后选择目标 VPS，打开 Open KiwiVM → API → Show API Key，将此实例的 VEID 和现有 API Key 填入上方。")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            Text("无需账号密码或浏览器连接器。请勿点击 Reset API Key。密钥只填在这里，不发送到聊天；验证成功后保存在本机钥匙串。")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
        }.padding(12)
            .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("fc.usage.editor.bandwagon-help")
    }
    private func save() {
        guard !editor.saving else { return }
        let candidate: ProviderUsageConfiguration
        do { candidate = try editor.configuration() } catch { editor.error = error.localizedDescription; return }
        editor.saving = true; editor.error = nil
        Task { @MainActor in
            let success = await model.save(candidate, secret: editor.secret.isEmpty ? nil : editor.secret)
            editor.saving = false
            if success {
                var display = editor.cardAppearance; display.displayName = nil
                _ = appearance.saveAppearance(display, for: UsagePresentationSourceID.service(candidate.id))
                editor.secret = ""; presentation.editor = nil; presentation.selectedSourceID = candidate.id
            }
            else { editor.error = model.errorMessage ?? "连接未保存，请检查设置后重试。"; model.errorMessage = nil }
        }
    }
}

private struct ProviderUsageFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 12)).padding(.horizontal, 10).frame(height: 32)
            .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
    }
}

private struct ProviderBrowserSetupView: View {
    @ObservedObject var app: WorkbenchAppModel
    let close: () -> Void
    @Environment(\.workbenchPalette) private var palette
    @State private var message: String?
    var body: some View {
        WorkbenchDialogFrame(title: "IPRoyal 浏览器连接", dismiss: close) {
            VStack(alignment: .leading, spacing: 13) {
                Text("在 Chrome 中继续使用 Google 登录").font(.system(size: 13, weight: .medium))
                Text("浏览器助手只在 IPRoyal 控制台读取订单额度，再交给本机方寸。不会读取 Google 页面、密码、Cookie 或 API Token。").font(.system(size: 12)).foregroundStyle(palette.secondary)
                Text("1. 导出连接包，按包内说明安装本机连接和 Chrome 扩展。\n2. 在 Chrome 中登录 IPRoyal，打开静态 ISP 订单。\n3. 在方寸添加订单编号，执行首次查询并核对额度。").font(.system(size: 12)).lineSpacing(5)
                Text("登录状态由服务商决定。浏览器关闭或会话失效时，自动查询可能暂停；重新登录后可继续更新，最后有效读数和查询时间会保留。").font(.system(size: 11)).foregroundStyle(palette.muted)
                if let message { Text(message).font(.system(size: 11)).foregroundStyle(palette.secondary) }
            }
        } actions: {
            Button("在 Chrome 中打开") {
                guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
                    message = "未找到 Google Chrome。请先安装 Chrome，再按连接包说明启用助手。"; return
                }
                NSWorkspace.shared.open([URL(string: "https://dashboard.iproyal.com/me/products/static-residential-proxies")!], withApplicationAt: chrome, configuration: .init()) { _, error in
                    if error != nil { Task { @MainActor in message = "无法打开 Chrome，请手动进入 IPRoyal 控制台。" } }
                }
            }.buttonStyle(WBButtonStyle())
            Spacer()
            Button("导出连接包") { app.exportProviderBrowserKit { message = $0 } }.buttonStyle(WBButtonStyle(primary: true))
        }
    }
}
