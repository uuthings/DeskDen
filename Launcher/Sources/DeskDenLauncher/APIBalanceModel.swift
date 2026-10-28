import Combine
import Foundation
import LauncherCore

/// Balance connections have their own currency model and credential namespace.
/// They do not consume or infer local Token or physical-network measurements.
@MainActor final class APIBalanceModel: ObservableObject {
    @Published private(set) var sources: [APIBalanceConfiguration] = []
    @Published private(set) var states: [UUID: APIBalanceSourceState] = [:]
    @Published private(set) var refreshing = Set<UUID>()
    @Published var errorMessage: String?
    @Published private(set) var storageError: String?
    private let store: APIBalanceStore
    private let client: any APIBalanceQuerying
    private let credentials: any APIBalanceCredentialStoring
    private let now: @MainActor () -> Date
    private var document = APIBalanceDocument()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var saving = Set<UUID>()
    private var timer: Task<Void, Never>?
    private var preparingForQuit = false
    private var protectedStorage = false

    init(dataDirectory: URL, startServices: Bool = true, client: (any APIBalanceQuerying)? = nil,
         credentials: (any APIBalanceCredentialStoring)? = nil, now: @escaping @MainActor () -> Date = { Date() }) {
        store = APIBalanceStore(url: dataDirectory.appendingPathComponent("api-balances.json"))
        self.client = client ?? APIBalanceClient(); self.credentials = credentials ?? APIBalanceKeychain(); self.now = now
        do { document = try store.load(); publish() }
        catch { protectedStorage = true; storageError = "API 余额文件无法读取，原文件已保留；修复前暂停查询和保存。" }
        guard startServices, !protectedStorage else { return }
        // Launch does not read a plaintext draft or make a speculative API call.
        // Only previously configured credentials can be used for due refreshes.
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, !self.preparingForQuit, self.refreshing.isEmpty, self.saving.isEmpty else { continue }
                if let source = self.sources.first(where: { source in
                    let state = self.state(for: source.id)
                    return source.enabled && source.credentialID != nil && !state.authenticationFailed
                        && (state.nextRetryAt.map { self.now() >= $0 } ?? true)
                        && (state.lastAttempt.map { self.now().timeIntervalSince($0) >= 1800 } ?? true)
                }) { await self.refresh(id: source.id) }
            }
        }
    }
    deinit { timer?.cancel(); for task in tasks.values { task.cancel() } }
    func state(for id: UUID) -> APIBalanceSourceState { states[id] ?? .init() }

    @discardableResult func validateAndSave(name: String, key: String, editingID: UUID? = nil) async throws -> APIBalanceConfiguration {
        guard !protectedStorage, !preparingForQuit else { throw APIBalanceFailure.storage }
        let previous = editingID.flatMap { id in sources.first { $0.id == id } }
        guard editingID == nil || previous != nil else { throw APIBalanceFailure.invalidConfiguration }
        let id = previous?.id ?? UUID()
        guard !saving.contains(id) else { throw APIBalanceFailure.busy }
        guard previous != nil || sources.count < 100 else { throw APIBalanceFailure.invalidConfiguration }
        saving.insert(id); cancel(id); defer { saving.remove(id) }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = previous ?? APIBalanceConfiguration(id: id, name: cleanName, createdAt: now())
        candidate.name = cleanName
        try candidate.validate()
        let supplied = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var newCredential: UUID?
        do {
            var state = state(for: id)
            if !supplied.isEmpty {
                guard APIBalanceClient.validSecret(supplied) else { throw APIBalanceFailure.invalidConfiguration }
                if let retry = state.rateLimitUntil, retry > now() { throw APIBalanceFailure.rateLimited(retry.timeIntervalSince(now())) }
                let reading = try await client.fetch(configuration: candidate, secret: supplied)
                try validate(reading, id: id)
                guard !preparingForQuit else { throw APIBalanceFailure.cancelled }
                let credential = UUID(); try await credentials.write(supplied, id: credential); newCredential = credential
                candidate.credentialID = credential
                state = .init(snapshot: reading, lastAttempt: now())
            } else {
                guard let previous, previous.credentialID != nil else { throw APIBalanceFailure.invalidConfiguration }
                candidate.credentialID = previous.credentialID
            }
            var next = document
            if let index = next.sources.firstIndex(where: { $0.id == id }) { next.sources[index] = candidate }
            else { next.sources.append(candidate) }
            next.states[id] = state
            try persist(next)
            newCredential = nil; errorMessage = nil
            if let old = previous?.credentialID, old != candidate.credentialID { scheduleCredentialRemoval(old) }
            return candidate
        } catch {
            if let newCredential { try? await credentials.remove(id: newCredential) }
            throw failure(error)
        }
    }
    func refresh(id: UUID) async {
        guard !protectedStorage, !preparingForQuit, !refreshing.contains(id), !saving.contains(id),
              let source = sources.first(where: { $0.id == id }), source.credentialID != nil else { return }
        let previous = state(for: id)
        if let retry = previous.rateLimitUntil, retry > now() { errorMessage = APIBalanceFailure.rateLimited(retry.timeIntervalSince(now())).localizedDescription; return }
        let generation = UUID(); generations[id] = generation; refreshing.insert(id)
        let work = Task { [weak self] in
            guard let self else { return }
            defer { if self.generations[id] == generation { self.refreshing.remove(id); self.tasks[id] = nil } }
            do {
                guard let credentialID = source.credentialID, let secret = try await self.credentials.read(id: credentialID) else { throw APIBalanceFailure.authentication }
                let snapshot = try await self.client.fetch(configuration: source, secret: secret)
                try self.validate(snapshot, id: id)
                guard !Task.isCancelled, self.generations[id] == generation,
                      self.sources.contains(where: { $0 == source }) else { return }
                var next = self.document
                next.states[id] = .init(snapshot: snapshot, lastAttempt: self.now())
                try self.persist(next); self.errorMessage = nil
            } catch {
                guard !Task.isCancelled, self.generations[id] == generation else { return }
                let failure = self.failure(error)
                var next = self.document, state = self.state(for: id)
                state.lastAttempt = self.now(); state.message = failure.localizedDescription
                state.authenticationFailed = failure == .authentication
                if case .rateLimited(let delay) = failure {
                    state.rateLimitUntil = self.now().addingTimeInterval(max(30, min(86_400, delay ?? 300))); state.nextRetryAt = state.rateLimitUntil
                } else { state.rateLimitUntil = nil; state.nextRetryAt = self.now().addingTimeInterval(300) }
                next.states[id] = state
                do { try self.persist(next) } catch { self.errorMessage = APIBalanceFailure.storage.localizedDescription }
            }
        }
        tasks[id] = work
        await work.value
    }
    /// Confirmation belongs to the caller's existing removal dialog. Metadata
    /// commits before asynchronous Keychain cleanup; failures never restore a card.
    func remove(id: UUID) throws {
        guard !protectedStorage, !preparingForQuit else { throw APIBalanceFailure.storage }
        guard !saving.contains(id) else { throw APIBalanceFailure.busy }
        guard let source = sources.first(where: { $0.id == id }) else { return }
        cancel(id)
        var next = document; next.sources.removeAll { $0.id == id }; next.states[id] = nil
        try persist(next)
        if let credential = source.credentialID { scheduleCredentialRemoval(credential) }
    }
    func prepareForQuit() async throws {
        preparingForQuit = true
        let active = Array(tasks.values); for id in Array(tasks.keys) { cancel(id) }
        for task in active { await task.value }
        guard saving.isEmpty else { throw APIBalanceFailure.busy }
        for task in Array(cleanupTasks.values) { await task.value }
    }
    func resumeAfterCancelledQuit() { preparingForQuit = false }
    func shutdown() { timer?.cancel(); timer = nil; for id in Array(tasks.keys) { cancel(id) } }
    private func publish() { sources = document.sources; states = document.states }
    private func persist(_ next: APIBalanceDocument) throws {
        guard !protectedStorage else { throw APIBalanceFailure.storage }
        do { try store.save(next); document = next; publish() }
        catch { protectedStorage = true; storageError = "API 余额保存失败，原有记录已保留。"; throw APIBalanceFailure.storage }
    }
    private func cancel(_ id: UUID) { generations[id] = UUID(); tasks.removeValue(forKey: id)?.cancel(); refreshing.remove(id) }
    private func scheduleCredentialRemoval(_ id: UUID) {
        cleanupTasks[id] = Task { [weak self, credentials] in
            defer { self?.cleanupTasks[id] = nil }
            do { try await credentials.remove(id: id) }
            catch { self?.errorMessage = "来源已移除或更新，但旧钥匙串条目清理失败，请在钥匙串访问中检查方寸 API 余额条目。" }
        }
    }
    private func validate(_ snapshot: APIBalanceSnapshot, id: UUID) throws {
        try snapshot.validate(now: now())
        guard snapshot.sourceID == id, snapshot.observedAt >= now().addingTimeInterval(-300) else { throw APIBalanceFailure.invalidResponse }
    }
    private func failure(_ error: Error) -> APIBalanceFailure {
        if let failure = error as? APIBalanceFailure { return failure }
        if error is CancellationError { return .cancelled }
        return .transport
    }
}
