import Combine
import Foundation
import LauncherCore

/// The sampler gives every successful read a common timestamp. This small key
/// observes new samples without comparing every process during SwiftUI layout.
struct DeviceProcessPresentationKey: Equatable {
    let sampledAt: Date?
    let processCount: Int
    let grouped: Bool
    let filter: DeviceProcessFilter
    let query: String
    let sort: DeviceProcessSort
    let ascending: Bool
    init(processes: [DeviceProcess], grouped: Bool, filter: DeviceProcessFilter,
         query: String, sort: DeviceProcessSort, ascending: Bool) {
        sampledAt = processes.first?.sampledAt; processCount = processes.count
        self.grouped = grouped; self.filter = filter; self.query = query
        self.sort = sort; self.ascending = ascending
    }
    func hasSamePresentation(as other: Self) -> Bool {
        grouped == other.grouped && filter == other.filter && query == other.query
            && sort == other.sort && ascending == other.ascending
    }
}

private actor DeviceProcessProjectionWorker {
    private var processes: [DeviceProcess] = []
    private var grouped = true
    private var projection: DeviceProcessProjection?

    func presentation(processes: [DeviceProcess], key: DeviceProcessPresentationKey,
                      previousOrder: [String]) -> DeviceProcessPresentation? {
        guard !Task.isCancelled else { return nil }
        if projection == nil || grouped != key.grouped || self.processes != processes {
            projection = DeviceProcessProjection(processes, grouped: key.grouped)
            self.processes = processes; grouped = key.grouped
        }
        guard !Task.isCancelled else { return nil }
        return projection?.presentation(filter: key.filter, query: key.query, sort: key.sort,
                                        ascending: key.ascending, previousOrder: previousOrder)
    }
}

/// Publishes one coherent set of rows and counts. Hover/focus repaint only reads
/// this snapshot; grouping, searching and ordering execute off the main actor.
@MainActor final class DeviceProcessPresentationModel: ObservableObject {
    @Published private(set) var snapshot = DeviceProcessPresentation()
    private let worker = DeviceProcessProjectionWorker()
    private var task: Task<Void, Never>?
    private var requestID: UInt64 = 0
    private var displayedKey: DeviceProcessPresentationKey?
    private var needsOrderReset = true

    func update(processes: [DeviceProcess], grouped: Bool, filter: DeviceProcessFilter,
                query: String, sort: DeviceProcessSort, ascending: Bool, forceReorder: Bool = false) {
        let key = DeviceProcessPresentationKey(processes: processes, grouped: grouped, filter: filter,
                                               query: query, sort: sort, ascending: ascending)
        if forceReorder || displayedKey?.hasSamePresentation(as: key) != true { needsOrderReset = true }
        let previousOrder = needsOrderReset ? [] : snapshot.rows.map(\.id)
        requestID &+= 1
        let request = requestID, worker = worker
        task?.cancel()
        task = Task { [weak self] in
            guard let next = await worker.presentation(processes: processes, key: key, previousOrder: previousOrder),
                  !Task.isCancelled, let self, request == self.requestID else { return }
            self.displayedKey = key; self.needsOrderReset = false; self.snapshot = next
        }
    }

    func waitForPendingUpdateForChecks() async { await task?.value }

    deinit { task?.cancel() }
}
