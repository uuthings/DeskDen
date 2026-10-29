import Foundation

/// The selected day and the rolling seven-day list are independent views of the
/// same records. A source selection never changes the calendar's visible day.
public enum CalendarWorkspaceQueries {
    public static func selectedDay(reminders: [ReminderItem], events: [CalendarEventItem], day: Date, calendar: Calendar) -> [CalendarAgendaEntry] {
        let reminders = reminders.filter { ReminderQueries.occurs(reminder: $0, on: day, calendar: calendar) }.map(CalendarAgendaEntry.reminder)
        return sorted(reminders + events.filter { $0.occurs(on: day, calendar: calendar) }.map(CalendarAgendaEntry.event), calendar: calendar)
    }

    public static func upcoming(reminders: [ReminderItem], events: [CalendarEventItem], interval: DateInterval, source: String = "all", calendar: Calendar) -> [CalendarAgendaEntry] {
        let reminders = reminders.filter { item in
            guard !item.isCompleted, let date = ReminderQueries.displayDate(for: .reminder(item), calendar: calendar) else { return false }
            return date >= interval.start && date < interval.end
        }.map(CalendarAgendaEntry.reminder)
        let events = events.filter { $0.start < interval.end && max($0.end, $0.start.addingTimeInterval(1)) > interval.start }.map(CalendarAgendaEntry.event)
        return sorted((reminders + events).filter { source == "all" || sourceKey($0) == source }, calendar: calendar)
    }

    public static func sourceKey(_ entry: CalendarAgendaEntry) -> String {
        switch entry {
        case .event(let event): "event:" + (event.calendarID ?? event.calendarName)
        case .reminder(let item): item.origin == .local ? "local" : "reminder:" + (item.calendarID ?? item.calendarName ?? "system")
        }
    }

    public static func sourceTitle(_ entry: CalendarAgendaEntry) -> String {
        switch entry {
        case .event(let event): "日程 · " + event.calendarName
        case .reminder(let item): item.origin == .local ? "方寸本机" : "待办 · " + (item.calendarName ?? "提醒事项")
        }
    }

    private static func sorted(_ entries: [CalendarAgendaEntry], calendar: Calendar) -> [CalendarAgendaEntry] {
        entries.sorted {
            let a = ReminderQueries.displayDate(for: $0, calendar: calendar) ?? .distantFuture
            let b = ReminderQueries.displayDate(for: $1, calendar: calendar) ?? .distantFuture
            return a == b ? $0.id < $1.id : a < b
        }
    }
}
