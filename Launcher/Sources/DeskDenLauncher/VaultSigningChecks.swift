import Foundation

struct VaultSigningCheckReport: Encodable, Equatable, Sendable {
    enum SigningStatus: String, Encodable, Sendable { case authorized, unavailable }
    enum HardwareStatus: String, Encodable, Sendable { case available, unavailable, notChecked }
    let schema = "deskden.vault-signing-check/1"
    let signingStatus: SigningStatus
    let reason: String?
    let keychainAccessGroup: String?
    let hardwareStatus: HardwareStatus
    let hardwareReason: String?
    var exitCode: Int32 { signingStatus == .authorized ? 0 : 1 }
}

/// This diagnostic never opens a VaultModel or user data. It checks the current
/// signed process and invokes only the store's no-interaction metadata preflight.
/// The unique temporary URL supplies an isolated in-memory account identity; no
/// file or directory is created, no secret is requested, and no key is enrolled.
@MainActor enum VaultSigningChecks {
    static func run() async -> Int32 {
        let signing = VaultBiometricSigningCapability.currentApp()
        let isolatedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskden-vault-signing-check-" + UUID().uuidString)
            .appendingPathComponent("uncreated-vault.json")
        let report = await preflight(signing: signing, isolatedVaultURL: isolatedURL) { url, capability in
            VaultKeychainBiometrics(vaultURL: url, signing: capability)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("Unable to encode vault signing diagnostic.\n".utf8))
            return 1
        }
        print(json)
        return report.exitCode
    }

    /// Injected only by isolated checks. The protocol's credential operations
    /// are intentionally never used by this read-only diagnostic.
    static func preflight(signing: VaultBiometricSigningCapability, isolatedVaultURL: URL,
                          makeStore: (URL, VaultBiometricSigningCapability) -> any VaultBiometricStore) async -> VaultSigningCheckReport {
        guard let group = signing.accessGroup else {
            return .init(signingStatus: .unavailable, reason: signing.unavailableReason ?? VaultBiometricSigningCapability.missingAuthorization,
                         keychainAccessGroup: nil, hardwareStatus: .notChecked, hardwareReason: nil)
        }
        let store = makeStore(isolatedVaultURL, signing)
        let failure = await store.refreshAvailability()
        // canRemove represents access-group authorization independently of
        // fingerprint hardware; available adds the hardware readiness check.
        guard store.canRemove else {
            return .init(signingStatus: .unavailable, reason: failure ?? VaultBiometricSigningCapability.missingAuthorization,
                         keychainAccessGroup: group, hardwareStatus: .notChecked, hardwareReason: nil)
        }
        let hardwareAvailable = store.available
        return .init(signingStatus: .authorized, reason: nil, keychainAccessGroup: group,
                     hardwareStatus: hardwareAvailable ? .available : .unavailable,
                     hardwareReason: hardwareAvailable ? nil : failure ?? store.unavailableReason)
    }
}
