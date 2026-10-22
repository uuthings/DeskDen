import Combine
import Darwin
import Foundation
import LauncherCore

enum HealthApplicationQuitOutcome: Equatable {
    case requested
    case skipped(String)
    case failed(String)
}

/// The only production operation available to this flow is a normal application
/// quit request. The existing service rereads PID, start time, owner and bundle
/// identity immediately before asking NSRunningApplication to terminate.
@MainActor protocol HealthApplicationQuitRequesting {
    func requestQuit(_ request: DeviceProcessActionRequest) async -> HealthApplicationQuitOutcome
}

@MainActor struct HealthApplicationQuitService: HealthApplicationQuitRequesting {
    func requestQuit(_ request: DeviceProcessActionRequest) async -> HealthApplicationQuitOutcome {
        guard case .quit = request.mode, request.wholeApplication,
              request.processes.contains(where: \.isApplicationMain) else {
            return .skipped("未取得可核验的完整应用身份，没有发送请求。")
        }
        switch DeviceProcessActionService.perform(request) {
        case .success: return .requested
        case .failure(let error):
            switch error as? DeviceProcessActionError {
            case .protectedProcess, .staleProcess, .missingApplicationMain, .invalidGroup:
                return .skipped(error.localizedDescription)
            default:
                return .failed("应用未接受正常退出请求，可能正在等待保存确认；本次没有继续操作。")
            }
        }
    }
}

struct HealthApplicationReviewPlan: Identifiable {
    let id = UUID()
    let candidates: [HealthApplicationCandidate]
    let preparedAt: Date
}

enum HealthApplicationReviewResultState: Equatable { case pending, requested, skipped, failed, cancelled }
struct HealthApplicationReviewResult: Identifiable, Equatable {
    let candidate: HealthApplicationCandidate
    var state: HealthApplicationReviewResultState = .pending
    var detail = "等待逐项核验"
    var recordedAt: Date?
    var id: String { candidate.id }
}

/// Selection contains exact application-instance identities, never names or a
/// continuously changing memory total. A confirmation captures those instances;
/// new applications cannot be added to a running operation.
@MainActor final class HealthApplicationReviewModel: ObservableObject {
    @Published private(set) var candidates: [HealthApplicationCandidate] = []
    @Published private(set) var selectedIDs = Set<String>()
    @Published private(set) var confirmation: HealthApplicationReviewPlan?
    @Published var savedWorkConfirmed = false
    @Published private(set) var results: [HealthApplicationReviewResult] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var cancelRequested = false
    @Published private(set) var sourceAt: Date?
    var onProcessingStarted: (() -> Void)?
    var onProcessingFinished: (() -> Void)?
    private var processes: [DeviceProcess] = []
    private var order: [String] = []
    private let currentUID: UInt32
    private let currentPID: Int32
    private let currentApplicationPath: String?
    private let executor: any HealthApplicationQuitRequesting
    private let now: () -> Date
    private var operation: Task<Void, Never>?
    private var stoppingForQuit = false

    init(currentUID: UInt32 = getuid(), currentPID: Int32 = getpid(),
         currentApplicationPath: String? = Bundle.main.bundleURL.resolvingSymlinksInPath().path,
         executor: (any HealthApplicationQuitRequesting)? = nil, now: @escaping () -> Date = Date.init) {
        self.currentUID = currentUID; self.currentPID = currentPID
        self.currentApplicationPath = currentApplicationPath
        self.executor = executor ?? HealthApplicationQuitService(); self.now = now
    }

    var selectedCandidates: [HealthApplicationCandidate] { candidates.filter { selectedIDs.contains($0.id) } }
    var eligibleCount: Int { candidates.filter { canSelect($0) }.count }
    var completedCount: Int { results.filter { $0.state != .pending }.count }
    var requestedCount: Int { results.filter { $0.state == .requested }.count }
    var hasResults: Bool { !results.isEmpty }
    var sourceIsCurrent: Bool {
        guard let sourceAt else { return false }
        let age = now().timeIntervalSince(sourceAt)
        return age.isFinite && age >= 0 && age <= 15
    }
    func update(_ snapshot: DeviceSnapshot) {
        processes = snapshot.processes; sourceAt = snapshot.performanceSampledAt
        let incoming = currentCandidates()
        let lookup = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        order = DeviceProcessExplorer.stableOrder(incoming.map(\.id), previous: order)
        candidates = order.compactMap { lookup[$0] }
        selectedIDs.formIntersection(Set(incoming.filter(\.isEligible).map(\.id)))
    }
    func canSelect(_ candidate: HealthApplicationCandidate) -> Bool {
        !isProcessing && !stoppingForQuit && sourceIsCurrent && candidate.isEligible
    }
    func toggle(_ candidate: HealthApplicationCandidate) {
        guard canSelect(candidate), candidates.contains(where: { $0.id == candidate.id }) else { return }
        if !selectedIDs.insert(candidate.id).inserted { selectedIDs.remove(candidate.id) }
    }
    func clearSelection() {
        guard !isProcessing else { return }; selectedIDs.removeAll(); cancelConfirmation()
    }
    func prepareConfirmation() {
        guard !isProcessing, !stoppingForQuit else { return }
        let eligible = Dictionary(uniqueKeysWithValues: currentCandidates().filter(\.isEligible).map { ($0.id, $0) })
        let selected = candidates.compactMap { selectedIDs.contains($0.id) ? eligible[$0.id] : nil }
        guard !selected.isEmpty else { selectedIDs.removeAll(); return }
        savedWorkConfirmed = false; confirmation = .init(candidates: selected, preparedAt: now())
    }
    func cancelConfirmation() { guard !isProcessing else { return }; confirmation = nil; savedWorkConfirmed = false }
    func executeConfirmed() {
        guard let plan = confirmation, savedWorkConfirmed, !isProcessing, !stoppingForQuit else { return }
        confirmation = nil; savedWorkConfirmed = false; cancelRequested = false
        results = plan.candidates.map { .init(candidate: $0) }; isProcessing = true
        onProcessingStarted?()
        operation = Task { [weak self] in guard let self else { return }; await self.run(plan) }
    }
    /// Do not cancel the dispatched request. Finish its truthful receipt, then
    /// skip the remaining frozen plan and let the application quit barrier wait.
    func cancelRemaining() { cancelRequested = true; if !isProcessing { cancelConfirmation() } }
    func stopForQuit() async {
        stoppingForQuit = true; cancelRemaining()
        if let operation { await operation.value }
    }
    func resumeAfterCancelledQuit() {
        guard !isProcessing, operation == nil else { return }
        stoppingForQuit = false; cancelRequested = false
        confirmation = nil; savedWorkConfirmed = false
    }
    private func currentCandidates() -> [HealthApplicationCandidate] {
        HealthApplicationReviewPolicy.candidates(processes, sourceAt: sourceAt, at: now(), currentUID: currentUID,
            currentPID: currentPID, currentApplicationPath: currentApplicationPath)
    }
    private func run(_ plan: HealthApplicationReviewPlan) async {
        for (index, selected) in plan.candidates.enumerated() {
            await Task.yield()
            if cancelRequested || stoppingForQuit {
                record(index, state: .cancelled, detail: "已取消后续处理，没有发送退出请求。")
                continue
            }
            guard let fresh = currentCandidates().first(where: { $0.id == selected.id }), fresh.isEligible,
                  fresh.application == selected.application,
                  fresh.mainProcess?.identity == selected.mainProcess?.identity,
                  fresh.mainProcess?.executablePath == selected.mainProcess?.executablePath,
                  let request = selected.request else {
                record(index, state: .skipped, detail: "来源已过期、应用已退出或身份已变化；没有发送请求。")
                continue
            }
            switch await executor.requestQuit(request) {
            case .requested: record(index, state: .requested, detail: "已请求正常退出，等待应用结束或保存确认。")
            case .skipped(let reason): record(index, state: .skipped, detail: reason)
            case .failed(let reason): record(index, state: .failed, detail: reason)
            }
        }
        selectedIDs.removeAll(); isProcessing = false; operation = nil
        onProcessingFinished?()
    }
    private func record(_ index: Int, state: HealthApplicationReviewResultState, detail: String) {
        guard results.indices.contains(index) else { return }
        results[index].state = state; results[index].detail = detail; results[index].recordedAt = now()
    }
}
