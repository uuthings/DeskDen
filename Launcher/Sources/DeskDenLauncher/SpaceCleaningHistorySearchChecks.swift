import Foundation
import LauncherCore

/// Pure metadata fixtures. No filesystem, Trash, model or native UI is touched.
enum SpaceCleaningHistorySearchChecks {
    @MainActor static func runAsync() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        let items = (0..<10_000).map { index in
            CleaningHistoryItemDisplay(id: UUID(), name: "history-\(index).txt", bytes: 32, allocatedBytes: 4096,
                state: .trashed, statusText: "在废纸篓", explanation: "", canRestore: true, canPurge: true,
                originalURL: URL(fileURLWithPath: "/history-fixture/history-\(index).txt"), resultURL: nil)
        }
        let batch = CleaningHistoryBatchDisplay(id: UUID(), date: Date(), method: .trash, items: items, bytes: 320_000)
        let model = CleaningHistorySearchModel()
        model.rebuild([batch], timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        model.query = "history-1.txt"
        model.query = "history-9999.txt"
        check(model.isUpdating && model.matches.isEmpty, "pending history queries expose no stale actionable rows")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.isUpdating && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        check(!model.isUpdating && model.matches.first?.items.map(\.id) == [items[9999].id],
              "the newest query wins while a ten-thousand-record index is built in the background")
        model.query = ""
        check(model.isUpdating && model.matches.isEmpty, "clearing search hides the partial list until complete batch results are ready")
        while model.isUpdating && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        check(!model.isUpdating && model.matchedItemCount == 10_000 && model.matches.first?.items.count == 10_000,
              "cleared history search restores the full batch before batch operations return")
        model.rebuild([], timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        while model.isUpdating && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        check(!model.isUpdating && model.matches.isEmpty && model.totalItemCount == 0,
              "a new empty history revision cannot be overwritten by an earlier projection")
        model.cancel()
        return (count, failures)
    }

    static func run() -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        func item(_ name: String, parent: String, bytes: UInt64, state: SpaceCleaningRecordState, status: String) -> CleaningHistoryItemDisplay {
            CleaningHistoryItemDisplay(id: UUID(), name: name, bytes: bytes, allocatedBytes: bytes + 32,
                state: state, statusText: status, explanation: "Recorded metadata only", canRestore: state == .trashed,
                canPurge: state == .trashed, originalURL: URL(fileURLWithPath: parent).appendingPathComponent(name),
                resultURL: nil)
        }
        let video = item("项目演示.MOV", parent: "/history-fixture/Downloads", bytes: 1_000_000, state: .trashed, status: "在废纸篓")
        let cache = item("Code Cache", parent: "/history-fixture/Library/Caches", bytes: 2_000_000, state: .trashed, status: "在废纸篓")
        let skipped = item("draft.zip", parent: "/history-fixture/Downloads", bytes: 3_000_000, state: .skipped, status: "已跳过")
        let deleted = item("旧文档.pdf", parent: "/history-fixture/Documents", bytes: 4_000_000, state: .deleted, status: "已永久删除")
        let date = ISO8601DateFormatter().date(from: "2026-11-03T01:30:00Z")!
        let first = CleaningHistoryBatchDisplay(id: UUID(), date: date, method: .trash, items: [video, cache, skipped], bytes: 6_000_000)
        let second = CleaningHistoryBatchDisplay(id: UUID(), date: date.addingTimeInterval(-86_400), method: .permanent, items: [deleted], bytes: 4_000_000)
        let batches = [first, second]
        let beijing = TimeZone(identifier: "Asia/Shanghai")!
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let beijingIndex = CleaningHistorySearchIndex(batches, timeZone: beijing)!
        let losAngelesIndex = CleaningHistorySearchIndex(batches, timeZone: losAngeles)!
        func search(_ query: String, zone: TimeZone? = nil) -> [CleaningHistorySearchMatch] {
            (zone == losAngeles ? losAngelesIndex : beijingIndex).project(query)?.matches ?? []
        }
        check(search("  \n ").map(\.id) == batches.map(\.id), "blank history search preserves all batches and order")
        let byName = search("项目演示.mov")
        check(byName.count == 1 && byName.first?.items.map(\.id) == [video.id], "history search matches Chinese names and case-insensitive extensions")
        check(byName.first?.batch.items.count == 3 && byName.first?.batch.allocatedBytes == first.allocatedBytes,
              "filtered history retains complete batch count and allocated total")
        check(search("Library/Caches").first?.items.map(\.id) == [cache.id], "history search uses recorded original paths")
        check(search("2026年11月03日").first?.items.count == 3, "date-only search reveals every item in the matching batch")
        check(search("2026-11-03 09:30").first?.id == first.id, "history search formats timestamps in the selected workbench time zone")
        check(search("2026-11-02 17:30", zone: losAngeles).first?.id == first.id,
              "the same history timestamp follows Los Angeles date and time")
        check(search("2026-11-03", zone: losAngeles).isEmpty, "history search does not leak the computer or another city's calendar date")
        check(search("2026年11月3日 演示").first?.items.map(\.id) == [video.id], "date and name terms narrow a batch to matching items")
        check(search("移入废纸篓").first?.items.count == 3, "method search keeps the entire matching batch including skipped outcomes")
        check(search("已跳过").first?.items.map(\.id) == [skipped.id], "status search exposes only the matching skipped record")
        check(search("永久删除").first?.items.map(\.id) == [deleted.id], "permanent deletion is searchable without offering restore targets")
        check(search("ＬＩＢＲＡＲＹ").first?.items.map(\.id) == [cache.id], "history search normalizes full-width case without changing stored text")
        check(search("missing metadata").isEmpty, "unmatched history search produces an explicit empty result")
        check(batches[0].items.map(\.id) == [video.id, cache.id, skipped.id] && batches[0].restorableCount == 2 && batches[0].purgeableCount == 2,
              "search never mutates restoration or deletion scope")
        check(!SpaceCleaningHistorySearch.isSearching(" \n") && SpaceCleaningHistorySearch.isSearching(" 项目 "),
              "batch action visibility follows substantive search terms")
        check(SpaceCleaningHistorySearch.batchStatus(first) == "部分完成" && SpaceCleaningHistorySearch.batchStatus(second) == "已完成",
              "batch summaries distinguish partial and completed processing")
        check(beijingIndex.totalItemCount == 4 && beijingIndex.batchCount == 2 && beijingIndex.restorableCount == 2,
              "history index caches complete source counts independently of search")
        let cleared = beijingIndex.project("")
        check(cleared?.itemCount == 4 && cleared?.matches.first?.items.count == 3 && cleared?.matches.first?.summary.purgeableCount == 2,
              "clearing a filtered query restores the complete batch with its original action counts")
        check(CleaningHistorySearchIndex(batches, timeZone: beijing, isCancelled: { true }) == nil,
              "cancelled history indexing cannot publish a partial source")
        check(beijingIndex.project("cache", isCancelled: { true }) == nil,
              "cancelled history filtering cannot publish stale actionable matches")
        return (count, failures)
    }
}
