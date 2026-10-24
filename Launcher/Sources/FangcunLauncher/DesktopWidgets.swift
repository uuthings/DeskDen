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
                Menu {
                    Button("组件设置…") { open(.cards) }
                    Divider()
                    Button(card.floating ? "融入桌面" : "悬浮置顶") { change { $0.floating.toggle() } }
                    Button(card.locked ? "解锁位置" : "锁定位置") { change { $0.locked.toggle() } }
                    Button("开启鼠标穿透") { change { $0.clickThrough = true } }
                    Divider()
                    Button("隐藏组件") { change { $0.visible = false } }
                } label: { Image(systemName: "ellipsis").frame(width: 18, height: 18) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("\(card.id.title)设置").accessibilityLabel("\(card.id.title)设置")
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
                        .font(.system(size: 10)).foregroundStyle(!battery.isPluggedIn && battery.percent <= 10 ? palette.critical : !battery.isPluggedIn && battery.percent <= 20 ? palette.warning : palette.muted)
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AIProviderLogo(provider: provider, size: 17)
                Text(provider.title).font(.system(size: 11))
                Spacer()
                Text(current ? "已用" : state.title)
                    .font(.system(size: 10)).foregroundStyle(palette.muted)
            }
            if !windows.isEmpty {
                quotaRow(primary?.title.replacingOccurrences(of: "窗口", with: "") ?? "短期", window: primary, current: current)
                quotaRow("每周", window: weekly, current: current)
            } else {
                Text(state == .disconnected ? "接入后显示额度" : "尚无有效额度读数")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            if !card.small {
                Text(caption(summary)).font(.system(size: 10)).foregroundStyle(palette.muted).lineLimit(1)
            }
        }
    }
    private func quotaRow(_ title: String, window: AIQuotaWindow?, current: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(palette.secondary).frame(width: 40, alignment: .leading)
            if let window {
                WBProgress(value: window.usedPercent / 100, color: current ? metricColor(window.usedPercent) : palette.muted, height: 4)
            } else {
                Capsule().fill(palette.progressTrack).frame(height: 4)
            }
            Text(window.map { String(format: "%.0f%%", $0.usedPercent) } ?? "—")
                .font(.system(size: 10)).monospacedDigit().frame(width: 30, alignment: .trailing)
                .foregroundStyle(current ? metricColor(window?.usedPercent) : palette.muted)
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
                Text(context.date.formatted(.dateTime.month().day().weekday(.wide)))
                    .font(.system(size: 10)).foregroundStyle(palette.muted)
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
    private func metricColor(_ value: Double?) -> Color { guard let value else { return palette.muted }; return value >= 90 ? palette.critical : value >= 75 ? palette.warning : palette.text }
    private func pressureColor(_ pressure: DevicePressure) -> Color { pressure == .critical ? palette.critical : pressure == .warning ? palette.warning : pressure == .normal ? palette.accent : palette.muted }
}

struct DesktopCardsView: View {
    let cards: [DesktopCardPreference]
    var update: (DesktopCardPreference) -> Void
    var openDesktop: () -> Void
    @ObservedObject var device: DeviceStatusModel
    @ObservedObject var calendar: CalendarModel
    @ObservedObject var ai: AIUsageModel
    @State private var editing: DesktopCardPreference?
    @StateObject private var dialogControl=DesktopCardDialogControl()
    @Environment(\.workbenchPalette) private var palette

    private var ordered: [DesktopCardPreference] {
        [.device, .today, .ai].compactMap { kind in cards.first { $0.id == kind } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: "桌面组件", subtitle: "把常用信息留在桌面，也可设为悬浮显示") {
                Button(action: openDesktop) { Label("查看桌面", systemImage: "rectangle.on.rectangle") }.buttonStyle(WBButtonStyle())
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(ordered) { card in managementCard(card, height: 545.938) }
                }.frame(minWidth: 790)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    ForEach(ordered) { card in
                        // The AI card has one additional 40 pt source row and
                        // its 10 pt grid gap in the frozen compact layout.
                        managementCard(card, minimumHeight: card.id == .ai ? 545.938 : 495.938)
                    }
                }.frame(minWidth: 532)
                VStack(spacing: 12) { ForEach(ordered) { card in managementCard(card) } }
            }
            Text("开启鼠标穿透后，可从这里关闭穿透并恢复操作。桌面组件与工作台使用同一套材质设置。")
                .font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(palette.soft, in: RoundedRectangle(cornerRadius: 8)).padding(.top, 12)
        }
        .workbenchModal(item: $editing,onRequestDismiss:{dialogControl.closeRequests += 1}) { card in
            DesktopCardSettings(initial: card, device: device, calendar: calendar, ai: ai,control:dialogControl,
                                save: { updated in update(updated); editing = nil }, cancel: { editing = nil })
        }
    }
    private func managementCard(_ card: DesktopCardPreference, height: CGFloat? = nil, minimumHeight: CGFloat? = nil) -> some View {
        WBCard(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: card.id.symbol).font(.system(size: 16)).foregroundStyle(palette.accent)
                Text(card.id.title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Button { editing = card } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(WBIconButtonStyle(size: 22)).help("更多组件设置")
                    .accessibilityLabel(card.id.title + "更多设置")
                Toggle("显示" + card.id.title, isOn: preference(card, \.visible))
                    .labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.small).tint(palette.accent)
            }.frame(height: 22)
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
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220, alignment: .center)
                .background(palette.sidebar, in: RoundedRectangle(cornerRadius: 10))
            VStack(spacing: 10) {
                widgetField("显示方式") {
                    WBSelect("显示方式", selection: preference(card, \.floating), options: [(value: false, title: "桌面"), (value: true, title: "悬浮置顶")])
                }
                widgetField("大小") {
                    WBSelect("组件大小", selection: preference(card, \.small), options: [(value: false, title: "标准"), (value: true, title: "小号")])
                }
                widgetField("锁定位置", controlHeight: 20) {
                    Toggle("锁定" + card.id.title + "位置", isOn: preference(card, \.locked)).labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.small).tint(palette.accent)
                }
                widgetField("鼠标穿透", controlHeight: 20) {
                    Toggle(card.id.title + "鼠标穿透", isOn: preference(card, \.clickThrough)).labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.small).tint(palette.accent)
                }
                if card.id == .ai {
                    widgetField("额度来源") {
                        WBSelect("额度来源", selection: preference(card, \.source), options: [(value: "both", title: "全部"), (value: "codex", title: "Codex"), (value: "claude", title: "Claude")])
                    }
                }
            }
            Text(card.id == .device ? "数据与设备状态同步" : card.id == .today ? "数据与日历提醒同步" : "显示来源与过期状态")
                .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: height == nil && minimumHeight == nil ? nil : .infinity, alignment: .bottomLeading)
        }
        .frame(height: height)
        .frame(minHeight: minimumHeight)
    }
    private func widgetField<Control: View>(_ title: String, controlHeight: CGFloat = 32, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary)
            Spacer(minLength: 4)
            control().frame(width: 112, height: controlHeight, alignment: .trailing)
        }.frame(height: controlHeight).padding(.vertical, 4)
    }
    private func preference<Value>(_ card: DesktopCardPreference, _ keyPath: WritableKeyPath<DesktopCardPreference, Value>) -> Binding<Value> {
        Binding(get: { card[keyPath: keyPath] }, set: { value in
            var changed = card; changed[keyPath: keyPath] = value; update(changed)
        })
    }
}

@MainActor private final class DesktopCardDialogControl:ObservableObject {@Published var closeRequests=0}

private struct DesktopCardSettings: View {
    let initial: DesktopCardPreference
    @ObservedObject var control:DesktopCardDialogControl
    @ObservedObject var device: DeviceStatusModel
    @ObservedObject var calendar: CalendarModel
    @ObservedObject var ai: AIUsageModel
    var save: (DesktopCardPreference) -> Void
    var cancel: () -> Void
    @State private var draft: DesktopCardPreference
    @State private var confirmDiscard = false
    @Environment(\.workbenchPalette) private var palette
    init(initial: DesktopCardPreference, device: DeviceStatusModel, calendar: CalendarModel, ai: AIUsageModel,control:DesktopCardDialogControl,
         save: @escaping (DesktopCardPreference) -> Void, cancel: @escaping () -> Void) {
        self.initial = initial; self.device = device; self.calendar = calendar; self.ai = ai; self.control=control; self.save = save; self.cancel = cancel
        _draft = State(initialValue: initial)
    }
    var body:some View {
        WorkbenchDialogFrame(title:"\(initial.id.title) · 卡片设置",dismiss:requestCancel) {
            VStack(alignment:.leading,spacing:0) {
                field("显示方式",selection:$draft.floating,options:[(false,"融入桌面 · 可被窗口遮挡"),(true,"悬浮置顶 · 保持在前")])
                field("卡片尺寸",selection:$draft.small,options:[(false,"标准"),(true,"小")])
                if draft.id == .ai {field("显示来源",selection:$draft.source,options:[("both","Codex + Claude"),("codex","仅 Codex"),("claude","仅 Claude")])}
                VStack(alignment:.leading,spacing:14){Toggle("显示组件",isOn:$draft.visible).clickableCursor();Toggle("锁定位置",isOn:$draft.locked).clickableCursor();Toggle("鼠标穿透",isOn:$draft.clickThrough).clickableCursor()}.toggleStyle(.checkbox)
                Text("开启穿透后，卡片不接收鼠标操作。请在工作台的“桌面组件”中关闭穿透以恢复交互。").font(.system(size:11)).foregroundStyle(palette.muted).lineSpacing(3).fixedSize(horizontal:false,vertical:true).padding(.top,12)
            }.font(.system(size:12))
        }actions:{
            Button("重置位置"){draft.x=nil;draft.y=nil}.buttonStyle(WBQuietButtonStyle());Spacer();Button("取消",action:requestCancel).buttonStyle(WBButtonStyle());Button("保存设置"){save(draft)}.buttonStyle(WBButtonStyle(primary:true)).keyboardShortcut(.defaultAction)
        }
        .onChange(of:control.closeRequests){_,_ in requestCancel()}
        .workbenchModal(isPresented:$confirmDiscard){WorkbenchDialogFrame(title:"放弃这次修改？",dismiss:{confirmDiscard=false}){Text("未保存的组件设置将被放弃。").foregroundStyle(palette.secondary)}actions:{Spacer();Button("继续编辑"){confirmDiscard=false}.buttonStyle(WBButtonStyle());Button("放弃修改"){confirmDiscard=false;cancel()}.buttonStyle(WBButtonStyle(destructive:true))}}
    }
    private func field<Value:Hashable>(_ title:String,selection:Binding<Value>,options:[(Value,String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).foregroundStyle(palette.secondary)
            WBSelect(title, selection: selection, options: options.map { (value: $0.0, title: $0.1) })
                .contentShape(RoundedRectangle(cornerRadius:8)).accessibilityLabel(title)
                .accessibilityValue(options.first(where:{$0.0 == selection.wrappedValue})?.1 ?? "")
        }.padding(.bottom, 15)
    }
    private func requestCancel() { if draft == initial { cancel() } else { confirmDiscard = true } }
}
