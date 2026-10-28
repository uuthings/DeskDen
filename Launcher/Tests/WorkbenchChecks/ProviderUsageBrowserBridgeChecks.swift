import Foundation
import LauncherCore
#if canImport(Darwin)
import Darwin
#endif

@main
struct ProviderUsageBrowserBridgeChecks {
    @MainActor
    static func main() async throws {
        if ProviderUsageBrowserHost.runIfRequested(arguments: CommandLine.arguments) { return }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("deskden-browser-check-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw NSError(domain: "BrowserBridgeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }; count += 1
        }
        func rejects(_ message: String, _ body: () throws -> Void) throws {
            do { try body() } catch { count += 1; return }; throw NSError(domain: "BrowserBridgeChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let now = Date(), sourceID = UUID()
        let request = ProviderUsageBrowserRequestMessage(sourceID: sourceID, orderID: "123", at: now)
        let result = ProviderUsageBrowserResultMessage(request: request, status: .success, observedAt: now, documentID: "fixture-document", generation: UUID(), gbLimit: 100, gbUsed: 1, gbBalance: 99, resetDateText: "2026-11-25")
        try check(result.isValid(for: request, at: now), "valid quota")
        var invalid = result; invalid.sourceID = UUID(); try check(!invalid.isValid(for: request, at: now), "source isolation")
        invalid = result; invalid.gbBalance = 98; try check(!invalid.isValid(for: request, at: now), "quota invariant")
        invalid = result; invalid.gbUsed = .infinity; try check(!invalid.isValid(for: request, at: now), "finite values")
        invalid = result; invalid.gbLimit = 10_000_000; try check(!invalid.isValid(for: request, at: now), "bounded values")
        invalid = result; invalid.observedAt = now.timeIntervalSince1970 - 60; try check(!invalid.isValid(for: request, at: now), "request time boundary")
        invalid = result; invalid.resetDateText = "2026-02-30"; try check(!invalid.isValid(for: request, at: now), "calendar validation")
        invalid = result; invalid.status = .authentication; try check(!invalid.isValid(for: request, at: now), "errors carry no quota")
        var limited = ProviderUsageBrowserResultMessage(request: request, status: .rateLimited, observedAt: now, retryAfterSeconds: 120)
        try check(limited.isValid(for: request, at: now), "rate limit payload")
        limited.retryAfterSeconds = 604_801; try check(!limited.hasValidPayload, "rate limit upper bound")
        limited.retryAfterSeconds = -1; try check(!limited.hasValidPayload, "rate limit lower bound")
        try rejects("unknown field") { _ = try ProviderUsageBrowserJSON.decodeRequest(Data(#"{"version":1,"requestID":"00000000-0000-4000-8000-000000000001","sourceID":"00000000-0000-4000-8000-000000000002","orderID":"123","createdAt":1,"expiresAt":2,"token":"not-a-real-token"}"#.utf8)) }
        try rejects("size limit") { try ProviderUsageBrowserJSON.keys(Data(repeating: 32, count: 16_385), allowed: []) }
        let directory = root.appendingPathComponent("mailbox"), mailbox = ProviderUsageBrowserMailbox(directory: directory)
        try mailbox.enqueue(request, at: now)
        try check(try mailbox.requests(at: now) == [request], "request persists")
        let mode = try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        try check(mode?.intValue == 0o700, "private directory")
        let requestPath = directory.appendingPathComponent(request.requestID.uuidString + ".request.json")
        let fileMode = try fm.attributesOfItem(atPath: requestPath.path)[.posixPermissions] as? NSNumber
        try check(fileMode?.intValue == 0o600, "private file")
        try mailbox.heartbeat(at: now); try check(mailbox.isConnected(at: now), "live heartbeat")
        try check(!mailbox.isConnected(at: now.addingTimeInterval(21)), "stale heartbeat")
        try mailbox.accept(result, at: now)
        try check(try mailbox.result(for: request, at: now) == result, "result persists")
        try check(try mailbox.requests(at: now).isEmpty, "completed request not reoffered")
        try mailbox.finish(request.requestID)
        try check(try mailbox.result(for: request, at: now) == nil, "cleanup")
        try check(try !mailbox.accept(result, at: now), "cancelled response safely ignored")
        invalid = result; invalid.gbBalance = 0
        try rejects("malformed cancelled reply still rejected") { _ = try mailbox.accept(invalid, at: now) }
        let expired = ProviderUsageBrowserRequestMessage(sourceID: sourceID, orderID: "123", at: now, lifetime: 1)
        try mailbox.enqueue(expired, at: now)
        try check(try !mailbox.accept(.init(request: expired, status: .unavailable, observedAt: now.addingTimeInterval(2)), at: now.addingTimeInterval(2)), "expired response safely ignored")
        try mailbox.enqueue(request, at: now)
        try check(try mailbox.requests(at: now.addingTimeInterval(181)).isEmpty, "expiry cleanup")
        let symlink = root.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: directory)
        try rejects("symlink mailbox") { try ProviderUsageBrowserMailbox(directory: symlink).heartbeat() }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try rejects("public mailbox") { try mailbox.heartbeat() }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try mailbox.enqueue(request, at: now)
        try fm.removeItem(at: requestPath)
        let outside = root.appendingPathComponent("unrelated.json"); try Data("private fixture".utf8).write(to: outside)
        try fm.createSymbolicLink(at: requestPath, withDestinationURL: outside)
        try rejects("symlink request") { _ = try mailbox.requests(at: now) }
        try fm.removeItem(at: requestPath)
        let queue = ProviderUsageBrowserMailbox(directory: root.appendingPathComponent("queue"))
        for _ in 0..<16 { try queue.enqueue(.init(sourceID: sourceID, orderID: "123", at: now), at: now) }
        try rejects("bounded queue") { try queue.enqueue(request, at: now) }
        let nativeBox = ProviderUsageBrowserMailbox(directory: root.appendingPathComponent("native"))
        try nativeBox.enqueue(request, at: now)
        let response = try ProviderUsageBrowserNativeProtocol.handle(Data(#"{"version":1,"type":"poll"}"#.utf8), mailbox: nativeBox, at: now)
        let decoded = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        try check(decoded["type"] as? String == "request", "native poll")
        var envelope = ["version": 1, "type": "result"] as [String: Any]
        envelope["result"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
        _ = try ProviderUsageBrowserNativeProtocol.handle(JSONSerialization.data(withJSONObject: envelope), mailbox: nativeBox, at: now)
        try check(try nativeBox.result(for: request, at: now) == result, "native result")
        try rejects("boolean version") { _ = try ProviderUsageBrowserNativeProtocol.handle(Data(#"{"version":true,"type":"poll"}"#.utf8), mailbox: nativeBox, at: now) }
        try rejects("extra envelope key") { _ = try ProviderUsageBrowserNativeProtocol.handle(Data(#"{"version":1,"type":"poll","token":"fixture"}"#.utf8), mailbox: nativeBox, at: now) }
        let bridgeDirectory = root.appendingPathComponent("app"), appBox = ProviderUsageBrowserMailbox(directory: bridgeDirectory)
        try appBox.heartbeat()
        let config = ProviderUsageConfiguration(kind: .iproyal, name: "Fixture", resourceID: "123")
        let bridge = ProviderUsageBrowserBridge(directory: bridgeDirectory)
        let task = Task { try await bridge.request(configuration: config) }
        try await Task.sleep(for: .milliseconds(50))
        let pending = try appBox.requests().first!
        try appBox.accept(.init(request: pending, status: .success, observedAt: Date(), documentID: "fixture", generation: UUID(), gbLimit: 100, gbUsed: 1, gbBalance: 99, resetDateText: "2026-11-25"))
        let snapshot = try await task.value
        try check(snapshot.remainingBytes == 99_000_000_000, "decimal GB conversion")
        try check(snapshot.sourceID == config.id && snapshot.resetDateText == "2026-11-25" && snapshot.resetsAt == nil, "order identity and date fidelity")
        try check(try appBox.requests().isEmpty, "app cleanup")
        let disconnected = ProviderUsageBrowserBridge(directory: root.appendingPathComponent("disconnected"))
        do { _ = try await disconnected.request(configuration: config); throw NSError(domain: "ExpectedUnavailable", code: 1) }
        catch ProviderUsageFailure.unavailable { count += 1 }
        let cancel = Task { try await bridge.request(configuration: config) }
        try await Task.sleep(for: .milliseconds(50)); cancel.cancel()
        do { _ = try await cancel.value; throw NSError(domain: "ExpectedCancellation", code: 1) }
        catch is CancellationError { count += 1 }
        try check(try appBox.requests().isEmpty, "cancel cleanup")
        let rateTask = Task { try await bridge.request(configuration: config) }
        try await Task.sleep(for: .milliseconds(50))
        let rateRequest = try appBox.requests().first!
        try appBox.accept(.init(request: rateRequest, status: .rateLimited, observedAt: Date(), retryAfterSeconds: 120))
        do { _ = try await rateTask.value; throw NSError(domain: "ExpectedRateLimit", code: 1) }
        catch ProviderUsageFailure.rateLimited(let seconds) { try check(seconds == 120, "Retry-After reaches App scheduler") }
        let resolved = ProviderUsageBrowserHost.defaultBridgeDirectory(environment: ["DESKDEN_DATA_DIRECTORY": root.path])
        try check(resolved.path == root.appendingPathComponent("Workbench/ProviderUsage/BrowserBridge").path, "isolated data directory")
        print("Provider browser bridge: \(count) checks passed")
    }
}
