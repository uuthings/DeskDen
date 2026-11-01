import SwiftUI

/// One optical box and stroke weight for the selected navigation symbol family.
struct WorkbenchNavigationIcon: View {
    let symbol: String
    private var custom: Bool {
        ["rectangle.split.2x2", "internaldrive", "arrow.up.arrow.down", "lock", "rectangle.on.rectangle", "keyboard", "checkmark.shield", "list.bullet.clipboard"].contains(symbol)
    }
    var body: some View {
        Group {
            if custom {
                WorkbenchNavigationGlyph(symbol: symbol).stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            } else {
                Image(systemName: symbol).font(.system(size: 17, weight: .regular)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 18, height: 18).accessibilityHidden(true)
    }
}

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
        case "internaldrive":
            line([(5, 3), (14, 12)])
            line([(10, 10), (20, 15), (16, 21), (5, 17), (10, 10)])
            line([(10, 18), (12, 15)]); line([(14, 20), (16, 17)])
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
