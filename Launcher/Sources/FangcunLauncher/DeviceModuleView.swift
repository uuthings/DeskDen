import AppKit
import SwiftUI
import LauncherCore

struct DeviceModuleView: View {
    @ObservedObject var model: DeviceStatusModel
    var onOpenNetwork: () -> Void = {}
    var onOpenHealth: () -> Void = {}
    var onCloseRequestedDetail: () -> Void = {}
    var requestedDetailReturnTitle = "返回设备状态"
    var initialDetail: DeviceCardID? = nil
    @Binding var requestedDetail: DeviceCardID?
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchContentHeight) private var viewportHeight
    @Environment(\.workbenchDeviceExpanded) private var expanded
    @StateObject private var monitoringDrafts = DeviceMonitoringDrafts()
    @State private var thermalSettings = false
    @State private var detail: DeviceCardID?
    @State private var detailWasRequested = false
    @State private var editing = false
    @State private var library = false
    @State private var resetLayout = false
    @State private var temperatureOpen = false
    @State private var minutes = 5
    @State private var query = ""
    @State private var processSort: DeviceProcessSort = .cpu
    @State private var ascending = false
    @State private var sheet: DeviceSheet?
    @State private var gridHeight: CGFloat = 620
    @State private var contentWidth: CGFloat = 864
    private var s: DeviceSnapshot { model.snapshot }
    init(model: DeviceStatusModel, onOpenNetwork: @escaping () -> Void = {}, onOpenHealth: @escaping () -> Void = {}, initialDetail: DeviceCardID? = nil, requestedDetail: Binding<DeviceCardID?> = .constant(nil), requestedDetailReturnTitle: String = "返回设备状态", onCloseRequestedDetail: @escaping () -> Void = {}) {
        self.model = model; self.onOpenNetwork = onOpenNetwork; self.onOpenHealth = onOpenHealth
        self.initialDetail = initialDetail; self._requestedDetail = requestedDetail
        self.requestedDetailReturnTitle = requestedDetailReturnTitle; self.onCloseRequestedDetail = onCloseRequestedDetail
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
        WorkbenchScrollView(detail == .processes ? [] : .vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if let detail { detailPage(detail) }
                else {
                    WBPageHeader(title: "设备状态", subtitle: "\(s.deviceName) · \(s.chipName)") {
                        HStack(spacing: 8) {
                            if editing { Button { library = true } label: { Label("添加卡片", systemImage: "plus") }.buttonStyle(WBButtonStyle()) }
                            Button { editing.toggle(); library = false } label: { Label(editing ? "完成" : "编辑布局", systemImage: editing ? "checkmark" : "slider.horizontal.3") }
                                .buttonStyle(WBButtonStyle(primary: editing)).accessibilityIdentifier("fc.action.device.edit")
                        }
                    }
                    if let error = model.layoutError ?? model.lastError {
                        Text(error).font(.system(size: 11)).foregroundStyle(palette.warning).padding(.bottom, 12)
                    }
                    DeviceDashboardRepresentable(model: model, editing: editing, scale: 1, expanded: expanded, minimumHeight: 0, open: { card in
                        if card == .traffic || card == .network { onOpenNetwork() }
                        else { detail = card; thermalSettings = false }
                    }, heightChanged: { height in if abs(height - gridHeight) > 0.5 { gridHeight = height } })
                        .frame(height: gridHeight)
                    if model.dashboardLayout.cards.allSatisfy({ !$0.visible }) {
                        Button("从卡片库添加信息") { editing = true; library = true }.buttonStyle(WBButtonStyle()).padding(.top, 12)
                    }
                    HStack(spacing: 10) {
                        Text("本机状态 · 每 \(Int(model.samplingInterval)) 秒更新").foregroundStyle(palette.muted)
                        Spacer()
                        if editing { Button("恢复默认布局") { resetLayout = true }.buttonStyle(WBQuietButtonStyle()) }
                        if model.undoLayout != nil { Button("撤销布局修改") { model.undoLayoutChange() }.buttonStyle(WBQuietButtonStyle()) }
                        Button("数据来源") { sheet = .sensors }.buttonStyle(WBQuietButtonStyle())
                    }.font(.system(size: 11)).padding(.top, 14)
                }
            }.frame(maxWidth: .infinity, alignment: .topLeading).foregroundStyle(palette.text)
                .background(GeometryReader { proxy in Color.clear.preference(key: DeviceContentWidth.self, value: proxy.size.width) })
                .workbenchPageCanvas()
                .id("device-page-top")
                .accessibilityElement(children:.contain).accessibilityIdentifier(detail.map { "fc.page.device.\($0.rawValue)" } ?? "fc.page.device")
        }.onPreferenceChange(DeviceContentWidth.self) { contentWidth = $0 }.scrollContentBackground(.hidden).scrollBounceBehavior(.basedOnSize)
            .task { monitoringDrafts.load(model); await model.refreshNotificationPermission() }
            .onAppear { detailWasRequested = requestedDetail != nil; detail = requestedDetail ?? initialDetail }
            .onChange(of: requestedDetail) { _, value in if detail != value { detailWasRequested = value != nil; detail = value } }
            .onChange(of: detail) { _, value in
                requestedDetail = value
                DispatchQueue.main.async {scrollProxy.scrollTo("device-page-top", anchor: .top)}
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.refreshNotificationPermission() } }
            .workbenchModal(item: $sheet) { item in DeviceSheetView(item: item, model: model) { sheet = nil } }
            .workbenchModal(isPresented: $library) { cardLibrary }
            .workbenchModal(isPresented: $resetLayout) {
                DeviceDialog(title: "恢复默认布局？", dismiss: { resetLayout = false }) {
                    Text("卡片的位置、大小与显隐将恢复为默认设置。").font(.system(size: 12)).foregroundStyle(palette.secondary)
                } actions: {
                    Button("取消") { resetLayout = false }.buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("恢复默认") { model.saveLayout(.init()); resetLayout = false }.buttonStyle(WBButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                }
            }
            .workbenchModal(isPresented: $temperatureOpen, onRequestDismiss: { monitoringDrafts.temperatureCloseRequest += 1 }) { DeviceTemperatureDialog(model: model, drafts: monitoringDrafts) { temperatureOpen = false } }
        }
    }
    private func closeDetail() {
        let returnToSource = detailWasRequested
        detailWasRequested = false; detail = nil; requestedDetail = nil
        if returnToSource { onCloseRequestedDetail() }
    }
    private var cardLibrary: some View {
        DeviceDialog(title: "卡片库", dismiss: { library = false }) {
            VStack(spacing: 0) {
                ForEach(DeviceDashboardLayout.defaultCards.map(\.id), id: \.self) { id in
                    HStack(spacing: 8) {
                        Image(systemName: id.symbol).frame(width: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(id.title).font(.system(size: 12))
                            if id == .network || id == .traffic { Text("也可在网络监控集中查看").font(.system(size: 11)).foregroundStyle(palette.muted) }
                        }
                        Spacer(minLength: 8)
                        let added = model.dashboardLayout.cards.first { $0.id == id }?.visible == true
                        if added { Text("已显示").font(.system(size: 11)).foregroundStyle(palette.muted) }
                        else { Button("添加") { model.changeCard(id) { $0.visible = true }; library = false }.buttonStyle(WBButtonStyle(compact: true)).accessibilityLabel("添加" + id.title) }
                    }.frame(height: 48).overlay(alignment: .bottom) { palette.line.frame(height: 1) }
                }
            }
        } actions: { Button("完成") { library = false }.buttonStyle(WBButtonStyle(primary: true)).keyboardShortcut(.defaultAction) }
    }
    @ViewBuilder private func detailPage(_ card: DeviceCardID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: closeDetail) { Label(detailWasRequested ? requestedDetailReturnTitle : "返回设备状态", systemImage: "arrow.left") }
                .buttonStyle(WBButtonStyle(compact: true)).keyboardShortcut(.cancelAction).padding(.bottom, 12).accessibilityIdentifier("device-detail-back")
            WBPageHeader(title: card.title, subtitle: "\(s.deviceName) · \(s.chipName)") {
                if card == .storage || card == .memory { Button { onOpenHealth() } label: { Label(card == .storage ? "前往体检中心" : "体检中心", systemImage: "heart.text.square") }.buttonStyle(WBButtonStyle(primary: card == .storage)).accessibilityIdentifier("device-detail-open-health") }
                else if card == .thermal { Button { temperatureOpen = true } label: { Label("温度提醒", systemImage: "bell") }.buttonStyle(WBButtonStyle()) }
                else if card == .processes { Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }.buttonStyle(WBButtonStyle()) }
            }
            switch card {
            case .profile: profileDetail
            case .cpu: performanceDetail(memory: false)
            case .memory: memoryDetail
            case .thermal: thermalDetail
            case .network: networkDetail
            case .traffic:
                WBCard(title:"完整流量记录",symbol:"network") {
                    Text("今日与周期流量、流量预算及历史记录已集中在网络监控中。")
                        .font(.system(size:12)).foregroundStyle(palette.secondary)
                    Button("打开网络监控",action:onOpenNetwork).buttonStyle(WBButtonStyle(primary:true))
                }
            case .storage: storageDetail
            case .processes: processesDetail
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func detailDescription(_ card: DeviceCardID) -> String {
        switch card {
        case .profile: "硬件配置与系统信息"
        case .cpu: "\(s.chipName) · \(s.physicalCPUCount) 核中央处理器"
        case .memory: "统一内存的使用、组成与压力"
        case .storage: "启动磁盘、共享容器与卷信息"
        case .thermal: "温度、风扇、电源状态与持续高温提醒"
        case .network: "当前上传、下载速度与短期趋势"
        case .traffic: "已记录流量、周期预算与额度提醒"
        case .processes: "实时读数 · 固定顺序 · CPU 以整机能力为 100%"
        }
    }
    private var profileDetail: some View {
        VStack(spacing: 12) {
            DeviceDetailColumns {
                DeviceDetailCard(title: "硬件信息", symbol: "laptopcomputer", spacing: 12) {
                    DeviceFact(label: "设备名称", value: s.deviceName)
                    DeviceFact(label: "型号标识符", value: s.modelIdentifier)
                    DeviceFact(label: "芯片", value: s.chipName)
                    DeviceFact(label: "CPU", value: "\(s.physicalCPUCount) 核 · \(s.logicalCPUCount) 个逻辑处理器")
                    DeviceFact(label: "核心构成", value: s.performanceCores.flatMap { p in s.efficiencyCores.map { "\(p) 个性能核 + \($0) 个能效核" } } ?? "系统未提供").accessibilityIdentifier("device-profile-core-composition")
                    DeviceFact(label: "统一内存", value: DeviceFormat.bytes(s.memory?.total))
                    DeviceFact(label: "显示器", value: NSScreen.screens.map(\.localizedName).joined(separator: "、"))
                }
                DeviceDetailCard(title: "系统与存储", symbol: "internaldrive", spacing: 12) {
                    DeviceFact(label: "操作系统", value: ProcessInfo.processInfo.operatingSystemVersionString)
                    DeviceFact(label: "系统卷", value: s.disk?.name ?? "暂无读数")
                    DeviceFact(label: "文件系统", value: s.disk?.fileSystem ?? "暂无读数")
                    DeviceFact(label: "启动卷容量", value: DeviceFormat.storage(s.disk?.total))
                    DeviceFact(label: "可用容量", value: DeviceFormat.storage(s.disk?.available))
                    DeviceFact(label: "运行时间", value: DeviceFormat.duration(s.uptime))
                }
            }
            DeviceRuleHelp(text: "型号标识符（如 Mac14,6）是 Apple 用来区分硬件机型的代码，不是系统版本。性能核适合编译、渲染等繁重任务；能效核用较低功耗处理日常与后台任务，由 macOS 自动分配。设备信息来自本机系统，可读配置因机型而异。", notice: true).accessibilityIdentifier("device-detail-profile-notice")
        }
    }
    private func performanceDetail(memory: Bool) -> some View {
        VStack(spacing: 12) {
            DeviceDetailColumns(minimumCardHeight: 128.25) {
                DeviceDetailCard(title: "当前使用率", symbol: "cpu") { DeviceReading(value: DeviceFormat.percent(s.cpuPercent), size: 36); Text("以全部 CPU 总算力为 100%").font(.system(size: 11)).foregroundStyle(palette.muted) }
                DeviceDetailCard(title: "用户进程", symbol: "macwindow") { DeviceReading(value: DeviceFormat.percent(s.cpuUserPercent)); Text("当前应用与后台任务").font(.system(size: 11)).foregroundStyle(palette.muted) }
                DeviceDetailCard(title: "系统", symbol: "gearshape") { DeviceReading(value: DeviceFormat.percent(s.cpuSystemPercent)); Text("系统内核与系统服务").font(.system(size: 11)).foregroundStyle(palette.muted) }
            }
            WBCard {
                HStack { Label("CPU 使用率趋势", systemImage: "waveform.path.ecg").font(.system(size: 12, weight: .medium)); Spacer(); rangePicker }
                DeviceHistoryChart(points: model.history, kind: .cpu, minutes: minutes).frame(height: expanded ? 260 : 190)
            }
            DeviceDetailColumns {
                DeviceDetailCard(title: "处理器", symbol: "cpu", spacing: 12, identifier: "fc.device.detail.card.cpu-processor") {
                    DeviceFact(label: "芯片", value: s.chipName)
                    DeviceFact(label: "CPU 核心", value: "\(s.physicalCPUCount) 核")
                    DeviceFact(label: "当前空闲", value: DeviceFormat.percent(s.cpuPercent.map { 100 - $0 }))
                }
                DeviceLinkedDetailCard(title: "相关进程", symbol: "macwindow", identifier: "fc.device.detail.card.cpu-processes", actionTitle: "查看全部进程", spacing: 0, action: { detail = .processes }) {
                    VStack(spacing: 0) {
                        ForEach(DeviceProcess.filtered(s.processes, query: "", sort: .cpu).prefix(3)) { process in
                            HStack(spacing: 8) { DeviceProcessIcon(path: process.executablePath).frame(width: 19, height: 19); Text(process.name).lineLimit(1); Spacer(); Text(DeviceFormat.percent(process.cpuPercent)).monospacedDigit() }.font(.system(size: 11)).frame(height: 23)
                        }
                    }
                }
            }
        }
    }
    private var memoryDetail: some View {
        VStack(spacing: 12) {
            DeviceDetailColumns(firstFraction: 1.1 / 2.1) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("统一内存").font(.system(size: 11)).foregroundStyle(palette.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 4) { DeviceReading(value: DeviceFormat.capacity(s.memory?.used), size: 30); Text("/ \(DeviceFormat.capacity(s.memory?.total))").font(.system(size: 12)).foregroundStyle(palette.secondary) }
                    DeviceMemoryComposition(memory: s.memory).frame(height: 9)
                    HStack(spacing: 11) {
                        Text("应用 \(DeviceFormat.capacity(s.memory?.application))")
                        Text("固定 \(DeviceFormat.capacity(s.memory?.wired))")
                        Text("压缩 \(DeviceFormat.capacity(s.memory?.compressed))")
                        Text("可用 \(DeviceFormat.capacity(s.memory?.available))")
                    }.font(.system(size: 11)).foregroundStyle(palette.muted)
                }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).background(DeviceCardSurface())
                HStack(spacing: 14) {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 22)).foregroundStyle(palette.success).frame(width: 45, height: 45).background(palette.success.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 7) {
                        Text("内存压力").font(.system(size: 11)).foregroundStyle(palette.muted)
                        Text(DeviceFormat.pressure(s.memory?.pressure ?? .unknown)).font(.system(size: 21, weight: .medium)).foregroundStyle((s.memory?.pressure == .normal ? palette.success : DeviceAppearance.pressure(s.memory?.pressure, palette: palette)))
                        Text("交换 \(DeviceFormat.capacity(s.memory?.swapUsed)) · 缓存文件 \(DeviceFormat.capacity(s.memory?.cached))").font(.system(size: 11)).foregroundStyle(palette.secondary)
                        Text(s.memory?.pressure == .normal ? "macOS 会利用空闲内存缓存。当前无需主动清空。" : "结合持续压力与交换空间判断，先保存工作，再按需复核应用。").font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).background(DeviceCardSurface())
            }
            DeviceProcessExplorerView(processes: s.processes, systemCount: s.processTotalCount, query: $query, sort: $processSort, ascending: $ascending, open: { sheet = .process($0) }, leave: { detail = nil }, memoryFocused: true)
                .frame(height: 505)
        }
    }
    private var thermalDetail: some View {
        VStack(spacing: 12) {
            DeviceDetailColumns(minimumCardHeight: 128.25) {
                DeviceDetailCard(title: "CPU 温度", symbol: "thermometer.medium") { DeviceReading(value: DeviceFormat.temperature(s.cpuTemperature), size: 36); Text(s.cpuTemperature == nil ? "暂无有效读数" : "当前传感器读数").font(.system(size: 11)).foregroundStyle(palette.muted) }
                DeviceDetailCard(title: "GPU 温度", symbol: "thermometer.medium") { DeviceReading(value: DeviceFormat.temperature(s.gpuTemperature), size: 36); Text(s.gpuTemperature == nil ? "暂无有效读数" : "当前传感器读数").font(.system(size: 11)).foregroundStyle(palette.muted) }
                DeviceDetailCard(title: "温度提醒", symbol: "bell") { Text(model.temperatureRule.enabled ? "已开启" : "未开启").font(.system(size: 22)); Text("CPU \(Int(model.temperatureRule.cpuThreshold))°C · GPU \(Int(model.temperatureRule.gpuThreshold))°C").font(.system(size: 11)).foregroundStyle(palette.muted) }
            }
            WBCard {
                HStack { Label("温度趋势", systemImage: "waveform.path.ecg").font(.system(size: 12, weight: .medium)); Spacer(); rangePicker }
                DeviceHistoryChart(points: model.history, kind: .thermal, minutes: minutes).frame(height: expanded ? 260 : 190)
            }
            DeviceDetailColumns {
                DeviceDetailCard(title: "风扇与系统散热", symbol: "fan") {
                    DeviceFanRows(snapshot: s)
                    DeviceFact(label: "系统热状态", value: DeviceFormat.thermal(s.thermalState))
                    DeviceFact(label: "控制方式", value: "系统自动")
                    DeviceFact(label: "CPU / GPU 峰值", value: "\(DeviceFormat.temperature(peak(\.cpuTemperature))) / \(DeviceFormat.temperature(peak(\.gpuTemperature)))")
                }
                DeviceDetailCard(title: "电池与供电", symbol: "battery.75percent") {
                    DevicePowerLine(snapshot: s, compact: false)
                    DeviceFact(label: "电源来源", value: s.battery.map { $0.isPluggedIn ? "电源适配器" : "电池" } ?? "外部电源")
                    DeviceFact(label: "电池健康", value: s.battery.map { DeviceFormat.batteryHealth($0.health) } ?? "无内置电池")
                    DeviceFact(label: "循环计数", value: (s.battery?.cycleCount).map { String($0) } ?? "系统未提供").accessibilityIdentifier("device-battery-cycle-count")
                    DeviceFact(label: "低电量模式", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "开启" : "关闭")
                }
            }
        }
    }
    private func peak(_ path: KeyPath<DeviceHistoryPoint, Double?>) -> Double? {
        let end = model.history.last?.date ?? Date()
        return model.history.filter { end.timeIntervalSince($0.date) <= Double(minutes * 60) }.compactMap { $0[keyPath: path] }.max()
    }
    private var networkInterfaceSummary: String {
        guard let selected = model.selectedInterfaceIDs else { return "自动 · 物理网络" }
        if selected.count == 1, let identifier = selected.first {
            return model.interfaces.first { $0.id == identifier }.map { $0.name + " · " + $0.id } ?? identifier
        }
        return selected.isEmpty ? "未选择接口" : "已选 \(selected.count) 个接口"
    }
    private var networkDetail: some View {
        VStack(spacing: 12) {
            HStack { Text("当前网络接口").font(.system(size: 12)).foregroundStyle(palette.secondary); Spacer(); Button { sheet = .networkOptions } label: { HStack(spacing: 6) { Text(networkInterfaceSummary).lineLimit(1).truncationMode(.tail); Image(systemName: "chevron.down").font(.system(size: 10)).accessibilityHidden(true) }.frame(width: 152, alignment: .leading) }.buttonStyle(WBButtonStyle()).help("管理实时网卡；完整选择列表在接口设置中展示").accessibilityLabel("当前网络接口：" + networkInterfaceSummary).accessibilityIdentifier("device-network-interface-picker") }
            DeviceDetailColumns {
                DeviceDetailCard(title: "下载速度", symbol: "arrow.down") { DeviceReading(value: DeviceFormat.rate(s.network.downloadBytesPerSecond), size: 36) }
                DeviceDetailCard(title: "上传速度", symbol: "arrow.up") { DeviceReading(value: DeviceFormat.rate(s.network.uploadBytesPerSecond), size: 36) }
            }
            WBCard(title: "网络速度趋势", symbol: "waveform.path.ecg") { DeviceHistoryChart(points: model.history, kind: .network, minutes: minutes).frame(height: expanded ? 260 : 190) }
            DeviceDetailColumns {
                DeviceDetailCard(title: "接口信息", symbol: "wifi") {
                    DeviceFact(label: "接口", value: s.network.interfaceNames.isEmpty ? "没有活跃接口" : s.network.interfaceNames.joined(separator: "、"))
                    DeviceFact(label: "状态", value: s.network.downloadBytesPerSecond == nil ? "等待有效采样" : "正在采集")
                    DeviceFact(label: "采样间隔", value: "\(Int(model.samplingInterval)) 秒")
                    Button("采集详情") { sheet = .coverage }.buttonStyle(WBQuietButtonStyle())
                }
                DeviceLinkedDetailCard(title: "流量记录", symbol: "chart.bar", identifier: "fc.device.detail.card.network-traffic", actionTitle: "查看网络监控", action: onOpenNetwork) {
                    let today = model.trafficSummary(period: .day, scope: .all)
                    DeviceFact(label: "今日已记录", value: today.coveredSeconds > 0 ? DeviceTrafficDisplay.adaptive(today.totalBytes) : "暂无记录")
                    Text("周期记录与预算可在网络监控中查看。实时接口选择不改变物理网络账本。").font(.system(size: 11)).foregroundStyle(palette.muted)
                }
            }
        }
    }
    private var storageDetail: some View {
        VStack(spacing: 12) {
            DeviceDetailColumns(minimumCardHeight: 218.0625) {
                DeviceDetailCard(title: s.disk?.name ?? "启动磁盘", symbol: "internaldrive", identifier: "fc.device.detail.card.storage-usage") {
                    Text("已用空间").font(.system(size: 11)).foregroundStyle(palette.muted)
                    DeviceReading(value: DeviceFormat.storage(s.disk?.used), size: 36)
                    DeviceUsageBar(value: s.disk?.percent, tone: DeviceAppearance.storage(s.disk?.percent, palette: palette))
                    DeviceFact(label: "可用空间", value: DeviceFormat.storage(s.disk?.available))
                    DeviceFact(label: "启动卷容量", value: DeviceFormat.storage(s.disk?.total))
                    DeviceFact(label: "已用比例", value: DeviceFormat.percent(s.disk?.percent))
                }
                DeviceDetailCard(title: "卷信息", symbol: "externaldrive") {
                    DeviceFact(label: "文件系统", value: s.disk?.fileSystem ?? "暂无读数")
                    DeviceFact(label: "挂载位置", value: "/System/Volumes/Data")
                    DeviceFact(label: "立即空闲", value: DeviceFormat.storage(s.disk?.immediatelyFree))
                    DeviceFact(label: "系统可回收估算", value: DeviceFormat.storage(s.disk?.reclaimableEstimate))
                    DeviceFact(label: "实时磁盘速率", value: "↓ \(DeviceFormat.rate(s.disk?.readBytesPerSecond)) / ↑ \(DeviceFormat.rate(s.disk?.writeBytesPerSecond))")
                    ForEach(DeviceVolumes.current, id: \.path) { volume in DeviceFact(label: volume.name, value: "\(volume.format) · \(volume.role)") }
                }
            }
            DeviceRuleHelp(text: "存储按十进制显示（1 GB = 10 亿字节），容量约 30 秒刷新。可用空间优先采用系统含按需可回收空间的估算；无法取得估算时显示立即空闲。已用与比例按同一口径计算。这里是启动卷可用容量，APFS 共享容器空间，不等于硬盘标称容量；可回收估算不代表方寸可删除这些文件。", notice: true).accessibilityIdentifier("device-detail-storage-notice")
        }
    }
    private var processesDetail: some View {
        DeviceProcessExplorerView(processes: s.processes, systemCount: s.processTotalCount, query: $query, sort: $processSort, ascending: $ascending, open: { sheet = .process($0) }, leave: closeDetail)
            .frame(height: min(650, max(260, viewportHeight - (contentWidth < 800 ? 144 : 146) - ((model.layoutError ?? model.lastError) == nil ? 0 : 46))))
    }
    private var rangePicker: some View {
        WBSelect("趋势时间范围", selection: $minutes, options: [(5, "最近 5 分钟"), (30, "最近 30 分钟"), (60, "最近 1 小时")]).frame(width: 146)
    }
}

struct DevicePanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 12) { content }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(DeviceCardSurface()) }
}
struct DeviceMemoryComposition: View {
    let memory: DeviceMemorySnapshot?
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                palette.progressTrack
                if let memory, memory.total > 0 {
                    HStack(spacing: 0) {
                        palette.accent.frame(width: geometry.size.width * Double(memory.application) / Double(memory.total))
                        palette.cool.frame(width: geometry.size.width * Double(memory.wired) / Double(memory.total))
                        palette.warning.frame(width: geometry.size.width * Double(memory.compressed) / Double(memory.total))
                    }
                }
            }.clipShape(Capsule())
        }.accessibilityLabel(memory.map { "应用 \(DeviceFormat.capacity($0.application))，固定 \(DeviceFormat.capacity($0.wired))，压缩 \(DeviceFormat.capacity($0.compressed))，可用 \(DeviceFormat.capacity($0.available))" } ?? "内存构成暂无读数")
    }
}
private struct DeviceContentWidth: PreferenceKey {
    static let defaultValue: CGFloat = 864
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
/// Related-detail actions use the same bounded icon surface as the overview
/// and native dashboard cards, while retaining hover/focus disclosure.
private struct DeviceLinkedDetailCard<Content: View>: View {
    let title: String
    let symbol: String
    let identifier: String
    let actionTitle: String
    var spacing: CGFloat = 8
    let action: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardHovered = false
    @FocusState private var actionFocused: Bool

    var body: some View {
        DeviceDetailCard(spacing: 0, identifier: identifier) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 16, height: 16).foregroundStyle(palette.accent).accessibilityHidden(true)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                Spacer(minLength: 0)
                Button(action: action) {
                    Image(systemName: "arrow.up.right")
                        .opacity(cardHovered || actionFocused ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: cardHovered || actionFocused)
                        .accessibilityHidden(true)
                }.buttonStyle(WBIconButtonStyle(size: 28)).focused($actionFocused)
                    .help(actionTitle).accessibilityLabel(actionTitle)
                    .accessibilityIdentifier(identifier + ".action")
            }.frame(height: 22).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: spacing) { content }
        }.onHover { cardHovered = $0 }
    }
}
/// Accepts the row's proposed height before drawing its surface. An outer frame
/// around WBCard would leave the already-painted card at its natural height.
struct DeviceDetailCard<Content: View>: View {
    var title: String?
    var symbol: String?
    var spacing: CGFloat = 8
    var identifier: String?
    let content: Content
    @Environment(\.workbenchPalette) private var palette
    init(title: String? = nil, symbol: String? = nil, spacing: CGFloat = 8, identifier: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.spacing = spacing; self.identifier = identifier; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 7) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(palette.accent) }
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                    Spacer(minLength: 0)
                }.frame(height: 22).padding(.bottom, 10)
            }
            VStack(alignment: .leading, spacing: spacing) { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(14)
        .background(WorkbenchMaterialSurface())
        .accessibilityElement(children: .contain).accessibilityIdentifier(identifier ?? "fc.device.detail.card." + (title ?? "related"))
    }
}
struct DeviceDetailColumns: Layout {
    var spacing: CGFloat = 12
    var firstFraction: CGFloat = 0.5
    // Frozen first-row card heights include their title, content line heights,
    // padding and border. Keep them as minima: longer actual data must grow.
    var minimumCardHeight: CGFloat = 0
    private func widths(_ width: CGFloat, count: Int) -> [CGFloat] {
        guard width >= 620, count > 1 else { return Array(repeating: width, count: count) }
        if count == 2 { return [(width - spacing) * firstFraction, (width - spacing) * (1 - firstFraction)] }
        return Array(repeating: max(0, width - spacing * CGFloat(count - 1)) / CGFloat(count), count: count)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800, compact = width < 620
        let values = widths(width, count: subviews.count)
        let heights = subviews.enumerated().map { max(minimumCardHeight, $0.element.sizeThatFits(.init(width: values[$0.offset], height: nil)).height) }
        return .init(width: width, height: compact ? heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing : heights.max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let compact = bounds.width < 620, values = widths(bounds.width, count: subviews.count)
        var x = bounds.minX, y = bounds.minY
        for (index, view) in subviews.enumerated() {
            let height = max(minimumCardHeight, view.sizeThatFits(.init(width: values[index], height: nil)).height)
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .init(width: values[index], height: compact ? height : bounds.height))
            if compact { y += height + spacing } else { x += values[index] + spacing }
        }
    }
}
struct DeviceVolumes {
    var path: String, name: String, format: String, role: String
    static var current: [Self] {
        ["/", "/System/Volumes/Data"].compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard let v = try? url.resourceValues(forKeys: [.volumeNameKey]) else { return nil }
            var info = statfs(); guard statfs(path, &info) == 0 else { return nil }
            let format = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }.uppercased()
            return Self(path: path, name: v.volumeName ?? path, format: format, role: path == "/" ? "系统卷" : "数据卷")
        }
    }
}

enum DeviceSheet: Identifiable {
    case coverage, sensors, thresholds, networkOptions, process(DeviceProcess)
    var id: String { switch self { case .coverage: "coverage"; case .sensors: "sensors"; case .thresholds: "thresholds"; case .networkOptions: "networkOptions"; case .process(let p): "process-\(p.pid)" } }
    var title: String { switch self { case .coverage: "网络采集详情"; case .sensors: "设备数据来源"; case .thresholds: "状态颜色规则"; case .networkOptions: "网络统计设置"; case .process(let p): p.name } }
}

struct DeviceSheetView: View {
    @Environment(\.workbenchPalette) private var palette
    let item: DeviceSheet
    @ObservedObject var model: DeviceStatusModel
    var dismiss: () -> Void
    @State private var useAutomatic = true
    @State private var selected: Set<String> = []
    @State private var confirmReset = false
    var body: some View {
        DeviceDialog(title: item.title, dismiss: dismiss, maximumBodyHeight: 390) {
            VStack(alignment: .leading, spacing: 12) { content }
        } actions: {
            if case .networkOptions = item {
                Button("开始新记录") { confirmReset = true }.buttonStyle(WBButtonStyle())
                Button("取消", action: dismiss).buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
                Button("保存") { model.setSelectedInterfaces(useAutomatic ? nil : Array(selected)); dismiss() }.buttonStyle(WBButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            } else { Button("完成", action: dismiss).buttonStyle(WBButtonStyle(primary: true)).keyboardShortcut(.defaultAction) }
        }
        .onAppear { useAutomatic = model.selectedInterfaceIDs == nil; selected = Set(model.selectedInterfaceIDs ?? model.interfaces.filter(\.isDefault).map(\.id)) }
        .workbenchModal(isPresented: $confirmReset) {
                DeviceDialog(title: "开始新的网络记录？", dismiss: { confirmReset = false }) {
                    Text("清零本次速度记录的累计值。今日已记录流量与预算的周期累计会保留。").font(.system(size: 12)).foregroundStyle(palette.secondary)
                } actions: {
                    Button("取消") { confirmReset = false }.buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("开始新记录") { model.beginNewNetworkRecording(); confirmReset = false }.buttonStyle(WBButtonStyle(primary: true))
                }
        }
    }
    @ViewBuilder private var content: some View {
        switch item {
        case .coverage:
            DeviceFact(label: "当前统计网卡", value: model.snapshot.network.interfaceNames.joined(separator: "、").isEmpty ? "没有活跃网卡" : model.snapshot.network.interfaceNames.joined(separator: "、"))
            DeviceFact(label: "今天首次有效采集", value: date(model.snapshot.network.todayFirstSample))
            DeviceFact(label: "今天最近有效采集", value: date(model.snapshot.network.todayLastSample))
            DeviceFact(label: "今天有效采集时长", value: DeviceFormat.duration(model.snapshot.network.todayCoverageSeconds))
            DeviceFact(label: "检测到的排除区间", value: String(model.snapshot.network.excludedIntervals))
            DeviceFact(label: "本次记录开始", value: date(model.snapshot.network.recordedSince))
            DeviceFact(label: "本次有效采集时长", value: DeviceFormat.duration(model.snapshot.network.sessionCoverageSeconds))
            explanation("只有两次连续有效、网卡范围相同的计数差才会累计。休眠、计数重置、网卡变化、跨日与超过采样容差的间隔均舍弃。应用未运行期间无法检测或补算；排除区间数不代表全部缺口。")
            explanation("隐藏工作台后保留至少每 10 秒一次的网络采样。曲线只保留当前运行中、窗口可见时最近 1 小时的有效读数，不为缺口补线。本次记录及最近 35 日汇总保存在本机。")
        case .sensors:
            DeviceFact(label: "CPU", value: "Mach 系统计数 · 整机百分比")
            DeviceFact(label: "内存", value: "公开虚拟内存统计与压力通知")
            DeviceFact(label: "网络速度", value: "64 位系统网卡计数 · 当前选择的网卡")
            DeviceFact(label: "流量与预算", value: "物理 Wi-Fi / 有线网卡的有效计数差 · 本机持久化累计")
            DeviceFact(label: "电源", value: "IOKit Power Sources")
            DeviceFact(label: "系统热状态", value: "ProcessInfo")
            DeviceFact(label: "进程", value: "libproc · 仅可访问的进程")
            DeviceFact(label: "GPU 使用率", value: "不可用")
            DeviceFact(label: "CPU / GPU 温度", value: "\(DeviceFormat.temperature(model.snapshot.cpuTemperature)) / \(DeviceFormat.temperature(model.snapshot.gpuTemperature))")
            DeviceFact(label: "风扇转速", value: model.snapshot.fanRPM == nil ? "暂无读数" : "AppleSMC · 只读")
            DeviceFact(label: "温度传感器", value: model.snapshot.sensorSource)
            DeviceFact(label: "CPU 采样点", value: model.snapshot.cpuSensorKeys.joined(separator: "、"))
            DeviceFact(label: "GPU 采样点", value: model.snapshot.gpuSensorKeys.joined(separator: "、"))
            explanation("温度取已识别 CPU / GPU 传感器的有效读数平均值；AppleSMC 是未公开、依赖硬件的只读接口，不修改风扇或功耗，不需要管理员权限。无效值不参与平均，缺失时不补零。首个 CPU 和网络样本只建立基准。")
        case .thresholds:
            DeviceFact(label: "CPU 使用率", value: "75% 留意 · 90% 高负载")
            DeviceFact(label: "磁盘已使用", value: "80% 留意 · 90% 接近上限")
            DeviceFact(label: "内存", value: "只使用系统压力通知")
            DeviceFact(label: "使用电池", value: "≤20% 低电量 · ≤10% 电量不足")
            DeviceFact(label: "接通电源", value: "不触发低电量颜色")
            DeviceFact(label: "流量预算", value: "达到 \(model.budget.warningPercent)% 留意 · 达到 100% 超额")
            DeviceFact(label: "不可用数据", value: "显示 —，不视为 0")
            explanation("颜色只提示状态，并配合文字与数值。系统热状态独立展示，不把它换算成未经测量的温度。")
        case .networkOptions:
            Toggle("自动统计物理 Wi-Fi / 有线网卡", isOn: $useAutomatic).clickableCursor().font(.system(size: 12)).padding(.bottom, 15)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.interfaces) { interface in
                    Toggle(isOn: Binding(get: { selected.contains(interface.id) }, set: { if $0 { selected.insert(interface.id) } else { selected.remove(interface.id) } })) {
                        HStack {
                            Text("\(interface.name) · \(interface.id)")
                            Spacer()
                            Text(interface.isVirtual ? "虚拟网卡" : interface.isActive ? "活跃" : "未连接").foregroundStyle(palette.muted)
                        }
                    }.clickableCursor().disabled(useAutomatic).font(.system(size: 12))
                }
                if model.interfaces.isEmpty { explanation("当前尚未读到网卡。请稍后刷新。") }
            }
            explanation("默认不统计 VPN 与其他虚拟网卡，始终排除回环。手动同时选物理网卡和 VPN 可能重复计算同一流量。修改后从下一组连续样本开始；历史累计保留原统计范围。")
        case .process(let process):
            DeviceFact(label: "进程 ID", value: String(process.pid))
            DeviceFact(label: "CPU", value: DeviceFormat.percent(process.cpuPercent))
            DeviceFact(label: "驻留内存", value: DeviceFormat.bytes(process.residentBytes))
            DeviceFact(label: "线程", value: String(process.threadCount))
            DeviceFact(label: "采样时间", value: date(process.sampledAt))
            if let path = process.executablePath { Text(path).font(.system(size: 11)).foregroundStyle(palette.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            explanation("这是打开详情时的样本。CPU 以整台设备的处理能力为 100%，不是单个核心百分比；驻留内存可能包含共享页。可从进程列表右侧的操作菜单请求退出；应用优先正常退出，强制结束需要另行确认。")
        }
    }
    private func date(_ value: Date?) -> String { value?.formatted(date: .abbreviated, time: .standard) ?? "尚无有效记录" }
    private func explanation(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.top, 14) }
}

struct DeviceFact: View {
    @Environment(\.workbenchPalette) private var palette
    let label: String, value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(palette.secondary).frame(minWidth: 84, alignment: .leading)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.system(size: 11)).frame(minHeight: 16).fixedSize(horizontal: false, vertical: true)
    }
}

struct DeviceProcessIcon: View {
    @Environment(\.workbenchPalette) private var palette
    let path: String?
    @MainActor private static let cache = NSCache<NSString, NSImage>()
    @MainActor static func image(for path: String) -> NSImage {
        let iconPath = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
        if let cached = cache.object(forKey: iconPath as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: iconPath); cache.setObject(image, forKey: iconPath as NSString); return image
    }

    var body: some View {
        Group {
            if let path { Image(nsImage: DeviceProcessIcon.image(for: path)).resizable().interpolation(.high) }
            else { Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(palette.muted).padding(3) }
        }.accessibilityHidden(true)
    }
}

enum DeviceFormat {
    static func storage(_ value: UInt64?) -> String { DeviceStorageCapacity.formatted(value) }
    static func capacity(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        var number = Double(value), unit = 0
        let units = ["B", "KB", "MB", "GB", "TB"]
        while number >= 1024 && unit < units.count - 1 { number /= 1024; unit += 1 }
        let formatted = String(format: "%.1f", number)
        return (formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted) + " " + units[unit]
    }

    static func temperature(_ value: Double?) -> String { value.map { String(format: "%.0f °C", $0) } ?? "暂无读数" }
    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .binary)
    }
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value >= 1_048_576 { return String(format: "%.2f MB/s", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.1f KB/s", value / 1024) }
        return String(format: "%.0f B/s", value)
    }
    static func percent(_ value: Double?) -> String { guard let value, value.isFinite else { return "—" }; return String(format: "%.1f%%", value) }
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds)), days = total / 86400, hours = total / 3600 % 24, minutes = total / 60 % 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        if minutes > 0 { return "\(minutes) 分钟" }
        return "\(total) 秒"
    }
    static func pressure(_ pressure: DevicePressure) -> String { switch pressure { case .normal: "压力低"; case .warning: "压力中等"; case .critical: "压力高"; case .unknown: "等待压力通知" } }
    static func load(_ value: Double?) -> String { guard let value else { return "等待采样" }; return value >= 90 ? "高负载" : value >= 75 ? "较高负载" : "正常" }
    static func thermal(_ state: DeviceThermalState) -> String { switch state { case .nominal: "正常"; case .fair: "轻度升温"; case .serious: "热状态较高"; case .critical: "热状态严重"; case .unknown: "不可用" } }
    static func batteryHealth(_ value: String?) -> String { switch value { case "Good": "正常"; case "Fair": "一般"; case "Poor": "建议维修"; default: value ?? "来源未提供" } }
}
