import AppKit
import Combine
import SwiftUI
import LauncherCore

/// The right card lists the next seven days or the month shown on the left (现行规范 9.3, K4).
private enum CalendarUpcomingRange: Hashable { case week, month }

struct CalendarModuleView:View {
    @ObservedObject var model:CalendarModel
    var context:WorkbenchContextModel? = nil
    var returnToSettingsPrivacy:(()->Void)?=nil
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchPageWidth) private var width
    @Environment(\.workbenchContentHeight) private var contentHeight
    @Environment(\.workbenchModals) private var modals
    @Environment(\.workbenchToast) private var toast
    @State private var introHeight:CGFloat=74
    @State private var upcomingSource="all"
    @State private var upcomingRange:CalendarUpcomingRange = .week
    @State private var newMenuOpen=false
    private var compact:Bool {width < 800}
    private var horizontalWorkspace:Bool {width >= 760}
    private var calendarWidth:CGFloat {horizontalWorkspace ? (width-12)*0.45 : width}
    private var sideWidth:CGFloat {max(0,width-calendarWidth-12)}
    private var rows:Int {max(5,model.monthDays.count/7)}
    private let selectedMinimum:CGFloat=132
    /// The month card and side column share the page's remaining height
    /// (现行规范 9.3, K2): date tiles take 40–64 so the selected day keeps at
    /// least two rows; five- and six-week months keep the same card height.
    private var availableHeight:CGFloat {max(0,contentHeight-introHeight)}
    private var monthChrome:CGFloat {28+42+28+CGFloat(rows-1)*4}
    private var dayHeight:CGFloat {
        let fit=(availableHeight-12-selectedMinimum-monthChrome)/CGFloat(rows)
        return max(40,min(64,fit.isFinite ? fit:52))
    }
    private var calendarHeight:CGFloat {monthChrome+CGFloat(rows)*dayHeight}
    private var workspaceHeight:CGFloat {max(calendarHeight+12+selectedMinimum,availableHeight)}
    private var longTermHeight:CGFloat {min(228,max(204,workspaceHeight*0.30))}
    private var displayMode:CalendarPresentationMode {model.presentationMode == .week ? .week:.month}
    private var pendingItems:[ReminderItem] {
        model.reminders.filter {!$0.isCompleted && $0.due == nil && (upcomingSource == "all" || CalendarWorkspaceQueries.sourceKey(.reminder($0)) == upcomingSource)}
            .sorted {$0.createdAt == $1.createdAt ? $0.id < $1.id:$0.createdAt > $1.createdAt}
    }
    private var selectedItems:[CalendarAgendaEntry] {CalendarWorkspaceQueries.selectedDay(reminders:model.reminders,events:model.visibleCalendarEvents,day:model.selectedDay,calendar:model.displayCalendar)}
    private var upcomingItems:[CalendarAgendaEntry] {CalendarWorkspaceQueries.upcoming(reminders:model.reminders,events:upcomingEvents,interval:upcomingInterval,source:upcomingSource,calendar:model.displayCalendar)}
    private var monthItems:[CalendarAgendaEntry] {model.monthEntries.filter {upcomingSource == "all" || CalendarWorkspaceQueries.sourceKey($0) == upcomingSource}}
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
                            newMenuButton
                        }
                    }
                    // The connection prompt lives in the right card, not a banner (K1).
                    if let error=model.storageError {storageWarning(error).padding(.bottom,12)}
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
            }
        }.frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(palette.text)
            .onPreferenceChange(CalendarSectionHeightKey.self) {heights in
                if let height=heights["intro"],height.isFinite,height>0,abs(introHeight-height)>0.25 {introHeight=height}
            }
            .onChange(of:sourceOptions.map(\.value)) {_,values in if !values.contains(upcomingSource) {upcomingSource="all"}}
            // A one-off result becomes the window toast with its undo (G3). The
            // reminder list dialog shows the same undo inline, so it stays quiet then.
            .onChange(of:model.undoMessage) {_,message in
                guard let message,!model.showSources,modals?.isPresented != true else {return}
                toast(message,actionTitle:"撤销") {Task {await model.undoLastChange()}}
            }
            .accessibilityElement(children:.contain).accessibilityIdentifier(model.showSources ? "fc.page.calendar.sources":"fc.page.calendar")
    }
    private var zoneTitle:String {context?.zoneTitle.components(separatedBy:" · ").first ?? model.displayTimeZone.identifier}
    /// "新建" opens a menu of the two kinds instead of a dialog (现行规范 9.3, K6).
    private var newMenuButton:some View {
        Button {newMenuOpen.toggle()} label:{HStack(spacing:6){Image(systemName:"plus");Text("新建");Image(systemName:"chevron.down").font(.system(size:10,weight:.medium))}}
            .buttonStyle(WBButtonStyle(primary:true)).disabled(model.storageError != nil)
            .workbenchPopover(isPresented:$newMenuOpen,width:300,alignment:.trailing) {newMenu}
            .accessibilityLabel("新建").accessibilityIdentifier("fc.calendar.new")
    }
    private var newMenu:some View {
        VStack(alignment:.leading,spacing:2) {
            newMenuItem(symbol:"checkmark.circle",tint:palette.accent,title:model.systemRemindersAvailable ? "提醒事项":"新建提醒",
                        detail:model.systemRemindersAvailable ? "保存到系统提醒事项，与提醒事项保持同步":"保存为方寸本机提醒；接入系统后保存到提醒事项",identifier:"fc.calendar.new.reminder") {model.openNewReminder()}
            newMenuItem(symbol:"calendar",tint:palette.cool,title:"系统日程",detail:"在系统日历中新建，方寸只读显示",identifier:"fc.calendar.new.event") {model.openSystemCalendar()}
        }.padding(6)
    }
    private func newMenuItem(symbol:String,tint:Color,title:String,detail:String,identifier:String,action:@escaping ()->Void)->some View {
        Button {newMenuOpen=false;action()} label:{
            HStack(alignment:.top,spacing:10) {
                Image(systemName:symbol).font(.system(size:16)).foregroundStyle(tint).frame(width:18).padding(.top,1)
                VStack(alignment:.leading,spacing:2) {
                    Text(title).font(.system(size:13,weight:.medium)).foregroundStyle(palette.text)
                    Text(detail).font(.system(size:11)).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
            }.padding(.horizontal,10).padding(.vertical,8).frame(maxWidth:.infinity,minHeight:52,alignment:.leading).contentShape(Rectangle())
        }.buttonStyle(WBSelectableButtonStyle(cornerRadius:7,drawsSelection:false,showsBorder:false)).accessibilityIdentifier(identifier)
    }
    private func storageWarning(_ text:String)->some View {
        HStack(alignment:.top,spacing:8) {
            Image(systemName:"exclamationmark.triangle").foregroundStyle(palette.warning)
            Text(text).font(.system(size:11)).textSelection(.enabled)
            Spacer()
            if model.canRecoverBackup {Button("恢复上次备份"){model.recoverBackup()}.buttonStyle(WBButtonStyle(compact:true))}
        }.padding(14).background(WorkbenchMaterialSurface(radius:10))
    }
    private var monthCard:some View {
        VStack(spacing:0) {
            monthToolbar.frame(height:32).padding(.bottom,10)
            switch displayMode {
            case .week:CalendarWeekGrid(model:model,height:calendarHeight-28-42)
            default:monthGrid
            }
        }.padding(14).frame(maxHeight:.infinity,alignment:.top).background(WorkbenchMaterialSurface()).accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.monthCard")
    }
    private var monthToolbar:some View {
        HStack(spacing:compact ? 4:6) {
            Text(WorkbenchDateText.yearMonth(model.displayedMonth,calendar:model.displayCalendar))
                .font(.system(size:13,weight:.medium)).lineLimit(1).fixedSize(horizontal:true,vertical:false)
            Spacer(minLength:4)
            Button {move(-1)} label:{Image(systemName:"chevron.left")}.buttonStyle(WBIconButtonStyle(size:28)).accessibilityLabel(displayMode == .week ? "上一周":"上个月")
            Button("今天"){model.goToToday()}.buttonStyle(WBButtonStyle())
            Button {move(1)} label:{Image(systemName:"chevron.right")}.buttonStyle(WBIconButtonStyle(size:28)).accessibilityLabel(displayMode == .week ? "下一周":"下个月")
            // Two views, one segmented choice (现行规范 4.4, K4).
            WBSegmentedChoice(selection:Binding(get:{displayMode},set:{model.presentationMode=$0}),options:[(value:.month,title:"月"),(value:.week,title:"周")],
                              optionWidth:34,identifier:"fc.calendar.view-mode").padding(.leading,4)
        }
    }
    private func move(_ value:Int) {
        if displayMode == .week,let next=model.displayCalendar.date(byAdding:.day,value:7*value,to:model.selectedDay){model.selectDay(next)}
        else {model.changeMonth(value)}
    }
    private var monthGrid:some View {
        VStack(spacing:0) {
            HStack(spacing:4) {ForEach(["一","二","三","四","五","六","日"],id:\.self){day in Text(day).font(.system(size:11)).foregroundStyle(palette.muted).frame(maxWidth:.infinity)}}.frame(height:24).padding(.bottom,4)
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(minimum:0),spacing:4),count:7),spacing:4) {
                ForEach(model.monthDays,id:\.self){date in CalendarDayCell(model:model,date:date).frame(height:dayHeight)}
            }
        }
    }
    private var selectedCard:some View {
        CalendarSideCard(title:WorkbenchDateText.monthDayWeekday(model.selectedDay,calendar:model.displayCalendar),symbol:"calendar",scrollIdentifier:"fc.calendar.selected.scroll") {
            let civilDay=CalendarCivilDay(date:model.selectedDay,calendar:model.displayCalendar,showsHolidays:model.holidaysEnabled)
            if let text=civilDay.namedLabel {
                Text(text).font(.system(size:11)).foregroundStyle(civilDay.color(palette)).padding(.horizontal,7).padding(.vertical,5).frame(maxWidth:.infinity,alignment:.leading).background(civilDay.holidayKind == nil ? palette.soft:civilDay.color(palette).opacity(0.08),in:RoundedRectangle(cornerRadius:6)).padding(.bottom,4)
            }
            if selectedItems.isEmpty {
                calendarEmpty("这一天还没有安排")
                HStack {Spacer(minLength:0);Button {newMenuOpen=true} label:{Label("添加安排",systemImage:"plus")}.buttonStyle(WBButtonStyle(compact:true)).accessibilityIdentifier("fc.calendar.empty.add-action");Spacer(minLength:0)}
            } else {
                let items=selectedItems
                ForEach(Array(items.enumerated()),id:\.element.id) {index,entry in CalendarAgendaRow(model:model,entry:entry,last:index == items.count-1)}
            }
        }.accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.selectedAgenda")
    }
    private var pendingCard:some View {
        CalendarSideCard(title:"长期待办",symbol:"tray",trailing:pendingItems.isEmpty ? nil:"\(pendingItems.count) 项",scrollIdentifier:"fc.calendar.pending.scroll") {
            if pendingItems.isEmpty {calendarEmpty("暂无长期待办")}
            let items=pendingItems
            ForEach(Array(items.enumerated()),id:\.element.id) {index,item in CalendarAgendaRow(model:model,entry:.reminder(item),showTime:false,last:index == items.count-1)}
        } footer: {
            // The list scrolls; its action stays at the card's bottom (现行规范 9.3, K5).
            HStack {Spacer(minLength:0);Button("查看全部提醒"){model.filter = .all;model.search="";model.showReminderList=true}.buttonStyle(WBButtonStyle(compact:true)).accessibilityIdentifier("fc.calendar.pending.all-action");Spacer(minLength:0)}.padding(.top,8)
        }.accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.pendingReminders")
    }
    private var upcomingRangeLabel:String {
        let calendar=model.displayCalendar
        if upcomingRange == .week {
            let end=calendar.date(byAdding:.day,value:-1,to:upcomingInterval.end) ?? upcomingInterval.start
            return WorkbenchDateText.range(upcomingInterval.start,end,calendar:calendar)
        }
        let start=calendar.dateInterval(of:.month,for:model.displayedMonth)?.start ?? model.displayedMonth
        let end=calendar.date(byAdding:DateComponents(month:1,day:-1),to:start) ?? start
        return WorkbenchDateText.range(start,end,calendar:calendar)
    }
    private var upcomingEntries:[CalendarAgendaEntry] {upcomingRange == .week ? upcomingItems:monthItems}
    private var upcomingCard:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:8) {
                WBSegmentedChoice(selection:$upcomingRange,options:[(value:.week,title:"未来七天"),(value:.month,title:"本月")],identifier:"fc.calendar.upcoming.choice")
                Text(upcomingRangeLabel).font(.system(size:11)).foregroundStyle(palette.muted).lineLimit(1).accessibilityIdentifier("fc.calendar.upcoming.range")
                Spacer(minLength:0)
                WBSelect("全部来源",selection:$upcomingSource,options:sourceOptions).frame(width:146,height:32).accessibilityIdentifier("fc.calendar.upcoming.source")
            }.frame(height:32).padding(.bottom,6)
            let entries=upcomingEntries
            if model.needsSystemConnection && !entries.isEmpty {connectPrompt(centered:false)}
            ScrollViewReader {scroll in
                WorkbenchScrollView {
                    LazyVStack(alignment:.leading,spacing:0) {
                        // Loading states belong to a connected system calendar only.
                        if upcomingRange == .week && model.preferences.calendarConnected && model.calendarAccess == .granted {
                            if model.isLoading && !hasUpcomingCoverage {
                                upcomingStatus("正在读取今天起七天的日程")
                            } else if model.overviewReadError != nil {
                                upcomingStatus("七天日程读取失败，请在来源中重试",warning:true)
                            } else if !hasUpcomingCoverage {
                                upcomingStatus("七天日程尚未完整载入，暂不能确认空闲")
                            }
                        }
                        if let error=model.remindersReadError {upcomingStatus(error,warning:true)}
                        // A notification problem belongs to this card, not the wallpaper (G3).
                        if let message=model.notificationMessage {upcomingStatus(message,warning:message.contains("失败"))}
                        if entries.isEmpty {
                            if model.needsSystemConnection {connectPrompt(centered:true)}
                            else {calendarEmpty(upcomingSource == "all" ? (upcomingRange == .week ? "未来七天暂无已载入的安排":"本月暂无已载入的安排"):"此来源暂无已载入的安排")}
                        }
                        let groups=groupedByDay(entries)
                        ForEach(groups,id:\.day) {group in
                            Text(WorkbenchDateText.monthDayWeekday(group.day,calendar:model.displayCalendar))
                                .font(.system(size:11)).foregroundStyle(palette.muted).frame(height:24,alignment:.bottom).padding(.bottom,2)
                                .id(group.day)
                            ForEach(Array(group.entries.enumerated()),id:\.element.id) {index,entry in
                                CalendarAgendaRow(model:model,entry:entry,last:index == group.entries.count-1)
                            }
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.accessibilityIdentifier("fc.calendar.upcoming.scroll")
                    // The month list opens at today when it shows the current month.
                    .onChange(of:upcomingRange) {_,range in
                        guard range == .month,let today=groupedByDay(monthItems).first(where:{$0.day >= model.displayCalendar.startOfDay(for:Date())})?.day else {return}
                        DispatchQueue.main.async {scroll.scrollTo(today,anchor:.top)}
                    }
            }
        }.padding(14).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(WorkbenchMaterialSurface())
            .accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.upcomingAgenda")
    }
    private func groupedByDay(_ entries:[CalendarAgendaEntry])->[(day:Date,entries:[CalendarAgendaEntry])] {
        let calendar=model.displayCalendar
        let floor=upcomingRange == .week ? upcomingInterval.start:Date.distantPast
        var result:[(day:Date,entries:[CalendarAgendaEntry])]=[]
        for entry in entries {
            let shown=max(ReminderQueries.displayDate(for:entry,calendar:calendar) ?? floor,floor)
            let day=calendar.startOfDay(for:shown)
            if let last=result.last,calendar.isDate(last.day,inSameDayAs:day) {result[result.count-1].entries.append(entry)}
            else {result.append((day:day,entries:[entry]))}
        }
        return result
    }
    /// Before the system calendar is connected, the right card offers it (K1).
    private func connectPrompt(centered:Bool)->some View {
        let text="接入系统日历后，这里同时显示"+(upcomingRange == .week ? "七天":"本月")+"日程"
        let button=Button("接入系统日历") {Task {await model.connectSystemSources()}}
            .buttonStyle(WBButtonStyle(primary:true,compact:true)).disabled(model.isWorking || model.storageError != nil)
            .accessibilityIdentifier("fc.calendar.connect-system")
        return Group {
            if centered {
                VStack(spacing:10) {
                    Image(systemName:"calendar.badge.checkmark").font(.system(size:24,weight:.light)).foregroundStyle(palette.accent)
                    Text(text).font(.system(size:12)).foregroundStyle(palette.secondary).multilineTextAlignment(.center)
                    button
                }.frame(maxWidth:.infinity).padding(.vertical,24)
            } else {
                HStack(spacing:10) {
                    Image(systemName:"calendar.badge.checkmark").font(.system(size:16)).foregroundStyle(palette.accent)
                    Text(text).font(.system(size:12)).foregroundStyle(palette.text).lineLimit(1)
                    Spacer(minLength:8)
                    button
                }.padding(.leading,12).padding(.trailing,8).frame(height:44)
                    .background(palette.accent.opacity(0.08),in:RoundedRectangle(cornerRadius:10)).padding(.bottom,4)
            }
        }.accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.system-connection")
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

private struct CalendarSideCard<Content:View,Footer:View>:View {
    let title:String
    let symbol:String
    var trailing:String?=nil
    var scrollIdentifier:String=""
    @ViewBuilder var content:()->Content
    @ViewBuilder var footer:()->Footer
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:7){Image(systemName:symbol).font(.system(size:16)).foregroundStyle(palette.accent);Text(title).font(.system(size:13,weight:.medium));Spacer();if let trailing {Text(trailing).font(.system(size:11)).foregroundStyle(palette.muted)}}.frame(height:22).padding(.bottom,6)
            WorkbenchScrollView {LazyVStack(alignment:.leading,spacing:0,content:content).frame(maxWidth:.infinity,alignment:.leading)}.scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight:.infinity,alignment:.top)
                .accessibilityIdentifier(scrollIdentifier)
            footer()
        }.padding(14).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(WorkbenchMaterialSurface())
    }
}
extension CalendarSideCard where Footer==EmptyView {
    init(title:String,symbol:String,trailing:String?=nil,scrollIdentifier:String="",@ViewBuilder content:@escaping ()->Content) {
        self.init(title:title,symbol:symbol,trailing:trailing,scrollIdentifier:scrollIdentifier,content:content,footer:{EmptyView()})
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
            label:"\(WorkbenchDateText.monthDay(date,calendar:calendar))，\(info.namedLabel ?? info.label)，\(entries.count) 项安排",
            identifier:"fc.calendar.day.\(calendarFormat(date,"yyyy-MM-dd",calendar:calendar))") {model.selectDay(date)}
    }
}

/// Seven equal columns without horizontal scrolling; an all-day row above the
/// hours, and an hour range that grows to the week's earliest and latest
/// timed items and scrolls inside the card (现行规范 9.3, K3).
private struct CalendarWeekGrid:View {
    @ObservedObject var model:CalendarModel
    let height:CGFloat
    @Environment(\.workbenchPalette) private var palette
    private let timeWidth:CGFloat=38
    private var calendar:Calendar {model.displayCalendar}
    private func entries(_ day:Date)->[CalendarAgendaEntry] {ReminderQueries.entries(reminders:model.reminders,events:model.visibleCalendarEvents,filter:.day,day:day,calendar:calendar)}
    private func span(_ entry:CalendarAgendaEntry,on day:Date)->(start:Double,end:Double)? {
        let dayStart=calendar.startOfDay(for:day),dayEnd=calendar.date(byAdding:.day,value:1,to:dayStart) ?? dayStart
        func hours(_ date:Date)->Double {max(0,min(24,date.timeIntervalSince(dayStart)/3600))}
        switch entry {
        case .event(let event):
            guard !event.isAllDay else {return nil}
            let start=event.start <= dayStart ? 0:hours(event.start),end=event.end >= dayEnd ? 24:hours(event.end)
            return (start,max(end,min(24,start+0.5)))
        case .reminder(let item):
            guard let due=item.due,due.hasTime,let date=due.date else {return nil}
            let start=hours(date); return (start,min(24,start+0.5))
        }
    }
    var body:some View {
        let days=model.weekDays
        let byDay=days.map {day in entries(day)}
        let allDay=zip(days,byDay).map {day,list in list.filter {span($0,on:day) == nil}}
        let timed=zip(days,byDay).map {day,list in list.compactMap {entry in span(entry,on:day).map {(entry:entry,start:$0.start,end:$0.end)}}}
        let starts=timed.flatMap {$0.map(\.start)},ends=timed.flatMap {$0.map(\.end)}
        let first=max(0,min(8,Int((starts.min() ?? 8).rounded(.down))))
        let last=min(24,max(20,Int((ends.max() ?? 20).rounded(.up))))
        let allDayRows=max(1,min(3,allDay.map(\.count).max() ?? 1))
        let allDayHeight=8+CGFloat(allDayRows)*22
        let viewport=max(60,height-30-4-allDayHeight-6)
        let hourHeight=max(20,viewport/CGFloat(last-first))
        GeometryReader {geometry in
            let column=max(0,(geometry.size.width-timeWidth)/7)
            VStack(spacing:0) {
                HStack(spacing:0) {
                    Color.clear.frame(width:timeWidth)
                    ForEach(days,id:\.self) {day in dayHeader(day).frame(width:column)}
                }.frame(height:30)
                HStack(spacing:0) {
                    Text("全天").font(.system(size:11)).foregroundStyle(palette.muted).frame(width:timeWidth,alignment:.leading).frame(maxHeight:.infinity,alignment:.top).padding(.top,6)
                    ForEach(Array(days.enumerated()),id:\.offset) {index,_ in
                        VStack(alignment:.leading,spacing:2) {
                            ForEach(allDay[index].prefix(allDayRows)) {entry in block(entry,time:nil,height:20)}
                            if allDay[index].count > allDayRows {Text("另有 \(allDay[index].count-allDayRows) 项").font(.system(size:11)).foregroundStyle(palette.muted)}
                        }.padding(.horizontal,2).padding(.vertical,4).frame(width:column,alignment:.topLeading).frame(maxHeight:.infinity,alignment:.top)
                            .overlay(alignment:.leading) {palette.line.frame(width:1)}
                    }
                }.frame(height:allDayHeight).padding(.top,4)
                    .overlay(alignment:.top) {palette.line.frame(height:1).padding(.top,4)}.overlay(alignment:.bottom) {palette.line.frame(height:1)}
                WorkbenchScrollView {
                    ZStack(alignment:.topLeading) {
                        ForEach(Array(stride(from:first,through:last,by:2)),id:\.self) {hour in
                            let y=CGFloat(hour-first)*hourHeight
                            palette.line.frame(height:1).padding(.leading,timeWidth).offset(y:y)
                            if hour < last {Text(String(format:"%02d:00",hour)).font(.system(size:11)).monospacedDigit().foregroundStyle(palette.muted).offset(y:y+2)}
                        }
                        ForEach(0..<7,id:\.self) {index in palette.line.frame(width:1,height:CGFloat(last-first)*hourHeight).offset(x:timeWidth+CGFloat(index)*column)}
                        ForEach(Array(timed.enumerated()),id:\.offset) {index,items in
                            let lanes=lanes(items)
                            ForEach(Array(items.enumerated()),id:\.offset) {position,item in
                                let lane=lanes.lane[position],count=CGFloat(lanes.count)
                                let laneWidth=max(0,(column-4)/count)
                                let top=CGFloat(item.start-Double(first))*hourHeight
                                let blockHeight=max(18,CGFloat(item.end-item.start)*hourHeight-2)
                                block(item.entry,time:calendarTime(item.entry,calendar:calendar),height:blockHeight)
                                    .frame(width:max(0,laneWidth-(lanes.count > 1 ? 2:0)))
                                    .offset(x:timeWidth+CGFloat(index)*column+2+CGFloat(lane)*laneWidth,y:top+1)
                            }
                        }
                    }.frame(width:geometry.size.width,height:CGFloat(last-first)*hourHeight,alignment:.topLeading)
                }.frame(height:viewport).padding(.top,6).scrollBounceBehavior(.basedOnSize)
            }
        }.frame(height:height).accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.week")
    }
    /// Overlapping items in a day share the column side by side.
    private func lanes(_ items:[(entry:CalendarAgendaEntry,start:Double,end:Double)])->(lane:[Int],count:Int) {
        var ends:[Double]=[],result:[Int]=[]
        for item in items {
            if let free=ends.firstIndex(where:{$0 <= item.start}) {ends[free]=item.end;result.append(free)}
            else {ends.append(item.end);result.append(ends.count-1)}
        }
        return (result,max(1,ends.count))
    }
    private func dayHeader(_ date:Date)->some View {
        let info=CalendarCivilDay(date:date,calendar:calendar,showsHolidays:model.holidaysEnabled)
        let selected=calendar.isDate(date,inSameDayAs:model.selectedDay),today=calendar.isDateInToday(date)
        return Button {model.selectDay(date)} label:{
            HStack(spacing:4){Text(WorkbenchDateText.weekday(date,calendar:calendar)+" \(calendar.component(.day,from:date))").font(.system(size:11));CalendarHolidayBadge(day:info)}
                .foregroundStyle(WorkbenchCalendarDayStyle.textColor(selected:selected,today:today,palette:palette))
                .frame(maxWidth:.infinity).frame(height:30)
        }.buttonStyle(WorkbenchCalendarDayStyle(selected:selected,today:today))
            .accessibilityLabel(WorkbenchDateText.monthDay(date,calendar:calendar)+(info.namedLabel.map{"，"+$0} ?? ""))
            .accessibilityValue(selected ? "已选择":"未选择")
            .accessibilityIdentifier("fc.calendar.weekday."+calendarFormat(date,"yyyy-MM-dd",calendar:calendar))
    }
    /// Blocks carry no border: a light schedule or accent tint (K5).
    private func block(_ entry:CalendarAgendaEntry,time:String?,height:CGFloat)->some View {
        let event:Bool={if case .event=entry {return true};return false}()
        let tint=event ? palette.cool:palette.accent
        return Button {open(entry)} label:{
            VStack(alignment:.leading,spacing:1) {
                Text(entry.title).lineLimit(1).strikethrough(entry.isCompleted)
                if let time,height >= 34 {Text(time).foregroundStyle(palette.secondary).lineLimit(1)}
            }.font(.system(size:11)).foregroundStyle(entry.isCompleted ? palette.muted:palette.text)
                .padding(.horizontal,5).padding(.vertical,2).frame(maxWidth:.infinity,minHeight:height,maxHeight:height,alignment:.topLeading)
                .background(tint.opacity(entry.isCompleted ? 0.06:0.14),in:RoundedRectangle(cornerRadius:6))
                .contentShape(RoundedRectangle(cornerRadius:6))
        }.buttonStyle(WBSelectableButtonStyle(cornerRadius:6,showsBorder:false)).help(entry.title)
            .accessibilityLabel("\(entry.title)，\(calendarTime(entry,calendar:calendar))")
    }
    private func open(_ entry:CalendarAgendaEntry){switch entry {case .reminder(let item):model.selectedReminder=item;case .event(let item):model.selectedEvent=item}}
}

/// A list row (现行规范 4.5, K5): 36 with the time on the right, or 52 with
/// a second line for the source. No tinted box or border; the icon carries
/// the schedule or accent color.
private struct CalendarAgendaRow:View {
    @ObservedObject var model:CalendarModel
    let entry:CalendarAgendaEntry
    var showTime=true
    var last=false
    @Environment(\.workbenchPalette) private var palette
    @State private var hovering=false
    private var event:Bool {if case .event = entry {return true};return false}
    private var tint:Color {event ? palette.cool:palette.accent}
    var body:some View {
        HStack(alignment:.center,spacing:9) {
            if case .reminder(let item)=entry {
                Button {Task {await model.toggle(item)}} label:{
                    ZStack {
                        Circle().strokeBorder(tint,lineWidth:1.5)
                        if item.isCompleted {Circle().fill(tint);Image(systemName:"checkmark").font(.system(size:9,weight:.bold)).foregroundStyle(palette.primaryText)}
                    }.frame(width:16,height:16).padding(3).contentShape(Rectangle())
                }.buttonStyle(ClickablePlainButtonStyle()).disabled(!item.isWritable || model.isWorking)
                    .accessibilityLabel("\(item.isCompleted ? "恢复待办":"完成提醒")：\(item.title)")
                    .accessibilityIdentifier("fc.calendar.complete."+item.stableID)
            } else {Image(systemName:"calendar").font(.system(size:16)).foregroundStyle(tint).frame(width:22)}
            Button {switch entry {case .reminder(let item):model.selectedReminder=item;case .event(let event):model.selectedEvent=event}} label:{
                HStack(spacing:8) {
                    VStack(alignment:.leading,spacing:3) {
                        Text(entry.title).font(.system(size:13,weight:.medium)).foregroundStyle(entry.isCompleted ? palette.muted:palette.text).strikethrough(entry.isCompleted).lineLimit(1)
                        if !showTime {Text(detail).font(.system(size:11)).foregroundStyle(palette.muted).lineLimit(1)}
                    }
                    Spacer(minLength:0)
                    if showTime {Text(timeText).font(.system(size:11)).foregroundStyle(palette.secondary).lineLimit(1).fixedSize()}
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(ClickablePlainButtonStyle())
        }.padding(.horizontal,4).frame(maxWidth:.infinity).frame(height:showTime ? 36:52)
            .background(hovering ? palette.accent.opacity(0.06):.clear,in:RoundedRectangle(cornerRadius:6))
            .overlay(alignment:.bottom) {if !last {palette.line.frame(height:1)}}
            .onHover {hovering=$0}
            .accessibilityElement(children:.contain).accessibilityIdentifier("fc.calendar.entry."+entry.id)
    }
    private var timeText:String {
        switch entry {
        case .reminder(let item):
            guard let due=item.due else {return "无期限"}
            return due.hasTime ? calendarTime(entry,calendar:model.displayCalendar)+" 截止":"当天截止"
        case .event(let event):
            return event.isAllDay ? "全天":calendarFormat(event.start,"HH:mm",calendar:model.displayCalendar)+"–"+calendarFormat(event.end,"HH:mm",calendar:model.displayCalendar)
        }
    }
    private var detail:String {
        switch entry {
        case .reminder(let item):
            let deadline=item.due == nil ? "无期限":calendarEntryShortDate(entry,calendar:model.displayCalendar)+(item.due?.hasTime == true ? " "+calendarTime(entry,calendar:model.displayCalendar):"")+" 截止"
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
            .onAppear {syncZone()}
            .onReceive(context?.objectWillChange.eraseToAnyPublisher() ?? Empty<Void,Never>().eraseToAnyPublisher()) {_ in Task {@MainActor in syncZone()}}
            .workbenchModal(isPresented:Binding(get:{model.shouldPresentOperationError},set:{if !$0 {model.errorMessage=nil}}),onRequestDismiss:{model.errorMessage=nil}) {
                CalendarOperationErrorDialog(model:model)
            }
    }
    private func syncZone(){if let context,model.displayTimeZone != context.dateContext.timeZone {model.displayTimeZone=context.dateContext.timeZone}}
}

private struct CalendarOperationErrorDialog:View {
    @ObservedObject var model:CalendarModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        CalendarDialog(title:model.permissionSettingsTargets.isEmpty ? "操作未完成":"需要访问权限",dismiss:{model.errorMessage=nil}) {
            Text(model.errorMessage ?? "").font(.system(size:12)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal:false,vertical:true)
        } actions:{
            Spacer()
            Button("知道了"){model.errorMessage=nil}.buttonStyle(WBButtonStyle(primary:model.permissionSettingsTargets.isEmpty)).keyboardShortcut(.cancelAction)
            ForEach(model.permissionSettingsTargets) {target in
                Button(model.permissionSettingsTargets.count == 1 ? "前往系统设置":"\(target.title)设置") {model.openPrivacySettings(reminders:target.isReminders)}
                    .buttonStyle(WBButtonStyle(primary:true))
                    .accessibilityIdentifier("fc.calendar.permission.settings."+target.rawValue)
            }
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
    // Calendar dialogs use the shared frame: 15 medium title, 32 close button (现行规范 4.7).
    var body:some View {
        WorkbenchDialogFrame(title:title,dismiss:dismiss,maximumBodyHeight:380) {
            VStack(alignment:.leading,spacing:16,content:content)
        } actions:{actions()}.frame(width:width)
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


private struct CalendarReminderList:View {
    @ObservedObject var model:CalendarModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {CalendarDialog(title:"全部提醒",dismiss:{model.showReminderList=false}){
        HStack(spacing:8){WBSegmentedChoice(selection:$model.filter,options:[ReminderFilter.all,.completed,.undated].map{(value:$0,title:$0 == .all ? "待办":$0.title)});Spacer();WBSelect("提醒来源",selection:$model.reminderListSource,options:[(value:"all",title:"全部来源"),(value:"local",title:"本机提醒"),(value:"system",title:"系统提醒事项")]).frame(width:120)}
        HStack(spacing:7){Image(systemName:"magnifyingglass").foregroundStyle(palette.muted);TextField("搜索标题、备注与来源",text:$model.search).textFieldStyle(.plain)}.modifier(WBFieldSurface())
        if model.allReminderEntries.isEmpty {Text("暂无提醒").font(.system(size:12)).foregroundStyle(palette.muted).frame(maxWidth:.infinity).padding(.vertical,25)}
        let entries=model.allReminderEntries
        VStack(spacing:0){ForEach(Array(entries.enumerated()),id:\.element.id){index,entry in CalendarAgendaRow(model:model,entry:entry,showTime:false,last:index == entries.count-1)}}
        if let undo=model.undoMessage {HStack{Text(undo).font(.system(size:11));Spacer();Button("撤销"){Task {await model.undoLastChange()}}.buttonStyle(WBButtonStyle(compact:true))}}
    } actions:{Spacer();Button("新建提醒"){model.showReminderList=false;model.openNewReminder()}.buttonStyle(WBButtonStyle(primary:true))}}
}

private struct CalendarSourcesPage:View {
    @ObservedObject var model:CalendarModel
    let onBack:()->Void
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var calendarsExpanded = false
    @State private var sourceSearch = ""
    private var filteredSources: [CalendarSourceDescriptor] {
        let query = sourceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.calendarSources.filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.account.localizedStandardContains(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func accountName(_ source: CalendarSourceDescriptor) -> String { source.account.isEmpty ? "其他日历" : source.account }
    private var accounts: [String] { Array(Set(filteredSources.map(accountName))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            // The way back sits before the title (现行规范 4.1, D7).
            WBPageHeader(title:"日历来源",subtitle:"按来源管理日程、提醒与授权状态",
                         back:WBPageBack(title:model.sourcesReturnToPrivacy ? "隐私与锁定":"日历与提醒",identifier:"calendar-sources-back",escapes:true) {model.errorMessage=nil;onBack()})
            VStack(spacing:12) {
                // Rows follow the shared setting row (现行规范 4.5, G1).
                WBCard(title:"系统来源",symbol:"calendar",spacing:0) {
                    systemCalendarRow
                    if calendarsExpanded && model.preferences.calendarConnected && model.calendarAccess == .granted { calendarSourceList }
                    WBSettingRow(title:"系统提醒事项",subtitle:connectionSubtitle(reminders:true)) { connectionControls(reminders:true) }
                }
                WBCard(title:"中国大陆节假日",symbol:"calendar",spacing:0) {
                    WBSettingRow(title:"放假与调休",subtitle:"关闭后隐藏官方放假、休息与补班标记",showsDivider:false) {
                        Toggle("显示中国大陆节假日",isOn:Binding(get:{model.holidaysEnabled},set:{model.setHolidaysEnabled($0)}))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(palette.accent).clickableCursor()
                            .accessibilityIdentifier("calendar-source-holidays")
                    }
                    WBSettingRow(title:"传统节日与农历",subtitle:"节日与调休分别标记，不把节日都视为放假") { WBStatusPill(title:"独立显示") }
                    WBSettingRow(title:"地区与日期",subtitle:"按中国大陆民用日期标注，不随显示时区偏移") { WBStatusPill(title:"中国大陆") }
                }
                WBCard(title:"本机内容",symbol:"internaldrive",spacing:0) {
                    WBSettingRow(title:"本机提醒",subtitle:"保存在此设备，无需日历权限",showsDivider:false) {
                        WBStatusPill(title:model.storageError == nil ? "可用":"数据不可用",good:model.storageError == nil)
                    }
                    WBSettingRow(title:"提醒通知",subtitle:"不授权通知也可以保存提醒") {
                        Button(model.preferences.notificationsEnabled && model.notificationAccess == .granted ? "已允许 · 管理":"管理通知"){model.showNotifications=true}.buttonStyle(WBButtonStyle(compact:true))
                    }
                }
                // Supporting copy sits on the note backing (现行规范 3.4).
                WBPageNote {
                    VStack(alignment:.leading,spacing:4) {
                        Text("日程直接读取系统日历，提醒事项可在原系统列表中创建、编辑与完成。断开只停止同步，不删除系统内容；原有本机提醒也不会自动迁移。节假日资料按年度载入，不推算未知年份的调休。")
                            .fixedSize(horizontal:false,vertical:true)
                        HStack(spacing:12) {
                            Link(WorkbenchChinaHolidays.sourceTitle,destination:WorkbenchChinaHolidays.sourceURL)
                            Text("数据版本："+WorkbenchChinaHolidays.datasetVersion).foregroundStyle(palette.muted)
                        }
                    }
                }
            }
        }
    }
    private var systemCalendarRow: some View {
        let disclosure=Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { calendarsExpanded.toggle() }
        } label: {
            Image(systemName: calendarsExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondary)
                .frame(width: 12, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).clickableCursor().padding(.trailing,-8)
            .accessibilityLabel("系统日历列表").accessibilityValue(calendarsExpanded ? "已展开" : "已折叠")
            .accessibilityIdentifier("calendar-source-disclosure")
        let hasList=model.preferences.calendarConnected && model.calendarAccess == .granted
        return WBSettingRow(title:"系统日历",subtitle:connectionSubtitle(reminders:false),showsDivider:false,leading:hasList ? AnyView(disclosure):nil) {
            connectionControls(reminders:false)
        }.onChange(of: model.preferences.calendarConnected) { _, _ in calendarsExpanded = false; sourceSearch = "" }
    }
    /// One calendar per 36-point row; "只读显示" is already in the system row's state (D4).
    @ViewBuilder private var calendarSourceList: some View {
        if model.preferences.calendarConnected && model.calendarAccess == .granted {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                    TextField("搜索日历或账号", text: $sourceSearch).textFieldStyle(.plain)
                        .accessibilityIdentifier("calendar-source-search")
                }.modifier(WBFieldSurface())
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if filteredSources.isEmpty {
                            Text(sourceSearch.isEmpty ? "此来源暂无可用日历" : "未找到匹配的日历")
                                .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.vertical, 14)
                        }
                        ForEach(accounts, id: \.self) { account in
                            Text(account).font(.system(size: 11)).foregroundStyle(palette.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24, alignment: .bottom).padding(.bottom, 2)
                            let sources = filteredSources.filter { accountName($0) == account }
                            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                                HStack(spacing: 10) {
                                    Image(systemName: "calendar").font(.system(size: 14)).foregroundStyle(palette.cool)
                                    Text(source.title).font(.system(size: 12)).lineLimit(1).help(source.title)
                                    Spacer(minLength: 8)
                                    Toggle("显示" + source.title, isOn: Binding(get: { model.isSourceVisible(source.id) }, set: { model.setSourceVisible(source.id, $0) }))
                                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(palette.accent).clickableCursor()
                                }.frame(height: 36).overlay(alignment: .bottom) { if index < sources.count - 1 { palette.line.frame(height: 1) } }
                                    .accessibilityElement(children: .contain)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: min(300, max(36, CGFloat(filteredSources.count * 36 + accounts.count * 26))))
                    .scrollBounceBehavior(.basedOnSize).accessibilityIdentifier("calendar-source-list")
            }.padding(.leading, 28).padding(.bottom, 10)
        }
    }
    /// The connection state is written into the description (G1).
    private func connectionSubtitle(reminders: Bool) -> String {
        let access = reminders ? model.remindersAccess : model.calendarAccess
        let connected = reminders ? model.preferences.remindersConnected : model.preferences.calendarConnected
        if model.connectingSource == (reminders ? .reminders : .calendar) { return "正在请求授权" }
        let ready = connected && access == .granted
        let state = ready ? (reminders ? "已连接" : "已连接 · 只读") : connected ? "权限已关闭" : access == .denied ? "未连接 · 未授权" : access == .restricted ? "受限" : "未连接"
        let detail: String
        if reminders { detail = ready ? "可在可写列表中创建与完成提醒" : "接入后可在可写列表中创建与完成提醒" }
        else { detail = ready ? "显示 \(model.calendarSources.filter { model.isSourceVisible($0.id) }.count) / \(model.calendarSources.count) 个日历" : "读取日程，保留原日历的来源与只读状态" }
        return state + " · " + detail
    }
    private func connectionControls(reminders: Bool) -> some View {
        let access = reminders ? model.remindersAccess : model.calendarAccess
        let connected = reminders ? model.preferences.remindersConnected : model.preferences.calendarConnected
        return HStack(spacing: 8) {
            if access == .denied || access == .restricted { Button("隐私设置") { model.openPrivacySettings(reminders: reminders) }.buttonStyle(WBButtonStyle(compact: true)) }
            if model.connectingSource == (reminders ? .reminders : .calendar) { ProgressView().controlSize(.mini).frame(width: 14, height: 14) }
            Toggle(reminders ? "连接系统提醒事项" : "连接系统日历", isOn: Binding(get: { connected && access == .granted }, set: { enabled in
                if !reminders { calendarsExpanded = false; sourceSearch = "" }
                Task { if enabled { await model.connect(reminders: reminders) } else { await model.disconnect(reminders: reminders) } }
            })).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(palette.accent).clickableCursor()
                .disabled(model.isWorking)
                .accessibilityIdentifier(reminders ? "calendar-source-system-reminders" : "calendar-source-system-events")
        }.fixedSize(horizontal: true, vertical: false)
    }
}

private struct CalendarNotificationsDialog:View {
    @ObservedObject var model:CalendarModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        CalendarDialog(title:"提醒通知",dismiss:close) {
            Text("到时间，轻轻提醒你").font(.system(size:13,weight:.medium))
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
            Text(badge).font(.system(size:8,weight:.medium)).foregroundStyle(day.color(palette))
                .padding(.horizontal,2).frame(height:11)
                .background(day.color(palette).opacity(0.08),in:RoundedRectangle(cornerRadius:3))
                .accessibilityLabel(day.namedLabel ?? day.label)
        }
    }
}
private extension CalendarAgendaEntry {var isSystemEvent:Bool {if case .event=self {return true};return false}}
private func calendarFormat(_ date:Date,_ format:String,calendar:Calendar)->String {let f=DateFormatter();f.locale=Locale(identifier:"zh_CN");f.calendar=calendar;f.timeZone=calendar.timeZone;f.dateFormat=format;return f.string(from:date)}
/// Details carry the full date (现行规范 5.3); rows use the short date (G2).
private func calendarEntryDate(_ entry:CalendarAgendaEntry,calendar:Calendar)->String {ReminderQueries.displayDate(for:entry,calendar:calendar).map{WorkbenchDateText.full($0,calendar:calendar)} ?? "未定日期"}
private func calendarEntryShortDate(_ entry:CalendarAgendaEntry,calendar:Calendar)->String {ReminderQueries.displayDate(for:entry,calendar:calendar).map{WorkbenchDateText.monthDay($0,calendar:calendar)} ?? "未定日期"}
private func calendarTime(_ entry:CalendarAgendaEntry,calendar:Calendar)->String {
    switch entry {
    case .reminder(let item):guard let due=item.due else{return "待定"};return due.hasTime ? due.date.map{calendarFormat($0,"HH:mm",calendar:calendar)} ?? "不可用":"全天"
    case .event(let event):return event.isAllDay ? "全天":calendarFormat(event.start,"HH:mm",calendar:calendar)
    }
}
