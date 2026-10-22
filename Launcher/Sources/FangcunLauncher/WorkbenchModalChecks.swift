import AppKit
import Combine
import SwiftUI

/// Exercises SwiftUI mounting, nested drafts and moving the same hosting view
/// between native windows, rather than only the coordinator's array operations.
@MainActor enum WorkbenchModalChecks {
    static func run() async -> (count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ message:String){count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") \(message)")}
        let fixture=ModalLifecycleFixture(),modals=WorkbenchModalCoordinator()
        let first=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
        let second=NSWindow(contentRect:first.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        for window in [first,second] {window.alphaValue=0;window.ignoresMouseEvents=true;window.isReleasedWhenClosed=false}
        let host=NSHostingView(rootView:ModalLifecycleRoot(fixture:fixture,modals:modals).nativeCheckAccessibility())
        first.contentView=host;modals.hostWindow=first;first.orderFront(nil)
        defer {modals.clear();first.orderOut(nil);second.orderOut(nil);first.contentView=nil;second.contentView=nil;fixture.readDraft=nil;fixture.writeDraft=nil}
        fixture.parent=true;await settle()
        check(modals.isPresented && modals.presentations.count == 1,"shared modal mounts an app-owned parent dialog")
        host.layoutSubtreeIfNeeded()
        let panels=descendants(host).compactMap{$0 as? NSVisualEffectView}.filter{abs($0.bounds.width-470)<1}
        check(!panels.isEmpty && panels.allSatisfy{$0.bounds.height>20 && $0.bounds.height<150},"shared modal material follows compact content instead of stretching to the window height")
        fixture.writeDraft?("synthetic unsaved draft")
        let identity=fixture.readDraft?().id
        fixture.child=true;await settle()
        check(modals.presentations.count == 2,"nested discard confirmation mounts above its draft")
        check(fixture.readDraft?().text == "synthetic unsaved draft" && fixture.readDraft?().id == identity,"opening nested confirmation retains parent view state and draft identity")
        fixture.child=false;await settle()
        check(modals.presentations.count == 1 && fixture.readDraft?().text == "synthetic unsaved draft","cancelling nested confirmation restores the existing parent draft")
        first.orderOut(nil);await settle()
        check(modals.isPresented && fixture.readDraft?().id == identity,"hiding native window preserves the modal and draft")
        first.contentView=nil;second.contentView=host;modals.hostWindow=second;second.orderFront(nil);await settle()
        check(fixture.readDraft?().id == identity && fixture.readDraft?().text == "synthetic unsaved draft","moving shared hosting view to another native window preserves draft identity")
        fixture.child=true;await settle();fixture.parent=false;modals.prune();await settle()
        check(!modals.isPresented && modals.presentations.isEmpty && !fixture.child,"closing parent also invalidates nested dialog bindings without leaving an orphan")
        fixture.parent=true;await settle()
        check(modals.presentations.count == 1 && !fixture.child,"reopening parent cannot resurrect a dismissed child confirmation")
        fixture.child=true;await settle();modals.clear();await settle()
        check(!fixture.parent && !fixture.child && !modals.isPresented,"shutting down shared modal host clears all live presentation bindings")
        return(count,failures)
    }
    private static func settle() async {try? await Task.sleep(for:.milliseconds(40))}
    private static func descendants(_ view:NSView)->[NSView] {view.subviews.flatMap{[$0]+descendants($0)}}
}
@MainActor private final class ModalLifecycleFixture:ObservableObject {
    @Published var parent=false
    @Published var child=false
    var readDraft:(()->(id:UUID,text:String))?
    var writeDraft:((String)->Void)?
}
private struct ModalLifecycleRoot:View {
    @ObservedObject var fixture:ModalLifecycleFixture
    @ObservedObject var modals:WorkbenchModalCoordinator
    var body:some View {
        ZStack {
            Text("Fixture").workbenchModal(isPresented:$fixture.parent) {ModalLifecycleEditor(fixture:fixture)}
            WorkbenchModalHost(coordinator:modals)
        }.environment(\.workbenchModals,modals).workbenchThemeEnvironment(theme:.arWorld,opacity:0.7,backgroundMotion:false)
    }
}
private struct ModalLifecycleEditor:View {
    @ObservedObject var fixture:ModalLifecycleFixture
    @State private var identity=UUID()
    @State private var text=""
    var body:some View {
        TextField("Synthetic draft",text:$text).padding(18)
            .onAppear {fixture.readDraft={ (identity,text) };fixture.writeDraft={text=$0}}
            .workbenchModal(isPresented:$fixture.child) {Text("Synthetic discard confirmation").padding(18)}
    }
}
