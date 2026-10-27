import AppKit
import SwiftUI
import LauncherCore

struct HealthScoreRingView: View {
    let score: Int?
    var size: CGFloat = 146
    @Environment(\.workbenchPalette) private var palette
    private var unit: CGFloat { size / 200 }
    // Final care.css tones are independent of the world's cyan / amber accent.
    private var tone: Color {
        guard let score else { return color(0x7C8BAF) }
        return score >= 90 ? color(0x74DFC3) : score >= 75 ? color(0xF0C76F) : color(0xF995A1)
    }
    private var halo: Color {
        guard let score else { return color(0x7586B1, 0.12) }
        return score >= 90 ? color(0x43CFAB, 0.11) : score >= 75 ? color(0xDDA22E, 0.12) : color(0xE1636E, 0.13)
    }
    private var isAR: Bool { palette.theme == .arWorld }
    private var discColors: [Color] {
        isAR ? [color(0x70BCD7, 132 / 255.0), color(0x194D75, 140 / 255.0)]
             : [color(0x8F9987, 107 / 255.0), color(0x283C43, 102 / 255.0)]
    }
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(stops: [.init(color: halo, location: 0.28), .init(color: .clear, location: 0.68)],
                                         center: .center, startRadius: 0, endRadius: size * 0.8061))
                .frame(width: size * 1.14, height: size * 1.14).blur(radius: 8)
            Circle().fill(EllipticalGradient(colors: discColors, center: UnitPoint(x: 0.3, y: 0.1))
                .shadow(.inner(color: isAR ? color(0xD9F9FF, 112 / 255.0) : color(0xFFF1CF, 48 / 255.0),
                               radius: isAR ? 3 : 2, x: 0, y: 1)))
                .frame(width: size * 0.72, height: size * 0.72)
                .shadow(color: isAR ? color(0x063044, 45 / 255.0) : color(0x03141B, 69 / 255.0),
                        radius: 24, x: 0, y: isAR ? 8 : 10)
            Circle().stroke(palette.border, lineWidth: unit).frame(width: size * 0.91, height: size * 0.91)
            Circle().stroke(palette.soft, lineWidth: 15 * unit).frame(width: size * 0.79, height: size * 0.79)
            // The 16-unit soft shadow is behind the 11-unit foreground stroke.
            // theme.css's more-specific final override sets blur 1 / opacity .23.
            arc(lineWidth: 16 * unit).foregroundStyle(tone).blur(radius: unit).opacity(0.23)
                .offset(x: -2 * unit, y: unit)
            arc(lineWidth: 11 * unit).foregroundStyle(tone)
                .shadow(color: color(0x22435E, 0.13), radius: unit, x: 0, y: 2 * unit)
            Circle().stroke(palette.border, lineWidth: unit).frame(width: size * 0.66, height: size * 0.66)
            VStack(spacing: 0) {
                Text(score.map(String.init) ?? "—").font(.system(size: size * 0.25, weight: .semibold))
                    .tracking(-1.5).monospacedDigit().foregroundStyle(tone).frame(height: size * 0.336)
                    .shadow(color: palette.raised, radius: 0, x: 0, y: 2)
                Text(score == nil ? "数据未齐" : "设备评分").font(.system(size: max(9, size * 0.065)))
                    .foregroundStyle(palette.muted).padding(.top, 5)
            }.offset(y: 2)
        }.frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(score.map { "设备评分 \($0) 分，满分 100 分，进度从 12 点逆时针累计" } ?? "评分未知，数据尚未完整")
    }
    @ViewBuilder private func arc(lineWidth: CGFloat) -> some View {
        Group {
            if let score {
                // Zero leaves only the readable track; a full score closes the ring.
                if score > 0 {
                    Circle().trim(from: 0, to: CGFloat(min(100, score)) / 100)
                        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            } else {
                Circle().stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [12 * unit, 13 * unit]))
            }
        }
        // Circle.trim starts at 3 o'clock. Rotate to 12, then reflect X to make
        // increasing progress counter-clockwise, matching the frozen SVG matrix.
        .rotationEffect(.degrees(-90)).scaleEffect(x: -1, y: 1)
        .frame(width: size * 0.79, height: size * 0.79)
    }
    private func color(_ hex: UInt32, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255, opacity: opacity)
    }
}

struct HealthCenterView: View {
    @ObservedObject var model: HealthCenterModel
    @ObservedObject private var storage: StorageReviewService
    @ObservedObject private var device: DeviceStatusModel
    @ObservedObject private var applications: HealthApplicationReviewModel
    let onReadDevice: (DeviceHealthFactor) -> Void
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.workbenchContentHeight) private var contentHeight
    @Environment(\.workbenchDeviceExpanded) private var expanded
    @State private var availableWidth: CGFloat = 0
    @State private var pageHeaderHeight: CGFloat = 0
    @State private var pageNoticeHeight: CGFloat = 0
    @State private var fileQuery = ""
    @State private var fileFilter = "全部"
    @State private var selectedFile: StorageReviewCandidate?
    let onOpenCleaning: (() -> Void)?
    init(model: HealthCenterModel, onReadDevice: @escaping (DeviceHealthFactor) -> Void, onOpenCleaning: (() -> Void)? = nil) {
        self.onOpenCleaning = onOpenCleaning
        self.model = model; _storage = ObservedObject(wrappedValue: model.storage); _device = ObservedObject(wrappedValue: model.device)
        _applications = ObservedObject(wrappedValue: model.applications)
        self.onReadDevice = onReadDevice
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
            VStack(alignment: .leading, spacing: 0) {
                switch model.phase {
                case .overview: overview
                case .checking: if model.isSpaceCleaning { storageChecking } else { checking }
                case .report: if model.category == .overview { reportOverview } else { explorer }
                case .processing: if model.resultKind == .applications { applicationProcessing } else { processing }
                case .result: if model.resultKind == .applications { applicationResult } else { result }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(WorkbenchMaterialSurface(radius: 15))
                .accessibilityElement(children: .contain).accessibilityIdentifier("health-workspace")
            pageNotices
        }
        .foregroundStyle(palette.text)
        .background(GeometryReader { geometry in Color.clear.onAppear { availableWidth = geometry.size.width }.onChange(of: geometry.size.width) { _, width in availableWidth = width } })
        .onPreferenceChange(HealthPageHeaderHeightKey.self) { pageHeaderHeight = $0 }
        .onPreferenceChange(HealthPageNoticeHeightKey.self) { pageNoticeHeight = $0 }
        .workbenchModal(item: $selectedFile, width: 470) { fileDetails($0) }
        .workbenchModal(item: Binding(get: { storage.confirmingPlan.map(HealthPlanPresentation.init) }, set: { if $0 == nil { storage.confirmingPlan = nil } }), width: 620) { presented in
            confirmation(presented.plan)
        }
        .workbenchModal(isPresented: Binding(get: { storage.confirmingRestore != nil }, set: { if !$0 { storage.confirmingRestore = nil } }), width: 470) { restoreConfirmation }
        .workbenchModal(isPresented: Binding(get: { model.scoreDetail != nil }, set: { if !$0 { model.scoreDetail = nil } }), width: 540) {
            if let factor = model.scoreDetail { scoreDetails(factor) }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("health-center")
    }
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBPageHeader(title: "体检中心", subtitle: "了解设备状态，让每次处理都有依据") {
                Button { if let onOpenCleaning { onOpenCleaning() } else { model.showSpaceCleaning() } } label: {
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: "internaldrive").frame(width: 16, height: 16).accessibilityIdentifier("health-open-space-cleaning-icon")
                        Text("清理空间").fixedSize().accessibilityIdentifier("health-open-space-cleaning-title")
                    }.frame(minHeight: 16, alignment: .center).fixedSize(horizontal: true, vertical: false)
                }
                    .buttonStyle(WBButtonStyle()).fixedSize(horizontal: true, vertical: false).disabled(storage.isScanning || storage.isProcessing || applications.isProcessing)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("health-open-space-cleaning")
            }
            if let message = model.assessmentNotice { notice(message, symbol: "clock.arrow.circlepath").padding(.bottom, 12) }
        }.background(GeometryReader { proxy in Color.clear.preference(key: HealthPageHeaderHeightKey.self, value: proxy.size.height).allowsHitTesting(false) })
    }
    private var pageNotices: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.storageError { notice(error, symbol: "exclamationmark.triangle").padding(.top, 12) }
            if let message = storage.message { notice(message, symbol: "info.circle").padding(.top, 12) }
        }.background(GeometryReader { proxy in Color.clear.preference(key: HealthPageNoticeHeightKey.self, value: proxy.size.height).allowsHitTesting(false) })
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: overviewNarrow ? 14 : expanded ? 30 : overviewCompact ? 16 : 24) {
                HealthScoreRingView(score: model.score, size: overviewNarrow ? 110 : expanded ? 164 : overviewCompact ? 126 : 146)
                    .accessibilityIdentifier("health-overview-score")
                VStack(alignment: .leading, spacing: 8) {
                    eyebrow("设备健康", symbol: "heart.text.square")
                    Text(model.summary).font(.system(size: overviewCompact ? 21 : 23, weight: .semibold))
                    Text(model.assessmentDescription).font(.system(size: overviewCompact ? 11 : 12)).foregroundStyle(palette.secondary).lineSpacing(4)
                    HStack(spacing: 12) { Label(assessmentTime, systemImage: "clock"); Text(model.coverageText) }.font(.system(size: 11)).foregroundStyle(palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !overviewNarrow { startAction }
            }.padding(.vertical, 6)
            if overviewNarrow { startAction.padding(.leading, 124) }
            factorGrid
            scopeChoices
            HStack(spacing: 12) {
                Label("个人文件、系统进程与未保存工作默认保留", systemImage: "checkmark.shield").font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer(minLength: 0)
                historyActions
            }
        }
    }
    private var overviewCompact: Bool { availableWidth <= 826 && !expanded }
    private var overviewNarrow: Bool { availableWidth <= 576 }
    @ViewBuilder private var historyActions: some View {
        if !storage.receipts.isEmpty { historyButton(.files, title: "文件处理记录") }
        if applications.hasResults {
            historyButton(.applications, title: storage.receipts.isEmpty ? "处理记录" : "应用处理记录")
        }
    }
    private func historyButton(_ kind: HealthCenterResultKind, title: String) -> some View {
        let action: @MainActor () -> Void = { [weak model] in model?.showResults(kind: kind) }
        return Button(title, action: action).buttonStyle(WBButtonStyle(compact: true)).fixedSize()
            .disabled(!model.canShowResults)
            .accessibilityIdentifier(kind == .files ? "health-history-files" : "health-history-applications")
            .onAppear {
                #if DEBUG
                model.historyNavigationInspection?.actions[kind] = action
                #endif
            }
    }
    private var startAction: some View {
        VStack(spacing: 9) {
            Button { model.startAssessment() } label: {
                HStack(spacing: 7) { Image(systemName: "viewfinder"); Text("开始体检") }.frame(width: (overviewCompact ? 120 : 126) - 22, alignment: .center)
            }.buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("health-start")
            if !overviewNarrow { Text("检查状态，再决定是否处理").font(.system(size: overviewCompact ? 10 : 11)).foregroundStyle(palette.muted).multilineTextAlignment(.center).frame(width: 150) }
        }
    }
    private var factorGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: overviewNarrow ? 2 : 4), spacing: 12) {
            ForEach(DeviceHealthFactor.allCases, id: \.self) { factor in
                let finding = model.latestReport?.factors.first { $0.factor == factor }
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 5) {
                        Label(factor.title, systemImage: factorSymbol(factor)).font(.system(size: 11)).foregroundStyle(palette.secondary)
                        Spacer(minLength: 2)
                        Text(scoreLabel(factor, finding: finding)).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tone(finding?.severity ?? .unknown)).fixedSize()
                            .accessibilityIdentifier("health-factor-deduction-" + factor.rawValue)
                    }
                    Text(factorValue(factor)).font(.system(size: expanded ? 18 : overviewCompact ? 14 : 16, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityIdentifier("health-overview-value-" + factor.rawValue)
                    Text(finding?.summary ?? "尚无有效评估").font(.system(size: 11)).foregroundStyle(palette.muted).frame(minHeight: expanded ? 18 : 33, alignment: .topLeading)
                    HStack(spacing: 8) {
                        Button { onReadDevice(factor) } label: { Label("查看读数", systemImage: "arrow.up.right") }
                            .buttonStyle(WBButtonStyle(compact: true)).accessibilityIdentifier("health-reading-" + factor.rawValue)
                        Spacer(minLength: 0)
                        Button("评分依据") { model.scoreDetail = factor }.buttonStyle(WBTextActionButtonStyle())
                            .font(.system(size: 11)).foregroundStyle(palette.accent).fixedSize()
                            .accessibilityIdentifier("health-factor-basis-" + factor.rawValue)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(overviewCompact ? 12 : 14).background(innerSurface)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("health-overview-factor-" + factor.rawValue)
            }
        }
    }
    private func scoreLabel(_ factor: DeviceHealthFactor, finding: DeviceHealthFactorResult?) -> String {
        guard factor.isRequiredForScore else { return "不计分" }
        guard let deduction = finding?.deduction else { return "未计分" }
        return deduction == 0 ? "未扣分" : "−\(deduction) 分"
    }
    private func scoreDetails(_ factor: DeviceHealthFactor) -> some View {
        let finding = model.latestReport?.factors.first { $0.factor == factor }
        return WorkbenchDialogFrame(title: factor.title + " · 评分依据", dismiss: { model.scoreDetail = nil }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    ForEach(DeviceHealthFactor.allCases, id: \.self) { option in
                        Button(option.title) { model.scoreDetail = option }
                            .buttonStyle(WBButtonStyle(primary: option == factor, compact: true))
                    }
                }
                HStack {
                    Text(finding?.summary ?? "尚无有效评估").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text(scoreLabel(factor, finding: finding)).font(.system(size: 17, weight: .medium))
                        .foregroundStyle(tone(finding?.severity ?? .unknown))
                }
                Text(DeviceHealthRules.explanation(for: factor)).font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(5)
                if let finding {
                    Text(finding.explanation).font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(4)
                    ForEach(finding.evidence.filter { $0.key != "rule" }.indices, id: \.self) { index in
                        let evidence = HealthCenterEvidenceDisplay.text(finding.evidence.filter { $0.key != "rule" }[index])
                        HStack(alignment: .top) {
                            Text(evidence.label).foregroundStyle(palette.muted)
                            Spacer(minLength: 12)
                            Text(evidence.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }.font(.system(size: 11))
                    }
                    Text("来源：\(finding.source) · \(finding.sampledAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "未读取")")
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                Text("总分以 100 分减去存储、内存压力与系统热状态的扣分。缺少有效来源时保持未知；清理文件不会自动加分。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(4)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("health-score-detail-" + factor.rawValue)
        } actions: {
            Spacer()
            Button("知道了") { model.scoreDetail = nil }.buttonStyle(WBButtonStyle(primary: true))
        }
    }
    private var scopeChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(palette.line)
            Text("同时查找处理建议").font(.system(size: 12, weight: .medium))
            Text("健康状态会完整检查，以下范围可按需选择。文件检查只在你选定的目录进行。").font(.system(size: 11)).foregroundStyle(palette.muted)
            let layout = overviewNarrow ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                scopeToggle("可重建缓存", subtitle: "网页与临时预览", symbol: "square.3.layers.3d", enabled: $model.includeCache)
                scopeToggle("历史诊断记录", subtitle: "旧日志与崩溃记录", symbol: "doc.badge.clock", enabled: $model.includeDiagnostics)
                scopeToggle("应用内存", subtitle: "占用与身份逐项复核", symbol: "memorychip", enabled: $model.includeMemory)
            }
            storageScopeChoices
        }.padding(.top, 2)
    }
    private var storageScopeChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("选择缓存目录") { storage.chooseScope(.rebuildableCache, host: model.hostWindow) }.buttonStyle(WBButtonStyle(compact: true))
                Button("选择诊断目录") { storage.chooseScope(.diagnosticRecords, host: model.hostWindow) }.buttonStyle(WBButtonStyle(compact: true))
                Text(storage.scopes.isEmpty ? "尚未选择文件范围" : "已选择 \(storage.scopes.count) 个目录").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            ForEach(storage.scopes) { scope in
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(palette.accent)
                    Text(scope.directory.path).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button { storage.removeScope(scope.id) } label: { Image(systemName: "xmark") }.buttonStyle(WBIconButtonStyle(size: 22)).help("移除此检查范围")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("health-storage-scope-choices")
    }
    private func scopeToggle(_ title: String, subtitle: String, symbol: String, enabled: Binding<Bool>) -> some View {
        HStack(spacing: overviewCompact ? 7 : 9) {
            if !overviewCompact || overviewNarrow { iconTile(symbol, size: 28) }
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 11, weight: .medium)); Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.muted) }
            Spacer(minLength: 0); Toggle(title, isOn: enabled).labelsHidden().toggleStyle(.checkbox).clickableCursor().tint(palette.accent)
        }.padding(.horizontal, overviewCompact ? 10 : 12).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: expanded ? 70 : overviewNarrow ? 54 : 64, alignment: .leading)
            .background(innerSurface).overlay(RoundedRectangle(cornerRadius: 12).stroke(enabled.wrappedValue ? palette.accent.opacity(0.32) : .clear, lineWidth: 1))
    }
    private var checking: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) { iconTile("viewfinder", size: 42); VStack(alignment: .leading, spacing: 5) { eyebrow("正在体检", symbol: "heart.text.square"); Text(storage.isScanning ? "正在核对所选文件范围" : "正在读取设备状态").font(.system(size: 18, weight: .medium)) }; Spacer(); Button("取消体检") { model.cancelCheck() }.buttonStyle(WBButtonStyle(compact: true)) }
            HStack { Text("\(model.completedFactors.count) / 4 项设备状态已检查").font(.system(size: 12)); Spacer(); if let progress = storage.progress { Text("已检查 \(progress.checkedEntries) 项 · \(DeviceFormat.bytes(progress.logicalBytes))").font(.system(size: 11)).foregroundStyle(palette.muted) } }
            if storage.isScanning { ProgressView().progressViewStyle(.linear).tint(palette.accent) }
            else { ProgressView(value: Double(model.completedFactors.count), total: 4).tint(palette.accent) }
            VStack(spacing: 0) {
                ForEach(DeviceHealthFactor.allCases, id: \.self) { factor in
                    let result = model.completedFactors.first { $0.factor == factor }
                    HStack(spacing: 12) { iconTile(factorSymbol(factor), size: 28); VStack(alignment: .leading, spacing: 5) { Text(factor.title).font(.system(size: 12, weight: .medium)); Text(result?.explanation ?? "等待读取真实来源").font(.system(size: 11)).foregroundStyle(palette.muted) }; Spacer(); Text(result?.summary ?? "待检查").font(.system(size: 11)).foregroundStyle(tone(result?.severity ?? .unknown)) }.padding(14)
                    if factor != .battery { Divider().overlay(palette.line) }
                }
            }.background(innerSurface)
            notice("检查不会自动删除内容或退出应用。文件扫描的进度来自实际已检查条目，不估算虚假百分比。", symbol: "checkmark.shield")
        }
    }
    private var storageChecking: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                iconTile("internaldrive", size: 42)
                VStack(alignment: .leading, spacing: 5) {
                    eyebrow("清理空间", symbol: "folder.badge.gearshape")
                    Text("正在检查所选目录").font(.system(size: 18, weight: .medium))
                }
                Spacer(minLength: 0)
                Button("取消检查") { model.cancelCheck() }.buttonStyle(WBButtonStyle(compact: true))
            }
            ProgressView().progressViewStyle(.linear).tint(palette.accent)
            if let progress = storage.progress {
                Text("已检查 \(progress.checkedEntries) 项 · \(DeviceFormat.bytes(progress.logicalBytes))")
                    .font(.system(size: 12)).monospacedDigit()
            }
            notice("检查完成后逐项复核并确认，文件不会自动处理。健康评分保持原有结果。", symbol: "checkmark.shield")
        }.accessibilityIdentifier("health-space-cleaning-checking")
    }
    @ViewBuilder private var reportOverview: some View {
        if storage.selectedIDs.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                reportOverviewContents
                HStack(spacing: 6) { Image(systemName: "checkmark.shield").font(.system(size: 14)).foregroundStyle(palette.success); Text("没有项目被自动选中").font(.system(size: 11)).foregroundStyle(palette.muted) }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).padding(.top, 12).accessibilityElement(children: .contain).accessibilityIdentifier("health-report-no-selection")
            }
        } else {
            HealthPinnedReviewWorkspace(maximumHeight: reviewMaximumHeight, contentIdentifier: "health-report-content-scroll") {
                reportOverviewContents
            } footer: { selectionBar }
        }
    }
    private var reportOverviewContents: some View {
        VStack(alignment: .leading, spacing: 0) {
            reportHeader
            HStack(spacing: 12) {
                Text("本次检查已完成，处理建议由你决定。").font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    historyActions
                    Button("评分规则") { model.scoreDetail = .storage }.buttonStyle(WBQuietButtonStyle()).accessibilityIdentifier("health-report-basis")
                }.frame(height: 28)
            }.padding(.vertical, 8).overlay(alignment: .top) { palette.line.frame(height: 1) }
            reportColumns.padding(.top, 8)
        }
    }
    // These are the accepted stage breakpoints mapped to the shared page frame.
    // Both cards keep their own intrinsic contents; their ratio never changes
    // the outer page margins or writes any user preference.
    private var compactReport: Bool { availableWidth <= 826 }
    private var fullReport: Bool { availableWidth >= 1100 }
    @ViewBuilder private var reportColumns: some View {
        if availableWidth <= 576 {
            VStack(alignment: .leading, spacing: 12) { findings; advice }
        } else {
            HealthReportColumnsLayout(ratio: fullReport ? 1.12 : compactReport ? 1 : 1.08) { findings; advice }
        }
    }
    private var reportHeader: some View {
        HStack(spacing: availableWidth <= 576 ? 10 : 14) {
            if availableWidth > 576 {
                Image(systemName: model.score == nil ? "questionmark.circle" : "checkmark.shield").font(.system(size: 25)).foregroundStyle(tone(model.latestReport?.severity ?? .unknown))
                    .frame(width: 44, height: 44).background(tone(model.latestReport?.severity ?? .unknown).opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(tone(model.latestReport?.severity ?? .unknown).opacity(0.25), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("体检报告 · " + assessmentTime).font(.system(size: 11)).foregroundStyle(palette.muted).frame(minHeight: 16, alignment: .leading)
                Text(model.summary).font(.system(size: compactReport ? 18 : 20, weight: .semibold)).tracking(-0.3).frame(minHeight: compactReport ? 25.2 : 28, alignment: .leading).padding(.top, 5).padding(.bottom, 7)
                Text(model.assessmentDescription).font(.system(size: compactReport ? 11 : 12)).foregroundStyle(palette.secondary).lineSpacing(6).fixedSize(horizontal: false, vertical: true).frame(minHeight: 20, alignment: .leading)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                Text(model.score.map { "\($0) 分" } ?? "待评估").font(.system(size: compactReport ? 21 : 24)).foregroundStyle(tone(model.latestReport?.severity ?? .unknown)).monospacedDigit()
                Text(model.coverageText).font(.system(size: 11)).foregroundStyle(palette.muted)
            }.fixedSize(horizontal: true, vertical: false).padding(.leading, 8)
        }.padding(.top, 4).padding(.bottom, 14)
    }
    private var reportFactors: [DeviceHealthFactorResult] { model.latestReport?.factors ?? [] }
    private var reportIssues: [DeviceHealthFactorResult] { reportFactors.filter { $0.state == .evaluated && ($0.severity == .watch || $0.severity == .urgent) } }
    private var reportGood: [DeviceHealthFactorResult] { reportFactors.filter { $0.state == .evaluated && $0.severity == .good } }
    private var reportMissing: [DeviceHealthFactorResult] { reportFactors.filter { $0.state != .evaluated } }
    private var findings: some View {
        VStack(alignment: .leading, spacing: 0) {
            reportSectionHeading("健康发现", subtitle: "根据持续状态与有效来源判断。")
            VStack(alignment: .leading, spacing: 8) {
                if reportIssues.isEmpty {
                    findingSummary
                } else {
                    ForEach(reportIssues) { item in findingIssue(item) }
                }
                if !reportGood.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(reportGood) { item in
                            Button { onReadDevice(item.factor) } label: {
                                HStack(spacing: 12) {
                                    HStack(spacing: 6) { Image(systemName: "checkmark").font(.system(size: 13)).foregroundStyle(palette.success); Text(item.factor.title) }
                                    Spacer(minLength: 0)
                                    Text(factorValue(item.factor)).lineLimit(1).multilineTextAlignment(.trailing)
                                }.font(.system(size: 11)).foregroundStyle(palette.secondary).frame(maxWidth: .infinity, minHeight: 33).contentShape(Rectangle())
                            }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 6, drawsSelection: false, showsBorder: false)).help("查看" + item.factor.title + "读数").accessibilityIdentifier("health-checked-" + item.factor.rawValue)
                        }
                    }.padding(.top, 5).overlay(alignment: .top) { palette.line.frame(height: 1) }.padding(.top, 5)
                }
                if !reportMissing.isEmpty && reportMissing.count < reportFactors.count {
                    HStack(alignment: .top, spacing: 7) { Image(systemName: "questionmark.circle").font(.system(size: 13)).padding(.top, 3); Text(missingFindingNote).font(.system(size: 11)).lineSpacing(5).fixedSize(horizontal: false, vertical: true) }.foregroundStyle(palette.muted).padding(.top, 8).accessibilityElement(children: .contain).accessibilityIdentifier("health-missing-footnote")
                }
            }
        }.padding(compactReport ? 12 : 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(innerSurface).accessibilityElement(children: .contain).accessibilityIdentifier("health-report-findings")
    }
    private var advice: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: compactReport ? .top : .center, spacing: 8) {
                reportSectionHeading("可选处理建议", subtitle: "以下内容不等于健康问题；可以只查看，按需选择。", bottom: 0)
                Spacer(minLength: 0)
                Button { model.startAssessment() } label: { Text("重新体检").font(.system(size: compactReport ? 10 : 11)) }.buttonStyle(WBQuietButtonStyle()).fixedSize()
            }.padding(.bottom, 12)
            VStack(spacing: 0) {
                ForEach(adviceCategories, id: \.self) { item in
                    Button { model.showCategory(item) } label: {
                        HStack(spacing: compactReport ? 7 : 10) {
                            if !compactReport { iconTile(item.symbol, size: 28) }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.system(size: 12, weight: .medium))
                                Text(categoryDescription(item)).font(.system(size: 11)).foregroundStyle(palette.muted).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(categorySize(item)).font(.system(size: compactReport ? 11 : 12, weight: .medium)).foregroundStyle(palette.secondary).fixedSize()
                            HStack(spacing: 3) { if fullReport { Text("复核").font(.system(size: 11)) }; Image(systemName: "chevron.right").font(.system(size: 11)) }.foregroundStyle(palette.accent)
                        }.padding(.top, 12).padding(.bottom, item == adviceCategories.last ? 0 : 12).frame(maxWidth: .infinity, minHeight: fullReport ? 82 : 70, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 6, drawsSelection: false, showsBorder: false)).accessibilityIdentifier("health-advice-" + item.rawValue)
                    if item != adviceCategories.last { palette.line.frame(height: 1) }
                }
                if adviceCategories.isEmpty { Text("本次仅检查设备健康，未选择额外建议范围。").font(.system(size: 11)).foregroundStyle(palette.muted).padding(.vertical, 20).frame(maxWidth: .infinity) }
            }.overlay(alignment: .top) { palette.line.frame(height: 1) }
            if let report = storage.report, !report.issues.isEmpty { notice("\(report.issues.count) 项范围或文件未能完整检查，明细保留原因。", symbol: "info.circle").padding(.top, 10) }
        }.padding(compactReport ? 12 : 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(innerSurface).accessibilityElement(children: .contain).accessibilityIdentifier("health-report-advice")
    }
    private var adviceCategories: [HealthCenterCategory] {
        [HealthCenterCategory.cache, .diagnostics, .memory].filter { $0 == .cache && model.includeCache || $0 == .diagnostics && model.includeDiagnostics || $0 == .memory && model.includeMemory }
    }
    private func reportSectionHeading(_ title: String, subtitle: String, bottom: CGFloat = 12) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, bottom).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var findingSummary: some View {
        let unknown = reportGood.isEmpty
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: unknown ? "questionmark.circle" : "checkmark.circle").font(.system(size: 16)).foregroundStyle(unknown ? palette.muted : palette.success)
                .frame(width: 28, height: 28).background(palette.soft, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 6) {
                Text(unknown ? "暂无可评价的健康信息" : "已知健康指标未见异常").font(.system(size: 12, weight: .medium)).frame(minHeight: 19, alignment: .leading)
                Text(unknown ? "补齐来源或持续观察后再重新评估，不以缺失数据推断正常。" : "当前无需为了提高分数而主动整理或退出应用。").font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.top, 12).padding(.bottom, 3).overlay(alignment: .top) { palette.line.frame(height: 1) }
    }
    private func findingIssue(_ item: DeviceHealthFactorResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: factorSymbol(item.factor)).font(.system(size: 16)).foregroundStyle(tone(item.severity)).frame(width: 28, height: 28).background(palette.soft, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.factor == .storage ? "存储余量需留意" : item.factor.title + " · " + factorValue(item.factor)).font(.system(size: 12, weight: .medium)).frame(minHeight: 19, alignment: .leading)
                    Text(findingNote(item)).font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { onReadDevice(item.factor) } label: { Label("查看状态", systemImage: "arrow.up.right").frame(height: 18) }.buttonStyle(WBQuietButtonStyle()).padding(.leading, 38).accessibilityIdentifier("health-finding-reading-" + item.factor.rawValue)
        }.padding(.top, 12).padding(.bottom, 3).overlay(alignment: .top) { palette.line.frame(height: 1) }
    }
    private func findingNote(_ item: DeviceHealthFactorResult) -> String {
        func evidence(_ key: String) -> String? { item.evidence.first { $0.key == key }.map { HealthCenterEvidenceDisplay.text($0).value } }
        switch item.factor {
        case .storage:
            return [factorValue(.storage), evidence("availableFraction").map { $0 + " 可用" }].compactMap { $0 }.joined(separator: " · ")
        case .memory:
            let duration = evidence("sustainedSeconds").map { "持续 " + $0 }
            let swap = evidence("swapUsedBytes").map { "交换 " + $0 }
            return [duration, swap].compactMap { $0 }.isEmpty ? item.summary : [duration, swap].compactMap { $0 }.joined(separator: " · ")
        case .thermal:
            return [item.summary, evidence("sustainedSeconds").map { "持续 " + $0 }].compactMap { $0 }.joined(separator: " · ")
        case .battery: return item.summary
        }
    }
    private var missingFindingNote: String {
        let states: [(DeviceHealthCheckState, String)] = [(.missing, "尚未读取"), (.observing, "仍在持续观察"), (.permissionDenied, "尚未获得读取权限"), (.stale, "读数已过期"), (.failed, "来源读取失败"), (.cancelled, "检查已取消")]
        return states.compactMap { state, message -> String? in
            let names = reportMissing.filter { $0.state == state }.map { $0.factor.title }
            return names.isEmpty ? nil : names.joined(separator: "、") + message
        }.joined(separator: "；") + "，未计入本次评分"
    }
    private var reviewMaximumHeight: CGFloat? {
        contentHeight > 0 ? max(96, contentHeight - pageHeaderHeight - pageNoticeHeight - 28) : nil
    }
    private var explorer: some View {
        HealthPinnedReviewWorkspace(maximumHeight: reviewMaximumHeight,
            contentIdentifier: model.category == .memory ? "health-application-review-content-scroll" : "health-file-review-content-scroll") {
            explorerContents
        } footer: {
            if model.category == .memory { applicationSelectionBar }
            else { selectionBar }
        }
    }
    private var explorerContents: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { if model.isSpaceCleaning { model.showOverview() } else { model.showReport() } } label: { Label(model.isSpaceCleaning ? "体检中心" : "体检报告", systemImage: "arrow.left") }.buttonStyle(WBButtonStyle(compact: true))
                palette.line.frame(width: 1, height: 16)
                Text(model.isSpaceCleaning ? "清理空间" : model.category.title).font(.system(size: 12)).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                historyActions
                Button(model.isSpaceCleaning ? "检查所选目录" : "重新体检") { if model.isSpaceCleaning { model.startStorageScan() } else { model.startAssessment() } }.buttonStyle(WBButtonStyle(compact: true))
                    .disabled(model.isSpaceCleaning && storage.scopes.isEmpty)
            }.frame(height: 28).padding(.bottom, 12).overlay(alignment: .bottom) { palette.line.frame(height: 1) }
            VStack(alignment: .leading, spacing: 6) {
                Text("逐项复核，再决定是否处理").font(.system(size: 17, weight: .medium))
                Text(model.category == .memory ? "占用大小不代表异常。只对你明确选择的应用请求正常退出。" : "查看内容归属与影响，个人文件和正在使用的内容默认保留。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 14)
            if model.isSpaceCleaning { storageScopeChoices.padding(.bottom, 14) }
            HStack(alignment: .top, spacing: compactReport ? 12 : 14) {
                explorerCategories
                if model.category == .memory {
                    HealthApplicationCandidatesView(model: applications, compact: compactReport, listHeight: explorerListHeight)
                } else { fileCandidates }
            }
        }
    }
    private var explorerListHeight: CGFloat { fullReport ? 365 : compactReport ? 240 : 252 }
    private var explorerSidebarWidth: CGFloat { availableWidth <= 576 ? 132 : fullReport ? 208 : compactReport ? 156 : 180 }
    private var explorerCategories: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(model.isSpaceCleaning ? [.cache, .diagnostics] : [HealthCenterCategory.cache, .diagnostics, .memory], id: \.self) { category in
                Button { model.showCategory(category) } label: {
                    HStack(spacing: compactReport ? 6 : 8) {
                        if !compactReport {
                            Image(systemName: category.symbol).font(.system(size: 15)).foregroundStyle(palette.accent)
                                .frame(width: 26, height: 29).background(palette.soft, in: RoundedRectangle(cornerRadius: 7))
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(category.title).font(.system(size: 11, weight: .medium))
                            Text(categorySize(category)).font(.system(size: 11)).foregroundStyle(palette.muted)
                        }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: 11))
                    }.foregroundStyle(model.category == category ? palette.accent : palette.secondary)
                        .padding(.horizontal, compactReport ? 5 : 8).padding(.vertical, 10)
                        .background(model.category == category ? palette.soft : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(model.category == category ? palette.accent.opacity(0.3) : .clear, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 9, drawsSelection: false, showsBorder: false)).accessibilityIdentifier("health-review-category-" + category.rawValue)
            }
            Spacer(minLength: 12)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "checkmark.shield").font(.system(size: 14)).foregroundStyle(palette.success).padding(.top, 3)
                Text(model.isSpaceCleaning ? "保留个人文件\n处理前逐项确认" : "保留个人文件\n退出前先保存工作").font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(7)
            }.padding(.top, 18).padding(.horizontal, 8).padding(.bottom, 4)
        }.frame(width: explorerSidebarWidth - (compactReport ? 9 : 12), height: max(280, explorerListHeight + 36), alignment: .topLeading)
            .padding(.trailing, compactReport ? 9 : 12).overlay(alignment: .trailing) { palette.line.frame(width: 1) }
    }
    private var fileCandidates: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("搜索文件名或路径", text: $fileQuery).textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
                    .accessibilityIdentifier("health-file-search")
                WBSelect("显示", selection: $fileFilter, options: [("全部", "全部"), ("可复核", "可复核"), ("保留", "保留")]).frame(width: 100)
                Button("全选可复核") { storage.selectAll(filteredFiles) }.buttonStyle(WBButtonStyle(compact: true))
                    .disabled(!filteredFiles.contains(where: storage.canSelect))
                Button("清空选择") { storage.selectedIDs.removeAll() }
                    .buttonStyle(WBButtonStyle(compact: true)).disabled(storage.selectedIDs.isEmpty || storage.isProcessing)
                    .accessibilityIdentifier("health-files-clear-selection")
            }.frame(height: 32).accessibilityElement(children: .contain).accessibilityIdentifier("health-file-tools")
                .padding(.bottom, 4)
            WorkbenchScrollView { LazyVStack(spacing: 0) { ForEach(filteredFiles) { file in fileRow(file) }; if filteredFiles.isEmpty { emptyFiles } } }
                .frame(height: explorerListHeight).background(innerSurface)
                .accessibilityElement(children: .contain).accessibilityIdentifier("health-file-candidates")
            if let report = storage.report, !report.issues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.issues.prefix(5).indices, id: \.self) { index in let issue = report.issues[index]; Text(issue.relativePath + " · " + issue.reason).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2) }
                }.padding(.top, 8)
            }
        }.frame(maxWidth: .infinity)
    }
    private var applicationSelectionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("已选 \(applications.selectedIDs.count) 个应用").font(.system(size: 12, weight: .medium))
                Text("仅请求正常退出 · 内存变化以新采样为准").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            Spacer(minLength: 0)
            Button { applications.prepareConfirmation() } label: { Label("处理所选项目", systemImage: "arrow.right") }
                .buttonStyle(WBButtonStyle(primary: true)).disabled(applications.selectedIDs.isEmpty || applications.isProcessing)
                .accessibilityIdentifier("health-application-selection")
        }.frame(minHeight: 36).padding(14).background(palette.raised)
            .overlay(alignment: .top) { palette.line.frame(height: 1) }
            .padding(.horizontal, -14).padding(.bottom, -14).padding(.top, 14)
            .accessibilityElement(children: .contain).accessibilityIdentifier("health-application-selection-bar")
    }
    private var emptyFiles: some View {
        VStack(spacing: 12) { Image(systemName: "folder").font(.system(size: 26)).foregroundStyle(palette.muted); Text(storage.report == nil ? "尚未选择并检查文件范围" : "当前筛选下没有文件").font(.system(size: 12)); if storage.report == nil { Button("选择检查目录") { storage.chooseScope(model.category == .cache ? .rebuildableCache : .diagnosticRecords, host: model.hostWindow) }.buttonStyle(WBButtonStyle(compact: true)); Button("开始检查") { if model.isSpaceCleaning { model.startStorageScan() } else { model.startAssessment() } }.buttonStyle(WBButtonStyle(primary: true, compact: true)).disabled(model.isSpaceCleaning && storage.scopes.isEmpty) } }.padding(24).frame(maxWidth: .infinity, minHeight: 220)
    }
    private func fileRow(_ file: StorageReviewCandidate) -> some View {
        let status = storage.candidateStatus(for: file)
        return HStack(alignment: .top, spacing: 8) {
            Toggle(file.relativePath, isOn: Binding(get: { status.isSelectable && storage.selectedIDs.contains(file.id) }, set: { _ in storage.toggle(file) })).labelsHidden().toggleStyle(.checkbox).clickableCursor().disabled(!storage.canSelect(file))
                .accessibilityIdentifier("health-file-select-" + file.id.uuidString)
            if !compactReport {
                Image(systemName: file.category == .symbolicLink ? "link" : "doc").font(.system(size: 15)).foregroundStyle(palette.accent)
                    .frame(width: 27, height: 29).background(palette.soft, in: RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
            }
            Button { selectedFile = file } label: { VStack(alignment: .leading, spacing: 5) { Text(URL(fileURLWithPath: file.relativePath).lastPathComponent).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text); Text(file.relativePath).font(.system(size: 10)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle); Text(status == .pendingReview || status == .retained ? file.explanation : status.explanation).font(.system(size: 10)).foregroundStyle(palette.muted).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 6, drawsSelection: false, showsBorder: false))
                .accessibilityIdentifier("health-file-details-" + file.id.uuidString)
            VStack(alignment: .trailing, spacing: 6) {
                Text(DeviceFormat.bytes(file.logicalBytes)).font(.system(size: 11))
                Text(status.label).font(.system(size: 10)).foregroundStyle(palette.muted).fixedSize()
                    .accessibilityIdentifier("health-file-state-" + file.id.uuidString)
            }
            Button { selectedFile = file } label: { Image(systemName: "info.circle").font(.system(size: 14)) }
                .buttonStyle(WBIconButtonStyle(size: 28))
                .help("查看文件明细").accessibilityLabel("查看" + URL(fileURLWithPath: file.relativePath).lastPathComponent + "明细")
                .accessibilityIdentifier("health-file-info-" + file.id.uuidString)
        }.padding(10).overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
            .accessibilityElement(children: .contain).accessibilityIdentifier("health-file-row-" + file.id.uuidString)
    }
    private var selectionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) { Text("已选 \(storage.selectedCandidateCount) 项").font(.system(size: 12, weight: .medium)); Text("移到废纸篓 · \(DeviceFormat.bytes(storage.selectedBytes))").font(.system(size: 11)).foregroundStyle(palette.muted) }
            Spacer()
            Button { storage.prepareProcessing() } label: { Label("处理所选项目", systemImage: "arrow.right") }.buttonStyle(WBButtonStyle(primary: true)).disabled(storage.selectedCandidateCount == 0 || storage.isScanning || storage.isProcessing).accessibilityIdentifier("health-review-selection")
        }.frame(minHeight: 36).padding(14).background(palette.raised)
            .overlay(alignment: .top) { palette.line.frame(height: 1) }
            .padding(.horizontal, -14).padding(.bottom, -14).padding(.top, 14)
            .accessibilityElement(children: .contain).accessibilityIdentifier("health-file-selection-bar")
    }
    private var processing: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("正在处理已确认的项目").font(.system(size: 18, weight: .medium)); Spacer(); Button("取消后续处理") { storage.cancel() }.buttonStyle(WBButtonStyle(compact: true)) }
            Text("\(storage.processedCount) / \(storage.plannedCount) 项").font(.system(size: 24)).foregroundStyle(palette.accent)
            ProgressView(value: Double(storage.processedCount), total: Double(max(1, storage.plannedCount))).tint(palette.accent)
            receiptList
            notice("每项操作前核验真实文件身份，只移到可恢复的废纸篓。已完成部分不会因取消而被隐瞒。", symbol: "checkmark.shield")
        }
    }
    private var applicationProcessing: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                iconTile("checklist", size: 42)
                VStack(alignment: .leading, spacing: 5) {
                    eyebrow("正在处理已确认的内容", symbol: "checkmark.shield")
                    Text("逐项核验并请求正常退出").font(.system(size: 18, weight: .medium))
                }
                Spacer(minLength: 0)
                Button(applications.cancelRequested ? "正在停止后续请求…" : "取消后续处理") { applications.cancelRemaining() }
                    .buttonStyle(WBButtonStyle(compact: true)).disabled(applications.cancelRequested)
            }
            HStack {
                Text("\(applications.completedCount) / \(applications.results.count) 项已记录").font(.system(size: 12))
                Spacer(minLength: 0)
                Text("请求进度").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            ProgressView(value: Double(applications.completedCount), total: Double(max(1, applications.results.count))).tint(palette.accent)
            HealthApplicationResultLog(model: applications)
            notice("只向明确选择并确认的应用发送正常退出请求。取消会停止尚未发送的请求，当前请求会先完成真实记录。", symbol: "checkmark.shield")
        }
    }
    private var applicationResult: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                iconTile(applications.requestedCount > 0 ? "checkmark" : "info.circle", size: 48)
                VStack(alignment: .leading, spacing: 7) {
                    eyebrow("处理记录", symbol: "clock")
                    Text(applications.requestedCount > 0 ? "已提交应用退出请求" : "已完成本次复核").font(.system(size: 21, weight: .medium))
                    Text(applicationOutcomeText).font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 4)
            HStack(spacing: 20) {
                resultMetric("当前可用空间", value: device.snapshot.disk.map { DeviceFormat.storage($0.available) } ?? "—", detail: "未处理文件")
                resultMetric("内存压力", value: DeviceFormat.pressure(device.snapshot.memory?.pressure ?? .unknown), detail: model.waitingForFreshSample ? "等待后续有效采样" : "以有效设备采样为准")
                resultMetric("最近评分", value: model.score.map(String.init) ?? "—", detail: "未因处理自动加分")
            }.padding(14).background(innerSurface)
            notice("请求已发送不代表应用已关闭或内存已释放。应用可能正在等待保存确认，继续按后续有效设备状态评估。", symbol: "info.circle")
            HealthApplicationResultLog(model: applications)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("重新体检") { model.showOverview() }.buttonStyle(WBButtonStyle())
                Button("查看本次报告") { model.showReport() }.buttonStyle(WBButtonStyle())
            }.padding(.top, 12)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("health-application-results")
    }
    private var applicationOutcomeText: String {
        let failed = applications.results.filter { $0.state == .failed }.count
        let skipped = applications.results.filter { $0.state == .skipped }.count
        let cancelled = applications.results.filter { $0.state == .cancelled }.count
        return "\(applications.requestedCount) 个应用已请求正常退出 · 失败 \(failed) 项 · 跳过 \(skipped) 项 · 未发送 \(cancelled) 项"
    }
    private var result: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) { iconTile("checkmark", size: 48); VStack(alignment: .leading, spacing: 7) { eyebrow("处理记录", symbol: "clock"); Text(storage.lastOperationID == nil ? "最近处理记录" : "已完成本次复核").font(.system(size: 21, weight: .medium)); Text(storage.lastOperationID == nil ? "按实际记录查看、核对或恢复文件。" : "本次已移到废纸篓 \(storage.receipts.filter { $0.operationID == storage.lastOperationID && $0.result.state == .trashed && $0.restoredAt == nil }.count) 项，失败与跳过分别保留结果。").font(.system(size: 12)).foregroundStyle(palette.secondary) } }
            HStack(spacing: 20) {
                resultMetric("当前可用空间", value: device.snapshot.disk.map { DeviceFormat.storage($0.available) } ?? "—", detail: "以真实设备采样为准")
                resultMetric("内存压力", value: DeviceFormat.pressure(device.snapshot.memory?.pressure ?? .unknown), detail: model.waitingForFreshSample ? "等待后续有效采样" : "已按真实状态重新评估")
                resultMetric("最近评分", value: model.score.map(String.init) ?? "—", detail: "未因处理自动加分")
            }.padding(14).background(innerSurface)
            notice("移到废纸篓仍可能占用磁盘，文件大小不等于实际释放空间。继续按实际设备状态评估。", symbol: "info.circle")
            receiptList
            HStack(spacing: 8) { Spacer(); Button("重新体检") { model.showOverview() }.buttonStyle(WBButtonStyle()); Button(model.isSpaceCleaning ? "返回清理空间" : "查看本次报告") { if model.isSpaceCleaning { model.showSpaceCleaning() } else { model.showReport() } }.buttonStyle(WBButtonStyle()) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("health-file-results")
    }
    private var receiptList: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("处理记录").font(.system(size: 12, weight: .medium))
            if storage.receipts.isEmpty { Text("尚未处理文件。").font(.system(size: 11)).foregroundStyle(palette.muted) }
            ForEach(storage.receipts.suffix(30).reversed()) { receipt in
                HStack(spacing: 8) {
                    Image(systemName: receipt.restoredAt != nil ? "arrow.uturn.backward" : receipt.result.state == .trashed ? "checkmark" : "info.circle").foregroundStyle(receipt.result.state == .trashed ? palette.success : palette.warning)
                    VStack(alignment: .leading, spacing: 4) { Text(receipt.candidate.relativePath).font(.system(size: 11)).lineLimit(1).truncationMode(.middle); Text(receipt.restoredAt != nil ? "已恢复到原位置" : receipt.result.reason).font(.system(size: 10)).foregroundStyle(palette.muted) }.frame(maxWidth: .infinity, alignment: .leading)
                    if receipt.restoredAt == nil {
                        if receipt.result.trashURL != nil { Button(receipt.requiresManualReview == true ? "核对" : "查看") { storage.revealReceipt(receipt) }.buttonStyle(WBButtonStyle(compact: true)) }
                        if receipt.result.state == .trashed { Button("恢复") { storage.confirmingRestore = receipt.id }.buttonStyle(WBButtonStyle(compact: true)).disabled(storage.isProcessing || receipt.trashIdentity == nil || receipt.requiresManualReview == true) }
                    }
                }.padding(.vertical, 6)
            }
            Label("个人文件、符号链接与未保存工作保持原有保护", systemImage: "checkmark.shield").font(.system(size: 11)).foregroundStyle(palette.muted)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(innerSurface)
    }
    private func confirmation(_ plan: StorageReviewTrashPlan) -> some View {
        let files = storage.report?.candidates.filter { plan.selectedCandidateIDs.contains($0.id) } ?? []
        return WorkbenchDialogFrame(title: "确认处理所选项目", dismiss: { storage.confirmingPlan = nil }) {
            VStack(alignment: .leading, spacing: 14) {
                dialogBanner("sparkles", title: "\(plan.selectedCandidateIDs.count) 项空间内容", detail: "移到废纸篓 · \(DeviceFormat.bytes(plan.logicalBytes))")
                WorkbenchScrollView {
                    VStack(spacing: 0) {
                        ForEach(files) { file in
                            HStack(spacing: 12) { Text(file.relativePath).lineLimit(1).truncationMode(.middle); Spacer(minLength: 0); Text(DeviceFormat.bytes(file.logicalBytes)).fixedSize() }.font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.vertical, 9).overlay(alignment: .bottom) { palette.line.frame(height: 1) }
                        }
                    }
                }.frame(height: min(210, CGFloat(max(1, files.count)) * 34))
                Text("请确认所选内容归属、可重建性，并已关闭相关文件。处理前再次核验身份与范围，变化项目将跳过；本次不会退出应用或永久删除文件。").font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Spacer(); Button("返回选择") { storage.confirmingPlan = nil }.buttonStyle(WBButtonStyle())
            Button("确认处理") { model.beginProcessing() }.buttonStyle(WBButtonStyle(primary: true)).accessibilityLabel("确认移到废纸篓").accessibilityIdentifier("health-confirm-trash")
        }
    }
    private func fileDetails(_ file: StorageReviewCandidate) -> some View {
        let title = URL(fileURLWithPath: file.relativePath).lastPathComponent
        let status = storage.candidateStatus(for: file)
        return WorkbenchDialogFrame(title: title, dismiss: { selectedFile = nil }) {
            VStack(alignment: .leading, spacing: 14) {
                dialogBanner("doc", title: title, detail: file.relativePath + " · " + DeviceFormat.bytes(file.logicalBytes))
                Text(file.explanation).font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                if status != .pendingReview && status != .retained {
                    Text(status.label + "。" + status.explanation).font(.system(size: 11)).foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("修改时间：\(Date(timeIntervalSince1970: Double(file.identity.modifiedSeconds)).formatted())\n文件身份：\(file.identity.fileKey)\n未读取文件正文；处理前重新核验。").font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        } actions: { Spacer(); Button("返回明细") { selectedFile = nil }.buttonStyle(WBButtonStyle(primary: true)) }
    }
    private var restoreConfirmation: some View {
        WorkbenchDialogFrame(title: "恢复到原位置？", dismiss: { storage.confirmingRestore = nil }) {
            VStack(alignment: .leading, spacing: 14) {
                if let receipt = storage.receipts.first(where: { $0.id == storage.confirmingRestore }) {
                    dialogBanner("arrow.uturn.backward", title: URL(fileURLWithPath: receipt.candidate.relativePath).lastPathComponent, detail: receipt.candidate.relativePath)
                }
                Text("仅恢复仍可核验的废纸篓文件。原位置已存在内容时不会覆盖，文件发生变化时保留现状并提示你核对。").font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Spacer(); Button("取消") { storage.confirmingRestore = nil }.buttonStyle(WBButtonStyle())
            Button("恢复文件") { storage.restoreConfirmedItem() }.buttonStyle(WBButtonStyle(primary: true))
        }
    }
    private func dialogBanner(_ symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).background(RoundedRectangle(cornerRadius: 11).fill(palette.soft).overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(palette.line, lineWidth: 1)))
    }
    private func dialogFact(_ name: String, _ value: String) -> some View {
        HStack(spacing: 12) { Text(name).foregroundStyle(palette.muted); Spacer(minLength: 0); Text(value).foregroundStyle(palette.secondary).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.system(size: 11)).padding(.vertical, 9).overlay(alignment: .bottom) { palette.line.frame(height: 1) }
    }
    private var filteredFiles: [StorageReviewCandidate] {
        let group = storage.report?.candidates.filter { file in
            guard let scope = storage.report?.scopes.first(where: { $0.scope.id == file.scopeID }) else { return false }
            return model.category == .cache ? scope.scope.kind == .rebuildableCache : scope.scope.kind == .diagnosticRecords
        } ?? []
        return group.filter { file in (fileQuery.isEmpty || file.relativePath.localizedStandardContains(fileQuery)) && (fileFilter == "全部" || fileFilter == "可复核" && storage.canSelect(file) || fileFilter == "保留" && storage.candidateStatus(for: file) == .retained) }
    }
    private var assessmentTime: String { model.latestReport.map { $0.finishedAt.formatted(date: .omitted, time: .shortened) + (model.showingPreviousReport ? " · 上次体检" : $0.isCurrent(at: Date()) ? "" : " · 历史评估") } ?? "尚无有效评估" }
    private var innerSurface: some View { RoundedRectangle(cornerRadius: 12).fill(palette.soft).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.line, lineWidth: 1)) }
    private func factorValue(_ factor: DeviceHealthFactor) -> String {
        let item = model.latestReport?.factors.first { $0.factor == factor }
        guard item?.state == .evaluated || item?.state == .observing else { return item?.summary ?? "等待读取" }
        switch factor { case .storage: return item?.evidence.first(where: { $0.key == "availableBytes" }).flatMap { UInt64($0.value) }.map { DeviceFormat.bytes($0) + " 可用" } ?? "未读取"
        case .memory: return DeviceFormat.pressure(item?.evidence.first(where: { $0.key == "pressure" }).flatMap { DevicePressure(rawValue: $0.value) } ?? .unknown)
        case .thermal: return item?.summary ?? "未读取"
        case .battery: return item?.summary ?? "未读取" }
    }
    private func categoryDescription(_ category: HealthCenterCategory) -> String {
        switch category { case .cache: "只检查明确选定的目录，逐项确认可重建性"; case .diagnostics: "旧日志可按需复核，排查历史问题时建议保留"; case .memory: "按真实应用身份与内存压力复核，不自动退出"; case .overview: "根据有效来源查看健康发现" }
    }
    private func categorySize(_ category: HealthCenterCategory) -> String {
        if category == .memory { return applications.sourceIsCurrent ? "\(applications.eligibleCount) 个可复核应用" : "等待读取" }
        guard let report = storage.report else { return "未检查" }
        let list = report.candidates.filter { (category == .cache ? $0.category == .cacheCandidate : $0.category == .oldDiagnostic) && storage.candidateStatus(for: $0).isSelectable }
        return DeviceFormat.bytes(list.reduce(0) { total, file in let sum = total.addingReportingOverflow(file.logicalBytes); return sum.overflow ? .max : sum.partialValue })
    }
    private func factorSymbol(_ factor: DeviceHealthFactor) -> String { switch factor { case .storage: "internaldrive"; case .memory: "memorychip"; case .thermal: "fan"; case .battery: "battery.100" } }
    private func tone(_ severity: DeviceHealthSeverity) -> Color { switch severity { case .good: palette.success; case .watch: palette.warning; case .urgent: palette.critical; case .unknown: palette.muted } }
    private func eyebrow(_ title: String, symbol: String) -> some View { Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(palette.secondary) }
    private func iconTile(_ symbol: String, size: CGFloat) -> some View { Image(systemName: symbol).font(.system(size: size > 35 ? 22 : 15)).foregroundStyle(palette.accent).frame(width: size, height: size).background(palette.soft, in: RoundedRectangle(cornerRadius: size > 35 ? 12 : 8)) }
    private func notice(_ text: String, symbol: String) -> some View { Label(text, systemImage: symbol).font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading) }
    private func resultMetric(_ title: String, value: String, detail: String) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 11)).foregroundStyle(palette.muted); Text(value).font(.system(size: 23)).foregroundStyle(palette.text); Text(detail).font(.system(size: 11)).foregroundStyle(palette.muted) }.frame(maxWidth: .infinity, alignment: .leading) }
}
private struct HealthPlanPresentation: Identifiable { let plan: StorageReviewTrashPlan; var id: UUID { plan.reportID }; init(_ plan: StorageReviewTrashPlan) { self.plan = plan } }

private struct HealthPageHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct HealthPageNoticeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct HealthReviewBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct HealthReviewFooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Equivalent to the accepted sticky footer: when the review exceeds the
/// visible page, its body scrolls while the selection bar stays outside it.
/// Short content retains its natural height, including in a full-screen window.
private struct HealthPinnedReviewWorkspace<Content: View, Footer: View>: View {
    let maximumHeight: CGFloat?
    let contentIdentifier: String
    let content: Content
    let footer: Footer
    @State private var bodyHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 64
    init(maximumHeight: CGFloat?, contentIdentifier: String = "health-application-review-content-scroll", @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.maximumHeight = maximumHeight; self.contentIdentifier = contentIdentifier; self.content = content(); self.footer = footer()
    }
    var body: some View {
        if let maximumHeight {
            VStack(alignment: .leading, spacing: 0) {
                WorkbenchScrollView {
                    content.fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: HealthReviewBodyHeightKey.self, value: proxy.size.height).allowsHitTesting(false)
                        })
                }.frame(height: min(bodyHeight > 0 ? bodyHeight : maximumHeight, max(0, maximumHeight - footerHeight)))
                    .scrollBounceBehavior(.basedOnSize)
                    .accessibilityElement(children: .contain).accessibilityIdentifier(contentIdentifier)
                footer.background(GeometryReader { proxy in
                    Color.clear.preference(key: HealthReviewFooterHeightKey.self, value: proxy.size.height).allowsHitTesting(false)
                })
            }
            .onPreferenceChange(HealthReviewBodyHeightKey.self) { if abs(bodyHeight - $0) > 0.25 { bodyHeight = $0 } }
            .onPreferenceChange(HealthReviewFooterHeightKey.self) { if abs(footerHeight - $0) > 0.25 { footerHeight = $0 } }
        } else {
            VStack(alignment: .leading, spacing: 0) { content; footer }
        }
    }
}

/// CSS grid's two fractional columns, including its equal-height surfaces.
/// Width comes from the shared card's actual content proposal, not page padding.
private struct HealthReportColumnsLayout: Layout {
    var ratio: CGFloat
    private let gap: CGFloat = 12
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? subviews.reduce(gap) { $0 + $1.sizeThatFits(.unspecified).width }
        let left = max(0, width - gap) / (1 + ratio)
        let heights = [subviews[0].sizeThatFits(.init(width: left, height: nil)).height, subviews[1].sizeThatFits(.init(width: left * ratio, height: nil)).height]
        return CGSize(width: width, height: heights.max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let left = max(0, bounds.width - gap) / (1 + ratio)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: left, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + left + gap, y: bounds.minY), anchor: .topLeading, proposal: .init(width: left * ratio, height: bounds.height))
    }
}
