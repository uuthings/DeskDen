import XCTest
import CryptoKit
@testable import LauncherCore

final class VaultTests:XCTestCase {
    private let password="test-only-private-password"
    private func directory() throws -> URL { let url=FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-vault-tests-\(UUID().uuidString)"); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url }
    private var contents:VaultContents { VaultContents(documents:[PrivateDocument(title:"Synthetic confidential title",body:"Synthetic private body 🔐 测试")]) }
    func testLegacyDocumentDefaultsToUnclassifiedAndKnownCategoriesRoundTrip() throws {
        let original=PrivateDocument(title:"Legacy synthetic title",body:"Legacy synthetic body")
        var fields=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as? [String:Any])
        fields.removeValue(forKey:"category")
        let legacy=try JSONDecoder().decode(PrivateDocument.self,from:JSONSerialization.data(withJSONObject:fields))
        XCTAssertEqual(legacy,original)
        XCTAssertEqual(legacy.category,.unclassified)
        let categorized=VaultContents(documents:[PrivateDocument(title:"Work synthetic",category:.work),PrivateDocument(title:"Personal synthetic",category:.personal)])
        let encrypted=try VaultCryptography.create(contents:categorized,password:password)
        XCTAssertEqual(try VaultCryptography.unlock(data:VaultCryptography.encoded(encrypted.envelope),password:password).contents,categorized)
    }
    func testUnknownCategoryIsRejectedRatherThanSilentlyReclassified() throws {
        let document=PrivateDocument(title:"Future synthetic category")
        var fields=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(document)) as? [String:Any])
        fields["category"]="future-category"
        XCTAssertThrowsError(try JSONDecoder().decode(PrivateDocument.self,from:JSONSerialization.data(withJSONObject:fields)))
    }
    func testProtectionPreferencesAcceptOnlyKnownSchemaAndIdleChoices() throws {
        for minutes in [1,5,10] {
            let value=VaultProtectionPreferences(idleMinutes:minutes)
            XCTAssertEqual(try JSONDecoder().decode(VaultProtectionPreferences.self,from:JSONEncoder().encode(value)).validated(),value)
        }
        for minutes in [-1,0,2,60] {XCTAssertThrowsError(try VaultProtectionPreferences(idleMinutes:minutes).validated())}
        var future=VaultProtectionPreferences();future.schema=3
        XCTAssertThrowsError(try future.validated())
    }
    func testCreateUnlockPreservesUnicodeAndDoesNotStorePlaintext() throws {
        let content=contents,created=try VaultCryptography.create(contents:content,password:password)
        let data=try VaultCryptography.encoded(created.envelope)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("Synthetic"))
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains(password))
        XCTAssertEqual(try VaultCryptography.unlock(data:data,password:password).contents,content)
    }
    func testWrongAndEmptyPasswordsFailWithoutCrashing() throws {
        let data=try VaultCryptography.encoded(VaultCryptography.create(contents:contents,password:password).envelope)
        XCTAssertThrowsError(try VaultCryptography.unlock(data:data,password:"wrong-password"))
        XCTAssertThrowsError(try VaultCryptography.unlock(data:data,password:""))
        XCTAssertThrowsError(try VaultCryptography.create(contents:contents,password:"short"))
        XCTAssertThrowsError(try VaultCryptography.create(contents:contents,password:String(repeating:"a",count:4097)))
    }
    func testEachVaultGetsNewSaltAndEverySaveGetsNewNonce() throws {
        let content=contents,a=try VaultCryptography.create(contents:content,password:password),b=try VaultCryptography.create(contents:content,password:password)
        XCTAssertNotEqual(a.envelope.salt,b.envelope.salt)
        let rewritten=try VaultCryptography.seal(contents:content,key:a.key,salt:a.envelope.salt)
        XCTAssertNotEqual(a.envelope.sealed,rewritten.sealed)
        XCTAssertNotEqual(a.envelope.sealed.prefix(12),rewritten.sealed.prefix(12))
    }
    func testCiphertextAndAuthenticationTagTamperingIsRejected() throws {
        let original=try VaultCryptography.create(contents:contents,password:password).envelope
        for position in [12,original.sealed.count-1] {
            var sealed=original.sealed; sealed[position] ^= 0x40
            let changed=VaultEnvelope(rounds:original.rounds,salt:original.salt,sealed:sealed)
            XCTAssertThrowsError(try VaultCryptography.unlock(data:VaultCryptography.encoded(changed),password:password))
        }
    }
    func testUnsupportedKDFAndSaltAreRejectedBeforeExpensiveWork() throws {
        let sealed=Data(repeating:0,count:32)
        XCTAssertThrowsError(try VaultCryptography.encoded(VaultEnvelope(rounds:1,salt:Data(repeating:0,count:16),sealed:sealed)))
        XCTAssertThrowsError(try VaultCryptography.encoded(VaultEnvelope(rounds:UInt32.max,salt:Data(repeating:0,count:16),sealed:sealed)))
        XCTAssertThrowsError(try VaultCryptography.encoded(VaultEnvelope(rounds:VaultCryptography.rounds,salt:Data(repeating:0,count:1),sealed:sealed)))
        XCTAssertThrowsError(try VaultCryptography.decodeEnvelope(Data("{\"format\":\"other\"}".utf8)))
    }
    func testDuplicateDocumentsAndOversizedTextCannotBeSealed() throws {
        let created=try VaultCryptography.create(contents:VaultContents(),password:password),document=PrivateDocument()
        XCTAssertThrowsError(try VaultCryptography.seal(contents:VaultContents(documents:[document,document]),key:created.key,salt:created.envelope.salt))
        XCTAssertThrowsError(try VaultContents(documents:[PrivateDocument(title:String(repeating:"a",count:101))]).validate())
        XCTAssertThrowsError(try VaultContents(documents:[PrivateDocument(body:String(repeating:"a",count:160001))]).validate())
    }
    func testPasswordChangeDoesNotRewriteOldExportedBackup() throws {
        let content=contents,old=try VaultCryptography.create(contents:content,password:password)
        let oldBackup=try VaultCryptography.encoded(old.envelope)
        let changed=try VaultCryptography.create(contents:old.contents,password:"new-test-password")
        let newData=try VaultCryptography.encoded(changed.envelope)
        XCTAssertEqual(try VaultCryptography.unlock(data:oldBackup,password:password).contents,content)
        XCTAssertThrowsError(try VaultCryptography.unlock(data:oldBackup,password:"new-test-password"))
        XCTAssertEqual(try VaultCryptography.unlock(data:newData,password:"new-test-password").contents,content)
        XCTAssertThrowsError(try VaultCryptography.unlock(data:newData,password:password))
    }
    func testAtomicStoreKeepsPreviousEncryptedRevisionAndPrivatePermissions() throws {
        let directory=try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=VaultFileStore(url:directory.appendingPathComponent("private.fangcunvault"))
        let first=try VaultCryptography.create(contents:contents,password:password)
        try store.write(first.envelope)
        let second=try VaultCryptography.seal(contents:VaultContents(),key:first.key,salt:first.envelope.salt)
        try store.write(second)
        XCTAssertTrue(try VaultCryptography.unlock(data:store.read(),password:password).contents.documents.isEmpty)
        XCTAssertEqual(try VaultCryptography.unlock(data:Data(contentsOf:store.url.appendingPathExtension("previous")),password:password).contents,first.contents)
        let attributes=try FileManager.default.attributesOfItem(atPath:store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testCorruptCurrentFileCannotBeSilentlyOverwrittenByAutosave() throws {
        let directory=try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=VaultFileStore(url:directory.appendingPathComponent("private.fangcunvault")),broken=Data("corrupt encrypted file".utf8)
        try broken.write(to:store.url)
        let valid=try VaultCryptography.create(contents:contents,password:password)
        XCTAssertThrowsError(try store.write(valid.envelope))
        XCTAssertEqual(try Data(contentsOf:store.url),broken)
    }
    func testConfirmedRestorePreservesDisplacedEncryptedFile() throws {
        let directory=try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=VaultFileStore(url:directory.appendingPathComponent("private.fangcunvault"))
        let current=try VaultCryptography.create(contents:contents,password:password)
        try store.write(current.envelope)
        let restored=try VaultCryptography.create(contents:VaultContents(),password:"backup-password")
        let preserved=try XCTUnwrap(store.restore(restored.envelope))
        XCTAssertEqual(try VaultCryptography.unlock(data:Data(contentsOf:preserved),password:password).contents,current.contents)
        XCTAssertTrue(try VaultCryptography.unlock(data:store.read(),password:"backup-password").contents.documents.isEmpty)
    }
    func testInvalidRestoreDoesNotReplaceCurrentBytes() throws {
        let directory=try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=VaultFileStore(url:directory.appendingPathComponent("private.fangcunvault"))
        let current=try VaultCryptography.create(contents:contents,password:password)
        try store.write(current.envelope); let before=try store.read()
        let invalid=VaultEnvelope(rounds:1,salt:Data(),sealed:Data())
        XCTAssertThrowsError(try store.restore(invalid))
        XCTAssertEqual(try store.read(),before)
    }
}
