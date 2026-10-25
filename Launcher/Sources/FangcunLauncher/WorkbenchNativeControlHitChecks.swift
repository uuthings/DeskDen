import AppKit
import Combine
import SwiftUI
import LauncherCore

/// Shared-control regressions plus the existing AppKit diagnostic matrix.
/// Pointer checks briefly move the cursor inside an isolated owned window and
/// restore its original position. Clicks are delivered only to that window;
/// no real preferences, user files, shortcuts or application actions are used.
@MainActor enum WorkbenchNativeControlHitChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        for result in await cursorChecks() { check(result.0, result.1) }
        for result in await pointerInteractionChecks() { check(result.0, result.1) }
        let activeBefore = NSApp.isActive
        let keyBefore = NSApp.keyWindow.map(ObjectIdentifier.init)
        var scenarios: [NativeControlHitScenario] = []
        for scroll in [false, true] {
            for movable in [false, true] {
                for decoration in NativeControlHitDecoration.allCases {
                    for shift in [CGFloat(0), CGFloat(0.5)] {
                        scenarios.append(.init(scroll: scroll, movable: movable, decoration: decoration, shift: shift))
                    }
                }
            }
        }
        // Add only eight focused variants, retaining the known 32-case baseline.
        // These reproduce the production two-line copy and nested slider/value
        // trailing stack rather than testing fixedSize on a different row shape.
        for fixed in [false, true] {
            for disabledFalse in [false, true] {
                for accessibilityFalse in [false, true] {
                    scenarios.append(.init(scroll: true, movable: true, decoration: .materialAndProbe, shift: 0.5,
                        productionTrailing: true, fixedTrailing: fixed, explicitDisabledFalse: disabledFalse,
                        explicitAccessibilityFalse: accessibilityFalse))
                }
            }
        }
        for scenario in scenarios {
            let state = NativeControlHitState()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 758), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Isolated native control diagnostic"
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.isOpaque = false; window.backgroundColor = .clear
            window.isReleasedWhenClosed = false; window.isExcludedFromWindowsMenu = true
            window.isMovableByWindowBackground = scenario.movable
            window.alphaValue = 0; window.ignoresMouseEvents = true
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = true }
            let host = NSHostingView(rootView: NativeControlHitRoot(state: state, scenario: scenario).nativeCheckAccessibility())
            host.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
            host.autoresizingMask = [.width, .height]
            window.contentView = host
            // orderFront mounts a real native hierarchy without making
            // this fully transparent, mouse-ignoring window key/active.
            window.orderFront(nil)
            let controls = await mountedControls(in: host)
            check(controls.slider != nil && controls.popup != nil, "isolated native controls mount [\(scenario.id)]")
            if let slider = controls.slider {
                check(validGeometry(slider, in: host), "isolated native slider geometry is finite [\(scenario.id)]")
                describe(slider, kind: "slider", in: host, scenario: scenario)
            }
            if let popup = controls.popup {
                check(validGeometry(popup, in: host), "isolated native popup geometry is finite [\(scenario.id)]")
                describe(popup, kind: "popup", in: host, scenario: scenario)
            }
            print("DETAIL native-hit-window [\(scenario.id)] key=\(window.isKeyWindow) active=\(NSApp.isActive) scale=\(window.backingScaleFactor) viewport=\(host.bounds) value=\(state.value) selected=\(state.selection)")
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        print("DETAIL native-hit-focus activeBefore=\(activeBefore) activeAfter=\(NSApp.isActive) sameKeyWindow=\(keyBefore == NSApp.keyWindow.map(ObjectIdentifier.init))")
        return (count, failures)
    }

    private static func cursorChecks() async -> [(Bool,String)] {
        let previous=ButtonCursorPolicy.shared.preference
        defer { ButtonCursorPolicy.shared.apply(previous) }
        let button=CursorCheckButton(frame:NSRect(x:0,y:0,width:80,height:32))
        ButtonCursorPolicy.shared.apply(.pointingHand)
        button.resetCursorRects()
        var checks=[(button.recorded.last === NSCursor.pointingHand,"enabled native buttons register the pointing hand")]
        button.recorded=[];button.isEnabled=false;button.resetCursorRects()
        checks.append((button.recorded.isEmpty,"disabled native buttons have no pointing-hand region"))
        ButtonCursorPolicy.shared.apply(.arrow)
        button.isEnabled=true;button.resetCursorRects()
        checks.append((button.recorded.last === NSCursor.arrow,"arrow preference applies to native buttons"))
        // macOS 14+ permits visibleRect to extend beyond bounds when a view
        // does not clip. Exercise the actual registrations for every host type.
        button.recordedRects=[];button.simulatedVisibleRect=NSRect(x:-40,y:-40,width:200,height:160)
        button.resetCursorRects()
        checks.append((button.recordedRects == [button.bounds],"native button cursor remains inside bounds when visibleRect is larger"))
        let popup=CursorCheckPopup(frame:NSRect(x:0,y:0,width:100,height:32),pullsDown:false)
        popup.resetCursorRects()
        checks.append((popup.recordedRects.last == popup.bounds,"native popup cursor remains inside bounds when visibleRect is larger"))
        let region=CursorCheckRegion(frame:NSRect(x:0,y:0,width:80,height:32))
        region.resetCursorRects()
        checks.append((region.recordedRects == [region.bounds],"SwiftUI cursor region remains inside bounds when visibleRect is larger"))
        button.recordedRects=[];button.simulatedVisibleRect=NSRect(x:200,y:200,width:20,height:20)
        button.resetCursorRects()
        checks.append((button.recordedRects.isEmpty,"fully clipped controls register no cursor rectangle"))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:320,height:220),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.alphaValue=0;window.ignoresMouseEvents=true
        let host=NSHostingView(rootView:VStack(spacing:12) {
            Button("Plain") {}.buttonStyle(ClickablePlainButtonStyle())
            Button("Styled") {}.buttonStyle(WBButtonStyle())
            Button("Disabled") {}.buttonStyle(WBButtonStyle()).disabled(true)
            TextField("Text entry",text:.constant("Synthetic"))
        }.padding(14))
        host.frame=window.contentLayoutRect;window.contentView=host;window.orderFront(nil)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded();try? await Task.sleep(for:.milliseconds(40)) }
        let regions=descendants(host).compactMap{$0 as? ClickableCursorView}
        checks.append((regions.count == 3 && regions.filter(\.enabled).count == 2,"plain and styled controls receive cursor regions; disabled state is inherited"))
        checks.append((regions.allSatisfy{$0.bounds.width>0 && $0.bounds.height>0 && $0.hitTest(.zero)==nil},"cursor regions have real bounds and never intercept clicks or text input"))
        window.orderOut(nil);window.contentView=nil;window.close()
        return checks
    }

    /// Uses the OS-delivered pointer and reads back the visible system cursor,
    /// rather than treating registration of a cursor rectangle as proof.
    static func pointerInteractionChecks() async -> [(Bool, String)] {
        let previous = ButtonCursorPolicy.shared.preference
        let previousKeyWindow = NSApp.keyWindow
        let previousMainWindow = NSApp.mainWindow
        let originalPoint = CGEvent(source: nil)?.location
        let window = NativeUIFixtureWindow(contentRect: NSRect(x: 260, y: 180, width: 460, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
        let state = PointerInteractionState()
        let host = NSHostingView(rootView: PointerInteractionRoot(state: state).nativeCheckAccessibility())
        window.contentView = host
        defer {
            ButtonCursorPolicy.shared.apply(previous)
            if let originalPoint { postPointer(at: originalPoint) }
            window.orderOut(nil); window.contentView = nil; window.close()
            if let previousMainWindow, previousMainWindow.isVisible { previousMainWindow.makeMain() }
            if let previousKeyWindow, previousKeyWindow.isVisible { previousKeyWindow.makeKey() }
        }
        let mounted = await NativeUIFixtureWindow.prepare(window: window) {
            descendants(host).filter { $0 is ClickableCursorView }.count == 8
        }
        guard mounted else { return [(false, "real pointer regression host mounts all shared action and selection button styles")] }
        var checks = [(true, "real pointer regression host mounts all shared action and selection button styles")]
        ButtonCursorPolicy.shared.apply(.pointingHand)
        let names = ["plain", "regular", "primary", "destructive", "quiet", "icon", "selected", "disabled"]
        for (index, name) in names.enumerated() {
            await movePointer(to: NSPoint(x: 12, y: 12), in: window)
            host.layoutSubtreeIfNeeded()
            let normalRegions = descendants(host).compactMap { $0 as? ClickableCursorView }.sorted {
                $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY
            }
            guard normalRegions.indices.contains(index) else {
                checks.append((false, "\(name) remains mounted before hover")); continue
            }
            let region = normalRegions[index]
            let rect = region.convert(region.bounds, to: nil)
            let normalBackground = backgroundSnapshot(region, in: host)
            // The left padding is visually part of every fixture Button,
            // while its centered glyphs sit well away from this position.
            let point = NSPoint(x: rect.minX + 3, y: rect.midY)
            await movePointer(to: point, in: window)
            if name == "disabled" {
                checks.append((!systemCursorMatches(.pointingHand), "disabled buttons retain a non-hand system cursor"))
            } else {
                checks.append((systemCursorMatches(.pointingHand), "OS pointer over \(name) button padding displays the pointing hand"))
            }
            host.layoutSubtreeIfNeeded()
            let live = descendants(host).compactMap { $0 as? ClickableCursorView }.sorted {
                $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY
            }
            guard live.indices.contains(index) else {
                checks.append((false, "\(name) remains mounted during hover")); continue
            }
            let liveRegion = live[index]
            let liveRect = liveRegion.convert(liveRegion.bounds, to: nil)
            let hoveredBackground = backgroundSnapshot(liveRegion, in: host)
            let backgroundDifference = backgroundDifference(normalBackground, hoveredBackground)
            // Readouts and custom-drawn controls use the plain pointer policy;
            // quiet text actions react through text/underline, without a box.
            // Bounded actions and selection surfaces have their own fill.
            let hasHoverSurface = !["plain", "quiet", "disabled"].contains(name)
            checks.append((backgroundDifference.map { hasHoverSurface ? $0 >= 1.5 : $0 < 0.5 } == true,
                           hasHoverSurface
                            ? "OS hover over \(name) changes its rendered background outside the glyphs"
                            : "OS hover over \(name) preserves its background without adding a generic box"))
            checks.append((abs(liveRect.width - rect.width) < 0.5 && abs(liveRect.height - rect.height) < 0.5 &&
                           abs(liveRect.minX - rect.minX) < 0.5 && abs(liveRect.minY - rect.minY) < 0.5,
                           "\(name) hover preserves the control's frame and neighbors"))
            print("DETAIL pointer hover background name=\(name) meanByteDifference=\(backgroundDifference ?? -1)")
            captureHoverEvidence(host, name: name)
            let clickPoint = NSPoint(x: liveRect.minX + 3, y: liveRect.midY)
            let before = state.presses[name, default: 0]
            if let down = pointerEvent(.leftMouseDown, point: clickPoint, window: window),
               let up = pointerEvent(.leftMouseUp, point: clickPoint, window: window) {
                NSApp.postEvent(up, atStart: false); NSApp.sendEvent(down)
            }
            for _ in 0..<15 {
                if state.presses[name, default: 0] != before { break }
                try? await Task.sleep(for: .milliseconds(15))
            }
            print("DETAIL pointer native press name=\(name) before=\(before) after=\(state.presses[name, default: 0]) rect=\(liveRect) point=\(clickPoint)")
            checks.append((state.presses[name, default: 0] == before + (name == "disabled" ? 0 : 1),
                           "native click on \(name) button padding \(name == "disabled" ? "does not trigger disabled action" : "triggers exactly once")"))
        }
        if let region = descendants(host).compactMap({ $0 as? ClickableCursorView }).max(by: {
            $0.convert($0.bounds, to: nil).midY < $1.convert($1.bounds, to: nil).midY
        }) {
            let rect = region.convert(region.bounds, to: nil)
            await movePointer(to: NSPoint(x: rect.midX, y: rect.midY), in: window)
            ButtonCursorPolicy.shared.apply(.arrow)
            try? await Task.sleep(for: .milliseconds(70))
            checks.append((systemCursorMatches(.arrow), "saved arrow preference changes the visible cursor without requiring pointer movement"))
            ButtonCursorPolicy.shared.apply(.pointingHand)
            try? await Task.sleep(for: .milliseconds(70))
            checks.append((systemCursorMatches(.pointingHand), "restoring default hand updates the visible hovered button immediately"))
        }
        await movePointer(to: NSPoint(x: 12, y: 12), in: window)
        checks.append((!systemCursorMatches(.pointingHand), "leaving a button clears the hand instead of retaining a stale cursor"))
        if let originalPoint { postPointer(at: originalPoint) }
        try? await Task.sleep(for: .milliseconds(100))
        return checks
    }
    private struct BackgroundSnapshot {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let rowBytes: Int
        let samples: Int
    }
    /// The narrow strip sits in button padding, away from every fixture label.
    /// A changed text color alone therefore cannot pass the hover assertion.
    private static func backgroundSnapshot(_ region: NSView, in host: NSView) -> BackgroundSnapshot? {
        let rect = region.convert(region.bounds, to: host)
        let strip = NSRect(x: rect.minX + 3, y: rect.minY + 4, width: min(5, max(1, rect.width / 10)), height: max(1, rect.height - 8)).intersection(host.bounds)
        guard !strip.isEmpty, let bitmap = host.bitmapImageRepForCachingDisplay(in: strip) else { return nil }
        host.cacheDisplay(in: strip, to: bitmap)
        guard bitmap.bitsPerSample == 8, let data = bitmap.bitmapData else { return nil }
        return BackgroundSnapshot(bytes: Array(UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh)),
            width: bitmap.pixelsWide, height: bitmap.pixelsHigh, rowBytes: bitmap.bytesPerRow, samples: bitmap.samplesPerPixel)
    }
    private static func backgroundDifference(_ before: BackgroundSnapshot?, _ after: BackgroundSnapshot?) -> Double? {
        guard let before, let after, before.width == after.width, before.height == after.height,
              before.rowBytes == after.rowBytes, before.samples == after.samples else { return nil }
        var difference = 0, count = 0
        for y in 0..<before.height {
            for x in 0..<(before.width * before.samples) {
                let index = y * before.rowBytes + x
                difference += abs(Int(before.bytes[index]) - Int(after.bytes[index])); count += 1
            }
        }
        return count > 0 ? Double(difference) / Double(count) : nil
    }
    private static func captureHoverEvidence(_ host: NSView, name: String) {
        guard let path = ProcessInfo.processInfo.environment["FANGCUN_HOVER_VISUAL_DIR"],
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? data.write(to: output.appendingPathComponent("shared-hover-" + name + ".png"))
    }
    private static func systemCursorMatches(_ expected: NSCursor) -> Bool {
        guard let actual = NSCursor.currentSystem else { return false }
        return actual.hotSpot == expected.hotSpot && actual.image.tiffRepresentation == expected.image.tiffRepresentation
    }
    private static func pointerEvent(_ type: NSEvent.EventType, point: NSPoint, window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
    }
    private static func postPointer(at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    private static func movePointer(to point: NSPoint, in window: NSWindow) async {
        let screenPoint = window.convertPoint(toScreen: point)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        postPointer(at: CGPoint(x: screenPoint.x, y: primaryTop - screenPoint.y))
        try? await Task.sleep(for: .milliseconds(120))
    }

    private static func mountedControls(in root: NSView) async -> (slider: NSSlider?, popup: WBPopUpButton?) {
        for _ in 0..<6 {
            root.layoutSubtreeIfNeeded()
            let views = descendants(root)
            let slider = views.compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "Isolated diagnostic slider" }
            let popup = views.compactMap { $0 as? WBPopUpButton }.first { $0.accessibilityLabel() == "Isolated diagnostic popup" }
            if let slider, let popup, validGeometry(slider, in: root), validGeometry(popup, in: root) {
                // Let SwiftUI commit its native hit-test graph, rather than
                // examining only the first frame after makeNSView.
                try? await Task.sleep(for: .milliseconds(40)); root.layoutSubtreeIfNeeded()
                return (slider, popup)
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        let views = descendants(root)
        return (views.compactMap { $0 as? NSSlider }.first, views.compactMap { $0 as? WBPopUpButton }.first)
    }

    private static func validGeometry(_ view: NSView, in root: NSView) -> Bool {
        let rect = view.convert(view.bounds, to: root)
        return view.window === root.window && !view.isHiddenOrHasHiddenAncestor && rect.width > 0 && rect.height > 0
            && [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite }
            && root.bounds.contains(NSPoint(x: rect.midX, y: rect.midY))
    }

    private static func describe(_ control: NSControl, kind: String, in root: NSView, scenario: NativeControlHitScenario) {
        let center = NSPoint(x: control.bounds.midX, y: control.bounds.midY)
        let windowPoint = control.convert(center, to: nil)
        let local = root.convert(windowPoint, from: nil)
        let rootHit = hit(root, atWindowPoint: windowPoint)
        let nativeHit = hit(control, atWindowPoint: windowPoint)
        var ancestor: NSView? = control
        var firstBreak = "none", chain: [String] = []
        var previouslyReachedControl = false
        while let current = ancestor {
            let result = hit(current, atWindowPoint: windowPoint)
            let reachesControl = result.map { $0 === control || $0.isDescendant(of: control) } ?? false
            if previouslyReachedControl && !reachesControl && firstBreak == "none" { firstBreak = String(describing: type(of: current)) }
            let point = current.superview?.convert(windowPoint, from: nil) ?? windowPoint
            chain.append("\(type(of: current)){f=\(current.frame),b=\(current.bounds),flip=\(current.isFlipped),p=\(point),h=\(result.map { String(describing: type(of: $0)) } ?? "nil")}")
            previouslyReachedControl = reachesControl
            if current === root { break }
            ancestor = current.superview
        }
        // All matrix samples are whole logical points. The unsnapped center
        // above is kept separately so a fractional-coordinate failure is visible.
        let origin = NSPoint(x: floor(local.x), y: floor(local.y))
        let matrix = (-1...1).map { dy in
            (-1...1).map { dx in
                let sample = NSPoint(x: origin.x + CGFloat(dx), y: origin.y + CGFloat(dy))
                let result = hit(root, atWindowPoint: root.convert(sample, to: nil))
                if result === control || result?.isDescendant(of: control) == true { return "+" }
                if let result, control.isDescendant(of: result) { return "a" }
                return result == nil ? "0" : "x"
            }.joined()
        }.joined(separator: "/")
        let ancestorHit = rootHit.map { control.isDescendant(of: $0) } ?? false
        print("DETAIL native-hit [\(scenario.id)] \(kind) rootPoint=\(local) backingPoint=\(root.convertToBacking(local)) windowRect=\(control.convert(control.bounds, to: nil)) enabled=\(control.isEnabled) direct=\(nativeHit.map { String(describing: type(of: $0)) } ?? "nil") root=\(rootHit.map { String(describing: type(of: $0)) } ?? "nil") ancestor=\(ancestorHit) firstBreak=\(firstBreak) integer3x3=\(matrix) (+control,a=ancestor,x=other,0=nil)")
        print("DETAIL native-hit-chain [\(scenario.id)] \(kind) " + chain.joined(separator: " / "))
    }

    /// AppKit hitTest takes a point in the receiver's *superview* coordinates.
    private static func hit(_ view: NSView, atWindowPoint point: NSPoint) -> NSView? {
        view.hitTest(view.superview?.convert(point, from: nil) ?? point)
    }
    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

private enum NativeControlHitDecoration: String, CaseIterable {
    case bare, material, probe, materialAndProbe
    var hasMaterial: Bool { self == .material || self == .materialAndProbe }
    var hasProbe: Bool { self == .probe || self == .materialAndProbe }
}
private struct NativeControlHitScenario {
    let scroll: Bool
    let movable: Bool
    let decoration: NativeControlHitDecoration
    let shift: CGFloat
    var productionTrailing = false
    var fixedTrailing = false
    var explicitDisabledFalse = false
    var explicitAccessibilityFalse = false
    var id: String { "scroll=\(scroll ? 1 : 0),drag=\(movable ? 1 : 0),decor=\(decoration.rawValue),shift=\(shift),row=\(productionTrailing ? "production" : "simple"),fixed=\(fixedTrailing ? 1 : 0),disabledFalse=\(explicitDisabledFalse ? 1 : 0),axHiddenFalse=\(explicitAccessibilityFalse ? 1 : 0)" }
}
@MainActor private final class NativeControlHitState: ObservableObject {
    @Published var selection = 0
    @Published var value = 0.7
}
private struct NativeControlHitRoot: View {
    @ObservedObject var state: NativeControlHitState
    let scenario: NativeControlHitScenario
    var body: some View {
        accessibilityVariant
    }
    @ViewBuilder private var accessibilityVariant: some View {
        if scenario.explicitAccessibilityFalse { disabledVariant.accessibilityHidden(false) }
        else { disabledVariant }
    }
    @ViewBuilder private var disabledVariant: some View {
        if scenario.explicitDisabledFalse { shell.disabled(false) }
        else { shell }
    }
    private var shell: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 46).allowsHitTesting(false)
            HStack(spacing: 0) {
                Color.clear.frame(width: 184).allowsHitTesting(false)
                if scenario.scroll {
                    ScrollView { page }.scrollContentBackground(.hidden).scrollBounceBehavior(.basedOnSize)
                } else { page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
            }
        }.padding(1).workbenchThemeEnvironment(theme: .arWorld, opacity: 0.7, backgroundMotion: false)
            .font(.system(size: 12))
    }
    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Native control hit-test isolation").frame(height: 58, alignment: .leading)
            VStack(spacing: 0) {
                Text("Actual WBSelect and NSSlider").frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                if scenario.productionTrailing {
                    productionRow("外观", subtitle: "工作台、启动器与浮层保持一致") { popup }
                    productionRow("界面不透明度", subtitle: "卡片、导航、菜单与 Mini 同步调整") {
                        VStack(spacing: 2) {
                            HStack(spacing: 10) {
                                NativeControlHitSlider(value: $state.value).frame(minWidth: 150, idealWidth: 170, maxWidth: 170, minHeight: 32, maxHeight: 32)
                                Text("70%").font(.system(size: 12)).monospacedDigit().frame(width: 36, alignment: .trailing)
                            }
                            HStack { Text("50% · 更通透"); Spacer(minLength: 8); Text("90% · 更清晰") }.font(.system(size: 11))
                        }.frame(width: 224)
                    }
                } else {
                    HStack { Text("Popup"); Spacer(); popup }.frame(height: 64)
                    HStack { Text("Slider"); Spacer(); NativeControlHitSlider(value: $state.value).frame(width: 170, height: 32) }.frame(height: 64)
                }
            }.padding(.top, scenario.shift).padding(14)
                .background { if scenario.decoration.hasMaterial { WorkbenchMaterialSurface() } }
        }.frame(maxWidth: 1360, alignment: .topLeading).frame(height: 629, alignment: .topLeading)
            .padding(EdgeInsets(top: 22, leading: 35, bottom: 16, trailing: 35))
            .frame(maxWidth: .infinity, alignment: .top)
            .background { if scenario.decoration.hasProbe { WorkbenchOverlayScrollbars() } }
    }
    private var popup: some View {
        WBSelect("Isolated diagnostic popup", selection: $state.selection, options: [(0, "First"), (1, "Second")]).frame(width: 174, height: 32)
    }
    private func productionRow<Content: View>(_ title: String, subtitle: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium)).frame(minHeight: 17.4, alignment: .leading)
                Text(subtitle).font(.system(size: 11)).lineSpacing(2).fixedSize(horizontal: false, vertical: true).frame(minHeight: 15.95, alignment: .leading)
            }.frame(maxWidth: 560, alignment: .leading)
            Spacer(minLength: 8)
            if scenario.fixedTrailing { trailing().fixedSize(horizontal: true, vertical: false) }
            else { trailing() }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13)
    }
}
private struct NativeControlHitSlider: NSViewRepresentable {
    @Binding var value: Double
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NativeControlHitSliderView(value: value, minValue: 0.5, maxValue: 0.9, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true; slider.setAccessibilityLabel("Isolated diagnostic slider")
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) { context.coordinator.value = $value; slider.doubleValue = value }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize? { CGSize(width: proposal.width ?? 170, height: 32) }
    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ sender: NSSlider) { value.wrappedValue = sender.doubleValue }
    }
}
private final class NativeControlHitSliderView: NSSlider {
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor private final class CursorCheckButton: ClickableButton {
    var recorded:[NSCursor]=[]
    var recordedRects:[NSRect]=[]
    var simulatedVisibleRect:NSRect?
    override var visibleRect:NSRect { simulatedVisibleRect ?? super.visibleRect }
    override func addCursorRect(_ rect:NSRect,cursor:NSCursor) { recorded.append(cursor);recordedRects.append(rect) }
}

@MainActor private final class CursorCheckPopup: ClickablePopUpButton {
    var recordedRects:[NSRect]=[]
    override var visibleRect:NSRect { NSRect(x:-40,y:-40,width:240,height:160) }
    override func addCursorRect(_ rect:NSRect,cursor:NSCursor) { recordedRects.append(rect) }
}

@MainActor private final class CursorCheckRegion: ClickableCursorView {
    var recordedRects:[NSRect]=[]
    override var visibleRect:NSRect { NSRect(x:-40,y:-40,width:200,height:160) }
    override func addCursorRect(_ rect:NSRect,cursor:NSCursor) { recordedRects.append(rect) }
}

@MainActor private final class PointerInteractionState: ObservableObject {
    var presses: [String: Int] = [:]
    func press(_ name: String) { presses[name, default: 0] += 1 }
}
private struct PointerInteractionRoot: View {
    let state: PointerInteractionState
    var body: some View {
        VStack(spacing: 16) {
            Button { state.press("plain") } label: {
                Text("Plain").frame(width: 180, height: 36).background(Color.blue.opacity(0.25))
            }.buttonStyle(ClickablePlainButtonStyle())
            Button { state.press("regular") } label: { Text("Regular").frame(width: 180) }.buttonStyle(WBButtonStyle())
            Button { state.press("primary") } label: { Text("Primary").frame(width: 180) }.buttonStyle(WBButtonStyle(primary: true))
            Button { state.press("destructive") } label: { Text("Destructive").frame(width: 180) }.buttonStyle(WBButtonStyle(destructive: true))
            Button { state.press("quiet") } label: { Text("Quiet").frame(width: 180, height: 30) }.buttonStyle(WBQuietButtonStyle())
            Button { state.press("icon") } label: { Image(systemName: "plus") }.buttonStyle(WBIconButtonStyle(size: 36))
            Button { state.press("selected") } label: { Text("Selected").frame(width: 180, height: 32) }.buttonStyle(WBSelectableButtonStyle(selected: true))
            Button { state.press("disabled") } label: { Text("Disabled").frame(width: 180) }.buttonStyle(WBButtonStyle()).disabled(true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.8))
            .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.70, backgroundMotion: false)
    }
}
