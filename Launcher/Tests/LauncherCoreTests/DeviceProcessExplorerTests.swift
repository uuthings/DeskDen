import XCTest
@testable import LauncherCore

final class DeviceProcessExplorerTests: XCTestCase {
    private let app = DeviceProcessApplication(bundlePath: "/Applications/Browser.app", bundleIdentifier: "test.browser", name: "Browser", executablePath: "/Applications/Browser.app/Contents/MacOS/Browser")
    private func process(_ pid: Int32, _ name: String, cpu: Double? = 0, bytes: UInt64 = 0, started: UInt64 = 1, uid: UInt32? = 501, parent: Int32 = 1, app: DeviceProcessApplication? = nil, main: Bool = false) -> DeviceProcess {
        .init(pid: pid, name: name, executablePath: main ? app?.executablePath : "/Applications/Tool.app/Contents/MacOS/\(name)", cpuPercent: cpu, residentBytes: bytes, threadCount: 1, sampledAt: .distantPast, startedMicroseconds: started, parentPID: parent, ownerUID: uid, application: app)
    }
    func testFiveFiltersUseOwnershipAndMeasuredThresholds() {
        XCTAssertEqual(DeviceProcessFilter.allCases.count, 5)
        let values = [process(11, "Missing", cpu: nil), process(12, "Idle"), process(13, "Below", cpu: 4.99), process(14, "Boundary", cpu: 5), process(15, "Busy", cpu: 32), process(16, "Invalid", cpu: .nan)]
        XCTAssertEqual(values.filter(DeviceProcessFilter.highCPU.includes).map(\.pid), [14, 15])
        let threshold = DeviceProcessFilter.highMemoryThreshold
        XCTAssertFalse(DeviceProcessFilter.highMemory.includes(process(11, "Below", bytes: threshold - 1)))
        XCTAssertTrue(DeviceProcessFilter.highMemory.includes(process(12, "Boundary", bytes: threshold)))
        XCTAssertTrue(DeviceProcessFilter.applications.includes(process(11, "Opaque", app: app)))
        XCTAssertTrue(DeviceProcessFilter.background.includes(process(12, "Browser Helper")))
    }
    func testSearchIntersectsFiltersAndSorting() {
        let values = [process(21, "Browser", cpu: 9, bytes: 200_000_000), process(32, "Browser Helper", cpu: 0.01, bytes: 400_000_000), process(43, "Editor", cpu: 17, bytes: 300_000_000)]
        XCTAssertEqual(DeviceProcessExplorer.results(values, filter: .highCPU, query: "Browser", sort: .cpu, ascending: false).map(\.pid), [21])
        XCTAssertEqual(DeviceProcessExplorer.results(values, filter: .all, query: "  32  ", sort: .pid, ascending: true).map(\.pid), [32])
        XCTAssertEqual(DeviceProcessExplorer.results(values, filter: .all, query: "", sort: .memory, ascending: true).map(\.pid), [21, 43, 32])
    }
    func testGroupsUseRealBundlesNotNamePrefixesAndAggregateValues() {
        let values = [process(21, "Browser", cpu: 3, app: app, main: true), process(32, "Renderer", cpu: 3, app: app), process(43, "Browser Helper", cpu: 1)]
        let groups = DeviceProcessExplorer.groups(values, grouped: true, filter: .all, query: "", sort: .cpu, ascending: false)
        XCTAssertEqual(groups.count, 2); XCTAssertEqual(groups[0].processes.map(\.pid), [21, 32]); XCTAssertEqual(groups[0].cpuPercent, 6); XCTAssertEqual(groups[0].mainProcess?.pid, 21)
        XCTAssertEqual(DeviceProcessExplorer.groups(values, grouped: true, filter: .highCPU, query: "", sort: .cpu, ascending: false).count, 1)
        XCTAssertEqual(DeviceProcessExplorer.groups(values, grouped: true, filter: .all, query: "32", sort: .cpu, ascending: false).first?.processes.count, 2)
        XCTAssertEqual(DeviceProcessExplorer.groups(values, grouped: false, filter: .all, query: "", sort: .cpu, ascending: false).count, 3)
    }
    func testMissingGroupCPUDoesNotBecomeZero() {
        let values = [process(21, "Browser", cpu: nil, app: app), process(32, "Renderer", cpu: 3, app: app)]
        XCTAssertNil(DeviceProcessExplorer.groups(values, grouped: true, filter: .all, query: "", sort: .cpu, ascending: false).first?.cpuPercent)
    }
    func testAncestryChecksOwnershipStartOrderAndCycles() {
        let values = [process(21, "Browser", started: 10, app: app), process(32, "Worker", started: 20, parent: 21), process(43, "Other", started: 20, uid: 0, parent: 21), process(54, "Old", started: 5, parent: 21), process(65, "CycleA", parent: 76), process(76, "CycleB", parent: 65)]
        let inherited = DeviceProcessExplorer.inheritApplications(values)
        XCTAssertEqual(inherited[1].application, app); XCTAssertNil(inherited[2].application); XCTAssertNil(inherited[3].application); XCTAssertNil(inherited[4].application)
    }
    func testStableOrderPreservesOverOneHundredRowsAndAppendsNewIdentities() {
        let before = (1...120).map { "\($0):1" }
        XCTAssertEqual(DeviceProcessExplorer.stableOrder(Array(before.reversed()) + ["121:1"], previous: before), before + ["121:1"])
        XCTAssertEqual(DeviceProcessExplorer.stableOrder(["2:2", "1:1"], previous: ["1:1", "2:1"]), ["1:1", "2:2"])
    }
    func testNormalWholeAppQuitTargetsOnlyMain() throws {
        let main = process(21, "Browser", app: app, main: true), child = process(32, "Renderer", app: app)
        var actions: [(Int32, DeviceProcessOperation)] = []
        let count = try DeviceProcessActions.perform(.init(name: "Browser", processes: [main, child], mode: .quit, wholeApplication: true), currentUID: 501, currentPID: 99, reread: { $0 == 21 ? main : child }, dispatch: { actions.append(($0.pid, $1)) })
        XCTAssertEqual(count, 1); XCTAssertEqual(actions.first?.0, 21); XCTAssertEqual(actions.first?.1, .quitApplication)
    }
    func testSelectiveChildQuitNeverQuitsTheWholeApp() throws {
        let child = process(32, "Renderer", app: app); var actions: [DeviceProcessOperation] = []
        try DeviceProcessActions.perform(.init(name: child.name, processes: [child], mode: .quit), currentUID: 501, currentPID: 99, reread: { _ in child }, dispatch: { _, operation in actions.append(operation) })
        XCTAssertEqual(actions, [.terminate])
    }
    func testForcedGroupUsesOnlyConfirmedTargetsAndMainLast() throws {
        let main = process(21, "Browser", app: app, main: true), child = process(32, "Renderer", app: app); var actions: [(Int32, DeviceProcessOperation)] = []
        try DeviceProcessActions.perform(.init(name: "Browser", processes: [main, child], mode: .force, wholeApplication: true), currentUID: 501, currentPID: 99, reread: { $0 == 21 ? main : child }, dispatch: { actions.append(($0.pid, $1)) })
        XCTAssertEqual(actions.map(\.0), [32, 21]); XCTAssertTrue(actions.allSatisfy { $0.1 == .forceTerminate })
    }
    func testProtectedSelfRootAndUnknownCannotDispatch() {
        var system = process(21, "System"); system.executablePath = "/System/Library/CoreServices/System.app/Contents/MacOS/System"
        for value in [system, process(99, "Self"), process(22, "Root", uid: 0), process(23, "Unknown", started: 0), process(1, "launchd")] {
            XCTAssertThrowsError(try DeviceProcessActions.perform(.init(name: value.name, processes: [value], mode: .force), currentUID: 501, currentPID: 99, reread: { _ in value }, dispatch: { _, _ in XCTFail("Protected action dispatched") }))
        }
    }
    func testPIDReuseOrExecutableChangeRejectsAction() {
        let selected = process(21, "Selected"); var changed = selected; changed.startedMicroseconds = 2
        XCTAssertThrowsError(try DeviceProcessActions.perform(.init(name: selected.name, processes: [selected], mode: .quit), currentUID: 501, currentPID: 99, reread: { _ in changed }, dispatch: { _, _ in XCTFail("Reused PID dispatched") }))
        changed = selected; changed.executablePath = "/Applications/Other.app/Contents/MacOS/Other"
        XCTAssertThrowsError(try DeviceProcessActions.perform(.init(name: selected.name, processes: [selected], mode: .quit), currentUID: 501, currentPID: 99, reread: { _ in changed }, dispatch: { _, _ in XCTFail("Changed identity dispatched") }))
    }
    func testImmediateRevalidationAndNoAutomaticForceFallback() {
        let selected = process(21, "Selected"); var reads = 0
        XCTAssertThrowsError(try DeviceProcessActions.perform(.init(name: selected.name, processes: [selected], mode: .quit), currentUID: 501, currentPID: 99, reread: { _ in reads += 1; return reads == 1 ? selected : nil }, dispatch: { _, _ in XCTFail("Stale identity dispatched") }))
        var calls = 0
        XCTAssertThrowsError(try DeviceProcessActions.perform(.init(name: selected.name, processes: [selected], mode: .quit), currentUID: 501, currentPID: 99, reread: { _ in selected }, dispatch: { _, operation in calls += 1; XCTAssertEqual(operation, .terminate); throw DeviceProcessActionError.failed("denied") }))
        XCTAssertEqual(calls, 1)
    }
    func testOwnApplicationHelpersAreProtectedAndMixedGroupsRejected() {
        let helper = process(32, "Helper", app: app)
        XCTAssertFalse(DeviceProcessActions.isAllowed(helper, currentUID: 501, currentPID: 99, currentApplicationPath: app.bundlePath))
        let other = process(43, "Other")
        XCTAssertThrowsError(try DeviceProcessActions.perform(.init(name: "Mixed", processes: [helper, other], mode: .force, wholeApplication: true), currentUID: 501, currentPID: 99, reread: { $0 == 32 ? helper : other }, dispatch: { _, _ in XCTFail("Mixed group dispatched") }))
    }
    func testWholeAppWithoutMainDoesNotSilentlyKillChildren() {
        let child = process(32, "Renderer", app: app)
        XCTAssertThrowsError(try DeviceProcessActions.perform(.init(name: "Browser", processes: [child], mode: .quit, wholeApplication: true), currentUID: 501, currentPID: 99, reread: { _ in child }, dispatch: { _, _ in XCTFail("Missing main fell back to child termination") })) { error in
            XCTAssertEqual(error as? DeviceProcessActionError, .missingApplicationMain)
        }
    }

    func testGroupMemoryThresholdAndMemberCountsAreDistinctFromSingleProcessMatches() {
        let values = [process(21, "Browser", bytes: 300 * 1_024 * 1_024, app: app, main: true),
                      process(32, "Renderer", bytes: 250 * 1_024 * 1_024, app: app),
                      process(43, "Independent", bytes: 600 * 1_024 * 1_024)]
        let grouped = DeviceProcessExplorer.groups(values, grouped: true, filter: .highMemory, query: "", sort: .memory, ascending: false)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped.reduce(0) { $0 + $1.processes.count }, 3)
        let flat = DeviceProcessExplorer.groups(values, grouped: false, filter: .highMemory, query: "", sort: .memory, ascending: false)
        XCTAssertEqual(flat.count, 1)
        XCTAssertEqual(flat.first?.processes.first?.pid, 43)
    }

}
