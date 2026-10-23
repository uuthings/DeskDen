import SwiftUI
import LauncherCore

struct SpaceCleaningDialogContent: View {
    @ObservedObject var model: SpaceCleaningModel
    let dialog: CleaningDialog
    @Environment(\.workbenchPalette) private var palette

    @ViewBuilder var body: some View {
        switch dialog {
        case .rules: SpaceCleaningRulesDialog(dismiss: model.closeDialog)
        case .scope: scopeDialog
        case .confirm:
            SpaceCleaningConfirmationDialog(items: model.selectedItems.map { .init(id: $0.id.uuidString, name: $0.name, bytes: $0.bytes) },
                                            totalBytes: model.selectedBytes, initiallyPermanent: model.method == .permanent, initiallyRemember: model.rememberMethod,
                                            acknowledgement: $model.acknowledgement, dismiss: model.closeDialog,
                                            confirm: model.executeConfirmed)
        case .purpose(let id): purposeDialog(id)
        case .restore(let id):
            if model.batches.contains(where: { $0.id == id }) || model.currentBatch?.id == id {
                SpaceCleaningRestoreDialog(itemCount: model.pendingHistoryItems.count,
                    conflictNames: model.pendingHistoryItems.filter { $0.canRestore && FileManager.default.fileExists(atPath: $0.originalURL.path) }.map(\.name),
                    dismiss: model.closeDialog, restore: { model.executeRestore(batchID: id, renameConflicts: $0) })
            } else { unavailableDialog }
        case .purge(let id):
            if let batch = model.batches.first(where: { $0.id == id }) ?? (model.currentBatch?.id == id ? model.currentBatch : nil) {
                let items = batch.items.filter(\.canPurge)
                SpaceCleaningPurgeDialog(items: items.map { .init(id: $0.id.uuidString, name: $0.name, bytes: $0.bytes) },
                    totalBytes: items.reduce(0) { partial, item in let sum = partial.addingReportingOverflow(item.bytes); return sum.overflow ? .max : sum.partialValue },
                    dismiss: model.closeDialog, purge: { model.executePurge(batchID: id) }, acknowledged: $model.acknowledgement)
            } else { unavailableDialog }
        case .issues: issuesDialog
        }
    }
    private var scopeDialog: some View {
        WorkbenchDialogFrame(title: "扫描范围", dismiss: model.closeDialog) {
            VStack(alignment: .leading, spacing: 0) {
                Text("默认从这台 Mac 的常用位置开始").font(.system(size: 11)).foregroundStyle(palette.muted).padding(.bottom, 12)
                scopeChoice(.recommended, title: "此 Mac · 推荐范围", subtitle: "当前用户缓存、开发构建、下载文件及保护核验")
                scopeChoice(.xcode, title: "Xcode 与本地测试构建", subtitle: "DerivedData、Archives 与本地构建位置")
                scopeChoice(.downloads, title: "下载文件夹", subtitle: "只查看下载目录中的文件，并核验保护规则")
                Rectangle().fill(palette.line).frame(height: 1)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自选目录").font(.system(size: 12, weight: .medium))
                        Text(model.scopeChoice == .custom ? model.scopeSummary : "需要时，指定其他本地文件夹")
                            .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(3).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择文件夹", action: model.chooseCustomDirectory).buttonStyle(WBButtonStyle()).disabled(model.isBusy)
                }.padding(.vertical, 13)
                Text("调整范围不会立即扫描，也不会自动选择文件。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 8)
            }
        } actions: {
            Spacer()
            Button("完成", action: model.closeDialog).buttonStyle(WBButtonStyle(primary: true))
        }.accessibilityIdentifier("space-cleaning-scope-dialog")
    }
    private func scopeChoice(_ choice: CleaningScopeChoice, title: String, subtitle: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.line).frame(height: 1)
            SpaceCleaningChoiceRow(title: title, subtitle: subtitle, selected: model.scopeChoice == choice, disabled: model.isBusy) { model.selectScope(choice) }
        }
    }
    private func purposeDialog(_ id: UUID) -> some View {
        let file = model.items.first { $0.id == id }
        return WorkbenchDialogFrame(title: "确认测试用途", dismiss: model.closeDialog) {
            VStack(alignment: .leading, spacing: 16) {
                Text(file?.name ?? "所选项目").font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                Text("名称、签名或存放时间无法证明它只是测试文件。确认用途后，这一项会进入人工复核；不会自动勾选，也不会改变其他归档的保护。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(5)
                Toggle("我确认它仅用于测试，不是正式发布原件或唯一保留归档", isOn: $model.acknowledgement)
                    .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .accessibilityIdentifier("space-cleaning-test-purpose-acknowledgement")
            }
        } actions: {
            Spacer()
            Button("继续保留", action: model.closeDialog).buttonStyle(WBButtonStyle())
            Button("确认为测试用途") { model.confirmTestPurpose(id) }.buttonStyle(WBButtonStyle(primary: true))
                .disabled(!model.acknowledgement || file?.needsPurposeConfirmation != true)
        }.accessibilityIdentifier("space-cleaning-purpose-dialog")
    }
    private var issuesDialog: some View {
        WorkbenchDialogFrame(title: "扫描覆盖范围", dismiss: model.closeDialog) {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.coverageIssues.isEmpty ? "扫描只覆盖已识别和已选择的位置。未安装软件对应的可选目录会正常跳过。" : "下列位置或项目没有得到完整结果。已检查的数据仍可查看，不能据此认为整台 Mac 都已扫描。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(5)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.coverageIssues.enumerated()), id: \.offset) { _, issue in
                            Label(issue, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        if !model.coverageNotes.isEmpty {
                            Text("范围说明").font(.system(size: 12, weight: .medium)).padding(.top, model.coverageIssues.isEmpty ? 0 : 6)
                            ForEach(Array(model.coverageNotes.enumerated()), id: \.offset) { _, note in
                                Text(note).font(.system(size: 11)).foregroundStyle(palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).background(WorkbenchOverlayScrollbars())
                }.frame(maxHeight: 280).scrollBounceBehavior(.basedOnSize)
            }
        } actions: {
            Spacer()
            Button("知道了", action: model.closeDialog).buttonStyle(WBButtonStyle(primary: true))
        }.accessibilityIdentifier("space-cleaning-issues-dialog")
    }
    private var unavailableDialog: some View {
        WorkbenchDialogFrame(title: "记录已更新", dismiss: model.closeDialog) {
            Text("这次处理记录当前不可用，请返回清理记录重新查看。")
                .font(.system(size: 12)).foregroundStyle(palette.secondary)
        } actions: {
            Spacer()
            Button("返回记录", action: model.closeDialog).buttonStyle(WBButtonStyle(primary: true))
        }
    }
}

struct SpaceCleaningRulesDialog: View {
    let dismiss: () -> Void
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchDialogFrame(title: "扫描与保护规则", dismiss: dismiss) {
            VStack(alignment: .leading, spacing: 16) {
                Text("默认从当前用户的常用位置开始。系统文件、其他用户目录、外接磁盘和云端未下载的内容不自动纳入。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(5)
                VStack(spacing: 0) {
                    rule("可重建缓存", status: "独立规则识别")
                    rule("测试 App 与测试归档", status: "可见 · 人工选择")
                    rule("用途不明的归档", status: "保留 · 可确认用途")
                    rule("正式发布原件与关联材料", status: "可见 · 受保护")
                    rule("已安装或正在使用的 App", status: "不直接清理")
                }
                Text("公证、签名、体积与修改时间，不单独决定是否属于测试文件。未获权限的位置会单独显示；扫描覆盖范围与全盘占用分别呈现。")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(5)
            }
        } actions: {
            Spacer()
            Button("知道了", action: dismiss).buttonStyle(WBButtonStyle(primary: true))
        }.accessibilityIdentifier("space-cleaning-rules")
    }
    private func rule(_ title: String, status: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.line).frame(height: 1)
            HStack(spacing: 12) {
                Text(title)
                Spacer(minLength: 12)
                Text(status).foregroundStyle(palette.muted)
            }.font(.system(size: 11)).padding(.vertical, 9)
        }
    }
}

struct SpaceCleaningChoiceRow: View {
    let title: String
    let subtitle: String
    let selected: Bool
    var disabled = false
    let select: () -> Void
    @Environment(\.workbenchPalette) private var palette

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15)).foregroundStyle(selected ? palette.accent : palette.muted).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.muted).lineSpacing(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 13).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
            .accessibilityElement(children: .ignore).accessibilityLabel(title + "，" + subtitle)
            .accessibilityValue(selected ? "已选择" : "未选择")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct SpaceCleaningConfirmationItem: Identifiable {
    let id: String
    let name: String
    let bytes: UInt64
}

struct SpaceCleaningConfirmationDialog: View {
    let items: [SpaceCleaningConfirmationItem]
    let totalBytes: UInt64
    let dismiss: () -> Void
    let confirm: (_ permanently: Bool, _ remember: Bool) -> Void
    @State private var permanently: Bool
    @State private var remember: Bool
    @Binding private var acknowledged: Bool
    @Environment(\.workbenchPalette) private var palette

    init(items: [SpaceCleaningConfirmationItem], totalBytes: UInt64, initiallyPermanent: Bool, initiallyRemember: Bool, acknowledgement: Binding<Bool>,
         dismiss: @escaping () -> Void, confirm: @escaping (Bool, Bool) -> Void) {
        self.items = items; self.totalBytes = totalBytes; self.dismiss = dismiss; self.confirm = confirm
        _permanently = State(initialValue: initiallyPermanent)
        _remember = State(initialValue: initiallyRemember)
        _acknowledged = acknowledgement
    }
    var body: some View {
        WorkbenchDialogFrame(title: "确认处理 \(items.count) 项文件", dismiss: dismiss) {
            VStack(alignment: .leading, spacing: 0) {
                Text("仅处理你明确选择的项目").font(.system(size: 11)).foregroundStyle(palette.muted)
                Text(SpaceCleaningFormat.bytes(totalBytes)).font(.system(size: 30, weight: .medium)).monospacedDigit().padding(.top, 12).padding(.bottom, 16)
                Rectangle().fill(palette.line).frame(height: 1)
                SpaceCleaningChoiceRow(title: "移到废纸篓", subtitle: "可从清理记录恢复。移入废纸篓暂不计为已释放空间。", selected: !permanently) { permanently = false; acknowledged = false }
                Rectangle().fill(palette.line).frame(height: 1)
                SpaceCleaningChoiceRow(title: "永久删除", subtitle: "直接删除所选文件，无法从本次记录恢复。", selected: permanently) { permanently = true; acknowledged = false }
                SpaceCleaningConfirmationList(items: items).padding(.top, 4)
                Toggle("记住这种处理方式，下次仍需确认", isOn: $remember)
                    .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 16)
                    .accessibilityIdentifier("space-cleaning-remember-method")
                if permanently {
                    Toggle("我已复核所选项目，理解永久删除无法恢复", isOn: $acknowledged)
                        .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 12)
                        .accessibilityIdentifier("space-cleaning-permanent-acknowledgement")
                }
            }
        } actions: {
            Button("返回复核", action: dismiss).buttonStyle(WBButtonStyle())
            Spacer()
            Button(permanently ? "永久删除所选项目" : "移到废纸篓") { confirm(permanently, remember) }
                .buttonStyle(WBButtonStyle(primary: !permanently, destructive: permanently))
                .disabled(items.isEmpty || (permanently && !acknowledged))
                .accessibilityIdentifier("space-cleaning-confirm-execute")
        }.accessibilityIdentifier("space-cleaning-confirmation")
    }
}

private struct SpaceCleaningConfirmationList: View {
    let items: [SpaceCleaningConfirmationItem]
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    VStack(spacing: 0) {
                        Rectangle().fill(palette.line).frame(height: 1)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(item.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Text(SpaceCleaningFormat.bytes(item.bytes)).foregroundStyle(palette.muted).monospacedDigit().fixedSize()
                        }.font(.system(size: 11)).padding(.vertical, 8)
                    }
                }
            }.background(WorkbenchOverlayScrollbars())
        }.scrollBounceBehavior(.basedOnSize).frame(maxHeight: min(176, CGFloat(items.count) * 34 + 2))
    }
}

struct SpaceCleaningRestoreDialog: View {
    let itemCount: Int
    let conflictNames: [String]
    let dismiss: () -> Void
    let restore: (_ renameConflicts: Bool) -> Void
    @State private var renameConflicts = true
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchDialogFrame(title: "恢复本次项目", dismiss: dismiss) {
            VStack(alignment: .leading, spacing: 16) {
                Text("将 \(itemCount) 项恢复到原位置。恢复前重新核验废纸篓文件，现有内容不会被覆盖。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(5)
                if !conflictNames.isEmpty {
                    Label("原位置已有 \(conflictNames.count) 个同名项目", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.warning)
                    Text(conflictNames.prefix(4).joined(separator: "、") + (conflictNames.count > 4 ? " 等" : ""))
                        .font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(3)
                }
                VStack(spacing: 0) {
                    Rectangle().fill(palette.line).frame(height: 1)
                    SpaceCleaningChoiceRow(title: "保留两份", subtitle: "遇到同名文件时，为恢复的文件添加新名称。", selected: renameConflicts) { renameConflicts = true }
                    Rectangle().fill(palette.line).frame(height: 1)
                    SpaceCleaningChoiceRow(title: "跳过同名项目", subtitle: "同名项目留在废纸篓，其余项目正常恢复。", selected: !renameConflicts) { renameConflicts = false }
                }
            }
        } actions: {
            Spacer()
            Button("取消", action: dismiss).buttonStyle(WBButtonStyle())
            Button("恢复 \(itemCount) 项") { restore(renameConflicts) }.buttonStyle(WBButtonStyle(primary: true))
                .disabled(itemCount == 0).accessibilityIdentifier("space-cleaning-confirm-restore")
        }.accessibilityIdentifier("space-cleaning-restore-dialog")
    }
}

struct SpaceCleaningPurgeDialog: View {
    let items: [SpaceCleaningConfirmationItem]
    let totalBytes: UInt64
    let dismiss: () -> Void
    let purge: () -> Void
    @Binding var acknowledged: Bool
    @Environment(\.workbenchPalette) private var palette
    var body: some View {
        WorkbenchDialogFrame(title: "永久删除本次项目", dismiss: dismiss) {
            VStack(alignment: .leading, spacing: 16) {
                Text("仅删除本次记录中仍在废纸篓的 \(items.count) 项，共 \(SpaceCleaningFormat.bytes(totalBytes))。不会清空废纸篓中的其他内容。")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary).lineSpacing(5)
                SpaceCleaningConfirmationList(items: items)
                Toggle("我理解这一步完成后，这些项目将无法恢复", isOn: $acknowledged)
                    .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .accessibilityIdentifier("space-cleaning-purge-acknowledgement")
            }
        } actions: {
            Spacer()
            Button("取消", action: dismiss).buttonStyle(WBButtonStyle())
            Button("永久删除本次项目", action: purge).buttonStyle(WBButtonStyle(destructive: true))
                .disabled(items.isEmpty || !acknowledged).accessibilityIdentifier("space-cleaning-confirm-purge")
        }.accessibilityIdentifier("space-cleaning-purge-dialog")
    }
}
