import SwiftUI
import LauncherCore

/// The approved preparation layout uses the existing scanner and source data.
struct SpaceCleaningHomeView: View {
    @ObservedObject var model: SpaceCleaningModel
    let width: CGFloat
    let height: CGFloat
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.timeZone) private var timeZone
    @State private var activeRange: CleaningScopeGroup = .downloads

    private var editingScope: Bool { model.screen == .scope }
    private var scope: CleaningScopeChoice { editingScope ? model.draftScope : model.scopeChoice }
    private var locations: [URL] { editingScope ? model.draftDirectories : model.customDirectories }
    private var hasPreviousResults: Bool { !model.items.isEmpty && !editingScope }
    private var chosenGroups: Set<CleaningScopeGroup> { editingScope ? model.draftScopeGroups : model.selectedScopeGroups }
    private var selectedRangeCount: Int { scope == .global ? CleaningScopeGroup.allCases.count : chosenGroups.count + locations.count }
    private var scopeIsEmpty: Bool { scope == .custom && chosenGroups.isEmpty && locations.isEmpty }
    private var columnHeight: CGFloat { max(420, height - (hasPreviousResults ? 132 : 0)) }
    private var compact: Bool { width >= 760 && columnHeight < 680 }
    private var denseOptions: Bool { compact && model.scanMode == .largeFiles }
    private var sectionSpacing: CGFloat { denseOptions ? 12 : min(32, max(18, (columnHeight - 480) * 0.08)) }
    private var leftWidth: CGFloat {
        let fraction: CGFloat = width >= 1152 ? 0.84 / 2.84 : width <= 802 ? 0.8 / 1.8 : 0.94 / 2.94
        return max(width >= 1152 ? 310 : 276, (width - 12) * fraction)
    }

    var body: some View {
        WorkbenchScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if width >= 760 {
                    HStack(alignment: .top, spacing: 12) {
                        volumeCard.frame(width: leftWidth, height: columnHeight)
                        configuration(width: max(0, width - leftWidth - 12))
                            .frame(maxWidth: .infinity).frame(height: columnHeight)
                    }
                } else {
                    volumeCard.frame(height: 680)
                    configuration(width: width)
                        .frame(height: max(680, height))
                }
                if hasPreviousResults { previousResults }
            }.frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-home-surface")
        }.scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("space-cleaning-home-scroll")
    }

    private var volumeCard: some View {
        SpaceCleaningCapacityCard(total: model.diskTotal, available: model.diskAvailable,
                                 immediatelyFree: model.diskImmediatelyFree, reclaimableEstimate: model.diskReclaimableEstimate,
                                 volumeName: model.diskVolumeName, updatedAt: model.diskUpdatedAt)
    }

    private func configuration(width: CGFloat) -> some View {
        let inset: CGFloat = compact ? 14 : 20
        let contentWidth = max(0, width - inset * 2)
        return SpaceCleaningSurface {
            GeometryReader { geometry in
                WorkbenchScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                            Text("扫描方式").font(.system(size: 13, weight: .medium))
                            modeChoices(width: contentWidth)
                            if model.scanMode == .largeFiles { largeFileControls }
                        }
                        scopeControls(width: contentWidth).padding(.top, sectionSpacing)
                        scopeDetails.padding(.top, sectionSpacing)
                        if scope == .custom { selectedLocations(width: contentWidth).padding(.top, sectionSpacing) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(minHeight: max(0, geometry.size.height - inset * 2), alignment: .topLeading)
                    .padding(inset)
                }.scrollBounceBehavior(.basedOnSize)
            }
            configurationActions.padding(.horizontal, inset).padding(.bottom, inset)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-configuration-card")
    }

    private func modeChoices(width: CGFloat) -> some View {
        let columns = width >= 440 ? 2 : 1
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            ForEach(SpaceCleaningScanMode.allCases, id: \.self) { mode in
                // Keep the card just clicked in place: large-file options open
                // below it and only the later sections tighten.
                SpaceCleaningModeChoice(mode: mode, selected: model.scanMode == mode,
                                        height: compact ? 78 : 92) { model.selectScanMode(mode) }
                    .disabled(model.isBusy || editingScope)
            }
        }
    }

    private func scopeControls(width: CGFloat) -> some View {
        let columns = width >= 650 ? 3 : width >= 440 ? 2 : 1
        let tileHeight: CGFloat = columns == 3
            ? (denseOptions ? 68 : min(132, max(82, 82 + (columnHeight - 545) * 0.16)))
            // Two-column compact tiles hold one title and a two-line summary; the
            // header and footer notes now sit on backings, so keep their height tight.
            : (denseOptions ? 52 : compact ? 56 : 82)
        return VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            ViewThatFits(in: .horizontal) {
                HStack { scopeHeading; Spacer(minLength: 8); scopeChoices }
                VStack(alignment: .leading, spacing: 8) { scopeHeading; scopeChoices }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 8) {
                ForEach(CleaningScopeGroup.allCases) { group in
                    SpaceCleaningScopeTile(group: group, active: activeRange == group, custom: scope == .custom,
                                           included: model.includesScopeGroup(group, draft: editingScope),
                                           height: tileHeight, stacked: columns == 3,
                                           open: { activeRange = group }, toggle: { toggleRange(group) })
                        .disabled(model.isBusy)
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-global-locations")
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier(editingScope ? "space-cleaning-scope-editor" : "space-cleaning-scope-options")
    }
    private var scopeHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("扫描范围").font(.system(size: 12, weight: .medium))
            Text("· \(selectedRangeCount) 项").font(.system(size: 11)).foregroundStyle(palette.muted)
        }
    }
    private var scopeChoices: some View {
        HStack(spacing: 10) {
            scopeButton("全部范围", selected: scope == .global, id: "global") {
                if editingScope { model.draftScope = .global } else { model.selectScope(.global) }
            }
            scopeButton("自选目录", selected: scope == .custom, id: "custom") {
                if editingScope { model.draftScope = .custom } else { model.editScope(custom: true) }
            }
        }
    }
    private func scopeButton(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13)).foregroundStyle(selected ? palette.accent : palette.secondary)
                Text(title).font(.system(size: 11))
            }.frame(height: 32).contentShape(Rectangle())
        }.buttonStyle(ClickablePlainButtonStyle()).disabled(model.isBusy)
            .accessibilityValue(selected ? "已选择" : "未选择")
            .accessibilityIdentifier("space-cleaning-scope-" + id)
    }
    private func toggleRange(_ group: CleaningScopeGroup) {
        if !editingScope { model.editScope(custom: true) }
        model.toggleDraftScopeGroup(group)
    }
    private var scopeDetails: some View {
        SpaceCleaningScopeDetail(group: activeRange,
                                 included: model.includesScopeGroup(activeRange, draft: editingScope),
                                 sizeDescription: model.scanMode == .largeFiles ? largeFileDescription : nil,
                                 compact: compact)
    }
    private var largeFileDescription: String {
        let minimum = model.minimumFileSize.isEmpty ? "100" : model.minimumFileSize
        let maximum = model.maximumFileSize.trimmingCharacters(in: .whitespacesAndNewlines)
        return maximum.isEmpty ? "按不小于 \(minimum) \(model.fileSizeUnit.rawValue) 筛选。" : "按 \(minimum)–\(maximum) \(model.fileSizeUnit.rawValue) 筛选。"
    }

    private func selectedLocations(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(locations.isEmpty ? "也可添加其他文件夹" : "另选 \(locations.count) 个文件夹")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer(minLength: 0)
                Button {
                    if !editingScope { model.editScope(custom: true) }
                    model.chooseCustomDirectory()
                } label: { Label("添加位置", systemImage: "plus") }
                    .buttonStyle(WBQuietButtonStyle()).accessibilityIdentifier("space-cleaning-manage-locations")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: width >= 470 ? 2 : 1), spacing: 8) {
                ForEach(locations, id: \.self) { location in
                    HStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 17)).foregroundStyle(palette.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(location.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Text(model.shortPath(location.deletingLastPathComponent())).font(.system(size: 11)).foregroundStyle(palette.muted)
                                .lineLimit(1).truncationMode(.middle)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            if !editingScope { model.editScope(custom: true) }
                            model.removeDraftDirectory(location)
                        } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                            .buttonStyle(WBIconButtonStyle(size: 24)).help("从扫描范围移除，不会删除文件")
                            .accessibilityLabel("移除扫描位置 " + location.lastPathComponent)
                    }.padding(10).frame(minHeight: 58).background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
                        .help(model.shortPath(location)).accessibilityElement(children: .contain)
                        .accessibilityIdentifier("space-cleaning-location-" + location.lastPathComponent)
                }
            }

        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-home-locations")
    }

    private var configurationActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { scanProtection; Spacer(minLength: 8); scanButtons }
            VStack(alignment: .leading, spacing: 10) { scanProtection; HStack { Spacer(minLength: 0); scanButtons } }
        }.padding(.top, 4).accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-home-actions")
    }
    private var scanProtection: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(scope == .global ? "扫描全部可访问范围" : "扫描 \(selectedRangeCount) 个已选范围").font(.system(size: 12, weight: .medium))
                Text("仅读取信息，扫描后再选择处理").foregroundStyle(palette.muted)
            }
        } icon: { Image(systemName: "checkmark.shield").foregroundStyle(palette.accent) }
            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
    }
    private var scanButtons: some View {
        HStack(spacing: 8) {
            if editingScope {
                Button("取消", action: model.cancelScope).buttonStyle(WBButtonStyle())
                    .accessibilityIdentifier("space-cleaning-cancel-scope")
                Button("保存范围", action: model.applyScope).buttonStyle(WBButtonStyle())
                    .disabled(!model.canApplyScope).accessibilityIdentifier("space-cleaning-apply-scope")
            }
            Button {
                if editingScope { model.applyScope() }
                model.startScan()
            } label: { Label("开始扫描", systemImage: "viewfinder") }
                .buttonStyle(WBButtonStyle(primary: true))
                .disabled(model.isBusy || model.largeFileRangeError != nil || scopeIsEmpty)
                .accessibilityIdentifier("space-cleaning-start")
        }
    }

    private var largeFileControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { largeFilePresets; largeFileRange }
                VStack(alignment: .leading, spacing: 8) { largeFilePresets; largeFileRange }
            }
            if let error = model.largeFileRangeError {
                Text(error).font(.system(size: 11)).foregroundStyle(palette.warning).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("space-cleaning-size-error")
            }
        }.disabled(model.isBusy || editingScope)
            .onChange(of: model.minimumFileSize) { _, _ in model.scanSettingsChanged() }
            .onChange(of: model.maximumFileSize) { _, _ in model.scanSettingsChanged() }
            .onChange(of: model.fileSizeUnit) { _, _ in model.scanSettingsChanged() }
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-large-file-options")
    }
    private var largeFilePresets: some View {
        HStack(spacing: 6) {
            ForEach(["100", "500"], id: \.self) { value in
                Button("≥ " + value + " MB") { model.setLargeFilePreset(value, unit: .mb) }
                    .buttonStyle(WBButtonStyle()).accessibilityIdentifier("space-cleaning-preset-" + value)
            }
            Button("≥ 1 GB") { model.setLargeFilePreset("1", unit: .gb) }
                .buttonStyle(WBButtonStyle()).accessibilityIdentifier("space-cleaning-preset-1gb")
        }.fixedSize()
    }
    private var largeFileRange: some View {
        HStack(spacing: 8) {
            Text("范围").font(.system(size: 11)).foregroundStyle(palette.secondary)
            sizeField("最小大小", value: $model.minimumFileSize).accessibilityIdentifier("space-cleaning-minimum-size")
            Text("—").font(.system(size: 11)).foregroundStyle(palette.muted)
            sizeField("不限", value: $model.maximumFileSize).accessibilityLabel("最大文件大小，留空表示不限")
                .accessibilityIdentifier("space-cleaning-maximum-size")
            WBSelect("文件大小单位", selection: $model.fileSizeUnit,
                     options: CleaningFileSizeUnit.allCases.map { (value: $0, title: $0.rawValue) })
                .frame(width: 64, height: 32).accessibilityIdentifier("space-cleaning-size-unit")
        }.fixedSize()
    }
    private func sizeField(_ title: String, value: Binding<String>) -> some View {
        TextField(title, text: value).textFieldStyle(.plain).font(.system(size: 12)).monospacedDigit()
            .padding(.horizontal, 10).frame(width: 76, height: 32)
            .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.controlBorder, lineWidth: 1)).accessibilityLabel(title)
    }

    private var previousResults: some View {
        SpaceCleaningSurface(fillHeight: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("继续上次的整理", systemImage: "clock.arrow.circlepath").font(.system(size: 13, weight: .medium))
                        if let date = model.lastScanDate {
                            Text(SpaceCleaningFormat.date(date, timeZone: timeZone) + " · " + model.scopeSummary)
                                .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(model.requiresRescan ? "部分结果 · 需重新扫描" : "结果与选择已保留")
                        .font(.system(size: 11)).foregroundStyle(model.requiresRescan ? palette.warning : palette.accent)
                }
                Rectangle().fill(palette.line).frame(height: 1)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { previousMetrics; Spacer(minLength: 8); previousResultsButton }
                    VStack(alignment: .leading, spacing: 12) { HStack(spacing: 24) { previousMetrics }; HStack { Spacer(); previousResultsButton } }
                }
            }.padding(14)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-previous-results")
    }
    private var previousMetrics: some View {
        Group {
            previousMetric("建议整理", count: model.recommendedItems.count, bytes: model.recommendedAllocatedBytes, symbol: "sparkles")
            previousMetric("其他可复核项目", count: model.otherItems.count,
                bytes: model.reviewableAllocatedBytes - min(model.reviewableAllocatedBytes, model.recommendedAllocatedBytes), symbol: "doc.on.doc")
        }
    }
    private func previousMetric(_ title: String, count: Int, bytes: UInt64, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(SpaceCleaningFormat.bytes(bytes)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                Text("\(title) · \(count) 项").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }
    }
    private var previousResultsButton: some View {
        Button { model.screen = .results } label: { Label("查看扫描结果", systemImage: "arrow.right") }
            .buttonStyle(WBButtonStyle()).accessibilityIdentifier("space-cleaning-previous-results-open")
    }
}

private struct SpaceCleaningModeChoice: View {
    let mode: SpaceCleaningScanMode
    let selected: Bool
    let height: CGFloat
    let action: () -> Void
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: mode == .cleanup ? "viewfinder" : "doc.text.magnifyingglass")
                    .font(.system(size: 26, weight: .regular)).foregroundStyle(palette.accent).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode == .cleanup ? "常规扫描" : "大文件扫描").font(.system(size: 15, weight: .medium))
                    Text(mode == .cleanup ? "检查缓存与待整理文件" : "按体积寻找占用较大的文件")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13)).foregroundStyle(selected ? palette.accent : palette.secondary).frame(width: 14)
            }.padding(.horizontal, 14).frame(height: height)
                .background {
                    RoundedRectangle(cornerRadius: 10).fill(palette.soft.opacity(selected ? 1 : 0.36))
                    if selected { RoundedRectangle(cornerRadius: 10).fill(palette.accent.opacity(palette.light ? 0.06 : 0.08)) }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.controlBorder.opacity(0.7), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(WBSelectableButtonStyle(selected: selected, cornerRadius: 10, drawsSelection: false, showsBorder: false))
            .accessibilityIdentifier("space-cleaning-mode-" + mode.rawValue)
            .accessibilityValue(selected ? "已选择" : "未选择")
    }
}

private struct SpaceCleaningScopeTile: View {
    let group: CleaningScopeGroup
    let active: Bool
    let custom: Bool
    let included: Bool
    let height: CGFloat
    let stacked: Bool
    let open: () -> Void
    let toggle: () -> Void
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                Group {
                    if stacked {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) { symbol; title; Spacer(minLength: 0) }
                            summary
                            if height >= 112 { pathPreview.padding(.top, 4) }
                        }
                    } else {
                        HStack(spacing: 10) {
                            symbol.frame(width: 36)
                            VStack(alignment: .leading, spacing: 3) { title; summary }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(.leading, 12).padding(.trailing, custom ? 0 : 12).frame(height: height).contentShape(Rectangle())
            }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 10, drawsSelection: false, showsBorder: false))
                .accessibilityLabel(group.title + "，查看范围说明")
                .accessibilityValue(active ? "正在查看" : "未查看")
                .accessibilityIdentifier("space-cleaning-scope-tile-" + group.rawValue)
            if custom {
                Button(action: toggle) {
                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17)).foregroundStyle(included ? palette.accent : palette.secondary)
                        .frame(width: 32, height: height).contentShape(Rectangle())
                }.buttonStyle(ClickablePlainButtonStyle()).padding(.trailing, 5)
                    .accessibilityLabel("扫描" + group.title).accessibilityValue(included ? "已包含" : "未包含")
                    .accessibilityIdentifier("space-cleaning-scope-toggle-" + group.rawValue)
            }
        // "Viewing" highlights the whole tile with a thin border; inclusion in a
        // custom scope keeps its own check control. Tiles do not navigate, so
        // they carry no chevron.
        }.background(RoundedRectangle(cornerRadius: 10).fill(palette.soft.opacity(active ? 1 : 0.24)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.accent.opacity(active ? 0.35 : 0), lineWidth: 1).allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
    }
    /// Whole path segments only, then "等 N 处"; never cut inside a word.
    private var pathPreview: some View {
        let parts = group.pathDescription.components(separatedBy: " · ")
        func candidate(_ count: Int) -> some View {
            Text(parts.prefix(count).joined(separator: " · ") + (count < parts.count ? " 等 \(parts.count) 处" : ""))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        return ViewThatFits(in: .horizontal) {
            if parts.count >= 3 { candidate(3) }
            if parts.count >= 2 { candidate(2) }
            candidate(1)
            Text(parts.first ?? "").lineLimit(1).truncationMode(.tail)
        }.font(.system(size: 11)).foregroundStyle(palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).help(group.pathDescription)
            .accessibilityIdentifier("space-cleaning-scope-paths-" + group.rawValue)
    }
    private var symbol: some View {
        Image(systemName: group.symbol).font(.system(size: 24, weight: .regular))
            .foregroundStyle(palette.accent).frame(width: 28, height: 28)
    }
    private var title: some View { Text(group.title).font(.system(size: 13, weight: .medium)).lineLimit(1) }
    private var summary: some View {
        Text(group.summary).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpaceCleaningScopeDetail: View {
    let group: CleaningScopeGroup
    let included: Bool
    let sizeDescription: String?
    let compact: Bool
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { title; Spacer(minLength: 8); inclusion }
                VStack(alignment: .leading, spacing: 5) { title; inclusion }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 12)).foregroundStyle(palette.secondary)
                Text(group.pathDescription).font(.system(size: 12)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            detailRow("检查内容", text: (sizeDescription ?? "") + group.content)
            detailRow("处理提示", text: group.impact)
        }.padding(.horizontal, 2).frame(maxWidth: .infinity, minHeight: compact ? 88 : 100, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-scope-detail")
    }
    private var title: some View {
        Label(group.title + " · 范围说明", systemImage: "info.circle")
            .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
            .accessibilityIdentifier("space-cleaning-scope-detail-title")
    }
    private var inclusion: some View {
        Text(included ? "已包含在本次扫描" : "未包含在本次扫描")
            .font(.system(size: 11)).foregroundStyle(palette.secondary)
            .accessibilityIdentifier("space-cleaning-scope-detail-inclusion")
    }
    private func detailRow(_ title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).foregroundStyle(palette.secondary).frame(width: 58, alignment: .leading)
            Text(text).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
}

/// Value-only presentation permits geometry fixtures without changing live reads.
struct SpaceCleaningCapacityCard: View {
    let total: UInt64?
    let available: UInt64?
    let immediatelyFree: UInt64?
    let reclaimableEstimate: UInt64?
    let volumeName: String?
    let updatedAt: Date?
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.timeZone) private var timeZone

    private var validTotal: UInt64? { total.flatMap { $0 > 0 ? $0 : nil } }
    private var validAvailable: UInt64? {
        guard let total = validTotal, let available, available <= total else { return nil }
        return available
    }
    private var validFree: UInt64? {
        guard let available = validAvailable, let immediatelyFree, immediatelyFree <= available else { return nil }
        return immediatelyFree
    }
    private var validReclaimable: UInt64? {
        guard let available = validAvailable, let free = validFree, let reclaimableEstimate,
              reclaimableEstimate == available - free else { return nil }
        return reclaimableEstimate
    }
    private var used: UInt64? {
        guard let total = validTotal, let available = validAvailable else { return nil }
        return total - available
    }
    private var percent: Double? {
        guard let total = validTotal, let used else { return nil }
        return Double(used) / Double(total) * 100
    }
    /// The shared usage colors, including the one warning red for 90% and above.
    private var usageTint: Color { palette.usageColor(forPercent: percent) }
    private var usedGradient: LinearGradient {
        LinearGradient(colors: [usageTint.opacity(0.72), usageTint], startPoint: .top, endPoint: .bottom)
    }
    private var freeTint: Color { palette.accent.opacity(palette.light ? 0.84 : 0.80) }
    private var reclaimTint: Color { palette.accent.opacity(palette.light ? 0.35 : 0.32) }
    private var note: String {
        if validAvailable == nil { return "暂未取得有效容量读数。实际可清理的内容，仍需扫描后逐项确认。" }
        if validReclaimable == nil {
            return validAvailable == validFree
                ? "系统未提供系统可回收估算；可用空间按立即空闲显示。实际可清理的内容仍需扫描后逐项确认。"
                : "系统未提供有效的系统可回收估算，暂不绘制容量构成。实际可清理的内容仍需扫描后逐项确认。"
        }
        return "可用空间包含 macOS 的系统可回收估算。实际可清理的内容，仍需扫描后逐项确认。"
    }

    var body: some View {
        SpaceCleaningSurface {
            GeometryReader { geometry in
                let compact = geometry.size.height < 680
                let inset: CGFloat = compact ? 14 : 20
                WorkbenchScrollView {
                    capacityContent(compact: compact)
                        .frame(minHeight: max(0, geometry.size.height - inset * 2), alignment: .topLeading)
                        .padding(inset)
                }.scrollBounceBehavior(.basedOnSize)
            }
        }.foregroundStyle(palette.text)
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-volume-card")
    }

    private func capacityContent(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 20) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive").font(.system(size: 24, weight: .regular)).foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(volumeName ?? "当前用户目录所在卷").font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .accessibilityIdentifier("space-cleaning-home-heading")
                    Text("当前用户所在卷").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            }
            SpaceCleaningCapacityLine(title: "总容量", bytes: validTotal, tint: nil, identifier: "total", numberSize: 17)
            if compact {
                capacity(compact: true)
            } else {
                capacity(compact: false).frame(height: 280)
            }
            availableBreakdown(compact: compact)
            if !compact { Spacer(minLength: 0) }
            Text(note).font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("space-cleaning-disk-capacity-note")
            HStack(spacing: 8) {
                Text("1 GB = 10 亿字节")
                Spacer(minLength: 0)
                Text(updatedAt.map { "更新于 " + SpaceCleaningFormat.time($0, timeZone: timeZone) } ?? "尚未取得读数")
                    .accessibilityIdentifier("space-cleaning-disk-updated-at")
            }.font(.system(size: 11)).foregroundStyle(palette.secondary)
        }
    }

    private func capacity(compact: Bool) -> some View {
        GeometryReader { geometry in
            let barWidth = max(32, min(46, geometry.size.width - 200))
            HStack(alignment: .center, spacing: 16) {
                column.frame(width: barWidth, height: min(300, geometry.size.height))
                VStack(alignment: .leading, spacing: compact ? 18 : 24) {
                    percentageLabel
                    VStack(spacing: compact ? 18 : 26) {
                        SpaceCleaningCapacityLine(title: "已用空间", bytes: used, tint: usageTint, identifier: "used")
                        SpaceCleaningCapacityLine(title: "立即空闲", bytes: validFree, tint: freeTint, identifier: "free")
                        SpaceCleaningCapacityLine(title: "系统可回收", bytes: validReclaimable, tint: reclaimTint, identifier: "reclaimable")
                    }
                }.frame(maxWidth: .infinity)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.frame(minHeight: compact ? 180 : 220, maxHeight: .infinity)
    }
    private var column: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(palette.progressTrack)
                if let total = validTotal, let used, let free = validFree,
                   validReclaimable != nil || validAvailable == free {
                    VStack(spacing: 0) {
                        Rectangle().fill(freeTint).frame(height: geometry.size.height * fraction(free, total))
                            .accessibilityElement(children: .ignore).accessibilityLabel("立即空闲容量段")
                            .accessibilityIdentifier("space-cleaning-disk-segment-free")
                        if let reclaim = validReclaimable {
                            Rectangle().fill(reclaimTint).frame(height: geometry.size.height * fraction(reclaim, total))
                                .accessibilityElement(children: .ignore).accessibilityLabel("系统可回收容量段")
                                .accessibilityIdentifier("space-cleaning-disk-segment-reclaimable")
                        }
                        Rectangle().fill(usedGradient).frame(height: geometry.size.height * fraction(used, total))
                            .accessibilityElement(children: .ignore).accessibilityLabel("已用容量段")
                            .accessibilityIdentifier("space-cleaning-disk-segment-used")
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 12))
        }.accessibilityElement(children: .contain).accessibilityLabel("磁盘容量构成")
            .accessibilityValue(percent.map { "已用 " + UsagePercentage.text($0) } ?? "暂无读数")
            .accessibilityIdentifier("space-cleaning-disk-occupancy")
    }
    private var percentageLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(percent.map { UsagePercentage.text($0) } ?? "—").font(.system(size: 30, weight: .regular)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.72)
                .accessibilityIdentifier("space-cleaning-disk-percentage")
            Text(percent == nil ? "暂无读数" : "空间已用").font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
        }.foregroundStyle(usageTint)
    }
    private func availableBreakdown(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            SpaceCleaningCapacityLine(title: "可用空间", bytes: validAvailable, tint: nil, identifier: "available", numberSize: 17)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.progressTrack)
                    if let available = validAvailable, available > 0, let free = validFree {
                        if let reclaim = validReclaimable {
                            let spacing: CGFloat = free > 0 && reclaim > 0 ? 3 : 0
                            HStack(spacing: spacing) {
                                Rectangle().fill(freeTint).frame(width: max(0, geometry.size.width - spacing) * fraction(free, available))
                                Rectangle().fill(reclaimTint).frame(width: max(0, geometry.size.width - spacing) * fraction(reclaim, available))
                            }
                        } else if free == available { Rectangle().fill(freeTint) }
                    }
                }.clipShape(Capsule())
            }.frame(height: 5).accessibilityIdentifier("space-cleaning-disk-available-breakdown")
            HStack(spacing: 8) {
                legend("立即空闲", tint: freeTint)
                Spacer(minLength: 0)
                legend(validReclaimable == nil ? "系统可回收估算未提供" : "系统可回收（估算）", tint: reclaimTint)
            }
        }.padding(.top, compact ? 4 : 12)
    }
    private func legend(_ title: String, tint: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(tint).frame(width: 6, height: 6); Text(title) }
            .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize()
    }
    private func fraction(_ value: UInt64, _ total: UInt64) -> CGFloat {
        total > 0 ? CGFloat(Double(value) / Double(total)) : 0
    }
}

private struct SpaceCleaningCapacityLine: View {
    let title: String
    let bytes: UInt64?
    let tint: Color?
    let identifier: String
    var numberSize: CGFloat = 17
    @Environment(\.workbenchPalette) private var palette
    private var parts: [String] { DeviceStorageCapacity.formatted(bytes).components(separatedBy: " ") }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let tint {
                Circle().fill(tint).frame(width: 6, height: 6).padding(.trailing, 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            }
            Text(title).font(.system(size: 12)).foregroundStyle(palette.secondary).lineLimit(1).fixedSize()
                .accessibilityIdentifier("space-cleaning-disk-" + identifier + "-label")
            Spacer(minLength: 4)
            Text(parts.first ?? "—").font(.system(size: numberSize, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
                .accessibilityIdentifier("space-cleaning-disk-" + identifier + "-value")
            Text(parts.count > 1 ? parts[1] : "").font(.system(size: 11)).foregroundStyle(palette.secondary)
                .frame(width: 18, alignment: .trailing).padding(.leading, 4)
                .accessibilityIdentifier("space-cleaning-disk-" + identifier + "-unit")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-disk-" + identifier)
    }
}
