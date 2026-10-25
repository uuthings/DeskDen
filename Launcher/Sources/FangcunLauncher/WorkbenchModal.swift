import AppKit
import Combine
import SwiftUI

/// App-owned dialogs live in the shared window instead of a second, titlebar-
/// attached sheet. Their view identity and drafts survive hiding the window.
@MainActor final class WorkbenchModalCoordinator: ObservableObject {
    struct Presentation: Identifiable {
        let id: UUID
        var parentID: UUID?
        var width: CGFloat
        var content: AnyView
        var requestDismiss: () -> Void
        var isStillPresented: () -> Bool
        var invalidate:()->Void
    }
    @Published private(set) var presentations: [Presentation] = []
    weak var hostWindow: NSWindow?
    var isPresented: Bool { presentations.contains { $0.isStillPresented() } }
    var top: Presentation? { presentations.last { $0.isStillPresented() } }

    func prune() {
        for item in presentations where !item.isStillPresented() { remove(item.id) }
    }
    func present(id: UUID, parentID: UUID?, width: CGFloat, content: AnyView, requestDismiss: @escaping () -> Void, isStillPresented: @escaping () -> Bool,invalidate:@escaping ()->Void) {
        prune()
        if let index = presentations.firstIndex(where: { $0.id == id }) {
            presentations[index] = .init(id: id, parentID:parentID, width: width, content: content, requestDismiss: requestDismiss, isStillPresented: isStillPresented,invalidate:invalidate)
        } else {
            hostWindow?.makeFirstResponder(nil)
            presentations.append(.init(id: id, parentID:parentID, width: width, content: content, requestDismiss: requestDismiss, isStillPresented: isStillPresented,invalidate:invalidate))
        }
    }
    func remove(_ id: UUID) {
        let descendants=presentations.filter{$0.parentID == id}
        presentations.removeAll { $0.id == id }
        for child in descendants {child.invalidate();remove(child.id)}
    }
    func dismissTop() { top?.requestDismiss() }
    func clear() {let previous=presentations;presentations=[];for item in previous {item.invalidate()}}
}

private struct WorkbenchModalCoordinatorKey: EnvironmentKey {
    static let defaultValue: WorkbenchModalCoordinator? = nil
}
private struct WorkbenchModalParentKey: EnvironmentKey {static let defaultValue:UUID?=nil}
extension EnvironmentValues {
    fileprivate var workbenchModalParent:UUID? {
        get {self[WorkbenchModalParentKey.self]}
        set {self[WorkbenchModalParentKey.self]=newValue}
    }
    var workbenchModals: WorkbenchModalCoordinator? {
        get { self[WorkbenchModalCoordinatorKey.self] }
        set { self[WorkbenchModalCoordinatorKey.self] = newValue }
    }
}

struct WorkbenchModalHost: View {
    @ObservedObject var coordinator: WorkbenchModalCoordinator
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        GeometryReader { viewport in
            if let presentation = coordinator.top {
                ZStack {
                    Color(red: 0.086, green: 0.153, blue: 0.259).opacity(0.33)
                        .contentShape(Rectangle()).onTapGesture { coordinator.dismissTop() }
                    ForEach(coordinator.presentations) { item in
                    item.content
                        .frame(width: min(item.width, max(0, viewport.size.width - 48)))
                        .fixedSize(horizontal: false, vertical: true)
                        .background(WorkbenchMaterialSurface(kind: .panel, radius: 14))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.30), radius: 30, y: 16)
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isModal)
                        .id(item.id)
                        .opacity(item.id == presentation.id ? 1:0)
                        .disabled(item.id != presentation.id)
                        .allowsHitTesting(item.id == presentation.id)
                        .accessibilityHidden(item.id != presentation.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onExitCommand { coordinator.dismissTop() }
            }
        }
        .accessibilityElement(children:.contain).accessibilityIdentifier("fc.modal.host")
        .allowsHitTesting(coordinator.isPresented)
    }
}

private struct WorkbenchBooleanModal<ModalContent: View>: ViewModifier {
    @Binding var presented: Bool
    var width: CGFloat
    var onDismiss: (() -> Void)?
    var onRequestDismiss: (() -> Void)?
    let makeContent: () -> ModalContent
    @Environment(\.workbenchModals) private var coordinator
    @Environment(\.workbenchModalParent) private var parentID
    @State private var identity = UUID()
    @State private var wasPresented = false

    func body(content: Content) -> some View {
        content.onChange(of: presented, initial: true) { _, value in
            if value {
                wasPresented = true
                coordinator?.present(id: identity, parentID:parentID, width: width, content: AnyView(makeContent().environment(\.workbenchModalParent,identity)), requestDismiss: {
                    if let onRequestDismiss { onRequestDismiss() } else { presented = false }
                }, isStillPresented: { presented },invalidate:{presented=false})
            } else {
                coordinator?.remove(identity)
                if wasPresented { wasPresented = false; onDismiss?() }
            }
        }
    }
}

private struct WorkbenchItemModal<Item: Identifiable, ModalContent: View>: ViewModifier {
    @Binding var item: Item?
    var width: CGFloat
    var onDismiss: (() -> Void)?
    var onRequestDismiss: (() -> Void)?
    let makeContent: (Item) -> ModalContent
    @Environment(\.workbenchModals) private var coordinator
    @Environment(\.workbenchModalParent) private var parentID
    @State private var identity = UUID()
    @State private var wasPresented = false

    func body(content: Content) -> some View {
        content.onChange(of: item?.id, initial: true) { _, _ in
            if let item {
                wasPresented = true
                coordinator?.present(id: identity, parentID:parentID, width: width, content: AnyView(makeContent(item).id(item.id).environment(\.workbenchModalParent,identity)), requestDismiss: {
                    if let onRequestDismiss { onRequestDismiss() } else { self.item = nil }
                }, isStillPresented: { self.item != nil },invalidate:{self.item=nil})
            } else {
                coordinator?.remove(identity)
                if wasPresented { wasPresented = false; onDismiss?() }
            }
        }
    }
}

extension View {
    func workbenchModal<ModalContent: View>(isPresented: Binding<Bool>, width: CGFloat = 470,
        onDismiss: (() -> Void)? = nil, onRequestDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> ModalContent) -> some View {
        modifier(WorkbenchBooleanModal(presented: isPresented, width: width, onDismiss: onDismiss,
            onRequestDismiss: onRequestDismiss, makeContent: content))
    }
    func workbenchModal<Item: Identifiable, ModalContent: View>(item: Binding<Item?>, width: CGFloat = 470,
        onDismiss: (() -> Void)? = nil, onRequestDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> ModalContent) -> some View {
        modifier(WorkbenchItemModal(item: item, width: width, onDismiss: onDismiss,
            onRequestDismiss: onRequestDismiss, makeContent: content))
    }
}

/// Overlay scrollers never reserve document width. Keep the policy active
/// across SwiftUI disabled/modal transitions and system scrollbar preferences.
struct WorkbenchOverlayScrollbars: View {
    var body: some View {
        WorkbenchScrollbarConfigurationProbe().frame(width: 0, height: 0)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
private struct WorkbenchScrollbarConfigurationProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.configure() }
    final class Probe: NSView {
        private weak var ownerScroll: NSScrollView?
        private var styleObservation: NSKeyValueObservation?
        private var scrollerObservation: NSKeyValueObservation?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { styleObservation = nil; scrollerObservation = nil; ownerScroll = nil }
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
        func configure() {
            guard let scroll = enclosingScrollView else {
                DispatchQueue.main.async { [weak self] in self?.applyToEnclosingScroll() }
                return
            }
            apply(scroll)
        }
        private func applyToEnclosingScroll() { if let scroll = enclosingScrollView { apply(scroll) } }
        private func apply(_ scroll: NSScrollView) {
            if ownerScroll !== scroll {
                ownerScroll = scroll
                styleObservation = scroll.observe(\.scrollerStyle, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.configure() }
                }
                scrollerObservation = scroll.observe(\.hasVerticalScroller, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.configure() }
                }
            }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
            scroll.drawsBackground = false
        }
    }
}
