import AppKit
import SwiftUI
import LauncherCore

struct VaultModuleView:View {
    @ObservedObject var model:VaultModel
    var returnToSettingsPrivacy:(()->Void)?=nil
    @State private var windowHeight:CGFloat=758
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchModals) private var modals
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            if model.showingProtection {
                Button{model.showingProtection=false;if model.protectionFromSettings {returnToSettingsPrivacy?()}}label:{Label(model.protectionFromSettings ? "返回隐私与锁定":"返回私密空间",systemImage:"arrow.left")}.buttonStyle(WBQuietButtonStyle()).padding(.bottom,12)
                VaultProtectionPage(model:model)
            } else {
                WBPageHeader(title:"私密空间",subtitle:model.isUnlocked ? "\(model.documents.count) 条文本 · 仅保存在此设备":"独立密码保护，仅在需要时解锁") {
                    Button{model.showProtection()}label:{Label("保护与备份",systemImage:"checkmark.shield")}.buttonStyle(WBButtonStyle())
                    if model.isUnlocked {
                        Button{model.lock(reason:"已手动锁定")}label:{Label("锁定",systemImage:"lock")}.buttonStyle(WBButtonStyle())
                        Button{model.newDocument()}label:{Label("新建",systemImage:"plus")}.buttonStyle(WBButtonStyle(primary:true))
                    }
                }
                if model.hasPendingSave && !model.isUnlocked {
                    HStack(alignment:.top,spacing:10){Image(systemName:"exclamationmark.triangle").foregroundStyle(palette.warning);Text("最新更改已加密保留，尚未写入磁盘。请重试保存后再退出。");Spacer();Button("重试保存"){model.flush()}.buttonStyle(WBButtonStyle(primary:true))}.font(.system(size:12)).padding(14).background(palette.warning.opacity(0.07),in:RoundedRectangle(cornerRadius:10)).padding(.bottom,12)
                }
                if model.isUnlocked {VaultUnlockedView(model:model,panelHeight:max(480,min(720,windowHeight-183))).id(model.sessionID)}
                else {VaultLockedView(model:model).id(model.sessionID).frame(maxWidth:.infinity).frame(minHeight:max(420,min(640,windowHeight-214))).background(WorkbenchMaterialSurface(radius:15))}
            }
        }.foregroundStyle(palette.text)
        .background(VaultWindowReader(found:{model.hostWindow=$0},resized:{windowHeight=$0}).frame(width:0,height:0))
        .onChange(of:model.sessionID){_,_ in modals?.prune()}
        .workbenchModal(item:$model.sheet,onDismiss:{if model.restorePreview != nil || model.restoreSourceName != nil {model.cancelRestore()}},onRequestDismiss:model.closeSheet){sheet in
            switch sheet {
            case .setup:VaultSetupSheet(model:model)
            case .unlockForPassword:VaultPasswordUnlockSheet(model:model)
            case .password:VaultPasswordSheet(model:model)
            case .backup:VaultBackupSheet(model:model)
            case .restore:VaultRestoreSheet(model:model)
            }
        }.accessibilityElement(children:.contain).accessibilityIdentifier(model.showingProtection ? "fc.page.vault.protection":"fc.page.vault")
    }
}

private struct VaultProtectionPage:View {
    @ObservedObject var model:VaultModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            WBPageHeader(title:"保护与备份",subtitle:"设置锁定规则，保留可恢复的加密备份")
            VStack(alignment:.leading,spacing:12) {
                WBCard(title:"访问保护",symbol:"checkmark.shield") {
                    VStack(spacing:0) {
                        row("独立密码",model.isUnlocked ? "至少 8 个字符；不会保存明文密码":"先验证解锁，再继续修改密码",first:true){Button("修改密码",action:model.requestPasswordChange).buttonStyle(WBButtonStyle(compact:true)).disabled(!model.isConfigured || model.busy)}
                        row("Touch ID",model.biometricUnavailableReason ?? (model.biometricEnabled ? "仅此设备；变更指纹或密码后需重新开启":"先用独立密码解锁，再为此资料库开启")){
                            if model.biometricEnabled && model.biometricCanRemove {Button("停用"){Task{_ = await model.disableBiometrics()}}.buttonStyle(WBButtonStyle(compact:true)).disabled(model.busy)}
                            else if !model.biometricAvailable {Text("暂不可用").foregroundStyle(palette.muted)}
                            else {Button("开启 Touch ID"){Task{_ = await model.enableBiometrics()}}.buttonStyle(WBButtonStyle(compact:true)).disabled(!model.isUnlocked || model.busy || !model.canChangeProtectionPreferences)}
                        }
                        row("离开私密页时锁定","切换模块、收起工作台后生效"){Text("始终开启").foregroundStyle(palette.secondary)}
                        row("闲置自动锁定","没有操作时自动收起内容"){WBSelect("闲置自动锁定",selection:Binding(get:{model.idleMinutes},set:model.changeIdleMinutes),options:[1,5,10].map{($0,"\($0) 分钟")}).frame(width:174).disabled(!model.canChangeProtectionPreferences)}
                        row("睡眠或会话切换","需要重新验证身份",last:true){Text("始终开启").foregroundStyle(palette.secondary)}
                    }
                }
                WBCard(title:"本机备份",symbol:"archivebox") {
                    VStack(spacing:0) {
                        row("导出加密备份","包含资料与必要的恢复信息",first:true){Button("导出"){model.errorMessage=nil;model.sheet = .backup}.buttonStyle(WBButtonStyle(compact:true)).disabled(!model.isConfigured || model.busy)}
                        row("恢复备份","先验证密码与格式，再确认替换",last:true){Button("选择备份"){model.errorMessage=nil;model.sheet = .restore}.buttonStyle(WBButtonStyle(compact:true)).disabled(model.busy)}
                    }
                }
                Label("没有密码找回功能。恢复会替换当前资料，确认前会保留原有加密副本。",systemImage:"info.circle").font(.system(size:11)).foregroundStyle(palette.muted).padding(.vertical,4)
                if let message=model.completionMessage {Label(message,systemImage:"checkmark.circle").font(.system(size:11)).foregroundStyle(palette.success)}
                if let error=model.errorMessage {Text(error).font(.system(size:11)).foregroundStyle(palette.critical)}
            }
        }.task {await model.refreshBiometrics()}
    }
    private func row<Control:View>(_ title:String,_ subtitle:String,first:Bool=false,last:Bool=false,@ViewBuilder control:()->Control)->some View {
        HStack(spacing:16){VStack(alignment:.leading,spacing:4){Text(title).font(.system(size:12));Text(subtitle).font(.system(size:11)).foregroundStyle(palette.muted)};Spacer();control()}.padding(.top,13).padding(.bottom,last ? 0:13).overlay(alignment:.top){if !first {Rectangle().fill(palette.line).frame(height:1)}}
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
    @State private var showForgot=false
    @FocusState private var focused:Bool
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        VStack(spacing:0) {
            Image(systemName:"lock").font(.system(size:23,weight:.light)).foregroundStyle(palette.secondary).frame(width:52,height:52).background(palette.soft,in:RoundedRectangle(cornerRadius:15)).overlay(RoundedRectangle(cornerRadius:15).strokeBorder(palette.line,lineWidth:1)).padding(.bottom,18)
            Text(model.isConfigured ? "资料已锁定":"建立你的私密空间").font(.system(size:16,weight:.medium)).padding(.bottom,9)
            Text(model.isConfigured ? "你的内容留在这台 Mac 上。\n离开此页面后会自动锁定。":"用一个独立密码，保护只属于你的文字。").font(.system(size:12)).foregroundStyle(palette.secondary).multilineTextAlignment(.center).lineSpacing(5)
            if model.isConfigured {
                SecureField("输入私密空间密码",text:$password).modifier(VaultInputStyle()).focused($focused).onSubmit(unlock).disabled(model.busy).padding(.top,21).padding(.bottom,10)
                Button(action:unlock){HStack{Spacer();if model.busy {ProgressView().controlSize(.small)}else{Label("解锁",systemImage:"lock.open")};Spacer()}}.buttonStyle(WBButtonStyle(primary:true)).disabled(model.busy || password.isEmpty)
                if model.biometricEnabled {
                    if model.biometricAvailable {Button{password="";Task{_ = await model.unlockWithBiometrics()}}label:{Label("使用 Touch ID 解锁",systemImage:"touchid").frame(maxWidth:.infinity)}.buttonStyle(WBButtonStyle()).disabled(model.busy).padding(.top,8)}
                    else if let reason=model.biometricUnavailableReason {Text(reason).font(.system(size:11)).foregroundStyle(palette.muted).multilineTextAlignment(.center).padding(.top,8)}
                }
            } else {
                Button{model.errorMessage=nil;model.sheet = .setup}label:{Label("设置独立密码",systemImage:"key").frame(maxWidth:.infinity)}.buttonStyle(WBButtonStyle(primary:true)).padding(.top,21)
            }
            if let error=model.errorMessage {Text(error).font(.system(size:11)).foregroundStyle(palette.critical).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).padding(.top,10)}
            if let message=model.completionMessage {Text(message).font(.system(size:11)).foregroundStyle(palette.success).multilineTextAlignment(.center).padding(.top,10)}
            HStack(spacing:16){Button("从备份恢复"){model.errorMessage=nil;model.sheet = .restore}.buttonStyle(WBQuietButtonStyle());if model.isConfigured {Button("忘记密码"){showForgot=true}.buttonStyle(WBQuietButtonStyle())}}.padding(.top,18)
        }.frame(maxWidth:360).padding(.vertical,24)
        .onAppear{focused=model.isConfigured}.task{await model.refreshBiometrics()}
        .modifier(VaultSensitiveState(model:model,clear:{password="";showForgot=false}))
        .workbenchModal(isPresented:$showForgot){WorkbenchDialogFrame(title:"忘记密码",dismiss:{showForgot=false}){Text("方寸不会保存或找回私密空间密码。若此前已开启 Touch ID，可在本机验证解锁；Touch ID 不能用于找回或修改遗忘的密码。你可以使用备份及其密码恢复；确认替换前会保留当前加密副本。").font(.system(size:12)).foregroundStyle(palette.secondary).lineSpacing(5)}actions:{Spacer();Button("知道了"){showForgot=false}.buttonStyle(WBButtonStyle(primary:true))}}
    }
    private func unlock(){guard !password.isEmpty,!model.busy else{return};let value=password;password="";Task{_ = await model.unlock(password:value)}}
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
                sidebar.frame(maxHeight:.infinity).padding(10).frame(width:244).background(WorkbenchMaterialSurface(radius:15))
                editor.frame(maxWidth:.infinity,maxHeight:.infinity).padding(14).background(WorkbenchMaterialSurface(radius:15))
            }.frame(height:panelHeight)
            if let error=model.errorMessage {HStack{Text(error).font(.system(size:11)).foregroundStyle(palette.critical);Spacer();if model.hasPendingSave {Button("重试保存"){model.flush()}.buttonStyle(WBButtonStyle())}}}
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
            HStack(spacing:7){Image(systemName:"magnifyingglass").foregroundStyle(palette.muted);TextField("搜索标题",text:$query).textFieldStyle(.plain)}.padding(.horizontal,10).frame(height:32).background(palette.soft,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.line,lineWidth:1))
            HStack(spacing:6){
                WBSelect("筛选分类",selection:Binding(get:{model.categoryFilter},set:{_ = model.selectCategory($0,matching:query)}),options:[("all","全部分类")]+model.categoryOptions)
                Button{categoryName="";editingCategoryID=nil;showCategories=true;model.recordActivity()}label:{Label("管理分类",systemImage:"folder.badge.gearshape")}
                    .buttonStyle(WBButtonStyle(compact:true)).help("新增、重命名或删除分类").accessibilityIdentifier("fc.vault.categories.manage")
            }
            ScrollView {
                LazyVStack(spacing:2) {
                    ForEach(filtered){document in
                        Button{model.selectDocument(document.id)}label:{VStack(alignment:.leading,spacing:5){
                            Text(document.title.isEmpty ? "未命名文本":document.title).font(.system(size:12,weight:.medium)).lineLimit(1)
                            HStack(spacing:6){
                                Text(model.categoryTitle(document)).font(.system(size:10)).foregroundStyle(palette.secondary).lineLimit(1)
                                    .padding(.horizontal,6).padding(.vertical,3).background(palette.soft,in:RoundedRectangle(cornerRadius:5))
                                Text(document.updatedAt.formatted(date:.abbreviated,time:.omitted)).font(.system(size:11)).foregroundStyle(palette.muted).lineLimit(1)
                            }
                        }.padding(.vertical,12).padding(.horizontal,9).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(model.selectedID == document.id ? palette.text:palette.secondary).background(model.selectedID == document.id ? palette.navSelected:.clear,in:RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain)
                    }
                    if filtered.isEmpty {Text(query.isEmpty ? "此分类暂无文本":"没有匹配的标题").font(.system(size:11)).foregroundStyle(palette.muted).padding(.vertical,20)}
                }.background(WorkbenchOverlayScrollbars())
            }
        }
    }
    private var categoryManager:some View {
        WorkbenchDialogFrame(title:"管理分类",dismiss:{showCategories=false;categoryName="";editingCategoryID=nil}){
            VStack(alignment:.leading,spacing:14){
                Text("分类与文本一起加密保存。「未分类」始终保留；删除其他分类时可先选择文本去向。").font(.system(size:12)).foregroundStyle(palette.secondary)
                ScrollView {VStack(spacing:4){ForEach(model.categories){category in
                    HStack(spacing:10){VStack(alignment:.leading,spacing:4){Text(category.name).font(.system(size:12));Text("\(model.documents.filter{$0.effectiveCategoryID == category.id}.count) 条文本").font(.system(size:11)).foregroundStyle(palette.muted)};Spacer();Button{editingCategoryID=category.id;categoryName=category.name}label:{Image(systemName:"pencil")}.buttonStyle(WBIconButtonStyle(size:28)).accessibilityLabel("重命名 \(category.name)");Button{moveDestination="unclassified";categoryDeletion=category}label:{Image(systemName:"trash")}.buttonStyle(WBIconButtonStyle(size:28)).foregroundStyle(palette.critical).accessibilityLabel("删除分类 \(category.name)")}.padding(.vertical,8)
                }}}.frame(maxHeight:240)
                VStack(alignment:.leading,spacing:6){Text(editingCategoryID == nil ? "新增分类":"重命名分类").font(.system(size:12));HStack(spacing:10){TextField("1–30 个字",text:$categoryName).modifier(VaultInputStyle());Button(editingCategoryID == nil ? "新增":"保存"){let saved=editingCategoryID.map{model.renameCategory($0,to:categoryName)} ?? model.addCategory(categoryName);if saved {categoryName="";editingCategoryID=nil}}.buttonStyle(WBButtonStyle(primary:true)).disabled(categoryName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty);if editingCategoryID != nil {Button("取消"){categoryName="";editingCategoryID=nil}.buttonStyle(WBButtonStyle())}}}
                VaultSheetError(model:model)
            }.disabled(model.busy)
        }actions:{Spacer();Button("完成"){showCategories=false;categoryName="";editingCategoryID=nil}.buttonStyle(WBButtonStyle(primary:true))}
    }
    @ViewBuilder private var editor:some View {
        if let document=model.selectedDocument {
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:8){TextField("未命名文本",text:Binding(get:{model.selectedDocument?.title ?? ""},set:model.updateTitle)).textFieldStyle(.plain).font(.system(size:18)).frame(height:32);Button{deletion=VaultDeletionTarget(id:document.id,title:document.title);model.recordActivity()}label:{Image(systemName:"trash")}.buttonStyle(WBIconButtonStyle(size:28)).foregroundStyle(palette.critical).accessibilityLabel("删除文本")}
                HStack(spacing:10){Text("分类").font(.system(size:11)).foregroundStyle(palette.muted);WBSelect("文本分类",selection:Binding(get:{model.selectedDocument?.effectiveCategoryID ?? "unclassified"},set:model.moveSelected),options:model.categoryOptions).frame(width:164);Spacer()}.padding(.top,10).padding(.bottom,10)
                VaultFormattingToolbar(controller:formatting).disabled(model.busy).padding(.bottom,8)
                VaultPrivateTextEditor(model:model,document:document,formatting:formatting).disabled(model.busy).id(document.id)
                HStack{Text(model.saveStatus).foregroundStyle(model.hasPendingSave ? palette.warning:palette.muted);Spacer();Text("\(document.body.count) 字")}.font(.system(size:11)).foregroundStyle(palette.muted).padding(.top,8)
            }
        } else {
            VStack(spacing:14){
                Text(!query.isEmpty ? "没有匹配的标题":model.categoryFilter == "all" ? "新建你的第一条文本":"「\(model.categoryTitle(id:model.categoryFilter))」暂无文本")
                    .font(.system(size:12)).foregroundStyle(palette.muted)
                Button{model.newDocument()}label:{Label("新建文本",systemImage:"plus")}.buttonStyle(WBButtonStyle(primary:true))
                Button("管理分类"){categoryName="";editingCategoryID=nil;showCategories=true;model.recordActivity()}.buttonStyle(WBQuietButtonStyle())
            }.frame(maxWidth:.infinity,maxHeight:.infinity).accessibilityIdentifier("fc.vault.category.empty")
        }
    }
}

private struct VaultFormattingToolbar:View {
    @ObservedObject var controller:VaultEditorFormatting
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        HStack(spacing:4){
            WBSelect("字体",selection:Binding(get:{controller.family},set:controller.setFamily),options:[(.system,"系统"),(.serif,"宋体"),(.monospaced,"等宽")]).frame(width:85)
            WBSelect("字号",selection:Binding(get:{controller.size},set:controller.setSize),options:[10.0,12,14,16,18,20,24,28].map{($0,"\(Int($0))")}).frame(width:66)
            formatButton("加粗",symbol:"bold",selected:controller.bold){controller.toggle(.boldFontMask)}
            formatButton("斜体",symbol:"italic",selected:controller.italic){controller.toggle(.italicFontMask)}
            formatButton("下划线",symbol:"underline",selected:controller.underline){controller.toggleUnderline()}
            Rectangle().fill(palette.line).frame(width:1,height:17).padding(.horizontal,3)
            formatButton("清除格式",symbol:"textformat",selected:false){controller.clearFormatting()}
            Spacer(minLength:0)
        }.padding(6).background(palette.soft,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.line,lineWidth:1)).accessibilityIdentifier("fc.vault.editor.toolbar")
    }
    private func formatButton(_ title:String,symbol:String,selected:Bool,action:@escaping ()->Void)->some View {Button(action:action){Image(systemName:symbol).frame(width:16,height:16)}.buttonStyle(WBIconButtonStyle(size:28)).background(selected ? palette.navSelected:.clear,in:RoundedRectangle(cornerRadius:6)).help(title).accessibilityLabel(title).accessibilityValue(selected ? "已开启":"未开启")}
}

@MainActor final class VaultEditorFormatting:ObservableObject {
    @Published private(set) var family:VaultFontFamily = .system
    @Published private(set) var size:Double=14
    @Published private(set) var bold=false
    @Published private(set) var italic=false
    @Published private(set) var underline=false
    weak var editor:NSTextView?
    static let familyKey=NSAttributedString.Key("FangcunVaultFontFamily")
    static let boldKey=NSAttributedString.Key("FangcunVaultBold")
    static let italicKey=NSAttributedString.Key("FangcunVaultItalic")
    private static func traits(_ attributes:[NSAttributedString.Key:Any])->(Bool,Bool) {let font=attributes[.font] as? NSFont ?? Self.font(family:.system,size:14);let traits=NSFontManager.shared.traits(of:font);return (attributes[boldKey] as? Bool ?? traits.contains(.boldFontMask),attributes[italicKey] as? Bool ?? traits.contains(.italicFontMask))}
    static func applyFont(to attributes:inout [NSAttributedString.Key:Any],family:VaultFontFamily,size:Double,bold:Bool,italic:Bool) {
        let font=font(family:family,size:size,bold:bold,italic:italic),traits=NSFontManager.shared.traits(of:font)
        attributes[.font]=font;attributes[familyKey]=family.rawValue;attributes[boldKey]=bold;attributes[italicKey]=italic
        // CJK faces do not always have italic/bold variants. Preserve the user's
        // semantic choice and synthesize only the unavailable visual trait.
        attributes[.obliqueness]=italic && !traits.contains(.italicFontMask) ? 0.16:0
        attributes[.strokeWidth]=bold && !traits.contains(.boldFontMask) ? -2.0:0
    }
    static func font(family:VaultFontFamily,size:Double,bold:Bool=false,italic:Bool=false)->NSFont {
        let base:NSFont=switch family {case .system:NSFont.systemFont(ofSize:size);case .serif:NSFont(name:"Songti SC",size:size) ?? NSFont.systemFont(ofSize:size);case .monospaced:NSFont.monospacedSystemFont(ofSize:size,weight:.regular)}
        var traits:NSFontTraitMask=[];if bold {traits.insert(.boldFontMask)};if italic {traits.insert(.italicFontMask)}
        return NSFontManager.shared.convert(base,toHaveTrait:traits)
    }
    static func paragraph()->NSParagraphStyle {let style=NSMutableParagraphStyle();style.lineSpacing=3;style.paragraphSpacing=5;return style}
    func attach(_ editor:NSTextView) {self.editor=editor;refresh()}
    func detach() {editor=nil;family = .system;size=14;bold=false;italic=false;underline=false}
    func refresh() {
        guard let editor else {return}
        let range=editor.selectedRange(),attributes: [NSAttributedString.Key:Any]
        if range.length>0,editor.textStorage?.length ?? 0 > 0,range.location<(editor.textStorage?.length ?? 0) {attributes=editor.textStorage!.attributes(at:range.location,effectiveRange:nil)}else{attributes=editor.typingAttributes}
        let font=attributes[.font] as? NSFont ?? Self.font(family:.system,size:14)
        family=(attributes[Self.familyKey] as? String).flatMap(VaultFontFamily.init(rawValue:)) ?? .system;size=Double(font.pointSize)
        let traits=Self.traits(attributes);bold=traits.0;italic=traits.1;underline=(attributes[.underlineStyle] as? Int ?? 0) != 0
    }
    func setFamily(_ family:VaultFontFamily) {mutate{attributes in let font=attributes[.font] as? NSFont ?? Self.font(family:.system,size:14),traits=Self.traits(attributes);Self.applyFont(to:&attributes,family:family,size:font.pointSize,bold:traits.0,italic:traits.1)}}
    func setSize(_ size:Double) {guard (10...28).contains(size) else{return};mutate{attributes in let family=(attributes[Self.familyKey] as? String).flatMap(VaultFontFamily.init(rawValue:)) ?? .system,traits=Self.traits(attributes);Self.applyFont(to:&attributes,family:family,size:size,bold:traits.0,italic:traits.1)}}
    func toggle(_ trait:NSFontTraitMask) {let turnOn=trait == .boldFontMask ? !bold:!italic;mutate{attributes in let font=attributes[.font] as? NSFont ?? Self.font(family:.system,size:14),family=(attributes[Self.familyKey] as? String).flatMap(VaultFontFamily.init(rawValue:)) ?? .system,traits=Self.traits(attributes);Self.applyFont(to:&attributes,family:family,size:font.pointSize,bold:trait == .boldFontMask ? turnOn:traits.0,italic:trait == .italicFontMask ? turnOn:traits.1)}}
    func toggleUnderline() {let next=underline ? 0:NSUnderlineStyle.single.rawValue;mutate{$0[.underlineStyle]=next}}
    func clearFormatting() {mutate{attributes in Self.applyFont(to:&attributes,family:.system,size:14,bold:false,italic:false);attributes[.underlineStyle]=0;attributes[.paragraphStyle]=Self.paragraph()}}
    private func mutate(_ change:(inout [NSAttributedString.Key:Any])->Void) {
        guard let editor,editor.isEditable,let storage=editor.textStorage else{return}
        let range=editor.selectedRange()
        var nextTyping:[NSAttributedString.Key:Any]?
        if range.length == 0 {var attributes=editor.typingAttributes;change(&attributes);nextTyping=attributes}
        else if editor.shouldChangeText(in:range,replacementString:nil) {
            let previous=storage.attributedSubstring(from:range)
            editor.undoManager?.registerUndo(withTarget:editor){target in Self.restore(previous,in:range,editor:target)}
            var replacements:[(NSRange,[NSAttributedString.Key:Any])]=[]
            storage.enumerateAttributes(in:range){attributes,range,_ in var next=attributes;change(&next);replacements.append((range,next))}
            storage.beginEditing();for (range,attributes) in replacements {storage.setAttributes(attributes,range:range)};storage.endEditing();editor.didChangeText()
        }
        editor.window?.makeFirstResponder(editor);editor.setSelectedRange(range);if let nextTyping {editor.typingAttributes=nextTyping};refresh()
    }
    private static func restore(_ text:NSAttributedString,in range:NSRange,editor:NSTextView) {
        guard let storage=editor.textStorage,range.location<=storage.length,range.length<=storage.length-range.location else{return}
        let previous=storage.attributedSubstring(from:range)
        editor.undoManager?.registerUndo(withTarget:editor){restore(previous,in:range,editor:$0)}
        storage.replaceCharacters(in:range,with:text);editor.didChangeText()
    }
    static func runs(_ text:NSAttributedString)->[VaultTextStyleRun] {
        var runs:[VaultTextStyleRun]=[]
        text.enumerateAttributes(in:NSRange(location:0,length:text.length)){attributes,range,_ in
            let font=attributes[.font] as? NSFont ?? Self.font(family:.system,size:14),traits=Self.traits(attributes)
            let family=(attributes[familyKey] as? String).flatMap(VaultFontFamily.init(rawValue:)) ?? .system
            let next=VaultTextStyleRun(location:range.location,length:range.length,family:family,size:Double(font.pointSize),bold:traits.0,italic:traits.1,underline:(attributes[.underlineStyle] as? Int ?? 0) != 0)
            if var last=runs.last,last.location+last.length == next.location,last.family == next.family,last.size == next.size,last.bold == next.bold,last.italic == next.italic,last.underline == next.underline {last.length += next.length;runs[runs.count-1]=last}else{runs.append(next)}
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
        if let storage=editor.textStorage {storage.addAttribute(.foregroundColor,value:palette.nsText,range:NSRange(location:0,length:storage.length))}
        editor.typingAttributes[.foregroundColor]=palette.nsText;editor.insertionPointColor=palette.nsText;editor.isEditable = !model.busy && model.isUnlocked;formatting.attach(editor)
    }
    private func defaultRuns(_ body:String)->[VaultTextStyleRun] {body.isEmpty ? []:[VaultTextStyleRun(location:0,length:(body as NSString).length)]}
    private func apply(_ document:PrivateDocument,to editor:NSTextView) {
        let attributes:[NSAttributedString.Key:Any]=[.font:VaultEditorFormatting.font(family:.system,size:14),.foregroundColor:palette.nsText,.paragraphStyle:VaultEditorFormatting.paragraph(),VaultEditorFormatting.familyKey:VaultFontFamily.system.rawValue]
        let text=NSMutableAttributedString(string:document.body,attributes:attributes)
        for run in document.formatting ?? [] {var style:[NSAttributedString.Key:Any]=[.underlineStyle:run.underline ? NSUnderlineStyle.single.rawValue:0];VaultEditorFormatting.applyFont(to:&style,family:run.family,size:run.size,bold:run.bold,italic:run.italic);text.addAttributes(style,range:NSRange(location:run.location,length:run.length))}
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

private final class VaultBodyTextView:NSTextView {
    private let history=UndoManager()
    override var undoManager:UndoManager? {history}
    override func paste(_ sender:Any?) {pasteAsPlainText(sender)}
}

private struct VaultSetupSheet:View {
    @ObservedObject var model:VaultModel
    @State private var password=""
    @State private var confirmation=""
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        WorkbenchDialogFrame(title:"建立独立密码",dismiss:model.closeSheet) {
            VStack(alignment:.leading,spacing:16) {
                VaultPasswordField(title:"新密码",placeholder:"至少 8 个字符",text:$password)
                VaultPasswordField(title:"确认新密码",placeholder:"再次输入新密码",text:$confirmation)
                VaultPrivacyNotice("请牢记这个独立密码。方寸不会保存明文密码，也没有密码找回功能。",warning:true)
                VaultSheetError(model:model)
            }.disabled(model.busy)
        } actions: {
            Spacer()
            Button("取消",action:model.closeSheet).buttonStyle(WBButtonStyle()).disabled(model.busy).keyboardShortcut(.cancelAction)
            Button("设置密码") { let p=password,c=confirmation; clear(); Task { _=await model.create(password:p,confirmation:c) } }
                .buttonStyle(WBButtonStyle(primary:true)).disabled(model.busy || password.count<8 || confirmation.isEmpty).keyboardShortcut(.defaultAction)
        }.modifier(VaultSensitiveState(model:model,clear:clear)).accessibilityIdentifier("fc.modal.vault.setup")
    }
    private func clear() { password=""; confirmation="" }
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
    var body:some View {
        WorkbenchDialogFrame(title:"修改独立密码",dismiss:model.closeSheet) {
            VStack(alignment:.leading,spacing:16) {
                VaultPasswordField(title:"当前密码",placeholder:"输入当前密码",text:$current)
                VaultPasswordField(title:"新密码",placeholder:"至少 8 个字符",text:$next)
                VaultPasswordField(title:"确认新密码",placeholder:"再次输入新密码",text:$confirmation)
                VaultPrivacyNotice("更改后会立即锁定。以前导出的备份仍需使用创建该备份时的密码。",warning:true)
                VaultSheetError(model:model)
            }.disabled(model.busy || !model.isUnlocked)
        } actions: {
            Spacer()
            Button("取消",action:model.closeSheet).buttonStyle(WBButtonStyle()).disabled(model.busy).keyboardShortcut(.cancelAction)
            Button("更改并锁定") { let c=current,n=next,r=confirmation; clear(); Task { _=await model.changePassword(current:c,new:n,confirmation:r) } }
                .buttonStyle(WBButtonStyle(primary:true)).disabled(model.busy || !model.isUnlocked || current.isEmpty || next.count<8 || confirmation.isEmpty).keyboardShortcut(.defaultAction)
        }.modifier(VaultSensitiveState(model:model,clear:clear)).accessibilityIdentifier("fc.modal.vault.password")
    }
    private func clear() { current=""; next=""; confirmation="" }
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
            Button("完成",action:model.closeSheet).buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
            Button("导出加密备份…",action:model.chooseBackupDestination).buttonStyle(WBButtonStyle(primary:true)).disabled(model.busy || !model.isConfigured)
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
                    VaultPrivacyNotice("恢复将替换当前资料，并使用这份备份的密码。确认前会另存保留原有加密文件，恢复后需要重新解锁。",warning:true)
                } else {
                    HStack(spacing:12) {
                        VStack(alignment:.leading,spacing:4) {
                            Text(model.restoreSourceName ?? "尚未选择加密备份").font(.system(size:12)).lineLimit(2)
                            Text("尚未替换当前资料").font(.system(size:11)).foregroundStyle(palette.muted)
                        }
                        Spacer(minLength:4)
                        Button("选择文件…",action:model.chooseRestoreSource).buttonStyle(WBButtonStyle())
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
private struct VaultInputStyle:ViewModifier {
    func body(content:Content) -> some View {
        content.textFieldStyle(.plain).font(.system(size:12)).padding(.horizontal,10).frame(height:32)
            .background(WorkbenchMaterialSurface(kind:.control,radius:8))
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
