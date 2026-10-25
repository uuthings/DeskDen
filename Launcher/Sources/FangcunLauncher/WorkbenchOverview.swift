import SwiftUI
import LauncherCore

struct WorkbenchOverview:View {
    @ObservedObject var device:DeviceStatusModel
    @ObservedObject var calendar:CalendarModel
    @ObservedObject var health:HealthCenterModel
    @ObservedObject var context:WorkbenchContextModel
    var navigate:(WorkbenchRoute)->Void
    var openHealth:()->Void
    var openDevice:(DeviceCardID)->Void
    @State private var selectedDay:Date?
    @State private var availableWidth:CGFloat=864
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchDeviceExpanded) private var expanded
    private var compact:Bool {availableWidth<800}
    private var displayCalendar:Calendar {context.dateContext.calendar}
    private var day:Date {selectedDay ?? Date()}
    private var events:[CalendarEventItem] {calendar.overviewEvents.filter{$0.occurs(on:day,calendar:displayCalendar)}.sorted{$0.start<$1.start}}
    private var reminders:[ReminderItem] {calendar.reminders.filter{item in
        guard let due=item.due else {return false}
        return due.hasTime ? due.date.map{displayCalendar.isDate($0,inSameDayAs:day)} ?? false:due.isSameDay(as:day,calendar:displayCalendar)
    }.sorted{($0.due?.date ?? .distantFuture)<($1.due?.date ?? .distantFuture)}}
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            WBPageHeader(title:"首页",subtitle:"常用之物，皆在方寸之间") {contextHeader}
            VStack(spacing:12) {
                HStack(alignment:.top,spacing:12) {
                    healthCard.frame(maxWidth:.infinity)
                    deviceCard.frame(width:max(280,(availableWidth-12)/(compact ? 2.32:2.38)))
                }.fixedSize(horizontal:false,vertical:true)
                agenda
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
        .background(GeometryReader{geometry in Color.clear.onAppear{availableWidth=geometry.size.width}.onChange(of:geometry.size.width){_,value in availableWidth=value}})
        .onChange(of:context.dateContext){_,_ in selectedDay=nil}
        .accessibilityElement(children:.contain).accessibilityIdentifier("fc.page.home")
    }
    private var contextHeader:some View {
        HStack(spacing:14) {
            Button{context.showWeather=true}label:{
                HStack(spacing:8) {
                    Image(systemName:weatherSymbol(context.weather?.snapshot?.weatherCode,isDay:context.weather?.snapshot?.isDay)).font(.system(size:25,weight:.light))
                    VStack(alignment:.leading,spacing:3) {
                        Text(weatherTemperature(context.weather?.snapshot?.temperatureCelsius)).font(.system(size:16,weight:.medium))
                        Text((context.settings.city?.name ?? "选择城市")+(context.weather?.freshness == .stale ? " · 已过期":"")).font(.system(size:11)).foregroundStyle(palette.muted)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(ClickablePlainButtonStyle()).accessibilityLabel("查看天气与城市")
            TimelineView(.periodic(from:.now,by:1)) {timeline in
                Button{context.showClock=true}label:{
                    HStack(spacing:compact ? 8:14) {
                        Text(context.time(timeline.date,seconds:true)).font(.system(size:compact ? 25:30,weight:.regular)).monospacedDigit()
                        VStack(alignment:.leading,spacing:3) {
                            if let date=try? context.dateContext.display(at:timeline.date) {
                                Text("\(displayCalendar.component(.month,from:timeline.date)) 月 \(displayCalendar.component(.day,from:timeline.date)) 日  "+date.weekdayText).font(.system(size:compact ? 11:12)).foregroundStyle(palette.secondary)
                            }
                            HStack(spacing:4){Text(WorkbenchContextModel.zoneTitle(context.dateContext.timeZoneIdentifier,at:timeline.date));Image(systemName:"chevron.down").font(.system(size:9))}.font(.system(size:11)).foregroundStyle(palette.muted)
                        }
                    }.padding(.leading,10).frame(minHeight:46).contentShape(Rectangle())
                }.buttonStyle(ClickablePlainButtonStyle()).accessibilityLabel("日期时间与时区")
            }
        }
    }
    private var healthCard:some View {
        HStack(spacing:expanded ? 32:24) {
            VStack(spacing:7) {
                HealthScoreRingView(score:health.score,size:expanded ? 202:compact ? 142:164)
                Text(health.latestReport.map {report in
                    let day=displayCalendar.isDate(report.finishedAt,inSameDayAs:Date()) ? "":"\(displayCalendar.component(.month,from:report.finishedAt))/\(displayCalendar.component(.day,from:report.finishedAt)) "
                    return "上次体检 · "+day+context.time(report.finishedAt)
                } ?? "尚未完成评估").font(.system(size:11)).foregroundStyle(palette.muted)
            }
            VStack(alignment:.leading,spacing:0) {
                Label("设备状态",systemImage:"heart.text.square").font(.system(size:11)).foregroundStyle(palette.secondary)
                Text(health.score == nil ? "了解状态，再从容安排":health.summary).font(.system(size:expanded ? 25:compact ? 18:20,weight:.semibold)).lineSpacing(4).padding(.top,11).padding(.bottom,8)
                Text(health.assessmentDescription).font(.system(size:expanded ? 13:compact ? 11:12)).foregroundStyle(palette.secondary).lineSpacing(5).fixedSize(horizontal:false,vertical:true)
                Button(action:openHealth){Label("前往体检中心",systemImage:"heart.text.square")}.buttonStyle(WBButtonStyle(primary:true)).accessibilityIdentifier("home-open-health").padding(.top,expanded ? 20:14)
                Text(health.latestReport == nil ? "根据本机有效读数评估":health.coverageText).font(.system(size:11)).foregroundStyle(palette.muted).padding(.top,8)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(14).frame(minHeight:expanded ? 310:compact ? 288:269).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.center)
            .background(WorkbenchMaterialSurface(radius:15))
    }
    private var deviceCard:some View {
        let s=device.snapshot
        return VStack(alignment:.leading,spacing:0) {
            HStack(spacing:7){Image(systemName:"laptopcomputer").font(.system(size:16,weight:.light)).foregroundStyle(palette.secondary);Text("这台 Mac").font(.system(size:12,weight:.medium));Spacer();Button{navigate(.device)}label:{Image(systemName:"arrow.up.right")}.buttonStyle(WBIconButtonStyle(size:28)).accessibilityLabel("查看设备状态").accessibilityIdentifier("home-device-detail")}.frame(height:22).padding(.bottom,10)
            VStack(alignment:.leading,spacing:compact ? 4:0) {
                if compact {Text(s.deviceName).font(.system(size:15,weight:.medium));deviceIdentity(s)}
                else {HStack(alignment:.firstTextBaseline,spacing:9){Text(s.deviceName).font(.system(size:expanded ? 18:15,weight:.medium)).lineLimit(1);deviceIdentity(s)}}
            }.padding(.bottom,expanded ? 24:14).padding(.top,expanded ? 9:0)
            HStack(alignment:.top,spacing:compact ? 12:18) {
                metric("存储可用",symbol:"internaldrive",used:s.disk?.available,total:s.disk?.total,percent:s.disk?.percent,note:s.disk.map{"已用 "+DeviceFormat.capacity($0.used)} ?? "等待有效采样",warning:(s.disk?.percent ?? 0)>=80,progressLabel:"存储已用比例"){openDevice(.storage)}
                metric("内存已用",symbol:"memorychip",used:s.memory?.used,total:s.memory?.total,percent:s.memory?.percent,note:s.memory.map{"压力"+pressureTitle($0.pressure)} ?? "等待有效采样",warning:s.memory?.pressure == .warning || s.memory?.pressure == .critical){openDevice(.memory)}
            }.frame(maxHeight:.infinity,alignment:.top)
            Rectangle().fill(palette.line).frame(height:1).padding(.top,expanded ? 22:15).padding(.bottom,expanded ? 16:12)
            HStack(alignment:.center,spacing:12) {
                Button{openDevice(.thermal)}label:{VStack(alignment:.leading,spacing:4){Label(s.battery.map{String(format:"%.0f%%",$0.percent)} ?? "—",systemImage:s.battery?.isPluggedIn == true ? "battery.100.bolt":"battery.100").font(.system(size:12));Text(s.battery.map{$0.isPluggedIn ? "已连接电源":"使用电池"} ?? "电源读数不可用").font(.system(size:11)).foregroundStyle(palette.muted)}}.buttonStyle(ClickablePlainButtonStyle())
                Spacer(minLength:0)
                Button{navigate(.network)}label:{VStack(alignment:.trailing,spacing:4){Text("↓ "+DeviceFormat.rate(s.network.downloadBytesPerSecond)+"  ·  ↑ "+DeviceFormat.rate(s.network.uploadBytesPerSecond)).font(.system(size:compact ? 10:11)).lineLimit(1).minimumScaleFactor(0.8);Text(todayTraffic).font(.system(size:11)).foregroundStyle(palette.muted)}}.buttonStyle(ClickablePlainButtonStyle())
            }
        }.padding(14).frame(minHeight:expanded ? 310:compact ? 288:269).frame(maxHeight:.infinity).background(WorkbenchMaterialSurface(radius:15))
    }
    private func deviceIdentity(_ s:DeviceSnapshot)->some View {Text(s.chipName+" · "+DeviceFormat.capacity(s.memory?.total)).font(.system(size:11)).foregroundStyle(palette.muted).lineLimit(1).minimumScaleFactor(0.8)}
    private var todayTraffic:String {let summary=device.trafficSummary(period:.day,scope:.all);return "今日已记录 "+(summary.coveredSeconds>0 ? DeviceTrafficDisplay.adaptive(summary.totalBytes):"—")}
    private func metric(_ title:String,symbol:String,used:UInt64?,total:UInt64?,percent:Double?,note:String,warning:Bool,progressLabel:String="内存已用比例",action:@escaping()->Void)->some View {
        Button(action:action) {VStack(alignment:.leading,spacing:0) {
            Label(title,systemImage:symbol).font(.system(size:11)).foregroundStyle(palette.secondary)
            HStack(alignment:.firstTextBaseline,spacing:3){Text(used.map{String(format:"%.1f",Double($0)/1_073_741_824)} ?? "—").font(.system(size:expanded ? 30:compact ? 23:25,weight:.medium));Text("GB").font(.system(size:11)).foregroundStyle(palette.muted)}.monospacedDigit().padding(.top,7).padding(.bottom,3)
            Text("共 "+DeviceFormat.capacity(total)).font(.system(size:11)).foregroundStyle(palette.muted)
            WBProgress(value:(percent ?? 0)/100,color:warning ? palette.warning:nil).accessibilityLabel(progressLabel).padding(.top,8).padding(.bottom,6)
            Text(note).font(.system(size:11)).foregroundStyle(palette.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())}.buttonStyle(ClickablePlainButtonStyle()).accessibilityIdentifier(title == "存储可用" ? "home-storage-readout" : "home-memory-readout").accessibilityLabel(title+"，"+DeviceFormat.capacity(used)+"，"+note)
    }
    private var agenda:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:7) {
                Image(systemName:"note.text").font(.system(size:16,weight:.light)).foregroundStyle(palette.secondary)
                Text(displayCalendar.isDateInToday(day) ? "今天的安排":"\(displayCalendar.component(.month,from:day)) 月 \(displayCalendar.component(.day,from:day)) 日的安排").font(.system(size:12,weight:.medium))
                if !compact {Text("\(events.count) 项日程 · \(reminders.filter{!$0.isCompleted}.count) 项待办").font(.system(size:11)).foregroundStyle(palette.muted).padding(.leading,6)}
                Spacer(minLength:0)
                Button{calendar.selectDay(day);calendar.openNewReminder()}label:{Image(systemName:"plus")}.buttonStyle(WBIconButtonStyle(size:28)).accessibilityLabel("新建提醒")
                Button{calendar.selectDay(day);navigate(.calendar)}label:{Label("打开日历",systemImage:"arrow.up.right")}.buttonStyle(WBQuietButtonStyle())
            }.frame(height:22).padding(.bottom,10)
            weekStrip.padding(.bottom,expanded ? 16:12)
            HStack(alignment:.top,spacing:expanded ? 32:compact ? 18:24) {
                planColumn(title:"日程",subtitle:"\(events.count) 项",items:events.map(CalendarAgendaEntry.event),empty:"这一天没有日程，留一点从容的时间。")
                Rectangle().fill(palette.line).frame(width:1,height:expanded ? 179:131)
                planColumn(title:"待办",subtitle:"\(reminders.filter{!$0.isCompleted}.count) 项未完成",items:reminders.map(CalendarAgendaEntry.reminder),empty:"没有待办提醒。想到什么，随手记下来。")
            }
            HStack(spacing:10) {
                if let undo=calendar.undoMessage {Text(undo).lineLimit(1);Button("撤销"){Task{await calendar.undoLastChange()}}.buttonStyle(WBQuietButtonStyle()).disabled(calendar.isWorking)}
                else {Text("日程与提醒在这里，也与你的日历保持一致。").lineLimit(1)}
                Spacer(minLength:0)
            }.font(.system(size:11)).foregroundStyle(palette.muted).frame(height:28).padding(.top,6)
        }.padding(14).frame(minHeight:expanded ? 367:277).background(WorkbenchMaterialSurface(radius:15))
            .accessibilityElement(children:.contain).accessibilityIdentifier("fc.home.agenda")
    }
    private var weekStrip:some View {
        let stripWidth = min(WorkbenchCalendarDayMetrics.maximumHomeWidth, max(0, availableWidth - 28))
        let cellWidth = max(0, (stripWidth - 36) / 7)
        let cellHeight = WorkbenchCalendarDayMetrics.height(forWidth:cellWidth)
        return VStack(spacing:5) {
            HStack(spacing:6) {ForEach(0..<7,id:\.self){offset in
                let date=displayCalendar.date(byAdding:.day,value:offset,to:displayCalendar.startOfDay(for:Date())) ?? Date()
                Text(offset == 0 ? "今天":"周"+["日","一","二","三","四","五","六"][displayCalendar.component(.weekday,from:date)-1])
                    .font(.system(size:11)).foregroundStyle(palette.muted).frame(maxWidth:.infinity).frame(height:18)
            }}
            HStack(spacing:6) {ForEach(0..<7,id:\.self){offset in
                let date=displayCalendar.date(byAdding:.day,value:offset,to:displayCalendar.startOfDay(for:Date())) ?? Date()
                let selected=displayCalendar.isDate(date,inSameDayAs:day)
                let civilDay=CalendarCivilDay(date:date,calendar:displayCalendar,showsHolidays:calendar.holidaysEnabled)
                let eventCount=calendar.overviewEvents.filter{$0.occurs(on:date,calendar:displayCalendar)}.count
                let reminderCount=calendar.reminders.filter{!$0.isCompleted && ReminderQueries.occurs(reminder:$0,on:date,calendar:displayCalendar)}.count
                let dateKey=String(format:"%04d-%02d-%02d",displayCalendar.component(.year,from:date),displayCalendar.component(.month,from:date),displayCalendar.component(.day,from:date))
                WorkbenchCalendarDayButton(date:date,calendar:displayCalendar,selected:selected,showsHolidays:calendar.holidaysEnabled,
                    eventMarkers:Array(repeating:true,count:min(3,eventCount))+Array(repeating:false,count:min(3,reminderCount)),
                    label:"查看\(displayCalendar.component(.month,from:date))月\(displayCalendar.component(.day,from:date))日安排"+(civilDay.namedLabel.map{"，"+$0} ?? ""),
                    identifier:"fc.home.calendar.day."+dateKey) {selectedDay=date}
                    .frame(height:cellHeight)
            }}
        }.frame(maxWidth:stripWidth).frame(maxWidth:.infinity)
            .accessibilityElement(children:.contain).accessibilityIdentifier("fc.home.calendar.strip")
    }
    private func planColumn(title:String,subtitle:String,items:[CalendarAgendaEntry],empty:String)->some View {
        VStack(spacing:3) {
            HStack{Text(title);Spacer();Text(subtitle).foregroundStyle(palette.muted)}.font(.system(size:11)).foregroundStyle(palette.secondary).frame(height:16)
            ScrollView {
                if items.isEmpty {Text(empty).font(.system(size:11)).foregroundStyle(palette.muted).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,19)}
                else {VStack(spacing:0){ForEach(items){item in planRow(item);if item.id != items.last?.id {Rectangle().fill(palette.line).frame(height:1)}}}.background(WorkbenchOverlayScrollbars())}
            }.frame(height:expanded ? 160:112)
                .accessibilityElement(children:.contain).accessibilityIdentifier("fc.home.agenda."+(title == "日程" ? "events":"reminders"))
        }.frame(maxWidth:.infinity,alignment:.topLeading)
    }
    private func planRow(_ item:CalendarAgendaEntry)->some View {
        HStack(alignment:.top,spacing:8) {
            if case .reminder(let reminder)=item {
                Button{Task{await calendar.toggle(reminder)}}label:{ZStack{Circle().strokeBorder(reminder.isCompleted ? palette.accent:palette.muted.opacity(0.55),lineWidth:1);if reminder.isCompleted {Circle().fill(palette.accent);Image(systemName:"checkmark").font(.system(size:9,weight:.semibold)).foregroundStyle(palette.primaryText)}}.frame(width:16,height:16).padding(.top,1)}.buttonStyle(ClickablePlainButtonStyle()).disabled(calendar.isWorking || !reminder.isWritable).accessibilityLabel((reminder.isCompleted ? "恢复":"完成")+reminder.title)
            } else {Image(systemName:"calendar").font(.system(size:14)).foregroundStyle(palette.cool).frame(width:16,height:16).padding(.top,1)}
            VStack(alignment:.leading,spacing:3) {
                Button{switch item {case .reminder(let reminder):calendar.openReminder(reminder);case .event(let event):calendar.selectedEvent=event}}label:{Text(item.title).font(.system(size:12,weight:.regular)).foregroundStyle(item.isCompleted ? palette.muted:palette.text).strikethrough(item.isCompleted).multilineTextAlignment(.leading).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)}.buttonStyle(WBSelectableButtonStyle(cornerRadius: 6, drawsSelection: false, showsBorder: false))
                Text(itemDescription(item)).font(.system(size:11)).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)
            }
        }.padding(.vertical,9).frame(maxWidth:.infinity,minHeight:52,alignment:.topLeading)
    }
    private func itemDescription(_ item:CalendarAgendaEntry)->String {
        switch item {
        case .reminder(let value):return (value.due?.hasTime == true ? value.due?.date.map{context.time($0)} ?? "时间不可用":"未定时间")+" · "+value.sourceTitle
        case .event(let value):return (value.isAllDay ? "全天":context.time(value.start)+"–"+context.time(value.end))+" · "+value.calendarName+(value.end<Date() ? " · 已结束":"")
        }
    }
    private func pressureTitle(_ pressure:DevicePressure)->String {
        switch pressure {case .normal:"正常";case .warning:"偏高";case .critical:"很高";case .unknown:"未知"}
    }
}
