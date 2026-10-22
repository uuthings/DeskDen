import Foundation
import XCTest
@testable import LauncherCore

final class AIUsageCoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func line(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func codex(_ total: Int, last: Int, timestamp: String = "2026-10-18T10:00:00Z", rates: [String: Any]? = nil) throws -> Data {
        var payload: [String: Any] = ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "cached_input_tokens": total / 2, "output_tokens": total / 10], "last_token_usage": ["input_tokens": last, "cached_input_tokens": last / 2, "output_tokens": last / 10]]]
        if let rates { payload["rate_limits"] = rates }
        return try line(["type": "event_msg", "timestamp": timestamp, "payload": payload])
    }
    func testCodexCumulativeRecordsDoNotDoubleCount() throws {
        var parser = AIUsageLogParser()
        for (total, last) in [(100,100),(100,100),(300,200),(300,200)] { parser.consume(try codex(total, last: last), provider: .codex, sourceID: "session") }
        XCTAssertEqual(parser.records.count, 2)
        let total = parser.records.reduce(AITokenCounts()) { $0 + $1.tokens }
        XCTAssertEqual(total.total, 330); XCTAssertEqual(total.input, 150); XCTAssertEqual(total.cacheRead, 150); XCTAssertEqual(total.output, 30)
    }
    func testCodexCumulativeResetUsesLastCall() throws {
        var parser = AIUsageLogParser()
        parser.consume(try codex(100, last: 100), provider: .codex, sourceID: "session")
        parser.consume(try codex(40, last: 40), provider: .codex, sourceID: "session")
        XCTAssertEqual(parser.records.map(\.tokens.total), [110,44])
    }
    func testCodexInitialPartialHistoryUsesLastUsage() throws {
        var parser = AIUsageLogParser()
        parser.consume(try codex(10_000, last: 100), provider: .codex, sourceID: "session")
        XCTAssertEqual(parser.records.first?.tokens.total, 110)
    }
    func testTokenUsageNeverCreatesQuota() throws {
        var parser = AIUsageLogParser(); parser.consume(try codex(100, last: 100), provider: .codex, sourceID: "s")
        XCTAssertFalse(parser.records.isEmpty); XCTAssertTrue(parser.snapshots.isEmpty)
    }
    func testCodexActualWindowDurationAndMissingSecondary() throws {
        var parser = AIUsageLogParser()
        parser.consume(try codex(100, last: 100, rates: ["limit_id":"codex", "primary": ["used_percent": 23.5, "window_minutes": 300, "resets_at": 1_800_000_000]]), provider: .codex, sourceID: "s")
        XCTAssertEqual(parser.snapshots.first?.shortWindow?.usedPercent, 23.5)
        XCTAssertEqual(parser.snapshots.first?.shortWindow?.durationMinutes, 300)
        XCTAssertNil(parser.snapshots.first?.weeklyWindow)
    }
    func testOtherCodexQuotaBucketIsNotLabeledMainCodex() throws {
        var parser = AIUsageLogParser()
        parser.consume(try codex(100, last: 100, rates: ["limit_id":"codex_other", "primary": ["used_percent":80, "window_minutes":60]]), provider: .codex, sourceID: "s")
        XCTAssertTrue(parser.snapshots.isEmpty)
    }
    func testOfficialCamelCaseCodexQuota() {
        let snapshot = AIUsageLogParser.codexQuota(["primary": ["usedPercent":25, "windowDurationMins":15, "resetsAt":1_800_000_001]], date: now, source: .imported)
        XCTAssertEqual(snapshot?.shortWindow?.durationMinutes, 15)
        XCTAssertEqual(snapshot?.shortWindow?.resetsAt?.timeIntervalSince1970, 1_800_000_001)
    }
    func testClaudeCachesAreDistinctFromFreshInput() throws {
        var parser = AIUsageLogParser()
        parser.consume(try line(["type":"assistant", "timestamp":"2026-10-18T10:00:00.000Z", "message":["id":"m1", "model":"claude-test", "usage":["input_tokens":10, "output_tokens":20, "cache_read_input_tokens":30, "cache_creation_input_tokens":40], "content":[["type":"text", "text":"PRIVATE_SENTINEL"]]]]), provider: .claude, sourceID: "s")
        XCTAssertEqual(parser.records.first?.tokens.total, 100)
        let encoded = try JSONEncoder().encode(parser.records)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE_SENTINEL"))
        XCTAssertTrue(parser.snapshots.isEmpty)
    }
    func testClaudeStreamingAndCopiedRecordsDeduplicate() {
        let a = AITokenRecord(id:"m", provider:.claude, timestamp:now, model:"x", tokens:.init(input:10, output:5, cacheRead:30))
        let b = AITokenRecord(id:"m", provider:.claude, timestamp:now.addingTimeInterval(2), model:"x", tokens:.init(input:10, output:20, cacheRead:30))
        let result = AIUsageAggregation.deduplicate([a,b,a])
        XCTAssertEqual(result.count,1); XCTAssertEqual(result[0].tokens.total,60)
    }
    func testProviderIdentityPreventsCrossProviderDeduplication() {
        let a = AITokenRecord(id:"same", provider:.codex, timestamp:now, model:"x", tokens:.init(input:1))
        let b = AITokenRecord(id:"same", provider:.claude, timestamp:now, model:"x", tokens:.init(input:1))
        XCTAssertEqual(AIUsageAggregation.deduplicate([a,b]).count,2)
    }
    func testClaudeOfficialStatusLineQuota() {
        let snapshot = AIUsageLogParser.claudeQuota(["five_hour":["used_percentage":23.5,"resets_at":1_800_000_010],"seven_day":["used_percentage":41.2,"resets_at":1_800_000_020]],date:now)
        XCTAssertEqual(snapshot?.source,.claudeStatusLine)
        XCTAssertEqual(snapshot?.shortWindow?.usedPercent,23.5)
        XCTAssertEqual(snapshot?.weeklyWindow?.durationMinutes,10_080)
    }
    func testContextWindowPercentageNeverBecomesQuota() {
        XCTAssertNil(AIUsageLogParser.claudeQuota(["used_percentage":55,"context_window":["used_percentage":55]], date:now))
    }
    func testInvalidQuotaDoesNotBecomeZero() {
        for value: Any in [-1, 101, "50", true, NSNull()] {
            XCTAssertNil(AIUsageLogParser.claudeQuota(["five_hour":["used_percentage":value]],date:now))
        }
    }
    func testStaleByAgeAndResetPreservesValue() throws {
        let window = try AIQuotaWindow(usedPercent:72, durationMinutes:300, resetsAt:now.addingTimeInterval(600))
        var snapshot = AIQuotaSnapshot(provider:.codex, observedAt:now, source:.localSession, shortWindow:window, weeklyWindow:nil)
        XCTAssertFalse(snapshot.isStale(at:now.addingTimeInterval(300)))
        XCTAssertTrue(snapshot.isStale(at:now.addingTimeInterval(601)))
        XCTAssertEqual(snapshot.shortWindow?.usedPercent,72)
        snapshot.shortWindow?.resetsAt = nil
        XCTAssertTrue(snapshot.isStale(at:now.addingTimeInterval(901)))
    }
    func testQuotaValidationRejectsFutureAndResetBeforeObservation() throws {
        let window = try AIQuotaWindow(usedPercent:1, durationMinutes:300, resetsAt:now.addingTimeInterval(-1))
        XCTAssertThrowsError(try AIQuotaSnapshot(provider:.claude,observedAt:now,source:.manual,shortWindow:window,weeklyWindow:nil).validate(now:now))
        XCTAssertThrowsError(try AIQuotaSnapshot(provider:.claude,observedAt:now.addingTimeInterval(301),source:.manual,shortWindow:window,weeklyWindow:nil).validate(now:now))
        XCTAssertThrowsError(try AIQuotaSnapshot(provider:.claude,observedAt:now,source:.manual,shortWindow:nil,weeklyWindow:nil).validate(now:now))
    }
    func testImportLabelsUserSourceAndRoundTrips() throws {
        let snapshot = AIQuotaSnapshot(provider:.claude, observedAt:now, source:.claudeStatusLine, shortWindow:try .init(usedPercent:30,durationMinutes:300,resetsAt:now.addingTimeInterval(600)), weeklyWindow:nil)
        let decoded = try AIQuotaImport.decode(AIQuotaImport.encode(snapshot),now:now)
        XCTAssertEqual(decoded.source,.imported); XCTAssertEqual(decoded.shortWindow?.usedPercent,30)
    }
    func testImportAcceptsFractionalISOTime() throws {
        let json = "{\"provider\":\"claude\",\"source\":\"manual\",\"observedAt\":\"2026-10-18T10:00:00.123Z\",\"shortWindow\":{\"usedPercent\":20,\"durationMinutes\":300}}"
        let value = try AIQuotaImport.decode(Data(json.utf8), now: now)
        XCTAssertEqual(value.shortWindow?.usedPercent, 20)
    }
    func testInvalidImportDoesNotAcceptOversizeOrPercent() throws {
        XCTAssertThrowsError(try AIQuotaImport.decode(Data(repeating:32,count:262_145),now:now))
        let bad = "{\"provider\":\"codex\",\"observedAt\":\"2026-10-18T10:00:00Z\",\"source\":\"manual\",\"shortWindow\":{\"usedPercent\":200,\"durationMinutes\":300}}"
        XCTAssertThrowsError(try AIQuotaImport.decode(Data(bad.utf8),now:now))
    }
    func testMalformedAndConversationRecordsAreIgnored() {
        var parser = AIUsageLogParser()
        for text in ["broken", "{\"type\":\"user\",\"content\":\"SECRET\"}","{\"type\":\"assistant\",\"message\":{\"content\":\"SECRET\"}}"] { parser.consume(Data(text.utf8),provider:.claude,sourceID:"s") }
        XCTAssertTrue(parser.records.isEmpty); XCTAssertTrue(parser.snapshots.isEmpty)
    }
    func testActivityIncludesZerosAndExcludesFuture() {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!
        let start = calendar.startOfDay(for:now)
        let records = [AITokenRecord(id:"a",provider:.codex,timestamp:start.addingTimeInterval(60),model:"m",tokens:.init(input:10)), AITokenRecord(id:"b",provider:.codex,timestamp:now.addingTimeInterval(60),model:"m",tokens:.init(input:999))]
        let buckets = AIUsageAggregation.buckets(records,period:.today,now:now,calendar:calendar)
        XCTAssertEqual(buckets.count,24); XCTAssertEqual(buckets.reduce(0){$0+$1.tokens.total},10)
        XCTAssertEqual(AIUsageAggregation.buckets([],period:.week,now:now,calendar:calendar).count,7)
        XCTAssertEqual(AIUsageAggregation.buckets([],period:.month,now:now,calendar:calendar).count,30)
    }
    func testSeverityBoundaries() throws {
        XCTAssertEqual(try AIQuotaWindow(usedPercent:74.9,durationMinutes:300,resetsAt:nil).severity,0)
        XCTAssertEqual(try AIQuotaWindow(usedPercent:75,durationMinutes:300,resetsAt:nil).severity,1)
        XCTAssertEqual(try AIQuotaWindow(usedPercent:90,durationMinutes:300,resetsAt:nil).severity,2)
    }
    func testPriceUsesFourDisjointTokenCategories() throws {
        let price = try AITokenPrice(provider:.codex,model:"test",inputPerMillion:2,outputPerMillion:4,cacheReadPerMillion:1,cacheWritePerMillion:3)
        XCTAssertEqual(price.estimate(.init(input:1_000_000,output:1_000_000,cacheRead:1_000_000,cacheWrite:1_000_000)),10,accuracy:0.001)
        XCTAssertThrowsError(try AITokenPrice(provider:.codex,model:"test",inputPerMillion:-1,outputPerMillion:0,cacheReadPerMillion:0,cacheWritePerMillion:0))
    }
}
