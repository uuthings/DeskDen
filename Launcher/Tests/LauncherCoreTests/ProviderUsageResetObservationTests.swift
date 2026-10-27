import Foundation
import XCTest
@testable import LauncherCore

final class ProviderUsageResetObservationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private let sourceID = UUID()

    private func reading(_ seconds: Double, date: String = "2026-11-25", used: UInt64 = 10,
                         limit: UInt64 = 1_000, remaining: UInt64? = nil, id: UUID? = nil) -> ProviderUsageSnapshot {
        .init(sourceID: id ?? sourceID, observedAt: now.addingTimeInterval(seconds), usedBytes: used,
              limitBytes: limit, remainingBytes: remaining, resetDateText: date,
              displayUnit: .decimalGB, sourceDescription: "fixture")
    }

    private func ingest(_ reading: ProviderUsageSnapshot, into state: inout ProviderUsageSourceState,
                        kind: ProviderUsageKind = .iproyal) {
        state.recordResetObservation(reading, kind: kind)
        state.snapshot = reading
    }

    func testLegacyStateWithoutObservationFieldsDecodesAndKeepsItsReading() throws {
        let state = ProviderUsageSourceState(snapshot: reading(0))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object.removeValue(forKey: "resetObservations"); object.removeValue(forKey: "pendingResetObservation")
        let restored = try JSONDecoder().decode(ProviderUsageSourceState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.snapshot, state.snapshot)
        XCTAssertTrue(restored.resetObservations.isEmpty)
        XCTAssertNil(restored.pendingResetObservation)
    }

    func testChangeNeedsASecondCoherentObservationAndRetainsActualQueryTimes() throws {
        var state = ProviderUsageSourceState(snapshot: reading(0, date: "2026-10-25", used: 900))
        ingest(reading(60), into: &state)
        XCTAssertTrue(state.resetObservations.isEmpty)
        let pending = try XCTUnwrap(state.pendingResetObservation)
        XCTAssertEqual(pending.lastOldObservedAt, now)
        XCTAssertEqual(pending.firstNewObservedAt, now.addingTimeInterval(60))
        XCTAssertNil(pending.confirmedAt)
        ingest(reading(120, used: 12), into: &state)
        let confirmed = try XCTUnwrap(state.resetObservations.last)
        XCTAssertEqual(confirmed.firstNewObservedAt, pending.firstNewObservedAt)
        XCTAssertEqual(confirmed.confirmedAt, now.addingTimeInterval(120))
        XCTAssertNil(state.pendingResetObservation)
        XCTAssertNil(state.snapshot?.resetsAt, "Date-only observations never manufacture a reset instant or timezone")
        try state.validateResetObservations(now: now.addingTimeInterval(120))
        XCTAssertEqual(try JSONDecoder().decode(ProviderUsageSourceState.self, from: JSONEncoder().encode(state)), state)
    }

    func testTopupsLimitChangesAndDateCorrectionsDoNotProduceConfirmedChanges() {
        let baseline = reading(0, date: "2026-10-25", used: 900)
        let nonCycles = [
            reading(60, date: "2026-10-25", used: 900, remaining: 300),
            reading(60, date: "2026-11-25", used: 10, limit: 2_000),
            reading(60, date: "2026-11-25", used: 900),
            reading(60, date: "2026-09-25", used: 10),
            reading(60, date: "2026-11-25", used: 10, remaining: 50)
        ]
        for next in nonCycles {
            var state = ProviderUsageSourceState(snapshot: baseline)
            ingest(next, into: &state)
            XCTAssertNil(state.pendingResetObservation)
            XCTAssertTrue(state.resetObservations.isEmpty)
        }
    }

    func testPendingChangeIsCancelledByQuotaAdjustmentAndIgnoresReplay() throws {
        var state = ProviderUsageSourceState(snapshot: reading(0, date: "2026-10-25", used: 900))
        let first = reading(60)
        ingest(first, into: &state)
        let pending = try XCTUnwrap(state.pendingResetObservation)
        state.recordResetObservation(first, kind: .iproyal)
        XCTAssertEqual(state.pendingResetObservation, pending)
        ingest(reading(120, used: 12, limit: 2_000), into: &state)
        XCTAssertNil(state.pendingResetObservation)
        XCTAssertTrue(state.resetObservations.isEmpty)
    }

    func testOtherSourceAndTimestampStyleNeverBecomeDateOnlyCycleRecords() {
        var state = ProviderUsageSourceState(snapshot: reading(0, date: "2026-10-25", used: 900))
        state.recordResetObservation(reading(60, id: UUID()), kind: .iproyal)
        XCTAssertNil(state.pendingResetObservation)
        state.recordResetObservation(reading(60), kind: .bandwagon)
        XCTAssertNil(state.pendingResetObservation)
        var exact = reading(60); exact.resetsAt = now.addingTimeInterval(86_400)
        state.recordResetObservation(exact, kind: .iproyal)
        XCTAssertNil(state.pendingResetObservation)
        state.recordResetObservation(reading(-60), kind: .iproyal)
        XCTAssertNil(state.pendingResetObservation)
    }

    func testRetentionKeepsOnlyTwelveConfirmedChanges() throws {
        var state = ProviderUsageSourceState()
        func date(_ month: Int) -> String { String(format: "%04d-%02d-25", 2024 + (month - 1) / 12, (month - 1) % 12 + 1) }
        for index in 1...15 {
            ingest(reading(Double(index * 180), date: date(index), used: 900), into: &state)
            ingest(reading(Double(index * 180 + 60), date: date(index + 1), used: 10), into: &state)
            ingest(reading(Double(index * 180 + 120), date: date(index + 1), used: 12), into: &state)
        }
        XCTAssertEqual(state.resetObservations.count, 12)
        XCTAssertEqual(state.resetObservations.first?.previousResetDateText, date(4))
        XCTAssertEqual(state.resetObservations.last?.resetDateText, date(16))
        try state.validateResetObservations(now: now.addingTimeInterval(3_000))
    }

    func testDocumentRejectsMalformedObservationMetadata() throws {
        let source = ProviderUsageConfiguration(id: sourceID, kind: .iproyal, name: "Fixture", resourceID: "123")
        var state = ProviderUsageSourceState(snapshot: reading(0, date: "2026-10-25", used: 900))
        ingest(reading(60), into: &state); ingest(reading(120), into: &state)
        var document = ProviderUsageDocument(); document.sources = [source]; document.states[sourceID] = state
        try document.validate(now: now.addingTimeInterval(120))
        state.resetObservations[0].confirmedAt = nil
        document.states[sourceID] = state
        XCTAssertThrowsError(try document.validate(now: now.addingTimeInterval(120)))
        state.resetObservations[0].confirmedAt = now.addingTimeInterval(120)
        state.resetObservations[0].resetDateText = "2026-02-30"
        document.states[sourceID] = state
        XCTAssertThrowsError(try document.validate(now: now.addingTimeInterval(120)))
    }
}
