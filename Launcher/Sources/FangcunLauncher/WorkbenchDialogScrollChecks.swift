import AppKit
import SwiftUI

/// Uses real hosting/scroll views without showing a window or changing system preferences.
@MainActor enum WorkbenchDialogScrollChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") dialog scrolling: \(message)")
        }
        let state = DialogScrollFixtureState(), modals = WorkbenchModalCoordinator()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1120, height: 758), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DialogScrollFixtureRoot(state: state, modals: modals))
        window.contentView = host
        defer { modals.clear(); state.markers.removeAll(); window.contentView = nil; window.close() }
        modals.present(id: UUID(), parentID: nil, width: 470, content: AnyView(DialogScrollFixture(state: state)),
                       requestDismiss: {}, isStillPresented: { true }, invalidate: {})
        for light in [false, true] {
            state.light = light
            for size in [CGSize(width: 960, height: 600), CGSize(width: 1120, height: 758), CGSize(width: 1728, height: 993)] {
                window.setContentSize(size)
                state.long = true; state.disabled = false
                await settle(host)
                let label = "\(Int(size.width))×\(Int(size.height))/\(light)"
                let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
                guard let outer = scrolls.first(where: { abs($0.bounds.width - 470) < 1 }), let document = outer.documentView else {
                    check(false, "\(label): full-width body exists"); continue
                }
                check(scrolls.count == 2 && scrolls.allSatisfy { $0.scrollerStyle == .overlay && $0.autohidesScrollers && !$0.drawsBackground },
                      "\(label): body and independent list share overlay styling")
                check(scrolls.allSatisfy { abs($0.contentSize.width - $0.bounds.width) < 1 && $0.scrollerKnobStyle == (light ? .dark : .light) },
                      "\(label): scrollbar takes no document width and follows appearance")
                let body = outer.convert(outer.bounds, to: host)
                check(abs(body.minX - (host.bounds.width - 470) / 2) < 1 && body.height <= 480 && document.bounds.height > outer.contentSize.height,
                      "\(label): long document scrolls against the dialog edge")
                let footerBefore = state.markers["footer"].map { $0.convert($0.bounds, to: host) } ?? .zero
                outer.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - outer.contentSize.height)))
                outer.reflectScrolledClipView(outer.contentView); await settle(host)
                let last = state.markers["last"].map { $0.convert($0.bounds, to: outer.contentView) } ?? .zero
                let footerAfter = state.markers["footer"].map { $0.convert($0.bounds, to: host) } ?? .zero
                check(last.height > 0 && outer.contentView.bounds.contains(last.insetBy(dx: 1, dy: 1)), "\(label): final field can be scrolled fully into view")
                check(footerBefore.height > 0 && footerBefore == footerAfter && host.bounds.contains(footerAfter), "\(label): footer stays fixed and inside the window")
                state.disabled = true
                for scroll in scrolls { scroll.scrollerStyle = .legacy }
                await settle(host)
                check(scrolls.allSatisfy { $0.scrollerStyle == .overlay && abs($0.contentSize.width - $0.bounds.width) < 1 },
                      "\(label): disabled content and style changes cannot restore a reserved track")
                state.long = false; state.disabled = false; await settle(host)
                check(outer.bounds.height < 160 && outer.documentView.map { $0.bounds.height <= outer.contentSize.height + 1 } == true,
                      "\(label): short confirmation shrinks to its content")
                check(!window.isVisible && !window.isKeyWindow, "\(label): checks remain offscreen")
            }
        }
        return (count, failures)
    }
    private static func settle(_ host: NSView) async {
        try? await Task.sleep(for: .milliseconds(160)); host.layoutSubtreeIfNeeded()
    }
    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

@MainActor private final class DialogScrollFixtureState: ObservableObject {
    @Published var long = true
    @Published var light = false
    @Published var disabled = false
    var markers: [String: NSView] = [:]
}
private struct DialogScrollFixtureRoot: View {
    @ObservedObject var state: DialogScrollFixtureState
    @ObservedObject var modals: WorkbenchModalCoordinator
    var body: some View {
        WorkbenchModalHost(coordinator: modals)
            .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.7, backgroundMotion: false, appearance: state.light ? .light : .dark)
    }
}
private struct DialogScrollFixture: View {
    @ObservedObject var state: DialogScrollFixtureState
    var body: some View {
        WorkbenchDialogFrame(title: "滚动布局验收", dismiss: {}) {
            VStack(alignment: .leading, spacing: 12) {
                Text("表单说明")
                if state.long {
                    WorkbenchScrollView {
                        VStack { ForEach(0..<12) { Text("独立列表 \($0)").frame(maxWidth: .infinity, minHeight: 28) } }
                    }.frame(maxHeight: 80)
                    ForEach(0..<30) { Text("表单字段 \($0)").frame(height: 30) }
                }
                Text("最后一项").frame(height: 32).background(DialogScrollMarker(state: state, name: "last"))
            }.disabled(state.disabled)
        } actions: {
            Spacer()
            Button("完成") {}.buttonStyle(WBButtonStyle(primary: true))
                .background(DialogScrollMarker(state: state, name: "footer"))
        }
    }
}
private struct DialogScrollMarker: NSViewRepresentable {
    let state: DialogScrollFixtureState
    let name: String
    func makeNSView(context: Context) -> NSView { let view = NSView(); state.markers[name] = view; return view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
