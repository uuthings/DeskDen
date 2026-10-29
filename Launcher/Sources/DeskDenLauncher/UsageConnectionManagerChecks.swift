import AppKit
import Foundation
import LauncherCore

/// Exercises production save orchestration with disposable files and in-memory
/// service/credential stores. No account discovery, browser or Keychain access.
@MainActor enum UsageConnectionManagerChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") connection manager: \(label)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-connection-check-\(UUID())")
        var fixtures: [UsageConnectionFixture] = []
        defer { for fixture in fixtures { fixture.app.shutdown() }; try? FileManager.default.removeItem(at: root) }
        do {
            let fixture = try UsageConnectionFixture(directory: root.appendingPathComponent("normal"))
            fixtures.append(fixture)
            let category = UsageCardCategory(id: "fixture-paid", title: "Paid tools")
            check(fixture.app.usageAppearance.replaceCategories(UsageCardCategory.defaults + [category]), "a shared custom category can be saved")
            let manager = UsageConnectionManager()
            manager.prepare(app: fixture.app); manager.selectService(.deepseek)
            manager.draft.name = "API fixture"
            manager.draft.appearance.categoryID = category.id
            manager.draft.appearance.icon = .brand(.deepseek)
            manager.draft.secret = "not-a-real-api-key"
            manager.save(app: fixture.app)
            check(await settle(manager), "API validation and save finish")
            guard let source = fixture.api.sources.first else { throw APIBalanceFailure.invalidResponse }
            let key = UsagePresentationSourceID.api(source.id)
            let requestCount = await fixture.balanceClient.requestCount(), storedKeys = await fixture.credentials.count()
            check(manager.error == nil && fixture.api.sources.count == 1 && requestCount == 1 && storedKeys == 1
                  && source.credentialID != nil && fixture.api.state(for: source.id).snapshot != nil,
                  "a new API connection publishes its verified balance and one opaque credential")
            let display = fixture.app.usageAppearance.appearance(for: key)
            check(display.displayName == "API fixture" && display.categoryID == category.id && display.icon == .brand(.deepseek)
                  && manager.selectedSourceID == key && manager.draft.secret.isEmpty && !manager.hasChanges,
                  "saving retains the chosen category and brand and clears the secret draft")
            let restoredDisplay = UsagePresentationModel(dataDirectory: fixture.appearanceDirectory)
            let restoredAPI = APIBalanceModel(dataDirectory: fixture.apiDirectory, startServices: false,
                                             client: fixture.balanceClient, credentials: fixture.credentials)
            check(restoredDisplay.appearance(for: key) == display && restoredAPI.sources == fixture.api.sources,
                  "connection identity, category and brand survive reload")
            restoredAPI.shutdown()
            let persisted = try String(contentsOf: fixture.apiDirectory.appendingPathComponent("api-balances.json"), encoding: .utf8)
                + String(contentsOf: fixture.appearanceFile, encoding: .utf8)
            check(!persisted.contains("not-a-real-api-key"), "neither display settings nor service metadata contain the plaintext key")

            manager.draft.name = "Renamed API fixture"; manager.save(app: fixture.app)
            check(await settle(manager), "metadata-only API edit finishes")
            let requestsAfterRename = await fixture.balanceClient.requestCount(), keysAfterRename = await fixture.credentials.count()
            check(manager.error == nil && fixture.api.sources.count == 1 && fixture.api.sources.first?.id == source.id
                  && fixture.api.sources.first?.credentialID == source.credentialID && requestsAfterRename == requestCount
                  && keysAfterRename == storedKeys && fixture.app.usageAppearance.appearance(for: key).displayName == "Renamed API fixture",
                  "renaming keeps the same connection and credential without another request")

            let invalid = UsageConnectionManager(); invalid.selectService(.deepseek)
            invalid.draft.secret = "not-another-real-key"; invalid.draft.appearance.categoryID = "deleted-category"
            invalid.save(app: fixture.app)
            let requestsAfterInvalid = await fixture.balanceClient.requestCount()
            check(!invalid.busy && invalid.error != nil && requestsAfterInvalid == requestsAfterRename && fixture.api.sources.count == 1,
                  "an invalid category is rejected before service validation")

            let trafficKey = UsagePresentationSourceID.service(fixture.traffic.id)
            let trafficEditor = UsageConnectionManager(sourceID: trafficKey); trafficEditor.prepare(app: fixture.app)
            trafficEditor.draft.name = "Renamed traffic fixture"; trafficEditor.draft.minimumHours = "2"
            trafficEditor.draft.maximumHours = "12"; trafficEditor.draft.appearance.icon = .symbol("network")
            trafficEditor.save(app: fixture.app)
            check(await settle(trafficEditor), "existing traffic settings save finishes")
            let trafficRequests = await fixture.trafficClient.requestCount()
            check(trafficEditor.error == nil && fixture.provider.sources.count == 1
                  && fixture.provider.sources.first?.id == fixture.traffic.id
                  && fixture.provider.sources.first?.resourceID == fixture.traffic.resourceID
                  && fixture.provider.sources.first?.refreshPolicy.minimumInterval == 7200
                  && fixture.provider.sources.first?.refreshPolicy.maximumInterval == 43200 && trafficRequests == 0,
                  "editing traffic name and frequency retains its order and performs no credential query")

            let codexKey = UsagePresentationSourceID.ai(.codex)
            let originalCodex = UsageCardAppearance(displayName: "My subscription", icon: .brand(.chatgpt), categoryID: category.id)
            check(fixture.app.usageAppearance.saveAppearance(originalCodex, for: codexKey), "existing subscription display is prepared")
            let duplicate = UsageConnectionManager(); duplicate.selectService(.codex)
            duplicate.draft.name = "Must not overwrite"; duplicate.draft.declaredPlan = .plus
            duplicate.save(app: fixture.app)
            check(duplicate.error != nil && !duplicate.busy && duplicate.existingSubscriptionID == codexKey
                  && fixture.app.usageAppearance.appearance(for: codexKey) == originalCodex
                  && fixture.ai.configuration(for: .codex).declaredPlan == .pro,
                  "adding a built-in subscription cannot overwrite its existing display or plan")
            duplicate.connectSubscription(app: fixture.app)
            check(duplicate.busy && duplicate.selectedSourceID == codexKey,
                  "one click connects the unique local source directly from the new form")
            check(await settle(duplicate), "local connection resolves without a second sync action")
            check(fixture.app.usageAppearance.appearance(for: codexKey) == originalCodex
                  && fixture.ai.configuration(for: .codex).declaredPlan == .pro
                  && duplicate.draft.name == "Must not overwrite" && duplicate.draft.declaredPlan == .plus,
                  "connecting preserves saved card metadata and keeps explicit appearance edits as a draft")

            let rollback = UsageConnectionManager(sourceID: codexKey); rollback.prepare(app: fixture.app)
            let switched = UsageConnectionManager(); switched.selectService(.claude)
            switched.draft.declaredPlan = .plus; switched.selectService(.codex)
            switched.connectSubscription(app: fixture.app)
            check(await settle(switched), "switching subscription service resolves its connection")
            check(switched.draft.declaredPlan == .pro && fixture.ai.configuration(for: .codex).declaredPlan == .pro,
                  "a different service's optional plan cannot clear the existing subscription plan")
            rollback.draft.declaredPlan = .plus; rollback.draft.name = "Unsaved name"
            let displayBytes = try Data(contentsOf: fixture.appearanceFile)
            try FileManager.default.removeItem(at: fixture.appearanceFile)
            try FileManager.default.createDirectory(at: fixture.appearanceFile, withIntermediateDirectories: false)
            rollback.save(app: fixture.app)
            check(await settle(rollback), "subscription save with display-storage failure finishes")
            check(rollback.error != nil && fixture.ai.configuration(for: .codex).declaredPlan == .pro
                  && fixture.app.usageAppearance.appearance(for: codexKey) == originalCodex && rollback.hasChanges,
                  "display-storage failure restores the previous plan and preserves the edit draft")
            try FileManager.default.removeItem(at: fixture.appearanceFile)
            try displayBytes.write(to: fixture.appearanceFile)

            let partial = try UsageConnectionFixture(directory: root.appendingPathComponent("partial"))
            fixtures.append(partial)
            try FileManager.default.createDirectory(at: partial.appearanceFile, withIntermediateDirectories: true)
            let retry = UsageConnectionManager(); retry.selectService(.deepseek)
            retry.draft.name = "Retry fixture"; retry.draft.secret = "not-a-retry-key"; retry.draft.appearance.icon = .brand(.deepseek)
            retry.save(app: partial.app)
            check(await settle(retry), "partial API save finishes")
            guard let partialSource = partial.api.sources.first else { throw APIBalanceFailure.invalidResponse }
            let partialKey = UsagePresentationSourceID.api(partialSource.id)
            check(retry.error != nil && partial.api.sources.count == 1 && retry.selectedSourceID == partialKey && retry.draft.secret.isEmpty,
                  "a verified connection is retained when only its display settings fail")
            try FileManager.default.removeItem(at: partial.appearanceFile)
            retry.save(app: partial.app)
            check(await settle(retry), "partial-save retry finishes")
            let partialRequests = await partial.balanceClient.requestCount(), partialKeys = await partial.credentials.count()
            check(retry.error == nil && partial.api.sources.count == 1 && partial.api.sources.first?.id == partialSource.id
                  && partialRequests == 1 && partialKeys == 1 && partial.app.usageAppearance.appearance(for: partialKey).icon == .brand(.deepseek),
                  "retry repairs display metadata without another connection, key or validation request")

            let protected = try UsageConnectionFixture(directory: root.appendingPathComponent("protected"), corruptAppearance: true)
            fixtures.append(protected)
            let blocked = UsageConnectionManager(); blocked.selectService(.deepseek); blocked.draft.secret = "not-a-protected-key"
            blocked.save(app: protected.app)
            let protectedRequests = await protected.balanceClient.requestCount(), protectedKeys = await protected.credentials.count()
            check(blocked.error != nil && !blocked.busy && protected.app.usageAppearance.storageError != nil
                  && protected.api.sources.isEmpty && protectedRequests == 0 && protectedKeys == 0,
                  "known corrupt display storage blocks connection writes before contacting a service")
        } catch { check(false, "fixture setup or save failed: \(error.localizedDescription)") }
        for fixture in fixtures { try? await fixture.ai.prepareForQuit(); try? await fixture.provider.prepareForQuit(); try? await fixture.api.prepareForQuit() }
        print("Connection manager checks: \(count) checks, \(failures) failures")
        return (count, failures)
    }

    private static func settle(_ manager: UsageConnectionManager) async -> Bool {
        for _ in 0..<200 where manager.busy { try? await Task.sleep(for: .milliseconds(10)) }
        return !manager.busy
    }
}

@MainActor private struct UsageConnectionFixture {
    let owner: LauncherController
    let app: WorkbenchAppModel
    let ai: AIUsageModel
    let provider: ProviderUsageModel
    let api: APIBalanceModel
    let balanceClient: ConnectionBalanceClient
    let trafficClient: ConnectionTrafficClient
    let credentials: ConnectionCredentials
    let traffic: ProviderUsageConfiguration
    let apiDirectory: URL
    let appearanceDirectory: URL
    var appearanceFile: URL { appearanceDirectory.appendingPathComponent("display-preferences.json") }

    init(directory: URL, corruptAppearance: Bool = false) throws {
        let owner = LauncherController(dataDirectory: directory.appendingPathComponent("Launcher")); owner.scanning = true
        let aiDirectory = directory.appendingPathComponent("AI"), sourceDirectory = aiDirectory.appendingPathComponent("AIUsage")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sources = AIProvider.allCases.map { provider in
            AIUsageSourceConfiguration(provider: provider, enabled: false,
                sessionsPath: directory.appendingPathComponent("disabled-" + provider.rawValue).path,
                declaredPlan: provider == .codex ? .pro : nil)
        }
        try JSONEncoder().encode(sources).write(to: sourceDirectory.appendingPathComponent("sources.json"))
        let ai = AIUsageModel(dataDirectory: aiDirectory, startServices: false, notifications: ConnectionAINotifications(),
                              claudeSettingsDirectory: directory.appendingPathComponent("isolated-claude"))
        let balanceClient = ConnectionBalanceClient(), trafficClient = ConnectionTrafficClient(), credentials = ConnectionCredentials()
        let traffic = ProviderUsageConfiguration(kind: .iproyal, name: "Traffic fixture", resourceID: "1001")
        var document = ProviderUsageDocument(); document.sources = [traffic]
        let providerDirectory = directory.appendingPathComponent("Provider")
        try ProviderUsageStore(url: providerDirectory.appendingPathComponent("provider-usage.json")).save(document)
        let provider = ProviderUsageModel(dataDirectory: providerDirectory, startServices: false, client: trafficClient, credentials: credentials)
        let apiDirectory = directory.appendingPathComponent("APIBalance")
        let api = APIBalanceModel(dataDirectory: apiDirectory, startServices: false, client: balanceClient, credentials: credentials)
        let appearanceDirectory = owner.store.url.deletingLastPathComponent().appendingPathComponent("Workbench/UsagePresentation")
        if corruptAppearance {
            try FileManager.default.createDirectory(at: appearanceDirectory, withIntermediateDirectories: true)
            try Data("invalid display fixture".utf8).write(to: appearanceDirectory.appendingPathComponent("display-preferences.json"))
        }
        let calendar = CalendarModel(dataDirectory: directory.appendingPathComponent("Calendar"), system: ConnectionCalendar(), notifier: ConnectionNotifications())
        let cleaning = SpaceCleaningModel(dataDirectory: directory.appendingPathComponent("Cleaning"), homeDirectory: directory)
        self.owner = owner; self.ai = ai; self.provider = provider; self.api = api; self.traffic = traffic
        self.balanceClient = balanceClient; self.trafficClient = trafficClient; self.credentials = credentials
        self.apiDirectory = apiDirectory; self.appearanceDirectory = appearanceDirectory
        app = WorkbenchAppModel(owner: owner, calendar: calendar, ai: ai, cleaning: cleaning,
                                providerUsage: provider, apiBalance: api, startServices: false)
    }
}

private actor ConnectionCredentials: APIBalanceCredentialStoring, ProviderUsageCredentialStoring {
    private var values: [UUID: String] = [:]
    func read(id: UUID) -> String? { values[id] }
    func write(_ secret: String, id: UUID) { values[id] = secret }
    func remove(id: UUID) { values[id] = nil }
    func count() -> Int { values.count }
}
private actor ConnectionBalanceClient: APIBalanceQuerying {
    private var requests = 0
    func requestCount() -> Int { requests }
    func fetch(configuration: APIBalanceConfiguration, secret: String) -> APIBalanceSnapshot {
        requests += 1
        return .init(sourceID: configuration.id, isAvailable: true,
                     balances: [.init(currency: "CNY", totalBalance: "12.30", grantedBalance: "2.00", toppedUpBalance: "10.30")])
    }
}
private actor ConnectionTrafficClient: ProviderUsageQuerying {
    private var requests = 0
    func requestCount() -> Int { requests }
    func fetch(configuration: ProviderUsageConfiguration, secret: String) throws -> ProviderUsageSnapshot {
        requests += 1; throw ProviderUsageFailure.unavailable("Unexpected fixture query")
    }
}
@MainActor private final class ConnectionCalendar: CalendarSystemProviding {
    func access(reminders: Bool) -> CalendarAccess { .notDetermined }
    func requestAccess(reminders: Bool) async throws -> Bool { false }
    func events(in interval: DateInterval) throws -> [CalendarEventItem] { [] }
    func reminders() async throws -> [ReminderItem] { [] }
    func writableReminderCalendars() -> [ReminderCalendar] { [] }
    func saveReminder(_ item: ReminderItem, creating: Bool) throws -> ReminderItem { throw ReminderError.unavailable("Isolated fixture") }
    func deleteReminder(_ item: ReminderItem) throws { throw ReminderError.unavailable("Isolated fixture") }
}
@MainActor private final class ConnectionNotifications: ReminderNotificationProviding {
    func access() async -> CalendarAccess { .notDetermined }
    func requestAccess() async throws -> Bool { false }
    func replacePending(_ notifications: [ReminderNotification]) async throws { }
}
@MainActor private final class ConnectionAINotifications: AIQuotaNotificationProviding {
    func permission() async -> AIQuotaNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func deliver(_ event: AIQuotaAlertEvent) async throws { throw AIUsageError.invalid("Isolated fixture") }
}
