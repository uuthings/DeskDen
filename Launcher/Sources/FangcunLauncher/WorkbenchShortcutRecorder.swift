import AppKit
import SwiftUI
import LauncherCore

enum WorkbenchShortcutTarget {case workbench,launcher
    var title:String {self == .workbench ? "工作台":"启动器"}
    var accessibilityID:String {self == .workbench ? "workbenchShortcut":"launcherShortcut"}
}

/// Records a candidate without changing the registered shortcuts until Save.
/// Carbon hotkeys and ordinary key events share this same capture session.
@MainActor
final class WorkbenchShortcutRecorder: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var draft: BindingHotKey?
    @Published private(set) var error: String?
    @Published private(set) var target:WorkbenchShortcutTarget = .workbench
    private weak var owner: LauncherController?
    private weak var window: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    func begin(owner:LauncherController,target:WorkbenchShortcutTarget = .workbench) {
        guard !owner.isPreparingToQuit else { return }
        owner.workbenchShortcutRecorder?.cancel()
        self.owner = owner;self.target=target
        draft = target == .workbench ? owner.configuration.settings.workbenchHotKey:owner.configuration.settings.effectiveLauncherHotKey
        error = nil
        owner.workbenchShortcutRecorder = self
        isPresented = true
    }

    func attach(window: NSWindow) {
        guard isPresented, self.window !== window else { return }
        stopObserving()
        self.window = window
        let center = NotificationCenter.default
        for observedWindow in [window, window.sheetParent].compactMap({ $0 }) {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: observedWindow, queue: .main) { [weak self] note in
                    let resigning=note.name == NSWindow.didResignKeyNotification
                    let sourceID=(note.object as? NSWindow).map(ObjectIdentifier.init)
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // A sheet becoming key makes its parent resign. Only the
                        // actual recorder losing focus cancels this session.
                        if resigning, sourceID != self.window.map(ObjectIdentifier.init) { return }
                        self.cancel()
                    }
                })
            }
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleEvent(event) ?? false }
            return handled ? nil : event
        }
    }

    @discardableResult
    func captureRegisteredHotKey(_ shortcut: BindingHotKey) -> Bool {
        guard ownsCapture else { return false }
        acceptCandidate(shortcut)
        return true
    }

    func handleEvent(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if event.window !== window { cancel() }
            return false
        }
        guard event.type == .keyDown, event.window === window, ownsCapture else { return false }
        if event.keyCode == 53 { cancel(); return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.intersection([.command, .control, .option]).isEmpty, [36, 48, 49, 76].contains(event.keyCode) {
            return false // Native Tab navigation, Space activation and default Save remain usable.
        }
        if !event.isARepeat {
            acceptCandidate(BindingHotKey(keyCode: event.keyCode, control: flags.contains(.control),
                                          option: flags.contains(.option), shift: flags.contains(.shift), command: flags.contains(.command)))
        }
        return true
    }

    func acceptCandidate(_ shortcut: BindingHotKey) {
        guard isPresented, owner?.isPreparingToQuit == false else { return }
        do { try shortcut.validate(); draft = shortcut; error = nil }
        catch { self.error = error.localizedDescription }
    }

    func clearCandidate() {guard isPresented else {return};draft=target == .launcher ? LauncherSettings.defaultLauncherHotKey:nil;error=nil}

    @discardableResult
    func save() -> Bool {
        guard isPresented, let owner, !owner.isPreparingToQuit else { return false }
        if target == .launcher,draft == nil {error="启动器需要保留一个唤出快捷键。";return false}
        let saved=target == .workbench ? owner.setWorkbenchHotKey(draft):owner.setLauncherHotKey(draft)
        guard saved else {
            error = owner.lastSaveError ?? "快捷键不可用，原设置已保留。"
            return false
        }
        owner.workbenchController?.model.toast = target.title+(draft == nil ? "快捷键已清除":"快捷键已更新")
        cancel()
        return true
    }

    func cancel() {
        let modals=owner?.workbenchController?.model.modals
        if isPresented {isPresented=false}
        // A settings subtree can disappear before its modal modifier receives
        // the final binding update. Prune on the next UI cycle in that case.
        DispatchQueue.main.async {[weak modals] in modals?.prune()}
        stopObserving()
        window = nil
        if owner?.workbenchShortcutRecorder === self { owner?.workbenchShortcutRecorder = nil }
        owner = nil
        draft = nil
        error = nil
    }

    private var ownsCapture: Bool {
        isPresented && owner?.isPreparingToQuit == false && window?.isVisible == true && window?.isKeyWindow == true
    }
    func canCapture(in window:NSWindow)->Bool {self.window === window && ownsCapture}
    private func stopObserving() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}

struct WorkbenchShortcutSetting: View {
    let owner: LauncherController
    var target:WorkbenchShortcutTarget = .workbench
    @StateObject private var recorder = WorkbenchShortcutRecorder()
    var body: some View {
        WorkbenchShortcutTrigger(title:target == .workbench ? owner.configuration.settings.workbenchHotKey?.title ?? "设置快捷键":owner.configuration.settings.effectiveLauncherHotKey.title,
                                 label:"设置\(target.title)快捷键",identifier:"fc.settings.\(target.accessibilityID)") {recorder.begin(owner:owner,target:target)}
            .frame(height:28)
            .workbenchModal(isPresented: $recorder.isPresented, onDismiss: { recorder.cancel() },onRequestDismiss:{recorder.cancel()}) {
                WorkbenchShortcutRecordingDialog(recorder: recorder)
            }
            .onDisappear { recorder.cancel() }
    }
}

/// The coordinator retains this modal's view. Observe the session here so both
/// validation messages and the candidate redraw while the modal stays open.
private struct WorkbenchShortcutRecordingDialog: View {
    @ObservedObject var recorder: WorkbenchShortcutRecorder
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        WorkbenchDialogFrame(title: "设置快捷键", dismiss: { recorder.cancel() }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("按下新的组合键；Esc 取消录制。包含 ⌃、⌥ 或 ⌘。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
                WorkbenchShortcutCapture(recorder: recorder)
                    .frame(maxWidth: .infinity).frame(height: 40)
                if let error = recorder.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(palette.critical)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fc.settings.\(recorder.target.accessibilityID).error")
                }
            }
        } actions: {
            Button(recorder.target == .launcher ? "恢复默认" : "清除") { recorder.clearCandidate() }
                .buttonStyle(WBButtonStyle())
            Spacer()
            Button("取消") { recorder.cancel() }.buttonStyle(WBButtonStyle())
            Button("保存") { recorder.save() }.buttonStyle(WBButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("fc.settings.\(recorder.target.accessibilityID).save")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fc.settings.\(recorder.target.accessibilityID).dialog")
        .frame(width: 470)
    }
}

private struct WorkbenchShortcutCapture:NSViewRepresentable {
    @ObservedObject var recorder:WorkbenchShortcutRecorder
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context:Context)->WorkbenchShortcutCaptureControl {WorkbenchShortcutCaptureControl(frame:.zero)}
    func updateNSView(_ view:WorkbenchShortcutCaptureControl,context:Context) {
        view.recorder=recorder;view.palette=palette;view.isEnabled=enabled
        view.valueText=recorder.draft?.title ?? "未设置"
        view.setAccessibilityLabel("录制\(recorder.target.title)快捷键")
        view.setAccessibilityValue(view.valueText)
        view.setAccessibilityIdentifier("fc.settings.\(recorder.target.accessibilityID).capture")
        view.needsDisplay=true;view.connect()
    }
    static func dismantleNSView(_ view:WorkbenchShortcutCaptureControl,coordinator:()) {view.disconnect()}
}

/// The visible candidate field is the actual keyboard responder. App-wide local
/// monitoring still handles registered combinations and outside clicks; a
/// consumed monitor event is never forwarded here by NSApplication.
@MainActor final class WorkbenchShortcutCaptureControl:NSControl {
    weak var recorder:WorkbenchShortcutRecorder?
    var palette=ThemePalette()
    var valueText="未设置"
    private weak var observedWindow:NSWindow?
    private var becameKeyObserver:NSObjectProtocol?
    private var initialFocusCompleted=false
    private var initialFocusScheduled=false
    private var focusGeneration=UUID()
    override var acceptsFirstResponder:Bool {isEnabled && recorder?.isPresented == true}
    override var intrinsicContentSize:NSSize {NSSize(width:NSView.noIntrinsicMetric,height:40)}
    override init(frame:NSRect) {
        super.init(frame:frame)
        focusRingType = .exterior
        setAccessibilityElement(true);setAccessibilityRole(.textField)
        setAccessibilityHelp("按下包含 Control、Option 或 Command 的组合键；Esc 取消，Tab 切换按钮。")
    }
    required init?(coder:NSCoder){fatalError()}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();connect()}
    func connect() {
        guard let window,recorder?.isPresented == true else {return}
        recorder?.attach(window:window)
        if observedWindow !== window {
            stopWaitingForKeyWindow();observedWindow=window
            if !initialFocusCompleted {
                becameKeyObserver=NotificationCenter.default.addObserver(forName:NSWindow.didBecomeKeyNotification,object:window,queue:.main){[weak self] _ in
                    MainActor.assumeIsolated {self?.scheduleInitialFocus()}
                }
            }
        }
        scheduleInitialFocus()
    }
    private func scheduleInitialFocus() {
        guard !initialFocusCompleted,!initialFocusScheduled,isEnabled,
              let window,window.isVisible,window.isKeyWindow,recorder?.isPresented == true else {return}
        initialFocusScheduled=true
        let generation=focusGeneration
        let previousResponder=window.firstResponder
        DispatchQueue.main.async {[weak self,weak window,weak previousResponder] in
            guard let self,self.focusGeneration == generation else {return}
            self.initialFocusScheduled=false
            guard !self.initialFocusCompleted,let window,self.window === window,
                  window.isVisible,window.isKeyWindow,self.recorder?.isPresented == true else {return}
            // A Tab/click made after mounting owns the focus. A later SwiftUI
            // update must never take it back from that control.
            guard window.firstResponder === previousResponder else {self.finishInitialFocus();return}
            if let control=window.firstResponder as? NSControl,control !== self {self.finishInitialFocus();return}
            _=self.focusCapture()
        }
    }
    private func finishInitialFocus(){initialFocusCompleted=true;initialFocusScheduled=false;stopWaitingForKeyWindow()}
    private func stopWaitingForKeyWindow(){if let becameKeyObserver {NotificationCenter.default.removeObserver(becameKeyObserver);self.becameKeyObserver=nil}}
    @discardableResult private func focusCapture()->Bool {
        guard isEnabled,let window,window.isVisible,window.isKeyWindow,recorder?.canCapture(in:window) == true else {return false}
        let focused=window.makeFirstResponder(self)
        if focused {finishInitialFocus()}
        return focused
    }
    override func becomeFirstResponder()->Bool {
        finishInitialFocus();needsDisplay=true
        NSAccessibility.post(element:self,notification:.focusedUIElementChanged)
        return true
    }
    override func resignFirstResponder()->Bool {needsDisplay=true;return true}
    override func mouseDown(with event:NSEvent){_=focusCapture()}
    override func keyDown(with event:NSEvent) {
        guard isEnabled,let window,window.isVisible,window.isKeyWindow,
              window.firstResponder === self,let recorder,recorder.canCapture(in:window) else {return}
        if recorder.handleEvent(event) {return}
        let flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48,flags.intersection([.command,.control,.option]).isEmpty {
            if flags.contains(.shift) {window.selectPreviousKeyView(self)}else{window.selectNextKeyView(self)}
            return
        }
        super.keyDown(with:event)
    }
    override func isAccessibilityFocused()->Bool {window?.isKeyWindow == true && window?.firstResponder === self}
    override func setAccessibilityFocused(_ focused:Bool) {
        if focused {_=focusCapture()}else if window?.firstResponder === self {window?.makeFirstResponder(nil)}
    }
    override func accessibilityPerformPress()->Bool {focusCapture()}
    func disconnect() {
        focusGeneration=UUID();initialFocusScheduled=false;stopWaitingForKeyWindow();observedWindow=nil
        if window?.firstResponder === self {window?.makeFirstResponder(nil)}
        recorder?.cancel();recorder=nil
    }
    override func draw(_ dirtyRect:NSRect) {
        let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:8,yRadius:8)
        NSColor(palette.soft).setFill();shape.fill();NSColor(palette.line).setStroke();shape.lineWidth=1;shape.stroke()
        let style=NSMutableParagraphStyle();style.alignment = .center
        let text=NSAttributedString(string:valueText,attributes:[.font:NSFont.monospacedSystemFont(ofSize:14,weight:.medium),.foregroundColor:NSColor(palette.text),.paragraphStyle:style])
        text.draw(in:NSRect(x:10,y:(bounds.height-text.size().height)/2,width:max(0,bounds.width-20),height:text.size().height))
    }
    override var focusRingMaskBounds:NSRect {bounds}
    override func drawFocusRingMask(){NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8).fill()}
}

/// A stable native trigger keeps keyboard focus when the page reflows. Its
/// dimensions and theme tokens match the shared compact button exactly.
private struct WorkbenchShortcutTrigger:NSViewRepresentable {
    let title:String
    let label:String
    let identifier:String
    let action:()->Void
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context:Context)->WorkbenchShortcutTriggerButton {WorkbenchShortcutTriggerButton(frame:.zero)}
    func updateNSView(_ button:WorkbenchShortcutTriggerButton,context:Context) {
        if button.title != title {button.title=title;button.invalidateIntrinsicContentSize()}
        button.palette=palette;button.isEnabled=enabled;button.activate=action
        button.setAccessibilityLabel(label);button.setAccessibilityIdentifier(identifier);button.needsDisplay=true
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:WorkbenchShortcutTriggerButton,context:Context)->CGSize? {nsView.intrinsicContentSize}
}
private final class WorkbenchShortcutTriggerButton:ClickableButton {
    var palette=ThemePalette()
    var activate:(()->Void)?
    private var hovering=false
    private var tracking:NSTrackingArea?
    override init(frame:NSRect) {super.init(frame:frame);isBordered=false;setButtonType(.momentaryPushIn);target=self;action=#selector(invoke);font = .systemFont(ofSize:11);focusRingType = .exterior}
    required init?(coder:NSCoder){fatalError()}
    override var acceptsFirstResponder:Bool {isEnabled}
    override var intrinsicContentSize:NSSize {NSSize(width:ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width)+16,height:28)}
    @objc private func invoke(){guard isEnabled else{return};activate?()}
    override func mouseDown(with event:NSEvent){window?.makeFirstResponder(self);super.mouseDown(with:event)}
    override func keyDown(with event:NSEvent) {
        if [36,49,76].contains(event.keyCode),event.modifierFlags.intersection([.command,.option,.control]).isEmpty {if !event.isARepeat {performClick(nil)};return}
        super.keyDown(with:event)
    }
    override func updateTrackingAreas(){super.updateTrackingAreas();if let tracking {removeTrackingArea(tracking)};let area=NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil);addTrackingArea(area);tracking=area}
    override func mouseEntered(with event:NSEvent){hovering=true;needsDisplay=true}
    override func mouseExited(with event:NSEvent){hovering=false;needsDisplay=true}
    override func draw(_ dirtyRect:NSRect) {
        let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:8,yRadius:8)
        let fill=NSColor(isHighlighted ? palette.accent.opacity(0.18):hovering ? palette.soft:palette.control),border=NSColor(palette.controlBorder)
        fill.withAlphaComponent(fill.alphaComponent*(isEnabled ? 1:0.4)).setFill();shape.fill()
        border.withAlphaComponent(border.alphaComponent*(isEnabled ? 1:0.4)).setStroke();shape.lineWidth=1;shape.stroke()
        drawText(title,in:NSRect(x:8,y:(bounds.height-16)/2,width:max(0,bounds.width-16),height:16),size:11,color:NSColor(hovering ? palette.text:palette.secondary).withAlphaComponent(isEnabled ? 1:0.4),alignment:.center)
    }
    override var focusRingMaskBounds:NSRect {bounds}
    override func drawFocusRingMask(){NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8).fill()}
}
