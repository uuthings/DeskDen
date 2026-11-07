import AppKit
import SwiftUI
import LauncherCore

/// Cards follow the home page's three-column grid (现行规范 9.3, U1). Few
/// sources keep the column width and leave the remaining slots empty.
struct UsageCardGrid: Layout {
    static let cardSize = CGSize(width: 248, height: 236)
    static let gap: CGFloat = 12
    static let rowHeight: CGFloat = 236
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let offered = proposal.width ?? Self.cardSize.width
        let width = offered.isFinite ? max(Self.cardSize.width, offered) : Self.cardSize.width
        let columns = columns(for: width, count: subviews.count)
        let rows = (subviews.count + columns - 1) / columns
        return .init(width: width, height: rows == 0 ? 0 : CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * Self.gap)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columns(for: bounds.width, count: subviews.count)
        let width = max(0, (bounds.width - CGFloat(columns - 1) * Self.gap) / CGFloat(columns))
        for (index, view) in subviews.enumerated() {
            view.place(at: .init(x: bounds.minX + CGFloat(index % columns) * (width + Self.gap),
                                 y: bounds.minY + CGFloat(index / columns) * (Self.rowHeight + Self.gap)),
                       anchor: .topLeading, proposal: .init(width: width, height: Self.rowHeight))
        }
    }
    private func columns(for width: CGFloat, count: Int) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, min(3, Int((width + Self.gap) / (Self.cardSize.width + Self.gap))))
    }
}

/// A neutral capsule (现行规范 2.3, 3.3): category colors stay on icons.
struct UsageCategoryTag: View {
    let title: String
    var categoryID: String = "uncategorized"
    @Environment(\.workbenchPalette) private var palette
    private var constrainedTextWidth: CGFloat? {
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        return width > 76 ? 76 : nil
    }
    var body: some View {
        Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary)
            .lineLimit(1).help(title).frame(width: constrainedTextWidth, alignment: .leading)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(palette.secondary.opacity(0.13)))
    }
}

struct UsageCardTitle: View {
    let name: String
    let categoryTitle: String
    let categoryID: String
    var body: some View {
        HStack(spacing: 7) {
            Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1).help(name)
                .layoutPriority(1)
            UsageCategoryTag(title: categoryTitle, categoryID: categoryID)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
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
                .font(.system(size: 12)).foregroundStyle(palette.accent)
                .frame(height: 28)
        }
        .padding(14)
        .frame(maxWidth: .infinity).frame(height: UsageCardGrid.cardSize.height, alignment: .topLeading)
        .background(WorkbenchMaterialSurface(kind: .card, radius: 15))
        .contentShape(RoundedRectangle(cornerRadius: 15))
    }
}

struct UsageSourceIcon: View {
    @ObservedObject var appearance: UsagePresentationModel
    let icon: UsageCardIcon
    var aiProvider: AIProvider?
    var serviceKind: ProviderUsageKind?
    var defaultBrand: UsageBrandIcon?
    var size: CGFloat = 32
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        Group {
            if case .image = icon, let image = appearance.image(for: icon) {
                Image(nsImage: image).resizable().scaledToFit()
            } else if case .symbol(let symbol) = icon {
                Image(systemName: symbol).font(.system(size: size * 0.78)).foregroundStyle(palette.accent)
            } else if case .brand(let brand) = icon {
                UsageBrandLogo(brand: brand, size: size)
            } else if let defaultBrand {
                UsageBrandLogo(brand: defaultBrand, size: size)
            } else if let aiProvider {
                AIProviderLogo(provider: aiProvider, size: size)
            } else {
                Image(systemName: serviceKind == .bandwagon ? "server.rack" : "globe")
                    .font(.system(size: size * 0.75)).foregroundStyle(palette.secondary)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

extension UsageBrandIcon {
    var title: String {
        switch self {
        case .chatgpt: "GPT"
        case .claude: "Claude"
        case .deepseek: "DeepSeek"
        }
    }
}

/// Bundled brand marks identify sources; choosing one never changes a connection.
/// DeepSeek's mark is the PNG representation of https://www.deepseek.com/favicon.ico.
/// ChatGPT and Claude reuse the existing production artwork.
@MainActor private enum UsageBrandArtwork {
    static let images: [UsageBrandIcon: NSImage] = Dictionary(uniqueKeysWithValues: UsageBrandIcon.allCases.compactMap { brand in
        let locations = [Bundle.main.url(forResource: brand.rawValue, withExtension: "png", subdirectory: "Workbench"),
                         Bundle.main.resourceURL?.appendingPathComponent("Workbench/" + brand.rawValue + ".png")]
        guard let image = locations.compactMap({ $0 }).compactMap({ NSImage(contentsOf: $0) }).first else { return nil }
        return (brand, image)
    })
}

struct UsageBrandLogo: View {
    let brand: UsageBrandIcon
    var size: CGFloat = 25
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        Group {
            if let image = UsageBrandArtwork.images[brand] { Image(nsImage: image).resizable().scaledToFit() }
            else { Text(brand.title.prefix(1)).font(.system(size: size * 0.7, weight: .medium)).foregroundStyle(palette.secondary) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct UsageAIQuotaCard: View {
    let summary: AIProviderSummary
    let display: UsageCardAppearance
    @ObservedObject var appearance: UsagePresentationModel
    let enabled: Bool
    let timeZone: TimeZone
    var categoryTitle: String = "订阅"
    var reading = false
    /// Leaves room for an action the caller lays over the card (see `UsageCardActionAnchor`).
    var reservesAction = false
    @Environment(\.workbenchPalette) private var palette
    private var name: String { display.displayName ?? summary.title }
    /// The card states its real reason (现行规范 9.3, U2): "reading" only
    /// while a scan is running, and an off source says so instead of "checking".
    private var isReading: Bool { enabled && summary.snapshot == nil && (reading || summary.detail == AIUsageModel.readingDetail) }
    private var status: String? {
        if !enabled { return "已关闭" }
        if isReading { return "读取中" }
        switch summary.state {
        case .error: return "读取失败"
        case .unavailable, .disconnected: return summary.snapshot == nil ? "不可用" : nil
        case .ready, .stale: return nil
        }
    }
    private var subtitle: String {
        let source: String
        switch summary.snapshot?.source {
        case .manual: source = "手动记录"
        case .imported: source = "导入读数"
        case .claudeCLI: source = "官方客户端"
        case .claudeStatusLine: source = "状态栏同步"
        case .localSession: source = "本机会话"
        case nil: source = summary.provider == .codex ? "本机会话" : "官方客户端"
        }
        // An unknown plan is left out here; the detail page states it (9.3, U2).
        guard let plan = summary.effectiveAccountPlan else { return source }
        return plan.title + (summary.accountPlanIsDeclared ? "（用户设置）" : "") + " · " + source
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                UsageSourceIcon(appearance: appearance, icon: display.icon, aiProvider: summary.provider)
                VStack(alignment: .leading, spacing: 3) {
                    UsageCardTitle(name: name, categoryTitle: categoryTitle,
                                   categoryID: appearance.categoryID(for: UsagePresentationSourceID.ai(summary.provider), defaultID: "ai-subscription"))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).help(summary.accountPlanDescription)
                }
                Spacer(minLength: 4)
                if let status { WBStatusPill(title: status) }
            }.frame(height: 36).padding(.bottom, 12)
            if let snapshot = summary.snapshot, !snapshot.availableWindows.isEmpty {
                let windows = snapshot.availableWindows
                ForEach(Array(windows.prefix(2).enumerated()), id: \.offset) { _, window in
                    UsageAIWindowRow(window: window, timeZone: timeZone)
                        .frame(height: 64, alignment: .top)
                }
                if windows.count == 1 {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: summary.hasNoFiveHourLimit ? "checkmark.shield" : "info.circle").font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.hasNoFiveHourLimit ? "Pro 不设 5 小时限制" : "按来源提供的窗口展示").font(.system(size: 11))
                            Text(summary.hasNoFiveHourLimit ? "每周用量以实际读数为准" : "其余周期暂未提供读数").font(.system(size: 11)).foregroundStyle(palette.muted)
                        }
                    }.foregroundStyle(palette.secondary).padding(.top, 8)
                        .frame(maxWidth: .infinity, minHeight: 51, alignment: .topLeading)
                }
            } else {
                // One centered group: reason, detail and, for an off source, the
                // "开启读取" slot right below the detail (现行规范 9.3, U2).
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: isReading ? "arrow.triangle.2.circlepath" : "info.circle").font(.system(size: 14)).foregroundStyle(palette.muted)
                        Text(emptyTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text)
                    }
                    Text(emptyDetail).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if reservesAction {
                        // The card is itself a button, so the real action is laid over this slot.
                        Color.clear.frame(width: 60, height: 28).anchorPreference(key: UsageCardActionAnchor.self, value: .bounds) { $0 }
                    }
                }.padding(.bottom, 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            if let date = summary.updatedAt {
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    UsageObservationAgeLabel(date: date, prefix: !enabled ? "已暂停 · 上次读数 " : summary.state == .ready ? "更新于 " : summary.state.title + " · 上次读数 ", timeZone: timeZone)
                    Spacer(minLength: 0)
                }.font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                    .padding(.top, 8)
            }
        }
        .foregroundStyle(palette.text).padding(14).frame(maxWidth: .infinity).frame(height: UsageCardGrid.cardSize.height, alignment: .topLeading)
        .background(WorkbenchMaterialSurface(kind: .card, radius: 15))
        .contentShape(RoundedRectangle(cornerRadius: 15))
    }
}

/// Where a card that is itself a button reserves room for a separate action.
struct UsageCardActionAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

extension UsageAIQuotaCard {
    private var emptyTitle: String {
        if !enabled { return "自动读取已关闭" }
        if isReading { return "读取中" }
        return summary.state == .error ? "读取失败" : summary.state == .unavailable ? "额度尚未可用" : "等待额度读数"
    }
    private var emptyDetail: String {
        if !enabled { return "开启后读取\(summary.provider == .codex ? "本机会话" : "官方客户端")提供的额度窗口；关闭期间不推算用量。" }
        return summary.detail
    }
}

private struct UsageAIWindowRow: View {
    let window: AIQuotaWindow
    let timeZone: TimeZone
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        // The used share is the card's main reading, 24 regular (现行规范 9.3).
        let tone = palette.usageColor(forPercent: window.usedPercent)
        VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(window.title).font(.system(size: 12)).foregroundStyle(palette.secondary).lineLimit(1)
                    Spacer(minLength: 3)
                    Text(UsagePercentage.text(window.usedPercent)).font(.system(size: 24)).monospacedDigit()
                    Text("已用").font(.system(size: 11)).foregroundStyle(palette.muted)
                }.frame(height: 26)
                WBProgress(value: window.usedPercent / 100, color: tone, height: 5)
                HStack(spacing: 6) {
                    UsageResetLabel(reset: .init(window: window), timeZone: timeZone).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("剩余 " + UsagePercentage.text(window.remainingPercent)).foregroundStyle(tone).lineLimit(1)
                }.font(.system(size: 11)).foregroundStyle(palette.muted)
        }
    }
}

struct ProviderQuotaCard: View {
    let source: ProviderUsageConfiguration
    let state: ProviderUsageSourceState
    let refreshing: Bool
    let display: UsageCardAppearance
    @ObservedObject var appearance: UsagePresentationModel
    var timeZone: TimeZone = .current
    var categoryTitle: String = "流量服务"
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                UsageSourceIcon(appearance: appearance, icon: display.icon, serviceKind: source.kind)
                VStack(alignment: .leading, spacing: 3) {
                    UsageCardTitle(name: display.displayName ?? source.name, categoryTitle: categoryTitle,
                                   categoryID: appearance.categoryID(for: UsagePresentationSourceID.service(source.id), defaultID: "traffic-services"))
                    Text(source.kind.title + " · " + (source.kind == .iproyal ? "订单 " : "实例 ") + source.resourceID)
                        .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 3)
                TimelineView(.periodic(from: .now, by: 60)) { tick in
                    if let status = status(at: tick.date) { WBStatusPill(title: status) }
                }
            }.frame(height: 36).padding(.bottom, 14)
            if let snapshot = state.snapshot {
                HStack {
                    Text("本周期已用").foregroundStyle(palette.secondary)
                    Spacer(minLength: 3)
                    Text(UsagePercentage.text(snapshot.usedPercent))
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                }.font(.system(size: 12)).lineLimit(1)
                Text(ProviderUsageFormatting.amount(snapshot.usedBytes, unit: snapshot.displayUnit) + " GB / " + ProviderUsageFormatting.amount(snapshot.limitBytes, unit: snapshot.displayUnit) + " GB")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).monospacedDigit().lineLimit(1).padding(.top, 4)
                WBProgress(value: snapshot.usedPercent / 100, color: palette.usageColor(forPercent: snapshot.usedPercent), height: 5)
                    .padding(.top, 6).padding(.bottom, 9)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(ProviderUsageFormatting.amount(snapshot.remaining, unit: snapshot.displayUnit)).font(.system(size: 24)).monospacedDigit()
                    Text("GB 剩余").font(.system(size: 11)).foregroundStyle(palette.muted)
                    Spacer(minLength: 0)
                }.frame(height: 31).padding(.bottom, 8)
                UsageResetLabel(reset: .init(snapshot: snapshot), timeZone: timeZone)
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("—").font(.system(size: 24))
                    Text(source.kind == .iproyal ? "连接来源后显示订单余额" : "验证连接后显示实例余额").font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Text("总额度与周期尚未确认").font(.system(size: 11)).foregroundStyle(palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 3)
            HStack(spacing: 4) {
                UsageResetClock(interval: 1) { current in
                    Text(footer(at: current)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.font(.system(size: 11)).foregroundStyle(state.refresh.authenticationRequired || state.refresh.failureCount > 0 ? palette.warning : palette.muted)
                .padding(.top, 8)
        }
        .foregroundStyle(palette.text).padding(14).frame(maxWidth: .infinity).frame(height: UsageCardGrid.cardSize.height, alignment: .topLeading)
        .background(WorkbenchMaterialSurface(kind: .card, radius: 15))
        .contentShape(RoundedRectangle(cornerRadius: 15))
    }
    /// A capsule only for states that need words (现行规范 9.3, U2); a card
    /// with a fresh reading carries none and its footer gives the update time.
    private func status(at date: Date) -> String? {
        if refreshing { return "读取中" }
        guard source.enabled else { return "已暂停" }
        return switch state.status(at: date, maximumAge: source.refreshPolicy.maximumInterval) {
        case .ready, .stale: nil
        case .authenticationRequired: "需重连"
        case .failed: "读取失败"
        case .pending: state.snapshot == nil ? "读取中" : nil
        }
    }
    private func footer(at date: Date) -> String {
        if refreshing { return "正在更新" }
        let age = state.snapshot.map { UsageObservationAge.text(since: $0.observedAt, now: date) }
        if state.refresh.authenticationRequired { return "需重连" + (age.map { " · 上次读数 " + $0 } ?? "") }
        if state.refresh.failureCount > 0 { return age.map { "更新失败 · 上次读数 " + $0 } ?? "更新失败 · 尚无有效读数" }
        if !source.enabled { return "已暂停" + (age.map { " · 上次读数 " + $0 } ?? "") }
        guard let age else { return "尚无有效读数" }
        let stale = state.status(at: date, maximumAge: source.refreshPolicy.maximumInterval) == .stale
        return (stale ? "上次读数 " : "更新于 ") + age
    }
}
