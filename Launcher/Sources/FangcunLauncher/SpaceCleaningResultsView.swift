import SwiftUI
import LauncherCore

struct SpaceCleaningResultsView: View {
    @ObservedObject var model: SpaceCleaningModel
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchScale) private var displayScale
    private let columnGap: CGFloat = 12
    private let typeWidth: CGFloat = 86
    private let dateWidth: CGFloat = 110
    private let sizeWidth: CGFloat = 80
    private var confirming: Bool { model.dialog == .confirm }
    @State private var availableWidth: CGFloat = 864

    var body: some View {
        VStack(spacing: 12) {
            SpaceCleaningSurface {
                summary
                controls
                tableHeader
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleItems) { item in row(item).id(item.id) }
                        if model.visibleItems.isEmpty { emptyResults }
                    }.scrollTargetLayout().background(WorkbenchOverlayScrollbars())
                }.scrollPosition(id: $model.resultScrollID, anchor: .top).scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("space-cleaning-result-list")
                HStack {
                    Text(model.onlySelected ? "显示全部已选项目，可直接在下方清理" : model.resultTab == .protected ? "这些项目保持保留，展开可查看具体原因" : "点击文件名查看详情，或在 Finder 中定位")
                    Spacer(minLength: 8)
                    if !model.coverageIssues.isEmpty {
                        Button("\(model.coverageIssues.count) 处未完整覆盖") { model.dialog = .issues }
                            .buttonStyle(WBTextActionButtonStyle()).foregroundStyle(palette.warning)
                    }
                    Text("\(model.visibleItems.count) 项")
                }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.horizontal, 14).frame(height: 34)
                    .background(palette.soft)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-results-surface")
            selectionFooter
        }.background(GeometryReader { geometry in
            Color.clear.onAppear { availableWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in availableWidth = width }
                .allowsHitTesting(false)
        })
    }
    private var summary: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("扫描结果").font(.system(size: 18, weight: .medium))
                Text(model.reportSummary).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(SpaceCleaningFormat.bytes(model.recommendedItems.reduce(0) { $0 &+ $1.bytes }))
                    .font(.system(size: 27, weight: .medium)).monospacedDigit()
                Text("建议清理占用").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }.padding(14).padding(.vertical, 4)
    }
    private var controls: some View {
        HStack(spacing: 18) {
            tab("建议清理", count: model.recommendedItems.count, value: .recommended)
            tab("其他文件", count: model.otherItems.count, value: .reviewable)
            if !model.protectedItems.isEmpty { tab("已保护", count: model.protectedItems.count, value: .protected) }
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                TextField("搜索名称或目录", text: $model.searchText).textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(WBIconButtonStyle(size: 24)).accessibilityLabel("清除搜索")
                }
            }.font(.system(size: 11)).padding(.horizontal, 10).frame(width: min(260, max(196, availableWidth * 0.26)), height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft)).overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line))
                .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-search")
        }.padding(.horizontal, 14)
    }
    private func tab(_ title: String, count: Int, value: CleaningResultTab) -> some View {
        let active = model.resultTab == value && !model.onlySelected
        return Button { model.showResults(value) } label: {
            HStack(spacing: 6) {
                Text(title).fontWeight(active ? .semibold : .regular)
                Text(count.formatted()).font(.system(size: 10)).monospacedDigit().foregroundStyle(palette.muted)
            }.font(.system(size: 12)).foregroundStyle(active ? palette.text : palette.muted).frame(height: 40)
                .overlay(alignment: .bottom) { if active { Capsule().fill(palette.accent).frame(height: 2) } }
                .contentShape(Rectangle())
        }.buttonStyle(WBTextActionButtonStyle()).accessibilityLabel("\(title)，\(count) 项")
            .accessibilityValue(active ? "当前分类" : "切换查看")
    }
    private var tableHeader: some View {
        HStack(spacing: columnGap) {
            let ids = model.visibleSelectableIDs
            let all = !ids.isEmpty && ids.isSubset(of: model.selectedIDs)
            let mixed = !all && !ids.isDisjoint(with: model.selectedIDs)
            SpaceCleaningSelectionControl(selected: all, mixed: mixed, label: "选择当前显示的可处理项目", action: model.toggleVisibleSelection)
                .disabled(ids.isEmpty || model.isBusy || model.requiresRescan || confirming)
                .accessibilityIdentifier("space-cleaning-select-visible")
            HStack(spacing: 14) {
                sortHeader("名称", key: .name)
                sortHeader("所在目录", key: .directory)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("类型", key: .type).frame(width: typeWidth, alignment: .leading)
            sortHeader("修改日期", key: .modified).frame(width: dateWidth, alignment: .leading)
            sortHeader("大小", key: .size, trailing: true).frame(width: sizeWidth, alignment: .trailing)
        }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.horizontal, 14).frame(height: 34)
            .background(palette.soft).overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }
    private func sortHeader(_ title: String, key: CleaningSortKey, trailing: Bool = false) -> some View {
        let active = model.sortKey == key
        return Button { model.sortResults(by: key) } label: {
            HStack(spacing: 5) {
                if trailing { Spacer(minLength: 0) }
                Text(title).fontWeight(active ? .medium : .regular)
                Image(systemName: active ? (model.sortAscending ? "chevron.up" : "chevron.down") : "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(active ? palette.accent : palette.muted)
                if !trailing { Spacer(minLength: 0) }
            }.frame(minHeight: 34).contentShape(Rectangle())
                .foregroundStyle(active ? palette.text : palette.muted)
        }.buttonStyle(WBTextActionButtonStyle()).disabled(model.isBusy || confirming)
            .accessibilityLabel("按" + title + "排序")
            .accessibilityValue(active ? (model.sortAscending ? "升序" : "降序") : "未排序")
            .accessibilityIdentifier("space-cleaning-sort-" + key.rawValue)
            .help("点击按" + title + "排序，再次点击切换升序或降序")
    }
    private func row(_ item: CleaningItemDisplay) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: columnGap) {
                if item.group == .protected {
                    if item.needsPurposeConfirmation {
                        Button { model.requestTestPurpose(item.id) } label: {
                            Image(systemName: "lock.open").font(.system(size: 13)).frame(width: 24, height: 24)
                        }.buttonStyle(WBIconButtonStyle(size: 24)).foregroundStyle(palette.accent)
                            .disabled(model.isBusy || model.requiresRescan || confirming)
                            .help("确认测试用途后可手动选择")
                            .accessibilityLabel("确认测试用途：" + item.name)
                            .accessibilityIdentifier("space-cleaning-unlock-" + item.id.uuidString)
                    } else {
                        Image(systemName: "lock").font(.system(size: 13)).foregroundStyle(palette.muted).frame(width: 24, height: 24)
                            .help(item.reason)
                    }
                } else {
                    SpaceCleaningSelectionControl(selected: model.selectedIDs.contains(item.id), label: "选择 \(item.name)") { model.toggleItem(item.id) }
                        .disabled(!item.isSelectable || model.isBusy || model.requiresRescan || confirming)
                        .accessibilityIdentifier("space-cleaning-select-" + item.id.uuidString)
                }
                Button { model.showDetail(item.id) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: item.isDirectory ? "folder" : "doc").foregroundStyle(palette.muted)
                            Text(item.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                            if item.needsSuggestionReview {
                                Text("手动选择").font(.system(size: 10)).foregroundStyle(palette.warning)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Capsule().fill(palette.warning.opacity(0.12))).fixedSize()
                            }
                            if let status = item.protectionTitle {
                                Text(status).font(.system(size: 10)).foregroundStyle(item.needsPurposeConfirmation ? palette.accent : palette.muted)
                                    .fixedSize()
                            }
                            Image(systemName: model.detailID == item.id ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(palette.muted)
                        }.font(.system(size: 12))
                        Text(model.shortPath(item.url.deletingLastPathComponent()))
                            .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 4, drawsSelection: false, showsBorder: false)).disabled(model.isBusy || confirming)
                Text(item.typeTitle).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .lineLimit(2).frame(width: typeWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.modifiedDate, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                    Text(item.modifiedDate, format: .dateTime.hour().minute()).foregroundStyle(palette.muted)
                }.font(.system(size: 11)).monospacedDigit().frame(width: dateWidth, alignment: .leading)
                Text((item.sizeIsComplete ? "" : "至少 ") + SpaceCleaningFormat.bytes(item.bytes))
                    .font(.system(size: 12)).monospacedDigit().lineLimit(2).frame(width: sizeWidth, alignment: .trailing)
            }.padding(.horizontal, 14).frame(height: 68).background(model.detailID == item.id ? palette.soft : .clear)
            if model.detailID == item.id { detail(item) }
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }
    private var emptyResults: some View {
        VStack(spacing: 12) {
            Image(systemName: model.searchText.isEmpty ? "checkmark.circle" : "magnifyingglass").font(.system(size: 26, weight: .light)).foregroundStyle(palette.accent)
            Text(!model.searchText.isEmpty ? "没有匹配的项目" : model.onlySelected ? "还没有选择文件" : model.resultTab == .recommended ? "暂未发现建议整理的内容" : "这个分类没有项目")
                .font(.system(size: 14, weight: .medium))
            if model.resultTab == .recommended && model.searchText.isEmpty && !model.onlySelected {
                Text(model.noRecommendationsSummary).font(.system(size: 11)).foregroundStyle(palette.muted).multilineTextAlignment(.center).frame(maxWidth: 430)
                if !model.otherItems.isEmpty { Button("查看其他文件") { model.showResults(.reviewable) }.buttonStyle(WBButtonStyle()) }
            } else if model.onlySelected { Button("返回建议清理") { model.showResults(.recommended) }.buttonStyle(WBQuietButtonStyle()) }
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 40)
    }
    private func detail(_ item: CleaningItemDisplay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = item.handlingNote {
                Label { Text(note).lineSpacing(4) } icon: { Image(systemName: item.group == .protected ? "lock.shield" : "info.circle") }
                    .font(.system(size: 11)).foregroundStyle(item.group == .protected ? palette.secondary : palette.accent)
            }
            if let guidance = item.protectionGuidance {
                Text(guidance).font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.dialog == .purpose(item.id) {
                Rectangle().fill(palette.line).frame(height: 1)
                Toggle("我确认它仅用于测试，不是发布原件或唯一保留归档", isOn: $model.acknowledgement)
                    .toggleStyle(.checkbox).font(.system(size: 11)).clickableCursor().disabled(model.isBusy)
                    .accessibilityIdentifier("space-cleaning-test-purpose-acknowledgement")
                HStack {
                    Text("仅核验这一项，确认后可手动选择。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                    Spacer(minLength: 8)
                    Button("取消", action: model.closeDialog).buttonStyle(WBButtonStyle()).disabled(model.isBusy)
                    Button(model.purposeReviewID == item.id ? "正在核验…" : "确认测试用途") { model.confirmTestPurpose(item.id) }
                        .buttonStyle(WBButtonStyle(primary: true)).disabled(!model.acknowledgement || model.isBusy)
                        .accessibilityIdentifier("space-cleaning-confirm-test-purpose")
                }
            }
            Text(item.url.path).font(.system(size: 11)).foregroundStyle(palette.muted).textSelection(.enabled)
            HStack(spacing: 8) {
                Button("快速预览") { model.preview(item.id) }.buttonStyle(WBButtonStyle(compact: true))
                Button("在 Finder 中查看") { model.reveal(item.id) }.buttonStyle(WBButtonStyle(compact: true))
                Spacer()
                if item.needsPurposeConfirmation && model.dialog != .purpose(item.id) {
                    Button("确认测试用途") { model.requestTestPurpose(item.id) }.buttonStyle(WBButtonStyle()).disabled(model.requiresRescan || model.isBusy)
                }
            }
        }.padding(EdgeInsets(top: 12, leading: 50, bottom: 14, trailing: 14)).background(palette.soft)
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-file-detail")
    }
    private var selectionFooter: some View {
        VStack(spacing: 0) {
            if confirming { permanentConfirmation }
            else { selectionActions }
        }.background(WorkbenchMaterialSurface(radius: 15))
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-selection-footer")
    }
    private var selectionActions: some View {
        Group {
            if availableWidth >= 800 {
                HStack(spacing: 16) {
                    selectionSummary.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    methodActions.fixedSize(horizontal: true, vertical: false)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    selectionSummary.frame(maxWidth: .infinity, alignment: .leading)
                    methodActions
                }
            }
        }.padding(14)
    }
    private var methodActions: some View {
        HStack(spacing: 12) {
            methodSelector
            rememberMethodToggle
            Spacer(minLength: 0)
            cleanupButton
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-method-actions")
    }
    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(model.selectedCount == 0 ? "尚未选择文件" : "已选 \(model.selectedCount) 项 · \(SpaceCleaningFormat.bytes(model.selectedBytes))")
                    .font(.system(size: 12, weight: .medium))
                if model.selectedCount > 0 {
                    Button(model.onlySelected ? "返回分类" : "查看已选") { model.toggleSelectedFilter() }
                        .buttonStyle(WBTextActionButtonStyle()).font(.system(size: 11)).foregroundStyle(palette.accent)
                        .disabled(model.isBusy || confirming)
                    Button("取消选择", action: model.clearSelection)
                        .buttonStyle(WBTextActionButtonStyle()).font(.system(size: 11)).foregroundStyle(palette.muted)
                        .disabled(model.isBusy || confirming)
                }
            }
            Text(model.method == .trash ? "移入废纸篓，可从清理记录恢复" : "永久删除将释放占用，无法恢复")
                .font(.system(size: 11)).foregroundStyle(model.method == .trash ? palette.muted : palette.warning)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var methodSelector: some View {
        HStack(spacing: 2) {
            methodOption(.trash, title: "移入废纸篓", icon: "trash")
            methodOption(.permanent, title: "永久删除", icon: "trash.slash")
        }.padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line))
            .fixedSize().disabled(model.isBusy || confirming)
            .accessibilityElement(children: .contain).accessibilityLabel("清理方式")
    }
    private func methodOption(_ method: SpaceCleaningMethod, title: String, icon: String) -> some View {
        let selected = model.method == method
        let color = method == .permanent ? palette.warning : palette.accent
        return Button { model.chooseMethod(method) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 11, weight: selected ? .medium : .regular))
            }.foregroundStyle(selected ? color : palette.secondary)
                .padding(.horizontal, 10).frame(width: 106, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(WBSelectableButtonStyle(selected: selected, cornerRadius: 6, tint: color))
            .accessibilityValue(selected ? "已选择" : "未选择")
            .accessibilityIdentifier(method == .trash ? "space-cleaning-method-trash" : "space-cleaning-method-permanent")
    }
    private var rememberMethodToggle: some View {
        Toggle("记住处理方式", isOn: Binding(get: { model.rememberMethod }, set: model.setRememberMethod))
            .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(palette.secondary)
            .fixedSize().clickableCursor().disabled(model.isBusy || confirming)
            .accessibilityIdentifier("space-cleaning-remember-method")
    }
    private var cleanupButton: some View {
        // Reserve the longest caption at the current result-count capacity.
        // Selection changes and switching deletion methods keep the whole
        // action group anchored, including its method and remember controls.
        let labelWidth = max(110, CGFloat(String(max(1, model.items.count)).count) * 8 + 70) * displayScale
        return Button(action: model.requestCleanup) {
            Text(model.method == .trash ? "清理 \(model.selectedCount) 项" : "永久删除 \(model.selectedCount) 项")
                .monospacedDigit().lineLimit(1).frame(width: labelWidth, alignment: .center)
        }.buttonStyle(WBButtonStyle(primary: model.method == .trash, destructive: model.method == .permanent))
            .fixedSize().disabled(!model.canProcess).accessibilityIdentifier("space-cleaning-cleanup")
    }
    private var permanentConfirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("永久删除这 \(model.selectedCount) 项？", systemImage: "trash.slash").font(.system(size: 14, weight: .medium))
                Spacer()
                Text(SpaceCleaningFormat.bytes(model.selectedBytes)).font(.system(size: 14)).monospacedDigit()
            }
            Text("这些文件不会进入废纸篓，清理记录只能保留操作信息，无法恢复文件。")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            HStack {
                Toggle("我理解永久删除无法恢复", isOn: $model.acknowledgement)
                    .toggleStyle(.checkbox).font(.system(size: 11)).clickableCursor()
                    .accessibilityIdentifier("space-cleaning-permanent-acknowledgement")
                Spacer()
                Button("取消", action: model.closeDialog).buttonStyle(WBButtonStyle())
                Button("确认永久删除") { model.executeConfirmed(permanent: true, remember: model.rememberMethod) }
                    .buttonStyle(WBButtonStyle(destructive: true)).disabled(!model.canProcess || !model.acknowledgement)
                    .accessibilityIdentifier("space-cleaning-confirm-execute")
            }
        }.padding(14)
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-confirmation")
    }
}

/// Header and rows share the exact hit area and glyph geometry, including the
/// mixed selection state. This avoids platform checkbox insets shifting a column.
struct SpaceCleaningSelectionControl: View {
    let selected: Bool
    var mixed = false
    let label: String
    let action: () -> Void
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            Image(systemName: selected ? "checkmark.square.fill" : mixed ? "minus.square.fill" : "square")
                .font(.system(size: 16)).foregroundStyle(selected || mixed ? palette.accent : palette.muted)
                .opacity(isEnabled ? 1 : 0.45).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(ClickablePlainButtonStyle()).accessibilityLabel(label)
            .accessibilityValue(selected ? "已选择" : mixed ? "部分选择" : "未选择")
    }
}
