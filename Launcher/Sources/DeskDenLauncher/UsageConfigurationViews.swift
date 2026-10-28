import AppKit
import SwiftUI
import LauncherCore

enum UsageConnectionKind: String, CaseIterable {
    case subscription, traffic, api
    var title: String { switch self { case .subscription: "AI 订阅额度"; case .traffic: "服务流量"; case .api: "API 余额" } }
    var description: String { switch self { case .subscription: "Codex、Claude 的订阅额度与窗口"; case .traffic: "IPRoyal 订单与搬瓦工 VPS 的流量额度"; case .api: "DeepSeek API 的货币余额" } }
}
@MainActor final class UsageCategoryEditor: ObservableObject, Identifiable {
    let id = UUID()
    let original: [UsageCardCategory]
    @Published var categories: [UsageCardCategory]
    init(_ categories: [UsageCardCategory]) { original = categories; self.categories = categories }
    var hasChanges: Bool { original != categories }
}
@MainActor final class UsageAPIBalanceEditor: ObservableObject, Identifiable {
    let id = UUID()
    let original: APIBalanceConfiguration?
    let originalAppearance: UsageCardAppearance
    @Published var name: String
    @Published var secret = ""
    @Published var display: UsageCardAppearance
    @Published var saving = false
    @Published var error: String?
    @Published var savedSourceID: UUID?
    init(source: APIBalanceConfiguration? = nil, appearance: UsageCardAppearance = .init()) {
        original = source; originalAppearance = appearance; display = appearance; name = source?.name ?? "DeepSeek"
    }
    var hasChanges: Bool { savedSourceID != nil || !secret.isEmpty || name != (original?.name ?? "DeepSeek") || display != originalAppearance }
}

@MainActor final class UsageAIEditor: ObservableObject, Identifiable {
    let id = UUID()
    let provider: AIProvider
    let original: UsageCardAppearance
    let originalPlan: AIAccountPlan?
    @Published var declaredPlan: AIAccountPlan?
    @Published var name: String
    @Published var display: UsageCardAppearance
    init(provider: AIProvider, appearance: UsageCardAppearance, declaredPlan: AIAccountPlan? = nil) {
        self.provider = provider; original = appearance; display = appearance
        originalPlan = declaredPlan; self.declaredPlan = declaredPlan
        name = appearance.displayName ?? provider.title
    }
    var hasChanges: Bool { name != (original.displayName ?? provider.title) || display != original || declaredPlan != originalPlan }
}

struct UsageConfigurationView: View {
    @ObservedObject var app: WorkbenchAppModel
    @ObservedObject var model: ProviderUsageModel
    @ObservedObject var ai: AIUsageModel
    @ObservedObject var presentation: ProviderUsagePresentation
    @ObservedObject var appearance: UsagePresentationModel
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchDialogFrame(title: "配置用量", dismiss: { presentation.showingConfiguration = false }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text("连接类型").font(.system(size: 12)).fixedSize()
                    WBSelect("连接类型", selection: $presentation.configurationKind, options: UsageConnectionKind.allCases.map { ($0, $0.title) })
                        .accessibilityIdentifier("fc.usage.config.kind")
                    Button("管理分类") { presentation.showingConfiguration = false; presentation.categoryEditor = .init(appearance.preferences.categories) }
                        .buttonStyle(WBButtonStyle()).accessibilityIdentifier("fc.usage.config.categories")
                }
                Text(presentation.configurationKind.description).font(.system(size: 11)).foregroundStyle(palette.muted)
                VStack(alignment: .leading, spacing: 0) {
                    switch presentation.configurationKind {
                    case .subscription: ForEach(AIProvider.allCases) { aiRow($0) }
                    case .traffic:
                        if model.sources.isEmpty { empty("尚无流量来源", detail: "添加 IPRoyal 订单或搬瓦工 VPS，各自保留流量额度与周期。") }
                        ForEach(model.sources) { serviceRow($0) }
                    case .api:
                        if app.apiBalance.sources.isEmpty { empty("连接 DeepSeek API", detail: "验证 Key 后显示余额；不同币种独立展示，不与流量额度混算。") }
                        ForEach(app.apiBalance.sources) { source in
                            row(name: source.name, detail: "DeepSeek · " + appearance.categoryTitle(for: UsagePresentationSourceID.api(source.id), defaultID: "api-balance"), symbol: "creditcard") {
                                presentation.showingConfiguration = false
                                presentation.apiEditor = .init(source: source, appearance: appearance.appearance(for: UsagePresentationSourceID.api(source.id)))
                            }
                        }
                    }
                }
                if let error = appearance.errorMessage ?? appearance.storageError { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning) }
            }
        } actions: {
            Spacer()
            Button("完成") { presentation.showingConfiguration = false }.buttonStyle(WBButtonStyle())
            switch presentation.configurationKind {
            case .subscription:
                Button("连接订阅来源") { presentation.showingConfiguration = false; presentation.selectedSourceID = nil; ai.openSources() }
                    .buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("fc.usage.config.add-ai")
            case .traffic:
                Button("添加流量来源") { presentation.add(.iproyal) }.buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("fc.usage.config.add-service")
            case .api:
                Button("添加 API 连接") { presentation.showingConfiguration = false; presentation.apiEditor = .init() }
                    .buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("fc.usage.config.add-api")
            }
        }.accessibilityIdentifier("fc.usage.configuration")
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 13, weight: .medium)); Text(detail).font(.system(size: 12)).foregroundStyle(palette.secondary) }.padding(.vertical, 18)
    }
    private func row(name: String, detail: String, symbol: String, edit: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(palette.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) { Text(name).font(.system(size: 13, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(palette.muted) }
            Spacer(minLength: 8); Button("编辑", action: edit).buttonStyle(WBButtonStyle(compact: true))
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
    private func aiRow(_ provider: AIProvider) -> some View {
        let display = appearance.appearance(for: UsagePresentationSourceID.ai(provider))
        return row(name: display.displayName ?? provider.title,
            detail: appearance.categoryTitle(for: UsagePresentationSourceID.ai(provider), defaultID: "ai-subscription") + " · " + (display.visible ? "概览显示" : "已隐藏"), symbol: "sparkles") {
            presentation.editAI(provider, appearance: display, declaredPlan: ai.configuration(for: provider).declaredPlan)
        }.accessibilityIdentifier("fc.usage.config.edit-ai." + provider.rawValue)
    }
    private func serviceRow(_ source: ProviderUsageConfiguration) -> some View {
        let display = appearance.appearance(for: UsagePresentationSourceID.service(source.id))
        return row(name: display.displayName ?? source.name, detail: source.kind.title + " · " + appearance.categoryTitle(for: UsagePresentationSourceID.service(source.id), defaultID: source.kind == .iproyal ? "static-isp" : "vps-traffic"), symbol: source.kind == .iproyal ? "globe" : "server.rack") {
            presentation.edit(source, appearance: display)
        }.accessibilityIdentifier("fc.usage.config.edit-service." + source.id.uuidString)
    }
}

struct UsageAIEditorView: View {
    @ObservedObject var ai: AIUsageModel
    @ObservedObject var editor: UsageAIEditor
    @ObservedObject var presentation: ProviderUsagePresentation
    @ObservedObject var appearance: UsagePresentationModel
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchDialogFrame(title: "编辑 AI 卡片", dismiss: presentation.requestCloseAIEditor) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("卡片名称").font(.system(size: 12))
                    TextField(editor.provider.title, text: $editor.name).textFieldStyle(UsageFieldStyle())
                }
                UsageCategoryPicker(selection: $editor.display.categoryID, defaultID: "ai-subscription", appearance: appearance)
                VStack(alignment: .leading, spacing: 6) {
                    Text("会员计划").font(.system(size: 12))
                    WBSelect("会员计划", selection: $editor.declaredPlan, options: planOptions)
                    Text("优先使用来源提供的信息；手动选择只用于展示，不改变额度读数。").font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                UsageIconPicker(selection: $editor.display.icon, appearance: appearance, aiProvider: editor.provider)
                Toggle("在概览中显示", isOn: $editor.display.visible).toggleStyle(.switch).controlSize(.small)
                HStack(spacing: 10) {
                    UsageSourceIcon(appearance: appearance, icon: editor.display.icon, aiProvider: editor.provider)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(editor.name.isEmpty ? editor.provider.title : editor.name).font(.system(size: 13, weight: .medium))
                        Text("AI 用量 · " + editor.provider.title).font(.system(size: 11)).foregroundStyle(palette.muted)
                    }
                    Spacer()
                }.padding(12).background(WorkbenchMaterialSurface(kind: .control, radius: 8))
                if let error = appearance.errorMessage ?? ai.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning) }
            }
        } actions: {
            Spacer()
            Button("取消", action: presentation.requestCloseAIEditor).buttonStyle(WBButtonStyle())
            Button("保存") {
                var value = editor.display; value.displayName = editor.name
                do {
                    var candidate = appearance.preferences; candidate.cards[UsagePresentationSourceID.ai(editor.provider)] = value
                    try candidate.validate()
                } catch { appearance.errorMessage = error.localizedDescription; return }
                let previous = ai.configuration(for: editor.provider).declaredPlan
                guard ai.setDeclaredPlan(editor.declaredPlan, provider: editor.provider) else { return }
                if appearance.saveAppearance(value, for: UsagePresentationSourceID.ai(editor.provider)) { presentation.aiEditor = nil }
                else { _ = ai.setDeclaredPlan(previous, provider: editor.provider) }
            }.buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("fc.usage.ai-editor.save")
        }.accessibilityIdentifier("fc.usage.ai-editor")
    }
    private var planOptions: [(value: AIAccountPlan?, title: String)] {
        let plans: [AIAccountPlan] = editor.provider == .codex ? [.free, .go, .plus, .prolite, .pro, .promax, .business, .enterprise, .edu] : [.pro, .max, .team, .enterprise]
        return [(nil, "由来源提供")] + plans.map { (Optional($0), $0.title + "（用户设置）") }
    }
}

struct UsageIconPicker: View {
    @Binding var selection: UsageCardIcon
    @ObservedObject var appearance: UsagePresentationModel
    var aiProvider: AIProvider?
    var serviceKind: ProviderUsageKind?
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("卡片图标").font(.system(size: 12))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 40), spacing: 8)], alignment: .leading, spacing: 8) {
                iconButton(.automatic, label: "使用服务默认图标") {
                    UsageSourceIcon(appearance: appearance, icon: .automatic, aiProvider: aiProvider, serviceKind: serviceKind, size: 24)
                }
                ForEach(UsageCardIcon.presetSymbols, id: \.self) { symbol in
                    iconButton(.symbol(symbol), label: "使用 " + symbol + " 图标") {
                        Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(palette.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                Button { appearance.chooseImage { selection = $0 } } label: { Label("选择本地图片", systemImage: "photo") }
                    .buttonStyle(WBButtonStyle(compact: true)).accessibilityIdentifier("fc.usage.icon.choose")
                if case .image = selection {
                    UsageSourceIcon(appearance: appearance, icon: selection, aiProvider: aiProvider, serviceKind: serviceKind, size: 24)
                    Text("已选择自定义图片").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
            }
            Text("PNG、JPEG 或 WebP · 图标仅用于显示").font(.system(size: 11)).foregroundStyle(palette.muted)
        }
    }
    private func iconButton<Content: View>(_ value: UsageCardIcon, label: String, @ViewBuilder content: () -> Content) -> some View {
        Button { selection = value } label: {
            content().frame(width: 40, height: 40)
                .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(selection == value ? palette.accent : Color.clear, lineWidth: 1) }
        }.buttonStyle(ClickablePlainButtonStyle()).accessibilityLabel(label)
            .accessibilityAddTraits(selection == value ? [.isSelected] : [])
    }
}

struct UsageFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 12)).padding(.horizontal, 10).frame(height: 32)
            .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
    }
}

struct UsageCategoryPicker: View {
    @Binding var selection: String?
    let defaultID: String
    @ObservedObject var appearance: UsagePresentationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("分类").font(.system(size: 12))
            WBSelect("卡片分类", selection: Binding(get: {
                let id = selection ?? defaultID
                return appearance.preferences.categories.contains { $0.id == id } ? id : "uncategorized"
            }, set: { selection = $0 }), options: appearance.preferences.categories.map { ($0.id, $0.title) })
        }
    }
}
struct UsageCategoryEditorView: View {
    @ObservedObject var editor: UsageCategoryEditor
    @ObservedObject var presentation: ProviderUsagePresentation
    @ObservedObject var appearance: UsagePresentationModel
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchDialogFrame(title: "管理分类", dismiss: presentation.requestCloseCategoryEditor) {
            VStack(alignment: .leading, spacing: 12) {
                Text("分类只整理卡片，不改变连接、计量方式或凭据。删除分类后，卡片归入未分类。").font(.system(size: 11)).foregroundStyle(palette.secondary)
                ForEach($editor.categories) { $category in
                    HStack(spacing: 10) {
                        TextField("分类名称", text: $category.title).textFieldStyle(UsageFieldStyle())
                        if category.id != "uncategorized" {
                            Button { editor.categories.removeAll { $0.id == category.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(WBIconButtonStyle(size: 28)).accessibilityLabel("删除" + category.title)
                        } else { Color.clear.frame(width: 28, height: 28) }
                    }
                }
                Button("添加分类") { editor.categories.append(.init(title: "新分类")) }.buttonStyle(WBButtonStyle(compact: true)).disabled(editor.categories.count >= 40)
                    .accessibilityIdentifier("fc.usage.category.add")
                if let error = appearance.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning) }
            }
        } actions: {
            Spacer(); Button("取消", action: presentation.requestCloseCategoryEditor).buttonStyle(WBButtonStyle())
            Button("保存分类") { if appearance.replaceCategories(editor.categories) { presentation.categoryEditor = nil } }
                .buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("fc.usage.category.save")
        }.accessibilityIdentifier("fc.usage.category.editor")
    }
}
struct UsageAPIBalanceEditorView: View {
    @ObservedObject var editor: UsageAPIBalanceEditor
    @ObservedObject var model: APIBalanceModel
    @ObservedObject var presentation: ProviderUsagePresentation
    @ObservedObject var appearance: UsagePresentationModel
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchDialogFrame(title: editor.original == nil ? "连接 DeepSeek API" : "编辑 DeepSeek API", dismiss: presentation.requestCloseAPIEditor) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) { Text("卡片名称").font(.system(size: 12)); TextField("DeepSeek", text: $editor.name).textFieldStyle(UsageFieldStyle()) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key").font(.system(size: 12))
                    SecureField(editor.original == nil ? "填写 DeepSeek API Key" : "留空保留现有 Key", text: $editor.secret).textFieldStyle(UsageFieldStyle()).accessibilityIdentifier("fc.usage.api.secret")
                    Text("仅调用 DeepSeek 官方余额接口；Key 保存在本机钥匙串，不写入卡片设置或日志。").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                UsageCategoryPicker(selection: $editor.display.categoryID, defaultID: "api-balance", appearance: appearance)
                UsageIconPicker(selection: $editor.display.icon, appearance: appearance)
                Toggle("在概览中显示", isOn: $editor.display.visible).toggleStyle(.switch).controlSize(.small)
                if let error = editor.error ?? model.storageError ?? appearance.storageError { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning) }
            }
        } actions: {
            if editor.saving { ProgressView().controlSize(.small) }
            Spacer(); Button("取消", action: presentation.requestCloseAPIEditor).buttonStyle(WBButtonStyle()).disabled(editor.saving)
            Button(editor.saving ? "正在验证" : editor.original == nil || !editor.secret.isEmpty ? "验证并保存" : "保存修改") {
                guard !editor.saving else { return }; editor.saving = true; editor.error = nil
                Task { @MainActor in
                    do {
                        var candidate = appearance.preferences
                        candidate.cards[UsagePresentationSourceID.api(editor.original?.id ?? editor.savedSourceID ?? UUID())] = editor.display
                        try candidate.validate()
                        let source = try await model.validateAndSave(name: editor.name, key: editor.secret, editingID: editor.original?.id ?? editor.savedSourceID)
                        editor.savedSourceID = source.id
                        if appearance.saveAppearance(editor.display, for: UsagePresentationSourceID.api(source.id)) {
                            editor.secret = ""; presentation.apiEditor = nil
                        } else { editor.error = "连接已保存，卡片显示设置尚未保存；可在此重试。" }
                    } catch { editor.error = error.localizedDescription }
                    editor.saving = false
                }
            }.buttonStyle(WBButtonStyle(primary: true)).disabled(editor.saving || model.storageError != nil || appearance.storageError != nil)
                .accessibilityIdentifier("fc.usage.api.save")
        }.accessibilityIdentifier("fc.usage.api.editor")
    }
}

struct UsageAPIBalanceCard: View {
    let source: APIBalanceConfiguration
    let state: APIBalanceSourceState
    let refreshing: Bool
    let display: UsageCardAppearance
    @ObservedObject var appearance: UsagePresentationModel
    let timeZone: TimeZone
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                UsageSourceIcon(appearance: appearance, icon: display.icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(display.displayName ?? source.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("DeepSeek API").font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                Spacer(minLength: 3)
                Circle().fill(state.message != nil ? palette.warning : state.snapshot != nil && !state.isStale() ? palette.accent : palette.muted).frame(width: 5, height: 5)
            }
            if let snapshot = state.snapshot {
                ForEach(snapshot.balances) { balance in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("可用余额 · " + balance.currency).font(.system(size: 11)).foregroundStyle(palette.secondary)
                        Text(balance.totalBalance).font(.system(size: snapshot.balances.count > 1 ? 21 : 29, weight: .medium)).monospacedDigit().lineLimit(1)
                    }
                }
                if !snapshot.isAvailable { Text("当前余额不足或不可用").font(.system(size: 11)).foregroundStyle(palette.warning) }
            } else {
                Label("等待验证余额", systemImage: "creditcard").font(.system(size: 13)).foregroundStyle(palette.secondary)
                Text("连接后显示官方余额，不推算消费或汇率。").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(refreshing ? "正在更新" : state.message != nil ? "更新失败 · 保留读数" : state.snapshot.map { "更新于 " + ProviderUsageFormatting.time($0.observedAt, timeZone: timeZone) } ?? "尚无有效读数").lineLimit(1)
                Spacer(minLength: 0); Image(systemName: "arrow.up.right").font(.system(size: 11)).accessibilityHidden(true)
            }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 8).overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        }.foregroundStyle(palette.text).padding(14).frame(maxWidth: .infinity).frame(height: UsageCardGrid.cardSize.height, alignment: .topLeading)
            .background(WorkbenchMaterialSurface(radius: 15)).contentShape(RoundedRectangle(cornerRadius: 15))
    }
}
