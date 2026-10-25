import Foundation
import XCTest
@testable import LauncherCore

final class AIQuotaDailyHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        value.firstWeekday = 2
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func snapshot(_ timestamp: String, percent: Double = 40, duration: Int = 300,
                          source: AIQuotaSource = .localSession, reset: String? = nil,
                          provider: AIProvider = .codex) throws -> AIQuotaSnapshot {
        .init(provider: provider, observedAt: date(timestamp), source: source,
              shortWindow: try .init(usedPercent: percent, durationMinutes: duration, resetsAt: reset.map(date)), weeklyWindow: nil)
    }
    private func build(_ snapshots: [AIQuotaSnapshot], now: String = "2026-10-25T18:00:00Z") -> AIQuotaDailyHistory {
        .build(snapshots, provider: .codex, now: date(now), calendar: calendar)
    }

    func testThirtyOneNaturalDaysStayWeekAlignedAcrossDaylightSaving() {
        let history = build([], now: "2026-03-20T18:00:00Z")
        let retained = history.days.filter(\.isInRange)
        XCTAssertEqual(retained.count, 31)
        XCTAssertEqual(history.days.count % 7, 0)
        XCTAssertEqual(calendar.component(.weekday, from: history.days.first!.date), calendar.firstWeekday)
        XCTAssertEqual(retained.first!.date, history.startDate)
        XCTAssertEqual(retained.last!.date, history.endDate)
        XCTAssertTrue(zip(retained, retained.dropFirst()).contains { $1.date.timeIntervalSince($0.date) == 23 * 3_600 })
        XCTAssertTrue(retained.allSatisfy { calendar.component(.hour, from: $0.date) == 0 })
    }

    func testLastDailyReadingPreservesResetAndSourceInsteadOfSummingOrTakingPeak() throws {
        let beforeReset = try snapshot("2026-10-24T14:00:00Z", percent: 89, reset: "2026-10-24T15:00:00Z")
        let afterReset = try snapshot("2026-10-24T16:00:00Z", percent: 6, source: .imported, reset: "2026-10-24T21:00:00Z")
        // Both resets are before now, but the observations were valid when made.
        let history = build([afterReset, beforeReset])
        let series = try XCTUnwrap(history.series.first)
        let reading = try XCTUnwrap(series.days.compactMap(\.reading).first)
        XCTAssertEqual(series.observedDayCount, 1)
        XCTAssertEqual(reading.window.usedPercent, 6)
        XCTAssertEqual(reading.source, .imported)
        XCTAssertEqual(reading.observedAt, afterReset.observedAt)
        XCTAssertEqual(reading.window.resetsAt, afterReset.shortWindow?.resetsAt)
    }

    func testMissingDayAndObservedZeroRemainDifferentAndPaddingHasNoReading() throws {
        let history = build([try snapshot("2026-10-24T16:00:00Z", percent: 0)])
        let days = try XCTUnwrap(history.series.first).days
        XCTAssertEqual(days.filter(\.isInRange).count, 31)
        XCTAssertEqual(days.filter { $0.reading != nil }.count, 1)
        XCTAssertEqual(days.compactMap(\.reading).first?.window.usedPercent, 0)
        XCTAssertEqual(days.filter { $0.isInRange && $0.reading == nil }.count, 30)
        XCTAssertTrue(days.filter { !$0.isInRange }.allSatisfy { $0.reading == nil })
    }

    func testLocalMidnightDeterminesTheDayRatherThanUTCMidnight() throws {
        let history = build([try snapshot("2026-10-25T03:59:00Z", percent: 10),
                             try snapshot("2026-10-25T04:00:00Z", percent: 20)])
        let observed = try XCTUnwrap(history.series.first).days.filter { $0.reading != nil }
        XCTAssertEqual(observed.map { calendar.component(.day, from: $0.date) }, [24, 25])
        XCTAssertEqual(observed.compactMap { $0.reading?.window.usedPercent }, [10, 20])
    }

    func testFutureOldAndOtherProviderReadingsAreExcluded() throws {
        let history = build([try snapshot("2026-10-25T18:00:01Z"),
                             try snapshot("2026-09-24T23:59:00Z"),
                             try snapshot("2026-10-25T17:00:00Z", provider: .claude)])
        XCTAssertTrue(history.series.isEmpty)
        XCTAssertEqual(history.days.filter(\.isInRange).count, 31)
    }

    func testActualWindowDurationsStaySeparateRegardlessOfStorageSlot() throws {
        let week = try AIQuotaWindow(usedPercent: 72, durationMinutes: 10_080, resetsAt: nil)
        let short = try AIQuotaWindow(usedPercent: 16, durationMinutes: 300, resetsAt: nil)
        let swapped = AIQuotaSnapshot(provider: .codex, observedAt: date("2026-10-25T17:00:00Z"),
                                      source: .manual, shortWindow: week, weeklyWindow: short)
        let history = build([swapped])
        XCTAssertEqual(history.series.map(\.durationMinutes), [300, 10_080])
        XCTAssertEqual(history.series.map { $0.days.compactMap(\.reading).first?.window.usedPercent }, [16, 72])
    }

    func testInvalidObservationOrWindowCannotReplaceAnEarlierValidReading() throws {
        let valid = try snapshot("2026-10-25T16:00:00Z", percent: 40)
        var invalidPercent = try snapshot("2026-10-25T17:00:00Z")
        invalidPercent.shortWindow?.usedPercent = .nan
        var invalidDuration = invalidPercent
        invalidDuration.shortWindow?.usedPercent = 80
        invalidDuration.shortWindow?.durationMinutes = 0
        var invalidReset = invalidDuration
        invalidReset.shortWindow?.durationMinutes = 300
        invalidReset.shortWindow?.resetsAt = date("2026-10-25T16:59:00Z")
        var invalidDate = valid
        invalidDate.observedAt = Date(timeIntervalSince1970: .nan)
        let history = build([valid, invalidPercent, invalidDuration, invalidReset, invalidDate])
        XCTAssertEqual(history.series.count, 1)
        XCTAssertEqual(history.series.first?.days.compactMap(\.reading).first?.window.usedPercent, 40)
    }

    func testAnInvalidCompanionWindowDoesNotHideTheValidWindow() throws {
        var value = try snapshot("2026-10-25T17:00:00Z", percent: 22)
        value.weeklyWindow = try AIQuotaWindow(usedPercent: 30, durationMinutes: 10_080, resetsAt: nil)
        value.weeklyWindow?.resetsAt = date("2026-10-25T16:00:00Z")
        let history = build([value])
        XCTAssertEqual(history.series.map(\.durationMinutes), [300])
        XCTAssertEqual(history.series.first?.days.compactMap(\.reading).first?.window.usedPercent, 22)
    }
    func testDailyTokensDeduplicateAndKeepProvidersMissingAndZeroDistinct() {
        let timestamp = date("2026-10-25T12:00:00Z")
        let record = AITokenRecord(id: "one", provider: .codex, timestamp: timestamp,
            model: "fixture", tokens: .init(input: 100, output: 20, cacheRead: 30, cacheWrite: 4))
        var other = record; other.provider = .claude
        let zero = AITokenRecord(id: "zero", provider: .codex, timestamp: date("2026-10-24T12:00:00Z"), model: "fixture", tokens: .init())
        let result = AIDailyTokenHistory.totals([record, record, other, zero], provider: .codex,
            now: date("2026-10-25T18:00:00Z"), calendar: calendar)
        XCTAssertEqual(result[calendar.startOfDay(for: timestamp)]?.total, 154)
        XCTAssertEqual(result[calendar.startOfDay(for: zero.timestamp)]?.total, 0)
        XCTAssertNil(result[calendar.startOfDay(for: date("2026-10-23T12:00:00Z"))])
        XCTAssertEqual(result.count, 2)
    }

    func testDailyTokensRespectLocalMidnightDSTAndRetainedRange() {
        let records = ["2026-03-08T04:59:00Z", "2026-03-08T05:00:00Z", "2026-03-09T03:59:00Z", "2026-03-09T04:00:00Z", "2026-02-01T12:00:00Z", "2026-03-10T12:00:00Z"].enumerated().map { index, time in
            AITokenRecord(id: String(index), provider: .codex, timestamp: date(time), model: "fixture", tokens: .init(input: 1))
        }
        let result = AIDailyTokenHistory.totals(records, provider: .codex, now: date("2026-03-09T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(result[calendar.startOfDay(for: records[0].timestamp)]?.total, 1)
        XCTAssertEqual(result[calendar.startOfDay(for: records[1].timestamp)]?.total, 2)
        XCTAssertEqual(result[calendar.startOfDay(for: records[3].timestamp)]?.total, 1)
        XCTAssertEqual(result.count, 3)
    }

}
