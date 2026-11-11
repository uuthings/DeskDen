import AppKit
import Combine
import CryptoKit
import Foundation
import LauncherCore
import UniformTypeIdentifiers
import LocalAuthentication
import Security

enum VaultSheet:String,Identifiable {
    case setup,password,passwordHint,touchIDDefault,backup,restore
    var id:String { rawValue }
}
struct VaultRestorePreview:Identifiable {
    let id=UUID()
    let envelope:VaultEnvelope
    let count:Int
    let sourceName:String
}

/// A hint is explicitly visible at the lock screen. Keep it local and bind it
/// to the vault's salt so a replacement vault cannot inherit the old hint.
private struct VaultPasswordHints:Codable {
    struct Record:Codable,Equatable {
        let salt:Data
        let text:String
    }

    var schema=1
    var records:[Record]

    func validated() throws -> Self {
        guard schema == 1,records.count<=2,Set(records.map(\.salt)).count == records.count,
              records.allSatisfy({$0.salt.count == 16 && !$0.text.isEmpty && $0.text.count<=VaultModel.maximumPasswordHintLength && $0.text.utf8.count<=4096}) else {
            throw VaultFailure.invalidData
        }
        return self
    }
}

private enum VaultHintFailure:LocalizedError {
    case invalid,protected
    var errorDescription:String? {
        switch self {
        case .invalid:"密码提示最多 \(VaultModel.maximumPasswordHintLength) 个字符。"
        case .protected:"密码提示无法读取，原文件已保留。"
        }
    }
}

@MainActor final class VaultModel:ObservableObject {
    nonisolated static let maximumPasswordHintLength=60
    private static let passwordHintFailureThreshold=3

    @Published private(set) var isUnlocked=false
    @Published private(set) var isConfigured=false
    @Published private(set) var busy=false
    @Published private(set) var documents:[PrivateDocument] = []
    @Published private(set) var categories:[VaultCategory] = []
    @Published private(set) var categoryFilter="all"
    @Published private(set) var biometricEnabled=false
    @Published private(set) var identityBiometricSetupRequired=false
    @Published private(set) var biometricAvailable=false
    @Published private(set) var biometricCanRemove=false
    @Published private(set) var biometricUnavailableReason:String?="正在检查 Touch ID 是否可用"
    @Published private(set) var preferredUnlockMethod:VaultUnlockMethod = .password
    @Published private(set) var passwordHint:String?
    @Published private(set) var shouldRevealPasswordHint=false
    @Published private(set) var selectedID:UUID?
    @Published private(set) var saveStatus="所有更改已保存"
    @Published private(set) var lockReason=""
    @Published private(set) var sessionID=UUID()
    @Published private(set) var hasPendingSave=false
    @Published var errorMessage:String?
    @Published var sheet:VaultSheet?
    @Published private(set) var showingProtection=false
    @Published private(set) var protectionFromSettings=false
    @Published private(set) var idleMinutes=5
    @Published var restorePreview:VaultRestorePreview?
    @Published private(set) var restoreSourceName:String?
    @Published private(set) var lastBackupPath:String?
    @Published private(set) var lastPreservedPath:String?
    let vaultDataURL:URL
    private let store:VaultFileStore
    private let protectionURL:URL
    private let passwordHintsURL:URL
    private let biometrics:any VaultBiometricStore
    private let clipboard:VaultClipboard
    private var biometricOperationInFlight=false
    private var protectionProtected=false
    private var passwordHintsProtected=false
    private var passwordHints:[VaultPasswordHints.Record]=[]
    private var failedPasswordAttempts=0
    private var key:SymmetricKey?
    private var salt:Data?
    private var openedPayloadVersion=3
    private var pendingEnvelope:VaultEnvelope?
    private var restoreData:Data?
    private var generation=0
    private var saveTask:Task<Void,Never>?
    private var idleTask:Task<Void,Never>?
    private var lastActivityUptime=ProcessInfo.processInfo.systemUptime
    private let protectedDataAvailable:()->Bool
    private var activityMonitor:Any?
    private var panel:NSPanel?
    private var plaintextClearers:[UUID:()->Void] = [:]
    /// The shell can supply its window without retaining it. Activity elsewhere does not reset this vault's idle timer.
    weak var hostWindow:NSWindow?

    init(dataDirectory:URL,protectedDataAvailable:@escaping ()->Bool = { NSApp.isProtectedDataAvailable },biometrics:(any VaultBiometricStore)?=nil,clipboard:VaultClipboard?=nil) {
        vaultDataURL=dataDirectory.appendingPathComponent("private.deskdenvault")
        store=VaultFileStore(url:vaultDataURL)
        protectionURL=dataDirectory.appendingPathComponent("protection.json")
        passwordHintsURL=dataDirectory.appendingPathComponent("password-hints.json")
        self.protectedDataAvailable=protectedDataAvailable
        self.biometrics=biometrics ?? VaultKeychainBiometrics(vaultURL:vaultDataURL)
        self.clipboard=clipboard ?? .shared
        do {
            if try store.recoverPasswordChange() != nil {lockReason="上次密码更改已完成，请使用新密码解锁"}
        } catch {
            hasPendingSave=true;saveStatus="密码更改尚未完成"
            errorMessage="密码更改尚未完成，加密资料已保留。请重试保存，完成后使用新密码解锁。\n\(error.localizedDescription)"
        }
        isConfigured=FileManager.default.fileExists(atPath:vaultDataURL.path)
        if FileManager.default.fileExists(atPath:protectionURL.path) {
            do {
                let handle=try FileHandle(forReadingFrom:protectionURL);defer{try? handle.close()}
                let data=try handle.read(upToCount:16_385) ?? Data()
                guard data.count <= 16_384 else {throw VaultFailure.invalidData}
                let preferences=try JSONDecoder().decode(VaultProtectionPreferences.self,from:data).validated()
                idleMinutes=preferences.idleMinutes;biometricEnabled=preferences.biometricEnabled
                preferredUnlockMethod=preferences.preferredUnlockMethod
            } catch {protectionProtected=true;errorMessage="锁定偏好无法读取，原文件已保留；当前按 5 分钟自动锁定。"}
        }
        loadPasswordHints()
        identityBiometricSetupRequired = !biometricEnabled && FileManager.default.fileExists(atPath:dataDirectory.appendingPathComponent(LegacyIdentityMigration.vaultNoticeName).path)
        activityMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.rightMouseDown,.scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self,self.isUnlocked,let window=self.hostWindow,event.window === window || event.window?.sheetParent === window { self.recordActivity() }
            }
            return event
        }
        idleTask=Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(5))
                guard !Task.isCancelled else { return }
                self?.checkIdle()
            }
        }
    }
    isolated deinit { saveTask?.cancel(); idleTask?.cancel(); if let activityMonitor { NSEvent.removeMonitor(activityMonitor) } }
    var selectedDocument:PrivateDocument? { documents.first { $0.id == selectedID } }
    var completionMessage:String? {
        guard !isUnlocked else {return nil}
        if lockReason.hasPrefix("密码已更改") || lockReason.hasPrefix("上次密码更改已完成") || lockReason.hasPrefix("备份已恢复") {return lockReason}
        return identityBiometricSetupRequired ? "资料已迁移。请先用密码解锁，再重新开启 Touch ID。":nil
    }
    var canChangeProtectionPreferences:Bool { !protectionProtected }
    var effectiveUnlockMethod:VaultUnlockMethod {
        biometricEnabled && biometricAvailable ? preferredUnlockMethod:.password
    }
    var hasPendingPasswordChange:Bool {store.isPendingPasswordChange}
    func recordActivity() { lastActivityUptime=ProcessInfo.processInfo.systemUptime }
    func registerPlaintextClearer(id:UUID,_ clear:@escaping ()->Void) { plaintextClearers[id]=clear }
    func removePlaintextClearer(id:UUID) { plaintextClearers.removeValue(forKey:id) }
    func checkIdle(uptime:TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if isUnlocked && uptime-lastActivityUptime >= Double(idleMinutes)*60 { lock(reason:"已闲置 \(idleMinutes) 分钟，资料已锁定") }
    }
    func showProtection(fromSettings:Bool=false) {
        guard isUnlocked,!busy,requireProtectedData() else {return}
        protectionFromSettings=fromSettings;showingProtection=true;recordActivity()
    }
    func closeProtection() {showingProtection=false;protectionFromSettings=false}
    func requestPasswordChange() {
        guard isUnlocked,!busy,requireProtectedData() else { return }
        errorMessage=nil; sheet = .password
    }
    func closeSheet() {
        guard !busy else { return }
        if sheet == .restore { cancelRestore() }
        else { sheet=nil; errorMessage=nil }
    }
    func changeIdleMinutes(_ value:Int) {
        guard isUnlocked,!busy,requireProtectedData() else {return}
        guard !protectionProtected else {errorMessage="锁定偏好无法读取，当前未覆盖原文件。";return}
        do {
            try persistProtectionPreferences(idleMinutes:value,biometricEnabled:biometricEnabled,preferredUnlockMethod:preferredUnlockMethod)
            errorMessage=nil;checkIdle()
        } catch {errorMessage="锁定偏好未能保存：\(error.localizedDescription)"}
    }
    @discardableResult func setPreferredUnlockMethod(_ method:VaultUnlockMethod) -> Bool {
        guard isUnlocked,!busy,requireProtectedData() else {return false}
        guard method == .password || (biometricEnabled && biometricAvailable && biometrics.available) else {
            errorMessage=biometricUnavailableReason ?? "请先开启 Touch ID。"
            return false
        }
        do {
            try persistProtectionPreferences(idleMinutes:idleMinutes,biometricEnabled:biometricEnabled,preferredUnlockMethod:method)
            errorMessage=nil;recordActivity();return true
        } catch {errorMessage="默认解锁方式未能保存：\(error.localizedDescription)";return false}
    }
    @discardableResult func setPasswordHint(_ value:String?) -> Bool {
        guard isUnlocked,!busy,let salt,requireProtectedData() else {return false}
        do {
            guard !passwordHintsProtected else {throw VaultHintFailure.protected}
            try stagePasswordHint(try normalizedPasswordHint(value),for:salt)
            selectPasswordHint(for:salt);errorMessage=nil;recordActivity();return true
        } catch {errorMessage="密码提示未能保存：\(error.localizedDescription)";return false}
    }
    private func normalizedPasswordHint(_ value:String?) throws -> String? {
        guard let text=value?.trimmingCharacters(in:.whitespacesAndNewlines),!text.isEmpty else {return nil}
        guard text.count<=Self.maximumPasswordHintLength,text.utf8.count<=4096 else {throw VaultHintFailure.invalid}
        return text
    }
    private func loadPasswordHints() {
        guard FileManager.default.fileExists(atPath:passwordHintsURL.path) else {return}
        do {
            let handle=try FileHandle(forReadingFrom:passwordHintsURL)
            defer {try? handle.close()}
            let data=try handle.read(upToCount:32_769) ?? Data()
            guard data.count<=32_768 else {throw VaultFailure.invalidData}
            passwordHints=try JSONDecoder().decode(VaultPasswordHints.self,from:data).validated().records
        } catch {passwordHintsProtected=true;return}
        if let activeSalt=storedVaultSalt() {finishPasswordHintChange(for:activeSalt)}
    }
    private func storedVaultSalt() -> Data? {
        guard !passwordHints.isEmpty,let data=try? store.read() else {return nil}
        return (try? VaultCryptography.decodeEnvelope(data))?.salt
    }
    private func selectPasswordHint(for salt:Data?) {
        passwordHint=passwordHints.first{$0.salt == salt}?.text
    }
    private func writePasswordHints(_ records:[VaultPasswordHints.Record]) throws {
        guard records != passwordHints else {return}
        guard !passwordHintsProtected else {throw VaultHintFailure.protected}
        let settings=try VaultPasswordHints(records:records).validated()
        let data=try JSONEncoder().encode(settings)
        guard data.count<=32_768 else {throw VaultHintFailure.invalid}
        try ProtectedAtomicFile.write(data,to:passwordHintsURL)
        passwordHints=records
    }
    private func stagePasswordHint(_ hint:String?,for salt:Data,retaining previousSalt:Data?=nil) throws {
        if passwordHintsProtected && hint != nil {throw VaultHintFailure.protected}
        var records=passwordHints.filter{$0.salt == previousSalt && $0.salt != salt}
        if let hint {records.append(.init(salt:salt,text:hint))}
        try writePasswordHints(records)
    }
    private func finishPasswordHintChange(for salt:Data?) {
        selectPasswordHint(for:salt)
        // Only the active hint remains after a committed password change.
        try? writePasswordHints(passwordHints.filter{$0.salt == salt})
    }
    private func resetPasswordFailures() {
        failedPasswordAttempts=0;shouldRevealPasswordHint=false
    }
    private func requireProtectedData() -> Bool {
        guard protectedDataAvailable() else {
            lock(reason:"系统保护数据不可用，资料已锁定")
            errorMessage="系统保护数据不可用，请解锁这台 Mac 后再试。"
            return false
        }
        return true
    }

    func create(password:String,confirmation:String,hint:String?=nil) async -> Bool {
        guard !busy,!isUnlocked,!isConfigured else { return false }
        guard requireProtectedData() else { return false }
        guard password == confirmation else { errorMessage="两次输入的密码不一致。"; return false }
        busy=true; errorMessage=nil; generation += 1; let token=generation
        do {
            let hint=try normalizedPasswordHint(hint)
            let unlocked=try await Task.detached(priority:.userInitiated) { try VaultCryptography.create(contents:VaultContents(),password:password) }.value
            guard token == generation else { return false }
            guard requireProtectedData() else { return false }
            // Re-check immediately before creation so an externally created file is not replaced.
            guard !FileManager.default.fileExists(atPath:vaultDataURL.path) else { isConfigured=true; busy=false; errorMessage="资料库已经存在，请使用密码解锁。"; return false }
            try stagePasswordHint(hint,for:unlocked.envelope.salt)
            pendingEnvelope=unlocked.envelope; hasPendingSave=true
            guard flush() else { busy=false; isConfigured=true; return false }
            adopt(unlocked); sheet=nil; busy=false; return true
        } catch { if token == generation { busy=false; errorMessage=error.localizedDescription }; return false }
    }
    func unlock(password:String) async -> Bool {
        guard !busy,!isUnlocked,!password.isEmpty else { return false }
        guard requireProtectedData() else { return false }
        guard flush() else { return false }
        busy=true; errorMessage=nil; generation += 1; let token=generation
        do {
            let encrypted=try store.read()
            let unlocked=try await Task.detached(priority:.userInitiated) { try VaultCryptography.unlock(data:encrypted,password:password) }.value
            guard token == generation else { return false }
            guard requireProtectedData() else { return false }
            adopt(unlocked); busy=false; return true
        } catch {
            if token == generation {
                if error as? VaultFailure == .incorrectPassword {
                    failedPasswordAttempts=min(failedPasswordAttempts+1,Self.passwordHintFailureThreshold)
                    shouldRevealPasswordHint=failedPasswordAttempts == Self.passwordHintFailureThreshold && passwordHint != nil
                }
                busy=false;errorMessage=error.localizedDescription
            }
            return false
        }
    }
    private func adopt(_ unlocked:UnlockedVault) {
        key=unlocked.key; salt=unlocked.envelope.salt;openedPayloadVersion=unlocked.contents.version; documents=unlocked.contents.documents;categories=unlocked.contents.categories
        selectPasswordHint(for:unlocked.envelope.salt);resetPasswordFailures()
        categoryFilter="all";selectedID=documents.first?.id; isConfigured=true; isUnlocked=true; saveStatus="所有更改已保存"; lockReason=""
        errorMessage=nil; sessionID=UUID(); recordActivity()
    }
    /// A pending ciphertext always represents the latest accepted UI edit. No plaintext is needed to retry a failed write after locking.
    private func accept(_ next:[PrivateDocument],categories nextCategories:[VaultCategory]?=nil) -> Bool {
        guard isUnlocked,!busy,let key,let salt else { return false }
        do {
            let envelope=try VaultCryptography.seal(contents:VaultContents(documents:next,categories:nextCategories ?? categories),key:key,salt:salt)
            pendingEnvelope=envelope; hasPendingSave=true; documents=next; if let nextCategories {categories=nextCategories}; saveStatus="正在保存…"; errorMessage=nil; recordActivity()
            saveTask?.cancel()
            saveTask=Task { [weak self] in
                try? await Task.sleep(for:.milliseconds(450))
                guard !Task.isCancelled else { return }; _=self?.flush()
            }
            return true
        } catch { errorMessage="更改尚未应用：\(error.localizedDescription)"; return false }
    }
    func newDocument() {
        guard isUnlocked,!busy,flush() else {return}
        var next=documents,document=PrivateDocument(title:"")
        document.categoryID=categoryFilter == "all" ? "unclassified":categoryFilter
        next.insert(document,at:0)
        if accept(next) { selectedID=document.id }
    }
    func selectDocument(_ id:UUID) {
        guard isUnlocked,!busy,let document=documents.first(where:{$0.id == id}),flush() else {return}
        if categoryFilter != "all",document.effectiveCategoryID != categoryFilter {categoryFilter="all"}
        selectedID=id;recordActivity()
    }
    func visibleDocuments(matching query:String="")->[PrivateDocument] {
        documents.filter{(categoryFilter == "all" || $0.effectiveCategoryID == categoryFilter) && (query.isEmpty || $0.title.range(of:query,options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive]) != nil)}
    }
    /// Resolve the current encrypted save before changing either navigation
    /// value. An empty category deliberately has no editor selection.
    @discardableResult func selectCategory(_ id:String,matching query:String="")->Bool {
        guard isUnlocked,!busy,id == "all" || id == "unclassified" || categories.contains(where:{$0.id == id}),flush() else {return false}
        categoryFilter=id
        let visible=visibleDocuments(matching:query)
        if !visible.contains(where:{$0.id == selectedID}) {selectedID=visible.first?.id}
        recordActivity();return true
    }
    func updateTitle(_ title:String) { updateSelected { $0.title=title } }
    func updateBody(_ body:String) { updateSelected { $0.body=body;$0.formatting=nil } }
    func updateRichBody(_ body:String,formatting:[VaultTextStyleRun]) {updateSelected{$0.body=body;$0.formatting=formatting.isEmpty ? nil:formatting}}
    func categoryTitle(_ document:PrivateDocument)->String {categoryTitle(id:document.effectiveCategoryID)}
    func categoryTitle(id:String)->String {id == "unclassified" ? "未分类":categories.first{$0.id == id}?.name ?? "未分类"}
    var categoryOptions:[(String,String)] {[("unclassified","未分类")]+categories.map{($0.id,$0.name)}}
    func moveSelected(to categoryID:String) {
        guard categoryID == "unclassified" || categories.contains(where:{$0.id == categoryID}),
              let index=documents.firstIndex(where:{$0.id == selectedID}),flush() else {return}
        var next=documents;next[index].categoryID=categoryID;next[index].category = .unclassified;next[index].updatedAt=Date()
        if accept(next),categoryFilter != "all" {categoryFilter=categoryID}
    }
    @discardableResult func addCategory(_ name:String)->Bool {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard validCategoryName(name,excluding:nil),categories.count<100 else {errorMessage="分类名称不能重复，需为 1–30 个字；最多 100 个分类。";return false}
        return accept(documents,categories:categories+[VaultCategory(name:name)])
    }
    @discardableResult func renameCategory(_ id:String,to name:String)->Bool {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let index=categories.firstIndex(where:{$0.id == id}),validCategoryName(name,excluding:id) else {errorMessage="分类名称不能重复，需为 1–30 个字。";return false}
        var next=categories;next[index].name=name;return accept(documents,categories:next)
    }
    @discardableResult func deleteCategory(_ id:String,movingTo destination:String="unclassified")->Bool {
        guard id != destination,categories.contains(where:{$0.id == id}),destination == "unclassified" || categories.contains(where:{$0.id == destination}),flush() else {return false}
        var next=documents
        for index in next.indices where next[index].effectiveCategoryID == id {next[index].categoryID=destination;next[index].category = .unclassified;next[index].updatedAt=Date()}
        guard accept(next,categories:categories.filter{$0.id != id}) else {return false}
        if categoryFilter == id {categoryFilter=destination;if selectedDocument == nil {selectedID=visibleDocuments().first?.id}}
        return true
    }
    private func validCategoryName(_ value:String,excluding:String?)->Bool {
        !value.isEmpty && value.count<=30 && value.compare("未分类",options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive]) != .orderedSame && !categories.contains{$0.id != excluding && $0.name.compare(value,options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive]) == .orderedSame}
    }
    func updateCategory(_ value:PrivateDocumentCategory) {guard value == .unclassified || categories.contains(where:{$0.id == value.rawValue}) else {return};updateSelected{$0.category=value;$0.categoryID=nil}}
    private func updateSelected(_ mutation:(inout PrivateDocument)->Void) {
        guard let index=documents.firstIndex(where:{$0.id == selectedID}) else { return }
        var next=documents; mutation(&next[index]); next[index].updatedAt=Date(); _=accept(next)
    }
    func deleteDocument(_ id:UUID) -> Bool {
        let next=documents.filter{$0.id != id}
        guard accept(next) else { return false }
        if selectedID == id { selectedID=visibleDocuments().first?.id }
        return true
    }
    @discardableResult func flush() -> Bool {
        saveTask?.cancel(); saveTask=nil
        if store.isPendingPasswordChange {
            // A password transaction owns the disk until it has completed. An
            // ordinary retry must never recreate an old-password revision.
            guard pendingEnvelope == nil else {
                errorMessage="密码更改与待保存资料发生冲突，原加密资料已保留，请先完成密码更改。"
                return false
            }
            do {
                _=try store.recoverPasswordChange()
                finishPasswordHintChange(for:storedVaultSalt())
                hasPendingSave=false;isConfigured=true;saveStatus="所有更改已保存";errorMessage=nil
                lockReason="密码已更改，请使用新密码重新解锁"
                if isUnlocked {lock(reason:lockReason)}
            } catch {
                hasPendingSave=true;saveStatus="密码更改尚未完成"
                errorMessage="密码更改尚未完成，加密资料已保留。请重试保存，完成后使用新密码解锁。\n\(error.localizedDescription)"
                return false
            }
        }
        guard let pendingEnvelope else { return true }
        do {
            try store.write(pendingEnvelope); self.pendingEnvelope=nil; hasPendingSave=false;openedPayloadVersion=3
            selectPasswordHint(for:pendingEnvelope.salt)
            isConfigured=true; saveStatus="所有更改已保存"; errorMessage=nil; return true
        } catch {
            hasPendingSave=true; saveStatus="尚未写入磁盘"
            errorMessage="保存失败。最新更改已加密保留在内存中，请重试保存后再退出。\n\(error.localizedDescription)"
            return false
        }
    }
    func lock(reason:String) {
        let hadPrivateInput=isUnlocked || sheet != nil || !plaintextClearers.isEmpty
        generation += 1
        biometrics.cancel()
        clipboard.clearPrivateSession()
        _=flush()
        isUnlocked=false; busy=false; key=nil; salt=nil; documents=[];categories=[];categoryFilter="all"; selectedID=nil
        resetPasswordFailures()
        restoreData=nil; restorePreview=nil; restoreSourceName=nil; sheet=nil
        closeProtection()
        (panel as? NSSavePanel)?.cancel(nil); panel=nil
        let clearers=Array(plaintextClearers.values); plaintextClearers.removeAll()
        for clear in clearers { clear() }
        if hadPrivateInput {
            if let fieldEditor=hostWindow?.firstResponder as? NSTextView,fieldEditor.isFieldEditor { VaultPlaintextPrivacy.clear(fieldEditor) }
            hostWindow?.makeFirstResponder(nil); hostWindow?.undoManager?.removeAllActions()
        }
        sessionID=UUID(); lockReason=reason
    }
    func changePassword(current:String,new:String,confirmation:String,hint:String?=nil) async -> Bool {
        guard isUnlocked,!busy,!biometricOperationInFlight else { return false }
        guard requireProtectedData() else { return false }
        guard new == confirmation else { errorMessage="两次输入的新密码不一致。"; return false }
        guard flush() else { return false }
        busy=true; errorMessage=nil; generation += 1; let token=generation
        do {
            let hint=try normalizedPasswordHint(hint)
            let store=store
            let change=try await Task.detached(priority:.userInitiated) {
                try store.preparePasswordChange(currentPassword:current,newPassword:new)
            }.value
            guard token == generation,isUnlocked else { return false }
            guard requireProtectedData() else { return false }
            let newSalt=try change.replacementSalt()
            // The current hint remains available until the new envelope is
            // committed, including when the password journal needs recovery.
            try stagePasswordHint(hint,for:newSalt,retaining:salt)
            if biometricEnabled {try biometrics.removeSynchronously();try persistBiometricPreference(false)}
            _=try store.commitPasswordChange(change)
            finishPasswordHintChange(for:newSalt)
            lock(reason:"密码已更改，本机对应历史副本已更新，请重新解锁")
            return true
        } catch {
            if token == generation {
                if store.isPendingPasswordChange {
                    hasPendingSave=true
                    lock(reason:"密码更改尚未完成，请重试保存；完成后使用新密码")
                    // lock also retries encrypted writes. A transient error may
                    // already be resolved without retaining any plaintext.
                    if !store.isPendingPasswordChange {
                        lockReason="密码已更改，本机对应历史副本已更新，请重新解锁"
                        return true
                    }
                } else {busy=false;errorMessage=error.localizedDescription}
            }
            return false
        }
    }
    func refreshBiometrics() async {
        biometricUnavailableReason=await biometrics.refreshAvailability()
        biometricAvailable=biometrics.available && biometricUnavailableReason == nil
        biometricCanRemove=biometrics.canRemove
        // A protected item's metadata may itself require biometric interaction.
        // Passive refresh must not turn a no-interaction lookup failure into a
        // missing-key warning. Only the user's explicit readKey can validate it.
    }
    func enableBiometrics() async -> Bool {
        guard isUnlocked,!busy,!biometricOperationInFlight,let key,let salt,requireProtectedData(),flush() else {return false}
        guard biometrics.available else {setBiometricsUnavailable();return false}
        guard !protectionProtected else {errorMessage="锁定偏好无法读取，Touch ID 未启用。";return false}
        // Opt-in is an explicit protected-data write. Fence the released writer
        // before storing a biometric key, even if the user has not edited text.
        if openedPayloadVersion == 1 {guard accept(documents),flush() else {return false}}
        biometricOperationInFlight=true;defer{biometricOperationInFlight=false}
        busy=true;errorMessage=nil;generation += 1;let token=generation
        var enrolled=false
        var secret=key.withUnsafeBytes{Data($0)};defer{secret.resetBytes(in:0..<secret.count)}
        do {
            try await biometrics.enroll(key:secret,salt:salt);enrolled=true
            guard token == generation,isUnlocked else {try? await biometrics.remove();return false}
            guard requireProtectedData() else {try? await biometrics.remove();return false}
            try persistBiometricPreference(true)
            try? FileManager.default.removeItem(at:vaultDataURL.deletingLastPathComponent().appendingPathComponent(LegacyIdentityMigration.vaultNoticeName))
            identityBiometricSetupRequired=false
            biometricAvailable=biometrics.available;biometricCanRemove=biometrics.canRemove;busy=false;recordActivity();return true
        } catch {
            if enrolled {try? await biometrics.remove()}
            if token == generation {
                busy=false
                handleBiometricFailure(error)
            }
            return false
        }
    }
    private func persistProtectionPreferences(idleMinutes:Int,biometricEnabled:Bool,preferredUnlockMethod:VaultUnlockMethod) throws {
        guard !protectionProtected else {throw VaultFailure.invalidData}
        let next=try VaultProtectionPreferences(idleMinutes:idleMinutes,biometricEnabled:biometricEnabled,preferredUnlockMethod:preferredUnlockMethod).validated()
        try ProtectedAtomicFile.write(JSONEncoder().encode(next),to:protectionURL)
        self.idleMinutes=next.idleMinutes
        self.biometricEnabled=next.biometricEnabled
        self.preferredUnlockMethod=next.preferredUnlockMethod
    }
    private func persistBiometricPreference(_ enabled:Bool) throws {
        try persistProtectionPreferences(idleMinutes:idleMinutes,biometricEnabled:enabled,preferredUnlockMethod:.password)
    }
    @discardableResult func disableBiometrics() -> Bool {
        guard isUnlocked,!busy,!biometricOperationInFlight,biometricEnabled,requireProtectedData() else {return false}
        guard !protectionProtected else {errorMessage="锁定偏好无法读取，Touch ID 未停用。";return false}
        do {
            try biometrics.removeSynchronously()
            // Deleting the key is irreversible even if the preferences cannot be saved.
            biometricEnabled=false;preferredUnlockMethod = .password
            try persistBiometricPreference(false)
            errorMessage=nil;recordActivity();return true
        } catch {errorMessage=error.localizedDescription;return false}
    }
    /// Only explicit foreground navigation calls this. A capability check may
    /// suspend, so recheck the page and session before asking macOS to prompt.
    @discardableResult func unlockAutomaticallyOnEntry(isForeground: () -> Bool) async -> Bool {
        guard isConfigured,!isUnlocked,!busy,sheet == nil,biometricEnabled,
              preferredUnlockMethod == .touchID,isForeground() else {return false}
        let token=generation
        await refreshBiometrics()
        guard token == generation,!Task.isCancelled,sheet == nil,isForeground(),effectiveUnlockMethod == .touchID else {return false}
        return await unlockWithBiometrics()
    }
    func unlockWithBiometrics() async -> Bool {
        guard !busy,!isUnlocked,!biometricOperationInFlight,biometricEnabled,isConfigured,requireProtectedData(),flush() else {return false}
        guard biometrics.available else {setBiometricsUnavailable();return false}
        biometricOperationInFlight=true;defer{biometricOperationInFlight=false}
        busy=true;errorMessage=nil;generation += 1;let token=generation
        do {
            let data=try store.read(),envelope=try VaultCryptography.decodeEnvelope(data)
            var secret=try await biometrics.readKey(salt:envelope.salt);defer{secret.resetBytes(in:0..<secret.count)}
            guard token == generation,requireProtectedData() else {return false}
            let key=SymmetricKey(data:secret)
            let unlocked=try await Task.detached(priority:.userInitiated){try VaultCryptography.unlock(data:data,key:key)}.value
            guard token == generation,requireProtectedData() else {return false}
            adopt(unlocked);busy=false;return true
        } catch {
            if token == generation {
                busy=false
                handleBiometricFailure(error)
            }
            return false
        }
    }
    private func setBiometricsUnavailable(fallback:String?=nil) {
        biometricAvailable=false
        biometricUnavailableReason=biometrics.unavailableReason ?? fallback ?? VaultBiometricFailure.unavailable.localizedDescription
        errorMessage=nil
    }
    private func handleBiometricFailure(_ error:Error) {
        guard let failure=error as? VaultBiometricFailure else {errorMessage=error.localizedDescription;return}
        switch failure {
        case .cancelled:
            errorMessage=nil
        case .invalidated:
            try? biometrics.removeSynchronously()
            do {
                try persistBiometricPreference(false)
                errorMessage=failure.localizedDescription
            } catch {
                // The key is no longer usable even if saving its opt-out failed.
                biometricEnabled=false;preferredUnlockMethod = .password
                errorMessage="\(failure.localizedDescription)\n锁定偏好未能保存：\(error.localizedDescription)"
            }
        case .unavailable,.status:
            setBiometricsUnavailable(fallback:failure.localizedDescription)
        case .authenticationFailed:
            if biometrics.available {errorMessage=failure.localizedDescription}
            else {setBiometricsUnavailable(fallback:failure.localizedDescription)}
        }
    }
    func chooseBackupDestination() {
        guard isUnlocked,!busy,panel == nil,requireProtectedData(),flush(),isUnlocked else { return }
        let save=NSSavePanel(); save.title="导出加密备份"; save.nameFieldStringValue="DeskDen 私密备份-\(Date().formatted(.iso8601.year().month().day())).deskdenvault"
        save.allowedContentTypes=[UTType(filenameExtension:"deskdenvault") ?? .data]; save.canCreateDirectories=true; save.isExtensionHidden=false
        panel=save; recordActivity(); let token=generation
        let completion:@MainActor (NSApplication.ModalResponse)->Void = { [weak self,weak save] response in
            guard let self,let save,self.panel === save else { return }; self.panel=nil
            guard token == self.generation,response == .OK,let url=save.url else { return }
            self.exportBackup(to:url)
        }
        if let window=NSApp.keyWindow ?? hostWindow { save.beginSheetModal(for:window,completionHandler:completion) } else { save.begin(completionHandler:completion) }
    }
    @discardableResult func exportBackup(to url:URL) -> Bool {
        guard isUnlocked,!busy,requireProtectedData(),flush(),isUnlocked else { return false }
        do {
            guard url.standardizedFileURL != vaultDataURL.standardizedFileURL else { throw VaultFailure.invalidData }
            let data=try store.read(),scoped=url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try data.write(to:url,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            lastBackupPath=url.path; errorMessage=nil; recordActivity(); return true
        } catch { errorMessage="备份未完成：\(error.localizedDescription)"; return false }
    }
    private var canRestoreBackup:Bool {
        isUnlocked || (!isConfigured && !store.isPendingPasswordChange && !FileManager.default.fileExists(atPath:vaultDataURL.path))
    }
    func requestRestore() {
        guard canRestoreBackup,!busy,requireProtectedData() else {return}
        errorMessage=nil;sheet = .restore
    }
    func chooseRestoreSource() {
        guard canRestoreBackup,!busy,panel == nil,requireProtectedData() else { return }
        let open=NSOpenPanel(); open.title="选择 DeskDen 加密备份"; open.allowedContentTypes=[UTType(filenameExtension:"deskdenvault") ?? .data,UTType(filenameExtension:"fangcunvault") ?? .data]; open.allowsMultipleSelection=false; open.canChooseDirectories=false
        panel=open; let token=generation
        let completion:@MainActor (NSApplication.ModalResponse)->Void = { [weak self,weak open] response in
            guard let self,let open,self.panel === open else { return }; self.panel=nil
            guard token == self.generation,response == .OK,let url=open.url else { return }
            self.loadRestoreSource(url)
        }
        if let window=NSApp.keyWindow ?? hostWindow { open.beginSheetModal(for:window,completionHandler:completion) } else { open.begin(completionHandler:completion) }
    }
    @discardableResult func loadRestoreSource(_ url:URL) -> Bool {
        guard canRestoreBackup,!busy,requireProtectedData() else {return false}
        do {
            let scoped=url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data=try VaultFileStore(url:url).read()
            restoreData=data; restoreSourceName=url.lastPathComponent; restorePreview=nil; errorMessage=nil; recordActivity(); return true
        } catch { errorMessage="无法读取备份：\(error.localizedDescription)"; return false }
    }
    func verifyRestore(password:String) async -> Bool {
        guard canRestoreBackup,!busy else {return false}
        guard let data=restoreData else { errorMessage="请先选择一份加密备份。"; return false }
        guard requireProtectedData() else { return false }
        busy=true; errorMessage=nil; generation += 1; let token=generation; let name=restoreSourceName ?? "加密备份"
        do {
            let preview=try await Task.detached(priority:.userInitiated) { () -> (VaultEnvelope,Int) in
                let unlocked=try VaultCryptography.unlock(data:data,password:password)
                return (unlocked.envelope,unlocked.contents.documents.count)
            }.value
            guard token == generation else { return false }
            guard requireProtectedData() else { return false }
            guard canRestoreBackup else {lock(reason:"已有私密空间，请先解锁");return false}
            restorePreview=VaultRestorePreview(envelope:preview.0,count:preview.1,sourceName:name); busy=false; recordActivity(); return true
        } catch { if token == generation { busy=false; errorMessage=error.localizedDescription }; return false }
    }
    @discardableResult func confirmRestore() -> Bool {
        guard canRestoreBackup,!busy,!biometricOperationInFlight,let restorePreview,requireProtectedData(),flush(),canRestoreBackup else { return false }
        let previousHints=passwordHints
        let previousData=previousHints.isEmpty ? nil:try? store.read()
        do {
            if biometricEnabled {try biometrics.removeSynchronously();try persistBiometricPreference(false)}
            // Restoring a backup of this same vault may retain its salt, so
            // clear the local hint even when the cryptographic identity matches.
            try writePasswordHints([])
            selectPasswordHint(for:nil)
            let previous=try store.restore(restorePreview.envelope,replacingExisting:isUnlocked)
            lastPreservedPath=previous?.path; isConfigured=true; errorMessage=nil
            lock(reason:"备份已恢复，请使用这份备份的密码解锁"); return true
        } catch {
            if let previousData,(try? store.read()) == previousData {
                try? writePasswordHints(previousHints)
                selectPasswordHint(for:storedVaultSalt())
            }
            errorMessage="恢复未完成，原资料已保留：\(error.localizedDescription)"
            return false
        }
    }
    func cancelRestore() { generation += 1; busy=false; restoreData=nil; restoreSourceName=nil; restorePreview=nil; sheet=nil; errorMessage=nil }
}

/// Both the body editor and the host's private field editor use the same lock cleanup.
/// This clears visible/marked text and all native undo actions, rather than merely
/// disconnecting the SwiftUI binding while the text view still retains its contents.
@MainActor enum VaultPlaintextPrivacy {
    static func clear(_ editor:NSTextView) {
        editor.unmarkText(); editor.string=""; editor.setSelectedRange(NSRange(location:0,length:0))
        editor.undoManager?.removeAllActions()
    }
}

/// No password is saved. A vault-specific AES key is released only by the system's
/// biometric Keychain access control. Tests inject this boundary and never enroll.
@MainActor protocol VaultBiometricStore:AnyObject {
    var available:Bool {get}
    var canRemove:Bool {get}
    var unavailableReason:String? {get}
    func refreshAvailability() async -> String?
    func containsKey() async -> Bool
    func enroll(key:Data,salt:Data) async throws
    func readKey(salt:Data) async throws -> Data
    func remove() async throws
    func removeSynchronously() throws
    func cancel()
}

extension VaultBiometricStore {
    var canRemove:Bool {available}
    var unavailableReason:String? {available ? nil:"这台 Mac 当前无法使用 Touch ID。请继续使用私密空间密码。"}
    func refreshAvailability() async -> String? {unavailableReason}
}

/// This is only a preflight. Claims or an embedded file alone never establish
/// authorization: the system must also accept a read-only query for this exact
/// default access group before the UI offers biometric enrollment.
struct VaultBiometricSigningCapability:Equatable,Sendable {
    let accessGroup:String?
    let unavailableReason:String?
    static let missingAuthorization="当前构建未配置 Touch ID 所需的安全授权。请继续使用私密空间密码。"
    static func evaluate(bundleIdentifier:String?,applicationIdentifier:String?,teamIdentifier:String?,groups:[String]?,embeddedProfileExists:Bool,signatureValid:Bool)->Self {
        guard let bundleIdentifier,let applicationIdentifier,let teamIdentifier,
              !bundleIdentifier.isEmpty,teamIdentifier.range(of:"^[A-Z0-9]{10}$",options:.regularExpression) != nil,
              applicationIdentifier.hasSuffix("."+bundleIdentifier),
              let prefix=applicationIdentifier.split(separator:".").first,prefix.count == 10,
              prefix.allSatisfy({$0.isASCII && ($0.isUppercase || $0.isNumber)}),
              !applicationIdentifier.contains("*"),embeddedProfileExists,signatureValid,
              groups == nil || groups!.contains(applicationIdentifier) else {return Self(accessGroup:nil,unavailableReason:missingAuthorization)}
        return Self(accessGroup:applicationIdentifier,unavailableReason:nil)
    }
    static func currentApp()->Self {
        guard let task=SecTaskCreateFromSelf(nil) else {return Self(accessGroup:nil,unavailableReason:missingAuthorization)}
        let applicationIdentifier=SecTaskCopyValueForEntitlement(task,"com.apple.application-identifier" as CFString,nil) as? String
        let teamIdentifier=SecTaskCopyValueForEntitlement(task,"com.apple.developer.team-identifier" as CFString,nil) as? String
        let groups=SecTaskCopyValueForEntitlement(task,"keychain-access-groups" as CFString,nil) as? [String]
        if applicationIdentifier == nil || teamIdentifier == nil {
            return Self(accessGroup:nil,unavailableReason:"当前构建缺少 Touch ID 的应用签名授权，无法使用受保护钥匙串。独立密码仍可正常使用。")
        }
        let bundle=Bundle.main,profile=bundle.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        let attributes=try? FileManager.default.attributesOfItem(atPath:profile.path)
        let exists=attributes?[.type] as? FileAttributeType == .typeRegular && (attributes?[.size] as? NSNumber).map{(1...2_000_000).contains($0.intValue)} == true
        guard exists else {return Self(accessGroup:nil,unavailableReason:"当前构建未包含 Touch ID 所需的应用授权文件。请使用具备完整签名授权的版本；独立密码仍可使用。")}
        var valid=false
        if let teamIdentifier,let identifier=bundle.bundleIdentifier,
           teamIdentifier.range(of:"^[A-Z0-9]{10}$",options:.regularExpression) != nil,
           identifier.range(of:"^[A-Za-z0-9.-]+$",options:.regularExpression) != nil {
            var code:SecCode?,requirement:SecRequirement?
            let expression="anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(identifier)\""
            if SecCodeCopySelf([], &code) == errSecSuccess,let code,
               SecRequirementCreateWithString(expression as CFString,[],&requirement) == errSecSuccess,let requirement {valid=SecCodeCheckValidity(code,[],requirement) == errSecSuccess}
        }
        return evaluate(bundleIdentifier:bundle.bundleIdentifier,applicationIdentifier:applicationIdentifier,teamIdentifier:teamIdentifier,groups:groups,embeddedProfileExists:exists,signatureValid:valid)
    }
}

enum VaultBiometricFailure:LocalizedError {
    case unavailable,cancelled,authenticationFailed,invalidated,status(OSStatus)
    var errorDescription:String? {
        switch self {
        case .unavailable:"这台 Mac 当前无法使用 Touch ID。请使用私密空间密码解锁。"
        case .cancelled:"Touch ID 已取消。你仍可使用私密空间密码。"
        case .authenticationFailed:"Touch ID 验证未通过，请重试或使用私密空间密码。"
        case .invalidated:"Touch ID 授权已失效或资料库已变更。请用密码解锁后重新开启。"
        case .status(let status):status == errSecMissingEntitlement ? "当前构建缺少受保护钥匙串权限，Touch ID 未启用。请继续使用私密空间密码。":"Touch ID 暂不可用（\(status)）。请使用私密空间密码。"
        }
    }
}

@MainActor final class VaultKeychainBiometrics:VaultBiometricStore {
    private let account:String
    private let signing:VaultBiometricSigningCapability
    private var keychainAuthorized=false
    private var capabilityFailure:String?
    private var context:LAContext?
    init(vaultURL:URL,signing:VaultBiometricSigningCapability?=nil) {
        account=SHA256.hash(data:Data(vaultURL.standardizedFileURL.path.utf8)).map{String(format:"%02x",$0)}.joined()
        self.signing=signing ?? .currentApp()
    }
    private var hardwareUnavailableReason:String? {
        let context=LAContext();defer{context.invalidate()}
        var failure:NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,error:&failure),context.biometryType == .touchID {return nil}
        switch failure?.code {
        case LAError.biometryNotEnrolled.rawValue:return "尚未设置 Touch ID。请在系统设置中添加指纹，然后重新检测。"
        case LAError.biometryLockout.rawValue:return "Touch ID 已被系统暂时锁定。请先使用系统密码恢复，再重新检测。"
        case LAError.passcodeNotSet.rawValue:return "系统登录密码尚未设置，暂时无法使用 Touch ID。"
        default:return "这台 Mac 当前没有可用的 Touch ID。独立密码仍可正常使用。"
        }
    }
    private var hardwareAvailable:Bool {hardwareUnavailableReason == nil}
    var available:Bool {signing.accessGroup != nil && keychainAuthorized && hardwareAvailable}
    var canRemove:Bool {signing.accessGroup != nil && keychainAuthorized}
    var unavailableReason:String? {
        if let failure=signing.unavailableReason ?? capabilityFailure {return failure}
        if !keychainAuthorized {return "当前构建尚未通过 Touch ID 安全授权检查。请继续使用私密空间密码。"}
        return hardwareUnavailableReason
    }
    func refreshAvailability() async -> String? {
        guard let group=signing.accessGroup else {return signing.unavailableReason}
        // Querying a deliberately unused metadata account checks the system's
        // actual access-group authorization. No secret is added or retrieved,
        // and interactionNotAllowed prevents an authentication prompt.
        let status=await Task.detached(priority:.utility) {
            var query=Self.query("capability-metadata-probe-v1",group:group)
            let context=LAContext();context.interactionNotAllowed=true;defer{context.invalidate()}
            query[kSecUseAuthenticationContext as String]=context;query[kSecReturnAttributes as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary,nil)
        }.value
        keychainAuthorized=status == errSecSuccess || status == errSecItemNotFound
        capabilityFailure=keychainAuthorized ? nil:VaultBiometricSigningCapability.missingAuthorization
        return unavailableReason
    }
    nonisolated private static func query(_ account:String,group:String)->[String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.deskden.launcher.vault.biometric-key.v1",kSecAttrAccount as String:account,kSecAttrAccessGroup as String:group,kSecUseDataProtectionKeychain as String:true,kSecAttrSynchronizable as String:false]
    }
    func containsKey() async -> Bool {
        guard available,let group=signing.accessGroup else {return false}
        let account=account
        return await Task.detached(priority:.utility) {
            var query=Self.query(account,group:group);let context=LAContext();context.interactionNotAllowed=true;defer{context.invalidate()}
            query[kSecUseAuthenticationContext as String]=context;query[kSecReturnAttributes as String]=true
            return SecItemCopyMatching(query as CFDictionary,nil) == errSecSuccess
        }.value
    }
    func enroll(key:Data,salt:Data) async throws {
        guard available,let group=signing.accessGroup,key.count == 32,salt.count == 16 else {throw VaultBiometricFailure.unavailable}
        let context=LAContext();context.localizedFallbackTitle="";context.touchIDAuthenticationAllowableReuseDuration=0;self.context=context
        defer{context.invalidate();if self.context === context {self.context=nil}}
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,localizedReason:"为私密空间开启 Touch ID 解锁") else {throw VaultBiometricFailure.authenticationFailed}
        } catch let error as LAError {
            switch error.code {
            case .userCancel,.systemCancel,.appCancel,.userFallback:throw VaultBiometricFailure.cancelled
            case .biometryLockout,.biometryNotAvailable,.biometryNotEnrolled,.passcodeNotSet:throw VaultBiometricFailure.unavailable
            default:throw VaultBiometricFailure.authenticationFailed
            }
        }
        guard self.context === context else {throw VaultBiometricFailure.cancelled}
        let account=account
        try await Task.detached(priority:.userInitiated) {
            guard let access=SecAccessControlCreateWithFlags(nil,kSecAttrAccessibleWhenUnlockedThisDeviceOnly,.biometryCurrentSet,nil) else {throw VaultBiometricFailure.unavailable}
            var payload=Data(salt);payload.append(key);defer{payload.resetBytes(in:0..<payload.count)}
            var query=Self.query(account,group:group);query[kSecAttrAccessControl as String]=access;query[kSecValueData as String]=payload;query[kSecAttrLabel as String]="DeskDen 私密空间 Touch ID"
            let deletion=Self.delete(account,group:group);guard deletion == errSecSuccess || deletion == errSecItemNotFound else {throw VaultBiometricFailure.status(deletion)}
            let status=SecItemAdd(query as CFDictionary,nil);guard status == errSecSuccess else {throw VaultBiometricFailure.status(status)}
        }.value
    }
    func readKey(salt:Data) async throws -> Data {
        guard available,let group=signing.accessGroup else {throw VaultBiometricFailure.unavailable}
        let context=LAContext();context.localizedFallbackTitle="";context.localizedReason="解锁 DeskDen 私密空间";context.touchIDAuthenticationAllowableReuseDuration=0;self.context=context
        defer{context.invalidate();if self.context === context {self.context=nil}}
        let account=account,handle=VaultAuthenticationContext(context)
        let payload=try await Task.detached(priority:.userInitiated) {
            var query=Self.query(account,group:group);query[kSecUseAuthenticationContext as String]=handle.value;query[kSecReturnData as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne
            var result:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&result)
            guard status == errSecSuccess,let data=result as? Data else {
                if status == errSecUserCanceled {throw VaultBiometricFailure.cancelled}
                if status == errSecAuthFailed {throw VaultBiometricFailure.authenticationFailed}
                if status == errSecItemNotFound {throw VaultBiometricFailure.invalidated}
                throw VaultBiometricFailure.status(status)
            }
            return data
        }.value
        var secret=payload;defer{secret.resetBytes(in:0..<secret.count)}
        guard self.context === context else {throw VaultBiometricFailure.cancelled}
        guard secret.count == 48,secret.prefix(16) == salt else {throw VaultBiometricFailure.invalidated}
        return Data(secret.suffix(32))
    }
    nonisolated private static func delete(_ account:String,group:String)->OSStatus {
        var query=query(account,group:group);let context=LAContext();context.interactionNotAllowed=true;defer{context.invalidate()};query[kSecUseAuthenticationContext as String]=context
        return SecItemDelete(query as CFDictionary)
    }
    func remove() async throws {
        guard let group=signing.accessGroup else {throw VaultBiometricFailure.status(errSecMissingEntitlement)}
        let account=account;let status=await Task.detached{Self.delete(account,group:group)}.value
        guard status == errSecSuccess || status == errSecItemNotFound else {throw VaultBiometricFailure.status(status)}
    }
    func removeSynchronously() throws {
        guard let group=signing.accessGroup else {throw VaultBiometricFailure.status(errSecMissingEntitlement)}
        let status=Self.delete(account,group:group);guard status == errSecSuccess || status == errSecItemNotFound else {throw VaultBiometricFailure.status(status)}
    }
    func cancel() {context?.invalidate();context=nil}
}

/// LAContext's supported invalidation cancels an in-flight Keychain operation.
/// This wrapper crosses only that system API boundary; no mutable app state is shared.
private final class VaultAuthenticationContext:@unchecked Sendable {
    let value:LAContext
    init(_ value:LAContext) {self.value=value}
}

/// Keeps only ownership metadata, never a second copy of the private text.
/// A later clipboard write always takes precedence over our cleanup deadline.
@MainActor final class VaultClipboard {
    typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void)
    static let retention:TimeInterval=180
    static let concealedType=NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType=NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let ownerType=NSPasteboard.PasteboardType("local.deskden.vault.clipboard-owner")
    static let shared=VaultClipboard(pasteboard:.general)
    let pasteboard:NSPasteboard
    private let schedule:Scheduler
    private var ownedChangeCount:Int?
    private var ownedToken:String?
    private var generation=0
    private var cancelCleanup:(()->Void)?
    private var fieldEditor:VaultClipboardTextView?
    private func privateFieldEditor()->VaultClipboardTextView {
        if let fieldEditor {return fieldEditor}
        let editor=VaultClipboardTextView()
        editor.clipboard=self;editor.isFieldEditor=true;editor.isRichText=false;editor.importsGraphics=false
        fieldEditor=editor
        return editor
    }

    init(pasteboard:NSPasteboard,schedule:Scheduler?=nil) {
        self.pasteboard=pasteboard
        self.schedule=schedule ?? { delay,action in
            let task=Task { @MainActor in
                try? await Task.sleep(for:.seconds(delay))
                guard !Task.isCancelled else {return}
                action()
            }
            return {task.cancel()}
        }
    }
    isolated deinit {cancelCleanup?()}

    /// Secure fields keep AppKit's secure editor and its copy restrictions.
    static func privateFieldEditor(for client:Any?)->NSTextView? {
        guard client is NSTextField,!(client is NSSecureTextField) else {return nil}
        return shared.privateFieldEditor()
    }

    @discardableResult func publishSelection(from source:NSPasteboard)->Bool {
        let token=UUID().uuidString
        let items=(source.pasteboardItems ?? []).map { original in
            let item=NSPasteboardItem()
            for type in original.types {if let data=original.data(forType:type) {item.setData(data,forType:type)}}
            item.setData(Data(),forType:Self.concealedType)
            item.setData(Data(),forType:Self.transientType)
            item.setString(token,forType:Self.ownerType)
            return item
        }
        guard !items.isEmpty else {return false}
        generation += 1;let currentGeneration=generation
        cancelCleanup?();cancelCleanup=nil;ownedChangeCount=nil;ownedToken=nil
        // Prepare the actual destination before publishing any representations,
        // so the plaintext is never first written with cross-device availability.
        pasteboard.prepareForNewContents(with:.currentHostOnly)
        guard pasteboard.writeObjects(items) else {pasteboard.clearContents();return false}
        ownedChangeCount=pasteboard.changeCount;ownedToken=token
        cancelCleanup=schedule(Self.retention) { [weak self] in
            guard let self,self.generation == currentGeneration else {return}
            self.clearOwnedContents()
        }
        return true
    }

    func clearOwnedContents() {
        generation += 1;cancelCleanup?();cancelCleanup=nil
        defer {ownedChangeCount=nil;ownedToken=nil}
        guard let count=ownedChangeCount,let token=ownedToken,
              pasteboard.changeCount == count,pasteboard.string(forType:Self.ownerType) == token else {return}
        pasteboard.clearContents()
    }

    /// Locking clears the cached native editor even after it stopped being the
    /// window's first responder. Clipboard expiry must not alter active edits.
    func clearPrivateSession() {
        clearOwnedContents()
        if let fieldEditor {
            fieldEditor.unmarkText();fieldEditor.string=""
            fieldEditor.setSelectedRange(NSRange(location:0,length:0))
            fieldEditor.undoManager?.removeAllActions()
        }
    }
}

/// Shared by the rich body editor and the private page's native field editor.
/// AppKit creates all native text representations on an isolated pasteboard;
/// only the fully marked, device-local result reaches the user's clipboard.
@MainActor class VaultClipboardTextView:NSTextView {
    var clipboard=VaultClipboard.shared
    override func copy(_ sender:Any?) {_=copyPrivateSelection()}
    override func cut(_ sender:Any?) {
        guard isEditable,copyPrivateSelection() else {return}
        delete(sender)
    }
    @discardableResult func copyPrivateSelection()->Bool {
        guard selectedRanges.contains(where:{$0.rangeValue.length>0}) else {return false}
        let staging=NSPasteboard.withUniqueName()
        defer {staging.clearContents();staging.releaseGlobally()}
        guard super.writeSelection(to:staging,types:writablePasteboardTypes) else {return false}
        return clipboard.publishSelection(from:staging)
    }
}
