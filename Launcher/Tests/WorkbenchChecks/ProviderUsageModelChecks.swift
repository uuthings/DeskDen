import AppKit
import Foundation
import LauncherCore

private actor FixtureCredentials: ProviderUsageCredentialStoring {
    var values: [UUID: String] = [:]
    var failWrite = false
    func read(id: UUID) -> String? { values[id] }
    func write(_ secret: String, id: UUID) throws { if failWrite { throw ProviderUsageFailure.credentials }; values[id] = secret }
    func remove(id: UUID) { values[id] = nil }
    func setFailWrite(_ value: Bool) { failWrite = value }
    var count: Int { values.count }
}
private actor FixtureClient: ProviderUsageQuerying {
    var calls = 0
    var failure: ProviderUsageFailure?
    var hold = false
    var date: Date
    init(_ date: Date) { self.date = date }
    func configure(failure: ProviderUsageFailure? = nil, hold: Bool = false, date: Date? = nil) { self.failure = failure; self.hold = hold; if let date { self.date = date } }
    func fetch(configuration: ProviderUsageConfiguration, secret: String) async throws -> ProviderUsageSnapshot {
        calls += 1
        while hold { try await Task.sleep(for: .milliseconds(10)) }
        if let failure { throw failure }
        return .init(sourceID: configuration.id, observedAt: date, usedBytes: 200, limitBytes: 1000, resetsAt: date.addingTimeInterval(86400), displayUnit: .binaryGB, sourceDescription: "fixture API")
    }
}
@MainActor private final class FixtureClock { var date = Date(timeIntervalSince1970: 1_780_000_000) }
private final class FixtureHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int, [String: String], Data) = (200, [:], Data())
    func set(_ status: Int, headers: [String: String] = [:], body: Data = Data()) { lock.lock(); defer { lock.unlock() }; value = (status, headers, body) }
    func read() -> (Int, [String: String], Data) { lock.lock(); defer { lock.unlock() }; return value }
}
private final class FixtureHTTPProtocol: URLProtocol {
    static let state = FixtureHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, data) = Self.state.read()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ProviderUsageModelChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-provider-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = FixtureClock(), credentials = FixtureCredentials()
        let client = FixtureClient(clock.date)
        var failures = 0, checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") \(message)") }
        func wait(_ condition: @escaping @MainActor () -> Bool) async {
            for _ in 0..<500 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        }
        let model = ProviderUsageModel(dataDirectory: root, startServices: false, client: client, credentials: credentials, now: { clock.date })
        try? await Task.sleep(for: .milliseconds(40))
        check(await client.calls == 0, "disabled background services never query")
        let first = ProviderUsageConfiguration(kind: .bandwagon, name: "First service", resourceID: "101")
        let browser = ProviderUsageConfiguration(kind: .iproyal, name: "Browser order", resourceID: "202")
        check(await model.save(browser), "IPRoyal can save pending connection without fake API query")
        check(await client.calls == 0 && model.state(for: browser.id).snapshot == nil, "pending browser source has no manufactured reading")
        model.receivePhysicalTraffic(.init(epoch: clock.date, received: 100, sent: 100))
        check(await model.save(first, secret: "fixture-first-key"), "validated API source stores a first reading")
        let saved = model.sources.first { $0.id == first.id }!
        check(saved.credentialID != nil && model.state(for: first.id).snapshot?.usedBytes == 200, "credential reference and authoritative reading commit together")
        let persisted = try String(contentsOf: root.appendingPathComponent("provider-usage.json"), encoding: .utf8)
        check(!persisted.contains("fixture-first-key"), "plaintext key is absent from persisted configuration")
        let originalID = saved.credentialID
        await client.configure(failure: .authentication)
        check(!(await model.save(saved, secret: "fixture-rejected-key")), "invalid replacement key is rejected before storage")
        let retainedKeys = await credentials.count
        check(model.sources.first(where: { $0.id == first.id })?.credentialID == originalID && retainedKeys == 1, "rejected replacement preserves original credential")
        await client.configure(); await credentials.setFailWrite(true)
        check(!(await model.save(saved, secret: "fixture-keychain-failure")), "Keychain failure cannot commit replacement metadata")
        check(model.sources.first(where: { $0.id == first.id })?.credentialID == originalID, "Keychain failure keeps old connection")
        await credentials.setFailWrite(false)
        model.receivePhysicalTraffic(.init(epoch: clock.date, received: 1_000_000_100, sent: 100))
        await client.configure(hold: true)
        model.refresh(id: first.id)
        await wait { model.refreshing.contains(first.id) }
        model.receivePhysicalTraffic(.init(epoch: clock.date, received: 1_200_000_100, sent: 100))
        await client.configure()
        await wait { !model.refreshing.contains(first.id) }
        check(model.state(for: first.id).refresh.pendingBytes == 200_000_000, "successful request retains traffic accrued while in flight")
        check(model.state(for: browser.id).refresh.pendingBytes == 1_200_000_000, "one source success never acknowledges another source traffic")
        try await model.prepareForQuit(); model.resumeAfterCancelledQuit()
        let restored = ProviderUsageModel(dataDirectory: root, startServices: false, client: client, credentials: credentials, now: { clock.date })
        check(restored.state(for: first.id).refresh.pendingBytes == 200_000_000 && restored.state(for: browser.id).refresh.pendingBytes == 1_200_000_000, "each source pending bytes survive restart")
        restored.receivePhysicalTraffic(.init(epoch: clock.date, received: 1_300_000_100, sent: 100))
        check(restored.state(for: first.id).refresh.pendingBytes == 300_000_000, "restored checkpoint adds only new measured bytes")
        await client.configure(failure: .rateLimited(retryAfter: 7200))
        restored.refresh(id: first.id); await wait { !restored.refreshing.contains(first.id) }
        let afterFailure = await client.calls
        restored.refresh(id: first.id)
        check(await client.calls == afterFailure && restored.state(for: first.id).refresh.pendingBytes == 300_000_000, "manual refresh respects Retry-After and keeps pending traffic")
        clock.date = clock.date.addingTimeInterval(7201); await client.configure(failure: .authentication)
        restored.refresh(id: first.id); await wait { !restored.refreshing.contains(first.id) }
        check(restored.state(for: first.id).refresh.authenticationRequired, "authentication failure pauses automatic and manual retries")
        let authCalls = await client.calls
        restored.refresh(id: first.id); try? await Task.sleep(for: .milliseconds(30))
        check(await client.calls == authCalls, "authentication failure does not hammer endpoint")
        await client.configure(date: clock.date)
        check(await restored.save(saved, secret: "fixture-reconnected-key"), "verified replacement resumes authenticated source")
        check(!restored.state(for: first.id).refresh.authenticationRequired, "successful reconnection clears authentication pause")

        let second = ProviderUsageConfiguration(kind: .bandwagon, name: "Second service", resourceID: "303")
        check(await restored.save(second, secret: "fixture-second-key"), "multiple API instances keep separate verified credentials")
        clock.date = clock.date.addingTimeInterval(21_601); await client.configure(hold: true, date: clock.date)
        restored.refresh(id: first.id, manual: false); restored.refresh(id: second.id, manual: false)
        check(restored.refreshing == [first.id], "automatic queries are serialized across sources")
        await client.configure(date: clock.date); await wait { !restored.refreshing.contains(first.id) }
        restored.refresh(id: second.id, manual: false)
        check(!restored.refreshing.contains(second.id), "automatic sources remain staggered after a quick response")
        clock.date = clock.date.addingTimeInterval(15); await client.configure(date: clock.date)
        restored.refresh(id: second.id, manual: false); await wait { !restored.refreshing.contains(second.id) }
        check(restored.state(for: second.id).refresh.lastSuccessAt == clock.date, "next source refreshes when its stagger interval expires")
        var paused = restored.sources.first(where: { $0.id == second.id })!; paused.enabled = false
        check(await restored.save(paused), "automatic refresh can be paused without removing connection")
        let beforePaused = await client.calls
        restored.refresh(id: second.id, manual: false)
        check(!restored.refreshing.contains(second.id), "paused source does not start automatic query")
        restored.refresh(id: second.id, manual: true); await wait { !restored.refreshing.contains(second.id) }
        check(await client.calls == beforePaused + 1, "paused automatic refresh still allows an explicit manual query")

        let sleepingModel = ProviderUsageModel(dataDirectory: root.appendingPathComponent("sleep"), startServices: false,
            client: client, credentials: credentials, browserRequest: { _ in try await Task.sleep(for: .seconds(30)); throw ProviderUsageFailure.cancelled }, now: { clock.date })
        check(await sleepingModel.save(browser), "sleep fixture begins with a pending browser source")
        sleepingModel.refresh(id: browser.id)
        sleepingModel.setSleeping(true)
        check(sleepingModel.refreshing.isEmpty && sleepingModel.state(for: browser.id).refresh.lastAttemptAt == nil, "sleep cancels initial query and removes the abandoned initial-attempt gate")
        sleepingModel.setSleeping(false); sleepingModel.refresh(id: browser.id, manual: false)
        check(sleepingModel.refreshing.contains(browser.id), "initial connection remains refreshable after waking")
        sleepingModel.setSleeping(true); try await sleepingModel.prepareForQuit()

        let rollbackURL = root.appendingPathComponent("provider-usage.json"), originalBytes = try Data(contentsOf: rollbackURL)
        let countBeforeRollback = await credentials.count
        try Data("{externally damaged".utf8).write(to: rollbackURL)
        check(!(await restored.save(saved, secret: "fixture-uncommitted-key")), "metadata write failure rejects a newly verified key")
        check(await credentials.count == countBeforeRollback && restored.sources.first(where: { $0.id == first.id })?.credentialID != nil, "metadata failure removes candidate secret and retains active credential")
        try originalBytes.write(to: rollbackURL)

        let damaged = root.appendingPathComponent("damaged"), bad = Data("{broken".utf8)
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        try bad.write(to: damaged.appendingPathComponent("provider-usage.json"))
        let protected = ProviderUsageModel(dataDirectory: damaged, startServices: false, client: client, credentials: credentials)
        let protectedSave = await protected.save(browser)
        check(protected.storageError != nil && !protectedSave, "damaged documents are visibly protected from replacement")
        check(try Data(contentsOf: damaged.appendingPathComponent("provider-usage.json")) == bad, "damaged source bytes remain unchanged")

        let request = try ProviderUsageAPIClient.request(configuration: first, secret: "fixture&plus+key")
        check(request.httpMethod == "POST" && request.url?.absoluteString == "https://api.64clouds.com/v1/getServiceInfo" && request.url?.query == nil, "KiWi API uses fixed read-only POST endpoint without URL credential")
        check(String(data: request.httpBody!, encoding: .utf8) == "veid=101&api_key=fixture%26plus%2Bkey", "form encoding preserves credential separators")
        let response = Data("{\"error\":0,\"plan_monthly_data\":1073741824000,\"data_counter\":107374182400,\"monthly_data_multiplier\":2,\"data_next_reset\":1795000000}".utf8)
        let reading = try ProviderUsageAPIClient.decodeBandwagon(response, sourceID: first.id, now: clock.date)
        check(reading.limitBytes == 2_147_483_648_000 && reading.usedBytes == 214_748_364_800 && reading.usedPercent == 10, "multiplier applies to both plan and usage without changing percentage")
        check(Double(reading.limitBytes) / reading.displayUnit.divisor == 2000 && reading.resetsAt == Date(timeIntervalSince1970: 1_795_000_000), "provider binary-GB display and Unix reset are preserved")
        for (multiplier, expectedLimit, expectedUsed) in [(0.5, UInt64(536_870_912_000), UInt64(53_687_091_200)),
                                                         (1.0, UInt64(1_073_741_824_000), UInt64(107_374_182_400))] {
            let fields: [String: Any] = ["error": 0, "plan_monthly_data": 1_073_741_824_000,
                "data_counter": 107_374_182_400, "monthly_data_multiplier": multiplier, "data_next_reset": 1_795_000_000]
            let body = try JSONSerialization.data(withJSONObject: fields)
            let scaled = try ProviderUsageAPIClient.decodeBandwagon(body, sourceID: first.id, now: clock.date)
            check(scaled.limitBytes == expectedLimit && scaled.usedBytes == expectedUsed && scaled.usedPercent == 10,
                  "multiplier \(multiplier) preserves provider allowance, usage and percentage")
            check(scaled.remaining == expectedLimit - expectedUsed, "multiplier \(multiplier) preserves remaining allowance")
        }
        let overage = Data("{\"error\":0,\"plan_monthly_data\":1073741824000,\"data_counter\":1181116006400,\"monthly_data_multiplier\":1,\"data_next_reset\":1795000000}".utf8)
        let overageReading = try ProviderUsageAPIClient.decodeBandwagon(overage, sourceID: first.id, now: clock.date)
        check(overageReading.remaining == 0 && overageReading.usedBytes == 1_181_116_006_400 && abs(overageReading.usedPercent - 110) < 0.000_001,
              "over-quota provider reading preserves actual usage while remaining allowance stops at zero")
        for invalid in ["{}", "{\"error\":42}", "{\"error\":0,\"plan_monthly_data\":0,\"data_counter\":0,\"monthly_data_multiplier\":1,\"data_next_reset\":1}"] {
            do { _ = try ProviderUsageAPIClient.decodeBandwagon(Data(invalid.utf8), sourceID: first.id, now: clock.date); check(false, "invalid response rejects") }
            catch { check(true, "invalid or non-success provider response rejects") }
        }
        check(ProviderUsageAPIClient.retryAfter("3600", now: clock.date) == 3600, "Retry-After seconds are recognized")
        let httpConfiguration = URLSessionConfiguration.ephemeral
        httpConfiguration.protocolClasses = [FixtureHTTPProtocol.self]
        let httpSession = URLSession(configuration: httpConfiguration)
        defer { httpSession.invalidateAndCancel() }
        let httpClient = ProviderUsageAPIClient(session: httpSession)
        FixtureHTTPProtocol.state.set(200, headers: ["Content-Type": "application/json", "Content-Length": String(response.count)], body: response)
        let fetchStartedAt = Date()
        let fetched = try await httpClient.fetch(configuration: first, secret: "fixture-http-key")
        check(fetched.sourceID == first.id && fetched.limitBytes == 2_147_483_648_000 && fetched.usedBytes == 214_748_364_800
              && fetched.remaining == 1_932_735_283_200 && fetched.usedPercent == 10,
              "HTTP 200 body reaches the authoritative quota decoder with correct source identity")
        check(fetched.displayUnit == .binaryGB && fetched.resetsAt == Date(timeIntervalSince1970: 1_795_000_000)
              && fetched.observedAt >= fetchStartedAt && fetched.observedAt <= Date(),
              "HTTP success keeps provider units and reset instant with a fresh observation timestamp")

        let httpCredentials = FixtureCredentials()
        let httpModelDirectory = root.appendingPathComponent("http-model")
        let httpModel = ProviderUsageModel(dataDirectory: httpModelDirectory, startServices: false, client: httpClient, credentials: httpCredentials)
        check(await httpModel.save(first, secret: "fixture-http-saved-key"), "HTTP-verified source saves through the real API client and model")
        let acceptedHTTPState = httpModel.state(for: first.id)
        let acceptedHTTPCredential = httpModel.sources.first(where: { $0.id == first.id })?.credentialID
        let httpTrafficEpoch = Date()
        httpModel.receivePhysicalTraffic(.init(epoch: httpTrafficEpoch, received: 0, sent: 0))
        httpModel.receivePhysicalTraffic(.init(epoch: httpTrafficEpoch, received: 300_000_000, sent: 200_000_000))
        let providerFailure = Data("{\"error\":42,\"message\":\"fixture-only-provider-detail\"}".utf8)
        FixtureHTTPProtocol.state.set(200, headers: ["Content-Type": "application/json"], body: providerFailure)
        do { _ = try await httpClient.fetch(configuration: first, secret: "fixture-http-key"); check(false, "nonzero API error in HTTP 200 rejects") }
        catch { check(error as? ProviderUsageFailure == .server(42), "nonzero API error stays a provider failure without guessed authentication semantics") }
        httpModel.refresh(id: first.id)
        await wait { !httpModel.refreshing.contains(first.id) }
        let failedHTTPState = httpModel.state(for: first.id)
        check(acceptedHTTPState.snapshot != nil && failedHTTPState.snapshot == acceptedHTTPState.snapshot
              && failedHTTPState.refresh.lastSuccessAt == acceptedHTTPState.refresh.lastSuccessAt,
              "provider JSON error retains the exact previous reading and successful observation time")
        check(failedHTTPState.refresh.pendingBytes == 500_000_000 && failedHTTPState.refresh.failureCount == 1
              && failedHTTPState.refresh.retryNotBefore.map({ $0 > Date() }) == true && !failedHTTPState.refresh.authenticationRequired,
              "provider JSON error preserves accumulated activity and applies retry backoff without an authentication guess")
        check(failedHTTPState.message != nil && failedHTTPState.message?.contains("fixture-only-provider-detail") == false,
              "untrusted provider error message is not exposed in the saved user-facing error")
        let httpPersisted = try String(contentsOf: httpModelDirectory.appendingPathComponent("provider-usage.json"), encoding: .utf8)
        let persistedHTTPDocument = try ProviderUsageStore(url: httpModelDirectory.appendingPathComponent("provider-usage.json")).load()
        check(persistedHTTPDocument.states[first.id]?.snapshot == acceptedHTTPState.snapshot
              && !httpPersisted.contains("fixture-http-saved-key") && !httpPersisted.contains("fixture-only-provider-detail"),
              "HTTP failure persists the last valid quota without credentials or raw provider messages")
        check(!(await httpModel.save(first, secret: "fixture-http-rejected-replacement")), "provider JSON failure cannot replace an existing API connection")
        let httpCredentialCount = await httpCredentials.count
        check(acceptedHTTPCredential != nil && httpModel.sources.first(where: { $0.id == first.id })?.credentialID == acceptedHTTPCredential
              && httpCredentialCount == 1, "failed HTTP revalidation preserves the original credential")
        try await httpModel.prepareForQuit()

        for (status, expected) in [(401, ProviderUsageFailure.authentication), (403, .authentication), (429, .rateLimited(retryAfter: 3600)), (503, .server(503))] {
            FixtureHTTPProtocol.state.set(status, headers: ["Retry-After": "3600"])
            do { _ = try await httpClient.fetch(configuration: first, secret: "fixture-http-key"); check(false, "HTTP failure rejects") }
            catch { check(error as? ProviderUsageFailure == expected, "HTTP \(status) maps to safe query state") }
        }
        FixtureHTTPProtocol.state.set(200, headers: ["Content-Length": "1048577"])
        do { _ = try await httpClient.fetch(configuration: first, secret: "fixture-http-key"); check(false, "oversized HTTP response rejects") }
        catch { check(error as? ProviderUsageFailure == .invalidResponse, "HTTP response allocation is bounded before body read") }
        print("Provider usage checks: \(checks - failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
