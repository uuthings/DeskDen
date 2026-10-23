import AppKit
import Foundation
import LauncherCore

/// System Trash integration only; identity checks, quarantine, permanent removal
/// and non-overwriting restoration are implemented by the core transaction.
struct SpaceCleaningAppFileOperations: SpaceCleaningFileOperating {
    func moveToTrash(_ source: URL) throws -> URL {
        var destination: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
        guard let destination = destination as URL? else {
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }
}
