import Foundation
import XCTest
@testable import LauncherCore

final class AIUsageRetentionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC
    private func row(_ id: String, at date: Date, input: Int64 = 10) -> AITokenRecord {
        .init(id: id, provider: .codex, timestamp: date, model: "synthetic", tokens: .init(input: input))
    }
    func testAFullYearKeepsRecentDetailsAndExactObservedMonthlyTotals() throws {
        var ledger = AITokenLedger(now: start)
        // Feed a real year's worth of distinct observations through daily pruning.
        for day in 0..<365 {
            let date = start.addingTimeInterval(Double(day) * 86_400)
            let rows = (0..<100).map { row("\(day)-\($0)", at: date, input: Int64($0 + 1)) }
            try ledger.ingest(rows, at: date)
            try ledger.ingest(rows, at: date.addingTimeInterval(60)) // repeated scans must not double count
            XCTAssertLessThanOrEqual(ledger.records.count, 3_200)
        }
        let now = start.addingTimeInterval(364 * 86_400 + 60)
        let summaries = try ledger.monthlySummaries(now: now)
        XCTAssertEqual(summaries.reduce(0) { $0 + $1.tokens.total }, 365 * 5_050)
        XCTAssertEqual(summaries.reduce(0) { $0 + $1.recordCount }, 36_500)
        XCTAssertEqual(summaries.count, 12)
        XCTAssertFalse(ledger.capacityLimited)
        let data = try JSONEncoder().encode(ledger)
        XCTAssertLessThan(data.count, 1_048_576)
        let reopened = try JSONDecoder().decode(AITokenLedger.self, from: data)
        try reopened.validate()
        XCTAssertEqual(try reopened.monthlySummaries(now: now), summaries)
    }
    func testClockRollbackAndReconnectedOldLogsCannotDoubleCountArchivedUsage() throws {
        var ledger = AITokenLedger(now: start)
        let original = row("old", at: start)
        try ledger.ingest([original], at: start)
        let later = start.addingTimeInterval(40 * 86_400)
        try ledger.ingest([], at: later)
        XCTAssertTrue(ledger.records.isEmpty)
        try ledger.ingest([original], at: start.addingTimeInterval(10 * 86_400))
        XCTAssertTrue(ledger.records.isEmpty)
        XCTAssertEqual(try ledger.monthlySummaries(now: later).reduce(0) { $0 + $1.tokens.total }, 10)
    }
    func testSummaryWindowStaysBoundedAcrossFifteenYears() throws {
        var ledger = AITokenLedger(now: start)
        for month in 0..<180 {
            let date = AITokenMonthSummary.calendar.date(byAdding: .month, value: month, to: start)!
            try ledger.ingest([row("month-\(month)", at: date)], at: date)
            XCTAssertLessThanOrEqual(ledger.archivedMonths.count, 120)
        }
        let date = AITokenMonthSummary.calendar.date(byAdding: .month, value: 179, to: start)!
        XCTAssertEqual(try ledger.monthlySummaries(now: date).count, 120)
    }
    func testClockRollbackPreservesPreviouslyObservedRecentDetails() throws {
        var ledger = AITokenLedger(now: start)
        let observed = start.addingTimeInterval(7_200)
        try ledger.ingest([row("accepted-before-clock-change", at: observed)], at: observed)
        try ledger.ingest([row("unobserved-future", at: observed.addingTimeInterval(600))], at: start)
        XCTAssertEqual(ledger.records.map(\.id), ["accepted-before-clock-change"])
        XCTAssertEqual(ledger.updatedAt, observed)
    }
    func testExtremeFiniteDatesAreRejectedWithoutCalendarCrashes() throws {
        var ledger = AITokenLedger(now: start)
        let invalid = Date(timeIntervalSince1970: Double.greatestFiniteMagnitude)
        XCTAssertThrowsError(try ledger.ingest([row("invalid", at: invalid)], at: start))
        XCTAssertThrowsError(try ledger.ingest([], at: invalid))
        XCTAssertThrowsError(try ledger.monthlySummaries(now: invalid))
        XCTAssertThrowsError(try AITokenMonthSummary.month(containing: invalid))
    }
    func testVersionOneLedgerMigratesWithoutInventingMissingHistory() throws {
        var ledger = AITokenLedger(now: start)
        try ledger.ingest([row("old-format", at: start)], at: start)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        object["schemaVersion"] = 1; object.removeValue(forKey: "archivedMonths"); object.removeValue(forKey: "archivedBefore")
        var restored = try JSONDecoder().decode(AITokenLedger.self, from: JSONSerialization.data(withJSONObject: object))
        try restored.validate()
        XCTAssertEqual(restored.records, ledger.records); XCTAssertTrue(restored.archivedMonths.isEmpty)
        try restored.ingest([], at: start.addingTimeInterval(40 * 86_400))
        XCTAssertEqual(restored.archivedMonths.first?.tokens.total, 10)
    }
    func testCacheEvictsByRecencyCostSourceAndAge() {
        var cache = AIUsageParseCache(maximumEntries: 2, maximumCost: 4_096, maximumItems: 4)
        let parsed = AIUsageParsedFile(records: [row("a", at: start)], snapshots: [])
        cache.insert(parsed, for: "a", size: 1, modified: start, now: start)
        cache.insert(parsed, for: "b", size: 1, modified: start, now: start)
        XCTAssertNotNil(cache.value(for: "a", size: 1, modified: start, now: start))
        cache.insert(parsed, for: "c", size: 1, modified: start, now: start)
        XCTAssertNil(cache.value(for: "b", size: 1, modified: start, now: start))
        XCTAssertEqual(cache.count, 2)
        cache.retain(keys: ["c"], now: start)
        XCTAssertEqual(cache.count, 1)
        cache.retain(keys: ["c"], now: start.addingTimeInterval(32 * 86_400))
        XCTAssertEqual(cache.count, 0)
        cache.insert(.init(records: (0..<5).map { row(String($0), at: start) }, snapshots: []), for: "oversize", size: 5, modified: start, now: start)
        XCTAssertEqual(cache.count, 0)
    }
    func testChangingThousandsOfSourceFilesCannotGrowTheCacheAcrossYears() {
        var cache = AIUsageParseCache(maximumEntries: 12, maximumCost: 16_384, maximumItems: 20)
        for day in 0..<730 {
            let now = start.addingTimeInterval(Double(day) * 86_400)
            var eligible = Set<String>()
            for file in 0..<20 {
                let key = "source-\(day)-\(file)"; eligible.insert(key)
                cache.insert(.init(records: [row(key, at: now)], snapshots: []), for: key, size: 128, modified: now, now: now)
            }
            cache.retain(keys: eligible, now: now)
            XCTAssertLessThanOrEqual(cache.count, 12); XCTAssertLessThanOrEqual(cache.itemCount, 20)
            XCTAssertLessThanOrEqual(cache.estimatedBytes, 16_384)
        }
        cache.retain(keys: [], now: start.addingTimeInterval(730 * 86_400))
        XCTAssertEqual(cache.count, 0)
    }
    func testCachedFileInvalidationAndRecordExpiryAreIndependentOfFileModification() {
        var cache = AIUsageParseCache()
        let modified = start.addingTimeInterval(30 * 86_400)
        cache.insert(.init(records: [row("old-row", at: start)], snapshots: []), for: "file", size: 128, modified: modified, now: modified)
        XCTAssertEqual(cache.value(for: "file", size: 128, modified: modified, now: start.addingTimeInterval(32 * 86_400))?.records.count, 0)
        XCTAssertNil(cache.value(for: "file", size: 129, modified: modified, now: modified))
    }
    func testBackgroundHistoryStoreDoesNotRewriteUnchangedData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokens = AITokenLedgerStore(url: directory.appendingPathComponent("tokens.json"))
        let store = AIUsageHistoryStore(tokens: tokens, quotaURL: directory.appendingPathComponent("quota.json"),
            ledger: .init(now: start), quotaHistory: [], canWriteTokens: true, canWriteQuota: true)
        let first = await store.update(records: [row("first", at: start)], snapshots: [], now: start)
        XCTAssertNil(first.tokenError)
        let bytes = try Data(contentsOf: tokens.url)
        _ = await store.update(records: [row("first", at: start)], snapshots: [], now: start.addingTimeInterval(60))
        try await store.flush()
        XCTAssertEqual(try Data(contentsOf: tokens.url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokens.backupURL.path))
    }
    func testClockRollbackPreservesAlreadySavedQuotaSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let observed = start.addingTimeInterval(7_200)
        let snapshot = AIQuotaSnapshot(provider: .codex, observedAt: observed, source: .localSession,
            shortWindow: try .init(usedPercent: 10, durationMinutes: 300, resetsAt: observed.addingTimeInterval(3_600)), weeklyWindow: nil)
        let store = AIUsageHistoryStore(tokens: .init(url: directory.appendingPathComponent("tokens.json")),
            quotaURL: directory.appendingPathComponent("quota.json"), ledger: .init(now: observed), quotaHistory: [], canWriteTokens: true, canWriteQuota: true)
        _ = await store.update(records: [], snapshots: [snapshot], now: observed)
        let result = await store.update(records: [], snapshots: [], now: start)
        XCTAssertEqual(result.quotaHistory, [snapshot])
    }
}
