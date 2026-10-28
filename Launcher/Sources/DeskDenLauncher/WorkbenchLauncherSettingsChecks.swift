import AppKit
import Combine
import Foundation
import SwiftUI
import LauncherCore

/// Uses synthetic targets and isolated configuration. No target is executed,
/// file chooser opened, system shortcut registered, or user setting changed.
@MainActor enum WorkbenchLauncherSettingsChecks {
    static func run() async -> (count:Int,failures:Int){
        var count=0,failures=0
        func check(_ condition:Bool,_ message:String){count += 1;if !condition{failures += 1};print("\(condition ? "PASS":"FAIL") \(message)")}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-launcher-settings-checks-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:directory)}
        do{
            let owner=LauncherController(dataDirectory:directory)
            owner.configuration.settings.workbenchHotKey=nil
            owner.configuration.settings.applicationViewHotKey=nil
            owner.configuration.settings.launcherHotKey=nil
            owner.configuration.settings.directLaunchPrefix=nil
            owner.configuration.bindingHotKeys=[:]
            try owner.store.save(owner.configuration)
            owner.configurePanel()
            defer{owner.hotKey.unregister();owner.bindingHotKeys.unregister();owner.toastTask?.cancel();owner.panel.orderOut(nil)}
            let model=WorkbenchLauncherSettingsModel(owner:owner)
            check(model.change{$0.defaultView = .applications;$0.hideUnboundKeys=true;$0.display = .list},"launcher settings save the real default view, visibility and list layout")
            let saved=try owner.store.load()
            check(saved?.settings.defaultView == .applications && saved?.settings.hideUnboundKeys == true && saved?.settings.display == .list,"launcher presentation preferences survive storage reload")
            let first=KeyBinding(target:LaunchTarget(kind:.web,name:"Synthetic first",location:"https://example.com/first"))
            let second=KeyBinding(target:LaunchTarget(kind:.web,name:"Synthetic second",location:"https://example.com/second"))
            check(model.save(first,key:"A") && model.save(second,key:"="),"binding manager writes separate physical keys without executing either target")
            check(try owner.store.load()?.bindings["A"] == first,"binding manager persists selected target through the existing configuration store")
            let list=LauncherBindingListView(owner:owner,frame:NSRect(x:0,y:0,width:600,height:320))
            check(list.rows.map(\.key) == ["=","A"],"ordinary list hides unbound keys and preserves physical keyboard order")
            check(list.documentView != nil && list.rows.allSatisfy{list.documentView!.bounds.contains($0.frame)},"list rows are contained by their independent scroll document")
            owner.draft=BindingEditor(owner.configuration.bindings)
            let editingList=LauncherBindingListView(owner:owner,frame:NSRect(x:0,y:0,width:600,height:320))
            check(editingList.rows.count == 38 && editingList.rows.allSatisfy(\.editing),"editing list exposes all 38 positions even when unbound keys are hidden")
            check(!model.save(nil,key:"A") && model.configuration.bindings["A"] == first,"settings reject binding changes while a separate launcher draft is active")
            owner.draft=nil
            check(model.save(nil,key:"A") && owner.configuration.bindings["A"] == nil,"binding removal uses real persisted configuration")
            model.undoRemoval()
            check(owner.configuration.bindings["A"] == first && owner.configuration.bindings["="] == second,"removal undo restores only the removed binding")
            check(model.status == "已撤销移除","successful removal undo replaces its obsolete status message")
            let before=owner.configuration
            check(!model.change{$0.actionsEnabled=false;$0.applicationsEnabled=false},"invalid panel configuration fails visibly")
            check(owner.configuration == before && model.configuration == before && model.error != nil,"failed settings save retains persisted values and reports an error")
            let modalChecks=await checkModals(owner:owner,model:model)
            count += modalChecks.count;failures += modalChecks.failures
            check(owner.hotKey.shortcut == nil && owner.bindingHotKeys.shortcuts.isEmpty,"isolated launcher settings and modal checks never register a system shortcut")
        }catch{check(false,"unexpected launcher settings check failure: \(error.localizedDescription)")}
        return(count,failures)
    }

    private static func checkModals(owner:LauncherController,model:WorkbenchLauncherSettingsModel) async ->(count:Int,failures:Int){
        var count=0,failures=0
        func check(_ condition:Bool,_ message:String){count += 1;if !condition{failures += 1};print("\(condition ? "PASS":"FAIL") \(message)")}
        let fixture=LauncherBindingsModalFixture(),inspection=WorkbenchBindingInspection(),modals=WorkbenchModalCoordinator()
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:700),styleMask:[.borderless],backing:.buffered,defer:false)
        window.alphaValue=0;window.ignoresMouseEvents=true;window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:LauncherBindingsModalRoot(fixture:fixture,model:model,inspection:inspection,modals:modals).nativeCheckAccessibility())
        window.contentView=host;modals.hostWindow=window;window.orderFront(nil)
        defer{modals.clear();window.orderOut(nil);window.contentView=nil;inspection.openKey=nil;inspection.clearEditor();model.cancelPicker()}
        fixture.presented=true;await settle()
        check(modals.presentations.count == 1 && inspection.openKey != nil,"actual binding manager mounts inside the shared native modal host")
        host.layoutSubtreeIfNeeded()
        let managerPanels=panels(in:host)
        check(!managerPanels.isEmpty && managerPanels.allSatisfy{$0.bounds.height>400 && $0.bounds.height<560},"470-point binding manager material follows its content height without stretching to the viewport")

        inspection.openKey?("1");await settle()
        check(modals.presentations.count == 2 && inspection.readEditor?().key == "1","binding manager opens its real nested editor for a physical key")
        inspection.selectWeb?();await settle()
        let unsaved="https://example.com/unsaved-v5-draft"
        inspection.writeLocation?(unsaved);await settle()
        let draftID=inspection.readEditor?().id
        check(inspection.readEditor?().kind == .web && inspection.readEditor?().location == unsaved && inspection.readEditor?().dirty == true,"real web editor retains the typed target as an unsaved draft")
        host.layoutSubtreeIfNeeded()
        let editorPanels=panels(in:host)
        print("DETAIL launcher modal sizes="+editorPanels.map{"\($0.bounds.width)×\($0.bounds.height)"}.joined(separator:","))
        check(editorPanels.count>=2 && editorPanels.allSatisfy{$0.bounds.height<560} && editorPanels.contains{$0.bounds.height>150 && $0.bounds.height<450},"real web editor has its own compact material height while its manager remains mounted")
        modals.dismissTop();await settle()
        check(modals.presentations.count == 3,"closing a dirty real editor opens a nested discard confirmation")
        host.layoutSubtreeIfNeeded()
        check(panels(in:host).contains{$0.bounds.height>100 && $0.bounds.height<250},"nested discard confirmation sizes its material to its short message and actions")
        inspection.continueEditing?();await settle()
        check(modals.presentations.count == 2 && inspection.readEditor?().id == draftID && inspection.readEditor?().location == unsaved,"continue editing preserves the same native editor and draft after nested cancellation")
        modals.dismissTop();await settle();inspection.discardChanges?();await settle()
        check(modals.presentations.count == 1 && inspection.readEditor == nil && owner.configuration.bindings["1"] == nil,"confirmed discard removes the editor while preserving its manager and persisted configuration")
        inspection.openKey?("1");await settle();inspection.selectWeb?();await settle()
        check(inspection.readEditor?().location.isEmpty == true,"reopening a discarded key cannot resurrect its abandoned URL")
        inspection.writeLocation?("file:///not-an-allowed-web-target");await settle();inspection.saveEditor?();await settle()
        check(modals.presentations.count == 2 && model.error != nil && owner.configuration.bindings["1"] == nil,"invalid web input leaves the actual editor open and never writes a binding")
        inspection.writeLocation?("https://example.com/saved-v5-editor");await settle()
        do {
            let url=owner.store.url,stored=try Data(contentsOf:owner.store.url),configuration=owner.configuration
            let identity=inspection.readEditor?().id
            defer{try? FileManager.default.removeItem(at:url);try? stored.write(to:url,options:.atomic)}
            try FileManager.default.removeItem(at:url)
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
            inspection.saveEditor?();await settle()
            check(model.error != nil && modals.presentations.count == 2 && inspection.readEditor?().id == identity && inspection.readEditor?().location == "https://example.com/saved-v5-editor" && inspection.readEditor?().dirty == true && owner.configuration == configuration,
                  "a real configuration-write failure preserves the mounted binding editor identity, complete draft and existing bindings for retry")
        }catch{check(false,"isolated binding storage failure fixture: "+error.localizedDescription)}
        inspection.saveEditor?();await settle()
        check(modals.presentations.count == 1 && owner.configuration.bindings["1"]?.target.location == "https://example.com/saved-v5-editor","saving from the actual web editor dismisses only the editor and persists its target")
        check((try? owner.store.load())?.bindings["1"]?.target.location == "https://example.com/saved-v5-editor","nested editor save survives a fresh read from its isolated configuration file")

        var openedAll=true,savedAll=true
        for (index,key) in KeyboardLayout.keys.enumerated(){
            inspection.openKey?(key);await settle()
            openedAll = openedAll && inspection.readEditor?().key == key && modals.presentations.count == 2
            inspection.selectWeb?();await settle()
            let address="https://example.com/v5-physical-key-\(index)"
            inspection.writeLocation?(address);await settle();inspection.saveEditor?();await settle()
            savedAll = savedAll && owner.configuration.bindings[key]?.target.kind == .web && owner.configuration.bindings[key]?.target.location == address && modals.presentations.count == 1
        }
        check(openedAll,"all 38 physical keys open the same real binding editor, including punctuation positions")
        let stored=(try? owner.store.load())?.bindings
        check(savedAll && stored?.count == 38 && KeyboardLayout.keys.enumerated().allSatisfy{stored?[$0.element]?.target.location == "https://example.com/v5-physical-key-\($0.offset)"},"all 38 physical positions save their own real web target through the nested editor and configuration store")
        fixture.presented=false;await settle()
        check(modals.presentations.isEmpty && inspection.openKey == nil,"closing the binding manager releases its nested UI inspection and modal state")
        return(count,failures)
    }
    private static func settle() async{try? await Task.sleep(for:.milliseconds(40))}
    private static func panels(in view:NSView)->[NSVisualEffectView]{view.subviews.flatMap{child->[NSVisualEffectView] in
        let own=(child as? NSVisualEffectView).map{abs($0.bounds.width-470)<1 ? [$0]:[]} ?? []
        return own+panels(in:child)
    }}
}

@MainActor private final class LauncherBindingsModalFixture:ObservableObject{@Published var presented=false}
private struct LauncherBindingsModalRoot:View{
    @ObservedObject var fixture:LauncherBindingsModalFixture
    @ObservedObject var model:WorkbenchLauncherSettingsModel
    let inspection:WorkbenchBindingInspection
    @ObservedObject var modals:WorkbenchModalCoordinator
    var body:some View{
        ZStack{
            Color.clear.workbenchModal(isPresented:$fixture.presented){WorkbenchBindingManager(model:model,dismiss:{fixture.presented=false},inspection:inspection)}
            WorkbenchModalHost(coordinator:modals)
        }.environment(\.workbenchModals,modals).workbenchThemeEnvironment(theme:.arWorld,opacity:0.7,backgroundMotion:false)
    }
}
