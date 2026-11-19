import AppKit
import Combine
import Sparkle

@MainActor protocol AppUpdateEngine: AnyObject {
    var canCheckForUpdates: Bool { get }
    var sessionInProgress: Bool { get }
    func start() throws
    func checkForUpdates()
    func checkForUpdateInformation()
    func observeChanges(_ changed: @escaping @MainActor () -> Void) -> Set<AnyCancellable>
}

@MainActor private final class SparkleUpdateEngine: AppUpdateEngine {
    let updater: SPUUpdater
    private let userDriver: AppUpdateUserDriver
    init(delegate: AppUpdateController) {
        userDriver = AppUpdateUserDriver(owner: delegate)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: delegate)
    }
    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    var sessionInProgress: Bool { updater.sessionInProgress }
    func start() throws {
        // A saved Sparkle download preference must never turn a check into an
        // unattended installation. The framework still owns verification/install.
        updater.sendsSystemProfile = false
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.updateCheckInterval = AppUpdateController.checkInterval
        try updater.start()
    }
    func checkForUpdates() { updater.checkForUpdates() }
    func checkForUpdateInformation() { updater.checkForUpdateInformation() }
    func observeChanges(_ changed: @escaping @MainActor () -> Void) -> Set<AnyCancellable> {
        var result = Set<AnyCancellable>()
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { _ in changed() }.store(in: &result)
        updater.publisher(for: \.sessionInProgress).receive(on: RunLoop.main).sink { _ in changed() }.store(in: &result)
        return result
    }
}

enum AppUpdatePhase: Equatable {
    case idle, checking, available, downloading, extracting, readyToInstall, installing, upToDate, failed, cancelled
}
struct AppUpdateReleaseNote: Equatable, Codable {
    var title: String
    var detail: String?
}
struct AppUpdateRelease: Equatable, Codable {
    var build: String? = nil
    var version: String
    var publishedAt: Date?
    var notes: [AppUpdateReleaseNote]
    var downloadSize: Int64?
    var informationURL: URL?
    var informationOnly: Bool
}

/// Sparkle performs the signed-feed selection, download, archive verification
/// and installation. This object owns only presentation and user choices.
@MainActor final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let checkInterval: TimeInterval = 86400
    @Published private(set) var mode: UpdateMode
    var automaticallyChecks: Bool { mode != .manual }
    var needsUpdateChoice: Bool { allowsStarting && Self.configurationIsValid(information) && !schedule.confirmed }
    private let schedule: UpdateSchedule
    private var verifiedFeed = false
    fileprivate var verifiedCurrentResult: Bool { verifiedFeed }
    private var resolvedFeed = false
    private var cycleError: NSError?
    private var automaticDownload = false
    private var withdrawing = false
    private var pendingBuild: String?
    @Published private(set) var canCheck = true
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status = "尚未检查更新"
    @Published private(set) var hasError = false
    @Published private(set) var phase: AppUpdatePhase = .idle
    @Published private(set) var release: AppUpdateRelease?
    @Published var isChoosingUpdateMode = false
    @Published var isDialogPresented = false
    @Published private(set) var progress: Double?
    @Published private(set) var downloadedBytes: UInt64 = 0
    @Published private(set) var expectedBytes: UInt64 = 0
    @Published private(set) var canCancelUpdate = false
    @Published private(set) var canRetryInstallation = false
    private var engine: AppUpdateEngine?
    private let engineFactory: @MainActor (AppUpdateController) -> AppUpdateEngine
    private var subscriptions = Set<AnyCancellable>()
    private let defaults: UserDefaults
    private let information: [String: Any]
    private let allowsStarting: Bool
    private enum InformationCheck { case checking, found(AppUpdateRelease) }
    private var informationCheck: InformationCheck?
    private var cancellation: (() -> Void)?
    private var offerReply: ((SPUUserUpdateChoice) -> Void)?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private var retryTermination: (() -> Void)?
    private var requestedDownloadVersion: String?
    private var installationConsented = false
    private var installReplyIsResumedOffer = false
    // Sparkle 2.10: SUConstants.m and SPUSkippedUpdate.m define these three
    // keys. An initial resumed-install offer's Skip writes them, whereas the
    // later ready callback's Skip only cancels. Preserve the exact prior values
    // solely around cancellation of the resumed offer; a normal quit is not a
    // user request to skip a release. Revisit when updating the pinned SDK.
    private static let skippedPreferenceKeys = ["SUSkippedVersion", "SUSkippedMajorVersion", "SUSkippedMajorSubreleaseVersion"]
    private var skippedPreferenceSnapshot: [String: Any]?
    private var terminationCompletions: [() -> Void] = []
    private enum RetryAction { case check, download, install }
    private var retryAction: RetryAction = .check
    weak var owner: LauncherController?

    init(owner: LauncherController? = nil, defaults: UserDefaults = .standard,
         information: [String: Any] = Bundle.main.infoDictionary ?? [:], allowsStarting: Bool = true,
         observesSystemEvents: Bool? = nil, now: @escaping () -> Date = Date.init,
         engineFactory: (@MainActor (AppUpdateController) -> AppUpdateEngine)? = nil) {
        self.owner = owner; self.defaults = defaults; self.information = information; self.allowsStarting = allowsStarting
        let legacyChecks = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        schedule = UpdateSchedule(defaults: defaults, legacyMode: legacyChecks ? .notify : .manual,
                                  monitorsNetwork: observesSystemEvents ?? (engineFactory == nil), now: now)
        mode = schedule.mode
        self.engineFactory = engineFactory ?? { SparkleUpdateEngine(delegate: $0) }
        super.init()
        lastChecked = schedule.lastSuccess
        if let data = defaults.data(forKey: "DeskDenAvailableUpdate"),
           let saved = try? JSONDecoder().decode(AppUpdateRelease.self, from: data),
           let installed = information["CFBundleVersion"] as? String,
           let build = saved.build, SUStandardVersionComparator().compareVersion(installed, toVersion: build) == .orderedAscending {
            release = saved
            phase = .available
            status = "发现新版本 v" + saved.version
        }
        canCheck = allowsStarting && Self.configurationIsValid(information)
        if !canCheck { status = "当前构建尚未配置更新通道" }
    }
    static func configurationIsValid(_ information: [String: Any]) -> Bool {
        guard let text = information["SUFeedURL"] as? String, let url = URL(string: text),
              url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              let key = information["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else { return false }
        return information["SUEnableAutomaticChecks"] as? Bool == false
            && information["SUAutomaticallyUpdate"] as? Bool == false
            && information["SUAllowsAutomaticUpdates"] as? Bool == false
            && information["SUVerifyUpdateBeforeExtraction"] as? Bool == true
            && information["SURequireSignedFeed"] as? Bool == true
    }
    func startAutomaticCheckingIfEnabled() {
        guard schedule.confirmed, automaticallyChecks, startIfNeeded() else { return }
        schedule.observe { [weak self] in self?.checkAutomaticallyIfDue(reconnected: $0) }
        checkAutomaticallyIfDue()
    }

    func setMode(_ value: UpdateMode) {
        guard allowsStarting, Self.configurationIsValid(information) else { return }
        isChoosingUpdateMode = false
        schedule.select(value)
        mode = value
        if automaticDownload && value != .install {
            withdrawing = true
            cancelPreparedInstallation()
        }
        startAutomaticCheckingIfEnabled()
    }
    func setAutomaticallyChecks(_ enabled: Bool) { setMode(enabled ? .notify : .manual) }

    func checkForUpdates() {
        isDialogPresented = true
        owner?.showWorkbench()
        guard startIfNeeded(), let engine else { return }
        // Reopening an existing offer/download must not discard its callbacks.
        guard engine.canCheckForUpdates, !engine.sessionInProgress else { return }
        hasError = false; status = "正在检查更新"; phase = .checking; progress = nil
        verifiedFeed = false; resolvedFeed = false; cycleError = nil
        engine.checkForUpdates()
        syncEngine()
    }
    func showUpdateDialog() {
        if phase == .idle { checkForUpdates(); return }
        isDialogPresented = true
        owner?.showWorkbench()
    }
    func dismissDialog() { isDialogPresented = false }
    func downloadUpdate() {
        guard let release, !release.informationOnly else { return }
        retryAction = .download
        if let reply = offerReply {
            offerReply = nil; cancellation = nil; canCancelUpdate = false
            hasError = false; phase = .downloading; status = "正在下载更新"; progress = nil
            reply(.install)
        } else if canCheck {
            // Cancellation ends the Sparkle session. Revalidate the same release
            // before honoring the user's download action in a new session.
            requestedDownloadVersion = release.version
            checkForUpdates()
        }
    }
    func cancelUpdate() {
        guard let cancellation else { return }
        self.cancellation = nil; canCancelUpdate = false; requestedDownloadVersion = nil
        hasError = false; phase = release == nil ? .cancelled : .available
        status = release == nil ? "已取消检查" : "已取消下载，可稍后重新下载"
        cancellation()
    }
    func installUpdate() {
        guard let reply = installReply else {
            if let retryTermination {
                isDialogPresented = false; installationConsented = true
                owner?.preparingUpdateRelaunch = true; retryTermination()
            }
            return
        }
        installReply = nil; installationConsented = true; automaticDownload = false; retryAction = .install
        phase = .installing; status = "正在安装更新"; canCancelUpdate = false
        // The update dialog must not block the application's existing unsaved
        // draft/async termination barriers. Sparkle still requests normal quit.
        isDialogPresented = false
        reply(.install)
    }
    func retryUpdate() {
        if retryAction == .install, canRetryInstallation { installUpdate() }
        else if retryAction == .download, release != nil { downloadUpdate() }
        else { checkForUpdates() }
    }
    /// Run before a normal quit is approved. Sparkle prepares an install-on-quit
    /// after extraction. A withdrawn or unconfirmed install must finish cancelling before exit.
    func prepareForOrdinaryTermination(completion: @escaping () -> Void) {
        if withdrawing { terminationCompletions.append(completion); return }
        guard !installationConsented, !(automaticDownload && mode == .install) else { completion(); return }
        guard phase == .downloading || phase == .extracting || phase == .readyToInstall else { completion(); return }
        terminationCompletions.append(completion)
        withdrawing = true
        cancelPreparedInstallation()
    }

    private func cancelPreparedInstallation() {
        if let reply = installReply {
            installReply = nil
            if installReplyIsResumedOffer { snapshotSkippedPreferences() }
            installReplyIsResumedOffer = false
            reply(.skip)
        } else if let cancellation {
            self.cancellation = nil; canCancelUpdate = false; cancellation()
        }
        // Extraction has no public cancellation callback. Its ready callback
        // immediately cancels instead; it never grants permission to install.
    }
    func checkAutomaticallyIfDue(reconnected: Bool = false) {
        guard automaticallyChecks, let engine, informationCheck == nil, !automaticDownload,
              !withdrawing, !isDialogPresented, engine.canCheckForUpdates, !engine.sessionInProgress,
              schedule.due(reconnected: reconnected) else { return }
        phase = .checking; status = "正在后台检查更新"
        verifiedFeed = false; resolvedFeed = false; cycleError = nil
        informationCheck = .checking
        engine.checkForUpdateInformation()
        syncEngine()
    }

    func checkWhenWorkbenchOpens() { checkAutomaticallyIfDue() }

    private func startIfNeeded() -> Bool {
        if engine != nil { return true }
        guard allowsStarting, Self.configurationIsValid(information) else {
            if !Self.configurationIsValid(information) {
                hasError = true; phase = .failed; status = "更新通道配置不完整，请使用维护者提供的安装包。"
            }
            return false
        }
        let value = engineFactory(self)
        do { try value.start() }
        catch { hasError = true; phase = .failed; status = "更新服务暂不可用，请稍后重试。"; return false }
        engine = value
        if hasError { hasError = false; status = "尚未检查更新"; phase = .idle }
        subscriptions = value.observeChanges { [weak self] in self?.syncEngine() }
        syncEngine()
        return true
    }
    private func syncEngine() {
        guard let engine else { return }
        canCheck = informationCheck != nil || (engine.canCheckForUpdates && !engine.sessionInProgress)
    }
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        recordFeedVerification(appcast.signingValidationStatus == .succeeded)
    }
    func recordFeedVerification(_ verified: Bool) { verifiedFeed = verified }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        // Sparkle's signed-feed recovery can report a failed validation after
        // its recovery interval. Do not expose or install unverified content.
        guard item.signingValidationStatus == .succeeded else {
            throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue),
                          userInfo: [NSLocalizedDescriptionKey: "更新信息未通过验证，请稍后重试。"])
        }
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard item.signingValidationStatus == .succeeded else { return }
        recordVerifiedRelease(Self.release(from: item))
    }
    private func recordResolution() {
        if verifiedFeed && !resolvedFeed && informationCheck == nil {
            schedule.succeeded()
            lastChecked = schedule.lastSuccess
        }
        resolvedFeed = true
    }
    func recordVerifiedRelease(_ item: AppUpdateRelease) {
        recordResolution()
        if informationCheck != nil {
            // Sparkle reports the result before it finishes cleaning up the
            // probe. Publish it once a requested download can start a new check.
            informationCheck = .found(item)
            return
        }
        release = item
        hasError = false; status = "发现新版本 v" + item.version
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        if verifiedFeed { foundNoUpdate() }
    }
    func foundNoUpdate() {
        recordResolution()
        release = nil; offerReply = nil; cancellation = nil; canCancelUpdate = false
        hasError = false; phase = .upToDate; status = "已是最新版本"
        requestedDownloadVersion = nil
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { recordAbort(error) }
    func recordAbort(_ error: Error) {
        owner?.preparingUpdateRelaunch = false
        installationConsented = false
        let error = error as NSError
        cycleError = error
        if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue { return }
        cancellation = nil; canCancelUpdate = false; offerReply = nil; requestedDownloadVersion = nil
        installReply = nil; retryTermination = nil; canRetryInstallation = false
        if error.domain == SUSparkleErrorDomain && error.code == SUError.installationCanceledError.rawValue {
            hasError = false; phase = release == nil ? .cancelled : .available
            status = "已取消更新，当前版本继续使用"
            return
        }
        // Sparkle can deliver the same failure through the user driver and
        // then the delegate. Preserve the original operation on the second call.
        if phase != .failed {
            if phase == .downloading || phase == .extracting { retryAction = .download }
            else if phase == .installing || phase == .readyToInstall { retryAction = .install }
            else { retryAction = .check }
        }
        hasError = true; phase = .failed
        status = retryAction == .check ? "检查更新失败，请检查网络后重试。" : "更新未能完成，当前版本仍可使用，请重试。"

        // A background check never activates a window. A visible operation
        // retains its error; one deliberately put in the background stays there.
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        owner?.preparingUpdateRelaunch = installationConsented
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { cycleError = error as NSError }
        finishUpdateCycle()
    }
    private func snapshotSkippedPreferences() {
        skippedPreferenceSnapshot = Dictionary(uniqueKeysWithValues: Self.skippedPreferenceKeys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
    }
    private func restoreSkippedPreferencesIfNeeded() {
        guard let snapshot = skippedPreferenceSnapshot else { return }
        skippedPreferenceSnapshot = nil
        for key in Self.skippedPreferenceKeys {
            if let value = snapshot[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
    func finishUpdateCycle() {
        let failure = cycleError
        cycleError = nil
        let current = failure?.domain == SUSparkleErrorDomain && failure?.code == Int(SUError.noUpdateError.rawValue)
        let cancelled = withdrawing || (failure?.domain == SUSparkleErrorDomain && failure?.code == Int(SUError.installationCanceledError.rawValue))
        let success = verifiedFeed && resolvedFeed && (failure == nil || current)
        if success, !cancelled, informationCheck != nil {
            schedule.succeeded()
            lastChecked = schedule.lastSuccess
        }
        let wasAutomaticDownload = automaticDownload
        automaticDownload = false
        withdrawing = false
        if !success, !cancelled, !wasAutomaticDownload, informationCheck != nil || phase == .failed {
            let network = failure.map(Self.isNetworkFailure) == true
            schedule.failed(network: network)
            hasError = true; phase = .failed
            status = network ? "连接更新服务器失败，请检查网络后重试。" : "无法验证或读取更新信息，请稍后重试。"
        }
        restoreSkippedPreferencesIfNeeded()
        owner?.preparingUpdateRelaunch = false
        installationConsented = false
        cancellation = nil; canCancelUpdate = false
        if !terminationCompletions.isEmpty {
            installReply = nil; retryTermination = nil; canRetryInstallation = false
            phase = release == nil ? .idle : .available
            let completions = terminationCompletions; terminationCompletions.removeAll()
            completions.forEach { $0() }
        }
        let finishedInformationCheck = informationCheck
        informationCheck = nil
        syncEngine()
        if case let .found(item) = finishedInformationCheck, success {
            recordVerifiedRelease(item)
            phase = .available
            if mode == .install, !item.informationOnly {
                Task { @MainActor [weak self] in
                    guard let self, mode == .install, !withdrawing, phase == .available,
                          let engine, !engine.sessionInProgress, engine.canCheckForUpdates else { return }
                    automaticDownload = true
                    pendingBuild = item.build ?? item.version
                    verifiedFeed = false; resolvedFeed = false
                    engine.checkForUpdates()
                }
            }
        }
        if success { defaults.set(release.flatMap { try? JSONEncoder().encode($0) }, forKey: "DeskDenAvailableUpdate") }
    }

    private static func isNetworkFailure(_ error: NSError) -> Bool {
        var cause = error
        for _ in 0..<8 {
            if cause.domain == NSURLErrorDomain {
                return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                        .cannotConnectToHost, .dnsLookupFailed].contains(URLError.Code(rawValue: cause.code))
            }
            guard let next = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            cause = next
        }
        return false
    }
    func showUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation; canCancelUpdate = true
        phase = .checking; hasError = false; status = "正在检查更新"
        if withdrawing { cancelPreparedInstallation() }
    }
    func offerUpdate(_ item: AppUpdateRelease, stage: SPUUserUpdateStage = .notDownloaded,
                     userInitiated: Bool, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        release = item; cancellation = nil; canCancelUpdate = false; hasError = false
        offerReply = reply; status = "发现新版本 v" + item.version; phase = .available
        if automaticDownload {
            if pendingBuild != (item.build ?? item.version) || mode != .install || item.informationOnly { withdrawing = true }
            if stage == .installing {
                offerReply = nil
                readyToInstall(reply: reply, isResumedOffer: true)
            } else if withdrawing { offerReply = nil; reply(.dismiss) }
            else { downloadUpdate() }
            return
        }
        if stage == .installing {
            offerReply = nil; readyToInstall(reply: reply, isResumedOffer: true); return
        }
        if let requested = requestedDownloadVersion {
            requestedDownloadVersion = nil
            if requested == item.version { downloadUpdate() }
        }
        // Even critical/background offers stay in the sidebar until the user
        // opens them. The explicit action already presented its dialog.
    }
    func downloadStarted(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation; canCancelUpdate = true
        phase = .downloading; hasError = false; status = "正在下载更新"
        downloadedBytes = 0; expectedBytes = 0; progress = nil
        if withdrawing { cancelPreparedInstallation() }
    }
    func downloadExpected(_ length: UInt64) { expectedBytes = length; updateDownloadProgress() }
    func downloadReceived(_ length: UInt64) {
        let addition = downloadedBytes.addingReportingOverflow(length)
        downloadedBytes = addition.overflow ? UInt64.max : addition.partialValue
        updateDownloadProgress()
    }
    private func updateDownloadProgress() {
        progress = expectedBytes > 0 ? min(1, Double(downloadedBytes) / Double(expectedBytes)) : nil
    }
    func extractionStarted() {
        cancellation = nil; canCancelUpdate = false; phase = .extracting; progress = nil
        status = "正在验证并准备更新"
    }
    func extractionProgress(_ value: Double) { progress = value.isFinite ? min(1, max(0, value)) : nil }
    func readyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void, isResumedOffer: Bool = false) {
        cancellation = nil; canCancelUpdate = false; progress = nil
        if withdrawing || !terminationCompletions.isEmpty {
            if isResumedOffer { snapshotSkippedPreferences() }
            reply(.skip); return
        }
        installReplyIsResumedOffer = isResumedOffer
        installReply = reply; phase = .readyToInstall; status = automaticDownload && mode == .install ? "更新已就绪，将在退出时安装" : "更新已下载，等待你确认安装"
    }
    func installing(retry: @escaping () -> Void, applicationTerminated: Bool) {
        phase = .installing; status = "正在等待 DeskDen 完成保存并重新启动"
        retryTermination = applicationTerminated ? nil : retry
        canRetryInstallation = !applicationTerminated
    }
    func installationDismissed() {
        offerReply = nil; installReply = nil; cancellation = nil; canCancelUpdate = false
        retryTermination = nil; canRetryInstallation = false
    }
    static func release(from item: SUAppcastItem) -> AppUpdateRelease {
        .init(build: item.versionString, version: item.displayVersionString, publishedAt: item.date,
              notes: releaseNotes(item.itemDescription ?? "", format: item.itemDescriptionFormat),
              downloadSize: item.contentLength > 0 && item.contentLength <= UInt64(Int64.max) ? Int64(item.contentLength) : nil,
              informationURL: allowedInformationURL(item.infoURL), informationOnly: item.isInformationOnlyUpdate)
    }
    static func allowedInformationURL(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.query == nil, url.fragment == nil,
              !url.absoluteString.contains("%"), !url.pathComponents.contains(".."), let host = url.host?.lowercased() else { return nil }
        let permitted = (host == "github.com" && (url.path == "/uuthings/DeskDen/releases" || url.path.hasPrefix("/uuthings/DeskDen/releases/")))
            || ((host == "uuthings.com" || host == "www.uuthings.com") && (url.path == "/products/deskden" || url.path.hasPrefix("/products/deskden/")))
        return permitted ? url : nil
    }
    static func releaseNotes(_ text: String, format: String?) -> [AppUpdateReleaseNote] {
        // Bounded plain text only: no WebView, HTML resource loading or script
        // execution. Keep substantive release/compatibility text intact.
        var value = String(text.prefix(100_000)).replacingOccurrences(of: "\r\n", with: "\n")
        if format != "plain-text" {
            value = value.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
            value = value.replacingOccurrences(of: "(?i)</(?:p|div|h[1-6])\\s*>", with: "\n\n", options: .regularExpression)
            value = value.replacingOccurrences(of: "(?i)<li(?:\\s[^>]*)?>", with: "\n• ", options: .regularExpression)
            value = value.replacingOccurrences(of: "(?i)</li\\s*>|<br\\s*/?>", with: "\n", options: .regularExpression)
            value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            for (entity, decoded) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
                value = value.replacingOccurrences(of: entity, with: decoded)
            }
        }
        var result: [AppUpdateReleaseNote] = [], block: [String] = []
        func flush() {
            guard let first = block.first else { return }
            let title = first.replacingOccurrences(of: "^(?:#{1,6}\\s+|[-*•]\\s+|[0-9]+[.)]\\s+)", with: "", options: .regularExpression)
            if block.count > 1, title.count <= 60 {
                result.append(.init(title: title, detail: block.dropFirst().joined(separator: "\n")))
            } else {
                result.append(.init(title: ([title] + block.dropFirst()).joined(separator: "\n"), detail: nil))
            }
            block.removeAll()
        }
        for line in value.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { flush(); continue }
            let isListItem = trimmed.range(of: "^(?:[-*•]\\s+|[0-9]+[.)]\\s+)", options: .regularExpression) != nil
            let isHeading = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) != nil
            if isListItem || isHeading { flush() }
            block.append(trimmed)
        }
        flush()
        return result
    }
}

@MainActor private final class AppUpdateUserDriver: NSObject, SPUUserDriver {
    weak var owner: AppUpdateController?
    init(owner: AppUpdateController) { self.owner = owner }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false,
                                        automaticUpdateDownloading: NSNumber(value: false), sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { owner?.showUpdateCheck(cancellation: cancellation) }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner, appcastItem.signingValidationStatus == .succeeded else { reply(.dismiss); return }
        owner.offerUpdate(AppUpdateController.release(from: appcastItem), stage: state.stage, userInitiated: state.userInitiated, reply: reply)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if owner?.verifiedCurrentResult == true { owner?.foundNoUpdate() }
        else { owner?.recordAbort(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue))) }
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { owner?.recordAbort(error); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { owner?.downloadStarted(cancellation: cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { owner?.downloadExpected(expectedContentLength) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { owner?.downloadReceived(length) }
    func showDownloadDidStartExtractingUpdate() { owner?.extractionStarted() }
    func showExtractionReceivedProgress(_ progress: Double) { owner?.extractionProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner else { reply(.skip); return }; owner.readyToInstall(reply: reply)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        owner?.installing(retry: retryTerminatingApplication, applicationTerminated: applicationTerminated)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { owner?.installationDismissed() }
    func showUpdateInFocus() { owner?.showUpdateDialog() }
}
