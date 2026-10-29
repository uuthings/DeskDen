import AppKit
import Combine
import SwiftUI
import LauncherCore

struct CalendarModuleView:View {
    @ObservedObject var model:CalendarModel
    var context:WorkbenchContextModel? = nil
    var returnToSettingsPrivacy:(()->Void)?=nil
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchPageWidth) private var width
    @Environment(\.workbenchContentHeight) private var contentHeight
    @State private var introHeight:CGFloat=72
    @State private var messagesHeight:CGFloat=0
    @State private var upcomingSource="all"
    private var compact:Bool {width < 800}
    private var horizontalWorkspace:Bool {width >= 760}
    private var calendarWidth:CGFloat {horizontalWorkspace ? (width-12)*0.45 : width}
    private var sideWidth:CGFloat {max(0,width-calendarWidth-12)}
    private var dayWidth:CGFloat {max(0, (calendarWidth - 28 - 24) / 7)}
    private var dayHeight:CGFloat {max(54,min(72,dayWidth))}
    private var monthHeight:CGFloat {
        let rows = max(1, model.monthDays.count / 7)
        return 104 + CGFloat(rows) * dayHeight + CGFloat(rows - 1) * 4
    }
    private var calendarHeight:CGFloat {model.presentationMode == .month ? min(600,monthHeight) : max(500,min(600,monthHeight))}
    // Read only the shell's real viewport; the page's intrinsic height must not
    // feed back into its own size after a resize or a connection banner appears.
    private var workspaceHeight:CGFloat {max(calendarHeight+172,contentHeight-introHeight-messagesHeight)}
    private var pendingItems:[ReminderItem] {
        model.reminders.filter {!$0.isCompleted && $0.due == nil && (upcomingSource == "all" || CalendarWorkspaceQueries.sourceKey(.reminder($0)) == upcomingSource)}
            .sorted {$0.createdAt == $1.createdAt ? $0.id < $1.id:$0.createdAt > $1.createdAt}
    }
    private var longTermHeight:CGFloat {min(228,max(204,workspaceHeight*0.30))}
    private var selectedItems:[CalendarAgendaEntry] {CalendarWorkspaceQueries.selectedDay(reminders:model.reminders,events:model.visibleCalendarEvents,day:model.selectedDay,calendar:model.displayCalendar)}
    private var upcomingItems:[CalendarAgendaEntry] {CalendarWorkspaceQueries.upcoming(reminders:model.reminders,events:upcomingEvents,interval:upcomingInterval,source:upcomingSource,calendar:model.displayCalendar)}
    private var sourceOptions:[(value:String,title:String)] {
        let entries=model.reminders.map(CalendarAgendaEntry.reminder)+model.overviewEvents.map(CalendarAgendaEntry.event)
        var sources=Dictionary(entries.map{(CalendarWorkspaceQueries.sourceKey($0),CalendarWorkspaceQueries.sourceTitle($0))},uniquingKeysWith:{first,_ in first})
        for source in model.calendarSources where model.isSourceVisible(source.id) {sources["event:"+source.id]="日程 · "+source.title}
        for source in model.writableCalendars {sources["reminder:"+source.id]="待办 · "+source.title}
        return [(value:"all",title:"全部来源")]+sources.map{(value:$0.key,title:$0.value)}.sorted{$0.title < $1.title}
    }
    private var upcomingInterval:DateInterval {model.overviewInterval}
    private var hasUpcomingCoverage:Bool {
        guard let loaded=model.overviewLoadedInterval else {return false}
        return loaded.start <= upcomingInterval.start && loaded.end >= upcomingInterval.end
    }
    private var upcomingEvents:[CalendarEventItem] {
        guard hasUpcomingCoverage else {return []}
        return model.overviewEvents.filter {$0.start < upcomingInterval.end && max($0.end,$0.start.addingTimeInterval(1)) > upcomingInterval.start}
            .sorted {$0.start == $1.start ? $0.id < $1.id:$0.start < $1.start}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            if model.showSources { CalendarSourcesPage(model:model,onBack:{model.showSources=false;if model.sourcesReturnToPrivacy {model.sourcesReturnToPrivacy=false;returnToSettingsPrivacy?()}}) }
            else {
                VStack(alignment:.leading,spacing:0) {
                    WBPageHeader(title:"日历与提醒",subtitle:"安排日程，留出真正重要的时间") {
                        HStack(spacing:8) {
                            if let context {
                                Button {context.showClock=true} label:{Label(zoneTitle,systemImage:"globe")}
                                    .buttonStyle(WBButtonStyle()).accessibilityLabel("更改日历显示时区")
                            }
                            Button {model.errorMessage=nil;model.openSources()} label:{Label("来源",systemImage:"square.3.layers.3d")}.buttonStyle(WBButtonStyle())
                            Button {model.showNewChoice=true} label:{Label("新建",systemImage:"plus")}.buttonStyle(WBButtonStyle(primary:true)).disabled(model.storageError != nil)
                        }
                    }
                    if let error=model.storageError {storageWarning(error).padding(.bottom,12)}
                    if model.needsSystemConnection {systemConnectionCard.padding(.bottom,12)}
                }
                .background(CalendarSectionHeightProbe(section:"intro"))
                if !horizontalWorkspace {
                    VStack(spacing:12) {
                        monthCard.frame(height:calendarHeight)
                        selectedCard.frame(height:220)
                        upcomingCard.frame(height:380)
                        pendingCard.frame(height:216)
                    }.accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.workspace")
                } else {
                    HStack(alignment:.top,spacing:12) {
                        VStack(spacing:12) {
                            monthCard.frame(height:calendarHeight)
                            selectedCard.frame(height:workspaceHeight-calendarHeight-12)
                        }.frame(width:calendarWidth,height:workspaceHeight)
                            .accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.monthColumn")
                        VStack(spacing:12) {
                            upcomingCard.frame(height:workspaceHeight-longTermHeight-12)
                            pendingCard.frame(height:longTermHeight)
                        }.frame(width:sideWidth,height:workspaceHeight)
                            .accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.sideColumn")
                    }.accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.workspace")
                }
                VStack(alignment:.leading,spacing:0) {
                    if let message=model.undoMessage {
                        HStack {Text(message);Spacer();Button("撤销"){Task {await model.undoLastChange()}}.buttonStyle(WBButtonStyle(compact:true)).disabled(model.isWorking)}
                            .font(.system(size:11)).padding(.top,10).accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.undo")
                    }
                    if let message=model.notificationMessage {Text(message).font(.system(size:11)).foregroundStyle(palette.warning).padding(.top,8)}
                }
                .background(CalendarSectionHeightProbe(section:"messages"))
            }
        }.frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(palette.text)
            .onPreferenceChange(CalendarSectionHeightKey.self) {heights in
                if let height=heights["intro"],height.isFinite,height>0,abs(introHeight-height)>0.25 {introHeight=height}
                if let height=heights["messages"],height.isFinite,abs(messagesHeight-height)>0.25 {messagesHeight=height}
            }
            .onChange(of:sourceOptions.map(\.value)) {_,values in if !values.contains(upcomingSource) {upcomingSource="all"}}
            .accessibilityElement(children:.contain).accessibilityIdentifier(model.showSources ? "fc.page.calendar.sources":"fc.page.calendar")
    }
    private var zoneTitle:String {context?.zoneTitle.components(separatedBy:" · ").first ?? model.displayTimeZone.identifier}
    private var systemConnectionCard:some View {
        HStack(alignment:.center,spacing:16) {
            Image(systemName:"calendar.badge.checkmark").font(.system(size:22,weight:.light)).foregroundStyle(palette.accent)
            VStack(alignment:.leading,spacing:5) {
                Text("连接系统日历与提醒事项").font(.system(size:12,weight:.medium))
                Text("直接显示已有日程和待办。接入后，新提醒默认保存到系统列表；原有本机提醒仍然保留。")
                    .font(.system(size:11)).foregroundStyle(palette.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Spacer(minLength:8)
            Button("接入系统") {Task {await model.connectSystemSources()}}.buttonStyle(WBButtonStyle(primary:true))
                .disabled(model.isWorking || model.storageError != nil).accessibilityIdentifier("fc.calendar.connect-system")
            Button("管理") {model.openSources()}.buttonStyle(WBButtonStyle())
        }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(WorkbenchMaterialSurface())
            .accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.system-connection")
    }
    private func storageWarning(_ text:String)->some View {
        HStack(alignment:.top,spacing:8) {
            Image(systemName:"exclamationmark.triangle").foregroundStyle(palette.warning)
            Text(text).font(.system(size:11)).textSelection(.enabled)
            Spacer()
            if model.canRecoverBackup {Button("恢复上次备份"){model.recoverBackup()}.buttonStyle(WBButtonStyle(compact:true))}
        }.padding(14).background(palette.soft,in:RoundedRectangle(cornerRadius:10))
    }
    private var monthCard:some View {
        VStack(spacing:0) {
            monthToolbar.frame(height:47)
            switch model.presentationMode {
            case .month:monthGrid
            case .week:CalendarWeekGrid(model:model)
            case .agenda:monthAgenda
            }
        }.padding(14).background(WorkbenchMaterialSurface()).accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.monthCard")
    }
    private var monthToolbar:some View {
        HStack(spacing:compact ? 4:6) {
            Text(verbatim: "\(model.displayCalendar.component(.year,from:model.displayedMonth)) 年 \(model.displayCalendar.component(.month,from:model.displayedMonth)) 月")
                .font(.system(size:12,weight:.medium)).lineLimit(1).fixedSize(horizontal:true,vertical:false)
            Spacer(minLength:4)
            Button {move(-1)} label:{Image(systemName:"chevron.left")}.buttonStyle(WBIconButtonStyle(size:28)).accessibilityLabel(model.presentationMode == .week ? "上一周":"上个月")
            Button("今天"){model.goToToday()}.buttonStyle(WBButtonStyle(compact:true))
            Button {move(1)} label:{Image(systemName:"chevron.right")}.buttonStyle(WBIconButtonStyle(size:28)).accessibilityLabel(model.presentationMode == .week ? "下一周":"下个月")
            WBSelect("视图",selection:$model.presentationMode,options:CalendarPresentationMode.allCases.map{(value:$0,title:$0.title)}).frame(width:58,height:32).accessibilityIdentifier("fc.calendar.view-mode")
        }
    }
    private func move(_ value:Int) {
        if model.presentationMode == .week,let next=model.displayCalendar.date(byAdding:.day,value:7*value,to:model.selectedDay){model.selectDay(next)}
        else {model.changeMonth(value)}
    }
    private var monthGrid:some View {
        VStack(spacing:0) {
            HStack(spacing:4) {ForEach(["一","二","三","四","五","六","日"],id:\.self){day in Text(day).font(.system(size:11)).foregroundStyle(palette.muted).frame(maxWidth:.infinity)}}.frame(height:24).padding(.bottom,5)
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(minimum:0),spacing:4),count:7),spacing:4) {
                ForEach(model.monthDays,id:\.self){date in CalendarDayCell(model:model,date:date).frame(height:dayHeight)}
            }

        }
    }
    private var monthAgenda:some View {
        WorkbenchScrollView {
            LazyVStack(alignment:.leading,spacing:8) {
                if model.monthEntries.isEmpty {calendarEmpty("这个月还没有安排")}
                ForEach(Array(model.monthEntries.enumerated()),id:\.element.id){index,entry in
                    if index == 0 || dayLabel(model.monthEntries[index-1]) != dayLabel(entry) {
                        Text(dayLabel(entry)).font(.system(size:11,weight:.medium)).foregroundStyle(palette.muted).padding(.top,15).padding(.bottom,3)
                    }
                    CalendarAgendaRow(model:model,entry:entry)
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.scrollBounceBehavior(.basedOnSize).accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.agenda")
    }
    private func dayLabel(_ entry:CalendarAgendaEntry)->String {
        guard let date=ReminderQueries.displayDate(for:entry,calendar:model.displayCalendar) else{return "未定日期"}
        return calendarFormat(date,"M 月 d 日 · EEEE",calendar:model.displayCalendar)
    }
    private var selectedCard:some View {
        CalendarSideCard(title:calendarFormat(model.selectedDay,"M 月 d 日 · EEEE",calendar:model.displayCalendar),symbol:"calendar",scrollIdentifier:"fc.calendar.selected.scroll") {
            let civilDay=CalendarCivilDay(date:model.selectedDay,calendar:model.displayCalendar,showsHolidays:model.holidaysEnabled)
            if let text=civilDay.namedLabel {
                Text(text).font(.system(size:11)).foregroundStyle(civilDay.color(palette)).padding(.horizontal,7).padding(.vertical,5).frame(maxWidth:.infinity,alignment:.leading).background(civilDay.holidayKind == nil ? palette.soft:civilDay.color(palette).opacity(0.08),in:RoundedRectangle(cornerRadius:6)).padding(.bottom,4)
            }
            if selectedItems.isEmpty {
                calendarEmpty("这一天还没有安排")
                HStack {Spacer(minLength:0);Button {model.showNewChoice=true} label:{Label("添加安排",systemImage:"plus")}.buttonStyle(WBButtonStyle(compact:true)).accessibilityIdentifier("fc.calendar.empty.add-action");Spacer(minLength:0)}
            } else {ForEach(selectedItems){CalendarAgendaRow(model:model,entry:$0)}}
        }.accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.selectedAgenda")
    }
    private var pendingCard:some View {
        CalendarSideCard(title:"长期待办",symbol:"tray",scrollIdentifier:"fc.calendar.pending.scroll") {
            if pendingItems.isEmpty {calendarEmpty("暂无长期待办")}
            ForEach(pendingItems){item in CalendarAgendaRow(model:model,entry:.reminder(item),showTime:false)}
            HStack {Spacer(minLength:0);Button("查看全部提醒"){model.filter = .all;model.search="";model.showReminderList=true}.buttonStyle(WBButtonStyle(compact:true)).accessibilityIdentifier("fc.calendar.pending.all-action");Spacer(minLength:0)}.padding(.top,2)
        }.accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.pendingReminders")
    }
    private var upcomingCard:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                VStack(alignment:.leading,spacing:5) {
                    Text("未来七天").font(.system(size:12,weight:.medium))
                    let end=model.displayCalendar.date(byAdding:.day,value:-1,to:upcomingInterval.end) ?? upcomingInterval.start
                    Text(calendarFormat(upcomingInterval.start,"M 月 d 日",calendar:model.displayCalendar)+" — "+calendarFormat(end,"M 月 d 日",calendar:model.displayCalendar))
                        .font(.system(size:11)).foregroundStyle(palette.muted).accessibilityIdentifier("fc.calendar.upcoming.range")
                }
                Spacer(minLength:0)
                WBSelect("全部来源",selection:$upcomingSource,options:sourceOptions).frame(width:146,height:32).accessibilityIdentifier("fc.calendar.upcoming.source")
            }
            WorkbenchScrollView {
                LazyVStack(alignment:.leading,spacing:8) {
                    if !model.preferences.calendarConnected || model.calendarAccess != .granted {
                        upcomingStatus("接入系统日历后，可同时查看七天日程")
                    } else if model.isLoading && !hasUpcomingCoverage {
                        upcomingStatus("正在读取今天起七天的日程")
                    } else if model.overviewReadError != nil {
                        upcomingStatus("七天日程读取失败，请在来源中重试",warning:true)
                    } else if !hasUpcomingCoverage {
                        upcomingStatus("七天日程尚未完整载入，暂不能确认空闲")
                    }
                    if let error=model.remindersReadError {upcomingStatus(error,warning:true)}
                    let entries=upcomingItems
                    if entries.isEmpty {calendarEmpty(upcomingSource == "all" ? "未来七天暂无已载入的安排":"此来源未来七天暂无已载入的安排")}
                    ForEach(Array(entries.enumerated()),id:\.element.id) {index,entry in
                        let day=max(ReminderQueries.displayDate(for:entry,calendar:model.displayCalendar) ?? upcomingInterval.start,upcomingInterval.start)
                        if index == 0 || !model.displayCalendar.isDate(max(ReminderQueries.displayDate(for:entries[index-1],calendar:model.displayCalendar) ?? upcomingInterval.start,upcomingInterval.start),inSameDayAs:day) {
                            Text(calendarFormat(day,"M 月 d 日 · EEEE",calendar:model.displayCalendar))
                                .font(.system(size:11,weight:.medium)).foregroundStyle(palette.muted).padding(.top,index == 0 ? 0:4)
                        }
                        CalendarAgendaRow(model:model,entry:entry)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.accessibilityIdentifier("fc.calendar.upcoming.scroll")
        }.padding(14).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(WorkbenchMaterialSurface())
            .accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.upcomingAgenda")
    }
    private func upcomingStatus(_ text:String,warning:Bool=false)->some View {
        Text(text).font(.system(size:12)).foregroundStyle(warning ? palette.warning:palette.muted)
            .frame(maxWidth:.infinity,alignment:.center).multilineTextAlignment(.center).padding(.vertical,14)
            .accessibilityIdentifier("fc.calendar.upcoming.status")
    }
    private func calendarEmpty(_ text:String)->some View {Text(text).font(.system(size:12)).foregroundStyle(palette.muted).frame(maxWidth:.infinity).padding(.vertical,20)}
}

private struct CalendarSectionHeightKey:PreferenceKey {
    static let defaultValue:[String:CGFloat]=[:]
    static func reduce(value:inout [String:CGFloat],nextValue:()->[String:CGFloat]) {value.merge(nextValue(),uniquingKeysWith:max)}
}
private struct CalendarSectionHeightProbe:View {
    let section:String
    var body:some View {
        GeometryReader {geometry in Color.clear.preference(key:CalendarSectionHeightKey.self,value:[section:geometry.size.height])}
            .allowsHitTesting(false)
    }
}

private struct CalendarSegment<Value:Hashable>:View {
    @Binding var selection:Value
    let items:[Value]
    let title:(Value)->String
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        HStack(spacing:2){ForEach(items,id:\.self){item in
            Button {selection=item} label:{Text(title(item)).font(.system(size:11)).padding(.horizontal,8).frame(height:26).background(selection == item ? palette.control:.clear,in:RoundedRectangle(cornerRadius:6))}
                .buttonStyle(WBSelectableButtonStyle(selected: selection == item, cornerRadius: 6, drawsSelection: false, showsBorder: false)).foregroundStyle(selection == item ? palette.text:palette.muted).accessibilityValue(selection == item ? "已选择":"")
        }}.padding(2).background(palette.soft,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.line,lineWidth:1))
    }
}

private struct CalendarSideCard<Content:View>:View {
    let title:String
    let symbol:String
    var scrollIdentifier:String=""
    @ViewBuilder var content:()->Content
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:7){Image(systemName:symbol).font(.system(size:16)).foregroundStyle(palette.accent);Text(title).font(.system(size:12,weight:.medium));Spacer()}.frame(height:22).padding(.bottom,10)
            WorkbenchScrollView {LazyVStack(alignment:.leading,spacing:8,content:content).frame(maxWidth:.infinity,alignment:.leading)}.scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier(scrollIdentifier)
        }.padding(14).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(WorkbenchMaterialSurface())
    }
}

private struct CalendarDayCell:View {
    @ObservedObject var model:CalendarModel
    let date:Date
    var body:some View {
        let calendar=model.displayCalendar,selected=calendar.isDate(date,inSameDayAs:model.selectedDay)
        let outside = !calendar.isDate(date,equalTo:model.displayedMonth,toGranularity:.month),info=CalendarCivilDay(date:date,calendar:calendar,showsHolidays:model.holidaysEnabled)
        let entries=outside ? []:CalendarWorkspaceQueries.selectedDay(reminders:model.reminders,events:model.visibleCalendarEvents,day:date,calendar:calendar)
        WorkbenchCalendarDayButton(date:date,calendar:calendar,selected:selected,outside:outside,showsHolidays:model.holidaysEnabled,eventMarkers:entries.map(\.isSystemEvent),
            label:"\(calendarFormat(date,"M月d日",calendar:calendar))，\(info.namedLabel ?? info.label)，\(entries.count) 项安排",
            identifier:"fc.calendar.day.\(calendarFormat(date,"yyyy-MM-dd",calendar:calendar))") {model.selectDay(date)}
    }
}

private struct CalendarWeekGrid:View {
    @ObservedObject var model:CalendarModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        WorkbenchScrollView(.horizontal) {
            HStack(alignment:.top,spacing:4) {
                VStack(spacing:0){Color.clear.frame(height:30);ForEach([8,10,12,14,16,18],id:\.self){hour in Text(String(format:"%02d:00",hour)).font(.system(size:11)).foregroundStyle(palette.muted).frame(maxHeight:.infinity,alignment:.top)}}.frame(width:38)
                ForEach(model.weekDays,id:\.self){date in weekDay(date)}
            }.frame(minWidth:450,maxWidth:.infinity).frame(height:390).padding(.top,8)
        }.frame(maxHeight:.infinity,alignment:.top).accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.week")
    }
    private func weekDay(_ date:Date)->some View {
        let entries=ReminderQueries.entries(reminders:model.reminders,events:model.visibleCalendarEvents,filter:.day,day:date,calendar:model.displayCalendar)
        let info=CalendarCivilDay(date:date,calendar:model.displayCalendar,showsHolidays:model.holidaysEnabled)
        return VStack(spacing:0) {
            Button {model.selectDay(date)} label:{
                HStack(spacing:4){Text(calendarFormat(date,"EE d",calendar:model.displayCalendar)).font(.system(size:11,weight:.medium));CalendarHolidayBadge(day:info)}
                    .frame(maxWidth:.infinity).frame(height:30)
            }.buttonStyle(WorkbenchCalendarDayStyle(selected:model.displayCalendar.isDate(date,inSameDayAs:model.selectedDay),today:model.displayCalendar.isDateInToday(date)))
                .accessibilityLabel(calendarFormat(date,"M月d日",calendar:model.displayCalendar)+(info.namedLabel.map{"，"+$0} ?? ""))
                .accessibilityValue(model.displayCalendar.isDate(date,inSameDayAs:model.selectedDay) ? "已选择":"未选择")
                .accessibilityIdentifier("fc.calendar.weekday."+calendarFormat(date,"yyyy-MM-dd",calendar:model.displayCalendar))
            ZStack(alignment:.top) {
                VStack(spacing:0){ForEach(0..<6,id:\.self){_ in Rectangle().fill(palette.line).frame(height:1);Spacer(minLength:0)}}
                ForEach(Array(entries.enumerated()),id:\.element.id){index,entry in
                    Button {open(entry)} label:{VStack(alignment:.leading,spacing:3){Text(entry.title).lineLimit(2);Text(calendarTime(entry,calendar:model.displayCalendar)).foregroundStyle(palette.secondary)}.font(.system(size:11)).padding(5).frame(maxWidth:.infinity,alignment:.leading).frame(minHeight:39,maxHeight:58).background(palette.soft,in:RoundedRectangle(cornerRadius:6)).overlay(RoundedRectangle(cornerRadius:6).strokeBorder(palette.line,lineWidth:1))}
                        .buttonStyle(WBSelectableButtonStyle(cornerRadius: 6, showsBorder: false)).padding(.top,offset(entry,index:index)).accessibilityLabel("\(entry.title)，\(calendarTime(entry,calendar:model.displayCalendar))")
                }
            }.frame(height:350)
        }.frame(minWidth:52,maxWidth:.infinity).overlay(alignment:.leading){palette.line.frame(width:1)}
    }
    private func offset(_ entry:CalendarAgendaEntry,index:Int)->CGFloat {
        guard let date=ReminderQueries.displayDate(for:entry,calendar:model.displayCalendar) else{return CGFloat(index*42)}
        if case .reminder(let item)=entry,item.due?.hasTime != true{return CGFloat(index*42)}
        if case .event(let event)=entry,event.isAllDay{return CGFloat(index*42)}
        let hour=model.displayCalendar.component(.hour,from:date),minute=model.displayCalendar.component(.minute,from:date)
        return max(4,min(292,CGFloat(hour-8)*29+CGFloat(minute)*29/60))+CGFloat(index%2)*3
    }
    private func open(_ entry:CalendarAgendaEntry){switch entry {case .reminder(let item):model.selectedReminder=item;case .event(let item):model.selectedEvent=item}}
}

private struct CalendarAgendaRow:View {
    @ObservedObject var model:CalendarModel
    let entry:CalendarAgendaEntry
    var showTime=true
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    private var event:Bool {if case .event = entry {return true};return false}
    private var tint:Color {event ? Color(red:0.66,green:0.51,blue:0.91):Color(red:0.23,green:0.68,blue:0.48)}
    var body:some View {
        HStack(alignment:.center,spacing:9) {
            if case .reminder(let item)=entry {
                Button {Task {await model.toggle(item)}} label:{
                    ZStack {
                        RoundedRectangle(cornerRadius:4).strokeBorder(item.isCompleted ? palette.success:palette.secondary,lineWidth:1)
                        if item.isCompleted {RoundedRectangle(cornerRadius:4).fill(palette.success);Image(systemName:"checkmark").font(.system(size:9,weight:.semibold)).foregroundStyle(palette.primaryText)}
                    }.frame(width:16,height:16).padding(3).contentShape(Rectangle())
                }.buttonStyle(ClickablePlainButtonStyle()).disabled(!item.isWritable || model.isWorking)
                    .accessibilityLabel("\(item.isCompleted ? "恢复待办":"完成提醒")：\(item.title)")
                    .accessibilityIdentifier("fc.calendar.complete."+item.stableID)
            } else {Image(systemName:"calendar").font(.system(size:16)).foregroundStyle(tint).frame(width:22)}
            Button {switch entry {case .reminder(let item):model.selectedReminder=item;case .event(let event):model.selectedEvent=event}} label:{
                VStack(alignment:.leading,spacing:4) {
                    Text(entry.title).font(.system(size:12)).foregroundStyle(entry.isCompleted ? palette.muted:palette.text).strikethrough(entry.isCompleted).lineLimit(2)
                    Text(detail).font(.system(size:11)).foregroundStyle(palette.secondary).lineLimit(2)
                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(ClickablePlainButtonStyle())
            Text(event ? "日程":"待办").font(.system(size:10,weight:.medium)).foregroundStyle(palette.secondary)
                .padding(.horizontal,6).padding(.vertical,3).background(tint.opacity(0.12),in:RoundedRectangle(cornerRadius:5))
        }.padding(.horizontal,10).padding(.vertical,9).frame(maxWidth:.infinity,minHeight:56)
            .background(tint.opacity(colorScheme == .dark ? 0.17:0.10),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(tint.opacity(colorScheme == .dark ? 0.38:0.30),lineWidth:1))
            .accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.entry."+entry.id)
    }
    private var detail:String {
        switch entry {
        case .reminder(let item):
            let deadline=item.due == nil ? "无期限":showTime ? (item.due?.hasTime == true ? calendarTime(entry,calendar:model.displayCalendar)+" 截止":"当天截止"):calendarEntryDate(entry,calendar:model.displayCalendar)+" 截止"
            return deadline+" · "+(item.origin == .local ? "方寸本机":item.calendarName ?? "提醒事项")
        case .event(let event):
            let time=event.isAllDay ? "全天":calendarFormat(event.start,"HH:mm",calendar:model.displayCalendar)+"–"+calendarFormat(event.end,"HH:mm",calendar:model.displayCalendar)
            let minutes=max(0,Int(event.end.timeIntervalSince(event.start)/60))
            let duration:String
            if event.isAllDay {
                let days=max(1,model.displayCalendar.dateComponents([.day],from:model.displayCalendar.startOfDay(for:event.start),to:model.displayCalendar.startOfDay(for:event.end)).day ?? 1)
                duration="\(days) 天"
            } else if minutes >= 60 {duration="\(minutes/60) 小时"+(minutes%60 == 0 ? "":" \(minutes%60) 分钟")}
            else {duration="\(minutes) 分钟"}
            return [time,duration,event.calendarName].joined(separator:" · ")
        }
    }
}

/// Mounted once by the shell so home and calendar use the same editor identity.
/// Hiding a native window keeps the draft; dismiss requests use the editor guard.
struct CalendarDialogs:View {
    @ObservedObject var model:CalendarModel
    var context:WorkbenchContextModel? = nil
    var body:some View {
        Color.clear.frame(width:0,height:0)
            .workbenchModal(item:$model.editor,width:640,onRequestDismiss:{model.editorCloseRequest += 1}) {CalendarReminderEditor(model:model,initial:$0)}
            .workbenchModal(item:$model.selectedEvent) {event in CalendarEventDetail(model:model,event:event)}
            .workbenchModal(item:$model.selectedReminder) {item in CalendarReminderDetail(model:model,item:item)}
            .workbenchModal(isPresented:$model.showNotifications) {CalendarNotificationsDialog(model:model)}
            .workbenchModal(isPresented:$model.showReminderList) {CalendarReminderList(model:model)}
            .workbenchModal(isPresented:$model.showNewChoice) {CalendarNewChoice(model:model)}
            .onAppear {syncZone()}
            .onReceive(context?.objectWillChange.eraseToAnyPublisher() ?? Empty<Void,Never>().eraseToAnyPublisher()) {_ in Task {@MainActor in syncZone()}}
            .workbenchModal(isPresented:Binding(get:{model.errorMessage != nil && model.editor == nil && !model.showSources && !model.showNotifications},set:{if !$0 {model.errorMessage=nil}}),onRequestDismiss:{model.errorMessage=nil}) {
                CalendarOperationErrorDialog(model:model)
            }
    }
    private func syncZone(){if let context,model.displayTimeZone != context.dateContext.timeZone {model.displayTimeZone=context.dateContext.timeZone}}
}

private struct CalendarOperationErrorDialog:View {
    @ObservedObject var model:CalendarModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        CalendarDialog(title:"操作未完成",dismiss:{model.errorMessage=nil}) {
            Text(model.errorMessage ?? "").font(.system(size:12)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal:false,vertical:true)
        } actions:{
            Spacer()
            Button("知道了"){model.errorMessage=nil}.buttonStyle(WBButtonStyle(primary:true))
        }
        .accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.error.dialog")
    }
}

struct CalendarDialog<Content:View,Actions:View>:View {
    let title:String
    let dismiss:()->Void
    var width:CGFloat=470
    @ViewBuilder var content:()->Content
    @ViewBuilder var actions:()->Actions
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {Text(title).font(.system(size:12,weight:.medium));Spacer();Button(action:dismiss){Image(systemName:"xmark")}.buttonStyle(WBIconButtonStyle(size:32)).accessibilityLabel("关闭")}.padding(.horizontal,18).padding(.top,18).padding(.bottom,13)
            WorkbenchDialogBody(maximumHeight:380) { VStack(alignment:.leading,spacing:16,content:content) }
            HStack(spacing:8,content:actions).padding(.horizontal,18).padding(.vertical,13)
        }.foregroundStyle(palette.text).frame(width:width)
    }
}
struct CalendarDiscardDialog:View {
    let back:()->Void
    let discard:()->Void
    @Environment(\.workbenchPalette) private var palette
    var body:some View {CalendarDialog(title:"放弃未保存的修改？",dismiss:back){Text("你的修改尚未保存，关闭后将恢复之前的内容。").font(.system(size:12)).foregroundStyle(palette.secondary)} actions:{Spacer();Button("继续编辑",action:back).buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction);Button("放弃修改",action:discard).buttonStyle(WBButtonStyle(destructive:true))}}
}
struct CalendarDeleteDialog:View {
    @ObservedObject var model:CalendarModel
    let item:ReminderItem
    let dismiss:()->Void
    @Environment(\.workbenchPalette) private var palette
    var body:some View {CalendarDialog(title:"删除这条提醒？",dismiss:dismiss){Text("「\(item.title)」将从\(item.sourceTitle)移除。删除后可以在列表中撤销。").font(.system(size:12)).foregroundStyle(palette.secondary)} actions:{Spacer();Button("取消",action:dismiss).buttonStyle(WBButtonStyle());Button("删除"){Task {if await model.delete(item){model.selectedReminder=nil;dismiss()}}}.buttonStyle(WBButtonStyle(destructive:true)).disabled(model.isWorking)}}
}

private struct CalendarReminderDetail:View {
    @ObservedObject var model:CalendarModel
    let item:ReminderItem
    @State private var delete=false
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        CalendarDialog(title:item.title,dismiss:{model.selectedReminder=nil}) {
            CalendarFact("日期",value:item.due == nil ? "未定日期":calendarEntryDate(.reminder(item),calendar:model.displayCalendar))
            CalendarFact("时间",value:calendarTime(.reminder(item),calendar:model.displayCalendar))
            CalendarFact("来源",value:item.sourceTitle)
            CalendarFact("状态",value:item.isCompleted ? "已完成":"待完成")
            CalendarFact("到时提醒",value:item.origin == .local ? (item.notificationsEnabled ? "已开启":"已关闭"):"由系统提醒事项管理")
            if !item.notes.isEmpty {Text(item.notes).font(.system(size:12)).foregroundStyle(palette.secondary).textSelection(.enabled)}
            if !item.isWritable {Text("这个系统提醒列表为只读。").font(.system(size:11)).foregroundStyle(palette.muted)}
        } actions:{
            if item.isWritable {Button("删除"){delete=true}.buttonStyle(WBButtonStyle(destructive:true))}
            Spacer()
            Button("编辑"){model.selectedReminder=nil;model.openReminder(item)}.buttonStyle(WBButtonStyle())
            if item.isWritable {Button(item.isCompleted ? "恢复待办":"完成提醒"){Task {await model.toggle(item);if model.errorMessage == nil {model.selectedReminder=nil}}}.buttonStyle(WBButtonStyle(primary:true)).disabled(model.isWorking)}
        }.workbenchModal(isPresented:$delete){CalendarDeleteDialog(model:model,item:item,dismiss:{delete=false})}
    }
}
private struct CalendarFact:View {
    let title:String
    let value:String
    init(_ title:String,value:String){self.title=title;self.value=value}
    @Environment(\.workbenchPalette) private var palette
    var body:some View {HStack(alignment:.top){Text(title).foregroundStyle(palette.muted);Spacer();Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)}.font(.system(size:12)).frame(minHeight:20)}
}
private struct CalendarEventDetail:View {
    @ObservedObject var model:CalendarModel
    let event:CalendarEventItem
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        CalendarDialog(title:event.title,dismiss:{model.selectedEvent=nil}) {
            CalendarFact("日期",value:calendarEntryDate(.event(event),calendar:model.displayCalendar))
            CalendarFact("时间",value:event.isAllDay ? "全天":calendarFormat(event.start,"HH:mm",calendar:model.displayCalendar)+" — "+calendarFormat(event.end,"HH:mm",calendar:model.displayCalendar))
            CalendarFact("来源",value:"系统日历 · "+event.calendarName)
            if !event.location.isEmpty {CalendarFact("地点",value:event.location)}
            if !event.notes.isEmpty {Text(event.notes).font(.system(size:12)).foregroundStyle(palette.secondary).textSelection(.enabled)}
            Text("这是只读系统日程。需要修改时，可前往系统日历。").font(.system(size:11)).foregroundStyle(palette.muted)
        } actions:{Spacer();Button("在日历中打开"){model.openSystemCalendar()}.buttonStyle(WBButtonStyle(primary:true))}
    }
}

private struct CalendarNewChoice:View {
    @ObservedObject var model:CalendarModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {CalendarDialog(title:"新建",dismiss:{model.showNewChoice=false}){
        Button {model.showNewChoice=false;model.openNewReminder()} label:{Label(model.systemRemindersAvailable ? "提醒事项":"新建提醒",systemImage:"checkmark.circle")}.buttonStyle(WBButtonStyle(primary:true))
        Button {model.openSystemCalendar();model.showNewChoice=false} label:{Label("系统日程",systemImage:"calendar")}.buttonStyle(WBButtonStyle())
        Text(model.systemRemindersAvailable ? "提醒直接保存到系统列表，与提醒事项保持同步。系统日程交由日历编辑。":"接入系统提醒事项后，新提醒默认保存到系统列表。尚未接入时可明确保存为本机提醒。系统日程交由日历编辑。")
            .font(.system(size:12)).foregroundStyle(palette.secondary)
    } actions:{Spacer();Button("取消"){model.showNewChoice=false}.buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)}}
}

private struct CalendarReminderList:View {
    @ObservedObject var model:CalendarModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {CalendarDialog(title:"全部提醒",dismiss:{model.showReminderList=false}){
        HStack(spacing:8){CalendarSegment(selection:$model.filter,items:[ReminderFilter.all,.completed,.undated],title:{$0 == .all ? "待办":$0.title});Spacer();WBSelect("提醒来源",selection:$model.reminderListSource,options:[(value:"all",title:"全部来源"),(value:"local",title:"本机提醒"),(value:"system",title:"系统提醒事项")]).frame(width:120)}
        HStack(spacing:7){Image(systemName:"magnifyingglass");TextField("搜索标题、备注与来源",text:$model.search).textFieldStyle(.plain)}.font(.system(size:12)).padding(.horizontal,10).frame(height:32).background(palette.soft,in:RoundedRectangle(cornerRadius:8))
        if model.allReminderEntries.isEmpty {Text("暂无提醒").font(.system(size:12)).foregroundStyle(palette.muted).frame(maxWidth:.infinity).padding(.vertical,25)}
        ForEach(model.allReminderEntries){CalendarAgendaRow(model:model,entry:$0,showTime:false)}
        if let undo=model.undoMessage {HStack{Text(undo).font(.system(size:11));Spacer();Button("撤销"){Task {await model.undoLastChange()}}.buttonStyle(WBButtonStyle(compact:true))}}
    } actions:{Spacer();Button("新建提醒"){model.showReminderList=false;model.openNewReminder()}.buttonStyle(WBButtonStyle(primary:true))}}
}

private struct CalendarSourcesPage:View {
    @ObservedObject var model:CalendarModel
    let onBack:()->Void
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            Button {model.errorMessage=nil;onBack()} label:{Label(model.sourcesReturnToPrivacy ? "返回隐私与锁定":"返回日历与提醒",systemImage:"chevron.left")}.buttonStyle(WBQuietButtonStyle()).padding(.bottom,12)
            WBPageHeader(title:"日历来源",subtitle:"按来源管理日程、提醒与授权状态")
            VStack(spacing:12) {
                WBCard(title:"系统来源",symbol:"calendar") {
                    systemSource(reminders:false)
                    ForEach(model.calendarSources){source in sourceRow(source.title,source.account.isEmpty ? "系统日历 · 只读显示":source.account+" · 只读显示") {Toggle("显示\(source.title)",isOn:Binding(get:{model.isSourceVisible(source.id)},set:{model.setSourceVisible(source.id,$0)})).labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.small).tint(palette.accent)}}
                    systemSource(reminders:true)
                }
                WBCard(title:"中国大陆节假日",symbol:"calendar") {
                    sourceRow("放假与调休","关闭后隐藏官方放假、休息与补班标记") {
                        Toggle("显示中国大陆节假日",isOn:Binding(get:{model.holidaysEnabled},set:{model.setHolidaysEnabled($0)}))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(palette.accent).clickableCursor()
                            .accessibilityIdentifier("calendar-source-holidays")
                    }
                    sourceRow("传统节日与农历","节日与调休分别标记，不把节日都视为放假"){status("独立显示")}
                    sourceRow("地区与日期","按中国大陆民用日期标注，不随显示时区偏移",last:true){status("中国大陆")}
                }
                WBCard(title:"本机内容",symbol:"internaldrive") {
                    sourceRow("本机提醒","保存在此设备，无需日历权限"){status(model.storageError == nil ? "可用":"数据不可用",good:model.storageError == nil)}
                    sourceRow("提醒通知","不授权通知也可以保存提醒",last:true){Button(model.preferences.notificationsEnabled && model.notificationAccess == .granted ? "已允许 · 管理":"管理通知"){model.showNotifications=true}.buttonStyle(WBButtonStyle(compact:true))}
                }
                VStack(alignment:.leading,spacing:8) {
                    Text("日程直接读取系统日历，提醒事项可在原系统列表中创建、编辑与完成。断开只停止同步，不删除系统内容；原有本机提醒也不会自动迁移。节假日资料按年度载入，不推算未知年份的调休。").font(.system(size:11)).foregroundStyle(palette.secondary)
                    Link(WorkbenchChinaHolidays.sourceTitle,destination:WorkbenchChinaHolidays.sourceURL).font(.system(size:11))
                    Text("数据版本："+WorkbenchChinaHolidays.datasetVersion).font(.system(size:11)).foregroundStyle(palette.muted)
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(palette.soft,in:RoundedRectangle(cornerRadius:8))
                if let error=model.errorMessage {Text(error).font(.system(size:11)).foregroundStyle(palette.critical).frame(maxWidth:.infinity,alignment:.leading)}
            }
        }
    }
    private func systemSource(reminders:Bool)->some View {
        let access=reminders ? model.remindersAccess:model.calendarAccess
        let connected=reminders ? model.preferences.remindersConnected:model.preferences.calendarConnected
        return sourceRow(reminders ? "系统提醒事项":"系统日历",reminders ? "接入后可在可写列表中创建与完成提醒":"读取日程，保留原日历的来源与只读状态",last:reminders) {
            HStack(spacing:8) {
                if access == .denied || access == .restricted {Button("隐私设置"){model.openPrivacySettings(reminders:reminders)}.buttonStyle(WBButtonStyle(compact:true))}
                Text(connected && access == .granted ? (reminders ? "已连接":"已连接 · 只读"):connected ? "权限已关闭":access == .denied ? "未连接 · 未授权":access == .restricted ? "受限":"未连接").font(.system(size:11)).foregroundStyle(connected && access == .granted ? palette.success:palette.muted)
                Toggle(reminders ? "连接系统提醒事项":"连接系统日历",isOn:Binding(get:{connected},set:{enabled in Task {if enabled {await model.connect(reminders:reminders)}else{await model.disconnect(reminders:reminders)}}}))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(palette.accent).clickableCursor()
                    .disabled(model.isWorking || (access == .restricted && !connected))
                    .accessibilityIdentifier(reminders ? "calendar-source-system-reminders":"calendar-source-system-events")
            }
        }
    }
    private func sourceRow<Content:View>(_ title:String,_ subtitle:String,last:Bool=false,@ViewBuilder control:()->Content)->some View {
        VStack(spacing:0){HStack(spacing:16){VStack(alignment:.leading,spacing:4){Text(title).font(.system(size:12));Text(subtitle).font(.system(size:11)).foregroundStyle(palette.muted)};Spacer(minLength:8);control()}.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,13);if !last {palette.line.frame(height:1)}}
    }
    private func status(_ title:String,good:Bool=false)->some View {Text(title).font(.system(size:11)).foregroundStyle(good ? palette.success:palette.secondary).padding(.horizontal,7).padding(.vertical,3).background(palette.soft,in:RoundedRectangle(cornerRadius:5))}
}

private struct CalendarNotificationsDialog:View {
    @ObservedObject var model:CalendarModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        CalendarDialog(title:"提醒通知",dismiss:close) {
            Text("到时间，轻轻提醒你").font(.system(size:14,weight:.medium))
            Text("本机提醒需开启「到时提醒我」并设置日期和时间才会通知。无日期、全天、已完成及已过期的提醒不会通知；系统提醒由 macOS 提醒事项负责，方寸不重复发送。").font(.system(size:12)).foregroundStyle(palette.secondary)
            Text("最近 60 条未来通知交给系统。收起窗口后继续提醒；彻底退出方寸会暂停方寸本机通知，重新打开后恢复。系统提醒事项中的通知不受影响。").font(.system(size:11)).foregroundStyle(palette.muted)
            CalendarFact("通知权限",value:model.notificationAccess == .granted ? "已允许":model.notificationAccess == .denied ? "已拒绝":model.notificationAccess == .restricted ? "受限":"尚未请求")
            if model.notificationAccess == .denied || model.notificationAccess == .restricted {Button("前往系统通知设置"){model.openNotificationSettings()}.buttonStyle(WBButtonStyle())}
            if let error=model.errorMessage {Text(error).font(.system(size:11)).foregroundStyle(palette.critical)}
        } actions:{
            if model.preferences.notificationsEnabled {Button("停止本机通知"){model.disableNotifications();if model.errorMessage == nil {close()}}.buttonStyle(WBButtonStyle(destructive:true)).disabled(model.isWorking)}
            Spacer();Button("稍后",action:close).buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
            if !model.preferences.notificationsEnabled || model.notificationAccess != .granted {Button("允许通知"){Task {await model.enableNotifications()}}.buttonStyle(WBButtonStyle(primary:true)).disabled(model.isWorking)}else{Button("完成",action:close).buttonStyle(WBButtonStyle(primary:true))}
        }
    }
    private func close(){guard !model.isWorking else{return};model.showNotifications=false;model.errorMessage=nil}
}

/// One civil-day interpretation shared by month, week, home and day details.
struct CalendarCivilDay {
    var label:String
    var namedLabel:String?
    var badge:String?
    var holidayKind:WorkbenchHolidayKind?
    func color(_ palette:ThemePalette)->Color {
        switch holidayKind {case .holiday:palette.success;case .workingDay:palette.critical;case nil:palette.muted}
    }
    init(date:Date,calendar:Calendar,showsHolidays:Bool=true) {
        let c=calendar.dateComponents([.year,.month,.day],from:date)
        var china=Calendar(identifier:.gregorian);china.timeZone=TimeZone(identifier:"Asia/Shanghai")!
        let noon=china.date(from:DateComponents(year:c.year,month:c.month,day:c.day,hour:12)) ?? date
        let value=try? WorkbenchDateContext(timeZoneIdentifier:"Asia/Shanghai").display(at:noon)
        let lunar=value?.lunarDate
        var festival:String?
        if let lunar,!lunar.isLeapMonth {
            festival=["1-1":"春节","1-15":"元宵节","5-5":"端午节","7-7":"七夕","8-15":"中秋节","9-9":"重阳节","12-8":"腊八节"]["\(lunar.month)-\(lunar.day)"]
        }
        if showsHolidays,let value,case .recorded(let holiday)=value.holiday {
            label=holiday.kind == .workingDay ? "调休上班":holiday.name
            namedLabel=holiday.name+(holiday.kind == .workingDay ? "":" · 放假")
            badge=holiday.kind == .holiday ? "休":"班";holidayKind=holiday.kind
        } else if let festival {label=festival;namedLabel=festival}
        else if let lunar {
            let text=lunar.displayText
            label=lunar.day == 1 ? String(text.prefix(through:text.firstIndex(of:"月")!)):String(text.suffix(from:text.index(after:text.firstIndex(of:"月")!)))
        } else {label=""}
    }
}
struct CalendarHolidayBadge:View {
    let day:CalendarCivilDay
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        if let badge=day.badge {
            Text(badge).font(.system(size:10)).foregroundStyle(day.color(palette))
                .padding(.horizontal,3).frame(height:15)
                .background(day.color(palette).opacity(0.08),in:RoundedRectangle(cornerRadius:3))
                .accessibilityLabel(day.namedLabel ?? day.label)
        }
    }
}
private extension CalendarAgendaEntry {var isSystemEvent:Bool {if case .event=self {return true};return false}}
private func calendarFormat(_ date:Date,_ format:String,calendar:Calendar)->String {let f=DateFormatter();f.locale=Locale(identifier:"zh_CN");f.calendar=calendar;f.timeZone=calendar.timeZone;f.dateFormat=format;return f.string(from:date)}
private func calendarEntryDate(_ entry:CalendarAgendaEntry,calendar:Calendar)->String {ReminderQueries.displayDate(for:entry,calendar:calendar).map{calendarFormat($0,"yyyy 年 M 月 d 日",calendar:calendar)} ?? "未定日期"}
private func calendarTime(_ entry:CalendarAgendaEntry,calendar:Calendar)->String {
    switch entry {
    case .reminder(let item):guard let due=item.due else{return "待定"};return due.hasTime ? due.date.map{calendarFormat($0,"HH:mm",calendar:calendar)} ?? "不可用":"全天"
    case .event(let event):return event.isAllDay ? "全天":calendarFormat(event.start,"HH:mm",calendar:calendar)
    }
}
