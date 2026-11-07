import Foundation
import Security
import Darwin
import LauncherCore

/// Runs the user's unmodified, signed Claude Code. Only its official control
/// channel handles authentication; Fangcun never opens credential stores and
/// never starts a login that would replace an existing login of another kind.
actor ClaudeSubscriptionService: ClaudeSubscriptionProviding {
    private let dataDirectory: URL
    private var cached: ClaudeSubscriptionReading?
    private var nextAttempt = Date.distantPast
    private var lastAttempt = Date.distantPast
    private var failures = 0
    private var flight: (id: UUID, task: Task<ClaudeSubscriptionReading, Never>)?
    private var loginFlight: Task<ClaudeSubscriptionReading, Never>?

    init(dataDirectory: URL) { self.dataDirectory = dataDirectory }

    func fetch() async -> ClaudeSubscriptionReading {
        if let loginFlight { return await loginFlight.value }
        if let flight { return await flight.task.value }
        if Date() < nextAttempt, let cached { return cached }
        lastAttempt = Date()
        let id = UUID(), directory = dataDirectory
        let task = Task { await Self.query(dataDirectory: directory) }
        flight = (id, task)
        let reading = await wait(task)
        if flight?.id == id {
            flight = nil
            if !task.isCancelled { remember(reading) }
        }
        return reading
    }

    /// A person-requested retry bypasses stale authentication/error caches while
    /// preserving an explicit rate-limit backoff and a short double-click guard.
    func refresh() async -> ClaudeSubscriptionReading {
        if let loginFlight { return await loginFlight.value }
        if let flight { return await flight.task.value }
        if let cached {
            if Date().timeIntervalSince(lastAttempt) < 5 { return cached }
            if case .unavailable(let message) = cached,
               message == ClaudeSubscriptionUsage.rateLimitedMessage, Date() < nextAttempt { return cached }
        }
        cached = nil; nextAttempt = .distantPast; failures = 0
        return await fetch()
    }

    /// Called only by an explicit login action. The official CLI opens its own
    /// login page; neither authorization codes nor tokens enter UI.
    func login() async -> ClaudeSubscriptionReading {
        let directory = dataDirectory
        return await interactive { await Self.signIn(dataDirectory: directory) }
    }

    /// Advanced: logs in to a Fangcun-only configuration and keeps the local login unchanged.
    func loginSeparately() async -> ClaudeSubscriptionReading {
        let directory = dataDirectory
        return await interactive { await Self.connectSeparately(dataDirectory: directory) }
    }

    func useLocalLogin() async -> ClaudeSubscriptionReading {
        let directory = dataDirectory
        return await interactive { await Self.leaveSeparateLogin(dataDirectory: directory) }
    }

    func usesSeparateLogin() -> Bool { (try? Self.dedicatedSelection(dataDirectory)) ?? false }

    /// Runs one login-related operation at a time in place of any background query.
    private func interactive(_ operation: @escaping @Sendable () async -> ClaudeSubscriptionReading) async -> ClaudeSubscriptionReading {
        if let loginFlight { return await wait(loginFlight) }
        flight?.task.cancel(); flight = nil
        let task = Task { await operation() }
        loginFlight = task
        let reading = await wait(task)
        loginFlight = nil
        if !task.isCancelled { remember(reading) }
        return reading
    }

    private func wait(_ task: Task<ClaudeSubscriptionReading, Never>) async -> ClaudeSubscriptionReading {
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func remember(_ reading: ClaudeSubscriptionReading) {
        cached = reading
        switch reading {
        case .ready: failures = 0
        case .loginRequired: failures = min(5, failures + 1)
        case .failed, .unavailable: failures = min(5, failures + 1)
        }
        nextAttempt = Date().addingTimeInterval(failures == 0 ? 60 : min(900, 60 * pow(2, Double(failures - 1))))
        // Cached snapshots keep their original observedAt, including on failures.
    }

    private static func query(dataDirectory: URL, separate: Bool? = nil) async -> ClaudeSubscriptionReading {
        guard !Task.isCancelled else { return .failed("Claude 额度读取已取消。") }
        let executable: URL
        switch ClaudeOfficialExecutable.discover() {
        case .found(let value): executable = value
        case .missing: return .unavailable("未找到官方 Claude Code。请安装官方客户端后登录会员。")
        case .untrusted: return .unavailable("无法验证本机 Claude Code 的官方签名，请使用官方 macOS 原生安装版。")
        }
        let configuration: URL?
        do { configuration = try selectedConfiguration(dataDirectory, separate: separate) }
        catch { return .failed(separateDirectoryMessage) }
        switch await ClaudeSubscriptionProcess.run(executable: executable, configuration: configuration, mode: .authentication) {
        case .authentication(.signedOut) where configuration != nil:
            return .loginRequired("方寸单独保存的 Claude 会员登录已退出或失效，请重新登录 Claude 会员。", .signIn)
        case .authentication(let identity):
            if let requirement = ClaudeSubscriptionUsage.loginRequirement(identity) { return requirement }
        case .failure(let reading): return reading
        default: return .failed("无法确认 Claude Code 的登录方式，请更新官方客户端后重试。")
        }
        guard !Task.isCancelled else { return .failed("Claude 额度读取已取消。") }
        switch await ClaudeSubscriptionProcess.run(executable: executable, configuration: configuration, mode: .usage) {
        case .usage(let reading), .failure(let reading): return reading
        default: return .failed("Claude 未返回额度，请更新官方客户端后重试。")
        }
    }

    /// Logs in to the configuration in use through the official claude.ai flow. A missing
    /// or expired membership login is completed; a login of another kind is explained and kept.
    private static func signIn(dataDirectory: URL) async -> ClaudeSubscriptionReading {
        let executable: URL
        switch ClaudeOfficialExecutable.discover() {
        case .found(let value): executable = value
        case .missing: return .unavailable("未找到官方 Claude Code。请先安装官方客户端。")
        case .untrusted: return .unavailable("无法验证 Claude Code 的官方签名，请安装官方 macOS 原生版后重试。")
        }
        let configuration: URL?
        do { configuration = try selectedConfiguration(dataDirectory, separate: nil) }
        catch { return .failed(separateDirectoryMessage) }
        switch await ClaudeSubscriptionProcess.run(executable: executable, configuration: configuration, mode: .authentication) {
        case .authentication(.signedOut), .authentication(.subscription): break
        case .authentication(let identity):
            return ClaudeSubscriptionUsage.loginRequirement(identity) ?? .failed("无法确认 Claude Code 的登录方式，请更新官方客户端后重试。")
        case .failure(let reading): return reading
        default: return .failed("无法确认 Claude Code 的登录方式，请更新官方客户端后重试。")
        }
        guard !Task.isCancelled else { return .failed("Claude 会员登录已取消。") }
        switch await ClaudeSubscriptionProcess.run(executable: executable, configuration: configuration, mode: .login) {
        case .completed: break
        case .failure(let reading): return reading
        default: return .loginRequired("Claude 会员授权尚未完成，请重新登录并在浏览器中完成授权。", .signIn)
        }
        guard !Task.isCancelled else { return .failed("Claude 会员登录已取消。") }
        return await query(dataDirectory: dataDirectory, separate: configuration != nil)
    }

    private static func connectSeparately(dataDirectory: URL) async -> ClaudeSubscriptionReading {
        let executable: URL
        switch ClaudeOfficialExecutable.discover() {
        case .found(let value): executable = value
        case .missing: return .unavailable("未找到官方 Claude Code。请先安装官方客户端。")
        case .untrusted: return .unavailable("无法验证 Claude Code 的官方签名，请安装官方 macOS 原生版后重试。")
        }
        let configuration = separateConfiguration(dataDirectory)
        do { try privateDirectory(dataDirectory, create: true); try privateDirectory(configuration, create: true) }
        catch { return .failed("无法建立方寸单独登录所需的目录，本机 Claude Code 登录未更改。") }
        switch await ClaudeSubscriptionProcess.run(executable: executable, configuration: configuration, mode: .login) {
        case .completed: break
        case .failure(.loginRequired(let message, _)): return .loginRequired(message, .separateLogin)
        case .failure(let reading): return reading
        default: return .loginRequired("Claude 会员授权尚未完成，请重新登录并完成官方网页授权。", .separateLogin)
        }
        guard !Task.isCancelled else { return .failed("Claude 会员登录已取消。") }
        // Verify the type before persisting the selector. Never choose a Console
        // login, and never alter the default CLI's settings or credential entry.
        guard case .authentication(.subscription) = await ClaudeSubscriptionProcess.run(executable: executable, configuration: configuration, mode: .authentication) else {
            return .loginRequired("尚未确认 Claude 会员登录，请重新登录并选择 Claude 订阅账号。", .separateLogin)
        }
        do {
            let marker = dataDirectory.appendingPathComponent("claude-subscription-selection.json")
            try regularFileIfPresent(marker)
            try ProtectedAtomicFile.write(Data("{\"version\":1,\"useDedicatedConfiguration\":true}".utf8), to: marker)
        } catch { return .failed("会员已完成官方登录，但无法保存连接选择，请重试。") }
        return await query(dataDirectory: dataDirectory, separate: true)
    }

    /// Returns to the local Claude Code login. The separate login is signed out through the
    /// official client first so no unused login stays behind; its directory is kept.
    private static func leaveSeparateLogin(dataDirectory: URL) async -> ClaudeSubscriptionReading {
        let configuration = separateConfiguration(dataDirectory)
        if case .found(let executable) = ClaudeOfficialExecutable.discover(), (try? privateDirectory(configuration, create: false)) != nil {
            _ = await ClaudeSubscriptionProcess.run(executable: executable, configuration: configuration, mode: .logout)
        }
        let marker = dataDirectory.appendingPathComponent("claude-subscription-selection.json")
        do {
            try regularFileIfPresent(marker)
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        } catch { return .failed("无法改回本机 Claude Code 登录，请稍后重试。") }
        guard !Task.isCancelled else { return .failed("已改回本机登录，额度读取已取消。") }
        return await query(dataDirectory: dataDirectory, separate: false)
    }

    private static let separateDirectoryMessage = "方寸单独保存的 Claude 登录目录不可用，请在「高级连接方式」中改回本机登录后重试。"
    private static func separateConfiguration(_ dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("ClaudeSubscription", isDirectory: true)
    }
    /// The separate configuration once it was chosen, otherwise nil for the local login.
    private static func selectedConfiguration(_ dataDirectory: URL, separate: Bool?) throws -> URL? {
        guard try separate ?? dedicatedSelection(dataDirectory) else { return nil }
        let configuration = separateConfiguration(dataDirectory)
        try privateDirectory(configuration, create: false)
        return configuration
    }

    private static func dedicatedSelection(_ directory: URL) throws -> Bool {
        let marker = directory.appendingPathComponent("claude-subscription-selection.json")
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        try regularFileIfPresent(marker)
        struct Selection: Decodable { let version: Int; let useDedicatedConfiguration: Bool }
        let descriptor = open(marker.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AIUsageError.invalid("selection") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1025) ?? Data()
        guard data.count <= 1024 else { throw AIUsageError.invalid("selection") }
        let value = try JSONDecoder().decode(Selection.self, from: data)
        guard value.version == 1 else { throw AIUsageError.invalid("selection") }
        return value.useDedicatedConfiguration
    }

    private static func regularFileIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1024 else { throw AIUsageError.invalid("selection") }
    }

    private static func privateDirectory(_ url: URL, create: Bool) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path), create {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw AIUsageError.invalid("directory") }
        if create { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }
}

private enum ClaudeOfficialExecutable {
    enum Discovery { case found(URL), missing, untrusted }
    static func discover() -> Discovery {
        let fm = FileManager.default
        var paths = [fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/claude" }
        var found = false, visited = Set<String>()
        for path in paths where visited.insert(path).inserted && fm.isExecutableFile(atPath: path) {
            found = true
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            var code: SecStaticCode?, requirement: SecRequirement?
            // Native/Homebrew-cask Claude Code builds are signed by Anthropic.
            // Do not execute a PATH shim or unsigned npm script to verify itself.
            let expression = "anchor apple generic and identifier \"com.anthropic.claude-code\" and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { continue }
            return .found(url)
        }
        return found ? .untrusted : .missing
    }
}

private enum ClaudeSubscriptionProcess {
    enum Mode: Sendable { case authentication, usage, login, logout }
    enum Result: Sendable {
        case authentication(ClaudeSubscriptionUsage.Authentication)
        case usage(ClaudeSubscriptionReading)
        case completed
        case failure(ClaudeSubscriptionReading)
    }
    static func run(executable: URL, configuration: URL?, mode: Mode) async -> Result {
        let task = Task.detached(priority: .utility) { execute(executable: executable, configuration: configuration, mode: mode) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private static func execute(executable: URL, configuration: URL?, mode: Mode) -> Result {
        let process = Process(), output = Pipe(), errors = Pipe(), input = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = ClaudeSubscriptionUsage.processEnvironment(ProcessInfo.processInfo.environment, configurationDirectory: configuration?.path)
        switch mode {
        case .authentication: process.arguments = ["--safe-mode", "auth", "status", "--json"]
        case .login: process.arguments = ["--safe-mode", "auth", "login", "--claudeai"]
        case .logout: process.arguments = ["--safe-mode", "auth", "logout"]
        case .usage:
            process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--no-session-persistence", "--safe-mode", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", ""]
        }
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        defer {
            for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting, errors.fileHandleForReading, errors.fileHandleForWriting] { try? handle.close() }
        }
        guard !Task.isCancelled else { return .failure(.failed("Claude 操作已取消。")) }
        do { try process.run() } catch { return .failure(.failed("无法启动官方 Claude Code，请检查安装后重试。")) }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        let stdout = output.fileHandleForReading.fileDescriptor, stderr = errors.fileHandleForReading.fileDescriptor
        _ = fcntl(stdout, F_SETFL, O_NONBLOCK); _ = fcntl(stderr, F_SETFL, O_NONBLOCK)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let limit = ClaudeSubscriptionUsage.maximumResponseBytes
        var pending = Data(), errorData = Data(), bytes = 0, result: Result?, usageRequested = false
        var closedInput = false, stoppedAt: Date?, exitedAt: Date?
        var stdoutEOF = false, stderrEOF = false
        let began = Date(), timeout: TimeInterval = mode == .login ? 180 : 30
        func closeInput() { if !closedInput { closedInput = true; try? input.fileHandleForWriting.close() } }
        func send(_ id: String, _ request: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id, "request": request])
            data.append(10); try input.fileHandleForWriting.write(contentsOf: data)
        }
        if mode == .usage {
            do { try send("deskden-init", ["subtype": "initialize"]) }
            catch { result = .failure(.failed("Claude 控制通道不可用，请更新官方客户端后重试。")) }
        } else { closeInput() }
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            if result == nil, Task.isCancelled { result = .failure(.failed("Claude 操作已取消。")) }
            if result == nil, Date().timeIntervalSince(began) > timeout {
                result = .failure(mode == .login ? .loginRequired("Claude 网页授权尚未完成，请重新登录并在浏览器中完成授权。", .signIn) : .failed("Claude 额度读取超时，请检查网络后稍后重试。"))
            }
            for fd in [stdout, stderr] {
                if (fd == stdout && stdoutEOF) || (fd == stderr && stderrEOF) { continue }
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count == 0 {
                        if fd == stdout { stdoutEOF = true } else { stderrEOF = true }
                        break
                    }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno != EAGAIN && errno != EWOULDBLOCK {
                            if fd == stdout { stdoutEOF = true } else { stderrEOF = true }
                            if result == nil { result = .failure(.failed("Claude 输出读取失败，请重试。")) }
                        }
                        break
                    }
                    bytes += count
                    if bytes > limit {
                        if result == nil { result = .failure(.failed("Claude 返回的数据超出读取上限，请更新官方客户端后重试。")) }
                        break
                    }
                    let chunk = Data(buffer.prefix(count))
                    if fd == stderr { errorData.append(chunk); continue }
                    if mode == .login || mode == .logout { errorData.append(chunk); continue }
                    pending.append(chunk)
                    if mode != .usage { continue }
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                        guard result == nil, let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              frame["type"] as? String == "control_response", let response = frame["response"] as? [String: Any],
                              let id = response["request_id"] as? String, ["deskden-init", "deskden-usage"].contains(id) else { continue }
                        guard response["subtype"] as? String == "success" else {
                            result = .failure(ClaudeSubscriptionUsage.failure(from: Data((response["error"] as? String ?? "").utf8))); break
                        }
                        if id == "deskden-init", !usageRequested {
                            usageRequested = true
                            do { try send("deskden-usage", ["subtype": "get_usage", "skip_behaviors": true]) }
                            catch { result = .failure(.failed("Claude 控制通道已断开，请重试。")) }
                        } else if id == "deskden-usage", usageRequested {
                            if let body = response["response"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: body) {
                                result = .usage(ClaudeSubscriptionUsage.decode(data, observedAt: Date()))
                            } else { result = .failure(.failed("Claude 额度响应不完整，请更新官方客户端后重试。")) }
                        }
                    }
                }
            }
            if result != nil {
                closeInput()
                if stoppedAt == nil { stoppedAt = Date() }
                if let stoppedAt, Date().timeIntervalSince(stoppedAt) > 0.5, process.isRunning { process.terminate() }
                if let stoppedAt, Date().timeIntervalSince(stoppedAt) > 2, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            if !process.isRunning {
                // A child can write its final JSON between the last EAGAIN and
                // the exit observation. Drain both pipes to EOF before decoding
                // auth output or returning, rather than treating exit as EOF.
                if stdoutEOF && stderrEOF { break }
                if exitedAt == nil { exitedAt = Date() }
                // A descendant retaining an inherited pipe must not keep the
                // app waiting forever after the direct CLI process has exited.
                if let exitedAt, Date().timeIntervalSince(exitedAt) > 1 {
                    if result == nil { result = .failure(.failed("Claude 未完整关闭输出，请稍后重试。")) }
                    break
                }
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        if let result { return result }
        if mode == .authentication, let auth = ClaudeSubscriptionUsage.authentication(pending) { return .authentication(auth) }
        if mode == .login || mode == .logout, process.terminationStatus == 0 { return .completed }
        return .failure(ClaudeSubscriptionUsage.failure(from: errorData))
    }
}
