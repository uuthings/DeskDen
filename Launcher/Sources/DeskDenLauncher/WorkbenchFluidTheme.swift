import AppKit
import SwiftUI
import LauncherCore

/// Registers only the independently animated header control, without searching
/// the accessibility tree or attaching another mouse-tracking surface.
struct WorkbenchAppearanceLiveRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkbenchAppearanceLiveRegionView {
        WorkbenchAppearanceLiveRegionView(frame: .zero)
    }
    func updateNSView(_ view: WorkbenchAppearanceLiveRegionView, context: Context) {}
}

@MainActor final class WorkbenchAppearanceLiveRegionView: NSView {
    private static let registered = NSHashTable<WorkbenchAppearanceLiveRegionView>.weakObjects()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        Self.registered.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    static func regions(in content: NSView) -> [WorkbenchAppearanceLiveRegionView] {
        registered.allObjects.filter {
            $0.window === content.window && $0.isDescendant(of: content) && !$0.isHiddenOrHasHiddenAncestor
                && $0.bounds.width > 0 && $0.bounds.height > 0
        }
    }
}

/// Blend a cached presentation over the live view. Data, focus and navigation
/// remain in one view tree; only the compositor animates during theme changes.
@MainActor final class WorkbenchAppearanceTransition: NSView {
    static let duration: TimeInterval = 0.34
    private(set) var liveRegionFrames: [CGRect] = []
    static func capture(_ window: NSWindow?, reduceMotion: Bool) -> WorkbenchAppearanceTransition? {
        guard let window, let content = window.contentView else { return nil }
        // A quick second toggle must sample the live scene, not the fading
        // screenshot from its preceding toggle. This also clears an in-flight
        // fade when Reduce Motion is enabled before the next appearance change.
        content.subviews.compactMap { $0 as? WorkbenchAppearanceTransition }.forEach {
            $0.layer?.removeAllAnimations(); $0.removeFromSuperview()
        }
        guard !reduceMotion, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              window.isVisible,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }
        let overlay = WorkbenchAppearanceTransition(frame: content.bounds)
        overlay.autoresizingMask = [.width, .height]; overlay.wantsLayer = true
        overlay.layer?.contents = image; overlay.layer?.contentsGravity = .resize
        overlay.layer?.contentsScale = window.backingScaleFactor
        overlay.setAccessibilityElement(false)
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.updateLiveRegionMask()
        return overlay
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        updateLiveRegionMask()
    }
    private func updateLiveRegionMask() {
        guard let content = superview, let layer else { return }
        liveRegionFrames = WorkbenchAppearanceLiveRegionView.regions(in: content).map {
            $0.convert($0.bounds, to: self).insetBy(dx: -2, dy: -2).intersection(bounds)
        }.filter { !$0.isEmpty }
        guard !liveRegionFrames.isEmpty else { layer.mask = nil; return }
        let path = CGMutablePath()
        path.addRect(bounds)
        liveRegionFrames.forEach { path.addEllipse(in: $0) }
        let mask = CAShapeLayer()
        mask.frame = bounds; mask.path = path; mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.mask = mask
        CATransaction.commit()
    }
    func finish() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.superview != nil, let layer = self.layer else { return }
            self.superview?.layoutSubtreeIfNeeded()
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = Self.duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.opacity = 0; layer.add(fade, forKey: "appearanceTransition")
            CATransaction.commit()
        }
    }
}

/// The approved milky surface and the dark glass surface share semantic colors.
enum HomeFluidPalette {
    static let light = ThemePalette(theme: .qingbiMist, opacity: 0.87, light: true)
    static let onWhiteInk = Color(red: 23 / 255, green: 45 / 255, blue: 51 / 255)
    static let ink = adaptive(0x172D33, 0xF3FCFF)
    static let secondary = adaptive(0x50676D, 0xD4E2E6)
    static let muted = adaptive(0x62757A, 0xB4C6CC)
    static let green = adaptive(0x197460, 0x8BEAD1)
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

struct WorkbenchHomeSurface: View {
    var radius: CGFloat = 15
    var body: some View {
        WorkbenchMaterialSurface(radius: radius)
    }
}

@MainActor enum WorkbenchFluidAssets {
    private static var images: [Bool: NSImage] = [:]
    static func url(light: Bool) -> URL? {
        Bundle.main.url(forResource: light ? "cyan-amber" : "ink-gold", withExtension: "jpg", subdirectory: "Workbench")
    }
    static func image(light: Bool) -> NSImage? {
        if let image = images[light] { return image }
        guard let image = url(light: light).flatMap(NSImage.init(contentsOf:)) else { return nil }
        images[light] = image
        return image
    }
}

/// Match the approved image's cover crop, including its slightly raised focal point.
struct WorkbenchFluidBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            if let image = WorkbenchFluidAssets.image(light: scheme == .light) {
                let scale = max(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                let width = image.size.width * scale, height = image.size.height * scale
                Image(nsImage: image).resizable()
                    .frame(width: width, height: height)
                    .position(x: geometry.size.width / 2, y: height / 2 + (geometry.size.height - height) * (scheme == .light ? 0.43 : 0.5))
            } else {
                scheme == .light ? Color(red: 6 / 255, green: 113 / 255, blue: 140 / 255) : .black
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}
