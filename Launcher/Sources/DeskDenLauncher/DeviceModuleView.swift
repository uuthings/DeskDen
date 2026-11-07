import AppKit
import SwiftUI
import LauncherCore

struct DeviceModuleView: View {
    @ObservedObject var model: DeviceStatusModel
    var onOpenNetwork: () -> Void = {}
    var onOpenCleaning: () -> Void = {}
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
    private var s: DeviceSnapshot { model.snapshot }
    init(model: DeviceStatusModel, onOpenNetwork: @escaping () -> Void = {}, onOpenCleaning: @escaping () -> Void = {}, initialDetail: DeviceCardID? = nil, requestedDetail: Binding<DeviceCardID?> = .constant(nil), requestedDetailReturnTitle: String = "返回设备状态", onCloseRequestedDetail: @escaping () -> Void = {}) {
        self.model = model; self.onOpenNetwork = onOpenNetwork; self.onOpenCleaning = onOpenCleaning
        self.initialDetail = initialDetail; self._requestedDetail = requestedDetail
        self.requestedDetailReturnTitle = requestedDetailReturnTitle; self.onCloseRequestedDetail = onCloseRequestedDetail
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
        WorkbenchScrollView(detail == .processes ? [] : .vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if let detail { detailPage(detail) }
                else {
                    // The sampling note and page actions live in the header, so the
                    // default dashboard fits the window without a footer (现行规范 9.2).
                    WBPageHeader(title: "设备状态", subtitle: "本机状态 · 每 \(Int(model.samplingInterval)) 秒更新") {
                        HStack(spacing: 8) {
                            if editing {
                                if model.undoLayout != nil {
                                    Button { model.undoLayoutChange() } label: { Label("撤销布局修改", systemImage: "arrow.uturn.backward") }
                                        .buttonStyle(WBButtonStyle()).accessibilityIdentifier("device-layout-undo")
                                }
                                Button("恢复默认布局") { resetLayout = true }.buttonStyle(WBButtonStyle()).accessibilityIdentifier("device-layout-reset")
                                Button { library = true } label: { Label("添加卡片", systemImage: "plus") }.buttonStyle(WBButtonStyle())
                            } else {
                                Button { sheet = .sensors } label: { Label("数据来源", systemImage: "info.circle") }
                                    .buttonStyle(WBButtonStyle()).accessibilityIdentifier("device-data-sources")
                            }
                            Button { editing.toggle(); library = false } label: { Label(editing ? "完成" : "编辑布局", systemImage: editing ? "checkmark" : "slider.horizontal.3") }
                                .buttonStyle(WBButtonStyle(primary: editing)).accessibilityIdentifier("fc.action.device.edit")
                        }
                    }
                    if let error = model.layoutError ?? model.lastError {
                        Text(error).font(.system(size: 11)).foregroundStyle(palette.warning).padding(.bottom, 12)
                    }
                    DeviceDashboardRepresentable(model: model, editing: editing, scale: 1, expanded: expanded, minimumHeight: dashboardHeight, open: { card in
                        if card == .traffic || card == .network { onOpenNetwork() }
                        else { detail = card; thermalSettings = false }
                    }, heightChanged: { height in if abs(height - gridHeight) > 0.5 { gridHeight = height } })
                        .frame(height: gridHeight)
                    if model.dashboardLayout.cards.allSatisfy({ !$0.visible }) {
                        Button("从卡片库添加信息") { editing = true; library = true }.buttonStyle(WBButtonStyle()).padding(.top, 12)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .topLeading).foregroundStyle(palette.text)
                .workbenchPageCanvas()
                .id("device-page-top")
                .accessibilityElement(children:.contain).accessibilityIdentifier(detail.map { "fc.page.device.\($0.rawValue)" } ?? "fc.page.device")
        }.scrollContentBackground(.hidden).scrollBounceBehavior(.basedOnSize)
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
    /// Page height below the header (62 + 12) and any status line; the trend
    /// row of the default dashboard takes what the other rows leave.
    private var errorLineHeight: CGFloat { (model.layoutError ?? model.lastError) == nil ? 0 : 28 }
    private var dashboardHeight: CGFloat { max(0, viewportHeight - 74 - errorLineHeight) }
    /// The model phrases a source as "返回首页"; the header names only the destination.
    private var backTitle: String {
        guard detailWasRequested else { return "设备状态" }
        return requestedDetailReturnTitle.hasPrefix("返回") ? String(requestedDetailReturnTitle.dropFirst(2)) : requestedDetailReturnTitle
    }
    private var cardLibrary: some View {
        DeviceDialog(title: "卡片库", dismiss: { library = false }) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(DeviceDashboardLayout.defaultCards.map(\.id), id: \.self) { id in
                    HStack(spacing: 8) {
                        WorkbenchContentIcon(device: id, size: 16).foregroundStyle(palette.accent)
                        Text(id.title).font(.system(size: 12))
                        Spacer(minLength: 8)
                        let added = model.dashboardLayout.cards.first { $0.id == id }?.visible == true
                        if added { Text("已显示").font(.system(size: 11)).foregroundStyle(palette.muted) }
                        else { Button("添加") { model.changeCard(id) { $0.visible = true }; library = false }.buttonStyle(WBButtonStyle(compact: true)).accessibilityLabel("添加" + id.title) }
                    }.frame(height: 36).overlay(alignment: .bottom) { palette.line.frame(height: 1) }
                }
                Text("网络速度和今日流量也可在网络监控集中查看。").font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 10)
            }
        } actions: { Button("完成") { library = false }.buttonStyle(WBButtonStyle(primary: true)).keyboardShortcut(.defaultAction) }
    }
    @ViewBuilder private func detailPage(_ card: DeviceCardID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The way back sits before the title and the subtitle says what the
            // page shows (现行规范 4.1, 9.2).
            WBPageHeader(title: card.title, subtitle: detailDescription(card),
                         back: WBPageBack(title: backTitle, identifier: "device-detail-back", escapes: true, action: closeDetail)) {
                if card == .storage { Button { onOpenCleaning() } label: { Label("空间清理", systemImage: "internaldrive") }.buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("device-detail-open-cleaning") }
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
            .environment(\.workbenchControlBorders, card != .processes)
    }
    private func detailDescription(_ card: DeviceCardID) -> String {
        switch card {
        case .profile: "硬件配置与系统信息"
        case .cpu: s.physicalCPUCount > 0 ? "\(s.chipName) · \(s.physicalCPUCount) 核中央处理器" : "中央处理器的使用率与负载"
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
                    DeviceFact(label: "统一内存", value: DeviceFormat.capacity(s.memory?.total))
                    DeviceFact(label: "显示器", value: NSScreen.screens.map(\.localizedName).joined(separator: "、"))
                }
                DeviceDetailCard(title: "系统与存储", symbol: "internaldrive", spacing: 12) {
                    DeviceFact(label: "操作系统", value: DeviceFormat.systemVersion)
                    DeviceFact(label: "系统卷", value: s.disk?.name ?? "暂无读数")
                    DeviceFact(label: "文件系统", value: s.disk?.fileSystem ?? "暂无读数")
                    DeviceFact(label: "总容量", value: DeviceFormat.storage(s.disk?.total))
                    DeviceFact(label: "可用空间", value: DeviceFormat.storage(s.disk?.available))
                    DeviceFact(label: "运行时间", value: DeviceFormat.duration(s.uptime))
                }
            }
            DeviceRuleHelp(text: "型号标识符（如 Mac14,6）是 Apple 用来区分硬件机型的代码，不是系统版本。性能核适合编译、渲染等繁重任务；能效核用较低功耗处理日常与后台任务，由 macOS 自动分配。设备信息来自本机系统，可读配置因机型而异。", notice: true).accessibilityIdentifier("device-detail-profile-notice")
        }
    }
    private func performanceDetail(memory: Bool) -> some View {
        VStack(spacing: 12) {
            // First-row page readings are 30, secondary readings in the same
            // row 24 (现行规范 9.2).
            DeviceDetailColumns(minimumCardHeight: 128.25) {
                DeviceDetailCard(title: "当前使用率", symbol: "cpu") { DeviceReading(value: DeviceFormat.percent(s.cpuPercent), size: 30); Text("以全部 CPU 总算力为 100%").font(.system(size: 11)).foregroundStyle(palette.muted) }
                DeviceDetailCard(title: "用户进程", symbol: "macwindow") { DeviceReading(value: DeviceFormat.percent(s.cpuUserPercent)); Text("当前应用与后台任务").font(.system(size: 11)).foregroundStyle(palette.muted) }
                DeviceDetailCard(title: "系统", symbol: "gearshape") { DeviceReading(value: DeviceFormat.percent(s.cpuSystemPercent)); Text("系统内核与系统服务").font(.system(size: 11)).foregroundStyle(palette.muted) }
            }
            WBCard {
                chartTitle("CPU 使用率趋势")
                DeviceHistoryChart(points: model.history, kind: .cpu, minutes: minutes).frame(height: expanded ? 260 : 190)
            }
            DeviceDetailColumns {
                DeviceDetailCard(title: "处理器", symbol: "cpu", identifier: "fc.device.detail.card.cpu-processor") {
                    DeviceFact(label: "芯片", value: s.chipName)
                    DeviceFact(label: "CPU 核心", value: s.physicalCPUCount > 0 ? "\(s.physicalCPUCount) 核" : "读取中")
                    DeviceFact(label: "核心构成", value: s.performanceCores.flatMap { p in s.efficiencyCores.map { "\(p) 个性能核 + \($0) 个能效核" } } ?? "系统未提供")
                }
                DeviceLinkedDetailCard(title: "相关进程", symbol: "macwindow", identifier: "fc.device.detail.card.cpu-processes", actionTitle: "查看全部进程", trailing: "查看全部进程", spacing: 0, action: { detail = .processes }) {
                    VStack(spacing: 0) {
                        DevicePreviewHeader(leading: "名称", trailing: "CPU 占用")
                        ForEach(DeviceProcess.filtered(s.processes, query: "", sort: .cpu).prefix(3)) { process in
                            HStack(spacing: 8) {
                                DeviceProcessIcon(path: process.executablePath).frame(width: 16, height: 16)
                                Text(process.displayName).lineLimit(1).help(process.displayName); Spacer()
                                Text(DeviceFormat.percent(process.cpuPercent)).monospacedDigit().foregroundStyle(palette.secondary)
                            }.font(.system(size: 12)).frame(height: 24)
                        }
                    }
                }
            }
        }
    }
    // Both first-row cards carry a title row; the second table became a preview
    // that leads to the process page, where quitting is handled (现行规范 9.2).
    private var memoryDetail: some View {
        VStack(spacing: 12) {
            DeviceDetailColumns(firstFraction: 1.1 / 2.1) {
                DeviceDetailCard(title: "统一内存", symbol: "memorychip", identifier: "fc.device.detail.card.memory-usage") {
                    HStack(alignment: .firstTextBaseline, spacing: 4) { DeviceReading(value: DeviceFormat.capacity(s.memory?.used), size: 30); Text("/ \(DeviceFormat.capacity(s.memory?.total))").font(.system(size: 11)).foregroundStyle(palette.secondary) }
                    DeviceMemoryComposition(memory: s.memory).frame(height: 5).padding(.top, 2)
                    HStack(spacing: 14) {
                        DeviceLegendItem(title: "应用", value: DeviceFormat.capacity(s.memory?.application), color: palette.accent)
                        DeviceLegendItem(title: "固定", value: DeviceFormat.capacity(s.memory?.wired), color: palette.cool)
                        DeviceLegendItem(title: "压缩", value: DeviceFormat.capacity(s.memory?.compressed), color: palette.warning)
                        DeviceLegendItem(title: "可用", value: DeviceFormat.capacity(s.memory?.available), color: palette.progressTrack)
                    }.padding(.top, 2)
                }
                DeviceDetailCard(title: "内存压力", symbol: "waveform.path.ecg", identifier: "fc.device.detail.card.memory-pressure") {
                    Text(DeviceFormat.pressure(s.memory?.pressure ?? .unknown)).font(.system(size: 17, weight: .medium)).foregroundStyle((s.memory?.pressure == .normal ? palette.success : DeviceAppearance.pressure(s.memory?.pressure, palette: palette)))
                    Text("交换 \(DeviceFormat.capacity(s.memory?.swapUsed)) · 缓存文件 \(DeviceFormat.capacity(s.memory?.cached))").font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Text(s.memory?.pressure == .normal ? "macOS 会利用空闲内存做缓存，当前无需主动清空。" : "结合持续压力与交换空间判断，先保存工作，再按需复核应用。").font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            DeviceLinkedDetailCard(title: "内存占用最多", symbol: "macwindow", identifier: "fc.device.detail.card.memory-top", actionTitle: "查看全部进程", trailing: "查看全部进程", spacing: 0,
                                   action: { processSort = .memory; ascending = false; detail = .processes }) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                        Text("进程数").frame(width: 90, alignment: .trailing)
                        Text("内存").frame(width: 90, alignment: .trailing)
                    }.font(.system(size: 11)).foregroundStyle(palette.secondary).frame(height: 28)
                    ForEach(topMemoryGroups) { group in
                        HStack(spacing: 12) {
                            HStack(spacing: 8) {
                                DeviceProcessIcon(path: group.application?.executablePath ?? group.processes.first?.executablePath).frame(width: 20, height: 20)
                                Text(group.name).font(.system(size: group.application == nil ? 12 : 13, weight: group.application == nil ? .regular : .medium))
                                    .lineLimit(1).help(group.name)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(group.application == nil ? "单个进程" : "\(group.processes.count) 个进程").font(.system(size: 11)).foregroundStyle(palette.muted).frame(width: 90, alignment: .trailing)
                            Text(DeviceFormat.bytes(group.residentBytes)).font(.system(size: 12)).monospacedDigit().frame(width: 90, alignment: .trailing)
                        }.frame(height: 36).overlay(alignment: .top) { palette.line.frame(height: 1) }
                    }
                    if topMemoryGroups.isEmpty {
                        Text("正在读取可访问的进程").font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .leading).frame(height: 36)
                    }
                }
            }
        }
    }
    /// The eight applications or independent processes using the most memory.
    private var topMemoryGroups: [DeviceProcessGroup] {
        Array(DeviceProcessExplorer.groups(s.processes, grouped: true, filter: .all, query: "", sort: .memory, ascending: false).prefix(8))
    }
    private var thermalDetail: some View {
        let status = DeviceThermalPresentation(snapshot: s, rule: model.temperatureRule)
        return VStack(spacing: 12) {
            // Temperature alerts open only from the header; the status card and
            // fan card no longer repeat each other (现行规范 9.2).
            DeviceDetailColumns(minimumCardHeight: 128.25) {
                DeviceDetailCard(title: "CPU 温度", symbol: "thermometer.medium") { DeviceReading(value: DeviceFormat.temperature(s.cpuTemperature), size: 30).foregroundStyle(status.cpuLevel == .normal ? palette.text : status.cpuLevel.color(palette: palette)); Text(s.cpuTemperature == nil ? "暂无有效读数" : "提醒阈值 \(model.temperatureRule.cpuThreshold.formatted())°C").font(.system(size: 11)).foregroundStyle(palette.muted) }
                DeviceDetailCard(title: "GPU 温度", symbol: "thermometer.medium") { DeviceReading(value: DeviceFormat.temperature(s.gpuTemperature), size: 30).foregroundStyle(status.gpuLevel == .normal ? palette.text : status.gpuLevel.color(palette: palette)); Text(s.gpuTemperature == nil ? "暂无有效读数" : "提醒阈值 \(model.temperatureRule.gpuThreshold.formatted())°C").font(.system(size: 11)).foregroundStyle(palette.muted) }
                DeviceDetailCard(title: "散热状态", symbol: status.symbol) {
                    DeviceThermalStatusBadge(status: status)
                    Text("macOS 报告：\(DeviceFormat.thermal(s.thermalState))").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            }
            WBCard {
                chartTitle("温度趋势")
                DeviceHistoryChart(points: model.history, kind: .thermal, minutes: minutes).frame(height: expanded ? 260 : 190)
            }
            DeviceDetailColumns {
                DeviceDetailCard(title: "风扇", symbol: "fan") {
                    DeviceFanRows(snapshot: s)
                    DeviceFact(label: "控制方式", value: "系统自动")
                    DeviceFact(label: "CPU / GPU 峰值", value: "\(DeviceFormat.temperature(peak(\.cpuTemperature))) / \(DeviceFormat.temperature(peak(\.gpuTemperature)))")
                }
                DeviceDetailCard(title: "电池与供电", symbol: "battery.75percent") {
                    DevicePowerLine(snapshot: s, compact: false, prominent: true)
                    DeviceFact(label: "电池健康", value: s.battery.map { DeviceFormat.batteryHealth($0.health) } ?? "无内置电池")
                    DeviceFact(label: "循环计数", value: (s.battery?.cycleCount).map { String($0) } ?? "系统未提供").accessibilityIdentifier("device-battery-cycle-count")
                    DeviceFact(label: "低电量模式", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "开启" : "关闭")
                }
            }
            if model.temperatureRule.notificationsEnabled && model.notificationPermission != .authorized {
                DeviceNotificationStatusView(model: model)
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
            // Same drawing as the home disk card; the volume card reads its mount
            // point from the system and names volumes by role (现行规范 9.2).
            DeviceDetailColumns(minimumCardHeight: 218.0625) {
                DeviceDetailCard(title: s.disk?.name ?? "启动磁盘", symbol: "internaldrive", identifier: "fc.device.detail.card.storage-usage") {
                    Text("已用空间").font(.system(size: 11)).foregroundStyle(palette.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        DeviceReading(value: DeviceFormat.storage(s.disk?.used), size: 30)
                        Text("/ \(DeviceFormat.storage(s.disk?.total))").font(.system(size: 11)).foregroundStyle(palette.secondary)
                        Spacer(minLength: 8)
                        Text(DeviceFormat.percent(s.disk?.percent)).font(.system(size: 17, weight: .medium)).monospacedDigit()
                            .foregroundStyle(DeviceAppearance.storage(s.disk?.percent, palette: palette))
                    }
                    DeviceStorageBar(disk: s.disk)
                    HStack(spacing: 14) {
                        DeviceLegendItem(title: "已用", value: DeviceFormat.storage(s.disk?.used), color: DeviceAppearance.storage(s.disk?.percent, palette: palette))
                        DeviceLegendItem(title: "系统可回收（估算）", value: DeviceFormat.storage(s.disk?.reclaimableEstimate), color: DeviceStorageBar.reclaimableTone(palette))
                        DeviceLegendItem(title: "立即空闲", value: DeviceFormat.storage(s.disk?.immediatelyFree), color: DeviceStorageBar.freeTone(palette))
                    }
                    DeviceFact(label: "可用空间", value: DeviceFormat.storage(s.disk?.available)).padding(.top, 4)
                    DeviceFact(label: "总容量", value: DeviceFormat.storage(s.disk?.total))
                }
                DeviceDetailCard(title: "卷信息", symbol: "externaldrive") {
                    DeviceFact(label: "文件系统", value: s.disk?.fileSystem ?? "暂无读数")
                    DeviceFact(label: "挂载位置", value: s.disk?.mountPoint ?? "暂无读数")
                    ForEach(DeviceVolumes.current, id: \.path) { volume in DeviceFact(label: volume.role, value: "\(volume.name) · \(volume.format)") }
                    DeviceFact(label: "磁盘读写", value: "读取 \(DeviceFormat.rate(s.disk?.readBytesPerSecond)) · 写入 \(DeviceFormat.rate(s.disk?.writeBytesPerSecond))")
                }
            }
            DeviceRuleHelp(text: "存储按十进制显示（1 GB = 10 亿字节），约 30 秒刷新。可用空间 = 立即空闲 + 系统可回收（估算）；读不到估算时只计立即空闲。这里是启动卷的容量，APFS 卷共享容器空间，不等于硬盘标称容量；系统可回收不是方寸可以删除的文件。", notice: true).accessibilityIdentifier("device-detail-storage-notice")
        }
    }
    private var processesDetail: some View {
        DeviceProcessExplorerView(processes: s.processes, systemCount: s.processTotalCount, query: $query, sort: $processSort, ascending: $ascending, open: { sheet = .process($0) }, leave: closeDetail)
            .frame(height: min(650, max(260, viewportHeight - 74 - errorLineHeight)))
    }
    private var rangePicker: some View {
        WBSelect("趋势时间范围", selection: $minutes, options: [(5, "最近 5 分钟"), (30, "最近 30 分钟"), (60, "最近 1 小时")]).frame(width: 146)
    }
    private func chartTitle(_ title: String) -> some View {
        HStack(spacing: 7) {
            WorkbenchContentIcon(symbol: "waveform.path.ecg", size: 16).foregroundStyle(palette.accent)
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(); rangePicker
        }
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
/// A related summary has one destination across its complete card surface.
private struct DeviceLinkedDetailCard<Content: View>: View {
    let title: String
    let symbol: String
    let identifier: String
    let actionTitle: String
    /// A visible text cue in the title row; the whole card stays the target.
    var trailing: String? = nil
    var spacing: CGFloat = 8
    let action: () -> Void
    @ViewBuilder let content: Content
    var body: some View {
        Button(action: action) {
            DeviceDetailCard(title: title, symbol: symbol, spacing: spacing, trailing: trailing.map { $0 + " ›" }) { content }
                .contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(ClickablePlainButtonStyle())
            .help(actionTitle).accessibilityHint(actionTitle)
            .accessibilityIdentifier(identifier)
    }
}
/// The header of a read-only preview list inside a card (现行规范 4.5 exception).
struct DevicePreviewHeader: View {
    let leading: String, trailing: String
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        HStack { Text(leading); Spacer(); Text(trailing) }
            .font(.system(size: 11)).foregroundStyle(palette.muted).frame(height: 16).padding(.bottom, 4)
    }
}
/// A colored dot names one segment of a bar.
struct DeviceLegendItem: View {
    let title: String, value: String, color: Color
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(palette.secondary)
            Text(value).monospacedDigit().foregroundStyle(palette.text)
        }.font(.system(size: 11)).lineLimit(1).fixedSize()
    }
}
/// Accepts the row's proposed height before drawing its surface. An outer frame
/// around WBCard would leave the already-painted card at its natural height.
struct DeviceDetailCard<Content: View>: View {
    var title: String?
    var symbol: String?
    var spacing: CGFloat = 8
    var identifier: String?
    var trailing: String?
    let content: Content
    @Environment(\.workbenchPalette) private var palette
    init(title: String? = nil, symbol: String? = nil, spacing: CGFloat = 8, identifier: String? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.spacing = spacing; self.identifier = identifier; self.trailing = trailing; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                // The shared card title: 16-point icon and 13 medium (现行规范 4.2).
                HStack(spacing: 7) {
                    if let symbol { WorkbenchContentIcon(symbol: symbol, size: 16).foregroundStyle(palette.accent) }
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text)
                    Spacer(minLength: 0)
                    if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(palette.accent) }
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
            // Both APFS volumes often share one name, so the role is the label.
            return Self(path: path, name: v.volumeName ?? path, format: format, role: path == "/" ? "系统卷" : "数据卷")
        }
    }
}

enum DeviceSheet: Identifiable {
    case coverage, sensors, thresholds, networkOptions, process(DeviceProcess)
    var id: String { switch self { case .coverage: "coverage"; case .sensors: "sensors"; case .thresholds: "thresholds"; case .networkOptions: "networkOptions"; case .process(let p): "process-\(p.pid)" } }
    var title: String { switch self { case .coverage: "网络采集详情"; case .sensors: "设备数据来源"; case .thresholds: "状态颜色规则"; case .networkOptions: "网络统计设置"; case .process(let p): p.displayName } }
}

struct DeviceSheetView: View {
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.timeZone) private var timeZone
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
            DeviceFact(label: "磁盘已使用", value: "70% 留意 · 90% 接近上限")
            DeviceFact(label: "内存", value: "只使用系统压力通知")
            DeviceFact(label: "使用电池", value: "≤20% 低电量 · ≤10% 电量不足")
            DeviceFact(label: "接通电源", value: "不触发低电量颜色")
            DeviceFact(label: "流量预算提醒", value: "达到 \(model.budget.warningPercent)% 通知 · 达到 100% 额度上限")
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
    /// Dates follow the workbench city's time zone (现行规范 5.3).
    private func date(_ value: Date?) -> String {
        guard let value else { return "尚无有效记录" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm"
        return formatter.string(from: value)
    }
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
        }.font(.system(size: 12)).frame(minHeight: 18).fixedSize(horizontal: false, vertical: true)
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
    /// Memory keeps the system's binary units; GB and TB keep one decimal and
    /// MB and smaller are whole numbers, moving up a unit at 1,000 (现行规范 5.2).
    static func capacity(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        var number = Double(value), unit = 0
        let units = ["B", "KB", "MB", "GB", "TB"]
        func text(_ number: Double, _ unit: Int) -> String { unit >= 3 ? String(format: "%.1f", number) : String(format: "%.0f", number) }
        while unit < units.count - 1, (Double(text(number, unit)) ?? 0) >= 1_000 { number /= 1024; unit += 1 }
        return text(number, unit) + " " + units[unit]
    }

    static func temperature(_ value: Double?) -> String { value.map { String(format: "%.0f °C", $0) } ?? "暂无读数" }
    /// Process and memory sizes share the capacity format, so one column never
    /// mixes "4.66 GB" with "860 MB".
    static func bytes(_ value: UInt64?) -> String { capacity(value) }
    /// "macOS 27.0（26A428）", with the build number read from the kernel.
    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = "macOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return version }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return version }
        return version + "（" + String(cString: buffer) + "）"
    }
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value >= 1_048_576 { return String(format: "%.2f MB/s", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.1f KB/s", value / 1024) }
        return String(format: "%.0f B/s", value)
    }
    static func percent(_ value: Double?) -> String { UsagePercentage.text(value) }
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds)), days = total / 86400, hours = total / 3600 % 24, minutes = total / 60 % 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        if minutes > 0 { return "\(minutes) 分钟" }
        return "\(total) 秒"
    }
    static func pressure(_ pressure: DevicePressure) -> String { switch pressure { case .normal: "压力低"; case .warning: "压力中等"; case .critical: "压力高"; case .unknown: "等待压力通知" } }
    static func load(_ value: Double?) -> String {
        switch UsageConsumptionLevel.classify(percent: value) {
        case .unknown: "等待采样"
        case .normal: "正常"
        case .warning: "较高负载"
        case .critical: "高负载"
        }
    }
    static func thermal(_ state: DeviceThermalState) -> String { switch state { case .nominal: "正常"; case .fair: "轻度升温"; case .serious: "热状态较高"; case .critical: "热状态严重"; case .unknown: "不可用" } }
    static func batteryHealth(_ value: String?) -> String { switch value { case "Good": "正常"; case "Fair": "一般"; case "Poor": "建议维修"; default: value ?? "来源未提供" } }
}
