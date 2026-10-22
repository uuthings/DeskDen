import Foundation

/// Shape-preserving cubic interpolation: every sample is retained, extrema are
/// bounded, and callers pass each contiguous recording segment separately.
public enum DeviceTrendCurve {
    public struct Segment: Equatable, Sendable {
        public let start: CGPoint
        public let control1: CGPoint
        public let control2: CGPoint
        public let end: CGPoint
    }
    public static func segments(_ points: [CGPoint]) -> [Segment] {
        guard points.count > 1, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        let n = points.count
        var widths = [CGFloat](), slopes = [CGFloat]()
        for i in 0..<(n - 1) {
            let width = points[i + 1].x - points[i].x
            guard width > 0 else { return [] }
            widths.append(width)
            slopes.append((points[i + 1].y - points[i].y) / width)
        }
        var tangents = [CGFloat](repeating: 0, count: n)
        tangents[0] = slopes[0]; tangents[n - 1] = slopes[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                let before = slopes[i - 1], after = slopes[i]
                if before * after > 0 {
                    let w1 = 2 * widths[i] + widths[i - 1]
                    let w2 = widths[i] + 2 * widths[i - 1]
                    tangents[i] = (w1 + w2) / (w1 / before + w2 / after)
                }
            }
        }
        return (0..<(n - 1)).map { i in
            let a = points[i], b = points[i + 1], dx = widths[i] / 3
            let lower = min(a.y, b.y), upper = max(a.y, b.y)
            func bounded(_ value: CGFloat) -> CGFloat { min(upper, max(lower, value)) }
            return Segment(start: a,
                           control1: CGPoint(x: a.x + dx, y: bounded(a.y + tangents[i] * dx)),
                           control2: CGPoint(x: b.x - dx, y: bounded(b.y - tangents[i + 1] * dx)), end: b)
        }
    }
}
