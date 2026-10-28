import Foundation
import LauncherCore

/// Exercises the actual native context model with isolated storage and an injected provider.
/// No location, network, calendar permission, account or personal data is involved.
@MainActor enum WorkbenchContextChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-context-v5-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let provider = ContextCheckWeatherProvider()
            let directory = root.appendingPathComponent("preferences")
            let model = WorkbenchContextModel(dataDirectory: directory, provider: provider)
            defer { model.stop() }
            check(model.settings.city == nil && model.weather == nil, "context starts without invented city or weather")
            let initialCalls = await provider.totalCalls()
            check(initialCalls == 0, "constructing context does not make an unrequested weather query")
            model.showClock = true
            check(model.saveClock(zone: "America/New_York", twelveHour: true) && !model.showClock && model.settings.timeZoneMode == .system && model.dateContext.timeZoneIdentifier == TimeZone.current.identifier,
                  "clock format saves without introducing a location independent of the selected city")
            let url = directory.appendingPathComponent("context.json"), saved = try Data(contentsOf: url)
            let reloaded = WorkbenchContextModel(dataDirectory: directory, provider: provider)
            defer { reloaded.stop() }
            check(reloaded.settings == model.settings, "clock preferences survive an independent native model reload")
            var draft = model.settings; draft.timeZoneIdentifier = "Asia/Tokyo"; draft.twelveHour = false
            model.showClock = true; model.showClock = false
            check(draft != model.settings && (try? Data(contentsOf: url)) == saved, "discarding local clock draft leaves persisted preferences intact")
            check(!model.saveClock(zone: "Invalid/Nowhere", twelveHour: false) && model.settings == reloaded.settings && (try? Data(contentsOf: url)) == saved,
                  "invalid zone is rejected before replacing valid preferences")

            let timed = ReminderDue(year: 2026, month: 11, day: 2, hour: 9, minute: 30, timeZoneIdentifier: "America/New_York")
            let allDay = ReminderDue(year: 2026, month: 11, day: 2, timeZoneIdentifier: "Europe/Berlin")
            var reminders = ReminderSnapshot()
            reminders.reminders = [.init(id: "timed", title: "独立提醒", due: timed), .init(id: "all-day", title: "原始日期", due: allDay)]
            let store = ReminderStore(directory: directory); try store.save(reminders)
            let reminderData = try Data(contentsOf: store.url), dueInstant = timed.date
            check(model.saveCity(berlin), "selecting a city updates the shared date and clock location")
            let after = try store.load()
            check((try? Data(contentsOf: store.url)) == reminderData && after.reminders.map(\.due) == [timed, allDay] && after.reminders[0].due?.date == dueInstant,
                  "city display change preserves timed and day-only reminder bytes, original zones and due instant")
            check(WorkbenchContextModel.zoneTitle("America/New_York", at: Date(timeIntervalSince1970: 1_783_080_000)).contains("UTC−4") &&
                  WorkbenchContextModel.zoneTitle("America/New_York", at: Date(timeIntervalSince1970: 1_767_225_600)).contains("UTC−5"),
                  "clock zone title uses actual summer and winter UTC offsets")

            let localizedZones=["America/Los_Angeles","America/Atikokan","Europe/Berlin","Asia/Calcutta","Australia/Adelaide","Pacific/Chatham"]
            check(localizedZones.allSatisfy {id in
                let name=WorkbenchContextModel.zoneTitle(id).components(separatedBy:" · ").first ?? ""
                return !name.contains("/") && !name.contains("_") && name.range(of:"[\\p{Han}]",options:.regularExpression) != nil
            }, "all display timezone choices use the app's Chinese localized location names instead of raw IANA identifiers")
            let common=WorkbenchCityCatalog.matches("")
            check(common.count >= 8 && common.allSatisfy {(try? $0.validated()) != nil} && Set(common.map(\.id)).count == common.count,
                  "city picker starts with distinct validated real common locations without inventing weather")
            check(WorkbenchCityCatalog.matches("北京").first?.id == WorkbenchCityCatalog.matches("bei").first?.id &&
                  WorkbenchCityCatalog.matches("new york").first?.timeZoneIdentifier == "America/New_York" &&
                  WorkbenchCityCatalog.providerQuery("北京市") == "北京" && WorkbenchCityCatalog.providerQuery("上海") == "上海",
                  "common city selection supports Chinese and pinyin while provider search strips only optional administrative suffixes")

            model.showWeather = true
            check(model.saveCity(berlin) && !model.showWeather, "manual city save persists selection and closes the dialog")
            let loaded = await wait { !model.loadingWeather && model.weather?.snapshot?.city == berlin }
            check(loaded && model.weather?.isCurrent == true, "manual city receives an actual injected provider reading")
            check(model.dateContext.timeZoneIdentifier == "Europe/Berlin" && model.settings.city?.timeZoneIdentifier == "Europe/Berlin",
                  "weather and display date always use the same selected city's timezone")
            let beforePreview = try Data(contentsOf: url), oldSettings = model.settings
            let preview = await model.service.load(city: tokyo)
            model.showWeather = true; model.showWeather = false
            check(preview.snapshot?.city == tokyo && model.settings == oldSettings && (try? Data(contentsOf: url)) == beforePreview,
                  "previewing and discarding another city cannot save it or change homepage weather")
            check(model.saveCity(tokyo) && model.weather?.snapshot == nil,
                  "saving another city immediately removes the previous city's already-visible reading")
            let cachedCityChanged = await wait { !model.loadingWeather && model.weather?.snapshot?.city == tokyo }
            check(cachedCityChanged && model.weather?.isCurrent == true,
                  "previously previewed city can use its attributed cache after actual save")
            check(model.saveCity(nil), "explicitly clearing weather city saves a nil selection")
            let cleared = await wait { !model.loadingWeather && model.weather?.freshness == .noCity }
            check(cleared && model.weather?.snapshot == nil && model.dateContext.timeZoneIdentifier == TimeZone.current.identifier,
                  "clearing a city removes weather and restores system date and time")

            let linkedDirectory = root.appendingPathComponent("linked-city")
            let linked = WorkbenchContextModel(dataDirectory: linkedDirectory, provider: provider)
            defer { linked.stop() }
            check(linked.settings.timeZoneMode == .system && linked.dateContext.timeZoneIdentifier == TimeZone.current.identifier && linked.settings.city == nil,
                  "new context explicitly follows system date and time without inventing weather")
            linked.showClock = true; linked.showWeather = true
            check(linked.saveContext(city: berlin, zone: "city", twelveHour: true, temperatureUnit: .fahrenheit) &&
                  !linked.showClock && !linked.showWeather && linked.dateContext.timeZoneIdentifier == "Europe/Berlin" && linked.temperature(17) == "63°F",
                  "unified save applies city timezone, hour format and explicit Fahrenheit presentation atomically")
            let linkedLoaded = await wait { !linked.loadingWeather && linked.weather?.snapshot?.city == berlin }
            check(linkedLoaded && linked.weather?.snapshot?.temperatureCelsius == 17 && linked.weatherStatusTitle == "局部多云",
                  "weather presentation exposes the observed condition and leaves stored Celsius readings unchanged")
            let unitDraft = WorkbenchLocationDraft(settings: linked.settings)
            var changedDraft = unitDraft; changedDraft.temperatureUnit = .celsius
            check(!unitDraft.hasChanges && changedDraft.hasChanges && linked.temperatureUnit == .fahrenheit,
                  "temperature changes remain a protected unsaved draft until the combined form is saved")
            var previewClock = unitDraft
            previewClock.twelveHour = false
            let previewInstant = Date(timeIntervalSince1970: 1_767_225_900)
            check(previewClock.time(previewInstant) == "01:05", "weather update time follows the draft city timezone and 24-hour format before save")
            previewClock.city = .init(id:"context:new-york",name:"纽约",latitude:40.7,longitude:-74,timeZoneIdentifier:"America/New_York"); previewClock.twelveHour = true
            check(previewClock.time(previewInstant).contains("下午") && previewClock.time(previewInstant).contains("7:05"),
                  "weather update time follows an unsaved city selection and 12-hour format")
            previewClock.city = nil
            check(previewClock.effectiveTimeZoneIdentifier == TimeZone.current.identifier,
                  "clearing the draft city makes its preview follow system time")
            check(linked.saveCity(tokyo) && linked.dateContext.timeZoneIdentifier == "Asia/Tokyo",
                  "changing city updates the default linked display timezone")
            check(linked.saveContext(city: nil, zone: "city", twelveHour: false, temperatureUnit: .celsius) &&
                  linked.settings.city == nil && linked.dateContext.timeZoneIdentifier == TimeZone.current.identifier,
                  "clearing a linked city falls back to system without inventing another weather location")
            var invalidCity = berlin; invalidCity.timeZoneIdentifier = "Invalid/Nowhere"
            check(!linked.saveContext(city: invalidCity, zone: "city", twelveHour: false, temperatureUnit: .celsius) && linked.settings.city == nil,
                  "a city without valid supplied timezone is rejected rather than assigned a guessed clock")
            check(linked.saveContext(city: berlin, zone: "system", twelveHour: false, temperatureUnit: .celsius) &&
                  linked.settings.timeZoneMode == .city && linked.dateContext.timeZoneIdentifier == berlin.timeZoneIdentifier,
                  "a legacy independent-zone argument cannot separate the selected city's weather and clock")
            let linkedURL = linkedDirectory.appendingPathComponent("context.json")
            let linkedBefore = try Data(contentsOf: linkedURL), linkedSettings = linked.settings
            check(!linked.saveContext(city: tokyo, zone: "Invalid/Nowhere", twelveHour: true, temperatureUnit: .fahrenheit) &&
                  linked.settings == linkedSettings && (try? Data(contentsOf: linkedURL)) == linkedBefore,
                  "invalid combined settings preserve all saved city, clock and temperature fields")
            let linkedReload = WorkbenchContextModel(dataDirectory: linkedDirectory, provider: provider)
            check(linkedReload.settings == linkedSettings, "temperature and timezone-link preferences survive a separate model reload")
            linkedReload.stop()
            for (name, legacy, expectedMode) in [
                ("legacy-explicit", #"{"schema":1,"twelveHour":true,"timeZoneIdentifier":"UTC"}"#, WorkbenchContextTimeZoneMode.system),
                ("legacy-default", #"{"schema":1,"twelveHour":false}"#, WorkbenchContextTimeZoneMode.system)
            ] {
                let legacyDirectory = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
                let legacyURL = legacyDirectory.appendingPathComponent("context.json"), legacyData = Data(legacy.utf8)
                try legacyData.write(to: legacyURL)
                let migrated = WorkbenchContextModel(dataDirectory: legacyDirectory, provider: provider)
                check(migrated.error == nil && migrated.settings.schema == 2 && migrated.settings.timeZoneMode == expectedMode &&
                      migrated.temperatureUnit == .celsius && (try? Data(contentsOf: legacyURL)) == legacyData,
                      "\(name) adopts unified system location in memory and leaves original bytes until explicit save")
                migrated.stop()
            }
            let legacyCityDirectory = root.appendingPathComponent("legacy-city-override")
            try FileManager.default.createDirectory(at:legacyCityDirectory,withIntermediateDirectories:true)
            let legacyCityURL = legacyCityDirectory.appendingPathComponent("context.json")
            var legacyCity = WorkbenchContextPreferences(); legacyCity.city = berlin
            legacyCity.timeZoneMode = .custom; legacyCity.timeZoneIdentifier = "UTC"
            let legacyCityData = try JSONEncoder().encode(legacyCity); try legacyCityData.write(to:legacyCityURL)
            let migratedCity = WorkbenchContextModel(dataDirectory:legacyCityDirectory,provider:provider)
            check(migratedCity.dateContext.timeZoneIdentifier == berlin.timeZoneIdentifier && migratedCity.settings.city == berlin &&
                  migratedCity.settings.timeZoneMode == .city && (try? Data(contentsOf:legacyCityURL)) == legacyCityData,
                  "a legacy city with a separate clock override unifies in memory while preserving its original settings file")
            migratedCity.stop()
            let beijing = WorkbenchCityCatalog.matches("北京").first!, guangzhou = WorkbenchCityCatalog.matches("广州").first!
            check(linked.saveCity(beijing) && linked.zoneTitle == "北京 · UTC+8" && linked.saveCity(guangzhou) && linked.zoneTitle == "广州 · UTC+8",
                  "Chinese cities retain their selected names instead of showing Shanghai's IANA representative name")

            // A failing destination preserves both in-memory settings and the last valid bytes.
            let oldDirectory = root.appendingPathComponent("preferences-backup")
            let beforeFailure = try Data(contentsOf: url), beforeSettings = model.settings
            try FileManager.default.moveItem(at: directory, to: oldDirectory)
            try Data("write obstruction".utf8).write(to: directory)
            check(!model.saveClock(zone: "UTC", twelveHour: true) && model.settings == beforeSettings && model.error != nil,
                  "failed persistence is reported without adopting unsaved preferences")
            check((try? Data(contentsOf: oldDirectory.appendingPathComponent("context.json"))) == beforeFailure,
                  "failed persistence retains the last valid context file")
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.moveItem(at: oldDirectory, to: directory)

            for (name, data) in [("malformed", Data("{broken".utf8)), ("unsupported", Data(#"{"schema":3,"twelveHour":false}"#.utf8)),
                                 ("invalid-zone", Data(#"{"schema":1,"twelveHour":false,"timeZoneIdentifier":"Missing/Nowhere"}"#.utf8))] {
                let badDirectory = root.appendingPathComponent(name), badURL = badDirectory.appendingPathComponent("context.json")
                try FileManager.default.createDirectory(at: badDirectory, withIntermediateDirectories: true)
                try data.write(to: badURL)
                let protected = WorkbenchContextModel(dataDirectory: badDirectory, provider: provider)
                check(protected.error != nil && !protected.saveClock(zone: "UTC", twelveHour: false) && !protected.saveCity(berlin) && (try? Data(contentsOf: badURL)) == data,
                      "\(name) context is protected against clock and city overwrites")
                protected.stop()
            }

            let staleProvider = ContextCheckWeatherProvider(reply: .stale)
            let stale = WorkbenchContextModel(dataDirectory: root.appendingPathComponent("stale"), provider: staleProvider)
            check(stale.saveCity(berlin), "stale source fixture saves only the selected city")
            let staleFinished = await wait { !stale.loadingWeather && stale.weather != nil }
            check(staleFinished && stale.weather?.freshness == .stale && stale.weather?.isCurrent == false && stale.weather?.snapshot != nil,
                  "old provider observation remains explicitly stale instead of becoming current")
            stale.stop()
            let cancelledProvider = ContextCheckWeatherProvider(reply: .cancelled)
            let cancelled = WorkbenchContextModel(dataDirectory: root.appendingPathComponent("cancelled"), provider: cancelledProvider)
            _ = cancelled.saveCity(berlin)
            let cancelledFinished = await wait { !cancelled.loadingWeather && cancelled.weather != nil }
            check(cancelledFinished && cancelled.weather?.freshness == .cancelled && cancelled.weather?.isCurrent == false && cancelled.weather?.snapshot == nil,
                  "provider cancellation produces no invented or current weather")
            cancelled.stop()

            let gated = ContextCheckWeatherProvider(gated: true)
            let racing = WorkbenchContextModel(dataDirectory: root.appendingPathComponent("racing"), provider: gated)
            _ = racing.saveCity(berlin)
            let firstStarted = await waitAsync { await gated.count(berlin) == 1 }
            check(firstStarted, "first city request is held by a deterministic fixture gate")
            _ = racing.saveCity(tokyo)
            let secondStarted = await waitAsync { await gated.count(tokyo) == 1 }
            check(secondStarted && racing.weather?.snapshot == nil, "switching city clears the previous city's display while awaiting the new source")
            await gated.release(tokyo)
            let secondFinished = await wait { !racing.loadingWeather && racing.weather?.snapshot?.city == tokyo }
            await gated.release(berlin); _ = await racing.service.load(city: berlin)
            check(secondFinished && racing.settings.city == tokyo && racing.weather?.snapshot?.city == tokyo,
                  "late first-city response cannot replace the newly saved city's weather")
            racing.stop()

            let sharedProvider = ContextCheckWeatherProvider(gated: true)
            let fastSave = WorkbenchContextModel(dataDirectory: root.appendingPathComponent("fast-save"), provider: sharedProvider)
            let previewCity = berlin
            let pendingPreview = Task { await fastSave.service.load(city: previewCity) }
            let previewStarted = await waitAsync { await sharedProvider.count(previewCity) == 1 }
            _ = fastSave.saveCity(previewCity)
            for _ in 0..<16 { await Task.yield() }
            pendingPreview.cancel(); await sharedProvider.release(previewCity)
            let previewResult = await pendingPreview.value
            let savedFinished = await wait { !fastSave.loadingWeather && fastSave.weather?.snapshot?.city == previewCity }
            let sharedCalls = await sharedProvider.count(previewCity)
            check(previewStarted && previewResult.freshness == .cancelled && savedFinished && fastSave.weather?.isCurrent == true && fastSave.weather?.issue == nil && sharedCalls == 1,
                  "immediate save joins pending preview; dialog cancellation cannot cancel saved city or trigger refresh throttle")
            fastSave.stop()

            let stoppedProvider = ContextCheckWeatherProvider(gated: true)
            let stopped = WorkbenchContextModel(dataDirectory: root.appendingPathComponent("stopped"), provider: stoppedProvider)
            _ = stopped.saveCity(berlin)
            let stopStarted = await waitAsync { await stoppedProvider.count(berlin) == 1 }
            stopped.stop(); await stoppedProvider.release(berlin); _ = await stopped.service.load(city: berlin)
            check(stopStarted && !stopped.loadingWeather && stopped.weather == nil,
                  "stopped native consumer ignores late completion while retaining the service's verified shared cache")
        } catch { check(false, "context fixture setup: \(error.localizedDescription)") }
        return (count, failures)
    }
    private static var berlin: WeatherCity { .init(id: "context:berlin", name: "Berlin", latitude: 52.5, longitude: 13.4, timeZoneIdentifier: "Europe/Berlin") }
    private static var tokyo: WeatherCity { .init(id: "context:tokyo", name: "Tokyo", latitude: 35.6, longitude: 139.7, timeZoneIdentifier: "Asia/Tokyo") }
    private static func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat { if condition() { return true }; try? await Task.sleep(for: .milliseconds(1)) } while ContinuousClock.now < deadline
        return condition()
    }
    private static func waitAsync(_ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(1)) } while ContinuousClock.now < deadline
        return await condition()
    }
}

private actor ContextCheckWeatherProvider: WeatherProviding {
    nonisolated let providerID = "native-context-fixture"
    enum Reply: Sendable, Equatable { case current, stale, cancelled }
    private struct Pending { var city: WeatherCity; var date: Date; var continuation: CheckedContinuation<WeatherSnapshot, Error> }
    private var pending: [WeatherCity: [Pending]] = [:]
    private var counts: [WeatherCity: Int] = [:]
    private var replies: [WeatherCity: Reply] = [:]
    private let gated: Bool
    private let reply: Reply
    init(gated: Bool = false, reply: Reply = .current) { self.gated = gated; self.reply = reply }
    func searchCities(query: String, language: String) async throws -> [WeatherCity] { [] }
    func currentWeather(for city: WeatherCity, receivedAt: Date) async throws -> WeatherSnapshot {
        counts[city, default: 0] += 1
        if let reply = replies[city] { return try snapshot(city, at: receivedAt, reply: reply) }
        if !gated { return try snapshot(city, at: receivedAt, reply: reply) }
        return try await withCheckedThrowingContinuation { continuation in pending[city, default: []].append(.init(city: city, date: receivedAt, continuation: continuation)) }
    }
    func totalCalls() -> Int { counts.values.reduce(0, +) }
    func count(_ city: WeatherCity) -> Int { counts[city, default: 0] }
    func release(_ city: WeatherCity) {
        replies[city] = reply
        for item in pending.removeValue(forKey: city) ?? [] {
            do { item.continuation.resume(returning: try snapshot(city, at: item.date, reply: reply)) }
            catch { item.continuation.resume(throwing: error) }
        }
    }
    private func snapshot(_ city: WeatherCity, at date: Date, reply: Reply) throws -> WeatherSnapshot {
        if reply == .cancelled { throw CancellationError() }
        return .init(city: city, observedAt: date.addingTimeInterval(reply == .stale ? -7200 : 0), receivedAt: date,
                     temperatureCelsius: 17, weatherCode: 2, providerID: providerID,
                     attribution: "Isolated fixture", attributionURL: URL(string: "https://example.com")!)
    }
}
