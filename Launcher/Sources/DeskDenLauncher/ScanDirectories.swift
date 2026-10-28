import AppKit
import LauncherCore

@MainActor
extension LauncherController {
    func showScanDirectories() {
        guard !isPreparingToQuit else { return }
        closeOverlay(render: false)
        let card = ScanDirectoriesCard(owner: self)
        presentBindingCard(card, anchor: content, centered: true)
        editorPanel?.makeFirstResponder(card.addButton)
    }
}

@MainActor
final class ScanDirectoriesCard: CardView {
    weak var owner: LauncherController?
    private var directories: [String]
    private let original: [String]
    private let rows = FlippedView()
    private let scroll = NSScrollView()
    private var saveButton: ActionButton!
    private var closeButton: ActionButton!
    private var cancelButton: ActionButton!
    private var removeButtons: [NSView] = []
    private var confirmation: ShadeView?
    var addButton: ActionButton!
    var hasChanges: Bool { directories != original }
    var tabFocusViews: [NSView] {
        if let confirmation { return confirmation.subviews.first?.subviews.filter { $0 is ActionButton } ?? [] }
        return [closeButton].compactMap { $0 } + removeButtons + [addButton, cancelButton, saveButton].compactMap { $0 }
    }

    init(owner: LauncherController) {
        self.owner = owner; directories = owner.configuration.scanDirectories; original = directories
        super.init(frame: NSRect(x: 0, y: 0, width: 430, height: 430))
        radius = 20
        owner.label("管理扫描范围", x: 16, y: 18, width: 330, height: 24, size: 14, in: self)
        closeButton = owner.button("", symbol: "xmark", rect: NSRect(x: 386, y: 15, width: 28, height: 28), in: self) { [weak owner] in owner?.requestCloseEditor() }
        closeButton.setAccessibilityLabel("关闭扫描范围")
        scroll.frame = NSRect(x: 12, y: 60, width: 406, height: 314)
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .legacy; scroll.autohidesScrollers = true
        scroll.verticalScroller = LauncherScroller(); scroll.documentView = rows
        addSubview(scroll)
        addButton = owner.button("", symbol: "plus", rect: NSRect(x: 12, y: 386, width: 34, height: 32), border: true, in: self) { [weak self] in self?.chooseDirectory() }
        addButton.setAccessibilityLabel("添加应用扫描目录"); addButton.toolTip = "添加应用扫描目录"
        cancelButton = owner.button("取消", rect: NSRect(x: 214, y: 386, width: 96, height: 32), border: true, in: self) { [weak owner] in owner?.requestCloseEditor() }
        saveButton = owner.button("保存", rect: NSRect(x: 322, y: 386, width: 96, height: 32), primary: true, in: self) { [weak self] in _ = self?.save() }
        renderDirectories()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func renderDirectories() {
        guard let owner else { return }
        rows.subviews.forEach { $0.removeFromSuperview() }
        removeButtons = []
        let defaults = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        let all = defaults.map { ($0, true) } + directories.map { ($0, false) }
        rows.frame = NSRect(x: 0, y: 0, width: 406, height: max(314, CGFloat(all.count * 62)))
        for (index, item) in all.enumerated() {
            let y = CGFloat(index * 62)
            let icon = NSImageView(frame: NSRect(x: 8, y: y + 17, width: 26, height: 26))
            icon.image = NSWorkspace.shared.icon(forFile: item.0); rows.addSubview(icon)
            let title = item.0 == "/System/Applications" ? "系统应用程序" : item.0 == "/Applications" ? "应用程序" : item.0 == NSHomeDirectory() + "/Applications" ? "用户应用程序" : URL(fileURLWithPath: item.0).lastPathComponent
            owner.label(title, x: 46, y: y + 8, width: 286, height: 22, size: 13, in: rows)
            let path = item.0.replacingOccurrences(of: NSHomeDirectory(), with: "~", options: [.anchored])
            let pathLabel = owner.label(path, x: 46, y: y + 32, width: 310, height: 18, size: 11, color: Palette.secondary, in: rows)
            pathLabel.toolTip = item.0
            if item.1 {
                owner.label("默认", x: 355, y: y + 12, width: 38, height: 20, size: 10, color: Palette.muted, in: rows)
            } else {
                let remove = owner.button("", symbol: "minus", rect: NSRect(x: 366, y: y + 17, width: 26, height: 26), in: rows) { [weak self] in
                    self?.directories.removeAll { $0 == item.0 }; self?.renderDirectories()
                }
                remove.toolTip = "移除这个扫描目录"; remove.setAccessibilityLabel("移除扫描目录 \(title)")
                removeButtons.append(remove)
            }
        }
        saveButton?.isEnabled = directories != original
        addButton?.isEnabled = directories.count < 100
    }

    func requestClose() {
        guard let owner else { return }
        guard hasChanges else { owner.closeOverlay(); return }
        guard confirmation == nil else { return }
        let shade = ShadeView(frame: bounds)
        let card = CardView(frame: NSRect(x: 35, y: 122, width: 360, height: 186)); card.radius = 14
        shade.addSubview(card)
        owner.label("放弃当前修改？", x: 18, y: 18, width: 324, height: 24, size: 14, in: card)
        owner.label("尚未保存的扫描目录修改将被放弃。", x: 18, y: 60, width: 324, height: 38, size: 12, color: Palette.secondary, in: card)
        let back = owner.button("返回", rect: NSRect(x: 18, y: 136, width: 156, height: 32), border: true, in: card) { [weak self] in self?.dismissConfirmation() }
        owner.button("放弃修改", rect: NSRect(x: 186, y: 136, width: 156, height: 32), primary: true, in: card) { [weak owner] in owner?.closeOverlay() }
        subviews.forEach { $0.setAccessibilityHidden(true) }
        addSubview(shade); confirmation = shade; window?.makeFirstResponder(back)
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard confirmation != nil, event.keyCode == 53 else { return false }
        dismissConfirmation(); return true
    }

    private func dismissConfirmation() {
        confirmation?.removeFromSuperview(); confirmation = nil
        subviews.forEach { $0.setAccessibilityHidden(false) }
        window?.makeFirstResponder(addButton)
    }

    private func chooseDirectory() {
        guard let owner, !owner.pickerActive else { return }
        let picker = NSOpenPanel(); picker.title = "添加扫描目录"; picker.prompt = "添加"
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = true
        picker.canCreateDirectories = false
        owner.pickerActive = true
        picker.beginSheetModal(for: owner.editorPanel ?? owner.panel) { [weak self, weak owner] response in
            guard let owner else { return }; owner.pickerActive = false
            guard let self else { return }
            if response == .OK {
                let defaults = Set(["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"])
                for url in picker.urls {
                    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                    if self.directories.count < 100, !defaults.contains(path), !self.directories.contains(path) { self.directories.append(path) }
                }
                self.renderDirectories()
            }
            owner.editorPanel?.makeKeyAndOrderFront(nil); owner.editorPanel?.makeFirstResponder(self.addButton)
        }
    }

    @discardableResult func save() -> Bool {
        guard let owner else { return false }
        var candidate = owner.configuration; candidate.scanDirectories = directories
        guard owner.save(candidate) else { window?.makeKeyAndOrderFront(nil); return false }
        owner.closeOverlay(); owner.refreshApplications(force: true); return true
    }
}
