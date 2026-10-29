import AppKit
import CryptoKit
import Combine
import Foundation
import LauncherCore
import UniformTypeIdentifiers
import UserNotifications

struct AIUsageSourceConfiguration: Codable, Sendable, Identifiable {
    var provider: AIProvider
    var enabled = true
    var sessionsPath: String
    var quotaPath: String?
    var manualSnapshot: AIQuotaSnapshot?
    var manualNote: String?
    var declaredPlan: AIAccountPlan?
    var id: String { provider.rawValue }
}

enum AISubscriptionConnectionResult: Equatable, Sendable {
    case ready(message: String)
    case waiting(message: String)
    case authorizationRequired(message: String)
    case failed(message: String)
    var message: String {
        switch self {
        case .ready(let message), .waiting(let message), .authorizationRequired(let message), .failed(let message): message
        }
    }
    var isReady: Bool { if case .ready = self { true } else { false } }
}

/// A short-lived, UI-free mode of the app invoked by Claude Code's official status line.
/// Input may contain other metadata; only the two documented quota windows survive.
enum ClaudeQuotaStatusLineHost {
    static let argument = "--claude-quota-statusline"
    static let maximumInputBytes = 262_144

    static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.dropFirst().first == argument else { return false }
        var text = "额度暂不可用"
        if arguments.count == 4, arguments[2] == "--claude-quota-output", arguments[3].hasPrefix("/") {
            do {
                var input = Data()
                while input.count <= maximumInputBytes {
                    let chunk = try FileHandle.standardInput.read(upToCount: min(8192, maximumInputBytes + 1 - input.count)) ?? Data()
                    if chunk.isEmpty { break }
                    input.append(chunk)
                }
                text = try consume(input, outputURL: URL(fileURLWithPath: arguments[3]))
            } catch { /* Never echo input or local paths into Claude's terminal. */ }
        }
        try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
        return true
    }

    @discardableResult static func consume(_ data: Data, outputURL: URL, now: Date = Date()) throws -> String {
        guard data.count <= maximumInputBytes,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageError.invalid("状态栏数据格式无效。")
        }
        guard let rates = payload["rate_limits"] as? [String: Any],
              let snapshot = AIUsageLogParser.claudeQuota(rates, date: now) else { return "额度暂不可用" }
        try snapshot.validate(now: now)
        try ClaudeQuotaSyncInstaller.validateOutput(outputURL)
        var safeRates: [String: Any] = [:]
        for (key, window) in [("five_hour", snapshot.shortWindow), ("seven_day", snapshot.weeklyWindow)] {
            guard let window else { continue }
            var value: [String: Any] = ["used_percentage": window.usedPercent]
            if let reset = window.resetsAt { value["resets_at"] = reset.timeIntervalSince1970 }
            safeRates[key] = value
        }
        let safe: [String: Any] = ["observedAt": ISO8601DateFormatter().string(from: now), "rate_limits": safeRates]
        try ProtectedAtomicFile.write(JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]), to: outputURL)
        return snapshot.availableWindows.map { "\($0.durationMinutes == 300 ? "5h" : "7d"): \(Int($0.usedPercent.rounded()))%" }.joined(separator: " · ")
    }
}

enum ClaudeQuotaSyncInstaller {
    /// Recognizes only the literal, shell-quoted command emitted by Fangcun.
    /// Shell substitutions, extra commands and third-party scripts cannot match.
    static func ownedCommand(_ command: String, matchingExecutable executableURL: URL) -> Bool {
        var remainder = command[...]
        func quotedPath() -> String? {
            guard remainder.first == "'" else { return nil }
            remainder.removeFirst()
            var path = ""
            while !remainder.isEmpty {
                if remainder.hasPrefix("'\"'\"'") { path.append("'"); remainder.removeFirst(5) }
                else if remainder.first == "'" { remainder.removeFirst(); return path }
                else { path.append(remainder.removeFirst()) }
            }
            return nil
        }
        guard let executable = quotedPath(), executable.hasPrefix("/"),
              URL(fileURLWithPath: executable).lastPathComponent == executableURL.lastPathComponent else { return false }
        let flags = " " + ClaudeQuotaStatusLineHost.argument + " --claude-quota-output "
        guard remainder.hasPrefix(flags) else { return false }
        remainder.removeFirst(flags.count)
        guard let output = quotedPath(), remainder.isEmpty, output.hasPrefix("/") else { return false }
        let destination = URL(fileURLWithPath: output)
        return destination.lastPathComponent == "claude-quota.json" && destination.deletingLastPathComponent().lastPathComponent == "AIUsage"
    }
    struct Receipt {
        let settingsURL: URL
        let originalData: Data?
        let installedData: Data
        func rollback() throws {
            guard try Data(contentsOf: settingsURL) == installedData else { throw AIUsageError.invalid("Claude 设置已被其他程序更改，请检查状态栏配置。") }
            if let originalData { try ProtectedAtomicFile.write(originalData, to: settingsURL) }
            else { try FileManager.default.removeItem(at: settingsURL) }
        }
    }
    private static func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return nil }
    }
    private static func settingsData(_ url: URL) throws -> Data? {
        guard let attributes = try attributesIfPresent(url) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 262_144 else {
            throw AIUsageError.invalid("Claude 设置文件类型或大小不受支持，原设置已保留。")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 262_145) ?? Data()
        guard data.count <= 262_144 else { throw AIUsageError.invalid("Claude 设置文件超过读取上限，原设置已保留。") }
        return data
    }
    private static func validateDirectory(_ url: URL) throws {
        if let attributes = try attributesIfPresent(url), attributes[.type] as? FileAttributeType != .typeDirectory {
            throw AIUsageError.invalid("同步目录应为普通文件夹，不能是符号链接。")
        }
    }
    static func validateOutput(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.lastPathComponent == "claude-quota.json" else { throw AIUsageError.invalid("额度同步文件位置无效。") }
        try validateDirectory(url.deletingLastPathComponent())
        if let attributes = try attributesIfPresent(url), attributes[.type] as? FileAttributeType != .typeRegular {
            throw AIUsageError.invalid("额度同步文件不能是符号链接或文件夹。")
        }
    }
    static func install(settingsDirectory: URL, executableURL: URL, quotaURL: URL) throws -> Receipt {
        let fm = FileManager.default
        try validateDirectory(settingsDirectory); try validateOutput(quotaURL)
        guard executableURL.isFileURL, fm.isExecutableFile(atPath: executableURL.path) else { throw AIUsageError.invalid("方寸程序暂不可用，请从应用程序文件夹重新打开。") }
        let url = settingsDirectory.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        let original = try settingsData(url)
        if let data = original {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIUsageError.invalid("Claude 设置格式无效，原设置已保留。") }
            settings = value
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let command = quote(executableURL.path) + " " + ClaudeQuotaStatusLineHost.argument + " --claude-quota-output " + quote(quotaURL.path)
        if let existing = settings["statusLine"], !(existing is NSNull) {
            guard var status = existing as? [String: Any], status["type"] as? String == "command", let previous = status["command"] as? String,
                  previous == command || ownedCommand(previous, matchingExecutable: executableURL) else {
                throw AIUsageError.invalid("Claude 已有状态栏配置，方寸已保留它。可导出适配器手动合并，或选择已有额度 JSON。")
            }
            status["command"] = command; settings["statusLine"] = status
        } else { settings["statusLine"] = ["type": "command", "command": command] }
        let encoded = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if original != encoded {
            guard try settingsData(url) == original else { throw AIUsageError.invalid("Claude 设置刚被其他程序更改，请重试连接。原设置已保留。") }
            try ProtectedAtomicFile.write(encoded, to: url)
        }
        return Receipt(settingsURL: url, originalData: original, installedData: encoded)
    }
}

enum AIUsageDestination: Equatable {
    case overview, provider(AIProvider), sources, history, prices
}
enum AIUsageDialog: Identifiable, Equatable {
    case alert, manual, claudeConnect, connectionPreview, disconnect(AIProvider), removePrice(String), help
    var id: String {
        switch self { case .alert: "alert"; case .manual: "manual"; case .claudeConnect: "claude-connect"; case .connectionPreview: "connection-preview"; case .disconnect(let provider): "disconnect-" + provider.rawValue; case .removePrice(let id): "remove-price-" + id; case .help: "help" }
    }
}
struct AIManualQuotaDraft: Equatable {
    var provider: AIProvider = .codex
    var shortPercent = "", weeklyPercent = "", note = ""
    var observedAt = Date()
    var shortReset = Date().addingTimeInterval(18_000)
    var weeklyReset = Date().addingTimeInterval(7 * 86_400)
    var specifiesResetTimes = false
}
struct AIPriceEditingDraft: Equatable {
    var provider: AIProvider = .codex
    var model = "", input = "", output = "", cacheRead = "", cacheWrite = ""
}
struct AIUsageConnectionPreview {
    var provider: AIProvider
    var path: String
    var quotaFile: Bool
    var files: Int
    var records: Int
    var windows: [AIQuotaWindow]
    var observedAt: Date?
    var quotaSource: AIQuotaSource?
    var singleImport = false
    var error: String?
    var canConnect: Bool
}
enum AIQuotaNotificationPermission: String {
    case unknown, notDetermined, authorized, denied, unavailable
    var title: String {
        switch self { case .unknown: "正在检查通知权限"; case .notDetermined: "保存并启用时请求通知权限"; case .authorized: "通知已允许"; case .denied: "系统未允许通知"; case .unavailable: "通知服务不可用" }
    }
}
@MainActor protocol AIQuotaNotificationProviding {
    func permission() async -> AIQuotaNotificationPermission
    func requestPermission() async throws -> Bool
    func deliver(_ event: AIQuotaAlertEvent) async throws
}
@MainActor final class AIQuotaNotificationService: AIQuotaNotificationProviding {
    private var center: UNUserNotificationCenter { .current() }
    func permission() async -> AIQuotaNotificationPermission {
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .unavailable
        }
    }
    func requestPermission() async throws -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return try await center.requestAuthorization(options: [.alert, .sound])
    }
    func deliver(_ event: AIQuotaAlertEvent) async throws {
        let content = UNMutableNotificationContent()
        content.title = event.provider.title + (event.level == .critical ? " 额度紧张" : " 额度接近关注阈值")
        content.body = "\(event.window.title)已用 \(Int(event.usedPercent.rounded()))%，达到 \(event.threshold)% 提醒阈值。来源：\(event.source.title)。"
        content.sound = .default; content.threadIdentifier = "deskden-ai-quota"
        content.userInfo = ["deskdenRoute": "ai", "provider": event.provider.rawValue]
        try await center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
    }
}
private struct AIUsageScanResult: Sendable {
    var provider: AIProvider
    var records: [AITokenRecord] = []
    var snapshots: [AIQuotaSnapshot] = []
    var sourceExists = false
    var fileCount = 0
    var skippedFiles = 0
    var capacityLimited = false
    var error: String?
}
private actor AIUsageReader {
    private var cache = AIUsageParseCache()
    private var eligibleKeys = Set<String>()
    func scan(_ configurations: [AIUsageSourceConfiguration], now: Date, includeSessionFiles: Bool = true) -> [AIUsageScanResult] {
        eligibleKeys.removeAll(keepingCapacity: true)
        let results = configurations.map { scan($0, now: now, includeSessionFiles: includeSessionFiles) }
        cache.retain(keys: eligibleKeys, now: now)
        return results
    }
    private func scan(_ config: AIUsageSourceConfiguration, now: Date, includeSessionFiles: Bool) -> AIUsageScanResult {
        var result = AIUsageScanResult(provider: config.provider)
        // Manual/single-import records are explicitly saved data, independent of
        // permission to inspect any automatic session directory or quota file.
        guard config.enabled else {
            if let manual = config.manualSnapshot { result.snapshots = [manual] }
            return result
        }
        let fm = FileManager.default, cutoff = now.addingTimeInterval(-31 * 86_400)
        let root = URL(fileURLWithPath: config.sessionsPath)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        var isDirectory: ObjCBool = false
        if includeSessionFiles, fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue, fm.isReadableFile(atPath: root.path) {
            result.sourceExists = true
            var candidates: [(URL, Date, Int)] = [], examined = 0
            if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in enumerator {
                    if Task.isCancelled { break }
                    examined += 1
                    if examined > 20_000 { result.skippedFiles += 1; break }
                    guard let info = try? url.resourceValues(forKeys: keys) else { continue }
                    if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    guard info.isRegularFile == true, url.pathExtension.lowercased() == "jsonl", let date = info.contentModificationDate, date >= cutoff else { continue }
                    candidates.append((url, date, info.fileSize ?? 0))
                }
            } else { result.error = "无法读取会话目录。请检查文件访问权限，或重新选择数据目录。" }
            candidates.sort { $0.1 > $1.1 }
            var budget = 128 * 1_024 * 1_024
            for (url, modified, size) in candidates.prefix(400) {
                if Task.isCancelled { break }
                guard size > 0, size <= 64 * 1_024 * 1_024, size <= budget else { result.skippedFiles += 1; continue }
                budget -= size
                let key = config.provider.rawValue + ":" + root.standardizedFileURL.path + ":" + url.path
                eligibleKeys.insert(key)
                do {
                    let parsed: AIUsageParsedFile
                    if let cached = cache.value(for: key, size: size, modified: modified, now: now) { parsed = cached }
                    else {
                        parsed = try parseFile(url, provider: config.provider, maximumBytes: size, now: now)
                        cache.insert(parsed, for: key, size: size, modified: modified, now: now)
                    }
                    result.records += parsed.records; result.snapshots += parsed.snapshots; result.fileCount += 1
                    result.capacityLimited = result.capacityLimited || parsed.capacityLimited
                    if result.records.count > AITokenLedger.maximumRecords {
                        result.records = AIUsageAggregation.deduplicate(result.records)
                        if result.records.count > AITokenLedger.maximumRecords {
                            result.records = Array(result.records.suffix(AITokenLedger.maximumRecords)); result.capacityLimited = true
                        }
                    }
                    if result.snapshots.count > 8_000 { result.snapshots = Array(result.snapshots.sorted { $0.observedAt < $1.observedAt }.suffix(8_000)) }
                } catch { result.skippedFiles += 1; result.error = "部分会话记录无法读取；已保留能够读取的计量数据。" }
            }
            result.skippedFiles += max(0, candidates.count - 400)
        }
        if includeSessionFiles, isDirectory.boolValue, !fm.isReadableFile(atPath: root.path) { result.error = "无法读取会话目录，请检查文件访问权限。" }
        if let path = config.quotaPath {
            do {
                let url = URL(fileURLWithPath: path)
                try Self.validateQuotaFile(url)
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? now
                if config.provider == .claude,
                   let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let rates = value["rate_limits"] as? [String: Any],
                   let snapshot = AIUsageLogParser.claudeQuota(rates, date: AIUsageLogParser.date(value["observedAt"]) ?? modified) {
                    try snapshot.validate(now: now); result.snapshots.append(snapshot); result.sourceExists = true
                } else {
                    let snapshot = try AIQuotaImport.decode(data, now: now)
                    guard snapshot.provider == config.provider else { throw AIUsageError.invalid("额度文件的服务商与所选来源不一致。") }
                    result.snapshots.append(snapshot); result.sourceExists = true
                }
            } catch {
                let failure = error as NSError
                // The status-line host creates its first snapshot after a real Claude request.
                if failure.domain != NSCocoaErrorDomain || failure.code != NSFileReadNoSuchFileError {
                    result.error = (error as? AIUsageError)?.localizedDescription ?? "额度文件无法读取，请检查访问权限及 JSON 格式。"
                }
            }
        }
        result.records = AIUsageAggregation.deduplicate(result.records.filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(300) })
        result.snapshots = result.snapshots.filter { $0.observedAt >= cutoff && $0.observedAt <= now.addingTimeInterval(300) }
        if let manual = config.manualSnapshot { result.snapshots.append(manual) }
        return result
    }
    private func parseFile(_ url: URL, provider: AIProvider, maximumBytes: Int, now: Date) throws -> AIUsageParsedFile {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let sourceID = SHA256.hash(data: Data(url.lastPathComponent.utf8)).map { String(format: "%02x", $0) }.joined()
        var parser = AIUsageLogParser(), buffer = Data(), read = 0, skippingLongLine = false
        var capacityLimited = false
        let cutoff = now.addingTimeInterval(-Double(AITokenLedger.retentionDays) * 86_400)
        while read < maximumBytes, let data = try file.read(upToCount: min(65_536, maximumBytes - read)), !data.isEmpty {
            try Task.checkCancellation()
            read += data.count; buffer.append(data)
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end)
                if !skippingLongLine {
                    parser.consume(Data(line), provider: provider, sourceID: sourceID)
                    // Keep the parser's cumulative-counter state, even when the
                    // resulting old metering record is outside our retention window.
                    if let last = parser.records.last, last.timestamp < cutoff || last.timestamp > now.addingTimeInterval(300) { parser.records.removeLast() }
                    if let last = parser.snapshots.last, last.observedAt < cutoff || last.observedAt > now.addingTimeInterval(300) { parser.snapshots.removeLast() }
                    if parser.records.count > AITokenLedger.maximumRecords + 256 {
                        parser.records = AIUsageAggregation.deduplicate(parser.records)
                        if parser.records.count > AITokenLedger.maximumRecords {
                            parser.records = Array(parser.records.suffix(AITokenLedger.maximumRecords)); capacityLimited = true
                        }
                    }
                    if parser.snapshots.count > 8_256 { parser.snapshots = Array(parser.snapshots.sorted { $0.observedAt < $1.observedAt }.suffix(8_000)) }
                }
                buffer.removeSubrange(...end); skippingLongLine = false
            }
            if buffer.count > 2_097_152 { buffer.removeAll(keepingCapacity: false); skippingLongLine = true }
        }
        // In-progress JSONL tails are deliberately ignored until a newline is written.
        let records = AIUsageAggregation.deduplicate(parser.records)
        return .init(records: Array(records.suffix(AITokenLedger.maximumRecords)),
                     snapshots: Array(parser.snapshots.sorted { $0.observedAt < $1.observedAt }.suffix(8_000)),
                     capacityLimited: capacityLimited || records.count > AITokenLedger.maximumRecords)
    }
    nonisolated static func validateQuotaFile(_ url: URL) throws {
        let forbidden = ["auth.json", "credentials.json", ".credentials.json", "settings.json", "config.json"]
        guard url.pathExtension.lowercased() == "json", !forbidden.contains(url.lastPathComponent.lowercased()) else { throw AIUsageError.invalid("请选择额度快照 JSON，不读取认证文件或应用配置。") }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) <= 262_144 else { throw AIUsageError.invalid("请选择不超过 256 KB 的普通额度 JSON 文件。") }
    }
}

@MainActor
final class AIUsageModel: ObservableObject {
    @Published private(set) var providerSummaries: [AIProviderSummary] = []
    @Published private(set) var records: [AITokenRecord] = []
    @Published private(set) var quotaHistory: [AIQuotaSnapshot] = []
    @Published private(set) var prices: [AITokenPrice] = []
    @Published private(set) var configurations: [AIUsageSourceConfiguration] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshed: Date?
    @Published var errorMessage: String?
    @Published private(set) var diagnostics: [AIProvider: String] = [:]
    @Published private(set) var storageReadErrors: [String: String] = [:]
    @Published private(set) var coverage: [AIProvider: AIUsageSourceCoverage] = [:]
    @Published private(set) var tokenHistoryCapacityLimited = false
    @Published private(set) var tokenHistoryMessage: String?
    @Published private(set) var monthlyTokenHistory: [AITokenMonthSummary] = []
    @Published private(set) var alertConfiguration = AIQuotaAlertConfiguration()
    @Published private(set) var notificationPermission: AIQuotaNotificationPermission = .unknown
    @Published private(set) var destination: AIUsageDestination = .overview
    @Published var selectedPeriod: AIUsagePeriod = .week
    @Published var selectedProvider: AIProvider?
    @Published var dialog: AIUsageDialog?
    @Published var confirmDiscardDialog = false
    @Published var dialogBusy = false
    @Published var manualDraft = AIManualQuotaDraft()
    @Published var alertEnabled = false
    @Published var alertWarningText = "75"
    @Published var alertCriticalText = "90"
    @Published var priceDraft = AIPriceEditingDraft()
    @Published var priceMessage: String?
    @Published var confirmDiscardPrice = false
    @Published private(set) var connectionPreview: AIUsageConnectionPreview?
    @Published private(set) var connectionPreviewLoading = false
    @Published private(set) var claudeQuotaSyncMessage: String?
    @Published private(set) var subscriptionConnectionResults: [AIProvider: AISubscriptionConnectionResult] = [:]
    private let directory: URL
    private let claudeSettingsDirectory: URL
    private let statusLineExecutableURL: URL?
    private let subscriptionConnectionWait: TimeInterval
    private let followsSubscriptionConnections: Bool
    private var connectingSubscriptions = Set<AIProvider>()
    private var subscriptionFollowups: [AIProvider: Task<Void, Never>] = [:]
    private let tokenStore: AITokenLedgerStore
    private let alertStore: AIQuotaAlertStore
    private let notifications: any AIQuotaNotificationProviding
    private var tokenLedger: AITokenLedger
    private var historyStore: AIUsageHistoryStore?
    private var inFlightAlerts = Set<String>()
    private var navigationStack: [AIUsageDestination] = []
    private var returnsToSettingsPrivacy = false
    private var manualBaseline = AIManualQuotaDraft()
    private var alertBaseline = AIQuotaAlertRule()
    private var priceBaseline = AIPriceEditingDraft()
    private var pendingPriceChoice: (AIProvider, String)?
    private var pendingPriceBack = false
    private var pendingConnection: AIUsageSourceConfiguration?
    private var connectionReturnDialog: AIUsageDialog?
    private var connectionGeneration = UUID()
    private let reader = AIUsageReader()
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var generation = 0
    private var preparingForQuit = false
    var todayTokens: Int64 { filteredRecords(period: .today).reduce(0) { $0 + $1.tokens.total } }
    var storageRecoveryInstructions: String { "原文件已保留，对应文件的写入已暂停。请先退出方寸，备份下列原文件，再修复文件或将损坏文件移出此目录，重新打开方寸。移走文件会重新建立该项数据，不会恢复旧记录。" }
    func revealDataDirectory() { NSWorkspace.shared.open(directory) }
    init(dataDirectory: URL, startServices: Bool = true, notifications: (any AIQuotaNotificationProviding)? = nil,
         claudeSettingsDirectory: URL? = nil, statusLineExecutableURL: URL? = nil, subscriptionConnectionWait: TimeInterval = 4) {
        directory = dataDirectory.appendingPathComponent("AIUsage", isDirectory: true)
        let environmentDirectory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { path -> URL? in
            guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        self.claudeSettingsDirectory = claudeSettingsDirectory ?? environmentDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        self.statusLineExecutableURL = statusLineExecutableURL ?? Bundle.main.executableURL
        self.subscriptionConnectionWait = subscriptionConnectionWait.isFinite ? min(10, max(0, subscriptionConnectionWait)) : 4
        followsSubscriptionConnections = startServices
        tokenStore = AITokenLedgerStore(url: directory.appendingPathComponent("token-ledger.json"))
        alertStore = AIQuotaAlertStore(url: directory.appendingPathComponent("quota-alerts.json"))
        tokenLedger = AITokenLedger()
        self.notifications = notifications ?? AIQuotaNotificationService()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaults = AIProvider.allCases.map { provider in
            AIUsageSourceConfiguration(provider: provider, sessionsPath: provider == .codex ? home.appendingPathComponent(".codex/sessions").path : self.claudeSettingsDirectory.appendingPathComponent("projects").path)
        }
        configurations = defaults
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch {
            for name in ["sources.json", "quota-history.json", "model-prices.json", "token-ledger.json", "quota-alerts.json"] { protectStorageFile(name) }
        }
        if let saved: [AIUsageSourceConfiguration] = loadStorage("sources.json", validate: { items in
            guard Set(items.map(\.provider)).count == items.count,
                  items.allSatisfy({ !$0.sessionsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw AIUsageError.invalid("来源配置无效。") }
            for item in items {
                if let snapshot = item.manualSnapshot {
                    guard snapshot.provider == item.provider else { throw AIUsageError.invalid("来源与读数服务商不一致。") }
                    try snapshot.validate()
                }
            }
        }) { configurations = defaults.map { item in saved.first(where: { $0.provider == item.provider }) ?? item } }
        if storageReadErrors["sources.json"] != nil {
            // A damaged opt-in configuration must not silently enable default sources.
            configurations = defaults.map { var item = $0; item.enabled = false; return item }
        }
        if let history: [AIQuotaSnapshot] = loadStorage("quota-history.json", validate: {
            guard $0.count <= 8_000 else { throw AIUsageError.invalid("额度历史超过容量上限。") }
            for snapshot in $0 { try snapshot.validate() }
        }) { quotaHistory = history }
        if let saved: [AITokenPrice] = loadStorage("model-prices.json", validate: { items in
            guard Set(items.map(\.id)).count == items.count else { throw AIUsageError.invalid("模型单价重复。") }
            for item in items { _ = try AITokenPrice(provider: item.provider, model: item.model, inputPerMillion: item.inputPerMillion, outputPerMillion: item.outputPerMillion, cacheReadPerMillion: item.cacheReadPerMillion, cacheWritePerMillion: item.cacheWritePerMillion) }
        }) { prices = saved }
        if storageReadErrors["token-ledger.json"] == nil {
            do { tokenLedger = try tokenStore.load(); records = tokenLedger.records; tokenHistoryCapacityLimited = tokenLedger.capacityLimited }
            catch { protectStorageFile("token-ledger.json") }
        }
        if storageReadErrors["quota-alerts.json"] == nil {
            do { alertConfiguration = try alertStore.load() }
            catch { protectStorageFile("quota-alerts.json") }
        }
        historyStore = AIUsageHistoryStore(tokens: tokenStore, quotaURL: directory.appendingPathComponent("quota-history.json"),
            ledger: tokenLedger, quotaHistory: quotaHistory, canWriteTokens: storageReadErrors["token-ledger.json"] == nil,
            canWriteQuota: storageReadErrors["quota-history.json"] == nil)
        if !storageReadErrors.isEmpty { errorMessage = "AI 本机文件读取失败，原文件已保留并暂停对应写入。请在 AI 用量的数据源中查看恢复说明。" }
        providerSummaries = AIProvider.allCases.map { .init(provider: $0, state: .unavailable, snapshot: nil, detail: "正在检查本地计量来源。") }
        if startServices {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        }
    }
    func refresh() {
        guard !isRefreshing, !preparingForQuit, let historyStore else { return }
        isRefreshing = true; generation += 1
        let currentGeneration = generation, configs = configurations, now = Date()
        refreshTask = Task { [weak self, reader, historyStore] in
            let results = await reader.scan(configs, now: now)
            guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
            let update = await historyStore.update(records: results.flatMap(\.records), snapshots: results.flatMap(\.snapshots),
                now: now, sourceCapacityLimited: results.contains { $0.capacityLimited })
            guard !Task.isCancelled, self.generation == currentGeneration else { return }
            self.tokenLedger = update.ledger; self.records = update.ledger.records; self.tokenHistoryCapacityLimited = update.ledger.capacityLimited
            self.tokenHistoryMessage = update.tokenError; self.monthlyTokenHistory = update.monthlySummaries
            self.quotaHistory = update.quotaHistory
            if let error = update.quotaError { self.errorMessage = error }
            self.coverage = Dictionary(uniqueKeysWithValues: configs.map { config in
                let result = results.first { $0.provider == config.provider }
                return (config.provider, AIUsageSourceCoverage(provider: config.provider, scannedAt: now, enabled: config.enabled, sourceAvailable: result?.sourceExists ?? false, scannedFiles: result?.fileCount ?? 0, skippedFiles: result?.skippedFiles ?? 0, records: result?.records ?? []))
            })
            self.providerSummaries = configs.map { config -> AIProviderSummary in
                if let error = self.storageReadErrors["sources.json"] { return .init(provider: config.provider, state: .error, snapshot: nil, detail: error) }
                let result = results.first { $0.provider == config.provider }!
                guard config.enabled else {
                    self.diagnostics[config.provider] = "自动读取关闭 · 未扫描会话目录或额度文件"
                    if let manual = result.snapshots.max(by: { $0.observedAt < $1.observedAt }) {
                        return .init(provider: config.provider, state: manual.isStale(at: now) ? .stale : .ready, snapshot: manual,
                                     detail: "自动读取已关闭；仅展示\(manual.source.title)，不会自动更新。超过 15 分钟或窗口重置后标记过期，历史记录仍保留。")
                    }
                    return .init(provider: config.provider, state: .disconnected, snapshot: nil, detail: "自动读取已关闭；历史读数仍保留，可单独手动记录或导入额度。")
                }
                let latest = result.snapshots.max { $0.observedAt < $1.observedAt }
                    ?? self.quotaHistory.filter { $0.provider == config.provider }.max { $0.observedAt < $1.observedAt }
                self.diagnostics[config.provider] = "已读取 \(result.fileCount) 个会话文件 · \(result.records.count) 条计量记录" + (result.skippedFiles > 0 ? " · \(result.skippedFiles) 个文件超出本次范围或不可读" : "")
                if let error = result.error { return .init(provider: config.provider, state: .error, snapshot: latest, detail: error) }
                if let latest {
                    let stale = latest.isStale(at: now) || result.snapshots.isEmpty
                    return .init(provider: config.provider, state: stale ? .stale : .ready, snapshot: latest,
                                 detail: result.snapshots.isEmpty ? "本次未读取到有效额度，保留最后读数并等待来源恢复。" : stale ? "保留最后有效读数；超过 15 分钟或窗口已重置，等待来源更新。" : "额度来自所标注来源，不由 Token 数推算。")
                }
                let detail = config.provider == .claude
                    ? (config.quotaPath == nil ? "在配置用量中点击“连接本机订阅”，自动接入 Claude 额度。" : "已连接本机来源，等待 Claude Code 提供真实额度；收到后自动更新。")
                    : "尚未找到额度字段。使用已登录的 Codex 完成一次请求后刷新，或选择会话目录。"
                return .init(provider: config.provider, state: result.sourceExists || config.quotaPath != nil ? .unavailable : .disconnected, snapshot: nil, detail: detail)
            }.map { summary in
                var value = summary
                value.declaredPlan = configs.first { $0.provider == summary.provider }?.declaredPlan
                return value
            }
            self.lastRefreshed = now
            self.updateSubscriptionConnectionResults()
            await self.processAlerts(at: now)
            if self.generation == currentGeneration { self.isRefreshing = false }
        }
    }
    func prepareForQuit() async throws {
        preparingForQuit = true
        subscriptionFollowups.values.forEach { $0.cancel() }; subscriptionFollowups.removeAll()
        refreshTask?.cancel()
        if let refreshTask { await refreshTask.value }
        refreshTask = nil; isRefreshing = false
        try await historyStore?.flush()
    }
    func resumeAfterCancelledQuit() { preparingForQuit = false; refresh() }
    func estimate(_ records: [AITokenRecord]) -> (amount: Double, covered: Int, total: Int) {
        var amount = 0.0, covered = 0
        for record in records {
            if let price = prices.first(where: { $0.provider == record.provider && $0.model == record.model }) { amount += price.estimate(record.tokens); covered += 1 }
        }
        return (amount, covered, records.count)
    }
    var alertRule: AIQuotaAlertRule { alertConfiguration.rule }
    var hasUnsavedPriceChanges: Bool { priceDraft != priceBaseline }
    var dialogHasChanges: Bool {
        switch dialog {
        case .manual: manualDraft != manualBaseline
        case .alert: alertEnabled != alertBaseline.enabled || alertWarningText != String(alertBaseline.warningPercent) || alertCriticalText != String(alertBaseline.criticalPercent)
        default: false
        }
    }
    func show(_ next: AIUsageDestination) {
        guard next != destination else { return }
        navigationStack.append(destination); destination = next
        if next == .prices, priceDraft.model.isEmpty, !hasUnsavedPriceChanges { loadPriceDraft(provider: selectedProvider ?? .codex, model: knownModels(for: selectedProvider ?? .codex).first ?? "") }
    }
    func showOverview() { navigationStack = []; destination = .overview; returnsToSettingsPrivacy = false }
    func openSources(fromSettingsPrivacy: Bool = false) {
        if fromSettingsPrivacy { navigationStack = []; destination = .sources; returnsToSettingsPrivacy = true }
        else { show(.sources) }
    }
    /// Returns true only for the external Settings → Privacy entry point.
    func backTitle(overviewTitle: String) -> String {
        guard let parent = navigationStack.last else { return returnsToSettingsPrivacy ? "返回隐私与锁定" : "返回" + overviewTitle }
        switch parent {
        case .overview: return "返回" + overviewTitle
        case .provider(let provider): return "返回" + provider.title + " 用量"
        case .sources: return "返回来源管理"
        case .history: return "返回 Token 活动记录"
        case .prices: return "返回模型单价"
        }
    }
    @discardableResult func goBack() -> Bool {
        if let previous = navigationStack.popLast() { destination = previous; return false }
        let external = returnsToSettingsPrivacy
        showOverview(); return external
    }
    func present(_ next: AIUsageDialog, provider: AIProvider? = nil) {
        errorMessage = nil
        if next == .manual {
            manualDraft = AIManualQuotaDraft(); manualDraft.provider = provider ?? selectedProvider ?? .codex
            manualBaseline = manualDraft
        }
        if next == .alert {
            alertBaseline = alertRule; alertEnabled = alertRule.enabled
            alertWarningText = String(alertRule.warningPercent); alertCriticalText = String(alertRule.criticalPercent)
        }
        dialog = next
    }
    func requestDismissDialog() {
        guard !dialogBusy else { return }
        if dialog == .connectionPreview { cancelConnection(); return }
        if dialogHasChanges { confirmDiscardDialog = true } else { dialog = nil; errorMessage = nil }
    }
    func discardDialogChanges() { confirmDiscardDialog = false; dialog = nil; errorMessage = nil }
    @discardableResult func saveManualDraft() -> Bool {
        let draft = manualDraft
        guard saveManual(provider: draft.provider, shortPercent: draft.shortPercent, weekPercent: draft.weeklyPercent, observedAt: draft.observedAt,
                         shortReset: draft.shortReset, weekReset: draft.weeklyReset, note: draft.note, includeResets: draft.specifiesResetTimes) else { return false }
        dialog = nil; return true
    }
    @discardableResult func saveAlertDraft() async -> Bool {
        guard let warning = Int(alertWarningText), let critical = Int(alertCriticalText) else { errorMessage = "请输入 1–99% 之间的整数阈值。"; return false }
        var rule = alertRule; rule.enabled = alertEnabled; rule.warningPercent = warning; rule.criticalPercent = critical
        dialogBusy = true; defer { dialogBusy = false }
        guard await saveAlertRule(rule) else { return false }
        dialog = nil; return true
    }
    @discardableResult func saveAlertRule(_ rule: AIQuotaAlertRule) async -> Bool {
        do {
            try rule.validate()
            if let protected = storageReadErrors["quota-alerts.json"] { throw AIUsageError.invalid(protected) }
            if rule.enabled {
                notificationPermission = await notifications.permission()
                if notificationPermission == .notDetermined {
                    _ = try await notifications.requestPermission()
                    notificationPermission = await notifications.permission()
                }
            }
            var next = alertConfiguration; next.rule = rule
            try alertStore.save(next); alertConfiguration = next
            await processAlerts(at: Date())
            return true
        } catch { errorMessage = "额度提醒未能保存：" + error.localizedDescription; return false }
    }
    private func processAlerts(at now: Date) async {
        notificationPermission = await notifications.permission()
        guard alertRule.enabled, notificationPermission == .authorized, storageReadErrors["quota-alerts.json"] == nil else { return }
        let events = AIQuotaAlertEvaluator(state: alertConfiguration.state).pendingEvents(rule: alertRule, summaries: providerSummaries, at: now)
        for event in events {
            guard !Task.isCancelled, alertRule.enabled, !inFlightAlerts.contains(event.id) else { continue }
            inFlightAlerts.insert(event.id)
            do {
                try await notifications.deliver(event)
                var evaluator = AIQuotaAlertEvaluator(state: alertConfiguration.state)
                evaluator.recordDelivery(event, at: Date())
                var next = alertConfiguration; next.state = evaluator.state
                // Keep an in-memory acknowledgement even if the disk is briefly
                // unavailable; do not repeat a delivered alert on every refresh.
                alertConfiguration = next
                do { try alertStore.save(next) }
                catch { errorMessage = "额度提醒已发送，但去重记录保存失败：" + error.localizedDescription }
            } catch { errorMessage = "额度提醒未能发送：" + error.localizedDescription }
            inFlightAlerts.remove(event.id)
        }
    }
    func knownModels(for provider: AIProvider) -> [String] {
        Array(Set(records.filter { $0.provider == provider }.map(\.model) + prices.filter { $0.provider == provider }.map(\.model))).sorted()
    }
    func requestPriceSelection(provider: AIProvider, model: String) {
        if hasUnsavedPriceChanges { pendingPriceChoice = (provider, model); pendingPriceBack = false; confirmDiscardPrice = true }
        else { loadPriceDraft(provider: provider, model: model) }
    }
    func requestPriceBack() { pendingPriceChoice = nil; pendingPriceBack = true; confirmDiscardPrice = true }
    func discardPriceChanges() {
        confirmDiscardPrice = false
        if let choice = pendingPriceChoice { loadPriceDraft(provider: choice.0, model: choice.1) }
        else { priceDraft = priceBaseline; if pendingPriceBack { _ = goBack() } }
        pendingPriceChoice = nil; pendingPriceBack = false
    }
    private func loadPriceDraft(provider: AIProvider, model: String) {
        var draft = AIPriceEditingDraft(); draft.provider = provider; draft.model = model
        if let price = prices.first(where: { $0.provider == provider && $0.model == model }) {
            draft.input = String(price.inputPerMillion); draft.output = String(price.outputPerMillion)
            draft.cacheRead = String(price.cacheReadPerMillion); draft.cacheWrite = String(price.cacheWritePerMillion)
        }
        priceDraft = draft; priceBaseline = draft; priceMessage = nil
    }
    @discardableResult func savePriceDraft() -> Bool {
        do {
            guard let input = Double(priceDraft.input), let output = Double(priceDraft.output),
                  let read = Double(priceDraft.cacheRead), let write = Double(priceDraft.cacheWrite) else {
                throw AIUsageError.invalid("四项单价均需填写；确认免费时可填 0。未配置的模型不参与估算。")
            }
            let price = try AITokenPrice(provider: priceDraft.provider, model: priceDraft.model.trimmingCharacters(in: .whitespacesAndNewlines), inputPerMillion: input, outputPerMillion: output, cacheReadPerMillion: read, cacheWritePerMillion: write)
            guard savePrice(price) else { return false }
            priceDraft.model = price.model; priceBaseline = priceDraft; priceMessage = "单价已保存，API 等价估算已更新。"; return true
        } catch { priceMessage = error.localizedDescription; return false }
    }
    @discardableResult func savePrice(_ price: AITokenPrice) -> Bool {
        let next = prices.filter { $0.id != price.id } + [price]
        do { try write(JSONEncoder().encode(next), to: "model-prices.json"); prices = next; return true }
        catch { errorMessage = storageReadErrors["model-prices.json"] ?? "模型单价保存失败，原设置已保留。"; return false }
    }
    func removePrice(_ id: String) {
        let next = prices.filter { $0.id != id }
        do { try write(JSONEncoder().encode(next), to: "model-prices.json"); prices = next; if priceDraft.provider.rawValue + ":" + priceDraft.model == id { loadPriceDraft(provider: priceDraft.provider, model: priceDraft.model) } }
        catch { errorMessage = storageReadErrors["model-prices.json"] ?? "模型单价删除失败。" }
    }
    func filteredRecords(provider: AIProvider? = nil, period: AIUsagePeriod = .today, now: Date = Date(), includeDisconnected: Bool = false) -> [AITokenRecord] {
        let start = period.start(now: now)
        let enabled = Set(configurations.filter(\.enabled).map(\.provider))
        return records.filter { (provider == nil || $0.provider == provider) && (includeDisconnected || enabled.contains($0.provider)) && $0.timestamp >= start && $0.timestamp <= now }
    }
    func configuration(for provider: AIProvider) -> AIUsageSourceConfiguration { configurations.first { $0.provider == provider }! }
    @discardableResult func setEnabled(_ enabled: Bool, provider: AIProvider) -> Bool {
        guard mutate(provider, update: { $0.enabled = enabled }) else { return false }
        if !enabled { subscriptionFollowups.removeValue(forKey: provider)?.cancel(); subscriptionConnectionResults.removeValue(forKey: provider) }
        return true
    }
    /// Accepts the directory already chosen in a system open panel. No second
    /// connection-preview confirmation is needed before the explicit connect.
    @discardableResult func useLocalSubscriptionDirectory(_ url: URL, provider: AIProvider) -> Bool {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            errorMessage = "请选择可读取的 \(provider.title) 会话文件夹。"; return false
        }
        guard mutate(provider, update: { $0.sessionsPath = url.standardizedFileURL.path }) else { return false }
        errorMessage = nil; return true
    }
    /// One explicit action connects the local source and, for Claude, its official
    /// status-line adapter. Only a fresh automatic quota may return ready.
    func connectLocalSubscription(provider: AIProvider) async -> AISubscriptionConnectionResult {
        guard connectingSubscriptions.insert(provider).inserted else {
            return .waiting(message: "正在检查本机来源，请稍候。")
        }
        defer { connectingSubscriptions.remove(provider) }
        let connectionStartedAt = Date()
        errorMessage = nil
        subscriptionFollowups.removeValue(forKey: provider)?.cancel()
        func finish(_ result: AISubscriptionConnectionResult) -> AISubscriptionConnectionResult {
            subscriptionConnectionResults[provider] = result
            switch result {
            case .failed, .authorizationRequired: errorMessage = result.message; if provider == .claude { claudeQuotaSyncMessage = nil }
            case .ready, .waiting: errorMessage = nil; if provider == .claude { claudeQuotaSyncMessage = result.message }
            }
            return result
        }
        let sourceURL = URL(fileURLWithPath: configuration(for: provider).sessionsPath)
        var isDirectory: ObjCBool = false
        let sourceExists = FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
        if sourceExists && !FileManager.default.isReadableFile(atPath: sourceURL.path) {
            return finish(.authorizationRequired(message: "无法读取 \(provider.title) 本机来源。请在系统文件选择窗口中授权实际会话目录后重试。"))
        }
        if !sourceExists {
            return finish(.authorizationRequired(message: "未找到 \(provider.title) 本机会话目录。可选择实际会话文件夹恢复；若尚未使用官方客户端，请先安装并完成登录。"))
        }
        if provider == .claude {
            guard enableClaudeQuotaSync() else { return finish(.failed(message: errorMessage ?? "Claude 额度同步设置未完成，原设置已保留。")) }
        } else {
            guard mutate(provider, update: { $0.enabled = true; $0.quotaPath = nil; $0.manualSnapshot = nil; $0.manualNote = nil }) else {
                return finish(.failed(message: errorMessage ?? "本机来源无法保存，请检查设置文件后重试。"))
            }
        }
        subscriptionConnectionResults[provider] = waitingForSubscription(provider)
        let deadline = Date().addingTimeInterval(subscriptionConnectionWait)
        var lastClaudeQuotaStamp = quotaFileStamp(.claude)
        var nextCodexInspection = Date().addingTimeInterval(1)
        repeat {
            let checkedCurrentSource = !isRefreshing && (lastRefreshed ?? .distantPast) >= connectionStartedAt
            if checkedCurrentSource, let ready = freshSubscriptionResult(provider) { return finish(ready) }
            if checkedCurrentSource, let summary = providerSummaries.first(where: { $0.provider == provider }), summary.state == .error {
                return finish(.failed(message: summary.detail))
            }
            if Date() >= deadline || Task.isCancelled || preparingForQuit { break }
            if !isRefreshing {
                if provider == .claude {
                    let stamp = quotaFileStamp(provider)
                    if stamp != lastClaudeQuotaStamp { lastClaudeQuotaStamp = stamp; refresh() }
                } else if Date() >= nextCodexInspection { nextCodexInspection = Date().addingTimeInterval(1); refresh() }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        } while true
        if !isRefreshing, (lastRefreshed ?? .distantPast) >= connectionStartedAt, let ready = freshSubscriptionResult(provider) { return finish(ready) }
        let result = finish(waitingForSubscription(provider))
        followSubscriptionReading(provider)
        return result
    }
    private func freshSubscriptionResult(_ provider: AIProvider) -> AISubscriptionConnectionResult? {
        guard configuration(for: provider).enabled,
              let summary = providerSummaries.first(where: { $0.provider == provider }), summary.state == .ready,
              let snapshot = summary.snapshot, !snapshot.isStale(),
              snapshot.source == (provider == .claude ? .claudeStatusLine : .localSession) else { return nil }
        return .ready(message: provider.title + " 订阅额度已连接。")
    }
    private func waitingForSubscription(_ provider: AIProvider) -> AISubscriptionConnectionResult {
        .waiting(message: provider == .claude
            ? "同步设置已完成，等待 Claude Code 提供真实额度。已有会话会自动更新；尚无读数时，下一次正常使用后自动显示。"
            : "本机来源已启用，等待 Codex 提供真实额度。下一次正常使用后会自动更新。")
    }
    private func updateSubscriptionConnectionResults() {
        for provider in Array(subscriptionConnectionResults.keys) where configuration(for: provider).enabled {
            if let ready = freshSubscriptionResult(provider) {
                subscriptionConnectionResults[provider] = ready; subscriptionFollowups.removeValue(forKey: provider)?.cancel()
                if provider == .claude { claudeQuotaSyncMessage = ready.message }
            }
            else if let summary = providerSummaries.first(where: { $0.provider == provider }), summary.state == .error {
                subscriptionConnectionResults[provider] = .failed(message: summary.detail)
            } else if subscriptionConnectionResults[provider]?.isReady == true {
                subscriptionConnectionResults[provider] = waitingForSubscription(provider)
            }
        }
    }
    private func followSubscriptionReading(_ provider: AIProvider) {
        guard followsSubscriptionConnections, !preparingForQuit else { return }
        subscriptionFollowups[provider]?.cancel()
        subscriptionFollowups[provider] = Task { [weak self] in
            var lastStamp = self?.quotaFileStamp(provider)
            for attempt in 0..<120 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let model = self, model.configuration(for: provider).enabled, !model.preparingForQuit else { return }
                if model.freshSubscriptionResult(provider) != nil { return }
                if provider == .claude {
                    let stamp = model.quotaFileStamp(provider)
                    if stamp != lastStamp { lastStamp = stamp; model.refresh() }
                } else if attempt % 5 == 0 { model.refresh() }
            }
        }
    }
    private func quotaFileStamp(_ provider: AIProvider) -> String? {
        guard let path = configuration(for: provider).quotaPath,
              let info = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = info.contentModificationDate else { return nil }
        return "\(modified.timeIntervalSince1970):\(info.fileSize ?? 0)"
    }
    func chooseSessionsDirectory(for provider: AIProvider) {
        let panel = NSOpenPanel(); panel.title = "选择 \(provider.title) 会话目录"; panel.message = "仅读取 JSONL 中的用量元数据，不保存对话正文。"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: configuration(for: provider).sessionsPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        reviewSessionsDirectory(at: url, for: provider)
    }
    func reviewSessionsDirectory(at url: URL, for provider: AIProvider) {
        var candidate = configuration(for: provider); candidate.sessionsPath = url.path; candidate.enabled = true
        stageConnection(candidate, quotaFile: false, path: url.path)
    }
    func chooseQuotaFile(for provider: AIProvider) {
        let panel = NSOpenPanel(); panel.title = "连接 \(provider.title) 额度快照"; panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        reviewQuotaFile(at: url, for: provider)
    }
    func reviewQuotaFile(at url: URL, for provider: AIProvider) {
        do {
            try AIUsageReader.validateQuotaFile(url)
            var candidate = configuration(for: provider); candidate.quotaPath = url.path; candidate.enabled = true; candidate.manualSnapshot = nil; candidate.manualNote = nil
            stageConnection(candidate, quotaFile: true, path: url.path)
        }
        catch { errorMessage = error.localizedDescription }
    }
    private func stageConnection(_ candidate: AIUsageSourceConfiguration, quotaFile: Bool, path: String) {
        connectionReturnDialog = dialog == .claudeConnect ? .claudeConnect : nil
        pendingConnection = candidate; connectionPreview = nil; connectionPreviewLoading = true; errorMessage = nil
        let generation = UUID(); connectionGeneration = generation; dialog = .connectionPreview
        Task { [weak self] in
            // A pending, unconfirmed source has its own short-lived cache.
            let reader = AIUsageReader()
            var previewCandidate = candidate; previewCandidate.manualSnapshot = nil
            if !quotaFile { previewCandidate.quotaPath = nil }
            let result = await reader.scan([previewCandidate], now: Date(), includeSessionFiles: !quotaFile).first
            guard let self, self.connectionGeneration == generation else { return }
            let snapshot = result?.snapshots.max { $0.observedAt < $1.observedAt }
            let windows = [snapshot?.shortWindow, snapshot?.weeklyWindow].compactMap { $0 }
            self.connectionPreview = .init(provider: candidate.provider, path: path, quotaFile: quotaFile, files: result?.fileCount ?? 0, records: result?.records.count ?? 0, windows: windows,
                                           observedAt: snapshot?.observedAt, quotaSource: snapshot?.source, error: result?.error, canConnect: quotaFile ? !windows.isEmpty && result?.error == nil : result?.sourceExists == true)
            self.connectionPreviewLoading = false
        }
    }
    @discardableResult func confirmConnection() -> Bool {
        guard connectionPreview?.canConnect == true, let candidate = pendingConnection else { return false }
        let singleImport = connectionPreview?.singleImport == true
        guard mutate(candidate.provider, update: {
            if singleImport { $0.manualSnapshot = candidate.manualSnapshot; $0.manualNote = candidate.manualNote }
            else { $0 = candidate }
        }) else { return false }
        connectionGeneration = UUID(); pendingConnection = nil; connectionPreview = nil
        dialog = connectionReturnDialog; connectionReturnDialog = nil
        return true
    }
    func cancelConnection() {
        connectionGeneration = UUID(); pendingConnection = nil; connectionPreview = nil; connectionPreviewLoading = false
        dialog = connectionReturnDialog; connectionReturnDialog = nil; errorMessage = nil
    }
    func removeQuotaFile(for provider: AIProvider) {
        if mutate(provider, update: { $0.quotaPath = nil }), provider == .claude { claudeQuotaSyncMessage = nil }
    }
    func importQuota() {
        let panel = NSOpenPanel(); panel.title = "导入额度记录"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        reviewQuotaImport(at: url)
    }
    @discardableResult func reviewQuotaImport(at url: URL) -> Bool {
        do {
            try AIUsageReader.validateQuotaFile(url)
            let snapshot = try AIQuotaImport.decode(Data(contentsOf: url))
            var candidate = configuration(for: snapshot.provider)
            candidate.manualSnapshot = snapshot; candidate.manualNote = nil
            connectionReturnDialog = dialog == .claudeConnect ? .claudeConnect : nil
            pendingConnection = candidate; connectionGeneration = UUID(); connectionPreviewLoading = false
            connectionPreview = .init(provider: snapshot.provider, path: url.path, quotaFile: true,
                                      files: 1, records: 0, windows: [snapshot.shortWindow, snapshot.weeklyWindow].compactMap { $0 },
                                      observedAt: snapshot.observedAt, quotaSource: .imported, singleImport: true, error: nil, canConnect: true)
            errorMessage = nil; dialog = .connectionPreview; return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    @discardableResult func saveManual(provider: AIProvider, shortPercent: String, weekPercent: String, observedAt: Date, shortReset: Date, weekReset: Date, note: String = "", includeResets: Bool = true) -> Bool {
        do {
            func window(_ text: String, minutes: Int, reset: Date) throws -> AIQuotaWindow? {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                guard let value = Double(trimmed) else { throw AIUsageError.invalid("请输入 0–100 的数字，未知的窗口请留空。") }
                return try .init(usedPercent: value, durationMinutes: minutes, resetsAt: includeResets ? reset : nil)
            }
            let snapshot = AIQuotaSnapshot(provider: provider, observedAt: observedAt, source: .manual, shortWindow: try window(shortPercent, minutes: 300, reset: shortReset), weeklyWindow: try window(weekPercent, minutes: 10_080, reset: weekReset))
            try snapshot.validate()
            guard note.count <= 200, !note.contains("\0") else { throw AIUsageError.invalid("记录备注最多 200 个字符。") }
            return mutate(provider) { $0.manualSnapshot = snapshot; $0.manualNote = note.isEmpty ? nil : note }
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func exportTemplate() {
        let panel = NSSavePanel(); panel.title = "保存额度 JSON 模板"; panel.nameFieldStringValue = "quota-template.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = """
        {
          "provider": "claude",
          "source": "imported",
          "observedAt": "填写真实读数的 ISO 8601 时间，例如 2026-10-19T10:00:00Z",
          "shortWindow": { "usedPercent": null, "durationMinutes": 300, "resetsAt": null },
          "weeklyWindow": { "usedPercent": null, "durationMinutes": 10080, "resetsAt": null }
        }
        """
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch { errorMessage = "模板保存失败。" }
    }
    @discardableResult func setDeclaredPlan(_ plan: AIAccountPlan?, provider: AIProvider) -> Bool {
        mutate(provider) { $0.declaredPlan = plan }
    }
    /// Called only by an explicit user action. Existing status-line commands are preserved.
    @discardableResult func enableClaudeQuotaSync() -> Bool {
        errorMessage = nil; claudeQuotaSyncMessage = nil
        guard storageReadErrors["sources.json"] == nil, let executable = statusLineExecutableURL else {
            errorMessage = storageReadErrors["sources.json"] ?? "无法找到方寸程序，请将方寸放入应用程序后再试。"
            return false
        }
        do {
            let destination = directory.appendingPathComponent("claude-quota.json")
            let sessions = URL(fileURLWithPath: configuration(for: .claude).sessionsPath)
            let settingsDirectory = sessions.lastPathComponent == "projects" ? sessions.deletingLastPathComponent() : claudeSettingsDirectory
            let receipt = try ClaudeQuotaSyncInstaller.install(settingsDirectory: settingsDirectory, executableURL: executable, quotaURL: destination)
            guard mutate(.claude, update: { $0.quotaPath = destination.path; $0.enabled = true; $0.manualSnapshot = nil; $0.manualNote = nil }) else {
                try receipt.rollback(); return false
            }
            claudeQuotaSyncMessage = "同步设置已完成。已有 Claude Code 会话会自动更新；尚无额度读数时，下一次正常使用后自动显示。"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    /// Exports a metadata-only adapter. It does not change the user's Claude settings or replace an existing status line.
    func exportClaudeAdapter() {
        let panel = NSSavePanel(); panel.title = "导出 Claude 状态栏适配器"; panel.nameFieldStringValue = "deskden-claude-usage.py"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = directory.appendingPathComponent("claude-quota.json").path
        // JSON string literals are valid Python string literals for these Unicode file paths.
        let adapterEncoder = JSONEncoder(); adapterEncoder.outputFormatting = [.withoutEscapingSlashes]
        let quoted = String(data: try! adapterEncoder.encode(destination), encoding: .utf8)!
        let script = """
        #!/usr/bin/env python3
        # Source: https://code.claude.com/docs/en/statusline
        # Only the official rate_limits fields are written; no prompt, credentials or workspace paths.
        import sys, json, os, datetime, math, tempfile
        destination = \(quoted)
        try:
            payload = json.load(sys.stdin)
            raw = payload.get('rate_limits') or {}
            rates = {}
            for key in ('five_hour', 'seven_day'):
                value = raw.get(key) or {}
                used, reset = value.get('used_percentage'), value.get('resets_at')
                if isinstance(used, (int, float)) and not isinstance(used, bool) and math.isfinite(used) and 0 <= used <= 100:
                    rates[key] = {'used_percentage': used}
                    if isinstance(reset, (int, float)) and math.isfinite(reset): rates[key]['resets_at'] = reset
            if rates:
                os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True)
                fd, temp = tempfile.mkstemp(prefix='.quota-', dir=os.path.dirname(destination))
                with os.fdopen(fd, 'w') as stream:
                    json.dump({'observedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'rate_limits': rates}, stream)
                os.replace(temp, destination)
            print(' · '.join(('5h' if k == 'five_hour' else '7d') + ': ' + str(round(v['used_percentage'])) + '%' for k, v in rates.items()) or '额度暂不可用')
        except (ValueError, OSError, TypeError):
            print('额度暂不可用')
        """
        do {
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            mutate(.claude) { $0.quotaPath = destination; $0.enabled = true }
        } catch { errorMessage = "适配器保存失败，请选择可写入的位置。" }
    }
    @discardableResult private func mutate(_ provider: AIProvider, update: (inout AIUsageSourceConfiguration) -> Void) -> Bool {
        var next = configurations
        guard let index = next.firstIndex(where: { $0.provider == provider }) else { return false }
        update(&next[index])
        do {
            try write(JSONEncoder().encode(next), to: "sources.json")
            configurations = next; generation += 1; refreshTask?.cancel(); isRefreshing = false; refresh(); return true
        } catch { errorMessage = storageReadErrors["sources.json"] ?? "来源设置保存失败，已保留原设置。"; return false }
    }
    private func protectStorageFile(_ name: String) {
        storageReadErrors[name] = "\(name) 无法读取或内容无效，已暂停此文件写入。原文件未更改；请备份后修复或移走原文件，再重启方寸。"
    }
    private func loadStorage<T: Decodable>(_ name: String, validate: (T) throws -> Void) -> T? {
        guard storageReadErrors[name] == nil else { return nil }
        do {
            let url = directory.appendingPathComponent(name)
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw AIUsageError.invalid("历史文件类型无效。") }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 4_194_305) ?? Data()
            guard data.count <= 4_194_304 else { throw AIUsageError.invalid("历史文件超过读取上限。") }
            let value = try JSONDecoder().decode(T.self, from: data)
            try validate(value)
            return value
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            protectStorageFile(name)
            return nil
        }
    }
    private func write(_ data: Data, to name: String) throws {
        if let error = storageReadErrors[name] { throw AIUsageError.invalid(error) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
