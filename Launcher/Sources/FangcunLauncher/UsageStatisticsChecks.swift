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
            let disabled = AIProvider.allCases.map { AIUsageSourceConfiguration(provider: $0, enabled: false,
                sessionsPath: folder.appendingPathComponent("disabled-" + $0.rawValue).path) }
            try JSONEncoder().encode(disabled).write(to: aiSources.appendingPathComponent("sources.json"))
            let ai = AIUsageModel(dataDirectory: aiFolder, startServices: false, notifications: UsageCheckAINotifications())
            let providerFolder = folder.appendingPathComponent("Provider"), now = Date()
            let isp = ProviderUsageConfiguration(kind: .iproyal, name: "ISP 示例订单", resourceID: "1001")
            let vps = ProviderUsageConfiguration(kind: .bandwagon, name: "VPS 示例实例", resourceID: "1002")
            let missing = ProviderUsageConfiguration(kind: .iproyal, name: "等待连接的订单", resourceID: "1003")
            var document = ProviderUsageDocument(); document.sources = [isp, vps, missing]
            document.states[isp.id] = .init(snapshot: .init(sourceID: isp.id, observedAt: now, usedBytes: 45_000_000_000, limitBytes: 100_000_000_000,
                remainingBytes: 55_000_000_000, resetDateText: "2026-11-25", displayUnit: .decimalGB, sourceDescription: "隔离测试数据"))
            document.states[vps.id] = .init(snapshot: .init(sourceID: vps.id, observedAt: now, usedBytes: 128 * 1_073_741_824, limitBytes: 1000 * 1_073_741_824,
                resetsAt: now.addingTimeInterval(86_400), displayUnit: .binaryGB, sourceDescription: "隔离测试数据"))
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
                    check(cardFrames.count == 3 && cardFrames.allSatisfy { $0.width >= 270 && $0.minX >= screen.minX && $0.maxX <= screen.maxX + 1 },
                          "usage \(width)/\(light): every service card has readable width inside the shared page")
                    check(provider.refreshing.isEmpty && !app.device.isSampling, "usage fixture performs no live collection")
                    if let output { check(save(host, to: output.appendingPathComponent("usage-\(width)-\(light ? "light" : "dark").png")), "usage surface renders offscreen") }
                }
            }
            check(press("fc.usage.source." + isp.id.uuidString, in: host), "whole service card exposes a native action")
            await settle(host)
            check(app.usagePresentation.selectedSourceID == isp.id, "service card opens its own independent detail")
            check(frame("fc.usage.detail", objects: objects(host)) != nil, "service detail mounts through the production navigation")
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
            app.openUsageOverview(); await settle(host)
            check(app.route == .ai && app.ai.destination == .overview && app.usagePresentation.selectedSourceID == nil, "unified overview returns without changing the legacy route identity")
            let pending = provider.state(for: missing.id)
            check(pending.snapshot == nil && pending.status() == .pending, "an unconnected order retains unknown usage")
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
