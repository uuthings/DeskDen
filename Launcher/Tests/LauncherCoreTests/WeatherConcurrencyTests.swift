import XCTest
@testable import LauncherCore

/// Deterministic gates model a slow public provider without using the network.
private actor WeatherConcurrencyProvider: WeatherProviding {
    nonisolated let providerID = "concurrency-fixture"
    enum Reply: Sendable, Equatable { case current, stale, cancelled, offline }
    private struct Pending {
        var city: WeatherCity
        var receivedAt: Date
        var continuation: CheckedContinuation<WeatherSnapshot, Error>
    }
    private var pending: [WeatherCity: [Pending]] = [:]
    private var replies: [WeatherCity: Reply] = [:]
    private var calls: [WeatherCity: Int] = [:]
    func searchCities(query: String, language: String) async throws -> [WeatherCity] { [] }
    func currentWeather(for city: WeatherCity, receivedAt: Date) async throws -> WeatherSnapshot {
        calls[city, default: 0] += 1
        if let reply = replies[city] { return try value(city, at: receivedAt, reply: reply) }
        return try await withCheckedThrowingContinuation { continuation in
            pending[city, default: []].append(.init(city: city, receivedAt: receivedAt, continuation: continuation))
        }
    }
    func count(_ city: WeatherCity) -> Int { calls[city, default: 0] }
    func release(_ city: WeatherCity, reply: Reply = .current) {
        replies[city] = reply
        for request in pending.removeValue(forKey: city) ?? [] {
            do { request.continuation.resume(returning: try value(request.city, at: request.receivedAt, reply: reply)) }
            catch { request.continuation.resume(throwing: error) }
        }
    }
    private func value(_ city: WeatherCity, at date: Date, reply: Reply) throws -> WeatherSnapshot {
        if reply == .cancelled { throw CancellationError() }
        if reply == .offline { throw URLError(.notConnectedToInternet) }
        return .init(city: city, observedAt: date.addingTimeInterval(reply == .stale ? -7200 : 0), receivedAt: date,
                     temperatureCelsius: city.latitude, weatherCode: 2, providerID: providerID,
                     attribution: "Isolated fixture", attributionURL: URL(string: "https://example.com")!)
    }
}

private actor WeatherSerialCache: WeatherCachePersisting {
    private var pending: CheckedContinuation<Void, Never>?
    private var writeCount = 0
    private var values: [WeatherSnapshot] = []
    private var released = false
    func load() -> [WeatherSnapshot] { values }
    func save(_ snapshots: [WeatherSnapshot]) async {
        writeCount += 1
        if writeCount == 1, !released { await withCheckedContinuation { pending = $0 } }
        values = snapshots
    }
    func count() -> Int { writeCount }
    func release() { released = true; pending?.resume(); pending = nil }
}

final class WeatherConcurrencyTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var berlin: WeatherCity { .init(id: "fixture:berlin", name: "Berlin", latitude: 52.5, longitude: 13.4, timeZoneIdentifier: "Europe/Berlin") }
    private var tokyo: WeatherCity { .init(id: "fixture:tokyo", name: "Tokyo", latitude: 35.6, longitude: 139.7, timeZoneIdentifier: "Asia/Tokyo") }

    func testPreviewAndImmediateSaveShareOneActualRequestDespiteRefreshThrottle() async {
        let provider = WeatherConcurrencyProvider(), service = WeatherService(provider: provider)
        let city = berlin, instant = now
        let preview = Task { await service.load(city: city, at: instant) }
        let began = await wait { await provider.count(city) == 1 }; XCTAssertTrue(began)
        let saved = Task { await service.load(city: city, forceRefresh: true, at: instant.addingTimeInterval(0.1)) }
        for _ in 0..<16 { await Task.yield() }
        preview.cancel()
        await provider.release(city)
        let first = await preview.value, second = await saved.value
        XCTAssertEqual(first.freshness, .cancelled)
        XCTAssertTrue(second.isCurrent); XCTAssertEqual(second.snapshot?.city, city)
        XCTAssertNil(second.issue)
        let calls = await provider.count(city); XCTAssertEqual(calls, 1)
    }

    func testCancellingFirstConsumerStillCommitsSharedResultForLaterConsumers() async {
        let provider = WeatherConcurrencyProvider(), cache = WeatherMemoryCache()
        let service = WeatherService(provider: provider, cache: cache), city = berlin, instant = now
        let consumer = Task { await service.load(city: city, at: instant) }
        let began = await wait { await provider.count(city) == 1 }; XCTAssertTrue(began)
        consumer.cancel(); await provider.release(city)
        let cancelled = await consumer.value
        XCTAssertEqual(cancelled.freshness, .cancelled); XCTAssertFalse(cancelled.isCurrent)
        let later = await service.load(city: city, at: instant.addingTimeInterval(1))
        XCTAssertEqual(later.freshness, .cached); XCTAssertEqual(later.snapshot?.city, city)
        let persisted = await cache.load(); XCTAssertEqual(persisted.map(\.city), [city])
        let calls = await provider.count(city); XCTAssertEqual(calls, 1)
    }

    func testSamePublicIDWithDifferentCoordinatesOrTimezoneDoesNotShareRequestOrCache() async {
        let provider = WeatherConcurrencyProvider(), service = WeatherService(provider: provider)
        let original = berlin, instant = now
        var revised = original; revised.latitude = 40; revised.longitude = -74; revised.timeZoneIdentifier = "America/New_York"
        let other = revised
        let first = Task { await service.load(city: original, at: instant) }
        let second = Task { await service.load(city: other, at: instant) }
        let began = await wait { let a = await provider.count(original), b = await provider.count(other); return a == 1 && b == 1 }; XCTAssertTrue(began)
        await provider.release(other); await provider.release(original)
        let a = await first.value, b = await second.value
        XCTAssertEqual(a.snapshot?.city, original); XCTAssertEqual(b.snapshot?.city, other)
        let cached = await service.load(city: original, at: instant.addingTimeInterval(1))
        XCTAssertEqual(cached.snapshot?.city, original)
    }

    func testOutOfOrderCitiesKeepTheirOwnFlightAndLaterJoiners() async {
        let provider = WeatherConcurrencyProvider(), service = WeatherService(provider: provider)
        let a = berlin, b = tokyo, instant = now
        let old = Task { await service.load(city: a, at: instant) }
        let next = Task { await service.load(city: b, at: instant) }
        let began = await wait { let first = await provider.count(a), second = await provider.count(b); return first == 1 && second == 1 }; XCTAssertTrue(began)
        await provider.release(a); _ = await old.value
        let joined = Task { await service.load(city: b, forceRefresh: true, at: instant) }
        for _ in 0..<16 { await Task.yield() }
        await provider.release(b)
        let result = await next.value, second = await joined.value
        XCTAssertEqual(result.snapshot?.city, b); XCTAssertEqual(second.snapshot?.city, b)
        XCTAssertTrue(second.isCurrent)
        let calls = await provider.count(b); XCTAssertEqual(calls, 1)
    }

    func testProviderCancellationClearsAttemptSoImmediateRetryIsAllowed() async {
        let provider = WeatherConcurrencyProvider(), service = WeatherService(provider: provider), city = berlin
        await provider.release(city, reply: .cancelled)
        let cancelled = await service.load(city: city, at: now)
        XCTAssertEqual(cancelled.freshness, .cancelled); XCTAssertNil(cancelled.snapshot)
        await provider.release(city)
        let retry = await service.load(city: city, at: now.addingTimeInterval(1))
        XCTAssertEqual(retry.freshness, .current)
        let calls = await provider.count(city); XCTAssertEqual(calls, 2)
    }

    func testActualFailureRetainsThrottleAndNeverInventsAReading() async {
        let provider = WeatherConcurrencyProvider(), service = WeatherService(provider: provider), city = berlin
        await provider.release(city, reply: .offline)
        let failed = await service.load(city: city, at: now)
        await provider.release(city)
        let immediate = await service.load(city: city, forceRefresh: true, at: now.addingTimeInterval(1))
        XCTAssertEqual(failed.freshness, .unavailable); XCTAssertNil(failed.snapshot)
        XCTAssertEqual(immediate.freshness, .unavailable); XCTAssertNotNil(immediate.issue)
        let calls = await provider.count(city); XCTAssertEqual(calls, 1)
    }

    func testStaleSharedProviderResultIsNeverMarkedCurrent() async {
        let provider = WeatherConcurrencyProvider(), service = WeatherService(provider: provider), city = berlin
        await provider.release(city, reply: .stale)
        let result = await service.load(city: city, at: now)
        XCTAssertEqual(result.freshness, .stale); XCTAssertFalse(result.isCurrent)
        XCTAssertEqual(result.snapshot?.observedAt, now.addingTimeInterval(-7200))
    }

    func testCacheWritesAreSerializedSoOlderSaveCannotReplaceBothCityResults() async {
        let provider = WeatherConcurrencyProvider(), cache = WeatherSerialCache()
        let service = WeatherService(provider: provider, cache: cache), a = berlin, b = tokyo, instant = now
        let first = Task { await service.load(city: a, at: instant) }
        let began = await wait { await provider.count(a) == 1 }; XCTAssertTrue(began)
        await provider.release(a)
        let saving = await wait { await cache.count() == 1 }; XCTAssertTrue(saving)
        let second = Task { await service.load(city: b, at: instant.addingTimeInterval(1)) }
        let secondBegan = await wait { await provider.count(b) == 1 }; XCTAssertTrue(secondBegan)
        await provider.release(b)
        for _ in 0..<16 { await Task.yield() }
        let before = await cache.count(); XCTAssertEqual(before, 1)
        await cache.release()
        _ = await first.value; _ = await second.value
        let stored = await cache.load()
        XCTAssertEqual(Set(stored.map(\.city)), Set([a, b]))
        let after = await cache.count(); XCTAssertEqual(after, 2)
    }

    private func wait(_ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(1)) } while ContinuousClock.now < deadline
        return await condition()
    }
}
