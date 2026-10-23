import AppKit
import SwiftUI
import LauncherCore

/// Unsaved form values stay separate from active monitoring rules and survive detail/tab/size changes.
struct DeviceBudgetDraft: Equatable {
    var enabled = false
    var period: DeviceBudgetPeriod = .month
    var scope: DeviceTrafficScope = .all
    var limit = "100"
    var warning = "80"
    var notifications = true
    var usesAnchor = false
    var anchor = Date()
    var customStart = Date()
    var customEnd = Date()
    var timeZoneIdentifier = TimeZone.current.identifier
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4
        return value
    }

    init() { }
    init(_ value: DeviceTrafficBudget, timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.timeZoneIdentifier = timeZoneIdentifier
        enabled = value.enabled; period = value.period; scope = value.scope
        limit = Self.numberText(value.limitGB)
        warning = String(value.warningPercent); notifications = value.notificationsEnabled
        usesAnchor = value.cycleAnchor != nil
        let month = calendar.dateInterval(of: .month, for: Date())!
        anchor = value.cycleAnchor?.date(in: calendar) ?? month.start
        customStart = value.customStart?.date(in: calendar) ?? month.start
        customEnd = value.customEndInclusive?.date(in: calendar) ?? calendar.date(byAdding: .day, value: -1, to: month.end)!
    }
    var errors: [String: String] {
        guard enabled else { return [:] }
        var result: [String: String] = [:]
        if let value = Self.number(limit), value.isFinite, (0.01...100_000).contains(value) { } else { result["limit"] = "请输入 0.01–100,000 GB 的额度。" }
        if let value = Int(warning), (1...99).contains(value) { } else { result["warning"] = "请输入 1–99 的整数比例。" }
        if period == .custom && calendar.startOfDay(for: customEnd) < calendar.startOfDay(for: customStart) {
            result["dates"] = "结束日期不能早于开始日期。"
        }
        return result
    }
    func rule(from saved: DeviceTrafficBudget) -> DeviceTrafficBudget {
        var value = saved; value.enabled = enabled
        if enabled {
            value.period = period; value.scope = scope; value.limitGB = Self.number(limit) ?? saved.limitGB
            value.warningPercent = Int(warning) ?? saved.warningPercent; value.notificationsEnabled = notifications
            value.cycleAnchor = usesAnchor ? DeviceBudgetDate(anchor, calendar: calendar) : nil
            value.customStart = DeviceBudgetDate(customStart, calendar: calendar)
            value.customEndInclusive = DeviceBudgetDate(customEnd, calendar: calendar)
        }
        return value
    }
    static func numberText(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(value)
    }
    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = Locale.current.decimalSeparator ?? "."
        let normalized = separator == "." ? trimmed : trimmed.replacingOccurrences(of: separator, with: ".")
        // Double parses the whole string. NumberFormatter may silently accept a numeric prefix.
        return Double(normalized)
    }
}

struct DeviceTemperatureDraft: Equatable {
    var enabled = false
    var cpu = "90"
    var gpu = "85"
    var duration = "30"
    var cooldown = "15"
    var notifications = true
    init() { }
    init(_ value: DeviceTemperatureRule) {
        enabled = value.enabled
        cpu = DeviceBudgetDraft.numberText(value.cpuThreshold)
        gpu = DeviceBudgetDraft.numberText(value.gpuThreshold)
        duration = String(value.sustainedSeconds); cooldown = String(value.cooldownMinutes)
        notifications = value.notificationsEnabled
    }
    var errors: [String: String] {
        guard enabled else { return [:] }
        var result: [String: String] = [:]
        for (key, text) in [("cpu", cpu), ("gpu", gpu)] {
            if let value = DeviceBudgetDraft.number(text), value.isFinite, (40...110).contains(value) { } else { result[key] = "请输入 40–110°C 的温度。" }
        }
        if let value = Int(duration), (5...3600).contains(value) { } else { result["duration"] = "请输入 5–3,600 秒的整数时长。" }
        if let value = Int(cooldown), (1...1440).contains(value) { } else { result["cooldown"] = "请输入 1–1,440 分钟的整数时长。" }
        return result
    }
    func rule(from saved: DeviceTemperatureRule) -> DeviceTemperatureRule {
        var value = saved; value.enabled = enabled
        if enabled {
            value.cpuThreshold = DeviceBudgetDraft.number(cpu) ?? saved.cpuThreshold
            value.gpuThreshold = DeviceBudgetDraft.number(gpu) ?? saved.gpuThreshold
            value.sustainedSeconds = Int(duration) ?? saved.sustainedSeconds
            value.cooldownMinutes = Int(cooldown) ?? saved.cooldownMinutes
            value.notificationsEnabled = notifications
        }
        return value
    }
}

@MainActor final class DeviceMonitoringDrafts: ObservableObject {
    @Published var budget = DeviceBudgetDraft()
    @Published var temperature = DeviceTemperatureDraft()
    @Published var budgetErrors: [String: String] = [:]
    @Published var temperatureErrors: [String: String] = [:]
    @Published var budgetStatus = "已保存"
    @Published var temperatureStatus = "已保存"
    @Published var savingBudget = false
    @Published var savingTemperature = false
    @Published var budgetCloseRequest = 0
    @Published var temperatureCloseRequest = 0
    private(set) var loaded = false
    private var savedBudget = DeviceBudgetDraft()
    private var savedTemperature = DeviceTemperatureDraft()
    var budgetDirty: Bool { budget != savedBudget }
    var temperatureDirty: Bool { temperature != savedTemperature }

    func load(_ model: DeviceStatusModel) {
        guard !loaded else { return }; loaded = true
        restoreBudget(model); restoreTemperature(model)
    }
    func restoreBudget(_ model: DeviceStatusModel) {
        budget = DeviceBudgetDraft(model.budget, timeZoneIdentifier: model.trafficSummary.timeZoneIdentifier); savedBudget = budget
        budgetErrors = [:]; budgetStatus = "已保存"
    }
    func restoreTemperature(_ model: DeviceStatusModel) {
        temperature = DeviceTemperatureDraft(model.temperatureRule); savedTemperature = temperature
        temperatureErrors = [:]; temperatureStatus = "已保存"
    }
    func saveBudget(_ model: DeviceStatusModel) async {
        guard !savingBudget else { return }
        budgetErrors = budget.errors
        guard budgetErrors.isEmpty else { budgetStatus = "请检查标出的设置"; return }
        savingBudget = true; defer { savingBudget = false }
        if await model.saveBudget(budget.rule(from: model.budget)) { restoreBudget(model); budgetStatus = "设置已保存" }
        else { budgetStatus = model.monitoringError ?? "保存失败，请重试。" }
    }
    func saveTemperature(_ model: DeviceStatusModel) async {
        guard !savingTemperature else { return }
        temperatureErrors = temperature.errors
        guard temperatureErrors.isEmpty else { temperatureStatus = "请检查标出的设置"; return }
        savingTemperature = true; defer { savingTemperature = false }
        if await model.saveTemperatureRule(temperature.rule(from: model.temperatureRule)) { restoreTemperature(model); temperatureStatus = "设置已保存" }
        else { temperatureStatus = model.monitoringError ?? "保存失败，请重试。" }
    }
}

struct DeviceBudgetSettingsView: View {
    @Environment(\.workbenchPalette) private var palette
    @ObservedObject var model: DeviceStatusModel
    @ObservedObject var drafts: DeviceMonitoringDrafts
    var body: some View {
        DevicePanel {
            budgetHeader
            budgetInputs
            cycleEditor.disabled(!drafts.budget.enabled)
            periodPreview
            notificationToggle
            coverageHelp
            limitHelp
            formActions
        }.disabled(drafts.savingBudget).accessibilityIdentifier("device-budget-settings")
    }
    private var budgetHeader: some View {
        HStack {
                Label("流量预算", systemImage: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle("启用流量预算", isOn: $drafts.budget.enabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).fixedSize()
                    .accessibilityIdentifier("fc.network.budget.settings.enabled")
            }
    }
    private var budgetInputs: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 12) {
                DeviceRuleField("统计周期") {
                    WBSelect("统计周期", selection: $drafts.budget.period, options: DeviceBudgetPeriod.allCases.map { (value: $0, title: $0.title) })
                }
                DeviceRuleNumberField(title: "周期额度", value: $drafts.budget.limit, unit: "GB", error: drafts.budgetErrors["limit"])
                DeviceRuleField("统计范围") {
                    WBSelect("统计范围", selection: $drafts.budget.scope, options: DeviceTrafficScope.allCases.map { (value: $0, title: $0.title) })
                }
                DeviceRuleNumberField(title: "接近额度时提示", value: $drafts.budget.warning, unit: "%", error: drafts.budgetErrors["warning"])
            }.disabled(!drafts.budget.enabled)
    }
    @ViewBuilder private var periodPreview: some View {
        if drafts.budget.enabled, drafts.budget.errors["dates"] == nil {
                let summary = model.trafficPreview(drafts.budget.rule(from: model.budget))
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(drafts.budget.period == .custom ? "所选期间" : "当前账期").foregroundStyle(palette.secondary)
                        Spacer()
                        Text(DeviceTrafficDisplay.period(summary, includeYear: true)).monospacedDigit()
                    }.font(.system(size: 11))
                    Text(summary.hasStarted ? (summary.isActivePeriod ? (drafts.budget.period == .custom ? "包含结束日期当天。\n次日 00:00 结束统计，不自动重复。" : "结束日期当天计入。\n次日 00:00 进入下一周期。") : "此期间已结束，保留已记录的统计。\n不再发送额度提醒。") : "此期间尚未开始。\n开始日期 00:00 起计入统计。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                }.padding(10).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            }
    }
    private var notificationToggle: some View {
        Toggle("达到提示比例或额度时发送通知", isOn: $drafts.budget.notifications)
                .font(.system(size: 12)).disabled(!drafts.budget.enabled)
    }
    private var coverageHelp: some View {
        DeviceRuleHelp(text: drafts.budget.enabled ? "按记录时区 \(model.trafficSummary.timeZoneIdentifier) 统计。\n达到提示比例变为黄色，达到额度变为红色。" : "预算已关闭，流量采集与统计继续保留。")
    }
    private var limitHelp: some View {
        DeviceRuleHelp(text: "仅提醒，不自动限速或断网。1 GB = 1,000,000,000 字节。")
    }
    private var formActions: some View {
        DeviceRuleActions(dirty: drafts.budgetDirty, saving: drafts.savingBudget, status: drafts.budgetStatus,
                              cancel: { drafts.restoreBudget(model) }, save: { Task { await drafts.saveBudget(model) } })
    }
    #if DEBUG
    var sizingPartsForChecks: [(String, AnyView)] {
        [("header", AnyView(budgetHeader)), ("inputs", AnyView(budgetInputs)), ("dates", AnyView(cycleEditor)),
         ("period", AnyView(periodPreview)), ("notify", AnyView(notificationToggle)), ("coverage", AnyView(coverageHelp)),
         ("limit", AnyView(limitHelp)), ("actions", AnyView(formActions))]
    }
    #endif
    @ViewBuilder private var cycleEditor: some View {
        if drafts.budget.period.supportsAnchor {
            Toggle("自定义账期起点", isOn: $drafts.budget.usesAnchor).font(.system(size: 12))
            if drafts.budget.usesAnchor {
                DeviceRuleField("参考起算日") { dateField("参考起算日", value: $drafts.budget.anchor) }
                DeviceRuleHelp(text: "按参考日期的日号循环。\n每季间隔 3 个月，每年间隔 12 个月。\n该月无对应日期时取月末，下期恢复原日号。")
            }
        } else if drafts.budget.period == .custom {
            // Date fields remain stacked so their native intrinsic widths never widen
            // the narrow detail column. Both dates retain the standard 32 pt control height.
            VStack(alignment: .leading, spacing: 12) { customStartField; customEndField }
            if let error = drafts.budgetErrors["dates"] {
                Text(error).font(.system(size: 11)).foregroundStyle(palette.warning)
            }
            DeviceRuleHelp(text: "自定义日期为单次期间，不自动重复。\n结束日期当天的采集计入该期间。")
        }
    }
    private var customStartField: some View {
        DeviceRuleField("开始日期") { dateField("开始日期", value: $drafts.budget.customStart) }
    }
    private var customEndField: some View {
        DeviceRuleField("结束日期（含当天）") { dateField("结束日期", value: $drafts.budget.customEnd) }
    }
    private func dateField(_ title: String, value: Binding<Date>) -> some View {
        DatePicker(title, selection: value, displayedComponents: .date).labelsHidden()
            .environment(\.timeZone, drafts.budget.calendar.timeZone)
            .environment(\.calendar, drafts.budget.calendar)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).frame(height: 32)
            .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.controlBorder, lineWidth: 1))
            .accessibilityLabel(title)
    }
}

struct DeviceTemperatureSettingsView: View {
    @Environment(\.workbenchPalette) private var palette
    @ObservedObject var model: DeviceStatusModel
    @ObservedObject var drafts: DeviceMonitoringDrafts
    var body: some View {
        DevicePanel {
            HStack {
                Label("温度提醒", systemImage: "bell").font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle("启用提醒", isOn: $drafts.temperature.enabled).toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 16) {
                DeviceRuleNumberField(title: "CPU 温度阈值", value: $drafts.temperature.cpu, unit: "°C", error: drafts.temperatureErrors["cpu"])
                DeviceRuleNumberField(title: "GPU 温度阈值", value: $drafts.temperature.gpu, unit: "°C", error: drafts.temperatureErrors["gpu"])
                DeviceRuleNumberField(title: "持续超过阈值", value: $drafts.temperature.duration, unit: "秒", error: drafts.temperatureErrors["duration"])
                DeviceRuleNumberField(title: "提醒冷却时间", value: $drafts.temperature.cooldown, unit: "分钟", error: drafts.temperatureErrors["cooldown"])
            }.disabled(!drafts.temperature.enabled)
            Toggle("满足条件时发送系统通知", isOn: $drafts.temperature.notifications)
                .font(.system(size: 12)).disabled(!drafts.temperature.enabled)
            DeviceRuleHelp(text: drafts.temperature.enabled ? "任一温度持续超阈值后提醒；短暂升温不提醒。恢复正常后重新计时，同一项在冷却期内不重复提醒。" : "提醒已关闭，温度监测继续保留。")
            DeviceRuleHelp(text: "仅使用实际传感器读数。缺少读数时暂停该项判断，不以 0 或旧读数代替。")
            DeviceRuleActions(dirty: drafts.temperatureDirty, saving: drafts.savingTemperature, status: drafts.temperatureStatus,
                              cancel: { drafts.restoreTemperature(model) }, save: { Task { await drafts.saveTemperature(model) } })
        }.disabled(drafts.savingTemperature).accessibilityIdentifier("device-temperature-settings")
    }
}

struct DeviceNotificationStatusView: View {
    @Environment(\.workbenchPalette) private var palette
    @ObservedObject var model: DeviceStatusModel
    var body: some View {
        DevicePanel {
            HStack {
                Label("系统通知", systemImage: "bell.badge").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(model.notificationPermission.title).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            DeviceRuleHelp(text: "保存并启用通知时才会申请授权。通知关闭或被拒绝不会停止数据采集，也不会影响卡片上的状态颜色。")
            HStack {
                if model.notificationPermission == .denied {
                    Button("打开通知设置") { openSettings() }.buttonStyle(WBButtonStyle(compact: true))
                } else if model.notificationPermission == .notDetermined {
                    Button("允许系统通知") { Task { await model.requestNotificationPermission() } }.buttonStyle(WBButtonStyle(compact: true))
                }
                Button("检查权限状态") { Task { await model.refreshNotificationPermission() } }.buttonStyle(WBButtonStyle(compact: true))
                Spacer()
            }
            if let error = model.monitoringError {
                Text(error).font(.system(size: 11)).foregroundStyle(palette.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct DeviceRuleField<Content: View>: View {
    @Environment(\.workbenchPalette) private var palette
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary)
            content.font(.system(size: 12)).frame(height: 32)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct DeviceRuleNumberField: View {
    @Environment(\.workbenchPalette) private var palette
    let title: String
    @Binding var value: String
    let unit: String
    var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DeviceRuleField(title) {
                HStack(spacing: 6) {
                    TextField(title, text: $value).textFieldStyle(.plain).monospacedDigit().accessibilityLabel(title)
                    Text(unit).foregroundStyle(palette.muted).fixedSize()
                }.padding(.horizontal, 10).frame(height: 32)
                    .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(error == nil ? palette.controlBorder : palette.warning.opacity(0.7), lineWidth: 1))
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(palette.warning).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct DeviceRuleHelp: View {
    @Environment(\.workbenchPalette) private var palette
    let text: String
    var notice = false
    var body: some View {
        if notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 14)).padding(.top, 1).accessibilityHidden(true)
                Text(text).font(.system(size: 11)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.foregroundStyle(palette.secondary).padding(.vertical, 10).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.soft, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
        } else {
            Text(text).font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}
struct DeviceRuleActions: View {
    @Environment(\.workbenchPalette) private var palette
    let dirty: Bool
    let saving: Bool
    let status: String
    let cancel: () -> Void
    let save: () -> Void
    static func statusText(dirty: Bool, saving: Bool, status: String) -> String {
        if saving { return "正在保存…" }
        if dirty && ["已保存", "设置已保存"].contains(status) { return "有未保存的修改" }
        return status
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                Text(Self.statusText(dirty: dirty, saving: saving, status: status))
                    .font(.system(size: 11)).foregroundStyle(dirty ? palette.warning : palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("取消", action: cancel).buttonStyle(WBButtonStyle(compact: true)).disabled(!dirty || saving)
                Button("保存设置", action: save).buttonStyle(WBButtonStyle(primary: true, compact: true)).disabled(!dirty || saving)
            }
        }
    }
}

/// Daily bars use only persisted measured traffic. Empty coverage remains explicitly labelled.
struct DeviceTrafficHistoryView: View {
    @Environment(\.workbenchPalette) private var palette
    let days: [DeviceTrafficDay]
    let timeZoneIdentifier: String
    @State private var selectedDate: Date?
    private var selected: DeviceTrafficDay? { days.first { $0.date == selectedDate } }
    private var maximum: Double { max(1, days.map { Double($0.totalBytes) }.max() ?? 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("每日已记录流量").font(.system(size: 12, weight: .medium))
                Spacer()
                if let selected {
                    Text("\(dayLabel(selected.date)) · \(trafficLabel(selected))")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary).monospacedDigit()
                }
            }.frame(height: 18)
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: days.count > 62) {
                    HStack(alignment: .bottom, spacing: days.count > 14 ? 4 : 8) {
                        ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                            RoundedRectangle(cornerRadius: 3).fill(day.coveredSeconds == 0 ? palette.muted.opacity(0.25) : palette.accent.opacity(selected?.date == day.date ? 0.95 : 0.65))
                                .frame(maxWidth: .infinity)
                                .frame(height: day.totalBytes == 0 ? 1 : max(3, (geometry.size.height - 8) * Double(day.totalBytes) / maximum))
                                .frame(height: geometry.size.height - 8, alignment: .bottom)
                                .contentShape(Rectangle()).onHover { if $0 { selectedDate = day.date } else if selectedDate == day.date { selectedDate = nil } }
                                .help("\(dayLabel(day.date))：\(trafficLabel(day))")
                                .accessibilityLabel("\(dayLabel(day.date))，\(trafficLabel(day))")
                        }
                    }.frame(width: max(geometry.size.width, days.count > 62 ? CGFloat(days.count) * 8 : 0)).background(WorkbenchOverlayScrollbars())
                }
            }.frame(height: 128)
            HStack {
                Text(days.first.map { dayLabel($0.date) } ?? "尚无记录")
                Spacer()
                Text(days.last.map { dayLabel($0.date) } ?? "")
            }.font(.system(size: 10)).foregroundStyle(palette.muted)
            Text("灰色基线表示没有有效采集；保留最近 400 个有记录的日期，图表最多显示最近 400 个自然日。未采集及已过期历史不补算。").font(.system(size: 10)).foregroundStyle(palette.muted)
        }
    }
    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: timeZoneIdentifier); formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
    private func trafficLabel(_ day: DeviceTrafficDay) -> String {
        day.coveredSeconds == 0 ? "没有有效采集" : DeviceTrafficDisplay.gigabytes(day.totalBytes)
    }
}

/// Decimal formatting matches the budget unit and retains small nonzero observations.
enum DeviceTrafficDisplay {
    static func period(_ summary: DeviceTrafficSummary, includeYear: Bool = false) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: summary.timeZoneIdentifier)
        formatter.dateFormat = includeYear ? "yyyy/M/d" : "M/d"
        return "\(formatter.string(from: summary.periodStart)) – \(formatter.string(from: summary.periodEnd.addingTimeInterval(-1)))"
    }
    static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_000_000_000
        if bytes > 0 && bytes < 1000 { return "<0.000001 GB" }
        let precision = value < 0.01 && value > 0 ? 6 : 2
        return value.formatted(.number.grouping(.never).precision(.fractionLength(2...precision))) + " GB"
    }
}
