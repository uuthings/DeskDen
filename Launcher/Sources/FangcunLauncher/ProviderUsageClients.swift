import Foundation
import LauncherCore

protocol ProviderUsageQuerying: Sendable {
    func fetch(configuration: ProviderUsageConfiguration, secret: String) async throws -> ProviderUsageSnapshot
}

/// API queries are restricted to one read-only KiWi operation. Credentials never enter a URL.
struct ProviderUsageAPIClient: ProviderUsageQuerying {
    let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil; configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration, delegate: ProviderUsageNoRedirects(), delegateQueue: nil)
        }
    }
    static func request(configuration: ProviderUsageConfiguration, secret: String) throws -> URLRequest {
        try configuration.validate()
        guard configuration.kind == .bandwagon, !secret.isEmpty, secret.utf8.count <= 4096,
              !secret.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ProviderUsageFailure.invalidConfiguration }
        var request = URLRequest(url: URL(string: "https://api.64clouds.com/v1/getServiceInfo")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let key = secret.addingPercentEncoding(withAllowedCharacters: allowed)!
        request.httpBody = Data("veid=\(configuration.resourceID)&api_key=\(key)".utf8)
        request.timeoutInterval = 25
        return request
    }
    func fetch(configuration: ProviderUsageConfiguration, secret: String) async throws -> ProviderUsageSnapshot {
        let request = try Self.request(configuration: configuration, secret: secret)
        do {
            // Stream into a bounded buffer rather than allocating an unbounded response body.
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ProviderUsageFailure.invalidResponse }
            if response.statusCode == 401 || response.statusCode == 403 { throw ProviderUsageFailure.authentication }
            if response.statusCode == 429 { throw ProviderUsageFailure.rateLimited(retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: Date())) }
            guard response.statusCode == 200 else { throw ProviderUsageFailure.server(response.statusCode) }
            guard response.expectedContentLength <= 1_048_576 else { throw ProviderUsageFailure.invalidResponse }
            var data = Data(); data.reserveCapacity(4096)
            for try await byte in stream {
                guard data.count < 1_048_576 else { throw ProviderUsageFailure.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try Self.decodeBandwagon(data, sourceID: configuration.id, now: Date())
        } catch let error as ProviderUsageFailure { throw error }
        catch is CancellationError { throw ProviderUsageFailure.cancelled }
        catch let error as URLError where error.code == .cancelled { throw ProviderUsageFailure.cancelled }
        catch { throw ProviderUsageFailure.transport }
    }
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
    static func decodeBandwagon(_ data: Data, sourceID: UUID, now: Date) throws -> ProviderUsageSnapshot {
        struct Envelope: Decodable { let error: Int }
        struct Reading: Decodable {
            let plan_monthly_data: UInt64
            let data_counter: UInt64
            let monthly_data_multiplier: Double
            let data_next_reset: Double
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.error == 0 else {
                // Preserve the documented error != 0 contract without guessing undocumented error-code semantics.
                throw ProviderUsageFailure.server(envelope.error)
            }
            let reading = try JSONDecoder().decode(Reading.self, from: data)
            let multiplier = reading.monthly_data_multiplier
            guard multiplier.isFinite, multiplier > 0, multiplier <= 1000 else { throw ProviderUsageFailure.invalidResponse }
            func scale(_ raw: UInt64) throws -> UInt64 {
                let value = Double(raw) * multiplier
                guard value.isFinite, value >= 0, value <= Double(ProviderUsageSnapshot.maximumBytes) else { throw ProviderUsageFailure.invalidResponse }
                return UInt64(value.rounded())
            }
            let snapshot = ProviderUsageSnapshot(sourceID: sourceID, observedAt: now,
                usedBytes: try scale(reading.data_counter), limitBytes: try scale(reading.plan_monthly_data),
                resetsAt: Date(timeIntervalSince1970: reading.data_next_reset), displayUnit: .binaryGB,
                sourceDescription: "搬瓦工 KiWi API")
            try snapshot.validate(now: now); return snapshot
        } catch let error as ProviderUsageFailure { throw error }
        catch { throw ProviderUsageFailure.invalidResponse }
    }
}

private final class ProviderUsageNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
