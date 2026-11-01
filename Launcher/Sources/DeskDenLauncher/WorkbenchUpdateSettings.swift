import AppKit
import SwiftUI

struct WorkbenchUpdateSettings: View {
    @ObservedObject var updates: AppUpdateController
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WBCard(title: "软件更新", symbol: "arrow.down.circle", spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("方寸 v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
                            .font(.system(size: 12, weight: .medium))
                        Text(updates.status).font(.system(size: 11)).foregroundStyle(updates.hasError ? palette.warning : palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("updates-current-version")
                    Spacer(minLength: 8)
                    Button(updates.release == nil ? "检查更新" : "查看更新") {
                        if updates.release == nil { updates.checkForUpdates() } else { updates.showUpdateDialog() }
                    }.buttonStyle(WBButtonStyle())
                        .disabled(!updates.canCheck && updates.release == nil).accessibilityIdentifier("updates-check")
                }.padding(.vertical, 13)
                Rectangle().fill(palette.line).frame(height: 1)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动检查更新").font(.system(size: 12, weight: .medium))
                        Text("每天在后台检查；有新版本时显示左下角入口，由你决定下载和安装。")
                            .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("自动检查更新", isOn: Binding(get: { updates.automaticallyChecks }, set: updates.setAutomaticallyChecks))
                        .labelsHidden().toggleStyle(.switch).clickableCursor().controlSize(.small).tint(palette.accent)
                        .disabled(!AppUpdateController.configurationIsValid(Bundle.main.infoDictionary ?? [:]))
                        .accessibilityIdentifier("updates-automatic")
                }.padding(.top, 13)
                if let lastChecked = updates.lastChecked {
                    Text("上次检查：" + lastChecked.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 12)
                }
                Text("关闭自动检查后，仅在你主动检查时连接更新服务。安装前会处理未保存的更改。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("fc.settings.updates")
    }
}

/// The entry and the modal observe the same session, even while settings are closed.
struct WorkbenchUpdateEntry: View {
    @ObservedObject var updates: AppUpdateController
    @Environment(\.workbenchPalette) private var palette
    private var title: String {
        switch updates.phase {
        case .downloading: "正在下载更新"
        case .extracting: "正在准备更新"
        case .readyToInstall: "待安装 v" + (updates.release?.version ?? "")
        case .installing: "正在安装更新"
        default: "新版本 v" + (updates.release?.version ?? "")
        }
    }
    var body: some View {
        if updates.release != nil {
            Button(action: updates.showUpdateDialog) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 13)).accessibilityHidden(true)
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }.frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.accent.opacity(0.4)))
            }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 8, drawsSelection: false))
                .foregroundStyle(palette.accent).padding(.top, 6)
                .accessibilityLabel(title).accessibilityHint("打开软件更新窗口")
                .accessibilityIdentifier("updates-sidebar-entry")
        }
    }
}

struct WorkbenchUpdatePresentation: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .workbenchModal(isPresented: Binding(get: { updates.isDialogPresented }, set: { if !$0 { updates.dismissDialog() } }),
                            width: WorkbenchUpdateDialog.showsNotes(updates.phase) ? 520 : 420,
                            onRequestDismiss: updates.dismissDialog) {
                WorkbenchUpdateDialog(updates: updates)
            }
    }
}

/// Compact release notes use the shared material and the accepted TSX-style spacing.
struct WorkbenchUpdateDialog: View {
    @ObservedObject var updates: AppUpdateController
    @Environment(\.workbenchPalette) private var palette
    static func showsNotes(_ phase: AppUpdatePhase) -> Bool {
        phase == .available || phase == .readyToInstall
    }
    private var showsNotes: Bool { Self.showsNotes(updates.phase) }
    private var title: String {
        switch updates.phase {
        case .idle, .checking: "正在检查更新"
        case .available: updates.release?.informationOnly == true ? "更新信息" : "发现新版本"
        case .downloading: "正在下载更新"
        case .extracting: "正在准备更新"
        case .readyToInstall: "更新已准备好"
        case .installing: "正在安装更新"
        case .upToDate: "已是最新版本"
        case .failed: "更新未能完成"
        case .cancelled: "更新已取消"
        }
    }
    private var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    private var footerNote: String {
        switch updates.phase {
        case .idle, .checking: return "检查不会下载或安装更新"
        case .available:
            if updates.release?.informationOnly == true { return "查看详细说明后再决定是否升级" }
            if let size = updates.release?.downloadSize, size > 0 { return byteCount(size) + " · 下载后再确认安装" }
            return "下载后再确认安装"
        case .downloading, .extracting: return "尚未安装，当前版本不受影响"
        case .readyToInstall: return "稍后安装，继续使用当前版本"
        case .installing: return "已由你确认安装"
        case .upToDate: return updates.automaticallyChecks ? "下次将自动在后台检查" : "自动检查已关闭"
        case .failed: return "当前版本仍可继续使用"
        case .cancelled: return "当前版本仍可继续使用"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                WorkbenchBrandMark(pointSize: 32)
                Text(title).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: updates.dismissDialog) { Image(systemName: "xmark") }
                    .buttonStyle(WBIconButtonStyle(size: 32)).accessibilityLabel("关闭软件更新")
                    .accessibilityIdentifier("updates-dialog-close")
            }.padding(.horizontal, 24).padding(.vertical, 21)
            WorkbenchDialogBody(maximumHeight: 368, horizontalPadding: 24, bottomPadding: 0) {
                if showsNotes, let release = updates.release { releaseNotes(release) }
                else { taskContent }
            }
            HStack(spacing: 16) {
                Text(footerNote).font(.system(size: 11)).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 8) { actions }.fixedSize(horizontal: true, vertical: false)
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 22)
        }.frame(minHeight: showsNotes ? 0 : 214, alignment: .top)
            .foregroundStyle(palette.text)
            .accessibilityElement(children: .contain).accessibilityLabel("软件更新")
            .accessibilityIdentifier("updates-dialog")
    }
    private func releaseNotes(_ release: AppUpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Text("v" + release.version).font(.system(size: 16, weight: .semibold))
                        Text(updates.phase == .readyToInstall ? "已下载" : "新版本")
                            .font(.system(size: 10)).foregroundStyle(palette.accent)
                            .padding(.horizontal, 6).frame(height: 19)
                            .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer(minLength: 0)
                    if let date = release.publishedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 12)).foregroundStyle(palette.muted)
                            .help(date.formatted(date: .complete, time: .shortened))
                    }
                }
                Text("当前版本 v" + currentVersion).font(.system(size: 11)).foregroundStyle(palette.muted)
            }.accessibilityElement(children: .combine)
            if release.notes.isEmpty {
                Text("此版本暂未提供更新说明。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(release.notes.enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(palette.muted).frame(width: 3, height: 3).padding(.top, 8)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title)
                                    .font(.system(size: note.detail == nil && note.title.count > 60 ? 12 : 13,
                                                  weight: note.detail == nil && note.title.count > 60 ? .regular : .medium))
                                    .foregroundStyle(note.detail == nil && note.title.count > 60 ? palette.secondary : palette.text)
                                    .lineSpacing(5)
                                if let detail = note.detail, !detail.isEmpty {
                                    Text(detail).font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(5)
                                }
                            }.fixedSize(horizontal: false, vertical: true)
                        }.accessibilityElement(children: .combine)
                    }
                }
            }
            if updates.phase == .readyToInstall {
                Text("安装前会处理未保存的更改，并重新启动方寸。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("updates-release-notes")
    }
    private var taskContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(updates.status).font(.system(size: 12)).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("updates-task-status")
            if updates.phase == .downloading {
                VStack(spacing: 8) {
                    ProgressView(value: updates.progress).tint(palette.accent)
                        .accessibilityLabel("更新下载进度")
                    HStack {
                        Text(byteCount(Int64(clamping: updates.downloadedBytes)) + (updates.expectedBytes > 0 ? " / " + byteCount(Int64(clamping: updates.expectedBytes)) : ""))
                        Spacer()
                        if let progress = updates.progress { Text("\(Int(progress * 100))%") }
                    }.font(.system(size: 11)).monospacedDigit().foregroundStyle(palette.muted)
                }
            } else if updates.phase == .checking || updates.phase == .extracting || updates.phase == .installing {
                ProgressView().controlSize(.small).accessibilityLabel(title)
            }
        }.padding(.bottom, 4)
    }
    @ViewBuilder private var actions: some View {
        switch updates.phase {
        case .idle, .checking:
            Button("取消", action: updates.cancelUpdate).buttonStyle(WBButtonStyle())
                .accessibilityIdentifier("updates-cancel")
        case .available:
            Button("稍后", action: updates.dismissDialog).buttonStyle(WBButtonStyle())
            if updates.release?.informationOnly == true {
                if let url = updates.release?.informationURL {
                    Button("查看详情") { NSWorkspace.shared.open(url) }.buttonStyle(WBButtonStyle(primary: true))
                }
            } else {
                Button(action: updates.downloadUpdate) { Label("下载更新", systemImage: "arrow.down.to.line") }
                    .buttonStyle(WBButtonStyle(primary: true)).accessibilityIdentifier("updates-download")
            }
        case .downloading, .extracting:
            if updates.canCancelUpdate {
                Button("取消下载", action: updates.cancelUpdate).buttonStyle(WBButtonStyle())
                    .accessibilityIdentifier("updates-cancel")
            }
            Button("后台继续", action: updates.dismissDialog).buttonStyle(WBButtonStyle(primary: true))
        case .readyToInstall:
            Button("稍后", action: updates.dismissDialog).buttonStyle(WBButtonStyle())
            Button("安装并重启", action: updates.installUpdate).buttonStyle(WBButtonStyle(primary: true))
                .accessibilityIdentifier("updates-install")
        case .installing:
            if updates.canRetryInstallation {
                Button("稍后", action: updates.dismissDialog).buttonStyle(WBButtonStyle())
                Button("重试安装", action: updates.installUpdate).buttonStyle(WBButtonStyle(primary: true))
            } else {
                Button("正在准备") {}.buttonStyle(WBButtonStyle(primary: true)).disabled(true)
            }
        case .failed:
            Button("稍后", action: updates.dismissDialog).buttonStyle(WBButtonStyle())
            Button("重试", action: updates.retryUpdate).buttonStyle(WBButtonStyle(primary: true))
                .accessibilityIdentifier("updates-retry")
        case .upToDate, .cancelled:
            Button("完成", action: updates.dismissDialog).buttonStyle(WBButtonStyle(primary: true))
        }
    }
    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
