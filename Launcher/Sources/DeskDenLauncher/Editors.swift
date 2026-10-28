import AppKit
import UniformTypeIdentifiers
import LauncherCore

@MainActor
final class MenuAction: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
    @objc func invoke(_ sender: Any?) { perform() }
}

/// A floating surface with its own window; opening a binding never resizes or dims the launcher.
final class BindingPopoverSurface: FlippedView {
    let card: CardView
    private let glass = GlassBackgroundView()
    var arrowX: CGFloat = 24
    var pointsUp = true
    let showsArrow: Bool
    let cornerRadius: CGFloat
    private let arrowHeight: CGFloat = 12
    var outsideMonitor: Any?
    init(card: CardView, showsArrow: Bool = true, cornerRadius: CGFloat = 20) {
        self.card = card; self.showsArrow = showsArrow; self.cornerRadius = cornerRadius
        super.init(frame: NSRect(x: 0, y: 0, width: card.frame.width, height: card.frame.height + (showsArrow ? 12 : 0)))
        glass.surfaceStyle = .panel; glass.frame = bounds; glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        card.radius = cornerRadius; card.usesGlassBackground = false
        card.frame.origin = NSPoint(x: 0, y: showsArrow ? arrowHeight : 0)
        addSubview(card); updateGlassShape()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); glass.frame = bounds; updateGlassShape() }
    func installOutsideHandler(owner: LauncherController) {
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak owner] event in
            let handled = MainActor.assumeIsolated {
                guard let owner, let popup=owner.editorPanel, event.window !== popup, !owner.pickerActive else { return false }
                if event.window === owner.panel {owner.requestCloseEditor();return true}
                // The opacity surface has no draft: a click in the workbench may
                // dismiss it and continue to the clicked control without refocusing the launcher.
                if (popup.contentView as? BindingPopoverSurface)?.card is GlobalOpacityMenuView {owner.closeOverlay(render:false)}
                return false
            }
            return handled ? nil : event
        }
    }
    func removeOutsideHandler() { if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil } }
    func orient(up: Bool, arrowX: CGFloat) {
        guard showsArrow else { return }
        pointsUp = up; self.arrowX = min(bounds.width - cornerRadius - 14, max(cornerRadius + 14, arrowX))
        card.frame.origin.y = up ? arrowHeight : 0; updateGlassShape()
    }
    private func updateGlassShape() {
        guard showsArrow else { glass.customShape = nil; glass.radius = cornerRadius; return }
        // One contour gives the body and arrow identical blur, tint, and a continuous edge.
        let body = card.frame.insetBy(dx: 0.5, dy: 0.5)
        let radius = cornerRadius, curve = radius * 0.5522847498
        let path = NSBezierPath()
        path.move(to: NSPoint(x: body.minX + radius, y: body.minY))
        if pointsUp {
            path.line(to: NSPoint(x: arrowX - 14, y: body.minY))
            path.curve(to: NSPoint(x: arrowX - 10, y: body.minY - 2), controlPoint1: NSPoint(x: arrowX - 12, y: body.minY), controlPoint2: NSPoint(x: arrowX - 11, y: body.minY - 1))
            path.line(to: NSPoint(x: arrowX - 2, y: 2))
            path.curve(to: NSPoint(x: arrowX + 2, y: 2), controlPoint1: NSPoint(x: arrowX - 0.8, y: 0), controlPoint2: NSPoint(x: arrowX + 0.8, y: 0))
            path.line(to: NSPoint(x: arrowX + 10, y: body.minY - 2))
            path.curve(to: NSPoint(x: arrowX + 14, y: body.minY), controlPoint1: NSPoint(x: arrowX + 11, y: body.minY - 1), controlPoint2: NSPoint(x: arrowX + 12, y: body.minY))
        }
        path.line(to: NSPoint(x: body.maxX - radius, y: body.minY))
        path.curve(to: NSPoint(x: body.maxX, y: body.minY + radius), controlPoint1: NSPoint(x: body.maxX - radius + curve, y: body.minY), controlPoint2: NSPoint(x: body.maxX, y: body.minY + radius - curve))
        path.line(to: NSPoint(x: body.maxX, y: body.maxY - radius))
        path.curve(to: NSPoint(x: body.maxX - radius, y: body.maxY), controlPoint1: NSPoint(x: body.maxX, y: body.maxY - radius + curve), controlPoint2: NSPoint(x: body.maxX - radius + curve, y: body.maxY))
        if !pointsUp {
            path.line(to: NSPoint(x: arrowX + 14, y: body.maxY))
            path.curve(to: NSPoint(x: arrowX + 10, y: body.maxY + 2), controlPoint1: NSPoint(x: arrowX + 12, y: body.maxY), controlPoint2: NSPoint(x: arrowX + 11, y: body.maxY + 1))
            path.line(to: NSPoint(x: arrowX + 2, y: bounds.height - 2))
            path.curve(to: NSPoint(x: arrowX - 2, y: bounds.height - 2), controlPoint1: NSPoint(x: arrowX + 0.8, y: bounds.height), controlPoint2: NSPoint(x: arrowX - 0.8, y: bounds.height))
            path.line(to: NSPoint(x: arrowX - 10, y: body.maxY + 2))
            path.curve(to: NSPoint(x: arrowX - 14, y: body.maxY), controlPoint1: NSPoint(x: arrowX - 11, y: body.maxY + 1), controlPoint2: NSPoint(x: arrowX - 12, y: body.maxY))
        }
        path.line(to: NSPoint(x: body.minX + radius, y: body.maxY))
        path.curve(to: NSPoint(x: body.minX, y: body.maxY - radius), controlPoint1: NSPoint(x: body.minX + radius - curve, y: body.maxY), controlPoint2: NSPoint(x: body.minX, y: body.maxY - radius + curve))
        path.line(to: NSPoint(x: body.minX, y: body.minY + radius))
        path.curve(to: NSPoint(x: body.minX + radius, y: body.minY), controlPoint1: NSPoint(x: body.minX, y: body.minY + radius - curve), controlPoint2: NSPoint(x: body.minX + radius - curve, y: body.minY))
        path.close(); glass.customShape = path
    }
}

extension LauncherController {
    func menuItem(_ title: String, symbol: String? = nil, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke(_:)), keyEquivalent: "")
        let handler = MenuAction(action); item.target = handler; item.representedObject = handler
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        item.isEnabled = enabled; return item
    }
    func popMenu(_ value: NSMenu, anchor: NSView) {
        guard !isPreparingToQuit else { return }
        value.autoenablesItems = false; value.font = .systemFont(ofSize: 13); menu = value
        value.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 6), in: anchor)
        menu = nil
    }
    func showTypeMenu(_ key: String, anchor: NSView) {
        guard !isPreparingToQuit else { return }
        closeOverlay(render: false)
        let bound = bindings[key] != nil
        let width: CGFloat = bound ? 264 : 184
        let card = CardView(frame: NSRect(x: 0, y: 0, width: width, height: bound ? 300 : 216)); card.radius = 20
        let kinds: [TargetKind] = [.app, .file, .folder, .web, .shortcut, .shell]
        for (index, kind) in kinds.enumerated() {
            let item = BindingTypeRow(kind: kind, frame: NSRect(x: 8, y: 6 + index * 34, width: Int(width) - 16, height: 34)) { [weak self] in self?.openEditor(key, kind: kind) }
            card.addSubview(item)
        }
        if bound {
            let line = NSBox(frame: NSRect(x: 12, y: 220, width: width - 24, height: 1)); line.boxType = .separator; card.addSubview(line)
            let shortcut = button("设置快捷键", symbol: "keyboard", rect: NSRect(x: 8, y: 228, width: width - 16, height: 32), in: card) { [weak self] in self?.showBindingHotKey(key) }
            shortcut.fontSize = 14; shortcut.isEnabled = !isEditing
            if let value = configuration.bindingHotKeys[key] { label(value.title, x: width - 105, y: 235, width: 85, height: 18, size: 12, color: Palette.muted, alignment: .right, in: card) }
            let remove = button("移除绑定", symbol: "minus.circle", rect: NSRect(x: 8, y: 262, width: width - 16, height: 32), in: card) { [weak self] in self?.removeBinding(key) }; remove.fontSize = 14; remove.textColor = Palette.error
        }
        presentBindingCard(card, anchor: anchor)
    }
    func showKeyMenu(_ key: String, anchor: NSView) { showTypeMenu(key, anchor: anchor) }
    func showDisplayMenu() {
        guard !isPreparingToQuit else { return }
        let value = NSMenu(title: "按键显示方式")
        for mode in DisplayMode.allCases { let item = menuItem(mode.title) { [weak self] in self?.setDisplay(mode) }; item.state = configuration.settings.display == mode ? .on : .off; value.addItem(item) }
        value.addItem(.separator())
        value.addItem(menuItem("编辑绑定…", symbol: "square.and.pencil") { [weak self] in self?.beginEditing() })
        let anchor = content.subviews.first { $0.accessibilityLabel() == "按键显示方式" } ?? content
        popMenu(value, anchor: anchor)
    }
    func showResultMenu(_ entry: SearchEntry, anchor: NSView) {
        guard !isPreparingToQuit else { return }
        let value = NSMenu()
        if entry.target.kind == .app {
            let starred = configuration.starredApplications.contains(entry.target.id)
            value.addItem(menuItem(starred ? "取消星标" : "设为星标", symbol: starred ? "star.slash" : "star") { [weak self] in
                guard let self else { return }
                var candidate = configuration
                if starred { candidate.starredApplications.removeAll { $0 == entry.target.id } }
                else if !candidate.starredApplications.contains(entry.target.id) { candidate.starredApplications.append(entry.target.id) }
                if save(candidate) { renderResults() }
            })
            value.addItem(.separator())
            let uninstall = menuItem("卸载应用", symbol: "trash", enabled: canUninstall(entry.target)) { [weak self] in self?.requestUninstall(entry.target) }
            if let url = TargetResolver.url(for: entry.target), isRunningApplication(at: url) { uninstall.toolTip = "请先退出应用，再卸载。" }
            value.addItem(uninstall)
            value.addItem(.separator())
        } else {
            value.addItem(menuItem("打开 \(entry.title)", symbol: "arrow.up.right") { [weak self] in self?.launch(entry.target) })
        }
        let bind = NSMenuItem(title: "绑定到按键", action: nil, keyEquivalent: ""); let submenu = NSMenu()
        for key in KeyboardLayout.keys { submenu.addItem(menuItem("\(key)\(bindings[key].map { " · \($0.title)" } ?? "")") { [weak self] in self?.openEditor(key, kind: entry.target.kind, preselected: entry.target, anchor: anchor) }) }
        bind.submenu = submenu; value.addItem(bind)
        if entry.target.kind.isFileSystem { value.addItem(menuItem("在访达中显示", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.target.location)]) }) }
        popMenu(value, anchor: anchor)
    }
    func canUninstall(_ target: LaunchTarget) -> Bool {
        guard target.kind == .app, let url = TargetResolver.url(for: target), !isRunningApplication(at: url) else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let systemRoots = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]
        guard !systemRoots.contains(where: path.hasPrefix), path != Bundle.main.bundleURL.resolvingSymlinksInPath().path else { return false }
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/")
    }
    func isRunningApplication(at url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path }
    }
    func requestUninstall(_ target: LaunchTarget) {
        guard !isPreparingToQuit else { return }
        guard canUninstall(target), let url = TargetResolver.url(for: target) else { return }
        let alert = NSAlert(); alert.messageText = "将「\(target.name)」移到废纸篓？"; alert.informativeText = "应用文件将移到废纸篓。已有按键绑定会保留，可稍后重新绑定。"; alert.alertStyle = .warning
        alert.addButton(withTitle: "移到废纸篓"); alert.addButton(withTitle: "取消")
        pickerActive = true
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }; pickerActive = false
            guard response == .alertFirstButtonReturn else { panel.makeKeyAndOrderFront(nil); focus(); return }
            guard canUninstall(target), let currentURL = TargetResolver.url(for: target), currentURL.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
                toast("应用正在运行或位置已改变，请退出应用后重试。", persistent: true); return
            }
            NSWorkspace.shared.recycle([currentURL]) { [weak self] _, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error { self.toast("卸载失败：\(error.localizedDescription)", persistent: true); return }
                    var candidate = self.configuration
                    candidate.addedApplications.removeAll { $0.id == target.id }; candidate.starredApplications.removeAll { $0 == target.id }
                    _ = self.save(candidate); self.applications.removeAll { $0.id == target.id }; self.rebuildIndex(); self.renderResults(); self.refreshApplications(force: true); self.toast("已将应用移到废纸篓")
                }
            }
        }
    }
    func openEditor(_ key: String, kind: TargetKind? = nil, preselected: LaunchTarget? = nil, anchor explicitAnchor: NSView? = nil) {
        guard !isPreparingToQuit else { return }
        let tile = content.subviews.compactMap { $0 as? KeyTile }.first { $0.key == key }
        if kind == nil, bindings[key] == nil, let tile { showTypeMenu(key, anchor: tile); return }
        closeOverlay(render: false)
        let form = BindingForm(owner: self, key: key, kind: kind ?? bindings[key]?.target.kind ?? .app, preselected: preselected)
        editor = form
        if [.file, .folder, .shell].contains(form.kind) { form.browse(); return }
        presentBindingCard(form, anchor: explicitAnchor ?? tile ?? content)
        form.loadChoices()
        editorPanel?.makeFirstResponder(form.initialFocus)
        if preselected != nil { form.save() }
    }
    func presentBindingCard(_ card: CardView, anchor: NSView, centered requestedCenter: Bool? = nil) {
        guard !isPreparingToQuit else { return }
        let centered = requestedCenter ?? (card as? BindingForm).map { ![.app, .web].contains($0.kind) } ?? (card is WebVariableForm)
        let radius: CGFloat = (card as? BindingForm)?.kind == .shortcut ? 16 : card is BindingForm || !centered ? 20 : card.radius
        let root = BindingPopoverSurface(card: card, showsArrow: !centered, cornerRadius: radius)
        let anchorRect = panel.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? panel.frame
        let width = root.frame.width, height = root.frame.height
        let x = centered ? visible.midX - width / 2 : min(visible.maxX - width - 12, max(visible.minX + 12, anchorRect.midX - width / 2))
        let below = anchorRect.minY - height - 6
        let up = below >= visible.minY + 12 || anchorRect.maxY + height + 6 > visible.maxY - 12
        let proposedY = up ? below : anchorRect.maxY + 6
        let y = centered ? visible.midY - height / 2 : min(visible.maxY - height - 12, max(visible.minY + 12, proposedY))
        root.orient(up: up, arrowX: anchorRect.midX - x)
        let popup = LauncherPanel(contentRect: NSRect(x: x, y: y, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.isOpaque = false; popup.backgroundColor = .clear; popup.hasShadow = true; popup.level = panel.level; popup.isReleasedWhenClosed = false; popup.hidesOnDeactivate = false; popup.becomesKeyOnlyIfNeeded = false; popup.appearance = NSAppearance(named: Palette.isLight ? .aqua : .darkAqua)
        popup.collectionBehavior = [.fullScreenAuxiliary]; popup.contentView = root
        editorPanel = popup; panel.addChildWindow(popup, ordered: .above); popup.makeKeyAndOrderFront(nil); root.installOutsideHandler(owner: self)
        if editor == nil { popup.makeFirstResponder(card.subviews.first(where: { $0 is NSControl })) }
    }
    func present(_ card: CardView) {
        guard !isPreparingToQuit else { return }
        let shade = ShadeView(frame: background.bounds); shade.addSubview(card); overlay = shade
        background.addSubview(shade); render(); centerOverlay()
    }
    func centerOverlay() {
        guard let overlay, let card = overlay.subviews.first else { return }
        card.frame.origin = NSPoint(x: (size.width - card.frame.width) / 2, y: (size.height - card.frame.height) / 2)
    }
    func requestCloseEditor() {
        guard !pickerActive else { return }
        if let form = (editorPanel?.contentView as? BindingPopoverSurface)?.card as? BindingHotKeyForm, form.hasChanges { form.confirmDiscard(); return }
        if let form = (editorPanel?.contentView as? BindingPopoverSurface)?.card as? ScanDirectoriesCard { form.requestClose(); return }
        guard let editor, editor.hasChanges else { closeOverlay(); return }
        editor.confirm("放弃当前修改？", detail: "尚未保存的内容将被放弃。", primary: "放弃修改") { [weak self] in self?.closeOverlay() }
    }
    func closeOverlay(render shouldRender: Bool = true) {
        guard !pickerActive else { return }
        if let variables = (editorPanel?.contentView as? BindingPopoverSurface)?.card as? WebVariableForm { variables.cancelPending() }
        editor?.cancelLoading(); editor = nil
        if let popup = editorPanel { (popup.contentView as? BindingPopoverSurface)?.removeOutsideHandler(); panel.removeChildWindow(popup); popup.orderOut(nil); popup.close(); editorPanel = nil }
        overlay?.removeFromSuperview(); overlay = nil
        if shouldRender && !isPreparingToQuit { render(); panel.makeKeyAndOrderFront(nil); focus() }
    }
    func showHelp() {
        guard !isPreparingToQuit else { return }
        closeOverlay(render:false)
        let card = CardView(frame:NSRect(x:0,y:0,width:460,height:480))
        label("顺手的键盘操作",x:22,y:22,width:370,height:24,size:16,in:card)
        label("按键启动与文字输入分开处理",x:22,y:52,width:400,height:18,size:11,color:Palette.secondary,in:card)
        let rows = [(configuration.settings.effectiveLauncherHotKey.title,"呼出 / 收起启动器"),("字母 / 数字 / − / =","按键页启动已绑定目标"),("Tab","切换按键与应用，非空查询保留"),("⌘ F","进入文字输入，支持中文和数字"),("↵ / 1–9","按键搜索打开选中项 / 对应结果"),("↑ ↓ ← →","按键搜索时选择结果"),("Esc","清除查询 → 返回按键 → 收起"),("右键","修改或移除绑定；搜索结果可绑定")]
        for (index,row) in rows.enumerated() { let y = CGFloat(92+index*34); label(row.0,x:22,y:y,width:143,height:20,size:11,color:Palette.accent,in:card); label(row.1,x:169,y:y,width:271,height:22,size:12,color:Palette.secondary,in:card) }
        label("文字输入时数字用于输入；中文选词期间，回车与数字交给输入法。",x:22,y:373,width:412,height:40,size:11,color:Palette.muted,in:card).maximumNumberOfLines = 2
        button("知道了",rect:NSRect(x:344,y:427,width:94,height:34),primary:true,in:card) { [weak self] in self?.closeOverlay() }
        present(card)
    }
    func showSettings() {
        guard !isPreparingToQuit else { return }
        guard !pickerActive else { return }
        if editorPanel != nil { requestCloseEditor(); return }
        closeOverlay(render: false)
        showWorkbench(route:.settings,settingsTab:.launcher)
    }

}

final class ClosurePopup: WBPopUpButton {}
final class ClosureCheckbox: ClickableButton {
    var changed:(()->Void)?
    init(title:String,frame:NSRect) { super.init(frame:frame); self.title = title; setButtonType(.switch); target = self; action = #selector(change) }
    required init?(coder:NSCoder) { fatalError() }
    @objc func change() { changed?() }
}

private final class BindingTypeRow: ClickableButton {
    let kind: TargetKind
    private let activate: () -> Void
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    init(kind: TargetKind, frame: NSRect, activate: @escaping () -> Void) {
        self.kind = kind; self.activate = activate
        super.init(frame: frame)
        title = ""; isBordered = false; focusRingType = .none
        target = self; action = #selector(invoke); setAccessibilityLabel("绑定" + kind.title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { activate() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted || window?.firstResponder === self {
            Palette.ink.withAlphaComponent(isHighlighted ? 0.16 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let symbol = kind == .app ? "app.dashed" : kind == .shortcut ? "sparkles" : kind.symbol
        drawSymbol(symbol, in: NSRect(x: 8, y: 8, width: 18, height: 18), color: Palette.secondary)
        drawText(kind.title, in: NSRect(x: 34, y: 8.5, width: bounds.width - 40, height: 19), size: 13, color: Palette.text, weight: .semibold)
    }
}

final class BindingForm: CardView, NSSearchFieldDelegate, NSTextViewDelegate {
    weak var owner: LauncherController?
    let sourceKey: String
    var kind: TargetKind
    var selectedTarget: LaunchTarget?
    var aliasField = NSTextField()
    var destination = ClosurePopup(frame: .zero)
    var filter = LauncherSearchField(frame: .zero)
    /// Kept as the canonical address value; the visible editor is a multiline native text view.
    var urlField = NSTextField()
    var bodyEditor = NSTextView()
    var choices: [LaunchTarget] = []
    var filteredChoices: [LaunchTarget] = []
    var choicesView = FlippedView()
    var selectedLabel: NSTextField?
    var errorLabel: NSTextField?
    var listScroll = NSScrollView()
    var loadTask: Task<Void, Never>?
    var confirmation: FlippedView?
    weak var retryButton: ActionButton?
    private weak var saveButton: ActionButton?
    private var focusedChoice = 0
    private var headerControls: [NSView] = []
    private var fieldControls: [NSView] = []
    private var initialAlias = ""
    private var initialLocation = ""
    private var bodyPlaceholder: NSTextField?
    private var iconView: NSImageView?
    private var iconTask: Task<Void, Never>?
    var webIconData: Data?
    private var initialIconData: Data?
    var webIconIsCustom = false
    private var initialIconIsCustom = false
    private var fetchedIconOrigin: String?
    private var choiceRowHeight: CGFloat { kind == .shortcut ? 41 : 42 }
    var tabFocusViews: [NSView] {
        if confirmation != nil { return [] }
        let row = choicesView.subviews.compactMap { $0 as? TargetChoiceRow }.first { $0.keyboardSelected }
        let candidate: [NSView] = row.map { [$0] } ?? []
        if kind == .shortcut { return headerControls + [filter] + candidate + fieldControls.dropFirst() }
        return headerControls + fieldControls + candidate
    }
    var initialFocus: NSView { if kind == .app || kind == .shortcut { return filter }; if kind == .web { return aliasField }; return fieldControls.first ?? self }
    var hasChanges: Bool {
        if kind == .app { return false }
        if kind == .shortcut { return selectedTarget?.location != (initialLocation.isEmpty ? nil : initialLocation) || !filter.stringValue.isEmpty }
        return aliasField.stringValue != initialAlias || urlField.stringValue != initialLocation || webIconData != initialIconData || webIconIsCustom != initialIconIsCustom
    }
    init(owner: LauncherController, key: String, kind: TargetKind, preselected: LaunchTarget?) {
        self.owner = owner; sourceKey = key; self.kind = kind
        let current = owner.bindings[key]
        selectedTarget = preselected ?? (current?.target.kind == kind ? current?.target : nil)
        super.init(frame: NSRect(x: 0, y: 0, width: kind == .app ? 430 : 330, height: [.app, .web, .shortcut].contains(kind) ? 430 : 214))
        radius = 20
        aliasField.stringValue = preselected == nil ? current?.alias ?? "" : ""
        if kind == .web, let current, current.alias.isEmpty { aliasField.stringValue = current.target.name }
        urlField.stringValue = selectedTarget?.location ?? ""
        webIconData = selectedTarget?.iconData; initialIconData = webIconData
        webIconIsCustom = selectedTarget?.iconIsCustom == true; initialIconIsCustom = webIconIsCustom
        if webIconData != nil, !webIconIsCustom { fetchedIconOrigin = try? WebURLTemplate(urlField.stringValue).originURL.absoluteString }
        initialAlias = aliasField.stringValue; initialLocation = urlField.stringValue
        destination.addItems(withTitles: KeyboardLayout.keys); destination.selectItem(withTitle: key)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }
    func cancelLoading() { loadTask?.cancel(); iconTask?.cancel() }
    func build() {
        guard let owner else { return }
        subviews.forEach { $0.removeFromSuperview() }; headerControls.removeAll(); fieldControls.removeAll(); confirmation = nil
        let width = bounds.width
        let icon = EditorSymbolView(symbol: kind == .app ? "app.dashed" : kind == .shortcut ? "sparkles" : kind.symbol, frame: NSRect(x: 12, y: 24, width: 16, height: 16)); addSubview(icon)
        owner.label("绑定\(kind.title)", x: 33, y: 23, width: width - 145, height: 22, size: 13, in: self).font = .systemFont(ofSize: 13, weight: .semibold)
        if kind == .app {
            let folders = owner.button("", symbol: "folder.badge.gearshape", rect: NSRect(x: width - 116, y: 17, width: 28, height: 28), in: self) { [weak self] in self?.showBrowseMenu() }
            folders.setAccessibilityLabel("扫描文件夹或选择应用"); folders.toolTip = "扫描文件夹或选择应用"
            let refresh = owner.button("", symbol: "arrow.clockwise", rect: NSRect(x: width - 84, y: 17, width: 28, height: 28), in: self) { [weak self] in self?.owner?.refreshApplications(force: true) }
            refresh.setAccessibilityLabel("刷新应用"); refresh.toolTip = "刷新应用"; headerControls += [folders, refresh]
        }
        let close = owner.button("", symbol: "xmark", rect: NSRect(x: width - 44, y: 17, width: 28, height: 28), in: self) { [weak owner] in owner?.requestCloseEditor() }
        close.setAccessibilityLabel("关闭绑定面板"); headerControls.append(close)
        if kind == .app || kind == .shortcut {
            filter.frame = NSRect(x: 12, y: 60, width: width - 24, height: 30)
            filter.placeholderString = kind == .app ? "首字母搜应用" : "搜索或输入快捷指令名称"
            filter.delegate = self; filter.font = .systemFont(ofSize: 13); filter.focusRingType = .none
            filter.setAccessibilityLabel("筛选绑定目标"); addSubview(filter); fieldControls.append(filter)
            listScroll.frame = NSRect(x: 12, y: 100, width: width - 24, height: kind == .shortcut ? 276 : 318)
            if kind == .shortcut {
                let surface = SoftSurface(frame: listScroll.frame); surface.radius = 8; addSubview(surface)
            }
            listScroll.drawsBackground = false; listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true
            listScroll.scrollerStyle = .legacy; listScroll.verticalScroller = LauncherScroller()
            choicesView.frame = NSRect(x: 0, y: 0, width: listScroll.frame.width, height: listScroll.frame.height)
            listScroll.documentView = choicesView; addSubview(listScroll)
            refreshChoices()
            if kind == .shortcut {
                let cancel = owner.button("取消", rect: NSRect(x: 12, y: 386, width: 148, height: 32), border: true, in: self) { [weak owner] in owner?.requestCloseEditor() }
                let save = owner.button("保存", rect: NSRect(x: 170, y: 386, width: 148, height: 32), primary: true, in: self) { [weak self] in self?.save() }
                saveButton = save; fieldControls += [cancel, save]
            }
        } else if kind == .web {
            buildWeb()
        } else {
            buildFile()
        }
        updateSaveAvailability()
    }
    func buildWeb() {
        guard let owner else { return }
        let surface = SoftSurface(frame: NSRect(x: 12, y: 60, width: 306, height: 84)); surface.radius = 9; addSubview(surface)
        let image = NSImageView(frame: NSRect(x: 16, y: 16, width: 52, height: 52)); image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel("网站图标"); surface.addSubview(image); iconView = image; refreshWebsitePreview()
        let hint = owner.label("输入网址后自动获取网站图标", x: 84, y: 18, width: 210, height: 24, size: 11, color: Palette.secondary, in: surface); hint.maximumNumberOfLines = 2
        let upload = owner.button("上传图标", rect: NSRect(x: 84, y: 40, width: 64, height: 26), border: true, in: surface) { [weak self] in self?.uploadIcon() }; upload.fontSize = 11
        styleField(aliasField, placeholder: "名称，例如：官网 / 文档中心", rect: NSRect(x: 12, y: 154, width: 306, height: 30)); aliasField.setAccessibilityLabel("网页名称")
        buildBody(rect: NSRect(x: 12, y: 194, width: 306, height: 182), value: urlField.stringValue, placeholder: "网址，例如：https://vkr.me?v={ID}&name={名字}\n{ID}、{名字} 会在触发跳转时弹窗填写")
        bodyEditor.setAccessibilityLabel("网页地址")
        let cancel = owner.button("取消", rect: NSRect(x: 12, y: 386, width: 148, height: 32), border: true, in: self) { [weak owner] in owner?.requestCloseEditor() }
        let save = owner.button("保存", rect: NSRect(x: 170, y: 386, width: 148, height: 32), primary: true, in: self) { [weak self] in self?.save() }
        saveButton = save; fieldControls = [upload, aliasField, bodyEditor, cancel, save]
    }
    private func refreshWebsitePreview() {
        if let webIconData, let image = NSImage(data: webIconData) { iconView?.image = image; return }
        iconView?.image = NSImage(size: NSSize(width: 52, height: 52), flipped: true) { bounds in
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.16); shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: 1); shadow.set()
            NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12).fill()
            NSGraphicsContext.restoreGraphicsState()
            drawSymbol("globe", in: bounds.insetBy(dx: 14, dy: 14), color: NSColor(calibratedWhite: 0.9, alpha: 1))
            return true
        }
    }
    func buildFile() {
        guard let owner else { return }
        owner.label(selectedTarget?.name ?? "选择\(kind.title)", x: 12, y: 61, width: 306, height: 24, size: 14, in: self)
        selectedLabel = owner.label(selectedTarget?.location ?? "从本机重新选择要绑定的目标", x: 12, y: 93, width: 306, height: 36, size: 11, color: Palette.muted, in: self)
        selectedLabel?.maximumNumberOfLines = 2; selectedLabel?.lineBreakMode = .byTruncatingMiddle
        let choose = owner.button("重新选择…", rect: NSRect(x: 12, y: 170, width: 148, height: 32), border: true, in: self) { [weak self] in self?.browse() }
        let cancel = owner.button("取消", rect: NSRect(x: 170, y: 170, width: 148, height: 32), border: true, in: self) { [weak owner] in owner?.requestCloseEditor() }
        fieldControls = [choose, cancel]
    }
    func buildBody(rect: NSRect, value: String, placeholder: String) {
        let surface = SoftSurface(frame: rect); surface.radius = 8; addSubview(surface)
        let scroll = NSScrollView(frame: surface.bounds.insetBy(dx: 9, dy: 6)); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .legacy; scroll.verticalScroller = LauncherScroller()
        bodyEditor = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize)); bodyEditor.delegate = self; bodyEditor.isRichText = false; bodyEditor.importsGraphics = false; bodyEditor.drawsBackground = false
        bodyEditor.textColor = Palette.text; bodyEditor.insertionPointColor = Palette.text; bodyEditor.font = .systemFont(ofSize: 13); bodyEditor.string = value
        bodyEditor.isAutomaticQuoteSubstitutionEnabled = false; bodyEditor.isAutomaticDashSubstitutionEnabled = false; bodyEditor.isAutomaticTextReplacementEnabled = false; bodyEditor.isContinuousSpellCheckingEnabled = false; bodyEditor.isAutomaticSpellingCorrectionEnabled = false
        bodyEditor.isVerticallyResizable = true; bodyEditor.isHorizontallyResizable = false; bodyEditor.autoresizingMask = [.width]; bodyEditor.textContainer?.widthTracksTextView = true; bodyEditor.textContainerInset = NSSize(width: 0, height: 4)
        scroll.documentView = bodyEditor; surface.addSubview(scroll)
        if let owner { let label = owner.label(placeholder, x: 13, y: 12, width: rect.width - 26, height: rect.height - 24, size: 12, color: Palette.muted, in: surface); label.maximumNumberOfLines = 0; label.lineBreakMode = .byWordWrapping; label.isHidden = !value.isEmpty; bodyPlaceholder = label }
    }
    func styleField(_ field: NSTextField, placeholder: String, rect: NSRect) {
        field.frame = rect; field.placeholderString = placeholder; field.font = .systemFont(ofSize: 13); field.textColor = Palette.text; field.backgroundColor = NSColor.white.withAlphaComponent(0.04)
        field.bezelStyle = .roundedBezel; field.focusRingType = .none; field.delegate = self; addSubview(field)
    }
    func showError(_ message: String) {
        errorLabel?.superview?.removeFromSuperview()
        guard let owner else { return }
        let banner = CardView(frame: NSRect(x: 12, y: kind == .app || kind == .shortcut ? 350 : kind == .web ? 335 : 126, width: bounds.width - 24, height: 40)); banner.radius = 8
        errorLabel = owner.label(message, x: 9, y: 7, width: banner.bounds.width - 18, height: 28, size: 11, color: Palette.error, in: banner); errorLabel?.maximumNumberOfLines = 2
        addSubview(banner)
    }
    func loadChoices() {
        if kind == .app { refreshChoices(); return }
        guard kind == .shortcut else { return }
        loadTask?.cancel(); retryButton?.removeFromSuperview(); choices = []; filteredChoices = []
        choicesView.subviews.forEach { $0.removeFromSuperview() }
        owner?.label("正在读取快捷指令…", x: 0, y: 122, width: choicesView.bounds.width, height: 24, size: 12, color: Palette.muted, alignment: .center, in: choicesView)
        loadTask = Task { [weak self] in
            do {
                let result = try await CommandRunner.run(executable: "/usr/bin/shortcuts", arguments: ["list"], timeout: 15)
                guard !Task.isCancelled, let self else { return }
                guard result.status == 0, !result.timedOut else { throw LauncherError.unavailable("无法读取快捷指令，请稍后重试。") }
                choices = result.output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }.map { LaunchTarget(kind: .shortcut, name: $0, location: $0) }
                refreshChoices()
            } catch {
                guard !Task.isCancelled, let self else { return }
                choicesView.subviews.forEach { $0.removeFromSuperview() }
                owner?.label("暂时无法读取快捷指令", x: 0, y: 112, width: choicesView.bounds.width, height: 24, size: 12, color: Palette.muted, alignment: .center, in: choicesView)
                addRetry()
            }
        }
    }
    func addRetry() {
        retryButton?.removeFromSuperview()
        retryButton = owner?.button("重试", rect: NSRect(x: (choicesView.bounds.width - 96) / 2, y: 155, width: 96, height: 30), border: true, in: choicesView) { [weak self] in self?.loadChoices() }
    }
    func refreshChoices() {
        guard let owner, kind == .app || kind == .shortcut else { return }
        if kind == .app {
            choices = owner.appIndex.map(\.target)
            if let selectedTarget, !choices.contains(where: { $0.id == selectedTarget.id }) { choices.insert(selectedTarget, at: 0) }
        }
        let previousID = filteredChoices.indices.contains(focusedChoice) ? filteredChoices[focusedChoice].id : selectedTarget?.id
        filteredChoices = SearchEngine.search(choices.map { SearchEntry(target: $0) }, query: filter.stringValue).map(\.target)
        focusedChoice = previousID.flatMap { id in filteredChoices.firstIndex { $0.id == id } } ?? 0
        choicesView.subviews.forEach { $0.removeFromSuperview() }
        let width = listScroll.contentSize.width
        choicesView.frame.size = NSSize(width: width, height: max(listScroll.frame.height, CGFloat(filteredChoices.count) * choiceRowHeight))
        if filteredChoices.isEmpty { owner.label(kind == .app && owner.scanning ? "正在发现应用…" : kind == .shortcut && filter.stringValue.isEmpty ? "暂无快捷指令" : "没有匹配的目标", x: 0, y: 123, width: width, height: 24, size: 12, color: Palette.muted, alignment: .center, in: choicesView) }
        for (index, target) in filteredChoices.enumerated() {
            let row = TargetChoiceRow(target: target, selected: index == focusedChoice, showsSubtitle: !filter.stringValue.isEmpty, frame: NSRect(x: 0, y: CGFloat(index) * choiceRowHeight, width: width, height: choiceRowHeight)) { [weak self] in self?.choose(target) }
            choicesView.addSubview(row)
        }
    }
    func choose(_ target: LaunchTarget) {
        if target.id != selectedTarget?.id { aliasField.stringValue = "" }
        selectedTarget = target
        focusedChoice = filteredChoices.firstIndex { $0.id == target.id } ?? 0
        for row in choicesView.subviews.compactMap({ $0 as? TargetChoiceRow }) { row.keyboardSelected = row.launchTarget.id == target.id }
        if kind == .app { save() } else { refreshChoices(); updateSaveAvailability() }
    }
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard confirmation == nil, kind == .app || kind == .shortcut, !filteredChoices.isEmpty,
              let responder = window?.firstResponder else { return false }
        let isFilter = responder === filter || filter.currentEditor() === responder
        let isCandidate = (responder as? TargetChoiceRow).map { $0.isDescendant(of: choicesView) } ?? false
        guard isFilter || isCandidate else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 125 || event.keyCode == 126 {
            focusedChoice = min(filteredChoices.count - 1, max(0, focusedChoice + (event.keyCode == 125 ? 1 : -1)))
            for (index, row) in choicesView.subviews.compactMap({ $0 as? TargetChoiceRow }).enumerated() { row.keyboardSelected = index == focusedChoice }
            choicesView.scrollToVisible(NSRect(x: 0, y: CGFloat(focusedChoice) * choiceRowHeight, width: choicesView.bounds.width, height: choiceRowHeight)); return true
        }
        if event.keyCode == 36 || event.keyCode == 76 { choose(filteredChoices[focusedChoice]); if kind == .shortcut { save() }; return true }
        return false
    }
    func controlTextDidChange(_ notification: Notification) {
        errorLabel?.superview?.removeFromSuperview(); errorLabel = nil
        if notification.object as? NSTextField === filter {
            if kind == .shortcut, filter.stringValue != selectedTarget?.name { selectedTarget = nil }
            focusedChoice = 0; refreshChoices(); choicesView.scroll(.zero)
        }
        updateSaveAvailability()
    }
    func textDidChange(_ notification: Notification) {
        guard !bodyEditor.hasMarkedText() else { return }
        urlField.stringValue = bodyEditor.string; bodyPlaceholder?.isHidden = !bodyEditor.string.isEmpty
        if kind == .web { scheduleWebsiteIcon() }
        updateSaveAvailability()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if kind == .app || kind == .shortcut { if filteredChoices.indices.contains(focusedChoice) { choose(filteredChoices[focusedChoice]) } }
            else { owner?.editorPanel?.makeFirstResponder(bodyEditor) }
            return true
        }
        return false
    }
    func showBrowseMenu() {
        guard let owner, let anchor = headerControls.first else { return }
        let menu = NSMenu()
        menu.addItem(owner.menuItem("扫描文件夹…", symbol: "folder.badge.plus") { [weak self] in self?.scanFolder() })
        menu.addItem(owner.menuItem("选择应用…", symbol: "app") { [weak self] in self?.browse() })
        owner.popMenu(menu, anchor: anchor)
    }
    func browse() {
        guard let owner, !owner.isPreparingToQuit else { return }
        let dialog = NSOpenPanel(); dialog.title = "绑定\(kind.title)"; dialog.prompt = "绑定"; dialog.message = "选择要绑定到 \(sourceKey) 的\(kind.title)。"
        if kind == .shell { dialog.title = "选择 Shell 脚本"; dialog.message = "选择要放到 \(sourceKey) 的 .sh 文件。"; dialog.prompt = "选择" }
        dialog.canChooseFiles = kind != .folder; dialog.canChooseDirectories = kind == .folder; dialog.allowsMultipleSelection = false; dialog.resolvesAliases = true
        if kind == .app { dialog.allowedContentTypes = [.applicationBundle]; dialog.directoryURL = URL(fileURLWithPath: "/Applications") }
        if kind == .shell, let type = UTType(filenameExtension: "sh") { dialog.allowedContentTypes = [type] }
        if let selectedTarget, kind.isFileSystem { dialog.directoryURL = URL(fileURLWithPath: selectedTarget.location).deletingLastPathComponent() }
        owner.pickerActive = true
        dialog.beginSheetModal(for: owner.editorPanel ?? owner.panel) { [weak self, weak owner] response in
            guard let owner else { return }; owner.pickerActive = false
            guard !owner.isPreparingToQuit else { return }
            guard let self else { return }
            guard response == .OK, let url = dialog.url else {
                if [.file, .folder, .shell].contains(self.kind) { owner.closeOverlay() }
                else { owner.editorPanel?.makeKeyAndOrderFront(nil); owner.editorPanel?.makeFirstResponder(self.initialFocus) }
                return
            }
            let target = TargetResolver.target(kind: self.kind, url: url)
            do { try target.validate(); self.selectedTarget = target; self.save() }
            catch { self.ensurePresented(); self.showError(error.localizedDescription) }
        }
    }
    func scanFolder() {
        guard let owner, !owner.isPreparingToQuit else { return }
        let dialog = NSOpenPanel(); dialog.title = "扫描应用文件夹"; dialog.prompt = "扫描"; dialog.canChooseFiles = false; dialog.canChooseDirectories = true; dialog.allowsMultipleSelection = false
        owner.pickerActive = true
        dialog.beginSheetModal(for: owner.editorPanel ?? owner.panel) { [weak self, weak owner] response in
            guard let owner else { return }; owner.pickerActive = false
            guard !owner.isPreparingToQuit else { return }
            guard let self, response == .OK, let root = dialog.url else { owner.editorPanel?.makeKeyAndOrderFront(nil); return }
            var candidate = owner.configuration
            let path = root.resolvingSymlinksInPath().standardizedFileURL.path
            if !candidate.scanDirectories.contains(path) { candidate.scanDirectories.append(path) }
            if owner.save(candidate) { owner.refreshApplications(force: true); owner.editorPanel?.makeKeyAndOrderFront(nil); owner.editorPanel?.makeFirstResponder(self.filter) }
            else { self.showError("扫描目录暂时无法保存，请重试。") }
        }
    }
    func ensurePresented() {
        guard let owner, !owner.isPreparingToQuit, owner.editorPanel == nil else { return }
        let anchor = owner.content.subviews.compactMap { $0 as? KeyTile }.first { $0.key == sourceKey }
        owner.presentBindingCard(self, anchor: anchor ?? owner.content)
    }
    func uploadIcon() {
        guard let owner, !owner.isPreparingToQuit else { return }
        let dialog = NSOpenPanel(); dialog.title = "选择网页图标"; dialog.prompt = "选择"; dialog.canChooseFiles = true; dialog.canChooseDirectories = false; dialog.allowsMultipleSelection = false
        dialog.allowedContentTypes = [.png, .jpeg, .tiff, .icns]
        owner.pickerActive = true
        dialog.beginSheetModal(for: owner.editorPanel ?? owner.panel) { [weak self, weak owner] response in
            guard let owner else { return }; owner.pickerActive = false
            guard !owner.isPreparingToQuit else { return }
            guard let self, response == .OK, let url = dialog.url else { owner.editorPanel?.makeKeyAndOrderFront(nil); return }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= 2 * 1024 * 1024 else { throw LauncherError.invalidTarget("图标文件不得超过 2 MB。") }
                let data = try WebsiteIconService.normalizedIcon(from: Data(contentsOf: url))
                self.iconTask?.cancel(); self.webIconData = data; self.webIconIsCustom = true; self.refreshWebsitePreview()
            } catch { self.showError(error.localizedDescription) }
            owner.editorPanel?.makeKeyAndOrderFront(nil); owner.editorPanel?.makeFirstResponder(self.aliasField)
        }
    }
    func updateSaveAvailability() {
        let enabled: Bool
        switch kind {
        case .web: enabled = (try? WebURLTemplate(urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))) != nil && aliasField.stringValue.count <= 64
        case .shortcut: enabled = selectedTarget != nil || !filter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: enabled = selectedTarget != nil
        }
        saveButton?.isEnabled = enabled
    }
    func scheduleWebsiteIcon() {
        iconTask?.cancel()
        guard !webIconIsCustom else { return }
        let source = urlField.stringValue
        let origin = try? WebURLTemplate(source).originURL.absoluteString
        if origin == fetchedIconOrigin, webIconData != nil { return }
        webIconData = nil; fetchedIconOrigin = nil
        refreshWebsitePreview()
        guard let origin else { return }
        iconTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let data = await WebsiteIconService.fetch(for: source), !Task.isCancelled, let self, !webIconIsCustom,
                  (try? WebURLTemplate(urlField.stringValue).originURL.absoluteString) == origin else { return }
            webIconData = data; fetchedIconOrigin = origin; refreshWebsitePreview()
        }
    }
    func save() {
        guard let owner, !owner.isPreparingToQuit else { return }
        let window = owner.editorPanel ?? owner.panel
        guard (window?.firstResponder as? NSTextView)?.hasMarkedText() != true, window?.processingMarkedKey != true else { return }
        window?.makeFirstResponder(self)
        if kind == .web {
            let address = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            selectedTarget = LaunchTarget(kind: .web, name: URL(string: address)?.host ?? "网页", location: address, iconData: webIconData, iconIsCustom: webIconIsCustom)
        }
        if kind == .shortcut, selectedTarget == nil, !filter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let name = filter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            selectedTarget = LaunchTarget(kind: .shortcut, name: name, location: name)
        }
        guard let selectedTarget else { showError("请选择要绑定的目标。"); return }
        do { try selectedTarget.validate(); guard aliasField.stringValue.count <= 64 else { throw LauncherError.invalidTarget("显示名称最多 64 个字符。") } }
        catch { showError(error.localizedDescription); return }
        if kind.isFileSystem, TargetResolver.url(for: selectedTarget) == nil { showError("目标不可访问，请重新选择。"); return }
        let binding = KeyBinding(target: selectedTarget, alias: aliasField.stringValue)
        let dest = destination.titleOfSelectedItem ?? sourceKey
        let duplicate = binding.target.kind == .app ? owner.bindings.first { $0.key != sourceKey && $0.key != dest && $0.value.target.id == binding.target.id }?.key : nil
        var changes: [String] = []
        if let occupied = owner.bindings[dest], dest != sourceKey || occupied.target.id != binding.target.id { changes.append("\(dest) 已绑定「\(occupied.title)」，继续将替换它。") }
        if let duplicate { changes.append("这个应用已绑定在 \(duplicate)，继续将移到 \(dest)。") }
        if !changes.isEmpty {
            ensurePresented()
            confirm("更新 \(dest) 的绑定", detail: changes.joined(separator: "\n"), primary: "确认替换") { [weak self] in guard let self else { return }; _ = self.owner?.commitBinding(binding, source: self.sourceKey, destination: dest, duplicate: duplicate) }
            return
        }
        if !owner.commitBinding(binding, source: sourceKey, destination: dest) { ensurePresented(); showError("保存失败，当前修改已保留。") }
    }
    func confirm(_ title: String, detail: String, primary: String, action: @escaping () -> Void) {
        guard let owner else { return }
        confirmation?.removeFromSuperview()
        let compact = [.file, .folder, .shell].contains(kind)
        let shade = ShadeView(frame: bounds); let width = compact ? bounds.width : min(bounds.width - 24, 406)
        let card = CardView(frame: NSRect(x: compact ? 0 : 12, y: compact ? 0 : max(56, (bounds.height - 202) / 2), width: width, height: compact ? bounds.height : 202)); card.radius = compact ? 20 : 13; shade.addSubview(card)
        owner.label(title, x: 18, y: 18, width: width - 36, height: 24, size: 14, in: card)
        let text = owner.label(detail, x: 18, y: 55, width: width - 36, height: 75, size: 12, color: Palette.secondary, in: card); text.maximumNumberOfLines = 4; text.lineBreakMode = .byWordWrapping
        let buttonWidth = (width - 46) / 2
        let back = owner.button("返回", rect: NSRect(x: 18, y: 151, width: buttonWidth, height: 32), border: true, in: card) { [weak self, weak shade] in shade?.removeFromSuperview(); self?.confirmation = nil; self?.owner?.editorPanel?.makeFirstResponder(self?.initialFocus) }
        owner.button(primary, rect: NSRect(x: 28 + buttonWidth, y: 151, width: buttonWidth, height: 32), primary: true, in: card, action: action)
        addSubview(shade); confirmation = shade; owner.editorPanel?.makeFirstResponder(back)
    }
}

final class EditorSymbolView: FlippedView {
    let symbol: String
    init(symbol: String, frame: NSRect) { self.symbol = symbol; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { drawSymbol(symbol, in: bounds, color: Palette.text) }
}

final class TargetChoiceRow: ClickableButton {
    let launchTarget: LaunchTarget
    var keyboardSelected: Bool { didSet { needsDisplay = true } }
    let showsSubtitle: Bool
    let selectedAction: () -> Void
    var hovered = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    init(target: LaunchTarget, selected: Bool, showsSubtitle: Bool = false, frame: NSRect, action: @escaping () -> Void) {
        launchTarget = target; keyboardSelected = selected; self.showsSubtitle = showsSubtitle; selectedAction = action
        super.init(frame: frame); isBordered = false; title = ""; self.target = self; self.action = #selector(invoke); focusRingType = .none
        setAccessibilityLabel(target.name); toolTip = target.location
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func invoke() { selectedAction() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self); addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ rect: NSRect) {
        if hovered || isHighlighted || keyboardSelected {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 7, yRadius: 7)
            NSColor.white.withAlphaComponent(isHighlighted ? 0.13 : hovered ? 0.07 : 0.035).setFill(); path.fill()
        }
        let isShortcut = launchTarget.kind == .shortcut
        if isShortcut { drawSymbol("sparkles", in: NSRect(x: 10, y: 10, width: 20, height: 20), color: Palette.secondary) }
        else { drawTarget(launchTarget, in: NSRect(x: 10, y: 10, width: 24, height: 24)) }
        let english = launchTarget.kind == .app ? URL(fileURLWithPath: launchTarget.location).deletingPathExtension().lastPathComponent : ""
        let subtitle = showsSubtitle && !english.isEmpty && english.localizedCaseInsensitiveCompare(launchTarget.name) != .orderedSame
        let textX: CGFloat = isShortcut ? 40 : 46
        drawText(launchTarget.name, in: NSRect(x: textX, y: subtitle ? 4 : isShortcut ? 12 : 13, width: bounds.width - textX - 12, height: 20), size: 13, weight: .semibold)
        if subtitle { drawText(english, in: NSRect(x: textX, y: 23, width: bounds.width - textX - 12, height: 15), size: 11, color: Palette.muted) }
    }
}

extension LauncherController {
    func requestWebVariables(for target: LaunchTarget, completion: @escaping (URL?) -> Void) {
        guard !isPreparingToQuit else { completion(nil); return }
        closeOverlay(render: false)
        do {
            let form = try WebVariableForm(owner: self, target: target, completion: completion)
            presentBindingCard(form, anchor: content)
            editorPanel?.makeFirstResponder(form.fields.first)
        } catch { toast(error.localizedDescription, persistent: true); completion(nil) }
    }
}

final class WebVariableForm: CardView, NSTextFieldDelegate {
    weak var owner: LauncherController?
    let template: WebURLTemplate
    let completion: (URL?) -> Void
    var fields: [NSTextField] = []
    var tabFocusViews: [NSView] = []
    private var completed = false
    private var errorLabel: NSTextField?
    init(owner: LauncherController, target: LaunchTarget, completion: @escaping (URL?) -> Void) throws {
        self.owner = owner; self.template = try WebURLTemplate(target.location); self.completion = completion
        let contentHeight = min(310, CGFloat(template.variables.count) * 62)
        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: contentHeight + 128))
        radius = 20
        let icon = EditorSymbolView(symbol: "globe", frame: NSRect(x: 13, y: 20, width: 18, height: 18)); addSubview(icon)
        owner.label("填写网址变量", x: 39, y: 18, width: 235, height: 22, size: 14, in: self).font = .systemFont(ofSize: 14, weight: .semibold)
        let close = owner.button("", symbol: "xmark", rect: NSRect(x: 290, y: 15, width: 28, height: 28), in: self) { [weak owner] in owner?.closeOverlay() }
        close.setAccessibilityLabel("取消填写变量")
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 56, width: 306, height: contentHeight)); scroll.drawsBackground = false; scroll.hasVerticalScroller = template.variables.count > 5; scroll.autohidesScrollers = true; scroll.scrollerStyle = .legacy; scroll.verticalScroller = LauncherScroller()
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 306, height: CGFloat(template.variables.count) * 62)); scroll.documentView = document; addSubview(scroll)
        for (index, name) in template.variables.enumerated() {
            let y = CGFloat(index) * 62
            owner.label(name, x: 0, y: y, width: 294, height: 18, size: 11, color: Palette.secondary, in: document)
            let field = NSTextField(frame: NSRect(x: 0, y: y + 23, width: 294, height: 30)); field.placeholderString = "填写 \(name)"; field.font = .systemFont(ofSize: 13); field.textColor = Palette.text; field.backgroundColor = NSColor.white.withAlphaComponent(0.04); field.focusRingType = .none; field.bezelStyle = .roundedBezel; field.delegate = self; field.setAccessibilityLabel(name); document.addSubview(field); fields.append(field)
        }
        errorLabel = owner.label("", x: 12, y: contentHeight + 60, width: 306, height: 16, size: 11, color: Palette.error, in: self)
        let cancel = owner.button("取消", rect: NSRect(x: 12, y: contentHeight + 84, width: 148, height: 32), border: true, in: self) { [weak owner] in owner?.closeOverlay() }
        let open = owner.button("打开", rect: NSRect(x: 170, y: contentHeight + 84, width: 148, height: 32), primary: true, in: self) { [weak self] in self?.submit() }
        tabFocusViews = [close] + fields + [cancel, open]
    }
    required init?(coder: NSCoder) { fatalError() }
    func cancelPending() { guard !completed else { return }; completed = true; completion(nil) }
    func submit() {
        guard !completed, (window?.firstResponder as? NSTextView)?.hasMarkedText() != true, (window as? LauncherPanel)?.processingMarkedKey != true else { return }
        let values = Dictionary(uniqueKeysWithValues: zip(template.variables, fields.map(\.stringValue)))
        do {
            let url = try template.resolvedURL(values: values)
            completed = true; owner?.closeOverlay(); completion(url)
        } catch { errorLabel?.stringValue = error.localizedDescription }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if !textView.hasMarkedText(), selector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        return false
    }
}

extension LauncherController {
    func showBindingHotKey(_ key: String) {
        guard !isPreparingToQuit else { return }
        guard bindings[key] != nil else { return }
        closeOverlay(render: false)
        let form = BindingHotKeyForm(owner: self, key: key)
        presentBindingCard(form, anchor: content, centered: true)
        editorPanel?.makeFirstResponder(form.recorder)
    }
}

final class BindingHotKeyForm: CardView {
    weak var owner: LauncherController?
    let key: String
    var value: BindingHotKey?
    private let originalValue: BindingHotKey?
    var hasChanges: Bool { value != originalValue }
    private var confirmation: FlippedView?
    private var normalFocusViews: [NSView] = []
    let recorder = HotKeyRecorder(frame: NSRect(x: 12, y: 62, width: 306, height: 46))
    var tabFocusViews: [NSView] { confirmation?.subviews.first?.subviews.filter { $0 is ActionButton } ?? normalFocusViews }
    private var errorLabel: NSTextField?
    init(owner: LauncherController, key: String) {
        self.owner = owner; self.key = key; value = owner.configuration.bindingHotKeys[key]; originalValue = owner.configuration.bindingHotKeys[key]
        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: 198)); radius = 20
        let icon = EditorSymbolView(symbol: "keyboard", frame: NSRect(x: 13, y: 20, width: 18, height: 18)); addSubview(icon)
        owner.label("设置快捷键", x: 39, y: 18, width: 235, height: 22, size: 14, in: self).font = .systemFont(ofSize: 14, weight: .semibold)
        let close = owner.button("", symbol: "xmark", rect: NSRect(x: 290, y: 15, width: 28, height: 28), in: self) { [weak owner] in owner?.requestCloseEditor() }; close.setAccessibilityLabel("关闭快捷键设置")
        recorder.value = value?.title; recorder.recording = value == nil; recorder.setAccessibilityLabel("录制快捷键"); addSubview(recorder)
        errorLabel = owner.label("包含 ⌃、⌥ 或 ⌘，按 Esc 取消录制", x: 12, y: 118, width: 306, height: 18, size: 11, color: Palette.muted, in: self)
        let clear = owner.button("清除", rect: NSRect(x: 12, y: 154, width: 72, height: 32), border: true, in: self) { [weak self] in self?.value = nil; self?.recorder.value = nil; self?.recorder.recording = false }
        let cancel = owner.button("取消", rect: NSRect(x: 132, y: 154, width: 86, height: 32), border: true, in: self) { [weak owner] in owner?.requestCloseEditor() }
        let save = owner.button("保存", rect: NSRect(x: 228, y: 154, width: 90, height: 32), primary: true, in: self) { [weak self] in _ = self?.save() }
        normalFocusViews = [close, recorder, clear, cancel, save]
    }
    required init?(coder: NSCoder) { fatalError() }
    @discardableResult func save() -> Bool {
        guard let owner, !owner.isPreparingToQuit else { return false }
        guard owner.setBindingHotKey(value, for: key) else {
            errorLabel?.stringValue = "快捷键被占用或无法保存，请重新设置。"; errorLabel?.textColor = Palette.error
            window?.makeKeyAndOrderFront(nil); return false
        }
        owner.closeOverlay(); return true
    }
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        if let confirmation {
            if event.keyCode == 53 { confirmation.removeFromSuperview(); self.confirmation = nil; window?.makeFirstResponder(recorder); return true }
            return false
        }
        guard recorder.recording else { return false }
        if event.keyCode == 53 { recorder.recording = false; return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, flags.intersection([.control, .option, .command]).isEmpty { recorder.recording = false; return false }
        let candidate = BindingHotKey(keyCode: event.keyCode, control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift), command: flags.contains(.command))
        acceptRecordedHotKey(candidate)
        return true
    }
    func confirmDiscard() {
        guard confirmation == nil, let owner else { return }
        let shade = ShadeView(frame: bounds)
        let card = CardView(frame: NSRect(x: 12, y: 12, width: 306, height: 174)); card.radius = 12; shade.addSubview(card)
        owner.label("放弃当前修改？", x: 16, y: 17, width: 274, height: 23, size: 14, in: card)
        owner.label("尚未保存的快捷键将被放弃。", x: 16, y: 58, width: 274, height: 34, size: 12, color: Palette.secondary, in: card)
        let back = owner.button("返回", rect: NSRect(x: 16, y: 126, width: 132, height: 32), border: true, in: card) { [weak self, weak shade] in shade?.removeFromSuperview(); self?.confirmation = nil; self?.window?.makeFirstResponder(self?.recorder) }
        owner.button("放弃修改", rect: NSRect(x: 158, y: 126, width: 132, height: 32), primary: true, in: card) { [weak owner] in owner?.closeOverlay() }
        addSubview(shade); confirmation = shade; window?.makeFirstResponder(back)
    }
    func acceptRecordedHotKey(_ candidate: BindingHotKey) {
        guard owner?.isPreparingToQuit == false else { return }
        do { try candidate.validate(); value = candidate; recorder.value = candidate.title; recorder.recording = false; errorLabel?.stringValue = "在任意应用中直接打开这个绑定"; errorLabel?.textColor = Palette.muted }
        catch { errorLabel?.stringValue = error.localizedDescription; errorLabel?.textColor = Palette.error }
    }
}

final class HotKeyRecorder: NSControl {
    var value: String? { didSet { needsDisplay = true } }
    var recording = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); focusRingType = .none }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { recording = true; window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) { if event.keyCode == 49 || event.keyCode == 36 { recording = true } else { super.keyDown(with: event) } }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor.white.withAlphaComponent(Palette.isLight ? 0.5 : 0.045).setFill(); path.fill(); Palette.secondary.withAlphaComponent(recording ? 0.45 : 0.18).setStroke(); path.stroke()
        drawText(recording ? "请按下快捷键…" : value ?? "点击录制快捷键", in: NSRect(x: 12, y: 13, width: bounds.width - 24, height: 22), size: 14, color: recording ? Palette.text : Palette.secondary, alignment: .center)
    }
}
