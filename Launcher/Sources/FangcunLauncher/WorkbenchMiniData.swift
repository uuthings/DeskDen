import Foundation
import Combine
import LauncherCore

/// Small presentation values derived from the shared models. No data provider,
/// timers, history traversal or copied settings live in the Mini itself.
struct WorkbenchMiniContextData {
    let time:String
    let date:String
    let zone:String
    let zoneHelp:String
    let city:String
    let temperature:String
    let condition:String
    let symbol:String
    let weatherNote:String?
    var shortDate:String = ""
    var weekday:String = ""
}

extension WorkbenchMiniContextData {
    @MainActor init(context:WorkbenchContextModel,now:Date) {
        time=context.time(now)
        date=WorkbenchMiniFormat.date(now,calendar:context.dateContext.calendar,pattern:"M月d日 · EEEE")
        shortDate=WorkbenchMiniFormat.date(now,calendar:context.dateContext.calendar,pattern:"M月d日")
        weekday=WorkbenchMiniFormat.date(now,calendar:context.dateContext.calendar,pattern:"EEE")
        zoneHelp=WorkbenchContextModel.zoneTitle(context.effectiveTimeZoneIdentifier,at:now)
        zone=zoneHelp.components(separatedBy:" · ").last ?? zoneHelp
        city=context.settings.city?.name ?? "未选择城市"
        let weather=context.weather,snapshot=weather?.snapshot
        temperature=context.temperature(snapshot?.temperatureCelsius)
        condition=context.weatherStatusTitle
        symbol=context.settings.city == nil ? "globe":weatherSymbol(snapshot?.weatherCode,isDay:snapshot?.isDay)
        if weather?.freshness == .stale {weatherNote="上次天气已过期"}
        else if let snapshot,let apparent=snapshot.apparentTemperatureCelsius {weatherNote="体感 "+context.temperature(apparent)}
        else {weatherNote=nil}
    }
}

struct WorkbenchMiniAgendaItem:Equatable {
    let title:String
    let dateText:String
    let note:String?
}

struct WorkbenchMiniAgendaData {
    let event:WorkbenchMiniAgendaItem?
    let reminder:WorkbenchMiniAgendaItem?
    let eventStatus:String
    let reminderStatus:String

}

extension WorkbenchMiniAgendaData {
    @MainActor init(calendar:CalendarModel,context:WorkbenchContextModel,now:Date) {
        self.init(events:calendar.overviewEvents,reminders:calendar.reminders,
                  displayCalendar:context.dateContext.calendar,twelveHour:context.settings.twelveHour,now:now,
                  calendarConnected:calendar.preferences.calendarConnected,calendarAccess:calendar.calendarAccess,
                  eventError:calendar.overviewReadError,reminderError:calendar.storageError ?? calendar.remindersReadError,
                  loading:calendar.isLoading)
    }

    /// Civil reminders keep their chosen day; timed entries use the display zone.
    init(events:[CalendarEventItem],reminders:[ReminderItem],displayCalendar:Calendar,twelveHour:Bool,now:Date,
         calendarConnected:Bool=true,calendarAccess:CalendarAccess = .granted,
         eventError:String?=nil,reminderError:String?=nil,loading:Bool=false) {
        let end=displayCalendar.date(byAdding:.day,value:7,to:displayCalendar.startOfDay(for:now)) ?? now
        let first=events.filter {calendarConnected && calendarAccess == .granted && $0.start < end && max($0.end,$0.start.addingTimeInterval(1)) > now}.min {
            $0.start == $1.start ? $0.id < $1.id:$0.start < $1.start
        }
        if let first {
            event=WorkbenchMiniAgendaItem(title:first.title,
                dateText:WorkbenchMiniFormat.date(first.start,calendar:displayCalendar,
                    pattern:first.isAllDay ? "MM/dd · 全天":twelveHour ? "MM/dd · a h:mm":"MM/dd · HH:mm"),
                note:eventError != nil ? "上次日程 · 读取失败":first.start <= now && !first.isAllDay ? "进行中":nil)
        } else {event=nil}
        if let eventError {eventStatus=eventError}
        else if !calendarConnected {eventStatus="日历未连接"}
        else if calendarAccess != .granted {eventStatus="日历访问未允许"}
        else {eventStatus=loading ? "正在读取日程":"未来 7 天暂无日程"}

        let firstReminder=reminders.lazy.filter {!$0.isCompleted}.min {
            let lhs=ReminderQueries.displayDate(for:.reminder($0),calendar:displayCalendar) ?? .distantFuture
            let rhs=ReminderQueries.displayDate(for:.reminder($1),calendar:displayCalendar) ?? .distantFuture
            return lhs == rhs ? $0.stableID < $1.stableID:lhs < rhs
        }
        if let firstReminder {
            let due=firstReminder.due
            let date=ReminderQueries.displayDate(for:.reminder(firstReminder),calendar:displayCalendar)
            let text=date.map {WorkbenchMiniFormat.date($0,calendar:displayCalendar,
                pattern:due?.hasTime == true ? (twelveHour ? "MM/dd · a h:mm":"MM/dd · HH:mm"):"MM/dd")} ?? "未定日期"
            let overdue=date.map {due?.hasTime == true ? $0 < now:displayCalendar.startOfDay(for:$0) < displayCalendar.startOfDay(for:now)} ?? false
            reminder=WorkbenchMiniAgendaItem(title:firstReminder.title,dateText:text,
                note:reminderError != nil ? "部分来源不可用":overdue ? "已逾期":nil)
        } else {reminder=nil}
        reminderStatus=reminderError == nil ? (loading ? "正在读取待办":"暂无未完成待办"):"待办读取失败"
    }
}

struct WorkbenchMiniQuotaData:Equatable {
    let label:String
    let value:String
    let fraction:Double?
    var reset:String = "—"
}

struct WorkbenchMiniAIData {
    let provider:AIProvider
    let title:String
    let stateText:String
    let detail:String
    let isStale:Bool
    let windows:[WorkbenchMiniQuotaData]

}

extension WorkbenchMiniAIData {
    init(summary:AIProviderSummary?,provider:AIProvider,now:Date,displayCalendar:Calendar = .current) {
        self.provider=provider;title=provider.title
        let summary=summary?.provider == provider ? summary:nil
        let snapshot=summary?.snapshot
        isStale=summary?.state == .stale || snapshot?.isStale(at:now) == true
        if summary?.state == .error {stateText="读取失败"}
        else if isStale {stateText="已过期"}
        else if let source=snapshot?.source,source == .manual || source == .imported {stateText=source == .manual ? "手动记录":"导入读数"}
        else {stateText=summary?.state == .ready ? "已用":summary?.state.title ?? "正在读取"}
        let rows=snapshot?.comparisonRows ?? []
        windows=(0..<2).map {index in
            guard index < rows.count,let window=rows[index] else {
                return WorkbenchMiniQuotaData(label:index == 0 ? "短时":"每周",value:"—",fraction:nil)
            }
            let label=window.durationMinutes == 10_080 ? "每周":window.durationMinutes % 60 == 0 ? "\(window.durationMinutes / 60)小时":"\(window.durationMinutes)分钟"
            let reset=window.resetsAt.map {WorkbenchMiniFormat.date($0,calendar:displayCalendar,
                pattern:displayCalendar.isDate($0,inSameDayAs:now) ? "HH:mm":"M/d HH:mm")} ?? "未提供"
            return WorkbenchMiniQuotaData(label:label,value:String(format:"%.0f%%",window.usedPercent),fraction:window.usedPercent/100,reset:reset)
        }
        var lines=[summary?.detail ?? "正在读取已配置的本机额度来源。"]
        if isStale {lines.append("上次读数已过期，等待来源更新；不代表当前已用比例。")}
        if let snapshot {
            lines.append("来源："+snapshot.source.title)
            lines.append("采集："+WorkbenchMiniFormat.date(snapshot.observedAt,calendar:displayCalendar,pattern:"MM/dd · HH:mm"))
            for window in snapshot.availableWindows {
                let reset=window.resetsAt.map {WorkbenchMiniFormat.date($0,calendar:displayCalendar,pattern:"MM/dd · HH:mm")} ?? "来源未提供"
                lines.append(window.title+"重置："+reset)
            }
        }
        detail=lines.joined(separator:"\n")
    }
}

enum WorkbenchMiniFormat {
    static func date(_ date:Date,calendar:Calendar,pattern:String)->String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"zh_CN")
        formatter.calendar=calendar;formatter.timeZone=calendar.timeZone;formatter.dateFormat=pattern
        return formatter.string(from:date)
    }
}

struct WorkbenchMiniNetworkPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let segment: UUID
    let download: Double?
    let upload: Double?
}

struct WorkbenchMiniDeviceData {
    var cpu = "—"
    var memory = "—"
    var temperature = "—"
    var download = "—"
    var upload = "—"
    var note: String?
    var memoryFraction: Double?
    var memoryPressure = "压力不可用"
    var disk = "—"
    var diskFraction: Double?
    var diskNote = "正在读取启动卷容量"
    var gpuTemperature = "—"
    var leftFan = "—"
    var rightFan = "—"
    var thermalState = "不可用"
    var sensorNote = "当前硬件未返回有效传感器读数"
    var todayTraffic = "—"
    var periodTraffic = "—"
    var trafficFraction: Double?
    var trafficNote = "尚未采集流量"
    var networkPoints: [WorkbenchMiniNetworkPoint] = []
}

extension WorkbenchMiniDeviceData {
    init(snapshot: DeviceSnapshot, openedAt: Date, history: [DeviceHistoryPoint] = [],
         summary: DeviceTrafficSummary? = nil, budget: DeviceTrafficBudget? = nil,
         unit: WeatherTemperatureUnit = .celsius, now: Date = Date()) {
        let fresh = snapshot.performanceSampledAt.map { $0 >= openedAt && now.timeIntervalSince($0) < 90 } ?? false
        cpu = DeviceFormat.percent(fresh ? snapshot.cpuPercent : nil)
        if fresh, let memory = snapshot.memory {
            self.memory = DeviceFormat.capacity(memory.used) + " / " + DeviceFormat.capacity(memory.total)
            memoryFraction = memory.total > 0 ? Double(memory.used) / Double(memory.total) : nil
            memoryPressure = DeviceFormat.pressure(memory.pressure)
        }
        if fresh, let disk = snapshot.disk {
            self.disk = DeviceFormat.storage(disk.used) + " / " + DeviceFormat.storage(disk.total)
            diskFraction = disk.total > 0 ? Double(disk.used) / Double(disk.total) : nil
            diskNote = "启动卷：\(disk.name)\n已用／总量采用十进制；可用 \(DeviceFormat.storage(disk.available))。"
        }
        temperature = unit.formatted(fresh ? snapshot.cpuTemperature : nil)
        gpuTemperature = unit.formatted(fresh ? snapshot.gpuTemperature : nil)
        func fan(_ index: Int) -> String {
            guard fresh, let fans = snapshot.fanRPM, index < fans.count,
                  let value = fans[index], value.isFinite, value >= 0 else { return "—" }
            return String(format: "%.0f RPM", value)
        }
        leftFan = fan(0); rightFan = fan(1)
        thermalState = fresh ? DeviceFormat.thermal(snapshot.thermalState) : "读取中"
        sensorNote = ([snapshot.sensorSource] + [snapshot.unavailableReasons["temperature"], snapshot.unavailableReasons["fan"]].compactMap { $0 }).joined(separator: "\n")
        download = DeviceFormat.rate(fresh ? snapshot.network.downloadBytesPerSecond : nil)
        upload = DeviceFormat.rate(fresh ? snapshot.network.uploadBytesPerSecond : nil)
        note = fresh ? nil : "正在读取本机数据"
        if snapshot.network.todayCoverageSeconds > 0 {
            let total = snapshot.network.todayDownload.addingReportingOverflow(snapshot.network.todayUpload)
            todayTraffic = DeviceFormat.storage(total.overflow ? UInt64.max : total.partialValue)
        }
        if let summary, summary.coveredSeconds > 0 {
            periodTraffic = DeviceFormat.storage(summary.totalBytes)
            if let budget, budget.enabled, budget.limitBytes > 0 {
                periodTraffic += " / " + DeviceFormat.storage(budget.limitBytes)
                trafficFraction = Double(summary.totalBytes) / Double(budget.limitBytes)
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: summary.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
            let start = WorkbenchMiniFormat.date(summary.periodStart, calendar: calendar, pattern: "M/d")
            let end = WorkbenchMiniFormat.date(summary.periodEnd.addingTimeInterval(-1), calendar: calendar, pattern: "M/d")
            trafficNote = "\(start)–\(end) · \(summary.scope.title)\n本机已采集流量；\(summary.isPartialPeriod ? "仅覆盖部分时间" : "覆盖当前周期")。"
            trafficNote += budget?.enabled == true ? "预算为本机自设额度。" : "尚未启用流量预算。"
        }
        if fresh {
            let cutoff = now.addingTimeInterval(-60)
            networkPoints = history.suffix(64).filter { $0.date >= cutoff && $0.date <= now.addingTimeInterval(1) }.map {
                .init(date: $0.date, segment: $0.segment, download: $0.downloadBytesPerSecond, upload: $0.uploadBytesPerSecond)
            }
        }
    }
}

/// Provider snapshots enter the same small-card renderer without introducing
/// credential handling or another refresh loop inside the transient panel.
struct WorkbenchMiniExternalProviderData: Identifiable {
    let id: UUID
    let title: String
    let stateText: String
    let amount: String
    let fraction: Double?
    let detail: String
    let isStale: Bool
}

extension WorkbenchMiniExternalProviderData {
    init(configuration: ProviderUsageConfiguration, state: ProviderUsageSourceState, now: Date, calendar: Calendar) {
        id = configuration.id; title = configuration.name
        let status = state.status(at: now, maximumAge: configuration.refreshPolicy.maximumInterval)
        let snapshot = state.snapshot.flatMap { $0.sourceID == configuration.id && (try? $0.validate(now: now)) != nil ? $0 : nil }
        stateText = configuration.enabled ? (snapshot == nil && status == .ready ? "尚无有效读数" : status.title) : "已停用"
        isStale = !configuration.enabled || status != .ready || snapshot == nil
        if let snapshot {
            let divisor = snapshot.displayUnit.divisor
            amount = String(format: "%.1f / %.1f %@", Double(snapshot.usedBytes) / divisor,
                            Double(snapshot.limitBytes) / divisor, snapshot.displayUnit.title)
            fraction = snapshot.usedPercent / 100
            let observed = WorkbenchMiniFormat.date(snapshot.observedAt, calendar: calendar, pattern: "M/d HH:mm")
            let reset = snapshot.resetsAt.map { WorkbenchMiniFormat.date($0, calendar: calendar, pattern: "M/d HH:mm") }
                ?? snapshot.resetDateText.map { $0 + "（服务商日期）" } ?? "来源未提供"
            detail = [snapshot.sourceDescription, snapshot.displayUnit.explanation, "采集：" + observed,
                      "重置：" + reset, isStale ? "上次有效读数；不代表当前余额。" : nil, state.message].compactMap { $0 }.joined(separator: "\n")
        } else {
            amount = "尚无读数"; fraction = nil
            detail = state.message ?? "请在用量页面连接此来源；小窗不自行查询或推算服务商用量。"
        }
    }
}

/// Device samples can update every second, but selecting the next reminder can
/// traverse a large list. Rebuild only for agenda/context changes or a new minute.
@MainActor final class WorkbenchMiniAgendaProjection:ObservableObject {
    @Published private(set) var data:WorkbenchMiniAgendaData
    private(set) var rebuildCount=1
    private let calendar:CalendarModel
    private let context:WorkbenchContextModel
    private var now:Date
    private var changed:AnyCancellable?

    init(calendar:CalendarModel,context:WorkbenchContextModel,now:Date=Date()) {
        self.calendar=calendar;self.context=context;self.now=now
        data=WorkbenchMiniAgendaData(calendar:calendar,context:context,now:now)
        // objectWillChange precedes the assignments; coalesce the burst and read
        // the completed state on the main run loop, without a second clock.
        changed=Publishers.Merge(calendar.objectWillChange,context.objectWillChange)
            .debounce(for:.milliseconds(16),scheduler:RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated {self?.rebuild()} }
    }
    func update(now:Date) {
        guard floor(now.timeIntervalSinceReferenceDate/60) != floor(self.now.timeIntervalSinceReferenceDate/60) else {return}
        self.now=now;rebuild()
    }
    private func rebuild() {
        data=WorkbenchMiniAgendaData(calendar:calendar,context:context,now:now)
        rebuildCount += 1
    }
}
