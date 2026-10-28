import AppKit
import LauncherCore

/// Called by NativeChecks.run(). All models use disposable local directories and
/// disabled/fake external providers. No login registration or permission request occurs.
@MainActor
enum WorkbenchNativeChecks {
    static func run() async -> (count:Int,failures:Int) {
        var checks = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-workbench-native-\(UUID().uuidString)")
        let oldOpacity = Palette.glassOpacity, oldLight = Palette.isLight
        defer {
            Palette.glassOpacity = oldOpacity; Palette.isLight = oldLight
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let owner = LauncherController(dataDirectory: directory.appendingPathComponent("Launcher"))
            try owner.store.save(owner.configuration)
            owner.configurePanel(); owner.scanning = true // This fixture must not scan real installed apps.
            check(owner.background.layer?.cornerRadius == 12, "launcher normal window uses the smaller 12 pt outer radius")
            owner.background.fullScreen = true
            check(owner.background.layer?.cornerRadius == 0, "launcher expanded window removes the outer radius")
            owner.background.fullScreen = false

            let system = WorkbenchCheckCalendar(), notifications = WorkbenchCheckNotifications()
            let calendar = CalendarModel(dataDirectory: directory.appendingPathComponent("Calendar"), system: system, notifier: notifications)
            let aiDirectory = directory.appendingPathComponent("AI"), sourceDirectory = aiDirectory.appendingPathComponent("AIUsage")
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let sources = AIProvider.allCases.map {
                AIUsageSourceConfiguration(provider: $0, enabled: false,
                    sessionsPath: directory.appendingPathComponent("disabled-\($0.rawValue)").path,
                    quotaPath: nil, manualSnapshot: nil)
            }
            try JSONEncoder().encode(sources).write(to: sourceDirectory.appendingPathComponent("sources.json"))
            let ai = AIUsageModel(dataDirectory: aiDirectory)
            let model = WorkbenchAppModel(owner: owner, calendar: calendar, ai: ai, startServices: false)
            let workbench = WorkbenchWindowController(owner: owner, model: model, autosavesFrame: false)
            owner.workbenchController = workbench
            let settings = LauncherSettingsWindowController(owner: owner, autosavesFrame: false)
            owner.settingsWindowController = settings
            defer {
                owner.closeOverlay(render: false); settings.stopEmbedding(); settings.close(); owner.panel.orderOut(nil)
                workbench.window?.close(); model.shutdown()
                owner.workbenchController = nil; owner.settingsWindowController = nil
                owner.hotKey.unregister(); owner.bindingHotKeys.unregister(); owner.toastTask?.cancel()
            }

            owner.showWorkbench(route: .overview)
            let hostReady: Bool
            if let window = workbench.window, let host = window.contentView {
                hostReady = await NativeUIFixtureWindow.prepare(window: window) {
                    descendants(host).compactMap { $0 as? NSScrollView }.contains { scroll in
                        guard scroll.window === window, !scroll.isHiddenOrHasHiddenAncestor,
                              let document = scroll.documentView, document.window === window else { return false }
                        return scroll.contentSize.width > 0 && scroll.contentSize.height > 0
                            && document.bounds.width > 0 && document.bounds.height > 0
                    }
                }
            } else { hostReady = false }
            check(hostReady, "production workbench host becomes active and key with its real page viewport and document mounted")
            check(owner.workbenchController === workbench && workbench.model === model && workbench.window?.isVisible == true && !owner.panel.isVisible,
                  "workbench opens in the same controller with the injected isolated models")
            if let window = workbench.window {
                let responsive = await WorkbenchResponsiveLayoutChecks.run(model:model,window:window)
                checks += responsive.count; failures += responsive.failures
                let detailLayout = await DeviceDetailLayoutChecks.run(model:model,window:window)
                checks += detailLayout.count; failures += detailLayout.failures
                let messageRefresh = await WorkbenchMessageRefreshChecks.run(model:model,window:window)
                checks += messageRefresh.count; failures += messageRefresh.failures
                let processDialog = await DeviceProcessDialogChecks.run(model:model,window:window)
                checks += processDialog.count; failures += processDialog.failures
                let recordsDialog = await NetworkRecordsDialogChecks.run(model:model,window:window)
                checks += recordsDialog.count; failures += recordsDialog.failures
                let nativeCancel = await WorkbenchCancelOperationChecks.run(model:model,workbench:workbench,owner:owner)
                checks += nativeCancel.count; failures += nativeCancel.failures
            }
            model.launcher()
            check(owner.panel.isVisible && owner.workbenchController === workbench,
                  "workbench launcher action opens the existing launcher without another process or controller")
            if let gear = descendants(owner.content).compactMap({ $0 as? ActionButton }).first(where: { $0.accessibilityLabel() == "启动器设置" }) {
                gear.performClick(nil)
                await settle()
                check(model.route == .settings && model.settingsTab == .launcher && !owner.panel.isVisible && workbench.window?.isVisible == true,
                      "the actual launcher gear opens the embedded launcher settings page")
            } else { check(false, "launcher gear exists for workbench integration") }

            let recorder = await findRecorder(in: workbench.window)
            if let recorder,let window=workbench.window {
                check(recorder.window === window && settings.window?.isVisible != true && settings.window !== window,
                      "launcher shortcut control lives in the real workbench settings page without a second window")
                for (passed,name) in await checkLauncherSettingsResizing(window:window,recorder:recorder) {check(passed,name)}
                let unchanged=try Data(contentsOf:owner.store.url)
                recorder.performClick(nil)
                let session=await findActiveRecorder(owner:owner)
                check(session?.target == .launcher && session?.isPresented == true && model.modals.top?.width == 470 && window.attachedSheet == nil,
                      "clicking the actual launcher shortcut control starts its real centered recording dialog")
                // A prohibited-activation self-check cannot create a real app focus
                // transition. Deliver AppKit's production notification and delegate
                // lifecycle instead; the recorder subscribes to the former.
                let ownsWindowLifecycle=window.delegate === workbench
                workbench.windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification,object:window))
                NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:window)
                await settle()
                let unrelated=key(window:window,keyCode:15,characters:"r",flags:[.control,.option])
                let rejected=session?.handleEvent(unrelated) == false && session?.captureRegisteredHotKey(BindingHotKey(keyCode:15,control:true,option:true)) == false && session?.save() == false
                let afterFocusLoss=try Data(contentsOf:owner.store.url)
                check(ownsWindowLifecycle && session?.isPresented == false && owner.workbenchShortcutRecorder == nil && rejected && afterFocusLoss == unchanged,
                      "losing workbench focus cancels launcher recording and rejects later key events and writes")

                workbench.present(route:.settings,settingsTab:.launcher)
                if let currentRecorder=await findRecorder(in:window) {
                    let beforeNavigation=try Data(contentsOf:owner.store.url)
                    currentRecorder.performClick(nil)
                    let active=await findActiveRecorder(owner:owner)
                    let didBegin=active?.isPresented == true && active?.target == .launcher
                    active?.acceptCandidate(BindingHotKey(keyCode:15,control:true,option:true))
                    model.navigate(.overview)
                    check(didBegin && model.route == .settings && active?.isPresented == true,
                          "an active launcher recording dialog blocks page navigation until its draft is safely closed")
                    // Settings changes can also originate outside the sidebar. A
                    // real settings subtree removal must cancel this exact session.
                    model.settingsTab = .general
                    for _ in 0..<6 {window.contentView?.layoutSubtreeIfNeeded();await settle()}
                    model.navigate(.overview)
                    let afterNavigation=try Data(contentsOf:owner.store.url)
                    check(didBegin && active?.isPresented == false && owner.workbenchShortcutRecorder == nil && active?.handleEvent(unrelated) == false && model.route == .overview && afterNavigation == beforeNavigation,
                          "leaving launcher settings cancels its captured candidate without changing stored shortcuts")
                } else {check(false,"launcher shortcut trigger remains available after a focus transition")}
            } else {check(false,"the real launcher shortcut trigger is present in the native settings hierarchy")}

            owner.allSettingsFromMenu()
            check(model.route == .settings && model.settingsTab == .general && owner.workbenchController === workbench,
                  "general settings and launcher settings share the existing workbench")

            workbench.present(route:.settings,settingsTab:.material)
            let materialSlider: NSSlider?
            if let window = workbench.window {materialSlider = await findMountedOpacitySlider(in: window)}
            else {materialSlider = nil}
            if let window=workbench.window,let root=window.contentView,
               let control=materialSlider {
                let point=control.convert(NSPoint(x:control.bounds.midX,y:control.bounds.midY),to:root.superview)
                let hit=root.hitTest(point)
                check(hit === control || hit?.isDescendant(of:control) == true,"material slider receives pointer hit testing through the shared surfaces")
                print("DETAIL material hit=\(hit.map{String(describing:type(of:$0))} ?? "nil") windowKey=\(window.isKeyWindow) acceptedFocus=\(window.makeFirstResponder(control))")
                print("DETAIL material slider point=\(point) frame=\(control.frame) bounds=\(control.bounds) hidden=\(control.isHiddenOrHasHiddenAncestor) enabled=\(control.isEnabled)")
                print("DETAIL material descendant=\(hit.map{control.isDescendant(of:$0)} ?? false) modal=\(model.modals.isPresented) confirming=\(model.confirmingQuit) quitting=\(model.quitting)")
                if let hit {var ancestor:NSView?=hit;var path:[String]=[];while let current=ancestor {path.append("\(type(of:current)) \(current.frame)");ancestor=current.superview};print("DETAIL material hit path="+path.joined(separator:" / "))}
                var sliderAncestor:NSView?=control
                while let current=sliderAncestor,let parent=current.superview {
                    let local=control.convert(NSPoint(x:control.bounds.midX,y:control.bounds.midY),to:parent)
                    let result=current.hitTest(local)
                    print("DETAIL slider ancestor \(type(of:current)) frame=\(current.frame) point=\(local) hit=\(result.map{String(describing:type(of:$0))} ?? "nil")")
                    sliderAncestor=parent
                }
                let before=control.doubleValue
                let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:124)!
                control.keyDown(with:key)
                check(abs(control.doubleValue-min(0.90,before+0.01))<0.000_001 && abs(model.opacity-control.doubleValue)<0.000_001,"material slider keyboard step saves through its live settings binding")
                model.changeOpacity(0.70)
            } else {check(false,"workbench material slider exists in the production view hierarchy")}

            if let window = workbench.window {
                workbench.present(route: .calendar, settingsTab: .launcher)
                let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
                sheet.isReleasedWhenClosed = false
                window.beginSheet(sheet,completionHandler:nil)
                defer { if window.attachedSheet === sheet { window.endSheet(sheet) }; sheet.close() }
                owner.allSettingsFromMenu()
                check(window.attachedSheet === sheet && model.route == .calendar && model.settingsTab == .launcher,
                      "external settings navigation preserves the route and tab while a real workbench sheet is attached")
                model.navigate(.overview)
                check(window.attachedSheet === sheet && model.route == .calendar,
                      "model navigation cannot discard a workbench page underneath its attached sheet")
                model.closeWindow?()
                for _ in 0..<12 {await settle()}
                check(!window.isVisible && window.attachedSheet === sheet && model.route == .calendar && !model.windowVisible,
                      "custom close hides the native parent and attached form without discarding its route")
                workbench.present()
                await settle()
                check(window.isVisible && window.attachedSheet === sheet && model.route == .calendar && model.windowVisible,
                      "reopening restores the same native form and host rather than a second window")
                window.endSheet(sheet); sheet.orderOut(nil)
                for _ in 0..<40 where window.attachedSheet != nil { await settle() }
                model.navigate(.overview)
                let resumed = model.route == .overview
                owner.allSettingsFromMenu()
                check(resumed && model.route == .settings && model.settingsTab == .general,
                      "ending the workbench sheet restores model and external settings navigation")
            } else { check(false, "workbench window exists for sheet navigation protection") }

            model.navigate(.vault)
            let created=await model.vault.create(password:"v5-isolated-window-check",confirmation:"v5-isolated-window-check")
            check(created && model.vault.isUnlocked,"isolated vault is unlocked before the native minimize lifecycle")
            if let window=workbench.window {
                let previousSession=model.vault.sessionID
                workbench.windowDidMiniaturize(Notification(name:NSWindow.didMiniaturizeNotification,object:window))
                check(!model.vault.isUnlocked && model.vault.documents.isEmpty && model.vault.sessionID != previousSession && !model.windowVisible,
                      "native minimize clears decrypted documents and changes the password input session")
                workbench.windowDidDeminiaturize(Notification(name:NSWindow.didDeminiaturizeNotification,object:window))
                check(model.windowVisible && !model.vault.isUnlocked,"restoring a minimized window keeps the private space locked")
            }
            model.navigate(.settings)
            model.settingsTab = .material
            model.changeTheme(.thunderCabin)
            let themed=try XCTValue(owner.store.load())
            check(model.theme == .thunderCabin && themed.settings.workbenchTheme == .thunderCabin,"theme selection persists through the actual native model action")
            model.changeTheme(.arWorld)
            model.requestQuit()
            check(model.confirmingQuit && workbench.window?.isVisible == true,"quit is a separate visible confirmation rather than immediate process termination")
            model.confirmingQuit=false

            do {
                // This renderer/keyboard fixture owns its temporary launcher and
                // popup. Native activation handoffs must not trigger the separate
                // auto-hide feature while these controls are being exercised.
                let previousFocusTransition = owner.focusTransitionUntil
                owner.focusTransitionUntil = .distantFuture
                defer { owner.focusTransitionUntil = previousFocusTransition }
                // Observe actual renderer output rather than copying its opacity formula into a test.
                Palette.isLight = false
                owner.show()
                if let trigger = descendants(owner.content).compactMap({ $0 as? ActionButton }).first(where: { $0.accessibilityLabel() == "全局透明度" }) {
                    trigger.performClick(nil)
                }
                let opacityControlReady: Bool
                if let popup = owner.editorPanel {opacityControlReady = await findMountedOpacitySlider(in: popup) != nil}
                else {opacityControlReady = false}
                let opacityCard = (owner.editorPanel?.contentView as? BindingPopoverSurface)?.card as? GlobalOpacityMenuView
                check(opacityControlReady && opacityCard != nil && opacityCard?.window === owner.editorPanel && owner.editorPanel?.isVisible == true && owner.menu == nil,
                      "the launcher opacity control opens its native glass popover rather than a system menu")
                if let slider = opacityCard?.slider {
                    slider.doubleValue = 0.55
                    let actionSent = slider.action.map { NSApp.sendAction($0, to: slider.target, from: slider) } ?? false
                    let saved = try owner.store.load()
                    check(actionSent && saved?.settings.glassOpacity == 0.55 && owner.configuration.settings.glassOpacity == 0.55,
                          "the opacity popover slider saves through its actual native control action")
                } else { check(false, "the native opacity popover exposes its working slider") }
                let tints = owner.editorPanel?.contentView.map { descendants($0).compactMap { $0 as? GlassTint } } ?? []
                check(!tints.isEmpty, "global appearance fixture contains the production glass tint renderer")
                tints.forEach { $0.needsDisplay = false }
                let lowSaved = owner.setGlobalGlassOpacity(0.50)
                // Layer-backed AppKit views may transfer their display request to CALayer
                // before this read; either pending invalidation is a real redraw request.
                let invalidated = tints.contains { $0.needsDisplay || $0.layer?.needsDisplay() == true }
                let lowPixel = tints.first.flatMap(renderCenterAlpha)
                if !lowSaved || !invalidated {
                    let registered = owner.editorPanel.map { panel in NSApp.windows.contains { $0 === panel } } ?? false
                    print("DETAIL opacity redraw: saved=\(lowSaved), tints=\(tints.count), popupRegistered=\(registered), invalidated=\(invalidated)")
                }
                check(lowSaved && invalidated, "global opacity entry invalidates existing native glass surfaces")
                let highSaved = owner.setGlobalGlassOpacity(0.90)
                let highPixel = tints.first.flatMap(renderCenterAlpha)
                let persisted = try XCTValue(owner.store.load())
                check(highSaved && abs(persisted.settings.glassOpacity - 0.90) < 0.000_001 && abs(Palette.glassOpacity - 0.90) < 0.000_001,
                      "global opacity persists through an independent load and updates the live palette")
                check(lowPixel != nil && highPixel != nil && highPixel! > lowPixel! + 0.20,
                      "higher global opacity changes the actual tint bitmap instead of only a stored number")
                await settle()
                check(abs(model.opacity - 0.90) < 0.000_001, "workbench appearance observes launcher configuration updates")
                if let popup = owner.editorPanel {
                    let before = "launcherVisible=\(owner.panel.isVisible), popupVisible=\(popup.isVisible), popupKey=\(popup.isKeyWindow), active=\(NSApp.isActive), picker=\(owner.pickerActive), menu=\(owner.menu != nil), responder=\(String(describing: popup.firstResponder)), marked=\((popup.firstResponder as? NSTextView)?.hasMarkedText() == true)"
                    let dismissed = owner.route(key(window: popup, keyCode: 53, characters: "\u{1b}", flags: []))
                    if !dismissed || owner.editorPanel != nil || !owner.panel.isVisible {
                        print("DETAIL opacity Escape before=[\(before)] after=[handled=\(dismissed), editorPanelPresent=\(owner.editorPanel != nil), launcherVisible=\(owner.panel.isVisible), launcherKey=\(owner.panel.isKeyWindow), quitting=\(model.quitting)]")
                    }
                    check(dismissed && owner.editorPanel == nil && owner.panel.isVisible,
                          "Escape closes the opacity popover while leaving the launcher open")
                } else { check(false, "opacity popover remains available for keyboard dismissal") }
            }

            let validBytes = try Data(contentsOf: owner.store.url)
            for invalid in [Double.nan, Double.infinity, -Double.infinity, 0.499, 0.901] {
                let rejected = !owner.setGlobalGlassOpacity(invalid)
                let afterInvalid = try Data(contentsOf: owner.store.url)
                check(rejected && owner.configuration.settings.glassOpacity == 0.90 && Palette.glassOpacity == 0.90 && afterInvalid == validBytes,
                      "invalid opacity \(invalid) cannot mutate the palette or configuration file")
            }
            let corrupt = Data("workbench opacity write failure fixture".utf8)
            try corrupt.write(to: owner.store.url)
            let failed = !owner.setGlobalGlassOpacity(0.75)
            let afterFailure = try Data(contentsOf: owner.store.url)
            check(failed && owner.configuration.settings.glassOpacity == 0.90 && Palette.glassOpacity == 0.90 && afterFailure == corrupt,
                  "an opacity save failure preserves both live appearance and corrupt configuration for recovery")
            try validBytes.write(to: owner.store.url)

            await settle()
            check(system.permissionRequests == 0 && system.reads == 0 && system.writes == 0 && notifications.permissionRequests == 0,
                  "navigation tests never request permissions or read and write real calendar data")
            check(ai.configurations.allSatisfy { !$0.enabled && $0.sessionsPath.hasPrefix(directory.path + "/") } && ai.records.isEmpty,
                  "AI navigation uses only disabled temporary sources and never real account metadata")
            check(!model.device.isSampling, "isolated workbench construction does not start the background device loop")
        } catch {
            check(false, "workbench native fixture failed: \(error.localizedDescription)")
        }
        print("Workbench native checks: \(checks - failures)/\(checks) passed")
        return (checks,failures)
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    /// SwiftUI mounts its AppKit control asynchronously after a route change.
    /// Wait for the production control to be attached and laid out, rather than
    /// assuming that one 25 ms UI turn is sufficient in every signed build.
    private static func findMountedOpacitySlider(in window: NSWindow) async -> NSSlider? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if let root = window.contentView,
               let slider = descendants(root).compactMap({ $0 as? NSSlider }).first(where: {
                   $0.accessibilityLabel() == "界面不透明度" && $0.window === window
                       && !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled
                       && $0.bounds.width > 0 && $0.bounds.height > 0
               }) {
                await settle()
                root.layoutSubtreeIfNeeded()
                if slider.window === window && !slider.isHiddenOrHasHiddenAncestor && slider.isEnabled
                    && slider.bounds.width > 0 && slider.bounds.height > 0 {return slider}
            }
            await settle()
        } while ContinuousClock.now < deadline
        print("DETAIL opacity slider readiness timed out: visible=\(window.isVisible), key=\(window.isKeyWindow), root=\(String(describing: window.contentView)), policy=\(NSApp.activationPolicy().rawValue)")
        return nil
    }
    private static func checkLauncherSettingsResizing(window:NSWindow,recorder:NSButton) async -> [(Bool,String)] {
        guard let root=window.contentView else {return [(false,"launcher recorder has a real window hierarchy for resizing")]}
        let originalFrame=window.frame
        defer {window.setFrame(originalFrame,display:true)}
        let focused=window.makeFirstResponder(recorder)
        var checks:[(Bool,String)]=[]
        var measurements:[(rootWidth:CGFloat,buttonX:CGFloat,referenceRight:CGFloat,rightInset:CGFloat)]=[]
        var maximumAncestorScrolls=0
        for requestedWidth in [CGFloat(900),1040,1400] {
            window.setContentSize(NSSize(width:requestedWidth,height:700))
            for _ in 0..<6 {root.layoutSubtreeIfNeeded();await settle()}
            let current=descendants(root).compactMap{$0 as? NSButton}.first{$0.accessibilityLabel() == "设置启动器快捷键"}
            checks.append((focused && current === recorder && recorder.window === window && window.firstResponder === recorder,
                "resizing the workbench to \(Int(requestedWidth)) preserves the real launcher trigger instance and keyboard focus"))
            let rect=recorder.convert(recorder.bounds,to:root)
            let visible=recorder.visibleRect.intersection(recorder.bounds)
            let anchor=descendants(root).compactMap{$0 as? NSPopUpButton}.first{$0.accessibilityLabel() == "默认视图"}
            let anchorRect=anchor.map{$0.convert($0.bounds,to:root)} ?? .zero
            let contained=root.bounds.insetBy(dx:-0.5,dy:-0.5).contains(rect)
            let reachable=recorder.isEnabled && !recorder.isHiddenOrHasHiddenAncestor && rect.width>0 && rect.height == 28 && visible.width >= recorder.bounds.width-1 && visible.height >= recorder.bounds.height-1
            checks.append((contained && reachable && anchor != nil && abs(rect.maxX-anchorRect.maxX)<2,
                "resizing the workbench to \(Int(requestedWidth)) keeps the 28 pt shortcut trigger reachable and aligned with its actual form controls"))
            measurements.append((root.bounds.width,rect.minX,anchorRect.maxX,anchorRect.maxX-rect.maxX))
            var view=recorder.superview,ancestorScrolls=0
            while let current=view {if current is NSScrollView {ancestorScrolls += 1};view=current.superview}
            maximumAncestorScrolls=max(maximumAncestorScrolls,ancestorScrolls)
        }
        let followsTrailingEdge=zip(measurements,measurements.dropFirst()).allSatisfy{before,after in
            let growth=after.referenceRight-before.referenceRight
            return after.rootWidth>before.rootWidth && growth>20 && abs((after.buttonX-before.buttonX)-growth)<2 && abs(after.rightInset-before.rightInset)<2
        }
        checks.append((measurements.count == 3 && followsTrailingEdge,
            "the real launcher settings page expands and its shortcut trigger follows the shared form trailing edge"))
        checks.append((maximumAncestorScrolls == 1,
            "launcher settings uses the shared page scroller without a nested whole-page scroll view"))
        if !checks.allSatisfy({$0.0}) {print("DETAIL launcher resize: focused=\(focused), geometry=\(measurements), scrollAncestors=\(maximumAncestorScrolls)")}
        window.setFrame(originalFrame,display:true)
        for _ in 0..<3 {root.layoutSubtreeIfNeeded();await settle()}
        return checks
    }
    private static func findActiveRecorder(owner:LauncherController) async -> WorkbenchShortcutRecorder? {
        for _ in 0..<40 {
            owner.workbenchController?.window?.contentView?.layoutSubtreeIfNeeded()
            if let recorder=owner.workbenchShortcutRecorder,recorder.isPresented,owner.workbenchController?.model.modals.top?.width == 470 {
                for _ in 0..<2 {owner.workbenchController?.window?.contentView?.layoutSubtreeIfNeeded();await settle()}
                return recorder
            }
            await settle()
        }
        return nil
    }
    private static func findRecorder(in window: NSWindow?) async -> NSButton? {
        for _ in 0..<40 {
            window?.contentView?.layoutSubtreeIfNeeded()
            if let root = window?.contentView,
               let recorder = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == "设置启动器快捷键" }) {
                return recorder
            }
            await settle()
        }
        return nil
    }
    private static func settle() async { try? await Task.sleep(for: .milliseconds(25)) }
    private static func key(window: NSWindow, keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }
    private static func renderCenterAlpha(_ tint: GlassTint) -> CGFloat? {
        let oldFrame = tint.frame
        defer { tint.frame = oldFrame }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 120,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context; context.cgContext.clear(CGRect(x: 0, y: 0, width: 120, height: 120))
        tint.frame = NSRect(x: 0, y: 0, width: 120, height: 120)
        tint.draw(tint.bounds); context.flushGraphics()
        return bitmap.colorAt(x: 60, y: 60)?.alphaComponent
    }
    private static func XCTValue<T>(_ value: T?) throws -> T {
        guard let value else { throw LauncherError.storage("测试配置未能重新加载。") }; return value
    }
}

@MainActor private final class WorkbenchCheckCalendar: CalendarSystemProviding {
    var permissionRequests = 0, reads = 0, writes = 0
    func access(reminders: Bool) -> CalendarAccess { .notDetermined }
    func requestAccess(reminders: Bool) async throws -> Bool { permissionRequests += 1; return false }
    func events(in interval: DateInterval) throws -> [CalendarEventItem] { reads += 1; return [] }
    func reminders() async throws -> [ReminderItem] { reads += 1; return [] }
    func writableReminderCalendars() -> [ReminderCalendar] { [] }
    func saveReminder(_ item: ReminderItem, creating: Bool) throws -> ReminderItem { writes += 1; throw ReminderError.unavailable("Isolated fixture") }
    func deleteReminder(_ item: ReminderItem) throws { writes += 1; throw ReminderError.unavailable("Isolated fixture") }
}
@MainActor private final class WorkbenchCheckNotifications: ReminderNotificationProviding {
    var permissionRequests = 0
    func access() async -> CalendarAccess { .notDetermined }
    func requestAccess() async throws -> Bool { permissionRequests += 1; return false }
    func replacePending(_ notifications: [ReminderNotification]) async throws { }
}
