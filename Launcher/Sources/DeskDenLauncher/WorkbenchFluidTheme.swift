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
