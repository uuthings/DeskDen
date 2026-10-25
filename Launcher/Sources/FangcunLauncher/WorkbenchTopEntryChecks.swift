import AppKit
import LauncherCore

/// Drives the production polling path with an isolated pointer provider.
/// No cursor is moved, no mouse event is synthesized, and account providers remain disabled.
@MainActor enum WorkbenchTopEntryChecks {
    static func run() async -> (count: Int, failures: Int) {
        // Match the real app's background accessory policy when validating
        // WindowServer visibility; .prohibited intentionally forbids UI activation.
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        var count = 0, failures = 0
        func check(_ condition: Bool, _ text: String) {
            count += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(text)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-top-entry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            guard let screen = NSScreen.screens.first else {
                check(false, "top entry integration has a native display")
                return (count, failures)
            }
            let owner = LauncherController(dataDirectory: directory.appendingPathComponent("Launcher"))
            try owner.store.save(owner.configuration)
            owner.configurePanel(); owner.scanning = true
            let calendarSystem = TopEntryCheckCalendar(), notifications = TopEntryCheckNotifications()
            let calendar = CalendarModel(dataDirectory: directory.appendingPathComponent("Calendar"), system: calendarSystem, notifier: notifications)
            let aiDirectory = directory.appendingPathComponent("AI")
            let sourceDirectory = aiDirectory.appendingPathComponent("AIUsage")
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let sources = AIProvider.allCases.map {
                AIUsageSourceConfiguration(provider: $0, enabled: false,
                    sessionsPath: directory.appendingPathComponent("disabled-\($0.rawValue)").path,
                    quotaPath: nil, manualSnapshot: nil)
            }
            try JSONEncoder().encode(sources).write(to: sourceDirectory.appendingPathComponent("sources.json"))
            let model = WorkbenchAppModel(owner: owner, calendar: calendar, ai: AIUsageModel(dataDirectory: aiDirectory), startServices: false)
            let workbench = WorkbenchWindowController(owner: owner, model: model, autosavesFrame: false)
            owner.workbenchController = workbench
            let originalFrame = workbench.window?.frame
            var expectedOrdinaryFrame = workbench.window!.frame
            let originalContent = workbench.window?.contentView
            model.navigate(.settings)
            let outside = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            let top = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
            var pointer = WorkbenchTopEntryInput(location: outside, pressedButtons: 0, uptime: 0)
            var useLiveClock = false
            var providerReads = 0
            let workspaceNotifications = NotificationCenter()
            let controller = WorkbenchTopEntryController(owner: owner, input: {
                providerReads += 1
                var sample = pointer
                if useLiveClock { sample.uptime = ProcessInfo.processInfo.systemUptime }
                return sample
            }, workspaceNotifications: workspaceNotifications, monitorSystemInput: false)
            owner.topEntryController = controller
            defer {
                controller.stop()
                owner.closeOverlay(render: false)
                owner.panel.orderOut(nil)
                workbench.presentationWindow?.orderOut(nil)
                workbench.window?.orderOut(nil)
                model.shutdown()
                owner.workbenchController = nil; owner.topEntryController = nil
                owner.hotKey.unregister(); owner.bindingHotKeys.unregister(); owner.toastTask?.cancel()
            }
            controller.start(automaticPolling: false)
            func poll(_ point: CGPoint, buttons: Int = 0, at time: TimeInterval) {
                pointer = .init(location: point, pressedButtons: buttons, uptime: time)
                controller.poll()
            }
            check(controller.isRunning && controller.preferences.enabled && controller.preferences.mode == .summary,
                  "top entry starts enabled with the compact island as its new default")
            controller.setMode(.workbench)
            poll(outside, at: 0)
            poll(top, buttons: 1, at: 1)
            poll(top, at: 1.4)
            check(model.route == .settings && workbench.presentationWindow?.isVisible != true,
                  "a pressed mouse button suppresses top entry until the pointer leaves")
            poll(outside, at: 2)
            poll(top, at: 3)
            check(controller.isEntryPending && !controller.isHoverFeedbackVisible && workbench.presentationWindow?.isVisible != true,
                  "entering the top edge has invisible intent confirmation without an intermediate surface")
            poll(top, at: 3.1)
            check(workbench.presentationWindow?.isVisible != true, "top entry does not open before its hover dwell")
            poll(top, at: 3.11)
            check(workbench.presentationWindow?.isVisible != true, "a 110 ms pass cannot bypass the 120 ms intent confirmation")
            poll(outside, at: 3.115)
            await settle()
            check(!controller.isHoverFeedbackVisible && workbench.presentationWindow?.isVisible != true,
                  "leaving before dwell cancels the pending reveal")
            poll(top, at: 3.4); poll(top, at: 3.76)
            await waitUntil { workbench.window?.isVisible == true && workbench.window?.alphaValue == 1 }
            guard let ordinary = workbench.window else {
                check(false, "canonical top entry has its ordinary native window")
                return (count, failures)
            }
            check(model.route == .settings && ordinary.isVisible && workbench.presentationWindow === ordinary,
                  "top-edge dwell reveals the same ordinary workbench and preserves its selected page")
            check(NSApp.activationPolicy() == .regular && !model.isTopEntryPresentation && !workbench.isTopEntryPresented,
                  "every complete-workbench top entry participates in Dock and Command-Tab")
            check(!controller.isHoverFeedbackVisible && ordinary.alphaValue == 1,
                  "direct top entry finishes at full opacity without a temporary full-panel handoff")
            check(!(ordinary is NSPanel) && !ordinary.styleMask.contains(.nonactivatingPanel),
                  "complete top entry uses the ordinary activatable window rather than another panel")
            await waitUntil { ordinary.occlusionState.contains(.visible) }
            let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            check(ordinary.isOnActiveSpace && ordinary.occlusionState.contains(.visible)
                  && onScreen.contains { ($0[kCGWindowNumber as String] as? Int) == ordinary.windowNumber },
                  "canonical top entry is actually visible on the active Space and listed by WindowServer")
            check(ordinary.collectionBehavior.contains(.fullScreenPrimary) && ordinary.level == .normal,
                  "canonical top entry keeps normal window level and native full-screen support")
            check(model.hostWindow === ordinary && model.vault.hostWindow === ordinary && model.health.hostWindow === ordinary
                  && model.modals.hostWindow === ordinary && ordinary.contentView === originalContent && ordinary.frame == originalFrame,
                  "top entry preserves one content tree, model, sheet hosts and saved ordinary geometry")
            let ordinaryIdentity = ObjectIdentifier(ordinary), contentIdentity = ordinary.contentView.map(ObjectIdentifier.init)
            poll(top, at: 4)
            poll(outside, at: 4.1); poll(top, at: 4.2); poll(top, at: 4.56)
            check(model.route == .settings && owner.workbenchController === workbench
                  && workbench.presentationWindow.map(ObjectIdentifier.init) == ordinaryIdentity
                  && ordinary.contentView.map(ObjectIdentifier.init) == contentIdentity,
                  "repeated top approaches never create a second window, controller or content tree")
            expectedOrdinaryFrame = ordinary.frame.offsetBy(dx: 12, dy: -8)
            ordinary.setFrame(expectedOrdinaryFrame, display: true)
            owner.workbenchFromMenu()
            owner.showWorkbenchFromTopEntry(originFrame: CGRect(x: top.x - 50, y: top.y - 1, width: 100, height: 1))
            await settle()
            check(workbench.presentationWindow === ordinary && ordinary.frame == expectedOrdinaryFrame && model.route == .settings,
                  "moving the workbench then reopening from menu or top preserves its one window position")
            controller.handleOutsideClick(at: CGPoint(x: ordinary.frame.midX, y: ordinary.frame.midY))
            let child = NSPanel(contentRect: NSRect(x: ordinary.frame.maxX + 8, y: ordinary.frame.midY, width: 100, height: 80),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            child.isReleasedWhenClosed = false
            ordinary.addChildWindow(child, ordered: .above); child.orderFrontRegardless()
            controller.handleOutsideClick(at: CGPoint(x: child.frame.midX, y: child.frame.midY))
            await settle()
            check(ordinary.isVisible && child.isVisible,
                  "ordinary workbench and its owned child survive internal interactions")
            ordinary.removeChildWindow(child); child.orderOut(nil)
            workspaceNotifications.post(name: NSWorkspace.didActivateApplicationNotification,
                object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
            await settle()
            check(ordinary.isVisible, "activation of this app preserves its canonical workbench")
            let externalApplication = NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular
            }
            if let externalApplication {
                workspaceNotifications.post(name: NSWorkspace.didActivateApplicationNotification,
                    object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: externalApplication])
            } else { controller.handleApplicationActivation(processIdentifier: ProcessInfo.processInfo.processIdentifier + 100_000) }
            await settle()
            check(ordinary.isVisible && NSApp.activationPolicy() == .regular && !controller.isQuickSummaryVisible,
                  "another-app activation leaves the complete workbench available in the application switcher")
            controller.handleOutsideClick(at: CGPoint(x: screen.frame.minX + 2, y: screen.frame.minY + 2))
            workspaceNotifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
            await settle()
            check(ordinary.isVisible && model.windowVisible && ordinary.frame == expectedOrdinaryFrame,
                  "outside clicks and Space changes do not auto-hide an ordinary top-opened workbench")
            model.closeWindow?()
            await waitUntil { !ordinary.isVisible }
            check(!ordinary.isVisible && NSApp.activationPolicy() == .accessory,
                  "explicit close alone returns the canonical workbench to background mode")
            poll(outside, at: 6); poll(top, at: 7); poll(top, at: 7.36)
            await waitUntil { ordinary.isVisible && ordinary.alphaValue == 1 }
            check(ordinary.isVisible && workbench.presentationWindow === ordinary && ordinary.frame == expectedOrdinaryFrame
                  && NSApp.activationPolicy() == .regular && ordinary.contentView === originalContent,
                  "close followed by top expansion restores the same positioned window and Dock participation")
            model.closeWindow?()
            await waitUntil { !ordinary.isVisible }
            owner.showWorkbenchFromTopEntry(); model.closeWindow?()
            owner.showWorkbenchFromTopEntry()
            await settle()
            check(ordinary.isVisible && ordinary.alphaValue == 1 && model.windowVisible && workbench.presentationWindow === ordinary,
                  "top reopen during a close fade cancels the stale exit on the same ordinary host")
            model.closeWindow?(); await waitUntil { !ordinary.isVisible }
            poll(outside, at: 10); poll(top, at: 11)
            check(controller.isEntryPending && !controller.isHoverFeedbackVisible, "a new approach begins invisible intent confirmation")
            controller.handleContextChange(animated: false); poll(top, at: 11.5)
            check(!controller.isHoverFeedbackVisible && !ordinary.isVisible,
                  "context changes cancel a pending dwell without reopening the hidden ordinary window")

            // Canonical windows and native drafts remain in place on context changes.
            owner.showWorkbenchFromTopEntry(); await settle(); model.navigate(.settings)
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 150),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            let draft = NSTextField(string: "未保存的顶部入口草稿")
            draft.frame = NSRect(x: 20, y: 60, width: 280, height: 24); sheet.contentView?.addSubview(draft)
            var sheetCompletions = 0
            ordinary.beginSheet(sheet, completionHandler: { _ in sheetCompletions += 1 })
            await settle()
            check(ordinary.attachedSheet === sheet && sheet.isVisible, "the canonical workbench owns its native sheet")
            controller.handleOutsideClick(at: CGPoint(x: sheet.frame.midX, y: sheet.frame.midY))
            controller.handleContextChange(animated: false)
            await settle()
            check(ordinary.isVisible && sheet.isVisible && sheet.sheetParent === ordinary && ordinary.attachedSheet === sheet,
                  "context changes preserve the ordinary parent and attached native sheet")
            check(draft.stringValue == "未保存的顶部入口草稿" && ordinary.contentView === originalContent && model.route == .settings && sheetCompletions == 0,
                  "canonical context changes preserve unsaved sheet input, page and modal session")
            model.closeWindow?(); await waitUntil { !ordinary.isVisible }
            check(!ordinary.isVisible && !sheet.isVisible && ordinary.attachedSheet === sheet && sheet.sheetParent === ordinary
                  && sheetCompletions == 0 && ordinary.contentView === originalContent && NSApp.activationPolicy() == .accessory,
                  "explicit close hides the ordinary sheet family while retaining its attachment and draft")
            owner.showWorkbenchFromTopEntry(); await settle()
            check(ordinary.isVisible && sheet.isVisible && workbench.presentationWindow === ordinary && model.hostWindow === ordinary
                  && draft.stringValue == "未保存的顶部入口草稿" && sheetCompletions == 0 && NSApp.activationPolicy() == .regular,
                  "top expansion after sheet close restores the same native family and regular Dock target")
            ordinary.endSheet(sheet); sheet.orderOut(nil); await settle()
            check(sheetCompletions == 1, "the retained native sheet completes exactly once when explicitly ended")

            let modal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 140),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            modal.isReleasedWhenClosed = false
            let modalDraft = NSTextField(string: "未保存的模态草稿")
            modalDraft.frame = NSRect(x: 16, y: 50, width: 268, height: 24); modal.contentView?.addSubview(modalDraft); modal.center()
            var preservedModalFamily = false, stoppedModalDeliberately = false
            let modalAction = TopEntryModalCheckAction {
                controller.handleContextChange(animated: false)
                poll(outside, at: 12); poll(top, at: 13); poll(top, at: 13.36)
                preservedModalFamily = modal.isVisible && ordinary.isVisible && NSApp.modalWindow === modal
                    && modalDraft.stringValue == "未保存的模态草稿" && workbench.presentationWindow === ordinary
                stoppedModalDeliberately = true; NSApp.stopModal(withCode: .cancel)
            }
            let modalTimer = Timer(timeInterval: 0.15, target: modalAction, selector: #selector(TopEntryModalCheckAction.fire), userInfo: nil, repeats: false)
            RunLoop.main.add(modalTimer, forMode: .modalPanel)
            let modalResponse = NSApp.runModal(for: modal); modalTimer.invalidate()
            check(preservedModalFamily, "context changes and hover polling preserve the same ordinary app-modal family and its unsaved input")
            check(stoppedModalDeliberately && modalResponse == .cancel, "an ordinary app-modal session ends only when explicitly stopped")
            modal.orderOut(nil); await settle()
            model.closeWindow?(); await waitUntil { !ordinary.isVisible }

            controller.setMode(.summary)
            poll(outside, at: 14)
            poll(top, at: 15)
            await settle()
            check(controller.isEntryPending && !controller.isHoverFeedbackVisible && !controller.isQuickSummaryVisible,
                  "mini approach has no visible intermediate notch expansion")
            poll(top, at: 15.13)
            let anticipationWindow = controller.islandWindowNumber
            let expandedTarget = controller.islandTargetFrame
            check(anticipationWindow != nil && controller.isQuickSummaryVisible
                  && expandedTarget.map { abs($0.maxY - screen.frame.maxY) <= 1 } == true,
                  "intent confirmation targets the complete mini card directly at the screen top")
            let notchWidth = screen.auxiliaryTopRightArea.flatMap { right in screen.auxiliaryTopLeftArea.map { right.minX - $0.maxX } } ?? 0
            let miniSize = WorkbenchMiniLayout.size(sectionCount: 4, screenWidth: screen.frame.width,
                                                    safeTop: screen.safeAreaInsets.top, notchWidth: notchWidth)
            check((expandedTarget?.width ?? 0) == miniSize.width && expandedTarget?.height == miniSize.height
                  && (controller.islandContentTopInset ?? -1) >= screen.safeAreaInsets.top,
                  "direct mini information has the intended width and reserves the physical camera area")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                try? await Task.sleep(for: .milliseconds(80))
                let intermediate = controller.islandPresentationFrame
                check(intermediate.map { frame in
                    frame.width > 100 && frame.width < (expandedTarget?.width ?? 0) - 0.5
                        && abs(frame.maxY - screen.frame.maxY) <= 1
                } == true,
                      "the direct transition passes through an intermediate width while keeping its top anchor")
            }
            await settle()
            check(controller.isQuickSummaryVisible && workbench.presentationWindow?.isVisible != true,
                  "summary mode shows the native quick-information panel without opening the workbench")
            check(controller.islandPresentationFrame.map { frame in
                abs(frame.width - (expandedTarget?.width ?? -100)) <= 1
                    && abs(frame.height - (expandedTarget?.height ?? -100)) <= 1
                    && abs(frame.maxY - screen.frame.maxY) <= 1
            } == true,
                  "the rendered mini information reaches its target geometry at the end of expansion")
            let initialOpacity = owner.configuration.settings.glassOpacity
            let initialAppearance = owner.configuration.settings.workbenchAppearance
            _ = owner.setGlobalGlassOpacity(0.82)
            model.changeAppearance(.light)
            controller.refreshAppearance(); model.syncAppearance()
            check(controller.islandMaterialOpacity == 0.82 && controller.islandUsesLightAppearance == true
                  && owner.configuration.settings.workbenchAppearance == .light
                  && controller.islandTargetFrame == expandedTarget
                  && controller.islandPresentationFrame.map { frame in
                      abs(frame.width - (expandedTarget?.width ?? -100)) <= 1
                          && abs(frame.height - (expandedTarget?.height ?? -100)) <= 1
                          && abs(frame.maxY - screen.frame.maxY) <= 1
                  } == true,
                  "mini material follows the shared opacity and appearance while retaining its geometry")
            model.changeAppearance(initialAppearance)
            _ = owner.setGlobalGlassOpacity(initialOpacity)
            controller.refreshAppearance(); model.syncAppearance()
            let initialTheme = owner.configuration.settings.workbenchTheme
            // Modify this isolated fixture in memory; theme coverage must not
            // register global shortcuts or save user preferences as a side effect.
            for theme in LauncherTheme.allCases {
                owner.configuration.settings.workbenchTheme = theme
                model.syncAppearance(); controller.refreshAppearance()
                check(controller.islandTheme == theme && controller.islandMaterialOpacity == initialOpacity
                      && controller.islandTargetFrame == expandedTarget,
                      "mini retains its safe-area geometry and shared material for \(theme.rawValue)")
#if DEBUG
                // Opt-in own-view renders only: no desktop capture, pointer input,
                // personal data, or production-profile changes are involved.
                if let destination = ProcessInfo.processInfo.environment["FANGCUN_MINI_REVIEW_DIRECTORY"], destination.hasPrefix("/tmp/") {
                    for appearance in [LauncherAppearance.dark, .light] {
                        owner.configuration.settings.workbenchAppearance = appearance
                        model.syncAppearance(); controller.refreshAppearance()
                        await settle()
                        let url = URL(fileURLWithPath: destination, isDirectory: true)
                            .appendingPathComponent("mini-\(theme.rawValue)-\(appearance.rawValue).png")
                        try controller.captureMiniReview(to: url)
                        check(NSImage(contentsOf: url) != nil,
                              "mini own-view review render exists for \(theme.rawValue)/\(appearance.rawValue)")
                        print("DETAIL mini own-view review \(url.path)")
                    }
                }
#endif
            }
            owner.configuration.settings.workbenchTheme = initialTheme
            owner.configuration.settings.workbenchAppearance = initialAppearance
            model.syncAppearance(); controller.refreshAppearance()
            controller.handleApplicationActivation(processIdentifier: ProcessInfo.processInfo.processIdentifier + 100_000)
            await settle()
            check(!controller.isQuickSummaryVisible && !ordinary.isVisible && NSApp.activationPolicy() == .accessory,
                  "unlike a complete workbench, the compact Mini still closes on another-app activation")
            poll(outside, at: 15.4); poll(top, at: 15.5); poll(top, at: 15.7)
            await settle()
            if let expandedTarget {
                controller.handleOutsideClick(at: CGPoint(x: expandedTarget.midX, y: expandedTarget.minY + 24))
                check(controller.isQuickSummaryVisible, "a click inside the expanded island preserves its information surface")
            }
            poll(top, at: 15.8); poll(top, at: 16.1)
            check(!controller.isHoverFeedbackVisible && controller.islandWindowNumber == anticipationWindow
                  && controller.islandTargetFrame == expandedTarget,
                  "staying over the open island does not restart anticipation or repeat expansion")
            poll(outside, at: 16.2)
            poll(outside, at: 16.55)
            // Re-enter while closing, before its completion callback can run. The
            // new dwell may reuse the same surface; the old callback must not hide it.
            poll(top, at: 16.56)
            try? await Task.sleep(for: .milliseconds(80))
            poll(top, at: 16.92)
            await settle()
            check(controller.isQuickSummaryVisible && controller.islandWindowNumber == anticipationWindow
                  && controller.islandTargetFrame == expandedTarget,
                  "re-entry during collapse reverses the same surface without a stale completion hiding the new mini")
            poll(outside, at: 17)
            poll(outside, at: 17.35)
            await settle()
            check(!controller.isQuickSummaryVisible, "leaving the top summary closes its native panel after the exit delay")
            poll(top, at: 18); poll(top, at: 18.36)
            await settle()
            controller.handleContextChange(animated: false)
            poll(top, at: 18.8)
            check(!controller.isQuickSummaryVisible && !controller.isHoverFeedbackVisible,
                  "context dismissal closes the quick summary and prevents immediate hover reactivation")
            poll(outside, at: 18.9); poll(top, at: 19); poll(top, at: 19.2)
            await settle()
            check(controller.isQuickSummaryVisible && !ordinary.isVisible,
                  "the compact Mini can reopen while the canonical workbench remains closed")
            owner.showWorkbenchFromTopEntry(originFrame: controller.islandPresentationFrame)
            await settle()
            check(!controller.isQuickSummaryVisible && ordinary.isVisible && workbench.presentationWindow === ordinary
                  && ordinary.frame == expectedOrdinaryFrame && ordinary.contentView === originalContent && NSApp.activationPolicy() == .regular,
                  "expanding Mini restores the same positioned ordinary window, content and Dock target")
            model.closeWindow?(); await waitUntil { !ordinary.isVisible }
            controller.setEnabled(false)
            poll(outside, at: 19); poll(top, at: 20); poll(top, at: 20.4)
            check(!controller.isQuickSummaryVisible && workbench.presentationWindow?.isVisible != true,
                  "disabled top entry does not reveal either native surface")
            controller.setEnabled(true); controller.stop()
            poll(outside, at: 21); poll(top, at: 22); poll(top, at: 22.4)
            check(!controller.isRunning && !controller.isQuickSummaryVisible, "stopping the controller prevents later injected polls")

            // Exercise the default production scheduler, not a direct call to poll().
            // Only the pointer values are injected; time and RunLoop timer delivery are real.
            model.navigate(.settings)
            model.closeWindow?(); await waitUntil { !ordinary.isVisible }
            controller.setMode(.workbench)
            pointer.location = outside; pointer.pressedButtons = 0; useLiveClock = true
            let readsBeforeTimer = providerReads
            controller.start()
            await waitUntil { providerReads >= readsBeforeTimer + 3 }
            let timerFired = providerReads >= readsBeforeTimer + 3
            check(timerFired, "automaticPolling default starts a real common-mode timer that reads the pointer provider")
            if !timerFired { print("DETAIL top-entry automatic providerReads=\(providerReads - readsBeforeTimer), isRunning=\(controller.isRunning)") }
            pointer.location = top
            await waitUntil { workbench.presentationWindow?.isVisible == true }
            check(ordinary.isVisible && workbench.presentationWindow === ordinary && !model.isTopEntryPresentation
                  && NSApp.activationPolicy() == .regular && ordinary.frame == expectedOrdinaryFrame,
                  "automatic timer alone opens the canonical ordinary workbench with Dock participation")
            await waitUntil { (workbench.presentationWindow?.alphaValue ?? 0) >= 0.999 }

            model.navigate(.settings)
            model.closeWindow?(); await waitUntil { !ordinary.isVisible }
            controller.setMode(.summary)
            pointer.location = outside
            let outsideReads = providerReads
            await waitUntil { providerReads >= outsideReads + 3 }
            pointer.location = top
            await waitUntil { controller.isQuickSummaryVisible }
            check(controller.isQuickSummaryVisible && workbench.presentationWindow?.isVisible != true,
                  "automatic timer alone opens the quick summary without direct poll calls")
            pointer.location = outside
            await waitUntil { !controller.isQuickSummaryVisible }
            check(!controller.isQuickSummaryVisible, "automatic timer alone dismisses the quick summary after pointer exit")
            controller.stop()
            let readsAtStop = providerReads
            try? await Task.sleep(for: .milliseconds(200))
            check(providerReads == readsAtStop, "stopping automatic polling invalidates the production timer")
            workbench.present(route: .settings)
            await settle()
            check(workbench.presentationWindow === workbench.window
                  && workbench.window?.contentView === originalContent
                  && model.hostWindow === workbench.window
                  && model.vault.hostWindow === workbench.window,
                  "ordinary entry restores the original hosting view and sheet hosts after top entry")
            check(workbench.window?.collectionBehavior.contains(.fullScreenPrimary) == true
                  && workbench.window?.level == .normal
                  && workbench.window?.frame == expectedOrdinaryFrame,
                  "ordinary entry retains native full-screen support, normal window level and saved geometry")
            check(NSApp.activationPolicy() == .regular,
                  "ordinary workbench participates in the Dock and Command-Tab application switcher")
            controller.handleContextChange(animated: false)
            check(workbench.window?.isVisible == true && !model.isTopEntryPresentation,
                  "context dismissal never closes an explicitly opened ordinary workbench window")
            controller.start(automaticPolling: false)
            controller.setMode(.workbench)
            poll(outside, at: 30); poll(top, at: 31)
            check(controller.isEntryPending && !controller.isHoverFeedbackVisible, "ordinary-entry race starts with pending intent and no intermediate panel")
            workbench.present(route: .device)
            poll(top, at: 31.5)
            check(!controller.isHoverFeedbackVisible && workbench.presentationWindow === workbench.window && model.route == .device,
                  "explicit ordinary entry cancels pending hover without stealing its host or route back")
            controller.stop()
            owner.showWorkbenchFromTopEntry(); await settle()
            let closingRoute = model.route
            ordinary.performClose(nil)
            await waitUntil { !ordinary.isVisible }
            check(!ordinary.isVisible && !workbench.isTopEntryPresented && workbench.window === ordinary
                  && ordinary.contentView === originalContent && model.hostWindow === ordinary && model.vault.hostWindow === ordinary
                  && model.route == closingRoute && NSApp.activationPolicy() == .accessory,
                  "closing a top-opened ordinary window preserves its one content tree without orphaned windows")
            owner.workbenchFromMenu(); await settle()
            check(ordinary.isVisible && ordinary.contentView === originalContent && ordinary.frame == expectedOrdinaryFrame
                  && model.hostWindow === ordinary && owner.workbenchController === workbench,
                  "menu reopen after a top-opened close reuses the same controller, host and geometry")
            if let ordinary = workbench.window {
                let retainedRoute = model.route
                let realFullScreenToggle = workbench.performFullScreenToggle
                var requestedFullScreenTarget:NSWindow?
                workbench.performFullScreenToggle = { requestedFullScreenTarget = $0 }
                model.closeWindow?()
                await waitUntil {ordinary.alphaValue < 0.99}
                let fullScreenInterruptedFade = ordinary.isVisible && ordinary.alphaValue < 0.99 && !model.windowVisible
                owner.toggleWorkbenchFullScreenFromMenu()
                await settle() // Wait beyond the real close timer's maximum 160 ms.
                check(fullScreenInterruptedFade && requestedFullScreenTarget === ordinary && ordinary.isVisible
                      && ordinary.alphaValue == 1 && model.windowVisible && NSApp.activationPolicy() == .regular,
                      "a fresh fullscreen menu request cancels a live close fade before crossing the OS transition boundary")
                workbench.performFullScreenToggle = realFullScreenToggle
                model.closeWindow?()
                await waitUntil {ordinary.alphaValue < 0.99}
                let minimizeInterruptedFade = ordinary.isVisible && ordinary.alphaValue < 0.99 && !model.windowVisible
                model.minimizeWindow?()
                let restoredBeforeMinimization = ordinary.alphaValue == 1
                await waitUntil {ordinary.isMiniaturized}
                await settle()
                check(minimizeInterruptedFade && restoredBeforeMinimization && ordinary.isMiniaturized
                      && ordinary.alphaValue == 1 && NSApp.activationPolicy() == .regular,
                      "a fresh minimize request restores opacity and invalidates an in-progress close completion")
                check(ordinary.isMiniaturized && !model.windowVisible && NSApp.activationPolicy() == .regular,
                      "native minimization preserves the Dock target while suspending the foreground surface")
                let handled = owner.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
                await waitUntil {!ordinary.isMiniaturized && ordinary.isVisible && model.windowVisible}
                check(handled && !ordinary.isMiniaturized && ordinary.isVisible && model.windowVisible
                      && model.route == retainedRoute && NSApp.activationPolicy() == .regular,
                      "Dock reopen deminiaturizes the same ordinary window and retains its current page")
                model.closeWindow?()
                await waitUntil {!ordinary.isVisible}
                check(!ordinary.isVisible && !model.windowVisible && NSApp.activationPolicy() == .accessory
                      && owner.workbenchController === workbench && !model.quitting && !model.calendar.ownNotificationsSuspendedForQuit,
                      "custom close only hides the frontend, returns to background mode and preserves running services")
                check(!owner.applicationShouldTerminateAfterLastWindowClosed(NSApp),
                      "closing the last workbench window never terminates the background app")
                _ = owner.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                await waitUntil {ordinary.isVisible && model.windowVisible}
                check(ordinary.isVisible && model.route == retainedRoute && NSApp.activationPolicy() == .regular,
                      "Dock/application reopen after close restores the same controller and page")
            }
            check(calendarSystem.permissionRequests == 0 && calendarSystem.reads == 0 && notifications.permissionRequests == 0,
                  "top entry integration does not request permissions or access calendar accounts")
        } catch { check(false, "top entry isolated fixture setup: \(error.localizedDescription)") }
        print("Top entry native checks: \(count - failures)/\(count) passed")
        return (count, failures)
    }
    private static func settle() async { try? await Task.sleep(for: .milliseconds(500)) }
    private static func waitUntil(_ ready: () -> Bool) async {
        for _ in 0..<30 {
            if ready() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

@MainActor private final class TopEntryModalCheckAction: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

@MainActor private final class TopEntryCheckCalendar: CalendarSystemProviding {
    var permissionRequests = 0, reads = 0
    func access(reminders: Bool) -> CalendarAccess { .notDetermined }
    func requestAccess(reminders: Bool) async throws -> Bool { permissionRequests += 1; return false }
    func events(in interval: DateInterval) throws -> [CalendarEventItem] { reads += 1; return [] }
    func reminders() async throws -> [ReminderItem] { reads += 1; return [] }
    func writableReminderCalendars() -> [ReminderCalendar] { [] }
    func saveReminder(_ item: ReminderItem, creating: Bool) throws -> ReminderItem { throw ReminderError.unavailable("Isolated fixture") }
    func deleteReminder(_ item: ReminderItem) throws { throw ReminderError.unavailable("Isolated fixture") }
}

@MainActor private final class TopEntryCheckNotifications: ReminderNotificationProviding {
    var permissionRequests = 0
    func access() async -> CalendarAccess { .notDetermined }
    func requestAccess() async throws -> Bool { permissionRequests += 1; return false }
    func replacePending(_ notifications: [ReminderNotification]) async throws {}
}
