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
final class WBPopUpButton: ClickablePopUpButton {
    var workbenchTheme: LauncherTheme = .arWorld
    var interfaceOpacity: Double = 0.70
    var interfaceLight = false
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
        (isHighlighted ? palette.nsAccent.withAlphaComponent(0.18) : NSColor(palette.control)).setFill(); path.fill()
        NSColor(palette.controlBorder).setStroke(); path.lineWidth = 1; path.stroke()
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
    @Environment(\.workbenchDeviceExpanded) private var expanded
    init(title:String,subtitle:String,@ViewBuilder trailing:()->Trailing) { self.title=title;self.subtitle=subtitle;self.trailing=trailing() }
    var body: some View {
        HStack(alignment:.center,spacing:16) {
            VStack(alignment:.leading,spacing:6) {
                Text(title).font(.system(size:expanded ? 22:20,weight:.medium)).foregroundStyle(palette.text).frame(height:26,alignment:.leading)
                Text(subtitle).font(.system(size:12)).foregroundStyle(palette.secondary).frame(minHeight:17.4,alignment:.leading).frame(height:18,alignment:.leading)
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
            .overlay(WBInteractionOverlay(tint: palette.accent, cornerRadius: 7, hovering: enabled && hovering, pressed: enabled && configuration.isPressed))
            .contentShape(RoundedRectangle(cornerRadius: 7)).opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }.clickableCursor()
    }
}
struct WBQuietButtonStyle: ButtonStyle {
    @Environment(\.workbenchScale) private var displayScale
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11 * displayScale))
            .foregroundStyle(enabled && hovering ? palette.text : palette.secondary)
            .multilineTextAlignment(.center).padding(.vertical, 3 * displayScale)
            .overlay(WBInteractionOverlay(tint: palette.accent, cornerRadius: 6, hovering: enabled && hovering, pressed: enabled && configuration.isPressed))
            .contentShape(Rectangle()).opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }.clickableCursor()
    }
}
/// For navigation and segmented choices. Geometry and label colors belong to
/// the caller, while interaction remains consistent across every module.
struct WBSelectableButtonStyle: ButtonStyle {
    var selected = false
    var cornerRadius: CGFloat = 8
    var drawsSelection = true
    var tint: Color? = nil
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let tone = tint ?? palette.accent
        return configuration.label
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(selected && drawsSelection ? tone.opacity(0.16) : .clear))
            .overlay(WBInteractionOverlay(tint: tone, cornerRadius: cornerRadius, hovering: enabled && hovering,
                pressed: enabled && configuration.isPressed, selected: selected && drawsSelection))
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
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape.fill(tint.opacity(pressed ? 0.25 : hovering ? 0.15 : 0))
            .overlay(shape.strokeBorder(tint.opacity(pressed ? 0.66 : hovering ? 0.44 : selected ? 0.30 : 0), lineWidth: 1))
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
                }.buttonStyle(ClickablePlainButtonStyle()).accessibilityValue(selection==item ? "已选择":"")
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

struct ClickablePlainButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .overlay(WBInteractionOverlay(tint: palette.accent, cornerRadius: 8, hovering: enabled && hovering, pressed: enabled && configuration.isPressed))
            .onHover { hovering = $0 }.clickableCursor()
    }
}
