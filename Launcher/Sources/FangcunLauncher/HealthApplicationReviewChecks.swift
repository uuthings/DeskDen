import AppKit
import Foundation
import LauncherCore
import SwiftUI

/// Exercises the production application-review model with synthetic identities
/// and an injected executor. No process service, sensor, notification or network
/// operation is invoked. A controlled async gate represents an in-flight quit
/// request without sending one to any real application.
@MainActor enum HealthApplicationReviewChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let clock = ApplicationReviewCheckClock()
        let executor = ApplicationReviewCheckExecutor()
        let model = makeModel(clock: clock, executor: executor)
        check(model.candidates.isEmpty && model.selectedIDs.isEmpty && model.confirmation == nil && !model.isProcessing,
              "application review starts empty without selecting or processing any application")
        model.prepareConfirmation(); model.executeConfirmed()
        await settle()
        check(executor.requests.isEmpty && !model.hasResults && model.confirmation == nil,
              "empty application selection cannot create a plan, result or quit request")

        let original = processes(at: clock.date)
        model.update(snapshot(original, at: clock.date))
        check(model.candidates.count == 2 && model.eligibleCount == 2 && model.selectedIDs.isEmpty && model.sourceIsCurrent,
              "current synthetic application groups appear with every selection initially off")
        guard let first = model.candidates.first(where: { $0.application?.bundleIdentifier == "com.example.review.one" }),
              let second = model.candidates.first(where: { $0.application?.bundleIdentifier == "com.example.review.two" }) else {
            check(false, "application fixture exposes both independently identified bundles")
            return (count, failures)
        }
        check(first.mainProcess?.pid == 4101 && first.request?.processes.count == 2,
              "one application candidate retains the captured main process and its helper")
        check(first.id != second.id && first.application?.name == second.application?.name,
              "identically named applications in different bundles remain distinct candidates")
        model.toggle(first)
        check(model.selectedIDs == [first.id] && model.selectedCandidates.map(\.id) == [first.id] && executor.requests.isEmpty,
              "selecting an application changes only its exact identity and sends no request")
        model.toggle(first)
        check(model.selectedIDs.isEmpty, "toggling an already selected application deselects it")
        model.toggle(first); model.prepareConfirmation()
        check(model.confirmation?.candidates.map(\.id) == [first.id] && !model.savedWorkConfirmed && !model.isProcessing,
              "preparing confirmation captures selected instances and requires a separate saved-work acknowledgement")
        model.executeConfirmed(); await settle()
        check(executor.requests.isEmpty && model.confirmation != nil && !model.isProcessing && !model.hasResults,
              "confirmation without the saved-work acknowledgement cannot execute")
        model.savedWorkConfirmed = true; model.cancelConfirmation()
        check(model.confirmation == nil && !model.savedWorkConfirmed && model.selectedIDs == [first.id],
              "cancelling confirmation preserves the user's selection while clearing the acknowledgement")
        model.prepareConfirmation(); model.savedWorkConfirmed = true; model.clearSelection()
        check(model.selectedIDs.isEmpty && model.confirmation == nil && !model.savedWorkConfirmed,
              "clear selection also discards its unexecuted confirmation")

        model.toggle(first)
        let previousOrder = model.candidates.map(\.id)
        var refreshed = Array(original.reversed())
        for index in refreshed.indices {
            refreshed[index].residentBytes = refreshed[index].pid == 4201 ? 8_000_000_000 : 100_000_000
            refreshed[index].cpuPercent = refreshed[index].pid == 4201 ? 80 : 1
        }
        model.update(snapshot(refreshed, at: clock.date))
        check(model.candidates.map(\.id) == previousOrder && model.selectedIDs == [first.id],
              "live resource changes and reversed input do not reorder rows or transfer a selection between same-name bundles")
        model.prepareConfirmation()
        let capturedPlan = model.confirmation
        model.toggle(second)
        check(capturedPlan?.candidates.map(\.id) == [first.id] && model.confirmation?.candidates.map(\.id) == [first.id],
              "an already prepared confirmation cannot silently include a subsequently selected application")
        var started = 0, finished = 0
        model.onProcessingStarted = { started += 1 }; model.onProcessingFinished = { finished += 1 }
        model.savedWorkConfirmed = true; model.executeConfirmed()
        check(model.isProcessing && model.confirmation == nil && !model.savedWorkConfirmed && started == 1,
              "confirmed execution begins one operation and consumes its independent acknowledgement")
        let completed = await wait { !model.isProcessing }
        check(completed && executor.requests.count == 1 && finished == 1,
              "one selected application with helpers produces exactly one normal quit request and one completion callback")
        if let request = executor.requests.first {
            check(request.mode == .quit && request.wholeApplication && request.processes.filter(\.isApplicationMain).count == 1 &&
                  request.processes.first(where: \.isApplicationMain)?.identity == first.mainProcess?.identity,
                  "the captured request uses quit mode for the whole application and keeps its original main identity")
            check(Set(request.processes.map(\.identity)) == Set(original.filter { $0.application?.bundleIdentifier == "com.example.review.one" }.map(\.identity)),
                  "the whole-application request contains only its captured main and helper, never the same-name neighbour")
        } else { check(false, "the grouped application request is available for inspection") }
        check(model.results.count == 1 && model.results.first?.state == .requested && model.results.first?.recordedAt == clock.date &&
              model.requestedCount == 1 && model.completedCount == 1,
              "successful dispatch records a timestamped requested receipt rather than assuming application termination")
        check(model.results.first?.detail.contains("已请求") == true && truthful(model.results),
              "requested receipts describe a normal quit request without claiming closed applications or released memory")
        check(model.selectedIDs.isEmpty && !model.cancelRequested,
              "finished application processing clears selections, including later selections outside the frozen plan")

        // Every variant prepares against a valid source, then changes only the
        // evidence available immediately before dispatch. The real model must
        // revalidate instead of trusting the confirmation's copied values.
        for scenario in EvidenceChange.allCases {
            let changingClock = ApplicationReviewCheckClock()
            let changingExecutor = ApplicationReviewCheckExecutor()
            let changing = makeModel(clock: changingClock, executor: changingExecutor)
            let baseline = processes(at: changingClock.date)
            changing.update(snapshot(baseline, at: changingClock.date))
            guard let selected = changing.candidates.first(where: { $0.application?.bundleIdentifier == "com.example.review.one" }) else {
                check(false, "\(scenario.rawValue) fixture begins with a selectable application"); continue
            }
            changing.toggle(selected); changing.prepareConfirmation(); changing.savedWorkConfirmed = true
            var altered = baseline
            switch scenario {
            case .restart:
                for index in altered.indices where altered[index].application?.bundleIdentifier == "com.example.review.one" {
                    altered[index].startedMicroseconds += 100_000
                }
                changing.update(snapshot(altered, at: changingClock.date))
            case .executable:
                let path = "/Applications/Review One.app/Contents/MacOS/Replacement"
                for index in altered.indices where altered[index].application?.bundleIdentifier == "com.example.review.one" {
                    altered[index].application?.executablePath = path
                    if altered[index].pid == 4101 { altered[index].executablePath = path }
                }
                changing.update(snapshot(altered, at: changingClock.date))
            case .owner:
                for index in altered.indices where altered[index].application?.bundleIdentifier == "com.example.review.one" { altered[index].ownerUID = 502 }
                changing.update(snapshot(altered, at: changingClock.date))
            case .missingMain:
                altered.removeAll { $0.pid == 4101 }
                changing.update(snapshot(altered, at: changingClock.date))
            case .stalePerformance:
                changing.update(snapshot(altered, at: changingClock.date.addingTimeInterval(-16), displayAt: changingClock.date))
            case .futurePerformance:
                changing.update(snapshot(altered, at: changingClock.date.addingTimeInterval(1), displayAt: changingClock.date))
            case .agedAfterConfirmation:
                changingClock.date.addTimeInterval(16)
            }
            if scenario == .restart {
                check(!changing.selectedIDs.contains(selected.id) && !changing.candidates.contains(where: { $0.id == selected.id }),
                      "restarted main identity replaces the candidate without inheriting its selection")
            }
            if scenario == .stalePerformance || scenario == .futurePerformance || scenario == .agedAfterConfirmation {
                check(!changing.sourceIsCurrent && !changing.canSelect(selected),
                      "\(scenario.rawValue) cannot be selected as current even when the display timestamp is recent")
            }
            changing.executeConfirmed()
            let ended = await wait { !changing.isProcessing }
            check(ended && changingExecutor.requests.isEmpty && changing.results.count == 1 && changing.results.first?.state == .skipped,
                  "\(scenario.rawValue) is independently skipped before any quit request is dispatched")
            check(changing.selectedIDs.isEmpty && truthful(changing.results),
                  "\(scenario.rawValue) clears completed selection without inventing closed applications or released memory")
        }

        let partialExecutor = ApplicationReviewCheckExecutor(outcomes: [
            "com.example.review.two": .failed("应用拒绝请求；请检查是否有未保存的工作。"),
            "com.example.review.three": .skipped("执行器核验发现应用身份已经变化，没有发送请求。")
        ])
        let partial = makeModel(clock: clock, executor: partialExecutor)
        partial.update(snapshot(processes(at: clock.date, includeThird: true), at: clock.date))
        partial.candidates.forEach(partial.toggle); partial.prepareConfirmation(); partial.savedWorkConfirmed = true; partial.executeConfirmed()
        let partialEnded = await wait { !partial.isProcessing }
        check(partialEnded && partialExecutor.requests.count == 3 && partial.completedCount == 3 && partial.requestedCount == 1,
              "partial processing preserves independent requested, failed and skipped outcomes")
        check(partial.results.first(where: { $0.candidate.application?.bundleIdentifier == "com.example.review.two" })?.state == .failed &&
              partial.results.first(where: { $0.candidate.application?.bundleIdentifier == "com.example.review.three" })?.state == .skipped,
              "each failed or skipped application keeps its own executor result instead of an overall success label")
        check(partial.results.first(where: { $0.state == .failed })?.detail.contains("未保存") == true &&
              partial.results.first(where: { $0.state == .skipped })?.detail.contains("身份") == true &&
              partial.results.allSatisfy { $0.recordedAt == clock.date } && truthful(partial.results) && partial.selectedIDs.isEmpty,
              "partial receipts retain real reasons and timestamps without claiming memory release or completed exits")

        let modalChecks = await checkCachedConfirmation()
        count += modalChecks.count; failures += modalChecks.failures

        for stopForQuit in [false, true] {
            let gatedExecutor = ApplicationReviewCheckExecutor(gatesFirstRequest: true)
            let gated = makeModel(clock: clock, executor: gatedExecutor)
            gated.update(snapshot(processes(at: clock.date), at: clock.date))
            gated.candidates.forEach(gated.toggle); gated.prepareConfirmation(); gated.savedWorkConfirmed = true; gated.executeConfirmed()
            let entered = await wait { gatedExecutor.isWaiting }
            check(entered && gated.isProcessing && gatedExecutor.requests.count == 1 && gated.results.allSatisfy { $0.state == .pending },
                  "\(stopForQuit ? "quit barrier" : "cancel remaining") fixture holds the first dispatched request without fabricating a receipt")
            let stopState = ApplicationReviewCheckStopState()
            let stopTask: Task<Void, Never>?
            if stopForQuit {
                stopTask = Task { @MainActor in await gated.stopForQuit(); stopState.finished = true }
            } else {
                gated.cancelRemaining(); stopTask = nil
            }
            await settle()
            check(gated.isProcessing && gated.cancelRequested && gatedExecutor.requests.count == 1 && !stopState.finished,
                  "\(stopForQuit ? "stopForQuit waits for" : "cancellation retains") the in-flight request while preventing later dispatch")
            if stopForQuit {
                gated.resumeAfterCancelledQuit()
                check(gated.isProcessing && gated.cancelRequested && gated.candidates.allSatisfy { !gated.canSelect($0) } &&
                      !stopState.finished && gatedExecutor.requests.count == 1,
                      "resume cannot unlock application selection while the quit barrier still owns an in-flight request")
            }
            gatedExecutor.releaseFirst()
            if let stopTask { await stopTask.value }
            let stopped = await wait { !gated.isProcessing }
            check(stopped && gatedExecutor.requests.count == 1 && gated.results.filter { $0.state == .requested }.count == 1 &&
                  gated.results.filter { $0.state == .cancelled }.count == 1 && gated.completedCount == 2,
                  "\(stopForQuit ? "quit barrier" : "cancel remaining") records the real first request and cancels every undispatched application")
            check((!stopForQuit || stopState.finished) && gated.selectedIDs.isEmpty && truthful(gated.results),
                  "\(stopForQuit ? "quit barrier" : "cancel remaining") completes only after the real receipt and leaves no selected application")
            check(!gatedExecutor.didTimeOut,
                  "\(stopForQuit ? "quit barrier" : "cancel remaining") releases its fixture gate explicitly before the five-second safety timeout")
            if stopForQuit {
                if let candidate = gated.candidates.first { gated.toggle(candidate) }
                gated.prepareConfirmation(); gated.savedWorkConfirmed = true; gated.executeConfirmed()
                await settle()
                check(gatedExecutor.requests.count == 1 && gated.selectedIDs.isEmpty && gated.confirmation == nil && !gated.isProcessing,
                      "a model stopping for quit cannot accept or dispatch a new application selection")
                gated.resumeAfterCancelledQuit()
                check(!gated.cancelRequested && gated.selectedIDs.isEmpty && gated.confirmation == nil && !gated.savedWorkConfirmed &&
                      gated.candidates.allSatisfy { gated.canSelect($0) } && gatedExecutor.requests.count == 1,
                      "explicit resume after the completed quit barrier unlocks selection without reselecting or dispatching applications")
                if let candidate = gated.candidates.first { gated.toggle(candidate) }
                gated.prepareConfirmation()
                check(gated.confirmation?.candidates.count == 1 && !gated.savedWorkConfirmed && gatedExecutor.requests.count == 1,
                      "a resumed model can prepare a newly chosen application but requires a fresh saved-work acknowledgement")
                gated.executeConfirmed(); await settle()
                check(gatedExecutor.requests.count == 1 && !gated.isProcessing && gated.confirmation != nil,
                      "a resumed model still refuses execution until saved work is independently confirmed again")
                gated.clearSelection()
            }
        }

        #if DEBUG
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-application-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let integratedExecutor = ApplicationReviewCheckExecutor(gatesFirstRequest: true)
        defer { integratedExecutor.releaseFirst() }
        do {
            let integratedClock = ApplicationReviewCheckClock(); integratedClock.date = Date()
            let notifications = ApplicationReviewCheckNotifications()
            let device = DeviceStatusModel(dataDirectory: directory.appendingPathComponent("device"), notifications: notifications)
            let applications = makeModel(clock: integratedClock, executor: integratedExecutor)
            let healthDirectory = directory.appendingPathComponent("health")
            let health = HealthCenterModel(device: device, dataDirectory: healthDirectory, applicationReview: applications)
            var value = snapshot(processes(at: integratedClock.date), at: integratedClock.date)
            value.memory = .init(total: 32_000_000_000, used: 31_000_000_000, available: 1_000_000_000,
                                 application: 20_000_000_000, wired: 4_000_000_000, compressed: 3_000_000_000,
                                 cached: 4_000_000_000, swapUsed: nil, pageIns: 0, pageOuts: 0, pressure: .normal)
            value.disk = .init(name: "Fixture volume", fileSystem: "APFS", total: 1_000_000_000_000,
                               used: 999_000_000_000, available: 1_000_000_000, readBytesPerSecond: nil, writeBytesPerSecond: nil)
            value.thermalState = .nominal
            await device.evaluateMonitoringForChecks(snapshot: value, ledger: .init(), at: integratedClock.date)
            let forwarded = await wait { applications.candidates.count == 2 && applications.sourceAt == integratedClock.date }
            check(forwarded && health.applications === applications && applications.selectedIDs.isEmpty,
                  "the real health device subscription forwards synthetic performance readings to the injected review model")
            health.startAssessment()
            let priorReport = health.latestReport
            let historyURL = healthDirectory.appendingPathComponent("health-history.json")
            let before = try Data(contentsOf: historyURL)
            check(health.phase == .report && health.score == 60 && priorReport != nil && applications.selectedIDs.isEmpty,
                  "a real health assessment retains its measured low-storage score without preselecting applications")
            applications.candidates.forEach(applications.toggle)
            applications.prepareConfirmation(); applications.savedWorkConfirmed = true; applications.executeConfirmed()
            let requestStarted = await wait { integratedExecutor.isWaiting }
            check(requestStarted && health.phase == .processing && health.resultKind == .applications && health.latestReport == priorReport,
                  "real application processing callbacks put health in its application-processing phase without changing evidence")
            health.showOverview(); health.showResults(); health.startAssessment()
            check(health.phase == .processing && health.latestReport == priorReport && health.score == 60,
                  "health navigation and reassessment cannot replace an in-flight application operation or credit a score gain")
            let integratedStop = ApplicationReviewCheckStopState()
            let integratedQuit = Task { @MainActor in await health.prepareForQuit(); integratedStop.finished = true }
            await settle()
            check(!integratedStop.finished && applications.isProcessing && applications.cancelRequested && integratedExecutor.requests.count == 1,
                  "real HealthCenterModel.prepareForQuit waits for the dispatched request and cancels remaining applications")
            health.resumeAfterCancelledQuit()
            check(!integratedStop.finished && applications.isProcessing && applications.cancelRequested &&
                  applications.candidates.allSatisfy { !applications.canSelect($0) } && integratedExecutor.requests.count == 1,
                  "real health resume cannot bypass the application's still-running quit barrier")
            integratedExecutor.releaseFirst(); await integratedQuit.value
            check(integratedStop.finished && health.phase == .result && health.resultKind == .applications && !applications.isProcessing &&
                  applications.results.filter { $0.state == .requested }.count == 1 && applications.results.filter { $0.state == .cancelled }.count == 1,
                  "the real health quit barrier returns after the first truthful receipt and the undispatched cancellation receipt")
            check(!integratedExecutor.didTimeOut,
                  "the integrated quit barrier releases its fixture gate explicitly before the five-second safety timeout")
            check(health.waitingForFreshSample && health.latestReport == priorReport && health.score == 60 &&
                  (try? Data(contentsOf: historyURL)) == before && health.storage.receipts.isEmpty,
                  "application completion waits for fresh evidence without adding score, rewriting history or creating file receipts")
            health.resumeAfterCancelledQuit()
            check(!applications.cancelRequested && applications.selectedIDs.isEmpty && applications.confirmation == nil &&
                  !applications.savedWorkConfirmed && applications.candidates.allSatisfy { applications.canSelect($0) } && integratedExecutor.requests.count == 1,
                  "real health resume reopens manual selection after the barrier without restoring old selection or dispatching a request")
            if let candidate = applications.candidates.first { applications.toggle(candidate) }
            applications.prepareConfirmation(); applications.executeConfirmed(); await settle()
            check(applications.confirmation?.candidates.count == 1 && !applications.savedWorkConfirmed && !applications.isProcessing &&
                  integratedExecutor.requests.count == 1 && health.latestReport == priorReport && health.score == 60,
                  "a new plan after health resume still requires fresh saved-work consent and cannot automatically act or alter the score")
            applications.clearSelection()
            check(!device.isSampling && notifications.requestCount == 0 && notifications.deliveryCount == 0,
                  "integrated application fixtures never start hardware sampling or request or deliver system notifications")
            let deviceFiles = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("device").path)) ?? []
            check(!deviceFiles.contains("device-network.json") && !deviceFiles.contains("device-traffic.json"),
                  "integrated snapshot injection never starts real network accounting")
        } catch {
            integratedExecutor.releaseFirst()
            check(false, "integrated application review fixture setup: \(error.localizedDescription)")
        }
        #else
        print("HealthCenter synthetic-device integration requires DEBUG; application review model and cached modal checks ran.")
        #endif
        return (count, failures)
    }

    private enum EvidenceChange: String, CaseIterable {
        case restart, executable, owner, missingMain, stalePerformance, futurePerformance, agedAfterConfirmation
    }
    private static func makeModel(clock: ApplicationReviewCheckClock, executor: ApplicationReviewCheckExecutor) -> HealthApplicationReviewModel {
        HealthApplicationReviewModel(currentUID: 501, currentPID: 9000, currentApplicationPath: "/Applications/Fixture Host.app",
                                     executor: executor, now: { clock.date })
    }
    private static func processes(at date: Date, includeThird: Bool = false) -> [DeviceProcess] {
        let first = DeviceProcessApplication(bundlePath: "/Applications/Review One.app", bundleIdentifier: "com.example.review.one",
                                             name: "Review App", executablePath: "/Applications/Review One.app/Contents/MacOS/Review")
        let second = DeviceProcessApplication(bundlePath: "/Applications/Review Two.app", bundleIdentifier: "com.example.review.two",
                                              name: "Review App", executablePath: "/Applications/Review Two.app/Contents/MacOS/Review")
        let third = DeviceProcessApplication(bundlePath: "/Applications/Review Three.app", bundleIdentifier: "com.example.review.three",
                                             name: "Third App", executablePath: "/Applications/Review Three.app/Contents/MacOS/Review")
        func process(_ pid: Int32, _ app: DeviceProcessApplication, helper: Bool = false) -> DeviceProcess {
            .init(pid: pid, name: helper ? "Review Helper" : app.name,
                  executablePath: helper ? app.bundlePath + "/Contents/Helpers/Review Helper" : app.executablePath,
                  cpuPercent: 10, residentBytes: 900_000_000, threadCount: 4, sampledAt: date,
                  startedMicroseconds: UInt64(pid) * 1_000, parentPID: helper ? 4101 : 1, ownerUID: 501, application: app)
        }
        var result = [process(4101, first), process(4102, first, helper: true), process(4201, second)]
        if includeThird { result.append(process(4301, third)) }
        return result
    }
    private static func snapshot(_ processes: [DeviceProcess], at date: Date, displayAt: Date? = nil) -> DeviceSnapshot {
        var value = DeviceSnapshot()
        value.sampledAt = displayAt ?? date; value.performanceSampledAt = date; value.processes = processes
        value.processReadCount = processes.count; value.processTotalCount = processes.count
        return value
    }
    private static func truthful(_ results: [HealthApplicationReviewResult]) -> Bool {
        results.allSatisfy { !$0.detail.contains("已关闭") && !$0.detail.contains("已释放") && !$0.detail.contains("释放了") }
    }
    private static func checkCachedConfirmation() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let clock = ApplicationReviewCheckClock(), executor = ApplicationReviewCheckExecutor()
        let model = makeModel(clock: clock, executor: executor)
        model.update(snapshot(processes(at: clock.date), at: clock.date))
        let coordinator = WorkbenchModalCoordinator()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0; window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ApplicationReviewCheckModalRoot(model: model, coordinator: coordinator))
        window.contentView = host; coordinator.hostWindow = window; window.orderFront(nil)
        defer { coordinator.clear(); window.orderOut(nil); window.contentView = nil; window.close() }
        await pump(window) { host.bounds.width > 0 }
        if let candidate = model.candidates.first { model.toggle(candidate) }
        model.prepareConfirmation()
        let mounted = await pump(window) { coordinator.top != nil && confirmationButtonEnabled(in: host) == false }
        let presentationID = coordinator.top?.id, planID = model.confirmation?.id
        check(mounted && coordinator.presentations.count == 1 && coordinator.top?.width == 620 && presentationID != nil,
              "the real application candidates view mounts its shared cached confirmation with the actual execute button disabled")
        model.savedWorkConfirmed = true
        let enabled = await pump(window) { confirmationButtonEnabled(in: host) == true }
        check(enabled && coordinator.top?.id == presentationID && model.confirmation?.id == planID,
              "saved-work acknowledgement enables the actual execute button within the same cached modal and frozen plan")
        model.savedWorkConfirmed = false
        let disabledAgain = await pump(window) { confirmationButtonEnabled(in: host) == false }
        check(disabledAgain && coordinator.top?.id == presentationID && model.confirmation?.id == planID,
              "revoking saved-work acknowledgement disables the actual execute button without replacing the cached modal")
        check(executor.requests.isEmpty && !model.isProcessing && model.results.isEmpty && model.selectedIDs.count == 1,
              "cached confirmation validation only reads native button state and never clicks execute or dispatches an application request")
        model.cancelConfirmation()
        let dismissed = await pump(window) { coordinator.presentations.isEmpty }
        check(dismissed && !model.savedWorkConfirmed && model.selectedIDs.count == 1 && executor.requests.isEmpty,
              "cancelling the actual cached confirmation preserves the chosen application without dispatching")
        return (count, failures)
    }
    /// Read only the fixture's in-process native accessibility objects. This
    /// does not use system AX APIs or require permission to inspect other apps.
    private static func confirmationButtonEnabled(in root: NSView) -> Bool? {
        var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>()
        while let object = pending.popLast(), visited.count < 4_096 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == "health-app-confirm-quit",
               object.responds(to: NSSelectorFromString("accessibilityRole")),
               object.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue,
               object.responds(to: NSSelectorFromString("isAccessibilityEnabled")) {
                return object.value(forKey: "accessibilityEnabled") as? Bool
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] {
                pending.append(contentsOf: children)
            }
        }
        return nil
    }
    @discardableResult private static func pump(_ window: NSWindow, until condition: () -> Bool) async -> Bool {
        let limit = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < limit
        return condition()
    }
    private static func settle() async { for _ in 0..<24 { await Task.yield() } }
    private static func wait(_ condition: () -> Bool) async -> Bool {
        let limit = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < limit { try? await Task.sleep(for: .milliseconds(1)) }
        return condition()
    }
}

@MainActor private final class ApplicationReviewCheckClock {
    var date = Date(timeIntervalSince1970: 1_792_540_800)
}
private struct ApplicationReviewCheckModalRoot: View {
    @ObservedObject var model: HealthApplicationReviewModel
    @ObservedObject var coordinator: WorkbenchModalCoordinator
    var body: some View {
        ZStack {
            HealthApplicationCandidatesView(model: model, compact: false, listHeight: 252).padding(24)
            WorkbenchModalHost(coordinator: coordinator)
        }.environment(\.workbenchModals, coordinator)
            .workbenchThemeEnvironment(theme: .arWorld, opacity: 0.70, backgroundMotion: false)
    }
}
@MainActor private final class ApplicationReviewCheckStopState { var finished = false }
@MainActor private final class ApplicationReviewCheckNotifications: DeviceNotificationProviding {
    var requestCount = 0, deliveryCount = 0
    func permission() async -> DeviceNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { requestCount += 1; return false }
    func deliver(_ event: DeviceMonitoringEvent, budget: DeviceTrafficBudget, rule: DeviceTemperatureRule) async throws { deliveryCount += 1 }
}
@MainActor private final class ApplicationReviewCheckExecutor: HealthApplicationQuitRequesting {
    private(set) var requests: [DeviceProcessActionRequest] = []
    private(set) var isWaiting = false
    private(set) var didTimeOut = false
    private let outcomes: [String: HealthApplicationQuitOutcome]
    private let gatesFirstRequest: Bool
    private var releaseRequested = false
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    init(outcomes: [String: HealthApplicationQuitOutcome] = [:], gatesFirstRequest: Bool = false) {
        self.outcomes = outcomes; self.gatesFirstRequest = gatesFirstRequest
    }
    func requestQuit(_ request: DeviceProcessActionRequest) async -> HealthApplicationQuitOutcome {
        requests.append(request)
        if gatesFirstRequest && requests.count == 1 && !releaseRequested {
            isWaiting = true
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard !Task.isCancelled, let self, self.firstContinuation != nil else { return }
                    self.didTimeOut = true
                    self.releaseFirst()
                }
            }
            isWaiting = false
        }
        let bundle = request.processes.first(where: \.isApplicationMain)?.application?.bundleIdentifier ?? ""
        return outcomes[bundle] ?? .requested
    }
    func releaseFirst() {
        // Retain an early release so a request arriving after the bounded
        // entered-wait cannot open a new, unowned gate and hang the checks.
        releaseRequested = true
        timeoutTask?.cancel(); timeoutTask = nil
        let continuation = firstContinuation; firstContinuation = nil; continuation?.resume()
    }
}
