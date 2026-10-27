import Foundation
import LauncherCore

/// Background-only checks of production presentation adapters and bounded reads.
/// Every record is synthetic and every provider is injected.
@MainActor enum WorkbenchMiniDataChecks {
    static func run() async -> (count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ name:String) {
            count += 1;if !value {failures += 1}
            print("\(value ? "PASS":"FAIL") \(name)")
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-mini-data-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        do {
            let now=ISO8601DateFormatter().date(from:"2026-10-25T14:24:00Z")!
            var zone=Calendar(identifier:.gregorian);zone.timeZone=TimeZone(identifier:"America/New_York")!
            let current=CalendarEventItem(id:"current",title:"进行中的夹具日程",start:now.addingTimeInterval(-600),end:now.addingTimeInterval(600),calendarName:"Fixture")
            let tomorrow=CalendarEventItem(id:"tomorrow",title:"明日夹具",start:now.addingTimeInterval(86_400),end:now.addingTimeInterval(90_000),calendarName:"Fixture")
            let finished=CalendarEventItem(id:"finished",title:"已结束夹具",start:now.addingTimeInterval(-3600),end:now.addingTimeInterval(-1),calendarName:"Fixture")
            let distant=CalendarEventItem(id:"distant",title:"范围外夹具",start:now.addingTimeInterval(10*86_400),end:now.addingTimeInterval(11*86_400),calendarName:"Fixture")
            func agenda(_ events:[CalendarEventItem]=[],_ reminders:[ReminderItem]=[],error:String?=nil)->WorkbenchMiniAgendaData {
                .init(events:events,reminders:reminders,displayCalendar:zone,twelveHour:false,now:now,eventError:error)
            }
            let combined=agenda([tomorrow,finished,current])
            check(combined.event?.title == current.title && combined.event?.note == "进行中","mini chooses the ongoing event before the next future event")
            check(combined.event?.dateText == "10/25 · 10:14","mini event time uses the display timezone and explicit date")
            check(agenda([finished,tomorrow]).event?.title == tomorrow.title,"mini finds tomorrow after today's last event")
            check(agenda([distant]).event == nil && agenda([distant]).eventStatus == "未来 7 天暂无日程","mini never claims absence beyond the bounded seven-day horizon")
            check(agenda([current],error:"读取失败").event?.note == "上次日程 · 读取失败","mini retained event has an explicit read-failure status")
            let disconnected=WorkbenchMiniAgendaData(events:[current],reminders:[],displayCalendar:zone,twelveHour:false,now:now,calendarConnected:false)
            check(disconnected.event == nil && disconnected.eventStatus == "日历未连接","disconnected calendar cannot reveal an old retained event")
            let dayOnly=ReminderItem(id:"day",title:"日期型夹具",due:.init(year:2026,month:10,day:25,timeZoneIdentifier:"Pacific/Kiritimati"))
            let timed=ReminderItem(id:"timed",title:"计时型夹具",due:.init(year:2026,month:10,day:26,hour:9,minute:0,timeZoneIdentifier:"Asia/Tokyo"))
            let completed=ReminderItem(id:"done",title:"已完成夹具",due:.init(year:2026,month:1,day:1),isCompleted:true)
            check(agenda([],[dayOnly]).reminder?.dateText == "10/25" && agenda([],[dayOnly]).reminder?.note == nil,"date-only reminders retain their civil date without a fake time or afternoon overdue state")
            check(agenda([],[timed]).reminder?.dateText == "10/25 · 20:00","timed reminders convert their actual instant into the display timezone")
            check(agenda([],[completed,timed,dayOnly]).reminder?.title == dayOnly.title,"mini skips completed reminders and orders upcoming civil and timed dates")
            let overdue=ReminderItem(id:"overdue",title:"逾期夹具",due:.init(year:2026,month:10,day:24,timeZoneIdentifier:"Pacific/Kiritimati"))
            check(agenda([],[overdue]).reminder?.note == "已逾期","date-only overdue state compares days instead of synthetic noon")
            let undated=ReminderItem(id:"undated",title:"无日期夹具")
            check(agenda([],[undated]).reminder?.dateText == "未定日期","undated reminders have no invented timestamp")
            check(agenda([],[completed]).reminder == nil,"completed-only list reports no incomplete reminder")
            let minuteWindow=try AIQuotaWindow(usedPercent:0,durationMinutes:45,resetsAt:now.addingTimeInterval(1200))
            let weekly=try AIQuotaWindow(usedPercent:27,durationMinutes:10_080,resetsAt:now.addingTimeInterval(86_400))
            let reversed=AIQuotaSnapshot(provider:.codex,observedAt:now,source:.localSession,shortWindow:weekly,weeklyWindow:minuteWindow)
            let summary=AIProviderSummary(provider:.codex,state:.ready,snapshot:reversed,detail:"夹具来源")
            let ai=WorkbenchMiniAIData(summary:summary,provider:.codex,now:now,displayCalendar:zone)
            check(ai.windows.count == 2 && ai.windows.map(\.label) == ["45分钟","每周"],"quota labels follow real durations rather than legacy primary/secondary slots")
            check(ai.windows[0].value == "0%" && ai.windows[0].fraction == 0,"a genuine zero quota remains distinct from missing data")
            check(ai.detail.contains("来源：Codex 本地会话额度") && ai.detail.contains("10/25 · 10:24") && ai.detail.contains("重置"),"quota help contains source, observation and reset times in the display timezone")
            let stale=WorkbenchMiniAIData(summary:summary,provider:.codex,now:now.addingTimeInterval(901))
            check(stale.isStale && stale.stateText == "已过期" && stale.detail.contains("不代表当前"),"quota expires between provider refreshes without being shown as current")
            let onlyWeekly=AIQuotaSnapshot(provider:.codex,observedAt:now,source:.manual,shortWindow:weekly,weeklyWindow:nil)
            let partial=WorkbenchMiniAIData(summary:.init(provider:.codex,state:.ready,snapshot:onlyWeekly,detail:"夹具"),provider:.codex,now:now)
            check(partial.windows[0].fraction == nil && partial.windows[1].label == "每周" && partial.stateText == "手动记录","weekly-only manual data leaves the short window unavailable and marks its provenance")
            let wrong=WorkbenchMiniAIData(summary:summary,provider:.claude,now:now)
            check(wrong.windows.allSatisfy {$0.fraction == nil && $0.value == "—"},"a provider mismatch cannot display another provider's quota")
            let error=WorkbenchMiniAIData(summary:.init(provider:.codex,state:.error,snapshot:reversed,detail:"夹具失败"),provider:.codex,now:now)
            check(error.stateText == "读取失败" && error.detail.contains("夹具失败"),"retained quota does not conceal its source failure")
            check(ai.windows[0].reset == "10:44" && ai.windows[1].reset == "10/26 10:24", "quota reset labels preserve the display timezone and next-day date")

            var snapshot = DeviceSnapshot()
            let unavailable = WorkbenchMiniDeviceData(snapshot: snapshot, openedAt: now, now: now)
            check(unavailable.memory == "—" && unavailable.disk == "—" && unavailable.download == "—" && unavailable.periodTraffic == "—" && unavailable.memoryFraction == nil, "missing device readings never become zero usage")
            snapshot.performanceSampledAt = now
            snapshot.cpuTemperature = 50; snapshot.gpuTemperature = 40; snapshot.fanRPM = [0, nil]
            snapshot.memory = .init(total: 16_000, used: 8_000, available: 8_000, application: 5_000, wired: 2_000, compressed: 1_000, cached: 0, swapUsed: nil, pageIns: 0, pageOuts: 0, pressure: .normal)
            snapshot.disk = .init(name: "Fixture", fileSystem: "APFS", total: 1_000_000_000_000, used: 700_000_000_000, available: 300_000_000_000, readBytesPerSecond: nil, writeBytesPerSecond: nil)
            snapshot.network.downloadBytesPerSecond = 0; snapshot.network.uploadBytesPerSecond = 0
            snapshot.network.todayCoverageSeconds = 10
            let live = WorkbenchMiniDeviceData(snapshot: snapshot, openedAt: now, unit: .fahrenheit, now: now)
            check(live.memoryFraction == 0.5 && live.diskFraction == 0.7 && live.disk.contains("1 TB"), "device fractions and decimal storage use the actual capacity snapshot")
            check(live.temperature == "122°F" && live.gpuTemperature == "104°F" && live.leftFan == "0 RPM" && live.rightFan == "—", "sensor units and genuine zero RPM remain distinct from unavailable readings")
            check(live.download == DeviceFormat.rate(0) && live.todayTraffic == DeviceFormat.storage(0), "covered zero network traffic remains a valid zero")
            let segment = UUID()
            let history = (0..<1_000).map { index in
                DeviceHistoryPoint(date: now.addingTimeInterval(Double(index - 999)), segment: segment,
                    cpuPercent: nil, downloadBytesPerSecond: index == 999 ? nil : 0, uploadBytesPerSecond: 1)
            }
            let graph = WorkbenchMiniDeviceData(snapshot: snapshot, openedAt: now, history: history, now: now)
            check(graph.networkPoints.count == 61 && graph.networkPoints.first?.date == now.addingTimeInterval(-60) && graph.networkPoints.last?.download == nil, "Mini graph reads a bounded sixty-second tail and retains unavailable samples as gaps")
            let old = WorkbenchMiniDeviceData(snapshot: snapshot, openedAt: now.addingTimeInterval(1), history: history, now: now.addingTimeInterval(100))
            check(old.networkPoints.isEmpty && old.download == "—" && old.temperature == "—", "stale pre-open samples cannot appear as current readings")
            var budget = DeviceTrafficBudget(); budget.enabled = true; budget.limitGB = 100
            var traffic = DeviceTrafficLedger(now: now.addingTimeInterval(-60), timeZone: zone.timeZone).summary(budget: budget, at: now)
            traffic.coveredSeconds = 10; traffic.received = 20_000_000_000; traffic.sent = 10_000_000_000
            let period = WorkbenchMiniDeviceData(snapshot: snapshot, openedAt: now, summary: traffic, budget: budget, now: now)
            check(period.trafficFraction == 0.3 && period.trafficNote.contains("本机自设额度"), "local period usage remains labeled as a local budget")
            traffic.coveredSeconds = 0
            check(WorkbenchMiniDeviceData(snapshot: snapshot, openedAt: now, summary: traffic, budget: budget, now: now).trafficFraction == nil, "an uncovered period does not become a zero budget reading")

            let source = ProviderUsageConfiguration(kind: .bandwagon, name: "Fixture source", resourceID: "123")
            var externalSnapshot = ProviderUsageSnapshot(sourceID: source.id, observedAt: now, usedBytes: 1_073_741_824, limitBytes: 10_737_418_240, resetDateText: "2026-11-01", displayUnit: .binaryGB, sourceDescription: "Synthetic provider fixture")
            let external = WorkbenchMiniExternalProviderData(configuration: source, state: .init(snapshot: externalSnapshot), now: now, calendar: zone)
            check(external.amount == "1.0 / 10.0 GB" && external.fraction == 0.1 && !external.isStale, "external cards project the provider's binary unit without adding local network bytes")
            check(external.detail.contains("2026-11-01（服务商日期）") && external.detail.contains("1,073,741,824"), "provider date-only reset and byte convention stay explicit")
            var slowSource = source; slowSource.refreshPolicy.maximumInterval = 43_200
            check(!WorkbenchMiniExternalProviderData(configuration: slowSource, state: .init(snapshot: externalSnapshot), now: now.addingTimeInterval(25_200), calendar: zone).isStale, "Mini freshness respects the source's configured maximum refresh interval")
            let absent = WorkbenchMiniExternalProviderData(configuration: source, state: .init(), now: now, calendar: zone)
            check(absent.amount == "尚无读数" && absent.fraction == nil, "unconnected external source remains reachable without an invented balance")
            var failedRefresh = ProviderUsageRefreshState(); failedRefresh.failed(.transport, at: now)
            let failed = WorkbenchMiniExternalProviderData(configuration: source, state: .init(snapshot: externalSnapshot, refresh: failedRefresh), now: now, calendar: zone)
            check(failed.isStale && failed.stateText == "更新失败" && failed.detail.contains("上次有效读数"), "retained provider balances disclose refresh failure")
            externalSnapshot.sourceID = UUID()
            let mismatched = WorkbenchMiniExternalProviderData(configuration: source, state: .init(snapshot: externalSnapshot), now: now, calendar: zone)
            check(mismatched.fraction == nil && mismatched.stateText == "尚无有效读数", "a mismatched provider identity cannot display another source's balance")

            let context=WorkbenchContextModel(dataDirectory:root.appendingPathComponent("Context"),provider:MiniCheckWeather())
            defer {context.stop()}
            _=context.saveClock(zone:"America/New_York",twelveHour:false)
            let emptyContext=WorkbenchMiniContextData(context:context,now:now)
            check(emptyContext.time == "10:24" && emptyContext.zone == "UTC−4" && emptyContext.zoneHelp.contains("纽约"),"mini shares context clock and emits a compact offset with full zone help")
            check(emptyContext.city == "未选择城市" && emptyContext.symbol == "globe" && emptyContext.temperature == "—","no city leaves weather unavailable without an invented temperature")
            let tick = now.addingTimeInterval(37)
            check(WorkbenchMiniContextData(context:context,now:tick,showSeconds:true).time == "10:24:37" &&
                  WorkbenchMiniContextData(context:context,now:tick).time == "10:24", "Mini seconds are optional and use the shared display timezone")
            _=context.saveClock(zone:"America/New_York",twelveHour:true)
            check(WorkbenchMiniContextData(context:context,now:tick,showSeconds:true).time == "上午 10:24:37", "Mini seconds preserve the selected 12-hour clock format")
            let city=WeatherCity(id:"mini:fixture",name:"上海",latitude:31.23,longitude:121.47,timeZoneIdentifier:"Asia/Shanghai")
            check(context.saveContext(city:city,zone:"city",twelveHour:false,temperatureUnit:.fahrenheit),"Mini context fixture uses the shared city and unit settings")
            for _ in 0..<60 where context.loadingWeather {try? await Task.sleep(for:.milliseconds(10))}
            let weather=WorkbenchMiniContextData(context:context,now:now)
            check(weather.temperature == "63°F" && weather.condition == "阴" && weather.city == "上海" && weather.zone == "UTC+8","Mini weather displays the observed condition, selected city and explicit Fahrenheit unit")
            check(weather.weatherNote == "体感 61°F","Mini apparent temperature converts through the same unit preference")
            _=context.saveContext(city:city,zone:"city",twelveHour:false,temperatureUnit:.celsius)
            check(WorkbenchMiniContextData(context:context,now:now).temperature == "17°C" && context.weather?.snapshot?.temperatureCelsius == 17,"Mini unit switching leaves the source Celsius observation unchanged")

            let directory=root.appendingPathComponent("Calendar")
            var saved=ReminderSnapshot();saved.preferences.calendarConnected=true;saved.preferences.remindersConnected=true
            try ReminderStore(directory:directory).save(saved)
            let system=MiniCheckCalendar(),notifier=MiniCheckNotifications()
            let calendar=CalendarModel(dataDirectory:directory,system:system,notifier:notifier)
            // Allow the constructor's ordinary refresh to finish before isolating
            // the subsequent Mini request's query range.
            for _ in 0..<60 {
                if !system.intervals.isEmpty && !calendar.isLoading {break}
                try? await Task.sleep(for:.milliseconds(10))
            }
            calendar.displayedMonth=now.addingTimeInterval(-180*86_400)
            let previousMonth=calendar.displayedMonth,previousZone=calendar.displayTimeZone
            system.intervals=[]
            await calendar.refreshMiniAgenda(timeZone:TimeZone(identifier:"Pacific/Kiritimati")!)
            check(system.intervals.count == 1 && system.intervals.allSatisfy {$0.duration <= 7*86_400+3600},"Mini refresh queries only the bounded overview instead of the browsed month")
            check(calendar.displayedMonth == previousMonth && calendar.displayTimeZone == previousZone && system.permissionRequests == 0 && notifier.permissionRequests == 0,"Mini refresh uses its requested timezone without changing calendar browsing or prompting for permission")
            system.fail=true
            await calendar.refreshMiniAgenda(timeZone:calendar.displayTimeZone)
            check(calendar.overviewReadError != nil && calendar.remindersReadError != nil,"Mini refresh exposes independent event and reminder read failures")
            system.fail=false
            await calendar.refreshMiniAgenda(timeZone:calendar.displayTimeZone)
            check(calendar.overviewReadError == nil && calendar.remindersReadError == nil,"successful Mini reread clears its prior failure state")

            // A held continuation models EventKit: cancelling the awaiting
            // Swift task does not end the underlying native fetch.
            system.holdReminders=true;system.reminderReads=0;system.maximumConcurrentReads=0
            let shared=ReminderItem(id:"single-flight",origin:.system,title:"共享请求夹具")
            let burst=(0..<12).map {_ in Task {await calendar.refreshMiniAgenda(timeZone:previousZone)}}
            _=await wait {system.pendingCount == 1}
            for _ in 0..<20 {await Task.yield()}
            check(system.reminderReads == 1 && system.maximumConcurrentReads == 1,"rapid same-zone Mini opens share exactly one pending native reminder fetch")
            system.finishReads(with:[shared])
            for task in burst {await task.value}
            check(calendar.systemReminders.map(\.id) == [shared.id],"coalesced Mini callers receive the single shared read result")

            let beforeReopen=system.reminderReads
            let closing=Task {await calendar.refreshMiniAgenda(timeZone:previousZone)}
            _=await wait {system.pendingCount == 1}
            closing.cancel()
            let reopened=Task {await calendar.refreshMiniAgenda(timeZone:previousZone)}
            for _ in 0..<20 {await Task.yield()}
            check(system.reminderReads == beforeReopen+1 && system.pendingCount == 1,"cancelling and reopening Mini reuses the still-running native fetch")
            let reopenedItem=ReminderItem(id:"reopened",origin:.system,title:"重新打开夹具")
            system.finishReads(with:[reopenedItem]);await closing.value;await reopened.value
            check(calendar.systemReminders.map(\.id) == [reopenedItem.id],"a live reopened Mini may publish the shared result after its previous caller cancelled")

            let cancelled=Task {await calendar.refreshMiniAgenda(timeZone:previousZone)}
            _=await wait {system.pendingCount == 1};cancelled.cancel()
            system.finishReads(with:[shared]);await cancelled.value
            check(calendar.systemReminders.map(\.id) == [reopenedItem.id],"an entirely cancelled Mini request cannot publish its delayed native result")

            let beforeZone=system.reminderReads
            let oldZone=Task {await calendar.refreshMiniAgenda(timeZone:previousZone)}
            _=await wait {system.pendingCount == 1}
            let otherZone=previousZone.identifier == "Pacific/Kiritimati" ? TimeZone(identifier:"America/New_York")!:TimeZone(identifier:"Pacific/Kiritimati")!
            let newZone=Task {await calendar.refreshMiniAgenda(timeZone:otherZone)}
            for _ in 0..<20 {await Task.yield()}
            check(system.reminderReads == beforeZone+1,"changed-zone Mini waits for the pending native fetch before starting another")
            system.finishReads(with:[shared])
            _=await wait {system.pendingCount == 1 && system.reminderReads == beforeZone+2}
            check(system.maximumConcurrentReads == 1 && system.reminderReads == beforeZone+2,"changed-zone Mini performs one fresh read after the first request completes")
            system.finishReads(with:[reopenedItem]);await oldZone.value;await newZone.value

            let permission=Task {await calendar.refreshMiniAgenda(timeZone:previousZone)}
            _=await wait {system.pendingCount == 1};system.accessGranted=false
            system.finishReads(with:[shared]);await permission.value
            check(calendar.systemReminders.isEmpty && calendar.remindersAccess == .denied,"revoked permission is checked again before a delayed Mini result can publish")
            system.accessGranted=true

            let disconnectedRequest=Task {await calendar.refreshMiniAgenda(timeZone:previousZone)}
            _=await wait {system.pendingCount == 1}
            await calendar.disconnect(reminders:true)
            system.finishReads(with:[shared]);await disconnectedRequest.value
            check(!calendar.preferences.remindersConnected && calendar.systemReminders.isEmpty,"disconnect invalidates the pending Mini result instead of resurrecting system reminders")

            // Drain the previous disconnect's notification publications before
            // isolating the device-only invalidation batch.
            try? await Task.sleep(for:.milliseconds(50))
            let projection=WorkbenchMiniAgendaProjection(calendar:calendar,context:context,now:now)
            let device=DeviceStatusModel(dataDirectory:root.appendingPathComponent("Device"))
            let initialBuilds=projection.rebuildCount
            for _ in 0..<120 {device.objectWillChange.send()}
            try? await Task.sleep(for:.milliseconds(50))
            check(projection.rebuildCount == initialBuilds,"120 device updates do not recompute the Mini agenda projection")
            let due=ReminderDue(date:now.addingTimeInterval(60),includesTime:true,calendar:zone)
            let projectionItem=ReminderItem(id:"projection",title:"投影更新夹具",due:due)
            let draft=CalendarReminderDraft(item:projectionItem,creating:true,defaultDate:now,calendar:zone)
            let savedProjection=await calendar.saveDraft(draft)
            _=await wait {projection.data.reminder?.title == projectionItem.title}
            check(savedProjection && projection.data.reminder?.title == projectionItem.title && projection.data.reminder?.note == nil,"a real reminder save updates the cached Mini agenda after model publication")
            _=context.saveClock(zone:"America/New_York",twelveHour:false)
            _=await wait {projection.data.reminder?.dateText == "10/25 · 10:25"}
            check(projection.data.reminder?.dateText == "10/25 · 10:25","changing the shared timezone rebuilds the cached Mini reminder time")
            let beforeMinute=projection.rebuildCount
            projection.update(now:now.addingTimeInterval(20))
            check(projection.rebuildCount == beforeMinute,"same-minute invalidations do not traverse reminders again")
            projection.update(now:now.addingTimeInterval(120))
            check(projection.rebuildCount == beforeMinute+1 && projection.data.reminder?.note == "已逾期","the shared minute clock still updates reminder expiry without another timer")
        } catch {check(false,"mini data fixtures: \(error.localizedDescription)")}
        print("Mini data checks: \(count) checks, \(failures) failures")
        return (count,failures)
    }
    private static func wait(_ condition:()->Bool) async->Bool {
        for _ in 0..<100 {
            if condition() {return true}
            try? await Task.sleep(for:.milliseconds(5))
        }
        return condition()
    }
}

private struct MiniCheckWeather:WeatherProviding {
    let providerID="mini-fixture"
    func searchCities(query:String,language:String) async throws->[WeatherCity] {[]}
    func currentWeather(for city:WeatherCity,receivedAt:Date) async throws->WeatherSnapshot {
        .init(city:city,observedAt:receivedAt,receivedAt:receivedAt,temperatureCelsius:17,apparentTemperatureCelsius:16,
              weatherCode:3,isDay:true,providerID:providerID,attribution:"Isolated fixture",attributionURL:URL(string:"https://example.com/weather")!)
    }
}

@MainActor private final class MiniCheckCalendar:CalendarSystemProviding {
    var intervals:[DateInterval]=[],permissionRequests=0,fail=false
    var holdReminders=false,accessGranted=true
    var reminderReads=0,maximumConcurrentReads=0
    private var concurrentReads=0
    private var pending:[CheckedContinuation<[ReminderItem],Error>]=[]
    var pendingCount:Int {pending.count}
    func access(reminders:Bool)->CalendarAccess {accessGranted ? .granted:.denied}
    func requestAccess(reminders:Bool) async throws->Bool {permissionRequests += 1;return false}
    func events(in interval:DateInterval) throws->[CalendarEventItem] {
        intervals.append(interval);if fail {throw ReminderError.unavailable("Fixture read failure")};return []
    }
    func reminders() async throws->[ReminderItem] {
        reminderReads += 1;concurrentReads += 1;maximumConcurrentReads=max(maximumConcurrentReads,concurrentReads)
        defer {concurrentReads -= 1}
        if holdReminders {return try await withCheckedThrowingContinuation {pending.append($0)}}
        if fail {throw ReminderError.unavailable("Fixture read failure")};return []
    }
    func finishReads(with items:[ReminderItem]) {
        let reads=pending;pending=[]
        for read in reads {read.resume(returning:items)}
    }
    func writableReminderCalendars()->[ReminderCalendar] {[]}
    func saveReminder(_ item:ReminderItem,creating:Bool) throws->ReminderItem {throw ReminderError.unavailable("Fixture")}
    func deleteReminder(_ item:ReminderItem) throws {throw ReminderError.unavailable("Fixture")}
}

@MainActor private final class MiniCheckNotifications:ReminderNotificationProviding {
    var permissionRequests=0
    func access() async->CalendarAccess {.notDetermined}
    func requestAccess() async throws->Bool {permissionRequests += 1;return false}
    func replacePending(_ notifications:[ReminderNotification]) async throws {}
}
