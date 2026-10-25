import SwiftUI
import LauncherCore

/// Observes the existing services. The Mini owns no additional sampling or AI
/// history loop; its clock only invalidates once a minute while mounted.
struct WorkbenchMiniView: View {
    @ObservedObject var model: WorkbenchAppModel
    @ObservedObject var controller: WorkbenchTopEntryController
    @ObservedObject var context: WorkbenchContextModel
    @StateObject private var agendaProjection: WorkbenchMiniAgendaProjection
    @ObservedObject var device: DeviceStatusModel
    @ObservedObject var ai: AIUsageModel
    let openedAt: Date
    let safeTop: CGFloat
    let notchWidth: CGFloat
    let open: () -> Void
    let finishConfiguration: () -> Void

    init(model: WorkbenchAppModel, controller: WorkbenchTopEntryController, openedAt: Date,
         safeTop: CGFloat, notchWidth: CGFloat, open: @escaping () -> Void,
         finishConfiguration: @escaping () -> Void) {
        self.model = model; self.controller = controller
        context = model.context; device = model.device; ai = model.ai
        _agendaProjection = StateObject(wrappedValue: WorkbenchMiniAgendaProjection(calendar: model.calendar, context: model.context))
        self.openedAt = openedAt; self.safeTop = safeTop; self.notchWidth = notchWidth
        self.open = open; self.finishConfiguration = finishConfiguration
    }

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            WorkbenchMiniPanelView(
                context: .init(context: context, now: timeline.date),
                agenda: agendaProjection.data,
                device: .init(snapshot: device.snapshot, openedAt: openedAt),
                providers: AIProvider.allCases.map { provider in
                    .init(summary: ai.providerSummaries.first { $0.provider == provider }, provider: provider, now: timeline.date, displayCalendar: context.dateContext.calendar)
                },
                sections: controller.preferences.visibleSections, safeTop: safeTop, notchWidth: notchWidth,
                error: controller.error, open: open, setVisible: controller.setMiniSection,
                restore: controller.restoreMiniSections, finishConfiguration: finishConfiguration
            )
            .onChange(of: timeline.date) { _, date in agendaProjection.update(now: date) }
        }
        .workbenchThemeEnvironment(theme: model.theme, opacity: model.opacity, backgroundMotion: false, appearance: model.appearance)
    }
}

struct WorkbenchMiniDeviceData {
    var cpu: String
    var memory: String
    var temperature: String
    var download: String
    var upload: String
    var note: String?

}

extension WorkbenchMiniDeviceData {
    init(snapshot: DeviceSnapshot, openedAt: Date) {
        let fresh = snapshot.performanceSampledAt.map { $0 >= openedAt } ?? false
        cpu = DeviceFormat.percent(fresh ? snapshot.cpuPercent : nil)
        memory = fresh && snapshot.memory != nil
            ? DeviceFormat.bytes(snapshot.memory?.used) + " / " + DeviceFormat.bytes(snapshot.memory?.total) : "—"
        temperature = DeviceFormat.temperature(fresh ? snapshot.cpuTemperature : nil)
        download = DeviceFormat.rate(fresh ? snapshot.network.downloadBytesPerSecond : nil)
        upload = DeviceFormat.rate(fresh ? snapshot.network.uploadBytesPerSecond : nil)
        note = fresh ? nil : "正在读取本机数据"
    }
}

/// The same content is used in the real nonactivating panel and hidden render
/// fixtures. There is one outer material, supplied by WorkbenchNotchSurface.
struct WorkbenchMiniPanelView: View {
    var context: WorkbenchMiniContextData
    var agenda: WorkbenchMiniAgendaData
    var device: WorkbenchMiniDeviceData
    var providers: [WorkbenchMiniAIData]
    var sections: [WorkbenchMiniSection]
    var safeTop: CGFloat
    var notchWidth: CGFloat
    var error: String?
    var open: () -> Void
    var setVisible: (WorkbenchMiniSection, Bool) -> Void
    var restore: () -> Void
    var finishConfiguration: () -> Void
    @State var configuring = false
    @State private var page = 0
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - WorkbenchMiniLayout.horizontalInset * 2
            let count = max(1, Int((width + 8) / 168))
            let pages = max(1, (sections.count + count - 1) / count)
            let currentPage = min(page, pages - 1)
            ZStack(alignment: .topLeading) {
                header(pages: pages, currentPage: currentPage)
                    .frame(width: width, height: WorkbenchMiniLayout.headerHeight)
                    .offset(x: WorkbenchMiniLayout.horizontalInset, y: WorkbenchMiniLayout.headerTop)
                Group {
                    if configuring { configuration }
                    else if sections.isEmpty { empty }
                    else {
                        HStack(spacing: 8) {
                            ForEach(Array(sections.dropFirst(currentPage * count).prefix(count))) { section in
                                sectionContent(section)
                                    .frame(width: min(168, (width - CGFloat(min(count, sections.count) - 1) * 8) / CGFloat(min(count, sections.count))),
                                           height: WorkbenchMiniLayout.sectionHeight)
                            }
                        }.frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .frame(width: width, height: WorkbenchMiniLayout.sectionHeight, alignment: .top)
                .offset(x: WorkbenchMiniLayout.horizontalInset, y: WorkbenchMiniLayout.contentTopInset(safeTop: safeTop))

            }
        }
        .foregroundStyle(palette.text)
        .onChange(of: sections) { _, _ in page = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-panel-content")
    }

    private func header(pages: Int, currentPage: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                WorkbenchBrandMark(pointSize: 18)
                Text("方寸").font(.system(size: 12, weight: .medium))
            }.accessibilityElement(children: .combine).accessibilityIdentifier("mini-brand")
            if pages > 1 && !configuring {
                HStack(spacing: 0) {
                    ForEach(0..<pages, id: \.self) { index in
                        Button { page = index } label: {
                            Circle().fill(index == currentPage ? palette.accent : palette.muted.opacity(0.45))
                                .frame(width: 4, height: 4).frame(width: 14, height: 28)
                        }.buttonStyle(.plain).clickableCursor()
                            .accessibilityLabel("第 \(index + 1) 页，共 \(pages) 页")
                            .accessibilityIdentifier("mini-page-\(index)")
                    }
                }.padding(.leading, 6)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button(action: open) {
                    HStack(spacing: 4) { Text("工作台"); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).frame(height: 28)
                        .background(palette.soft, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line, lineWidth: 1))
                }
                .buttonStyle(WBSelectableButtonStyle(cornerRadius: 8, drawsSelection: false, showsBorder: false))
                .keyboardShortcut(.return, modifiers: []).accessibilityLabel("展开完整工作台")
                .accessibilityIdentifier("mini-open-workbench")
                Button {
                    configuring.toggle()
                    if !configuring { finishConfiguration() }
                } label: {
                    Image(systemName: configuring ? "checkmark" : "slider.horizontal.3")
                        .font(.system(size: 14)).frame(width: 28, height: 28)
                }
                .buttonStyle(WBSelectableButtonStyle(cornerRadius: 8, drawsSelection: false, showsBorder: false))
                .help(configuring ? "完成配置" : "配置显示内容")
                .accessibilityLabel(configuring ? "完成配置" : "配置显示内容")
                .accessibilityIdentifier("mini-configure")
            }.fixedSize().accessibilityElement(children: .contain).accessibilityIdentifier("mini-header-actions")
        }
    }

    @ViewBuilder private func sectionContent(_ section: WorkbenchMiniSection) -> some View {
        Group {
            switch section {
            case .context: clock
            case .agenda: upcoming
            case .device: metrics
            case .ai: quotas
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-section-\(section.rawValue)")
    }

    private var clock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "globe").foregroundStyle(palette.accent)
                Text(context.city).lineLimit(1)
                Spacer(minLength: 0)
                Text(context.zone).font(.system(size: 10)).foregroundStyle(palette.muted).fixedSize()
            }.font(.system(size: 11)).frame(height: 15).help(context.zoneHelp)
            Text(context.time).font(.system(size: 30, weight: .regular)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.80).frame(height: 36, alignment: .leading)
            Text(context.date).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
            Spacer(minLength: 2)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: context.symbol).font(.system(size: 17)).foregroundStyle(palette.accent)
                Text(context.temperature).font(.system(size: 21)).monospacedDigit().lineLimit(1)
                Spacer(minLength: 0)
                Text(context.condition).font(.system(size: 11)).lineLimit(1)
            }
            if let note = context.weatherNote {
                Text(note).font(.system(size: 10)).foregroundStyle(palette.muted).lineLimit(1)
            }
        }.help(context.weatherNote ?? context.condition)
    }

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("接下来").font(.system(size: 12, weight: .medium)).frame(height: 15)
            agendaItem(agenda.event, fallback: agenda.eventStatus, symbol: "calendar")
            Rectangle().fill(palette.line).frame(height: 1)
            agendaItem(agenda.reminder, fallback: agenda.reminderStatus, symbol: "circle")
            Spacer(minLength: 0)
        }
    }
    private func agendaItem(_ item: WorkbenchMiniAgendaItem?, fallback: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let item {
                Label(item.dateText, systemImage: symbol).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                HStack(spacing: 3) {
                    Text(item.title).lineLimit(1)
                    if let note = item.note {
                        Text(note).font(.system(size: 9)).foregroundStyle(palette.warning).lineLimit(1).fixedSize()
                    }
                }.font(.system(size: 11)).help(item.title + (item.note.map { " · " + $0 } ?? ""))
            } else {
                Label(fallback, systemImage: symbol).font(.system(size: 11)).foregroundStyle(palette.muted)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(height: 37, alignment: .topLeading)
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("本机状态").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                if device.note != nil { Text("读取中").font(.system(size: 9)).foregroundStyle(palette.muted) }
            }.frame(height: 15)
            metric("CPU", device.cpu, identifier: "mini-metric-cpu")
            metric("内存", device.memory, identifier: "mini-metric-memory")
            metric("CPU 温度", device.temperature, identifier: "mini-metric-temperature")
            Rectangle().fill(palette.line).frame(height: 1)
            metric("↓ 下载", device.download, identifier: "mini-metric-download")
            metric("↑ 上传", device.upload, identifier: "mini-metric-upload")
        }.help(device.note ?? "CPU 为整机使用率；内存为已用 / 总量；温度与实时网速来自本机采样。")
    }
    private func metric(_ title: String, _ value: String, identifier: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(palette.secondary).fixedSize()
            Spacer(minLength: 0)
            Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
        }.font(.system(size: 11)).frame(height: 16).accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
    }

    private var quotas: some View {
        VStack(spacing: 7) {
            ForEach(Array(providers.enumerated()), id: \.element.provider) { index, provider in
                if index > 0 { Rectangle().fill(palette.line).frame(height: 1) }
                VStack(spacing: 3) {
                    HStack {
                        Text(provider.title).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                        Text(provider.stateText).font(.system(size: 10)).foregroundStyle(palette.muted)
                    }.frame(height: 16)
                    ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                        HStack(spacing: 5) {
                            Text(window.label).font(.system(size: 10)).foregroundStyle(palette.secondary).frame(width: 36, alignment: .leading)
                            if let fraction = window.fraction {
                                GeometryReader { geometry in
                                    Capsule().fill(palette.progressTrack)
                                    Capsule().fill(provider.isStale ? palette.muted : palette.accent)
                                        .frame(width: geometry.size.width * min(1, max(0, fraction)))
                                }.frame(height: 3)
                            } else { Spacer(minLength: 4) }
                            Text(window.value).font(.system(size: 10)).monospacedDigit().frame(minWidth: 26, alignment: .trailing)
                        }.frame(height: 14)
                    }
                }.help(provider.detail).accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mini-provider-\(provider.provider.rawValue)")
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("显示内容").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("恢复默认", action: restore).font(.system(size: 11)).buttonStyle(.plain).clickableCursor()
                    .accessibilityIdentifier("mini-restore")
            }
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 6) {
                ForEach(WorkbenchMiniSection.allCases) { section in
                    Toggle(section.title, isOn: Binding(get: { sections.contains(section) }, set: { setVisible(section, $0) }))
                        .font(.system(size: 11)).toggleStyle(.checkbox).clickableCursor()
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(palette.soft, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("mini-toggle-\(section.rawValue)")
                }
            }
            Text(error ?? "即时保存 · 日期、城市与温度单位沿用首页设置")
                .font(.system(size: 10)).foregroundStyle(error == nil ? palette.muted : palette.warning).lineLimit(2)
        }.padding(.horizontal, 4).padding(.top, 2)
    }
    private var empty: some View {
        VStack(spacing: 10) {
            Text("已隐藏全部信息").font(.system(size: 13))
            Button("配置显示内容") { configuring = true }
                .font(.system(size: 12)).buttonStyle(WBSelectableButtonStyle(cornerRadius: 8, drawsSelection: false, showsBorder: false))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension WorkbenchMiniSection {
    var title: String {
        switch self {
        case .context: "日期与天气"
        case .agenda: "日历与待办"
        case .device: "本机状态"
        case .ai: "AI 用量"
        }
    }
}
