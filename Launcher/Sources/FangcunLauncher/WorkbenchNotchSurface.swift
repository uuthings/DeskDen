import AppKit
import QuartzCore
import SwiftUI

/// One direct transition from the physical notch to the mini dashboard.
/// The content stays at its final size and is revealed by the animated mask, so text
/// never stretches or reflows during the shape transition.
@MainActor final class WorkbenchNotchSurface: NSView {
    enum Phase { case closed, expanded }
    override var isFlipped: Bool { true }
    private let shell = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let contentMask = CAShapeLayer()
    private let materialContainer = FlippedView()
    private let glass = GlassBackgroundView()
    private let materialMask = CAShapeLayer()
    private let sceneLayer = CALayer()
    private let sceneTone = CAGradientLayer()
    private(set) var theme = Palette.workbenchTheme
    private var host: NSView?
    private(set) var phase: Phase = .closed
    let closedSize: CGSize
    let expandedSize: CGSize
    let contentTopInset: CGFloat
    private(set) var targetBounds: CGRect = .zero

    init(size: CGSize, notchWidth: CGFloat, safeTop: CGFloat) {
        expandedSize = size
        closedSize = CGSize(width: min(size.width, notchWidth), height: max(3, safeTop))
        contentTopInset = max(8, safeTop) + 8
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        shell.fillColor = NSColor.clear.cgColor
        outline.fillColor = nil
        outline.strokeColor = NSColor(Palette.workbenchPalette.border).cgColor
        outline.lineWidth = 1
        layer?.addSublayer(shell)
        layer?.addSublayer(outline)
        materialContainer.frame = bounds
        materialContainer.wantsLayer = true
        materialContainer.layer?.mask = materialMask
        sceneLayer.frame = bounds
        sceneLayer.contentsGravity = .resizeAspectFill
        sceneLayer.masksToBounds = true
        materialContainer.layer?.addSublayer(sceneLayer)
        sceneTone.frame = bounds
        sceneTone.startPoint = CGPoint(x: 0, y: 0)
        sceneTone.endPoint = CGPoint(x: 1, y: 1)
        materialContainer.layer?.addSublayer(sceneTone)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        glass.surfaceStyle = .workbench
        glass.blendingMode = .withinWindow
        glass.radius = 0
        glass.drawsBorder = false
        materialContainer.addSubview(glass)
        addSubview(materialContainer)
        refreshAppearance()
        setPhase(.closed, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func refreshAppearance() {
        appearance = NSAppearance(named: Palette.isLight ? .aqua : .darkAqua)
        glass.refreshAppearance()
        theme = Palette.workbenchTheme
        outline.strokeColor = NSColor(Palette.workbenchPalette.line).cgColor
        if let image=WorkbenchSceneAssets.image(for:Palette.workbenchTheme) {
            sceneLayer.contents=image.cgImage(forProposedRect:nil,context:nil,hints:nil)
        } else {sceneLayer.contents=nil}
        sceneLayer.frame=bounds
        // The same scene remains stationary. A quiet, theme-derived veil gives
        // the compact readings a consistent surface above bright horizons.
        sceneTone.frame = bounds
        sceneTone.colors = [NSColor(Palette.workbenchPalette.chrome).withAlphaComponent(Palette.isLight ? 0.16 : 0.20).cgColor,
                            NSColor(Palette.workbenchPalette.surface).withAlphaComponent(Palette.isLight ? 0.22 : 0.28).cgColor]
    }
    var materialOpacity: Double { Palette.glassOpacity }
    var usesLightAppearance: Bool { appearance?.name == .aqua }

    func setContent(_ view: NSView) {
        host?.removeFromSuperview()
        host = view
        view.frame = CGRect(x: 34, y: contentTopInset, width: expandedSize.width - 68,
                            height: expandedSize.height - contentTopInset - 16)
        view.wantsLayer = true
        view.layer?.opacity = 0
        addSubview(view)
        // Start at the currently visible contour, including a partially reversed
        // animation; a first-open content mask must not jump straight to full size.
        var transform = CGAffineTransform(translationX: -view.frame.minX, y: -view.frame.minY)
        contentMask.removeAllAnimations()
        contentMask.path = (shell.presentation()?.path ?? shell.path)?.copy(using: &transform)
        view.layer?.mask = contentMask
    }

    var presentationBounds: CGRect {
        (shell.presentation()?.path ?? shell.path)?.boundingBoxOfPath ?? targetBounds
    }
    func containsVisiblePoint(_ point: CGPoint) -> Bool {
        (shell.presentation()?.path ?? shell.path)?.contains(point) == true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard phase == .expanded, containsVisiblePoint(point) else { return nil }
        return super.hitTest(point)
    }

    func setPhase(_ phase: Phase, animated: Bool) {
        self.phase = phase
        let size = phase == .expanded ? expandedSize : closedSize
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        targetBounds = rect
        let path = Self.path(in: rect, shoulder: phase == .expanded ? 16 : 6,
                             bottom: phase == .expanded ? 20 : 13)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration: TimeInterval = !animated ? 0 : reduce ? 0.10 : 0.32
        let fadeWithoutClipping = reduce && animated && phase == .closed
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if !fadeWithoutClipping {
            animatePath(shell, to: path, duration: reduce ? 0 : duration, spring: phase == .expanded && !reduce)
            animatePath(outline, to: path, duration: reduce ? 0 : duration, spring: phase == .expanded && !reduce)
            animatePath(materialMask, to: path, duration: reduce ? 0 : duration, spring: phase == .expanded && !reduce)
        }
        if reduce {
            if phase != .closed { shell.opacity = 0; outline.opacity = 0 }
            animateOpacity(shell, to: phase == .closed ? 0 : 1, duration: duration)
            animateOpacity(outline, to: phase == .closed ? 0 : 1, duration: duration)
            animateOpacity(materialContainer.layer, to: phase == .closed ? 0 : 1, duration: duration)
        } else { shell.opacity = 1; outline.opacity = 1; materialContainer.layer?.opacity = 1 }
        if let host {
            var transform = CGAffineTransform(translationX: -host.frame.minX, y: -host.frame.minY)
            let translated = path.copy(using: &transform) ?? path
            if !fadeWithoutClipping {
                animatePath(contentMask, to: translated, duration: reduce ? 0 : duration, spring: phase == .expanded && !reduce)
            }
            animateOpacity(host.layer, to: phase == .expanded ? 1 : 0,
                           duration: duration == 0 ? 0 : reduce ? duration : phase == .expanded ? 0.20 : 0.08,
                           delay: phase == .expanded && !reduce && animated ? 0.06 : 0)
        }
        CATransaction.commit()
    }

    private func animatePath(_ target: CAShapeLayer, to path: CGPath, duration: TimeInterval, spring: Bool) {
        let from = target.presentation()?.path ?? target.path ?? path
        target.removeAnimation(forKey: "shape")
        target.path = path
        guard duration > 0 else { return }
        let animation: CABasicAnimation
        if spring {
            let bounce = CASpringAnimation(keyPath: "path")
            bounce.mass = 1; bounce.stiffness = 280; bounce.damping = 29
            animation = bounce
        } else {
            animation = CABasicAnimation(keyPath: "path")
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        }
        animation.fromValue = from; animation.toValue = path; animation.duration = duration
        target.add(animation, forKey: "shape")
    }
    private func animateOpacity(_ target: CALayer?, to opacity: Float, duration: TimeInterval, delay: TimeInterval = 0) {
        guard let target else { return }
        let from = target.presentation()?.opacity ?? target.opacity
        target.removeAnimation(forKey: "visibility"); target.opacity = opacity
        guard duration > 0 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = opacity; fade.duration = duration
        fade.beginTime = CACurrentMediaTime() + delay; fade.fillMode = .backwards
        target.add(fade, forKey: "visibility")
    }
    /// Inward shoulders meet the physical screen edge; only the lower corners are convex.
    private static func path(in rect: CGRect, shoulder: CGFloat, bottom: CGFloat) -> CGPath {
        let s = min(shoulder, rect.height / 3), b = min(bottom, rect.height / 2)
        let l = rect.minX, r = rect.maxX, t = rect.minY, d = rect.maxY
        let p = CGMutablePath()
        p.move(to: CGPoint(x: l, y: t))
        p.addLine(to: CGPoint(x: r, y: t))
        p.addCurve(to: CGPoint(x: r - s, y: t + s), control1: CGPoint(x: r - s, y: t), control2: CGPoint(x: r - s, y: t))
        p.addLine(to: CGPoint(x: r - s, y: d - b))
        p.addQuadCurve(to: CGPoint(x: r - s - b, y: d), control: CGPoint(x: r - s, y: d))
        p.addLine(to: CGPoint(x: l + s + b, y: d))
        p.addQuadCurve(to: CGPoint(x: l + s, y: d - b), control: CGPoint(x: l + s, y: d))
        p.addLine(to: CGPoint(x: l + s, y: t + s))
        p.addCurve(to: CGPoint(x: l, y: t), control1: CGPoint(x: l + s, y: t), control2: CGPoint(x: l + s, y: t))
        p.closeSubpath()
        return p
    }
}
