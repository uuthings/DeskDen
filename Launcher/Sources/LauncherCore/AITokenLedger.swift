import Foundation

/// A bounded archive of usage fields only. AITokenRecord has no prompt, response,
/// file path, account credential, or conversation-content property to persist.
public struct AITokenLedger: Codable, Equatable, Sendable {
    public static let retentionDays = 31
    public static let maximumRecords = 20_000
    public var schemaVersion = 1
    public private(set) var createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var records: [AITokenRecord] = []
    public private(set) var capacityLimited = false
    public init(now: Date = Date()) { createdAt = now; updatedAt = now }

    /// Disconnection is intentionally absent from ingestion. The caller may
    /// stop reading a provider while retaining its already-observed records.
    public mutating func ingest(_ incoming: [AITokenRecord], at now: Date, maximumRecords: Int = Self.maximumRecords) throws {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0, (1...Self.maximumRecords).contains(maximumRecords) else {
            throw AIUsageError.invalid("Token 历史的保留范围无效。")
        }
        for record in incoming { try Self.validate(record) }
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let retained = (records + incoming).filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(300) }
        let merged = AIUsageAggregation.deduplicate(retained)
        // Combining maximum values from duplicate records must itself remain
        // representable, even when each independent source record was valid.
        for record in merged { try Self.validate(record) }
        var next = self
        next.records = Array(merged.suffix(maximumRecords))
        next.capacityLimited = capacityLimited || merged.count > maximumRecords
        next.updatedAt = now
        try next.validate()
        self = next
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
        guard schemaVersion == 1 else { throw AIUsageError.invalid("Token 历史格式来自更新版本，原文件已保留。") }
        guard createdAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince1970 > 0,
              updatedAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970 > 0,
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
        }
    }

    private static func validate(_ record: AITokenRecord) throws {
        func safe(_ value: String, maximumBytes: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximumBytes &&
            !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        }
        guard safe(record.id, maximumBytes: 512), safe(record.model, maximumBytes: 512),
              record.timestamp.timeIntervalSince1970.isFinite, record.timestamp.timeIntervalSince1970 > 0 else {
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
