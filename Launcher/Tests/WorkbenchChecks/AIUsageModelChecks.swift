import AppKit
import Foundation
import LauncherCore

@MainActor private final class FixtureAIQuotaNotifications: AIQuotaNotificationProviding {
    var status: AIQuotaNotificationPermission = .authorized
    var grantsPermission = true
    var permissionRequests = 0
    var deliveryAttempts = 0
    var failingDeliveries = 0
    var delivered: [AIQuotaAlertEvent] = []
    func permission() async -> AIQuotaNotificationPermission { status }
    func requestPermission() async throws -> Bool {
        permissionRequests += 1; status = grantsPermission ? .authorized : .denied; return grantsPermission
    }
    func deliver(_ event: AIQuotaAlertEvent) async throws {
        deliveryAttempts += 1
        if failingDeliveries > 0 { failingDeliveries -= 1; throw AIUsageError.invalid("fixture delivery failure") }
        delivered.append(event)
    }
}

private actor FixtureClaudeSubscription: ClaudeSubscriptionProviding {
    var reading: ClaudeSubscriptionReading
    var loginReading: ClaudeSubscriptionReading
    var fetchCount = 0
    var loginCount = 0
    var refreshCount = 0
    var delay: Duration
    var loginDelay: Duration
    init(_ reading: ClaudeSubscriptionReading = .unavailable("fixture: no current official quota"),
         login: ClaudeSubscriptionReading = .failed("fixture: login cancelled"), delay: Duration = .zero, loginDelay: Duration = .zero) {
        self.reading = reading; loginReading = login; self.delay = delay; self.loginDelay = loginDelay
    }
    func setReading(_ value: ClaudeSubscriptionReading) { reading = value }
    func counts() -> (fetch: Int, login: Int, refresh: Int) { (fetchCount, loginCount, refreshCount) }
    func refresh() async -> ClaudeSubscriptionReading { refreshCount += 1; return await fetch() }
    func fetch() async -> ClaudeSubscriptionReading {
        fetchCount += 1
        try? await Task.sleep(for: delay)
        return reading
    }
    func login() async -> ClaudeSubscriptionReading {
        loginCount += 1
        try? await Task.sleep(for: loginDelay)
        return loginReading
    }
}

@main struct AIUsageModelChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("deskden-ai-model-checks-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var failures = 0, checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") \(message)") }
        func fixture(_ name: String) throws -> URL {
            let base = root.appendingPathComponent(name), directory = base.appendingPathComponent("AIUsage")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let sources = AIProvider.allCases.map { AIUsageSourceConfiguration(provider: $0, enabled: false, sessionsPath: base.appendingPathComponent("unused-sessions-" + $0.rawValue).path) }
            try JSONEncoder().encode(sources).write(to: directory.appendingPathComponent("sources.json"))
            return base
        }
        func file(_ base: URL, _ name: String) -> URL { base.appendingPathComponent("AIUsage").appendingPathComponent(name) }
        func refresh(_ model: AIUsageModel) async {
            model.refresh()
            for _ in 0..<500 {
                if !model.isRefreshing && !model.isRefreshingClaudeSubscription { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let bad = Data("{ damaged fixture".utf8)
        let price = try AITokenPrice(provider: .codex, model: "fixture-model", inputPerMillion: 1, outputPerMillion: 2, cacheReadPerMillion: 0.1, cacheWritePerMillion: 0)
        let now = Date(), reset = now.addingTimeInterval(86_400)

        let membershipBase = try fixture("weekly-only-membership")
        let membershipSessions = membershipBase.appendingPathComponent("metering-fixture")
        try fm.createDirectory(at: membershipSessions, withIntermediateDirectories: true)
        let membershipMetadata: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now),
            "payload": ["type": "token_count", "rate_limits": ["plan_type": "pro", "primary": NSNull(),
                "secondary": ["used_percent": 32, "window_minutes": 10_080, "resets_at": reset.timeIntervalSince1970]]]]
        var membershipData = try JSONSerialization.data(withJSONObject: membershipMetadata); membershipData.append(10)
        try membershipData.write(to: membershipSessions.appendingPathComponent("metering.jsonl"))
        var membershipSources = AIProvider.allCases.map { AIUsageSourceConfiguration(provider: $0, enabled: false, sessionsPath: membershipBase.appendingPathComponent("unused-" + $0.rawValue).path) }
        membershipSources[0].enabled = true; membershipSources[0].sessionsPath = membershipSessions.path
        try JSONEncoder().encode(membershipSources).write(to: file(membershipBase, "sources.json"))
        let membershipModel = AIUsageModel(dataDirectory: membershipBase, startServices: false, notifications: FixtureAIQuotaNotifications(), claudeSubscription: FixtureClaudeSubscription())
        await refresh(membershipModel)
        let membershipSummary = membershipModel.providerSummaries.first { $0.provider == .codex }
        check(membershipSummary?.snapshot?.accountPlan == .pro && membershipSummary?.shortWindow == nil && membershipSummary?.snapshot?.availableWindows.map(\.durationMinutes) == [10_080],
              "source-provided Pro membership and a weekly-only quota survive the real local metering reader")
        let membershipReload = AIUsageModel(dataDirectory: membershipBase, startServices: false, notifications: FixtureAIQuotaNotifications(), claudeSubscription: FixtureClaudeSubscription())
        check(membershipReload.quotaHistory.last?.accountPlan == .pro && membershipReload.quotaHistory.last?.shortWindow == nil,
              "quota history persists actual membership metadata without manufacturing a five-hour window")
        check(membershipModel.setDeclaredPlan(.plus, provider: .codex), "membership preference saves independently of metering")
        await refresh(membershipModel)
        let preferredSummary = membershipModel.providerSummaries.first { $0.provider == .codex }
        check(preferredSummary?.effectiveAccountPlan == .pro && preferredSummary?.accountPlanIsDeclared == false && membershipModel.quotaHistory.allSatisfy { $0.accountPlan == .pro },
              "real source membership wins over a declared preference without changing historical quota metadata")
        check(membershipModel.saveManual(provider: .codex, shortPercent: "99", weekPercent: "", observedAt: now.addingTimeInterval(30), shortReset: reset, weekReset: reset),
              "manual fixture can precede reconnecting an automatic subscription")
        await refresh(membershipModel)
        let codexConnection = await membershipModel.connectLocalSubscription(provider: .codex)
        check(codexConnection.isReady && membershipModel.providerSummaries.first(where: { $0.provider == .codex })?.snapshot?.source == .localSession
              && membershipModel.configuration(for: .codex).manualSnapshot == nil && membershipModel.quotaHistory.contains { $0.source == .manual },
              "one-click Codex waits for a fresh automatic reading, clears its manual override and retains historical manual observations")

        let syncBase = try fixture("claude-statusline-sync")
        let settingsDirectory = syncBase.appendingPathComponent("Claude settings")
        try fm.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        let originalSettings = try JSONSerialization.data(withJSONObject: ["permissions": ["allow": ["fixture-only"]], "theme": "fixture-theme"])
        try originalSettings.write(to: settingsURL)
        let executable = syncBase.appendingPathComponent("Fangcun with ' space")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let syncModel = AIUsageModel(dataDirectory: syncBase, startServices: false, notifications: FixtureAIQuotaNotifications(),
                                     claudeSettingsDirectory: settingsDirectory, statusLineExecutableURL: executable, claudeSubscription: FixtureClaudeSubscription())
        check(syncModel.enableClaudeQuotaSync(), "explicit quota sync installs into an isolated Claude settings fixture")
        await refresh(syncModel)
        let installedSettings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        let command = (installedSettings["statusLine"] as? [String: Any])?["command"] as? String ?? ""
        check(installedSettings["theme"] as? String == "fixture-theme" && (installedSettings["permissions"] as? [String: Any])?["allow"] as? [String] == ["fixture-only"] && command.contains("'\"'\"'") && command.contains(ClaudeQuotaStatusLineHost.argument),
              "sync preserves unrelated settings and safely quotes executable and output paths")
        let waitingSummary = syncModel.providerSummaries.first { $0.provider == .claude }
        check(waitingSummary?.state == .unavailable && waitingSummary?.snapshot == nil && syncModel.claudeQuotaSyncMessage != nil,
              "configured sync waits for a real Claude response without fabricating a connected quota or read failure")
        check(syncModel.enableClaudeQuotaSync(), "re-enabling the same status-line command is idempotent")
        var decoratedSettings = installedSettings
        var decoratedLine = decoratedSettings["statusLine"] as! [String: Any]; decoratedLine["padding"] = 3
        decoratedSettings["statusLine"] = decoratedLine
        try JSONSerialization.data(withJSONObject: decoratedSettings).write(to: settingsURL)
        let movedDirectory = syncBase.appendingPathComponent("Moved app")
        try fm.createDirectory(at: movedDirectory, withIntermediateDirectories: true)
        let movedExecutable = movedDirectory.appendingPathComponent(executable.lastPathComponent)
        try fm.copyItem(at: executable, to: movedExecutable)
        let migratedOutput = syncBase.appendingPathComponent("New preview profile/AIUsage/claude-quota.json")
        _ = try ClaudeQuotaSyncInstaller.install(settingsDirectory: settingsDirectory, executableURL: movedExecutable, quotaURL: migratedOutput)
        let migratedSettings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        let migratedLine = migratedSettings["statusLine"] as! [String: Any], migratedCommand = migratedLine["command"] as! String
        check(migratedLine["padding"] as? Int == 3 && migratedSettings["theme"] as? String == "fixture-theme"
              && migratedCommand != command && ClaudeQuotaSyncInstaller.ownedCommand(migratedCommand, matchingExecutable: executable),
              "a recognized Fangcun connection migrates moved app and preview destinations while retaining existing status-line options")
        check(!ClaudeQuotaSyncInstaller.ownedCommand(command + " && fixture-extra-command", matchingExecutable: executable)
              && !ClaudeQuotaSyncInstaller.ownedCommand("printf '" + ClaudeQuotaStatusLineHost.argument + "'", matchingExecutable: executable),
              "own-command recognition rejects extra shell commands and a third-party script merely mentioning the flag")
        let outputURL = file(syncBase, "claude-quota.json")
        let payload = try JSONSerialization.data(withJSONObject: ["rate_limits": ["five_hour": ["used_percentage": 13, "resets_at": reset.timeIntervalSince1970],
            "seven_day": ["used_percentage": 27, "resets_at": reset.timeIntervalSince1970]],
            "context_window": ["used_percentage": 99], "prompt": "DISCARDED_FIXTURE_SENTINEL", "credential": "DISCARDED_FIXTURE_SENTINEL"])
        let rendered = try ClaudeQuotaStatusLineHost.consume(payload, outputURL: outputURL, now: now)
        let sanitized = try Data(contentsOf: outputURL), sanitizedText = String(decoding: sanitized, as: UTF8.self)
        check(rendered == "5h: 13% · 7d: 27%" && !sanitizedText.contains("SENTINEL") && !sanitizedText.contains("context_window") && !sanitizedText.contains("credential"),
              "native status-line host retains only documented quota windows and never context, prompt or credential fields")
        check(syncModel.setDeclaredPlan(.max, provider: .claude), "Claude membership can be explicitly marked as a display preference")
        await refresh(syncModel)
        let syncedSummary = syncModel.providerSummaries.first { $0.provider == .claude }
        check(syncedSummary?.state == .ready && syncedSummary?.snapshot?.source == .claudeStatusLine && syncedSummary?.effectiveAccountPlan == .max && syncedSummary?.accountPlanIsDeclared == true && syncedSummary?.snapshot?.accountPlan == nil && syncModel.quotaHistory.allSatisfy { $0.accountPlan == nil },
              "live status-line fixture reaches quota summary while user-declared membership remains outside history")
        let unavailable = try ClaudeQuotaStatusLineHost.consume(Data("{\"rate_limits\":{}}".utf8), outputURL: outputURL, now: now)
        let afterUnavailable = try Data(contentsOf: outputURL)
        check(unavailable == "额度暂不可用" && sanitized == afterUnavailable, "missing official windows preserve the last real snapshot instead of writing zero or erasing history")
        syncModel.removeQuotaFile(for: .claude)
        check(syncModel.configuration(for: .claude).quotaPath == nil && syncModel.claudeQuotaSyncMessage == nil,
              "removing the quota file connection also clears the obsolete sync-success notice")
        let existingStatus = try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "fixture-existing-command"], "theme": "fixture-theme"])
        try existingStatus.write(to: settingsURL)
        check(!syncModel.enableClaudeQuotaSync(), "a pre-existing different Claude status line is never replaced")
        let retainedStatus = try Data(contentsOf: settingsURL)
        check(existingStatus == retainedStatus && syncModel.errorMessage?.contains("已有状态栏") == true,
              "status-line conflict preserves exact settings bytes and explains the manual alternative")
        let rollbackDirectory = syncBase.appendingPathComponent("rollback-settings")
        try fm.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        let rollbackURL = rollbackDirectory.appendingPathComponent("settings.json")
        try originalSettings.write(to: rollbackURL)
        let receipt = try ClaudeQuotaSyncInstaller.install(settingsDirectory: rollbackDirectory, executableURL: executable, quotaURL: outputURL)
        try receipt.rollback()
        let rolledBack = try Data(contentsOf: rollbackURL)
        check(rolledBack == originalSettings, "a failed source save can roll back only the exact status-line settings written by the installer")
        let linkedSettingsDirectory = syncBase.appendingPathComponent("dangling-settings")
        try fm.createDirectory(at: linkedSettingsDirectory, withIntermediateDirectories: true)
        let linkedSettings = linkedSettingsDirectory.appendingPathComponent("settings.json")
        try fm.createSymbolicLink(at: linkedSettings, withDestinationURL: syncBase.appendingPathComponent("missing-target.json"))
        do {
            _ = try ClaudeQuotaSyncInstaller.install(settingsDirectory: linkedSettingsDirectory, executableURL: executable, quotaURL: outputURL)
            check(false, "quota setup refuses a dangling settings symlink instead of replacing it")
        } catch { check(true, "quota setup refuses a dangling settings symlink instead of replacing it") }
        let oversized = Data(repeating: 32, count: ClaudeQuotaStatusLineHost.maximumInputBytes + 1)
        do { try ClaudeQuotaStatusLineHost.consume(oversized, outputURL: outputURL, now: now); check(false, "oversized status-line payload is rejected") }
        catch { check(true, "oversized status-line payload is rejected") }
        let symlinkDirectory = syncBase.appendingPathComponent("symlink-output")
        try fm.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
        let symlinkURL = symlinkDirectory.appendingPathComponent("claude-quota.json")
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: outputURL)
        do { try ClaudeQuotaStatusLineHost.consume(payload, outputURL: symlinkURL, now: now); check(false, "status-line host refuses a symlink output") }
        catch { check(true, "status-line host refuses a symlink output") }

        func connectionFixture(_ name: String, service: FixtureClaudeSubscription) throws -> (AIUsageModel, URL, URL) {
            let base = try fixture(name), settings = base.appendingPathComponent("Claude config")
            try fm.createDirectory(at: settings, withIntermediateDirectories: true)
            return (AIUsageModel(dataDirectory: base, startServices: false, notifications: FixtureAIQuotaNotifications(),
                                 claudeSettingsDirectory: settings, statusLineExecutableURL: executable,
                                 claudeSubscription: service), base, settings)
        }
        let apiKeyService = FixtureClaudeSubscription(.loginRequired("当前 Claude Code 使用 API 计费登录，请连接会员账号。"))
        let (apiKeyModel, apiKeyBase, apiKeySettings) = try connectionFixture("api-key-needs-membership", service: apiKeyService)
        let apiKeyBefore = try Data(contentsOf: file(apiKeyBase, "sources.json"))
        let apiKeyResult = await apiKeyModel.connectLocalSubscription(provider: .claude)
        if case .failed = apiKeyResult { check(true, "API-key authentication reports a membership-login requirement instead of directory authorization or indefinite waiting") }
        else { check(false, "API-key authentication reports a membership-login requirement instead of directory authorization or indefinite waiting") }
        let apiKeyAfter = try Data(contentsOf: file(apiKeyBase, "sources.json"))
        check(apiKeyModel.claudeSubscriptionNeedsLogin && apiKeyBefore == apiKeyAfter
              && !fm.fileExists(atPath: apiKeySettings.appendingPathComponent("settings.json").path),
              "diagnosing API-key authentication preserves source and Claude settings without creating a session directory")
        let initialServiceCounts = await apiKeyService.counts()
        check(initialServiceCounts.fetch == 1 && initialServiceCounts.login == 0 && initialServiceCounts.refresh == 1,
              "explicit subscription checks request fresh quota without starting interactive account login")
        let failedLogin = await apiKeyModel.connectClaudeSubscriptionAccount()
        let loginServiceCounts = await apiKeyService.counts()
        check(!failedLogin.isReady && loginServiceCounts.login == 1 && !apiKeyModel.configuration(for: .claude).enabled,
              "explicit failed account login is reported honestly and does not enable an unconnected source")

        let actualQuota = AIQuotaSnapshot(provider: .claude, observedAt: now, source: .claudeCLI,
            shortWindow: try .init(usedPercent: 13, durationMinutes: 300, resetsAt: reset),
            weeklyWindow: try .init(usedPercent: 27, durationMinutes: 10_080, resetsAt: reset), accountPlan: .pro)
        let readyService = FixtureClaudeSubscription(.ready(actualQuota), login: .ready(actualQuota))
        let (readyModel, readyBase, readySettings) = try connectionFixture("official-cli-ready", service: readyService)
        let readySettingsURL = readySettings.appendingPathComponent("settings.json")
        try existingStatus.write(to: readySettingsURL)
        let readyResult = await readyModel.connectLocalSubscription(provider: .claude)
        await refresh(readyModel)
        let readySummary = readyModel.providerSummaries.first { $0.provider == .claude }
        let preservedSettings = try Data(contentsOf: readySettingsURL)
        check(readyResult.isReady && readySummary?.state == .ready && readySummary?.snapshot == actualQuota
              && readyModel.configuration(for: .claude).quotaPath == nil && preservedSettings == existingStatus,
              "official CLI quota connects without local conversation history and preserves a third-party status line")
        let storedQuota = try JSONDecoder().decode([AIQuotaSnapshot].self, from: Data(contentsOf: file(readyBase, "quota-history.json")))
        check(storedQuota.contains(actualQuota) && readySummary?.effectiveAccountPlan == .pro,
              "real five-hour and weekly windows with membership persist through the existing quota history")

        check(readyModel.saveManual(provider: .claude, shortPercent: "44", weekPercent: "", observedAt: now.addingTimeInterval(30),
                                    shortReset: reset, weekReset: reset), "an explicit Claude manual reading can coexist with an automatic source")
        await refresh(readyModel)
        check(readyModel.providerSummaries.first { $0.provider == .claude }?.snapshot?.source == .manual,
              "an older cached official response cannot erase a newer explicit manual reading")
        let reconnectedActual = await readyModel.connectLocalSubscription(provider: .claude)
        check(reconnectedActual.isReady && readyModel.configuration(for: .claude).manualSnapshot == nil,
              "explicit Claude reconnect clears the manual override and restores the verified official reading")

        await readyService.setReading(.failed("fixture: official service temporarily unavailable"))
        let failedQuery = await readyModel.connectLocalSubscription(provider: .claude)
        await refresh(readyModel)
        let failedSummary = readyModel.providerSummaries.first { $0.provider == .claude }
        check(!failedQuery.isReady && failedSummary?.state == .error && failedSummary?.snapshot == actualQuota
              && failedSummary?.detail == "fixture: official service temporarily unavailable"
              && readyModel.subscriptionConnectionResults[.claude]?.isReady == false,
              "query failure retains the last real quota while neither a local refresh nor a cached window hides the error")
        let failedReload = AIUsageModel(dataDirectory: readyBase, startServices: false, notifications: FixtureAIQuotaNotifications(),
            claudeSubscription: FixtureClaudeSubscription(.failed("fixture: source still unavailable")))
        await refresh(failedReload)
        check(failedReload.providerSummaries.first { $0.provider == .claude }?.snapshot == actualQuota
              && failedReload.providerSummaries.first { $0.provider == .claude }?.state == .error,
              "restart restores the last official reading without reviving a cleared manual override when the source is unavailable")
        await readyService.setReading(.loginRequired("fixture: membership login expired"))
        await refresh(readyModel)
        check(readyModel.claudeSubscriptionNeedsLogin && readyModel.providerSummaries.first { $0.provider == .claude }?.detail == "fixture: membership login expired"
              && readyModel.providerSummaries.first { $0.provider == .claude }?.snapshot == actualQuota,
              "expired membership keeps the useful last reading and a durable login action")
        let loginResult = await readyModel.connectClaudeSubscriptionAccount()
        check(loginResult.isReady && !readyModel.claudeSubscriptionNeedsLogin,
              "explicit account login accepts a verified official quota and clears the login requirement")
        check(readyModel.setEnabled(false, provider: .claude), "a connected Claude source can be disconnected")
        let disconnectedCounts = await readyService.counts()
        await refresh(readyModel)
        let afterDisconnectedCounts = await readyService.counts()
        check(disconnectedCounts.fetch == afterDisconnectedCounts.fetch
              && readyModel.providerSummaries.first { $0.provider == .claude }?.state == .disconnected,
              "a disconnected source stops official quota queries while preserving history")

        let singleQuota = AIQuotaSnapshot(provider: .claude, observedAt: now, source: .claudeCLI,
            shortWindow: nil, weeklyWindow: try .init(usedPercent: 19, durationMinutes: 10_080, resetsAt: reset))
        let (singleModel, _, _) = try connectionFixture("official-cli-single-window", service: FixtureClaudeSubscription(.ready(singleQuota)))
        let singleResult = await singleModel.connectLocalSubscription(provider: .claude)
        check(singleResult.isReady && singleModel.providerSummaries.first { $0.provider == .claude }?.shortWindow == nil
              && singleModel.quotaHistory.allSatisfy { $0.shortWindow == nil },
              "a weekly-only official response remains useful without manufacturing a five-hour quota")

        var staleQuota = actualQuota; staleQuota.observedAt = now.addingTimeInterval(-1_800)
        let (staleModel, _, _) = try connectionFixture("official-cli-stale-result", service: FixtureClaudeSubscription(.ready(staleQuota)))
        let staleResult = await staleModel.connectLocalSubscription(provider: .claude)
        if case .failed = staleResult { check(true, "an expired official reading fails explicit connection instead of waiting indefinitely") }
        else { check(false, "an expired official reading fails explicit connection instead of waiting indefinitely") }

        let slowService = FixtureClaudeSubscription(.ready(actualQuota), delay: .milliseconds(350))
        let (slowModel, _, _) = try connectionFixture("official-cli-independent-refresh", service: slowService)
        check(slowModel.setEnabled(true, provider: .claude), "a slow official source can start an independent quota query")
        for _ in 0..<20 {
            if !slowModel.isRefreshing { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let slowCounts = await slowService.counts()
        check(!slowModel.isRefreshing && slowModel.isRefreshingClaudeSubscription && slowModel.lastRefreshed != nil && slowCounts.refresh == 0,
              "slow Claude quota requests do not block local token and other-provider refreshes")
        slowModel.cancelClaudeSubscriptionAccountConnection()
        check(slowModel.isRefreshingClaudeSubscription, "account-login cancellation does not cancel an unrelated background quota query")
        check(slowModel.setEnabled(false, provider: .claude), "disconnect cancels an in-flight official quota query")
        try? await Task.sleep(for: .milliseconds(400))
        check(!slowModel.isRefreshingClaudeSubscription && slowModel.quotaHistory.isEmpty,
              "a cancelled official response cannot reconnect a disabled source or add a late quota")

        let cancelledService = FixtureClaudeSubscription(.ready(actualQuota), delay: .milliseconds(350))
        let (cancelledModel, _, _) = try connectionFixture("official-cli-cancelled-action", service: cancelledService)
        let cancelledAction = Task { await cancelledModel.connectLocalSubscription(provider: .claude) }
        try? await Task.sleep(for: .milliseconds(20))
        cancelledAction.cancel()
        let cancelledResult = await cancelledAction.value
        check(!cancelledResult.isReady && !cancelledModel.isRefreshingClaudeSubscription && cancelledModel.quotaHistory.isEmpty,
              "cancelling a connect action cancels its query and clears loading without retaining a late result")
        var cancelledLoginQuota = actualQuota
        cancelledLoginQuota.observedAt = now.addingTimeInterval(20)
        cancelledLoginQuota.shortWindow = try .init(usedPercent: 89, durationMinutes: 300, resetsAt: reset)
        let cancellableLoginService = FixtureClaudeSubscription(.ready(actualQuota), login: .ready(cancelledLoginQuota), loginDelay: .seconds(10))
        let (cancellableLoginModel, _, _) = try connectionFixture("official-cli-cancel-account-login", service: cancellableLoginService)
        _ = await cancellableLoginModel.connectLocalSubscription(provider: .claude)
        let accountAction = Task { await cancellableLoginModel.connectClaudeSubscriptionAccount() }
        for _ in 0..<100 {
            if cancellableLoginModel.isConnectingClaudeSubscriptionAccount { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        check(cancellableLoginModel.isConnectingClaudeSubscriptionAccount, "interactive membership login publishes a cancellable state while waiting")
        cancellableLoginModel.cancelClaudeSubscriptionAccountConnection()
        check(!cancellableLoginModel.isConnectingClaudeSubscriptionAccount && !cancellableLoginModel.isRefreshingClaudeSubscription,
              "explicit membership cancellation immediately clears the login and loading states")
        let cancelledAccountResult = await accountAction.value
        check(!cancelledAccountResult.isReady && cancellableLoginModel.configuration(for: .claude).enabled
              && cancellableLoginModel.providerSummaries.first { $0.provider == .claude }?.snapshot == actualQuota
              && !cancellableLoginModel.quotaHistory.contains(cancelledLoginQuota),
              "cancelled membership login preserves the connected source and previous quota and rejects its late result")
        let afterCancelledLogin = await cancellableLoginModel.connectLocalSubscription(provider: .claude)
        check(afterCancelledLogin.isReady && !cancellableLoginModel.isConnectingClaudeSubscriptionAccount,
              "a cancelled membership flow releases its connection lock for a later explicit retry")

        let quitService = FixtureClaudeSubscription(.ready(actualQuota), delay: .milliseconds(350))
        let (quitModel, _, _) = try connectionFixture("official-cli-quit-cleanup", service: quitService)
        _ = quitModel.setEnabled(true, provider: .claude)
        try await quitModel.prepareForQuit()
        check(!quitModel.isRefreshingClaudeSubscription && quitModel.quotaHistory.isEmpty,
              "application quit cancels the independent Claude task before flushing history")

        let invalidDirectoryBefore = try Data(contentsOf: file(apiKeyBase, "sources.json"))
        check(!apiKeyModel.useLocalSubscriptionDirectory(file(apiKeyBase, "sources.json"), provider: .claude),
              "directory recovery still rejects a regular file")
        let invalidDirectoryAfter = try Data(contentsOf: file(apiKeyBase, "sources.json"))
        check(invalidDirectoryBefore == invalidDirectoryAfter, "invalid directory recovery preserves the saved source")

        let manualBase = try fixture("manual-with-automatic-reading-disabled")
        let trapSessions = manualBase.appendingPathComponent("disabled-session-trap")
        try fm.createDirectory(at: trapSessions, withIntermediateDirectories: true)
        let trapQuotaURL = manualBase.appendingPathComponent("disabled-automatic-quota.json")
        let trapSnapshot = AIQuotaSnapshot(provider: .codex, observedAt: now.addingTimeInterval(60), source: .manual,
                                          shortWindow: try AIQuotaWindow(usedPercent: 99, durationMinutes: 300, resetsAt: reset), weeklyWindow: nil)
        try AIQuotaImport.encode(trapSnapshot).write(to: trapQuotaURL)
        let trapMetadata: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now),
            "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 777, "output_tokens": 111]],
                        "rate_limits": ["primary": ["used_percent": 98, "window_minutes": 300, "resets_at": reset.timeIntervalSince1970]]]]
        var trapData = try JSONSerialization.data(withJSONObject: trapMetadata); trapData.append(10)
        try trapData.write(to: trapSessions.appendingPathComponent("must-not-be-scanned.jsonl"))
        var manualSources = AIProvider.allCases.map { AIUsageSourceConfiguration(provider: $0, enabled: false, sessionsPath: manualBase.appendingPathComponent("unused-" + $0.rawValue).path) }
        manualSources[0].sessionsPath = trapSessions.path; manualSources[0].quotaPath = trapQuotaURL.path
        try JSONEncoder().encode(manualSources).write(to: file(manualBase, "sources.json"))
        let retainedQuota = AIQuotaSnapshot(provider: .codex, observedAt: now.addingTimeInterval(-1_200), source: .localSession,
                                          shortWindow: try AIQuotaWindow(usedPercent: 5, durationMinutes: 300, resetsAt: reset), weeklyWindow: nil)
        try JSONEncoder().encode([retainedQuota]).write(to: file(manualBase, "quota-history.json"))
        let manualModel = AIUsageModel(dataDirectory: manualBase, startServices: false, notifications: FixtureAIQuotaNotifications(), claudeSubscription: FixtureClaudeSubscription())
        check(manualModel.saveManual(provider: .codex, shortPercent: "12", weekPercent: "34", observedAt: now, shortReset: reset, weekReset: reset, note: "isolated manual reading"),
              "manual quota can save while automatic reading is disconnected")
        await refresh(manualModel)
        let manualConfig = manualModel.configuration(for: .codex), manualSummary = manualModel.providerSummaries.first { $0.provider == .codex }
        check(!manualConfig.enabled && manualConfig.sessionsPath == trapSessions.path && manualConfig.quotaPath == trapQuotaURL.path && manualConfig.manualNote == "isolated manual reading",
              "manual save preserves disabled automatic reading, both automatic paths and its explicit note")
        check(manualSummary?.state == .ready && manualSummary?.snapshot?.source == .manual && manualSummary?.shortWindow?.usedPercent == 12 && manualSummary?.weeklyWindow?.usedPercent == 34 && manualSummary?.detail.contains("自动读取已关闭") == true,
              "disconnected automatic sources still display fresh manual windows and explicitly report automatic reading off")
        check(manualModel.records.isEmpty && manualModel.coverage[.codex]?.enabled == false && manualModel.coverage[.codex]?.sourceAvailable == false && manualModel.coverage[.codex]?.scannedFiles == 0 && manualModel.coverage[.codex]?.parsedRecords == 0,
              "disabled readers ignore populated Token and newer quota trap files without claiming a directory connection")
        check(manualModel.quotaHistory.contains(retainedQuota) && manualModel.quotaHistory.contains { $0.source == .manual && $0.shortWindow?.usedPercent == 12 },
              "manual-only refresh adds its marked snapshot while preserving existing automatic quota history")
        let manualReload = AIUsageModel(dataDirectory: manualBase, startServices: false, notifications: FixtureAIQuotaNotifications(), claudeSubscription: FixtureClaudeSubscription())
        await refresh(manualReload)
        check(!manualReload.configuration(for: .codex).enabled && manualReload.configuration(for: .codex).sessionsPath == trapSessions.path && manualReload.configuration(for: .codex).quotaPath == trapQuotaURL.path && manualReload.providerSummaries.first(where: { $0.provider == .codex })?.shortWindow?.usedPercent == 12 && manualReload.records.isEmpty && manualReload.quotaHistory.contains(retainedQuota),
              "restart restores manual quota and retained history without reconnecting or reading either automatic trap")
        _ = manualReload.saveManual(provider: .codex, shortPercent: "7", weekPercent: "", observedAt: now.addingTimeInterval(-1_800), shortReset: reset, weekReset: reset)
        await refresh(manualReload)
        check(manualReload.providerSummaries.first(where: { $0.provider == .codex })?.state == .stale && manualReload.providerSummaries.first(where: { $0.provider == .codex })?.snapshot?.observedAt == now.addingTimeInterval(-1_800) && !manualReload.configuration(for: .codex).enabled,
              "manual-only display keeps the supplied observation time and marks an old reading stale")
        let oneTimeURL = manualBase.appendingPathComponent("one-time-import.json")
        let oneTime = AIQuotaSnapshot(provider: .codex, observedAt: now, source: .manual,
                                     shortWindow: try AIQuotaWindow(usedPercent: 36, durationMinutes: 300, resetsAt: reset), weeklyWindow: nil)
        try AIQuotaImport.encode(oneTime).write(to: oneTimeURL)
        check(manualReload.reviewQuotaImport(at: oneTimeURL) && manualReload.confirmConnection(), "a single imported quota can be confirmed independently of automatic reading")
        await refresh(manualReload)
        check(!manualReload.configuration(for: .codex).enabled && manualReload.configuration(for: .codex).sessionsPath == trapSessions.path && manualReload.configuration(for: .codex).quotaPath == trapQuotaURL.path && manualReload.providerSummaries.first(where: { $0.provider == .codex })?.snapshot?.source == .imported && manualReload.providerSummaries.first(where: { $0.provider == .codex })?.shortWindow?.usedPercent == 36 && manualReload.records.isEmpty,
              "single import preserves disconnected automatic paths and displays only its explicit imported snapshot")
        check(manualReload.quotaHistory.contains(retainedQuota) && manualReload.quotaHistory.contains { $0.source == .manual && $0.shortWindow?.usedPercent == 12 } && manualReload.quotaHistory.contains { $0.source == .imported && $0.shortWindow?.usedPercent == 36 },
              "single import retains earlier automatic and manual quota-history provenance")
        let activeManualBase = try fixture("manual-with-automatic-reading-enabled")
        let activeSessions = activeManualBase.appendingPathComponent("explicit-missing-sessions")
        var activeSources = AIProvider.allCases.map { AIUsageSourceConfiguration(provider: $0, enabled: false, sessionsPath: activeSessions.path) }
        activeSources[0].enabled = true
        try JSONEncoder().encode(activeSources).write(to: file(activeManualBase, "sources.json"))
        let activeManual = AIUsageModel(dataDirectory: activeManualBase, startServices: false, notifications: FixtureAIQuotaNotifications(), claudeSubscription: FixtureClaudeSubscription())
        _ = activeManual.saveManual(provider: .codex, shortPercent: "22", weekPercent: "", observedAt: now, shortReset: reset, weekReset: reset)
        await refresh(activeManual)
        check(activeManual.configuration(for: .codex).enabled && activeManual.configuration(for: .codex).sessionsPath == activeSessions.path && activeManual.providerSummaries.first(where: { $0.provider == .codex })?.shortWindow?.usedPercent == 22 && activeManual.coverage[.codex]?.sourceAvailable == false,
              "saving manual quota preserves an enabled source without pretending its missing automatic directory is connected")
        _ = activeManual.reviewQuotaImport(at: oneTimeURL)
        _ = activeManual.setEnabled(false, provider: .codex)
        check(activeManual.confirmConnection() && !activeManual.configuration(for: .codex).enabled,
              "confirming a pending single import preserves the current automatic setting instead of restoring its preview-time value")

        let historyBase = try fixture("history")
        try bad.write(to: file(historyBase, "quota-history.json"))
        let historyModel = AIUsageModel(dataDirectory: historyBase, startServices: false, claudeSubscription: FixtureClaudeSubscription())
        check(Set(historyModel.storageReadErrors.keys) == ["quota-history.json"], "history load error protects only history file")
        await refresh(historyModel)
        check(!historyModel.isRefreshing, "refresh completes while history storage is protected")
        check(try Data(contentsOf: file(historyBase, "quota-history.json")) == bad, "automatic refresh preserves corrupt history bytes")
        check(historyModel.savePrice(price), "history protection does not block healthy price writes")
        check(historyModel.saveManual(provider: .codex, shortPercent: "20", weekPercent: "", observedAt: now, shortReset: reset, weekReset: reset), "history protection allows explicit healthy source changes")
        await refresh(historyModel)
        check(try Data(contentsOf: file(historyBase, "quota-history.json")) == bad, "source refresh cannot overwrite protected history")
        check(historyModel.providerSummaries.first(where: { $0.provider == .codex })?.shortWindow?.usedPercent == 20, "fresh source quota remains available despite history protection")
        let backup = file(historyBase, "quota-history-preserved.json")
        try fm.moveItem(at: file(historyBase, "quota-history.json"), to: backup)
        await refresh(historyModel)
        check(!fm.fileExists(atPath: file(historyBase, "quota-history.json").path), "moving protected file does not bypass current-session write protection")
        let restarted = AIUsageModel(dataDirectory: historyBase, startServices: false, claudeSubscription: FixtureClaudeSubscription())
        await refresh(restarted)
        check(restarted.storageReadErrors.isEmpty && fm.fileExists(atPath: file(historyBase, "quota-history.json").path), "explicit move and model restart safely create new history")
        check(try Data(contentsOf: backup) == bad, "recovery leaves original backup untouched")

        let sourceBase = try fixture("sources")
        try bad.write(to: file(sourceBase, "sources.json"))
        let sourceModel = AIUsageModel(dataDirectory: sourceBase, startServices: false, claudeSubscription: FixtureClaudeSubscription())
        check(Set(sourceModel.storageReadErrors.keys) == ["sources.json"], "source load error protects only source file")
        check(sourceModel.configurations.allSatisfy { !$0.enabled }, "damaged opt-in settings never enable default session readers")
        sourceModel.setEnabled(true, provider: .codex)
        check(!sourceModel.configuration(for: .codex).enabled, "protected source mutation does not change in-memory state")
        check(!sourceModel.saveManual(provider: .codex, shortPercent: "20", weekPercent: "", observedAt: now, shortReset: reset, weekReset: reset), "protected sources reject manual quota persistence")
        await refresh(sourceModel)
        check(sourceModel.providerSummaries.allSatisfy { $0.state == .error }, "damaged source settings stay visibly erroneous after refresh")
        check(try Data(contentsOf: file(sourceBase, "sources.json")) == bad, "manual source writes preserve corrupt original bytes")
        check(sourceModel.savePrice(price), "source protection does not block healthy model price writes")

        let priceBase = try fixture("prices")
        try bad.write(to: file(priceBase, "model-prices.json"))
        let priceModel = AIUsageModel(dataDirectory: priceBase, startServices: false, claudeSubscription: FixtureClaudeSubscription())
        check(Set(priceModel.storageReadErrors.keys) == ["model-prices.json"], "price load error protects only price file")
        check(!priceModel.savePrice(price) && priceModel.prices.isEmpty, "protected price writes report failure without mutating state")
        priceModel.removePrice(price.id)
        check(try Data(contentsOf: file(priceBase, "model-prices.json")) == bad, "price deletion preserves corrupt original bytes")
        check(priceModel.errorMessage?.contains("model-prices.json") == true, "write error identifies protected file and recovery instructions")
        check(priceModel.saveManual(provider: .codex, shortPercent: "21", weekPercent: "", observedAt: now, shortReset: reset, weekReset: reset), "price protection does not block healthy source writes")
        await refresh(priceModel)
        check(fm.fileExists(atPath: file(priceBase, "quota-history.json").path), "price protection does not block healthy automatic history persistence")

        let invalidBase = try fixture("semantic-invalid")
        var invalidPrice = price; invalidPrice.inputPerMillion = -1
        try JSONEncoder().encode([invalidPrice]).write(to: file(invalidBase, "model-prices.json"))
        var invalidWindow = try AIQuotaWindow(usedPercent: 20, durationMinutes: 300, resetsAt: reset); invalidWindow.usedPercent = 200
        let invalidSnapshot = AIQuotaSnapshot(provider: .codex, observedAt: now, source: .manual, shortWindow: invalidWindow, weeklyWindow: nil)
        try JSONEncoder().encode([invalidSnapshot]).write(to: file(invalidBase, "quota-history.json"))
        let invalidModel = AIUsageModel(dataDirectory: invalidBase, startServices: false, claudeSubscription: FixtureClaudeSubscription())
        check(Set(invalidModel.storageReadErrors.keys) == ["model-prices.json", "quota-history.json"], "decodable but invalid rates and prices are write protected")
        check(invalidModel.errorMessage != nil && !invalidModel.storageRecoveryInstructions.isEmpty, "load errors retain explicit user-visible recovery guidance")
        let freshBase = try fixture("fresh")
        let freshModel = AIUsageModel(dataDirectory: freshBase, startServices: false, claudeSubscription: FixtureClaudeSubscription())
        check(freshModel.storageReadErrors.isEmpty, "absent history and prices are valid fresh state")
        check(freshModel.savePrice(price), "fresh model price writes remain available")

        let notificationBase = try fixture("notifications")
        let notificationService = FixtureAIQuotaNotifications()
        notificationService.status = .notDetermined
        let notificationModel = AIUsageModel(dataDirectory: notificationBase, startServices: false, notifications: notificationService, claudeSubscription: FixtureClaudeSubscription())
        await refresh(notificationModel)
        check(notificationService.permissionRequests == 0, "automatic refresh never requests notification permission")
        check(notificationModel.saveManual(provider: .codex, shortPercent: "80", weekPercent: "", observedAt: now, shortReset: reset, weekReset: reset), "quota fixture saves before reminder activation")
        await refresh(notificationModel)
        var enabledRule = AIQuotaAlertRule(); enabledRule.enabled = true
        let savedRule = await notificationModel.saveAlertRule(enabledRule)
        check(savedRule && notificationService.permissionRequests == 1, "explicit reminder save requests notification permission once")
        check(notificationService.delivered.count == 1 && notificationService.delivered.first?.level == .warning, "fresh threshold crossing sends real notification through delivery service")
        await refresh(notificationModel)
        check(notificationService.delivered.count == 1, "repeated refresh suppresses already delivered threshold")
        let notificationRestart = AIUsageModel(dataDirectory: notificationBase, startServices: false, notifications: notificationService, claudeSubscription: FixtureClaudeSubscription())
        await refresh(notificationRestart)
        check(notificationService.delivered.count == 1, "successful delivery deduplication survives model restart")
        check(notificationRestart.saveManual(provider: .codex, shortPercent: "95", weekPercent: "", observedAt: now, shortReset: reset, weekReset: reset), "same window can receive a newer high-severity reading")
        await refresh(notificationRestart)
        check(notificationService.delivered.count == 2 && notificationService.delivered.last?.level == .critical, "higher threshold sends once within the same reset window")
        notificationRestart.setEnabled(false, provider: .codex)
        await refresh(notificationRestart)
        check(notificationService.delivered.count == 2, "disconnecting automatic reading cannot redeliver an already acknowledged manual quota window")

        let retryBase = try fixture("notification-retry")
        let retryService = FixtureAIQuotaNotifications(); retryService.failingDeliveries = 1
        let retryModel = AIUsageModel(dataDirectory: retryBase, startServices: false, notifications: retryService, claudeSubscription: FixtureClaudeSubscription())
        _ = retryModel.saveManual(provider: .codex, shortPercent: "85", weekPercent: "", observedAt: now, shortReset: reset, weekReset: reset)
        await refresh(retryModel)
        let retryRuleSaved = await retryModel.saveAlertRule(enabledRule)
        check(retryRuleSaved && retryService.deliveryAttempts == 1 && retryModel.alertConfiguration.state.deliveries.isEmpty, "failed notification delivery does not consume deduplication state")
        await refresh(retryModel)
        check(retryService.deliveryAttempts == 2 && retryService.delivered.count == 1, "next refresh retries an unsuccessful notification")
        await refresh(retryModel)
        check(retryService.deliveryAttempts == 2, "successful retry stops subsequent duplicate deliveries")

        let deniedBase = try fixture("notification-denied")
        let deniedService = FixtureAIQuotaNotifications(); deniedService.status = .notDetermined; deniedService.grantsPermission = false
        let deniedModel = AIUsageModel(dataDirectory: deniedBase, startServices: false, notifications: deniedService, claudeSubscription: FixtureClaudeSubscription())
        let deniedSaved = await deniedModel.saveAlertRule(enabledRule)
        check(deniedSaved && deniedModel.alertRule.enabled && deniedModel.notificationPermission == .denied, "denied system permission preserves the user's explicit saved rule")
        await refresh(deniedModel)
        check(deniedService.permissionRequests == 1 && deniedService.deliveryAttempts == 0, "denied permission is not requested again on refresh")

        let ledgerBase = try fixture("ledger")
        let sessions = ledgerBase.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let enabledSources = AIProvider.allCases.map { AIUsageSourceConfiguration(provider: $0, enabled: $0 == .codex, sessionsPath: sessions.path) }
        try JSONEncoder().encode(enabledSources).write(to: file(ledgerBase, "sources.json"))
        let timestamp = ISO8601DateFormatter().string(from: now)
        let metadata: [String: Any] = ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 200, "output_tokens": 25, "cached_input_tokens": 50]], "private_prompt": "fixture-secret-body"]]
        var meteringData = try JSONSerialization.data(withJSONObject: metadata); meteringData.append(10)
        try meteringData.write(to: sessions.appendingPathComponent("private-project-name.jsonl"))
        let ledgerModel = AIUsageModel(dataDirectory: ledgerBase, startServices: false, notifications: FixtureAIQuotaNotifications(), claudeSubscription: FixtureClaudeSubscription())
        await refresh(ledgerModel)
        check(ledgerModel.records.count == 1 && ledgerModel.todayTokens == 225, "scanner records disjoint input output and cache metering")
        check(ledgerModel.coverage[.codex]?.scannedFiles == 1 && ledgerModel.coverage[.codex]?.parsedRecords == 1, "coverage reports actual scanned files and parsed records")
        let ledgerBytes = try Data(contentsOf: file(ledgerBase, "token-ledger.json"))
        let ledgerText = String(decoding: ledgerBytes, as: UTF8.self)
        check(!ledgerText.contains("fixture-secret-body") && !ledgerText.contains("private-project-name") && !ledgerText.contains(sessions.path), "durable ledger excludes conversation body and source filenames or paths")
        _ = ledgerModel.setEnabled(false, provider: .codex)
        await refresh(ledgerModel)
        check(ledgerModel.todayTokens == 0 && ledgerModel.filteredRecords(period: .month, includeDisconnected: true).count == 1, "disconnect removes active summaries while retaining activity history")
        check(ledgerModel.coverage[.codex]?.enabled == false && ledgerModel.coverage[.codex]?.scannedFiles == 0, "disconnected coverage does not claim a current scan")
        try fm.removeItem(at: sessions)
        let ledgerRestart = AIUsageModel(dataDirectory: ledgerBase, startServices: false, notifications: FixtureAIQuotaNotifications(), claudeSubscription: FixtureClaudeSubscription())
        check(ledgerRestart.records.count == 1, "retained Token history restores without the original session directory")
        await refresh(ledgerRestart)
        check(ledgerRestart.filteredRecords(period: .month, includeDisconnected: true).count == 1, "refresh with source absent preserves durable historical records")

        let protectedBase = try fixture("new-files-protection")
        try bad.write(to: file(protectedBase, "token-ledger.json")); try bad.write(to: file(protectedBase, "quota-alerts.json"))
        let protectedModel = AIUsageModel(dataDirectory: protectedBase, startServices: false, notifications: FixtureAIQuotaNotifications(), claudeSubscription: FixtureClaudeSubscription())
        check(Set(protectedModel.storageReadErrors.keys) == ["token-ledger.json", "quota-alerts.json"], "new persistence failures are isolated to their own files")
        await refresh(protectedModel)
        let protectedSaved = await protectedModel.saveAlertRule(enabledRule)
        let protectedAlertBytes = try Data(contentsOf: file(protectedBase, "quota-alerts.json"))
        check(!protectedSaved && protectedAlertBytes == bad, "corrupt reminder state is never overwritten by save")
        check(try Data(contentsOf: file(protectedBase, "token-ledger.json")) == bad, "refresh preserves corrupt original Token ledger")
        check(protectedModel.savePrice(price), "new storage failures do not block independent healthy prices")

        let navigationModel = AIUsageModel(dataDirectory: freshBase, startServices: false, notifications: FixtureAIQuotaNotifications(), claudeSubscription: FixtureClaudeSubscription())
        navigationModel.openSources(fromSettingsPrivacy: true)
        navigationModel.show(.provider(.codex))
        check(navigationModel.backTitle(overviewTitle: "用量与额度") == "返回来源管理", "AI back labels name the actual immediate parent")
        check(!navigationModel.goBack() && navigationModel.destination == .sources, "nested AI routes restore their immediate source")
        check(navigationModel.backTitle(overviewTitle: "用量与额度") == "返回隐私与锁定", "external AI source navigation keeps its Settings privacy parent label")
        check(navigationModel.goBack() && navigationModel.destination == .overview, "privacy-source entry retains external return context")
        navigationModel.present(.manual, provider: .claude); navigationModel.manualDraft.note = "unsaved fixture"
        navigationModel.requestDismissDialog()
        check(navigationModel.confirmDiscardDialog && navigationModel.dialog == .manual, "manual draft requires explicit discard before closing")
        navigationModel.confirmDiscardDialog = false
        check(navigationModel.manualDraft.note == "unsaved fixture", "continue editing preserves manual fields")
        navigationModel.discardDialogChanges()
        check(navigationModel.dialog == nil, "confirmed manual discard closes dialog")
        navigationModel.show(.prices); navigationModel.priceDraft.input = "1.5"
        navigationModel.requestPriceSelection(provider: .claude, model: "fixture-claude")
        check(navigationModel.confirmDiscardPrice && navigationModel.priceDraft.input == "1.5", "switching models cannot silently discard unsaved prices")
        navigationModel.confirmDiscardPrice = false
        navigationModel.showOverview(); navigationModel.show(.prices)
        check(navigationModel.priceDraft.input == "1.5", "leaving and re-entering AI preserves a pending price draft")
        navigationModel.requestPriceSelection(provider: .claude, model: "fixture-claude"); navigationModel.discardPriceChanges()
        check(navigationModel.priceDraft.provider == .claude && navigationModel.priceDraft.model == "fixture-claude", "explicit discard applies the selected model change")

        let importBase = try fixture("import-confirmation")
        let importService = FixtureAIQuotaNotifications()
        let importModel = AIUsageModel(dataDirectory: importBase, startServices: false, notifications: importService, claudeSubscription: FixtureClaudeSubscription())
        let importURL = importBase.appendingPathComponent("quota-reading.json")
        let importSnapshot = AIQuotaSnapshot(provider: .claude, observedAt: now, source: .manual,
                                            shortWindow: try AIQuotaWindow(usedPercent: 36, durationMinutes: 300, resetsAt: reset), weeklyWindow: nil)
        try AIQuotaImport.encode(importSnapshot).write(to: importURL)
        let sourcesBeforeReview = try Data(contentsOf: file(importBase, "sources.json"))
        check(importModel.reviewQuotaImport(at: importURL), "valid quota JSON can be reviewed without connecting")
        check(importModel.dialog == .connectionPreview && importModel.connectionPreview?.singleImport == true && importModel.connectionPreview?.windows.first?.usedPercent == 36,
              "import preview exposes the actual provider window reading")
        let sourcesAfterReview = try Data(contentsOf: file(importBase, "sources.json"))
        check(sourcesBeforeReview == sourcesAfterReview && !importModel.configuration(for: .claude).enabled && importModel.configuration(for: .claude).manualSnapshot == nil,
              "reviewing an import does not write configuration or enable a source")
        importModel.cancelConnection()
        check(importModel.dialog == nil && importModel.configuration(for: .claude).manualSnapshot == nil, "canceling import review preserves the existing source configuration")
        _ = importModel.reviewQuotaImport(at: importURL)
        check(importModel.confirmConnection(), "explicit confirmation commits the reviewed single import")
        await refresh(importModel)
        check(importModel.providerSummaries.first(where: { $0.provider == .claude })?.snapshot?.source == .imported && importModel.configuration(for: .claude).manualSnapshot?.shortWindow?.usedPercent == 36,
              "confirmed import retains its real value and imported provenance")
        let credentialURL = importBase.appendingPathComponent("auth.json")
        try AIQuotaImport.encode(importSnapshot).write(to: credentialURL)
        let sourcesBeforeInvalidImport = try Data(contentsOf: file(importBase, "sources.json"))
        check(!importModel.reviewQuotaImport(at: credentialURL) && importModel.dialog == nil, "credential filenames are rejected before an import preview opens")
        let sourcesAfterInvalidImport = try Data(contentsOf: file(importBase, "sources.json"))
        check(sourcesBeforeInvalidImport == sourcesAfterInvalidImport, "invalid import cannot overwrite a previously confirmed source")

        let missingBase = try fixture("missing-live-reading")
        let missingSessions = missingBase.appendingPathComponent("metering-sessions")
        try fm.createDirectory(at: missingSessions, withIntermediateDirectories: true)
        let missingSources = AIProvider.allCases.map { AIUsageSourceConfiguration(provider: $0, enabled: $0 == .codex, sessionsPath: missingSessions.path) }
        try JSONEncoder().encode(missingSources).write(to: file(missingBase, "sources.json"))
        let liveFile = missingSessions.appendingPathComponent("rate-reading.jsonl")
        let liveJSON: [String: Any] = ["type": "event_msg", "timestamp": timestamp,
                                    "payload": ["type": "token_count", "rate_limits": ["primary": ["used_percent": 85, "window_minutes": 300, "resets_at": reset.timeIntervalSince1970]]]]
        var liveData = try JSONSerialization.data(withJSONObject: liveJSON); liveData.append(10); try liveData.write(to: liveFile)
        let missingService = FixtureAIQuotaNotifications()
        let missingModel = AIUsageModel(dataDirectory: missingBase, startServices: false, notifications: missingService, claudeSubscription: FixtureClaudeSubscription())
        await refresh(missingModel)
        check(missingModel.providerSummaries.first(where: { $0.provider == .codex })?.state == .ready, "a present fresh local quota is reported as ready")
        try fm.removeItem(at: liveFile)
        await refresh(missingModel)
        let missingSummary = missingModel.providerSummaries.first { $0.provider == .codex }
        check(missingSummary?.state == .stale && missingSummary?.shortWindow?.usedPercent == 85,
              "missing source reading preserves the last percentage with an explicit stale state")
        let missingRuleSaved = await missingModel.saveAlertRule(enabledRule)
        check(missingRuleSaved && missingService.delivered.isEmpty, "enabling reminders while the current quota source is absent cannot notify from retained history")
        try liveData.write(to: liveFile)
        await refresh(missingModel)
        check(missingService.delivered.count == 1, "restoring a fresh real quota source resumes eligible reminders")

        print("AI model checks: \(checks-failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
