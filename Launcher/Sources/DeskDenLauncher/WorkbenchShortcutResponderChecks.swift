import AppKit
import SwiftUI
import LauncherCore

/// Mounts the production recording dialog and sends events to its actual native
/// responder. It never calls acceptCandidate, registers a shortcut, or saves one.
@MainActor enum WorkbenchShortcutResponderChecks {
    static func run() async -> (count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ message:String){count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") \(message)")}
        let oldPolicy=NSApp.activationPolicy()
        // The shared native host preparation owns activation. Switching a
        // running regular app to accessory and immediately back can hide its
        // nonactivating panel before AppKit finishes that policy transition.
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-shortcut-responder-\(UUID().uuidString)")
        let owner=LauncherController(dataDirectory:directory)
        owner.configurePanel();owner.scanning=true
        let coordinator=WorkbenchModalCoordinator()
        let window=owner.panel!
        let host=NSHostingView(rootView:ShortcutResponderCheckRoot(owner:owner,coordinator:coordinator).nativeCheckAccessibility())
        window.contentView=host;window.setContentSize(NSSize(width:640,height:440))
        coordinator.hostWindow=window
        defer {
            owner.workbenchShortcutRecorder?.cancel();coordinator.clear()
            window.orderOut(nil);window.contentView=nil;window.delegate=nil;window.close()
            owner.hotKey.unregister();owner.bindingHotKeys.unregister();owner.toastTask?.cancel()
            NSApp.setActivationPolicy(oldPolicy)
            try? FileManager.default.removeItem(at:directory)
        }
        do {
            try owner.store.save(owner.configuration)
            let original=try Data(contentsOf:owner.store.url)
            _ = await NativeUIFixtureWindow.prepare(window: window) {
                descendants(host).compactMap { $0 as? NSButton }.contains { $0.accessibilityLabel() == "设置工作台快捷键" }
            }
            guard let trigger=descendants(host).compactMap({$0 as? NSButton}).first(where:{$0.accessibilityLabel() == "设置工作台快捷键"}) else {throw ShortcutResponderCheckError.missingTrigger}
            trigger.performClick(nil)
            _=await wait {descendants(host).contains{$0 is WorkbenchShortcutCaptureControl}}
            guard let capture=descendants(host).compactMap({$0 as? WorkbenchShortcutCaptureControl}).first,
                  let session=owner.workbenchShortcutRecorder else {throw ShortcutResponderCheckError.missingCapture}
            let initiallyFocused=await wait {window.firstResponder === capture}
            print("DETAIL shortcut focus initial focused=\(initiallyFocused) enabled=\(capture.isEnabled) accepts=\(capture.acceptsFirstResponder) visible=\(window.isVisible) key=\(window.isKeyWindow) presented=\(session.isPresented) canCapture=\(session.canCapture(in:window)) currentResponder=\(window.firstResponder.map{String(describing:type(of:$0))} ?? "nil")")
            check(initiallyFocused && capture.isAccessibilityFocused() && capture.window === window && abs(capture.bounds.height-40)<0.5 && coordinator.top?.width == 470,
                  "mounted shortcut field acquires real keyboard and accessibility focus at its unchanged 40-point height")
            let presentationID=coordinator.top?.id
            let errorIdentifier="fc.settings.\(session.target.accessibilityID).error"
            let initialCandidate=session.draft
            capture.keyDown(with:key(window,keyCode:15,characters:"r"))
            await settle(host)
            check(session.error?.contains("至少需要包含") == true && session.draft == initialCandidate,
                  "plain R reaches the mounted native responder and reports the real missing-modifier validation")
            let visibleValidation=await wait {
                host.layoutSubtreeIfNeeded()
                return visibleError(identifier:errorIdentifier,in:host,window:window)
            }
            check(visibleValidation && presentationID != nil && coordinator.top?.id == presentationID,
                  "plain R displays the actual missing-modifier error text inside the same cached production recording dialog")
            let first=BindingHotKey(keyCode:15,control:true,option:true)
            capture.keyDown(with:key(window,keyCode:15,characters:"r",flags:[.control,.option]))
            await settle(host)
            check(session.draft == first && session.error == nil && capture.valueText == first.title && capture.accessibilityValue() as? String == first.title,
                  "a modified keyDown updates the production candidate and its native accessibility value")
            let validationRemoved=await wait {
                host.layoutSubtreeIfNeeded()
                return errorElements(identifier:errorIdentifier,in:host).isEmpty
            }
            check(validationRemoved && coordinator.top?.id == presentationID && session.isPresented && capture.window === window &&
                  session.draft == first && capture.accessibilityValue() as? String == first.title,
                  "a valid modified key removes the actual error node from the cached dialog while retaining the correctly captured candidate")
            check(owner.hotKey.shortcut == nil && owner.bindingHotKeys.shortcuts.isEmpty && (try? Data(contentsOf:owner.store.url)) == original,
                  "native responder capture neither installs Carbon shortcuts nor changes stored configuration")

            // A known native neighbour makes AppKit's Tab transition deterministic
            // without depending on the user's Full Keyboard Access preference.
            // Freeze only this fixture's explicit two-control loop. Otherwise
            // NSHostingView/AppKit may recalculate it as the candidate redraws,
            // and an ordinary NSButton can be skipped by Full Keyboard Access.
            window.autorecalculatesKeyViewLoop=false
            let next=ShortcutResponderCheckButton(title:"下一个控件",target:nil,action:nil)
            next.frame=NSRect(x:12,y:12,width:100,height:28);host.addSubview(next)
            capture.nextKeyView=next;next.nextKeyView=capture
            let loopReady=capture.nextValidKeyView === next && next.canBecomeKeyView && window.firstResponder === capture
            let second=BindingHotKey(keyCode:17,control:true,option:true)
            capture.keyDown(with:key(window,keyCode:17,characters:"t",flags:[.control,.option]))
            capture.keyDown(with:key(window,keyCode:48,characters:"\t"))
            let immediatelyNext=window.firstResponder === next
            await settle(host)
            print("DETAIL shortcut-tab loopReady=\(loopReady) immediatelyNext=\(immediatelyNext) laterNext=\(window.firstResponder === next) laterCapture=\(window.firstResponder === capture) firstResponder=\(window.firstResponder.map{String(describing:type(of:$0))} ?? "nil") nextValid=\(capture.nextValidKeyView.map{String(describing:type(of:$0))} ?? "nil") nextEligible=\(next.canBecomeKeyView) captureFocused=\(capture.isAccessibilityFocused()) candidate=\(capture.valueText) expected=\(second.title)")
            check(loopReady && immediatelyNext && window.firstResponder === next && !capture.isAccessibilityFocused() && capture.valueText == second.title,
                  "Tab leaves the recording field and the queued candidate update does not steal focus back")
            let point=capture.convert(NSPoint(x:capture.bounds.midX,y:capture.bounds.midY),to:nil)
            let click=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:1,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
            capture.mouseDown(with:click)
            check(window.firstResponder === capture && capture.isAccessibilityFocused(),
                  "clicking the visible candidate field reacquires the same native keyboard responder")
            window.makeFirstResponder(next);capture.setAccessibilityFocused(true)
            check(window.firstResponder === capture && capture.isAccessibilityFocused(),
                  "an accessibility focus request targets the real recording control")
            window.resignKey()
            await settle(host)
            capture.keyDown(with:key(window,keyCode:15,characters:"r",flags:[.control,.option]))
            check(!session.isPresented && owner.workbenchShortcutRecorder == nil && session.draft == nil && (try? Data(contentsOf:owner.store.url)) == original && owner.bindingHotKeys.shortcuts.isEmpty,
                  "losing the real key window cancels mounted recording and rejects subsequent responder events")
        } catch {check(false,"shortcut responder fixture: "+error.localizedDescription)}
        return(count,failures)
    }
    private static func key(_ window:NSWindow,keyCode:UInt16,characters:String,flags:NSEvent.ModifierFlags=[])->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:1,windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:keyCode)!
    }
    private static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    private static func visibleError(identifier:String,in host:NSView,window:NSWindow)->Bool {
        let contentBounds=window.convertToScreen(host.convert(host.bounds,to:nil)).insetBy(dx:-1,dy:-1)
        return errorElements(identifier:identifier,in:host).contains { object in
            let text=[axString("accessibilityLabel",from:object),axString("accessibilityValue",from:object),axString("accessibilityTitle",from:object)]
                .compactMap{$0}.joined(separator:" ")
            guard text.contains("至少需要包含"),object.responds(to:NSSelectorFromString("accessibilityFrame")),
                  let value=object.value(forKey:"accessibilityFrame") as? NSValue else {return false}
            if let view=object as? NSView,view.isHiddenOrHasHiddenAncestor {return false}
            let frame=value.rectValue
            return frame.width>0 && frame.height>0 && contentBounds.contains(frame)
        }
    }
    private static func errorElements(identifier:String,in host:NSView)->[NSObject] {
        var pending:[NSObject]=[host],seen=Set<ObjectIdentifier>(),result:[NSObject]=[]
        while let object=pending.popLast(),seen.count<4096 {
            guard seen.insert(ObjectIdentifier(object)).inserted else {continue}
            if axString("accessibilityIdentifier",from:object) == identifier {result.append(object)}
            if let view=object as? NSView {pending.append(contentsOf:view.subviews)}
            if object.responds(to:NSSelectorFromString("accessibilityChildren")),
               let children=object.value(forKey:"accessibilityChildren") as? [NSObject] {pending.append(contentsOf:children)}
        }
        return result
    }
    private static func axString(_ property:String,from object:NSObject)->String? {
        object.responds(to:NSSelectorFromString(property)) ? object.value(forKey:property) as? String:nil
    }
    private static func wait(_ predicate:@MainActor ()->Bool) async -> Bool {
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        repeat {if predicate(){return true};try? await Task.sleep(for:.milliseconds(20))}while ContinuousClock.now < deadline
        return predicate()
    }
    private static func settle(_ host:NSView) async {for _ in 0..<4 {host.layoutSubtreeIfNeeded();try? await Task.sleep(for:.milliseconds(30))}}
}
private enum ShortcutResponderCheckError:Error {case missingTrigger,missingCapture}
private final class ShortcutResponderCheckButton:NSButton {
    override var acceptsFirstResponder:Bool {true}
    override var canBecomeKeyView:Bool {isEnabled && !isHiddenOrHasHiddenAncestor && window != nil}
}
private struct ShortcutResponderCheckRoot:View {
    let owner:LauncherController
    @ObservedObject var coordinator:WorkbenchModalCoordinator
    var body:some View {
        ZStack {
            WorkbenchShortcutSetting(owner:owner).disabled(coordinator.isPresented)
            WorkbenchModalHost(coordinator:coordinator)
        }.environment(\.workbenchModals,coordinator)
            .workbenchThemeEnvironment(theme:.arWorld,opacity:0.70,backgroundMotion:false)
    }
}
