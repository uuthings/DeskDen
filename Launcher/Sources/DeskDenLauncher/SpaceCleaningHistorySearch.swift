import Foundation
import Combine
import LauncherCore

struct CleaningHistoryBatchSummary: Sendable {
    let allocatedBytes: UInt64
    let restorableCount: Int
    let purgeableCount: Int
    let status: String
    let hasAttention: Bool

    init(_ batch: CleaningHistoryBatchDisplay) {
        allocatedBytes = batch.allocatedBytes
        restorableCount = batch.restorableCount
        purgeableCount = batch.purgeableCount
        status = SpaceCleaningHistorySearch.batchStatus(batch)
        hasAttention = SpaceCleaningHistorySearch.hasAttention(batch)
    }
}

struct CleaningHistorySearchMatch: Identifiable, Sendable {
    let batch: CleaningHistoryBatchDisplay
    let items: [CleaningHistoryItemDisplay]
    let summary: CleaningHistoryBatchSummary
    var id: UUID { batch.id }
}

struct CleaningHistorySearchProjection: Sendable {
    let matches: [CleaningHistorySearchMatch]
    let itemCount: Int
}

/// Date strings and searchable text are prepared once per history/time-zone
/// revision; each query only compares normalized terms against immutable text.
struct CleaningHistorySearchIndex: Sendable {
    private struct Entry: Sendable {
        let batch: CleaningHistoryBatchDisplay
        let summary: CleaningHistoryBatchSummary
        let sharedText: String
        let itemText: [String]
    }
    private let entries: [Entry]
    let totalItemCount: Int
    let restorableCount: Int
    let batchCount: Int

    init?(_ batches: [CleaningHistoryBatchDisplay], timeZone: TimeZone, isCancelled: @Sendable () -> Bool = { false }) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        var prepared: [Entry] = [], count = 0, restorable = 0
        prepared.reserveCapacity(batches.count)
        for batch in batches {
            guard !isCancelled() else { return nil }
            let summary = CleaningHistoryBatchSummary(batch)
            let dates = ["yyyy年MM月dd日 HH:mm", "yyyy年M月d日", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm"].map { pattern in
                formatter.dateFormat = pattern
                return formatter.string(from: batch.date)
            }
            let shared = SpaceCleaningHistorySearch.normalized((dates + [SpaceCleaningHistorySearch.methodTitle(batch.method), summary.status, timeZone.identifier]).joined(separator: " "))
            var itemText: [String] = []
            itemText.reserveCapacity(batch.items.count)
            for item in batch.items {
                guard !isCancelled() else { return nil }
                itemText.append(SpaceCleaningHistorySearch.normalized([item.name, item.originalURL.path, item.statusText, SpaceCleaningHistorySearch.statusKeywords(item)].joined(separator: " ")))
            }
            prepared.append(Entry(batch: batch, summary: summary, sharedText: shared, itemText: itemText))
            count += batch.items.count
            restorable += summary.restorableCount
        }
        entries = prepared
        totalItemCount = count
        restorableCount = restorable
        batchCount = batches.count
    }

    func project(_ query: String, isCancelled: @Sendable () -> Bool = { false }) -> CleaningHistorySearchProjection? {
        let terms = SpaceCleaningHistorySearch.normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [CleaningHistorySearchMatch] = [], count = 0
        matches.reserveCapacity(entries.count)
        for entry in entries {
            guard !isCancelled() else { return nil }
            let itemTerms = terms.filter { !entry.sharedText.contains($0) }
            let matched: [CleaningHistoryItemDisplay]
            if itemTerms.isEmpty { matched = entry.batch.items }
            else {
                var filtered: [CleaningHistoryItemDisplay] = []
                for (index, text) in entry.itemText.enumerated() {
                    guard !isCancelled() else { return nil }
                    if itemTerms.allSatisfy({ text.contains($0) }) { filtered.append(entry.batch.items[index]) }
                }
                matched = filtered
            }
            if !matched.isEmpty || terms.isEmpty {
                matches.append(.init(batch: entry.batch, items: matched, summary: entry.summary))
                count += matched.count
            }
        }
        return .init(matches: matches, itemCount: count)
    }
}

@MainActor final class CleaningHistorySearchModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { requestProjection() } } }
    @Published private(set) var matches: [CleaningHistorySearchMatch] = []
    @Published private(set) var isUpdating = false
    @Published private(set) var totalItemCount = 0
    @Published private(set) var matchedItemCount = 0
    @Published private(set) var restorableCount = 0
    @Published private(set) var batchCount = 0
    private var index: CleaningHistorySearchIndex?
    private var build: Task<CleaningHistorySearchIndex?, Never>?
    private var projection: Task<CleaningHistorySearchProjection?, Never>?
    private var sourceRevision: UInt64 = 0
    private var queryRevision: UInt64 = 0

    func rebuild(_ batches: [CleaningHistoryBatchDisplay], timeZone: TimeZone) {
        build?.cancel()
        projection?.cancel()
        sourceRevision &+= 1
        queryRevision &+= 1
        let revision = sourceRevision
        index = nil
        isUpdating = true
        matches = []
        matchedItemCount = 0
        let work = Task.detached(priority: .userInitiated) {
            CleaningHistorySearchIndex(batches, timeZone: timeZone, isCancelled: { Task.isCancelled })
        }
        build = work
        Task { [weak self] in
            guard let prepared = await work.value, let self, self.sourceRevision == revision else { return }
            self.index = prepared
            self.totalItemCount = prepared.totalItemCount
            self.restorableCount = prepared.restorableCount
            self.batchCount = prepared.batchCount
            self.build = nil
            self.requestProjection()
        }
    }

    private func requestProjection() {
        projection?.cancel()
        queryRevision &+= 1
        let revision = queryRevision
        isUpdating = true
        matches = []
        matchedItemCount = 0
        guard let index else { return }
        let query = query
        let work = Task.detached(priority: .userInitiated) {
            index.project(query, isCancelled: { Task.isCancelled })
        }
        projection = work
        Task { [weak self] in
            guard let result = await work.value, let self, self.queryRevision == revision else { return }
            self.matches = result.matches
            self.matchedItemCount = result.itemCount
            self.isUpdating = false
            self.projection = nil
        }
    }

    func cancel() {
        build?.cancel()
        projection?.cancel()
        sourceRevision &+= 1
        queryRevision &+= 1
    }
}

/// Searches recorded metadata only. Results retain the complete batch so a
/// filtered item list never replaces its totals or an operation's target set.
enum SpaceCleaningHistorySearch {
    static func isSearching(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func project(_ batches: [CleaningHistoryBatchDisplay], query: String, timeZone: TimeZone) -> [CleaningHistorySearchMatch] {
        CleaningHistorySearchIndex(batches, timeZone: timeZone)?.project(query)?.matches ?? []
    }

    static func methodTitle(_ method: SpaceCleaningMethod) -> String {
        method == .trash ? "移入废纸篓" : "永久删除"
    }

    static func batchStatus(_ batch: CleaningHistoryBatchDisplay) -> String {
        let succeeded = batch.items.filter { [.trashed, .deleted, .restored].contains($0.state) }.count
        if batch.attentionCount > 0 { return succeeded > 0 ? "部分完成" : "需要核对" }
        if batch.items.allSatisfy({ $0.state == .restored }) { return "已恢复" }
        if succeeded == batch.items.count { return "已完成" }
        return succeeded > 0 ? "部分完成" : "未完成"
    }

    static func hasAttention(_ batch: CleaningHistoryBatchDisplay) -> Bool {
        batch.attentionCount > 0 || batch.items.contains { [.skipped, .cancelled].contains($0.state) }
    }

    fileprivate static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    fileprivate static func statusKeywords(_ item: CleaningHistoryItemDisplay) -> String {
        switch item.state {
        case .trashed: "已移入废纸篓 可恢复"
        case .deleted: "已永久删除 已删除"
        case .restored: "已恢复"
        case .skipped: "已跳过 未处理"
        case .cancelled: "已取消 未处理"
        case .failed: "处理失败 未完成"
        case .needsReview, .prepared, .isolated, .deleting, .restoring: "需要核对"
        }
    }
}
