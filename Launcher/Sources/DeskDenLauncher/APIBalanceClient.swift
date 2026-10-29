import Foundation
import Security
import LauncherCore

protocol APIBalanceQuerying: Sendable {
    func fetch(configuration: APIBalanceConfiguration, secret: String) async throws -> APIBalanceSnapshot
}
protocol APIBalanceCredentialStoring: Sendable {
    func read(id: UUID) async throws -> String?
    func write(_ secret: String, id: UUID) async throws
    func remove(id: UUID) async throws
}
actor APIBalanceKeychain: APIBalanceCredentialStoring {
    private let service = "local.deskden.launcher.api-balance.v1"
    private func query(_ id: UUID, service: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service ?? self.service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    func read(id: UUID) throws -> String? {
        try LegacyIdentityMigration.readCredential(current:{try read(id:id,service:service)},
            legacyDisabled:{try legacyIsDeleted(id:id)}, legacy:{try read(id:id,service:"local.fangcun.launcher.api-balance.v1")})
    }
    private func read(id: UUID, service: String) throws -> String? {
        var request = query(id,service:service); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw APIBalanceFailure.credentials }
        return value
    }
    func write(_ secret: String, id: UUID) throws {
        guard APIBalanceClient.validSecret(secret) else { throw APIBalanceFailure.credentials }
        var request = query(id); request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        request[kSecAttrLabel as String] = "方寸 DeepSeek API 余额"
        request[kSecValueData as String] = Data(secret.utf8)
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw APIBalanceFailure.credentials }
    }
    private func legacyIsDeleted(id: UUID) throws -> Bool {
        var request = query(id,service:service + ".legacy-deleted")
        request[kSecReturnAttributes as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary,nil)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIBalanceFailure.credentials }
        return status == errSecSuccess
    }
    func remove(id: UUID) throws {
        try LegacyIdentityMigration.deleteCredential(markLegacyDeleted:{
            // This non-secret marker belongs to the new identity. Keep the old
            // credential untouched while preventing fallback after deletion.
            var marker = query(id,service:service + ".legacy-deleted")
            marker[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            marker[kSecValueData as String] = Data([1])
            let status = SecItemAdd(marker as CFDictionary,nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else { throw APIBalanceFailure.credentials }
        },deleteCurrent:{
            let status = SecItemDelete(query(id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw APIBalanceFailure.credentials }
        })
    }
}
/// Only the documented read endpoint is allowed. No cookies, cache, URL keys,
/// redirects, model calls, top-ups or account-modifying endpoints are used.
struct APIBalanceClient: APIBalanceQuerying {
    let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil; configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 25
            self.session = URLSession(configuration: configuration, delegate: APIBalanceNoRedirects(), delegateQueue: nil)
        }
    }
    static func validSecret(_ secret: String) -> Bool {
        !secret.isEmpty && secret.utf8.count <= 4096 && !secret.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains)
    }
    static func request(configuration: APIBalanceConfiguration, secret: String) throws -> URLRequest {
        try configuration.validate()
        guard configuration.provider == .deepseek, validSecret(secret) else { throw APIBalanceFailure.invalidConfiguration }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"; request.timeoutInterval = 20
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    func fetch(configuration: APIBalanceConfiguration, secret: String) async throws -> APIBalanceSnapshot {
        do {
            let (stream, response) = try await session.bytes(for: Self.request(configuration: configuration, secret: secret))
            guard let response = response as? HTTPURLResponse, response.url?.host == "api.deepseek.com", response.url?.path == "/user/balance" else { throw APIBalanceFailure.invalidResponse }
            switch response.statusCode {
            case 200: break
            case 401, 403: throw APIBalanceFailure.authentication
            case 429: throw APIBalanceFailure.rateLimited(Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
            default: throw APIBalanceFailure.server(response.statusCode)
            }
            guard response.expectedContentLength <= 65_536 else { throw APIBalanceFailure.invalidResponse }
            var data = Data()
            for try await byte in stream { guard data.count < 65_536 else { throw APIBalanceFailure.invalidResponse }; data.append(byte) }
            try Task.checkCancellation()
            return try Self.decode(data, sourceID: configuration.id)
        } catch let error as APIBalanceFailure { throw error }
        catch is CancellationError { throw APIBalanceFailure.cancelled }
        catch let error as URLError where error.code == .cancelled { throw APIBalanceFailure.cancelled }
        catch { throw APIBalanceFailure.transport }
    }
    static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value, let amount = Double(value), amount.isFinite else { return nil }
        return min(86_400, max(0, amount))
    }
    static func decode(_ data: Data, sourceID: UUID, now: Date = Date()) throws -> APIBalanceSnapshot {
        struct Reply: Decodable {
            struct Balance: Decodable { let currency, total_balance, granted_balance, topped_up_balance: String }
            let is_available: Bool
            let balance_infos: [Balance]
        }
        do {
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            let snapshot = APIBalanceSnapshot(sourceID: sourceID, observedAt: now, isAvailable: reply.is_available,
                balances: reply.balance_infos.map { .init(currency: $0.currency, totalBalance: $0.total_balance, grantedBalance: $0.granted_balance, toppedUpBalance: $0.topped_up_balance) })
            try snapshot.validate(now: now); return snapshot
        } catch { throw APIBalanceFailure.invalidResponse }
    }
}
private final class APIBalanceNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
