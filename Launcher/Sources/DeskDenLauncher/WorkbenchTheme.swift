import AppKit
import LauncherCore
import SwiftUI

/// One approved material pair for every surface. Legacy theme/opacity values
/// remain decodable, but no longer select a different product color system.
struct ThemePalette: Sendable {
    let theme: LauncherTheme
    let opacity: Double
    let light: Bool

    init(theme: LauncherTheme = .qingbiMist, opacity: Double = 0.70, light: Bool = false) {
        self.theme = theme
        self.opacity = opacity.isFinite ? min(0.90, max(0.50, opacity)) : 0.70
        self.light = light
    }

    var nsText: NSColor { color(light ? 0x172D33 : 0xF3FCFF) }
    var nsSecondary: NSColor { color(light ? 0x50676D : 0xD4E2E6) }
    // Muted text keeps at least 4.5:1 on the light card; warning red is one
    // shared value for every page instead of a pink dark variant per module.
    var nsMuted: NSColor { color(light ? 0x5C6F74 : 0xB4C6CC) }
    var nsAccent: NSColor { color(light ? 0x197460 : 0x8BEAD1) }
    var text: Color { Color(nsColor: nsText) }
    var secondary: Color { Color(nsColor: nsSecondary) }
    var muted: Color { Color(nsColor: nsMuted) }
    var accent: Color { Color(nsColor: nsAccent) }
    var accentText: Color { light ? .white : token(0x103B32) }
    var cool: Color { token(light ? 0x655CA8 : 0xC4BEFF) }
    var success: Color { accent }
    var warning: Color { token(light ? 0x9E6113 : 0xFFDA93) }
    var critical: Color { token(light ? 0xBF3B37 : 0xF16C62) }
    var materialOpacity: Double { light ? 0.87 : 0.72 }
    var surface: Color { token(light ? 0xFFFFFF : 0x091116, materialOpacity) }
    var raised: Color { token(light ? 0xFFFFFF : 0x182127, light ? 0.95 : 0.78) }
    var border: Color { token(0xFFFFFF, light ? 0.69 : 0.23) }
    var line: Color { token(light ? 0x244D58 : 0xD4E2E6, light ? 0.12 : 0.16) }
    var primary: Color { token(light ? 0x2866D7 : 0x83B4FF) }
    var primaryText: Color { light ? .white : token(0x102644) }
    var calendarSelection: Color { token(light ? 0xAFCDFB : 0x456A9D) }
    var calendarSelectionText: Color { token(light ? 0x173964 : 0xF0F6FF) }
    var calendarToday: Color { light ? token(0x225BBE) : primary }
    var overlay: Color { surface }
    var sidebar: Color { surface }
    var chrome: Color { token(light ? 0xFFFFFF : 0x091116, light ? 0.10 : 0.24) }
    var shell: Color { .clear }
    var navSelected: Color { accent.opacity(light ? 0.12 : 0.14) }
    var navBorder: Color { accent.opacity(light ? 0.24 : 0.32) }
    var soft: Color { accent.opacity(0.08) }
    var control: Color { token(light ? 0xFFFFFF : 0xD4E2E6, light ? 0.66 : 0.07) }
    var controlBorder: Color { token(light ? 0x50676D : 0xD4E2E6, light ? 0.24 : 0.22) }
    var progressTrack: Color { token(light ? 0x3D7882 : 0x9EC6C1, light ? 0.12 : 0.13) }
    /// Backing for text placed outside cards: page titles and footnotes.
    var note: Color { token(light ? 0xFFFFFF : 0x091116, light ? 0.68 : 0.60) }
    var noteBorder: Color { token(0xFFFFFF, light ? 0.62 : 0.14) }
    var shadow: Color { token(0x061014, light ? 0.04 : 0.12) }
    var highlight: Color { token(0xFFFFFF, light ? 0.16 : 0.08) }

    var surfaceGradient: LinearGradient {
        LinearGradient(stops: [
            .init(color: raised, location: 0),
            .init(color: surface, location: 0.70),
            .init(color: token(light ? 0xF4FCFD : 0x091116, light ? 0.83 : 0.72), location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var navSelectedGradient: LinearGradient {
        LinearGradient(colors: [navSelected, accent.opacity(0.08)], startPoint: .leading, endPoint: .trailing)
    }

    private func token(_ hex: UInt32, _ alpha: Double = 1) -> Color { Color(nsColor: color(hex, alpha)) }
    private func color(_ hex: UInt32, _ alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: alpha)
    }
}

private struct WorkbenchThemeKey: EnvironmentKey { static let defaultValue: LauncherTheme = .qingbiMist }
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
            // Independent AppKit hosting views do not inherit the presenting
            // SwiftUI tree. Keep the actual palette in sync with the preference.
            .environment(\.colorScheme, light ? .light : .dark)
            .preferredColorScheme(appearance == .system ? nil : appearance == .light ? .light : .dark)
            .tint(ThemePalette(theme: theme, opacity: opacity, light: light).accent)
    }
}

/// A single reusable material for pages, navigation, popovers, and Mini. The
/// visual effect samples the app's own scene; the approved tint supplies the
/// readable 50–90% surface, independently from the foreground content.
struct WorkbenchMaterialSurface: View {
    enum Kind { case card, panel, chrome, sidebar, shell, control, selected, note }
    var kind: Kind = .card
    var radius: CGFloat = 15
    var behindWindow = false
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if kind == .card || kind == .panel || kind == .selected || kind == .note {
                // All surfaces share the scene material and tint. The modal
                // host softens the underlying page separately so translucent
                // panels do not expose competing, readable text.
                WorkbenchBackdropBlur(behindWindow: behindWindow)
                    .opacity(palette.light ? 0.35 : 0.14)
            }
            switch kind {
            case .card: shape.fill(palette.surfaceGradient)
            case .panel: shape.fill(palette.surfaceGradient)
            case .chrome: shape.fill(palette.chrome)
            case .sidebar: shape.fill(palette.sidebar)
            case .shell: shape.fill(palette.shell)
            case .control: shape.fill(palette.control)
            case .selected: shape.fill(palette.navSelectedGradient)
            case .note: shape.fill(palette.note)
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
            } else if kind == .note {
                shape.strokeBorder(palette.noteBorder, lineWidth: 1)
            }
        }
        .shadow(color: kind == .card || kind == .panel ? palette.shadow : .clear, radius: kind == .panel ? 16 : 4, x: 0, y: kind == .panel ? 8 : 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WorkbenchBackdropBlur: NSViewRepresentable {
    var behindWindow: Bool
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = WorkbenchPassthroughVisualEffectView()
        view.blendingMode = behindWindow ? .behindWindow : .withinWindow
        view.material = .underWindowBackground
        view.state = .active
        view.isEmphasized = false
        view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.blendingMode = behindWindow ? .behindWindow : .withinWindow
        view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
    }
}

private final class WorkbenchPassthroughVisualEffectView:NSVisualEffectView {
    override func hitTest(_ point:NSPoint)->NSView? {nil}
}

/// Compatibility entry for Mini and auxiliary windows; appearance chooses the
/// same artwork as the main window. There is no separate legacy scene effect.
struct WorkbenchSceneBackground: View {
    var theme: LauncherTheme = .qingbiMist
    var motionEnabled = false
    var active = true
    var body: some View { WorkbenchFluidBackground() }
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
