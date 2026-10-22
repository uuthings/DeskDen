import XCTest
import CoreGraphics
@testable import LauncherCore

final class DesktopCardPlacementTests: XCTestCase {
    func testSecondaryScreenNegativeCoordinatesArePreserved() {
        let card = CGRect(x: -900, y: 400, width: 260, height: 240)
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 875), CGRect(x: -1920, y: 0, width: 1920, height: 1055)]
        XCTAssertEqual(DesktopCardPlacement.clamped(card, visibleScreens: screens), card)
    }
    func testDetachedDisplayReturnsCardToVisibleArea() {
        let card = CGRect(x: -1800, y: 100, width: 260, height: 240)
        let screen = CGRect(x: 0, y: 24, width: 1440, height: 851)
        let result = DesktopCardPlacement.clamped(card, visibleScreens: [screen])
        XCTAssertEqual(result.minX, 0); XCTAssertTrue(screen.contains(result))
    }
    func testCardSizeChangeAndMenuBarNeverLeaveHeaderOffScreen() {
        let screen = CGRect(x: 0, y: 40, width: 1440, height: 835)
        let result = DesktopCardPlacement.clamped(CGRect(x: 1300, y: 840, width: 260, height: 286), visibleScreens: [screen])
        XCTAssertEqual(result.maxX, screen.maxX); XCTAssertEqual(result.maxY, screen.maxY)
    }
    func testLargestOverlapChoosesCorrectMonitor() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800), right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let result = DesktopCardPlacement.clamped(CGRect(x: 950, y: 100, width: 260, height: 240), visibleScreens: [left, right])
        XCTAssertEqual(result.minX, 1000)
    }
}
