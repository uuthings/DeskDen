import Foundation

public enum AppSortMode: String, Codable, CaseIterable, Sendable {
    case custom, nameAscending, nameDescending, addedNewest, addedOldest, installedNewest, installedOldest, usedNewest, usedOldest
    public var title: String {
        switch self {
        case .custom: "自定义排序"
        case .nameAscending: "名称正序"
        case .nameDescending: "名称逆序"
        case .addedNewest: "最近添加"
        case .addedOldest: "最早添加"
        case .installedNewest: "最近安装"
        case .installedOldest: "最早安装"
        case .usedNewest: "最近使用"
        case .usedOldest: "最久未使用"
        }
    }
}

public struct ApplicationMetadata: Codable, Equatable, Sendable {
    public var addedAt: Date
    public var installedAt: Date?
    public var lastUsedAt: Date?
    public init(addedAt: Date = Date(), installedAt: Date? = nil, lastUsedAt: Date? = nil) {
        self.addedAt = addedAt; self.installedAt = installedAt; self.lastUsedAt = lastUsedAt
    }
}

public enum ApplicationSorter {
    public static func sorted(_ applications: [LaunchTarget], mode: AppSortMode, order: [String] = [], metadata: [String:ApplicationMetadata] = [:], starred: [String] = []) -> [LaunchTarget] {
        let stars = Set(starred)
        var ranks: [String:Int] = [:]
        for (index, id) in order.enumerated() where ranks[id] == nil { ranks[id] = index }
        func date(for target: LaunchTarget) -> Date? {
            switch mode {
            case .addedNewest, .addedOldest: metadata[target.id]?.addedAt
            case .installedNewest, .installedOldest: metadata[target.id]?.installedAt
            case .usedNewest, .usedOldest: metadata[target.id]?.lastUsedAt
            default: nil
            }
        }
        return applications.sorted { first, second in
            if stars.contains(first.id) != stars.contains(second.id) { return stars.contains(first.id) }
            if mode == .custom {
                let firstRank = ranks[first.id] ?? Int.max, secondRank = ranks[second.id] ?? Int.max
                if firstRank != secondRank { return firstRank < secondRank }
            } else if ![.nameAscending, .nameDescending].contains(mode) {
                let firstDate = date(for:first), secondDate = date(for:second)
                // Unknown installation/usage dates remain at the end in both directions.
                if firstDate == nil && secondDate != nil { return false }
                if firstDate != nil && secondDate == nil { return true }
                if let firstDate, let secondDate, firstDate != secondDate {
                    return [.addedNewest, .installedNewest, .usedNewest].contains(mode) ? firstDate > secondDate : firstDate < secondDate
                }
            }
            let comparison = first.name.localizedStandardCompare(second.name)
            if comparison != .orderedSame { return mode == .nameDescending ? comparison == .orderedDescending : comparison == .orderedAscending }
            return first.id < second.id
        }
    }
}
