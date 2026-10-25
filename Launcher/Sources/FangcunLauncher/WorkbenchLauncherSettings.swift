import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import LauncherCore

@MainActor final class WorkbenchLauncherSettingsModel:ObservableObject {
    weak var owner:LauncherController?
    @Published private(set) var configuration:LauncherConfiguration
    @Published private(set) var applications:[LaunchTarget]=[]
    @Published var error:String?
    @Published var status:String?
    @Published var editorCloseRequest=0
    @Published private(set) var pickerBusy=false
    private var observation:AnyCancellable?
    private var picker:NSOpenPanel?
    init(owner:LauncherController){
        self.owner=owner;configuration=owner.configuration;sync()
        observation=NotificationCenter.default.publisher(for:.fangcunConfigurationChanged,object:owner).sink{[weak self] _ in Task{@MainActor in self?.sync()}}
    }
    func sync(){guard let owner else{return};configuration=owner.configuration;applications=SearchEngine.entries(applications:owner.applications+configuration.addedApplications,bindings:[:],includeBindings:false).map(\.target).sorted{LocalizedStandardComparator.compare($0.name,$1.name) == .orderedAscending}}
    @discardableResult func change(_ transform:(inout LauncherSettings)->Void)->Bool{
        guard let owner else{return false}
        guard owner.updateSettings(transform) else{error=owner.lastSaveError ?? "设置未能保存，原值已保留。";sync();return false}
        owner.render();error=nil;sync();return true
    }
    @discardableResult func save(_ binding:KeyBinding?,key:String,movingDuplicate:Bool=false)->Bool{
        guard let owner else{return false}
        guard !owner.isEditing else{error="请先完成或取消启动器中的绑定编辑。";return false}
        do {
            var next=try LauncherBindingMutation.replacing(binding,key:key,in:owner.configuration,movingDuplicate:movingDuplicate)
            if let target=binding?.target,target.kind == .app,!owner.applications.contains(where:{$0.id == target.id}),!next.addedApplications.contains(where:{$0.id == target.id}){next.addedApplications.append(target)}
            let removed=owner.configuration.bindings[key],removedHotKey=owner.configuration.bindingHotKeys[key]
            guard owner.save(next) else{error=owner.lastSaveError ?? "绑定未能保存，当前草稿已保留。";return false}
            if binding == nil,let removed {owner.lastRemoved=(key,removed,removedHotKey)}
            owner.render();error=nil;status=binding == nil ? "已移除 \(key) 的绑定":"已保存 \(key) 的绑定";sync();return true
        }catch{self.error=error.localizedDescription;return false}
    }
    func undoRemoval(){
        guard let owner else{return};owner.undoLastRemoval();sync()
        if owner.lastRemoved == nil{status="已撤销移除";error=nil}else{error=owner.lastSaveError ?? "未能撤销移除，原绑定已保留。"}
    }
    func filteredApplications(_ query:String)->[LaunchTarget]{SearchEngine.search(applications.map{SearchEntry(target:$0)},query:query).map(\.target)}
    func refreshApplications(force:Bool=false) async {
        guard let owner else{return};if force{owner.refreshApplications(force:true)}
        for _ in 0..<150 where owner.scanning {if Task.isCancelled{return};try? await Task.sleep(for:.milliseconds(200))}
        guard !Task.isCancelled else{return};sync()
    }
    func shortcuts() async -> [LaunchTarget]{
        do {let result=try await CommandRunner.run(executable:"/usr/bin/shortcuts",arguments:["list"],timeout:15);guard !result.timedOut,result.status == 0 else{throw LauncherError.unavailable("未能读取快捷指令，可直接填写已有快捷指令名称。")};return result.output.split(whereSeparator:\.isNewline).map{LaunchTarget(kind:.shortcut,name:String($0),location:String($0))}}
        catch{self.error=error.localizedDescription;return []}
    }
    func choose(_ kind:TargetKind,completion:@escaping(LaunchTarget)->Void){
        guard !pickerBusy,let owner,!owner.isPreparingToQuit else{return}
        let panel=NSOpenPanel();panel.title="选择\(kind.title)";panel.allowsMultipleSelection=false;panel.canChooseDirectories=kind == .folder;panel.canChooseFiles=kind != .folder;panel.treatsFilePackagesAsDirectories=false
        if kind == .app {panel.allowedContentTypes=[.applicationBundle]}
        if kind == .shell,let type=UTType(filenameExtension:"sh"){panel.allowedContentTypes=[type]}
        picker=panel;pickerBusy=true;owner.pickerActive=true
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self,weak panel,weak owner] response in
            self?.picker=nil;self?.pickerBusy=false;owner?.pickerActive=false
            guard response == .OK,let url=panel?.url else{return}
            completion(TargetResolver.target(kind:kind,url:url))
        }
        if let window=NSApp.keyWindow {panel.beginSheetModal(for:window,completionHandler:finish)}else{panel.begin(completionHandler:finish)}
    }
    func cancelPicker(){picker?.cancel(nil);picker=nil;pickerBusy=false;owner?.pickerActive=false}
    func moreSettings(){guard let owner else{return};if owner.settingsWindowController == nil{owner.settingsWindowController=LauncherSettingsWindowController(owner:owner)};owner.settingsWindowController?.present()}
}

private enum LocalizedStandardComparator {
    static func compare(_ lhs:String,_ rhs:String)->ComparisonResult{lhs.localizedStandardCompare(rhs)}
}

struct WorkbenchLauncherSettings:View {
    let owner:LauncherController
    let adjustMaterial:()->Void
    @StateObject private var model:WorkbenchLauncherSettingsModel
    @State private var bindingsOpen=false
    @Environment(\.workbenchPalette) private var palette
    init(owner:LauncherController,adjustMaterial:@escaping()->Void){self.owner=owner;self.adjustMaterial=adjustMaterial;_model=StateObject(wrappedValue:WorkbenchLauncherSettingsModel(owner:owner))}
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            WBCard(title:"主面板",symbol:"command",spacing:10){VStack(spacing:0){
                row("唤出快捷键","在任何应用中打开启动器"){WorkbenchShortcutSetting(owner:owner,target:.launcher)}
                row("默认视图","Tab 键可切换按键与应用"){WBSelect("默认视图",selection:setting(\.defaultView),options:LauncherDefaultView.allCases.map{($0,$0.title)}).frame(width:174)}
                row("卡片布局","绑定与未绑定项目使用一致尺寸"){WBSelect("卡片布局",selection:setting(\.display),options:displayOptions).frame(width:174)}
                row("数字快速启动","搜索后用数字键打开候选应用"){Toggle("数字快速启动",isOn:Binding(get:{model.configuration.settings.defaultSearchInputMode == .quick},set:{value in model.change{$0.defaultSearchInputMode=value ? .quick:.text}})).labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.small).tint(palette.accent)}
                row("背景材质","与全局外观同步",last:true){Button("调整材质",action:adjustMaterial).buttonStyle(WBButtonStyle(compact:true))}
            }}
            WBCard(title:"绑定与搜索",symbol:"keyboard",spacing:10){VStack(spacing:0){
                row("按键绑定","管理应用、网址、文件及快捷动作"){Button("管理绑定"){model.error=nil;bindingsOpen=true}.buttonStyle(WBButtonStyle(compact:true)).accessibilityIdentifier("fc.settings.launcher.bindings")}
                row("隐藏未绑定按键","仅影响启动器按键视图",last:true){Toggle("隐藏未绑定按键",isOn:setting(\.hideUnboundKeys)).labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.small).tint(palette.accent)}
            }}
            HStack(spacing:12){Button("更多启动器选项…",action:model.moreSettings).buttonStyle(WBQuietButtonStyle()).help("应用扫描、面板开关、独立快捷键、直达前缀与配置恢复");Spacer();Button("打开启动器"){owner.show()}.buttonStyle(WBQuietButtonStyle())}.font(.system(size:11))
            if let error=model.error{Text(error).font(.system(size:11)).foregroundStyle(palette.critical)}
            if let status=model.status{HStack{Text(status);Spacer();if owner.lastRemoved != nil{Button("撤销移除",action:model.undoRemoval).buttonStyle(WBQuietButtonStyle())}}.font(.system(size:11)).foregroundStyle(palette.muted)}
        }.workbenchModal(isPresented:$bindingsOpen){WorkbenchBindingManager(model:model){bindingsOpen=false}}
            .onAppear{model.sync()}.accessibilityElement(children:.contain).accessibilityIdentifier("fc.settings.launcher")
    }
    private var displayOptions:[(value:DisplayMode,title:String)]{
        var values:[(value:DisplayMode,title:String)]=[(.name,"图标与名称"),(.icon,"仅图标"),(.list,"列表")]
        if [.full,.key].contains(model.configuration.settings.display){values.append((model.configuration.settings.display,model.configuration.settings.display.title))}
        return values
    }
    private func setting<T:Equatable>(_ key:WritableKeyPath<LauncherSettings,T>)->Binding<T>{Binding(get:{model.configuration.settings[keyPath:key]},set:{value in model.change{$0[keyPath:key]=value}})}
    private func row<T:View>(_ title:String,_ subtitle:String,last:Bool=false,@ViewBuilder trailing:()->T)->some View{
        VStack(spacing:0){HStack(spacing:16){VStack(alignment:.leading,spacing:4){Text(title).font(.system(size:12,weight:.medium)).frame(minHeight:17.4,alignment:.leading);Text(subtitle).font(.system(size:11)).foregroundStyle(palette.muted).lineSpacing(2).fixedSize(horizontal:false,vertical:true).frame(minHeight:15.95,alignment:.leading)}.frame(maxWidth:560,alignment:.leading);Spacer(minLength:8);trailing().fixedSize(horizontal:true,vertical:false)}.frame(maxWidth:.infinity,alignment:.leading).padding(.top,13).padding(.bottom,last ? 0:13);if !last{Rectangle().fill(palette.line).frame(height:1)}}
    }
}

/// Native checks mount the same manager/editor and invoke these view-owned
/// actions. No separate test editor or duplicate save path is used.
@MainActor final class WorkbenchBindingInspection {
    struct Snapshot {let id:UUID;let key:String;let kind:TargetKind;let location:String;let dirty:Bool}
    var openKey:((String)->Void)?
    var readEditor:(()->Snapshot)?
    var selectWeb:(()->Void)?
    var writeLocation:((String)->Void)?
    var closeEditor:(()->Void)?
    var continueEditing:(()->Void)?
    var discardChanges:(()->Void)?
    var saveEditor:(()->Void)?
    func clearEditor(){readEditor=nil;selectWeb=nil;writeLocation=nil;closeEditor=nil;continueEditing=nil;discardChanges=nil;saveEditor=nil}
}

private struct WorkbenchBindingRequest:Identifiable{let id:String}
struct WorkbenchBindingManager:View{
    @ObservedObject var model:WorkbenchLauncherSettingsModel
    let dismiss:()->Void
    var inspection:WorkbenchBindingInspection?=nil
    @State private var editing:WorkbenchBindingRequest?
    @Environment(\.workbenchPalette) private var palette
    init(model:WorkbenchLauncherSettingsModel,dismiss:@escaping()->Void,inspection:WorkbenchBindingInspection?=nil){self.model=model;self.dismiss=dismiss;self.inspection=inspection}
    var body:some View{
        WorkbenchDialogFrame(title:"按键绑定",dismiss:dismiss){
            ScrollView{LazyVStack(spacing:0){ForEach(KeyboardLayout.keys,id:\.self){key in
                let binding=model.configuration.bindings[key]
                HStack(spacing:12){Text(key).font(.system(size:12,weight:.medium)).frame(width:30,height:24).background(palette.soft,in:RoundedRectangle(cornerRadius:5));VStack(alignment:.leading,spacing:4){Text(binding?.title ?? "未绑定").font(.system(size:12)).lineLimit(1);if let binding{Text(binding.target.kind.title).font(.system(size:11)).foregroundStyle(palette.muted)}};Spacer();Button(binding == nil ? "绑定":"修改"){open(key)}.buttonStyle(WBButtonStyle(compact:true)).accessibilityIdentifier("fc.launcher.binding.manage.\(key)")}.frame(minHeight:58).overlay(alignment:.bottom){palette.line.frame(height:1)}
            }}.background(WorkbenchOverlayScrollbars())}.frame(height:380)
        }actions:{Text("38 个键位 · 已绑定 \(model.configuration.bindings.count)").font(.system(size:11)).foregroundStyle(palette.muted);Spacer();Button("完成",action:dismiss).buttonStyle(WBButtonStyle(primary:true)).keyboardShortcut(.defaultAction)}
            .workbenchModal(item:$editing,onRequestDismiss:{model.editorCloseRequest += 1}){request in WorkbenchBindingEditor(model:model,key:request.id,dismiss:{editing=nil},openAdvanced:{kind in editing=nil;dismiss();DispatchQueue.main.async{guard let owner=model.owner else{return};owner.show();owner.openEditor(request.id,kind:kind)}},inspection:inspection)}
            .onAppear{inspection?.openKey=open}.onDisappear{inspection?.openKey=nil;inspection?.clearEditor()}
            .accessibilityIdentifier("fc.modal.launcher.bindings")
    }
    private func open(_ key:String){guard KeyboardLayout.keys.contains(key) else{return};model.error=nil;editing=WorkbenchBindingRequest(id:key)}
}

private enum WorkbenchBindingGroup:String,CaseIterable{case app,web,file,action
    var title:String{switch self{case .app:"应用";case .web:"网址";case .file:"文件";case .action:"动作"}}
    init(_ kind:TargetKind){switch kind{case .app:self = .app;case .web:self = .web;case .file,.folder:self = .file;case .shortcut,.shell,.tool:self = .action}}
}
private struct WorkbenchBindingDraft:Equatable{
    var selected:LaunchTarget?
    var location=""
    var alias=""
    var name=""
    var keywords=""
    init(_ binding:KeyBinding?){selected=binding?.target;location=binding?.target.location ?? "";alias=binding?.alias ?? "";name=binding?.target.name ?? "";keywords=binding?.target.keywords ?? ""}
    func binding(kind:TargetKind)throws->KeyBinding{
        let address=location.trimmingCharacters(in:.whitespacesAndNewlines)
        var target:LaunchTarget
        switch kind{
        case .app:guard let selected,selected.kind == .app else{throw LauncherError.invalidTarget("请选择要绑定的应用。")};guard TargetResolver.url(for:selected) != nil else{throw LauncherError.unavailable("应用已移动或不可访问，请重新选择。")};target=selected
        case .web:
            _=try WebURLTemplate(address)
            target=selected ?? LaunchTarget(kind:.web,name:URLComponents(string:address)?.host ?? "网页",location:address)
            if target.location != address,target.iconIsCustom != true{target.iconData=nil}
            target.kind = .web;target.location=address
            target.name=name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? URLComponents(string:address)?.host ?? "网页":name
        case .file,.folder,.shell:
            if let selected,selected.location == address,TargetResolver.url(for:selected) != nil{target=selected}
            else{guard address.hasPrefix("/"),FileManager.default.fileExists(atPath:address) else{throw LauncherError.unavailable("目标不存在或不可访问，请重新选择。")};target=TargetResolver.target(kind:kind,url:URL(fileURLWithPath:address))}
        case .shortcut:target=LaunchTarget(kind:.shortcut,name:address,location:address)
        case .tool:throw LauncherError.unavailable("此工具目标尚不可用，请选择已有快捷指令或本地脚本。")
        }
        target.keywords=keywords;try target.validate();return KeyBinding(target:target,alias:alias)
    }
}

private struct WorkbenchBindingConfirmation:Identifiable{let id=UUID();let binding:KeyBinding;let duplicate:String}
private struct WorkbenchBindingEditor:View{
    @ObservedObject var model:WorkbenchLauncherSettingsModel
    let key:String
    let dismiss:()->Void
    let openAdvanced:(TargetKind)->Void
    let inspection:WorkbenchBindingInspection?
    private let original:KeyBinding?
    @State private var identity=UUID()
    @State private var group:WorkbenchBindingGroup
    @State private var kind:TargetKind
    @State private var fileKind:TargetKind
    @State private var actionKind:TargetKind
    @State private var drafts:[TargetKind:WorkbenchBindingDraft]
    @State private var query=""
    @State private var moreOptions=false
    @State private var showDiscard=false
    @State private var pendingAdvanced=false
    @State private var confirmation:WorkbenchBindingConfirmation?
    @State private var shortcuts:[LaunchTarget]=[]
    @State private var bodyHeight:CGFloat=320
    @Environment(\.workbenchPalette) private var palette
    init(model:WorkbenchLauncherSettingsModel,key:String,dismiss:@escaping()->Void,openAdvanced:@escaping(TargetKind)->Void,inspection:WorkbenchBindingInspection?=nil){
        self.model=model;self.key=key;self.dismiss=dismiss;self.openAdvanced=openAdvanced;self.inspection=inspection
        let current=model.configuration.bindings[key];original=current
        let initial=current?.target.kind == .tool ? TargetKind.shortcut:current?.target.kind ?? .app
        _group=State(initialValue:WorkbenchBindingGroup(initial));_kind=State(initialValue:initial)
        _fileKind=State(initialValue:initial == .folder ? .folder:.file);_actionKind=State(initialValue:initial == .shell ? .shell:.shortcut)
        _drafts=State(initialValue:[initial:WorkbenchBindingDraft(current?.target.kind == initial ? current:nil)])
    }
    private var draft:WorkbenchBindingDraft{drafts[kind] ?? WorkbenchBindingDraft(nil)}
    private var dirty:Bool{drafts.contains{entry in entry.value != WorkbenchBindingDraft(original?.target.kind == entry.key ? original:nil)}}
    var body:some View{
        WorkbenchDialogFrame(title:"绑定按键 \(key)",dismiss:{requestClose()}){
            ScrollView {
            VStack(alignment:.leading,spacing:16){
                groupSelector
                targetFields
                Button(moreOptions ? "收起目标选项":"显示名称与更多选项"){moreOptions.toggle()}.buttonStyle(WBQuietButtonStyle())
                if moreOptions{advancedFields}
                if let error=model.error{Text(error).font(.system(size:11)).foregroundStyle(palette.critical).fixedSize(horizontal:false,vertical:true)}
            }.disabled(model.pickerBusy).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
                .background(GeometryReader{proxy in Color.clear.preference(key:WorkbenchBindingBodyHeight.self,value:proxy.size.height)})
                .background(WorkbenchOverlayScrollbars())
            }.frame(height:min(470,max(60,bodyHeight))).onPreferenceChange(WorkbenchBindingBodyHeight.self){bodyHeight=$0}
        }actions:{
            if original != nil{Button("移除绑定"){if model.save(nil,key:key){dismiss()}}.buttonStyle(WBButtonStyle(destructive:true,compact:true)).disabled(model.pickerBusy)}
            Spacer()
            Button("取消"){requestClose()}.buttonStyle(WBButtonStyle()).disabled(model.pickerBusy).keyboardShortcut(.cancelAction).accessibilityIdentifier("fc.launcher.binding.cancel")
            if kind != .app || moreOptions{Button("保存",action:save).buttonStyle(WBButtonStyle(primary:true)).disabled(model.pickerBusy).keyboardShortcut(.defaultAction).accessibilityIdentifier("fc.launcher.binding.save")}
        }
        .task(id:kind){if kind == .app{await model.refreshApplications()}else if kind == .shortcut{shortcuts=await model.shortcuts()}}
        .onChange(of:model.editorCloseRequest){_,_ in requestClose()}
        .workbenchModal(item:$confirmation){value in
            WorkbenchBindingMoveConfirmation(model:model,binding:value.binding,key:key,duplicate:value.duplicate,
                                            cancel:{confirmation=nil},saved:{confirmation=nil;dismiss()})
        }
        .workbenchModal(isPresented:$showDiscard){WorkbenchDialogFrame(title:"放弃未保存的修改？",dismiss:{showDiscard=false}){
            Text("当前目标修改尚未保存。你可以继续编辑，或放弃后离开。").font(.system(size:12)).foregroundStyle(palette.secondary)
        }actions:{Spacer();Button("继续编辑",action:continueDraft).buttonStyle(WBButtonStyle());Button("放弃修改",action:discardDraft).buttonStyle(WBButtonStyle())}}
        .onAppear{installInspection()}.onDisappear{model.cancelPicker();inspection?.clearEditor()}.accessibilityIdentifier("fc.modal.launcher.bindingEditor.\(key)")
    }
    private var groupSelector:some View{
        HStack(spacing:2){ForEach(WorkbenchBindingGroup.allCases,id:\.self){value in Button{select(value)}label:{Text(value.title).font(.system(size:11)).frame(maxWidth:.infinity).frame(height:24).foregroundStyle(group == value ? palette.text:palette.muted).background(group == value ? palette.soft:.clear,in:RoundedRectangle(cornerRadius:5))}.buttonStyle(WBSelectableButtonStyle(selected: group == value, cornerRadius: 5, drawsSelection: false, showsBorder: false)).accessibilityValue(group == value ? "已选择":"")}}.padding(3).frame(height:32).background(WorkbenchMaterialSurface(kind:.control,radius:8))
    }
    @ViewBuilder private var targetFields:some View{
        switch kind{
        case .app:
            field("搜索应用"){HStack(spacing:7){Image(systemName:"magnifyingglass").foregroundStyle(palette.muted);TextField("名称或首字母",text:$query).textFieldStyle(.plain)}.padding(.horizontal,10).frame(height:32).background(WorkbenchMaterialSurface(kind:.control,radius:8))}
            ScrollView{LazyVStack(spacing:7){ForEach(model.filteredApplications(query)){target in
                Button{var value=draft;value.selected=target;value.location=target.location;value.name=target.name;drafts[kind]=value;if !moreOptions{save()}}label:{HStack(spacing:8){WorkbenchBindingIcon(target:target).frame(width:18,height:18);Text(target.name).font(.system(size:12)).lineLimit(1);Spacer();if draft.selected?.id == target.id{Image(systemName:"checkmark").font(.system(size:11)).foregroundStyle(palette.accent)}}.padding(.horizontal,10).frame(height:32).frame(maxWidth:.infinity,alignment:.leading).background(WorkbenchMaterialSurface(kind:.control,radius:8))}.buttonStyle(WBSelectableButtonStyle(selected: draft.selected?.id == target.id, cornerRadius: 8, drawsSelection: false, showsBorder: false))
            };if model.filteredApplications(query).isEmpty{Text("没有匹配的应用").font(.system(size:11)).foregroundStyle(palette.muted).padding(.vertical,20)}}.background(WorkbenchOverlayScrollbars())}.frame(height:200)
            HStack{Button("选择应用…"){choose(.app)}.buttonStyle(WBButtonStyle(compact:true));Spacer();Button("刷新列表"){Task{await model.refreshApplications(force:true)}}.buttonStyle(WBQuietButtonStyle())}
        case .web:
            field("网址"){input("https://example.com",text:fieldBinding(\.location)).accessibilityIdentifier("fc.launcher.binding.url")}
            Text("可在网址路径或查询中使用 {变量}，打开时会要求填写。").font(.system(size:11)).foregroundStyle(palette.muted)
        case .file,.folder:
            WBSelect("目标类型",selection:Binding(get:{fileKind},set:{fileKind=$0;switchKind($0)}),options:[(.file,"文件"),(.folder,"文件夹")])
            fileField
        case .shortcut:
            WBSelect("动作类型",selection:Binding(get:{actionKind},set:{actionKind=$0;switchKind($0)}),options:[(.shortcut,"快捷指令"),(.shell,"Shell 脚本")])
            field("快捷指令名称"){input("输入已有快捷指令的名称",text:fieldBinding(\.location))}
            if !shortcuts.isEmpty{WBSelect("已有快捷指令",selection:fieldBinding(\.location),options:[("","选择已有快捷指令")]+shortcuts.map{($0.location,$0.name)})}
        case .shell:
            WBSelect("动作类型",selection:Binding(get:{actionKind},set:{actionKind=$0;switchKind($0)}),options:[(.shortcut,"快捷指令"),(.shell,"Shell 脚本")])
            fileField
            Text("仅保存你选择的 .sh 文件；执行时沿用原有脚本运行方式。").font(.system(size:11)).foregroundStyle(palette.muted)
        case .tool:Text("此工具目标尚不可用，请选择快捷指令或本地脚本。").font(.system(size:11)).foregroundStyle(palette.warning)
        }
    }
    private var fileField:some View{field(kind == .shell ? "脚本路径":"文件路径"){HStack(spacing:8){input("选择本机目标",text:fieldBinding(\.location));Button("选择…"){choose(kind)}.buttonStyle(WBButtonStyle())}}}
    private var advancedFields:some View{
        VStack(alignment:.leading,spacing:16){
            field("显示名称"){input("留空使用目标名称",text:fieldBinding(\.alias))}
            field("搜索关键词"){input("名称、首字母或自定义关键词",text:fieldBinding(\.keywords))}
            if kind == .web{field("网页名称"){input("留空使用网站域名",text:fieldBinding(\.name))}}
            Button("完整目标选项…"){requestClose(advanced:true)}.buttonStyle(WBQuietButtonStyle()).help("打开已有目标编辑器，管理自定义图标、变量与目标快捷键")
        }
    }
    private func field<V:View>(_ label:String,@ViewBuilder content:()->V)->some View{VStack(alignment:.leading,spacing:6){Text(label).font(.system(size:12)).foregroundStyle(palette.secondary);content()}}
    private func input(_ prompt:String,text:Binding<String>)->some View{TextField(prompt,text:text).textFieldStyle(.plain).font(.system(size:12)).padding(.horizontal,10).frame(height:32).background(WorkbenchMaterialSurface(kind:.control,radius:8))}
    private func fieldBinding(_ path:WritableKeyPath<WorkbenchBindingDraft,String>)->Binding<String>{Binding(get:{draft[keyPath:path]},set:{value in var next=draft;next[keyPath:path]=value;drafts[kind]=next})}
    private func select(_ value:WorkbenchBindingGroup){group=value;switch value{case .app:switchKind(.app);case .web:switchKind(.web);case .file:switchKind(fileKind);case .action:switchKind(actionKind)}}
    private func switchKind(_ value:TargetKind){kind=value;if drafts[value] == nil{drafts[value]=WorkbenchBindingDraft(original?.target.kind == value ? original:nil)};model.error=nil}
    private func choose(_ value:TargetKind){model.choose(value){target in var next=drafts[value] ?? WorkbenchBindingDraft(nil);next.selected=target;next.location=target.location;next.name=target.name;drafts[value]=next;if value == .app && !moreOptions{save()}}}
    private func save(){
        do{let binding=try draft.binding(kind:kind);if let duplicate=LauncherBindingMutation.duplicateApplicationKey(binding,key:key,in:model.configuration){model.error=nil;confirmation=WorkbenchBindingConfirmation(binding:binding,duplicate:duplicate)}else if model.save(binding,key:key){dismiss()}}
        catch{model.error=error.localizedDescription}
    }
    private func requestClose(advanced:Bool=false){guard !model.pickerBusy else{return};pendingAdvanced=advanced;if dirty{showDiscard=true}else if advanced{openAdvanced(kind)}else{dismiss()}}
    private func continueDraft(){showDiscard=false}
    private func discardDraft(){showDiscard=false;if pendingAdvanced{openAdvanced(kind)}else{dismiss()}}
    private func installInspection(){
        inspection?.readEditor={.init(id:identity,key:key,kind:kind,location:draft.location,dirty:dirty)}
        inspection?.selectWeb={select(.web)}
        inspection?.writeLocation={fieldBinding(\.location).wrappedValue=$0}
        inspection?.closeEditor={requestClose()}
        inspection?.continueEditing=continueDraft
        inspection?.discardChanges=discardDraft
        inspection?.saveEditor=save
    }
}

/// A failed transaction leaves the editor and its frozen move request intact.
/// Observe errors in the topmost retained dialog so retry feedback stays visible.
private struct WorkbenchBindingMoveConfirmation:View {
    @ObservedObject var model:WorkbenchLauncherSettingsModel
    let binding:KeyBinding
    let key:String
    let duplicate:String
    let cancel:()->Void
    let saved:()->Void
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        WorkbenchDialogFrame(title:"移动已有应用绑定？",dismiss:cancel) {
            VStack(alignment:.leading,spacing:12) {
                Text("这个应用已绑定在 \(duplicate)。确认后将移到 \(key)，原键位的独立快捷键也会移除。").font(.system(size:12)).foregroundStyle(palette.secondary)
                if let error=model.error {
                    Text(error).font(.system(size:11)).foregroundStyle(palette.critical).fixedSize(horizontal:false,vertical:true)
                        .accessibilityIdentifier("fc.launcher.binding.moveError")
                }
            }
        }actions:{
            Spacer();Button("取消",action:cancel).buttonStyle(WBButtonStyle())
            Button("确认移动"){if model.save(binding,key:key,movingDuplicate:true){saved()}}.buttonStyle(WBButtonStyle(primary:true))
        }
    }
}

private struct WorkbenchBindingIcon:View{
    let target:LaunchTarget
    var body:some View{Group{if let data=target.iconData,let image=NSImage(data:data){Image(nsImage:image).resizable().scaledToFit()}else if target.kind.isFileSystem{Image(nsImage:NSWorkspace.shared.icon(forFile:target.location)).resizable().scaledToFit()}else{Image(systemName:target.kind.symbol).resizable().scaledToFit().padding(2)}}.accessibilityHidden(true)}
}
private struct WorkbenchBindingBodyHeight:PreferenceKey{
    static let defaultValue:CGFloat=0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat){value=max(value,nextValue())}
}
