import AppKit
import SwiftUI
import LauncherCore

struct SpaceCleaningScopeView: View {
    @ObservedObject var model: SpaceCleaningModel
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        SpaceCleaningSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("选择扫描范围").font(.system(size: 20, weight: .medium))
                Text("先确定位置，开始扫描由你决定。").font(.system(size: 12)).foregroundStyle(palette.muted)
                HStack(spacing: 12) {
                    choice("全局扫描", subtitle: "检查这台 Mac 的当前用户位置", icon: "globe", value: .global)
                    choice("自定义位置", subtitle: "一次添加多个文件夹", icon: "folder", value: .custom)
                }.padding(.top, 10)
            }.padding(24)
            Rectangle().fill(palette.line).frame(height: 1)
            if model.draftScope == .global {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("一次扫描，无需按目录分别检查", systemImage: "checkmark.circle").font(.system(size: 15, weight: .medium))
                        Text("包括当前用户的桌面、文稿、下载、影音与开发目录，以及已识别的缓存、构建和归档位置。")
                        Text("系统目录、其他用户、外接磁盘与云端未下载内容不自动纳入。无法访问或未完整检查的位置会列在扫描结果中。")
                        Text("发布档案与正在使用的内容持续受保护；扫描不会自动删除任何项目。")
                    }.font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(6).padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading).background(WorkbenchOverlayScrollbars())
                }.scrollBounceBehavior(.basedOnSize)
            } else {
                HStack {
                    Text("已选择 \(model.draftDirectories.count) 个文件夹").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(action: model.chooseCustomDirectory) { Label("浏览文件夹…", systemImage: "plus") }
                        .buttonStyle(WBButtonStyle()).accessibilityIdentifier("space-cleaning-browse")
                }.padding(24).padding(.bottom, -10)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.draftDirectories.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "folder.badge.plus").font(.system(size: 32, weight: .light)).foregroundStyle(palette.accent)
                                Text("选择一个或多个本地文件夹").font(.system(size: 14))
                                Text("使用系统文件选择器，可按住 Command 多选。")
                                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                            }.frame(maxWidth: .infinity).padding(.vertical, 36)
                        }
                        ForEach(model.draftDirectories, id: \.self) { url in
                            HStack(spacing: 12) {
                                Image(systemName: "folder").font(.system(size: 20)).foregroundStyle(palette.accent)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(url.lastPathComponent).font(.system(size: 12, weight: .medium))
                                    Text(model.shortPath(url)).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button { model.removeDraftDirectory(url) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(WBIconButtonStyle()).accessibilityLabel("移除 " + url.lastPathComponent)
                            }.padding(.vertical, 14)
                            Rectangle().fill(palette.line).frame(height: 1)
                        }
                    }.padding(.horizontal, 24).background(WorkbenchOverlayScrollbars())
                }.scrollBounceBehavior(.basedOnSize)
            }
            HStack {
                Text("重叠目录会自动合并 · 更改范围后需重新扫描").font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer()
                Button("取消", action: model.cancelScope).buttonStyle(WBButtonStyle())
                Button(model.draftScope == .global ? "使用全局扫描" : "使用这 \(model.draftDirectories.count) 个位置", action: model.applyScope)
                    .buttonStyle(WBButtonStyle(primary: true)).disabled(model.draftScope == .custom && model.draftDirectories.isEmpty)
                    .accessibilityIdentifier("space-cleaning-apply-scope")
            }.padding(20).background(palette.soft)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-scope-editor")
    }
    private func choice(_ title: String, subtitle: String, icon: String, value: CleaningScopeChoice) -> some View {
        Button { model.draftScope = value } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 19)).foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: model.draftScope == value ? "checkmark.circle.fill" : "circle").foregroundStyle(palette.accent)
            }.padding(14).background(RoundedRectangle(cornerRadius: 10).fill(model.draftScope == value ? palette.soft : .clear))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.draftScope == value ? palette.accent.opacity(0.45) : palette.line))
        }.buttonStyle(.plain).accessibilityValue(model.draftScope == value ? "已选择" : "未选择")
    }
}

struct SpaceCleaningReviewView: View {
    @ObservedObject var model: SpaceCleaningModel
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        SpaceCleaningSurface {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("最后复核一次").font(.system(size: 22, weight: .medium))
                    Text("确认所选文件与处理方式。执行前还会重新核验文件和保护状态。")
                        .font(.system(size: 12)).foregroundStyle(palette.muted)
                }
                Spacer()
                Text("\(model.selectedCount) 项").font(.system(size: 24)).monospacedDigit()
            }.padding(24)
            Rectangle().fill(palette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 24) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.selectedItems) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "doc").foregroundStyle(palette.accent)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.name).font(.system(size: 12)).lineLimit(2)
                                    Text(model.shortPath(item.url)).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(SpaceCleaningFormat.bytes(item.bytes)).font(.system(size: 11)).monospacedDigit()
                            }.padding(.vertical, 14)
                            Rectangle().fill(palette.line).frame(height: 1)
                        }
                    }.background(WorkbenchOverlayScrollbars())
                }.scrollBounceBehavior(.basedOnSize).frame(maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(SpaceCleaningFormat.bytes(model.selectedBytes)).font(.system(size: 29)).monospacedDigit()
                        Text("所选项目占用").font(.system(size: 11)).foregroundStyle(palette.muted)
                        SpaceCleaningMethodPicker(method: $model.method)
                        Text(model.method == .trash ? "移入废纸篓后，可从清理记录恢复。此时占用尚未释放；需要释放空间时，可单独永久删除这一批项目。" : "所选项目将直接删除，无法从清理记录恢复。")
                            .font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(6)
                        Toggle("记住这种处理方式，下次仍需确认", isOn: $model.rememberMethod)
                            .toggleStyle(.checkbox).font(.system(size: 11)).accessibilityIdentifier("space-cleaning-remember-method")
                        if model.method == .permanent {
                            Toggle("我已复核所选项目，理解永久删除无法恢复", isOn: $model.acknowledgement)
                                .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(palette.warning)
                                .accessibilityIdentifier("space-cleaning-permanent-acknowledgement")
                        }
                    }.padding(.top, 14).background(WorkbenchOverlayScrollbars())
                }.frame(width: 250).scrollBounceBehavior(.basedOnSize)
            }.padding(.horizontal, 24).padding(.bottom, 20)
            HStack {
                Button("返回复核", action: model.closeDialog).buttonStyle(WBButtonStyle())
                Spacer()
                Button(model.method == .trash ? "移到废纸篓" : "永久删除所选项目") {
                    model.executeConfirmed(permanent: model.method == .permanent, remember: model.rememberMethod)
                }.buttonStyle(WBButtonStyle(primary: model.method == .trash, destructive: model.method == .permanent))
                    .disabled(!model.canProcess || (model.method == .permanent && !model.acknowledgement))
                    .accessibilityIdentifier("space-cleaning-confirm-execute")
            }.padding(20).background(palette.soft)
        }.onChange(of: model.method) { _, _ in model.acknowledgement = false }
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-confirmation")
    }
}

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
                }.buttonStyle(.plain)
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
