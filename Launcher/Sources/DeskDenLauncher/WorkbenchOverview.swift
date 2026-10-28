import SwiftUI
import LauncherCore

struct WorkbenchOverview:View {
    @ObservedObject var device:DeviceStatusModel
    @ObservedObject var calendar:CalendarModel
    @ObservedObject var context:WorkbenchContextModel
    var navigate:(WorkbenchRoute)->Void
    var openDevice:(DeviceCardID)->Void
    @State private var selectedDay:Date?
    @State private var availableWidth:CGFloat=864
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchDeviceExpanded) private var expanded
    private var compact:Bool {availableWidth<800}
    private var stacksSummaryCards: Bool { availableWidth < 680 }
    private var summaryInnerWidth: CGFloat { max(0, availableWidth - 24) }
    private var statusSummaryWidth: CGFloat { summaryInnerWidth * 0.46 }
    private var thermalSummaryWidth: CGFloat { summaryInnerWidth * 0.30 }
    private var displayCalendar:Calendar {context.dateContext.calendar}
    private var day:Date {selectedDay ?? Date()}
    private var events:[CalendarEventItem] {calendar.overviewEvents.filter{$0.occurs(on:day,calendar:displayCalendar)}.sorted{$0.start<$1.start}}
    private var reminders:[ReminderItem] {calendar.reminders.filter{item in
        guard let due=item.due else {return false}
        return due.hasTime ? due.date.map{displayCalendar.isDate($0,inSameDayAs:day)} ?? false:due.isSameDay(as:day,calendar:displayCalendar)
    }.sorted{($0.due?.date ?? .distantFuture)<($1.due?.date ?? .distantFuture)}}
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            WBPageHeader(title:"首页",subtitle:"常用之物，皆在方寸之间")
            VStack(spacing:12) {
                if stacksSummaryCards {
                    VStack(spacing:12) {
                        statusCard
                        HStack(alignment:.top,spacing:12) {deviceCard;networkCard}
                    }.fixedSize(horizontal:false,vertical:true)
                } else {
                    HStack(alignment:.top,spacing:12) {
                        statusCard.frame(width:statusSummaryWidth)
                        deviceCard.frame(width:thermalSummaryWidth)
                        networkCard.frame(maxWidth:.infinity)
                    }.fixedSize(horizontal:false,vertical:true)
                }
                agenda
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
        .background(GeometryReader{geometry in Color.clear.onAppear{availableWidth=geometry.size.width}.onChange(of:geometry.size.width){_,value in availableWidth=value}})
        .onChange(of:context.dateContext){_,_ in selectedDay=nil}
        .accessibilityElement(children:.contain).accessibilityIdentifier("fc.page.home")
    }
    private var statusCard:some View {
        VStack(alignment:.leading,spacing:10) {storageUsage;memoryUsage}
            .padding(14).frame(maxWidth:.infinity,minHeight:208,alignment:.topLeading)
            .background(WorkbenchMaterialSurface(radius:15))
            .accessibilityElement(children:.contain).accessibilityIdentifier("home-device-summary")
    }
    private var storageUsage:some View {
        let disk=device.snapshot.disk
        return VStack(alignment:.leading,spacing:4) {
            HStack(spacing:8) {
                Label("磁盘空间",systemImage:"internaldrive").font(.system(size:12,weight:.medium))
                Spacer(minLength:4)
                Button("空间清理"){navigate(.cleaning)}.buttonStyle(WBButtonStyle(compact:true))
                    .accessibilityIdentifier("home-open-cleaning")
            }.frame(height:28)
            HStack(alignment:.firstTextBaseline,spacing:5) {
                Text(DeviceFormat.storage(disk?.used)).font(.system(size:17,weight:.medium))
                Text("已用").font(.system(size:11)).foregroundStyle(palette.secondary)
                Spacer(minLength:4)
                Text(disk.map{String(format:"已用 %.0f%%",$0.percent)} ?? "读数不可用")
                    .font(.system(size:11)).foregroundStyle(palette.secondary)
            }.monospacedDigit().frame(height:22)
            WBProgress(value:(disk?.percent ?? 0)/100,color:(disk?.percent ?? 0)>=80 ? palette.warning:palette.accent,height:6)
                .accessibilityElement(children:.ignore)
                .accessibilityLabel("磁盘已用比例，" + (disk.map{String(format:"%.0f%%",$0.percent)} ?? "读数不可用"))
                .accessibilityIdentifier("home-storage-progress")
            Text(disk.map{"总计 "+DeviceFormat.storage($0.total)+" · 可用 "+DeviceFormat.storage($0.available)} ?? "等待有效磁盘采样")
                .font(.system(size:11)).foregroundStyle(palette.muted).lineLimit(1)
        }.accessibilityElement(children:.contain).accessibilityIdentifier("home-storage-usage")
    }
    private var memoryUsage:some View {
        let memory=device.snapshot.memory
        return VStack(alignment:.leading,spacing:4) {
            HStack(spacing:8) {
                Label("运行内存",systemImage:"memorychip").font(.system(size:12,weight:.medium))
                Spacer(minLength:4)
                Button("查看读数"){openDevice(.memory)}.buttonStyle(WBButtonStyle(compact:true))
                    .accessibilityIdentifier("home-open-memory")
            }.frame(height:28)
            HStack(alignment:.firstTextBaseline,spacing:5) {
                Text(DeviceFormat.capacity(memory?.used)).font(.system(size:17,weight:.medium))
                Text("/ "+DeviceFormat.capacity(memory?.total)).font(.system(size:11)).foregroundStyle(palette.secondary)
                Spacer(minLength:4)
                Text(memory.map{String(format:"%.0f%%",$0.percent)} ?? "—")
                    .font(.system(size:12,weight:.medium)).foregroundStyle(palette.secondary)
            }.monospacedDigit().frame(height:22)
            WBProgress(value:(memory?.percent ?? 0)/100,color:DeviceAppearance.pressure(memory?.pressure,palette:palette),height:6)
                .accessibilityElement(children:.ignore)
                .accessibilityLabel("运行内存已用比例，" + (memory.map{String(format:"%.0f%%",$0.percent)} ?? "读数不可用"))
                .accessibilityIdentifier("home-memory-progress")
            Text(memoryPressureTitle(memory?.pressure ?? .unknown)).font(.system(size:11)).foregroundStyle(palette.muted).lineLimit(1)
        }.accessibilityElement(children:.contain).accessibilityIdentifier("home-memory-usage")
    }
    private func memoryPressureTitle(_ pressure:DevicePressure)->String {
        switch pressure {case .normal:"内存压力正常";case .warning:"内存压力偏高";case .critical:"内存压力很高";case .unknown:"等待有效内存压力采样"}
    }
    private var deviceCard:some View {
        let s=device.snapshot
        return WBActionCard(title: "散热与电池", symbol: "laptopcomputer", identifier: "home-device-detail", actionLabel: "查看设备散热与供电", contentIdentifier: "home-device-metrics", minimumHeight: 208) { openDevice(.thermal) } content: {
            Text(s.deviceName + " · " + s.chipName).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
            VStack(alignment: .leading, spacing: 10) {
                DeviceTemperatureReadings(snapshot: s, size: 23)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("home-temperature-readout")
                    .help(s.unavailableReasons["temperature"] ?? "查看温度与散热详情")
                DeviceFanRows(snapshot: s, paired: true)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("home-fan-readout")
                    .help(s.unavailableReasons["fan"] ?? "查看风扇与散热详情")
            }
            HStack(spacing: 8) {
                Label(s.battery.map { String(format: "%.0f%%", $0.percent) } ?? "—", systemImage: s.battery?.isPluggedIn == true ? "battery.100.bolt" : "battery.100")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .accessibilityIdentifier("home-battery-percent")
                Text(s.battery.map { $0.isCharging ? "正在充电" : $0.isPluggedIn ? "已连接电源" : "使用电池" } ?? "电源读数不可用")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer(minLength: 0)
                Text(DeviceFormat.thermal(s.thermalState)).font(.system(size: 11)).foregroundStyle(palette.muted)
            }.padding(.top, 2)
        }
    }
    private var networkCard: some View {
        let network = device.snapshot.network
        return WBActionCard(title: "实时网络", symbol: "network", identifier: "home-network-detail", actionLabel: "查看网络监控", minimumHeight: 208) { navigate(.network) } content: {
            VStack(alignment:.leading,spacing:10) {
                networkReading("下载",symbol:"arrow.down",value:network.downloadBytesPerSecond)
                networkReading("上传",symbol:"arrow.up",value:network.uploadBytesPerSecond)
            }.accessibilityElement(children:.combine).accessibilityIdentifier("home-network-speed")
            Text(todayTraffic).font(.system(size: 11)).foregroundStyle(palette.muted)
        }
    }
    private func networkReading(_ title: String, symbol: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(palette.secondary)
            Text(DeviceFormat.rate(value)).font(.system(size: 17, weight: .medium)).monospacedDigit().lineLimit(1)
        }
    }
    private var todayTraffic:String {let summary=device.trafficSummary(period:.day,scope:.all);return "今日已记录 "+(summary.coveredSeconds>0 ? DeviceTrafficDisplay.adaptive(summary.totalBytes):"—")}
    private var agenda:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:7) {
                Image(systemName:"note.text").font(.system(size:16,weight:.light)).foregroundStyle(palette.secondary)
                Text(displayCalendar.isDateInToday(day) ? "今天的安排":"\(displayCalendar.component(.month,from:day)) 月 \(displayCalendar.component(.day,from:day)) 日的安排").font(.system(size:12,weight:.medium))
                if !compact {Text("\(events.count) 项日程 · \(reminders.filter{!$0.isCompleted}.count) 项待办").font(.system(size:11)).foregroundStyle(palette.muted).padding(.leading,6)}
                Spacer(minLength:0)
                Button{calendar.selectDay(day);calendar.openNewReminder()}label:{Image(systemName:"plus")}.buttonStyle(WBButtonStyle(compact:true)).accessibilityLabel("新建提醒")
                Button{calendar.selectDay(day);navigate(.calendar)}label:{Label("打开日历",systemImage:"arrow.up.right")}.buttonStyle(WBButtonStyle(compact:true)).accessibilityIdentifier("home-open-calendar")
            }.frame(height:28).padding(.bottom,10)
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
            WorkbenchScrollView {
                if items.isEmpty {Text(empty).font(.system(size:11)).foregroundStyle(palette.muted).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,19)}
                else {VStack(spacing:0){ForEach(items){item in planRow(item);if item.id != items.last?.id {Rectangle().fill(palette.line).frame(height:1)}}}}
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

}

/// The actual homepage context area is also mountable in isolated appearance checks.
struct WorkbenchHomeContextHeader: View {
    @ObservedObject var context: WorkbenchContextModel
    var compact = false
    @Environment(\.workbenchPalette) private var palette
    private var displayCalendar: Calendar { context.dateContext.calendar }
    var body:some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:14) { weatherContextButton; clockContextButton }.fixedSize(horizontal:true,vertical:false)
            VStack(alignment:.trailing,spacing:8) { weatherContextButton; clockContextButton }
        }
    }
    private var weatherContextButton:some View {
        Button{context.showWeather=true}label:{
            HStack(spacing:10) {
                Image(systemName:context.settings.city == nil ? "cloud.sun":weatherSymbol(context.weather?.snapshot?.weatherCode,isDay:context.weather?.snapshot?.isDay))
                    .font(.system(size:context.settings.city == nil ? 23 : compact ? 28:30,weight:.light)).foregroundStyle(palette.secondary)
                VStack(alignment:.leading,spacing:4) {
                    HStack(alignment:.firstTextBaseline,spacing:8) {
                        if let temperature=context.weather?.snapshot?.temperatureCelsius {
                            Text(context.temperature(temperature))
                                .font(.system(size:compact ? 24:27,weight:.medium)).monospacedDigit()
                                .accessibilityIdentifier("home-weather-temperature")
                        }
                        Text(context.settings.city == nil ? "添加城市":context.weatherStatusTitle)
                            .font(.system(size:12,weight:.medium)).foregroundStyle(palette.secondary)
                            .lineLimit(1).accessibilityIdentifier("home-weather-condition")
                    }
                    HStack(spacing:4) {
                        Text((context.settings.city?.name ?? "设置天气与当地时间")+(context.weather?.freshness == .stale ? " · 天气已过期":""))
                        Image(systemName:"chevron.down").font(.system(size:9))
                    }.font(.system(size:11)).foregroundStyle(palette.muted)
                }
            }.frame(minHeight:52).contentShape(Rectangle())
        }.buttonStyle(ClickablePlainButtonStyle()).accessibilityLabel(context.settings.city == nil ? "添加城市，设置天气与当地时间":"城市、天气与时间，"+context.weatherStatusTitle+"，"+context.temperature(context.weather?.snapshot?.temperatureCelsius))
            .accessibilityIdentifier("home-weather-settings")
    }
    private var clockContextButton:some View {
        TimelineView(.periodic(from:.now,by:1)) {timeline in
            Button{context.showClock=true}label:{
                HStack(spacing:compact ? 8:14) {
                    Text(context.time(timeline.date,seconds:true)).font(.system(size:compact ? 24:28,weight:.regular)).monospacedDigit()
                    VStack(alignment:.leading,spacing:3) {
                        if let date=try? context.dateContext.display(at:timeline.date) {
                            Text("\(displayCalendar.component(.month,from:timeline.date)) 月 \(displayCalendar.component(.day,from:timeline.date)) 日  "+date.weekdayText).font(.system(size:compact ? 11:12)).foregroundStyle(palette.secondary)
                        }
                        HStack(spacing:4){Text(context.locationTitle+" · "+WorkbenchContextModel.utcOffset(context.effectiveTimeZoneIdentifier,at:timeline.date));Image(systemName:"chevron.down").font(.system(size:9))}.font(.system(size:11)).foregroundStyle(palette.muted)
                    }
                }.padding(.leading,10).frame(minHeight:46).contentShape(Rectangle())
            }.buttonStyle(ClickablePlainButtonStyle()).accessibilityLabel("城市、天气与时间")
        }
    }
}


/// The selected city's date, clock and weather remain visible on every route.
struct WorkbenchTopBarContext:View {
    @ObservedObject var context:WorkbenchContextModel
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        TimelineView(.periodic(from:Date(timeIntervalSince1970:(Date().timeIntervalSince1970/60).rounded(.down)*60),by:60)) { timeline in
            HStack(spacing:0) {
                Button{context.showWeather=true} label:{
                    ViewThatFits(in:.horizontal) {
                        content(at:timeline.date,compact:false)
                        content(at:timeline.date,compact:true)
                    }.contentShape(Rectangle())
                }.buttonStyle(ClickablePlainButtonStyle())
                    .accessibilityHint("设置城市、天气与时间")
                    .accessibilityIdentifier("home-weather-settings")
                    .help(context.zoneTitle+" · "+context.weatherStatusTitle)
            }.accessibilityElement(children:.contain).accessibilityIdentifier("top-context-display")
        }
    }
    private func content(at date:Date,compact:Bool)->some View {
        HStack(spacing:compact ? 8:12) {
            Text(dateTitle(date,compact:compact)).foregroundStyle(palette.secondary)
            Text(context.time(date)).monospacedDigit().foregroundStyle(palette.text)
            Rectangle().fill(palette.line).frame(width:1,height:12)
            HStack(spacing:6) {
                Image(systemName:context.settings.city == nil ? "cloud.sun":weatherSymbol(context.weather?.snapshot?.weatherCode,isDay:context.weather?.snapshot?.isDay))
                    .font(.system(size:13,weight:.regular))
                Text(weatherTitle).lineLimit(1).truncationMode(.tail).fixedSize(horizontal:true,vertical:false)
                if context.weather?.freshness == .stale {Text("旧").font(.system(size:9)).foregroundStyle(palette.warning)}
            }.foregroundStyle(palette.secondary)
            Image(systemName:"chevron.down").font(.system(size:8)).foregroundStyle(palette.muted)
        }.font(.system(size:11)).frame(height:32)
            .accessibilityElement(children:.combine)
    }
    private func dateTitle(_ date:Date,compact:Bool)->String {
        let calendar=context.dateContext.calendar
        let month=calendar.component(.month,from:date),day=calendar.component(.day,from:date)
        if compact {return "\(month)/\(day)"}
        let weekday=(try? context.dateContext.display(at:date).weekdayText) ?? ""
        return "\(month)月\(day)日 "+weekday
    }
    private var weatherTitle:String {
        guard let city=context.settings.city else {return "添加城市"}
        if let temperature=context.weather?.snapshot?.temperatureCelsius {return city.name+" "+context.temperature(temperature)}
        return city.name+(context.loadingWeather ? " · 更新中":" · 天气待更新")
    }
}
