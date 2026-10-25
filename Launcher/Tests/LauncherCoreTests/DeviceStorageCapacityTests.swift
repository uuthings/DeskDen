import XCTest
@testable import LauncherCore

final class DeviceStorageCapacityTests: XCTestCase {
    func testStorageUsesDecimalUnitsAndPreservesUnknownValues() {
        XCTAssertEqual(DeviceStorageCapacity.formatted(1_000_000_000_000), "1 TB")
        XCTAssertEqual(DeviceStorageCapacity.formatted(500_000_000_000), "500 GB")
        XCTAssertEqual(DeviceStorageCapacity.formatted(1_048_576), "1 MB")
        XCTAssertEqual(DeviceStorageCapacity.formatted(1_073_741_824), "1.1 GB")
        XCTAssertEqual(DeviceStorageCapacity.formatted(0), "0 B")
        XCTAssertEqual(DeviceStorageCapacity.formatted(nil), "—")
    }

    func testReclaimableEstimateUsesSameTotalAsAvailableAndUsageBar() throws {
        let value = try XCTUnwrap(DeviceStorageCapacity(total: 1_000, immediatelyFree: 100, availableForImportantUsage: 250))
        XCTAssertEqual(value.total, 1_000); XCTAssertEqual(value.immediatelyFree, 100)
        XCTAssertEqual(value.available, 250); XCTAssertEqual(value.reclaimableEstimate, 150)
        XCTAssertEqual(value.used, 750); XCTAssertEqual(value.used + value.available, value.total)
        XCTAssertEqual(value.percentUsed, 75)
    }

    func testMissingOrInconsistentEstimateFallsBackWithoutInventingReclaimableSpace() throws {
        for estimate in [Int64?.none, -1, 50, 1_001] {
            let value = try XCTUnwrap(DeviceStorageCapacity(total: 1_000, immediatelyFree: 100, availableForImportantUsage: estimate))
            XCTAssertEqual(value.available, 100); XCTAssertEqual(value.used, 900)
            XCTAssertNil(value.reclaimableEstimate)
        }
        let measuredZero = try XCTUnwrap(DeviceStorageCapacity(total: 1_000, immediatelyFree: 100, availableForImportantUsage: 100))
        XCTAssertEqual(measuredZero.reclaimableEstimate, 0)
    }

    func testInvalidBasicCapacityCannotBecomeAZeroReading() {
        for total in [Int64?.none, -1, 0] {
            XCTAssertNil(DeviceStorageCapacity(total: total, immediatelyFree: 0, availableForImportantUsage: 0))
        }
        for free in [Int64?.none, -1, 1_001] {
            XCTAssertNil(DeviceStorageCapacity(total: 1_000, immediatelyFree: free, availableForImportantUsage: 500))
        }
    }
}
