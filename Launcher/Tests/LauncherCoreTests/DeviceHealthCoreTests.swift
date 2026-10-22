import XCTest
@testable import LauncherCore

final class DeviceHealthCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot(memory: DevicePressure = .normal, duration: TimeInterval = 120,
                          available: UInt64 = 200_000_000_000, total: UInt64 = 1_000_000_000_000,
                          thermal: DeviceThermalState = .nominal) -> DeviceHealthSnapshot {
        .init(memory: .init(value: .init(pressure: memory, sustainedSeconds: duration), sampledAt: now, source: "macOS pressure"),
              storage: .init(value: .init(totalBytes: total, availableBytes: available, volumeName: "Data"), sampledAt: now, source: "filesystem"),
              thermal: .init(value: .init(state: thermal, sustainedSeconds: duration), sampledAt: now, source: "ProcessInfo"))
    }
    func testCompleteNecessaryCoverageScoresButOptionalBatteryRemainsUnknown() throws {
        let report = DeviceHealthAssessor.evaluate(snapshot(), at: now)
        XCTAssertEqual(report.score, 100)
        XCTAssertEqual(report.evaluatedRequiredCount, 3)
        XCTAssertEqual(report.evaluatedCount, 3)
        XCTAssertEqual(report.factors.last?.state, .missing)
        XCTAssertEqual(report.ruleVersion, DeviceHealthRules.version)
        XCTAssertEqual(try report.validated(), report)
    }
    func testMissingPressureIsNeverInferredFromOccupancyOrOtherPassingFactors() {
        let report = DeviceHealthAssessor.evaluate(snapshot(memory: .unknown), at: now)
        XCTAssertNil(report.score)
        XCTAssertEqual(report.evaluatedRequiredCount, 2)
        XCTAssertEqual(report.factors.first { $0.factor == .memory }?.state, .missing)
        XCTAssertEqual(report.summary, "信息不足，暂不打分")
    }
    func testTransientPressureAndThermalSpikesRemainObservingWithoutDeduction() {
        let report = DeviceHealthAssessor.evaluate(snapshot(memory: .critical, duration: 59.99, thermal: .serious), at: now)
        XCTAssertNil(report.score)
        for factor in [DeviceHealthFactor.memory, .thermal] {
            let item = report.factors.first { $0.factor == factor }
            XCTAssertEqual(item?.state, .observing); XCTAssertNil(item?.deduction)
        }
    }
    func testSustainedBoundaryHasExplicitFixedDeductionsAndNoProcessingBonus() {
        let input = snapshot(memory: .warning, duration: 60, available: 100_000_000_000, thermal: .serious)
        let first = DeviceHealthAssessor.evaluate(input, at: now)
        let repeated = DeviceHealthAssessor.evaluate(input, at: now)
        XCTAssertEqual(first.score, 55)
        XCTAssertEqual(first.factors.compactMap(\.deduction).reduce(0, +), 45)
        XCTAssertEqual(first.score, repeated.score)
        XCTAssertTrue(first.factors.allSatisfy { !$0.source.isEmpty && $0.sampledAt == now || $0.state == .missing })
    }
    func testStorageFractionAndAbsoluteThresholdsAreBothAppliedAtEdges() {
        func storageLoss(_ free: UInt64, total: UInt64 = 1_000_000_000_000) -> Int? {
            DeviceHealthAssessor.evaluate(snapshot(available: free, total: total), at: now).factors.first { $0.factor == .storage }?.deduction
        }
        XCTAssertEqual(storageLoss(150_000_000_000), 0)
        XCTAssertEqual(storageLoss(149_999_999_999), 16)
        XCTAssertEqual(storageLoss(50_000_000_000), 16)
        XCTAssertEqual(storageLoss(49_999_999_999), 40)
        XCTAssertEqual(storageLoss(19_000_000_000, total: 100_000_000_000), 16)
        XCTAssertEqual(storageLoss(4_999_999_999, total: 10_000_000_000), 40)
    }
    func testInvalidStorageAndInvalidDurationsFailInsteadOfClampingToHealthy() {
        var input = snapshot(available: 2, total: 1)
        input.memory.value?.sustainedSeconds = -.infinity
        let result = DeviceHealthAssessor.evaluate(input, at: now)
        XCTAssertNil(result.score)
        XCTAssertEqual(result.factors.first { $0.factor == .storage }?.state, .failed)
        XCTAssertEqual(result.factors.first { $0.factor == .memory }?.state, .failed)
    }
    func testStaleFuturePermissionAndFailedSourcesRetainDistinctStates() {
        var input = snapshot()
        input.memory.sampledAt = now.addingTimeInterval(-61)
        input.storage.sampledAt = now.addingTimeInterval(6)
        input.thermal = .init(unavailable: .permissionDenied, source: "thermal", detail: "denied")
        input.battery = .init(unavailable: .failed, source: "battery", detail: "read error")
        let report = DeviceHealthAssessor.evaluate(input, at: now)
        XCTAssertNil(report.score)
        XCTAssertEqual(report.factors.map(\.state), [.failed, .stale, .permissionDenied, .failed])
        XCTAssertEqual(report.factors.last?.explanation, "read error")
    }
    func testCancellationPreservesCompletedEvidenceButNeverPublishesScore() throws {
        var callbacks: [DeviceHealthFactorResult] = []
        let report = DeviceHealthAssessor.evaluate(snapshot(), at: now, isCancelled: { callbacks.count >= 1 }, progress: { callbacks.append($0) })
        XCTAssertEqual(report.stage, .cancelled); XCTAssertNil(report.score)
        XCTAssertEqual(report.factors.first?.state, .evaluated)
        XCTAssertEqual(report.factors.dropFirst().map(\.state), [.cancelled, .cancelled, .cancelled])
        XCTAssertEqual(callbacks.count, 4)
        _ = try report.validated()
    }
    func testBatteryServiceRecommendationDoesNotImpersonateScoredHardwareDiagnosis() {
        var input = snapshot()
        input.battery = .init(value: .serviceRecommended, sampledAt: now, source: "IOKit")
        let report = DeviceHealthAssessor.evaluate(input, at: now)
        XCTAssertEqual(report.score, 100)
        XCTAssertEqual(report.factors.last?.severity, .watch)
        XCTAssertEqual(report.factors.last?.deduction, 0)
    }
    func testPersistenceRoundTripRejectsForgedScoreAndMissingFactorCoverage() throws {
        let report = DeviceHealthAssessor.evaluate(snapshot(), at: now)
        var history = DeviceHealthHistory(); try history.append(report)
        let restored = try JSONDecoder().decode(DeviceHealthHistory.self, from: JSONEncoder().encode(history)).validated()
        XCTAssertEqual(restored, history)
        var forged = report; forged.score = 92
        XCTAssertThrowsError(try history.append(forged))
        forged = report; forged.factors.removeLast()
        XCTAssertThrowsError(try forged.validated())
        forged = report; forged.ruleVersion = "unknown"
        XCTAssertThrowsError(try forged.validated())
    }
    func testHistoryCapsAtThirtyAndKeepsNewestResultsWithoutDuplication() throws {
        var history = DeviceHealthHistory()
        for offset in 0..<35 {
            try history.append(DeviceHealthAssessor.evaluate(snapshot(), at: now.addingTimeInterval(Double(offset))))
        }
        XCTAssertEqual(history.reports.count, 30)
        XCTAssertEqual(history.reports.first?.finishedAt, now.addingTimeInterval(34))
        try history.append(history.reports[0]); XCTAssertEqual(history.reports.count, 30)
    }
    func testContinuityResetOnChangeGapUnknownAndBackwardsClock() {
        var tracker = DeviceHealthContinuity<DevicePressure>()
        XCTAssertEqual(tracker.ingest(.warning, at: now, maximumGap: 6), 0)
        XCTAssertEqual(tracker.ingest(.warning, at: now.addingTimeInterval(5), maximumGap: 6), 5)
        XCTAssertEqual(tracker.ingest(.critical, at: now.addingTimeInterval(10), maximumGap: 6), 0)
        XCTAssertEqual(tracker.ingest(.critical, at: now.addingTimeInterval(20), maximumGap: 6), 0)
        XCTAssertEqual(tracker.ingest(.critical, at: now.addingTimeInterval(19), maximumGap: 6), 0)
        XCTAssertEqual(tracker.ingest(nil, at: now.addingTimeInterval(21), maximumGap: 6), 0)
        XCTAssertNil(tracker.value)
    }
    func testCurrentReportAgeDoesNotTreatBackwardsClockAsFresh() {
        let report = DeviceHealthAssessor.evaluate(snapshot(), at: now)
        XCTAssertTrue(report.isCurrent(at: now.addingTimeInterval(300)))
        XCTAssertFalse(report.isCurrent(at: now.addingTimeInterval(301)))
        XCTAssertFalse(report.isCurrent(at: now.addingTimeInterval(-1)))
    }
}
