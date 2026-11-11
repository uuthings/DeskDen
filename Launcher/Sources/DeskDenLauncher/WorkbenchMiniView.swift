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
    @ObservedObject var balances: APIBalanceModel
    @ObservedObject var appearance: UsagePresentationModel
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
        balances = model.apiBalance; appearance = model.usageAppearance
        _agendaProjection = StateObject(wrappedValue: WorkbenchMiniAgendaProjection(calendar: model.calendar, context: model.context))
        self.openedAt = openedAt; self.safeTop = safeTop; self.notchWidth = notchWidth
        self.open = open; self.openContext = openContext; self.finishConfiguration = finishConfiguration
    }

    private var currentThermalStatus: DeviceThermalPresentation {
        guard WorkbenchMiniDeviceData.sampleIsCurrent(device.snapshot.thermalSampledAt, now: Date(), maximumAge: 90) else {
            return .init(cpu: nil, gpu: nil, state: .unknown, isLoading: true)
        }
        return .init(snapshot: device.snapshot, rule: device.temperatureRule)
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
                          now: timeline.date, displayCalendar: context.dateContext.calendar, enabled: ai.configuration(for: provider).enabled)
                },
                externalProviders: providerUsage.sources.map {
                    WorkbenchMiniExternalProviderData(configuration: $0, state: providerUsage.state(for: $0.id),
                                                      now: timeline.date, calendar: context.dateContext.calendar)
                }, balances: balances.sources.map {
                    WorkbenchMiniAPIBalanceData(configuration: $0, state: balances.state(for: $0.id), now: timeline.date, calendar: context.dateContext.calendar)
                }, appearance: appearance, sourceKinds: Dictionary(uniqueKeysWithValues: providerUsage.sources.map { ($0.id, $0.kind) }), thermalStatus: currentThermalStatus, preferences: controller.preferences, safeTop: safeTop, notchWidth: notchWidth,
                error: controller.error, open: open, openContext: openContext, setVisible: controller.setMiniCard,
                setHeaderVisible: controller.setMiniHeader, setSeconds: controller.setMiniSeconds, reorder: controller.moveMiniCard,
                restore: controller.restoreMiniSections, finishConfiguration: finishConfiguration, saveLayout: controller.saveMiniLayout
            )
            .onChange(of: timeline.date) { _, date in agendaProjection.update(now: date) }
        }
        .onChange(of: providerUsage.sources.map(\.id)) { _, _ in finishConfiguration() }
        .workbenchThemeEnvironment(theme: model.theme, opacity: model.opacity, backgroundMotion: false, appearance: model.appearance)
    }
}

/// Production and isolated render fixtures use this same modular panel.
/// WorkbenchNotchSurface supplies the outer glass; cards share a soft tint and fine border.
struct WorkbenchMiniPanelView: View {
    var context: WorkbenchMiniContextData
    var agenda: WorkbenchMiniAgendaData
    var device: WorkbenchMiniDeviceData
    var providers: [WorkbenchMiniAIData]
    var externalProviders: [WorkbenchMiniExternalProviderData] = []
    var balances: [WorkbenchMiniAPIBalanceData] = []
    var appearance: UsagePresentationModel? = nil
    var sourceKinds: [UUID: ProviderUsageKind] = [:]
    var thermalStatus: DeviceThermalPresentation = .init(cpu: nil, gpu: nil, state: .unknown, rule: .init())
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
    var saveLayout: ((WorkbenchTopEntryPreferences) -> Bool)? = nil
    @State var configuring = false
    @State private var draft: WorkbenchTopEntryPreferences?
    @State private var dragOriginal: WorkbenchTopEntryPreferences?
    @State private var dragPoint = CGPoint.zero
    @State private var dragGrab = CGSize.zero
    @State private var dragPageDirection = 0
    @State private var dragCapacity = 1
    @GestureState private var gestureActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing = false
    @State private var page = 0
    @State private var dragged: WorkbenchMiniCardID?
    @FocusState private var focusedCard: WorkbenchMiniCardID?
    @Environment(\.workbenchPalette) private var palette

    private var available: [WorkbenchMiniCardID] { WorkbenchMiniCardID.builtIn + externalProviders.map { .provider($0.id) } + balances.map { .apiBalance($0.id) } }
    private var current: WorkbenchTopEntryPreferences { draft ?? preferences }
    private var active: [WorkbenchMiniCardID] { current.activeCards(available: available) }
    private var placements: [WorkbenchMiniPlacement] { WorkbenchMiniPacking.pack(active) }
    private var columns: Int { (placements.map(\.column).max() ?? -1) + 1 }

    var body: some View {
        GeometryReader { geometry in
            let bodyWidth = max(220, geometry.size.width - WorkbenchMiniLayout.horizontalInset * 2)
            let capacity = min(4, max(1, Int((bodyWidth + 10) / 230)))
            let pages = max(1, (columns + capacity - 1) / capacity)
            let currentPage = min(page, pages - 1)
            let shown = placements.filter { $0.column / capacity == currentPage }
            let shownColumns = editing ? capacity : max(1, min(capacity, columns - currentPage * capacity))
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
                                ZStack {
                                    if dragged == placement.card {
                                        RoundedRectangle(cornerRadius: 12).fill(palette.accent.opacity(0.08))
                                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                            .accessibilityLabel("放置位置").accessibilityIdentifier("mini-drag-placeholder")
                                    }
                                    card(placement.card, capacity: capacity)
                                        .opacity(dragged == placement.card ? 0 : 1)
                                }
                                .frame(width: 220, height: placement.span == 3 ? 113 : 72)
                                .offset(x: CGFloat(placement.column % capacity) * 230, y: CGFloat(placement.row) * 41)
                            }
                            if let dragged {
                                cardSurface(dragged).frame(width: 220, height: dragged.span == 3 ? 113 : 72)
                                    .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
                                    .offset(x: dragPoint.x - dragGrab.width, y: dragPoint.y - dragGrab.height)
                                    .allowsHitTesting(false).accessibilityHidden(true).zIndex(10)
                            }
                        }.frame(width: boardWidth, height: WorkbenchMiniLayout.sectionHeight, alignment: .topLeading)
                            .coordinateSpace(name: "mini-board")
                            .contentShape(Rectangle())
                            .highPriorityGesture(DragGesture(minimumDistance: 7, coordinateSpace: .named("mini-board"))
                                .updating($gestureActive) { _, state, _ in if editing { state = true } }
                                .onChanged { value in
                                    guard editing else { return }
                                    let source = dragged ?? shown.first { placement in
                                        let origin = CGPoint(x: CGFloat(placement.column % capacity) * 230, y: CGFloat(placement.row) * 41)
                                        let rect = CGRect(origin: origin, size: CGSize(width: 220, height: placement.span == 3 ? 113 : 72))
                                        let hideControl = CGRect(x: origin.x + 198, y: origin.y - 4, width: 26, height: 26)
                                        return rect.contains(value.startLocation) && !hideControl.contains(value.startLocation)
                                    }?.card
                                    if let source { updateDrag(source, value: value, capacity: capacity) }
                                }
                                .onEnded { value in
                                    let width = CGFloat(capacity) * 230 - 10
                                    if value.location.x < -24 || value.location.x > width + 24 || value.location.y < -44 || value.location.y > 260 { cancelDrag() }
                                    else { dragged = nil; dragOriginal = nil; dragPageDirection = 0 }
                                // Disable only the editor's drag recognizer in
                                // normal mode. `.none` also disables the child
                                // buttons' pointer gestures, despite AX press
                                // actions continuing to work.
                                }, including: editing ? .all : .subviews)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: current.cardOrder)

                    }
                }
                .frame(width: bodyWidth, height: WorkbenchMiniLayout.sectionHeight, alignment: .top)
                .offset(x: (geometry.size.width - bodyWidth) / 2, y: WorkbenchMiniLayout.contentTopInset(safeTop: safeTop))
            }
            .onChange(of: active) { _, _ in page = min(page, max(0, (columns + capacity - 1) / capacity - 1)) }
            .onChange(of: capacity) { _, _ in page = min(page, max(0, (columns + capacity - 1) / capacity - 1)) }
        }
        .onAppear { if configuring { beginEditing() } }
        .onChange(of: gestureActive) { _, running in if !running, dragged != nil { cancelDrag() } }
        .task(id: dragPageDirection) {
            guard dragPageDirection != 0 else { return }
            do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
            guard dragged != nil else { return }
            page = max(0, min(max(0, (columns - 1) / dragCapacity), page + dragPageDirection))
            dragPageDirection = 0
        }

        .foregroundStyle(palette.text)
        .onChange(of: externalProviders.map(\.id)) { _, _ in page = 0 }
        .accessibilityElement(children: .contain).accessibilityIdentifier("mini-panel-content")
    }

    private func header(width: CGFloat, pages: Int, currentPage: Int) -> some View {
        let innerWidth = width - WorkbenchMiniLayout.horizontalInset * 2
        let wing = max(28, (width - notchWidth) / 2 - WorkbenchMiniLayout.horizontalInset - (notchWidth > 0 ? 8 : 4))
        let compactPaging = wing < 180
        return HStack(spacing: 0) {
            HStack(spacing: compactPaging ? 4 : 6) {
                if pages > 1 && !configuring {
                    HStack(spacing: 0) {
                        Button { page = max(0, currentPage - 1) } label: { Image(systemName: "chevron.left").frame(width: compactPaging ? 12 : 15, height: 28) }
                            .disabled(currentPage == 0).accessibilityLabel("上一页卡片").accessibilityIdentifier("mini-previous-page")
                        if !compactPaging { Text(wing < 120 && pages > 9 ? "\(currentPage + 1)" : "\(currentPage + 1)/\(pages)")
                            .font(.system(size: 11)).monospacedDigit().fixedSize().accessibilityLabel("第 \(currentPage + 1) 页，共 \(pages) 页")
                        }
                        Button { page = min(pages - 1, currentPage + 1) } label: { Image(systemName: "chevron.right").frame(width: compactPaging ? 12 : 15, height: 28) }
                            .disabled(currentPage == pages - 1).accessibilityLabel("下一页卡片").accessibilityIdentifier("mini-next-page")
                    }.fixedSize().help("第 \(currentPage + 1) 页，共 \(pages) 页")
                }
                if editing || configuring {
                    Button { beginEditing(); configuring.toggle() } label: {
                        if configuring { Label("编辑 Mini", systemImage: "chevron.left") } else { Text("添加卡片") }
                    }.font(.system(size: 11)).frame(height: 28)
                        .accessibilityLabel(configuring ? "返回编辑 Mini" : "添加卡片").accessibilityIdentifier("mini-show-configuration")
                } else if current.showDate {
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
                if current.showWeather && !editing && !configuring {
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
                if editing || configuring {
                    compactAction("取消编辑", symbol: "xmark", identifier: "mini-cancel") { cancelEditing() }
                    compactAction("保存布局", symbol: "checkmark", identifier: "mini-configure") { commitEditing() }
                } else {
                    compactAction("编辑布局", symbol: "gearshape", identifier: "mini-configure") { beginEditing() }
                }
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

    private func compactAction(_ title: String, symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)).frame(width: 26, height: 26).contentShape(RoundedRectangle(cornerRadius: 6)) }
            .buttonStyle(WBTextActionButtonStyle()).help(title).accessibilityLabel(title).accessibilityIdentifier(identifier)
    }
    private func beginEditing() {
        if draft == nil { var value = preferences; value.materializeLayout(available: available); draft = value }
        editing = true
    }
    private func cancelEditing() {
        cancelDrag(); draft = nil; editing = false; configuring = false; page = 0
        finishConfiguration()
    }
    private func commitEditing() {
        cancelDrag()
        guard let value = draft else { return }
        if let saveLayout { guard saveLayout(value) else { configuring = true; return } }
        else {
            for id in available { setVisible(id, value.visibleCards.contains(id)) }
            for pair in zip(value.cardOrder, value.cardOrder.dropFirst()) { reorder(pair.1, pair.0, true) }
            setHeaderVisible(value.showDate, value.showWeather); setSeconds(value.showSeconds)
        }
        draft = nil; editing = false; configuring = false; finishConfiguration()
    }
    private func editVisibility(_ id: WorkbenchMiniCardID, _ visible: Bool) { beginEditing(); draft?.setCard(id, visible: visible) }
    private func restoreDraft() {
        beginEditing(); var value = WorkbenchTopEntryPreferences(); value.enabled = preferences.enabled; value.mode = preferences.mode
        value.materializeLayout(available: available); value.usesDefaultLayout = true; draft = value; page = 0
    }
    private func cardSurface(_ id: WorkbenchMiniCardID) -> some View {
        cardContent(id).padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WorkbenchMaterialSurface(radius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(palette.light ? Color(red: 0.17, green: 0.31, blue: 0.34).opacity(0.22) : palette.border, lineWidth: 1)
                .allowsHitTesting(false))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    private func card(_ id: WorkbenchMiniCardID, capacity: Int) -> some View {
        let content = Button {
            if editing { focusedCard = id } else { open(id) }
        } label: { cardSurface(id) }
            .buttonStyle(WBSelectableButtonStyle(cornerRadius: 12, drawsSelection: false, showsBorder: false))
            .focusable(interactions: editing ? .edit : .activate).focusEffectDisabled()
            .focused($focusedCard, equals: id)
            .onMoveCommand { direction in guard editing else { return }; move(id, forward: direction == .right || direction == .down, capacity: capacity) }
            .accessibilityLabel((editing ? "调整" : "打开") + title(id)).accessibilityIdentifier("mini-card-" + id.rawValue)
            .accessibilityValue(accessibilityReading(id))
        return Group {
            if editing {
                content
                    .accessibilityAction(named: Text("前移")) { Task { @MainActor in guard editing else { return }; move(id, forward: false, capacity: capacity) } }
                    .accessibilityAction(named: Text("后移")) { Task { @MainActor in guard editing else { return }; move(id, forward: true, capacity: capacity) } }
                    .accessibilityAction(named: Text("隐藏卡片")) { Task { @MainActor in guard editing else { return }; editVisibility(id, false) } }
            } else { content }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(editing && focusedCard == id ? palette.accent.opacity(0.5) : .clear, lineWidth: 1).allowsHitTesting(false))
        .overlay(alignment: .topTrailing) {
            if editing && dragged == nil {
                Button { editVisibility(id, false) } label: { Image(systemName: "eye.slash").font(.system(size: 11)).frame(width: 22, height: 22).background(palette.raised, in: Circle()) }
                    .buttonStyle(.plain).clickableCursor().help("隐藏" + title(id)).accessibilityLabel("隐藏" + title(id))
                    .accessibilityIdentifier("mini-hide-" + id.rawValue).offset(x: 4, y: -4)
            }
        }
    }
    private func move(_ id: WorkbenchMiniCardID, forward: Bool, capacity: Int) {
        guard let index = active.firstIndex(of: id) else { return }
        let next = index + (forward ? 1 : -1); guard active.indices.contains(next) else { return }
        draft?.moveCard(id, relativeTo: active[next], after: forward)
        if let placement = placements.first(where: { $0.card == id }) { page = placement.column / capacity }
        focusedCard = id
    }
    private func cancelDrag() {
        if let original = dragOriginal { draft = original }
        dragged = nil; dragOriginal = nil; dragPageDirection = 0
    }
    private func updateDrag(_ id: WorkbenchMiniCardID, value: DragGesture.Value, capacity: Int) {
        if dragged == nil, let placement = placements.first(where: { $0.card == id }) {
            dragOriginal = draft; dragged = id; dragCapacity = capacity
            dragGrab = CGSize(width: value.startLocation.x - CGFloat(placement.column % capacity) * 230,
                              height: value.startLocation.y - CGFloat(placement.row) * 41)
        }
        guard dragged == id else { return }; dragPoint = value.location
        let width = CGFloat(capacity) * 230 - 10
        dragPageDirection = value.location.x < 4 && page > 0 ? -1 : value.location.x > width - 4 && (page + 1) * capacity < columns ? 1 : 0
        guard value.location.x >= 0, value.location.x <= width, value.location.y >= 0, value.location.y <= 236 else { return }
        let column = min(capacity - 1, max(0, Int((value.location.x + 5) / 230))) + page * capacity
        if let placeholder = placements.first(where: { $0.card == id }), placeholder.column == column,
           (CGFloat(placeholder.row) * 41...CGFloat(placeholder.row) * 41 + (id.span == 3 ? 113 : 72)).contains(value.location.y) { return }
        let candidates = placements.filter { $0.column == column && $0.card != id }
        let target = candidates.first { value.location.y < CGFloat($0.row) * 41 + ($0.span == 3 ? 56.5 : 36) }
        if let target { draft?.moveCard(id, relativeTo: target.card, after: false) }
        else if let last = candidates.last { draft?.moveCard(id, relativeTo: last.card, after: true) }
    }

    @ViewBuilder private func cardContent(_ id: WorkbenchMiniCardID) -> some View {
        switch id {
        case .codex, .claude:
            quota(providers.first { $0.provider == (id == .codex ? .codex : .claude) }, id: id)
        case .traffic:
            VStack(spacing: 4) { heading(id, ""); valueRow(device.periodTraffic, percent(device.trafficFraction)); meter(device.trafficFraction) }.help(device.trafficNote)
        case .disk:
            VStack(spacing: 4) { heading(id, device.diskStatus); valueRow(device.disk, percent(device.diskFraction)); meter(device.diskFraction) }.help(device.diskNote + (device.diskStatus.isEmpty ? "" : "\n" + device.diskStatus))
        case .memory:
            VStack(spacing: 4) { heading(id, device.memoryStatus); valueRow(device.memory, percent(device.memoryFraction)); meter(device.memoryFraction, color: DeviceAppearance.pressure(device.memoryPressureState, palette: palette)) }
                .help("内存为已用 / 总量；压力由系统独立指标提供。" + device.memoryPressure + (device.note ?? ""))
        case .todo:
            VStack(alignment: .leading, spacing: 3) {
                heading(id, agenda.reminder?.note ?? "")
                Text(agenda.reminder?.title ?? agenda.reminderStatus).font(.system(size: 12)).lineLimit(1)
                Text(agenda.reminder?.dateText ?? "").font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
            }.help([agenda.reminder?.title, agenda.reminder?.dateText, agenda.reminder?.note].compactMap { $0 }.joined(separator: " · "))
        case .network:
            VStack(alignment: .leading, spacing: 4) {
                heading(id, device.networkStatus)
                HStack(spacing: 8) {
                    Label(device.download, systemImage: "arrow.down"); Spacer(minLength: 0)
                    Label(device.upload, systemImage: "arrow.up")
                }.font(.system(size: 12)).monospacedDigit().lineLimit(1).frame(height: 18)
                networkTrend.frame(height: 28)
                valueRow("近60秒", "今日已记录 " + device.todayTraffic)
            }.help("最近 60 秒本机全部流量采样；下载实线、上传虚线，使用相同刻度。采样中断处不连线。" + device.trafficNote)
        case .thermal:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    titleLabel(id)
                    if device.thermalUpdating { Text("更新中").font(.system(size: 11)).foregroundStyle(palette.muted) }
                    Spacer(minLength: 0)
                    DeviceThermalStatusBadge(status: thermalStatus)
                }.frame(height: 18)
                HStack(spacing: 12) {
                    temperature("CPU", device.temperature, level: thermalStatus.cpuLevel, trailing: false)
                    temperature("GPU", device.gpuTemperature, level: thermalStatus.gpuLevel, trailing: true)
                }
                valueRow("左 " + device.leftFan, "右 " + device.rightFan)
            }.help(thermalStatus.detail + "\n" + device.sensorNote)
        default:
            if let value = externalProviders.first(where: { $0.id == id.providerID }) {
                VStack(alignment: .leading, spacing: 2) {
                    heading(id, value.isStale ? value.stateText : "")
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value.remaining).font(.system(size: 17, weight: .medium)).monospacedDigit()
                        Text(value.unit + " 剩余").font(.system(size: 11)).foregroundStyle(palette.secondary)
                    }.lineLimit(1).frame(height: 20)
                    valueRow(value.amount, value.usedPercent.map { UsagePercentage.text($0) } ?? percent(value.fraction)); meter(value.fraction, stale: value.isStale)
                    Text(value.reset).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1).frame(height: 14)
                    UsageResetClock(interval: 1) { now in
                        Text(value.observedAt.map { (value.isStale ? "上次读数 " : "更新于 ") + UsageObservationAge.text(since: $0, now: now) } ?? "尚无更新时间")
                            .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).monospacedDigit().frame(height: 14)
                    }
                }.help(value.detail)
            } else if let value = balances.first(where: { $0.id == id.apiBalanceID }) {
                VStack(alignment: .leading, spacing: 6) {
                    heading(id, value.isStale ? value.stateText : "")
                    Text(value.amount).font(.system(size: 17, weight: .medium)).monospacedDigit().lineLimit(2)
                    Text(value.isStale ? "上次余额" : value.stateText).font(.system(size: 11)).foregroundStyle(palette.secondary)
                }.help(value.detail)
            } else { Text("来源已移除").font(.system(size: 12)) }
        }
    }
    private func quota(_ provider: WorkbenchMiniAIData?, id: WorkbenchMiniCardID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(id, provider?.stateText == "已用" ? "" : provider?.stateText ?? "未接入")
            if let provider {
                ForEach(Array(provider.windows.prefix(2).enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(window.label).foregroundStyle(palette.secondary).frame(width: 38, alignment: .leading)
                            meter(window.fraction, stale: provider.isStale).frame(minWidth: 16)
                            Text(window.value).monospacedDigit().frame(minWidth: 29, alignment: .trailing)
                        }.font(.system(size: 11)).frame(height: 14).lineLimit(1)
                        Text(window.reset).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1).frame(height: 14)
                    }
                }
                if provider.windows.isEmpty {
                    Text(provider.emptyMessage).font(.system(size: 12)).foregroundStyle(palette.secondary).lineLimit(2)
                    if let hint = provider.emptyHint { Text(hint).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1) }
                } else if let note = provider.availabilityNote {
                    Text(note).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                }
            } else { Text("连接本机订阅后显示额度").font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2) }
        }.help(provider?.detail ?? "尚未取得真实额度读数")
    }
    private func sourceKey(_ id: WorkbenchMiniCardID) -> String? {
        if id == .codex || id == .claude { return UsagePresentationSourceID.ai(id == .codex ? .codex : .claude) }
        if let uuid = id.providerID { return UsagePresentationSourceID.service(uuid) }
        if let uuid = id.apiBalanceID { return UsagePresentationSourceID.api(uuid) }
        return nil
    }
    @ViewBuilder private func sourceIcon(_ id: WorkbenchMiniCardID) -> some View {
        if let key = sourceKey(id), let appearance {
            UsageSourceIcon(appearance: appearance, icon: appearance.appearance(for: key).icon,
                aiProvider: id == .codex ? .codex : id == .claude ? .claude : nil,
                serviceKind: id.providerID.flatMap { sourceKinds[$0] }, defaultBrand: id.apiBalanceID != nil ? .deepseek : nil, size: 16)
        } else if id == .codex || id == .claude { AIProviderLogo(provider: id == .codex ? .codex : .claude, size: 16) }
        else { WorkbenchContentIcon(mini: id, size: 16).foregroundStyle(palette.secondary) }
    }
    private func titleLabel(_ id: WorkbenchMiniCardID) -> some View {
        HStack(spacing: 6) { sourceIcon(id); Text(title(id)).font(.system(size: 12, weight: .medium)).lineLimit(1) }
    }
    private func heading(_ id: WorkbenchMiniCardID, _ status: String) -> some View {
        HStack(spacing: 4) {
            titleLabel(id); Spacer(minLength: 0)
            if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1) }
        }.frame(height: 18)
    }
    private func valueRow(_ left: String, _ right: String) -> some View {
        HStack(spacing: 4) { Text(left).lineLimit(1).monospacedDigit(); Spacer(minLength: 0); Text(right).foregroundStyle(palette.secondary).lineLimit(1).monospacedDigit() }
            .font(.system(size: 11)).frame(height: 14)
    }
    private func percent(_ value: Double?) -> String { UsagePercentage.text(value.map { $0 * 100 }) }
    private func meter(_ fraction: Double?, stale: Bool = false, color: Color? = nil) -> some View {
        GeometryReader { geometry in
            if let fraction, fraction.isFinite {
                Capsule().fill(palette.progressTrack)
                Capsule().fill(stale ? palette.muted : color ?? palette.usageColor(forPercent: fraction * 100)).frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }.frame(height: 3).accessibilityHidden(true)
    }
    private func temperature(_ title: String, _ value: String, level: DeviceThermalLevel, trailing: Bool) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary)
            Text(value).font(.system(size: 24)).foregroundStyle(level.color(palette: palette)).lineLimit(1).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
    private var networkTrend: some View {
        let downloads = device.networkSegments(upload: false), uploads = device.networkSegments(upload: true)
        return Group {
            if downloads.isEmpty && uploads.isEmpty {
                let status = switch device.networkStatus {
                case "无活动接口": "当前无活动网络接口"
                case "网卡读数不可用", "采样已暂停": device.networkStatus
                default: device.download == "—" && device.upload == "—" ? "正在建立网络采样" : "正在采集趋势"
                }
                Text(status)
                    .font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { drawing, size in
                    let points = device.networkPoints
                    let maximum = max(1, points.flatMap { [$0.download, $0.upload].compactMap { $0 }.filter { $0.isFinite && $0 >= 0 } }.max() ?? 1)
                    let duration = WorkbenchMiniDeviceData.networkWindowDuration
                    let first = device.networkWindowEnd.addingTimeInterval(-duration)
                    for upload in [false, true] {
                        let color = upload ? palette.secondary : palette.accent
                        for segment in upload ? uploads : downloads {
                            let locations = segment.map { point in
                                let value = (upload ? point.upload : point.download)!
                                return CGPoint(x: point.date.timeIntervalSince(first) / duration * size.width,
                                               y: size.height - 1 - min(1, value / maximum) * (size.height - 2))
                            }
                            guard let start = locations.first else { continue }
                            var path = Path(); path.move(to: start)
                            for curve in DeviceTrendCurve.segments(locations) {
                                path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
                            }
                            if locations.count == 1 {
                                drawing.fill(Path(ellipseIn: CGRect(x: start.x - 1, y: start.y - 1, width: 2, height: 2)), with: .color(color))
                            }
                            drawing.stroke(path, with: .color(color), style: .init(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: upload ? [3, 2] : []))
                        }
                    }
                }.accessibilityLabel("最近60秒网络曲线：下载实线、上传虚线")
            }
        }
    }
    private var configuration: some View {
        WorkbenchScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("显示内容").font(.system(size: 12, weight: .medium)); Spacer()
                    Button("恢复默认", action: restoreDraft).font(.system(size: 11)).buttonStyle(.plain).clickableCursor().accessibilityIdentifier("mini-restore")
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning).accessibilityIdentifier("mini-save-error") }
                LazyVGrid(columns: [.init(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 8) {
                    Toggle("日期时间", isOn: Binding(get: { current.showDate }, set: { draft?.showDate = $0 }))
                    Toggle("城市天气", isOn: Binding(get: { current.showWeather }, set: { draft?.showWeather = $0 }))
                    Toggle("显示秒数", isOn: Binding(get: { current.showSeconds }, set: { draft?.showSeconds = $0 }))
                        .disabled(!current.showDate).accessibilityIdentifier("mini-show-seconds")
                }.font(.system(size: 11)).toggleStyle(.checkbox).clickableCursor()
                LazyVGrid(columns: [.init(.adaptive(minimum: 145), spacing: 12)], alignment: .leading, spacing: 8) {
                    ForEach(available) { id in
                        Toggle(title(id), isOn: Binding(get: { current.visibleCards.contains(id) }, set: { editVisibility(id, $0) }))
                            .font(.system(size: 11)).toggleStyle(.checkbox).clickableCursor().frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("mini-toggle-" + id.rawValue)
                    }
                }
                Text("拖动整张卡片调整顺序，确认后保存。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }.padding(12)
        }.background(palette.soft, in: RoundedRectangle(cornerRadius: 12))
    }
    private var empty: some View {
        VStack(spacing: 10) {
            Text("已隐藏全部卡片").font(.system(size: 12))
            Button("配置显示内容") { beginEditing(); configuring = true }.font(.system(size: 12)).buttonStyle(.plain).clickableCursor()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func title(_ id: WorkbenchMiniCardID) -> String {
        if let key = sourceKey(id), let name = appearance?.appearance(for: key).displayName, !name.isEmpty { return name }
        return externalProviders.first { $0.id == id.providerID }?.title ?? balances.first { $0.id == id.apiBalanceID }?.title ?? id.title
    }
    private func accessibilityReading(_ id: WorkbenchMiniCardID) -> String {
        switch id {
        case .codex, .claude:
            guard let value = providers.first(where: { $0.provider == (id == .codex ? .codex : .claude) }) else { return "未接入" }
            return ([value.stateText] + value.windows.map { "\($0.label)已用\($0.value)，重置\($0.reset)" } + [value.windows.isEmpty ? value.emptyMessage : value.availabilityNote].compactMap { $0 }).joined(separator: "；")
        case .traffic: return "今日\(device.todayTraffic)；本周期\(device.periodTraffic)"
        case .disk: return "已用／总量\(device.disk)；\(device.diskStatus)"
        case .memory: return "已用／总量\(device.memory)；\(device.memoryPressure)；\(device.memoryStatus)"
        case .todo: return [agenda.reminder?.title ?? agenda.reminderStatus, agenda.reminder?.dateText, agenda.reminder?.note].compactMap { $0 }.joined(separator: "；")
        case .network: return "下载\(device.download)；上传\(device.upload)；全部本机网络；\(device.networkStatus)"
        case .thermal: return "\(thermalStatus.title)；CPU \(device.temperature)；GPU \(device.gpuTemperature)；左风扇\(device.leftFan)；右风扇\(device.rightFan)" + (device.thermalUpdating ? "；更新中" : "")
        default:
            if let value = balances.first(where: { $0.id == id.apiBalanceID }) { return "\(value.stateText)；\(value.amount)" }
            guard let value = externalProviders.first(where: { $0.id == id.providerID }) else { return "来源已移除" }
            return "\(value.stateText)；\(value.amount)" + (value.observedAt.map { "；更新于 " + UsageObservationAge.text(since: $0) } ?? "")
        }
    }
}

extension WorkbenchMiniCardID {
    var title: String {
        switch self {
        case .codex: "Codex"; case .claude: "Claude"; case .traffic: "今日流量"
        case .disk: "存储空间"; case .memory: "统一内存"; case .todo: "最近待办"
        case .network: "网络速度"; case .thermal: "散热状态"; default: "外部用量"
        }
    }
}
extension WorkbenchMiniSection {
    var title: String { switch self { case .context: "日期与天气"; case .agenda: "日历与待办"; case .device: "本机状态"; case .ai: "AI 用量" } }
}
