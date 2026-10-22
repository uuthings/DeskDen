import AppKit
import Combine
import CryptoKit
import Foundation
import LauncherCore
import UniformTypeIdentifiers

enum VaultSheet:String,Identifiable { case setup,unlockForPassword,password,backup,restore; var id:String { rawValue } }
struct VaultRestorePreview:Identifiable {
    let id=UUID()
    let envelope:VaultEnvelope
    let count:Int
    let sourceName:String
}

@MainActor final class VaultModel:ObservableObject {
    @Published private(set) var isUnlocked=false
    @Published private(set) var isConfigured=false
    @Published private(set) var busy=false
    @Published private(set) var documents:[PrivateDocument] = []
    @Published private(set) var selectedID:UUID?
    @Published private(set) var saveStatus="所有更改已保存"
    @Published private(set) var lockReason=""
    @Published private(set) var sessionID=UUID()
    @Published private(set) var hasPendingSave=false
    @Published var errorMessage:String?
    @Published var sheet:VaultSheet?
    @Published var showingProtection=false
    @Published var protectionFromSettings=false
    @Published private(set) var idleMinutes=5
    @Published var restorePreview:VaultRestorePreview?
    @Published private(set) var restoreSourceName:String?
    @Published private(set) var lastBackupPath:String?
    @Published private(set) var lastPreservedPath:String?
    let vaultDataURL:URL
    private let store:VaultFileStore
    private let protectionURL:URL
    private var protectionProtected=false
    private var key:SymmetricKey?
    private var salt:Data?
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

    init(dataDirectory:URL,protectedDataAvailable:@escaping ()->Bool = { NSApp.isProtectedDataAvailable }) {
        vaultDataURL=dataDirectory.appendingPathComponent("private.fangcunvault")
        store=VaultFileStore(url:vaultDataURL)
        protectionURL=dataDirectory.appendingPathComponent("protection.json")
        self.protectedDataAvailable=protectedDataAvailable
        isConfigured=FileManager.default.fileExists(atPath:vaultDataURL.path)
        if FileManager.default.fileExists(atPath:protectionURL.path) {
            do {
                let handle=try FileHandle(forReadingFrom:protectionURL);defer{try? handle.close()}
                let data=try handle.read(upToCount:16_385) ?? Data()
                guard data.count <= 16_384 else {throw VaultFailure.invalidData}
                idleMinutes=try JSONDecoder().decode(VaultProtectionPreferences.self,from:data).validated().idleMinutes
            } catch {protectionProtected=true;errorMessage="锁定偏好无法读取，原文件已保留；当前按 5 分钟自动锁定。"}
        }
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
    var completionMessage:String? { !isUnlocked && (lockReason.hasPrefix("密码已更改") || lockReason.hasPrefix("备份已恢复")) ? lockReason:nil }
    var canChangeProtectionPreferences:Bool { !protectionProtected }
    func recordActivity() { lastActivityUptime=ProcessInfo.processInfo.systemUptime }
    func registerPlaintextClearer(id:UUID,_ clear:@escaping ()->Void) { plaintextClearers[id]=clear }
    func removePlaintextClearer(id:UUID) { plaintextClearers.removeValue(forKey:id) }
    func checkIdle(uptime:TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if isUnlocked && uptime-lastActivityUptime >= Double(idleMinutes)*60 { lock(reason:"已闲置 \(idleMinutes) 分钟，资料已锁定") }
    }
    func showProtection(fromSettings:Bool=false) {protectionFromSettings=fromSettings;showingProtection=true;recordActivity()}
    func requestPasswordChange() {
        guard isConfigured,!busy else { return }
        errorMessage=nil; sheet=isUnlocked ? .password:.unlockForPassword
    }
    func closeSheet() {
        guard !busy else { return }
        if sheet == .restore { cancelRestore() }
        else { sheet=nil; errorMessage=nil }
    }
    func changeIdleMinutes(_ value:Int) {
        guard !protectionProtected else {errorMessage="锁定偏好无法读取，当前未覆盖原文件。";return}
        do {
            let next=try VaultProtectionPreferences(idleMinutes:value).validated()
            try ProtectedAtomicFile.write(JSONEncoder().encode(next),to:protectionURL)
            idleMinutes=value;errorMessage=nil;checkIdle()
        } catch {errorMessage="锁定偏好未能保存：\(error.localizedDescription)"}
    }
    private func requireProtectedData() -> Bool {
        guard protectedDataAvailable() else {
            lock(reason:"系统保护数据不可用，资料已锁定")
            errorMessage="系统保护数据不可用，请解锁这台 Mac 后再试。"
            return false
        }
        return true
    }

    func create(password:String,confirmation:String) async -> Bool {
        guard !busy,!isUnlocked,!isConfigured else { return false }
        guard requireProtectedData() else { return false }
        guard password == confirmation else { errorMessage="两次输入的密码不一致。"; return false }
        busy=true; errorMessage=nil; generation += 1; let token=generation
        do {
            let unlocked=try await Task.detached(priority:.userInitiated) { try VaultCryptography.create(contents:VaultContents(),password:password) }.value
            guard token == generation else { return false }
            guard requireProtectedData() else { return false }
            // Re-check immediately before creation so an externally created file is not replaced.
            guard !FileManager.default.fileExists(atPath:vaultDataURL.path) else { isConfigured=true; busy=false; errorMessage="资料库已经存在，请使用密码解锁。"; return false }
            pendingEnvelope=unlocked.envelope; hasPendingSave=true
            guard flush() else { busy=false; isConfigured=true; return false }
            adopt(unlocked); sheet=nil; busy=false; return true
        } catch { if token == generation { busy=false; errorMessage=error.localizedDescription }; return false }
    }
    func unlock(password:String) async -> Bool {
        guard !busy,!isUnlocked else { return false }
        guard requireProtectedData() else { return false }
        guard flush() else { return false }
        busy=true; errorMessage=nil; generation += 1; let token=generation
        do {
            let encrypted=try store.read()
            let unlocked=try await Task.detached(priority:.userInitiated) { try VaultCryptography.unlock(data:encrypted,password:password) }.value
            guard token == generation else { return false }
            guard requireProtectedData() else { return false }
            adopt(unlocked); busy=false; return true
        } catch { if token == generation { busy=false; errorMessage=error.localizedDescription }; return false }
    }
    private func adopt(_ unlocked:UnlockedVault) {
        key=unlocked.key; salt=unlocked.envelope.salt; documents=unlocked.contents.documents
        selectedID=documents.first?.id; isConfigured=true; isUnlocked=true; saveStatus="所有更改已保存"; lockReason=""
        errorMessage=nil; sessionID=UUID(); recordActivity()
    }
    /// A pending ciphertext always represents the latest accepted UI edit. No plaintext is needed to retry a failed write after locking.
    private func accept(_ next:[PrivateDocument]) -> Bool {
        guard isUnlocked,!busy,let key,let salt else { return false }
        do {
            let envelope=try VaultCryptography.seal(contents:VaultContents(documents:next),key:key,salt:salt)
            pendingEnvelope=envelope; hasPendingSave=true; documents=next; saveStatus="正在保存…"; errorMessage=nil; recordActivity()
            saveTask?.cancel()
            saveTask=Task { [weak self] in
                try? await Task.sleep(for:.milliseconds(450))
                guard !Task.isCancelled else { return }; _=self?.flush()
            }
            return true
        } catch { errorMessage="更改尚未应用：\(error.localizedDescription)"; return false }
    }
    func newDocument() {
        var next=documents; let document=PrivateDocument(title:""); next.insert(document,at:0)
        if accept(next) { selectedID=document.id }
    }
    func selectDocument(_ id:UUID) { guard isUnlocked,documents.contains(where:{$0.id == id}) else { return }; selectedID=id; recordActivity() }
    func updateTitle(_ title:String) { updateSelected { $0.title=title } }
    func updateBody(_ body:String) { updateSelected { $0.body=body } }
    func updateCategory(_ value:PrivateDocumentCategory) {updateSelected{$0.category=value}}
    private func updateSelected(_ mutation:(inout PrivateDocument)->Void) {
        guard let index=documents.firstIndex(where:{$0.id == selectedID}) else { return }
        var next=documents; mutation(&next[index]); next[index].updatedAt=Date(); _=accept(next)
    }
    func deleteDocument(_ id:UUID) -> Bool {
        let next=documents.filter{$0.id != id}
        guard accept(next) else { return false }
        if selectedID == id { selectedID=next.first?.id }
        return true
    }
    @discardableResult func flush() -> Bool {
        saveTask?.cancel(); saveTask=nil
        guard let pendingEnvelope else { return true }
        do {
            try store.write(pendingEnvelope); self.pendingEnvelope=nil; hasPendingSave=false
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
        _=flush()
        isUnlocked=false; busy=false; key=nil; salt=nil; documents=[]; selectedID=nil
        restoreData=nil; restorePreview=nil; restoreSourceName=nil; sheet=nil
        (panel as? NSSavePanel)?.cancel(nil); panel=nil
        let clearers=Array(plaintextClearers.values); plaintextClearers.removeAll()
        for clear in clearers { clear() }
        if hadPrivateInput {
            if let fieldEditor=hostWindow?.firstResponder as? NSTextView,fieldEditor.isFieldEditor { VaultPlaintextPrivacy.clear(fieldEditor) }
            hostWindow?.makeFirstResponder(nil); hostWindow?.undoManager?.removeAllActions()
        }
        sessionID=UUID(); lockReason=reason
    }
    func changePassword(current:String,new:String,confirmation:String) async -> Bool {
        guard isUnlocked,!busy else { return false }
        guard requireProtectedData() else { return false }
        guard new == confirmation else { errorMessage="两次输入的新密码不一致。"; return false }
        guard flush() else { return false }
        busy=true; errorMessage=nil; generation += 1; let token=generation
        do {
            let data=try store.read(),contents=VaultContents(documents:documents)
            let changed=try await Task.detached(priority:.userInitiated) {
                _=try VaultCryptography.unlock(data:data,password:current)
                return try VaultCryptography.create(contents:contents,password:new)
            }.value
            guard token == generation,isUnlocked else { return false }
            guard requireProtectedData() else { return false }
            pendingEnvelope=changed.envelope; hasPendingSave=true
            let saved=flush()
            lock(reason:saved ? "密码已更改，请重新解锁":"新密码资料尚未写入磁盘，请重试保存；保存后使用新密码")
            return saved
        } catch { if token == generation { busy=false; errorMessage=error.localizedDescription }; return false }
    }
    func chooseBackupDestination() {
        guard isConfigured,!busy,flush() else { return }
        let save=NSSavePanel(); save.title="导出加密备份"; save.nameFieldStringValue="方寸私密备份-\(Date().formatted(.iso8601.year().month().day())).fangcunvault"
        save.allowedContentTypes=[UTType(filenameExtension:"fangcunvault") ?? .data]; save.canCreateDirectories=true; save.isExtensionHidden=false
        panel=save; recordActivity(); let token=generation
        let completion:@MainActor (NSApplication.ModalResponse)->Void = { [weak self,weak save] response in
            guard let self else { return }; self.panel=nil
            guard token == self.generation,self.isConfigured,response == .OK,let url=save?.url else { return }
            self.exportBackup(to:url)
        }
        if let window=NSApp.keyWindow ?? hostWindow { save.beginSheetModal(for:window,completionHandler:completion) } else { save.begin(completionHandler:completion) }
    }
    @discardableResult func exportBackup(to url:URL) -> Bool {
        guard isConfigured,!busy,flush() else { return false }
        do {
            guard url.standardizedFileURL != vaultDataURL.standardizedFileURL else { throw VaultFailure.invalidData }
            let data=try store.read(),scoped=url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try data.write(to:url,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            lastBackupPath=url.path; errorMessage=nil; recordActivity(); return true
        } catch { errorMessage="备份未完成：\(error.localizedDescription)"; return false }
    }
    func chooseRestoreSource() {
        guard !busy else { return }
        let open=NSOpenPanel(); open.title="选择方寸加密备份"; open.allowedContentTypes=[UTType(filenameExtension:"fangcunvault") ?? .data]; open.allowsMultipleSelection=false; open.canChooseDirectories=false
        panel=open; let token=generation
        let completion:@MainActor (NSApplication.ModalResponse)->Void = { [weak self,weak open] response in
            guard let self else { return }; self.panel=nil
            guard token == self.generation,response == .OK,let url=open?.url else { return }
            self.loadRestoreSource(url)
        }
        if let window=NSApp.keyWindow ?? hostWindow { open.beginSheetModal(for:window,completionHandler:completion) } else { open.begin(completionHandler:completion) }
    }
    @discardableResult func loadRestoreSource(_ url:URL) -> Bool {
        do {
            let scoped=url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data=try VaultFileStore(url:url).read()
            restoreData=data; restoreSourceName=url.lastPathComponent; restorePreview=nil; errorMessage=nil; recordActivity(); return true
        } catch { errorMessage="无法读取备份：\(error.localizedDescription)"; return false }
    }
    func verifyRestore(password:String) async -> Bool {
        guard !busy,let data=restoreData else { errorMessage="请先选择一份加密备份。"; return false }
        guard requireProtectedData() else { return false }
        busy=true; errorMessage=nil; generation += 1; let token=generation; let name=restoreSourceName ?? "加密备份"
        do {
            let preview=try await Task.detached(priority:.userInitiated) { () -> (VaultEnvelope,Int) in
                let unlocked=try VaultCryptography.unlock(data:data,password:password)
                return (unlocked.envelope,unlocked.contents.documents.count)
            }.value
            guard token == generation else { return false }
            guard requireProtectedData() else { return false }
            restorePreview=VaultRestorePreview(envelope:preview.0,count:preview.1,sourceName:name); busy=false; recordActivity(); return true
        } catch { if token == generation { busy=false; errorMessage=error.localizedDescription }; return false }
    }
    @discardableResult func confirmRestore() -> Bool {
        guard !busy,let restorePreview,flush() else { return false }
        guard requireProtectedData() else { return false }
        do {
            let previous=try store.restore(restorePreview.envelope)
            lastPreservedPath=previous?.path; isConfigured=true; errorMessage=nil
            lock(reason:"备份已恢复，请使用这份备份的密码解锁"); return true
        } catch { errorMessage="恢复未完成，原资料已保留：\(error.localizedDescription)"; return false }
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
