import AppKit
import Charts
import SwiftUI
import LauncherCore

/// Opt-in inspection of the production layout. A whole-card Button deliberately
/// exposes one accessibility action, so its internal metric frames are measured
/// through mounted, noninteractive native backgrounds instead of AX glyph boxes.
/// The default environment is nil and normal app views create no probes.
@MainActor final class AIQuotaLayoutInspection {
    private final class WeakView {
        weak var value: NSView?
        init(_ value: NSView) { self.value = value }
    }
    private var views: [String: WeakView] = [:]
    fileprivate func register(_ view: NSView, identifier: String) { views[identifier] = WeakView(view) }
    func frame(_ identifier: String) -> NSRect? {
        guard let view = views[identifier]?.value, let window = view.window else { return nil }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        guard rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else { return nil }
        return rect
    }
}
private struct AIQuotaLayoutInspectionKey: EnvironmentKey {
    static let defaultValue: AIQuotaLayoutInspection? = nil
}
extension EnvironmentValues {
    var aiQuotaLayoutInspection: AIQuotaLayoutInspection? {
        get { self[AIQuotaLayoutInspectionKey.self] }
        set { self[AIQuotaLayoutInspectionKey.self] = newValue }
    }
}
private struct AIQuotaLayoutProbe: NSViewRepresentable {
    let identifier: String
    let inspection: AIQuotaLayoutInspection
    func makeNSView(context: Context) -> NSView {
        let view = AIQuotaPassthroughProbe()
        inspection.register(view, identifier: identifier)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { inspection.register(view, identifier: identifier) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        .init(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
private final class AIQuotaPassthroughProbe: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
private struct AIQuotaMeasuredRegion: ViewModifier {
    let identifier: String
    @Environment(\.aiQuotaLayoutInspection) private var inspection
    func body(content: Content) -> some View {
        content.background {
            if let inspection {
                AIQuotaLayoutProbe(identifier: identifier, inspection: inspection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}
private extension View {
    func aiQuotaMeasuredRegion(_ identifier: String) -> some View { modifier(AIQuotaMeasuredRegion(identifier: identifier)) }
}

#if DEBUG
/// Layout inspection only. This holds the mounted manual form's actual UI
/// bindings; it cannot save a quota, connect a source or dispatch an OS action.
@MainActor final class AIManualDialogInspection {
    private var owner: UUID?
    private var expanded: Binding<Bool>?
    private var knownReset: Binding<Bool>?
    var isMounted: Bool { expanded != nil && knownReset != nil }
    fileprivate func attach(owner: UUID, expanded: Binding<Bool>, knownReset: Binding<Bool>) {
        self.owner = owner; self.expanded = expanded; self.knownReset = knownReset
    }
    fileprivate func detach(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil; expanded = nil; knownReset = nil
    }
    @discardableResult func setExpanded(_ value: Bool) -> Bool {
        guard let expanded else { return false }; expanded.wrappedValue = value; return true
    }
    @discardableResult func setKnownReset(_ value: Bool) -> Bool {
        guard let knownReset else { return false }; knownReset.wrappedValue = value; return true
    }
}
private struct AIManualDialogInspectionKey: EnvironmentKey {
    static let defaultValue: AIManualDialogInspection? = nil
}
extension EnvironmentValues {
    var aiManualDialogInspection: AIManualDialogInspection? {
        get { self[AIManualDialogInspectionKey.self] }
        set { self[AIManualDialogInspectionKey.self] = newValue }
    }
}
#endif

struct AIUsageModuleView: View {
    @ObservedObject var model: AIUsageModel
    var openDesktopCards: (() -> Void)? = nil
    var returnToSettingsPrivacy: (() -> Void)? = nil
    var overviewTitle = "AI 用量"
    var overviewSubtitle = "账户额度与本机活动，分别记录"
    var overviewRefreshTitle = "刷新"
    var overviewSourcesTitle = "来源管理"
    var overviewSupplement: AnyView? = nil
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchDeviceExpanded) private var expanded
    @Environment(\.timeZone) private var timeZone
    @Environment(\.usageDisplayLocation) private var displayLocation
    @State private var selectedResetWindow = 1
    @State private var contentWidth: CGFloat = 864
    @State private var selectedBucket: Date?
    @State private var sourcesMenuOpen = false
    private var visibleRecords: [AITokenRecord] { model.filteredRecords(provider: model.selectedProvider, period: model.selectedPeriod) }
    private var routeID: String {
        switch model.destination { case .overview: "fc.page.ai"; case .provider(let provider): "fc.page.ai." + provider.rawValue; case .sources: "fc.page.ai.sources"; case .history: "fc.page.ai.history"; case .prices: "fc.page.ai.prices" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.destination {
            case .overview: overview
            case .provider(let provider): providerDetail(provider)
            case .sources: sources
            case .history: history
            case .prices: prices
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .foregroundStyle(palette.text)
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { contentWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in contentWidth = width }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .accessibilityElement(children:.contain).accessibilityIdentifier(routeID)
        .workbenchModal(item: $model.dialog, width: 470, onRequestDismiss: { model.requestDismissDialog() }) { _ in
            AIUsageDialogContent(model: model)
        }
        .workbenchModal(isPresented: $model.confirmDiscardDialog, width: 440) {
            AIUsageDiscardDialog(model: model, price: false)
        }
        .workbenchModal(isPresented: $model.confirmDiscardPrice, width: 440) {
            AIUsageDiscardDialog(model: model, price: true)
        }
        .workbenchModal(isPresented: Binding(get: { model.errorMessage != nil && model.dialog == nil }, set: { if !$0 { model.errorMessage = nil } }), width: 470) {
            AIUsageErrorDialog(model: model)
        }
    }
    /// Sub-pages return from the title's left, named after the parent page (现行规范 4.1, D7).
    private var pageBack: WBPageBack {
        WBPageBack(title: model.backTitle(overviewTitle: overviewTitle), identifier: "fc.ai.back", escapes: true) { goBack() }
    }
    private func goBack() {
        if model.destination == .prices && model.hasUnsavedPriceChanges { model.requestPriceBack() }
        else if model.goBack() { returnToSettingsPrivacy?() }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: overviewTitle, subtitle: overviewSubtitle) {
                HStack(spacing: 8) {
                    Button { model.refresh() } label: { Label(overviewRefreshTitle, systemImage: "arrow.clockwise") }.buttonStyle(WBButtonStyle()).disabled(model.isRefreshing).accessibilityIdentifier("fc.ai.refresh")
                    Button { model.openSources() } label: { Label(overviewSourcesTitle, systemImage: "point.3.connected.trianglepath.dotted") }.buttonStyle(WBButtonStyle()).accessibilityIdentifier("fc.ai.sources")
                }
            }
            storageProtection
            AIWeightedColumns(ratio: 1, gap: 12) {
                providerCard(.codex)
                providerCard(.claude)
            }
            if let overviewSupplement { overviewSupplement.padding(.top, 20) }
            activitySectionHeader
            AIWeightedColumns(ratio: contentWidth < 800 ? 1.25 : 1.55, gap: 12) {
                tokenCard(visibleRecords, title: "Token 总量", showChart: true)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.overview.tokens")
                modelDistribution.accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.overview.models")
            }
            recentActivity.padding(.top, 12)
            privacyFootnote.padding(.top, 12)
        }
    }
    private var storageProtection: some View {
        Group {
            if !model.storageReadErrors.isEmpty {
                WBCard(title: "本机 AI 文件需要恢复", symbol: "exclamationmark.shield") {
                    Text(model.storageReadErrors.keys.sorted().joined(separator: "、") + " 读取失败，原件已保留，对应文件的写入已暂停。")
                        .aiText(11, color: palette.warning)
                    Text(model.storageRecoveryInstructions).aiText(11, color: palette.secondary)
                    Button("打开 AI 数据目录") { model.revealDataDirectory() }.buttonStyle(WBButtonStyle())
                }.padding(.bottom, 12)
            }
        }
    }
    private func summary(_ provider: AIProvider) -> AIProviderSummary {
        model.providerSummaries.first { $0.provider == provider } ?? .init(provider: provider, state: .unavailable, snapshot: nil, detail: "尚未读取此来源。")
    }
    private func providerCard(_ provider: AIProvider, detail: Bool = false) -> some View {
        AIProviderQuotaCard(summary: summary(provider), minimumHeight: detail ? (expanded ? 288 : 284) : (expanded ? 288 : 260.83), expanded: expanded, automaticReadingEnabled: model.configuration(for: provider).enabled, showsAction: !detail,
                            reading: model.isRefreshing, enable: detail ? { model.setEnabled(true, provider: provider) } : nil,
                            connect: detail && provider == .claude ? { model.present(.claudeConnect) } : nil) {
            if detail { model.openSources() } else { model.show(.provider(provider)) }
        }
    }
    private var activitySectionHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("本机 Token 活动").aiText(13, weight: .medium, color: palette.text)
                Text("当前筛选下的本机记录，不计入订阅额度").aiText(11, color: palette.muted)
            }
            Spacer(minLength: 8)
            filters
        }.padding(.top, 20).padding(.bottom, 12)
    }
    private var filters: some View {
        HStack(spacing: 8) {
            WBSelect("AI 来源", selection: $model.selectedProvider, options: [(value: Optional<AIProvider>.none, title: "全部来源")] + AIProvider.allCases.map { (value: Optional($0), title: $0.title) })
                .frame(width: 112).accessibilityIdentifier("fc.ai.filter.source")
            WBSelect("记录范围", selection: $model.selectedPeriod, options: AIUsagePeriod.allCases.map { (value: $0, title: $0.title) })
                .frame(width: 112).accessibilityIdentifier("fc.ai.filter.period")
        }
    }
    private func tokenCard(_ records: [AITokenRecord], title: String, showChart: Bool) -> some View {
        let totals = records.reduce(AITokenCounts()) { $0 + $1.tokens }
        let buckets = AIUsageAggregation.buckets(records, period: model.selectedPeriod, now: Date())
        return AIActionCard(actionTitle: "查看 Token 记录", action: { model.show(.history) }) {
            AICardTitle(title: title, symbol: "chart.bar.xaxis")
            Group {
                if contentWidth >= 800 {
                    HStack(alignment: .center, spacing: 14) {
                        tokenValue(totals.total)
                        Spacer(minLength: 0)
                        tokenParts(totals).fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) { tokenValue(totals.total); tokenParts(totals) }
                }
            }.padding(.top, 2)
            if showChart {
                Chart(buckets) { bucket in
                    BarMark(x: .value("时段", bucket.date, unit: model.selectedPeriod == .today ? .hour : .day), y: .value("Token", bucket.tokens.total))
                        .foregroundStyle(palette.accent.opacity(selectedBucket == bucket.date ? 1 : 0.58)).cornerRadius(3)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: model.selectedPeriod == .today ? .dateTime.hour() : .dateTime.month().day()) } }
                .chartYAxis(.hidden)
                .chartXSelection(value: $selectedBucket)
                .frame(height: expanded ? 170 : 110).padding(.top, 16)
                Text(bucketDetail(buckets, hasRecords: !records.isEmpty)).aiText(11, color: palette.muted).frame(minHeight: 16, alignment: .leading).padding(.top, 8)
            }
        }
    }
    private func tokenValue(_ total: Int64) -> some View {
        let divisor = total >= 1_000_000 ? 1_000_000.0 : total >= 1_000 ? 1_000.0 : 1.0
        let value = divisor == 1 ? total.formatted() : (Double(total) / divisor).formatted(.number.precision(.fractionLength(0...2)))
        let unit = divisor == 1_000_000 ? "M Token" : divisor == 1_000 ? "K Token" : "Token"
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.system(size: 24)).monospacedDigit()
            Text(unit).aiText(11, color: palette.muted)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("fc.ai.tokens.total")
    }
    private func tokenParts(_ totals: AITokenCounts) -> some View {
        Grid(alignment: .leading, horizontalSpacing: contentWidth < 800 ? 8 : 12, verticalSpacing: 6) {
            GridRow { tokenMetric("输入", count: totals.input); tokenMetric("输出", count: totals.output) }
            GridRow { tokenMetric("缓存读取", count: totals.cacheRead); tokenMetric("缓存写入", count: totals.cacheWrite) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.tokens.parts")
    }
    private func tokenMetric(_ title: String, count: Int64) -> some View {
        HStack(spacing: 6) { Text(title).aiText(11, color: palette.muted); Text(aiCount(count)).aiText(11, color: palette.secondary).monospacedDigit() }
    }
    private func bucketDetail(_ buckets: [AITokenBucket], hasRecords: Bool) -> String {
        guard let selectedBucket, let nearest = buckets.min(by: { abs($0.date.timeIntervalSince(selectedBucket)) < abs($1.date.timeIntervalSince(selectedBucket)) }) else {
            return hasRecords ? "选择时段查看计量明细 · 输入不含缓存" : "此范围内尚无可识别记录"
        }
        return nearest.date.formatted(date: model.selectedPeriod == .today ? .omitted : .abbreviated, time: model.selectedPeriod == .today ? .shortened : .omitted) + " · " + aiCount(nearest.tokens.total) + " Token"
    }
    private var distribution: [(name: String, tokens: Int64)] {
        Dictionary(grouping: visibleRecords, by: { $0.provider.title + " · " + $0.model })
            .map { (name: $0.key, tokens: $0.value.reduce(0) { $0 + $1.tokens.total }) }
            .sorted { $0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens }
    }
    private var modelDistribution: some View {
        let total = visibleRecords.reduce(Int64(0)) { $0 + $1.tokens.total }
        let estimate = model.estimate(visibleRecords)
        return AIActionCard(actionTitle: "管理模型单价", action: { model.show(.prices) }) {
            AICardTitle(title: "模型分布", symbol: "square.stack.3d.up")
            if distribution.isEmpty {
                Text("读取到有效计量记录后显示模型组成。").aiText(11, color: palette.muted).frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
            } else {
                ForEach(distribution.prefix(6), id: \.name) { row in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 5) {
                            Text(row.name).aiText(11, color: palette.secondary).lineLimit(1).help(row.name)
                            Spacer(minLength: 0)
                            Text((Double(row.tokens) / Double(max(1, total)) * 100).formatted(.number.precision(.fractionLength(0))) + "%").aiText(11, color: palette.muted).monospacedDigit()
                        }
                        WBProgress(value: Double(row.tokens) / Double(max(1, total)), height: 5)
                    }.padding(.bottom, 12)
                }
                if distribution.count > 6 { Button("另有 \(distribution.count - 6) 个模型，查看全部记录") { model.show(.history) }.buttonStyle(WBQuietButtonStyle()).padding(.bottom, 8) }
            }
            Rectangle().fill(palette.line).frame(height: 1).padding(.bottom, 12)
            HStack(alignment: .firstTextBaseline) {
                Text("API 等价估算").aiText(11, color: palette.muted)
                Spacer()
                Text(estimate.covered == 0 ? "未配置单价" : estimate.amount.formatted(.currency(code: "USD"))).aiText(13, weight: .medium, color: palette.text).monospacedDigit()
            }
            Text(estimate.covered == 0 ? "尚未配置单价，不代表账户账单。" : "单价覆盖 \(estimate.covered)/\(estimate.total) 条；估算不代表账户账单。").aiText(11, color: palette.muted).padding(.top, 7)
        }.frame(maxHeight: .infinity, alignment: .top)
    }
    private var recentActivity: some View {
        AIActionCard(actionTitle: "全部活动记录", action: { model.show(.history) }) {
            AICardTitle(title: "最近活动", symbol: "clock.arrow.circlepath")
            AITokenTable(records: Array(visibleRecords.sorted { $0.timestamp > $1.timestamp }.prefix(3)), model: model, compact: contentWidth < 800, scrollHeight: nil)
        }
    }
    private var privacyFootnote: some View {
        WBPageNote(symbol: "lock.shield") {
            HStack(spacing: 8) {
                Text("仅保存本机计量字段，不保存提示词或对话正文")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("口径说明") { model.present(.help) }.buttonStyle(WBQuietButtonStyle())
            }
        }
    }
    private func providerDetail(_ provider: AIProvider) -> some View {
        let value = summary(provider)
        return VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: provider.title + " 用量", subtitle: "额度按来源提供的窗口计算；Token 为本机活动计量", back: pageBack) {
                Button { model.present(.alert) } label: { Label("提醒设置", systemImage: "bell") }.buttonStyle(WBButtonStyle()).accessibilityIdentifier("fc.ai.alert")
            }
            storageProtection
            AIWeightedColumns(ratio: 1, gap: 12) {
                providerCard(provider, detail: true)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.detail.quota." + provider.rawValue)
                WBCard(spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.shield").font(.system(size: 16)).frame(width: 16, height: 16).foregroundStyle(palette.accent).accessibilityHidden(true)
                        Text("来源与有效性").aiText(13, weight: .medium, color: palette.text).accessibilityIdentifier("fc.ai.detail.validity.title")
                        Spacer(minLength: 0)
                        Button("管理来源") { model.openSources() }.buttonStyle(WBButtonStyle(compact: true)).accessibilityIdentifier("fc.ai.detail.manageSources")
                    }.frame(height: 22).padding(.bottom, 10)
                    AIFactRow(title: "来源类型", value: value.sourceDescription)
                    AIFactRow(title: "会员方案", value: value.accountPlanDescription)
                    AIFactRow(title: "最后有效读数", value: value.updatedAt.map { aiShortDateTime($0, timeZone: timeZone) } ?? "尚无读数")
                        .help(value.updatedAt.map { UsageDatePresentation.withZone($0, timeZone: timeZone, location: displayLocation) } ?? "")
                    // Only a valid reading is colored; other states stay neutral (现行规范 9.3, U2).
                    AIFactRow(title: "当前状态", value: model.configuration(for: provider).enabled ? value.state.title : "自动读取已关闭", color: value.state == .ready && model.configuration(for: provider).enabled ? palette.accent : nil)
                    AIFactRow(title: "过期判定", value: "15 分钟未更新或窗口已重置")
                    AIFactRow(title: "额度提醒", value: model.alertRule.enabled ? "\(model.alertRule.warningPercent)% / \(model.alertRule.criticalPercent)% · " + model.notificationPermission.title : "未开启", last: true)
                    // Keep the surface stretched after moving its action back
                    // to the frozen title row. Longer actual readings may grow.
                    Spacer(minLength: 0)
                }.frame(minHeight: expanded ? 288 : 284, alignment: .top)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.detail.validity")
            }
            resetDetails(value).padding(.top, 12)
            quotaHistory(provider).padding(.top, 12)
            AINotice(text: "每个点是当天最后一次实际读数，并非当日消耗；不同额度窗口各画一条线。无读数不代表 0，本机最多保留 31 天。", onBackdrop: true)
                .accessibilityIdentifier("fc.ai.detail.historyNotice").padding(.top, 12)
            AIWeightedColumns(ratio: 1, gap: 12) {
                providerTokenCard(provider)
                coverageCard(provider)
            }.padding(.top, 12)
        }
    }
    @ViewBuilder private func resetDetails(_ summary: AIProviderSummary) -> some View {
        if let windows = summary.snapshot?.availableWindows, !windows.isEmpty {
            let index = min(max(0, selectedResetWindow), windows.count - 1)
            WBCard(title: "重置时间", spacing: 14) {
                if windows.count > 1 {
                    WBSegmentedChoice(selection: Binding(get: { index }, set: { selectedResetWindow = $0 }),
                                      options: windows.enumerated().map { (value: $0.offset, title: $0.element.title) },
                                      identifier: "fc.ai.reset-windows", optionIdentifierPrefix: "fc.ai.reset-window.")
                }
                UsageResetDetailsView(reset: .init(window: windows[index]), timeZone: timeZone)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.reset-details")
        }
    }
    private func quotaHistory(_ provider: AIProvider) -> some View {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let history = AIQuotaDailyHistory.build(model.quotaHistory, provider: provider, calendar: calendar)
        let tokens = AIDailyTokenHistory.totals(model.records, provider: provider, calendar: calendar)
        return WBCard(spacing: 0) {
            AICardTitle(title: "每日额度与 Token", symbol: "chart.bar.xaxis", trailing: "最近 31 天")
            Text("额度是当天最后观测的窗口已用比例；Token 是本机当天记录的消耗。")
                .aiText(11, color: palette.secondary).padding(.top, 8).padding(.bottom, 16)
            AIDailyQuotaChart(series: history.series, days: history.days, tokens: tokens, calendar: calendar, identifier: provider.rawValue)
            Text("折线断开或「—」表示没有记录，不能视为 0。Token 含输入、输出及缓存；仅覆盖已连接来源，不换算账户额度。")
                .aiText(11, color: palette.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            Text("按工作台时区统计 · " + calendar.timeZone.identifier)
                .aiText(11, color: palette.muted).padding(.top, 5)
        }.aiQuotaMeasuredRegion("fc.ai.history." + provider.rawValue + ".section")
            .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.detail.dailyHistory")
    }
    private func providerTokenCard(_ provider: AIProvider) -> some View {
        let records = model.filteredRecords(provider: provider, period: model.selectedPeriod)
        let total = records.reduce(Int64(0)) { $0 + $1.tokens.total }
        return WBCard(title: "本机 Token", symbol: "chart.bar.xaxis", spacing: 0) {
            tokenValue(total)
            Spacer(minLength: 10)
            Text(model.selectedPeriod.title + " · 含缓存读取").aiText(11, color: palette.muted)
        }
    }
    private func coverageCard(_ provider: AIProvider) -> some View {
        let item = model.coverage[provider]
        let retained = model.records.filter { $0.provider == provider }
        return WBCard(title: "记录覆盖", symbol: "externaldrive.badge.checkmark", spacing: 0) {
            AIFactRow(title: "当前扫描", value: item.map { !$0.enabled ? "已断开" : $0.sourceAvailable ? "来源可读取" : "来源不可用" } ?? "尚未扫描")
            AIFactRow(title: "读取文件", value: item.map { "\($0.scannedFiles) 个 · 跳过 \($0.skippedFiles) 个" } ?? "—")
            AIFactRow(title: "本次识别", value: item.map { "\($0.parsedRecords) 条计量记录" } ?? "—")
            AIFactRow(title: "保留历史", value: "\(retained.count) 条 · 最长 31 天", last: true)
            if let first = retained.map(\.timestamp).min(), let last = retained.map(\.timestamp).max() {
                Text(aiFullDateTime(first, timeZone: timeZone) + " 至 " + aiFullDateTime(last, timeZone: timeZone)).aiText(11, color: palette.muted).padding(.top, 12)
            }
            if model.tokenHistoryCapacityLimited { AINotice(text: "历史达到容量上限，较早记录已移出；统计仅覆盖当前保留范围。", warning: true).padding(.top, 10) }
            if let message = model.tokenHistoryMessage { AINotice(text: message, warning: true).padding(.top, 10) }
        }
    }
    private var sources: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: "AI 数据来源", subtitle: "只读取用量元数据，不读取密钥或对话正文", back: pageBack) {
                HStack(spacing: 8) {
                    Button { sourcesMenuOpen.toggle() } label: { Label("更多", systemImage: "ellipsis") }.buttonStyle(WBButtonStyle())
                        .workbenchPopover(isPresented: $sourcesMenuOpen, width: 230, alignment: .trailing) { sourcesMenu }
                        .accessibilityIdentifier("fc.ai.sources.more")
                    Button { model.present(.manual) } label: { Label("添加记录", systemImage: "plus") }.buttonStyle(WBButtonStyle()).accessibilityIdentifier("fc.ai.manual")
                }
            }
            storageProtection
            AIWeightedColumns(ratio: 1, gap: 12) { sourceCard(.codex); sourceCard(.claude) }
            // Supporting copy sits on the note backing, never on the wallpaper (现行规范 3.4).
            WBPageNote {
                HStack(alignment: .top, spacing: 12) {
                    Text("断开只停止继续读取，已记录的 Token 历史会保留。不会读取认证密钥，也不保存提示词或对话正文。")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("来源与隐私说明") { model.present(.help) }.buttonStyle(WBQuietButtonStyle())
                }
            }.padding(.top, 12).accessibilityIdentifier("fc.ai.sources.note")
        }
    }
    /// The JSON actions live in the header's "更多" popover (现行规范 9.3, U3).
    private var sourcesMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            sourcesMenuItem("导入单次额度 JSON") { model.importQuota() }
            sourcesMenuItem("导出 JSON 模板") { model.exportTemplate() }
            sourcesMenuItem("连接 Codex 额度 JSON") { model.chooseQuotaFile(for: .codex) }
            if model.configuration(for: .codex).quotaPath != nil {
                sourcesMenuItem("移除 Codex 额度 JSON 连接") { model.removeQuotaFile(for: .codex) }
            }
        }.padding(6)
    }
    private func sourcesMenuItem(_ title: String, action: @escaping () -> Void) -> some View {
        Button { sourcesMenuOpen = false; action() } label: {
            Text(title).font(.system(size: 12)).foregroundStyle(palette.text).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
        }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 7, drawsSelection: false, showsBorder: false))
    }
    private func sourceCard(_ provider: AIProvider) -> some View {
        let config = model.configuration(for: provider)
        let value = summary(provider)
        let savedReading = config.manualSnapshot.map { $0.source.title + " · " + aiShortDateTime($0.observedAt, timeZone: timeZone) }
        let sourceDetail = config.enabled ? (model.diagnostics[provider] ?? "尚无采样，等待首次读取") + (savedReading.map { "；另有" + $0 } ?? "") :
            (savedReading.map { $0 + "；" } ?? "") + "自动读取已关闭，不扫描目录或额度文件；历史保留"
        // One switch says whether the source is read; turning it off still asks
        // first, as the former "断开" action did (现行规范 9.3, G1).
        let automatic = Binding(get: { config.enabled }, set: { enabled in
            if enabled { model.setEnabled(true, provider: provider) } else { model.present(.disconnect(provider)) }
        })
        return WBCard(spacing: 0) {
            HStack(spacing: 7) {
                AIProviderLogo(provider: provider, size: 16)
                Text(provider.title).aiText(13, weight: .medium, color: palette.text)
                Spacer()
            }.frame(height: 22).padding(.bottom, 10)
            WBSettingRow(title: "自动读取", subtitle: provider == .codex ? "读取本机会话目录中的额度与 Token 元数据" : "读取官方客户端额度与本机会话 Token；Token 不推断订阅额度", showsDivider: false) {
                Toggle("自动读取 " + provider.title, isOn: automatic).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(palette.accent).clickableCursor()
                    .accessibilityIdentifier("fc.ai.disconnect." + provider.rawValue)
            }
            if provider == .codex {
                WBSettingRow(title: "来源状态", subtitle: sourceDetail) {
                    Button("重新读取") { model.refresh() }.buttonStyle(WBButtonStyle(compact: true)).disabled(model.isRefreshing)
                }
                WBSettingRow(title: "目录范围", subtitle: config.sessionsPath, subtitleTruncation: .middle) {
                    Button("更改目录") { model.chooseSessionsDirectory(for: provider) }.buttonStyle(WBButtonStyle(compact: true))
                }
            } else {
                WBSettingRow(title: "额度快照", subtitle: value.snapshot?.source.title ?? "等待 Claude 官方额度读数") {
                    WBStatusPill(title: value.state == .ready ? "有效" + (value.updatedAt.map { " · " + aiClock($0, timeZone: timeZone) } ?? "") : value.state.title, good: value.state == .ready)
                }
                WBSettingRow(title: "连接方式", subtitle: "通过官方客户端查询会员额度") {
                    Button("连接设置") { model.present(.claudeConnect) }.buttonStyle(WBButtonStyle(compact: true))
                }
            }
        }
    }
    private var history: some View {
        let records = model.filteredRecords(provider: model.selectedProvider, period: model.selectedPeriod, includeDisconnected: true).sorted { $0.timestamp > $1.timestamp }
        return VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: "Token 活动记录", subtitle: "仅显示用量元数据；已断开来源的历史仍保留", back: pageBack) { filters }
            WBCard(spacing: 0) {
                AICardTitle(title: "最近活动", symbol: "clock.arrow.circlepath", trailing: "\(records.count) 条记录")
                tokenSourceSummary(records).padding(.bottom, 12)
                AITokenTable(records: records, model: model, compact: contentWidth < 800, scrollHeight: expanded ? 525 : 405)
            }
            if model.tokenHistoryCapacityLimited { WBPageNote(symbol: "exclamationmark.triangle") { Text("历史容量最多 20,000 条，最长保留 31 天。较早记录已移出，当前列表不代表完整账户历史。").fixedSize(horizontal: false, vertical: true) }.padding(.top, 12) }
            monthlyTokenHistory.padding(.top, 12)
            privacyFootnote.padding(.top, 12)
        }
    }
    private func tokenSourceSummary(_ records: [AITokenRecord]) -> some View {
        let totals = AIProvider.allCases.map { provider in
            (provider: provider, tokens: records.filter { $0.provider == provider }.reduce(Int64(0)) { $0 + $1.tokens.total })
        }
        let total = totals.reduce(Int64(0)) { $0 + $1.tokens }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("合计 " + aiCount(total) + " Token").aiText(13, weight: .medium, color: palette.text).monospacedDigit()
                Spacer(minLength: 8)
                ForEach(totals, id: \.provider) { source in
                    let share = total > 0 ? Double(source.tokens) / Double(total) : 0
                    Text(source.provider.title + " " + (total > 0 ? share.formatted(.percent.precision(.fractionLength(0))) : "暂无记录"))
                        .aiText(11, color: palette.secondary).monospacedDigit()
                }
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(totals, id: \.provider) { source in
                        (source.provider == .codex ? palette.accent : palette.cool)
                            .frame(width: total > 0 ? geometry.size.width * Double(source.tokens) / Double(total) : 0)
                    }
                    if total == 0 { palette.soft }
                }.clipShape(Capsule())
            }.frame(height: 5)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("fc.ai.history.source-summary")
    }
    private var monthlyTokenHistory: some View {
        let summaries = model.monthlyTokenHistory.filter { model.selectedProvider == nil || $0.provider == model.selectedProvider }
        return WBCard(spacing: 0) {
            AICardTitle(title: "月度用量汇总", symbol: "calendar", trailing: "最近 120 个月")
            Text("明细保留 31 天，到期后只保留每月 Token 汇总；按 UTC 月份归档，仅包含本机实际采集到的记录。")
                .aiText(11, color: palette.muted).padding(.bottom, 12)
            if summaries.isEmpty {
                Text("暂无月度记录").aiText(12, color: palette.muted).padding(.vertical, 12)
            } else {
                WorkbenchScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(summaries.reversed())) { summary in
                            HStack(spacing: 12) {
                                Text(summary.title).aiText(12, color: palette.text)
                                Text(summary.provider.title).aiText(11, color: palette.muted)
                                Spacer()
                                Text(aiCount(summary.tokens.total) + " Token").aiText(13, weight: .medium, color: palette.text).monospacedDigit()
                            }.frame(height: 36)
                        }
                    }
                }.frame(maxHeight: 240)
            }
            if model.tokenHistoryCapacityLimited {
                Text("部分来源或明细曾达到容量上限，月度汇总也可能不完整。")
                    .aiText(11, color: palette.muted).padding(.top, 8)
            }
        }.accessibilityIdentifier("fc.ai.history.monthly")
    }
    private var prices: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: "模型单价", subtitle: "API 等价估算不代表订阅账单或实际付费", back: pageBack) {
                Button("保存单价") { model.savePriceDraft() }.buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("fc.ai.price.save")
            }
            WBCard(title: model.priceDraft.model.isEmpty ? "API 等价估算单价" : model.priceDraft.model, symbol: "dollarsign.circle", spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    AIFieldLabel("来源") {
                        WBSelect("模型价格来源", selection: Binding(get: { model.priceDraft.provider }, set: { model.requestPriceSelection(provider: $0, model: model.knownModels(for: $0).first ?? "") }), options: AIProvider.allCases.map { (value: $0, title: $0.title) })
                    }.frame(width: 160)
                    AIFieldLabel("模型标识") {
                        TextField("填写日志中的完整模型标识", text: $model.priceDraft.model).textFieldStyle(AIFieldStyle()).accessibilityIdentifier("fc.ai.price.model")
                    }
                }.frame(maxWidth: 680, alignment: .leading)
                if !model.knownModels(for: model.priceDraft.provider).isEmpty {
                    AIFieldLabel("已识别或已配置的模型") {
                        WBSelect("选择模型", selection: Binding(get: { model.priceDraft.model }, set: { model.requestPriceSelection(provider: model.priceDraft.provider, model: $0) }), options: model.knownModels(for: model.priceDraft.provider).map { (value: $0, title: $0) })
                    }.frame(maxWidth: 680, alignment: .leading)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    priceField("输入（不含缓存）", value: $model.priceDraft.input, id: "input")
                    priceField("输出", value: $model.priceDraft.output, id: "output")
                    priceField("缓存读取", value: $model.priceDraft.cacheRead, id: "read")
                    priceField("缓存写入", value: $model.priceDraft.cacheWrite, id: "write")
                }.frame(maxWidth: 680, alignment: .leading)
                AINotice(text: "单价由你填写。四类计量互不重叠；确认免费时可填写 0。未配置的模型不参与成本估算，估算不是实际账单。")
                if let message = model.priceMessage { Text(message).aiText(11, color: palette.secondary).accessibilityIdentifier("fc.ai.price.status") }
            }
            if !model.prices.isEmpty {
                WBCard(title: "已保存单价", symbol: "list.bullet.rectangle", spacing: 0) {
                    ForEach(model.prices.sorted { $0.id < $1.id }) { price in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(price.provider.title + " · " + price.model).aiText(12, color: palette.text)
                                Text("输入 \(price.inputPerMillion.formatted()) · 输出 \(price.outputPerMillion.formatted()) · 缓存读 \(price.cacheReadPerMillion.formatted()) / 写 \(price.cacheWritePerMillion.formatted()) USD / M").aiText(11, color: palette.muted)
                            }
                            Spacer()
                            Button("编辑") { model.requestPriceSelection(provider: price.provider, model: price.model) }.buttonStyle(WBButtonStyle(compact: true))
                            Button { model.present(.removePrice(price.id)) } label: { Image(systemName: "trash") }.buttonStyle(WBIconButtonStyle(size: 28)).help("删除此模型单价")
                        }.frame(minHeight: 52).overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
                    }
                }.padding(.top, 12)
            }
        }
    }
    private func priceField(_ title: String, value: Binding<String>, id: String) -> some View {
        AIFieldLabel(title) { HStack(spacing: 8) { TextField("USD / 百万 Token", text: value).textFieldStyle(AIFieldStyle()).accessibilityIdentifier("fc.ai.price." + id) } }
    }
}

private struct AIWeightedColumns: Layout {
    var ratio: CGFloat = 1
    var gap: CGFloat = 12
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 864
        let widths = columnWidths(width)
        let heights = subviews.enumerated().map { index, view in view.sizeThatFits(.init(width: widths[min(index, 1)], height: nil)).height }
        return .init(width: width, height: heights.max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(bounds.width)
        for (index, view) in subviews.enumerated() {
            view.place(at: .init(x: bounds.minX + (index == 0 ? 0 : widths[0] + gap), y: bounds.minY), anchor: .topLeading, proposal: .init(width: widths[min(index, 1)], height: bounds.height))
        }
    }
    private func columnWidths(_ width: CGFloat) -> [CGFloat] {
        let available = max(0, width - gap)
        let left = ratio == 1 ? available / 2 : min(available - min(235, available / 2), available * ratio / (1 + ratio))
        return [left, available - left]
    }
}
@MainActor private enum AIUsageArtwork {
    static let images: [AIProvider: NSImage] = Dictionary(uniqueKeysWithValues: AIProvider.allCases.compactMap { provider in
        let name = provider == .codex ? "chatgpt" : "claude"
        let locations = [Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Workbench"), Bundle.main.resourceURL?.appendingPathComponent("Workbench/" + name + ".png")]
        guard let image = locations.compactMap({ $0 }).compactMap({ NSImage(contentsOf: $0) }).first else { return nil }
        return (provider, image)
    })
}
struct AIProviderLogo: View {
    let provider: AIProvider
    var size: CGFloat = 34
    @Environment(\.workbenchPalette) private var palette
    private var image: NSImage? { AIUsageArtwork.images[provider] }
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: provider == .codex ? "circle.hexagongrid" : "sparkles").font(.system(size: size * 22 / 34)).foregroundStyle(palette.accent) } }
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Aligned daily bars keep the two independent units explicit. Quota snapshots
/// never become daily consumption; token counts come only from the local ledger.
/// One chart for a provider's last 31 days: each quota window is a line of its
/// last observation per day, and local Token use is a bar on the same days,
/// with one date axis and one caption (现行规范 9.4, D6). A missing day breaks
/// the line; nothing is added, interpolated or converted into daily usage.
struct AIDailyQuotaChart: View {
    let series: [AIQuotaDailyWindowSeries]
    let days: [AIQuotaDailyCell]
    let tokens: [Date: AITokenCounts]
    let calendar: Calendar
    let identifier: String
    @Environment(\.workbenchPalette) private var palette
    @State private var hoveredDate: Date?
    @State private var selectedDate: Date?
    private let quotaHeight: CGFloat = 88
    private let tokenHeight: CGFloat = 56
    private let gap: CGFloat = 5
    private var visibleDays: [AIQuotaDailyCell] { days.filter(\.isInRange) }
    private var tokenMaximum: Double { max(1, Double(tokens.values.map(\.total).max() ?? 0)) }
    private var activeDate: Date? { hoveredDate ?? selectedDate }
    private var focusedDay: AIQuotaDailyCell? {
        visibleDays.first { $0.date == activeDate }
            ?? visibleDays.last { day in series.contains { reading($0, on: day.date) != nil } || tokens[day.date] != nil }
            ?? visibleDays.last
    }
    private func color(_ index: Int) -> Color { index == 0 ? palette.accent : palette.cool }
    private func reading(_ item: AIQuotaDailyWindowSeries, on date: Date) -> AIQuotaDailyReading? {
        item.days.first { $0.date == date }?.reading
    }
    private func stamp(_ date: Date) -> String { String(Int(date.timeIntervalSince1970)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                if series.isEmpty {
                    Text("额度占用 · 尚无读数").aiText(13, weight: .medium, color: palette.text)
                } else {
                    ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 6) {
                            Capsule().fill(color(index)).frame(width: 12, height: 2)
                            Text(item.title + " · 当天最后观测").aiText(11, color: palette.secondary)
                        }
                    }
                }
                Spacer()
                Text("0–100%").aiText(11, color: palette.muted).monospacedDigit()
            }
            HStack(alignment: .top, spacing: 8) {
                axis(top: "100%", bottom: "0%", height: quotaHeight)
                GeometryReader { plot in
                    let step = (plot.size.width + gap) / CGFloat(max(1, visibleDays.count))
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(palette.line).frame(width: plot.size.width, height: 1).offset(y: quotaHeight - 1)
                        ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                            line(item, step: step).stroke(color(index), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                            ForEach(Array(visibleDays.enumerated()), id: \.element.id) { offset, day in
                                if let value = reading(item, on: day.date) {
                                    Circle().fill(palette.usageColor(forPercent: value.window.usedPercent))
                                        .overlay(Circle().strokeBorder(color(index), lineWidth: 1))
                                        .frame(width: activeDate == day.date ? 7 : 5, height: activeDate == day.date ? 7 : 5)
                                        .frame(width: 7, height: 7)
                                        .aiQuotaMeasuredRegion("fc.ai.history." + identifier + "." + String(item.durationMinutes) + ".point." + stamp(day.date))
                                        .position(x: center(offset, step: step), y: y(value.window.usedPercent))
                                }
                            }
                        }
                        HStack(spacing: gap) {
                            ForEach(visibleDays) { day in
                                Button { selectedDate = day.date } label: { Color.clear.contentShape(Rectangle()) }
                                    .buttonStyle(ClickablePlainButtonStyle())
                                    .aiQuotaMeasuredRegion("fc.ai.history." + identifier + ".quota.cell." + stamp(day.date))
                                    .accessibilityLabel(description(day))
                                    .accessibilityIdentifier("fc.ai.history." + identifier + ".quota.day." + stamp(day.date))
                            }
                        }.frame(width: plot.size.width, height: quotaHeight)
                    }.frame(width: plot.size.width, height: quotaHeight, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onContinuousHover { hover($0, width: plot.size.width) }
                        .aiQuotaMeasuredRegion("fc.ai.history." + identifier + ".quota.grid")
                }.frame(height: quotaHeight)
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(palette.cool).frame(width: 8, height: 8)
                Text("Token · 本机记录").aiText(11, color: palette.secondary)
                Spacer()
                Text(tokens.isEmpty ? "暂无 Token 记录" : "已记录 " + aiCount(tokens.values.reduce(Int64(0)) { $0 + $1.total }) + " Token / 31 天")
                    .aiText(11, color: palette.muted).monospacedDigit()
            }.padding(.top, 6)
            HStack(alignment: .top, spacing: 8) {
                axis(top: aiCount(Int64(tokenMaximum)), bottom: "0", height: tokenHeight)
                GeometryReader { plot in
                    VStack(spacing: 6) {
                        HStack(alignment: .bottom, spacing: gap) {
                            ForEach(visibleDays) { day in
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    if let count = tokens[day.date] {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(palette.cool.opacity(activeDate == day.date ? 1 : 0.72))
                                            .frame(height: max(2, tokenHeight * Double(count.total) / tokenMaximum))
                                            .aiQuotaMeasuredRegion("fc.ai.history." + identifier + ".tokens.bar." + stamp(day.date))
                                    } else {
                                        Text("—").font(.system(size: 11)).foregroundStyle(palette.muted).frame(height: 14)
                                    }
                                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }.frame(height: tokenHeight).contentShape(Rectangle())
                            .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1).allowsHitTesting(false) }
                            .onContinuousHover { hover($0, width: plot.size.width) }
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(visibleDays.enumerated()), id: \.element.id) { index, day in
                                if index == 0 || index == 7 || index == 14 || index == 21 || index == visibleDays.count - 1 {
                                    Text(WorkbenchDateText.axis(day.date, calendar: calendar))
                                        .fixedSize()
                                        .position(x: min(max(22, (CGFloat(index) + 0.5) * (plot.size.width + gap) / CGFloat(visibleDays.count) - gap / 2), plot.size.width - 22), y: 6)
                                }
                            }
                        }.font(.system(size: 11)).foregroundStyle(palette.muted).frame(height: 14)
                    }
                }.frame(height: tokenHeight + 20)
            }
            caption
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.history." + identifier)
    }
    private func axis(top: String, bottom: String, height: CGFloat) -> some View {
        VStack(alignment: .trailing) {
            Text(top)
            Spacer(minLength: 0)
            Text(bottom)
        }.font(.system(size: 11)).foregroundStyle(palette.muted).monospacedDigit().frame(width: 40, height: height)
    }
    private func center(_ index: Int, step: CGFloat) -> CGFloat { CGFloat(index) * step + (step - gap) / 2 }
    private func y(_ percent: Double) -> CGFloat { quotaHeight * (1 - CGFloat(min(100, max(0, percent))) / 100) }
    /// Consecutive observed days are joined; a missing day starts a new segment.
    private func line(_ item: AIQuotaDailyWindowSeries, step: CGFloat) -> Path {
        var path = Path(); var drawing = false
        for (offset, day) in visibleDays.enumerated() {
            guard let value = reading(item, on: day.date) else { drawing = false; continue }
            let point = CGPoint(x: center(offset, step: step), y: y(value.window.usedPercent))
            if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
        }
        return path
    }
    private func hover(_ phase: HoverPhase, width: CGFloat) {
        switch phase {
        case .active(let location):
            guard !visibleDays.isEmpty else { return }
            let step = (width + gap) / CGFloat(visibleDays.count)
            hoveredDate = visibleDays[min(visibleDays.count - 1, max(0, Int((location.x + gap / 2) / step)))].date
        case .ended: hoveredDate = nil
        }
    }
    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let day = focusedDay {
                HStack(spacing: 12) {
                    Text(([formatted(day.date, template: "Md")] + series.map { item in
                        item.title + " " + (reading(item, on: day.date).map { UsagePercentage.text($0.window.usedPercent) } ?? "—")
                    }).joined(separator: " · "))
                    Text(tokens[day.date].map { $0.total.formatted() + " Token" } ?? "Token 无记录")
                    Spacer(minLength: 0)
                }.foregroundStyle(palette.text).monospacedDigit()
                Text(series.lazy.compactMap { reading($0, on: day.date) }.first.map {
                    "最后观测 " + formatted($0.observedAt, template: "jm") + " · " + $0.source.title + " · 非当日消耗比例"
                } ?? (series.isEmpty ? "尚无额度读数；Token 仍按本机记录显示。" : "当天没有读取到额度，不能视为 0%。"))
                    .foregroundStyle(palette.muted).lineLimit(1)
            }
        }.font(.system(size: 11)).frame(height: 34, alignment: .topLeading)
    }
    private func formatted(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
    private func tokenDetail(_ day: AIQuotaDailyCell) -> String {
        guard let counts = tokens[day.date] else { return "当天没有采集到本机 Token 记录，不能推断账户未使用。" }
        return "输入 " + aiCount(counts.input) + " · 输出 " + aiCount(counts.output) + " · 缓存读取 " + aiCount(counts.cacheRead) + " · 缓存写入 " + aiCount(counts.cacheWrite)
    }
    private func description(_ day: AIQuotaDailyCell) -> String {
        let date = formatted(day.date, template: "yMMMMEEEEd")
        let quota = series.map { item -> String in
            guard let reading = reading(item, on: day.date) else { return item.title + "无额度读数；无读数不代表 0" }
            let reset = reading.window.resetsAt.map { "；该窗口重置时间 " + UsageResetTime.timestamp($0, timeZone: calendar.timeZone) } ?? "；来源未提供重置时间"
            return item.title + " " + UsagePercentage.text(reading.window.usedPercent) + "；当天最后观测 " + UsageResetTime.timestamp(reading.observedAt, timeZone: calendar.timeZone) + "；" + reading.source.title + reset
        }
        let token = tokens[day.date].map { "本机记录 " + String($0.total) + " Token；" + tokenDetail(day) } ?? "Token 无记录"
        return ([date] + quota + [token]).joined(separator: "，")
    }
}

private struct AIProviderQuotaCard: View {
    let summary: AIProviderSummary
    let minimumHeight: CGFloat
    let expanded: Bool
    var automaticReadingEnabled = true
    var showsAction = true
    var reading = false
    var enable: (() -> Void)? = nil
    /// The source's own connection settings, offered beside "开启读取" (9.3, U2).
    var connect: (() -> Void)? = nil
    @Environment(\.timeZone) private var timeZone
    var action: () -> Void
    @Environment(\.workbenchPalette) private var palette
    private var windows: [AIQuotaWindow] { summary.snapshot?.availableWindows ?? [] }
    private var rowGap: CGFloat { expanded ? 18 : 14 }
    /// Nothing under the name while the empty state already gives the reason (9.3, U2).
    private var sourceText: String? {
        if !automaticReadingEnabled { return summary.snapshot == nil ? nil : summary.sourceDescription + " · 自动读取已关闭" }
        return summary.state == .disconnected ? "来源已断开" : summary.sourceDescription
    }
    fileprivate var isReading: Bool { automaticReadingEnabled && summary.snapshot == nil && (reading || summary.detail == AIUsageModel.readingDetail) }
    /// One status, in words, at the top right (现行规范 9.3, U2).
    private var status: String? {
        if !automaticReadingEnabled { return "已关闭" }
        if isReading { return "读取中" }
        switch summary.state {
        case .error: return "读取失败"
        case .unavailable, .disconnected: return windows.isEmpty ? "不可用" : nil
        case .ready, .stale: return nil
        }
    }
    var body: some View {
        Group {
            if showsAction {
                Button(action: action) { cardContent }
                    .buttonStyle(ClickablePlainButtonStyle())
                    .help("查看 " + summary.title + " 用量详情")
                    .accessibilityLabel("查看 " + summary.title + " 用量详情")
                    .accessibilityIdentifier("fc.ai.provider." + summary.provider.rawValue)
            } else { cardContent }
        }
    }
    private var cardContent: some View {
        WBCard(spacing: 0) {
            HStack(spacing: 10) {
                AIProviderLogo(provider: summary.provider)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(summary.title).aiText(13, weight: .medium, color: palette.text)
                        if let plan = summary.effectiveAccountPlan {
                            WBStatusPill(title: plan.title)
                                .help(summary.accountPlanDescription)
                                .accessibilityIdentifier("fc.ai.plan." + summary.provider.rawValue)
                        }
                    }.frame(height: 20, alignment: .leading)
                    if let sourceText {
                        Text(sourceText).aiText(11, color: palette.muted).lineLimit(1).truncationMode(.middle).help(sourceText).frame(height: 16)
                    }
                }
                Spacer()
                if let status { WBStatusPill(title: status) }
            }.frame(height: 40)
                .aiQuotaMeasuredRegion("fc.ai.quota.header." + summary.provider.rawValue)
                .padding(.bottom, 14)
                .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.quota.header." + summary.provider.rawValue)
            quotaContent.frame(height: 128 + rowGap, alignment: .top)
            Spacer(minLength: 12)
            // Without windows the empty state above is the only explanation.
            if !windows.isEmpty {
            HStack(spacing: 5) {
                Circle().fill(summary.state == .ready ? palette.accent : summary.state == .error ? palette.warning : palette.muted).frame(width: 5, height: 5)
                Text(summary.state.title)
                if let updated = summary.updatedAt { UsageObservationAgeLabel(date: updated, prefix: "· ", timeZone: timeZone) }
                Spacer(minLength: 0)
                Text(summary.snapshot?.source == .manual ? "手动记录" : summary.snapshot?.source == .imported ? "导入读数" : "本机来源")
            }.font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).frame(height: 16)
                .aiQuotaMeasuredRegion("fc.ai.quota.footer." + summary.provider.rawValue)
                .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.quota.footer." + summary.provider.rawValue)
            Text(summary.state == .ready ? summary.accountPlanDescription : summary.detail)
                .aiText(11, color: summary.state == .error ? palette.warning : palette.muted)
                .lineLimit(1).truncationMode(.tail).help(summary.state == .ready ? summary.accountPlanDescription : summary.detail)
                .frame(height: 16).padding(.top, 6)
            }
        }.frame(minHeight: minimumHeight, alignment: .top)
            .contentShape(RoundedRectangle(cornerRadius: 15))
    }
    @ViewBuilder private var quotaContent: some View {
        if windows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: isReading ? "arrow.triangle.2.circlepath" : "info.circle").font(.system(size: 14)).foregroundStyle(palette.muted)
                    Text(emptyTitle).aiText(13, weight: .medium, color: palette.text)
                }
                Text(emptyDetail).aiText(11, color: palette.secondary).fixedSize(horizontal: false, vertical: true)
                if !automaticReadingEnabled, let enable, !showsAction {
                    HStack(spacing: 12) {
                        Button("开启读取", action: enable).buttonStyle(WBButtonStyle(compact: true))
                            .accessibilityIdentifier("fc.ai.quota.enable." + summary.provider.rawValue)
                        if let connect { Button("连接设置", action: connect).buttonStyle(WBQuietButtonStyle()) }
                        else { Button("管理来源", action: action).buttonStyle(WBQuietButtonStyle()) }
                    }.padding(.top, 2)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityIdentifier("fc.ai.quota.empty." + summary.provider.rawValue)
        } else {
            VStack(alignment: .leading, spacing: rowGap) {
                ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                    let slot = window.durationMinutes == 10_080 ? 1 : index
                    AIQuotaRow(window: window, identifier: "fc.ai.quota." + summary.provider.rawValue + "." + String(slot))
                }
                if windows.count == 1 {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(summary.hasNoFiveHourLimit ? "Pro 不设 5 小时限制" : "按来源提供的窗口展示", systemImage: summary.hasNoFiveHourLimit ? "checkmark.shield" : "info.circle").font(.system(size: 12))
                        Text(summary.hasNoFiveHourLimit ? "每周额度仍以实际读数为准。" : "其他周期暂未提供；缺失值不代表已用 0%。")
                            .font(.system(size: 11)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }.foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .leading).frame(height: 64, alignment: .top)
                        .aiQuotaMeasuredRegion("fc.ai.quota." + summary.provider.rawValue + ".availability")
                }
            }
        }
    }
}
extension AIProviderQuotaCard {
    fileprivate var emptyTitle: String {
        if !automaticReadingEnabled { return "自动读取已关闭" }
        if isReading { return "读取中" }
        return summary.state == .error ? "读取失败" : "暂无可用额度窗口"
    }
    fileprivate var emptyDetail: String {
        if !automaticReadingEnabled { return "开启后显示\(summary.provider == .codex ? "本机会话" : "官方客户端")提供的额度窗口；缺失的窗口不会记作 0%。" }
        if isReading { return summary.detail }
        return summary.state == .error ? summary.detail : "连接来源后显示实际提供的周期；不会把缺失窗口记作 0%。"
    }
}
private struct AIQuotaRow: View {
    var window: AIQuotaWindow
    var identifier: String
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.timeZone) private var timeZone
    private var color: Color { palette.usageColor(forPercent: window.usedPercent) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title).aiText(12, color: palette.secondary).lineLimit(1)
                Spacer()
                Text(UsagePercentage.text(window.usedPercent)).font(.system(size: 24)).monospacedDigit()
                Text("已用").aiText(11, color: palette.muted)
            }.frame(height: 26)
            WBProgress(value: window.usedPercent / 100, color: color, height: 5)
                .aiQuotaMeasuredRegion(identifier + ".progress")
                .accessibilityElement(children: .ignore).accessibilityLabel(window.title + "已用 " + UsagePercentage.text(window.usedPercent))
                .accessibilityIdentifier(identifier + ".progress")
            HStack(spacing: 6) {
                UsageResetLabel(reset: .init(window: window), timeZone: timeZone).lineLimit(1)
                Spacer(minLength: 0)
                Text("剩余 " + UsagePercentage.text(window.remainingPercent)).foregroundStyle(color).lineLimit(1)
            }.font(.system(size: 11)).foregroundStyle(palette.muted).frame(height: 16)
        }.frame(height: 64).aiQuotaMeasuredRegion(identifier)
            .accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }
}
private struct AIActionCard<Content: View>: View {
    let actionTitle: String
    let action: () -> Void
    let content: Content
    @Environment(\.workbenchPalette) private var palette
    @FocusState private var actionFocused: Bool
    @State private var keyboardFocused = false
    init(actionTitle: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.actionTitle = actionTitle
        self.action = action
        self.content = content()
    }
    var body: some View {
        WBCard(spacing: 0) { content }
            .contentShape(RoundedRectangle(cornerRadius: 15))
            .onTapGesture(perform: action)
            .focusable()
            .focusEffectDisabled()
            .focused($actionFocused)
            .onKeyPress(.return) {
                guard actionFocused else { return .ignored }
                action(); return .handled
            }
            .onKeyPress(.space) {
                guard actionFocused else { return .ignored }
                action(); return .handled
            }
            // Only keyboard focus draws the 2-point accent ring; a click does not (现行规范 8).
            .onChange(of: actionFocused) { _, focused in keyboardFocused = focused && NSApp.currentEvent?.type == .keyDown }
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(keyboardFocused ? palette.accent : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .help(actionTitle)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(actionTitle)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
private struct AICardTitle: View {
    var title: String
    var symbol: String
    var trailing: String? = nil
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(palette.accent)
            Text(title).aiText(13, weight: .medium, color: palette.text)
            Spacer()
            if let trailing { Text(trailing).aiText(11, color: palette.muted) }
        }.frame(height: 22).padding(.bottom, 10)
    }
}
private struct AITokenTable: View {
    var records: [AITokenRecord]
    @ObservedObject var model: AIUsageModel
    var compact: Bool
    var scrollHeight: CGFloat?
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.timeZone) private var timeZone
    var body: some View {
        VStack(spacing: 0) {
            rowHeader
            if let scrollHeight {
                WorkbenchScrollView { LazyVStack(spacing: 0) { rows }.frame(maxWidth: .infinity) }.frame(height: scrollHeight)
            } else { rows }
        }
    }
    private var rowHeader: some View {
        HStack(spacing: compact ? 6 : 12) {
            Text("时间").frame(width: compact ? 72 : 92, alignment: .leading)
            Text("来源 / 模型").frame(maxWidth: .infinity, alignment: .leading)
            Text("输入").frame(width: compact ? 52 : 74, alignment: .trailing)
            Text("输出").frame(width: compact ? 52 : 74, alignment: .trailing)
        }.aiText(11, color: palette.muted).frame(height: 32).overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
    @ViewBuilder private var rows: some View {
        if records.isEmpty {
            Text("此范围内尚无可识别的本机计量记录").aiText(11, color: palette.muted).frame(maxWidth: .infinity, minHeight: 80)
        } else {
            ForEach(records, id: \.selfIdentity) { record in
                HStack(spacing: compact ? 6 : 12) {
                    Text(aiShortDateTime(record.timestamp, timeZone: timeZone)).foregroundStyle(palette.muted).lineLimit(1).frame(width: compact ? 72 : 92, alignment: .leading)
                    Text(record.provider.title + " · " + record.model).foregroundStyle(palette.secondary).lineLimit(1).help(record.provider.title + " · " + record.model).frame(maxWidth: .infinity, alignment: .leading)
                    Text(aiCount(record.tokens.input)).monospacedDigit().frame(width: compact ? 52 : 74, alignment: .trailing)
                    Text(aiCount(record.tokens.output)).foregroundStyle(palette.muted).monospacedDigit().frame(width: compact ? 52 : 74, alignment: .trailing)
                }.font(.system(size: 11)).frame(height: 36).overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
            }
        }
    }
}
private extension AITokenRecord { var selfIdentity: String { provider.rawValue + ":" + id } }
private struct AIFactRow: View {
    var title: String
    var value: String
    var color: Color? = nil
    var last = false
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(palette.muted)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(color ?? palette.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 11)).frame(minHeight: 15.95).padding(.bottom, last ? 0 : 12)
    }
}
private struct AISourceRow<Action: View>: View {
    var title: String
    var detail: String
    var last = false
    var first = false
    @ViewBuilder var action: () -> Action
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).aiText(12, color: palette.secondary)
                Text(detail).aiText(11, color: palette.muted).lineLimit(2).help(detail).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            action()
        }.padding(.top, first ? 0 : 13).padding(.bottom, last ? 0 : 13).overlay(alignment: .bottom) { if !last { Rectangle().fill(palette.line).frame(height: 1) } }
    }
}
private struct AINotice: View {
    var text: String
    var warning = false
    /// Outside a card the notice sits on the page note backing (现行规范 3.4).
    var onBackdrop = false
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 16)).frame(width: 16, height: 16).padding(.top, 1).accessibilityHidden(true)
            Text(text).font(.system(size: 11)).lineSpacing(4.6).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 17.6, alignment: .leading).accessibilityIdentifier("fc.ai.notice.text")
        }.foregroundStyle(warning ? palette.warning : palette.secondary)
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background {
                if onBackdrop { WorkbenchMaterialSurface(radius: 8) }
                else {
                    RoundedRectangle(cornerRadius: 8).fill(warning ? palette.surface : palette.soft)
                        .overlay { if warning { RoundedRectangle(cornerRadius: 8).fill(palette.warning.opacity(0.10)) } }
                }
            }
            .accessibilityElement(children: .contain)
    }
}
private struct AIFieldLabel<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.workbenchPalette) private var palette
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).aiText(12, color: palette.secondary); content() }.frame(maxWidth: .infinity, alignment: .leading) }
}
private struct AIFieldStyle: TextFieldStyle {
    @Environment(\.workbenchPalette) private var palette
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).foregroundStyle(palette.text).modifier(WBFieldSurface())
    }
}
private extension View {
    func aiText(_ size: CGFloat, weight: Font.Weight = .regular, color: Color) -> some View {
        font(.system(size: size, weight: weight)).foregroundStyle(color).lineSpacing(size * 0.25).fixedSize(horizontal: false, vertical: true).frame(minHeight: size * 1.45, alignment: .leading)
    }
}
/// 「11月7日 10:50」 for compact rows; lists with room use the full date (现行规范 5.3).
private func aiShortDateTime(_ date: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    return WorkbenchDateText.monthDay(date, calendar: calendar) + " " + aiClock(date, timeZone: timeZone)
}
private func aiFullDateTime(_ date: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    return WorkbenchDateText.fullWithTime(date, calendar: calendar)
}
private func aiClock(_ date: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
}
private func aiCount(_ value: Int64) -> String {
    let number = Double(value)
    if number >= 1_000_000 { return (number / 1_000_000).formatted(.number.precision(.fractionLength(0...2))) + "M" }
    if number >= 1_000 { return (number / 1_000).formatted(.number.precision(.fractionLength(0...1))) + "K" }
    return value.formatted()
}

private struct AIUsageDialogContent: View {
    @ObservedObject var model: AIUsageModel
    @Environment(\.workbenchModals) private var modals
    @State private var manualTimesExpanded = false
    #if DEBUG
    @Environment(\.aiManualDialogInspection) private var inspection
    @State private var inspectionOwner = UUID()
    #endif
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    private var inputCalendar: Calendar {
        var value = calendar
        value.timeZone = timeZone
        return value
    }
    var body: some View {
        Group {
            switch model.dialog {
            case .alert: alertDialog
            case .manual: manualDialog
            case .claudeConnect: claudeDialog
            case .connectionPreview: previewDialog
            case .disconnect(let provider): disconnectDialog(provider)
            case .removePrice(let id): removePriceDialog(id)
            case .help: helpDialog
            case nil: EmptyView()
            }
        }.foregroundStyle(palette.text)
    }
    private var alertDialog: some View {
        AIDialogShell(title: "额度提醒", close: model.requestDismissDialog) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("额度接近上限时提醒").aiText(12, color: palette.text)
                        Text("仅对新鲜、有效的来源读数触发").aiText(11, color: palette.muted)
                    }
                    Spacer()
                    Toggle("额度接近上限时提醒", isOn: $model.alertEnabled).labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.mini).accessibilityIdentifier("fc.ai.alert.enabled")
                }
                HStack(spacing: 14) {
                    AIFieldLabel("留意 · 已用达到（%）") { TextField("75", text: $model.alertWarningText).textFieldStyle(AIFieldStyle()).accessibilityIdentifier("fc.ai.alert.warning") }
                    AIFieldLabel("紧张 · 已用达到（%）") { TextField("90", text: $model.alertCriticalText).textFieldStyle(AIFieldStyle()).accessibilityIdentifier("fc.ai.alert.critical") }
                }
                AINotice(text: "用量颜色统一在 70% 转黄、90% 转红；通知按上方设置的比例触发。来源过期或缺失时不触发通知，不用 Token 推算额度。")
                if model.notificationPermission == .denied || model.notificationPermission == .unavailable {
                    HStack(alignment: .top, spacing: 12) {
                        Text(model.notificationPermission == .denied ? "系统通知未获允许，规则仍会保存。请允许 DeskDen 发送通知。" : "当前运行环境无法发送系统通知，规则可先保存在本机。").aiText(11, color: palette.warning)
                        if model.notificationPermission == .denied { Button("打开设置") { openNotificationSettings() }.buttonStyle(WBButtonStyle(compact: true)) }
                    }
                }
                errorText
            }
        } footer: {
            Button("取消") { model.requestDismissDialog() }.buttonStyle(WBButtonStyle()).disabled(model.dialogBusy)
            Button(model.dialogBusy ? "保存中…" : "保存提醒") { Task { await model.saveAlertDraft() } }.buttonStyle(WBButtonStyle(primary: true)).disabled(model.dialogBusy).accessibilityIdentifier("fc.ai.alert.save")
        }.accessibilityIdentifier("fc.modal.ai.alert")
    }
    private var manualDialog: some View {
        AIDialogShell(title: "手动记录额度", close: dismissManual) {
            VStack(alignment: .leading, spacing: 16) {
                AIFieldLabel("来源") { WBSelect("记录来源", selection: $model.manualDraft.provider, options: AIProvider.allCases.map { (value: $0, title: $0.title) }) }
                HStack(spacing: 14) {
                    AIFieldLabel("5 小时已用（%）") { TextField("未知请留空", text: $model.manualDraft.shortPercent).textFieldStyle(AIFieldStyle()).accessibilityIdentifier("fc.ai.manual.short") }
                    AIFieldLabel("每周已用（%）") { TextField("未知请留空", text: $model.manualDraft.weeklyPercent).textFieldStyle(AIFieldStyle()).accessibilityIdentifier("fc.ai.manual.weekly") }
                }
                AIFieldLabel("记录备注（可选）") { TextField("例如：从账户用量页面查看", text: $model.manualDraft.note).textFieldStyle(AIFieldStyle()).accessibilityIdentifier("fc.ai.manual.note") }
                DisclosureGroup("采集时间与重置时间", isExpanded: $manualTimesExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        dateTimeField("实际采集时间", selection: $model.manualDraft.observedAt)
                        Toggle("已知实际重置时间", isOn: $model.manualDraft.specifiesResetTimes).toggleStyle(.checkbox).clickableCursor()
                        if model.manualDraft.specifiesResetTimes {
                            dateTimeField("5 小时重置", selection: $model.manualDraft.shortReset)
                            dateTimeField("每周重置", selection: $model.manualDraft.weeklyReset)
                        }
                    }.font(.system(size: 11)).padding(.top, 10)
                }.font(.system(size: 11)).foregroundStyle(palette.secondary)
                AINotice(text: "手动记录始终标明来源，不会自动更新；未知窗口请留空。")
                errorText
            }
        } footer: {
            Button("取消", action: dismissManual).buttonStyle(WBButtonStyle())
            Button("保存记录") {
                guard WBEditableComboSurface.commitActive(in: modals?.hostWindow) else { return }
                model.saveManualDraft()
            }.buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("fc.ai.manual.save")
        }.accessibilityIdentifier("fc.modal.ai.manual")
        #if DEBUG
        .onAppear { inspection?.attach(owner: inspectionOwner, expanded: $manualTimesExpanded, knownReset: $model.manualDraft.specifiesResetTimes) }
        .onDisappear { inspection?.detach(owner: inspectionOwner) }
        #endif
    }
    private func dismissManual() { modals?.hostWindow?.makeFirstResponder(nil); model.requestDismissDialog() }
    private func dateTimeField(_ title: String, selection: Binding<Date>) -> some View {
        AIFieldLabel(title) {
            HStack(spacing: 12) {
                WBDateInput(title + " · 日期", selection: selection, components: .date, calendar: inputCalendar)
                    .frame(maxWidth: .infinity)
                WBDateInput(title + " · 时间", selection: selection, components: .time, calendar: inputCalendar)
                    .frame(width: 156)
            }
        }
    }
    private var claudeDialog: some View {
        AIDialogShell(title: "连接 Claude 额度", close: model.requestDismissDialog) {
            VStack(alignment: .leading, spacing: 0) {
                Text("通过本机 Claude Code 主动查询五小时和每周额度，无需发送对话，也不通过 Token 数推算。").aiText(12, color: palette.secondary).padding(.bottom, 4)
                AISourceRow(title: model.claudeUsesSeparateLogin ? "DeskDen 单独登录" : "本机 Claude Code",
                            detail: ClaudeConnectionPresentation.status(model.claudeLoginRemedy), last: true) {
                    Button(model.dialogBusy ? "正在连接…" : ClaudeConnectionPresentation.primaryTitle(model.claudeLoginRemedy)) {
                        connectClaude(ClaudeConnectionPresentation.primaryAction(model.claudeLoginRemedy))
                    }.buttonStyle(WBButtonStyle(primary: true, compact: true)).disabled(model.dialogBusy)
                        .accessibilityIdentifier("fc.ai.claude.enableSync")
                }
                if model.claudeLoginRemedy == .switchInTerminal { ClaudeTerminalSwitchNotice().padding(.top, 12) }
                DisclosureGroup("高级连接方式") {
                    if model.claudeUsesSeparateLogin {
                        AISourceRow(title: "改回本机登录", detail: "退出 DeskDen 单独保存的会员登录，改为读取本机 Claude Code") {
                            Button("改回") { connectClaude(.useLocalLogin) }.buttonStyle(WBButtonStyle(compact: true))
                                .accessibilityIdentifier("fc.ai.claude.use-local-login")
                        }
                    } else {
                        AISourceRow(title: "为 DeskDen 单独登录会员", detail: "终端需要保留 API 或其他登录时使用，不改变本机 Claude Code") {
                            Button("官方登录") { connectClaude(.signInSeparately) }.buttonStyle(WBButtonStyle(compact: true))
                                .accessibilityIdentifier("fc.ai.claude.member-login")
                        }
                    }
                    AISourceRow(title: "选择额度 JSON", detail: "读取已有额度文件") {
                        Button("选择文件") { model.chooseQuotaFile(for: .claude) }.buttonStyle(WBButtonStyle(compact: true)).accessibilityIdentifier("fc.ai.claude.json")
                    }
                    AISourceRow(title: "导出状态栏适配器", detail: "用于自定义状态栏配置") {
                        Button("导出") { model.exportClaudeAdapter() }.buttonStyle(WBButtonStyle(compact: true)).accessibilityIdentifier("fc.ai.claude.adapter")
                    }
                    AISourceRow(title: "Token 会话目录", detail: model.configuration(for: .claude).sessionsPath, last: true) {
                        Button("更改目录") { model.chooseSessionsDirectory(for: .claude) }.buttonStyle(WBButtonStyle(compact: true))
                            .accessibilityIdentifier("fc.ai.claude.sessions")
                    }
                    if model.configuration(for: .claude).quotaPath != nil {
                        HStack { Text("已配置额度文件").aiText(11, color: palette.muted); Spacer(); Button("移除连接") { model.removeQuotaFile(for: .claude) }.buttonStyle(WBQuietButtonStyle()) }.padding(.top, 12)
                    }
                }.font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 16).disabled(model.dialogBusy)
                // A failed connection reports one message as the error, not twice.
                if let message = model.claudeQuotaSyncMessage, message != model.errorMessage { AINotice(text: message).padding(.top, 12) }
                errorText.padding(.top, model.errorMessage == nil ? 0 : 12)
            }
        } footer: {
            if model.isConnectingClaudeSubscriptionAccount {
                Button("取消连接") { model.cancelClaudeSubscriptionAccountConnection() }
                    .buttonStyle(WBButtonStyle())
                    .accessibilityIdentifier("fc.ai.claude.cancel-member-login")
            }
            Button("完成") { model.requestDismissDialog() }
                .buttonStyle(WBButtonStyle()).disabled(model.dialogBusy)
        }.accessibilityIdentifier("fc.modal.ai.claude-connect")
    }
    private func connectClaude(_ action: ClaudeConnectionAction) {
        guard !model.dialogBusy else { return }
        model.dialogBusy = true
        Task { @MainActor in
            _ = await model.connectClaude(action)
            model.dialogBusy = false
        }
    }
    private var previewDialog: some View {
        AIDialogShell(title: model.connectionPreview.map { "连接 " + $0.provider.title + " 来源" } ?? "检查来源", close: model.requestDismissDialog) {
            VStack(alignment: .leading, spacing: 14) {
                if model.connectionPreviewLoading {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在检查可识别的计量字段…").aiText(12, color: palette.secondary) }.frame(maxWidth: .infinity, minHeight: 140)
                } else if let preview = model.connectionPreview {
                    AISourceRow(title: URL(fileURLWithPath: preview.path).lastPathComponent, detail: preview.path, last: true, first: true) {
                        WBStatusPill(title: !preview.canConnect ? "不可读取" : previewIsStale(preview) ? "可读取 · 已过期" : "可读取", good: preview.canConnect && !previewIsStale(preview))
                    }
                    VStack(spacing: 0) {
                        if preview.quotaFile {
                            AIFactRow(title: "有效读数", value: preview.windows.map { $0.title + " " + UsagePercentage.text($0.usedPercent) }.joined(separator: " · "))
                            AIFactRow(title: "采集时间", value: preview.observedAt.map { aiFullDateTime($0, timeZone: timeZone) } ?? "未提供")
                            AIFactRow(title: "读数来源", value: preview.quotaSource?.title ?? "尚无读数", last: true)
                        } else {
                            AIFactRow(title: "有效记录", value: "\(preview.files) 个文件 · \(preview.records) 条计量记录")
                            AIFactRow(title: "包括", value: "可识别的额度与 Token 元数据")
                            AIFactRow(title: "不包括", value: "密钥、提示词、会话正文", last: true)
                        }
                    }
                    if let message = preview.error { AINotice(text: message, warning: true) }
                    AINotice(text: preview.canConnect ? (preview.singleImport ? "确认后保存此条额度读数。单次导入不会自动更新，不读取密钥、提示词或对话正文。" : "确认后读取所选来源，只保存计量字段。重置、过期和读取错误会保留真实状态，不导入对话正文。") : "尚未找到可读取的有效来源。请重新选择文件或目录。", warning: !preview.canConnect)
                }
                errorText
            }
        } footer: {
            Button("取消") { model.cancelConnection() }.buttonStyle(WBButtonStyle())
            Button(model.connectionPreview?.singleImport == true ? "确认导入" : "连接来源") { model.confirmConnection() }.buttonStyle(WBButtonStyle(primary: true)).disabled(model.connectionPreviewLoading || model.connectionPreview?.canConnect != true).accessibilityIdentifier("fc.ai.connection.confirm")
        }.accessibilityIdentifier("fc.modal.ai.connection-preview")
    }
    private func previewIsStale(_ preview: AIUsageConnectionPreview) -> Bool {
        guard let observed = preview.observedAt else { return false }
        return Date().timeIntervalSince(observed) > 900 || preview.windows.contains { $0.resetsAt.map { $0 <= Date() } ?? false }
    }
    private func disconnectDialog(_ provider: AIProvider) -> some View {
        AIDialogShell(title: "断开 " + provider.title + "？", close: model.requestDismissDialog) {
            Text("断开后停止继续读取。已记录的本机 Token 历史和模型单价会保留，之后可以重新连接。").aiText(12, color: palette.secondary)
            errorText
        } footer: {
            Button("取消") { model.requestDismissDialog() }.buttonStyle(WBButtonStyle())
            Button("断开来源") { if model.setEnabled(false, provider: provider) { model.dialog = nil } }.buttonStyle(WBButtonStyle(destructive: true)).accessibilityIdentifier("fc.ai.disconnect.confirm")
        }.accessibilityIdentifier("fc.modal.ai.disconnect")
    }
    private func removePriceDialog(_ id: String) -> some View {
        AIDialogShell(title: "删除模型单价？", close: model.requestDismissDialog) {
            Text("此模型的本机记录会保留，但不再参与 API 等价成本估算。").aiText(12, color: palette.secondary)
            errorText
        } footer: {
            Button("取消") { model.requestDismissDialog() }.buttonStyle(WBButtonStyle())
            Button("删除单价") { model.removePrice(id); if model.errorMessage == nil { model.dialog = nil } }.buttonStyle(WBButtonStyle(destructive: true))
        }
    }
    private var helpDialog: some View {
        AIDialogShell(title: "AI 计量与隐私", close: model.requestDismissDialog) {
            VStack(alignment: .leading, spacing: 14) {
                helpLine("账户额度", "使用来源直接提供的百分比与窗口。超过 15 分钟未更新、窗口重置或读取失败会显示对应状态，不从 Token 反推。")
                helpLine("本机 Token", "仅读取已连接目录内可识别的计量字段。扫描有文件大小、数量和时间范围限制；读取覆盖情况在各来源详情中显示。")
                helpLine("保留范围", "Token 计量最多保留 31 天、20,000 条。断开只停止采集，不删除已记录的计量历史；不保存提示词、对话正文或认证密钥。")
                helpLine("等价成本", "只按你保存的模型单价估算，未配置的模型不计入金额。它不代表订阅账单、实际扣款或完整账户费用。")
                helpLine("Claude 连接", "通过官方客户端查询会员额度；API 计费登录与会员登录分开识别。独立会员连接由官方登录完成，不改变现有 Claude Code 登录。")
                if let open = URL(string: "https://code.claude.com/docs/en/authentication") { Link("Claude 官方登录说明", destination: open).font(.system(size: 11)).foregroundStyle(palette.accent) }
            }
        } footer: { Button("知道了") { model.requestDismissDialog() }.buttonStyle(WBButtonStyle(primary: true)) }
    }
    private func helpLine(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).aiText(13, weight: .medium, color: palette.text); Text(text).aiText(11, color: palette.secondary) }
    }
    @ViewBuilder private var errorText: some View {
        if let message = model.errorMessage { Text(message).aiText(11, color: palette.warning).accessibilityIdentifier("fc.ai.dialog.error") }
    }
    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
private struct AIDialogShell<Content: View, Footer: View>: View {
    var title: String
    var close: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchContentHeight) private var viewportHeight
    private var maximumBodyHeight: CGFloat { viewportHeight > 0 ? max(180, min(600, viewportHeight - 140)) : 430 }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(palette.text)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11)) }.buttonStyle(WBIconButtonStyle(size: 32)).accessibilityLabel("关闭弹窗")
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 13)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.dialog.header")
            WorkbenchDialogBody(maximumHeight: maximumBodyHeight, content: content)
                .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.dialog.body")
            HStack(spacing: 8) { Spacer(); footer() }.padding(.horizontal, 18).padding(.vertical, 13)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1).allowsHitTesting(false) }
                .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.dialog.footer")
        }.accessibilityElement(children:.contain).accessibilityLabel(title)
    }
}
private struct AIUsageDiscardDialog: View {
    @ObservedObject var model: AIUsageModel
    var price: Bool
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        AIDialogShell(title: "放弃未保存的修改？", close: keepEditing) {
            Text("你填写的内容尚未保存。继续编辑可保留当前内容。").aiText(12, color: palette.secondary)
        } footer: {
            Button("继续编辑", action: keepEditing).buttonStyle(WBButtonStyle())
            Button("放弃修改") { if price { model.discardPriceChanges() } else { model.discardDialogChanges() } }.buttonStyle(WBButtonStyle(destructive: true))
        }.accessibilityIdentifier("fc.modal.ai.discard")
    }
    private func keepEditing() { if price { model.confirmDiscardPrice = false } else { model.confirmDiscardDialog = false } }
}
private struct AIUsageErrorDialog: View {
    @ObservedObject var model: AIUsageModel
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        AIDialogShell(title: "AI 用量", close: { model.errorMessage = nil }) {
            Text(model.errorMessage ?? "").aiText(12, color: palette.secondary)
        } footer: { Button("知道了") { model.errorMessage = nil }.buttonStyle(WBButtonStyle(primary: true)) }
    }
}
