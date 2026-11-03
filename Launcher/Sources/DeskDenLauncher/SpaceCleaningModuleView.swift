import AppKit
import SwiftUI
import LauncherCore

struct SpaceCleaningModuleView: View {
    @ObservedObject var model: SpaceCleaningModel
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.timeZone) private var timeZone
    @State private var measuredHeights: [SpaceCleaningMeasuredRegion: CGFloat] = [:]

    private var isPreparing: Bool { [.start, .scope].contains(model.screen) && model.dialog == nil }
    private func panelHeight(in viewport: CGFloat) -> CGFloat {
        max(0, viewport - (measuredHeights[.header] ?? 72) - (measuredHeights[.footer] ?? 36))
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
                // All stages use the actual work area. Dense or narrow layouts
                // scroll inside it instead of shrinking their controls.
                content(width: geometry.size.width, height: height)
                    .frame(width: geometry.size.width, height: height, alignment: .top)
                VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if !isPreparing {
                        Text(model.scopeSummary).lineLimit(1).truncationMode(.middle)
                        if model.screen == .results { Text(model.requiresRescan ? "· 需重新扫描" : "· 已检查") }
                    } else if let date = model.lastScanDate {
                        Text("上次扫描 · " + SpaceCleaningFormat.date(date, timeZone: timeZone))
                    } else {
                        Label("开发依赖与发布归档保持保护", systemImage: "checkmark.shield")
                    }
                    Spacer(minLength: 4)
                    Button("覆盖范围与保留规则") { model.dialog = .rules }.buttonStyle(WBTextActionButtonStyle())
                        .disabled(model.isBusy).accessibilityIdentifier("space-cleaning-rules-link")
                }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.92)).shadow(color:.black.opacity(0.45),radius:2,y:1).padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = model.message {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(message).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.message = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(WBIconButtonStyle(size: 24)).accessibilityLabel("关闭提示")
                    }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.92)).shadow(color:.black.opacity(0.45),radius:2,y:1).padding(.top, 10)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("space-cleaning-message")
                }
                }.environment(\.workbenchOnBackdrop, true).measureCleaningHeight(.footer)
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
        switch model.screen {
        case .start, .scope: "查看空间占用，找到值得整理的内容"
        case .scanning: "正在检查空间占用，完成后逐项复核"
        case .results: "核对文件用途，选择处理方式"
        case .processing: "重新核验所选项目，安全完成处理"
        case .completed: "查看处理结果与未完成的项目"
        case .history: "查找每次处理的项目、方式与结果"
        }
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
            case .start, .scope: SpaceCleaningHomeView(model: model, width: width, height: height)
            case .scanning: SpaceCleaningScanView(model: model, width: width, height: height)
            case .results: SpaceCleaningResultsView(model: model)
            case .processing: processing(height: height)
            case .completed: SpaceCleaningCompletionView(model: model)
            case .history: SpaceCleaningHistoryView(model: model)
            }
        }
    }
    private func isPurpose(_ dialog: CleaningDialog) -> Bool { if case .purpose = dialog { true } else { false } }
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
    static func bytes(_ bytes: UInt64) -> String {
        bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
    @MainActor private static var dateFormatters: [String: DateFormatter] = [:]
    @MainActor static func date(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatted(date, pattern: "yyyy年MM月dd日 HH:mm", timeZone: timeZone)
    }
    @MainActor static func day(_ date: Date, timeZone: TimeZone) -> String {
        formatted(date, pattern: "yyyy年MM月dd日", timeZone: timeZone)
    }
    @MainActor static func time(_ date: Date, timeZone: TimeZone) -> String {
        formatted(date, pattern: "HH:mm", timeZone: timeZone)
    }
    @MainActor private static func formatted(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        let key = timeZone.identifier + ":" + pattern
        let formatter: DateFormatter
        if let cached = dateFormatters[key] { formatter = cached }
        else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            if dateFormatters.count >= 24 { dateFormatters.removeAll(keepingCapacity: true) }
            dateFormatters[key] = formatter
        }
        return formatter.string(from: date)
    }
}


private enum SpaceCleaningMeasuredRegion: Hashable { case header, footer }
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
