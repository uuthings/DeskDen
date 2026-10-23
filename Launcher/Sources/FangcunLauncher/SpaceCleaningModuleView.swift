import AppKit
import SwiftUI
import LauncherCore

struct SpaceCleaningModuleView: View {
    @ObservedObject var model: SpaceCleaningModel
    var onLegacyHistory: (() -> Void)? = nil
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchDeviceExpanded) private var expanded
    @Environment(\.workbenchPageScrollHeight) private var scrollViewportHeight
    @State private var availableWidth: CGFloat = 0
    @State private var expandedBatch: UUID?
    @State private var stickyFrames = SpaceCleaningStickyFrames()

    private var narrow: Bool { availableWidth > 0 && availableWidth < 760 }
    private var isHistory: Bool { model.screen == .history }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: isHistory ? "清理记录" : "空间清理",
                         subtitle: isHistory ? "每次处理都有记录，可恢复的项目随时取回" : "看清占用，再决定去留") {
                if isHistory {
                    Button(action: model.returnFromHistory) { Label("返回清理", systemImage: "arrow.left") }.buttonStyle(WBButtonStyle())
                } else {
                    Button(action: model.showHistory) { Label("清理记录", systemImage: "clock.arrow.circlepath") }
                        .buttonStyle(WBButtonStyle()).disabled(model.isBusy)
                }
            }
            if model.isReconcilingHistory {
                HStack(spacing: 8) {
                    Text("正在核对历史项目").font(.system(size: 11)).foregroundStyle(palette.muted)
                    Button("停止核对", action: model.cancelHistoryVerification).buttonStyle(WBQuietButtonStyle())
                }.padding(.bottom, 12).accessibilityIdentifier("space-cleaning-history-verification")
            }
            content
            footnote
            if let message = model.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(message).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(WBIconButtonStyle()).accessibilityLabel("关闭提示")
                }.font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 12)
                    .accessibilityIdentifier("space-cleaning-message")
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { availableWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, value in availableWidth = value }
        })
        .foregroundStyle(palette.text)
        .workbenchModal(item: $model.dialog, width: 500, onRequestDismiss: model.closeDialog) { dialog in
            SpaceCleaningDialogContent(model: model, dialog: dialog)
        }
        .onAppear { model.refreshDisk() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning")
    }

    @ViewBuilder private var content: some View {
        switch model.screen {
        case .start: startSurface
        case .scanning: scanSurface
        case .results:
            if let detail = model.detail {
                if narrow {
                    VStack(spacing: 12) { detailPanel(detail); resultsSurface }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        resultsSurface.frame(maxWidth: .infinity)
                        detailPanel(detail).frame(width: 280)
                    }
                }
            } else { resultsSurface }
        case .processing, .finished: operationSurface
        case .history: historySurface
        }
    }

    private var disk: some View {
        SpaceCleaningDiskHeader(volumeName: model.diskVolumeName ?? "", totalBytes: model.diskTotal, availableBytes: model.diskAvailable)
    }
    private var startSurface: some View {
        SpaceCleaningSurface {
            disk
            let layout = availableWidth > 0 && availableWidth < 620 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20)) : AnyLayout(HStackLayout(alignment: .center, spacing: expanded ? 70 : 30))
            layout {
                VStack(alignment: .leading, spacing: 0) {
                    Label(model.scopeChoice == .recommended ? "默认扫描这台 Mac" : "按所选范围扫描", systemImage: "viewfinder")
                        .font(.system(size: 11)).foregroundStyle(palette.accent).padding(.bottom, 16)
                    Text("看看哪些空间\n可以整理。").font(.system(size: 20, weight: .medium)).lineSpacing(6)
                    Text("从常用位置开始，找到缓存、构建和下载内容。每一项，都由你决定去留。")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(6).frame(maxWidth: 280, alignment: .leading).padding(.top, 12)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.shield")
                        Text("发布与归档材料默认保留\n扫描不会选择或删除文件").lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                        .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 23)
                }.frame(maxWidth: .infinity, alignment: .leading)
                scopeOverview.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(EdgeInsets(top: 30, leading: 14, bottom: 34, trailing: 14))
                .frame(minHeight: expanded ? 395 : 351)
            SpaceCleaningFooter {
                footerLabel(model.scopeSummary, subtitle: model.scopeChoice == .recommended ? "当前用户常用位置，无须先选择文件夹" : "仅扫描所选位置，保护规则仍然生效")
            } actions: {
                HStack(spacing: 8) {
                    Button("调整范围") { model.dialog = .scope }.buttonStyle(WBQuietButtonStyle()).disabled(model.isBusy)
                    Button(action: model.startScan) { Label("开始扫描", systemImage: "viewfinder") }.buttonStyle(WBButtonStyle(primary: true)).disabled(model.isBusy).accessibilityIdentifier("space-cleaning-start")
                }
            }
        }
    }
    private var scopeOverview: some View {
        let entries: [(String, String, String)] = {
            switch model.scopeChoice {
            case .recommended:
                [("应用缓存", "网页缓存、下载缓存与历史日志", "square.3.layers.3d"), ("开发与构建", "DerivedData、依赖缓存与测试包", "chevron.left.forwardslash.chevron.right"), ("下载与大文件", "安装包、录制与个人下载内容", "arrow.down.doc"), ("归档与保护核验", "发布原件、关联符号与更新材料", "checkmark.shield")]
            case .xcode:
                [("开发与构建", "DerivedData、依赖缓存与测试包", "chevron.left.forwardslash.chevron.right"), ("归档与保护核验", "发布原件、关联符号与更新材料", "checkmark.shield")]
            case .downloads:
                [("下载与大文件", "安装包、录制与个人下载内容", "arrow.down.doc"), ("保护核验", "发布材料与正在使用的内容", "checkmark.shield")]
            case .custom:
                [("自选目录", "只检查你明确选择的位置", "folder"), ("保护核验", "同样识别发布材料与正在使用的内容", "checkmark.shield")]
            }
        }()
        return VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 { Rectangle().fill(palette.line).frame(height: 1) }
                HStack(spacing: 12) {
                    Image(systemName: entry.2).font(.system(size: 18, weight: .light)).foregroundStyle(palette.accent).frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.0).font(.system(size: 12, weight: .medium))
                        Text(entry.1).font(.system(size: 11)).foregroundStyle(palette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 14)
            }
        }
    }

    private var scanSurface: some View {
        SpaceCleaningSurface {
            disk
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(activeLane.map { "正在检查" + $0.title } ?? "正在准备扫描")
                        .font(.system(size: 20, weight: .medium))
                    Text("查看文件用途，同时核对保留规则").font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.checkedCount.formatted()).font(.system(size: 20, weight: .medium)).monospacedDigit()
                    Text("项已检查").font(.system(size: 11)).foregroundStyle(palette.muted)
                }
            }.padding(EdgeInsets(top: 28, leading: 14, bottom: 20, trailing: 14))
            VStack(spacing: 0) {
                ForEach(model.lanes) { lane in scanLane(lane) }
            }.padding(.horizontal, 14).padding(.bottom, 22).frame(minHeight: 242, alignment: .top)
            SpaceCleaningFooter {
                footerLabel(model.scopeSummary, subtitle: "已完成 \(model.completedStageCount) / \(model.lanes.count) 类 · 不自动处理文件")
            } actions: {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        ForEach(model.lanes) { lane in
                            Capsule().fill(lane.state == .complete ? palette.accent : lane.state == .active ? palette.accent.opacity(0.5) : palette.progressTrack).frame(height: 4)
                        }
                    }.frame(width: 124).accessibilityElement(children: .ignore)
                        .accessibilityLabel("扫描类别进展").accessibilityValue("已完成 \(model.completedStageCount) 类，共 \(model.lanes.count) 类")
                    Button("停止扫描", action: model.cancelScan).buttonStyle(WBButtonStyle()).accessibilityIdentifier("space-cleaning-cancel-scan")
                }
            }
        }
    }
    private var activeLane: CleaningScanLane? { model.lanes.first { $0.state == .active } }
    private func scanLane(_ lane: CleaningScanLane) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: lane.state == .complete ? "checkmark" : lane.systemImage).frame(width: 20).foregroundStyle(palette.accent)
                Text(lane.title).foregroundStyle(lane.state == .active ? palette.text : palette.muted)
                Spacer(minLength: 10)
                Text(lane.state == .complete ? "\(lane.checkedCount.formatted()) 项 · 已检查" : lane.state == .active ? "正在查找" : "等待检查")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }.padding(.vertical, lane.state == .active ? 11 : 9).frame(minHeight: 43)
            if lane.state == .active {
                VStack(alignment: .leading, spacing: 9) {
                    if !lane.path.isEmpty { Text(lane.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).textSelection(.enabled).lineLimit(2).truncationMode(.middle) }
                    if !lane.currentFile.isEmpty {
                        SpaceCleaningFileInspection(fileName: lane.currentFile, verdict: lane.decision, active: model.animationActive)
                    }
                }.padding(.leading, 30).padding(.bottom, 12)
            }
            if lane.id != model.lanes.last?.id { Rectangle().fill(palette.line).frame(height: 1) }
        }.accessibilityElement(children: .contain)
    }

    private var resultsSurface: some View {
        SpaceCleaningSurface {
            disk
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("可重建内容，建议优先复核").font(.system(size: 12)).foregroundStyle(palette.secondary)
                    Text(SpaceCleaningFormat.bytes(total(items(in: .rebuildable))))
                        .font(.system(size: 32, weight: .medium)).monospacedDigit().accessibilityIdentifier("space-cleaning-rebuildable-bytes")
                    Text(model.reportSummary).font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(3).padding(.top, 4)
                }
                Spacer(minLength: 4)
                Button(action: model.startScan) { Label("重新扫描", systemImage: "viewfinder") }.buttonStyle(WBQuietButtonStyle()).disabled(model.isBusy).fixedSize()
            }.padding(EdgeInsets(top: 25, leading: 14, bottom: 20, trailing: 14))
            VStack(spacing: 0) {
                ForEach(CleaningResultGroup.allCases, id: \.self) { group in groupSection(group) }
            }.padding(.horizontal, 14).padding(.bottom, 18)
            // Keep the footer's document slot while moving the same controls
            // within this surface, like CSS position: sticky; bottom: 0.
            ZStack {
                resultsFooter
                    .background(palette.overlay, in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-selection-footer")
                    .offset(y: selectionFooterOffset)
            }.background(GeometryReader { geometry in
                Color.clear.preference(key: SpaceCleaningStickyFramesKey.self,
                    value: .init(footer: geometry.frame(in: .named(WorkbenchPageScrollSpace.name))))
            }).zIndex(1)
        }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: SpaceCleaningStickyFramesKey.self,
                value: .init(surface: geometry.frame(in: .named(WorkbenchPageScrollSpace.name))))
        })
        .onPreferenceChange(SpaceCleaningStickyFramesKey.self) { stickyFrames = $0 }
    }
    private var selectionFooterOffset: CGFloat {
        guard scrollViewportHeight > 0, let surface = stickyFrames.surface, let footer = stickyFrames.footer else { return 0 }
        return min(0, max(surface.minY - footer.minY, scrollViewportHeight - footer.maxY))
    }
    private var resultsFooter: some View {
            SpaceCleaningFooter {
                footerLabel(model.selectedCount == 0 ? "选择要整理的项目" : "已选 \(model.selectedCount) 项 · \(SpaceCleaningFormat.bytes(model.selectedBytes))", subtitle: model.selectedCount == 0 ? "展开分类可查看每一项的用途与影响" : "处理前会再核对文件与保护状态")
            } actions: {
                HStack(spacing: 8) {
                    Button("选择建议项", action: model.selectRecommended).buttonStyle(WBQuietButtonStyle()).disabled(model.requiresRescan || model.isBusy || items(in: .rebuildable).allSatisfy { !$0.isSelectable })
                    Button(action: model.requestConfirmation) { Label("继续", systemImage: "arrow.right") }
                        .buttonStyle(WBButtonStyle(primary: true)).disabled(!model.canProcess).accessibilityIdentifier("space-cleaning-review-continue")
                }
            }
    }
    private func groupSection(_ group: CleaningResultGroup) -> some View {
        let files = items(in: group)
        let info = groupInfo(group)
        return VStack(spacing: 0) {
            Rectangle().fill(palette.line).frame(height: 1)
            Button { model.toggleGroup(group) } label: {
                HStack(spacing: 11) {
                    Image(systemName: info.symbol).font(.system(size: 20, weight: .light)).foregroundStyle(palette.accent).frame(width: 25)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.title).font(.system(size: 12, weight: .medium))
                        Text(info.subtitle).font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(SpaceCleaningFormat.bytes(total(files))).font(.system(size: 20)).monospacedDigit().fixedSize()
                    Image(systemName: model.expandedGroup == group ? "chevron.down" : "chevron.right").font(.system(size: 12)).foregroundStyle(palette.secondary).frame(width: 16)
                }.padding(.vertical, 10).frame(minHeight: 69).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(model.expandedGroup == group ? "已展开" : "已折叠")
                .accessibilityIdentifier("space-cleaning-group-" + info.identifier)
            if model.expandedGroup == group {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(files.count) 项 · " + (group == .protected ? "可查看保留原因" : "默认不勾选"))
                        Spacer(minLength: 4)
                        if group == .rebuildable { Button("选择本组", action: model.selectRecommended).buttonStyle(WBQuietButtonStyle()).disabled(model.requiresRescan) }
                    }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.leading, 36).padding(.bottom, 8)
                    if files.isEmpty {
                        Text("这一组没有待整理项目").font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity).padding(.vertical, 22)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(files.enumerated()), id: \.element.id) { index, item in fileRow(item, striped: index.isMultiple(of: 2)) }
                        }
                    }
                }.padding(.bottom, 12)
            }
        }
    }
    private func fileRow(_ item: CleaningItemDisplay, striped: Bool) -> some View {
        HStack(spacing: 11) {
            if item.isSelectable {
                Toggle("选择 " + item.name, isOn: Binding(get: { model.selectedIDs.contains(item.id) }, set: { _ in model.toggleItem(item.id) }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(model.requiresRescan || model.isBusy).frame(width: 16)
                    .accessibilityLabel("选择 " + item.name).accessibilityIdentifier("space-cleaning-select-" + item.id.uuidString)
            } else { Image(systemName: "lock").font(.system(size: 13)).foregroundStyle(palette.muted).frame(width: 16) }
            Button { model.showDetail(item.id) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(2).truncationMode(.middle)
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text((item.sizeIsComplete ? "" : "至少 ") + SpaceCleaningFormat.bytes(item.bytes))
                .font(.system(size: 11)).foregroundStyle(palette.secondary).monospacedDigit().fixedSize()
            Button { model.showDetail(item.id) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(WBIconButtonStyle(size: 28)).accessibilityLabel("复核 " + item.name)
        }.padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 0)).frame(minHeight: 53)
            .background(model.selectedIDs.contains(item.id) ? palette.accent.opacity(0.16) : striped ? palette.soft.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
    }

    private func detailPanel(_ item: CleaningItemDisplay) -> some View {
        WBCard(spacing: 0) {
            HStack {
                Text("文件复核").font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer()
                Button(action: model.closeDetail) { Image(systemName: "xmark") }.buttonStyle(WBIconButtonStyle(size: 28)).accessibilityLabel("关闭文件复核")
            }.padding(.bottom, 16)
            Text(item.name).font(.system(size: 16, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(item.subtitle).font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 6)
            Text((item.sizeIsComplete ? "" : "至少 ") + SpaceCleaningFormat.bytes(item.bytes)).font(.system(size: 20, weight: .medium)).monospacedDigit().padding(.top, 15).padding(.bottom, 2)
            detailField("为什么显示这项", content: item.reason)
            detailField("处理后会怎样", content: item.impact)
            detailField("所在位置", content: item.url.path, monospaced: true)
            HStack(spacing: 8) {
                Button { model.preview(item.id) } label: { Label("预览", systemImage: "eye") }.buttonStyle(WBButtonStyle())
                Button { model.reveal(item.id) } label: { Image(systemName: "folder") }.buttonStyle(WBIconButtonStyle(size: 28)).help("在访达中显示").accessibilityLabel("在访达中显示")
            }.padding(.top, 24)
            if item.isSelectable {
                Button(model.selectedIDs.contains(item.id) ? "取消选择" : "加入本次整理") { model.toggleItem(item.id) }
                    .buttonStyle(WBButtonStyle(primary: true)).disabled(model.requiresRescan || model.isBusy).padding(.top, 10)
            } else if item.needsPurposeConfirmation {
                Button("确认用途") { model.requestTestPurpose(item.id) }.buttonStyle(WBButtonStyle()).padding(.top, 10)
            }
            if item.group == .protected {
                Label(item.needsPurposeConfirmation ? "确认仅用于测试后，可以手动选择；不会自动勾选。" : "保留原因可见，这项不进入建议清理集合。", systemImage: "checkmark.shield")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(4).padding(.top, 23)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-file-detail")
    }
    private func detailField(_ title: String, content: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.muted)
            Text(content).font(.system(size: monospaced ? 11 : 12, design: monospaced ? .monospaced : .default)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 18)
    }

    private var operationSurface: some View {
        SpaceCleaningSurface {
            disk
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.screen == .processing ? "doc.on.doc" : "checkmark.circle")
                    .font(.system(size: 26, weight: .light)).foregroundStyle(palette.accent).frame(width: 32).padding(.top, 3)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.screen == .processing ? "正在逐项处理" : "本次处理已结束").font(.system(size: 20, weight: .medium))
                    Text(model.screen == .processing ? "每项执行前重新核对身份、占用与保护状态。" : "每个项目的实际处理状态保存在下方记录中。")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(5)
                    Text("\(model.processingCompleted) / \(model.processingTotal) 项").font(.system(size: 32, weight: .medium)).monospacedDigit().padding(.top, 14)
                    if model.screen == .processing, !model.processingItem.isEmpty {
                        Text(model.processingItem).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2).truncationMode(.middle)
                    }
                    Text(model.currentBatch?.method == .trash ? "移入废纸篓暂不计为已释放空间。" : "实际可用空间以系统后续读数为准。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(EdgeInsets(top: 35, leading: 14, bottom: 24, trailing: 14))
            if let batch = model.currentBatch {
                LazyVStack(spacing: 0) {
                    ForEach(batch.items) { item in historyItem(item) }
                }.padding(.horizontal, 14).padding(.bottom, 22)
            }
            SpaceCleaningFooter {
                if model.screen == .processing { Text("正在处理选中的文件").font(.system(size: 11)).foregroundStyle(palette.muted) }
                else { Button("查看清理记录", action: model.showHistory).buttonStyle(WBQuietButtonStyle()) }
            } actions: {
                HStack(spacing: 8) {
                    if model.screen == .processing {
                        Button("停止后续处理", action: model.cancelProcessing).buttonStyle(WBButtonStyle()).accessibilityIdentifier("space-cleaning-stop-processing")
                    } else if let batch = model.currentBatch, batch.restorableCount > 0 || batch.purgeableCount > 0 {
                        if batch.restorableCount > 0 { Button("恢复本次项目") { model.requestRestore(batch.id) }.buttonStyle(WBButtonStyle()).disabled(model.isBusy) }
                        if batch.purgeableCount > 0 { Button("永久删除本次项目") { model.requestPurge(batch.id) }.buttonStyle(WBButtonStyle()).disabled(model.isBusy) }
                    } else {
                        Button("返回扫描结果") { model.screen = .results }.buttonStyle(WBButtonStyle(primary: true))
                    }
                }
            }
        }
    }

    private var historySurface: some View {
        SpaceCleaningSurface {
            HStack {
                Text("\(model.batches.count) 次处理记录")
                Spacer(minLength: 12)
                Text("仅记录方寸处理的项目").foregroundStyle(palette.muted)
            }.font(.system(size: 11)).padding(14)
            if model.batches.isEmpty {
                WBEmptyState(symbol: "clock.arrow.circlepath", title: "还没有清理记录", message: "完成处理后，可以在这里查看逐项结果，并恢复仍在废纸篓中的内容。")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.batches) { batch in historyBatch(batch) }
                }
            }
            Text("恢复前会核对原文件；遇到同名文件时保留现有内容。")
                .font(.system(size: 11)).foregroundStyle(palette.muted).padding(14)
            if let onLegacyHistory {
                Button("早期清理记录", action: onLegacyHistory).buttonStyle(WBQuietButtonStyle()).padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
    }
    private func historyBatch(_ batch: CleaningHistoryBatchDisplay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(palette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SpaceCleaningFormat.date(batch.date)).font(.system(size: 12, weight: .medium))
                    Text("\(batch.method == .trash ? "移到废纸篓" : "永久删除") · \(batch.items.count) 项 · \(batch.restorableCount) 项可恢复")
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(SpaceCleaningFormat.bytes(batch.bytes)).font(.system(size: 20)).monospacedDigit()
            }
            HStack(spacing: 16) {
                Button(expandedBatch == batch.id ? "收起明细" : "查看明细") { expandedBatch = expandedBatch == batch.id ? nil : batch.id }.buttonStyle(WBQuietButtonStyle())
                if batch.restorableCount > 0 { Button("恢复项目") { model.requestRestore(batch.id) }.buttonStyle(WBQuietButtonStyle()).disabled(model.isBusy) }
                if batch.purgeableCount > 0 { Button("永久删除剩余项目") { model.requestPurge(batch.id) }.buttonStyle(WBQuietButtonStyle()).disabled(model.isBusy) }
            }
            if expandedBatch == batch.id {
                LazyVStack(spacing: 0) { ForEach(batch.items) { item in historyItem(item) } }
            }
        }.padding(.horizontal, 14).padding(.bottom, 18).accessibilityElement(children: .contain)
    }
    private func historyItem(_ item: CleaningHistoryItemDisplay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2).truncationMode(.middle)
                Text(item.statusText).foregroundStyle(palette.muted)
            }.font(.system(size: 11))
            if !item.explanation.isEmpty { Text(item.explanation).font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(3) }
            HStack(spacing: 12) {
                if item.canRestore {
                    Button("恢复") { model.requestRestoreItem(item.id) }.buttonStyle(WBQuietButtonStyle()).disabled(model.isBusy)
                        .accessibilityLabel("恢复 " + item.name).accessibilityIdentifier("space-cleaning-restore-item-" + item.id.uuidString)
                }
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.resultURL ?? item.originalURL]) }
                    .buttonStyle(WBQuietButtonStyle()).accessibilityLabel("在访达中显示 " + item.name)
            }
            Rectangle().fill(palette.line).frame(height: 1).padding(.top, 4)
        }.padding(.vertical, 8).accessibilityElement(children: .contain)
    }
    private var footnote: some View {
        HStack(alignment: .top, spacing: 12) {
            if !model.coverageIssues.isEmpty {
                Button { model.dialog = .issues } label: { Label("\(model.coverageIssues.count) 处范围需要留意", systemImage: "info.circle") }
                    .buttonStyle(WBQuietButtonStyle()).accessibilityIdentifier("space-cleaning-coverage-issues")
            } else if !model.coverageNotes.isEmpty {
                Button("扫描范围") { model.dialog = .issues }.buttonStyle(WBQuietButtonStyle())
            } else { Text("扫描与处理均在本机进行").font(.system(size: 11)).foregroundStyle(palette.secondary) }
            Spacer(minLength: 4)
            Button("扫描与保护规则") { model.dialog = .rules }.buttonStyle(WBQuietButtonStyle())
        }.padding(.top, 12)
    }
    private func footerLabel(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func items(in group: CleaningResultGroup) -> [CleaningItemDisplay] { model.items.filter { $0.group == group } }
    private func total(_ items: [CleaningItemDisplay]) -> UInt64 {
        items.reduce(0) { partial, item in let result = partial.addingReportingOverflow(item.bytes); return result.overflow ? .max : result.partialValue }
    }
    private func groupInfo(_ group: CleaningResultGroup) -> (title: String, subtitle: String, symbol: String, identifier: String) {
        switch group {
        case .rebuildable: ("可重建内容", "缓存与构建内容，可以再次生成", "square.3.layers.3d", "rebuildable")
        case .review: ("需要你确认", "下载文件与测试包，逐项决定去留", "folder", "review")
        case .protected: ("已为你保留", "发布档案、用途待确认与正在使用的内容", "checkmark.shield", "protected")
        }
    }
}

/// Shared presentation pieces use the workbench's material and metrics; the
/// owning shell continues to provide the window, navigation and page scrolling.
private struct SpaceCleaningStickyFrames: Equatable {
    var surface: CGRect?
    var footer: CGRect?
}
private struct SpaceCleaningStickyFramesKey: PreferenceKey {
    static let defaultValue = SpaceCleaningStickyFrames()
    static func reduce(value: inout SpaceCleaningStickyFrames, nextValue: () -> SpaceCleaningStickyFrames) {
        let next = nextValue()
        value.surface = next.surface ?? value.surface
        value.footer = next.footer ?? value.footer
    }
}

private struct SpaceCleaningDiskHeader: View {
    let volumeName: String
    let totalBytes: UInt64?
    let availableBytes: UInt64?
    @Environment(\.workbenchPalette) private var palette

    private var validReading: Bool {
        guard let totalBytes, let availableBytes else { return false }
        return totalBytes > 0 && availableBytes <= totalBytes
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Label(volumeName.isEmpty ? "此 Mac" : "此 Mac · " + volumeName, systemImage: "internaldrive")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
                Spacer(minLength: 12)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(validReading ? SpaceCleaningFormat.bytes(availableBytes ?? 0) : "暂无读数")
                        .font(.system(size: 20, weight: .medium)).monospacedDigit()
                    if validReading { Text("可用").font(.system(size: 11)).foregroundStyle(palette.muted) }
                }
            }
            if validReading, let totalBytes, let availableBytes {
                WBProgress(value: Double(totalBytes - availableBytes) / Double(totalBytes), height: 5).padding(.top, 12)
                HStack {
                    Text("已用 \(SpaceCleaningFormat.bytes(totalBytes - availableBytes)) / \(SpaceCleaningFormat.bytes(totalBytes))")
                    Spacer(minLength: 8)
                    Text("内置存储")
                }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 7)
            } else {
                Text("读取存储容量后显示已用与可用空间").font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 12)
            }
        }.padding(EdgeInsets(top: 14, leading: 14, bottom: 0, trailing: 14))
            .accessibilityElement(children: .combine).accessibilityIdentifier("space-cleaning-disk")
    }
}

private struct SpaceCleaningSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkbenchMaterialSurface(radius: 15))
            .clipShape(RoundedRectangle(cornerRadius: 15))
    }
}

private struct SpaceCleaningFooter<Leading: View, Actions: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let actions: () -> Actions
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.line).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { leading(); Spacer(minLength: 12); actions() }
                VStack(alignment: .leading, spacing: 12) {
                    leading()
                    HStack { Spacer(minLength: 0); actions() }
                }
            }.padding(14).frame(minHeight: 66)
                .background(palette.soft.opacity(0.5))
        }
    }
}

private struct SpaceCleaningFileInspection: View {
    let fileName: String
    let verdict: String
    let active: Bool
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var applicationActive = NSApplication.shared.isActive

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc").font(.system(size: 14)).foregroundStyle(palette.accent)
                Text(fileName).lineLimit(1).truncationMode(.middle).font(.system(size: 11))
                Spacer(minLength: 0)
            }.padding(.horizontal, 11).frame(minHeight: 39)
                .background(palette.soft, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if active && applicationActive && !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1 / 30.0)) { timeline in
                            GeometryReader { geometry in
                                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.7) / 1.7
                                LinearGradient(colors: [.clear, palette.accent.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: max(30, geometry.size.width * 0.2))
                                    .offset(x: (geometry.size.width + 40) * phase - 40)
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 8)).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            if !verdict.isEmpty {
                Label(verdict, systemImage: verdict.contains("保留") ? "checkmark.shield" : "arrow.right")
                    .font(.system(size: 11)).foregroundStyle(palette.accent)
                    .frame(width: 110, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in applicationActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in applicationActive = false }
        .accessibilityElement(children: .combine)
    }
}

enum SpaceCleaningFormat {
    static func bytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute())
    }
}
