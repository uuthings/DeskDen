import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Weather sources and caches retain Celsius; this preference changes display only.
public enum WeatherTemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius, fahrenheit
    public var symbol: String { self == .celsius ? "°C" : "°F" }
    public var title: String { self == .celsius ? "摄氏度 · °C" : "华氏度 · °F" }
    public func value(fromCelsius value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        let converted = self == .celsius ? value : value * 9 / 5 + 32
        return converted.isFinite ? converted : nil
    }
    public func formatted(_ celsius: Double?) -> String {
        guard let value = value(fromCelsius: celsius) else { return "—" }
        // Avoid a negative zero for temperatures just below freezing.
        let rounded = value.rounded()
        return String(format: "%.0f", rounded == 0 ? 0 : rounded) + symbol
    }
}

public struct WeatherCity: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var administrativeArea: String?
    public var country: String?
    public var latitude: Double
    public var longitude: Double
    public var timeZoneIdentifier: String
    public init(id: String, name: String, administrativeArea: String? = nil, country: String? = nil,
                latitude: Double, longitude: Double, timeZoneIdentifier: String) {
        self.id = id; self.name = name; self.administrativeArea = administrativeArea; self.country = country
        self.latitude = latitude; self.longitude = longitude; self.timeZoneIdentifier = timeZoneIdentifier
    }
    public func validated() throws -> Self {
        guard !id.isEmpty, id.count <= 200, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
              latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
              TimeZone(identifier: timeZoneIdentifier) != nil else { throw WeatherServiceError.invalidCity }
        return self
    }
    public var displayName: String { [name, administrativeArea, country].compactMap { $0 }.filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · ") }
}

public struct WeatherDayForecast: Codable, Equatable, Identifiable, Sendable {
    public var id:String {dayKey}
    public var dayKey:String
    public var weatherCode:Int?
    public var highCelsius:Double?
    public var lowCelsius:Double?
    public init(dayKey:String,weatherCode:Int?,highCelsius:Double?,lowCelsius:Double?) {
        self.dayKey=dayKey;self.weatherCode=weatherCode;self.highCelsius=highCelsius;self.lowCelsius=lowCelsius
    }
    public func validated() throws -> Self {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(secondsFromGMT:0);formatter.dateFormat="yyyy-MM-dd";formatter.isLenient=false
        guard dayKey.count == 10,let date=formatter.date(from:dayKey),formatter.string(from:date) == dayKey,
              highCelsius.map({$0.isFinite && (-100...70).contains($0)}) ?? true,
              lowCelsius.map({$0.isFinite && (-100...70).contains($0)}) ?? true,
              highCelsius == nil || lowCelsius == nil || highCelsius! >= lowCelsius! else {throw WeatherServiceError.invalidResponse}
        return self
    }
}
public struct WeatherSnapshot: Codable, Equatable, Sendable {
    public var city: WeatherCity
    public var observedAt: Date
    public var receivedAt: Date
    public var temperatureCelsius: Double?
    public var apparentTemperatureCelsius: Double?
    public var relativeHumidityPercent: Double?
    public var windSpeedKilometresPerHour: Double?
    public var weatherCode: Int?
    public var isDay: Bool?
    public var providerID: String
    public var attribution: String
    public var attributionURL: URL
    public var dailyForecast:[WeatherDayForecast]?
    public init(city: WeatherCity, observedAt: Date, receivedAt: Date, temperatureCelsius: Double?,
                apparentTemperatureCelsius: Double? = nil, relativeHumidityPercent: Double? = nil,
                windSpeedKilometresPerHour: Double? = nil, weatherCode: Int? = nil, isDay: Bool? = nil,
                providerID: String, attribution: String, attributionURL: URL,dailyForecast:[WeatherDayForecast]?=nil) {
        self.city = city; self.observedAt = observedAt; self.receivedAt = receivedAt; self.temperatureCelsius = temperatureCelsius
        self.apparentTemperatureCelsius = apparentTemperatureCelsius; self.relativeHumidityPercent = relativeHumidityPercent
        self.windSpeedKilometresPerHour = windSpeedKilometresPerHour; self.weatherCode = weatherCode; self.isDay = isDay
        self.providerID = providerID; self.attribution = attribution; self.attributionURL = attributionURL
        self.dailyForecast=dailyForecast
    }
    public func validated() throws -> Self {
        _ = try city.validated()
        if let dailyForecast {
            guard dailyForecast.count <= 16,Set(dailyForecast.map(\.dayKey)).count == dailyForecast.count else {throw WeatherServiceError.invalidResponse}
            for day in dailyForecast {_ = try day.validated()}
        }
        guard observedAt.timeIntervalSince1970.isFinite, receivedAt.timeIntervalSince1970.isFinite,
              abs(observedAt.timeIntervalSince1970) < 100_000_000_000, abs(receivedAt.timeIntervalSince1970) < 100_000_000_000,
              observedAt <= receivedAt.addingTimeInterval(3600), temperatureCelsius != nil || weatherCode != nil,
              valid(temperatureCelsius, range: -100...70), valid(apparentTemperatureCelsius, range: -150...100),
              valid(relativeHumidityPercent, range: 0...100), valid(windSpeedKilometresPerHour, range: 0...600),
              !providerID.isEmpty, attributionURL.scheme == "https", !attribution.isEmpty else { throw WeatherServiceError.invalidResponse }
        return self
    }
    private func valid(_ value: Double?, range: ClosedRange<Double>) -> Bool { value.map { $0.isFinite && range.contains($0) } ?? true }
    public var conditionDescription: String {
        switch weatherCode {
        case 0: "晴"
        case 1: "大部晴朗"
        case 2: "局部多云"
        case 3: "阴"
        case 45, 48: "雾"
        case 51, 53, 55: "毛毛雨"
        case 56, 57: "冻毛毛雨"
        case 61, 63, 65: "雨"
        case 66, 67: "冻雨"
        case 71, 73, 75, 77: "雪"
        case 80, 81, 82: "阵雨"
        case 85, 86: "阵雪"
        case 95, 97: "雷暴"
        case 96, 99: "雷暴伴冰雹"
        default: "天气状况未知"
        }
    }
}

public enum WeatherServiceError: LocalizedError, Equatable, Sendable {
    case invalidCity, invalidQuery, invalidResponse, tooLarge, httpStatus(Int), rateLimited, providerNotConfigured
    public var errorDescription: String? {
        switch self {
        case .invalidCity: "城市信息无效，请重新选择。"
        case .invalidQuery: "请输入 2 至 100 个字符搜索城市。"
        case .invalidResponse: "天气来源未提供有效数据。"
        case .tooLarge: "天气响应超出读取上限。"
        case .httpStatus(let code): "天气服务暂不可用（\(code)）。"
        case .rateLimited: "请求过于频繁，请稍后重试。"
        case .providerNotConfigured: "尚未配置天气来源。"
        }
    }
}

public protocol WeatherProviding: Sendable {
    var providerID: String { get }
    func searchCities(query: String, language: String) async throws -> [WeatherCity]
    func currentWeather(for city: WeatherCity, receivedAt: Date) async throws -> WeatherSnapshot
}
public struct WeatherHTTPResponse: Sendable {
    public var statusCode: Int
    public var data: Data
    public init(statusCode: Int, data: Data) { self.statusCode = statusCode; self.data = data }
}
public protocol WeatherHTTPTransport: Sendable { func response(for request: URLRequest) async throws -> WeatherHTTPResponse }

public final class WeatherURLSessionTransport: WeatherHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        config.httpMaximumConnectionsPerHost = 2; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }
    public func response(for request: URLRequest) async throws -> WeatherHTTPResponse {
        #if canImport(Darwin)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw WeatherServiceError.invalidResponse }
        guard response.expectedContentLength <= 1_048_576 else { throw WeatherServiceError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw WeatherServiceError.tooLarge }
            data.append(byte)
        }
        return .init(statusCode: http.statusCode, data: data)
        #else
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WeatherServiceError.invalidResponse }
        guard data.count <= 1_048_576 else { throw WeatherServiceError.tooLarge }
        return .init(statusCode: http.statusCode, data: data)
        #endif
    }
}

/// Free endpoints are for non-commercial use only. A commercial app must use a licensed provider.
/// This access choice is explicit; it never signs up, purchases a plan or reads an account secret.
public enum OpenMeteoAccess: Sendable { case nonCommercial, customer(apiKey: String) }
public struct OpenMeteoWeatherProvider: WeatherProviding, Sendable {
    public let providerID = "open-meteo"
    public static let weatherAttribution = "天气：Open-Meteo · CC BY 4.0"
    public static let cityAttribution = "城市数据：GeoNames，经 Open-Meteo 提供"
    public static let termsURL = URL(string: "https://open-meteo.com/en/terms")!
    private let access: OpenMeteoAccess
    private let transport: any WeatherHTTPTransport
    public init(access: OpenMeteoAccess, transport: any WeatherHTTPTransport = WeatherURLSessionTransport()) {
        self.access = access; self.transport = transport
    }
    public func searchCities(query: String, language: String = "zh") async throws -> [WeatherCity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...100).contains(trimmed.count), language.count <= 10 else { throw WeatherServiceError.invalidQuery }
        let url = try requestURL(geocoding: true, parameters: [.init(name: "name", value: trimmed), .init(name: "count", value: "10"),
                                                              .init(name: "language", value: language.lowercased()), .init(name: "format", value: "json")])
        let data = try await fetch(url)
        let result = try JSONDecoder().decode(GeocodingResponse.self, from: data)
        if result.error == true { throw WeatherServiceError.invalidResponse }
        return (result.results ?? []).prefix(10).compactMap { value in
            guard let timezone = value.timezone else { return nil }
            let city = WeatherCity(id: "open-meteo:\(value.id)", name: value.name, administrativeArea: value.admin1, country: value.country,
                                   latitude: value.latitude, longitude: value.longitude, timeZoneIdentifier: timezone)
            return try? city.validated()
        }
    }
    public func currentWeather(for city: WeatherCity, receivedAt: Date = Date()) async throws -> WeatherSnapshot {
        _ = try city.validated()
        let url = try requestURL(geocoding: false, parameters: [.init(name: "latitude", value: String(city.latitude)), .init(name: "longitude", value: String(city.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m"),
            .init(name: "temperature_unit", value: "celsius"), .init(name: "wind_speed_unit", value: "kmh"),
            .init(name: "daily",value:"weather_code,temperature_2m_max,temperature_2m_min"),
            .init(name: "timeformat", value: "unixtime"), .init(name: "timezone", value: city.timeZoneIdentifier), .init(name: "forecast_days", value: "4")])
        let data = try await fetch(url)
        let response = try JSONDecoder().decode(ForecastResponse.self, from: data)
        guard response.error != true, let current = response.current, let observed = current.time, observed.isFinite,
              response.current_units?.temperature_2m == nil || response.current_units?.temperature_2m == "°C",
              response.current_units?.wind_speed_10m == nil || response.current_units?.wind_speed_10m == "km/h" else { throw WeatherServiceError.invalidResponse }
        var forecast:[WeatherDayForecast]?
        if let daily=response.daily {
            guard let dates=daily.time, dates.count <= 16,
                  daily.weather_code.map({$0.count == dates.count}) ?? true,
                  daily.temperature_2m_max.map({$0.count == dates.count}) ?? true,
                  daily.temperature_2m_min.map({$0.count == dates.count}) ?? true,
                  response.daily_units?.temperature_2m_max == nil || response.daily_units?.temperature_2m_max == "°C",
                  response.daily_units?.temperature_2m_min == nil || response.daily_units?.temperature_2m_min == "°C" else {throw WeatherServiceError.invalidResponse}
            let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(identifier:city.timeZoneIdentifier);formatter.dateFormat="yyyy-MM-dd"
            forecast=try dates.enumerated().map {index,instant in
                guard instant.isFinite,abs(instant)<100_000_000_000 else {throw WeatherServiceError.invalidResponse}
                return try WeatherDayForecast(dayKey:formatter.string(from:Date(timeIntervalSince1970:instant)),weatherCode:daily.weather_code?[index],highCelsius:daily.temperature_2m_max?[index],lowCelsius:daily.temperature_2m_min?[index]).validated()
            }
        }
        let snapshot = WeatherSnapshot(city: city, observedAt: Date(timeIntervalSince1970: observed), receivedAt: receivedAt,
                                       temperatureCelsius: current.temperature_2m, apparentTemperatureCelsius: current.apparent_temperature,
                                       relativeHumidityPercent: current.relative_humidity_2m, windSpeedKilometresPerHour: current.wind_speed_10m,
                                       weatherCode: current.weather_code, isDay: current.is_day.flatMap { $0 == 1 ? true : $0 == 0 ? false : nil }, providerID: providerID,
                                       attribution: Self.weatherAttribution, attributionURL: URL(string: "https://open-meteo.com/")!,dailyForecast:forecast)
        return try snapshot.validated()
    }
    private func requestURL(geocoding: Bool, parameters: [URLQueryItem]) throws -> URL {
        let base: String
        var items = parameters
        switch access {
        case .nonCommercial: base = geocoding ? "https://geocoding-api.open-meteo.com/v1/search" : "https://api.open-meteo.com/v1/forecast"
        case .customer(let key):
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WeatherServiceError.providerNotConfigured }
            base = geocoding ? "https://customer-geocoding-api.open-meteo.com/v1/search" : "https://customer-api.open-meteo.com/v1/forecast"
            items.append(.init(name: "apikey", value: key))
        }
        var components = URLComponents(string: base)!; components.queryItems = items
        guard let url = components.url else { throw WeatherServiceError.invalidResponse }; return url
    }
    private func fetch(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url); request.timeoutInterval = 10; request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.response(for: request)
        guard response.data.count <= 1_048_576 else { throw WeatherServiceError.tooLarge }
        if response.statusCode == 429 { throw WeatherServiceError.rateLimited }
        guard (200...299).contains(response.statusCode) else { throw WeatherServiceError.httpStatus(response.statusCode) }
        try Task.checkCancellation()
        return response.data
    }
    private struct GeocodingResponse: Decodable {
        var error: Bool?
        var results: [City]?
        struct City: Decodable { var id: Int; var name: String; var latitude: Double; var longitude: Double; var timezone: String?; var admin1: String?; var country: String? }
    }
    private struct ForecastResponse: Decodable {
        var error: Bool?
        var current: Current?
        var current_units: Units?
        var daily:Daily?
        var daily_units:DailyUnits?
        struct Current: Decodable { var time: Double?; var temperature_2m: Double?; var apparent_temperature: Double?; var relative_humidity_2m: Double?; var wind_speed_10m: Double?; var weather_code: Int?; var is_day: Int? }
        struct Units: Decodable { var temperature_2m: String?; var wind_speed_10m: String? }
        struct Daily:Decodable {var time:[Double]?;var weather_code:[Int?]?;var temperature_2m_max:[Double?]?;var temperature_2m_min:[Double?]?}
        struct DailyUnits:Decodable {var temperature_2m_max:String?;var temperature_2m_min:String?}
    }
}

/// Persistent implementations must replace atomically and preserve the previous data on failure.
public protocol WeatherCachePersisting: Sendable {
    func load() async throws -> [WeatherSnapshot]
    func save(_ snapshots: [WeatherSnapshot]) async throws
}
public actor WeatherMemoryCache: WeatherCachePersisting {
    private var entries: [WeatherSnapshot] = []
    public init() {}
    public func load() -> [WeatherSnapshot] { entries }
    public func save(_ snapshots: [WeatherSnapshot]) { entries = snapshots }
}
public actor WeatherJSONFileCache: WeatherCachePersisting {
    private let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func load() throws -> [WeatherSnapshot] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: fileURL); defer { try? handle.close() }
        let data = try handle.read(upToCount: 524_289) ?? Data()
        guard data.count <= 524_288 else { throw WeatherServiceError.tooLarge }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.schema == 1, payload.snapshots.count <= 20 else { throw WeatherServiceError.invalidResponse }
        return try payload.snapshots.map { try $0.validated() }
    }
    public func save(_ snapshots: [WeatherSnapshot]) throws {
        guard fileURL.isFileURL, snapshots.count <= 20 else { throw WeatherServiceError.invalidResponse }
        let checked = try snapshots.map { try $0.validated() }
        let data = try JSONEncoder().encode(Payload(schema: 1, snapshots: checked))
        guard data.count <= 524_288 else { throw WeatherServiceError.tooLarge }
        // Previewing the first city may precede saving context preferences, so
        // the cache must also create its own private parent directory.
        try ProtectedAtomicFile.write(data, to: fileURL)
    }
    private struct Payload: Codable { var schema: Int; var snapshots: [WeatherSnapshot] }
}

public enum WeatherFreshness: String, Codable, Equatable, Sendable { case current, cached, stale, unavailable, noCity, cancelled }
public struct WeatherPresentation: Equatable, Sendable {
    public var freshness: WeatherFreshness
    public var snapshot: WeatherSnapshot?
    public var issue: String?
    public var persistenceIssue: String?
    public var isCurrent: Bool { freshness == .current || freshness == .cached }
}

/// The chosen city is independent of the workbench display timezone. No location permission is used.
public actor WeatherService {
    private struct RequestKey: Hashable, Sendable { var providerID: String; var city: WeatherCity }
    private struct Completion: Sendable { var snapshot: WeatherSnapshot?; var issue: String?; var persistenceIssue: String?; var cancelled = false }
    private struct Flight: Sendable { var token: UUID; var task: Task<Completion, Never> }
    private let provider: any WeatherProviding
    private let cache: any WeatherCachePersisting
    private var entries: [RequestKey: WeatherSnapshot] = [:]
    private var loaded = false
    private var cacheLoading: Task<[WeatherSnapshot], Error>?
    private var cacheLoadIssue: String?
    private var cacheWriting: Task<Void, Error>?
    private var cacheWriteToken: UUID?
    private var lastAttempts: [RequestKey: Date] = [:]
    private var inFlight: [RequestKey: Flight] = [:]
    private var lastSearch: Date?
    public init(provider: any WeatherProviding, cache: any WeatherCachePersisting = WeatherMemoryCache()) {
        self.provider = provider; self.cache = cache
    }
    public func searchCities(query: String, language: String = "zh", at now: Date = Date()) async throws -> [WeatherCity] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...100).contains(clean.count) else { throw WeatherServiceError.invalidQuery }
        if let lastSearch, now.timeIntervalSince(lastSearch) < 1 { throw WeatherServiceError.rateLimited }
        lastSearch = now
        return try await provider.searchCities(query: clean, language: language)
    }
    public func load(city: WeatherCity?, forceRefresh: Bool = false, at now: Date = Date()) async -> WeatherPresentation {
        guard let city else { return .init(freshness: .noCity, snapshot: nil, issue: "选择城市后查看天气。", persistenceIssue: nil) }
        do { _ = try city.validated() } catch { return .init(freshness: .unavailable, snapshot: nil, issue: error.localizedDescription, persistenceIssue: nil) }
        let key = RequestKey(providerID: provider.providerID, city: city)
        if Task.isCancelled { return cancelled(entries[key], issue: nil) }
        let cacheIssue = await ensureCacheLoaded()
        let previous = entries[key]
        if Task.isCancelled { return cancelled(previous, issue: cacheIssue) }
        // Joining the same actual request never consumes another request slot or the refresh throttle.
        if let flight = inFlight[key] { return await presentation(for: flight, previous: previous, at: now, cacheIssue: cacheIssue) }
        if !forceRefresh, let previous, fresh(previous, at: now, maximumAge: 1800) {
            return .init(freshness: .cached, snapshot: previous, issue: nil, persistenceIssue: cacheIssue)
        }
        if let attempt = lastAttempts[key], now.timeIntervalSince(attempt) < 60 {
            return fallback(previous, at: now, issue: WeatherServiceError.rateLimited.localizedDescription, persistenceIssue: cacheIssue)
        }
        let token = UUID(), provider = self.provider
        lastAttempts[key] = now
        let shared = Task<Completion, Never> { [weak self] in
            do {
                let snapshot = try await provider.currentWeather(for: city, receivedAt: now).validated()
                guard snapshot.city == city, snapshot.providerID == provider.providerID else { throw WeatherServiceError.invalidResponse }
                guard let self else { return .init(snapshot: nil, issue: "天气服务已结束。", persistenceIssue: nil, cancelled: true) }
                return await self.finish(snapshot, key: key, token: token)
            } catch {
                guard let self else { return .init(snapshot: nil, issue: "天气服务已结束。", persistenceIssue: nil, cancelled: true) }
                return await self.fail(error, key: key, token: token)
            }
        }
        let flight = Flight(token: token, task: shared); inFlight[key] = flight
        // This unstructured shared task is service-owned. Cancelling a dialog's consumer cannot
        // cancel another consumer (such as the just-saved homepage city) or clear its task token.
        return await presentation(for: flight, previous: previous, at: now, cacheIssue: cacheIssue)
    }
    private func ensureCacheLoaded() async -> String? {
        guard !loaded else { return cacheLoadIssue }
        if cacheLoading == nil { let cache = self.cache; cacheLoading = Task { try await cache.load() } }
        guard let loading = cacheLoading else { return nil }
        let result = await loading.result
        if !loaded {
            loaded = true; cacheLoading = nil
            do {
                let all = try result.get().map { try $0.validated() }
                for entry in all where entry.providerID == provider.providerID {
                    let key = RequestKey(providerID: entry.providerID, city: entry.city)
                    if entries[key].map({ $0.receivedAt > entry.receivedAt }) != true { entries[key] = entry }
                }
            } catch { cacheLoadIssue = "天气缓存读取失败，已有有效读数继续保留。" }
        }
        return cacheLoadIssue
    }
    private func finish(_ snapshot: WeatherSnapshot, key: RequestKey, token: UUID) async -> Completion {
        guard inFlight[key]?.token == token else { return .init(snapshot: nil, issue: "较早的天气请求已失效。", persistenceIssue: nil, cancelled: true) }
        defer { if inFlight[key]?.token == token { inFlight.removeValue(forKey: key) } }
        entries[key] = snapshot
        let retained = Array(entries.values.sorted { $0.receivedAt > $1.receivedAt }.prefix(20))
        entries = Dictionary(retained.map { (RequestKey(providerID: $0.providerID, city: $0.city), $0) }, uniquingKeysWith: { newest, _ in newest })
        let priorWrite = cacheWriting, cache = self.cache, writeToken = UUID()
        // Serialize even injected asynchronous stores, so an older write cannot replace newer data.
        let write = Task<Void, Error> { if let priorWrite { _ = await priorWrite.result }; try await cache.save(retained) }
        cacheWriting = write; cacheWriteToken = writeToken
        var issue: String?
        do {
            try await write.value; cacheLoadIssue = nil
        } catch { issue = "新天气已读取，缓存保存失败；上次磁盘缓存仍保留。" }
        if cacheWriteToken == writeToken { cacheWriting = nil; cacheWriteToken = nil }
        return .init(snapshot: snapshot, issue: nil, persistenceIssue: issue)
    }
    private func fail(_ error: Error, key: RequestKey, token: UUID) -> Completion {
        guard inFlight[key]?.token == token else { return .init(snapshot: nil, issue: "较早的天气请求已失效。", persistenceIssue: nil, cancelled: true) }
        inFlight.removeValue(forKey: key)
        let wasCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        if wasCancelled { lastAttempts.removeValue(forKey: key) }
        return .init(snapshot: nil, issue: wasCancelled ? "天气来源已取消本次请求。" : error.localizedDescription, persistenceIssue: nil, cancelled: wasCancelled)
    }
    private func presentation(for flight: Flight, previous: WeatherSnapshot?, at now: Date, cacheIssue: String?) async -> WeatherPresentation {
        let result = await flight.task.value
        if Task.isCancelled { return cancelled(previous, issue: result.persistenceIssue ?? cacheIssue) }
        if result.cancelled { return .init(freshness: .cancelled, snapshot: previous, issue: result.issue, persistenceIssue: result.persistenceIssue ?? cacheIssue) }
        if let snapshot = result.snapshot {
            if !fresh(snapshot, at: now, maximumAge: 1800) { return fallback(snapshot, at: now, issue: "来源资料已过期。", persistenceIssue: result.persistenceIssue ?? cacheIssue) }
            return .init(freshness: .current, snapshot: snapshot, issue: nil, persistenceIssue: result.persistenceIssue ?? cacheIssue)
        }
        return fallback(previous, at: now, issue: result.issue ?? "天气来源暂不可用。", persistenceIssue: result.persistenceIssue ?? cacheIssue)
    }
    private func cancelled(_ previous: WeatherSnapshot?, issue: String?) -> WeatherPresentation {
        .init(freshness: .cancelled, snapshot: previous, issue: "天气刷新已取消。", persistenceIssue: issue)
    }
    private func fresh(_ snapshot: WeatherSnapshot, at now: Date, maximumAge: TimeInterval) -> Bool {
        let receivedAge = now.timeIntervalSince(snapshot.receivedAt), observedAge = now.timeIntervalSince(snapshot.observedAt)
        return receivedAge.isFinite && observedAge.isFinite && receivedAge >= -5 && receivedAge <= maximumAge && observedAge >= -900 && observedAge <= maximumAge
    }
    private func fallback(_ snapshot: WeatherSnapshot?, at now: Date, issue: String, persistenceIssue: String?) -> WeatherPresentation {
        guard let snapshot else { return .init(freshness: .unavailable, snapshot: nil, issue: issue, persistenceIssue: persistenceIssue) }
        return .init(freshness: fresh(snapshot, at: now, maximumAge: 1800) ? .cached : .stale,
                     snapshot: snapshot, issue: issue, persistenceIssue: persistenceIssue)
    }
}
