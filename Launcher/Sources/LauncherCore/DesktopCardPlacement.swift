import Foundation
import CoreGraphics

public enum DesktopCardPlacement {
    /// Cocoa coordinates can be negative on secondary displays. Keep the card on the
    /// screen with the greatest overlap, or the nearest screen after a display detaches.
    public static func clamped(_ frame: CGRect, visibleScreens: [CGRect]) -> CGRect {
        guard !visibleScreens.isEmpty else { return frame }
        let screen = visibleScreens.max { a, b in
            let areaA = overlap(frame, a), areaB = overlap(frame, b)
            if areaA != areaB { return areaA < areaB }
            return distance(frame, a) > distance(frame, b)
        }!
        let width = min(frame.width, screen.width), height = min(frame.height, screen.height)
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height), width: width, height: height)
    }
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let x = max(b.minX - a.midX, 0, a.midX - b.maxX)
        let y = max(b.minY - a.midY, 0, a.midY - b.maxY)
        return x * x + y * y
    }
}
