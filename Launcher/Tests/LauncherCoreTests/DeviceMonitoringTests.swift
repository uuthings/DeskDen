import XCTest
@testable import LauncherCore

final class DeviceMonitoringTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var utc: TimeZone { TimeZone(secondsFromGMT: 0)! }
    func counter(_ bytes: UInt64) -> [String: DeviceNetworkCounter] { ["en0": .init(received: bytes, sent: bytes / 10)] }
    func budget() -> DeviceTrafficBudget { var b = DeviceTrafficBudget(); b.enabled = true; b.notificationsEnabled = true; b.limitGB = 1; return b }
    func rule() -> DeviceTemperatureRule { var r = DeviceTemperatureRule(); r.enabled = true; r.notificationsEnabled = true; r.sustainedSeconds = 5; r.cooldownMinutes = 1; return r }
    func summary(_ bytes: UInt64, period: DeviceBudgetPeriod = .month, scope: DeviceTrafficScope = .all, date: Date? = nil) -> DeviceTrafficSummary {
        var s = DeviceTrafficLedger(now: start, timeZone: utc).summary(period: period, scope: scope, at: date ?? start)
        s.received = bytes; return s
    }
    func testSettingsStartDisabledAndRejectNonfiniteOrOutOfRangeValues() throws {
        XCTAssertFalse(DeviceTrafficBudget().enabled); XCTAssertFalse(DeviceTemperatureRule().enabled)
        var b = budget(); b.limitGB = .nan; XCTAssertThrowsError(try b.validated())
        b.limitGB = .infinity; XCTAssertThrowsError(try b.validated())
        b.limitGB = 1; b.warningPercent = 100; XCTAssertThrowsError(try b.validated())
        b.warningPercent = 80; XCTAssertEqual(try b.validated().limitBytes, 1_000_000_000)
        var r = rule(); r.cpuThreshold = .nan; XCTAssertThrowsError(try r.validated())
        r.cpuThreshold = 85; r.sustainedSeconds = 0; XCTAssertThrowsError(try r.validated())
        r.sustainedSeconds = 30; r.cooldownMinutes = 0; XCTAssertThrowsError(try r.validated())
        r.cooldownMinutes = 15; XCTAssertNoThrow(try r.validated())
        XCTAssertEqual(try JSONDecoder().decode(DeviceTrafficBudget.self, from: JSONEncoder().encode(b)), b)
        XCTAssertEqual(try JSONDecoder().decode(DeviceTemperatureRule.self, from: JSONEncoder().encode(r)), r)
    }
    func testIndependentScopesIncludeBothDirectionsWithoutVPNDoubleCounting() {
        var a = DeviceTrafficAccumulator(ledger: .init(now: start, timeZone: utc))
        a.ingest(wifi: counter(100), ethernet: ["en1": .init(received: 500, sent: 200)], at: start, maximumGap: 6)
        a.ingest(wifi: counter(1100), ethernet: ["en1": .init(received: 2500, sent: 600)], at: start.addingTimeInterval(2), maximumGap: 6)
        let all = a.ledger.summary(period: .day, scope: .all, at: start.addingTimeInterval(2))
        XCTAssertEqual(all.received, 3000); XCTAssertEqual(all.sent, 500); XCTAssertEqual(all.totalBytes, 3500)
        XCTAssertEqual(a.ledger.summary(period: .day, scope: .wifi, at: start).totalBytes, 1100)
        XCTAssertEqual(a.ledger.summary(period: .day, scope: .ethernet, at: start).totalBytes, 2400)
    }
    func testScopeSwitchPreservesHistoricalBucketsAndRestartExcludesGap() throws {
        var a = DeviceTrafficAccumulator(ledger: .init(now: start, timeZone: utc))
        a.ingest(wifi: counter(100), ethernet: [:], at: start, maximumGap: 6)
        a.ingest(wifi: counter(1100), ethernet: [:], at: start.addingTimeInterval(2), maximumGap: 6)
        let restored = try JSONDecoder().decode(DeviceTrafficLedger.self, from: JSONEncoder().encode(a.ledger))
        var resumed = DeviceTrafficAccumulator(ledger: restored)
        resumed.ingest(wifi: counter(1_000_000), ethernet: [:], at: start.addingTimeInterval(3600), maximumGap: 6)
        let result = resumed.ledger.summary(period: .month, scope: .wifi, at: start.addingTimeInterval(3600))
        XCTAssertEqual(result.totalBytes, 1100); XCTAssertEqual(result.coveredSeconds, 2)
        XCTAssertGreaterThan(result.excludedIntervals, 0); XCTAssertTrue(result.isPartialPeriod)
        XCTAssertEqual(resumed.ledger.timeZoneIdentifier, utc.identifier)
    }
    func testPeriodsUseMondayAndMonthBoundariesWithFixedRecordingTimezone() {
        let ledger = DeviceTrafficLedger(now: start, timeZone: utc), c = ledger.calendar
        let week = ledger.summary(period: .week, scope: .all, at: start)
        XCTAssertEqual(c.component(.weekday, from: week.periodStart), 2)
        let month = ledger.summary(period: .month, scope: .all, at: start)
        XCTAssertEqual(c.component(.day, from: month.periodStart), 1)
        XCTAssertEqual(c.component(.day, from: month.periodEnd), 1)
        XCTAssertEqual(month.dailyUsage.count, c.component(.day, from: start))
        XCTAssertTrue(month.isPartialPeriod)
    }
    func testMidnightAndInterfaceDisconnectDoNotInventTraffic() {
        var a = DeviceTrafficAccumulator(ledger: .init(now: start, timeZone: utc)); let c = a.ledger.calendar
        let midnight = c.date(byAdding: .day, value: 1, to: c.startOfDay(for: start))!
        a.ingest(wifi: counter(100), ethernet: [:], at: midnight.addingTimeInterval(-1), maximumGap: 6)
        a.ingest(wifi: counter(10_000), ethernet: [:], at: midnight.addingTimeInterval(1), maximumGap: 6)
        XCTAssertEqual(a.ledger.summary(period: .day, scope: .all, at: midnight).totalBytes, 0)
        a.ingest(wifi: [:], ethernet: [:], at: midnight.addingTimeInterval(3), maximumGap: 6)
        a.ingest(wifi: counter(20_000), ethernet: [:], at: midnight.addingTimeInterval(5), maximumGap: 6)
        a.ingest(wifi: counter(21_000), ethernet: [:], at: midnight.addingTimeInterval(7), maximumGap: 6)
        XCTAssertEqual(a.ledger.summary(period: .day, scope: .all, at: midnight.addingTimeInterval(7)).totalBytes, 1100)
    }
    func testBudgetWarningAndExceededDeduplicateAcrossRestartAndResetPerCycle() throws {
        var e = DeviceMonitoringEvaluator(), b = budget()
        XCTAssertEqual(e.evaluateBudget(b, summary: summary(800_000_000)), [.budgetWarning(percent: 80)])
        XCTAssertEqual(e.evaluateBudget(b, summary: summary(900_000_000)), [])
        XCTAssertEqual(e.evaluateBudget(b, summary: summary(1_000_000_000)), [.budgetExceeded])
        var restored = DeviceMonitoringEvaluator(state: try JSONDecoder().decode(DeviceMonitoringState.self, from: JSONEncoder().encode(e.state)))
        XCTAssertEqual(restored.evaluateBudget(b, summary: summary(1_100_000_000)), [])
        XCTAssertEqual(restored.evaluateBudget(b, summary: summary(1_100_000_000, date: start.addingTimeInterval(40 * 86400))), [.budgetExceeded])
        b.scope = .wifi
        XCTAssertEqual(restored.evaluateBudget(b, summary: summary(900_000_000, scope: .all)), [])
        XCTAssertEqual(restored.evaluateBudget(b, summary: summary(900_000_000, scope: .wifi)), [.budgetWarning(percent: 80)])
    }
    func testJumpOverBudgetDoesNotSendTwoNotificationsAndDisabledRulesStaySilent() {
        var e = DeviceMonitoringEvaluator(), b = budget()
        XCTAssertEqual(e.evaluateBudget(b, summary: summary(2_000_000_000)), [.budgetExceeded])
        b.enabled = false; XCTAssertEqual(e.evaluateBudget(b, summary: summary(2_000_000_000, date: start.addingTimeInterval(40 * 86400))), [])
        b.enabled = true; b.notificationsEnabled = false
        XCTAssertEqual(e.evaluateBudget(b, summary: summary(2_000_000_000, date: start.addingTimeInterval(40 * 86400))), [])
    }
    func testTemperatureRequiresContinuousSamplesAndRecoveryAndCooldown() {
        var e = DeviceMonitoringEvaluator(); let r = rule()
        XCTAssertEqual(e.evaluateTemperature(r, cpu: 90, gpu: 50, at: start, maximumGap: 3), [])
        for t in [2.0, 4.0] { XCTAssertEqual(e.evaluateTemperature(r, cpu: 90, gpu: 50, at: start.addingTimeInterval(t), maximumGap: 3), []) }
        XCTAssertEqual(e.evaluateTemperature(r, cpu: 90, gpu: 50, at: start.addingTimeInterval(6), maximumGap: 3), [.temperature(sensor: "CPU", value: 90)])
        XCTAssertEqual(e.evaluateTemperature(r, cpu: 90, gpu: 50, at: start.addingTimeInterval(70), maximumGap: 3), [])
        _ = e.evaluateTemperature(r, cpu: 70, gpu: 50, at: start.addingTimeInterval(72), maximumGap: 3)
        for t in [74.0,76.0,78.0] { XCTAssertEqual(e.evaluateTemperature(r, cpu: 90, gpu: 50, at: start.addingTimeInterval(t), maximumGap: 3), []) }
        XCTAssertEqual(e.evaluateTemperature(r, cpu: 90, gpu: 50, at: start.addingTimeInterval(80), maximumGap: 3), [.temperature(sensor: "CPU", value: 90)])
    }
    func testMissingDataSleepAndClockRollbackBreakSustainedTemperature() {
        for interrupted: Double? in [nil, .nan] {
            var e = DeviceMonitoringEvaluator(); let r = rule()
            _ = e.evaluateTemperature(r, cpu: 90, gpu: nil, at: start, maximumGap: 3)
            _ = e.evaluateTemperature(r, cpu: interrupted, gpu: nil, at: start.addingTimeInterval(2), maximumGap: 3)
            _ = e.evaluateTemperature(r, cpu: 90, gpu: nil, at: start.addingTimeInterval(4), maximumGap: 3)
            XCTAssertEqual(e.evaluateTemperature(r, cpu: 90, gpu: nil, at: start.addingTimeInterval(6), maximumGap: 3), [])
            XCTAssertEqual(e.evaluateTemperature(r, cpu: 90, gpu: nil, at: start.addingTimeInterval(90), maximumGap: 3), [])
            XCTAssertEqual(e.evaluateTemperature(r, cpu: 90, gpu: nil, at: start.addingTimeInterval(2), maximumGap: 3), [])
        }
    }
    func testTemperatureCooldownAndRecoverySurviveRestart() throws {
        var e = DeviceMonitoringEvaluator(); let r = rule()
        for t in stride(from: 0.0, through: 6.0, by: 2) { _ = e.evaluateTemperature(r, cpu: 90, gpu: 90, at: start.addingTimeInterval(t), maximumGap: 3) }
        var restored = DeviceMonitoringEvaluator(state: try JSONDecoder().decode(DeviceMonitoringState.self, from: JSONEncoder().encode(e.state)))
        for t in stride(from: 8.0, through: 20.0, by: 2) { XCTAssertEqual(restored.evaluateTemperature(r, cpu: 90, gpu: 90, at: start.addingTimeInterval(t), maximumGap: 3), []) }
        _ = restored.evaluateTemperature(r, cpu: 60, gpu: 60, at: start.addingTimeInterval(22), maximumGap: 3)
        for t in stride(from: 24.0, through: 64.0, by: 2) { XCTAssertEqual(restored.evaluateTemperature(r, cpu: 90, gpu: 90, at: start.addingTimeInterval(t), maximumGap: 3), []) }
        XCTAssertEqual(restored.evaluateTemperature(r, cpu: 90, gpu: 90, at: start.addingTimeInterval(66), maximumGap: 3).count, 2)
    }
    func testLedgerValidationRejectsCorruptDurationsCountsAndScopeMetadata() throws {
        var ledger = DeviceTrafficLedger(now: start, timeZone: utc), day = DeviceNetworkDay()
        let key = DeviceNetworkLedger.dayKey(start, calendar: ledger.calendar)
        day.excludedIntervals = Int.max; ledger.scopes[.all]?.days[key] = day
        XCTAssertThrowsError(try ledger.validated())
        day.excludedIntervals = -1; ledger.scopes[.all]?.days[key] = day
        XCTAssertThrowsError(try ledger.validated())
        day.excludedIntervals = 0; day.coveredSeconds = -.infinity; ledger.scopes[.all]?.days[key] = day
        XCTAssertThrowsError(try ledger.validated())
        day.coveredSeconds = -2; ledger.scopes[.all]?.days[key] = day
        XCTAssertThrowsError(try ledger.validated())
        day.coveredSeconds = 2; ledger.scopes[.all]?.days[key] = day
        XCTAssertNoThrow(try ledger.validated())
        ledger.timeZoneIdentifier = "not-a-time-zone"; XCTAssertThrowsError(try ledger.validated())
    }
    func testGapIncrementAndSummarySaturateEvenForUnvalidatedInMemoryCounts() {
        var ledger = DeviceTrafficLedger(now: start, timeZone: utc), day = DeviceNetworkDay()
        day.excludedIntervals = Int.max; day.lastSample = start
        let key = DeviceNetworkLedger.dayKey(start, calendar: ledger.calendar)
        ledger.scopes[.all]?.days[key] = day
        var accumulator = DeviceNetworkAccumulator(ledger: ledger.scopes[.all]!)
        _ = accumulator.ingest(counter(100), at: start.addingTimeInterval(2), maximumGap: 6, calendar: ledger.calendar)
        _ = accumulator.ingest(counter(1_000_000), at: start.addingTimeInterval(200), maximumGap: 6, calendar: ledger.calendar)
        XCTAssertEqual(accumulator.ledger.days[key]?.excludedIntervals, Int.max)
        let priorDate = start.addingTimeInterval(-86_400)
        let priorKey = DeviceNetworkLedger.dayKey(priorDate, calendar: ledger.calendar)
        ledger.scopes[.all]?.days[priorKey] = day
        XCTAssertEqual(ledger.summary(period: .month, scope: .all, at: start).excludedIntervals, Int.max)
    }
    func testTurningTemperatureRuleOffCancelsPendingDuration() {
        var e = DeviceMonitoringEvaluator(), r = rule()
        _ = e.evaluateTemperature(r, cpu: 90, gpu: nil, at: start, maximumGap: 3)
        r.enabled = false; _ = e.evaluateTemperature(r, cpu: 90, gpu: nil, at: start.addingTimeInterval(2), maximumGap: 3)
        r.enabled = true
        XCTAssertEqual(e.evaluateTemperature(r, cpu: 90, gpu: nil, at: start.addingTimeInterval(4), maximumGap: 3), [])
        XCTAssertEqual(e.evaluateTemperature(r, cpu: 90, gpu: nil, at: start.addingTimeInterval(6), maximumGap: 3), [])
    }
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!
        c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    func testLegacyBudgetDecodesAndKeepsItsNotificationIdentity() throws {
        let data = Data(#"{"enabled":true,"period":"month","scope":"wifi","limitGB":20,"warningPercent":85,"notificationsEnabled":true}"#.utf8)
        let b = try JSONDecoder().decode(DeviceTrafficBudget.self, from: data).validated()
        XCTAssertNil(b.cycleAnchor); XCTAssertNil(b.customStart); XCTAssertNil(b.customEndInclusive)
        XCTAssertEqual(b.identity, "month:wifi:20000000000:85")
        XCTAssertEqual(try JSONDecoder().decode(DeviceTrafficBudget.self, from: JSONEncoder().encode(b)), b)
    }
    func testMonthlyBillingOnFifteenthHasExclusiveNextFifteenthBoundary() {
        let c = calendar("America/New_York")
        var b = budget(); b.cycleAnchor = .init(year: 2026, month: 10, day: 15)
        let interval = b.interval(at: date(2026, 10, 21, calendar: c), calendar: c)
        XCTAssertEqual(interval.start, date(2026, 10, 15, calendar: c))
        XCTAssertEqual(interval.end, date(2026, 11, 15, calendar: c))
        let next = b.interval(at: interval.end, calendar: c)
        XCTAssertEqual(next.start, interval.end); XCTAssertEqual(next.end, date(2026, 12, 15, calendar: c))
        // The November DST transition adds one real hour; no fixed 30-day arithmetic.
        XCTAssertEqual(interval.duration, 31 * 86_400 + 3600)
    }
    func testMonthEndBillingDoesNotDriftAfterFebruary() {
        let c = calendar(); var b = budget(); b.cycleAnchor = .init(year: 2024, month: 1, day: 31)
        let leap = b.interval(at: date(2024, 2, 29, 12, calendar: c), calendar: c)
        XCTAssertEqual(leap.start, date(2024, 2, 29, calendar: c)); XCTAssertEqual(leap.end, date(2024, 3, 31, calendar: c))
        let normal = b.interval(at: date(2025, 2, 28, 12, calendar: c), calendar: c)
        XCTAssertEqual(normal.start, date(2025, 2, 28, calendar: c)); XCTAssertEqual(normal.end, date(2025, 3, 31, calendar: c))
        XCTAssertEqual(b.interval(at: date(2024, 1, 15, calendar: c), calendar: c).start, date(2023, 12, 31, calendar: c))
    }
    func testQuarterAndYearSupportNaturalAndAnchoredCycles() {
        let c = calendar(); var b = budget(); b.period = .quarter
        XCTAssertEqual(b.interval(at: date(2026, 5, 20, calendar: c), calendar: c).start, date(2026, 4, 1, calendar: c))
        b.cycleAnchor = .init(year: 2026, month: 2, day: 15)
        let quarter = b.interval(at: date(2026, 5, 14, calendar: c), calendar: c)
        XCTAssertEqual(quarter.start, date(2026, 2, 15, calendar: c)); XCTAssertEqual(quarter.end, date(2026, 5, 15, calendar: c))
        b.period = .year; b.cycleAnchor = .init(year: 2024, month: 2, day: 29)
        let year = b.interval(at: date(2027, 8, 1, calendar: c), calendar: c)
        XCTAssertEqual(year.start, date(2027, 2, 28, calendar: c)); XCTAssertEqual(year.end, date(2028, 2, 29, calendar: c))
        b.cycleAnchor = nil
        XCTAssertEqual(b.interval(at: date(2026, 10, 21, calendar: c), calendar: c).start, date(2026, 1, 1, calendar: c))
    }
    func testCustomDatesIncludeWholeEndDayAcrossDSTAndRejectInvalidRanges() throws {
        let c = calendar("America/New_York"); var b = budget(); b.period = .custom
        b.customStart = .init(year: 2026, month: 3, day: 8); b.customEndInclusive = b.customStart
        XCTAssertNoThrow(try b.validated())
        let spring = b.interval(at: date(2026, 3, 8, 12, calendar: c), calendar: c)
        XCTAssertEqual(spring.duration, 23 * 3600); XCTAssertEqual(spring.end, date(2026, 3, 9, calendar: c))
        b.customStart = .init(year: 2026, month: 11, day: 1); b.customEndInclusive = b.customStart
        XCTAssertEqual(b.interval(at: date(2026, 11, 1, 12, calendar: c), calendar: c).duration, 25 * 3600)
        b.customEndInclusive = .init(year: 2026, month: 10, day: 31); XCTAssertThrowsError(try b.validated())
        b.customStart = .init(year: 2026, month: 2, day: 30); XCTAssertThrowsError(try b.validated())
        b.customStart = nil; XCTAssertThrowsError(try b.validated())
    }
    func testCustomSummaryCountsOnlySelectedMeasuredDaysAndNeverFutureBuckets() {
        let c = calendar("America/New_York"), now = date(2026, 10, 21, 12, calendar: calendar("America/New_York"))
        var ledger = DeviceTrafficLedger(now: date(2026, 10, 1, calendar: c), timeZone: c.timeZone)
        for d in [14, 15, 16, 17, 22] {
            var bucket = DeviceNetworkDay(); bucket.received = UInt64(d); bucket.sent = UInt64(d * 2); bucket.coveredSeconds = 2
            ledger.scopes[.all]?.days[DeviceNetworkLedger.dayKey(date(2026, 10, d, calendar: c), calendar: c)] = bucket
        }
        var b = budget(); b.period = .custom; b.customStart = .init(year: 2026, month: 10, day: 15); b.customEndInclusive = .init(year: 2026, month: 10, day: 16)
        let ended = ledger.summary(budget: b, at: now)
        XCTAssertEqual(ended.totalBytes, (15 + 16) * 3); XCTAssertEqual(ended.dailyUsage.count, 2)
        XCTAssertFalse(ended.isActivePeriod); XCTAssertTrue(ended.isPartialPeriod)
        b.customEndInclusive = .init(year: 2026, month: 10, day: 25)
        let active = ledger.summary(budget: b, at: now)
        XCTAssertEqual(active.totalBytes, (15 + 16 + 17) * 3); XCTAssertEqual(active.dailyUsage.count, 7)
        XCTAssertTrue(active.isActivePeriod)
        b.customStart = .init(year: 2026, month: 11, day: 1); b.customEndInclusive = .init(year: 2026, month: 11, day: 30)
        let future = ledger.summary(budget: b, at: now)
        XCTAssertEqual(future.totalBytes, 0); XCTAssertTrue(future.dailyUsage.isEmpty); XCTAssertFalse(future.hasStarted)
    }
    func testAnnualHistoryAndLongCustomTotalsAreNotLimitedByChartWindow() {
        let c = calendar(), now = date(2026, 10, 21, calendar: calendar())
        var ledger = DeviceTrafficLedger(now: date(2020, 1, 1, calendar: c), timeZone: c.timeZone)
        var bucket = DeviceNetworkDay(); bucket.received = 123; bucket.coveredSeconds = 2
        ledger.scopes[.all]?.days["2020-01-01"] = bucket; ledger.scopes[.all]?.days["2026-10-21"] = bucket
        var b = budget(); b.period = .custom; b.customStart = .init(year: 2020, month: 1, day: 1); b.customEndInclusive = .init(year: 2026, month: 12, day: 31)
        let summary = ledger.summary(budget: b, at: now)
        XCTAssertEqual(summary.totalBytes, 246); XCTAssertEqual(summary.dailyUsage.count, 400)
        XCTAssertEqual(summary.dailyUsage.reduce(0) { $0 + $1.totalBytes }, 123)
        XCTAssertTrue(summary.isPartialPeriod)
        b.period = .year
        XCTAssertEqual(ledger.summary(budget: b, at: now).dailyUsage.count, 294)
    }
    func testAlertUsesSavedBillingCycleAndStaysSilentOutsideCustomDates() {
        let c = calendar(), now = date(2026, 10, 21, 12, calendar: calendar())
        let ledger = DeviceTrafficLedger(now: now, timeZone: c.timeZone)
        var b = budget(); b.cycleAnchor = .init(year: 2026, month: 10, day: 15)
        var e = DeviceMonitoringEvaluator(), s = ledger.summary(budget: b, at: now); s.received = 900_000_000
        XCTAssertEqual(e.evaluateBudget(b, summary: s), [.budgetWarning(percent: 80)])
        XCTAssertEqual(e.evaluateBudget(b, summary: s), [])
        b.cycleAnchor = .init(year: 2026, month: 10, day: 16)
        XCTAssertEqual(e.evaluateBudget(b, summary: s), [], "A stale old-cycle summary must not trigger a newly saved rule")
        s = ledger.summary(budget: b, at: now); s.received = 900_000_000
        XCTAssertEqual(e.evaluateBudget(b, summary: s), [.budgetWarning(percent: 80)])
        b.period = .custom; b.customStart = .init(year: 2026, month: 10, day: 1); b.customEndInclusive = .init(year: 2026, month: 10, day: 20)
        s = ledger.summary(budget: b, at: now); s.received = 2_000_000_000
        XCTAssertEqual(e.evaluateBudget(b, summary: s), [])
        b.customStart = .init(year: 2026, month: 11, day: 1); b.customEndInclusive = .init(year: 2026, month: 11, day: 30)
        s = ledger.summary(budget: b, at: now); s.received = 2_000_000_000
        XCTAssertEqual(e.evaluateBudget(b, summary: s), [])
    }

}
