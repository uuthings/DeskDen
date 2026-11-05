import SwiftUI
import LauncherCore

/// Progress is presented from the scanner's existing, throttled events. A
/// discovered scope has no known total, so only verification shows a percent.
struct SpaceCleaningScanView: View {
    @ObservedObject var model: SpaceCleaningModel
    let width: CGFloat
    let height: CGFloat
    @Environment(\.workbenchPalette) private var palette

    private var phaseIndex: Int {
        switch model.scanPhase {
        case .discovering: 0
        case .verifying: 1
        case .finished: 2
        }
    }
    private var fraction: Double? {
        model.scanPhase == .discovering ? nil : model.scanFraction
    }
    private var title: String {
        switch model.scanPhase {
        case .discovering: "正在发现项目"
        case .verifying: "正在核验文件"
        case .finished: "正在整理结果"
        }
    }
    private var scopeProgress: String {
        guard model.scanTotalScopes > 0 else { return "正在确认范围" }
        return "\(model.scanCompletedScopes) / \(model.scanTotalScopes)"
    }

    var body: some View {
        SpaceCleaningSurface {
            phases
            Rectangle().fill(palette.line).frame(height: 1)
            WorkbenchScrollView {
                if width >= 760 {
                    HStack(alignment: .top, spacing: 0) {
                        status.frame(width: max(240, (width - 12) / 3))
                            .frame(minHeight: max(410, height - 142), alignment: .top)
                        activity.frame(maxWidth: .infinity, minHeight: max(410, height - 142), alignment: .topLeading)
                            .overlay(alignment: .leading) { Rectangle().fill(palette.line).frame(width: 1) }
                    }.frame(minHeight: max(410, height - 142), alignment: .top)
                } else {
                    VStack(spacing: 0) {
                        status
                        Rectangle().fill(palette.line).frame(height: 1).padding(.horizontal, 14)
                        activity
                    }
                }
            }.scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("space-cleaning-scan-scroll")
            Rectangle().fill(palette.line).frame(height: 1).padding(.horizontal, 14)
            scanActions
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-scan")
    }

    private var phases: some View {
        HStack(spacing: 12) {
            phase(0, title: "发现项目", subtitle: "读取扫描范围")
            phase(1, title: "核验文件", subtitle: "检查用途与保护")
            phase(2, title: "整理结果", subtitle: "汇总可复核内容")
        }.padding(14).accessibilityElement(children: .contain)
            .accessibilityIdentifier("space-cleaning-scan-phases")
    }
    private func phase(_ index: Int, title: String, subtitle: String) -> some View {
        let selected = index == phaseIndex
        let finished = index < phaseIndex
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(selected || finished ? palette.accent.opacity(0.13) : palette.soft)
                if finished {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .medium))
                } else {
                    Text(String(index + 1)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
            }.foregroundStyle(selected || finished ? palette.accent : palette.muted).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? palette.text : palette.secondary)
                Text(finished ? "已完成" : selected ? "进行中" : subtitle)
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
            .accessibilityIdentifier("space-cleaning-scan-phase-\(index)")
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text((model.scanMode == .largeFiles ? "大文件扫描" : "常规扫描") + " · " + (model.scopeChoice == .global ? "全局范围" : "自选目录"))
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            progressRing.frame(maxWidth: .infinity).padding(.vertical, 4)
            VStack(spacing: 12) {
                fact("已检查项目", value: model.checkedCount.formatted(), id: "checked")
                fact("已记录候选", value: model.scanRecordedCandidates.formatted(), id: "candidates")
                fact("候选文件大小", value: SpaceCleaningFormat.bytes(model.scanLogicalBytes), id: "bytes")
                fact("已完成范围", value: scopeProgress, id: "scopes")
            }
            Text("统计随扫描更新，文件用途、实际占用与保护状态以核验后的结果为准。")
                .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-scan-status")
    }

    private var progressRing: some View {
        ZStack {
            Circle().stroke(palette.progressTrack, lineWidth: 7)
            if let fraction {
                Circle().trim(from: 0, to: CGFloat(fraction))
                    .stroke(palette.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle().stroke(palette.accent.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 9]))
            }
            VStack(spacing: 7) {
                if let fraction {
                    Text(UsagePercentage.text(fraction * 100)).font(.system(size: 30, weight: .regular)).monospacedDigit()
                    Text("项目核验进度").font(.system(size: 11)).foregroundStyle(palette.muted)
                } else {
                    Image(systemName: "viewfinder").font(.system(size: 28, weight: .light)).foregroundStyle(palette.accent)
                    Text(model.scanPhase == .finished ? "汇总中" : "发现中").font(.system(size: 15, weight: .medium))
                    Text(model.scanPhase == .finished ? "正在归类结果" : "总量尚未确定")
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                }
            }
        }.padding(8).frame(width: 174, height: 174)
            .accessibilityElement(children: .ignore).accessibilityLabel("扫描进度")
            .accessibilityValue(fraction.map { UsagePercentage.text($0 * 100) + "，项目核验进度" } ?? (model.scanPhase == .finished ? "正在整理结果" : "正在发现项目，总量尚未确定"))
            .accessibilityIdentifier("space-cleaning-scan-progress")
    }
    private func fact(_ title: String, value: String, id: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }.accessibilityElement(children: .combine).accessibilityIdentifier("space-cleaning-scan-" + id)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 16) {
            currentPath
            HStack {
                Text("最近检查的路径").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Text("实时采样").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            VStack(spacing: 0) {
                if model.scanRecentPaths.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder.badge.magnifyingglass").font(.system(size: 28, weight: .light))
                        Text("正在读取扫描范围")
                        Text("开始检查后，这里显示最近读取的位置").font(.system(size: 11))
                    }.font(.system(size: 12)).foregroundStyle(palette.muted)
                        .frame(maxWidth: .infinity, minHeight: 216)
                } else {
                    ForEach(Array(model.scanRecentPaths.enumerated()), id: \.element) { index, path in
                        if index > 0 { Rectangle().fill(palette.line).frame(height: 1) }
                        recentPath(path, index: index)
                    }
                }
            }.frame(maxWidth: .infinity, minHeight: 216, alignment: .topLeading)
                .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-scan-recent-paths")
            VStack(alignment: .leading, spacing: 7) {
                Text(model.scopeSummary).font(.system(size: 11)).foregroundStyle(palette.secondary)
                Text("这里仅展示最近的采样位置；完整项目、覆盖情况与保留规则将在扫描结束后显示。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-scan-activity")
    }

    private var currentPath: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.magnifyingglass").font(.system(size: 17)).foregroundStyle(palette.accent)
                Text(model.scanPhase == .discovering ? "正在检查" : "正在核验").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                if model.scanPhase != .discovering, let total = model.scanTotalItems {
                    Text("\(model.scanCompletedItems.formatted()) / \(total.formatted()) 项")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.muted)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(model.scanDirectory.isEmpty ? "正在确认可访问的目录…" : model.scanDirectory)
                    .font(.system(size: 11, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                    .foregroundStyle(palette.secondary).help(model.scanDirectory)
                Text(model.scanItem.isEmpty ? "等待目录返回" : model.scanItem)
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.middle).foregroundStyle(palette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            SpaceCleaningProgressTrack(fraction: fraction, active: model.animationActive)
        }.padding(14).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.soft))
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-scan-directory")
    }
    private func recentPath(_ path: String, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 18)).foregroundStyle(index == 0 ? palette.accent : palette.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12))
                    .lineLimit(1).truncationMode(.middle)
                Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted)
                    .lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 52).help(path)
            .accessibilityElement(children: .combine).accessibilityIdentifier("space-cleaning-scan-recent-\(index)")
    }

    private var scanActions: some View {
        HStack(spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("扫描不会移动或删除文件").foregroundStyle(palette.secondary)
                    Text("停止后可查看部分结果，处理前需要重新扫描").foregroundStyle(palette.muted)
                }
            } icon: { Image(systemName: "checkmark.shield").foregroundStyle(palette.accent) }
                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("停止扫描", action: model.cancelScan).buttonStyle(WBButtonStyle())
                .accessibilityIdentifier("space-cleaning-cancel-scan")
        }.padding(14).accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-scan-actions")
    }
}
