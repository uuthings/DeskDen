import AppKit
import SwiftUI
import LauncherCore

/// Refreshes labels without requesting new provider data. Activation and wake
/// refresh the visible time immediately after a suspended timeline resumes.
struct UsageResetClock<Content: View>: View {
    var now: Date? = nil
    var interval: TimeInterval = 60
    @ViewBuilder var content: (Date) -> Content
    @State private var clockGeneration = 0

    var body: some View {
        Group {
            if let now { content(now) }
            else {
                TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: interval)) { _ in
                    // Use the current wall clock even after it moves backward;
                    // a previous activation time must never freeze the countdown.
                    content(Date())
                }
                .id(clockGeneration)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in clockGeneration &+= 1 }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in clockGeneration &+= 1 }
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in clockGeneration &+= 1 }
            }
        }
    }
}

private struct UsageDisplayLocationKey: EnvironmentKey { static let defaultValue = "系统时间" }
extension EnvironmentValues {
    var usageDisplayLocation: String {
        get { self[UsageDisplayLocationKey.self] }
        set { self[UsageDisplayLocationKey.self] = newValue }
    }
}

enum UsageDatePresentation {
    static func zone(_ timeZone: TimeZone, location: String, at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let hours = abs(seconds) / 3600, minutes = abs(seconds) % 3600 / 60
        let offset = "GMT" + (seconds >= 0 ? "+" : "−") + String(hours) + (minutes == 0 ? "" : String(format: ":%02d", minutes))
        return location + " · " + offset + " · " + timeZone.identifier
    }
    static func absolute(_ date: Date, timeZone: TimeZone, location: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return formatter.string(from: date) + " · " + zone(timeZone, location: location, at: date)
    }
}

struct UsageObservationAgeLabel: View {
    let date: Date
    var prefix: String = "更新于 "
    var timeZone: TimeZone = .current
    @Environment(\.usageDisplayLocation) private var location
    var body: some View {
        UsageResetClock(interval: 1) { current in
            Text(prefix + UsageObservationAge.text(since: date, now: current)).monospacedDigit()
                .help(UsageDatePresentation.absolute(date, timeZone: timeZone, location: location))
        }
    }
}

struct UsageResetLabel: View {
    var reset: UsageResetTime
    var timeZone: TimeZone
    var now: Date? = nil
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        UsageResetClock(now: now) { current in
            Text(reset.summary(at: current, timeZone: timeZone))
                .font(.system(size: 11)).foregroundStyle(palette.muted)
                .monospacedDigit()
                .help(reset.help(at: current, timeZone: timeZone))
        }
    }
}

/// The containing page supplies its card and heading, keeping these rows on the
/// shared material instead of introducing a separate surface.
struct UsageResetDetailsView: View {
    var reset: UsageResetTime
    var timeZone: TimeZone
    var now: Date? = nil
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.usageDisplayLocation) private var location

    var body: some View {
        UsageResetClock(now: now) { current in
            let detail = reset.details(at: current, timeZone: timeZone)
            VStack(alignment: .leading, spacing: 18) {
                Label(detail.summary, systemImage: "clock")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(palette.text)
                    .monospacedDigit()
                row("工作台时间", value: detail.workbenchValue,
                    zone: reset.resetsAt.map { UsageDatePresentation.zone(timeZone, location: location, at: $0) } ?? (location + " · " + timeZone.identifier))
                row(detail.sourceLabel, value: detail.sourceValue, zone: detail.sourceZone)
                Text(detail.explanation).font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ title: String, value: String, zone: String?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).font(.system(size: 12)).foregroundStyle(palette.muted)
                .frame(width: 94, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.system(size: 14, weight: .medium)).foregroundStyle(palette.text).monospacedDigit()
                if let zone { Text(zone).font(.system(size: 11)).foregroundStyle(palette.muted) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
