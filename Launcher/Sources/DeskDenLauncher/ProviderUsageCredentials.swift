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
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    func read(id: UUID) throws -> String? {
        var request = query(id); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
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
    func remove(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ProviderUsageFailure.credentials }
    }
}
