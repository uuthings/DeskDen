import AppKit
import Combine
import SwiftUI
import LauncherCore

struct WorkbenchContextPreferences:Codable,Equatable {
    var schema=1
    var timeZoneIdentifier:String?
    var twelveHour=false
    var city:WeatherCity?
    func validated() throws -> Self {
        guard schema == 1 else {throw LauncherError.storage("日期与天气设置版本无法读取，原文件已保留。")}
        if let timeZoneIdentifier {_ = try WorkbenchDateContext(timeZoneIdentifier:timeZoneIdentifier)}
        _ = try city?.validated();return self
    }
}

/// Display timezone and manually chosen weather city are independent. No device
/// location, reminder due date, or notification timezone is changed here.
@MainActor final class WorkbenchContextModel:ObservableObject {
    @Published private(set) var settings=WorkbenchContextPreferences()
    @Published private(set) var weather:WeatherPresentation?
    @Published private(set) var loadingWeather=false
    @Published private(set) var error:String?
    @Published var showClock=false
    @Published var showWeather=false
    let service:WeatherService
    private let url:URL
    private var protected=false
    private var request:Task<Void,Never>?
    private var refreshLoop:Task<Void,Never>?
    private var visible=false
    private var generation=UUID()
    private var zoneObserver:NSObjectProtocol?
    init(dataDirectory:URL,provider:any WeatherProviding=OpenMeteoWeatherProvider(access:.nonCommercial)) {
        url=dataDirectory.appendingPathComponent("context.json")
        service=WeatherService(provider:provider,cache:WeatherJSONFileCache(fileURL:dataDirectory.appendingPathComponent("weather-cache.json")))
        if FileManager.default.fileExists(atPath:url.path) {
            do {
                let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
                let data=try handle.read(upToCount:65_537) ?? Data()
                guard data.count <= 65_536 else {throw LauncherError.storage("日期与天气设置超过读取上限。")}
                settings=try JSONDecoder().decode(WorkbenchContextPreferences.self,from:data).validated()
            } catch {protected=true;self.error="日期与天气设置无法读取，原文件已保留；未覆盖已有设置。"}
        }
        zoneObserver=NotificationCenter.default.addObserver(forName:.NSSystemTimeZoneDidChange,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {self?.objectWillChange.send()}
        }
    }
    var dateContext:WorkbenchDateContext {
        (try? WorkbenchDateContext(timeZoneIdentifier:settings.timeZoneIdentifier ?? TimeZone.current.identifier)) ?? (try! WorkbenchDateContext(timeZoneIdentifier:"UTC"))
    }
    var zoneTitle:String { Self.zoneTitle(dateContext.timeZoneIdentifier) }
    static func zoneTitle(_ id:String,at date:Date=Date()) -> String {
        let cities=["America/New_York":"纽约","Asia/Shanghai":"上海","Europe/London":"伦敦","Asia/Tokyo":"东京","UTC":"世界协调时"]
        let offset=TimeZone(identifier:id)?.secondsFromGMT(for:date) ?? 0
        let hours=abs(offset)/3600,minutes=abs(offset)%3600/60
        return (cities[id] ?? id.replacingOccurrences(of:"_",with:" "))+" · UTC"+(offset >= 0 ? "+":"−")+String(hours)+(minutes == 0 ? "":String(format:":%02d",minutes))
    }
    func time(_ date:Date,seconds:Bool=false) -> String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"zh_CN");formatter.timeZone=dateContext.timeZone
        formatter.dateFormat=settings.twelveHour ? (seconds ? "a h:mm:ss":"a h:mm"):(seconds ? "HH:mm:ss":"HH:mm")
        return formatter.string(from:date)
    }
    @discardableResult func saveClock(zone:String?,twelveHour:Bool) -> Bool {
        var next=settings;next.timeZoneIdentifier=zone;next.twelveHour=twelveHour
        guard save(next) else {return false};showClock=false;return true
    }
    @discardableResult func saveCity(_ city:WeatherCity?) -> Bool {
        var next=settings;next.city=city
        guard save(next) else {return false}
        showWeather=false;refreshWeather();return true
    }
    private func save(_ next:WorkbenchContextPreferences) -> Bool {
        guard !protected else {error="已有日期与天气设置无法读取，请先检查原文件；当前没有覆盖它。";return false}
        do {
            _ = try next.validated()
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try ProtectedAtomicFile.write(JSONEncoder().encode(next),to:url)
            settings=next;error=nil;return true
        } catch {self.error="设置未能保存：\(error.localizedDescription)";return false}
    }
    func refreshWeather(force:Bool=false) {
        request?.cancel();let id=UUID();generation=id;let city=settings.city;loadingWeather=city != nil
        if weather?.snapshot?.city != city {weather=nil}
        request=Task { [weak self,service] in
            let result=await service.load(city:city,forceRefresh:force)
            guard let self,!Task.isCancelled,self.generation == id else {return}
            self.weather=result;self.loadingWeather=false
        }
    }
    func setVisible(_ value:Bool) {
        guard value != visible else {return};visible=value;refreshLoop?.cancel();refreshLoop=nil
        if value {
            refreshWeather()
            refreshLoop=Task { [weak self] in
                while !Task.isCancelled {
                    do {try await Task.sleep(for:.seconds(1800))} catch {return}
                    guard let self,!Task.isCancelled else {return};self.refreshWeather()
                }
            }
        } else {request?.cancel();loadingWeather=false}
    }
    func stop() {refreshLoop?.cancel();request?.cancel();refreshLoop=nil;request=nil;visible=false;loadingWeather=false}
}

struct WorkbenchContextDialogs:View {
    @ObservedObject var model:WorkbenchContextModel
    @StateObject private var clockClose = WorkbenchDraftCloseCoordinator()
    @StateObject private var weatherClose = WorkbenchDraftCloseCoordinator()
    var body:some View {
        Color.clear.frame(width:0,height:0)
            .workbenchModal(isPresented:$model.showClock,onDismiss:clockClose.continueEditing,onRequestDismiss:clockClose.requestClose) {WorkbenchClockDialog(model:model,close:clockClose)}
            .workbenchModal(isPresented:$model.showWeather,onDismiss:weatherClose.continueEditing,onRequestDismiss:weatherClose.requestClose) {WorkbenchWeatherDialog(model:model,close:weatherClose)}
    }
}

/// Kept by the presenting view and observed by the cached modal content. A close
/// request must remain live after presentation, rather than capture an old Int.
@MainActor final class WorkbenchDraftCloseCoordinator: ObservableObject {
    @Published private(set) var closeRequests = 0
    @Published var confirmingDiscard = false
    func requestClose() { closeRequests &+= 1 }
    func resolveClose(hasChanges: Bool, dismiss: () -> Void) {
        if hasChanges { confirmingDiscard = true }
        else { confirmingDiscard = false; dismiss() }
    }
    func continueEditing() { confirmingDiscard = false }
    func discardChanges(dismiss: () -> Void) { confirmingDiscard = false; dismiss() }
}

struct WorkbenchClockDraft {
    var zone: String
    var twelveHour: Bool
    private let savedZone: String
    private let savedTwelveHour: Bool
    init(settings: WorkbenchContextPreferences) {
        zone = settings.timeZoneIdentifier ?? "system"; twelveHour = settings.twelveHour
        savedZone = zone; savedTwelveHour = twelveHour
    }
    var hasChanges: Bool { zone != savedZone || twelveHour != savedTwelveHour }
}

struct WorkbenchWeatherDraft {
    var city: WeatherCity?
    private let savedCity: WeatherCity?
    init(city: WeatherCity?) { self.city = city; savedCity = city }
    var hasChanges: Bool { city != savedCity }
}

struct WorkbenchDiscardConfirmation: View {
    var message = "你的更改尚未保存，放弃后将保留之前的设置。"
    let continueEditing: () -> Void
    let discard: () -> Void
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchDialogFrame(title: "放弃更改？", dismiss: continueEditing) {
            Text(message).font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(4)
        } actions: {
            Spacer()
            Button("继续编辑", action: continueEditing).buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
            Button("放弃更改", action: discard).buttonStyle(WBButtonStyle(destructive: true))
        }.accessibilityIdentifier("workbench-discard-confirmation")
    }
}

struct WorkbenchDialogFrame<Content:View,Actions:View>:View {
    let title:String
    let dismiss:()->Void
    @ViewBuilder let content:()->Content
    @ViewBuilder let actions:()->Actions
    @Environment(\.workbenchPalette) private var palette
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {Text(title).font(.system(size:15,weight:.medium));Spacer();Button(action:dismiss){Image(systemName:"xmark")}.buttonStyle(WBIconButtonStyle(size:32)).accessibilityLabel("关闭"+title)}.padding(EdgeInsets(top:18,leading:18,bottom:13,trailing:18))
            content().padding(.horizontal,18).padding(.bottom,18)
            Rectangle().fill(palette.line).frame(height:1)
            HStack(spacing:8){actions()}.padding(.horizontal,18).padding(.vertical,13)
        }.foregroundStyle(palette.text).accessibilityElement(children:.contain).accessibilityLabel(title)
    }
}

private struct WorkbenchClockDialog:View {
    @ObservedObject var model:WorkbenchContextModel
    @ObservedObject var close:WorkbenchDraftCloseCoordinator
    @State private var draft:WorkbenchClockDraft
    @Environment(\.workbenchPalette) private var palette
    init(model:WorkbenchContextModel,close:WorkbenchDraftCloseCoordinator,initialDraft:WorkbenchClockDraft?=nil) {
        self.model=model;self.close=close;_draft=State(initialValue:initialDraft ?? WorkbenchClockDraft(settings:model.settings))
    }
    var body:some View {
        WorkbenchDialogFrame(title:"日期与时区",dismiss:requestDismiss) {
            VStack(alignment:.leading,spacing:16) {
                VStack(alignment:.leading,spacing:7) {
                    Text("显示时区").foregroundStyle(palette.secondary)
                    WBSelect("显示时区",selection:$draft.zone,options:options)
                }
                HStack {Text("时间格式").foregroundStyle(palette.secondary);Spacer();WBSelect("时间格式",selection:$draft.twelveHour,options:[(false,"24 小时"),(true,"12 小时")]).frame(width:174)}
                Text("日期与世界时钟只在首页和日历显示，不占用设备状态页头。提醒的原始日期与通知时间保持各自的时区。").font(.system(size:11)).foregroundStyle(palette.muted).lineSpacing(4)
                if let error=model.error {Text(error).font(.system(size:11)).foregroundStyle(palette.critical)}
            }
        } actions:{Spacer();Button("取消",action:requestDismiss).buttonStyle(WBButtonStyle());Button("保存"){model.saveClock(zone:draft.zone == "system" ? nil:draft.zone,twelveHour:draft.twelveHour)}.buttonStyle(WBButtonStyle(primary:true))}
        .onChange(of:close.closeRequests){_,_ in requestDismiss()}
        .workbenchModal(isPresented:$close.confirmingDiscard,onRequestDismiss:close.continueEditing) {
            WorkbenchDiscardConfirmation(continueEditing:close.continueEditing,discard:{close.discardChanges{model.showClock=false}})
        }
        .accessibilityIdentifier("context-clock-dialog")
    }
    private func requestDismiss() {close.resolveClose(hasChanges:draft.hasChanges){model.showClock=false}}
    private var options:[(value:String,title:String)] {
        let primary=["America/New_York","Asia/Shanghai","Europe/London","Asia/Tokyo","UTC"]
        return [("system","跟随系统 · "+WorkbenchContextModel.zoneTitle(TimeZone.current.identifier))]+(primary+TimeZone.knownTimeZoneIdentifiers.filter{!primary.contains($0)}).map{($0,WorkbenchContextModel.zoneTitle($0))}
    }
}

private struct WorkbenchWeatherDialog:View {
    @ObservedObject var model:WorkbenchContextModel
    @ObservedObject var close:WorkbenchDraftCloseCoordinator
    @State private var draft:WorkbenchWeatherDraft
    @State private var query=""
    @State private var results:[WeatherCity]=[]
    @State private var searching=false
    @State private var searched=false
    @State private var preview:WeatherPresentation?
    @State private var issue:String?
    @State private var searchTask:Task<Void,Never>?
    @State private var weatherTask:Task<Void,Never>?
    @State private var searchID=UUID()
    @Environment(\.workbenchPalette) private var palette
    init(model:WorkbenchContextModel,close:WorkbenchDraftCloseCoordinator,initialDraft:WorkbenchWeatherDraft?=nil) {self.model=model;self.close=close;_draft=State(initialValue:initialDraft ?? WorkbenchWeatherDraft(city:model.settings.city));_preview=State(initialValue:model.weather)}
    private var city:WeatherCity? {draft.city}
    var body:some View {
        WorkbenchDialogFrame(title:"天气与城市",dismiss:requestDismiss) {
            VStack(alignment:.leading,spacing:16) {
                HStack(spacing:8) {
                    TextField("搜索城市名称",text:$query).textFieldStyle(.plain).padding(.horizontal,10).frame(height:32).background(palette.soft,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.line,lineWidth:1)).onSubmit(search)
                    Button(action:search){if searching {ProgressView().controlSize(.small)} else {Text("搜索")}}.buttonStyle(WBButtonStyle()).disabled(searching || query.trimmingCharacters(in:.whitespacesAndNewlines).count<2)
                }
                if !results.isEmpty {
                    ScrollView {VStack(spacing:3){ForEach(results){item in Button{select(item)}label:{HStack{Text(item.displayName).multilineTextAlignment(.leading);Spacer();if item == city {Image(systemName:"checkmark")}}.padding(8).frame(maxWidth:.infinity,alignment:.leading).background(item == city ? palette.navSelected:.clear,in:RoundedRectangle(cornerRadius:7))}.buttonStyle(.plain)}}.background(WorkbenchOverlayScrollbars())}.frame(maxHeight:120)
                } else if searched && !searching {Text("未找到城市，请尝试完整名称或英文名称。").font(.system(size:11)).foregroundStyle(palette.muted)}
                if let city {
                    HStack {Text(city.displayName).lineLimit(2);Spacer();Button("刷新"){load(city,force:true)}.buttonStyle(WBButtonStyle(compact:true))}
                    weatherPreview
                } else {unavailable("选择城市后查看天气")}
                if let issue {Text(issue).font(.system(size:11)).foregroundStyle(palette.warning)}
                if let error=model.error {Text(error).font(.system(size:11)).foregroundStyle(palette.critical)}
                VStack(alignment:.leading,spacing:5) {
                    Text("城市单独设置，不改变日历时区。").foregroundStyle(palette.muted)
                    Link("天气：Open-Meteo · 城市：GeoNames",destination:URL(string:"https://open-meteo.com/")!).foregroundStyle(palette.secondary)
                }.font(.system(size:11))
            }
        } actions:{
            if city != nil {Button("清除城市"){draft.city=nil;preview=nil;weatherTask?.cancel()}.buttonStyle(WBButtonStyle())}
            Spacer();Button("取消",action:requestDismiss).buttonStyle(WBButtonStyle());Button("保存"){model.saveCity(city)}.buttonStyle(WBButtonStyle(primary:true))
        }
        .onChange(of:close.closeRequests){_,_ in requestDismiss()}
        .workbenchModal(isPresented:$close.confirmingDiscard,onRequestDismiss:close.continueEditing) {
            WorkbenchDiscardConfirmation(continueEditing:close.continueEditing,discard:{close.discardChanges{model.showWeather=false}})
        }
        .onDisappear{searchTask?.cancel();weatherTask?.cancel()}
        .onChange(of:query){_,_ in searchID=UUID();searchTask?.cancel();searching=false;results=[];searched=false;issue=nil}
        .onAppear{if let city,preview?.snapshot?.city != city {load(city)}}
        .accessibilityIdentifier("context-weather-dialog")
    }
    @ViewBuilder private var weatherPreview:some View {
        if let snapshot=preview?.snapshot,snapshot.city == city {
            VStack(spacing:16) {
                HStack(spacing:18) {
                    Image(systemName:weatherSymbol(snapshot.weatherCode,isDay:snapshot.isDay)).font(.system(size:40,weight:.light)).foregroundStyle(palette.secondary)
                    VStack(alignment:.leading,spacing:4) {Text(weatherTemperature(snapshot.temperatureCelsius)).font(.system(size:34));Text(snapshot.conditionDescription).font(.system(size:12)).foregroundStyle(palette.secondary)}
                    Spacer()
                    if let today=snapshot.dailyForecast?.first {VStack(alignment:.trailing,spacing:5){Text("最高 "+weatherTemperature(today.highCelsius));Text("最低 "+weatherTemperature(today.lowCelsius))}.font(.system(size:11)).foregroundStyle(palette.secondary)}
                }.padding(.vertical,8)
                if let days=snapshot.dailyForecast,!days.isEmpty {
                    HStack {ForEach(Array(days.dropFirst().prefix(3))) {day in VStack(spacing:9){Text(String(day.dayKey.suffix(5))).font(.system(size:11));Image(systemName:weatherSymbol(day.weatherCode)).font(.system(size:20));Text(weatherTemperature(day.highCelsius)+" / "+weatherTemperature(day.lowCelsius)).font(.system(size:12))}.frame(maxWidth:.infinity)}}.foregroundStyle(palette.secondary)
                }
                Text((preview?.freshness == .stale ? "上次天气 · 已过期":"更新于 ")+snapshot.receivedAt.formatted(date:.omitted,time:.shortened)).font(.system(size:11)).foregroundStyle(palette.muted)
            }
        } else {unavailable(preview?.issue ?? "正在读取天气…")}
    }
    private func unavailable(_ text:String)->some View {VStack(spacing:14){Image(systemName:"cloud.slash").font(.system(size:36,weight:.light));Text(text);Text("日期、待办与其他模块照常显示。").font(.system(size:11))}.foregroundStyle(palette.secondary).frame(maxWidth:.infinity).padding(.vertical,22)}
    private func search() {
        searchTask?.cancel();let id=UUID();searchID=id;let text=query;searching=true;searched=true;issue=nil
        searchTask=Task {
            do {let found=try await model.service.searchCities(query:text);guard !Task.isCancelled,searchID == id else {return};results=found}
            catch {guard !Task.isCancelled,searchID == id else {return};issue=error.localizedDescription}
            guard !Task.isCancelled,searchID == id else {return};searching=false
        }
    }
    private func requestDismiss() {close.resolveClose(hasChanges:draft.hasChanges){model.showWeather=false}}
    private func select(_ value:WeatherCity) {draft.city=value;results=[];searched=false;load(value)}
    private func load(_ value:WeatherCity,force:Bool=false) {
        weatherTask?.cancel();preview=nil;issue=nil
        weatherTask=Task {let loaded=await model.service.load(city:value,forceRefresh:force);guard !Task.isCancelled,city == value else {return};preview=loaded;issue=loaded.issue ?? loaded.persistenceIssue}
    }
}

#if DEBUG
/// Mount the actual private dialog views with a known edited UI draft. Checks
/// exercise the real cached-modal close subscription, not a duplicate probe view.
@MainActor enum WorkbenchContextDialogViewsForChecks {
    static func clock(model:WorkbenchContextModel,close:WorkbenchDraftCloseCoordinator,draft:WorkbenchClockDraft) -> AnyView {
        AnyView(WorkbenchClockDialog(model:model,close:close,initialDraft:draft))
    }
    static func weather(model:WorkbenchContextModel,close:WorkbenchDraftCloseCoordinator,draft:WorkbenchWeatherDraft) -> AnyView {
        AnyView(WorkbenchWeatherDialog(model:model,close:close,initialDraft:draft))
    }
}
#endif

func weatherTemperature(_ value:Double?) -> String {value.map{String(format:"%.0f°",$0)} ?? "—"}
func weatherSymbol(_ code:Int?,isDay:Bool?=true) -> String {
    guard let code else {return "cloud.slash"}
    switch code {case 0,1:return isDay == false ? "moon.stars":"sun.max";case 2:return isDay == false ? "cloud.moon":"cloud.sun";case 3:return "cloud";case 45,48:return "cloud.fog";case 51...67,80...82:return "cloud.rain";case 71...77,85,86:return "cloud.snow";case 95...99:return "cloud.bolt.rain";default:return "cloud.slash"}
}
