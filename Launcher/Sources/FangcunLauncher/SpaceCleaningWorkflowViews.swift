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
            HStack(spacing: 12) {
                Text("\(model.batches.count) 次处理 · \(model.batches.reduce(0) { $0 + $1.items.count }) 项记录")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer(minLength: 8)
                Text("\(model.batches.reduce(0) { $0 + $1.restorableCount }) 项可恢复")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
                if model.isReconcilingHistory {
                    Button("停止核对", action: model.cancelHistoryVerification)
                        .buttonStyle(WBButtonStyle(compact: true))
                }
                if let onLegacyHistory {
                    Button("早期处理记录", action: onLegacyHistory)
                        .buttonStyle(WBButtonStyle(compact: true))
                }
            }.frame(minHeight: 28).padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if model.batches.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 24, weight: .light))
                            Text("还没有清理记录").font(.system(size: 12, weight: .medium))
                            Text("完成处理后，可在这里查看文件去向与恢复状态。")
                                .font(.system(size: 11))
                        }.foregroundStyle(palette.muted).frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                    ForEach(model.batches) { batch in batchRow(batch) }
                }.padding(.horizontal, 14).padding(.bottom, 2).background(WorkbenchOverlayScrollbars())
            }.scrollBounceBehavior(.basedOnSize)
            Label("移入废纸篓后仍占用空间；永久删除仅保留操作记录。", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true).padding(14)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-history")
    }

    private func batchRow(_ batch: CleaningHistoryBatchDisplay) -> some View {
        let expanded = expandedBatch == batch.id
        return VStack(alignment: .leading, spacing: 0) {
            Button { expandedBatch = expanded ? nil : batch.id } label: {
                HStack(alignment: .center, spacing: 10) {
                    SpaceCleaningRecordOperationIcon(method: batch.method)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(SpaceCleaningFormat.date(batch.date)).font(.system(size: 12, weight: .medium))
                        Text("\(batch.method == .trash ? "移入废纸篓" : "永久删除") · \(batch.items.count) 项 · 扫描时占用 \(SpaceCleaningFormat.bytes(batch.allocatedBytes))")
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(batch.restorableCount > 0 ? "\(batch.restorableCount) 项可恢复" : batch.attentionCount > 0 ? "\(batch.attentionCount) 项需核对" : "处理已结束")
                        .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(expanded ? palette.accent : palette.muted).frame(width: 16, height: 28)
                }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).padding(12)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 10, drawsSelection: false, showsBorder: false))
                .accessibilityLabel((expanded ? "收起" : "展开") + "清理记录 " + SpaceCleaningFormat.date(batch.date))
                .accessibilityValue(expanded ? "已展开" : "已收起")
                .accessibilityIdentifier("space-cleaning-history-expand-" + batch.id.uuidString)
            if expanded {
                VStack(spacing: 8) {
                    ForEach(batch.items) { item in historyItem(item) }
                }.padding(.horizontal, 12)
                HStack(spacing: 8) {
                    Text(batch.purgeableCount > 0 ? "仅处理本批仍在废纸篓且核验一致的项目" : batch.restorableCount > 0 ? "恢复前核验文件，不覆盖同名项目" : "文件状态与处理记录已保留")
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if batch.purgeableCount > 0 {
                        Button { model.requestPurge(batch.id) } label: {
                            Label("永久删除本批 \(batch.purgeableCount) 项", systemImage: "doc.badge.minus")
                                .frame(minWidth: 120)
                        }.buttonStyle(WBButtonStyle(destructive: true, compact: true)).disabled(model.isBusy)
                            .accessibilityIdentifier("space-cleaning-history-purge-" + batch.id.uuidString)
                    }
                    if batch.restorableCount > 0 {
                        Button("恢复本次") { model.requestRestore(batch.id) }
                            .buttonStyle(WBButtonStyle(compact: true)).disabled(model.isBusy)
                            .accessibilityIdentifier("space-cleaning-history-restore-" + batch.id.uuidString)
                    }
                }.padding(12)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.soft))
    }

    private func historyItem(_ item: CleaningHistoryItemDisplay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: SpaceCleaningRecordFileSymbol.name(for: item.originalURL))
                        .font(.system(size: 18, weight: .regular)).foregroundStyle(palette.secondary)
                        .frame(width: 24, height: 28).accessibilityHidden(true)
                    Text(item.name).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .center, spacing: 10) {
                    Text(item.statusText).font(.system(size: 11)).foregroundStyle(palette.secondary)
                        .lineLimit(1).fixedSize().frame(minHeight: 28)
                        .accessibilityIdentifier("space-cleaning-history-status-" + item.id.uuidString)
                    if item.canRestore {
                        Button("恢复") { model.requestRestoreItem(item.id) }
                            .buttonStyle(WBButtonStyle(compact: true)).disabled(model.isBusy)
                            .accessibilityIdentifier("space-cleaning-history-restore-item-" + item.id.uuidString)
                    }
                    if let result = item.resultURL {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([result]) } label: { Image(systemName: "folder") }
                            .buttonStyle(WBIconButtonStyle(size: 28)).accessibilityLabel("在 Finder 中查看 " + item.name)
                            .accessibilityIdentifier("space-cleaning-history-reveal-" + item.id.uuidString)
                    }
                }.fixedSize()
            }.frame(minHeight: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text((item.resultURL ?? item.originalURL).path)
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("文件大小 \(SpaceCleaningFormat.bytes(item.bytes)) · 扫描时磁盘占用 \(SpaceCleaningFormat.bytes(item.allocatedBytes))")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                if !item.explanation.isEmpty {
                    Text(item.explanation).font(.system(size: 11)).foregroundStyle(palette.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.leading, 32)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-history-item-" + item.id.uuidString)
    }
}

private struct SpaceCleaningRecordOperationIcon: View {
    let method: SpaceCleaningMethod
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        Group {
            if method == .trash, let trash = NSImage(named: NSImage.trashFullName) {
                Image(nsImage: trash).resizable().interpolation(.high).scaledToFit().frame(width: 24, height: 26)
            } else if method == .trash {
                Image(systemName: "trash").font(.system(size: 18)).foregroundStyle(palette.secondary)
            } else {
                Image(systemName: "doc").font(.system(size: 18)).foregroundStyle(palette.secondary)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10, weight: .medium))
                            .symbolRenderingMode(.palette).foregroundStyle(palette.critical, palette.control)
                            .offset(x: 4, y: 2)
                    }
            }
        }.accessibilityHidden(true)
    }
}

private enum SpaceCleaningRecordFileSymbol {
    // History paths can be stale. Resolve only from the recorded extension, without touching the file.
    static func name(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tif", "tiff", "svg", "avif": "photo"
        case "mov", "mp4", "m4v", "mkv", "avi", "webm": "film"
        case "mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg": "waveform"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "xcarchive": "archivebox"
        case "dmg", "iso": "opticaldiscdrive"
        case "pkg": "shippingbox"
        case "app": "app"
        case "swift", "js", "ts", "tsx", "jsx", "py", "rs", "go", "c", "h", "cpp", "java", "json", "yaml", "yml", "xml", "html", "css", "sh": "chevron.left.forwardslash.chevron.right"
        case "pdf", "doc", "docx", "rtf", "pages": "doc.richtext"
        case "xls", "xlsx", "csv", "numbers": "tablecells"
        case "log", "txt", "md": "doc.text"
        default: "doc"
        }
    }
}

struct SpaceCleaningCompletionView: View {
    @ObservedObject var model: SpaceCleaningModel
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        SpaceCleaningSurface {
            if let batch = model.currentBatch {
                completion(batch)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        completionHeading(title: "本次处理已结束", subtitle: "尚无已确认的成功处理记录。", symbol: "info.circle", needsAttention: true)
                        Text("本次原计划 \(model.processingTotal) 项，已核对 \(model.processingCompleted) 项。")
                            .font(.system(size: 12)).foregroundStyle(palette.secondary)
                        Text("可在清理记录中查看逐项状态；未确认的结果不计为清理成功。")
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                    }.fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 700, alignment: .leading).padding(24).frame(maxWidth: .infinity)
                        .background(WorkbenchOverlayScrollbars())
                }.scrollBounceBehavior(.basedOnSize)
                completionActions(batch: nil)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-completed")
    }

    private func completion(_ batch: CleaningHistoryBatchDisplay) -> some View {
        let succeeded = batch.items.filter { [.trashed, .deleted].contains($0.state) }
        let unprocessed = max(0, model.processingTotal - model.processingCompleted)
        let skipped = batch.items.filter { [.skipped, .cancelled].contains($0.state) }.count + unprocessed
        let attention = batch.attentionCount
        let restored = batch.items.filter { $0.state == .restored }.count
        let pending = batch.items.filter { ![.trashed, .deleted, .restored].contains($0.state) }
        let title = attention > 0 ? "本次清理需要核对" : succeeded.isEmpty && unprocessed > 0 ? "清理已停止" : skipped > 0 || succeeded.isEmpty ? "本次清理已结束" : "清理完成"
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    completionHeading(
                        title: title,
                        subtitle: "成功处理 \(succeeded.count) 项" + (skipped > 0 ? " · \(skipped) 项跳过或未处理" : "") + (attention > 0 ? " · \(attention) 项需要核对" : "") + (restored > 0 ? " · \(restored) 项已恢复" : ""),
                        symbol: attention > 0 ? "exclamationmark.circle" : skipped > 0 && succeeded.isEmpty ? "pause.circle" : "checkmark.circle",
                        needsAttention: attention > 0
                    )
                    HStack(spacing: 12) {
                        completionMetric("\(succeeded.count) 项", caption: "已确认处理", symbol: "checkmark.circle")
                        completionMetric(SpaceCleaningFormat.bytes(batch.successfulAllocatedBytes), caption: "处理项目扫描时占用", symbol: "internaldrive")
                        completionMetric("\(batch.restorableCount) 项", caption: "可从清理记录恢复", symbol: "arrow.uturn.backward")
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-completed-summary")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(batch.method == .trash ? "移入废纸篓的项目仍然占用空间，可从清理记录逐项恢复，也可单独永久删除本批剩余项目。" : "永久删除的项目无法恢复。项目大小不等于实际释放空间，请以系统可用容量为准。")
                            .font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(4)
                        Label("文件去向、处理状态与失败原因已保存在清理记录中。", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                    }.fixedSize(horizontal: false, vertical: true)
                    if !pending.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("跳过与待核对项目").font(.system(size: 12, weight: .medium))
                            ForEach(pending) { item in completionIssue(item) }
                        }
                    }
                }.frame(maxWidth: 700, alignment: .leading).padding(24).frame(maxWidth: .infinity)
                    .background(WorkbenchOverlayScrollbars())
            }.scrollBounceBehavior(.basedOnSize)
            completionActions(batch: batch)
        }
    }

    private func completionHeading(title: String, subtitle: String, symbol: String, needsAttention: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light))
                .foregroundStyle(needsAttention ? palette.warning : palette.accent)
                .frame(width: 64, height: 64)
                .background(Circle().fill((needsAttention ? palette.warning : palette.accent).opacity(0.10)))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 20, weight: .medium)).accessibilityIdentifier("space-cleaning-completed-title")
                Text(subtitle).font(.system(size: 12)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func completionIssue(_ item: CleaningHistoryItemDisplay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: SpaceCleaningRecordFileSymbol.name(for: item.originalURL))
                    .font(.system(size: 16)).foregroundStyle(palette.secondary).frame(width: 20)
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(item.statusText).font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            Text(item.explanation).font(.system(size: 11)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.leading, 28)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
    }

    private func completionActions(batch: CleaningHistoryBatchDisplay?) -> some View {
        HStack(spacing: 10) {
            if let batch, batch.restorableCount > 0 {
                Button("恢复本次项目") { model.requestRestore(batch.id) }
                    .buttonStyle(WBButtonStyle()).disabled(model.isBusy)
                    .accessibilityIdentifier("space-cleaning-completed-restore")
            }
            Spacer(minLength: 8)
            Button("查看清理记录", action: model.showHistory).buttonStyle(WBButtonStyle())
                .accessibilityIdentifier("space-cleaning-completed-history")
            Button("返回首页", action: model.goHome).buttonStyle(WBButtonStyle(primary: true))
                .accessibilityIdentifier("space-cleaning-completed-home")
        }.padding(14)
    }

    private func completionMetric(_ value: String, caption: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(caption, systemImage: symbol).font(.system(size: 11)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 32, alignment: .topLeading)
            Text(value).font(.system(size: 26, weight: .regular)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, minHeight: 84, alignment: .leading).padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.soft))
    }
}
