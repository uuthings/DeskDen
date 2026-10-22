import AppKit
import Combine
import Foundation
import LauncherCore
@preconcurrency import EventKit
@preconcurrency import UserNotifications

@MainActor final class EventKitCalendarProvider:CalendarSystemProviding {
    private let store=EKEventStore()
    private var deletedTemplate:(id:String,reminder:EKReminder)?
    func access(reminders:Bool) -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for:reminders ? .reminder:.event) {
        case .fullAccess:return .granted
        case .notDetermined:return .notDetermined
        case .restricted:return .restricted
        default:return .denied
        }
    }
    func requestAccess(reminders:Bool) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let completion:@Sendable (Bool,Error?) -> Void = { allowed,error in
                if let error { continuation.resume(throwing:error) } else { continuation.resume(returning:allowed) }
            }
            if reminders { store.requestFullAccessToReminders(completion:completion) }
            else { store.requestFullAccessToEvents(completion:completion) }
        }
    }
    func events(in interval:DateInterval) throws -> [CalendarEventItem] {
        guard access(reminders:false) == .granted else { throw ReminderError.unavailable("尚未允许读取系统日历。") }
        return store.events(matching:store.predicateForEvents(withStart:interval.start,end:interval.end,calendars:nil)).map { event in
            CalendarEventItem(id:"\(event.calendarItemIdentifier):\(event.startDate.timeIntervalSince1970)",title:event.title ?? "未命名日程",notes:event.notes ?? "",start:event.startDate,end:event.endDate,isAllDay:event.isAllDay,calendarName:event.calendar.title,location:event.location ?? "",calendarID:event.calendar.calendarIdentifier)
        }.sorted { $0.start < $1.start }
    }
    func calendarSources() -> [CalendarSourceDescriptor] {
        guard access(reminders:false) == .granted else {return []}
        return store.calendars(for:.event).map {CalendarSourceDescriptor(id:$0.calendarIdentifier,title:$0.title,account:$0.source.title)}
            .sorted {$0.title.localizedStandardCompare($1.title) == .orderedAscending}
    }
    func reminders() async throws -> [ReminderItem] {
        guard access(reminders:true) == .granted else { throw ReminderError.unavailable("尚未允许读取系统提醒事项。") }
        let predicate=store.predicateForReminders(in:nil)
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching:predicate) { reminders in
                guard let reminders else { continuation.resume(throwing:ReminderError.unavailable("系统提醒事项读取失败，请重试。")); return }
                continuation.resume(returning:reminders.map(Self.value))
            }
        }
    }
    nonisolated private static func value(_ reminder:EKReminder) -> ReminderItem {
        let due=reminder.dueDateComponents.flatMap { c -> ReminderDue? in
            guard let year=c.year,let month=c.month,let day=c.day else { return nil }
            return ReminderDue(year:year,month:month,day:day,hour:c.hour,minute:c.hour == nil ? nil:(c.minute ?? 0),timeZoneIdentifier:c.timeZone?.identifier ?? TimeZone.current.identifier)
        }
        return ReminderItem(id:reminder.calendarItemIdentifier,origin:.system,calendarID:reminder.calendar.calendarIdentifier,calendarName:reminder.calendar.title,title:reminder.title ?? "未命名提醒",notes:reminder.notes ?? "",due:due,isCompleted:reminder.isCompleted,completedAt:reminder.completionDate,createdAt:reminder.creationDate ?? Date(),updatedAt:reminder.lastModifiedDate ?? Date(),isWritable:reminder.calendar.allowsContentModifications)
    }
    func writableReminderCalendars() -> [ReminderCalendar] {
        guard access(reminders:true) == .granted else { return [] }
        let defaultID=store.defaultCalendarForNewReminders()?.calendarIdentifier
        return store.calendars(for:.reminder).filter(\.allowsContentModifications).sorted { lhs,rhs in
            if lhs.calendarIdentifier == defaultID { return true }; if rhs.calendarIdentifier == defaultID { return false }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }.map { ReminderCalendar(id:$0.calendarIdentifier,title:$0.title) }
    }
    func saveReminder(_ item:ReminderItem,creating:Bool) throws -> ReminderItem {
        guard access(reminders:true) == .granted else { throw ReminderError.unavailable("提醒事项访问已关闭，请重新接入。") }
        let reminder:EKReminder
        let restoring=creating && deletedTemplate?.id == item.id
        if creating {
            reminder=restoring ? deletedTemplate!.reminder:EKReminder(eventStore:store)
            let destination:EKCalendar?
            if let identifier=item.calendarID { destination=store.calendar(withIdentifier:identifier) }
            else { destination=store.defaultCalendarForNewReminders() }
            guard let calendar=destination, calendar.allowedEntityTypes.contains(.reminder),calendar.allowsContentModifications else {
                throw ReminderError.unavailable("没有可写入的提醒列表。请先在系统提醒事项中创建一个列表。")
            }
            reminder.calendar=calendar
        } else {
            guard let current=store.calendarItem(withIdentifier:item.id) as? EKReminder else { throw ReminderError.unavailable("这条系统提醒已被删除或移动，请刷新后重试。") }
            guard current.calendar.allowsContentModifications else { throw ReminderError.unavailable("这个系统提醒列表为只读。") }
            reminder=current
        }
        reminder.title=item.title; reminder.notes=item.notes.isEmpty ? nil:item.notes
        let dueChanged=(creating && !restoring) || Self.value(reminder).due != item.due
        if dueChanged {
            reminder.dueDateComponents=item.due?.components
            if item.due == nil { reminder.startDateComponents=nil }
        }
        reminder.isCompleted=item.isCompleted; reminder.completionDate=item.isCompleted ? (item.completedAt ?? Date()):nil
        // Existing location/custom alarms survive ordinary title edits and completion changes.
        // For a newly supplied due time, Reminders itself owns the alarm, not Fangcun's notification queue.
        if dueChanged {
            let locationAlarms=(reminder.alarms ?? []).filter { $0.structuredLocation != nil }
            reminder.alarms=locationAlarms
            if let due=item.due,due.hasTime,let date=due.date { reminder.addAlarm(EKAlarm(absoluteDate:date)) }
        }
        try store.save(reminder,commit:true)
        if restoring { deletedTemplate=nil }
        return Self.value(reminder)
    }
    func deleteReminder(_ item:ReminderItem) throws {
        guard access(reminders:true) == .granted else { throw ReminderError.unavailable("提醒事项访问已关闭，无法删除。") }
        guard let reminder=store.calendarItem(withIdentifier:item.id) as? EKReminder else { throw ReminderError.unavailable("这条系统提醒已不存在，请刷新列表。") }
        guard reminder.calendar.allowsContentModifications else { throw ReminderError.unavailable("这个系统提醒列表为只读。") }
        let copy=EKReminder(eventStore:store)
        copy.calendar=reminder.calendar; copy.title=reminder.title; copy.notes=reminder.notes
        copy.startDateComponents=reminder.startDateComponents; copy.dueDateComponents=reminder.dueDateComponents
        copy.isCompleted=reminder.isCompleted; copy.completionDate=reminder.completionDate
        copy.priority=reminder.priority; copy.url=reminder.url; copy.alarms=reminder.alarms; copy.recurrenceRules=reminder.recurrenceRules
        try store.remove(reminder,commit:true)
        deletedTemplate=(item.id,copy)
    }
}

@MainActor final class LocalReminderNotificationProvider:NSObject,ReminderNotificationProviding {
    private let center=UNUserNotificationCenter.current()
    override init() {super.init();FangcunNotificationDelegate.shared.install()}
    func access() async -> CalendarAccess {
        let settings=await center.notificationSettings()
        switch settings.authorizationStatus { case .authorized,.provisional:return .granted; case .notDetermined:return .notDetermined; default:return .denied }
    }
    func requestAccess() async throws -> Bool { try await center.requestAuthorization(options:[.alert,.sound]) }
    func replacePending(_ notifications:[ReminderNotification]) async throws {
        let pending=await center.pendingNotificationRequests()
        let wanted=Set(notifications.map(\.id))
        let obsolete=pending.filter { $0.identifier.hasPrefix(ReminderNotificationPlan.prefix) && !wanted.contains($0.identifier) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers:obsolete)
        for notification in notifications {
            let content=UNMutableNotificationContent(); content.title=notification.title; content.body=notification.notes
            content.sound = .default; content.threadIdentifier="fangcun-reminders"; content.userInfo=["fangcunRoute":"calendar","reminderID":String(notification.id.dropFirst(ReminderNotificationPlan.prefix.count))]
            let trigger=UNCalendarNotificationTrigger(dateMatching:notification.due.components,repeats:false)
            try await center.add(UNNotificationRequest(identifier:notification.id,content:content,trigger:trigger))
        }
    }
}

struct CalendarReminderDraft:Identifiable,Equatable {
    var id:UUID = UUID()
    var item:ReminderItem
    var creating:Bool
    var hasDate:Bool
    var hasTime:Bool
    var date:Date
    var time:Date
    var calendar:Calendar
    init(item:ReminderItem,creating:Bool,defaultDate:Date,calendar:Calendar = .current) {
        var editingCalendar=calendar
        if let due=item.due,let zone=TimeZone(identifier:due.timeZoneIdentifier) {editingCalendar.timeZone=zone}
        self.calendar=editingCalendar
        self.item=item; self.creating=creating; hasDate=item.due != nil; hasTime=item.due?.hasTime ?? false
        date=item.due?.date ?? defaultDate; time=item.due?.date ?? Date()
    }
    func value() throws -> ReminderItem {
        var item=item
        if hasDate {
            var due=ReminderDue(date:date,includesTime:false,calendar:calendar)
            if hasTime { due.hour=calendar.component(.hour,from:time); due.minute=calendar.component(.minute,from:time) }
            item.due=due
        } else { item.due=nil }
        item.updatedAt=Date(); return try item.validated()
    }
}

enum CalendarPresentationMode:String,CaseIterable,Identifiable {case month,week,agenda;var id:String {rawValue};var title:String {switch self {case .month:"月";case .week:"周";case .agenda:"日程"}}}
private struct CalendarDisplayPreferences:Codable {
    var hiddenSources:Set<String> = []
}

@MainActor final class CalendarModel:ObservableObject {
    @Published private(set) var localReminders:[ReminderItem] = []
    @Published private(set) var systemReminders:[ReminderItem] = []
    @Published private(set) var events:[CalendarEventItem] = []
    @Published private(set) var todayEvents:[CalendarEventItem] = []
    @Published private(set) var overviewEventValues:[CalendarEventItem] = []
    @Published private(set) var calendarSources:[CalendarSourceDescriptor] = []
    @Published private(set) var hiddenSources:Set<String> = []
    @Published var presentationMode:CalendarPresentationMode = .month
    @Published var showReminderList=false
    @Published var reminderListSource="all"
    @Published var editorCloseRequest=0
    @Published var displayTimeZone:TimeZone = .current {
        didSet {
            guard oldValue != displayTimeZone else {return}
            var previous=displayCalendar;previous.timeZone=oldValue
            let day=previous.dateComponents([.year,.month,.day],from:selectedDay)
            let month=previous.dateComponents([.year,.month,.day],from:displayedMonth)
            selectedDay=displayCalendar.date(from:day) ?? selectedDay
            displayedMonth=displayCalendar.date(from:month) ?? displayedMonth
            Task {await refresh()}
        }
    }
    @Published private(set) var preferences=ReminderPreferences()
    @Published private(set) var calendarAccess:CalendarAccess = .notDetermined
    @Published private(set) var remindersAccess:CalendarAccess = .notDetermined
    @Published private(set) var notificationAccess:CalendarAccess = .notDetermined
    @Published private(set) var writableCalendars:[ReminderCalendar] = []
    @Published var selectedDay=Date()
    @Published var displayedMonth=Date()
    @Published var filter:ReminderFilter = .day
    @Published var search=""
    @Published var editor:CalendarReminderDraft?
    @Published var selectedEvent:CalendarEventItem?
    @Published var selectedReminder:ReminderItem?
    @Published var showNewChoice=false
    @Published var showSources=false
    @Published var sourcesReturnToPrivacy=false
    @Published var showNotifications=false
    @Published var errorMessage:String?
    @Published private(set) var storageError:String?
    @Published private(set) var isLoading=false
    @Published private(set) var isWorking=false
    @Published private(set) var undoMessage:String?
    @Published private(set) var notificationMessage:String?
    private enum Undo { case changed(ReminderItem),deleted(ReminderItem) }
    private var undo:Undo?
    private let store:ReminderStore
    private let displayPreferencesURL:URL
    private var displayPreferencesError:String?
    private let system:any CalendarSystemProviding
    private let notifier:any ReminderNotificationProviding
    private var service:ReminderService?
    private var refreshVersion=0
    private var observer:NSObjectProtocol?
    private var activationObserver:NSObjectProtocol?
    private var dayObserver:NSObjectProtocol?
    private var notificationTask:Task<Void,Never>?
    private(set) var ownNotificationsSuspendedForQuit=false
    private var notificationsNeedRefresh=false

    convenience init(dataDirectory:URL) { self.init(dataDirectory:dataDirectory,system:EventKitCalendarProvider(),notifier:LocalReminderNotificationProvider()) }
    init(dataDirectory:URL,system:any CalendarSystemProviding,notifier:any ReminderNotificationProviding) {
        store=ReminderStore(directory:dataDirectory); self.system=system; self.notifier=notifier
        displayPreferencesURL=dataDirectory.appendingPathComponent("calendar-display.json")
        if FileManager.default.fileExists(atPath:displayPreferencesURL.path) {
            do {
                let bytes=try Data(contentsOf:displayPreferencesURL)
                guard bytes.count <= 1_000_000 else {throw ReminderError.invalid("日历来源显示偏好过大。")}
                let saved=try JSONDecoder().decode(CalendarDisplayPreferences.self,from:bytes)
                guard saved.hiddenSources.count <= 5_000,saved.hiddenSources.allSatisfy({!$0.isEmpty && $0.count <= 1024}) else {throw ReminderError.invalid("日历来源显示偏好无效。")}
                hiddenSources=saved.hiddenSources
            } catch {displayPreferencesError="日历显示偏好读取失败，原文件已保留。";errorMessage=displayPreferencesError}
        }
        do { service=try ReminderService(store:store,system:system); syncLocal() }
        catch { storageError="本机提醒读取失败，原文件已保留。\n\(error.localizedDescription)" }
        calendarAccess=system.access(reminders:false); remindersAccess=system.access(reminders:true)
        observer=NotificationCenter.default.addObserver(forName:.EKEventStoreChanged,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        activationObserver=NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        dayObserver=NotificationCenter.default.addObserver(forName:.NSCalendarDayChanged,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        Task { [weak self] in await self?.refresh() }
    }
    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let dayObserver { NotificationCenter.default.removeObserver(dayObserver) }
        notificationTask?.cancel()
    }
    var displayCalendar:Calendar {var calendar=Calendar(identifier:.gregorian);calendar.timeZone=displayTimeZone;calendar.firstWeekday=2;return calendar}
    var reminders:[ReminderItem] { localReminders+systemReminders }
    var upcomingReminders:[ReminderItem] { ReminderQueries.upcoming(reminders) }
    var visibleCalendarEvents:[CalendarEventItem] {events.filter {isSourceVisible($0.calendarID ?? $0.calendarName)}}
    var overviewEvents:[CalendarEventItem] {overviewEventValues.filter {isSourceVisible($0.calendarID ?? $0.calendarName)}}
    var todayItems:[CalendarAgendaEntry] {ReminderQueries.entries(reminders:reminders,events:todayEvents.filter {isSourceVisible($0.calendarID ?? $0.calendarName)},filter:.day,day:Date(),calendar:displayCalendar)}
    var visibleEntries:[CalendarAgendaEntry] {ReminderQueries.entries(reminders:reminders,events:visibleCalendarEvents,filter:filter,day:selectedDay,search:search,calendar:displayCalendar)}
    var selectedEntries:[CalendarAgendaEntry] {ReminderQueries.entries(reminders:reminders,events:visibleCalendarEvents,filter:.day,day:selectedDay,calendar:displayCalendar)}
    var monthEntries:[CalendarAgendaEntry] {
        guard let interval=displayCalendar.dateInterval(of:.month,for:displayedMonth) else {return []}
        return ReminderQueries.entries(reminders:reminders,events:visibleCalendarEvents,filter:.all,day:selectedDay,calendar:displayCalendar).filter {
            if case .event(let event)=$0 {return event.start < interval.end && event.end > interval.start}
            return ReminderQueries.displayDate(for:$0,calendar:displayCalendar).map(interval.contains) ?? false
        }
    }
    var allReminderEntries:[CalendarAgendaEntry] {
        let items=reminders.filter {reminderListSource == "all" || (reminderListSource == "local" && $0.origin == .local) || (reminderListSource == "system" && $0.origin == .system)}
        return ReminderQueries.entries(reminders:items,events:[],filter:filter == .day ? .all:filter,day:selectedDay,search:search,calendar:displayCalendar)
    }
    var monthDays:[Date] {ReminderQueries.monthDays(containing:displayedMonth,calendar:displayCalendar)}
    var weekDays:[Date] {ReminderQueries.weekDays(containing:selectedDay,calendar:displayCalendar)}
    var eventInterval:DateInterval {
        let days=monthDays;let start=days.first ?? displayCalendar.startOfDay(for:displayedMonth)
        return DateInterval(start:start,end:displayCalendar.date(byAdding:.day,value:1,to:days.last ?? start)!)
    }
    var overviewInterval:DateInterval {
        let start=displayCalendar.startOfDay(for:Date())
        return DateInterval(start:start,end:displayCalendar.date(byAdding:.day,value:7,to:start)!)
    }
    var monthCount:Int {monthEntries.count}
    func isSourceVisible(_ id:String)->Bool {!hiddenSources.contains(id)}
    func setSourceVisible(_ id:String,_ visible:Bool) {
        guard displayPreferencesError == nil else {errorMessage=displayPreferencesError;return}
        var next=hiddenSources;if visible {next.remove(id)} else {next.insert(id)}
        do {
            let data=try JSONEncoder().encode(CalendarDisplayPreferences(hiddenSources:next))
            try FileManager.default.createDirectory(at:displayPreferencesURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try data.write(to:displayPreferencesURL,options:.atomic);hiddenSources=next
        } catch {errorMessage="无法保存日历显示偏好：\(error.localizedDescription)"}
    }
    var connectedSourceCount:Int { (preferences.calendarConnected && calendarAccess == .granted ? 1:0)+(preferences.remindersConnected && remindersAccess == .granted ? 1:0) }
    var canRecoverBackup:Bool { (try? store.decode(Data(contentsOf:store.backupURL))) != nil }
    func count(on day:Date) -> Int { ReminderQueries.entries(reminders:reminders,events:visibleCalendarEvents,filter:.day,day:day,calendar:displayCalendar).count }
    func openNewReminder() {
        guard storageError == nil else { errorMessage=storageError; return }
        errorMessage=nil
        let due=filter == .undated ? nil:ReminderDue(date:selectedDay,includesTime:false,calendar:displayCalendar)
        editor=CalendarReminderDraft(item:ReminderItem(title:"",due:due),creating:true,defaultDate:selectedDay,calendar:displayCalendar)
    }
    func openReminder(_ reminder:ReminderItem) { errorMessage=nil; editor=CalendarReminderDraft(item:reminder,creating:false,defaultDate:selectedDay,calendar:displayCalendar) }
    func cancelEditor() {
        guard !isWorking else { return }
        errorMessage=nil
        editor=nil
    }
    func openSources(fromSettingsPrivacy:Bool=false) {sourcesReturnToPrivacy=fromSettingsPrivacy;showSources=true}
    func selectDay(_ date:Date) { selectedDay=date; filter = .day; if !displayCalendar.isDate(date,equalTo:displayedMonth,toGranularity:.month) { displayedMonth=date; Task { await refresh() } } }
    func changeMonth(_ delta:Int) { if let date=displayCalendar.date(byAdding:.month,value:delta,to:displayedMonth) {displayedMonth=date;selectedDay=displayCalendar.dateInterval(of:.month,for:date)?.start ?? date;filter = .day;Task {await refresh()}} }
    func goToToday() { displayedMonth=Date(); selectedDay=Date(); filter = .day; Task { await refresh() } }
    private func syncLocal() { if let snapshot=service?.snapshot { localReminders=snapshot.reminders; preferences=snapshot.preferences } }
    private func requireService() throws -> ReminderService { guard let service else { throw ReminderError.unavailable(storageError ?? "本机提醒数据不可用。") }; return service }
    func refresh() async {
        refreshVersion += 1; let version=refreshVersion; isLoading=true
        calendarAccess=system.access(reminders:false); remindersAccess=system.access(reminders:true)
        if preferences.calendarConnected && calendarAccess == .granted {
            do { events=try system.events(in:eventInterval) } catch { errorMessage="系统日历读取失败：\(error.localizedDescription)" }
            // Overview and desktop cards must keep today's events even while the
            // calendar page browses a different month. Query a separate bounded day.
            if let today=displayCalendar.dateInterval(of:.day,for:Date()) {
                do { todayEvents=try system.events(in:today) } catch { errorMessage="今日系统日历读取失败：\(error.localizedDescription)" }
            }
            do {overviewEventValues=try system.events(in:overviewInterval)} catch {errorMessage="首页七天日历读取失败：\(error.localizedDescription)"}
            calendarSources=system.calendarSources()
            let known=Set(calendarSources.map(\.id))
            let inferred=Dictionary(grouping:events+todayEvents+overviewEventValues,by:{$0.calendarID ?? $0.calendarName})
            calendarSources += inferred.filter {!known.contains($0.key)}.map {CalendarSourceDescriptor(id:$0.key,title:$0.value.first?.calendarName ?? "系统日历")}.sorted {$0.title < $1.title}
        } else {events=[];todayEvents=[];overviewEventValues=[];calendarSources=[]}
        if preferences.remindersConnected && remindersAccess == .granted {
            do {
                let loaded=try await system.reminders()
                guard version == refreshVersion else { return }
                if preferences.remindersConnected && system.access(reminders:true) == .granted { systemReminders=loaded; writableCalendars=system.writableReminderCalendars() }
            } catch { if version == refreshVersion { errorMessage="系统提醒事项读取失败：\(error.localizedDescription)" } }
        } else { systemReminders=[]; writableCalendars=[] }
        let access=await notifier.access()
        guard version == refreshVersion else { return }
        notificationAccess=access; isLoading=false; scheduleNotifications()
    }
    func connect(reminders:Bool) async {
        guard !isWorking else { return }; isWorking=true; defer { isWorking=false }
        do {
            let allowed=try await system.requestAccess(reminders:reminders)
            if reminders { remindersAccess=system.access(reminders:true) } else { calendarAccess=system.access(reminders:false) }
            guard allowed else { errorMessage="未允许访问\(reminders ? "提醒事项":"日历")。本机提醒仍可正常使用。你可以在系统设置的隐私与安全性中更改权限。"; return }
            var next=preferences; if reminders { next.remindersConnected=true } else { next.calendarConnected=true }
            try requireService().setPreferences(next); syncLocal(); await refresh()
        } catch { errorMessage=error.localizedDescription }
    }
    func disconnect(reminders:Bool) async {
        guard !isWorking else { return }; isWorking=true; defer { isWorking=false }
        do {
            var next=preferences; if reminders { next.remindersConnected=false } else { next.calendarConnected=false }
            try requireService().setPreferences(next); syncLocal(); await refresh()
        } catch { errorMessage=error.localizedDescription }
    }
    func saveDraft(_ draft:CalendarReminderDraft) async -> Bool {
        guard !isWorking else { return false }; isWorking=true; defer { isWorking=false }
        errorMessage=nil
        do {
            let result=try requireService().save(draft.value(),creating:draft.creating)
            syncLocal(); updateSystem(result)
            if let date=ReminderQueries.displayDate(for:.reminder(result),calendar:displayCalendar) { selectedDay=date; displayedMonth=date; filter = .day } else { filter = .undated }
            errorMessage=nil; editor=nil; undo=nil; undoMessage=nil; scheduleNotifications(); await refresh(); return true
        } catch { errorMessage=error.localizedDescription; return false }
    }
    func toggle(_ item:ReminderItem) async {
        guard !isWorking,item.isWritable else { return }; isWorking=true; defer { isWorking=false }
        do {
            var next=item; next.isCompleted.toggle(); next.completedAt=next.isCompleted ? Date():nil; next.updatedAt=Date()
            let saved=try requireService().save(next,creating:false)
            syncLocal(); updateSystem(saved); undo = .changed(item); undoMessage=saved.isCompleted ? "已完成「\(item.title)」":"已移回待办"; scheduleNotifications()
        } catch { errorMessage=error.localizedDescription }
    }
    func delete(_ item:ReminderItem) async -> Bool {
        guard !isWorking else { return false }; isWorking=true; defer { isWorking=false }
        do {
            try requireService().delete(item); syncLocal(); systemReminders.removeAll { $0.stableID == item.stableID }
            undo = .deleted(item); undoMessage="已删除「\(item.title)」"; editor=nil; scheduleNotifications(); return true
        } catch { errorMessage=error.localizedDescription; return false }
    }
    func undoLastChange() async {
        guard let undo,!isWorking else { return }; isWorking=true; defer { isWorking=false }
        do {
            let restored:ReminderItem
            switch undo {
            case .changed(let item):restored=try requireService().save(item,creating:false)
            case .deleted(let item):restored=try requireService().save(item,creating:item.origin == .system)
            }
            syncLocal(); updateSystem(restored); self.undo=nil; undoMessage=nil; scheduleNotifications()
        } catch { errorMessage="撤销失败，操作记录仍保留：\(error.localizedDescription)" }
    }
    private func updateSystem(_ item:ReminderItem) {
        guard item.origin == .system else { return }
        if let index=systemReminders.firstIndex(where:{$0.id == item.id}) { systemReminders[index]=item } else { systemReminders.append(item) }
    }
    func enableNotifications() async {
        guard !isWorking else { return }; isWorking=true; defer { isWorking=false }
        do {
            let allowed=try await notifier.requestAccess(); notificationAccess=await notifier.access()
            guard allowed else { errorMessage="通知未获允许。本机提醒仍会保存；可在系统设置的通知中允许方寸。"; return }
            var next=preferences; next.notificationsEnabled=true
            try requireService().setPreferences(next); syncLocal(); scheduleNotifications(); showNotifications=false
        } catch { errorMessage="无法开启通知：\(error.localizedDescription)" }
    }
    func disableNotifications() {
        do { var next=preferences; next.notificationsEnabled=false; try requireService().setPreferences(next); syncLocal(); scheduleNotifications() }
        catch { errorMessage=error.localizedDescription }
    }
    /// Only this provider's namespaced local notifications are removed. EventKit
    /// reminder alarms remain owned by Reminders and are never touched here.
    /// Freeze before awaiting any health/file transaction. EventKit, activation,
    /// day-change and in-flight refreshes cannot create a replacement plan.
    func freezeOwnNotificationsForQuit() {
        ownNotificationsSuspendedForQuit=true
        notificationsNeedRefresh=false
        notificationTask?.cancel()
    }
    func suspendOwnNotificationsForQuit() async throws {
        freezeOwnNotificationsForQuit()
        if let task=notificationTask {await task.value}
        notificationTask=nil
        try await notifier.replacePending([])
    }
    func resumeOwnNotificationsAfterCancelledQuit() {
        guard ownNotificationsSuspendedForQuit else {return}
        ownNotificationsSuspendedForQuit=false
        scheduleNotifications()
    }
    private func scheduleNotifications() {
        guard !ownNotificationsSuspendedForQuit else {return}
        notificationsNeedRefresh=true
        guard notificationTask == nil else { return }
        notificationTask=Task { [weak self] in
            guard let self else { return }
            while self.notificationsNeedRefresh && !Task.isCancelled && !self.ownNotificationsSuspendedForQuit {
                self.notificationsNeedRefresh=false
                let active=self.preferences.notificationsEnabled && self.notificationAccess == .granted
                let all=ReminderNotificationPlan.pending(self.localReminders,limit:Int.max)
                do {
                    try await self.notifier.replacePending(active ? Array(all.prefix(60)):[])
                    self.notificationMessage=active && all.count > 60 ? "已安排最近 60 条通知，其余会在下次打开工作台时补充。":nil
                } catch { self.notificationMessage="提醒已保存，但通知安排失败：\(error.localizedDescription)" }
            }
            self.notificationTask=nil
        }
    }
    func recoverBackup() {
        do {
            _=try store.recoverBackup(); service=try ReminderService(store:store,system:system); storageError=nil; syncLocal()
            Task { await refresh() }
        } catch { errorMessage="无法恢复提醒备份：\(error.localizedDescription)" }
    }
    func openSystemCalendar() {NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Calendar.app"))}
    func openPrivacySettings(reminders:Bool) {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?\(reminders ? "Privacy_Reminders":"Privacy_Calendars")") { NSWorkspace.shared.open(url) }
    }
    func openNotificationSettings() {
        if let url=URL(string:"x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
