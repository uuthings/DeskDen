import AppKit
import Combine
import SwiftUI
import LauncherCore

/// A diagnostic matrix, not a declaration that any particular AppKit/SwiftUI
/// hit-test result is correct. Only control mounting and finite geometry count
/// as assertions. No menu is opened, pointer event posted, shortcut registered,
/// application activated, preference loaded, or user file touched.
@MainActor enum WorkbenchNativeControlHitChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
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
