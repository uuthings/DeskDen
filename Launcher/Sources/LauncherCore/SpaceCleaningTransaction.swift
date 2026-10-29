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
}
public struct SpaceCleaningTreeProof: Codable, Equatable, Sendable {
    public var sha256: String
    public var entryCount: Int
    public var logicalBytes: UInt64
    public var rootIdentity: SpaceCleaningFileIdentity
    public var isValid: Bool {
        sha256.utf8.count == 64 && sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && (1...100_000).contains(entryCount)
    }
    public func matches(_ other: Self) -> Bool {
        sha256 == other.sha256 && entryCount == other.entryCount && logicalBytes == other.logicalBytes &&
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
        if let reason = validatePolicy(candidate) { return finish(record, .skipped, reason, persist) }
        if let reason = validateActivity(candidate, candidate.url) { return finish(record, .skipped, reason, persist) }
        do {
            let selected = try SpaceCleaningFilesystem.snapshot(candidate.url, expected: candidate.identity, allowRename: false, isCancelled: isCancelled)
            if let reason = SpaceCleaningDevelopmentPolicy.reason(in: selected) { return finish(record, .skipped, reason, persist) }
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
            let isolated = try verifiedSnapshot(record, at: record.locationURL!, isCancelled: isCancelled, lease: selected.lease)
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
            record.state = .trashed; record.explanation = "已移到废纸篓，完整项目身份和内容核验一致。"
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
        guard SpaceCleaningFilesystem.validateAncestors(record.candidate) else {
            return finish(record, .needsReview, "原父目录已变化或不可访问，未自动恢复；请在 Finder 中核对。", persist)
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
            if let reason = SpaceCleaningDevelopmentPolicy.reason(in: current) {
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
            return finish(record, .needsReview, "永久删除尚未确认完成，请核对记录位置；未重复删除：" + error.localizedDescription, persist)
        }
    }

    /// Startup only verifies evidence. Incomplete deletion is never resumed;
    /// absence alone is never reported as successful deletion.
    public static func reconcile(_ original: SpaceCleaningRecord, isCancelled: () -> Bool = { false }) -> SpaceCleaningRecord {
        guard !isCancelled(), (try? original.validated()) != nil else { return original }
        var record = original
        switch record.state {
        case .trashed:
            if let location = record.locationURL, (try? verifiedSnapshot(record, at: location, isCancelled: isCancelled)) != nil { return record }
            if isCancelled() { return original }
            record.state = .needsReview; record.explanation = "废纸篓项目已变化、被移走或无法读取，已停用自动恢复和永久删除。"
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
            record.state = .needsReview; record.explanation = "操作中断，记录位置可能保留完整或部分项目。未推定成功，未自动继续删除；请在 Finder 中核对。"
        case .deleted, .restored, .skipped, .cancelled, .failed, .needsReview: return record
        }
        if isCancelled() { return original }
        record.updatedAt = Date(); return record
    }
    private static func verifiedSnapshot(_ record: SpaceCleaningRecord, at url: URL, isCancelled: () -> Bool,
                                         lease: SpaceCleaningFilesystem.ObjectLease? = nil) throws -> SpaceCleaningFilesystem.Snapshot {
        guard let proof = record.proof, proof.isValid else { throw SpaceCleaningFilesystem.Failure(message: "缺少原始完整内容依据，未自动处理。") }
        let actual = try SpaceCleaningFilesystem.snapshot(url, expected: proof.rootIdentity, allowRename: true, isCancelled: isCancelled, lease: lease)
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
            try SpaceCleaningFilesystem.removeVerified(location, snapshot: snapshot, isCancelled: isCancelled)
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
            record.explanation += " 处理记录未能保存，自动处理已停止：" + error.localizedDescription
        }
        return record
    }
}

/// One append/update journal for intentions AND outcomes: no success receipt can
/// be lost between separate stores. Invalid/unreadable journals block mutation.
public final class SpaceCleaningHistoryStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var values: [UUID: SpaceCleaningRecord] = [:]
    private var fileIdentity: SpaceCleaningFileIdentity?
    public init(fileURL: URL) throws {
        guard fileURL.isFileURL else { throw SpaceCleaningFilesystem.Failure(message: "清理记录位置无效。") }
        self.fileURL = fileURL
        if !SpaceCleaningFilesystem.absent(fileURL) {
            let descriptor = fileURL.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK) } ?? -1 }
            guard descriptor >= 0 else { throw SpaceCleaningFilesystem.Failure(message: "清理记录无法读取，暂停文件处理。") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), info.st_size <= 33_554_432 else {
                throw SpaceCleaningFilesystem.Failure(message: "清理记录不是有效的私有文件。")
            }
            let data = try handle.read(upToCount: 33_554_433) ?? Data()
            guard data.count <= 33_554_432 else { throw SpaceCleaningFilesystem.Failure(message: "清理记录超过安全容量。") }
            let records = try JSONDecoder().decode([SpaceCleaningRecord].self, from: data)
            guard records.count <= 10_000, Set(records.map(\.id)).count == records.count else { throw SpaceCleaningFilesystem.Failure(message: "清理记录重复或超过容量。") }
            for record in records { values[record.id] = try record.validated() }
            fileIdentity = SpaceCleaningFilesystem.identity(info)
            guard SpaceCleaningFilesystem.capture(fileURL) == fileIdentity else { throw SpaceCleaningFilesystem.Failure(message: "读取期间清理记录已变化。") }
        }
    }
    public var records: [SpaceCleaningRecord] {
        lock.lock(); defer { lock.unlock() }; return values.values.sorted { $0.createdAt > $1.createdAt }
    }
    public func record(_ value: SpaceCleaningRecord) throws {
        lock.lock(); defer { lock.unlock() }
        let checked = try value.validated(); var next = values; next[checked.id] = checked
        guard next.count <= 10_000 else { throw SpaceCleaningFilesystem.Failure(message: "清理历史已达上限，保留恢复记录并停止新处理。") }
        let data = try JSONEncoder().encode(next.values.sorted { $0.createdAt < $1.createdAt })
        guard data.count <= 33_554_432 else { throw SpaceCleaningFilesystem.Failure(message: "清理历史已达容量上限，停止新处理。") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = try SpaceCleaningFilesystem.Directory(fileURL.deletingLastPathComponent())
        guard parent.stillAtPath(), parent.entry(fileURL.lastPathComponent) == fileIdentity else { throw SpaceCleaningFilesystem.Failure(message: "清理记录被外部修改，原记录已保留。") }
        let temporary = ".space-cleaning-journal-" + UUID().uuidString
        let descriptor = temporary.withCString { openat(parent.descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw SpaceCleaningFilesystem.Failure(message: "无法写入处理意图，未操作文件。") }
        defer { close(descriptor); _ = temporary.withCString { unlinkat(parent.descriptor, $0, 0) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw SpaceCleaningFilesystem.Failure(message: "处理意图未完整写入。") }
                guard count > 0 else { throw SpaceCleaningFilesystem.Failure(message: "处理意图写入中断。") }; offset += count
            }
        }
        guard fsync(descriptor) == 0, parent.stillAtPath(), parent.entry(fileURL.lastPathComponent) == fileIdentity else {
            throw SpaceCleaningFilesystem.Failure(message: "处理记录未安全落盘或被外部修改。")
        }
        let result = temporary.withCString { from in fileURL.lastPathComponent.withCString { to in
            fileIdentity == nil ? renameatx_np(parent.descriptor, from, parent.descriptor, to, UInt32(RENAME_EXCL)) : renameat(parent.descriptor, from, parent.descriptor, to)
        } }
        guard result == 0 else { throw SpaceCleaningFilesystem.Failure(message: "处理记录无法原子保存。") }
        fileIdentity = parent.entry(fileURL.lastPathComponent)
        guard fileIdentity != nil, parent.stillAtPath() else { throw SpaceCleaningFilesystem.Failure(message: "保存后的处理记录无法核验。") }
        values = next
    }
}
