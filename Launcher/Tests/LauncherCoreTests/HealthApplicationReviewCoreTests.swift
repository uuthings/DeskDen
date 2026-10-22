import XCTest
@testable import LauncherCore

final class HealthApplicationReviewCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let app = DeviceProcessApplication(bundlePath: "/Applications/Review.app", bundleIdentifier: "test.review",
                                               name: "Review", executablePath: "/Applications/Review.app/Contents/MacOS/Review")

    private func process(_ pid: Int32, application: DeviceProcessApplication? = nil, main: Bool = false,
                         parent: Int32 = 1, started: UInt64 = 1_000_000, uid: UInt32? = 501,
                         bytes: UInt64 = 100, name: String = "Worker", age: TimeInterval = 0) -> DeviceProcess {
        .init(pid: pid, name: name,
              executablePath: main ? application?.executablePath : "/Applications/Review.app/Contents/Helpers/Worker-\(pid)",
              cpuPercent: 2, residentBytes: bytes, threadCount: 1, sampledAt: now.addingTimeInterval(-age),
              startedMicroseconds: started, parentPID: parent, ownerUID: uid, application: application)
    }

    private func candidates(_ values: [DeviceProcess], source: Date? = nil, useMissingSource: Bool = false,
                            at: Date? = nil, uid: UInt32 = 501, pid: Int32 = 999,
                            ownPath: String? = "/Applications/Fangcun.app", maximumAge: TimeInterval = 15) -> [HealthApplicationCandidate] {
        HealthApplicationReviewPolicy.candidates(values, sourceAt: useMissingSource ? nil : source ?? now,
                                                 at: at ?? now, currentUID: uid, currentPID: pid,
                                                 currentApplicationPath: ownPath, maximumAge: maximumAge)
    }

    func testRealBundleAndVerifiedAncestorAggregateWithoutNameMatching() throws {
        let main = process(10, application: app, main: true, bytes: 400, name: "Unrelated main name")
        let child = process(11, parent: 10, started: 2_000_000, bytes: 300, name: "Renderer")
        let grandchild = process(12, parent: 11, started: 3_000_000, bytes: 200, name: "Worker")
        let lookalike = process(13, bytes: 50, name: "Review Helper")
        let result = candidates([grandchild, lookalike, child, main])
        let reviewed = try XCTUnwrap(result.first { $0.application == app })
        XCTAssertEqual(reviewed.processes.map(\.pid), [10, 11, 12])
        XCTAssertEqual(reviewed.residentBytes, 900)
        XCTAssertEqual(reviewed.mainProcess?.identity, main.identity)
        XCTAssertEqual(reviewed.name, "Review")
        XCTAssertTrue(reviewed.isEligible)
        let background = try XCTUnwrap(result.first { $0.application == nil })
        XCTAssertEqual(background.processes.map(\.pid), [13])
        XCTAssertFalse(background.isEligible)
        XCTAssertNil(background.request)
    }

    func testDifferentBundlesRemainSeparateEvenWithIdenticalNamesAndBundleIdentifiers() {
        var other = app
        other.bundlePath = "/Applications/Second/Review.app"
        other.executablePath = other.bundlePath + "/Contents/MacOS/Review"
        let result = candidates([process(10, application: app, main: true), process(20, application: other, main: true)])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
        XCTAssertTrue(result.allSatisfy(\.isEligible))
    }

    func testCandidateIdentitySurvivesReadingUpdatesAndHelperChangesButNotMainRestart() throws {
        let main = process(10, application: app, main: true)
        let original = try XCTUnwrap(candidates([main, process(11, application: app)]).first)
        var updated = main
        updated.residentBytes = 900_000_000
        updated.cpuPercent = 88
        updated.sampledAt = now.addingTimeInterval(-1)
        updated.name = "Renamed display text"
        let refreshed = try XCTUnwrap(candidates([updated, process(12, application: app)]).first)
        XCTAssertEqual(original.id, refreshed.id)
        updated.startedMicroseconds += 1
        let restarted = try XCTUnwrap(candidates([updated]).first)
        XCTAssertNotEqual(original.id, restarted.id)
        updated = main
        updated.pid = 20
        XCTAssertNotEqual(original.id, try XCTUnwrap(candidates([updated]).first).id)
    }

    func testMemoryOrderingUsesStableIDForTiesAndSaturatesInsteadOfOverflowing() {
        let values = [process(10, application: app, main: true, bytes: .max),
                      process(11, application: app, bytes: 10), process(20, bytes: 50), process(21, bytes: 50)]
        let first = candidates(values)
        XCTAssertEqual(first.first?.residentBytes, .max)
        XCTAssertEqual(first.dropFirst().map(\.residentBytes), [50, 50])
        XCTAssertEqual(first.dropFirst().map(\.id), first.dropFirst().map(\.id).sorted())
        XCTAssertEqual(first.map(\.id), candidates(Array(values.reversed())).map(\.id))
    }

    func testLowAndHighMemoryAreBothNeutralManualReviewCandidates() throws {
        var value = process(10, application: app, main: true, bytes: 1)
        let low = try XCTUnwrap(candidates([value]).first)
        value.residentBytes = 20_000_000_000
        value.cpuPercent = 100
        let high = try XCTUnwrap(candidates([value]).first)
        XCTAssertTrue(low.isEligible)
        XCTAssertTrue(high.isEligible)
        XCTAssertEqual(low.reason, high.reason)
        XCTAssertTrue(high.reason.contains("不代表应用异常"))
    }

    func testOnlyNormalWholeApplicationRequestIsExposedAndSyntheticDispatchTargetsMain() throws {
        let main = process(10, application: app, main: true)
        let helper = process(11, application: app)
        let candidate = try XCTUnwrap(candidates([main, helper]).first)
        let request = try XCTUnwrap(candidate.request)
        XCTAssertTrue(request.wholeApplication)
        if case .force = request.mode { XCTFail("Health review exposed force quit") }
        XCTAssertEqual(request.processes.map(\.pid), [10, 11])
        var dispatched: [(Int32, DeviceProcessOperation)] = []
        let count = try DeviceProcessActions.perform(request, currentUID: 501, currentPID: 999,
                                                     reread: { $0 == main.pid ? main : helper },
                                                     dispatch: { dispatched.append(($0.pid, $1)) })
        XCTAssertEqual(count, 1)
        XCTAssertEqual(dispatched.first?.0, main.pid)
        XCTAssertEqual(dispatched.first?.1, .quitApplication)
    }

    func testStaleFutureMissingAndInvalidSourceNeverOfferAction() {
        let main = process(10, application: app, main: true)
        for date in [now.addingTimeInterval(-15.001), now.addingTimeInterval(0.001), Date(timeIntervalSince1970: .nan)] {
            let result = candidates([main], source: date)
            XCTAssertFalse(result[0].isEligible)
            XCTAssertNil(result[0].request)
        }
        XCTAssertFalse(candidates([main], useMissingSource: true)[0].isEligible)
        XCTAssertTrue(candidates([main], source: now.addingTimeInterval(-15))[0].isEligible)
    }

    func testEveryMemberMustHaveFreshSampleAndOldestEvidenceIsShown() {
        let main = process(10, application: app, main: true, age: 2)
        var helper = process(11, application: app, age: 5)
        XCTAssertEqual(candidates([main, helper], source: now.addingTimeInterval(-3))[0].sampledAt,
                       now.addingTimeInterval(-5))
        for age in [15.001, -0.001] {
            helper.sampledAt = now.addingTimeInterval(-age)
            XCTAssertFalse(candidates([main, helper])[0].isEligible)
            XCTAssertNil(candidates([main, helper])[0].request)
        }
        helper.sampledAt = Date(timeIntervalSince1970: .nan)
        XCTAssertFalse(candidates([main, helper])[0].isEligible)
    }

    func testInvalidClockOrMaximumAgeDoesNotWeakenFreshness() {
        let main = process(10, application: app, main: true)
        for maximum in [-1.0, .infinity, .nan] {
            XCTAssertFalse(candidates([main], maximumAge: maximum)[0].isEligible)
        }
        XCTAssertFalse(candidates([main], at: Date(timeIntervalSince1970: .nan))[0].isEligible)
        XCTAssertTrue(candidates([main], maximumAge: 0)[0].isEligible)
        XCTAssertFalse(candidates([main], source: now.addingTimeInterval(-0.001), maximumAge: 0)[0].isEligible)
    }

    func testAProtectedHelperMakesWholeAppReadOnlyEvenIfMainIsAllowed() {
        let main = process(10, application: app, main: true)
        var helper = process(11, application: app)
        let owners: [UInt32?] = [0, 502, nil]
        for uid in owners {
            helper.ownerUID = uid
            XCTAssertFalse(candidates([main, helper])[0].isEligible)
        }
        helper = process(11, application: app)
        helper.startedMicroseconds = 0
        XCTAssertNil(candidates([main, helper])[0].request)
        helper = process(11, application: app)
        helper.executablePath = nil
        XCTAssertFalse(candidates([main, helper])[0].isEligible)
        helper.executablePath = "/usr/libexec/Worker"
        XCTAssertFalse(candidates([main, helper])[0].isEligible)
        helper.executablePath = "/System/Applications/Other.app/Contents/MacOS/Other"
        XCTAssertFalse(candidates([main, helper])[0].isEligible)
    }

    func testSelfOwnApplicationRootCallerAndInvalidPIDsAreProtected() {
        let main = process(10, application: app, main: true)
        XCTAssertFalse(candidates([main], pid: 10)[0].isEligible)
        XCTAssertFalse(candidates([main], ownPath: app.bundlePath)[0].isEligible)
        XCTAssertFalse(candidates([main], uid: 0)[0].isEligible)
        for pid in [Int32(-1), 0, 1] {
            XCTAssertFalse(candidates([process(pid, application: app, main: true)])[0].isEligible)
        }
    }

    func testMissingOrMultipleMainProcessesCannotBeResolvedByMemoryOrArrayOrder() {
        let helper = process(11, application: app, bytes: .max)
        let missing = candidates([helper])[0]
        XCTAssertNil(missing.mainProcess)
        XCTAssertNil(missing.request)
        let first = process(10, application: app, main: true, bytes: 1)
        let second = process(12, application: app, main: true, bytes: 1_000_000)
        let ambiguous = candidates([second, helper, first])[0]
        XCTAssertNil(ambiguous.mainProcess)
        XCTAssertFalse(ambiguous.isEligible)
        XCTAssertNil(ambiguous.request)
        XCTAssertEqual(ambiguous.id, candidates([first, helper, second])[0].id)
    }

    func testApplicationIdentityNeedsActualBundlePathIdentifierAndContainedExecutable() {
        var invalid: [DeviceProcessApplication] = []
        for path in ["", "Review.app", "/Applications/../Review.app", "/Applications/Review", "/Applications//Review.app"] {
            var value = app; value.bundlePath = path; invalid.append(value)
        }
        for identifier in ["", " ", " test.review", "test review", "test.review\n"] {
            var value = app; value.bundleIdentifier = identifier; invalid.append(value)
        }
        for path in ["", "/Applications/Elsewhere.app/Contents/MacOS/Review", app.bundlePath + "/../Other", "relative/path"] {
            var value = app; value.executablePath = path; invalid.append(value)
        }
        for value in invalid {
            let result = candidates([process(10, application: value, main: true)])[0]
            XCTAssertFalse(result.isEligible, "Accepted incomplete identity: \(value)")
            XCTAssertNil(result.request)
        }
    }

    func testMemberPathTraversalAndInconsistentBundleMetadataStayReadOnly() {
        let main = process(10, application: app, main: true)
        var helper = process(11, application: app)
        helper.executablePath = "/Applications/Review.app/../../usr/libexec/Worker"
        XCTAssertFalse(candidates([main, helper])[0].isEligible)
        helper = process(11, application: app)
        helper.application?.executablePath = "/Applications/Review.app/Contents/MacOS/Changed"
        XCTAssertFalse(candidates([main, helper])[0].isEligible)
    }

    func testIdenticalDuplicateRowsCountOnceButConflictingMainIsFiltered() {
        let main = process(10, application: app, main: true, bytes: 300)
        let helper = process(11, application: app, bytes: 200)
        let repeated = candidates([main, helper, main, helper])[0]
        XCTAssertEqual(repeated.processes.count, 2)
        XCTAssertEqual(repeated.residentBytes, 500)
        XCTAssertTrue(repeated.isEligible)
        var reused = main; reused.startedMicroseconds += 1
        let conflicted = candidates([main, helper, reused])
        XCTAssertEqual(conflicted.count, 1)
        XCTAssertEqual(conflicted[0].processes.map(\.pid), [11])
        XCTAssertFalse(conflicted[0].isEligible)
        XCTAssertNil(conflicted[0].request)
        XCTAssertTrue(candidates([main, reused]).isEmpty)
    }

    func testConflictingHelperTaintsApplicationEvenAfterUnsafePIDIsFiltered() {
        let main = process(10, application: app, main: true)
        let helper = process(11, parent: 10, started: 2_000_000)
        var conflict = helper; conflict.ownerUID = 502
        let result = candidates([main, helper, conflict])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].processes.map(\.pid), [10])
        XCTAssertFalse(result[0].isEligible)
        XCTAssertNil(result[0].request)
        XCTAssertEqual(result[0].id, candidates([conflict, helper, main])[0].id)
    }

    func testAmbiguousAncestorCannotGrantAnApplicationToItsDescendant() {
        let main = process(10, application: app, main: true)
        var conflict = main; conflict.startedMicroseconds += 1
        let child = process(11, parent: 10, started: 2_000_000)
        let result = candidates([main, conflict, child])
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].application)
        XCTAssertFalse(result[0].isEligible)
        XCTAssertNil(result[0].request)
    }

    func testWrongOwnerOrImpossibleStartOrderCannotInheritApplication() {
        let main = process(10, application: app, main: true, started: 2_000_000)
        let olderChild = process(11, parent: 10, started: 1_000_000)
        let otherUser = process(12, parent: 10, started: 3_000_000, uid: 502)
        let result = candidates([main, olderChild, otherUser])
        XCTAssertEqual(result.filter { $0.application != nil }.first?.processes.map(\.pid), [10])
        XCTAssertEqual(result.filter { $0.application == nil }.count, 2)
        XCTAssertTrue(result.filter { $0.application == nil }.allSatisfy { !$0.isEligible && $0.request == nil })
    }

    func testCapturedRequestStillRejectsPIDReuseAtExecution() throws {
        let main = process(10, application: app, main: true)
        let request = try XCTUnwrap(candidates([main])[0].request)
        var restarted = main; restarted.startedMicroseconds += 1
        XCTAssertThrowsError(try DeviceProcessActions.perform(request, currentUID: 501, currentPID: 999,
                                                               reread: { _ in restarted },
                                                               dispatch: { _, _ in XCTFail("Stale selection dispatched") })) {
            XCTAssertEqual($0 as? DeviceProcessActionError, .staleProcess)
        }
    }
}
