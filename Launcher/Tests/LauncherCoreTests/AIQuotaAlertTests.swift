import Foundation
import XCTest
@testable import LauncherCore

final class AIQuotaAlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_600_000)
    private var rule: AIQuotaAlertRule { var value = AIQuotaAlertRule(); value.enabled = true; return value }
    private func summary(_ provider: AIProvider = .codex, percent: Double = 80, week: Double? = nil, observed: Date? = nil, reset: Date? = nil, state: AIUsageState = .ready, source: AIQuotaSource = .localSession) throws -> AIProviderSummary {
        let short = try AIQuotaWindow(usedPercent: percent, durationMinutes: 300, resetsAt: reset ?? now.addingTimeInterval(3_600))
        let weekly = try week.map { try AIQuotaWindow(usedPercent: $0, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)) }
        return .init(provider: provider, state: state, snapshot: .init(provider: provider, observedAt: observed ?? now, source: source, shortWindow: short, weeklyWindow: weekly), detail: "test")
    }

    func testRulesRequireExplicitEnableAndIncreasingThresholds() throws {
        XCTAssertFalse(AIQuotaAlertRule().enabled)
        XCTAssertTrue(AIQuotaAlertEvaluator().pendingEvents(rule: .init(), summaries: [try summary()], at: now).isEmpty)
        for (warning, critical) in [(0, 90), (75, 100), (90, 75), (75, 75)] {
            var changed = rule; changed.warningPercent = warning; changed.criticalPercent = critical
            XCTAssertThrowsError(try changed.validate())
            XCTAssertTrue(AIQuotaAlertEvaluator().pendingEvents(rule: changed, summaries: [try summary()], at: now).isEmpty)
        }
    }

    func testProvidersAndWindowsRemainIndependent() throws {
        let events = AIQuotaAlertEvaluator().pendingEvents(rule: rule, summaries: [try summary(percent: 76, week: 95), try summary(.claude, percent: 96, week: 78, source: .claudeStatusLine)], at: now)
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(Set(events.map(\.id)).count, 4)
        XCTAssertEqual(events.filter { $0.level == .critical }.count, 2)
        XCTAssertEqual(Set(events.map(\.provider)), Set(AIProvider.allCases))
    }

    func testFailedOrUnacknowledgedDeliveryDoesNotConsumeThreshold() throws {
        let evaluator = AIQuotaAlertEvaluator()
        let summaries = [try summary()]
        let first = evaluator.pendingEvents(rule: rule, summaries: summaries, at: now)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(evaluator.pendingEvents(rule: rule, summaries: summaries, at: now), first)
    }

    func testWarningThenCriticalIsDeliveredOncePerActualWindow() throws {
        var evaluator = AIQuotaAlertEvaluator()
        let warning = try XCTUnwrap(evaluator.pendingEvents(rule: rule, summaries: [try summary()], at: now).first)
        evaluator.recordDelivery(warning, at: now)
        XCTAssertTrue(evaluator.pendingEvents(rule: rule, summaries: [try summary()], at: now).isEmpty)
        let high = try summary(percent: 95)
        let critical = try XCTUnwrap(evaluator.pendingEvents(rule: rule, summaries: [high], at: now).first)
        XCTAssertEqual(critical.level, .critical)
        evaluator.recordDelivery(critical, at: now)
        XCTAssertTrue(evaluator.pendingEvents(rule: rule, summaries: [high], at: now).isEmpty)
        evaluator.recordDelivery(warning, at: now) // An earlier async delivery finishing later cannot downgrade it.
        XCTAssertTrue(evaluator.pendingEvents(rule: rule, summaries: [high], at: now).isEmpty)
    }

    func testFirstCriticalSampleDoesNotEmitAnExtraWarning() throws {
        let events = AIQuotaAlertEvaluator().pendingEvents(rule: rule, summaries: [try summary(percent: 98)], at: now)
        XCTAssertEqual(events.map(\.level), [.critical])
    }

    func testNewResetIdentityCanAlertAgainAfterPersistedDelivery() throws {
        var evaluator = AIQuotaAlertEvaluator()
        let event = try XCTUnwrap(evaluator.pendingEvents(rule: rule, summaries: [try summary()], at: now).first)
        evaluator.recordDelivery(event, at: now)
        let state = try JSONDecoder().decode(AIQuotaAlertState.self, from: JSONEncoder().encode(evaluator.state))
        let restored = AIQuotaAlertEvaluator(state: state)
        XCTAssertTrue(restored.pendingEvents(rule: rule, summaries: [try summary()], at: now).isEmpty)
        XCTAssertEqual(restored.pendingEvents(rule: rule, summaries: [try summary(reset: now.addingTimeInterval(7_200))], at: now).count, 1)
    }

    func testStaleMissingDisconnectedErrorsExpiredAndFutureSamplesDoNotAlert() throws {
        let evaluator = AIQuotaAlertEvaluator()
        for state in [AIUsageState.stale, .unavailable, .disconnected, .error] {
            XCTAssertTrue(evaluator.pendingEvents(rule: rule, summaries: [try summary(state: state)], at: now).isEmpty)
        }
        for observed in [now.addingTimeInterval(-901), now.addingTimeInterval(1)] {
            XCTAssertTrue(evaluator.pendingEvents(rule: rule, summaries: [try summary(observed: observed)], at: now).isEmpty)
        }
        XCTAssertTrue(evaluator.pendingEvents(rule: rule, summaries: [try summary(reset: now)], at: now).isEmpty)
        XCTAssertTrue(evaluator.pendingEvents(rule: rule, summaries: [.init(provider: .codex, state: .ready, snapshot: nil, detail: "missing")], at: now).isEmpty)
    }

    func testUnknownResetDoesNotInventCycleChangesOrRepeatOnRefresh() throws {
        var sample = try summary()
        sample.snapshot?.shortWindow?.resetsAt = nil
        var evaluator = AIQuotaAlertEvaluator()
        let event = try XCTUnwrap(evaluator.pendingEvents(rule: rule, summaries: [sample], at: now).first)
        evaluator.recordDelivery(event, at: now)
        sample.snapshot?.observedAt = now.addingTimeInterval(60)
        XCTAssertTrue(evaluator.pendingEvents(rule: rule, summaries: [sample], at: now.addingTimeInterval(60)).isEmpty)
    }

    func testSameWindowInTwoUpstreamSlotsProducesOnlyOneEvent() throws {
        var sample = try summary()
        let repeated = sample.snapshot?.shortWindow
        sample.snapshot?.weeklyWindow = repeated
        XCTAssertEqual(AIQuotaAlertEvaluator().pendingEvents(rule: rule, summaries: [sample], at: now).count, 1)
    }

    func testRuleAndDeduplicationStateSurviveIndependentStoreReload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AIQuotaAlertStore(url: folder.appendingPathComponent("alerts.json"))
        var value = AIQuotaAlertConfiguration(); value.rule = rule
        var evaluator = AIQuotaAlertEvaluator()
        evaluator.recordDelivery(try XCTUnwrap(evaluator.pendingEvents(rule: rule, summaries: [try summary()], at: now).first), at: now)
        value.state = evaluator.state
        try store.save(value)
        XCTAssertEqual(try AIQuotaAlertStore(url: store.url).load(), value)
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testCorruptOrFutureRuleFileCannotBeReplacedByDefaults() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AIQuotaAlertStore(url: folder.appendingPathComponent("alerts.json"))
        var future = AIQuotaAlertConfiguration(); future.schemaVersion = 2
        for bytes in [Data("{broken".utf8), try JSONEncoder().encode(future)] {
            try bytes.write(to: store.url)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(.init()))
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        }
    }

    func testHistorySegmentsDoNotConnectAcrossResetGapSourceOrBackwardsReadings() throws {
        func snapshot(_ seconds: Double, _ percent: Double, reset: Double = 3_600, source: AIQuotaSource = .localSession) throws -> AIQuotaSnapshot {
            .init(provider: .codex, observedAt: now.addingTimeInterval(seconds), source: source,
                  shortWindow: try .init(usedPercent: percent, durationMinutes: 300, resetsAt: now.addingTimeInterval(reset)), weeklyWindow: nil)
        }
        let samples = try [snapshot(0, 40), snapshot(60, 45), snapshot(120, 10, reset: 7_200), snapshot(1_500, 12, reset: 7_200), snapshot(1_560, 8, reset: 7_200), snapshot(1_620, 9, reset: 7_200, source: .manual)]
        let segments = AIQuotaHistorySegmentation.segments(samples, provider: .codex)
        XCTAssertEqual(segments.count, 5)
        XCTAssertEqual(segments.first?.points.map(\.usedPercent), [40, 45])
        XCTAssertEqual(segments.flatMap(\.points).count, samples.count)
    }

    func testHistoryWithUnknownResetKeepsObservedPointsWithoutInventingAConnectingWindow() throws {
        var first = try summary().snapshot!
        first.shortWindow?.resetsAt = nil
        var second = first; second.observedAt = now.addingTimeInterval(60)
        let segments = AIQuotaHistorySegmentation.segments([first, second], provider: .codex)
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.allSatisfy { $0.points.count == 1 })
    }

    func testHistoryMissingWindowBreaksContinuityUntilARealWindowSampleReturns() throws {
        let first = try summary().snapshot!
        var missing = first; missing.observedAt = now.addingTimeInterval(60); missing.shortWindow = nil
        missing.weeklyWindow = try .init(usedPercent: 30, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400))
        var resumed = first; resumed.observedAt = now.addingTimeInterval(120)
        let short = AIQuotaHistorySegmentation.segments([first, missing, resumed], provider: .codex).filter { $0.window.durationMinutes == 300 }
        XCTAssertEqual(short.count, 2)
        XCTAssertTrue(short.allSatisfy { $0.points.count == 1 })
    }
}
