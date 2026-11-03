import AppKit
import SwiftUI
import LauncherCore

/// The approved header keeps its center independent of the brand and account
/// controls. A second expanded item is reserved for hover or keyboard focus.
struct WorkbenchFluidNavigation: View {
    @ObservedObject var model: WorkbenchAppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var hoveredRoute: WorkbenchRoute?
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var focusedRoute: WorkbenchRoute?
    @FocusState private var brandFocused: Bool
    private let routes: [WorkbenchRoute] = [.overview, .device, .cleaning, .calendar, .ai, .network, .vault]
    private var motion: Animation? { FluidNavigationMotion.transition(disabled: model.reduceMotion || systemReduceMotion) }

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                brand
                if let owner = model.owner { WorkbenchFluidUpdateEntry(updates: owner.updates) }
                Spacer(minLength: 0)
                HStack(spacing: 11) {
                    WorkbenchFluidRoundButton(symbol: model.light ? "moon" : "sun.max", title: model.light ? "切换深色模式" : "切换浅色模式", suppressMotion: model.reduceMotion) {
                        model.changeLight(!model.light)
                    }.accessibilityIdentifier("fc.home.appearance.toggle")
                        .accessibilityValue(model.light ? "浅色" : "深色")
                    WorkbenchFluidRoundButton(symbol: "gearshape", title: "设置", selected: model.route == .settings, suppressMotion: model.reduceMotion) {
                        model.navigate(.settings)
                    }.accessibilityIdentifier("navigation-settings")
                    WorkbenchFluidAccountButton(model: model).frame(width: 32, height: 32)
                }
            }
            HStack(spacing: 7) {
                ForEach(routes, id: \.self) { route in navigation(route) }
            }.frame(width: 358, height: 32)
                .animation(motion, value: hoveredRoute)
                .animation(motion, value: focusedRoute)
                .animation(motion, value: model.route)
                .onHover { inside in if !inside { finishHover() } }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("主导航")
                .accessibilityIdentifier("workbench-top-navigation")
        }.padding(.horizontal, 24).frame(height: 58)
            .onChange(of: model.windowVisible) { _, visible in if !visible { resetHover() } }
            .onDisappear { resetHover() }
    }

    private var brand: some View {
        Button { model.brandMenuPresented.toggle() } label: {
            HStack(spacing: 7) {
                WorkbenchFluidDeskGlyph().stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 20, height: 20).accessibilityHidden(true)
                Text("DeskDen").font(.system(size: 14, weight: .medium)).tracking(0.25)
            }.foregroundStyle(.white).padding(.vertical, 3)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(brandFocused ? 0.65 : 0), lineWidth: 1).padding(-3))
        }.buttonStyle(ClickablePlainButtonStyle()).focused($brandFocused).focusEffectDisabled()
            .help("DeskDen 菜单").accessibilityLabel("DeskDen 菜单").accessibilityIdentifier("window-brand")
            .popover(isPresented: $model.brandMenuPresented, arrowEdge: .top) {
                WorkbenchFluidBrandMenu(model: model)
            }
    }

    private func navigation(_ route: WorkbenchRoute) -> some View {
        let selected = model.route == route
        let expanded = selected || (hoveredRoute ?? focusedRoute) == route
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
        }.buttonStyle(FluidNavigationButtonStyle(suppressMotion: model.reduceMotion)).focused($focusedRoute, equals: route).focusEffectDisabled()
            .onHover { inside in trackHover(route, inside: inside) }
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

    // Keep the expanded target until the pointer leaves the whole navigation
    // region. An animated capsule edge moving away is not a user hover exit.
    private func trackHover(_ route: WorkbenchRoute, inside: Bool) {
        guard inside else { return }
        hoverTask?.cancel(); hoverTask = nil
        hoveredRoute = route
    }
    private func finishHover() {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            hoveredRoute = nil
        }
    }
    private func resetHover() {
        hoverTask?.cancel(); hoverTask = nil; hoveredRoute = nil
    }
}

/// All settings remain reachable after the main sidebar is removed.
struct WorkbenchFluidSettingsNavigation: View {
    @ObservedObject var model: WorkbenchAppModel
    var body: some View {
        HStack(spacing: 8) {
            WorkbenchFluidRoundButton(symbol: "arrow.left", title: "返回" + model.settingsReturnRoute.title, suppressMotion: model.reduceMotion) { model.returnFromSettings() }
                .accessibilityIdentifier("settings-return")
            ForEach(WorkbenchSettingsTab.allCases, id: \.self) { tab in
                WorkbenchFluidSettingsTab(tab: tab, selected: model.settingsTab == tab, suppressMotion: model.reduceMotion) { model.settingsTab = tab }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 24)
            .accessibilityElement(children: .contain).accessibilityLabel("设置分类")
            .accessibilityIdentifier("workbench-settings-navigation")
    }
}

private struct WorkbenchFluidSettingsTab: View {
    let tab: WorkbenchSettingsTab
    let selected: Bool
    var suppressMotion = false
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        }.buttonStyle(FluidNavigationButtonStyle(suppressMotion: suppressMotion)).focused($focused).focusEffectDisabled().onHover { hovered = $0 }
            .animation(FluidNavigationMotion.transition(disabled: reduceMotion || suppressMotion), value: hovered || focused || selected)
            .accessibilityLabel(tab.title).accessibilityValue(selected ? "当前页面" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("settings-navigation-" + tab.rawValue)
    }
}

private struct WorkbenchFluidRoundButton: View {
    let symbol: String
    let title: String
    var selected = false
    var suppressMotion = false
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let engaged = selected || hovered || focused
        let motion = FluidNavigationMotion.transition(disabled: reduceMotion || suppressMotion)
        Button(action: action) {
            ZStack {
                Image(systemName: symbol).font(.system(size: 15, weight: .regular))
                    .id(symbol).transition(.opacity)
            }
                .frame(width: 32, height: 32)
                .foregroundStyle(engaged ? FluidNavigationColors.ink : .white)
                .background(Circle().fill(Color.white.opacity(engaged ? 0.94 : 0.03)))
                .overlay(Circle().strokeBorder(Color.white.opacity(engaged ? 1 : 0.31), lineWidth: 1))
                .contentShape(Circle())
        }.buttonStyle(FluidNavigationButtonStyle(suppressMotion: suppressMotion)).focused($focused).focusEffectDisabled().onHover { hovered = $0 }
            .animation(motion, value: engaged)
            .animation(motion, value: symbol)
            .accessibilityLabel(title).help(title)
    }
}

private enum FluidNavigationMotion {
    static func transition(disabled: Bool) -> Animation? {
        disabled ? nil : .timingCurve(0.25, 0.10, 0.25, 1, duration: 0.40)
    }
}

private struct FluidNavigationButtonStyle: ButtonStyle {
    var suppressMotion: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).clickableCursor()
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion || suppressMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct WorkbenchFluidBrandMenu: View {
    @ObservedObject var model: WorkbenchAppModel
    private var version: String { "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("DeskDen").font(.system(size: 14, weight: .medium))
                Text(version).font(.system(size: 11)).foregroundStyle(model.light ? FluidNavigationColors.secondary : Color.white.opacity(0.64))
            }.padding(.horizontal, 10).padding(.vertical, 9)
            Divider().padding(.vertical, 3)
            if model.isTopEntryPresentation { row("留在窗口", symbol: "macwindow", identifier: "window-keep") { model.keepInOrdinaryWindow?() } }
            row("最小化窗口", symbol: "minus", identifier: "window-minimize") { model.minimizeWindow?() }
            row(model.isFullScreen ? "返回窗口" : "进入全屏", symbol: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", identifier: "window-fullscreen") { model.toggleFullScreen?() }
            row("关闭窗口", symbol: "xmark", identifier: "window-close") { model.closeWindow?() }
            Divider().padding(.vertical, 3)
            row("检查更新", symbol: "arrow.down.to.line", identifier: "window-check-updates") { model.owner?.updates.checkForUpdates() }
            row("设置", symbol: "gearshape", identifier: "window-open-settings") { model.navigate(.settings) }
            // Keep an escape hatch when the user hides the menu bar item.
            if !model.preferences.menuBarVisible {
                Divider().padding(.vertical, 3)
                row("退出 DeskDen", symbol: "power", identifier: "window-quit") { _ = model.requestQuit() }
            }
        }.padding(7).frame(width: 206).foregroundStyle(model.light ? FluidNavigationColors.ink : .white)
            .workbenchThemeEnvironment(theme: model.theme, opacity: model.opacity, backgroundMotion: false, appearance: model.light ? .light : .dark)
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
    static let shadow = Color(red: 22/255, green: 64/255, blue: 75/255)
}

/// Reuses the approved desk silhouette without the app icon's cream tile.
private struct WorkbenchFluidDeskGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 3.7, y: 2.8, width: 12.6, height: 6.5), cornerSize: CGSize(width: 1.4, height: 1.4))
        path.move(to: CGPoint(x: 2.3, y: 12.5)); path.addLine(to: CGPoint(x: 17.7, y: 12.5))
        path.move(to: CGPoint(x: 3.7, y: 12.5)); path.addLine(to: CGPoint(x: 3.7, y: 16.8))
        path.move(to: CGPoint(x: 16.3, y: 12.5)); path.addLine(to: CGPoint(x: 16.3, y: 16.8))
        let ink = path.boundingRect
        let scale = min((rect.width - 1.2) / ink.width, (rect.height - 1.2) / ink.height)
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: rect.minX + 0.6 - ink.minX * scale, ty: rect.midY - ink.midY * scale))
    }
}

private struct WorkbenchFluidAccountButton: NSViewRepresentable {
    @ObservedObject var model: WorkbenchAppModel
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> WorkbenchFluidAccountMenuButton {
        WorkbenchFluidAccountMenuButton(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
    }
    func updateNSView(_ button: WorkbenchFluidAccountMenuButton, context: Context) {
        button.model = model; button.isEnabled = enabled
        button.appearance = NSAppearance(named: model.light ? .aqua : .darkAqua)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkbenchFluidAccountMenuButton, context: Context) -> CGSize? {
        CGSize(width: 32, height: 32)
    }
}

/// A native menu supplies keyboard navigation, outside-click dismissal and a
/// right-aligned anchor without the speech-bubble arrow of an NSPopover.
@MainActor final class WorkbenchFluidAccountMenuButton: ClickableButton {
    weak var model: WorkbenchAppModel?
    private(set) var activeMenu: NSMenu?
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false; title = ""; focusRingType = .none
        target = self; action = #selector(openAccountMenu)
        userInterfaceLayoutDirection = .rightToLeft
        cell?.userInterfaceLayoutDirection = .rightToLeft
        setAccessibilityRole(.button)
        setAccessibilityLabel("本机账户")
        setAccessibilityIdentifier("workbench-local-account")
        toolTip = "本机账户"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = isEnabled; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func becomeFirstResponder() -> Bool { let value = super.becomeFirstResponder(); needsDisplay = true; return value }
    override func resignFirstResponder() -> Bool { let value = super.resignFirstResponder(); needsDisplay = true; return value }
    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        let engaged = hovering || isHighlighted || focused || activeMenu != nil
        let rim = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.65, dy: 0.65))
        NSColor.white.withAlphaComponent(engaged ? 0.17 : 0.07).setFill(); rim.fill()
        NSColor.white.withAlphaComponent(engaged ? 0.88 : 0.64).setStroke(); rim.lineWidth = 1.1; rim.stroke()
        let ink = NSColor.white.withAlphaComponent(isEnabled ? 0.96 : 0.4)
        let head = NSBezierPath(ovalIn: NSRect(x: bounds.midX - 3.15, y: 7.1, width: 6.3, height: 6.3))
        ink.setStroke(); head.lineWidth = 1.3; head.stroke()
        let shoulders = NSBezierPath()
        shoulders.move(to: NSPoint(x: bounds.midX - 7, y: 24.3))
        shoulders.curve(to: NSPoint(x: bounds.midX, y: 16.7), controlPoint1: NSPoint(x: bounds.midX - 7, y: 19.5), controlPoint2: NSPoint(x: bounds.midX - 4.1, y: 16.7))
        shoulders.curve(to: NSPoint(x: bounds.midX + 7, y: 24.3), controlPoint1: NSPoint(x: bounds.midX + 4.1, y: 16.7), controlPoint2: NSPoint(x: bounds.midX + 7, y: 19.5))
        shoulders.lineWidth = 1.3; shoulders.lineCapStyle = .round; shoulders.stroke()
    }
    func makeAccountMenu() -> NSMenu {
        let menu = NSMenu(title: "本机账户")
        menu.autoenablesItems = false; menu.font = .systemFont(ofSize: 12)
        menu.minimumWidth = 156
        let fullName = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        let name = fullName.count > 22 ? String(fullName.prefix(21)) + "…" : fullName
        let account = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        account.isEnabled = false; account.toolTip = fullName + " · 本机账户"
        menu.addItem(account)
        let description = NSMenuItem(title: "当前 macOS 账户", action: nil, keyEquivalent: "")
        description.isEnabled = false
        menu.addItem(description)
        return menu
    }
    @objc private func openAccountMenu() {
        guard isEnabled, window != nil, model?.quitting == false else { return }
        let menu = makeAccountMenu()
        activeMenu = menu; highlight(true)
        defer { activeMenu = nil; highlight(false) }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX, y: bounds.maxY + 7), in: self)
    }
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
