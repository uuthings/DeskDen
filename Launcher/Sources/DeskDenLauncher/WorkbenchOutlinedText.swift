import AppKit
import CoreText
import QuartzCore
import SwiftUI

/// The glyph outlines stay readable while a short light stroke travels along
/// them. Core Animation owns the frames; the dashboard is not redrawn at 60 Hz.
struct WorkbenchOutlinedText: NSViewRepresentable {
    var text: String
    var fontSize: CGFloat = 56
    var letterSpacing: CGFloat = 7
    var lineWidth: CGFloat = 0.8
    var repeats = false
    var reduceMotion = false
    var leading = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func makeNSView(context: Context) -> WorkbenchOutlinedTextView {
        WorkbenchOutlinedTextView(frame: .zero)
    }

    func updateNSView(_ view: WorkbenchOutlinedTextView, context: Context) {
        view.configure(text: text, fontSize: fontSize, letterSpacing: letterSpacing,
                       lineWidth: lineWidth, animates: repeats && !reduceMotion && !systemReduceMotion, leading: leading)
    }

    static func dismantleNSView(_ view: WorkbenchOutlinedTextView, coordinator: ()) {
        view.stopAnimating()
    }
}

final class WorkbenchOutlinedTextView: NSView {
    private let outline = CAShapeLayer()
    private let lightStroke = CAShapeLayer()
    private var sourcePath: CGPath?
    private var signature = ""
    private var animationAllowed = false
    private var leading = false
    // Only the main actor installs these tokens; deinit only unregisters them.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for shape in [outline, lightStroke] {
            shape.fillColor = NSColor.clear.cgColor
            shape.strokeColor = NSColor.white.cgColor
            shape.lineCap = .round
            shape.lineJoin = .round
            layer?.addSublayer(shape)
        }
        lightStroke.shadowColor = NSColor.white.cgColor
        lightStroke.shadowRadius = 1.3
        lightStroke.shadowOpacity = 0.65
        lightStroke.shadowOffset = .zero
        setAccessibilityElement(false)
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAnimationState() }
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func configure(text: String, fontSize: CGFloat, letterSpacing: CGFloat,
                   lineWidth: CGFloat, animates: Bool, leading: Bool = false) {
        if self.leading != leading { self.leading = leading; needsLayout = true }
        let newSignature = "\(text)|\(fontSize)|\(letterSpacing)"
        if signature != newSignature {
            signature = newSignature
            sourcePath = Self.glyphPath(text: text, fontSize: fontSize, letterSpacing: letterSpacing)
            needsLayout = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.lineWidth = lineWidth
        lightStroke.lineWidth = lineWidth + 0.45
        CATransaction.commit()
        animationAllowed = animates
        updateAnimationState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimationState()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateAnimationState()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimationState()
    }

    override func layout() {
        super.layout()
        guard let sourcePath else { return }
        let sourceBounds = sourcePath.boundingBoxOfPath
        guard sourceBounds.width > 0, sourceBounds.height > 0 else { return }
        let scale = min(1, max(0, bounds.width - outline.lineWidth) / sourceBounds.width, max(0, bounds.height - outline.lineWidth) / sourceBounds.height)
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                          tx: leading ? bounds.minX + outline.lineWidth / 2 - sourceBounds.minX * scale : bounds.midX - sourceBounds.midX * scale,
                                          ty: bounds.midY + sourceBounds.midY * scale)
        let path = sourcePath.copy(using: &transform)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [outline, lightStroke] {
            shape.frame = bounds
            shape.path = path
            shape.contentsScale = window?.backingScaleFactor ?? 2
        }
        CATransaction.commit()
        updateAnimationState()
    }

    func stopAnimating() {
        lightStroke.removeAnimation(forKey: "welcome-light-stroke")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.opacity = 0.94
        lightStroke.isHidden = true
        CATransaction.commit()
    }

    private func updateAnimationState() {
        guard animationAllowed, NSApp.isActive, !isHiddenOrHasHiddenAncestor,
              let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible) else {
            stopAnimating()
            return
        }
        guard lightStroke.animation(forKey: "welcome-light-stroke") == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.opacity = 0.72
        lightStroke.isHidden = false
        CATransaction.commit()
        let end = CAKeyframeAnimation(keyPath: "strokeEnd")
        end.values = [0, 1, 1]
        end.keyTimes = [0, 0.25, 1]
        let start = CAKeyframeAnimation(keyPath: "strokeStart")
        start.values = [0, 0, 1, 1]
        start.keyTimes = [0, 0.045, 0.30, 1]
        let group = CAAnimationGroup()
        group.animations = [end, start]
        group.duration = 10
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lightStroke.add(group, forKey: "welcome-light-stroke")
    }

    private static func glyphPath(text: String, fontSize: CGFloat, letterSpacing: CGFloat) -> CGPath {
        let font = NSFont(name: "Kaiti SC", size: fontSize) ?? NSFont(name: "STKaiti", size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .light)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .kern: letterSpacing])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let result = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = Array(repeating: CGGlyph(), count: count)
            var positions = Array(repeating: CGPoint.zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            for index in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                result.addPath(glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
            }
        }
        return result
    }
}
