import AppKit
import SwiftUI
import LauncherCore

struct SpaceCleaningModuleView: View {
    @ObservedObject var model: SpaceCleaningModel
    @Environment(\.workbenchPalette) private var palette
    @State private var measuredHeights: [SpaceCleaningMeasuredRegion: CGFloat] = [:]

    private var isPreparing: Bool { [.start, .scope].contains(model.screen) && model.dialog == nil }
    private func panelHeight(in viewport: CGFloat) -> CGFloat {
        let available = max(0, viewport - (measuredHeights[.header] ?? 72) - (measuredHeights[.footer] ?? 36))
        guard isPreparing, let document = measuredHeights[.homeDocument], let actions = measuredHeights[.homeActions] else { return available }
        return min(available, document + actions + 12 + 28)
    }

    var body: some View {
        GeometryReader { geometry in
            let height = panelHeight(in: geometry.size.height)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                header.fixedSize(horizontal: false, vertical: true)
                if model.isReconcilingHistory && model.screen != .history {
                    HStack(spacing: 8) {
                        Text("正在核对历史项目").font(.system(size: 11)).foregroundStyle(palette.muted)
                        Button("停止核对", action: model.cancelHistoryVerification).buttonStyle(WBQuietButtonStyle())
                    }.padding(.bottom, 12).fixedSize(horizontal: false, vertical: true)
                }
                }.measureCleaningHeight(.header)
                // Preparation uses its measured content height, bounded by the
                // actual viewport. Other stages fill the available work area.
                // Additional fields extend downward; the overview never shrinks.
                content(width: geometry.size.width, height: height)
                    .frame(width: geometry.size.width, height: height, alignment: .top)
                VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if !isPreparing {
                        Text(model.scopeSummary).lineLimit(1).truncationMode(.middle)
                        if model.screen == .results { Text(model.requiresRescan ? "· 需重新扫描" : "· 已检查") }
                    } else if let date = model.lastScanDate {
                        Text("上次扫描 · " + SpaceCleaningFormat.date(date))
                    } else {
                        Label("开发依赖与发布归档保持保护", systemImage: "checkmark.shield")
                    }
                    Spacer(minLength: 4)
                    Button("覆盖范围与保留规则") { model.dialog = .rules }.buttonStyle(WBTextActionButtonStyle())
                        .disabled(model.isBusy).accessibilityIdentifier("space-cleaning-rules-link")
                }.font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = model.message {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(message).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.message = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(WBIconButtonStyle(size: 24)).accessibilityLabel("关闭提示")
                    }.font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 10)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("space-cleaning-message")
                }
                }.measureCleaningHeight(.footer)
                Spacer(minLength: 0)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }.foregroundStyle(palette.text)
            .environment(\.workbenchScale, 1)
            .onAppear { model.refreshDisk() }
            .onPreferenceChange(SpaceCleaningHeightPreference.self) { values in
                for (region, value) in values where value.isFinite && value > 0 {
                    if abs((measuredHeights[region] ?? 0) - value) > 0.25 { measuredHeights[region] = value }
                }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning")
    }
    private var subtitle: String {
        if model.screen == .results { return "核对文件用途，选择处理方式" }
        guard let total = model.diskTotal, let available = model.diskAvailable else { return "正在读取存储信息" }
        return "\(model.diskVolumeName ?? "此 Mac") · \(DeviceStorageCapacity.formatted(available)) 可用 / \(DeviceStorageCapacity.formatted(total)) 卷容量"
    }
    private var capacityExplanation: String {
        let free = DeviceStorageCapacity.formatted(model.diskImmediatelyFree)
        let reclaimable = DeviceStorageCapacity.formatted(model.diskReclaimableEstimate)
        return "当前用户目录所在卷，按十进制显示（1 GB = 10 亿字节）。立即空闲 \(free)，系统可回收估算 \(reclaimable)。可用空间优先包含系统按需可回收部分，缺少估算时使用立即空闲；不代表方寸可清理容量。"
    }
    private var header: some View {
        WBPageHeader(title: model.screen == .history ? "清理记录" : "空间清理", subtitle: subtitle) {
            if model.dialog.map({ !isPurpose($0) }) == true {
                Button(action: model.closeDialog) { Label(model.dialogReturnTitle, systemImage: "arrow.left") }
                    .buttonStyle(WBQuietButtonStyle()).disabled(model.isBusy)
            } else if model.screen == .results {
                Button(action: model.goHome) { Label("扫描设置", systemImage: "chevron.left") }
                    .buttonStyle(WBQuietButtonStyle()).disabled(model.isBusy)
                    .accessibilityIdentifier("space-cleaning-edit-scope")
            } else if model.screen == .history {
                Button(action: model.returnFromHistory) { Label(model.historyReturnTitle, systemImage: "chevron.left") }
                    .buttonStyle(WBQuietButtonStyle()).disabled(model.isBusy)
            }
            if model.screen == .results {
                Button(action: model.startScan) { Label("重新扫描", systemImage: "arrow.clockwise") }
                    .buttonStyle(WBButtonStyle()).disabled(model.isBusy).accessibilityIdentifier("space-cleaning-rescan")
            }
            if model.screen != .history {
                Button(action: model.showHistory) { Label("清理记录", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(WBButtonStyle()).disabled(model.isBusy || model.screen == .scope)
            }
        }.help(capacityExplanation)
    }
    @ViewBuilder private func content(width: CGFloat, height: CGFloat) -> some View {
        if let dialog = model.dialog, dialog != .confirm, !isPurpose(dialog) {
            SpaceCleaningSurface {
                WorkbenchScrollView {
                    SpaceCleaningDialogContent(model: model, dialog: dialog)
                }.scrollBounceBehavior(.basedOnSize)
            }
        } else {
            switch model.screen {
            case .start, .scope: home(width: width, height: height)
            case .scanning: scanning(height: height)
            case .results: SpaceCleaningResultsView(model: model)
            case .processing: processing(height: height)
            case .completed: SpaceCleaningCompletionView(model: model)
            case .history: SpaceCleaningHistoryView(model: model)
            }
        }
    }
    private func isPurpose(_ dialog: CleaningDialog) -> Bool { if case .purpose = dialog { true } else { false } }
    private var editingScope: Bool { model.screen == .scope }
    private var displayedScope: CleaningScopeChoice { editingScope ? model.draftScope : model.scopeChoice }
    private var displayedLocations: [URL] { editingScope ? model.draftDirectories : model.customDirectories }
    private func home(width: CGFloat, height: CGFloat) -> some View {
        let documentViewport = max(0, height - (measuredHeights[.homeActions] ?? 32) - 12 - 28)
        let overflowing = (measuredHeights[.homeDocument] ?? 0) > documentViewport + 1
        return SpaceCleaningSurface {
            VStack(alignment: .leading, spacing: 12) {
                WorkbenchScrollView {
                VStack(alignment: .leading, spacing: 12) {
                storageOverview(width: width)
                scanModeControls
                if model.scanMode == .largeFiles { largeFileControls }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        HStack(spacing: 8) {
                            Text("扫描范围").font(.system(size: 12, weight: .medium))
                            Text(displayedScope == .global ? "8 类常用位置" : "\(displayedLocations.count) 个位置")
                                .font(.system(size: 11)).foregroundStyle(palette.muted)
                            if overflowing {
                                Label("向下滚动查看", systemImage: "arrow.down")
                                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                                    .accessibilityIdentifier("space-cleaning-scope-scroll-hint")
                            }
                        }.lineLimit(1)
                        Spacer(minLength: 0)
                        HStack(spacing: 2) {
                            scopeButton("全局扫描", icon: "globe", selected: displayedScope == .global) {
                                if editingScope { model.draftScope = .global } else { model.selectScope(.global) }
                            }
                            scopeButton("自定义位置", icon: "folder", selected: displayedScope == .custom) {
                                if editingScope { model.draftScope = .custom } else { model.editScope(custom: true) }
                            }
                        }.padding(2).background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line))
                    }
                    if displayedScope == .custom {
                        selectedLocations(width: width - 32)
                    } else {
                        globalLocations(width: width - 32)
                    }
                }.accessibilityElement(children: .contain)
                    .accessibilityIdentifier(editingScope ? "space-cleaning-scope-editor" : "space-cleaning-scope-options")
                }.fixedSize(horizontal: false, vertical: true).padding(.trailing, 4)
                    .measureCleaningHeight(.homeDocument)
                }.scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("space-cleaning-home-scroll")
                HStack(spacing: 10) {
                    Text(displayedScope == .global ? "未获权限的位置会在结果中说明" : "\(displayedLocations.count) 个位置 · 可在上方添加或移除")
                        .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
                    Spacer(minLength: 4)
                    if !editingScope && !model.items.isEmpty && !model.requiresRescan {
                        Button("返回上次结果") { model.screen = .results }.buttonStyle(WBButtonStyle())
                    }
                    if editingScope {
                        Button("取消", action: model.cancelScope).buttonStyle(WBButtonStyle()).accessibilityIdentifier("space-cleaning-cancel-scope")
                        Button("保存范围", action: model.applyScope).buttonStyle(WBButtonStyle())
                            .disabled(displayedScope == .custom && displayedLocations.isEmpty)
                            .accessibilityIdentifier("space-cleaning-apply-scope")
                    }
                    Button {
                        if editingScope { model.applyScope() }
                        model.startScan()
                    } label: { Label("开始扫描", systemImage: "viewfinder") }
                        .buttonStyle(WBButtonStyle(primary: true))
                        .disabled(model.isBusy || model.largeFileRangeError != nil || (displayedScope == .custom && displayedLocations.isEmpty))
                        .accessibilityIdentifier("space-cleaning-start")
                }.fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-home-actions")
                    .measureCleaningHeight(.homeActions)
            }.padding(14)
        }
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-home-surface")
    }
    private var scanModeControls: some View {
        HStack(spacing: 8) {
            ForEach(SpaceCleaningScanMode.allCases, id: \.self) { mode in
                Button { model.selectScanMode(mode) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mode == .cleanup ? "sparkles" : "doc.text.magnifyingglass")
                            .font(.system(size: 14)).foregroundStyle(model.scanMode == mode ? palette.accent : palette.secondary)
                            .frame(width: 16)
                        Text(mode == .cleanup ? "普通清理" : "大文件扫描").font(.system(size: 12, weight: .medium))
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.accent).opacity(model.scanMode == mode ? 1 : 0)
                    }.frame(width: 140, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.controlBorder, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(WBSelectableButtonStyle(selected: model.scanMode == mode))
                    .accessibilityIdentifier("space-cleaning-mode-" + mode.rawValue)
                    .accessibilityValue(model.scanMode == mode ? "已选择" : "未选择")
            }
            Text(model.scanMode == .cleanup ? "识别可重建缓存，逐项核对其余文件" : "按大小查找，所有结果由你选择")
                .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2).padding(.leading, 4)
            Spacer(minLength: 0)
        }.disabled(model.isBusy || editingScope)
    }
    private var diskUsed: UInt64? {
        guard let total = model.diskTotal, total > 0, let available = model.diskAvailable else { return nil }
        return total - min(total, available)
    }
    private var diskUsedFraction: Double? {
        guard let total = model.diskTotal, total > 0, let used = diskUsed else { return nil }
        return Double(used) / Double(total)
    }
    private func storageOverview(width: CGFloat) -> some View {
        let size = 132.0
        return HStack(alignment: .center, spacing: 24) {
            ZStack {
                Circle().stroke(palette.progressTrack, lineWidth: 8)
                if let fraction = diskUsedFraction {
                    Circle().trim(from: 0, to: CGFloat(fraction)).stroke(palette.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(diskUsedFraction.map { ($0 * 100).formatted(.number.precision(.fractionLength(1))) } ?? "—")
                            .font(.system(size: 31)).monospacedDigit()
                        if diskUsedFraction != nil { Text("%").font(.system(size: 12)).foregroundStyle(palette.secondary) }
                    }
                    Text(diskUsedFraction == nil ? "暂无容量读数" : "磁盘已用").font(.system(size: 11)).foregroundStyle(palette.muted)
                }
            }.padding(8).frame(width: size, height: size)
                .accessibilityElement(children: .ignore).accessibilityLabel("磁盘已用比例")
                .accessibilityValue(diskUsedFraction.map { ($0 * 100).formatted(.number.precision(.fractionLength(1))) + "%" } ?? "暂无读数")
                .accessibilityIdentifier("space-cleaning-disk-occupancy")
            VStack(alignment: .leading, spacing: 0) {
                Text(model.diskVolumeName ?? "当前用户目录所在卷").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.muted)
                    .accessibilityIdentifier("space-cleaning-home-heading")
                Text("查看空间占用，核对文件用途后再整理")
                    .font(.system(size: 12)).padding(.top, 4)
                HStack(alignment: .top, spacing: 24) {
                    storageValue("已用", value: diskUsed)
                    storageValue("可用", value: model.diskAvailable)
                    storageValue("总容量", value: model.diskTotal)
                }.padding(.top, 14)
                Text("先扫描查看位置与用途，确认后再处理文件。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 10)
            }.frame(maxWidth: 520, alignment: .leading)
                .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-home-intro")
            Spacer(minLength: 0)
        }.padding(.horizontal, 4).help(capacityExplanation)
    }
    private func storageValue(_ title: String, value: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.muted)
            Text(DeviceStorageCapacity.formatted(value)).font(.system(size: 17, weight: .medium)).monospacedDigit().lineLimit(1)
        }.accessibilityElement(children: .combine)
            .accessibilityIdentifier("space-cleaning-disk-" + (title == "已用" ? "used" : title == "可用" ? "available" : "total"))
    }
    private var largeFileControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Only reflow when the complete set of standard-height controls no
            // longer fits. The normal window keeps presets and range together.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    largeFilePresets
                    largeFileRange
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    largeFilePresets
                    largeFileRange
                }
            }
            if let error = model.largeFileRangeError {
                Text(error).font(.system(size: 11)).foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("space-cleaning-size-error")
            }
        }.disabled(model.isBusy || editingScope)
            .help("按文件大小筛选；开发环境不展开。大小与磁盘占用分别显示，文件较大不代表可以删除。")
            .onChange(of: model.minimumFileSize) { _, _ in model.scanSettingsChanged() }
            .onChange(of: model.maximumFileSize) { _, _ in model.scanSettingsChanged() }
            .onChange(of: model.fileSizeUnit) { _, _ in model.scanSettingsChanged() }
            .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-large-file-options")
    }
    private var largeFilePresets: some View {
        HStack(spacing: 6) {
            ForEach(["100", "500"], id: \.self) { value in
                Button("≥ " + value + " MB") { model.setLargeFilePreset(value, unit: .mb) }
                    .buttonStyle(WBButtonStyle())
                    .accessibilityIdentifier("space-cleaning-preset-" + value)
            }
            Button("≥ 1 GB") { model.setLargeFilePreset("1", unit: .gb) }
                .buttonStyle(WBButtonStyle())
                .accessibilityIdentifier("space-cleaning-preset-1gb")
        }.fixedSize()
    }
    private var largeFileRange: some View {
        HStack(spacing: 8) {
            Text("范围").font(.system(size: 11)).foregroundStyle(palette.secondary)
            sizeField("最小大小", value: $model.minimumFileSize)
                .accessibilityIdentifier("space-cleaning-minimum-size")
            Text("—").font(.system(size: 11)).foregroundStyle(palette.muted)
            sizeField("不限", value: $model.maximumFileSize).accessibilityLabel("最大文件大小，留空表示不限")
                .accessibilityIdentifier("space-cleaning-maximum-size")
            WBSelect("文件大小单位", selection: $model.fileSizeUnit,
                     options: CleaningFileSizeUnit.allCases.map { (value: $0, title: $0.rawValue) })
                .frame(width: 64, height: 32)
                .accessibilityIdentifier("space-cleaning-size-unit")
        }.fixedSize().controlSize(.regular)
    }
    private func sizeField(_ title: String, value: Binding<String>) -> some View {
        TextField(title, text: value).textFieldStyle(.plain).font(.system(size: 12)).monospacedDigit()
            .padding(.horizontal, 10).frame(width: 76, height: 32)
            .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.controlBorder, lineWidth: 1))
            .accessibilityLabel(title)
    }
    private func globalLocations(width: CGFloat) -> some View {
        let locations: [(String, String, String, String)] = [
            ("downloads", "下载", "arrow.down.to.line", "安装包与下载文件"), ("desktop", "桌面", "desktopcomputer", "桌面文件与文件夹"),
            ("documents", "文稿", "doc.text", "文档与个人资料"), ("media", "图片与影音", "photo", "照片、视频与音乐"),
            ("caches", "应用缓存", "square.stack.3d.up", "核验可重建的缓存"), ("development", "开发与构建", "hammer", "检查构建缓存 · 保护依赖"),
            ("applications", "用户应用", "macwindow", "查看占用 · 保留应用"), ("archives", "归档与发布", "archivebox", "查看占用 · 保留原件")
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: width < 560 ? 2 : 4), spacing: 8) {
            ForEach(locations, id: \.0) { id, title, icon, detail in
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: icon).font(.system(size: 18, weight: .regular)).foregroundStyle(palette.secondary)
                        .frame(width: 28, height: 28)
                        .accessibilityElement(children: .ignore).accessibilityLabel(title + "图标")
                        .accessibilityIdentifier("space-cleaning-scope-icon-" + id)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(detail).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-scope-copy-" + id)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 72)
                    .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-scope-tile-" + id)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-global-locations")
    }
    private func selectedLocations(width: CGFloat) -> some View {
        let columns = min(4, max(1, Int((width + 8) / 244)))
        let rows = Int(ceil(Double(displayedLocations.count) / Double(columns)))
        let rowHeight = 72.0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(displayedLocations.isEmpty ? "添加想要检查的文件夹" : "已选 \(displayedLocations.count) 个位置" + (rows > 2 ? " · 向下滚动查看" : "")).font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer()
                Button { if !editingScope { model.editScope(custom: true) }; model.chooseCustomDirectory() } label: { Label("添加位置", systemImage: "plus") }
                    .buttonStyle(WBQuietButtonStyle())
                    .accessibilityIdentifier("space-cleaning-manage-locations")
            }
            WorkbenchScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: columns), spacing: 8) {
                    ForEach(displayedLocations, id: \.self) { location in
                        HStack(spacing: 10) {
                            Image(systemName: "folder").font(.system(size: 18, weight: .regular)).foregroundStyle(palette.secondary)
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(location.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Text(model.shortPath(location.deletingLastPathComponent())).font(.system(size: 11)).foregroundStyle(palette.muted)
                                    .lineLimit(1).truncationMode(.middle)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                if !editingScope { model.editScope(custom: true) }
                                model.removeDraftDirectory(location)
                            } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                                .buttonStyle(WBIconButtonStyle(size: 24)).help("从扫描范围移除，不会删除文件")
                                .accessibilityLabel("移除扫描位置 " + location.lastPathComponent)
                        }.padding(.horizontal, 12).frame(height: rowHeight)
                            .background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line))
                            .help(model.shortPath(location)).accessibilityElement(children: .contain)
                            .accessibilityLabel("扫描文件夹 " + model.shortPath(location))
                            .accessibilityIdentifier("space-cleaning-location-" + location.lastPathComponent)
                    }
                }.padding(.trailing, 12)
                if displayedLocations.isEmpty {
                    Text("支持多选文件夹，也可以选择外接磁盘中的位置")
                        .font(.system(size: 11)).foregroundStyle(palette.muted).frame(maxWidth: .infinity, minHeight: rowHeight * 2 + 8)
                }
            }.frame(height: rowHeight * 2 + 8).scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("space-cleaning-home-locations")
        }
    }
    private func scopeButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.system(size: 12)).padding(.horizontal, 12).frame(height: 28)
            .contentShape(Rectangle()) }
            .buttonStyle(WBSelectableButtonStyle(selected: selected, cornerRadius: 6)).disabled(model.isBusy).accessibilityValue(selected ? "已选择" : "未选择")
            .accessibilityIdentifier(icon == "globe" ? "space-cleaning-scope-global" : "space-cleaning-scope-custom")
    }
    private func scanning(height: CGFloat) -> some View {
        let fraction = model.scanPhase == .discovering ? nil : model.scanFraction
        return SpaceCleaningSurface {
            WorkbenchScrollView {
            VStack(spacing: 0) {
            SpaceCleaningAperture(active: model.animationActive, scanning: true)
                .frame(height: max(170, min(276, height * 0.46))).frame(maxWidth: 680).frame(maxWidth: .infinity)
                .padding(.horizontal, 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.scanPhase == .discovering ? "发现项目" : "核验文件").font(.system(size: 11)).foregroundStyle(palette.muted)
                        Text(model.scanPhase == .discovering ? "正在查找可检查项目" : "正在检查文件").font(.system(size: 20, weight: .medium))
                        Text(model.scanPhase == .discovering ? "已查看 \(model.checkedCount.formatted()) 个目录与文件 · 总量尚未确定" : model.scanTotalItems.map { "已核验 \(model.scanCompletedItems) / \($0) 项" } ?? "正在汇总已检查的项目")
                            .font(.system(size: 11)).foregroundStyle(palette.muted).monospacedDigit()
                    }
                    Spacer()
                    if let fraction {
                        VStack(alignment: .trailing, spacing: 4) {
                            (Text("\(Int(fraction * 100))").font(.system(size: 29)) + Text(" %").font(.system(size: 11))).monospacedDigit()
                            Text("项目核验进度").font(.system(size: 11)).foregroundStyle(palette.muted)
                        }
                    } else { Text("正在发现").font(.system(size: 12)).foregroundStyle(palette.muted) }
                }
                SpaceCleaningProgressTrack(fraction: fraction, active: model.animationActive)
                VStack(alignment: .leading, spacing: 10) {
                    scanLine("当前目录", value: model.scanDirectory.isEmpty ? "正在读取扫描范围" : model.scanDirectory, mono: true)
                    scanLine("当前项目", value: model.scanItem.isEmpty ? "等待目录返回" : model.scanItem, mono: false)
                }
                Label("开发依赖和发布原件保持保护", systemImage: "checkmark.shield")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }.frame(maxWidth: 660).padding(.horizontal, 30).padding(.bottom, 20).frame(maxWidth: .infinity)
            }
            }.scrollBounceBehavior(.basedOnSize)
            HStack {
                Label(model.scopeChoice == .global ? "当前用户常用位置" : "自定义位置", systemImage: model.scopeChoice == .global ? "globe" : "folder")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer()
                Button("停止扫描", action: model.cancelScan).buttonStyle(WBButtonStyle()).accessibilityIdentifier("space-cleaning-cancel-scan")
            }.padding(14)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-scan")
    }
    private func scanLine(_ title: String, value: String, mono: Bool) -> some View {
        HStack(spacing: 16) {
            Text(title).foregroundStyle(palette.muted).frame(width: 50, alignment: .leading)
            Text(value).font(.system(size: 11, design: mono ? .monospaced : .default)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11)).frame(height: 16)
    }
    private func processing(height: CGFloat) -> some View {
        SpaceCleaningSurface {
            WorkbenchScrollView {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(palette.accent.opacity(0.06)).frame(width: 160, height: 160)
                    Circle().stroke(palette.accent.opacity(0.14), lineWidth: 1).frame(width: 128, height: 128)
                    Image(systemName: "checkmark.shield").font(.system(size: 44, weight: .light)).foregroundStyle(palette.accent)
                }.frame(height: max(180, min(250, height * 0.44))).frame(maxWidth: .infinity).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("处理所选项目").font(.system(size: 11)).foregroundStyle(palette.muted)
                    Text("正在安全处理所选项目").font(.system(size: 20, weight: .medium))
                    Text("每项操作前，重新核对文件与保护状态。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                HStack(spacing: 12) {
                    Image(systemName: "doc").font(.system(size: 20)).foregroundStyle(palette.secondary).frame(width: 28)
                    Text(model.processingItem.isEmpty ? "正在准备处理项目" : model.processingItem)
                        .font(.system(size: 12)).lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(14).frame(minHeight: 62).background(RoundedRectangle(cornerRadius: 8).fill(palette.soft))
                SpaceCleaningProgressTrack(fraction: model.processingTotal > 0 ? Double(model.processingCompleted) / Double(model.processingTotal) : nil, active: model.windowVisible && !model.reduceMotion)
                Text("已处理 \(model.processingCompleted) / \(model.processingTotal) 项")
                    .font(.system(size: 12)).monospacedDigit()
            }.frame(maxWidth: 660).padding(.horizontal, 30).padding(.bottom, 20).frame(maxWidth: .infinity)
            }
            }.scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 12) {
                Text("停止后保留已完成的操作，其余项目不会继续处理。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
                Spacer(minLength: 0)
                Button("停止后续处理", action: model.cancelProcessing).buttonStyle(WBButtonStyle())
                    .accessibilityIdentifier("space-cleaning-cancel-processing")
            }.padding(14)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("space-cleaning-processing")
    }
}

struct SpaceCleaningSurface<Content: View>: View {
    var fillHeight = true
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(WorkbenchMaterialSurface(radius: 15)).clipShape(RoundedRectangle(cornerRadius: 15))
    }
}
struct SpaceCleaningProgressTrack: View {
    let fraction: Double?
    let active: Bool
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var applicationActive = NSApplication.shared.isActive
    private var running: Bool { active && applicationActive && !systemReduceMotion }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: fraction != nil || !running)) { timeline in
            GeometryReader { geo in
                let position = running ? (sin(timeline.date.timeIntervalSinceReferenceDate * 1.4) + 1) / 2 : 0.35
                Capsule().fill(palette.progressTrack)
                Capsule().fill(LinearGradient(colors: [palette.accent.opacity(0.4), palette.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * (fraction ?? 0.18))
                    .offset(x: fraction == nil ? geo.size.width * 0.82 * position : 0)
            }
        }.frame(height: 3)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in applicationActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in applicationActive = false }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("扫描进度").accessibilityValue(fraction.map { "\(Int($0 * 100))%" } ?? "正在发现项目，总量未知")
    }
}
enum SpaceCleaningFormat {
    static func bytes(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file) }
    static func date(_ date: Date) -> String { date.formatted(.dateTime.year().month().day().hour().minute()) }
}


private enum SpaceCleaningMeasuredRegion: Hashable { case header, footer, homeDocument, homeActions }
private struct SpaceCleaningHeightPreference: PreferenceKey {
    static let defaultValue: [SpaceCleaningMeasuredRegion: CGFloat] = [:]
    static func reduce(value: inout [SpaceCleaningMeasuredRegion: CGFloat], nextValue: () -> [SpaceCleaningMeasuredRegion: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private extension View {
    func measureCleaningHeight(_ region: SpaceCleaningMeasuredRegion) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: SpaceCleaningHeightPreference.self, value: [region: geometry.size.height])
                .allowsHitTesting(false)
        })
    }
}
