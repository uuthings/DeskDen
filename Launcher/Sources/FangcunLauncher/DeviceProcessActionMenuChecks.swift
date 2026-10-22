import AppKit
import LauncherCore

/// Uses only synthetic process identities and callbacks. No OS process action is
/// reachable from this fixture, including when a native menu item is selected.
@MainActor enum DeviceProcessActionMenuChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let app = DeviceProcessApplication(bundlePath: "/Applications/Synthetic Menu.app", bundleIdentifier: "test.process-menu",
                                           name: "Synthetic Menu", executablePath: "/Applications/Synthetic Menu.app/Contents/MacOS/Synthetic")
        func process(_ pid: Int32, path: String? = "/Applications/Synthetic Menu.app/Contents/MacOS/Helper", uid: UInt32? = 501, started: UInt64 = 10) -> DeviceProcess {
            .init(pid: pid, name: "Synthetic \(pid)", executablePath: path, residentBytes: 1, threadCount: 1,
                  sampledAt: .distantPast, startedMicroseconds: started, ownerUID: uid, application: app)
        }
        let main = process(21, path: app.executablePath), helper = process(22)
        func availability(_ values: [DeviceProcess], whole: Bool = true, memory: Bool = false, currentApp: String? = nil) -> DeviceProcessActionAvailability {
            .init(name: app.name, members: values, wholeApplication: whole, memoryFocused: memory,
                  currentUID: 501, currentPID: 99, currentApplicationPath: currentApp)
        }
        let normal = availability([main, helper])
        check(normal.canQuit && normal.canForce && normal.protection == nil,
              "verified application groups retain both explicit quit and force choices without a protection warning")
        for (value, reason) in [(process(23, path: "/System/Library/Synthetic"), "系统服务"),
                                (process(24, path: nil), "核验进程身份"),
                                (process(25, uid: 502), "其他用户"),
                                (process(99), "方寸"),
                                (process(26, started: 0), "核验进程身份")] {
            let state = availability([value], whole: false)
            check(!state.canQuit && !state.canForce && state.protection?.badge == "只读" && state.protection?.reason.contains(reason) == true,
                  "protected process \(value.pid) keeps both actions disabled with an explicit outside-menu reason")
        }
        let mixed = availability([main, process(27, path: nil)])
        check(mixed.canQuit && !mixed.canForce && mixed.protection?.badge == "受限" && mixed.protection?.guidance.contains("主进程正常退出") == true,
              "mixed groups explain why normal main-process quit remains available while force for the entire group is disabled")
        let missingMain = availability([helper])
        check(!missingMain.canQuit && missingMain.canForce && missingMain.protection?.reason.contains("应用主进程") == true,
              "a missing main process disables whole-application quit without silently turning it into child termination")
        let ownApp = availability([main, helper], currentApp: app.bundlePath)
        check(!ownApp.canQuit && !ownApp.canForce && ownApp.protection?.reason.contains("方寸") == true,
              "the complete current application remains read-only, including its helpers")
        let empty = availability([])
        check(!empty.canQuit && !empty.canForce && empty.protection != nil, "an empty stale selection cannot acquire actions through allSatisfy")

        let button = DeviceProcessMenuButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.processName = app.name; button.wholeApplication = true
        var details = 0, confirmations: [DeviceProcessActionMode] = []
        button.viewDetails = { details += 1 }; button.request = { confirmations.append($0) }
        for state in [normal, mixed, ownApp, missingMain] {
            button.canQuit = state.canQuit; button.canForce = state.canForce
            let menu = button.makeActionsMenu(), actions = menu.items.filter { !$0.isSeparatorItem }
            check(actions.map(\.title) == ["查看详情", "退出整个应用", "强制结束此组"]
                    && actions.allSatisfy { !$0.title.hasSuffix("…") && !$0.title.hasSuffix("...") }
                    && !menu.autoenablesItems,
                  "the actual native menu contains concise action labels, no protection-warning item, and explicit enablement")
            check(actions[0].isEnabled && actions[1].isEnabled == state.canQuit && actions[2].isEnabled == state.canForce,
                  "native menu disabled states exactly reflect the captured process policy")
            let before = confirmations.count
            menu.performActionForItem(at: 0); menu.performActionForItem(at: 2); menu.performActionForItem(at: 3)
            check(confirmations.count - before == (state.canQuit ? 1 : 0) + (state.canForce ? 1 : 0),
                  "selecting native process actions only requests the corresponding confirmation and cannot invoke a disabled action")
        }
        check(details == 4 && confirmations == [.quit, .force, .quit, .force],
              "menu callbacks preserve distinct normal/force confirmation modes and never execute an OS action")
        button.canQuit = true; button.canForce = true
        button.wholeApplication = false
        check(button.makeActionsMenu().items.filter { !$0.isSeparatorItem }.map(\.title) == ["查看详情", "退出进程", "强制结束进程"],
              "single-process menu labels remain distinct from whole-application actions")

        // Exercise the core's real revalidation path with a fake dispatcher.
        var dispatches = 0, reads = 0
        do {
            try DeviceProcessActions.perform(.init(name: app.name, processes: [main], mode: .quit), currentUID: 501, currentPID: 99,
                reread: { _ in reads += 1; var fresh = main; if reads > 1 { fresh.startedMicroseconds += 1 }; return fresh },
                dispatch: { _, _ in dispatches += 1 })
            check(false, "identity reuse must fail immediately before dispatch")
        } catch {
            check(error as? DeviceProcessActionError == .staleProcess && dispatches == 0 && reads == 2,
                  "native menu presentation changes preserve immediate PID/start-time revalidation and zero stale dispatches")
        }
        do {
            try DeviceProcessActions.perform(.init(name: app.name, processes: [main, helper], mode: .quit, wholeApplication: true),
                currentUID: 501, currentPID: 99, reread: { $0 == main.pid ? main : helper },
                dispatch: { selected, operation in
                    dispatches += 1
                    check(selected.pid == main.pid && operation == .quitApplication, "normal whole-app quit still targets only the verified main process")
                })
            check(dispatches == 1, "normal quit does not dispatch force or kill helpers")
        } catch { check(false, "synthetic verified quit policy fixture: \(error)") }

        // The same native button used by the process rows opens a real AppKit
        // menu. Cancel its tracking automatically; nothing is ever selected.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NativeUIFixtureWindow(contentRect: NSRect(x: screen.midX - 330, y: screen.midY - 160, width: 660, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 320)); window.contentView = content
        content.addSubview(button)
        defer { window.close() }
        for width: CGFloat in [660, 380] {
            window.setContentSize(NSSize(width: width, height: 320))
            button.frame = NSRect(x: width - 42, y: 210, width: 28, height: 28)
            let ready = await NativeUIFixtureWindow.prepare(window: window) {
                let frame = button.convert(button.bounds, to: content)
                return button.window === window && !button.isHiddenOrHasHiddenAncestor && button.isEnabled
                    && button.bounds.size == NSSize(width: 28, height: 28) && content.bounds.contains(frame)
                    && abs(frame.maxX - (content.bounds.maxX - 14)) <= 0.5
            }
            check(ready, "the native process menu fixture is active, key and visible with its real trigger mounted before tracking at \(Int(width)) pt")
            let trigger = window.convertToScreen(button.convert(button.bounds, to: nil))
            var observed: NSRect?
            let existing = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            let trackingDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            let timer = Timer(timeInterval: 0.08, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if observed == nil {
                        observed = NSApp.windows.first(where: { $0.isVisible && !existing.contains($0.windowNumber)
                            && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue })?.frame
                    }
                    // performClick highlights before AppKit displays its menu.
                    // Wait within this one real tracking session; cancelling on
                    // the first tick can close a menu before it becomes visible.
                    if observed != nil || ContinuousClock.now >= trackingDeadline {
                        button.activeMenu?.cancelTracking()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .default)
            button.performClick(nil)
            timer.invalidate()
            if let frame = observed {
                print("DETAIL native process menu width=\(Int(width)) trigger=\(NSStringFromRect(trigger)) menu=\(NSStringFromRect(frame))")
                check(frame.maxX <= trigger.maxX + 2 && frame.maxX >= trigger.maxX - 2
                        && frame.minX < trigger.minX && frame.maxY <= trigger.minY + 2 && frame.maxY >= trigger.minY - 12,
                      "the real native process menu opens below the trigger, flush with its right edge, at \(Int(width)) pt")
                check(frame.maxX < window.frame.maxX && confirmations.count == 4 && button.activeMenu == nil,
                      "process menu stays inside the content's right edge and cancelling tracking changes no action state")
            } else {
                print("DETAIL native process menu windows=" + NSApp.windows.map { "\($0.windowNumber):\($0.level.rawValue):\($0.isVisible):\(NSStringFromRect($0.frame))" }.joined(separator: " | "))
                check(false, "a real native process menu window is observable while tracking at \(Int(width)) pt")
            }
        }
        print("Device process action menu checks: \(count - failures)/\(count) passed")
        return (count, failures)
    }
}
