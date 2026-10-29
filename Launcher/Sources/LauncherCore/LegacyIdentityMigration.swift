import CryptoKit
import Darwin
import Foundation

/// Copies the released 0.3 data into the renamed application's directory once.
/// The original is never written, and an existing destination always wins.
public enum LegacyIdentityMigration {
    public enum Outcome: Equatable, Sendable { case noLegacyData, existingDestination, migrated }
    public static let markerName = "legacy-identity-migration.json"
    public static let vaultNoticeName = "identity-migration-touch-id.json"
    public static let legacyDefaultsDomain = "local.fangcun.launcher"
    public static let preferencesMigratedKey = "DeskDen.legacyPreferencesMigrated"

    public enum Failure: LocalizedError {
        case unsafeLocation, changedSource, invalidConfiguration, conflictingVault, pendingPasswordChange
        public var errorDescription: String? {
            switch self {
            case .unsafeLocation: "旧版资料目录包含链接或不支持的文件，未进行迁移。"
            case .changedSource: "旧版资料在迁移过程中发生变化，请退出旧版后重试。"
            case .invalidConfiguration: "旧版配置无法读取，未创建新的空白资料。"
            case .conflictingVault: "旧版资料库中存在同名的新旧文件，未覆盖任何资料。"
            case .pendingPasswordChange: "旧版私密空间的密码更改尚未完成，请先在旧版完成后重试。"
            }
        }
    }

    @discardableResult public static func migrate(applicationSupport: URL) throws -> Outcome {
        let manager = FileManager.default
        let root = applicationSupport.standardizedFileURL.resolvingSymlinksInPath()
        let sourceParent = root.appendingPathComponent("Fangcun", isDirectory: true)
        let source = sourceParent.appendingPathComponent("Launcher", isDirectory: true)
        let parent = root.appendingPathComponent("DeskDen", isDirectory: true)
        let destination = parent.appendingPathComponent("Launcher", isDirectory: true)
        try requireDirectory(root)
        if try attributes(parent) != nil { try requireDirectory(parent) }
        if try attributes(destination) != nil {
            try requireDirectory(destination)
            return .existingDestination
        }
        guard try attributes(sourceParent) != nil else { return .noLegacyData }
        try requireDirectory(sourceParent)
        guard try attributes(source) != nil else { return .noLegacyData }
        try requireDirectory(source)

        let before = try manifest(source)
        guard before["configuration.json"]?.digest != nil else { throw Failure.invalidConfiguration }
        if try attributes(parent) == nil {
            try manager.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let staging = parent.appendingPathComponent(".identity-migration-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        guard try manifest(staging) == before, try manifest(source) == before else { throw Failure.changedSource }
        do {
            guard try ConfigurationStore(url: staging.appendingPathComponent("configuration.json")).load() != nil else {
                throw Failure.invalidConfiguration
            }
        } catch { throw Failure.invalidConfiguration }
        try migrateVault(in: staging)
        try Data("{\"schema\":1}\n".utf8).write(to: staging.appendingPathComponent(markerName), options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        // renamex_np with RENAME_EXCL is atomic and never replaces a destination
        // created by another process after the checks above.
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return .migrated
    }

    public static func hasMigrationMarker(in directory: URL) -> Bool {
        let marker = directory.appendingPathComponent(markerName)
        guard let metadata = try? attributes(marker), metadata[.type] as? FileAttributeType == .typeRegular,
              (metadata[.size] as? NSNumber)?.intValue == 13,
              let data = try? Data(contentsOf: marker) else { return false }
        return data == Data("{\"schema\":1}\n".utf8)
    }

    /// Do not migrate test feeds, cached update decisions, or system permissions.
    /// Existing values, including false, take precedence over the old domain.
    public static func preferencesToMigrate(legacy: [String: Any], current: [String: Any]) -> [String: Any] {
        guard current[preferencesMigratedKey] == nil else { return [:] }
        var result: [String: Any] = [:]
        for key in ["SUEnableAutomaticChecks"] where current[key] == nil {
            if let value = legacy[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { result[key] = value }
        }
        if current["SULastCheckTime"] == nil, let value = legacy["SULastCheckTime"] as? Date { result["SULastCheckTime"] = value }
        result[preferencesMigratedKey] = true
        return result
    }

    /// Missing credentials can fall back; denial or corruption must not silently
    /// bypass the current item's error. Reads never delete or rewrite old items.
    public static func readCredential(current: () throws -> String?, legacyDisabled: () throws -> Bool = { false },
                                      legacy: () throws -> String?) rethrows -> String? {
        if let value = try current() { return value }
        guard try !legacyDisabled() else { return nil }
        return try legacy()
    }

    /// A persistent deletion marker must succeed before deleting the new item.
    /// Otherwise a later read could revive the retained legacy credential.
    public static func deleteCredential(markLegacyDeleted: () throws -> Void, deleteCurrent: () throws -> Void) rethrows {
        try markLegacyDeleted()
        try deleteCurrent()
    }

    private static func migrateVault(in directory: URL) throws {
        let manager = FileManager.default
        let vault = directory.appendingPathComponent("Workbench/Vault", isDirectory: true)
        guard try attributes(vault) != nil else { return }
        try requireDirectory(vault)
        let oldName = "private.fangcunvault", newName = "private.deskdenvault"
        let names = try manager.contentsOfDirectory(atPath: vault.path)
        guard !names.contains(oldName + ".password-change") else { throw Failure.pendingPasswordChange }
        for name in names {
            let replacement: String?
            if name == oldName || name == oldName + ".previous" {
                replacement = newName + name.dropFirst(oldName.count)
            } else if name.hasPrefix("vault-before-restore-"), name.hasSuffix(".fangcunvault"),
                      UUID(uuidString: String(name.dropFirst("vault-before-restore-".count).dropLast(".fangcunvault".count))) != nil {
                replacement = String(name.dropLast(".fangcunvault".count)) + ".deskdenvault"
            } else { replacement = nil }
            guard let replacement else { continue }
            guard try attributes(vault.appendingPathComponent(replacement)) == nil else { throw Failure.conflictingVault }
            try manager.moveItem(at: vault.appendingPathComponent(name), to: vault.appendingPathComponent(replacement))
        }
        let protection = vault.appendingPathComponent("protection.json")
        guard let metadata = try attributes(protection) else { return }
        guard (metadata[.size] as? NSNumber)?.intValue ?? Int.max <= 16_384 else { throw Failure.unsafeLocation }
        var settings = try JSONDecoder().decode(VaultProtectionPreferences.self, from: Data(contentsOf: protection)).validated()
        if settings.biometricEnabled {
            settings.biometricEnabled = false
            try JSONEncoder().encode(settings).write(to: protection, options: .atomic)
            try Data("{\"schema\":1}\n".utf8).write(to: vault.appendingPathComponent(vaultNoticeName), options: .atomic)
        }
    }

    private struct Entry: Equatable {
        let permissions: Int
        let digest: Data?
    }
    private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    private static func requireDirectory(_ url: URL) throws {
        guard let value = try attributes(url), value[.type] as? FileAttributeType == .typeDirectory else { throw Failure.unsafeLocation }
    }
    private static func manifest(_ root: URL) throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        func visit(_ url: URL, relative: String) throws {
            guard result.count < 100_000, let value = try attributes(url),
                  let type = value[.type] as? FileAttributeType,
                  let permissions = (value[.posixPermissions] as? NSNumber)?.intValue else { throw Failure.unsafeLocation }
            if type == .typeDirectory {
                result[relative] = Entry(permissions: permissions, digest: nil)
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent)
                }
            } else if type == .typeRegular {
                let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { throw Failure.unsafeLocation }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var hasher = SHA256()
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
                result[relative] = Entry(permissions: permissions, digest: Data(hasher.finalize()))
            } else { throw Failure.unsafeLocation }
        }
        try visit(root, relative: "")
        return result
    }
}
