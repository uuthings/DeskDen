import SwiftUI

struct WorkbenchUpdateSettings: View {
    @ObservedObject var updates: AppUpdateController
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WBCard(title: "软件更新", symbol: "arrow.down.circle", spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("方寸 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
                            .font(.system(size: 12, weight: .medium))
                        Text(updates.status).font(.system(size: 11)).foregroundStyle(updates.hasError ? palette.warning : palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("检查更新", action: updates.checkForUpdates).buttonStyle(WBButtonStyle())
                        .disabled(!updates.canCheck).accessibilityIdentifier("updates-check")
                }.padding(.vertical, 13)
                Rectangle().fill(palette.line).frame(height: 1)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动检查更新").font(.system(size: 12, weight: .medium))
                        Text("每天检查新版本并提示；由你确认下载和安装。默认关闭。")
                            .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("自动检查更新", isOn: Binding(get: { updates.automaticallyChecks }, set: updates.setAutomaticallyChecks))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(palette.accent)
                        .disabled(!AppUpdateController.configurationIsValid(Bundle.main.infoDictionary ?? [:]))
                        .accessibilityIdentifier("updates-automatic")
                }.padding(.top, 13)
                if let lastChecked = updates.lastChecked {
                    Text("上次检查：" + lastChecked.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 12)
                }
                Text("手动模式只在点击「检查更新」时联网。更新会保留设置与本机资料，安装前会处理未保存的更改。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
        }.accessibilityIdentifier("fc.settings.updates")
    }
}
