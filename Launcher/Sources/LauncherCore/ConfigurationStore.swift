import Foundation

/// Atomic local configuration. Invalid or newer data is never replaced by defaults.
public struct ConfigurationStore: Sendable {
    public let url: URL
    public var backupURL: URL { url.appendingPathExtension("previous") }
    public init(url: URL) { self.url = url }
    public func load() throws -> LauncherConfiguration? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(Data(contentsOf: url))
    }
    public func decode(_ data: Data) throws -> LauncherConfiguration {
        guard data.count <= 8_388_608 else { throw LauncherError.storage("配置文件过大，原文件已保留。") }
        let value = try JSONDecoder().decode(LauncherConfiguration.self, from: data)
        try value.validate()
        return value
    }
    public func save(_ configuration: LauncherConfiguration) throws {
        try configuration.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        let encoded = try encoder.encode(configuration)
        guard encoded.count <= 8_388_608 else { throw LauncherError.storage("配置文件过大，现有文件未被修改。") }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if manager.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            _ = try decode(previous) // Preserve corrupt/newer data; recovery is explicit.
            try previous.write(to: backupURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
        try encoded.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func recoverPrevious() throws -> LauncherConfiguration {
        let data = try Data(contentsOf: backupURL)
        let valid = try decode(data)
        if FileManager.default.fileExists(atPath: url.path) {
            let preserved = url.deletingPathExtension().appendingPathExtension("preserved-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: url, to: preserved)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return valid
    }
}
