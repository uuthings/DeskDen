import Foundation
import LauncherCore

enum CleaningScreen: Equatable { case start, scanning, results, processing, finished, history }
enum CleaningResultGroup: String, CaseIterable { case rebuildable, review, protected }
enum CleaningScopeChoice: String, CaseIterable, Codable { case recommended, xcode, downloads, custom }
enum CleaningLaneState { case pending, active, complete }

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
}

struct CleaningScanLane: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var state: CleaningLaneState
    var checkedCount: Int
    var path: String
    var currentFile: String
    var decision: String
}

struct CleaningHistoryItemDisplay: Identifiable {
    let id: UUID
    let name: String
    let bytes: UInt64
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
