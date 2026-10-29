import AppKit
import SwiftUI
import LauncherCore

struct UsageConnectionManagerView: View {
    @ObservedObject var app: WorkbenchAppModel
    @ObservedObject var manager: UsageConnectionManager
    let onClose: () -> Void
    @ObservedObject private var appearance: UsagePresentationModel
    @ObservedObject private var traffic: ProviderUsageModel
    @ObservedObject private var ai: AIUsageModel
    @ObservedObject private var api: APIBalanceModel
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchContentHeight) private var availableHeight
    @State private var availableWidth: CGFloat = 840
    @State private var categoryEditor: UsageCategoryEditor?
    @State private var categoryDiscard = false
    @State private var showingBrowserGuide = false
    @State private var browserGuideMessage: String?

    init(app: WorkbenchAppModel, manager: UsageConnectionManager, onClose: @escaping () -> Void) {
        self.app = app; self.manager = manager; self.onClose = onClose
        appearance = app.usageAppearance; traffic = app.providerUsage; ai = app.ai; api = app.apiBalance
    }
    private var entries: [UsageManagedConnection] { manager.connections(app: app) }
    private var bodyHeight: CGFloat { availableHeight > 0 ? min(500, max(260, availableHeight - 132)) : 500 }
    private var connectionError: String? {
        if let error = manager.error ?? appearance.storageError { return error }
        if manager.draft.service == .deepseek { return api.storageError }
        if manager.draft.service?.trafficKind != nil { return traffic.storageError }
        if manager.draft.service?.aiProvider != nil { return ai.storageReadErrors["sources.json"] }
        return nil
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.line).frame(height: 1)
            if availableWidth >= 650 {
                HStack(spacing: 0) {
                    connectionList.frame(width: 194)
                    Rectangle().fill(palette.line).frame(width: 1)
                    formBody
                }.frame(height: bodyHeight)
            } else {
                VStack(spacing: 0) {
                    compactConnections.padding(14)
                    Rectangle().fill(palette.line).frame(height: 1)
                    formBody
                }.frame(height: bodyHeight)
            }
            Rectangle().fill(palette.line).frame(height: 1)
            footer
        }
        .foregroundStyle(palette.text)
        .background(GeometryReader { proxy in Color.clear.onAppear { availableWidth = proxy.size.width }.onChange(of: proxy.size.width) { _, width in availableWidth = width } })
        .onAppear { manager.prepare(app: app) }
        .onChange(of: appearance.preferences.categories) { _, categories in manager.reconcileCategories(categories) }
        .workbenchModal(isPresented: $manager.confirmingDiscard, width: 430, onRequestDismiss: manager.keepEditing) {
            WorkbenchDialogFrame(title: manager.discardTitle, dismiss: manager.keepEditing) {
                Text(manager.discardDetail).font(.system(size: 12)).foregroundStyle(palette.secondary)
            } actions: {
                Spacer()
                Button("继续编辑", action: manager.keepEditing).buttonStyle(WBButtonStyle())
                Button("放弃修改", action: manager.discardChanges).buttonStyle(WBButtonStyle(destructive: true))
                    .accessibilityIdentifier("fc.usage.manager.discard")
            }
        }
        .workbenchModal(item: $categoryEditor, width: 500, onRequestDismiss: closeCategories) { editor in
            UsageCategoryEditorView(editor: editor, presentation: app.usagePresentation, appearance: appearance, onClose: closeCategories, onSaved: { categoryEditor = nil })
        }
        .workbenchModal(isPresented: $categoryDiscard, width: 420) {
            WorkbenchDialogFrame(title: "放弃分类修改？", dismiss: { categoryDiscard = false }) {
                Text("分类修改尚未保存，连接表单会继续保留。").font(.system(size: 12))
            } actions: {
                Spacer(); Button("继续编辑") { categoryDiscard = false }.buttonStyle(WBButtonStyle())
                Button("放弃修改") { categoryDiscard = false; categoryEditor = nil }.buttonStyle(WBButtonStyle(destructive: true))
            }
        }
        .workbenchModal(isPresented: $showingBrowserGuide, width: 560) {
            browserGuide
        }
        .accessibilityElement(children: .contain).accessibilityLabel("配置用量")
        .accessibilityIdentifier("fc.usage.manager")
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("配置用量").font(.system(size: 15, weight: .medium))
                Text("管理连接与卡片显示").font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            Spacer()
            Button { manager.requestClose(onClose) } label: { Image(systemName: "xmark") }
                .buttonStyle(WBIconButtonStyle(size: 32)).disabled(manager.busy)
                .accessibilityLabel("关闭配置用量").accessibilityIdentifier("fc.usage.manager.close")
        }.padding(18)
    }
    private var connectionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("我的连接"); Spacer(); Text("\(entries.count)").monospacedDigit() }
                .font(.system(size: 11)).foregroundStyle(palette.secondary).padding(18)
            WorkbenchScrollView {
                VStack(spacing: 4) { ForEach(entries) { entry in connectionRow(entry) } }.padding(.horizontal, 10)
            }
            Button(action: manager.add) { Label("新增连接", systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(WBButtonStyle()).padding(10).disabled(manager.busy)
                .accessibilityIdentifier("fc.usage.manager.new")
        }
    }
    private func connectionRow(_ entry: UsageManagedConnection) -> some View {
        Button { manager.select(entry.id, app: app) } label: {
            HStack(spacing: 10) {
                UsageSourceIcon(appearance: appearance, icon: entry.appearance.icon, aiProvider: entry.service.aiProvider,
                                serviceKind: entry.service.trafficKind, defaultBrand: entry.service == .deepseek ? .deepseek : nil, size: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.name).font(.system(size: 12)).lineLimit(1)
                    Text(entry.detail).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Circle().fill(entry.connected ? palette.accent : palette.muted).frame(width: 4, height: 4)
            }.padding(.horizontal, 10).padding(.vertical, 12)
                .background { if manager.selectedSourceID == entry.id { WorkbenchMaterialSurface(kind: .control, radius: 8) } }
                .contentShape(Rectangle())
        }.buttonStyle(ClickablePlainButtonStyle()).disabled(manager.busy)
            .accessibilityLabel(entry.name + "，" + entry.detail)
            .accessibilityAddTraits(manager.selectedSourceID == entry.id ? [.isSelected] : [])
            .accessibilityIdentifier("fc.usage.manager.source." + entry.id)
    }
    private var compactConnections: some View {
        HStack(spacing: 10) {
            WBSelect("选择已有连接", selection: Binding(get: { manager.selectedSourceID }, set: { if let id = $0 { manager.select(id, app: app) } }),
                     options: entries.map { (Optional($0.id), $0.name) })
            Button(action: manager.add) { Label("新增", systemImage: "plus") }.buttonStyle(WBButtonStyle())
                .accessibilityIdentifier("fc.usage.manager.new")
        }.disabled(manager.busy)
    }
    private var formBody: some View {
        WorkbenchScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(manager.isNew ? "新增连接" : "编辑连接").font(.system(size: 15, weight: .medium))
                identityFields
                separator
                field("连接服务") {
                    WBSelect("选择连接服务", selection: Binding(get: { manager.draft.service }, set: { manager.selectService($0) }),
                             options: UsageConnectionService.allCases.map { (Optional($0), $0.title) })
                        .disabled(!manager.isNew).accessibilityIdentifier("fc.usage.manager.service")
                }
                connectionFields
                separator
                refreshFields
                if let error = connectionError {
                    Text(error).font(.system(size: 11)).foregroundStyle(palette.warning).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fc.usage.manager.error")
                }
                if let notice = manager.notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fc.usage.manager.notice")
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).disabled(manager.busy)
        }
    }
    private var identityFields: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) { nameField.frame(minWidth: 240); categoryField.frame(minWidth: 190) }
            VStack(alignment: .leading, spacing: 16) { nameField; categoryField }
        }
    }
    private var nameField: some View {
        field("名称与图标") {
            HStack(spacing: 8) {
                UsageIconPicker(selection: $manager.draft.appearance.icon, appearance: appearance,
                                aiProvider: manager.draft.service?.aiProvider, serviceKind: manager.draft.service?.trafficKind,
                                defaultBrand: manager.draft.service == .deepseek ? .deepseek : nil, compact: true)
                    .accessibilityIdentifier("fc.usage.manager.icon")
                TextField("为这张卡片起个名字", text: $manager.draft.name).textFieldStyle(UsageFieldStyle())
                    .accessibilityLabel("卡片名称").accessibilityIdentifier("fc.usage.manager.name")
            }
        }
    }
    private var categoryField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("分类").font(.system(size: 12)); Spacer(minLength: 8)
                Button("管理分类") { categoryEditor = .init(appearance.preferences.categories) }
                    .buttonStyle(WBQuietButtonStyle()).font(.system(size: 11))
                    .accessibilityIdentifier("fc.usage.manager.categories")
            }
            WBSelect("分类", selection: Binding(get: { manager.draft.appearance.categoryID ?? "uncategorized" }, set: { manager.draft.appearance.categoryID = $0 }),
                     options: appearance.preferences.categories.map { ($0.id, $0.title) })
                .accessibilityIdentifier("fc.usage.manager.category")
        }
    }
    @ViewBuilder private var connectionFields: some View {
        if let existing = manager.existingSubscriptionID {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("此本机订阅已有连接").font(.system(size: 12))
                    Text("可直接编辑已有连接，保留原来的名称、分类和图标。").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
                Button("编辑已有连接") { manager.select(existing, app: app) }.buttonStyle(WBButtonStyle())
                    .accessibilityIdentifier("fc.usage.manager.edit-existing")
            }
        } else if let provider = manager.draft.service?.aiProvider {
            subscriptionFields(provider)
        } else if manager.draft.service == .iproyal {
            iproyalFields
        } else if manager.draft.service == .bandwagon {
            bandwagonFields
        } else if manager.draft.service == .deepseek {
            field("API Key") {
                SecureField(manager.isNew ? "填写 DeepSeek API Key" : "留空保留现有 Key", text: $manager.draft.secret)
                    .textFieldStyle(UsageFieldStyle()).accessibilityIdentifier("fc.usage.manager.secret")
            }
            Text("验证后读取 DeepSeek 官方余额，密钥仅保存在本机钥匙串。").font(.system(size: 11)).foregroundStyle(palette.secondary)
        } else {
            Label("选择服务后，显示相应的连接信息", systemImage: "powerplug")
                .font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.vertical, 10)
        }
    }
    private func subscriptionFields(_ provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider == .codex ? "读取本机 Codex 订阅" : "连接本机 Claude Code").font(.system(size: 12))
                    Text(subscriptionStatus(provider)).font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(ai.isRefreshing ? "正在读取" : "读取本机来源") { manager.connectSubscription(app: app) }
                    .buttonStyle(WBButtonStyle()).disabled(ai.isRefreshing).accessibilityIdentifier("fc.usage.manager.connect-subscription")
            }
            if provider == .claude {
                HStack(spacing: 12) {
                    Text("订阅额度通过 Claude Code 官方状态栏同步。").font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Spacer(minLength: 0)
                    Button("启用额度同步") { manager.enableClaudeSync(app: app) }.buttonStyle(WBButtonStyle())
                        .accessibilityIdentifier("fc.usage.manager.claude-sync")
                }
            }
            field("会员计划") {
                WBSelect("会员计划", selection: $manager.draft.declaredPlan, options: planOptions(provider))
                    .accessibilityIdentifier("fc.usage.manager.plan")
            }
            Text("优先显示来源提供的会员信息；手动设置只改变名称，不改变额度。").font(.system(size: 11)).foregroundStyle(palette.muted)
        }
    }
    private func subscriptionStatus(_ provider: AIProvider) -> String {
        if ai.isRefreshing { return "正在读取本机用量元数据…" }
        if !ai.configuration(for: provider).enabled { return "自动读取已暂停，已有记录保留。" }
        if let summary = ai.providerSummaries.first(where: { $0.provider == provider }), summary.snapshot != nil { return summary.state.title + " · " + summary.accountPlanDescription }
        if ai.coverage[provider]?.sourceAvailable == true { return "本机来源可读取，暂未提供有效额度。" }
        return "尚无可用读数，请确认已登录并使用过本机客户端。"
    }
    private var iproyalFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("通过 Chrome 连接器读取订单").font(.system(size: 11)).foregroundStyle(palette.secondary); Spacer(); Button("连接指南") { showingBrowserGuide = true }.buttonStyle(WBQuietButtonStyle()) }
            field("静态 ISP 订单编号") {
                HStack(spacing: 10) {
                    TextField("订单详情中的编号", text: $manager.draft.resourceID).textFieldStyle(UsageFieldStyle())
                        .accessibilityIdentifier("fc.usage.manager.resource")
                    Button("检测连接") { manager.checkBrowser(app: app) }.buttonStyle(WBButtonStyle())
                        .accessibilityIdentifier("fc.usage.manager.browser-check")
                }
            }
            HStack { Text("更换订单后重新读取额度。").font(.system(size: 11)).foregroundStyle(palette.muted); Spacer(); Button("读取订单") { manager.verifyOrder(app: app) }.buttonStyle(WBButtonStyle()).accessibilityIdentifier("fc.usage.manager.read-order") }
        }
    }
    private var bandwagonFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("实例编号 · VEID") {
                TextField("KiwiVM 中的 VEID", text: $manager.draft.resourceID).textFieldStyle(UsageFieldStyle()).accessibilityIdentifier("fc.usage.manager.resource")
            }
            field("API Key") {
                SecureField(manager.canKeepTrafficCredential ? "留空保留现有 Key" : "填写此实例的 API Key", text: $manager.draft.secret)
                    .textFieldStyle(UsageFieldStyle()).accessibilityIdentifier("fc.usage.manager.secret")
            }
            HStack(alignment: .top, spacing: 12) {
                Text("在 KiwiVM → API → Show API Key 获取此实例信息，验证后保存在本机钥匙串。").font(.system(size: 11)).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                Button("打开服务") { NSWorkspace.shared.open(URL(string: "https://bandwagonhost.com/services")!) }.buttonStyle(WBButtonStyle(compact: true))
            }
        }
    }
    private var refreshFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 16) {
                field("刷新频率") {
                    if manager.draft.service?.trafficKind != nil {
                        WBSelect("刷新频率", selection: Binding(get: { refreshSelection }, set: selectRefresh), options: [
                            ("smart", "智能更新 · 1–6 小时"), ("1", "每 1 小时"), ("6", "每 6 小时"), ("24", "每 24 小时"), ("custom", "自定义间隔"), ("manual", "仅手动刷新")
                        ]).accessibilityIdentifier("fc.usage.manager.frequency")
                    } else {
                        Text(manager.draft.service == .deepseek ? "自动检查 · 每 30 分钟" : manager.draft.service?.aiProvider != nil ? "自动读取 · 每分钟" : "选择服务后显示")
                            .font(.system(size: 12)).foregroundStyle(palette.secondary).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    }
                }
                Toggle("在列表中显示", isOn: $manager.draft.appearance.visible).toggleStyle(.checkbox).font(.system(size: 11))
                    .fixedSize().padding(.bottom, 8).accessibilityIdentifier("fc.usage.manager.visible")
            }
            if manager.draft.service?.trafficKind != nil, refreshSelection == "custom" || refreshSelection == "smart" {
                HStack(spacing: 10) {
                    field("累计阈值 · MB") { TextField("1000", text: $manager.draft.thresholdMB).textFieldStyle(UsageFieldStyle()) }
                    field("最短间隔 · 小时") { TextField("1", text: $manager.draft.minimumHours).textFieldStyle(UsageFieldStyle()) }
                    field("最长间隔 · 小时") { TextField("6", text: $manager.draft.maximumHours).textFieldStyle(UsageFieldStyle()) }
                }
                Text("达到累计流量阈值且经过最短间隔，或到达最长间隔时更新。").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }
    }
    private var refreshSelection: String {
        if !manager.draft.enabled { return "manual" }
        if manager.draft.minimumHours == "1", manager.draft.maximumHours == "6" { return "smart" }
        if manager.draft.minimumHours == manager.draft.maximumHours, ["1", "6", "24"].contains(manager.draft.minimumHours) { return manager.draft.minimumHours }
        return "custom"
    }
    private func selectRefresh(_ value: String) {
        manager.draft.enabled = value != "manual"
        if value == "smart" { manager.draft.minimumHours = "1"; manager.draft.maximumHours = "6" }
        else if ["1", "6", "24"].contains(value) { manager.draft.minimumHours = value; manager.draft.maximumHours = value }
        else if value == "custom", refreshSelection != "custom" { manager.draft.minimumHours = "1"; manager.draft.maximumHours = "12" }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            if manager.busy { ProgressView().controlSize(.small) }
            Text(manager.busy ? "正在验证或保存连接" : manager.hasChanges ? "有未保存的修改" : "设置保存后应用到卡片列表")
                .font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button("取消") { manager.requestClose(onClose) }.buttonStyle(WBButtonStyle()).disabled(manager.busy)
            Button(manager.primaryTitle) { manager.save(app: app) }.buttonStyle(WBButtonStyle(primary: true))
                .disabled(manager.busy || manager.draft.service == nil || manager.existingSubscriptionID != nil || manager.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appearance.storageError != nil)
                .accessibilityIdentifier("fc.usage.manager.save")
        }.padding(.horizontal, 22).padding(.vertical, 13)
    }
    private var separator: some View { Rectangle().fill(palette.line).frame(height: 1) }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 12)); content() }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func planOptions(_ provider: AIProvider) -> [(value: AIAccountPlan?, title: String)] {
        let plans: [AIAccountPlan] = provider == .codex ? [.free, .go, .plus, .prolite, .pro, .promax, .business, .enterprise, .edu] : [.pro, .max, .team, .enterprise]
        return [(nil, "由来源提供")] + plans.map { (Optional($0), $0.title + "（用户设置）") }
    }
    private func closeCategories() {
        if categoryEditor?.hasChanges == true { categoryDiscard = true } else { categoryEditor = nil }
    }
    private var browserGuide: some View {
        WorkbenchDialogFrame(title: "连接 IPRoyal", dismiss: { showingBrowserGuide = false }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("安装并启用 Chrome 网页助手，在浏览器登录 IPRoyal，打开静态 ISP 订单详情。")
                Text("将订单编号填入表单，检测连接后点击读取订单。已有登录会话留在 Chrome 中，无需提供密码。")
                if let message = browserGuideMessage { Text(message).foregroundStyle(palette.secondary) }
            }.font(.system(size: 12))
        } actions: {
            Button("安装本机连接") { browserGuideMessage = app.installProviderBrowserHost() }.buttonStyle(WBButtonStyle())
            Button("导出连接器") { app.exportProviderBrowserKit { browserGuideMessage = $0 } }.buttonStyle(WBButtonStyle())
            Spacer(); Button("完成") { showingBrowserGuide = false }.buttonStyle(WBButtonStyle(primary: true))
        }
    }
}
