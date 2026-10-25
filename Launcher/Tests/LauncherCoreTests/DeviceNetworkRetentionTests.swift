import Foundation
import XCTest
@testable import LauncherCore

final class DeviceNetworkRetentionTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private var start: Date { calendar.date(from: DateComponents(year: 2020, month: 1, day: 1))! }
    private func counter(_ received: UInt64) -> [String: DeviceNetworkCounter] { ["en0": .init(received: received, sent: 0)] }
    private func recorded(_ count: Int) -> DeviceNetworkLedger {
        var accumulator = DeviceNetworkAccumulator(ledger: .init(now: start))
        for day in 0..<count {
            let date = calendar.date(byAdding: .day, value: day, to: start)!
            _ = accumulator.ingest(counter(UInt64(day) * 100), at: date, maximumGap: 6, calendar: calendar)
            _ = accumulator.ingest(counter(UInt64(day) * 100 + 10), at: date.addingTimeInterval(2), maximumGap: 6, calendar: calendar)
        }
        return accumulator.ledger
    }

    func testTwoYearsCompactWithoutDoubleCountingAndSurviveRestart() throws {
        let network = recorded(760)
        XCTAssertEqual(network.days.count, 400)
        XCTAssertFalse(network.archivedMonths.isEmpty)
        XCTAssertLessThanOrEqual(network.archivedMonths.count, 120)
        XCTAssertEqual(network.days.values.reduce(0) { $0 + $1.received } + network.archivedMonths.values.reduce(0) { $0 + $1.totals.received }, 7_600)
        XCTAssertEqual(network.recordingReceived, 7_600)
        let restored = try JSONDecoder().decode(DeviceNetworkLedger.self, from: JSONEncoder().encode(network)).validated()
        XCTAssertEqual(restored, network)
        var resumed = DeviceNetworkAccumulator(ledger: restored)
        let last = calendar.date(byAdding: .day, value: 759, to: start)!
        XCTAssertNil(resumed.ingest(counter(90_000), at: last.addingTimeInterval(4), maximumGap: 6, calendar: calendar))
        XCTAssertEqual(resumed.ingest(counter(90_010), at: last.addingTimeInterval(6), maximumGap: 6, calendar: calendar)?.received, 10)
        XCTAssertEqual(resumed.ledger.recordingReceived, 7_610)
        XCTAssertEqual(resumed.ledger.archivedMonths, restored.archivedMonths)
    }

    func testLegacyJSONKeepsExistingDaysWithoutInventingOlderHistory() throws {
        let value = recorded(3)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        for key in ["archivedMonths", "compactedThroughDay", "olderHistoryExpired"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(DeviceNetworkLedger.self, from: JSONSerialization.data(withJSONObject: json)).validated()
        XCTAssertEqual(decoded.days, value.days)
        XCTAssertEqual(decoded.recordingReceived, 30)
        XCTAssertTrue(decoded.archivedMonths.isEmpty)
        XCTAssertNil(decoded.compactedThroughDay)
    }

    func testArchivedMonthlyQueryDoesNotInventPartialMonthDistribution() throws {
        var traffic = DeviceTrafficLedger(now: start, timeZone: calendar.timeZone)
        traffic.scopes[.all] = recorded(760)
        let now = calendar.date(byAdding: .day, value: 760, to: start)!
        var budget = DeviceTrafficBudget(); budget.period = .custom
        budget.customStart = .init(year: 2020, month: 1, day: 1); budget.customEndInclusive = .init(year: 2020, month: 1, day: 31)
        let whole = traffic.summary(budget: budget, at: now)
        XCTAssertEqual(whole.received, 310)
        XCTAssertTrue(whole.includesMonthlyHistory)
        XCTAssertTrue(whole.isPartialPeriod) // 2 measured seconds per day are not complete coverage.
        budget.customStart = .init(year: 2020, month: 1, day: 15)
        budget.customEndInclusive = .init(year: 2020, month: 1, day: 20)
        let partial = traffic.summary(budget: budget, at: now)
        XCTAssertEqual(partial.totalBytes, 0)
        XCTAssertTrue(partial.omitsPartialArchivedMonth)
        XCTAssertTrue(partial.isPartialPeriod)
        budget.customStart = .init(year: 2020, month: 1, day: 1)
        budget.customEndInclusive = DeviceBudgetDate(now, calendar: calendar)
        XCTAssertEqual(traffic.summary(budget: budget, at: now).received, 7_600)
        XCTAssertEqual(traffic.history(scope: .all, yearly: false, at: now).reduce(0) { $0 + $1.received }, 7_600)
        XCTAssertEqual(traffic.history(scope: .all, yearly: true, at: now).reduce(0) { $0 + $1.received }, 7_600)
        XCTAssertTrue(traffic.history(scope: .all, yearly: true, at: now).allSatisfy(\.isPartial))
    }

    func testCompactedMonthAndRemainingDaysMergeExactlyOnce() {
        var traffic = DeviceTrafficLedger(now: start, timeZone: calendar.timeZone)
        traffic.scopes[.all] = recorded(415) // Jan 1–15 compacted, Jan 16–31 still daily.
        let now = calendar.date(byAdding: .day, value: 415, to: start)!
        XCTAssertEqual(traffic.history(scope: .all, yearly: false, at: now).first { $0.id == "2020-01" }?.received, 310)
        let network = traffic.scopes[.all]!
        XCTAssertEqual(network.archivedMonths["2020-01"]?.totals.received, 150)
        var backwards = DeviceNetworkAccumulator(ledger: network)
        XCTAssertNil(backwards.ingest(counter(100), at: start, maximumGap: 6, calendar: calendar))
        XCTAssertNil(backwards.ingest(counter(110), at: start.addingTimeInterval(2), maximumGap: 6, calendar: calendar))
        XCTAssertEqual(backwards.ledger, network)
    }

    func testFifteenYearsStayBoundedAndMarkExpiredOlderMonths() throws {
        var ledger = DeviceNetworkLedger(now: start)
        for day in 0..<5_500 {
            let date = calendar.date(byAdding: .day, value: day, to: start)!
            var value = DeviceNetworkDay(); value.received = 10; value.coveredSeconds = 2
            value.firstSample = date; value.lastSample = date.addingTimeInterval(2)
            ledger.days[DeviceNetworkLedger.dayKey(date, calendar: calendar)] = value
        }
        ledger.compactHistory()
        XCTAssertEqual(ledger.days.count, 400)
        XCTAssertEqual(ledger.archivedMonths.count, 120)
        XCTAssertTrue(ledger.olderHistoryExpired)
        _ = try ledger.validated()
        let encoded = try JSONEncoder().encode(ledger)
        XCTAssertLessThan(encoded.count, 200_000)
        var corrupt = ledger
        corrupt.days[try XCTUnwrap(ledger.compactedThroughDay)] = .init()
        XCTAssertThrowsError(try corrupt.validated())
    }

    func testPersistenceCoalescesRetriesAndFlushesDirtyState() {
        var schedule = DevicePersistenceSchedule(), writes = 0
        XCTAssertFalse(schedule.beginWrite(at: 0, force: true))
        for second in 0..<60 {
            schedule.markChanged()
            if schedule.beginWrite(at: Double(second)) { writes += 1; schedule.didWrite() }
        }
        XCTAssertEqual(writes, 2)
        XCTAssertTrue(schedule.dirty)
        XCTAssertTrue(schedule.beginWrite(at: 59, force: true))
        schedule.didWrite()
        XCTAssertFalse(schedule.beginWrite(at: 60, force: true))
        schedule.markChanged()
        XCTAssertFalse(schedule.beginWrite(at: 60))
        XCTAssertTrue(schedule.beginWrite(at: 89))
        // Failed writes stay dirty, but do not spin at the sampling frequency.
        XCTAssertTrue(schedule.dirty)
        XCTAssertFalse(schedule.beginWrite(at: 90))
        XCTAssertTrue(schedule.beginWrite(at: 119))
        XCTAssertTrue(schedule.beginWrite(at: 1)) // new monotonic clock epoch
    }
}
