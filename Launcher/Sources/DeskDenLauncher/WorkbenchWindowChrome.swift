import AppKit
import SwiftUI
import LauncherCore

/// Window commands share the same native lifecycle as keyboard and application menus.
struct WorkbenchWindowIconControls: View {
    @ObservedObject var model: WorkbenchAppModel
    @Environment(\.workbenchTheme) private var theme
    @Environment(\.workbenchOpacity) private var opacity
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        HStack(spacing: 4) {
            Button { model.requestQuit() } label: {
                Image(systemName: "power").font(.system(size: 13)).frame(width: 32, height: 28)
            }.buttonStyle(WorkbenchChromeButtonStyle(closing: true)).help("退出方寸")
                .accessibilityLabel("退出方寸").accessibilityIdentifier("window-quit")
            chromeButton("最小化", symbol: "minus") { model.minimizeWindow?() }
            chromeButton(model.isFullScreen ? "返回窗口" : "全屏", symbol: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") { model.toggleFullScreen?() }
            chromeButton("关闭窗口", symbol: "xmark", closing: true) { model.closeWindow?() }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(palette.line).frame(width: 1, height: 20) }
    }
    private func chromeButton(_ title: String, symbol: String, closing: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .regular)).frame(width: 32, height: 28) }
            .buttonStyle(WorkbenchChromeButtonStyle(closing: closing))
            .help(closing ? "收起界面，后台继续运行" : title)
            .accessibilityLabel(title).accessibilityIdentifier("window-" + (closing ? "close" : title == "最小化" ? "minimize" : "fullscreen"))
    }
}

struct WorkbenchChromeButtonStyle: ButtonStyle {
    var closing = false
    @Environment(\.workbenchTheme) private var theme
    @Environment(\.workbenchOpacity) private var opacity
    @State private var hovering = false
    @Environment(\.workbenchPalette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        let p = palette
        configuration.label.foregroundStyle(hovering && closing ? p.critical : hovering ? p.text : p.secondary)
            .background(RoundedRectangle(cornerRadius: 7).fill(configuration.isPressed ? p.soft.opacity(0.9) : hovering ? (closing ? p.critical.opacity(0.12) : p.soft) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(hovering ? (closing ? p.critical.opacity(0.25) : p.border) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7)).onHover { hovering = $0 }.clickableCursor()
    }
}

struct WorkbenchBrandMenu: View {
    @ObservedObject var model: WorkbenchAppModel
    let dismiss: () -> Void
    @Environment(\.workbenchTheme) private var theme
    @Environment(\.workbenchOpacity) private var opacity
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("方寸 · 窗口与应用").font(.system(size: 11)).foregroundStyle(palette.muted).padding(EdgeInsets(top: 5, leading: 9, bottom: 8, trailing: 9))
            command(model.isFullScreen ? "返回窗口" : "进入全屏", symbol: "arrow.up.left.and.arrow.down.right") { model.toggleFullScreen?() }
            command("最小化", symbol: "minus") { model.minimizeWindow?() }
            command("关闭窗口", symbol: "xmark", subtitle: "收起界面，后台继续运行") { model.closeWindow?() }
            Rectangle().fill(palette.line).frame(height: 1).padding(.horizontal, 7).padding(.vertical, 6)
            command("退出方寸", symbol: "power", subtitle: "停止后台监测与方寸提醒", destructive: true) { model.requestQuit() }
            #if DEBUG
            if Bundle.main.object(forInfoDictionaryKey:"DeskDenUIReview") as? Bool == true, !model.isFullScreen {
                Rectangle().fill(palette.line).frame(height:1).padding(.horizontal,7).padding(.vertical,6)
                ForEach([NSSize(width:1120,height:758),NSSize(width:960,height:720),NSSize(width:1728,height:993)],id:\.width) {size in
                    command("验收尺寸 · \(Int(size.width)) × \(Int(size.height))",symbol:"viewfinder") {
                        model.hostWindow?.setContentSize(size);model.hostWindow?.center()
                    }
                }
            }
            #endif
        }
        .padding(7).frame(width: 242, alignment: .leading)
        .background(WorkbenchMaterialSurface(kind: .panel, radius: 12))
        .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
        .accessibilityElement(children:.contain).accessibilityIdentifier("window-brand-menu")
    }
    private func command(_ title: String, symbol: String, subtitle: String? = nil, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button { dismiss(); action() } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(destructive ? palette.critical : palette.secondary).frame(width: 15)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12)).foregroundStyle(palette.text)
                    if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.secondary) }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 9).padding(.vertical, 8).frame(minHeight: 34)
        }.buttonStyle(WorkbenchChromeButtonStyle()).accessibilityLabel(title)
    }
}

struct WorkbenchQuitConfirmation: View {
    @ObservedObject var model: WorkbenchAppModel
    @Environment(\.workbenchTheme) private var theme
    @Environment(\.workbenchOpacity) private var opacity
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        ZStack {
            palette.shell.opacity(0.44).ignoresSafeArea().contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "power").font(.system(size: 20)).foregroundStyle(palette.accent)
                    .frame(width: 42, height: 42).background(palette.soft, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.border)).padding(.bottom, 16)
                Text("退出方寸？").font(.system(size: 20, weight: .medium)).foregroundStyle(palette.text)
                Text("退出后，后台设备监测、流量记录和方寸本机提醒都会停止。").font(.system(size: 12)).lineSpacing(5).foregroundStyle(palette.secondary).padding(.top, 12)
                Text("只想收起界面，可以选择关闭窗口。系统提醒事项仍由 macOS 管理。").font(.system(size: 12)).lineSpacing(5).foregroundStyle(palette.secondary).padding(.top, 8)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("取消", role: .cancel) { model.confirmingQuit = false }.buttonStyle(WBButtonStyle())
                    Button("只关闭窗口") { model.confirmingQuit = false; model.closeWindow?() }.buttonStyle(WBButtonStyle())
                    Button("退出方寸") { model.confirmQuit() }.buttonStyle(WBButtonStyle(destructive: true)).disabled(model.quitting)
                }.disabled(model.quitting).padding(.top, 24)
            }.padding(24).frame(width: 440, alignment: .leading)
                .background(WorkbenchMaterialSurface(kind: .panel, radius: 15))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 18)
        }.accessibilityElement(children:.contain).accessibilityAddTraits(.isModal).accessibilityIdentifier("window-quit-confirmation")
            .onExitCommand { if !model.quitting { model.confirmingQuit = false } }
    }
}
