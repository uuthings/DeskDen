import SwiftUI
import Darwin
import LauncherCore

/// Live readings never continuously reshuffle the table; only the result rows scroll.
/// Sorting lives only in the column headers and rows are a single 36-point line
/// (现行规范 4.5, 9.2).
struct DeviceProcessExplorerView: View {
    let processes: [DeviceProcess]
    let systemCount: Int
    @Binding var query: String
    @Binding var sort: DeviceProcessSort
    @Binding var ascending: Bool
    let open: (DeviceProcess) -> Void
    var leave: () -> Void = {}
    @Environment(\.workbenchPalette) private var palette
    @StateObject private var presentation = DeviceProcessPresentationModel()
    private let cpuWidth: CGFloat = 58, memoryWidth: CGFloat = 65, pidWidth: CGFloat = 62, actionWidth: CGFloat = 76
    @State private var filter: DeviceProcessFilter = .all
    @State private var grouped = true
    @State private var expandedGroups = Set<String>()
    @State private var actionRequest: DeviceProcessActionRequest?
    @State private var actionMessage: String?
    @State private var actionFailed = false
    @State private var processProtection: DeviceProcessProtectionInfo?

    private var results: [DeviceProcessGroup] { presentation.snapshot.rows }
    private var displayedGrouped: Bool { presentation.snapshot.grouped }
    private var hasFilter: Bool { filter != .all || !query.isEmpty }
    private var viewportKey: String { "\(filter.rawValue)|\(query)|\(grouped)" }
    private var presentationKey: DeviceProcessPresentationKey {
        .init(processes: processes, grouped: grouped, filter: filter, query: query, sort: sort, ascending: ascending)
    }
    private var matchingCount: Int { presentation.snapshot.matchingCount }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 12) {
                filterRail.frame(width: geometry.size.width < 800 ? 145 : 166)
                resultCard.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(height: geometry.size.height)
        }
        .onChange(of: presentationKey, initial: true) { _, _ in refreshPresentation() }
        .environment(\.workbenchControlBorders, false)
        .workbenchModal(item: $actionRequest) { request in
            DeviceProcessActionDialog(request: request, memoryFocused: false,
                                      dismiss: { actionRequest = nil },
                                      force: { actionRequest = .init(name: request.name, processes: request.processes, mode: .force, wholeApplication: request.wholeApplication) },
                                      perform: perform)
        }
        .workbenchModal(isPresented: Binding(get: { processProtection != nil }, set: { if !$0 { processProtection = nil } }), width: 440) {
            WorkbenchDialogFrame(title: "进程保护说明", dismiss: { processProtection = nil }) {
                VStack(alignment: .leading, spacing: 12) {
                    Label(processProtection?.name ?? "进程", systemImage: "lock.shield").font(.system(size: 13, weight: .medium))
                    Text(processProtection?.reason ?? "进程身份暂不可核验，请重新选择。")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(processProtection?.guidance ?? "你仍可查看进程详情。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            } actions: { Spacer(); Button("知道了") { processProtection = nil }.buttonStyle(WBButtonStyle(primary: true)) }
        }
    }
    private func refreshPresentation(forceReorder: Bool = false) {
        presentation.update(processes: processes, grouped: grouped, filter: filter,
                            query: query, sort: sort, ascending: ascending, forceReorder: forceReorder)
    }
    private func applySort() { refreshPresentation(forceReorder: true) }
    private func perform(_ request: DeviceProcessActionRequest) {
        switch DeviceProcessActionService.perform(request) {
        case .success(let message): actionMessage = message; actionFailed = false
        case .failure(let error): actionMessage = error.localizedDescription; actionFailed = true
        }
    }

    private var filterRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            filterButton(.all, title: "全部进程", subtitle: "当前可访问的进程")
            filterButton(.applications, title: "应用进程", subtitle: "含所属辅助进程")
            filterButton(.highCPU, title: "CPU 较高", subtitle: grouped ? "应用合计 ≥ 5%" : "单进程 ≥ 5%")
            filterButton(.highMemory, title: "内存较高", subtitle: grouped ? "应用合计 ≥ 500 MB" : "单进程 ≥ 500 MB")
            filterButton(.background, title: "独立后台", subtitle: "未归属应用包")
            palette.line.frame(height: 1).padding(.vertical, 8)
            Text("\(grouped ? "应用合计" : "单进程") CPU ≥ 5%\n\(grouped ? "应用合计" : "单进程") ≥ 500 MB\n独立后台按单进程计算\n\n数值更新时保持顺序。\n系统进程仅供查看。")
                .font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(3).padding(.horizontal, 8).padding(.vertical, 6)
            if hasFilter { Button("清除筛选与搜索") { filter = .all; query = "" }.buttonStyle(WBQuietButtonStyle()).padding(.horizontal, 8).accessibilityIdentifier("process-filter-reset") }
        }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading).background(DeviceCardSurface())
    }
    private func filterButton(_ value: DeviceProcessFilter, title: String, subtitle: String) -> some View {
        let counts = presentation.snapshot.counts[value]
        let groupCount = counts?.groupCount ?? 0, processCount = counts?.processCount ?? 0
        return Button { filter = value } label: {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 1)
                Text(displayedGrouped ? "\(groupCount) 组" : "\(processCount) 项").font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.muted).fixedSize()
            }.padding(.horizontal, 8).frame(height: 36)
                .background(filter == value ? palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(WBSelectableButtonStyle(selected: filter == value, cornerRadius: 8, drawsSelection: false, showsBorder: false)).foregroundStyle(filter == value ? palette.text : palette.secondary)
            .accessibilityLabel("\(title)，\(displayedGrouped ? "\(groupCount) 组，包含" : "")\(processCount) 个进程，\(subtitle)")
            .accessibilityValue(filter == value ? "已选择" : "").accessibilityIdentifier("process-filter-\(value.rawValue)").help(subtitle)
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                    TextField("搜索名称或 PID", text: $query).textFieldStyle(.plain).onExitCommand { if query.isEmpty { leave() } else { query = "" } }.accessibilityIdentifier("process-search")
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(WBIconButtonStyle(size: 28)).accessibilityLabel("清除进程搜索") }
                }.font(.system(size: 12)).padding(.horizontal, 10).frame(minWidth: 120, maxWidth: .infinity).frame(height: 32).background(WorkbenchMaterialSurface(kind: .control, radius: 8))
                groupingControl
            }.padding(12).overlay(alignment: .bottom) { palette.line.frame(height: 1) }
            tableHeader
            ScrollViewReader { reader in
                WorkbenchScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("process-list-top")
                        ForEach(results) { group in
                            if displayedGrouped && group.application != nil {
                                groupRow(group)
                                if expandedGroups.contains(group.id) || !query.isEmpty { ForEach(group.processes, id: \.identity) { process in processRow(process, child: true) } }
                            } else if let process = group.processes.first { processRow(process, child: false) }
                        }
                        if results.isEmpty {
                            VStack(spacing: 9) {
                                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .light)).foregroundStyle(palette.muted)
                                Text("没有匹配的应用或进程").font(.system(size: 13, weight: .medium))
                                Text(hasFilter ? "更换筛选条件，或搜索其他名称与 PID。" : "当前尚未读到可访问的进程。").font(.system(size: 11)).foregroundStyle(palette.muted)
                                if hasFilter { Button("显示全部进程") { filter = .all; query = "" }.buttonStyle(WBButtonStyle(compact: true)) }
                            }.padding(.vertical, 28).frame(maxWidth: .infinity)
                        }
                    }
                }.scrollIndicators(.visible).accessibilityIdentifier("process-results-scroll")
                    .onChange(of: viewportKey) { _, _ in reader.scrollTo("process-list-top", anchor: .top) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 6) {
                Text(displayedGrouped ? "\(results.count) 组 · 含 \(matchingCount) 个进程" : "\(matchingCount) 个进程").monospacedDigit().help("已读取 \(processes.count) / \(max(systemCount, processes.count)) 项；未读取 \(max(0, systemCount - processes.count)) 项")
                Spacer(minLength: 0); Button("重新排序", action: applySort).buttonStyle(WBQuietButtonStyle())
            }.font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.horizontal, 13).frame(height: 34).overlay(alignment: .top) { palette.line.frame(height: 1) }
            if let actionMessage {
                HStack(alignment: .top, spacing: 6) {
                    Text(actionMessage).font(.system(size: 11)).foregroundStyle(actionFailed ? palette.warning : palette.secondary).lineLimit(3)
                    Spacer(minLength: 0)
                    Button { self.actionMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(WBIconButtonStyle(size: 28)).accessibilityLabel("关闭操作结果")
                }.padding(12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(DeviceCardSurface()).foregroundStyle(palette.text)
    }
    /// The shared two-option choice from round 1 (现行规范 4.4).
    private var groupingControl: some View {
        HStack(spacing: 2) {
            groupingOption("按应用", value: true)
            groupingOption("按进程", value: false)
        }.padding(2).frame(width: 136, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.control))
            .accessibilityElement(children: .contain).accessibilityLabel("进程显示方式")
    }
    private func groupingOption(_ title: String, value: Bool) -> some View {
        let selected = grouped == value
        return Button { grouped = value } label: {
            Text(title).font(.system(size: 12, weight: selected ? .medium : .regular)).lineLimit(1)
                .foregroundStyle(selected ? palette.text : palette.secondary)
                .frame(maxWidth: .infinity).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? (palette.light ? palette.raised : palette.secondary.opacity(0.16)) : .clear)
                    .shadow(color: selected && palette.light ? palette.shadow : .clear, radius: 1, y: 1))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(WBSegmentOptionStyle(selected: selected))
            .accessibilityIdentifier(value ? "process-mode-applications" : "process-mode-processes")
            .accessibilityLabel(title).accessibilityValue(selected ? "已选择" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(value ? "按真实应用归属聚合；点击应用名称展开其进程" : "每个进程单独一行，不按应用分组")
    }
    // Applications are list titles (13 medium); processes are body text (12).
    private func groupRow(_ group: DeviceProcessGroup) -> some View {
        DeviceProcessRow {
            HStack(spacing: 10) {
                Button {
                    if expandedGroups.contains(group.id) { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expandedGroups.contains(group.id) || !query.isEmpty ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 10)
                        DeviceProcessIcon(path: group.application?.executablePath).frame(width: 20, height: 20)
                        Text(group.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail).help(group.name)
                        Text("\(group.processes.count)").font(.system(size: 10)).foregroundStyle(palette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(ClickablePlainButtonStyle()).accessibilityLabel("\(group.name)，\(group.processes.count) 个进程，展开或收起")
                measurements(cpu: group.cpuPercent, memory: group.residentBytes, pid: "—")
                actionMenu(name: group.name, members: group.processes, wholeApplication: true)
            }.font(.system(size: 12)).monospacedDigit().padding(.horizontal, 13).frame(height: 36)
        }
    }
    private func processRow(_ process: DeviceProcess, child: Bool) -> some View {
        DeviceProcessRow {
            HStack(spacing: 10) {
                Button { open(process) } label: {
                    HStack(spacing: 8) {
                        if child { Color.clear.frame(width: 12) }
                        DeviceProcessIcon(path: process.executablePath).frame(width: child ? 17 : 20, height: child ? 17 : 20)
                        Text(process.displayName).lineLimit(1).truncationMode(.tail)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(ClickablePlainButtonStyle()).help("\(process.displayName) · 点击查看采样详情")
                measurements(cpu: process.cpuPercent, memory: process.residentBytes, pid: String(process.pid))
                actionMenu(name: process.displayName, members: [process], wholeApplication: false)
            }.font(.system(size: 12)).monospacedDigit().padding(.horizontal, 13).frame(height: 36)
                .accessibilityElement(children: .contain)
        }
    }
    @ViewBuilder private func measurements(cpu: Double?, memory: UInt64, pid: String) -> some View {
        Text(DeviceFormat.percent(cpu)).frame(width: cpuWidth, alignment: .trailing)
        Text(DeviceFormat.bytes(memory)).frame(width: memoryWidth, alignment: .trailing)
        Text(pid).frame(width: pidWidth, alignment: .trailing).foregroundStyle(palette.muted)
    }
    @ViewBuilder private func actionMenu(name: String, members: [DeviceProcess], wholeApplication: Bool) -> some View {
        let availability = DeviceProcessActionAvailability(name: name, members: members, wholeApplication: wholeApplication, memoryFocused: false)
        HStack(spacing: 4) {
            if let protection = availability.protection {
                Button(protection.badge) { processProtection = protection }
                    .buttonStyle(WBQuietButtonStyle())
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

    private var tableHeader: some View {
        HStack(spacing: 10) {
            sortButton("进程名称", .name).frame(maxWidth: .infinity, alignment: .leading)
            sortButton("CPU", .cpu).frame(width: cpuWidth, alignment: .trailing)
            sortButton("内存", .memory).frame(width: memoryWidth, alignment: .trailing)
            sortButton("PID", .pid).frame(width: pidWidth, alignment: .trailing)
            Color.clear.frame(width: actionWidth)
        }.padding(.horizontal, 13).frame(height: 32)
            .font(.system(size: 11)).foregroundStyle(palette.secondary)
            .overlay(alignment: .bottom) { palette.line.frame(height: 1) }
    }
    private func sortButton(_ title: String, _ value: DeviceProcessSort) -> some View {
        Button {
            if sort == value { ascending.toggle() }
            else { sort = value; ascending = value == .name || value == .pid }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sort == value { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .medium)) }
            }
        }.buttonStyle(WBTextActionButtonStyle()).accessibilityLabel("按\(title)排序")
            .accessibilityValue(sort == value ? (ascending ? "升序" : "降序") : "")
    }
}

/// A whole-row hover wash and a separator; the row's own controls keep their roles.
private struct DeviceProcessRow<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.workbenchPalette) private var palette
    @State private var hovering = false
    var body: some View {
        content.background(hovering ? palette.soft : Color.clear)
            .overlay(alignment: .bottom) { palette.line.frame(height: 1) }
            .onHover { hovering = $0 }
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
                Label(request.name, systemImage: "macwindow").font(.system(size: 13, weight: .medium))
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
