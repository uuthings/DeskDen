import AppKit
import SwiftUI
import LauncherCore

@MainActor enum DeviceModuleChecks {
    static func run() async -> Int {
        let topEntry = await WorkbenchTopEntryChecks.run()
        var count = topEntry.count, failures = await DeviceMonitoringFormChecks.run() + topEntry.failures
        func check(_ condition: Bool, _ message: String) { count += 1; if !condition { failures += 1 }; print("\(condition ? "PASS" : "FAIL") \(message)") }
        check(DeviceTrafficDisplay.budget(100) == "100 GB" && DeviceTrafficDisplay.budget(0.01) == "0.01 GB", "traffic budget card keeps the exact decimal GB allowance")
        check(DeviceTrafficDisplay.adaptive(100_000_000_000) == "100 GB" && DeviceTrafficDisplay.adaptive(1_048_576) == "1.05 MB", "traffic card adaptive units use decimal bytes consistently with budget thresholds")
        check(DeviceTrafficDisplay.adaptive(999) == "999 B" && DeviceTrafficDisplay.adaptive(1000) == "1 KB" && DeviceTrafficDisplay.adaptive(nil) == "—", "traffic display preserves byte boundaries and missing data")
        check(DeviceFormat.capacity(1_048_576) == "1 MB", "traffic unit fix does not change memory or storage formatting")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-device-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = DeviceStatusModel(dataDirectory: dir)
        model.changeCard(.memory) { $0.meter = .ring; $0.visible = false; $0.columns = 6; $0.rows = 5 }
        check(model.dashboardLayout.cards.first { $0.id == .memory }?.meter == .ring, "card display preference changes are stored")
        let restored = DeviceStatusModel(dataDirectory: dir)
        check(restored.dashboardLayout == model.dashboardLayout, "layout, visibility and style survive model recreation")
        model.undoLayoutChange()
        check(model.dashboardLayout == DeviceDashboardLayout(), "undo restores the complete prior layout")
        let grid = DeviceDashboardNSView(frame: NSRect(x: 0, y: 0, width: 864, height: 696))
        var opened: DeviceCardID?
        grid.configure(model: model, editing: false, light: false, open: { opened = $0 }, heightChanged: { _ in })
        grid.layoutSubtreeIfNeeded()
        func mouse(_ point: CGPoint) -> NSEvent { Self.mouse(grid.convert(point, to: nil)) }
        check(grid.cards.count == 8, "native grid mounts all eight independent cards")
        check(grid.cards[.profile]?.frame == CGRect(x: 0, y: 0, width: 280, height: 444), "normal tall profile matches the accepted V5 dimensions")
        check(grid.cards[.cpu]?.frame.maxY == 696, "normal dashboard matches the V5 696-point composition")
        check([DeviceCardID.memory, .storage, .thermal, .traffic].allSatisfy { grid.cards[$0]?.frame.height == 216 }, "all four summary cards share a compact content height")
        let original = model.dashboardLayout
        grid.begin(id: .profile, event: mouse(grid.cards[.profile]!.frame.center), edge: nil)
        grid.move(event: mouse(CGPoint(x: 30, y: 420))); grid.end(event: mouse(CGPoint(x: 30, y: 420)))
        check(!grid.isInteracting && model.dashboardLayout == original, "normal mode cannot drag or reorder cards")
        grid.keyboardMove(.profile, forward: true)
        grid.keyboardResize(.memory, horizontal: true, growing: true)
        check(model.dashboardLayout == original, "normal mode rejects keyboard layout mutations")
        let cpuTile = grid.cards[.cpu]!
        let detailButton = cpuTile.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "打开CPU 使用率" }
        check(detailButton?.isHidden == true, "detail action is hidden at rest")
        cpuTile.mouseEntered(with: mouse(cpuTile.frame.center))
        check(detailButton?.isHidden == false, "hover reveals the detail action without changing layout")
        cpuTile.mouseExited(with: mouse(cpuTile.frame.center))
        check(detailButton?.isHidden == true, "detail action hides after hover ends")
        grid.activate(.network); check(opened == .network, "network speed opens its own detail route")
        grid.activate(.traffic); check(opened == .traffic, "traffic statistics opens an independent detail route")
        grid.configure(model: model, editing: true, light: false, open: { _ in }, heightChanged: { _ in })
        let memoryStart = grid.cards[.memory]!.frame.center
        grid.begin(id: .memory, event: mouse(memoryStart), edge: .s)
        grid.move(event: mouse(CGPoint(x: memoryStart.x, y: memoryStart.y + 5)))
        let memoryGhost = grid.subviews.compactMap { $0 as? DeviceDashboardTile }.first { $0.isGhost }
        check(memoryGhost?.frame.height == 221, "summary edge resize starts smoothly at its projected height")
        grid.cancelInteraction()
        for edge in DeviceResizeEdge.allCases {
            grid.configure(model: model, editing: true, light: false, open: { _ in }, heightChanged: { _ in })
            let frame = grid.cards[.cpu]!.frame, start = frame.center
            let delta = CGSize(width: edge.rawValue.contains("w") ? -60 : 60, height: edge.rawValue.contains("n") ? -60 : 60)
            grid.begin(id: .cpu, event: mouse(start), edge: edge)
            grid.move(event: mouse(CGPoint(x: start.x + delta.width, y: start.y + delta.height)))
            check(grid.isInteracting, "\(edge.rawValue) begins a live native resize")
            let card = grid.layoutValue.cards.first { $0.id == .cpu }!
            check(card.columns == 8 && card.rows == 5, "\(edge.rawValue) snaps to a readable content preset")
            grid.cancelInteraction()
            check(!grid.isInteracting && grid.layoutValue == model.dashboardLayout && grid.cards[.cpu]?.alphaValue == 1, "\(edge.rawValue) cancellation restores layout and removes ghost")
        }
        let start = grid.cards[.cpu]!.frame.center
        grid.begin(id: .cpu, event: mouse(start), edge: .e)
        grid.move(event: mouse(CGPoint(x: start.x + 60, y: start.y)))
        grid.end(event: mouse(CGPoint(x: start.x + 60, y: start.y)))
        check(model.dashboardLayout.cards.first { $0.id == .cpu }?.columns == 8, "completed native resize persists")
        model.undoLayoutChange()
        grid.configure(model: model, editing: true, light: false, open: { _ in }, heightChanged: { _ in })
        grid.begin(id: .cpu, event: mouse(grid.cards[.cpu]!.frame.center), edge: nil)
        grid.move(event: mouse(CGPoint(x: 20, y: 20)))
        check(grid.isInteracting && grid.layoutValue.cards.first?.id == .cpu, "edit drag inserts card while other cards make room")
        grid.cancelInteraction()
        check(model.dashboardLayout == original && grid.cards.values.allSatisfy { $0.alphaValue == 1 }, "drag cancellation restores all tiles")
        grid.keyboardResize(.memory, horizontal: true, growing: true)
        check(model.dashboardLayout.cards.first { $0.id == .memory }?.columns == 6, "keyboard resizing uses the same size presets")
        model.undoLayoutChange()
        grid.frame.size.width = 1360
        grid.configure(model: model, editing: true, light: false, minimumHeight: 740, expanded: true, open: { _ in }, heightChanged: { _ in })
        grid.layoutSubtreeIfNeeded()
        check(grid.cards[.profile]?.frame.height == 444 && grid.cards[.memory]?.frame.height == 216, "wide view keeps profile and summary cards at content height")
        check(grid.cards[.cpu]?.frame.height == 272 && grid.cards[.network]?.frame.height == 272 && grid.cards[.processes]?.frame.height == 272, "wide view matches the V5 272-point trend and process rows")
        let hideButton = grid.cards[.cpu]!.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "隐藏CPU 使用率" }
        check(hideButton?.frame.width == 26, "wide view preserves readable control size rather than scaling the entire card")
        grid.frame.size.width = 728
        grid.configure(model: model, editing: false, light: false, open: { _ in }, heightChanged: { _ in })
        grid.layoutSubtreeIfNeeded()
        check(model.dashboardLayout == original && grid.cards[.processes]?.frame.width == 728, "compact projection preserves preferences and gives processes a full-width row")
        grid.detachObservers()
        // Exercise the real read-only sampler separately from deterministic fixtures.
        model.start(interval: 1)
        try? await Task.sleep(for: .seconds(3.2)); model.stop()
        let s = model.snapshot
        check(s.sampledAt != nil && s.memory != nil && s.physicalCPUCount > 0, "real CPU / memory / identity sampler returns data")
        check(!s.processes.isEmpty && s.processes.allSatisfy { $0.startedMicroseconds > 0 && $0.ownerUID != nil }, "real process sampler captures start identities and ownership")
        check(s.processes.first { $0.pid == getpid() }.map { !DeviceProcessActions.isAllowed($0, currentUID: getuid(), currentPID: getpid()) } ?? false, "real own process remains protected from termination")
        let realGroups = DeviceProcessExplorer.groups(s.processes, grouped: true, filter: .all, query: "", sort: .cpu, ascending: false)
        check(realGroups.reduce(0) { $0 + $1.processes.count } == s.processes.count, "real app grouping preserves every readable process without pagination")
        check(s.cpuTemperature.map { (0..<130).contains($0) } ?? true, "temperature is valid or explicitly unavailable")
        check(s.fanRPM?.allSatisfy { $0.map { (0...20000).contains($0) } ?? true } ?? true, "fan values preserve unavailable versus zero RPM")
        print("SENSOR EVIDENCE cpu=\(s.cpuTemperature.map { String(format:"%.1f",$0) } ?? "unavailable") gpu=\(s.gpuTemperature.map { String(format:"%.1f",$0) } ?? "unavailable") fans=\(s.fanRPM?.map { $0.map { String(Int($0)) } ?? "unavailable" }.joined(separator:",") ?? "unavailable") source=\(s.sensorSource)")
        print("Device module checks: \(count-failures)/\(count) passed")
        return failures
    }
    private static func mouse(_ point: CGPoint) -> NSEvent { NSEvent.mouseEvent(with:.leftMouseDragged, location:point, modifierFlags:[], timestamp:0, windowNumber:0, context:nil, eventNumber:0, clickCount:1, pressure:1)! }
}
private extension CGRect { var center: CGPoint { CGPoint(x:midX,y:midY) } }

/// Uses the existing native-workbench window whose accessibility tree is already
/// mounted. The production child's actual Binding is inspected, not mouse input.
@MainActor enum DeviceProcessDialogChecks {
    static func run(model: WorkbenchAppModel, window: NSWindow) async -> (count: Int, failures: Int) {
        #if DEBUG
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        guard let root = window.contentView, !model.modals.isPresented, !model.confirmingQuit else {
            check(false, "process-state checks require the already mounted isolated workbench without another modal")
            return (count, failures)
        }
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let syntheticPath = FileManager.default.temporaryDirectory.appendingPathComponent("Synthetic-device-modal.app")
        let application = DeviceProcessApplication(bundlePath: syntheticPath.path,
            bundleIdentifier: "com.example.device-dialog.synthetic", name: "Synthetic application",
            executablePath: syntheticPath.appendingPathComponent("Contents/MacOS/Synthetic").path)
        let process = DeviceProcess(pid: 999_991, name: application.name, executablePath: application.executablePath,
            cpuPercent: 1, residentBytes: 900_000_000, threadCount: 2, sampledAt: started,
            startedMicroseconds: 123_456, parentPID: 1, ownerUID: getuid(), application: application)
        let inspection = DeviceProcessDialogInspection(), modalID = UUID()
        var activeRequestID: UUID?, executions: [DeviceProcessActionRequest] = [], forceRequests = 0
        defer { activeRequestID = nil; model.modals.remove(modalID) }
        func present(_ request: DeviceProcessActionRequest) {
            activeRequestID = request.id
            let dismiss = { activeRequestID = nil; model.modals.remove(modalID) }
            let dialog = DeviceProcessActionDialog(request: request, memoryFocused: true, dismiss: dismiss,
                force: { forceRequests += 1 }, perform: { executions.append($0) }, inspection: inspection)
            model.modals.present(id: modalID, parentID: nil, width: 470, content: AnyView(dialog.id(request.id)),
                requestDismiss: dismiss, isStillPresented: { activeRequestID == request.id }, invalidate: { activeRequestID = nil })
        }
        let request = DeviceProcessActionRequest(name: application.name, processes: [process], mode: .quit, wholeApplication: true)
        present(request)
        let mounted = await CachedDialogCheckAccessibility.pump(window) {
            inspection.consent != nil && model.modals.top != nil && CachedDialogCheckAccessibility.enabled("device-process-quit-confirm", in: root) == false
        }
        let presentationID = model.modals.top?.id
        if !mounted { print("DETAIL process-consent mounted-state " + CachedDialogCheckAccessibility.describe(window: window, coordinator: model.modals)) }
        check(mounted && inspection.requestID == request.id && model.modals.presentations.count == 1 && model.modals.top?.width == 470,
              "the mounted production process confirmation starts with its actual execute button disabled")
        inspection.consent?.wrappedValue = true
        let acknowledged = await CachedDialogCheckAccessibility.pump(window) { CachedDialogCheckAccessibility.enabled("device-process-quit-confirm", in: root) == true }
        check(acknowledged && inspection.consent?.wrappedValue == true && model.modals.top?.id == presentationID && inspection.requestID == request.id,
              "changing the mounted child's real acknowledgement Binding enables its native execute button within the same cached modal")
        inspection.consent?.wrappedValue = false
        let revoked = await CachedDialogCheckAccessibility.pump(window) { CachedDialogCheckAccessibility.enabled("device-process-quit-confirm", in: root) == false }
        check(revoked && inspection.consent?.wrappedValue == false && model.modals.top?.id == presentationID && inspection.requestID == request.id,
              "revoking the mounted child's real acknowledgement Binding disables execution without replacing the confirmation")
        check(executions.isEmpty && forceRequests == 0 && !model.device.isSampling,
              "mounted process-state checks never request a real or simulated process exit")
        model.modals.dismissTop()
        _ = await CachedDialogCheckAccessibility.pump(window) { model.modals.presentations.isEmpty && inspection.requestID == nil }
        let next = DeviceProcessActionRequest(name: application.name, processes: [process], mode: .quit, wholeApplication: true)
        present(next)
        let reopened = await CachedDialogCheckAccessibility.pump(window) {
            inspection.requestID == next.id && inspection.consent?.wrappedValue == false && CachedDialogCheckAccessibility.enabled("device-process-quit-confirm", in: root) == false
        }
        check(reopened && next.id != request.id && executions.isEmpty,
              "closing and remounting the production process confirmation requires fresh acknowledgement and preserves zero executions")
        model.modals.dismissTop()
        _ = await CachedDialogCheckAccessibility.pump(window) { model.modals.presentations.isEmpty && inspection.requestID == nil }
        return (count, failures)
        #else
        return (0, 0)
        #endif
    }
}

/// Shares the proven native modal host but owns a separate isolated device model.
/// Real ledger publications cannot alter the workbench fixture's device or route.
@MainActor enum NetworkRecordsDialogChecks {
    static func run(model: WorkbenchAppModel, window: NSWindow) async -> (count: Int, failures: Int) {
        #if DEBUG
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        guard let root = window.contentView, !model.modals.isPresented, !model.confirmingQuit else {
            check(false, "records-state checks require the already mounted isolated workbench without another modal")
            return (count, failures)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-cached-records-\(UUID().uuidString)")
        let notifications = RecordsDialogCheckNotifications()
        let device = DeviceStatusModel(dataDirectory: directory, notifications: notifications)
        let modalID = UUID(); var presented = true
        defer { presented = false; model.modals.remove(modalID); device.stop(); try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var accumulator = DeviceTrafficAccumulator(ledger: DeviceTrafficLedger(now: start, timeZone: TimeZone(secondsFromGMT: 0)!))
        accumulator.ingest(wifi: ["fake": .init(received: 100, sent: 100)], ethernet: [:], at: start, maximumGap: 6)
        accumulator.ingest(wifi: ["fake": .init(received: 1_234_100, sent: 234_100)], ethernet: [:], at: start.addingTimeInterval(2), maximumGap: 6)
        await device.evaluateMonitoringForChecks(snapshot: DeviceSnapshot(), ledger: accumulator.ledger, at: start.addingTimeInterval(2))
        let initial = DeviceTrafficDisplay.adaptive(device.trafficSummary.received)
        let dismiss = { presented = false; model.modals.remove(modalID) }
        model.modals.present(id: modalID, parentID: nil, width: 470,
            content: AnyView(NetworkRecordsDialog(model: device, dismiss: dismiss)), requestDismiss: dismiss,
            isStillPresented: { presented }, invalidate: { presented = false })
        let mounted = await CachedDialogCheckAccessibility.pump(window) {
            model.modals.top != nil && CachedDialogCheckAccessibility.text(prefix: "network-records-received-", in: root).contains(initial)
        }
        let identity = model.modals.top?.id
        if !mounted { print("DETAIL network-records mounted initial=\(initial) bytes=\(device.trafficSummary.received) text=\(CachedDialogCheckAccessibility.text(prefix: "network-records-received-", in: root)) " + CachedDialogCheckAccessibility.describe(window: window, coordinator: model.modals)) }
        check(mounted && model.modals.presentations.count == 1 && model.modals.top?.width == 470 && device.trafficSummary.received == 1_234_000,
              "the mounted production network records dialog shows the exact initial synthetic ledger reading")
        accumulator.ingest(wifi: ["fake": .init(received: 5_678_100, sent: 678_100)], ethernet: [:], at: start.addingTimeInterval(4), maximumGap: 6)
        await device.evaluateMonitoringForChecks(snapshot: DeviceSnapshot(), ledger: accumulator.ledger, at: start.addingTimeInterval(4))
        let updated = DeviceTrafficDisplay.adaptive(device.trafficSummary.received)
        let refreshed = await CachedDialogCheckAccessibility.pump(window) {
            let text = CachedDialogCheckAccessibility.text(prefix: "network-records-received-", in: root)
            return text.contains(updated) && !text.contains(initial)
        }
        if !refreshed { print("DETAIL network-records updated=\(updated) bytes=\(device.trafficSummary.received) text=\(CachedDialogCheckAccessibility.text(prefix: "network-records-received-", in: root)) " + CachedDialogCheckAccessibility.describe(window: window, coordinator: model.modals)) }
        check(refreshed && initial != updated && model.modals.top?.id == identity && model.modals.presentations.count == 1,
              "a real ledger publication refreshes the mounted production records text inside the same cached presentation")
        check(!device.isSampling && device.snapshot.sampledAt == nil && notifications.requests == 0 && notifications.deliveries == 0,
              "mounted network records checks use no sensors, permission prompts or notification deliveries")
        model.modals.dismissTop()
        let dismissed = await CachedDialogCheckAccessibility.pump(window) { model.modals.presentations.isEmpty && !presented }
        check(dismissed && device.trafficSummary.received == 5_678_000,
              "closing mounted refreshed network records leaves the measured ledger unchanged")
        return (count, failures)
        #else
        return (0, 0)
        #endif
    }
}

/// Called with the already isolated native-workbench fixture and its real shell.
/// It verifies both different non-nil messages in the same retained dialog.
@MainActor enum WorkbenchMessageRefreshChecks {
    static func run(model: WorkbenchAppModel, window: NSWindow) async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        guard let root = window.contentView, model.message == nil, !model.modals.isPresented else {
            check(false, "message refresh check requires the isolated shell without another active modal")
            return (count, failures)
        }
        defer { model.message = nil; model.modals.prune() }
        let first = "隔离检查：第一条错误", second = "隔离检查：稍后到达的第二条错误"
        model.message = first
        let mounted = await CachedDialogCheckAccessibility.pump(window) {
            model.modals.top != nil && CachedDialogCheckAccessibility.text(prefix: "workbench-status-message-text", in: root).contains(first)
        }
        let identity = model.modals.top?.id
        check(mounted && model.modals.presentations.count == 1,
              "the real workbench shell mounts its actual first status-message text")
        model.message = second
        let refreshed = await CachedDialogCheckAccessibility.pump(window) {
            let text = CachedDialogCheckAccessibility.text(prefix: "workbench-status-message-text", in: root)
            return text.contains(second) && !text.contains(first)
        }
        check(refreshed && model.modals.top?.id == identity && model.modals.presentations.count == 1,
              "replacing a non-nil error refreshes visible native text within the same cached message modal")
        model.modals.dismissTop()
        let dismissed = await CachedDialogCheckAccessibility.pump(window) { model.message == nil && !model.modals.isPresented }
        check(dismissed, "dismissing the refreshed status message clears the actual model message")
        return (count, failures)
    }
}

@MainActor private enum CachedDialogCheckAccessibility {
    static func element(prefix: String, role: NSAccessibility.Role? = nil, in root: NSView) -> NSObject? {
        var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>()
        while let object = pending.popLast(), visited.count < 4_096 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               let identifier = object.value(forKey: "accessibilityIdentifier") as? String, identifier.hasPrefix(prefix) {
                if role == nil { return object }
                if object.responds(to: NSSelectorFromString("accessibilityRole")), object.value(forKey: "accessibilityRole") as? String == role?.rawValue { return object }
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return nil
    }
    static func enabled(_ identifier: String, in root: NSView) -> Bool? {
        guard let object = element(prefix: identifier, role: .button, in: root), object.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return nil }
        return object.value(forKey: "accessibilityEnabled") as? Bool
    }
    static func describe(window: NSWindow, coordinator: WorkbenchModalCoordinator) -> String {
        guard let root = window.contentView else { return "no-content-view" }
        var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>(), nodes: [String] = []
        while let object = pending.popLast(), visited.count < 4_096 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            func string(_ property: String) -> String {
                object.responds(to: NSSelectorFromString(property)) ? object.value(forKey: property) as? String ?? "" : ""
            }
            let identifier = string("accessibilityIdentifier"), role = string("accessibilityRole")
            if nodes.count < 28 && (!identifier.isEmpty || role == NSAccessibility.Role.button.rawValue || role == NSAccessibility.Role.checkBox.rawValue) {
                nodes.append("\(type(of:object)) id=\(identifier) role=\(role) label=\(string("accessibilityLabel")) value=\(string("accessibilityValue"))")
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return "policy=\(NSApp.activationPolicy().rawValue) visible=\(window.isVisible) root=\(NSStringFromRect(root.frame)) presentations=\(coordinator.presentations.count) top=\(coordinator.top?.id.uuidString ?? "nil") visited=\(visited.count) nodes=[\(nodes.joined(separator:" | "))]"
    }
    static func text(prefix: String, in root: NSView) -> String {
        var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>(), values: [String] = []
        while let object = pending.popLast(), visited.count < 4_096 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               let identifier = object.value(forKey: "accessibilityIdentifier") as? String, identifier.hasPrefix(prefix) {
                for property in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] where object.responds(to: NSSelectorFromString(property)) {
                    if let value = object.value(forKey: property) as? String { values.append(value) }
                }
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return values.joined(separator: " ")
    }
    @discardableResult static func pump(_ window: NSWindow, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return condition()
    }
}
@MainActor private final class RecordsDialogCheckNotifications: DeviceNotificationProviding {
    var requests = 0, deliveries = 0
    func permission() async -> DeviceNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { requests += 1; return false }
    func deliver(_ event: DeviceMonitoringEvent, budget: DeviceTrafficBudget, rule: DeviceTemperatureRule) async throws { deliveries += 1 }
}
