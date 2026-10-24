import AppKit
import LauncherCore

@MainActor
final class LauncherSettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Page: Int, CaseIterable {
        case general, shortcuts, panel
        var title: String { ["通用", "快捷键", "主面板"][rawValue] }
        var symbol: String { ["app", "keyboard", "rectangle.3.group"][rawValue] }
        var keywords: String {
            switch self {
            case .general: "外观 深色 浅色 启动 收起 动效 备份 恢复"
            case .shortcuts: "键位 直达 前缀 呼出 应用 快捷键"
            case .panel: "启用 显示 名称 图标 布局 翻页 滚动 搜索 输入 扫描 目录 刷新"
            }
        }
    }
    private weak var launcher: LauncherController?
    private let root = FlippedView()
    private let embeddedRoot = LauncherSettingsEmbeddedRoot()
    private var embedding = false
    private let sidebar = NSVisualEffectView()
    private let search = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let pageContent = FlippedView()
    private let titleLabel = NSTextField(labelWithString: "通用")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let backButton = ClickableButton()
    private let forwardButton = ClickableButton()
    private var actions: [SettingsControlAction] = []
    private var headerActions: [SettingsControlAction] = []
    private var pages = Page.allCases
    private var page: Page = .general
    private var history: [Page] = [.general]
    private var historyIndex = 0
    private var recorder: NSButton?
    private var recordingApplicationShortcut = false
    private var keyMonitor: Any?
    private let width: CGFloat = 485
    private var cursorY: CGFloat = 10

    init(owner launcher: LauncherController, autosavesFrame: Bool = true) {
        self.launcher = launcher
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 670), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "方寸设置"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.delegate = self; window.isMovableByWindowBackground = true
        window.setFrame(NSRect(x: 0, y: 0, width: 740, height: 698), display: false)
        window.center(); if autosavesFrame { window.setFrameAutosaveName("FangcunLauncherSettings") }
        root.frame = NSRect(origin: .zero, size: NSSize(width: 740, height: 698)); root.autoresizingMask = [.width, .height]
        window.contentView = root
        buildChrome(); applyAppearance(); renderPage()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        guard launcher?.isPreparingToQuit == false else { return }
        guard let window else { return }
        if pageContent.superview === embeddedRoot {
            stopEmbedding();pageContent.removeFromSuperview();scroll.documentView=pageContent
            statusLabel.removeFromSuperview();statusLabel.frame=NSRect(x:235,y:662,width:width,height:30);root.addSubview(statusLabel)
        }
        cancelRecording(); applyAppearance(); renderPage()
        showWindow(nil); NSApp.activate(); window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }
    func embeddedPage(section: Int) -> NSView {
        let target=Page(rawValue:section) ?? .general
        let needsRender = !embedding || page != target
        embedding=true
        if needsRender {cancelRecording();page=target;renderPage()}
        applyAppearance()
        embeddedRoot.appearance=NSAppearance(named:launcher?.configuration.settings.lightAppearance == true ? .aqua:.darkAqua)
        if pageContent.superview !== embeddedRoot {
            scroll.documentView=nil;pageContent.removeFromSuperview();embeddedRoot.addSubview(pageContent)
            statusLabel.removeFromSuperview();embeddedRoot.addSubview(statusLabel)
        }
        embeddedRoot.widthChanged={ [weak self] width in _=self?.embeddedSize(width:width) }
        _=embeddedSize(width:embeddedRoot.bounds.width > 0 ? embeddedRoot.bounds.width:485)
        installKeyMonitor();return embeddedRoot
    }
    /// The workbench owns vertical scrolling; native controls retain their responders.
    func embeddedSize(width proposedWidth:CGFloat)->NSSize {
        let available=proposedWidth.isFinite && proposedWidth > 0 ? proposedWidth:max(485,embeddedRoot.bounds.width)
        let width=max(485,available),contentHeight=cursorY+12
        let statusHeight:CGFloat=statusLabel.stringValue.isEmpty ? 0:42
        pageContent.frame=NSRect(x:0,y:0,width:width,height:contentHeight)
        statusLabel.frame=NSRect(x:4,y:contentHeight+6,width:width-8,height:30)
        embeddedRoot.contentHeight=contentHeight+statusHeight
        return NSSize(width:width,height:embeddedRoot.contentHeight)
    }
    func stopEmbedding() {
        cancelRecording();embedding=false
        if let keyMonitor {NSEvent.removeMonitor(keyMonitor);self.keyMonitor=nil}
    }
    func cancelEmbeddedRecording() {cancelRecording()}
    func windowWillClose(_ notification: Notification) {
        cancelRecording()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }
    func windowDidResignKey(_ notification: Notification) { cancelRecording() }

    private func buildChrome() {
        sidebar.frame = NSRect(x: 0, y: 0, width: 215, height: 698)
        sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow; sidebar.state = .active
        sidebar.autoresizingMask = [.height]; root.addSubview(sidebar)
        search.frame = NSRect(x: 10, y: 62, width: 195, height: 28)
        search.placeholderString = "搜索"; search.delegate = self; search.setAccessibilityLabel("搜索设置")
        root.addSubview(search)
        let tableScroll = NSScrollView(frame: NSRect(x: 10, y: 106, width: 195, height: 160))
        tableScroll.drawsBackground = false; tableScroll.borderType = .noBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settingsPage")); column.width = 195
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 32; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .sourceList; table.backgroundColor = .clear
        table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("设置分类")
        tableScroll.documentView = table; root.addSubview(tableScroll)

        for (button, symbol, x) in [(backButton, "chevron.left", CGFloat(225)), (forwardButton, "chevron.right", CGFloat(260))] {
            button.frame = NSRect(x: x, y: 14, width: 34, height: 32); button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "chevron.left" ? "后退" : "前进")
            button.bezelStyle = .texturedRounded; button.imagePosition = .imageOnly
            root.addSubview(button)
        }
        connect(backButton, persistent: true) { [weak self] in self?.navigateHistory(-1) }
        connect(forwardButton, persistent: true) { [weak self] in self?.navigateHistory(1) }
        titleLabel.frame = NSRect(x: 307, y: 19, width: 390, height: 24); titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        root.addSubview(titleLabel)
        scroll.frame = NSRect(x: 215, y: 58, width: 525, height: 608); scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.documentView = pageContent; root.addSubview(scroll)
        statusLabel.frame = NSRect(x: 235, y: 662, width: width, height: 30); statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor; statusLabel.maximumNumberOfLines = 2; root.addSubview(statusLabel)
    }
    private func applyAppearance() {
        guard let launcher else { return }
        let light = launcher.configuration.settings.lightAppearance
        window?.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window?.backgroundColor = NSColor(calibratedWhite: light ? 0.94 : 0.118, alpha: 1)
    }
    private func select(_ selected: Page, addHistory: Bool = true) {
        guard selected != page else { return }
        cancelRecording(); page = selected
        if addHistory {
            history = Array(history.prefix(historyIndex + 1)); history.append(selected); historyIndex = history.count - 1
        }
        renderPage(); scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func navigateHistory(_ direction: Int) {
        let next = historyIndex + direction
        guard history.indices.contains(next) else { return }
        historyIndex = next; select(history[next], addHistory: false)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let value = pages[row]
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 195, height: 32))
        let icon = NSImageView(frame: NSRect(x: 8, y: 5, width: 22, height: 22)); icon.image = NSImage(systemSymbolName: value.symbol, accessibilityDescription: nil)
        icon.contentTintColor = value == .general ? .secondaryLabelColor : .controlAccentColor; cell.addSubview(icon); cell.imageView = icon
        let label = NSTextField(labelWithString: value.title); label.frame = NSRect(x: 37, y: 7, width: 146, height: 20); label.font = .systemFont(ofSize: 14, weight: .medium)
        cell.addSubview(label); cell.textField = label; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard pages.indices.contains(table.selectedRow) else { return }; select(pages[table.selectedRow])
    }
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === search else { return }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pages = Page.allCases.filter { query.isEmpty || ($0.title + " " + $0.keywords).localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if let index = pages.firstIndex(of: page) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }

    private func renderPage() {
        pageContent.subviews.forEach { $0.removeFromSuperview() }; actions.removeAll(); recorder = nil; cursorY = 10
        titleLabel.stringValue = page.title; backButton.isEnabled = historyIndex > 0; forwardButton.isEnabled = historyIndex < history.count - 1
        if let index = pages.firstIndex(of: page) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        switch page { case .general: buildGeneral(); case .shortcuts: buildShortcuts(); case .panel: buildPanel() }
        pageContent.frame = NSRect(x: 0, y: 0, width: embedding ? 485:525, height: embedding ? cursorY+12:max(608, cursorY + 20))
        statusLabel.stringValue = ""
        if embedding {
            for view in pageContent.subviews {
                view.autoresizingMask=[.width]
                if let group=view as? SettingsRowGroup {prepareEmbeddedControls(group)}
            }
            _=embeddedSize(width:embeddedRoot.bounds.width > 0 ? embeddedRoot.bounds.width:485)
        }
    }
    private func buildGeneral() {
        guard let launcher else { return }
        if !embedding {
        let hero = group(height: 122)
        let icon = NSImageView(frame: NSRect(x: 22, y: 29, width: 64, height: 64)); icon.image = NSImage(named: NSImage.applicationIconName); hero.addSubview(icon)
        text("方寸", x: 108, y: 24, width: 340, size: 27, weight: .semibold, in: hero)
        text("键位启动与应用搜索", x: 108, y: 64, width: 340, size: 13, color: .secondaryLabelColor, in: hero)
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            text("版本 \(version)", x: 108, y: 86, width: 340, size: 11, color: .tertiaryLabelColor, in: hero)
        }
        }
        section("外观",top:!embedding)
        let appearance = group(height: 100)
        rowLabel("界面外观", y: 0, in: appearance)
        let themes = popup(["深色", "浅色"], selected: launcher.configuration.settings.lightAppearance ? 1 : 0, x: 333, y: 13, width: 136, in: appearance)
        connect(themes) { [weak self, weak themes] in
            guard let self, let launcher = self.launcher, let themes else { return }
            if self.update({ $0.lightAppearance = themes.indexOfSelectedItem == 1 }) { self.applyAppearance() }
            else { themes.selectItem(at: launcher.configuration.settings.lightAppearance ? 1 : 0) }
        }
        separator(y: 50, in: appearance); rowLabel("面板材质", y: 50, in: appearance)
        text("通透玻璃 · 自然", x: 277, y: 66, width: 192, size: 12, color: .secondaryLabelColor, alignment: .right, in: appearance)
        section("通用设置")
        let common = group(height: 100)
        toggle("启动成功后收起面板", y: 0, value: launcher.configuration.settings.hideOnLaunch, in: common) { [weak self] value in self?.update { $0.hideOnLaunch = value } ?? false }
        separator(y: 50, in: common)
        toggle("减少动态效果", y: 50, value: launcher.configuration.settings.reduceMotion, in: common) { [weak self] value in self?.update { $0.reduceMotion = value } ?? false }
        if launcher.storageProblem != nil {
            section("配置恢复")
            let recovery = group(height: 62); rowLabel("上一次有效配置", y: 6, in: recovery)
            let button = nativeButton("恢复…", x: 369, y: 17, width: 100, in: recovery)
            connect(button) { [weak self] in
                guard let self, let launcher = self.launcher else { return }
                if launcher.recoverConfiguration() { launcher.render(); self.applyAppearance(); self.renderPage(); self.status("已恢复上一次有效配置。") }
                else { self.status(launcher.lastSaveError ?? "恢复失败，当前配置已保留。", error: true) }
            }
        }
    }
    private func buildShortcuts() {
        guard let launcher else { return }
        section("面板快捷键", top: false)
        let launches = group(height: 118)
        rowLabel("呼出按键面板", y: 5, in: launches)
        let custom=launcher.configuration.settings.launcherHotKey
        let offset=custom == nil ? 0:1
        let options=(custom.map {["自定义 · \($0.title)"]} ?? [])+HotKeyChoice.allCases.map(\.title)
        let mainSelection=custom == nil ? (HotKeyChoice.allCases.firstIndex(of:launcher.configuration.settings.hotKey) ?? 0):0
        let main=popup(options,selected:mainSelection,x:292,y:18,width:177,in:launches)
        if custom != nil {main.item(at:0)?.isEnabled=false}
        connect(main) { [weak self, weak main] in
            guard let self,self.launcher != nil,let main else {return}
            let index=main.indexOfSelectedItem-offset
            guard HotKeyChoice.allCases.indices.contains(index) else {return}
            if !self.update({$0.hotKey=HotKeyChoice.allCases[index];$0.launcherHotKey=nil}) {main.selectItem(at:mainSelection)}
        }
        separator(y: 59, in: launches); rowLabel("呼出应用面板", y: 64, in: launches)
        let record = nativeButton(launcher.configuration.settings.applicationViewHotKey?.title ?? "设置快捷键", x: 275, y: 77, width: 158, in: launches)
        record.setAccessibilityLabel("设置应用面板快捷键"); recorder = record
        connect(record) { [weak self] in self?.beginRecording() }
        let clear = nativeButton("", x: 439, y: 77, width: 30, in: launches); clear.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "清除应用面板快捷键"); clear.imagePosition = .imageOnly
        clear.isEnabled = launcher.configuration.settings.applicationViewHotKey != nil
        connect(clear) { [weak self] in
            guard let self, let launcher = self.launcher else { return }
            self.cancelRecording()
            if launcher.setApplicationViewHotKey(nil) { self.renderPage(); self.status("应用面板快捷键已清除。") }
            else { self.status(launcher.lastSaveError ?? "无法清除快捷键。", error: true) }
        }
        section("键位直达")
        let direct = group(height: 102)
        rowLabel("统一快捷键前缀", y: 3, in: direct)
        let prefixes = Self.prefixOptions
        let selected = prefixes.firstIndex { $0 == launcher.configuration.settings.directLaunchPrefix } ?? 0
        let prefix = popup(prefixes.map { $0.map { $0.title + " + 键位" } ?? "关闭" }, selected: selected, x: 292, y: 16, width: 177, in: direct)
        connect(prefix) { [weak self, weak prefix] in
            guard let self, let launcher = self.launcher, let prefix else { return }
            if launcher.setDirectLaunchPrefix(prefixes[prefix.indexOfSelectedItem]) { launcher.render(); self.status("") }
            else { prefix.selectItem(at: prefixes.firstIndex { $0 == launcher.configuration.settings.directLaunchPrefix } ?? 0); self.status(launcher.lastSaveError ?? "快捷键发生冲突，原设置已保留。", error: true) }
        }
        text("在任意应用中按“前缀 + 键位”直接打开绑定；单独设置的键位快捷键优先生效。", x: 12, y: 57, width: 461, height: 34, size: 11, color: .secondaryLabelColor, in: direct)
        section("面板内操作")
        let keys = group(height: 100)
        rowLabel("切换按键与应用视图", y: 0, in: keys); text("Tab", x: 353, y: 16, width: 116, size: 13, color: .secondaryLabelColor, alignment: .right, in: keys)
        separator(y: 50, in: keys); rowLabel("进入文字输入", y: 50, in: keys); text("⌘ F", x: 353, y: 66, width: 116, size: 13, color: .secondaryLabelColor, alignment: .right, in: keys)
    }
    private static var prefixOptions: [KeyShortcutPrefix?] {
        var result: [KeyShortcutPrefix?] = [nil]
        for flags in [1, 2, 8, 3, 9, 10, 11, 5, 6, 12, 7, 13, 14, 15] {
            result.append(KeyShortcutPrefix(control: flags & 1 != 0, option: flags & 2 != 0, shift: flags & 4 != 0, command: flags & 8 != 0))
        }
        return result
    }
    private func buildPanel() {
        guard let launcher else { return }
        let enabled = group(height: 128)
        featureToggle("按键面板", detail: "通过键位打开绑定的应用和内容", symbol: "square.grid.3x3", y: 0, value: launcher.configuration.settings.actionsEnabled, in: enabled) { [weak self] value in
            self?.update { $0.actionsEnabled = value } ?? false
        }
        separator(y: 64, in: enabled)
        featureToggle("应用面板", detail: "搜索和浏览已扫描的应用", symbol: "magnifyingglass", y: 64, value: launcher.configuration.settings.applicationsEnabled, in: enabled) { [weak self] value in
            self?.update { $0.applicationsEnabled = value } ?? false
        }
        section("面板切换")
        let switching = group(height: 84)
        toggle("滚动切换", y: 0, value: launcher.configuration.settings.scrollSwitchesViews, in: switching) { [weak self] value in
            self?.update { $0.scrollSwitchesViews = value } ?? false
        }
        text("横向翻页时，左右滚动可在按键面板与应用面板之间切换。", x: 12, y: 49, width: 461, height: 28, size: 11, color: .secondaryLabelColor, in: switching)
        section("应用面板搜索")
        let input = group(height: 116)
        text("默认输入方式", x: 12, y: 13, width: 440, size: 13, weight: .medium, in: input)
        text("按键搜索支持拼音、首字母和数字启动；文字输入使用当前输入法。", x: 12, y: 38, width: 461, height: 30, size: 11, color: .secondaryLabelColor, in: input)
        let inputs: [SearchInputMode] = [.quick, .text]
        let inputMode = NSSegmentedControl(labels: inputs.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        inputMode.frame = NSRect(x: 12, y: 76, width: 461, height: 30); inputMode.segmentStyle = .rounded
        inputMode.setWidth(230, forSegment: 0); inputMode.setWidth(230, forSegment: 1)
        inputMode.selectedSegment = launcher.configuration.settings.defaultSearchInputMode == .quick ? 0 : 1
        inputMode.setAccessibilityLabel("默认搜索输入方式"); input.addSubview(inputMode)
        connect(inputMode) { [weak self, weak inputMode] in
            guard let self, let launcher = self.launcher, let inputMode else { return }
            if !self.update({ $0.defaultSearchInputMode = inputs[inputMode.selectedSegment] }) {
                inputMode.selectedSegment = launcher.configuration.settings.defaultSearchInputMode == .quick ? 0 : 1
            }
        }
        section("应用面板布局")
        let layout = group(height: 92)
        text("排列方式", x: 12, y: 13, width: 440, size: 13, weight: .medium, in: layout)
        let segments = NSSegmentedControl(labels: ["横向翻页", "纵向滚动"], trackingMode: .selectOne, target: nil, action: nil)
        segments.frame = NSRect(x: 12, y: 43, width: 461, height: 33); segments.segmentStyle = .rounded
        segments.setWidth(230, forSegment: 0); segments.setWidth(230, forSegment: 1)
        segments.selectedSegment = launcher.configuration.settings.resultLayout == .grid ? 0 : 1; layout.addSubview(segments)
        connect(segments) { [weak self, weak segments] in
            guard let self, let launcher = self.launcher, let segments else { return }
            if self.update({ $0.resultLayout = segments.selectedSegment == 0 ? .grid : .list }) { launcher.resetSearchSelection(); launcher.render() }
            else { segments.selectedSegment = launcher.configuration.settings.resultLayout == .grid ? 0 : 1 }
        }
        section("按键面板布局")
        let displayGroup = group(height: 58); rowLabel("显示方式", y: 4, in: displayGroup)
        let modes = DisplayMode.allCases
        let display = popup(modes.map(\.title), selected: modes.firstIndex(of: launcher.configuration.settings.display) ?? 0, x: 292, y: 17, width: 177, in: displayGroup)
        connect(display) { [weak self, weak display] in
            guard let self, let launcher = self.launcher, let display else { return }
            if !self.update({ $0.display = modes[display.indexOfSelectedItem] }) { display.selectItem(at: modes.firstIndex(of: launcher.configuration.settings.display) ?? 0) }
        }
        section("应用扫描范围")
        let directories = group(height: 228)
        let directoryScroll = NSScrollView(frame: NSRect(x: 1, y: 1, width: 483, height: 174)); directoryScroll.drawsBackground = false; directoryScroll.hasVerticalScroller = true; directoryScroll.autohidesScrollers = true; directoryScroll.scrollerStyle = .overlay
        let rows = FlippedView(); directoryScroll.documentView = rows; directories.addSubview(directoryScroll)
        let defaults = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        let entries = defaults.map { ($0, true) } + launcher.configuration.scanDirectories.map { ($0, false) }
        rows.frame = NSRect(x: 0, y: 0, width: 483, height: max(174, CGFloat(entries.count * 47)))
        for (index, entry) in entries.enumerated() {
            let y = CGFloat(index * 47)
            let icon = NSImageView(frame: NSRect(x: 12, y: y + 12, width: 23, height: 23)); icon.image = NSWorkspace.shared.icon(forFile: entry.0); rows.addSubview(icon)
            let name = entry.0 == "/Applications" ? "应用程序" : entry.0 == "/System/Applications" ? "系统应用程序" : entry.0 == NSHomeDirectory() + "/Applications" ? "用户应用程序" : URL(fileURLWithPath: entry.0).lastPathComponent
            text(name, x: 45, y: y + 7, width: 360, size: 12, in: rows)
            text(entry.0.replacingOccurrences(of: NSHomeDirectory(), with: "~", options: [.anchored]), x: 45, y: y + 25, width: 370, size: 10, color: .secondaryLabelColor, in: rows)
            if entry.1 { text("默认", x: 423, y: y + 15, width: 45, size: 11, color: .tertiaryLabelColor, alignment: .right, in: rows) }
            else {
                let remove = nativeButton("", x: 438, y: y + 10, width: 30, in: rows); remove.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "移除扫描目录 \(name)"); remove.imagePosition = .imageOnly
                connect(remove) { [weak self] in self?.removeScanDirectory(entry.0) }
            }
        }
        separator(y: 176, in: directories)
        let add = nativeButton("添加目录…", x: 12, y: 190, width: 112, in: directories); add.isEnabled = launcher.configuration.scanDirectories.count < 100
        connect(add) { [weak self] in self?.addScanDirectories() }
        let refresh = nativeButton("刷新应用列表", x: 341, y: 190, width: 132, in: directories)
        connect(refresh) { [weak self] in self?.launcher?.refreshApplications(force: true); self?.status("已开始刷新应用列表。") }
    }

    private func update(_ transform: (inout LauncherSettings) -> Void) -> Bool {
        guard let launcher else { return false }
        guard launcher.updateSettings(transform) else { status(launcher.lastSaveError ?? "无法保存设置，原设置已保留。", error: true); return false }
        launcher.render(); status(""); return true
    }
    private func addScanDirectories() {
        guard let launcher, let window = pageContent.window ?? window, !launcher.pickerActive else { return }
        let picker = NSOpenPanel(); picker.title = "添加扫描目录"; picker.prompt = "添加"; picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = true; picker.canCreateDirectories = false
        launcher.pickerActive = true
        picker.beginSheetModal(for: window) { [weak self, weak launcher] response in
            guard let launcher else { return }; launcher.pickerActive = false
            guard let self, response == .OK else { return }
            var candidate = launcher.configuration
            let defaults = Set(["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"])
            for url in picker.urls {
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                if candidate.scanDirectories.count < 100, !defaults.contains(path), !candidate.scanDirectories.contains(path) { candidate.scanDirectories.append(path) }
            }
            guard candidate.scanDirectories != launcher.configuration.scanDirectories else { return }
            if launcher.save(candidate) { launcher.refreshApplications(force: true); self.renderPage(); self.status("扫描范围已更新。") }
            else { self.status(launcher.lastSaveError ?? "无法保存扫描范围。", error: true) }
        }
    }
    private func removeScanDirectory(_ path: String) {
        guard let launcher else { return }
        var candidate = launcher.configuration; candidate.scanDirectories.removeAll { $0 == path }
        if launcher.save(candidate) { launcher.refreshApplications(force: true); renderPage(); status("扫描范围已更新。") }
        else { status(launcher.lastSaveError ?? "无法保存扫描范围。", error: true) }
    }
    private func beginRecording() {
        guard launcher?.isPreparingToQuit == false else { return }
        recordingApplicationShortcut = true; recorder?.title = "请按下快捷键…"
        (pageContent.window ?? window)?.makeFirstResponder(recorder); status("包含 ⌃、⌥ 或 ⌘，按 Esc 取消录制。")
    }
    private func cancelRecording() {
        guard recordingApplicationShortcut else { return }
        recordingApplicationShortcut = false; recorder?.title = launcher?.configuration.settings.applicationViewHotKey?.title ?? "设置快捷键"
        status("")
    }
    func captureRegisteredHotKey(_ shortcut: BindingHotKey) -> Bool {
        guard launcher?.isPreparingToQuit == false else { return false }
        guard (embedding ? pageContent.window : window)?.isVisible == true, (embedding ? pageContent.window : window)?.isKeyWindow == true, recordingApplicationShortcut else { return false }
        acceptApplicationShortcut(shortcut); return true
    }
    private func acceptApplicationShortcut(_ shortcut: BindingHotKey) {
        guard let launcher, !launcher.isPreparingToQuit else { return }
        do { try shortcut.validate() }
        catch { status(error.localizedDescription, error: true); return }
        if launcher.setApplicationViewHotKey(shortcut) {
            recordingApplicationShortcut = false; renderPage(); status("应用面板快捷键已更新。")
        } else { status(launcher.lastSaveError ?? "快捷键已被占用，原设置已保留。", error: true) }
    }
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleEvent(event) ?? false }
            return handled ? nil : event
        }
    }
    func handleEvent(_ event: NSEvent) -> Bool {
        guard launcher?.isPreparingToQuit == false else { cancelRecording(); return false }
        guard let eventWindow=event.window, eventWindow === window || (embedding && eventWindow === pageContent.window) else { return false }
        if event.type == .leftMouseDown {
            if recordingApplicationShortcut, let recorder, !recorder.bounds.contains(recorder.convert(event.locationInWindow, from: nil)) { cancelRecording() }
            return false
        }
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Recording owns the combination before normal window commands such as Command-W.
        if recordingApplicationShortcut {
            if event.keyCode == 53 { cancelRecording(); return true }
            if event.keyCode == 48, flags.intersection([.control, .option, .command]).isEmpty { cancelRecording(); return false }
            acceptApplicationShortcut(BindingHotKey(keyCode: event.keyCode, control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift), command: flags.contains(.command)))
            return true
        }
        if flags.intersection([.control, .option, .shift, .command]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            eventWindow.performClose(nil); return true
        }
        return false
    }

    private func status(_ message: String, error: Bool = false) {
        statusLabel.stringValue = message; statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        if embedding {_=embeddedSize(width:pageContent.bounds.width)}
    }
    private func connect(_ control: NSControl, persistent: Bool = false, action: @escaping () -> Void) {
        let target = SettingsControlAction(action); control.target = target; control.action = #selector(SettingsControlAction.invoke(_:))
        if persistent { headerActions.append(target) } else { actions.append(target) }
    }
    @discardableResult private func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 20, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, alignment: NSTextAlignment = .left, in view: NSView) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value); label.frame = NSRect(x: x, y: y, width: width, height: height)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color; label.alignment = alignment; label.maximumNumberOfLines = height > 25 ? 2 : 1
        label.lineBreakMode = .byTruncatingTail; view.addSubview(label); return label
    }
    private func rowLabel(_ title: String, y: CGFloat, in view: NSView) { text(title, x: 12, y: y + 16, width: 255, in: view) }
    private func section(_ title: String, top: Bool = true) {
        cursorY += top ? 28 : 0
        text(title, x: embedding ? 4:24, y: cursorY, width: 477, size: 13, weight: embedding ? .medium:.semibold, color: .secondaryLabelColor, in: pageContent)
        cursorY += 28
    }
    private func group(height: CGFloat) -> FlippedView {
        let group = SettingsRowGroup(frame: NSRect(x: embedding ? 0:20, y: cursorY, width: width, height: height));group.embedded=embedding;pageContent.addSubview(group)
        cursorY += height; return group
    }
    private func separator(y: CGFloat, in view: NSView) {
        let line = NSBox(frame: NSRect(x: 12, y: y, width: view.bounds.width - 24, height: 1)); line.boxType = .separator; view.addSubview(line)
    }
    private func prepareEmbeddedControls(_ view:NSView) {
        for child in view.subviews {
            if let scroll=child as? NSScrollView {
                scroll.autoresizingMask=[.width]
                if let rows=scroll.documentView {rows.autoresizingMask=[.width];prepareEmbeddedControls(rows)}
            } else if let segment=child as? NSSegmentedControl {
                segment.autoresizingMask=[.width];segment.segmentDistribution = .fillEqually
            } else if child is NSBox || (child is NSTextField && child.frame.minX < 110 && child.frame.width > 300) {
                child.autoresizingMask=[.width]
            } else if child.frame.minX > 200 {
                child.autoresizingMask=[.minXMargin]
            }
        }
    }
    private func popup(_ titles: [String], selected: Int, x: CGFloat, y: CGFloat, width: CGFloat, in view: NSView) -> NSPopUpButton {
        let popup = WBPopUpButton(frame: NSRect(x: x, y: y - 3, width: width, height: 32), pullsDown: false); popup.font = .systemFont(ofSize: 12)
        popup.addItems(withTitles: titles); popup.selectItem(at: selected); view.addSubview(popup); return popup
    }
    private func nativeButton(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, in view: NSView) -> NSButton {
        let button = ClickableButton(title: title, target: nil, action: nil); button.frame = NSRect(x: x, y: y, width: width, height: 28)
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 12); view.addSubview(button); return button
    }
    private func toggle(_ title: String, y: CGFloat, value: Bool, in view: NSView, change: @escaping (Bool) -> Bool) {
        rowLabel(title, y: y, in: view)
        let control = NSSwitch(frame: NSRect(x: 432, y: y + 13, width: 42, height: 26)); control.state = value ? .on : .off; control.setAccessibilityLabel(title); view.addSubview(control)
        connect(control) { [weak control] in
            guard let control else { return }
            if !change(control.state == .on) { control.state = control.state == .on ? .off : .on }
        }
    }
    private func featureToggle(_ title: String, detail: String, symbol: String, y: CGFloat, value: Bool, in view: NSView, change: @escaping (Bool) -> Bool) {
        let tile = FlippedView(frame: NSRect(x: 12, y: y + 16, width: 32, height: 32)); tile.wantsLayer = true
        tile.layer?.backgroundColor = (embedding ? NSColor.labelColor.withAlphaComponent(0.09):NSColor.systemIndigo).cgColor; tile.layer?.cornerRadius = 8
        let icon = NSImageView(frame: NSRect(x: 7, y: 7, width: 18, height: 18)); icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); icon.contentTintColor = .white
        if embedding {icon.contentTintColor = .secondaryLabelColor}
        tile.addSubview(icon); view.addSubview(tile)
        text(title, x: 56, y: y + 13, width: 350, size: 13, weight: .semibold, in: view)
        text(detail, x: 56, y: y + 35, width: 350, size: 11, color: .secondaryLabelColor, in: view)
        let control = NSSwitch(frame: NSRect(x: 432, y: y + 20, width: 42, height: 26)); control.state = value ? .on : .off; control.setAccessibilityLabel("启用" + title); view.addSubview(control)
        connect(control) { [weak control] in
            guard let control else { return }
            if !change(control.state == .on) { control.state = control.state == .on ? .off : .on }
        }
    }

}

@MainActor
private final class SettingsControlAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: Any?) { action() }
}

private final class LauncherSettingsEmbeddedRoot:FlippedView {
    var contentHeight:CGFloat=0 {didSet {if oldValue != contentHeight {invalidateIntrinsicContentSize()}}}
    var widthChanged:((CGFloat)->Void)?
    override var intrinsicContentSize:NSSize {NSSize(width:NSView.noIntrinsicMetric,height:contentHeight)}
    override func layout() {super.layout();if bounds.width > 0 {widthChanged?(bounds.width)}}
}

private final class SettingsRowGroup: FlippedView {
    var embedded=false {didSet {needsDisplay=true}}
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if embedded {
            let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:15,yRadius:15)
            NSGradient(colors:[NSColor.labelColor.withAlphaComponent(dark ? 0.055:0.035),NSColor.labelColor.withAlphaComponent(0.018)])?.draw(in:path,angle:35)
            NSColor.labelColor.withAlphaComponent(0.10).setStroke();path.lineWidth=0.7;path.stroke();return
        }
        (dark ? NSColor(calibratedWhite: 0.155, alpha: 1) : NSColor(calibratedWhite: 0.97, alpha: 1)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
