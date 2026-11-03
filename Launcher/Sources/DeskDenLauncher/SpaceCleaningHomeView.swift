import SwiftUI
import LauncherCore

/// The preparation page shares the same two-column work area as the scan.
/// All capacity and previous-result values come from the existing model.
struct SpaceCleaningHomeView: View {
    @ObservedObject var model: SpaceCleaningModel
    let width: CGFloat
    let height: CGFloat
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.timeZone) private var timeZone

    private var editingScope: Bool { model.screen == .scope }
    private var scope: CleaningScopeChoice { editingScope ? model.draftScope : model.scopeChoice }
    private var locations: [URL] { editingScope ? model.draftDirectories : model.customDirectories }
    private var hasPreviousResults: Bool { !model.items.isEmpty && !editingScope }
    private var usedBytes: UInt64? {
        guard let total = model.diskTotal, let available = model.diskAvailable else { return nil }
        return total - min(total, available)
    }
    private var usedFraction: Double? {
        guard let total = model.diskTotal, total > 0, let usedBytes else { return nil }
        return Double(usedBytes) / Double(total)
    }
    private var columnHeight: CGFloat { max(420, height - (hasPreviousResults ? 132 : 0)) }

    var body: some View {
        WorkbenchScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if width >= 760 {
                    HStack(alignment: .top, spacing: 12) {
                        volumeCard.frame(width: max(240, (width - 12) / 3), height: columnHeight)
                        configuration(width: max(0, width - max(240, (width - 12) / 3) - 12))
                            .frame(maxWidth: .infinity).frame(height: columnHeight)
                    }
                } else {
                    volumeCard.frame(height: 342)
                    configuration(width: width).frame(height: max(452, model.scanMode == .largeFiles ? 530 : 452))
                }
                if hasPreviousResults { previousResults }
            }.frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-home-surface")
        }.scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("space-cleaning-home-scroll")
    }

    private var volumeCard: some View {
        SpaceCleaningSurface {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 9) {
                    Image(systemName: "internaldrive").font(.system(size: 20, weight: .regular)).foregroundStyle(palette.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.diskVolumeName ?? "当前用户目录所在卷").font(.system(size: 14, weight: .medium))
                            .lineLimit(1).accessibilityIdentifier("space-cleaning-home-heading")
                        Text("当前用户目录所在卷").font(.system(size: 11)).foregroundStyle(palette.muted)
                    }
                }
                Spacer(minLength: 0)
                occupancyRing.frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                VStack(spacing: 11) {
                    capacityLine("已用空间", value: usedBytes, tint: palette.accent, identifier: "used")
                    capacityLine("可用空间", value: model.diskAvailable, tint: palette.muted.opacity(0.45), identifier: "available")
                    capacityLine("总容量", value: model.diskTotal, identifier: "total")
                }
                Spacer(minLength: 0)
                Rectangle().fill(palette.line).frame(height: 1)
                HStack(spacing: 8) {
                    Text("十进制容量")
                    Spacer(minLength: 0)
                    if let date = model.diskUpdatedAt {
                        Text("更新于 " + SpaceCleaningFormat.time(date, timeZone: timeZone))
                    }
                }.font(.system(size: 11)).foregroundStyle(palette.muted)
            }.padding(14)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-volume-card")
    }

    private var occupancyRing: some View {
        ZStack {
            Circle().stroke(palette.progressTrack, lineWidth: 8)
            if let fraction = usedFraction {
                Circle().trim(from: 0, to: CGFloat(fraction))
                    .stroke(palette.usageColor(forPercent: fraction * 100), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 5) {
                Text(usedFraction.map { UsagePercentage.text($0 * 100) } ?? "—")
                    .font(.system(size: 30, weight: .medium)).monospacedDigit()
                Text(usedFraction == nil ? "暂无容量读数" : "空间已使用")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }.padding(8).frame(width: 174, height: 174)
            .accessibilityElement(children: .ignore).accessibilityLabel("磁盘已用比例")
            .accessibilityValue(usedFraction.map { UsagePercentage.text($0 * 100) } ?? "暂无读数")
            .accessibilityIdentifier("space-cleaning-disk-occupancy")
    }

    private func capacityLine(_ title: String, value: UInt64?, tint: Color? = nil, identifier: String) -> some View {
        HStack(spacing: 8) {
            if let tint { Circle().fill(tint).frame(width: 6, height: 6) }
            Text(title).foregroundStyle(palette.secondary)
            Spacer(minLength: 8)
            Text(DeviceStorageCapacity.formatted(value)).monospacedDigit()
        }.font(.system(size: 12)).accessibilityElement(children: .combine)
            .accessibilityIdentifier("space-cleaning-disk-" + identifier)
    }

    private func configuration(width: CGFloat) -> some View {
        SpaceCleaningSurface {
            WorkbenchScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text(editingScope ? "调整扫描范围" : "开始一次整理").font(.system(size: 14, weight: .medium))
                        Spacer(minLength: 0)
                        Text("扫描 → 复核 → 处理").font(.system(size: 11)).foregroundStyle(palette.muted)
                    }
                    modeChoices
                    if model.scanMode == .largeFiles { largeFileControls }
                    scopeControls(width: width - 28)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize)
            Rectangle().fill(palette.line).frame(height: 1).padding(.horizontal, 14)
            configurationActions
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-configuration-card")
    }

    private var modeChoices: some View {
        HStack(spacing: 12) {
            ForEach(SpaceCleaningScanMode.allCases, id: \.self) { mode in
                Button { model.selectScanMode(mode) } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: mode == .cleanup ? "sparkles" : "doc.text.magnifyingglass")
                                .font(.system(size: 20, weight: .regular)).foregroundStyle(palette.accent)
                            Spacer(minLength: 4)
                            Image(systemName: model.scanMode == mode ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 13)).foregroundStyle(model.scanMode == mode ? palette.accent : palette.muted)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode == .cleanup ? "常规扫描" : "大文件扫描").font(.system(size: 12, weight: .medium))
                            Text(mode == .cleanup ? "检查可重建缓存与待整理文件" : "按体积找出占用较大的文件")
                                .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(14).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(palette.soft))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(model.scanMode == mode ? palette.accent.opacity(0.35) : palette.controlBorder, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(WBSelectableButtonStyle(selected: model.scanMode == mode, cornerRadius: 10, showsBorder: false))
                    .disabled(model.isBusy || editingScope)
                    .accessibilityIdentifier("space-cleaning-mode-" + mode.rawValue)
                    .accessibilityValue(model.scanMode == mode ? "已选择" : "未选择")
            }
        }
    }

    private func scopeControls(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack { Text("扫描范围").font(.system(size: 12, weight: .medium)); Spacer(minLength: 8); scopeChoices }
                VStack(alignment: .leading, spacing: 8) { Text("扫描范围").font(.system(size: 12, weight: .medium)); scopeChoices }
            }
            if scope == .custom { selectedLocations(width: width) }
            else { globalLocations }
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier(editingScope ? "space-cleaning-scope-editor" : "space-cleaning-scope-options")
    }

    private var scopeChoices: some View {
        HStack(spacing: 2) {
            scopeButton("全局扫描", selected: scope == .global, id: "global") {
                if editingScope { model.draftScope = .global } else { model.selectScope(.global) }
            }
            scopeButton("自选目录", selected: scope == .custom, id: "custom") {
                if editingScope { model.draftScope = .custom } else { model.editScope(custom: true) }
            }
        }.padding(2).background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
    }

    private func scopeButton(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 12)).padding(.horizontal, 12).frame(height: 28).contentShape(Rectangle()) }
            .buttonStyle(WBSelectableButtonStyle(selected: selected, cornerRadius: 6, showsBorder: false))
            .disabled(model.isBusy).accessibilityValue(selected ? "已选择" : "未选择")
            .accessibilityIdentifier("space-cleaning-scope-" + id)
    }

    private var globalLocations: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                scopeTile("下载", subtitle: "~/Downloads", symbol: "arrow.down.to.line", id: "downloads")
                scopeTile("应用缓存", subtitle: "~/Library/Caches", symbol: "square.stack.3d.up", id: "caches")
                scopeTile("文稿", subtitle: "~/Documents", symbol: "doc.text", id: "documents")
                scopeTile("桌面", subtitle: "~/Desktop", symbol: "desktopcomputer", id: "desktop")
            }
            HStack(alignment: .top, spacing: 8) {
                Text("另含图片影音、开发构建、用户应用与归档；未获权限的位置会在结果中说明。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("查看范围") { model.dialog = .rules }.buttonStyle(WBTextActionButtonStyle()).fixedSize()
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-global-locations")
    }

    private func scopeTile(_ title: String, subtitle: String, symbol: String, id: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(palette.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(palette.accent)
        }.padding(10).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
            .accessibilityElement(children: .combine).accessibilityIdentifier("space-cleaning-scope-tile-" + id)
    }

    private func selectedLocations(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(locations.isEmpty ? "添加想要检查的文件夹" : "已选 \(locations.count) 个位置")
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
            if locations.isEmpty {
                Text("支持多选文件夹，也可选择外接磁盘中的位置")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, minHeight: 88)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-home-locations")
    }

    private var configurationActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { scanProtection; Spacer(minLength: 8); scanButtons }
            VStack(alignment: .leading, spacing: 10) { scanProtection; HStack { Spacer(minLength: 0); scanButtons } }
        }.padding(14).accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-home-actions")
    }
    private var scanProtection: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("扫描只读取信息")
                Text("开发依赖与发布原件保持保护").foregroundStyle(palette.muted)
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
                    .disabled(scope == .custom && locations.isEmpty).accessibilityIdentifier("space-cleaning-apply-scope")
            }
            Button {
                if editingScope { model.applyScope() }
                model.startScan()
            } label: { Label("开始扫描", systemImage: "viewfinder") }
                .buttonStyle(WBButtonStyle(primary: true))
                .disabled(model.isBusy || model.largeFileRangeError != nil || (scope == .custom && locations.isEmpty))
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
