import SwiftUI

/// A checkbox whose surface follows the workbench palette, independently of
/// AppKit's key-window highlight and appearance invalidations.
struct WBCheckboxToggleStyle: ToggleStyle {
    @Environment(\.workbenchPalette) private var palette
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isOn ? palette.accent : palette.control)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(configuration.isOn ? palette.accent : palette.secondary.opacity(0.60), lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                            .opacity(configuration.isOn ? 1 : 0)
                    }
                    .frame(width: 16, height: 16).accessibilityHidden(true)
                configuration.label.font(.system(size: 12)).foregroundStyle(palette.text)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: WBControlMetrics.regularHeight, alignment: .leading)
            .contentShape(Rectangle()).opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(ClickablePlainButtonStyle())
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}
