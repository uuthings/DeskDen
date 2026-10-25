import Foundation

/// A bounded archive of usage fields only. AITokenRecord has no prompt, response,
/// file path, account credential, or conversation-content property to persist.
public struct AITokenLedger: Codable, Equatable, Sendable {
    public static let retentionDays = 31
    public static let maximumRecords = 20_000
    public static let maximumSummaryMonths = 120
    public var schemaVersion = 2
    public private(set) var createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var records: [AITokenRecord] = []
    public private(set) var capacityLimited = false
    public private(set) var archivedMonths: [AITokenMonthSummary] = []
    /// A monotonic cutoff prevents re-importing already summarized records after
    /// a clock rollback or reconnect. Monthly totals never retain record IDs.
    public private(set) var archivedBefore: Date?
    public init(now: Date = Date()) { createdAt = now; updatedAt = now }

    private enum CodingKeys: String, CodingKey { case schemaVersion, createdAt, updatedAt, records, capacityLimited, archivedMonths, archivedBefore }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 || version == 2 else { throw AIUsageError.invalid("Token 历史格式来自更新版本，原文件已保留。") }
        schemaVersion = 2
        createdAt = try values.decode(Date.self, forKey: .createdAt); updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        records = try values.decode([AITokenRecord].self, forKey: .records)
        capacityLimited = try values.decodeIfPresent(Bool.self, forKey: .capacityLimited) ?? false
        archivedMonths = try values.decodeIfPresent([AITokenMonthSummary].self, forKey: .archivedMonths) ?? []
        archivedBefore = try values.decodeIfPresent(Date.self, forKey: .archivedBefore)
    }

    /// Disconnection is intentionally absent from ingestion. The caller may
    /// stop reading a provider while retaining its already-observed records.
    public mutating func ingest(_ incoming: [AITokenRecord], at now: Date, maximumRecords: Int = Self.maximumRecords, sourceCapacityLimited: Bool = false) throws {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0, now.timeIntervalSince1970 <= 100_000_000_000,
              (1...Self.maximumRecords).contains(maximumRecords) else {
            throw AIUsageError.invalid("Token 历史的保留范围无效。")
        }
        for record in incoming { try Self.validate(record) }
        let cutoff = max(now.addingTimeInterval(-Double(Self.retentionDays) * 86_400), archivedBefore ?? .distantPast)
        let retained = records.filter { $0.timestamp >= cutoff } + incoming.filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(300) }
        let merged = AIUsageAggregation.deduplicate(retained)
        // Combining maximum values from duplicate records must itself remain
        // representable, even when each independent source record was valid.
        for record in merged { try Self.validate(record) }
        var next = self
        next.archivedMonths = try AITokenMonthSummary.merged(archivedMonths, records: records.filter { $0.timestamp < cutoff }, now: max(now, updatedAt))
        next.archivedBefore = cutoff
        next.records = Array(merged.suffix(maximumRecords))
        next.capacityLimited = capacityLimited || merged.count > maximumRecords || sourceCapacityLimited
        next.updatedAt = max(now, updatedAt)
        try next.validate()
        self = next
    }

    public func monthlySummaries(provider: AIProvider? = nil, now: Date = Date()) throws -> [AITokenMonthSummary] {
        try AITokenMonthSummary.merged(archivedMonths, records: records.filter { $0.timestamp <= now }, now: now)
            .filter { provider == nil || $0.provider == provider }
    }

    public func records(provider: AIProvider? = nil, period: AIUsagePeriod, enabledProviders: Set<AIProvider>? = nil, now: Date = Date()) -> [AITokenRecord] {
        let start = period.start(now: now)
        return records.filter { record in
            (provider == nil || record.provider == provider) &&
            (enabledProviders.map { $0.contains(record.provider) } ?? true) &&
            record.timestamp >= start && record.timestamp <= now
        }
    }

    public func validate() throws {
        guard schemaVersion == 2 else { throw AIUsageError.invalid("Token 历史格式来自更新版本，原文件已保留。") }
        guard createdAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince1970 > 0, createdAt.timeIntervalSince1970 <= 100_000_000_000,
              updatedAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970 > 0, updatedAt.timeIntervalSince1970 <= 100_000_000_000,
              records.count <= Self.maximumRecords else { throw AIUsageError.invalid("Token 历史范围无效，原文件已保留。") }
        var identities = Set<String>()
        var totalTokens: Int64 = 0
        for record in records {
            try Self.validate(record)
            guard identities.insert(record.provider.rawValue + ":" + record.id).inserted else { throw AIUsageError.invalid("Token 历史包含重复记录。") }
            guard record.timestamp <= updatedAt.addingTimeInterval(300) else { throw AIUsageError.invalid("Token 历史采集时间无效。") }
            let added = totalTokens.addingReportingOverflow(record.tokens.total)
            guard !added.overflow else { throw AIUsageError.invalid("Token 历史汇总超出支持范围。") }
            totalTokens = added.partialValue
            if let archivedBefore, record.timestamp < archivedBefore { throw AIUsageError.invalid("Token 明细与已汇总历史范围重叠。") }
        }
        guard archivedMonths.count <= Self.maximumSummaryMonths * AIProvider.allCases.count,
              Set(archivedMonths.map(\.id)).count == archivedMonths.count else { throw AIUsageError.invalid("Token 月度汇总范围无效。") }
        if let archivedBefore {
            guard archivedBefore.timeIntervalSince1970.isFinite, archivedBefore <= updatedAt else { throw AIUsageError.invalid("Token 汇总边界无效。") }
        } else if !archivedMonths.isEmpty { throw AIUsageError.invalid("Token 汇总缺少明细边界。") }
        for summary in archivedMonths {
            guard summary.month.timeIntervalSince1970.isFinite, summary.month.timeIntervalSince1970 > 0,
                  summary.month == (try? AITokenMonthSummary.month(containing: summary.month)), summary.month < (archivedBefore ?? .distantPast),
                  summary.recordCount > 0 else { throw AIUsageError.invalid("Token 月度汇总内容无效。") }
            _ = try AITokenMonthSummary.checkedAdd(.init(), summary.tokens)
            let added = totalTokens.addingReportingOverflow(summary.tokens.total)
            guard !added.overflow else { throw AIUsageError.invalid("Token 历史汇总超出支持范围。") }
            totalTokens = added.partialValue
        }
    }

    private static func validate(_ record: AITokenRecord) throws {
        func safe(_ value: String, maximumBytes: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximumBytes &&
            !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        }
        guard safe(record.id, maximumBytes: 512), safe(record.model, maximumBytes: 512),
              record.timestamp.timeIntervalSince1970.isFinite, record.timestamp.timeIntervalSince1970 > 0,
              record.timestamp.timeIntervalSince1970 <= 100_000_000_000 else {
            throw AIUsageError.invalid("Token 计量记录标识或时间无效。")
        }
        var sum: Int64 = 0
        for count in [record.tokens.input, record.tokens.output, record.tokens.cacheRead, record.tokens.cacheWrite] {
            let added = sum.addingReportingOverflow(count)
            guard count >= 0, !added.overflow else { throw AIUsageError.invalid("Token 计量值无效或超出支持范围。") }
            sum = added.partialValue
        }
    }
}

/// Current scan coverage stays distinct from retained history. A disconnected
/// provider may still have historical records, but cannot claim a current scan.
public struct AIUsageSourceCoverage: Equatable, Sendable {
    public var provider: AIProvider
    public var scannedAt: Date
    public var enabled: Bool
    public var sourceAvailable: Bool
    public var scannedFiles: Int
    public var skippedFiles: Int
    public var parsedRecords: Int
    public var firstRecordAt: Date?
    public var lastRecordAt: Date?
    public init(provider: AIProvider, scannedAt: Date, enabled: Bool, sourceAvailable: Bool, scannedFiles: Int, skippedFiles: Int, records: [AITokenRecord]) {
        self.provider = provider; self.scannedAt = scannedAt; self.enabled = enabled; self.sourceAvailable = sourceAvailable
        self.scannedFiles = max(0, scannedFiles); self.skippedFiles = max(0, skippedFiles)
        let scoped = records.filter { $0.provider == provider }
        parsedRecords = scoped.count; firstRecordAt = scoped.map(\.timestamp).min(); lastRecordAt = scoped.map(\.timestamp).max()
    }
}

public struct AITokenLedgerStore: Sendable {
    public static let maximumBytes = 67_108_864
    public let url: URL
    public var backupURL: URL { url.appendingPathExtension("previous") }
    public init(url: URL) { self.url = url }
    public func load(now: Date = Date()) throws -> AITokenLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init(now: now) }
        return try decode(read(url))
    }
    public func save(_ value: AITokenLedger) throws {
        try value.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumBytes else { throw AIUsageError.invalid("Token 历史文件过大，原文件已保留。") }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if manager.fileExists(atPath: url.path) {
            let previous = try read(url); _ = try decode(previous)
            try previous.write(to: backupURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func read(_ file: URL) throws -> Data {
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) <= Self.maximumBytes else {
            throw AIUsageError.invalid("Token 历史文件无法读取或过大，原文件已保留。")
        }
        return try Data(contentsOf: file)
    }
    private func decode(_ data: Data) throws -> AITokenLedger {
        let value = try JSONDecoder().decode(AITokenLedger.self, from: data)
        try value.validate(); return value
    }
}
