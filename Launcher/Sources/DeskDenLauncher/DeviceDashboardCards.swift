import AppKit
import SwiftUI
import LauncherCore

enum DeviceAppearance {
    static func pressure(_ value: DevicePressure?, palette: ThemePalette = .init()) -> Color { value == .critical ? palette.critical : value == .warning ? palette.warning : value == nil || value == .unknown ? palette.muted : palette.accent }
    static func storage(_ value: Double?, palette: ThemePalette = .init()) -> Color { palette.usageColor(forPercent: value) }
    static func battery(_ percent: Double, pluggedIn: Bool, palette: ThemePalette = .init()) -> Color {
        guard percent.isFinite, percent >= 0 else { return palette.muted }
        return !pluggedIn && percent <= 10 ? palette.critical : !pluggedIn && percent <= 20 ? palette.warning : palette.text
    }
}
struct DeviceCardSurface: View {
    var editing = false
    /// Whole-card hover uses the home cards' light wash (现行规范 4.2); a
    /// keyboard focus ring sits inside the card so its frame never changes.
    var hovered = false
    var keyboardFocused = false
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchMaterialSurface(kind: .card, radius: 15)
            .overlay {
                if hovered && !editing { RoundedRectangle(cornerRadius: 15).fill(Color.white.opacity(palette.light ? 0.22 : 0.066)) }
                if editing { RoundedRectangle(cornerRadius: 15).strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                if keyboardFocused && !editing { RoundedRectangle(cornerRadius: 15).strokeBorder(palette.accent, lineWidth: 2) }
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
    var temperatureRule = DeviceTemperatureRule()
    var expanded = false
    var hovered = false
    var keyboardFocused = false
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(width: max(0, geometry.size.width - 28), height: max(0, geometry.size.height - 60))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    WorkbenchContentIcon(device: card.id, size: 16).foregroundStyle(palette.accent)
                    Text(card.id.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if card.id == .thermal {
                        Spacer(minLength: 4)
                        DeviceThermalStatusBadge(status: .init(snapshot: snapshot, rule: temperatureRule))
                        if editing { Color.clear.frame(width: 24) }
                    } else { Spacer(minLength: editing ? (card.id.supportsMeterStyle ? 60 : 28) : 0) }
                }.frame(height: 22)
                content(size: size).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.padding(14).frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }.foregroundStyle(palette.text).background(DeviceCardSurface(editing: editing, hovered: hovered, keyboardFocused: keyboardFocused)).environment(\.workbenchDeviceExpanded, expanded)
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
    // Card readings use the 24-point main value (现行规范 2.1).
    private func measure(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1).frame(height: 16)
            DeviceReading(value: value).frame(height: 32, alignment: .leading)
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
                }.font(.system(size: 11)).foregroundStyle(palette.secondary).monospacedDigit().lineLimit(1)
            }.frame(height: 52)
            DeviceHistoryChart(points: history, kind: .cpu, minutes: 5, compact: true).frame(maxHeight: .infinity)
        }
    }
    private func network(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                measure("↓ 下载", value: DeviceFormat.rate(snapshot.network.downloadBytesPerSecond))
                Spacer(minLength: 0)
                measure("↑ 上传", value: DeviceFormat.rate(snapshot.network.uploadBytesPerSecond))
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
                DeviceReading(value: trafficSummary.flatMap { $0.coveredSeconds > 0 ? DeviceTrafficDisplay.adaptive($0.totalBytes) : nil } ?? "—", size: 17)
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
            DeviceReading(value: DeviceFormat.rate(value))
        }.frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
    // The status pill already says how macOS regulates heat, so the card ends
    // with power; fan speeds are secondary readings (现行规范 9.2).
    private func thermal(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DeviceTemperatureReadings(snapshot: snapshot, size: 24, alignedColumns: true, rule: temperatureRule).frame(height: 52, alignment: .top)
            DeviceFanRows(snapshot: snapshot, paired: true, alignedColumns: true).frame(height: 40, alignment: .top)
            DevicePowerLine(snapshot: snapshot, compact: true).padding(.top, 2)
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
    /// Before the first sample the profile says it is reading instead of
    /// showing a zero core count (现行规范 1, 9.2).
    private var sampling: Bool { snapshot.sampledAt == nil }
    private func identity(showsModel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.deviceName).font(.system(size: 17, weight: .medium)).lineLimit(1)
            Text(snapshot.chipName).font(.system(size: 12)).foregroundStyle(palette.secondary).lineLimit(1)
            if showsModel {
                Text("型号标识：\(snapshot.modelIdentifier)").font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                    .help("这是 Apple 用于区分硬件机型的标识，不是 macOS 版本。").padding(.top, 2)
            }
        }
    }
    private func profileMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit().lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var cpuSummary: String {
        guard !sampling, snapshot.physicalCPUCount > 0 else { return "读取中" }
        guard let p = snapshot.performanceCores, let e = snapshot.efficiencyCores else { return "\(snapshot.physicalCPUCount) 核" }
        return "\(snapshot.physicalCPUCount) 核（\(p) 性能 + \(e) 能效）"
    }
    private func profile(_ size: CGSize) -> some View {
        Group {
            if size.width > 520 && size.height < 120 {
                // One information strip: identity, then CPU (which carries the
                // core composition, so it is wider), memory, capacity and system.
                let identityWidth = min(230, max(160, size.width * 0.25))
                let unit = max(0, size.width - identityWidth - 64) / 4.6
                HStack(alignment: .center, spacing: 16) {
                    identity(showsModel: false).frame(width: identityWidth, alignment: .leading)
                    profileMetric("CPU", cpuSummary).frame(width: unit * 1.6, alignment: .leading).help(coreExplanation)
                    profileMetric("统一内存", sampling ? "读取中" : DeviceFormat.capacity(snapshot.memory?.total)).frame(width: unit, alignment: .leading)
                    profileMetric("总容量", sampling ? "读取中" : DeviceFormat.storage(snapshot.disk?.total)).frame(width: unit, alignment: .leading)
                    profileMetric("操作系统", systemVersion).frame(width: unit, alignment: .leading)
                }.frame(maxHeight: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: size.height > 260 ? 23 : 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        identity(showsModel: true)
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
                DeviceCompactFact(label: "CPU 核心", value: sampling || snapshot.physicalCPUCount == 0 ? "读取中" : "\(snapshot.physicalCPUCount) 核")
                DeviceCompactFact(label: "核心构成", value: sampling ? "读取中" : coreComposition).help(coreExplanation)
                DeviceCompactFact(label: "统一内存", value: sampling ? "读取中" : DeviceFormat.capacity(snapshot.memory?.total))
            }
            if includeSystem != false {
                DeviceCompactFact(label: "总容量", value: sampling ? "读取中" : DeviceFormat.storage(snapshot.disk?.total))
                DeviceCompactFact(label: "操作系统", value: systemVersion)
                DeviceCompactFact(label: "显示器", value: NSScreen.main?.localizedName ?? "暂无读数")
            }
        }.frame(maxWidth: .infinity)
    }
    private var coreComposition: String {
        snapshot.performanceCores.flatMap { p in snapshot.efficiencyCores.map { "\(p) 性能核 + \($0) 能效核" } } ?? "核心构成未提供"
    }
    private var coreExplanation: String { "性能核适合编译、渲染等繁重任务；能效核以较低功耗处理日常与后台任务。macOS 会自动分配，不需要手动切换。" }
    private func capacityReading(label: String, value: UInt64?, total: UInt64?, percent: Double?, size: CGFloat = 24, storage: Bool = false) -> some View {
        let format = storage ? DeviceFormat.storage : DeviceFormat.capacity
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                Text(percent.map { "已用 " + UsagePercentage.text($0) } ?? "等待采样").foregroundStyle(palette.muted).monospacedDigit()
            }.font(.system(size: 11)).lineLimit(1).frame(height: 16)
                .accessibilityElement(children: .contain).accessibilityIdentifier("fc.device.capacity.\(card.id.rawValue).label")
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                DeviceReading(value: format(value), size: size)
                Text("/ \(format(total))").font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
            }.frame(height: 32, alignment: .leading)
                .accessibilityElement(children: .contain).accessibilityIdentifier("fc.device.capacity.\(card.id.rawValue).value")
        }.frame(height: 52, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("fc.device.capacity.\(card.id.rawValue).primary")
    }
    private func memory(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if card.meter == .ring {
                HStack(spacing: 10) { DeviceUsageRing(value: snapshot.memory?.percent, tone: DeviceAppearance.pressure(snapshot.memory?.pressure, palette: palette)).frame(width: 36, height: 36); capacityReading(label: "已用内存", value: snapshot.memory?.used, total: snapshot.memory?.total, percent: snapshot.memory?.percent) }.frame(height: 52)
                Color.clear.frame(height: 5)
            } else {
                capacityReading(label: "已用内存", value: snapshot.memory?.used, total: snapshot.memory?.total, percent: snapshot.memory?.percent)
                DeviceUsageBar(value: snapshot.memory?.percent, tone: DeviceAppearance.pressure(snapshot.memory?.pressure, palette: palette))
                    .accessibilityIdentifier("fc.device.capacity.memory.bar")
            }
            VStack(spacing: 6) {
                DeviceCompactFact(label: "可用内存", value: DeviceFormat.capacity(snapshot.memory?.available)).accessibilityIdentifier("fc.device.capacity.memory.fact.0")
                DeviceCompactFact(label: "内存压力", value: DeviceFormat.pressure(snapshot.memory?.pressure ?? .unknown)).accessibilityIdentifier("fc.device.capacity.memory.fact.1")
                DeviceCompactFact(label: "压缩 / 交换", value: "\(DeviceFormat.capacity(snapshot.memory?.compressed)) / \(DeviceFormat.capacity(snapshot.memory?.swapUsed))").accessibilityIdentifier("fc.device.capacity.memory.fact.2")
                if size.height > 200 { DeviceCompactFact(label: "App 内存", value: DeviceFormat.capacity(snapshot.memory?.application)) }
                if size.height > 230 { DeviceCompactFact(label: "缓存文件", value: DeviceFormat.capacity(snapshot.memory?.cached)) }
            }
        }
    }
    // Same reading as the home disk card: used over total, with the bar split
    // into used, system-reclaimable and immediately free space (现行规范 9.2).
    private func storage(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if card.meter == .ring {
                HStack(spacing: 10) {
                    DeviceUsageRing(value: snapshot.disk?.percent, tone: DeviceAppearance.storage(snapshot.disk?.percent, palette: palette)).frame(width: 36, height: 36)
                    capacityReading(label: "已用空间", value: snapshot.disk?.used, total: snapshot.disk?.total, percent: snapshot.disk?.percent, storage: true)
                }.frame(height: 52)
                Color.clear.frame(height: 5)
            } else {
                capacityReading(label: "已用空间", value: snapshot.disk?.used, total: snapshot.disk?.total, percent: snapshot.disk?.percent, storage: true)
                DeviceStorageBar(disk: snapshot.disk)
                    .accessibilityIdentifier("fc.device.capacity.storage.bar")
            }
            VStack(spacing: 6) {
                DeviceCompactFact(label: "可用空间", value: DeviceFormat.storage(snapshot.disk?.available)).accessibilityIdentifier("fc.device.capacity.storage.fact.0")
                DeviceCompactFact(label: "立即空闲", value: DeviceFormat.storage(snapshot.disk?.immediatelyFree), dot: DeviceStorageBar.freeTone(palette)).accessibilityIdentifier("fc.device.capacity.storage.fact.1")
                DeviceCompactFact(label: "系统可回收（估算）", value: DeviceFormat.storage(snapshot.disk?.reclaimableEstimate), dot: DeviceStorageBar.reclaimableTone(palette)).accessibilityIdentifier("fc.device.capacity.storage.fact.2")
            }
            if size.height > 200 { DeviceCompactFact(label: "读取", value: DeviceFormat.rate(snapshot.disk?.readBytesPerSecond)) }
            if size.height > 230 { DeviceCompactFact(label: "写入", value: DeviceFormat.rate(snapshot.disk?.writeBytesPerSecond)) }
        }
    }
    // A read-only preview: 24-point rows and an 11-point header; the whole card
    // opens the process page (现行规范 9.2, 4.5 exception).
    private func processes(_ size: CGSize) -> some View {
        let columns = size.width > 530 ? 2 : 1
        let rows = max(1, Int((size.height - 20) / 24))
        let items = Array(DeviceProcess.filtered(snapshot.processes, query: "", sort: .cpu).prefix(rows * columns))
        return HStack(alignment: .top, spacing: 24) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(spacing: 0) {
                    HStack { Text("名称"); Spacer(); Text("CPU 占用") }.font(.system(size: 11)).foregroundStyle(palette.muted).frame(height: 16).padding(.bottom, 4)
                    ForEach(Array(items.dropFirst(column * rows).prefix(rows))) { p in
                        HStack(spacing: 8) {
                            DeviceProcessIcon(path: p.executablePath).frame(width: 16, height: 16)
                            Text(p.displayName).lineLimit(1).truncationMode(.tail).help(p.displayName)
                            Spacer(minLength: 3)
                            Text(DeviceFormat.percent(p.cpuPercent)).monospacedDigit().foregroundStyle(palette.secondary).frame(minWidth: 37, alignment: .trailing)
                        }.font(.system(size: 12)).frame(height: 24)
                    }
                    if items.isEmpty && column == 0 { Text("正在读取可访问的进程").font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .leading) }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}
/// 24 is a card's main value and 30 a page reading; 17 is the medium-weight
/// secondary reading (现行规范 2.1).
struct DeviceReading: View {
    @Environment(\.workbenchPalette) private var palette
    let value: String
    var size: CGFloat = 24
    private var parts: (String, String) {
        if value.hasSuffix("%") { return (String(value.dropLast()), "%") }
        if let index = value.lastIndex(of: " ") { return (String(value[..<index]), String(value[value.index(after: index)...])) }
        return (value, "")
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(parts.0).font(.system(size: size, weight: size < 20 ? .medium : .regular))
            if !parts.1.isEmpty { Text(parts.1).font(.system(size: 11)).foregroundStyle(palette.secondary) }
        }.monospacedDigit().lineLimit(1).fixedSize().accessibilityElement(children: .ignore).accessibilityLabel(value)
    }
}
struct DeviceCompactFact: View {
    @Environment(\.workbenchPalette) private var palette
    let label: String, value: String
    /// A colored dot ties the line to its bar segment, acting as the legend.
    var dot: Color? = nil
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6).padding(.trailing, -3) }
            Text(label).foregroundStyle(palette.muted).lineLimit(1)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(palette.secondary).lineLimit(1).truncationMode(.middle)
        }.font(.system(size: 11)).monospacedDigit().frame(height: 16).accessibilityElement(children: .contain)
    }
}
struct DeviceUsageBar: View {
    @Environment(\.workbenchPalette) private var palette
    let value: Double?
    var tone: Color? = nil
    var body: some View {
        GeometryReader { g in
            Capsule().fill(palette.progressTrack).overlay(alignment: .leading) {
                if let value { Capsule().fill((tone ?? palette.usageColor(forPercent: value)).opacity(0.85)).frame(width: g.size.width * min(1, max(0, value / 100))) }
            }
        }.frame(height: 5).accessibilityLabel(value.map { "已用 " + UsagePercentage.text($0) } ?? "暂无读数")
    }
}
struct DeviceUsageRing: View {
    @Environment(\.workbenchPalette) private var palette
    let value: Double?
    var tone: Color? = nil
    var body: some View {
        ZStack {
            Circle().stroke(palette.progressTrack, lineWidth: 5)
            if let value { Circle().trim(from: 0, to: min(1, max(0, value / 100))).stroke(tone ?? palette.usageColor(forPercent: value), style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90)) }
            Text(UsagePercentage.text(value)).font(.system(size: 11)).monospacedDigit()
        }.padding(3)
    }
}
/// The home disk card's three segments: used space, the system-reclaimable
/// estimate and immediately free space (现行规范 9.1, 9.2).
struct DeviceStorageBar: View {
    let disk: DeviceDiskSnapshot?
    @Environment(\.workbenchPalette) private var palette
    static func reclaimableTone(_ palette: ThemePalette) -> Color { palette.accent.opacity(0.34) }
    static func freeTone(_ palette: ThemePalette) -> Color { palette.accent.opacity(0.20) }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.progressTrack)
                if let disk, disk.total > 0 {
                    HStack(spacing: 1) {
                        Rectangle().fill(palette.usageColor(forPercent: disk.percent))
                            .frame(width: g.size.width * min(1, Double(disk.used) / Double(disk.total)))
                        if let reclaimable = disk.reclaimableEstimate, reclaimable > 0 {
                            Rectangle().fill(Self.reclaimableTone(palette))
                                .frame(width: g.size.width * min(1, Double(reclaimable) / Double(disk.total)))
                        }
                        Rectangle().fill(Self.freeTone(palette))
                    }
                }
            }.clipShape(Capsule())
        }.frame(height: 5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(disk.map { "已用 " + UsagePercentage.text($0.percent) + "，系统可回收（估算）" + DeviceFormat.storage($0.reclaimableEstimate) + "，立即空闲 " + DeviceFormat.storage($0.immediatelyFree) } ?? "暂无读数")
    }
}
struct DeviceTemperatureReadings: View {
    @Environment(\.workbenchPalette) private var palette
    let snapshot: DeviceSnapshot
    var size: CGFloat = 30
    var alignedColumns = false
    var rule = DeviceTemperatureRule()
    var body: some View {
        HStack(spacing: 16) {
            reading("CPU 温度", snapshot.cpuTemperature, level: status.cpuLevel, trailing: false)
            reading("GPU 温度", snapshot.gpuTemperature, level: status.gpuLevel, trailing: !alignedColumns)
        }
    }
    private var status: DeviceThermalPresentation { .init(snapshot: snapshot, rule: rule) }
    private func reading(_ name: String, _ value: Double?, level: DeviceThermalLevel, trailing: Bool) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 4) {
            Text(name).font(.system(size: 11)).foregroundStyle(palette.secondary).frame(height: 16)
            DeviceReading(value: value.map { String(format: "%.0f °C", $0) } ?? "— °C", size: size)
                .foregroundStyle(level == .normal ? palette.text : level.color(palette: palette))
        }.frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}
struct DeviceFanRows: View {
    @Environment(\.workbenchPalette) private var palette
    let snapshot: DeviceSnapshot
    var paired = false
    var alignedColumns = false
    var body: some View {
        Group {
        if paired, snapshot.fanRPM?.isEmpty != true {
            let fans = snapshot.fanRPM ?? [nil, nil]
            HStack(spacing: 12) {
                ForEach(Array(fans.prefix(2).enumerated()), id: \.offset) { index, rpm in
                    VStack(alignment: index == 1 && !alignedColumns ? .trailing : .leading, spacing: 2) {
                        Text(fans.count == 2 ? (index == 0 ? "左风扇" : "右风扇") : "风扇 \(index + 1)").font(.system(size: 11)).foregroundStyle(palette.secondary).frame(height: 16)
                        DeviceReading(value: rpm.map { "\(Int($0.rounded()).formatted()) RPM" } ?? "— RPM", size: 17)
                    }.frame(maxWidth: .infinity, alignment: index == 1 && !alignedColumns ? .trailing : .leading)
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
                        Text(fans.count == 2 ? (index == 0 ? "左风扇" : "右风扇") : "风扇 \(index + 1)").font(.system(size: 12))
                        Spacer()
                        DeviceReading(value: rpm.map { "\(Int($0.rounded()).formatted()) RPM" } ?? "— RPM", size: 17).foregroundStyle(palette.text)
                    }.foregroundStyle(palette.secondary).frame(height: 26)
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
    /// The detail page's battery card leads with the charge as a 17 medium reading.
    var prominent = false
    var body: some View {
        HStack(spacing: 8) {
            if let battery = snapshot.battery {
                let tone = DeviceAppearance.battery(battery.percent, pluggedIn: battery.isPluggedIn, palette: palette)
                DeviceBatteryGlyph(fraction: battery.percent / 100, tone: tone).frame(width: 24, height: 13)
                Text("\(Int(battery.percent.rounded()))%").font(.system(size: prominent ? 17 : 12, weight: prominent ? .medium : .regular)).monospacedDigit().foregroundStyle(tone)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    if battery.isCharging { Image(systemName: "bolt.fill").font(.system(size: 10)) }
                    Text(battery.isCharging ? "正在充电" : battery.isPluggedIn ? "已接电源" : "电池供电").font(.system(size: prominent ? 12 : 11))
                }.foregroundStyle(battery.isCharging ? palette.success : palette.secondary).lineLimit(1)
                if !compact && battery.isCharging { Text("电源适配器").font(.system(size: 11)).foregroundStyle(palette.muted) }
            } else {
                Image(systemName: "powerplug").font(.system(size: 13))
                Text("外部供电").font(.system(size: 12)); Spacer()
                Text("无内置电池").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }.frame(height: prominent ? 26 : 18)
    }
}
struct DeviceBatteryGlyph: View {
    @Environment(\.workbenchPalette) private var palette
    let fraction: Double
    var tone: Color? = nil
    var body: some View {
        GeometryReader { g in
            let w = g.size.width - 3
            RoundedRectangle(cornerRadius: 2.5).stroke(palette.secondary, lineWidth: 1).frame(width: w)
            RoundedRectangle(cornerRadius: 1).fill(tone ?? palette.text).frame(width: max(0, w - 4) * min(1, max(0, fraction)), height: max(0, g.size.height - 4)).offset(x: 2, y: 2)
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
/// One linear projection per view update. Canvas redraws must not repeatedly
/// filter an hour of history and rescan the axis range for every painted point.
struct DeviceHistoryChartData {
    struct Sample {
        var segment: UUID
        var location: CGPoint?
    }
    let end: Date
    let visible: [DeviceHistoryPoint]
    let series: [[Sample]]
    let minValue: Double
    let maxValue: Double
    let hasReadings: Bool

    init(points: [DeviceHistoryPoint], kind: DeviceChartKind, minutes: Int, networkScale: Bool, now: Date = Date()) {
        self.end = now
        let duration = Double(max(1, minutes) * 60)
        let visible = points.filter { (0...duration).contains(now.timeIntervalSince($0.date)) }
        self.visible = visible
        let values = visible.map { Self.values($0, kind: kind) }
        let finite = values.flatMap { $0.compactMap { $0 }.filter(\.isFinite) }
        hasReadings = !finite.isEmpty
        let minValue: Double, maxValue: Double
        switch kind {
        case .cpu, .memory:
            minValue = 0; maxValue = 100
        case .thermal:
            // Ten-degree bounds with a margin keep the middle gridline on a
            // whole degree, so the axis can label all three lines.
            minValue = max(0, (((finite.min() ?? 40) - 5) / 10).rounded(.down) * 10)
            maxValue = max(minValue + 20, 70, (((finite.max() ?? 60) + 5) / 10).rounded(.up) * 10)
        case .network:
            minValue = 0
            let maximum = max(1_000, (finite.max() ?? 0) * 1.15)
            maxValue = networkScale ? Self.niceNetworkMaximum(maximum) : maximum
        }
        self.minValue = minValue; self.maxValue = maxValue
        let range = maxValue - minValue
        series = (0..<(kind == .network || kind == .thermal ? 2 : 1)).map { index in
            zip(visible, values).map { point, readings in
                let location = readings[index].flatMap { value -> CGPoint? in
                    guard value.isFinite else { return nil }
                    return CGPoint(x: 1 - now.timeIntervalSince(point.date) / duration,
                                   y: 1 - (min(maxValue, max(minValue, value)) - minValue) / range)
                }
                return Sample(segment: Self.segment(point, kind: kind), location: location)
            }
        }
    }

    /// The network axis tops out at 1, 2 or 5 × 10ⁿ decimal bytes per second,
    /// so the labelled middle gridline is a clean half (现行规范 9.3).
    static func niceNetworkMaximum(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1_000 }
        let magnitude = pow(10, floor(log10(value)))
        for step in [1.0, 2, 5] where step * magnitude >= value * 0.999_999 { return step * magnitude }
        return 10 * magnitude
    }

    static func values(_ point: DeviceHistoryPoint, kind: DeviceChartKind) -> [Double?] {
        switch kind {
        case .cpu: [point.cpuPercent]
        case .network: [point.downloadBytesPerSecond, point.uploadBytesPerSecond]
        case .thermal: [point.cpuTemperature, point.gpuTemperature]
        case .memory: [point.memoryPercent]
        }
    }

    static func segment(_ point: DeviceHistoryPoint, kind: DeviceChartKind) -> UUID {
        switch kind {
        case .network: point.selectedNetworkSegment ?? point.segment
        case .memory: point.memorySegment ?? point.segment
        case .cpu, .thermal: point.segment
        }
    }

    static func status(_ point: DeviceHistoryPoint, kind: DeviceChartKind) -> String? {
        switch kind {
        case .cpu: point.cpuStatus
        case .network: point.networkStatus
        case .thermal, .memory: nil
        }
    }

    func sample(near target: Date, kind: DeviceChartKind, tolerance: TimeInterval) -> DeviceHistoryPoint? {
        let index = visible.firstIndex { $0.date >= target } ?? visible.count
        let before = index > 0 ? visible[index - 1] : nil
        let after = index < visible.count ? visible[index] : nil
        let nearest = [before, after].compactMap { $0 }.min {
            abs(target.timeIntervalSince($0.date)) < abs(target.timeIntervalSince($1.date))
        }
        if let nearest, abs(target.timeIntervalSince(nearest.date)) <= tolerance { return nearest }
        guard let before, let after, Self.segment(before, kind: kind) == Self.segment(after, kind: kind),
              zip(Self.values(before, kind: kind), Self.values(after, kind: kind))
                .contains(where: { $0.0?.isFinite == true && $0.1?.isFinite == true }) else { return nil }
        // A connected trace can snap to a real endpoint; a gap cannot snap to
        // an old sample and imply that it was current at the pointer.
        return nearest
    }

    func segments(series index: Int, size: CGSize) -> [[CGPoint]] {
        guard series.indices.contains(index) else { return [] }
        var result: [[CGPoint]] = [], current: [CGPoint] = [], previous: UUID?
        for sample in series[index] {
            guard let location = sample.location else {
                if !current.isEmpty { result.append(current) }
                current = []; previous = nil; continue
            }
            if previous != sample.segment && !current.isEmpty { result.append(current); current = [] }
            current.append(CGPoint(x: size.width * location.x, y: size.height * location.y))
            previous = sample.segment
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

struct DeviceHistoryChart: View {
    @Environment(\.workbenchPalette) private var palette
    let points: [DeviceHistoryPoint]
    let kind: DeviceChartKind
    var minutes = 5
    var compact = false
    var networkScale = false
    var showsSeriesLegend = true
    @State private var hover: CGPoint?
    private func axisValue(_ value: Double, divisor: Double) -> String { let text = String(format: "%.1f", value / divisor); return text.hasSuffix(".0") ? String(text.dropLast(2)) : text }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in chart(now: Date()) }
    }

    private func chart(now: Date) -> some View {
        let data = DeviceHistoryChartData(points: points, kind: kind, minutes: minutes, networkScale: networkScale, now: now)
        let visible = data.visible, end = data.end, minValue = data.minValue, maxValue = data.maxValue
        let networkDivisor: Double = maxValue >= 1_000_000 ? 1_000_000 : 1_000
        let maximumLabel = axisValue(maxValue, divisor: networkDivisor)
        let middleLabel = axisValue(maxValue / 2, divisor: networkDivisor)
        let networkAxisWidth = DeviceChartAxisMetrics.width(for: [maximumLabel, middleLabel, "0"], minimum: 21)
        // Detail charts label their gridlines on a left axis (现行规范 9.2).
        let valueLabels: [String] = compact || networkScale || kind == .network ? [] : kind == .thermal
            ? [maxValue, (maxValue + minValue) / 2, minValue].map { String(format: "%.0f°C", $0) } : ["100%", "50%", "0%"]
        let valueAxisWidth = valueLabels.isEmpty ? 0 : DeviceChartAxisMetrics.width(for: valueLabels, minimum: 28)
        return VStack(spacing: 8) {
            if networkScale {
                HStack { Spacer(); Text(networkDivisor == 1_000_000 ? "MB/s" : "KB/s") }
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            HStack(spacing: networkScale || !valueLabels.isEmpty ? 6 : 0) {
            if !valueLabels.isEmpty {
                GeometryReader { axis in
                    ForEach(Array(valueLabels.enumerated()), id: \.offset) { index, label in
                        Text(label).lineLimit(1).frame(width: valueAxisWidth, alignment: .trailing)
                            .position(x: valueAxisWidth / 2, y: axis.size.height * CGFloat(index) / CGFloat(max(1, valueLabels.count - 1)))
                    }
                }.font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.muted).frame(width: valueAxisWidth)
            }
            if networkScale {
                VStack(alignment: .trailing) {
                    Text(maximumLabel).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    Text(middleLabel).lineLimit(1).fixedSize(horizontal: true, vertical: false)
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
                        let segments = data.segments(series: index, size: size)
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
                    if !data.hasReadings {
                        Text(visible.last.flatMap { DeviceHistoryChartData.status($0, kind: kind) }
                             ?? (kind == .thermal ? "暂无温度读数" : "等待连续有效样本"))
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                    }
                }.onContinuousHover { phase in
                    switch phase { case .active(let point): hover = point; case .ended: hover = nil }
                }.overlay(alignment: .topLeading) {
                    if let hover {
                        let duration = Double(max(1, minutes) * 60)
                        let secondsPerPoint = duration / max(1, g.size.width)
                        let at = end.addingTimeInterval(-(1 - hover.x / max(1, g.size.width)) * duration)
                        let point = data.sample(near: at, kind: kind, tolerance: 2 * secondsPerPoint)
                        Text(point.map(tooltip) ?? at.formatted(date: .omitted, time: .standard) + "　未采样")
                            .font(.system(size: 11)).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 5)
                            .background(WorkbenchMaterialSurface(kind: .panel, radius: 8)).padding(3).allowsHitTesting(false)
                    }
                }
            }
            }
            HStack(spacing: 6) {
                if networkScale || !valueLabels.isEmpty {
                    Text(minutes == 60 ? "1 小时前" : "\(minutes) 分钟前"); Spacer(minLength: 0); Text("现在")
                } else if kind == .thermal {
                    legend("CPU", palette.accent); legend("GPU", palette.cool, dashed: true)
                    Spacer(minLength: 0); Text("\(Int(minValue))–\(Int(maxValue))°C · \(minutes == 60 ? "1 小时" : "\(minutes) 分钟")")
                } else {
                    Text(minutes == 60 ? "1 小时前" : "\(minutes) 分钟前"); Spacer(minLength: 0)
                    if kind == .network { if showsSeriesLegend { Text("↓ 下载　↑ 上传") } }
                    else { Text(kind == .memory ? "内存 · 0–100%" : "使用率 · 0–100%") }
                    Spacer(minLength: 0); Text("现在")
                }
            }.font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                .padding(.leading, networkScale ? networkAxisWidth + 6 : valueLabels.isEmpty ? 0 : valueAxisWidth + 6)
            if !valueLabels.isEmpty && kind == .thermal {
                HStack(spacing: 14) { legend("CPU", palette.accent); legend("GPU", palette.cool, dashed: true); Spacer(minLength: 0) }
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
            }
        }.padding(.top, networkScale ? 4 : 0).accessibilityElement(children: .ignore).accessibilityLabel("最近 \(minutes) 分钟的实际采样趋势，共 \(visible.count) 个样本，缺口不补线")
    }
    private func legend(_ title: String, _ color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            Path { path in path.move(to: CGPoint(x: 0, y: 1)); path.addLine(to: CGPoint(x: 14, y: 1)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : [])).frame(width: 14, height: 2)
            Text(title)
        }
    }
    private func tooltip(_ point: DeviceHistoryPoint) -> String {
        let values = DeviceHistoryChartData.values(point, kind: kind)
        let formatted = DeviceHistoryChartData.status(point, kind: kind) ??
            values.map { value in kind == .network ? DeviceFormat.rate(value) : kind == .thermal ? DeviceFormat.temperature(value) : DeviceFormat.percent(value) }.joined(separator: " / ")
        return point.date.formatted(date: .omitted, time: .standard) + "　" + formatted
    }
}

// Traffic and storage use decimal bytes; memory retains its separate binary units.
extension DeviceTrafficDisplay {
    /// Traffic totals share the disk precision: GB and TB keep one decimal,
    /// MB and smaller are whole numbers (现行规范 5.2, 9.3).
    static func adaptive(_ bytes: UInt64?) -> String {
        DeviceStorageCapacity.formatted(bytes)
    }
    static func budget(_ gigabytes: Double) -> String { decimal(gigabytes) + " GB" }
    private static func decimal(_ value: Double) -> String {
        var result = String(format: "%.2f", value)
        while result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        return result
    }
}
