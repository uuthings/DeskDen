import SwiftUI
import UniformTypeIdentifiers
import LauncherCore

/// Readings come from shared services. Mounting a Mini never starts a provider
/// scan or owns a second hardware history loop.
struct WorkbenchMiniView: View {
    @ObservedObject var model: WorkbenchAppModel
    @ObservedObject var controller: WorkbenchTopEntryController
    @ObservedObject var context: WorkbenchContextModel
    @StateObject private var agendaProjection: WorkbenchMiniAgendaProjection
    @ObservedObject var device: DeviceStatusModel
    @ObservedObject var ai: AIUsageModel
    @ObservedObject var providerUsage: ProviderUsageModel
    let openedAt: Date
    let safeTop: CGFloat
    let notchWidth: CGFloat
    let open: (WorkbenchMiniCardID) -> Void
    let openContext: () -> Void
    let finishConfiguration: () -> Void

    init(model: WorkbenchAppModel, controller: WorkbenchTopEntryController, openedAt: Date,
         safeTop: CGFloat, notchWidth: CGFloat, open: @escaping (WorkbenchMiniCardID) -> Void,
         openContext: @escaping () -> Void,
         finishConfiguration: @escaping () -> Void) {
        self.model = model; self.controller = controller
        context = model.context; device = model.device; ai = model.ai; providerUsage = model.providerUsage
        _agendaProjection = StateObject(wrappedValue: WorkbenchMiniAgendaProjection(calendar: model.calendar, context: model.context))
        self.openedAt = openedAt; self.safeTop = safeTop; self.notchWidth = notchWidth
        self.open = open; self.openContext = openContext; self.finishConfiguration = finishConfiguration
    }

    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0),
                               by: controller.preferences.showDate && controller.preferences.showSeconds ? 1 : 60)) { timeline in
            WorkbenchMiniPanelView(
                context: .init(context: context, now: timeline.date, showSeconds: controller.preferences.showSeconds), agenda: agendaProjection.data,
                device: .init(snapshot: device.snapshot, openedAt: openedAt, history: device.history,
                              summary: device.trafficSummary, budget: device.budget, unit: context.settings.temperatureUnit),
                providers: AIProvider.allCases.map { provider in
                    .init(summary: ai.providerSummaries.first { $0.provider == provider }, provider: provider,
                          now: timeline.date, displayCalendar: context.dateContext.calendar)
                },
                externalProviders: providerUsage.sources.map {
                    WorkbenchMiniExternalProviderData(configuration: $0, state: providerUsage.state(for: $0.id),
                                                      now: timeline.date, calendar: context.dateContext.calendar)
                }, preferences: controller.preferences, safeTop: safeTop, notchWidth: notchWidth,
                error: controller.error, open: open, openContext: openContext, setVisible: controller.setMiniCard,
                setHeaderVisible: controller.setMiniHeader, setSeconds: controller.setMiniSeconds, reorder: controller.moveMiniCard,
                restore: controller.restoreMiniSections, finishConfiguration: finishConfiguration
            )
            .onChange(of: timeline.date) { _, date in agendaProjection.update(now: date) }
        }
        .onChange(of: providerUsage.sources.map(\.id)) { _, _ in finishConfiguration() }
        .workbenchThemeEnvironment(theme: model.theme, opacity: model.opacity, backgroundMotion: false, appearance: model.appearance)
    }
}

/// Production and isolated render fixtures use this same modular panel.
/// WorkbenchNotchSurface supplies the outer glass; cards only add a soft tint.
struct WorkbenchMiniPanelView: View {
    var context: WorkbenchMiniContextData
    var agenda: WorkbenchMiniAgendaData
    var device: WorkbenchMiniDeviceData
    var providers: [WorkbenchMiniAIData]
    var externalProviders: [WorkbenchMiniExternalProviderData] = []
    var preferences: WorkbenchTopEntryPreferences
    var safeTop: CGFloat
    var notchWidth: CGFloat
    var error: String?
    var open: (WorkbenchMiniCardID) -> Void
    var openContext: () -> Void
    var setVisible: (WorkbenchMiniCardID, Bool) -> Void
    var setHeaderVisible: (Bool, Bool) -> Void
    var setSeconds: (Bool) -> Void
    var reorder: (WorkbenchMiniCardID, WorkbenchMiniCardID, Bool) -> Void
    var restore: () -> Void
    var finishConfiguration: () -> Void
    @State var configuring = false
    @State private var editing = false
    @State private var page = 0
    @State private var dragged: WorkbenchMiniCardID?
    @FocusState private var focusedCard: WorkbenchMiniCardID?
    @Environment(\.workbenchPalette) private var palette

    private var available: [WorkbenchMiniCardID] { WorkbenchMiniCardID.builtIn + externalProviders.map { .provider($0.id) } }
    private var active: [WorkbenchMiniCardID] { preferences.activeCards(available: available) }
    private var placements: [WorkbenchMiniPlacement] { WorkbenchMiniPacking.pack(active) }
    private var columns: Int { (placements.map(\.column).max() ?? -1) + 1 }

    var body: some View {
        GeometryReader { geometry in
            let bodyWidth = max(220, geometry.size.width - WorkbenchMiniLayout.horizontalInset * 2)
            let capacity = max(1, Int((bodyWidth + 10) / 230))
            let pages = max(1, (columns + capacity - 1) / capacity)
            let currentPage = min(page, pages - 1)
            let shown = placements.filter { $0.column / capacity == currentPage }
            let shownColumns = max(1, min(capacity, columns - currentPage * capacity))
            let boardWidth = CGFloat(shownColumns) * 230 - 10
            ZStack(alignment: .topLeading) {
                header(width: geometry.size.width, pages: pages, currentPage: currentPage)
                    .offset(x: WorkbenchMiniLayout.horizontalInset, y: WorkbenchMiniLayout.headerTop)
                Group {
                    if configuring { configuration }
                    else if active.isEmpty { empty }
                    else {
                        ZStack(alignment: .topLeading) {
                            ForEach(shown, id: \.card) { placement in
                                card(placement.card, capacity: capacity)
                                    .frame(width: 220, height: placement.span == 3 ? 113 : 72)
                                    .offset(x: CGFloat(placement.column % capacity) * 230, y: CGFloat(placement.row) * 41)
                            }
                        }.frame(width: boardWidth, height: WorkbenchMiniLayout.sectionHeight, alignment: .topLeading)
                    }
                }
                .frame(width: bodyWidth, height: WorkbenchMiniLayout.sectionHeight, alignment: .top)
                .offset(x: (geometry.size.width - bodyWidth) / 2, y: WorkbenchMiniLayout.contentTopInset(safeTop: safeTop))
            }
            .onChange(of: active) { _, _ in
                if editing, let focusedCard, let placement = placements.first(where: { $0.card == focusedCard }) { page = placement.column / capacity }
                else { page = 0 }
            }
        }
        .foregroundStyle(palette.text)
        .onChange(of: externalProviders.map(\.id)) { _, _ in page = 0 }
        .accessibilityElement(children: .contain).accessibilityIdentifier("mini-panel-content")
    }

    private func header(width: CGFloat, pages: Int, currentPage: Int) -> some View {
        let innerWidth = width - WorkbenchMiniLayout.horizontalInset * 2
        let wing = max(28, (width - notchWidth) / 2 - WorkbenchMiniLayout.horizontalInset - (notchWidth > 0 ? 8 : 4))
        let compactPaging = wing < 160 && preferences.showDate && !editing && !configuring
        return HStack(spacing: 0) {
            HStack(spacing: compactPaging ? 4 : 6) {
                if pages > 1 && !configuring {
                    HStack(spacing: 0) {
                        Button { page = max(0, currentPage - 1) } label: { Image(systemName: "chevron.left").frame(width: compactPaging ? 12 : 15, height: 28) }
                            .disabled(currentPage == 0).accessibilityLabel("上一页卡片").accessibilityIdentifier("mini-previous-page")
                            .onDrop(of: [UTType.plainText], delegate: MiniPageDropDelegate(enabled: editing && dragged != nil && currentPage > 0, turn: { page = currentPage - 1 }))
                        if !compactPaging { Text(wing < 120 && pages > 9 ? "\(currentPage + 1)" : "\(currentPage + 1)/\(pages)")
                            .font(.system(size: 11)).monospacedDigit().fixedSize().accessibilityLabel("第 \(currentPage + 1) 页，共 \(pages) 页")
                        }
                        Button { page = min(pages - 1, currentPage + 1) } label: { Image(systemName: "chevron.right").frame(width: compactPaging ? 12 : 15, height: 28) }
                            .disabled(currentPage == pages - 1).accessibilityLabel("下一页卡片").accessibilityIdentifier("mini-next-page")
                            .onDrop(of: [UTType.plainText], delegate: MiniPageDropDelegate(enabled: editing && dragged != nil && currentPage < pages - 1, turn: { page = currentPage + 1 }))
                    }.fixedSize().help("第 \(currentPage + 1) 页，共 \(pages) 页")
                }
                if editing || configuring {
                    Button(configuring ? "返回布局" : "显示内容") { configuring.toggle(); editing = true }
                        .font(.system(size: 11)).frame(height: 28).accessibilityIdentifier("mini-show-configuration")
                } else if preferences.showDate {
                    Button(action: openContext) {
                        ViewThatFits(in: .horizontal) {
                            dateHeader(detail: 2)
                            dateHeader(detail: 1)
                            dateHeader(detail: 0)
                        }.frame(height: 28).contentShape(Rectangle())
                    }.buttonStyle(WBTextActionButtonStyle())
                        .help(context.date + " · " + context.zoneHelp + "\n打开首页的城市、天气与时间设置")
                        .accessibilityLabel("城市、天气与时间设置，" + context.time + "，" + context.date)
                        .accessibilityIdentifier("mini-open-context-date")
                } else { Text("方寸").font(.system(size: 12)) }
            }.frame(width: wing, height: 28, alignment: .leading).clipped()
                .accessibilityElement(children: .contain).accessibilityIdentifier("mini-header-date")
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if preferences.showWeather && !editing && !configuring {
                    Button(action: openContext) {
                        ViewThatFits(in: .horizontal) {
                            weatherHeader(detail: 2)
                            weatherHeader(detail: 1)
                            weatherHeader(detail: 0)
                        }.frame(height: 28).contentShape(Rectangle())
                    }.buttonStyle(WBTextActionButtonStyle())
                        .help([context.city, context.condition, context.weatherNote].compactMap { $0 }.joined(separator: " · ") + "\n打开首页的城市、天气与时间设置")
                        .accessibilityLabel("城市、天气与时间设置，" + context.city + "，" + context.temperature + "，" + context.condition)
                        .accessibilityIdentifier("mini-open-context-weather")
                }
                Button {
                    if editing || configuring { editing = false; configuring = false; dragged = nil; finishConfiguration() }
                    else { editing = true }
                } label: {
                    Image(systemName: editing || configuring ? "checkmark" : "gearshape").font(.system(size: 14)).frame(width: 28, height: 28)
                }
                .help(editing || configuring ? "完成布局编辑" : "编辑布局：拖动或使用方向键排序")
                .accessibilityLabel(editing || configuring ? "完成布局编辑" : "编辑布局")
                .accessibilityIdentifier("mini-configure")
            }.frame(width: wing, height: 28, alignment: .trailing).clipped()
                .accessibilityElement(children: .contain).accessibilityIdentifier("mini-header-actions")
        }.buttonStyle(.plain).clickableCursor().frame(width: innerWidth, height: 28)
    }
    private func dateHeader(detail: Int) -> some View {
        HStack(spacing: 7) {
            Text(context.time).monospacedDigit()
            if detail > 0 { Text(context.shortDate.isEmpty ? context.date : context.shortDate).foregroundStyle(palette.secondary) }
            if detail > 1 && !context.weekday.isEmpty { Text(context.weekday).foregroundStyle(palette.secondary) }
        }.font(.system(size: 12)).fixedSize()
    }
    private func weatherHeader(detail: Int) -> some View {
        HStack(spacing: 5) {
            if detail > 1 { Text(context.city) }
            Image(systemName: context.symbol).foregroundStyle(palette.accent)
            Text(context.temperature).monospacedDigit()
            if detail > 0 { Text(context.condition).foregroundStyle(palette.secondary) }
        }.font(.system(size: 12)).fixedSize().accessibilityIdentifier("mini-header-weather")
    }

    private func card(_ id: WorkbenchMiniCardID, capacity: Int) -> some View {
        let button = Button {
            if editing { focusedCard = id } else { open(id) }
        } label: {
            cardContent(id).padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(WBSelectableButtonStyle(cornerRadius: 12, drawsSelection: false, showsBorder: false))
        .background(palette.soft, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            if editing { Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(palette.muted).padding(5).allowsHitTesting(false) }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(editing && focusedCard == id ? palette.accent : .clear, lineWidth: 1))
        // Editing needs a real key responder even when system-wide keyboard
        // navigation for ordinary buttons is disabled.
        .focusable(interactions: editing ? .edit : .activate)
        .focused($focusedCard, equals: id)
        .onMoveCommand { direction in
            guard editing else { return }
            move(id, forward: direction == .right || direction == .down, capacity: capacity)
        }
        .accessibilityLabel((editing ? "调整" : "打开") + title(id)).accessibilityIdentifier("mini-card-" + id.rawValue)
        .accessibilityValue(accessibilityReading(id))
        .accessibilityActions {
            if editing {
                Button("前移") { move(id, forward: false, capacity: capacity) }
                Button("后移") { move(id, forward: true, capacity: capacity) }
                Button("隐藏卡片") { setVisible(id, false) }
            }
        }
        .onDrop(of: [UTType.plainText], delegate: MiniCardDropDelegate(target: id, enabled: editing, dragged: $dragged) { moving, target, after in
            reorder(moving, target, after); focusedCard = moving
        })
        return Group {
            if editing { button.onDrag { dragged = id; return NSItemProvider(object: id.rawValue as NSString) } }
            else { button }
        }
        .overlay(alignment: .topTrailing) {
            if id == .network && !editing {
                Menu {
                    Text("当前：全部本机网络")
                    Text("直连 / VPN：尚未接入分流识别")
                } label: { Text("全部").font(.system(size: 11)).foregroundStyle(palette.accent).padding(.horizontal, 8).frame(height: 24) }
                .menuStyle(.borderlessButton).fixedSize().padding(.top, 4).padding(.trailing, 7)
                .help("本机接口采样包含全部网络；尚无可靠的直连和 VPN 归属，不生成分流数字。")
                .accessibilityIdentifier("mini-network-scope")
            }
        }
    }
    private func move(_ id: WorkbenchMiniCardID, forward: Bool, capacity: Int) {
        guard let index = active.firstIndex(of: id) else { return }
        let targetIndex = index + (forward ? 1 : -1)
        guard active.indices.contains(targetIndex) else { return }
        let target = active[targetIndex]
        var next = preferences; next.moveCard(id, relativeTo: target, after: forward)
        reorder(id, target, forward)
        if let placement = WorkbenchMiniPacking.pack(next.activeCards(available: available)).first(where: { $0.card == id }) { page = placement.column / capacity }
        focusedCard = id
    }

    @ViewBuilder private func cardContent(_ id: WorkbenchMiniCardID) -> some View {
        switch id {
        case .codex, .claude:
            quota(providers.first { $0.provider == (id == .codex ? .codex : .claude) }, title: title(id), providerID: id == .codex ? .codex : .claude)
        case .traffic:
            VStack(spacing: 5) { heading("本机流量", "今日 " + device.todayTraffic); valueRow("本周期", device.periodTraffic); meter(device.trafficFraction) }.help(device.trafficNote)
        case .disk:
            VStack(spacing: 5) { heading("磁盘空间", percent(device.diskFraction)); valueRow(device.disk, "已用"); meter(device.diskFraction) }.help(device.diskNote)
        case .memory:
            VStack(spacing: 5) { heading("运行内存", device.memoryPressure); valueRow(device.memory, percent(device.memoryFraction)); meter(device.memoryFraction) }
                .help("内存为已用 / 总量；压力由系统独立指标提供。" + (device.note ?? ""))
        case .todo:
            VStack(alignment: .leading, spacing: 4) {
                heading("最近待办", agenda.reminder?.note ?? "")
                Text(agenda.reminder?.title ?? agenda.reminderStatus).font(.system(size: 13)).lineLimit(1)
                Text(agenda.reminder?.dateText ?? "").font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
            }.help([agenda.reminder?.title, agenda.reminder?.dateText, agenda.reminder?.note].compactMap { $0 }.joined(separator: " · "))
        case .network:
            VStack(alignment: .leading, spacing: 4) {
                heading("实时网络", "")
                HStack(spacing: 12) { networkReading("arrow.down", "下载", device.download); networkReading("arrow.up", "上传", device.upload) }
                networkTrend.frame(height: 32)
            }.help("最近 60 秒本机采样；下载实线、上传虚线，使用相同刻度。采样中断处不连线。")
        case .thermal:
            VStack(alignment: .leading, spacing: 7) {
                heading("散热状态", device.thermalState)
                HStack(spacing: 12) { sensor("CPU 温度", device.temperature); sensor("GPU 温度", device.gpuTemperature) }
                HStack(spacing: 12) { sensor("左风扇", device.leftFan); sensor("右风扇", device.rightFan) }
            }.help(device.sensorNote)
        default:
            if let value = externalProviders.first(where: { $0.id == id.providerID }) {
                VStack(spacing: 5) { heading(value.title, value.stateText); valueRow(value.amount, value.isStale ? "上次" : "已用"); meter(value.fraction, stale: value.isStale) }.help(value.detail)
            } else { Text("来源已移除").font(.system(size: 12)) }
        }
    }
    private func quota(_ provider: WorkbenchMiniAIData?, title: String, providerID: AIProvider) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                AIProviderLogo(provider: providerID, size: 14).accessibilityHidden(true)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Text(provider?.stateText == "已用" ? "" : provider?.stateText ?? "未接入")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
            }.frame(height: 16)
            if let provider {
                ForEach(Array(provider.windows.prefix(2).enumerated()), id: \.offset) { _, window in
                    HStack(spacing: 5) {
                        Text(window.label).foregroundStyle(palette.secondary).frame(width: 32, alignment: .leading)
                        meter(window.fraction, stale: provider.isStale).frame(minWidth: 16)
                        Text(window.value).monospacedDigit().frame(width: 28, alignment: .trailing)
                        Text(window.reset).foregroundStyle(palette.muted).monospacedDigit().frame(width: 72, alignment: .trailing)
                    }.font(.system(size: 11)).frame(height: 14).lineLimit(1)
                }
            } else { Text("等待已配置来源的读数").font(.system(size: 11)).foregroundStyle(palette.muted) }
        }.help(provider?.detail ?? "尚未取得真实额度读数")
    }
    private func heading(_ title: String, _ status: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            Text(status).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
        }.frame(height: 16)
    }
    private func valueRow(_ left: String, _ right: String) -> some View {
        HStack(spacing: 4) { Text(left).lineLimit(1).monospacedDigit(); Spacer(minLength: 0); Text(right).foregroundStyle(palette.secondary).lineLimit(1).monospacedDigit() }
            .font(.system(size: 11)).frame(height: 16)
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
    private func meter(_ fraction: Double?, stale: Bool = false) -> some View {
        GeometryReader { geometry in
            if let fraction, fraction.isFinite {
                Capsule().fill(palette.progressTrack)
                Capsule().fill(stale ? palette.muted : palette.accent).frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }.frame(height: 3).accessibilityHidden(true)
    }
    private func sensor(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary); Text(value).font(.system(size: 13)).lineLimit(1).monospacedDigit() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func networkReading(_ symbol: String, _ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) { Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(palette.secondary); Text(value).font(.system(size: 15, weight: .medium)).monospacedDigit().lineLimit(1) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var networkTrend: some View {
        Group {
            if device.networkPoints.count < 2 {
                Text("等待连续采样").font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { drawing, size in
                    let points = device.networkPoints
                    let maximum = max(1, points.flatMap { [$0.download, $0.upload].compactMap { $0 }.filter { $0.isFinite && $0 >= 0 } }.max() ?? 1)
                    let first = points.first!.date, duration = max(1, points.last!.date.timeIntervalSince(first))
                    for upload in [false, true] {
                        var path = Path(), previous: WorkbenchMiniNetworkPoint?
                        for point in points {
                            let value = upload ? point.upload : point.download
                            guard let value, value.isFinite, value >= 0 else { previous = nil; continue }
                            let location = CGPoint(x: point.date.timeIntervalSince(first) / duration * size.width, y: size.height - 1 - min(1, value / maximum) * (size.height - 2))
                            if let previous, previous.segment == point.segment, point.date.timeIntervalSince(previous.date) <= 8 { path.addLine(to: location) }
                            else { path.move(to: location) }
                            previous = point
                        }
                        drawing.stroke(path, with: .color(upload ? palette.secondary : palette.accent), style: .init(lineWidth: 1.4, dash: upload ? [3, 2] : []))
                    }
                }.accessibilityLabel("最近60秒网络趋势：下载实线、上传虚线")
            }
        }
    }
    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("显示内容").font(.system(size: 12, weight: .medium)); Spacer()
                    Button("恢复默认", action: restore).font(.system(size: 11)).buttonStyle(.plain).clickableCursor().accessibilityIdentifier("mini-restore")
                }
                LazyVGrid(columns: [.init(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 8) {
                    Toggle("日期时间", isOn: Binding(get: { preferences.showDate }, set: { setHeaderVisible($0, preferences.showWeather) }))
                    Toggle("城市天气", isOn: Binding(get: { preferences.showWeather }, set: { setHeaderVisible(preferences.showDate, $0) }))
                    Toggle("显示秒数", isOn: Binding(get: { preferences.showSeconds }, set: setSeconds))
                        .disabled(!preferences.showDate).accessibilityIdentifier("mini-show-seconds")
                }.font(.system(size: 11)).toggleStyle(.checkbox).clickableCursor()
                LazyVGrid(columns: [.init(.adaptive(minimum: 145), spacing: 12)], alignment: .leading, spacing: 8) {
                    ForEach(available) { id in
                        Toggle(title(id), isOn: Binding(get: { preferences.visibleCards.contains(id) }, set: { setVisible(id, $0) }))
                            .font(.system(size: 11)).toggleStyle(.checkbox).clickableCursor().frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("mini-toggle-" + id.rawValue)
                    }
                }
                Text(error ?? "布局编辑时拖动卡片，或聚焦卡片后用方向键排序。即时保存。")
                    .font(.system(size: 11)).foregroundStyle(error == nil ? palette.muted : palette.warning)
            }.padding(12)
        }.background(palette.soft, in: RoundedRectangle(cornerRadius: 12))
    }
    private var empty: some View {
        VStack(spacing: 10) {
            Text("已隐藏全部卡片").font(.system(size: 13))
            Button("配置显示内容") { configuring = true; editing = true }.font(.system(size: 12)).buttonStyle(.plain).clickableCursor()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func title(_ id: WorkbenchMiniCardID) -> String { externalProviders.first { $0.id == id.providerID }?.title ?? id.title }
    private func accessibilityReading(_ id: WorkbenchMiniCardID) -> String {
        switch id {
        case .codex, .claude:
            guard let value = providers.first(where: { $0.provider == (id == .codex ? .codex : .claude) }) else { return "未接入" }
            return ([value.stateText] + value.windows.map { "\($0.label)已用\($0.value)，重置\($0.reset)" }).joined(separator: "；")
        case .traffic: return "今日\(device.todayTraffic)；本周期\(device.periodTraffic)"
        case .disk: return "已用／总量\(device.disk)"
        case .memory: return "已用／总量\(device.memory)；\(device.memoryPressure)"
        case .todo: return [agenda.reminder?.title ?? agenda.reminderStatus, agenda.reminder?.dateText, agenda.reminder?.note].compactMap { $0 }.joined(separator: "；")
        case .network: return "下载\(device.download)；上传\(device.upload)；全部本机网络"
        case .thermal: return "CPU \(device.temperature)；GPU \(device.gpuTemperature)；左风扇\(device.leftFan)；右风扇\(device.rightFan)"
        default:
            guard let value = externalProviders.first(where: { $0.id == id.providerID }) else { return "来源已移除" }
            return "\(value.stateText)；\(value.amount)"
        }
    }
}

private struct MiniCardDropDelegate: DropDelegate {
    let target: WorkbenchMiniCardID
    let enabled: Bool
    @Binding var dragged: WorkbenchMiniCardID?
    let move: (WorkbenchMiniCardID, WorkbenchMiniCardID, Bool) -> Void
    func validateDrop(info: DropInfo) -> Bool { enabled && dragged != nil && dragged != target }
    func dropUpdated(info: DropInfo) -> DropProposal? { validateDrop(info: info) ? .init(operation: .move) : .init(operation: .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let source = dragged else { return false }
        move(source, target, info.location.y > (target.span == 3 ? 56.5 : 36)); dragged = nil
        return true
    }
}
private struct MiniPageDropDelegate: DropDelegate {
    let enabled: Bool
    let turn: () -> Void
    func validateDrop(info: DropInfo) -> Bool { enabled }
    func dropEntered(info: DropInfo) { if enabled { turn() } }
    func dropUpdated(info: DropInfo) -> DropProposal? { .init(operation: enabled ? .move : .forbidden) }
    func performDrop(info: DropInfo) -> Bool { false }
}

extension WorkbenchMiniCardID {
    var title: String {
        switch self {
        case .codex: "Codex 用量"; case .claude: "Claude 用量"; case .traffic: "本机流量"
        case .disk: "磁盘空间"; case .memory: "运行内存"; case .todo: "最近待办"
        case .network: "实时网络"; case .thermal: "散热状态"; default: "外部用量"
        }
    }
}
extension WorkbenchMiniSection {
    var title: String { switch self { case .context: "日期与天气"; case .agenda: "日历与待办"; case .device: "本机状态"; case .ai: "AI 用量" } }
}
