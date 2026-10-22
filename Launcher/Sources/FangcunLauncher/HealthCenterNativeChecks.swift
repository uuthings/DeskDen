import Foundation
import LauncherCore
#if DEBUG
import AppKit
import SwiftUI
#endif

/// Tests the production HealthCenterModel and its device subscription using only
/// injected snapshots and isolated history. Device sampling is never started.
/// The processing-completion callback below tests the model contract. Real
/// isolated transaction and quit barriers run in StorageReviewServiceChecks.
@MainActor enum HealthCenterNativeChecks {
    static func run() async -> (count: Int, failures: Int) {
        #if DEBUG
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-health-native-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let notifications = HealthCheckNotifications()
            let device = DeviceStatusModel(dataDirectory: root.appendingPathComponent("device"), notifications: notifications)
            let directory = root.appendingPathComponent("health")
            let model = HealthCenterModel(device: device, dataDirectory: directory)
            await settle()
            check(model.phase == .overview && model.latestReport == nil && model.score == nil && model.summary == "尚未体检",
                  "health begins unknown rather than publishing an initial perfect score")
            check(!device.isSampling && !model.storage.isScanning && !model.storage.isProcessing && model.storage.scopes.isEmpty,
                  "opening health does not start hardware sampling, file scanning or processing")
            check(model.completedFactors.isEmpty && model.storage.receipts.isEmpty,
                  "initial health has no invented completed checks or file receipts")
            model.cancelCheck()
            check(model.phase == .overview && model.score == nil && model.latestReport == nil && model.assessmentOutcome == .cancelled,
                  "cancelling before a completed assessment cannot manufacture a report or score")
            model.showOverview()
            model.returnContext = "设备状态"
            model.startAssessment()
            check(model.phase == .report && model.latestReport?.stage == .report && model.score == nil,
                  "assessment with no performance sample completes evidence collection without a precise score")
            check(model.completedFactors.count == DeviceHealthFactor.allCases.count && model.latestReport?.evaluatedRequiredCount == 0,
                  "native assessment progress comes from four actual rule callbacks, with zero missing factors credited")
            check(model.latestReport?.factors.allSatisfy { $0.state == .missing && $0.deduction == nil } == true,
                  "all absent native readings remain missing with no implicit zero deduction")
            check(model.storage.report == nil && !model.storage.isScanning && model.storage.receipts.isEmpty,
                  "default suggestions without explicitly selected directories never inspect personal files")
            model.cancelCheck()
            check(model.score == nil && model.storage.receipts.isEmpty,
                  "cancel on an incomplete native report does not invent score or actions")

            let validAt = Date()
            var valid = sample(at: validAt)
            valid.cpuPercent = 100; valid.cpuTemperature = 119; valid.gpuTemperature = nil
            await inject(valid, into: device)
            model.startAssessment()
            let healthy = try requiredReport(model)
            check(model.score == 100 && healthy.evaluatedRequiredCount == 3 && healthy.requiredCount == 3,
                  "only complete valid storage, memory pressure and thermal coverage enables native score")
            check(healthy.factors.first { $0.factor == .battery }?.state == .missing && healthy.evaluatedCount == 3,
                  "a device without readable battery health is not treated as a failed scored factor")
            check(healthy.factors.filter { $0.factor.isRequiredForScore }.allSatisfy { $0.deduction == 0 && $0.sampledAt == validAt && !$0.source.isEmpty },
                  "native report retains actual source times and evidence instead of CPU or occupancy deductions")
            check(healthy.ruleVersion == DeviceHealthRules.version && (try? healthy.validated()) == healthy,
                  "native report uses the versioned, internally consistent health rules")
            check(healthy.factors.first { $0.factor == .memory }?.evidence.first { $0.key == "pressure" }?.value == DevicePressure.normal.rawValue,
                  "high occupied memory and transient CPU/temperature values cannot replace actual normal pressure")
            let reportID = healthy.id
            for category in HealthCenterCategory.allCases {
                model.showCategory(category)
                check(model.phase == .report && model.category == category && model.latestReport?.id == reportID && model.returnContext == "设备状态",
                      "health category \(category.rawValue) preserves the report identity and entry return source")
            }
            model.reportExpanded = true; model.includeCache = false; model.includeDiagnostics = false; model.includeMemory = false
            model.showReport()
            check(model.category == .overview && model.reportExpanded && !model.includeCache && !model.includeDiagnostics && !model.includeMemory,
                  "returning to the report preserves expanded evidence and explicit suggestion choices")
            model.showOverview()
            check(model.phase == .overview && model.category == .overview && model.latestReport?.id == reportID && model.returnContext == "设备状态",
                  "returning to health overview keeps report and caller context")
            let diskHistory = try readHistory(directory)
            let reloaded = HealthCenterModel(device: device, dataDirectory: directory)
            check(diskHistory.reports.first?.id == reportID && reloaded.latestReport == healthy && reloaded.score == 100,
                  "saved native health report reloads independently with the same score, rule and evidence")

            var missing = sample(at: Date()); missing.memory = nil
            await inject(missing, into: device); model.startAssessment()
            check(model.score == nil && model.latestReport?.evaluatedRequiredCount == 2 && factor(model, .memory)?.state == .missing,
                  "one absent required source suppresses the native score rather than redistributing weights")
            var unknownPressure = sample(at: Date()); unknownPressure.memory?.pressure = .unknown
            await inject(unknownPressure, into: device); model.startAssessment()
            check(model.score == nil && factor(model, .memory)?.state == .missing,
                  "unknown native pressure is not inferred from occupied memory")
            var unknownThermal = sample(at: Date()); unknownThermal.thermalState = .unknown
            await inject(unknownThermal, into: device); model.startAssessment()
            check(model.score == nil && factor(model, .thermal)?.state == .missing,
                  "unknown native thermal state cannot be labelled healthy or overheated")
            var invalidDisk = sample(at: Date()); let invalidAvailable = invalidDisk.disk!.total + 1
            invalidDisk.disk?.available = invalidAvailable
            await inject(invalidDisk, into: device); model.startAssessment()
            check(model.score == nil && factor(model, .storage)?.state == .failed,
                  "inconsistent native disk capacity fails validation rather than being clamped to healthy")
            var stale = sample(at: Date().addingTimeInterval(-120)); stale.sampledAt = Date()
            await inject(stale, into: device); model.startAssessment()
            check(model.score == nil && model.latestReport?.factors.filter { $0.factor.isRequiredForScore }.allSatisfy { $0.state == .stale } == true,
                  "fresh network-only timestamp cannot disguise stale performance readings")
            await inject(sample(at: Date().addingTimeInterval(120)), into: device); model.startAssessment()
            check(model.score == nil && model.latestReport?.factors.filter { $0.factor.isRequiredForScore }.allSatisfy { $0.state == .failed } == true,
                  "future native sampling times are rejected rather than presented as current evidence")

            var transient = sample(at: Date()); transient.memory?.pressure = .warning; transient.thermalState = .serious
            await inject(transient, into: device); model.startAssessment()
            check(model.score == nil && factor(model, .memory)?.state == .observing && factor(model, .thermal)?.state == .observing,
                  "first native pressure and thermal spikes remain observing without premature deductions")
            // Feed consecutive, timestamped samples spanning 60 seconds. No real-time delay,
            // sensor access or synthetic timer progress is needed to test the adapter.
            let sustainedEnd = Date().addingTimeInterval(-1)
            for offset in stride(from: -60.0, through: 0.0, by: 6.0) {
                var value = sample(at: sustainedEnd.addingTimeInterval(offset), available: 100_000_000_000)
                value.memory?.pressure = .warning; value.thermalState = .serious
                await inject(value, into: device)
            }
            model.startAssessment()
            check(model.score == 55 && factor(model, .memory)?.deduction == 14 && factor(model, .thermal)?.deduction == 15 && factor(model, .storage)?.deduction == 16,
                  "native continuity earns only the documented deductions after sixty seconds of uninterrupted evidence")
            let sustainedID = model.latestReport?.id
            await inject(sample(at: Date()), into: device)
            check(model.latestReport?.id == sustainedID && model.score == 55,
                  "a subsequent background sample does not silently rewrite a completed report")
            model.startAssessment()
            check(model.score == 100 && model.latestReport?.id != sustainedID,
                  "an explicit reassessment evaluates fresh readings instead of fixed action bonuses")

            let priorReport = try requiredReport(model)
            model.storage.onProcessingFinished?()
            check(model.phase == .result && model.waitingForFreshSample && model.latestReport == priorReport && model.score == 100,
                  "processing completion contract requests a later sample while preserving the measured previous score")
            await inject(sample(at: Date().addingTimeInterval(-120), available: 1_000_000_000), into: device)
            check(model.waitingForFreshSample && model.latestReport == priorReport && model.score == 100,
                  "an old post-processing sample cannot end waiting or alter the score")
            var noTimestamp = sample(at: Date()); noTimestamp.performanceSampledAt = nil
            await inject(noTimestamp, into: device)
            check(model.waitingForFreshSample && model.latestReport == priorReport,
                  "missing post-processing sample time cannot masquerade as a completed reassessment")
            await inject(sample(at: Date().addingTimeInterval(0.1), available: 1_000_000_000), into: device)
            check(!model.waitingForFreshSample && model.score == 60 && model.latestReport?.id != priorReport.id,
                  "a genuinely later complete sample recalculates from actual disk evidence without automatic score gain")
            let resultingID = model.latestReport?.id
            model.showResults(); model.showReport(); model.showOverview()
            check(model.phase == .overview && model.latestReport?.id == resultingID && model.returnContext == "设备状态",
                  "result, report and overview navigation preserves the same reassessed evidence and source")
            model.beginProcessing()
            check(model.phase == .overview && !model.storage.isProcessing && model.storage.receipts.isEmpty,
                  "processing without a separately confirmed selected-file plan performs no action")
            await model.prepareForQuit()
            check(!model.storage.isScanning && !model.storage.isProcessing && model.storage.receipts.isEmpty,
                  "idle prepare-for-quit finishes without inventing operations or receipts")
            check(!device.isSampling && notifications.requestCount == 0 && notifications.deliveredCount == 0,
                  "native health fixtures never start sensors or request or deliver system notifications")

            let latestHistory = try readHistory(directory)
            check(latestHistory.reports.count <= 30 && latestHistory.reports.first?.id == resultingID && (try? latestHistory.validated()) != nil,
                  "native history stores the latest validated report while respecting its bounded retention")

            model.storage.onProcessingFinished?()
            check(model.waitingForFreshSample, "processing completion establishes a pending automatic recheck")
            model.startAssessment()
            let manualID = model.latestReport?.id
            await inject(sample(at: Date().addingTimeInterval(0.2)), into: device)
            check(!model.waitingForFreshSample && model.latestReport?.id == manualID && model.score == 60,
                  "manual assessment clears its superseded automatic request so the next sample cannot silently reassess twice")
            let beforeCancelled = try requiredReport(model)
            let beforeCancelledData = try Data(contentsOf: directory.appendingPathComponent("health-history.json"))
            model.beginAssessmentAwaitingScanForChecks()
            check(model.phase == .checking && model.completedFactors.count == 4 && model.latestReport == beforeCancelled,
                  "pending file-scan boundary keeps prior report while new device evidence is provisional")
            model.cancelCheck()
            check(model.phase == .overview && model.assessmentOutcome == .cancelled && model.showingPreviousReport && model.latestReport == beforeCancelled && model.assessmentNotice?.contains("上次") == true,
                  "cancelled native check returns to overview and clearly labels the retained previous report")
            model.storage.onScanFinished?()
            check(model.latestReport == beforeCancelled && model.phase == .overview && (try? Data(contentsOf: directory.appendingPathComponent("health-history.json"))) == beforeCancelledData,
                  "late scan completion after cancellation cannot publish or persist a new complete score")
            model.beginAssessmentAwaitingScanForChecks(); model.storage.onScanFinished?()
            check(model.assessmentOutcome == .failed && model.phase == .overview && model.latestReport == beforeCancelled && model.showingPreviousReport,
                  "missing scan result remains an incomplete assessment, preserving prior evidence instead of reporting success")
            model.startAssessment()
            check(model.assessmentOutcome == .completed && model.assessmentNotice == nil && model.score == 100,
                  "a later fully completed manual assessment replaces the previous-report notice with actual new evidence")
            let cancelledPendingDirectory = root.appendingPathComponent("cancelled-pending")
            let cancelledPending = HealthCenterModel(device: device, dataDirectory: cancelledPendingDirectory)
            cancelledPending.beginAssessmentAwaitingScanForChecks(); cancelledPending.cancelAll(); cancelledPending.storage.onScanFinished?()
            check(cancelledPending.phase == .overview && cancelledPending.score == nil && cancelledPending.latestReport == nil && !FileManager.default.fileExists(atPath: cancelledPendingDirectory.appendingPathComponent("health-history.json").path),
                  "cancelling a first provisional assessment never creates a completed history record or score")

            let capacityText = HealthCenterEvidenceDisplay.text(.init("availableBytes", "1048576"))
            check(capacityText.label == "可用空间" && capacityText.value == "1 MB",
                  "health capacity evidence uses a Chinese label and actual byte conversion")
            check(HealthCenterEvidenceDisplay.text(.init("availableFraction", "0.125")).value == "12.5%",
                  "health free-space evidence converts the actual fraction to percent")
            check(HealthCenterEvidenceDisplay.text(.init("sustainedSeconds", "60")).value == "60 秒" && HealthCenterEvidenceDisplay.text(.init("sustainedSeconds", "0.5")).value == "0.5 秒",
                  "health duration evidence preserves measured seconds and fractional values")
            check(HealthCenterEvidenceDisplay.text(.init("pressure", "warning")).value == "压力中等" && HealthCenterEvidenceDisplay.text(.init("thermalState", "critical")).value == "临界",
                  "actual pressure and thermal states have distinct human-readable Chinese values")
            check(HealthCenterEvidenceDisplay.text(.init("condition", "serviceRecommended")).value == "系统建议检修",
                  "battery evidence retains the source's service recommendation without claiming a diagnosis")
            check(HealthCenterEvidenceDisplay.text(.init("availableBytes", "invalid")).value == "读数不可用" && HealthCenterEvidenceDisplay.text(.init("availableFraction", "NaN")).value == "读数不可用" && HealthCenterEvidenceDisplay.text(.init("sustainedSeconds", "-1")).value == "读数不可用",
                  "invalid capacities, ratios and durations never become fabricated zero readings")
            check(HealthCenterEvidenceDisplay.text(.init("pressure", "unknown")).value == "不可用" && HealthCenterEvidenceDisplay.text(.init("thermalState", "unrecognized")).value == "不可用",
                  "unknown source states never become normal through evidence formatting")
            let rule = "只按来源判断"
            check(HealthCenterEvidenceDisplay.text(.init("rule", rule)) == .init(label: "评分规则", value: rule) && HealthCenterEvidenceDisplay.text(.init("volume", "Fixture volume")).value == "Fixture volume",
                  "evidence formatting preserves original rule and volume source text")
            let unsupported = try alteredHistory(latestHistory, key: "ruleVersion", value: "future")
            let forged = try alteredHistory(latestHistory, key: "score", value: 999)
            for (name, bytes) in [("broken", Data("{broken".utf8)), ("unsupported", unsupported), ("forged-score", forged)] {
                let badDirectory = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: badDirectory, withIntermediateDirectories: true)
                let url = badDirectory.appendingPathComponent("health-history.json"); try bytes.write(to: url)
                let protected = HealthCenterModel(device: device, dataDirectory: badDirectory)
                protected.startAssessment()
                check(protected.storageError != nil && (try? Data(contentsOf: url)) == bytes && protected.latestReport != nil,
                      "\(name) native history is preserved while new evidence stays session-only")
            }
            let cancelledDirectory = root.appendingPathComponent("cancelled-history")
            try FileManager.default.createDirectory(at: cancelledDirectory, withIntermediateDirectories: true)
            var cancelledHistory = DeviceHealthHistory()
            let cancelledReport = DeviceHealthAssessor.evaluate(coreSample(at: Date()), isCancelled: { true })
            try cancelledHistory.append(cancelledReport)
            try JSONEncoder().encode(cancelledHistory).write(to: cancelledDirectory.appendingPathComponent("health-history.json"))
            let cancelledReload = HealthCenterModel(device: device, dataDirectory: cancelledDirectory)
            check(cancelledReload.score == nil && cancelledReload.latestReport == nil && cancelledReload.storageError == nil,
                  "valid cancelled history cannot reload as a completed assessment or precise native score")
            let emptyData = root.appendingPathComponent("device")
            let deviceFiles = (try? FileManager.default.contentsOfDirectory(atPath: emptyData.path)) ?? []
            check(!deviceFiles.contains("device-network.json") && !deviceFiles.contains("device-traffic.json"),
                  "snapshot injection does not start network accounting or read the real sampler")
            print("Health in-flight transaction and quit barrier are covered separately by StorageReviewServiceChecks using an isolated injected mover.")
        } catch { check(false, "native health fixture setup: \(error.localizedDescription)") }
        let navigation = await checkHistoryNavigation()
        count += navigation.count; failures += navigation.failures
        if let path = ProcessInfo.processInfo.environment["FANGCUN_HEALTH_VISUAL_EVIDENCE_DIR"], !path.isEmpty {
            let visual = await checkMountedVisualStates(exportDirectory: URL(fileURLWithPath: path))
            count += visual.count; failures += visual.failures
        }
        return (count, failures)
        #else
        print("Health native fixtures require a DEBUG candidate; production sampler was not started.")
        return (0, 0)
        #endif
    }
    #if DEBUG
    /// Calls the exact action captured from each mounted production Button.
    /// This is an owned-view action check, not a claim of native mouse input.
    private static func checkHistoryNavigation() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") health record navigation: \(name)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-health-record-navigation-\(UUID().uuidString)")
        let clock = Date(), notifications = HealthCheckNotifications(), mover = HealthHistoryNoMove()
        let executor = HealthVisualQuitGate()
        let device = DeviceStatusModel(dataDirectory: root.appendingPathComponent("Device"), notifications: notifications)
        let applications = HealthApplicationReviewModel(currentUID: 501, currentPID: 9000,
            currentApplicationPath: root.appendingPathComponent("Host.app").path, executor: executor, now: { clock })
        var app: WorkbenchAppModel?, controller: WorkbenchWindowController?, owner: LauncherController?
        let oldTheme = Palette.workbenchTheme, oldOpacity = Palette.glassOpacity, oldLight = Palette.isLight
        defer {
            executor.release(); app?.shutdown()
            controller?.window?.orderOut(nil); controller?.window?.delegate = nil
            controller?.window?.contentView = nil; controller?.window?.close()
            owner?.panel?.orderOut(nil); owner?.panel?.delegate = nil; owner?.panel?.close()
            owner?.hotKey.unregister(); owner?.bindingHotKeys.unregister(); owner?.toastTask?.cancel()
            owner?.workbenchController = nil
            Palette.workbenchTheme = oldTheme; Palette.glassOpacity = oldOpacity; Palette.isLight = oldLight
            try? FileManager.default.removeItem(at: root)
        }
        do {
            let source = root.appendingPathComponent("explicit-cache"), data = root.appendingPathComponent("Health")
            for directory in [source, data] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            for name in ["prior.cache", "selected.cache"] { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
            let scope = StorageReviewScope(directory: source, kind: .rebuildableCache)
            let seeded = try StorageReviewScanner.scan(scopes: [scope], now: clock)
            guard let prior = seeded.candidates.first(where: { $0.relativePath == "prior.cache" }), let record = seeded.scopes.first else {
                throw HealthVisualError.invalid("isolated receipt source missing")
            }
            let receipt = StorageReviewReceipt(operationID: UUID(), candidate: prior, scope: record,
                result: .init(candidateID: prior.id, state: .skipped, reason: "QA 隔离历史；没有移动文件"))
            try JSONEncoder().encode([receipt]).write(to: data.appendingPathComponent("storage-actions.json"))
            let storage = StorageReviewService(dataDirectory: data, mover: mover)
            let health = HealthCenterModel(device: device, dataDirectory: data, storageService: storage, applicationReview: applications)
            let inspection = HealthHistoryNavigationInspection(); health.historyNavigationInspection = inspection
            let calendarSystem = HealthVisualCalendarSystem(), calendarNotifications = HealthVisualCalendarNotifications()
            let calendar = CalendarModel(dataDirectory: root.appendingPathComponent("Calendar"), system: calendarSystem, notifier: calendarNotifications)
            let ai = AIUsageModel(dataDirectory: root.appendingPathComponent("AI"), startServices: false, notifications: HealthVisualAINotifications())
            let hostOwner = LauncherController(dataDirectory: root.appendingPathComponent("Launcher")); owner = hostOwner
            hostOwner.configuration.settings.workbenchTheme = .arWorld
            hostOwner.configuration.settings.workbenchAppearance = .dark
            hostOwner.configuration.settings.backgroundMotionEnabled = false
            hostOwner.configuration.settings.reduceMotion = true
            hostOwner.configurePanel(); hostOwner.scanning = true; hostOwner.panel.isReleasedWhenClosed = false
            let hostApp = WorkbenchAppModel(owner: hostOwner, calendar: calendar, ai: ai, device: device, health: health, startServices: false); app = hostApp
            let hostController = WorkbenchWindowController(owner: hostOwner, model: hostApp, autosavesFrame: false); controller = hostController
            hostOwner.workbenchController = hostController
            guard let window = hostController.window, let host = window.contentView else { throw HealthVisualError.invalid("missing full production Workbench host") }
            hostApp.navigate(.health); hostApp.setWindowVisible(true); hostApp.syncAppearance()
            window.alphaValue = 1; window.ignoresMouseEvents = true; window.orderFront(nil)
            let bundle = root.appendingPathComponent("Synthetic Review.app").path
            let identity = DeviceProcessApplication(bundlePath: bundle, bundleIdentifier: "local.fangcun.health-history.synthetic",
                name: "QA 合成应用", executablePath: bundle + "/Contents/MacOS/Synthetic")
            var value = sample(at: clock)
            value.processes = [.init(pid: 4101, name: identity.name, executablePath: identity.executablePath, cpuPercent: 0,
                residentBytes: 800_000_000, threadCount: 2, sampledAt: clock, startedMicroseconds: 4_101_000, parentPID: 1, ownerUID: 501, application: identity)]
            value.processReadCount = 1; value.processTotalCount = 1
            await inject(value, into: device)
            guard await visualWait(host, until: { applications.candidates.count == 1 }) else { throw HealthVisualError.invalid("synthetic application source missing") }
            try storage.registerScope(scope); health.startAssessment()
            check(storage.isScanning && !health.canShowResults, "an actual isolated file scan disables record navigation")
            health.showResults(kind: .applications)
            check(health.phase == .checking, "record navigation cannot interrupt the actual in-flight scan")
            guard await visualWait(host, until: { !storage.isScanning && health.phase == .report }),
                  let selected = storage.report?.candidates.first(where: { $0.relativePath == "selected.cache" }),
                  let application = applications.candidates.first else { throw HealthVisualError.invalid("complete review source missing") }
            storage.toggle(selected); applications.toggle(application)
            applications.prepareConfirmation(); applications.savedWorkConfirmed = true; applications.executeConfirmed()
            guard await visualWait(host, until: { executor.entered && applications.isProcessing }) else { throw HealthVisualError.invalid("fake normal-quit gate missing") }
            health.showResults(kind: .files)
            check(!health.canShowResults && health.phase == .processing && health.resultKind == .applications,
                  "record navigation cannot interrupt an actual pending fake application request")
            executor.release()
            guard await visualWait(host, until: { !applications.isProcessing && applications.hasResults }) else { throw HealthVisualError.invalid("fake application receipt missing") }
            applications.toggle(application); health.reportExpanded = true
            let reportID = health.latestReport?.id, scanID = storage.report?.id
            let fileSelection = storage.selectedIDs, applicationSelection = applications.selectedIDs
            let journal = try Data(contentsOf: data.appendingPathComponent("storage-actions.json"))
            check(fileSelection == [selected.id] && applicationSelection == [application.id], "real review selections are nonempty before navigation checks")
            health.showResults()
            check(health.phase == .result && health.resultKind == .files, "default record navigation prioritizes persistent file receipts after an application result")
            let applicationsOnly = HealthCenterModel(device: device, dataDirectory: root.appendingPathComponent("ApplicationOnly"), applicationReview: applications)
            applicationsOnly.showResults()
            check(applicationsOnly.phase == .result && applicationsOnly.resultKind == .applications, "application-only history still opens its actual result kind")
            for (sizeName, size, pageWidth) in [("window", NSSize(width: 1120, height: 758), CGFloat(864)),
                                               ("compact", NSSize(width: 960, height: 720), CGFloat(736)),
                                               ("large", NSSize(width: 1728, height: 993), CGFloat(1360))] {
                window.setContentSize(size)
                for (page, category) in [("overview", HealthCenterCategory.overview), ("report", .overview), ("files", .cache), ("memory", .memory)] {
                    func returnToPage() { if page == "overview" { health.showOverview() } else { health.showCategory(category) } }
                    returnToPage()
                    let mounted = await visualWait(host) {
                        historyButton(.files, in: host) != nil && historyButton(.applications, in: host) != nil &&
                        visualFrames("health-workspace", in: host).contains { abs($0.width - pageWidth) < 2 }
                    }
                    if page == "overview" { await revealHistoryButtons(in: host, window: window, label: sizeName + "/" + page) }
                    let viewport = historyViewport(in: host, window: window)
                    let buttons = [historyButton(.files, in: host), historyButton(.applications, in: host)]
                    let frames = buttons.compactMap { $0.flatMap(visualFrame) }
                    check(mounted && frames.count == 2 && frames.allSatisfy { abs($0.height - 28) < 1 && viewport.contains($0) } &&
                          abs(frames[0].midY - frames[1].midY) < 1 && frames[0].maxX <= frames[1].minX,
                          "\(sizeName)/\(page) both compact 28-point record buttons share one visible row within the unchanged page width")
                    for kind in [HealthCenterResultKind.files, .applications] {
                        returnToPage()
                        guard await visualWait(host, until: { historyButton(kind, in: host) != nil }), let action = inspection.actions[kind] else {
                            check(false, "\(sizeName)/\(page) mounted \(kind) button action missing"); continue
                        }
                        if page == "overview" { await revealHistoryButtons(in: host, window: window, label: sizeName + "/" + page + "/" + String(describing: kind)) }
                        action()
                        let resultID = kind == .files ? "health-file-results" : "health-application-results"
                        let opened = await visualWait(host) { health.phase == .result && health.resultKind == kind && !visualFrames(resultID, in: host).isEmpty }
                        returnToPage()
                        check(opened && health.latestReport?.id == reportID && storage.report?.id == scanID && health.reportExpanded &&
                              storage.selectedIDs == fileSelection && applications.selectedIDs == applicationSelection,
                              "\(sizeName)/\(page) mounted \(kind) Button action opens the correct real result and preserves report and both selections on return")
                    }
                }
            }
            check(try Data(contentsOf: data.appendingPathComponent("storage-actions.json")) == journal && mover.calls == 0 &&
                  executor.requests.count == 1 && !executor.timedOut && !device.isSampling && notifications.requestCount == 0 && notifications.deliveredCount == 0 &&
                  calendarSystem.requests == 0 && calendarNotifications.requests == 0,
                  "navigation does not rewrite file receipts, dispatch any file action, sample hardware, request permission or send an additional quit request")
        } catch { check(false, "fixture setup or mounted navigation: \(error.localizedDescription)") }
        executor.release()
        if let app { await app.health.prepareForQuit() }
        return (count, failures)
    }
    private static func historyButton(_ kind: HealthCenterResultKind, in host: NSView) -> NSObject? {
        let id = kind == .files ? "health-history-files" : "health-history-applications"
        return visualObjects(host).first { object in
            object.responds(to: NSSelectorFromString("accessibilityIdentifier")) && object.value(forKey: "accessibilityIdentifier") as? String == id &&
            object.responds(to: NSSelectorFromString("accessibilityRole")) && object.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue &&
            visualFrame(object).map { $0.width > 0 && $0.height > 0 } == true
        }
    }
    private static func historyScrollView(in host: NSView) -> NSScrollView? {
        // The production module's outer scroll view is wider than its sidebar
        // or any pinned internal review list. Do not use NSView.visibleRect,
        // which can still contain the pre-layout document extent.
        visualObjects(host).compactMap { $0 as? NSScrollView }
            .filter { $0.documentView != nil && $0.contentView.bounds.width > host.bounds.width / 2 && $0.contentView.bounds.height > 0 }
            .max { $0.contentView.bounds.width < $1.contentView.bounds.width }
    }
    private static func historyViewport(in host: NSView, window: NSWindow) -> NSRect {
        guard let scroll = historyScrollView(in: host) else { return .zero }
        let clip = scroll.contentView
        let clipFrame = window.convertToScreen(clip.convert(clip.bounds, to: nil))
        return clipFrame.intersection(window.convertToScreen(host.convert(host.bounds, to: nil))).insetBy(dx: -1, dy: -1)
    }
    private static func revealHistoryButtons(in host: NSView, window: NSWindow, label: String) async {
        guard let scroll = historyScrollView(in: host), let document = scroll.documentView else {
            print("DETAIL health record navigation \(label): real outer scroll/document missing")
            return
        }
        let frames = [HealthCenterResultKind.files, .applications].compactMap { historyButton($0, in: host).flatMap(visualFrame) }
        guard frames.count == 2 else {
            print("DETAIL health record navigation \(label): expected two actual button frames, found \(frames)")
            return
        }
        let beforeViewport = historyViewport(in: host, window: window), origin = scroll.contentView.bounds.origin
        let target = frames[0].union(frames[1])
        if !beforeViewport.contains(target) {
            let windowTarget = window.convertFromScreen(target)
            let documentTarget = document.convert(windowTarget, from: nil).insetBy(dx: -1, dy: -4)
            _ = document.scrollToVisible(documentTarget)
            scroll.reflectScrolledClipView(scroll.contentView)
            _ = await visualWait(host) {
                let visible = historyViewport(in: host, window: window)
                let current = [HealthCenterResultKind.files, .applications].compactMap { historyButton($0, in: host).flatMap(visualFrame) }
                return current.count == 2 && current.allSatisfy { abs($0.height - 28) < 1 && visible.contains($0) }
            }
        }
        let after = [HealthCenterResultKind.files, .applications].compactMap { historyButton($0, in: host).flatMap(visualFrame) }
        print("DETAIL health record navigation \(label): before=\(frames), clipBefore=\(beforeViewport), documentOriginBefore=\(origin), after=\(after), clipAfter=\(historyViewport(in: host, window: window)), documentOriginAfter=\(scroll.contentView.bounds.origin)")
    }
    /// Opt-in evidence only. These are owned-view renders of a synthetic DEBUG
    /// fixture, never desktop captures or proof of a real application exiting.
    private static func checkMountedVisualStates(exportDirectory: URL) async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ text: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") DEBUG health visual fixture: \(text)")
        }
        guard CommandLine.arguments.contains("--self-check") else {
            check(false, "requires the existing --self-check Workbench host context, not a standalone device check")
            return (count, failures)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-health-visual-\(UUID().uuidString)")
        let output = exportDirectory.appendingPathComponent("health-debug-mounted-\(UUID().uuidString)", isDirectory: true)
        let oldTheme = Palette.workbenchTheme, oldOpacity = Palette.glassOpacity, oldLight = Palette.isLight
        defer {
            Palette.workbenchTheme = oldTheme; Palette.glassOpacity = oldOpacity; Palette.isLight = oldLight
            try? FileManager.default.removeItem(at: root)
        }
        var evidence: [HealthVisualEvidence] = []
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for theme in [LauncherTheme.arWorld, .thunderCabin] {
                for (sizeName, size, pageWidth) in [("window", NSSize(width: 1120, height: 758), CGFloat(864)),
                                                   ("compact", NSSize(width: 960, height: 720), CGFloat(736)),
                                                   ("large", NSSize(width: 1728, height: 993), CGFloat(1360))] {
                    let label = theme.rawValue + "-" + sizeName
                    let directory = root.appendingPathComponent(label)
                    let clock = Date()
                    let notifications = HealthCheckNotifications()
                    let device = DeviceStatusModel(dataDirectory: directory.appendingPathComponent("Device"), notifications: notifications)
                    let executor = HealthVisualQuitGate()
                    let applications = HealthApplicationReviewModel(currentUID: 501, currentPID: 9000,
                        currentApplicationPath: directory.appendingPathComponent("Host.app").path, executor: executor, now: { clock })
                    let health = HealthCenterModel(device: device, dataDirectory: directory.appendingPathComponent("Health"), applicationReview: applications)
                    let calendarSystem = HealthVisualCalendarSystem(), calendarNotifications = HealthVisualCalendarNotifications()
                    let calendar = CalendarModel(dataDirectory: directory.appendingPathComponent("Calendar"), system: calendarSystem, notifier: calendarNotifications)
                    let ai = AIUsageModel(dataDirectory: directory.appendingPathComponent("AI"), startServices: false, notifications: HealthVisualAINotifications())
                    let owner = LauncherController(dataDirectory: directory.appendingPathComponent("Launcher"))
                    owner.configuration.settings.workbenchTheme = theme
                    owner.configuration.settings.workbenchAppearance = .dark
                    owner.configuration.settings.glassOpacity = 0.70
                    owner.configuration.settings.backgroundMotionEnabled = false
                    owner.configuration.settings.reduceMotion = true
                    owner.configurePanel(); owner.scanning = true; owner.panel.isReleasedWhenClosed = false
                    let app = WorkbenchAppModel(owner: owner, calendar: calendar, ai: ai, device: device, health: health, startServices: false)
                    let controller = WorkbenchWindowController(owner: owner, model: app, autosavesFrame: false)
                    owner.workbenchController = controller
                    defer {
                        executor.release(); app.shutdown()
                        controller.window?.orderOut(nil); controller.window?.delegate = nil
                        controller.window?.contentView = nil; controller.window?.close()
                        owner.panel?.orderOut(nil); owner.panel?.delegate = nil; owner.panel?.close()
                        owner.hotKey.unregister(); owner.bindingHotKeys.unregister(); owner.toastTask?.cancel()
                        owner.workbenchController = nil
                    }
                    do {
                        guard let window = controller.window, let host = window.contentView else { throw HealthVisualError.invalid("missing real Workbench host") }
                        app.navigate(.health); app.setWindowVisible(true); app.syncAppearance()
                        window.setContentSize(size); window.alphaValue = 1; window.ignoresMouseEvents = true; window.orderFront(nil)
                        let mounted = await visualWait(host) { visualFrames("health-workspace", in: host).contains { abs($0.width - pageWidth) < 2 } }
                        guard mounted else { throw HealthVisualError.invalid("real mounted health AX workspace missing or wrong width") }
                        check(true, "\(label) full production WorkbenchRootView mounts its real health AX workspace")

                        health.beginAssessmentAwaitingScanForChecks()
                        evidence.append(try await captureVisualState("checking", health: health, app: app, host: host, window: window,
                            size: size, pageWidth: pageWidth, theme: theme, sizeName: sizeName, executor: executor, output: output,
                            sourceAt: clock, expectedPhase: .checking, requiredTexts: ["正在体检", "取消体检", "正在读取设备状态"]))
                        check(true, "\(label) checking uses actual mounted text/geometry; DEBUG-held scan boundary, no file scan")

                        health.cancelCheck()
                        var value = sample(at: clock)
                        let bundle = directory.appendingPathComponent("Synthetic Review.app").path
                        let application = DeviceProcessApplication(bundlePath: bundle, bundleIdentifier: "local.fangcun.health-visual.synthetic",
                            name: "QA 合成应用", executablePath: bundle + "/Contents/MacOS/Synthetic")
                        value.processes = [.init(pid: 4101, name: application.name, executablePath: application.executablePath,
                            cpuPercent: 0, residentBytes: 800_000_000, threadCount: 2, sampledAt: clock,
                            startedMicroseconds: 4_101_000, parentPID: 1, ownerUID: 501, application: application)]
                        value.processReadCount = 1; value.processTotalCount = 1
                        await inject(value, into: device)
                        guard await visualWait(host, until: { applications.candidates.count == 1 }) else { throw HealthVisualError.invalid("synthetic process did not reach Health's actual device subscription") }
                        health.startAssessment(); health.showCategory(.memory)
                        guard let candidate = applications.candidates.first, applications.canSelect(candidate) else { throw HealthVisualError.invalid("isolated application identity not selectable") }
                        applications.toggle(candidate); applications.prepareConfirmation(); applications.savedWorkConfirmed = true
                        applications.executeConfirmed()
                        guard await visualWait(host, until: { executor.entered && applications.isProcessing && health.phase == .processing }) else { throw HealthVisualError.invalid("fake normal-quit gate not entered") }
                        evidence.append(try await captureVisualState("application-processing", health: health, app: app, host: host, window: window,
                            size: size, pageWidth: pageWidth, theme: theme, sizeName: sizeName, executor: executor, output: output,
                            sourceAt: clock, expectedPhase: .processing, requiredTexts: ["逐项核验并请求正常退出", "取消后续处理", "QA 合成应用"]))
                        check(true, "\(label) application processing is mounted while the fake executor is actually waiting")

                        executor.release()
                        guard await visualWait(host, until: { !applications.isProcessing && health.phase == .result }) else { throw HealthVisualError.invalid("fake result did not traverse Health's completion callback") }
                        evidence.append(try await captureVisualState("application-result", health: health, app: app, host: host, window: window,
                            size: size, pageWidth: pageWidth, theme: theme, sizeName: sizeName, executor: executor, output: output,
                            sourceAt: clock, expectedPhase: .result, requiredTexts: ["已提交应用退出请求", "已请求正常退出", "等待后续有效采样"]))
                        check(true, "\(label) mounted result reports only a fake request, never an OS exit or released bytes")
                        check(!device.isSampling && !health.storage.isScanning && health.storage.scopes.isEmpty && health.storage.receipts.isEmpty &&
                              notifications.requestCount == 0 && notifications.deliveredCount == 0 && calendarSystem.requests == 0 &&
                              calendarNotifications.requests == 0 && calendarNotifications.pending.isEmpty && app.context.settings.city == nil &&
                              !executor.timedOut && executor.requests.count == 1 && applications.requestedCount == 1,
                              "\(label) sources remain isolated: no sampler, file scan/action, notification permission or OS quit executor")
                    } catch { check(false, "\(label): \(error.localizedDescription)") }
                    executor.release(); await health.prepareForQuit()
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(evidence).write(to: output.appendingPathComponent("index.json"), options: .atomic)
            check(evidence.count == 18, "exports exactly 18 owned-view PNGs (three states, two themes, three window sizes); actual CUA is separate")
            print("DETAIL DEBUG health owned-view evidence directory=\(output.path) rendered=\(evidence.count) activationPolicy=\(NSApp.activationPolicy().rawValue)")
        } catch { check(false, "evidence output failed: \(error.localizedDescription)") }
        return (count, failures)
    }

    private static func captureVisualState(_ state: String, health: HealthCenterModel, app: WorkbenchAppModel, host: NSView, window: NSWindow,
        size: NSSize, pageWidth: CGFloat, theme: LauncherTheme, sizeName: String, executor: HealthVisualQuitGate, output: URL,
        sourceAt: Date, expectedPhase: HealthCenterPhase, requiredTexts: [String]) async throws -> HealthVisualEvidence {
        let ready = await visualWait(host) {
            let objects = visualObjects(host)
            return !objects.isEmpty && requiredTexts.allSatisfy { text in objects.contains { visualText($0).contains(text) } }
        }
        guard ready, health.phase == expectedPhase else { throw HealthVisualError.invalid("\(state) phase or actual AX text missing") }
        let viewport = window.convertToScreen(host.convert(host.bounds, to: nil)).insetBy(dx: -1, dy: -1)
        guard abs(host.bounds.width - size.width) < 1, abs(host.bounds.height - size.height) < 1,
              let workspace = visualFrames("health-workspace", in: host).first(where: { abs($0.width - pageWidth) < 2 && viewport.contains($0) }),
              requiredTexts.allSatisfy({ text in visualObjects(host).contains { object in
                  visualText(object).contains(text) && visualFrame(object).map { $0.width > 0 && $0.height > 0 && viewport.contains($0) } == true
              } }) else { throw HealthVisualError.invalid("\(state) actual AX workspace/text clipped or outside the owned host") }
        guard state == "checking" || health.resultKind == .applications,
              !executor.timedOut, !health.storage.isScanning, health.storage.receipts.isEmpty else { throw HealthVisualError.invalid("\(state) fixture source invariants changed") }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw HealthVisualError.invalid("owned view bitmap allocation failed") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var colors = Set<String>(), opaque = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 12)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 12)) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 {
                    opaque += 1; colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        guard opaque > 50, colors.count > 8, let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
            throw HealthVisualError.invalid("owned view render is empty or unvaried; no placeholder exported")
        }
        let file = state + "-" + theme.rawValue + "-" + sizeName + ".png"
        try png.write(to: output.appendingPathComponent(file), options: .atomic)
        return .init(file: file, evidenceKind: "DEBUG-mounted-own-view-fixture", notExternalCUA: true, state: state,
            theme: theme.rawValue, windowSize: [Double(size.width), Double(size.height)], pixelSize: [bitmap.pixelsWide, bitmap.pixelsHigh],
            nativeFullScreen: app.isFullScreen, phase: health.phase.rawValue, sourceAt: state == "checking" ? nil : sourceAt,
            source: state == "checking" ? "DEBUG-held assessment boundary; device sample missing; no actual scan or invented file progress" : "synthetic DeviceSnapshot through the production device subscription",
            ruleVersion: DeviceHealthRules.version, executor: "fake-normal-quit-gate; no DeviceProcessActionService", gateEntered: executor.entered,
            gateReleased: executor.released, fakeQuitRequests: executor.requests.count, osQuitRequests: 0, samplerStarted: health.device.isSampling,
            fileScanStarted: health.storage.isScanning, fileCleanupActions: health.storage.receipts.count, sourceFilesMutated: 0,
            axObjectCount: visualObjects(host).filter { $0.responds(to: NSSelectorFromString("accessibilityRole")) && $0.value(forKey: "accessibilityRole") != nil }.count,
            workspace: [Double(workspace.minX), Double(workspace.minY), Double(workspace.width), Double(workspace.height)], requiredVisibleTexts: requiredTexts,
            activationPolicy: NSApp.activationPolicy().rawValue, reviewStatus: "mounted AX and nonblank own-view render checked; manual image review still required")
    }
    private static func visualObjects(_ root: NSObject) -> [NSObject] {
        var pending = [root], seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        while let object = pending.popLast(), seen.count < 8192 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }; result.append(object)
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return result
    }
    private static func visualText(_ object: NSObject) -> String {
        ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].compactMap { property in
            object.responds(to: NSSelectorFromString(property)) ? object.value(forKey: property) as? String : nil
        }.joined(separator: " ")
    }
    private static func visualFrame(_ object: NSObject) -> NSRect? {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")), let frame = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        return frame.rectValue
    }
    private static func visualFrames(_ identifier: String, in host: NSView) -> [NSRect] {
        visualObjects(host).compactMap { object in
            guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")), object.value(forKey: "accessibilityIdentifier") as? String == identifier else { return nil }
            return visualFrame(object)
        }
    }
    private static func visualWait(_ host: NSView, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { try? await Task.sleep(for: .milliseconds(30)); host.layoutSubtreeIfNeeded(); return condition() }
            try? await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return condition()
    }

    private static func sample(at date: Date, available: UInt64 = 200_000_000_000) -> DeviceSnapshot {
        var value = DeviceSnapshot()
        value.sampledAt = date; value.performanceSampledAt = date
        value.deviceName = "Isolated fixture"; value.chipName = "Fixture CPU"
        value.memory = .init(total: 32_000_000_000, used: 31_000_000_000, available: 1_000_000_000,
                             application: 20_000_000_000, wired: 4_000_000_000, compressed: 3_000_000_000,
                             cached: 4_000_000_000, swapUsed: nil, pageIns: 0, pageOuts: 0, pressure: .normal)
        value.disk = .init(name: "Fixture volume", fileSystem: "APFS", total: 1_000_000_000_000,
                           used: 1_000_000_000_000 - available, available: available,
                           readBytesPerSecond: nil, writeBytesPerSecond: nil)
        value.thermalState = .nominal
        return value
    }
    private static func coreSample(at date: Date) -> DeviceHealthSnapshot {
        .init(memory: .init(value: .init(pressure: .normal, sustainedSeconds: 0), sampledAt: date, source: "fixture pressure"),
              storage: .init(value: .init(totalBytes: 1_000_000_000_000, availableBytes: 200_000_000_000, volumeName: "fixture"), sampledAt: date, source: "fixture capacity"),
              thermal: .init(value: .init(state: .nominal, sustainedSeconds: 0), sampledAt: date, source: "fixture thermal"))
    }
    private static func inject(_ snapshot: DeviceSnapshot, into device: DeviceStatusModel) async {
        await device.evaluateMonitoringForChecks(snapshot: snapshot, ledger: .init(), at: snapshot.sampledAt ?? Date())
        await settle()
    }
    private static func settle() async { for _ in 0..<20 { await Task.yield() } }
    private static func requiredReport(_ model: HealthCenterModel) throws -> DeviceHealthReport {
        guard let value = model.latestReport else { throw DeviceHealthPersistenceError.invalidReport }
        return try value.validated()
    }
    private static func factor(_ model: HealthCenterModel, _ factor: DeviceHealthFactor) -> DeviceHealthFactorResult? {
        model.latestReport?.factors.first { $0.factor == factor }
    }
    private static func readHistory(_ directory: URL) throws -> DeviceHealthHistory {
        try JSONDecoder().decode(DeviceHealthHistory.self, from: Data(contentsOf: directory.appendingPathComponent("health-history.json"))).validated()
    }
    private static func alteredHistory(_ history: DeviceHealthHistory, key: String, value: Any) throws -> Data {
        var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as! [String: Any]
        var reports = root["reports"] as! [[String: Any]]
        guard !reports.isEmpty else { throw DeviceHealthPersistenceError.invalidReport }
        reports[0][key] = value; root["reports"] = reports
        return try JSONSerialization.data(withJSONObject: root)
    }
    #endif
}

@MainActor private final class HealthCheckNotifications: DeviceNotificationProviding {
    var requestCount = 0
    var deliveredCount = 0
    func permission() async -> DeviceNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { requestCount += 1; return false }
    func deliver(_ event: DeviceMonitoringEvent, budget: DeviceTrafficBudget, rule: DeviceTemperatureRule) async throws { deliveredCount += 1 }
}

#if DEBUG
private final class HealthHistoryNoMove: StorageReviewFileMoving, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    private func reject() throws -> Never {
        lock.lock(); count += 1; lock.unlock()
        throw HealthVisualError.invalid("record-navigation fixture forbids file actions")
    }
    func moveToTrash(_ source: URL) throws -> URL { try reject() }
    func moveBack(_ source: URL, to destination: URL) throws { try reject() }
}
private enum HealthVisualError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
private struct HealthVisualEvidence: Encodable {
    let file: String, evidenceKind: String
    let notExternalCUA: Bool
    let state: String, theme: String
    let windowSize: [Double], pixelSize: [Int]
    let nativeFullScreen: Bool
    let phase: String
    let sourceAt: Date?
    let source: String, ruleVersion: String, executor: String
    let gateEntered: Bool, gateReleased: Bool
    let fakeQuitRequests: Int, osQuitRequests: Int
    let samplerStarted: Bool, fileScanStarted: Bool
    let fileCleanupActions: Int, sourceFilesMutated: Int, axObjectCount: Int
    let workspace: [Double], requiredVisibleTexts: [String]
    let activationPolicy: Int
    let reviewStatus: String
}
@MainActor private final class HealthVisualQuitGate: HealthApplicationQuitRequesting {
    private(set) var requests: [DeviceProcessActionRequest] = []
    private(set) var entered = false
    private(set) var released = false
    private(set) var timedOut = false
    private var continuation: CheckedContinuation<HealthApplicationQuitOutcome, Never>?
    private var timeout: Task<Void, Never>?
    func requestQuit(_ request: DeviceProcessActionRequest) async -> HealthApplicationQuitOutcome {
        requests.append(request); entered = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self, let pending = self.continuation else { return }
                self.timedOut = true; self.continuation = nil
                pending.resume(returning: .failed("DEBUG fixture gate timed out; no OS request sent"))
            }
        }
    }
    func release() {
        released = true; timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil
        pending?.resume(returning: .requested)
    }
}
@MainActor private final class HealthVisualCalendarSystem: CalendarSystemProviding {
    var requests = 0
    func access(reminders: Bool) -> CalendarAccess { .denied }
    func requestAccess(reminders: Bool) async throws -> Bool { requests += 1; return false }
    func events(in interval: DateInterval) throws -> [CalendarEventItem] { [] }
    func reminders() async throws -> [ReminderItem] { [] }
    func writableReminderCalendars() -> [ReminderCalendar] { [] }
    func saveReminder(_ item: ReminderItem, creating: Bool) throws -> ReminderItem { throw ReminderError.unavailable("DEBUG visual fixture forbids reminder writes") }
    func deleteReminder(_ item: ReminderItem) throws { throw ReminderError.unavailable("DEBUG visual fixture forbids reminder deletion") }
}
@MainActor private final class HealthVisualCalendarNotifications: ReminderNotificationProviding {
    var requests = 0
    var pending: [ReminderNotification] = []
    func access() async -> CalendarAccess { .denied }
    func requestAccess() async throws -> Bool { requests += 1; return false }
    func replacePending(_ values: [ReminderNotification]) async throws { pending = values }
}
@MainActor private final class HealthVisualAINotifications: AIQuotaNotificationProviding {
    func permission() async -> AIQuotaNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func deliver(_ event: AIQuotaAlertEvent) async throws { throw AIUsageError.invalid("DEBUG visual fixture forbids notifications") }
}
#endif
