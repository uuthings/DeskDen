import AppKit
import Combine
import Foundation
import Network
import LauncherCore

typealias ProviderUsageBrowserRequest = @MainActor (ProviderUsageConfiguration) async throws -> ProviderUsageSnapshot

/// One owner serves the workbench and Mini. UI views never start independent collectors.
@MainActor final class ProviderUsageModel: ObservableObject {
    @Published private(set) var sources: [ProviderUsageConfiguration] = []
    @Published private(set) var states: [UUID: ProviderUsageSourceState] = [:]
    @Published private(set) var refreshing: Set<UUID> = []
    @Published var errorMessage: String?
    @Published private(set) var storageError: String?
    private let store: ProviderUsageStore
    private let client: any ProviderUsageQuerying
    private let credentials: any ProviderUsageCredentialStoring
    private let browserRequest: ProviderUsageBrowserRequest?
    private let now: @MainActor () -> Date
    private let startServices: Bool
    private var document = ProviderUsageDocument()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]
    private var saving: Set<UUID> = []
    private var timer: Task<Void, Never>?
    private var pendingSave: Task<Void, Never>?
    private var events = Set<AnyCancellable>()
    private var pathMonitor: NWPathMonitor?
    private var online = true
    private var sleeping = false
    private var preparingForQuit = false
    private var protectedStorage = false
    private var dirty = false
    private var latestTraffic: ProviderPhysicalTrafficCounter?
    private var nextAutomaticStart: Date?

    init(dataDirectory: URL, startServices: Bool = true, client: (any ProviderUsageQuerying)? = nil,
         credentials: (any ProviderUsageCredentialStoring)? = nil, browserRequest: ProviderUsageBrowserRequest? = nil,
         now: @escaping @MainActor () -> Date = { Date() }) {
        store = ProviderUsageStore(url: dataDirectory.appendingPathComponent("provider-usage.json"))
        self.client = client ?? ProviderUsageAPIClient(); self.credentials = credentials ?? ProviderUsageKeychain()
        self.browserRequest = browserRequest; self.startServices = startServices; self.now = now
        do { document = try store.load(); publish() }
        catch { protectedStorage = true; storageError = "服务用量文件无法读取，原文件已保留；修复前暂停查询和保存。" }
        guard startServices, !protectedStorage else { return }
        online = false
        let monitor = NWPathMonitor(); pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(connected) }
        }
        monitor.start(queue: DispatchQueue(label: "local.fangcun.provider-usage-network"))
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.refreshDueSources()
            }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in self?.setSleeping(true) }
        }.store(in: &events)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.setSleeping(false) }
        }.store(in: &events)
    }
    deinit { timer?.cancel(); pathMonitor?.cancel(); pendingSave?.cancel(); for task in tasks.values { task.cancel() } }

    func state(for id: UUID) -> ProviderUsageSourceState { states[id] ?? .init() }
    func receivePhysicalTraffic(_ counter: ProviderPhysicalTrafficCounter) {
        guard ProviderUsageSnapshot.validDate(counter.epoch), !protectedStorage, !preparingForQuit else { return }
        latestTraffic = counter
        var changed = false
        for source in sources where source.enabled {
            var state = state(for: source.id)
            let previous = state.refresh; state.refresh.ingest(counter)
            if previous != state.refresh { document.states[source.id] = state; changed = true }
        }
        if changed { publish(); markDirty() }
        if startServices { refreshDueSources() }
    }
    func refreshDueSources() {
        guard startServices, online, !sleeping, !preparingForQuit, !protectedStorage,
              refreshing.isEmpty, saving.isEmpty, nextAutomaticStart.map({ now() >= $0 }) ?? true else { return }
        if let source = sources.first(where: { configuration in
            let value = state(for: configuration.id)
            return configuration.enabled && value.refresh.isDue(at: now(), policy: configuration.refreshPolicy, resetAt: value.snapshot?.resetsAt)
        }) { refresh(id: source.id, manual: false) }
    }
    func refresh(id: UUID, manual: Bool = true) {
        if manual && !online { errorMessage = "当前网络不可用，请连接网络后再刷新。"; return }
        guard !protectedStorage, !preparingForQuit, !sleeping, online,
              !refreshing.contains(id), !saving.contains(id), let configuration = sources.first(where: { $0.id == id }), configuration.enabled || manual else { return }
        var state = state(for: id)
        guard state.refresh.isDue(at: now(), policy: configuration.refreshPolicy, manual: manual, resetAt: state.snapshot?.resetsAt) else { return }
        if !manual {
            guard refreshing.isEmpty, nextAutomaticStart.map({ now() >= $0 }) ?? true else { return }
            nextAutomaticStart = now().addingTimeInterval(15)
        }
        let amount = state.refresh.begin(at: now()), generation = UUID()
        generations[id] = generation; state.message = nil
        var next = document; next.states[id] = state
        guard persist(next) else { return }
        refreshing.insert(id)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { if self.generations[id] == generation { self.refreshing.remove(id); self.tasks[id] = nil } }
            do {
                let snapshot: ProviderUsageSnapshot
                if configuration.kind == .iproyal {
                    guard let browserRequest = self.browserRequest else { throw ProviderUsageFailure.unavailable("请先安装网页助手，并在浏览器打开 IPRoyal 订单页完成连接。") }
                    snapshot = try await browserRequest(configuration)
                } else {
                    guard let credentialID = configuration.credentialID,
                          let secret = try await self.credentials.read(id: credentialID) else { throw ProviderUsageFailure.authentication }
                    snapshot = try await self.client.fetch(configuration: configuration, secret: secret)
                }
                guard !Task.isCancelled, self.generations[id] == generation, self.sources.contains(where: { $0 == configuration }) else { return }
                try self.accept(snapshot, for: configuration, acknowledgedBytes: amount)
            } catch {
                guard !Task.isCancelled, self.generations[id] == generation else { return }
                self.recordFailure(self.failure(error), id: id)
            }
        }
    }

    /// Editing metadata does not retain the form or its plaintext API-key draft.
    @discardableResult func save(_ configuration: ProviderUsageConfiguration, secret: String? = nil) async -> Bool {
        guard !protectedStorage, !preparingForQuit, !saving.contains(configuration.id) else { errorMessage = storageError; return false }
        saving.insert(configuration.id); cancel(configuration.id)
        defer { saving.remove(configuration.id) }
        var newCredential: UUID?
        do {
            try configuration.validate()
            let previous = sources.first { $0.id == configuration.id }
            guard previous != nil || sources.count < 100 else { throw ProviderUsageFailure.invalidConfiguration }
            var candidate = configuration
            var nextState = state(for: configuration.id)
            if let until = nextState.refresh.rateLimitUntil, until > now() {
                throw ProviderUsageFailure.rateLimited(retryAfter: until.timeIntervalSince(now()))
            }
            let changedResource = previous.map { $0.kind != configuration.kind || $0.resourceID != configuration.resourceID } ?? true
            if changedResource { nextState = .init(); nextState.refresh.trafficCheckpoint = latestTraffic }
            let supplied = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
            if configuration.kind == .bandwagon {
                if let supplied, !supplied.isEmpty {
                    let acknowledged = nextState.refresh.pendingBytes
                    let snapshot = try await client.fetch(configuration: configuration, secret: supplied)
                    try validate(snapshot, for: configuration)
                    guard !preparingForQuit else { throw ProviderUsageFailure.cancelled }
                    let identifier = UUID(); try await credentials.write(supplied, id: identifier); newCredential = identifier
                    candidate.credentialID = identifier
                    if !changedResource { nextState = state(for: configuration.id) }
                    else if let latestTraffic { nextState.refresh.ingest(latestTraffic) }
                    let checkedReset = nextState.snapshot?.resetsAt
                    nextState.snapshot = snapshot; nextState.refresh.succeeded(at: now(), acknowledgedBytes: acknowledged, checkedReset: checkedReset); nextState.message = nil
                } else {
                    guard !changedResource, let identifier = previous?.credentialID else { throw ProviderUsageFailure.unavailable("请输入此实例的 API Key，以验证查询连接。") }
                    candidate.credentialID = identifier
                }
            } else { candidate.credentialID = nil }
            if previous?.enabled == false && candidate.enabled { nextState.refresh.trafficCheckpoint = latestTraffic }
            // Only a newly verified key or explicit browser reconnect clears authentication failure.
            var next = document
            if let index = next.sources.firstIndex(where: { $0.id == candidate.id }) { next.sources[index] = candidate }
            else { next.sources.append(candidate) }
            next.states[candidate.id] = nextState
            guard persist(next) else { throw ProviderUsageFailure.storage }
            if let old = previous?.credentialID, old != candidate.credentialID { try? await credentials.remove(id: old) }
            newCredential = nil; errorMessage = nil; return true
        } catch {
            if let newCredential { try? await credentials.remove(id: newCredential) }
            errorMessage = failure(error).localizedDescription; return false
        }
    }
    @discardableResult func remove(id: UUID) async -> Bool {
        guard !protectedStorage, !preparingForQuit, !saving.contains(id), let source = sources.first(where: { $0.id == id }) else { return false }
        saving.insert(id); cancel(id); defer { saving.remove(id) }
        var next = document; next.sources.removeAll { $0.id == id }; next.states[id] = nil
        guard persist(next) else { return false }
        if let credentialID = source.credentialID {
            do { try await credentials.remove(id: credentialID) }
            catch { errorMessage = "来源已移除，但钥匙串清理失败，请在钥匙串访问中移除对应的方寸服务用量条目。" }
        }
        return true
    }
    func reconnect(id: UUID) {
        guard !protectedStorage, !preparingForQuit, let source = sources.first(where: { $0.id == id }), source.kind == .iproyal else { return }
        if let until = state(for: id).refresh.rateLimitUntil, until > now() {
            errorMessage = ProviderUsageFailure.rateLimited(retryAfter: until.timeIntervalSince(now())).localizedDescription; return
        }
        var next = document; var state = state(for: id); state.refresh.reconnect(); state.message = nil; next.states[id] = state
        if persist(next) { refresh(id: id, manual: true) }
    }
    /// Push-only bridges must target an explicitly configured order; this method never creates one.
    @discardableResult func acceptBrowserSnapshot(_ snapshot: ProviderUsageSnapshot, for id: UUID) -> Bool {
        guard !protectedStorage, !preparingForQuit, let source = sources.first(where: { $0.id == id }), source.kind == .iproyal, source.enabled,
              !refreshing.contains(id), !saving.contains(id) else { return false }
        do { try accept(snapshot, for: source, acknowledgedBytes: state(for: id).refresh.pendingBytes); return true }
        catch { errorMessage = failure(error).localizedDescription; return false }
    }
    func prepareForQuit() async throws {
        preparingForQuit = true
        let pending = Array(tasks.values); for id in Array(tasks.keys) { cancel(id) }
        for task in pending { await task.value }
        pendingSave?.cancel(); pendingSave = nil
        // Connection saves are owned by a protected UI form and must finish before termination.
        guard saving.isEmpty else { throw ProviderUsageFailure.unavailable("请先完成服务用量连接设置。") }
        if dirty && !persist(document) { throw ProviderUsageFailure.storage }
    }
    func resumeAfterCancelledQuit() { preparingForQuit = false; refreshDueSources() }
    func setSleeping(_ value: Bool) {
        sleeping = value
        if value { for id in Array(tasks.keys) { cancel(id) }; if dirty { _ = persist(document) } }
        else { refreshDueSources() }
    }
    private func networkChanged(_ connected: Bool) {
        let restored = !online && connected; online = connected
        if !connected { for id in Array(tasks.keys) { cancel(id) } }
        else if restored { refreshDueSources() }
    }
    private func validate(_ snapshot: ProviderUsageSnapshot, for configuration: ProviderUsageConfiguration) throws {
        guard snapshot.sourceID == configuration.id else { throw ProviderUsageFailure.invalidResponse }
        try snapshot.validate(now: now())
        guard snapshot.observedAt >= now().addingTimeInterval(-300) else { throw ProviderUsageFailure.invalidResponse }
    }
    private func accept(_ snapshot: ProviderUsageSnapshot, for configuration: ProviderUsageConfiguration, acknowledgedBytes: UInt64) throws {
        try validate(snapshot, for: configuration)
        var next = document, state = state(for: configuration.id)
        guard state.snapshot.map({ snapshot.observedAt >= $0.observedAt }) ?? true else { throw ProviderUsageFailure.invalidResponse }
        let checkedReset = state.snapshot?.resetsAt
        state.recordResetObservation(snapshot, kind: configuration.kind)
        state.snapshot = snapshot; state.message = nil; state.refresh.succeeded(at: now(), acknowledgedBytes: acknowledgedBytes, checkedReset: checkedReset)
        next.states[configuration.id] = state
        guard persist(next) else { throw ProviderUsageFailure.storage }
    }
    private func recordFailure(_ failure: ProviderUsageFailure, id: UUID) {
        guard sources.contains(where: { $0.id == id }) else { return }
        var next = document, state = state(for: id)
        state.refresh.failed(failure, at: now()); state.message = failure.localizedDescription
        next.states[id] = state; _ = persist(next)
    }
    private func cancel(_ id: UUID) {
        let hadRequest = tasks[id] != nil
        generations[id] = UUID(); tasks.removeValue(forKey: id)?.cancel(); refreshing.remove(id)
        if hadRequest, var state = document.states[id], state.refresh.lastSuccessAt == nil, state.refresh.failureCount == 0 {
            state.refresh.lastAttemptAt = nil; document.states[id] = state; publish(); markDirty()
        }
    }
    private func publish() { sources = document.sources; states = document.states }
    @discardableResult private func persist(_ next: ProviderUsageDocument) -> Bool {
        guard !protectedStorage else { errorMessage = storageError; return false }
        do {
            try store.save(next); document = next; dirty = false; storageError = nil; publish(); return true
        } catch { storageError = ProviderUsageFailure.storage.localizedDescription; errorMessage = storageError; return false }
    }
    private func markDirty() {
        dirty = true; guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self else { return }; self.pendingSave = nil
            if self.dirty { _ = self.persist(self.document) }
        }
    }
    private func failure(_ error: Error) -> ProviderUsageFailure {
        if let failure = error as? ProviderUsageFailure { return failure }
        return error is CancellationError ? .cancelled : .transport
    }
}
