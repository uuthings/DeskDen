import AppKit
import SwiftUI
import LauncherCore

/// The approved header keeps its center independent of the brand and account
/// controls. A second expanded item is reserved for hover or keyboard focus.
struct WorkbenchFluidNavigation: View {
    @ObservedObject var model: WorkbenchAppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var hoveredRoute: WorkbenchRoute?
    @State private var pressedRoute: WorkbenchRoute?
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var focusedRoute: WorkbenchRoute?
    private let routes: [WorkbenchRoute] = [.overview, .device, .cleaning, .calendar, .ai, .network, .vault]
    private var motion: Animation? { FluidNavigationMotion.transition(disabled: model.reduceMotion || systemReduceMotion) }

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                brand
                if let owner = model.owner { WorkbenchFluidUpdateEntry(updates: owner.updates) }
                Spacer(minLength: 0)
                HStack(spacing: 11) {
                    WorkbenchFluidAppearanceButton(model: model)
                    WorkbenchFluidRoundButton(symbol: "gearshape", title: "设置", selected: model.route == .settings, suppressMotion: model.reduceMotion) {
                        model.selectModule(.settings)
                    }.accessibilityIdentifier("navigation-settings")
                    WorkbenchFluidAccountButton(model: model).frame(width: 32, height: 32)
                    WorkbenchFluidRoundButton(symbol: "xmark", title: "关闭窗口", suppressMotion: model.reduceMotion) {
                        model.closeWindow?()
                    }.accessibilityIdentifier("window-close")
                        .accessibilityHint("收起主窗口，后台继续运行")
                }
            }
            HStack(spacing: 7) {
                ForEach(routes, id: \.self) { route in navigation(route) }
            }.frame(width: 358, height: 32)
                .animation(motion, value: hoveredRoute)
                .animation(motion, value: focusedRoute)
                .animation(motion, value: model.route)
                .overlay {
                    WorkbenchFluidNavigationInput(routes: routes, selected: model.route,
                        expanded: hoveredRoute ?? focusedRoute,
                        hover: { route in
                            if let route { trackHover(route) } else { finishHover() }
                        }, press: { pressedRoute = $0 }, activate: { _ = model.selectModule($0) })
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("主导航")
                .accessibilityIdentifier("workbench-top-navigation")
        }.padding(.horizontal, 24).frame(height: 58)
            .onChange(of: model.windowVisible) { _, visible in if !visible { resetHover() } }
            .onDisappear { resetHover() }
    }

    private var brand: some View {
        HStack(spacing: 7) {
            WorkbenchFluidDeskGlyph().stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .frame(width: 20, height: 20).accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("DeskDen").font(.system(size: 14, weight: .medium)).tracking(0.25)
                Text(version).font(.system(size: 10)).foregroundStyle(.white.opacity(0.90))
                    .accessibilityIdentifier("fc.home.version")
            }.fixedSize()
        }.foregroundStyle(.white).padding(.vertical, 3)
            .accessibilityElement(children: .contain).accessibilityLabel("DeskDen " + version)
            .accessibilityIdentifier("window-brand")
    }

    private var version: String {
        "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
    }

    private func navigation(_ route: WorkbenchRoute) -> some View {
        let selected = model.route == route
        let expanded = selected || (hoveredRoute ?? focusedRoute) == route
        return Button { model.selectModule(route) } label: {
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
                .opacity(pressedRoute == route ? 0.82 : 1)
                .animation(model.reduceMotion || systemReduceMotion ? nil : .easeOut(duration: 0.16), value: pressedRoute == route)
        }.buttonStyle(FluidNavigationButtonStyle(suppressMotion: model.reduceMotion, managesCursor: false)).focused($focusedRoute, equals: route).focusEffectDisabled()
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
    private func trackHover(_ route: WorkbenchRoute) {
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
        hoverTask?.cancel(); hoverTask = nil; hoveredRoute = nil; pressedRoute = nil
    }
}

/// One fixed native input surface owns pointer tracking for the complete strip.
/// The SwiftUI capsules below it may animate without moving cursor rectangles or
/// generating a new hover target. Their Buttons retain keyboard and AX actions.
private struct WorkbenchFluidNavigationInput: NSViewRepresentable {
    let routes: [WorkbenchRoute]
    let selected: WorkbenchRoute
    let expanded: WorkbenchRoute?
    let hover: (WorkbenchRoute?) -> Void
    let press: (WorkbenchRoute?) -> Void
    let activate: (WorkbenchRoute) -> Void

    func makeNSView(context: Context) -> WorkbenchFluidNavigationInputView {
        WorkbenchFluidNavigationInputView(frame: .zero)
    }
    func updateNSView(_ view: WorkbenchFluidNavigationInputView, context: Context) {
        view.routes = routes; view.selected = selected; view.expanded = expanded
        view.onHover = hover; view.onPress = press; view.onActivate = activate
    }
}

final class WorkbenchFluidNavigationInputView: ClickableCursorView {
    var routes: [WorkbenchRoute] = []
    var selected: WorkbenchRoute = .overview { didSet { if oldValue != selected { preservePointerIntent() } } }
    var expanded: WorkbenchRoute? { didSet { if oldValue != expanded { preservePointerIntent() } } }
    var onHover: ((WorkbenchRoute?) -> Void)?
    var onPress: ((WorkbenchRoute?) -> Void)?
    var onActivate: ((WorkbenchRoute) -> Void)?
    private var trackedRoute: WorkbenchRoute?
    private var trackedPoint: CGPoint?
    private var intentAnchor: CGPoint?
    private var pressed: (route: WorkbenchRoute, point: CGPoint)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard enabled, !isHiddenOrHasHiddenAncestor,
              bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateTarget(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        // A layout/cursor refresh at the same location is not new user intent.
        if trackedPoint.map({ hypot(point.x - $0.x, point.y - $0.y) > 0.25 }) ?? true {
            updateTarget(at: point)
        }
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard !containsPointer else { return }
        trackedRoute = nil; trackedPoint = nil; intentAnchor = nil; toolTip = nil
        onHover?(nil)
    }
    override func mouseDown(with event: NSEvent) {
        pressed = nil
        let point = convert(event.locationInWindow, from: nil)
        // Preserve the route that the physical pointer entered while its label
        // is still expanding, instead of letting the moving capsule choose it.
        let stationary = trackedPoint.map { hypot(point.x - $0.x, point.y - $0.y) <= 1 } == true
        if let route = stationary ? trackedRoute : route(at: point) {
            pressed = (route, point); onPress?(route)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let pressed, hypot(point.x - pressed.point.x, point.y - pressed.point.y) > 4 {
            self.pressed = nil; onPress?(nil)
        }
    }
    override func mouseUp(with event: NSEvent) {
        let press = pressed; pressed = nil; onPress?(nil)
        let point = convert(event.locationInWindow, from: nil)
        guard let press, bounds.contains(point),
              hypot(point.x - press.point.x, point.y - press.point.y) <= 4 else { return }
        onActivate?(press.route)
    }
    private func updateTarget(at point: CGPoint) {
        trackedPoint = point
        // Selecting the hovered item can recenter the strip by 23 points. Keep
        // its existing intent through ordinary hand jitter, but do not enlarge
        // its hit rectangle over an adjacent visible button.
        if trackedRoute != nil, let intentAnchor,
           hypot(point.x - intentAnchor.x, point.y - intentAnchor.y) <= 4 { return }
        intentAnchor = nil
        guard let route = route(at: point) else {
            if trackedRoute != nil { trackedRoute = nil; toolTip = nil; onHover?(nil) }
            return
        }
        guard trackedRoute != route else { return }
        trackedRoute = route; toolTip = route.title
        onHover?(route)
    }
    private func preservePointerIntent() {
        if trackedRoute != nil { intentAnchor = trackedPoint }
    }
    private func route(at point: CGPoint) -> WorkbenchRoute? {
        guard bounds.contains(point), !routes.isEmpty else { return nil }
        let widths = routes.map { $0 == selected || $0 == expanded ? CGFloat(78) : 32 }
        let total = widths.reduce(0, +) + CGFloat(max(0, routes.count - 1)) * 7
        var x = bounds.midX - total / 2
        guard point.x >= x, point.x <= x + total else { return nil }
        for (index, route) in routes.enumerated() {
            let width = widths[index]
            if point.x <= x + width + 3.5 || index == routes.count - 1 { return route }
            x += width + 7
        }
        return nil
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
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.31), lineWidth: 1))
                .contentShape(Capsule())
        }.buttonStyle(FluidNavigationButtonStyle(suppressMotion: suppressMotion)).focused($focused).focusEffectDisabled().onHover { hovered = $0 }
            .animation(FluidNavigationMotion.transition(disabled: reduceMotion || suppressMotion), value: hovered || focused || selected)
            .accessibilityLabel(tab.title).accessibilityValue(selected ? "当前页面" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("settings-navigation-" + tab.rawValue)
    }
}

/// The native Button keeps a fixed hit/focus frame while its two-sided face
/// turns. There is no delayed state change or queued completion: a second click
/// immediately reverses the presentation toward the current appearance.
private struct WorkbenchFluidAppearanceButton: View {
    @ObservedObject var model: WorkbenchAppModel
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var disableMotion: Bool { model.reduceMotion || systemReduceMotion }
    private var title: String { model.light ? "切换深色模式" : "切换浅色模式" }
    private var angle: Double { model.light ? 0 : 180 }

    var body: some View {
        Button { model.changeLight(!model.light) } label: {
            ZStack {
                if disableMotion {
                    // A separate static branch also stops a turn immediately
                    // if Reduce Motion is enabled while it is in flight.
                    WorkbenchFluidAppearanceFace(angle: angle, highlighted: hovered || focused)
                        .transaction { $0.animation = nil }
                } else {
                    WorkbenchFluidAppearanceFace(angle: angle, highlighted: hovered || focused)
                        .animation(.timingCurve(0.35, 0, 0.20, 1, duration: 0.34), value: model.light)
                }
            }.frame(width: 32, height: 32).contentShape(Circle())
                .background(WorkbenchAppearanceLiveRegion().accessibilityHidden(true))
        }.buttonStyle(FluidNavigationButtonStyle(suppressMotion: disableMotion))
            .focused($focused).focusEffectDisabled().onHover { hovered = $0 }
            .animation(FluidNavigationMotion.transition(disabled: disableMotion), value: hovered || focused)
            .accessibilityLabel(title).accessibilityValue(model.light ? "浅色" : "深色")
            .accessibilityIdentifier("fc.home.appearance.toggle").help(title)
    }
}

private struct WorkbenchFluidAppearanceFace: View, @MainActor Animatable {
    var angle: Double
    let highlighted: Bool
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    var body: some View {
        let front = angle < 90
        Image(systemName: front ? "moon" : "sun.max")
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(Color.white.opacity(highlighted ? 1 : 0.88))
            .frame(width: 32, height: 32)
            .background { FluidNavigationRoundSurface(highlighted: highlighted, selected: false) }
            // Change faces only at the edge; subtracting the half turn keeps
            // the back icon readable instead of displaying a mirrored glyph.
            .rotation3DEffect(.degrees(front ? angle : angle - 180),
                axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.28)
            .accessibilityHidden(true)
    }
}

/// The same thin, softly lit surface is shared by all circular header actions.
/// Hover changes light within the existing circle; neither bounds nor scale move.
private struct FluidNavigationRoundSurface: View {
    let highlighted: Bool
    let selected: Bool
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [
                Color.white.opacity(selected ? 0.96 : highlighted ? 0.15 : 0.045),
                Color.white.opacity(selected ? 0.91 : highlighted ? 0.055 : 0.018)
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Circle().strokeBorder(LinearGradient(colors: [
                    Color.white.opacity(selected ? 1 : highlighted ? 0.47 : 0.35),
                    Color.white.opacity(selected ? 0.85 : highlighted ? 0.23 : 0.20)
                ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
            .shadow(color: Color.white.opacity(highlighted && !selected ? 0.055 : 0), radius: 4)
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
                .foregroundStyle(selected ? FluidNavigationColors.ink : .white.opacity(engaged ? 1 : 0.88))
                .background { FluidNavigationRoundSurface(highlighted: engaged, selected: selected) }
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
    var managesCursor = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if managesCursor { configuration.label.contentShape(Rectangle()).clickableCursor() }
            else { configuration.label.contentShape(Rectangle()) }
        }
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion || suppressMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
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

private struct WorkbenchFluidAccountButton: View {
    @ObservedObject var model: WorkbenchAppModel
    @State private var presented = false
    private var accountName: String { NSFullUserName().isEmpty ? NSUserName() : NSFullUserName() }
    var body: some View {
        WorkbenchFluidRoundButton(symbol: "person", title: "本机账户", selected: presented, suppressMotion: model.reduceMotion) {
            presented.toggle()
        }.accessibilityIdentifier("workbench-local-account")
            .workbenchPopover(isPresented: $presented, width: 240, alignment: .trailing) {
                HStack(spacing: 11) {
                    Image(systemName: "person.crop.circle").font(.system(size: 28, weight: .light))
                        .foregroundStyle(model.light ? FluidNavigationColors.secondary : Color.white.opacity(0.72))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(accountName).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text("当前 macOS 账户").font(.system(size: 11))
                            .foregroundStyle(model.light ? FluidNavigationColors.secondary : Color.white.opacity(0.64))
                    }
                    Spacer(minLength: 0)
                }.foregroundStyle(model.light ? FluidNavigationColors.ink : .white).padding(14)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("workbench-account-menu")
            }
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
