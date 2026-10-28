import AppKit
import SwiftUI
import LauncherCore

/// Presentation follows the same policy used by the execution service. It never
/// substitutes a menu decision for the identity checks performed after consent.
struct DeviceProcessActionAvailability {
    let canQuit: Bool
    let canForce: Bool
    let protection: DeviceProcessProtectionInfo?

    init(name: String, members: [DeviceProcess], wholeApplication: Bool, memoryFocused: Bool,
         currentUID: UInt32 = getuid(), currentPID: Int32 = getpid(),
         currentApplicationPath: String? = Bundle.main.bundleURL.resolvingSymlinksInPath().path) {
        func allowed(_ process: DeviceProcess) -> Bool {
            DeviceProcessActions.isAllowed(process, currentUID: currentUID, currentPID: currentPID,
                                           currentApplicationPath: currentApplicationPath)
        }
        let allAllowed = !members.isEmpty && members.allSatisfy(allowed)
        canQuit = !members.isEmpty
            && (wholeApplication ? members.first(where: \.isApplicationMain).map(allowed) ?? false : allAllowed)
            && (!memoryFocused || members.allSatisfy { $0.application != nil })
        canForce = allAllowed

        var reasons: [String] = []
        func add(_ value: String) { if !reasons.contains(value) { reasons.append(value) } }
        for process in members where !allowed(process) {
            if process.pid == currentPID || (currentApplicationPath != nil && process.application?.bundlePath == currentApplicationPath) {
                add("方寸及其辅助进程由应用自身管理。")
            } else if process.pid <= 1 || ["/System/Library/", "/usr/", "/bin/", "/sbin/"].contains(where: { process.executablePath?.hasPrefix($0) == true }) {
                add("系统服务受保护，避免影响 macOS 的正常运行。")
            } else if let owner = process.ownerUID, owner != currentUID {
                add("此进程属于其他用户，不能在此结束。")
            } else {
                add("当前无法完整核验进程身份，暂不允许结束。")
            }
        }
        if members.isEmpty { add("此进程已不在当前读数中，请重新选择。") }
        if wholeApplication && !members.contains(where: \.isApplicationMain) {
            add("暂未读到应用主进程，无法请求整个应用正常退出；可展开后查看各进程。")
        }
        if memoryFocused && members.contains(where: { $0.application == nil }) {
            add("内存详情中的独立后台进程仅供查看；应用退出需有可核验的应用归属。")
        }
        if reasons.isEmpty { protection = nil }
        else {
            let guidance = canQuit
                ? "仍可请求已核验的应用主进程正常退出；整组强制结束不可用。所有操作均需另行确认。"
                : canForce && !memoryFocused
                    ? "仍可查看详情。强制结束需要单独确认，不会自动作为正常退出的替代操作。"
                    : "你仍可查看进程详情；此处不会执行退出或强制结束。"
            protection = .init(name: name, badge: canQuit || (canForce && !memoryFocused) ? "受限" : "只读",
                               reason: reasons.joined(separator: "\n"), guidance: guidance)
        }
    }
}

struct DeviceProcessProtectionInfo {
    let name: String
    let badge: String
    let reason: String
    let guidance: String
}

/// The table's trailing action column needs an explicit right-aligned anchor.
/// A stock SwiftUI Menu positions from its leading edge on macOS.
struct DeviceProcessActionsMenu: NSViewRepresentable {
    let name: String
    let wholeApplication: Bool
    let canQuit: Bool
    let canForce: Bool
    let textColor: NSColor
    let viewDetails: () -> Void
    let request: (DeviceProcessActionMode) -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchPalette) private var palette

    func makeNSView(context: Context) -> DeviceProcessMenuButton {
        let button = DeviceProcessMenuButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: DeviceProcessMenuButton, context: Context) {
        button.processName = name; button.wholeApplication = wholeApplication
        button.canQuit = canQuit; button.canForce = canForce
        button.isEnabled = enabled
        button.contentTintColor = textColor
        button.palette = palette
        button.viewDetails = viewDetails; button.request = request
        button.setAccessibilityLabel("\(name) 的进程操作")
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DeviceProcessMenuButton, context: Context) -> CGSize? {
        CGSize(width: 28, height: 28)
    }
}

@MainActor final class DeviceProcessMenuButton: ClickableButton {
    var processName = "进程"
    var wholeApplication = false
    var canQuit = false
    var canForce = false
    var viewDetails: () -> Void = {}
    var request: (DeviceProcessActionMode) -> Void = { _ in }
    var palette = ThemePalette() { didSet { needsDisplay = true } }
    private(set) var activeMenu: NSMenu?
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    override var isFlipped: Bool { true }
    override var isEnabled: Bool {
        didSet { if !isEnabled { hovering = false }; needsDisplay = true }
    }
    override var isHidden: Bool {
        didSet { if isHidden { hovering = false }; needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false; imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        symbolConfiguration = .init(pointSize: 12, weight: .regular)
        title = ""; target = self; action = #selector(openActionsMenu)
        // NSMenu uses the trigger/cell direction to choose its documented
        // top-right anchor. This symbol-only button has no text to rearrange.
        userInterfaceLayoutDirection = .rightToLeft
        cell?.userInterfaceLayoutDirection = .rightToLeft
        toolTip = "更多进程操作"
        setAccessibilityRole(.popUpButton)
        setAccessibilityIdentifier("fc.device.process.more")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = isEnabled; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let active = isEnabled && hovering, pressed = isEnabled && isHighlighted
        if active || pressed {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            palette.nsAccent.withAlphaComponent(pressed ? 0.25 : 0.15).setFill(); shape.fill()
            palette.nsAccent.withAlphaComponent(pressed ? 0.66 : 0.44).setStroke(); shape.lineWidth = 1; shape.stroke()
        }
        let color = (active || pressed ? palette.nsText : contentTintColor ?? palette.nsSecondary).withAlphaComponent(isEnabled ? 1 : 0.4)
        drawSymbol("ellipsis", in: NSRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12), color: color)
    }

    func makeActionsMenu() -> NSMenu {
        let menu = NSMenu(title: "\(processName) 的进程操作")
        menu.autoenablesItems = false; menu.font = .systemFont(ofSize: 12)
        func add(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
            let handler = DeviceProcessMenuAction { if enabled { action() } }
            let item = NSMenuItem(title: title, action: #selector(DeviceProcessMenuAction.invoke), keyEquivalent: "")
            item.target = handler; item.representedObject = handler; item.isEnabled = enabled
            menu.addItem(item)
        }
        add("查看详情", action: viewDetails)
        menu.addItem(.separator())
        let quit = request, force = request
        add(wholeApplication ? "退出整个应用" : "退出进程", enabled: canQuit) { quit(.quit) }
        add(wholeApplication ? "强制结束此组" : "强制结束进程", enabled: canForce) { force(.force) }
        if canForce, let item = menu.items.last {
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemRed])
        }
        return menu
    }

    /// Let AppKit place the actual top-right corner. A fresh NSMenu.size can be
    /// wider than its displayed size, so subtracting that estimate drifts left.
    private var menuAnchor: NSPoint {
        NSPoint(x: bounds.maxX, y: bounds.maxY + 4)
    }
    @objc private func openActionsMenu() {
        guard isEnabled, window != nil else { return }
        let menu = makeActionsMenu()
        activeMenu = menu; highlight(true)
        defer { activeMenu = nil; highlight(false) }
        menu.popUp(positioning: nil, at: menuAnchor, in: self)
    }
}

@MainActor private final class DeviceProcessMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
