import SwiftUI
import LauncherCore

/// The home month remains compact; selecting a day reveals its real records
/// without changing the independent all-pending list below it.
struct WorkbenchHomeCalendar: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var context: WorkbenchContextModel
    @Binding var selectedDay: Date?
    var navigate: (WorkbenchRoute) -> Void
    @State private var displayedMonth = Date()
    @State private var showingDay = false

    private var calendar: Calendar { context.dateContext.calendar }
    private var selection: Date { selectedDay ?? Date() }
    private var days: [Date] {
        guard let first = calendar.dateInterval(of: .month, for: displayedMonth)?.start else { return [] }
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: first) }
    }
    private var knownEvents: [CalendarEventItem] { HomeCalendarContent.events(model) }
    private var dayEntries: [CalendarAgendaEntry] {
        CalendarWorkspaceQueries.selectedDay(reminders: model.reminders, events: knownEvents, day: selection, calendar: calendar)
    }

    var body: some View {
        let events = knownEvents
        let pending = model.reminders.filter { !$0.isCompleted }
        VStack(spacing: 0) {
            monthHeader.padding(.bottom, 7)
            HStack(spacing: 3) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { text in
                    Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.68))
                        .frame(maxWidth: .infinity).frame(height: 25)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: 7), spacing: 3) {
                ForEach(days, id: \.self) { date in dayButton(date, events: events, reminders: pending) }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        .frame(maxWidth: .infinity).frame(height: 301)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(LinearGradient(
                colors: [Color(red: 3/255, green: 80/255, blue: 106/255).opacity(0.35),
                         Color(red: 3/255, green: 59/255, blue: 87/255).opacity(0.37)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .padding(5)
        .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(.white.opacity(0.28), lineWidth: 1))
        .frame(height: 311)
        .popover(isPresented: $showingDay, arrowEdge: .leading) { dayPopover }
        .onAppear {
            displayedMonth = selection
            if !calendar.isDate(model.displayedMonth, equalTo: selection, toGranularity: .month) { model.selectDay(selection) }
        }
        .onChange(of: context.dateContext) { _, _ in
            selectedDay = nil; displayedMonth = Date(); showingDay = false
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("fc.home.calendar")
    }

    private var monthHeader: some View {
        HStack(spacing: 4) {
            Text(HomeCalendarContent.format(displayedMonth, "yyyy年M月", calendar: calendar))
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 25, height: 28) }
                .accessibilityLabel("上个月").accessibilityIdentifier("fc.home.calendar.previous")
            Button("今天") {
                displayedMonth = Date(); selectedDay = nil; model.goToToday()
            }.frame(height: 28).accessibilityIdentifier("fc.home.calendar.today")
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 25, height: 28) }
                .accessibilityLabel("下个月").accessibilityIdentifier("fc.home.calendar.next")
        }
        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.92))
        .buttonStyle(HomeCalendarControlStyle()).frame(height: 28)
    }

    private func dayButton(_ date: Date, events knownEvents: [CalendarEventItem], reminders pending: [ReminderItem]) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selection)
        let today = calendar.isDate(date, inSameDayAs: Date())
        let outside = !calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        let events = knownEvents.filter { $0.occurs(on: date, calendar: calendar) }.count
        let reminders = pending.filter { ReminderQueries.occurs(reminder: $0, on: date, calendar: calendar) }.count
        let civil = CalendarCivilDay(date: date, calendar: calendar, showsHolidays: model.holidaysEnabled)
        let dateLabel = HomeCalendarContent.format(date, "yyyy年M月d日", calendar: calendar)
        let help = [dateLabel, civil.label, civil.badge.map { $0 == "班" ? "调休上班" : "放假" },
                    events + reminders > 0 ? "\(events) 项日程 · \(reminders) 项待办" : nil].compactMap { $0 }.joined(separator: " · ")
        return Button {
            selectedDay = date; displayedMonth = date; model.selectDay(date); showingDay = true
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .frame(maxWidth: .infinity).frame(height: 34)
                .overlay(alignment: .topTrailing) {
                    if let badge = civil.badge {
                        Text(badge).font(.system(size: 8, weight: .medium))
                            .foregroundStyle(badge == "班" ? Color(red: 0.65, green: 0.32, blue: 0.15) : HomeFluidPalette.green)
                            .frame(width: 11, height: 11)
                            .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 3))
                            .padding(.top, 1).padding(.trailing, 1).accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottom) {
                    if events + reminders > 0 {
                        Circle().fill(selected ? HomeFluidPalette.green : .white.opacity(0.9))
                            .frame(width: 3, height: 3).padding(.bottom, 4)
                    }
                }
        }
        .buttonStyle(HomeCalendarDateStyle(selected: selected, today: today, outside: outside))
        .help(help).accessibilityLabel(help)
        .accessibilityValue(selected ? "已选择" : today ? "今天" : "未选择")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("fc.home.calendar.day." + HomeCalendarContent.format(date, "yyyy-MM-dd", calendar: calendar))
    }

    private func moveMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth),
              let first = calendar.dateInterval(of: .month, for: next)?.start else { return }
        displayedMonth = first; selectedDay = first; showingDay = false; model.selectDay(first)
    }

    private var dayPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(HomeCalendarContent.format(selection, "M月d日 EEEE", calendar: calendar)).font(.system(size: 13, weight: .medium))
                    Text(CalendarCivilDay(date: selection, calendar: calendar, showsHolidays: model.holidaysEnabled).label)
                        .font(.system(size: 11)).foregroundStyle(HomeFluidPalette.secondary)
                }
                Spacer(minLength: 8)
                Button { showingDay = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(WBIconButtonStyle(size: 28)).accessibilityLabel("关闭当天安排")
            }
            if !dayEntries.isEmpty {
                WorkbenchScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(dayEntries) { entry in
                            HomeCalendarEntryRow(entry: entry, model: model, context: context) { showingDay = false }
                        }
                    }
                }.frame(height: min(240, CGFloat(dayEntries.count) * 52))
            } else {
                Text(model.isLoading ? "正在读取这一天的安排…" : "这一天没有已读取的日程或待办")
                    .font(.system(size: 12)).foregroundStyle(HomeFluidPalette.secondary).padding(.vertical, 14)
            }
            if !model.preferences.calendarConnected || model.calendarAccess != .granted {
                Text("系统日历未连接，本机待办仍可使用。")
                    .font(.system(size: 11)).foregroundStyle(HomeFluidPalette.muted)
            } else if model.overviewReadError != nil || model.remindersReadError != nil {
                Text("部分来源读取失败，可在日历中查看详情。")
                    .font(.system(size: 11)).foregroundStyle(HomeFluidPalette.muted)
            }
            HStack {
                Button("新建待办") { showingDay = false; model.selectDay(selection); model.openNewReminder() }
                    .buttonStyle(WBButtonStyle(compact: true)).disabled(model.storageError != nil)
                Spacer()
                Button("查看日历") { showingDay = false; model.selectDay(selection); navigate(.calendar) }
                    .buttonStyle(WBQuietButtonStyle())
            }
        }
        .padding(16).frame(width: 340).foregroundStyle(HomeFluidPalette.ink)
        .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.87, backgroundMotion: false, appearance: .light)
        .accessibilityElement(children: .contain).accessibilityIdentifier("fc.home.calendar.dayDetails")
    }
}

struct WorkbenchHomeReminders: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var context: WorkbenchContextModel
    var navigate: (WorkbenchRoute) -> Void

    private var entries: [CalendarAgendaEntry] { HomeCalendarContent.pending(model, calendar: context.dateContext.calendar) }
    private var reminderCount: Int { model.reminders.filter { !$0.isCompleted }.count }
    private var sourceStatus: String? {
        if let error = model.storageError { return error }
        if model.remindersReadError != nil || model.overviewReadError != nil { return "部分来源读取失败" }
        if model.isLoading { return "正在同步日历与待办" }
        if model.preferences.calendarConnected && model.calendarAccess == .granted {
            let interval = model.overviewInterval
            let covered = model.overviewLoadedInterval.map { $0.start <= interval.start && $0.end >= interval.end } ?? false
            if !covered { return "近期日程待读取" }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "checklist").font(.system(size: 16, weight: .light)).foregroundStyle(HomeFluidPalette.secondary)
                Text("待办事项").font(.system(size: 12, weight: .medium))
                Text("\(reminderCount)").font(.system(size: 11, weight: .medium)).foregroundStyle(HomeFluidPalette.green)
                    .padding(.horizontal, 6).frame(height: 21)
                    .background(HomeFluidPalette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .help("全部未完成待办，包含逾期与无期限；近期日程另以日历图标显示。")
                Spacer(minLength: 4)
                Button { model.selectDay(Date()); model.openNewReminder() } label: { Image(systemName: "plus") }
                    .buttonStyle(WBIconButtonStyle(size: 28)).disabled(model.storageError != nil)
                    .accessibilityLabel("新建待办").accessibilityIdentifier("fc.home.reminders.add")
            }.frame(height: 28).accessibilityElement(children: .contain)
                .accessibilityIdentifier("fc.home.reminders.header").padding(.bottom, 10)
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Text(model.isLoading ? "正在读取待办…" : "暂时没有待办")
                        .font(.system(size: 12)).foregroundStyle(HomeFluidPalette.secondary)
                    if model.needsSystemConnection {
                        Button("连接系统日历与提醒") { model.openSources(); navigate(.calendar) }
                            .font(.system(size: 11)).buttonStyle(WBQuietButtonStyle())
                    } else {
                        Text("想到什么，随手记下来。")
                            .font(.system(size: 11)).foregroundStyle(HomeFluidPalette.muted)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WorkbenchScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(entries) { entry in HomeCalendarEntryRow(entry: entry, model: model, context: context) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(HomeFluidPalette.ink.opacity(0.09)).frame(height: 1).padding(.top, 10).padding(.bottom, 9)
            footer.frame(height: 20)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("fc.home.reminders.content")
        .padding(14).frame(maxWidth: .infinity).frame(height: 261)
        .foregroundStyle(HomeFluidPalette.ink).background(WorkbenchHomeSurface())
        .accessibilityElement(children: .contain).accessibilityIdentifier("fc.home.reminders")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let message = model.undoMessage {
                Text(message).lineLimit(1).help(message)
                Spacer(minLength: 4)
                Button("撤销") { Task { await model.undoLastChange() } }
                    .buttonStyle(WBQuietButtonStyle()).disabled(model.isWorking)
                    .accessibilityIdentifier("fc.home.reminders.undo")
            } else {
                Text(sourceStatus ?? "全部未完成 · 含无期限").lineLimit(1).help(sourceStatus ?? "日历选择不会筛掉待办；完整列表可在卡片内滚动查看。")
                Spacer(minLength: 4)
                Button("查看日历") { navigate(.calendar) }.buttonStyle(WBQuietButtonStyle())
                    .accessibilityIdentifier("fc.home.reminders.openCalendar")
            }
        }.font(.system(size: 11)).foregroundStyle(HomeFluidPalette.muted)
    }
}

private struct HomeCalendarEntryRow: View {
    let entry: CalendarAgendaEntry
    @ObservedObject var model: CalendarModel
    @ObservedObject var context: WorkbenchContextModel
    var beforeOpen: () -> Void = {}
    private var color: Color { HomeCalendarContent.color(entry) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if case .reminder(let item) = entry {
                Button { Task { await model.toggle(item) } } label: {
                    ZStack {
                        Circle().strokeBorder(color, lineWidth: 1.5)
                        if item.isCompleted {
                            Circle().fill(color)
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        }
                    }.frame(width: 15, height: 15).frame(width: 20, height: 30)
                }
                .buttonStyle(ClickablePlainButtonStyle()).disabled(model.isWorking || !item.isWritable)
                .accessibilityLabel((item.isCompleted ? "恢复" : "完成") + item.title)
                .accessibilityIdentifier("fc.home.reminder.toggle." + item.stableID)
                .help(item.isWritable ? "颜色按本机／系统来源类型区分，不代表来源自定义颜色。" : "这条系统提醒为只读")
            } else {
                Image(systemName: "calendar").font(.system(size: 15)).foregroundStyle(color).frame(width: 20, height: 30)
                    .accessibilityLabel("系统日程，只读")
            }
            Button {
                beforeOpen()
                switch entry {
                case .reminder(let item): model.openReminder(item)
                case .event(let event): model.selectedEvent = event
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 12)).strikethrough(entry.isCompleted).lineLimit(1)
                        .foregroundStyle(entry.isCompleted ? HomeFluidPalette.muted : HomeFluidPalette.ink)
                    Text(HomeCalendarContent.subtitle(entry, context: context)).font(.system(size: 11))
                        .foregroundStyle(HomeFluidPalette.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 48, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ClickablePlainButtonStyle())
            .help(entry.title + "\n" + HomeCalendarContent.subtitle(entry, context: context))
        }.frame(height: 48).accessibilityElement(children: .contain)
    }
}

private enum HomeCalendarContent {
    @MainActor static func events(_ model: CalendarModel) -> [CalendarEventItem] {
        let today = model.todayEvents.filter { model.isSourceVisible($0.calendarID ?? $0.calendarName) }
        return Array(Dictionary((model.visibleCalendarEvents + model.overviewEvents + today).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    @MainActor static func pending(_ model: CalendarModel, calendar: Calendar) -> [CalendarAgendaEntry] {
        let reminders = model.reminders.filter { !$0.isCompleted }.map(CalendarAgendaEntry.reminder)
        let interval = model.overviewInterval
        let covered = model.overviewLoadedInterval.map { $0.start <= interval.start && $0.end >= interval.end } ?? false
        let events = covered ? model.overviewEvents.filter { $0.start < interval.end && max($0.end, $0.start.addingTimeInterval(1)) > Date() }.map(CalendarAgendaEntry.event) : []
        return (reminders + events).sorted {
            let lhs = ReminderQueries.displayDate(for: $0, calendar: calendar) ?? .distantFuture
            let rhs = ReminderQueries.displayDate(for: $1, calendar: calendar) ?? .distantFuture
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }

    // Calendar/Reminder models do not currently carry EventKit colors. These
    // colors describe source type, never a guessed source name or custom color.
    static func color(_ entry: CalendarAgendaEntry) -> Color {
        switch entry {
        case .event: Color(red: 0.20, green: 0.52, blue: 0.69)
        case .reminder(let item): item.origin == .local ? Color(red: 0.70, green: 0.51, blue: 0.25) : HomeFluidPalette.green
        }
    }

    @MainActor static func subtitle(_ entry: CalendarAgendaEntry, context: WorkbenchContextModel) -> String {
        let calendar = context.dateContext.calendar
        let dateText: String
        if let date = ReminderQueries.displayDate(for: entry, calendar: calendar) {
            if calendar.isDate(date, inSameDayAs: Date()) { dateText = "今天" }
            else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()), calendar.isDate(date, inSameDayAs: tomorrow) { dateText = "明天" }
            else { dateText = format(date, calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日", calendar: calendar) }
        } else { dateText = "无期限" }
        switch entry {
        case .reminder(let item):
            let time = item.due?.hasTime == true ? item.due?.date.map { " " + context.time($0) } ?? "" : ""
            return dateText + time + " · " + item.sourceTitle + (item.isWritable ? "" : " · 只读")
        case .event(let event):
            return dateText + " " + (event.isAllDay ? "全天" : context.time(event.start) + "–" + context.time(event.end)) + " · 日程 · " + event.calendarName
        }
    }

    static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

private struct HomeCalendarControlStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 2)
            .background(.white.opacity(configuration.isPressed ? 0.20 : hovering ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6)).onHover { hovering = $0 }.clickableCursor()
    }
}

private struct HomeCalendarDateStyle: ButtonStyle {
    let selected: Bool
    let today: Bool
    let outside: Bool
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? HomeFluidPalette.green : .white.opacity(outside ? 0.38 : 0.94))
            .background(selected ? Color.white.opacity(configuration.isPressed ? 0.87 : 1) : .white.opacity(configuration.isPressed ? 0.22 : hovering ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(today && !selected ? 0.38 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6)).onHover { hovering = $0 }.clickableCursor()
    }
}
