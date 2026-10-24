import AppKit
import SwiftUI
import LauncherCore

struct SpaceCleaningModuleView: View {
    @ObservedObject var model: SpaceCleaningModel
    var onLegacyHistory: (() -> Void)? = nil
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                header
                if model.isReconcilingHistory && model.screen != .history {
                    HStack(spacing: 8) {
                        Text("正在核对历史项目").font(.system(size: 11)).foregroundStyle(palette.muted)
                        Button("停止核对", action: model.cancelHistoryVerification).buttonStyle(WBQuietButtonStyle())
                    }.padding(.bottom, 12)
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 8) {
                    Text(model.scopeSummary).lineLimit(1).truncationMode(.middle)
                    if model.screen == .results { Text(model.requiresRescan ? "· 需重新扫描" : "· 已检查") }
                    Spacer(minLength: 4)
                    Button("覆盖范围与保留规则") { model.dialog = .rules }.buttonStyle(ClickablePlainButtonStyle())
                        .disabled(model.isBusy).accessibilityIdentifier("space-cleaning-rules-link")
                }.font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 16)
                if let message = model.message {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(message).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.message = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(ClickablePlainButtonStyle()).accessibilityLabel("关闭提示")
                    }.font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 10)
                        .accessibilityIdentifier("space-cleaning-message")
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }.foregroundStyle(palette.text)
            .onAppear { model.refreshDisk() }
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning")
    }
    private var subtitle: String {
        guard let total = model.diskTotal, let available = model.diskAvailable else { return "正在读取存储信息" }
        return "\(model.diskVolumeName ?? "此 Mac") · \(SpaceCleaningFormat.bytes(available)) 可用 / \(SpaceCleaningFormat.bytes(total))"
    }
    private var header: some View {
        WBPageHeader(title: model.screen == .history ? "清理记录" : "空间清理", subtitle: subtitle) {
            if model.screen == .scope {
                Button("返回", action: model.cancelScope).buttonStyle(WBButtonStyle())
            } else if model.dialog.map({ !isPurpose($0) }) == true {
                Button("返回", action: model.closeDialog).buttonStyle(WBButtonStyle()).disabled(model.isBusy)
            } else if model.screen == .history {
                Button(action: model.returnFromHistory) { Label("返回清理", systemImage: "arrow.left") }.buttonStyle(WBButtonStyle()).disabled(model.isBusy)
            } else {
                if model.screen == .results {
                    Button("首页", action: model.goHome).buttonStyle(WBButtonStyle()).disabled(model.isBusy)
                    Button("更改范围") { model.editScope() }.buttonStyle(WBButtonStyle()).disabled(model.isBusy)
                        .accessibilityIdentifier("space-cleaning-edit-scope")
                    Button(action: model.startScan) { Label("重新扫描", systemImage: "arrow.clockwise") }
                        .buttonStyle(WBButtonStyle()).disabled(model.isBusy).accessibilityIdentifier("space-cleaning-rescan")
                }
                Button(action: model.showHistory) { Label("清理记录", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(WBButtonStyle()).disabled(model.isBusy)
            }
        }
    }
    @ViewBuilder private var content: some View {
        if let dialog = model.dialog, dialog != .confirm, !isPurpose(dialog) {
            SpaceCleaningSurface {
                ScrollView {
                    SpaceCleaningDialogContent(model: model, dialog: dialog)
                        .background(WorkbenchOverlayScrollbars())
                }.scrollBounceBehavior(.basedOnSize)
                Spacer(minLength: 0)
            }
        } else {
            switch model.screen {
            case .start: home
            case .scope: SpaceCleaningScopeView(model: model)
            case .scanning: scanning
            case .results: SpaceCleaningResultsView(model: model)
            case .processing: processing
            case .history: SpaceCleaningHistoryView(model: model, onLegacyHistory: onLegacyHistory)
            }
        }
    }
    private func isPurpose(_ dialog: CleaningDialog) -> Bool { if case .purpose = dialog { true } else { false } }
    private var home: some View {
        GeometryReader { geometry in
            SpaceCleaningSurface(fillHeight: false) {
                if let batch = model.currentBatch {
                    HStack(spacing: 12) {
                        Image(systemName: batch.attentionCount > 0 ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(batch.attentionCount > 0 ? palette.warning : palette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(batch.attentionCount > 0 ? "本次处理已结束 · \(batch.attentionCount) 项需要核对" : "本次处理已结束 · \(batch.items.count) 项")
                                .font(.system(size: 12, weight: .medium))
                            Text(batch.restorableCount > 0 ? "\(batch.restorableCount) 项可恢复 · 移入废纸篓的占用尚未释放" : "实际处理状态已保存至清理记录")
                                .font(.system(size: 11)).foregroundStyle(palette.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if batch.restorableCount > 0 { Button("恢复本次") { model.requestRestore(batch.id) }.buttonStyle(WBQuietButtonStyle()) }
                        Button("查看记录", action: model.showHistory).buttonStyle(WBButtonStyle())
                    }.padding(14).background(palette.soft).accessibilityIdentifier("space-cleaning-completion-receipt")
                }
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("看清空间，自在整理").font(.system(size: 11)).foregroundStyle(palette.muted)
                        Text("让需要的留下。\n给空间留一点余地。")
                            .font(.system(size: geometry.size.width < 700 ? 24 : 29, weight: .medium)).lineSpacing(6)
                            .fixedSize(horizontal: true, vertical: false)
                        Text("先扫描，再决定。\n可重建缓存会为你选好，其余文件由你选择。")
                            .font(.system(size: 12)).foregroundStyle(palette.muted).lineSpacing(6)
                        if !model.items.isEmpty && !model.requiresRescan {
                            Button("返回上次扫描结果") { model.screen = .results }.buttonStyle(WBQuietButtonStyle())
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    SpaceCleaningAperture(active: model.animationActive)
                        .frame(width: geometry.size.width * 0.43)
                }.padding(.horizontal, 28)
                    .frame(height: min(280, max(195, geometry.size.height - (model.currentBatch == nil ? 110 : 182))))
                Rectangle().fill(palette.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Text("扫描范围").font(.system(size: 12, weight: .medium))
                        HStack(spacing: 2) {
                            scopeButton("全局扫描", icon: "globe", selected: model.scopeChoice == .global) { model.selectScope(.global) }
                            scopeButton("自定义位置", icon: "folder", selected: model.scopeChoice == .custom) { model.editScope(custom: true) }
                        }.padding(2).background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line))
                        Spacer(minLength: 0)
                        Button(action: model.startScan) {
                            Label("开始扫描", systemImage: "viewfinder")
                        }.buttonStyle(WBButtonStyle(primary: true)).disabled(model.isBusy)
                            .accessibilityIdentifier("space-cleaning-start")
                    }
                    HStack(spacing: 10) {
                        Text(model.scopeChoice == .global ? "一次检查当前用户的缓存、开发与个人常用位置" : model.customDirectories.map { model.shortPath($0) }.joined(separator: " · "))
                            .lineLimit(1).truncationMode(.middle)
                        if model.scopeChoice == .custom {
                            Button("编辑 \(model.customDirectories.count) 个位置") { model.editScope(custom: true) }
                                .buttonStyle(ClickablePlainButtonStyle()).foregroundStyle(palette.accent).fixedSize()
                        }
                        Spacer(minLength: 0)
                        Text("扫描不会删除文件").fixedSize()
                    }.font(.system(size: 11)).foregroundStyle(palette.muted)
                }.padding(14)
            }.frame(maxHeight: .infinity, alignment: .top)
        }
    }
    private func scopeButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.system(size: 12)).padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? palette.accent.opacity(0.18) : .clear)) }
            .buttonStyle(ClickablePlainButtonStyle()).disabled(model.isBusy).accessibilityValue(selected ? "已选择" : "未选择")
    }
    private var scanning: some View {
        SpaceCleaningSurface {
            SpaceCleaningAperture(active: model.animationActive, scanning: true).frame(maxWidth: 680, maxHeight: .infinity).frame(maxWidth: .infinity).padding(.horizontal, 26)
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.scanPhase == .discovering ? "正在查找可检查项目" : "正在检查文件").font(.system(size: 20, weight: .medium))
                        Text(model.scanTotalItems.map { "已核验 \(model.scanCompletedItems) / \($0) 项" } ?? "已查看 \(model.checkedCount.formatted()) 个目录与文件")
                            .font(.system(size: 11)).foregroundStyle(palette.muted).monospacedDigit()
                    }
                    Spacer()
                    if let fraction = model.scanFraction {
                        VStack(alignment: .trailing, spacing: 4) {
                            (Text("\(Int(fraction * 100))").font(.system(size: 29)) + Text(" %").font(.system(size: 11))).monospacedDigit()
                            Text("项目核验进度").font(.system(size: 11)).foregroundStyle(palette.muted)
                        }
                    } else { Text("正在发现").font(.system(size: 12)).foregroundStyle(palette.muted) }
                }
                SpaceCleaningProgressTrack(fraction: model.scanFraction, active: model.animationActive)
                VStack(alignment: .leading, spacing: 10) {
                    scanLine("当前目录", value: model.scanDirectory.isEmpty ? "正在读取扫描范围" : model.scanDirectory, mono: true)
                    scanLine("当前项目", value: model.scanItem.isEmpty ? "等待目录返回" : model.scanItem, mono: false)
                }
                HStack {
                    Label(model.scopeChoice == .global ? "全局扫描" : "自定义位置", systemImage: "globe").font(.system(size: 11)).foregroundStyle(palette.muted)
                    Spacer()
                    Button("停止扫描", action: model.cancelScan).buttonStyle(WBButtonStyle()).accessibilityIdentifier("space-cleaning-cancel-scan")
                }.padding(.top, 4)
            }.frame(maxWidth: 660).padding(.horizontal, 30).padding(.bottom, 28).frame(maxWidth: .infinity)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-scan")
    }
    private func scanLine(_ title: String, value: String, mono: Bool) -> some View {
        HStack(spacing: 16) {
            Text(title).foregroundStyle(palette.muted).frame(width: 50, alignment: .leading)
            Text(value).font(.system(size: 11, design: mono ? .monospaced : .default)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11)).frame(height: 16)
    }
    private var processing: some View {
        SpaceCleaningSurface {
            VStack(alignment: .leading, spacing: 24) {
                Spacer(minLength: 0)
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 34, weight: .light)).foregroundStyle(palette.accent)
                Text("正在安全处理所选项目").font(.system(size: 24, weight: .medium))
                Text(model.processingItem).font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                SpaceCleaningProgressTrack(fraction: model.processingTotal > 0 ? Double(model.processingCompleted) / Double(model.processingTotal) : nil, active: model.windowVisible && !model.reduceMotion)
                HStack {
                    Text("已处理 \(model.processingCompleted) / \(model.processingTotal) 项").font(.system(size: 12)).monospacedDigit()
                    Spacer()
                    Button("停止后续处理", action: model.cancelProcessing).buttonStyle(WBButtonStyle())
                }
                Text("每项操作前重新核对文件与保护状态，完成后返回清理首页或记录。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer(minLength: 0)
            }.frame(maxWidth: 580).padding(30).frame(maxWidth: .infinity)
        }
    }
}

struct SpaceCleaningSurface<Content: View>: View {
    var fillHeight = true
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(WorkbenchMaterialSurface(radius: 15)).clipShape(RoundedRectangle(cornerRadius: 15))
    }
}
struct SpaceCleaningProgressTrack: View {
    let fraction: Double?
    let active: Bool
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var applicationActive = NSApplication.shared.isActive
    private var running: Bool { active && applicationActive && !systemReduceMotion }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: fraction != nil || !running)) { timeline in
            GeometryReader { geo in
                let position = running ? (sin(timeline.date.timeIntervalSinceReferenceDate * 1.4) + 1) / 2 : 0.35
                Capsule().fill(palette.progressTrack)
                Capsule().fill(LinearGradient(colors: [palette.accent.opacity(0.4), palette.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * (fraction ?? 0.18))
                    .offset(x: fraction == nil ? geo.size.width * 0.82 * position : 0)
            }
        }.frame(height: 3)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in applicationActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in applicationActive = false }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("扫描进度").accessibilityValue(fraction.map { "\(Int($0 * 100))%" } ?? "正在发现项目，总量未知")
    }
}
enum SpaceCleaningFormat {
    static func bytes(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file) }
    static func date(_ date: Date) -> String { date.formatted(.dateTime.year().month().day().hour().minute()) }
}
