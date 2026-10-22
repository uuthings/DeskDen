import AppKit
import SwiftUI
import LauncherCore

enum DeviceAppearance {
    static let cool = Color(red: 0.56, green: 0.68, blue: 0.74)
    static let charging = Color(red: 0.43, green: 0.85, blue: 0.65)
    static func pressure(_ value: DevicePressure?, palette: ThemePalette = .init()) -> Color { value == .critical ? palette.critical : value == .warning ? palette.warning : value == nil || value == .unknown ? palette.muted : palette.accent }
    static func storage(_ value: Double?, palette: ThemePalette = .init()) -> Color { (value ?? 0) >= 90 ? palette.critical : (value ?? 0) >= 80 ? palette.warning : value == nil ? palette.muted : palette.accent }
}
struct DeviceCardSurface: View {
    var editing = false
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchMaterialSurface(kind: .card, radius: 15)
            .overlay {
                if editing { RoundedRectangle(cornerRadius: 15).strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            }
    }
}
struct DeviceCardContent: View {
    let card: DeviceCardPreference
    let snapshot: DeviceSnapshot
    let history: [DeviceHistoryPoint]
    let editing: Bool
    var trafficSummary: DeviceTrafficSummary?
    var budget = DeviceTrafficBudget()
    var expanded = false
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(width: max(0, geometry.size.width - 28), height: max(0, geometry.size.height - 60))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: card.id.symbol).font(.system(size: 15, weight: .light)).frame(width: 16, height: 18)
                    Text(card.id.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: editing && card.id.supportsMeterStyle ? 47 : 24)
                }.frame(height: 22)
                content(size: size).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.padding(14).frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }.foregroundStyle(palette.text).background(DeviceCardSurface(editing: editing)).environment(\.workbenchDeviceExpanded, expanded)
    }
    @ViewBuilder private func content(size: CGSize) -> some View {
        switch card.id {
        case .cpu: cpu(size)
        case .network: network(size)
        case .traffic: traffic(size)
        case .thermal: thermal(size)
        case .profile: profile(size)
        case .memory: memory(size)
        case .storage: storage(size)
        case .processes: processes(size)
        }
    }
    private func measure(_ label: String, value: String, size: CGFloat = 28) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1).frame(height: 16)
            DeviceReading(value: value, size: expanded && size >= 28 ? 30 : size).frame(height: 32, alignment: .leading)
        }.frame(height: 52, alignment: .topLeading)
    }
    private func cpu(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                measure("当前使用率", value: DeviceFormat.percent(snapshot.cpuPercent))
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    Text("用户进程 \(DeviceFormat.percent(snapshot.cpuUserPercent))")
                    Text("系统 \(DeviceFormat.percent(snapshot.cpuSystemPercent))")
                }.font(.system(size: size.width < 240 ? 10 : 11)).foregroundStyle(palette.secondary).monospacedDigit().lineLimit(1)
            }.frame(height: 52)
            DeviceHistoryChart(points: history, kind: .cpu, minutes: 5, compact: true).frame(maxHeight: .infinity)
        }
    }
    private func network(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                measure("↓ 下载", value: DeviceFormat.rate(snapshot.network.downloadBytesPerSecond), size: size.width < 280 ? 23 : 28)
                Spacer(minLength: 0)
                measure("↑ 上传", value: DeviceFormat.rate(snapshot.network.uploadBytesPerSecond), size: size.width < 280 ? 23 : 28)
            }.frame(height: 52)
            DeviceHistoryChart(points: history, kind: .network, minutes: 5, compact: true).frame(maxHeight: .infinity)
        }
    }
    private func traffic(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                trafficSpeed("实时下载", symbol: "arrow.down", value: snapshot.network.downloadBytesPerSecond, trailing: false)
                trafficSpeed("实时上传", symbol: "arrow.up", value: snapshot.network.uploadBytesPerSecond, trailing: true)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("今日已记录").font(.system(size: 11)).foregroundStyle(palette.secondary)
                Spacer(minLength: 8)
                DeviceReading(value: trafficSummary.flatMap { $0.coveredSeconds > 0 ? DeviceTrafficDisplay.adaptive($0.totalBytes) : nil } ?? "—", size: 20)
            }.padding(.top, 11).overlay(alignment: .top) { palette.line.frame(height: 1) }
            VStack(alignment: .leading, spacing: 4) {
                Label((trafficSummary?.coveredSeconds ?? 0) > 0 ? "本机连续采集时段" : "暂无采集记录", systemImage: "dot.radiowaves.left.and.right")
                Text("关闭与睡眠期间不补记")
            }.font(.system(size: 11)).foregroundStyle(palette.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func trafficSpeed(_ label: String, symbol: String, value: Double?, trailing: Bool) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 5) {
            Label(label, systemImage: symbol).font(.system(size: 11)).foregroundStyle(palette.secondary)
            DeviceReading(value: DeviceFormat.rate(value), size: expanded ? 27 : 25)
        }.frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
    private func thermal(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            DeviceTemperatureReadings(snapshot: snapshot, size: expanded ? 28 : 26).frame(height: 49)
            DeviceFanRows(snapshot: snapshot, paired: true)
            VStack(alignment: .leading, spacing: 7) {
                DevicePowerLine(snapshot: snapshot, compact: true)
                Text("热状态\(DeviceFormat.thermal(snapshot.thermalState)) · 系统自动调节")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
            }
        }
    }
    private var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
    }
    private var displayResolution: String {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return "分辨率暂无读数" }
        let display = CGDirectDisplayID(number.uint32Value)
        let width = CGDisplayPixelsWide(display), height = CGDisplayPixelsHigh(display)
        guard width > 0, height > 0 else { return "分辨率暂无读数" }
        return "\(width) × \(height)"
    }
    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.deviceName).font(.system(size: 23, weight: .medium)).lineLimit(1)
            Text(snapshot.chipName).font(.system(size: 12)).foregroundStyle(palette.secondary).lineLimit(1)
        }
    }
    private func profileMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(label).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func profile(_ size: CGSize) -> some View {
        Group {
            if size.width > 520 && size.height < 120 {
                HStack(alignment: .center, spacing: 16) {
                    identity.frame(width: min(230, max(160, size.width * 0.25)), alignment: .leading)
                    profileMetric("\(snapshot.physicalCPUCount) 核", "CPU 核心")
                    profileMetric(DeviceFormat.capacity(snapshot.memory?.total), "统一内存")
                    profileMetric(DeviceFormat.capacity(snapshot.disk?.total), "内置存储")
                    profileMetric(systemVersion, "操作系统")
                }.frame(maxHeight: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: size.height > 260 ? 23 : 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        identity
                        Text(snapshot.modelIdentifier).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                    }.padding(.top, size.height > 260 ? 8 : 0)
                    if size.width > 450 {
                        HStack(alignment: .top, spacing: 24) {
                            profileFacts(includeSystem: false)
                            profileFacts(includeSystem: true)
                        }
                    } else { profileFacts(includeSystem: nil) }
                    Spacer(minLength: 0)
                    if size.height > 300 {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(NSScreen.main?.localizedName ?? "显示器信息不可用")
                            Text(displayResolution)
                        }.font(.system(size: 11)).foregroundStyle(palette.muted)
                    }
                }
            }
        }
    }
    private func profileFacts(includeSystem: Bool?) -> some View {
        VStack(spacing: includeSystem == nil ? 15 : 9) {
            if includeSystem != true {
                DeviceCompactFact(label: "CPU 核心", value: "\(snapshot.physicalCPUCount) 核")
                DeviceCompactFact(label: "核心构成", value: snapshot.performanceCores.flatMap { p in snapshot.efficiencyCores.map { "\(p) 性能 + \($0) 能效" } } ?? "暂无读数")
                DeviceCompactFact(label: "统一内存", value: DeviceFormat.capacity(snapshot.memory?.total))
            }
            if includeSystem != false {
                DeviceCompactFact(label: "内置存储", value: DeviceFormat.capacity(snapshot.disk?.total))
                DeviceCompactFact(label: "操作系统", value: systemVersion)
                DeviceCompactFact(label: "显示器", value: NSScreen.main?.localizedName ?? "暂无读数")
            }
        }.frame(maxWidth: .infinity)
    }
    private func memoryReading(size: CGFloat = 28) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("已用内存").font(.system(size: 11)).foregroundStyle(palette.secondary).frame(height: 16)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                DeviceReading(value: DeviceFormat.capacity(snapshot.memory?.used), size: size)
                Text("/ \(DeviceFormat.capacity(snapshot.memory?.total))").font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
            }.frame(height: 32, alignment: .leading)
        }.frame(height: 52, alignment: .topLeading)
    }
    private func memory(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if card.meter == .ring {
                HStack(spacing: 10) { DeviceUsageRing(value: snapshot.memory?.percent, tone: DeviceAppearance.pressure(snapshot.memory?.pressure, palette: palette)).frame(width: 36, height: 36); memoryReading(size: size.width < 240 ? 22 : 28) }.frame(height: 52)
                Color.clear.frame(height: 5)
            } else {
                memoryReading()
                DeviceUsageBar(value: snapshot.memory?.percent, tone: DeviceAppearance.pressure(snapshot.memory?.pressure, palette: palette))
            }
            VStack(spacing: 6) {
                DeviceCompactFact(label: "可用内存", value: DeviceFormat.capacity(snapshot.memory?.available))
                DeviceCompactFact(label: "内存压力", value: DeviceFormat.pressure(snapshot.memory?.pressure ?? .unknown))
                DeviceCompactFact(label: "压缩内存", value: DeviceFormat.capacity(snapshot.memory?.compressed))
                DeviceCompactFact(label: "交换已用", value: DeviceFormat.capacity(snapshot.memory?.swapUsed))
                if size.height > 200 { DeviceCompactFact(label: "App 内存", value: DeviceFormat.capacity(snapshot.memory?.application)) }
                if size.height > 230 { DeviceCompactFact(label: "缓存文件", value: DeviceFormat.capacity(snapshot.memory?.cached)) }
            }
        }
    }
    private func storage(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if card.meter == .ring {
                HStack(spacing: 10) {
                    DeviceUsageRing(value: snapshot.disk?.percent, tone: DeviceAppearance.storage(snapshot.disk?.percent, palette: palette)).frame(width: 36, height: 36)
                    measure("已用空间", value: DeviceFormat.capacity(snapshot.disk?.used))
                }.frame(height: 52)
            } else {
                measure("\(snapshot.disk?.name ?? "磁盘") · 已用空间", value: DeviceFormat.capacity(snapshot.disk?.used))
                DeviceUsageBar(value: snapshot.disk?.percent, tone: DeviceAppearance.storage(snapshot.disk?.percent, palette: palette))
            }
            VStack(spacing: 6) {
                DeviceCompactFact(label: "可用空间", value: DeviceFormat.capacity(snapshot.disk?.available))
                DeviceCompactFact(label: "总容量", value: DeviceFormat.capacity(snapshot.disk?.total))
            }
            HStack {
                Text(snapshot.disk?.fileSystem ?? "暂无读数")
                Spacer(minLength: 8)
                Text((snapshot.disk?.percent).map { "已用 \(String(format: "%.1f", $0))%" } ?? "等待有效采样")
            }.font(.system(size: 11)).foregroundStyle(palette.muted).monospacedDigit()
            if size.height > 200 { DeviceCompactFact(label: "读取", value: DeviceFormat.rate(snapshot.disk?.readBytesPerSecond)) }
            if size.height > 230 { DeviceCompactFact(label: "写入", value: DeviceFormat.rate(snapshot.disk?.writeBytesPerSecond)) }
        }
    }
    private func processes(_ size: CGSize) -> some View {
        let columns = size.width > 530 ? 2 : 1
        let rows = max(1, Int((size.height - 24 + 4) / 24))
        let items = Array(DeviceProcess.filtered(snapshot.processes, query: "", sort: .cpu).prefix(rows * columns))
        return HStack(alignment: .top, spacing: 24) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(spacing: 4) {
                    HStack { Text("名称"); Spacer(); Text("CPU 占用") }.font(.system(size: 10)).foregroundStyle(palette.muted).frame(height: 16).padding(.bottom, 4)
                    ForEach(Array(items.dropFirst(column * rows).prefix(rows))) { p in
                        HStack(spacing: 8) {
                            DeviceProcessIcon(path: p.executablePath).frame(width: 18, height: 18)
                            Text(p.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 3)
                            Text(DeviceFormat.percent(p.cpuPercent)).monospacedDigit().frame(minWidth: 37, alignment: .trailing)
                        }.font(.system(size: 11)).frame(height: 20)
                    }
                    if items.isEmpty && column == 0 { Text("正在读取可访问的进程").font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .leading) }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}
struct DeviceReading: View {
    @Environment(\.workbenchPalette) private var palette
    let value: String
    var size: CGFloat = 28
    private var parts: (String, String) {
        if value.hasSuffix("%") { return (String(value.dropLast()), "%") }
        if let index = value.lastIndex(of: " ") { return (String(value[..<index]), String(value[value.index(after: index)...])) }
        return (value, "")
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(parts.0).font(.system(size: size, weight: .regular))
            if !parts.1.isEmpty { Text(parts.1).font(.system(size: 11)).foregroundStyle(palette.secondary) }
        }.monospacedDigit().lineLimit(1).fixedSize().accessibilityElement(children: .ignore).accessibilityLabel(value)
    }
}
struct DeviceCompactFact: View {
    @Environment(\.workbenchPalette) private var palette
    let label: String, value: String
    @Environment(\.workbenchDeviceExpanded) private var expanded
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(palette.muted).lineLimit(1)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(palette.secondary).lineLimit(1).truncationMode(.middle)
        }.font(.system(size: 11)).monospacedDigit().frame(height: 16)
    }
}
struct DeviceUsageBar: View {
    @Environment(\.workbenchPalette) private var palette
    let value: Double?
    var tone: Color? = nil
    var body: some View {
        GeometryReader { g in
            Capsule().fill(palette.progressTrack).overlay(alignment: .leading) {
                if let value { Capsule().fill((tone ?? palette.accent).opacity(0.85)).frame(width: g.size.width * min(1, max(0, value / 100))) }
            }
        }.frame(height: 5).accessibilityLabel(value.map { "已用 \(Int($0))%" } ?? "暂无读数")
    }
}
struct DeviceUsageRing: View {
    @Environment(\.workbenchPalette) private var palette
    let value: Double?
    var tone: Color? = nil
    var body: some View {
        ZStack {
            Circle().stroke(palette.progressTrack, lineWidth: 5)
            if let value { Circle().trim(from: 0, to: min(1, max(0, value / 100))).stroke(tone ?? palette.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90)) }
            Text(value.map { "\(Int($0.rounded()))%" } ?? "—").font(.system(size: 13)).monospacedDigit()
        }.padding(3)
    }
}
struct DeviceTemperatureReadings: View {
    @Environment(\.workbenchPalette) private var palette
    let snapshot: DeviceSnapshot
    var size: CGFloat = 30
    var body: some View {
        HStack(spacing: 16) {
            reading("CPU 温度", snapshot.cpuTemperature, trailing: false)
            reading("GPU 温度", snapshot.gpuTemperature, trailing: true)
        }
    }
    private func reading(_ name: String, _ value: Double?, trailing: Bool) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 4) {
            Text(name).font(.system(size: 11)).foregroundStyle(palette.secondary).frame(height: 16)
            DeviceReading(value: value.map { String(format: "%.0f °C", $0) } ?? "— °C", size: size)
        }.frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}
struct DeviceFanRows: View {
    @Environment(\.workbenchPalette) private var palette
    let snapshot: DeviceSnapshot
    var paired = false
    var body: some View {
        Group {
        if paired, snapshot.fanRPM?.isEmpty != true {
            let fans = snapshot.fanRPM ?? [nil, nil]
            HStack(spacing: 12) {
                ForEach(Array(fans.prefix(2).enumerated()), id: \.offset) { index, rpm in
                    VStack(alignment: index == 1 ? .trailing : .leading, spacing: 3) {
                        Text(fans.count == 2 ? (index == 0 ? "左风扇" : "右风扇") : "风扇 \(index + 1)").font(.system(size: 11)).foregroundStyle(palette.secondary)
                        DeviceReading(value: rpm.map { "\(Int($0.rounded()).formatted()) RPM" } ?? "— RPM", size: 13)
                    }.frame(maxWidth: .infinity, alignment: index == 1 ? .trailing : .leading)
                }
            }
        } else {
        VStack(spacing: 6) {
            if let fans = snapshot.fanRPM, fans.isEmpty {
                DeviceCompactFact(label: "散热方式", value: "无风扇")
            } else {
                let fans = snapshot.fanRPM ?? [nil, nil]
                ForEach(Array(fans.prefix(2).enumerated()), id: \.offset) { index, rpm in
                    HStack(spacing: 8) {
                        Image(systemName: "fan").font(.system(size: 13, weight: .light)).frame(width: 14)
                        Text(fans.count == 2 ? (index == 0 ? "左风扇" : "右风扇") : "风扇 \(index + 1)").font(.system(size: 11))
                        Spacer()
                        DeviceReading(value: rpm.map { "\(Int($0.rounded()).formatted()) RPM" } ?? "— RPM", size: 15)
                    }.foregroundStyle(palette.secondary).frame(height: 20)
                }
            }
        }
        }
        }
    }
}
struct DevicePowerLine: View {
    @Environment(\.workbenchPalette) private var palette
    let snapshot: DeviceSnapshot
    var compact = false
    var body: some View {
        HStack(spacing: 8) {
            if let battery = snapshot.battery {
                DeviceBatteryGlyph(fraction: battery.percent / 100).frame(width: 24, height: 13)
                Text("\(Int(battery.percent.rounded()))%").font(.system(size: 12)).monospacedDigit()
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    if battery.isCharging { Image(systemName: "bolt.fill").font(.system(size: 10)) }
                    Text(battery.isCharging ? "正在充电" : battery.isPluggedIn ? "已接电源" : "电池供电").font(.system(size: 11))
                }.foregroundStyle(battery.isCharging ? palette.success : palette.secondary).lineLimit(1)
                if !compact && battery.isCharging { Text("电源适配器").font(.system(size: 11)).foregroundStyle(palette.muted) }
            } else {
                Image(systemName: "powerplug").font(.system(size: 13))
                Text("外部供电").font(.system(size: 12)); Spacer()
                Text("无内置电池").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }.frame(height: 18)
    }
}
struct DeviceBatteryGlyph: View {
    @Environment(\.workbenchPalette) private var palette
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            let w = g.size.width - 3
            RoundedRectangle(cornerRadius: 2.5).stroke(palette.secondary, lineWidth: 1).frame(width: w)
            RoundedRectangle(cornerRadius: 1).fill(palette.text).frame(width: max(0, w - 4) * min(1, max(0, fraction)), height: max(0, g.size.height - 4)).offset(x: 2, y: 2)
            Capsule().fill(palette.secondary).frame(width: 1.5, height: g.size.height * 0.38).offset(x: w + 1.5, y: g.size.height * 0.31)
        }
    }
}
struct DeviceNetworkReadings: View {
    @Environment(\.workbenchPalette) private var palette
    let snapshot: DeviceSnapshot
    var size: CGFloat = 28
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) { DeviceReading(value: DeviceFormat.rate(snapshot.network.downloadBytesPerSecond), size: size); Text("↓ 下载").font(.system(size: 11)).foregroundStyle(palette.muted) }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) { DeviceReading(value: DeviceFormat.rate(snapshot.network.uploadBytesPerSecond), size: size); Text("↑ 上传").font(.system(size: 11)).foregroundStyle(palette.muted) }
        }
    }
}

enum DeviceChartKind { case cpu, network, thermal, memory }
/// Preserve the accepted small axis gutter for short values, and reserve only
/// the width the actual single-line 11 pt labels need for real network data.
enum DeviceChartAxisMetrics {
    static func width(for labels: [String], minimum: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let measured = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(minimum, ceil(measured) + 2)
    }
}
struct DeviceHistoryChart: View {
    @Environment(\.workbenchPalette) private var palette
    let points: [DeviceHistoryPoint]
    let kind: DeviceChartKind
    var minutes = 5
    var compact = false
    var networkScale = false
    @State private var hover: CGPoint?
    private var end: Date { points.last?.date ?? Date() }
    private var visible: [DeviceHistoryPoint] { points.filter { end.timeIntervalSince($0.date) <= Double(minutes * 60) } }
    private func values(_ p: DeviceHistoryPoint) -> [Double?] {
        switch kind { case .cpu: [p.cpuPercent]; case .network: [p.downloadBytesPerSecond, p.uploadBytesPerSecond]; case .thermal: [p.cpuTemperature, p.gpuTemperature]; case .memory: [p.memoryPercent] }
    }
    private var maxValue: Double {
        switch kind {
        case .cpu, .memory: return 100
        case .thermal: return max(70, ((visible.flatMap { values($0).compactMap { $0 } }.max() ?? 60) / 10).rounded(.up) * 10 + 10)
        case .network:
            let maximum = max(1024, (visible.flatMap { values($0).compactMap { $0 } }.max() ?? 0) * 1.15)
            if networkScale { let divisor: Double = maximum >= 1_048_576 ? 1_048_576 : 1024; return ceil(maximum / divisor) * divisor }
            return maximum
        }
    }
    private var minValue: Double { kind == .thermal ? max(0, ((visible.flatMap { values($0).compactMap { $0 } }.min() ?? 40) / 10).rounded(.down) * 10 - 5) : 0 }
    private var networkDivisor: Double { maxValue >= 1_048_576 ? 1_048_576 : 1024 }
    private func axisValue(_ value: Double) -> String { let text = String(format: "%.1f", value / networkDivisor); return text.hasSuffix(".0") ? String(text.dropLast(2)) : text }
    private var networkAxisWidth: CGFloat { DeviceChartAxisMetrics.width(for: [axisValue(maxValue), axisValue(maxValue / 2), "0"], minimum: 21) }
    private func clock(_ date: Date) -> String { let format = DateFormatter(); format.dateFormat = "HH:mm"; return format.string(from: date) }
    var body: some View {
        VStack(spacing: 8) {
            if networkScale {
                HStack { Text("近 \(minutes) 分钟"); Spacer(); Text(networkDivisor == 1_048_576 ? "MB/s" : "KB/s") }
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            HStack(spacing: networkScale ? 6 : 0) {
            if networkScale {
                VStack(alignment: .trailing) {
                    Text(axisValue(maxValue)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    Text(axisValue(maxValue / 2)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    Text("0").lineLimit(1)
                }.font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.muted).frame(width: networkAxisWidth, alignment: .trailing)
            }
            GeometryReader { g in
                Canvas { context, size in
                    for ratio in [0.0,0.5,1.0] {
                        var line = Path(); line.move(to: .init(x: 0, y: size.height * ratio)); line.addLine(to: .init(x: size.width, y: size.height * ratio))
                        context.stroke(line, with: .color(palette.line), lineWidth: 1)
                    }
                    for index in 0..<(kind == .network || kind == .thermal ? 2 : 1) {
                        var segments: [[CGPoint]] = [], current: [CGPoint] = [], previous: UUID?
                        for point in visible {
                            guard let value = values(point)[index], value.isFinite else { if !current.isEmpty { segments.append(current) }; current = []; previous = nil; continue }
                            let location = CGPoint(x: size.width * (1 - end.timeIntervalSince(point.date) / Double(minutes * 60)), y: size.height * (1 - (min(maxValue, max(minValue, value)) - minValue) / (maxValue - minValue)))
                            if previous != point.segment && !current.isEmpty { segments.append(current); current = [] }
                            current.append(location); previous = point.segment
                        }
                        if !current.isEmpty { segments.append(current) }
                        let color = index == 0 ? palette.accent : palette.cool
                        for segment in segments where !segment.isEmpty {
                            var path = Path(); path.move(to: segment[0])
                            for curve in DeviceTrendCurve.segments(segment) {
                                path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
                            }
                            if segment.count == 1 {
                                let point = segment[0]
                                context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)), with: .color(color))
                            }
                            if kind != .thermal && index == 0 {
                                var area = path; area.addLine(to: CGPoint(x: segment.last!.x, y: size.height)); area.addLine(to: CGPoint(x: segment[0].x, y: size.height)); area.closeSubpath()
                                context.fill(area, with: .color(color.opacity(0.07)))
                            }
                            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: index == 1 && kind == .thermal ? [4,3] : []))
                        }
                    }
                    if let hover {
                        var path = Path(); path.move(to: CGPoint(x: hover.x, y: 0)); path.addLine(to: CGPoint(x: hover.x, y: size.height))
                        context.stroke(path, with: .color(palette.secondary.opacity(0.55)), style: .init(lineWidth: 1, dash: [2,3]))
                    }
                }.overlay {
                    if visible.flatMap({ values($0).compactMap { $0 } }).isEmpty { Text(kind == .thermal ? "暂无温度读数" : "等待连续有效样本").font(.system(size: 11)).foregroundStyle(palette.muted) }
                }.onContinuousHover { phase in
                    switch phase { case .active(let point): hover = point; case .ended: hover = nil }
                }.overlay(alignment: .topLeading) {
                    if let hover, let nearest = visible.min(by: { abs(end.timeIntervalSince($0.date) - (1 - hover.x / max(1,g.size.width)) * Double(minutes * 60)) < abs(end.timeIntervalSince($1.date) - (1 - hover.x / max(1,g.size.width)) * Double(minutes * 60)) }) {
                        Text(tooltip(nearest)).font(.system(size: 10)).padding(6).background(WorkbenchMaterialSurface(kind: .panel, radius: 5)).padding(3).allowsHitTesting(false)
                    }
                }
            }
            }
            HStack(spacing: 6) {
                if networkScale {
                    Text(clock(end.addingTimeInterval(-Double(minutes * 60)))); Spacer(); Text(clock(end))
                } else if kind == .thermal {
                    legend("CPU", palette.accent); legend("GPU", palette.cool)
                    Spacer(minLength: 0); Text("\(Int(minValue))–\(Int(maxValue))°C · \(minutes == 60 ? "1 小时" : "\(minutes) 分钟")")
                } else {
                    Text(minutes == 60 ? "1 小时前" : "\(minutes) 分钟前"); Spacer(minLength: 0)
                    if kind == .network { Text("↓ 下载　↑ 上传") }
                    else { Text(kind == .memory ? "内存 · 0–100%" : "使用率 · 0–100%") }
                    Spacer(minLength: 0); Text("现在")
                }
            }.font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).padding(.leading, networkScale ? 27 : 0)
        }.padding(.top, networkScale ? 4 : 0).accessibilityElement(children: .ignore).accessibilityLabel("最近 \(minutes) 分钟的实际采样趋势，共 \(visible.count) 个样本，缺口不补线")
    }
    private func legend(_ title: String, _ color: Color) -> some View { HStack(spacing: 4) { Capsule().fill(color).frame(width: 10, height: 1.5); Text(title) } }
    private func tooltip(_ point: DeviceHistoryPoint) -> String {
        let formatted = values(point).map { value in kind == .network ? DeviceFormat.rate(value) : kind == .thermal ? DeviceFormat.temperature(value) : DeviceFormat.percent(value) }.joined(separator: " / ")
        return point.date.formatted(date: .omitted, time: .standard) + "　" + formatted
    }
}

// Traffic budgets use decimal bytes. Memory and storage retain their existing binary units.
extension DeviceTrafficDisplay {
    static func adaptive(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        var value = Double(bytes), index = 0
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        while value >= 1000 && index < units.count - 1 { value /= 1000; index += 1 }
        return decimal(value) + " " + units[index]
    }
    static func budget(_ gigabytes: Double) -> String { decimal(gigabytes) + " GB" }
    private static func decimal(_ value: Double) -> String {
        var result = String(format: "%.2f", value)
        while result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        return result
    }
}
