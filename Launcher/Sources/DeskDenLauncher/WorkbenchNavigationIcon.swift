import SwiftUI
import LauncherCore

/// One optical box and stroke weight for the selected navigation symbol family.
struct WorkbenchNavigationIcon: View {
    let symbol: String
    var size: CGFloat = 18
    init(symbol: String, size: CGFloat = 18) { self.symbol = symbol; self.size = size }
    init(route: WorkbenchRoute, size: CGFloat = 18) {
        symbol = route == .cleaning ? "brush-cleaning" : route == .settings ? "gearshape" : route.symbol
        self.size = size
    }
    private var custom: Bool {
        ["rectangle.split.2x2", "brush-cleaning", "calendar", "chart.bar", "chart.bar.xaxis", "arrow.up.arrow.down", "lock", "rectangle.on.rectangle", "keyboard", "checkmark.shield", "list.bullet.clipboard"].contains(symbol)
    }
    var body: some View {
        Group {
            if custom {
                WorkbenchNavigationGlyph(symbol: symbol).stroke(style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round, lineJoin: .round))
            } else {
                Image(systemName: symbol).font(.system(size: size - 1, weight: .regular)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Hardware and compact cards share one semantic mapping. In particular, a
/// storage drive stays a drive; only the cleaning navigation uses the brush.
struct WorkbenchContentIcon: View {
    let symbol: String
    var size: CGFloat = 18
    init(symbol: String, size: CGFloat = 18) { self.symbol = symbol; self.size = size }
    init(device: DeviceCardID, size: CGFloat = 18) { symbol = Self.symbol(for: device); self.size = size }
    init(mini: WorkbenchMiniCardID, size: CGFloat = 16) { symbol = Self.symbol(for: mini); self.size = size }
    static func symbol(for device: DeviceCardID) -> String { device == .thermal ? "thermometer.medium" : device.symbol }
    static func symbol(for mini: WorkbenchMiniCardID) -> String {
        switch mini {
        case .network: symbol(for: DeviceCardID.network)
        case .thermal: symbol(for: DeviceCardID.thermal)
        case .disk: symbol(for: DeviceCardID.storage)
        case .memory: symbol(for: DeviceCardID.memory)
        case .traffic: symbol(for: DeviceCardID.traffic)
        case .todo: "calendar"
        default: "server.rack"
        }
    }
    var body: some View { WorkbenchNavigationIcon(symbol: symbol, size: size) }
}

// Brush, calendar-days and chart-column outlines adapted from Lucide 1.17.0.
// ISC License — Copyright (c) 2026 Lucide Icons and Contributors
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
private struct WorkbenchNavigationGlyph: Shape {
    let symbol: String
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func line(_ points: [(CGFloat, CGFloat)]) {
            guard let first = points.first else { return }
            p.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { p.addLine(to: CGPoint(x: point.0, y: point.1)) }
        }
        switch symbol {
        case "rectangle.split.2x2":
            line([(3, 10), (12, 3), (21, 10)])
            line([(5, 9), (5, 21), (10, 21), (10, 15), (14, 15), (14, 21), (19, 21), (19, 9)])
        case "brush-cleaning":
            p.move(to: CGPoint(x: 19, y: 14))
            p.addQuadCurve(to: CGPoint(x: 20, y: 13), control: CGPoint(x: 20, y: 14))
            p.addLine(to: CGPoint(x: 20, y: 12))
            p.addQuadCurve(to: CGPoint(x: 18, y: 10), control: CGPoint(x: 20, y: 10))
            p.addLine(to: CGPoint(x: 15, y: 10))
            p.addQuadCurve(to: CGPoint(x: 14, y: 9), control: CGPoint(x: 14, y: 10))
            p.addLine(to: CGPoint(x: 14, y: 4))
            p.addCurve(to: CGPoint(x: 10, y: 4), control1: CGPoint(x: 14, y: 1.333), control2: CGPoint(x: 10, y: 1.333))
            p.addLine(to: CGPoint(x: 10, y: 9))
            p.addQuadCurve(to: CGPoint(x: 9, y: 10), control: CGPoint(x: 10, y: 10))
            p.addLine(to: CGPoint(x: 6, y: 10))
            p.addQuadCurve(to: CGPoint(x: 4, y: 12), control: CGPoint(x: 4, y: 10))
            p.addLine(to: CGPoint(x: 4, y: 13))
            p.addQuadCurve(to: CGPoint(x: 5, y: 14), control: CGPoint(x: 4, y: 14))
            line([(19, 14), (5, 14), (3.027, 20.767)])
            p.addQuadCurve(to: CGPoint(x: 4, y: 22), control: CGPoint(x: 2.7, y: 22))
            p.addLine(to: CGPoint(x: 20, y: 22))
            p.addQuadCurve(to: CGPoint(x: 20.973, y: 20.767), control: CGPoint(x: 21.3, y: 22))
            p.addLine(to: CGPoint(x: 19, y: 14))
            line([(8, 22), (9, 18)]); line([(16, 22), (15, 18)])
        case "calendar":
            p.addRoundedRect(in: CGRect(x: 3, y: 4, width: 18, height: 18), cornerSize: CGSize(width: 2, height: 2))
            line([(8, 2), (8, 6)]); line([(16, 2), (16, 6)]); line([(3, 10), (21, 10)])
            for y: CGFloat in [14, 18] { for x: CGFloat in [8, 12, 16] { line([(x, y), (x + 0.01, y)]) } }
        case "chart.bar", "chart.bar.xaxis":
            line([(3, 3), (3, 19)])
            p.addQuadCurve(to: CGPoint(x: 5, y: 21), control: CGPoint(x: 3, y: 21))
            p.addLine(to: CGPoint(x: 21, y: 21))
            line([(8, 17), (8, 14)]); line([(13, 17), (13, 5)]); line([(18, 17), (18, 9)])
        case "arrow.up.arrow.down":
            line([(7, 21), (7, 3), (3, 7)]); line([(7, 3), (11, 7)])
            line([(17, 3), (17, 21), (13, 17)]); line([(17, 21), (21, 17)])
        case "lock":
            p.addRoundedRect(in: CGRect(x: 4, y: 10, width: 16, height: 12), cornerSize: CGSize(width: 2, height: 2))
            p.move(to: CGPoint(x: 7, y: 10)); p.addLine(to: CGPoint(x: 7, y: 7))
            p.addCurve(to: CGPoint(x: 17, y: 7), control1: CGPoint(x: 7, y: 0.5), control2: CGPoint(x: 17, y: 0.5))
            p.addLine(to: CGPoint(x: 17, y: 10))
            p.addEllipse(in: CGRect(x: 11, y: 14, width: 2, height: 2)); line([(12, 16), (12, 18)])
        case "rectangle.on.rectangle":
            p.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerSize: CGSize(width: 3, height: 3))
            line([(8, 18), (16, 6)]); line([(5, 9), (8, 5)])
        case "keyboard":
            p.addRoundedRect(in: CGRect(x: 2, y: 5, width: 20, height: 14), cornerSize: CGSize(width: 2, height: 2))
            for y: CGFloat in [9, 12] { for x: CGFloat in [6, 10, 14, 18] { line([(x, y), (x + 0.1, y)]) } }
            line([(8, 16), (16, 16)])
        case "checkmark.shield":
            p.move(to: CGPoint(x: 12, y: 2)); p.addLine(to: CGPoint(x: 21, y: 6)); p.addLine(to: CGPoint(x: 20, y: 14))
            p.addQuadCurve(to: CGPoint(x: 12, y: 22), control: CGPoint(x: 18, y: 20))
            p.addQuadCurve(to: CGPoint(x: 4, y: 14), control: CGPoint(x: 6, y: 20))
            p.addLine(to: CGPoint(x: 3, y: 6)); p.closeSubpath(); line([(8, 12), (11, 15), (16, 9)])
        case "list.bullet.clipboard":
            p.addRoundedRect(in: CGRect(x: 4, y: 5, width: 16, height: 17), cornerSize: CGSize(width: 2, height: 2))
            p.addRoundedRect(in: CGRect(x: 8, y: 2, width: 8, height: 5), cornerSize: CGSize(width: 1.5, height: 1.5))
            line([(8, 12), (10, 14), (15, 10)]); line([(8, 18), (16, 18)])
        default: break
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24).translatedBy(x: rect.minX, y: rect.minY))
    }
}
