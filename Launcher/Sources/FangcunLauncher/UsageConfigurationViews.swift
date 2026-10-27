import AppKit
import SwiftUI
import LauncherCore

@MainActor final class UsageAIEditor: ObservableObject, Identifiable {
    let id = UUID()
    let provider: AIProvider
    let original: UsageCardAppearance
    @Published var name: String
    @Published var display: UsageCardAppearance
    init(provider: AIProvider, appearance: UsageCardAppearance) {
        self.provider = provider; original = appearance; display = appearance
        name = appearance.displayName ?? provider.title
    }
    var hasChanges: Bool { name != (original.displayName ?? provider.title) || display != original }
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
                HStack(spacing: 20) {
                    category(.ai, title: "AI 用量")
                    category(.service, title: "服务流量")
                    Spacer(minLength: 0)
                }.overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
                WorkbenchScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if presentation.configurationGroup == .ai {
                            ForEach(AIProvider.allCases) { provider in aiRow(provider) }
                        } else if model.sources.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("添加独立订单或服务器").font(.system(size: 13, weight: .medium))
                                Text("每个来源保留自己的额度、更新设置与重置周期。").font(.system(size: 12)).foregroundStyle(palette.secondary)
                            }.padding(.vertical, 18)
                        } else {
                            ForEach(model.sources) { source in serviceRow(source) }
                        }
                    }
                }.frame(maxHeight: 300)
                if let error = appearance.errorMessage ?? appearance.storageError {
                    Text(error).font(.system(size: 11)).foregroundStyle(palette.warning)
                }
            }
        } actions: {
            Text(presentation.configurationGroup == .ai ? "目前支持 Codex 与 Claude 的本机来源" : "各订单或实例独立管理")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
            Spacer(minLength: 12)
            if presentation.configurationGroup == .ai {
                Button {
                    presentation.showingConfiguration = false; presentation.selectedSourceID = nil; ai.openSources()
                } label: { Label("添加 AI 来源", systemImage: "plus") }
                    .buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("fc.usage.config.add-ai")
            } else {
                Button { presentation.add(.iproyal) } label: { Label("新增服务流量", systemImage: "plus") }
                    .buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("fc.usage.config.add-service")
            }
        }.accessibilityIdentifier("fc.usage.configuration")
    }
    private func category(_ group: UsageCardGroup, title: String) -> some View {
        Button { presentation.configurationGroup = group } label: {
            Text(title).font(.system(size: 12)).foregroundStyle(presentation.configurationGroup == group ? palette.text : palette.muted)
                .frame(width: 140, height: 32)
                .overlay(alignment: .bottom) { if presentation.configurationGroup == group { Rectangle().fill(palette.accent).frame(height: 2) } }
        }.buttonStyle(ClickablePlainButtonStyle()).accessibilityAddTraits(presentation.configurationGroup == group ? [.isSelected] : [])
            .accessibilityIdentifier("fc.usage.config." + group.rawValue)
    }
    private func aiRow(_ provider: AIProvider) -> some View {
        let display = appearance.appearance(for: UsagePresentationSourceID.ai(provider))
        return HStack(spacing: 10) {
            UsageSourceIcon(appearance: appearance, icon: display.icon, aiProvider: provider)
            VStack(alignment: .leading, spacing: 3) {
                Text(display.displayName ?? provider.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text((display.visible ? "在概览中显示" : "已从概览隐藏") + " · " + (ai.configuration(for: provider).enabled ? "自动读取开启" : "自动读取关闭"))
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("编辑") { presentation.editAI(provider, appearance: display) }.buttonStyle(WBButtonStyle(compact: true))
                .accessibilityIdentifier("fc.usage.config.edit-ai." + provider.rawValue)
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
    private func serviceRow(_ source: ProviderUsageConfiguration) -> some View {
        let display = appearance.appearance(for: UsagePresentationSourceID.service(source.id))
        return HStack(spacing: 10) {
            UsageSourceIcon(appearance: appearance, icon: display.icon, serviceKind: source.kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(display.displayName ?? source.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(source.kind.title + " · " + (display.visible ? "在概览中显示" : "已从概览隐藏"))
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("编辑") { presentation.edit(source, appearance: display) }.buttonStyle(WBButtonStyle(compact: true))
                .accessibilityIdentifier("fc.usage.config.edit-service." + source.id.uuidString)
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}

struct UsageAIEditorView: View {
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
                if let error = appearance.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning) }
            }
        } actions: {
            Spacer()
            Button("取消", action: presentation.requestCloseAIEditor).buttonStyle(WBButtonStyle())
            Button("保存") {
                var value = editor.display; value.displayName = editor.name
                if appearance.saveAppearance(value, for: UsagePresentationSourceID.ai(editor.provider)) { presentation.aiEditor = nil }
            }.buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("fc.usage.ai-editor.save")
        }.accessibilityIdentifier("fc.usage.ai-editor")
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
