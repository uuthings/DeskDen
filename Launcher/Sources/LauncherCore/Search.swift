import Foundation

public struct SearchEntry: Sendable, Identifiable {
    public let target: LaunchTarget
    public let title: String
    public let key: String?
    public var id: String { target.id }
    private let name: String
    private let latin: String
    private let initials: String
    private let extras: String
    public init(target: LaunchTarget, title: String? = nil, key: String? = nil) {
        self.target = target; self.title = title ?? target.name; self.key = key
        name = Self.normalize(self.title)
        let transliterated = self.title.applyingTransform(.toLatin, reverse: false) ?? self.title
        let words = Self.normalize(transliterated).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        latin = words.joined()
        initials = words.compactMap(\.first).map(String.init).joined()
        extras = Self.normalize(target.name + " " + target.keywords + " " + URL(fileURLWithPath: target.location).deletingPathExtension().lastPathComponent)
    }
    public static func normalize(_ value: String) -> String { value.folding(options: [.caseInsensitive,.diacriticInsensitive,.widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased() }
    public func score(_ query: String) -> Int? {
        let q = Self.normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return 0 }
        if name == q { return 1000 }
        if name.hasPrefix(q) { return 900 }
        if latin == q { return 850 }
        if initials == q { return 800 }
        if latin.hasPrefix(q) { return 750 }
        if initials.hasPrefix(q) { return 700 }
        if name.contains(q) { return 650 }
        if extras.contains(q) { return 500 }
        let parts = q.split(separator: " ")
        if parts.count > 1 && parts.allSatisfy({ name.contains($0) || extras.contains($0) || latin.contains($0) }) { return 450 }
        return nil
    }
}

public enum SearchEngine {
    public static func entries(applications: [LaunchTarget], bindings: [String: KeyBinding], includeBindings: Bool) -> [SearchEntry] {
        var entries: [String: SearchEntry] = [:]
        for app in applications { entries[app.id] = SearchEntry(target: app) }
        if includeBindings {
            for key in KeyboardLayout.keys {
                guard let binding = bindings[key] else { continue }
                entries[binding.target.id] = SearchEntry(target: binding.target, title: binding.title, key: key)
            }
        }
        return entries.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public static func search(_ entries: [SearchEntry], query: String, preservingInputOrder: Bool = false) -> [SearchEntry] {
        entries.enumerated().compactMap { index, entry in entry.score(query).map { (entry, $0, index) } }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if preservingInputOrder { return $0.2 < $1.2 }
            return $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending
        }.map(\.0)
    }
}

public struct SearchSelection: Sendable {
    public var page = 0
    public var selected = 0
    public init() {}
    public mutating func reset() { page = 0; selected = 0 }
    public mutating func clamp(total: Int, pageSize: Int) {
        page = min(max(0,page), max(0,(total-1)/pageSize))
        selected = min(max(0,selected), max(0,min(pageSize,total-page*pageSize)-1))
    }
    public func pageCount(total: Int, pageSize: Int) -> Int { max(1,(total+pageSize-1)/pageSize) }
    public func range(total: Int, pageSize: Int) -> Range<Int> { let start = min(total,max(0,page)*pageSize); return start..<min(total,start+pageSize) }
    public mutating func move(_ delta: Int, visibleCount: Int) { selected = min(max(0,selected+delta),max(0,visibleCount-1)) }
    /// Horizontal navigation preserves the visual row across page boundaries.
    /// A missing row on the adjacent page is a hard edge, not a jump to a
    /// different row. The last page never wraps back to the first page.
    public mutating func moveHorizontally(_ direction:Int,total:Int,pageSize:Int,columns:Int) {
        guard columns > 0, pageSize > 0, total > 0 else { reset(); return }
        clamp(total:total,pageSize:pageSize)
        guard direction != 0 else { return }
        let rowStart = (selected/columns)*columns
        let visibleCount = range(total:total,pageSize:pageSize).count
        if direction > 0 {
            if selected+1 < min(rowStart+columns,visibleCount) { selected += 1; return }
            let nextPage = page+1
            guard nextPage < pageCount(total:total,pageSize:pageSize), nextPage*pageSize+rowStart < total else { return }
            page = nextPage; selected = rowStart
        } else {
            if selected > rowStart { selected -= 1; return }
            guard page > 0 else { return }
            let previousPage = page-1
            let previousCount = min(pageSize,total-previousPage*pageSize)
            guard rowStart < previousCount else { return }
            page = previousPage; selected = min(rowStart+columns,previousCount)-1
        }
    }
}
