import AppKit
import Foundation
import LauncherCore

/// Standalone model checks. All data is synthetic and written under a temporary directory.
/// No dialogs, windows, permission requests, or user files are touched.
@main struct VaultModelChecks {
    @MainActor static func main() async {
        _=NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-vault-model-checks-\(UUID().uuidString)")
        var failures=0,checks=0
        func check(_ condition:Bool,_ message:String) { checks += 1; if !condition { failures += 1 }; print("\(condition ? "PASS":"FAIL") \(message)") }
        func waitForBusy(_ model:VaultModel) async -> Bool {
            for _ in 0..<1000 { if model.busy { return true }; await Task.yield() }
            return false
        }
        defer { try? FileManager.default.removeItem(at:directory) }
        let pasteboard=NSPasteboard.withUniqueName(),copySource=NSPasteboard.withUniqueName()
        defer {pasteboard.releaseGlobally();copySource.releaseGlobally()}
        let clipboard=VaultClipboard(pasteboard:pasteboard,schedule:{_,_ in {}})
        var protectedAvailable=true
        let model=VaultModel(dataDirectory:directory,protectedDataAvailable:{ protectedAvailable },clipboard:clipboard)
        let blocked=VaultModel(dataDirectory:directory.appendingPathComponent("unavailable"),protectedDataAvailable:{ false })
        check(!(await blocked.create(password:"blocked-password",confirmation:"blocked-password")),"protected-data unavailability blocks creation before KDF")
        check(!FileManager.default.fileExists(atPath:blocked.vaultDataURL.path),"blocked creation never writes a vault")
        let created=await model.create(password:"model-check-password",confirmation:"model-check-password")
        check(created && model.isUnlocked && model.documents.isEmpty,"first creation starts an empty encrypted vault")
        model.newDocument(); model.updateTitle("Synthetic private title"); model.updateBody("Latest synthetic private body")
        check(model.hasPendingSave,"editing immediately creates an encrypted pending revision")
        check(model.flush(),"pending revision persists")
        let backup=directory.appendingPathComponent("export.deskdenvault")
        check(model.exportBackup(to:backup),"export writes an encrypted portable backup")
        copySource.setString("Synthetic copied private text",forType:.string)
        check(clipboard.publishSelection(from:copySource),"private copy is published on an isolated clipboard")
        var didClear=false; model.registerPlaintextClearer(id:UUID()) { didClear=true }
        model.lock(reason:"test lock")
        check(!model.isUnlocked && model.documents.isEmpty && model.selectedDocument == nil && didClear,"lock clears model plaintext and registered native editors")
        check(pasteboard.string(forType:.string) == nil,"model lock immediately clears its owned private clipboard")
        protectedAvailable=false
        check(!(await model.unlock(password:"model-check-password")) && !model.isUnlocked,"protected-data unavailability blocks unlock entry")
        protectedAvailable=true
        check(!(await model.unlock(password:"wrong-password")) && !model.isUnlocked,"wrong password cannot unlock")
        check(await model.unlock(password:"model-check-password"),"correct password unlocks")
        check(model.selectedDocument?.body == "Latest synthetic private body","reopened body matches saved revision")

        model.lock(reason:"before protected-data race")
        let unavailableUnlock=Task { @MainActor in await model.unlock(password:"model-check-password") }
        check(await waitForBusy(model),"unlock KDF is in flight before protected-data loss")
        protectedAvailable=false
        check(!(await unavailableUnlock.value) && !model.isUnlocked && model.documents.isEmpty,"protected-data loss rejects a completed background unlock")
        protectedAvailable=true
        let interruptedCreation=VaultModel(dataDirectory:directory.appendingPathComponent("interrupted-create"),protectedDataAvailable:{ protectedAvailable })
        let pendingCreate=Task { @MainActor in await interruptedCreation.create(password:"creation-password",confirmation:"creation-password") }
        check(await waitForBusy(interruptedCreation),"creation KDF is in flight before protected-data loss")
        protectedAvailable=false
        check(!(await pendingCreate.value) && !interruptedCreation.isUnlocked,"protected-data loss rejects background vault creation")
        check(!FileManager.default.fileExists(atPath:interruptedCreation.vaultDataURL.path),"interrupted creation does not persist or adopt KDF results")
        protectedAvailable=true

        model.lock(reason:"before async race")
        let pendingUnlock=Task { @MainActor in await model.unlock(password:"model-check-password") }
        check(await waitForBusy(model),"unlock KDF is in flight before explicit lock")
        model.lock(reason:"left page while verifying")
        _=await pendingUnlock.value
        check(!model.isUnlocked && model.documents.isEmpty,"stale asynchronous unlock cannot reopen a locked session")
        _=await model.unlock(password:"model-check-password")
        model.checkIdle(uptime:ProcessInfo.processInfo.systemUptime+299)
        check(model.isUnlocked,"monotonic idle check does not lock before five minutes")
        model.checkIdle(uptime:ProcessInfo.processInfo.systemUptime+301)
        check(!model.isUnlocked && model.documents.isEmpty,"five minute idle boundary locks")
        _=await model.unlock(password:"model-check-password")

        // Make backup revision creation fail without changing permissions or deleting user data.
        let previous=model.vaultDataURL.appendingPathExtension("previous")
        try? FileManager.default.removeItem(at:previous)
        try? FileManager.default.createDirectory(at:previous,withIntermediateDirectories:true)
        model.updateBody("Pending survives a failed disk write")
        check(!model.flush() && model.hasPendingSave,"failed disk write keeps encrypted pending revision")
        model.lock(reason:"failure lock")
        check(!model.isUnlocked && model.documents.isEmpty && model.hasPendingSave,"failed save still permits secure plaintext clearing")
        check(!model.flush(),"flush rejects exit while encrypted changes cannot persist")
        try? FileManager.default.removeItem(at:previous)
        check(model.flush() && !model.hasPendingSave,"locked encrypted pending revision can be retried without password")
        _=await model.unlock(password:"model-check-password")
        check(model.selectedDocument?.body == "Pending survives a failed disk write","retry preserves the latest accepted edit")

        check(model.loadRestoreSource(backup),"backup selection checks encrypted envelope")
        let beforeRestore=try? Data(contentsOf:model.vaultDataURL)
        check(!(await model.verifyRestore(password:"incorrect")),"incorrect backup password fails verification")
        check((try? Data(contentsOf:model.vaultDataURL)) == beforeRestore,"verification failure never replaces current data")
        check(await model.verifyRestore(password:"model-check-password"),"correct backup reaches confirmation only")
        check(model.selectedDocument?.body == "Pending survives a failed disk write","successful verification alone does not replace current contents")
        check(model.confirmRestore() && !model.isUnlocked && model.documents.isEmpty,"confirmed restore locks and clears old plaintext")
        check(model.lastPreservedPath.map { FileManager.default.fileExists(atPath:$0) } == true,"confirmed restore preserves displaced encrypted file")
        _=await model.unlock(password:"model-check-password")
        check(model.selectedDocument?.body == "Latest synthetic private body","restored backup contains exported revision")
        let beforePasswordChange=try? Data(contentsOf:model.vaultDataURL)
        let pendingChange=Task { @MainActor in await model.changePassword(current:"model-check-password",new:"cancelled-change-password",confirmation:"cancelled-change-password") }
        check(await waitForBusy(model),"password-change preparation runs before an explicit lock")
        model.lock(reason:"lock during password preparation")
        check(!(await pendingChange.value) && !model.isUnlocked,"locking cancels adoption and disk commit of a prepared password change")
        check((try? Data(contentsOf:model.vaultDataURL)) == beforePasswordChange,"cancelled password preparation leaves encrypted disk bytes unchanged")
        check(await model.unlock(password:"model-check-password"),"original password still works after cancelled preparation")
        check(await model.changePassword(current:"model-check-password",new:"changed-model-password",confirmation:"changed-model-password"),"password change verifies old key and reseals contents")
        check(!model.isUnlocked,"password change locks immediately")
        check(!(await model.unlock(password:"model-check-password")),"old password no longer opens current vault")
        check(await model.unlock(password:"changed-model-password"),"new password opens changed vault")
        let previousBytes=try? Data(contentsOf:previous)
        check(previousBytes.flatMap{try? VaultCryptography.unlock(data:$0,password:"model-check-password")} == nil,"old password no longer decrypts the automatic local previous revision")
        check(previousBytes.flatMap{try? VaultCryptography.unlock(data:$0,password:"changed-model-password")} != nil,"automatic previous revision remains recoverable with the new password")
        let preservedBytes=model.lastPreservedPath.flatMap{try? Data(contentsOf:URL(fileURLWithPath:$0))}
        check(preservedBytes.flatMap{try? VaultCryptography.unlock(data:$0,password:"model-check-password")} == nil,"old password no longer decrypts the restore-preserved local history")
        check(preservedBytes.flatMap{try? VaultCryptography.unlock(data:$0,password:"changed-model-password")}?.contents.documents.first?.body == "Pending survives a failed disk write","password change preserves the original contents of local restore history")
        check((try? Data(contentsOf:backup)).flatMap{try? VaultCryptography.unlock(data:$0,password:"model-check-password")} != nil,"user-exported backup stays unchanged and retains its original password")
        model.lock(reason:"test complete")
        let minimum=VaultModel(dataDirectory:directory.appendingPathComponent("existing-password-policy"),protectedDataAvailable:{true})
        check(await minimum.create(password:"12345678",confirmation:"12345678"),"existing eight-character password requirement is preserved")
        minimum.lock(reason:"test complete")
        do {
            let recoveryDirectory=directory.appendingPathComponent("interrupted-password-change")
            let original=VaultModel(dataDirectory:recoveryDirectory,protectedDataAvailable:{true})
            check(await original.create(password:"original-recovery-password",confirmation:"original-recovery-password"),"interruption fixture starts with an independent password")
            original.newDocument();original.updateBody("Synthetic recovery body")
            check(original.flush(),"interruption fixture persists its original private content")
            original.lock(reason:"before interruption fixture")
            let recoveryStore=VaultFileStore(url:original.vaultDataURL)
            let plan=try recoveryStore.preparePasswordChange(currentPassword:"original-recovery-password",newPassword:"new-recovery-password")
            let oldPrevious=try Data(contentsOf:original.vaultDataURL.appendingPathExtension("previous"))
            try JSONEncoder().encode(plan).write(to:original.vaultDataURL.appendingPathExtension("password-change"))
            let changedPrevious=try VaultCryptography.create(contents:VaultContents(),password:"other-fixture-password")
            try VaultCryptography.encoded(changedPrevious.envelope).write(to:original.vaultDataURL.appendingPathExtension("previous"))
            let blocked=VaultModel(dataDirectory:recoveryDirectory,protectedDataAvailable:{true})
            check(blocked.hasPendingSave && blocked.hasPendingPasswordChange && blocked.errorMessage != nil,"failed startup recovery retains the transaction and exposes a retry state")
            check(!blocked.flush() && !blocked.isUnlocked,"ordinary saving cannot bypass an incomplete password transaction")
            try oldPrevious.write(to:original.vaultDataURL.appendingPathExtension("previous"))
            check(blocked.flush() && !blocked.hasPendingSave && !blocked.hasPendingPasswordChange,"retry finishes the original ciphertext transaction without recreating an old-password previous copy")
            check(!(await blocked.unlock(password:"original-recovery-password")),"old password stays invalid after retry recovery")
            check(await blocked.unlock(password:"new-recovery-password"),"new password opens the transaction recovered through the model")
            check(blocked.selectedDocument?.body == "Synthetic recovery body","model recovery preserves the original accepted private content")
            blocked.lock(reason:"before startup recovery fixture")
            let next=try recoveryStore.preparePasswordChange(currentPassword:"new-recovery-password",newPassword:"next-recovery-password")
            try JSONEncoder().encode(next).write(to:original.vaultDataURL.appendingPathExtension("password-change"))
            let resumed=VaultModel(dataDirectory:recoveryDirectory,protectedDataAvailable:{true})
            check(!resumed.hasPendingPasswordChange && !resumed.hasPendingSave && !resumed.isUnlocked,"startup completes a valid interrupted change while leaving private content locked")
            check(resumed.completionMessage?.contains("新密码") == true,"startup recovery visibly explains which password now opens the vault")
            check(await resumed.unlock(password:"next-recovery-password"),"startup recovery consistently uses the latest new password")
            resumed.lock(reason:"test complete")
        } catch {check(false,"password transaction model recovery failed: \(error.localizedDescription)")}
        print("Vault model checks: \(checks-failures)/\(checks) passed")
        exit(failures == 0 ? 0:1)
    }
}
