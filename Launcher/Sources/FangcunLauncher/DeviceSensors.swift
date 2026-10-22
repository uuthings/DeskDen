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
final class DeviceSensorReader {
    private var connection: io_connect_t = 0
    private var metadata: [String: (size: UInt32, type: UInt32)] = [:]
    private var unsupported = Set<String>()
    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }; defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    private func request(_ key: String, command: UInt8, size: UInt32 = 0) -> [UInt8]? {
        guard connection != 0, key.utf8.count == 4, command == 9 || command == 5 else { return nil }
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
        guard status == KERN_SUCCESS, outputSize >= 80, output[40] == 0 else { return nil }
        return output
    }
    func value(_ key: String) -> Double? {
        if unsupported.contains(key) { return nil }
        if metadata[key] == nil {
            guard let response = request(key, command: 9) else { unsupported.insert(key); return nil }
            let size = response.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self) }
            let type = response.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self) }
            guard (1...32).contains(size) else { unsupported.insert(key); return nil }
            metadata[key] = (size, type)
        }
        guard let meta = metadata[key], let response = request(key, command: 5, size: meta.size) else { return nil }
        let type = String(bytes: [24,16,8,0].map { UInt8(truncatingIfNeeded: meta.type >> $0) }, encoding: .ascii) ?? ""
        return DeviceSensorValue.decode(type: type, bytes: Array(response[48..<(48 + Int(meta.size))]))
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
        if connection == 0 { reading.source = "AppleSMC 传感器连接不可用" }
        return reading
    }
}
