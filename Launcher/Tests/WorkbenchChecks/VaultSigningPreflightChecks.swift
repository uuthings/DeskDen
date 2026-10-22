import Foundation

@main @MainActor enum VaultSigningPreflightChecks {
    static func main() async throws {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let group = "A1B2C3D4E5.example.synthetic-vault"
        let valid = VaultBiometricSigningCapability.evaluate(bundleIdentifier: "example.synthetic-vault", applicationIdentifier: group,
            teamIdentifier: "A1B2C3D4E5", groups: [group], embeddedProfileExists: true, signatureValid: true)
        let missing = VaultBiometricSigningCapability.evaluate(bundleIdentifier: "example.synthetic-vault", applicationIdentifier: group,
            teamIdentifier: "A1B2C3D4E5", groups: [group], embeddedProfileExists: false, signatureValid: true)
        let isolatedURL = FileManager.default.temporaryDirectory.appendingPathComponent("uncreated-signing-fixture-" + UUID().uuidString)
            .appendingPathComponent("PRIVATE_VAULT_PATH_SENTINEL.json")
        var factories = 0
        let refused = VaultSigningProbeFixture(authorized: false, hardware: false, reason: "Authorization unavailable")
        let unsignedReport = await VaultSigningChecks.preflight(signing: missing, isolatedVaultURL: isolatedURL) { _, _ in factories += 1; return refused }
        check(unsignedReport.exitCode != 0 && unsignedReport.signingStatus == .unavailable && unsignedReport.hardwareStatus == .notChecked && factories == 0,
              "missing signed profile fails before constructing a biometric store or inspecting hardware")
        let refusedReport = await VaultSigningChecks.preflight(signing: valid, isolatedVaultURL: isolatedURL) { url, signing in
            factories += 1
            check(url == isolatedURL && signing == valid, "metadata preflight receives only the injected isolated URL and signing claims")
            return refused
        }
        check(refusedReport.exitCode != 0 && refusedReport.signingStatus == .unavailable && refusedReport.keychainAccessGroup == group && refusedReport.hardwareStatus == .notChecked,
              "signed claims alone cannot pass a rejected read-only access-group authorization check")
        let noHardware = VaultSigningProbeFixture(authorized: true, hardware: false, reason: "Touch ID unavailable")
        let noHardwareReport = await VaultSigningChecks.preflight(signing: valid, isolatedVaultURL: isolatedURL) { _, _ in factories += 1; return noHardware }
        check(noHardwareReport.exitCode == 0 && noHardwareReport.signingStatus == .authorized && noHardwareReport.hardwareStatus == .unavailable && noHardwareReport.hardwareReason == "Touch ID unavailable",
              "unavailable fingerprint hardware is reported separately without falsely rejecting valid signing authorization")
        let ready = VaultSigningProbeFixture(authorized: true, hardware: true, reason: nil)
        let readyReport = await VaultSigningChecks.preflight(signing: valid, isolatedVaultURL: isolatedURL) { _, _ in factories += 1; return ready }
        check(readyReport.exitCode == 0 && readyReport.signingStatus == .authorized && readyReport.hardwareStatus == .available && readyReport.reason == nil && readyReport.hardwareReason == nil,
              "successful metadata authorization and ready hardware produce a successful signing report")
        check(factories == 3 && [refused, noHardware, ready].allSatisfy { $0.refreshes == 1 && $0.forbiddenOperations == 0 },
              "each permitted diagnostic performs only one metadata preflight and never inspects, enrolls, reads, deletes or cancels a vault key")
        check(!FileManager.default.fileExists(atPath: isolatedURL.deletingLastPathComponent().path),
              "the diagnostic never creates the temporary vault directory or accesses a user vault")
        let encoder = JSONEncoder()
        for report in [unsignedReport, refusedReport, noHardwareReport, readyReport] {
            let data = try encoder.encode(report)
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let allowed: Set<String> = ["schema", "signingStatus", "reason", "keychainAccessGroup", "hardwareStatus", "hardwareReason"]
            check(Set(json.keys).isSubset(of: allowed) && !String(decoding: data, as: UTF8.self).contains("PRIVATE_VAULT_PATH_SENTINEL"),
                  "diagnostic JSON contains only public signing and hardware metadata")
        }
        print("Vault signing preflight checks: \(count - failures)/\(count) passed")
        exit(failures == 0 ? 0 : 1)
    }
}

@MainActor private final class VaultSigningProbeFixture: VaultBiometricStore {
    let canRemove: Bool
    let available: Bool
    let unavailableReason: String?
    var refreshes = 0
    var forbiddenOperations = 0
    init(authorized: Bool, hardware: Bool, reason: String?) { canRemove = authorized; available = authorized && hardware; unavailableReason = reason }
    func refreshAvailability() async -> String? { refreshes += 1; return unavailableReason }
    func containsKey() async -> Bool { forbiddenOperations += 1; return false }
    func enroll(key: Data, salt: Data) async throws { forbiddenOperations += 1 }
    func readKey(salt: Data) async throws -> Data { forbiddenOperations += 1; return Data() }
    func remove() async throws { forbiddenOperations += 1 }
    func removeSynchronously() throws { forbiddenOperations += 1 }
    func cancel() { forbiddenOperations += 1 }
}
