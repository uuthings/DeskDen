import AppKit
import QuartzCore
import SwiftUI

/// The compact Mini has one fixed-height information row below the screen's
/// hardware safe area. Header controls occupy the two sides of that area.
enum WorkbenchMiniLayout {
    static let sectionHeight: CGFloat = 148
    static let headerHeight: CGFloat = 28
    static let headerTop: CGFloat = 4
    static let horizontalInset: CGFloat = 34
    static let bottomInset: CGFloat = 12
    static let minimumWidth: CGFloat = 480
    static let maximumWidth: CGFloat = 760
    static let shoulderWidth: CGFloat = 22
    static let shoulderDepth: CGFloat = 26
    static let bottomRadius: CGFloat = 18

    static func contentTopInset(safeTop: CGFloat) -> CGFloat {
        max(40, (safeTop.isFinite ? max(0, safeTop) : 0) + 8)
    }

    static func size(sectionCount: Int, screenWidth: CGFloat, safeTop: CGFloat, notchWidth: CGFloat) -> CGSize {
        // Reserve both header wings around the actual camera, including its
        // safe margin. Hide sections without stretching the remaining regions.
        let headerMinimum = max(minimumWidth, notchWidth + 300)
        let desired = horizontalInset * 2 + CGFloat(max(1, sectionCount)) * 168 + CGFloat(max(0, sectionCount - 1)) * 8
        let width = min(maximumWidth, max(headerMinimum, desired), max(320, screenWidth - 32))
        return CGSize(width: width, height: height(safeTop: safeTop))
    }

    static func height(safeTop: CGFloat) -> CGFloat {
        contentTopInset(safeTop: safeTop) + sectionHeight + bottomInset
    }
}

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
    private let glass = NSHostingView(rootView: AnyView(EmptyView()))
    private let materialMask = CAShapeLayer()
    private(set) var theme = Palette.workbenchTheme
    private var host: NSView?
    private(set) var phase: Phase = .closed
    let closedSize: CGSize
    let expandedSize: CGSize
    let contentTopInset: CGFloat
    private(set) var targetBounds: CGRect = .zero

    init(size: CGSize, notchWidth: CGFloat, safeTop: CGFloat) {
        expandedSize = size
        closedSize = CGSize(width: min(size.width, notchWidth > 0 ? notchWidth : 180), height: max(3, safeTop))
        contentTopInset = WorkbenchMiniLayout.contentTopInset(safeTop: safeTop)
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
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        materialContainer.addSubview(glass)
        addSubview(materialContainer)
        refreshAppearance()
        setPhase(.closed, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func refreshAppearance() {
        appearance = NSAppearance(named: Palette.isLight ? .aqua : .darkAqua)
        theme = Palette.workbenchTheme
        outline.strokeColor = NSColor(Palette.workbenchPalette.line).cgColor
        // A separate panel samples what is behind its window. An opaque scene
        // image underneath the tint would defeat the shared opacity setting.
        glass.rootView = AnyView(WorkbenchMaterialSurface(kind: .panel, radius: 0, behindWindow: true)
            .workbenchThemeEnvironment(theme: theme, opacity: Palette.glassOpacity, backgroundMotion: false,
                                      appearance: Palette.isLight ? .light : .dark))
    }
    var materialOpacity: Double { Palette.glassOpacity }
    var usesLightAppearance: Bool { appearance?.name == .aqua }

    func setContent(_ view: NSView) {
        host?.removeFromSuperview()
        host = view
        // The brand and actions sit beside the hardware notch. The root view
        // places its information row below contentTopInset; the whole host uses
        // the same animated contour so the two areas reveal together.
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
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

    func clearContent() {
        host?.removeFromSuperview(); host = nil
        contentMask.removeAllAnimations(); contentMask.path = nil
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
        let path = Self.path(in: rect,
                             shoulderWidth: phase == .expanded ? WorkbenchMiniLayout.shoulderWidth : 6,
                             shoulderDepth: phase == .expanded ? WorkbenchMiniLayout.shoulderDepth : 6,
                             bottom: phase == .expanded ? WorkbenchMiniLayout.bottomRadius : 13)
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
    private static func path(in rect: CGRect, shoulderWidth: CGFloat, shoulderDepth: CGFloat, bottom: CGFloat) -> CGPath {
        let s = min(shoulderWidth, rect.width / 4, rect.height / 3)
        let h = min(shoulderDepth, rect.height / 3)
        let b = min(bottom, (rect.width - 2 * s) / 2, rect.height / 2)
        // A quarter ellipse gives horizontal and vertical endpoint tangents,
        // avoiding the pinched bend where the wide top meets the straight side.
        let k: CGFloat = 0.5522847498
        let l = rect.minX, r = rect.maxX, t = rect.minY, d = rect.maxY
        let p = CGMutablePath()
        p.move(to: CGPoint(x: l, y: t))
        p.addLine(to: CGPoint(x: r, y: t))
        p.addCurve(to: CGPoint(x: r - s, y: t + h),
                   control1: CGPoint(x: r - k * s, y: t),
                   control2: CGPoint(x: r - s, y: t + h * (1 - k)))
        p.addLine(to: CGPoint(x: r - s, y: d - b))
        p.addQuadCurve(to: CGPoint(x: r - s - b, y: d), control: CGPoint(x: r - s, y: d))
        p.addLine(to: CGPoint(x: l + s + b, y: d))
        p.addQuadCurve(to: CGPoint(x: l + s, y: d - b), control: CGPoint(x: l + s, y: d))
        p.addLine(to: CGPoint(x: l + s, y: t + h))
        p.addCurve(to: CGPoint(x: l, y: t),
                   control1: CGPoint(x: l + s, y: t + h * (1 - k)),
                   control2: CGPoint(x: l + k * s, y: t))
        p.closeSubpath()
        return p
    }
}
