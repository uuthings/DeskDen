import AppKit
import SwiftUI
import LauncherCore

/// The window shell has one set of metrics for every module. Large displays give
/// navigation a little more breathing room without enlarging page typography.
struct WorkbenchShellMetrics {
    let expanded: Bool
    let compact: Bool
    let chromeHeight: CGFloat
    let contentGutter: CGFloat
    let sidebarWidth: CGFloat

    init(viewport: CGSize) {
        expanded = viewport.width >= 1350 && viewport.height >= 800
        compact = viewport.width < 1000
        chromeHeight = expanded ? 50 : 46
        // Keep the existing shared scrollbar reservation inside both boundaries.
        contentGutter = (expanded ? 28 : compact ? 20 : 24) + 11
        sidebarWidth = expanded
            ? min(280, 216 + max(0, viewport.width - 1350) / 12).rounded()
            : compact ? 160 : 184
    }
}

private struct WorkbenchPageInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}
private struct WorkbenchPageScrollHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
enum WorkbenchPageScrollSpace { static let name = "workbench-page-scroll" }
extension EnvironmentValues {
    var workbenchPageInsets: EdgeInsets {
        get {self[WorkbenchPageInsetsKey.self]}
        set {self[WorkbenchPageInsetsKey.self] = newValue}
    }
    var workbenchPageScrollHeight: CGFloat {
        get {self[WorkbenchPageScrollHeightKey.self]}
        set {self[WorkbenchPageScrollHeightKey.self] = newValue}
    }
}
extension View {
    /// The document gets reading margins; its enclosing scroll view occupies
    /// the entire content viewport so the scrollbar stays at the window edge.
    func workbenchPageCanvas() -> some View {modifier(WorkbenchPageCanvas())}
}
private struct WorkbenchPageCanvas: ViewModifier {
    @Environment(\.workbenchPageInsets) private var insets
    func body(content: Content) -> some View {
        content.frame(maxWidth:1360,alignment:.topLeading).padding(insets)
            .frame(maxWidth:.infinity,alignment:.top)
    }
}

/// One content frame is shared by every module and detail. Typography never scales
/// the entire page when the window grows; useful content receives the extra space.
struct WorkbenchRootView: View {
    @ObservedObject var model: WorkbenchAppModel
    private var palette: ThemePalette { ThemePalette(theme: model.theme, opacity: model.opacity, light: model.light) }
    var body: some View {
        GeometryReader { viewport in
            let metrics = WorkbenchShellMetrics(viewport: viewport.size)
            let expanded = metrics.expanded
            let compact = metrics.compact
            let chromeHeight = metrics.chromeHeight
            let gutter = metrics.contentGutter
            let pageInsets = EdgeInsets(top:expanded ? 26:compact ? 20:22,leading:gutter,bottom:expanded || compact ? 20:16,trailing:gutter)
            ZStack(alignment: .topLeading) {
                WorkbenchSceneBackground(theme: model.theme, motionEnabled: model.backgroundMotion && !model.reduceMotion, active: model.windowVisible)
                VStack(spacing: 0) {
                    chrome(expanded: expanded).frame(height: chromeHeight)
                        .background(WorkbenchMaterialSurface(kind: .chrome, radius: 0))
                        .overlay(alignment:.bottom) {Rectangle().fill(palette.line).frame(height:1)}
                    HStack(spacing: 0) {
                        sidebar(expanded: expanded).frame(width: metrics.sidebarWidth)
                            .background(WorkbenchMaterialSurface(kind: .sidebar, radius: 0))
                            .overlay(alignment:.trailing) {Rectangle().fill(palette.line).frame(width:1)}
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("workbench-sidebar")
                        content(gutter: gutter, expanded: expanded, compact:compact)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .environment(\.workbenchPageInsets,pageInsets)
                    }
                }.padding(1)
                    .disabled(model.modals.isPresented || model.confirmingQuit || model.quitting)
                    .accessibilityHidden(model.modals.isPresented || model.confirmingQuit)
                if model.brandMenuPresented {
                    Color.clear.contentShape(Rectangle()).onTapGesture { model.brandMenuPresented = false }
                    WorkbenchBrandMenu(model: model, dismiss: { model.brandMenuPresented = false }).offset(x: 14, y: chromeHeight - 2)
                }
                WorkbenchModalHost(coordinator:model.modals)
                WorkbenchContextDialogs(model:model.context)
                CalendarDialogs(model:model.calendar,context:model.context)
                WorkbenchStatusMessages(model:model)
                if model.confirmingQuit { WorkbenchQuitConfirmation(model: model) }
            }
            .environment(\.workbenchScale, 1)
            .environment(\.workbenchDeviceExpanded, expanded)
            .environment(\.workbenchContentHeight, max(0, viewport.size.height - chromeHeight - 2 - (expanded ? 26:compact ? 20:22) - (expanded || compact ? 20:16)))
            .environment(\.workbenchPageScrollHeight, max(0, viewport.size.height - chromeHeight - 2))
        }
        .clipShape(RoundedRectangle(cornerRadius: model.isFullScreen ? 0 : WorkbenchViewport.windowRadius))
        .overlay(RoundedRectangle(cornerRadius: model.isFullScreen ? 0 : WorkbenchViewport.windowRadius).strokeBorder(palette.border.opacity(model.isFullScreen ? 0 : 1), lineWidth: 1).allowsHitTesting(false))
        .workbenchThemeEnvironment(theme: model.theme, opacity: model.opacity, backgroundMotion: model.backgroundMotion && !model.reduceMotion, appearance: model.appearance)
        .environment(\.workbenchModals,model.modals)
        .ignoresSafeArea(.container, edges: .top)
        .tint(palette.accent).controlSize(.regular)
        .font(.system(size: 12)).foregroundStyle(palette.text)
        .onExitCommand {
            model.cancelPresentedInteraction()
        }
        .onChange(of: model.route) { _, _ in model.brandMenuPresented = false }
        .onChange(of: model.windowVisible) { _, visible in if !visible { model.brandMenuPresented = false } }
    }
    private func chrome(expanded: Bool) -> some View {
        HStack(spacing: 12) {
            Button { model.brandMenuPresented.toggle() } label: {
                HStack(spacing: 8) {
                    WorkbenchBrandMark().frame(width: 25, height: 25)
                    Text("方寸").font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }.padding(.leading, 4).padding(.trailing, 8).frame(height: 32)
            }.buttonStyle(WorkbenchChromeButtonStyle()).accessibilityLabel("方寸菜单").accessibilityIdentifier("window-brand-trigger")
            Spacer(minLength: 12)
            if model.isTopEntryPresentation {
                Button { model.keepInOrdinaryWindow?() } label: { Label("留在窗口", systemImage: "macwindow") }
                    .buttonStyle(WBQuietButtonStyle()).help("转为普通窗口，切换应用时按系统窗口顺序显示")
            }
            WorkbenchUptime(device: model.device)
            WorkbenchWindowIconControls(model: model)
        }.padding(.horizontal, 14)
    }
    @ViewBuilder private func content(gutter: CGFloat, expanded: Bool, compact:Bool) -> some View {
        if model.route == .device {
            DeviceModuleView(model: model.device, onOpenNetwork:{model.navigate(.network)},onOpenHealth:model.openHealth, requestedDetail:$model.deviceDetail,requestedDetailReturnTitle:model.requestedReadingReturnTitle,onCloseRequestedDetail:model.closeRequestedDeviceDetail)
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        } else if model.route == .cleaning {
            SpaceCleaningModuleView(model:model.cleaning,onLegacyHistory:model.health.storage.receipts.isEmpty ? nil:{model.navigate(.health);model.health.showResults(kind:.files)})
                .workbenchPageCanvas()
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        } else if model.route == .network {
            NetworkMonitorView(model:model.device)
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        } else {
            ScrollViewReader {scroll in
              let resetToTop = { DispatchQueue.main.async {scroll.scrollTo("workbench-page-top",anchor:.top)} }
              ScrollView {
                Group {
                    switch model.route {
                    case .overview: WorkbenchOverview(device: model.device, calendar: model.calendar, health:model.health,context:model.context,navigate:model.navigate,openHealth:model.openHealth,openDevice:model.openDeviceReading)
                    case .device: EmptyView()
                    case .health: HealthCenterView(model:model.health,onReadDevice:model.openHealthReading,onOpenCleaning:{model.navigate(.cleaning)})
                    case .cleaning: EmptyView()
                    case .calendar: CalendarModuleView(model: model.calendar,context:model.context,returnToSettingsPrivacy:{model.navigate(.settings);model.settingsTab = .privacy})
                    case .network: EmptyView()
                    case .ai: AIUsageModuleView(model: model.ai, openDesktopCards: { model.navigate(.cards) },returnToSettingsPrivacy:{model.navigate(.settings);model.settingsTab = .privacy})
                    case .vault: VaultModuleView(model: model.vault,returnToSettingsPrivacy:{model.navigate(.settings);model.settingsTab = .privacy})
                    case .cards: DesktopCardsView(cards: model.preferences.cards, update: model.updateCard, openDesktop: { model.showDesktop?() }, device: model.device, calendar: model.calendar, ai: model.ai)
                    case .settings: WorkbenchSettingsView(model: model)
                    }
                }
                .workbenchPageCanvas()
                .id("workbench-page-top")
                .background(WorkbenchOverlayScrollbars())
              }.scrollContentBackground(.hidden).scrollBounceBehavior(.basedOnSize)
                .coordinateSpace(name: WorkbenchPageScrollSpace.name)
                .onChange(of:model.route) {_,_ in resetToTop()}
                .onChange(of:model.settingsTab) {_,_ in if model.route == .settings {resetToTop()}}
                .onReceive(model.ai.$destination.removeDuplicates()) {_ in if model.route == .ai {resetToTop()}}
                .onReceive(model.calendar.$showSources.removeDuplicates()) {_ in if model.route == .calendar {resetToTop()}}
                .onReceive(model.vault.$showingProtection.removeDuplicates()) {_ in if model.route == .vault {resetToTop()}}
                .onReceive(model.cleaning.$screen.removeDuplicates()) {_ in if model.route == .cleaning {resetToTop()}}
                .onReceive(model.health.$phase.removeDuplicates()) {_ in if model.route == .health {resetToTop()}}
                .onReceive(model.health.$category.removeDuplicates()) {_ in if model.route == .health {resetToTop()}}
                .onReceive(model.health.$resultKind.removeDuplicates()) {_ in if model.route == .health {resetToTop()}}
            }
        }
    }
    private func sidebar(expanded: Bool) -> some View {
        VStack(alignment:.leading,spacing:6) {
            if model.route == .settings {
                Button {model.returnFromSettings()} label:{
                    HStack(spacing:10) {Image(systemName:"arrow.left").frame(width:18).accessibilityHidden(true);Text("返回方寸");Spacer(minLength:0)}
                        .padding(.horizontal,12).frame(height:expanded ? 46:42)
                        .contentShape(RoundedRectangle(cornerRadius:9))
                }.buttonStyle(ClickablePlainButtonStyle()).foregroundStyle(palette.secondary)
                ForEach(WorkbenchSettingsTab.allCases,id:\.self) {tab in
                    Button {model.settingsTab=tab} label:{
                        HStack(spacing:10) {
                            Image(systemName:tab.symbol).font(.system(size:16,weight:.light)).frame(width:18)
                                .foregroundStyle(model.settingsTab == tab ? palette.accent:palette.secondary)
                                .accessibilityHidden(true)
                            Text(tab.title).font(.system(size:expanded ? 13:12));Spacer(minLength:0)
                        }.padding(.horizontal,12).frame(height:expanded ? 46:42)
                            .foregroundStyle(model.settingsTab == tab ? palette.text:palette.secondary)
                            .background {if model.settingsTab == tab {WorkbenchMaterialSurface(kind:.selected,radius:9)}}
                            .contentShape(RoundedRectangle(cornerRadius:9))
                    }.buttonStyle(ClickablePlainButtonStyle()).accessibilityElement(children:.ignore).accessibilityAddTraits(.isButton).accessibilityLabel(tab.title).accessibilityValue(model.settingsTab == tab ? "当前页面":"").accessibilityAddTraits(model.settingsTab == tab ? .isSelected:[]).accessibilityRemoveTraits(model.settingsTab == tab ? []:.isSelected)
                        .accessibilityIdentifier("settings-navigation-"+tab.rawValue)
                }
                Spacer(minLength:24)
                Text("方寸").font(.system(size:11)).foregroundStyle(palette.muted).padding(.horizontal,12)
            } else {
                ForEach([WorkbenchRoute.overview,.device,.health,.cleaning,.calendar,.ai,.network,.vault],id:\.self) {route in navigation(route,expanded:expanded)}
                navigation(.cards,expanded:expanded)
                Spacer(minLength:0)
                Button {model.launcher()} label:{
                    HStack(spacing:10) {
                        Image(systemName:"command").font(.system(size:16,weight:.light)).frame(width:18)
                            .accessibilityHidden(true)
                        Text("启动器").font(.system(size:expanded ? 13:12));Spacer(minLength:0)
                    }.padding(.horizontal,12).frame(height:expanded ? 46:42)
                        .contentShape(RoundedRectangle(cornerRadius:9))
                }.buttonStyle(ClickablePlainButtonStyle()).foregroundStyle(palette.muted).accessibilityLabel("启动器").accessibilityIdentifier("navigation-launcher")
                navigation(.settings,expanded:expanded)
            }
        }.padding(.horizontal,12).padding(.top,22).padding(.bottom,15)
    }
    private func navigation(_ route: WorkbenchRoute, expanded: Bool) -> some View {
        Button { if route == .health {model.openHealth()} else {if route == .ai {model.ai.showOverview()};model.navigate(route)} } label: {
            HStack(spacing: 10) {
                Image(systemName: route.symbol).font(.system(size: 16, weight: .light)).frame(width: 18)
                    .foregroundStyle(model.route == route ? palette.accent : palette.secondary)
                    .accessibilityHidden(true)
                Text(route == .overview ? "首页" : route == .vault ? "私密空间" : route.title).font(.system(size: expanded ? 13 : 12))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: expanded ? 46 : 42)
            .foregroundStyle(model.route == route ? palette.text : palette.secondary)
            .background {
                if model.route == route { WorkbenchMaterialSurface(kind: .selected, radius: 9) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(ClickablePlainButtonStyle()).accessibilityElement(children:.ignore).accessibilityAddTraits(.isButton).accessibilityLabel(route == .overview ? "首页":route == .vault ? "私密空间":route.title).accessibilityValue(model.route == route ? "当前页面" : "").accessibilityAddTraits(model.route == route ? .isSelected:[]).accessibilityRemoveTraits(model.route == route ? []:.isSelected).accessibilityIdentifier("navigation-" + route.rawValue)
    }
}

private struct WorkbenchStatusMessages:View {
    @ObservedObject var model:WorkbenchAppModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        ZStack(alignment:.bottom) {
            Color.clear.frame(width:0,height:0)
                .workbenchModal(isPresented:Binding(get:{model.message != nil},set:{if !$0 {model.message=nil}})) {
                    WorkbenchStatusMessageDialog(model:model)
                }
            if let toast=model.toast {
                Text(toast).font(.system(size:12)).foregroundStyle(palette.text).padding(.horizontal,16).padding(.vertical,10)
                    .background(WorkbenchMaterialSurface(kind:.panel,radius:10)).padding(.bottom,18)
                    .allowsHitTesting(false).accessibilityIdentifier("workbench-toast")
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottom).allowsHitTesting(false)
            .task(id:model.toast) {
                let shown=model.toast;guard shown != nil else {return}
                do {try await Task.sleep(for:.seconds(3))}catch{return}
                if model.toast == shown {model.toast=nil}
            }
    }
}

/// A second asynchronous failure may replace a message while it is visible.
/// Observe the model inside the retained modal instead of caching its first text.
struct WorkbenchStatusMessageDialog:View {
    @ObservedObject var model:WorkbenchAppModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        WorkbenchDialogFrame(title:"方寸",dismiss:{model.message=nil}) {
            Text(model.message ?? "").font(.system(size:12)).foregroundStyle(palette.secondary).fixedSize(horizontal:false,vertical:true)
                .accessibilityIdentifier("workbench-status-message-text")
        }actions:{Spacer();Button("知道了"){model.message=nil}.buttonStyle(WBButtonStyle(primary:true))}
    }
}
