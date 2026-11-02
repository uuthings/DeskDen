import AppKit
import SwiftUI
import LauncherCore

/// The approved header keeps its center independent of the brand and account
/// controls. A second expanded item is reserved for hover or keyboard focus.
struct WorkbenchFluidNavigation: View {
    @ObservedObject var model: WorkbenchAppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var hoveredRoute: WorkbenchRoute?
    @State private var accountPresented = false
    @State private var brandHovered = false
    @FocusState private var focusedRoute: WorkbenchRoute?
    @FocusState private var brandFocused: Bool
    private let routes: [WorkbenchRoute] = [.overview, .device, .cleaning, .calendar, .ai, .network, .vault]
    private var motion: Animation? { model.reduceMotion || systemReduceMotion ? nil : .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.19) }

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                brand
                if let owner = model.owner { WorkbenchFluidUpdateEntry(updates: owner.updates) }
                Spacer(minLength: 0)
                HStack(spacing: 11) {
                    WorkbenchFluidRoundButton(symbol: "gearshape", title: "设置", selected: model.route == .settings) {
                        model.navigate(.settings)
                    }.accessibilityIdentifier("navigation-settings")
                    WorkbenchFluidRoundButton(symbol: "person", title: "本机账户", avatar: true) { accountPresented.toggle() }
                        .accessibilityIdentifier("workbench-local-account")
                        .popover(isPresented: $accountPresented, arrowEdge: .top) {
                            accountMenu
                        }
                }
            }
            HStack(spacing: 7) {
                ForEach(routes, id: \.self) { route in navigation(route) }
            }.frame(width: 358, height: 32)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("主导航")
                .accessibilityIdentifier("workbench-top-navigation")
        }.padding(.horizontal, 24).frame(height: 58)
            .onChange(of: model.route) { _, _ in accountPresented = false; hoveredRoute = nil }
            .onChange(of: model.windowVisible) { _, visible in if !visible { accountPresented = false; hoveredRoute = nil } }
    }

    private var brand: some View {
        Button { model.brandMenuPresented.toggle() } label: {
            HStack(spacing: 6) {
                WorkbenchBrandMark(pointSize: 34)
                Text("方寸").font(.system(size: 13, weight: .medium))
            }.foregroundStyle(.white).padding(.vertical, 3)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .background(Color.white.opacity(brandHovered || brandFocused ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(ClickablePlainButtonStyle()).focused($brandFocused).focusEffectDisabled()
            .onHover { brandHovered = $0 }
            .help("方寸菜单").accessibilityLabel("方寸菜单").accessibilityIdentifier("window-brand")
            .popover(isPresented: $model.brandMenuPresented, arrowEdge: .top) {
                WorkbenchFluidBrandMenu(model: model)
            }
    }

    private func navigation(_ route: WorkbenchRoute) -> some View {
        let selected = model.route == route
        let expanded = selected || hoveredRoute == route || focusedRoute == route
        return Button {
            if route == .ai { model.openUsageOverview() } else { model.navigate(route) }
        } label: {
            HStack(spacing: 0) {
                if route == .ai {
                    FluidUsageNavigationGlyph().stroke(style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                        .frame(width: 15, height: 15).accessibilityHidden(true)
                } else { WorkbenchNavigationIcon(route: route, size: 15) }
                Text(shortTitle(route)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .frame(width: expanded ? 26 : 0).clipped().opacity(expanded ? 1 : 0)
                    .padding(.leading, expanded ? 7 : 0)
            }.frame(width: expanded ? 78 : 32, height: 32)
                .foregroundStyle(expanded ? FluidNavigationColors.ink : Color.white.opacity(0.86))
                .background(Color.white.opacity(expanded ? 0.94 : 0.028), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(expanded ? 1 : 0.31), lineWidth: 1))
                .clipShape(Capsule())
                .shadow(color: FluidNavigationColors.shadow.opacity(expanded ? 0.05 : 0), radius: 2, y: 1)
                .contentShape(Capsule())
        }.buttonStyle(ClickablePlainButtonStyle()).focused($focusedRoute, equals: route).focusEffectDisabled()
            .onHover { inside in
                if inside { hoveredRoute = route } else if hoveredRoute == route { hoveredRoute = nil }
            }
            .animation(motion, value: expanded)
            .accessibilityLabel(route.title)
            .accessibilityValue(selected ? "当前页面" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("navigation-" + route.rawValue).help(route.title)
    }

    private func shortTitle(_ route: WorkbenchRoute) -> String {
        switch route {
        case .overview: "首页"
        case .device: "设备"
        case .cleaning: "清理"
        case .calendar: "日历"
        case .ai: "用量"
        case .network: "网络"
        case .vault: "私密"
        default: route.title
        }
    }

    private var accountMenu: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle").font(.system(size: 34, weight: .light)).foregroundStyle(FluidNavigationColors.account)
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()).font(.system(size: 14, weight: .medium))
                    Text("本机账户 · 本机模式").font(.system(size: 11)).foregroundStyle(FluidNavigationColors.secondary)
                }
            }
            Button {
                accountPresented = false
                DispatchQueue.main.async { model.navigate(.settings) }
            } label: {
                Label("打开设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(WBButtonStyle())
        }.padding(16).frame(width: 244).foregroundStyle(FluidNavigationColors.ink)
            .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.87, backgroundMotion: false, appearance: .light)
            .accessibilityElement(children: .contain).accessibilityIdentifier("workbench-local-account-menu")
    }
}

/// All settings remain reachable after the main sidebar is removed.
struct WorkbenchFluidSettingsNavigation: View {
    @ObservedObject var model: WorkbenchAppModel
    var body: some View {
        HStack(spacing: 8) {
            WorkbenchFluidRoundButton(symbol: "arrow.left", title: "返回" + model.settingsReturnRoute.title) { model.returnFromSettings() }
                .accessibilityIdentifier("settings-return")
            ForEach(WorkbenchSettingsTab.allCases, id: \.self) { tab in
                WorkbenchFluidSettingsTab(tab: tab, selected: model.settingsTab == tab) { model.settingsTab = tab }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 35)
            .accessibilityElement(children: .contain).accessibilityLabel("设置分类")
            .accessibilityIdentifier("workbench-settings-navigation")
    }
}

private struct WorkbenchFluidSettingsTab: View {
    let tab: WorkbenchSettingsTab
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                WorkbenchNavigationIcon(symbol: tab.symbol, size: 15)
                Text(tab.title).font(.system(size: 12, weight: selected ? .medium : .regular))
            }.padding(.horizontal, 12).frame(height: 32)
                .foregroundStyle(selected || hovered || focused ? FluidNavigationColors.ink : .white)
                .background(Color.white.opacity(selected || hovered || focused ? 0.94 : 0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(selected || hovered || focused ? 1 : 0.31), lineWidth: 1))
                .contentShape(Capsule())
        }.buttonStyle(ClickablePlainButtonStyle()).focused($focused).focusEffectDisabled().onHover { hovered = $0 }
            .accessibilityLabel(tab.title).accessibilityValue(selected ? "当前页面" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("settings-navigation-" + tab.rawValue)
    }
}

private struct WorkbenchFluidRoundButton: View {
    let symbol: String
    let title: String
    var selected = false
    var avatar = false
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: avatar ? 17 : 15, weight: .regular))
                .frame(width: 32, height: 32)
                .foregroundStyle(avatar ? FluidNavigationColors.account : selected ? FluidNavigationColors.ink : .white)
                .background {
                    if avatar {
                        Circle().fill(LinearGradient(colors: [Color.white.opacity(hovered || focused ? 1 : 0.95), Color(red: 219/255, green: 242/255, blue: 242/255).opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else { Circle().fill(Color.white.opacity(selected ? 0.94 : hovered || focused ? 0.14 : 0.03)) }
                }
                .overlay(Circle().strokeBorder(Color.white.opacity(avatar ? 0.86 : 0.31), lineWidth: 1))
                .contentShape(Circle())
        }.buttonStyle(ClickablePlainButtonStyle()).focused($focused).focusEffectDisabled().onHover { hovered = $0 }
            .accessibilityLabel(title).help(title)
    }
}

private struct WorkbenchFluidBrandMenu: View {
    @ObservedObject var model: WorkbenchAppModel
    private var version: String { "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("方寸").font(.system(size: 14, weight: .medium))
                Text(version).font(.system(size: 11)).foregroundStyle(FluidNavigationColors.secondary)
            }.padding(.horizontal, 10).padding(.vertical, 9)
            Divider().padding(.vertical, 3)
            if model.isTopEntryPresentation { row("留在窗口", symbol: "macwindow", identifier: "window-keep") { model.keepInOrdinaryWindow?() } }
            row("最小化窗口", symbol: "minus", identifier: "window-minimize") { model.minimizeWindow?() }
            row(model.isFullScreen ? "返回窗口" : "进入全屏", symbol: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", identifier: "window-fullscreen") { model.toggleFullScreen?() }
            row("关闭窗口", symbol: "xmark", identifier: "window-close") { model.closeWindow?() }
            Divider().padding(.vertical, 3)
            row("检查更新", symbol: "arrow.down.to.line", identifier: "window-check-updates") { model.owner?.updates.checkForUpdates() }
            row("设置", symbol: "gearshape", identifier: "window-open-settings") { model.navigate(.settings) }
            Divider().padding(.vertical, 3)
            row("退出方寸", symbol: "power", identifier: "window-quit") { _ = model.requestQuit() }
        }.padding(7).frame(width: 218).foregroundStyle(FluidNavigationColors.ink)
            .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.87, backgroundMotion: false, appearance: .light)
            .accessibilityElement(children: .contain).accessibilityIdentifier("workbench-brand-menu")
    }
    private func row(_ title: String, symbol: String, identifier: String, action: @escaping @MainActor () -> Void) -> some View {
        Button {
            model.brandMenuPresented = false
            DispatchQueue.main.async { action() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 18).accessibilityHidden(true)
                Text(title).font(.system(size: 12))
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).frame(height: 30).contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 7)).accessibilityIdentifier(identifier)
    }
}

private struct WorkbenchFluidUpdateEntry: View {
    @ObservedObject var updates: AppUpdateController
    private var title: String {
        switch updates.phase {
        case .downloading: "下载中"
        case .extracting: "准备更新"
        case .readyToInstall: "待安装"
        case .installing: "安装中"
        default: "新版本"
        }
    }
    var body: some View {
        if let release = updates.release {
            Button(action: updates.showUpdateDialog) {
                Label(title, systemImage: "arrow.down.to.line").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).frame(height: 26)
                    .foregroundStyle(FluidNavigationColors.ink)
                    .background(Color.white.opacity(0.94), in: Capsule()).contentShape(Capsule())
            }.buttonStyle(ClickablePlainButtonStyle()).help(title + " v" + release.version)
                .accessibilityLabel(title + " v" + release.version).accessibilityHint("打开软件更新窗口")
                .accessibilityIdentifier("updates-sidebar-entry")
        }
    }
}

private enum FluidNavigationColors {
    static let ink = Color(red: 32/255, green: 58/255, blue: 64/255)
    static let secondary = Color(red: 80/255, green: 103/255, blue: 109/255)
    static let account = Color(red: 53/255, green: 101/255, blue: 116/255)
    static let shadow = Color(red: 22/255, green: 64/255, blue: 75/255)
}

private struct FluidUsageNavigationGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bars: [(CGFloat, CGFloat)] = [(6, 14), (12, 7), (18, 3)]
        for (x, top) in bars {
            path.move(to: CGPoint(x: rect.minX + rect.width * x / 24, y: rect.minY + rect.height * top / 24))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * x / 24, y: rect.minY + rect.height * 21 / 24))
        }
        return path
    }
}
