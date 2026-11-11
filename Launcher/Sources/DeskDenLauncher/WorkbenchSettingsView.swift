import AppKit
import SwiftUI
import LauncherCore

struct WorkbenchSettingsView: View {
    @ObservedObject var model: WorkbenchAppModel
    @ObservedObject private var vault: VaultModel
    @Environment(\.workbenchPalette) private var palette

    init(model:WorkbenchAppModel) {
        self.model=model
        self.vault=model.vault
    }

    private var subtitle: String {
        switch model.settingsTab {
        case .general: "管理启动方式、工作台入口与数据更新"
        case .material: "工作台、启动器与浮层使用同一套外观"
        case .launcher: "调整启动方式、按键绑定与搜索"
        case .widgets: "管理桌面组件的显示、位置与行为"
        case .privacy: "管理个人内容、数据来源与访问权限"
        case .audit: "查看各模块的数据来源与可用状态"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: model.settingsTab.title, subtitle: subtitle) {
                // The page action sits in the header, like every other page (9.4, S7).
                if model.settingsTab == .widgets {
                    Button { model.showDesktop?() } label: { Label("查看桌面", systemImage: "macwindow.on.rectangle") }
                        .buttonStyle(WBButtonStyle()).accessibilityIdentifier("fc.settings.widgets.show-desktop")
                } else if model.settingsTab == .launcher, let owner = model.owner {
                    Button { owner.show() } label: { Label("打开启动器", systemImage: "keyboard") }
                        .buttonStyle(WBButtonStyle()).accessibilityIdentifier("fc.settings.launcher.open")
                }
            }
            switch model.settingsTab {
            case .general: general
            case .material: material
            case .launcher: launcher
            case .widgets: DesktopCardsView(cards: model.preferences.cards, update: model.updateCard, openDesktop: { model.showDesktop?() }, device: model.device, calendar: model.calendar, ai: model.ai, showsHeader: false)
            case .privacy: privacy
            case .audit: audit
            }
        }
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children:.contain).accessibilityIdentifier("fc.page.settings."+model.settingsTab.rawValue)
    }

    // Every settings row is the shared setting row (现行规范 4.5 G1, 9.4 S1).
    private var general: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let owner = model.owner { WorkbenchUpdateSettings(updates: owner.updates) }
            WBCard(title: "启动与入口", symbol: "power", spacing: 0) {
                settingsRow("登录时启动", model.loginNeedsApproval ? "需要在系统设置的登录项中批准" : "随系统登录在后台运行", first: true) {
                    settingToggle("登录时启动", get: { model.loginEnabled }, set: model.setLogin)
                }
                settingsRow("显示菜单栏图标", "通过菜单栏快速打开工作台") {
                    settingToggle("显示菜单栏图标", get: { model.preferences.menuBarVisible }, set: model.changeMenuBar)
                }
                if let controller = model.owner?.topEntryController {
                    WorkbenchTopEntryRow(controller: controller)
                }
                settingsRow("工作台快捷键", "随时打开工作台") {
                    if let owner = model.owner { WorkbenchShortcutSetting(owner: owner) }
                }
                settingsRow("记住窗口大小", "关闭时每次打开都恢复默认大小；开启后沿用上次的大小") {
                    settingToggle("记住窗口大小", get: { model.remembersWindowSize }, set: model.changeRemembersWindowSize)
                }
            }
            if let controller = model.owner?.topEntryController {
                WorkbenchMiniDisplaySettings(controller: controller, providers: model.providerUsage, balances: model.apiBalance)
            }
            WBCard(title: "数据更新", symbol: "arrow.clockwise", spacing: 0) {
                settingsRow("设备采样间隔", "隐藏时降低性能采样频率，保留网络累计", first: true) {
                    WBSelect("设备采样间隔", selection: Binding(get: { model.preferences.sampleInterval }, set: model.changeSampleInterval), options: [1.0, 2, 5].map { (value: $0, title: "\(Int($0)) 秒") }).frame(width: 174)
                }
                settingsRow("本机数据目录", "管理配置与本机历史记录") {
                    Button("在访达中打开") { model.revealDataDirectory() }.buttonStyle(WBButtonStyle(compact: true))
                }
            }
        }
    }

    /// One card: the appearance is chosen on the cards themselves (9.4 S5);
    /// the pointer choice joins it instead of a card of its own (S3).
    private var material: some View {
        WBCard(title: "共享外观", symbol: "circle.lefthalf.filled", spacing: 0) {
            HStack(spacing: 12) {
                appearanceCard(.light, title: "浅色", detail: "青蓝琥珀 · 奶白半透明表面")
                appearanceCard(.dark, title: "深色", detail: "墨金 · 炭黑半透明表面")
                appearanceCard(.system, title: "跟随系统", detail: "随 macOS 外观切换")
            }.padding(.bottom, 14)
                .accessibilityElement(children: .contain).accessibilityLabel("外观")
                .accessibilityIdentifier("fc.settings.appearance")
            settingsRow("减少动态效果", "停用欢迎文字动效并简化界面过渡；系统设置始终优先") {
                settingToggle("减少动态效果", get: { model.reduceMotion }, set: model.changeReduceMotion)
            }
            settingsRow("按钮悬停指针", "默认使用小手，提示按钮、选项与导航可以点击") {
                WBSelect("按钮悬停指针", selection: Binding(get: { model.buttonHoverCursor }, set: model.changeButtonHoverCursor), options: ButtonHoverCursor.allCases.map { (value: $0, title: $0.title) }).frame(width: 174)
            }
        }
    }

    /// A selectable appearance card with a visible selection mark (现行规范 4.4 D8).
    private func appearanceCard(_ value: LauncherAppearance, title: String, detail: String) -> some View {
        let selected = model.appearance == value
        return Button { model.changeAppearance(value) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if value == .system {
                        HStack(spacing: 0) {
                            WorkbenchFluidBackground().environment(\.colorScheme, .light)
                            WorkbenchFluidBackground().environment(\.colorScheme, .dark)
                        }
                    } else {
                        WorkbenchFluidBackground().environment(\.colorScheme, value == .light ? .light : .dark)
                    }
                }.frame(maxWidth: .infinity).frame(height: 84).clipped().accessibilityHidden(true)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text)
                        Text(detail).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 16))
                        .foregroundStyle(selected ? palette.accent : palette.muted).accessibilityHidden(true)
                }.padding(.horizontal, 12).frame(height: 52)
            }
            .background(WorkbenchMaterialSurface(kind: .control, radius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? palette.accent : palette.border, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(ClickablePlainButtonStyle())
            .accessibilityLabel(title).accessibilityValue(selected ? "已选择" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("fc.settings.appearance." + value.rawValue)
    }

    private var launcher: some View {
        Group {
            if let owner = model.owner {
                WorkbenchLauncherSettings(owner: owner) { model.settingsTab = .material }
            }
        }
    }

    private var privacy: some View {
        WBCard(title: "内容保护", symbol: "checkmark.shield", spacing: 0) {
            settingsRow("私密空间", "独立密码、离页锁定与加密备份", first: true) {
                if vault.isUnlocked {
                    Button("保护与备份") {
                        guard vault.isUnlocked else {return}
                        model.navigate(.vault)
                        if model.route == .vault {vault.showProtection(fromSettings:true)}
                    }.buttonStyle(WBButtonStyle(compact: true))
                        .accessibilityIdentifier("fc.settings.privacy.vault-protection")
                }
            }
            settingsRow("日历与提醒", "按来源分别授权，拒绝不影响本机提醒") {
                Button("管理来源") {
                    model.calendar.openSources(fromSettingsPrivacy:true); model.navigate(.calendar)
                }.buttonStyle(WBButtonStyle(compact: true))
            }
            settingsRow("AI 数据", "只读取计量元数据，不读取对话正文与密钥") {
                Button("管理来源") { model.ai.openSources(fromSettingsPrivacy:true);model.navigate(.ai) }.buttonStyle(WBButtonStyle(compact: true))
            }
            settingsRow("服务流量额度", "实例凭据存入钥匙串；浏览器连接只同步额度") {
                Button("管理来源") {model.openUsageOverview()}.buttonStyle(WBButtonStyle(compact:true))
            }
        }
    }

    /// Setting rows with a status capsule; the technical detail stays in the export (9.4 S9).
    private var audit: some View {
        VStack(alignment: .leading, spacing: 12) {
            WBCard(title: "功能与来源状态", symbol: "checklist", spacing: 0) {
                let entries = model.auditEntries
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    WBSettingRow(title: entry.title, subtitle: entry.summary.isEmpty ? entry.detail : entry.summary, showsDivider: index > 0) {
                        WBStatusPill(title: entry.state, good: entry.isGood)
                    }.accessibilityIdentifier("fc.settings.audit." + entry.id)
                }
                HStack(spacing: 8) {
                    Button { model.runStorageAudit() } label: { Label("重新检查", systemImage: "arrow.clockwise") }.buttonStyle(WBButtonStyle())
                    Spacer()
                    Button { model.exportAudit() } label: { Label("导出诊断", systemImage: "arrow.down.to.line") }.buttonStyle(WBButtonStyle())
                }.padding(.top, 12)
            }
            WBPageNote {
                Text((model.lastAudit.map { "本机存储检查于 " + WorkbenchDateText.fullWithTime($0, calendar: .current) + "。" } ?? "")
                     + "导出包含功能与连接状态，不包含提醒正文、聊天内容、私密文字或认证信息。")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingToggle(_ label: String, get: @escaping @MainActor @Sendable () -> Bool, set: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: get, set: set)).labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.mini)
            .tint(palette.accent)
    }

    private func settingsRow<T: View>(_ title: String, _ subtitle: String, first: Bool = false, @ViewBuilder trailing: () -> T) -> some View {
        WBSettingRow(title: title, subtitle: subtitle, showsDivider: !first) { trailing().fixedSize(horizontal: true, vertical: false) }
    }
}

private struct WorkbenchMiniDisplaySettings: View {
    @ObservedObject var controller: WorkbenchTopEntryController
    @ObservedObject var providers: ProviderUsageModel
    @ObservedObject var balances: APIBalanceModel
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchPageWidth) private var pageWidth
    private var columns: [GridItem] {
        let count = max(1, min(4, Int((max(0, pageWidth - 28) + 12) / 172)))
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12, alignment: .leading), count: count)
    }
    var body: some View {
        WBCard(title: "Mini 显示内容", symbol: "rectangle.topthird.inset.filled", spacing: 12) {
            HStack {
                group("顶部信息")
                Spacer()
                Button("恢复默认", action: controller.restoreMiniSections).buttonStyle(WBButtonStyle(compact: true))
                    .accessibilityIdentifier("mini-display-restore-defaults")
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                Toggle("日期时间", isOn: Binding(get: { controller.preferences.showDate }, set: { controller.setMiniHeader(date: $0, weather: controller.preferences.showWeather) }))
                    .accessibilityIdentifier("mini-display-date")
                Toggle("城市天气", isOn: Binding(get: { controller.preferences.showWeather }, set: { controller.setMiniHeader(date: controller.preferences.showDate, weather: $0) }))
                    .accessibilityIdentifier("mini-display-weather")
            }
            group("卡片内容")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(WorkbenchMiniCardID.builtIn) { card in cardToggle(card, title: card.title) }
            }
            if !providers.sources.isEmpty || !balances.sources.isEmpty {
                group("服务额度")
                WorkbenchScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(providers.sources) { source in cardToggle(.provider(source.id), title: source.name) }
                        ForEach(balances.sources) { source in cardToggle(.apiBalance(source.id), title: source.name) }
                    }.padding(.vertical, 2)
                }.frame(maxHeight: 180)
            }
            Text("在 Mini 的编辑模式中拖动卡片调整顺序；城市、时区和温度单位沿用首页设置。")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
            if let error = controller.error { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning) }
        }.toggleStyle(WBCheckboxToggleStyle())
            .accessibilityElement(children: .contain).accessibilityIdentifier("mini-display-settings")
    }
    /// Group titles use the 13-medium step (现行规范 2.1, 9.4 S10).
    private func group(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text)
    }
    private func cardToggle(_ card: WorkbenchMiniCardID, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { controller.preferences.activeCards(available: controller.availableMiniCards).contains(card) }, set: { controller.setMiniCard(card, visible: $0) }))
            .help(title).accessibilityIdentifier("mini-display-card-" + card.rawValue)
    }
}

/// The top entry's reason for being unavailable goes into the row's description (G1).
private struct WorkbenchTopEntryRow: View {
    @ObservedObject var controller: WorkbenchTopEntryController
    @Environment(\.workbenchPalette) private var palette
    private enum Choice: String, CaseIterable {
        case summary, workbench, disabled
        var title: String {
            switch self { case .summary: "迷你信息面板"; case .workbench: "直接展开工作台"; case .disabled: "关闭" }
        }
    }
    private var selection: Choice { controller.preferences.enabled ? (controller.preferences.mode == .summary ? .summary : .workbench) : .disabled }
    var body: some View {
        WBSettingRow(title: "顶部入口", subtitle: controller.error ?? "靠近屏幕顶部，查看简要信息或进入工作台", subtitleColor: controller.error == nil ? nil : palette.warning) {
            WBSelect("顶部入口", selection: Binding(get: { selection }, set: { value in
                if value == .disabled { controller.setEnabled(false) }
                else {
                    controller.setMode(value == .summary ? .summary : .workbench)
                    if controller.error == nil { controller.setEnabled(true) }
                }
            }), options: Choice.allCases.map { (value: $0, title: $0.title) }).frame(width: 174)
        }
    }
}
