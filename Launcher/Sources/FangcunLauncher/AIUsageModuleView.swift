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
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchDeviceExpanded) private var expanded
    @State private var contentWidth: CGFloat = 864
    @State private var selectedBucket: Date?
    private var visibleRecords: [AITokenRecord] { model.filteredRecords(provider: model.selectedProvider, period: model.selectedPeriod) }
    private var routeID: String {
        switch model.destination { case .overview: "fc.page.ai"; case .provider(let provider): "fc.page.ai." + provider.rawValue; case .sources: "fc.page.ai.sources"; case .history: "fc.page.ai.history"; case .prices: "fc.page.ai.prices" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.destination != .overview { backRow }
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
    private var backRow: some View {
        HStack {
            Button { goBack() } label: { Label("返回", systemImage: "chevron.left") }.buttonStyle(WBButtonStyle(compact: true)).accessibilityIdentifier("fc.ai.back")
            Spacer()
        }.frame(height: 28).padding(.bottom, 12)
    }
    private func goBack() {
        if model.destination == .prices && model.hasUnsavedPriceChanges { model.requestPriceBack() }
        else if model.goBack() { returnToSettingsPrivacy?() }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: "AI 用量", subtitle: "账户额度与本机活动，分别记录") {
                HStack(spacing: 8) {
                    Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }.buttonStyle(WBButtonStyle()).disabled(model.isRefreshing).accessibilityIdentifier("fc.ai.refresh")
                    Button { model.openSources() } label: { Label("来源管理", systemImage: "point.3.connected.trianglepath.dotted") }.buttonStyle(WBButtonStyle()).accessibilityIdentifier("fc.ai.sources")
                }
            }
            storageProtection
            AIWeightedColumns(ratio: 1, gap: 12) {
                providerCard(.codex)
                providerCard(.claude)
            }
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
        AIProviderQuotaCard(summary: summary(provider), minimumHeight: detail ? (expanded ? 288 : 284) : (expanded ? 288 : 260.83), expanded: expanded, automaticReadingEnabled: model.configuration(for: provider).enabled, showsAction: !detail) {
            if detail { model.openSources() } else { model.show(.provider(provider)) }
        }
    }
    private var activitySectionHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("本机 Token 活动").aiText(12, weight: .medium, color: palette.text)
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
        return AIActionCard {
            AICardTitle(title: title, symbol: "chart.bar.xaxis", actionTitle: "查看 Token 记录") { model.show(.history) }
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
            Text(value).font(.system(size: 28)).monospacedDigit()
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
        return AIActionCard {
            AICardTitle(title: "模型分布", symbol: "square.stack.3d.up", actionTitle: "管理模型单价") { model.show(.prices) }
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
                Text(estimate.covered == 0 ? "未配置单价" : estimate.amount.formatted(.currency(code: "USD"))).aiText(11, weight: .medium, color: palette.text).monospacedDigit()
            }
            Text(estimate.covered == 0 ? "尚未配置单价，不代表账户账单。" : "单价覆盖 \(estimate.covered)/\(estimate.total) 条；估算不代表账户账单。").aiText(11, color: palette.muted).padding(.top, 7)
        }.frame(maxHeight: .infinity, alignment: .top)
    }
    private var recentActivity: some View {
        AIActionCard {
            AICardTitle(title: "最近活动", symbol: "clock.arrow.circlepath", actionTitle: "全部活动记录") { model.show(.history) }
            AITokenTable(records: Array(visibleRecords.sorted { $0.timestamp > $1.timestamp }.prefix(3)), model: model, compact: contentWidth < 800, scrollHeight: nil)
        }
    }
    private var privacyFootnote: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.shield").font(.system(size: 11))
            Text("仅保存本机计量字段，不保存提示词或对话正文").aiText(11, color: palette.muted)
            Spacer()
            Button("口径说明") { model.present(.help) }.buttonStyle(WBQuietButtonStyle())
        }.foregroundStyle(palette.muted)
    }
    private func providerDetail(_ provider: AIProvider) -> some View {
        let value = summary(provider)
        return VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: provider.title + " 用量", subtitle: "额度按来源提供的窗口计算；Token 为本机活动计量") {
                Button { model.present(.alert) } label: { Label("提醒设置", systemImage: "bell") }.buttonStyle(WBButtonStyle()).accessibilityIdentifier("fc.ai.alert")
            }
            storageProtection
            AIWeightedColumns(ratio: 1, gap: 12) {
                providerCard(provider, detail: true)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.detail.quota." + provider.rawValue)
                WBCard(spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.shield").font(.system(size: 16)).frame(width: 16, height: 16).foregroundStyle(palette.accent).accessibilityHidden(true)
                        Text("来源与有效性").aiText(12, weight: .medium, color: palette.text).accessibilityIdentifier("fc.ai.detail.validity.title")
                        Spacer(minLength: 0)
                        Button("管理来源") { model.openSources() }.buttonStyle(WBButtonStyle(compact: true)).accessibilityIdentifier("fc.ai.detail.manageSources")
                    }.frame(height: 22).padding(.bottom, 10)
                    AIFactRow(title: "来源类型", value: value.sourceDescription)
                    AIFactRow(title: "会员方案", value: value.accountPlanDescription)
                    AIFactRow(title: "最后有效采样", value: value.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚无读数")
                    AIFactRow(title: "当前状态", value: value.state.title + (model.configuration(for: provider).enabled ? "" : " · 自动读取关闭"), color: value.state == .ready ? palette.accent : palette.warning)
                    AIFactRow(title: "过期判定", value: "15 分钟未更新或窗口已重置")
                    AIFactRow(title: "额度提醒", value: model.alertRule.enabled ? "\(model.alertRule.warningPercent)% / \(model.alertRule.criticalPercent)% · " + model.notificationPermission.title : "未开启", last: true)
                    // Keep the surface stretched after moving its action back
                    // to the frozen title row. Longer actual readings may grow.
                    Spacer(minLength: 0)
                }.frame(minHeight: expanded ? 288 : 284, alignment: .top)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.detail.validity")
            }
            quotaHistory(provider).padding(.top, 12)
            AINotice(text: "图表仅展示最近 24 小时实际读数，本机最多保留 31 天。跨重置、来源切换和采集中断会分段；空白不代表 0，不用 Token 推算额度。")
                .accessibilityIdentifier("fc.ai.detail.historyNotice").padding(.top, 12)
            AIWeightedColumns(ratio: 1, gap: 12) {
                providerTokenCard(provider)
                coverageCard(provider)
            }.padding(.top, 12)
        }
    }
    private func quotaHistory(_ provider: AIProvider) -> some View {
        let now = Date()
        let recentSnapshots = model.quotaHistory.filter { $0.observedAt >= now.addingTimeInterval(-86_400) && $0.observedAt <= now }
        let segments = AIQuotaHistorySegmentation.segments(recentSnapshots, provider: provider)
        let points = segments.flatMap { $0.points }
        return WBCard(spacing: 0) {
            AICardTitle(title: "已观测额度历史", symbol: "clock.arrow.circlepath", trailing: "最近 24 小时")
            if points.isEmpty {
                Text("最近 24 小时尚无有效额度历史。连接来源并读取后显示。").aiText(12, color: palette.muted).frame(maxWidth: .infinity, minHeight: expanded ? 170 : 155)
            } else {
                Chart {
                    ForEach(segments) { segment in
                        ForEach(segment.points) { point in
                            LineMark(x: .value("采集时间", point.date), y: .value("已用百分比", point.usedPercent), series: .value("窗口", segment.id))
                                .foregroundStyle(segment.window.durationMinutes == 10_080 ? palette.secondary : palette.accent)
                            PointMark(x: .value("采集时间", point.date), y: .value("已用百分比", point.usedPercent))
                                .foregroundStyle(segment.window.durationMinutes == 10_080 ? palette.secondary : palette.accent).symbolSize(14)
                        }
                    }
                }.chartYScale(domain: 0...100)
                    .chartYAxis { AxisMarks(values: [0, 50, 100]) { value in AxisGridLine(); AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%") } } } }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: .dateTime.month().day().hour()) } }
                    .frame(height: expanded ? 170 : 155)
            }
            HStack(spacing: 14) {
                Label("短期窗口", systemImage: "circle.fill").foregroundStyle(palette.accent)
                Label("每周窗口", systemImage: "circle.fill").foregroundStyle(palette.secondary)
                Spacer()
                Text("\(points.count) 个实际读数").foregroundStyle(palette.muted)
            }.font(.system(size: 10)).padding(.top, 10)
        }.frame(minHeight: 240, alignment: .top)
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
                Text(first.formatted(date: .abbreviated, time: .shortened) + " 至 " + last.formatted(date: .abbreviated, time: .shortened)).aiText(11, color: palette.muted).padding(.top, 12)
            }
            if model.tokenHistoryCapacityLimited { AINotice(text: "历史达到容量上限，较早记录已移出；统计仅覆盖当前保留范围。", warning: true).padding(.top, 10) }
            if let message = model.tokenHistoryMessage { AINotice(text: message, warning: true).padding(.top, 10) }
        }
    }
    private var sources: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: "AI 数据来源", subtitle: "只读取用量元数据，不读取密钥或对话正文") {
                Button { model.present(.manual) } label: { Label("添加记录", systemImage: "plus") }.buttonStyle(WBButtonStyle()).accessibilityIdentifier("fc.ai.manual")
            }
            storageProtection
            AIWeightedColumns(ratio: 1, gap: 12) { sourceCard(.codex); sourceCard(.claude) }
            AINotice(text: "断开只停止继续读取，已记录的 Token 历史会保留。不会读取认证密钥，也不保存提示词或对话正文。").padding(.top, 12)
            HStack(spacing: 12) {
                Button("导入单次额度 JSON") { model.importQuota() }.buttonStyle(WBQuietButtonStyle())
                Button("导出 JSON 模板") { model.exportTemplate() }.buttonStyle(WBQuietButtonStyle())
                Menu("更多来源操作") {
                    Button("连接 Codex 额度 JSON") { model.chooseQuotaFile(for: .codex) }
                    if model.configuration(for: .codex).quotaPath != nil { Button("移除 Codex 额度 JSON 连接") { model.removeQuotaFile(for: .codex) } }
                }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).foregroundStyle(palette.secondary)
                Spacer()
                Button("来源与隐私说明") { model.present(.help) }.buttonStyle(WBQuietButtonStyle())
            }.padding(.top, 12)
        }
    }
    private func sourceCard(_ provider: AIProvider) -> some View {
        let config = model.configuration(for: provider)
        let value = summary(provider)
        let actualCoverage = model.coverage[provider]
        let connectionTitle = !config.enabled ? "自动读取关闭" : actualCoverage == nil ? "尚未读取" : actualCoverage?.sourceAvailable == true ? "已连接" : "来源不可用"
        let connected = config.enabled && actualCoverage?.sourceAvailable == true
        let savedReading = config.manualSnapshot.map { $0.source.title + " · " + $0.observedAt.formatted(date: .abbreviated, time: .shortened) }
        let sourceDetail = config.enabled ? (model.diagnostics[provider] ?? "尚无采样，等待首次读取") + (savedReading.map { "；另有" + $0 } ?? "") :
            (savedReading.map { $0 + "；" } ?? "") + "自动读取关闭，不扫描目录或额度文件；历史保留"
        return WBCard(spacing: 0) {
            HStack(spacing: 7) {
                AIProviderLogo(provider: provider, size: 16)
                Text(provider.title).aiText(12, weight: .medium, color: palette.secondary)
                Spacer()
            }.frame(height: 22).padding(.bottom, 10)
            AISourceRow(title: provider == .codex ? "本机会话目录" : "本机会话 Token", detail: provider == .codex ? "读取额度与 Token 元数据" : "只提供 Token 记录，不推断订阅额度") {
                AIStateChip(title: connectionTitle, positive: connected)
            }
            if provider == .codex {
                AISourceRow(title: "来源状态", detail: sourceDetail) {
                    Button("重新读取") { model.refresh() }.buttonStyle(WBButtonStyle(compact: true)).disabled(model.isRefreshing)
                }
                AISourceRow(title: "目录范围", detail: config.sessionsPath) {
                    Button("更改目录") { model.chooseSessionsDirectory(for: provider) }.buttonStyle(WBButtonStyle(compact: true))
                }
                AISourceRow(title: "断开来源", detail: "保留已有历史，停止后续读取", last: true) {
                    if config.enabled {
                        Button("断开") { model.present(.disconnect(provider)) }.buttonStyle(WBButtonStyle(destructive: true, compact: true)).accessibilityIdentifier("fc.ai.disconnect." + provider.rawValue)
                    } else {
                        Button("恢复读取") { model.setEnabled(true, provider: provider) }.buttonStyle(WBButtonStyle(compact: true))
                    }
                }
            } else {
                AISourceRow(title: "额度快照", detail: value.snapshot?.source.title ?? "官方状态栏导出的用量字段") {
                    AIStateChip(title: value.state == .ready ? "有效" + (value.updatedAt.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? "") : value.state.title, positive: value.state == .ready)
                }
                AISourceRow(title: "连接方式", detail: "选择额度 JSON，或导出状态栏适配器", last: true) {
                    Button("连接设置") { model.present(.claudeConnect) }.buttonStyle(WBButtonStyle(compact: true))
                }
            }
        }.frame(minHeight: 305.32, alignment: .top)
    }
    private var history: some View {
        let records = model.filteredRecords(provider: model.selectedProvider, period: model.selectedPeriod, includeDisconnected: true).sorted { $0.timestamp > $1.timestamp }
        return VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: "Token 活动记录", subtitle: "仅显示用量元数据；已断开来源的历史仍保留") { filters }
            WBCard(spacing: 0) {
                AICardTitle(title: "最近活动", symbol: "clock.arrow.circlepath", trailing: "\(records.count) 条记录")
                AITokenTable(records: records, model: model, compact: contentWidth < 800, scrollHeight: expanded ? 525 : 405)
            }
            if model.tokenHistoryCapacityLimited { AINotice(text: "历史容量最多 20,000 条，最长保留 31 天。较早记录已移出，当前列表不代表完整账户历史。", warning: true).padding(.top, 12) }
            privacyFootnote.padding(.top, 12)
        }
    }
    private var prices: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: "模型单价", subtitle: "API 等价估算不代表订阅账单或实际付费") {
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
                        }.padding(.vertical, 12).overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
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
private struct AIProviderQuotaCard: View {
    let summary: AIProviderSummary
    let minimumHeight: CGFloat
    let expanded: Bool
    var automaticReadingEnabled = true
    var showsAction = true
    var action: () -> Void
    @Environment(\.workbenchPalette) private var palette
    @State private var hovering = false
    @FocusState private var actionFocused: Bool
    private var windows: [AIQuotaWindow] { summary.snapshot?.availableWindows ?? [] }
    private var rowGap: CGFloat { expanded ? 18 : 14 }
    private var sourceText: String {
        if !automaticReadingEnabled { return summary.snapshot == nil ? "自动读取关闭" : summary.sourceDescription + " · 自动读取关闭" }
        return summary.state == .disconnected ? "来源已断开" : summary.sourceDescription
    }
    var body: some View {
        Group {
            if showsAction {
                Button(action: action) { cardContent }
                    .buttonStyle(.plain)
                    .focused($actionFocused)
                    .help("查看 " + summary.title + " 用量详情")
                    .accessibilityLabel("查看 " + summary.title + " 用量详情")
                    .accessibilityIdentifier("fc.ai.provider." + summary.provider.rawValue)
            } else { cardContent }
        }.onHover { hovering = $0 }
    }
    private var cardContent: some View {
        WBCard(spacing: 0) {
            HStack(spacing: 10) {
                AIProviderLogo(provider: summary.provider)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(summary.title).aiText(14, weight: .medium, color: palette.text)
                        if let plan = summary.snapshot?.accountPlan {
                            Text(plan.title).aiText(10, weight: .medium, color: palette.secondary)
                                .padding(.horizontal, 6).frame(height: 18)
                                .background(palette.soft, in: RoundedRectangle(cornerRadius: 5))
                                .help("来源报告的会员方案；未提供的倍率不作推算")
                                .accessibilityIdentifier("fc.ai.plan." + summary.provider.rawValue)
                        }
                    }.frame(height: 20, alignment: .leading)
                    Text(sourceText).aiText(11, color: palette.muted).lineLimit(1).truncationMode(.middle).help(sourceText).frame(height: 16)
                }
                Spacer()
                if showsAction {
                    Image(systemName: "arrow.up.right").font(.system(size: 11))
                        .foregroundStyle(palette.secondary).opacity(hovering || actionFocused ? 1 : 0)
                        .frame(width: 26, height: 26).accessibilityHidden(true)
                }
            }.frame(height: 40)
                .aiQuotaMeasuredRegion("fc.ai.quota.header." + summary.provider.rawValue)
                .padding(.bottom, 14)
                .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.quota.header." + summary.provider.rawValue)
            quotaContent.frame(height: 128 + rowGap, alignment: .top)
            Spacer(minLength: 12)
            HStack(spacing: 5) {
                Circle().fill(summary.state == .ready ? palette.accent : summary.state == .error ? palette.warning : palette.muted).frame(width: 5, height: 5)
                Text(summary.state.title)
                if let updated = summary.updatedAt { Text("· " + updated.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())).monospacedDigit() }
                Spacer(minLength: 0)
                Text(summary.snapshot?.source == .manual ? "手动记录" : summary.snapshot?.source == .imported ? "导入读数" : "本机来源")
            }.font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).frame(height: 16)
                .aiQuotaMeasuredRegion("fc.ai.quota.footer." + summary.provider.rawValue)
                .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.quota.footer." + summary.provider.rawValue)
            Text(summary.state == .ready ? (summary.snapshot?.accountPlan == nil ? "会员档位未提供 · 不从额度推算" : "会员倍率未提供 · 不从额度推算") : summary.detail)
                .aiText(11, color: summary.state == .error ? palette.warning : palette.muted)
                .lineLimit(1).truncationMode(.tail).help(summary.state == .ready ? summary.accountPlanDescription : summary.detail)
                .frame(height: 16).padding(.top, 6)
        }.frame(minHeight: minimumHeight, alignment: .top)
            .contentShape(RoundedRectangle(cornerRadius: 15))
    }
    @ViewBuilder private var quotaContent: some View {
        if windows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 20)).foregroundStyle(palette.muted)
                Text("暂无可用额度窗口").aiText(12, weight: .medium, color: palette.secondary)
                Text("连接来源后显示实际提供的周期；不会把缺失窗口记作 0%。")
                    .aiText(11, color: palette.muted).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityIdentifier("fc.ai.quota.empty." + summary.provider.rawValue)
        } else {
            VStack(alignment: .leading, spacing: rowGap) {
                ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                    AIQuotaRow(window: window, identifier: "fc.ai.quota." + summary.provider.rawValue + "." + String(index))
                }
                if windows.count == 1 {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "info.circle").font(.system(size: 11)).padding(.top, 1)
                        Text("当前来源仅提供上述周期。其他窗口未提供，暂不显示。")
                            .font(.system(size: 11)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }.foregroundStyle(palette.muted).frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                        .aiQuotaMeasuredRegion("fc.ai.quota.availableOnly." + summary.provider.rawValue)
                        .accessibilityIdentifier("fc.ai.quota.availableOnly." + summary.provider.rawValue)
                }
            }
        }
    }
}
private struct AIQuotaRow: View {
    var window: AIQuotaWindow
    var identifier: String
    @Environment(\.workbenchPalette) private var palette
    private var color: Color { window.severity == 2 ? palette.critical : window.severity == 1 ? palette.warning : palette.accent }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title).aiText(12, color: palette.secondary).lineLimit(1)
                Spacer()
                Text(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))) + "%").font(.system(size: 21)).monospacedDigit()
                Text("已用").aiText(11, color: palette.muted)
            }.frame(height: 26)
            WBProgress(value: window.usedPercent / 100, color: color, height: 6)
                .aiQuotaMeasuredRegion(identifier + ".progress")
                .accessibilityElement(children: .ignore).accessibilityLabel(window.title + "已用 " + window.usedPercent.formatted() + "%")
                .accessibilityIdentifier(identifier + ".progress")
            HStack(spacing: 6) {
                Text(window.resetsAt.map { $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()) + " 重置" } ?? "未提供重置时间").lineLimit(1)
                Spacer(minLength: 0)
                Text(countdown(window) + "剩余 " + window.remainingPercent.formatted(.number.precision(.fractionLength(0...1))) + "%").foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.9)
            }.font(.system(size: 11)).foregroundStyle(palette.muted).frame(height: 16)
        }.frame(height: 64).accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }
    private func countdown(_ window: AIQuotaWindow) -> String {
        guard let reset = window.resetsAt else { return "" }
        let remaining = reset.timeIntervalSinceNow
        guard remaining > 0 else { return "已到重置时间 · " }
        let minutes = max(1, Int(remaining / 60)), days = Int(remaining / 86_400)
        if days > 0 { return "还有 \(days) 天 · " }
        if minutes >= 60 { return "还有 \(minutes / 60) 小时 \(minutes % 60) 分 · " }
        return "还有 \(minutes) 分钟 · "
    }
}
private struct AIHoveredCardKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var aiCardHovered: Bool {
        get { self[AIHoveredCardKey.self] }
        set { self[AIHoveredCardKey.self] = newValue }
    }
}
private struct AIActionCard<Content: View>: View {
    let content: Content
    @State private var hovering = false
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        WBCard(spacing: 0) { content.environment(\.aiCardHovered, hovering) }
            .onHover { hovering = $0 }
    }
}
private struct AICardTitle: View {
    var title: String
    var symbol: String
    var trailing: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.aiCardHovered) private var cardHovered
    @FocusState private var actionFocused: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(palette.accent)
            Text(title).aiText(12, weight: .medium, color: palette.secondary)
            Spacer()
            if let trailing { Text(trailing).aiText(11, color: palette.muted) }
            if let actionTitle, let action {
                Button(action: action) {
                    Image(systemName: "arrow.up.right").font(.system(size: 11))
                        .opacity(cardHovered || actionFocused ? 1 : 0)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(palette.secondary)
                    .focused($actionFocused).help(actionTitle).accessibilityLabel(actionTitle)
            }
        }.frame(height: 22).padding(.bottom, 10)
    }
}
private struct AITokenTable: View {
    var records: [AITokenRecord]
    @ObservedObject var model: AIUsageModel
    var compact: Bool
    var scrollHeight: CGFloat?
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        VStack(spacing: 0) {
            rowHeader
            if let scrollHeight {
                ScrollView { LazyVStack(spacing: 0) { rows }.frame(maxWidth: .infinity) }.frame(height: scrollHeight)
            } else { rows }
        }
    }
    private var rowHeader: some View {
        HStack(spacing: compact ? 6 : 12) {
            Text("时间").frame(width: compact ? 72 : 92, alignment: .leading)
            Text("来源 / 模型").frame(maxWidth: .infinity, alignment: .leading)
            Text("输入").frame(width: compact ? 52 : 74, alignment: .trailing)
            Text("输出").frame(width: compact ? 52 : 74, alignment: .trailing)
        }.aiText(11, color: palette.muted).padding(.vertical, 10).overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
    @ViewBuilder private var rows: some View {
        if records.isEmpty {
            Text("此范围内尚无可识别的本机计量记录").aiText(11, color: palette.muted).frame(maxWidth: .infinity, minHeight: 80)
        } else {
            ForEach(records, id: \.selfIdentity) { record in
                HStack(spacing: compact ? 6 : 12) {
                    Text(record.timestamp.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())).foregroundStyle(palette.muted).frame(width: compact ? 72 : 92, alignment: .leading)
                    Text(record.provider.title + " · " + record.model).foregroundStyle(palette.secondary).lineLimit(1).help(record.provider.title + " · " + record.model).frame(maxWidth: .infinity, alignment: .leading)
                    Text(aiCount(record.tokens.input)).monospacedDigit().frame(width: compact ? 52 : 74, alignment: .trailing)
                    Text(aiCount(record.tokens.output)).foregroundStyle(palette.muted).monospacedDigit().frame(width: compact ? 52 : 74, alignment: .trailing)
                }.font(.system(size: 11)).frame(minHeight: 15.95).padding(.vertical, 11).overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
            }
        }
    }
}
private extension AITokenRecord { var selfIdentity: String { provider.rawValue + ":" + id } }
private struct AIStateChip: View {
    var title: String
    var positive: Bool
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        Text(title).font(.system(size: 11)).foregroundStyle(positive ? palette.success : palette.muted)
            .padding(.horizontal, 7).padding(.vertical, 3).background((positive ? palette.success : palette.muted).opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}
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
                RoundedRectangle(cornerRadius: 8).fill(warning ? palette.surface : palette.soft)
                    .overlay { if warning { RoundedRectangle(cornerRadius: 8).fill(palette.warning.opacity(0.10)) } }
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
        configuration.textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.text).padding(.horizontal, 10).frame(height: 32)
            .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
    }
}
private extension View {
    func aiText(_ size: CGFloat, weight: Font.Weight = .regular, color: Color) -> some View {
        font(.system(size: size, weight: weight)).foregroundStyle(color).lineSpacing(size * 0.25).fixedSize(horizontal: false, vertical: true).frame(minHeight: size * 1.45, alignment: .leading)
    }
}
private func aiCount(_ value: Int64) -> String {
    let number = Double(value)
    if number >= 1_000_000 { return (number / 1_000_000).formatted(.number.precision(.fractionLength(0...2))) + "M" }
    if number >= 1_000 { return (number / 1_000).formatted(.number.precision(.fractionLength(0...1))) + "K" }
    return value.formatted()
}

private struct AIUsageDialogContent: View {
    @ObservedObject var model: AIUsageModel
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
                    Toggle("额度接近上限时提醒", isOn: $model.alertEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityIdentifier("fc.ai.alert.enabled")
                }
                HStack(spacing: 14) {
                    AIFieldLabel("留意 · 已用达到（%）") { TextField("75", text: $model.alertWarningText).textFieldStyle(AIFieldStyle()).accessibilityIdentifier("fc.ai.alert.warning") }
                    AIFieldLabel("紧张 · 已用达到（%）") { TextField("90", text: $model.alertCriticalText).textFieldStyle(AIFieldStyle()).accessibilityIdentifier("fc.ai.alert.critical") }
                }
                AINotice(text: "来源过期或缺失时不触发额度通知，不用 Token 推算额度。")
                if model.notificationPermission == .denied || model.notificationPermission == .unavailable {
                    HStack(alignment: .top, spacing: 12) {
                        Text(model.notificationPermission == .denied ? "系统通知未获允许，规则仍会保存。请允许方寸发送通知。" : "当前运行环境无法发送系统通知，规则可先保存在本机。").aiText(11, color: palette.warning)
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
        AIDialogShell(title: "手动记录额度", close: model.requestDismissDialog) {
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
                        Toggle("已知实际重置时间", isOn: $model.manualDraft.specifiesResetTimes).toggleStyle(.checkbox)
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
            Button("取消") { model.requestDismissDialog() }.buttonStyle(WBButtonStyle())
            Button("保存记录") { model.saveManualDraft() }.buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("fc.ai.manual.save")
        }.accessibilityIdentifier("fc.modal.ai.manual")
        #if DEBUG
        .onAppear { inspection?.attach(owner: inspectionOwner, expanded: $manualTimesExpanded, knownReset: $model.manualDraft.specifiesResetTimes) }
        .onDisappear { inspection?.detach(owner: inspectionOwner) }
        #endif
    }
    private func dateTimeField(_ title: String, selection: Binding<Date>) -> some View {
        AIFieldLabel(title) {
            HStack(spacing: 12) {
                WBDateInput(title + " · 日期", selection: selection, components: .date, calendar: inputCalendar)
                    .frame(maxWidth: .infinity)
                WBDateInput(title + " · 时间", selection: selection, components: .time, calendar: inputCalendar)
                    .frame(maxWidth: .infinity)
            }
        }
    }
    private var claudeDialog: some View {
        AIDialogShell(title: "连接 Claude 额度", close: model.requestDismissDialog) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Claude 本机会话只包含 Token。额度需要独立来源。").aiText(12, color: palette.secondary).padding(.bottom, 4)
                AISourceRow(title: "选择额度 JSON", detail: "读取官方状态栏适配器生成或你已有的额度文件") {
                    Button("选择文件") { model.chooseQuotaFile(for: .claude) }.buttonStyle(WBButtonStyle(compact: true)).accessibilityIdentifier("fc.ai.claude.json")
                }
                AISourceRow(title: "导出状态栏适配器", detail: "只导出脚本，不会替换你现有的 Claude 配置", last: true) {
                    Button("导出") { model.exportClaudeAdapter() }.buttonStyle(WBButtonStyle(compact: true)).accessibilityIdentifier("fc.ai.claude.adapter")
                }
                AINotice(text: "适配器只接收官方状态栏提供的额度字段。配置后需由 Claude 产生真实读数；缺失时显示不可用。").padding(.top, 16)
                if model.configuration(for: .claude).quotaPath != nil {
                    HStack { Text("已配置额度文件").aiText(11, color: palette.muted); Spacer(); Button("移除连接") { model.removeQuotaFile(for: .claude) }.buttonStyle(WBQuietButtonStyle()) }.padding(.top, 12)
                }
                errorText.padding(.top, model.errorMessage == nil ? 0 : 12)
            }
        } footer: {
            Menu("会话来源") {
                Text(model.configuration(for: .claude).sessionsPath)
                Button("更改 Token 会话目录") { model.chooseSessionsDirectory(for: .claude) }
                if model.configuration(for: .claude).enabled { Button("断开 Claude 来源") { model.present(.disconnect(.claude)) } }
                else { Button("恢复读取") { model.setEnabled(true, provider: .claude) } }
            }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).foregroundStyle(palette.secondary)
            Button("完成") { model.requestDismissDialog() }.buttonStyle(WBButtonStyle(primary: true))
        }.accessibilityIdentifier("fc.modal.ai.claude-connect")
    }
    private var previewDialog: some View {
        AIDialogShell(title: model.connectionPreview.map { "连接 " + $0.provider.title + " 来源" } ?? "检查来源", close: model.requestDismissDialog) {
            VStack(alignment: .leading, spacing: 14) {
                if model.connectionPreviewLoading {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在检查可识别的计量字段…").aiText(12, color: palette.secondary) }.frame(maxWidth: .infinity, minHeight: 140)
                } else if let preview = model.connectionPreview {
                    AISourceRow(title: URL(fileURLWithPath: preview.path).lastPathComponent, detail: preview.path, last: true, first: true) {
                        AIStateChip(title: !preview.canConnect ? "不可读取" : previewIsStale(preview) ? "可读取 · 已过期" : "可读取", positive: preview.canConnect && !previewIsStale(preview))
                    }
                    VStack(spacing: 0) {
                        if preview.quotaFile {
                            AIFactRow(title: "有效读数", value: preview.windows.map { $0.title + " " + $0.usedPercent.formatted(.number.precision(.fractionLength(0...1))) + "%" }.joined(separator: " · "))
                            AIFactRow(title: "采集时间", value: preview.observedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未提供")
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
                if let open = URL(string: "https://code.claude.com/docs/en/statusline") { Link("Claude 官方状态栏说明", destination: open).font(.system(size: 11)).foregroundStyle(palette.accent) }
            }
        } footer: { Button("知道了") { model.requestDismissDialog() }.buttonStyle(WBButtonStyle(primary: true)) }
    }
    private func helpLine(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).aiText(12, weight: .medium, color: palette.text); Text(text).aiText(11, color: palette.secondary) }
    }
    @ViewBuilder private var errorText: some View {
        if let message = model.errorMessage { Text(message).aiText(11, color: palette.warning).accessibilityIdentifier("fc.ai.dialog.error") }
    }
    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
private struct AIDialogBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct AIDialogShell<Content: View, Footer: View>: View {
    var title: String
    var close: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchContentHeight) private var viewportHeight
    @State private var measuredBodyHeight: CGFloat = 0
    private var maximumBodyHeight: CGFloat { viewportHeight > 0 ? max(180, min(600, viewportHeight - 140)) : 430 }
    private var bodyHeight: CGFloat { min(maximumBodyHeight, max(36, measuredBodyHeight > 0 ? measuredBodyHeight : 60)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(palette.text)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11)) }.buttonStyle(WBIconButtonStyle(size: 32)).accessibilityLabel("关闭弹窗")
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 13)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .contain).accessibilityIdentifier("fc.ai.dialog.header")
            ScrollView {
                content().frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18).padding(.bottom, 18)
                    .background(GeometryReader { geometry in Color.clear.preference(key: AIDialogBodyHeightKey.self, value: geometry.size.height).allowsHitTesting(false) })
            }.frame(height: bodyHeight)
                .scrollBounceBehavior(.basedOnSize)
                .background(WorkbenchOverlayScrollbars())
                .onPreferenceChange(AIDialogBodyHeightKey.self) { height in
                    // Scrollbar probes and conditional siblings may emit the
                    // default preference during a layout pass. They must not
                    // replace a real content measurement with a zero viewport.
                    if height.isFinite, height > 0, abs(measuredBodyHeight - height) > 0.25 { measuredBodyHeight = height }
                }
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
