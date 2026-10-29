import XCTest
import CryptoKit
@testable import LauncherCore

final class LegacyIdentityMigrationTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-identity-test-" + UUID().uuidString)
        let old = root.appendingPathComponent("Fangcun/Launcher")
        let next = root.appendingPathComponent("DeskDen/Launcher")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try ConfigurationStore(url: old.appendingPathComponent("configuration.json")).save(LauncherConfiguration())
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, old, next)
    }
    private func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }
    private func releasedVault(contents: VaultContents, password: String) throws -> Data {
        let created = try VaultCryptography.create(contents: contents, password: password)
        let box = try AES.GCM.seal(JSONEncoder().encode(created.contents), using: created.key,
            authenticating: Data("fangcun-encrypted-vault:1:pbkdf2-sha256-310000".utf8))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(created.envelope)) as? [String: Any])
        fields["format"] = "fangcun-encrypted-vault"
        fields["sealed"] = try XCTUnwrap(box.combined).base64EncodedString()
        return try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
    }
    private func assertNoPartialDestination(_ root: URL, _ next: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.path), file: file, line: line)
        let parent = root.appendingPathComponent("DeskDen")
        if FileManager.default.fileExists(atPath: parent.path) {
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains(where: { $0.hasPrefix(".identity-migration-") }), file: file, line: line)
        }
    }

    func testCopiesReleasedDirectoryWithoutRewritingOriginalAndIsIdempotent() throws {
        let (root, old, next) = try fixture()
        let sourceConfiguration = try Data(contentsOf: old.appendingPathComponent("configuration.json"))
        let reminderBytes = Data("{\"syntheticReminder\":\"preserved\"}".utf8)
        try write(reminderBytes, to: old.appendingPathComponent("Workbench/Calendar/reminders.json"))
        let outcome = try LegacyIdentityMigration.migrate(applicationSupport: root)
        XCTAssertEqual(outcome, .migrated)
        XCTAssertTrue(LegacyIdentityMigration.hasMigrationMarker(in: next))
        XCTAssertEqual(try Data(contentsOf: next.appendingPathComponent("configuration.json")), sourceConfiguration)
        XCTAssertEqual(try Data(contentsOf: next.appendingPathComponent("Workbench/Calendar/reminders.json")), reminderBytes)
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("configuration.json")), sourceConfiguration)
        XCTAssertFalse(LegacyIdentityMigration.hasMigrationMarker(in: old))
        try Data("new value".utf8).write(to: next.appendingPathComponent("Workbench/Calendar/reminders.json"))
        XCTAssertEqual(try LegacyIdentityMigration.migrate(applicationSupport: root), .existingDestination)
        XCTAssertEqual(try Data(contentsOf: next.appendingPathComponent("Workbench/Calendar/reminders.json")), Data("new value".utf8))
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("Workbench/Calendar/reminders.json")), reminderBytes)
    }

    func testExistingEmptyDestinationIsNotMergedOrOverwritten() throws {
        let (root, _, next) = try fixture()
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        XCTAssertEqual(try LegacyIdentityMigration.migrate(applicationSupport: root), .existingDestination)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: next.path), [])
    }

    func testFreshInstallDoesNotCreateAnyNewDirectory() throws {
        let (root, old, next) = try fixture()
        try FileManager.default.removeItem(at: old.deletingLastPathComponent())
        XCTAssertEqual(try LegacyIdentityMigration.migrate(applicationSupport: root), .noLegacyData)
        try assertNoPartialDestination(root, next)
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.deletingLastPathComponent().path))
    }

    func testCorruptOrMissingConfigurationNeverCreatesAnEmptyProfile() throws {
        let (root, old, next) = try fixture()
        let configuration = old.appendingPathComponent("configuration.json")
        try Data("corrupt original".utf8).write(to: configuration)
        XCTAssertThrowsError(try LegacyIdentityMigration.migrate(applicationSupport: root))
        XCTAssertEqual(try Data(contentsOf: configuration), Data("corrupt original".utf8))
        try assertNoPartialDestination(root, next)
        try FileManager.default.removeItem(at: configuration)
        XCTAssertThrowsError(try LegacyIdentityMigration.migrate(applicationSupport: root))
        try assertNoPartialDestination(root, next)
    }

    func testRejectsFileAndDanglingSymlinksWithoutFollowingTheirTargets() throws {
        let (root, old, next) = try fixture()
        let outside = root.appendingPathComponent("outside-private-data")
        try Data("not application data".utf8).write(to: outside)
        let link = old.appendingPathComponent("external-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try LegacyIdentityMigration.migrate(applicationSupport: root))
        try assertNoPartialDestination(root, next)
        try FileManager.default.removeItem(at: outside)
        XCTAssertThrowsError(try LegacyIdentityMigration.migrate(applicationSupport: root))
        try assertNoPartialDestination(root, next)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.path)
    }

    func testRejectsDestinationAndSourceParentSymlinks() throws {
        let (root, old, next) = try fixture()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: next.deletingLastPathComponent(), withDestinationURL: outside)
        XCTAssertThrowsError(try LegacyIdentityMigration.migrate(applicationSupport: root))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: next.deletingLastPathComponent())
        try FileManager.default.moveItem(at: old.deletingLastPathComponent(), to: root.appendingPathComponent("saved-source"))
        try FileManager.default.createSymbolicLink(at: old.deletingLastPathComponent(), withDestinationURL: root.appendingPathComponent("saved-source"))
        XCTAssertThrowsError(try LegacyIdentityMigration.migrate(applicationSupport: root))
        try assertNoPartialDestination(root, next)
    }

    func testRenamesEncryptedVaultAndHistoryAndResetsOnlyCopiedBiometricChoice() throws {
        let (root, old, next) = try fixture()
        let source = old.appendingPathComponent("Workbench/Vault")
        let destination = next.appendingPathComponent("Workbench/Vault")
        let contents = VaultContents(documents: [PrivateDocument(title: "Migration fixture", body: "Synthetic encrypted content")])
        let password = "migration-fixture-password"
        let encrypted = try releasedVault(contents: contents, password: password)
        let backupName = "vault-before-restore-" + UUID().uuidString
        for name in ["private.fangcunvault", "private.fangcunvault.previous", backupName + ".fangcunvault"] {
            try write(encrypted, to: source.appendingPathComponent(name))
        }
        // Restore reads the old exported suffix directly, before any migration.
        XCTAssertEqual(try VaultCryptography.unlock(data:VaultFileStore(url:source.appendingPathComponent(backupName+".fangcunvault")).read(),password:password).contents.documents,contents.documents)
        let preferences = try JSONEncoder().encode(VaultProtectionPreferences(idleMinutes: 10, biometricEnabled: true))
        try write(preferences, to: source.appendingPathComponent("protection.json"))
        XCTAssertEqual(try LegacyIdentityMigration.migrate(applicationSupport: root), .migrated)
        for name in ["private.deskdenvault", "private.deskdenvault.previous", backupName + ".deskdenvault"] {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), encrypted)
        }
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("private.fangcunvault")), encrypted)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("protection.json")), preferences)
        let copied = try JSONDecoder().decode(VaultProtectionPreferences.self, from: Data(contentsOf: destination.appendingPathComponent("protection.json")))
        XCTAssertEqual(copied.idleMinutes, 10)
        XCTAssertFalse(copied.biometricEnabled)
        XCTAssertEqual(try VaultCryptography.unlock(data: VaultFileStore(url: destination.appendingPathComponent("private.deskdenvault")).read(), password: password).contents, contents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(LegacyIdentityMigration.vaultNoticeName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent(LegacyIdentityMigration.vaultNoticeName).path))
    }

    func testVaultCollisionAndPendingPasswordChangeLeaveSourceUntouched() throws {
        let (root, old, next) = try fixture()
        let vault = old.appendingPathComponent("Workbench/Vault")
        try write(Data("old ciphertext".utf8), to: vault.appendingPathComponent("private.fangcunvault"))
        try write(Data("new ciphertext".utf8), to: vault.appendingPathComponent("private.deskdenvault"))
        XCTAssertThrowsError(try LegacyIdentityMigration.migrate(applicationSupport: root))
        try assertNoPartialDestination(root, next)
        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent("private.fangcunvault")), Data("old ciphertext".utf8))
        try FileManager.default.removeItem(at: vault.appendingPathComponent("private.deskdenvault"))
        try write(Data("pending encrypted change".utf8), to: vault.appendingPathComponent("private.fangcunvault.password-change"))
        XCTAssertThrowsError(try LegacyIdentityMigration.migrate(applicationSupport: root))
        try assertNoPartialDestination(root, next)
        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent("private.fangcunvault.password-change")), Data("pending encrypted change".utf8))
    }

    func testReleasedVaultHeaderRemainsAuthenticatedAndUnknownFormatsAreRejected() throws {
        let password = "migration-fixture-password"
        let bytes = try releasedVault(contents: VaultContents(), password: password)
        XCTAssertEqual(try VaultCryptography.unlock(data: bytes, password: password).envelope.format, "fangcun-encrypted-vault")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        fields["format"] = "deskden-encrypted-vault"
        XCTAssertThrowsError(try VaultCryptography.unlock(data: JSONSerialization.data(withJSONObject: fields), password: password))
        fields["format"] = "unknown-encrypted-vault"
        XCTAssertThrowsError(try VaultCryptography.decodeEnvelope(JSONSerialization.data(withJSONObject: fields)))
    }

    func testPasswordChangeReencryptsMigratedReleasedHistoryWithNewFormat() throws {
        let (root, old, next) = try fixture()
        let password = "migration-fixture-password", replacement = "replacement-fixture-password"
        let contents = VaultContents(documents: [PrivateDocument(title: "Old history fixture")])
        let bytes = try releasedVault(contents: contents, password: password)
        for name in ["private.fangcunvault", "private.fangcunvault.previous"] {
            try write(bytes, to: old.appendingPathComponent("Workbench/Vault/" + name))
        }
        try LegacyIdentityMigration.migrate(applicationSupport: root)
        let store = VaultFileStore(url: next.appendingPathComponent("Workbench/Vault/private.deskdenvault"))
        let result = try store.commitPasswordChange(store.preparePasswordChange(currentPassword: password, newPassword: replacement))
        XCTAssertEqual(result.reencryptedBackupCount, 1)
        for file in [store.url, store.url.appendingPathExtension("previous")] {
            let data = try Data(contentsOf: file)
            let unlocked = try VaultCryptography.unlock(data: data, password: replacement)
            XCTAssertEqual(unlocked.envelope.format, "deskden-encrypted-vault")
            XCTAssertEqual(unlocked.contents.documents, contents.documents)
            XCTAssertThrowsError(try VaultCryptography.unlock(data: data, password: password))
        }
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("Workbench/Vault/private.fangcunvault")), bytes)
    }

    func testMigrationDoesNotEnableOrInventTouchID() throws {
        let (root, old, next) = try fixture()
        let source = old.appendingPathComponent("Workbench/Vault/protection.json")
        let original = try JSONEncoder().encode(VaultProtectionPreferences(idleMinutes: 5, biometricEnabled: false))
        try write(original, to: source)
        try LegacyIdentityMigration.migrate(applicationSupport: root)
        XCTAssertEqual(try Data(contentsOf: next.appendingPathComponent("Workbench/Vault/protection.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.appendingPathComponent("Workbench/Vault/" + LegacyIdentityMigration.vaultNoticeName).path))
    }

    func testOnlySafeDefaultsMigrateAndExistingFalseWins() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let values = LegacyIdentityMigration.preferencesToMigrate(legacy: [
            "SUEnableAutomaticChecks": true, "SUAutomaticallyUpdate": true, "SULastCheckTime": date,
            "SUFeedURL": "https://invalid.example/qa.xml", "SUSkippedVersion": "999", "unrelated": "private"],
            current: ["SUEnableAutomaticChecks": false])
        XCTAssertNil(values["SUEnableAutomaticChecks"])
        XCTAssertEqual(values["SULastCheckTime"] as? Date, date)
        XCTAssertNil(values["SUFeedURL"])
        XCTAssertNil(values["SUAutomaticallyUpdate"])
        XCTAssertNil(values["SUSkippedVersion"])
        XCTAssertNil(values["unrelated"])
        XCTAssertEqual(values[LegacyIdentityMigration.preferencesMigratedKey] as? Bool, true)
        XCTAssertTrue(LegacyIdentityMigration.preferencesToMigrate(legacy: ["SUEnableAutomaticChecks": true], current: [LegacyIdentityMigration.preferencesMigratedKey: true]).isEmpty)
    }

    func testInvalidPreferenceTypesAreNotCoercedIntoOptIn() {
        let result = LegacyIdentityMigration.preferencesToMigrate(legacy: ["SUEnableAutomaticChecks": 1, "SUAutomaticallyUpdate": "true", "SULastCheckTime": "yesterday"], current: [:])
        XCTAssertNil(result["SUEnableAutomaticChecks"])
        XCTAssertNil(result["SUAutomaticallyUpdate"])
        XCTAssertNil(result["SULastCheckTime"])
    }

    func testCredentialFallbackPreservesCurrentPriorityAndDoesNotMaskDenial() throws {
        var fallbackReads = 0
        let current = try LegacyIdentityMigration.readCredential(current: { "current-value" }, legacy: { fallbackReads += 1; throw CocoaError(.fileReadNoPermission) })
        XCTAssertEqual(current, "current-value")
        XCTAssertEqual(fallbackReads, 0)
        XCTAssertEqual(try LegacyIdentityMigration.readCredential(current: { nil }, legacy: { fallbackReads += 1; return "legacy-value" }), "legacy-value")
        XCTAssertEqual(fallbackReads, 1)
        XCTAssertThrowsError(try LegacyIdentityMigration.readCredential(current: { throw CocoaError(.fileReadNoPermission) }, legacy: { fallbackReads += 1; return "legacy-value" }))
        XCTAssertEqual(fallbackReads, 1)
    }
    func testDeletedLegacyCredentialCannotReappearAfterANewRead() throws {
        var current:String?,deleted=false,legacyReads=0
        func read()->String? {
            LegacyIdentityMigration.readCredential(current:{current},legacyDisabled:{deleted},legacy:{legacyReads += 1;return "legacy-secret"})
        }
        XCTAssertEqual(read(),"legacy-secret")
        LegacyIdentityMigration.deleteCredential(markLegacyDeleted:{deleted=true},deleteCurrent:{current=nil})
        XCTAssertNil(read())
        XCTAssertEqual(legacyReads,1)
        // A deliberate new save takes precedence; a second deletion still must
        // not revive the retained source credential.
        current="new-secret"
        XCTAssertEqual(read(),"new-secret")
        LegacyIdentityMigration.deleteCredential(markLegacyDeleted:{deleted=true},deleteCurrent:{current=nil})
        XCTAssertNil(read())
        XCTAssertEqual(legacyReads,1)
    }
    func testDeletingCurrentCredentialAlsoDisablesLegacyWithSameID() {
        var current:String?="current-secret",deleted=false,legacyReads=0
        LegacyIdentityMigration.deleteCredential(markLegacyDeleted:{deleted=true},deleteCurrent:{current=nil})
        let value=LegacyIdentityMigration.readCredential(current:{current},legacyDisabled:{deleted},legacy:{legacyReads += 1;return "old-secret"})
        XCTAssertNil(value);XCTAssertEqual(legacyReads,0)
    }
    func testCredentialDeletionMarkerFailureLeavesCurrentItemAndNeverFallsBackOnMarkerDenial() {
        var current:String?="current-secret",deleteCalls=0,legacyReads=0
        XCTAssertThrowsError(try LegacyIdentityMigration.deleteCredential(
            markLegacyDeleted:{throw CocoaError(.fileWriteNoPermission)},
            deleteCurrent:{deleteCalls += 1;current=nil}))
        XCTAssertEqual(current,"current-secret");XCTAssertEqual(deleteCalls,0)
        XCTAssertThrowsError(try LegacyIdentityMigration.readCredential(current:{nil},
            legacyDisabled:{throw CocoaError(.fileReadNoPermission)},legacy:{legacyReads += 1;return "old-secret"}))
        XCTAssertEqual(legacyReads,0)
    }
    func testCredentialReplacementCleanupDisablesOnlyTheRemovedID() {
        let oldID=UUID(),newID=UUID()
        var current=[newID:"new-secret"],deleted=Set<UUID>(),legacyReads=0
        LegacyIdentityMigration.deleteCredential(markLegacyDeleted:{deleted.insert(oldID)},deleteCurrent:{current.removeValue(forKey:oldID)})
        XCTAssertNil(LegacyIdentityMigration.readCredential(current:{current[oldID]},legacyDisabled:{deleted.contains(oldID)},legacy:{legacyReads += 1;return "old-secret"}))
        XCTAssertEqual(LegacyIdentityMigration.readCredential(current:{current[newID]},legacyDisabled:{deleted.contains(newID)},legacy:{legacyReads += 1;return "unused"}),"new-secret")
        XCTAssertEqual(legacyReads,0);XCTAssertFalse(deleted.contains(newID))
    }
}
