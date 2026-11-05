import SwiftUI
import LauncherCore

struct SpaceCleaningResultsView: View {
    @ObservedObject var model: SpaceCleaningModel
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.timeZone) private var timeZone
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private let columnGap: CGFloat = 12
    private let typeWidth: CGFloat = 86
    private let dateWidth: CGFloat = 110
    private let sizeWidth: CGFloat = 112
    private let methodSelectorWidth: CGFloat = 136
    private let rememberMethodWidth: CGFloat = 104
    private var confirming: Bool { model.dialog == .confirm }
    @State private var availableWidth: CGFloat = 864

    // Reserve for the full result set, so selecting items and switching
    // methods never changes the width of the trailing action group.
    private var cleanupButtonWidth: CGFloat {
        max(144, 104 + CGFloat(String(max(1, model.items.count)).count) * 8)
    }
    private var methodActionsWidth: CGFloat {
        methodSelectorWidth + rememberMethodWidth + cleanupButtonWidth + 24
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                SpaceCleaningSurface(fillHeight: false) { summary }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("space-cleaning-result-summary")
                workspace(width: geometry.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                selectionFooter.fixedSize(horizontal: false, vertical: true)
            }.onAppear { availableWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in availableWidth = width }
                .animation(systemReduceMotion || model.reduceMotion ? nil : .easeInOut(duration: 0.24), value: model.detailID != nil)
        }
    }
    @ViewBuilder private func workspace(width: CGFloat) -> some View {
        if width < 700, let item = model.detail {
            WorkbenchScrollView {
                VStack(spacing: 12) {
                    resultList(width: width).frame(height: 320)
                    detailSidebar(item).frame(height: 400)
                }
            }.scrollBounceBehavior(.basedOnSize)
        } else {
            HStack(alignment: .top, spacing: model.detail == nil ? 0 : 12) {
                resultList(width: width - (model.detail == nil ? 0 : 298))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let item = model.detail {
                    detailSidebar(item).frame(width: 286)
                        .transition(.opacity)
                }
            }
        }
    }
    private func resultList(width: CGFloat) -> some View {
        SpaceCleaningSurface {
            controls(width: width)
            tableHeader(showsMetadata: width >= 740)
            SpaceCleaningResultScrollView(resetID: model.resultScrollResetID, requestedID: model.resultScrollID, updating: model.isUpdatingResults) {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleItems) { item in row(item, showsMetadata: width >= 740).id(item.id) }
                    if model.isUpdatingResults {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在整理结果…").font(.system(size: 12)).foregroundStyle(palette.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                            .accessibilityIdentifier("space-cleaning-results-updating")
                    } else if model.visibleItems.isEmpty { emptyResults }
                }
            }.scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("space-cleaning-result-list")
            HStack(spacing: 8) {
                Text(model.onlySelected ? "仅显示已选项目" : model.resultTab == .protected ? "这些项目保持保留" : "点击项目查看详情")
                    .lineLimit(1)
                Spacer(minLength: 4)
                if model.resultTab == .protected && model.summarizedProtectedCount > 0 && !model.onlySelected {
                    // Summarized links and small protected entries stay visible in the scope notes.
                    Button("另有 \(model.summarizedProtectedCount) 项已汇总") { model.dialog = .issues }
                        .buttonStyle(WBTextActionButtonStyle())
                        .help("符号链接等不可处理的小型保护项目按目录汇总在范围说明中")
                        .accessibilityIdentifier("space-cleaning-summarized-protection")
                        .fixedSize()
                }
                if !model.coverageIssues.isEmpty {
                    Button("\(model.coverageIssues.count) 处未完整覆盖") { model.dialog = .issues }
                        .buttonStyle(WBTextActionButtonStyle()).foregroundStyle(palette.warning)
                        .fixedSize()
                }
                Text("\(model.visibleItems.count) 项").fixedSize()
            }.font(.system(size: 11)).foregroundStyle(palette.muted).padding(.horizontal, 14).frame(height: 34)
                .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-results-surface")
    }
    private var summary: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.scanMode == .largeFiles ? "大文件扫描结果" : "扫描结果").font(.system(size: 12, weight: .semibold))
                Text(model.reportSummary).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(SpaceCleaningFormat.bytes(model.scanMode == .largeFiles ? model.reviewableAllocatedBytes : model.recommendedAllocatedBytes))
                    .font(.system(size: 24, weight: .medium)).monospacedDigit()
                Text(model.scanMode == .largeFiles ? "这些文件的磁盘占用" : "建议项目磁盘占用").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }.padding(14)
    }
    private func controls(width: CGFloat) -> some View {
        Group {
            if width >= 740 {
                HStack(spacing: 18) {
                    resultTabs
                    Spacer(minLength: 0)
                    searchField.frame(width: min(260, max(196, width * 0.26)))
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    resultTabs
                    HStack(spacing: 8) {
                        searchField
                        compactSorting
                    }
                }
            }
        }.padding(14).fixedSize(horizontal: false, vertical: true)
    }
    private var resultTabs: some View {
        HStack(spacing: 18) {
            if model.scanMode == .cleanup { tab("建议清理", count: model.recommendedItems.count, value: .recommended) }
            tab(model.scanMode == .largeFiles ? "符合范围的文件" : "其他文件", count: model.otherItems.count, value: .reviewable)
            if !model.protectedItems.isEmpty { tab("已保护", count: model.protectedItems.count, value: .protected) }
        }
    }
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
            TextField("搜索名称或目录", text: $model.searchText).textFieldStyle(.plain)
                .disabled(model.isBusy || confirming)
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(WBIconButtonStyle(size: 24)).accessibilityLabel("清除搜索")
                    .disabled(model.isBusy || confirming)
            }
        }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-search")
    }
    private var compactSorting: some View {
        HStack(spacing: 4) {
            WBSelect("排序", selection: Binding(get: { model.sortKey }, set: model.sortResults), options: [
                (.name, "名称"), (.directory, "所在目录"), (.type, "类型"), (.modified, "修改日期"), (.size, "文件大小")
            ]).frame(width: 112, height: 32).accessibilityLabel("排序依据")
                .accessibilityIdentifier("space-cleaning-sort-selector")
            Button { model.sortResults(by: model.sortKey) } label: {
                Image(systemName: model.sortAscending ? "arrow.up" : "arrow.down")
            }.buttonStyle(WBIconButtonStyle(size: 28))
                .help(model.sortAscending ? "当前升序，点击改为降序" : "当前降序，点击改为升序")
                .accessibilityLabel("切换排序方向").accessibilityValue(model.sortAscending ? "升序" : "降序")
                .accessibilityIdentifier("space-cleaning-sort-direction")
        }.disabled(model.isBusy || confirming)
    }
    private func tab(_ title: String, count: Int, value: CleaningResultTab) -> some View {
        let active = model.resultTab == value && !model.onlySelected
        return Button { model.showResults(value) } label: {
            HStack(spacing: 6) {
                Text(title).fontWeight(active ? .semibold : .regular)
                Text(count.formatted()).font(.system(size: 10)).monospacedDigit().foregroundStyle(palette.muted)
            }.font(.system(size: 12)).foregroundStyle(active ? palette.text : palette.muted).frame(height: 28)
                .overlay(alignment: .bottom) { if active { Capsule().fill(palette.accent).frame(height: 2) } }
                .contentShape(Rectangle())
        }.buttonStyle(WBTextActionButtonStyle()).accessibilityLabel("\(title)，\(count) 项")
            .accessibilityValue(active ? "当前分类" : "切换查看")
    }
    private func tableHeader(showsMetadata: Bool) -> some View {
        HStack(spacing: columnGap) {
            let all = model.allVisibleSelected
            let mixed = model.someVisibleSelected && !all
            SpaceCleaningSelectionControl(selected: all, mixed: mixed, label: "选择当前显示的可处理项目", action: model.toggleVisibleSelection)
                .disabled(model.visibleSelectableCount == 0 || model.isUpdatingResults || model.isBusy || model.requiresRescan || confirming)
                .accessibilityIdentifier("space-cleaning-select-visible")
            HStack(spacing: 14) {
                sortHeader("名称", key: .name).fixedSize(horizontal: true, vertical: false)
                sortHeader("所在目录", key: .directory).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if showsMetadata {
                sortHeader("类型", key: .type).frame(width: typeWidth, alignment: .leading)
                sortHeader("修改日期", key: .modified).frame(width: dateWidth, alignment: .leading)
            }
            sortHeader("文件大小", key: .size, trailing: true).frame(width: sizeWidth, alignment: .trailing)
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
    private func row(_ item: CleaningItemDisplay, showsMetadata: Bool) -> some View {
        let measured = model.directorySizes[item.id]
        return VStack(spacing: 0) {
            SpaceCleaningResultRowSurface(expanded: model.detailID == item.id, enabled: !model.isBusy && !confirming) {
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
                    HStack(spacing: columnGap) {
                        HStack(spacing: 10) {
                            SpaceCleaningFileGlyph(category: item.fileCategory)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    if model.needsManualSelection(item) { manualSelectionTag(item) }
                                }
                                Text(model.shortPath(item.url.deletingLastPathComponent()))
                                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if showsMetadata {
                            Text(item.typeTitle).font(.system(size: 11)).foregroundStyle(item.fileCategory.tint(palette: palette))
                                .lineLimit(2).frame(width: typeWidth, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(SpaceCleaningFormat.day(item.modifiedDate, timeZone: timeZone))
                                Text(SpaceCleaningFormat.time(item.modifiedDate, timeZone: timeZone)).foregroundStyle(palette.muted)
                            }.font(.system(size: 11)).monospacedDigit().frame(width: dateWidth, alignment: .leading)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("space-cleaning-file-date-" + item.id.uuidString)
                        }
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(logicalSizeText(item)).font(.system(size: 12))
                            if measured.map({ $0.complete || $0.checkedEntries > 0 }) == true || (measured == nil && (item.sizeIsComplete || item.allocatedBytes > 0)) {
                                Text("占用 " + SpaceCleaningFormat.bytes(measured?.allocatedBytes ?? item.allocatedBytes)).font(.system(size: 11)).foregroundStyle(palette.muted)
                            }
                        }.monospacedDigit().lineLimit(1).frame(width: sizeWidth, alignment: .trailing)
                    }.frame(maxWidth: .infinity, minHeight: 68, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(ClickablePlainButtonStyle()).disabled(model.isBusy || confirming)
                    .accessibilityIdentifier("space-cleaning-file-" + item.id.uuidString)
            }.padding(.horizontal, 14).frame(height: 68)
            }.accessibilityElement(children: .contain)
                .accessibilityIdentifier("space-cleaning-file-row-" + item.id.uuidString)
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }
    /// Suggestion rows that are never preselected (installers, disk images, old
    /// diagnostics) carry a light tag; it never truncates and keeps the row height.
    private func manualSelectionTag(_ item: CleaningItemDisplay) -> some View {
        Text("需手选").font(.system(size: 11)).foregroundStyle(palette.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(palette.soft, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.line, lineWidth: 1))
            .fixedSize().layoutPriority(1)
            .help("建议整理，但不会默认勾选；确认用途后再手动选择")
            .accessibilityLabel("需手动选择")
            .accessibilityIdentifier("space-cleaning-manual-tag-" + item.id.uuidString)
    }
    private func logicalSizeText(_ item: CleaningItemDisplay) -> String {
        if let measured = model.directorySizes[item.id] {
            return measured.checkedEntries == 0 && !measured.complete ? "大小未知" : (measured.complete ? "" : "部分 ") + SpaceCleaningFormat.bytes(measured.logicalBytes)
        }
        return !item.sizeIsComplete && item.bytes == 0 ? "未统计" : (item.sizeIsComplete ? "" : "至少 ") + SpaceCleaningFormat.bytes(item.bytes)
    }
    private func allocatedSizeText(_ item: CleaningItemDisplay) -> String {
        if let measured = model.directorySizes[item.id] {
            return measured.checkedEntries == 0 && !measured.complete ? "未统计" : (measured.complete ? "" : "部分 ") + SpaceCleaningFormat.bytes(measured.allocatedBytes)
        }
        return !item.sizeIsComplete && item.allocatedBytes == 0 ? "未统计" : (item.sizeIsComplete ? "" : "至少 ") + SpaceCleaningFormat.bytes(item.allocatedBytes)
    }
    private var emptyResults: some View {
        VStack(spacing: 12) {
            Image(systemName: model.searchText.isEmpty ? "checkmark.circle" : "magnifyingglass").font(.system(size: 26, weight: .light)).foregroundStyle(palette.accent)
            Text(!model.searchText.isEmpty ? "没有匹配的项目" : model.onlySelected ? "还没有选择文件" : model.scanMode == .largeFiles && model.resultTab == .reviewable ? "未找到符合大小范围的文件" : model.resultTab == .recommended ? "暂未发现建议整理的内容" : "这个分类没有项目")
                .font(.system(size: 14, weight: .medium))
            if (model.resultTab == .recommended || model.scanMode == .largeFiles && model.resultTab == .reviewable) && model.searchText.isEmpty && !model.onlySelected {
                Text(model.noRecommendationsSummary).font(.system(size: 11)).foregroundStyle(palette.muted).multilineTextAlignment(.center).frame(maxWidth: 430)
                if !model.otherItems.isEmpty { Button("查看其他文件") { model.showResults(.reviewable) }.buttonStyle(WBButtonStyle()) }
            } else if model.onlySelected { Button("返回文件列表") { model.showResults(model.scanMode == .largeFiles ? .reviewable : .recommended) }.buttonStyle(WBQuietButtonStyle()) }
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 40)
    }
    private func detailSidebar(_ item: CleaningItemDisplay) -> some View {
        SpaceCleaningSurface {
            HStack(spacing: 8) {
                Text("项目详情").font(.system(size: 12)).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                Button(action: model.closeDetail) {
                    Image(systemName: "sidebar.right").font(.system(size: 13, weight: .regular))
                }.buttonStyle(WBIconButtonStyle(size: 24))
                    .disabled(model.isBusy)
                    .help("折叠项目详情")
                    .accessibilityLabel("折叠项目详情")
                    .accessibilityIdentifier("space-cleaning-collapse-detail")
            }.padding(.leading, 14).padding(.trailing, 8).frame(height: 44)
                .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-detail-header")
            Rectangle().fill(palette.line).frame(height: 1)
            // The scroll viewport spans the card. Only its document is inset,
            // keeping the scrollbar at the outer edge and actions stationary.
            ScrollViewReader { proxy in
                WorkbenchScrollView {
                    detailContents(item).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).padding(14)
                }.scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("space-cleaning-detail-scroll")
                    .task(id: model.dialog == .purpose(item.id)) {
                        guard model.dialog == .purpose(item.id) else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo("space-cleaning-purpose", anchor: .bottom)
                    }
            }.id(item.id)
            Rectangle().fill(palette.line).frame(height: 1)
            HStack(spacing: 8) {
                Button { model.preview(item.id) } label: {
                    Label("快速预览", systemImage: "eye").frame(maxWidth: .infinity)
                }.buttonStyle(WBButtonStyle(compact: true))
                    .accessibilityIdentifier("space-cleaning-detail-preview")
                Button { model.reveal(item.id) } label: {
                    Label("Finder", systemImage: "folder").frame(maxWidth: .infinity)
                }.buttonStyle(WBButtonStyle(compact: true)).help("在 Finder 中查看")
                    .accessibilityLabel("在 Finder 中查看")
                    .accessibilityIdentifier("space-cleaning-detail-finder")
            }.disabled(model.isBusy || confirming).padding(.horizontal, 14).padding(.vertical, 12)
                .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-detail-actions")
        }.environment(\.workbenchScale, 1)
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-detail-surface")
    }
    private func detailContents(_ item: CleaningItemDisplay) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SpaceCleaningFileGlyph(category: item.fileCategory)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
                    Text(item.typeTitle).font(.system(size: 11)).foregroundStyle(palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(item.url.path).font(.system(size: 11)).foregroundStyle(palette.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                detailFact("文件大小", value: logicalSizeText(item))
                detailFact("磁盘占用", value: allocatedSizeText(item))
                detailFact("修改时间", value: SpaceCleaningFormat.day(item.modifiedDate, timeZone: timeZone) + "\n" + SpaceCleaningFormat.time(item.modifiedDate, timeZone: timeZone))
                detailFact("显示时区", value: WorkbenchContextModel.zoneTitle(timeZone.identifier, at: item.modifiedDate))
            }.padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
            if let note = item.handlingNote {
                VStack(alignment: .leading, spacing: 7) {
                    Label(item.protectionTitle ?? (item.group == .rebuildable ? "可重建缓存" : "处理前请复核"), systemImage: item.group == .protected ? "lock.shield" : "info.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(item.group == .protected ? palette.secondary : palette.accent)
                    Text(note).font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let guidance = item.protectionGuidance {
                        Text(guidance).font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(palette.soft, in: RoundedRectangle(cornerRadius: 8))
            }
            if item.kind == .developmentEnvironment && item.isDirectory { directorySizeAnalysis(item) }
            if model.dialog == .purpose(item.id) {
                purposeConfirmation(item).id("space-cleaning-purpose")
            } else if item.needsPurposeConfirmation {
                Button("确认测试用途") { model.requestTestPurpose(item.id) }.buttonStyle(WBButtonStyle())
                    .disabled(model.requiresRescan || model.isBusy || confirming)
            }
            Text("文件大小与磁盘占用可能不同；稀疏、压缩或共享数据会影响实际释放量，以处理后系统可用空间为准。")
                .font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-file-detail")
    }
    private func detailFact(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(palette.muted).fixedSize()
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit().textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).accessibilityElement(children: .combine)
    }
    private func purposeConfirmation(_ item: CleaningItemDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("我确认它仅用于测试，不是发布原件或唯一保留归档", isOn: $model.acknowledgement)
                .toggleStyle(.checkbox).font(.system(size: 11)).clickableCursor().disabled(model.isBusy)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("space-cleaning-test-purpose-acknowledgement")
            Text("仅核验这一项，确认后可手动选择。")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
            HStack(spacing: 8) {
                Button("取消", action: model.closeDialog).buttonStyle(WBButtonStyle(compact: true)).disabled(model.isBusy)
                Spacer(minLength: 0)
                Button(model.purposeReviewID == item.id ? "正在核验…" : "确认测试用途") { model.confirmTestPurpose(item.id) }
                    .buttonStyle(WBButtonStyle(primary: true, compact: true)).disabled(!model.acknowledgement || model.isBusy)
                    .accessibilityIdentifier("space-cleaning-confirm-test-purpose")
            }
        }
    }
    private func directorySizeAnalysis(_ item: CleaningItemDisplay) -> some View {
        let active = model.measuringDirectoryID == item.id
        let measured = model.directorySizes[item.id]
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if active {
                    Text("正在统计 · 已检查 \(measured?.checkedEntries ?? 0) 项").font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Button("停止统计", action: model.cancelDirectorySize).buttonStyle(WBButtonStyle(compact: true))
                        .accessibilityIdentifier("space-cleaning-cancel-size")
                } else {
                    Text(measured.map { $0.complete ? "统计完成 · 保持保护" : $0.checkedEntries == 0 ? "容量未知 · 保持保护" : "部分统计 · 保持保护" } ?? "仅查看容量，不改变清理保护")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Button(measured == nil ? "仅统计占用" : "重新统计占用") { model.measureDirectorySize(item.id) }
                        .buttonStyle(WBButtonStyle(compact: true)).disabled(model.isBusy || model.requiresRescan)
                        .accessibilityIdentifier("space-cleaning-measure-size-" + item.id.uuidString)
                }
            }
            if let measured, measured.complete || measured.checkedEntries > 0 {
                Text("\(measured.complete ? "" : "已读取部分：")文件大小 \(SpaceCleaningFormat.bytes(measured.logicalBytes)) · 磁盘占用 \(SpaceCleaningFormat.bytes(measured.allocatedBytes))")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            if let reason = measured?.reason { Text(reason).font(.system(size: 11)).foregroundStyle(palette.muted) }
            Text("只读取文件信息，不跟随链接或下载云端内容；最多检查 10 万项、32 层。统计容量不代表可释放空间。")
                .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-directory-size")
    }
    private var selectionFooter: some View {
        VStack(spacing: 0) {
            if confirming { permanentConfirmation }
            else { selectionActions }
        }.background(WorkbenchMaterialSurface(radius: 15))
            .environment(\.workbenchScale, 1)
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-selection-footer")
    }
    private var selectionActions: some View {
        Group {
            if availableWidth >= methodActionsWidth + 236 + 16 + 28 {
                HStack(spacing: 16) {
                    selectionSummary.frame(maxWidth: .infinity, alignment: .leading)
                    methodActions
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    selectionSummary.frame(maxWidth: .infinity, alignment: .leading)
                    methodActions.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }.padding(14)
    }
    private var methodActions: some View {
        Group {
            if availableWidth >= methodActionsWidth + 28 {
                HStack(spacing: 12) {
                    methodSelector
                    rememberMethodToggle
                    cleanupButton
                }.frame(width: methodActionsWidth, height: 32)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        methodSelector
                        Spacer(minLength: 0)
                        cleanupButton
                    }
                    rememberMethodToggle
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-method-actions")
    }
    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.selectedCount == 0 ? "尚未选择文件" : "已选 \(model.selectedCount) 项 · 占用 \(SpaceCleaningFormat.bytes(model.selectedAllocatedBytes))")
                .font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1)
            HStack(spacing: 8) {
                Text(model.method == .permanent ? "永久删除无法恢复" : model.selectedSimulatorCount > 0 ? "模拟器无法恢复" : "废纸篓内可恢复")
                    .font(.system(size: 11)).foregroundStyle(model.method == .trash && model.selectedSimulatorCount == 0 ? palette.muted : palette.warning)
                    .frame(width: 110, alignment: .leading)
                HStack(spacing: 10) {
                    Button(model.onlySelected ? "返回分类" : "查看已选") { model.toggleSelectedFilter() }
                        .buttonStyle(WBTextActionButtonStyle()).font(.system(size: 11)).foregroundStyle(palette.accent)
                        .disabled(model.isBusy || confirming)
                        .accessibilityIdentifier("space-cleaning-view-selected")
                    Button("取消选择", action: model.clearSelection)
                        .buttonStyle(WBTextActionButtonStyle()).font(.system(size: 11)).foregroundStyle(palette.muted)
                        .disabled(model.isBusy || confirming)
                        .accessibilityIdentifier("space-cleaning-clear-selection")
                }.fixedSize().opacity(model.selectedCount > 0 ? 1 : 0)
                    .disabled(model.selectedCount == 0)
                    .allowsHitTesting(model.selectedCount > 0)
                    .accessibilityHidden(model.selectedCount == 0)
            }
        }.fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-selection-summary")
    }
    private var methodSelector: some View {
        WBSelect("处理方式", selection: Binding(get: { model.method }, set: model.chooseMethod), options: [
            (.trash, "移入废纸篓"), (.permanent, "永久删除")
        ]).frame(width: methodSelectorWidth, height: 32).disabled(model.isBusy || confirming)
            .accessibilityLabel("处理方式")
            .accessibilityIdentifier("space-cleaning-method-selector")
    }
    private var rememberMethodToggle: some View {
        Toggle("记住处理方式", isOn: Binding(get: { model.rememberMethod }, set: model.setRememberMethod))
            .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(palette.secondary)
            .fixedSize().frame(width: rememberMethodWidth, alignment: .leading)
            .clickableCursor().disabled(model.isBusy || confirming)
            .accessibilityIdentifier("space-cleaning-remember-method")
    }
    private var cleanupButton: some View {
        Button(action: model.requestCleanup) {
            Text(model.method == .trash ? "移入废纸篓 \(model.selectedCount) 项" : "永久删除 \(model.selectedCount) 项")
                .monospacedDigit().lineLimit(1)
                .frame(width: cleanupButtonWidth - 22, alignment: .center)
        }.buttonStyle(WBButtonStyle(primary: model.method == .trash, destructive: model.method == .permanent))
            .fixedSize().disabled(!model.canProcess).accessibilityIdentifier("space-cleaning-cleanup")
    }
    /// Permanent deletion, or a Trash batch with simulators: those cannot reach
    /// the Trash and are deleted through Xcode.
    private var confirmationDetail: String {
        let simulators = model.selectedSimulatorCount, others = model.selectedCount - simulators
        if model.method == .permanent {
            return "这些文件不会进入废纸篓，清理记录只能保留操作信息，无法恢复文件。" +
                (simulators > 0 ? "其中 \(simulators) 台模拟器通过 Xcode 的 simctl 删除。" : "")
        }
        return (others > 0 ? "\(others) 项移入废纸篓，可以恢复；" : "") +
            "\(simulators) 台模拟器不能移入废纸篓，将通过 Xcode 的 simctl 直接删除，无法恢复。"
    }
    private var permanentConfirmation: some View {
        let permanent = model.method == .permanent
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(permanent ? "永久删除这 \(model.selectedCount) 项？" : "处理这 \(model.selectedCount) 项？", systemImage: "trash.slash")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Text("磁盘占用 " + SpaceCleaningFormat.bytes(model.selectedAllocatedBytes)).font(.system(size: 14)).monospacedDigit()
            }
            Text(confirmationDetail)
                .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle(permanent ? "我理解永久删除无法恢复" : "我理解模拟器删除后无法恢复", isOn: $model.acknowledgement)
                    .toggleStyle(.checkbox).font(.system(size: 11)).clickableCursor()
                    .accessibilityIdentifier("space-cleaning-permanent-acknowledgement")
                Spacer()
                Button("取消", action: model.closeDialog).buttonStyle(WBButtonStyle())
                Button(permanent ? "确认永久删除" : "确认处理") { model.executeConfirmed(permanent: permanent, remember: model.rememberMethod) }
                    .buttonStyle(WBButtonStyle(destructive: true)).disabled(!model.canProcess || !model.acknowledgement)
                    .accessibilityIdentifier("space-cleaning-confirm-execute")
            }
        }.padding(14)
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-confirmation")
    }
}

/// The scroll anchor is local to the scrolling surface. Tracking a visible row
/// must not publish a change to the cleaning model or rebuild the whole page.
private struct SpaceCleaningResultScrollView<Content: View>: View {
    let resetID: UUID
    let requestedID: UUID?
    let updating: Bool
    @ViewBuilder let content: Content
    @State private var scrollID: UUID?
    @State private var pendingID: UUID?
    var body: some View {
        WorkbenchScrollView { content.scrollTargetLayout() }
            .scrollPosition(id: $scrollID, anchor: .top)
            .onAppear { applyScrollRequest() }
            .onChange(of: resetID) { _, _ in applyScrollRequest() }
            .onChange(of: updating) { _, active in
                if !active, let pendingID { scrollID = pendingID; self.pendingID = nil }
            }
    }
    private func applyScrollRequest() {
        if updating, let requestedID { pendingID = requestedID }
        else { pendingID = nil; scrollID = requestedID }
    }
}

/// One faint row surface replaces the name column's truncated selection fill.
/// Its hover state is isolated from the result collection and model.
private struct SpaceCleaningResultRowSurface<Content: View>: View {
    let expanded: Bool
    let enabled: Bool
    @ViewBuilder let content: Content
    @Environment(\.workbenchPalette) private var palette
    @State private var hovering = false
    var body: some View {
        content.background(expanded ? palette.soft : hovering && enabled ? palette.text.opacity(0.035) : .clear)
            .onHover { hovering = $0 }
    }
}

struct SpaceCleaningFileGlyph: View {
    let category: CleaningFileCategory
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        Image(systemName: category.symbol).font(.system(size: 15, weight: .regular))
            .foregroundStyle(category.tint(palette: palette))
            .frame(width: 24, height: 28)
            .background(category.tint(palette: palette).opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
    }
}

private extension CleaningFileCategory {
    func tint(palette: ThemePalette) -> Color {
        switch self {
        case .folder: palette.accent
        case .diskImage: Color(nsColor: .systemBlue)
        case .application, .xcodeArchive, .simulator: Color(nsColor: .systemIndigo)
        case .installer, .archive: Color(nsColor: .systemOrange)
        case .pdf: Color(nsColor: .systemRed)
        case .document: Color(nsColor: .systemBlue)
        case .image: Color(nsColor: .systemPurple)
        case .video: Color(nsColor: .systemPink)
        case .audio: Color(nsColor: .systemTeal)
        case .code: Color(nsColor: .systemGreen)
        case .file: palette.secondary
        }
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
