import AppKit
import LauncherCore
import SwiftUI

/// Mounts the production AI view with isolated metadata and a real shared modal
/// host. Its notification provider cannot contact the system notification center.
@MainActor enum AIUsageNativeChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-ai-native-\(UUID().uuidString)")
        let sourceDirectory = directory.appendingPathComponent("AIUsage")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let observed = Date(), reset = observed.addingTimeInterval(86_400)
            let weeklyOnly = AIQuotaSnapshot(provider: .codex, observedAt: observed, source: .manual, shortWindow: nil,
                weeklyWindow: try AIQuotaWindow(usedPercent: 35, durationMinutes: 10_080, resetsAt: reset), accountPlan: .pro)
            let bothWindows = AIQuotaSnapshot(provider: .claude, observedAt: observed, source: .manual,
                shortWindow: try AIQuotaWindow(usedPercent: 99.5, durationMinutes: 300, resetsAt: reset),
                weeklyWindow: try AIQuotaWindow(usedPercent: 6, durationMinutes: 10_080, resetsAt: reset))
            let configs = AIProvider.allCases.map { AIUsageSourceConfiguration(provider: $0, enabled: false,
                sessionsPath: directory.appendingPathComponent("disabled-" + $0.rawValue).path,
                manualSnapshot: $0 == .codex ? weeklyOnly : bothWindows) }
            try JSONEncoder().encode(configs).write(to: sourceDirectory.appendingPathComponent("sources.json"))
            let model = AIUsageModel(dataDirectory: directory, startServices: false, notifications: AIUsageCheckNotifications())
            model.refresh()
            for _ in 0..<300 where model.isRefreshing { try? await Task.sleep(for: .milliseconds(10)) }
            check(!model.isRefreshing && model.providerSummaries.first(where: { $0.provider == .codex })?.snapshot?.shortWindow == nil && model.providerSummaries.first(where: { $0.provider == .codex })?.snapshot?.accountPlan == .pro,
                  "AI native fixture loads an actual weekly-only Pro snapshot without inventing a short window")
            let coordinator = WorkbenchModalCoordinator()
            let inspection = AIUsageNativeDialogInspection()
            let surface = AIUsageCheckSurface(model: model, coordinator: coordinator, inspection: inspection)
            let host = NSHostingView(rootView: surface)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 864, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; coordinator.hostWindow = window
            defer { coordinator.clear(); window.orderOut(nil); window.close() }
            window.orderFront(nil)
            await settle(window)
            if let sourceFilter = descendants(host).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == "AI 来源" }) {
                sourceFilter.selectItem(withTitle: "Codex")
                if let action = sourceFilter.action { NSApp.sendAction(action, to: sourceFilter.target, from: sourceFilter) }
                check(model.selectedProvider == .codex, "production AI source popup changes the shared source filter")
            } else { check(false, "production AI source popup is mounted") }
            if let periodFilter = descendants(host).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == "记录范围" }) {
                periodFilter.selectItem(withTitle: "30 天")
                if let action = periodFilter.action { NSApp.sendAction(action, to: periodFilter.target, from: periodFilter) }
                check(model.selectedPeriod == .month, "production AI period popup changes the shared record range")
            } else { check(false, "production AI period popup is mounted") }
            let routes: [AIUsageDestination] = [.overview, .provider(.codex), .provider(.claude), .sources, .history, .prices]
            for size in [CGSize(width: 864, height: 660), CGSize(width: 736, height: 620), CGSize(width: 1360, height: 880)] {
                window.setContentSize(size)
                for route in routes {
                    model.show(route); await settle(window)
                    let fitting = host.fittingSize
                    check(host.frame.width == size.width && fitting.width.isFinite && fitting.height.isFinite && window.attachedSheet == nil,
                          "AI route \(String(describing: route)) lays out at content width \(Int(size.width)) without an attached sheet")
                    if route == .overview {
                        let pageScroller = descendants(host).compactMap { $0 as? NSScrollView }.max { $0.bounds.width < $1.bounds.width }
                        check(pageScroller.map { $0.scrollerStyle == .overlay && abs($0.contentSize.width - size.width) < 1 } == true,
                              "AI fixture uses the production overlay scroller without subtracting a legacy scrollbar from the shared page width at \(Int(size.width)) pt")
                        print("DETAIL AI page viewport=\(host.bounds) scroll=\(String(describing: pageScroller?.bounds)) clip=\(String(describing: pageScroller?.contentView.bounds)) style=\(String(describing: pageScroller?.scrollerStyle.rawValue))")
                        let quotaChecks = checkOverviewQuotaGeometry(host: host, pageWidth: size.width, inspection: inspection.quota)
                        count += quotaChecks.count; failures += quotaChecks.failures
                    }
                    if case .provider(let provider) = route {
                        let providerChecks = checkProviderGeometry(provider: provider, host: host, pageWidth: size.width)
                        count += providerChecks.count; failures += providerChecks.failures
                    }
                }
            }
            model.showOverview(); model.present(.alert); await settle(window)
            check(coordinator.top?.width == 470 && window.attachedSheet == nil, "AI reminder uses the real centered 470 pt shared modal host")
            let presentationIdentity = coordinator.top?.id
            model.alertWarningText = "78"; window.orderOut(nil); await settle(window); window.orderFront(nil); await settle(window)
            check(coordinator.top?.id == presentationIdentity && model.alertWarningText == "78", "hiding and restoring the AI window retains reminder draft and modal identity")
            model.requestDismissDialog(); await settle(window)
            check(model.confirmDiscardDialog, "closing an edited reminder requests an explicit discard decision")
            model.confirmDiscardDialog = false; model.discardDialogChanges(); await settle(window)
            check(coordinator.top == nil, "confirmed AI draft discard removes the modal from the shared host")
            model.present(.manual, provider: .claude); await settle(window)
            check(coordinator.top?.width == 470 && model.manualDraft.provider == .claude, "manual quota entry opens with the selected provider in the shared host")
            model.requestDismissDialog(); await settle(window)
            check(coordinator.top == nil, "an unchanged manual form can close without a discard prompt")
            let geometryChecks = await checkDialogGeometry(model: model, coordinator: coordinator, inspection: inspection, host: host, window: window, directory: directory)
            count += geometryChecks.count; failures += geometryChecks.failures
            model.openSources(fromSettingsPrivacy: true); model.show(.provider(.codex)); _ = model.goBack()
            check(model.destination == .sources && model.goBack(), "production AI navigation retains the settings privacy return context")
            check(model.configurations.allSatisfy { !$0.enabled && $0.sessionsPath.hasPrefix(directory.path) } && model.records.isEmpty,
                  "AI native view checks never read live accounts or conversation metadata")
        } catch { check(false, "AI native fixture failed: " + error.localizedDescription) }
        print("AI native checks: \(count - failures)/\(count) passed")
        return (count, failures)
    }
    private static func checkOverviewQuotaGeometry(host: NSView, pageWidth: CGFloat, inspection: AIQuotaLayoutInspection) -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message) at \(Int(pageWidth)) pt")
        }
        func frame(_ identifier: String) -> NSRect? { inspection.frame(identifier) }
        func aligned(_ a: String, _ b: String) -> Bool {
            frame(a).flatMap { left in frame(b).map { right in abs(left.midY - right.midY) < 1 && abs(left.height - right.height) < 1 } } ?? false
        }
        check(aligned("fc.ai.quota.header.codex", "fc.ai.quota.header.claude"), "AI provider headers share a stable row despite differing source and membership metadata")
        check(aligned("fc.ai.quota.codex.0.progress", "fc.ai.quota.claude.0.progress"), "weekly-only and two-window AI cards align their first real progress bars")
        check(aligned("fc.ai.quota.footer.codex", "fc.ai.quota.footer.claude"), "AI source status footers align below the shared metric area")
        check(frame("fc.ai.quota.availableOnly.codex") != nil && frame("fc.ai.quota.codex.1.progress") == nil && frame("fc.ai.quota.claude.1.progress") != nil,
              "a missing AI window uses an availability note without a fabricated label or empty progress bar")
        let regions = ["header.codex", "header.claude", "codex.0.progress", "claude.0.progress", "footer.codex", "footer.claude", "availableOnly.codex", "claude.1.progress"]
        let measured = regions.map { $0 + "=" + String(describing: frame("fc.ai.quota." + $0)) }.joined(separator: " ")
        let axMetricIDs = accessibilityObjects(in: host).compactMap { string("accessibilityIdentifier", from: $0) }.filter { $0.hasPrefix("fc.ai.quota.") }.sorted()
        print("DETAIL AI quota native regions at \(Int(pageWidth)) pt: \(measured); AX metric IDs=\(axMetricIDs)")
        return (count, failures)
    }
    private static func checkProviderGeometry(provider: AIProvider, host: NSView, pageWidth: CGFloat) -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        let sample = "\(provider.rawValue) at \(Int(pageWidth)) pt"
        func check(_ condition: Bool, _ name: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name) in \(sample)")
        }
        // Read the mounted production accessibility frames. These are AppKit
        // screen coordinates, whose larger Y is above the smaller Y.
        let objects = accessibilityObjects(in: host)
        func frame(_ identifier: String) -> NSRect? {
            objects.compactMap { object -> NSRect? in
                guard string("accessibilityIdentifier", from: object) == identifier,
                      object.responds(to: NSSelectorFromString("accessibilityFrame")),
                      let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
                let rect = value.rectValue
                return rect.width > 0 && rect.height > 0 && rect.width.isFinite && rect.height.isFinite ? rect : nil
            }.max { $0.width * $0.height < $1.width * $1.height }
        }
        let quota = frame("fc.ai.detail.quota." + provider.rawValue)
        let validity = frame("fc.ai.detail.validity")
        let title = frame("fc.ai.detail.validity.title")
        let action = frame("fc.ai.detail.manageSources")
        let notice = frame("fc.ai.detail.historyNotice")
        let noticeText = frame("fc.ai.notice.text")
        check([quota, validity, title, action, notice, noticeText].allSatisfy { $0 != nil },
              "provider title, actual source action, paired surfaces and history notice are mounted")
        let expectedWidth = (pageWidth - 12) / 2
        check(quota.flatMap { left in validity.map { right in
            abs(left.width - expectedWidth) < 1 && abs(right.width - expectedWidth) < 1 && abs(right.minX - left.maxX - 12) < 1
        } } == true, "provider quota and validity surfaces preserve their equal columns and 12 pt gap")
        let minimumHeight: CGFloat = pageWidth > 1200 ? 288 : 284
        check(quota.flatMap { left in validity.map { right in
            abs(left.minY - right.minY) < 1 && abs(left.maxY - right.maxY) < 1 &&
                left.height >= minimumHeight - 1 && right.height >= minimumHeight - 1
        } } == true, "provider surfaces keep the same top and bottom with the frozen minimum height and room for longer real content")
        check(action.map { abs($0.width - 60) < 1.5 && abs($0.height - 28) < 1 } == true,
              "Manage Sources retains the frozen 60 by 28 pt compact control")
        check(validity.flatMap { card in title.flatMap { heading in action.map { button in
            abs(heading.midY - button.midY) < 1 && abs(card.maxX - button.maxX - 14) < 1 &&
                abs(card.maxY - button.midY - 25) < 1 && abs(heading.minX - card.minX - 37) < 1
        } } } == true, "Manage Sources sits beside the title at the card top with the frozen 14 pt inset instead of at its bottom")
        check(notice.map { abs($0.width - pageWidth) < 1 && abs($0.height - 37.6) < 1 } == true,
              "history notice spans the page and retains its 17.6 pt line box plus 20 pt padding")
        // AX reports the text glyph bounds, rather than its 17.6 pt line box.
        // Measure their shared center instead of treating the glyph top as padding.
        check(notice.flatMap { outer in noticeText.map { text in
            abs(text.minX - outer.minX - 36) < 1 && abs(outer.maxY - text.midY - (10 + 17.6 / 2)) < 1 && outer.contains(text)
        } } == true, "history notice text follows the 12 pt inset, 16 pt info icon, 8 pt gap and centered 17.6 pt line box below its 10 pt padding")
        print("DETAIL AI provider \(sample) quota=\(String(describing: quota)) validity=\(String(describing: validity)) title=\(String(describing: title)) action=\(String(describing: action)) notice=\(String(describing: notice)) text=\(String(describing: noticeText))")
        return (count, failures)
    }
    private struct DialogGeometry {
        var header: NSRect
        var body: NSRect
        var footer: NSRect
        @MainActor func isUsable(in window: NSWindow, minimumBodyHeight: CGFloat = 12) -> Bool {
            guard let content = window.contentView else { return false }
            let bounds = window.convertToScreen(content.convert(content.bounds, to: nil)).insetBy(dx: -2, dy: -2)
            return [header, body, footer].allSatisfy { $0.width > 100 && $0.height.isFinite && bounds.contains($0) } &&
                header.height >= 20 && body.height > minimumBodyHeight && footer.height >= 32 &&
                header.minY >= body.maxY - 2 && body.minY >= footer.maxY - 2
        }
    }
    private static func checkDialogGeometry(model: AIUsageModel, coordinator: WorkbenchModalCoordinator,
        inspection: AIUsageNativeDialogInspection, host: NSView, window: NSWindow, directory: URL) async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let previewDirectory = directory.appendingPathComponent("isolated-preview")
        do { try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true) }
        catch { check(false, "AI dialog geometry fixture creates its isolated empty preview directory"); return (count, failures) }
        for size in [CGSize(width: 864, height: 660), CGSize(width: 736, height: 620), CGSize(width: 1360, height: 880)] {
            let label = "\(Int(size.width))×\(Int(size.height))"
            window.setContentSize(size)
            model.present(.manual, provider: .claude)
            _ = await wait(window) { dialogGeometry(in: host)?.isUsable(in: window, minimumBodyHeight: 180) == true }
            let collapsed = dialogGeometry(in: host)
            check(collapsed?.isUsable(in: window, minimumBodyHeight: 180) == true && coordinator.top?.width == 470,
                  "manual AI dialog has a readable body with separate header and footer inside \(label)")
            #if DEBUG
            _ = await wait(window) { inspection.manual.isMounted }
            let expandedByBinding = inspection.manual.isMounted && inspection.manual.setExpanded(true)
            let expanded = await wait(window) {
                descendants(host).compactMap { $0 as? WBDateInputSurface }.count == 2 &&
                (dialogGeometry(in: host)?.body.height ?? 0) > (collapsed?.body.height ?? 0) + 20
            }
            print("DETAIL AI manual \(label) DEBUG expandedBindingAccepted=\(expandedByBinding) inputs=\(descendants(host).compactMap { $0 as? WBDateInputSurface }.count) collapsedBody=\(collapsed?.body.height ?? -1) expandedBody=\(dialogGeometry(in: host)?.body.height ?? -1)")
            check(expandedByBinding && expanded && dialogGeometry(in: host)?.isUsable(in: window, minimumBodyHeight: 180) == true,
                  "DEBUG state-driven mounted manual disclosure lays out two date/time controls and grows the readable body in \(label)")
            let resetByBinding = inspection.manual.isMounted && inspection.manual.setKnownReset(true)
            let allDatesMounted = await wait(window) { descendants(host).compactMap { $0 as? WBDateInputSurface }.count == 6 }
            let inputs = descendants(host).compactMap { $0 as? WBDateInputSurface }
            print("DETAIL AI manual \(label) DEBUG resetBindingAccepted=\(resetByBinding) knownReset=\(model.manualDraft.specifiesResetTimes) inputs=\(inputs.count) body=\(dialogGeometry(in: host)?.body.height ?? -1)")
            let allInsideDocuments = inputs.count == 6 && inputs.allSatisfy { input in
                guard let scroll = input.enclosingScrollView, let document = scroll.documentView else { return false }
                let rect = input.convert(input.bounds, to: document)
                return abs(input.bounds.height - 32) < 1 && document.bounds.insetBy(dx: -1, dy: -1).contains(rect)
            }
            check(resetByBinding && allDatesMounted && model.manualDraft.specifiesResetTimes && allInsideDocuments &&
                  inputs.filter { $0.picker.datePickerElements == .yearMonthDay }.count == 3 &&
                  inputs.filter { $0.picker.datePickerElements == .hourMinute }.count == 3,
                  "DEBUG state-driven known reset layout mounts all three real date and three time inputs inside their scroll document in \(label)")
            if let lastInput = inputs.last, let scroll = lastInput.enclosingScrollView {
                _ = lastInput.scrollToVisible(lastInput.bounds)
                await settle(window)
                let visible = lastInput.convert(lastInput.bounds, to: scroll.contentView)
                check(visible.intersection(scroll.contentView.bounds).height > 16 &&
                      dialogGeometry(in: host)?.isUsable(in: window, minimumBodyHeight: 180) == true,
                      "DEBUG state-driven mounted manual dates remain reachable by scrolling without collapsing or overlapping dialog chrome in \(label)")
            } else { check(false, "expanded manual AI date controls have a real scroll viewport in \(label)") }
            #endif
            model.discardDialogChanges(); await settle(window)

            for (dialog, name) in [(AIUsageDialog.alert, "alert"), (.claudeConnect, "Claude connection"), (.help, "help"), (.disconnect(.claude), "disconnect")] {
                model.present(dialog)
                let mounted = await wait(window) { dialogGeometry(in: host)?.isUsable(in: window) == true }
                let geometry = dialogGeometry(in: host)
                let compactEnough = dialog != .disconnect(.claude) || ((geometry?.body.height ?? .infinity) < 180 &&
                    (geometry.map { $0.header.height + $0.body.height + $0.footer.height } ?? .infinity) < 350)
                check(mounted && geometry?.isUsable(in: window) == true && compactEnough,
                      "\(name) AI dialog uses its real nonzero content height and visible separate chrome in \(label)")
                model.discardDialogChanges(); await settle(window)
            }
            model.reviewSessionsDirectory(at: previewDirectory, for: .codex)
            let previewMounted = await wait(window) { !model.connectionPreviewLoading && model.connectionPreview != nil &&
                dialogGeometry(in: host)?.isUsable(in: window, minimumBodyHeight: 100) == true }
            check(previewMounted && model.connectionPreview?.path == previewDirectory.path && model.records.isEmpty,
                  "real isolated connection preview has readable content and separate chrome in \(label) without importing or connecting")
            model.cancelConnection(); await settle(window)
            model.errorMessage = "隔离验证：尚未连接计量来源。"
            let errorMounted = await wait(window) { dialogGeometry(in: host)?.isUsable(in: window) == true }
            let errorGeometry = dialogGeometry(in: host)
            check(errorMounted && (errorGeometry?.body.height ?? .infinity) < 120 &&
                  (errorGeometry.map { $0.header.height + $0.body.height + $0.footer.height } ?? .infinity) < 300,
                  "short AI errors fit their actual message rather than a large fixed-height panel in \(label)")
            model.errorMessage = nil; await settle(window)
        }
        #if !DEBUG
        print("AI manual expanded/reset layout requires DEBUG; 9 state-driven mounted layout checks did not run. Remaining AI behavior and geometry checks ran.")
        #endif
        return (count, failures)
    }
    private static func dialogGeometry(in host: NSView) -> DialogGeometry? {
        let objects = accessibilityObjects(in: host)
        func frame(_ identifier: String) -> NSRect? {
            for object in objects where string("accessibilityIdentifier", from: object) == identifier {
                guard object.responds(to: NSSelectorFromString("accessibilityFrame")),
                      let value = object.value(forKey: "accessibilityFrame") as? NSValue else { continue }
                let rect = value.rectValue
                if rect.width > 0 && rect.height.isFinite { return rect }
            }
            return nil
        }
        guard let header = frame("fc.ai.dialog.header"), let body = frame("fc.ai.dialog.body"), let footer = frame("fc.ai.dialog.footer") else { return nil }
        return DialogGeometry(header: header, body: body, footer: footer)
    }
    private static func string(_ property: String, from object: NSObject) -> String? {
        object.responds(to: NSSelectorFromString(property)) ? object.value(forKey: property) as? String : nil
    }
    private static func accessibilityObjects(in root: NSView) -> [NSObject] {
        var pending: [NSObject] = [root], result: [NSObject] = [], seen = Set<ObjectIdentifier>()
        while let object = pending.popLast(), seen.count < 8_192 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return result
    }
    private static func wait(_ window: NSWindow, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline
        return condition()
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func settle(_ window: NSWindow) async {
        for _ in 0..<3 { window.contentView?.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
    }
}
private struct AIUsageCheckSurface: View {
    @ObservedObject var model: AIUsageModel
    @ObservedObject var coordinator: WorkbenchModalCoordinator
    let inspection: AIUsageNativeDialogInspection
    var body: some View {
        #if DEBUG
        surface.environment(\.aiManualDialogInspection, inspection.manual).environment(\.aiQuotaLayoutInspection, inspection.quota)
        #else
        surface.environment(\.aiQuotaLayoutInspection, inspection.quota)
        #endif
    }
    private var surface: some View {
        GeometryReader { geometry in
            ZStack {
                // Match WorkbenchRootView's real page container. A bare test
                // ScrollView may inherit a 15 pt legacy scroller and would
                // measure window width rather than the agreed content width.
                ScrollView {
                    AIUsageModuleView(model: model)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(WorkbenchOverlayScrollbars())
                }.scrollContentBackground(.hidden).scrollBounceBehavior(.basedOnSize)
                WorkbenchModalHost(coordinator: coordinator)
            }.environment(\.workbenchDeviceExpanded, geometry.size.width > 1200)
                .environment(\.workbenchContentHeight, geometry.size.height)
        }.environment(\.workbenchModals, coordinator)
            .workbenchThemeEnvironment(theme: .arWorld, opacity: 0.70, backgroundMotion: false)
    }
}
/// One instance spans the page and cached modal host. Release never constructs
/// a debug binding bridge; its remaining behavior and geometry checks still run.
@MainActor private final class AIUsageNativeDialogInspection {
    let quota = AIQuotaLayoutInspection()
    #if DEBUG
    let manual = AIManualDialogInspection()
    #endif
}
@MainActor private final class AIUsageCheckNotifications: AIQuotaNotificationProviding {
    func permission() async -> AIQuotaNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func deliver(_ event: AIQuotaAlertEvent) async throws { throw AIUsageError.invalid("Isolated AI native fixture") }
}
