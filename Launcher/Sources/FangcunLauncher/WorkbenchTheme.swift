import AppKit
import LauncherCore
import SwiftUI

/// Color tokens transcribed from the accepted V5 CSS after its final material
/// overrides. Surface opacity never affects text, icons, or business readings.
struct ThemePalette: Sendable {
    let theme: LauncherTheme
    let opacity: Double
    let light: Bool

    init(theme: LauncherTheme = .arWorld, opacity: Double = 0.70, light: Bool = false) {
        self.theme = theme
        self.opacity = opacity.isFinite ? min(0.90, max(0.50, opacity)) : 0.70
        self.light = light
    }

    private var ar: Bool { theme == .arWorld }
    var nsText: NSColor { color(light ? (ar ? 0x0E3347 : 0x2C302F) : (ar ? 0xF3FCFF : 0xF3F0E9)) }
    var nsSecondary: NSColor { color(light ? (ar ? 0x274F62 : 0x55534B) : (ar ? 0xE1F2FF : 0xE5DFD3)) }
    var nsMuted: NSColor { color(light ? (ar ? 0x48697B : 0x6C685E) : (ar ? 0xC8E4F3 : 0xC7C2B7)) }
    var nsAccent: NSColor { color(light ? (ar ? 0x137A94 : 0x8B652C) : (ar ? 0x88EDFF : 0xE1BB7B)) }
    var text: Color { Color(nsColor: nsText) }
    var secondary: Color { Color(nsColor: nsSecondary) }
    var muted: Color { Color(nsColor: nsMuted) }
    var accent: Color { Color(nsColor: nsAccent) }
    var cool: Color { token(light ? (ar ? 0x655CA8 : 0x39718C) : (ar ? 0xC4BEFF : 0x89B8D2)) }
    var success: Color { token(light ? (ar ? 0x117A60 : 0x347254) : (ar ? 0x91F4D3 : 0x9AD4B2)) }
    var warning: Color { token(light ? (ar ? 0x9E6113 : 0xA56B11) : (ar ? 0xFFDA93 : 0xEFB75D)) }
    var critical: Color { token(light ? (ar ? 0xB03851 : 0xAF443D) : (ar ? 0xFFBBC8 : 0xF4A59B)) }
    var surface: Color { token(light ? (ar ? 0xD8EFF8 : 0xECE8DF) : (ar ? 0x0F304A : 0x1E242A), opacity) }
    var raised: Color { token(light ? (ar ? 0xF5FDFF : 0xFFFBF2) : (ar ? 0x245470 : 0x3E4448), opacity) }
    var border: Color { light ? token(0xFFFFFF, 0.85) : token(ar ? 0xB3EAFF : 0xE4D8BA, ar ? 112 / 255.0 : 89 / 255.0) }
    var line: Color { light ? token(ar ? 0x1F5D7C : 0x706445, 0.18) : token(ar ? 0xC2EDFF : 0xDED5BF, ar ? 61 / 255.0 : 54 / 255.0) }
    var primary: Color { token(light ? (ar ? 0x175F7B : 0x8A642C) : (ar ? 0x97EDFF : 0xDFBB80)) }
    var primaryText: Color { light ? .white : token(ar ? 0x06415A : 0x2B2923) }
    var overlay: Color { token(light ? (ar ? 0xF2FAFD : 0xF9F5EA) : (ar ? 0x11364F : 0x232A2F), min(0.97, opacity + 0.16)) }
    var sidebar: Color { token(light ? (ar ? 0xDAEEF7 : 0xEBE6DB) : (ar ? 0x0C2D45 : 0x181F26), opacity * 0.82) }
    var chrome: Color { token(light ? (ar ? 0xE6F6FC : 0xF2EDDF) : (ar ? 0x11344D : 0x1A2026), opacity * 0.92) }
    var shell: Color { token(light ? (ar ? 0xD8EEF7 : 0xEEE6D5) : (ar ? 0x082C46 : 0x12181F), opacity * 0.34) }
    var navSelected: Color { token(light ? (ar ? 0x3BA5C2 : 0xB28A4B) : (ar ? 0x8ADFF5 : 0xC19D5E), opacity * (ar ? 0.42 : 0.48)) }
    var navBorder: Color { light ? accent.opacity(0.34) : token(ar ? 0xC7F4FF : 0xEAD3A7, ar ? 112 / 255.0 : 103 / 255.0) }
    var soft: Color { token(ar ? 0x7BE5FF : 0xE2C28E, ar ? 20 / 255.0 : 22 / 255.0) }
    var control: Color { light ? raised : ar ? token(0x89D8F1, 25 / 255.0) : raised }
    var controlBorder: Color { light ? accent.opacity(0.30) : ar ? token(0xD1F5FF, 80 / 255.0) : line }
    var progressTrack: Color { light ? accent.opacity(0.14) : token(ar ? 0xCFEDFF : 0xD2BE8F, ar ? 46 / 255.0 : 27 / 255.0) }
    var shadow: Color { token(ar ? 0x002139 : 0x090D10, ar ? 33 / 255.0 : 56 / 255.0) }
    var highlight: Color { token(ar ? 0xE1FBFF : 0xFFF4CE, ar ? 0.20 : 0.075) }

    var surfaceGradient: LinearGradient {
        LinearGradient(colors: [raised, surface], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var navSelectedGradient: LinearGradient {
        LinearGradient(colors: [navSelected, token(ar ? 0x228EB2 : 0x625541, opacity * (ar ? 0.24 : 0.28))], startPoint: .leading, endPoint: .trailing)
    }

    private func token(_ hex: UInt32, _ alpha: Double = 1) -> Color { Color(nsColor: color(hex, alpha)) }
    private func color(_ hex: UInt32, _ alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: alpha)
    }
}

private struct WorkbenchThemeKey: EnvironmentKey { static let defaultValue: LauncherTheme = .arWorld }
private struct WorkbenchOpacityKey: EnvironmentKey { static let defaultValue = 0.70 }
private struct WorkbenchBackgroundMotionKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var workbenchTheme: LauncherTheme {
        get { self[WorkbenchThemeKey.self] }
        set { self[WorkbenchThemeKey.self] = newValue }
    }
    var workbenchOpacity: Double {
        get { self[WorkbenchOpacityKey.self] }
        set { self[WorkbenchOpacityKey.self] = newValue }
    }
    var workbenchBackgroundMotion: Bool {
        get { self[WorkbenchBackgroundMotionKey.self] }
        set { self[WorkbenchBackgroundMotionKey.self] = newValue }
    }
    var workbenchPalette: ThemePalette { ThemePalette(theme: workbenchTheme, opacity: workbenchOpacity, light: colorScheme == .light) }
}

extension View {
    func workbenchThemeEnvironment(theme: LauncherTheme, opacity: Double, backgroundMotion: Bool = true, appearance: LauncherAppearance = .dark) -> some View {
        modifier(WorkbenchThemeEnvironmentModifier(theme: theme, opacity: opacity, backgroundMotion: backgroundMotion, appearance: appearance))
    }
}

private struct WorkbenchThemeEnvironmentModifier: ViewModifier {
    let theme: LauncherTheme
    let opacity: Double
    let backgroundMotion: Bool
    let appearance: LauncherAppearance
    @Environment(\.colorScheme) private var systemScheme
    func body(content: Content) -> some View {
        let light = appearance == .light || (appearance == .system && systemScheme == .light)
        content.environment(\.workbenchTheme, theme)
            .environment(\.workbenchOpacity, ThemePalette(theme: theme, opacity: opacity).opacity)
            .environment(\.workbenchBackgroundMotion, backgroundMotion)
            .preferredColorScheme(appearance == .system ? nil : appearance == .light ? .light : .dark)
            .tint(ThemePalette(theme: theme, opacity: opacity, light: light).accent)
    }
}

/// A single reusable material for pages, navigation, popovers, and Mini. The
/// visual effect samples the app's own scene; the approved tint supplies the
/// readable 50–90% surface, independently from the foreground content.
struct WorkbenchMaterialSurface: View {
    enum Kind { case card, panel, chrome, sidebar, shell, control, selected }
    var kind: Kind = .card
    var radius: CGFloat = 15
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if kind == .card || kind == .panel || kind == .selected {
                WorkbenchBackdropBlur().opacity(kind == .panel ? 0.24 : 0.14)
            }
            switch kind {
            case .card: shape.fill(palette.surfaceGradient)
            case .panel: shape.fill(palette.overlay)
            case .chrome: shape.fill(palette.chrome)
            case .sidebar: shape.fill(palette.sidebar)
            case .shell: shape.fill(palette.shell)
            case .control: shape.fill(palette.control)
            case .selected: shape.fill(palette.navSelectedGradient)
            }
        }
        .clipShape(shape)
        .overlay {
            if kind == .card || kind == .panel {
                shape.strokeBorder(palette.border, lineWidth: 1)
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [.clear, palette.highlight, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(height: 1).padding(.horizontal, radius)
                    }
            } else if kind == .selected {
                shape.strokeBorder(palette.navBorder, lineWidth: 1)
            }
        }
        .shadow(color: kind == .card || kind == .panel ? palette.shadow : .clear, radius: kind == .panel ? 16 : 7, x: 0, y: kind == .panel ? 12 : 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WorkbenchBackdropBlur: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = WorkbenchPassthroughVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .underWindowBackground
        view.state = .active
        view.isEmphasized = false
        view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua) }
}

private final class WorkbenchPassthroughVisualEffectView:NSVisualEffectView {
    override func hitTest(_ point:NSPoint)->NSView? {nil}
}

/// Both shipped scene images are static and cropped with CSS-equivalent cover.
/// Only the separate decorative layer animates, so controls and text do not
/// drift. Removing TimelineView while paused stops decoration work entirely.
struct WorkbenchSceneBackground: View {
    var theme: LauncherTheme = .arWorld
    var motionEnabled = true
    var active = true
    @Environment(\.workbenchOpacity) private var opacity
    @Environment(\.workbenchBackgroundMotion) private var environmentMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var applicationActive = NSApplication.shared.isActive

    private var running: Bool { active && applicationActive && motionEnabled && environmentMotion && !reduceMotion }

    var body: some View {
        let palette = ThemePalette(theme: theme, opacity: opacity, light: scheme == .light)
        GeometryReader { geometry in
            ZStack {
                if let image = WorkbenchSceneAssets.image(for: theme) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    // Packaging validation must catch this; avoid reading from
                    // a developer's design directory in the installed app.
                    Color(nsColor: NSColor(srgbRed: 8 / 255.0, green: 44 / 255.0, blue: 70 / 255.0, alpha: 1))
                }
                if running {
                    TimelineView(.animation(minimumInterval: 1 / 20.0)) { timeline in
                        WorkbenchAmbientDecoration(theme: theme, time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
                palette.shell
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in applicationActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in applicationActive = false }
    }
}

@MainActor enum WorkbenchSceneAssets {
    private static var images: [LauncherTheme: NSImage] = [:]
    static func url(for theme: LauncherTheme) -> URL? {
        Bundle.main.url(forResource: theme.backgroundResource, withExtension: "jpg", subdirectory: "Workbench")
            ?? Bundle.main.url(forResource: theme.backgroundResource, withExtension: "jpg")
    }
    static func image(for theme: LauncherTheme) -> NSImage? {
        if let image = images[theme] { return image }
        guard let image = url(for: theme).flatMap(NSImage.init(contentsOf:)) else { return nil }
        images[theme] = image
        return image
    }
}

private struct WorkbenchAmbientDecoration: View {
    let theme: LauncherTheme
    let time: TimeInterval

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let light = Color(red: 139 / 255.0, green: theme == .arWorld ? 241 / 255.0 : 200 / 255.0, blue: 1)
            if theme == .arWorld {
                screen(context: &context, size: size, fraction: CGRect(x: 0.015, y: 0.30, width: 0.12, height: 0.15), phase: time + 3, duration: 16, light: light)
                screen(context: &context, size: size, fraction: CGRect(x: 0.792, y: 0.09, width: 0.19, height: 0.17), phase: time + 9, duration: 20, light: light)
                screen(context: &context, size: size, fraction: CGRect(x: 0.865, y: 0.79, width: 0.10, height: 0.13), phase: time + 14, duration: 18, light: light)
                ray(context: &context, size: size, x: 0.02, y: 0.16, width: 0.18, phase: time + 4, duration: 13, light: light)
                ray(context: &context, size: size, x: 0.66, y: 0.87, width: 0.26, phase: time + 10, duration: 18, light: light)
                let orbit = CGRect(x: size.width * 0.08, y: size.height * 0.94 - 72, width: 72, height: 72)
                context.stroke(Path(ellipseIn: orbit), with: .color(light.opacity(0.068)), lineWidth: 1)
                context.stroke(Path(ellipseIn: orbit.insetBy(dx: 8, dy: 8)), with: .color(light.opacity(0.052)), lineWidth: 1)
                var arc = Path()
                arc.addArc(center: CGPoint(x: orbit.midX, y: orbit.midY), radius: 37, startAngle: .degrees(time.truncatingRemainder(dividingBy: 36) * 10), endAngle: .degrees(time.truncatingRemainder(dividingBy: 36) * 10 + 80), clockwise: false)
                context.stroke(arc, with: .color(light.opacity(0.20)), lineWidth: 2)
            } else {
                instrument(context: &context, center: CGPoint(x: size.width * 0.075, y: size.height * 0.15), radius: 2.5, phase: time + 3, duration: 8, light: light)
                instrument(context: &context, center: CGPoint(x: size.width * 0.92, y: size.height * 0.86), radius: 2, phase: time + 6, duration: 11, light: Color(red: 1, green: 206 / 255.0, blue: 146 / 255.0))
                let pulse = wave(time, duration: 15)
                let rect = CGRect(x: size.width * 0.95, y: size.height * 0.10 + pulse * 18, width: 1, height: size.height * 0.22)
                context.fill(Path(rect), with: .linearGradient(Gradient(colors: [.clear, light.opacity(0.15 + 0.25 * pulse), .clear]), startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            }
        }
        .allowsHitTesting(false)
    }

    private func screen(context: inout GraphicsContext, size: CGSize, fraction: CGRect, phase: Double, duration: Double, light: Color) {
        let pulse = wave(phase, duration: duration)
        let rect = CGRect(x: fraction.minX * size.width, y: fraction.minY * size.height - pulse * 7, width: fraction.width * size.width, height: fraction.height * size.height)
        let strength = 0.36 + pulse * 0.20
        context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(light.opacity(0.24 * strength)), lineWidth: 1)
        var top = Path(); top.move(to: CGPoint(x: rect.minX, y: rect.minY)); top.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        context.stroke(top, with: .color(light.opacity(0.55 * strength)), lineWidth: 1)
        for (row, width) in [(0.27, 0.56), (0.46, 0.70), (0.65, 0.42)] {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * row))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * (0.12 + width), y: rect.minY + rect.height * row))
            context.stroke(path, with: .color(light.opacity(0.24 * strength)), lineWidth: 1)
        }
    }
    private func ray(context: inout GraphicsContext, size: CGSize, x: Double, y: Double, width: Double, phase: Double, duration: Double, light: Color) {
        let progress = phase.truncatingRemainder(dividingBy: duration) / duration
        let rect = CGRect(x: size.width * x - 24 + 134 * progress, y: size.height * y, width: size.width * width, height: 1)
        context.fill(Path(rect), with: .linearGradient(Gradient(colors: [.clear, light.opacity(0.25 * sin(progress * .pi)), .clear]), startPoint: CGPoint(x: rect.minX, y: rect.midY), endPoint: CGPoint(x: rect.maxX, y: rect.midY)))
    }
    private func instrument(context: inout GraphicsContext, center: CGPoint, radius: CGFloat, phase: Double, duration: Double, light: Color) {
        let strength = 0.22 + 0.30 * wave(phase, duration: duration)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(light.opacity(strength * 0.12)))
        context.fill(Path(ellipseIn: rect), with: .color(light.opacity(strength * 0.75)))
    }
    private func wave(_ time: Double, duration: Double) -> Double { (1 - cos(time / duration * 2 * .pi)) / 2 }
}
