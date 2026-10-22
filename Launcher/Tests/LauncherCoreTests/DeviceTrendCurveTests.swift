import XCTest
@testable import LauncherCore

final class DeviceTrendCurveTests: XCTestCase {
    func testCurvesPreserveSamplesAndNeverInventPeaksOrNegativeTraffic() {
        let points: [CGPoint] = [.init(x: 0, y: 0), .init(x: 1, y: 100), .init(x: 4, y: 2), .init(x: 5, y: 2), .init(x: 8, y: 40)]
        let segments = DeviceTrendCurve.segments(points)
        XCTAssertEqual(segments.count, points.count - 1)
        for (i, segment) in segments.enumerated() {
            XCTAssertEqual(segment.start, points[i]); XCTAssertEqual(segment.end, points[i + 1])
            let low = min(segment.start.y, segment.end.y), high = max(segment.start.y, segment.end.y)
            var previous = segment.start.y
            for step in 0...100 {
                let t = CGFloat(step) / 100, u = 1 - t
                let y = u*u*u*segment.start.y + 3*u*u*t*segment.control1.y + 3*u*t*t*segment.control2.y + t*t*t*segment.end.y
                XCTAssertGreaterThanOrEqual(y, low - 0.00001); XCTAssertLessThanOrEqual(y, high + 0.00001)
                if segment.end.y >= segment.start.y { XCTAssertGreaterThanOrEqual(y, previous - 0.00001) }
                else { XCTAssertLessThanOrEqual(y, previous + 0.00001) }
                previous = y
            }
        }
    }
    func testInvalidAndIsolatedPointsCannotProduceCrossGapCurves() {
        XCTAssertTrue(DeviceTrendCurve.segments([]).isEmpty)
        XCTAssertTrue(DeviceTrendCurve.segments([.zero]).isEmpty)
        XCTAssertTrue(DeviceTrendCurve.segments([.zero, .zero]).isEmpty)
        XCTAssertTrue(DeviceTrendCurve.segments([.zero, .init(x: 1, y: CGFloat.nan)]).isEmpty)
        let first = DeviceTrendCurve.segments([.init(x: 0, y: 2), .init(x: 1, y: 3)])
        let second = DeviceTrendCurve.segments([.init(x: 8, y: 4), .init(x: 9, y: 5)])
        XCTAssertEqual(first.last?.end.x, 1); XCTAssertEqual(second.first?.start.x, 8)
    }
}
