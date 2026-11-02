import AppKit
import CoreText
import SwiftUI
import LauncherCore

struct WorkbenchHomeDeviceCard: View {
    @ObservedObject var model: DeviceStatusModel
    var navigate: (WorkbenchRoute) -> Void
    private let palette = HomeFluidPalette.light
    private var snapshot: DeviceSnapshot { model.snapshot }
    private var thermal: DeviceThermalPresentation { snapshot.thermalPresentation(rule: model.temperatureRule) }

    var body: some View {
        VStack(spacing: 4) {
            Button { navigate(.device) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        WorkbenchContentIcon(symbol: "laptopcomputer", size: 17)
                        Text("这台 Mac").font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 4)
                        WorkbenchHomeStatus(title: statusTitle, color: statusColor)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(snapshot.deviceName).font(.system(size: 17, weight: .medium)).lineLimit(1)
                        Text(snapshot.chipName).font(.system(size: 12)).foregroundStyle(HomeFluidPalette.secondary).lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Image(systemName: "thermometer.medium").font(.system(size: 14, weight: .light)).foregroundStyle(HomeFluidPalette.secondary)
                            temperature("CPU", snapshot.cpuTemperature, level: thermal.cpuLevel)
                            Text("/").foregroundStyle(HomeFluidPalette.muted.opacity(0.65))
                            temperature("GPU", snapshot.gpuTemperature, level: thermal.gpuLevel)
                            Spacer(minLength: 0)
                        }.font(.system(size: 12)).help(thermal.detail)
                            .accessibilityElement(children: .combine).accessibilityIdentifier("home-temperature-readout")
                        HStack(spacing: 5) {
                            Label(snapshot.battery.map { String(format: "%.0f%%", $0.percent) } ?? "—", systemImage: snapshot.battery?.isPluggedIn == true ? "battery.100.bolt" : "battery.100")
                                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                                .foregroundStyle(batteryColor)
                                .accessibilityIdentifier("home-battery-percent")
                            Spacer(minLength: 4)
                            Text(batteryStatus).font(.system(size: 11)).foregroundStyle(HomeFluidPalette.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    memory
                }
                .accessibilityElement(children: .contain).accessibilityIdentifier("home-device-content")
                .padding(14).frame(maxWidth: .infinity).frame(height: 230)
                .foregroundStyle(HomeFluidPalette.ink)
                .background(WorkbenchHomeSurface())
                .contentShape(RoundedRectangle(cornerRadius: 15))
            }
            .buttonStyle(WorkbenchHomeCardButtonStyle())
            .accessibilityLabel("查看设备状态")
            .accessibilityValue(snapshot.deviceName + "，" + snapshot.chipName + "，" + statusTitle
                + "，CPU " + (snapshot.cpuTemperature.map { String(format: "%.0f 度", $0) } ?? "读数不可用")
                + "，GPU " + (snapshot.gpuTemperature.map { String(format: "%.0f 度", $0) } ?? "读数不可用")
                + "，" + batteryStatus + "，内存 " + (snapshot.memory.map { DeviceFormat.capacity($0.used) + " / " + DeviceFormat.capacity($0.total) } ?? "读数不可用") + "，" + memoryPressure)
            .accessibilityIdentifier("home-device-detail")
            .accessibilityElement(children: .contain)
            HStack(spacing: 8) {
                shortcut("设备", route: .device)
                shortcut("清理", route: .cleaning)
                shortcut("用量", route: .ai)
            }.padding(.horizontal, 12).frame(height: 48)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.32), lineWidth: 1))
        .accessibilityIdentifier("home-device-metrics")
    }

    private func shortcut(_ title: String, route: WorkbenchRoute) -> some View {
        Button { navigate(route) } label: {
            VStack(spacing: 4) {
                WorkbenchNavigationIcon(route: route, size: 18)
                Text(title).font(.system(size: 11))
            }.frame(maxWidth: .infinity).frame(height: 43)
                .foregroundStyle(.white.opacity(0.9))
        }.buttonStyle(WorkbenchHomeCardButtonStyle(radius: 8, highlight: .white.opacity(0.10)))
            .accessibilityLabel("打开" + route.title)
    }
    private func temperature(_ name: String, _ value: Double?, level: DeviceThermalLevel) -> some View {
        HStack(spacing: 3) {
            Text(name).foregroundStyle(HomeFluidPalette.secondary)
            Text(value.map { String(format: "%.0f°", $0) } ?? "—")
                .fontWeight(.medium).monospacedDigit()
                .foregroundStyle(level == .normal ? HomeFluidPalette.ink : level.color(palette: palette))
        }
    }
    private var memory: some View {
        let memory = snapshot.memory
        return VStack(spacing: 7) {
            HStack(spacing: 5) {
                Text("运行内存").foregroundStyle(HomeFluidPalette.secondary)
                Text(memory.map { DeviceFormat.capacity($0.used) + " / " + DeviceFormat.capacity($0.total) } ?? "—")
                    .fontWeight(.medium).monospacedDigit().lineLimit(1)
                Spacer(minLength: 0)
                Text(memoryPressure).foregroundStyle(DeviceAppearance.pressure(memory?.pressure, palette: palette)).lineLimit(1)
            }.font(.system(size: 10.5))
            WBProgress(value: (memory?.percent ?? 0) / 100,
                       color: DeviceAppearance.pressure(memory?.pressure, palette: palette), height: 4)
                .accessibilityLabel("运行内存已用比例，" + (memory.map { UsagePercentage.text($0.percent) } ?? "读数不可用"))
                .accessibilityIdentifier("home-memory-progress")
        }.accessibilityElement(children: .combine).accessibilityIdentifier("home-memory-usage")
    }
    private var memoryPressure: String {
        switch snapshot.memory?.pressure {
        case .normal: "压力正常"
        case .warning: "压力偏高"
        case .critical: "压力很高"
        default: "压力未提供"
        }
    }
    private var statusTitle: String {
        if thermal.level == .warning || thermal.level == .critical { return thermal.title }
        if snapshot.memory?.pressure == .critical { return "内存压力高" }
        if snapshot.memory?.pressure == .warning { return "内存压力偏高" }
        if snapshot.performanceSampledAt == nil { return "读取中" }
        if snapshot.memory?.pressure == .normal && thermal.level == .normal { return "运行正常" }
        return "部分读数缺失"
    }
    private var statusColor: Color {
        if thermal.level == .critical || snapshot.memory?.pressure == .critical { return palette.critical }
        if thermal.level == .warning || snapshot.memory?.pressure == .warning { return palette.warning }
        return statusTitle == "运行正常" ? HomeFluidPalette.green : HomeFluidPalette.muted
    }
    private var batteryColor: Color {
        guard let battery = snapshot.battery else { return HomeFluidPalette.muted }
        return DeviceAppearance.battery(battery.percent, pluggedIn: battery.isPluggedIn, palette: palette)
    }
    private var batteryStatus: String {
        snapshot.battery.map { $0.isCharging ? "正在充电" : $0.isPluggedIn ? "已连接电源" : "使用电池" } ?? "电源读数不可用"
    }
}

struct WorkbenchHomeStorageCard: View {
    @ObservedObject var model: DeviceStatusModel
    @ObservedObject var cleaning: SpaceCleaningModel
    var action: () -> Void
    private let palette = HomeFluidPalette.light
    private var disk: DeviceDiskSnapshot? { model.snapshot.disk }
    private var total: UInt64? { disk?.total ?? cleaning.diskTotal }
    private var available: UInt64? { disk?.available ?? cleaning.diskAvailable }
    private var immediatelyFree: UInt64? { disk?.immediatelyFree ?? (disk == nil ? cleaning.diskImmediatelyFree : nil) }
    private var reclaimable: UInt64? { disk?.reclaimableEstimate ?? (disk == nil ? cleaning.diskReclaimableEstimate : nil) }
    private var used: UInt64? {
        guard let total, let available, available <= total else { return nil }
        return total - available
    }
    private var percent: Double? {
        guard let total, total > 0, let used else { return nil }
        return Double(used) / Double(total) * 100
    }
    private var scanIsCurrent: Bool {
        cleaning.lastScanDate != nil && !cleaning.requiresRescan && cleaning.scanMode == .cleanup &&
            cleaning.screen == .results && !cleaning.isBusy
    }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    WorkbenchContentIcon(device: .storage, size: 17)
                    Text("磁盘空间").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    Text(disk?.name ?? cleaning.diskVolumeName ?? "本机磁盘")
                        .font(.system(size: 11)).foregroundStyle(HomeFluidPalette.muted).lineLimit(1)
                }.frame(height: 22)
                Text("已用空间").font(.system(size: 11)).foregroundStyle(HomeFluidPalette.secondary).padding(.top, 13)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    WorkbenchHomeValue(value: DeviceFormat.storage(used), size: 26)
                    Text("/ " + DeviceFormat.storage(total)).font(.system(size: 11)).foregroundStyle(HomeFluidPalette.secondary)
                    Spacer(minLength: 4)
                    Text(UsagePercentage.text(percent)).font(.system(size: 19)).monospacedDigit()
                }.padding(.top, 5)
                capacityBar.padding(.top, 12)
                HStack(alignment: .top, spacing: 6) {
                    capacityLegend("已用", value: used, color: palette.usageColor(forPercent: percent))
                    capacityLegend("立即可用", value: immediatelyFree, color: HomeFluidPalette.green.opacity(0.20))
                    capacityLegend("系统可回收", value: reclaimable, color: HomeFluidPalette.green.opacity(0.34))
                }.padding(.top, 12)
                Spacer(minLength: 6)
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("可用空间").font(.system(size: 11)).foregroundStyle(HomeFluidPalette.secondary)
                        WorkbenchHomeValue(value: DeviceFormat.storage(available), size: 18)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(scanIsCurrent ? "建议整理项占用" : "可整理空间")
                            .font(.system(size: 11)).foregroundStyle(HomeFluidPalette.secondary)
                        if scanIsCurrent {
                            WorkbenchHomeValue(value: DeviceFormat.storage(cleaning.recommendedAllocatedBytes), size: 18)
                                .foregroundStyle(HomeFluidPalette.green)
                        } else {
                            Text(cleaning.screen == .scanning ? "扫描中" : cleaning.requiresRescan ? "重新扫描后查看" : "扫描后查看")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(HomeFluidPalette.green)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("home-storage-content")
            .padding(14).frame(maxWidth: .infinity).frame(height: 261)
            .foregroundStyle(HomeFluidPalette.ink)
            .background(WorkbenchHomeSurface())
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(WorkbenchHomeCardButtonStyle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-open-cleaning")
        .accessibilityLabel("打开空间清理")
        .accessibilityValue("磁盘已用 " + DeviceFormat.storage(used) + " / " + DeviceFormat.storage(total)
            + "，" + UsagePercentage.text(percent) + "，可用 " + DeviceFormat.storage(available)
            + "，立即可用 " + DeviceFormat.storage(immediatelyFree) + "，系统可回收估算 " + DeviceFormat.storage(reclaimable))
        .help("可用空间包含 macOS 可按需回收的估算。系统可回收不是方寸建议删除的文件；整理项占用仅来自已完成扫描，实际释放量以系统读数为准。")
    }
    private var capacityBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(HomeFluidPalette.green.opacity(0.14))
                if let total, total > 0, let used {
                    HStack(spacing: 1) {
                        Rectangle().fill(palette.usageColor(forPercent: percent))
                            .frame(width: max(0, geometry.size.width * Double(used) / Double(total)))
                        if let reclaimable, reclaimable > 0 {
                            Rectangle().fill(HomeFluidPalette.green.opacity(0.34))
                                .frame(width: max(0, geometry.size.width * Double(reclaimable) / Double(total) - 1))
                        }
                    }
                }
            }.clipShape(Capsule())
        }.frame(height: 7)
            .accessibilityLabel("磁盘已用" + UsagePercentage.text(percent))
            .accessibilityIdentifier("home-storage-progress")
    }
    private func capacityLegend(_ title: String, value: UInt64?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 4, height: 4)
                Text(title).font(.system(size: 10.5)).lineLimit(1)
            }
            Text(DeviceFormat.storage(value)).font(.system(size: 11)).monospacedDigit().foregroundStyle(HomeFluidPalette.muted).lineLimit(1).padding(.leading, 8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkbenchHomeNetworkCard: View {
    @ObservedObject var model: DeviceStatusModel
    @ObservedObject var context: WorkbenchContextModel
    var action: () -> Void
    private var network: DeviceNetworkSnapshot { model.snapshot.allNetwork }
    private var hasReading: Bool {
        guard let down = network.downloadBytesPerSecond, let up = network.uploadBytesPerSecond else { return false }
        return down.isFinite && up.isFinite && down >= 0 && up >= 0
    }
    private var todayTraffic: String {
        let summary = model.trafficSummary(period: .day, scope: .all)
        return summary.coveredSeconds > 0 ? DeviceTrafficDisplay.adaptive(summary.totalBytes) : "—"
    }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    WorkbenchContentIcon(device: .network, size: 17)
                    Text("实时网络").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    WorkbenchHomeStatus(title: hasReading ? "采集中" : model.snapshot.sampledAt == nil ? "读取中" : "暂无读数",
                                        color: hasReading ? HomeFluidPalette.green : HomeFluidPalette.muted)
                }.frame(height: 22)
                HStack(alignment: .top) {
                    rate("下载", value: network.downloadBytesPerSecond, alignment: .leading)
                    Spacer(minLength: 8)
                    rate("上传", value: network.uploadBytesPerSecond, alignment: .trailing)
                }.padding(.top, 16)
                Spacer(minLength: 12)
                WorkbenchHomeNetworkTrend(points: model.history, context: context)
                    .frame(height: 62).accessibilityIdentifier("home-network-trend")
                Spacer(minLength: 14)
                HStack(spacing: 4) {
                    Text("最近 60 秒")
                    Spacer(minLength: 4)
                    Text("今日已记录")
                    Text(todayTraffic).fontWeight(.medium).foregroundStyle(HomeFluidPalette.ink).monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(HomeFluidPalette.muted)
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("home-network-content")
            .padding(14).frame(maxWidth: .infinity).frame(height: 261)
            .foregroundStyle(HomeFluidPalette.ink)
            .background(WorkbenchHomeSurface())
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(WorkbenchHomeCardButtonStyle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-network-detail")
        .accessibilityLabel("查看网络监控")
        .accessibilityValue("本机全部流量，下载 " + DeviceFormat.rate(network.downloadBytesPerSecond)
            + "，上传 " + DeviceFormat.rate(network.uploadBytesPerSecond) + "，今日已记录 " + todayTraffic)
        .help("本机全部流量。曲线显示最近 60 秒实际下载与上传合计，采样缺口不补线；今日累计仅含已记录时段。")
    }
    private func rate(_ title: String, value: Double?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(HomeFluidPalette.secondary)
            WorkbenchHomeValue(value: DeviceFormat.rate(value), size: 25)
        }
    }
}

private struct WorkbenchHomeNetworkTrend: View {
    let points: [DeviceHistoryPoint]
    @ObservedObject var context: WorkbenchContextModel
    @State private var hover: CGPoint?
    private var end: Date { max(points.last?.date ?? .distantPast, Date()) }
    private var visible: [DeviceHistoryPoint] { points.filter { $0.date <= end && end.timeIntervalSince($0.date) <= 60 } }
    private func value(_ point: DeviceHistoryPoint) -> Double? {
        guard let down = point.allDownloadBytesPerSecond, let up = point.allUploadBytesPerSecond,
              down.isFinite, up.isFinite, down >= 0, up >= 0 else { return nil }
        let sum = down + up
        return sum.isFinite ? sum : nil
    }
    var body: some View {
        GeometryReader { geometry in
            let values = visible
            let end = self.end
            let maximum = max(1_024, (values.compactMap(value).max() ?? 0) * 1.12)
            Canvas { canvas, size in
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height - 1))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                canvas.stroke(baseline, with: .color(HomeFluidPalette.green.opacity(0.13)), lineWidth: 1)
                var segments: [[CGPoint]] = [], current: [CGPoint] = []
                var previous: UUID?
                for point in values {
                    guard let sample = value(point), let segment = point.allNetworkSegment else {
                        if !current.isEmpty { segments.append(current) }
                        current = []; previous = nil; continue
                    }
                    if previous != segment && !current.isEmpty { segments.append(current); current = [] }
                    let location = CGPoint(x: size.width * (1 - end.timeIntervalSince(point.date) / 60),
                                           y: (size.height - 2) * (1 - min(1, sample / maximum)) + 1)
                    current.append(location); previous = segment
                }
                if !current.isEmpty { segments.append(current) }
                for segment in segments {
                    guard let first = segment.first, let last = segment.last else { continue }
                    var line = Path(); line.move(to: first)
                    for curve in DeviceTrendCurve.segments(segment) {
                        line.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
                    }
                    if segment.count == 1 {
                        canvas.fill(Path(ellipseIn: CGRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3)), with: .color(HomeFluidPalette.green))
                    } else {
                        var area = line
                        area.addLine(to: CGPoint(x: last.x, y: size.height))
                        area.addLine(to: CGPoint(x: first.x, y: size.height)); area.closeSubpath()
                        canvas.fill(area, with: .color(HomeFluidPalette.green.opacity(0.075)))
                        canvas.stroke(line, with: .color(HomeFluidPalette.green), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                }
                if let hover {
                    var guide = Path(); guide.move(to: CGPoint(x: hover.x, y: 0)); guide.addLine(to: CGPoint(x: hover.x, y: size.height))
                    canvas.stroke(guide, with: .color(HomeFluidPalette.green.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
            .overlay {
                if values.compactMap(value).isEmpty {
                    Text("等待有效网络采样").font(.system(size: 11)).foregroundStyle(HomeFluidPalette.muted)
                }
            }
            .overlay(alignment: .topLeading) {
                if let hover, let nearest = nearest(to: hover, width: geometry.size.width, end: end, points: values) {
                    Text(context.time(nearest.date, seconds: true) + "  " + DeviceFormat.rate(value(nearest)))
                        .font(.system(size: 10)).monospacedDigit().padding(5)
                        .foregroundStyle(HomeFluidPalette.ink)
                        .background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 5))
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase { case .active(let point): hover = point; case .ended: hover = nil }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("本机全部上下行，最近 60 秒真实曲线，共 \(visible.compactMap(value).count) 个有效采样；缺口不补线")
    }
    private func nearest(to position: CGPoint, width: CGFloat, end: Date, points: [DeviceHistoryPoint]) -> DeviceHistoryPoint? {
        let target = end.addingTimeInterval(-60 * (1 - min(1, max(0, position.x / max(1, width)))))
        return points.filter { value($0) != nil }.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
    }
}

struct WorkbenchHomeWelcome: View {
    @ObservedObject var context: WorkbenchContextModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(spacing: 0) {
                Spacer(minLength: 5)
                WorkbenchHomeWelcomeOutline().stroke(.white.opacity(0.94), lineWidth: 0.8)
                    .frame(maxWidth: 230).frame(height: 63)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("欢迎你").accessibilityIdentifier("home-welcome")
                Button { context.showClock = true } label: {
                    VStack(spacing: 9) {
                        Text(dateText(timeline.date)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.89))
                        Text(context.time(timeline.date)).font(.system(size: 46, weight: .light)).monospacedDigit()
                            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                    }.frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(ClickablePlainButtonStyle()).padding(.top, 28)
                    .accessibilityIdentifier("home-date-time")
                    .accessibilityHint(context.zoneTitle + "，点击设置日期与城市")
                Button { context.showWeather = true } label: {
                    weather(at: timeline.date)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.91))
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .padding(.horizontal, 3).padding(.vertical, 7)
                        .contentShape(Rectangle())
                }.buttonStyle(ClickablePlainButtonStyle()).padding(.top, 19)
                    .accessibilityIdentifier("home-weather")
                    .help(context.weather?.issue ?? "查看天气与设置城市；" + context.zoneTitle)
                Spacer(minLength: 5)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = context.dateContext.timeZone
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }
    @ViewBuilder private func weather(at date: Date) -> some View {
        if let snapshot = context.weather?.snapshot {
            HStack(spacing: 6) {
                Image(systemName: weatherSymbol(snapshot.weatherCode, isDay: snapshot.isDay)).font(.system(size: 16, weight: .light))
                ViewThatFits(in: .horizontal) {
                    Text(weatherText(snapshot, at: date)).lineLimit(1)
                    VStack(spacing: 2) {
                        Text(snapshot.city.name + " · " + context.temperature(snapshot.temperatureCelsius))
                        Text(snapshot.conditionDescription + (context.weather?.freshness == .stale ? " · 上次天气" : ""))
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "cloud.sun").font(.system(size: 16, weight: .light))
                Text(context.weatherStatusTitle)
            }
        }
    }
    private func weatherText(_ snapshot: WeatherSnapshot, at date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = context.dateContext.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let forecast = snapshot.dailyForecast?.first { $0.dayKey == formatter.string(from: date) }
        var parts = [snapshot.city.name + " · " + context.temperature(snapshot.temperatureCelsius), snapshot.conditionDescription]
        if let low = forecast?.lowCelsius, let high = forecast?.highCelsius {
            parts.append(context.temperature(low) + " / " + context.temperature(high))
        }
        if context.weather?.freshness == .stale { parts.append("上次天气") }
        return parts.joined(separator: "  ")
    }
}

private struct WorkbenchHomeWelcomeOutline: Shape {
    nonisolated(unsafe) private static let outlines: CGPath = {
        let font = NSFont(name: "Kaiti SC", size: 56) ?? NSFont(name: "STKaiti", size: 56) ?? NSFont.systemFont(ofSize: 56, weight: .light)
        let text = NSAttributedString(string: "欢迎你", attributes: [.font: font, .kern: 7])
        let line = CTLineCreateWithAttributedString(text as CFAttributedString)
        let result = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = Array(repeating: CGGlyph(), count: count)
            var positions = Array(repeating: CGPoint.zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            for index in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                result.addPath(glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
            }
        }
        return result
    }()
    func path(in rect: CGRect) -> Path {
        let source = Self.outlines, bounds = source.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        let scale = min(1, rect.width / bounds.width, rect.height / bounds.height)
        let x = rect.midX - bounds.midX * scale
        let y = rect.midY + bounds.midY * scale
        return Path(source).applying(CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: x, ty: y))
    }
}

private struct WorkbenchHomeValue: View {
    let value: String
    var size: CGFloat
    private var parts: [Substring] { value.split(separator: " ", maxSplits: 1) }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.first.map(String.init) ?? "—").font(.system(size: size, weight: .regular))
            if parts.count > 1 { Text(String(parts[1])).font(.system(size: 11)).foregroundStyle(HomeFluidPalette.secondary) }
        }.monospacedDigit().fixedSize(horizontal: true, vertical: false)
    }
}

private struct WorkbenchHomeStatus: View {
    var title: String
    var color: Color
    var body: some View {
        Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            .foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct WorkbenchHomeCardButtonStyle: ButtonStyle {
    var radius: CGFloat = 15
    var highlight: Color = .white.opacity(0.22)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: radius).fill(configuration.isPressed ? HomeFluidPalette.green.opacity(0.075) : hovering ? highlight : .clear).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(hovering ? 0.95 : 0), lineWidth: 1).allowsHitTesting(false))
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .onHover { hovering = $0 }.clickableCursor()
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
    }
}
