import Foundation
import LauncherCore

@main struct APIBalanceModelChecks {
    @MainActor static func main() async {
        var count = 0, failures = 0
        func check(_ value: Bool, _ name: String) { count += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") \(name)") }
        func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-api-balance-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let now = Date(), id = UUID()
            let cny = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.01","granted_balance":"10.00","topped_up_balance":"100.01"}]}"#
            let snapshot = try APIBalanceClient.decode(Data(cny.utf8), sourceID: id, now: now)
            check(snapshot.balances.first?.total == Decimal(string: "110.01") && snapshot.balances.first?.formattedTotal == "CNY 110.01", "provider currency amounts retain exact decimal precision and unit")
            let zero = cny.replacingOccurrences(of: "110.01", with: "0.00").replacingOccurrences(of: "10.00", with: "0.00").replacingOccurrences(of: "100.01", with: "0.00").replacingOccurrences(of: "true", with: "false")
            check(try APIBalanceClient.decode(Data(zero.utf8), sourceID: id, now: now).isAvailable == false, "an insufficient balance is a successful real reading, not a connection error")
            check(rejects { _ = try APIBalanceClient.decode(Data(cny.replacingOccurrences(of: "110.01", with: "111.01").utf8), sourceID: id) }, "inconsistent total and component amounts are rejected")
            check(rejects { _ = try APIBalanceClient.decode(Data(cny.replacingOccurrences(of: "CNY", with: "BTC").utf8), sourceID: id) }, "unrecognized currency cannot receive an invented monetary unit")
            check(rejects { _ = try APIBalanceClient.decode(Data(#"{"is_available":true,"balance_infos":[]}"#.utf8), sourceID: id) }, "an empty currency list stays unavailable instead of becoming zero")
            let usd = APIBalanceAmount(currency: "USD", totalBalance: "0.100000000001", grantedBalance: "0.100000000000", toppedUpBalance: "0.000000000001")
            try usd.validate(); check(usd.total == Decimal(string: "0.100000000001"), "small fractional balances do not round through a binary Double")
            let config = APIBalanceConfiguration(id: id, name: "Fixture")
            let request = try APIBalanceClient.request(configuration: config, secret: "not-a-real-key")
            check(request.url?.absoluteString == "https://api.deepseek.com/user/balance" && request.httpMethod == "GET" && request.httpBody == nil,
                  "the client permits only the fixed official read endpoint")
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer not-a-real-key" && request.url?.query == nil,
                  "the key is carried only in the authorization header")
            check(rejects { _ = try APIBalanceClient.request(configuration: config, secret: "key\r\ninvalid") }, "control characters cannot be injected into authorization")
            check(APIBalanceClient.retryAfter("120") == 120 && APIBalanceClient.retryAfter("Infinity") == nil && APIBalanceClient.retryAfter("999999") == 86400, "retry delays stay finite and bounded")
            let client = BalanceFixtureClient(), keys = BalanceFixtureCredentials()
            var clock = now
            let model = APIBalanceModel(dataDirectory: directory, startServices: false, client: client, credentials: keys, now: { clock })
            let initialRequests = await client.requestCount()
            check(model.sources.isEmpty && initialRequests == 0, "a fresh model performs no speculative API query")
            let added = try await model.validateAndSave(name: "DeepSeek fixture", key: "not-a-real-key")
            check(model.sources == [added] && model.state(for: added.id).snapshot != nil && added.credentialID != nil, "adding a connection validates before publishing its source and first balance")
            let file = directory.appendingPathComponent("api-balances.json"), bytes = try Data(contentsOf: file)
            let storedKeyCount = await keys.count()
            check(!String(decoding: bytes, as: UTF8.self).contains("not-a-real-key") && storedKeyCount == 1, "only an opaque credential reference is persisted; the secret stays in its credential store")
            check((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "stored API metadata remains user-private")
            let countBeforeRename = await client.requestCount()
            let renamed = try await model.validateAndSave(name: "Renamed fixture", key: "", editingID: added.id)
            let countAfterRename = await client.requestCount()
            check(renamed.id == added.id && renamed.credentialID == added.credentialID && countAfterRename == countBeforeRename, "a metadata-only rename retains identity and key without claiming another verification")
            let last = model.state(for: added.id).snapshot
            await client.setFailure(.authentication)
            await model.refresh(id: added.id)
            check(model.state(for: added.id).snapshot == last && model.state(for: added.id).authenticationFailed, "authentication failure preserves the last balance and its original timestamp")
            let beforeRejectedKey = try Data(contentsOf: file)
            do { _ = try await model.validateAndSave(name: "Must not save", key: "not-another-real-key", editingID: added.id); check(false, "a rejected replacement key cannot change metadata") }
            catch { let unchangedKeyCount = await keys.count(); check(try Data(contentsOf: file) == beforeRejectedKey && unchangedKeyCount == 1, "a rejected replacement key preserves the old key and metadata") }
            await client.setFailure(nil)
            let replaced = try await model.validateAndSave(name: "Verified replacement", key: "not-a-replacement-key", editingID: added.id)
            check(replaced.credentialID != added.credentialID && model.state(for: added.id).message == nil, "explicit replacement recovers authentication without waiting through a transport backoff")
            let beforeLimited = model.state(for: added.id).snapshot
            await client.setFailure(.rateLimited(120)); await model.refresh(id: added.id)
            let limitedRequests = await client.requestCount()
            check(model.state(for: added.id).snapshot == beforeLimited && model.state(for: added.id).rateLimitUntil == clock.addingTimeInterval(120), "rate limits preserve the previous balance and remember the provider retry time")
            await model.refresh(id: added.id)
            let blockedRequests = await client.requestCount()
            check(blockedRequests == limitedRequests, "a repeated manual refresh honors an active provider rate limit")
            clock = clock.addingTimeInterval(121); await client.setFailure(nil); await model.refresh(id: added.id)
            check(model.state(for: added.id).message == nil && model.state(for: added.id).rateLimitUntil == nil, "a successful refresh after the retry time clears the failed state")
            try await model.prepareForQuit(); model.resumeAfterCancelledQuit()
            check(await keys.count() == 1, "replacement cleanup leaves only its active credential")
            let restored = APIBalanceModel(dataDirectory: directory, startServices: false, client: client, credentials: keys)
            check(restored.sources == model.sources && restored.state(for: added.id).snapshot == model.state(for: added.id).snapshot, "source and cached currency balances survive recreation")
            try model.remove(id: added.id); try await model.prepareForQuit()
            let remainingKeys = await keys.count()
            check(model.sources.isEmpty && remainingKeys == 0, "removing a confirmed source also cleans up its own credential")
            let corrupt = directory.appendingPathComponent("Corrupt"); try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
            let bad = corrupt.appendingPathComponent("api-balances.json"), invalidBytes = Data("invalid balance file".utf8)
            try invalidBytes.write(to: bad)
            let protected = APIBalanceModel(dataDirectory: corrupt, startServices: false, client: client, credentials: keys)
            let protectedCount = await client.requestCount()
            do { _ = try await protected.validateAndSave(name: "Protected", key: "not-a-real-key"); check(false, "corrupt storage blocks save") }
            catch { let protectedBytes = try Data(contentsOf: bad); let protectedRequests = await client.requestCount(); check(protected.storageError != nil && protectedBytes == invalidBytes && protectedRequests == protectedCount, "corrupt storage preserves its original bytes and prevents validation requests") }
            let linked = directory.appendingPathComponent("Linked")
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: corrupt)
            check(rejects { _ = try APIBalanceStore(url: linked.appendingPathComponent("api-balances.json")).load() }, "symlinked storage cannot redirect API metadata writes")
            model.shutdown(); restored.shutdown(); protected.shutdown()
        } catch { check(false, "API balance fixture: \(error.localizedDescription)") }
        print("API balance model checks: \(count - failures)/\(count) passed")
        exit(failures == 0 && count > 0 ? 0 : 1)
    }
}
actor BalanceFixtureCredentials: APIBalanceCredentialStoring {
    private var values: [UUID: String] = [:]
    func read(id: UUID) -> String? { values[id] }
    func write(_ secret: String, id: UUID) { values[id] = secret }
    func remove(id: UUID) { values[id] = nil }
    func count() -> Int { values.count }
}
actor BalanceFixtureClient: APIBalanceQuerying {
    private var failure: APIBalanceFailure?
    private var requests = 0
    func requestCount() -> Int { requests }
    func setFailure(_ failure: APIBalanceFailure?) { self.failure = failure }
    func fetch(configuration: APIBalanceConfiguration, secret: String) throws -> APIBalanceSnapshot {
        requests += 1
        if let failure { throw failure }
        return .init(sourceID: configuration.id, isAvailable: true, balances: [.init(currency: "CNY", totalBalance: "12.30", grantedBalance: "2.00", toppedUpBalance: "10.30")])
    }
}
