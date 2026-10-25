import AppKit
import SwiftUI
import LauncherCore

struct SpaceCleaningHistoryView: View {
    @ObservedObject var model: SpaceCleaningModel
    var onLegacyHistory: (() -> Void)?
    @Environment(\.workbenchPalette) private var palette
    @State private var expandedBatch: UUID?
    var body: some View {
        SpaceCleaningSurface {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("每次整理，都有来处").font(.system(size: 20, weight: .medium))
                    Text("移入废纸篓的文件可恢复；永久删除保留操作记录。")
                        .font(.system(size: 12)).foregroundStyle(palette.muted)
                }
                Spacer()
                if model.isReconcilingHistory {
                    Button("停止核对", action: model.cancelHistoryVerification).buttonStyle(WBButtonStyle())
                }
                if let onLegacyHistory { Button("早期处理记录", action: onLegacyHistory).buttonStyle(WBQuietButtonStyle()) }
            }.padding(24)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.batches.isEmpty {
                        Text("还没有清理记录").font(.system(size: 14)).foregroundStyle(palette.muted).frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                    ForEach(model.batches) { batch in batchRow(batch) }
                }.padding(.horizontal, 24).background(WorkbenchOverlayScrollbars())
            }.scrollBounceBehavior(.basedOnSize)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-history")
    }
    private func batchRow(_ batch: CleaningHistoryBatchDisplay) -> some View {
        let expanded = expandedBatch == batch.id
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(palette.line).frame(height: 1)
            HStack(alignment: .center, spacing: 14) {
                Button { expandedBatch = expanded ? nil : batch.id } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(expanded ? palette.accent : palette.secondary)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
                        VStack(alignment: .leading, spacing: 7) {
                            Text(SpaceCleaningFormat.date(batch.date)).font(.system(size: 12, weight: .medium))
                            Text("\(batch.items.count) 项 · \(batch.method == .trash ? "移入废纸篓" : "永久删除") · \(batch.restorableCount) 项可恢复")
                                .font(.system(size: 11)).foregroundStyle(palette.muted)
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(ClickablePlainButtonStyle())
                    .accessibilityLabel((expanded ? "收起" : "展开") + "清理记录 " + SpaceCleaningFormat.date(batch.date))
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                    .accessibilityIdentifier("space-cleaning-history-expand-" + batch.id.uuidString)
                Text(SpaceCleaningFormat.bytes(batch.bytes)).font(.system(size: 15)).monospacedDigit().fixedSize()
                if batch.restorableCount > 0 {
                    Button("恢复本次") { model.requestRestore(batch.id) }.buttonStyle(WBButtonStyle()).disabled(model.isBusy)
                        .accessibilityIdentifier("space-cleaning-history-restore-" + batch.id.uuidString)
                }
            }.padding(.vertical, 10)
            if expanded {
                VStack(spacing: 8) {
                    ForEach(batch.items) { item in historyItem(item) }
                }.padding(.leading, 44).padding(.bottom, 14)
                if batch.purgeableCount > 0 {
                    HStack(spacing: 12) {
                        Text("仅处理本批仍在废纸篓且核验一致的项目")
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                        Spacer(minLength: 8)
                        Button { model.requestPurge(batch.id) } label: {
                            Label("永久删除本批 \(batch.purgeableCount) 项", systemImage: "trash.slash")
                        }.buttonStyle(WBButtonStyle(destructive: true)).disabled(model.isBusy)
                            .accessibilityIdentifier("space-cleaning-history-purge-" + batch.id.uuidString)
                    }.padding(.leading, 44).padding(.bottom, 18)
                }
            }
        }
    }
    private func historyItem(_ item: CleaningHistoryItemDisplay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Label(item.name, systemImage: "doc").font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .center, spacing: 10) {
                    Text(item.statusText).font(.system(size: 11)).foregroundStyle(palette.secondary)
                        .lineLimit(1).fixedSize().frame(minHeight: 28)
                        .accessibilityIdentifier("space-cleaning-history-status-" + item.id.uuidString)
                    if item.canRestore {
                        Button("恢复") { model.requestRestoreItem(item.id) }.buttonStyle(WBButtonStyle(compact: true)).disabled(model.isBusy)
                            .accessibilityIdentifier("space-cleaning-history-restore-item-" + item.id.uuidString)
                    }
                    if let result = item.resultURL {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([result]) } label: { Image(systemName: "folder") }
                            .buttonStyle(WBIconButtonStyle(size: 28)).accessibilityLabel("在 Finder 中查看 " + item.name)
                            .accessibilityIdentifier("space-cleaning-history-reveal-" + item.id.uuidString)
                    }
                }.fixedSize()
            }.frame(minHeight: 32)
            Text(item.explanation).font(.system(size: 11)).foregroundStyle(palette.muted).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text((item.resultURL ?? item.originalURL).path).font(.system(size: 10)).foregroundStyle(palette.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-history-item-" + item.id.uuidString)
    }
}

struct SpaceCleaningCompletionView: View {
    @ObservedObject var model: SpaceCleaningModel
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        SpaceCleaningSurface(fillHeight: false) {
            if let batch = model.currentBatch {
                completion(batch)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Text("本次处理已结束").font(.system(size: 24, weight: .medium))
                    Text("尚无已确认的成功处理记录；本次原计划 \(model.processingTotal) 项，已核对 \(model.processingCompleted) 项。")
                        .font(.system(size: 12)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                    Text("可在清理记录中查看逐项状态；未确认的结果不计为清理成功。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("查看清理记录", action: model.showHistory).buttonStyle(WBButtonStyle())
                            .accessibilityIdentifier("space-cleaning-completed-history")
                        Button("返回首页", action: model.goHome).buttonStyle(WBButtonStyle(primary: true))
                            .accessibilityIdentifier("space-cleaning-completed-home")
                    }
                }.padding(28).frame(maxWidth: .infinity, minHeight: 280, alignment: .leading)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-completed")
    }
    private func completion(_ batch: CleaningHistoryBatchDisplay) -> some View {
        let succeeded = batch.items.filter { [.trashed, .deleted].contains($0.state) }
        let unprocessed = max(0, model.processingTotal - model.processingCompleted)
        let skipped = batch.items.filter { [.skipped, .cancelled].contains($0.state) }.count + unprocessed
        let attention = batch.attentionCount
        let title = attention > 0 ? "本次清理需要核对" : succeeded.isEmpty && unprocessed > 0 ? "清理已停止" : skipped > 0 || succeeded.isEmpty ? "本次清理已结束" : "清理完成"
        let processedBytes = succeeded.reduce(UInt64(0)) { $0 &+ $1.bytes }
        return VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: attention > 0 ? "exclamationmark.circle" : skipped > 0 && succeeded.isEmpty ? "pause.circle" : "checkmark.circle")
                    .font(.system(size: 40, weight: .light)).foregroundStyle(attention > 0 ? palette.warning : palette.accent)
                    .frame(width: 72, height: 72).background(Circle().fill((attention > 0 ? palette.warning : palette.accent).opacity(0.10)))
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 26, weight: .medium)).accessibilityIdentifier("space-cleaning-completed-title")
                    Text("成功处理 \(succeeded.count) 项" + (skipped > 0 ? " · \(skipped) 项跳过或未处理" : "") + (attention > 0 ? " · \(attention) 项需要核对" : ""))
                        .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                completionMetric("\(succeeded.count) 项", caption: batch.method == .trash ? "已移入废纸篓" : "已永久删除", symbol: batch.method == .trash ? "trash" : "trash.slash")
                completionMetric(SpaceCleaningFormat.bytes(processedBytes), caption: "成功处理项目占用", symbol: "internaldrive")
                completionMetric("\(batch.restorableCount) 项", caption: "可从清理记录恢复", symbol: "arrow.uturn.backward")
            }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-completed-summary")
            Text(batch.method == .trash ? "移入废纸篓的项目仍然占用空间，可从清理记录逐项恢复，也可单独永久删除本批剩余项目。" : "永久删除的项目无法恢复。项目大小不等于实际释放空间，请以系统可用容量为准。")
                .font(.system(size: 12)).foregroundStyle(palette.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if batch.restorableCount > 0 {
                    Button("恢复本次项目") { model.requestRestore(batch.id) }.buttonStyle(WBButtonStyle()).disabled(model.isBusy)
                        .accessibilityIdentifier("space-cleaning-completed-restore")
                }
                Spacer(minLength: 8)
                Button("查看清理记录", action: model.showHistory).buttonStyle(WBButtonStyle())
                    .accessibilityIdentifier("space-cleaning-completed-history")
                Button("返回首页", action: model.goHome).buttonStyle(WBButtonStyle(primary: true))
                    .accessibilityIdentifier("space-cleaning-completed-home")
            }
        }.padding(28).frame(maxWidth: .infinity, minHeight: 360, alignment: .leading)
    }
    private func completionMetric(_ value: String, caption: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(palette.accent)
            Text(value).font(.system(size: 24, weight: .medium)).monospacedDigit()
            Text(caption).font(.system(size: 11)).foregroundStyle(palette.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.soft))
    }
}
