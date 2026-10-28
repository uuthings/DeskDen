import AppKit
import SwiftUI
import LauncherCore

/// Fixed source tiles wrap as a group, without distributing spare width into tiles.
struct UsageCardGrid: Layout {
    static let cardSize = CGSize(width: 248, height: 208)
    static let gap: CGFloat = 12
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let offered = proposal.width ?? Self.cardSize.width
        let width = offered.isFinite ? max(Self.cardSize.width, offered) : Self.cardSize.width
        let columns = columns(for: width, count: subviews.count)
        let rows = (subviews.count + columns - 1) / columns
        return .init(width: width, height: rows == 0 ? 0 : CGFloat(rows) * Self.cardSize.height + CGFloat(rows - 1) * Self.gap)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columns(for: bounds.width, count: subviews.count)
        for (index, view) in subviews.enumerated() {
            view.place(at: .init(x: bounds.minX + CGFloat(index % columns) * (Self.cardSize.width + Self.gap),
                                 y: bounds.minY + CGFloat(index / columns) * (Self.cardSize.height + Self.gap)),
                       anchor: .topLeading, proposal: .init(Self.cardSize))
        }
    }
    private func columns(for width: CGFloat, count: Int) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let maximum = max(1, count)
        return max(1, Int(min(CGFloat(maximum), (width + Self.gap) / (Self.cardSize.width + Self.gap))))
    }
}

/// An unconfigured group occupies one source slot, just like a connected card.
/// The entire surface opens configuration; there is no second nested button.
struct UsageEmptySourceCard: View {
    let title: String
    let description: String
    let actionTitle: String
    let symbol: String
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 22)).foregroundStyle(palette.accent)
                .frame(width: 32, height: 32, alignment: .leading)
                .accessibilityHidden(true)
                .padding(.bottom, 12)
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.text).padding(.bottom, 8)
            Text(description).font(.system(size: 12)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Label(actionTitle, systemImage: "plus")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.accent)
                .frame(height: 28)
        }
        .padding(14)
        .frame(width: UsageCardGrid.cardSize.width, height: UsageCardGrid.cardSize.height, alignment: .topLeading)
        .background(WorkbenchMaterialSurface(kind: .card, radius: 15))
        .contentShape(RoundedRectangle(cornerRadius: 15))
    }
}

struct UsageSourceIcon: View {
    @ObservedObject var appearance: UsagePresentationModel
    let icon: UsageCardIcon
    var aiProvider: AIProvider?
    var serviceKind: ProviderUsageKind?
    var size: CGFloat = 25
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        Group {
            if case .image = icon, let image = appearance.image(for: icon) {
                Image(nsImage: image).resizable().scaledToFit()
            } else if case .symbol(let symbol) = icon {
                Image(systemName: symbol).font(.system(size: size * 0.78)).foregroundStyle(palette.accent)
            } else if let aiProvider {
                AIProviderLogo(provider: aiProvider, size: size)
            } else {
                Image(systemName: serviceKind == .bandwagon ? "server.rack" : "globe")
                    .font(.system(size: size * 0.66)).foregroundStyle(palette.secondary)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct UsageAIQuotaCard: View {
    let summary: AIProviderSummary
    let display: UsageCardAppearance
    @ObservedObject var appearance: UsagePresentationModel
    let enabled: Bool
    let timeZone: TimeZone
    @Environment(\.workbenchPalette) private var palette
    private var name: String { display.displayName ?? summary.title }
    private var subtitle: String {
        let source = summary.snapshot?.source == .manual ? "手动记录" : summary.snapshot?.source == .imported ? "导入读数" : summary.provider == .codex ? "本机会话" : "本机状态栏"
        return [summary.snapshot?.accountPlan?.title, source].compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                UsageSourceIcon(appearance: appearance, icon: display.icon, aiProvider: summary.provider)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                Circle().fill(summary.state == .ready ? palette.accent : summary.state == .error ? palette.warning : palette.muted)
                    .frame(width: 5, height: 5).help(enabled ? summary.state.title : "自动读取关闭")
            }.frame(height: 32).padding(.bottom, 7)
            if let snapshot = summary.snapshot, !snapshot.availableWindows.isEmpty {
                let rows = snapshot.comparisonRows
                ForEach(0..<2, id: \.self) { index in
                    UsageAIWindowRow(window: index < rows.count ? rows[index] : nil, index: index, timeZone: timeZone)
                        .frame(height: 51, alignment: .top)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("—").font(.system(size: 27)).foregroundStyle(palette.text)
                    Text(summary.state == .disconnected ? "尚未连接额度来源" : "暂无可用额度窗口")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                    Text(summary.detail).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
                }.frame(maxWidth: .infinity, minHeight: 102, alignment: .topLeading)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(!enabled ? "自动读取关闭" : summary.state == .ready ? "窗口占用" : summary.state.title)
                if let date = summary.updatedAt { Text("· 更新于 " + ProviderUsageFormatting.time(date, timeZone: timeZone)) }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 11)).accessibilityHidden(true)
            }.font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                .padding(.top, 8).overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        }
        .foregroundStyle(palette.text).padding(14).frame(width: UsageCardGrid.cardSize.width, height: UsageCardGrid.cardSize.height, alignment: .topLeading)
        .background(WorkbenchMaterialSurface(kind: .card, radius: 15))
        .contentShape(RoundedRectangle(cornerRadius: 15))
    }
}

private struct UsageAIWindowRow: View {
    let window: AIQuotaWindow?
    let index: Int
    let timeZone: TimeZone
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        if let window {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(window.title).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                    Spacer(minLength: 3)
                    Text(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))) + "%")
                        .font(.system(size: 18)).monospacedDigit()
                }.frame(height: 20)
                WBProgress(value: window.usedPercent / 100, color: window.severity == 2 ? palette.critical : window.severity == 1 ? palette.warning : palette.accent, height: 4)
                Text(reset(window)).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(index == 0 ? "短周期窗口未提供" : "其他额度窗口未提供").font(.system(size: 11)).foregroundStyle(palette.muted)
                Text("—").font(.system(size: 17)).foregroundStyle(palette.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func reset(_ window: AIQuotaWindow) -> String {
        guard let date = window.resetsAt else { return "来源未提供重置时间" }
        let remaining = date.timeIntervalSinceNow
        if window.durationMinutes < 1440, remaining > 0, remaining < 86_400 {
            let minutes = max(1, Int(remaining / 60))
            return (minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟") + "后重置"
        }
        return ProviderUsageFormatting.resetDate(date, timeZone: timeZone) + " 重置"
    }
}

struct ProviderQuotaCard: View {
    let source: ProviderUsageConfiguration
    let state: ProviderUsageSourceState
    let refreshing: Bool
    let display: UsageCardAppearance
    @ObservedObject var appearance: UsagePresentationModel
    var timeZone: TimeZone = .current
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                UsageSourceIcon(appearance: appearance, icon: display.icon, serviceKind: source.kind)
                VStack(alignment: .leading, spacing: 3) {
                    Text(display.displayName ?? source.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(source.kind.title + " · " + (source.kind == .iproyal ? "订单 " : "实例 ") + source.resourceID)
                        .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 3)
                TimelineView(.periodic(from: .now, by: 60)) { tick in
                    Circle().fill(statusColor(at: tick.date)).frame(width: 5, height: 5)
                        .help(refreshing ? "更新中" : !source.enabled ? "已暂停" : state.status(at: tick.date, maximumAge: source.refreshPolicy.maximumInterval).title)
                }
            }.frame(height: 32).padding(.bottom, 10)
            if let snapshot = state.snapshot {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(ProviderUsageFormatting.amount(snapshot.remaining, unit: snapshot.displayUnit)).font(.system(size: 27)).monospacedDigit()
                    Text("GB 剩余").font(.system(size: 11)).foregroundStyle(palette.muted)
                    Spacer(minLength: 0)
                }.frame(height: 33).padding(.bottom, 8)
                HStack(spacing: 3) {
                    Text("本周期消耗")
                    Spacer(minLength: 2)
                    Text(ProviderUsageFormatting.amount(snapshot.usedBytes, unit: snapshot.displayUnit) + " / " + ProviderUsageFormatting.amount(snapshot.limitBytes, unit: snapshot.displayUnit) + " GB").monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                WBProgress(value: min(1, max(0, snapshot.usedPercent / 100)), color: snapshot.usedPercent >= 90 ? palette.warning : palette.accent, height: 4).padding(.top, 5).padding(.bottom, 9)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("下次重置")
                    Spacer(minLength: 2)
                    Text(ProviderUsageFormatting.resetValue(snapshot, timeZone: timeZone)).monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                Text(snapshot.resetDateText != nil ? "服务商日期 · 时区未提供" : snapshot.resetsAt != nil ? "跟随工作台 · " + ProviderUsageFormatting.zone(timeZone) : "平台未提供重置时间")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("—").font(.system(size: 27))
                    Text(source.kind == .iproyal ? "连接来源后显示订单余额" : "验证连接后显示实例余额").font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Text("总额度与周期尚未确认").font(.system(size: 11)).foregroundStyle(palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 3)
            HStack(spacing: 4) {
                TimelineView(.periodic(from: .now, by: 60)) { tick in
                    Text(footer(at: tick.date)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 11)).accessibilityHidden(true)
            }.font(.system(size: 11)).foregroundStyle(state.refresh.authenticationRequired || state.refresh.failureCount > 0 ? palette.warning : palette.muted)
                .padding(.top, 8).overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        }
        .foregroundStyle(palette.text).padding(14).frame(width: UsageCardGrid.cardSize.width, height: UsageCardGrid.cardSize.height, alignment: .topLeading)
        .background(WorkbenchMaterialSurface(kind: .card, radius: 15))
        .contentShape(RoundedRectangle(cornerRadius: 15))
    }
    private func statusColor(at date: Date) -> Color {
        guard source.enabled else { return palette.muted }
        return switch state.status(at: date, maximumAge: source.refreshPolicy.maximumInterval) {
        case .ready: palette.accent
        case .authenticationRequired, .failed: palette.warning
        case .pending, .stale: palette.muted
        }
    }
    private func footer(at date: Date) -> String {
        if refreshing { return "正在更新" }
        if state.refresh.authenticationRequired { return "需要重新连接" }
        if state.refresh.failureCount > 0 { return state.snapshot == nil ? "更新失败 · 尚无有效读数" : "更新失败 · 保留上次读数" }
        if !source.enabled { return "已暂停自动更新" }
        guard let snapshot = state.snapshot else { return "尚无有效读数" }
        let stale = state.status(at: date, maximumAge: source.refreshPolicy.maximumInterval) == .stale
        return (stale ? "旧读数 · " : "更新于 ") + ProviderUsageFormatting.time(snapshot.observedAt, timeZone: timeZone)
    }
}
