import Foundation
import Security
import LauncherCore

protocol ProviderUsageCredentialStoring: Sendable {
    func read(id: UUID) async throws -> String?
    func write(_ secret: String, id: UUID) async throws
    func remove(id: UUID) async throws
}

/// Dedicated API credentials; unrelated to the vault's biometric encryption key.
actor ProviderUsageKeychain: ProviderUsageCredentialStoring {
    private let service = "local.deskden.launcher.provider-usage.v1"
    private func query(_ id: UUID, service: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service ?? self.service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    func read(id: UUID) throws -> String? {
        try LegacyIdentityMigration.readCredential(current:{try read(id:id,service:service)},
            legacyDisabled:{try legacyIsDeleted(id:id)}, legacy:{try read(id:id,service:"local.fangcun.launcher.provider-usage.v1")})
    }
    private func read(id: UUID, service: String) throws -> String? {
        var request = query(id,service:service); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8), !secret.isEmpty else { throw ProviderUsageFailure.credentials }
        return secret
    }
    func write(_ secret: String, id: UUID) throws {
        guard !secret.isEmpty, secret.utf8.count <= 4096 else { throw ProviderUsageFailure.credentials }
        var request = query(id)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        request[kSecAttrLabel as String] = "方寸服务用量查询"
        request[kSecValueData as String] = Data(secret.utf8)
        // Callers use a new ID for every replacement, preserving the old secret until metadata commits.
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw ProviderUsageFailure.credentials }
    }
    private func legacyIsDeleted(id: UUID) throws -> Bool {
        var request = query(id,service:service + ".legacy-deleted")
        request[kSecReturnAttributes as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary,nil)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ProviderUsageFailure.credentials }
        return status == errSecSuccess
    }
    func remove(id: UUID) throws {
        try LegacyIdentityMigration.deleteCredential(markLegacyDeleted:{
            // This non-secret marker belongs to the new identity. Keep the old
            // credential untouched while preventing fallback after deletion.
            var marker = query(id,service:service + ".legacy-deleted")
            marker[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            marker[kSecValueData as String] = Data([1])
            let status = SecItemAdd(marker as CFDictionary,nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else { throw ProviderUsageFailure.credentials }
        },deleteCurrent:{
            let status = SecItemDelete(query(id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ProviderUsageFailure.credentials }
        })
    }
}
