import Foundation
import XCTest
@testable import LauncherCore

final class ProviderUsageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    func testCumulativeTrafficCrossesHoursWithoutBecomingProviderUsage() {
        var state = ProviderUsageRefreshState(); let policy = ProviderUsageRefreshPolicy()
        state.ingest(.init(epoch: now, received: 10, sent: 0)); state.succeeded(at: now, acknowledgedBytes: 0)
        for hour in 1...3 {
            state.ingest(.init(epoch: now, received: 10 + UInt64(hour) * 300_000_000, sent: 0))
            XCTAssertFalse(state.isDue(at: now.addingTimeInterval(Double(hour) * 3600), policy: policy))
        }
        state.ingest(.init(epoch: now, received: 1_200_000_010, sent: 0))
        XCTAssertTrue(state.isDue(at: now.addingTimeInterval(4 * 3600), policy: policy))
        XCTAssertFalse(state.isDue(at: now.addingTimeInterval(3599), policy: policy))
        XCTAssertEqual(state.pendingBytes, 1_200_000_000)
    }
    func testIdleMaximumAndRequestStartAcknowledgement() {
        var state = ProviderUsageRefreshState(); let policy = ProviderUsageRefreshPolicy()
        state.succeeded(at: now, acknowledgedBytes: 0)
        XCTAssertFalse(state.isDue(at: now.addingTimeInterval(21599), policy: policy))
        XCTAssertTrue(state.isDue(at: now.addingTimeInterval(21600), policy: policy))
        state.ingest(.init(epoch: now, received: 0, sent: 0))
        state.ingest(.init(epoch: now, received: 1_000_000_000, sent: 400_000_000))
        let acknowledged = state.begin(at: now)
        state.ingest(.init(epoch: now, received: 1_200_000_000, sent: 500_000_000))
        state.succeeded(at: now.addingTimeInterval(2), acknowledgedBytes: acknowledged)
        XCTAssertEqual(state.pendingBytes, 300_000_000)
    }
    func testRetryAuthenticationAndRestartPreserveTraffic() throws {
        var state = ProviderUsageRefreshState()
        state.pendingBytes = 2_000_000_000
        _ = state.begin(at: now); state.failed(.rateLimited(retryAfter: 7200), at: now)
        XCTAssertFalse(state.isDue(at: now.addingTimeInterval(7199), policy: .init(), manual: true))
        XCTAssertTrue(state.isDue(at: now.addingTimeInterval(7200), policy: .init()))
        let restored = try JSONDecoder().decode(ProviderUsageRefreshState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.pendingBytes, 2_000_000_000)
        state.failed(.authentication, at: now)
        XCTAssertFalse(state.isDue(at: now.addingTimeInterval(100_000), policy: .init(), manual: true))
        state.reconnect(); XCTAssertFalse(state.isDue(at: now, policy: .init(), manual: true))
        XCTAssertTrue(state.isDue(at: now.addingTimeInterval(7200), policy: .init(), manual: true))
        XCTAssertEqual(state.pendingBytes, 2_000_000_000)
    }
    func testManualRetryAfterRepairPreservesAutomaticBackoffAndServerLimits() {
        var state = ProviderUsageRefreshState()
        state.pendingBytes = 400_000_000
        _ = state.begin(at: now)
        state.failed(.unavailable("fixture connection interrupted"), at: now)
        let retry = now.addingTimeInterval(1)
        XCTAssertFalse(state.isDue(at: retry, policy: .init()))
        XCTAssertTrue(state.isDue(at: retry, policy: .init(), manual: true))
        XCTAssertEqual(state.pendingBytes, 400_000_000)
        state.failed(.rateLimited(retryAfter: 3600), at: now)
        XCTAssertFalse(state.isDue(at: retry, policy: .init(), manual: true))
        state.reconnect()
        XCTAssertFalse(state.isDue(at: retry, policy: .init(), manual: true))
    }
    func testResetTriggersOnceAndPersistsItsIdentity() throws {
        let reset = now.addingTimeInterval(5000)
        var state = ProviderUsageRefreshState(); state.succeeded(at: now, acknowledgedBytes: 0)
        XCTAssertFalse(state.isDue(at: reset.addingTimeInterval(-1), policy: .init(), resetAt: reset))
        XCTAssertTrue(state.isDue(at: reset, policy: .init(), resetAt: reset))
        let amount = state.begin(at: reset)
        XCTAssertTrue(state.isDue(at: reset, policy: .init(), resetAt: reset), "An interrupted reset query must remain due")
        state.succeeded(at: reset, acknowledgedBytes: amount, checkedReset: reset)
        let restored = try JSONDecoder().decode(ProviderUsageRefreshState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(restored.isDue(at: reset.addingTimeInterval(3600), policy: .init(), resetAt: reset))
        XCTAssertTrue(restored.isDue(at: reset.addingTimeInterval(7200), policy: .init(), resetAt: reset.addingTimeInterval(7200)))
    }
    func testCounterResetAndEpochChangeRebaseWithoutForgingTraffic() {
        var state = ProviderUsageRefreshState()
        state.ingest(.init(epoch: now, received: 100, sent: 100))
        state.ingest(.init(epoch: now, received: 300, sent: 200))
        state.ingest(.init(epoch: now, received: 20, sent: 20))
        state.ingest(.init(epoch: now.addingTimeInterval(1), received: 8_000, sent: 8_000))
        XCTAssertEqual(state.pendingBytes, 300)
        state.ingest(.init(epoch: now.addingTimeInterval(1), received: 8_010, sent: 8_005))
        XCTAssertEqual(state.pendingBytes, 315)
    }
    func testDateOnlyResetAndMissingLimitAreNotGuessed() throws {
        var snapshot = ProviderUsageSnapshot(sourceID: UUID(), observedAt: now, usedBytes: 30, limitBytes: 100,
            resetDateText: "2026-10-25", displayUnit: .decimalGB, sourceDescription: "fixture")
        try snapshot.validate(now: now); XCTAssertNil(snapshot.resetsAt)
        snapshot.resetDateText = "2026-02-30"; XCTAssertThrowsError(try snapshot.validate(now: now))
        snapshot.resetDateText = nil; snapshot.limitBytes = 0; XCTAssertThrowsError(try snapshot.validate(now: now))
    }
    func testStoreProtectsMalformedOriginalAndRoundTripsIndependentSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderUsageStore(url: directory.appendingPathComponent("usage.json"))
        var document = ProviderUsageDocument()
        document.sources = [.init(kind: .iproyal, name: "First", resourceID: "101"), .init(kind: .bandwagon, name: "Second", resourceID: "202")]
        var first = ProviderUsageSourceState(); first.refresh.pendingBytes = 300
        document.states[document.sources[0].id] = first
        try store.save(document); XCTAssertEqual(try store.load(), document)
        let invalid = Data("{ broken".utf8); try invalid.write(to: store.url)
        XCTAssertThrowsError(try store.save(.init())); XCTAssertEqual(try Data(contentsOf: store.url), invalid)
    }
}
