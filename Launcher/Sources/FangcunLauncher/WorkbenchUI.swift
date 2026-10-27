import AppKit
import LauncherCore
import SwiftUI

/// Viewport adaptation is presentation-only; saved card sizes remain in the base grid.
private struct WorkbenchScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
private struct WorkbenchContentHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct WorkbenchDeviceExpandedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var workbenchScale: CGFloat {
        get { self[WorkbenchScaleKey.self] }
        set { self[WorkbenchScaleKey.self] = newValue }
    }
    var workbenchContentHeight: CGFloat {
        get { self[WorkbenchContentHeightKey.self] }
        set { self[WorkbenchContentHeightKey.self] = newValue }
    }
    var workbenchDeviceExpanded: Bool {
        get { self[WorkbenchDeviceExpandedKey.self] }
        set { self[WorkbenchDeviceExpandedKey.self] = newValue }
    }
}
enum WorkbenchViewport {
    static func scale(for size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite else { return 1 }
        return min(1.3, max(1, min(size.width / 1120, size.height / 758)))
    }
    static let windowRadius: CGFloat = 12
}

/// Compatibility tokens for existing content. New reusable components obtain
/// their theme from the environment instead of sharing mutable global state.
enum WorkbenchStyle {
    static let text = ThemePalette().text
    static let secondary = ThemePalette().secondary
    static let muted = ThemePalette().muted
    static let accent = ThemePalette().accent
    static let warning = ThemePalette().warning
    static let critical = ThemePalette().critical
    static let cardRadius: CGFloat = 15
}

/// Native popup semantics with our shared 32-point trigger. SwiftUI Menu can replace
/// its custom label on macOS, so the visible surface is drawn by WBPopUpButton.
struct WBSelect<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchTheme) private var theme
    @Environment(\.workbenchOpacity) private var opacity
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, selection: Binding<Value>, options: [(value: Value, title: String)]) {
        self.title = title; self._selection = selection; self.options = options
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> WBPopUpButton {
        let button = WBPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 32), pullsDown: false)
        button.font = .systemFont(ofSize: 12)
        button.controlSize = .regular
        button.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: WBPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        let selectionIndex = options.firstIndex { $0.value == selection }
        // A stale/missing value gets a disabled prompt; displaying the first option
        // must not silently mutate a persisted preference or an unsaved form draft.
        let hasPrompt = selectionIndex == nil
        let titles = (hasPrompt ? [title] : []) + options.map(\.title)
        let values: [Value?] = (hasPrompt ? [nil] : []) + options.map { Optional($0.value) }
        if context.coordinator.rowValues != values || button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
            context.coordinator.rowValues = values
        }
        let selectedRow = selectionIndex.map { $0 + (hasPrompt ? 1 : 0) } ?? 0
        if button.indexOfSelectedItem != selectedRow { button.selectItem(at: selectedRow) }
        for (index, item) in button.itemArray.enumerated() {
            item.isEnabled = values[index] != nil
            item.state = index == selectedRow && values[index] != nil ? .on : .off
        }
        button.isEnabled = enabled && !options.isEmpty
        button.workbenchTheme = theme
        button.interfaceOpacity = opacity
        button.interfaceLight = colorScheme == .light
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(selectionIndex.map { options[$0].title } ?? "未选择")
        button.toolTip = title
        button.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WBPopUpButton, context: Context) -> CGSize? {
        let naturalWidth = max(120, nsView.cell?.cellSize.width ?? 160)
        return CGSize(width: proposal.width ?? naturalWidth, height: 32)
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Value>
        var rowValues: [Value?] = []
        init(selection: Binding<Value>) { self.selection = selection }
        @objc func changed(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard rowValues.indices.contains(index), let value = rowValues[index] else { return }
            selection.wrappedValue = value
            for (row, item) in sender.itemArray.enumerated() { item.state = row == index ? .on : .off }
            sender.setAccessibilityValue(sender.titleOfSelectedItem ?? "")
            sender.needsDisplay = true
        }
    }
}

/// AppKit equivalent for the embedded launcher settings; preserves the standard
/// popup cell's keyboard and menu behavior instead of reimplementing selection.
class WBPopUpButton: ClickablePopUpButton {
    private var choicePanel: WBChoicePopup?
    var choiceListFrame: NSRect? { choicePanel?.isVisible == true ? choicePanel?.frame : nil }
    override func mouseDown(with event: NSEvent) { openChoiceList() }
    override func performClick(_ sender: Any?) { openChoiceList() }
    override func keyDown(with event: NSEvent) {
        if [49, 36, 76, 125, 126].contains(event.keyCode) { openChoiceList() } else { super.keyDown(with: event) }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { choicePanel?.dismiss() }; super.viewWillMove(toWindow: newWindow)
    }
    fileprivate func choiceListDismissed() { choicePanel = nil; needsDisplay = true }
    private func openChoiceList() {
        guard isEnabled, !itemArray.isEmpty else { return }
        if let choicePanel { choicePanel.dismiss(); return }
        let panel = WBChoicePopup(anchor: self); choicePanel = panel; panel.present(); needsDisplay = true
    }
    var workbenchTheme: LauncherTheme = .arWorld
    var interfaceOpacity: Double = 0.70
    var interfaceLight = false
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    override var isEnabled: Bool {
        didSet { if !isEnabled { hovering = false }; needsDisplay = true }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = isEnabled; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override var isFlipped: Bool { true }
    // The stock popup cell adds optical alignment insets around its small bezel.
    // Our custom surface already occupies the full shared 32-point control frame.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: 32)
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let palette = ThemePalette(theme: workbenchTheme, opacity: interfaceOpacity, light: interfaceLight)
        NSColor(palette.control).setFill(); path.fill()
        let active = isEnabled && hovering, pressed = isEnabled && isHighlighted
        if active || pressed { palette.nsAccent.withAlphaComponent(pressed ? 0.25 : 0.15).setFill(); path.fill() }
        (active || pressed ? palette.nsAccent.withAlphaComponent(pressed ? 0.66 : 0.48) : NSColor(palette.controlBorder)).setStroke()
        path.lineWidth = 1; path.stroke()
        let color = palette.nsText.withAlphaComponent(isEnabled ? 1 : 0.4)
        drawText(titleOfSelectedItem ?? "", in: NSRect(x: 10, y: (bounds.height - 16) / 2, width: bounds.width - 34, height: 16), size: 12, color: color)
        drawSymbol("chevron.down", in: NSRect(x: bounds.width - 20, y: (bounds.height - 10) / 2, width: 10, height: 10), color: color.withAlphaComponent(isEnabled ? 0.7 : 0.35))
    }
}

struct WBCard<Content:View>: View {
    var title: String?
    var symbol: String?
    let content: Content
    var spacing:CGFloat=8
    var insets=EdgeInsets(top:14,leading:14,bottom:14,trailing:14)
    @Environment(\.workbenchPalette) private var palette
    init(title: String? = nil, symbol: String? = nil, spacing:CGFloat=8, insets:EdgeInsets=EdgeInsets(top:14,leading:14,bottom:14,trailing:14), @ViewBuilder content: () -> Content) { self.title=title; self.symbol=symbol;self.spacing=spacing;self.insets=insets;self.content=content() }
    init(_ title: String, @ViewBuilder content: () -> Content) { self.init(title:title,content:content) }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            if let title {
                HStack(spacing:7) {
                    if let symbol { Image(systemName:symbol).font(.system(size:16,weight:.regular)).foregroundStyle(palette.accent) }
                    Text(title).font(.system(size:12,weight:.medium)).foregroundStyle(palette.text)
                    Spacer(minLength:0)
                }.frame(height:22).padding(.bottom,10)
            }
            VStack(alignment:.leading,spacing:spacing) {content}
        }
        .frame(maxWidth:.infinity,alignment:.leading).padding(insets)
        .background(WorkbenchMaterialSurface())
    }
}

struct WBPageHeader<Trailing:View>:View {
    let title:String
    let subtitle:String
    let trailing:Trailing
    @Environment(\.workbenchPalette) private var palette
    init(title:String,subtitle:String,@ViewBuilder trailing:()->Trailing) { self.title=title;self.subtitle=subtitle;self.trailing=trailing() }
    var body: some View {
        HStack(alignment:.center,spacing:16) {
            VStack(alignment:.leading,spacing:6) {
                Text(title).font(.system(size:20,weight:.medium)).foregroundStyle(palette.text).lineLimit(1).truncationMode(.tail).frame(height:26,alignment:.leading).help(title)
                Text(subtitle).font(.system(size:12)).foregroundStyle(palette.secondary).lineLimit(1).truncationMode(.tail).frame(height:18,alignment:.leading).help(subtitle)
            }
            Spacer(minLength:12);trailing
        }.frame(minHeight:54).padding(.bottom,18)
    }
}
extension WBPageHeader where Trailing == EmptyView {
    init(title:String,subtitle:String) { self.init(title:title,subtitle:subtitle) { EmptyView() } }
}

struct WBMetric:View {
    let label:String
    let value:String
    var detail:String? = nil
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            Text(label).font(.system(size:11)).foregroundStyle(palette.muted)
            Text(value).font(.system(size:28,weight:.regular)).monospacedDigit().foregroundStyle(palette.text)
            if let detail { Text(detail).font(.system(size:11)).foregroundStyle(palette.muted) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
struct WBProgress:View {
    let value:Double
    var color:Color? = nil
    var height:CGFloat=5
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        GeometryReader { g in
            ZStack(alignment:.leading) {
                Capsule().fill(palette.progressTrack)
                Capsule().fill(color ?? palette.accent).frame(width:g.size.width*min(1,max(0,value.isFinite ? value : 0)))
            }
        }.frame(height:height)
    }
}
struct WBButtonStyle: ButtonStyle {
    var primary = false
    var destructive = false
    var compact = false
    @Environment(\.workbenchScale) private var displayScale
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let hovered = enabled && hovering
        let pressed = enabled && configuration.isPressed
        let tone = destructive ? palette.critical : palette.accent
        let shape = RoundedRectangle(cornerRadius: 8)
        return configuration.label
            .font(.system(size: (compact ? 11 : 12) * displayScale, weight: primary ? .medium : .regular))
            .multilineTextAlignment(.center)
            .padding(.horizontal, (compact ? 8 : 11) * displayScale)
            .frame(minHeight: (compact ? 28 : 32) * displayScale, alignment: .center)
            .foregroundStyle(primary ? palette.primaryText : destructive ? palette.critical : hovered ? palette.text : palette.secondary)
            .background(shape.fill(primary ? palette.primary : palette.control))
            .overlay(shape.fill(primary ? Color.black.opacity(pressed ? 0.22 : hovered ? 0.12 : 0) : tone.opacity(pressed ? 0.25 : hovered ? 0.15 : 0)).allowsHitTesting(false))
            .overlay(shape.strokeBorder(primary ? (hovered || pressed ? palette.primaryText.opacity(0.35) : palette.primary.opacity(0.50)) : hovered || pressed ? tone.opacity(pressed ? 0.66 : 0.48) : palette.controlBorder, lineWidth: 1).allowsHitTesting(false))
            .contentShape(shape).opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }.clickableCursor()
    }
}
struct WBIconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    @Environment(\.workbenchScale) private var displayScale
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14 * displayScale, weight: .regular))
            .frame(width: size * displayScale, height: size * displayScale, alignment: .center)
            .foregroundStyle(enabled && hovering ? palette.text : palette.secondary)
            .overlay(WBIconFeedbackSurface(hovering: enabled && hovering, pressed: enabled && configuration.isPressed))
            .contentShape(RoundedRectangle(cornerRadius: 7)).opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }.clickableCursor()
    }
}
/// Tertiary text actions use a color/underline cue, never a tight box around
/// their glyphs. Form-level Cancel actions use the regular secondary style.
struct WBQuietButtonStyle: ButtonStyle {
    @Environment(\.workbenchScale) private var displayScale
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11 * displayScale))
            .foregroundStyle(enabled && hovering ? palette.accent : palette.secondary)
            .padding(.vertical, 3 * displayScale)
            .overlay(alignment: .bottom) { Rectangle().fill(enabled && hovering ? palette.accent.opacity(0.55) : .clear).frame(height: 1).allowsHitTesting(false) }
            .contentShape(Rectangle()).opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
            .onHover { hovering = $0 }.clickableCursor()
    }
}
/// Explicit opt-in for links, text tabs and sortable headings. Keep the
/// caller's dimensions/font and do not paint a new button/card-shaped border.
struct WBTextActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(alignment: .bottom) { Rectangle().fill(enabled && hovering ? palette.accent.opacity(0.55) : .clear).frame(height: 1).allowsHitTesting(false) }
            .contentShape(Rectangle()).opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
            .onHover { hovering = $0 }.clickableCursor()
    }
}
/// The visual surface shared by actual detail icon buttons and a detail icon
/// inside an already-clickable card. This view does not receive mouse events.
struct WBIconFeedbackSurface: View {
    var hovering: Bool
    var pressed = false
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WBInteractionOverlay(tint: palette.accent, cornerRadius: 7, hovering: hovering, pressed: pressed)
    }
}
/// For navigation and segmented choices. Geometry and label colors belong to
/// the caller, while interaction remains consistent across every module.
struct WBSelectableButtonStyle: ButtonStyle {
    var selected = false
    var cornerRadius: CGFloat = 8
    var drawsSelection = true
    var tint: Color? = nil
    var showsBorder = true
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let tone = tint ?? palette.accent
        return configuration.label
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(selected && drawsSelection ? tone.opacity(0.16) : .clear))
            .overlay(WBInteractionOverlay(tint: tone, cornerRadius: cornerRadius, hovering: enabled && hovering,
                pressed: enabled && configuration.isPressed, selected: selected && drawsSelection, showsBorder: showsBorder))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius)).opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }.clickableCursor()
    }
}
/// An overlay keeps custom label fills from hiding interaction feedback. It
/// never changes padding, frame, hit testing or the caller's selected layout.
private struct WBInteractionOverlay: View {
    let tint: Color
    let cornerRadius: CGFloat
    let hovering: Bool
    let pressed: Bool
    var selected = false
    var showsBorder = true
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape.fill(tint.opacity(pressed ? 0.25 : hovering ? 0.15 : 0))
            .overlay(shape.strokeBorder(tint.opacity(showsBorder ? (pressed ? 0.66 : hovering ? 0.44 : selected ? 0.30 : 0) : 0), lineWidth: 1))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct WBTextTabs<Selection:Hashable>:View {
    let items:[Selection]
    @Binding var selection:Selection
    let title:(Selection)->String
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        HStack(spacing:21) {
            ForEach(items,id:\.self) {item in
                Button {selection=item} label:{
                    VStack(alignment:.leading,spacing:7) {
                        Text(title(item)).font(.system(size:12)).foregroundStyle(selection==item ? palette.text:palette.muted)
                        Capsule().fill(selection==item ? palette.accent:.clear).frame(height:2)
                    }.fixedSize(horizontal:true,vertical:false).padding(.top,3)
                }.buttonStyle(WBTextActionButtonStyle()).accessibilityValue(selection==item ? "已选择":"")
            }
        }
    }
}
struct WBEmptyState:View {
    let symbol:String
    let title:String
    let message:String
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        VStack(spacing:12) {
            Image(systemName:symbol).font(.system(size:28,weight:.light)).foregroundStyle(palette.accent)
            Text(title).font(.system(size:16,weight:.medium)).foregroundStyle(palette.text)
            Text(message).font(.system(size:12)).foregroundStyle(palette.secondary).multilineTextAlignment(.center).frame(maxWidth:360)
        }.frame(maxWidth:.infinity,minHeight:180).padding(24)
    }
}

struct WorkbenchGlass: NSViewRepresentable {
    var opacity:Double
    var light:Bool
    var panel:Bool=false
    var cornerRadius:CGFloat=24
    func makeNSView(context:Context)->GlassBackgroundView {
        let view=GlassBackgroundView(frame:.zero);view.radius=panel ? 18:cornerRadius;view.surfaceStyle = panel ? .workbenchPanel:.workbench
        return view
    }
    func updateNSView(_ view:GlassBackgroundView,context:Context) {
        Palette.isLight=light;Palette.glassOpacity=opacity
        view.radius=panel ? 18:cornerRadius;view.refreshAppearance()
    }
}

private struct WorkbenchSheetSurface:ViewModifier {
    func body(content:Content)->some View {
        content.background(WorkbenchMaterialSurface(kind:.panel,radius:14))
            .presentationBackground(.clear)
    }
}
extension View {func workbenchSheetSurface()->some View {modifier(WorkbenchSheetSurface())}}

/// Real AppKit traffic lights share the 46 pt chrome baseline instead of the system's short titlebar.
struct WorkbenchWindowControls:NSViewRepresentable {
    func makeNSView(context:Context)->WorkbenchTrafficLights {WorkbenchTrafficLights()}
    func updateNSView(_ view:WorkbenchTrafficLights,context:Context) {view.refresh()}
}
final class WorkbenchTrafficLights:NSView {
    private var controls:[NSButton]=[]
    override init(frame:NSRect) {
        super.init(frame:frame)
        for (index,type) in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton].enumerated() {
            guard let button=NSWindow.standardWindowButton(type,for:[.titled,.closable,.miniaturizable,.resizable]) else {continue}
            button.frame=NSRect(x:CGFloat(index)*20,y:1,width:12,height:12)
            button.target=self;button.action=[#selector(closeWindow),#selector(minimizeWindow),#selector(fullScreenWindow)][index]
            addSubview(button);controls.append(button)
        }
    }
    convenience init(){self.init(frame:NSRect(x:0,y:0,width:52,height:14))}
    required init?(coder:NSCoder){fatalError()}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();refresh()}
    func refresh(){if controls.indices.contains(1) {controls[1].isEnabled=window?.styleMask.contains(.fullScreen) != true}}
    @objc private func closeWindow(){window?.performClose(nil)}
    @objc private func minimizeWindow(){window?.performMiniaturize(nil)}
    @objc private func fullScreenWindow(){window?.toggleFullScreen(nil)}
}

/// Cursor rectangles let AppKit restore text, resize and drag cursors naturally.
/// Unlike push/pop in onHover, they cannot leave a stale hand when a page closes.
@MainActor final class ButtonCursorPolicy {
    static let shared = ButtonCursorPolicy()
    private(set) var preference: ButtonHoverCursor = .pointingHand
    private let views = NSHashTable<NSView>.weakObjects()
    private weak var hoveredView: ClickableCursorView?
    var cursor: NSCursor { preference == .pointingHand ? .pointingHand : .arrow }
    func register(_ view: NSView) { views.add(view) }
    func apply(_ preference: ButtonHoverCursor) {
        guard self.preference != preference else { return }
        self.preference = preference
        for view in views.allObjects {
            view.window?.invalidateCursorRects(for: view)
        }
        // Cursor-rectangle invalidation may rebuild a SwiftUI tracking area.
        // Re-evaluate the actual location so a stationary pointer updates too.
        let hovered = hoveredView.flatMap { $0.containsPointer ? $0 : nil }
            ?? views.allObjects.compactMap { $0 as? ClickableCursorView }.first(where: \.containsPointer)
        hovered?.refreshHoverCursor()
    }
    func beginHover(_ view: ClickableCursorView) { hoveredView = view }
    func ownsHover(_ view: ClickableCursorView) -> Bool { hoveredView === view }
    func endHover(_ view: ClickableCursorView) {
        guard hoveredView === view else { return }
        hoveredView = nil
        if NSCursor.current === NSCursor.pointingHand { NSCursor.arrow.set() }
    }
}

class ClickableButton: NSButton {
    override var isEnabled: Bool { didSet { window?.invalidateCursorRects(for: self) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); ButtonCursorPolicy.shared.register(self)
        window?.invalidateCursorRects(for: self)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = bounds.intersection(visibleRect)
        if isEnabled && !rect.isEmpty { addCursorRect(rect, cursor: ButtonCursorPolicy.shared.cursor) }
    }
}

class ClickablePopUpButton: NSPopUpButton {
    override var isEnabled: Bool { didSet { window?.invalidateCursorRects(for: self) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); ButtonCursorPolicy.shared.register(self)
        window?.invalidateCursorRects(for: self)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = bounds.intersection(visibleRect)
        if isEnabled && !rect.isEmpty { addCursorRect(rect, cursor: ButtonCursorPolicy.shared.cursor) }
    }
}

class ClickableCursorView: NSView {
    private var hoverTracking: NSTrackingArea?
    private var hovering = false
    private var refreshTask: Task<Void, Never>?
    var enabled = true {
        didSet {
            guard oldValue != enabled else { return }
            window?.invalidateCursorRects(for: self)
            updateTrackingAreas()
            refreshHoverCursor()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); ButtonCursorPolicy.shared.register(self)
        window?.invalidateCursorRects(for: self)
        updateTrackingAreas()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endHover() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        hoverTracking = nil
        guard enabled else { return }
        // SwiftUI's hosting view can install a later arrow cursor rectangle
        // over a hit-transparent background. Native tracking receives the
        // actual pointer event after that update while leaving clicks with
        // the SwiftUI Button's full content shape.
        let area = NSTrackingArea(rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self, userInfo: nil)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refreshHoverCursor() }
    override func mouseMoved(with event: NSEvent) { hovering = true; refreshHoverCursor() }
    override func cursorUpdate(with event: NSEvent) { hovering = true; refreshHoverCursor() }
    override func mouseExited(with event: NSEvent) { endHover() }
    var containsPointer: Bool {
        guard enabled, !isHiddenOrHasHiddenAncestor, let window, window.isVisible else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.intersection(visibleRect).contains(point)
    }
    func refreshHoverCursor() {
        guard containsPointer else { endHover(); return }
        hovering = true
        ButtonCursorPolicy.shared.beginHover(self)
        ButtonCursorPolicy.shared.cursor.set()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            // A hover-driven SwiftUI redraw may rebuild its cursor rectangles
            // after mouseEntered returns. Reassert once after that transaction,
            // without polling or retaining a cursor beyond the hovered region.
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled, let self, self.hovering, self.containsPointer,
                  ButtonCursorPolicy.shared.ownsHover(self) else { return }
            ButtonCursorPolicy.shared.cursor.set()
        }
    }
    private func endHover() {
        guard hovering else { return }
        hovering = false
        refreshTask?.cancel(); refreshTask = nil
        // A delayed exit from an old/rebuilt region must not clear the cursor
        // already installed by the button that the pointer entered next.
        ButtonCursorPolicy.shared.endHover(self)
        window?.invalidateCursorRects(for: self)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = bounds.intersection(visibleRect)
        if enabled && !rect.isEmpty { addCursorRect(rect, cursor: ButtonCursorPolicy.shared.cursor) }
    }
}

private struct ClickableCursorRegion: NSViewRepresentable {
    let enabled: Bool
    func makeNSView(context: Context) -> ClickableCursorView { ClickableCursorView(frame: .zero) }
    func updateNSView(_ view: ClickableCursorView, context: Context) { view.enabled = enabled }
}

private struct ClickableCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content.background(ClickableCursorRegion(enabled: enabled).accessibilityHidden(true))
    }
}

extension View {
    func clickableCursor() -> some View { modifier(ClickableCursorModifier()) }
}

/// Cursor and full-label hit shape only. Readouts and already-painted card
/// bodies must not acquire an arbitrary rounded hover surface from this style.
struct ClickablePlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).clickableCursor()
    }
}


/// A choice list opens outside the trigger, not with the selected row covering
/// it. The same native host serves every WBSelect while retaining popup AX and
/// model bindings. It never changes the document's width or scroll position.
@MainActor final class WBChoicePopup: NSPanel {
    private weak var anchor: WBPopUpButton?
    private let items: [NSMenuItem]
    private let palette: ThemePalette
    private let scroller = NSScrollView()
    private let list = WBChoiceDocument()
    private var rows: [WBChoiceRow] = []
    private var current: Int
    private var outsideMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var dismissing = false
    private var typed = ""
    private var lastTyped: TimeInterval = 0

    init(anchor: WBPopUpButton) {
        self.anchor = anchor; items = anchor.itemArray
        current = max(0, anchor.indexOfSelectedItem)
        palette = ThemePalette(theme: anchor.workbenchTheme, opacity: anchor.interfaceOpacity, light: anchor.interfaceLight)
        let width = min(440, max(anchor.bounds.width, (items.map { ($0.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width }.max() ?? 100) + 48))
        let height = min(288, CGFloat(items.count) * 28 + 8)
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear; hasShadow = true
        appearance = NSAppearance(named: anchor.interfaceLight ? .aqua : .darkAqua)
        level = .popUpMenu; animationBehavior = .none; hidesOnDeactivate = true
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        surface.wantsLayer = true
        let material = NSHostingView(rootView: WorkbenchMaterialSurface(kind: .panel, radius: 10, behindWindow: true)
            .workbenchThemeEnvironment(theme: anchor.workbenchTheme, opacity: anchor.interfaceOpacity, appearance: anchor.interfaceLight ? .light : .dark))
        material.frame = surface.bounds; material.autoresizingMask = [.width, .height]
        surface.addSubview(material)
        surface.layer?.cornerRadius = 10
        surface.layer?.masksToBounds = true
        scroller.frame = surface.bounds.insetBy(dx: 4, dy: 4)
        scroller.hasVerticalScroller = true; scroller.scrollerStyle = .overlay; scroller.autohidesScrollers = true
        scroller.drawsBackground = false; scroller.borderType = .noBorder
        scroller.scrollerKnobStyle = anchor.interfaceLight ? .dark : .light
        list.frame = NSRect(x: 0, y: 0, width: width - 8, height: CGFloat(items.count) * 28)
        for (index, item) in items.enumerated() {
            let row = WBChoiceRow(frame: NSRect(x: 0, y: CGFloat(index) * 28, width: width - 8, height: 28),
                                  title: item.title, selected: index == anchor.indexOfSelectedItem, palette: palette)
            row.isEnabled = item.isEnabled
            row.commit = { [weak self] in self?.choose(index) }
            row.hover = { [weak self] in self?.setCurrent(index) }
            list.addSubview(row); rows.append(row)
        }
        scroller.documentView = list; surface.addSubview(scroller); contentView = surface
        setAccessibilityLabel(anchor.accessibilityLabel() ?? "选择选项")
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    func present() {
        guard let anchor, let parent = anchor.window else { return }
        let trigger = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        let below = trigger.minY - 5 - frame.height
        let originY = below >= visible.minY + 6 ? below : min(visible.maxY - frame.height - 6, trigger.maxY + 5)
        setFrameOrigin(NSPoint(x: min(max(visible.minX + 6, trigger.minX), visible.maxX - frame.width - 6), y: max(visible.minY + 6, originY)))
        parent.addChildWindow(self, ordered: .above); makeKeyAndOrderFront(nil)
        setCurrent(current)
        if rows.indices.contains(current) { list.scrollToVisible(rows[current].frame) }
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self { self.dismiss() }
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }
    func dismiss() {
        guard !dismissing else { return }; dismissing = true
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        let wasKey = isKeyWindow
        let parent = parent; parent?.removeChildWindow(self); orderOut(nil)
        anchor?.choiceListDismissed()
        if NSApp.isActive, wasKey { parent?.makeKey(); parent?.makeFirstResponder(anchor) }
        close()
    }
    private func choose(_ index: Int) {
        guard items.indices.contains(index), items[index].isEnabled, let anchor else { return }
        dismiss()
        anchor.selectItem(at: index)
        for (i, item) in anchor.itemArray.enumerated() { item.state = i == index ? .on : .off }
        anchor.setAccessibilityValue(anchor.titleOfSelectedItem ?? "")
        anchor.sendAction(anchor.action, to: anchor.target); anchor.needsDisplay = true
    }
    private func setCurrent(_ value: Int) {
        guard rows.indices.contains(value), rows[value].isEnabled else { return }
        current = value
        for (index, row) in rows.enumerated() { row.active = index == value }
    }
    private func move(_ direction: Int) {
        guard !rows.isEmpty else { return }
        for step in 1...rows.count {
            let index = (current + direction * step + rows.count * 2) % rows.count
            if rows[index].isEnabled { setCurrent(index); list.scrollToVisible(rows[index].frame); return }
        }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: dismiss()
        case 125: move(1)
        case 126: move(-1)
        case 36, 76, 49: choose(current)
        case 48: dismiss()
        default:
            guard let value = event.charactersIgnoringModifiers, !value.isEmpty else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTyped > 0.8 { typed = "" }; lastTyped = now; typed += value.lowercased()
            if let index = items.indices.first(where: { items[$0].isEnabled && items[$0].title.lowercased().hasPrefix(typed) }) {
                setCurrent(index); list.scrollToVisible(rows[index].frame)
            }
        }
    }
}
@MainActor private final class WBChoiceDocument: NSView {
    override var isFlipped: Bool { true }
}
@MainActor private final class WBChoiceRow: ClickableButton {
    let palette: ThemePalette
    let chosen: Bool
    var active = false { didSet { needsDisplay = true } }
    var commit: () -> Void = {}
    var hover: () -> Void = {}
    private var area: NSTrackingArea?
    init(frame: NSRect, title: String, selected: Bool, palette: ThemePalette) {
        self.palette = palette; chosen = selected
        super.init(frame: frame); self.title = title; isBordered = false; target = self; action = #selector(pick)
        setAccessibilityLabel(title); setAccessibilityValue(selected ? "已选择" : "未选择")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self)
        area = new; addTrackingArea(new)
    }
    override func mouseEntered(with event: NSEvent) { if isEnabled { hover() } }
    @objc private func pick() { commit() }
    override func draw(_ dirtyRect: NSRect) {
        if active || isHighlighted {
            palette.nsAccent.withAlphaComponent(isHighlighted ? 0.22 : 0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let textColor = (active ? palette.nsText : palette.nsSecondary).withAlphaComponent(isEnabled ? 1 : 0.4)
        if chosen { drawSymbol("checkmark", in: NSRect(x: 7, y: 8, width: 12, height: 12), color: palette.nsAccent) }
        drawText(title, in: NSRect(x: 28, y: 6, width: bounds.width - 36, height: 17), size: 12, color: textColor)
    }
}

/// Shared chart callout: the pointer terminates on the actual plotted mark.
/// The surface follows the same theme and opacity as every workbench card.
struct WBChartCallout<Content: View>: View {
    let anchor: CGRect
    let canvas: CGSize
    let size: CGSize
    @ViewBuilder let content: () -> Content
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        let placement = WBChartCalloutPlacement(anchor: anchor, canvas: canvas, size: size)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: placement.tip)
                path.addLine(to: placement.baseStart)
                path.addLine(to: placement.baseEnd)
                path.closeSubpath()
            }.fill(palette.surfaceGradient)
            Path { path in
                path.move(to: placement.baseStart)
                path.addLine(to: placement.tip)
                path.addLine(to: placement.baseEnd)
            }.stroke(palette.border, lineWidth: 1)
            content().frame(width: placement.frame.width, height: placement.frame.height, alignment: .topLeading)
                .background(WorkbenchMaterialSurface(kind: .panel, radius: 8))
                .position(x: placement.frame.midX, y: placement.frame.midY)
            Circle().fill(palette.accent).frame(width: 5, height: 5)
                .position(placement.tip)
        }.allowsHitTesting(false)
    }
}

struct WBChartCalloutPlacement {
    let frame: CGRect
    let tip: CGPoint
    let baseStart: CGPoint
    let baseEnd: CGPoint
    init(anchor: CGRect, canvas: CGSize, size: CGSize) {
        let width = min(size.width, max(0, canvas.width))
        let height = min(size.height, max(0, canvas.height - 10))
        tip = CGPoint(x: anchor.midX, y: anchor.minY)
        let above = anchor.minY >= height + 10
        let below = anchor.minY + 10 + height <= canvas.height
        if above || below {
            let x = min(max(anchor.midX - width / 2, 0), max(0, canvas.width - width))
            let y = above ? anchor.minY - height - 10 : anchor.minY + 10
            frame = CGRect(x: x, y: y, width: width, height: height)
            let baseX = min(max(anchor.midX, x + 14), x + width - 14)
            let edgeY = above ? frame.maxY : frame.minY
            baseStart = CGPoint(x: baseX - 6, y: edgeY)
            baseEnd = CGPoint(x: baseX + 6, y: edgeY)
        } else {
            // Mid-height marks leave insufficient vertical room. Move beside
            // the mark so the pointer never points into the bubble itself.
            let left = anchor.midX > canvas.width / 2
            let available = max(0, (left ? anchor.midX : canvas.width - anchor.midX) - 10)
            let fittedWidth = min(width, available)
            let x = left ? anchor.midX - 10 - fittedWidth : anchor.midX + 10
            let y = min(max(0, anchor.minY - height / 2), max(0, canvas.height - height))
            frame = CGRect(x: x, y: y, width: fittedWidth, height: height)
            let edgeX = left ? frame.maxX : frame.minX
            let baseY = min(max(anchor.minY, y + 14), y + height - 14)
            baseStart = CGPoint(x: edgeX, y: baseY - 6)
            baseEnd = CGPoint(x: edgeX, y: baseY + 6)
        }
    }
}
