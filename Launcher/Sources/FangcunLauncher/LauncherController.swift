import AppKit
import LauncherCore

@MainActor
final class LauncherController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: ConfigurationStore
    var configuration = LauncherConfiguration()
    let hotKey = GlobalHotKey()
    let bindingHotKeys = GlobalBindingHotKeys()
    let catalog = ApplicationCatalog()
    let launcher = TargetLauncher()
    var panel: LauncherPanel!
    var editorPanel: LauncherPanel?
    var settingsWindowController: LauncherSettingsWindowController?
    var workbenchController: WorkbenchWindowController?
    var notificationRouter: WorkbenchNotificationRouter?
    lazy var updates = AppUpdateController(owner: self)
    var preparingUpdateRelaunch = false
    weak var workbenchShortcutRecorder: WorkbenchShortcutRecorder?
    var isPreparingToQuit: Bool { workbenchController?.model.quitting == true }
    var topEntryController: WorkbenchTopEntryController?
    var background: BackdropView!
    var content = LauncherContentSurface()
    let horizontalNavigationGesture = HorizontalNavigationGesture()
    var statusItem: NSStatusItem!
    var previousApp: NSRunningApplication?
    var eventMonitor: Any?
    /// An optional observer of the installed AppKit monitor, used by isolated
    /// native checks to verify real delivery and duplicate-monitor replacement.
    var localEventMonitorDidReceive:((NSEvent)->Void)?
    var observers: [NSObjectProtocol] = []
    var applications: [LaunchTarget] = []
    var searchIndex: [SearchEntry] = []
    var appIndex: [SearchEntry] = []
    var results: [SearchEntry] = []
    var selection = SearchSelection()
    var keyboardSelectionVisible = false
    var searchView = false
    var textMode = false
    var query = ""
    var searchInput = SearchTextView()
    var searchScroll = NSScrollView()
    var resultContainer: FlippedView?
    var resultScroll: NSScrollView?
    var resultScrollObserver: NSObjectProtocol?
    var verticalSelectedIndex = 0
    var verticalScrollOrigin = NSPoint.zero
    var suppressResultScrollUpdates = false
    var resultCountLabel: NSTextField?
    var paginationView: FlippedView?
    var hoverLabel: NSTextField?
    var shortcutHint: LauncherShortcutHint?
    var placeholderLabel: NSTextField?
    var searchClearButton: ActionButton?
    var draft: BindingEditor?
    var lastRemoved: (key:String,binding:KeyBinding,hotKey:BindingHotKey?)?
    var overlay: ShadeView?
    var editor: BindingForm?
    var menu: NSMenu?
    var toastView: CardView?
    var toastTask: Task<Void,Never>?
    var scanning = false
    var scanAgain = false
    var lastScan = Date.distantPast
    var launchPending = false
    var launchEpoch = 0
    var focusTransitionUntil = Date.distantPast
    var storageProblem: String?
    var hotKeyProblem: String?
    var bindingHotKeyProblem: String?
    var hotKeysStarted = false
    var lastSaveError: String?
    private var confirmedTerminationPermit=false
    private(set) var systemTerminationPending=false
    /// Injectable OS boundaries keep exit checks inside an isolated process.
    var terminateApplication:()->Void = {NSApp.terminate(nil)}
    var replyToSystemTermination:(Bool)->Void = {NSApp.reply(toApplicationShouldTerminate:$0)}
    var presentQuitDraftAlert:(NSAlert)->NSApplication.ModalResponse = {$0.runModal()}
    var pickerActive = false
    var lastSize = NSSize.zero
    var expanded = false
    var floatingFrame: NSRect?
    var bindings: [String:KeyBinding] { draft?.bindings ?? configuration.bindings }
    var isEditing: Bool { draft != nil }
    var hasMarkedInput: Bool {
        (panel?.firstResponder as? NSTextView)?.hasMarkedText() == true ||
        (editorPanel?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }
    var searchBodyHeight: CGFloat { 414 }
    var usesVerticalResults: Bool { configuration.settings.resultLayout == .list }
    var verticalFirstVisibleIndex: Int {
        let origin = resultScroll?.contentView.bounds.minY ?? verticalScrollOrigin.y
        return min(results.count,max(0,Int(ceil(origin/138)))*7)
    }
    var size: NSSize {
        expanded ? (panel?.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame.size : NSSize(width:1080,height:560)
    }
    var boardScale: CGFloat { expanded ? size.width/1080 : 1 }
    var recordingHotKeyForm: BindingHotKeyForm? {
        guard editorPanel?.isVisible == true,
              let form = (editorPanel?.contentView as? BindingPopoverSurface)?.card as? BindingHotKeyForm,
              form.recorder.recording else { return nil }
        return form
    }
    /// Footer hints describe registrations that actually succeeded on this Mac.
    var activeDirectLaunchPrefix: KeyShortcutPrefix? {
        guard let prefix = configuration.settings.directLaunchPrefix else { return nil }
        let inheritedKeys = configuration.bindings.keys.filter { configuration.bindingHotKeys[$0] == nil }
        guard !inheritedKeys.isEmpty, inheritedKeys.allSatisfy({ bindingHotKeys.shortcuts[$0] == prefix.shortcut(for:$0) }) else { return nil }
        return prefix
    }
    var applicationViewHotKeyTitle: String? { bindingHotKeys.shortcuts[GlobalBindingHotKeys.applicationViewKey]?.title }

    func shortcutRegistrations(for value:LauncherConfiguration) -> [String:BindingHotKey] {
        var shortcuts = value.effectiveBindingHotKeys
        shortcuts[GlobalBindingHotKeys.applicationViewKey] = value.settings.applicationsEnabled ? value.settings.applicationViewHotKey : nil
        shortcuts[GlobalBindingHotKeys.workbenchKey] = value.settings.workbenchHotKey
        return shortcuts
    }
    func activateGlobalShortcut(_ key:String) {
        guard !isPreparingToQuit else { return }
        if let shortcut = bindingHotKeys.shortcuts[key], workbenchShortcutRecorder?.captureRegisteredHotKey(shortcut) == true { return }
        if let shortcut = bindingHotKeys.shortcuts[key], settingsWindowController?.captureRegisteredHotKey(shortcut) == true { return }
        if let form = recordingHotKeyForm, let shortcut = bindingHotKeys.shortcuts[key] { form.acceptRecordedHotKey(shortcut); return }
        if key == GlobalBindingHotKeys.workbenchKey { showWorkbench(); return }
        if key == GlobalBindingHotKeys.applicationViewKey { toggleApplicationsView(); return }
        guard let binding = configuration.bindings[key], !pickerActive, editorPanel == nil, overlay == nil, !isEditing else { return }
        launch(binding.target)
    }
    func toggleApplicationsView() {
        guard !isPreparingToQuit, !pickerActive else { return }
        guard configuration.settings.applicationsEnabled else { show(); toast("应用面板已关闭，可在设置中重新启用。"); return }
        if editorPanel != nil || overlay != nil || isEditing {
            show(); toast("请先完成当前操作后再切换应用视图。",persistent:true); return
        }
        if panel.isVisible && searchView { hide(restore:true); return }
        show(); setSearch(text:textMode)
    }
    @discardableResult func setDirectLaunchPrefix(_ prefix:KeyShortcutPrefix?) -> Bool {
        var candidate = configuration; candidate.settings.directLaunchPrefix = prefix
        return save(candidate,synchronizeShortcuts:true)
    }
    @discardableResult func setApplicationViewHotKey(_ shortcut:BindingHotKey?) -> Bool {
        var candidate = configuration; candidate.settings.applicationViewHotKey = shortcut
        return save(candidate,synchronizeShortcuts:true)
    }

    @discardableResult func setLauncherHotKey(_ shortcut:BindingHotKey?) -> Bool {
        guard !isPreparingToQuit else {return false}
        var candidate=configuration
        if let shortcut,let legacy=HotKeyChoice.allCases.first(where:{$0.bindingHotKey == shortcut}) {
            candidate.settings.hotKey=legacy;candidate.settings.launcherHotKey=nil
        } else {candidate.settings.launcherHotKey=shortcut}
        return save(candidate,synchronizeShortcuts:true)
    }

    @discardableResult func setWorkbenchHotKey(_ shortcut:BindingHotKey?) -> Bool {
        guard !isPreparingToQuit else { return false }
        var candidate = configuration; candidate.settings.workbenchHotKey = shortcut
        return save(candidate,synchronizeShortcuts:true)
    }

    init(dataDirectory:URL? = nil) {
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let requestedProfile = Bundle.main.object(forInfoDictionaryKey:"FangcunDeviceAcceptanceProfile") as? String ?? "DeviceStatus"
        let profile = requestedProfile.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil ? requestedProfile:"DeviceStatus"
        let testDirectory = Bundle.main.object(forInfoDictionaryKey:"FangcunDeviceAcceptance") as? Bool == true ? support.appendingPathComponent("Fangcun/TestProfiles/\(profile)",isDirectory:true) : nil
        let reviewDirectory:URL? = Bundle.main.object(forInfoDictionaryKey:"FangcunUIReview") as? Bool == true
            ? (Bundle.main.object(forInfoDictionaryKey:"FangcunUIReviewDataDirectory") as? String).map{URL(fileURLWithPath:$0)}
                ?? support.appendingPathComponent("Fangcun/UIReview/"+(Bundle.main.bundleIdentifier ?? "local-review"),isDirectory:true)
            : nil
        let path = dataDirectory ?? reviewDirectory ?? ProcessInfo.processInfo.environment["FANGCUN_DATA_DIRECTORY"].map { URL(fileURLWithPath:$0) } ?? testDirectory ?? support.appendingPathComponent("Fangcun/Launcher",isDirectory:true)
        store = ConfigurationStore(url:path.appendingPathComponent("configuration.json"))
        super.init()
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            if let saved = try store.load() { configuration = saved }
            else { configuration = initialConfiguration(); try store.save(configuration) }
        } catch { storageProblem = "配置读取失败，原文件已保留。\(error.localizedDescription)" }
        configureMenus(); configurePanel()
        FangcunNotificationDelegate.shared.install()
        notificationRouter=WorkbenchNotificationRouter(owner:self)
        hotKey.pressed = { [weak self] in
            guard let self, !isPreparingToQuit else { return }
            if let shortcut = hotKey.shortcut, workbenchShortcutRecorder?.captureRegisteredHotKey(shortcut) == true { return }
            if let shortcut = hotKey.shortcut, settingsWindowController?.captureRegisteredHotKey(shortcut) == true { return }
            if let form = recordingHotKeyForm {
                form.acceptRecordedHotKey(hotKey.shortcut ?? configuration.settings.effectiveLauncherHotKey)
                return
            }
            toggle()
        }
        bindingHotKeys.pressed = { [weak self] key in self?.activateGlobalShortcut(key) }
        if Bundle.main.object(forInfoDictionaryKey:"FangcunUIReview") as? Bool != true {registerStartupHotKeys()}
        installLocalEventMonitor()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] note in
            let identifier = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let identifier, identifier != ProcessInfo.processInfo.processIdentifier, self.panel.isVisible, !self.panel.isKeyWindow, self.editorPanel?.isKeyWindow != true, !self.hasMarkedInput, self.menu == nil, !self.pickerActive, !self.launchPending, Date() >= self.focusTransitionUntil else { return }
                self.hide(restore:false)
            }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName:Notification.Name("local.fangcun.launcher.show"),object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.show() } })
        refreshApplications()
        observers.append(DistributedNotificationCenter.default().addObserver(forName:Notification.Name("local.fangcun.workbench.show"),object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.showWorkbench() } })
        topEntryController = WorkbenchTopEntryController(owner: self)
        if Bundle.main.object(forInfoDictionaryKey:"FangcunUIReview") as? Bool != true {topEntryController?.start()}
        performStartupPresentation(FangcunStartupPresentation(arguments:CommandLine.arguments))
        if Bundle.main.object(forInfoDictionaryKey: "FangcunUIReview") as? Bool != true {
            updates.startAutomaticCheckingIfEnabled()
        }
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool { showWorkbench(); return true }
    /// Only the ordinary workbench participates in Dock and Command-Tab. Mini,
    /// widgets and the launcher remain temporary accessory surfaces.
    func setWorkbenchDockVisible(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowDidResignKey(_ notification:Notification) {
        guard notification.object as? NSWindow === panel || notification.object as? NSWindow === editorPanel else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow, self.editorPanel?.isKeyWindow != true, !NSApp.isActive, !self.pickerActive, self.menu == nil, !self.launchPending, Date() >= self.focusTransitionUntil else { return }
            if self.hasMarkedInput { return }
            self.hide(restore:false)
        }
    }
    /// One production monitor installation is shared with isolated native event checks.
    /// Reinstallation never stacks handlers on the same controller.
    func installLocalEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else {return false}
                self.localEventMonitorDidReceive?(event)
                if event.type != .keyDown {
                    self.dismissLauncherForWorkbenchInteraction(event)
                    return false // The original click must still reach the workbench.
                }
                guard event.window === self.panel || event.window === self.editorPanel else { return false }
                return self.route(event)
            }
            return handled ? nil : event
        }
    }
    /// Local clicks do not emit another-app activation notifications. Treat a
    /// workbench click just like clicking outside the transient launcher while
    /// preserving editors, composition, menus and native picker sessions.
    func dismissLauncherForWorkbenchInteraction(_ event:NSEvent) {
        guard panel?.isVisible == true, !pickerActive, menu == nil, !launchPending,
              editorPanel == nil, !isEditing, !hasMarkedInput,
              let clicked=event.window, let workbench=workbenchController,
              clicked === workbench.presentationWindow else {return}
        closeOverlay(render:false)
        hide(restore:false)
    }
    var hasUnsavedLauncherChanges: Bool {
        let card = (editorPanel?.contentView as? BindingPopoverSurface)?.card
        return editor?.hasChanges == true || (draft != nil && draft?.bindings != configuration.bindings)
            || (card as? BindingHotKeyForm)?.hasChanges == true
            || (card as? ScanDirectoriesCard)?.hasChanges == true
    }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if confirmedTerminationPermit {confirmedTerminationPermit=false;return .terminateNow}
        if preparingUpdateRelaunch {
            // Sparkle may retry termination after a cancelled save decision
            // without repeating its relaunch notification. Keep this intent
            // until it aborts or the prepared termination actually succeeds.
            guard let workbench = workbenchController ?? prepareWorkbenchServices() else { return .terminateCancel }
            // Install & Relaunch was explicitly chosen in Sparkle. Reuse all
            // save, process-transaction and notification barriers without a second quit prompt.
            workbench.model.confirmQuit()
            guard workbench.model.quitting else { return .terminateCancel }
            systemTerminationPending = true
            return .terminateLater
        }
        // Dock, logout and other native terminate requests must use the same
        // confirmation and async preparation as the in-app quit command.
        guard let workbench=workbenchController ?? prepareWorkbenchServices() else {return .terminateCancel}
        systemTerminationPending=true
        guard workbench.model.requestQuit() else {
            systemTerminationPending=false
            return .terminateCancel
        }
        return .terminateLater
    }
    /// Resolves existing drafts only. It never authorizes OS termination before
    /// the health transaction and local notification barriers have completed.
    func resolveQuitDrafts() -> NSApplication.TerminateReply {
        if let workbenchController,workbenchController.model.modals.isPresented {
            workbenchController.present();return .terminateCancel
        }
        if let workbenchController,let sheet=workbenchController.presentationWindow?.attachedSheet {
            workbenchController.present();sheet.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        if let workbenchController,!workbenchController.model.vault.flush() {
            workbenchController.present(route:.vault)
            let alert=NSAlert();alert.messageText="私密资料尚未写入磁盘";alert.informativeText="当前加密草稿仍在内存中。可以返回重试保存，或放弃本次未保存的修改并退出。"
            alert.addButton(withTitle:"返回重试");alert.addButton(withTitle:"放弃未保存修改并退出")
            return presentQuitDraftAlert(alert) == .alertSecondButtonReturn ? .terminateNow:.terminateCancel
        }
        guard hasUnsavedLauncherChanges else { return .terminateNow }
        panel.makeKeyAndOrderFront(nil); editorPanel?.makeKeyAndOrderFront(nil)
        let alert = NSAlert(); alert.messageText = "还有未保存的修改"; alert.informativeText = "退出前可以保存，也可以返回继续编辑。"
        alert.addButton(withTitle:"保存并退出"); alert.addButton(withTitle:"继续编辑"); alert.addButton(withTitle:"放弃并退出")
        return resolveTerminationChoice(presentQuitDraftAlert(alert))
    }
    /// Shared by the native quit alert and checks that never terminate the test process.
    func resolveTerminationChoice(_ response:NSApplication.ModalResponse) -> NSApplication.TerminateReply {
        switch response {
        case .alertFirstButtonReturn:
            let card = (editorPanel?.contentView as? BindingPopoverSurface)?.card
            if let form = card as? BindingHotKeyForm, form.hasChanges, !form.save() { return .terminateCancel }
            if let form = card as? ScanDirectoriesCard, form.hasChanges, !form.save() { return .terminateCancel }
            if let editor { editor.save(); if self.editor != nil { return .terminateCancel } }
            if draft != nil { finishEditing(save:true); if draft != nil { return .terminateCancel } }
            return .terminateNow
        case .alertThirdButtonReturn: return .terminateNow
        default:
            if let editorPanel { editorPanel.makeKeyAndOrderFront(nil) }
            else { panel.makeKeyAndOrderFront(nil); focus() }
            return .terminateCancel
        }
    }
    func applicationWillTerminate(_ notification:Notification) { notificationRouter?.stop(); workbenchShortcutRecorder?.cancel(); topEntryController?.stop(); workbenchController?.model.shutdown(); hotKey.unregister(); bindingHotKeys.unregister(); if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }; toastTask?.cancel() }

    func initialConfiguration() -> LauncherConfiguration {
        var value = LauncherConfiguration()
        let choices = [("S","com.apple.Safari"),("F","com.apple.finder"),("N","com.apple.Notes"),("C","com.apple.iCal"),("E","com.apple.mail"),("T","com.apple.Terminal"),("X","com.apple.dt.Xcode"),("G","com.google.Chrome"),("Y","com.apple.Preview"),("O","com.apple.Photos"),("H","com.apple.reminders"),("A","com.apple.shortcuts"),("M","com.apple.Music"),("I","com.apple.MobileSMS")]
        for (key,id) in choices { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:id) { value.bindings[key] = KeyBinding(target:TargetResolver.target(kind:.app,url:url)) } }
        return value
    }
    @objc private func compactAcceptanceWindow() { resizeAcceptanceWindow(NSSize(width: 900, height: 620)) }
    @objc private func standardAcceptanceWindow() { resizeAcceptanceWindow(NSSize(width: 1120, height: 758)) }
    private func resizeAcceptanceWindow(_ size: NSSize) {
        guard Bundle.main.object(forInfoDictionaryKey: "FangcunDeviceAcceptance") as? Bool == true,
              let window = workbenchController?.presentationWindow, window.attachedSheet == nil, !window.styleMask.contains(.fullScreen) else { return }
        window.setContentSize(size); window.center()
    }
#if DEBUG
    /// UI-only diagnostic for checking presentation over another app's full-screen Space.
    /// The delay allows switching apps; it does not synthesize input or replace hover checks.
    @objc private func previewTopEntry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.topEntryController?.previewInteraction() }
    }
#endif

    func configureMenus() {
        let main = NSMenu()
        let application = NSMenuItem(); let submenu = NSMenu()
        submenu.addItem(withTitle:"关于方寸",action:#selector(showAbout),keyEquivalent:"").target = self
        submenu.addItem(withTitle:"方寸设置…",action:#selector(allSettingsFromMenu),keyEquivalent:",").target = self
        submenu.addItem(withTitle:"检查更新",action:#selector(checkForUpdatesFromMenu),keyEquivalent:"").target = self
        submenu.addItem(.separator())
        submenu.addItem(withTitle:"退出方寸",action:#selector(requestQuitFromMenu),keyEquivalent:"q").target=self
        application.submenu = submenu; main.addItem(application)
        let edit = NSMenuItem(title:"编辑",action:nil,keyEquivalent:""); let editMenu = NSMenu(title:"编辑")
        for (title,selector,key) in [("撤销",Selector(("undo:")),"z"),("剪切",#selector(NSText.cut(_:)),"x"),("拷贝",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] { editMenu.addItem(withTitle:title,action:selector,keyEquivalent:key) }
        edit.submenu = editMenu; main.addItem(edit)
        let window = NSMenuItem(title:"窗口",action:nil,keyEquivalent:""); let windowMenu = NSMenu(title:"窗口")
        windowMenu.addItem(withTitle:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        let fullScreen=windowMenu.addItem(withTitle:"切换全屏",action:#selector(toggleWorkbenchFullScreenFromMenu),keyEquivalent:"f");fullScreen.keyEquivalentModifierMask=[.command,.control];fullScreen.target=self
        if Bundle.main.object(forInfoDictionaryKey: "FangcunDeviceAcceptance") as? Bool == true {
            windowMenu.addItem(.separator())
            let compact = windowMenu.addItem(withTitle: "验收：紧凑窗口 900 × 620", action: #selector(compactAcceptanceWindow), keyEquivalent: "1")
            compact.keyEquivalentModifierMask = [.command, .option]; compact.target = self
            let standard = windowMenu.addItem(withTitle: "验收：标准窗口 1120 × 758", action: #selector(standardAcceptanceWindow), keyEquivalent: "2")
            standard.keyEquivalentModifierMask = [.command, .option]; standard.target = self
        }
#if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "FangcunTopEntryDiagnostics") as? Bool == true {
            let preview = windowMenu.addItem(withTitle: "诊断：3 秒后展开顶部工作台", action: #selector(previewTopEntry), keyEquivalent: "3")
            preview.keyEquivalentModifierMask = [.command, .option]; preview.target = self
        }
#endif
        window.submenu = windowMenu; main.addItem(window); NSApp.windowsMenu = windowMenu; NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        statusItem.button?.title = "方寸"; statusItem.button?.toolTip = "方寸 · 启动器"
        let statusMenu = NSMenu()
        for (title,action) in [("打开工作台",#selector(workbenchFromMenu)),("打开启动器",#selector(showFromMenu)),("方寸设置…",#selector(allSettingsFromMenu)),("启动器设置…",#selector(settingsFromMenu)),("刷新应用列表",#selector(refreshFromMenu))] { statusMenu.addItem(withTitle:title,action:action,keyEquivalent:"").target = self }
        statusMenu.addItem(withTitle:"检查更新",action:#selector(checkForUpdatesFromMenu),keyEquivalent:"").target=self
        statusMenu.addItem(.separator()); statusMenu.addItem(withTitle:"退出方寸",action:#selector(requestQuitFromMenu),keyEquivalent:"q").target=self
        statusItem.menu = statusMenu
    }
    @objc func requestQuitFromMenu() {
        showWorkbench()
        workbenchController?.model.requestQuit()
    }
    @objc func checkForUpdatesFromMenu() { updates.checkForUpdates() }
    @objc func toggleWorkbenchFullScreenFromMenu() {workbenchController?.requestToggleFullScreen()}
    func finishConfirmedQuit() {
        // Safety and the user's save/discard choice were already resolved exactly
        // once before asynchronous notification suspension. The preparation overlay
        // blocks new edits until this one-shot native termination is consumed.
        if systemTerminationPending {
            systemTerminationPending=false
            replyToSystemTermination(true)
        } else {
            confirmedTerminationPermit=true
            terminateApplication()
            confirmedTerminationPermit=false
        }
    }
    func cancelPendingSystemTermination() {
        guard systemTerminationPending else {return}
        systemTerminationPending=false
        replyToSystemTermination(false)
    }
    @objc func showFromMenu() { show() }
    @objc func settingsFromMenu() { show(); showSettings() }
    @objc func refreshFromMenu() { refreshApplications(force:true) }
    @objc func showAbout() { show(); showHelp() }
    func configurePanel() {
        panel = LauncherPanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title = "方寸启动器"; panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.transient]
        panel.isMovableByWindowBackground = true; panel.delegate = self; panel.appearance = NSAppearance(named:.darkAqua)
        background = BackdropView(frame:NSRect(origin:.zero,size:size)); panel.contentView = background
        content.frame = background.bounds; content.autoresizingMask = [.width,.height]; background.addSubview(content)
        content.scrollHandler = { [weak self] event in
            guard let self, !searchView, canHandleHorizontalNavigation else { return false }
            return horizontalNavigationGesture.handleScroll(deltaX:event.scrollingDeltaX,deltaY:event.scrollingDeltaY,phase:event.phase,momentumPhase:event.momentumPhase,precise:event.hasPreciseScrollingDeltas,timestamp:event.timestamp) { [weak self] direction in self?.handleHorizontalNavigation(direction) }
        }
        searchInput.configure()
        searchInput.changed = { [weak self] text in guard let self else { return }; query = text.replacingOccurrences(of:"\n",with:" "); resetSearchSelection(); renderResults() }
        searchInput.clicked = { [weak self] in self?.panel.makeFirstResponder(self?.searchInput) }
        searchInput.editingChanged = { [weak self] in
            guard let self else { return }
            placeholderLabel?.isHidden = !searchInput.string.isEmpty
            searchClearButton?.isHidden = searchInput.string.isEmpty
        }
        searchInput.command = { [weak self] selector in self?.searchCommand(selector) ?? false }
    }
    func toggle() { guard !isPreparingToQuit else { return }; if panel.isVisible { hide(restore:true) } else { show() } }
    func show() {
        guard !isPreparingToQuit else { return }
        topEntryController?.handleContextChange()
        if !panel.isVisible {
            previousApp = NSWorkspace.shared.frontmostApplication
            if overlay == nil && editorPanel == nil && draft == nil {
                searchView = LauncherPresentationPolicy.initialView(configuration.settings) == .applications
                textMode = configuration.settings.defaultSearchInputMode == .text
                query = ""; resetSearchSelection()
            }
        }
        launchEpoch += 1; launchPending = false
        render(); placePanel(center:true); NSApp.activate(); panel.makeKeyAndOrderFront(nil)
        if let editorPanel { editorPanel.makeKeyAndOrderFront(nil) } else { focus() }
        refreshApplications()
        if let storageProblem { toast(storageProblem,persistent:true) } else if let hotKeyProblem { toast(hotKeyProblem,persistent:true) } else if let bindingHotKeyProblem { toast(bindingHotKeyProblem,persistent:true) }
    }
    func hide(restore:Bool) {
        guard panel.isVisible, !pickerActive else { return }
        menu?.cancelTracking(); launchEpoch += 1; launchPending = false
        editorPanel?.orderOut(nil); panel.orderOut(nil)
        if restore, let previousApp, !previousApp.isTerminated, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp.activate() }
    }
    func placePanel(center:Bool = false) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let available = (expanded ? panel.screen ?? screen : screen).visibleFrame
        if expanded {
            panel.setFrame(available,display:true); lastSize = available.size; return
        }
        let desired = size
        var origin = panel.frame.origin
        if center || lastSize == .zero { origin = NSPoint(x:available.midX-desired.width/2,y:available.midY-desired.height/2+available.height*0.05) }
        else { origin = NSPoint(x:panel.frame.midX-desired.width/2,y:panel.frame.midY-desired.height/2) }
        origin.x = min(max(available.minX+10,origin.x),available.maxX-desired.width-10)
        origin.y = min(max(available.minY+10,origin.y),available.maxY-desired.height-10)
        panel.setFrame(NSRect(origin:origin,size:desired),display:true,animate:panel.isVisible && lastSize != .zero && desired.width != lastSize.width && !configuration.settings.reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        lastSize = desired
    }
    func toggleExpanded() {
        guard !isPreparingToQuit else { return }
        guard editorPanel == nil, overlay == nil else { return }
        if expanded {
            expanded = false; panel.isMovableByWindowBackground = true
            if let floatingFrame { panel.setFrame(floatingFrame,display:true); lastSize = floatingFrame.size }
        } else {
            floatingFrame = panel.frame; expanded = true; panel.isMovableByWindowBackground = false
        }
        render(); focus()
    }
    func focus() { if isPreparingToQuit || overlay != nil || editorPanel != nil { return }; panel.makeFirstResponder(searchView ? searchInput : content) }
    func rebuildIndex() {
        let hidden = Set(configuration.hiddenApplications)
        let discovered = SearchEngine.entries(applications:applications+configuration.addedApplications,bindings:[:],includeBindings:false).map(\.target).filter { !hidden.contains($0.id) }
        let ordered = ApplicationSorter.sorted(discovered,mode:configuration.settings.appSort,order:configuration.applicationOrder,metadata:configuration.applicationMetadata,starred:configuration.starredApplications)
        appIndex = ordered.map { SearchEntry(target:$0) }
        let ranks = Dictionary(uniqueKeysWithValues:ordered.enumerated().map { ($0.element.id,$0.offset) })
        // A bound app can live outside every catalog directory. Enrich only its
        // in-memory search copy; never replace the user's alias or saved keywords.
        let catalogIDs = Set(ordered.map(\.id))
        let indexedBindings = bindings.mapValues { binding in
            var indexed = binding
            if binding.target.kind == .app, !catalogIDs.contains(binding.target.id) {
                let metadata = ApplicationNames.searchKeywords(for:URL(fileURLWithPath:binding.target.location))
                indexed.target.keywords = [binding.target.keywords,metadata].filter { !$0.isEmpty }.joined(separator:"\n")
            }
            return indexed
        }
        searchIndex = SearchEngine.entries(applications:ordered,bindings:indexedBindings,includeBindings:true).filter { $0.target.kind != .app || !hidden.contains($0.id) }.sorted {
            let first = ranks[$0.id] ?? Int.max, second = ranks[$1.id] ?? Int.max
            if first != second { return first < second }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    func refreshApplications(force:Bool = false) {
        if scanning { if force { scanAgain = true }; return }
        guard force || Date().timeIntervalSince(lastScan)>30 else { return }
        scanning = true
        let directories = configuration.scanDirectories
        Task {
            let found = await catalog.scan(extraRoots:directories)
            let metadata = await catalog.metadata(for:found+configuration.addedApplications,existing:configuration.applicationMetadata)
            applications = found; scanning = false; lastScan = Date(); IconCache.shared.clear()
            var refreshed = configuration
            for (id,record) in metadata {
                var latest = refreshed.applicationMetadata[id] ?? record
                latest.installedAt = record.installedAt; refreshed.applicationMetadata[id] = latest
            }
            for (key,binding) in refreshed.bindings where binding.target.kind == .app {
                if let name = ApplicationNames.chinese[binding.target.bundleIdentifier ?? ""] { refreshed.bindings[key]?.target.name = name }
            }
            if refreshed != configuration, storageProblem == nil { _ = save(refreshed) }
            rebuildIndex()
            if panel.isVisible && overlay == nil { if searchView { renderResults() } else { render() } }
            editor?.refreshChoices()
            if scanAgain || directories != configuration.scanDirectories { scanAgain = false; refreshApplications(force:true) }
        }
    }
    /// Apply both groups together when the launcher shortcut changes. Releasing the
    /// old group first also permits a restored configuration to exchange shortcuts.
    func registerStartupHotKeys() {
        hotKeysStarted = true
        let mainStatus = hotKey.register(configuration.settings.effectiveLauncherHotKey)
        hotKeyProblem = mainStatus == 0 ? nil : "快捷键注册失败（\(mainStatus)）。可从菜单栏打开并重新选择。"
        let desired = shortcutRegistrations(for:configuration)
        let status = bindingHotKeys.register(desired)
        if status == 0 { bindingHotKeyProblem = nil }
        else {
            let failed = registerAvailableBindingHotKeys(desired)
            bindingHotKeyProblem = failed.isEmpty ? nil : "以下快捷键不可用：\(shortcutFailureDescription(failed))。其他可用快捷键已保留，请在设置中重新选择。"
        }
    }
    /// Used only when restoring an existing configuration, never to partially
    /// commit a user-requested shortcut change.
    func registerAvailableBindingHotKeys(_ desired:[String:BindingHotKey]) -> [String:Int32] {
        var available = bindingHotKeys.shortcuts.filter { desired[$0.key] == $0.value }
        _ = bindingHotKeys.register(available)
        var failed:[String:Int32] = [:]
        for key in desired.keys.sorted() where available[key] == nil {
            var candidate = available; candidate[key] = desired[key]
            let status = bindingHotKeys.register(candidate)
            if status == 0 { available = candidate } else { failed[key] = status }
        }
        return failed
    }
    func shortcutFailureDescription(_ failed:[String:Int32]) -> String {
        failed.keys.sorted().map { key in
            let title = key == GlobalBindingHotKeys.workbenchKey ? "工作台" : key == GlobalBindingHotKeys.applicationViewKey ? "应用面板" : "\(key) 键"
            return "\(title)（\(failed[key]!)）"
        }.joined(separator:"、")
    }
    func registerHotKeys(main:HotKeyChoice?,bindings:[String:BindingHotKey]) -> (main:Int32,bindings:Int32) {registerHotKeys(mainShortcut:main?.bindingHotKey,bindings:bindings)}
    func registerHotKeys(mainShortcut main:BindingHotKey?,bindings:[String:BindingHotKey]) -> (main:Int32,bindings:Int32) {
        if main != nil { hotKeysStarted = true }
        if main == hotKey.shortcut { return (0,bindingHotKeys.register(bindings)) }
        bindingHotKeys.unregister(); hotKey.unregister()
        if let main {
            let status = hotKey.register(main)
            guard status == 0 else { return (status,0) }
        }
        return (0,bindingHotKeys.register(bindings))
    }
    @discardableResult func restoreHotKeys(main:HotKeyChoice?,bindings:[String:BindingHotKey]) -> String {restoreHotKeys(mainShortcut:main?.bindingHotKey,bindings:bindings)}
    @discardableResult func restoreHotKeys(mainShortcut main:BindingHotKey?,bindings:[String:BindingHotKey]) -> String {
        if main == hotKey.shortcut, bindings == bindingHotKeys.shortcuts { return "" }
        // A conflict in either group must not prevent restoring the other group.
        bindingHotKeys.unregister(); hotKey.unregister()
        var failures:[String] = []
        if let main {
            let status = hotKey.register(main)
            if status != 0 {
                let message = "原呼出快捷键暂时无法恢复（\(status)），可从菜单栏重新设置。"
                hotKeyProblem = message; failures.append(message)
            }
        }
        let status = bindingHotKeys.register(bindings)
        if status != 0 {
            // Restore unaffected bindings even if another process claimed one of
            // the previous combinations during this transaction.
            let failed = registerAvailableBindingHotKeys(bindings)
            if !failed.isEmpty {
                let message = "以下原快捷键暂时无法恢复：\(shortcutFailureDescription(failed))。其他可用快捷键已恢复，请重新设置。"
                bindingHotKeyProblem = message; failures.append(message)
            }
        }
        return failures.joined(separator:" ")
    }
    @discardableResult func save(_ candidate:LauncherConfiguration,synchronizeShortcuts:Bool = false) -> Bool {
        guard !isPreparingToQuit else { lastSaveError = "正在准备退出，请稍后再修改设置。"; return false }
        var candidate = candidate
        candidate.bindingHotKeys = candidate.bindingHotKeys.filter { candidate.bindings[$0.key] != nil }
        lastSaveError = nil
        do { try candidate.validate() }
        catch { lastSaveError = error.localizedDescription; toast(error.localizedDescription,persistent:true); return false }
        let previousMain = hotKey.shortcut, previousShortcuts = bindingHotKeys.shortcuts
        let desiredShortcuts = shortcutRegistrations(for:candidate)
        let mainChanged = candidate.settings.effectiveLauncherHotKey != configuration.settings.effectiveLauncherHotKey || (hotKeysStarted && candidate.settings.effectiveLauncherHotKey != hotKey.shortcut)
        let shortcutsChanged = synchronizeShortcuts || mainChanged || desiredShortcuts != shortcutRegistrations(for:configuration)
        if shortcutsChanged {
            let status = registerHotKeys(mainShortcut:mainChanged ? candidate.settings.effectiveLauncherHotKey : previousMain,bindings:desiredShortcuts)
            guard status.main == 0, status.bindings == 0 else {
                let rollback = restoreHotKeys(mainShortcut:previousMain,bindings:previousShortcuts)
                let code = status.main != 0 ? status.main : status.bindings
                lastSaveError = "快捷键已被占用或不可用（\(code)）。" + (rollback.isEmpty ? "原设置已保留。" : "配置未改变。" + rollback)
                toast(lastSaveError!,persistent:true); return false
            }
        }
        do {
            let previousSettings = configuration.settings
            try store.save(candidate); configuration = candidate; storageProblem = nil
            applyPanelSettings(previous:previousSettings)
            if mainChanged { hotKeyProblem = nil }
            if shortcutsChanged { bindingHotKeyProblem = nil }
            rebuildIndex(); NotificationCenter.default.post(name:.fangcunConfigurationChanged,object:self); return true
        } catch {
            let rollback = shortcutsChanged ? restoreHotKeys(mainShortcut:previousMain,bindings:previousShortcuts) : ""
            lastSaveError = "保存失败，修改仍保留在当前编辑中。\(error.localizedDescription)" + rollback
            toast(lastSaveError!,persistent:true); return false
        }
    }
    @discardableResult func recoverConfiguration() -> Bool {
        guard !isPreparingToQuit else { return false }
        let candidate:LauncherConfiguration
        do { candidate = try store.decode(Data(contentsOf:store.backupURL)) }
        catch { lastSaveError = "恢复失败：\(error.localizedDescription)"; toast(lastSaveError!,persistent:true); return false }
        let previousMain = hotKey.shortcut, previousShortcuts = bindingHotKeys.shortcuts
        let restoredShortcuts = shortcutRegistrations(for:candidate)
        let status = registerHotKeys(mainShortcut:candidate.settings.effectiveLauncherHotKey,bindings:restoredShortcuts)
        guard status.main == 0, status.bindings == 0 else {
            let rollback = restoreHotKeys(mainShortcut:previousMain,bindings:previousShortcuts)
            let code = status.main != 0 ? status.main : status.bindings
            lastSaveError = "恢复配置中的快捷键被占用或不可用（\(code)），当前配置已保留。" + rollback
            toast(lastSaveError!,persistent:true); return false
        }
        do {
            // Verify the prepared backup is still the one about to be recovered.
            guard try store.decode(Data(contentsOf:store.backupURL)) == candidate else {
                throw LauncherError.storage("备份在恢复过程中发生变化，请重新恢复。")
            }
            let previousSettings = configuration.settings
            configuration = try store.recoverPrevious()
            applyPanelSettings(previous:previousSettings)
            storageProblem = nil; hotKeyProblem = nil; bindingHotKeyProblem = nil; lastSaveError = nil
            lastRemoved = nil; resetSearchSelection(); rebuildIndex(); refreshApplications(force:true)
            toast("配置已恢复，原配置文件已另存保留"); return true
        } catch {
            let rollback = restoreHotKeys(mainShortcut:previousMain,bindings:previousShortcuts)
            lastSaveError = "恢复失败，当前配置已保留。\(error.localizedDescription)" + rollback
            toast(lastSaveError!,persistent:true); return false
        }
    }
    @discardableResult func setBindingHotKey(_ shortcut:BindingHotKey?,for key:String) -> Bool {
        guard !isEditing else { toast("请先完成绑定编辑，再设置快捷键。",persistent:true); return false }
        guard KeyboardLayout.keys.contains(key), bindings[key] != nil else { toast("请先绑定这个按键。",persistent:true); return false }
        var candidate = configuration
        if let shortcut {
            do { try shortcut.validate() } catch { toast(error.localizedDescription,persistent:true); return false }
            candidate.bindingHotKeys[key] = shortcut
        } else { candidate.bindingHotKeys.removeValue(forKey:key) }
        return save(candidate,synchronizeShortcuts:true)
    }
    func updateSettings(_ transform:(inout LauncherSettings)->Void) -> Bool {
        var candidate = configuration; transform(&candidate.settings)
        if isEditing && !candidate.settings.actionsEnabled {
            lastSaveError = "请先完成或取消绑定编辑，再关闭动作面板。"
            toast(lastSaveError!,persistent:true); return false
        }
        return save(candidate)
    }
    func applyPanelSettings(previous:LauncherSettings) {
        if previous.defaultSearchInputMode != configuration.settings.defaultSearchInputMode, !hasMarkedInput {
            textMode = configuration.settings.defaultSearchInputMode == .text
        }
        if !isEditing, editorPanel == nil, overlay == nil {
            if searchView && !configuration.settings.applicationsEnabled { searchView = false }
            else if !searchView && !configuration.settings.actionsEnabled { searchView = true }
        }
    }
    func setDisplay(_ mode:DisplayMode) { if updateSettings({ $0.display = mode }) { closeOverlay(); render(); focus() } }
    func setSearch(text:Bool? = nil) {
        guard !isEditing, configuration.settings.applicationsEnabled else { return }
        searchView = true; textMode = text ?? (configuration.settings.defaultSearchInputMode == .text); render(); focus()
        if textMode { searchInput.setSelectedRange(NSRange(location:(query as NSString).length,length:0)) }
    }
    func setKeys() { guard configuration.settings.actionsEnabled else { return }; searchView = false; render(); focus() }
    func toggleMainView() {
        guard configuration.settings.actionsEnabled, configuration.settings.applicationsEnabled,
              !isEditing, overlay == nil, editorPanel == nil, menu == nil, !pickerActive else { return }
        if searchView { setKeys() } else { setSearch(text:textMode) }
    }
    var canHandleHorizontalNavigation: Bool {
        configuration.settings.resultLayout == .grid && !isEditing && overlay == nil && editorPanel == nil && menu == nil && !pickerActive && !hasMarkedInput
    }
    func handleHorizontalNavigation(_ direction:Int) {
        guard canHandleHorizontalNavigation else { return }
        switch HorizontalNavigation.destination(applications:searchView,page:selection.page,direction:direction,settings:configuration.settings) {
        case .none: break
        case .actions: setKeys()
        case .applications: setSearch(text:textMode)
        case .page(let delta): changePage(delta)
        }
    }

    func render() {
        guard panel != nil else { return }
        if !isEditing, editorPanel == nil, overlay == nil {
            if searchView && !configuration.settings.applicationsEnabled { searchView = false }
            else if !searchView && !configuration.settings.actionsEnabled { searchView = true }
        }
        Palette.isLight = configuration.settings.workbenchAppearance == .light || (configuration.settings.workbenchAppearance == .system && NSApp.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .aqua)
        Palette.glassOpacity = configuration.settings.glassOpacity
        Palette.workbenchTheme = configuration.settings.workbenchTheme
        panel.appearance = NSAppearance(named:configuration.settings.lightAppearance ? .aqua : .darkAqua)
        background.fullScreen = expanded; background.refreshAppearance()
        if searchView { refreshSearchData() }
        // The native text view survives result updates so the IME retains its composition session.
        if let resultScrollObserver { NotificationCenter.default.removeObserver(resultScrollObserver); self.resultScrollObserver = nil }
        resultScroll = nil
        content.subviews.forEach { $0.removeFromSuperview() }
        resultContainer = nil; paginationView = nil; toastView?.removeFromSuperview(); toastView = nil
        placePanel()
        let w = size.width, h = size.height
        let footerY = h - (expanded ? 59 : 50), footerInset:CGFloat = expanded ? 16 : 0
        let chromeOffset = expanded ? NSPoint(x:16,y:20) : .zero
        content.addSubview(LauncherBrandView(frame:NSRect(x:32+chromeOffset.x,y:31+chromeOffset.y,width:85,height:32)))
        if !isEditing {
            let switcher = LauncherViewSwitcher(frame:NSRect(x:129+chromeOffset.x,y:31+chromeOffset.y,width:127,height:32),applications:searchView) { [weak self] applications in
                guard let self else { return }
                if applications { setSearch(text:textMode) } else { setKeys() }
            }
            for (index,view) in switcher.subviews.compactMap({ $0 as? NSControl }).enumerated() {
                let enabled = index == 0 ? configuration.settings.actionsEnabled : configuration.settings.applicationsEnabled
                view.isEnabled = enabled; view.alphaValue = enabled ? 1 : 0.38
            }
            content.addSubview(switcher)
            let workbench = LauncherWorkbenchButton(frame:NSRect(x:w-118-chromeOffset.x,y:31+chromeOffset.y,width:86,height:32)) { [weak self] in
                self?.showWorkbench()
            }
            content.addSubview(workbench)
        } else {
            label("编辑绑定",x:112,y:31,width:120,height:18,size:12,color:Palette.secondary)
            button("取消",rect:NSRect(x:w-172,y:23,width:64,height:34),border:true) { [weak self] in self?.finishEditing(save:false) }
            button("完成",rect:NSRect(x:w-98,y:23,width:70,height:34),primary:true) { [weak self] in self?.finishEditing(save:true) }
        }
        if searchView && !isEditing { renderSearch() } else { renderBoard() }
        hoverLabel = label(isEditing ? "点击修改 · 拖动交换位置" : "",x:220,y:footerY+6,width:w-440,height:20,size:11,color:Palette.secondary,alignment:.center)
        shortcutHint = nil
        if !isEditing && !searchView {
            let hint = LauncherShortcutHint(frame:NSRect(x:220,y:footerY+2,width:w-440,height:28),prefix:activeDirectLaunchPrefix?.title,summon:hotKey.shortcut?.title)
            content.addSubview(hint); shortcutHint = hint
        }
        if isEditing {
            let undo = button("撤销上一步",rect:NSRect(x:w-174,y:h-50,width:126,height:32)) { [weak self] in self?.undoDraft() }; undo.isEnabled = !(draft?.history.isEmpty ?? true)
        } else {
            if !expanded {
                iconButton(configuration.settings.lightAppearance ? "sun.max" : "moon.fill",label:configuration.settings.lightAppearance ? "切换深色外观" : "切换浅色外观",x:32,y:footerY) { [weak self] in
                    guard let self else { return }; if updateSettings({ $0.lightAppearance.toggle() }) { render(); focus() }
                }
            }
            if !expanded {
                let opacity=button("",symbol:"circle.lefthalf.filled",rect:NSRect(x:108,y:footerY,width:32,height:32)) {}
                opacity.setAccessibilityLabel("全局透明度");opacity.toolTip="调整所有方寸窗口的不透明度"
                opacity.actionBlock={ [weak self,weak opacity] in if let self,let opacity {showOpacityMenu(anchor:opacity)} }
            }
            iconButton(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",label:expanded ? "退出全屏" : "全屏启动器",x:expanded ? 48 : 70,y:footerY) { [weak self] in self?.toggleExpanded() }
            if searchView {
                let pages = FlippedView(frame:NSRect(x:w/2-130,y:footerY+4,width:260,height:26))
                pages.setAccessibilityElement(true); pages.setAccessibilityRole(.group); pages.setAccessibilityLabel("应用分页")
                content.addSubview(pages); paginationView = pages; updatePageIndicators()
            }
            if searchView {
                let trigger = LauncherLayoutButton(frame:NSRect(x:w-146-footerInset,y:footerY,width:72,height:32)) {}
                trigger.activate = { [weak self,weak trigger] in if let self, let trigger { showSearchOptions(anchor:trigger) } }; content.addSubview(trigger)
                trigger.setAccessibilityLabel("应用显示选项"); trigger.toolTip = "视图、排序与搜索方式"
            } else {
                let trigger = LauncherLayoutButton(frame:NSRect(x:w-146-footerInset,y:footerY,width:72,height:32)) { [weak self] in self?.showDisplayMenu() }; content.addSubview(trigger)
                trigger.setAccessibilityLabel("按键显示方式")
            }
            iconButton("gearshape",label:"启动器设置",x:w-64-footerInset,y:footerY) { [weak self] in self?.showSettings() }
        }
        content.setAccessibilityHidden(overlay != nil)
        if let overlay { background.addSubview(overlay); overlay.frame = background.bounds; centerOverlay() }
    }
    func renderBoard() {
        if configuration.settings.display == .list {
            let inset:CGFloat=expanded ? 90:96
            let list=LauncherBindingListView(owner:self,frame:NSRect(x:inset,y:76,width:size.width-2*inset,height:size.height-156))
            content.addSubview(list);return
        }
        let mode = configuration.settings.display, scale = boardScale
        let pitch:CGFloat = switch mode { case .full:98; case .key:82; case .name:92; case .icon:82; case .list:48 }
        let rowStep = pitch*scale
        let cellHeight:CGFloat = mode.showsName ? 98 : 80
        let boardHeight = rowStep*3+cellHeight*scale
        let floatingTop:CGFloat = switch mode { case .full:87.5; case .key:123.5; case .name:97; case .icon:124; case .list:97 }
        let boardTop:CGFloat = expanded ? (size.height-boardHeight)/2 : floatingTop
        let visibleKeys=Set(LauncherPresentationPolicy.visibleKeys(settings:configuration.settings,bindings:bindings,editing:isEditing))
        for (index,row) in KeyboardLayout.rows.enumerated() {
            let width = CGFloat(row.count)*80*scale
            let x = (size.width-width)/2, y = boardTop+CGFloat(index)*rowStep
            for (column,key) in row.enumerated() {
                if !visibleKeys.contains(key) {continue}
                let tile = KeyTile(key:key,mode:mode,binding:bindings[key],editing:isEditing,frame:NSRect(x:x+CGFloat(column)*80*scale,y:y,width:80*scale,height:cellHeight*scale))
                tile.bounds = NSRect(x:0,y:0,width:80,height:cellHeight)
                tile.actionBlock = { [weak self, weak tile] in guard let self, let tile else { return }; if let binding = bindings[key], !isEditing, !tile.missing { launch(binding.target) } else { if bindings[key] == nil { showTypeMenu(key,anchor:tile) } else { openEditor(key) } } }
                tile.removeBlock = { [weak self] in self?.removeBinding(key) }
                tile.contextBlock = { [weak self, weak tile] in if let self, let tile { showKeyMenu(key,anchor:tile) } }
                tile.hoverBlock = { [weak self] inside in guard let self else { return }; shortcutHint?.isHidden = inside; hoverLabel?.stringValue = inside ? "\(key)  ·  \(bindings[key]?.title ?? "点击绑定")" : (isEditing ? "点击修改 · 拖动交换位置" : "") }
                tile.swapBlock = { [weak self] from,to in guard let self else { return }; draft?.swap(from,to); render(); toast("位置已交换 · 完成后保存") }
                content.addSubview(tile)
            }
        }
    }
    func renderSearch() {
        let w = size.width
        let searchBox = ApplicationSearchSurface(frame:NSRect(x:(w-289)/2,y:expanded ? 47 : 27,width:289,height:40)); searchBox.editor = searchInput; content.addSubview(searchBox)
        let searchSymbol = SymbolView(symbol:"magnifyingglass",frame:NSRect(x:18,y:12,width:16,height:16)); searchBox.addSubview(searchSymbol)
        searchScroll.removeFromSuperview(); searchInput.frame = NSRect(x:0,y:0,width:177,height:28)
        searchInput.minSize = NSSize(width:177,height:28); searchInput.maxSize = NSSize(width:100000,height:28)
        searchInput.textContainer?.containerSize = NSSize(width:100000,height:28)
        searchInput.textContainer?.widthTracksTextView = false
        searchScroll.frame = NSRect(x:43,y:6,width:177,height:28); searchScroll.drawsBackground = false
        searchScroll.hasHorizontalScroller = false; searchScroll.hasVerticalScroller = false
        searchScroll.documentView = searchInput
        searchInput.isEditable = true; searchInput.isSelectable = true
        if searchInput.string != query { searchInput.string = query }
        let inputColor = Palette.text
        searchInput.textColor = inputColor; searchInput.insertionPointColor = inputColor
        searchInput.typingAttributes[.foregroundColor] = inputColor
        searchInput.textStorage?.addAttribute(.foregroundColor,value:inputColor,range:NSRange(location:0,length:(searchInput.string as NSString).length))
        searchBox.addSubview(searchScroll)
        placeholderLabel = label("搜索名称或首字母",x:43,y:10,width:177,height:20,size:14,color:Palette.isLight ? Palette.secondary : NSColor(calibratedWhite:0.71,alpha:1),in:searchBox)
        placeholderLabel?.font = .systemFont(ofSize:14,weight:.semibold)
        placeholderLabel?.isHidden = !query.isEmpty; placeholderLabel?.isSelectable = false
        searchClearButton = nil
        let inputMode = SearchAccessoryButton(.inputMode,frame:NSRect(x:224,y:6,width:28,height:28))
        inputMode.textMode = textMode
        inputMode.setAccessibilityLabel(textMode ? "切换到数字快启" : "切换到文字输入")
        inputMode.toolTip = textMode ? "文字输入 · 点击切换数字快启" : "数字快启 · 点击切换文字输入（⌘ F）"
        inputMode.actionBlock = { [weak self] in guard let self else { return }; setSearch(text:!textMode) }
        inputMode.contextBlock = { [weak self,weak inputMode] in
            guard let self, let inputMode else { return }
            let options = NSMenu()
            let quick = menuItem("数字快启") { [weak self] in self?.setSearch(text:false) }; quick.state = textMode ? .off : .on; options.addItem(quick)
            let text = menuItem("文字输入") { [weak self] in self?.setSearch(text:true) }; text.state = textMode ? .on : .off; options.addItem(text)
            options.addItem(.separator())
            let clear = menuItem("清除搜索") { [weak self] in self?.clearSearch() }; clear.isEnabled = !query.isEmpty; options.addItem(clear)
            popMenu(options,anchor:inputMode)
        }
        searchBox.addSubview(inputMode)
        let more = SearchAccessoryButton(.more,frame:NSRect(x:254,y:6,width:28,height:28))
        more.setAccessibilityLabel("应用显示与排序"); more.toolTip = "显示、排序与扫描范围"
        more.actionBlock = { [weak self,weak more] in if let more { self?.showSearchOptions(anchor:more) } }
        more.contextBlock = more.actionBlock; searchBox.addSubview(more)
        let scale = expanded ? min(size.width/1080,(size.height-150)/414) : 1
        let width = 966*scale, height = searchBodyHeight*scale
        let top:CGFloat = expanded ? max(93,(size.height-height)/2) : 93
        let viewportFrame = NSRect(x:(w-width)/2,y:top,width:width,height:height)
        let viewport:FlippedView
        if usesVerticalResults { viewport = FlippedView(frame:viewportFrame) }
        else { viewport = HorizontalPagingSurface(frame:viewportFrame,recognizer:horizontalNavigationGesture) { [weak self] direction in self?.handleHorizontalNavigation(direction) } }
        viewport.bounds = NSRect(x:0,y:0,width:966,height:searchBodyHeight); content.addSubview(viewport)
        if usesVerticalResults {
            let scroll = NSScrollView(frame:viewport.bounds)
            scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true; scroll.scrollerStyle = .legacy; scroll.verticalScroller = LauncherScroller()
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.verticalScrollElasticity = .none; scroll.horizontalScrollElasticity = .none
            let document = FlippedView(frame:NSRect(x:0,y:0,width:966,height:searchBodyHeight))
            scroll.documentView = document; viewport.addSubview(scroll)
            resultScroll = scroll; resultContainer = document; renderResults()
            resultScrollObserver = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.verticalResultsDidScroll() }
            }
        } else { resultContainer = viewport; renderResults() }
    }
    func showSearchOptions(anchor:NSView) {
        guard !isPreparingToQuit else { return }
        let options = NSMenu()
        for layout in [ResultLayout.grid,.list] {
            let item = menuItem(layout == .grid ? "横向翻页" : "竖向滚动",symbol:layout == .grid ? "rectangle.split.3x1" : "scroll") { [weak self] in
                guard let self else { return }
                if updateSettings({ $0.resultLayout = layout }) { resetSearchSelection(); render(); focus() }
            }
            item.state = configuration.settings.resultLayout == layout ? .on : .off; options.addItem(item)
        }
        options.addItem(.separator())
        let quick = menuItem("数字快启",symbol:"number") { [weak self] in self?.setSearch(text:false) }
        quick.state = textMode ? .off : .on; quick.toolTip = "搜索后按 1–9 直接打开当前页对应结果"; options.addItem(quick)
        let text = menuItem("文字输入",symbol:"character.cursor.ibeam") { [weak self] in self?.setSearch(text:true) }
        text.state = textMode ? .on : .off; text.keyEquivalent = "f"; text.keyEquivalentModifierMask = .command
        text.toolTip = "使用输入法输入中文及数字"; options.addItem(text)
        options.addItem(.separator())
        for mode in AppSortMode.allCases {
            let item = menuItem(mode.title) { [weak self] in self?.setApplicationSort(mode) }
            item.state = configuration.settings.appSort == mode ? .on : .off; options.addItem(item)
        }
        options.addItem(.separator())
        options.addItem(menuItem("刷新列表",symbol:"arrow.clockwise") { [weak self] in self?.refreshApplications(force:true) })
        options.addItem(menuItem("管理扫描范围",symbol:"folder") { [weak self] in self?.showScanDirectories() })
        popMenu(options,anchor:anchor)
    }
    func setApplicationSort(_ mode:AppSortMode) {
        var candidate = configuration
        if mode == .custom && candidate.applicationOrder.isEmpty { candidate.applicationOrder = appIndex.map(\.id) }
        candidate.settings.appSort = mode
        guard save(candidate) else { return }; resetSearchSelection(); renderResults(); focus()
    }
    func reorderApplication(source:String,destination:String) {
        guard source != destination, configuration.settings.appSort == .custom, query.isEmpty else { return }
        var order = appIndex.map(\.id)
        guard let sourceIndex = order.firstIndex(of:source), let destinationIndex = order.firstIndex(of:destination) else { return }
        order.remove(at:sourceIndex); order.insert(source,at:min(destinationIndex,order.count))
        var candidate = configuration; candidate.applicationOrder = order
        if save(candidate) { renderResults(); focus() }
    }
    func refreshSearchData() {
        results = SearchEngine.search(query.isEmpty ? appIndex : searchIndex,query:query,preservingInputOrder:true)
        selection.clamp(total:results.count,pageSize:configuration.settings.resultLayout.pageSize)
        verticalSelectedIndex = min(max(0,verticalSelectedIndex),max(0,results.count-1))
    }
    func resetSearchSelection() {
        selection.reset(); keyboardSelectionVisible = false; verticalSelectedIndex = 0; verticalScrollOrigin = .zero
    }
    func renderResults() {
        guard searchView, let container = resultContainer else { return }
        if usesVerticalResults != (resultScroll != nil) { render(); return }
        placeholderLabel?.isHidden = !query.isEmpty || searchInput.hasMarkedText()
        searchClearButton?.isHidden = query.isEmpty
        refreshSearchData()
        let pageSize = configuration.settings.resultLayout.pageSize
        if overlay == nil && abs(size.height-lastSize.height)>0.5 { render(); focus(); return }
        suppressResultScrollUpdates = true
        defer { suppressResultScrollUpdates = false }
        container.subviews.forEach { $0.removeFromSuperview() }
        let visible = usesVerticalResults ? results : Array(results[selection.range(total:results.count,pageSize:pageSize)])
        if usesVerticalResults {
            container.setFrameSize(NSSize(width:966,height:max(searchBodyHeight,CGFloat((results.count+6)/7)*138)))
        }
        if visible.isEmpty {
            let icon = SymbolView(symbol:"magnifyingglass",frame:NSRect(x:(container.bounds.width-30)/2,y:89,width:30,height:30)); container.addSubview(icon)
            label(scanning ? "正在发现本机应用" : "没有找到匹配项",x:0,y:137,width:container.bounds.width,height:22,size:15,color:Palette.text,alignment:.center,in:container)
            label("试试名称、拼音或首字母；⌘ F 可输入中文和数字",x:0,y:171,width:container.bounds.width,height:20,size:12,color:Palette.muted,alignment:.center,in:container)
        }
        for (index,entry) in visible.enumerated() {
            let rect = NSRect(x:CGFloat(index%7)*138,y:CGFloat(index/7)*138,width:138,height:126)
            let selected = usesVerticalResults ? verticalSelectedIndex == index : selection.selected == index
            let tile = ResultTile(entry:entry,list:false,selected:selected,badge:resultBadge(at:index),frame:rect)
            tile.selectionVisible = keyboardSelectionVisible
            tile.showsSearchDetails = !query.isEmpty
            tile.starred = configuration.starredApplications.contains(entry.id)
            if configuration.settings.appSort == .custom && query.isEmpty {
                tile.reorderBlock = { [weak self] source,destination in self?.reorderApplication(source:source,destination:destination) }
            }
            tile.actionBlock = { [weak self] in
                guard let self else { return }
                if usesVerticalResults { verticalSelectedIndex = index } else { selection.selected = index }
                updateResultHighlights(); launch(entry.target)
            }
            tile.contextBlock = { [weak self,weak tile] in if let self, let tile { showResultMenu(entry,anchor:tile) } }
            container.addSubview(tile)
        }
        if let scroll = resultScroll {
            let maximum = max(0,container.bounds.height-scroll.contentView.bounds.height)
            verticalScrollOrigin = NSPoint(x:0,y:min(maximum,max(0,verticalScrollOrigin.y)))
            scroll.contentView.scroll(to:verticalScrollOrigin); scroll.reflectScrolledClipView(scroll.contentView)
            keepVerticalSelectionVisible(); updateResultHighlights()
        }
        updatePageIndicators()
    }
    func resultBadge(at index:Int) -> String? {
        let first = usesVerticalResults ? verticalFirstVisibleIndex : 0
        if !textMode, !query.isEmpty, index >= first, index < first+9 { return "\(index-first+1)" }
        return index == (usesVerticalResults ? verticalSelectedIndex : selection.selected) ? "↵" : nil
    }
    func updateResultHighlights() {
        for (index,tile) in (resultContainer?.subviews.compactMap { $0 as? ResultTile } ?? []).enumerated() {
            tile.selected = index == (usesVerticalResults ? verticalSelectedIndex : selection.selected)
            tile.selectionVisible = keyboardSelectionVisible
            tile.badge = resultBadge(at:index); tile.needsDisplay = true
        }
    }
    func keepVerticalSelectionVisible() {
        guard usesVerticalResults, let scroll = resultScroll, !results.isEmpty else { return }
        let first = min(verticalFirstVisibleIndex,results.count-1)
        let lastFullRow = Int(floor((scroll.contentView.bounds.maxY-126)/138))
        let end = min(results.count,max(first+1,(lastFullRow+1)*7))
        if verticalSelectedIndex < first || verticalSelectedIndex >= end { verticalSelectedIndex = first }
    }
    func verticalResultsDidScroll() {
        guard usesVerticalResults, !suppressResultScrollUpdates, let scroll = resultScroll else { return }
        verticalScrollOrigin = scroll.contentView.bounds.origin
        keepVerticalSelectionVisible(); updateResultHighlights()
    }
    func revealVerticalSelection() {
        guard usesVerticalResults, let scroll = resultScroll,
              let tile = resultContainer?.subviews.compactMap({ $0 as? ResultTile }).dropFirst(verticalSelectedIndex).first else { return }
        suppressResultScrollUpdates = true
        tile.scrollToVisible(tile.bounds)
        scroll.reflectScrolledClipView(scroll.contentView); verticalScrollOrigin = scroll.contentView.bounds.origin
        suppressResultScrollUpdates = false; updateResultHighlights()
    }
    func updatePageIndicators() {
        guard let paginationView else { return }
        paginationView.subviews.forEach { $0.removeFromSuperview() }; resultCountLabel = nil
        let count = selection.pageCount(total:results.count,pageSize:configuration.settings.resultLayout.pageSize)
        if usesVerticalResults || count == 1 {
            let countText = "\(results.count) 个结果"
            paginationView.setAccessibilityLabel("搜索结果"); paginationView.setAccessibilityValue(countText)
            resultCountLabel = label(countText,x:0,y:3,width:paginationView.bounds.width,height:20,size:11,color:Palette.secondary,alignment:.center,in:paginationView)
            return
        }
        paginationView.setAccessibilityLabel("应用分页")
        paginationView.setAccessibilityValue("第 \(selection.page+1) 页，共 \(count) 页")
        let total = CGFloat(count)*13+12
        var x = (paginationView.bounds.width-total)/2
        for page in 0..<count {
            let width:CGFloat = page == selection.page ? 25 : 13
            let marker = PageIndicatorButton(page:page,count:count,selected:page == selection.page,frame:NSRect(x:x,y:0,width:width,height:26)) { [weak self] in self?.selectPage(page) }
            paginationView.addSubview(marker); x += width
        }
    }
    func selectPage(_ page:Int) {
        keyboardSelectionVisible = false
        if usesVerticalResults {
            verticalSelectedIndex = min(max(0,page*21),max(0,results.count-1)); revealVerticalSelection(); focus(); return
        }
        selection.page = page; selection.selected = 0
        selection.clamp(total:results.count,pageSize:configuration.settings.resultLayout.pageSize)
        renderResults(); focus()
    }
    func clearSearch() { searchInput.unmarkText(); query = ""; searchInput.string = ""; resetSearchSelection(); renderResults(); focus() }
    func changePage(_ delta:Int) {
        if usesVerticalResults { moveSelection(delta*21,revealingInitialSelection:false) } else { selectPage(selection.page+delta) }
    }
    func moveSelection(_ delta:Int,revealingInitialSelection:Bool = true) {
        guard !results.isEmpty else { return }
        if revealingInitialSelection && !keyboardSelectionVisible {
            keyboardSelectionVisible = true
            if usesVerticalResults { verticalSelectedIndex = min(verticalFirstVisibleIndex,results.count-1) }
            else { selection.selected = 0 }
            updateResultHighlights(); return
        }
        keyboardSelectionVisible = true
        if usesVerticalResults {
            verticalSelectedIndex = min(max(0,verticalSelectedIndex+delta),max(0,results.count-1)); revealVerticalSelection()
        } else {
            let pageSize = configuration.settings.resultLayout.pageSize
            let oldPage = selection.page
            if delta == -1 || delta == 1 {
                selection.moveHorizontally(delta,total:results.count,pageSize:pageSize,columns:7)
            } else {
                let count = selection.range(total:results.count,pageSize:pageSize).count
                selection.move(delta,visibleCount:count)
            }
            if selection.page != oldPage { renderResults() } else { updateResultHighlights() }
        }
    }
    func launchSelected(_ index:Int? = nil) {
        if usesVerticalResults {
            let selected = index.map { verticalFirstVisibleIndex+$0 } ?? verticalSelectedIndex
            guard selected >= 0, selected < results.count else { NSSound.beep(); return }
            verticalSelectedIndex = selected; updateResultHighlights(); launch(results[selected].target); return
        }
        let range = selection.range(total:results.count,pageSize:configuration.settings.resultLayout.pageSize)
        let offset = index ?? selection.selected
        guard offset >= 0, offset < range.count else { NSSound.beep(); return }
        launch(results[range.lowerBound+offset].target)
    }
    func launch(_ target:LaunchTarget) {
        guard !isPreparingToQuit, !launchPending else { return }
        if target.kind == .web, let template = try? WebURLTemplate(target.location), !template.variables.isEmpty {
            if !panel.isVisible { show() }
            requestWebVariables(for:target) { [weak self] url in
                guard let self, let url else { return }
                var resolved = target; resolved.location = url.absoluteString; launch(resolved)
            }
            return
        }
        if target.kind.isFileSystem, TargetResolver.url(for:target) == nil {
            if let key = bindings.first(where: { $0.value.target.id == target.id })?.key { if !panel.isVisible { show() }; openEditor(key) }
            else { toast("目标已移动或不可访问，请刷新列表或重新选择。",persistent:true) }
            return
        }
        let wasVisible = panel.isVisible
        launchPending = true; let token = launchEpoch
        focusTransitionUntil = Date().addingTimeInterval(0.4)
        if target.kind == .shell || target.kind == .shortcut { toast("正在运行 \(target.name)…",persistent:true) }
        Task {
            do {
                try await launcher.launch(target)
                guard !isPreparingToQuit, token == launchEpoch else { return }; launchPending = false
                if target.kind == .app {
                    var candidate = configuration
                    var metadata = candidate.applicationMetadata[target.id] ?? ApplicationMetadata()
                    metadata.lastUsedAt = Date(); candidate.applicationMetadata[target.id] = metadata
                    if storageProblem == nil { _ = save(candidate) }
                }
                guard wasVisible else { return }
                if configuration.settings.hideOnLaunch { hide(restore:false) }
                else {
                    focusTransitionUntil = Date().addingTimeInterval(0.3)
                    if searchView { renderResults() }
                    toast("已打开 \(target.name)"); panel.makeKeyAndOrderFront(nil); focus()
                    scheduleFocusRestore(token:token)
                }
            } catch {
                guard !isPreparingToQuit, token == launchEpoch else { return }; launchPending = false
                if !panel.isVisible { show() }
                panel.makeKeyAndOrderFront(nil); toast(error.localizedDescription,persistent:true); focus()
            }
        }
    }

    func scheduleFocusRestore(token:Int) {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in
            guard let self, !self.isPreparingToQuit, token == self.launchEpoch, self.panel.isVisible else { return }
            self.panel.makeKeyAndOrderFront(nil); self.focus()
        }
    }

    func route(_ event:NSEvent) -> Bool {
        guard !isPreparingToQuit, panel.isVisible, !pickerActive, menu == nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let activeWindow = event.window ?? (editorPanel?.isKeyWindow == true ? editorPanel : panel)
        let native = activeWindow?.firstResponder as? NSTextView
        // An IME owns every key in an unfinished composition, including Tab and result digits.
        if native?.hasMarkedText() == true { return false }
        if overlay != nil || editorPanel != nil {
            if let form = (editorPanel?.contentView as? BindingPopoverSurface)?.card as? BindingHotKeyForm, form.handleKeyEvent(event) { return true }
            if let form = (editorPanel?.contentView as? BindingPopoverSurface)?.card as? ScanDirectoriesCard, form.handleKeyEvent(event) { return true }
            if editor?.handleKeyEvent(event) == true { return true }
            if [36,76].contains(event.keyCode), flags.intersection([.command,.control,.option]).isEmpty,
               let button = activeWindow?.firstResponder as? NSButton,
               button.isEnabled, !button.isHiddenOrHasHiddenAncestor {
                if !event.isARepeat {
                    if let action = button as? ActionButton { action.actionBlock?() }
                    else { button.performClick(nil) }
                }
                return true
            }
            if event.keyCode == 48 { cycleModalFocus(backward:flags.contains(.shift)); return true }
            if event.keyCode == 53 { if let confirmation = editor?.confirmation { confirmation.removeFromSuperview(); editor?.confirmation = nil } else { requestCloseEditor() }; return true }
            return false
        }
        if flags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "f" { setSearch(text:true); return true }
            if event.charactersIgnoringModifiers == "," { showSettings(); return true }
            if isEditing && event.charactersIgnoringModifiers?.lowercased() == "z" { undoDraft(); return true }
            return false
        }
        if !flags.intersection([.control,.option]).isEmpty { return false }
        if event.isARepeat && ((!searchView && ![51,123,124,125,126].contains(event.keyCode)) || [36,48,76].contains(event.keyCode)) { return true }
        if event.keyCode == 48, !flags.contains(.shift), !isEditing { toggleMainView(); return true }
        if event.keyCode == 53 { if isEditing { finishEditing(save:false) } else { escape() }; return true }
        if searchView {
            // Quick search consumes ASCII keys before the active input method so
            // pinyin initials filter immediately. Text mode owns native composition.
            if native != nil && textMode { return false }
            switch event.keyCode {
            case 36,76: launchSelected(); return true
            case 123: moveSelection(-1); return true
            case 124: moveSelection(1); return true
            case 125: moveSelection(7); return true
            case 126: moveSelection(-7); return true
            case 116: changePage(-1); return true
            case 121: changePage(1); return true
            default: break
            }
            if !textMode, !flags.contains(.shift), !query.isEmpty,
               let key = KeyboardLayout.keyCodes[event.keyCode], let number = Int(key), (1...9).contains(number) {
                if !event.isARepeat { launchSelected(number-1) }; return true
            }
            if !textMode {
                if event.keyCode == 51 {
                    searchInput.deleteBackward(nil); focus(); return true
                }
                if let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
                   characters.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) {
                    searchInput.insertText(characters,replacementRange:searchInput.selectedRange()); focus(); return true
                }
            }
            if native != nil { return false }
            // Keep direct input working when keyboard focus was left on a page control.
            if event.keyCode == 51 {
                searchInput.deleteBackward(nil); focus(); return true
            }
            if let character = event.characters,
               !character.isEmpty,
               character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).union(.whitespaces).contains($0) }) {
                searchInput.insertText(character,replacementRange:searchInput.selectedRange()); focus(); return true
            }
            return false
        }
        if let key = KeyboardLayout.keyCodes[event.keyCode] {
            if isEditing { openEditor(key) }
            else if let binding = bindings[key] { launch(binding.target) }
            else { showTypeMenu(key,anchor:bindingPresentationAnchor(for:key) ?? content) }
            return true
        }
        return false
    }
    /// Keyboard actions use the same visible row as pointer actions in list mode.
    /// Hidden unbound keys can still be configured from their physical key.
    func bindingPresentationAnchor(for key:String)->NSView? {
        if let tile=content.subviews.compactMap({$0 as? KeyTile}).first(where:{$0.key == key}) {return tile}
        if let list=content.subviews.compactMap({$0 as? LauncherBindingListView}).first,
           let row=list.rows.first(where:{$0.key == key}) {
            row.scrollToVisible(row.bounds)
            list.layoutSubtreeIfNeeded()
            return row
        }
        return nil
    }
    func cycleModalFocus(backward:Bool) {
        guard let card = editor?.confirmation?.subviews.first ?? editorPanel?.contentView ?? overlay?.subviews.first else { return }
        var controls: [NSView] = []
        func collect(_ view:NSView) {
            if view is NSScrollView { return }
            if let control = view as? NSControl, control.isEnabled, !control.isHidden {
                if let field = control as? NSTextField { if field.isEditable { controls.append(control) } }
                else { controls.append(control) }
            } else { view.subviews.forEach(collect) }
        }
        if let editor, editor.confirmation == nil { controls = editor.tabFocusViews }
        else if let form = (editorPanel?.contentView as? BindingPopoverSurface)?.card as? WebVariableForm { controls = form.tabFocusViews }
        else if let form = (editorPanel?.contentView as? BindingPopoverSurface)?.card as? BindingHotKeyForm { controls = form.tabFocusViews }
        else if let form = (editorPanel?.contentView as? BindingPopoverSurface)?.card as? ScanDirectoriesCard { controls = form.tabFocusViews }
        else { collect(card) }
        controls = controls.filter { !$0.isHiddenOrHasHiddenAncestor && ($0 as? NSControl)?.isEnabled != false }
        guard !controls.isEmpty else { return }
        let window = card.window ?? panel!
        let firstResponder = window.firstResponder
        let current = controls.firstIndex {
            guard let firstResponder else { return false }
            return $0 === firstResponder || ($0 as? NSControl)?.currentEditor() === firstResponder
        } ?? (backward ? 0 : -1)
        for offset in 1...controls.count {
            let index = (current + (backward ? -offset : offset) + controls.count) % controls.count
            if window.makeFirstResponder(controls[index]) {
                controls[index].scrollToVisible(controls[index].bounds); return
            }
        }
    }
    func searchCommand(_ selector:Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { launchSelected(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { escape(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) { moveSelection(7); return true }
        if selector == #selector(NSResponder.moveUp(_:)) { moveSelection(-7); return true }
        return false
    }
    func escape() { if searchView { if !query.isEmpty { clearSearch() } else if configuration.settings.actionsEnabled { setKeys() } else { hide(restore:true) } } else { hide(restore:true) } }
    func beginEditing() { guard !isPreparingToQuit, configuration.settings.actionsEnabled else { return }; searchView = false; draft = BindingEditor(configuration.bindings); render(); focus() }
    func finishEditing(save shouldSave:Bool) {
        guard !isPreparingToQuit else { return }
        if shouldSave, let draft { var candidate = configuration; candidate.bindings = draft.bindings; guard save(candidate) else { return } }
        draft = nil; rebuildIndex(); render(); focus()
    }
    func undoDraft() { guard !isPreparingToQuit else { return }; draft?.undo(); render(); focus() }
    func removeBinding(_ key:String) {
        guard !isPreparingToQuit else { return }
        guard let old = bindings[key] else { return }
        if isEditing { draft?.remove(key); closeOverlay(); render(); toast("已移除 · 完成后保存") }
        else {
            let shortcut = configuration.bindingHotKeys[key]
            var candidate = configuration; candidate.bindings.removeValue(forKey:key)
            guard save(candidate) else { return }; lastRemoved = (key,old,shortcut); closeOverlay(); render()
            toast("已移除绑定",undo:{ [weak self] in self?.undoLastRemoval() })
        }
    }
    func undoLastRemoval() {
        guard !isPreparingToQuit else { return }
        guard let removed = lastRemoved else { return }
        let retry:() -> Void = { [weak self] in self?.undoLastRemoval() }
        guard configuration.bindings[removed.key] == nil else {
            toast("这个键位已有新绑定，未覆盖。",persistent:true,undo:retry); return
        }
        var restored = configuration
        restored.bindings[removed.key] = removed.binding
        restored.bindingHotKeys[removed.key] = removed.hotKey
        guard save(restored) else {
            toast(lastSaveError ?? "恢复失败，撤销记录已保留。",persistent:true,undo:retry); return
        }
        lastRemoved = nil; render(); toast("绑定已恢复")
    }
    @discardableResult func commitBinding(_ binding:KeyBinding,source:String,destination:String,duplicate:String? = nil) -> Bool {
        guard !isPreparingToQuit else { return false }
        if isEditing { draft?.set(binding,at:destination,movingFrom:source,alsoRemoving:duplicate); closeOverlay(); render(); toast("已更新草稿 · 完成后保存"); return true }
        var candidate = configuration
        if let duplicate, duplicate != destination { candidate.bindings.removeValue(forKey:duplicate) }
        if source != destination { candidate.bindings.removeValue(forKey:source) }; candidate.bindings[destination] = binding
        if binding.target.kind == .app, !candidate.addedApplications.contains(where: { $0.id == binding.target.id }), !applications.contains(where: { $0.id == binding.target.id }) { candidate.addedApplications.append(binding.target) }
        guard save(candidate) else { return false }; closeOverlay(); render(); toast("绑定已保存"); return true
    }

    @discardableResult func label(_ text:String,x:CGFloat,y:CGFloat,width:CGFloat,height:CGFloat,size:CGFloat = 12,color:NSColor = Palette.text,alignment:NSTextAlignment = .left,in parent:NSView? = nil) -> NSTextField {
        let field = PassthroughLabel(labelWithString:text); field.frame = NSRect(x:x,y:y,width:width,height:height); field.font = .systemFont(ofSize:size); field.textColor = color; field.alignment = alignment; field.lineBreakMode = .byTruncatingTail
        (parent ?? content).addSubview(field); return field
    }
    @discardableResult func button(_ title:String,symbol:String? = nil,rect:NSRect,primary:Bool = false,selected:Bool = false,border:Bool = false,in parent:NSView? = nil,action:@escaping ()->Void) -> ActionButton {
        let value = ActionButton(title,symbol:symbol,frame:rect,action:action); value.primary = primary; value.selected = selected; value.border = border; (parent ?? content).addSubview(value); return value
    }
    func iconButton(_ symbol:String,label title:String,x:CGFloat,y:CGFloat,action:@escaping ()->Void) {
        let value = button("",symbol:symbol,rect:NSRect(x:x,y:y,width:32,height:32),action:action); value.setAccessibilityLabel(title); value.toolTip = title
    }
    func toast(_ message:String,persistent:Bool = false,undo:(()->Void)? = nil) {
        toastTask?.cancel(); toastView?.removeFromSuperview()
        let width = min(size.width-80,max(260,CGFloat(message.count)*12+60+(undo == nil ? 0 : 50)))
        let card = CardView(frame:NSRect(x:(size.width-width)/2,y:size.height-116,width:width,height:48)); card.radius = 11
        label(message,x:15,y:13,width:width-(undo == nil ? 30 : 90),height:26,size:12,color:Palette.accent,in:card).toolTip = message
        if let undo { button("撤销",rect:NSRect(x:width-68,y:9,width:56,height:30),in:card,action:undo) }
        background.addSubview(card); toastView = card
        if !persistent { toastTask = Task { try? await Task.sleep(for:.seconds(undo == nil ? 4 : 8)); guard !Task.isCancelled else { return }; card.removeFromSuperview() } }
    }
}

final class SymbolView: FlippedView {
    let symbol:String
    init(symbol:String,frame:NSRect) { self.symbol = symbol; super.init(frame:frame) }
    required init?(coder:NSCoder) { fatalError() }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override func draw(_ rect:NSRect) { drawSymbol(symbol,in:bounds) }
}

/// The shared recognizer survives view replacement, so the remainder of a
/// gesture cannot turn an application page after it just opened that view.
final class LauncherContentSurface: FlippedView {
    var scrollHandler: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func scrollWheel(with event:NSEvent) {
        if scrollHandler?(event) != true { super.scrollWheel(with:event) }
    }
}

final class HorizontalPagingSurface: FlippedView {
    let recognizer: HorizontalNavigationGesture
    var pageBy:(Int) -> Void
    init(frame:NSRect,recognizer:HorizontalNavigationGesture? = nil,pageBy:@escaping (Int) -> Void) {
        self.recognizer = recognizer ?? HorizontalNavigationGesture(); self.pageBy = pageBy; super.init(frame:frame)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func scrollWheel(with event:NSEvent) {
        if !handleScroll(deltaX:event.scrollingDeltaX,deltaY:event.scrollingDeltaY,phase:event.phase,momentumPhase:event.momentumPhase,precise:event.hasPreciseScrollingDeltas,timestamp:event.timestamp) {
            super.scrollWheel(with:event)
        }
    }
    /// Exposed for native checks without synthesizing a device-specific CGEvent.
    @discardableResult func handleScroll(deltaX:CGFloat,deltaY:CGFloat,phase:NSEvent.Phase = [],momentumPhase:NSEvent.Phase = [],precise:Bool = true,timestamp:TimeInterval) -> Bool {
        recognizer.handleScroll(deltaX:deltaX,deltaY:deltaY,phase:phase,momentumPhase:momentumPhase,precise:precise,timestamp:timestamp,pageBy:pageBy)
    }
}

@MainActor
final class HorizontalNavigationGesture {
    private enum Axis { case horizontal, vertical }
    private var axis:Axis?
    private var totalX:CGFloat = 0
    private var totalY:CGFloat = 0
    private var turned = false
    private var wheelTotalX:CGFloat = 0
    private var lastWheelTimestamp:TimeInterval?
    private var lastWheelTurn:TimeInterval = -.infinity
    @discardableResult func handleScroll(deltaX:CGFloat,deltaY:CGFloat,phase:NSEvent.Phase = [],momentumPhase:NSEvent.Phase = [],precise:Bool = true,timestamp:TimeInterval,pageBy:(Int)->Void) -> Bool {
        // Momentum must never start another page transition after fingers lift.
        if !momentumPhase.isEmpty { return abs(deltaX) > abs(deltaY)*1.25 }
        let scale:CGFloat = precise ? 1 : 12
        let horizontal = deltaX*scale, vertical = deltaY*scale
        if !phase.isEmpty {
            if phase.contains(.began) || phase.contains(.mayBegin) { resetGesture() }
            if phase.contains(.cancelled) { let handled = axis == .horizontal; resetGesture(); return handled }
            defer { if phase.contains(.ended) { resetGesture() } }
            totalX += horizontal; totalY += vertical
            if axis == nil, max(abs(totalX),abs(totalY)) >= 12 {
                if abs(totalX) > abs(totalY)*1.25 { axis = .horizontal }
                else if abs(totalY) > abs(totalX)*1.25 { axis = .vertical }
            }
            guard axis == .horizontal else { return false }
            if !turned, abs(totalX) >= 36, abs(totalX) > abs(totalY)*1.25 {
                turned = true; lastWheelTurn = timestamp
                pageBy(totalX < 0 ? 1 : -1)
            }
            return abs(horizontal) >= abs(vertical)
        }
        // Older wheel devices omit phase information. Accumulate only a short
        // burst, then rate-limit it so one physical gesture cannot skip pages.
        if let lastWheelTimestamp, timestamp-lastWheelTimestamp > 0.18 || timestamp < lastWheelTimestamp { wheelTotalX = 0 }
        lastWheelTimestamp = timestamp
        guard abs(horizontal) > abs(vertical)*1.25 else { wheelTotalX = 0; return false }
        guard timestamp-lastWheelTurn >= 0.45 else { return true }
        if wheelTotalX != 0, (wheelTotalX > 0) != (horizontal > 0) { wheelTotalX = 0 }
        wheelTotalX += horizontal
        if abs(wheelTotalX) >= 36 {
            let direction = wheelTotalX < 0 ? 1 : -1
            wheelTotalX = 0; lastWheelTurn = timestamp; pageBy(direction)
        }
        return true
    }
    private func resetGesture() { axis = nil; totalX = 0; totalY = 0; turned = false; wheelTotalX = 0; lastWheelTimestamp = nil }
}

/// A full-size hit target around the small visual page marker.
final class PageIndicatorButton: NSButton {
    let selectedPage: Bool
    let activate: () -> Void
    override var isFlipped: Bool { true }
    init(page:Int,count:Int,selected:Bool,frame:NSRect,activate:@escaping () -> Void) {
        selectedPage = selected; self.activate = activate
        super.init(frame:frame); title = ""; isBordered = false; focusRingType = .none
        target = self; action = #selector(selectPage)
        setAccessibilityLabel("第 \(page+1) 页，共 \(count) 页")
        setAccessibilityValue(selected ? "当前页" : "")
        toolTip = "第 \(page+1) 页"
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc func selectPage() { activate() }
    override func draw(_ dirtyRect:NSRect) {
        let width:CGFloat = selectedPage ? 18 : 6
        let marker = NSRect(x:(bounds.width-width)/2,y:(bounds.height-6)/2,width:width,height:6)
        Palette.text.withAlphaComponent(selectedPage ? 0.82 : isHighlighted ? 0.60 : 0.28).setFill()
        NSBezierPath(roundedRect:marker,xRadius:3,yRadius:3).fill()
        if window?.firstResponder === self {
            let focus = NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:5),xRadius:7,yRadius:7)
            NSColor.white.withAlphaComponent(0.4).setStroke(); focus.stroke()
        }
    }
}
