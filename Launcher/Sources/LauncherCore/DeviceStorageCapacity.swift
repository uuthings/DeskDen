import Foundation

/// Filesystem capacity is distinct from the storage device's advertised size.
/// Available space can include resources macOS may reclaim when needed; it is
/// not a promise that the application can or should delete those resources.
public struct DeviceStorageCapacity: Equatable, Sendable {
    public let total: UInt64
    public let immediatelyFree: UInt64
    public let available: UInt64
    public let reclaimableEstimate: UInt64?
    public let volumeName: String?
    public var used: UInt64 { total - available }
    public var percentUsed: Double { Double(used) / Double(total) * 100 }

    public init?(total: Int64?, immediatelyFree: Int64?, availableForImportantUsage: Int64?, volumeName: String? = nil) {
        guard let total, total > 0, let immediatelyFree, immediatelyFree >= 0, immediatelyFree <= total else { return nil }
        self.total = UInt64(total); self.immediatelyFree = UInt64(immediatelyFree); self.volumeName = volumeName
        // A fallback remains explicitly different from a measured zero estimate.
        if let value = availableForImportantUsage, value >= immediatelyFree, value <= total {
            available = UInt64(value); reclaimableEstimate = UInt64(value - immediatelyFree)
        } else {
            available = UInt64(immediatelyFree); reclaimableEstimate = nil
        }
    }

    public static func read(at url: URL) -> Self? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey]) else { return nil }
        // An unavailable estimate must not discard valid basic capacity values.
        let estimated = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return .init(total: values.volumeTotalCapacity.map(Int64.init),
                     immediatelyFree: values.volumeAvailableCapacity.map(Int64.init),
                     availableForImportantUsage: estimated?.volumeAvailableCapacityForImportantUsage,
                     volumeName: values.volumeName)
    }

    /// Disk and file capacities use decimal SI units, as in macOS storage views.
    /// GB and larger always keep one decimal, so values on one card share a
    /// precision; MB and smaller are whole numbers. Memory retains its
    /// separate binary formatter.
    public static func formatted(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var number = Double(bytes), index = 0
        while number >= 1_000 && index < units.count - 1 { number /= 1_000; index += 1 }
        func text(_ value: Double, _ unit: Int) -> String {
            unit >= 3 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        }
        // Rounding may reach 1000 of the current unit (999.96 GB, 999.6 MB);
        // show the next unit instead of a four-digit value.
        if index < units.count - 1, (Double(text(number, index)) ?? 0) >= 1_000 { number /= 1_000; index += 1 }
        return text(number, index) + " " + units[index]
    }
}
