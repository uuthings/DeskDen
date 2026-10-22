import SwiftUI
import LauncherCore

struct HealthApplicationCandidatesView: View {
    @ObservedObject var model: HealthApplicationReviewModel
    let compact: Bool
    let listHeight: CGFloat
    @Environment(\.workbenchPalette) private var palette
    @State private var details: HealthApplicationCandidate?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("退出应用需要单独确认").font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer(minLength: 0)
                Button("清空选择") { model.clearSelection() }.buttonStyle(WBButtonStyle(compact: true))
                    .disabled(model.selectedIDs.isEmpty).accessibilityIdentifier("health-app-clear-selection")
            }.frame(minHeight: 33).padding(.top, -3).padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.sourceIsCurrent {
                        ForEach(model.candidates) { candidate in
                            candidateRow(candidate, showsSeparator: candidate.id != model.candidates.last?.id)
                        }
                    }
                    if !model.sourceIsCurrent || model.candidates.isEmpty {
                        Text(model.sourceIsCurrent ? "本次没有可读的应用候选" : "尚未取得有效进程来源，暂不展示退出候选")
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                            .frame(maxWidth: .infinity, minHeight: listHeight)
                    }
                }
            }.frame(height: listHeight)
                .background(palette.soft, in: RoundedRectangle(cornerRadius: 9))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(palette.border, lineWidth: 1).allowsHitTesting(false))
                .accessibilityElement(children: .contain).accessibilityIdentifier("health-application-candidates")
        }.frame(maxWidth: .infinity, alignment: .leading)
            .workbenchModal(item: $details, width: 470) { candidate in applicationDetails(candidate) }
            .workbenchModal(item: Binding(get: { model.confirmation }, set: { if $0 == nil { model.cancelConfirmation() } }), width: 620,
                onRequestDismiss: model.cancelConfirmation) { plan in HealthApplicationConfirmationView(model: model, plan: plan) }
    }
    private func candidateRow(_ candidate: HealthApplicationCandidate, showsSeparator: Bool) -> some View {
        HStack(spacing: 8) {
            Toggle("选择退出" + candidate.name, isOn: Binding(get: { model.selectedIDs.contains(candidate.id) }, set: { _ in model.toggle(candidate) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(!model.canSelect(candidate))
                .accessibilityIdentifier("health-app-select-" + candidate.id)
            if !compact {
                DeviceProcessIcon(path: candidate.application?.bundlePath ?? candidate.mainProcess?.executablePath)
                    .frame(width: 27, height: 29)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(candidate.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(candidate.reason).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(DeviceFormat.bytes(candidate.residentBytes)).font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.secondary).monospacedDigit().fixedSize()
            Button { details = candidate } label: { Image(systemName: "info.circle").font(.system(size: 14)) }
                .buttonStyle(WBIconButtonStyle(size: 28)).help("查看" + candidate.name + "应用详情")
                .accessibilityLabel("查看" + candidate.name + "应用详情")
        }.padding(10).frame(minHeight: compact ? 58 : listHeight > 300 ? 66 : 58)
            .overlay(alignment: .bottom) { if showsSeparator { palette.border.frame(height: 1).allowsHitTesting(false) } }
            .foregroundStyle(candidate.isEligible ? palette.text : palette.secondary)
    }
    private func applicationDetails(_ candidate: HealthApplicationCandidate) -> some View {
        WorkbenchDialogFrame(title: candidate.name + " · 应用详情", dismiss: { details = nil }) {
            VStack(alignment: .leading, spacing: 14) {
                banner(candidate.name, detail: DeviceFormat.bytes(candidate.residentBytes) + " · " + (candidate.mainProcess.map { "PID \($0.pid)" } ?? "主进程不可核验"))
                fact("归属", candidate.application?.bundleIdentifier ?? "系统或独立后台进程 · 只读")
                fact("范围", "\(candidate.processes.count) 个按真实身份聚合的进程")
                fact("来源时间", candidate.sampledAt.formatted())
                Text(candidate.reason).font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                Text(candidate.isEligible ? "占用大小不代表异常。只有你明确选中，并确认已保存工作后，才会请求正常退出；应用仍可提示保存或拒绝退出。" : "此项目不会加入处理方案。占用大小本身不代表异常。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
        } actions: { Spacer(); Button("返回候选") { details = nil }.buttonStyle(WBButtonStyle(primary: true)) }
    }
    private func banner(_ title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "app.badge.checkmark").font(.system(size: 26)).foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).background(palette.soft, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(palette.line, lineWidth: 1))
    }
    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) { Text(label).foregroundStyle(palette.muted); Spacer(minLength: 0); Text(value).multilineTextAlignment(.trailing) }
            .font(.system(size: 11)).padding(.vertical, 6)
    }
}

struct HealthApplicationConfirmationView: View {
    @ObservedObject var model: HealthApplicationReviewModel
    let plan: HealthApplicationReviewPlan
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchDialogFrame(title: "确认处理所选项目", dismiss: model.cancelConfirmation) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "app.badge.checkmark").font(.system(size: 26)).foregroundStyle(palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(plan.candidates.count) 个应用").font(.system(size: 14, weight: .medium))
                        Text("仅请求正常退出 · 内存变化以新采样为准").font(.system(size: 11)).foregroundStyle(palette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(14).background(palette.soft, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(palette.line, lineWidth: 1))
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(plan.candidates) { candidate in
                            HStack(spacing: 12) {
                                Text("正常退出 " + candidate.name).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(DeviceFormat.bytes(candidate.residentBytes)).fixedSize()
                            }.font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.vertical, 9)
                                .overlay(alignment: .bottom) { palette.line.frame(height: 1) }
                        }
                    }
                }.frame(height: min(210, CGFloat(max(1, plan.candidates.count)) * 34))
                Toggle("已保存所选应用中的工作，确认请求正常退出", isOn: $model.savedWorkConfirmed)
                    .toggleStyle(.checkbox).font(.system(size: 11)).accessibilityIdentifier("health-app-saved-work-consent")
                Text("发送请求前再次核验应用身份、所属用户与来源时间，变化项目将跳过。本次不会处理文件，也不会强制结束进程。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Spacer(); Button("返回选择", action: model.cancelConfirmation).buttonStyle(WBButtonStyle())
            Button("确认处理", action: model.executeConfirmed).buttonStyle(WBButtonStyle(primary: true))
                .disabled(!model.savedWorkConfirmed).accessibilityLabel("确认请求正常退出所选应用")
                .accessibilityIdentifier("health-app-confirm-quit")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("health-application-confirmation")
    }
}

struct HealthApplicationResultLog: View {
    @ObservedObject var model: HealthApplicationReviewModel
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本次处理记录").font(.system(size: 12, weight: .medium)).padding(.bottom, 2)
            ForEach(model.results) { result in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: result.state == .requested ? "checkmark" : result.state == .pending ? "clock" : "info.circle")
                        .foregroundStyle(result.state == .requested ? palette.success : palette.muted).frame(width: 14)
                    Text(result.candidate.name).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(result.detail).font(.system(size: 11)).foregroundStyle(palette.secondary)
                        .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 8).overlay(alignment: .top) { palette.line.frame(height: 1) }
            }
            Label("应用是否结束、内存是否变化，以后续有效采样为准", systemImage: "checkmark.shield")
                .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 6)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.soft, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.line, lineWidth: 1))
            .accessibilityElement(children: .contain).accessibilityIdentifier("health-application-results")
    }
}
