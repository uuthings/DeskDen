import AppKit
import LauncherCore
import SwiftUI

/// The network page reads the same physical-network ledger as the device card.
/// Selecting a live interface never rewrites the scope of historical traffic.
struct NetworkMonitorView: View {
    @ObservedObject var model: DeviceStatusModel
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchModals) private var modals
    @Environment(\.workbenchDeviceExpanded) private var expanded
    @StateObject private var drafts = DeviceMonitoringDrafts()
    @State private var budgetOpen = false
    @State private var recordsOpen = false
    @State private var interfaceSheet: DeviceSheet?
    @State private var contentWidth: CGFloat = 864
    private var compact: Bool { contentWidth < 800 }
    private var summary: DeviceTrafficSummary { model.trafficSummary }
    private var today: DeviceTrafficSummary { model.trafficSummary(period: .day, scope: .all) }
    private var known: Bool { summary.coveredSeconds > 0 }
    private var percentage: Double? { known ? model.budgetProgressPercent : nil }
    private var tone: Color { (percentage ?? 0) >= 100 ? palette.critical : (percentage ?? 0) >= Double(model.budget.warningPercent) ? palette.warning : palette.success }
    private var budgetStatus: String {
        !summary.hasStarted ? "账期尚未开始" : !known ? "等待有效记录" : !model.budget.enabled ? "预算未启用" : (percentage ?? 0) >= 100 ? "已超出预算" : (percentage ?? 0) >= Double(model.budget.warningPercent) ? "接近预算" : "预算充足"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WBPageHeader(title: "网络监控", subtitle: "实时连接、今日记录与周期流量") {
                    Button { drafts.load(model); budgetOpen = true } label: { Label("流量预算", systemImage: "slider.horizontal.3") }.buttonStyle(WBButtonStyle())
                        .accessibilityIdentifier("fc.action.network.budget")
                }
                VStack(spacing: 12) {
                    liveCard
                    periodCard
                    HStack(alignment: .top, spacing: 16) {
                        Label("睡眠、退出和采集间断不补记流量；预算仅提醒，不限速。", systemImage: "info.circle")
                        Spacer(minLength: 8)
                        Text("记录时区 · \(summary.timeZoneIdentifier)")
                    }.font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                if let error = model.lastError ?? model.monitoringError {
                    Text(error).font(.system(size: 11)).foregroundStyle(palette.warning).padding(.top, 12)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in Color.clear.preference(key: NetworkContentWidth.self, value: proxy.size.width) })
                .workbenchPageCanvas()
                .background(WorkbenchOverlayScrollbars())
        }.onPreferenceChange(NetworkContentWidth.self) { contentWidth = $0 }.scrollContentBackground(.hidden).accessibilityElement(children:.contain).accessibilityIdentifier("fc.page.network")
            .task {drafts.load(model);openNotificationBudget();await model.refreshNotificationPermission()}
            .onReceive(NotificationCenter.default.publisher(for:.fangcunNotificationOpenBudget)) {note in
                guard note.object as? DeviceStatusModel === model else {return}
                openNotificationBudget()
            }
            .workbenchModal(isPresented: $budgetOpen, onRequestDismiss: { drafts.budgetCloseRequest += 1 }) { DeviceBudgetDialog(model: model, drafts: drafts) { budgetOpen = false } }
            .workbenchModal(isPresented: $recordsOpen) { NetworkRecordsDialog(model: model) { recordsOpen = false } }
            .workbenchModal(item: $interfaceSheet) { item in DeviceSheetView(item: item, model: model) { interfaceSheet = nil } }
    }

    private func openNotificationBudget() {
        guard NotificationDetailRequests.consumeBudget(for:model) else {return}
        modals?.prune()
        guard modals?.isPresented != true,!budgetOpen,!recordsOpen,interfaceSheet == nil else {return}
        drafts.load(model);budgetOpen=true
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("实时网速", systemImage: "waveform.path.ecg").font(.system(size: 12, weight: .medium))
                HStack(spacing: 5) {
                    Circle().fill(model.snapshot.network.downloadBytesPerSecond == nil ? palette.muted : palette.success).frame(width: 5, height: 5)
                    Text(model.snapshot.network.interfaceNames.isEmpty ? "未连接" : model.snapshot.network.downloadBytesPerSecond == nil ? "暂无读数" : "正在采集")
                }.font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer(minLength: 8)
                WBSelect("实时接口", selection: interfaceBinding, options: interfaceOptions).frame(width: expanded ? 180 : 155)
                    .accessibilityIdentifier("fc.field.networkInterface")
                Button { interfaceSheet = .networkOptions } label: { Image(systemName: "ellipsis") }.buttonStyle(WBIconButtonStyle()).help("管理实时网卡与本次记录")
            }.frame(height: 32)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: expanded ? 30 : compact ? 16 : 22) {
                    speedReadings.frame(width: expanded ? 180 : compact ? 112 : 138)
                    DeviceHistoryChart(points: model.history, kind: .network, minutes: 5, networkScale: true).frame(minWidth: 220, minHeight: expanded ? 180 : 144)
                    todayReadings.frame(width: expanded ? 224 : compact ? 162 : 182).padding(.leading, expanded ? 28 : compact ? 14 : 20)
                        .overlay(alignment: .leading) { palette.line.frame(width: 1) }
                }
                VStack(spacing: 14) {
                    HStack(spacing: 18) { speedReadings.frame(width: 112); DeviceHistoryChart(points: model.history, kind: .network, minutes: 5, networkScale: true).frame(height: 144) }
                    todayReadings.padding(.top, 12).overlay(alignment: .top) { palette.line.frame(height: 1) }
                }
            }
            HStack(spacing: 12) { Text("每 \(Int(model.samplingInterval)) 秒采样"); Spacer(); Text("切换实时接口不改变流量统计范围") }
                .font(.system(size: 11)).foregroundStyle(palette.muted)
        }.padding(14).background(DeviceCardSurface()).foregroundStyle(palette.text)
    }
    private var speedReadings: some View {
        VStack(alignment: .leading, spacing: 12) {
            liveSpeed("下载", symbol: "arrow.down", value: model.snapshot.network.downloadBytesPerSecond, color: palette.accent)
            liveSpeed("上传", symbol: "arrow.up", value: model.snapshot.network.uploadBytesPerSecond, color: palette.cool)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func liveSpeed(_ title: String, symbol: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(color)
            DeviceReading(value: DeviceFormat.rate(value), size: expanded ? 32 : compact ? 24 : 26)
        }
    }
    private var todayReadings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日已记录").font(.system(size: 11)).foregroundStyle(palette.secondary)
            DeviceReading(value: today.coveredSeconds > 0 ? DeviceTrafficDisplay.adaptive(today.totalBytes) : "—", size: expanded ? 36 : compact ? 28 : 30)
            transfer("下载", value: today.coveredSeconds > 0 ? today.received : nil)
            transfer("上传", value: today.coveredSeconds > 0 ? today.sent : nil)
            Text("全部物理网络 · 已采集时段").font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func transfer(_ title: String, value: UInt64?) -> some View {
        HStack(spacing: 8) { Text(title).foregroundStyle(palette.muted); Spacer(minLength: 0); Text(value.map { DeviceTrafficDisplay.adaptive($0) } ?? "暂无记录").foregroundStyle(palette.secondary) }
            .font(.system(size: 11)).monospacedDigit()
    }
    private var periodCard: some View {
        VStack(alignment: .leading, spacing: expanded ? 14 : 10) {
            HStack(spacing: 8) {
                Label("周期流量", systemImage: "calendar").font(.system(size: 12, weight: .medium))
                Text("\(model.budget.period.title) · \(DeviceTrafficDisplay.period(summary))").font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer(minLength: 8)
                Button { recordsOpen = true } label: { Label("流量历史", systemImage: "arrow.up.right") }.buttonStyle(WBButtonStyle(compact: true))
                    .accessibilityIdentifier("fc.action.network.records")
            }.frame(minHeight: 32)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: expanded ? 30 : compact ? 18 : 24) {
                    periodSummary.frame(width: expanded ? 274 : compact ? 200 : 222).padding(.trailing, expanded ? 30 : compact ? 18 : 24)
                        .overlay(alignment: .trailing) { palette.line.frame(width: 1) }
                    history.frame(minWidth: 280)
                }
                VStack(spacing: 16) { periodSummary; history }
            }
            HStack(alignment: .top, spacing: 14) {
                Label(coverageText, systemImage: "clock").fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(resetText)
            }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 10)
                .overlay(alignment: .top) { palette.line.frame(height: 1) }
        }.padding(14).background(DeviceCardSurface()).foregroundStyle(palette.text)
    }
    private var periodSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("本周期已记录").font(.system(size: 11)).foregroundStyle(palette.secondary); Spacer(minLength: 5); Text(budgetStatus).font(.system(size: 11)).foregroundStyle(known ? tone : palette.muted) }
            HStack(alignment: .firstTextBaseline) {
                DeviceReading(value: known ? DeviceTrafficDisplay.adaptive(summary.totalBytes) : "—", size: expanded ? 40 : compact ? 32 : 34)
                Spacer(minLength: 4)
                if let percentage { Text("\(percentage.formatted(.number.precision(.fractionLength(1))))% 已用").font(.system(size: 11)).foregroundStyle(tone) }
            }.padding(.vertical, expanded ? 12 : 2)
            if model.budget.enabled && known { DeviceUsageBar(value: percentage, tone: tone).frame(height: 6) }
            else { Text(summary.hasStarted ? "未采集的时段不会填为 0" : "新账期开始后记录").font(.system(size: 11)).foregroundStyle(palette.muted) }
            HStack(alignment: .top, spacing: 8) {
                Text(model.budget.enabled ? "预算 \(DeviceTrafficDisplay.budget(model.budget.limitGB))" : "预算未启用")
                Spacer(minLength: 0)
                if model.budget.enabled && known {
                    Text(model.budgetExceededBytes > 0 ? "超出 \(DeviceTrafficDisplay.adaptive(model.budgetExceededBytes))" : "剩余 \(DeviceTrafficDisplay.adaptive(model.budgetRemainingBytes ?? 0))").multilineTextAlignment(.trailing)
                }
            }.font(.system(size: 11)).foregroundStyle(palette.muted)
            VStack(spacing: 9) {
                transfer("下载", value: known ? summary.received : nil)
                transfer("上传", value: known ? summary.sent : nil)
            }.padding(.vertical, 4)
            Label(model.budget.scope.title, systemImage: "network").font(.system(size: 11)).foregroundStyle(palette.muted)
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("每日已记录流量")
                Spacer()
                legend("下载", color: palette.accent); legend("上传", color: palette.cool)
            }.font(.system(size: 11)).foregroundStyle(palette.secondary)
            NetworkDailyBars(summary: summary).frame(height: expanded ? 226 : 154)
            Text("\(DeviceTrafficDisplay.period(summary))\(summary.isActivePeriod ? " · 今日未结束" : " · 所选周期内记录") · — 未采集")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
        }
    }
    private func legend(_ title: String, color: Color) -> some View { HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7); Text(title) } }
    private var coverageText: String {
        let note = summary.omitsPartialArchivedMonth ? " · 部分旧记录已按月汇总，无法拆分到所选日期" : summary.isPartialPeriod ? " · 部分时段未采集" : ""
        return "有效采集 \(DeviceFormat.duration(summary.coveredSeconds))\(summary.includesMonthlyHistory ? " · 含较早月度汇总" : "")\(note)"
    }
    private var resetText: String { !model.budget.enabled ? "预算未开启" : model.budget.period == .custom ? "单次周期 · 不重复" : "下次重置：\(NetworkLedgerDate.resetLabel(summary.periodEnd, timeZone: summary.timeZoneIdentifier))" }
    private var interfaceBinding: Binding<String> {
        Binding(get: { guard let ids = model.selectedInterfaceIDs else { return "automatic" }; return ids.count == 1 ? ids[0] : "custom" }, set: { if $0 == "custom" { interfaceSheet = .networkOptions } else { model.setSelectedInterfaces($0 == "automatic" ? nil : [$0]) } })
    }
    private var interfaceOptions: [(value: String, title: String)] {
        var values = [(value: "automatic", title: "自动 · 物理网络")]
        if let ids = model.selectedInterfaceIDs, ids.count != 1 { values.append(("custom", "手动 · \(ids.count) 个接口")) }
        return values + model.interfaces.map { ($0.id, "\($0.name) · \($0.id)") }
    }
}

/// The modal host keeps this child alive; its own subscription refreshes the
/// ledger readings without replacing the presentation or its scroll view.
struct NetworkRecordsDialog: View {
    @ObservedObject var model: DeviceStatusModel
    let dismiss: () -> Void
    @Environment(\.workbenchPalette) private var palette
    @State private var detail: String = "day"
    private var summary: DeviceTrafficSummary { model.trafficSummary }
    private var coverageText: String {
        "有效采集 \(DeviceFormat.duration(summary.coveredSeconds))" +
        (summary.includesMonthlyHistory ? " · 周期总计含较早月度汇总" : "") +
        (summary.omitsPartialArchivedMonth ? " · 部分旧记录无法拆分到所选日期" : summary.isPartialPeriod ? " · 部分时段未采集" : "")
    }

    var body: some View {
        DeviceDialog(title: "流量历史", dismiss: dismiss) {
            HStack {
                WBSelect("历史精度", selection: $detail, options: [("day", "每日明细"), ("month", "月度汇总"), ("year", "年度汇总")]).frame(width: 126)
                    .accessibilityIdentifier("fc.network.history.granularity")
                Spacer(); Text(detail == "day" ? DeviceTrafficDisplay.period(summary) : "全部已保留历史")
                Text(model.budget.scope.title)
            }.font(.system(size: 11)).foregroundStyle(palette.muted)
            HStack { Text("日期").frame(maxWidth: .infinity, alignment: .leading); Text("下载").frame(width: 86, alignment: .trailing); Text("上传").frame(width: 86, alignment: .trailing); Text("合计").frame(width: 86, alignment: .trailing) }.font(.system(size: 11)).foregroundStyle(palette.muted)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if detail == "day" {
                    ForEach(summary.dailyUsage.filter { $0.coveredSeconds > 0 }.reversed()) { day in
                        HStack {
                            Text(NetworkLedgerDate.label(day.date, timeZone: summary.timeZoneIdentifier, includeYear: true)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(DeviceTrafficDisplay.adaptive(day.received)).frame(width: 86, alignment: .trailing)
                                .accessibilityIdentifier("network-records-received-" + String(Int(day.date.timeIntervalSince1970)))
                            Text(DeviceTrafficDisplay.adaptive(day.sent)).frame(width: 86, alignment: .trailing)
                            Text(DeviceTrafficDisplay.adaptive(day.totalBytes)).frame(width: 86, alignment: .trailing)
                        }.font(.system(size: 12)).monospacedDigit().frame(minHeight: 38).overlay(alignment: .bottom) { palette.line.frame(height: 1) }
                            .accessibilityElement(children: .contain)
                    }
                    if !summary.dailyUsage.contains(where: { $0.coveredSeconds > 0 }) { Text(summary.hasStarted ? "此周期暂无采集记录" : "账期尚未开始").font(.system(size: 12)).foregroundStyle(palette.muted).padding(.vertical, 24) }
                    } else {
                        let rows = model.trafficHistory(yearly: detail == "year")
                        ForEach(rows) { row in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.id)
                                    Text(row.isPartial ? "部分时段已记录" : "已采集时段").font(.system(size: 10)).foregroundStyle(palette.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(row.coveredSeconds > 0 ? DeviceTrafficDisplay.adaptive(row.received) : "—").frame(width: 86, alignment: .trailing)
                                Text(row.coveredSeconds > 0 ? DeviceTrafficDisplay.adaptive(row.sent) : "—").frame(width: 86, alignment: .trailing)
                                Text(row.coveredSeconds > 0 ? DeviceTrafficDisplay.adaptive(row.totalBytes) : "—").frame(width: 86, alignment: .trailing)
                            }.font(.system(size: 12)).monospacedDigit().frame(minHeight: 44)
                                .overlay(alignment: .bottom) { palette.line.frame(height: 1) }
                        }
                        if rows.isEmpty { Text("尚无汇总记录").font(.system(size: 12)).foregroundStyle(palette.muted).padding(.vertical, 24) }
                    }
                }.background(WorkbenchOverlayScrollbars())
            }.frame(maxHeight: 300)
            Text(detail == "day" ? "\(coverageText)。未列出的日期不代表零流量；较早日期可查看月度或年度汇总。记录时区：\(summary.timeZoneIdentifier)。" : "保留最近 400 个记录日，较早数据合并为最多 120 个月汇总；年度数据由现有日／月记录合计。旧版已经丢弃的记录无法恢复，未采集时段不补算。记录时区：\(summary.timeZoneIdentifier)。")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
                .accessibilityIdentifier("network-records-coverage")
        } actions: { Button("完成", action: dismiss).buttonStyle(WBButtonStyle(primary: true)).keyboardShortcut(.defaultAction) }
    }
}

private struct NetworkBarBoundsKey: PreferenceKey {
    static let defaultValue: [Date: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Date: Anchor<CGRect>], nextValue: () -> [Date: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct NetworkDailyBars: View {
    let summary: DeviceTrafficSummary
    @Environment(\.workbenchPalette) private var palette
    @State private var selectedDate: Date?
    @State private var hoveredDate: Date?
    @FocusState private var focusedDate: Date?
    private var activeDate: Date? { hoveredDate ?? focusedDate ?? selectedDate }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: summary.timeZoneIdentifier) ?? .current; return c }
    private var dates: [Date] {
        let last = calendar.startOfDay(for: min(summary.measuredAt, summary.periodEnd.addingTimeInterval(-1)))
        let start = max(calendar.startOfDay(for: summary.periodStart), calendar.date(byAdding: .day, value: -13, to: last) ?? last)
        guard start <= last else { return [] }
        return (0..<14).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.filter { $0 <= last }
    }
    private func record(_ date: Date) -> DeviceTrafficDay? { summary.dailyUsage.first { calendar.isDate($0.date, inSameDayAs: date) && $0.coveredSeconds > 0 } }
    var body: some View {
        let maximumBytes = max(UInt64(1), dates.compactMap { record($0) }.map(\.totalBytes).max() ?? 0)
        let maximum = Double(maximumBytes)
        let maximumLabel = axisLabel(maximumBytes)
        let axisWidth = DeviceChartAxisMetrics.width(for: [maximumLabel, "0"], minimum: 32)
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .trailing) {
                Text(maximumLabel).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer()
                Text("0").lineLimit(1)
            }.font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.muted).frame(width: axisWidth, alignment: .trailing).padding(.bottom, 23)
            GeometryReader { plot in
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(dates, id: \.self) { date in
                        let day = record(date)
                        VStack(spacing: 7) {
                            Button { selectedDate = selectedDate == date ? nil : date } label: {
                                GeometryReader { geometry in
                                    VStack(spacing: 0) {
                                        Spacer(minLength: 0)
                                        if let day {
                                            VStack(spacing: 0) {
                                                palette.accent.opacity(activeDate == date ? 1 : 0.76)
                                                    .frame(height: max(0, geometry.size.height * Double(day.received) / maximum))
                                                palette.cool.frame(height: max(0, geometry.size.height * Double(day.sent) / maximum))
                                                if day.totalBytes == 0 { palette.accent.frame(height: 2) }
                                            }.frame(maxWidth: 36).clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                                                .anchorPreference(key: NetworkBarBoundsKey.self, value: .bounds) { [date: $0] }
                                        } else {
                                            Text("—").font(.system(size: 13)).foregroundStyle(palette.muted).frame(height: 14)
                                                .anchorPreference(key: NetworkBarBoundsKey.self, value: .bounds) { [date: $0] }
                                        }
                                    }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                                }
                            }.buttonStyle(ClickablePlainButtonStyle()).focused($focusedDate, equals: date)
                                .accessibilityLabel(detail(date, day: day)).accessibilityValue(activeDate == date ? "正在显示明细" : "")
                                .accessibilityIdentifier("fc.network.day-bar." + String(Int(date.timeIntervalSince1970)))
                            HStack(spacing: 3) {
                                Text("\(calendar.component(.day, from: date))").lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                if calendar.isDate(date, inSameDayAs: summary.measuredAt) { Circle().fill(palette.accent).frame(width: 4, height: 4) }
                            }.font(.system(size: 11, weight: activeDate == date ? .semibold : .regular)).foregroundStyle(activeDate == date ? palette.text : palette.muted)
                                .fixedSize(horizontal: true, vertical: false)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("fc.network.day-label." + NetworkLedgerDate.label(date, timeZone: summary.timeZoneIdentifier))
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if dates.isEmpty { Text(summary.hasStarted ? "此周期暂无采集记录" : "账期尚未开始").font(.system(size: 12)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.contentShape(Rectangle()).overlayPreferenceValue(NetworkBarBoundsKey.self) { anchors in
                    GeometryReader { geometry in
                        if let date = activeDate, let anchor = anchors[date] {
                            let bounds = geometry[anchor]
                            WBChartCallout(anchor: bounds, canvas: geometry.size,
                                size: CGSize(width: 218, height: record(date) == nil ? 68 : 112)) {
                                tip(date, day: record(date))
                                    .accessibilityIdentifier("fc.network.day-tooltip")
                            }
                        }
                    }.allowsHitTesting(false)
                }.onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        guard !dates.isEmpty, plot.size.width > 0 else { hoveredDate = nil; return }
                        let columnWidth = max(1, (plot.size.width - CGFloat(dates.count - 1) * 10) / CGFloat(dates.count))
                        let index = min(dates.count - 1, max(0, Int((point.x + 5) / (columnWidth + 10))))
                        let date = dates[index]
                        if hoveredDate != date { hoveredDate = date }
                    case .ended: hoveredDate = nil
                    }
                }.onExitCommand { selectedDate = nil; focusedDate = nil }
            }
        }
    }
    private func tip(_ date: Date, day: DeviceTrafficDay?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(NetworkLedgerDate.label(date, timeZone: summary.timeZoneIdentifier)).font(.system(size: 12, weight: .medium))
            if let day {
                DeviceFact(label: "下载", value: DeviceTrafficDisplay.adaptive(day.received))
                DeviceFact(label: "上传", value: DeviceTrafficDisplay.adaptive(day.sent))
                DeviceFact(label: "合计", value: DeviceTrafficDisplay.adaptive(day.totalBytes))
            } else { Text("未采集，不代表零流量。").font(.system(size: 11)).foregroundStyle(palette.secondary) }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(palette.text)
    }
    /// Axis ticks need less precision than the actual totals and hover details.
    /// Decimal units stay consistent with the traffic ledger and budget.
    private func axisLabel(_ bytes: UInt64) -> String {
        var value = Double(bytes), unit = 0
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
        var text = String(format: value >= 100 ? "%.0f" : "%.1f", value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text + " " + units[unit]
    }
    private func detail(_ date: Date, day: DeviceTrafficDay?) -> String {
        let label = NetworkLedgerDate.label(date, timeZone: summary.timeZoneIdentifier)
        return day.map { "\(label) · 下载 \(DeviceTrafficDisplay.adaptive($0.received)) · 上传 \(DeviceTrafficDisplay.adaptive($0.sent)) · 合计 \(DeviceTrafficDisplay.adaptive($0.totalBytes))" } ?? "\(label) · 未采集，不代表零流量"
    }
}
/// Anchors to the selected column's real painted top, then keeps the tooltip
/// within the chart canvas. It never uses the tallest column as a shared anchor.
enum NetworkTrafficTooltipPlacement {
    static func frame(anchor: CGRect, canvas: CGSize, size: CGSize) -> CGRect {
        WBChartCalloutPlacement(anchor: anchor, canvas: canvas, size: size).frame
    }
}

private enum NetworkLedgerDate {
    static func label(_ date: Date, timeZone: String, includeYear: Bool = false) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = TimeZone(identifier: timeZone) ?? .current; formatter.dateFormat = includeYear ? "yyyy/M/d" : "M 月 d 日"; return formatter.string(from: date)
    }
    static func resetLabel(_ date: Date, timeZone: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = TimeZone(identifier: timeZone) ?? .current; formatter.dateFormat = "M 月 d 日 HH:mm"; return formatter.string(from: date)
    }
}

private struct NetworkContentWidth: PreferenceKey {
    static let defaultValue: CGFloat = 864
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct DeviceDialog<Content: View, Actions: View>: View {
    let title: String
    var width: CGFloat = 470
    let dismiss: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(title).font(.system(size: 14, weight: .medium)); Spacer(); Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(WBIconButtonStyle()).accessibilityLabel("关闭") }.padding(18)
            VStack(alignment: .leading, spacing: 16) { content }.padding(.horizontal, 18).padding(.bottom, 18)
            HStack(spacing: 8) { Spacer(); actions }.padding(.horizontal, 18).padding(.vertical, 13).overlay(alignment: .top) { palette.line.frame(height: 1) }
        }.frame(width: width).foregroundStyle(palette.text)
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

/// Separate draft and explicit save keep sampling from replacing active input.
struct DeviceBudgetDialog: View {
    @ObservedObject var model: DeviceStatusModel
    @ObservedObject var drafts: DeviceMonitoringDrafts
    let dismiss: () -> Void
    @Environment(\.workbenchPalette) private var palette
    @State private var discard = false
    var body: some View {
        DeviceDialog(title: "流量预算", dismiss: close) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("启用流量预算").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                            Text("按选定周期记录，接近额度时提醒").font(.system(size: 11)).foregroundStyle(palette.muted)
                        }
                        Spacer(minLength: 12)
                        Toggle("启用流量预算", isOn: $drafts.budget.enabled)
                            .labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.mini).fixedSize().tint(palette.accent)
                            .disabled(drafts.savingBudget).accessibilityIdentifier("fc.network.budget.enabled")
                    }.frame(maxWidth: .infinity, minHeight: 32)
                    Group {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionTitle("周期与额度")
                            HStack(alignment: .top, spacing: 12) {
                                DeviceRuleField("统计周期") { WBSelect("统计周期", selection: $drafts.budget.period, options: DeviceBudgetPeriod.allCases.map { ($0, $0.title) }) }
                                DeviceRuleNumberField(title: "可用额度", value: $drafts.budget.limit, unit: "GB", error: drafts.budgetErrors["limit"])
                            }
                            if drafts.budget.period.supportsAnchor {
                                Toggle("自定义账期起点", isOn: $drafts.budget.usesAnchor).clickableCursor().font(.system(size: 12))
                                if drafts.budget.usesAnchor {
                                    dateField("账期起算日", value: $drafts.budget.anchor)
                                    Text("按该日期重复计算账期；月份天数不足时采用月末。").font(.system(size: 11)).foregroundStyle(palette.muted)
                                }
                            } else if drafts.budget.period == .custom {
                                dateField("开始日期", value: $drafts.budget.customStart)
                                dateField("结束日期 · 包含当天", value: $drafts.budget.customEnd)
                            }
                            if let error = drafts.budgetErrors["dates"] { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning) }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            sectionTitle("范围与提醒")
                            HStack(alignment: .top, spacing: 12) {
                                DeviceRuleField("统计范围") { WBSelect("统计范围", selection: $drafts.budget.scope, options: DeviceTrafficScope.allCases.map { ($0, $0.title) }) }
                                DeviceRuleNumberField(title: "接近额度时提醒", value: $drafts.budget.warning, unit: "%", error: drafts.budgetErrors["warning"])
                            }
                            Toggle("发送系统通知", isOn: $drafts.budget.notifications).clickableCursor().font(.system(size: 12))
                        }
                        let preview = model.trafficPreview(drafts.budget.rule(from: model.budget))
                        VStack(alignment: .leading, spacing: 7) {
                            Text("当前账期").font(.system(size: 11)).foregroundStyle(palette.muted)
                            Text(DeviceTrafficDisplay.period(preview, includeYear: true)).font(.system(size: 12, weight: .medium))
                            Text("记录时区 · \(preview.timeZoneIdentifier)").font(.system(size: 11)).foregroundStyle(palette.muted)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(palette.soft, in: RoundedRectangle(cornerRadius: 8))
                    }.disabled(!drafts.budget.enabled || drafts.savingBudget)
                    Text("预算仅提醒，不会限速或断网。保存后再申请通知权限，未采集的时段不补记流量。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                    if drafts.budgetStatus != "已保存" { Text(drafts.budgetStatus).font(.system(size: 11)).foregroundStyle(palette.warning) }
                }.background(WorkbenchOverlayScrollbars())
            }.frame(maxHeight: 470)
        } actions: {
            Button("取消", action: close).buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
            Button("保存预算") { Task { await drafts.saveBudget(model); if !drafts.budgetDirty && drafts.budgetErrors.isEmpty { dismiss() } } }.buttonStyle(WBButtonStyle(primary: true)).disabled(drafts.savingBudget).keyboardShortcut(.defaultAction)
        }.onAppear { drafts.load(model) }
            .onChange(of: drafts.budgetCloseRequest) { _, _ in close() }
            .workbenchModal(isPresented: $discard) {
                    DeviceDialog(title: "放弃未保存的修改？", dismiss: { discard = false }) {
                        Text("你的修改尚未保存，关闭后将恢复之前的内容。").font(.system(size: 12)).foregroundStyle(palette.secondary)
                    } actions: {
                        Button("继续编辑") { discard = false }.buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
                        Button("放弃修改") { drafts.restoreBudget(model); discard = false; dismiss() }.buttonStyle(WBButtonStyle())
                    }
            }
    }
    private func close() { guard !drafts.savingBudget else { return }; if drafts.budgetDirty { discard = true } else { dismiss() } }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
    }
    private func dateField(_ title: String, value: Binding<Date>) -> some View {
        let calendar = drafts.budget.calendar
        let year = calendar.component(.year, from: value.wrappedValue)
        let currentYear = calendar.component(.year, from: Date())
        let yearOptions = Array(Set(Array((currentYear - 30)...(currentYear + 30)) + [year])).sorted().map { ($0, "\($0) 年") }
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: value.wrappedValue)) ?? value.wrappedValue
        let days = calendar.range(of: .day, in: .month, for: monthStart) ?? 1..<29
        return DeviceRuleField(title) {
            HStack(spacing: 8) {
                WBSelect(title + "年份", selection: datePart(.year, value: value), options: yearOptions)
                WBSelect(title + "月份", selection: datePart(.month, value: value), options: (1...12).map { ($0, "\($0) 月") })
                WBSelect(title + "日期", selection: datePart(.day, value: value), options: days.map { ($0, "\($0) 日") })
            }.accessibilityElement(children: .contain).accessibilityIdentifier("fc.network.budget.date." + title)
        }
    }
    private func datePart(_ component: Calendar.Component, value: Binding<Date>) -> Binding<Int> {
        Binding(get: { drafts.budget.calendar.component(component, from: value.wrappedValue) }, set: { number in
            value.wrappedValue = NetworkBudgetDateSelection.replacing(component, with: number, in: value.wrappedValue, calendar: drafts.budget.calendar)
        })
    }
}

/// Component selection preserves the ledger timezone and clamps invalid days
/// on month/year changes, instead of silently overflowing into the next month.
enum NetworkBudgetDateSelection {
    static func replacing(_ component: Calendar.Component, with number: Int, in date: Date, calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        switch component {
        case .year: parts.year = number
        case .month: parts.month = number
        case .day: parts.day = number
        default: return date
        }
        guard let year = parts.year, let month = parts.month, (1...12).contains(month),
              let first = calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return date }
        parts.day = min(max(parts.day ?? 1, range.lowerBound), range.upperBound - 1)
        parts.hour = 12
        return calendar.date(from: parts) ?? date
    }
}

struct DeviceTemperatureDialog: View {
    @ObservedObject var model: DeviceStatusModel
    @ObservedObject var drafts: DeviceMonitoringDrafts
    let dismiss: () -> Void
    @Environment(\.workbenchPalette) private var palette
    @State private var discard = false
    var body: some View {
        DeviceDialog(title: "温度提醒", dismiss: close) {
            Toggle("启用温度提醒", isOn: $drafts.temperature.enabled).toggleStyle(.switch).clickableCursor().disabled(drafts.savingTemperature)
            Group {
            HStack(spacing: 12) {
                DeviceRuleNumberField(title: "CPU 阈值", value: $drafts.temperature.cpu, unit: "°C", error: drafts.temperatureErrors["cpu"])
                DeviceRuleNumberField(title: "GPU 阈值", value: $drafts.temperature.gpu, unit: "°C", error: drafts.temperatureErrors["gpu"])
            }
            HStack(spacing: 12) {
                DeviceRuleNumberField(title: "连续超温", value: $drafts.temperature.duration, unit: "秒", error: drafts.temperatureErrors["duration"])
                DeviceRuleNumberField(title: "提醒冷却", value: $drafts.temperature.cooldown, unit: "分钟", error: drafts.temperatureErrors["cooldown"])
            }
            Label("CPU 与 GPU 分别判断。缺失读数会中断计时，恢复正常后才允许再次触发。温度提醒不控制风扇。", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(10).background(palette.soft, in: RoundedRectangle(cornerRadius: 8))
            Toggle("系统通知", isOn: $drafts.temperature.notifications).clickableCursor().font(.system(size: 12))
            }.disabled(!drafts.temperature.enabled || drafts.savingTemperature)
            if drafts.temperatureStatus != "已保存" { Text(drafts.temperatureStatus).font(.system(size: 11)).foregroundStyle(palette.warning) }
        } actions: {
            Button("取消", action: close).buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
            Button("保存提醒") { Task { await drafts.saveTemperature(model); if !drafts.temperatureDirty && drafts.temperatureErrors.isEmpty { dismiss() } } }
                .buttonStyle(WBButtonStyle(primary: true)).disabled(drafts.savingTemperature).keyboardShortcut(.defaultAction)
        }.onAppear { drafts.load(model) }
            .onChange(of: drafts.temperatureCloseRequest) { _, _ in close() }
            .workbenchModal(isPresented: $discard) {
                    DeviceDialog(title: "放弃未保存的修改？", dismiss: { discard = false }) {
                        Text("你的修改尚未保存，关闭后将恢复之前的内容。").font(.system(size: 12)).foregroundStyle(palette.secondary)
                    } actions: {
                        Button("继续编辑") { discard = false }.buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
                        Button("放弃修改") { drafts.restoreTemperature(model); discard = false; dismiss() }.buttonStyle(WBButtonStyle())
                    }
            }
    }
    private func close() { guard !drafts.savingTemperature else { return }; if drafts.temperatureDirty { discard = true } else { dismiss() } }
}
