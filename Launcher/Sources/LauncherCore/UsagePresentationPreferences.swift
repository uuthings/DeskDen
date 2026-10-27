import Darwin
import Foundation

/// Display choices are independent from service credentials and collection settings.
public enum UsageCardGroup: String, Codable, CaseIterable, Sendable {
    case ai, service
}

public enum UsageCardIcon: Codable, Equatable, Sendable {
    case automatic
    case symbol(String)
    case image(String)

    public static let presetSymbols = ["sparkles", "terminal", "server.rack", "globe", "network", "externaldrive", "cpu", "bolt", "cloud", "square.stack.3d.up"]

    public func validate() throws {
        switch self {
        case .automatic: break
        case .symbol(let name):
            guard Self.presetSymbols.contains(name) else { throw UsagePresentationError.invalid }
        case .image(let name):
            guard Self.isManagedImageName(name) else { throw UsagePresentationError.invalid }
        }
    }

    public static func isManagedImageName(_ name: String) -> Bool {
        guard name.hasSuffix(".png"), name.count == 40 else { return false }
        let identifier = String(name.dropLast(4))
        return UUID(uuidString: identifier)?.uuidString.lowercased() == identifier
    }
}

public struct UsageCardAppearance: Codable, Equatable, Sendable {
    public var displayName: String?
    public var icon: UsageCardIcon
    public var visible: Bool

    public init(displayName: String? = nil, icon: UsageCardIcon = .automatic, visible: Bool = true) {
        self.displayName = displayName; self.icon = icon; self.visible = visible
    }

    private enum CodingKeys: String, CodingKey { case displayName, icon, visible }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        icon = try values.decodeIfPresent(UsageCardIcon.self, forKey: .icon) ?? .automatic
        visible = try values.decodeIfPresent(Bool.self, forKey: .visible) ?? true
    }

    public func validate() throws {
        if let displayName {
            guard !displayName.isEmpty, displayName == displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                  displayName.count <= 80,
                  !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw UsagePresentationError.invalid }
        }
        try icon.validate()
    }
}

public enum UsagePresentationSourceID {
    public static func ai(_ provider: AIProvider) -> String { "ai." + provider.rawValue }
    public static func service(_ identifier: UUID) -> String { "service." + identifier.uuidString.lowercased() }
    public static func isValid(_ key: String) -> Bool {
        if AIProvider.allCases.contains(where: { ai($0) == key }) { return true }
        guard key.hasPrefix("service.") else { return false }
        let identifier = String(key.dropFirst(8))
        return UUID(uuidString: identifier).map { service($0) == key } ?? false
    }
}

public struct UsagePresentationPreferences: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var aiCollapsed = false
    public var serviceCollapsed = false
    public var cards: [String: UsageCardAppearance] = [:]
    public init() {}

    private enum CodingKeys: String, CodingKey { case schemaVersion, aiCollapsed, serviceCollapsed, cards }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        aiCollapsed = try values.decodeIfPresent(Bool.self, forKey: .aiCollapsed) ?? false
        serviceCollapsed = try values.decodeIfPresent(Bool.self, forKey: .serviceCollapsed) ?? false
        cards = try values.decodeIfPresent([String: UsageCardAppearance].self, forKey: .cards) ?? [:]
    }

    public func validate() throws {
        guard schemaVersion == 1, cards.count <= 128 else { throw UsagePresentationError.invalid }
        for (key, value) in cards {
            guard UsagePresentationSourceID.isValid(key) else { throw UsagePresentationError.invalid }
            try value.validate()
        }
    }
    public func isCollapsed(_ group: UsageCardGroup) -> Bool { group == .ai ? aiCollapsed : serviceCollapsed }
    public mutating func setCollapsed(_ value: Bool, group: UsageCardGroup) {
        if group == .ai { aiCollapsed = value } else { serviceCollapsed = value }
    }
}

public enum UsagePresentationError: Error, LocalizedError {
    case invalid, storage, image
    public var errorDescription: String? {
        switch self {
        case .invalid: "请检查卡片名称、图标和显示设置。"
        case .storage: "用量显示设置无法保存，原设置已保留。"
        case .image: "请选择不超过 2 MB 的 PNG、JPEG 或 WebP 静态图片。"
        }
    }
}

public struct UsagePresentationStore: Sendable {
    public static let maximumBytes = 131_072
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> UsagePresentationPreferences {
        guard let data = try readCurrentData() else { return .init() }
        let value = try JSONDecoder().decode(UsagePresentationPreferences.self, from: data)
        try value.validate(); return value
    }

    public func save(_ value: UsagePresentationPreferences) throws {
        try value.validate()
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try manager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else { throw UsagePresentationError.storage }
        if let existing = try readCurrentData() {
            let previousValue = try JSONDecoder().decode(UsagePresentationPreferences.self, from: existing)
            try previousValue.validate()
            let previous = url.appendingPathExtension("previous")
            if let attributes = try? manager.attributesOfItem(atPath: previous.path) {
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw UsagePresentationError.storage }
            }
            try writeAtomically(existing, to: previous)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumBytes else { throw UsagePresentationError.storage }
        try writeAtomically(data, to: url)
    }

    private func readCurrentData() throws -> Data? {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path),
           attributes[.type] as? FileAttributeType != .typeDirectory { throw UsagePresentationError.storage }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw UsagePresentationError.storage
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_size >= 0, attributes.st_size <= Self.maximumBytes else { throw UsagePresentationError.storage }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw UsagePresentationError.storage }
        return data
    }

    private func writeAtomically(_ data: Data, to target: URL) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".usage-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UsagePresentationError.storage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, target.path) == 0 else { throw UsagePresentationError.storage }
    }
}

/// These fixed destinations contain no key, token or browser-session material.
public enum ProviderUsageExternalLinks {
    public static func url(for source: ProviderUsageConfiguration) -> URL? {
        if source.kind == .bandwagon { return URL(string: "https://bandwagonhost.com/services") }
        guard (1...20).contains(source.resourceID.count), source.resourceID.first != "0",
              source.resourceID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        var components = URLComponents()
        components.scheme = "https"; components.host = "dashboard.iproyal.com"
        components.path = "/me/orders/" + source.resourceID
        components.queryItems = [.init(name: "tab", value: "data-usage")]
        return components.url
    }
    public static func title(for source: ProviderUsageConfiguration) -> String {
        source.kind == .iproyal ? "打开 IPRoyal 订单" : "打开搬瓦工服务"
    }
}
