import AppKit
import SwiftUI
import LauncherCore

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
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            HomeBackdropBlur(light: scheme == .light).opacity(scheme == .light ? 0.35 : 0.14)
            if scheme == .light {
            LinearGradient(stops: [
                .init(color: .white.opacity(0.95), location: 0),
                .init(color: .white.opacity(0.87), location: 0.70),
                .init(color: Color(red: 244 / 255, green: 252 / 255, blue: 253 / 255).opacity(0.83), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                LinearGradient(colors: [Color(red: 0.10, green: 0.14, blue: 0.16).opacity(0.86),
                                        Color(red: 0.035, green: 0.07, blue: 0.085).opacity(0.81)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(scheme == .light ? 0.69 : 0.23), lineWidth: 1))
        .shadow(color: Color(red: 22 / 255, green: 71 / 255, blue: 87 / 255).opacity(0.04), radius: 4, y: 2)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct HomeBackdropBlur: NSViewRepresentable {
    var light: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = HomePassthroughEffect()
        view.blendingMode = .withinWindow
        view.material = .underWindowBackground
        view.state = .active
        view.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    }
}
private final class HomePassthroughEffect: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Match the approved image's cover crop, including its slightly raised focal point.
struct WorkbenchFluidBackground: View {
    private static let image: NSImage? = Bundle.main.url(forResource: "cyan-amber", withExtension: "jpg", subdirectory: "Workbench")
        .flatMap(NSImage.init(contentsOf:))
    var body: some View {
        GeometryReader { geometry in
            if let image = Self.image {
                let scale = max(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                let width = image.size.width * scale, height = image.size.height * scale
                Image(nsImage: image).resizable()
                    .frame(width: width, height: height)
                    .position(x: geometry.size.width / 2, y: height / 2 + (geometry.size.height - height) * 0.43)
            } else {
                Color(red: 6 / 255, green: 113 / 255, blue: 140 / 255)
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}
