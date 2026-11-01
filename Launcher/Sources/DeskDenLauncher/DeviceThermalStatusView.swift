import SwiftUI
import LauncherCore

extension DeviceThermalPresentation {
    init(snapshot: DeviceSnapshot, rule: DeviceTemperatureRule = .init()) {
        self = snapshot.thermalPresentation(rule: rule)
    }
}

extension DeviceThermalLevel {
    func color(palette: ThemePalette) -> Color {
        switch self {
        case .normal: palette.accent
        case .warning: palette.warning
        case .critical: palette.critical
        case .unknown: palette.muted
        }
    }
}

struct DeviceThermalStatusBadge: View {
    let status: DeviceThermalPresentation
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(status.level.color(palette: palette))
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(status.level.color(palette: palette).opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .help(status.detail)
            .accessibilityElement(children: .combine)
            .accessibilityHint(status.detail)
            .accessibilityIdentifier("device-thermal-status")
    }
}
