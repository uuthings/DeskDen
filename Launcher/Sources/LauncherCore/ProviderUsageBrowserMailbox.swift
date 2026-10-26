import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A user-owned, bounded mailbox. Every operation uses a no-follow directory descriptor.
public struct ProviderUsageBrowserMailbox: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory.standardizedFileURL }
    public func enqueue(_ request: ProviderUsageBrowserRequestMessage, at date: Date = Date()) throws {
        guard request.isValid(at: date) else { throw ProviderUsageBrowserProtocolError.invalidMessage }
        guard try requests(at: date).count < ProviderUsageBrowserProtocol.maximumPendingRequests else { throw ProviderUsageBrowserProtocolError.queueFull }
        try write(JSONEncoder().encode(request), named: request.requestID.uuidString + ".request.json")
    }
    public func requests(at date: Date = Date()) throws -> [ProviderUsageBrowserRequestMessage] {
        _ = try withDirectory { _ in () }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= 128 else { throw ProviderUsageBrowserProtocolError.queueFull }
        var result: [ProviderUsageBrowserRequestMessage] = []
        for name in names where name.hasSuffix(".request.json") && validName(name) {
            guard let data = try read(named: name) else { continue }
            guard let request = try? ProviderUsageBrowserJSON.decodeRequest(data), request.isValid(at: date) else {
                try remove(named: name)
                try remove(named: String(name.dropLast(".request.json".count)) + ".result.json")
                continue
            }
            if try read(named: request.requestID.uuidString + ".result.json") == nil { result.append(request) }
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }
    @discardableResult
    public func accept(_ response: ProviderUsageBrowserResultMessage, at date: Date = Date()) throws -> Bool {
        guard response.hasValidPayload else { throw ProviderUsageBrowserProtocolError.invalidMessage }
        // A cancelled request can legitimately finish after the App removed its mailbox.
        guard let data = try read(named: response.requestID.uuidString + ".request.json") else { return false }
        let request = try ProviderUsageBrowserJSON.decodeRequest(data)
        if request.expiresAt <= date.timeIntervalSince1970,
           request.isValid(at: Date(timeIntervalSince1970: request.expiresAt - 0.001)) { return false }
        guard response.isValid(for: request, at: date) else { throw ProviderUsageBrowserProtocolError.invalidMessage }
        try write(JSONEncoder().encode(response), named: response.requestID.uuidString + ".result.json")
        return true
    }
    public func result(for request: ProviderUsageBrowserRequestMessage, at date: Date = Date()) throws -> ProviderUsageBrowserResultMessage? {
        guard let data = try read(named: request.requestID.uuidString + ".result.json") else { return nil }
        let result = try ProviderUsageBrowserJSON.decodeResult(data)
        guard result.isValid(for: request, at: date) else { throw ProviderUsageBrowserProtocolError.invalidMessage }
        return result
    }
    public func finish(_ requestID: UUID) throws {
        try remove(named: requestID.uuidString + ".request.json")
        try remove(named: requestID.uuidString + ".result.json")
    }
    public func heartbeat(at date: Date = Date()) throws {
        try write(JSONSerialization.data(withJSONObject: ["version": 1, "observedAt": date.timeIntervalSince1970]), named: "heartbeat.json")
    }
    public func isConnected(at date: Date = Date()) -> Bool {
        guard let data = try? read(named: "heartbeat.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let observed = object["observedAt"] as? Double, observed.isFinite else { return false }
        let age = date.timeIntervalSince1970 - observed
        return age >= -5 && age <= 20
    }
    private func validName(_ value: String) -> Bool {
        if value == "heartbeat.json" { return true }
        for suffix in [".request.json", ".result.json"] where value.hasSuffix(suffix) {
            return UUID(uuidString: String(value.dropLast(suffix.count))) != nil
        }
        return false
    }
    private func normalizedPath(_ path: String) -> String {
        var value = path
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        #if os(macOS)
        // Foundation folds the system-owned /private/var alias only after a path exists.
        // Treat that OS alias consistently without accepting user-created symlinks.
        if value == "/private/var" || value.hasPrefix("/private/var/") { value.removeFirst("/private".count) }
        #endif
        return value
    }
    private func withDirectory<T>(_ action: (Int32) throws -> T) throws -> T {
        let manager = FileManager.default
        guard directory.isFileURL, normalizedPath(directory.resolvingSymlinksInPath().path) == normalizedPath(directory.path) else { throw ProviderUsageBrowserProtocolError.insecureMailbox }
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProviderUsageBrowserProtocolError.insecureMailbox }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else { throw ProviderUsageBrowserProtocolError.insecureMailbox }
        return try action(fd)
    }
    private func read(named name: String) throws -> Data? {
        guard validName(name) else { throw ProviderUsageBrowserProtocolError.invalidMessage }
        return try withDirectory { directoryFD in
            let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if fd < 0, errno == ENOENT { return nil }
            guard fd >= 0 else { throw ProviderUsageBrowserProtocolError.insecureMailbox }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                  info.st_size > 0, info.st_size <= ProviderUsageBrowserProtocol.maximumMessageBytes else { throw ProviderUsageBrowserProtocolError.insecureMailbox }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), count = 0
            while count < bytes.count {
                let n = bytes.withUnsafeMutableBytes { buffer in
                    providerRead(fd, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ProviderUsageBrowserProtocolError.io }; count += n
            }
            return Data(bytes)
        }
    }
    private func write(_ data: Data, named name: String) throws {
        guard validName(name), !data.isEmpty, data.count <= ProviderUsageBrowserProtocol.maximumMessageBytes else { throw ProviderUsageBrowserProtocolError.invalidMessage }
        try withDirectory { directoryFD in
            let temporary = "." + UUID().uuidString + ".tmp"
            let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ProviderUsageBrowserProtocolError.io }
            defer { close(fd); _ = unlinkat(directoryFD, temporary, 0) }
            var count = 0
            while count < data.count {
                let n = data.withUnsafeBytes { providerWrite(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ProviderUsageBrowserProtocolError.io }; count += n
            }
            guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw ProviderUsageBrowserProtocolError.io }
        }
    }
    private func remove(named name: String) throws {
        guard validName(name) else { throw ProviderUsageBrowserProtocolError.invalidMessage }
        try withDirectory { fd in
            if unlinkat(fd, name, 0) != 0 && errno != ENOENT { throw ProviderUsageBrowserProtocolError.io }
        }
    }
}
private func providerRead(_ fd: Int32, _ address: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, address, count)
    #else
    Glibc.read(fd, address, count)
    #endif
}
private func providerWrite(_ fd: Int32, _ address: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, address, count)
    #else
    Glibc.write(fd, address, count)
    #endif
}
