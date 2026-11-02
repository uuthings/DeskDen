import SwiftUI
import LauncherCore

/// The approved home composition has its own proportions; other modules retain
/// their existing content layouts while sharing the new navigation shell.
struct WorkbenchOverview: View {
    @ObservedObject var device: DeviceStatusModel
    @ObservedObject var calendar: CalendarModel
    @ObservedObject var context: WorkbenchContextModel
    @ObservedObject var cleaning: SpaceCleaningModel
    var navigate: (WorkbenchRoute) -> Void
    var openDevice: (DeviceCardID) -> Void
    var reduceMotion = false
    @State private var selectedDay: Date?
    @Environment(\.workbenchPageWidth) private var availableWidth
    @Environment(\.workbenchContentHeight) private var availableHeight

    private var deviceWidth: CGFloat { min(320, 270 + max(0, availableWidth - 976) * 0.15) }
    private var calendarWidth: CGFloat { min(340, 296 + max(0, availableWidth - 976) * 0.12) }

    var body: some View {
        VStack(spacing: 0) {
            upperRow
            Spacer(minLength: 24)
            lowerRow
        }
        .frame(maxWidth: .infinity, minHeight: availableHeight, alignment: .topLeading)
        .onChange(of: context.dateContext) { _, _ in selectedDay = nil }
        .onAppear { cleaning.refreshDisk() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fc.page.home")
    }

    @ViewBuilder private var upperRow: some View {
        if availableWidth >= 840 {
            HStack(alignment: .top, spacing: 20) {
                deviceCard.frame(width: deviceWidth)
                WorkbenchHomeWelcome(context: context, reduceMotion: reduceMotion).frame(maxWidth: .infinity).frame(height: 311)
                monthCard.frame(width: calendarWidth)
            }.frame(minHeight: 311, alignment: .top)
        } else {
            VStack(spacing: 16) {
                WorkbenchHomeWelcome(context: context, reduceMotion: reduceMotion).frame(height: 210)
                if availableWidth >= 580 {
                    HStack(alignment: .top, spacing: 16) {
                        deviceCard.frame(maxWidth: 320)
                        Spacer(minLength: 0)
                        monthCard.frame(width: min(340, (availableWidth - 16) / 2))
                    }
                } else {
                    deviceCard
                    monthCard
                }
            }
        }
    }

    private var deviceCard: some View {
        WorkbenchHomeDeviceCard(model: device, navigate: navigate)
    }
    private var monthCard: some View {
        WorkbenchHomeCalendar(model: calendar, context: context, selectedDay: $selectedDay, navigate: navigate)
    }
    private var storageCard: some View {
        WorkbenchHomeStorageCard(model: device, cleaning: cleaning) { navigate(.cleaning) }
    }
    private var networkCard: some View {
        WorkbenchHomeNetworkCard(model: device, context: context) { navigate(.network) }
    }
    private var remindersCard: some View {
        WorkbenchHomeReminders(model: calendar, context: context, navigate: navigate)
    }

    @ViewBuilder private var lowerRow: some View {
        if availableWidth >= 760 {
            HStack(alignment: .top, spacing: 8) {
                storageCard.frame(maxWidth: .infinity)
                networkCard.frame(maxWidth: .infinity)
                remindersCard.frame(maxWidth: .infinity)
            }
        } else if availableWidth >= 540 {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    storageCard.frame(maxWidth: .infinity)
                    networkCard.frame(maxWidth: .infinity)
                }
                remindersCard
            }
        } else {
            VStack(spacing: 8) { storageCard; networkCard; remindersCard }
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
