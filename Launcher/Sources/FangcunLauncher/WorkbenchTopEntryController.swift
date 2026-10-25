import AppKit
import Combine
import QuartzCore
import SwiftUI
import LauncherCore

struct WorkbenchTopEntryInput {
    var location: CGPoint
    var pressedButtons: Int
    var uptime: TimeInterval
    @MainActor static var live: Self {
        .init(location: NSEvent.mouseLocation, pressedButtons: NSEvent.pressedMouseButtons, uptime: ProcessInfo.processInfo.systemUptime)
    }
}

@MainActor final class WorkbenchTopEntryController: ObservableObject {
    @Published private(set) var preferences = WorkbenchTopEntryPreferences()
    @Published private(set) var error: String?
    private weak var owner: LauncherController?
    private let store: WorkbenchTopEntryStore
    private let input: () -> WorkbenchTopEntryInput
    private let workspaceNotifications: NotificationCenter
    private let monitorSystemInput: Bool
    private(set) var isRunning = false
    private var timer: Timer?
    private var gate = WorkbenchTopEntryGate()
    private var regions: [(screen: NSScreen, rect: CGRect)] = []
    private var observers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var systemAppearanceObserver: NSKeyValueObservation?
    private var localObservers: [NSObjectProtocol] = []
    private var localEventMonitor: Any?
    private var globalClickMonitor: Any?
    private var menuTrackingCount = 0
    private var islandSurface: WorkbenchNotchSurface?
    private var islandScreen: NSScreen?
    private var suspended = false
    private var summaryPanel: NSPanel?
    private var summaryVisible = false
    private var summaryOutsideAt: TimeInterval?
    private var animationID = UUID()
    private var miniOpenedAt = Date()
    private var miniAgendaTask: Task<Void, Never>?
    private var miniAgendaVisible = false
    private var miniDeviceVisible = false
#if DEBUG
    private var previewID = UUID()
    private var previewUntil: TimeInterval = 0
    private var diagnosticTime: TimeInterval = 0
    private var diagnosticPollCount = 0
    private var diagnosticTriggerCount = 0
    /// Opt-in local acceptance diagnostics; absent from Release builds and never enabled by default.
    private func recordDiagnostic() {
        guard Bundle.main.object(forInfoDictionaryKey: "FangcunTopEntryDiagnostics") as? Bool == true else { return }
        diagnosticPollCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now - diagnosticTime > 0.5 else { return }
        diagnosticTime = now
        let point = NSEvent.mouseLocation
        let data: [String: Any] = [
            "uptime": now, "polls": diagnosticPollCount, "triggers": diagnosticTriggerCount,
            "enabled": preferences.enabled, "mode": preferences.mode.rawValue, "suspended": suspended,
            "inside": regions.contains { WorkbenchTopEntryGate.contains(point, in: $0.rect) },
            "point": [point.x, point.y], "regions": regions.map { NSStringFromRect($0.rect) },
            "active": NSApp.isActive, "buttons": NSEvent.pressedMouseButtons,
            "key": owner?.workbenchController?.presentationWindow?.isKeyWindow == true,
            "visible": owner?.workbenchController?.presentationWindow?.isVisible == true,
            "onActiveSpace": owner?.workbenchController?.presentationWindow?.isOnActiveSpace == true,
            "occlusionVisible": owner?.workbenchController?.presentationWindow?.occlusionState.contains(.visible) == true,
            "alpha": owner?.workbenchController?.presentationWindow?.alphaValue ?? -1,
            "modal": NSApp.modalWindow != nil, "sheet": owner?.workbenchController?.presentationWindow?.attachedSheet != nil,
            "picker": owner?.pickerActive == true, "editor": owner?.editorPanel != nil,
            "overlay": owner?.overlay != nil, "editing": owner?.isEditing == true,
            "menu": owner?.menu != nil, "summary": summaryVisible,
            "islandFrame": islandTargetFrame.map { NSStringFromRect($0) } ?? "none",
            "feedback": isHoverFeedbackVisible, "topSession": owner?.workbenchController?.isTopEntryPresented == true
        ]
        if let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? encoded.write(to: store.url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("top-entry-diagnostic.json"), options: .atomic)
        }
    }
    /// Uses the real presentation sequence, but not a synthetic system pointer.
    /// Only available in opt-in Debug UI checks, never in the distributed Release app.
    func previewInteraction() {
        guard Bundle.main.object(forInfoDictionaryKey: "FangcunTopEntryDiagnostics") as? Bool == true,
              let region = regions.first(where: { WorkbenchTopEntryGate.contains(NSEvent.mouseLocation, in: $0.screen.frame) }) ?? regions.first else { return }
        handleContextChange(animated: false)
        let token = UUID(); previewID = token
        previewUntil = ProcessInfo.processInfo.systemUptime + 30
        DispatchQueue.main.asyncAfter(deadline: .now() + WorkbenchTopEntryGate.dwell) { [weak self] in
            guard let self, self.previewID == token else { return }
            if self.preferences.mode == .summary { self.showSummary(on: region.screen) }
            else { self.owner?.showWorkbenchFromTopEntry(originFrame: region.rect) }
        }
    }

#endif

    init(owner: LauncherController, input: @escaping () -> WorkbenchTopEntryInput = { .live },
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         monitorSystemInput: Bool = true) {
        self.owner = owner
        self.input = input
        self.workspaceNotifications = workspaceNotifications
        self.monitorSystemInput = monitorSystemInput
        store = WorkbenchTopEntryStore(url: owner.store.url.deletingLastPathComponent().appendingPathComponent("Workbench/top-entry.json"))
        do { preferences = try store.load() }
        catch { self.error = error.localizedDescription; preferences.enabled = false }
    }

    func start(automaticPolling: Bool = true) {
        guard !isRunning else { return }
        isRunning = true
        refreshScreens()
        if automaticPolling {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            timer.tolerance = 0.025
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleContextChange(animated: false); self?.refreshScreens() }
        }
        localObservers.append(NotificationCenter.default.addObserver(forName: .fangcunConfigurationChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAppearance() }
        })
        systemAppearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.owner?.configuration.settings.workbenchAppearance == .system else { return }
                self.refreshAppearance()
            }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspaceNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspended = true; self?.handleContextChange(animated: false) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspaceNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspended = false; self?.gate.reset(); self?.refreshScreens() }
            })
        }
        observers.append(workspaceNotifications.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { self?.handleApplicationActivation(processIdentifier: pid) }
            }
        })
        observers.append(workspaceNotifications.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleContextChange() }
        })
        for (name, delta) in [(NSMenu.didBeginTrackingNotification, 1), (NSMenu.didEndTrackingNotification, -1)] {
            localObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuTrackingCount = max(0, self.menuTrackingCount + delta)
                }
            })
        }
        // Global mouse monitoring needs no global keyboard hook or Accessibility permission.
        // Isolated checks provide explicit click/key calls and a private workspace
        // center, so unrelated desktop activity cannot race their intended input.
        guard monitorSystemInput else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleOutsideClick(at: NSEvent.mouseLocation) }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                let workbench = self.owner?.workbenchController
                let transientIsVisible = self.summaryVisible || (workbench?.isTopEntryPresented == true && workbench?.presentationWindow?.isVisible == true)
                let hasChildInteraction = self.menuTrackingCount > 0 || NSApp.modalWindow != nil
                    || workbench?.presentationWindow?.attachedSheet != nil
                    || workbench?.presentationWindow?.childWindows?.isEmpty == false
                if event.keyCode == 53, transientIsVisible, !hasChildInteraction {
                    self.handleContextChange(); return nil
                }
                // Pass Command-Tab through to macOS; don't consume the system shortcut.
                if event.keyCode == 48, event.modifierFlags.contains(.command) { self.handleContextChange() }
            } else if self.menuTrackingCount == 0 && NSApp.modalWindow == nil {
                self.handleOutsideClick(at: NSEvent.mouseLocation)
            }
            return event
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate(); timer = nil
        observers.forEach { workspaceNotifications.removeObserver($0) }; observers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        systemAppearanceObserver?.invalidate(); systemAppearanceObserver = nil
        localObservers.forEach { NotificationCenter.default.removeObserver($0) }; localObservers.removeAll()
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }; localEventMonitor = nil
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }; globalClickMonitor = nil
        menuTrackingCount = 0
        handleContextChange(animated: false)
    }

    func setEnabled(_ enabled: Bool) {
        var value = preferences; value.enabled = enabled; save(value)
    }
    func setMode(_ mode: WorkbenchTopEntryMode) {
        var value = preferences; value.mode = mode; save(value)
    }
    func setMiniSection(_ section: WorkbenchMiniSection, visible: Bool) {
        var value = preferences
        let selected = Set(value.visibleSections).subtracting([section]).union(visible ? [section] : [])
        value.visibleSections = WorkbenchMiniSection.allCases.filter { selected.contains($0) }
        save(value, dismiss: false)
    }
    func restoreMiniSections() {
        var value = preferences; value.visibleSections = WorkbenchMiniSection.allCases
        save(value, dismiss: false)
    }
    private func save(_ value: WorkbenchTopEntryPreferences, dismiss: Bool = true) {
        do {
            try store.save(value); preferences = value; error = nil
            if dismiss { gate.reset(); dismissSummary(animated: true) }
            else { updateMiniConsumers() }
        } catch { self.error = error.localizedDescription }
    }
    private func refreshScreens() {
        islandScreen = nil; islandSurface = nil
        regions = NSScreen.screens.map { screen in
            let notchWidth: CGFloat?
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
                notchWidth = right.minX - left.maxX
            } else { notchWidth = nil }
            return (screen, WorkbenchTopEntryGate.activationRect(screen: screen.frame, safeTop: screen.safeAreaInsets.top, notchWidth: notchWidth))
        }
        gate.reset()
    }
    func poll() {
#if DEBUG
        recordDiagnostic()
        if ProcessInfo.processInfo.systemUptime < previewUntil { return }
#endif
        guard isRunning, preferences.enabled, !suspended, let owner else { return }
        let sample = input()
        let point = sample.location, now = sample.uptime
        let region = regions.first { WorkbenchTopEntryGate.contains(point, in: $0.rect) }
        if summaryVisible {
            if sample.pressedButtons != 0 || menuTrackingCount > 0 || NSApp.modalWindow != nil || region != nil || islandContains(point, tolerance: 8) {
                summaryOutsideAt = nil
            } else if let since = summaryOutsideAt, now - since >= 0.28 {
                dismissSummary(animated: true)
            } else if summaryOutsideAt == nil { summaryOutsideAt = now }
        }
        if summaryVisible { summaryPanel?.ignoresMouseEvents = !islandContains(point) }
        let workbenchAlreadyVisible = owner.workbenchController?.isTopEntryPresented == true
            && owner.workbenchController?.presentationWindow?.isVisible == true
        let resumesProtectedInteraction = owner.workbenchController?.canResumeSuspendedTopInteraction == true
        let allowed = !summaryVisible && (!workbenchAlreadyVisible || resumesProtectedInteraction) && menuTrackingCount == 0
            && sample.pressedButtons == 0 && (NSApp.modalWindow == nil || resumesProtectedInteraction)
            && !owner.pickerActive && owner.editorPanel == nil && owner.overlay == nil && !owner.isEditing
            && owner.menu == nil && (owner.workbenchController?.presentationWindow?.attachedSheet == nil || resumesProtectedInteraction)

        let triggered = gate.update(inside: region != nil, allowed: allowed, at: now)
        guard triggered, let region else { return }
        // A direct entry starts at the current display's trigger, not a hidden
        // mini panel left over from an earlier session on another display.
        let origin = region.rect
#if DEBUG
        diagnosticTriggerCount += 1
#endif
        if preferences.mode == .workbench || resumesProtectedInteraction {
            owner.showWorkbenchFromTopEntry(originFrame: origin)
        }
        else { showSummary(on: region.screen) }
    }
    var isQuickSummaryVisible: Bool { summaryVisible && summaryPanel?.isVisible == true }
    var isHoverFeedbackVisible: Bool { false }
    var isEntryPending: Bool { gate.isDwelling }
    var islandMaterialOpacity: Double? { islandSurface?.materialOpacity }
    var islandUsesLightAppearance: Bool? { islandSurface?.usesLightAppearance }
    var islandTheme: LauncherTheme? { islandSurface?.theme }
    var islandWindowNumber: Int? { summaryPanel?.windowNumber }
    var islandContentTopInset: CGFloat? { islandSurface?.contentTopInset }
    var islandTargetFrame: CGRect? { islandSurface.map { screenRect($0.targetBounds) } }
    var islandPresentationFrame: CGRect? { islandSurface.map { screenRect($0.presentationBounds) } }
#if DEBUG
    /// Explicitly requested, isolated own-view evidence. It never captures other
    /// windows, the desktop, a pointer or private workbench content.
    func captureMiniReview(to url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/tmp/"), summaryVisible,
              let surface = islandSurface, surface.phase == .expanded else { return }
        surface.layoutSubtreeIfNeeded()
        guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { return }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try png.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
#endif
    private func screenRect(_ rect: CGRect) -> CGRect {
        guard let panel = summaryPanel else { return .zero }
        return CGRect(x: panel.frame.minX + rect.minX, y: panel.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
    private func islandContains(_ point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        guard summaryPanel?.isVisible == true, let surface = islandSurface, let panel = summaryPanel else { return false }
        if tolerance > 0 { return screenRect(surface.presentationBounds).insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        return surface.containsVisiblePoint(CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y))
    }

    /// A context change always cancels pending opening as well as visible temporary surfaces.
    /// Do not reactivate this app or reveal its sheets while the user is going elsewhere.
    func cancelPendingEntry(animated: Bool = false) {
#if DEBUG
        previewID = UUID(); previewUntil = 0
#endif
        gate.reset()
        dismissSummary(animated: animated)
    }
    func handleContextChange(animated: Bool = true) {
        cancelPendingEntry(animated: animated)
        owner?.workbenchController?.dismissTopEntryForContextChange(animated: animated)
    }
    func handleApplicationActivation(processIdentifier: pid_t) {
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        handleContextChange()
    }
    func handleOutsideClick(at point: CGPoint) {
        func contains(_ window: NSWindow?) -> Bool {
            guard let window, window.isVisible else { return false }
            if window.frame.contains(point) { return true }
            if contains(window.attachedSheet) { return true }
            return window.childWindows?.contains(where: { contains($0) }) == true
        }
        if summaryVisible && islandContains(point) { return }
        if let workbench = owner?.workbenchController, workbench.isTopEntryPresented,
           workbench.presentationWindow?.isVisible == true,
           contains(workbench.presentationWindow) || contains(NSApp.modalWindow) { return }
        handleContextChange()
    }
    private func prepareIsland(on screen: NSScreen) -> NSPanel {
        let panel = summaryPanel ?? WorkbenchSummaryPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        summaryPanel = panel
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityLabel("方寸灵动岛")
        panel.appearance = NSAppearance(named: Palette.isLight ? .aqua : .darkAqua)
        let notchWidth = hardwareNotchWidth(on: screen)
        let size = WorkbenchMiniLayout.size(sectionCount: preferences.visibleSections.count,
                                            screenWidth: screen.frame.width, safeTop: screen.safeAreaInsets.top,
                                            notchWidth: notchWidth)
        if islandScreen !== screen || islandSurface?.expandedSize != size {
            let surface = WorkbenchNotchSurface(size: size, notchWidth: notchWidth, safeTop: screen.safeAreaInsets.top)
            islandSurface = surface; islandScreen = screen; panel.contentView = surface
            panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                                  width: size.width, height: size.height), display: false)
        }
        return panel
    }
    func refreshAppearance() {
        guard let owner else { return }
        Palette.workbenchTheme = owner.configuration.settings.workbenchTheme
        let appearance = owner.configuration.settings.workbenchAppearance
        Palette.isLight = appearance == .light || (appearance == .system && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        Palette.glassOpacity = owner.configuration.settings.glassOpacity
        summaryPanel?.appearance = NSAppearance(named: Palette.isLight ? .aqua : .darkAqua)
        islandSurface?.refreshAppearance()
    }
    private func showSummary(on screen: NSScreen) {
        guard let owner else { return }
        if owner.workbenchController == nil { owner.workbenchController = WorkbenchWindowController(owner: owner) }
        guard let model = owner.workbenchController?.model else { return }
        let panel = prepareIsland(on: screen)
        refreshAppearance()
        if !panel.isVisible { islandSurface?.setPhase(.closed, animated: false) }
        animationID = UUID(); summaryVisible = true; summaryOutsideAt = nil
        miniOpenedAt = Date()
        mountMini(model: model, on: screen)
        updateMiniConsumers()
        panel.alphaValue = 1; panel.ignoresMouseEvents = !islandContains(input().location)
        panel.orderFrontRegardless(); panel.makeKey()
        islandSurface?.setPhase(.expanded, animated: true)
    }
    private func hardwareNotchWidth(on screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
            return right.minX - left.maxX
        }
        return 0
    }
    private func mountMini(model: WorkbenchAppModel, on screen: NSScreen) {
        let host = NSHostingView(rootView: WorkbenchMiniView(model: model, controller: self, openedAt: miniOpenedAt,
            safeTop: screen.safeAreaInsets.top, notchWidth: hardwareNotchWidth(on: screen), open: { [weak self] in
                guard let self else { return }
                self.owner?.workbenchController?.model.navigate(.overview)
                self.owner?.showWorkbenchFromTopEntry(originFrame: self.islandPresentationFrame)
            }, finishConfiguration: { [weak self] in self?.resizeMiniAfterConfiguration() }).nativeCheckAccessibility())
        islandSurface?.setContent(host)
    }
    private func resizeMiniAfterConfiguration() {
        guard summaryVisible, let screen = islandScreen, let model = owner?.workbenchController?.model else { return }
        _ = prepareIsland(on: screen)
        mountMini(model: model, on: screen)
        islandSurface?.setPhase(.expanded, animated: false)
    }
    private func updateMiniConsumers() {
        guard let model = owner?.workbenchController?.model else { return }
        let deviceVisible = summaryVisible && preferences.visibleSections.contains(.device)
        model.device.setQuickSummaryVisible(deviceVisible)
        if deviceVisible && !miniDeviceVisible { model.device.refresh() }
        miniDeviceVisible = deviceVisible
        model.setMiniContextVisible(summaryVisible && preferences.visibleSections.contains(.context))
        let agendaVisible = summaryVisible && preferences.visibleSections.contains(.agenda)
        guard agendaVisible != miniAgendaVisible else { return }
        miniAgendaVisible = agendaVisible
        miniAgendaTask?.cancel(); miniAgendaTask = nil
        if agendaVisible {
            miniAgendaTask = Task { [weak model] in
                guard let model, !Task.isCancelled else { return }
                await model.calendar.refreshMiniAgenda(timeZone: model.context.dateContext.timeZone)
            }
        }
    }
    private func collapseIsland(animated: Bool) {
        guard let panel = summaryPanel else { return }
        let token = UUID(); animationID = token
        panel.ignoresMouseEvents = true
        islandSurface?.setPhase(.closed, animated: animated)
        guard animated, panel.isVisible else {
            panel.orderOut(nil); panel.alphaValue = 1; islandSurface?.clearContent(); return
        }
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.33
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak panel] in
            guard self?.animationID == token else { return }
            panel?.orderOut(nil); panel?.alphaValue = 1
            self?.islandSurface?.clearContent()
        }
    }
    func dismissSummary(animated: Bool = true) {
        summaryVisible = false; summaryOutsideAt = nil
        updateMiniConsumers()
        collapseIsland(animated: animated)
    }
}

struct WorkbenchTopEntrySettingsRow: View {
    @ObservedObject var controller: WorkbenchTopEntryController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("顶部感知入口").font(.system(size: 13, weight: .medium))
                    Text("滑入顶部直接展开迷你信息，点击进入工作台首页；切换应用自动收起。").font(.system(size: 12))
                        .foregroundStyle(WorkbenchStyle.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: 400, alignment: .leading)
                Spacer(minLength: 5)
                WBSelect("顶部入口显示", selection: Binding(get: { controller.preferences.mode }, set: controller.setMode),
                         options: [(value: .summary, title: "迷你信息面板"), (value: .workbench, title: "直接展开工作台")])
                    .frame(width: 160).disabled(!controller.preferences.enabled)
                Toggle("开启顶部感知入口", isOn: Binding(get: { controller.preferences.enabled }, set: controller.setEnabled))
                    .labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.small)
            }
            if controller.preferences.mode == .summary {
                HStack(spacing: 18) {
                    ForEach(WorkbenchMiniSection.allCases) { section in
                        Toggle(section.title, isOn: Binding(get: { controller.preferences.visibleSections.contains(section) },
                            set: { controller.setMiniSection(section, visible: $0) }))
                            .font(.system(size: 11)).toggleStyle(.checkbox).clickableCursor()
                    }
                    Spacer(minLength: 0)
                    Button("恢复默认", action: controller.restoreMiniSections).font(.system(size: 11)).buttonStyle(.plain).clickableCursor()
                }.disabled(!controller.preferences.enabled)
                Text("默认显示全部四项；城市、时区和温度单位沿用首页设置。").font(.system(size: 11)).foregroundStyle(WorkbenchStyle.secondary)
            }
            if let error = controller.error { Text(error).font(.system(size: 11)).foregroundStyle(WorkbenchStyle.warning) }
        }.padding(.vertical, 17)
        Divider().opacity(0.25)
    }
}

@MainActor private final class WorkbenchSummaryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
