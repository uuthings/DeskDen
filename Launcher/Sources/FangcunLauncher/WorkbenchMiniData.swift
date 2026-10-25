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

}

extension WorkbenchMiniContextData {
    @MainActor init(context:WorkbenchContextModel,now:Date) {
        time=context.time(now)
        date=WorkbenchMiniFormat.date(now,calendar:context.dateContext.calendar,pattern:"M月d日 · EEEE")
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
            return WorkbenchMiniQuotaData(label:label,value:String(format:"%.0f%%",window.usedPercent),fraction:window.usedPercent/100)
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
