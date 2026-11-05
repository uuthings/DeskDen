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

/// A stable native boundary lets Core Animation cross-fade its already
/// composited scene. It never redraws SwiftUI into a CPU bitmap. Navigation
/// lives outside this layer, so the theme control flips independently.
struct WorkbenchAppearanceScene: NSViewRepresentable {
    let model: WorkbenchAppModel
    func makeNSView(context: Context) -> WorkbenchAppearanceSceneView {
        WorkbenchAppearanceSceneView(model: model)
    }
    func updateNSView(_ view: WorkbenchAppearanceSceneView, context: Context) {}
}

@MainActor final class WorkbenchAppearanceSceneView: NSHostingView<AnyView> {
    private static let registered = NSHashTable<WorkbenchAppearanceSceneView>.weakObjects()
    init(model: WorkbenchAppModel) {
        super.init(rootView: AnyView(WorkbenchSceneView(model: model).nativeCheckAccessibility()))
        wantsLayer = true
        sizingOptions = []
        Self.registered.add(self)
    }
    @MainActor required init(rootView: AnyView) { fatalError("init(rootView:) has not been implemented") }
    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func scene(in window: NSWindow) -> WorkbenchAppearanceSceneView? {
        registered.allObjects.first { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
    }
}

@MainActor enum WorkbenchAppearanceTransition {
    static let duration: TimeInterval = 0.34
    // Core Animation stores every CATransition under this reserved key,
    // regardless of the key passed to add(_:forKey:).
    static let key = kCATransition
    static func begin(_ window: NSWindow?, reduceMotion: Bool) -> CALayer? {
        guard let window, let layer = WorkbenchAppearanceSceneView.scene(in: window)?.layer else { return nil }
        // Replace rather than queue transitions. Reduced Motion also cancels
        // an existing fade, including one started before the setting changed.
        layer.removeAnimation(forKey: key)
        guard !reduceMotion, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              window.isVisible else { return nil }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: key)
        return layer
    }
    static func isRunning(in window: NSWindow) -> Bool {
        WorkbenchAppearanceSceneView.scene(in: window)?.layer?.animation(forKey: key) != nil
    }
}

/// Appearance-following entries for views that cannot read the environment
/// palette. Every value comes from ThemePalette; none is defined here.
enum HomeFluidPalette {
    static let light = ThemePalette(theme: .qingbiMist, opacity: 0.87, light: true)
    static let onWhiteInk = light.text
    static let ink = adaptive { $0.nsText }
    static let secondary = adaptive { $0.nsSecondary }
    static let muted = adaptive { $0.nsMuted }
    static let green = adaptive { $0.nsAccent }
    private static func adaptive(_ pick: @escaping @Sendable (ThemePalette) -> NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            pick(ThemePalette(light: appearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua))
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
