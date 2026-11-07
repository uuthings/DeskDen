import AppKit
import SwiftUI
import LauncherCore

@MainActor
final class DesktopWidgetsController: NSObject, NSWindowDelegate {
    private let device: DeviceStatusModel
    private let calendar: CalendarModel
    private let ai: AIUsageModel
    private let open: (WorkbenchRoute) -> Void
    private let onChange: (DesktopCardPreference) -> Void
    private var panels: [DesktopCardKind: DesktopWidgetPanel] = [:]
    private var preferences: [DesktopCardKind: DesktopCardPreference] = [:]
    private var moveTasks: [DesktopCardKind: Task<Void, Never>] = [:]
    private var applying = false
    private var opacity = 0.70
    private var light = false
    private var theme: LauncherTheme = .arWorld
    private var screenObserver: DesktopScreenObservation?

    init(device: DeviceStatusModel, calendar: CalendarModel, ai: AIUsageModel,
         open: @escaping (WorkbenchRoute) -> Void, onChange: @escaping (DesktopCardPreference) -> Void) {
        self.device = device; self.calendar = calendar; self.ai = ai; self.open = open; self.onChange = onChange
        super.init()
        screenObserver = DesktopScreenObservation { [weak self] _ in
            Task { @MainActor [weak self] in self?.constrainWindowsToScreens() }
        }
    }

    func apply(_ cards: [DesktopCardPreference], opacity: Double, light: Bool, theme: LauncherTheme = .arWorld) {
        guard !applying else { return }
        applying = true
        self.opacity = opacity; self.light = light; self.theme = theme
        preferences = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        var adjusted: [DesktopCardPreference] = []
        for kind in DesktopCardKind.allCases {
            guard let card = preferences[kind], card.visible else {
                moveTasks[kind]?.cancel(); moveTasks[kind] = nil
                panels[kind]?.orderOut(nil); panels[kind]?.close(); panels[kind] = nil
                continue
            }
            let size = DesktopWidgetSize.size(for: card)
            let panel: DesktopWidgetPanel
            if let existing = panels[kind] { panel = existing }
            else {
                panel = DesktopWidgetPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.kind = kind; panel.title = "方寸 · " + kind.title
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
                panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                panel.delegate = self; panels[kind] = panel
            }
            panel.level = card.floating ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.ignoresMouseEvents = card.clickThrough
            panel.isMovable = !card.locked && !card.clickThrough
            panel.isMovableByWindowBackground = false
            panel.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            let root = DesktopWidgetView(card: card, device: device, calendar: calendar, ai: ai, opacity: opacity, light: light, theme: theme,
                                         open: open, update: { [weak self] changed in self?.onChange(changed) },
                                         moved: { [weak self] in self?.commitPosition(kind) })
            if let host = panel.contentView as? NSHostingView<DesktopWidgetView> { host.rootView = root }
            else { panel.contentView = NSHostingView(rootView: root) }
            let desired: CGRect
            if let x = card.x, let y = card.y { desired = CGRect(x: x, y: y, width: size.width, height: size.height) }
            else { desired = defaultFrame(for: kind, size: size) }
            let frame = DesktopCardPlacement.clamped(desired, visibleScreens: NSScreen.screens.map(\.visibleFrame))
            panel.setFrame(frame, display: true)
            if !panel.isVisible { panel.orderFrontRegardless() }
            if card.x != frame.minX || card.y != frame.minY {
                var saved = card; saved.x = frame.minX; saved.y = frame.minY
                preferences[kind] = saved; adjusted.append(saved)
            }
        }
        applying = false
        device.setWidgetsVisible(cards.contains { $0.id == .device && $0.visible })
        // Persist initial placement and display-detachment corrections through the owner's store.
        for card in adjusted { onChange(card) }
    }

    func hideAll() {
        for task in moveTasks.values { task.cancel() }; moveTasks.removeAll()
        for panel in panels.values { panel.orderOut(nil) }
        device.setWidgetsVisible(false)
    }

    func windowDidMove(_ notification: Notification) {
        guard !applying, let panel = notification.object as? DesktopWidgetPanel, let kind = panel.kind else { return }
        moveTasks[kind]?.cancel()
        moveTasks[kind] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.commitPosition(kind)
        }
    }

    private func commitPosition(_ kind: DesktopCardKind) {
        guard !applying, let panel = panels[kind], var card = preferences[kind] else { return }
        moveTasks[kind]?.cancel(); moveTasks[kind] = nil
        applying = true
        let frame = DesktopCardPlacement.clamped(panel.frame, visibleScreens: NSScreen.screens.map(\.visibleFrame))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        applying = false
        guard card.x != frame.minX || card.y != frame.minY else { return }
        card.x = frame.minX; card.y = frame.minY; preferences[kind] = card
        onChange(card)
    }

    private func constrainWindowsToScreens() { for kind in Array(panels.keys) { commitPosition(kind) } }

    private func defaultFrame(for kind: DesktopCardKind, size: CGSize) -> CGRect {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let x = kind == .device ? screen.maxX - size.width - 24 : screen.minX + 24
        let y = screen.maxY - size.height - (kind == .today ? 330 : kind == .device ? 74 : 24)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

private final class DesktopScreenObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ block: @escaping @Sendable (Notification) -> Void) {
        token = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: block)
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}

private final class DesktopWidgetPanel: NSPanel {
    var kind: DesktopCardKind?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum DesktopWidgetSize {
    static func size(for card: DesktopCardPreference) -> CGSize {
        let height: CGFloat
        switch card.id {
        case .ai: height = card.source == "both" ? (card.small ? 230 : 286) : (card.small ? 150 : 178)
        case .today: height = card.small ? 166 : 246
        case .device: height = card.small ? 170 : 240
        }
        return CGSize(width: card.small ? 220 : 260, height: height)
    }
}

private struct DesktopWidgetView: View {
    let card: DesktopCardPreference
    @ObservedObject var device: DeviceStatusModel
    @ObservedObject var calendar: CalendarModel
    @ObservedObject var ai: AIUsageModel
    let opacity: Double, light: Bool
    let theme: LauncherTheme
    var open: (WorkbenchRoute) -> Void
    var update: (DesktopCardPreference) -> Void
    var moved: () -> Void
    @State private var showingMenu = false
    private var palette: ThemePalette { ThemePalette(theme: theme, opacity: opacity, light: light) }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: card.id.symbol).font(.system(size: 13))
                    Text(card.id.title).font(.system(size: 12, weight: .medium))
                    if card.floating { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(palette.muted) }
                    if card.locked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(palette.muted) }
                    Spacer(minLength: 0)
                }.overlay(DesktopWidgetDragHandle(enabled: !card.locked && !card.clickThrough, ended: moved))
                Button { showingMenu.toggle() } label: { Image(systemName: "ellipsis").frame(width: 18, height: 18) }
                .buttonStyle(ClickablePlainButtonStyle())
                .help("\(card.id.title)设置").accessibilityLabel("\(card.id.title)设置")
                .workbenchPopover(isPresented: $showingMenu, width: 180, alignment: .trailing) {
                    VStack(alignment: .leading, spacing: 2) {
                        menuAction("组件设置") { open(.cards) }
                        Divider().padding(.vertical, 3)
                        menuAction(card.floating ? "融入桌面" : "悬浮置顶") { change { $0.floating.toggle() } }
                        menuAction(card.locked ? "解锁位置" : "锁定位置") { change { $0.locked.toggle() } }
                        menuAction("开启鼠标穿透") { change { $0.clickThrough = true } }
                        Divider().padding(.vertical, 3)
                        menuAction("隐藏组件") { change { $0.visible = false } }
                    }.padding(6)
                }
            }
            Button { open(card.id == .ai ? .ai : card.id == .today ? .calendar : .device) } label: {
                DesktopCardContent(card: card, device: device, calendar: calendar, ai: ai)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).contentShape(Rectangle())
            }.buttonStyle(ClickablePlainButtonStyle())
        }
        .padding(14)
        .frame(width: DesktopWidgetSize.size(for: card).width, height: DesktopWidgetSize.size(for: card).height)
        .foregroundStyle(palette.text)
        .background(WorkbenchGlass(opacity: opacity, light: light, panel: true))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(palette.border, lineWidth: 1))
        .workbenchThemeEnvironment(theme: theme, opacity: opacity, backgroundMotion: false, appearance: light ? .light : .dark)
        .environment(\.colorScheme, light ? .light : .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("方寸\(card.id.title)桌面组件")
    }
    private func menuAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button { showingMenu = false; action() } label: {
            Text(title).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 28)
        }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 6, drawsSelection: false, showsBorder: false))
    }
    private func change(_ edit: (inout DesktopCardPreference) -> Void) { var copy = card; edit(&copy); update(copy) }
}

private struct DesktopWidgetDragHandle: NSViewRepresentable {
    var enabled: Bool
    var ended: () -> Void
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) { view.enabled = enabled; view.ended = ended }
    final class Handle: NSView {
        var enabled = true
        var ended: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            guard enabled else { return }
            window?.performDrag(with: event); ended?()
        }
        override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .openHand) } }
    }
}

/// The manager preview and live NSPanel intentionally share this exact content view.
private struct DesktopCardContent: View {
    let card: DesktopCardPreference
    @ObservedObject var device: DeviceStatusModel
    @ObservedObject var calendar: CalendarModel
    @ObservedObject var ai: AIUsageModel
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        Group {
            switch card.id {
            case .device: deviceContent
            case .ai: aiContent
            case .today: todayContent
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var deviceContent: some View {
        let s = device.snapshot
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text("内存").foregroundStyle(palette.secondary)
                Spacer()
                memoryValue(s.memory?.used)
            }.font(.system(size: 12))
            WBProgress(value: (s.memory?.percent ?? 0) / 100, color: pressureColor(s.memory?.pressure ?? .unknown))
            line("CPU", DeviceFormat.percent(s.cpuPercent), color: metricColor(s.cpuPercent))
            if !card.small {
                line("今日已记录", DeviceFormat.bytes(s.network.todayDownload + s.network.todayUpload))
                if let battery = s.battery {
                    Text("电量 \(Int(battery.percent))% · \(battery.isPluggedIn ? "电源适配器" : "电池供电")")
                        .font(.system(size: 10)).foregroundStyle(DeviceAppearance.battery(battery.percent, pluggedIn: battery.isPluggedIn, palette: palette))
                } else { Text("\(DeviceFormat.thermal(s.thermalState)) · 无内置电池").font(.system(size: 10)).foregroundStyle(palette.muted) }
            }
        }
    }
    private var aiContent: some View {
        VStack(alignment: .leading, spacing: card.small ? 15 : 18) {
            ForEach(AIProvider.allCases.filter { card.source == "both" || card.source == $0.rawValue }) { provider in
                providerContent(provider)
            }
        }
    }
    private func providerContent(_ provider: AIProvider) -> some View {
        let summary = ai.providerSummaries.first { $0.provider == provider }
        let state = summary?.state ?? .unavailable
        let windows = state == .disconnected ? [] : [summary?.shortWindow, summary?.weeklyWindow].compactMap { $0 }
        let primary = windows.first { $0.durationMinutes != 10_080 }
        let weekly = windows.first { $0.durationMinutes == 10_080 }
        let current = state == .ready
        // One status per source, with the real reason (现行规范 9.4 W1, U2).
        let enabled = ai.configuration(for: provider).enabled
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AIProviderLogo(provider: provider, size: 17)
                Text(provider.title).font(.system(size: 11))
                Spacer()
                Text(!enabled ? "已关闭" : current ? "已用" : state.title)
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            if !windows.isEmpty {
                quotaRow(primary?.title.replacingOccurrences(of: "窗口", with: "") ?? "短期", window: primary, current: current)
                quotaRow("每周", window: weekly, current: current)
            } else {
                Text(!enabled ? "自动读取已关闭" : state == .disconnected ? "接入后显示额度" : "尚无有效额度读数")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            if !card.small, summary?.updatedAt != nil {
                Text(caption(summary)).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
            }
        }
    }
    private func quotaRow(_ title: String, window: AIQuotaWindow?, current: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary).frame(width: 40, alignment: .leading)
            if let window {
                WBProgress(value: window.usedPercent / 100, color: current ? palette.usageColor(forPercent: window.usedPercent) : palette.muted, height: 4)
            } else {
                Capsule().fill(palette.progressTrack).frame(height: 4)
            }
            Text(UsagePercentage.text(window?.usedPercent))
                .font(.system(size: 11)).monospacedDigit().frame(width: 32, alignment: .trailing)
                .foregroundStyle(current ? palette.usageColor(forPercent: window?.usedPercent) : palette.muted)
        }.frame(height: 14)
    }
    private func caption(_ summary: AIProviderSummary?) -> String {
        guard let summary else { return ai.isRefreshing ? "正在读取" : "未更新" }
        let time = summary.updatedAt?.formatted(date: .omitted, time: .shortened)
        if summary.snapshot?.source == .manual { return "手动记录 · \(time ?? "—") · \(summary.state.title)" }
        return [time, summary.state.title].compactMap { $0 }.joined(separator: " · ")
    }
    private var todayContent: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 12) {
                Text(WorkbenchDateText.monthDayWeekday(context.date, calendar: calendar.displayCalendar))
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                let items = Array(calendar.todayItems.filter { !$0.isCompleted }.prefix(card.small ? 1 : 3))
                if items.isEmpty {
                    Text(calendar.isLoading ? "正在读取安排" : "今天暂无未完成安排")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                    if !card.small { Text("在日历与提醒中添加安排，或接入系统日历。")
                        .font(.system(size: 10)).foregroundStyle(palette.muted).lineSpacing(3) }
                } else {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Text(time(item)).font(.system(size: 10)).monospacedDigit().foregroundStyle(palette.muted).frame(width: 36, alignment: .leading)
                            Text(item.title).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
    private func time(_ item: CalendarAgendaEntry) -> String {
        switch item {
        case .event(let event): return event.isAllDay ? "全天" : event.start.formatted(.dateTime.hour().minute())
        case .reminder(let reminder): return reminder.due?.hasTime == true ? reminder.due?.date?.formatted(.dateTime.hour().minute()) ?? "全天" : "全天"
        }
    }
    private func line(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack { Text(label).foregroundStyle(palette.secondary); Spacer(); Text(value).foregroundStyle(color ?? palette.text).monospacedDigit() }.font(.system(size: 12))
    }
    private func memoryValue(_ bytes: UInt64?) -> some View {
        let parts = DeviceFormat.bytes(bytes).split(maxSplits:1,whereSeparator:{$0.isWhitespace}).map(String.init)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(parts.first ?? "—").font(.system(size: 24)).monospacedDigit()
            if parts.count > 1 { Text(parts[1]).font(.system(size: 11)).foregroundStyle(palette.muted) }
        }
    }
    private func metricColor(_ value: Double?) -> Color { palette.usageColor(forPercent: value) }
    private func pressureColor(_ pressure: DevicePressure) -> Color { pressure == .critical ? palette.critical : pressure == .warning ? palette.warning : pressure == .normal ? palette.accent : palette.muted }
}

struct DesktopCardsView: View {
    let cards: [DesktopCardPreference]
    var update: (DesktopCardPreference) -> Void
    var openDesktop: () -> Void
    @ObservedObject var device: DeviceStatusModel
    @ObservedObject var calendar: CalendarModel
    @ObservedObject var ai: AIUsageModel
    var showsHeader = true
    @Environment(\.workbenchPalette) private var palette

    private var ordered: [DesktopCardPreference] {
        [.device, .today, .ai].compactMap { kind in cards.first { $0.id == kind } }
    }
    /// Each widget is set once, in its card; no second dialog (现行规范 9.4, S7).
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                WBPageHeader(title: "桌面组件", subtitle: "把常用信息留在桌面，也可设为悬浮显示") {
                    Button(action: openDesktop) { Label("查看桌面", systemImage: "macwindow.on.rectangle") }.buttonStyle(WBButtonStyle())
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(ordered) { card in managementCard(card).frame(maxHeight: .infinity, alignment: .top) }
                }.fixedSize(horizontal: false, vertical: true).frame(minWidth: 790)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(ordered) { card in managementCard(card) }
                }.frame(minWidth: 532)
                VStack(spacing: 12) { ForEach(ordered) { card in managementCard(card) } }
            }
            WBPageNote {
                Text("开启鼠标穿透后，可从这里关闭穿透并恢复操作。桌面组件与工作台使用同一套材质设置。")
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 12)
        }
    }
    private func managementCard(_ card: DesktopCardPreference) -> some View {
        WBCard(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: card.id.symbol).font(.system(size: 16)).foregroundStyle(palette.accent)
                Text(card.id.title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                Toggle("显示" + card.id.title, isOn: preference(card, \.visible))
                    .labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.mini).tint(palette.accent)
            }.frame(height: 22).padding(.bottom, 12)
            // The widget preview itself, without a frame around it (D7).
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(card.id.title).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: card.id.symbol).font(.system(size: 16)).foregroundStyle(palette.secondary)
                }
                DesktopCardContent(card: card, device: device, calendar: calendar, ai: ai)
            }
                .frame(width: 174, alignment: .leading).padding(13)
                .background(WorkbenchMaterialSurface(kind: .card, radius: 11))
                .frame(maxWidth: .infinity, minHeight: 196, alignment: .center)
                .padding(.bottom, 8)
            WBSettingRow(title: "显示方式", subtitle: "桌面层或悬浮置顶") {
                WBSelect("显示方式", selection: preference(card, \.floating), options: [(value: false, title: "桌面"), (value: true, title: "悬浮置顶")]).frame(width: 112)
            }
            WBSettingRow(title: "大小", subtitle: "标准或小号") {
                WBSelect("组件大小", selection: preference(card, \.small), options: [(value: false, title: "标准"), (value: true, title: "小号")]).frame(width: 112)
            }
            if card.id == .ai {
                WBSettingRow(title: "额度来源", subtitle: "显示哪些 AI 来源") {
                    WBSelect("额度来源", selection: preference(card, \.source), options: [(value: "both", title: "全部"), (value: "codex", title: "Codex"), (value: "claude", title: "Claude")]).frame(width: 112)
                }
            }
            WBSettingRow(title: "锁定位置", subtitle: "不能拖动组件") {
                Toggle("锁定" + card.id.title + "位置", isOn: preference(card, \.locked)).labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.mini).tint(palette.accent)
            }
            WBSettingRow(title: "鼠标穿透", subtitle: "点击会穿过组件") {
                Toggle(card.id.title + "鼠标穿透", isOn: preference(card, \.clickThrough)).labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.mini).tint(palette.accent)
            }
            WBSettingRow(title: "位置", subtitle: card.x == nil && card.y == nil ? "默认位置" : "已拖动到自定位置") {
                Button("重置位置") { var changed = card; changed.x = nil; changed.y = nil; update(changed) }
                    .buttonStyle(WBButtonStyle(compact: true)).disabled(card.x == nil && card.y == nil)
                    .accessibilityIdentifier("fc.settings.widgets.reset." + card.id.rawValue)
            }
        }
    }
    private func preference<Value>(_ card: DesktopCardPreference, _ keyPath: WritableKeyPath<DesktopCardPreference, Value>) -> Binding<Value> {
        Binding(get: { card[keyPath: keyPath] }, set: { value in
            var changed = card; changed[keyPath: keyPath] = value; update(changed)
        })
    }
}
