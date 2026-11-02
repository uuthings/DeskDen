import Foundation
import IOKit
import LauncherCore

struct DeviceSensorReading: Sendable {
    var cpu: Double?
    var gpu: Double?
    var fans: [Double?]?
    var source = "AppleSMC · 只读"
    var cpuKeys: [String] = []
    var gpuKeys: [String] = []
}

/// Actor-owned, read-only transport. Only key metadata (9) and value reads (5) are sent.
/// AppleSMC is undocumented; supported keys are hardware-specific and never guessed on unknown chips.
/// Key identity reference: https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
enum DeviceSensorTransportResult {
    case response([UInt8])
    case temporaryFailure
    case disconnected
}

protocol DeviceSensorTransport: AnyObject {
    func open() -> Bool
    func close()
    func request(_ key: String, command: UInt8, size: UInt32) -> DeviceSensorTransportResult
}

/// The production transport has no write operation. Tests replace this object,
/// rather than asking IOKit to manufacture a missing key or a disconnected Mac.
final class DeviceSMCTransport: DeviceSensorTransport {
    private var connection: io_connect_t = 0
    func open() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }; defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
        return connection != 0
    }
    func close() {
        if connection != 0 { IOServiceClose(connection) }
        connection = 0
    }
    deinit { close() }
    func request(_ key: String, command: UInt8, size: UInt32) -> DeviceSensorTransportResult {
        guard connection != 0 else { return .disconnected }
        guard key.utf8.count == 4, command == 9 || command == 5 else { return .temporaryFailure }
        // The 80-byte AppleSMC user-client ABI has key at 0, key-info at 28, result at 40,
        // command at 42, and a bounded 32-byte payload at 48. No write command exists here.
        var input = [UInt8](repeating: 0, count: 80), output = input
        input.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
        }
        input[42] = command
        var outputSize = output.count
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, source.count, target.baseAddress, &outputSize)
            }
        }
        guard status == KERN_SUCCESS else { return .disconnected }
        // A per-key SMC result is not proof that the whole connection is lost,
        // nor do we guess undocumented result codes as permanent support flags.
        guard outputSize >= 80, output[40] == 0 else { return .temporaryFailure }
        return .response(output)
    }
}

final class DeviceSensorReader {
    private let transport: any DeviceSensorTransport
    private let clock: () -> TimeInterval
    private var connected = false
    private var connectionRetry = DeviceSensorRetryState()
    private var metadata: [String: (size: UInt32, type: String)] = [:]
    private var unsupported = Set<String>()
    private var keyRetries: [String: DeviceSensorRetryState] = [:]
    init(transport: any DeviceSensorTransport = DeviceSMCTransport(),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport; self.clock = clock
        _ = connect(at: clock())
    }
    deinit { transport.close() }
    private func connect(at now: TimeInterval) -> Bool {
        if connected { return true }
        guard connectionRetry.canAttempt(at: now) else { return false }
        connected = transport.open()
        if connected {
            // A new service connection can have different key metadata.
            metadata.removeAll(); unsupported.removeAll(); keyRetries.removeAll()
        } else { connectionRetry.failed(at: now) }
        return connected
    }
    private func request(_ key: String, command: UInt8, size: UInt32 = 0, at now: TimeInterval) -> [UInt8]? {
        guard connect(at: now) else { return nil }
        switch transport.request(key, command: command, size: size) {
        case .response(let bytes):
            guard bytes.count >= 80 else { return nil }
            connectionRetry.succeeded()
            return bytes
        case .temporaryFailure:
            connectionRetry.succeeded()
            return nil
        case .disconnected:
            connected = false; transport.close(); connectionRetry.failed(at: now)
            return nil
        }
    }
    private func failed(_ key: String, at now: TimeInterval) {
        keyRetries[key, default: .init()].failed(at: now)
    }
    func value(_ key: String) -> Double? {
        let now = clock()
        guard key.utf8.count == 4, connect(at: now), !unsupported.contains(key),
              keyRetries[key]?.canAttempt(at: now) ?? true else { return nil }
        if metadata[key] == nil {
            guard let response = request(key, command: 9, at: now) else { failed(key, at: now); return nil }
            let size = response.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self) }
            let typeCode = response.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self) }
            let type = String(bytes: [24,16,8,0].map { UInt8(truncatingIfNeeded: typeCode >> $0) }, encoding: .ascii) ?? ""
            guard let minimumSize = DeviceSensorValue.payloadSize(type: type) else {
                unsupported.insert(key); keyRetries[key] = nil; return nil
            }
            guard (UInt32(minimumSize)...32).contains(size) else { failed(key, at: now); return nil }
            metadata[key] = (size, type)
        }
        guard let meta = metadata[key], let response = request(key, command: 5, size: meta.size, at: now),
              let value = DeviceSensorValue.decode(type: meta.type, bytes: Array(response[48..<(48 + Int(meta.size))])) else {
            failed(key, at: now); return nil
        }
        keyRetries[key] = nil
        return value
    }
    func read(chip: String) -> DeviceSensorReading {
        var reading = DeviceSensorReading()
        let keys: (cpu: [String], gpu: [String])
        if chip.contains("Apple M2") {
            keys = (["Tp1h","Tp1t","Tp1p","Tp1l","Tp01","Tp05","Tp09","Tp0D","Tp0X","Tp0b","Tp0f","Tp0j"], ["Tg0f","Tg0j"])
        } else if chip.contains("Apple M1") {
            keys = (["Tp09","Tp0T","Tp01","Tp05","Tp0D","Tp0H","Tp0L","Tp0P","Tp0X","Tp0b"], ["Tg05","Tg0D","Tg0L","Tg0T"])
        } else if chip.contains("Apple M3") {
            keys = (["Te05","Te0L","Te0P","Te0S","Tf04","Tf09","Tf0A","Tf0B","Tf0D","Tf0E","Tf44","Tf49","Tf4A","Tf4B","Tf4D","Tf4E"], ["Tf14","Tf18","Tf19","Tf1A","Tf24","Tf28","Tf29","Tf2A"])
        } else if chip.contains("Apple M4") {
            keys = (["Te05","Te0S","Te09","Te0H","Tp01","Tp05","Tp09","Tp0D","Tp0V","Tp0Y","Tp0b","Tp0e"], ["Tg0K","Tg0L","Tg0d","Tg0e","Tg0j","Tg0k"])
        } else if chip.contains("Intel") {
            keys = (["TC0D","TC0P"], ["TG0D","TG0P"])
        } else { keys = ([], []) }
        func temperatures(_ list: [String], isCPU: Bool) -> [(String, Double)] {
            list.compactMap { key in
                guard let v = DeviceTemperatureValidation.celsius(value(key), chipName: chip, isCPU: isCPU) else { return nil }
                return (key, v)
            }
        }
        let cpu = temperatures(keys.cpu, isCPU: true), gpu = temperatures(keys.gpu, isCPU: false)
        reading.cpu = cpu.isEmpty ? nil : cpu.map(\.1).reduce(0,+) / Double(cpu.count)
        reading.gpu = gpu.isEmpty ? nil : gpu.map(\.1).reduce(0,+) / Double(gpu.count)
        reading.cpuKeys = cpu.map(\.0); reading.gpuKeys = gpu.map(\.0)
        if let count = value("FNum"), count >= 0, count <= 8, count.rounded() == count {
            reading.fans = (0..<Int(count)).map { index in
                guard let rpm = value("F\(index)Ac"), (0...20_000).contains(rpm) else { return nil }; return rpm
            }
        }
        if !connected { reading.source = "AppleSMC 传感器连接不可用，等待重试" }
        return reading
    }
}

/// Runs against an injected read-only transport, never the user's sensors.
enum DeviceSensorRecoveryChecks {
    static func run() -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        var now: TimeInterval = 100
        let transport = SensorFixtureTransport()
        let reader = DeviceSensorReader(transport: transport, clock: { now })
        transport.next = .temporaryFailure
        check(reader.value("TC0D") == nil, "temporary metadata failure stays unavailable without marking the key unsupported")
        let attempts = transport.commands.count
        now += 4
        check(reader.value("TC0D") == nil && transport.commands.count == attempts, "metadata retries wait for backoff rather than the next render")
        now += 1
        check(reader.value("TC0D") == 54.5, "a later scheduled sample recovers the same failed metadata key")
        transport.type = "other"
        check(reader.value("UNSP") == nil, "an acknowledged unsupported metadata encoding remains unavailable")
        let unsupportedAttempts = transport.commands.count
        now += 300
        check(reader.value("UNSP") == nil && transport.commands.count == unsupportedAttempts,
              "a confirmed unsupported encoding does not repeatedly call the transport")
        transport.next = .disconnected
        check(reader.value("TC0D") == nil, "a lost transport does not reuse a cached sensor number")
        let opens = transport.opens
        _ = reader.read(chip: "Apple M2 Max")
        check(transport.opens == opens, "one disconnected sample cannot reopen once for every sensor key")
        transport.canOpen = false; now += 5
        _ = reader.read(chip: "Apple M2 Max")
        check(transport.opens == opens + 1, "an unavailable service gets one bounded reconnect attempt per retry deadline")
        now += 14
        _ = reader.read(chip: "Apple M2 Max")
        check(transport.opens == opens + 1, "failed reconnection increases the shared connection backoff")
        transport.canOpen = true; transport.type = "flt "; now += 1
        check(reader.value("TC0D") == 60 && transport.opens == opens + 2,
              "reconnection refreshes metadata and resumes real samples after service recovery")
        check(reader.value("UNSP") == 60, "a new service connection rechecks earlier unsupported metadata")
        check(transport.commands.allSatisfy { $0 == 9 || $0 == 5 }, "sensor recovery still sends only metadata and value read commands")
        print("Device sensor recovery checks: \(count - failures)/\(count) passed")
        return (count, failures)
    }
}

private final class SensorFixtureTransport: DeviceSensorTransport {
    var opens = 0
    var canOpen = true
    var type = "sp78"
    var next: DeviceSensorTransportResult?
    var commands: [UInt8] = []
    func open() -> Bool { opens += 1; return canOpen }
    func close() {}
    func request(_ key: String, command: UInt8, size: UInt32) -> DeviceSensorTransportResult {
        commands.append(command)
        if let next { self.next = nil; return next }
        var response = [UInt8](repeating: 0, count: 80)
        if command == 9 {
            response.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: UInt32(type == "sp78" ? 2 : 4), toByteOffset: 28, as: UInt32.self)
                raw.storeBytes(of: type.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }, toByteOffset: 32, as: UInt32.self)
            }
        } else if type == "sp78" {
            response[48] = 0x36; response[49] = 0x80
        } else {
            let bits = Float(60).bitPattern
            for (index, shift) in [0,8,16,24].enumerated() { response[48 + index] = UInt8(truncatingIfNeeded: bits >> shift) }
        }
        return .response(response)
    }
}
