import AppKit
import Carbon
import Darwin
import ImageIO
import LauncherCore
import UniformTypeIdentifiers

enum ApplicationNames {
    // The launcher has a Chinese UI even when an application's own display name follows English.
    static let chinese: [String:String] = ["com.apple.finder":"访达", "com.apple.Notes":"备忘录", "com.apple.iCal":"日历", "com.apple.mail":"邮件", "com.apple.Terminal":"终端", "com.apple.Preview":"预览", "com.apple.Photos":"照片", "com.apple.reminders":"提醒事项", "com.apple.shortcuts":"快捷指令", "com.apple.Music":"音乐", "com.apple.MobileSMS":"信息", "com.apple.calculator":"计算器", "com.apple.systempreferences":"系统设置", "com.apple.ActivityMonitor":"活动监视器", "com.apple.TextEdit":"文本编辑", "com.apple.VoiceMemos":"语音备忘录", "com.apple.iBooksX":"图书", "com.apple.keychainaccess":"钥匙串访问", "com.tencent.xinWeChat":"微信", "com.google.Chrome":"Chrome"]
    static func name(for url:URL) -> String {
        if let identifier = Bundle(url:url)?.bundleIdentifier, let name = chinese[identifier] { return name }
        return FileManager.default.displayName(atPath:url.path).replacingOccurrences(of:".app",with:"",options:[.anchored,.backwards])
    }
    /// Search aliases come from the installed bundle rather than a guessed
    /// translation table. Keep separate lines so initials never cross names.
    static func searchKeywords(for url:URL) -> String {
        let bundle = Bundle(url:url)
        let fields = ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"]
        var names = fields.compactMap { bundle?.infoDictionary?[$0] as? String }
        names += fields.compactMap { bundle?.localizedInfoDictionary?[$0] as? String }
        if let executable = bundle?.executableURL?.lastPathComponent { names.append(executable) }
        names.append(url.deletingPathExtension().lastPathComponent)
        var seen = Set<String>()
        return names.compactMap { value -> String? in
            let name = value.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 256, !name.contains("/"), !name.contains("\\"), !name.contains("\0"), !name.contains("\n"), !name.contains("\r"), seen.insert(SearchEntry.normalize(name)).inserted else {return nil}
            return name
        }.joined(separator:"\n")
    }
}

actor ApplicationCatalog {
    func scan(extraRoots: [String] = []) -> [LaunchTarget] {
        let manager = FileManager.default
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] + extraRoots.filter { $0.hasPrefix("/") && !$0.contains("\0") }
        var locations = Set<String>()
        for path in roots {
            let root = URL(fileURLWithPath: path)
            guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey,.isPackageKey], options: [.skipsHiddenFiles,.skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if url.pathExtension.lowercased() == "app" { locations.insert(url.resolvingSymlinksInPath().standardizedFileURL.path); walker.skipDescendants() }
                else if walker.level > 3 { walker.skipDescendants() }
            }
        }
        locations.insert("/System/Library/CoreServices/Finder.app")
        return locations.sorted().compactMap { path in
            guard manager.fileExists(atPath: path), let bundle = Bundle(path: path) else { return nil }
            let name = ApplicationNames.name(for:URL(fileURLWithPath:path))
            let keywords = ApplicationNames.searchKeywords(for:URL(fileURLWithPath:path))
            return LaunchTarget(kind: .app, name: name, location: path, bundleIdentifier: bundle.bundleIdentifier, keywords: keywords)
        }
    }
    func metadata(for applications: [LaunchTarget], existing: [String:ApplicationMetadata], now: Date = Date()) -> [String:ApplicationMetadata] {
        var result = existing
        for app in applications {
            var record = result[app.id] ?? ApplicationMetadata(addedAt: now)
            // Finder's package creation date is the locally available installation-time signal.
            if let created = try? URL(fileURLWithPath: app.location).resourceValues(forKeys: [.creationDateKey]).creationDate { record.installedAt = created }
            result[app.id] = record
        }
        return result
    }
}

struct CommandResult: Sendable { let status: Int32; let output: String; let timedOut: Bool }

/// Streams and caps captured output while continuing to drain the pipe.
private final class ProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var timeout = false
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; data.append(value.prefix(max(0, 262_144-data.count))) }
    func markTimeout() { lock.lock(); timeout = true; lock.unlock() }
    func snapshot(_ status: Int32) -> CommandResult { lock.lock(); defer { lock.unlock() }; return CommandResult(status: status, output: String(decoding: data, as: UTF8.self), timedOut: timeout) }
}

enum CommandRunner {
    static func run(executable: String, arguments: [String], directory: URL? = nil, timeout: TimeInterval = 30) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process(), pipe = Pipe(), capture = ProcessCapture()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            pipe.fileHandleForWriting.closeFile()
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let began = Date()
            var stoppedAt: Date?
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                if Date().timeIntervalSince(began) > timeout, stoppedAt == nil, process.isRunning {
                    capture.markTimeout(); process.terminate(); stoppedAt = Date()
                }
                if let stoppedAt, Date().timeIntervalSince(stoppedAt) > 2, process.isRunning { kill(process.processIdentifier, SIGKILL) }
                let count = read(fd, &buffer, buffer.count)
                if count > 0 { capture.append(Data(buffer.prefix(count))); continue }
                if !process.isRunning { break }
                usleep(10_000)
            }
            process.waitUntilExit()
            pipe.fileHandleForReading.closeFile()
            return capture.snapshot(process.terminationStatus)
        }.value
    }
}

@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var down = false
    private var identifier: UInt32 = 0
    private(set) var shortcut: BindingHotKey?
    var choice:HotKeyChoice? {HotKeyChoice.allCases.first {$0.bindingHotKey == shortcut}}
    var pressed: (() -> Void)?
    func register(_ newChoice:HotKeyChoice)->OSStatus {register(newChoice.bindingHotKey)}
    func register(_ newShortcut:BindingHotKey)->OSStatus {
        guard (try? newShortcut.validate()) != nil else {return OSStatus(paramErr)}
        if shortcut == newShortcut, reference != nil { return noErr }
        if handler == nil {
            var kinds = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == 0x46434C52 else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                    guard id.id == owner.identifier else { return }
                    if GetEventKind(event) == UInt32(kEventHotKeyReleased) { owner.down = false }
                    else if !owner.down { owner.down = true; owner.pressed?() }
                }
                return noErr
            }, kinds.count, &kinds, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { return result }
        }
        var modifiers:UInt32=0
        if newShortcut.control {modifiers |= UInt32(controlKey)}
        if newShortcut.option {modifiers |= UInt32(optionKey)}
        if newShortcut.shift {modifiers |= UInt32(shiftKey)}
        if newShortcut.command {modifiers |= UInt32(cmdKey)}
        var candidate: EventHotKeyRef?
        let next = identifier &+ 1
        let status = RegisterEventHotKey(UInt32(newShortcut.keyCode), modifiers, EventHotKeyID(signature: 0x46434C52, id: next), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &candidate)
        guard status == noErr else { return status }
        if let reference { UnregisterEventHotKey(reference) }
        reference = candidate; identifier = next; shortcut = newShortcut; down = false
        return noErr
    }
    func unregister() { if let reference { UnregisterEventHotKey(reference) }; if let handler { RemoveEventHandler(handler) }; reference = nil; handler = nil; shortcut = nil; down = false }
}

/// Maintains all per-binding registrations as a transaction: a conflict cannot remove a working shortcut.
@MainActor
final class GlobalBindingHotKeys {
    /// Reserved action ID shares the same atomic transaction as target shortcuts.
    static let applicationViewKey = "__applications"
    static let workbenchKey = "__workbench"
    private struct Registration { let reference: EventHotKeyRef; let identifier: UInt32 }
    private var registrations: [BindingHotKey:Registration] = [:]
    private var keysByIdentifier: [UInt32:String] = [:]
    private var handler: EventHandlerRef?
    private var down = Set<UInt32>()
    private var nextIdentifier: UInt32 = 0
    private(set) var shortcuts: [String:BindingHotKey] = [:]
    var pressed: ((String) -> Void)?

    func register(_ candidates: [String:BindingHotKey]) -> OSStatus {
        guard Set(candidates.values).count == candidates.count,
              candidates.keys.allSatisfy({ KeyboardLayout.keys.contains($0) || $0 == Self.applicationViewKey || $0 == Self.workbenchKey }),
              candidates.values.allSatisfy({ (try? $0.validate()) != nil }) else { return OSStatus(paramErr) }
        if handler == nil, !candidates.isEmpty {
            let kinds = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == 0x46434248 else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    let owner = Unmanaged<GlobalBindingHotKeys>.fromOpaque(context).takeUnretainedValue()
                    guard let key = owner.keysByIdentifier[id.id] else { return }
                    if GetEventKind(event) == UInt32(kEventHotKeyReleased) { owner.down.remove(id.id) }
                    else if owner.down.insert(id.id).inserted { owner.pressed?(key) }
                }
                return noErr
            }, kinds.count, kinds, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { return result }
        }
        var additions: [BindingHotKey:Registration] = [:]
        for shortcut in Set(candidates.values) where registrations[shortcut] == nil {
            var modifiers: UInt32 = 0
            if shortcut.control { modifiers |= UInt32(controlKey) }
            if shortcut.option { modifiers |= UInt32(optionKey) }
            if shortcut.shift { modifiers |= UInt32(shiftKey) }
            if shortcut.command { modifiers |= UInt32(cmdKey) }
            nextIdentifier &+= 1
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers, EventHotKeyID(signature: 0x46434248, id: nextIdentifier), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            guard status == noErr, let reference else {
                for value in additions.values { UnregisterEventHotKey(value.reference) }
                return status == noErr ? OSStatus(paramErr) : status
            }
            additions[shortcut] = Registration(reference: reference, identifier: nextIdentifier)
        }
        let requested = Set(candidates.values)
        for (shortcut, registration) in registrations where !requested.contains(shortcut) { UnregisterEventHotKey(registration.reference) }
        registrations = registrations.filter { requested.contains($0.key) }
        registrations.merge(additions) { _, new in new }
        keysByIdentifier = Dictionary(uniqueKeysWithValues: candidates.compactMap { key, shortcut in registrations[shortcut].map { ($0.identifier, key) } })
        down.formIntersection(keysByIdentifier.keys)
        shortcuts = candidates
        return noErr
    }
    func unregister() {
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        if let handler { RemoveEventHandler(handler) }
        registrations = [:]; keysByIdentifier = [:]; down = []; shortcuts = [:]; handler = nil
    }
}

enum TargetResolver {
    static func url(for target: LaunchTarget) -> URL? {
        if target.kind == .web { return try? WebURLTemplate(target.location).resolvedURL() }
        guard target.kind.isFileSystem else { return URL(string: target.location) }
        if let data = target.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI,.withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale), FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let url = URL(fileURLWithPath: target.location)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    static func target(kind: TargetKind, url: URL) -> LaunchTarget {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let name = kind == .app ? ApplicationNames.name(for:canonical) : FileManager.default.displayName(atPath:canonical.path)
        let keywords = kind == .app ? ApplicationNames.searchKeywords(for:canonical) : canonical.deletingPathExtension().lastPathComponent
        return LaunchTarget(kind: kind, name: name, location: canonical.path, bundleIdentifier: kind == .app ? Bundle(url: canonical)?.bundleIdentifier : nil, bookmark: try? canonical.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), keywords:keywords)
    }
}

@MainActor
final class TargetLauncher {
    func launch(_ target: LaunchTarget, webVariables: [String:String] = [:]) async throws {
        try target.validate()
        switch target.kind {
        case .app:
            guard let url = TargetResolver.url(for: target) else { throw LauncherError.unavailable("找不到这个应用，请重新选择。") }
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
            }
        case .web:
            let url = try WebURLTemplate(target.location).resolvedURL(values: webVariables)
            guard NSWorkspace.shared.open(url) else { throw LauncherError.unavailable("系统未能打开网页，绑定与查询已保留。") }
        case .file, .folder:
            guard let url = TargetResolver.url(for: target) else { throw LauncherError.unavailable("目标已移动或不可访问，请重新选择。") }
            guard NSWorkspace.shared.open(url) else { throw LauncherError.unavailable("系统未能打开目标，绑定与查询已保留。") }
        case .shortcut:
            let result = try await CommandRunner.run(executable: "/usr/bin/shortcuts", arguments: ["run", target.location], timeout: 120)
            guard !result.timedOut, result.status == 0 else { throw LauncherError.unavailable(result.timedOut ? "快捷指令运行超时。可在快捷指令中检查。" : "快捷指令未完成，请在快捷指令应用中检查授权或内容。") }
        case .shell:
            guard let url = TargetResolver.url(for: target) else { throw LauncherError.unavailable("找不到脚本，请重新选择。") }
            let result = try await CommandRunner.run(executable: "/bin/sh", arguments: [url.path], directory: url.deletingLastPathComponent(), timeout: 120)
            guard !result.timedOut, result.status == 0 else { throw LauncherError.unavailable(result.timedOut ? "脚本运行超时，已请求停止。" : "脚本退出码为 \(result.status)。请检查脚本后重试。") }
        case .tool: throw LauncherError.unavailable("方寸工具将在对应工作台模块验收后开放。")
        }
    }
}

/// Fetches icons from the website itself, without sending the saved URL's query or variable values.
enum WebsiteIconService {
    static let maximumSourceBytes = 2_097_152

    static func normalizedIcon(from data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 16_000_000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw LauncherError.invalidTarget("请选择不超过 2 MB、4096 × 4096 像素的有效图片。")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw LauncherError.invalidTarget("无法读取这张图片，请选择其他图片。")
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 131_072 else {
            throw LauncherError.invalidTarget("无法缩小这张图片，请选择其他图片。")
        }
        return output as Data
    }

    static func fetch(for source: String) async -> Data? {
        guard let template = try? WebURLTemplate(source) else { return nil }
        let origin = template.originURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let fallback = origin.appendingPathComponent("favicon.ico")
            if let data = try? await read(fallback, session: session, origin: origin, limit: maximumSourceBytes),
               let icon = try? normalizedIcon(from: data) { return icon }
            try Task.checkCancellation()
            let page = try await read(origin, session: session, origin: origin, limit: 524_288)
            let html = String(decoding: page, as: UTF8.self)
            for candidate in iconCandidates(in: html, origin: origin).prefix(4) {
                try Task.checkCancellation()
                if let data = try? await read(candidate, session: session, origin: origin, limit: maximumSourceBytes),
                   let icon = try? normalizedIcon(from: data) { return icon }
            }
        } catch { return nil }
        return nil
    }

    private static func read(_ url: URL, session: URLSession, origin: URL, limit: Int) async throws -> Data {
        guard WebsiteRedirectPolicy.permits(url, for: origin) else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.setValue("image/*,text/html;q=0.5", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request, delegate: WebsiteRedirectPolicy(origin: origin))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= limit else { throw URLError(.badServerResponse) }
        var data = Data(); data.reserveCapacity(min(limit, 8192))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    private static func iconCandidates(in html: String, origin: URL) -> [URL] {
        guard let tags = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive]) else { return [] }
        let source = html as NSString
        var candidates: [URL] = []
        for match in tags.matches(in: html, range: NSRange(location: 0, length: source.length)).prefix(100) {
            let tag = source.substring(with: match.range)
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  rel.split(whereSeparator: \.isWhitespace).contains(where: { $0 == "icon" || $0 == "apple-touch-icon" }),
                  let href = attribute("href", in: tag)?.replacingOccurrences(of: "&amp;", with: "&"),
                  let url = URL(string: href, relativeTo: origin)?.absoluteURL,
                  WebsiteRedirectPolicy.permits(url, for: origin), !candidates.contains(url) else { continue }
            candidates.append(url)
        }
        return candidates
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b" + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        let source = tag as NSString
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound { return source.substring(with: match.range(at: index)) }
        return nil
    }
}

private final class WebsiteRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL
    private let lock = NSLock()
    private var redirects = 0
    init(origin: URL) { self.origin = origin }
    static func permits(_ url: URL, for origin: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return ["http", "https"].contains(scheme ?? "") && url.host?.lowercased() == origin.host?.lowercased()
            && url.port == origin.port && url.user == nil && url.password == nil
            && !(origin.scheme?.lowercased() == "https" && scheme == "http")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let count = redirects; lock.unlock()
        completionHandler(count <= 3 && request.url.map({ Self.permits($0, for: origin) }) == true ? request : nil)
    }
}
