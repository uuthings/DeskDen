import Foundation

public struct AIUsageHistoryUpdate: Sendable {
    public var ledger: AITokenLedger
    public var quotaHistory: [AIQuotaSnapshot]
    public var monthlySummaries: [AITokenMonthSummary]
    public var tokenError: String?
    public var quotaError: String?
}

/// A single serial owner merges, validates and persists usage off the UI thread.
/// Unchanged scans do not rewrite the ledger or its previous-good backup.
public actor AIUsageHistoryStore {
    private let tokens: AITokenLedgerStore
    private let quotaURL: URL
    private let canWriteTokens: Bool
    private let canWriteQuota: Bool
    private var ledger: AITokenLedger
    private var quotaHistory: [AIQuotaSnapshot]
    private var savedLedger: AITokenLedger
    private var savedQuota: [AIQuotaSnapshot]
    public init(tokens: AITokenLedgerStore, quotaURL: URL, ledger: AITokenLedger, quotaHistory: [AIQuotaSnapshot],
                canWriteTokens: Bool, canWriteQuota: Bool) {
        self.tokens = tokens; self.quotaURL = quotaURL; self.ledger = ledger; self.quotaHistory = quotaHistory
        savedLedger = ledger; savedQuota = quotaHistory; self.canWriteTokens = canWriteTokens; self.canWriteQuota = canWriteQuota
    }
    public func update(records: [AITokenRecord], snapshots: [AIQuotaSnapshot], now: Date, sourceCapacityLimited: Bool = false) -> AIUsageHistoryUpdate {
        var tokenError: String?, quotaError: String?
        do {
            try ledger.ingest(records, at: now, sourceCapacityLimited: sourceCapacityLimited)
            if canWriteTokens && (ledger.records != savedLedger.records || ledger.archivedMonths != savedLedger.archivedMonths || ledger.capacityLimited != savedLedger.capacityLimited) {
                try tokens.save(ledger); savedLedger = ledger
            }
        } catch { tokenError = "Token 历史处理或保存失败，保留可用记录：" + error.localizedDescription }
        func key(_ snapshot: AIQuotaSnapshot) -> String {
            snapshot.id + ":" + [snapshot.shortWindow, snapshot.weeklyWindow].compactMap { $0 }.map {
                AIQuotaWindowIdentity(provider: snapshot.provider, durationMinutes: $0.durationMinutes, resetsAt: $0.resetsAt).id
            }.joined(separator: "|")
        }
        var unique = Dictionary(quotaHistory.map { (key($0), $0) }, uniquingKeysWith: { _, newest in newest })
        for snapshot in snapshots where snapshot.observedAt <= now.addingTimeInterval(300) { unique[key(snapshot)] = snapshot }
        let historyNow = max(now, ledger.updatedAt)
        quotaHistory = Array(unique.values.filter { $0.observedAt >= historyNow.addingTimeInterval(-31 * 86_400) }
            .sorted { $0.observedAt == $1.observedAt ? key($0) < key($1) : $0.observedAt < $1.observedAt }.suffix(8_000))
        if canWriteQuota && quotaHistory != savedQuota {
            do {
                if FileManager.default.fileExists(atPath: quotaURL.path) {
                    let info = try quotaURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true else { throw AIUsageError.invalid("额度历史文件类型已改变。") }
                }
                try JSONEncoder().encode(quotaHistory).write(to: quotaURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: quotaURL.path)
                savedQuota = quotaHistory
            } catch { quotaError = "额度历史保存失败：" + error.localizedDescription }
        }
        return .init(ledger: ledger, quotaHistory: quotaHistory, monthlySummaries: (try? ledger.monthlySummaries(now: now)) ?? [],
                     tokenError: tokenError, quotaError: quotaError)
    }
    public func flush() throws {
        if canWriteTokens && (ledger.records != savedLedger.records || ledger.archivedMonths != savedLedger.archivedMonths || ledger.capacityLimited != savedLedger.capacityLimited) {
            try tokens.save(ledger); savedLedger = ledger
        }
        if canWriteQuota && quotaHistory != savedQuota {
            let info = try? quotaURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if FileManager.default.fileExists(atPath: quotaURL.path), info?.isRegularFile != true || info?.isSymbolicLink == true {
                throw AIUsageError.invalid("额度历史文件类型已改变。")
            }
            try JSONEncoder().encode(quotaHistory).write(to: quotaURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: quotaURL.path)
            savedQuota = quotaHistory
        }
    }
}
