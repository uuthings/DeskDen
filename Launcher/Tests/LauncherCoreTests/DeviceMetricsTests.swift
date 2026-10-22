import XCTest
@testable import LauncherCore

final class DeviceMetricsTests: XCTestCase {
    func testBatteryCyclesRequireOneInternalBatteryAndOneInstalledRegistrySource() {
        XCTAssertNil(DeviceBatteryCycleCount.resolve(internalBatteryCount: 0, installedCycleCounts: [NSNumber(value: 438)]))
        XCTAssertNil(DeviceBatteryCycleCount.resolve(internalBatteryCount: 2, installedCycleCounts: [NSNumber(value: 438)]))
        XCTAssertNil(DeviceBatteryCycleCount.resolve(internalBatteryCount: 1, installedCycleCounts: []))
        XCTAssertNil(DeviceBatteryCycleCount.resolve(internalBatteryCount: 1, installedCycleCounts: [NSNumber(value: 438), NSNumber(value: 438)]))
        XCTAssertNil(DeviceBatteryCycleCount.resolve(internalBatteryCount: 1, installedCycleCounts: [nil]))
    }

    func testBatteryCyclesPreserveMeasuredZeroAndUnsignedIntegerValues() {
        XCTAssertEqual(DeviceBatteryCycleCount.resolve(internalBatteryCount: 1, installedCycleCounts: [NSNumber(value: 0)]), 0)
        XCTAssertEqual(DeviceBatteryCycleCount.resolve(internalBatteryCount: 1, installedCycleCounts: [NSNumber(value: 438)]), 438)
        XCTAssertEqual(DeviceBatteryCycleCount.resolve(internalBatteryCount: 1, installedCycleCounts: [NSNumber(value: UInt32.max)]), Int(UInt32.max))
    }

    func testBatteryCyclesRejectBooleanTextFractionalNonfiniteAndOutOfRangeValues() {
        let invalid: [Any?] = [nil, "438", true, NSNumber(value: true), NSNumber(value: -1), NSNumber(value: 0.5),
                               NSNumber(value: Double.nan), NSNumber(value: Double.infinity), NSNumber(value: -Double.infinity),
                               NSNumber(value: UInt64(UInt32.max) + 1)]
        for value in invalid {
            XCTAssertNil(DeviceBatteryCycleCount.resolve(internalBatteryCount: 1, installedCycleCounts: [value]), "Invalid cycle count: \(String(describing: value))")
        }
    }

    func testProcessCPUConvertsAppleSiliconMachTicksAndNormalizesAllCores() {
        XCTAssertEqual(DeviceProcessCPU.percent(ticks: 24_000_000, nanosecondsPerTick: 125.0 / 3, elapsed: 2, logicalCores: 12)!, 100.0 / 24, accuracy: 0.0001)
        XCTAssertEqual(DeviceProcessCPU.percent(ticks: 1_000_000_000, nanosecondsPerTick: 1, elapsed: 2, logicalCores: 12)!, 100.0 / 24, accuracy: 0.0001)
        XCTAssertEqual(DeviceProcessCPU.percent(ticks: 0, nanosecondsPerTick: 1, elapsed: 2, logicalCores: 12), 0)
        XCTAssertNil(DeviceProcessCPU.percent(ticks: 1, nanosecondsPerTick: 1, elapsed: 0, logicalCores: 12))
        XCTAssertNil(DeviceProcessCPU.percent(ticks: 1, nanosecondsPerTick: 1, elapsed: 2, logicalCores: 0))
    }

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func counter(_ received: UInt64, _ sent: UInt64 = 0) -> [String: DeviceNetworkCounter] {
        ["en0": .init(received: received, sent: sent)]
    }

    func testNetworkStartsWithBaselineAndRecordsOnlyDifferences() {
        var subject = DeviceNetworkAccumulator(ledger: .init(now: start))
        XCTAssertNil(subject.ingest(counter(1_000, 500), at: start, maximumGap: 6, calendar: utc))
        let delta = subject.ingest(counter(1_400, 700), at: start.addingTimeInterval(2), maximumGap: 6, calendar: utc)
        XCTAssertEqual(delta?.downloadBytesPerSecond, 200)
        XCTAssertEqual(delta?.uploadBytesPerSecond, 100)
        let today = subject.ledger.today(at: start, calendar: utc)
        XCTAssertEqual(today.received, 400); XCTAssertEqual(today.sent, 200)
        XCTAssertEqual(today.coveredSeconds, 2); XCTAssertEqual(today.firstSample, start)
    }

    func testSleepAndCounterResetDoNotCreateRateSpikesOrCreditMissingTraffic() {
        var subject = DeviceNetworkAccumulator(ledger: .init(now: start))
        _ = subject.ingest(counter(100), at: start, maximumGap: 6, calendar: utc)
        XCTAssertNil(subject.ingest(counter(8_000_000), at: start.addingTimeInterval(100), maximumGap: 6, calendar: utc))
        XCTAssertNil(subject.ingest(counter(10), at: start.addingTimeInterval(102), maximumGap: 6, calendar: utc))
        let valid = subject.ingest(counter(30), at: start.addingTimeInterval(104), maximumGap: 6, calendar: utc)
        XCTAssertEqual(valid?.received, 20)
        XCTAssertEqual(subject.ledger.recordingReceived, 20)
        XCTAssertEqual(subject.ledger.today(at: start, calendar: utc).excludedIntervals, 2)
    }

    func testScopeChangesAndStopResumeEstablishFreshBaseline() {
        var subject = DeviceNetworkAccumulator(ledger: .init(now: start))
        _ = subject.ingest(counter(100), at: start, maximumGap: 6, calendar: utc)
        subject.selectInterfaces(["utun0"])
        XCTAssertNil(subject.ingest(["utun0": .init(received: 20_000)], at: start.addingTimeInterval(2), maximumGap: 6, calendar: utc))
        _ = subject.ingest(["utun0": .init(received: 20_020)], at: start.addingTimeInterval(4), maximumGap: 6, calendar: utc)
        subject.breakContinuity()
        XCTAssertNil(subject.ingest(["utun0": .init(received: 30_000)], at: start.addingTimeInterval(5), maximumGap: 6, calendar: utc))
        XCTAssertEqual(subject.ledger.recordingReceived, 20)
        XCTAssertEqual(subject.ledger.selectedInterfaceIDs, ["utun0"])
    }

    func testCrossMidnightIntervalIsExcludedRatherThanAllocatedToWrongDay() {
        let midnight = utc.startOfDay(for: start).addingTimeInterval(86_400)
        var subject = DeviceNetworkAccumulator(ledger: .init(now: start))
        _ = subject.ingest(counter(100), at: midnight.addingTimeInterval(-1), maximumGap: 6, calendar: utc)
        XCTAssertNil(subject.ingest(counter(500), at: midnight.addingTimeInterval(1), maximumGap: 6, calendar: utc))
        _ = subject.ingest(counter(700), at: midnight.addingTimeInterval(3), maximumGap: 6, calendar: utc)
        XCTAssertEqual(subject.ledger.today(at: midnight, calendar: utc).received, 200)
        XCTAssertEqual(subject.ledger.today(at: midnight.addingTimeInterval(-2), calendar: utc).received, 0)
    }

    func testDisconnectedInterfaceDoesNotSilentlyReduceAccountingScope() {
        var subject = DeviceNetworkAccumulator(ledger: .init(now: start))
        _ = subject.ingest(["en0": .init(received: 100), "en1": .init(received: 200)], at: start, maximumGap: 6, calendar: utc)
        XCTAssertNil(subject.ingest(counter(300), at: start.addingTimeInterval(2), maximumGap: 6, calendar: utc))
        XCTAssertEqual(subject.ledger.recordingReceived, 0)
    }

    func testPersistenceRetainsTotalsAndSelectionButNeverRestoresCounterBaseline() throws {
        var subject = DeviceNetworkAccumulator(ledger: .init(now: start))
        subject.selectInterfaces(["en1", "en0", "en1"])
        _ = subject.ingest(counter(100), at: start, maximumGap: 6, calendar: utc)
        _ = subject.ingest(counter(400, 10), at: start.addingTimeInterval(2), maximumGap: 6, calendar: utc)
        let encoded = try JSONEncoder().encode(subject.ledger)
        let restored = try JSONDecoder().decode(DeviceNetworkLedger.self, from: encoded)
        XCTAssertEqual(restored, subject.ledger)
        XCTAssertEqual(restored.selectedInterfaceIDs, ["en0", "en1"])
        var resumed = DeviceNetworkAccumulator(ledger: restored)
        XCTAssertNil(resumed.ingest(counter(40_000), at: start.addingTimeInterval(3), maximumGap: 6, calendar: utc))
        XCTAssertEqual(resumed.ledger.recordingReceived, 300)
        resumed.beginRecording(at: start.addingTimeInterval(4))
        XCTAssertEqual(resumed.ledger.recordingReceived, 0)
        XCTAssertEqual(resumed.ledger.today(at: start, calendar: utc).received, 300)
    }

    func testClockMovingBackwardsDoesNotAccumulateNegativeDuration() {
        var subject = DeviceNetworkAccumulator(ledger: .init(now: start))
        _ = subject.ingest(counter(100), at: start, maximumGap: 6, calendar: utc)
        XCTAssertNil(subject.ingest(counter(200), at: start.addingTimeInterval(-3), maximumGap: 6, calendar: utc))
        XCTAssertEqual(subject.ledger.recordingCoveredSeconds, 0)
    }

    func testCPUUsesWholeMachineTickDifferencesAndHandlesWrap() {
        let old = DeviceCPUTicks(user: 100, system: 200, idle: 500, nice: 5)
        let now = DeviceCPUTicks(user: 120, system: 230, idle: 550, nice: 5)
        XCTAssertEqual(now.percentages(since: old)?.total, 50)
        XCTAssertEqual(now.percentages(since: old)?.user, 20)
        XCTAssertNil(old.percentages(since: old))
        let wrapped = DeviceCPUTicks(user: 4, system: 0, idle: 9)
        let previous = DeviceCPUTicks(user: UInt32.max - 5, system: 0, idle: 0)
        XCTAssertEqual(wrapped.percentages(since: previous)!.total, 10.0 / 19 * 100, accuracy: 0.001)
    }

    func testProcessSearchSortAndUnknownCPUOrdering() {
        let processes: [DeviceProcess] = [
            .init(pid: 33, name: "Safari Web", cpuPercent: nil, residentBytes: 10, threadCount: 2, sampledAt: start),
            .init(pid: 22, name: "Finder", cpuPercent: 1, residentBytes: 400, threadCount: 2, sampledAt: start),
            .init(pid: 11, name: "Safari", cpuPercent: 3, residentBytes: 200, threadCount: 2, sampledAt: start)
        ]
        XCTAssertEqual(DeviceProcess.filtered(processes, query: " safari ", sort: .cpu).map(\.pid), [11, 33])
        XCTAssertEqual(DeviceProcess.filtered(processes, query: "22", sort: .memory).map(\.name), ["Finder"])
        XCTAssertEqual(DeviceProcess.filtered(processes, query: "", sort: .memory).map(\.pid), [22, 11, 33])
        XCTAssertEqual(DeviceProcess.filtered(processes, query: "", sort: .cpu).map(\.pid), [11, 22, 33])
    }
}
