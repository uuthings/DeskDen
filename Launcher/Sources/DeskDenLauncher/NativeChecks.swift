import AppKit
import LauncherCore

@MainActor
enum NativeChecks {
    static func run() async -> Int {
        var failures = 0, count = 0
        func check(_ condition:Bool,_ name:String) { count += 1; if !condition { failures += 1 }; print("\(condition ? "PASS" : "FAIL") \(name)") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-native-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:temporary) }
        do {
            try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
            let text = SearchTextView(frame:NSRect(x:0,y:0,width:300,height:30)); text.configure()
            var submissions = 0, cancellations = 0, selections = 0
            text.command = { selector in
                if selector == #selector(NSResponder.insertNewline(_:)) { submissions += 1; return true }
                if selector == #selector(NSResponder.cancelOperation(_:)) { cancellations += 1; return true }
                if selector == #selector(NSResponder.moveDown(_:)) { selections += 1; return true }
                return false
            }
            text.setMarkedText("fang",selectedRange:NSRange(location:4,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            check(text.hasMarkedText(),"native input begins marked composition")
            text.doCommand(by:#selector(NSResponder.insertNewline(_:)))
            check(submissions == 0,"marked Return cannot launch")
            text.setMarkedText("fang",selectedRange:NSRange(location:4,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            text.doCommand(by:#selector(NSResponder.moveDown(_:)))
            check(selections == 0,"marked arrow belongs to IME")
            text.setMarkedText("fang",selectedRange:NSRange(location:4,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            text.doCommand(by:#selector(NSResponder.cancelOperation(_:)))
            check(cancellations == 0,"marked Escape cannot navigate")
            text.unmarkText(); text.doCommand(by:#selector(NSResponder.insertNewline(_:)))
            check(submissions == 1,"unmarked Return dispatches once")
            text.doCommand(by:#selector(NSResponder.cancelOperation(_:)))
            check(cancellations == 1,"unmarked Escape dispatches once")

            var turns:[Int] = []
            let paging = HorizontalPagingSurface(frame:.zero) { turns.append($0) }
            paging.handleScroll(deltaX:-18,deltaY:1,phase:.began,timestamp:1)
            check(turns.isEmpty,"small horizontal gesture cannot accidentally turn a page")
            paging.handleScroll(deltaX:-20,deltaY:1,phase:.changed,timestamp:1.05)
            paging.handleScroll(deltaX:-80,deltaY:0,phase:.changed,timestamp:1.1)
            paging.handleScroll(deltaX:0,deltaY:0,phase:.ended,timestamp:1.2)
            paging.handleScroll(deltaX:-80,deltaY:0,momentumPhase:.began,timestamp:1.3)
            check(turns == [1],"one horizontal gesture and its momentum turn exactly one page")
            paging.handleScroll(deltaX:40,deltaY:0,phase:.began,timestamp:2)
            paging.handleScroll(deltaX:0,deltaY:0,phase:.ended,timestamp:2.1)
            check(turns == [1,-1],"a new reverse gesture returns one page")
            check(!paging.handleScroll(deltaX:1,deltaY:50,phase:.began,timestamp:3) && turns == [1,-1],"vertical gestures do not turn horizontal pages")
            var wheelTurns = 0
            let wheel = HorizontalPagingSurface(frame:.zero) { _ in wheelTurns += 1 }
            for time in [4.0,4.05,4.1,4.15,4.8,4.85,4.9] {
                wheel.handleScroll(deltaX:-1,deltaY:0,precise:false,timestamp:time)
            }
            check(wheelTurns == 2,"phase-less wheel bursts are accumulated and rate-limited")

            let sharedGesture = HorizontalNavigationGesture()
            var sharedTurns = 0
            let actionsSurface = HorizontalPagingSurface(frame:.zero,recognizer:sharedGesture) { _ in sharedTurns += 1 }
            actionsSurface.handleScroll(deltaX:-40,deltaY:0,phase:.began,timestamp:6)
            let applicationsSurface = HorizontalPagingSurface(frame:.zero,recognizer:sharedGesture) { _ in sharedTurns += 1 }
            applicationsSurface.handleScroll(deltaX:-90,deltaY:0,phase:.changed,timestamp:6.1)
            applicationsSurface.handleScroll(deltaX:0,deltaY:0,phase:.ended,timestamp:6.2)
            applicationsSurface.handleScroll(deltaX:-80,deltaY:0,momentumPhase:.began,timestamp:6.3)
            check(sharedTurns == 1,"gesture state survives a view replacement without an extra page transition")
            applicationsSurface.handleScroll(deltaX:-40,deltaY:0,phase:.began,timestamp:7)
            check(sharedTurns == 2,"a new gesture can navigate after cross-view switching")

            let policyController = LauncherController(dataDirectory:temporary.appendingPathComponent("panel-policy"))
            try policyController.store.save(policyController.configuration)
            policyController.configurePanel(); policyController.scanning = true
            check(policyController.updateSettings({ $0.defaultSearchInputMode = .text }) && policyController.textMode,"default text input persists and applies to the current session")
            policyController.textMode = false; policyController.show()
            check(policyController.textMode,"a fresh launcher presentation uses the persisted default input mode")
            policyController.setSearch(text:false); policyController.query = "fixture"; policyController.toggleMainView(); policyController.toggleMainView()
            check(policyController.searchView && !policyController.textMode && policyController.query == "fixture","Tab round trip preserves a temporary input mode and query")
            check(policyController.updateSettings({ $0.applicationsEnabled = false }) && !policyController.searchView,"disabling the active applications view moves to actions")
            policyController.toggleMainView()
            check(!policyController.searchView,"Tab cannot navigate into a disabled applications view")
            let policyBytes = try Data(contentsOf:policyController.store.url)
            let rejectedBoth = !policyController.updateSettings({ $0.actionsEnabled = false })
            let policyAfterRejection = try Data(contentsOf:policyController.store.url)
            check(rejectedBoth && policyController.configuration.settings.actionsEnabled && policyAfterRejection == policyBytes,"disabling both views preserves memory and stored configuration")
            check(policyController.updateSettings({ $0.applicationsEnabled = true; $0.actionsEnabled = false }) && policyController.searchView,"disabling actions moves to the remaining applications view")
            policyController.toggleMainView()
            check(policyController.searchView,"Tab cannot navigate into a disabled actions view")
            check(policyController.updateSettings({ $0.actionsEnabled = true; $0.scrollSwitchesViews = false }),"cross-view scrolling can be disabled independently")
            policyController.setKeys(); policyController.handleHorizontalNavigation(1)
            check(!policyController.searchView,"disabled cross-view scrolling leaves the actions view intact")
            _ = policyController.updateSettings { $0.scrollSwitchesViews = true }
            policyController.handleHorizontalNavigation(1)
            check(policyController.searchView,"enabled horizontal navigation opens applications")
            policyController.handleHorizontalNavigation(-1)
            check(!policyController.searchView,"reverse navigation from the first application page returns to actions")
            policyController.hide(restore:false)

            do {
                let settingsOwner = LauncherController(dataDirectory:temporary.appendingPathComponent("settings-window-commands"))
                try settingsOwner.store.save(settingsOwner.configuration)
                settingsOwner.configurePanel(); settingsOwner.scanning = true
                let settings = LauncherSettingsWindowController(owner:settingsOwner)
                settingsOwner.settingsWindowController = settings
                defer {
                    settings.close(); settingsOwner.panel.orderOut(nil); settingsOwner.hotKey.unregister(); settingsOwner.bindingHotKeys.unregister()
                    settingsOwner.toastTask?.cancel()
                }
                settings.present()
                if let window = settings.window {
                    func commandW() -> NSEvent {
                        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"w",charactersIgnoringModifiers:"w",isARepeat:false,keyCode:13)!
                    }
                    check(window.isVisible && settings.handleEvent(commandW()) && !window.isVisible,"Command-W closes the real settings window outside shortcut recording")
                    settings.present()
                    func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
                    if let root = window.contentView,
                       let pages = descendants(root).compactMap({ $0 as? NSTableView }).first {
                        pages.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
                        if let recorder = descendants(root).compactMap({ $0 as? NSButton }).first(where:{ $0.accessibilityLabel() == "设置应用面板快捷键" }) {
                            recorder.performClick(nil)
                            let wasRecording = recorder.title == "请按下快捷键…"
                            let handled = settings.handleEvent(commandW())
                            let attemptedCapture = settingsOwner.configuration.settings.applicationViewHotKey == BindingHotKey(keyCode:13,command:true) || settingsOwner.lastSaveError != nil
                            check(wasRecording && handled && window.isVisible && attemptedCapture,"Command-W is captured as a shortcut without closing the settings window while recording")
                        } else { check(false,"settings shortcut recorder is available") }
                    } else { check(false,"settings categories are available for shortcut recording") }
                } else {
                    check(false,"settings window exists for Command-W close handling")
                    check(false,"settings window exists for shortcut recording")
                }
            }

            let controller = LauncherController(dataDirectory:temporary.appendingPathComponent("config"))
            // These temporary controllers exercise binding transactions only. Do
            // not compete with a running app for its default workbench shortcut.
            controller.configuration.settings.workbenchHotKey = nil
            let file = temporary.appendingPathComponent("目标 中文.txt"); try Data("test".utf8).write(to:file)
            let target = TargetResolver.target(kind:.file,url:file)
            do {
                let quitting = LauncherController(dataDirectory:temporary.appendingPathComponent("quit-drafts"))
                quitting.configuration.settings.workbenchHotKey = nil
                quitting.configuration.bindings["D"] = KeyBinding(target:target)
                let originalShortcut = BindingHotKey(keyCode:80,control:true,option:true,shift:true,command:true)
                quitting.configuration.bindingHotKeys["D"] = originalShortcut
                try quitting.store.save(quitting.configuration)
                quitting.configurePanel(); quitting.scanning = true
                defer {
                    quitting.closeOverlay(render:false); quitting.panel.orderOut(nil); quitting.toastTask?.cancel()
                    quitting.hotKey.unregister(); quitting.bindingHotKeys.unregister()
                }
                quitting.showBindingHotKey("D")
                if let form = (quitting.editorPanel?.contentView as? BindingPopoverSurface)?.card as? BindingHotKeyForm {
                    check(!quitting.hasUnsavedLauncherChanges && quitting.resolveQuitDrafts() == .terminateNow,"unchanged shortcut form does not block quitting")
                    let original = try Data(contentsOf:quitting.store.url)
                    form.subviews.compactMap { $0 as? ActionButton }.first { $0.title == "清除" }?.actionBlock?()
                    check(quitting.hasUnsavedLauncherChanges,"clearing a shortcut marks its floating form as unsaved on quit")
                    let continued = quitting.resolveTerminationChoice(.alertSecondButtonReturn)
                    let afterContinue = try Data(contentsOf:quitting.store.url)
                    check(continued == .terminateCancel && form.hasChanges && quitting.editorPanel != nil && afterContinue == original,"continue editing cancels quit without discarding the shortcut draft")
                    let discarded = quitting.resolveTerminationChoice(.alertThirdButtonReturn)
                    let afterDiscard = try Data(contentsOf:quitting.store.url)
                    check(discarded == .terminateNow && afterDiscard == original,"discard-and-quit never persists a shortcut draft")
                    let broken = Data("quit shortcut save failure".utf8); try broken.write(to:quitting.store.url)
                    let failed = quitting.resolveTerminationChoice(.alertFirstButtonReturn)
                    let afterFailure = try Data(contentsOf:quitting.store.url)
                    check(failed == .terminateCancel && form.hasChanges && quitting.editorPanel != nil && quitting.configuration.bindingHotKeys["D"] == originalShortcut && afterFailure == broken,"shortcut save failure cancels quit and retains the original configuration and draft")
                    try original.write(to:quitting.store.url)
                    let saved = quitting.resolveTerminationChoice(.alertFirstButtonReturn)
                    let persisted = try quitting.store.load()
                    check(saved == .terminateNow && quitting.editorPanel == nil && persisted?.bindingHotKeys["D"] == nil,"save-and-quit persists the shortcut change before allowing termination")
                } else { check(false,"shortcut quit-protection fixture opens") }

                quitting.configuration.scanDirectories = [temporary.path]
                try quitting.store.save(quitting.configuration)
                quitting.showScanDirectories()
                if let form = (quitting.editorPanel?.contentView as? BindingPopoverSurface)?.card as? ScanDirectoriesCard {
                    check(!quitting.hasUnsavedLauncherChanges && quitting.resolveQuitDrafts() == .terminateNow,"unchanged scan-directory form does not block quitting")
                    let original = try Data(contentsOf:quitting.store.url)
                    form.tabFocusViews.compactMap { $0 as? ActionButton }.first { $0.accessibilityLabel()?.hasPrefix("移除扫描目录") == true }?.actionBlock?()
                    check(quitting.hasUnsavedLauncherChanges,"removing a scan directory marks its floating form as unsaved on quit")
                    let continued = quitting.resolveTerminationChoice(.alertSecondButtonReturn)
                    let afterContinue = try Data(contentsOf:quitting.store.url)
                    check(continued == .terminateCancel && form.hasChanges && quitting.editorPanel != nil && afterContinue == original,"continue editing retains the scan-directory draft and persisted directories")
                    let discarded = quitting.resolveTerminationChoice(.alertThirdButtonReturn)
                    let afterDiscard = try Data(contentsOf:quitting.store.url)
                    check(discarded == .terminateNow && afterDiscard == original,"discard-and-quit never persists scan-directory changes")
                    let broken = Data("quit scan-directory save failure".utf8); try broken.write(to:quitting.store.url)
                    let failed = quitting.resolveTerminationChoice(.alertFirstButtonReturn)
                    let afterFailure = try Data(contentsOf:quitting.store.url)
                    check(failed == .terminateCancel && form.hasChanges && quitting.editorPanel != nil && quitting.configuration.scanDirectories == [temporary.path] && afterFailure == broken,"scan-directory save failure cancels quit and keeps the form and stored configuration")
                    try original.write(to:quitting.store.url)
                    let saved = quitting.resolveTerminationChoice(.alertFirstButtonReturn)
                    let persisted = try quitting.store.load()
                    check(saved == .terminateNow && quitting.editorPanel == nil && persisted?.scanDirectories.isEmpty == true,"save-and-quit persists scan-directory changes before allowing termination")
                } else { check(false,"scan-directory quit-protection fixture opens") }
            }
            controller.configuration.bindings["D"] = KeyBinding(target:target)
            try controller.store.save(controller.configuration)
            controller.configurePanel(); controller.rebuildIndex()
            for mode in DisplayMode.allCases {
                controller.configuration.settings.display = mode; controller.render()
                if mode == .list {
                    let list=controller.content.subviews.compactMap{$0 as? LauncherBindingListView}.first
                    check(list?.rows.count == 38 && list.map{controller.content.bounds.contains($0.frame)} == true && list?.rows.allSatisfy({$0.superview?.bounds.contains($0.frame) == true}) == true,"list renders 38 contained and scrollable binding rows")
                } else {
                    let tiles = controller.content.subviews.compactMap { $0 as? KeyTile }
                    check(tiles.count == 38 && tiles.allSatisfy { controller.content.bounds.contains($0.frame) },"\(mode.rawValue) renders 38 contained key tiles")
                }
            }
            controller.configuration.settings.display = .name; controller.render()
            controller.applications = (0..<30).map { LaunchTarget(kind:.app,name:"Fixture \($0)",location:"/Applications/Fixture \($0).app") }
            controller.rebuildIndex(); controller.setSearch()
            check(controller.content.subviews.filter { $0.accessibilityLabel() == "应用分页" }.count == 1,"search draws exactly one capsule pagination footer")
            if let results = controller.resultContainer {
                check(results.subviews.count == 21 && results.subviews.allSatisfy { results.bounds.contains($0.frame) } && results.frame.maxY <= (controller.paginationView?.frame.minY ?? controller.size.height-46),"21-result grid fits above footer")
            }
            controller.selectPage(1)
            if let results = controller.resultContainer {
                check(results.subviews.count == 9 && results.subviews.first?.frame.origin == .zero,"partial application page stays at the upper left")
            }
            controller.query = "Fixture 29"; controller.selection.reset(); controller.renderResults()
            check(controller.resultContainer?.subviews.first?.frame.origin == .zero,"single search result stays at the upper left")
            controller.query = ""; controller.selection.reset()
            _ = controller.updateSettings { $0.resultLayout = .list }; controller.selection.reset(); controller.renderResults()
            let verticalTiles = controller.resultContainer?.subviews.compactMap { $0 as? ResultTile } ?? []
            check(verticalTiles.count == 30 && verticalTiles.allSatisfy { !$0.list } && verticalTiles[6].frame.minX == 828 && verticalTiles[7].frame.minX == 0 && verticalTiles[7].frame.minY == 138,"vertical application mode renders a continuous seven-column icon grid")
            check(controller.resultScroll?.verticalScroller is LauncherScroller && controller.paginationView?.subviews.compactMap { $0 as? PageIndicatorButton }.isEmpty == true,"vertical grid uses the shared scrollbar without misleading page dots")
            _ = controller.updateSettings { $0.resultLayout = .grid }
            controller.query = "beiwanglu 123 中文"; controller.setSearch(text:true)
            if let container = controller.searchInput.textContainer, let manager = controller.searchInput.layoutManager {
                manager.ensureLayout(for:container)
                check(manager.glyphRange(for:container).length == (controller.query as NSString).length,"single-line search lays out all characters")
            }
            controller.configuration.settings.lightAppearance = true; controller.render()
            check(controller.searchInput.textColor == Palette.text && controller.searchInput.insertionPointColor == Palette.text && controller.searchInput.textStorage?.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor == Palette.text,"theme switch refreshes existing search text and insertion color")
            controller.configuration.settings.lightAppearance = false; controller.render()
            controller.setKeys(); controller.panel.makeKeyAndOrderFront(nil); controller.focus()
            func key(_ code:UInt16,_ characters:String,flags:NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:controller.panel.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
            }
            let applicationsBeforeNavigation = controller.applications
            controller.applications = (0..<63).map { LaunchTarget(kind:.app,name:String(format:"Navigation %02d",$0),location:"/Applications/Navigation \($0).app") }
            controller.rebuildIndex(); controller.query = ""; controller.setSearch(text:false)
            for arrow in [123,124,125,126] {
                controller.resetSearchSelection(); controller.renderResults()
                _ = controller.route(key(UInt16(arrow),""))
                let first = controller.resultContainer?.subviews.compactMap { $0 as? ResultTile }.first
                check(controller.selection.page == 0 && controller.selection.selected == 0 && controller.keyboardSelectionVisible && first?.selected == true && first?.selectionVisible == true,"first arrow \(arrow) activates the first application without skipping it")
            }
            controller.searchInput.string = "Navigation"; controller.searchInput.changed?("Navigation")
            check(!controller.keyboardSelectionVisible && controller.selection.selected == 0,"changing a query resets the keyboard selection outline")
            controller.keyboardSelectionVisible = true; controller.selectPage(1)
            check(!controller.keyboardSelectionVisible && controller.selection.page == 1 && controller.selection.selected == 0,"explicit page selection resets its keyboard outline")
            _ = controller.route(key(124,"\u{F703}"))
            check(controller.keyboardSelectionVisible && controller.selection.page == 1 && controller.selection.selected == 0,"first arrow after pagination activates that page's first application")
            _ = controller.route(key(124,"\u{F703}"))
            check(controller.selection.page == 1 && controller.selection.selected == 1,"subsequent arrows move from the activated application")
            controller.query = ""; controller.searchInput.string = ""
            for row in 0..<3 {
                controller.selection.page = 0; controller.selection.selected = row*7+6; controller.keyboardSelectionVisible = true; controller.renderResults()
                let handledRight = controller.route(key(124,"\u{F703}"))
                let selectedTiles = controller.resultContainer?.subviews.compactMap { $0 as? ResultTile }.filter(\.selected) ?? []
                let expectedTarget = controller.results[21+row*7].target.id
                check(handledRight && controller.selection.page == 1 && controller.selection.selected == row*7 && selectedTiles.count == 1 && selectedTiles.first?.entry.target.id == expectedTarget,"Right at row \(row+1) edge selects the same row on the next rendered page")
                check(controller.route(key(123,"\u{F702}")) && controller.selection.page == 0 && controller.selection.selected == row*7+6,"Left at row \(row+1) start returns to the previous page same-row end")
            }
            controller.applications = Array(controller.applications.prefix(22)); controller.rebuildIndex()
            controller.selection.page = 0; controller.selection.selected = 20; controller.keyboardSelectionVisible = true; controller.renderResults()
            _ = controller.route(key(124,"\u{F703}"))
            check(controller.selection.page == 0 && controller.selection.selected == 20,"Right stays on the current icon when the next page has no corresponding row")
            controller.selection.selected = 6; controller.setSearch(text:true)
            check(!controller.route(key(124,"\u{F703}")) && controller.selection.page == 0 && controller.selection.selected == 6,"text-editing arrows do not page the application grid")
            controller.setSearch(text:false)
            controller.searchInput.setMarkedText("fang",selectedRange:NSRange(location:4,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            check(!controller.route(key(124,"\u{F703}")) && controller.selection.page == 0 && controller.selection.selected == 6,"IME candidate navigation cannot trigger a horizontal page transition")
            controller.searchInput.unmarkText(); controller.query = ""; controller.searchInput.string = ""
            controller.applications = applicationsBeforeNavigation; controller.rebuildIndex()
            _ = controller.updateSettings { $0.resultLayout = .list }
            controller.setSearch(text:false); controller.verticalSelectedIndex = 6; controller.keyboardSelectionVisible = true; controller.updateResultHighlights()
            _ = controller.route(key(124,"\u{F703}"))
            check(controller.verticalSelectedIndex == 7,"vertical results preserve continuous horizontal navigation")
            _ = controller.updateSettings { $0.resultLayout = .grid }
            controller.resetSearchSelection(); controller.setKeys()
            check(controller.route(key(48,"\t")) && controller.searchView,"Tab switches keys to applications")
            controller.query = "Fixture"; controller.searchInput.string = controller.query; controller.selection.page = 1; controller.keyboardSelectionVisible = true; controller.renderResults()
            _ = controller.route(key(48,"\t")); _ = controller.route(key(48,"\t"))
            check(controller.searchView && controller.query == "Fixture" && controller.selection.page == 1 && controller.keyboardSelectionVisible,"Tab round-trip retains query page and keyboard selection outline")
            controller.searchInput.setMarkedText("fang",selectedRange:NSRange(location:4,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            check(!controller.route(key(48,"\t")) && !controller.route(key(19,"2")) && controller.searchView,"IME composition owns Tab and numeric candidate keys")
            controller.searchInput.unmarkText(); controller.query = "Fixture"; controller.searchInput.string = controller.query; controller.textMode = false
            check(controller.route(key(49," ")) && controller.query == "Fixture " && controller.searchView,"Space adds a query space without switching views")
            controller.searchInput.setSelectedRange(NSRange(location:0,length:(controller.searchInput.string as NSString).length))
            _ = controller.route(key(7,"x"))
            check(controller.query == "x","quick search typing replaces its selected text")
            controller.searchInput.setSelectedRange(NSRange(location:0,length:1)); _ = controller.route(key(51,"\u{8}"))
            check(controller.query.isEmpty,"quick search Backspace deletes the selected range")
            controller.query = "Fixture"; controller.searchInput.string = controller.query; controller.renderResults()
            controller.searchInput.clicked?()
            check(!controller.textMode,"clicking search does not disable numeric launch")
            _ = controller.route(key(3,"f",flags:.command))
            check(controller.textMode && !controller.route(key(19,"2")),"Command F reserves digits for text editing")
            controller.configuration.settings.hideOnLaunch = false
            var quickEntries:[SearchEntry] = []
            for index in 1...23 {
                let script = temporary.appendingPathComponent("quick-\(index).sh")
                try Data("#!/bin/sh\nprintf '%s' '\(index)' > quick-result.txt\n".utf8).write(to:script)
                quickEntries.append(SearchEntry(target:LaunchTarget(kind:.shell,name:String(format:"Quick %02d",index),location:script.path)))
            }
            // Persisted launch usage rebuilds the index; keep these harmless
            // launch targets in the scanner fixture as well as the first query.
            let originalApplications = controller.applications
            controller.applications = quickEntries.map(\.target); controller.rebuildIndex()
            controller.query = "Quick"; controller.textMode = false
            controller.selection.reset(); controller.setSearch(); controller.selectPage(1)
            check(controller.route(key(19,"2")),"numeric launch is routed from the current search page")
            for _ in 0..<150 { if !controller.launchPending { break }; try await Task.sleep(for:.milliseconds(20)) }
            check((try? String(contentsOf:temporary.appendingPathComponent("quick-result.txt"),encoding:.utf8)) == "23","digit 2 executes the second result of page two exactly")
            _ = controller.updateSettings { $0.resultLayout = .list }; controller.resetSearchSelection(); controller.render()
            controller.resultScroll?.contentView.scroll(to:NSPoint(x:0,y:138)); controller.verticalResultsDidScroll()
            check(controller.verticalFirstVisibleIndex == 7 && controller.resultBadge(at:7) == "1" && controller.resultBadge(at:8) == "2","vertical numeric badges follow the first fully visible icon row")
            _ = controller.route(key(19,"2"))
            for _ in 0..<150 { if !controller.launchPending { break }; try await Task.sleep(for:.milliseconds(20)) }
            check((try? String(contentsOf:temporary.appendingPathComponent("quick-result.txt"),encoding:.utf8)) == "9","vertical digit 2 executes the second visible result after scrolling")
            let scrollBeforeTab = controller.resultScroll?.contentView.bounds.origin
            _ = controller.route(key(48,"\t")); _ = controller.route(key(48,"\t"))
            check(controller.resultScroll?.contentView.bounds.origin == scrollBeforeTab,"Tab round-trip retains vertical scroll position")
            _ = controller.updateSettings { $0.resultLayout = .grid }; controller.render()
            controller.applications = originalApplications
            controller.configuration.settings.hideOnLaunch = true; controller.rebuildIndex()
            controller.setKeys()
            let baseFrame = controller.panel.frame
            controller.openEditor("1",kind:.web)
            if let form = controller.editor {
                check(form.frame.size == NSSize(width:330,height:430) && form.subviews.allSatisfy { form.bounds.contains($0.frame) },"web binding form matches reference size and contains controls")
                check(controller.panel.frame == baseFrame && controller.overlay == nil && controller.editorPanel != nil,"binding uses a child window without resizing or dimming the launcher")
                _ = controller.route(key(48,"\t"))
                check(!controller.searchView,"Tab within binding cannot switch the main view")
                check(form.subviews.compactMap { $0 as? ActionButton }.first { $0.title == "保存" }?.isEnabled == false,"empty website cannot be saved")
                if let cancel = form.subviews.compactMap({ $0 as? ActionButton }).first(where:{ $0.title == "取消" }) {
                    controller.editorPanel?.makeFirstResponder(cancel); controller.cycleModalFocus(backward:false)
                    check(controller.editorPanel?.firstResponder !== cancel,"modal Tab skips the disabled Save button and continues cycling")
                }
                form.urlField.stringValue = "https://example.com"; form.aliasField.stringValue = "Fixture"; form.save()
                check(controller.configuration.bindings["1"]?.title == "Fixture","binding form saves a valid URL and alias")
            }
            controller.openEditor("1",kind:.web)
            controller.editor?.urlField.stringValue = "javascript:alert(1)"; controller.editor?.save()
            check(controller.editor != nil && controller.configuration.bindings["1"]?.target.location == "https://example.com","invalid URL keeps editor and original binding")
            controller.closeOverlay()
            let fixtureApp = temporary.appendingPathComponent("Fixture.app")
            try FileManager.default.createDirectory(at:fixtureApp,withIntermediateDirectories:true)
            let appTarget = TargetResolver.target(kind:.app,url:fixtureApp)
            controller.configuration.bindings["N"] = KeyBinding(target:appTarget); try controller.store.save(controller.configuration)
            controller.openEditor("2",kind:.app,preselected:appTarget)
            check(controller.editor?.frame.size == NSSize(width:430,height:430),"application binding uses reference 430pt list panel")
            check(controller.editor?.listScroll.verticalScroller is LauncherScroller,"application popup uses the shared custom scrollbar")
            if let close = controller.editor?.subviews.compactMap({ $0 as? ActionButton }).first(where: { $0.accessibilityLabel() == "关闭绑定面板" }) {
                controller.editorPanel?.makeFirstResponder(close)
                check(controller.editor?.handleKeyEvent(key(36,"\r")) == false && controller.configuration.bindings["2"] == nil,"Return on a header button cannot bind the first candidate")
            }
            controller.editor?.save()
            check(controller.editor?.confirmation != nil && controller.configuration.bindings["N"] != nil && controller.configuration.bindings["2"] == nil,"duplicate application requires explicit confirmation")
            if let card = controller.editor?.confirmation?.subviews.first,
               let confirm = card.subviews.compactMap({ $0 as? ActionButton }).first(where:{ $0.title == "确认替换" }) { confirm.actionBlock?() }
            check(controller.configuration.bindings["N"] == nil && controller.configuration.bindings["2"]?.target == appTarget,"confirmed duplicate application moves to exactly one key")
            let variableTarget = LaunchTarget(kind:.web,name:"Variable fixture",location:"https://example.com/search?q={词语}&id={ID}")
            var resolved:URL?
            controller.requestWebVariables(for:variableTarget) { resolved = $0 }
            if let surface = controller.editorPanel?.contentView as? BindingPopoverSurface, let form = surface.card as? WebVariableForm {
                check(form.fields.count == 2 && controller.panel.frame.size == baseFrame.size,"URL variables appear in a separate compact form")
                form.fields[0].stringValue = "中文 & test"; form.fields[1].stringValue = "a/b"; form.submit()
                check(resolved?.absoluteString == "https://example.com/search?q=%E4%B8%AD%E6%96%87%20%26%20test&id=a%2Fb","URL variable form percent-encodes literal user values")
            } else { check(false,"URL variable form appears") }
            controller.setKeys()
            controller.beginEditing(); controller.draft?.swap("D","F"); controller.finishEditing(save:false)
            check(controller.bindings["D"] != nil && controller.bindings["F"] == nil,"cancel board edit leaves persisted bindings")
            controller.beginEditing(); controller.draft?.swap("D","F"); controller.finishEditing(save:true)
            check(try controller.store.load()?.bindings["F"]?.target == target,"done persists board swap")
            let undoChord = BindingHotKey(keyCode:107,control:true,option:true,shift:true,command:true)
            check(controller.setBindingHotKey(undoChord,for:"F"),"binding can register its own global shortcut")
            controller.removeBinding("F")
            check(try controller.store.load()?.bindings["F"] == nil && controller.lastRemoved?.binding.target == target && controller.bindingHotKeys.shortcuts["F"] == nil,"remove persists and retains undo snapshot while unregistering its shortcut")
            controller.undoLastRemoval()
            check(controller.configuration.bindings["F"]?.target == target && controller.configuration.bindingHotKeys["F"] == undoChord && controller.bindingHotKeys.shortcuts["F"] == undoChord,"undo removal restores the target and its live global shortcut")
            _ = controller.setBindingHotKey(nil,for:"F"); controller.removeBinding("F")
            controller.configuration.bindings["D"] = KeyBinding(target:target)
            controller.beginEditing(); controller.draft?.remove("D")
            try Data("corrupt fixture".utf8).write(to:controller.store.url)
            controller.finishEditing(save:true)
            check(controller.draft != nil && controller.configuration.bindings["D"] != nil,"failed save retains draft and last configuration")
            controller.closeOverlay(render:false); controller.draft = nil
            let newURL = temporary.appendingPathComponent("移动后的文件.txt")
            try FileManager.default.moveItem(at:file,to:newURL)
            check(TargetResolver.url(for:target)?.resolvingSymlinksInPath().path == newURL.resolvingSymlinksInPath().path,"bookmark resolves renamed local file")
            try FileManager.default.removeItem(at:newURL)
            check(TargetResolver.url(for:target) == nil,"missing target is detected without deleting binding")

            let quoted = temporary.appendingPathComponent("quoted ' $(literal).sh")
            try Data("#!/bin/sh\nprintf '%s' 'fixture-ok'\n".utf8).write(to:quoted)
            let command = try await CommandRunner.run(executable:"/bin/sh",arguments:[quoted.path],directory:temporary,timeout:3)
            check(command.status == 0 && command.output == "fixture-ok","script path is passed literally without interpolation")
            let failure = try await CommandRunner.run(executable:"/bin/sh",arguments:["-c","exit 7"],timeout:3)
            check(failure.status == 7,"script failure preserves actual exit status")
            let timed = try await CommandRunner.run(executable:"/bin/sleep",arguments:["5"],timeout:0.1)
            check(timed.timedOut && timed.status != 0,"timeout stops a noninteractive process")
            let noisy = try await CommandRunner.run(executable:"/usr/bin/yes",arguments:["bounded"],timeout:0.1)
            check(noisy.timedOut && noisy.output.utf8.count <= 262_144,"command output drains with bounded memory")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:256,pixelsHigh:256,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:1024,bitsPerPixel:32)!
            memset(bitmap.bitmapData!,255,256*1024)
            let smallIcon = try WebsiteIconService.normalizedIcon(from:bitmap.representation(using:.png,properties:[:])!)
            let decoded = NSBitmapImageRep(data:smallIcon)
            check(decoded?.pixelsWide == 128 && decoded?.pixelsHigh == 128 && smallIcon.count <= 131_072,"custom icon normalizes to a bounded 128px PNG")
            check((try? WebsiteIconService.normalizedIcon(from:Data("invalid".utf8))) == nil,"invalid image is rejected")
            check((try? WebsiteIconService.normalizedIcon(from:Data(repeating:0,count:2_097_153))) == nil,"oversized image is rejected before decode")
            let restoredController = LauncherController(dataDirectory:temporary.appendingPathComponent("recovery-config"))
            restoredController.configurePanel()
            let recoveryChord = BindingHotKey(keyCode:113,control:true,option:true,shift:true,command:true)
            var backup = LauncherConfiguration()
            backup.settings.launcherHotKey=nil
            backup.settings.workbenchHotKey=nil // Legacy fixture; the new independent shortcut has its own isolated checks.
            backup.bindings["D"] = KeyBinding(target:TargetResolver.target(kind:.shell,url:quoted))
            backup.bindingHotKeys["D"] = recoveryChord
            try restoredController.store.save(backup)
            var newer = backup; newer.settings.display = .icon
            try restoredController.store.save(newer)
            try Data("damaged configuration".utf8).write(to:restoredController.store.url)
            check(restoredController.recoverConfiguration() && restoredController.configuration.bindings == backup.bindings,"configuration recovery restores the actual backup")
            check(restoredController.hotKey.choice == backup.settings.hotKey && restoredController.bindingHotKeys.shortcuts["D"] == recoveryChord && restoredController.scanning,"configuration recovery registers both shortcut groups and starts a fresh scan")
            while restoredController.scanning { try await Task.sleep(for:.milliseconds(20)) }
            restoredController.hotKey.unregister(); restoredController.bindingHotKeys.unregister()
            let recoveredConfiguration = restoredController.configuration
            restoredController.lastSaveError = "旧的保存错误"
            try Data("damaged recovery backup".utf8).write(to:restoredController.store.backupURL)
            let failedRecovery = !restoredController.recoverConfiguration()
            check(failedRecovery && restoredController.configuration == recoveredConfiguration && restoredController.lastSaveError?.hasPrefix("恢复失败") == true && restoredController.lastSaveError != "旧的保存错误","failed recovery preserves configuration and replaces a stale save error with the actual recovery failure")
            restoredController.panel.orderOut(nil); restoredController.toastTask?.cancel()
            do {
                let startupController = LauncherController(dataDirectory:temporary.appendingPathComponent("startup-shortcuts"))
                startupController.configurePanel(); startupController.lastScan = Date()
                let startupBlocker = GlobalBindingHotKeys(), mainBlocker = GlobalHotKey()
                defer {
                    startupBlocker.unregister(); mainBlocker.unregister()
                    startupController.hotKey.unregister(); startupController.bindingHotKeys.unregister()
                    startupController.panel.orderOut(nil); startupController.toastTask?.cancel()
                }
                let blockedMain = HotKeyChoice.allCases.first { mainBlocker.register($0) == 0 }
                var fixture = LauncherConfiguration()
                fixture.settings.launcherHotKey=nil
                fixture.settings.workbenchHotKey=nil
                if let blockedMain { fixture.settings.hotKey = blockedMain }
                let fixtureTarget = TargetResolver.target(kind:.shell,url:quoted)
                fixture.bindings = Dictionary(uniqueKeysWithValues:["1","2","-","="].map { ($0,KeyBinding(target:fixtureTarget)) })
                let prefix = KeyShortcutPrefix(control:true,option:true,shift:true,command:true)
                fixture.settings.directLaunchPrefix = prefix
                let blockedExplicit = BindingHotKey(keyCode:64,control:true,option:true,shift:true,command:true)
                let availableExplicit = BindingHotKey(keyCode:79,control:true,option:true,shift:true,command:true)
                fixture.bindingHotKeys = ["1":blockedExplicit,"2":availableExplicit]
                let blockedInherited = prefix.shortcut(for:"-")!, availableInherited = prefix.shortcut(for:"=")!
                let blockerStatus = startupBlocker.register(["D":blockedExplicit,"E":blockedInherited])
                if blockerStatus == 0 {
                    startupController.configuration = fixture; try startupController.store.save(fixture)
                    startupController.registerStartupHotKeys()
                    check(startupController.bindingHotKeys.shortcuts == ["2":availableExplicit,"=":availableInherited],"startup conflicts retain every available explicit and inherited shortcut")
                    let startupProblem = startupController.bindingHotKeyProblem ?? ""
                    check(startupProblem.contains("1 键") && startupProblem.contains("- 键") && !startupProblem.contains("2 键") && startupController.activeDirectLaunchPrefix == nil,"startup reports failed keys and hides an incomplete shared-prefix hint")
                    startupBlocker.unregister(); startupController.registerStartupHotKeys()
                    check(startupController.bindingHotKeys.shortcuts == fixture.effectiveBindingHotKeys && startupController.activeDirectLaunchPrefix == prefix && startupController.bindingHotKeyProblem == nil,"startup retry restores the complete prefix after external conflicts clear")
                    if let blockedMain {
                        let before = startupController.configuration, keysBefore = startupController.bindingHotKeys.shortcuts
                        let diskBefore = try Data(contentsOf:startupController.store.url)
                        let retryWhileBlocked = startupController.updateSettings { $0.hotKey = blockedMain }
                        let diskAfter = try Data(contentsOf:startupController.store.url)
                        check(!retryWhileBlocked && startupController.hotKey.choice == nil && startupController.configuration == before && startupController.bindingHotKeys.shortcuts == keysBefore && diskBefore == diskAfter,"reselecting an occupied startup shortcut reports failure and preserves current registrations")
                        mainBlocker.unregister()
                        let retried = startupController.updateSettings { $0.hotKey = blockedMain }
                        check(retried && startupController.hotKey.choice == blockedMain && startupController.hotKeyProblem == nil && startupController.bindingHotKeys.shortcuts == keysBefore,"reselecting the same saved shortcut genuinely retries a failed startup registration")
                        startupController.hotKey.unregister()
                        let damaged = Data("startup retry save failure".utf8); try damaged.write(to:startupController.store.url)
                        let saved = startupController.updateSettings { $0.hotKey = blockedMain }
                        let preserved = try Data(contentsOf:startupController.store.url)
                        check(!saved && startupController.hotKey.choice == nil && startupController.bindingHotKeys.shortcuts == keysBefore && preserved == damaged,"failed retry persistence restores the prior unregistered main shortcut state")
                    } else { print("SKIP main shortcut retry fixture: all available Space combinations are already occupied") }
                } else { print("SKIP startup partial-registration fixture chord occupied (\(blockerStatus))") }
            }
            // Every new shortcut fixture owns a separate temporary configuration.
            // Do not send a system key or register the reference app's Option F/G.
            let shortcutController = LauncherController(dataDirectory:temporary.appendingPathComponent("shortcut-config"))
            shortcutController.configurePanel(); shortcutController.lastScan = Date()
            let shortcutBlocker = GlobalBindingHotKeys()
            defer {
                shortcutBlocker.unregister(); shortcutController.bindingHotKeys.unregister(); shortcutController.hotKey.unregister()
                shortcutController.panel.orderOut(nil); shortcutController.toastTask?.cancel()
            }
            var shortcutFixture = LauncherConfiguration()
            shortcutFixture.settings.workbenchHotKey=nil
            shortcutFixture.bindings = ["=":KeyBinding(target:TargetResolver.target(kind:.shell,url:quoted)),"-":KeyBinding(target:TargetResolver.target(kind:.shell,url:quoted))]
            let independentChord = BindingHotKey(keyCode:64,control:true,option:true,shift:true,command:true)
            shortcutFixture.bindingHotKeys["="] = independentChord
            let shortcutFixtureSaved = shortcutController.save(shortcutFixture)
            check(shortcutFixtureSaved,"isolated shortcut fixture registers its existing independent shortcut")
            if shortcutFixtureSaved {
                let prefix = KeyShortcutPrefix(control:true,option:true,shift:true,command:true)
                let generatedChord = prefix.shortcut(for:"-")!
                let beforePrefix = shortcutController.configuration, beforePrefixKeys = shortcutController.bindingHotKeys.shortcuts
                let beforePrefixData = try Data(contentsOf:shortcutController.store.url)
                let blockedPrefix = shortcutBlocker.register(["D":generatedChord])
                if blockedPrefix == 0 {
                    let accepted = shortcutController.setDirectLaunchPrefix(prefix)
                    let stored = try Data(contentsOf:shortcutController.store.url)
                    check(!accepted && shortcutController.configuration == beforePrefix && shortcutController.bindingHotKeys.shortcuts == beforePrefixKeys && stored == beforePrefixData,"external prefix conflict rolls back configuration disk and active shortcuts")
                } else { print("SKIP prefix conflict fixture chord occupied (\(blockedPrefix))") }
                shortcutBlocker.unregister()
                let prefixEnabled = shortcutController.setDirectLaunchPrefix(prefix)
                check(prefixEnabled && shortcutController.bindingHotKeys.shortcuts["="] == independentChord && shortcutController.bindingHotKeys.shortcuts["-"] == generatedChord && shortcutController.activeDirectLaunchPrefix == prefix,"shared prefix registers bound keys while independent shortcut remains authoritative")
                let applicationChord = BindingHotKey(keyCode:90,control:true,option:true,shift:true,command:true)
                let beforeApplication = shortcutController.configuration, beforeApplicationKeys = shortcutController.bindingHotKeys.shortcuts
                let beforeApplicationData = try Data(contentsOf:shortcutController.store.url)
                let blockedApplication = shortcutBlocker.register(["D":applicationChord])
                if blockedApplication == 0 {
                    let accepted = shortcutController.setApplicationViewHotKey(applicationChord)
                    let stored = try Data(contentsOf:shortcutController.store.url)
                    check(!accepted && shortcutController.configuration == beforeApplication && shortcutController.bindingHotKeys.shortcuts == beforeApplicationKeys && stored == beforeApplicationData,"external application shortcut conflict preserves prefix and independent shortcuts")
                } else { print("SKIP application shortcut fixture chord occupied (\(blockedApplication))") }
                shortcutBlocker.unregister()
                let applicationEnabled = shortcutController.setApplicationViewHotKey(applicationChord)
                check(applicationEnabled && shortcutController.bindingHotKeys.shortcuts[GlobalBindingHotKeys.applicationViewKey] == applicationChord && shortcutController.applicationViewHotKeyTitle == applicationChord.title,"application view shortcut registers as a separate real action")
                if applicationEnabled {
                    shortcutController.activateGlobalShortcut(GlobalBindingHotKeys.applicationViewKey)
                    check(shortcutController.panel.isVisible && shortcutController.searchView,"application shortcut action directly opens the application view without sending system keys")
                    shortcutController.activateGlobalShortcut(GlobalBindingHotKeys.applicationViewKey)
                    check(!shortcutController.panel.isVisible,"repeating application shortcut action closes its own panel")
                }
                check(shortcutController.setDirectLaunchPrefix(nil) && shortcutController.activeDirectLaunchPrefix == nil && shortcutController.bindingHotKeys.shortcuts["-"] == nil && shortcutController.bindingHotKeys.shortcuts["="] == independentChord && shortcutController.bindingHotKeys.shortcuts[GlobalBindingHotKeys.applicationViewKey] == applicationChord,"disabling shared prefix retains independent and application shortcuts")
                if shortcutController.setDirectLaunchPrefix(prefix) {
                    let beforeDiskFailure = shortcutController.configuration, beforeDiskFailureKeys = shortcutController.bindingHotKeys.shortcuts
                    let damagedShortcutData = Data("damaged shortcut fixture".utf8)
                    try damagedShortcutData.write(to:shortcutController.store.url)
                    let accepted = shortcutController.setDirectLaunchPrefix(nil)
                    let stored = try Data(contentsOf:shortcutController.store.url)
                    check(!accepted && shortcutController.configuration == beforeDiskFailure && shortcutController.bindingHotKeys.shortcuts == beforeDiskFailureKeys && stored == damagedShortcutData,"failed shortcut save restores shared prefix and preserves damaged temporary data")
                }
            }
            let bindingKeys = GlobalBindingHotKeys()
            defer { bindingKeys.unregister() }
            let originalChord = BindingHotKey(keyCode:105,control:true,option:true,shift:true,command:true)
            let registered = bindingKeys.register(["D":originalChord])
            if registered == 0 {
                let blocker = GlobalHotKey(); defer { blocker.unregister() }
                let blocked = blocker.register(.controlOptionSpace)
                if blocked == 0 {
                    let conflict = BindingHotKey(keyCode:49,control:true,option:true)
                    check(bindingKeys.register(["D":conflict]) != 0 && bindingKeys.shortcuts["D"] == originalChord,"per-binding hotkey conflict retains its prior registered shortcut")
                } else { print("SKIP per-binding hotkey fixture conflict chord occupied (\(blocked))") }
            } else { print("SKIP per-binding hotkey fixture chord occupied (\(registered))") }
            let first = GlobalHotKey(), second = GlobalHotKey()
            defer { first.unregister(); second.unregister() }
            let one = first.register(.controlOptionSpace), two = second.register(.optionSpace)
            if one == 0 && two == 0 {
                check(second.register(.controlOptionSpace) != 0 && second.choice == .optionSpace,"hotkey conflict retains the previous registered combination")
            } else { print("SKIP hotkey collision fixture: one of the test chords is already in use (\(one), \(two))") }
            controller.panel.orderOut(nil); controller.toastTask?.cancel()
        } catch { failures += 1; print("FAIL native check: \(error.localizedDescription)") }
        let workbenchChecks = await WorkbenchNativeChecks.run()
        count += workbenchChecks.count; failures += workbenchChecks.failures
        let nativeControlHitChecks=await WorkbenchNativeControlHitChecks.run()
        count += nativeControlHitChecks.count;failures += nativeControlHitChecks.failures
        let deviceCardActionChecks=await DeviceCardActionInteractionChecks.run()
        count += deviceCardActionChecks.count;failures += deviceCardActionChecks.failures
        let shortcutChecks=WorkbenchShortcutChecks.run()
        count += shortcutChecks.count; failures += shortcutChecks.failures
        let shortcutResponderChecks=await WorkbenchShortcutResponderChecks.run()
        count += shortcutResponderChecks.count;failures += shortcutResponderChecks.failures
        let calendarMigrationChecks=await CalendarMigrationChecks.run()
        count += calendarMigrationChecks.count; failures += calendarMigrationChecks.failures
        let modalChecks=await WorkbenchModalChecks.run()
        count += modalChecks.count;failures += modalChecks.failures
        let contextChecks=await WorkbenchContextChecks.run()
        count += contextChecks.count;failures += contextChecks.failures
        let contextDraftChecks=await WorkbenchContextDraftChecks.run()
        count += contextDraftChecks.count;failures += contextDraftChecks.failures
        let updateChecks=await AppUpdateChecks.run()
        count += updateChecks.count;failures += updateChecks.failures
        let dateInputChecks=await WorkbenchDateInputChecks.run()
        count += dateInputChecks.count;failures += dateInputChecks.failures
        let aiNativeChecks=await AIUsageNativeChecks.run()
        count += aiNativeChecks.count;failures += aiNativeChecks.failures
        let notificationChecks=await NotificationNavigationChecks.run()
        count += notificationChecks.count;failures += notificationChecks.failures
        let launcherShortcutChecks=LauncherShortcutChecks.run()
        count += launcherShortcutChecks.count;failures += launcherShortcutChecks.failures
        let launcherPresentationChecks=LauncherPresentationNativeChecks.run()
        count += launcherPresentationChecks.count;failures += launcherPresentationChecks.failures
        let launcherSettingsChecks=await WorkbenchLauncherSettingsChecks.run()
        count += launcherSettingsChecks.count;failures += launcherSettingsChecks.failures
        let cleaningModelChecks=await SpaceCleaningModelChecks.run()
        count += cleaningModelChecks.count;failures += cleaningModelChecks.failures
        let cleaningNativeChecks=await SpaceCleaningNativeChecks.run()
        count += cleaningNativeChecks.count;failures += cleaningNativeChecks.failures
        let quitChecks=await WorkbenchQuitChecks.run()
        count += quitChecks.count;failures += quitChecks.failures
        print("Native checks: \(count) checks, \(failures) failures")
        return failures
    }
}
