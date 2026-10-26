import Foundation

public struct ProviderUsageDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var sources: [ProviderUsageConfiguration] = []
    public var states: [UUID: ProviderUsageSourceState] = [:]
    public init() {}
    public func validate(now: Date = Date()) throws {
        guard schemaVersion == 1, sources.count <= 100, Set(sources.map(\.id)).count == sources.count,
              Set(states.keys).isSubset(of: Set(sources.map(\.id))) else { throw ProviderUsageFailure.storage }
        for source in sources { try source.validate() }
        for (id, state) in states {
            try state.refresh.validate()
            if let snapshot = state.snapshot { guard snapshot.sourceID == id else { throw ProviderUsageFailure.storage }; try snapshot.validate(now: now) }
            guard state.message.map({ $0.count <= 240 }) ?? true else { throw ProviderUsageFailure.storage }
        }
    }
}

public struct ProviderUsageStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> ProviderUsageDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 2_097_153) ?? Data()
        guard bytes.count <= 2_097_152 else { throw ProviderUsageFailure.storage }
        let value = try JSONDecoder().decode(ProviderUsageDocument.self, from: bytes); try value.validate(); return value
    }
    public func save(_ value: ProviderUsageDocument) throws {
        try value.validate()
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { _ = try load() }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value)
        guard data.count <= 2_097_152 else { throw ProviderUsageFailure.storage }
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
