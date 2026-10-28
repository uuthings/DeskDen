import Foundation
import LauncherCore

@MainActor
final class ProviderUsageBrowserBridge {
    let directory: URL
    private let mailbox: ProviderUsageBrowserMailbox
    init(directory: URL) { self.directory = directory; mailbox = .init(directory: directory) }
    var isConnected: Bool { mailbox.isConnected() }

    func request(configuration: ProviderUsageConfiguration) async throws -> ProviderUsageSnapshot {
        try configuration.validate()
        guard configuration.kind == .iproyal else { throw ProviderUsageFailure.invalidConfiguration }
        guard mailbox.isConnected() else {
            throw ProviderUsageFailure.unavailable("请安装并启用 Chrome 的 DeskDen IPRoyal Connector，然后保持 Chrome 运行。")
        }
        let request = ProviderUsageBrowserRequestMessage(sourceID: configuration.id, orderID: configuration.resourceID, at: Date())
        do { try mailbox.enqueue(request) } catch { throw ProviderUsageFailure.unavailable("浏览器连接暂时繁忙或本机连接目录不可用。") }
        defer { try? mailbox.finish(request.requestID) }
        while Date().timeIntervalSince1970 < request.expiresAt {
            try Task.checkCancellation()
            if let result = try mailbox.result(for: request) {
                switch result.status {
                case .authentication: throw ProviderUsageFailure.authentication
                case .rateLimited: throw ProviderUsageFailure.rateLimited(retryAfter: result.retryAfterSeconds)
                case .unavailable, .timeout:
                    throw ProviderUsageFailure.unavailable("未收到 IPRoyal 订单额度。请在 Chrome 确认已登录，并检查订单编号。")
                case .invalidResponse: throw ProviderUsageFailure.invalidResponse
                case .success:
                    guard let limit = result.gbLimit, let used = result.gbUsed, let balance = result.gbBalance else { throw ProviderUsageFailure.invalidResponse }
                    let snapshot = ProviderUsageSnapshot(sourceID: configuration.id, observedAt: Date(timeIntervalSince1970: result.observedAt),
                        usedBytes: UInt64((used * 1_000_000_000).rounded()), limitBytes: UInt64((limit * 1_000_000_000).rounded()),
                        remainingBytes: UInt64((balance * 1_000_000_000).rounded()), resetDateText: result.resetDateText,
                        displayUnit: .decimalGB, sourceDescription: "IPRoyal 控制台 · Chrome 网页助手")
                    try snapshot.validate(); return snapshot
                }
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw ProviderUsageFailure.unavailable("浏览器连接响应超时，已保留原有额度。请检查网页助手与登录状态。")
    }

    static var templateURL: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("BrowserConnectors/IPRoyal", isDirectory: true)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) ? $0 : nil }
    }

    /// Prepare a reviewable local kit. Exporting does not register a host or install an extension.
    @discardableResult
    static func exportConnectionKit(to directory: URL, applicationURL: URL, bridgeDirectory: URL) throws -> URL {
        guard let templateURL else { throw ProviderUsageFailure.unavailable("当前构建未包含网页助手资源。") }
        let manager = FileManager.default
        let target = directory.appendingPathComponent("DeskDen-IPRoyal-Connector", isDirectory: true)
        guard !manager.fileExists(atPath: target.path), let bundle = Bundle(url: applicationURL), let executable = bundle.executableURL,
              manager.isExecutableFile(atPath: executable.path), directory.isFileURL, bridgeDirectory.isFileURL else {
            throw ProviderUsageFailure.unavailable("请选择新目录，并使用完整的方寸 App 导出连接包。")
        }
        try manager.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let extensionDirectory = target.appendingPathComponent("Extension", isDirectory: true)
            try manager.createDirectory(at: extensionDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let files = ["manifest.json", "protocol.js", "protocol-isolated.js", "observer.js", "content.js", "background.js", "popup.html", "popup.css", "popup.js",
                         "icon-16.png", "icon-32.png", "icon-64.png", "icon-128.png"]
            for file in files {
                let source = templateURL.appendingPathComponent(file)
                guard try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                      try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ProviderUsageFailure.storage }
                try manager.copyItem(at: source, to: extensionDirectory.appendingPathComponent(file))
            }
            let wrapper = target.appendingPathComponent("native-host.command")
            let command = "#!/bin/sh\nexec " + shellQuote(executable.path) + " --provider-usage-browser-host --provider-usage-browser-directory " + shellQuote(bridgeDirectory.path) + " \"$@\"\n"
            try writeKit(Data(command.utf8), to: wrapper, permissions: 0o700)
            let manifest: [String: Any] = ["name": ProviderUsageBrowserProtocol.hostName, "description": "DeskDen IPRoyal Connector",
                "path": wrapper.path, "type": "stdio", "allowed_origins": [ProviderUsageBrowserProtocol.extensionOrigin]]
            try writeKit(JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
                         to: target.appendingPathComponent(ProviderUsageBrowserProtocol.hostName + ".json"), permissions: 0o600)
            for file in ["install.command", "README.md"] {
                try manager.copyItem(at: templateURL.appendingPathComponent(file), to: target.appendingPathComponent(file))
                try manager.setAttributes([.posixPermissions: file.hasSuffix(".command") ? 0o700 : 0o600], ofItemAtPath: target.appendingPathComponent(file).path)
            }
            return target
        } catch {
            // Only this newly created kit is rolled back; an existing directory is never overwritten.
            try? manager.removeItem(at: target); throw error
        }
    }
    private static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func writeKit(_ data: Data, to url: URL, permissions: Int) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}

/// Must run before NSApplication is initialized or singleton-window handling takes place.
enum ProviderUsageBrowserHost {
    static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.contains("--provider-usage-browser-host") else { return false }
        let origins = arguments.filter { $0.hasPrefix("chrome-extension://") }
        guard origins == [ProviderUsageBrowserProtocol.extensionOrigin] else { return true }
        let directory: URL
        if let position = arguments.firstIndex(of: "--provider-usage-browser-directory") {
            guard position + 1 < arguments.count, arguments[position + 1].hasPrefix("/") else { return true }
            directory = URL(fileURLWithPath: arguments[position + 1], isDirectory: true)
        } else { directory = defaultBridgeDirectory() }
        let mailbox = ProviderUsageBrowserMailbox(directory: directory)
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        do {
            while let prefix = try readExactly(input, count: 4) {
                let length = prefix.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
                guard length > 0, length <= ProviderUsageBrowserProtocol.maximumMessageBytes,
                      let body = try readExactly(input, count: length) else { break }
                let response = try ProviderUsageBrowserNativeProtocol.handle(body, mailbox: mailbox)
                var size = UInt32(response.count).littleEndian
                try output.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) })
                try output.write(contentsOf: response)
            }
        } catch { /* Never emit raw JSON, paths, or site data to stdout/stderr. */ }
        return true
    }
    static func defaultBridgeDirectory(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let requested = bundle.object(forInfoDictionaryKey: "DeskDenDeviceAcceptanceProfile") as? String ?? "DeviceStatus"
        let profile = requested.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil ? "DeviceStatus" : requested
        let test = bundle.object(forInfoDictionaryKey: "DeskDenDeviceAcceptance") as? Bool == true
            ? support.appendingPathComponent("DeskDen/TestProfiles/" + profile, isDirectory: true) : nil
        let review: URL? = bundle.object(forInfoDictionaryKey: "DeskDenUIReview") as? Bool == true
            ? (bundle.object(forInfoDictionaryKey: "DeskDenUIReviewDataDirectory") as? String).map { URL(fileURLWithPath: $0) }
                ?? support.appendingPathComponent("DeskDen/UIReview/" + (bundle.bundleIdentifier ?? "local-review"), isDirectory: true) : nil
        let base = review ?? environment["DESKDEN_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? test ?? support.appendingPathComponent("DeskDen/Launcher", isDirectory: true)
        return base.appendingPathComponent("Workbench/ProviderUsage/BrowserBridge", isDirectory: true)
    }
    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty else {
                if data.isEmpty { return nil }; throw ProviderUsageBrowserProtocolError.invalidMessage
            }
            data.append(next)
        }
        return data
    }
}
