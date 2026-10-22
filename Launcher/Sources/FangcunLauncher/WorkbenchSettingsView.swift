import AppKit
import SwiftUI
import LauncherCore

struct WorkbenchSettingsView: View {
    @ObservedObject var model: WorkbenchAppModel
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var previewResponded = false

    private var subtitle: String {
        switch model.settingsTab {
        case .general: "管理启动方式、工作台入口与数据更新"
        case .material: "工作台、启动器与浮层使用同一套外观"
        case .launcher: "调整启动方式、按键绑定与搜索"
        case .privacy: "管理个人内容、数据来源与访问权限"
        case .audit: "查看各模块的数据来源与可用状态"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: model.settingsTab.title, subtitle: subtitle)
            switch model.settingsTab {
            case .general: general
            case .material: material
            case .launcher: launcher
            case .privacy: privacy
            case .audit: audit
            }
        }
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children:.contain).accessibilityIdentifier("fc.page.settings."+model.settingsTab.rawValue)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 12) {
            WBCard(title: "启动与入口", symbol: "power", spacing: 10) {
                VStack(spacing: 0) {
                    settingsRow("登录时启动", model.loginNeedsApproval ? "需要在系统设置的登录项中批准" : "随系统登录在后台运行", first: true) {
                        settingToggle("登录时启动", get: { model.loginEnabled }, set: model.setLogin)
                    }
                    settingsRow("显示菜单栏图标", "通过菜单栏快速打开工作台") {
                        settingToggle("显示菜单栏图标", get: { model.preferences.menuBarVisible }, set: model.changeMenuBar)
                    }
                    if let controller = model.owner?.topEntryController {
                        settingsRow("顶部入口", "靠近屏幕顶部，查看简要信息或进入工作台") {
                            WorkbenchTopEntrySelection(controller: controller).frame(width: 174)
                        }
                    }
                    settingsRow("工作台快捷键", "随时打开工作台", last: true) {
                        if let owner = model.owner { WorkbenchShortcutSetting(owner: owner) }
                    }
                }
            }
            WBCard(title: "数据更新", symbol: "arrow.clockwise", spacing: 10) {
                VStack(spacing: 0) {
                    settingsRow("设备采样间隔", "隐藏时降低性能采样频率，保留网络累计", first: true) {
                        WBSelect("设备采样间隔", selection: Binding(get: { model.preferences.sampleInterval }, set: model.changeSampleInterval), options: [1.0, 2, 5].map { (value: $0, title: "\(Int($0)) 秒") }).frame(width: 174)
                    }
                    settingsRow("本机数据目录", "管理配置与本机历史记录", last: true) {
                        Button("在访达中打开") { model.revealDataDirectory() }.buttonStyle(WBButtonStyle(compact: true))
                    }
                }
            }
        }
    }

    private var material: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkbenchApplicationIconSettings()
            materialControls
        }
    }

    private var materialControls: some View {
        WBCard(title: "共享外观", symbol: "circle.lefthalf.filled", spacing: 10) {
            VStack(spacing: 0) {
                settingsRow("外观", "工作台、启动器与浮层保持一致", first: true) {
                    WBSelect("外观", selection: Binding(get: { model.appearance }, set: model.changeAppearance), options: LauncherAppearance.allCases.map { (value: $0, title: $0.title) }).frame(width: 174)
                }
                settingsRow("主题背景", "玻璃层、Mini 与浮层同步使用") {
                    WBSelect("主题背景", selection: Binding(get: { model.theme }, set: model.changeTheme), options: LauncherTheme.allCases.map { (value: $0, title: $0.title) }).frame(width: 174)
                }
                settingsRow("界面不透明度", "卡片、导航、菜单与 Mini 同步调整") {
                    VStack(spacing: 2) {
                        HStack(spacing: 10) {
                            WorkbenchOpacitySlider(value: Binding(get: { model.opacity }, set: model.changeOpacity))
                                .frame(minWidth: 150, idealWidth: 170, maxWidth: 170, minHeight: 32, maxHeight: 32)
                            Text("\(Int((model.opacity * 100).rounded()))%")
                                .font(.system(size: 12)).monospacedDigit().frame(width: 36, alignment: .trailing)
                                .accessibilityLabel("当前界面不透明度")
                        }
                        HStack {
                            Text("50% · 更通透")
                            Spacer(minLength: 8)
                            Text("90% · 更清晰")
                        }.font(.system(size: 11)).foregroundStyle(palette.muted)
                    }.frame(width: 224)
                }
                materialPreview.padding(.vertical, 12)
                settingsRow("恢复默认", "默认界面不透明度为 70%", first: true) {
                    Button("恢复 70%") { model.changeOpacity(0.70) }.buttonStyle(WBButtonStyle(compact: true))
                }
                settingsRow("背景动态效果", motionStatus) {
                    settingToggle("背景动态效果", get: { model.backgroundMotion }, set: model.changeBackgroundMotion)
                }
                settingsRow("减少动态效果", "背景保持静止，同时简化界面过渡；系统设置始终优先", last: true) {
                    settingToggle("减少动态效果", get: { model.reduceMotion }, set: model.changeReduceMotion)
                }
            }
        }
    }

    private var motionStatus: String {
        if systemReduceMotion || model.reduceMotion { return "减少动态效果已开启，背景保持静止" }
        return model.backgroundMotion ? "缓慢光轨与悬浮屏幕微动，不影响内容阅读" : "背景保持静止"
    }

    private var materialPreview: some View {
        HStack(spacing: 12) {
            Label("同一套玻璃材质", systemImage: "square.3.layers.3d")
                .font(.system(size: 12)).foregroundStyle(palette.secondary)
            Spacer()
            Text("\(Int((model.opacity * 100).rounded()))%")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(palette.secondary)
            Spacer()
            Button(previewResponded ? "已响应" : "按钮预览") {
                previewResponded = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    previewResponded = false
                }
            }.buttonStyle(WBButtonStyle(compact: true))
        }
        .padding(.horizontal, 22).frame(height: 90)
        .background {
            GeometryReader { geometry in
                ZStack {
                    if let image = WorkbenchSceneAssets.image(for: model.theme) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                    palette.surfaceGradient
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(palette.line, lineWidth: 1).allowsHitTesting(false))
    }

    private var launcher: some View {
        Group {
            if let owner = model.owner {
                WorkbenchLauncherSettings(owner: owner) { model.settingsTab = .material }
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 12) {
            WBCard(title: "内容保护", symbol: "checkmark.shield", spacing: 10) {
                VStack(spacing: 0) {
                    settingsRow("私密空间", "独立密码、离页锁定与加密备份", first: true) {
                        Button("保护设置") {
                            model.navigate(.vault)
                            model.vault.showProtection(fromSettings:true)
                        }.buttonStyle(WBButtonStyle(compact: true))
                    }
                    settingsRow("日历与提醒", "按来源分别授权，拒绝不影响本机提醒") {
                        Button("来源管理") {
                            model.calendar.openSources(fromSettingsPrivacy:true); model.navigate(.calendar)
                        }.buttonStyle(WBButtonStyle(compact: true))
                    }
                    settingsRow("AI 数据", "只读取计量元数据，不读取对话正文与密钥", last: true) {
                        Button("来源管理") { model.ai.openSources(fromSettingsPrivacy:true);model.navigate(.ai) }.buttonStyle(WBButtonStyle(compact: true))
                    }
                }
            }
            WBCard(title: "诊断范围", symbol: "doc.badge.gearshape", spacing: 10) {
                VStack(spacing: 0) {
                    settingsRow("状态诊断", "不包含提醒正文、私密文字和认证内容", first: true, last: true) {
                        Button("查看审计") { model.settingsTab = .audit }.buttonStyle(WBButtonStyle(compact: true))
                    }
                }
            }
        }
    }

    private var audit: some View {
        WBCard(title: "功能与来源状态", symbol: "checklist", spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("检查连接、权限与本机持久化状态。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.bottom, 12)
                ForEach(model.auditEntries) { entry in
                    HStack(alignment: .center, spacing: 16) {
                        Text(entry.title).font(.system(size: 12)).frame(width: 118, alignment: .leading)
                        Text(entry.detail).font(.system(size: 11)).foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.state).font(.system(size: 11)).foregroundStyle(palette.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(palette.soft, in: RoundedRectangle(cornerRadius: 5))
                            .frame(maxWidth: 155, alignment: .trailing)
                    }.padding(.vertical, 12)
                    if entry.id != model.auditEntries.last?.id { Rectangle().fill(palette.line).frame(height: 1) }
                }
                HStack(spacing: 8) {
                    Button { model.runStorageAudit() } label: { Label("重新检查", systemImage: "arrow.clockwise") }.buttonStyle(WBButtonStyle())
                    Spacer()
                    Button { model.exportAudit() } label: { Label("导出诊断", systemImage: "arrow.down.to.line") }.buttonStyle(WBButtonStyle())
                }.padding(.top, 12)
                if let date = model.lastAudit {
                    Text("本机存储检查于 " + date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 10)
                }
                Text("导出包含功能与连接状态，不包含提醒正文、聊天内容、私密文字或认证信息。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 10)
            }
        }
    }

    private func settingToggle(_ label: String, get: @escaping @MainActor @Sendable () -> Bool, set: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: get, set: set)).labelsHidden().toggleStyle(.switch).controlSize(.small)
            .tint(palette.accent)
    }

    private func settingsRow<T: View>(_ title: String, _ subtitle: String, first: Bool = false, last: Bool = false, @ViewBuilder trailing: () -> T) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text).frame(minHeight:17.4,alignment:.leading)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.muted)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true).frame(minHeight:15.95,alignment:.leading)
                }.frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 8)
                trailing().fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 13).padding(.bottom, last ? 0 : 13)
            if !last { Rectangle().fill(palette.line).frame(height: 1) }
        }
    }
}

private struct WorkbenchTopEntrySelection: View {
    @ObservedObject var controller: WorkbenchTopEntryController
    private enum Choice: String, CaseIterable {
        case summary, workbench, disabled
        var title: String {
            switch self { case .summary: "迷你信息面板"; case .workbench: "直接展开工作台"; case .disabled: "关闭" }
        }
    }
    private var selection: Choice { controller.preferences.enabled ? (controller.preferences.mode == .summary ? .summary : .workbench) : .disabled }
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            WBSelect("顶部入口", selection: Binding(get: { selection }, set: { value in
                if value == .disabled { controller.setEnabled(false) }
                else {
                    controller.setMode(value == .summary ? .summary : .workbench)
                    if controller.error == nil { controller.setEnabled(true) }
                }
            }), options: Choice.allCases.map { (value: $0, title: $0.title) })
            if let error = controller.error {
                Text(error).font(.system(size: 11)).foregroundStyle(WorkbenchStyle.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// This AppKit control keeps the same responder throughout a continuous drag.
/// Updating the surrounding model therefore cannot replace the knob mid-gesture.
private struct WorkbenchOpacitySlider: NSViewRepresentable {
    @Binding var value: Double
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.workbenchPalette) private var palette
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = WorkbenchInterfaceOpacityControl(value: value, minValue: 0.50, maxValue: 0.90, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.altIncrementValue = 0.01
        slider.controlSize = .regular
        slider.setAccessibilityLabel("界面不透明度")
        slider.setAccessibilityHelp("50% 更通透，90% 更清晰；使用方向键按 1% 调整")
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.isEnabled = isEnabled
        if abs(slider.doubleValue - value) > 0.000_001 { slider.doubleValue = value }
        slider.trackFillColor = palette.nsAccent
        slider.setAccessibilityValueDescription("\(Int((value * 100).rounded()))%")
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 170, height: 32)
    }
    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ sender: NSSlider) {
            value.wrappedValue = (sender.doubleValue * 100).rounded() / 100
        }
    }
}

private final class WorkbenchInterfaceOpacityControl: NSSlider {
    override var mouseDownCanMoveWindow:Bool {false}
    override var acceptsFirstResponder:Bool {true}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with:event)
    }
    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        let next: Double
        switch event.keyCode {
        case 123, 125: next = doubleValue - 0.01
        case 124, 126: next = doubleValue + 0.01
        case 115: next = minValue
        case 119: next = maxValue
        default: super.keyDown(with: event); return
        }
        doubleValue = min(maxValue, max(minValue, (next * 100).rounded() / 100))
        sendAction(action, to: target)
    }
}

struct LauncherSettingsEmbeddedView:NSViewRepresentable {
    let owner:LauncherController
    let section:Int
    final class Coordinator {var controller:LauncherSettingsWindowController;init(_ controller:LauncherSettingsWindowController){self.controller=controller}}
    func makeCoordinator()->Coordinator {
        if owner.settingsWindowController == nil {owner.settingsWindowController=LauncherSettingsWindowController(owner:owner)}
        return Coordinator(owner.settingsWindowController!)
    }
    func makeNSView(context:Context)->NSView {context.coordinator.controller.embeddedPage(section:section)}
    func updateNSView(_ view:NSView,context:Context) {_=context.coordinator.controller.embeddedPage(section:section)}
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSView,context:Context)->CGSize? {
        context.coordinator.controller.embeddedSize(width:proposal.width ?? max(485,nsView.bounds.width))
    }
    static func dismantleNSView(_ view:NSView,coordinator:Coordinator) {coordinator.controller.stopEmbedding()}
}
