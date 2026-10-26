import AppKit
import SwiftUI
import LauncherCore

enum ProviderUsageFormatting {
    static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.locale = .current; formatter.timeZone = timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date) + " · " + (timeZone.abbreviation(for: date) ?? timeZone.identifier)
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
    func edit(_ source: ProviderUsageConfiguration) { editor = ProviderUsageEditor(source: source, existing: true) }
    func add(_ kind: ProviderUsageKind) { editor = ProviderUsageEditor(source: .init(kind: kind, name: kind.title, resourceID: ""), existing: false) }
    func requestCloseEditor() {
        guard let editor, !editor.saving else { return }
        if editor.hasChanges { discardEditor = true } else { self.editor = nil }
    }
    func discard() { editor?.secret = ""; editor = nil; discardEditor = false }
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
    init(source: ProviderUsageConfiguration, existing: Bool) {
        original = source; self.existing = existing; kind = source.kind; name = source.name
        resourceID = source.resourceID; enabled = source.enabled
        thresholdMB = Self.number(Double(source.refreshPolicy.byteThreshold) / 1_000_000)
        minimumHours = Self.number(source.refreshPolicy.minimumInterval / 3600)
        maximumHours = Self.number(source.refreshPolicy.maximumInterval / 3600)
    }
    static func number(_ value: Double) -> String { value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...6))) }
    var hasChanges: Bool {
        !secret.isEmpty || kind != original.kind || name != original.name || resourceID != original.resourceID || enabled != original.enabled
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
    @Environment(\.workbenchPalette) private var palette
    init(app: WorkbenchAppModel) {
        self.app = app; model = app.providerUsage; ai = app.ai; presentation = app.usagePresentation; context = app.context
    }
    var body: some View {
        Group {
            if ai.destination != .overview { aiContent }
            else if let id = presentation.selectedSourceID, let source = model.sources.first(where: { $0.id == id }) { detail(source) }
            else { aiContent }
        }
        .workbenchModal(item: $presentation.editor, width: 520, onRequestDismiss: presentation.requestCloseEditor) { editor in
            ProviderUsageEditorView(editor: editor, model: model, presentation: presentation)
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
                        if await model.remove(id: source.id) { presentation.removing = nil; presentation.selectedSourceID = nil }
                        presentation.isRemoving = false
                    }
                }.buttonStyle(WBButtonStyle(destructive: true)).disabled(presentation.isRemoving)
            }
        }
        .workbenchModal(isPresented: $presentation.showingBrowserSetup, width: 540) {
            ProviderBrowserSetupView(app: app, close: { presentation.showingBrowserSetup = false })
        }
        .workbenchModal(isPresented: Binding(get: { model.errorMessage != nil && presentation.editor == nil && presentation.removing == nil }, set: { if !$0 { model.errorMessage = nil } }), width: 470) {
            WorkbenchDialogFrame(title: "服务用量", dismiss: { model.errorMessage = nil }) {
                Text(model.errorMessage ?? "").font(.system(size: 12)).foregroundStyle(palette.secondary)
            } actions: { Spacer(); Button("知道了") { model.errorMessage = nil }.buttonStyle(WBButtonStyle(primary: true)) }
        }
        .onChange(of: model.sources.map(\.id)) { _, ids in
            if let selected = presentation.selectedSourceID, !ids.contains(selected) { presentation.selectedSourceID = nil }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("fc.page.usage")
    }
    private var aiContent: some View {
        AIUsageModuleView(model: ai, openDesktopCards: { app.navigate(.cards) }, returnToSettingsPrivacy: { app.navigate(.settings); app.settingsTab = .privacy },
                          overviewTitle: "用量统计", overviewSubtitle: "AI 额度与服务流量，各自保留独立周期", overviewRefreshTitle: "刷新 AI", overviewSourcesTitle: "AI 来源", overviewSupplement: AnyView(serviceOverview))
    }
    private var serviceOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("服务流量额度").font(.system(size: 12, weight: .medium))
                    Text("从平台读取余额；与本机网络预算分开").font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                Spacer(minLength: 8)
                Button("添加搬瓦工") { presentation.add(.bandwagon) }.buttonStyle(WBButtonStyle(compact: true)).accessibilityIdentifier("fc.usage.add.bandwagon")
                Button("添加 IPRoyal") { presentation.add(.iproyal) }.buttonStyle(WBButtonStyle(compact: true)).accessibilityIdentifier("fc.usage.add.iproyal")
            }
            if let storageError = model.storageError {
                WBCard(title: "用量记录需要恢复", symbol: "exclamationmark.shield") {
                    Text(storageError).font(.system(size: 11)).foregroundStyle(palette.warning)
                    Text("原文件已保留。恢复有效文件后重新打开方寸，避免覆盖已有连接。").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            }
            if model.sources.isEmpty {
                WBCard {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "network").font(.system(size: 24, weight: .light)).foregroundStyle(palette.accent)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("连接你的服务额度").font(.system(size: 13, weight: .medium))
                            Text("每笔 ISP 订单、每台 VPS 都是一条独立来源，可以使用不同的周期和额度。").font(.system(size: 11)).foregroundStyle(palette.secondary)
                            Text("搬瓦工使用实例 API Key；IPRoyal 通过 Chrome 网页助手连接，首次安装与账号联调仍需完成。").font(.system(size: 11)).foregroundStyle(palette.muted)
                            Button("IPRoyal 连接方式") { presentation.showingBrowserSetup = true }.buttonStyle(WBQuietButtonStyle())
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 6)
                }.accessibilityIdentifier("fc.usage.empty")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12)], spacing: 12) {
                    ForEach(model.sources) { source in
                        Button { presentation.selectedSourceID = source.id } label: {
                            ProviderQuotaCard(source: source, state: model.state(for: source.id), refreshing: model.refreshing.contains(source.id), timeZone: context.dateContext.timeZone)
                        }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 15))
                            .accessibilityLabel(source.name + "，查看额度详情").accessibilityIdentifier("fc.usage.source." + source.id.uuidString)
                    }
                }
            }
        }.foregroundStyle(palette.text)
    }
    private func detail(_ source: ProviderUsageConfiguration) -> some View {
        let state = model.state(for: source.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Button { presentation.selectedSourceID = nil } label: { Label("返回用量统计", systemImage: "chevron.left") }.buttonStyle(WBButtonStyle(compact: true)); Spacer() }.padding(.bottom, 2)
            WBPageHeader(title: source.name, subtitle: source.kind.title + " · " + (source.kind == .iproyal ? "订单 " : "实例 ") + source.resourceID) {
                HStack(spacing: 8) {
                    Button("刷新") { model.refresh(id: source.id, manual: true) }.buttonStyle(WBButtonStyle()).disabled(model.refreshing.contains(source.id))
                    Button("配置") { presentation.edit(source) }.buttonStyle(WBButtonStyle())
                }
            }
            ProviderQuotaCard(source: source, state: state, refreshing: model.refreshing.contains(source.id), timeZone: context.dateContext.timeZone)
            if state.refresh.authenticationRequired {
                WBCard(title: "恢复连接", symbol: "person.crop.circle.badge.exclamationmark") {
                    Text(source.kind == .iproyal ? "在 Chrome 中恢复 IPRoyal 登录，再点击重新连接。登录会话由浏览器保留。" : "请核对实例编号与 API Key，在配置中重新验证。原有效读数会保留。")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                    Button("重新连接") { if source.kind == .iproyal { model.reconnect(id: source.id) } else { presentation.edit(source) } }.buttonStyle(WBButtonStyle(primary: true))
                }
            }
            WBCard(title: "更新策略", symbol: "arrow.triangle.2.circlepath", spacing: 12) {
                detailRow("累计触发", ProviderUsageEditor.number(Double(source.refreshPolicy.byteThreshold) / 1_000_000) + " MB")
                detailRow("最短间隔", ProviderUsageEditor.number(source.refreshPolicy.minimumInterval / 3600) + " 小时")
                detailRow("最长未刷新", ProviderUsageEditor.number(source.refreshPolicy.maximumInterval / 3600) + " 小时")
                detailRow("本机待累计", ProviderUsageEditor.number(Double(state.refresh.pendingBytes) / 1_000_000) + " MB")
                Text("累计量达到阈值且满足最短间隔时查询；低流量时按最长间隔补查。本机流量只作活跃信号，未计入此服务的账单。休眠或断网期间不补造数据。").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            WBCard(title: "来源与计量", symbol: "info.circle", spacing: 12) {
                detailRow("连接方式", source.kind == .bandwagon ? "实例 API Key · 本机钥匙串" : "Chrome 网页助手 · 浏览器登录会话")
                detailRow("统计截止时间", "平台未提供")
                if let snapshot = state.snapshot {
                    detailRow("查询时间", ProviderUsageFormatting.timestamp(snapshot.observedAt, timeZone: context.dateContext.timeZone))
                    detailRow("单位口径", snapshot.displayUnit.explanation)
                    detailRow("数据来源", snapshot.sourceDescription)
                }
                Text(source.kind == .bandwagon ? "直接使用平台的账单计数，不再将上下行额外翻倍。密钥可能具备其他管理权限，但方寸仅调用用量查询。" : "只读取订单的额度、已用量、余额和重置日期，不读取 Google 密码、Cookie 或 Token。Chrome 退出、登录失效或网站变化时可能暂停更新。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                if source.kind == .iproyal { Button("浏览器连接设置") { presentation.showingBrowserSetup = true }.buttonStyle(WBButtonStyle(compact: true)) }
            }
            HStack { Spacer(); Button("移除来源") { model.errorMessage = nil; presentation.removing = source }.buttonStyle(WBButtonStyle(destructive: true)) }
        }.accessibilityIdentifier("fc.usage.detail")
    }
    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) { Text(title).foregroundStyle(palette.muted).frame(width: 110, alignment: .leading); Text(value).textSelection(.enabled); Spacer(minLength: 0) }.font(.system(size: 12))
    }
}

struct ProviderQuotaCard: View {
    let source: ProviderUsageConfiguration
    let state: ProviderUsageSourceState
    let refreshing: Bool
    var timeZone: TimeZone = .current
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WBCard(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: source.kind == .bandwagon ? "server.rack" : "globe").foregroundStyle(palette.accent)
                Text(source.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 60)) { tick in
                    Text(refreshing ? "更新中" : !source.enabled ? "已暂停" : state.status(at: tick.date, maximumAge: source.refreshPolicy.maximumInterval).title)
                        .font(.system(size: 10)).foregroundStyle(state.refresh.authenticationRequired || state.refresh.failureCount > 0 ? palette.warning : palette.muted)
                }
            }
            if let snapshot = state.snapshot {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(amount(snapshot.remaining, unit: snapshot.displayUnit)).font(.system(size: 28, weight: .regular)).monospacedDigit()
                    Text("GB 剩余").font(.system(size: 11)).foregroundStyle(palette.muted)
                    Spacer(minLength: 0)
                }.frame(height: 36)
                VStack(spacing: 7) {
                    WBProgress(value: min(1, max(0, snapshot.usedPercent / 100)), height: 5)
                    HStack {
                        Text(amount(snapshot.usedBytes, unit: snapshot.displayUnit) + " / " + amount(snapshot.limitBytes, unit: snapshot.displayUnit) + " GB")
                        Spacer(minLength: 4); Text(snapshot.usedPercent.formatted(.number.precision(.fractionLength(0...1))) + "%")
                    }.font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.secondary)
                }
                Text(resetText(snapshot)).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2).frame(minHeight: 28, alignment: .topLeading)
                Text("查询于 " + ProviderUsageFormatting.timestamp(snapshot.observedAt, timeZone: timeZone)).font(.system(size: 10)).foregroundStyle(palette.muted)
            } else {
                Text("—").font(.system(size: 28)).frame(height: 36)
                Text(source.kind == .iproyal ? "连接浏览器助手后验证真实额度" : "验证连接后显示真实额度")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary).frame(minHeight: 36, alignment: .topLeading)
                Text("尚无有效读数，不以零余额代替").font(.system(size: 11)).foregroundStyle(palette.muted).frame(minHeight: 28, alignment: .topLeading)
                Text(source.kind.title).font(.system(size: 10)).foregroundStyle(palette.muted)
            }
            if let message = state.message { Text(message).font(.system(size: 10)).foregroundStyle(palette.warning).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(palette.text)
    }
    private func amount(_ bytes: UInt64, unit: ProviderUsageDisplayUnit) -> String { (Double(bytes) / unit.divisor).formatted(.number.precision(.fractionLength(0...2))) }
    private func resetText(_ snapshot: ProviderUsageSnapshot) -> String {
        if let date = snapshot.resetsAt {
            return "重置 " + ProviderUsageFormatting.timestamp(date, timeZone: timeZone)
        }
        if let date = snapshot.resetDateText { return "重置 " + date + " · 服务商日期，时区待确认" }
        return "平台尚未提供重置时间"
    }
}

private struct ProviderUsageEditorView: View {
    @ObservedObject var editor: ProviderUsageEditor
    @ObservedObject var model: ProviderUsageModel
    @ObservedObject var presentation: ProviderUsagePresentation
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchDialogFrame(title: editor.existing ? "配置用量来源" : "添加用量来源", dismiss: presentation.requestCloseEditor) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("服务平台") { WBSelect("服务平台", selection: $editor.kind, options: ProviderUsageKind.allCases.map { (value: $0, title: $0.title) }).disabled(editor.existing) }
                    field("名称") { TextField("自定义显示名称", text: $editor.name).textFieldStyle(ProviderUsageFieldStyle()) }
                    field(editor.kind == .bandwagon ? "实例编号 VEID" : "静态 ISP 订单编号") {
                        TextField(editor.kind == .bandwagon ? "KiwiVM 中的 VEID" : "订单详情中的编号", text: $editor.resourceID).textFieldStyle(ProviderUsageFieldStyle())
                    }
                    if editor.kind == .bandwagon {
                        field("API Key") { SecureField(editor.existing ? "留空保留现有凭据" : "填写此实例的 API Key", text: $editor.secret).textFieldStyle(ProviderUsageFieldStyle()) }
                        Text("在 KiwiVM 的 API 页面获取。保存前先验证查询，凭据只存入本机钥匙串。").font(.system(size: 11)).foregroundStyle(palette.muted)
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
                    if let error = editor.error { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning).accessibilityIdentifier("fc.usage.editor.error") }
                }.padding(.vertical, 2)
            }.frame(maxHeight: 420).disabled(editor.saving)
        } actions: {
            if editor.saving { ProgressView().controlSize(.small); Text("正在验证连接").font(.system(size: 11)).foregroundStyle(palette.muted) }
            Spacer()
            Button("取消", action: presentation.requestCloseEditor).buttonStyle(WBButtonStyle()).disabled(editor.saving)
            Button(editor.kind == .bandwagon ? "验证并保存" : "保存来源") { save() }.buttonStyle(WBButtonStyle(primary: true)).disabled(editor.saving)
        }
        .onChange(of: editor.kind) { old, new in if editor.name == old.title { editor.name = new.title }; editor.secret = ""; editor.error = nil }
        .accessibilityIdentifier("fc.usage.editor")
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 12)); content() }
    }
    private func save() {
        guard !editor.saving else { return }
        let candidate: ProviderUsageConfiguration
        do { candidate = try editor.configuration() } catch { editor.error = error.localizedDescription; return }
        editor.saving = true; editor.error = nil
        Task { @MainActor in
            let success = await model.save(candidate, secret: editor.secret.isEmpty ? nil : editor.secret)
            editor.saving = false
            if success { editor.secret = ""; presentation.editor = nil; presentation.selectedSourceID = candidate.id }
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
                Text("浏览器关闭或会话失效时，自动查询会暂停。登录能保持多久取决于服务商；当前尚未完成此账号的连接与持续性验证。").font(.system(size: 11)).foregroundStyle(palette.muted)
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
