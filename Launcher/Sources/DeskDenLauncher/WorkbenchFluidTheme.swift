import AppKit
import SwiftUI
import LauncherCore

/// The home surface is deliberately fixed to the approved light treatment.
/// Other modules retain their existing theme until their own migration.
enum HomeFluidPalette {
    static let light = ThemePalette(theme: .qingbiMist, opacity: 0.87, light: true)
    static let ink = Color(red: 23 / 255, green: 45 / 255, blue: 51 / 255)
    static let secondary = Color(red: 80 / 255, green: 103 / 255, blue: 109 / 255)
    static let muted = Color(red: 98 / 255, green: 117 / 255, blue: 122 / 255)
    static let green = Color(red: 25 / 255, green: 116 / 255, blue: 96 / 255)
}

struct WorkbenchHomeSurface: View {
    var radius: CGFloat = 15
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            HomeBackdropBlur().opacity(0.35)
            LinearGradient(stops: [
                .init(color: .white.opacity(0.95), location: 0),
                .init(color: .white.opacity(0.87), location: 0.70),
                .init(color: Color(red: 244 / 255, green: 252 / 255, blue: 253 / 255).opacity(0.83), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.69), lineWidth: 1))
        .shadow(color: Color(red: 22 / 255, green: 71 / 255, blue: 87 / 255).opacity(0.04), radius: 4, y: 2)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct HomeBackdropBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = HomePassthroughEffect()
        view.blendingMode = .withinWindow
        view.material = .underWindowBackground
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
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
