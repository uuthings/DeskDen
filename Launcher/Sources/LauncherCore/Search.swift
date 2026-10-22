import Foundation

public struct SearchEntry: Sendable, Identifiable {
    public let target: LaunchTarget
    public let title: String
    public let key: String?
    public var id: String { target.id }
    private let names: [SearchName]
    public init(target: LaunchTarget, title: String? = nil, key: String? = nil, additionalAliases: [String] = []) {
        self.target = target; self.title = title ?? target.name; self.key = key
        let aliases = [target.name] + Self.aliases(for: target) + additionalAliases
        var seen = Set<String>()
        names = ([self.title] + aliases.prefix(64)).compactMap { value in
            let trimmed = String(value.prefix(256)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(Self.normalize(trimmed)).inserted else { return nil }
            return SearchName(trimmed)
        }
    }
    fileprivate static func aliases(for target: LaunchTarget) -> [String] {
        var aliases = target.keywords.components(separatedBy: .newlines).prefix(32).map { String($0.prefix(256)) }
        if target.kind.isFileSystem { aliases.append(URL(fileURLWithPath: target.location).deletingPathExtension().lastPathComponent) }
        // Names and explicit keywords are searchable; directory components,
        // executable paths and saved web addresses are not fuzzy aliases.
        return aliases.filter { !$0.contains("://") && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") }
    }
    public static func normalize(_ value: String) -> String { value.folding(options: [.caseInsensitive,.diacriticInsensitive,.widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased() }
    public func score(_ query: String) -> Int? {
        let q = Self.normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return 0 }
        let parts = q.split(whereSeparator: \.isWhitespace).map(String.init)
        let compact = q.filter { $0.isLetter || $0.isNumber }
        var best = names.enumerated().compactMap { index, name in name.score(q, compact: compact, primary: index == 0) }.max()
        if parts.count > 1 && parts.allSatisfy({ part in names.contains { $0.matchesPart(part) } }) { best = max(best ?? 0, 550) }
        return best
    }
}

private struct SearchName: Sendable {
    let normalized: String
    let compact: String
    let latin: String
    let words: [String]
    let initials: [String]
    let allowsFuzzy: Bool
    init(_ value: String) {
        normalized = SearchEntry.normalize(value)
        compact = normalized.filter { $0.isLetter || $0.isNumber }
        let transliterated = value.applyingTransform(.toLatin, reverse: false) ?? value
        let originalWords = Self.wordParts(transliterated)
        words = originalWords.map(SearchEntry.normalize)
        latin = words.joined()
        let firstLetters = words.compactMap(\.first).map(String.init).joined()
        // Preserve short uppercase abbreviations: VSCode becomes both VC and
        // VSC, while ActivityMonitor becomes AM. Chinese syllables stay intact.
        let withAcronyms = originalWords.map { word -> String in
            word.count <= 6 && word.count > 1 && word.contains(where: \.isLetter) && word.allSatisfy({ $0.isUppercase || $0.isNumber }) ? SearchEntry.normalize(word) : word.first.map { SearchEntry.normalize(String($0)) } ?? ""
        }.joined()
        initials = Array(Set([firstLetters, withAcronyms])).filter { !$0.isEmpty }
        allowsFuzzy = !value.contains("://") && !value.contains("/") && !value.contains("\\") && !value.contains("\0") && latin.count <= 128
    }
    func score(_ query: String, compact queryCompact: String, primary: Bool) -> Int? {
        if normalized == query { return primary ? 1000 : 980 }
        if !queryCompact.isEmpty, compact == queryCompact { return primary ? 970 : 950 }
        if normalized.hasPrefix(query) { return primary ? 900 : 880 }
        if latin == query { return primary ? 850 : 840 }
        if initials.contains(query) { return primary ? 830 : 820 }
        if latin.hasPrefix(query) { return primary ? 790 : 780 }
        if initials.contains(where: { $0.hasPrefix(query) }) { return primary ? 750 : 740 }
        if words.contains(where: { $0.hasPrefix(query) }) { return primary ? 730 : 720 }
        if query.count >= 2, normalized.contains(query) { return primary ? 650 : 630 }
        if query.count >= 2, latin.contains(query) { return primary ? 610 : 600 }
        guard allowsFuzzy, query.count >= 2, query.count <= 64, query.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
              let cost = Self.subsequenceCost(query, in: latin) else { return nil }
        return 400 - min(100, cost) - (primary ? 0 : 10)
    }
    func matchesPart(_ part: String) -> Bool { normalized.contains(part) || latin.contains(part) || initials.contains(where: { $0.hasPrefix(part) }) }
    private static func wordParts(_ value: String) -> [String] {
        let characters = Array(value)
        var result: [String] = [], current = ""
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { result.append(current); current = "" }; continue
            }
            if !current.isEmpty, index > 0 {
                let previous = characters[index - 1], next = index + 1 < characters.count ? characters[index + 1] : nil
                let camelBoundary = previous.isLowercase && character.isUppercase
                let acronymBoundary = previous.isUppercase && character.isUppercase && next?.isLowercase == true
                let numberBoundary = previous.isNumber != character.isNumber && (previous.isNumber || character.isNumber)
                if camelBoundary || acronymBoundary || numberBoundary { result.append(current); current = "" }
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
    private static func subsequenceCost(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query), haystack = Array(candidate)
        guard needle.count <= haystack.count else { return nil }
        var best: Int?
        for start in haystack.indices where haystack[start] == needle[0] {
            var matched = 1, end = start
            if needle.count > 1, start + 1 < haystack.count {
                for index in (start + 1)..<haystack.count where haystack[index] == needle[matched] {
                    matched += 1; end = index
                    if matched == needle.count { break }
                }
            }
            guard matched == needle.count else { continue }
            let skipped = end - start + 1 - needle.count
            // Two-letter shortcuts must be compact; longer queries can skip
            // a few vowels without matching arbitrarily distant letters.
            guard skipped <= (needle.count == 2 ? 2 : max(4, needle.count * 2)) else { continue }
            let cost = skipped * 4 + start * 2 + max(0, haystack.count - needle.count)
            best = min(best ?? cost, cost)
        }
        return best
    }
}

public enum SearchEngine {
    public static func entries(applications: [LaunchTarget], bindings: [String: KeyBinding], includeBindings: Bool) -> [SearchEntry] {
        var entries: [String: SearchEntry] = [:]
        var aliases: [String: [String]] = [:]
        for app in applications {
            aliases[app.id, default: []] += [app.name] + SearchEntry.aliases(for: app)
            entries[app.id] = SearchEntry(target: app, additionalAliases: aliases[app.id] ?? [])
        }
        if includeBindings {
            for key in KeyboardLayout.keys {
                guard let binding = bindings[key] else { continue }
                entries[binding.target.id] = SearchEntry(target: binding.target, title: binding.title, key: key, additionalAliases: aliases[binding.target.id] ?? [])
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
