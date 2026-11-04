import AppKit
import SwiftUI
import LauncherCore

/// Resizing gives space to page content, never to window chrome or navigation.
struct WorkbenchShellMetrics {
    let chromeHeight: CGFloat
    let contentGutter: CGFloat
    let sidebarWidth: CGFloat
    let pageWidth: CGFloat

    init(viewport: CGSize, home: Bool = false) {
        chromeHeight = 58
        // Fixed reading margins are independent of scrollbar presence.
        contentGutter = 24
        sidebarWidth = 0
        pageWidth = max(0, viewport.width - 2 - 2 * contentGutter)
    }
}

private struct WorkbenchPageInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}
private struct WorkbenchPageScrollHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}
private struct WorkbenchPageWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 864
}
private struct WorkbenchPageMaximumWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
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
    /// Derived from the hosting viewport, independent of a page's intrinsic size.
    var workbenchPageWidth: CGFloat {
        get {self[WorkbenchPageWidthKey.self]}
        set {self[WorkbenchPageWidthKey.self] = newValue}
    }
    var workbenchPageMaximumWidth: CGFloat {
        get {self[WorkbenchPageMaximumWidthKey.self]}
        set {self[WorkbenchPageMaximumWidthKey.self] = newValue}
    }
}
extension View {
    /// The document gets reading margins; its enclosing scroll view occupies
    /// the entire content viewport so the scrollbar stays at the window edge.
    func workbenchPageCanvas() -> some View {modifier(WorkbenchPageCanvas())}
}
private struct WorkbenchPageCanvas: ViewModifier {
    @Environment(\.workbenchPageInsets) private var insets
    @Environment(\.workbenchPageMaximumWidth) private var maximumWidth
    func body(content: Content) -> some View {
        content.frame(maxWidth:maximumWidth,alignment:.topLeading).padding(insets)
            .frame(maxWidth:.infinity,alignment:.top)
    }
}

/// One content frame is shared by every module and detail. Typography never scales
/// the entire page when the window grows; useful content receives the extra space.
struct WorkbenchRootView: View {
    @ObservedObject var model: WorkbenchAppModel
    private var blocked: Bool { model.modals.isPresented || model.confirmingQuit || model.quitting }
    var body: some View {
        ZStack(alignment: .top) {
            WorkbenchAppearanceScene(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            WorkbenchFluidNavigation(model: model)
                .frame(height: 58).padding(1)
                .blur(radius: blocked ? 8 : 0)
                .disabled(blocked)
                .allowsHitTesting(!blocked)
                .accessibilityHidden(blocked)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workbench-chrome")
        }
        .workbenchThemeEnvironment(theme: model.theme, opacity: model.opacity, backgroundMotion: false, appearance: model.appearance)
        .tint(ThemePalette(light: model.light).accent).controlSize(.regular)
        .font(.system(size: 12))
        .ignoresSafeArea(.container, edges: .top)
        .onExitCommand { model.cancelPresentedInteraction() }
    }
}

struct WorkbenchSceneView: View {
    @ObservedObject var model: WorkbenchAppModel
    private var home: Bool { model.route == .overview }
    private var palette: ThemePalette { ThemePalette(light: model.light) }
    private var windowRadius: CGFloat { model.isFullScreen ? 0 : 16 }
    var body: some View {
        GeometryReader { viewport in
            let metrics = WorkbenchShellMetrics(viewport: viewport.size, home: home)
            let chromeHeight = metrics.chromeHeight
            let settingsHeight: CGFloat = model.route == .settings ? 52 : 0
            let gutter = metrics.contentGutter
            let pageInsets = EdgeInsets(top:24,leading:gutter,bottom:32,trailing:gutter)
            ZStack(alignment: .topLeading) {
                WorkbenchFluidBackground()
                VStack(spacing: 0) {
                    // Navigation is a live sibling of the fading scene. This
                    // reserves exactly the same layout space without duplicating it.
                    Color.clear.frame(height: chromeHeight).accessibilityHidden(true)
                    if model.route == .settings {
                        WorkbenchFluidSettingsNavigation(model: model).frame(height: settingsHeight)
                    }
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .environment(\.workbenchPageInsets,pageInsets)
                }.padding(1)
                    .blur(radius: model.modals.isPresented || model.confirmingQuit || model.quitting ? 8 : 0)
                    .disabled(model.modals.isPresented || model.confirmingQuit || model.quitting)
                    .accessibilityHidden(model.modals.isPresented || model.confirmingQuit)
                WorkbenchModalHost(coordinator:model.modals)
                WorkbenchContextDialogs(model:model.context)
                CalendarDialogs(model:model.calendar,context:model.context)
                if let owner = model.owner { WorkbenchUpdatePresentation(updates: owner.updates) }
                WorkbenchStatusMessages(model:model)
                if model.confirmingQuit { WorkbenchQuitConfirmation(model: model) }
            }
            .environment(\.workbenchScale, 1)
            .environment(\.workbenchDeviceExpanded, false)
            .environment(\.workbenchPageWidth, metrics.pageWidth)
            .environment(\.workbenchPageMaximumWidth, .infinity)
            .environment(\.workbenchContentHeight, max(0, viewport.size.height - chromeHeight - settingsHeight - 2 - pageInsets.top - pageInsets.bottom))
            .environment(\.workbenchPageScrollHeight, max(0, viewport.size.height - chromeHeight - settingsHeight - 2))
        }
        .clipShape(RoundedRectangle(cornerRadius: windowRadius))
        .overlay(RoundedRectangle(cornerRadius: windowRadius).strokeBorder(Color.white.opacity(model.isFullScreen ? 0 : 0.57), lineWidth: 1).allowsHitTesting(false))
        .workbenchThemeEnvironment(theme: model.theme, opacity: model.opacity, backgroundMotion: false, appearance: model.appearance)
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
    @ViewBuilder private var content: some View {
        if model.route == .device {
            DeviceModuleView(model: model.device, onOpenNetwork:{model.navigate(.network)},onOpenCleaning:{model.navigate(.cleaning)}, requestedDetail:$model.deviceDetail,requestedDetailReturnTitle:model.requestedReadingReturnTitle,onCloseRequestedDetail:model.closeRequestedDeviceDetail)
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        } else if model.route == .cleaning {
            SpaceCleaningModuleView(model:model.cleaning)
                .environment(\.timeZone, model.context.dateContext.timeZone)
                .workbenchPageCanvas()
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        } else if model.route == .network {
            NetworkMonitorView(model:model.device)
                .environment(\.timeZone, model.context.dateContext.timeZone)
                .environment(\.usageDisplayLocation, model.context.locationTitle)
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        } else {
            ScrollViewReader {scroll in
              let resetToTop = { DispatchQueue.main.async {scroll.scrollTo("workbench-page-top",anchor:.top)} }
              WorkbenchScrollView {
                Group {
                    switch model.route {
                    case .overview: WorkbenchOverview(device: model.device, calendar: model.calendar,context:model.context,cleaning:model.cleaning,navigate:{ route in
                        if route == .ai { model.openUsageOverview() } else { model.navigate(route) }
                    },openDevice:{model.openDeviceReading($0)},reduceMotion:model.reduceMotion)
                    case .device: EmptyView()
                    case .cleaning: EmptyView()
                    case .calendar: CalendarModuleView(model: model.calendar,context:model.context,returnToSettingsPrivacy:{model.navigate(.settings);model.settingsTab = .privacy})
                    case .network: EmptyView()
                    case .ai: UsageStatisticsView(app:model)
                    case .vault: VaultModuleView(model: model.vault,returnToSettingsPrivacy:{model.navigate(.settings);model.settingsTab = .privacy})
                    case .cards: DesktopCardsView(cards: model.preferences.cards, update: model.updateCard, openDesktop: { model.showDesktop?() }, device: model.device, calendar: model.calendar, ai: model.ai)
                    case .settings: WorkbenchSettingsView(model: model)
                    }
                }
                .workbenchPageCanvas()
                .id("workbench-page-top")
              }.scrollContentBackground(.hidden).scrollBounceBehavior(.basedOnSize)
                .coordinateSpace(name: WorkbenchPageScrollSpace.name)
                .onChange(of:model.route) {_,_ in resetToTop()}
                .onChange(of:model.settingsTab) {_,_ in if model.route == .settings {resetToTop()}}
                .onReceive(model.ai.$destination.removeDuplicates()) {_ in if model.route == .ai {resetToTop()}}
                .onReceive(model.usagePresentation.$selectedSourceID.removeDuplicates()) {_ in if model.route == .ai {resetToTop()}}
                .onReceive(model.calendar.$showSources.removeDuplicates()) {_ in if model.route == .calendar {resetToTop()}}
                .onReceive(model.vault.$showingProtection.removeDuplicates()) {_ in if model.route == .vault {resetToTop()}}
                .onReceive(model.cleaning.$screen.removeDuplicates()) {_ in if model.route == .cleaning {resetToTop()}}
            }
        }
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
