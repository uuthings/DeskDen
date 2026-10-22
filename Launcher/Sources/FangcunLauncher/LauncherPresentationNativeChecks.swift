import AppKit
import LauncherCore

/// Exercises physical-key routing against the real list viewport and popover.
@MainActor enum LauncherPresentationNativeChecks {
    static func run()->(count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ message:String){count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") \(message)")}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-launcher-presentation-\(UUID().uuidString)")
        let owner=LauncherController(dataDirectory:directory)
        owner.configurePanel();owner.scanning=true
        owner.configuration.bindings=[:]
        owner.configuration.settings.display = .list
        owner.configuration.settings.defaultView = .keys
        defer {owner.closeOverlay(render:false);owner.panel.orderOut(nil);owner.toastTask?.cancel();owner.hotKey.unregister();owner.bindingHotKeys.unregister();try? FileManager.default.removeItem(at:directory)}
        owner.show()
        guard let list=owner.content.subviews.compactMap({$0 as? LauncherBindingListView}).first,
              let row=list.rows.first(where:{$0.key == "M"}) else {
            check(false,"physical-key list fixture has its real M row");return(count,failures)
        }
        // NSView.visibleRect can still contain its pre-layout value immediately
        // after the launcher is ordered. Establish a real clip viewport and a
        // known document origin, then compare both views in clip coordinates.
        owner.panel.contentView?.layoutSubtreeIfNeeded()
        list.tile();list.layoutSubtreeIfNeeded()
        let clip=list.contentView
        clip.scroll(to:.zero);list.reflectScrolledClipView(clip)
        let initialOrigin=clip.bounds.origin
        let initialFrame=row.convert(row.bounds,to:clip)
        let initiallyOutside=abs(initialOrigin.y) < 0.5 && !clip.bounds.isEmpty && clip.bounds.intersection(initialFrame).isEmpty
        if !initiallyOutside {print("DIAG launcher list before route: row=\(initialFrame), clip=\(clip.bounds), document=\(list.documentView?.frame ?? .zero)")}
        check(initiallyOutside,"last physical-key row begins outside the native list viewport")
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:owner.panel.windowNumber,context:nil,characters:"m",charactersIgnoringModifiers:"m",isARepeat:false,keyCode:46)!
        check(owner.route(event) && owner.editorPanel?.isVisible == true && owner.editor == nil,
              "unbound physical key opens the real type chooser in list mode")
        let revealedFrame=row.convert(row.bounds,to:clip)
        let intersection=clip.bounds.intersection(revealedFrame)
        let fullyRevealed=intersection.width >= revealedFrame.width-0.5 && intersection.height >= revealedFrame.height-0.5
        if !fullyRevealed {print("DIAG launcher list after route: row=\(revealedFrame), clip=\(clip.bounds), document=\(list.documentView?.frame ?? .zero), initialOrigin=\(initialOrigin)")}
        check(fullyRevealed && clip.bounds.origin.y > initialOrigin.y && owner.bindingPresentationAnchor(for:"M") === row,
              "keyboard chooser scrolls to and anchors to its matching real list row")
        let surface=owner.editorPanel?.contentView as? BindingPopoverSurface
        let choices=Set(surface?.card.subviews.compactMap{($0 as? NSButton)?.accessibilityLabel()} ?? [])
        let expectedChoices=Set([TargetKind.app,.file,.folder,.web,.shortcut,.shell].map{"绑定"+$0.title})
        check(choices == expectedChoices,
              "list keyboard chooser exposes the six supported user-binding target types")
        owner.closeOverlay(render:false)
        owner.configuration.settings.hideUnboundKeys=true;owner.render()
        check(owner.bindingPresentationAnchor(for:"M") == nil && owner.route(event) && owner.editorPanel?.isVisible == true,
              "hidden unbound physical keys remain configurable using the content anchor")
        return(count,failures)
    }
}
