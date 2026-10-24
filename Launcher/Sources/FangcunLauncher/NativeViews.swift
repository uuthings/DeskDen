import AppKit
import Combine
import LauncherCore
import SwiftUI

@MainActor
enum Palette {
    static var isLight = false
    static var glassOpacity: Double = 0.70
    static var workbenchTheme: LauncherTheme = .arWorld
    static var workbenchPalette: ThemePalette { ThemePalette(theme: workbenchTheme, opacity: glassOpacity, light: isLight) }
    static var text: NSColor { workbenchPalette.nsText }
    static var secondary: NSColor { workbenchPalette.nsSecondary }
    static var muted: NSColor { workbenchPalette.nsMuted }
    static var ink: NSColor { isLight ? .black : .white }
    static var darkText: NSColor { ThemePalette(theme: workbenchTheme).nsText }
    static var darkSecondary: NSColor { ThemePalette(theme: workbenchTheme).nsSecondary }
    static var darkMuted: NSColor { ThemePalette(theme: workbenchTheme).nsMuted }
    static var accent: NSColor { workbenchPalette.nsAccent }
    static var warning: NSColor { NSColor(workbenchPalette.warning) }
    static var error: NSColor { NSColor(workbenchPalette.critical) }
}

@MainActor
func drawText(_ value: String, in rect: NSRect, size: CGFloat = 12, color: NSColor = Palette.text, alignment: NSTextAlignment = .left, weight: NSFont.Weight = .regular) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineBreakMode = .byTruncatingTail
    (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
}

@MainActor
func drawSymbol(_ name: String, in rect: NSRect, color: NSColor = Palette.secondary) {
    if name == "magnifyingglass" {
        let side = min(rect.width,rect.height), unit = side / 16
        let origin = NSPoint(x:rect.midX-side/2,y:rect.midY-side/2)
        let ring = NSBezierPath(ovalIn:NSRect(x:origin.x+1.25*unit,y:origin.y+1.25*unit,width:10.5*unit,height:10.5*unit))
        ring.lineWidth = 1.65*unit; color.setStroke(); ring.stroke()
        let handle = NSBezierPath(); handle.move(to:NSPoint(x:origin.x+10.1*unit,y:origin.y+10.1*unit)); handle.line(to:NSPoint(x:origin.x+14.75*unit,y:origin.y+14.75*unit))
        handle.lineWidth = 1.65*unit; handle.lineCapStyle = .round; handle.stroke(); return
    }
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: rect.height, weight: .regular)) else { return }
    let tinted = NSImage(size: image.size, flipped: false) { bounds in image.draw(in: bounds); color.set(); bounds.fill(using: .sourceAtop); return true }
    let scale = min(rect.width/image.size.width,rect.height/image.size.height)
    let fitted = NSRect(x:rect.midX-image.size.width*scale/2,y:rect.midY-image.size.height*scale/2,width:image.size.width*scale,height:image.size.height*scale)
    tinted.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

class FlippedView: NSView { override var isFlipped: Bool { true } }
final class FocusSurface: FlippedView { override var acceptsFirstResponder: Bool { true } }
final class PassthroughLabel: NSTextField { override func hitTest(_ point:NSPoint) -> NSView? { nil } }

enum GlassSurfaceStyle: Equatable { case launcher, panel, workbench, workbenchPanel }

/// Native refraction/blur, tint, and the edge are independent decoration layers.
final class GlassBackgroundView: FlippedView {
    private var effectView: NSView?
    private var usesClearGlass = false
    private let tint = GlassTint()
    private let edge = GlassBorder()
    var surfaceStyle: GlassSurfaceStyle = .launcher { didSet { tint.surfaceStyle = surfaceStyle; configureEffect() } }
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow { didSet { configureEffect() } }
    var radius: CGFloat = 12 { didSet { updateShape() } }
    var drawsBorder = true { didSet { edge.isHidden = !drawsBorder } }
    var customShape: NSBezierPath? { didSet { configureEffect(); updateShape() } }
    /// Only the effect changes opacity; controls, tint, and edge never inherit it.
    var effectOpacity: CGFloat = 0.62 { didSet { updateEffectOpacity() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(tint); addSubview(edge)
        configureEffect(); refreshAppearance(); updateShape()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        effectView?.frame = bounds; tint.frame = bounds; edge.frame = bounds
        if #available(macOS 26.0, *), let clear = effectView as? NSGlassEffectView { clear.contentView?.frame = clear.bounds }
        updateShape()
    }
    func refreshAppearance() {
        let name: NSAppearance.Name = Palette.isLight ? .aqua : .darkAqua
        if appearance?.name != name { appearance = NSAppearance(named: name) }
        effectView?.appearance = appearance
        tint.needsDisplay = true; edge.needsDisplay = true
    }
    private func configureEffect() {
        // The same native glass samples the desktop and the launcher behind child panels.
        // Arrow surfaces clip that glass to their public shape instead of adding an opaque HUD.
        let wantsClear: Bool
        if #available(macOS 26.0, *) {
            wantsClear = blendingMode == .behindWindow && surfaceStyle != .workbench && surfaceStyle != .workbenchPanel
        } else { wantsClear = false }
        if effectView == nil || usesClearGlass != wantsClear {
            effectView?.removeFromSuperview()
            let next: NSView
            if #available(macOS 26.0, *), wantsClear {
                let clear = NSGlassEffectView(frame: bounds)
                clear.style = surfaceStyle == .panel ? .regular : .clear; clear.tintColor = nil; clear.cornerRadius = radius
                clear.contentView = FlippedView(frame: bounds)
                if #available(macOS 27.0, *) { clear.effectIsInteractive = false }
                next = clear
            } else {
                let blur = NSVisualEffectView(frame: bounds)
                blur.state = .active; blur.isEmphasized = false
                next = blur
            }
            usesClearGlass = wantsClear; effectView = next
            next.autoresizingMask = [.width, .height]
            addSubview(next, positioned: .below, relativeTo: tint)
        }
        if let blur = effectView as? NSVisualEffectView {
            blur.blendingMode = blendingMode
            blur.material = surfaceStyle == .workbench || surfaceStyle == .workbenchPanel ? .hudWindow : blendingMode == .withinWindow || surfaceStyle == .panel ? .popover : .underWindowBackground
        }
        if #available(macOS 26.0, *), let clear = effectView as? NSGlassEffectView {
            clear.style = surfaceStyle == .panel ? .regular : .clear
        }
        edge.nativeGlassEdge = usesClearGlass && surfaceStyle == .launcher
        updateEffectOpacity(); refreshAppearance(); updateShape()
    }
    private func updateEffectOpacity() {
        // In-window dialogs must fully blur the launcher's text behind them.
        effectView?.alphaValue = blendingMode == .withinWindow || surfaceStyle == .panel || surfaceStyle == .workbench || surfaceStyle == .workbenchPanel || usesClearGlass ? 1 : min(1, max(0, effectOpacity))
    }
    private func updateShape() {
        tint.frame = bounds; edge.frame = bounds
        tint.radius = radius; tint.customShape = customShape
        edge.radius = radius; edge.customShape = customShape
        if let customShape, bounds.width > 0, bounds.height > 0 {
            layer?.cornerRadius = 0; layer?.masksToBounds = false
            let mask = CAShapeLayer(); mask.frame = bounds; mask.path = customShape.cgPath; layer?.mask = mask
            if let blur = effectView as? NSVisualEffectView {
                let path = customShape.copy() as! NSBezierPath
                blur.maskImage = NSImage(size: bounds.size, flipped: true) { _ in
                    NSColor.white.setFill(); path.fill(); return true
                }
            }
        } else {
            layer?.mask = nil
            layer?.cornerRadius = radius; layer?.masksToBounds = true
            if let blur = effectView as? NSVisualEffectView { blur.maskImage = nil }
        }
        if #available(macOS 26.0, *), let clear = effectView as? NSGlassEffectView { clear.cornerRadius = radius }
    }
}

final class BackdropView: FlippedView {
    private let glass = GlassBackgroundView()
    var fullScreen = false { didSet { updateGeometry() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if CommandLine.arguments.contains("--material-preview") {
            let pattern = MaterialPreviewPattern(frame:bounds); pattern.autoresizingMask = [.width,.height]; addSubview(pattern)
        }
        glass.frame = bounds; glass.autoresizingMask = [.width, .height]; addSubview(glass)
        updateGeometry()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); glass.frame = bounds; updateGeometry() }
    private func updateGeometry() {
        let radius: CGFloat = fullScreen ? 0 : 12
        layer?.cornerRadius = radius; layer?.masksToBounds = true
        glass.radius = radius; glass.drawsBorder = !fullScreen
    }
    func refreshAppearance() { glass.refreshAppearance(); needsDisplay = true }
}

final class GlassTint: FlippedView {
    var radius: CGFloat = 12 { didSet { needsDisplay = true } }
    var surfaceStyle: GlassSurfaceStyle = .launcher { didSet { needsDisplay = true } }
    var customShape: NSBezierPath? { didSet { needsDisplay = true } }
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = customShape ?? NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let palette = Palette.workbenchPalette
        if surfaceStyle == .launcher {
            NSGraphicsContext.saveGraphicsState(); path.addClip()
            if let image = WorkbenchSceneAssets.image(for: Palette.workbenchTheme), image.size.width > 0, image.size.height > 0 {
                let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
                let rect = NSRect(x: bounds.midX - image.size.width * scale / 2, y: bounds.midY - image.size.height * scale / 2, width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGradient(colors: [NSColor(palette.raised), NSColor(palette.surface)])?.draw(in: path, angle: 45)
            NSGraphicsContext.restoreGraphicsState()
        } else if surfaceStyle == .workbenchPanel {
            NSGradient(colors: [NSColor(palette.raised), NSColor(palette.surface)])?.draw(in: path, angle: 45)
        } else {
            NSColor(palette.overlay).setFill(); path.fill()
        }
    }
}

private final class GlassBorder: FlippedView {
    var radius: CGFloat = 12 { didSet { needsDisplay = true } }
    var customShape: NSBezierPath? { didSet { needsDisplay = true } }
    var nativeGlassEdge = false { didSet { needsDisplay = true } }
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = customShape ?? NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor(Palette.workbenchPalette.border).setStroke()
        path.lineWidth = 1; path.stroke()
    }
}

final class SoftSurface: FlippedView {
    var radius: CGFloat = 8
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        (Palette.isLight ? NSColor.white.withAlphaComponent(0.20) : NSColor.white.withAlphaComponent(0.035)).setFill(); path.fill()
        Palette.ink.withAlphaComponent(0.09).setStroke(); path.stroke()
    }
}

class CardView: FlippedView {
    private let glass = GlassBackgroundView()
    private var installingSurface = false
    private var storedRadius: CGFloat = 12
    var radius: CGFloat {
        get { storedRadius }
        set { storedRadius = max(0, newValue); installSurface() }
    }
    /// A popover's shared background also covers its arrow, so its body must stay clear.
    var usesGlassBackground = true { didSet { installSurface() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.surfaceStyle = .panel
        installSurface()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func didAddSubview(_ subview: NSView) { super.didAddSubview(subview); installSurface() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); installSurface() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installSurface() }
    override func layout() { super.layout(); installSurface() }
    func refreshAppearance() { glass.refreshAppearance() }
    private func installSurface() {
        guard !installingSurface else { return }
        installingSurface = true; defer { installingSurface = false }
        layer?.cornerRadius = radius; layer?.masksToBounds = true
        guard usesGlassBackground else { glass.removeFromSuperview(); return }
        var ancestor = superview
        var hasBackgroundInWindow = false
        while let view = ancestor {
            if view is CardView || view is BackdropView || view is GlassBackgroundView { hasBackgroundInWindow = true; break }
            ancestor = view.superview
        }
        let blending: NSVisualEffectView.BlendingMode = hasBackgroundInWindow ? .withinWindow : .behindWindow
        if glass.blendingMode != blending { glass.blendingMode = blending }
        glass.radius = radius
        glass.frame = bounds; glass.autoresizingMask = [.width, .height]
        if glass.superview !== self { addSubview(glass, positioned: .below, relativeTo: nil) }
        refreshAppearance()
    }
}

final class ShadeView: FlippedView {
    var outsideClick: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) { NSColor.black.withAlphaComponent(0.07).setFill(); bounds.fill() }
    override func mouseDown(with event: NSEvent) { outsideClick?() }
}

final class ActionButton: ClickableButton {
    var actionBlock: (() -> Void)?
    var symbol: String?
    var primary = false
    var selected = false { didSet { needsDisplay = true } }
    var border = false
    var radius: CGFloat = 8
    var fontSize: CGFloat = 12
    var textColor: NSColor?
    var hovered = false
    var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    init(_ title: String, symbol: String? = nil, frame: NSRect, action: @escaping () -> Void) {
        super.init(frame: frame); self.title = title; self.symbol = symbol; actionBlock = action
        isBordered = false; setButtonType(.momentaryChange); target = self; self.action = #selector(invoke)
        setAccessibilityLabel(title); focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func invoke() { actionBlock?() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited,.activeAlways,.inVisibleRect], owner: self); addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let isFocused = window?.firstResponder === self
        if primary { (isEnabled ? Palette.accent : Palette.ink.withAlphaComponent(0.12)).setFill(); shape.fill() }
        else if selected || hovered || isHighlighted || border || isFocused { NSColor.white.withAlphaComponent(isHighlighted ? 0.20 : selected ? 0.10 : hovered ? 0.08 : 0.035).setFill(); shape.fill() }
        if border { Palette.ink.withAlphaComponent(0.14).setStroke(); shape.stroke() }
        let foreground = (textColor ?? (primary ? NSColor(calibratedWhite: 0.13, alpha: 1) : selected ? Palette.text : Palette.secondary)).withAlphaComponent(isEnabled ? 1 : 0.35)
        if let symbol {
            let compact = bounds.width < 80 && !title.isEmpty
            let icon: CGFloat = compact ? 12 : 16
            let x: CGFloat = title.isEmpty ? (bounds.width-icon)/2 : compact ? 7 : 10
            drawSymbol(symbol, in: NSRect(x:x,y:(bounds.height-icon)/2,width:icon,height:icon),color:foreground)
            if !title.isEmpty {
                let textX:CGFloat = compact ? 24 : 32
                let text = NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:compact ? min(fontSize,11) : fontSize,weight:.medium),.foregroundColor:foreground])
                text.draw(in:NSRect(x:textX,y:(bounds.height-text.size().height)/2,width:bounds.width-textX-4,height:text.size().height))
            }
        } else {
            let text = NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:fontSize),.foregroundColor:foreground])
            text.draw(at:NSPoint(x:(bounds.width-text.size().width)/2,y:(bounds.height-text.size().height)/2))
        }
    }
}

/// Brand and segmented controls use the same optical centre, rather than a text-field baseline.
final class LauncherBrandView: FlippedView {
    private var iconChanges: AnyCancellable?
    override init(frame:NSRect) {
        super.init(frame:frame)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("方寸")
        iconChanges = ApplicationIconController.shared.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.needsDisplay = true }
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    override func draw(_ dirtyRect:NSRect) {
        let controller = ApplicationIconController.shared
        let logo = controller.image(for: controller.selection) ?? Bundle.main.image(forResource:"PanelLogo")
        logo?.draw(in:NSRect(x:0,y:4,width:26,height:26),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        let text=NSAttributedString(string:"方寸",attributes:[.font:NSFont.systemFont(ofSize:22,weight:.regular),.foregroundColor:Palette.text,.kern:2])
        text.draw(at:NSPoint(x:32,y:(bounds.height-text.size().height)/2))
    }
}

/// A real refractive surface shared by the header controls. The face and rim are
/// separate from the native backdrop, so the content never inherits translucency.
final class LauncherControlGlass: FlippedView {
    private let effect: NSView
    private let rim = LauncherControlRim()
    init(frame: NSRect, selected: Bool = false) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.style = .regular; glass.tintColor = nil
            glass.cornerRadius = frame.height / 2
            glass.contentView = FlippedView(frame: .zero)
            if #available(macOS 27.0, *) { glass.effectIsInteractive = false }
            effect = glass
        } else {
            let blur = NSVisualEffectView(frame: .zero)
            blur.material = .popover; blur.blendingMode = .withinWindow
            blur.state = .active; effect = blur
        }
        super.init(frame: frame)
        rim.selected = selected
        addSubview(effect); addSubview(rim)
        effect.frame = bounds; rim.frame = bounds
        effect.autoresizingMask = [.width, .height]; rim.autoresizingMask = [.width, .height]
        wantsLayer = true; layer?.cornerRadius = frame.height / 2; layer?.masksToBounds = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class LauncherControlRim: FlippedView {
    var selected = false
    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5), radius = outer.height / 2
        let face = NSBezierPath(roundedRect: outer, xRadius: radius, yRadius: radius)
        let lift: CGFloat = selected ? 0.12 : 0.075
        NSGradient(colors: [NSColor.white.withAlphaComponent(lift),
                            NSColor.white.withAlphaComponent(lift * 0.32),
                            NSColor.white.withAlphaComponent(lift * 0.65)])?.draw(in: face, angle: 90)
        NSColor.black.withAlphaComponent(selected ? 0.14 : 0.30).setStroke()
        face.lineWidth = 0.75; face.stroke()
        // A narrow specular rim with brighter horizontal edges and quiet sides.
        let edge = NSBezierPath(roundedRect: outer.insetBy(dx: 0.65, dy: 0.65), xRadius: radius - 0.65, yRadius: radius - 0.65)
        let hollow = NSBezierPath(roundedRect: outer.insetBy(dx: 1.35, dy: 1.35), xRadius: radius - 1.35, yRadius: radius - 1.35)
        edge.append(hollow); edge.windingRule = .evenOdd
        NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(selected ? 0.42 : 0.52), 0),
            (NSColor.white.withAlphaComponent(0.06), 0.32),
            (NSColor.white.withAlphaComponent(0.08), 0.72),
            (NSColor.white.withAlphaComponent(selected ? 0.35 : 0.45), 1))?.draw(in: edge, angle: 90)
    }
}

final class LauncherViewSwitcher: FlippedView {
    init(frame:NSRect, applications:Bool, changed:@escaping (Bool)->Void) {
        super.init(frame:frame)
        addSubview(LauncherControlGlass(frame:bounds))
        for (index,title) in ["动作","应用"].enumerated() {
            let segment = NSRect(x:3+CGFloat(index)*(frame.width-6)/2,y:3,width:(frame.width-6)/2,height:frame.height-6)
            let selected = applications == (index == 1)
            if selected { addSubview(LauncherControlGlass(frame:segment,selected:true)) }
            let button = LauncherSegmentButton(title:title,symbol:index == 0 ? "keyboard" : "magnifyingglass",selected:selected,frame:segment) { changed(index == 1) }
            addSubview(button)
        }
        setAccessibilityElement(false)
    }
    required init?(coder:NSCoder) { fatalError() }
}

private final class LauncherSegmentButton: ClickableButton {
    let selectedSegment:Bool
    let symbol:String
    let activate:()->Void
    private var tracking:NSTrackingArea?
    private var hovered=false
    override var isFlipped:Bool { true }
    init(title:String,symbol:String,selected:Bool,frame:NSRect,activate:@escaping ()->Void) {
        selectedSegment=selected; self.symbol=symbol; self.activate=activate
        super.init(frame:frame); self.title=title; isBordered=false; focusRingType = .none
        target=self; action=#selector(invoke); setAccessibilityLabel(title); setAccessibilityValue(selected ? 1 : 0)
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func invoke() { activate() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking=NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self); addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent) { hovered=true; needsDisplay=true }
    override func mouseExited(with event:NSEvent) { hovered=false; needsDisplay=true }
    override func draw(_ dirtyRect:NSRect) {
        if hovered || isHighlighted || window?.firstResponder === self {
            let selection=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:13,yRadius:13)
            Palette.ink.withAlphaComponent(isHighlighted ? 0.12 : 0.045).setFill(); selection.fill()
        }
        let font=NSFont.systemFont(ofSize:12,weight:selectedSegment ? .semibold : .medium)
        let attributes:[NSAttributedString.Key:Any] = [.font:font,.foregroundColor:selectedSegment ? Palette.text : Palette.secondary]
        let text=NSAttributedString(string:title,attributes:attributes), size=text.size()
        let iconWidth:CGFloat = symbol == "keyboard" ? 15 : 12
        let groupWidth:CGFloat=iconWidth+5+size.width, x=(bounds.width-groupWidth)/2
        let color = selectedSegment ? Palette.text : Palette.secondary
        if symbol == "keyboard" {
            drawLauncherKeyboard(in:NSRect(x:x,y:(bounds.height-10)/2,width:15,height:10),color:color)
        } else {
            drawSymbol(symbol,in:NSRect(x:x,y:(bounds.height-12)/2,width:12,height:12),color:color)
        }
        text.draw(at:NSPoint(x:x+iconWidth+5,y:(bounds.height-size.height)/2))
    }
}

@MainActor
private func drawLauncherKeyboard(in rect: NSRect, color: NSColor) {
    let outline = NSBezierPath(roundedRect:rect.insetBy(dx:0.5,dy:0.5),xRadius:1.6,yRadius:1.6)
    color.setStroke(); outline.lineWidth = 1; outline.stroke()
    color.setFill()
    for row in 0..<2 { for column in 0..<5 {
        NSBezierPath(roundedRect:NSRect(x:rect.minX+2.3+CGFloat(column)*2.25,y:rect.minY+2.3+CGFloat(row)*2.2,width:1.35,height:1.25),xRadius:0.3,yRadius:0.3).fill()
    } }
    NSBezierPath(roundedRect:NSRect(x:rect.minX+4.5,y:rect.minY+6.8,width:6,height:1),xRadius:0.4,yRadius:0.4).fill()
}

/// Header destination with the same glass, type scale and optical centre as the switcher.
final class LauncherWorkbenchButton: FlippedView {
    init(frame: NSRect, activate: @escaping () -> Void) {
        super.init(frame: frame)
        addSubview(LauncherControlGlass(frame:bounds))
        let button = LauncherWorkbenchAction(frame:bounds,activate:activate)
        button.autoresizingMask = [.width,.height]; addSubview(button)
    }
    required init?(coder:NSCoder) { fatalError() }
}
private final class LauncherWorkbenchAction: ClickableButton {
    let activate: () -> Void
    override var isFlipped:Bool { true }
    init(frame:NSRect,activate:@escaping ()->Void) {
        self.activate=activate; super.init(frame:frame)
        title="工作台"; isBordered=false; focusRingType = .none
        target=self; action=#selector(invoke); setAccessibilityLabel("工作台")
        toolTip="打开方寸工作台"
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func invoke() { activate() }
    override func draw(_ dirtyRect:NSRect) {
        if isHighlighted { NSColor.white.withAlphaComponent(0.10).setFill(); NSBezierPath(roundedRect:bounds,xRadius:16,yRadius:16).fill() }
        let text=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:Palette.secondary])
        let x=(bounds.width-16-6-text.size().width)/2
        drawSymbol("rectangle.split.2x2",in:NSRect(x:x,y:(bounds.height-16)/2,width:16,height:16),color:Palette.secondary)
        text.draw(at:NSPoint(x:x+22,y:(bounds.height-text.size().height)/2))
    }
}

/// The footer uses individual keycaps, as in the reference, and only advertises live registrations.
final class LauncherShortcutHint: FlippedView {
    let prefix: String?
    let summon: String?
    init(frame: NSRect, prefix: String?, summon: String?) {
        self.prefix = prefix; self.summon = summon
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel(prefix.map { "任意界面按 \($0) + 键位 直接打开对应内容" } ?? summon.map { "任意界面按 \($0) 打开启动器" } ?? "从菜单栏打开启动器")
        toolTip = "Tab 切换动作与应用视图"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:Palette.muted]
        let items: [(String,Bool)] = prefix.map { [("任意界面按",false),($0,true),("+",false),("键位",true),("直接打开对应内容",false)] } ?? summon.map { [("任意界面按",false),($0,true),("打开启动器",false)] } ?? [("从菜单栏打开启动器",false)]
        let widths = items.map { NSAttributedString(string:$0.0,attributes:attributes).size().width + ($0.1 ? 12 : 0) }
        var x = (bounds.width - widths.reduce(0,+) - CGFloat(items.count-1)*6)/2
        for (index,item) in items.enumerated() {
            let text = NSAttributedString(string:item.0,attributes:attributes)
            if item.1 {
                let key = NSBezierPath(roundedRect:NSRect(x:x,y:5,width:widths[index],height:18),xRadius:4,yRadius:4)
                Palette.ink.withAlphaComponent(0.045).setFill(); key.fill()
                Palette.ink.withAlphaComponent(0.13).setStroke(); key.lineWidth=0.7; key.stroke()
            }
            text.draw(at:NSPoint(x:x+(item.1 ? 6 : 0),y:(bounds.height-text.size().height)/2))
            x += widths[index]+6
        }
    }
}

final class LauncherLayoutButton: ClickableButton {
    var activate:(()->Void)?
    private var area:NSTrackingArea?
    private var hovered=false
    override var isFlipped:Bool { true }
    init(frame:NSRect,activate:@escaping ()->Void) {
        self.activate=activate; super.init(frame:frame); title="布局"; isBordered=false; focusRingType = .none
        target=self; action=#selector(invoke); setAccessibilityLabel("布局")
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func invoke() { activate?() }
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }; area=NSTrackingArea(rect:bounds,options:[.activeAlways,.mouseEnteredAndExited,.inVisibleRect],owner:self); addTrackingArea(area!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent) { hovered=true; needsDisplay=true }
    override func mouseExited(with event:NSEvent) { hovered=false; needsDisplay=true }
    override func draw(_ dirtyRect:NSRect) {
        if hovered || isHighlighted { Palette.ink.withAlphaComponent(isHighlighted ? 0.12 : 0.055).setFill(); NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8).fill() }
        let color=Palette.secondary
        let glyph = NSRect(x:7,y:9,width:14,height:14)
        color.setStroke()
        for (y,knobX): (CGFloat,CGFloat) in [(1.5,9.5),(7,4),(12.5,8)] {
            let line=NSBezierPath(); line.move(to:NSPoint(x:glyph.minX,y:glyph.minY+y)); line.line(to:NSPoint(x:glyph.maxX,y:glyph.minY+y))
            line.lineWidth=1; line.lineCapStyle = .round; line.stroke()
            let knob=NSBezierPath(roundedRect:NSRect(x:glyph.minX+knobX-1.8,y:glyph.minY+y-1.5,width:3.6,height:3),xRadius:1,yRadius:1)
            (Palette.isLight ? NSColor(calibratedWhite:0.80,alpha:1) : NSColor(calibratedWhite:0.40,alpha:1)).setFill(); knob.fill()
            color.setStroke(); knob.lineWidth=0.9; knob.stroke()
        }
        let text=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:color])
        text.draw(at:NSPoint(x:28,y:(bounds.height-text.size().height)/2))
        drawSymbol("chevron.down",in:NSRect(x:58,y:12.5,width:7,height:7),color:color)
    }
}


/// Reference-style rounded track, visible while the list has more content.
final class LauncherScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func draw(_ dirtyRect: NSRect) { drawKnobSlot(in:bounds,highlight:false); drawKnob() }
    override func drawKnob() {
        let slot = rect(for:.knob)
        guard slot.height > 0 else { return }
        let thumb = NSRect(x:bounds.midX-5,y:slot.minY,width:10,height:max(14,slot.height))
        (Palette.isLight ? NSColor.black.withAlphaComponent(0.45) : NSColor.white.withAlphaComponent(0.43)).setFill()
        NSBezierPath(roundedRect:thumb,xRadius:5,yRadius:5).fill()
    }
    override func drawKnobSlot(in slotRect:NSRect, highlight flag:Bool) {
        let track = NSRect(x:bounds.midX-5,y:0,width:10,height:bounds.height)
        NSColor.black.withAlphaComponent(Palette.isLight ? 0.12 : 0.68).setFill()
        NSBezierPath(roundedRect:track,xRadius:5,yRadius:5).fill()
    }
}

final class LauncherSearchFieldCell: NSSearchFieldCell {
    private var previousEditorInset: NSSize?
    private var previousLinePadding: CGFloat?
    /// Borderless search cells do not consistently consult searchTextRect when drawing.
    /// Use one rectangle for display, hit testing and the native field editor.
    private func contentRect(in bounds: NSRect) -> NSRect {
        let textFont = font ?? .systemFont(ofSize: 13)
        let height = min(bounds.height, ceil(NSLayoutManager().defaultLineHeight(for: textFont)))
        return NSRect(x: bounds.minX + 10, y: bounds.midY - height / 2,
                      width: max(0, bounds.width - 40), height: height)
    }
    private func fullBounds(_ fallback: NSRect) -> NSRect { controlView?.bounds ?? fallback }
    override func searchTextRect(forBounds rect: NSRect) -> NSRect { contentRect(in: fullBounds(rect)) }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { contentRect(in: fullBounds(rect)) }
    override func titleRect(forBounds rect: NSRect) -> NSRect { contentRect(in: fullBounds(rect)) }
    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        let bounds = fullBounds(rect)
        return NSRect(x: bounds.maxX - 25, y: bounds.midY - 8, width: 16, height: 16)
    }
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        if let textView = editor as? NSTextView {
            if previousEditorInset == nil { previousEditorInset = textView.textContainerInset }
            if previousLinePadding == nil { previousLinePadding = textView.textContainer?.lineFragmentPadding }
            textView.drawsBackground = false
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
        }
        return editor
    }
    override func endEditing(_ textObj: NSText) {
        super.endEditing(textObj)
        if let textView = textObj as? NSTextView {
            if let previousEditorInset { textView.textContainerInset = previousEditorInset }
            if let previousLinePadding { textView.textContainer?.lineFragmentPadding = previousLinePadding }
        }
        previousEditorInset = nil; previousLinePadding = nil
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: contentRect(in: controlView.bounds), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: contentRect(in: controlView.bounds), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
    func drawSearchContents(in view: NSControl) {
        let editor = view.currentEditor()
        let value = editor?.string ?? stringValue
        // The NSTextView field editor draws entered text and composition itself.
        // Only the inactive value or the empty placeholder is drawn by the cell.
        if editor == nil || value.isEmpty {
            let text = value.isEmpty ? placeholderString ?? "" : value
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .left; paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: value.isEmpty ? Palette.muted : textColor ?? Palette.text,
                .paragraphStyle: paragraph
            ]
            NSAttributedString(string: text, attributes: attributes).draw(in: contentRect(in: view.bounds))
        }
        if !value.isEmpty { cancelButtonCell?.draw(withFrame: cancelButtonRect(forBounds: view.bounds), in: view) }
    }
}

/// Native editing, selection, search callbacks and IME are retained; only the surface is drawn here.
final class LauncherSearchField: NSSearchField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = LauncherSearchFieldCell(textCell: "")
        isEditable = true; isSelectable = true
        focusRingType = .none; isBordered = false; isBezeled = false; drawsBackground = false
        font = .systemFont(ofSize: 13); textColor = Palette.text
        sendsSearchStringImmediately = true; sendsWholeSearchString = false
        if let searchCell = cell as? NSSearchFieldCell {
            searchCell.searchButtonCell = nil
            searchCell.focusRingType = .none
            searchCell.usesSingleLineMode = true
            searchCell.isScrollable = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Palette.ink.withAlphaComponent(0.065).setFill(); path.fill()
        (cell as? LauncherSearchFieldCell)?.drawSearchContents(in: self)
    }
}

final class LauncherPanel: NSPanel {
    private(set) var processingMarkedKey = false
    override func sendEvent(_ event:NSEvent) {
        if event.type == .keyDown {
            processingMarkedKey = (firstResponder as? NSTextView)?.hasMarkedText() == true
            defer { processingMarkedKey = false }
            super.sendEvent(event)
        } else { super.sendEvent(event) }
    }
    override func animationResizeTime(_ newFrame:NSRect) -> TimeInterval { 0.16 }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// NSTextView owns composition and candidate handling; commands are dispatched only outside composition.
final class SearchTextView: NSTextView, NSTextViewDelegate {
    var changed: ((String) -> Void)?
    var editingChanged: (() -> Void)?
    var command: ((Selector) -> Bool)?
    var clicked: (() -> Void)?
    private var beganMarked = false
    override func keyDown(with event: NSEvent) {
        beganMarked = hasMarkedText()
        defer { beganMarked = false }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) { clicked?(); super.mouseDown(with: event) }
    override func doCommand(by selector: Selector) {
        if !beganMarked && !hasMarkedText(), command?(selector) == true { return }
        super.doCommand(by: selector)
    }
    override func setMarkedText(_ string:Any,selectedRange:NSRange,replacementRange:NSRange) {
        super.setMarkedText(string,selectedRange:selectedRange,replacementRange:replacementRange); editingChanged?()
    }
    override func unmarkText() { super.unmarkText(); editingChanged?() }
    func textDidChange(_ notification: Notification) { editingChanged?(); if !hasMarkedText() { changed?(string) } }
    func configure() {
        delegate = self; isRichText = false; importsGraphics = false; drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = false; isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false; isContinuousSpellCheckingEnabled = false
        isAutomaticTextReplacementEnabled = false; allowsUndo = true
        textColor = Palette.text; insertionPointColor = Palette.text
        font = .systemFont(ofSize:15); textContainerInset = NSSize(width:0,height:4)
        textContainer?.lineFragmentPadding = 0; textContainer?.maximumNumberOfLines = 1
        textContainer?.lineBreakMode = .byClipping; isHorizontallyResizable = true
        setAccessibilityLabel("搜索应用和绑定目标")
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var images: [String:NSImage] = [:]
    private var opticalRects: [String:NSRect] = [:]
    func image(for target: LaunchTarget) -> NSImage? {
        if let data = target.iconData {
            let key = target.id + ":" + String(data.hashValue)
            if let image = images[key] { return image }; let image = NSImage(data:data); images[key] = image; return image
        }
        guard [.app,.file,.folder].contains(target.kind), let url = TargetResolver.url(for: target) else { return nil }
        if let image = images[url.path] { return image }
        let icon = NSWorkspace.shared.icon(forFile: url.path); images[url.path] = icon
        if images.count > 500 { images.removeAll(keepingCapacity:true) }
        return icon
    }
    /// Detect the opaque body, excluding the icon's transparent canvas and soft shadow.
    func sourceRect(for image: NSImage, key: String) -> NSRect {
        if let value = opticalRects[key] { return value }
        let size = 128
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:size*4,bitsPerPixel:32), let context = NSGraphicsContext(bitmapImageRep:bitmap), let bytes = bitmap.bitmapData else { return NSRect(origin:.zero,size:image.size) }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        image.draw(in:NSRect(x:0,y:0,width:size,height:size)); NSGraphicsContext.restoreGraphicsState()
        var minX = size, minY = size, maxX = 0, maxY = 0
        for y in 0..<size { for x in 0..<size where bytes[y*size*4+x*4+3] >= 160 { minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y) } }
        guard minX < maxX, minY < maxY else { return NSRect(origin:.zero,size:image.size) }
        let edge = CGFloat(max(maxX-minX+1,maxY-minY+1)), centerX = CGFloat(minX+maxX+1)/2, centerY = CGFloat(minY+maxY+1)/2
        let rect = NSRect(x:(centerX-edge/2)/128*image.size.width,y:(128-centerY-edge/2)/128*image.size.height,width:edge/128*image.size.width,height:edge/128*image.size.height)
        opticalRects[key] = rect; return rect
    }
    func clear() { images.removeAll(); opticalRects.removeAll() }
}

@MainActor
func drawTarget(_ target: LaunchTarget, in rect: NSRect, normalized: Bool = false, opacity: CGFloat = 1) {
    if let icon = IconCache.shared.image(for: target) {
        if normalized {
            // Draw the whole icon expanded so the opaque body, not its transparent canvas, fills rect.
            let source = IconCache.shared.sourceRect(for:icon,key:target.id + ":" + String(target.iconData?.hashValue ?? 0))
            let scale = rect.width/source.width
            let destination = NSRect(x:rect.minX-source.minX*scale,y:rect.minY-(icon.size.height-source.maxY)*scale,width:icon.size.width*scale,height:icon.size.height*scale)
            icon.draw(in:destination,from:.zero,operation:.sourceOver,fraction:opacity,respectFlipped:true,hints:nil)
        } else { icon.draw(in:rect,from:.zero,operation:.sourceOver,fraction:opacity,respectFlipped:true,hints:nil) }
    } else {
        let path = NSBezierPath(roundedRect:rect,xRadius:rect.width*0.22,yRadius:rect.width*0.22)
        let colors: [NSColor] = target.kind == .shortcut ? [NSColor(calibratedRed:0.48,green:0.53,blue:0.70,alpha:opacity),NSColor(calibratedRed:0.32,green:0.39,blue:0.40,alpha:opacity)] : [NSColor(calibratedRed:0.58,green:0.67,blue:0.61,alpha:opacity),NSColor(calibratedRed:0.32,green:0.43,blue:0.37,alpha:opacity)]
        NSGradient(colors:colors)?.draw(in:path,angle:60); NSColor.white.withAlphaComponent(0.23).setStroke(); path.stroke()
        drawSymbol(target.kind.symbol,in:rect.insetBy(dx:rect.width*0.21,dy:rect.height*0.21),color:Palette.text.withAlphaComponent(opacity))
    }
}

final class KeyTile: ClickableButton {
    let key: String
    let mode: DisplayMode
    let binding: KeyBinding?
    let editing: Bool
    let missing: Bool
    var hovered = false
    var dropHighlight = false
    var actionBlock: (() -> Void)?
    var contextBlock: (() -> Void)?
    var hoverBlock: ((Bool) -> Void)?
    var swapBlock: ((String,String) -> Void)?
    var removeBlock:(()->Void)?
    private var area: NSTrackingArea?
    private var initialPoint: NSPoint?
    private var dragged = false
    override var isFlipped: Bool { true }
    init(key: String, mode: DisplayMode, binding: KeyBinding?, editing: Bool, frame: NSRect) {
        self.key = key; self.mode = mode; self.binding = binding; self.editing = editing
        missing = binding.map { $0.target.kind.isFileSystem && TargetResolver.url(for:$0.target) == nil } ?? false
        super.init(frame: frame); isBordered = false; focusRingType = .none
        title = ""; setAccessibilityRole(.button); setAccessibilityLabel("\(key) · \(binding?.title ?? "未绑定")\(missing ? "，目标失效" : "")")
        toolTip = binding.map { "\(key) · \($0.title)\n\($0.target.location)" } ?? "绑定到 \(key)"
        target = self; action = #selector(invoke)
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc func invoke() { actionBlock?() }
    override func updateTrackingAreas() { if let area { removeTrackingArea(area) }; area = NSTrackingArea(rect:bounds,options:[.activeAlways,.mouseEnteredAndExited,.inVisibleRect],owner:self); addTrackingArea(area!); super.updateTrackingAreas() }
    override func mouseEntered(with event:NSEvent) { hovered = true; needsDisplay = true; hoverBlock?(true) }
    override func mouseExited(with event:NSEvent) { hovered = false; needsDisplay = true; hoverBlock?(false) }
    override func rightMouseDown(with event:NSEvent) { contextBlock?() }
    override func mouseDown(with event:NSEvent) {
        if event.modifierFlags.contains(.control) { contextBlock?(); return }
        initialPoint = event.locationInWindow; dragged = false; isHighlighted = true; needsDisplay = true
    }
    override func mouseDragged(with event:NSEvent) {
        guard editing, let initialPoint else { return }
        if hypot(event.locationInWindow.x-initialPoint.x,event.locationInWindow.y-initialPoint.y) > 6 { dragged = true }
        guard dragged else { return }
        for case let tile as KeyTile in superview?.subviews ?? [] { tile.dropHighlight = tile.bounds.contains(tile.convert(event.locationInWindow,from:nil)); tile.needsDisplay = true }
    }
    override func mouseUp(with event:NSEvent) {
        defer { initialPoint = nil; isHighlighted = false; needsDisplay = true }
        if dragged {
            for case let tile as KeyTile in superview?.subviews ?? [] {
                let dropped = tile.dropHighlight; tile.dropHighlight = false; tile.needsDisplay = true
                if dropped { swapBlock?(key,tile.key) }
            }
        } else if bounds.contains(convert(event.locationInWindow,from:nil)) { if editing && binding != nil && NSRect(x:0,y:0,width:18,height:18).contains(convert(event.locationInWindow,from:nil)) { removeBlock?() } else { actionBlock?() } }
    }
    override func draw(_ dirtyRect:NSRect) {
        let size = mode.keySize, iconSize = mode.iconSize
        let plateSize:CGFloat = mode == .full ? 65 : mode == .key ? 71 : iconSize
        let tileRect = NSRect(x:(size-plateSize)/2,y:(size-plateSize)/2,width:plateSize,height:plateSize)
        let radius: CGFloat = plateSize*0.25
        let path = NSBezierPath(roundedRect:tileRect,xRadius:radius,yRadius:radius)
        let focus = window?.firstResponder === self
        if binding == nil || mode.showsKey {
            NSGradient(colors:[Palette.ink.withAlphaComponent(binding == nil ? 0.065 : 0.075),Palette.ink.withAlphaComponent(0.025)])?.draw(in:path,angle:70)
            (Palette.isLight ? NSColor.black.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.24)).setStroke()
            if editing && binding == nil { path.setLineDash([3,3],count:2,phase:0) }; path.lineWidth = 0.6; path.stroke()
            if !editing { let inside = NSBezierPath(roundedRect:tileRect.insetBy(dx:0.8,dy:0.8),xRadius:radius-0.8,yRadius:radius-0.8); Palette.ink.withAlphaComponent(0.06).setStroke(); inside.lineWidth=0.5; inside.stroke() }
        }
        if hovered || dropHighlight || focus || isHighlighted { NSColor.white.withAlphaComponent(isHighlighted ? 0.17 : 0.055).setFill(); path.fill(); NSColor.white.withAlphaComponent(dropHighlight || focus ? 0.65 : 0.25).setStroke(); path.stroke() }
        if let binding {
            let iconRect = NSRect(x:(size-iconSize)/2,y:(size-iconSize)/2+(isHighlighted ? 1 : 0),width:iconSize,height:iconSize)
            drawTarget(binding.target,in:iconRect,normalized:true,opacity:missing ? 0.45 : 1)
            if mode.showsKey { drawText(key,in:NSRect(x:tileRect.maxX-17,y:tileRect.maxY-18,width:15,height:17),size:12,alignment:.center,weight:.bold) }
        } else { drawText(key,in:NSRect(x:0,y:(size-23)/2,width:size,height:23),size:mode.showsKey ? 19 : 16,color:Palette.text,alignment:.center,weight:.semibold) }
        if mode.showsName { drawText(binding?.title ?? "绑定",in:NSRect(x:-2,y:mode == .name ? 79 : 78,width:size+4,height:18),size:11,color:Palette.secondary,alignment:.center,weight:.medium) }
        if missing { let dot = NSRect(x:size-12,y:0,width:15,height:15); Palette.warning.setFill(); NSBezierPath(ovalIn:dot).fill(); drawText("!",in:dot,size:11,color:.black,alignment:.center,weight:.medium) }
        if editing && binding != nil { drawSymbol("minus.circle.fill",in:NSRect(x:0,y:0,width:16,height:16),color:Palette.error) }
    }
}

/// The search field uses a quiet one-pixel edge instead of AppKit's outer focus ring.
final class ApplicationSearchSurface: FlippedView {
    weak var editor: NSTextView?
    override init(frame:NSRect) {
        super.init(frame:frame)
        let glass = LauncherControlGlass(frame:bounds)
        glass.autoresizingMask = [.width,.height]; addSubview(glass)
    }
    required init?(coder:NSCoder) { fatalError() }
}

/// Both search affordances retain the small, unframed glyphs of the reference.
final class SearchAccessoryButton: ClickableButton {
    enum Glyph: Equatable { case inputMode, more }
    let glyph: Glyph
    var textMode = false { didSet { needsDisplay = true } }
    var actionBlock: (() -> Void)?
    var contextBlock: (() -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    init(_ glyph: Glyph, frame: NSRect) {
        self.glyph = glyph
        super.init(frame: frame)
        title = ""; isBordered = false; focusRingType = .none
        target = self; action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { actionBlock?() }
    override func rightMouseDown(with event: NSEvent) { contextBlock?() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted || window?.firstResponder === self {
            Palette.ink.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        let color = glyph == .inputMode && !textMode ? Palette.secondary : Palette.text
        switch glyph {
        case .inputMode:
            drawText("字", in: NSRect(x: 4, y: 5.5, width: 15, height: 18), size: 12.5, color: color, weight: .medium)
            let caret = NSBezierPath()
            caret.move(to: NSPoint(x: 20.5, y: 6)); caret.line(to: NSPoint(x: 20.5, y: 22))
            caret.move(to: NSPoint(x: 18.5, y: 6)); caret.line(to: NSPoint(x: 22.5, y: 6))
            caret.move(to: NSPoint(x: 18.5, y: 22)); caret.line(to: NSPoint(x: 22.5, y: 22))
            color.setStroke(); caret.lineWidth = 0.85; caret.stroke()
        case .more:
            let circle = NSBezierPath(ovalIn:NSRect(x:8,y:7.5,width:12,height:12))
            color.setStroke(); circle.lineWidth=1.2; circle.stroke(); color.setFill()
            for x:CGFloat in [11,14,17] { NSBezierPath(ovalIn:NSRect(x:x-0.65,y:12.85,width:1.3,height:1.3)).fill() }
        }
    }
}

final class ResultTile: ClickableButton {
    let entry: SearchEntry
    let list: Bool
    var selected: Bool { didSet { refreshSelectionAppearance() } }
    var selectionVisible = false { didSet { refreshSelectionAppearance() } }
    var badge: String?
    var showsSearchDetails = false
    var starred = false
    var dropHighlight = false
    var actionBlock: (() -> Void)?
    var contextBlock: (() -> Void)?
    var reorderBlock: ((String,String) -> Void)?
    private var initialPoint:NSPoint?
    private var dragging = false
    override var isFlipped: Bool { true }
    init(entry:SearchEntry,list:Bool,selected:Bool,badge:String?,frame:NSRect) {
        self.entry = entry; self.list = list; self.selected = selected; self.badge = badge
        super.init(frame:frame); isBordered = false; title = ""; target = self; action = #selector(invoke)
        focusRingType = .none; setAccessibilityLabel(entry.title); setAccessibilitySelected(false); toolTip = entry.target.location
    }
    private var searchSubtitle: String? {
        guard showsSearchDetails else { return nil }
        if entry.target.kind == .app {
            guard let translated = entry.title.applyingTransform(.toLatin, reverse: false) else { return nil }
            let plain = translated.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard SearchEntry.normalize(plain) != SearchEntry.normalize(entry.title) else { return nil }
            return plain
        }
        if entry.target.kind == .web, let host = URLComponents(string: entry.target.location)?.host, !host.isEmpty { return host }
        return entry.target.kind.title
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc func invoke() { actionBlock?() }
    private func refreshSelectionAppearance() {
        setAccessibilitySelected(selected && selectionVisible); needsDisplay = true
    }
    override func rightMouseDown(with event:NSEvent) { contextBlock?() }
    override func mouseDown(with event:NSEvent) {
        if event.modifierFlags.contains(.control) { contextBlock?(); return }
        initialPoint = event.locationInWindow; dragging = false; isHighlighted = true; needsDisplay = true
    }
    override func mouseDragged(with event:NSEvent) {
        guard reorderBlock != nil, let initialPoint else { return }
        if hypot(event.locationInWindow.x-initialPoint.x,event.locationInWindow.y-initialPoint.y) > 6 { dragging = true }
        guard dragging else { return }
        for case let tile as ResultTile in superview?.subviews ?? [] {
            tile.dropHighlight = tile !== self && tile.bounds.contains(tile.convert(event.locationInWindow,from:nil)); tile.needsDisplay = true
        }
    }
    override func mouseUp(with event:NSEvent) {
        defer { initialPoint = nil; isHighlighted = false; needsDisplay = true }
        if dragging {
            for case let tile as ResultTile in superview?.subviews ?? [] {
                let dropped = tile.dropHighlight; tile.dropHighlight = false; tile.needsDisplay = true
                if dropped { reorderBlock?(entry.target.id,tile.entry.target.id) }
            }
        } else if bounds.contains(convert(event.locationInWindow,from:nil)) { actionBlock?() }
    }
    override func draw(_ dirtyRect:NSRect) {
        let iconRect = list ? NSRect(x:10,y:9,width:30,height:30) : NSRect(x:(bounds.width-61)/2,y:11,width:61,height:61)
        let subtitle = list ? nil : searchSubtitle
        if selected && selectionVisible {
            let rect = list ? bounds.insetBy(dx:1,dy:1) : NSRect(x:(bounds.width-95)/2,y:0.5,width:95,height:subtitle == nil ? 117 : 125)
            let path = NSBezierPath(roundedRect:rect,xRadius:list ? 9 : 16,yRadius:list ? 9 : 16)
            NSColor.white.withAlphaComponent(Palette.isLight ? 0.20 : 0.09).setFill(); path.fill()
            NSColor(srgbRed:0.357,green:0.576,blue:0.741,alpha:1).setStroke(); path.lineWidth = 1; path.stroke()
        }
        if isHighlighted || dropHighlight {
            let highlight = list ? bounds.insetBy(dx:1,dy:1) : iconRect.insetBy(dx:-8,dy:-8)
            let path = NSBezierPath(roundedRect:highlight,xRadius:list ? 9 : 20,yRadius:list ? 9 : 20)
            Palette.ink.withAlphaComponent(isHighlighted ? 0.12 : 0.065).setFill(); path.fill()
            if dropHighlight { Palette.accent.setStroke(); path.lineWidth = 1; path.stroke() }
        }
        drawTarget(entry.target,in:iconRect,normalized:!list,opacity:isHighlighted ? 0.82 : 1)
        if list {
            drawText(entry.title,in:NSRect(x:52,y:14,width:bounds.width*0.47,height:20),size:13,weight:.medium)
            drawText(entry.target.location,in:NSRect(x:bounds.width*0.52,y:16,width:bounds.width*0.48-52,height:16),size:11,color:Palette.muted,alignment:.right)
        } else {
            drawText(entry.title,in:NSRect(x:6,y:91,width:bounds.width-12,height:20),size:13,color:Palette.text,alignment:.center,weight:.semibold)
            if let subtitle {
                drawText(subtitle,in:NSRect(x:6,y:111,width:bounds.width-12,height:15),size:10,color:Palette.muted,alignment:.center,weight:.medium)
            }
        }
        let badgeBox = list ? NSRect(x:bounds.width-29,y:14,width:20,height:20) : NSRect(x:iconRect.maxX-5,y:0,width:20,height:20)
        let drawsReturn = showsSearchDetails && selected
        let number = showsSearchDetails ? badge.flatMap(Int.init) : nil
        if drawsReturn || number != nil || starred {
            NSColor(calibratedWhite:0.95,alpha:0.97).setFill(); NSBezierPath(ovalIn:badgeBox).fill()
            let ink = NSColor(calibratedWhite:0.12,alpha:1)
            if drawsReturn {
                drawSymbol("return",in:badgeBox.insetBy(dx:5,dy:5),color:ink)
            } else if let number {
                drawText(String(number),in:badgeBox.offsetBy(dx:0,dy:2.5),size:10.5,color:ink,alignment:.center,weight:.bold)
            } else {
                let c = NSPoint(x:badgeBox.midX,y:badgeBox.midY), r:CGFloat = 5.5
                let star = NSBezierPath(); star.move(to:NSPoint(x:c.x,y:c.y-r))
                star.curve(to:NSPoint(x:c.x+r,y:c.y),controlPoint1:NSPoint(x:c.x+1.5,y:c.y-1.5),controlPoint2:NSPoint(x:c.x+1.5,y:c.y-1.5))
                star.curve(to:NSPoint(x:c.x,y:c.y+r),controlPoint1:NSPoint(x:c.x+1.5,y:c.y+1.5),controlPoint2:NSPoint(x:c.x+1.5,y:c.y+1.5))
                star.curve(to:NSPoint(x:c.x-r,y:c.y),controlPoint1:NSPoint(x:c.x-1.5,y:c.y+1.5),controlPoint2:NSPoint(x:c.x-1.5,y:c.y+1.5))
                star.curve(to:NSPoint(x:c.x,y:c.y-r),controlPoint1:NSPoint(x:c.x-1.5,y:c.y-1.5),controlPoint2:NSPoint(x:c.x-1.5,y:c.y-1.5))
                star.close(); ink.setFill(); star.fill()
            }
        }
    }
}

/// A reproducible backdrop for native glass QA, shown only with --material-preview.
/// It contains no desktop capture or user content and is never shown during normal use.
private final class MaterialPreviewPattern: FlippedView {
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.12,alpha:1).setFill(); bounds.fill()
        let colors:[NSColor] = [.systemIndigo,.systemBlue,.systemTeal,.systemGreen,.systemOrange,.systemRed]
        for (index,color) in colors.enumerated() {
            color.withAlphaComponent(0.85).setFill()
            NSRect(x:CGFloat(index)*bounds.width/6,y:64,width:bounds.width/6,height:bounds.height-128).fill()
        }
        NSColor.white.setFill(); NSRect(x:bounds.width/2,y:64,width:bounds.width/2,height:100).fill()
        NSColor.black.setFill(); NSRect(x:0,y:bounds.height-164,width:bounds.width/2,height:100).fill()
        drawText("玻璃材质检查 · 合成色板背景",in:NSRect(x:40,y:20,width:600,height:24),size:15,color:.white)
        drawText("同一窗口跨越明、暗和彩色背景：观察透光、磨砂和文字对比",in:NSRect(x:40,y:bounds.height-41,width:1000,height:24),size:13,color:.white)
    }
}
