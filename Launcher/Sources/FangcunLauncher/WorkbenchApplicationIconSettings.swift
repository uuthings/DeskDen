import AppKit
import SwiftUI

struct WorkbenchApplicationIconSettings: View {
    @ObservedObject var controller: ApplicationIconController = .shared
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        WBCard(title: "应用图标", symbol: "drop", spacing: 12) {
            Text("一滴水中，自有方寸天地。选择后立即应用，下次启动时保留。")
                .font(.system(size: 11)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                ForEach(ApplicationIconChoice.allCases) { choice in
                    Button { controller.select(choice) } label: {
                        VStack(spacing: 7) {
                            Group {
                                if let image = controller.image(for: choice) {
                                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                                } else { Image(systemName: "drop").resizable().scaledToFit().foregroundStyle(palette.muted) }
                            }.frame(width: 76, height: 76).accessibilityHidden(true)
                            Text(choice.title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                            Text(choice.subtitle).font(.system(size: 11)).foregroundStyle(palette.muted)
                            HStack(spacing: 4) {
                                Image(systemName: controller.selection == choice ? "checkmark.circle.fill" : "circle")
                                Text(controller.selection == choice ? "使用中" : "使用此图标")
                            }.font(.system(size: 11)).foregroundStyle(controller.selection == choice ? palette.accent : palette.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 14).padding(.horizontal, 8)
                        .background(controller.selection == choice ? palette.accent.opacity(0.10) : palette.soft,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(controller.selection == choice ? palette.accent.opacity(0.65) : palette.line, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.title)
                    .accessibilityValue(controller.selection == choice ? "当前应用图标" : "未选中")
                    .accessibilityHint("将方寸图标更换为" + choice.title)
                    .accessibilityIdentifier("fc.settings.icon." + choice.rawValue)
                }
            }
            if let error = controller.error {
                Text(error).font(.system(size: 11)).foregroundStyle(WorkbenchStyle.warning)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("fc.settings.icon.error")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("fc.settings.icons")
    }
}
