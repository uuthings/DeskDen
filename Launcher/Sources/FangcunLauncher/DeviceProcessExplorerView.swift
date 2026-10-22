import SwiftUI
import Darwin
import LauncherCore

/// Live readings never continuously reshuffle the table; only the result rows scroll.
struct DeviceProcessExplorerView: View {
    let processes: [DeviceProcess]
    let systemCount: Int
    @Binding var query: String
    @Binding var sort: DeviceProcessSort
    @Binding var ascending: Bool
    let open: (DeviceProcess) -> Void
    var leave: () -> Void = {}
    var memoryFocused = false
    @Environment(\.workbenchPalette) private var palette
    @State private var appliedSort: DeviceProcessSort = .cpu
    @State private var appliedAscending = false
    @State private var contentWidth: CGFloat = 864
    private var pidWidth: CGFloat { memoryFocused ? (contentWidth < 800 ? 48 : 64) : 62 }
    private var memoryWidth: CGFloat { memoryFocused ? (contentWidth < 800 ? 72 : 88) : 65 }
    private var actionWidth: CGFloat { memoryFocused ? (contentWidth < 800 ? 100 : 112) : 76 }
    private var sortSelection: Binding<DeviceProcessSort> { Binding(get: { sort }, set: { sort = $0; ascending = $0 == .name || $0 == .pid }) }
    @State private var filter: DeviceProcessFilter = .all
    @State private var grouped = true
    @State private var expandedGroups = Set<String>()
    @State private var order: [String] = []
    @State private var actionRequest: DeviceProcessActionRequest?
    @State private var actionMessage: String?
    @State private var actionFailed = false
    @State private var processProtection: DeviceProcessProtectionInfo?

    private var candidates: [DeviceProcessGroup] {
        DeviceProcessExplorer.groups(processes, grouped: grouped, filter: filter, query: query, sort: appliedSort, ascending: appliedAscending)
    }
    private var results: [DeviceProcessGroup] {
        let values = candidates, lookup = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        return DeviceProcessExplorer.stableOrder(values.map(\.id), previous: order).compactMap { lookup[$0] }
    }
    private var hasFilter: Bool { filter != .all || !query.isEmpty }
    private var viewportKey: String { "\(filter.rawValue)|\(query)|\(grouped)" }
    private var matchingCount: Int { results.reduce(0) { $0 + $1.processes.count } }

    var body: some View {
        GeometryReader { geometry in
            Group {
            if memoryFocused { resultCard }
            else {
                HStack(alignment: .top, spacing: 12) {
                    filterRail(compact: geometry.size.height < 430).frame(width: geometry.size.width < 800 ? 145 : 166)
                    resultCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(height: geometry.size.height)
            }
            }.onChange(of: geometry.size.width, initial: true) { _, width in contentWidth = width }
        }
        .onAppear {
            if memoryFocused { sort = .memory; ascending = false }
            appliedSort = sort; appliedAscending = ascending; reorder()
        }
        .onChange(of: viewportKey) { _, _ in reorder() }
        .onChange(of: candidates.map(\.id)) { _, ids in order = DeviceProcessExplorer.stableOrder(ids, previous: order) }
        .workbenchModal(item: $actionRequest) { request in
            DeviceProcessActionDialog(request: request, memoryFocused: memoryFocused,
                                      dismiss: { actionRequest = nil },
                                      force: { actionRequest = .init(name: request.name, processes: request.processes, mode: .force, wholeApplication: request.wholeApplication) },
                                      perform: perform)
        }
        .workbenchModal(isPresented: Binding(get: { processProtection != nil }, set: { if !$0 { processProtection = nil } }), width: 440) {
            WorkbenchDialogFrame(title: "进程保护说明", dismiss: { processProtection = nil }) {
                VStack(alignment: .leading, spacing: 12) {
                    Label(processProtection?.name ?? "进程", systemImage: "lock.shield").font(.system(size: 14, weight: .medium))
                    Text(processProtection?.reason ?? "进程身份暂不可核验，请重新选择。")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(processProtection?.guidance ?? "你仍可查看进程详情。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            } actions: { Spacer(); Button("知道了") { processProtection = nil }.buttonStyle(WBButtonStyle(primary: true)) }
        }
    }
    private func reorder() { order = candidates.map(\.id) }
    private func applySort() { appliedSort = sort; appliedAscending = ascending; reorder() }
    private func perform(_ request: DeviceProcessActionRequest) {
        switch DeviceProcessActionService.perform(request) {
        case .success(let message): actionMessage = message; actionFailed = false
        case .failure(let error): actionMessage = error.localizedDescription; actionFailed = true
        }
    }

    private func filterRail(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            filterButton(.all, title: "全部进程", subtitle: "当前可访问的进程")
            filterButton(.applications, title: "应用进程", subtitle: "含所属辅助进程")
            filterButton(.highCPU, title: "CPU 较高", subtitle: grouped ? "应用合计 ≥ 5%" : "单进程 ≥ 5%")
            filterButton(.highMemory, title: "内存较高", subtitle: grouped ? "应用合计 ≥ 500 MiB" : "单进程 ≥ 500 MiB")
            filterButton(.background, title: "独立后台", subtitle: "未归属应用包")
            palette.line.frame(height: 1).padding(.vertical, 8)
            Text("\(grouped ? "应用合计" : "单进程") CPU ≥ 5%\n\(grouped ? "应用合计" : "单进程") ≥ 500 MiB\n独立后台按单进程计算\n\n数值更新时保持顺序。\n系统进程仅供查看。")
                .font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(3).padding(.horizontal, 8).padding(.vertical, 6)
            if hasFilter { Button("清除筛选与搜索") { filter = .all; query = "" }.buttonStyle(WBQuietButtonStyle()).padding(.horizontal, 8).accessibilityIdentifier("process-filter-reset") }
        }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading).background(DeviceCardSurface())
    }
    private func filterButton(_ value: DeviceProcessFilter, title: String, subtitle: String) -> some View {
        let groups = DeviceProcessExplorer.groups(processes, grouped: grouped, filter: value, query: "", sort: appliedSort, ascending: appliedAscending)
        let processCount = groups.reduce(0) { $0 + $1.processes.count }
        return Button { filter = value } label: {
            HStack(spacing: 7) {
                Text(title).lineLimit(1)
                Spacer(minLength: 1)
                Text(grouped ? "\(groups.count) 组" : "\(processCount) 项").monospacedDigit().foregroundStyle(palette.muted).fixedSize()
            }.font(.system(size: 11)).padding(.horizontal, 8).frame(height: 36)
                .background(filter == value ? palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).foregroundStyle(filter == value ? palette.text : palette.secondary)
            .accessibilityLabel("\(title)，\(grouped ? "\(groups.count) 组，包含" : "")\(processCount) 个进程，\(subtitle)")
            .accessibilityValue(filter == value ? "已选择" : "").accessibilityIdentifier("process-filter-\(value.rawValue)").help(subtitle)
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if memoryFocused {
                HStack { Text("哪些应用正在使用内存").font(.system(size: 12, weight: .medium)); Spacer(); Text("\(results.count) \(grouped ? "个应用与进程组" : "个进程")").font(.system(size: 11)).foregroundStyle(palette.muted) }.padding(.bottom, 12)
            }
            HStack(spacing: 8) {
                if memoryFocused {
                    memoryFilter("全部", .all); memoryFilter("应用", .applications); memoryFilter("系统与后台", .background)
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                    TextField(memoryFocused ? "搜索应用或 PID" : "搜索名称或 PID", text: $query).textFieldStyle(.plain).onExitCommand { if query.isEmpty { leave() } else { query = "" } }.accessibilityIdentifier("process-search")
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除进程搜索") }
                }.font(.system(size: 12)).padding(.horizontal, 10).frame(minWidth: 120, maxWidth: .infinity).frame(height: 32).background(WorkbenchMaterialSurface(kind: .control, radius: 8))
                Button { grouped.toggle() } label: { Label(memoryFocused ? (grouped ? "按应用聚合" : "逐个进程") : (grouped ? "按应用" : "全部展开"), systemImage: grouped ? "square.3.layers.3d" : "list.bullet") }.buttonStyle(WBButtonStyle(compact: true)).accessibilityLabel("按应用聚合").accessibilityIdentifier("process-group-toggle")
                WBSelect("排序", selection: sortSelection, options: memoryFocused ? [(.memory, "内存占用"), (.name, "名称")] : [(.cpu, "CPU 占用"), (.memory, "内存占用"), (.name, "名称"), (.pid, "PID")]).frame(width: 108)
                if memoryFocused { Button("重新排序", action: applySort).buttonStyle(WBButtonStyle(compact: true)).help("按所选方式重新排序；实时读数更新保持既有顺序") }
            }.padding(memoryFocused ? 0 : 12).padding(.bottom, memoryFocused ? 12 : 0).overlay(alignment: .bottom) { if !memoryFocused { palette.line.frame(height: 1) } }
            tableHeader
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("process-list-top")
                        ForEach(results) { group in
                            if grouped && group.application != nil {
                                groupRow(group)
                                if expandedGroups.contains(group.id) || !query.isEmpty { ForEach(group.processes, id: \.identity) { process in processRow(process, child: true) } }
                            } else if let process = group.processes.first { processRow(process, child: false) }
                        }
                        if results.isEmpty {
                            VStack(spacing: 9) {
                                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .light)).foregroundStyle(palette.muted)
                                Text("没有匹配的应用或进程").font(.system(size: 12, weight: .medium))
                                Text(hasFilter ? "更换筛选条件，或搜索其他名称与 PID。" : "当前尚未读到可访问的进程。").font(.system(size: 11)).foregroundStyle(palette.muted)
                                if hasFilter { Button("显示全部进程") { filter = .all; query = "" }.buttonStyle(WBButtonStyle(compact: true)) }
                            }.padding(.vertical, 28).frame(maxWidth: .infinity)
                        }
                    }.background(WorkbenchOverlayScrollbars())
                }.scrollIndicators(.visible).accessibilityIdentifier("process-results-scroll")
                    .onChange(of: viewportKey) { _, _ in reader.scrollTo("process-list-top", anchor: .top) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if memoryFocused {
                Text("读数刷新保持顺序，点「重新排序」才应用新顺序。可操作的应用可在确认后退出。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 10)
            } else {
                HStack(spacing: 6) {
                    Text((grouped ? "\(results.count) 组 · 含 \(matchingCount) 个进程" : "\(matchingCount) 个进程") + " · 共 \(processes.count) 项").monospacedDigit().help("已读取 \(processes.count) / \(max(systemCount, processes.count)) 项；未读取 \(max(0, systemCount - processes.count)) 项")
                    Spacer(minLength: 0); Button("重新排序", action: applySort).buttonStyle(WBQuietButtonStyle())
                }.font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.horizontal, 13).frame(height: 34).overlay(alignment: .top) { palette.line.frame(height: 1) }
            }
            if let actionMessage {
                HStack(alignment: .top, spacing: 6) {
                    Text(actionMessage).font(.system(size: 11)).foregroundStyle(actionFailed ? palette.warning : palette.secondary).lineLimit(3)
                    Spacer(minLength: 0)
                    Button { self.actionMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭操作结果")
                }.padding(12)
            }
        }.padding(memoryFocused ? EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14) : EdgeInsets()).frame(maxWidth: .infinity, maxHeight: .infinity).background(DeviceCardSurface()).foregroundStyle(palette.text)
    }
    private func memoryFilter(_ title: String, _ value: DeviceProcessFilter) -> some View {
        Button(title) { filter = value }.buttonStyle(WBButtonStyle(compact: true)).foregroundStyle(filter == value ? palette.accent : palette.secondary)
    }
    private func groupRow(_ group: DeviceProcessGroup) -> some View {
        HStack(spacing: memoryFocused ? 12 : 10) {
            Button {
                if expandedGroups.contains(group.id) { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expandedGroups.contains(group.id) || !query.isEmpty ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 10)
                    DeviceProcessIcon(path: group.application?.executablePath).frame(width: 20, height: 20)
                    if memoryFocused {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.name).lineLimit(1).truncationMode(.tail)
                            Text("\(group.processes.count) 个进程 · 已聚合").font(.system(size: 11)).foregroundStyle(palette.muted)
                        }
                    } else {
                        Text(group.name).lineLimit(1).truncationMode(.tail)
                        Text("\(group.processes.count)").font(.system(size: 10)).foregroundStyle(palette.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(group.name)，\(group.processes.count) 个进程，展开或收起")
            measurements(cpu: group.cpuPercent, memory: group.residentBytes, pid: memoryFocused ? group.processes.first(where: \.isApplicationMain).map { String($0.pid) } ?? "—" : "—")
            actionMenu(name: group.name, members: group.processes, wholeApplication: true)
        }.font(.system(size: 11, weight: .medium)).monospacedDigit().padding(.horizontal, memoryFocused ? 10 : 13).frame(height: memoryFocused ? 50 : 38)
            .background(palette.soft, in: RoundedRectangle(cornerRadius: 5))
    }
    private func processRow(_ process: DeviceProcess, child: Bool) -> some View {
        HStack(spacing: memoryFocused ? 12 : 10) {
            Button { open(process) } label: {
                HStack(spacing: 8) {
                    if child { Color.clear.frame(width: 12) }
                    DeviceProcessIcon(path: process.executablePath).frame(width: child ? 17 : 20, height: child ? 17 : 20)
                    if memoryFocused {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(process.name).lineLimit(1).truncationMode(.tail)
                            Text(child ? "所属 \(process.application?.name ?? "应用")" : process.application == nil ? "独立后台进程" : "应用").font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                        }
                    } else { Text(process.name).lineLimit(1).truncationMode(.tail) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("\(process.name) · 点击查看采样详情")
            measurements(cpu: process.cpuPercent, memory: process.residentBytes, pid: String(process.pid))
            actionMenu(name: process.name, members: [process], wholeApplication: false)
        }.font(.system(size: 11)).monospacedDigit().padding(.horizontal, memoryFocused ? 10 : 13).frame(height: memoryFocused ? 50 : 38)
            .accessibilityElement(children: .contain)
    }
    @ViewBuilder private func measurements(cpu: Double?, memory: UInt64, pid: String) -> some View {
        if memoryFocused { Text(pid).frame(width: pidWidth, alignment: .trailing).foregroundStyle(palette.muted) }
        else { Text(DeviceFormat.percent(cpu)).frame(width: 58, alignment: .trailing) }
        Text(DeviceFormat.bytes(memory)).frame(width: memoryWidth, alignment: .trailing)
        if !memoryFocused { Text(pid).frame(width: pidWidth, alignment: .trailing).foregroundStyle(palette.muted) }
    }
    @ViewBuilder private func actionMenu(name: String, members: [DeviceProcess], wholeApplication: Bool) -> some View {
        let availability = DeviceProcessActionAvailability(name: name, members: members, wholeApplication: wholeApplication, memoryFocused: memoryFocused)
        if memoryFocused {
            HStack(spacing: 4) {
                Button { if let process = members.first(where: \.isApplicationMain) ?? members.first { open(process) } } label: { Image(systemName: "info.circle") }.buttonStyle(WBIconButtonStyle()).accessibilityLabel("查看\(name)占用")
                if availability.canQuit {
                    Button("退出") { actionRequest = .init(name: name, processes: members, mode: .quit, wholeApplication: wholeApplication) }.buttonStyle(WBButtonStyle(compact: true))
                        .accessibilityIdentifier("device-process-open-quit-" + String(members.first?.pid ?? 0))
                } else if let protection = availability.protection {
                    Button("仅查看") { processProtection = protection }.buttonStyle(WBQuietButtonStyle()).help(protection.reason)
                        .accessibilityLabel("\(name) 仅供查看，了解原因")
                }
            }.frame(width: actionWidth, alignment: .trailing)
        } else {
            HStack(spacing: 4) {
                if let protection = availability.protection {
                    Button(protection.badge) { processProtection = protection }
                        .buttonStyle(WBQuietButtonStyle()).font(.system(size: 10))
                        .help(protection.reason + "\n" + protection.guidance)
                        .accessibilityLabel("\(name) \(protection.badge)，查看保护说明")
                        .accessibilityIdentifier("fc.device.process.protection.\(members.first?.pid ?? 0)")
                }
                DeviceProcessActionsMenu(name: name, wholeApplication: wholeApplication,
                    canQuit: availability.canQuit, canForce: availability.canForce, textColor: NSColor(palette.text),
                    viewDetails: { if let process = members.first(where: \.isApplicationMain) ?? members.first { open(process) } },
                    request: { mode in actionRequest = .init(name: name, processes: members, mode: mode, wholeApplication: wholeApplication) })
                    .frame(width: 28, height: 28)
            }.frame(width: actionWidth, alignment: .trailing)
        }
    }

    private var tableHeader: some View {
        HStack(spacing: memoryFocused ? 12 : 10) {
            sortButton(memoryFocused ? "应用 / 进程" : "进程名称", .name).frame(maxWidth: .infinity, alignment: .leading)
            if memoryFocused { sortButton("PID", .pid).frame(width: pidWidth, alignment: .trailing) }
            else { sortButton("CPU", .cpu).frame(width: 58, alignment: .trailing) }
            sortButton(memoryFocused ? "内存占用" : "内存", .memory).frame(width: memoryWidth, alignment: .trailing)
            if !memoryFocused { sortButton("PID", .pid).frame(width: pidWidth, alignment: .trailing) }
            if memoryFocused { Text("操作").frame(width: actionWidth, alignment: .trailing) }
            else { Color.clear.frame(width: actionWidth) }
        }.padding(.horizontal, memoryFocused ? 10 : 13).frame(height: memoryFocused ? 30 : 32)
            .font(.system(size: 11)).foregroundStyle(palette.secondary)
    }
    private func sortButton(_ title: String, _ value: DeviceProcessSort) -> some View {
        Button {
            if sort == value { ascending.toggle() }
            else { sort = value; ascending = value == .name || value == .pid }
        } label: {
            HStack(spacing: 3) {
                Text(title)

            }
        }.buttonStyle(.plain).accessibilityLabel("按\(title)排序")
            .accessibilityValue(sort == value ? (ascending ? "升序" : "降序") : "")
    }
}

/// The shared host retains a dialog value for its presentation. Keep consent
/// inside that retained child so changing it also redraws the execute button.
struct DeviceProcessActionDialog: View {
    let request: DeviceProcessActionRequest
    let memoryFocused: Bool
    let dismiss: () -> Void
    let force: () -> Void
    let perform: (DeviceProcessActionRequest) -> Void
    #if DEBUG
    var inspection: DeviceProcessDialogInspection? = nil
    #endif
    @State private var quitConsent = false
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        DeviceDialog(title: request.mode == .force ? "强制结束 \(request.name)？" : "确认退出 \(request.name)？", dismiss: dismiss) {
            VStack(alignment: .leading, spacing: 12) {
                Label(request.name, systemImage: "macwindow").font(.system(size: 16, weight: .medium))
                DeviceFact(label: "范围", value: request.wholeApplication ? "此应用及已确认的 \(request.processes.count) 个进程" : "仅所选进程")
                Text(request.mode == .force ? "强制结束不会等待应用保存内容。仅在正常退出无响应时使用；不会扩大到之后新出现的进程。" : "先请求正常退出，让应用有机会保存内容。不直接强制结束；应用提示保存时会等待你处理。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                if memoryFocused {
                    Toggle("我确认这是要处理的应用，并了解未保存工作需要先处理", isOn: $quitConsent)
                        .font(.system(size: 12)).accessibilityIdentifier("device-process-quit-consent")
                }
                Text("提交前重新核验应用身份、PID 与启动时间。系统、自身或身份无法核验的目标不会执行。").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        } actions: {
            Button("取消", action: dismiss).buttonStyle(WBButtonStyle()).keyboardShortcut(.cancelAction)
            if request.mode == .quit && !memoryFocused {
                Button("强制结束", action: force).buttonStyle(WBButtonStyle()).foregroundStyle(palette.critical)
            }
            Button(request.mode == .force ? "强制结束" : "请求正常退出") {
                guard !memoryFocused || quitConsent else { return }
                perform(request); dismiss()
            }
                .buttonStyle(WBButtonStyle(primary: request.mode == .quit)).foregroundStyle(request.mode == .force ? palette.critical : palette.primaryText)
                .disabled(memoryFocused && !quitConsent).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("device-process-quit-confirm")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("device-process-confirmation-" + request.id.uuidString)
        #if DEBUG
        .onAppear { inspection?.consent = $quitConsent; inspection?.requestID = request.id }
        .onDisappear {
            if inspection?.requestID == request.id { inspection?.consent = nil; inspection?.requestID = nil }
        }
        #endif
    }
}

#if DEBUG
/// Exposes the mounted production child's actual state, never a mirrored value.
@MainActor final class DeviceProcessDialogInspection {
    var consent: Binding<Bool>?
    var requestID: UUID?
}
#endif
