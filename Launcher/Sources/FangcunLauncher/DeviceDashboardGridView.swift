import AppKit
import SwiftUI
import LauncherCore

struct DeviceDashboardRepresentable: NSViewRepresentable {
    @ObservedObject var model: DeviceStatusModel
    var editing: Bool
    var scale: CGFloat = 1
    var expanded = false
    var minimumHeight: CGFloat = 0
    var open: (DeviceCardID) -> Void
    var heightChanged: (CGFloat) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.workbenchOpacity) private var opacity
    @Environment(\.workbenchTheme) private var theme
    func makeNSView(context: Context) -> DeviceDashboardNSView { DeviceDashboardNSView() }
    func updateNSView(_ view: DeviceDashboardNSView, context: Context) {
        view.configure(model: model, editing: editing, light: scheme == .light, opacity: opacity, theme: theme, scale: scale, minimumHeight: minimumHeight, expanded: expanded, open: open, heightChanged: heightChanged)
    }
    static func dismantleNSView(_ view: DeviceDashboardNSView, coordinator: ()) { view.rememberScroll(); view.cancelInteraction(); view.detachObservers() }
}

@MainActor final class DeviceDashboardNSView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    private(set) var cards: [DeviceCardID: DeviceDashboardTile] = [:]
    private(set) var layoutValue = DeviceDashboardLayout()
    private weak var model: DeviceStatusModel?
    private var editing = false, light = false, expanded = false
    private var opacity = 0.70
    private var theme: LauncherTheme = .arWorld
    private var scale: CGFloat = 1
    private var minimumHeight: CGFloat = 0
    private var open: ((DeviceCardID) -> Void)?
    private var heightChanged: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = 0
    private var lastHeight: CGFloat = 0
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?
    private var scrollTimer: Timer?
    private var popover: NSPopover?
    private var restoredScroll = false
    private struct Interaction {
        let id: DeviceCardID
        let edge: DeviceResizeEdge?
        let original: DeviceDashboardLayout
        let origin: CGRect
        let start: CGPoint
        let startWindow: CGPoint
        let metrics: DeviceDashboardGrid.Metrics
        var started = false
        var lastReorder: CGPoint?
    }
    private var interaction: Interaction?
    private var ghost: DeviceDashboardTile?
    var isInteracting: Bool { interaction?.started == true }

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = false; setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError() }
    func configure(model: DeviceStatusModel, editing: Bool, light: Bool, opacity: Double = 0.70, theme: LauncherTheme = .arWorld, scale: CGFloat = 1, minimumHeight: CGFloat = 0, expanded: Bool = false, open: @escaping (DeviceCardID) -> Void, heightChanged: @escaping (CGFloat) -> Void) {
        self.model = model; self.open = open; self.heightChanged = heightChanged
        let scale: CGFloat = 1 // Typography stays readable; expanded view allocates useful chart space.
        let minimumHeight = minimumHeight.isFinite ? max(0, minimumHeight) : 0
        if self.editing != editing || self.light != light || self.expanded != expanded || abs(self.scale - scale) > 0.001 || abs(self.minimumHeight - minimumHeight) > 0.5 { cancelInteraction(); popover?.close() }
        self.editing = editing; self.light = light; self.opacity = opacity; self.theme = theme; self.expanded = expanded
        self.scale = scale; self.minimumHeight = minimumHeight
        if interaction == nil { layoutValue = model.dashboardLayout }
        reconcile(animated: false)
    }
    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 0.5 {
            cancelInteraction(); lastWidth = bounds.width; reconcile(animated: false)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); detachObservers()
        guard let window else { cancelInteraction(); return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willStartLiveResizeNotification, NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancelInteraction() } })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancelInteraction() } })
        DispatchQueue.main.async { [weak self] in self?.restoreScroll() }
    }
    func detachObservers() { for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = [] }
    func rememberScroll() { if let scroll = enclosingScrollView { model?.dashboardScrollOffset = scroll.contentView.bounds.origin.y } }
    private func restoreScroll() {
        guard !restoredScroll, let scroll = enclosingScrollView, let model else { return }
        restoredScroll = true
        let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(maxY, model.dashboardScrollOffset))); scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func reconcile(animated: Bool) {
        guard let model, bounds.width > 0 else { return }
        let placements = gridPlacements(layoutValue)
        let visible = Set(placements.map(\.id))
        for (id, card) in cards where !visible.contains(id) { card.removeFromSuperview(); cards.removeValue(forKey: id) }
        for placement in placements {
            guard let preference = layoutValue.cards.first(where: { $0.id == placement.id }) else { continue }
            let tile: DeviceDashboardTile
            if let old = cards[placement.id] { tile = old }
            else { tile = DeviceDashboardTile(id: placement.id); tile.grid = self; cards[placement.id] = tile; addSubview(tile); tile.frame = placement.frame }
            tile.update(preference: preference, snapshot: model.snapshot, history: model.history, trafficSummary: model.trafficSummary(period: .day, scope: .all), budget: model.budget, editing: editing, light: light, expanded: expanded, scale: scale, theme: theme, opacity: opacity)
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in context.duration = 0.18; context.timingFunction = CAMediaTimingFunction(name: .easeOut); tile.animator().frame = placement.frame }
            } else { tile.frame = placement.frame }
            tile.alphaValue = interaction?.started == true && interaction?.id == placement.id ? 0.18 : 1
        }
        if let ghost, let gesture = interaction, let preference = layoutValue.cards.first(where: { $0.id == gesture.id }) {
            ghost.update(preference: preference, snapshot: model.snapshot, history: model.history, trafficSummary: model.trafficSummary(period: .day, scope: .all), budget: model.budget, editing: editing, light: light, expanded: expanded, scale: scale, theme: theme, opacity: opacity)
        }
        let height = max(interaction.flatMap { gridPlacements($0.original).map(\.frame.maxY).max() } ?? 0, placements.map(\.frame.maxY).max() ?? 180 * scale)
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.heightChanged?(self.lastHeight) }
        }
        window?.invalidateCursorRects(for: self)
    }
    private var gridMetrics: DeviceDashboardGrid.Metrics {
        interaction?.metrics ?? DeviceDashboardGrid.metrics(layoutValue, width: bounds.width, scale: scale, minimumHeight: minimumHeight, expanded: expanded)
    }
    private func gridPlacements(_ layout: DeviceDashboardLayout) -> [DeviceCardPlacement] {
        DeviceDashboardGrid.placements(layout, width: bounds.width, metrics: gridMetrics)
    }
    func begin(id: DeviceCardID, event: NSEvent, edge: DeviceResizeEdge?) {
        guard editing, interaction == nil, let card = cards[id] else { return }
        popover?.close(); window?.makeFirstResponder(card)
        interaction = Interaction(id: id, edge: editing ? edge : nil, original: layoutValue, origin: card.frame, start: convert(event.locationInWindow, from: nil), startWindow: event.locationInWindow, metrics: gridMetrics)
    }
    func move(event: NSEvent) { move(to: convert(event.locationInWindow, from: nil)) }
    private func move(to point: CGPoint) {
        guard var gesture = interaction, let model else { return }
        let dx = point.x - gesture.start.x, dy = point.y - gesture.start.y
        if !gesture.started {
            guard hypot(dx,dy) > 4 * scale else { return }
            gesture.started = true; interaction = gesture
            let preview = DeviceDashboardTile(id: gesture.id); preview.isGhost = true
            if let pref = layoutValue.cards.first(where: { $0.id == gesture.id }) { preview.update(preference: pref, snapshot: model.snapshot, history: model.history, trafficSummary: model.trafficSummary(period: .day, scope: .all), budget: model.budget, editing: editing, light: light, expanded: expanded, scale: scale, theme: theme, opacity: opacity) }
            preview.frame = gesture.origin; preview.wantsLayer = true
            preview.layer?.shadowColor = NSColor.black.cgColor; preview.layer?.shadowOpacity = 0.35; preview.layer?.shadowRadius = 15; preview.layer?.shadowOffset = CGSize(width: 0, height: -7)
            ghost = preview; addSubview(preview, positioned: .above, relativeTo: nil)
            cards[gesture.id]?.alphaValue = 0.18
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                if event.keyCode == 53 { MainActor.assumeIsolated { self?.cancelInteraction() }; return nil }
                return event
            }
            scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.autoScroll() } }
        }
        if let edge = gesture.edge {
            let metrics = gesture.metrics, step = metrics.columnStep, gap = metrics.gap
            let minimumColumns = DeviceDashboardGrid.renderedColumns(gesture.id.minimumColumns, width: bounds.width, scale: scale)
            let minimumHeight = min(gesture.origin.height, CGFloat(gesture.id.minimumRows) * metrics.rowStep - gap)
            let rect = edge.preview(origin: gesture.origin, delta: CGSize(width: dx, height: dy), minimum: CGSize(width: CGFloat(minimumColumns) * step - gap, height: minimumHeight), maximum: CGSize(width: bounds.width, height: CGFloat(gesture.id.maximumRows) * metrics.rowStep - gap))
            ghost?.frame = rect
            let original = gesture.original.cards.first { $0.id == gesture.id }!
            let horizontal = edge.horizontal && (!edge.vertical || abs(dx) > abs(dy))
            let movement = horizontal ? dx * (edge.rawValue.contains("w") ? -1 : 1) : dy * (edge.rawValue.contains("n") ? -1 : 1)
            let choice = abs(movement) > 34 ? gesture.id.resized(from: original, horizontal: horizontal, growing: movement > 0) : nil
            var next = layoutValue
            next.update(gesture.id) { $0.columns = choice?.columns ?? original.columns; $0.rows = choice?.rows ?? original.rows }
            if next != layoutValue { layoutValue = next; reconcile(animated: true) }
        } else {
            ghost?.frame = gesture.origin.offsetBy(dx: dx, dy: dy)
            let candidates = gridPlacements(layoutValue).filter { $0.id != gesture.id }
            if let target = candidates.first(where: { $0.frame.insetBy(dx: 5 * scale, dy: 5 * scale).contains(point) }),
               gesture.lastReorder.map({ hypot(point.x - $0.x, point.y - $0.y) > 18 * scale }) ?? true {
                let sourceFrame = cards[gesture.id]?.frame ?? gesture.origin
                let sameRow = abs(target.frame.midY - sourceFrame.midY) < min(target.frame.height, sourceFrame.height) * 0.6
                let after = sameRow ? point.x > target.frame.midX : point.y > target.frame.midY
                var next = layoutValue; next.move(gesture.id, before: target.id, after: after)
                if next != layoutValue {
                    gesture.lastReorder = point; interaction = gesture
                    layoutValue = next; reconcile(animated: true)
                }
            }
        }
    }
    private func autoScroll() {
        guard interaction?.started == true, let window, let scroll = enclosingScrollView else { return }
        let point = scroll.contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let clip = scroll.contentView.bounds
        let speed: CGFloat = point.y < clip.minY + 25 ? -10 : point.y > clip.maxY - 25 ? 10 : 0
        guard speed != 0 else { return }
        let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - clip.height)
        let nextY = min(maxY, max(0, clip.minY + speed))
        if nextY != clip.minY {
            scroll.contentView.scroll(to: CGPoint(x: clip.minX, y: nextY)); scroll.reflectScrolledClipView(scroll.contentView)
            move(to: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }
    func end(event: NSEvent) {
        guard let gesture = interaction else { return }
        if gesture.started { move(event: event) }
        let next = layoutValue
        cleanupInteraction()
        if gesture.started { model?.saveLayout(next) }
        layoutValue = model?.dashboardLayout ?? gesture.original
        reconcile(animated: true)
    }
    func cancelInteraction() {
        guard let gesture = interaction else { return }
        layoutValue = gesture.original; cleanupInteraction(); reconcile(animated: true)
    }
    private func cleanupInteraction() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        scrollTimer?.invalidate(); scrollTimer = nil
        ghost?.removeFromSuperview(); ghost = nil; interaction = nil
        for card in cards.values { card.alphaValue = 1 }
    }
    func activate(_ id: DeviceCardID) {
        guard interaction == nil else { return }
        if editing { model?.changeCard(id) { $0.visible = false } }
        else { rememberScroll(); open?(id) }
    }
    func style(_ id: DeviceCardID, anchor: NSView) {
        guard editing, let model else { return }
        let popover = NSPopover(); popover.behavior = .transient
        let content = DeviceMeterPopover(model: model, id: id)
        popover.contentViewController = NSHostingController(rootView: content.environment(\.workbenchOpacity,opacity).environment(\.workbenchTheme,theme).preferredColorScheme(light ? .light : .dark))
        popover.contentSize = CGSize(width: 220, height: 112)
        self.popover = popover; popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    func keyboardMove(_ id: DeviceCardID, forward: Bool) {
        guard editing else { return }
        let visible = layoutValue.cards.filter(\.visible).map(\.id)
        guard let index = visible.firstIndex(of: id), visible.indices.contains(index + (forward ? 1 : -1)) else { return }
        var next = layoutValue; next.move(id, before: visible[index + (forward ? 1 : -1)], after: forward); model?.saveLayout(next)
    }
    func keyboardResize(_ id: DeviceCardID, horizontal: Bool, growing: Bool) {
        guard editing, let current = layoutValue.cards.first(where: { $0.id == id }),
              let size = id.resized(from: current, horizontal: horizontal, growing: growing) else { return }
        model?.changeCard(id) { $0.columns = size.columns; $0.rows = size.rows }
    }
}

@MainActor final class DeviceDashboardTile: NSView {
    let id: DeviceCardID
    weak var grid: DeviceDashboardNSView?
    var isGhost = false
    private var editing = false
    private var scale: CGFloat = 1
    private var host: NSHostingView<AnyView>?
    private var hover = false
    private var area: NSTrackingArea?
    private let actionButton = NSButton(), styleButton = NSButton()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isGhost }
    override var mouseDownCanMoveWindow: Bool { false }
    init(id: DeviceCardID) {
        self.id = id; super.init(frame: .zero); wantsLayer = true
        for button in [actionButton, styleButton] {
            button.isBordered = false; button.imagePosition = .imageOnly
            button.bezelStyle = .inline; button.target = self; addSubview(button)
        }
        actionButton.action = #selector(activate); styleButton.action = #selector(style)
        setAccessibilityElement(false); setAccessibilityLabel(id.title + "卡片"); setAccessibilityIdentifier("fc.device.card.\(id.rawValue)")
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(preference: DeviceCardPreference, snapshot: DeviceSnapshot, history: [DeviceHistoryPoint], trafficSummary: DeviceTrafficSummary, budget: DeviceTrafficBudget, editing: Bool, light: Bool, expanded: Bool = false, scale: CGFloat = 1, theme: LauncherTheme = .arWorld, opacity: Double = 0.70) {
        self.editing = editing; self.scale = scale
        let content = AnyView(DeviceCardContent(card: preference, snapshot: snapshot, history: history, editing: editing, trafficSummary: trafficSummary, budget: budget, expanded: expanded)
            .environment(\.workbenchTheme, theme).environment(\.workbenchOpacity, opacity).preferredColorScheme(light ? .light : .dark))
        if let host { host.rootView = content }
        else {
            let host = NSHostingView(rootView: content); host.sizingOptions = []; self.host = host
            addSubview(host, positioned: .below, relativeTo: actionButton)
        }
        appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        actionButton.image = NSImage(systemSymbolName: editing ? "xmark" : "arrow.up.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12 * scale, weight: .regular))
        actionButton.contentTintColor = ThemePalette(theme: theme, opacity: opacity, light: light).nsSecondary
        actionButton.setAccessibilityLabel((editing ? "隐藏" : "打开") + id.title)
        actionButton.setAccessibilityIdentifier("fc.device.card.\(id.rawValue).\(editing ? "hide" : "open")")
        actionButton.toolTip = (editing ? "隐藏" : "打开") + id.title
        styleButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12 * scale, weight: .regular))
        styleButton.contentTintColor = ThemePalette(theme: theme, opacity: opacity, light: light).nsSecondary
        styleButton.isHidden = !editing || !id.supportsMeterStyle || isGhost
        styleButton.setAccessibilityLabel(id.title + "显示设置"); styleButton.toolTip = "进度显示设置"
        updateActionVisibility()
        needsLayout = true; window?.invalidateCursorRects(for: self)
    }
    override func layout() {
        super.layout(); host?.frame = bounds
        actionButton.frame = NSRect(x: bounds.width - 39 * scale, y: 12 * scale, width: 26 * scale, height: 26 * scale)
        styleButton.frame = NSRect(x: bounds.width - 65 * scale, y: 12 * scale, width: 24 * scale, height: 24 * scale)
    }
    private func edge(at point: CGPoint) -> DeviceResizeEdge? {
        guard editing else { return nil }
        let margin = 7 * scale
        let n = point.y < margin, s = point.y > bounds.height - margin, w = point.x < margin, e = point.x > bounds.width - margin
        let value = (n ? "n" : s ? "s" : "") + (w ? "w" : e ? "e" : "")
        return DeviceResizeEdge(rawValue: value)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isGhost, let parent = superview else { return nil }
        let local = convert(point, from: parent)
        guard bounds.contains(local) else { return nil }
        if edge(at: local) != nil { return self }
        for button in [actionButton, styleButton] where !button.isHidden && button.frame.contains(local) { return button }
        return editing ? self : super.hitTest(point)
    }
    override func resetCursorRects() {
        let edge = 7 * scale, corner = 8 * scale
        guard editing else { addCursorRect(bounds, cursor: .arrow); return }
        addCursorRect(bounds.insetBy(dx: edge, dy: edge), cursor: .openHand)
        addCursorRect(NSRect(x: corner, y: 0, width: max(0,bounds.width - 2 * corner), height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: corner, y: bounds.height - edge, width: max(0,bounds.width - 2 * corner), height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: corner, width: edge, height: max(0,bounds.height - 2 * corner)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - edge, y: corner, width: edge, height: max(0,bounds.height - 2 * corner)), cursor: .resizeLeftRight)
        let nwse = Self.diagonalCursor("arrow.up.left.and.arrow.down.right")
        let nesw = Self.diagonalCursor("arrow.up.right.and.arrow.down.left")
        addCursorRect(NSRect(x:0,y:0,width:corner,height:corner), cursor:nwse)
        addCursorRect(NSRect(x:bounds.width-corner,y:bounds.height-corner,width:corner,height:corner), cursor:nwse)
        addCursorRect(NSRect(x:bounds.width-corner,y:0,width:corner,height:corner), cursor:nesw)
        addCursorRect(NSRect(x:0,y:bounds.height-corner,width:corner,height:corner), cursor:nesw)
    }
    private static func diagonalCursor(_ name: String) -> NSCursor {
        guard let image = NSImage(systemSymbolName:name,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:15,weight:.medium)) else {return .crosshair}
        return NSCursor(image:image,hotSpot:CGPoint(x:image.size.width/2,y:image.size.height/2))
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); guard editing else { return }; grid?.begin(id: id, event: event, edge: edge(at: convert(event.locationInWindow, from: nil))) }
    override func mouseDragged(with event: NSEvent) { grid?.move(event: event) }
    override func mouseUp(with event: NSEvent) { grid?.end(event: event) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { grid?.cancelInteraction(); return }
        if editing && event.modifierFlags.contains(.option), [123,124,125,126].contains(event.keyCode) {
            if event.modifierFlags.contains(.shift) { grid?.keyboardResize(id, horizontal: event.keyCode == 123 || event.keyCode == 124, growing: event.keyCode == 124 || event.keyCode == 125) }
            else { grid?.keyboardMove(id, forward: event.keyCode == 124 || event.keyCode == 125) }; return
        }
        if event.keyCode == 36 && !editing { grid?.activate(id); return }; super.keyDown(with: event)
    }
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hover = true; updateActionVisibility() }
    override func mouseExited(with event: NSEvent) { hover = false; updateActionVisibility() }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); updateActionVisibility(); return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); DispatchQueue.main.async { [weak self] in self?.updateActionVisibility() }; return result }
    private func updateActionVisibility() {
        let focused = window?.firstResponder === self || window?.firstResponder === actionButton
        actionButton.isHidden = isGhost || !(editing || hover || focused)
    }
    @objc private func activate() { grid?.activate(id) }
    @objc private func style() { grid?.style(id, anchor: styleButton) }
}
struct DeviceMeterPopover: View {
    @ObservedObject var model: DeviceStatusModel
    let id: DeviceCardID
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(id.title) · 显示设置").font(.system(size: 12, weight: .medium))
            Picker("进度展示", selection: Binding(get: { model.dashboardLayout.cards.first { $0.id == id }?.meter ?? .bar }, set: { value in model.changeCard(id) { $0.meter = value } })) {
                Text("长条").tag(DeviceMeterStyle.bar); Text("圆环").tag(DeviceMeterStyle.ring)
            }.pickerStyle(.segmented)
        }.padding(14).frame(width: 220).workbenchSheetSurface()
    }
}
