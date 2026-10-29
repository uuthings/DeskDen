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
        let managerChecks = await UsageConnectionManagerChecks.run()
        count += managerChecks.count; failures += managerChecks.failures
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-usage-ui-\(UUID())")
        let output = ProcessInfo.processInfo.environment["DESKDEN_USAGE_OUTPUT"].map { URL(fileURLWithPath: $0) }
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
            let apiFolder = folder.appendingPathComponent("APIBalance")
            let apiSource = APIBalanceConfiguration(name: "DeepSeek 示例连接", createdAt: now)
            var apiDocument = APIBalanceDocument(); apiDocument.sources = [apiSource]
            apiDocument.states[apiSource.id] = .init(snapshot: .init(sourceID: apiSource.id, observedAt: now, isAvailable: true,
                balances: [.init(currency: "CNY", totalBalance: "23.75", grantedBalance: "3.75", toppedUpBalance: "20.00")]))
            try APIBalanceStore(url: apiFolder.appendingPathComponent("api-balances.json")).save(apiDocument)
            let api = APIBalanceModel(dataDirectory: apiFolder, startServices: false)
            let calendar = CalendarModel(dataDirectory: folder.appendingPathComponent("Calendar"), system: UsageCheckCalendar(), notifier: UsageCheckNotifications())
            let app = WorkbenchAppModel(owner: owner, calendar: calendar, ai: ai, providerUsage: provider, apiBalance: api, startServices: false)
            app.route = .ai
            let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1120, height: 758), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
            let host = NSHostingView(rootView: WorkbenchRootView(model: app).environment(\.accessibilityEnabled, true))
            window.contentView = host; app.hostWindow = window; app.modals.hostWindow = window
            defer { app.modals.clear(); window.contentView = nil; window.close(); app.shutdown() }
            var observedCardWidths = Set<Int>()
            for light in [false, true] {
                app.changeAppearance(light ? .light : .dark)
                for width in [960, 1120, 1728] {
                    window.setContentSize(.init(width: width, height: width == 1728 ? 993 : 758))
                    app.openUsageOverview(); await settle(host)
                    check(!window.isVisible && !window.isKeyWindow, "usage \(width)/\(light): remains hidden and non-key")
                    let objects = objects(host)
                    let cardFrames = [isp, vps, missing].compactMap { frame("fc.usage.source." + $0.id.uuidString, objects: objects) }
                    let screen = window.convertToScreen(host.bounds)
                    let aiFrames = AIProvider.allCases.compactMap { frame("fc.ai.provider." + $0.rawValue, objects: objects) }
                    let apiFrames = [frame("fc.usage.api." + apiSource.id.uuidString, objects: objects)].compactMap { $0 }
                    let sourceFrames = cardFrames + aiFrames + apiFrames
                    if let first = sourceFrames.first { observedCardWidths.insert(Int(first.width.rounded())) }
                    check(cardFrames.count == 3 && aiFrames.count == 2 && apiFrames.count == 1 && sourceFrames.allSatisfy {
                        $0.width >= 247 && abs($0.height - 236) < 1 && abs($0.width - (sourceFrames.first?.width ?? 0)) < 1
                            && $0.minX >= screen.minX && $0.maxX <= screen.maxX + 1
                    }, "usage \(width)/\(light): subscription, traffic and currency cards share adaptive equal widths and a 236-point tagged row")
                    let rows = sourceFrames.reduce(into: [Int: [CGRect]]()) { $0[Int($1.maxY.rounded()), default: []].append($1) }.values
                    let rowsAlign = rows.allSatisfy { row in
                        let ordered = row.sorted { $0.minX < $1.minX }
                        return zip(ordered, ordered.dropFirst()).allSatisfy { pair in abs(pair.1.minX - pair.0.maxX - 12) < 1 }
                            && abs((ordered.first?.minX ?? 0) - (sourceFrames.map(\.minX).min() ?? 0)) < 1
                    }
                    check(rows.count > 1 && rowsAlign, "usage \(width)/\(light): a unified grid wraps at its minimum width with 12-point gaps and aligned row starts")
                    check(frame("fc.usage.filter", objects: objects) != nil && frame("fc.usage.sort", objects: objects) != nil
                          && frame("fc.usage.group.service", objects: objects) == nil && frame("fc.usage.group.ai", objects: objects) == nil,
                          "usage \(width)/\(light): category filtering and sorting replace collapsible group headers")
                    let apiText = text("fc.usage.api." + apiSource.id.uuidString, objects: objects)
                    check(apiText.contains("CNY") && apiText.contains("23.75") && !apiText.contains("GB") && !apiText.contains("%"),
                          "usage \(width)/\(light): the API card exposes its exact currency amount without traffic units or quota percentages")
                    check(provider.refreshing.isEmpty && api.refreshing.isEmpty && !app.device.isSampling, "usage fixture performs no live collection")
                    if let output { check(save(host, to: output.appendingPathComponent("usage-\(width)-\(light ? "light" : "dark").png")), "usage surface renders offscreen") }
                }
            }
            check(observedCardWidths.count > 1, "usage cards expand proportionally as the viewport changes instead of retaining a fixed width")
            for aiProvider in AIProvider.allCases {
                _ = app.usageAppearance.setVisible(false, for: UsagePresentationSourceID.ai(aiProvider))
            }
            for source in provider.sources {
                _ = app.usageAppearance.setVisible(false, for: UsagePresentationSourceID.service(source.id))
            }
            _ = app.usageAppearance.setVisible(false, for: UsagePresentationSourceID.api(apiSource.id))
            for light in [false, true] {
                app.changeAppearance(light ? .light : .dark)
                for width in [960, 1120, 1350, 1728] {
                    window.setContentSize(.init(width: width, height: width >= 1350 ? 993 : 758)); await settle(host)
                    let emptyFrame = frame("fc.usage.empty", objects: objects(host))
                    let bounds = window.convertToScreen(host.bounds)
                    check(emptyFrame.map { $0.width >= 248 && $0.height >= 208 && $0.minX >= bounds.minX && $0.maxX <= bounds.maxX } ?? false,
                          "empty usage \(width)/\(light): one unified configuration placeholder remains within the shared page")
                    if let output { check(save(host, to: output.appendingPathComponent("usage-empty-\(width)-\(light ? "light" : "dark").png")), "empty usage surface renders offscreen") }
                }
            }
            check(press("fc.usage.empty", in: host), "the unified empty card exposes a whole-card configuration action")
            await settle(host)
            check(app.usagePresentation.connectionManager != nil, "the empty card opens connection configuration")
            app.usagePresentation.connectionManager = nil; await settle(host)
            check(provider.sources.count == 3 && provider.state(for: isp.id).snapshot == document.states[isp.id]?.snapshot
                  && api.sources == [apiSource] && api.state(for: apiSource.id).snapshot == apiDocument.states[apiSource.id]?.snapshot,
                  "hiding cards and configuring an empty list preserves service and currency sources with their cached observations")
            for aiProvider in AIProvider.allCases {
                _ = app.usageAppearance.setVisible(true, for: UsagePresentationSourceID.ai(aiProvider))
            }
            for source in provider.sources {
                _ = app.usageAppearance.setVisible(true, for: UsagePresentationSourceID.service(source.id))
            }
            _ = app.usageAppearance.setVisible(true, for: UsagePresentationSourceID.api(apiSource.id))
            await settle(host)
            check(WorkbenchRoute.ai.title == "用量与额度", "saved AI route keeps its identity with the clearer navigation title")
            check(frame("fc.usage.tokens", objects: objects(host)) != nil, "local Token records retain an independent summary entrance above the unified list")
            _ = app.usageAppearance.setOrdering(.name, ascending: true); await settle(host)
            check(comesBefore("fc.ai.provider.claude", "fc.ai.provider.codex", in: host), "ascending name sorting reorders actual cards in the unified grid")
            check(press("fc.usage.sort-direction", in: host), "sort direction exposes a native action")
            await settle(host)
            check(!app.usageAppearance.preferences.ascending && comesBefore("fc.ai.provider.codex", "fc.ai.provider.claude", in: host),
                  "descending name sorting reverses the visible provider order")
            _ = app.usageAppearance.setOrdering(.added, ascending: true); await settle(host)
            check(press("fc.usage.configure", in: host), "overview opens unified usage configuration")
            await settle(host)
            check(app.modals.isPresented && app.usagePresentation.connectionManager != nil, "split connection manager is mounted in the shared modal host")
            let manager = app.usagePresentation.connectionManager!
            check(manager.isNew && manager.draft.service == nil && manager.draft.name.isEmpty
                  && manager.draft.appearance.categoryID == "uncategorized", "new connection opens a blank form without a provider selection stage")
            check(frame("fc.usage.manager.name", objects: objects(host)) != nil
                  && frame("fc.usage.manager.category", objects: objects(host)) != nil
                  && frame("fc.usage.manager.service", objects: objects(host)) != nil
                  && frame("fc.usage.config.kind", objects: objects(host)) == nil,
                  "the native form exposes one category and a service field without a second classification")
            manager.selectService(.codex)
            await settle(host)
            check(frame("fc.usage.manager.connect-subscription", objects: objects(host)) != nil
                  && frame("fc.usage.manager.edit-existing", objects: objects(host)) == nil
                  && frame("fc.usage.manager.claude-sync", objects: objects(host)) == nil
                  && frame("fc.usage.manager.plan", objects: objects(host)) == nil,
                  "a local subscription exposes one connection action without an edit prerequisite or required plan field")
            let previousAI = app.usageAppearance.appearance(for: UsagePresentationSourceID.ai(.codex))
            manager.save(app: app)
            check(manager.existingSubscriptionID == UsagePresentationSourceID.ai(.codex)
                  && app.usageAppearance.appearance(for: UsagePresentationSourceID.ai(.codex)) == previousAI,
                  "adding an existing local subscription cannot overwrite its saved presentation")
            manager.selectService(.bandwagon)
            for light in [false, true] {
                app.changeAppearance(light ? .light : .dark)
                for width in [960, 1120, 1728] {
                    window.setContentSize(.init(width: width, height: width == 1728 ? 993 : 758)); await settle(host)
                    let controls = objects(host), bounds = window.convertToScreen(host.bounds)
                    let saveFrame = frame("fc.usage.manager.save", objects: controls)
                    check(saveFrame.map { abs($0.height - 32) < 1 && $0.minX >= bounds.minX && $0.maxX <= bounds.maxX
                        && $0.minY >= bounds.minY && $0.maxY <= bounds.maxY } ?? false,
                          "split manager \(width)/\(light): fixed save action remains visible within the window")
                    check(frame("fc.usage.manager.resource", objects: controls) != nil && frame("fc.usage.manager.secret", objects: controls) != nil,
                          "split manager \(width)/\(light): instance and secure key fields are available")
                    check(!window.isVisible && !window.isKeyWindow && provider.refreshing.isEmpty,
                          "split manager geometry check remains isolated from live services")
                    if let output, width == 1120 { check(save(host, to: output.appendingPathComponent("usage-manager-\(light ? "light" : "dark").png")), "split manager renders offscreen") }
                }
            }
            manager.draft.name = "自定义连接名称"
            manager.draft.appearance.icon = .brand(.claude)
            manager.draft.appearance.categoryID = "api-balance"
            manager.selectService(.bandwagon)
            check(manager.draft.name == "自定义连接名称" && manager.draft.appearance.icon == .brand(.claude)
                  && manager.draft.appearance.categoryID == "api-balance", "service choice preserves an independently chosen name, brand icon and category")
            manager.draft.resourceID = "2002"; manager.draft.secret = "synthetic-switch-draft"
            manager.selectService(.deepseek)
            check(manager.confirmingDiscard && manager.draft.service == .bandwagon, "switching a service protects entered connection fields")
            manager.discardChanges(); await settle(host)
            check(manager.draft.service == .deepseek && manager.draft.secret.isEmpty && manager.draft.resourceID.isEmpty
                  && manager.draft.appearance.categoryID == "api-balance", "confirmed service change clears credentials but preserves the category")
            manager.select(UsagePresentationSourceID.service(isp.id), app: app)
            check(manager.confirmingDiscard && manager.isNew, "switching to an existing connection protects the new draft")
            manager.discardChanges(); await settle(host)
            check(manager.selectedSourceID == UsagePresentationSourceID.service(isp.id) && manager.draft.resourceID == isp.resourceID,
                  "existing connection selection loads its real order fields")
            if let output { check(save(host, to: output.appendingPathComponent("usage-configuration.png")), "split configuration renders offscreen") }
            app.usagePresentation.requestCloseConfiguration(); await settle(host)
            check(app.usagePresentation.connectionManager == nil, "an unchanged connection closes without a discard prompt")
            check(press("fc.usage.categories", in: host), "overview opens the shared category catalog")
            await settle(host)
            let customCategory = UsageCardCategory(id: "fixture-category", title: "测试分类")
            check(app.usagePresentation.categoryEditor != nil && frame("fc.usage.category.editor", objects: objects(host)) != nil,
                  "custom categories use the shared modal editor")
            app.usagePresentation.categoryEditor?.categories.append(customCategory)
            check(press("fc.usage.category.save", in: host), "category management exposes an explicit save action")
            await settle(host)
            var apiAppearance = app.usageAppearance.appearance(for: UsagePresentationSourceID.api(apiSource.id))
            apiAppearance.categoryID = customCategory.id
            check(app.usageAppearance.saveAppearance(apiAppearance, for: UsagePresentationSourceID.api(apiSource.id))
                  && app.usageAppearance.setCategoryFilter(customCategory.id), "a real API connection can receive and filter by a custom category")
            await settle(host)
            check(frame("fc.usage.api." + apiSource.id.uuidString, objects: objects(host)) != nil
                  && frame("fc.ai.provider.codex", objects: objects(host)) == nil && frame("fc.usage.source." + isp.id.uuidString, objects: objects(host)) == nil,
                  "category filtering displays matching cards without deleting other source records")
            let restoredAppearance = UsagePresentationModel(dataDirectory: app.dataDirectory.appendingPathComponent("UsagePresentation"))
            check(restoredAppearance.preferences.filterCategoryID == customCategory.id
                  && restoredAppearance.appearance(for: UsagePresentationSourceID.api(apiSource.id)).categoryID == customCategory.id,
                  "custom categories and filtering survive presentation-model recreation")
            _ = app.usageAppearance.setVisible(false, for: UsagePresentationSourceID.api(apiSource.id)); await settle(host)
            check(frame("fc.usage.empty", objects: objects(host)) != nil && api.sources == [apiSource]
                  && api.state(for: apiSource.id).snapshot == apiDocument.states[apiSource.id]?.snapshot,
                  "hiding the last filtered card preserves its currency source and cached balance")
            check(press("fc.usage.empty", in: host), "an empty category can return to all categories")
            await settle(host)
            check(app.usageAppearance.preferences.filterCategoryID == nil && app.usagePresentation.connectionManager == nil,
                  "the filtered empty action clears only its category filter")
            _ = app.usageAppearance.setVisible(true, for: UsagePresentationSourceID.api(apiSource.id)); await settle(host)
            check(press("fc.usage.api." + apiSource.id.uuidString, in: host), "the entire API balance card exposes its detail action")
            await settle(host)
            let apiDetailText = labels(objects(host))
            check(app.usagePresentation.selectedAPIID == apiSource.id && app.usagePresentation.selectedSourceID == nil
                  && frame("fc.usage.api.detail", objects: objects(host)) != nil
                  && apiDetailText.contains("赠送余额") && apiDetailText.contains("3.75 CNY") && apiDetailText.contains("20.00 CNY"),
                  "API detail keeps total, granted and topped-up currency amounts distinct from service traffic")
            if let output { check(save(host, to: output.appendingPathComponent("usage-api-detail.png")), "API balance detail renders offscreen") }
            check(pressLabel("编辑连接", in: host), "API detail opens its own connection editor")
            await settle(host)
            let apiDraft = app.usagePresentation.connectionManager
            check(apiDraft?.selectedSourceID == UsagePresentationSourceID.api(apiSource.id) && apiDraft?.draft.service == .deepseek,
                  "API editing loads the selected source into the same split manager")
            apiDraft?.draft.name = "未保存的余额名称"; apiDraft?.draft.secret = "synthetic-api-draft"
            app.openUsageOverview()
            check(app.usagePresentation.selectedAPIID == apiSource.id && app.usagePresentation.connectionManager === apiDraft,
                  "overview navigation preserves an unsaved API connection draft")
            app.usagePresentation.requestCloseConfiguration(); await settle(host)
            check(apiDraft?.confirmingDiscard == true, "changed API fields require explicit discard")
            apiDraft?.discardChanges(); await settle(host)
            check(apiDraft?.draft.secret.isEmpty == true && api.sources == [apiSource] && app.usagePresentation.connectionManager == nil,
                  "discard clears the transient API key without altering stored currency metadata")
            check(pressLabel("返回用量与额度", in: host), "API detail names and exposes its real parent return action")
            await settle(host)
            check(app.usagePresentation.selectedAPIID == nil && frame("fc.usage.api." + apiSource.id.uuidString, objects: objects(host)) != nil,
                  "API detail returns to the unified source overview")
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
            // Exercise the actual production settings and Home in this same
            // hidden host. An invalid channel plus allowsStarting=false prevents
            // even an accidental action from creating a real update engine.
            owner.updates = AppUpdateController(owner: owner, information: [:], allowsStarting: false)
            let installedVersion = "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            for light in [false, true] {
                app.changeAppearance(light ? .light : .dark)
                for width in [960, 1120, 1728] {
                    window.setContentSize(.init(width: width, height: width == 1728 ? 993 : 758))
                    app.settingsTab = .general; app.navigate(.settings); await settle(host)
                    let settingsObjects = objects(host)
                    check(text("updates-current-version", objects: settingsObjects).contains("方寸 " + installedVersion)
                          && text("window-brand", objects: settingsObjects).contains(installedVersion)
                          && !text("window-brand", objects: settingsObjects).contains("·"),
                          "version display \(width)/\(light): mounted brand and software update card share the lowercase v prefix")
                    check(frame("top-context-display", objects: settingsObjects) != nil,
                          "global context \(width)/\(light): date, time and weather remain in the settings top bar")
                    check(!window.isVisible && !window.isKeyWindow && !owner.updates.canCheck && !app.device.isSampling && provider.refreshing.isEmpty,
                          "version display \(width)/\(light): settings stay hidden with collection and the real updater disabled")
                    if let output { check(save(host, to: output.appendingPathComponent("update-settings-\(width)-\(light ? "light" : "dark").png")), "software update settings render offscreen") }
                    app.navigate(.overview); await settle(host)
                    let homeObjects = objects(host)
                    let thermalCard = frame("home-device-detail", objects: homeObjects)
                    let networkCard = frame("home-network-detail", objects: homeObjects)
                    let thermalText = text("home-device-detail", objects: homeObjects)
                    let networkText = text("home-network-detail", objects: homeObjects)
                    let snapshot = app.device.snapshot
                    let batteryText = snapshot.battery.map { String(format: "%.0f%%", $0.percent) } ?? "电源读数不可用"
                    check(thermalCard != nil && thermalText.contains("CPU 温度") && thermalText.contains("GPU 温度") && thermalText.contains("°C") && thermalText.contains(snapshot.deviceName) && thermalText.contains(snapshot.chipName),
                          "home readings \(width)/\(light): the whole device button exposes its actual identity and temperatures")
                    let storageText = text("home-open-cleaning", objects: homeObjects)
                    check(storageText.contains("磁盘已用比例") && thermalText.contains("运行内存")
                          && storageText.contains(snapshot.disk.map { String(format: "%.0f%%", $0.percent) } ?? "读数不可用")
                          && thermalText.contains(snapshot.memory.map { String(format: "%.0f%%", $0.percent) } ?? "读数不可用"),
                          "home readings \(width)/\(light): disk and memory progress remain labeled inside their whole-card actions")
                    check(thermalText.contains(batteryText)
                          && networkText.contains("下载") && networkText.contains("上传")
                          && networkText.contains(DeviceFormat.rate(snapshot.network.downloadBytesPerSecond))
                          && networkText.contains(DeviceFormat.rate(snapshot.network.uploadBytesPerSecond))
                          && thermalCard.flatMap { thermal in networkCard.map { network in network.minX >= thermal.maxX + 10 && abs(network.maxY - thermal.maxY) < 1 } } == true,
                          "home readings \(width)/\(light): actual battery and live network readings occupy compact cards beside one another")
                    let diskCard = frame("home-open-cleaning", objects: homeObjects)
                    check(thermalCard.flatMap { left in diskCard.flatMap { middle in networkCard.map { right in
                        abs(left.width - middle.width) < 1 && abs(middle.width - right.width) < 1
                            && abs(middle.minX - left.maxX - 12) < 1 && abs(right.minX - middle.maxX - 12) < 1
                            && [left, middle, right].allSatisfy { abs($0.height - 264) < 1 }
                    } } } == true && networkText.contains("最近 1 分钟的实际采样趋势"),
                          "home layout \(width)/\(light): three equal 264-point cards retain the network trend")
                    let viewport = window.convertToScreen(host.bounds)
                    let agendaFrames = ["fc.home.agenda.events", "fc.home.agenda.reminders"].compactMap { frame($0, objects: homeObjects) }
                    check(agendaFrames.count == 2 && agendaFrames.allSatisfy { $0.intersection(viewport).height >= 60 },
                          "home layout \(width)/\(light): both schedules and reminders are visible inside the initial viewport")
                    check(frame("top-context-display", objects: homeObjects) != nil,
                          "global context \(width)/\(light): Home uses the shared top-bar date, time and weather")
                    print("DETAIL home card labels \(width)/\(light) thermal=\(String(reflecting: thermalText)) network=\(String(reflecting: networkText))")
                    check(press("home-device-detail", in: host), "home device card exposes a whole-card action")
                    await settle(host)
                    check(app.route == .device && app.deviceDetail == nil && frame("top-context-display", objects: objects(host)) != nil,
                          "the complete device card opens device status while retaining global date and weather")
                    app.closeRequestedDeviceDetail(); app.navigate(.overview); await settle(host)
                    check(press("home-open-cleaning", in: host), "home disk card exposes a whole-card cleaning action")
                    await settle(host)
                    check(app.route == .cleaning, "the disk card opens space cleaning")
                    app.navigate(.overview); await settle(host)
                    check(press("home-network-detail", in: host), "home realtime network card exposes a whole-card action")
                    await settle(host)
                    check(app.route == .network && frame("top-context-display", objects: objects(host)) != nil,
                          "the complete network card opens network monitoring while retaining global date and weather")
                    app.navigate(.overview); await settle(host)
                    check(!window.isVisible && !window.isKeyWindow && !app.device.isSampling && provider.refreshing.isEmpty,
                          "home readings \(width)/\(light): mounting Home never activates a window or starts live collection")
                    if let output { check(save(host, to: output.appendingPathComponent("home-device-\(width)-\(light ? "light" : "dark").png")), "home device readings render offscreen") }
                }
            }
            window.setContentSize(.init(width: 1120, height: 758))
            for route in WorkbenchRoute.allCases {
                app.navigate(route); await settle(host)
                check(frame("top-context-display", objects: objects(host)) != nil,
                      "global context remains available on \(route.rawValue) without starting a weather request")
            }
            app.openUsageOverview(); await settle(host)
            if Bundle.main.bundleURL.pathExtension == "app" {
                let kit = try ProviderUsageBrowserBridge.exportConnectionKit(to: folder, applicationURL: Bundle.main.bundleURL, bridgeDirectory: folder.appendingPathComponent("Bridge"))
                let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: kit.appendingPathComponent("com.uuthings.deskden.iproyal.json"))) as? [String: Any]
                check(manifest?["allowed_origins"] as? [String] == [ProviderUsageBrowserProtocol.extensionOrigin], "bundled exporter restricts its native host to the exact extension")
                check(FileManager.default.isExecutableFile(atPath: kit.appendingPathComponent("native-host.command").path)
                    && FileManager.default.fileExists(atPath: kit.appendingPathComponent("Extension/manifest.json").path), "bundled exporter includes an executable wrapper and extension resources")
                let installationGuide = try String(contentsOf: kit.appendingPathComponent("INSTALL.md"), encoding: .utf8)
                check(installationGuide.contains("/bin/sh") && installationGuide.contains("INSTALL"),
                      "bundled exporter preserves the linked installation guide and explicit legacy script steps")
                let extensionManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: kit.appendingPathComponent("Extension/manifest.json"))) as? [String: Any]
                let icons = extensionManifest?["icons"] as? [String: String] ?? [:]
                let action = extensionManifest?["action"] as? [String: Any]
                let actionIcons = action?["default_icon"] as? [String: String] ?? [:]
                check(!icons.isEmpty && !actionIcons.isEmpty && Set(icons.values).union(actionIcons.values).allSatisfy {
                    guard let template = ProviderUsageBrowserBridge.templateURL,
                          let exported = try? Data(contentsOf: kit.appendingPathComponent("Extension/" + $0)),
                          let original = try? Data(contentsOf: template.appendingPathComponent($0)) else { return false }
                    return exported == original
                }, "bundled exporter preserves every manifest and toolbar icon")
                let support = folder.appendingPathComponent("Isolated Application Support", isDirectory: true)
                let bridge = folder.appendingPathComponent("Bridge with 'quote'", isDirectory: true)
                let installed = try ProviderUsageBrowserBridge.installNativeHost(applicationURL: Bundle.main.bundleURL, bridgeDirectory: bridge, applicationSupportDirectory: support)
                let installedData = try Data(contentsOf: installed)
                let installedManifest = try JSONSerialization.jsonObject(with: installedData) as? [String: Any]
                let launcher = support.appendingPathComponent("DeskDen/Connectors/IPRoyal/native-host.command")
                check(installedManifest?["allowed_origins"] as? [String] == [ProviderUsageBrowserProtocol.extensionOrigin]
                      && installedManifest?["path"] as? String == launcher.path,
                      "App registration pins the exact extension and a persistent private launcher")
                let command = try String(contentsOf: launcher, encoding: .utf8)
                check(command.contains("'\\''") && command.contains(" --provider-usage-browser-host ")
                      && command.hasSuffix(" \"$@\"\n"), "App registration quotes local paths and forwards Chrome's origin")
                let launcherMode = try FileManager.default.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? NSNumber
                let manifestMode = try FileManager.default.attributesOfItem(atPath: installed.path)[.posixPermissions] as? NSNumber
                check(launcherMode?.intValue == 0o700 && manifestMode?.intValue == 0o600,
                      "App registration restricts launcher and manifest to the current user")
                _ = try ProviderUsageBrowserBridge.installNativeHost(applicationURL: Bundle.main.bundleURL, bridgeDirectory: bridge, applicationSupportDirectory: support)
                check(try Data(contentsOf: installed) == installedData, "reinstalling the same App connection is idempotent")
                let unsafeSupport = folder.appendingPathComponent("Unsafe Support", isDirectory: true)
                try FileManager.default.createDirectory(at: unsafeSupport, withIntermediateDirectories: false)
                try FileManager.default.createSymbolicLink(at: unsafeSupport.appendingPathComponent("Google"), withDestinationURL: support.appendingPathComponent("Google"))
                do {
                    _ = try ProviderUsageBrowserBridge.installNativeHost(applicationURL: Bundle.main.bundleURL, bridgeDirectory: bridge, applicationSupportDirectory: unsafeSupport)
                    check(false, "App registration refuses linked browser directories")
                } catch { check(true, "App registration refuses linked browser directories") }
                let afterRefusedInstall = try Data(contentsOf: installed)
                check(!FileManager.default.fileExists(atPath: unsafeSupport.appendingPathComponent("DeskDen").path)
                      && afterRefusedInstall == installedData, "refused registration leaves connector and linked destination unchanged")
                let before = try Data(contentsOf: kit.appendingPathComponent("README.md"))
                do {
                    _ = try ProviderUsageBrowserBridge.exportConnectionKit(to: folder, applicationURL: Bundle.main.bundleURL, bridgeDirectory: folder)
                    check(false, "connection export never overwrites an existing kit")
                } catch { check(true, "connection export never overwrites an existing kit") }
                check(try Data(contentsOf: kit.appendingPathComponent("README.md")) == before, "refused export preserves the existing kit")
            }
            try await provider.prepareForQuit(); try await ai.prepareForQuit(); try await api.prepareForQuit()
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
    private static func text(_ id: String, objects: [NSObject]) -> String {
        objects.filter { identifier($0) == id }.flatMap { object in
            ["accessibilityLabel", "accessibilityValue"].compactMap { selector -> String? in
                guard object.responds(to: NSSelectorFromString(selector)) else { return nil }
                return object.value(forKey: selector) as? String
            }
        }.joined(separator: " ")
    }
    private static func labels(_ objects: [NSObject]) -> String {
        objects.flatMap { object in
            ["accessibilityLabel", "accessibilityValue"].compactMap { selector -> String? in
                guard object.responds(to: NSSelectorFromString(selector)) else { return nil }
                return object.value(forKey: selector) as? String
            }
        }.joined(separator: " ")
    }
    private static func comesBefore(_ first: String, _ second: String, in host: NSView) -> Bool {
        let controls = objects(host)
        guard let a = frame(first, objects: controls), let b = frame(second, objects: controls) else { return false }
        return abs(a.maxY - b.maxY) < 1 ? a.minX < b.minX : a.maxY > b.maxY
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
    private static func pressLabel(_ label: String, in host: NSView) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let object = objects(host).first(where: { object in
            object.responds(to: selector) && object.responds(to: NSSelectorFromString("accessibilityLabel"))
                && object.value(forKey: "accessibilityLabel") as? String == label
        }) else { return false }
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
