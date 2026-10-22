import Foundation

public enum StorageReviewRestoreState: String, Equatable, Sendable { case restored, notMoved, rolledBack, needsReview }
public struct StorageReviewRestoreOutcome: Equatable, Sendable {
    public var state: StorageReviewRestoreState
    public var explanation: String
}
public enum StorageReviewRestoreTransaction {
    /// The persisted marker lets a restart reconcile a move-back without repeating it.
    public static func execute(candidate: StorageReviewCandidate, scope: StorageReviewScopeRecord, trashURL: URL,
                               verifiedIdentity: StorageReviewFileIdentity, mover: any StorageReviewFileMoving,
                               contentProof:StorageReviewContentProof?=nil,isCancelled:()->Bool={false},
                               persistIntent: () throws -> Void) -> StorageReviewRestoreOutcome {
        guard !isCancelled() else {return .init(state:.notMoved,explanation:"恢复已取消，未移动文件。")}
        guard candidate.identity.matchesMovedResource(verifiedIdentity),contentProof?.isValid ?? true,
              contentProof == nil || candidate.identity.matchesContentResource(verifiedIdentity),
              StorageReviewIdentityValidator.validate(candidate, scope: scope) == .missing else {
            return .init(state: .notMoved, explanation: "原位置或废纸篓文件已经变化，未自动恢复或覆盖文件。")
        }
        let content:StorageReviewContentLease?
        if let contentProof {
            do {
                let lease=try StorageReviewIdentityValidator.openContent(at:trashURL,expected:verifiedIdentity,allowChangedTime:true)
                guard try lease.contentProof(isCancelled:isCancelled) == contentProof,lease.matchesPath(trashURL) else {throw StorageReviewContentError.changed}
                content=lease
            } catch {
                return .init(state:.notMoved,explanation:isCancelled() ? "恢复已取消，未移动文件。":"无法读取或核验废纸篓文件的原始内容与身份，未自动恢复。macOS 访问保护也可能限制读取，请在 Finder 中核对并移回原目录。")
            }
        } else {
            // Legacy records have no prior content evidence. Never manufacture a
            // proof from the current Trash file or rebase their stored ctime.
            guard StorageReviewIdentityValidator.captureRegularFileIdentity(at:trashURL) == verifiedIdentity else {
                return .init(state:.notMoved,explanation:"旧记录缺少原始内容摘要，废纸篓文件元数据已变化，未自动恢复。请在 Finder 中核对并移回原目录。")
            }
            content=nil
        }
        do { try persistIntent() } catch { return .init(state: .notMoved, explanation: "恢复意图未能写入，未移动文件：\(error.localizedDescription)") }
        guard !isCancelled() else {return .init(state:.notMoved,explanation:"恢复已取消，未移动文件。")}
        let stillMatches:Bool
        if let content,let contentProof {stillMatches=(try? content.contentProof(isCancelled:isCancelled)) == contentProof && content.matchesPath(trashURL)}
        else {stillMatches=StorageReviewIdentityValidator.captureRegularFileIdentity(at:trashURL) == verifiedIdentity}
        guard !isCancelled(),stillMatches,
              StorageReviewIdentityValidator.validate(candidate, scope: scope) == .missing else {
            return .init(state: .notMoved, explanation: "写入恢复意图后文件发生变化，未移动文件。")
        }
        let original = scope.canonicalDirectory.appendingPathComponent(candidate.relativePath)
        do {
            try mover.moveBack(trashURL, to: original)
            if let actual = StorageReviewIdentityValidator.captureRegularFileIdentity(at: original),
               verifiedIdentity.matchesMovedResource(actual),
               contentProof == nil || ((try? content?.contentProof()) == contentProof && content?.matchesPath(original) == true),
               StorageReviewIdentityValidator.captureRegularFileIdentity(at: trashURL) == nil {
                return .init(state: .restored, explanation: contentProof == nil ? "文件已恢复到原位置，资源身份、大小与修改时间核验一致。":"文件已恢复到原位置，资源身份与原始内容摘要核验一致。")
            }
            // A different item raced into the trash source. Return that actual item only if
            // both positions remain unchanged and the trash slot is still vacant.
            let location = StorageReviewIdentityValidator.validate(candidate, scope: scope)
            guard location == .changed || location == .unchanged,
                  let moved = StorageReviewIdentityValidator.captureRegularFileIdentity(at: original),
                  StorageReviewIdentityValidator.captureRegularFileIdentity(at: trashURL) == nil,
                  StorageReviewIdentityValidator.captureRegularFileIdentity(at: original) == moved else {
                return .init(state: .needsReview, explanation: "恢复后的资源不一致且位置已变化，未记成功、未覆盖其他文件。请在 Finder 中核对。")
            }
            try mover.moveBack(original, to: trashURL)
            guard let returned = StorageReviewIdentityValidator.captureRegularFileIdentity(at: trashURL),
                  moved.matchesMovedResource(returned), StorageReviewIdentityValidator.captureRegularFileIdentity(at: original) == nil else {
                return .init(state: .needsReview, explanation: "恢复竞态后的回退无法核验，请在 Finder 中核对；未标记恢复成功。")
            }
            return .init(state: .rolledBack, explanation: "恢复期间文件被替换，已将本次实际移动的文件回退废纸篓，未误记为已恢复。")
        } catch {
            let state = reconcile(candidate: candidate, scope: scope, trashURL: trashURL, verifiedIdentity: verifiedIdentity,contentProof:contentProof)
            if state.state == .restored { return state }
            return .init(state: state.state == .notMoved ? .notMoved : .needsReview,
                         explanation: "恢复未确认完成：\(error.localizedDescription)。" + state.explanation + (state.explanation.contains("Finder") ? "":"请在 Finder 中核对并移回原目录。"))
        }
    }
    public static func reconcile(candidate: StorageReviewCandidate, scope: StorageReviewScopeRecord, trashURL: URL,
                                 verifiedIdentity: StorageReviewFileIdentity,contentProof:StorageReviewContentProof?=nil,isCancelled:()->Bool={false}) -> StorageReviewRestoreOutcome {
        guard !isCancelled(),candidate.identity.matchesMovedResource(verifiedIdentity),contentProof?.isValid ?? true,
              contentProof == nil || candidate.identity.matchesContentResource(verifiedIdentity) else { return .init(state: .needsReview, explanation: "恢复依据无法核验或核验已取消，未自动处理。") }
        let original = scope.canonicalDirectory.appendingPathComponent(candidate.relativePath)
        let location = StorageReviewIdentityValidator.validate(candidate, scope: scope)
        if location == .changed || location == .unchanged,
           let actual = StorageReviewIdentityValidator.captureRegularFileIdentity(at: original),
           verifiedIdentity.matchesMovedResource(actual),
           contentProof.map({StorageReviewIdentityValidator.contentMatches(at:original,expected:verifiedIdentity,proof:$0,isCancelled:isCancelled)}) ?? (actual == verifiedIdentity),
           StorageReviewIdentityValidator.captureRegularFileIdentity(at: trashURL) == nil {
            return .init(state: .restored, explanation: "已根据中断恢复记录核验：所选文件位于原位置。")
        }
        if location == .missing, let actual = StorageReviewIdentityValidator.captureRegularFileIdentity(at: trashURL),
           verifiedIdentity.matchesMovedResource(actual),
           contentProof.map({StorageReviewIdentityValidator.contentMatches(at:trashURL,expected:verifiedIdentity,proof:$0,isCancelled:isCancelled)}) ?? (actual == verifiedIdentity) {
            return .init(state: .notMoved, explanation: "文件仍在已记录的废纸篓位置，未重复恢复。")
        }
        return .init(state: .needsReview, explanation: "恢复中断后位置或资源发生变化，未自动移动或覆盖文件。请在 Finder 中核对。")
    }
}
