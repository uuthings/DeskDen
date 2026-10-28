import Foundation

/// Website templates keep the destination fixed while escaping each supplied path/query value.
public struct WebURLTemplate: Sendable {
    public let source: String
    public let variables: [String]
    private enum Segment: Sendable { case literal(String), variable(String) }
    private let segments: [Segment]

    public init(_ source: String) throws {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8192, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LauncherError.invalidTarget("网页地址无效，请检查地址中的换行或特殊字符。")
        }
        guard let schemeEnd = trimmed.range(of: "://") else { throw Self.invalidURL }
        let authorityEnd = trimmed[schemeEnd.upperBound...].firstIndex(where: { "/?#".contains($0) }) ?? trimmed.endIndex
        guard !trimmed[..<authorityEnd].contains("{"), !trimmed[..<authorityEnd].contains("}") else {
            throw LauncherError.invalidTarget("网址变量只能用于路径、查询参数或片段，不能改变网站域名。")
        }
        var segments: [Segment] = [], variables: [String] = []
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex {
            guard let opening = trimmed[cursor...].firstIndex(of: "{") else {
                let literal = String(trimmed[cursor...])
                guard !literal.contains("}") else { throw Self.invalidVariable }
                segments.append(.literal(literal)); break
            }
            let literal = String(trimmed[cursor..<opening])
            guard !literal.contains("}") else { throw Self.invalidVariable }
            if !literal.isEmpty { segments.append(.literal(literal)) }
            guard let closing = trimmed[trimmed.index(after: opening)...].firstIndex(of: "}") else { throw Self.invalidVariable }
            let variable = String(trimmed[trimmed.index(after: opening)..<closing])
            guard !variable.isEmpty, variable.count <= 64, !variable.contains("{"), variable == variable.trimmingCharacters(in: .whitespacesAndNewlines) else { throw Self.invalidVariable }
            if !variables.contains(variable) { variables.append(variable) }
            guard variables.count <= 16 else { throw LauncherError.invalidTarget("每个网页最多使用 16 个变量。") }
            segments.append(.variable(variable)); cursor = trimmed.index(after: closing)
        }
        let preview = segments.map { segment in
            switch segment { case .literal(let text): text; case .variable: "deskden-value" }
        }.joined()
        _ = try Self.validateURL(preview)
        self.source = trimmed; self.variables = variables; self.segments = segments
    }

    public func resolvedURL(values: [String:String] = [:]) throws -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let result = try segments.map { segment -> String in
            switch segment {
            case .literal(let text): return text
            case .variable(let name):
                guard let value = values[name] else { throw LauncherError.invalidTarget("请填写网址变量「\(name)」。") }
                guard value.count <= 4096, let escaped = value.addingPercentEncoding(withAllowedCharacters: unreserved) else {
                    throw LauncherError.invalidTarget("网址变量「\(name)」的内容过长。")
                }
                return escaped
            }
        }.joined()
        guard result.utf8.count <= 131_072 else { throw LauncherError.invalidTarget("生成的网页地址过长，请缩短变量内容。") }
        return try Self.validateURL(result)
    }

    /// Only the origin is needed to retrieve a favicon; no template values or query are requested.
    public var originURL: URL {
        let preview = segments.map { segment in
            switch segment { case .literal(let text): text; case .variable: "deskden-value" }
        }.joined()
        var parts = URLComponents(url: URL(string: preview)!, resolvingAgainstBaseURL: false)!
        parts.path = "/"; parts.query = nil; parts.fragment = nil
        return parts.url!
    }

    private static var invalidURL: LauncherError { .invalidTarget("请填写完整的 http:// 或 https:// 网页地址。") }
    private static var invalidVariable: LauncherError { .invalidTarget("网址变量请使用成对的大括号，例如 {ID} 或 {名字}。") }
    private static func validateURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { throw invalidURL }
        return url
    }
}
