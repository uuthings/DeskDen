import AppKit
import SwiftUI
import LauncherCore

/// Refreshes labels without requesting new provider data. Activation and wake
/// refresh the visible time immediately after a suspended timeline resumes.
struct UsageResetClock<Content: View>: View {
    var now: Date? = nil
    @ViewBuilder var content: (Date) -> Content
    @State private var clockGeneration = 0

    var body: some View {
        Group {
            if let now { content(now) }
            else {
                TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 60)) { _ in
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

    var body: some View {
        UsageResetClock(now: now) { current in
            let detail = reset.details(at: current, timeZone: timeZone)
            VStack(alignment: .leading, spacing: 18) {
                Label(detail.summary, systemImage: "clock")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(palette.text)
                    .monospacedDigit()
                row("工作台时间", value: detail.workbenchValue, zone: detail.workbenchZone)
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
