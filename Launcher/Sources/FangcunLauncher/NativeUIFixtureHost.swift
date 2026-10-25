import AppKit
import ApplicationServices
import SwiftUI

enum NativeUIFixtureAccessibility {
    static func isRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains { ["--self-check", "--device-check", "--form-check", "--space-cleaning-check", "--pointer-check", "--shortcut-responder-check"].contains($0) }
    }

    private struct BridgeProbe: Sendable {
        let trusted: Bool
        let timeoutError: Int32
        let queryError: Int32
        let windowCount: Int
        var succeeded: Bool {
            timeoutError == AXError.success.rawValue
                && (queryError == AXError.success.rawValue || queryError == AXError.noValue.rawValue)
                && windowCount >= 0
        }
    }
    @MainActor private static var bridgeProbe: BridgeProbe?
    @MainActor private static var mountedProbeAttempted = false

    /// A public AX request to this process makes AppKit's SwiftUI accessibility
    /// bridge service its real dynamic subtree. Direct in-process children
    /// getters alone can leave nested ScrollView contents uninitialized.
    /// This reads only our window count, never another process or window text.
    /// There is no trust prompt or permission mutation. The background query
    /// lets the main run loop answer its own AX message without deadlocking.
    @MainActor static func prepareOwnProcessBridge(requiringWindow: Bool = false) async -> Bool {
        guard isRequested(), NSApp.isRunning else { return false }
        if let probe = bridgeProbe {
            if !probe.succeeded { return false }
            if !requiringWindow || probe.windowCount > 0 { return true }
            if mountedProbeAttempted { return false }
        }
        if requiringWindow { mountedProbeAttempted = true }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let probe = await Task.detached(priority: .userInitiated) {
            let own = AXUIElementCreateApplication(ownPID)
            let timeoutError = AXUIElementSetMessagingTimeout(own, 1)
            var windows: CFTypeRef?
            let queryError = AXUIElementCopyAttributeValue(own, kAXWindowsAttribute as CFString, &windows)
            let count = queryError == .noValue ? 0 : (windows as? [Any])?.count ?? -1
            return BridgeProbe(trusted: AXIsProcessTrusted(), timeoutError: timeoutError.rawValue,
                               queryError: queryError.rawValue, windowCount: count)
        }.value
        bridgeProbe = probe
        print("DETAIL native UI own-process AX bridge trusted=\(probe.trusted) timeoutError=\(probe.timeoutError) queryError=\(probe.queryError) ownWindowCount=\(probe.windowCount) requiringWindow=\(requiringWindow)")
        return probe.succeeded && (!requiringWindow || probe.windowCount > 0)
    }
}

extension View {
    /// SwiftUI may defer its virtual AX tree until assistive technology is
    /// attached. Its public accessibilityEnabled environment key requests that
    /// same real tree for explicit native QA; normal startup preserves the
    /// incoming system value. No permissions or system settings are changed.
    func nativeCheckAccessibility() -> some View {
        transformEnvironment(\.accessibilityEnabled) { enabled in
            if NativeUIFixtureAccessibility.isRequested() { enabled = true }
        }
    }
}

/// QA hosts need a real key-capable window. Ordinary borderless NSWindow
/// instances cannot become key, even when makeKeyAndOrderFront is requested.
/// This type is constructed only by explicit native-check entry points.
@MainActor final class NativeUIFixtureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Call only when a test explicitly presents its host, never from a generic
    /// settle helper: hidden-window and focus-loss checks must remain hidden or
    /// unfocused. The caller supplies a real production AX/layout predicate.
    static func prepare(window: NSWindow, until condition: @MainActor () -> Bool) async -> Bool {
        // Explicit QA opt-in for desktops covered by an unrelated floating
        // review window. Keep real occlusion, AX and pointer checks; never
        // change the production window level during ordinary startup.
        if NativeUIFixtureAccessibility.isRequested(),
           ProcessInfo.processInfo.environment["FANGCUN_QA_FLOATING_HOSTS"] == "1",
           window.level.rawValue < NSWindow.Level.modalPanel.rawValue {
            window.level = .modalPanel
        }
        // Only explicitly mounted QA hosts use regular activation and may
        // briefly appear in the Dock. Product startup and saved settings are
        // unchanged. An accessory test process did not reliably become active.
        if NSApp.activationPolicy() != .regular { _ = NSApp.setActivationPolicy(.regular) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var stablePasses = 0, conditionReady = false
        var activationRequested = false
        var activationRequestedAt: ContinuousClock.Instant?
        var explicitActivationRequested = false, keyedAfterActivation = false
        var bridgeRequested = false, bridgeReady = false
        repeat {
            if Task.isCancelled { break }
            // Read back the policy before requesting activation; the setter's
            // return value alone does not establish the actual process state.
            if !activationRequested, NSApp.activationPolicy() == .regular {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                activationRequested = true
                activationRequestedAt = .now
            }
            if !explicitActivationRequested, !NSApp.isActive, let requestedAt = activationRequestedAt,
               ContinuousClock.now >= requestedAt.advanced(by: .milliseconds(250)) {
                // Public AppKit fallback at this explicit QA boundary only.
                // A CLI-launched host may have no cooperative activation grant;
                // activate() alone is not guaranteed to bring it forward.
                print("DETAIL native UI fixture requests one explicit public AppKit activation after the cooperative request remained inactive")
                NSApp.activate(ignoringOtherApps: true)
                explicitActivationRequested = true
            }
            if NSApp.isActive, !keyedAfterActivation {
                // The first key request may precede asynchronous activation.
                // Retry once after reading back the app's real active state.
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                keyedAfterActivation = true
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if !bridgeRequested, surfaceReady(window) {
                bridgeRequested = true
                bridgeReady = await NativeUIFixtureAccessibility.prepareOwnProcessBridge(requiringWindow: true)
            }
            conditionReady = condition()
            if surfaceReady(window) && bridgeReady && conditionReady {
                stablePasses += 1
                if stablePasses >= 2 {
                    describe(window, ready: true, conditionReady: conditionReady)
                    return true
                }
            } else { stablePasses = 0 }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        describe(window, ready: false, conditionReady: conditionReady)
        return false
    }

    /// Queries existing accessibility elements only; it adds no replacement
    /// elements, permissions, identifiers or synthetic geometry to the UI.
    static func hasAccessibilityElement(_ identifier: String, in root: NSView) -> Bool {
        var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>()
        while let object = pending.popLast(), visited.count < 8_192 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier,
               object.responds(to: NSSelectorFromString("accessibilityFrame")),
               let value = object.value(forKey: "accessibilityFrame") as? NSValue {
                let rect = value.rectValue
                if rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite { return true }
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return false
    }

    private static func surfaceReady(_ window: NSWindow) -> Bool {
        guard NSApp.activationPolicy() == .regular, NSApp.isActive,
              window.canBecomeKey, window.isKeyWindow, window.isVisible,
              window.alphaValue >= 0.99, window.occlusionState.contains(.visible),
              let host = window.contentView, host.window === window else { return false }
        return host.bounds.width > 0 && host.bounds.height > 0 && host.bounds.width.isFinite && host.bounds.height.isFinite
    }

    private static func describe(_ window: NSWindow, ready: Bool, conditionReady: Bool) {
        print("DETAIL native UI fixture ready=\(ready) axOrLayoutReady=\(conditionReady) policy=\(NSApp.activationPolicy().rawValue) running=\(NSApp.isRunning) finishedLaunching=\(NSRunningApplication.current.isFinishedLaunching) active=\(NSApp.isActive) runningAppActive=\(NSRunningApplication.current.isActive) hidden=\(NSApp.isHidden) visible=\(window.isVisible) key=\(window.isKeyWindow) canKey=\(window.canBecomeKey) canMain=\(window.canBecomeMain) occlusion=\(window.occlusionState.rawValue) alpha=\(window.alphaValue) frame=\(NSStringFromRect(window.frame)) host=\(String(describing: window.contentView?.bounds))")
    }
}
