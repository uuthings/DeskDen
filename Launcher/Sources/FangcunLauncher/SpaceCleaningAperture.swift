import AppKit
import SwiftUI

/// Ambient document panes crossing a light slit. Geometry is decorative; progress
/// comes exclusively from the scanner and is rendered outside this canvas.
struct SpaceCleaningAperture: View {
    let active: Bool
    var scanning = false
    @Environment(\.workbenchPalette) private var palette

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var applicationActive = NSApplication.shared.isActive
    private var running: Bool { active && applicationActive && !systemReduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !running)) { timeline in
            Canvas { context, size in
                let time = running ? timeline.date.timeIntervalSinceReferenceDate : 2.7
                let scale = min(size.width / 600, size.height / 280)
                let center = CGPoint(x: size.width * 0.52, y: size.height * 0.50)
                let travel = (time / (scanning ? 5.4 : 10)).truncatingRemainder(dividingBy: 1)
                var glow = context
                glow.addFilter(.blur(radius: 22 * scale))
                glow.fill(Path(ellipseIn: CGRect(x: center.x - 170 * scale, y: center.y - 44 * scale, width: 340 * scale, height: 88 * scale)), with: .color(palette.accent.opacity(0.12)))
                for i in 0..<5 {
                    let position = (Double(i) + travel) / 5
                    let x = (position - 0.5) * 600 * scale
                    let visibility = max(0, 1 - pow(abs(position - 0.5) * 2, 3))
                    let proximity = max(0, 1 - abs(x) / (180 * scale))
                    var pane = context
                    pane.translateBy(x: center.x + x, y: center.y - x * 0.16)
                    pane.rotate(by: .degrees(-9))
                    let rect = CGRect(x: -38 * scale, y: -62 * scale, width: 76 * scale, height: 124 * scale)
                    let path = Path(roundedRect: rect, cornerRadius: 7 * scale)
                    pane.fill(path, with: .linearGradient(Gradient(colors: [palette.text.opacity(0.06 * visibility), palette.accent.opacity((0.05 + proximity * 0.13) * visibility)]), startPoint: rect.origin, endPoint: CGPoint(x: 0, y: rect.maxY)))
                    pane.stroke(path, with: .color(palette.text.opacity((0.12 + proximity * 0.30) * visibility)), lineWidth: 1)
                    pane.fill(Path(roundedRect: CGRect(x: -26 * scale, y: -45 * scale, width: 35 * scale, height: 4 * scale), cornerRadius: 2), with: .color(palette.text.opacity(0.24 * visibility)))
                    for line in 0..<3 {
                        pane.fill(Path(CGRect(x: -26 * scale, y: CGFloat(-24 + line * 9) * scale, width: CGFloat(48 - line * 6) * scale, height: 1.2 * scale)), with: .color(palette.text.opacity(0.16 * visibility)))
                    }
                    for bar in 0..<4 {
                        let height = CGFloat([7, 11, 6, 10][bar]) * scale
                        pane.fill(Path(CGRect(x: CGFloat(-26 + bar * 7) * scale, y: 42 * scale - height, width: 4 * scale, height: height)), with: .color(palette.accent.opacity((0.15 + proximity * 0.3) * visibility)))
                    }
                }
                var line = Path()
                line.move(to: CGPoint(x: center.x - 35 * scale, y: center.y + 136 * scale))
                line.addLine(to: CGPoint(x: center.x + 23 * scale, y: center.y - 136 * scale))
                var halo = context
                halo.addFilter(.blur(radius: 8 * scale))
                halo.stroke(line, with: .color(palette.accent.opacity(0.55)), lineWidth: 6 * scale)
                context.stroke(line, with: .linearGradient(Gradient(colors: [.clear, palette.accent, palette.text.opacity(0.9), .clear]), startPoint: CGPoint(x: center.x, y: center.y - 136 * scale), endPoint: CGPoint(x: center.x, y: center.y + 136 * scale)), lineWidth: 1.4 * scale)
                var horizon = Path()
                horizon.move(to: CGPoint(x: 20, y: center.y + size.width * 0.08))
                horizon.addLine(to: CGPoint(x: size.width - 20, y: center.y - size.width * 0.08))
                context.stroke(horizon, with: .linearGradient(Gradient(colors: [.clear, palette.accent.opacity(0.45), .clear]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 0.7)
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in applicationActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in applicationActive = false }
    }
}
