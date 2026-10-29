import Darwin
import Foundation

/// Display choices are independent from service credentials and collection settings.
public enum UsageCardGroup: String, Codable, CaseIterable, Sendable {
    case ai, service
}

public enum UsageBrandIcon: String, Codable, CaseIterable, Sendable {
    case chatgpt, claude, deepseek
}

public enum UsageCardIcon: Codable, Equatable, Sendable {
    case automatic
    case brand(UsageBrandIcon)
    case symbol(String)
    case image(String)

    public static let presetSymbols = ["sparkles", "terminal", "server.rack", "globe", "network", "externaldrive", "cpu", "bolt", "cloud", "square.stack.3d.up"]

    public func validate() throws {
        switch self {
        case .automatic, .brand: break
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
    public var categoryID: String?
    public var addedAt: Date?

    public init(displayName: String? = nil, icon: UsageCardIcon = .automatic, visible: Bool = true, categoryID: String? = nil, addedAt: Date? = nil) {
        self.displayName = displayName; self.icon = icon; self.visible = visible
        self.categoryID = categoryID; self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey { case displayName, icon, visible, categoryID, addedAt }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        icon = try values.decodeIfPresent(UsageCardIcon.self, forKey: .icon) ?? .automatic
        visible = try values.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        categoryID = try values.decodeIfPresent(String.self, forKey: .categoryID)
        addedAt = try values.decodeIfPresent(Date.self, forKey: .addedAt)
    }

    public func validate() throws {
        if let displayName {
            guard !displayName.isEmpty, displayName == displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                  displayName.count <= 80,
                  !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw UsagePresentationError.invalid }
        }
        try icon.validate()
        if let addedAt { guard addedAt.timeIntervalSince1970.isFinite else { throw UsagePresentationError.invalid } }
    }
}

public enum UsagePresentationSourceID {
    public static func ai(_ provider: AIProvider) -> String { "ai." + provider.rawValue }
    public static func service(_ identifier: UUID) -> String { "service." + identifier.uuidString.lowercased() }
    public static func api(_ identifier: UUID) -> String { "api." + identifier.uuidString.lowercased() }
    public static func isValid(_ key: String) -> Bool {
        if AIProvider.allCases.contains(where: { ai($0) == key }) { return true }
        for prefix in ["service.", "api."] where key.hasPrefix(prefix) {
            let identifier = String(key.dropFirst(prefix.count))
            return UUID(uuidString: identifier).map { prefix + $0.uuidString.lowercased() == key } ?? false
        }
        return false
    }
}

public struct UsageCardCategory: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public init(id: String = UUID().uuidString.lowercased(), title: String) { self.id = id; self.title = title }
    public static let defaults: [Self] = [
        .init(id: "ai-subscription", title: "订阅"), .init(id: "api-balance", title: "API"),
        .init(id: "traffic-services", title: "流量服务"), .init(id: "uncategorized", title: "未分类")
    ]
    fileprivate static let legacyDefaults: [Self] = [
        .init(id: "ai-subscription", title: "AI 订阅"), .init(id: "static-isp", title: "静态 ISP"),
        .init(id: "vps-traffic", title: "VPS 流量"), .init(id: "api-balance", title: "API 余额"),
        .init(id: "uncategorized", title: "未分类")
    ]
    public func validate() throws {
        guard !id.isEmpty, id.count <= 80, id.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }),
              !title.isEmpty, title == title.trimmingCharacters(in: .whitespacesAndNewlines), title.count <= 24,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw UsagePresentationError.invalid }
    }
}
public enum UsageCardSort: String, Codable, CaseIterable, Sendable {
    case added, name, category
    public var title: String { switch self { case .added: "添加时间"; case .name: "名称"; case .category: "分类" } }
}

public struct UsagePresentationPreferences: Codable, Equatable, Sendable {
    public var schemaVersion = 3
    public var aiCollapsed = false
    public var serviceCollapsed = false
    public var cards: [String: UsageCardAppearance] = [:]
    public var categories: [UsageCardCategory] = UsageCardCategory.defaults
    public var sourceOrder: [String] = []
    public var sort: UsageCardSort = .added
    public var ascending = true
    public var filterCategoryID: String?
    public init() {}

    private enum CodingKeys: String, CodingKey { case schemaVersion, aiCollapsed, serviceCollapsed, cards, categories, sourceOrder, sort, ascending, filterCategoryID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        aiCollapsed = try values.decodeIfPresent(Bool.self, forKey: .aiCollapsed) ?? false
        serviceCollapsed = try values.decodeIfPresent(Bool.self, forKey: .serviceCollapsed) ?? false
        cards = try values.decodeIfPresent([String: UsageCardAppearance].self, forKey: .cards) ?? [:]
        categories = try values.decodeIfPresent([UsageCardCategory].self, forKey: .categories)
            ?? (schemaVersion <= 2 ? UsageCardCategory.legacyDefaults : UsageCardCategory.defaults)
        sourceOrder = try values.decodeIfPresent([String].self, forKey: .sourceOrder) ?? []
        sort = try values.decodeIfPresent(UsageCardSort.self, forKey: .sort) ?? .added
        ascending = try values.decodeIfPresent(Bool.self, forKey: .ascending) ?? true
        filterCategoryID = try values.decodeIfPresent(String.self, forKey: .filterCategoryID)
        if schemaVersion <= 2 { try validate(); migrateDefaultCategories() }
    }

    /// Preserve renamed and user-created categories. Only untouched stock entries
    /// participate in the old ISP/VPS-to-traffic consolidation.
    private mutating func migrateDefaultCategories() {
        for (id, oldTitle, newTitle) in [("ai-subscription", "AI 订阅", "订阅"), ("api-balance", "API 余额", "API")] {
            if let index = categories.firstIndex(where: { $0.id == id && $0.title == oldTitle }),
               !categories.contains(where: { $0.title == newTitle }) { categories[index].title = newTitle }
        }
        let oldTitles = ["static-isp": "静态 ISP", "vps-traffic": "VPS 流量"]
        let mergedIDs = Set(categories.filter { oldTitles[$0.id] == $0.title }.map(\.id))
        guard !mergedIDs.isEmpty, !categories.contains(where: { $0.id == "traffic-services" || $0.title == "流量服务" }) else { return }
        let insertion = categories.firstIndex(where: { mergedIDs.contains($0.id) }) ?? categories.count
        categories.removeAll { mergedIDs.contains($0.id) }
        categories.insert(.init(id: "traffic-services", title: "流量服务"), at: min(insertion, categories.count))
        for (key, var card) in cards {
            if let category = card.categoryID, mergedIDs.contains(category) {
                card.categoryID = "traffic-services"; cards[key] = card
            }
        }
        if filterCategoryID.map(mergedIDs.contains) == true { filterCategoryID = "traffic-services" }
    }

    public func resolvedCategoryID(_ id: String) -> String {
        if categories.contains(where: { $0.id == id }) { return id }
        if ["static-isp", "vps-traffic"].contains(id), categories.contains(where: { $0.id == "traffic-services" }) { return "traffic-services" }
        return "uncategorized"
    }

    public func validate() throws {
        guard (1...3).contains(schemaVersion), cards.count <= 128, (1...40).contains(categories.count),
              Set(categories.map(\.id)).count == categories.count, Set(categories.map(\.title)).count == categories.count,
              categories.contains(where: { $0.id == "uncategorized" }), sourceOrder.count <= 128,
              Set(sourceOrder).count == sourceOrder.count, sourceOrder.allSatisfy(UsagePresentationSourceID.isValid),
              filterCategoryID == nil || categories.contains(where: { $0.id == filterCategoryID }) else { throw UsagePresentationError.invalid }
        try categories.forEach { try $0.validate() }
        for (key, value) in cards {
            guard UsagePresentationSourceID.isValid(key) else { throw UsagePresentationError.invalid }
            try value.validate()
            guard value.categoryID == nil || categories.contains(where: { $0.id == value.categoryID }) else { throw UsagePresentationError.invalid }
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
        case .invalid: "请检查卡片和分类名称；分类不可重复或留空。"
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
