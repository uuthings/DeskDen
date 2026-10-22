import AppKit
import CryptoKit
import Foundation
import LauncherCore

/// V5-only checks use synthetic passwords and isolated temporary data. They do
/// not show windows, open file panels, request permissions, or touch user files.
@main struct VaultV5ModelChecks {
    @MainActor static func main() async {
        _=NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-vault-v5-checks-\(UUID().uuidString)")
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
            let lockedExport=directory.appendingPathComponent("locked-export.fangcunvault")
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
            let futurePreferences=Data("{\"schema\":2,\"idleMinutes\":1}".utf8)
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
            let legacyDirectory=directory.appendingPathComponent("legacy"),legacyStore=VaultFileStore(url:legacyDirectory.appendingPathComponent("private.fangcunvault"))
            try legacyStore.write(VaultCryptography.decodeEnvelope(legacyData))
            let legacy=VaultModel(dataDirectory:legacyDirectory,protectedDataAvailable:{true})
            check(await legacy.unlock(password:password),"pre-category encrypted data remains readable")
            check(legacy.selectedDocument?.category == .unclassified,"pre-category documents default to unclassified")
            legacy.updateCategory(.personal);check(legacy.flush(),"legacy document can receive an explicit category")
            legacy.lock(reason:"legacy round trip");_=await legacy.unlock(password:password)
            check(legacy.selectedDocument?.category == .personal && legacy.selectedDocument?.body == "Legacy preserved body","legacy migration preserves body and explicit new category")
            legacy.lock(reason:"test complete")

            let unknownDirectory=directory.appendingPathComponent("future-category"),unknownStore=VaultFileStore(url:unknownDirectory.appendingPathComponent("private.fangcunvault"))
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
        } catch {check(false,"unexpected isolated V5 check failure: \(error.localizedDescription)")}
        print("Vault V5 checks: \(checks-failures)/\(checks) passed")
        exit(failures == 0 ? 0:1)
    }
    private static func variant(_ vault:UnlockedVault,category:String?) throws -> Data {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(vault.contents)) as! [String:Any]
        var documents=object["documents"] as! [[String:Any]]
        documents[0]["category"]=category;object["documents"]=documents
        let plaintext=try JSONSerialization.data(withJSONObject:object)
        let box=try AES.GCM.seal(plaintext,using:vault.key,authenticating:Data("fangcun-encrypted-vault:1:pbkdf2-sha256-310000".utf8))
        return try VaultCryptography.encoded(VaultEnvelope(rounds:VaultCryptography.rounds,salt:vault.envelope.salt,sealed:box.combined!))
    }
}

@MainActor private final class VaultCheckTextView:NSTextView {
    let history=UndoManager()
    override var undoManager:UndoManager? {history}
}
