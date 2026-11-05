import AppKit
import SwiftUI
import LauncherCore

struct SpaceCleaningHistoryView: View {
    @ObservedObject var model: SpaceCleaningModel
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.timeZone) private var timeZone
    @State private var expandedBatch: UUID?
    @StateObject private var search = CleaningHistorySearchModel()
    @State private var collapsedMatches: Set<UUID> = []
    @State private var availableWidth: CGFloat = 864
    @State private var initializedExpansion = false
    private var searching: Bool { SpaceCleaningHistorySearch.isSearching(search.query) }
    private var wide: Bool { availableWidth >= 780 }

    var body: some View {
        let matches = search.matches
        SpaceCleaningSurface {
            historyControls(matches: matches)
            if wide && !matches.isEmpty { batchColumns }
            WorkbenchScrollView {
                LazyVStack(spacing: 0) {
                    if search.isUpdating {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在整理记录…").font(.system(size: 12)).foregroundStyle(palette.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 70)
                            .accessibilityIdentifier("space-cleaning-history-updating")
                    } else {
                        if matches.isEmpty { emptyHistory }
                        ForEach(matches) { match in batchRow(match) }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 2)
            }.scrollBounceBehavior(.basedOnSize).accessibilityIdentifier("space-cleaning-history-scroll")
            Label("移入废纸篓后仍占用空间；永久删除仅保留操作记录。", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true).padding(14)
        }.background(GeometryReader { geometry in
            Color.clear.onAppear { availableWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in availableWidth = width }
                .allowsHitTesting(false)
        })
        .onAppear {
            if !initializedExpansion {
                expandedBatch = model.batches.first?.id
                initializedExpansion = true
            }
        }
        .onReceive(model.$batches) { batches in search.rebuild(batches, timeZone: timeZone) }
        .onChange(of: timeZone.identifier) { _, _ in search.rebuild(model.batches, timeZone: timeZone) }
        .onChange(of: search.query) { _, _ in collapsedMatches.removeAll() }
        .onDisappear { search.cancel() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-history")
    }

    private func historyControls(matches: [CleaningHistorySearchMatch]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { historyTitle; Spacer(minLength: 10); historySearch.frame(width: 300) }
                VStack(alignment: .leading, spacing: 12) { historyTitle; historySearch }
            }
            HStack(spacing: 12) {
                Text(search.isUpdating ? "正在更新匹配结果…" : searching ? "匹配 \(search.matchedItemCount) / 共 \(search.totalItemCount) 项 · \(matches.count) 次处理" : "\(search.batchCount) 次处理 · \(search.totalItemCount) 项记录")
                    .accessibilityIdentifier("space-cleaning-history-match-summary")
                Spacer(minLength: 8)
                if model.isReconcilingHistory {
                    Button("停止核对", action: model.cancelHistoryVerification).buttonStyle(WBButtonStyle(compact: true))
                } else {
                    if !search.isUpdating { Text("\(search.restorableCount) 项可恢复") }
                }
            }.font(.system(size: 11)).foregroundStyle(palette.muted)
        }.padding(14)
    }

    private var historyTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("处理记录").font(.system(size: 14, weight: .medium))
            Text("保留原位置与逐项结果，随时回看。")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var historySearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
            TextField("名称、路径、日期、方式或状态", text: $search.query).textFieldStyle(.plain)
                .accessibilityLabel("搜索清理记录")
                .accessibilityIdentifier("space-cleaning-history-search-input")
            if !search.query.isEmpty {
                Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(WBIconButtonStyle(size: 24)).accessibilityLabel("清除清理记录搜索")
                    .accessibilityIdentifier("space-cleaning-history-search-clear")
            }
        }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 32)
            .background(palette.soft, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-history-search")
    }

    private var emptyHistory: some View {
        VStack(spacing: 10) {
            Image(systemName: searching ? "magnifyingglass" : "clock.arrow.circlepath").font(.system(size: 24, weight: .light))
            Text(searching ? "没有匹配的清理记录" : "还没有清理记录").font(.system(size: 12, weight: .medium))
            Text(searching ? "可搜索文件名称、原路径、处理日期、方式或状态。" : "完成处理后，可在这里查看文件去向、大小与恢复状态。")
                .font(.system(size: 11)).multilineTextAlignment(.center)
            if searching {
                Button("清除搜索") { search.query = "" }.buttonStyle(WBButtonStyle(compact: true))
            }
        }.foregroundStyle(palette.muted).frame(maxWidth: .infinity).padding(.vertical, 70)
    }

    private var batchColumns: some View {
        HStack(spacing: 12) {
            Text("处理日期").frame(maxWidth: .infinity, alignment: .leading)
            Text("处理方式").frame(width: 100, alignment: .leading)
            Text("项目数量").frame(width: 68, alignment: .leading)
            Text("记录占用").frame(width: 100, alignment: .trailing)
            Text("结果").frame(width: 90, alignment: .leading)
            Color.clear.frame(width: 84, height: 1)
        }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.horizontal, 12).frame(height: 32)
            .background(palette.soft, in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 14)
            .accessibilityHidden(true)
    }

    private func batchRow(_ match: CleaningHistorySearchMatch) -> some View {
        let batch = match.batch
        let expanded = searching ? !collapsedMatches.contains(batch.id) : expandedBatch == batch.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if searching {
                    if expanded { collapsedMatches.insert(batch.id) } else { collapsedMatches.remove(batch.id) }
                } else { expandedBatch = expanded ? nil : batch.id }
            } label: {
                batchSummary(match, expanded: expanded).padding(12).contentShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 8, drawsSelection: false, showsBorder: false))
                .accessibilityLabel((expanded ? "收起" : "展开") + "清理记录 " + SpaceCleaningFormat.date(batch.date, timeZone: timeZone))
                .accessibilityValue(expanded ? "已展开" : "已收起")
                .accessibilityIdentifier("space-cleaning-history-expand-" + batch.id.uuidString)
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    if searching {
                        Text("匹配 \(match.items.count) / 共 \(batch.items.count) 项 · 上方合计为完整批次")
                            .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.vertical, 10)
                            .accessibilityIdentifier("space-cleaning-history-batch-matches-" + batch.id.uuidString)
                    }
                    if wide { itemColumns }
                    LazyVStack(spacing: 0) {
                        ForEach(match.items) { item in historyItem(item) }
                    }
                    batchActions(match)
                }.padding(12)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-history-table-" + batch.id.uuidString)
            }
            Rectangle().fill(palette.line).frame(height: 1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func batchSummary(_ match: CleaningHistorySearchMatch, expanded: Bool) -> some View {
        let batch = match.batch
        if wide {
            HStack(spacing: 12) {
                batchDate(batch).frame(maxWidth: .infinity, alignment: .leading)
                Text(SpaceCleaningHistorySearch.methodTitle(batch.method)).frame(width: 100, alignment: .leading)
                Text("\(batch.items.count) 项").frame(width: 68, alignment: .leading)
                Text(SpaceCleaningFormat.bytes(match.summary.allocatedBytes)).monospacedDigit().frame(width: 100, alignment: .trailing)
                batchStatus(match.summary).frame(width: 90, alignment: .leading)
                disclosure(expanded).frame(width: 84, alignment: .trailing)
            }.font(.system(size: 12)).frame(minHeight: 50)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack { batchDate(batch); Spacer(minLength: 8); disclosure(expanded) }
                HStack(spacing: 10) {
                    Text(SpaceCleaningHistorySearch.methodTitle(batch.method))
                    Text("\(batch.items.count) 项")
                    Text(SpaceCleaningFormat.bytes(match.summary.allocatedBytes)).monospacedDigit()
                    Spacer(minLength: 0)
                }.font(.system(size: 11)).foregroundStyle(palette.secondary)
                batchStatus(match.summary)
            }
        }
    }

    private func batchDate(_ batch: CleaningHistoryBatchDisplay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SpaceCleaningFormat.day(batch.date, timeZone: timeZone)).font(.system(size: 12, weight: .medium))
            Text(SpaceCleaningFormat.time(batch.date, timeZone: timeZone)).font(.system(size: 11)).foregroundStyle(palette.muted)
        }
    }

    private func batchStatus(_ summary: CleaningHistoryBatchSummary) -> some View {
        let tint = summary.hasAttention ? palette.warning : palette.accent
        return Text(summary.status).font(.system(size: 11))
            .foregroundStyle(tint).padding(.horizontal, 7).padding(.vertical, 4)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private func disclosure(_ expanded: Bool) -> some View {
        HStack(spacing: 6) {
            Text(expanded ? "收起明细" : "查看明细")
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).rotationEffect(.degrees(expanded ? 180 : 0))
        }.font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize()
    }

    private var itemColumns: some View {
        HStack(spacing: 12) {
            Text("项目 / 原位置").frame(maxWidth: .infinity, alignment: .leading)
            Text("文件大小").frame(width: 86, alignment: .trailing)
            Text("磁盘占用").frame(width: 86, alignment: .trailing)
            Text("处理结果 / 操作").frame(width: 228, alignment: .leading)
        }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.horizontal, 10).frame(height: 32)
            .background(palette.soft, in: RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
    }

    @ViewBuilder private func batchActions(_ match: CleaningHistorySearchMatch) -> some View {
        if searching {
            HStack(spacing: 8) {
                Text("搜索中仅支持逐项恢复；清除搜索后可操作完整批次。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("清除搜索") { search.query = "" }.buttonStyle(WBButtonStyle(compact: true))
            }.padding(.top, 14)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { batchNote(match); Spacer(minLength: 8); batchButtons(match) }
                VStack(alignment: .leading, spacing: 12) { batchNote(match); batchButtons(match) }
            }.padding(.top, 14)
        }
    }

    private func batchNote(_ match: CleaningHistorySearchMatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本批记录 \(match.batch.items.count) 项 · 扫描时占用 \(SpaceCleaningFormat.bytes(match.summary.allocatedBytes))")
                .font(.system(size: 11, weight: .medium))
            Text(match.summary.purgeableCount > 0 ? "仅处理仍在废纸篓且核验一致的项目" : match.summary.restorableCount > 0 ? "恢复前核验文件，不覆盖同名项目" : "文件状态与处理记录已保留")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func batchButtons(_ match: CleaningHistorySearchMatch) -> some View {
        HStack(spacing: 8) {
            if match.summary.purgeableCount > 0 {
                Button { model.requestPurge(match.id) } label: {
                    Label("永久删除本批 \(match.summary.purgeableCount) 项", systemImage: "doc.badge.minus").frame(minWidth: 120)
                }.buttonStyle(WBButtonStyle(destructive: true, compact: true)).disabled(model.isBusy || search.isUpdating || searching)
                    .accessibilityIdentifier("space-cleaning-history-purge-" + match.id.uuidString)
            }
            if match.summary.restorableCount > 0 {
                Button("恢复本批 \(match.summary.restorableCount) 项") { model.requestRestore(match.id) }
                    .buttonStyle(WBButtonStyle(compact: true)).disabled(model.isBusy || search.isUpdating || searching)
                    .accessibilityIdentifier("space-cleaning-history-restore-" + match.id.uuidString)
            }
        }
    }

    private func historyItem(_ item: CleaningHistoryItemDisplay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if wide {
                HStack(alignment: .center, spacing: 12) {
                    itemIdentity(item).frame(maxWidth: .infinity, alignment: .leading)
                    Text(SpaceCleaningFormat.bytes(item.bytes)).font(.system(size: 12)).monospacedDigit().frame(width: 86, alignment: .trailing)
                    Text(SpaceCleaningFormat.bytes(item.allocatedBytes)).font(.system(size: 12)).monospacedDigit().frame(width: 86, alignment: .trailing)
                    itemActions(item).frame(width: 228, alignment: .leading)
                }.padding(.horizontal, 10).padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    itemIdentity(item)
                    HStack(spacing: 14) {
                        itemSize("文件大小", value: item.bytes)
                        itemSize("磁盘占用", value: item.allocatedBytes)
                    }.padding(.leading, 34)
                    itemActions(item).padding(.leading, 34)
                }.padding(.horizontal, 10).padding(.vertical, 12)
            }
            Rectangle().fill(palette.line).frame(height: 1)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-history-item-" + item.id.uuidString)
    }

    private func itemIdentity(_ item: CleaningHistoryItemDisplay) -> some View {
        HStack(alignment: .center, spacing: 10) {
            SpaceCleaningFileGlyph(category: item.category)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(2).truncationMode(.middle)
                    .accessibilityIdentifier("space-cleaning-history-name-" + item.id.uuidString)
                Text(item.originalURL.path).font(.system(size: 11)).foregroundStyle(palette.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("space-cleaning-history-original-path-" + item.id.uuidString)
                if let currentURL = item.resultURL, currentURL != item.originalURL,
                   [.restored, .needsReview, .isolated, .restoring, .deleting].contains(item.state) {
                    Text("当前位置：" + currentURL.path).font(.system(size: 11)).foregroundStyle(palette.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !item.explanation.isEmpty {
                    Text(item.explanation).font(.system(size: 11)).foregroundStyle(palette.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func itemSize(_ title: String, value: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.muted)
            Text(SpaceCleaningFormat.bytes(value)).font(.system(size: 12)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemActions(_ item: CleaningHistoryItemDisplay) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(item.statusText).font(.system(size: 11)).foregroundStyle(itemTint(item))
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 28)
                .accessibilityIdentifier("space-cleaning-history-status-" + item.id.uuidString)
            Spacer(minLength: 0)
            if item.canRestore {
                Button("恢复") { model.requestRestoreItem(item.id) }.buttonStyle(WBButtonStyle(compact: true)).disabled(model.isBusy || search.isUpdating)
                    .accessibilityIdentifier("space-cleaning-history-restore-item-" + item.id.uuidString)
            }
            if let result = item.resultURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([result]) } label: { Image(systemName: "folder") }
                    .buttonStyle(WBIconButtonStyle(size: 28)).accessibilityLabel("在 Finder 中查看 " + item.name)
                    .disabled(search.isUpdating)
                    .accessibilityIdentifier("space-cleaning-history-reveal-" + item.id.uuidString)
            }
        }
    }

    private func itemTint(_ item: CleaningHistoryItemDisplay) -> Color {
        if [.failed, .needsReview].contains(item.state) { return palette.warning }
        if [.trashed, .deleted, .restored].contains(item.state) { return palette.accent }
        return palette.secondary
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
                WorkbenchScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        completionHeading(title: "本次处理已结束", subtitle: "尚无已确认的成功处理记录。", symbol: "info.circle", needsAttention: true)
                        Text("本次原计划 \(model.processingTotal) 项，已核对 \(model.processingCompleted) 项。")
                            .font(.system(size: 12)).foregroundStyle(palette.secondary)
                        Text("可在清理记录中查看逐项状态；未确认的结果不计为清理成功。")
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                    }.fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 700, alignment: .leading).padding(24).frame(maxWidth: .infinity)
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
            WorkbenchScrollView {
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
                        if !model.reviewableItems.isEmpty {
                            Label("扫描结果中还有 \(model.reviewableItems.count) 项可复核内容，可返回继续选择；处理前仍会逐项重新核验。", systemImage: "list.bullet")
                                .font(.system(size: 11)).foregroundStyle(palette.muted)
                                .accessibilityIdentifier("space-cleaning-completed-remaining")
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                    if !pending.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("跳过与待核对项目").font(.system(size: 12, weight: .medium))
                            ForEach(pending) { item in completionIssue(item) }
                        }
                    }
                }.frame(maxWidth: 700, alignment: .leading).padding(24).frame(maxWidth: .infinity)
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
            // Remaining verified results stay selectable; continuing is the main path.
            Button("返回首页", action: model.goHome).buttonStyle(WBButtonStyle(primary: !model.canReturnToResults))
                .accessibilityIdentifier("space-cleaning-completed-home")
            if model.canReturnToResults {
                Button("返回扫描结果", action: model.returnToResults).buttonStyle(WBButtonStyle(primary: true))
                    .accessibilityIdentifier("space-cleaning-completed-results")
            }
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
