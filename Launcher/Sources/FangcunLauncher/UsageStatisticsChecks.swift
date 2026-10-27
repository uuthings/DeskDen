import AppKit
import SwiftUI
import LauncherCore

/// Disposable metadata and hidden production views. No real accounts, network
/// requests, browser registration, permission prompts or Keychain writes.
@MainActor enum UsageStatisticsChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        let presentationChecks = UsagePresentationModelChecks.run()
        count += presentationChecks.count; failures += presentationChecks.failures
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-usage-ui-\(UUID())")
        let output = ProcessInfo.processInfo.environment["FANGCUN_USAGE_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let originalPalette = (Palette.workbenchTheme, Palette.isLight, Palette.glassOpacity)
        defer {
            Palette.workbenchTheme = originalPalette.0; Palette.isLight = originalPalette.1; Palette.glassOpacity = originalPalette.2
            try? FileManager.default.removeItem(at: folder)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            let owner = LauncherController(dataDirectory: folder.appendingPathComponent("Launcher"))
            owner.scanning = true
            let aiFolder = folder.appendingPathComponent("AI"), aiSources = aiFolder.appendingPathComponent("AIUsage")
            try FileManager.default.createDirectory(at: aiSources, withIntermediateDirectories: true)
            let now = Date()
            let disabled = try AIProvider.allCases.map { provider in
                AIUsageSourceConfiguration(provider: provider, enabled: false,
                    sessionsPath: folder.appendingPathComponent("disabled-" + provider.rawValue).path,
                    manualSnapshot: AIQuotaSnapshot(provider: provider, observedAt: now, source: .manual,
                        shortWindow: provider == .codex ? try AIQuotaWindow(usedPercent: 32, durationMinutes: 300, resetsAt: now.addingTimeInterval(7200)) : nil,
                        weeklyWindow: try AIQuotaWindow(usedPercent: provider == .codex ? 16 : 28, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)),
                        accountPlan: provider == .codex ? .plus : .pro))
            }
            try JSONEncoder().encode(disabled).write(to: aiSources.appendingPathComponent("sources.json"))
            let ai = AIUsageModel(dataDirectory: aiFolder, startServices: false, notifications: UsageCheckAINotifications())
            ai.refresh()
            for _ in 0..<40 where ai.isRefreshing { try? await Task.sleep(for: .milliseconds(25)) }
            check(!ai.isRefreshing && ai.providerSummaries.allSatisfy { $0.snapshot != nil }, "isolated AI readings load without scanning automatic sources")
            let providerFolder = folder.appendingPathComponent("Provider")
            let isp = ProviderUsageConfiguration(kind: .iproyal, name: "ISP 示例订单", resourceID: "1001")
            let vps = ProviderUsageConfiguration(kind: .bandwagon, name: "VPS 示例实例", resourceID: "1002")
            let missing = ProviderUsageConfiguration(kind: .iproyal, name: "等待连接的订单", resourceID: "1003")
            var document = ProviderUsageDocument(); document.sources = [isp, vps, missing]
            document.states[isp.id] = .init(snapshot: .init(sourceID: isp.id, observedAt: now, usedBytes: 45_000_000_000, limitBytes: 100_000_000_000,
                remainingBytes: 55_000_000_000, resetDateText: "2026-11-25", displayUnit: .decimalGB, sourceDescription: "隔离测试数据"))
            document.states[vps.id] = .init(snapshot: .init(sourceID: vps.id, observedAt: now, usedBytes: 128 * 1_073_741_824, limitBytes: 1000 * 1_073_741_824,
                resetsAt: now.addingTimeInterval(86_400), displayUnit: .binaryGB, sourceDescription: "隔离测试数据"))
            var failedFirstRead = ProviderUsageSourceState()
            failedFirstRead.refresh.failed(.transport, at: now)
            failedFirstRead.message = ProviderUsageFailure.transport.localizedDescription
            document.states[missing.id] = failedFirstRead
            try ProviderUsageStore(url: providerFolder.appendingPathComponent("provider-usage.json")).save(document)
            let provider = ProviderUsageModel(dataDirectory: providerFolder, startServices: false)
            let calendar = CalendarModel(dataDirectory: folder.appendingPathComponent("Calendar"), system: UsageCheckCalendar(), notifier: UsageCheckNotifications())
            let app = WorkbenchAppModel(owner: owner, calendar: calendar, ai: ai, providerUsage: provider, startServices: false)
            app.route = .ai
            let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1120, height: 758), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
            let host = NSHostingView(rootView: WorkbenchRootView(model: app).environment(\.accessibilityEnabled, true))
            window.contentView = host; app.hostWindow = window; app.modals.hostWindow = window
            defer { app.modals.clear(); window.contentView = nil; window.close(); app.shutdown() }
            for light in [false, true] {
                app.changeAppearance(light ? .light : .dark)
                for width in [960, 1120, 1728] {
                    window.setContentSize(.init(width: width, height: width == 1728 ? 993 : 758))
                    app.openUsageOverview(); await settle(host)
                    check(!window.isVisible && !window.isKeyWindow, "usage \(width)/\(light): remains hidden and non-key")
                    let objects = objects(host)
                    let cardFrames = [isp, vps, missing].compactMap { frame("fc.usage.source." + $0.id.uuidString, objects: objects) }
                    let screen = window.convertToScreen(host.bounds)
                    check(cardFrames.count == 3 && cardFrames.allSatisfy { abs($0.width - 248) < 1 && abs($0.height - 208) < 1 && $0.minX >= screen.minX && $0.maxX <= screen.maxX + 1 },
                          "usage \(width)/\(light): every service card preserves the approved 248 by 208 size inside the shared page")
                    let aiFrames = AIProvider.allCases.compactMap { frame("fc.ai.provider." + $0.rawValue, objects: objects) }
                    check(aiFrames.count == 2 && aiFrames.allSatisfy { abs($0.width - 248) < 1 && abs($0.height - 208) < 1 },
                          "usage \(width)/\(light): AI cards use the same fixed size as service cards")
                    if cardFrames.count == 3 {
                        check(abs(cardFrames[1].minX - cardFrames[0].minX - 260) < 1
                              && (width != 960 || abs(cardFrames[2].minX - cardFrames[0].minX) < 1),
                              "usage \(width)/\(light): cards retain 12-point gaps and wrap from the left")
                    }
                    check(provider.refreshing.isEmpty && !app.device.isSampling, "usage fixture performs no live collection")
                    if let output { check(save(host, to: output.appendingPathComponent("usage-\(width)-\(light ? "light" : "dark").png")), "usage surface renders offscreen") }
                }
            }
            check(WorkbenchRoute.ai.title == "用量与额度", "saved AI route keeps its identity with the clearer navigation title")
            check(frame("fc.usage.tokens", objects: objects(host)) != nil, "local Token records have an entrance within the AI category")
            check(press("fc.usage.group.service", in: host), "service group exposes a native collapse action")
            await settle(host)
            let restoredAppearance = UsagePresentationModel(dataDirectory: app.dataDirectory.appendingPathComponent("UsagePresentation"))
            check(app.usageAppearance.isCollapsed(.service) && restoredAppearance.isCollapsed(.service)
                  && frame("fc.usage.source." + isp.id.uuidString, objects: objects(host)) == nil,
                  "collapse removes the service tiles and persists independently of their source records")
            check(provider.sources.count == 3 && provider.state(for: isp.id).snapshot != nil, "collapsing preserves service sources and cached observations")
            _ = press("fc.usage.group.service", in: host); await settle(host)
            check(press("fc.usage.configure", in: host), "overview opens unified usage configuration")
            await settle(host)
            check(app.modals.isPresented && frame("fc.usage.configuration", objects: objects(host)) != nil, "usage configuration is mounted in the shared modal host")
            check(press("fc.usage.config.service", in: host), "configuration exposes a service category")
            await settle(host)
            check(app.usagePresentation.configurationGroup == .service, "service configuration changes category without navigating the overview")
            check(nativeViews(host).compactMap { $0 as? NSScrollView }.contains { abs($0.bounds.width - 564) < 1 && $0.bounds.height >= 120 && $0.bounds.height <= 300 },
                  "configuration keeps its independent source list readable inside the adaptive dialog body")
            if let output { check(save(host, to: output.appendingPathComponent("usage-configuration.png")), "configuration renders offscreen") }
            app.usagePresentation.showingConfiguration = false; await settle(host)
            app.usagePresentation.editAI(.codex, appearance: .init())
            let aiDraft = app.usagePresentation.aiEditor!
            aiDraft.name = "未保存的 AI 名称"
            app.openProviderUsage(vps.id)
            check(app.usagePresentation.selectedSourceID == nil && app.usagePresentation.aiEditor === aiDraft,
                  "source navigation preserves a new AI display draft before its modal mounts")
            await settle(host)
            app.usagePresentation.requestCloseAIEditor(); await settle(host)
            check(app.usagePresentation.discardEditor && app.usagePresentation.aiEditor === aiDraft,
                  "AI display edits use explicit discard protection")
            app.usagePresentation.discard(); await settle(host)
            check(press("fc.usage.source." + isp.id.uuidString, in: host), "whole service card exposes a native action")
            await settle(host)
            check(app.usagePresentation.selectedSourceID == isp.id, "service card opens its own independent detail")
            check(frame("fc.ai.provider.codex", objects: objects(host)) == nil
                  && frame("fc.usage.order-link", objects: objects(host)) != nil,
                  "service detail replaces the AI overview and mounts its native order action")
            check(frame("fc.usage.order-link", objects: objects(host)) != nil, "service detail exposes the official order link without opening a browser during checks")
            if let output { check(save(host, to: output.appendingPathComponent("usage-detail.png")), "service detail renders offscreen") }
            app.usagePresentation.edit(isp); await settle(host)
            check(app.modals.isPresented && window.attachedSheet == nil, "connection editing uses the shared modal host")
            let editor = app.usagePresentation.editor!
            editor.name = "未保存的新名称"; editor.secret = "synthetic-form-value"
            app.openProviderUsage(vps.id)
            check(app.usagePresentation.selectedSourceID == isp.id && app.usagePresentation.editor === editor, "Mini navigation preserves the open connection draft")
            app.usagePresentation.requestCloseEditor(); await settle(host)
            check(app.usagePresentation.discardEditor && app.usagePresentation.editor === editor, "dismiss asks before discarding a changed connection")
            app.usagePresentation.discard(); await settle(host)
            check(editor.secret.isEmpty && app.usagePresentation.editor == nil && provider.sources.first?.name == isp.name, "discard clears the temporary credential and leaves saved metadata unchanged")
            let invalid = ProviderUsageEditor(source: isp, existing: true)
            invalid.thresholdMB = "nan"
            check((try? invalid.configuration()) == nil, "non-finite thresholds never reach byte conversion")
            invalid.thresholdMB = "1000"; invalid.minimumHours = "inf"
            check((try? invalid.configuration()) == nil, "non-finite refresh intervals are rejected")
            let fresh = ProviderUsageEditor(source: isp, existing: true)
            let restored = try fresh.configuration()
            check(!fresh.hasChanges && restored == isp, "existing connection round-trips without an artificial unsaved draft")
            var connectedVPS = vps; connectedVPS.credentialID = UUID()
            let vpsEditor = ProviderUsageEditor(source: connectedVPS, existing: true)
            check(!vpsEditor.verifiesCredential && vpsEditor.saveTitle == "保存修改" && vpsEditor.savingTitle == "正在保存修改",
                  "editing metadata with an unchanged saved key does not claim to verify the connection")
            vpsEditor.secret = "  \n"
            check(!vpsEditor.verifiesCredential, "whitespace-only credential edits preserve the existing-key save action")
            vpsEditor.secret = "synthetic-replacement-value"
            check(vpsEditor.verifiesCredential && vpsEditor.saveTitle == "验证并保存" && vpsEditor.savingTitle == "正在验证连接",
                  "a replacement key explicitly changes the action to connection verification")
            vpsEditor.secret = ""; vpsEditor.resourceID = "2002"
            check(vpsEditor.verifiesCredential && !vpsEditor.canKeepCredential && vpsEditor.credentialPlaceholder == "填写此实例的 API Key",
                  "changing the VPS identity requires a new verified connection and does not offer to keep the previous key")
            let resetZone = TimeZone(identifier: "America/Los_Angeles")!
            let summerReset = Date(timeIntervalSince1970: 1_783_036_800)
            let winterReset = Date(timeIntervalSince1970: 1_798_761_600)
            check(ProviderUsageFormatting.resetTimeZoneDescription(summerReset, timeZone: resetZone).hasSuffix("（UTC−07:00）")
                  && ProviderUsageFormatting.resetTimeZoneDescription(winterReset, timeZone: resetZone).hasSuffix("（UTC−08:00）"),
                  "reset timezone offsets follow the reset instant across daylight-saving changes")
            check(ProviderUsageFormatting.resetDetail(document.states[isp.id]!.snapshot!, timeZone: resetZone) == "2026-11-25 · 服务商日期，时区未提供",
                  "date-only provider reset values remain unchanged and do not acquire an invented timezone")
            app.openProviderUsage(vps.id); await settle(host)
            check(frame("fc.usage.bandwagon.reset-explanation", objects: objects(host)) != nil
                  && frame("fc.usage.bandwagon.accounting-explanation", objects: objects(host)) != nil,
                  "Bandwagon detail explains provider accounting and the timezone conversion")
            if let output { check(save(host, to: output.appendingPathComponent("usage-bandwagon-detail.png")), "Bandwagon detail renders offscreen") }
            app.usagePresentation.add(.bandwagon); await settle(host)
            let connectionDraft = app.usagePresentation.editor!
            check(connectionDraft.verifiesCredential && connectionDraft.saveTitle == "验证并保存", "new Bandwagon sources require verified credentials")
            for light in [false, true] {
                app.changeAppearance(light ? .light : .dark)
                for width in [960, 1120, 1728] {
                    window.setContentSize(.init(width: width, height: width == 1728 ? 993 : 758)); await settle(host)
                    let controls = objects(host), bounds = window.convertToScreen(host.bounds)
                    let scrolls = nativeViews(host).compactMap { $0 as? NSScrollView }
                    let editorScroll = scrolls.first { abs($0.bounds.width - 560) < 1 }
                    check(editorScroll.map { $0.scrollerStyle == .overlay && $0.autohidesScrollers && abs($0.contentSize.width - 560) < 1 } ?? false,
                          "Bandwagon editor \(width)/\(light): body scrolls at the full dialog edge without a reserved track")
                    let saveFrame = frame("fc.usage.editor.save", objects: controls)
                    check(saveFrame.map { abs($0.height - 32) < 1 && $0.minX >= bounds.minX && $0.maxX <= bounds.maxX && $0.minY >= bounds.minY && $0.maxY <= bounds.maxY } ?? false,
                          "Bandwagon editor \(width)/\(light): verification remains a visible 32-point fixed-footer action")
                    check(frame("fc.usage.editor.resource-id", objects: controls) != nil
                          && frame("fc.usage.editor.api-key", objects: controls) != nil
                          && frame("fc.usage.editor.bandwagon-services", objects: controls) != nil,
                          "Bandwagon editor \(width)/\(light): instance, secure key and official setup entry remain available")
                    check(!window.isVisible && !window.isKeyWindow && provider.refreshing.isEmpty,
                          "Bandwagon editor \(width)/\(light): hidden checks do not query a live service or open the browser")
                    if let output { check(save(host, to: output.appendingPathComponent("usage-bandwagon-editor-\(width)-\(light ? "light" : "dark").png")), "Bandwagon connection form renders offscreen") }
                }
            }
            app.usagePresentation.discard(); await settle(host)
            app.openUsageOverview(); await settle(host)
            check(app.route == .ai && app.ai.destination == .overview && app.usagePresentation.selectedSourceID == nil, "unified overview returns without changing the legacy route identity")
            let pending = provider.state(for: missing.id)
            check(pending.snapshot == nil && pending.status() == .failed, "a failed first query retains unknown usage instead of a fabricated old reading")
            if Bundle.main.bundleURL.pathExtension == "app" {
                let kit = try ProviderUsageBrowserBridge.exportConnectionKit(to: folder, applicationURL: Bundle.main.bundleURL, bridgeDirectory: folder.appendingPathComponent("Bridge"))
                let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: kit.appendingPathComponent("com.uuthings.fangcun.iproyal.json"))) as? [String: Any]
                check(manifest?["allowed_origins"] as? [String] == [ProviderUsageBrowserProtocol.extensionOrigin], "bundled exporter restricts its native host to the exact extension")
                check(FileManager.default.isExecutableFile(atPath: kit.appendingPathComponent("native-host.command").path)
                    && FileManager.default.fileExists(atPath: kit.appendingPathComponent("Extension/manifest.json").path), "bundled exporter includes an executable wrapper and extension resources")
                let before = try Data(contentsOf: kit.appendingPathComponent("README.md"))
                do {
                    _ = try ProviderUsageBrowserBridge.exportConnectionKit(to: folder, applicationURL: Bundle.main.bundleURL, bridgeDirectory: folder)
                    check(false, "connection export never overwrites an existing kit")
                } catch { check(true, "connection export never overwrites an existing kit") }
                check(try Data(contentsOf: kit.appendingPathComponent("README.md")) == before, "refused export preserves the existing kit")
            }
            try await provider.prepareForQuit(); try await ai.prepareForQuit()
        } catch { check(false, "isolated usage fixture: \(error.localizedDescription)") }
        print("Usage UI checks: \(count) checks, \(failures) failures")
        return (count, failures)
    }
    private static func nativeViews(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + nativeViews($0) } }
    private static func settle(_ host: NSView) async { try? await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
    private static func save(_ host: NSView, to url: URL) -> Bool {
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }
    private static func objects(_ root: NSView) -> [NSObject] {
        var pending: [NSObject] = [root], seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        while let object = pending.popLast(), seen.count < 12_000 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }; result.append(object)
            if let view = object as? NSView { pending += view.subviews }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending += children }
        }; return result
    }
    private static func identifier(_ object: NSObject) -> String {
        object.responds(to: NSSelectorFromString("accessibilityIdentifier")) ? object.value(forKey: "accessibilityIdentifier") as? String ?? "" : ""
    }
    private static func frame(_ id: String, objects: [NSObject]) -> CGRect? {
        objects.filter { identifier($0) == id }.compactMap { object -> CGRect? in
            guard object.responds(to: NSSelectorFromString("accessibilityFrame")), let rect = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, rect.width > 0 else { return nil }; return rect
        }.reduce(nil) { (result: CGRect?, next: CGRect) in result.map { $0.union(next) } ?? next }
    }
    private static func press(_ id: String, in host: NSView) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let object = objects(host).first(where: { identifier($0) == id && $0.responds(to: selector) }) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
}

@MainActor private final class UsageCheckCalendar: CalendarSystemProviding {
    func access(reminders: Bool) -> CalendarAccess { .notDetermined }
    func requestAccess(reminders: Bool) async throws -> Bool { false }
    func events(in interval: DateInterval) throws -> [CalendarEventItem] { [] }
    func reminders() async throws -> [ReminderItem] { [] }
    func writableReminderCalendars() -> [ReminderCalendar] { [] }
    func saveReminder(_ item: ReminderItem, creating: Bool) throws -> ReminderItem { throw ReminderError.unavailable("Isolated fixture") }
    func deleteReminder(_ item: ReminderItem) throws { throw ReminderError.unavailable("Isolated fixture") }
}
@MainActor private final class UsageCheckNotifications: ReminderNotificationProviding {
    func access() async -> CalendarAccess { .notDetermined }
    func requestAccess() async throws -> Bool { false }
    func replacePending(_ notifications: [ReminderNotification]) async throws { }
}
@MainActor private final class UsageCheckAINotifications: AIQuotaNotificationProviding {
    func permission() async -> AIQuotaNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func deliver(_ event: AIQuotaAlertEvent) async throws { throw AIUsageError.invalid("Isolated fixture") }
}
