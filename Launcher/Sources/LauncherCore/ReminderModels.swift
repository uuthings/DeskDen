import Foundation

public enum ReminderError: LocalizedError, Equatable, Sendable {
    case invalid(String)
    case unavailable(String)
    public var errorDescription: String? { switch self { case .invalid(let message), .unavailable(let message): message } }
}

/// A civil date, with an optional clock time. A day-only reminder is never silently assigned midnight.
public struct ReminderDue: Codable, Hashable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int?
    public var minute: Int?
    public var timeZoneIdentifier: String
    public init(year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil, timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.year = year; self.month = month; self.day = day; self.hour = hour; self.minute = minute; self.timeZoneIdentifier = timeZoneIdentifier
    }
    public init(date: Date, includesTime: Bool, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year,.month,.day,.hour,.minute], from: date)
        self.init(year:c.year!,month:c.month!,day:c.day!,hour:includesTime ? c.hour:nil,minute:includesTime ? c.minute:nil,timeZoneIdentifier:calendar.timeZone.identifier)
    }
    public var hasTime: Bool { hour != nil && minute != nil }
    public var components: DateComponents {
        var c = DateComponents(); c.calendar = Calendar(identifier:.gregorian)
        c.timeZone = TimeZone(identifier:timeZoneIdentifier); c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        return c
    }
    public var date: Date? {
        var c = components
        // Noon makes a day-only value stable across ordinary daylight-saving transitions.
        if !hasTime { c.hour = 12; c.minute = 0 }
        return c.date
    }
    public func isSameDay(as date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.year,.month,.day],from:date)
        return year == c.year && month == c.month && day == c.day
    }
    public func validate() throws {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day), TimeZone(identifier:timeZoneIdentifier) != nil,
              (hour == nil) == (minute == nil), hour.map({(0...23).contains($0)}) ?? true, minute.map({(0...59).contains($0)}) ?? true,
              let date else { throw ReminderError.invalid("提醒的日期或时间无效。") }
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:timeZoneIdentifier)!
        let c = calendar.dateComponents([.year,.month,.day,.hour,.minute],from:date)
        guard c.year == year, c.month == month, c.day == day, !hasTime || (c.hour == hour && c.minute == minute) else {
            throw ReminderError.invalid("这个日期或时间不存在，请检查日期与夏令时设置。")
        }
    }
}

public enum ReminderOrigin: String, Codable, Sendable { case local, system }
public struct ReminderItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var origin: ReminderOrigin
    public var calendarID: String?
    public var calendarName: String?
    public var title: String
    public var notes: String
    public var due: ReminderDue?
    public var isCompleted: Bool
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var isWritable: Bool
    /// A per-reminder choice; the global notification switch is an independent gate.
    public var notificationsEnabled: Bool
    public init(id:String = UUID().uuidString, origin:ReminderOrigin = .local, calendarID:String? = nil, calendarName:String? = nil, title:String, notes:String = "", due:ReminderDue? = nil, isCompleted:Bool = false, completedAt:Date? = nil, createdAt:Date = Date(), updatedAt:Date = Date(), isWritable:Bool = true, notificationsEnabled:Bool = true) {
        self.id=id; self.origin=origin; self.calendarID=calendarID; self.calendarName=calendarName; self.title=title; self.notes=notes; self.due=due; self.isCompleted=isCompleted; self.completedAt=completedAt; self.createdAt=createdAt; self.updatedAt=updatedAt; self.isWritable=isWritable; self.notificationsEnabled=notificationsEnabled
    }
    private enum CodingKeys:String,CodingKey {case id,origin,calendarID,calendarName,title,notes,due,isCompleted,completedAt,createdAt,updatedAt,isWritable,notificationsEnabled}
    public init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        id=try values.decode(String.self,forKey:.id);origin=try values.decode(ReminderOrigin.self,forKey:.origin)
        calendarID=try values.decodeIfPresent(String.self,forKey:.calendarID);calendarName=try values.decodeIfPresent(String.self,forKey:.calendarName)
        title=try values.decode(String.self,forKey:.title);notes=try values.decode(String.self,forKey:.notes)
        due=try values.decodeIfPresent(ReminderDue.self,forKey:.due);isCompleted=try values.decode(Bool.self,forKey:.isCompleted)
        completedAt=try values.decodeIfPresent(Date.self,forKey:.completedAt);createdAt=try values.decode(Date.self,forKey:.createdAt)
        updatedAt=try values.decode(Date.self,forKey:.updatedAt);isWritable=try values.decode(Bool.self,forKey:.isWritable)
        notificationsEnabled=try values.decodeIfPresent(Bool.self,forKey:.notificationsEnabled) ?? true
    }
    public var stableID:String { "\(origin.rawValue):\(id)" }
    public var sourceTitle:String { origin == .local ? "方寸本机" : "提醒事项 · \(calendarName ?? "系统")" }
    public func validated() throws -> ReminderItem {
        var value = self; value.title = title.trimmingCharacters(in:.whitespacesAndNewlines); value.notes = notes.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.id.isEmpty, !value.title.isEmpty else { throw ReminderError.invalid("请先写下提醒标题。") }
        guard value.title.count <= 120 else { throw ReminderError.invalid("标题不能超过 120 个字符。") }
        guard value.notes.count <= 1000 else { throw ReminderError.invalid("备注不能超过 1000 个字符。") }
        try due?.validate(); return value
    }
}

public struct CalendarEventItem: Identifiable, Hashable, Sendable {
    public var id:String
    public var title:String
    public var notes:String
    public var start:Date
    public var end:Date
    public var isAllDay:Bool
    public var calendarName:String
    public var calendarID:String?
    public var location:String
    public init(id:String,title:String,notes:String = "",start:Date,end:Date,isAllDay:Bool = false,calendarName:String,location:String = "",calendarID:String? = nil) {
        self.id=id; self.title=title; self.notes=notes; self.start=start; self.end=end; self.isAllDay=isAllDay; self.calendarName=calendarName; self.calendarID=calendarID; self.location=location
    }
    public func occurs(on day:Date, calendar:Calendar = .current) -> Bool {
        guard let interval = calendar.dateInterval(of:.day,for:day) else { return false }
        return start < interval.end && max(end,start.addingTimeInterval(1)) > interval.start
    }
}

public enum CalendarAgendaEntry: Identifiable, Hashable, Sendable {
    case reminder(ReminderItem), event(CalendarEventItem)
    public var id:String { switch self { case .reminder(let item): item.stableID; case .event(let event): "event:\(event.id)" } }
    public var title:String { switch self { case .reminder(let item): item.title; case .event(let event): event.title } }
    public var date:Date? { switch self { case .reminder(let item): item.due?.date; case .event(let event): event.start } }
    public var isCompleted:Bool { if case .reminder(let item) = self { return item.isCompleted }; return false }
    public var searchText:String { switch self { case .reminder(let item): return [item.title,item.notes,item.sourceTitle].joined(separator:" "); case .event(let event): return [event.title,event.notes,event.calendarName,event.location].joined(separator:" ") } }
}
public enum ReminderFilter:String, CaseIterable, Identifiable, Sendable {
    case day, all, undated, completed
    public var id:String { rawValue }
    public var title:String { switch self { case .day:"当天"; case .all:"全部"; case .undated:"未定日期"; case .completed:"已完成" } }
}
public enum ReminderQueries {
    public static func entries(reminders:[ReminderItem], events:[CalendarEventItem], filter:ReminderFilter, day:Date, search:String = "", calendar:Calendar = .current) -> [CalendarAgendaEntry] {
        let query = search.trimmingCharacters(in:.whitespacesAndNewlines)
        let reminders = reminders.filter { item in
            switch filter {
            case .completed:return item.isCompleted
            case .undated:return !item.isCompleted && item.due == nil
            case .all:return !item.isCompleted
            case .day:return !item.isCompleted && occurs(reminder:item,on:day,calendar:calendar)
            }
        }.map(CalendarAgendaEntry.reminder)
        let events = events.filter { filter == .all || (filter == .day && $0.occurs(on:day,calendar:calendar)) }.map(CalendarAgendaEntry.event)
        return (reminders+events).filter { query.isEmpty || $0.searchText.range(of:query,options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive]) != nil }.sorted {
            let lhs=displayDate(for:$0,calendar:calendar),rhs=displayDate(for:$1,calendar:calendar)
            if lhs != rhs { return (lhs ?? .distantFuture) < (rhs ?? .distantFuture) }
            return $0.id < $1.id
        }
    }
    /// Timed reminders are instants; date-only reminders keep their civil date
    /// when the workbench display zone changes. Neither query mutates the due.
    public static func occurs(reminder:ReminderItem,on day:Date,calendar:Calendar = .current) -> Bool {
        guard let due=reminder.due else { return false }
        return due.hasTime ? due.date.map {calendar.isDate($0,inSameDayAs:day)} ?? false : due.isSameDay(as:day,calendar:calendar)
    }
    public static func displayDate(for entry:CalendarAgendaEntry,calendar:Calendar = .current) -> Date? {
        if case .reminder(let item)=entry,let due=item.due,!due.hasTime {
            return calendar.date(from:DateComponents(year:due.year,month:due.month,day:due.day,hour:12))
        }
        return entry.date
    }
    public static func weekDays(containing date:Date,calendar:Calendar = .current) -> [Date] {
        let day=calendar.startOfDay(for:date),offset=(calendar.component(.weekday,from:date)+5)%7
        return (0..<7).compactMap {calendar.date(byAdding:.day,value:$0-offset,to:day)}
    }
    public static func monthDays(containing date:Date, calendar:Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of:.month,for:date),let count = calendar.range(of:.day,in:.month,for:date)?.count else { return [] }
        let offset = (calendar.component(.weekday,from:month.start)+5)%7
        let cells = ((count+offset+6)/7)*7
        return (0..<cells).compactMap { calendar.date(byAdding:.day,value:$0-offset,to:month.start) }
    }
    public static func upcoming(_ reminders:[ReminderItem], limit:Int = 5) -> [ReminderItem] {
        reminders.filter { !$0.isCompleted }.sorted {
            if $0.due?.date != $1.due?.date { return ($0.due?.date ?? .distantFuture) < ($1.due?.date ?? .distantFuture) }
            return $0.createdAt < $1.createdAt
        }.prefix(max(0,limit)).map { $0 }
    }
}

public struct ReminderPreferences: Codable, Equatable, Sendable {
    public var calendarConnected = false
    public var remindersConnected = false
    public var notificationsEnabled = false
    public init() {}
}
public struct ReminderSnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public var reminders:[ReminderItem] = []
    public var preferences = ReminderPreferences()
    public init() {}
    public func validate() throws {
        guard version == 1 else { throw ReminderError.invalid("提醒数据由更新版本创建，原文件已保留。") }
        guard reminders.count <= 50_000, Set(reminders.map(\.id)).count == reminders.count, reminders.allSatisfy({$0.origin == .local}) else { throw ReminderError.invalid("本机提醒数据不完整，原文件已保留。") }
        for reminder in reminders { _ = try reminder.validated() }
    }
    public mutating func upsert(_ reminder:ReminderItem) throws {
        let item = try reminder.validated()
        guard item.origin == .local else { throw ReminderError.invalid("系统提醒必须保存到系统来源。") }
        if let index = reminders.firstIndex(where:{$0.id == item.id}) { reminders[index] = item } else { reminders.append(item) }
    }
    public mutating func remove(id:String) -> ReminderItem? {
        guard let index = reminders.firstIndex(where:{$0.id == id}) else { return nil }
        return reminders.remove(at:index)
    }
}
public struct ReminderStore:Sendable {
    public let url:URL
    public var backupURL:URL { url.appendingPathExtension("previous") }
    public init(directory:URL) { url=directory.appendingPathComponent("reminders.json") }
    public func decode(_ data:Data) throws -> ReminderSnapshot {
        guard data.count <= 32_000_000 else { throw ReminderError.invalid("提醒数据过大，原文件已保留。") }
        let value = try JSONDecoder().decode(ReminderSnapshot.self,from:data); try value.validate(); return value
    }
    public func load() throws -> ReminderSnapshot {
        guard FileManager.default.fileExists(atPath:url.path) else { return ReminderSnapshot() }
        return try decode(Data(contentsOf:url))
    }
    public func save(_ value:ReminderSnapshot) throws {
        try value.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 32_000_000 else { throw ReminderError.invalid("提醒数据过大，现有数据未改变。") }
        let fm = FileManager.default
        try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if fm.fileExists(atPath:url.path) {
            let old = try Data(contentsOf:url); _ = try decode(old)
            try old.write(to:backupURL,options:.atomic); try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:backupURL.path)
        }
        try data.write(to:url,options:.atomic); try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    public func recoverBackup() throws -> ReminderSnapshot {
        let data = try Data(contentsOf:backupURL), value = try decode(data)
        if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.copyItem(at:url,to:url.appendingPathExtension("preserved-\(UUID().uuidString)")) }
        try data.write(to:url,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        return value
    }
}

public enum CalendarAccess:String, Sendable { case notDetermined, granted, denied, restricted }
public struct ReminderCalendar:Identifiable, Equatable, Sendable {
    public var id:String
    public var title:String
    public init(id:String,title:String) { self.id=id; self.title=title }
}
public struct CalendarSourceDescriptor:Identifiable,Equatable,Sendable {
    public var id:String
    public var title:String
    public var account:String
    public init(id:String,title:String,account:String = "") {self.id=id;self.title=title;self.account=account}
}
/// Adapters only request permission through an explicit connect action. Tests use a fake provider.
@MainActor public protocol CalendarSystemProviding:AnyObject {
    func access(reminders:Bool) -> CalendarAccess
    func requestAccess(reminders:Bool) async throws -> Bool
    func events(in interval:DateInterval) throws -> [CalendarEventItem]
    func calendarSources() -> [CalendarSourceDescriptor]
    func reminders() async throws -> [ReminderItem]
    func writableReminderCalendars() -> [ReminderCalendar]
    func saveReminder(_ item:ReminderItem, creating:Bool) throws -> ReminderItem
    func deleteReminder(_ item:ReminderItem) throws
}
public extension CalendarSystemProviding {
    func calendarSources() -> [CalendarSourceDescriptor] { [] }
}
public struct ReminderNotification:Equatable, Sendable {
    public var id:String
    public var title:String
    public var notes:String
    public var due:ReminderDue
    public init(id:String,title:String,notes:String,due:ReminderDue) { self.id=id; self.title=title; self.notes=notes; self.due=due }
}
public enum ReminderNotificationPlan {
    public static let prefix = "fangcun.local-reminder."
    public static func pending(_ items:[ReminderItem], now:Date = Date(), limit:Int = 60) -> [ReminderNotification] {
        items.filter { $0.origin == .local && $0.notificationsEnabled && !$0.isCompleted && $0.due?.hasTime == true && ($0.due?.date ?? .distantPast) > now }
            .sorted { $0.due!.date! < $1.due!.date! }.prefix(max(0,limit)).map { ReminderNotification(id:prefix+$0.id,title:$0.title,notes:$0.notes,due:$0.due!) }
    }
}
@MainActor public protocol ReminderNotificationProviding:AnyObject {
    func access() async -> CalendarAccess
    func requestAccess() async throws -> Bool
    func replacePending(_ notifications:[ReminderNotification]) async throws
}

/// The source boundary is deliberately explicit: failed system operations never create local duplicates.
@MainActor public final class ReminderService {
    public let store:ReminderStore
    public let system:any CalendarSystemProviding
    public private(set) var snapshot:ReminderSnapshot
    public init(store:ReminderStore,system:any CalendarSystemProviding) throws { self.store=store; self.system=system; snapshot=try store.load() }
    @discardableResult public func save(_ item:ReminderItem,creating:Bool) throws -> ReminderItem {
        // Completion and undo must preserve imported system titles/notes even when they
        // exceed the editor's input limits. New/edited drafts validate before this layer.
        let valid = item.origin == .system ? item:try item.validated()
        guard !valid.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ReminderError.invalid("请先写下提醒标题。") }
        try valid.due?.validate()
        if valid.origin == .system {
            guard snapshot.preferences.remindersConnected, system.access(reminders:true) == .granted else { throw ReminderError.unavailable("系统提醒事项未接入，提醒尚未保存。") }
            return try system.saveReminder(valid,creating:creating)
        }
        var next=snapshot; try next.upsert(valid); try store.save(next); snapshot=next; return valid
    }
    public func delete(_ item:ReminderItem) throws {
        if item.origin == .system {
            guard snapshot.preferences.remindersConnected, system.access(reminders:true) == .granted else { throw ReminderError.unavailable("系统提醒事项未接入，无法删除。") }
            try system.deleteReminder(item); return
        }
        var next=snapshot; _=next.remove(id:item.id); try store.save(next); snapshot=next
    }
    public func setPreferences(_ preferences:ReminderPreferences) throws { var next=snapshot; next.preferences=preferences; try store.save(next); snapshot=next }
    public func recoverBackup() throws { snapshot=try store.recoverBackup() }
}
