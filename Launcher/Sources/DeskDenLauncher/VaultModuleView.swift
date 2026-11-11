import AppKit
import SwiftUI
import LauncherCore

/// Places the lock card 42% down the free height, slightly above center.
private enum VaultLockCardAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context.height * 0.42 }
}
private extension VerticalAlignment { static let vaultLockCard = VerticalAlignment(VaultLockCardAlignment.self) }

struct VaultModuleView:View {
    @ObservedObject var model:VaultModel
    var returnToSettingsPrivacy:(()->Void)?=nil
    @State private var windowHeight:CGFloat=758
    @StateObject private var hintClose = WorkbenchDraftCloseCoordinator()
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchModals) private var modals
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            if model.showingProtection {
                // The way back sits before the title (现行规范 4.1, D7).
                VaultProtectionPage(model:model,back:WBPageBack(title:model.protectionFromSettings ? "隐私与锁定":"私密空间",identifier:"vault-protection-back",escapes:true) {
                    model.showingProtection=false;if model.protectionFromSettings {returnToSettingsPrivacy?()}
                })
            } else {
                WBPageHeader(title:"私密空间",subtitle:model.isUnlocked ? "\(model.documents.count) 条文本 · 仅保存在此设备":"独立密码保护，仅在需要时解锁") {
                    Button{model.showProtection()}label:{Label("保护与备份",systemImage:"checkmark.shield")}.buttonStyle(WBButtonStyle())
                    if model.isUnlocked {
                        Button{model.lock(reason:"已手动锁定")}label:{Label("锁定",systemImage:"lock")}.buttonStyle(WBButtonStyle())
                        Button{model.newDocument()}label:{Label("新建",systemImage:"plus")}.buttonStyle(WBButtonStyle(primary:true))
                    }
                }
                if model.hasPendingSave && !model.isUnlocked {
                    HStack(alignment:.top,spacing:10){Image(systemName:"exclamationmark.triangle").foregroundStyle(palette.warning);Text(model.hasPendingPasswordChange ? "密码更改尚未完成，加密资料已保留。请重试完成，之后使用新密码解锁。":"最新更改已加密保留，尚未写入磁盘。请重试保存后再退出。");Spacer();Button(model.hasPendingPasswordChange ? "重试完成":"重试保存"){model.flush()}.buttonStyle(WBButtonStyle(primary:true))}.font(.system(size:12)).padding(14).background(WorkbenchMaterialSurface(radius:10)).padding(.bottom,12)
                }
                if model.isUnlocked {VaultUnlockedView(model:model,panelHeight:max(480,min(720,windowHeight-183))).id(model.sessionID)}
                // A compact card in the unlocked panel's area, 42% down its free
                // height, wallpaper around it (现行规范 9.3, V1).
                else {VaultLockedView(model:model).id(model.sessionID).frame(width:400).background(WorkbenchMaterialSurface(radius:15))
                    .frame(maxWidth:.infinity,minHeight:max(320,windowHeight-183),alignment:Alignment(horizontal:.center,vertical:.vaultLockCard))}
            }
        }.foregroundStyle(palette.text)
        .background(VaultWindowReader(found:{model.hostWindow=$0},resized:{windowHeight=$0}).frame(width:0,height:0))
        .onChange(of:model.sessionID){_,_ in modals?.prune()}
        .workbenchModal(item: $model.sheet, onDismiss: {
            hintClose.continueEditing()
            if model.restorePreview != nil || model.restoreSourceName != nil { model.cancelRestore() }
        }, onRequestDismiss: {
            if model.sheet == .passwordHint { hintClose.requestClose() }
            else { model.closeSheet() }
        }) { sheet in
            switch sheet {
            case .setup:VaultSetupSheet(model:model)
            case .unlockForPassword:VaultPasswordUnlockSheet(model:model)
            case .password:VaultPasswordSheet(model:model)
            case .passwordHint: VaultPasswordHintSheet(model: model, close: hintClose)
            case .touchIDDefault: VaultTouchIDDefaultSheet(model: model)
            case .backup:VaultBackupSheet(model:model)
            case .restore:VaultRestoreSheet(model:model)
            }
        }.accessibilityElement(children:.contain).accessibilityIdentifier(model.showingProtection ? "fc.page.vault.protection":"fc.page.vault")
    }
}

private struct VaultProtectionPage:View {
    @ObservedObject var model:VaultModel
    let back:WBPageBack
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchToast) private var toast
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            WBPageHeader(title:"保护与备份",subtitle:"设置锁定规则，保留可恢复的加密备份",back:back)
            VStack(alignment:.leading,spacing:12) {
                // Setting rows (现行规范 4.5, G1); the three fixed rules share one row (V4).
                WBCard(title:"访问保护",symbol:"checkmark.shield",spacing:0) {
                    WBSettingRow(title:"独立密码",subtitle:model.isUnlocked ? "新密码至少需要 \(VaultCryptography.minimumPasswordLength) 个字符":"先验证解锁，再继续修改密码",showsDivider:false) {
                        Button("修改密码",action:model.requestPasswordChange).buttonStyle(WBButtonStyle(compact:true)).disabled(!model.isConfigured || model.busy)
                    }
                    WBSettingRow(title:"Touch ID",subtitle:model.biometricUnavailableReason ?? (model.biometricEnabled ? "仅此设备；变更指纹或密码后需重新开启":"先用独立密码解锁，再为此资料库开启")) {
                        if !model.biometricAvailable {
                            Button("重新检测") { Task { await model.refreshBiometrics() } }
                                .buttonStyle(WBButtonStyle(compact:true)).disabled(model.busy)
                        } else if model.biometricEnabled && model.biometricCanRemove {
                            Button("停用") { Task { _ = await model.disableBiometrics() } }
                                .buttonStyle(WBButtonStyle(compact:true)).disabled(model.busy)
                        } else {
                            Button("开启 Touch ID", action: enableTouchID)
                                .buttonStyle(WBButtonStyle(compact:true))
                                .disabled(!model.isUnlocked || model.busy || !model.canChangeProtectionPreferences)
                        }
                    }
                    WBSettingRow(title: "默认解锁方式", subtitle: unlockMethodNote) {
                        WBSelect("默认解锁方式", selection: Binding(
                            get: { model.preferredUnlockMethod },
                            set: { method in
                                guard method != model.preferredUnlockMethod, model.setPreferredUnlockMethod(method) else { return }
                                toast("已更新默认解锁方式")
                            }
                        ), options: unlockMethods)
                        .frame(width: 120)
                        .disabled(!model.isUnlocked || model.busy || !model.canChangeProtectionPreferences || unlockMethods.count < 2)
                    }
                    WBSettingRow(title: "密码提示", subtitle: hintNote) {
                        Button(model.passwordHint == nil ? "设置提示" : "编辑提示") {
                            model.errorMessage = nil
                            model.sheet = .passwordHint
                        }
                        .buttonStyle(WBButtonStyle(compact: true))
                        .disabled(!model.isUnlocked || model.busy)
                    }
                    WBSettingRow(title:"闲置自动锁定",subtitle:"没有操作时自动收起内容") {
                        WBSelect("闲置自动锁定",selection:Binding(get:{model.idleMinutes},set:model.changeIdleMinutes),options:[1,5,10].map{($0,"\($0) 分钟")}).frame(width:120).disabled(!model.canChangeProtectionPreferences)
                    }
                    WBSettingRow(title:"始终生效的保护",subtitle:"离开私密页或收起工作台时锁定；睡眠或切换用户后需重新验证；复制的内容 3 分钟后或锁定时清除") {
                        WBStatusPill(title:"始终开启")
                    }
                    if model.sheet == nil, let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11))
                            .foregroundStyle(palette.critical)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    }
                }
                WBCard(title:"本机备份",symbol:"archivebox",spacing:0) {
                    WBSettingRow(title:"导出加密备份",subtitle:"包含资料与必要的恢复信息",showsDivider:false) {
                        Button("导出"){model.errorMessage=nil;model.sheet = .backup}.buttonStyle(WBButtonStyle(compact:true)).disabled(!model.isConfigured || model.busy)
                    }
                    WBSettingRow(title:"恢复备份",subtitle:"使用备份文件和导出时的密码") {
                        Button("选择备份"){model.errorMessage=nil;model.sheet = .restore}.buttonStyle(WBButtonStyle(compact:true)).disabled(model.busy)
                    }
                }
                WBPageNote {Text("确认恢复后，方寸会先保留当前资料的加密副本，再替换为这份备份。").fixedSize(horizontal:false,vertical:true)}
            }
        }.task {await model.refreshBiometrics()}
            // A finished restore or password change is a one-off result (现行规范 4.8, G3).
            .onChange(of:model.completionMessage) {_,message in if let message {toast(message)}}
    }

    private var unlockMethods: [(value: VaultUnlockMethod, title: String)] {
        var methods: [(VaultUnlockMethod, String)] = [(.password, "密码")]
        if (model.biometricEnabled && model.biometricAvailable) || model.preferredUnlockMethod == .touchID {
            methods.append((.touchID, "Touch ID"))
        }
        return methods
    }

    private var unlockMethodNote: String {
        if !model.isUnlocked { return "解锁后可更改默认方式" }
        if !model.biometricEnabled { return "开启 Touch ID 后可选择" }
        return "进入私密空间时优先显示所选方式"
    }

    private var hintNote: String {
        guard model.isUnlocked else { return "解锁后可设置密码提示" }
        return model.passwordHint == nil ? "未设置 · 选填" : "已设置 · 锁定时可查看"
    }

    private func enableTouchID() {
        Task {
            guard await model.enableBiometrics(), model.isUnlocked, model.showingProtection,
                  model.sheet == nil else { return }
            model.sheet = .touchIDDefault
        }
    }
}

private struct VaultWindowReader:NSViewRepresentable {
    let found:(NSWindow?)->Void
    let resized:(CGFloat)->Void
    func makeNSView(context:Context) -> NSView { let view=Reader(); view.found=found; view.resized=resized; return view }
    func updateNSView(_ nsView:NSView,context:Context) { if let view=nsView as? Reader { view.found=found; view.resized=resized } }
    private final class Reader:NSView {
        var found:((NSWindow?)->Void)?
        var resized:((CGFloat)->Void)?
        private var resizeObserver:NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver=nil
            found?(window)
            guard let window else { return }
            resized?(window.frame.height)
            resizeObserver=NotificationCenter.default.addObserver(forName:NSWindow.didResizeNotification,object:window,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { if let window=self?.window { self?.resized?(window.frame.height) } }
            }
        }
        isolated deinit { if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) } }
    }
}

private struct VaultLockedView:View {
    @ObservedObject var model:VaultModel
    @State private var password=""
    @State private var showPasswordHint = false
    @State private var usingPasswordInstead = false
    @FocusState private var focused:Bool
    @Environment(\.workbenchPalette) private var palette

    private var showsPassword: Bool {
        model.isConfigured && (usingPasswordInstead || model.effectiveUnlockMethod == .password)
    }

    var body:some View {
        VStack(spacing:0) {
            Image(systemName:"lock").font(.system(size:30,weight:.light)).foregroundStyle(palette.secondary).frame(height:36).padding(.bottom,12)
            Text(model.isConfigured ? "资料已锁定":"建立你的私密空间").font(.system(size:15,weight:.medium)).padding(.bottom,8)
            Text(model.isConfigured ? "你的内容留在这台 Mac 上。\n离开此页面后会自动锁定。":"用一个独立密码，保护只属于你的文字。").font(.system(size:12)).foregroundStyle(palette.secondary).multilineTextAlignment(.center).lineSpacing(5)
            // The form is 280 wide inside the 400-point card (V1).
            VStack(spacing:0) {
                if showsPassword {
                    passwordForm
                } else if model.isConfigured {
                    unlockButton("使用 Touch ID 解锁", symbol: "touchid", action: unlockWithTouchID)
                        .disabled(model.busy).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("fc.vault.lock.touchID")
                    Button("改用密码") { usingPasswordInstead = true }
                        .buttonStyle(WBQuietButtonStyle()).disabled(model.busy).padding(.top, 8)
                        .accessibilityIdentifier("fc.vault.lock.usePassword")
                } else {
                    Button{model.errorMessage=nil;model.sheet = .setup}label:{Label("设置独立密码",systemImage:"key").frame(maxWidth:.infinity)}.buttonStyle(WBButtonStyle(primary:true))
                }
            }.frame(width:280).padding(.top, 20)
            if let error=model.errorMessage {Text(error).font(.system(size:11)).foregroundStyle(palette.critical).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).padding(.top,10)}
            if let message=model.completionMessage {Text(message).font(.system(size:11)).foregroundStyle(palette.success).multilineTextAlignment(.center).lineLimit(nil).fixedSize(horizontal:false,vertical:true).padding(.top,10)}
        }.frame(maxWidth:.infinity).fixedSize(horizontal:false,vertical:true).padding(.horizontal,24).padding(.top,28).padding(.bottom,24)
        .onChange(of: showsPassword, initial: true) { _, visible in focused = visible }
        .onChange(of: model.shouldRevealPasswordHint, initial: true) { _, reveal in
            if reveal { showPasswordHint = true }
        }
        .task { await model.refreshBiometrics() }
        .modifier(VaultSensitiveState(model:model,clear:{
            password = ""
            showPasswordHint = false
            usingPasswordInstead = false
        }))
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                SecureField("输入私密空间密码", text: $password)
                    .focused($focused).onSubmit(unlock).accessibilityIdentifier("fc.vault.lock.password")
                    .onChange(of: password) { _, value in
                        if !value.isEmpty { usingPasswordInstead = true }
                    }
                if model.passwordHint != nil {
                    Button {
                        showPasswordHint.toggle()
                        focused = true
                    } label: { Image(systemName: "questionmark.circle") }
                        .buttonStyle(WBIconButtonStyle())
                        .help("密码提示")
                        .accessibilityLabel("密码提示")
                        .accessibilityValue(showPasswordHint ? "已显示" : "已隐藏")
                        .accessibilityIdentifier("fc.vault.lock.hintButton")
                }
            }
            .modifier(VaultInputStyle()).disabled(model.busy)
            if showPasswordHint, let hint = model.passwordHint {
                Text("提示：\(hint)")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fc.vault.lock.hint")
            }
            if model.biometricEnabled, !model.biometricAvailable, let reason = model.biometricUnavailableReason {
                Text(reason).font(.system(size:11)).foregroundStyle(palette.muted)
                    .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("fc.vault.lock.biometric-reason")
            }
            unlockButton("解锁", symbol: "lock.open", action: unlock)
                .disabled(model.busy || password.isEmpty)
            if model.biometricEnabled && model.biometricAvailable {
                Button("使用 Touch ID", action: unlockWithTouchID)
                    .buttonStyle(WBQuietButtonStyle()).disabled(model.busy)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("fc.vault.lock.touchID")
            }
        }
    }

    private func unlockButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if model.busy { ProgressView().controlSize(.small) }
                else { Label(title, systemImage: symbol) }
            }.frame(maxWidth: .infinity)
        }.buttonStyle(WBButtonStyle(primary: true))
    }

    private func unlock() {
        guard !password.isEmpty, !model.busy else { return }
        let value = password
        password = ""
        Task {
            if !(await model.unlock(password: value)), showsPassword { focused = true }
        }
    }

    private func unlockWithTouchID() {
        guard !model.busy else { return }
        password = ""
        Task { _ = await model.unlockWithBiometrics() }
    }
}

private struct VaultDeletionTarget:Identifiable {let id:UUID;let title:String}

private struct VaultUnlockedView:View {
    @ObservedObject var model:VaultModel
    @StateObject private var formatting=VaultEditorFormatting()
    @State private var deletion:VaultDeletionTarget?
    @State private var query=""
    @State private var showCategories=false
    @State private var categoryName=""
    @State private var editingCategoryID:String?
    @State private var categoryDeletion:VaultCategory?
    @State private var moveDestination="unclassified"
    @Environment(\.workbenchPalette) private var palette
    var panelHeight:CGFloat=575
    private var filtered:[PrivateDocument] {model.visibleDocuments(matching:query)}
    var body:some View {
        VStack(spacing:12) {
            HStack(alignment:.top,spacing:12) {
                sidebar.frame(maxHeight:.infinity).padding(14).frame(width:244).background(WorkbenchMaterialSurface(radius:15))
                editor.frame(maxWidth:.infinity,maxHeight:.infinity).padding(14).background(WorkbenchMaterialSurface(radius:15))
            }.frame(height:panelHeight)
        }
        .workbenchModal(item:$deletion){document in WorkbenchDialogFrame(title:"删除这条私密文本？",dismiss:{deletion=nil}){
            Text("「\(document.title.isEmpty ? "未命名文本":document.title)」删除后无法撤销，可从此前的加密备份恢复。").font(.system(size:12)).foregroundStyle(palette.secondary)
        }actions:{Spacer();Button("取消"){deletion=nil}.buttonStyle(WBButtonStyle());Button("删除"){_ = model.deleteDocument(document.id);deletion=nil}.buttonStyle(WBButtonStyle(destructive:true))}}
        .workbenchModal(isPresented:$showCategories){categoryManager}
        .workbenchModal(item:$categoryDeletion){category in WorkbenchDialogFrame(title:"删除分类「\(category.name)」？",dismiss:{categoryDeletion=nil}){
            VStack(alignment:.leading,spacing:12){Text("分类中的 \(model.documents.filter{$0.effectiveCategoryID == category.id}.count) 条文本会移到下方分类，文本内容不会删除。").font(.system(size:12)).foregroundStyle(palette.secondary);WBSelect("移到分类",selection:$moveDestination,options:model.categoryOptions.filter{$0.0 != category.id})}
        }actions:{Spacer();Button("取消"){categoryDeletion=nil}.buttonStyle(WBButtonStyle());Button("删除分类并移动文本"){if model.deleteCategory(category.id,movingTo:moveDestination){categoryDeletion=nil}}.buttonStyle(WBButtonStyle(destructive:true))}}
        .onChange(of:model.selectedID){_,_ in
            deletion=nil
            if let document=model.selectedDocument,!query.isEmpty,document.title.range(of:query,options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive]) == nil {query=""}
        }
        .onChange(of:model.categories.map(\.id)){_,ids in
            if let id=editingCategoryID,!ids.contains(id) {editingCategoryID=nil;categoryName=""}
            if let category=categoryDeletion,!ids.contains(category.id) {categoryDeletion=nil}
        }
        .modifier(VaultSensitiveState(model:model,clear:{query="";deletion=nil;showCategories=false;categoryName="";editingCategoryID=nil;categoryDeletion=nil;formatting.detach()}))
    }
    private var sidebar:some View {
        VStack(spacing:12) {
            HStack(spacing:7){Image(systemName:"magnifyingglass").foregroundStyle(palette.muted);TextField("搜索标题",text:$query).textFieldStyle(.plain)}.modifier(WBFieldSurface())
            HStack(spacing:6){
                WBSelect("筛选分类",selection:Binding(get:{model.categoryFilter},set:{_ = model.selectCategory($0,matching:query)}),options:[("all","全部分类")]+model.categoryOptions)
                Button{categoryName="";editingCategoryID=nil;showCategories=true;model.recordActivity()}label:{Label("管理分类",systemImage:"folder.badge.gearshape")}
                    .buttonStyle(WBButtonStyle()).help("新增、重命名或删除分类").accessibilityIdentifier("fc.vault.categories.manage")
            }
            WorkbenchScrollView {
                LazyVStack(spacing:2) {
                    ForEach(filtered){document in
                        // A 52-point row: title, then category and date-time on one line (现行规范 4.5, 5.3).
                        Button{model.selectDocument(document.id)}label:{VStack(alignment:.leading,spacing:3){
                            Text(document.title.isEmpty ? "未命名文本":document.title).font(.system(size:13,weight:.medium)).foregroundStyle(palette.text).lineLimit(1)
                            Text(model.categoryTitle(document)+" · "+WorkbenchDateText.fullWithTime(document.updatedAt,calendar:.current)).font(.system(size:11)).foregroundStyle(palette.muted).lineLimit(1)
                        }.padding(.horizontal,10).frame(maxWidth:.infinity,minHeight:52,maxHeight:52,alignment:.leading).background(model.selectedID == document.id ? palette.navSelected:.clear,in:RoundedRectangle(cornerRadius:8))}.buttonStyle(WBSelectableButtonStyle(selected: model.selectedID == document.id, cornerRadius: 8, drawsSelection: false, showsBorder: false))
                    }
                    if filtered.isEmpty {Text(query.isEmpty ? "此分类暂无文本":"没有匹配的标题").font(.system(size:11)).foregroundStyle(palette.muted).padding(.vertical,20)}
                }
            }
        }
    }
    private var categoryManager:some View {
        WorkbenchDialogFrame(title:"管理分类",dismiss:{showCategories=false;categoryName="";editingCategoryID=nil}){
            VStack(alignment:.leading,spacing:14){
                Text("分类与文本一起加密保存。「未分类」始终保留；删除其他分类时可先选择文本去向。").font(.system(size:12)).foregroundStyle(palette.secondary)
                WorkbenchScrollView {VStack(spacing:4){ForEach(model.categories){category in
                    HStack(spacing:10){VStack(alignment:.leading,spacing:3){Text(category.name).font(.system(size:13,weight:.medium));Text("\(model.documents.filter{$0.effectiveCategoryID == category.id}.count) 条文本").font(.system(size:11)).foregroundStyle(palette.muted)};Spacer();Button{editingCategoryID=category.id;categoryName=category.name}label:{Image(systemName:"pencil")}.buttonStyle(WBIconButtonStyle(size:28)).accessibilityLabel("重命名 \(category.name)");Button{moveDestination="unclassified";categoryDeletion=category}label:{Image(systemName:"trash")}.buttonStyle(WBIconButtonStyle(size:28,danger:true)).accessibilityLabel("删除分类 \(category.name)")}.frame(height:52)
                }}}.frame(maxHeight:240)
                VStack(alignment:.leading,spacing:6){Text(editingCategoryID == nil ? "新增分类":"重命名分类").font(.system(size:12));HStack(spacing:10){TextField("1–30 个字",text:$categoryName).modifier(VaultInputStyle());Button(editingCategoryID == nil ? "新增":"保存"){let saved=editingCategoryID.map{model.renameCategory($0,to:categoryName)} ?? model.addCategory(categoryName);if saved {categoryName="";editingCategoryID=nil}}.buttonStyle(WBButtonStyle(primary:true)).disabled(categoryName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty);if editingCategoryID != nil {Button("取消"){categoryName="";editingCategoryID=nil}.buttonStyle(WBButtonStyle())}}}
                VaultSheetError(model:model)
            }.disabled(model.busy)
        }actions:{Spacer();Button("完成"){showCategories=false;categoryName="";editingCategoryID=nil}.buttonStyle(WBButtonStyle(primary:true))}
    }
    @ViewBuilder private var editor:some View {
        if let document=model.selectedDocument {
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:8){TextField("未命名文本",text:Binding(get:{model.selectedDocument?.title ?? ""},set:model.updateTitle)).textFieldStyle(.plain).font(.system(size:17,weight:.medium)).frame(height:32);Button{deletion=VaultDeletionTarget(id:document.id,title:document.title);model.recordActivity()}label:{Image(systemName:"trash")}.buttonStyle(WBIconButtonStyle(size:28,danger:true)).accessibilityLabel("删除文本")}
                HStack(spacing:10){Text("分类").font(.system(size:11)).foregroundStyle(palette.muted);WBSelect("文本分类",selection:Binding(get:{model.selectedDocument?.effectiveCategoryID ?? "unclassified"},set:model.moveSelected),options:model.categoryOptions).frame(width:164);Spacer()}.padding(.top,10).padding(.bottom,10)
                VaultFormattingToolbar(controller:formatting).disabled(model.busy).padding(.bottom,10)
                VaultPrivateTextEditor(model:model,document:document,formatting:formatting).disabled(model.busy).id(document.id)
                // Only a failed save is a warning; saving in progress is quiet (V2, G3).
                HStack(spacing:8){
                    if let error=model.errorMessage {
                        Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(palette.critical).lineLimit(1).help(error)
                        if model.hasPendingSave {Button("重试保存"){model.flush()}.buttonStyle(WBButtonStyle(compact:true))}
                    } else {Text(model.saveStatus)}
                    Spacer();Text("\(document.body.count) 字")
                }.font(.system(size:11)).foregroundStyle(palette.muted).padding(.top,8)
            }
        } else {
            VStack(spacing:14){
                Text(!query.isEmpty ? "没有匹配的标题":model.categoryFilter == "all" ? "新建你的第一条文本":"「\(model.categoryTitle(id:model.categoryFilter))」暂无文本")
                    .font(.system(size:12)).foregroundStyle(palette.muted)
                Button{model.newDocument()}label:{Label("新建文本",systemImage:"plus")}.buttonStyle(WBButtonStyle(primary:true))
                Button("管理分类"){categoryName="";editingCategoryID=nil;showCategories=true;model.recordActivity()}.buttonStyle(WBQuietButtonStyle())
                if let error=model.errorMessage {Text(error).font(.system(size:11)).foregroundStyle(palette.critical).multilineTextAlignment(.center)}
            }.frame(maxWidth:.infinity,maxHeight:.infinity).accessibilityIdentifier("fc.vault.category.empty")
        }
    }
}

/// One row without a boxed backing, a hairline below (现行规范 9.3, V3):
/// font and size | bold, italic, underline, strikethrough | text color and
/// highlight | clear formatting. A narrow editor folds the last two groups
/// into "更多".
private struct VaultFormattingToolbar:View {
    @ObservedObject var controller:VaultEditorFormatting
    @Environment(\.workbenchPalette) private var palette
    @State private var textColorOpen=false
    @State private var highlightOpen=false
    @State private var moreOpen=false
    var body:some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:6){fontControls;divider;formatControls;divider;colorControls;divider;clearButton;Spacer(minLength:0)}
            HStack(spacing:6){fontControls;divider;formatControls;divider;moreButton;Spacer(minLength:0)}
        }.frame(height:32).padding(.bottom,8).overlay(alignment:.bottom){palette.line.frame(height:1)}
            .accessibilityElement(children:.contain).accessibilityIdentifier("fc.vault.editor.toolbar")
    }
    private var divider:some View {Rectangle().fill(palette.line).frame(width:1,height:18).padding(.horizontal,2)}
    private var fontControls:some View {
        Group {
            WBSelect("字体",selection:Binding(get:{controller.family},set:controller.setFamily),options:VaultEditorFormatting.availableFamilies.map{($0,VaultEditorFormatting.familyTitle($0))}).frame(width:132)
            WBSelect("字号",selection:Binding(get:{controller.size},set:controller.setSize),options:[10.0,12,14,16,18,20,22,24,26,28].map{($0,"\(Int($0))")}).frame(width:66)
        }
    }
    private var formatControls:some View {
        Group {
            formatButton("加粗",symbol:"bold",selected:controller.bold){controller.toggle(.boldFontMask)}
            formatButton("斜体",symbol:"italic",selected:controller.italic){controller.toggle(.italicFontMask)}
            formatButton("下划线",symbol:"underline",selected:controller.underline){controller.toggleUnderline()}
            formatButton("删除线",symbol:"strikethrough",selected:controller.strikethrough){controller.toggleStrikethrough()}
        }
    }
    private var colorControls:some View {
        Group {
            colorButton("文字颜色",glyph:AnyView(Text("A").font(.system(size:14,weight:.medium))),swatch:VaultFormattingToolbar.swatch(controller.textColor,automatic:palette.text),isOpen:$textColorOpen) {textColorChoices{textColorOpen=false}}
            colorButton("高亮",glyph:AnyView(Image(systemName:"highlighter").font(.system(size:14))),swatch:VaultEditorFormatting.highlight(controller.highlightColor).map{Color(nsColor:$0)},isOpen:$highlightOpen) {highlightChoices{highlightOpen=false}}
        }
    }
    private var clearButton:some View {
        Button(action:controller.clearFormatting){Image(systemName:"eraser").frame(width:16,height:16)}.buttonStyle(WBIconButtonStyle(size:28)).help("清除格式").accessibilityLabel("清除格式")
    }
    private var moreButton:some View {
        Button{moreOpen.toggle()}label:{Image(systemName:"ellipsis").frame(width:16,height:16)}.buttonStyle(WBIconButtonStyle(size:28)).help("更多格式").accessibilityLabel("更多格式")
            .workbenchPopover(isPresented:$moreOpen,width:180) {
                VStack(alignment:.leading,spacing:6) {
                    Text("文字颜色").font(.system(size:11)).foregroundStyle(palette.muted).padding(.horizontal,10)
                    textColorChoices{moreOpen=false}
                    Text("高亮").font(.system(size:11)).foregroundStyle(palette.muted).padding(.horizontal,10)
                    highlightChoices{moreOpen=false}
                    palette.line.frame(height:1)
                    choice("清除格式",swatch:nil,selected:false){controller.clearFormatting();moreOpen=false}
                }.padding(6)
            }
    }
    private func textColorChoices(close:@escaping ()->Void)->some View {
        VStack(alignment:.leading,spacing:2) {
            ForEach(VaultTextColor.allCases,id:\.self) {value in
                choice(VaultEditorFormatting.textColorTitle(value),swatch:VaultFormattingToolbar.swatch(value,automatic:palette.text),selected:controller.textColor == value) {controller.setTextColor(value);close()}
            }
        }
    }
    private func highlightChoices(close:@escaping ()->Void)->some View {
        VStack(alignment:.leading,spacing:2) {
            ForEach(VaultHighlightColor.allCases,id:\.self) {value in
                choice(VaultEditorFormatting.highlightTitle(value),swatch:VaultEditorFormatting.highlight(value).map{Color(nsColor:$0)},selected:controller.highlightColor == value) {controller.setHighlightColor(value);close()}
            }
        }
    }
    private func choice(_ title:String,swatch:Color?,selected:Bool,action:@escaping ()->Void)->some View {
        Button(action:action){
            HStack(spacing:8) {
                if let swatch {Circle().fill(swatch).frame(width:10,height:10)} else {Circle().strokeBorder(palette.controlBorder,lineWidth:1).frame(width:10,height:10)}
                Text(title).font(.system(size:12)).foregroundStyle(palette.text)
                Spacer(minLength:0)
                if selected {Image(systemName:"checkmark").font(.system(size:11,weight:.medium)).foregroundStyle(palette.accent)}
            }.padding(.horizontal,10).frame(height:28).contentShape(Rectangle())
        }.buttonStyle(WBSelectableButtonStyle(cornerRadius:7,drawsSelection:false,showsBorder:false))
    }
    /// A color dropdown shows its current color as a bar under the glyph.
    private func colorButton<Content:View>(_ title:String,glyph:AnyView,swatch:Color?,isOpen:Binding<Bool>,@ViewBuilder content:@escaping ()->Content)->some View {
        Button{isOpen.wrappedValue.toggle()}label:{
            HStack(spacing:3) {
                VStack(spacing:1) {
                    glyph.frame(width:18,height:16)
                    RoundedRectangle(cornerRadius:1.5).fill(swatch ?? .clear)
                        .overlay(RoundedRectangle(cornerRadius:1.5).strokeBorder(palette.controlBorder,lineWidth:swatch == nil ? 1:0))
                        .frame(width:16,height:3)
                }
                Image(systemName:"chevron.down").font(.system(size:9,weight:.medium))
            }.foregroundStyle(palette.secondary).padding(.horizontal,6).frame(height:28).contentShape(Rectangle())
        }.buttonStyle(WBSelectableButtonStyle(cornerRadius:7,drawsSelection:false,showsBorder:false)).help(title).accessibilityLabel(title)
            .workbenchPopover(isPresented:isOpen,width:150) {content().padding(6)}
    }
    static func swatch(_ value:VaultTextColor,automatic:Color)->Color {value == .automatic ? automatic:Color(nsColor:VaultEditorFormatting.color(value,automatic:.textColor))}
    private func formatButton(_ title:String,symbol:String,selected:Bool,action:@escaping ()->Void)->some View {Button(action:action){Image(systemName:symbol).frame(width:16,height:16)}.buttonStyle(WBIconButtonStyle(size:28)).background(selected ? palette.navSelected:.clear,in:RoundedRectangle(cornerRadius:7)).help(title).accessibilityLabel(title).accessibilityValue(selected ? "已开启":"未开启")}
}

@MainActor final class VaultEditorFormatting:ObservableObject {
    @Published private(set) var family:VaultFontFamily = .system
    @Published private(set) var size:Double=14
    @Published private(set) var bold=false
    @Published private(set) var italic=false
    @Published private(set) var underline=false
    @Published private(set) var strikethrough=false
    @Published private(set) var textColor:VaultTextColor = .automatic
    @Published private(set) var highlightColor:VaultHighlightColor = .none
    weak var editor:NSTextView?
    var automaticTextColor:NSColor = .textColor
    static let familyKey=NSAttributedString.Key("DeskDenVaultFontFamily")
    static let boldKey=NSAttributedString.Key("DeskDenVaultBold")
    static let italicKey=NSAttributedString.Key("DeskDenVaultItalic")
    static let textColorKey=NSAttributedString.Key("DeskDenVaultTextColor")
    static let highlightKey=NSAttributedString.Key("DeskDenVaultHighlightColor")
    static var availableFamilies:[VaultFontFamily] {VaultFontFamily.allCases.filter{family in family == .system || family == .monospaced || fontNames(family).contains{NSFont(name:$0,size:14) != nil}}}
    static func familyTitle(_ family:VaultFontFamily)->String {
        switch family {case .system:"系统字体";case .serif:"宋体";case .monospaced:"系统等宽";case .pingFang:"苹方";case .kaiti:"楷体";case .heiti:"黑体";case .helvetica:"Helvetica Neue";case .georgia:"Georgia";case .menlo:"Menlo"}
    }
    private static func fontNames(_ family:VaultFontFamily)->[String] {
        switch family {case .system,.monospaced:[];case .serif:["Songti SC"];case .pingFang:["PingFang SC"];case .kaiti:["Kaiti SC","STKaiti"];case .heiti:["Heiti SC","STHeitiSC-Light"];case .helvetica:["Helvetica Neue"];case .georgia:["Georgia"];case .menlo:["Menlo"]}
    }
    static func textColorTitle(_ value:VaultTextColor)->String {switch value {case .automatic:"自动";case .red:"红色";case .orange:"橙色";case .green:"绿色";case .blue:"蓝色";case .purple:"紫色";case .gray:"灰色"}}
    static func highlightTitle(_ value:VaultHighlightColor)->String {switch value {case .none:"无高亮";case .yellow:"黄色";case .green:"绿色";case .blue:"蓝色";case .pink:"粉色";case .purple:"紫色"}}
    static func color(_ value:VaultTextColor,automatic:NSColor)->NSColor {
        switch value {case .automatic:automatic;case .red:NSColor(srgbRed:0.85,green:0.22,blue:0.25,alpha:1);case .orange:NSColor(srgbRed:0.80,green:0.39,blue:0.10,alpha:1);case .green:NSColor(srgbRed:0.19,green:0.62,blue:0.37,alpha:1);case .blue:NSColor(srgbRed:0.25,green:0.52,blue:0.92,alpha:1);case .purple:NSColor(srgbRed:0.62,green:0.39,blue:0.83,alpha:1);case .gray:NSColor(srgbRed:0.55,green:0.57,blue:0.60,alpha:1)}
    }
    static func highlight(_ value:VaultHighlightColor)->NSColor? {
        switch value {case .none:nil;case .yellow:NSColor(srgbRed:0.95,green:0.78,blue:0.22,alpha:0.35);case .green:NSColor(srgbRed:0.30,green:0.74,blue:0.47,alpha:0.3);case .blue:NSColor(srgbRed:0.30,green:0.59,blue:0.92,alpha:0.3);case .pink:NSColor(srgbRed:0.90,green:0.40,blue:0.58,alpha:0.3);case .purple:NSColor(srgbRed:0.65,green:0.44,blue:0.88,alpha:0.3)}
    }
    private static func traits(_ attributes:[NSAttributedString.Key:Any])->(Bool,Bool) {let font=attributes[.font] as? NSFont ?? Self.font(family:.system,size:14);let traits=NSFontManager.shared.traits(of:font);return (attributes[boldKey] as? Bool ?? traits.contains(.boldFontMask),attributes[italicKey] as? Bool ?? traits.contains(.italicFontMask))}
    static func applyFont(to attributes:inout [NSAttributedString.Key:Any],family:VaultFontFamily,size:Double,bold:Bool,italic:Bool) {
        let font=font(family:family,size:size,bold:bold,italic:italic),traits=NSFontManager.shared.traits(of:font)
        attributes[.font]=font;attributes[familyKey]=family.rawValue;attributes[boldKey]=bold;attributes[italicKey]=italic
        attributes[.obliqueness]=italic && !traits.contains(.italicFontMask) ? 0.16:0
        attributes[.strokeWidth]=bold && !traits.contains(.boldFontMask) ? -2.0:0
    }
    static func font(family:VaultFontFamily,size:Double,bold:Bool=false,italic:Bool=false)->NSFont {
        let base:NSFont
        if family == .monospaced {base=NSFont.monospacedSystemFont(ofSize:size,weight:.regular)}
        else {base=fontNames(family).compactMap{NSFont(name:$0,size:size)}.first ?? NSFont.systemFont(ofSize:size)}
        var traits:NSFontTraitMask=[];if bold {traits.insert(.boldFontMask)};if italic {traits.insert(.italicFontMask)}
        return NSFontManager.shared.convert(base,toHaveTrait:traits)
    }
    static func paragraph()->NSParagraphStyle {let style=NSMutableParagraphStyle();style.lineSpacing=3;style.paragraphSpacing=5;return style}
    func attach(_ editor:NSTextView) {self.editor=editor;refresh()}
    func detach() {editor=nil;family = .system;size=14;bold=false;italic=false;underline=false;strikethrough=false;textColor = .automatic;highlightColor = .none}
    func refresh() {
        guard let editor else {return}
        let range=editor.selectedRange(),attributes: [NSAttributedString.Key:Any]
        if range.length>0,editor.textStorage?.length ?? 0 > 0,range.location<(editor.textStorage?.length ?? 0) {attributes=editor.textStorage!.attributes(at:range.location,effectiveRange:nil)}else{attributes=editor.typingAttributes}
        let font=attributes[.font] as? NSFont ?? Self.font(family:.system,size:14)
        family=(attributes[Self.familyKey] as? String).flatMap(VaultFontFamily.init(rawValue:)) ?? .system;size=Double(font.pointSize)
        let traits=Self.traits(attributes);bold=traits.0;italic=traits.1;underline=(attributes[.underlineStyle] as? Int ?? 0) != 0
        strikethrough=(attributes[.strikethroughStyle] as? Int ?? 0) != 0
        textColor=(attributes[Self.textColorKey] as? String).flatMap(VaultTextColor.init(rawValue:)) ?? .automatic
        highlightColor=(attributes[Self.highlightKey] as? String).flatMap(VaultHighlightColor.init(rawValue:)) ?? .none
    }
    func setFamily(_ family:VaultFontFamily) {guard Self.availableFamilies.contains(family) else{return};mutate{attributes in let font=attributes[.font] as? NSFont ?? Self.font(family:.system,size:14),traits=Self.traits(attributes);Self.applyFont(to:&attributes,family:family,size:font.pointSize,bold:traits.0,italic:traits.1)}}
    func setSize(_ size:Double) {guard (10...28).contains(size) else{return};mutate{attributes in let family=(attributes[Self.familyKey] as? String).flatMap(VaultFontFamily.init(rawValue:)) ?? .system,traits=Self.traits(attributes);Self.applyFont(to:&attributes,family:family,size:size,bold:traits.0,italic:traits.1)}}
    func toggle(_ trait:NSFontTraitMask) {let turnOn=trait == .boldFontMask ? !bold:!italic;mutate{attributes in let font=attributes[.font] as? NSFont ?? Self.font(family:.system,size:14),family=(attributes[Self.familyKey] as? String).flatMap(VaultFontFamily.init(rawValue:)) ?? .system,traits=Self.traits(attributes);Self.applyFont(to:&attributes,family:family,size:font.pointSize,bold:trait == .boldFontMask ? turnOn:traits.0,italic:trait == .italicFontMask ? turnOn:traits.1)}}
    func toggleUnderline() {let next=underline ? 0:NSUnderlineStyle.single.rawValue;mutate{$0[.underlineStyle]=next}}
    func toggleStrikethrough() {let next=strikethrough ? 0:NSUnderlineStyle.single.rawValue;mutate{$0[.strikethroughStyle]=next}}
    func setTextColor(_ value:VaultTextColor) {let automatic=automaticTextColor;mutate{$0[Self.textColorKey]=value.rawValue;$0[.foregroundColor]=Self.color(value,automatic:automatic)}}
    func setHighlightColor(_ value:VaultHighlightColor) {mutate{$0[Self.highlightKey]=value.rawValue;$0[.backgroundColor]=Self.highlight(value)}}
    func clearFormatting() {let automatic=automaticTextColor;mutate{attributes in Self.applyFont(to:&attributes,family:.system,size:14,bold:false,italic:false);attributes[.underlineStyle]=0;attributes[.strikethroughStyle]=0;attributes[Self.textColorKey]=VaultTextColor.automatic.rawValue;attributes[.foregroundColor]=automatic;attributes[Self.highlightKey]=VaultHighlightColor.none.rawValue;attributes[.backgroundColor]=nil;attributes[.paragraphStyle]=Self.paragraph()}}
    private func mutate(_ change:(inout [NSAttributedString.Key:Any])->Void) {
        guard let editor,editor.isEditable,let storage=editor.textStorage else{return}
        let range=editor.selectedRange()
        var nextTyping:[NSAttributedString.Key:Any]?
        if range.length == 0 {var attributes=editor.typingAttributes;change(&attributes);nextTyping=attributes}
        else {
            editor.breakUndoCoalescing()
            let undo=editor.undoManager
            undo?.beginUndoGrouping()
            defer {undo?.endUndoGrouping()}
            guard editor.shouldChangeText(in:range,replacementString:nil) else {return}
            let previous=storage.attributedSubstring(from:range)
            undo?.registerUndo(withTarget:editor){target in Self.restore(previous,in:range,editor:target)}
            var replacements:[(NSRange,[NSAttributedString.Key:Any])]=[]
            storage.enumerateAttributes(in:range){attributes,range,_ in var next=attributes;change(&next);replacements.append((range,next))}
            storage.beginEditing();for (range,attributes) in replacements {storage.setAttributes(attributes,range:range)};storage.endEditing();editor.didChangeText()
            undo?.setActionName("文本格式")
        }
        editor.window?.makeFirstResponder(editor);editor.setSelectedRange(range);if let nextTyping {editor.typingAttributes=nextTyping};refresh()
    }
    private static func restore(_ text:NSAttributedString,in range:NSRange,editor:NSTextView) {
        guard let storage=editor.textStorage,range.location<=storage.length,range.length<=storage.length-range.location else{return}
        let previous=storage.attributedSubstring(from:range)
        editor.undoManager?.registerUndo(withTarget:editor){restore(previous,in:range,editor:$0)}
        storage.replaceCharacters(in:range,with:text);editor.didChangeText()
    }
    static func attributes(for run:VaultTextStyleRun,automatic:NSColor)->[NSAttributedString.Key:Any] {
        var style:[NSAttributedString.Key:Any]=[.underlineStyle:run.underline ? NSUnderlineStyle.single.rawValue:0,.strikethroughStyle:run.strikethrough ? NSUnderlineStyle.single.rawValue:0,
            textColorKey:run.textColor.rawValue,highlightKey:run.highlightColor.rawValue,.foregroundColor:color(run.textColor,automatic:automatic),.paragraphStyle:paragraph()]
        style[.backgroundColor]=highlight(run.highlightColor)
        applyFont(to:&style,family:run.family,size:run.size,bold:run.bold,italic:run.italic)
        return style
    }
    static func updateAutomaticColor(in editor:NSTextView,color:NSColor) {
        guard let storage=editor.textStorage else{return}
        var ranges:[NSRange]=[]
        storage.enumerateAttributes(in:NSRange(location:0,length:storage.length)){attributes,range,_ in
            if ((attributes[textColorKey] as? String).flatMap(VaultTextColor.init(rawValue:)) ?? .automatic) == .automatic {ranges.append(range)}
        }
        for range in ranges {storage.addAttribute(.foregroundColor,value:color,range:range)}
        let typing=(editor.typingAttributes[textColorKey] as? String).flatMap(VaultTextColor.init(rawValue:)) ?? .automatic
        if typing == .automatic {editor.typingAttributes[.foregroundColor]=color}
    }
    static func runs(_ text:NSAttributedString)->[VaultTextStyleRun] {
        var runs:[VaultTextStyleRun]=[]
        text.enumerateAttributes(in:NSRange(location:0,length:text.length)){attributes,range,_ in
            let font=attributes[.font] as? NSFont ?? Self.font(family:.system,size:14),traits=Self.traits(attributes)
            let family=(attributes[familyKey] as? String).flatMap(VaultFontFamily.init(rawValue:)) ?? .system
            let next=VaultTextStyleRun(location:range.location,length:range.length,family:family,size:Double(font.pointSize),bold:traits.0,italic:traits.1,underline:(attributes[.underlineStyle] as? Int ?? 0) != 0,
                strikethrough:(attributes[.strikethroughStyle] as? Int ?? 0) != 0,textColor:(attributes[textColorKey] as? String).flatMap(VaultTextColor.init(rawValue:)) ?? .automatic,
                highlightColor:(attributes[highlightKey] as? String).flatMap(VaultHighlightColor.init(rawValue:)) ?? .none)
            if var last=runs.last,last.location+last.length == next.location,last.family == next.family,last.size == next.size,last.bold == next.bold,last.italic == next.italic,last.underline == next.underline,
               last.strikethrough == next.strikethrough,last.textColor == next.textColor,last.highlightColor == next.highlightColor {last.length += next.length;runs[runs.count-1]=last}else{runs.append(next)}
        }
        return runs
    }
}

/// Font metrics determine the insertion point. Fixed minimum/maximum paragraph
/// heights are deliberately absent, so a 14pt body never receives a 23pt caret.
private struct VaultPrivateTextEditor:NSViewRepresentable {
    @ObservedObject var model:VaultModel
    let document:PrivateDocument
    let formatting:VaultEditorFormatting
    @Environment(\.workbenchPalette) private var palette
    func makeCoordinator()->Coordinator {Coordinator(model:model,id:document.id,formatting:formatting)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.scrollerStyle = .overlay;scroll.autohidesScrollers=true;scroll.hasVerticalScroller=true;scroll.drawsBackground=false;scroll.borderType = .noBorder
        let editor=VaultBodyTextView(frame:NSRect(x:0,y:0,width:400,height:400));editor.isRichText=true;editor.importsGraphics=false;editor.allowsUndo=true;editor.usesFontPanel=false
        editor.isAutomaticTextReplacementEnabled=false;editor.isAutomaticDataDetectionEnabled=false;editor.isAutomaticSpellingCorrectionEnabled=false;editor.isContinuousSpellCheckingEnabled=false
        editor.drawsBackground=false;editor.insertionPointColor=palette.nsText;editor.defaultParagraphStyle=VaultEditorFormatting.paragraph()
        editor.textContainerInset=NSSize(width:0,height:8);editor.minSize=NSSize(width:0,height:0);editor.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable=true;editor.isHorizontallyResizable=false;editor.autoresizingMask=[.width];editor.textContainer?.widthTracksTextView=true;editor.textContainer?.lineFragmentPadding=0
        editor.textContainer?.containerSize=NSSize(width:400,height:CGFloat.greatestFiniteMagnitude)
        apply(document,to:editor);editor.delegate=context.coordinator;scroll.documentView=editor;formatting.attach(editor)
        model.registerPlaintextClearer(id:context.coordinator.clearerID){[weak editor,weak formatting] in if let editor {VaultPlaintextPrivacy.clear(editor)};formatting?.detach()}
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let editor=scroll.documentView as? NSTextView else{return}
        if editor.string != document.body || VaultEditorFormatting.runs(editor.attributedString()) != (document.formatting ?? defaultRuns(document.body)) {
            let selection=editor.selectedRange();apply(document,to:editor);let location=min(selection.location,(document.body as NSString).length);editor.setSelectedRange(NSRange(location:location,length:0))
        }
        VaultEditorFormatting.updateAutomaticColor(in:editor,color:palette.nsText)
        formatting.automaticTextColor=palette.nsText;editor.insertionPointColor=palette.nsText;editor.isEditable = !model.busy && model.isUnlocked;formatting.attach(editor)
    }
    private func defaultRuns(_ body:String)->[VaultTextStyleRun] {body.isEmpty ? []:[VaultTextStyleRun(location:0,length:(body as NSString).length)]}
    private func apply(_ document:PrivateDocument,to editor:NSTextView) {
        let attributes:[NSAttributedString.Key:Any]=[.font:VaultEditorFormatting.font(family:.system,size:14),.foregroundColor:palette.nsText,.paragraphStyle:VaultEditorFormatting.paragraph(),VaultEditorFormatting.familyKey:VaultFontFamily.system.rawValue]
        let text=NSMutableAttributedString(string:document.body,attributes:attributes)
        for run in document.formatting ?? [] {text.addAttributes(VaultEditorFormatting.attributes(for:run,automatic:palette.nsText),range:NSRange(location:run.location,length:run.length))}
        formatting.automaticTextColor=palette.nsText
        editor.textStorage?.setAttributedString(text);editor.typingAttributes=attributes
    }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) {if let editor=scroll.documentView as? NSTextView {VaultPlaintextPrivacy.clear(editor);editor.delegate=nil;if coordinator.formatting?.editor === editor {coordinator.formatting?.detach()}};coordinator.model?.removePlaintextClearer(id:coordinator.clearerID)}
    final class Coordinator:NSObject,NSTextViewDelegate {
        weak var model:VaultModel?
        weak var formatting:VaultEditorFormatting?
        let id:UUID
        let clearerID=UUID()
        init(model:VaultModel,id:UUID,formatting:VaultEditorFormatting){self.model=model;self.id=id;self.formatting=formatting}
        func textDidChange(_ notification:Notification) {guard let editor=notification.object as? NSTextView,model?.selectedID == id else{return};model?.updateRichBody(editor.string,formatting:VaultEditorFormatting.runs(editor.attributedString()));formatting?.refresh()}
        func textViewDidChangeSelection(_ notification:Notification){formatting?.refresh()}
    }
}

private final class VaultBodyTextView:VaultClipboardTextView {
    private let history=UndoManager()
    override var undoManager:UndoManager? {history}
    override func paste(_ sender:Any?) {pasteAsPlainText(sender)}
}

private struct VaultSetupSheet:View {
    @ObservedObject var model:VaultModel
    @State private var password=""
    @State private var confirmation=""
    @State private var hint = ""
    var body:some View {
        WorkbenchDialogFrame(title:"建立独立密码",dismiss:model.closeSheet) {
            VStack(alignment:.leading,spacing:16) {
                VaultNewPasswordFields(password: $password, confirmation: $confirmation)
                VaultPasswordHintField(text: $hint)
                VaultPrivacyNotice("请牢记独立密码。密码提示可以帮助你回想密码。", warning: true)
                VaultSheetError(model:model)
            }.disabled(model.busy)
        } actions: {
            Spacer()
            Button("取消",action:model.closeSheet).buttonStyle(WBButtonStyle()).disabled(model.busy).keyboardShortcut(.cancelAction)
            Button("设置密码") {
                let new = password, confirmed = confirmation, question = hint
                password = ""; confirmation = ""
                Task { _ = await model.create(password: new, confirmation: confirmed, hint: question) }
            }.buttonStyle(WBButtonStyle(primary:true))
                .disabled(model.busy || !VaultNewPasswordFields.canSubmit(password, confirmation) || !VaultPasswordHintField.fits(hint))
                .keyboardShortcut(.defaultAction)
        }.modifier(VaultSensitiveState(model:model,clear:clear)).accessibilityIdentifier("fc.modal.vault.setup")
    }
    private func clear() { password=""; confirmation=""; hint="" }
}

private struct VaultPasswordUnlockSheet:View {
    @ObservedObject var model:VaultModel
    @State private var password=""
    var body:some View {
        WorkbenchDialogFrame(title:"先解锁私密空间",dismiss:model.closeSheet) {
            VStack(alignment:.leading,spacing:16) {
                VaultPrivacyNotice("修改密码前需要先验证当前密码。验证通过后继续修改，已有资料不会被替换。")
                VaultPasswordField(title:"当前密码",placeholder:"输入私密空间密码",text:$password)
                VaultSheetError(model:model)
            }.disabled(model.busy)
        } actions: {
            Spacer()
            Button("取消",action:model.closeSheet).buttonStyle(WBButtonStyle()).disabled(model.busy).keyboardShortcut(.cancelAction)
            Button("解锁并继续") {
                let value=password; password=""
                Task { if await model.unlock(password:value),model.isUnlocked { model.sheet = .password } }
            }.buttonStyle(WBButtonStyle(primary:true)).disabled(model.busy || password.isEmpty).keyboardShortcut(.defaultAction)
        }.modifier(VaultSensitiveState(model:model,clear:{password=""})).accessibilityIdentifier("fc.modal.vault.unlockForPassword")
    }
}

private struct VaultPasswordSheet:View {
    @ObservedObject var model:VaultModel
    @State private var current=""
    @State private var next=""
    @State private var confirmation=""
    @State private var hint = ""
    var body:some View {
        WorkbenchDialogFrame(title:"修改独立密码",dismiss:model.closeSheet) {
            VStack(alignment:.leading,spacing:16) {
                VaultPasswordField(title:"当前密码",placeholder:"输入当前密码",text:$current)
                VaultNewPasswordFields(password: $next, confirmation: $confirmation)
                VaultPasswordHintField(text: $hint)
                VaultPrivacyNotice("更改后会立即锁定。使用当前密码的本机历史副本随新密码更新；已导出备份仍需使用创建时的密码。",warning:true)
                VaultSheetError(model:model)
            }.disabled(model.busy || !model.isUnlocked)
        } actions: {
            Spacer()
            Button("取消",action:model.closeSheet).buttonStyle(WBButtonStyle()).disabled(model.busy).keyboardShortcut(.cancelAction)
            Button("更改并锁定") {
                let old = current, new = next, confirmed = confirmation, question = hint
                current = ""; next = ""; confirmation = ""
                Task { _ = await model.changePassword(current: old, new: new, confirmation: confirmed, hint: question) }
            }.buttonStyle(WBButtonStyle(primary:true))
                .disabled(model.busy || !model.isUnlocked || current.isEmpty || !VaultNewPasswordFields.canSubmit(next, confirmation) || !VaultPasswordHintField.fits(hint))
                .keyboardShortcut(.defaultAction)
        }.onAppear { hint = model.passwordHint ?? "" }
            .modifier(VaultSensitiveState(model:model,clear:clear)).accessibilityIdentifier("fc.modal.vault.password")
    }
    private func clear() { current=""; next=""; confirmation=""; hint="" }
}

private struct VaultTouchIDDefaultSheet: View {
    @ObservedObject var model: VaultModel
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchToast) private var toast

    var body: some View {
        WorkbenchDialogFrame(title: "将 Touch ID 设为默认解锁方式？", dismiss: model.closeSheet) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Touch ID 已开启。设为默认后，打开私密空间时会优先显示 Touch ID。你仍可随时改用独立密码。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(4)
                VaultSheetError(model: model)
            }
        } actions: {
            Spacer()
            Button("保留密码为默认", action: model.closeSheet)
                .buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("fc.vault.touchIDDefault.keepPassword")
            Button("设为默认") {
                if model.setPreferredUnlockMethod(.touchID) {
                    model.closeSheet()
                    toast("已将 Touch ID 设为默认解锁方式")
                }
            }
            .buttonStyle(WBButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            .disabled(!model.isUnlocked || !model.biometricEnabled || !model.biometricAvailable || model.busy)
            .accessibilityIdentifier("fc.vault.touchIDDefault.confirm")
        }
        .accessibilityIdentifier("fc.modal.vault.touchIDDefault")
    }
}

private struct VaultPasswordHintSheet: View {
    @ObservedObject var model: VaultModel
    @ObservedObject var close: WorkbenchDraftCloseCoordinator
    @State private var hint = ""
    @Environment(\.workbenchToast) private var toast

    var body: some View {
        WorkbenchDialogFrame(title: "密码提示", dismiss: requestDismiss) {
            VStack(alignment: .leading, spacing: 16) {
                VaultPasswordHintField(text: $hint)
                VaultSheetError(model: model)
            }
        } actions: {
            if model.passwordHint != nil {
                Button("移除提示") { save(nil) }.buttonStyle(WBQuietButtonStyle())
            }
            Spacer()
            Button("取消", action: requestDismiss)
                .buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
            Button("保存提示") { save(hint) }
                .buttonStyle(WBButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                .disabled(hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !VaultPasswordHintField.fits(hint))
        }
        .onAppear { hint = model.passwordHint ?? "" }
        .onChange(of: close.closeRequests) { _, _ in requestDismiss() }
        .workbenchModal(isPresented: $close.confirmingDiscard, onRequestDismiss: close.continueEditing) {
            WorkbenchDiscardConfirmation(
                continueEditing: close.continueEditing,
                discard: { close.discardChanges(dismiss: model.closeSheet) }
            )
        }
        .modifier(VaultSensitiveState(model: model, clear: { hint = "" }))
        .accessibilityIdentifier("fc.modal.vault.passwordHint")
    }

    private func save(_ value: String?) {
        if model.setPasswordHint(value) {
            model.closeSheet()
            toast(value == nil ? "已移除密码提示" : "已保存密码提示")
        }
    }

    private func requestDismiss() {
        close.resolveClose(
            hasChanges: hint.trimmingCharacters(in: .whitespacesAndNewlines) != (model.passwordHint ?? ""),
            dismiss: model.closeSheet
        )
    }
}

private struct VaultBackupSheet:View {
    @ObservedObject var model:VaultModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        WorkbenchDialogFrame(title:"导出加密备份",dismiss:model.closeSheet) {
            VStack(alignment:.leading,spacing:16) {
                VStack(spacing:12) {
                    VaultBackupFact(title:"备份内容",value:model.isUnlocked ? "\(model.documents.count) 条文本":"全部已加密文本")
                    VaultBackupFact(title:"格式",value:"方寸加密备份")
                    VaultBackupFact(title:"恢复要求",value:"导出时使用的密码")
                }
                VaultPrivacyNotice("备份保持完整加密。请保存到可靠的位置；锁定状态下也可导出，内容不会在导出时解密。")
                if let path=model.lastBackupPath {
                    Label("已导出：\(URL(fileURLWithPath:path).lastPathComponent)",systemImage:"checkmark.circle")
                        .font(.system(size:11)).foregroundStyle(palette.success).fixedSize(horizontal:false,vertical:true)
                }
                VaultSheetError(model:model)
            }
        } actions: {
            Spacer()
            Button("取消",action:model.closeSheet).buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
            Button("导出加密备份",action:model.chooseBackupDestination).buttonStyle(WBButtonStyle(primary:true)).disabled(model.busy || !model.isConfigured)
        }.accessibilityIdentifier("fc.modal.vault.export")
    }
}

private struct VaultRestoreSheet:View {
    @ObservedObject var model:VaultModel
    @State private var password=""
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        WorkbenchDialogFrame(title:model.restorePreview == nil ? "验证备份":"确认恢复备份",dismiss:model.closeSheet) {
            VStack(alignment:.leading,spacing:16) {
                if let preview=model.restorePreview {
                    Label("验证通过 · \(preview.count) 条文本",systemImage:"checkmark.shield")
                        .font(.system(size:12)).foregroundStyle(palette.success).padding(10).frame(maxWidth:.infinity,alignment:.leading).background(palette.soft,in:RoundedRectangle(cornerRadius:8))
                    Text(preview.sourceName).font(.system(size:11)).foregroundStyle(palette.muted).lineLimit(2)
                    VaultPrivacyNotice("方寸会先保留当前资料的加密副本，再替换为这份备份。恢复后请用备份密码解锁。",warning:true)
                } else {
                    HStack(spacing:12) {
                        VStack(alignment:.leading,spacing:4) {
                            Text(model.restoreSourceName ?? "尚未选择加密备份").font(.system(size:12)).lineLimit(2)
                            Text("尚未替换当前资料").font(.system(size:11)).foregroundStyle(palette.muted)
                        }
                        Spacer(minLength:4)
                        Button("选择文件",action:model.chooseRestoreSource).buttonStyle(WBButtonStyle())
                    }
                    VaultPasswordField(title:"备份密码",placeholder:"创建这份备份时的密码",text:$password)
                    VaultPrivacyNotice("验证通过后还需确认替换；验证失败不会改动现有资料。")
                }
                VaultSheetError(model:model)
            }.disabled(model.busy)
        } actions: {
            if model.restorePreview != nil {Button("重新选择",action:model.chooseRestoreSource).buttonStyle(WBQuietButtonStyle()).disabled(model.busy)}
            Spacer()
            Button("取消",action:model.closeSheet).buttonStyle(WBButtonStyle()).disabled(model.busy).keyboardShortcut(.cancelAction)
            if model.restorePreview != nil {
                Button("恢复并锁定"){model.confirmRestore()}.buttonStyle(WBButtonStyle(primary:true)).disabled(model.busy).keyboardShortcut(.defaultAction)
            } else {
                Button("验证") { let value=password; password=""; Task { _=await model.verifyRestore(password:value) } }
                    .buttonStyle(WBButtonStyle(primary:true)).disabled(model.busy || password.isEmpty || model.restoreSourceName == nil).keyboardShortcut(.defaultAction)
            }
        }.modifier(VaultSensitiveState(model:model,clear:{password=""})).onChange(of:model.restoreSourceName){_,_ in password=""}.accessibilityIdentifier("fc.modal.vault.restore")
    }
}

private struct VaultBackupFact:View {
    let title:String,value:String
    @Environment(\.workbenchPalette) private var palette
    var body:some View {HStack(spacing:12){Text(title).foregroundStyle(palette.muted);Spacer();Text(value).multilineTextAlignment(.trailing)}.font(.system(size:11)).frame(minHeight:16)}
}
private struct VaultPrivacyNotice:View {
    let text:String
    var warning=false
    @Environment(\.workbenchPalette) private var palette
    init(_ text:String,warning:Bool=false){self.text=text;self.warning=warning}
    var body:some View {HStack(alignment:.top,spacing:8){Image(systemName:warning ? "exclamationmark.triangle":"info.circle");Text(text).fixedSize(horizontal:false,vertical:true)}.font(.system(size:11)).foregroundStyle(warning ? palette.warning:palette.secondary).lineSpacing(4).padding(.vertical,10).padding(.horizontal,12).frame(maxWidth:.infinity,alignment:.leading).background(warning ? palette.warning.opacity(0.07):palette.soft,in:RoundedRectangle(cornerRadius:8))}
}
private struct VaultPasswordField:View {
    let title:String
    let placeholder:String
    @Binding var text:String
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.system(size:12)).foregroundStyle(palette.secondary)
            SecureField(placeholder,text:$text).modifier(VaultInputStyle())
        }
    }
}

private struct VaultNewPasswordFields: View {
    @Binding var password: String
    @Binding var confirmation: String
    @Environment(\.workbenchPalette) private var palette

    static func canSubmit(_ password: String, _ confirmation: String) -> Bool {
        password.count >= VaultCryptography.minimumPasswordLength && password == confirmation
    }

    var body: some View {
        let minimum = VaultCryptography.minimumPasswordLength
        VaultPasswordField(title: "新密码", placeholder: "至少 \(minimum) 个字符", text: $password)
        VaultPasswordField(title: "确认新密码", placeholder: "再次输入新密码", text: $confirmation)
        if !password.isEmpty && password.count < minimum {
            validation("新密码至少需要 \(minimum) 个字符。")
        } else if !confirmation.isEmpty && password != confirmation {
            validation("两次输入的密码不一致。")
        }
    }

    private func validation(_ message: String) -> some View {
        Text(message).font(.system(size: 11)).foregroundStyle(palette.critical)
    }
}

private struct VaultPasswordHintField: View {
    @Binding var text: String
    @Environment(\.workbenchPalette) private var palette

    static func fits(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count <= VaultModel.maximumPasswordHintLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("密码提示（选填）").font(.system(size: 12)).foregroundStyle(palette.secondary)
            TextField("写一句能帮你想起密码的话", text: $text)
                .textFieldStyle(WBTextFieldStyle())
                .accessibilityLabel("密码提示")
            Text("锁定时可查看。请勿填写密码、答案或个人信息。")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !Self.fits(text) {
                Text("密码提示最多 \(VaultModel.maximumPasswordHintLength) 个字符。")
                    .font(.system(size: 11)).foregroundStyle(palette.critical)
            }
        }
    }
}

private struct VaultInputStyle:ViewModifier {
    func body(content:Content) -> some View {
        content.textFieldStyle(.plain).modifier(WBFieldSurface())
    }
}
private struct VaultSheetError:View {
    @ObservedObject var model:VaultModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        if model.busy {HStack(spacing:8){ProgressView().controlSize(.small);Text("正在安全处理…").font(.system(size:11)).foregroundStyle(palette.secondary)}}
        if let error=model.errorMessage {Text(error).font(.system(size:11)).foregroundStyle(palette.critical).fixedSize(horizontal:false,vertical:true)}
    }
}

/// Register private UI drafts independently of the encrypted document model so
/// locking also removes text retained by a modal, search field, or confirmation.
private struct VaultSensitiveState:ViewModifier {
    @ObservedObject var model:VaultModel
    let clear:()->Void
    @State private var identity=UUID()
    func body(content:Content)->some View {
        content.onAppear{model.registerPlaintextClearer(id:identity,clear)}
            .onChange(of:model.sessionID){_,_ in clear()}
            .onDisappear{clear();model.removePlaintextClearer(id:identity)}
    }
}
