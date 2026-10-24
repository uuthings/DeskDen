import SwiftUI
import LauncherCore

struct SpaceCleaningResultsView: View {
    @ObservedObject var model: SpaceCleaningModel
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        VStack(spacing: 14) {
            SpaceCleaningSurface {
                summary
                controls
                tableHeader
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleItems) { item in row(item).id(item.id) }
                        if model.visibleItems.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "checkmark.circle").font(.system(size: 24, weight: .light))
                                Text(model.items.isEmpty ? "本次范围内没有发现可复核项目" : "没有匹配的项目")
                                if model.onlySelected { Button("查看全部") { model.onlySelected = false }.buttonStyle(WBQuietButtonStyle()) }
                            }.font(.system(size: 12)).foregroundStyle(palette.muted).frame(maxWidth: .infinity).padding(.vertical, 44)
                        }
                    }.scrollTargetLayout().background(WorkbenchOverlayScrollbars())
                }.scrollPosition(id: $model.resultScrollID, anchor: .top).scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("space-cleaning-result-list")
                HStack {
                    Text("点击文件名，展开依据与处理影响")
                    Spacer()
                    if !model.coverageIssues.isEmpty {
                        Button("\(model.coverageIssues.count) 处未完整覆盖") { model.dialog = .issues }.buttonStyle(.plain).foregroundStyle(palette.warning)
                    }
                    Text("显示 \(model.visibleItems.count) 项")
                }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.horizontal, 24).frame(height: 38)
                    .background(palette.soft)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-results-surface")
            selectionFooter
        }
    }
    private var summary: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("扫描结果").font(.system(size: 20, weight: .medium))
                Text(model.reportSummary).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                Text(SpaceCleaningFormat.bytes(model.reviewableItems.reduce(0) { $0 &+ $1.bytes })).font(.system(size: 27)).monospacedDigit()
                Text("待复核占用 · 尚未释放").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }.padding(24).padding(.bottom, 0)
    }
    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                tab("待复核", count: model.reviewableItems.count, selected: model.resultTab == .reviewable) { model.resultTab = .reviewable }
                if !model.protectedItems.isEmpty {
                    tab("受保护", count: model.protectedItems.count, selected: model.resultTab == .protected) { model.resultTab = .protected; model.onlySelected = false }
                }
            }.padding(3).background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line))
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                TextField("查找名称或路径", text: $model.searchText).textFieldStyle(.plain)
                if !model.searchText.isEmpty { Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.font(.system(size: 11)).padding(.horizontal, 10).frame(width: 172, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft)).overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line))
            Button { model.onlySelected.toggle(); if model.onlySelected { model.resultTab = .reviewable } } label: {
                Label("仅看已选  \(model.selectedCount)", systemImage: model.onlySelected ? "checklist.checked" : "checklist")
                    .font(.system(size: 11)).foregroundStyle(model.onlySelected ? palette.accent : palette.muted)
            }.buttonStyle(.plain)
        }.padding(.horizontal, 24).padding(.bottom, 18)
    }
    private func tab(_ text: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(text)
                Text(count.formatted()).font(.system(size: 10)).padding(.horizontal, 4).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(palette.soft))
            }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? palette.accent.opacity(0.18) : .clear))
        }.buttonStyle(.plain).accessibilityValue(selected ? "已选择" : "未选择")
    }
    private var tableHeader: some View {
        HStack(spacing: 14) {
            let ids = model.visibleSelectableIDs
            let all = !ids.isEmpty && ids.isSubset(of: model.selectedIDs)
            let mixed = !all && !ids.isDisjoint(with: model.selectedIDs)
            Button(action: model.toggleVisibleSelection) {
                Image(systemName: all ? "checkmark.square.fill" : mixed ? "minus.square.fill" : "square")
                    .font(.system(size: 17)).foregroundStyle(all || mixed ? palette.accent : palette.muted)
            }.buttonStyle(.plain).disabled(ids.isEmpty || model.isBusy || model.requiresRescan)
                .accessibilityLabel("选择当前显示的可处理项目").accessibilityValue(all ? "全选" : mixed ? "部分选择" : "未选")
            Text("文件与位置").frame(maxWidth: .infinity, alignment: .leading)
            Text("识别状态与依据").frame(width: 180, alignment: .leading)
            Text("占用").frame(width: 88, alignment: .trailing)
        }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.horizontal, 24).frame(height: 36)
            .background(palette.soft).overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }
    private func row(_ item: CleaningItemDisplay) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if item.group == .protected {
                    Image(systemName: "lock").font(.system(size: 14)).foregroundStyle(palette.muted).frame(width: 18)
                } else {
                    Toggle("选择 \(item.name)", isOn: Binding(get: { model.selectedIDs.contains(item.id) }, set: { _ in model.toggleItem(item.id) }))
                        .labelsHidden().toggleStyle(.checkbox).disabled(!item.isSelectable || model.isBusy || model.requiresRescan)
                        .accessibilityIdentifier("space-cleaning-select-" + item.id.uuidString)
                }
                Button { model.showDetail(item.id) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Image(systemName: model.detailID == item.id ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(palette.muted)
                        }
                        Text(model.shortPath(item.url)).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.isBusy)
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.group == .protected ? "受保护" : item.group == .rebuildable ? "可重新生成" : "由你判断用途")
                        .foregroundStyle(item.group == .rebuildable ? palette.accent : palette.secondary)
                    Text(item.reason).foregroundStyle(palette.muted).lineLimit(1)
                }.font(.system(size: 11)).frame(width: 180, alignment: .leading)
                Text((item.sizeIsComplete ? "" : "至少 ") + SpaceCleaningFormat.bytes(item.bytes))
                    .font(.system(size: 12)).monospacedDigit().lineLimit(2).frame(width: 88, alignment: .trailing)
            }.padding(.horizontal, 24).frame(height: 70).background(model.detailID == item.id ? palette.soft : .clear)
            if model.detailID == item.id { detail(item) }
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }
    private func detail(_ item: CleaningItemDisplay) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            detailLine("识别依据", item.reason)
            detailLine("处理影响", item.impact)
            detailLine("完整路径", item.url.path)
            HStack(spacing: 8) {
                Button("快速预览") { model.preview(item.id) }.buttonStyle(WBButtonStyle())
                Button("在 Finder 中查看") { model.reveal(item.id) }.buttonStyle(WBButtonStyle())
                Spacer()
                if item.needsPurposeConfirmation && model.dialog != .purpose(item.id) {
                    Button("这是测试包…") { model.requestTestPurpose(item.id) }.buttonStyle(WBQuietButtonStyle()).disabled(model.requiresRescan || model.isBusy)
                }
            }
            if model.dialog == .purpose(item.id) {
                Rectangle().fill(palette.line).frame(height: 1)
                Toggle("我确认它仅用于测试，不是发布原件或唯一保留归档", isOn: $model.acknowledgement)
                    .toggleStyle(.checkbox).font(.system(size: 11)).disabled(model.isBusy)
                HStack {
                    Text("仅重新核验这一项；不会自动勾选，也不解除其他文件的保护。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                    Spacer(minLength: 8)
                    Button("取消", action: model.closeDialog).buttonStyle(WBQuietButtonStyle()).disabled(model.isBusy)
                    Button(model.purposeReviewID == item.id ? "正在核验…" : "确认测试用途") { model.confirmTestPurpose(item.id) }
                        .buttonStyle(WBButtonStyle(primary: true)).disabled(!model.acknowledgement || model.isBusy)
                }
            }
        }.padding(EdgeInsets(top: 15, leading: 56, bottom: 20, trailing: 24)).background(palette.soft)
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-file-detail")
    }
    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title).foregroundStyle(palette.muted).frame(width: 54, alignment: .leading)
            Text(value).foregroundStyle(palette.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11)).lineSpacing(4)
    }
    private var selectionFooter: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(model.selectedCount == 0 ? "尚未选择文件" : "已选 \(model.selectedCount) 项 · \(SpaceCleaningFormat.bytes(model.selectedBytes))")
                        .font(.system(size: 12, weight: .medium))
                    if model.selectedCount > 0 { Button("清空", action: model.clearSelection).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(palette.muted) }
                }
                Text("复核确认后才会处理文件").font(.system(size: 11)).foregroundStyle(palette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            SpaceCleaningMethodPicker(method: $model.method).disabled(model.isBusy)
            Button(action: model.requestConfirmation) { Label("复核所选", systemImage: "arrow.right") }
                .buttonStyle(WBButtonStyle(primary: true)).disabled(!model.canProcess)
                .accessibilityIdentifier("space-cleaning-review-continue")
        }.padding(.horizontal, 18).frame(height: 70).background(WorkbenchMaterialSurface(radius: 12))
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-selection-footer")
    }
}

struct SpaceCleaningMethodPicker: View {
    @Binding var method: SpaceCleaningMethod
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        HStack(spacing: 2) {
            choice("移入废纸篓", value: .trash)
            choice("永久删除", value: .permanent)
        }.padding(3).background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.controlBorder))
    }
    private func choice(_ title: String, value: SpaceCleaningMethod) -> some View {
        Button { method = value } label: {
            Text(title).font(.system(size: 11)).padding(.horizontal, 9).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 5).fill(method == value ? palette.accent.opacity(0.22) : .clear))
        }.buttonStyle(.plain).accessibilityValue(method == value ? "已选择" : "未选择")
    }
}
