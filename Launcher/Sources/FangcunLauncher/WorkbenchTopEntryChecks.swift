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
                  "entering the top edge has invisible intent confirmation without a separate expansion surface")
            poll(top, at: 3.1)
            check(workbench.presentationWindow?.isVisible != true, "top entry does not open before the hover dwell")
            poll(top, at: 3.11)
            check(workbench.presentationWindow?.isVisible != true, "a 110 ms pass cannot open the 120 ms intent confirmation")
            poll(outside, at: 3.115)
            await settle()
            check(!controller.isHoverFeedbackVisible && workbench.presentationWindow?.isVisible != true,
                  "leaving before the dwell cancels the anticipation and pending reveal")
            poll(top, at: 3.4)
            poll(top, at: 3.76)
            for _ in 0..<20 {
                if (workbench.presentationWindow?.alphaValue ?? 0) >= 0.999 { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            check(model.route == .overview && workbench.presentationWindow?.isVisible == true,
                  "injected top-edge dwell opens the real workbench overview through the production poll path")
            check(NSApp.activationPolicy() == .accessory,
                  "temporary top-entry workbench keeps the background accessory policy")
            check(!controller.isHoverFeedbackVisible && model.isTopEntryPresentation,
                  "the anticipation hands off to the temporary workbench presentation")
            let animationFinished = (workbench.presentationWindow?.alphaValue ?? 0) >= 0.999
            if !animationFinished { print("DETAIL top-entry alpha=\(workbench.presentationWindow?.alphaValue ?? -1)") }
            check(animationFinished, "top-entry workbench animation finishes at full opacity")
            let presented = workbench.presentationWindow
            check(presented is NSPanel && presented?.styleMask.contains(.nonactivatingPanel) == true,
                  "top entry uses a nonactivating panel instead of relying on background app activation")
            check(presented?.isOnActiveSpace == true,
                  "top-entry panel belongs to the user's active Space, not only an ordered background window")
            await waitUntil { presented?.occlusionState.contains(.visible) == true }
            let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            print("DETAIL top-visibility alpha=\(presented?.alphaValue ?? -1) occlusion=\(presented?.occlusionState.rawValue ?? 0) id=\(presented?.windowNumber ?? -1) listed=\(onScreen.contains { ($0[kCGWindowNumber as String] as? Int) == presented?.windowNumber })")
            check(presented?.occlusionState.contains(.visible) == true
                  && onScreen.contains { ($0[kCGWindowNumber as String] as? Int) == presented?.windowNumber },
                  "top-entry panel is actually unobscured and listed on screen by WindowServer")
            check(presented?.collectionBehavior.contains(.fullScreenAuxiliary) == true
                  && presented?.collectionBehavior.contains(.fullScreenPrimary) == false,
                  "top-entry panel can accompany another application's full-screen Space")
            check(model.hostWindow === presented && model.vault.hostWindow === presented
                  && presented?.contentView === originalContent,
                  "top-entry panel transfers the existing content and sheet hosts without a second model")
            check(workbench.window?.frame == originalFrame,
                  "hover presentation preserves the saved ordinary window frame")
            model.navigate(.settings)
            poll(top, at: 4)
            check(model.route == .settings, "remaining inside the zone cannot retrigger the direct entry")
            poll(outside, at: 4.1); poll(top, at: 4.2); poll(top, at: 4.56)
            check(model.route == .settings && !controller.isHoverFeedbackVisible,
                  "re-entering the activation zone while the temporary workbench is open preserves its route")
            if let presented {
                controller.handleOutsideClick(at: CGPoint(x: presented.frame.midX, y: presented.frame.midY))
                await settle()
                check(presented.isVisible, "clicks inside the temporary workbench do not dismiss it")
                let child = NSPanel(contentRect: NSRect(x: presented.frame.maxX + 8, y: presented.frame.midY,
                                                       width: 100, height: 80),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                child.isReleasedWhenClosed = false
                presented.addChildWindow(child, ordered: .above)
                child.orderFrontRegardless()
                controller.handleOutsideClick(at: CGPoint(x: child.frame.midX, y: child.frame.midY))
                await settle()
                check(presented.isVisible && child.isVisible,
                      "an owned child panel outside the parent frame is still treated as an internal interaction")
                presented.removeChildWindow(child); child.orderOut(nil)
            } else { check(false, "an inside-click test has a presented workbench") }
            workspaceNotifications.post(name: NSWorkspace.didActivateApplicationNotification,
                object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
            await settle()
            check(workbench.presentationWindow?.isVisible == true,
                  "activation of this app does not dismiss its temporary presentation")

            // These inject the same notification metadata macOS delivers. They do not
            // synthesize Cmd-Tab or activate another real application.
            let externalApplication = NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular
            }
            if let externalApplication {
                workspaceNotifications.post(name: NSWorkspace.didActivateApplicationNotification,
                    object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: externalApplication])
            } else {
                controller.handleApplicationActivation(processIdentifier: ProcessInfo.processInfo.processIdentifier + 100_000)
            }
            await settle()
            check(workbench.presentationWindow?.isVisible != true && !controller.isQuickSummaryVisible
                  && !controller.isHoverFeedbackVisible,
                  "external-app activation input dismisses every temporary surface without requiring app deactivation")
            poll(top, at: 4.9); poll(top, at: 5.4)
            check(workbench.presentationWindow?.isVisible != true && !controller.isHoverFeedbackVisible,
                  "context dismissal cannot reopen while the pointer remains in the activation zone")

            poll(outside, at: 6); poll(top, at: 7); poll(top, at: 7.36)
            await settle()
            check(workbench.presentationWindow?.isVisible == true,
                  "leaving and returning rearms top entry after an application switch")
            let clearOutside = CGPoint(x: screen.frame.minX + 2, y: screen.frame.minY + 2)
            controller.handleOutsideClick(at: clearOutside)
            await settle()
            check(workbench.presentationWindow?.isVisible != true,
                  "a click outside the temporary workbench dismisses it")

            workbench.presentFromTopEntry()
            try? await Task.sleep(for: .milliseconds(60))
            controller.handleContextChange()
            try? await Task.sleep(for: .milliseconds(60))
            workbench.presentFromTopEntry()
            await settle()
            check(workbench.presentationWindow?.isVisible == true
                  && (workbench.presentationWindow?.alphaValue ?? 0) >= 0.999
                  && model.hostWindow === workbench.presentationWindow,
                  "reopening during a workbench opacity fade cancels the old exit and restores the same visible host")
            controller.handleContextChange(animated: false)

            poll(outside, at: 8); poll(top, at: 9); poll(top, at: 9.36)
            await settle()
            workspaceNotifications.post(name: NSWorkspace.activeSpaceDidChangeNotification,
                                                       object: NSWorkspace.shared)
            await settle()
            check(workbench.presentationWindow?.isVisible != true && !controller.isHoverFeedbackVisible,
                  "an injected Space-change notification dismisses temporary presentation")

            poll(outside, at: 10); poll(top, at: 11)
            check(controller.isEntryPending && !controller.isHoverFeedbackVisible, "a new approach starts invisible intent confirmation after rearming")
            controller.handleContextChange(animated: false)
            poll(top, at: 11.5)
            check(!controller.isHoverFeedbackVisible && workbench.presentationWindow?.isVisible != true,
                  "a context change during anticipation cancels the pending dwell reveal")

            // A native sheet is kept attached while its whole temporary family is
            // hidden. The form object and its unsaved field must survive restoration.
            poll(outside, at: 12); poll(top, at: 13); poll(top, at: 13.36)
            await settle()
            model.navigate(.settings)
            if let sheetHost = workbench.presentationWindow {
                let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 150),
                                     styleMask: [.titled], backing: .buffered, defer: false)
                sheet.isReleasedWhenClosed = false
                let draft = NSTextField(string: "未保存的顶部入口草稿")
                draft.frame = NSRect(x: 20, y: 60, width: 280, height: 24)
                sheet.contentView?.addSubview(draft)
                var sheetCompletions = 0
                sheetHost.beginSheet(sheet, completionHandler: { _ in sheetCompletions += 1 })
                await settle()
                check(sheetHost.attachedSheet === sheet && sheet.isVisible,
                      "the isolated fixture presents a native sheet on the temporary host")
                controller.handleOutsideClick(at: CGPoint(x: sheet.frame.midX, y: sheet.frame.midY))
                await settle()
                check(sheetHost.isVisible && sheet.isVisible,
                      "a click within an attached native sheet does not dismiss its temporary family")
                controller.handleContextChange(animated: false)
                await settle()
                print("DETAIL sheet-hide parentVisible=\(sheetHost.isVisible) parentAlpha=\(sheetHost.alphaValue) sheetVisible=\(sheet.isVisible) sheetAlpha=\(sheet.alphaValue) parentAttached=\(sheetHost.attachedSheet === sheet) childParent=\(sheet.sheetParent === sheetHost) hostSame=\(model.hostWindow === sheetHost) resumable=\(workbench.canResumeSuspendedTopInteraction) completions=\(sheetCompletions)")
                check(!sheetHost.isVisible && !sheet.isVisible && sheet.sheetParent === sheetHost
                      && sheetHost.attachedSheet === sheet && model.hostWindow === sheetHost,
                      "context dismissal hides both the sheet and its parent while retaining attachment")
                check(sheetHost.contentView === originalContent && draft.stringValue == "未保存的顶部入口草稿"
                      && workbench.model === model && model.route == .settings,
                      "hiding a sheet preserves its unsaved field, hosting view, model and selected route")
                poll(outside, at: 13.5); poll(top, at: 14); poll(top, at: 14.36)
                await settle()
                print("DETAIL sheet-resume parentVisible=\(sheetHost.isVisible) parentAlpha=\(sheetHost.alphaValue) sheetVisible=\(sheet.isVisible) sheetAlpha=\(sheet.alphaValue) parentAttached=\(sheetHost.attachedSheet === sheet) childParent=\(sheet.sheetParent === sheetHost) hostSame=\(model.hostWindow === sheetHost) resumable=\(workbench.canResumeSuspendedTopInteraction) completions=\(sheetCompletions)")
                check(sheetHost.isVisible && sheet.isVisible && sheetHost.attachedSheet === sheet
                      && draft.stringValue == "未保存的顶部入口草稿" && model.route == .settings,
                      "hovering again restores the same sheet and draft without navigating away")
                check(sheetCompletions == 0,
                      "temporarily hiding and resuming a native sheet does not finish its modal session")
                model.closeWindow?()
                await waitUntil {!sheetHost.isVisible}
                check(!sheetHost.isVisible && !sheet.isVisible && sheet.sheetParent === sheetHost
                      && sheetHost.attachedSheet === sheet && sheetHost.contentView === originalContent
                      && workbench.isTopEntryPresented && workbench.window?.isVisible != true && sheetCompletions == 0,
                      "explicit close hides a native sheet family without migrating or ending its draft session")
                workbench.presentFromTopEntry()
                await settle()
                check(sheetHost.isVisible && sheet.isVisible && model.hostWindow === sheetHost
                      && draft.stringValue == "未保存的顶部入口草稿" && sheetCompletions == 0,
                      "reopening an explicitly closed native sheet restores the same host and unsaved input")
                controller.handleContextChange()
                controller.handleContextChange(animated: false)
                check(!sheetHost.isVisible && !sheet.isVisible && sheetHost.attachedSheet === sheet,
                      "an immediate context change finishes an in-progress exit without detaching its sheet")
                workbench.presentFromTopEntry()
                await settle()
                sheetHost.endSheet(sheet); sheet.orderOut(nil)
                await settle()
                check(sheetCompletions == 1,
                      "the preserved native sheet completes exactly once when the user actually ends it")
                controller.handleContextChange(animated: false)
            } else { check(false, "sheet recovery has a temporary workbench host") }

            // Some existing import/export actions use an app-modal session rather
            // than an attached sheet. Hiding it must not terminate runModal early.
            workbench.presentFromTopEntry()
            await settle()
            let modal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 140),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            modal.isReleasedWhenClosed = false
            let modalDraft = NSTextField(string: "未保存的模态草稿")
            modalDraft.frame = NSRect(x: 16, y: 50, width: 268, height: 24)
            modal.contentView?.addSubview(modalDraft)
            modal.center()
            var hidModalFamily = false, resumedModalFamily = false, stoppedModalDeliberately = false
            let modalAction = TopEntryModalCheckAction {
                controller.handleContextChange(animated: false)
                hidModalFamily = !modal.isVisible && workbench.presentationWindow?.isVisible != true
                    && NSApp.modalWindow === modal && workbench.canResumeSuspendedTopInteraction
                poll(outside, at: 14.5); poll(top, at: 15); poll(top, at: 15.36)
                resumedModalFamily = modal.isVisible && workbench.presentationWindow?.isVisible == true
                    && NSApp.modalWindow === modal && modalDraft.stringValue == "未保存的模态草稿"
                stoppedModalDeliberately = true
                NSApp.stopModal(withCode: .cancel)
            }
            let modalTimer = Timer(timeInterval: 0.15, target: modalAction,
                                   selector: #selector(TopEntryModalCheckAction.fire), userInfo: nil, repeats: false)
            RunLoop.main.add(modalTimer, forMode: .modalPanel)
            let modalResponse = NSApp.runModal(for: modal)
            modalTimer.invalidate()
            check(hidModalFamily, "context dismissal hides an app-modal family while preserving its modal session")
            check(resumedModalFamily, "hover polling restores the same app-modal window and its unsaved draft")
            check(stoppedModalDeliberately && modalResponse == .cancel,
                  "a suspended app-modal session ends only when explicitly stopped")
            modal.orderOut(nil)
            await settle()
            controller.handleContextChange(animated: false)

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
            check((expandedTarget?.width ?? 0) == min(600, screen.frame.width - 32)
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
            workbench.dismissTopEntryForContextChange(animated: false)
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
            check(workbench.presentationWindow?.isVisible == true && model.isTopEntryPresentation,
                  "automatic timer alone opens the temporary workbench after an injected top-edge hover")
            await waitUntil { (workbench.presentationWindow?.alphaValue ?? 0) >= 0.999 }

            model.navigate(.settings)
            workbench.dismissTopEntryForContextChange(animated: false)
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
                  && workbench.window?.frame == originalFrame,
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
            workbench.presentFromTopEntry()
            await settle()
            let closingPanel = workbench.presentationWindow
            let closingRoute = model.route
            closingPanel?.performClose(nil)
            await waitUntil { closingPanel?.isVisible != true }
            check(closingPanel !== workbench.window && closingPanel?.isVisible != true
                  && closingPanel?.contentView == nil && workbench.window?.isVisible != true
                  && !workbench.isTopEntryPresented && workbench.window?.contentView === originalContent
                  && model.hostWindow === workbench.window && model.vault.hostWindow === workbench.window
                  && model.route == closingRoute,
                  "closing the hover panel returns the original content without an orphaned empty window")
            workbench.present(route:closingRoute)
            await settle()
            check(workbench.window?.isVisible == true && workbench.window?.contentView === originalContent
                  && model.hostWindow === workbench.window && owner.workbenchController === workbench,
                  "ordinary reopen after an explicit hover close reuses the original host and controller")
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
