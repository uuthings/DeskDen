import Foundation
import CoreGraphics

/// Synthetic history only: exercise the production chart projection without
/// collecting device data, changing preferences, or drawing a foreground window.
enum WorkbenchChartPerformanceChecks {
    static func run() -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000), first = UUID(), second = UUID()
        func point(_ offset: TimeInterval, _ download: Double?, _ upload: Double? = nil, segment: UUID? = nil) -> DeviceHistoryPoint {
            .init(date: start.addingTimeInterval(offset), segment: segment ?? first, cpuPercent: download,
                  downloadBytesPerSecond: download, uploadBytesPerSecond: upload,
                  cpuTemperature: download, gpuTemperature: upload, memoryPercent: download)
        }
        let empty = DeviceHistoryChartData(points: [], kind: .network, minutes: 5, networkScale: true, now: start)
        check(!empty.hasReadings && empty.visible.isEmpty && empty.end == start, "empty chart preserves its unavailable state and reference time")
        check(empty.segments(series: 0, size: CGSize(width: 300, height: 100)).isEmpty, "empty chart cannot invent a zero-valued line")
        let gaps = [point(0, 10, 5), point(2, 20, 6), point(4, nil, 7), point(6, 30, 8),
                    point(8, 40, 9, segment: second), point(10, Double.nan, Double.infinity, segment: second), point(12, 50, 10, segment: second)]
        let data = DeviceHistoryChartData(points: gaps, kind: .network, minutes: 5, networkScale: true, now: start.addingTimeInterval(12))
        let download = data.segments(series: 0, size: CGSize(width: 300, height: 100))
        let upload = data.segments(series: 1, size: CGSize(width: 300, height: 100))
        check(download.map(\.count) == [2, 1, 1, 1], "missing values, sample discontinuities and nonfinite reads each break download lines")
        check(upload.map(\.count) == [4, 1, 1], "upload retains its independent valid samples across a missing download")
        check(download.flatMap { $0 }.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "nonfinite readings never become chart coordinates")
        check(data.maxValue == 1_000 && data.minValue == 0, "small network samples keep the minimum decimal axis of 1 KB/s")
        let both = DeviceHistoryChartData(points: [point(0, 1_000, 3_000_000)], kind: .network, minutes: 5, networkScale: true, now: start)
        // 现行规范 9.3: the axis tops out at 1, 2 or 5 × 10ⁿ decimal bytes per second.
        check(both.maxValue == 5_000_000, "network axis includes upload peaks and rounds up to a 1-2-5 decimal step")
        let thermal = DeviceHistoryChartData(points: [point(0, 46, 79)], kind: .thermal, minutes: 5, networkScale: false, now: start)
        // 现行规范 9.2: ten-degree bounds keep the labelled middle gridline on a whole degree.
        check(thermal.minValue == 40 && thermal.maxValue == 90, "thermal axis uses padded ten-degree bounds")
        let cpu = DeviceHistoryChartData(points: [point(0, 20), point(2, 140)], kind: .cpu, minutes: 5, networkScale: false, now: start.addingTimeInterval(2))
        check(cpu.maxValue == 100 && cpu.minValue == 0 && cpu.series[0].last?.location?.y == 0, "percentage charts keep their 0–100 range and clip oversized readings")
        var switched = point(20, 30)
        switched.selectedNetworkSegment = second
        let now = start.addingTimeInterval(50)
        let afterSwitch = DeviceHistoryChartData(points: [point(0, 20), switched], kind: .network, minutes: 5, networkScale: true, now: now)
        let cpuAfterSwitch = DeviceHistoryChartData(points: [point(0, 20), switched], kind: .cpu, minutes: 5, networkScale: false, now: now)
        check(afterSwitch.segments(series: 0, size: CGSize(width: 300, height: 100)).map(\.count) == [1, 1]
              && cpuAfterSwitch.segments(series: 0, size: CGSize(width: 300, height: 100)).map(\.count) == [2],
              "an interface selection breaks the selected network series without splitting CPU")
        check(afterSwitch.end == now && abs((afterSwitch.series[0].last?.location?.x ?? 0) - 0.9) < 0.000_001
              && afterSwitch.sample(near: now, kind: .network, tolerance: 2) == nil
              && afterSwitch.sample(near: start.addingTimeInterval(10), kind: .network, tolerance: 2) == nil,
              "the time axis keeps the unsampled tail and gap instead of snapping either to a previous reading")
        let history = (0...1800).map { index in point(Double(index * 2), Double(index % 79) * 100_000, Double(index % 37) * 10_000) }
        let historyEnd = start.addingTimeInterval(3600)
        let recent = DeviceHistoryChartData(points: history, kind: .network, minutes: 5, networkScale: true, now: historyEnd)
        check(recent.visible.count == 151 && recent.visible.first?.date == start.addingTimeInterval(3300), "one hour of retained samples yields exactly the last five minutes including the boundary")
        check(recent.segments(series: 0, size: CGSize(width: 300, height: 100)).first?.count == 151, "long-history projection keeps every measured visible sample")
        let oldPeak = DeviceHistoryChartData(points: [point(0, 1e12), point(302, 500)], kind: .network, minutes: 5, networkScale: true, now: start.addingTimeInterval(302))
        check(oldPeak.maxValue == 1_000 && oldPeak.visible.count == 1, "out-of-window peaks cannot inflate the current axis")
        let clock = ContinuousClock(), began = clock.now
        var plotted = 0
        for _ in 0..<200 {
            let projected = DeviceHistoryChartData(points: history, kind: .network, minutes: 5, networkScale: true, now: historyEnd)
            plotted += projected.segments(series: 0, size: CGSize(width: 600, height: 180)).reduce(0) { $0 + $1.count }
            plotted += projected.segments(series: 1, size: CGSize(width: 600, height: 180)).reduce(0) { $0 + $1.count }
        }
        let elapsed = began.duration(to: clock.now)
        check(plotted == 60_400, "repeated chart projections preserve both complete network series")
        check(elapsed < .seconds(2), "200 redraw projections of an hour-long history stay below a two-second aggregate budget")
        print("DETAIL chart projection: 200 iterations, 1801 retained samples, 151 visible samples, \(elapsed)")
        return (count, failures)
    }
}
