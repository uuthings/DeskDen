import Foundation

/// File identity across a rename. A rename may legitimately alter ctime and allocation metadata.
/// Resource identity, content length and modification time must remain identical.
public extension StorageReviewFileIdentity {
    func matchesMovedResource(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && sizeBytes == other.sizeBytes &&
        modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds &&
        (mode & 0o170000) == (other.mode & 0o170000) && linkCount == other.linkCount
    }
    /// Content proof may excuse rename/Trash ctime and allocation changes, but
    /// must not excuse permission changes or an added hard link.
    func matchesContentResource(_ other:Self)->Bool {matchesMovedResource(other) && mode == other.mode && linkCount == 1}
}

public protocol StorageReviewFileMoving: Sendable {
    /// Return the actual OS destination. A throw must not be used to assert that nothing moved.
    func moveToTrash(_ source: URL) throws -> URL
    /// Must fail if the destination exists. No overwrite, permanent delete or force option.
    func moveBack(_ source: URL, to destination: URL) throws
}
public enum StorageReviewMoveStage: String, Codable, Sendable { case prepared, moved, verified, rolledBack, needsReview, failed, cancelled }
public struct StorageReviewMoveIntent: Identifiable, Codable, Equatable, Sendable {
    public var schema = 1
    public var id: UUID
    public var operationID: UUID
    public var candidate: StorageReviewCandidate
    public var scope: StorageReviewScopeRecord
    public var updatedAt: Date
    public var stage: StorageReviewMoveStage
    public var resultingURL: URL?
    public var resultingIdentity: StorageReviewFileIdentity?
    public var contentProof: StorageReviewContentProof?
    public var explanation: String
    public init(id: UUID = UUID(), operationID: UUID, candidate: StorageReviewCandidate, scope: StorageReviewScopeRecord, at date: Date = Date()) {
        self.id = id; self.operationID = operationID; self.candidate = candidate; self.scope = scope
        updatedAt = date; stage = .prepared; resultingURL = nil; resultingIdentity = nil; contentProof=nil; explanation = "已记录处理意图，尚未确认文件移动。"
    }
    public var originalURL: URL { scope.canonicalDirectory.appendingPathComponent(candidate.relativePath) }
    public func validated() throws -> Self {
        guard schema == 1, candidate.scopeID == scope.scope.id, scope.canonicalDirectory.isFileURL,
              !candidate.relativePath.isEmpty, candidate.relativePath.count <= 4096, !candidate.relativePath.hasPrefix("/"),
              !candidate.relativePath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              resultingURL?.isFileURL ?? true, updatedAt.timeIntervalSince1970.isFinite,
              abs(updatedAt.timeIntervalSince1970) < 100_000_000_000,
              contentProof?.isValid ?? true,
              stage != .verified || (resultingURL != nil && resultingIdentity.map(candidate.identity.matchesMovedResource) == true &&
                  (contentProof == nil || resultingIdentity.map(candidate.identity.matchesContentResource) == true)) else {
            throw StorageReviewIntentError.invalidJournal
        }
        return self
    }
}
public enum StorageReviewMoveState: String, Codable, Equatable, Sendable { case trashed, skipped, cancelled, failed, rolledBack, needsReview }
public struct StorageReviewMoveOutcome: Sendable, Equatable {
    public var intent: StorageReviewMoveIntent
    public var state: StorageReviewMoveState
    public var explanation: String
    /// Only a verified move of the selected resource may offer automatic restoration.
    public var automaticRestoreIdentity: StorageReviewFileIdentity? {
        guard state == .trashed, let actual = intent.resultingIdentity,
              intent.candidate.identity.matchesMovedResource(actual),
              intent.contentProof == nil || intent.candidate.identity.matchesContentResource(actual) else { return nil }
        return actual
    }
}
public enum StorageReviewIntentError: LocalizedError {
    case invalidJournal
    public var errorDescription: String? { "文件处理意图记录无效或超过容量，原记录已保留。" }
}

/// A durable intention is committed before the OS move. A result is verified after it.
/// The caller retains the intent until its separate final receipt has been saved.
public enum StorageReviewMoveTransaction {
    public static func execute(candidate: StorageReviewCandidate, scope: StorageReviewScopeRecord, operationID: UUID,
                               mover: any StorageReviewFileMoving, isCancelled: () -> Bool = { false },
                               persist: (StorageReviewMoveIntent) throws -> Void) -> StorageReviewMoveOutcome {
        var intent = StorageReviewMoveIntent(operationID: operationID, candidate: candidate, scope: scope)
        guard !isCancelled() else { intent.stage = .cancelled; return .init(intent: intent, state: .cancelled, explanation: "已取消，未移动文件。") }
        guard candidate.disposition == .requiresReview, StorageReviewIdentityValidator.validate(candidate, scope: scope) == .unchanged else {
            intent.stage = .failed; return .init(intent: intent, state: .skipped, explanation: "文件身份或范围已变化，未移动文件。")
        }
        let selectedContent:StorageReviewContentLease
        do {
            selectedContent=try StorageReviewIdentityValidator.openContent(at:intent.originalURL,expected:candidate.identity)
            intent.contentProof=try selectedContent.contentProof(isCancelled:isCancelled)
            guard selectedContent.matchesPath(intent.originalURL) else {throw StorageReviewContentError.changed}
        } catch {
            let cancelled=isCancelled();intent.stage=cancelled ? .cancelled:.failed
            return .init(intent:intent,state:cancelled ? .cancelled:.skipped,
                         explanation:cancelled ? "已取消内容核验，未移动文件。":"无法安全读取并核验所选文件，未移动文件。")
        }
        do { try persist(intent) } catch {
            intent.stage = .failed
            return .init(intent: intent, state: .failed, explanation: "处理意图未能写入，未移动文件：\(error.localizedDescription)")
        }
        guard !isCancelled() else {
            intent.stage = .cancelled; intent.explanation = "已取消，未移动文件。"; try? persist(intent)
            return .init(intent: intent, state: .cancelled, explanation: intent.explanation)
        }
        guard StorageReviewIdentityValidator.validate(candidate, scope: scope) == .unchanged else {
            intent.stage = .failed; intent.explanation = "写入意图后文件身份或范围变化，已跳过。"; try? persist(intent)
            return .init(intent: intent, state: .skipped, explanation: intent.explanation)
        }
        do {
            let destination = try mover.moveToTrash(intent.originalURL)
            guard destination.isFileURL else { throw StorageReviewIntentError.invalidJournal }
            intent.resultingURL = destination
            intent.resultingIdentity = StorageReviewIdentityValidator.captureRegularFileIdentity(at: destination)
            intent.stage = .moved; intent.updatedAt = Date(); intent.explanation = "系统返回移动结果，正在核验所选资源。"
            do { try persist(intent) } catch { return rollback(intent, mover: mover, reason: "移动结果未能持久化", persist: persist) }
            guard let actual = intent.resultingIdentity,candidate.identity.matchesContentResource(actual),
                  selectedContent.matchesPath(destination),
                  (try? selectedContent.contentProof()) == intent.contentProof,
                  selectedContent.matchesPath(destination) else {
                return rollback(intent, mover: mover, reason: "预检与移动之间文件被替换或内容变化", persist: persist)
            }
            intent.resultingIdentity=selectedContent.currentIdentity()
            intent.stage = .verified; intent.updatedAt = Date(); intent.explanation = "已移到废纸篓，所选文件的资源身份与内容摘要核验一致。"
            do { try persist(intent) } catch { return rollback(intent, mover: mover, reason: "核验结果未能持久化", persist: persist) }
            return .init(intent: intent, state: .trashed, explanation: intent.explanation)
        } catch {
            // Some filesystem APIs can fail after a partial operation. Preserve the prepared intent
            // rather than treating a missing original as proof of either success or safe failure.
            let source = StorageReviewIdentityValidator.validate(candidate, scope: scope)
            intent.stage = source == .unchanged ? .failed : .needsReview; intent.updatedAt = Date()
            intent.explanation = "系统移动未确认完成：\(error.localizedDescription)" + (source == .unchanged ? "；原文件仍可核验。" : "；原位置已变化，请在 Finder 与废纸篓中核对。")
            try? persist(intent)
            return .init(intent: intent, state: source == .unchanged ? .failed : .needsReview, explanation: intent.explanation)
        }
    }
    private static func rollback(_ original: StorageReviewMoveIntent, mover: any StorageReviewFileMoving, reason: String,
                                 persist: (StorageReviewMoveIntent) throws -> Void) -> StorageReviewMoveOutcome {
        var intent = original
        guard let destination = intent.resultingURL, let movedIdentity = intent.resultingIdentity,
              StorageReviewIdentityValidator.captureRegularFileIdentity(at: destination) == movedIdentity,
              StorageReviewIdentityValidator.validate(intent.candidate, scope: intent.scope) == .missing else {
            intent.stage = .needsReview; intent.updatedAt = Date()
            intent.explanation = reason + "；原位置或移动结果已变化，未覆盖或自动恢复任何文件。请在 Finder 中核对。"
            try? persist(intent)
            return .init(intent: intent, state: .needsReview, explanation: intent.explanation)
        }
        do {
            try mover.moveBack(destination, to: intent.originalURL)
            guard let returned = StorageReviewIdentityValidator.captureRegularFileIdentity(at: intent.originalURL),
                  movedIdentity.matchesMovedResource(returned),
                  StorageReviewIdentityValidator.captureRegularFileIdentity(at: destination) == nil else { throw StorageReviewIntentError.invalidJournal }
            intent.stage = .rolledBack; intent.updatedAt = Date(); intent.resultingIdentity = returned
            intent.explanation = reason + "；已将本次实际移动的文件安全回退原位置，本项未记为处理成功。"
            try? persist(intent)
            return .init(intent: intent, state: .rolledBack, explanation: intent.explanation)
        } catch {
            intent.stage = .needsReview; intent.updatedAt = Date(); intent.explanation = reason + "；回退未完成，未覆盖现有文件：\(error.localizedDescription)"
            try? persist(intent)
            return .init(intent: intent, state: .needsReview, explanation: intent.explanation)
        }
    }
    /// A restart never repeats a move. It only reconciles recorded evidence with current files.
    public static func reconcile(_ original: StorageReviewMoveIntent,isCancelled:()->Bool={false}) -> StorageReviewMoveOutcome {
        guard !isCancelled(),(try? original.validated()) != nil else { return .init(intent: original, state: .needsReview, explanation: "中断记录无法核验或核验已取消，未自动操作文件。") }
        var intent = original
        if (intent.stage == .moved || intent.stage == .verified), let destination = intent.resultingURL,
           let actual = StorageReviewIdentityValidator.captureRegularFileIdentity(at: destination),
           intent.candidate.identity.matchesMovedResource(actual),let expected=intent.resultingIdentity,
           intent.contentProof.map({StorageReviewIdentityValidator.contentMatches(at:destination,expected:expected,proof:$0,isCancelled:isCancelled)}) ?? (expected == actual) {
            intent.stage = .verified; intent.resultingIdentity = actual
            return .init(intent: intent, state: .trashed, explanation: "已根据中断记录核验：所选资源位于已记录的废纸篓位置。")
        }
        if intent.stage == .prepared || intent.stage == .cancelled || intent.stage == .failed {
            if StorageReviewIdentityValidator.validate(intent.candidate, scope: intent.scope) == .unchanged {
                return .init(intent: intent, state: .skipped, explanation: "上次处理未确认完成；原文件仍在原位，未重新执行。")
            }
        }
        if intent.stage == .rolledBack, let expected = intent.resultingIdentity,
           let actual = StorageReviewIdentityValidator.captureRegularFileIdentity(at: intent.originalURL), expected.matchesMovedResource(actual) {
            return .init(intent: intent, state: .rolledBack, explanation: intent.explanation)
        }
        intent.stage = .needsReview
        intent.explanation = "上次处理被中断或文件后来发生变化，未推定成功、未重复移动或自动恢复。请在 Finder 与废纸篓中核对。"
        return .init(intent: intent, state: .needsReview, explanation: intent.explanation)
    }
}

/// Synchronous atomic writes are used from the operation's background worker, in transaction order.
public final class StorageReviewIntentStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var values: [UUID: StorageReviewMoveIntent] = [:]
    public init(fileURL: URL) throws {
        guard fileURL.isFileURL else { throw StorageReviewIntentError.invalidJournal }
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forReadingFrom: fileURL); defer { try? handle.close() }
            let data = try handle.read(upToCount: 16_777_217) ?? Data()
            guard data.count <= 16_777_216 else { throw StorageReviewIntentError.invalidJournal }
            let decoded = try JSONDecoder().decode([StorageReviewMoveIntent].self, from: data)
            guard decoded.count <= 10_000, Set(decoded.map(\.id)).count == decoded.count else { throw StorageReviewIntentError.invalidJournal }
            for item in decoded { values[item.id] = try item.validated() }
        }
    }
    public var pending: [StorageReviewMoveIntent] { lock.lock(); defer { lock.unlock() }; return values.values.sorted { $0.updatedAt < $1.updatedAt } }
    public func record(_ intent: StorageReviewMoveIntent) throws {
        lock.lock(); defer { lock.unlock() }; let checked = try intent.validated()
        var next = values; next[checked.id] = checked; try save(next); values = next
    }
    public func remove(_ id: UUID) throws { lock.lock(); defer { lock.unlock() }; var next = values; next.removeValue(forKey: id); try save(next); values = next }
    private func save(_ next: [UUID: StorageReviewMoveIntent]) throws {
        guard next.count <= 10_000 else { throw StorageReviewIntentError.invalidJournal }
        let data = try JSONEncoder().encode(next.values.sorted { $0.updatedAt < $1.updatedAt })
        guard data.count <= 16_777_216 else { throw StorageReviewIntentError.invalidJournal }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
    }
}
