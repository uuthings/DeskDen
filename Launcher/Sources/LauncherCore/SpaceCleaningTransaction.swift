import Foundation
import Darwin

public enum SpaceCleaningMethod: String, Codable, CaseIterable, Sendable { case trash, permanent }
public enum SpaceCleaningRestoreConflict: String, Codable, Sendable { case skip, rename }
public enum SpaceCleaningRecordState: String, Codable, Sendable {
    case prepared, isolated, trashed, deleting, deleted, restoring, restored, skipped, cancelled, failed, needsReview
}
public protocol SpaceCleaningFileOperating: Sendable {
    /// Return the system's actual destination; a thrown error is not proof that
    /// the source did not move. The transaction reconciles all recorded evidence.
    func moveToTrash(_ source: URL) throws -> URL
    /// Deletes a simulator through Xcode's own tool. Returning normally means
    /// the tool reported success; the transaction still checks the result.
    func deleteSimulator(udid: String) throws
}
extension SpaceCleaningFileOperating {
    public func deleteSimulator(udid: String) throws {
        throw SpaceCleaningFilesystem.Failure(message: "当前处理方式不能删除模拟器，未处理。")
    }
}
public struct SpaceCleaningTreeProof: Codable, Equatable, Sendable {
    public var sha256: String
    /// Entries covered by a content proof. Released builds reject records whose
    /// count exceeds `maximumContentEntries`, and a rejected record makes the
    /// whole history unreadable there, so a whole-folder proof stores at most
    /// that many here and keeps its full count in `metadataEntryCount`.
    public var entryCount: Int
    public var logicalBytes: UInt64
    public var rootIdentity: SpaceCleaningFileIdentity
    /// True for whole-folder proofs: identities, sizes, times and link targets
    /// without file contents. Optional so older receipts stay readable; older
    /// builds cannot match such a proof and therefore never act on it.
    public var metadataOnly: Bool?
    /// The full entry count of a whole-folder proof. Absent in content proofs
    /// and in whole-folder proofs written before this field existed.
    public var metadataEntryCount: Int?
    public static let maximumContentEntries = 100_000
    public static let maximumMetadataEntries = 5_000_000
    public init(sha256: String, entryCount: Int, logicalBytes: UInt64, rootIdentity: SpaceCleaningFileIdentity, metadataOnly: Bool? = nil) {
        self.sha256 = sha256; self.logicalBytes = logicalBytes
        self.rootIdentity = rootIdentity; self.metadataOnly = metadataOnly
        if metadataOnly == true {
            self.entryCount = min(entryCount, Self.maximumContentEntries); metadataEntryCount = entryCount
        } else {
            self.entryCount = entryCount
        }
    }
    /// Entries the proof actually covers.
    public var coveredEntries: Int { metadataOnly == true ? metadataEntryCount ?? entryCount : entryCount }
    public var isValid: Bool {
        guard sha256.utf8.count == 64 && sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        guard metadataOnly == true else { return metadataEntryCount == nil && (1...Self.maximumContentEntries).contains(entryCount) }
        guard let full = metadataEntryCount else { return (1...Self.maximumMetadataEntries).contains(entryCount) }
        return (1...Self.maximumMetadataEntries).contains(full) && entryCount == min(full, Self.maximumContentEntries)
    }
    public func matches(_ other: Self) -> Bool {
        sha256 == other.sha256 && coveredEntries == other.coveredEntries && logicalBytes == other.logicalBytes &&
        (metadataOnly ?? false) == (other.metadataOnly ?? false) &&
        rootIdentity.matchesMovedResource(other.rootIdentity) && rootIdentity.mode == other.rootIdentity.mode
    }
}
public struct SpaceCleaningRecord: Identifiable, Codable, Equatable, Sendable {
    public var schema = 1
    public var id: UUID
    public var operationID: UUID
    public var candidate: SpaceCleaningCandidate
    public var method: SpaceCleaningMethod
    public var state: SpaceCleaningRecordState
    public var createdAt: Date
    public var updatedAt: Date
    public var locationURL: URL?
    /// Retained before a purge replaces locationURL with its isolation target.
    /// Optional so existing schema-1 receipts remain readable.
    public var previousTrashURL: URL?
    public var isolationURL: URL?
    public var restoredURL: URL?
    public var proof: SpaceCleaningTreeProof?
    public var explanation: String
    public var originalURL: URL { candidate.url }
    public var canRestore: Bool { state == .trashed && proof?.isValid == true && locationURL != nil }
    public var canPurge: Bool { canRestore }
    public init(id: UUID = UUID(), operationID: UUID, candidate: SpaceCleaningCandidate, method: SpaceCleaningMethod, at date: Date = Date()) {
        self.id = id; self.operationID = operationID; self.candidate = candidate; self.method = method
        state = .prepared; createdAt = date; updatedAt = date; explanation = "正在核验所选项目。"
    }
    public func validated() throws -> Self {
        guard schema == 1, candidate.url.isFileURL, candidate.rootURL.isFileURL,
              candidate.url.path.hasPrefix(candidate.rootURL.path + "/"), candidate.rootURL.path != "/",
              candidate.url.pathComponents.allSatisfy({ $0 != ".." && $0 != "." }),
              locationURL?.isFileURL ?? true, previousTrashURL?.isFileURL ?? true,
              isolationURL?.isFileURL ?? true, restoredURL?.isFileURL ?? true,
              previousTrashURL == nil || (proof != nil && previousTrashURL?.path != originalURL.path),
              proof?.isValid ?? true, proof.map({ candidate.identity.matchesMovedResource($0.rootIdentity) && candidate.identity.mode == $0.rootIdentity.mode }) ?? true,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              abs(createdAt.timeIntervalSince1970) < 100_000_000_000, abs(updatedAt.timeIntervalSince1970) < 100_000_000_000,
              ![.trashed, .deleting, .deleted, .restoring, .restored].contains(state) || proof != nil,
              ![.trashed, .deleting, .restoring].contains(state) || locationURL != nil,
              state != .restored || restoredURL != nil else { throw SpaceCleaningFilesystem.Failure(message: "空间清理记录无效，原记录已保留。") }
        if let isolationURL {
            guard SpaceCleaningFilesystem.isIsolationDirectoryName(isolationURL.lastPathComponent, recordID:id) else {
                throw SpaceCleaningFilesystem.Failure(message: "隔离位置记录无效，未操作文件。")
            }
        }
        return self
    }
}

/// Serial, per-item transactions. The app owns the batch loop and invokes the
/// policy closure with a fresh running-app/release-protection context. Nothing
/// here selects candidates, invents release provenance, or empties the Trash.
public enum SpaceCleaningTransaction {
    public static func execute(candidate: SpaceCleaningCandidate, operationID: UUID, method: SpaceCleaningMethod,
                               permanentConfirmed: Bool = false, mover: any SpaceCleaningFileOperating,
                               isCancelled: () -> Bool = { false }, validatePolicy: (SpaceCleaningCandidate) -> String?,
                               validateActivity: (SpaceCleaningCandidate, URL) -> String? = { _, _ in nil },
                               persist: (SpaceCleaningRecord) throws -> Void) -> SpaceCleaningRecord {
        if let device = candidate.simulator {
            return executeSimulator(candidate, device: device, operationID: operationID, permanentConfirmed: permanentConfirmed,
                                    mover: mover, isCancelled: isCancelled, validatePolicy: validatePolicy,
                                    validateActivity: validateActivity, persist: persist)
        }
        var record = SpaceCleaningRecord(operationID: operationID, candidate: candidate, method: method)
        guard !isCancelled() else { return finish(record, .cancelled, "已取消，未处理项目。", persist) }
        guard method != .permanent || permanentConfirmed else { return finish(record, .skipped, "永久删除尚未明确确认，未处理项目。", persist) }
        guard SpaceCleaningDevelopmentPolicy.reason(at: candidate.url) == nil else {
            return finish(record, .skipped, "开发环境或版本资料保持保护，未处理内部文件。", persist)
        }
        guard candidate.canProcess, SpaceCleaningFilesystem.validateAncestors(candidate),
              SpaceCleaningFilesystem.capture(candidate.url) == candidate.identity else {
            return finish(record, .skipped, "项目受保护、未完整扫描，或文件与父目录身份已变化。", persist)
        }
        let bulk = candidate.isBulkVerified == true
        let buildOutput = bulk ? SpaceCleaningBuildOutputs.kind(of: candidate.url) : nil
        // Whole-folder verification is limited to recognized build output and
        // the known large caches; nothing else may skip the content proof.
        if bulk, buildOutput == nil, !(candidate.kind == .packageCache && SpaceCleaningKnownLocations.allowsBulk(candidate.url)) {
            return finish(record, .skipped, "整体核验仅用于已识别的构建产物与大型缓存，未处理项目。", persist)
        }
        if let reason = validatePolicy(candidate) { return finish(record, .skipped, reason, persist) }
        if let reason = validateActivity(candidate, candidate.url) { return finish(record, .skipped, reason, persist) }
        do {
            let selected = try bulk
                ? SpaceCleaningFilesystem.metadataSnapshot(candidate.url, expected: candidate.identity, allowRename: false, isCancelled: isCancelled)
                : SpaceCleaningFilesystem.snapshot(candidate.url, expected: candidate.identity, allowRename: false, isCancelled: isCancelled)
            if bulk {
                if selected.containsReleaseContent {
                    return finish(record, .skipped, "目录中包含安装包、Xcode 归档或发布档案，保留整个目录。", persist)
                }
                if buildOutput != nil, Double(selected.latestFileModification) > Date().timeIntervalSince1970 - SpaceCleaningBuildOutputs.recentWindow {
                    return finish(record, .skipped, "最近 7 天内仍有构建或测试，已保留。", persist)
                }
            } else {
                // A few fixed caches and assistant outputs store unpacked packages or
                // generated prototypes; only those paths skip this project check.
                let knownStructure = [.packageCache, .personalFile].contains(candidate.kind) && SpaceCleaningKnownLocations.allowsProjectNames(candidate.url)
                if !knownStructure, let reason = SpaceCleaningDevelopmentPolicy.reason(in: selected) {
                    return finish(record, .skipped, reason, persist)
                }
            }
            guard !isCancelled(), SpaceCleaningFilesystem.validateAncestors(candidate),
                  SpaceCleaningFilesystem.capture(candidate.url) == candidate.identity else { throw SpaceCleaningFilesystem.Failure(message: "内容核验后项目或父目录已变化。") }
            if let reason = validatePolicy(candidate) { throw SpaceCleaningFilesystem.Failure(message: reason) }
            record.proof = selected.proof
            let isolation = candidate.url.deletingLastPathComponent().appendingPathComponent(".deskden-cleaning-" + record.id.uuidString, isDirectory: true)
            record.isolationURL = isolation
            // Persist both locations before creating or moving anything, including
            // the narrow crash window between the atomic rename and its receipt.
            record.locationURL = isolation.appendingPathComponent(candidate.url.lastPathComponent)
            record.explanation = "已记录处理意图，正在隔离并复核所选项目。"
            try persist(record)
            guard !isCancelled() else { return finish(record, .cancelled, "已取消，未移动项目。", persist) }
            guard SpaceCleaningFilesystem.validateAncestors(candidate), SpaceCleaningFilesystem.capture(candidate.url) == candidate.identity else {
                return finish(record, .skipped, "意图保存后项目或父目录已变化，未移动项目。", persist)
            }
            if let reason = validatePolicy(candidate) { return finish(record, .skipped, reason, persist) }
            try SpaceCleaningFilesystem.makeIsolation(isolation, candidate: candidate)
            guard SpaceCleaningFilesystem.validateAncestors(candidate), SpaceCleaningFilesystem.capture(candidate.url) == candidate.identity else {
                SpaceCleaningFilesystem.removeEmptyIsolation(isolation)
                return finish(record, .skipped, "隔离前项目或父目录已变化，未移动项目。", persist)
            }
            try SpaceCleaningFilesystem.move(candidate.url, to: record.locationURL!, expected: candidate.identity)
            record.state = .isolated; record.updatedAt = Date()
            try persist(record)
            // A rename keeps a whole folder's objects; its identity is the check here,
            // and the tree is walked again once it reaches the Trash.
            let isolated: SpaceCleaningFilesystem.Snapshot
            if bulk {
                guard let moved = SpaceCleaningFilesystem.capture(record.locationURL!), candidate.identity.matchesMovedResource(moved) else {
                    throw SpaceCleaningFilesystem.Failure(message: "隔离后项目身份核验未通过。")
                }
                isolated = selected
            } else {
                isolated = try verifiedSnapshot(record, at: record.locationURL!, isCancelled: isCancelled, lease: selected.lease)
            }
            guard !isCancelled() else { return rollback(record, explanation: "已取消。", persist: persist) }
            if let reason = validateActivity(candidate, record.locationURL!) { return rollback(record, explanation: reason, persist: persist) }
            if method == .permanent {
                return erase(record, snapshot: isolated, isCancelled: isCancelled,
                             validateActivity: { validateActivity(candidate, record.locationURL!) }, persist: persist)
            }
            let destination = try mover.moveToTrash(record.locationURL!)
            guard destination.isFileURL else { throw SpaceCleaningFilesystem.Failure(message: "系统未返回可核验的废纸篓位置。") }
            record.locationURL = destination; record.updatedAt = Date()
            // Keep the nonterminal state until destination identity AND complete
            // content have matched. A path returned by an API is not evidence.
            try persist(record)
            _ = try verifiedSnapshot(record, at: destination, isCancelled: { false }, lease: selected.lease)
            record.state = .trashed; record.explanation = bulk ? wholeFolderTrashedExplanation : trashedExplanation
            record.updatedAt = Date()
            do { try persist(record) }
            catch { return rollback(record, explanation: "移动结果未能保存。", persist: persist) }
            SpaceCleaningFilesystem.removeEmptyIsolation(isolation)
            return record
        } catch {
            if record.state == .isolated || record.locationURL.map({ SpaceCleaningFilesystem.capture($0) != nil }) == true {
                return rollback(record, explanation: error.localizedDescription, persist: persist)
            }
            if let isolation = record.isolationURL { SpaceCleaningFilesystem.removeEmptyIsolation(isolation) }
            let unchanged = SpaceCleaningFilesystem.validateAncestors(candidate) && SpaceCleaningFilesystem.capture(candidate.url) == candidate.identity
            return finish(record, unchanged ? (isCancelled() ? .cancelled : .failed) : .needsReview,
                          error.localizedDescription + (unchanged ? " 原项目仍可核验，未记为清理成功。" : " 无法确认当前位置，请在 Finder 中核对；未重复处理。"), persist)
        }
    }

    public static func restore(record original: SpaceCleaningRecord, conflict: SpaceCleaningRestoreConflict,
                               isCancelled: () -> Bool = { false }, validatePolicy: (SpaceCleaningCandidate) -> String? = { _ in nil },
                               persist: (SpaceCleaningRecord) throws -> Void) -> SpaceCleaningRecord {
        guard (try? original.validated()) != nil, original.canRestore, let source = original.locationURL else { return original }
        var record = original
        guard !isCancelled() else { return original }
        if let reason = validatePolicy(record.candidate) { record.explanation = reason; try? persist(record); return record }
        switch SpaceCleaningFilesystem.ancestorStatus(record.candidate) {
        case .valid: break
        case .unavailable:
            return finish(record, .trashed, "原位置暂时无法访问（权限或所在卷变化），未恢复；废纸篓中的项目保持可恢复，可稍后重试。", persist)
        case .changed:
            return finish(record, .needsReview, "原父目录已变化，未自动恢复；请在 Finder 中核对。", persist)
        }
        do {
            let current = try verifiedSnapshot(record, at: source, isCancelled: isCancelled)
            var destination = record.originalURL
            if !SpaceCleaningFilesystem.absent(destination) {
                guard conflict == .rename else {
                    record.explanation = "原位置已有同名项目，已跳过；废纸篓中的项目仍可恢复。"; record.updatedAt = Date()
                    try persist(record); return record
                }
                destination = try availableRestoreURL(record.originalURL)
            }
            record.restoredURL = destination; record.state = .restoring; record.updatedAt = Date()
            record.explanation = "已记录恢复意图，正在恢复完整项目。"
            try persist(record)
            guard !isCancelled(), SpaceCleaningFilesystem.validateAncestors(record.candidate), SpaceCleaningFilesystem.absent(destination) else {
                record.state = .trashed; record.restoredURL = nil
                return finish(record, .trashed, "恢复已取消，或原位置出现同名项目；未覆盖任何内容。", persist)
            }
            _ = try verifiedSnapshot(record, at: source, isCancelled: isCancelled, lease: current.lease)
            if let reason = validatePolicy(record.candidate) {
                record.restoredURL = nil
                return finish(record, .trashed, reason, persist)
            }
            try SpaceCleaningFilesystem.move(source, to: destination, expected: current.proof.rootIdentity)
            _ = try verifiedSnapshot(record, at: destination, isCancelled: { false }, lease: current.lease)
            guard SpaceCleaningFilesystem.absent(source), SpaceCleaningFilesystem.validateAncestors(record.candidate) else {
                throw SpaceCleaningFilesystem.Failure(message: "恢复后位置核验未通过。")
            }
            return finish(record, .restored, destination == record.originalURL ? "已恢复到原位置。请重新扫描后再处理此项目。" : "已保留原有同名项目，并以新名称恢复。请重新扫描后再处理。", persist)
        } catch {
            // Restore errors do not trigger another move. If the old Trash item
            // still matches it remains recoverable; otherwise require review.
            if let destination = record.restoredURL,
               (try? verifiedSnapshot(record, at: destination, isCancelled: { false })) != nil,
               SpaceCleaningFilesystem.absent(source), SpaceCleaningFilesystem.validateAncestors(record.candidate) {
                return finish(record, .restored, "已核验项目恢复到记录位置。请重新扫描后再处理。", persist)
            }
            if (try? verifiedSnapshot(record, at: source, isCancelled: { false })) != nil {
                record.restoredURL = nil
                return finish(record, .trashed, "恢复未完成，原废纸篓项目仍可核验：" + error.localizedDescription, persist)
            }
            // Unreadable is not changed: keep the entry when nothing reached the destination.
            if SpaceCleaningFilesystem.presence(source) == .unavailable,
               record.restoredURL.map({ SpaceCleaningFilesystem.presence($0) == .absent }) ?? true {
                record.restoredURL = nil
                return finish(record, .trashed, "暂时无法读取废纸篓中的项目，未恢复；恢复入口保留，可稍后重试。", persist)
            }
            return finish(record, .needsReview, "恢复中断，未覆盖或重复移动项目：" + error.localizedDescription, persist)
        }
    }

    /// Operates on one verified receipt from the user's selected batch. There is
    /// deliberately no global empty-Trash operation or directory enumeration.
    public static func purge(record original: SpaceCleaningRecord, permanentConfirmed: Bool,
                             isCancelled: () -> Bool = { false }, validatePolicy: (SpaceCleaningCandidate) -> String? = { _ in nil },
                             persist: (SpaceCleaningRecord) throws -> Void) -> SpaceCleaningRecord {
        guard permanentConfirmed, (try? original.validated()) != nil, original.canPurge,
              let source = original.locationURL, !isCancelled() else { return original }
        var record = original
        if SpaceCleaningDevelopmentPolicy.reason(at: record.originalURL) != nil || SpaceCleaningDevelopmentPolicy.reason(at: source) != nil {
            record.explanation = "开发环境或版本资料保持保护，可恢复或在 Finder 中复核，不执行永久删除。"
            try? persist(record); return record
        }
        if let reason = validatePolicy(record.candidate) { record.explanation = reason; try? persist(record); return record }
        do {
            let current = try verifiedSnapshot(record, at: source, isCancelled: isCancelled)
            let knownStructure = [.packageCache, .personalFile].contains(record.candidate.kind) && SpaceCleaningKnownLocations.allowsProjectNames(record.originalURL)
            if !knownStructure, let reason = SpaceCleaningDevelopmentPolicy.reason(in: current) {
                return finish(record, .trashed, reason + " 可从清理记录恢复，未永久删除。", persist)
            }
            // A fresh unique directory in the same Trash parent avoids moving
            // across volumes and never touches any unrelated Trash entries.
            let isolation = source.deletingLastPathComponent().appendingPathComponent(".deskden-cleaning-" + record.id.uuidString + "-" + UUID().uuidString, isDirectory: true)
            record.previousTrashURL = source
            record.isolationURL = isolation; record.locationURL = isolation.appendingPathComponent(source.lastPathComponent)
            record.state = .prepared; record.explanation = "已记录本批次项目永久删除意图。"; record.updatedAt = Date()
            try persist(record)
            guard !isCancelled() else { return finish(original, .trashed, "已取消永久删除。", persist) }
            if let reason = validatePolicy(record.candidate) { return finish(original, .trashed, reason, persist) }
            try SpaceCleaningFilesystem.makeIsolation(isolation)
            try SpaceCleaningFilesystem.move(source, to: record.locationURL!, expected: current.proof.rootIdentity)
            record.state = .isolated; record.updatedAt = Date(); try persist(record)
            let isolated = try verifiedSnapshot(record, at: record.locationURL!, isCancelled: isCancelled, lease: current.lease)
            return erase(record, snapshot: isolated, isCancelled: isCancelled, validateActivity: { validatePolicy(record.candidate) }, persist: persist)
        } catch {
            if (try? verifiedSnapshot(original, at: source, isCancelled: { false })) != nil {
                if let isolation = record.isolationURL { SpaceCleaningFilesystem.removeEmptyIsolation(isolation) }
                return finish(original, .trashed, "本次永久删除未完成，项目仍在废纸篓：" + error.localizedDescription, persist)
            }
            // Unreadable before anything moved: the original Trash entry stays recoverable.
            if SpaceCleaningFilesystem.presence(source) == .unavailable,
               record.locationURL == original.locationURL || record.locationURL.map({ SpaceCleaningFilesystem.presence($0) == .absent }) == true {
                if let isolation = record.isolationURL, isolation != original.isolationURL { SpaceCleaningFilesystem.removeEmptyIsolation(isolation) }
                return finish(original, .trashed, "暂时无法读取废纸篓中的项目，未永久删除；恢复和永久删除入口保留。", persist)
            }
            return finish(record, .needsReview, "永久删除尚未确认完成，请核对记录位置；未重复删除：" + error.localizedDescription, persist)
        }
    }

    /// A simulator is deleted only through Xcode's tool (`simctl delete`), never
    /// moved or removed file by file: CoreSimulator owns the device set. It
    /// cannot be restored, so it needs the irreversible-action confirmation
    /// whichever method the batch uses, and its record is always permanent.
    private static func executeSimulator(_ candidate: SpaceCleaningCandidate, device: SpaceCleaningSimulatorDevice, operationID: UUID,
                                         permanentConfirmed: Bool, mover: any SpaceCleaningFileOperating, isCancelled: () -> Bool,
                                         validatePolicy: (SpaceCleaningCandidate) -> String?,
                                         validateActivity: (SpaceCleaningCandidate, URL) -> String?,
                                         persist: (SpaceCleaningRecord) throws -> Void) -> SpaceCleaningRecord {
        var record = SpaceCleaningRecord(operationID: operationID, candidate: candidate, method: .permanent)
        guard !isCancelled() else { return finish(record, .cancelled, "已取消，未处理项目。", persist) }
        guard permanentConfirmed else { return finish(record, .skipped, "模拟器不能移入废纸篓，删除前需要确认无法恢复；未处理。", persist) }
        // The same folder, the same shut-down device and no use since the scan.
        func unchanged() -> Bool {
            candidate.canProcess && SpaceCleaningFilesystem.validateAncestors(candidate) &&
                SpaceCleaningFilesystem.capture(candidate.url) == candidate.identity &&
                SpaceCleaningSimulators.device(at: candidate.url) == device && device.isShutdown
        }
        guard unchanged() else { return finish(record, .skipped, "模拟器在扫描后被使用、状态已变化或受保护，未删除；请重新扫描。", persist) }
        if let reason = validatePolicy(candidate) { return finish(record, .skipped, reason, persist) }
        if let reason = validateActivity(candidate, candidate.url) { return finish(record, .skipped, reason, persist) }
        guard !isCancelled() else { return finish(record, .cancelled, "已取消，未删除模拟器。", persist) }
        guard unchanged() else { return finish(record, .skipped, "核验期间模拟器状态已变化，未删除；请重新扫描。", persist) }
        record.proof = SpaceCleaningSimulators.proof(for: device, identity: candidate.identity, logicalBytes: candidate.logicalBytes)
        record.locationURL = candidate.url
        record.state = .deleting; record.updatedAt = Date()
        record.explanation = "已记录不可恢复的删除意图，正在通过 Xcode 的 simctl 删除模拟器。"
        do { try persist(record) } catch {
            var untouched = record; untouched.proof = nil; untouched.locationURL = nil
            return finish(untouched, .failed, "删除意图未能保存，未删除模拟器：" + error.localizedDescription, persist)
        }
        do {
            try mover.deleteSimulator(udid: device.udid)
        } catch {
            // A reported failure is not proof that nothing changed.
            if SpaceCleaningFilesystem.capture(candidate.url) == candidate.identity, SpaceCleaningSimulators.device(at: candidate.url) == device {
                return finish(record, .failed, "模拟器未删除，原设备保持不变：" + error.localizedDescription, persist)
            }
            return finish(record, .needsReview, "模拟器删除未确认完成，请在 Xcode 的「设备与模拟器」窗口中核对：" + error.localizedDescription, persist)
        }
        guard SpaceCleaningFilesystem.absent(candidate.url) else {
            return finish(record, .needsReview, "simctl 报告已删除，但设备文件夹仍在；请在 Xcode 的「设备与模拟器」窗口中核对。", persist)
        }
        return finish(record, .deleted, "已通过 Xcode 的 simctl 删除模拟器，不经过废纸篓，无法恢复。", persist)
    }

    /// A review record may regain its restore entry only when it describes an
    /// item that reached the system Trash through this flow and nothing else
    /// (a purge, a restore or a still-isolated move) can have moved it since.
    public static func canReverify(_ record: SpaceCleaningRecord) -> Bool {
        guard record.state == .needsReview, record.method == .trash, record.proof?.isValid == true,
              record.previousTrashURL == nil, record.restoredURL == nil, let location = record.locationURL,
              location.path != record.originalURL.path else { return false }
        if let isolation = record.isolationURL, location.deletingLastPathComponent().path == isolation.path { return false }
        return true
    }

    /// Startup only verifies evidence. Incomplete deletion is never resumed;
    /// absence alone is never reported as successful deletion.
    public static func reconcile(_ original: SpaceCleaningRecord, isCancelled: () -> Bool = { false }) -> SpaceCleaningRecord {
        guard !isCancelled(), (try? original.validated()) != nil else { return original }
        var record = original
        switch record.state {
        case .trashed:
            // Metadata only: the same object, length and modification time keep
            // the entry. Restore and purge re-verify the complete content first.
            guard let location = record.locationURL, let proof = record.proof else { return original }
            switch SpaceCleaningFilesystem.presence(location) {
            case .present(let actual) where proof.rootIdentity.matchesMovedResource(actual) && proof.rootIdentity.mode == actual.mode:
                guard record.explanation == unavailableTrashExplanation else { return original }
                record.explanation = trashedExplanation
            case .unavailable:
                // Missing permission or an unmounted volume is not evidence that
                // the item changed; keep the entry and check again next time.
                guard record.explanation != unavailableTrashExplanation else { return original }
                record.explanation = unavailableTrashExplanation
            case .absent:
                record.state = .needsReview
                record.explanation = "废纸篓中已找不到该项目，可能已清空废纸篓或被移走；已停用自动恢复和永久删除。"
            case .present:
                record.state = .needsReview
                record.explanation = "废纸篓中的项目已变化，已停用自动恢复和永久删除。"
            }
        case .needsReview:
            // Re-check a record that an earlier failure moved to review. Only a
            // complete content match at the recorded Trash location restores it.
            guard canReverify(record), let location = record.locationURL, let proof = record.proof,
                  case .present(let actual) = SpaceCleaningFilesystem.presence(location),
                  proof.rootIdentity.matchesMovedResource(actual), proof.rootIdentity.mode == actual.mode,
                  (try? verifiedSnapshot(record, at: location, isCancelled: isCancelled)) != nil else { return original }
            record.state = .trashed
            record.explanation = "已重新完整核验，项目仍在废纸篓的记录位置，恢复与永久删除入口已恢复。"
        case .restoring:
            if let destination = record.restoredURL, let source = record.locationURL,
               SpaceCleaningFilesystem.validateAncestors(record.candidate),
               (try? verifiedSnapshot(record, at: destination, isCancelled: isCancelled)) != nil, SpaceCleaningFilesystem.absent(source) {
                record.state = .restored; record.explanation = "已核验中断前的恢复完成，未重复移动。"
            } else if let source = record.locationURL, (try? verifiedSnapshot(record, at: source, isCancelled: isCancelled)) != nil {
                record.state = .trashed; record.restoredURL = nil; record.explanation = "项目仍在已记录的废纸篓位置，未重复恢复。"
            } else { record.state = .needsReview; record.explanation = "恢复中断后的身份或位置无法确认，请在 Finder 中核对。" }
        case .prepared:
            if let previous = record.previousTrashURL {
                if let target = record.locationURL, SpaceCleaningFilesystem.absent(target),
                   (try? verifiedSnapshot(record, at: previous, isCancelled: isCancelled)) != nil {
                    record.locationURL = previous; record.isolationURL = nil; record.state = .trashed
                    record.explanation = "永久删除在隔离移动前中断；已核验完整项目仍在原废纸篓位置，恢复入口保留。未继续删除。"
                } else if let target = record.locationURL, SpaceCleaningFilesystem.absent(previous),
                          (try? verifiedSnapshot(record, at: target, isCancelled: isCancelled)) != nil {
                    record.state = .needsReview
                    record.explanation = "永久删除在隔离移动后中断；完整项目位于记录的隔离位置，原废纸篓位置也已保留。未继续删除，请在 Finder 中核对。"
                } else {
                    record.state = .needsReview
                    record.explanation = "永久删除中断，原废纸篓位置与隔离位置已保留，但当前身份或内容无法确认。未继续删除，请在 Finder 中核对。"
                }
            } else if SpaceCleaningFilesystem.validateAncestors(record.candidate), SpaceCleaningFilesystem.capture(record.originalURL) == record.candidate.identity,
               record.locationURL.map(SpaceCleaningFilesystem.absent) ?? true {
                record.state = .skipped; record.explanation = "上次操作尚未移动项目，原文件仍在原位；未重新执行。"
            } else { record.state = .needsReview; record.explanation = "上次操作中断，请核对原位置和记录的隔离位置；未重复移动或删除。" }
        case .isolated, .deleting:
            record.state = .needsReview
            record.explanation = record.candidate.simulator != nil
                ? "模拟器删除中断，未推定成功；请在 Xcode 的「设备与模拟器」窗口中核对。"
                : "操作中断，记录位置可能保留完整或部分项目。未推定成功，未自动继续删除；请在 Finder 中核对。"
        case .deleted, .restored, .skipped, .cancelled, .failed: return record
        }
        if isCancelled() { return original }
        record.updatedAt = Date(); return record
    }
    private static let trashedExplanation = "已移到废纸篓，完整项目身份和内容核验一致。"
    private static let wholeFolderTrashedExplanation = "已移到废纸篓，整个文件夹的身份、文件数量、大小与修改时间核验一致。"
    private static let unavailableTrashExplanation = "暂时无法核对废纸篓中的项目，恢复入口保留；恢复或永久删除前会重新完整核验。"
    private static func verifiedSnapshot(_ record: SpaceCleaningRecord, at url: URL, isCancelled: () -> Bool,
                                         lease: SpaceCleaningFilesystem.ObjectLease? = nil) throws -> SpaceCleaningFilesystem.Snapshot {
        guard let proof = record.proof, proof.isValid else { throw SpaceCleaningFilesystem.Failure(message: "缺少原始完整内容依据，未自动处理。") }
        let actual = try proof.metadataOnly == true
            ? SpaceCleaningFilesystem.metadataSnapshot(url, expected: proof.rootIdentity, allowRename: true, isCancelled: isCancelled, lease: lease)
            : SpaceCleaningFilesystem.snapshot(url, expected: proof.rootIdentity, allowRename: true, isCancelled: isCancelled, lease: lease)
        guard proof.matches(actual.proof) else { throw SpaceCleaningFilesystem.Failure(message: "项目身份或完整内容与清理记录不一致。") }
        return actual
    }
    private static func erase(_ original: SpaceCleaningRecord, snapshot: SpaceCleaningFilesystem.Snapshot,
                              isCancelled: () -> Bool, validateActivity: () -> String?,
                              persist: (SpaceCleaningRecord) throws -> Void) -> SpaceCleaningRecord {
        var record = original
        guard let location = record.locationURL else { return finish(record, .needsReview, "隔离位置缺失，未删除项目。", persist) }
        guard !isCancelled() else { return finish(record, .needsReview, "已停止永久删除，完整项目仍保留在记录的隔离位置。", persist) }
        do {
            record.state = .deleting; record.updatedAt = Date(); record.explanation = "已记录不可恢复的删除意图，正在逐项核验并删除。"
            try persist(record)
            if let reason = validateActivity() {
                return finish(record, .needsReview, reason + " 尚未永久删除；完整项目保留在记录的隔离位置。", persist)
            }
            if let objects = snapshot.verifiedObjects {
                try SpaceCleaningFilesystem.removeVerifiedObjects(location, objects: objects, device: snapshot.proof.rootIdentity.device, isCancelled: isCancelled)
            } else {
                try SpaceCleaningFilesystem.removeVerified(location, snapshot: snapshot, isCancelled: isCancelled)
            }
            guard SpaceCleaningFilesystem.absent(location) else { throw SpaceCleaningFilesystem.Failure(message: "项目仍存在，未确认删除完成。") }
            record.state = .deleted; record.updatedAt = Date(); record.explanation = "所选完整项目已永久删除，不提供恢复。"
            try persist(record)
            if let isolation = record.isolationURL { SpaceCleaningFilesystem.removeEmptyIsolation(isolation) }
            return record
        } catch {
            return finish(record, .needsReview, "永久删除未完整确认，部分内容可能已删除。保留记录，未记为清理成功：" + error.localizedDescription, persist)
        }
    }
    private static func rollback(_ original: SpaceCleaningRecord, explanation: String,
                                 persist: (SpaceCleaningRecord) throws -> Void) -> SpaceCleaningRecord {
        var record = original
        guard let location = record.locationURL, let actual = SpaceCleaningFilesystem.capture(location),
              record.proof?.rootIdentity.matchesMovedResource(actual) == true,
              SpaceCleaningFilesystem.validateAncestors(record.candidate), SpaceCleaningFilesystem.absent(record.originalURL) else {
            return finish(record, .needsReview, explanation + " 未自动覆盖或恢复项目，请在 Finder 中核对记录位置。", persist)
        }
        do {
            // Even if its content changed during the attempted move, the same
            // selected resource may be returned to a still-vacant original slot.
            try SpaceCleaningFilesystem.move(location, to: record.originalURL, expected: actual)
            guard SpaceCleaningFilesystem.capture(record.originalURL).map(actual.matchesMovedResource) == true,
                  SpaceCleaningFilesystem.absent(location) else { throw SpaceCleaningFilesystem.Failure(message: "回退后身份核验未通过。") }
            record.locationURL = nil
            if let isolation = record.isolationURL { SpaceCleaningFilesystem.removeEmptyIsolation(isolation) }
            return finish(record, .failed, explanation + " 已安全回退原位置，未记为清理成功；请重新扫描。", persist)
        } catch {
            return finish(record, .needsReview, explanation + " 回退未确认完成，未覆盖其他项目：" + error.localizedDescription, persist)
        }
    }
    private static func availableRestoreURL(_ original: URL) throws -> URL {
        let parent = original.deletingLastPathComponent(), ext = original.pathExtension
        let stem = ext.isEmpty ? original.lastPathComponent : original.deletingPathExtension().lastPathComponent
        for number in 1...1000 {
            let name = stem + "（已恢复" + (number == 1 ? "" : " \(number)") + "）" + (ext.isEmpty ? "" : "." + ext)
            let proposed = parent.appendingPathComponent(name)
            if SpaceCleaningFilesystem.absent(proposed) { return proposed }
        }
        throw SpaceCleaningFilesystem.Failure(message: "无法找到空闲的恢复名称，未覆盖现有项目。")
    }
    private static func finish(_ original: SpaceCleaningRecord, _ state: SpaceCleaningRecordState, _ explanation: String,
                               _ persist: (SpaceCleaningRecord) throws -> Void) -> SpaceCleaningRecord {
        var record = original; record.state = state; record.updatedAt = Date(); record.explanation = explanation
        do { try persist(record) }
        catch {
            record.state = .needsReview
            record.explanation += " 清理记录未能保存，自动处理已停止：" + error.localizedDescription
        }
        return record
    }
}
