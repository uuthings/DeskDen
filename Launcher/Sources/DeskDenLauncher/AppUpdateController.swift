import AppKit
import Combine
import Sparkle

@MainActor protocol AppUpdateEngine: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    func start() throws
    func checkForUpdates()
    func observeChanges(_ changed: @escaping @MainActor () -> Void) -> Set<AnyCancellable>
}

@MainActor private final class SparkleUpdateEngine: AppUpdateEngine {
    let controller: SPUStandardUpdaterController
    init(delegate: SPUUpdaterDelegate) {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
    }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }
    func start() throws { try controller.updater.start() }
    func checkForUpdates() { controller.updater.checkForUpdates() }
    func observeChanges(_ changed: @escaping @MainActor () -> Void) -> Set<AnyCancellable> {
        var result = Set<AnyCancellable>()
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { _ in changed() }.store(in: &result)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).sink { _ in changed() }.store(in: &result)
        controller.updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main).sink { _ in changed() }.store(in: &result)
        return result
    }
}

/// Sparkle owns its preference keys. Merely displaying settings never starts it.
@MainActor final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var canCheck = true
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status = "尚未检查更新"
    @Published private(set) var hasError = false
    private var engine: AppUpdateEngine?
    private let engineFactory: @MainActor (AppUpdateController) -> AppUpdateEngine
    private var subscriptions = Set<AnyCancellable>()
    private let defaults: UserDefaults
    private let information: [String: Any]
    private let allowsStarting: Bool
    weak var owner: LauncherController?

    init(owner: LauncherController? = nil, defaults: UserDefaults = .standard,
         information: [String: Any] = Bundle.main.infoDictionary ?? [:], allowsStarting: Bool = true,
         engineFactory: (@MainActor (AppUpdateController) -> AppUpdateEngine)? = nil) {
        self.owner = owner; self.defaults = defaults; self.information = information; self.allowsStarting = allowsStarting
        self.engineFactory = engineFactory ?? { SparkleUpdateEngine(delegate: $0) }
        super.init()
        automaticallyChecks = (defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool)
            ?? (information["SUEnableAutomaticChecks"] as? Bool ?? false)
        lastChecked = defaults.object(forKey: "SULastCheckTime") as? Date
        canCheck = Self.configurationIsValid(information)
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
    /// Called after launch. A fresh installation in manual mode does no updater work.
    func startAutomaticCheckingIfEnabled() {
        guard automaticallyChecks else { return }
        _ = startIfNeeded()
    }
    func setAutomaticallyChecks(_ enabled: Bool) {
        guard Self.configurationIsValid(information) else { return }
        if enabled {
            guard startIfNeeded() else { return }
        }
        if let engine { engine.automaticallyChecksForUpdates = enabled }
        else { defaults.set(enabled, forKey: "SUEnableAutomaticChecks") }
        automaticallyChecks = enabled
    }
    func checkForUpdates() {
        guard startIfNeeded(), let engine else { return }
        guard engine.canCheckForUpdates else { return }
        hasError = false; status = "正在检查更新"
        owner?.showWorkbench()
        engine.checkForUpdates()
    }
    private func startIfNeeded() -> Bool {
        if engine != nil { return true }
        guard allowsStarting, Self.configurationIsValid(information) else {
            if !Self.configurationIsValid(information) { hasError = true; status = "更新通道配置不完整，请使用维护者提供的安装包。" }
            return false
        }
        let value = engineFactory(self)
        do { try value.start() }
        catch { hasError = true; status = "更新服务暂不可用，请稍后重试。"; return false }
        engine = value
        if hasError { hasError = false; status = "尚未检查更新" }
        subscriptions = value.observeChanges { [weak self] in self?.syncEngine() }
        syncEngine()
        return true
    }
    private func syncEngine() {
        guard let engine else { return }
        canCheck = engine.canCheckForUpdates; automaticallyChecks = engine.automaticallyChecksForUpdates
        lastChecked = engine.lastUpdateCheckDate
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        hasError = false; status = "发现新版本 " + item.displayVersionString
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        hasError = false; status = "当前没有适用的新版本"
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        recordAbort(error)
    }
    func recordAbort(_ error: Error) {
        owner?.preparingUpdateRelaunch = false
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue { return }
        if error.domain == SUSparkleErrorDomain && error.code == SUError.installationCanceledError.rawValue {
            hasError = false; status = "已取消更新，当前版本继续使用"
            return
        }
        hasError = true; status = "未能读取更新通道，请检查网络后重试。尚未发布更新时，也会出现此提示。"
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // Sparkle's explicit Install & Relaunch action is already confirmed.
        // Native termination still runs the normal draft and async safety barriers.
        owner?.preparingUpdateRelaunch = true
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finishUpdateCycle()
    }
    func finishUpdateCycle() {
        // A cancelled/finished installer must not grant the next ordinary quit
        // the earlier Install & Relaunch consent.
        owner?.preparingUpdateRelaunch = false
    }
}
