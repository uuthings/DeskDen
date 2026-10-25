import AppKit
import Combine
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import QuartzCore
import LauncherCore

extension Notification.Name { static let fangcunConfigurationChanged=Notification.Name("local.fangcun.configuration.changed") }
enum WorkbenchSettingsTab:String,CaseIterable {
    case general,material,launcher,privacy,audit
    var title:String {switch self {case .general:"通用";case .material:"外观与材质";case .launcher:"启动器";case .privacy:"隐私与锁定";case .audit:"功能审计"}}
    var symbol:String {switch self {case .general:"slider.horizontal.3";case .material:"circle.lefthalf.filled";case .launcher:"command";case .privacy:"checkmark.shield";case .audit:"list.bullet.rectangle"}}
    var subtitle:String {switch self {case .general:"管理启动方式、工作台入口与数据更新";case .material:"工作台、启动器与浮层使用同一套外观";case .launcher:"调整启动方式、按键绑定与搜索";case .privacy:"管理个人内容、数据来源与访问权限";case .audit:"查看各模块的数据来源与可用状态"}}
}

struct WorkbenchAuditEntry:Codable,Identifiable {var id:String;var title:String;var state:String;var detail:String}

@MainActor final class WorkbenchAppModel:ObservableObject {
    weak var owner:LauncherController?
    let dataDirectory:URL
    let preferenceStore:WorkbenchPreferenceStore
    let device:DeviceStatusModel
    let health:HealthCenterModel
    let cleaning:SpaceCleaningModel
    let context:WorkbenchContextModel
    let modals=WorkbenchModalCoordinator()
    let calendar:CalendarModel
    let ai:AIUsageModel
    let vault:VaultModel
    private(set) var widgets:DesktopWidgetsController!
    @Published var route:WorkbenchRoute = .overview
    @Published var deviceDetail:DeviceCardID?
    private var readingReturnRoute:WorkbenchRoute?
    @Published var settingsTab:WorkbenchSettingsTab = .general
    @Published private(set) var settingsReturnRoute:WorkbenchRoute = .overview
    @Published var isFullScreen=false
    @Published private(set) var isTopEntryPresentation=false
    @Published var launcherSection=0
    @Published private(set) var preferences=WorkbenchPreferences()
    @Published private(set) var opacity=0.70
    @Published private(set) var theme:LauncherTheme = .arWorld
    @Published private(set) var backgroundMotion=true
    @Published private(set) var reduceMotion=false
    @Published var brandMenuPresented=false
    @Published var confirmingQuit=false {
        didSet {
            // All dismissals, including Escape and "close window only", release
            // a pending native .terminateLater request without ending the app.
            if !confirmingQuit && !quitting {owner?.cancelPendingSystemTermination()}
        }
    }
    @Published private(set) var quitting=false
    @Published private(set) var light=false
    @Published private(set) var appearance:LauncherAppearance = .dark
    @Published private(set) var buttonHoverCursor:ButtonHoverCursor = .pointingHand
    @Published private(set) var loginEnabled=false
    @Published private(set) var loginNeedsApproval=false
    @Published var message:String?
    @Published var toast:String?
    @Published var auditStorageResult="尚未检查"
    @Published var lastAudit:Date?
    weak var hostWindow:NSWindow?
    var revealWindow:(()->Void)?
    var showDesktop:(()->Void)?
    var keepInOrdinaryWindow:(()->Void)?
    var minimizeWindow:(()->Void)?
    var toggleFullScreen:(()->Void)?
    var closeWindow:(()->Void)?
    func setTopEntryPresentation(_ value:Bool) {isTopEntryPresentation=value}
    private var changed:AnyCancellable?
    private var modalChanges:AnyCancellable?
    private var systemAppearanceObserver:NSKeyValueObservation?
    @Published private(set) var windowVisible=false
    private let startServices:Bool
    private var quitPreparationTask:Task<Void,Never>?
    init(owner:LauncherController,calendar:CalendarModel?=nil,ai:AIUsageModel?=nil,device:DeviceStatusModel?=nil,health:HealthCenterModel?=nil,cleaning:SpaceCleaningModel?=nil,startServices:Bool=true) {
        self.owner=owner;self.startServices=startServices
        dataDirectory=owner.store.url.deletingLastPathComponent().appendingPathComponent("Workbench",isDirectory:true)
        preferenceStore=WorkbenchPreferenceStore(url:dataDirectory.appendingPathComponent("preferences.json"))
        let deviceModel=device ?? DeviceStatusModel(dataDirectory:dataDirectory.appendingPathComponent("Device"))
        self.device=deviceModel
        self.health=health ?? HealthCenterModel(device:deviceModel,dataDirectory:dataDirectory.appendingPathComponent("Health"))
        self.cleaning=cleaning ?? SpaceCleaningModel(dataDirectory:dataDirectory.appendingPathComponent("SpaceCleaning"))
        context=WorkbenchContextModel(dataDirectory:dataDirectory.appendingPathComponent("Context"))
        self.calendar=calendar ?? CalendarModel(dataDirectory:dataDirectory.appendingPathComponent("Calendar"))
        self.ai=ai ?? AIUsageModel(dataDirectory:dataDirectory.appendingPathComponent("AI"))
        vault=VaultModel(dataDirectory:dataDirectory.appendingPathComponent("Vault"))
        opacity=owner.configuration.settings.glassOpacity;appearance=owner.configuration.settings.workbenchAppearance
        buttonHoverCursor=owner.configuration.settings.buttonHoverCursor
        light=appearance == .light || (appearance == .system && NSApp.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .aqua)
        theme=owner.configuration.settings.workbenchTheme;backgroundMotion=owner.configuration.settings.backgroundMotionEnabled;reduceMotion=owner.configuration.settings.reduceMotion
        do {preferences=try preferenceStore.load()} catch {message=error.localizedDescription}
        if Bundle.main.object(forInfoDictionaryKey:"FangcunDeviceAcceptance") as? Bool == true {route = .device}
        widgets=DesktopWidgetsController(device:self.device,calendar:self.calendar,ai:self.ai,open:{[weak self] route in self?.navigate(route);self?.revealWindow?()},onChange:{[weak self] card in self?.updateCard(card)})
        changed=NotificationCenter.default.publisher(for:.fangcunConfigurationChanged).sink { [weak self] _ in Task { @MainActor in self?.syncAppearance() } }
        modalChanges=modals.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        systemAppearanceObserver=NSApp.observe(\.effectiveAppearance,options:[.new]) { [weak self] _,_ in
            Task { @MainActor in if self?.appearance == .system {self?.syncAppearance()} }
        }
        if startServices {refreshLoginStatus()};applyPreferences()
    }
    func navigate(_ next:WorkbenchRoute) {
        guard !quitting else {return}
        modals.prune()
        if next != route, modals.isPresented {revealWindow?();return}
        if next != route, let sheet=hostWindow?.attachedSheet {hostWindow?.makeKeyAndOrderFront(nil);sheet.makeKeyAndOrderFront(nil);return}
        if route == .vault && next != .vault { vault.lock(reason:"离开私密资料") }
        if route == .settings && next != .settings { owner?.settingsWindowController?.stopEmbedding() }
        if next == .settings, route != .settings {settingsReturnRoute=route}
        route=next;updateSamplingVisibility()
    }
    func openHealth() { navigate(.health) }
    func openHealthReading(_ factor:DeviceHealthFactor) {
        readingReturnRoute = .health
        switch factor {case .storage:deviceDetail = .storage;case .memory:deviceDetail = .memory;case .thermal,.battery:deviceDetail = .thermal}
        navigate(.device)
    }
    func openDeviceReading(_ detail:DeviceCardID) {readingReturnRoute=route;deviceDetail=detail;navigate(.device)}
    var requestedReadingReturnTitle:String {"返回"+(readingReturnRoute?.title ?? "设备状态")}
    func closeRequestedDeviceDetail() {
        guard let previous=readingReturnRoute else {return}
        readingReturnRoute=nil;deviceDetail=nil;navigate(previous)
    }
    func launcher() { owner?.show() }
    func setWindowVisible(_ value:Bool) {windowVisible=value;updateSamplingVisibility()}
    private func updateSamplingVisibility() {
        cleaning.windowVisible=windowVisible && route == .cleaning
        cleaning.reduceMotion=reduceMotion
        guard startServices else {return}
        context.setVisible(windowVisible && [.overview,.calendar].contains(route))
        device.setWindowVisible(windowVisible && [.overview,.device,.health,.cleaning,.network].contains(route))
        device.setWidgetsVisible(preferences.cards.contains(where:{$0.visible && $0.id == .device}) || (windowVisible && route == .cards))
    }
    func syncAppearance() {
        guard let owner else {return};opacity=owner.configuration.settings.glassOpacity;appearance=owner.configuration.settings.workbenchAppearance
        buttonHoverCursor=owner.configuration.settings.buttonHoverCursor
        light=appearance == .light || (appearance == .system && NSApp.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .aqua)
        theme=owner.configuration.settings.workbenchTheme;backgroundMotion=owner.configuration.settings.backgroundMotionEnabled;reduceMotion=owner.configuration.settings.reduceMotion
        cleaning.reduceMotion=reduceMotion
        Palette.workbenchTheme=theme;Palette.isLight=light;Palette.glassOpacity=opacity
        hostWindow?.appearance=appearance == .system ? nil:NSAppearance(named:light ? .aqua:.darkAqua)
        widgets.apply(preferences.cards,opacity:opacity,light:light,theme:theme)
    }
    func changeOpacity(_ value:Double) {guard owner?.setGlobalGlassOpacity(value) == true else {message=owner?.lastSaveError;return};syncAppearance()}
    func changeButtonHoverCursor(_ value:ButtonHoverCursor) {
        guard let owner,owner.updateSettings({$0.buttonHoverCursor=value}) else {message=owner?.lastSaveError;return}
        syncAppearance()
    }
    func changeLight(_ value:Bool) {changeAppearance(value ? .light:.dark)}
    func changeAppearance(_ value:LauncherAppearance) {
        guard let owner,owner.updateSettings({$0.workbenchAppearance=value;$0.lightAppearance=value == .light}) else {message=owner?.lastSaveError;return}
        owner.render();syncAppearance()
    }
    func changeTheme(_ value:LauncherTheme) {
        guard let owner,owner.updateSettings({$0.workbenchTheme=value;$0.workbenchAppearance = .dark;$0.lightAppearance=false}) else {message=owner?.lastSaveError;return}
        owner.render();syncAppearance()
    }
    func changeBackgroundMotion(_ value:Bool) {
        guard let owner,owner.updateSettings({$0.backgroundMotionEnabled=value}) else {message=owner?.lastSaveError;return}
        syncAppearance()
    }
    /// A final responder-chain fallback shares the same close requests as the
    /// focused SwiftUI commands. It must never bypass a form's draft protection.
    @discardableResult func cancelPresentedInteraction()->Bool {
        guard !quitting else {return true}
        if confirmingQuit {confirmingQuit=false;return true}
        modals.prune()
        if modals.isPresented {modals.dismissTop();return true}
        if brandMenuPresented {brandMenuPresented=false;return true}
        return false
    }
    @discardableResult func requestQuit()->Bool {
        guard !quitting else {return true};revealWindow?()
        if let sheet=hostWindow?.attachedSheet {hostWindow?.makeKeyAndOrderFront(nil);sheet.makeKeyAndOrderFront(nil);return false}
        if modals.isPresented {modals.dismissTop();modals.prune();guard !modals.isPresented else {return false}}
        confirmingQuit=true
        return true
    }
    func confirmQuit() {
        guard !quitting,let owner else {return}
        // Existing dirty-form and encrypted-write protections remain the final authority.
        guard owner.resolveQuitDrafts() == .terminateNow else {confirmingQuit=false;return}
        quitting=true
        calendar.freezeOwnNotificationsForQuit()
        quitPreparationTask=Task { [weak self,weak owner] in
            guard let self,let owner else {return}
            defer {self.quitPreparationTask=nil}
            do {
                await self.cleaning.prepareForQuit()
                await self.health.prepareForQuit()
                try await self.calendar.suspendOwnNotificationsForQuit()
                try await self.device.prepareForQuit()
                try await self.ai.prepareForQuit()
                self.confirmingQuit=false
                owner.finishConfirmedQuit()
                // Keep both the UI and notification gate frozen until the OS
                // actually terminates. Returning from an injected/native boundary
                // is not evidence that termination was cancelled.
            } catch {
                self.calendar.resumeOwnNotificationsAfterCancelledQuit()
                self.health.resumeAfterCancelledQuit()
                self.cleaning.resumeAfterCancelledQuit()
                self.device.resumeAfterCancelledQuit()
                self.ai.resumeAfterCancelledQuit()
                self.quitting=false;self.confirmingQuit=false
                owner.cancelPendingSystemTermination()
                self.message="退出前数据保存或提醒暂停未完成：\(error.localizedDescription)"
            }
        }
    }
    func waitForQuitPreparation() async {if let quitPreparationTask {await quitPreparationTask.value}}
    func returnFromSettings() {navigate(settingsReturnRoute)}
    func changeReduceMotion(_ value:Bool) {
        guard let owner,owner.updateSettings({$0.reduceMotion=value}) else {message=owner?.lastSaveError;return}
        syncAppearance()
    }
    func changeSampleInterval(_ value:Double) {var p=preferences;p.sampleInterval=value;savePreferences(p)}
    func changeMenuBar(_ value:Bool) {var p=preferences;p.menuBarVisible=value;savePreferences(p)}
    func updateCard(_ card:DesktopCardPreference) {var p=preferences;guard let i=p.cards.firstIndex(where:{$0.id==card.id}),p.cards[i] != card else {return};p.cards[i]=card;savePreferences(p)}
    private func savePreferences(_ value:WorkbenchPreferences) {
        do {try preferenceStore.save(value);preferences=value;applyPreferences()} catch {message=error.localizedDescription}
    }
    private func applyPreferences() {
        owner?.statusItem?.isVisible=preferences.menuBarVisible
        if startServices {device.start(interval:preferences.sampleInterval)}
        widgets.apply(preferences.cards,opacity:opacity,light:light,theme:theme);updateSamplingVisibility()
    }
    func setLogin(_ value:Bool) {
        Task {
            do {if value {try SMAppService.mainApp.register()} else {try await SMAppService.mainApp.unregister()};refreshLoginStatus()}
            catch {message="登录启动未能更新：\(error.localizedDescription)";refreshLoginStatus()}
        }
    }
    private func refreshLoginStatus() {loginEnabled=SMAppService.mainApp.status == .enabled;loginNeedsApproval=SMAppService.mainApp.status == .requiresApproval}
    func revealDataDirectory() {NSWorkspace.shared.open(dataDirectory)}
    private func accessTitle(_ access:CalendarAccess)->String {switch access {case .notDetermined:"尚未接入";case .granted:"已授权";case .denied:"未授权";case .restricted:"系统限制"}}
    var auditEntries:[WorkbenchAuditEntry] {
        let s=device.snapshot
        return [
            .init(id:"storage",title:"本机存储",state:auditStorageResult,detail:"配置、提醒、计量元数据与加密资料分别存储；损坏数据不被默认值覆盖。"),
            .init(id:"device",title:"设备状态",state:s.sampledAt == nil ? "等待采样":"真实采样",detail:"CPU、内存、磁盘、网卡与可读进程；温度及风扇使用硬件相关的 AppleSMC 只读接口，缺失时明确标记。GPU 使用率暂不可用。"),
            .init(id:"device-traffic",title:"流量统计与预算",state:device.budget.enabled ? "预算已启用":"真实采集 · 预算关闭",detail:"网络速度与周期统计分离；按全部物理网络、Wi-Fi、有线分别记录。只计入方寸运行期间的连续采样，间断不补齐；预算不执行限速或断网。"),
            .init(id:"device-temperature",title:"温度提醒",state:device.temperatureRule.enabled ? "规则已启用":"规则关闭",detail:"CPU/GPU 独立阈值、持续时间和恢复后的冷却去重；传感器缺失与休眠中断计时。系统通知：" + device.notificationPermission.title + "。"),
            .init(id:"workbench-top-entry",title:"顶部悬浮入口",state:owner?.topEntryController?.preferences.enabled == true ? "已开启":"已关闭",detail:"鼠标在顶部刘海或屏幕中央短暂停留，直接进入工作台或显示真实快速信息；无需辅助功能权限。入口设置独立保存在本机，展开/收起尊重系统减少动态效果。"),
            .init(id:"calendar",title:"系统日历",state:accessTitle(calendar.calendarAccess),detail:"系统日程只读。当前加载 \(calendar.events.count) 条；不连接也可以使用本机提醒。"),
            .init(id:"reminders",title:"提醒事项",state:accessTitle(calendar.remindersAccess),detail:"本机 \(calendar.localReminders.count) 条，系统 \(calendar.systemReminders.count) 条；系统来源变更需要授权。"),
            .init(id:"notifications",title:"系统通知",state:device.notificationPermission.title,detail:"方寸本机日历提醒、流量预算和温度提醒共用系统通知授权；不同模块保持独立通知标识，系统提醒事项由系统管理。"),
            .init(id:"codex",title:"Codex 额度",state:ai.providerSummaries.first(where:{$0.provider.rawValue == "codex"})?.state.title ?? "无读数",detail:ai.providerSummaries.first(where:{$0.provider.rawValue == "codex"})?.detail ?? "未读取到计量元数据。"),
            .init(id:"claude",title:"Claude 额度",state:ai.providerSummaries.first(where:{$0.provider.rawValue == "claude"})?.state.title ?? "无读数",detail:"额度与 Token 独立统计；只接入官方状态数据或明确标记的导入数据，不读取认证密钥。"),
            .init(id:"vault",title:"私密资料",state:vault.isUnlocked ? "已解锁":"已锁定",detail:"PBKDF2-SHA256 与 AES-GCM；离开页面、关闭窗口、闲置与系统保护事件撤销会话。"),
            .init(id:"widgets",title:"桌面组件",state:"\(preferences.cards.filter(\.visible).count) 张已显示",detail:"桌面层/置顶、大小、位置锁定、鼠标穿透和来源可独立保存。"),
            .init(id:"launcher",title:"启动器",state:owner?.storageProblem == nil ? "本机配置已加载":"配置异常",detail:"统一设置、38 键绑定、全局快捷键、应用搜索与数字快启。")
        ]
    }
    func runStorageAudit() {
        let probe=dataDirectory.appendingPathComponent(".audit-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at:dataDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            defer {try? FileManager.default.removeItem(at:probe)}
            let value=Data(UUID().uuidString.utf8);try value.write(to:probe,options:.atomic)
            guard try Data(contentsOf:probe)==value else {throw LauncherError.storage("读写校验不一致。")}
            auditStorageResult="读写校验通过";lastAudit=Date()
        } catch {auditStorageResult="检查失败：\(error.localizedDescription)";lastAudit=Date()}
    }
    func exportAudit() {
        runStorageAudit();let panel=NSSavePanel();panel.title="导出功能审计";panel.nameFieldStringValue="方寸功能审计.json";panel.allowedContentTypes=[.json]
        guard panel.runModal() == .OK,let url=panel.url else {return}
        struct Report:Codable {var format="fangcun-function-audit";var date:Date;var entries:[WorkbenchAuditEntry]}
        do {let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];encoder.dateEncodingStrategy = .iso8601;try encoder.encode(Report(date:Date(),entries:auditEntries)).write(to:url,options:.atomic);toast="功能审计已导出。"} catch {message="导出失败：\(error.localizedDescription)"}
    }
    func shutdown() {modals.clear();context.stop();health.cancelAll();cleaning.cancelAll();vault.lock(reason:"退出方寸");device.stop();widgets.hideAll();owner?.settingsWindowController?.stopEmbedding()}
}

@MainActor final class WorkbenchWindowController:NSWindowController,NSWindowDelegate {
    let model:WorkbenchAppModel
    private weak var launcher:LauncherController?
    private var systemObservers:[NSObjectProtocol]=[]
    private var presentationGeneration = 0
    private var finishingClose = false
    private var pendingMinimizeGeneration:Int?
    private var fullScreenTransition=false
    private var ordinaryWindowSessionActive=false
    private var ordinaryDismissalGeneration:Int?
    /// The OS transition boundary is injectable for timer-race checks without
    /// moving the user's desktop into a real full-screen Space.
    var performFullScreenToggle:(NSWindow)->Void = {$0.toggleFullScreen(nil)}
    private var topEntryPanel: WorkbenchTopPanel?
    private var hostingView: NSHostingView<AnyView>!
    private var topEntryOriginFrame: NSRect?
    private var topEntrySuspended = false
    private var topEntryDismissing = false
    private var restoreTopEntryHostAfterClose = false
    private var suspendedTopChildren: [NSWindow] = []
    private weak var suspendedTopModal: NSWindow?
    private var opacityTransitions: [ObjectIdentifier: (token: UUID, timer: Timer)] = [:]
    private(set) var isTopEntryPresented = false
    /// `window` remains the ordinary, frame-autosaving native full-screen window.
    var presentationWindow: NSWindow? { isTopEntryPresented ? topEntryPanel : window }
    var isPresentationOnActiveSpace: Bool { presentationWindow?.isOnActiveSpace == true }
    var isPresentationOccluded: Bool { presentationWindow?.occlusionState.contains(.visible) != true }
    private func updateDockParticipation() {
        // A minimized ordinary window still needs its Dock restore target. A
        // parked native full-screen Space also remains a real ordinary window.
        let retainedOrdinaryWindow = window?.isMiniaturized == true
            || (isTopEntryPresented && window?.styleMask.contains(.fullScreen) == true && window?.isVisible == true)
        launcher?.setWorkbenchDockVisible(ordinaryWindowSessionActive || retainedOrdinaryWindow)
    }
    /// A hidden sheet is a resumable part of this hover session, not a reason to
    /// disable its only entry point. A newly opened, unrelated modal still blocks it.
    var canResumeSuspendedTopInteraction: Bool {
        guard isTopEntryPresented, topEntrySuspended, let panel = topEntryPanel,
              !panel.isVisible || topEntryDismissing else { return false }
        if let modal = NSApp.modalWindow,
           modal !== suspendedTopModal,
           !isTopEntryChild(modal) { return false }
        if panel.attachedSheet != nil { return true }
        return NSApp.modalWindow != nil && NSApp.modalWindow === suspendedTopModal
    }
    init(owner:LauncherController,model:WorkbenchAppModel?=nil,autosavesFrame:Bool=true) {
        launcher=owner;self.model=model ?? WorkbenchAppModel(owner:owner)
        let window=WorkbenchCancelWindow(contentRect:NSRect(x:0,y:0,width:1120,height:758),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:window)
        window.cancelWorkbenchInteraction={ [weak self,weak window] in self?.cancelWorkbenchInteraction(in:window) ?? false }
        window.title="方寸";window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true;window.isOpaque=false;window.backgroundColor = .clear
        window.collectionBehavior.insert(.fullScreenPrimary)
        for kind in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton] {window.standardWindowButton(kind)?.isHidden=true}
        window.isReleasedWhenClosed=false;window.isMovableByWindowBackground=true;window.minSize=NSSize(width:900,height:620);window.delegate=self
        window.animationBehavior = .none
        self.model.hostWindow=window
        self.model.vault.hostWindow=window
        self.model.health.hostWindow=window
        self.model.cleaning.hostWindow=window
        self.model.modals.hostWindow=window
        window.center();if autosavesFrame {window.setFrameAutosaveName(Bundle.main.object(forInfoDictionaryKey:"FangcunDeviceAcceptance") as? Bool == true ? "FangcunDeviceAcceptance" : "FangcunWorkbench")}
        hostingView=NSHostingView(rootView:AnyView(WorkbenchRootView(model:self.model).nativeCheckAccessibility()));hostingView.frame=NSRect(origin:.zero,size:window.contentLayoutRect.size);hostingView.autoresizingMask=[.width,.height]
        window.contentView=hostingView
        self.model.revealWindow={ [weak self] in self?.present() }
        self.model.showDesktop={ [weak self] in self?.dismiss() }
        self.model.keepInOrdinaryWindow={ [weak self] in self?.promoteTopEntryToOrdinary(fullScreen: false) }
        self.model.minimizeWindow={ [weak self] in self?.requestMinimize() }
        self.model.toggleFullScreen={ [weak self] in self?.requestToggleFullScreen() }
        self.model.closeWindow={ [weak self] in self?.dismiss(close:true) }
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.screensDidSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
            systemObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.model.vault.lock(reason:"系统保护事件") } })
        }
    }
    required init?(coder:NSCoder) {fatalError()}
    override func cancelOperation(_ sender:Any?) {
        if cancelWorkbenchInteraction(in:presentationWindow) {return}
        super.cancelOperation(sender)
    }
    private func cancelWorkbenchInteraction(in target:NSWindow?)->Bool {
        guard let target,target === presentationWindow,target.isVisible,
              target.attachedSheet == nil,
              NSApp.modalWindow == nil || NSApp.modalWindow === target else {return false}
        return model.cancelPresentedInteraction()
    }
    func present(route:WorkbenchRoute?=nil,settingsTab:WorkbenchSettingsTab?=nil) {
        pendingMinimizeGeneration=nil
        launcher?.topEntryController?.cancelPendingEntry()
        guard let window else { return }
        if let sheet = presentationWindow?.attachedSheet {
            revealAttachedSheet(sheet); return
        }
        if isTopEntryPresented, let modal = NSApp.modalWindow {
            revealSuspendedTopEntry(modal: modal); return
        }
        presentationGeneration += 1
        finishingClose = false
        restoreOrdinaryHost()
        present(window, route: route, settingsTab: settingsTab, fromTop: false)
    }
    func presentFromTopEntry(originFrame: NSRect? = nil) {
        guard let window else { return }
        if let originFrame, originFrame.width.isFinite, originFrame.height.isFinite,
           originFrame.midX.isFinite, originFrame.midY.isFinite { topEntryOriginFrame = originFrame }
        if let sheet = presentationWindow?.attachedSheet {
            revealAttachedSheet(sheet); return
        }
        if isTopEntryPresented, let modal = NSApp.modalWindow {
            revealSuspendedTopEntry(modal: modal); return
        }
        presentationGeneration += 1
        finishingClose = false
        let panel = makeTopEntryPanel()
        let newSession = !isTopEntryPresented
        if !isTopEntryPresented {
            launcher?.settingsWindowController?.cancelEmbeddedRecording()
            window.makeFirstResponder(nil)
            // A native full-screen Space must never be left with an empty content view.
            // The parked surface contains no cached business or unlocked vault content.
            if window.styleMask.contains(.fullScreen) {
                window.contentView = parkedOrdinarySurface()
            } else {
                window.orderOut(nil)
                window.contentView = nil
            }
            isTopEntryPresented = true
            ordinaryWindowSessionActive = false
            updateDockParticipation()
            model.setTopEntryPresentation(true)
            model.isFullScreen = false
            bindHost(panel)
        }
        placeTopEntryPanel(panel)
        // A return from another app resumes the current page and its drafts.
        // Merely crossing the notch again must never reset an open detail page.
        present(panel, route: newSession ? .overview : nil, settingsTab: nil, fromTop: true)
        restoreSuspendedTopChildren()
    }
    private func present(_ target: NSWindow, route: WorkbenchRoute?, settingsTab: WorkbenchSettingsTab?, fromTop: Bool) {
        ordinaryDismissalGeneration=nil
        pendingMinimizeGeneration=nil
        let wasVisible = target.isVisible
        let shouldAnimate = !wasVisible || target.isMiniaturized || target.alphaValue < 0.999 || topEntryDismissing
        cancelOpacityTransition(target)
        presentationGeneration += 1
        finishingClose = false
        topEntryDismissing = false
        restoreTopEntryHostAfterClose = false
        if fromTop { topEntrySuspended = false }
        if let route {model.navigate(route)};if let settingsTab {model.settingsTab=settingsTab}
        target.appearance=model.appearance == .system ? nil:NSAppearance(named:model.light ? .aqua:.darkAqua)
        if target.isMiniaturized { target.deminiaturize(nil) }
        if !wasVisible { target.alphaValue = shouldAnimate ? 0 : 1 }
        model.setWindowVisible(true)
        if fromTop {
            // Hover is not an app-activation handoff. The nonactivating panel can join
            // the user's current Space without relying on NSApp.activate() succeeding.
            target.orderFrontRegardless()
            target.makeKey()
        } else {
            ordinaryWindowSessionActive = true
            updateDockParticipation()
            showWindow(nil);NSApp.activate();target.makeKeyAndOrderFront(nil)
        }
        guard shouldAnimate else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduceMotion ? 0.12 : fromTop ? 0.28 : 0.24
        animateSurface(target, entering: true, fromTop: fromTop, duration: duration, newlyVisible: !wasVisible)
        transitionOpacity(target, to: 1, duration: duration, curve: .easeOut)
    }
    private enum OpacityCurve {
        case easeIn, easeOut, easeInOut
        func value(_ progress: Double) -> Double {
            switch self {
            case .easeIn: return progress * progress
            case .easeOut: return 1 - pow(1 - progress, 3)
            case .easeInOut: return progress * progress * (3 - 2 * progress)
            }
        }
    }
    private func cancelOpacityTransition(_ window: NSWindow) {
        opacityTransitions.removeValue(forKey: ObjectIdentifier(window))?.timer.invalidate()
    }
    /// WindowServer opacity has an owned clock, independent of implicit AppKit/Core
    /// Animation transactions used by the island mask and SwiftUI. A cancelled fade
    /// cannot later finish a newer presentation or detach a restored sheet family.
    private func transitionOpacity(_ window: NSWindow, to opacity: CGFloat, duration: TimeInterval,
                                   curve: OpacityCurve, completion: (@MainActor @Sendable () -> Void)? = nil) {
        cancelOpacityTransition(window)
        guard duration > 0 else { window.alphaValue = opacity; completion?(); return }
        let identifier = ObjectIdentifier(window), token = UUID()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let from = window.alphaValue
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak window] timer in
            let valid = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window,
                      self.opacityTransitions[identifier]?.token == token else { return false }
                let progress = max(0, min(1, (ProcessInfo.processInfo.systemUptime - startedAt) / duration))
                window.alphaValue = from + (opacity - from) * CGFloat(curve.value(progress))
                guard progress >= 1 else { return true }
                self.cancelOpacityTransition(window)
                window.alphaValue = opacity
                completion?()
                return true
            }
            if !valid { timer.invalidate() }
        }
        timer.tolerance = 0.003
        opacityTransitions[identifier] = (token, timer)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }
    /// The window and SwiftUI layout stay at their final size throughout the motion.
    /// This avoids reflowing text or overwriting the saved ordinary-window geometry.
    private func animateSurface(_ target: NSWindow, entering: Bool, fromTop: Bool,
                                duration: TimeInterval, newlyVisible: Bool = false) {
        guard let content = target.contentView else { return }
        content.wantsLayer = true
        guard let layer = content.layer else { return }
        let current = layer.presentation()?.transform ?? CATransform3DIdentity
        layer.removeAnimation(forKey: "workbench-entry")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !model.reduceMotion, !model.isFullScreen else { return }
        let origin = topEntryOriginFrame ?? NSRect(x: target.frame.midX - 100,
            y: target.screen?.frame.maxY ?? target.frame.maxY, width: 200, height: 1)
        let dx = fromTop ? max(-40, min(40, (origin.midX - target.frame.midX) * 0.12)) : 0
        let distance = fromTop ? max(20, min(56, (origin.midY - target.frame.midY) * 0.12)) : 8
        let dy = (content.isFlipped ? -1.0 : 1.0) * distance
        let scale: CGFloat = fromTop ? 0.94 : 1.0
        let collapsed = CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(dx, dy, 0))
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: entering && newlyVisible ? collapsed : current)
        animation.toValue = NSValue(caTransform3D: entering ? CATransform3DIdentity : collapsed)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)
        if !entering { animation.fillMode = .forwards; animation.isRemovedOnCompletion = false }
        layer.add(animation, forKey: "workbench-entry")
    }
    private func makeTopEntryPanel() -> WorkbenchTopPanel {
        if let topEntryPanel { return topEntryPanel }
        let panel = WorkbenchTopPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 758),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "方寸工作台"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient]
        panel.minSize = NSSize(width: 900, height: 620)
        panel.animationBehavior = .none; panel.delegate = self
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        panel.enterNativeFullScreen = { [weak self] in self?.promoteTopEntryToOrdinary(fullScreen: true) }
        panel.minimizeOrdinaryWindow = { [weak self] in self?.promoteTopEntryToOrdinary(fullScreen: false, minimize: true) }
        panel.cancelWorkbenchInteraction = { [weak self,weak panel] in self?.cancelWorkbenchInteraction(in:panel) ?? false }
        topEntryPanel = panel
        return panel
    }
    private func placeTopEntryPanel(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { WorkbenchTopEntryGate.contains(pointer, in: $0.frame) }) ?? NSScreen.main else { return }
        if panel.isVisible, panel.screen?.frame == screen.frame { return }
        let available = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let ordinarySize = panel.isVisible ? panel.frame.size : window?.styleMask.contains(.fullScreen) == true ? NSSize(width: 1120, height: 758) : window?.frame.size ?? NSSize(width: 1120, height: 758)
        let size = NSSize(width: min(ordinarySize.width, available.width), height: min(ordinarySize.height, available.height))
        panel.setFrame(NSRect(x: available.midX - size.width / 2, y: available.maxY - size.height,
                              width: size.width, height: size.height), display: false)
    }
    private func bindHost(_ target: NSWindow) {
        hostingView.window?.makeFirstResponder(nil)
        hostingView.removeFromSuperview()
        hostingView.frame = NSRect(origin: .zero, size: target.contentLayoutRect.size)
        target.contentView = hostingView
        model.hostWindow = target
        model.vault.hostWindow = target
        model.health.hostWindow = target
        model.cleaning.hostWindow = target
        model.modals.hostWindow = target
    }
    private func parkedOrdinarySurface() -> NSView {
        let placeholder = NSHostingView(rootView: WorkbenchParkedSurface(opacity: model.opacity, light: model.light) { [weak self] in
            self?.present()
        }.nativeCheckAccessibility())
        placeholder.frame = hostingView.frame
        placeholder.autoresizingMask = [.width, .height]
        return placeholder
    }
    private func restoreOrdinaryHost() {
        guard isTopEntryPresented, let window else { return }
        launcher?.settingsWindowController?.cancelEmbeddedRecording()
        cancelOpacityTransition(window)
        if let topEntryPanel { cancelOpacityTransition(topEntryPanel) }
        for child in suspendedTopChildren { cancelOpacityTransition(child) }
        // orderOut can synchronously make the original window key again.
        isTopEntryPresented = false
        model.setTopEntryPresentation(false)
        topEntrySuspended = false
        topEntryDismissing = false
        restoreTopEntryHostAfterClose = false
        suspendedTopChildren.removeAll()
        suspendedTopModal = nil
        model.isFullScreen = window.styleMask.contains(.fullScreen)
        topEntryPanel?.makeFirstResponder(nil)
        topEntryPanel?.orderOut(nil)
        topEntryPanel?.alphaValue = 1
        topEntryPanel?.contentView?.layer?.removeAnimation(forKey: "workbench-entry")
        topEntryPanel?.contentView = nil
        bindHost(window)
    }
    /// Called by the top panel's native traffic-light selectors. Promotion restores
    /// the original window before AppKit starts a full-screen transition.
    func promoteTopEntryToOrdinary(fullScreen: Bool, minimize: Bool = false) {
        guard isTopEntryPresented, let window else { return }
        if let sheet = topEntryPanel?.attachedSheet { revealAttachedSheet(sheet); return }
        if let modal = NSApp.modalWindow { revealSuspendedTopEntry(modal: modal); return }
        present()
        if minimize { window.performMiniaturize(nil) }
        else if fullScreen, !window.styleMask.contains(.fullScreen) { performFullScreenToggle(window) }
    }
    /// Yields a temporary hover session to the user's next task. Unlike an explicit
    /// close, this must never bring a sheet back to the front or migrate its host.
    /// Hidden sessions retain their current page, draft controls and attached sheets.
    func dismissTopEntryForContextChange(animated: Bool = true) {
        guard isTopEntryPresented, let target = topEntryPanel else { return }
        if topEntryDismissing {
            if !animated {
                // Sleep, stop and display removal must not leave the tail of an
                // earlier animated dismissal visible until its completion runs.
                presentationGeneration += 1
                finishContextDismissal(generation: presentationGeneration)
            }
            return
        }
        guard target.isVisible else { return }
        presentationGeneration += 1
        let generation = presentationGeneration
        suspendedTopModal = NSApp.modalWindow
        topEntrySuspended = true
        topEntryDismissing = true
        finishingClose = false
        launcher?.settingsWindowController?.cancelEmbeddedRecording()
        // The vault has an independent security lifecycle; ordinary form drafts are
        // preserved, but leaving the temporary session cannot keep plaintext alive.
        if model.vault.isUnlocked || model.route == .vault { model.vault.lock(reason: "离开顶部工作台") }
        suspendedTopChildren = topEntryChildWindows().filter(\.isVisible)
        model.setWindowVisible(false)
        let duration = animated ? ((NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || model.reduceMotion) ? 0.1 : 0.18) : 0
        guard duration > 0 else { finishContextDismissal(generation: generation); return }
        animateSurface(target, entering: false, fromTop: true, duration: duration)
        for child in suspendedTopChildren {
            transitionOpacity(child, to: 0, duration: duration, curve: .easeInOut)
        }
        transitionOpacity(target, to: 0, duration: duration, curve: .easeInOut) { [weak self] in
            self?.finishContextDismissal(generation: generation)
        }
    }
    private func topEntryChildWindows() -> [NSWindow] {
        guard let target = topEntryPanel else { return [] }
        var result: [NSWindow] = []
        func append(_ window: NSWindow) {
            guard window !== target, !result.contains(where: { $0 === window }) else { return }
            result.append(window)
            for child in window.childWindows ?? [] { append(child) }
            if let sheet = window.attachedSheet { append(sheet) }
        }
        for child in target.childWindows ?? [] { append(child) }
        if let sheet = target.attachedSheet { append(sheet) }
        // An app-modal window has no sheetParent. Keep only the exact modal captured
        // when this session yielded; never adopt a different modal that opens later.
        if let modal = NSApp.modalWindow, modal === suspendedTopModal, modal !== target { append(modal) }
        return result
    }
    private func isTopEntryChild(_ window: NSWindow) -> Bool {
        guard let panel = topEntryPanel else { return false }
        var current: NSWindow? = window
        var visited: Set<ObjectIdentifier> = []
        while let candidate = current, visited.insert(ObjectIdentifier(candidate)).inserted {
            if candidate === panel { return true }
            current = candidate.sheetParent ?? candidate.parent
        }
        return false
    }
    private func finishContextDismissal(generation: Int) {
        guard presentationGeneration == generation, topEntrySuspended, let target = topEntryPanel else { return }
        cancelOpacityTransition(target)
        // A child can finish attaching during the exit animation. Include it without
        // presenting it, and leave its parent relationship intact for resumption.
        for child in topEntryChildWindows() where child.isVisible && !suspendedTopChildren.contains(where: { $0 === child }) {
            suspendedTopChildren.append(child)
        }
        let attachedChildren = Set(suspendedTopChildren.filter { isTopEntryChild($0) }.map(ObjectIdentifier.init))
        // Ordering a sheet out directly breaks AppKit's sheetParent relationship
        // without completing its modal session. Let the parent hide its own family.
        target.orderOut(nil)
        for child in suspendedTopChildren.reversed() {
            cancelOpacityTransition(child)
            if !attachedChildren.contains(ObjectIdentifier(child)) { child.orderOut(nil) }
            child.alphaValue = 1
        }
        target.alphaValue = 1
        target.contentView?.layer?.removeAnimation(forKey: "workbench-entry")
        topEntryDismissing = false
        if restoreTopEntryHostAfterClose {
            restoreTopEntryHostAfterClose = false
            // A deliberate close must not leave the native full-screen window
            // showing its parked placeholder after the temporary panel is gone.
            window?.orderOut(nil)
            ordinaryWindowSessionActive = false
            updateDockParticipation()
            // Native child/sheet/modal sessions cannot move to a different
            // parent. Keep their one hosting view attached for safe resumption.
            if topEntryChildWindows().isEmpty {
                restoreOrdinaryHost()
                window?.orderOut(nil)
            }
        }
    }
    private func restoreSuspendedTopChildren() {
        let children = suspendedTopChildren
        suspendedTopChildren.removeAll()
        let attached = topEntryChildWindows()
        for child in children where attached.contains(where: { $0 === child }) {
            cancelOpacityTransition(child)
            child.alphaValue = 1
            child.orderFrontRegardless()
        }
    }
    private func revealSuspendedTopEntry(modal: NSWindow) {
        guard let panel = topEntryPanel else { return }
        present(panel, route: nil, settingsTab: nil, fromTop: true)
        restoreSuspendedTopChildren()
        cancelOpacityTransition(modal)
        modal.alphaValue = 1
        modal.makeKeyAndOrderFront(nil)
    }
    private func revealAttachedSheet(_ sheet: NSWindow) {
        ordinaryDismissalGeneration=nil
        presentationGeneration += 1
        finishingClose = false
        let parent = sheet.sheetParent ?? presentationWindow
        if let parent { cancelOpacityTransition(parent) }
        cancelOpacityTransition(sheet)
        if parent === topEntryPanel {
            topEntrySuspended = false
            topEntryDismissing = false
            restoreTopEntryHostAfterClose = false
            parent?.contentView?.layer?.removeAnimation(forKey: "workbench-entry")
            model.setWindowVisible(true)
        }
        if parent === presentationWindow {model.setWindowVisible(true)}
        parent?.alphaValue = 1
        if parent === topEntryPanel { parent?.orderFrontRegardless(); parent?.makeKey() }
        else {
            ordinaryWindowSessionActive = true
            updateDockParticipation()
            NSApp.activate(); parent?.makeKeyAndOrderFront(nil)
        }
        restoreSuspendedTopChildren()
        sheet.alphaValue = 1
        sheet.makeKeyAndOrderFront(nil)
    }
    func requestToggleFullScreen() {
        guard !model.quitting else {return}
        if isTopEntryPresented {promoteTopEntryToOrdinary(fullScreen:true);return}
        guard let window else {return}
        cancelOrdinaryDismissalForWindowControl(window)
        pendingMinimizeGeneration=nil
        performFullScreenToggle(window)
    }
    func requestMinimize() {
        guard !model.quitting else {return}
        model.vault.lock(reason:"最小化方寸")
        if isTopEntryPresented {promoteTopEntryToOrdinary(fullScreen:false,minimize:true);return}
        guard let window else {return}
        cancelOrdinaryDismissalForWindowControl(window)
        if fullScreenTransition {
            pendingMinimizeGeneration=presentationGeneration
        } else if window.styleMask.contains(.fullScreen) {
            pendingMinimizeGeneration=presentationGeneration
            performFullScreenToggle(window)
        } else {window.performMiniaturize(nil)}
    }
    /// A fresh window-control action supersedes an in-progress close. Otherwise
    /// its old fade completion could order out a window that has just entered
    /// full screen or remove the user's new minimized restore target.
    private func cancelOrdinaryDismissalForWindowControl(_ target:NSWindow) {
        guard target === window,let dismissalGeneration=ordinaryDismissalGeneration else {return}
        ordinaryDismissalGeneration=nil
        if presentationGeneration == dismissalGeneration {presentationGeneration += 1}
        cancelOpacityTransition(target)
        target.alphaValue=1
        target.contentView?.layer?.removeAnimation(forKey:"workbench-entry")
        ordinaryWindowSessionActive=true
        updateDockParticipation()
        model.setWindowVisible(!target.isMiniaturized)
    }
    private func dismiss(_ target: NSWindow? = nil, close: Bool = false) {
        guard !model.quitting,let target = target ?? presentationWindow else { return }
        pendingMinimizeGeneration=nil
        model.vault.lock(reason:close ? "关闭方寸窗口":"收起方寸窗口")
        model.confirmingQuit=false
        launcher?.settingsWindowController?.cancelEmbeddedRecording()
        if target === topEntryPanel {
            if close {restoreTopEntryHostAfterClose = true}
            dismissTopEntryForContextChange()
            return
        }
        presentationGeneration += 1
        let generation=presentationGeneration
        ordinaryDismissalGeneration=generation
        model.setWindowVisible(false)
        let duration=(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || model.reduceMotion) ? 0.1:0.16
        animateSurface(target,entering:false,fromTop:false,duration:duration)
        transitionOpacity(target,to:0,duration:duration,curve:.easeIn) { [weak self] in
            guard let self,self.presentationGeneration == generation else {return}
            self.ordinaryDismissalGeneration=nil
            // Hiding the native parent preserves an attached form and its draft; AppKit
            // hides its sheet family together instead of detaching an active modal sheet.
            target.orderOut(nil)
            self.ordinaryWindowSessionActive = false
            self.updateDockParticipation()
            target.alphaValue=1
            target.contentView?.layer?.removeAnimation(forKey:"workbench-entry")
        }
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        if finishingClose {return true}
        dismiss(sender,close:true)
        return false
    }
    func windowWillClose(_ notification:Notification) {
        if let window = notification.object as? NSWindow { cancelOpacityTransition(window) }
        guard notification.object as? NSWindow === presentationWindow else { return }
        ordinaryDismissalGeneration=nil
        ordinaryWindowSessionActive=false;updateDockParticipation()
        model.vault.lock(reason:"关闭工作台");model.setWindowVisible(false);launcher?.settingsWindowController?.stopEmbedding()
    }
    func windowDidResignKey(_ notification:Notification) {launcher?.settingsWindowController?.cancelEmbeddedRecording()}
    func windowDidBecomeKey(_ notification: Notification) {
        if isTopEntryPresented, notification.object as? NSWindow === window {
            // Ordering out a temporary host can synchronously make a parked native
            // full-screen window key. That is not a request to reopen the overlay.
            guard !topEntrySuspended else { return }
            if let sheet = topEntryPanel?.attachedSheet { revealAttachedSheet(sheet); return }
            presentationGeneration += 1; restoreOrdinaryHost(); model.setWindowVisible(true)
        }
        if !isTopEntryPresented,notification.object as? NSWindow === window {
            ordinaryWindowSessionActive=true;updateDockParticipation()
        }
    }
    func windowWillEnterFullScreen(_ notification:Notification) {
        guard !isTopEntryPresented else {return}
        fullScreenTransition=true;model.isFullScreen=true
    }
    func windowDidFailToEnterFullScreen(_ window:NSWindow) {
        guard !isTopEntryPresented else {return}
        fullScreenTransition=false;model.isFullScreen=false
        finishPendingMinimize()
    }
    func windowDidEnterFullScreen(_ notification:Notification) {
        guard !isTopEntryPresented else {return}
        fullScreenTransition=false;model.isFullScreen=true
        if pendingMinimizeGeneration == presentationGeneration,let window {performFullScreenToggle(window)}
    }
    func windowWillExitFullScreen(_ notification:Notification) {
        if !isTopEntryPresented {fullScreenTransition=true}
    }
    func windowDidFailToExitFullScreen(_ window:NSWindow) {
        pendingMinimizeGeneration=nil;fullScreenTransition=false;model.isFullScreen=true
    }
    func windowDidExitFullScreen(_ notification:Notification) {
        guard !isTopEntryPresented else {return}
        fullScreenTransition=false;model.isFullScreen=false
        finishPendingMinimize()
    }
    private func finishPendingMinimize() {
        let shouldMinimize=pendingMinimizeGeneration == presentationGeneration
        pendingMinimizeGeneration=nil
        if shouldMinimize {window?.performMiniaturize(nil)}
    }
    func windowDidMiniaturize(_ notification:Notification) {if notification.object as? NSWindow === presentationWindow {model.vault.lock(reason:"最小化方寸");model.setWindowVisible(false);updateDockParticipation()}}
    func windowDidDeminiaturize(_ notification:Notification) {if notification.object as? NSWindow === presentationWindow {ordinaryWindowSessionActive=true;updateDockParticipation();model.setWindowVisible(true)}}
}

private struct WorkbenchParkedSurface: View {
    let opacity: Double
    let light: Bool
    let restore: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            WorkbenchBrandMark().frame(width: 36, height: 36)
            Text("工作台正在顶部浮层中显示").font(.system(size: 18, weight: .medium))
            Button("回到此窗口", action: restore).buttonStyle(WBButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkbenchGlass(opacity: opacity, light: light, cornerRadius: 0))
        .foregroundStyle(WorkbenchStyle.text)
        .preferredColorScheme(light ? .light : .dark)
    }
}

/// Escape reaches these windows only after the focused text/input responder has
/// had its normal opportunity to handle it (including marked-text cancellation).
/// Do not move this fallback to performKeyEquivalent or an event monitor.
@MainActor private final class WorkbenchCancelWindow:NSWindow {
    var cancelWorkbenchInteraction:(()->Bool)?
    override func cancelOperation(_ sender:Any?) {
        if cancelWorkbenchInteraction?() == true {return}
        super.cancelOperation(sender)
    }
    override func keyDown(with event:NSEvent) {
        if WorkbenchCancelKey.isUnhandledEscape(event),cancelWorkbenchInteraction?() == true {return}
        super.keyDown(with:event)
    }
}

@MainActor private enum WorkbenchCancelKey {
    static func isUnhandledEscape(_ event:NSEvent)->Bool {
        event.keyCode == 53 && event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty
    }
}

/// The nonactivating mask stays fixed for the panel's lifetime. Ordinary/native
/// full-screen presentation uses a separate NSWindow rather than changing this mask.
@MainActor private final class WorkbenchTopPanel: NSPanel {
    var enterNativeFullScreen: (() -> Void)?
    var minimizeOrdinaryWindow: (() -> Void)?
    var cancelWorkbenchInteraction:(()->Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func toggleFullScreen(_ sender: Any?) { enterNativeFullScreen?() }
    override func performMiniaturize(_ sender: Any?) { minimizeOrdinaryWindow?() }
    override func cancelOperation(_ sender:Any?) {
        if cancelWorkbenchInteraction?() == true {return}
        super.cancelOperation(sender)
    }
    override func keyDown(with event:NSEvent) {
        if WorkbenchCancelKey.isUnhandledEscape(event),cancelWorkbenchInteraction?() == true {return}
        super.keyDown(with:event)
    }
}


struct WorkbenchUptime:View {
    @ObservedObject var device:DeviceStatusModel
    @Environment(\.workbenchScale) private var displayScale
    @Environment(\.workbenchDeviceExpanded) private var deviceExpanded
    var body:some View {
        HStack(spacing:6*displayScale) {
            Circle().fill(Color(red:0.57,green:0.77,blue:0.65)).frame(width:5*displayScale,height:5*displayScale)
            Text("已运行 \(DeviceFormat.duration(device.snapshot.uptime > 0 ? device.snapshot.uptime : ProcessInfo.processInfo.systemUptime))")
                .font(.system(size:deviceExpanded ? 12:11*displayScale)).monospacedDigit().foregroundStyle(WorkbenchStyle.secondary)
        }.accessibilityElement(children:.combine)
    }
}
struct WorkbenchBrandMark:View {
    @ObservedObject private var icons = ApplicationIconController.shared
    var body:some View {
        Group {
            if let image = icons.image(for: icons.selection) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "square.on.square").resizable().scaledToFit().foregroundStyle(.cyan)
            }
        }.shadow(color:.black.opacity(0.2),radius:3,y:2).accessibilityHidden(true)
    }
}
