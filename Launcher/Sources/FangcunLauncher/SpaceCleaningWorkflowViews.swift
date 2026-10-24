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
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(palette.line).frame(height: 1)
            HStack(spacing: 12) {
                Button { expandedBatch = expandedBatch == batch.id ? nil : batch.id } label: {
                    HStack(spacing: 12) {
                        Image(systemName: expandedBatch == batch.id ? "chevron.down" : "chevron.right").font(.system(size: 10))
                        VStack(alignment: .leading, spacing: 7) {
                            Text(SpaceCleaningFormat.date(batch.date)).font(.system(size: 12, weight: .medium))
                            Text("\(batch.items.count) 项 · \(batch.method == .trash ? "移入废纸篓" : "永久删除") · \(batch.restorableCount) 项可恢复")
                                .font(.system(size: 11)).foregroundStyle(palette.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(ClickablePlainButtonStyle())
                Text(SpaceCleaningFormat.bytes(batch.bytes)).font(.system(size: 15)).monospacedDigit()
                if batch.restorableCount > 0 {
                    Button("恢复本次") { model.requestRestore(batch.id) }.buttonStyle(WBButtonStyle()).disabled(model.isBusy)
                }
            }.padding(.vertical, 18)
            if expandedBatch == batch.id {
                ForEach(batch.items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name).font(.system(size: 12))
                            Text(item.explanation).font(.system(size: 11)).foregroundStyle(palette.muted).textSelection(.enabled)
                            Text((item.resultURL ?? item.originalURL).path).font(.system(size: 10)).foregroundStyle(palette.muted).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.statusText).font(.system(size: 11)).foregroundStyle(palette.secondary)
                        if item.canRestore {
                            Button("恢复") { model.requestRestoreItem(item.id) }.buttonStyle(WBQuietButtonStyle()).disabled(model.isBusy)
                        }
                        if let result = item.resultURL {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([result]) } label: { Image(systemName: "folder") }
                                .buttonStyle(WBIconButtonStyle()).accessibilityLabel("在 Finder 中查看")
                        }
                    }.padding(.vertical, 12).padding(.leading, 22)
                }
                if batch.purgeableCount > 0 {
                    Button("永久删除本批废纸篓项目…") { model.requestPurge(batch.id) }
                        .buttonStyle(WBQuietButtonStyle()).disabled(model.isBusy).padding(.bottom, 16).padding(.leading, 22)
                }
            }
        }
    }
}
