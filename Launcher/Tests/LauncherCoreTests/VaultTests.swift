import XCTest
import CryptoKit
@testable import LauncherCore

final class VaultTests:XCTestCase {
    private let password="test-only-private-password"
    private func directory() throws -> URL { let url=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-vault-tests-\(UUID().uuidString)"); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url }
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
    func testPasswordRotationReencryptsManagedHistoryAndPreservesOtherPasswords() throws {
        let directory=try directory();defer {try? FileManager.default.removeItem(at:directory)}
        let store=VaultFileStore(url:directory.appendingPathComponent("private.deskdenvault")),newPassword="new-test-private-password"
        let historicalContents=contents
        let first=try VaultCryptography.create(contents:historicalContents,password:password)
        try store.write(first.envelope)
        let currentContents=VaultContents(documents:[PrivateDocument(title:"Current synthetic",body:"Current synthetic body")])
        try store.write(VaultCryptography.seal(contents:currentContents,key:first.key,salt:first.envelope.salt))
        let retainedURL=directory.appendingPathComponent("vault-before-restore-\(UUID().uuidString).deskdenvault")
        let independentlySalted=try VaultCryptography.create(contents:historicalContents,password:password)
        try VaultCryptography.encoded(independentlySalted.envelope).write(to:retainedURL)
        let foreignURL=directory.appendingPathComponent("vault-before-restore-\(UUID().uuidString).deskdenvault")
        let foreign=try VaultCryptography.encoded(VaultCryptography.create(contents:contents,password:"different-history-password").envelope)
        try foreign.write(to:foreignURL)
        let exportedURL=directory.appendingPathComponent("user-export.deskdenvault"),exported=try store.read()
        try exported.write(to:exportedURL)

        let prepared=try store.preparePasswordChange(currentPassword:password,newPassword:newPassword)
        XCTAssertEqual(try store.read(),exported,"preparation cannot change the active password")
        XCTAssertFalse(store.isPendingPasswordChange)
        let journalText=String(decoding:try JSONEncoder().encode(prepared),as:UTF8.self)
        XCTAssertFalse(journalText.contains(password));XCTAssertFalse(journalText.contains(newPassword));XCTAssertFalse(journalText.contains("Current synthetic body"))
        let result=try store.commitPasswordChange(prepared)
        XCTAssertEqual(result.reencryptedBackupCount,2)
        XCTAssertEqual(result.retainedOtherPasswordBackups,[foreignURL.lastPathComponent])
        XCTAssertEqual(try VaultCryptography.unlock(data:store.read(),password:newPassword).contents,currentContents)
        for candidate in [store.url,store.url.appendingPathExtension("previous"),retainedURL] {
            let bytes=try Data(contentsOf:candidate)
            XCTAssertThrowsError(try VaultCryptography.unlock(data:bytes,password:password))
            let expected=candidate == store.url ? currentContents:historicalContents
            XCTAssertEqual(try VaultCryptography.unlock(data:bytes,password:newPassword).contents,expected)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:candidate.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        }
        XCTAssertEqual(try Data(contentsOf:foreignURL),foreign)
        XCTAssertEqual(try Data(contentsOf:exportedURL),exported)
        XCTAssertEqual(try VaultCryptography.unlock(data:Data(contentsOf:exportedURL),password:password).contents,currentContents)
        XCTAssertFalse(store.isPendingPasswordChange)
        XCTAssertNil(try store.recoverPasswordChange())
    }
    func testPasswordRotationRejectsChangedSourceBeforeCreatingJournal() throws {
        let directory=try directory();defer {try? FileManager.default.removeItem(at:directory)}
        let store=VaultFileStore(url:directory.appendingPathComponent("private.deskdenvault"))
        let created=try VaultCryptography.create(contents:contents,password:password)
        try store.write(created.envelope)
        let prepared=try store.preparePasswordChange(currentPassword:password,newPassword:"replacement-test-password")
        let external=try VaultCryptography.encoded(VaultCryptography.seal(contents:VaultContents(),key:created.key,salt:created.envelope.salt))
        try external.write(to:store.url)
        XCTAssertThrowsError(try store.commitPasswordChange(prepared)) {XCTAssertEqual($0 as? VaultFailure,.passwordChangeSourceChanged)}
        XCTAssertFalse(store.isPendingPasswordChange)
        XCTAssertEqual(try store.read(),external)
    }
    func testInterruptedPasswordRotationRequiresForwardRecoveryBeforeOrdinaryWrites() throws {
        let directory=try directory();defer {try? FileManager.default.removeItem(at:directory)}
        let store=VaultFileStore(url:directory.appendingPathComponent("private.deskdenvault")),newPassword="recovered-test-password"
        let created=try VaultCryptography.create(contents:contents,password:password)
        try store.write(created.envelope)
        try store.write(VaultCryptography.seal(contents:VaultContents(),key:created.key,salt:created.envelope.salt))
        let prepared=try store.preparePasswordChange(currentPassword:password,newPassword:newPassword)
        // Inject a process interruption after the journal and first history have
        // reached disk, while the main vault still uses its original password.
        let journal=try JSONEncoder().encode(prepared)
        try journal.write(to:store.url.appendingPathExtension("password-change"))
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:journal) as? [String:Any])
        let targets=try XCTUnwrap(object["targets"] as? [[String:Any]])
        let previous=try XCTUnwrap(targets.first{($0["name"] as? String) == "private.deskdenvault.previous"})
        let replacement=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(previous["replacement"] as? String)))
        try replacement.write(to:store.url.appendingPathExtension("previous"))
        XCTAssertTrue(store.isPendingPasswordChange)
        XCTAssertEqual(try VaultCryptography.unlock(data:Data(contentsOf:store.url),password:password).contents,VaultContents())
        XCTAssertThrowsError(try store.read()) {XCTAssertEqual($0 as? VaultFailure,.passwordChangePending)}
        XCTAssertThrowsError(try store.write(created.envelope)) {XCTAssertEqual($0 as? VaultFailure,.passwordChangePending)}
        XCTAssertThrowsError(try store.restore(created.envelope)) {XCTAssertEqual($0 as? VaultFailure,.passwordChangePending)}
        XCTAssertThrowsError(try store.preparePasswordChange(currentPassword:password,newPassword:newPassword)) {XCTAssertEqual($0 as? VaultFailure,.passwordChangePending)}
        let recovered=try XCTUnwrap(store.recoverPasswordChange())
        XCTAssertEqual(recovered.reencryptedBackupCount,1)
        XCTAssertFalse(store.isPendingPasswordChange)
        XCTAssertEqual(try VaultCryptography.unlock(data:store.read(),password:newPassword).contents,VaultContents())
        XCTAssertEqual(try VaultCryptography.unlock(data:Data(contentsOf:store.url.appendingPathExtension("previous")),password:newPassword).contents,created.contents)
        XCTAssertThrowsError(try VaultCryptography.unlock(data:store.read(),password:password))
    }
    func testInterruptedRotationDoesNotOverwriteExternallyChangedHistory() throws {
        let directory=try directory();defer {try? FileManager.default.removeItem(at:directory)}
        let store=VaultFileStore(url:directory.appendingPathComponent("private.deskdenvault"))
        let created=try VaultCryptography.create(contents:contents,password:password)
        try store.write(created.envelope);try store.write(created.envelope)
        let prepared=try store.preparePasswordChange(currentPassword:password,newPassword:"replacement-test-password")
        try JSONEncoder().encode(prepared).write(to:store.url.appendingPathExtension("password-change"))
        let external=try VaultCryptography.encoded(VaultCryptography.create(contents:VaultContents(),password:"unrelated-password").envelope)
        try external.write(to:store.url.appendingPathExtension("previous"))
        let primary=try Data(contentsOf:store.url)
        XCTAssertThrowsError(try store.recoverPasswordChange()) {XCTAssertEqual($0 as? VaultFailure,.passwordChangeSourceChanged)}
        XCTAssertEqual(try Data(contentsOf:store.url.appendingPathExtension("previous")),external)
        XCTAssertEqual(try Data(contentsOf:store.url),primary)
        XCTAssertTrue(store.isPendingPasswordChange)
    }
    func testPasswordRotationPreservesLegacyHistoryPayloadBytes() throws {
        let directory=try directory();defer {try? FileManager.default.removeItem(at:directory)}
        let store=VaultFileStore(url:directory.appendingPathComponent("private.deskdenvault")),newPassword="replacement-test-password"
        let created=try VaultCryptography.create(contents:contents,password:password)
        try store.write(created.envelope)
        var fields=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(contents)) as? [String:Any])
        fields["version"]=1;fields.removeValue(forKey:"categories")
        let legacyPlaintext=try JSONSerialization.data(withJSONObject:fields)
        let associated=Data("deskden-encrypted-vault:1:pbkdf2-sha256-310000".utf8)
        let legacyBox=try AES.GCM.seal(legacyPlaintext,using:created.key,authenticating:associated)
        let legacyEnvelope=VaultEnvelope(rounds:VaultCryptography.rounds,salt:created.envelope.salt,sealed:try XCTUnwrap(legacyBox.combined))
        let historyURL=directory.appendingPathComponent("vault-before-restore-\(UUID().uuidString).deskdenvault")
        try VaultCryptography.encoded(legacyEnvelope).write(to:historyURL)
        try store.commitPasswordChange(store.preparePasswordChange(currentPassword:password,newPassword:newPassword))
        let reopened=try VaultCryptography.unlock(data:Data(contentsOf:historyURL),password:newPassword)
        XCTAssertEqual(reopened.contents.version,1)
        let plaintext=try AES.GCM.open(AES.GCM.SealedBox(combined:reopened.envelope.sealed),using:reopened.key,authenticating:associated)
        XCTAssertEqual(plaintext,legacyPlaintext)
    }
    func testPasswordRotationRejectsSamePasswordAndMalformedHistoryWithoutChanges() throws {
        let directory=try directory();defer {try? FileManager.default.removeItem(at:directory)}
        let store=VaultFileStore(url:directory.appendingPathComponent("private.deskdenvault"))
        let created=try VaultCryptography.create(contents:contents,password:password)
        try store.write(created.envelope)
        let primary=try store.read()
        XCTAssertThrowsError(try store.preparePasswordChange(currentPassword:password,newPassword:password)) {XCTAssertEqual($0 as? VaultFailure,.unchangedPassword)}
        let malformed=Data("corrupt synthetic history".utf8)
        try malformed.write(to:store.url.appendingPathExtension("previous"))
        XCTAssertThrowsError(try store.preparePasswordChange(currentPassword:password,newPassword:"replacement-test-password"))
        XCTAssertEqual(try store.read(),primary)
        XCTAssertEqual(try Data(contentsOf:store.url.appendingPathExtension("previous")),malformed)
        XCTAssertFalse(store.isPendingPasswordChange)
    }
    func testRecoveryRemovesOnlyPreciselyNamedAbandonedCiphertextWrites() throws {
        let directory=try directory();defer {try? FileManager.default.removeItem(at:directory)}
        let store=VaultFileStore(url:directory.appendingPathComponent("private.deskdenvault"))
        let abandoned=directory.appendingPathComponent("private.deskdenvault.password-change-staging-"+UUID().uuidString)
        let unrelated=directory.appendingPathComponent("private.deskdenvault.password-change-staging-user-file")
        let encrypted=try VaultCryptography.encoded(VaultCryptography.create(contents:contents,password:password).envelope)
        try encrypted.write(to:abandoned);try encrypted.write(to:unrelated)
        XCTAssertNil(try store.recoverPasswordChange())
        XCTAssertFalse(FileManager.default.fileExists(atPath:abandoned.path))
        XCTAssertEqual(try Data(contentsOf:unrelated),encrypted)
    }
    func testAtomicStoreKeepsPreviousEncryptedRevisionAndPrivatePermissions() throws {
        let directory=try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=VaultFileStore(url:directory.appendingPathComponent("private.deskdenvault"))
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
        let store=VaultFileStore(url:directory.appendingPathComponent("private.deskdenvault")),broken=Data("corrupt encrypted file".utf8)
        try broken.write(to:store.url)
        let valid=try VaultCryptography.create(contents:contents,password:password)
        XCTAssertThrowsError(try store.write(valid.envelope))
        XCTAssertEqual(try Data(contentsOf:store.url),broken)
    }
    func testConfirmedRestorePreservesDisplacedEncryptedFile() throws {
        let directory=try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=VaultFileStore(url:directory.appendingPathComponent("private.deskdenvault"))
        let current=try VaultCryptography.create(contents:contents,password:password)
        try store.write(current.envelope)
        let restored=try VaultCryptography.create(contents:VaultContents(),password:"backup-password")
        let preserved=try XCTUnwrap(store.restore(restored.envelope))
        XCTAssertEqual(try VaultCryptography.unlock(data:Data(contentsOf:preserved),password:password).contents,current.contents)
        XCTAssertTrue(try VaultCryptography.unlock(data:store.read(),password:"backup-password").contents.documents.isEmpty)
    }
    func testInvalidRestoreDoesNotReplaceCurrentBytes() throws {
        let directory=try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=VaultFileStore(url:directory.appendingPathComponent("private.deskdenvault"))
        let current=try VaultCryptography.create(contents:contents,password:password)
        try store.write(current.envelope); let before=try store.read()
        let invalid=VaultEnvelope(rounds:1,salt:Data(),sealed:Data())
        XCTAssertThrowsError(try store.restore(invalid))
        XCTAssertEqual(try store.read(),before)
    }
    func testLegacyStyleRunsDecodeWithSafeNewDefaults() throws {
        let legacy=Data("{\"location\":0,\"length\":4,\"family\":\"serif\",\"size\":22,\"bold\":true,\"italic\":false,\"underline\":true}".utf8)
        let run=try JSONDecoder().decode(VaultTextStyleRun.self,from:legacy)
        XCTAssertFalse(run.strikethrough);XCTAssertEqual(run.textColor,.automatic);XCTAssertEqual(run.highlightColor,.none)
        XCTAssertEqual(run.size,22)
    }
    func testExpandedRichTextStylesSurviveAuthenticatedEncryption() throws {
        for family in VaultFontFamily.allCases {
            var document=PrivateDocument(body:"Font color 🔐")
            let run=VaultTextStyleRun(location:0,length:document.body.utf16.count,family:family,size:26,bold:true,italic:true,underline:true,
                                      strikethrough:true,textColor:.blue,highlightColor:.yellow)
            document.formatting=[run]
            let content=VaultContents(documents:[document])
            let encrypted=try VaultCryptography.create(contents:content,password:password)
            let result=try VaultCryptography.unlock(data:VaultCryptography.encoded(encrypted.envelope),password:password)
            XCTAssertEqual(result.contents.version,3)
            XCTAssertEqual(result.contents.documents.first?.formatting,[run])
        }
    }
    func testPayloadTwoReadsWithoutMigrationButSubsequentEncodingFencesOldWriters() throws {
        var document=PrivateDocument(body:"Legacy style")
        document.formatting=[VaultTextStyleRun(location:0,length:document.body.utf16.count,family:.serif,size:20)]
        var value=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(VaultContents(documents:[document]))) as? [String:Any])
        value["version"]=2
        var documents=value["documents"] as! [[String:Any]]
        var styles=documents[0]["formatting"] as! [[String:Any]]
        for key in ["strikethrough","textColor","highlightColor"] {styles[0].removeValue(forKey:key)}
        documents[0]["formatting"]=styles;value["documents"]=documents
        let legacyBytes=try JSONSerialization.data(withJSONObject:value)
        let decoded=try JSONDecoder().decode(VaultContents.self,from:legacyBytes)
        XCTAssertEqual(decoded.version,2)
        XCTAssertEqual(decoded.documents[0].formatting,document.formatting)
        let written=try JSONDecoder().decode(VaultContents.self,from:JSONEncoder().encode(decoded))
        XCTAssertEqual(written.version,3)
        XCTAssertEqual(decoded.version,2)
        XCTAssertEqual(try JSONSerialization.jsonObject(with:legacyBytes) as? NSDictionary,value as NSDictionary)
    }
    func testUnknownFontColorAndHighlightAreRejectedRatherThanDiscarded() throws {
        let run=VaultTextStyleRun(location:0,length:4)
        for key in ["family","textColor","highlightColor"] {
            var value=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(run)) as? [String:Any])
            value[key]="unsupported-future-style"
            XCTAssertThrowsError(try JSONDecoder().decode(VaultTextStyleRun.self,from:JSONSerialization.data(withJSONObject:value)))
        }
    }

}
