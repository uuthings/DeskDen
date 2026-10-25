import AppKit
import SwiftUI

struct WorkbenchApplicationIconSettings: View {
    @ObservedObject var controller: ApplicationIconController = .shared
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        WBCard(title: "应用图标", symbol: "app", spacing: 12) {
            HStack(spacing: 16) {
                Group {
                    if let image = controller.brandImage(pointSize: 76) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: "desktopcomputer").resizable().scaledToFit().foregroundStyle(palette.muted)
                    }
                }.frame(width: 76, height: 76).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(controller.selection.title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text)
                        Label("当前图标", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    }
                    Text(controller.selection.subtitle).font(.system(size: 11)).foregroundStyle(palette.muted)
                    Text("Dock、窗口与菜单栏使用同一套桌面标记。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("fc.settings.icon.desk")
            if let error = controller.error {
                Text(error).font(.system(size: 11)).foregroundStyle(WorkbenchStyle.warning)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("fc.settings.icon.error")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("fc.settings.icons")
    }
}
