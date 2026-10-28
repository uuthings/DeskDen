import XCTest
@testable import LauncherCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor WeatherFixtureTransport: WeatherHTTPTransport {
    let payload: Data
    let status: Int
    private var captured: [URLRequest] = []
    init(_ text: String, status: Int = 200) { payload = Data(text.utf8); self.status = status }
    func response(for request: URLRequest) async throws -> WeatherHTTPResponse {
        captured.append(request); return .init(statusCode: status, data: payload)
    }
    func requests() -> [URLRequest] { captured }
}
private actor WeatherFixtureProvider: WeatherProviding {
    nonisolated let providerID = "fixture"
    var error: URLError?
    var calls = 0
    let observed: Date
    init(observed: Date) { self.observed = observed }
    func setOffline() { error = URLError(.notConnectedToInternet) }
    func count() -> Int { calls }
    func searchCities(query: String, language: String) async throws -> [WeatherCity] { [] }
    func currentWeather(for city: WeatherCity, receivedAt: Date) async throws -> WeatherSnapshot {
        calls += 1; if let error { throw error }
        return .init(city: city, observedAt: observed, receivedAt: receivedAt, temperatureCelsius: 17.3, weatherCode: 2,
                     providerID: providerID, attribution: "Fixture", attributionURL: URL(string: "https://example.com")!)
    }
}
private actor WeatherFailingCache: WeatherCachePersisting {
    let existing: WeatherSnapshot
    init(existing: WeatherSnapshot) { self.existing = existing }
    func load() -> [WeatherSnapshot] { [existing] }
    func save(_ snapshots: [WeatherSnapshot]) throws { throw CocoaError(.fileWriteNoPermission) }
}

final class WeatherCoreTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testTemperaturePreferenceConvertsOnlyPresentationAndPreservesMissingValues() {
        XCTAssertEqual(WeatherTemperatureUnit.celsius.formatted(17.3), "17°C")
        XCTAssertEqual(WeatherTemperatureUnit.fahrenheit.formatted(17.3), "63°F")
        XCTAssertEqual(WeatherTemperatureUnit.fahrenheit.value(fromCelsius: 0), 32)
        XCTAssertEqual(WeatherTemperatureUnit.fahrenheit.value(fromCelsius: -40), -40)
        XCTAssertEqual(WeatherTemperatureUnit.celsius.formatted(-0.1), "0°C")
        XCTAssertEqual(WeatherTemperatureUnit.celsius.formatted(nil), "—")
        XCTAssertEqual(WeatherTemperatureUnit.fahrenheit.formatted(.nan), "—")
        XCTAssertEqual(WeatherTemperatureUnit.fahrenheit.formatted(.infinity), "—")
    }

    private var berlin: WeatherCity { .init(id: "open-meteo:2950159", name: "Berlin", administrativeArea: "Berlin", country: "Germany",
                                           latitude: 52.52437, longitude: 13.41053, timeZoneIdentifier: "Europe/Berlin") }
    func testGeocodingSearchUsesOnlyExplicitQueryAndRetainsDistinctCityIdentity() async throws {
        let transport = WeatherFixtureTransport(#"{"results":[{"id":2950159,"name":"Berlin","latitude":52.52437,"longitude":13.41053,"timezone":"Europe/Berlin","admin1":"Berlin","country":"Germany"}]}"#)
        let provider = OpenMeteoWeatherProvider(access: .nonCommercial, transport: transport)
        let cities = try await provider.searchCities(query: "Berlin", language: "zh")
        XCTAssertEqual(cities, [berlin])
        let request = await transport.requests()[0]
        XCTAssertEqual(request.url?.host, "geocoding-api.open-meteo.com")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(query.contains(.init(name: "name", value: "Berlin")))
        XCTAssertFalse(query.contains { $0.name == "apikey" || $0.name == "latitude" })
        XCTAssertEqual(request.timeoutInterval, 10)
    }
    func testMissingGeocodingResultsAreEmptyRatherThanInventedDefaultCity() async throws {
        let provider = OpenMeteoWeatherProvider(access: .nonCommercial, transport: WeatherFixtureTransport("{}"))
        let result = try await provider.searchCities(query: "NoSuchCity", language: "zh")
        XCTAssertTrue(result.isEmpty)
    }
    func testCurrentWeatherParsesNullWithoutFillingZeroAndUsesAbsoluteTime() async throws {
        let transport = WeatherFixtureTransport(#"{"current_units":{"temperature_2m":"°C","wind_speed_10m":"km/h"},"current":{"time":1800000000,"temperature_2m":17.5,"apparent_temperature":null,"weather_code":2,"is_day":1}}"#)
        let provider = OpenMeteoWeatherProvider(access: .nonCommercial, transport: transport)
        let snapshot = try await provider.currentWeather(for: berlin, receivedAt: now)
        XCTAssertEqual(snapshot.temperatureCelsius, 17.5)
        XCTAssertNil(snapshot.apparentTemperatureCelsius); XCTAssertNil(snapshot.relativeHumidityPercent); XCTAssertNil(snapshot.windSpeedKilometresPerHour)
        XCTAssertEqual(snapshot.observedAt, now); XCTAssertEqual(snapshot.conditionDescription, "局部多云")
        XCTAssertTrue(snapshot.attribution.contains("Open-Meteo"))
        let request = await transport.requests()[0]
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(items.contains(.init(name: "timeformat", value: "unixtime")))
        XCTAssertTrue(items.contains(.init(name: "timezone", value: "Europe/Berlin")))
    }
    func testMissingWeatherAndWrongUnitsAreRejectedInsteadOfShowingSunnyZero() async {
        for text in [#"{"current":{"time":1800000000,"temperature_2m":null,"weather_code":null}}"#,
                     #"{"current_units":{"temperature_2m":"°F"},"current":{"time":1800000000,"temperature_2m":17}}"#] {
            let provider = OpenMeteoWeatherProvider(access: .nonCommercial, transport: WeatherFixtureTransport(text))
            do { _ = try await provider.currentWeather(for: berlin, receivedAt: now); XCTFail("Expected invalid weather") }
            catch { XCTAssertEqual(error as? WeatherServiceError, .invalidResponse) }
        }
    }
    func testDailyForecastUsesCityCivilDatesAndPreservesNullReadings() async throws {
        let transport=WeatherFixtureTransport(#"{"current":{"time":1800000000,"temperature_2m":17},"daily_units":{"temperature_2m_max":"°C","temperature_2m_min":"°C"},"daily":{"time":[1799967600,1800054000],"weather_code":[3,null],"temperature_2m_max":[20,null],"temperature_2m_min":[10,11]}}"#)
        let provider=OpenMeteoWeatherProvider(access:.nonCommercial,transport:transport)
        let value=try await provider.currentWeather(for:berlin,receivedAt:now)
        let day=value.dailyForecast![0]
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(identifier:"Europe/Berlin");formatter.dateFormat="yyyy-MM-dd"
        XCTAssertEqual(day.dayKey,formatter.string(from:Date(timeIntervalSince1970:1_799_967_600)))
        XCTAssertEqual(day.highCelsius,20);XCTAssertEqual(day.lowCelsius,10)
        XCTAssertNil(value.dailyForecast![1].weatherCode);XCTAssertNil(value.dailyForecast![1].highCelsius)
        let url=await transport.requests()[0].url!
        let items=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertTrue(items.contains(.init(name:"daily",value:"weather_code,temperature_2m_max,temperature_2m_min")))
        XCTAssertTrue(items.contains(.init(name:"forecast_days",value:"4")))
    }
    func testMismatchedForecastArraysAndImpossibleTemperaturesAreRejected() async {
        for daily in [#""time":[1800000000],"temperature_2m_max":[]"#,#""time":[1800000000],"temperature_2m_max":[4],"temperature_2m_min":[10]"#] {
            let provider=OpenMeteoWeatherProvider(access:.nonCommercial,transport:WeatherFixtureTransport("{\"current\":{\"time\":1800000000,\"temperature_2m\":17},\"daily\":{\(daily)}}"))
            do {_ = try await provider.currentWeather(for:berlin,receivedAt:now);XCTFail("Expected rejected daily forecast")}
            catch {XCTAssertEqual(error as? WeatherServiceError,.invalidResponse)}
        }
    }
    func testOlderWeatherCacheWithoutForecastStillDecodes() throws {
        let snapshot=WeatherSnapshot(city:berlin,observedAt:now,receivedAt:now,temperatureCelsius:17,providerID:"fixture",attribution:"Fixture",attributionURL:URL(string:"https://example.com")!)
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot)) as! [String:Any]
        json.removeValue(forKey:"dailyForecast")
        let restored=try JSONDecoder().decode(WeatherSnapshot.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertNil(restored.dailyForecast);XCTAssertEqual(try restored.validated().temperatureCelsius,17)
    }
    func testRateLimitAndResponseSizeAreExplicitFailures() async {
        let provider = OpenMeteoWeatherProvider(access: .nonCommercial, transport: WeatherFixtureTransport("{}", status: 429))
        do { _ = try await provider.searchCities(query: "Berlin", language: "zh"); XCTFail() }
        catch { XCTAssertEqual(error as? WeatherServiceError, .rateLimited) }
        let large = OpenMeteoWeatherProvider(access: .nonCommercial, transport: WeatherFixtureTransport(String(repeating: " ", count: 1_048_577)))
        do { _ = try await large.searchCities(query: "Berlin", language: "zh"); XCTFail() }
        catch { XCTAssertEqual(error as? WeatherServiceError, .tooLarge) }
    }
    func testCityValidationRejectsInvalidCoordinatesAndTimeZone() {
        var city = berlin; city.latitude = .nan
        XCTAssertThrowsError(try city.validated())
        city = berlin; city.timeZoneIdentifier = "Missing/Unknown"
        XCTAssertThrowsError(try city.validated())
    }
    func testWeatherCodeUnknownIsNotMappedToClearOrZero() throws {
        let value = WeatherSnapshot(city: berlin, observedAt: now, receivedAt: now, temperatureCelsius: -5, weatherCode: 999,
                                    providerID: "fixture", attribution: "Fixture", attributionURL: URL(string: "https://example.com")!)
        XCTAssertEqual(try value.validated().conditionDescription, "天气状况未知")
    }
    func testServiceCachesGoodReadingsAndDoesNotMakeRedundantRequests() async {
        let provider = WeatherFixtureProvider(observed: now)
        let service = WeatherService(provider: provider)
        let first = await service.load(city: berlin, at: now)
        let cached = await service.load(city: berlin, at: now.addingTimeInterval(100))
        XCTAssertEqual(first.freshness, .current); XCTAssertEqual(cached.freshness, .cached)
        let calls = await provider.count(); XCTAssertEqual(calls, 1)
        let absent = await service.load(city: nil, at: now)
        XCTAssertEqual(absent.freshness, .noCity); XCTAssertNil(absent.snapshot)
    }
    func testOfflineUsesAttributedStaleCacheAndNeverRelabelsItCurrent() async {
        let provider = WeatherFixtureProvider(observed: now)
        let service = WeatherService(provider: provider)
        _ = await service.load(city: berlin, at: now)
        await provider.setOffline()
        let stale = await service.load(city: berlin, at: now.addingTimeInterval(1801))
        XCTAssertEqual(stale.freshness, .stale); XCTAssertFalse(stale.isCurrent)
        XCTAssertEqual(stale.snapshot?.observedAt, now); XCTAssertNotNil(stale.issue)
    }
    func testRefreshThrottleDoesNotMasqueradeAsSuccessfulNetworkRefresh() async {
        let provider = WeatherFixtureProvider(observed: now)
        let service = WeatherService(provider: provider)
        _ = await service.load(city: berlin, at: now)
        let response = await service.load(city: berlin, forceRefresh: true, at: now.addingTimeInterval(5))
        XCTAssertEqual(response.freshness, .cached); XCTAssertNotNil(response.issue)
        let calls = await provider.count(); XCTAssertEqual(calls, 1)
    }
    func testCacheSaveFailureKeepsPreviousPersistentRecordAndReportsNewActualReading() async throws {
        let previous = WeatherSnapshot(city: berlin, observedAt: now.addingTimeInterval(-300), receivedAt: now.addingTimeInterval(-300), temperatureCelsius: 16,
                                       providerID: "fixture", attribution: "Fixture", attributionURL: URL(string: "https://example.com")!)
        let cache = WeatherFailingCache(existing: previous)
        let service = WeatherService(provider: WeatherFixtureProvider(observed: now), cache: cache)
        let result = await service.load(city: berlin, forceRefresh: true, at: now)
        XCTAssertEqual(result.freshness, .current); XCTAssertEqual(result.snapshot?.temperatureCelsius, 17.3)
        XCTAssertNotNil(result.persistenceIssue)
        let stored = await cache.load(); XCTAssertEqual(stored, [previous])
    }
    func testFileCacheAtomicRoundTripAndRejectedWritePreservesOldData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskDen-WeatherTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Context")
        let file = directory.appendingPathComponent("weather.json")
        let cache = WeatherJSONFileCache(fileURL: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let snapshot = WeatherSnapshot(city: berlin, observedAt: now, receivedAt: now, temperatureCelsius: 10,
                                       providerID: "fixture", attribution: "Fixture", attributionURL: URL(string: "https://example.com")!)
        try await cache.save([snapshot])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var invalid = snapshot; invalid.temperatureCelsius = .nan
        do { try await cache.save([invalid]); XCTFail() } catch {}
        let restored = try await cache.load(); XCTAssertEqual(restored, [snapshot])
    }
    func testCancelledRefreshReturnsCancelledAndNoInventedWeather() async {
        let service = WeatherService(provider: WeatherFixtureProvider(observed: now))
        let city = berlin, instant = now
        let task = Task { await service.load(city: city, at: instant) }; task.cancel()
        let result = await task.value
        XCTAssertEqual(result.freshness, .cancelled); XCTAssertNil(result.snapshot)
    }
}
