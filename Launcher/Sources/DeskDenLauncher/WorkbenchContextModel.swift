import AppKit
import Combine
import SwiftUI
import LauncherCore

enum WorkbenchContextTimeZoneMode: String, Codable { case city, system, custom }

struct WorkbenchContextPreferences: Codable, Equatable {
    var schema = 2
    var timeZoneIdentifier: String?
    var timeZoneMode: WorkbenchContextTimeZoneMode = .system
    var twelveHour = false
    var city: WeatherCity?
    var temperatureUnit: WeatherTemperatureUnit = .celsius
    init() {}
    private enum CodingKeys: String, CodingKey { case schema, timeZoneIdentifier, timeZoneMode, twelveHour, city, temperatureUnit }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(Int.self, forKey: .schema)
        timeZoneIdentifier = try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        twelveHour = try values.decode(Bool.self, forKey: .twelveHour)
        city = try values.decodeIfPresent(WeatherCity.self, forKey: .city)
        timeZoneMode = try values.decodeIfPresent(WorkbenchContextTimeZoneMode.self, forKey: .timeZoneMode) ?? (timeZoneIdentifier == nil ? .city : .custom)
        temperatureUnit = try values.decodeIfPresent(WeatherTemperatureUnit.self, forKey: .temperatureUnit) ?? .celsius
    }
    var zoneSelection: String {
        city == nil ? "system" : "city"
    }
    func validated() throws -> Self {
        guard (1...2).contains(schema) else { throw LauncherError.storage("城市与时间设置版本无法读取，原文件已保留。") }
        if let timeZoneIdentifier { _ = try WorkbenchDateContext(timeZoneIdentifier: timeZoneIdentifier) }
        guard timeZoneMode != .custom || timeZoneIdentifier != nil else { throw LauncherError.storage("自定义时区缺少有效设置。") }
        _ = try city?.validated()
        // Legacy overrides are validated before migrating. Reading never writes
        // the original file; an explicit save adopts the single-location model.
        var result = self; result.schema = 2
        result.timeZoneMode = city == nil ? .system : .city
        result.timeZoneIdentifier = nil
        return result
    }
}

/// One location controls the display date, clock and weather. With no selected
/// city the date and clock follow macOS; no weather location is inferred.
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
        (try? WorkbenchDateContext(timeZoneIdentifier:effectiveTimeZoneIdentifier)) ?? (try! WorkbenchDateContext(timeZoneIdentifier:"UTC"))
    }
    var effectiveTimeZoneIdentifier: String {
        settings.city?.timeZoneIdentifier ?? TimeZone.current.identifier
    }
    var temperatureUnit: WeatherTemperatureUnit { settings.temperatureUnit }
    func temperature(_ celsius: Double?) -> String { settings.temperatureUnit.formatted(celsius) }
    var weatherStatusTitle: String {
        if loadingWeather && weather?.snapshot == nil { return "正在读取天气" }
        if let snapshot = weather?.snapshot { return snapshot.conditionDescription }
        return settings.city == nil ? "选择城市查看天气" : "天气暂不可用"
    }
    var locationTitle: String { settings.city?.name ?? "系统时间" }
    var zoneTitle:String { locationTitle + " · " + Self.utcOffset(effectiveTimeZoneIdentifier) }
    static func utcOffset(_ id: String, at date: Date = Date()) -> String {
        guard let zone = TimeZone(identifier: id) else { return "时区不可用" }
        let offset = zone.secondsFromGMT(for: date)
        let hours = abs(offset) / 3600, minutes = abs(offset) % 3600 / 60
        return "UTC" + (offset >= 0 ? "+" : "−") + String(hours) + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }
    static func zoneTitle(_ id:String,at date:Date=Date()) -> String {
        guard let zone=TimeZone(identifier:id) else {return "时区不可用"}
        // The app currently presents Chinese copy. ICU's generic-location name
        // localizes every IANA zone, not only a short hand-written city list.
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"zh_CN")
        formatter.timeZone=zone;formatter.dateFormat="VVVV"
        let primary=["America/New_York":"纽约","Asia/Shanghai":"上海","Europe/London":"伦敦","Asia/Tokyo":"东京","UTC":"世界协调时"]
        let name=primary[id] ?? formatter.string(from:date)
        return name+" · "+utcOffset(id, at: date)
    }
    func time(_ date:Date,seconds:Bool=false) -> String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"zh_CN");formatter.timeZone=dateContext.timeZone
        formatter.dateFormat=settings.twelveHour ? (seconds ? "a h:mm:ss":"a h:mm"):(seconds ? "HH:mm:ss":"HH:mm")
        return formatter.string(from:date)
    }
    @discardableResult func saveClock(zone:String?,twelveHour:Bool) -> Bool {
        // Retain the old entry point for existing callers, without creating a
        // second display location. Invalid legacy inputs still fail safely.
        if let zone, TimeZone(identifier: zone) == nil {error="时间设置包含无效时区，尚未保存。";return false}
        var next=settings;next.twelveHour=twelveHour
        guard save(next) else {return false};showClock=false;return true
    }
    @discardableResult func saveCity(_ city:WeatherCity?) -> Bool {
        var next=settings;next.city=city
        guard save(next) else {return false}
        showWeather=false;refreshWeather();return true
    }
    @discardableResult func saveContext(city: WeatherCity?, zone: String, twelveHour: Bool, temperatureUnit: WeatherTemperatureUnit) -> Bool {
        guard zone == "city" || zone == "system" || TimeZone(identifier: zone) != nil else {error="时间设置包含无效时区，尚未保存。";return false}
        let cityChanged = settings.city != city
        var next = settings
        next.city = city; next.twelveHour = twelveHour; next.temperatureUnit = temperatureUnit
        next.timeZoneMode = city == nil ? .system : .city
        next.timeZoneIdentifier = nil
        guard save(next) else { return false }
        closeSettings()
        if cityChanged || weather == nil { refreshWeather() }
        return true
    }
    func closeSettings() { showClock = false; showWeather = false }
    private func save(_ next:WorkbenchContextPreferences) -> Bool {
        guard !protected else {error="已有日期与天气设置无法读取，请先检查原文件；当前没有覆盖它。";return false}
        do {
            let validated = try next.validated()
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try ProtectedAtomicFile.write(JSONEncoder().encode(validated),to:url)
            settings=validated;error=nil;return true
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

struct WorkbenchContextDialogs: View {
    @ObservedObject var model: WorkbenchContextModel
    @StateObject private var close = WorkbenchDraftCloseCoordinator()
    private var isPresented: Binding<Bool> {
        Binding(get: { model.showClock || model.showWeather }, set: { if !$0 { model.closeSettings() } })
    }
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .workbenchModal(isPresented: isPresented, onDismiss: close.continueEditing, onRequestDismiss: close.requestClose) {
                WorkbenchWeatherDialog(model: model, close: close)
            }
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
    var twelveHour: Bool
    private let savedTwelveHour: Bool
    init(settings: WorkbenchContextPreferences) {
        twelveHour = settings.twelveHour
        savedTwelveHour = twelveHour
    }
    var hasChanges: Bool { twelveHour != savedTwelveHour }
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

private struct WorkbenchClockDialog: View {
    @ObservedObject var model: WorkbenchContextModel
    @ObservedObject var close: WorkbenchDraftCloseCoordinator
    var initialDraft: WorkbenchClockDraft?
    var body: some View { WorkbenchWeatherDialog(model: model, close: close, initialClockDraft: initialDraft) }
}

struct WorkbenchLocationDraft {
    var city: WeatherCity?
    var zone: String { city == nil ? "system" : "city" }
    var twelveHour: Bool
    var temperatureUnit: WeatherTemperatureUnit
    private let saved: WorkbenchContextPreferences
    init(settings: WorkbenchContextPreferences) {
        city = settings.city; twelveHour = settings.twelveHour
        temperatureUnit = settings.temperatureUnit; saved = settings
    }
    var hasChanges: Bool {
        city != saved.city || twelveHour != saved.twelveHour || temperatureUnit != saved.temperatureUnit
    }
    var effectiveTimeZoneIdentifier: String {
        city?.timeZoneIdentifier ?? TimeZone.current.identifier
    }
    func time(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: effectiveTimeZoneIdentifier) ?? .current
        formatter.dateFormat = twelveHour ? "a h:mm" : "HH:mm"
        return formatter.string(from: date)
    }
}

/// A small attributed GeoNames city index makes the initial picker useful and
/// keeps common choices available while the optional online search is offline.
/// It supplies locations only; no weather observation is synthesized.
enum WorkbenchCityCatalog {
    private struct Entry:Sendable {let city:WeatherCity;let aliases:[String]}
    private static let entries:[Entry] = [
        entry(1816670,"北京","北京市",39.9075,116.39723,"Asia/Shanghai",["beijing","peking","北京市"]),
        entry(1796236,"上海","上海市",31.22222,121.45806,"Asia/Shanghai",["shanghai","上海市"]),
        entry(1809858,"广州","广东省",23.11667,113.25,"Asia/Shanghai",["guangzhou","canton","广州市"]),
        entry(1795565,"深圳","广东省",22.54554,114.0683,"Asia/Shanghai",["shenzhen","深圳市"]),
        entry(1815286,"成都","四川省",30.66667,104.06667,"Asia/Shanghai",["chengdu","成都市"]),
        entry(1808926,"杭州","浙江省",30.29365,120.16142,"Asia/Shanghai",["hangzhou","杭州市"]),
        entry(5128581,"纽约","纽约州",40.71427,-74.00597,"America/New_York",["new york","newyork","nyc"],country:"美国"),
        entry(2643743,"伦敦",nil,51.50853,-0.12574,"Europe/London",["london"],country:"英国"),
        entry(1850147,"东京","东京都",35.6895,139.69171,"Asia/Tokyo",["tokyo"],country:"日本"),
        entry(1880252,"新加坡",nil,1.28967,103.85007,"Asia/Singapore",["singapore"],country:"新加坡")
    ]
    private static func entry(_ id:Int,_ name:String,_ area:String?,_ latitude:Double,_ longitude:Double,_ zone:String,_ aliases:[String],country:String="中国") -> Entry {
        Entry(city:.init(id:"open-meteo:\(id)",name:name,administrativeArea:area,country:country,latitude:latitude,longitude:longitude,timeZoneIdentifier:zone),aliases:aliases)
    }
    static func matches(_ query:String) -> [WeatherCity] {
        let clean=query.trimmingCharacters(in:.whitespacesAndNewlines).folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"zh_CN")).replacingOccurrences(of:" ",with:"")
        guard !clean.isEmpty else {return entries.map(\.city)}
        return entries.filter {entry in ([entry.city.name]+entry.aliases).contains {value in
            value.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"zh_CN")).replacingOccurrences(of:" ",with:"").hasPrefix(clean)
        }}.map(\.city)
    }
    static func providerQuery(_ query:String) -> String {
        let clean=query.trimmingCharacters(in:.whitespacesAndNewlines)
        if clean.count > 2 && (clean.hasSuffix("市") || clean.hasSuffix("县")) {return String(clean.dropLast())}
        return clean
    }
}

struct WorkbenchWeatherDialog:View {
    @ObservedObject var model:WorkbenchContextModel
    @ObservedObject var close:WorkbenchDraftCloseCoordinator
    @State private var draft:WorkbenchLocationDraft
    @State private var query=""
    @State private var results:[WeatherCity]=WorkbenchCityCatalog.matches("")
    @State private var searching=false
    @State private var searched=false
    @State private var preview:WeatherPresentation?
    @State private var issue:String?
    @State private var searchTask:Task<Void,Never>?
    @State private var weatherTask:Task<Void,Never>?
    @State private var searchID=UUID()
    @Environment(\.workbenchPalette) private var palette
    init(model: WorkbenchContextModel, close: WorkbenchDraftCloseCoordinator, initialDraft: WorkbenchWeatherDraft? = nil, initialClockDraft: WorkbenchClockDraft? = nil) {
        self.model = model; self.close = close
        var draft = WorkbenchLocationDraft(settings: model.settings)
        if let initialDraft { draft.city = initialDraft.city }
        if let initialClockDraft { draft.twelveHour = initialClockDraft.twelveHour }
        _draft = State(initialValue: draft); _preview = State(initialValue: model.weather)
    }
    private var city:WeatherCity? {draft.city}
    private var cleanQuery:String {query.trimmingCharacters(in:.whitespacesAndNewlines)}
    var body:some View {
        WorkbenchDialogFrame(title:"城市、天气与时间",dismiss:requestDismiss) {
            VStack(alignment:.leading,spacing:14) {
                Text("选择一个城市，天气、日期与时间一起更新。").font(.system(size:12)).foregroundStyle(palette.secondary)
                Button {followSystem()} label: {
                    HStack(spacing:10) {
                        Image(systemName:"desktopcomputer").font(.system(size:19,weight:.light)).frame(width:28,height:28)
                        VStack(alignment:.leading,spacing:3) {
                            Text("跟随系统").font(.system(size:12,weight:.medium))
                            Text("日期与时间使用系统设置；添加城市后显示当地天气。").font(.system(size:10)).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)
                        }
                        Spacer(minLength:6)
                        Text(WorkbenchContextModel.utcOffset(TimeZone.current.identifier)).font(.system(size:11)).foregroundStyle(palette.secondary)
                        if city == nil {Image(systemName:"checkmark").foregroundStyle(palette.accent)}
                    }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                        .background(city == nil ? palette.navSelected : palette.soft,in:RoundedRectangle(cornerRadius:8))
                }.buttonStyle(WBSelectableButtonStyle(selected:city == nil,cornerRadius:8,drawsSelection:false,showsBorder:false))
                    .accessibilityIdentifier("context-follow-system")
                HStack(spacing:8) {
                    Image(systemName:"magnifyingglass").foregroundStyle(palette.muted)
                    TextField("搜索城市、拼音或英文名称",text:$query).textFieldStyle(.plain).onSubmit {search(immediate:true)}
                        .accessibilityIdentifier("context-city-search")
                    if searching {ProgressView().controlSize(.small).accessibilityLabel("正在搜索城市")}
                    else if !query.isEmpty {Button {query=""} label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(WBIconButtonStyle(size:24)).accessibilityLabel("清除城市搜索")}
                }.font(.system(size:12)).padding(.leading,10).padding(.trailing,4).frame(height:32)
                    .background(palette.soft,in:RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.line,lineWidth:1))
                VStack(alignment:.leading,spacing:7) {
                    HStack {Text(cleanQuery.isEmpty ? "常用城市":"搜索结果");Spacer();Text(searching ? "正在查找…":"选择后保存")}.font(.system(size:11)).foregroundStyle(palette.muted)
                    WorkbenchScrollView {
                        LazyVStack(spacing:2) {
                            ForEach(results) {item in
                                Button {select(item)} label:{
                                    HStack(spacing:10) {
                                        Image(systemName:"globe").font(.system(size:22,weight:.light)).foregroundStyle(palette.secondary).frame(width:28,height:28)
                                        VStack(alignment:.leading,spacing:3) {Text(item.name).font(.system(size:12));Text([item.administrativeArea,item.country].compactMap{$0}.joined(separator:" · ")).font(.system(size:10)).foregroundStyle(palette.muted)}
                                        Spacer(minLength:6)
                                        Text(WorkbenchContextModel.utcOffset(item.timeZoneIdentifier)).font(.system(size:11)).foregroundStyle(palette.secondary)
                                        if item.id == city?.id {Image(systemName:"checkmark").foregroundStyle(palette.accent)}
                                    }.padding(.horizontal,9).frame(maxWidth:.infinity,minHeight:42,alignment:.leading)
                                        .background(item.id == city?.id ? palette.navSelected:.clear,in:RoundedRectangle(cornerRadius:7))
                                }.buttonStyle(WBSelectableButtonStyle(selected:item.id == city?.id,cornerRadius:7,drawsSelection:false,showsBorder:false))
                                    .accessibilityLabel("选择城市 "+item.displayName+"，"+WorkbenchContextModel.utcOffset(item.timeZoneIdentifier))
                                    .accessibilityIdentifier("context-city-"+item.id)
                            }
                            if results.isEmpty {
                                Text(searching ? "正在搜索城市…":cleanQuery.count < 2 ? "继续输入城市名称，也可使用拼音或英文。":"未找到匹配城市，请尝试去掉“市”或使用拼音、英文名称。")
                                    .font(.system(size:11)).foregroundStyle(palette.muted).lineSpacing(4)
                                    .frame(maxWidth:.infinity,minHeight:100)
                            }
                        }.padding(.trailing,12)
                    }.frame(height:156).scrollBounceBehavior(.basedOnSize)
                        .accessibilityIdentifier("context-city-results")
                }
                if let issue {Text(issue).font(.system(size:11)).foregroundStyle(palette.warning).lineSpacing(4)}
                if let city {
                    HStack {Text(city.name+" · "+WorkbenchContextModel.utcOffset(city.timeZoneIdentifier)).font(.system(size:12,weight:.medium)).foregroundStyle(palette.secondary).lineLimit(1);Spacer();Button("刷新天气"){load(city,force:true)}.buttonStyle(WBButtonStyle(compact:true))}
                    weatherPreview
                }
                Rectangle().fill(palette.line).frame(height:1)
                timeAndUnits
                if let error=model.error {Text(error).font(.system(size:11)).foregroundStyle(palette.critical)}
                HStack {Text("天气仅按所选城市查询，不自动获取位置。");Spacer();Link("Open-Meteo · GeoNames",destination:URL(string:"https://open-meteo.com/")!)}.font(.system(size:10)).foregroundStyle(palette.muted)
            }
        } actions:{
            Spacer();Button("取消",action:requestDismiss).buttonStyle(WBButtonStyle())
            Button("保存"){model.saveContext(city:city,zone:draft.zone,twelveHour:draft.twelveHour,temperatureUnit:draft.temperatureUnit)}.buttonStyle(WBButtonStyle(primary:true))
        }
        .onChange(of:close.closeRequests){_,_ in requestDismiss()}
        .workbenchModal(isPresented:$close.confirmingDiscard,onRequestDismiss:close.continueEditing) {
            WorkbenchDiscardConfirmation(continueEditing:close.continueEditing,discard:{close.discardChanges{model.closeSettings()}})
        }
        .onDisappear{searchTask?.cancel();weatherTask?.cancel()}
        .onChange(of:query){_,_ in search(immediate:false)}
        .onAppear{if let city,preview?.snapshot?.city != city {load(city)}}
        .accessibilityIdentifier("context-weather-dialog")
    }
    private var timeAndUnits: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("温度单位").foregroundStyle(palette.secondary)
                Spacer()
                WBSelect("温度单位",selection:$draft.temperatureUnit,options:WeatherTemperatureUnit.allCases.map{($0,$0.title)}).frame(width:174)
                    .accessibilityIdentifier("context-temperature-unit")
            }
            HStack {
                Text("时间格式").foregroundStyle(palette.secondary)
                Spacer()
                WBSelect("时间格式",selection:$draft.twelveHour,options:[(false,"24 小时"),(true,"12 小时")]).frame(width:174)
            }
            HStack {
                Text(city?.name ?? "系统时间").foregroundStyle(palette.secondary)
                Spacer()
                Text(draft.time(Date())+" · "+WorkbenchContextModel.utcOffset(draft.effectiveTimeZoneIdentifier)).monospacedDigit()
            }.font(.system(size:11)).accessibilityIdentifier("context-location-time-preview")
            Text("首页、日历和 Mini 共用此城市。已有提醒的日期与通知时间保持不变。").font(.system(size:11)).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)
        }.font(.system(size:12))
    }
    @ViewBuilder private var weatherPreview:some View {
        if let snapshot=preview?.snapshot,snapshot.city == city {
            HStack(spacing:14) {
                Image(systemName:weatherSymbol(snapshot.weatherCode,isDay:snapshot.isDay)).font(.system(size:30,weight:.light)).foregroundStyle(palette.secondary)
                VStack(alignment:.leading,spacing:4) {Text(draft.temperatureUnit.formatted(snapshot.temperatureCelsius)).font(.system(size:27));Text(snapshot.conditionDescription).font(.system(size:11)).foregroundStyle(palette.secondary)}
                Spacer()
                VStack(alignment:.trailing,spacing:5) {
                    if let today=snapshot.dailyForecast?.first {Text("最高 "+draft.temperatureUnit.formatted(today.highCelsius)+" · 最低 "+draft.temperatureUnit.formatted(today.lowCelsius))}
                    Text((preview?.freshness == .stale ? "上次天气 · 已过期":"更新于 ")+draft.time(snapshot.receivedAt))
                }.font(.system(size:10)).foregroundStyle(palette.muted)
            }.padding(.vertical,8)
        } else {Text(preview?.issue ?? "正在读取天气…").font(.system(size:11)).foregroundStyle(palette.muted).padding(.vertical,8)}
    }
    private func search(immediate:Bool) {
        searchTask?.cancel();let id=UUID();searchID=id
        let text=cleanQuery;results=WorkbenchCityCatalog.matches(text);issue=nil;searched=false
        guard text.count >= 2 else {searching=false;return}
        guard text.count <= 100 else {searching=false;issue="城市名称最多输入 100 个字符。";return}
        searching=true
        searchTask=Task {
            do {
                if !immediate {try await Task.sleep(for:.milliseconds(400))}
                try Task.checkCancellation()
                let found:[WeatherCity]
                do {found=try await model.service.searchCities(query:WorkbenchCityCatalog.providerQuery(text))}
                catch WeatherServiceError.rateLimited {
                    // Input can change while the previous request is in flight.
                    // Keep the service's one-second limit, then retry only the
                    // still-current query instead of showing an empty result.
                    try await Task.sleep(for:.seconds(1))
                    try Task.checkCancellation()
                    found=try await model.service.searchCities(query:WorkbenchCityCatalog.providerQuery(text))
                }
                guard !Task.isCancelled,searchID == id else {return}
                var seen=Set<String>()
                results=(WorkbenchCityCatalog.matches(text)+found).filter {seen.insert($0.id).inserted}
            } catch is CancellationError {return}
            catch {
                guard !Task.isCancelled,searchID == id else {return}
                issue=results.isEmpty ? "在线城市搜索暂不可用，请稍后重试。" : "在线搜索暂不可用，仍可选择下列常用城市。"
            }
            guard !Task.isCancelled,searchID == id else {return};searching=false;searched=true
        }
    }
    private func requestDismiss() {close.resolveClose(hasChanges:draft.hasChanges){model.closeSettings()}}
    private func followSystem() {draft.city=nil;preview=nil;weatherTask?.cancel()}
    private func select(_ value:WeatherCity) {draft.city=value;load(value)}
    private func load(_ value:WeatherCity,force:Bool=false) {
        weatherTask?.cancel();preview=nil
        weatherTask=Task {let loaded=await model.service.load(city:value,forceRefresh:force);guard !Task.isCancelled,city == value else {return};preview=loaded}
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

func weatherTemperature(_ value:Double?,unit:WeatherTemperatureUnit = .celsius) -> String {unit.formatted(value)}
func weatherSymbol(_ code:Int?,isDay:Bool?=true) -> String {
    guard let code else {return "cloud"}
    switch code {case 0,1:return isDay == false ? "moon.stars":"sun.max";case 2:return isDay == false ? "cloud.moon":"cloud.sun";case 3:return "cloud";case 45,48:return "cloud.fog";case 51...67,80...82:return "cloud.rain";case 71...77,85,86:return "cloud.snow";case 95...99:return "cloud.bolt.rain";default:return "cloud"}
}
