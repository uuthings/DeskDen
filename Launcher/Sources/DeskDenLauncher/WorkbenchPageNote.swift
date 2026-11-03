import SwiftUI

/// Supporting copy outside a card needs its own surface: text colors that are
/// readable inside a card cannot guarantee contrast over the scene wallpaper.
struct WBPageNote<Content: View>: View {
    @Environment(\.workbenchPalette) private var palette
    var symbol = "info.circle"
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14)).padding(.top, 1).accessibilityHidden(true)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(3)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchMaterialSurface(radius: 8))
        .environment(\.workbenchOnBackdrop, false)
        .accessibilityElement(children: .contain)
    }
}
