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
private struct WorkbenchModalBodyLimitKey: EnvironmentKey { static let defaultValue: CGFloat = .infinity }
extension EnvironmentValues {
    fileprivate var workbenchModalBodyLimit: CGFloat {
        get { self[WorkbenchModalBodyLimitKey.self] }
        set { self[WorkbenchModalBodyLimitKey.self] = newValue }
    }
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
                    Color.black.opacity(palette.light ? 0.12 : 0.18)
                        .contentShape(Rectangle()).onTapGesture { coordinator.dismissTop() }
                    ForEach(coordinator.presentations) { item in
                    item.content
                        .environment(\.workbenchModalBodyLimit, max(40, viewport.size.height - 48 - 140))
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

/// Every workbench scroll region uses the same policy, including nested lists.
/// The probe must be inside the document to configure the owning NSScrollView.
struct WorkbenchScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let showsIndicators: Bool
    private let content: Content
    init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.axes = axes; self.showsIndicators = showsIndicators; self.content = content()
    }
    var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content.background(WorkbenchOverlayScrollbars())
        }
    }
}

/// The viewport fills the dialog width; reading gutters belong to its document.
/// Short confirmations stay compact, while long forms keep header/actions fixed.
struct WorkbenchDialogBody<Content: View>: View {
    var maximumHeight: CGFloat = 480
    @ViewBuilder var content: () -> Content
    @Environment(\.workbenchModalBodyLimit) private var viewportLimit
    @State private var measuredHeight: CGFloat = 0
    var body: some View {
        WorkbenchScrollView {
            content().frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18).padding(.bottom, 18)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: WorkbenchDialogBodyHeightKey.self, value: geometry.size.height)
                        .allowsHitTesting(false)
                })
        }
        .frame(height: min(maximumHeight, viewportLimit, max(36, measuredHeight > 0 ? measuredHeight : 60)))
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(WorkbenchDialogBodyHeightKey.self) { height in
            // Ignore transient default preferences during disabled/modal changes.
            if height.isFinite, height > 0, abs(measuredHeight - height) > 0.25 { measuredHeight = height }
        }
    }
}
private struct WorkbenchDialogBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Overlay scrollers never reserve document width. Keep the policy active
/// across SwiftUI disabled/modal transitions and system scrollbar preferences.
struct WorkbenchOverlayScrollbars: View {
    @Environment(\.colorScheme) private var scheme
    private var light: Bool { scheme == .light }
    var body: some View {
        WorkbenchScrollbarConfigurationProbe(light: light).frame(width: 0, height: 0)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
private struct WorkbenchScrollbarConfigurationProbe: NSViewRepresentable {
    let light: Bool
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.light = light; return view }
    func updateNSView(_ view: Probe, context: Context) { view.light = light; view.configure() }
    final class Probe: NSView {
        var light = false
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
            scroll.scrollerKnobStyle = light ? .dark : .light
            scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
    }
}

struct WorkbenchDialogFrame<Content:View,Actions:View>:View {
    let title:String
    let dismiss:()->Void
    var maximumBodyHeight: CGFloat = 480
    @ViewBuilder let content:()->Content
    @ViewBuilder let actions:()->Actions
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {Text(title).font(.system(size:15,weight:.medium));Spacer();Button(action:dismiss){Image(systemName:"xmark")}.buttonStyle(WBIconButtonStyle(size:32)).accessibilityLabel("关闭"+title)}.padding(EdgeInsets(top:18,leading:18,bottom:13,trailing:18))
            WorkbenchDialogBody(maximumHeight: maximumBodyHeight, content: content)
            Rectangle().fill(palette.line).frame(height:1)
            HStack(spacing:8){actions()}.padding(.horizontal,18).padding(.vertical,13)
        }.foregroundStyle(palette.text).accessibilityElement(children:.contain).accessibilityLabel(title)
    }
}
