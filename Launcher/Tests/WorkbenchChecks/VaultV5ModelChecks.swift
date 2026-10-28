import AppKit
import CryptoKit
import Foundation
import LauncherCore

/// V5-only checks use synthetic passwords and isolated temporary data. They do
/// not show windows, open file panels, request permissions, or touch user files.
@main struct VaultV5ModelChecks {
    @MainActor static func main() async {
        _=NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-vault-v5-checks-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:directory)}
        var checks=0,failures=0
        func check(_ condition:Bool,_ message:String){checks += 1;if !condition {failures += 1};print("\(condition ? "PASS":"FAIL") \(message)")}
        do {
            let password="v5-only-synthetic-password"
            let model=VaultModel(dataDirectory:directory.appendingPathComponent("current"),protectedDataAvailable:{true})
            model.requestPasswordChange()
            check(model.sheet == nil,"unconfigured vault does not offer an ineffective password-change dialog")
            check(await model.create(password:password,confirmation:password),"synthetic vault is created")
            model.newDocument();model.updateTitle("V5 synthetic title");model.updateBody("V5 synthetic private body");model.updateCategory(.work)
            let documentID=model.selectedID
            check(model.flush(),"category and text persist in the same encrypted revision")
            let bytes=try Data(contentsOf:model.vaultDataURL)
            check(!String(decoding:bytes,as:UTF8.self).contains("V5 synthetic"),"saved revision contains no title or body plaintext")
            model.lock(reason:"synthetic test")
            check(await model.unlock(password:password),"saved encrypted revision reopens")
            check(model.selectedDocument?.id == documentID && model.selectedDocument?.category == .work && model.selectedDocument?.body == "V5 synthetic private body","classification survives lock and unlock without changing document identity")
            model.changeIdleMinutes(1)
            let reopened=VaultModel(dataDirectory:directory.appendingPathComponent("current"),protectedDataAvailable:{true})
            check(reopened.idleMinutes == 1,"one-minute preference survives model recreation")
            model.recordActivity();model.checkIdle(uptime:ProcessInfo.processInfo.systemUptime+59)
            check(model.isUnlocked,"one-minute timer keeps content before its boundary")
            model.checkIdle(uptime:ProcessInfo.processInfo.systemUptime+61)
            check(!model.isUnlocked && model.documents.isEmpty,"one-minute timer locks and clears at its boundary")
            for minutes in [5,10] {
                model.changeIdleMinutes(minutes)
                let restored=VaultModel(dataDirectory:directory.appendingPathComponent("current"),protectedDataAvailable:{true})
                check(restored.idleMinutes == minutes,"\(minutes)-minute preference survives model recreation")
            }
            let preferenceURL=directory.appendingPathComponent("current/protection.json")
            check((try FileManager.default.attributesOfItem(atPath:preferenceURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,"protection preference file is private")
            let preferenceBytes=try Data(contentsOf:preferenceURL)
            model.changeIdleMinutes(2)
            let invalidPreferenceBytes=try Data(contentsOf:preferenceURL)
            check(model.idleMinutes == 10 && invalidPreferenceBytes == preferenceBytes,"unsupported idle value changes neither memory nor disk")
            let lockedExport=directory.appendingPathComponent("locked-export.deskdenvault")
            check(model.exportBackup(to:lockedExport),"locked vault exports its existing ciphertext")
            check(try Data(contentsOf:lockedExport) == Data(contentsOf:model.vaultDataURL),"locked export is byte-identical encrypted data with no invented document count")
            model.requestPasswordChange()
            check(model.sheet == .unlockForPassword && !model.isUnlocked,"locked password change first requests real unlock")
            check(!(await model.unlock(password:"wrong-synthetic-password")) && !model.isUnlocked,"incorrect unlock cannot reach password change")
            check(await model.unlock(password:password),"correct unlock permits password change")
            model.requestPasswordChange();check(model.sheet == .password,"unlocked password change opens the real change form")
            model.closeSheet();check(model.sheet == nil,"cancel closes password form without changing credentials")

            check(model.loadRestoreSource(lockedExport),"restore reads a valid encrypted backup")
            let beforeVerify=try Data(contentsOf:model.vaultDataURL)
            check(!(await model.verifyRestore(password:"wrong-backup-password")),"incorrect backup password fails")
            check(try Data(contentsOf:model.vaultDataURL) == beforeVerify,"failed verification never overwrites current data")
            check(await model.verifyRestore(password:password),"correct backup password creates confirmation metadata")
            check(try Data(contentsOf:model.vaultDataURL) == beforeVerify,"successful verification alone never overwrites current data")
            let editor=VaultCheckTextView();editor.allowsUndo=true;editor.string="Native synthetic private body"
            editor.history.registerUndo(withTarget:editor){$0.string="Retained synthetic undo"}
            var modalDraft="Synthetic private modal input"
            model.registerPlaintextClearer(id:UUID()){modalDraft="";VaultPlaintextPrivacy.clear(editor)}
            model.sheet = .restore
            model.lock(reason:"lock during private confirmation")
            check(modalDraft.isEmpty && editor.string.isEmpty && !editor.history.canUndo,"lock clears registered modal draft, native text, and native undo")
            check(model.sheet == nil && model.restorePreview == nil && model.restoreSourceName == nil && model.documents.isEmpty,"lock removes restoration and modal plaintext state")
            check(!model.confirmRestore(),"cleared restore confirmation cannot later replace data")
            var lockedInput="Synthetic locked password input"
            model.registerPlaintextClearer(id:UUID()){lockedInput=""}
            model.lock(reason:"minimize while already locked")
            check(lockedInput.isEmpty,"locking an already locked page also clears its pending password input")

            let futureDirectory=directory.appendingPathComponent("future-preferences")
            try FileManager.default.createDirectory(at:futureDirectory,withIntermediateDirectories:true)
            let futurePreferences=Data("{\"schema\":3,\"idleMinutes\":1}".utf8)
            let futureURL=futureDirectory.appendingPathComponent("protection.json");try futurePreferences.write(to:futureURL)
            let future=VaultModel(dataDirectory:futureDirectory,protectedDataAvailable:{true})
            future.changeIdleMinutes(10)
            check(future.idleMinutes == 5 && !future.canChangeProtectionPreferences && future.errorMessage != nil,"unknown protection schema uses safe default and blocks editing")
            check(try Data(contentsOf:futureURL) == futurePreferences,"unknown protection schema is never overwritten")
            let failedDirectory=directory.appendingPathComponent("failed-preferences")
            let failed=VaultModel(dataDirectory:failedDirectory,protectedDataAvailable:{true})
            try FileManager.default.createDirectory(at:failedDirectory.appendingPathComponent("protection.json"),withIntermediateDirectories:true)
            failed.changeIdleMinutes(1)
            check(failed.idleMinutes == 5 && failed.errorMessage != nil,"failed atomic preference replacement retains the in-memory value")
            check(try FileManager.default.contentsOfDirectory(atPath:failedDirectory.path) == ["protection.json"],"failed atomic preference replacement removes its private temporary file")

            let contents=VaultContents(documents:[PrivateDocument(title:"Legacy synthetic",body:"Legacy preserved body")])
            let created=try VaultCryptography.create(contents:contents,password:password)
            let legacyData=try variant(created,category:nil)
            let legacyDirectory=directory.appendingPathComponent("legacy"),legacyStore=VaultFileStore(url:legacyDirectory.appendingPathComponent("private.deskdenvault"))
            try legacyStore.write(VaultCryptography.decodeEnvelope(legacyData))
            let legacy=VaultModel(dataDirectory:legacyDirectory,protectedDataAvailable:{true})
            check(await legacy.unlock(password:password),"pre-category encrypted data remains readable")
            check(legacy.selectedDocument?.category == .unclassified,"pre-category documents default to unclassified")
            legacy.updateCategory(.personal);check(legacy.flush(),"legacy document can receive an explicit category")
            legacy.lock(reason:"legacy round trip");_=await legacy.unlock(password:password)
            check(legacy.selectedDocument?.category == .personal && legacy.selectedDocument?.body == "Legacy preserved body","legacy migration preserves body and explicit new category")
            legacy.lock(reason:"test complete")

            let unknownDirectory=directory.appendingPathComponent("future-category"),unknownStore=VaultFileStore(url:unknownDirectory.appendingPathComponent("private.deskdenvault"))
            let unknownData=try variant(created,category:"future-category")
            try unknownStore.write(VaultCryptography.decodeEnvelope(unknownData))
            let unknown=VaultModel(dataDirectory:unknownDirectory,protectedDataAvailable:{true})
            let unknownBefore=try unknownStore.read()
            check(!(await unknown.unlock(password:password)) && unknown.documents.isEmpty,"unknown future document category is rejected without reclassification")
            unknown.newDocument();unknown.updateCategory(.work);_=unknown.flush()
            check(!(await unknown.create(password:password,confirmation:password)),"unknown existing vault cannot be recreated over its data")
            check(try unknownStore.read() == unknownBefore,"unknown future category remains byte-for-byte intact")
            check(unknown.loadRestoreSource(unknownStore.url),"future-category envelope can be selected without decrypting it")
            check(!(await unknown.verifyRestore(password:password)) && !unknown.confirmRestore(),"unsupported backup contents never reach replacement confirmation")
            check(try unknownStore.read() == unknownBefore,"unsupported backup validation preserves the existing encrypted file")
            unknown.cancelRestore();model.lock(reason:"test complete")

            let syntheticBiometrics=VaultSyntheticBiometrics()
            let refined=VaultModel(dataDirectory:directory.appendingPathComponent("refinement"),protectedDataAvailable:{true},biometrics:syntheticBiometrics)
            check(await refined.create(password:password,confirmation:password),"refinement vault starts with a password")
            refined.newDocument();refined.updateTitle("Synthetic rich title")
            let richBody="Synthetic 加粗正文 🔐\nSecond line"
            let richRuns=[VaultTextStyleRun(location:0,length:10,family:.serif,size:18,bold:true,italic:true,underline:true),VaultTextStyleRun(location:10,length:(richBody as NSString).length-10)]
            refined.updateRichBody(richBody,formatting:richRuns)
            check(refined.selectedDocument?.formatting == richRuns,"body and semantic formatting are accepted together")
            check(refined.addCategory("资料"),"user can add an encrypted category")
            let group=refined.categories.last!
            refined.moveSelected(to:group.id)
            check(refined.selectedDocument?.effectiveCategoryID == group.id,"text moves into a custom category")
            check(refined.renameCategory(group.id,to:"归档资料"),"category can be renamed without changing its identity")
            check(refined.categoryTitle(refined.selectedDocument!) == "归档资料","text immediately reflects category rename")
            check(!refined.addCategory("归档资料") && !refined.renameCategory(group.id,to:"未分类"),"duplicate and reserved category names are rejected")
            check(refined.flush(),"rich text and categories share an encrypted revision")
            let refinedBytes=try Data(contentsOf:refined.vaultDataURL)
            check(!String(decoding:refinedBytes,as:UTF8.self).contains("归档资料") && !String(decoding:refinedBytes,as:UTF8.self).contains("Synthetic"),"category and rich body never appear in on-disk plaintext")
            refined.lock(reason:"refinement round trip");check(await refined.unlock(password:password),"rich revision unlocks with the existing password")
            check(refined.selectedDocument?.formatting == richRuns && refined.selectedDocument?.body == richBody && refined.categories.contains{$0.id == group.id && $0.name == "归档资料"},"formatting, Unicode body, and category round trip")
            check(refined.deleteCategory(group.id,movingTo:"work"),"deleting a category moves its texts to the selected existing category")
            check(refined.selectedDocument?.effectiveCategoryID == "work" && refined.selectedDocument?.body == richBody && refined.selectedDocument?.formatting == richRuns,"category deletion preserves text and formatting")
            check(refined.deleteCategory("work"),"built-in category can also be deleted coherently")
            check(refined.selectedDocument?.effectiveCategoryID == "unclassified","default category deletion preserves text in unclassified")
            let navigationBiometrics=VaultSyntheticBiometrics()
            let navigation=VaultModel(dataDirectory:directory.appendingPathComponent("category-navigation"),protectedDataAvailable:{true},biometrics:navigationBiometrics)
            check(await navigation.create(password:password,confirmation:password),"category navigation starts with an isolated encrypted vault")
            navigation.newDocument();navigation.updateTitle("Alpha reference");navigation.updateBody("Synthetic category draft")
            let alphaID=navigation.selectedID!
            check(navigation.addCategory("Empty group"),"category navigation can create an empty group")
            let emptyGroup=navigation.categories.last!
            check(navigation.selectCategory("work") && navigation.selectedID == nil && navigation.visibleDocuments().isEmpty,
                  "selecting an empty category clears the old editor selection")
            navigation.newDocument();navigation.updateTitle("Work reference")
            let workID=navigation.selectedID!
            check(navigation.selectedDocument?.effectiveCategoryID == "work" && navigation.categoryFilter == "work",
                  "new text inherits the active category instead of jumping to all categories")
            check(navigation.selectCategory("all") && navigation.selectedID == workID && navigation.selectCategory("work") && navigation.selectedID == workID,
                  "a selected text stays selected when it remains visible in the new category filter")
            check(navigation.selectCategory(emptyGroup.id) && navigation.selectedID == nil,"another empty group never retains the previous category's editor")
            navigation.newDocument();navigation.updateTitle("Custom reference")
            let customID=navigation.selectedID!
            check(navigation.selectedDocument?.effectiveCategoryID == emptyGroup.id && navigation.visibleDocuments().map(\.id) == [customID],"new text also inherits an empty custom group")
            check(navigation.renameCategory(emptyGroup.id,to:"Renamed group") && navigation.categoryFilter == emptyGroup.id && navigation.selectedID == customID,
                  "renaming a selected category preserves its stable filter and editor identity")
            navigation.moveSelected(to:"personal")
            check(navigation.categoryFilter == "personal" && navigation.selectedID == customID && navigation.visibleDocuments().map(\.id) == [customID],
                  "moving the current text follows its destination without leaving an invisible editor selection")
            check(navigation.deleteCategory("personal",movingTo:"work") && navigation.categoryFilter == "work" && navigation.selectedID == customID,
                  "deleting the active category follows the explicit destination and preserves the selected text")
            check(navigation.deleteDocument(customID) && navigation.selectedID == workID && navigation.visibleDocuments().map(\.id) == [workID],
                  "deleting a selected text chooses the next text inside the current category")
            check(navigation.selectCategory(emptyGroup.id) && navigation.deleteCategory(emptyGroup.id) && navigation.categoryFilter == "unclassified" && navigation.selectedID == alphaID,
                  "deleting an empty selected category resolves to an existing destination without deleting texts")
            check(navigation.selectCategory("all",matching:"alpha") && navigation.selectedID == alphaID && navigation.visibleDocuments(matching:"ALPHA").map(\.id) == [alphaID],
                  "category selection chooses only a text matching the visible title query")
            check(!navigation.selectCategory("missing-group") && navigation.categoryFilter == "all" && navigation.selectedID == alphaID,
                  "an unknown category cannot change the current filter or selected document")
            navigation.updateBody("Synthetic encrypted draft retained on failed category navigation")
            let navigationBefore=try Data(contentsOf:navigation.vaultDataURL),preservedNavigation=directory.appendingPathComponent("preserved-category-navigation.deskdenvault")
            try FileManager.default.moveItem(at:navigation.vaultDataURL,to:preservedNavigation)
            try FileManager.default.createDirectory(at:navigation.vaultDataURL,withIntermediateDirectories:false)
            check(!navigation.selectCategory("work") && navigation.categoryFilter == "all" && navigation.selectedID == alphaID && navigation.hasPendingSave,
                  "a real encrypted-write failure blocks category switching and retains the pending draft")
            navigation.selectDocument(workID);let countBeforeRejectedCreate=navigation.documents.count;navigation.newDocument()
            check(navigation.selectedID == alphaID && navigation.documents.count == countBeforeRejectedCreate && navigation.selectedDocument?.body.contains("retained") == true,
                  "failed saving also blocks switching documents and creating a replacement selection")
            let categoriesBeforeRejectedDelete=navigation.categories
            navigation.moveSelected(to:"work")
            check(!navigation.deleteCategory("work") && navigation.categories == categoriesBeforeRejectedDelete && navigation.selectedDocument?.effectiveCategoryID == "unclassified",
                  "failed saving cannot move the selected text or remove a category")
            check(try Data(contentsOf:preservedNavigation) == navigationBefore,"failed navigation preserves the previous encrypted revision byte for byte")
            try FileManager.default.removeItem(at:navigation.vaultDataURL)
            try FileManager.default.moveItem(at:preservedNavigation,to:navigation.vaultDataURL)
            check(navigation.flush() && navigation.selectCategory("work") && navigation.selectedID == workID && !navigation.hasPendingSave,
                  "retrying the original encrypted save permits the same category navigation")
            let navigationBytes=try Data(contentsOf:navigation.vaultDataURL)
            check(!String(decoding:navigationBytes,as:UTF8.self).contains("Synthetic") && !String(decoding:navigationBytes,as:UTF8.self).contains("Renamed group"),
                  "classification and navigation changes never expose text or category names in plaintext")
            navigation.lock(reason:"isolated category navigation complete")
            check(navigation.categoryFilter == "all" && navigation.selectedID == nil && navigation.documents.isEmpty && navigation.categories.isEmpty,
                  "locking clears category navigation together with private content")
            check(await navigation.unlock(password:password) && navigation.documents.first{$0.id == alphaID}?.body.contains("retained") == true,
                  "the draft blocked by navigation still round trips after the save is retried")
            navigation.lock(reason:"isolated category checks finished")
            check(navigationBiometrics.enrollments == 0 && navigationBiometrics.reads == 0 && navigationBiometrics.removals == 0,
                  "category checks never enroll, authenticate, or remove a biometric key")
            refined.updateBody("Plain synthetic replacement")
            check(refined.selectedDocument?.formatting == nil,"plain-body replacement cannot retain stale formatting ranges")
            syntheticBiometrics.available=false;await refined.refreshBiometrics()
            check(!refined.biometricAvailable && refined.biometricUnavailableReason != nil,"missing injected capability is explained before enrollment")
            check(!(await refined.enableBiometrics()) && syntheticBiometrics.enrollments == 0 && refined.isUnlocked,"unavailable capability never authenticates or weakens the unlocked password session")
            syntheticBiometrics.available=true;await refined.refreshBiometrics()
            check(refined.biometricAvailable && refined.biometricUnavailableReason == nil,"approved injected capability exposes the real opt-in path")
            check(await refined.enableBiometrics(),"explicit opt-in enrolls only through the injected biometric boundary")
            check(syntheticBiometrics.enrollments == 1 && syntheticBiometrics.secret?.count == 32,"biometric enrollment stores only a vault AES key, not the password")
            let passiveVaultBefore=try Data(contentsOf:refined.vaultDataURL)
            let passivePreferenceURL=directory.appendingPathComponent("refinement/protection.json")
            let passivePreferencesBefore=try Data(contentsOf:passivePreferenceURL)
            syntheticBiometrics.silentProbeResult=false
            let passiveRefreshBefore=syntheticBiometrics.refreshes,passiveContainsBefore=syntheticBiometrics.containsCalls,passiveReadsBefore=syntheticBiometrics.reads,passiveRemovalsBefore=syntheticBiometrics.removals,passiveCancelsBefore=syntheticBiometrics.cancels
            await refined.refreshBiometrics()
            check(refined.biometricEnabled && refined.biometricAvailable && refined.errorMessage == nil,"enabled Touch ID stays error-free when a silent protected-key probe would not succeed")
            check(syntheticBiometrics.refreshes == passiveRefreshBefore+1 && syntheticBiometrics.containsCalls == passiveContainsBefore,"passive protection-page refresh runs only the independent capability metadata preflight")
            check(syntheticBiometrics.reads == passiveReadsBefore && syntheticBiometrics.enrollments == 1 && syntheticBiometrics.removals == passiveRemovalsBefore && syntheticBiometrics.cancels == passiveCancelsBefore,"passive refresh never reads, enrolls, removes, or cancels a protected key")
            check(try Data(contentsOf:refined.vaultDataURL) == passiveVaultBefore && Data(contentsOf:passivePreferenceURL) == passivePreferencesBefore,"passive refresh leaves encrypted content and saved biometric opt-in byte-identical")
            refined.errorMessage="Synthetic unrelated save error"
            await refined.refreshBiometrics()
            check(refined.errorMessage == "Synthetic unrelated save error","successful biometric refresh never clears an unrelated save error")
            refined.errorMessage=nil
            let preferences=try Data(contentsOf:directory.appendingPathComponent("refinement/protection.json"))
            check(!String(decoding:preferences,as:UTF8.self).contains(password) && preferences.count<256,"nonsecret preferences contain neither password nor encryption key")
            refined.lock(reason:"biometric test")
            syntheticBiometrics.failAuthentication=true
            check(!(await refined.unlockWithBiometrics()) && !refined.isUnlocked && refined.documents.isEmpty,"cancelled biometric authentication exposes no plaintext")
            check(await refined.unlock(password:password),"password remains available after biometric cancellation")
            refined.lock(reason:"biometric success");syntheticBiometrics.failAuthentication=false
            check(await refined.unlockWithBiometrics(),"successful injected biometric authentication releases the key and decrypts the vault")
            refined.lock(reason:"synthetic missing biometric key")
            syntheticBiometrics.secret=nil
            await refined.refreshBiometrics()
            check(refined.biometricEnabled && refined.errorMessage == nil,"passive metadata availability makes no claim that a protected key still exists")
            let missingKeyReadsBefore=syntheticBiometrics.reads
            check(!(await refined.unlockWithBiometrics()) && !refined.isUnlocked && refined.documents.isEmpty && refined.errorMessage != nil && syntheticBiometrics.reads == missingKeyReadsBefore+1,"a genuinely missing key is rejected only by the explicit unlock attempt without exposing plaintext")
            check(await refined.unlock(password:password),"password unlock remains available after an explicit missing-key failure")
            check(await refined.changePassword(current:password,new:"changed-synthetic-password",confirmation:"changed-synthetic-password"),"password change succeeds while revoking biometric access")
            check(!refined.biometricEnabled && syntheticBiometrics.secret == nil && !refined.isUnlocked,"password change removes biometric key before using a new vault salt")
            check(await refined.unlock(password:"changed-synthetic-password"),"new password remains the independent fallback")
            check(await refined.enableBiometrics(),"biometrics can be explicitly re-enrolled after password change")
            check(await refined.disableBiometrics() && syntheticBiometrics.secret == nil && !refined.biometricEnabled,"opt-out deletes protected key and saved opt-in flag")
            refined.lock(reason:"finished isolated refinement")
            var invalid=PrivateDocument(body:"emoji 🔐")
            invalid.formatting=[VaultTextStyleRun(location:0,length:100)]
            check((try? VaultContents(documents:[invalid]).validate()) == nil,"out-of-range rich formatting is rejected")
            invalid.formatting=[VaultTextStyleRun(location:0,length:1,size:100)]
            check((try? VaultContents(documents:[invalid]).validate()) == nil,"unsupported font sizes are rejected")
            invalid.formatting=nil;invalid.categoryID="missing-category"
            check((try? VaultContents(documents:[invalid]).validate()) == nil,"orphaned custom category references are rejected")
            let syntheticID="A1B2C3D4E5.example.synthetic-vault"
            func capability(app:String?=syntheticID,group:[String]?=[syntheticID],profile:Bool=true,signature:Bool=true)->VaultBiometricSigningCapability {VaultBiometricSigningCapability.evaluate(bundleIdentifier:"example.synthetic-vault",applicationIdentifier:app,teamIdentifier:"A1B2C3D4E5",groups:group,embeddedProfileExists:profile,signatureValid:signature)}
            check(capability().accessGroup == syntheticID,"matching signed claims select only the app's own exact group before the separate system probe")
            check(capability(profile:false).accessGroup == nil,"self-asserted entitlements without an embedded profile cannot enable Touch ID")
            check(capability(signature:false).accessGroup == nil,"untrusted or ad-hoc signature cannot enable Touch ID")
            check(capability(app:"A1B2C3D4E5.example.other").accessGroup == nil,"another app identifier cannot enable Touch ID")
            check(capability(app:"A1B2C3D4E5.*").accessGroup == nil,"wildcard entitlement claims cannot enable Touch ID")
            check(capability(group:["A1B2C3D4E5.example.other"]).accessGroup == nil,"unrelated shared group cannot stand in for the app's own group")
            check(capability(app:nil).unavailableReason != nil,"missing process application entitlement reports the unavailable-build reason")
        } catch {check(false,"unexpected isolated V5 check failure: \(error.localizedDescription)")}
        print("Vault V5 checks: \(checks-failures)/\(checks) passed")
        exit(failures == 0 ? 0:1)
    }
    private static func variant(_ vault:UnlockedVault,category:String?) throws -> Data {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(vault.contents)) as! [String:Any]
        var documents=object["documents"] as! [[String:Any]]
        documents[0]["category"]=category;object["documents"]=documents
        let plaintext=try JSONSerialization.data(withJSONObject:object)
        let box=try AES.GCM.seal(plaintext,using:vault.key,authenticating:Data("deskden-encrypted-vault:1:pbkdf2-sha256-310000".utf8))
        return try VaultCryptography.encoded(VaultEnvelope(rounds:VaultCryptography.rounds,salt:vault.envelope.salt,sealed:box.combined!))
    }
}

@MainActor private final class VaultCheckTextView:NSTextView {
    let history=UndoManager()
    override var undoManager:UndoManager? {history}
}

@MainActor private final class VaultSyntheticBiometrics:VaultBiometricStore {
    var available=true
    var secret:Data?
    var salt:Data?
    var enrollments=0
    var failAuthentication=false
    var silentProbeResult:Bool?
    var refreshes=0,containsCalls=0,reads=0,removals=0,cancels=0
    func refreshAvailability() async -> String? {refreshes += 1;return unavailableReason}
    func containsKey() async -> Bool {containsCalls += 1;return silentProbeResult ?? (secret != nil)}
    func enroll(key:Data,salt:Data) async throws {secret=key;self.salt=salt;enrollments += 1}
    func readKey(salt:Data) async throws -> Data {reads += 1;guard !failAuthentication,self.salt == salt,let secret else {throw VaultFailure.incorrectPassword};return secret}
    func remove() async throws {removals += 1;secret=nil;salt=nil}
    func removeSynchronously() throws {removals += 1;secret=nil;salt=nil}
    func cancel() {cancels += 1}
}
