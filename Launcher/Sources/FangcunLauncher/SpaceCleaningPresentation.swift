import Foundation
import LauncherCore

enum CleaningScreen: Equatable { case start, scope, scanning, results, processing, history }
enum CleaningResultGroup: String, CaseIterable { case rebuildable, review, protected }
enum CleaningScopeChoice: String, CaseIterable, Codable { case global, custom }
enum CleaningResultTab { case recommended, reviewable, protected }

struct CleaningItemDisplay: Identifiable {
    let id: UUID
    let name: String
    let url: URL
    let bytes: UInt64
    let sizeIsComplete: Bool
    let group: CleaningResultGroup
    let subtitle: String
    let reason: String
    let impact: String
    let isSelectable: Bool
    let needsPurposeConfirmation: Bool
    let kind: SpaceCleaningKind
    let isDirectory: Bool
    let modifiedDate: Date

    var typeTitle: String {
        switch url.pathExtension.lowercased() {
        case "app": return "应用程序"
        case "xcarchive": return "Xcode 归档"
        case "dmg": return "DMG 磁盘映像"
        case "pkg": return "PKG 安装包"
        case "zip", "tar", "gz", "7z", "rar": return url.pathExtension.uppercased() + " 压缩包"
        default:
            if isDirectory { return "文件夹" }
            return url.pathExtension.isEmpty ? "文件" : url.pathExtension.uppercased() + " 文件"
        }
    }
    /// Personal-file rows already carry their useful facts. Only show an
    /// explanation when a scan rule actually changes the available action.
    var handlingNote: String? {
        if group == .protected || group == .rebuildable || needsPurposeConfirmation || [.testApplication, .testArchive, .installerPackage, .downloadedDiskImage].contains(kind) {
            return reason + " " + impact
        }
        return nil
    }
    var needsSuggestionReview: Bool {
        isSelectable && [.installerPackage, .downloadedDiskImage, .oldDiagnostic].contains(kind)
    }
}

struct CleaningHistoryItemDisplay: Identifiable {
    let id: UUID
    let name: String
    let bytes: UInt64
    let state: SpaceCleaningRecordState
    let statusText: String
    let explanation: String
    let canRestore: Bool
    let canPurge: Bool
    let originalURL: URL
    let resultURL: URL?
}

struct CleaningHistoryBatchDisplay: Identifiable {
    let id: UUID
    let date: Date
    let method: SpaceCleaningMethod
    let items: [CleaningHistoryItemDisplay]
    let bytes: UInt64
    var deletedCount: Int { items.filter { $0.state == .deleted }.count }
    var attentionCount: Int { items.filter { [.failed, .needsReview, .prepared, .isolated, .deleting, .restoring].contains($0.state) }.count }
    var restorableCount: Int { items.filter(\.canRestore).count }
    var purgeableCount: Int { items.filter(\.canPurge).count }
}

enum CleaningDialog: Identifiable, Equatable {
    case scope, rules, confirm, purpose(UUID), restore(UUID), purge(UUID), issues
    var id: String {
        switch self {
        case .scope: "scope"
        case .rules: "rules"
        case .confirm: "confirm"
        case .purpose(let id): "purpose-\(id)"
        case .restore(let id): "restore-\(id)"
        case .purge(let id): "purge-\(id)"
        case .issues: "issues"
        }
    }
}
