import AppKit
import SwiftUI
import LauncherCore

/// Focused checks for the cleaning workspace. Scans and transactions use a
/// disposable home and an injected Trash, never the user's files or Trash.
@MainActor enum SpaceCleaningWorkspaceChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("deskden-cleaning-workspace-" + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            guard let root = SpaceCleaningScanner.canonicalURL(root) else { throw FixtureError.missing }
            let home = root.appendingPathComponent("Home")
            for index in 0..<36 {
                let file = home.appendingPathComponent("Downloads/review-\(index).txt")
                try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x41, count: 1024 * (index + 1)).write(to: file)
            }
            let model = SpaceCleaningModel(dataDirectory: root.appendingPathComponent("State"), homeDirectory: home,
                mover: WorkspaceTrash(root: root, destination: root.appendingPathComponent("Trash")))
            await model.waitUntilIdle()
            let host = NSHostingView(rootView: fixture(model: model, light: true))
            let window = NativeUIFixtureWindow(contentRect: NSRect(x: 80, y: 80, width: 1120, height: 700),
                styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            check(await NativeUIFixtureWindow.prepare(window: window, until: { frame("space-cleaning-start", host) != nil }),
                  "production cleaning preparation mounts with its real controls")
            check(model.items.isEmpty && !model.isBusy, "preparation never starts a scan implicitly")
            for size in [NSSize(width: 1120, height: 700), NSSize(width: 900, height: 562), NSSize(width: 1440, height: 860), NSSize(width: 1600, height: 1000)] {
                window.setContentSize(size)
                _ = await settle(window) { frame("space-cleaning-start", host) != nil }
                let volume = frame("space-cleaning-volume-card", host)
                let start = frame("space-cleaning-start", host)
                check(volume != nil && start != nil && volume!.maxX < start!.minX,
                      "\(Int(size.width))-point preparation keeps disk and scan configuration in separate columns")
                check(start.map { window.frame.contains($0) } == true, "\(Int(size.width))-point preparation keeps the scan action visible")
                try await capture(host, "cleanup-home-\(Int(size.width))-light.png")
            }
            try await capture(host, "cleanup-home-light.png")
            host.rootView = fixture(model: model, light: false)
            _ = await settle(window) { frame("space-cleaning-start", host) != nil }
            check(frame("space-cleaning-start", host).map { window.frame.contains($0) } == true,
                  "dark preparation keeps the same fixed action geometry")
            try await capture(host, "cleanup-home-dark.png")
            host.rootView = fixture(model: model, light: true)
            _ = await settle(window) { frame("space-cleaning-scope-tile-documents", host) != nil }
            let originalGroups = model.selectedScopeGroups
            check(click("space-cleaning-scope-tile-documents", host), "a real pointer press opens the document range explanation")
            check(await settle(window) { accessibilityText("space-cleaning-scope-detail-title", host).contains("文稿") },
                  "range-card selection updates the independent explanation")
            check(model.scopeChoice == .global && model.selectedScopeGroups == originalGroups && model.items.isEmpty,
                  "opening a global range explanation does not change scan scope or start a scan")
            check(click("space-cleaning-scope-custom", host), "the custom-range control receives a real pointer press")
            check(await settle(window) { model.screen == .scope && frame("space-cleaning-scope-toggle-downloads", host) != nil },
                  "custom scope editing exposes an independent range inclusion control")
            let detailBeforeToggle = accessibilityText("space-cleaning-scope-detail-title", host)
            let includedBeforeToggle = model.draftScopeGroups.contains(.downloads)
            check(click("space-cleaning-scope-toggle-downloads", host), "the download inclusion control receives a real pointer press")
            check(await settle(window) { model.draftScopeGroups.contains(.downloads) != includedBeforeToggle },
                  "a custom range toggle changes the draft inclusion")
            check(accessibilityText("space-cleaning-scope-detail-title", host) == detailBeforeToggle && model.scopeChoice == .global,
                  "toggling inclusion preserves the viewed explanation and does not commit the draft")
            let expectedGroups = model.draftScopeGroups
            check(click("space-cleaning-apply-scope", host), "custom range selection saves through its real button")
            check(await settle(window) { model.screen == .start && model.scopeChoice == .custom && model.selectedScopeGroups == expectedGroups },
                  "saving the custom draft commits the selected real scanner groups")
            check(click("space-cleaning-scope-global", host), "the global scope control restores the full fixture scan")
            check(await settle(window) { model.screen == .start && model.scopeChoice == .global },
                  "range interaction leaves the subsequent thirty-six-file scan in its original global mode")
            // A failed pointer assertion must not contaminate the independent
            // scanner/transaction checks that follow this interaction batch.
            if model.screen == .scope { model.cancelScope() }
            model.selectScope(.global)
            window.setContentSize(NSSize(width: 900, height: 562))
            model.selectScanMode(.largeFiles)
            _ = await settle(window) { frame("space-cleaning-large-file-options", host) != nil }
            check(frame("space-cleaning-start", host).map { window.frame.contains($0) } == true,
                  "large-file options keep the scan action visible in the narrow workspace")
            model.editScope(custom: true)
            model.addDraftDirectories([home.appendingPathComponent("Downloads")])
            _ = await settle(window) { frame("space-cleaning-apply-scope", host) != nil }
            check(frame("space-cleaning-apply-scope", host).map { window.frame.contains($0) } == true,
                  "custom scope editing keeps its save action visible")
            model.cancelScope(); model.selectScanMode(.cleanup)
            model.startScan(); await model.waitUntilIdle()
            check(model.screen == .results && model.items.count == 36 && model.detailID == nil,
                  "real fixture scan opens results with the sidebar collapsed")
            model.showResults(.reviewable)
            _ = await settle(window) { frame("space-cleaning-result-list", host) != nil }
            guard let item = model.visibleItems.first else { throw FixtureError.missing }
            for size in [NSSize(width: 1120, height: 700), NSSize(width: 900, height: 562), NSSize(width: 1440, height: 860)] {
                window.setContentSize(size)
                model.showDetail(item.id)
                _ = await settle(window) { frame("space-cleaning-detail-scroll", host) != nil }
                let surface = frame("space-cleaning-detail-surface", host)
                let scroll = frame("space-cleaning-detail-scroll", host)
                let header = frame("space-cleaning-detail-header", host)
                let actions = frame("space-cleaning-detail-actions", host)
                let collapse = frame("space-cleaning-collapse-detail", host)
                check(surface != nil && scroll != nil && header != nil && actions != nil && collapse != nil,
                      "\(Int(size.width))-point detail exposes a separate header, scroll body, footer and collapse control")
                if let surface, let scroll, let header, let actions, let collapse {
                    check(abs(surface.maxX - scroll.maxX) <= 2 && scroll.height > 80,
                          "\(Int(size.width))-point detail scrollbar reaches the card's outer right edge")
                    check(header.minY >= scroll.maxY - 2 && actions.maxY <= scroll.minY + 2,
                          "\(Int(size.width))-point detail header and actions stay outside the scrolling body")
                    check(collapse.width <= 28 && collapse.height <= 28 && surface.maxX - collapse.maxX <= 15,
                          "\(Int(size.width))-point sidebar glyph stays compact and right aligned")
                }
                let footer = frame("space-cleaning-selection-footer", host)
                let action = frame("space-cleaning-cleanup", host)
                print("DETAIL result footer width=\(Int(size.width)) footer=\(String(describing: footer)) action=\(String(describing: action)) window=\(window.frame)")
                try await capture(host, "cleanup-details-\(Int(size.width)).png")
                check(footer != nil && action.map { footer!.insetBy(dx: -1, dy: -1).contains($0) && window.frame.contains($0) } == true,
                      "\(Int(size.width))-point result action remains in the fixed footer")
            }
            try await capture(host, "cleanup-details-light.png")
            check(click("space-cleaning-collapse-detail", host), "sidebar collapse control receives a real pointer press")
            check(await settle(window) { model.detailID == nil && frame("space-cleaning-detail-surface", host) == nil },
                  "sidebar collapse returns the list to its full width")
            model.showDetail(item.id); model.toggleItem(item.id)
            check(model.detailID == item.id && model.selectedIDs == [item.id], "selection and focused detail have independent identities")
            model.requestCleanup(); await model.waitUntilIdle()
            check(model.currentBatch?.items.count == 1 && model.currentBatch?.items.first?.bytes == item.bytes && model.currentBatch?.items.first?.state == .trashed,
                  "a real isolated transaction retains item size in its receipt")
            model.showHistory(); await model.waitUntilIdle()
            _ = await settle(window) { frame("space-cleaning-history-search", host) != nil }
            check(model.screen == .history && model.dialog == nil && frame("space-cleaning-history-search", host) != nil,
                  "history is a searchable child page rather than a modal")
            if let batch = model.batches.first, let record = batch.items.first {
                if frame("space-cleaning-history-original-path-" + record.id.uuidString, host) != nil {
                    _ = click("space-cleaning-history-expand-" + batch.id.uuidString, host)
                    _ = await settle(window) { frame("space-cleaning-history-original-path-" + record.id.uuidString, host) == nil }
                }
                check(click("space-cleaning-history-expand-" + batch.id.uuidString, host), "batch summary opens with its right-aligned disclosure control")
                check(await settle(window) { frame("space-cleaning-history-original-path-" + record.id.uuidString, host) != nil },
                      "expanded history exposes the recorded file and original path")
            }
            try await capture(host, "cleanup-history-light.png")
            host.rootView = fixture(model: model, light: false)
            _ = await settle(window) { frame("space-cleaning-history-search", host) != nil }
            try await capture(host, "cleanup-history-dark.png")
            model.returnFromHistory()
            check(model.screen == .start, "return from processed history respects the required fresh scan")
        } catch { check(false, "workspace fixture: \(error)") }
        let capacities = await capacityFixtureChecks()
        return (count + capacities.count, failures + capacities.failures)
    }

    private static func capacityFixtureChecks() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        let total: UInt64 = 994_700_000_000
        let available: UInt64 = 78_600_000_000
        let free: UInt64 = 42_300_000_000
        let reclaim: UInt64 = 36_300_000_000
        let host = NSHostingView(rootView: capacityFixture(total: total, available: available, free: free, reclaim: reclaim, light: true))
        let window = NativeUIFixtureWindow(contentRect: NSRect(x: 80, y: 80, width: 292, height: 680),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        check(await NativeUIFixtureWindow.prepare(window: window, until: { frame("space-cleaning-disk-used-value", host) != nil }),
              "value-only capacity fixture mounts without changing the live cleaning model")
        do {
            for light in [true, false] {
                for size in [NSSize(width: 292, height: 680), NSSize(width: 400, height: 800)] {
                    window.setContentSize(size)
                    host.rootView = capacityFixture(total: total, available: available, free: free, reclaim: reclaim, light: light)
                    let variant = "\(Int(size.width))-point \(light ? "light" : "dark") capacity"
                    _ = await settle(window) { frame("space-cleaning-disk-reclaimable-unit", host) != nil }
                    let rows = ["used", "free", "reclaimable"]
                    let labels = rows.compactMap { frame("space-cleaning-disk-" + $0 + "-label", host) }
                    let values = rows.compactMap { frame("space-cleaning-disk-" + $0 + "-value", host) }
                    let units = rows.compactMap { frame("space-cleaning-disk-" + $0 + "-unit", host) }
                    check(labels.count == 3 && values.count == 3 && units.count == 3,
                          variant + " exposes three separate label, number and unit columns")
                    if labels.count == 3, values.count == 3, units.count == 3 {
                        check(spread(labels.map(\.minX)) <= 1.5 && spread(values.map(\.maxX)) <= 1.5 && spread(units.map(\.maxX)) <= 1.5,
                              variant + " aligns labels left and numbers and units right")
                        check((0..<3).allSatisfy { index in
                            labels[index].maxX <= values[index].minX && values[index].maxX <= units[index].minX
                                && abs(labels[index].minY - units[index].minY) <= 4
                                && abs(values[index].minY - units[index].minY) <= 6
                                && window.frame.contains(labels[index]) && window.frame.contains(values[index]) && window.frame.contains(units[index])
                        }, variant + " keeps every label, number and GB unit on one visible baseline without overlap")
                        check(labels[0].minY > labels[1].maxY && labels[1].minY > labels[2].maxY,
                              variant + " keeps used, immediately free and reclaimable rows in their approved order")
                        print("DETAIL \(variant) labels=\(labels) values=\(values) units=\(units)")
                    }
                    let usedSegment = frame("space-cleaning-disk-segment-used", host)
                    let freeSegment = frame("space-cleaning-disk-segment-free", host)
                    let reclaimSegment = frame("space-cleaning-disk-segment-reclaimable", host)
                    check(usedSegment != nil && freeSegment != nil && reclaimSegment != nil, variant + " exposes all three measured capacity segments")
                    if let usedSegment, let freeSegment, let reclaimSegment {
                        let height = usedSegment.height + freeSegment.height + reclaimSegment.height
                        // AppKit AX frames use bottom-up screen coordinates.
                        check(abs(usedSegment.maxY - reclaimSegment.minY) <= 1.5 && abs(reclaimSegment.maxY - freeSegment.minY) <= 1.5
                                && usedSegment.minY < reclaimSegment.minY && reclaimSegment.minY < freeSegment.minY,
                              variant + " places used capacity at the bottom and immediately free capacity at the top")
                        check(height > 0 && abs(usedSegment.height / height - CGFloat(Double(total - available) / Double(total))) <= 0.006
                                && abs(freeSegment.height / height - CGFloat(Double(free) / Double(total))) <= 0.006
                                && abs(reclaimSegment.height / height - CGFloat(Double(reclaim) / Double(total))) <= 0.006,
                              variant + " preserves the measured segment proportions instead of enlarging small bands")
                        print("DETAIL \(variant) used=\(usedSegment) reclaim=\(reclaimSegment) free=\(freeSegment)")
                    }
                    check(accessibilityText("space-cleaning-disk-percentage", host).contains("92%"), variant + " displays the real ninety-two-percent warning reading")
                    try await capture(host, "cleanup-capacity-\(Int(size.width))-\(light ? "light" : "dark").png")
                }
            }
            window.setContentSize(NSSize(width: 292, height: 680))
            host.rootView = capacityFixture(total: total, available: free, free: free, reclaim: nil, light: true)
            _ = await settle(window) { accessibilityText("space-cleaning-disk-reclaimable-value", host).contains("—") }
            check(accessibilityText("space-cleaning-disk-reclaimable-value", host).contains("—")
                    && frame("space-cleaning-disk-segment-reclaimable", host) == nil
                    && accessibilityText("space-cleaning-disk-capacity-note", host).contains("未提供按需回收估算"),
                  "missing reclaimable estimate remains unknown with an explicit fallback explanation")
            check(accessibilityText("space-cleaning-disk-available-value", host).contains("42.3"),
                  "missing reclaimable estimate uses the actual immediately free amount without adding a fabricated estimate")
            try await capture(host, "cleanup-capacity-unknown.png")
            host.rootView = capacityFixture(total: total, available: 0, free: 0, reclaim: 0, light: false)
            _ = await settle(window) { accessibilityText("space-cleaning-disk-percentage", host).contains("100%") }
            check(accessibilityText("space-cleaning-disk-available-value", host).contains("0")
                    && accessibilityText("space-cleaning-disk-reclaimable-value", host).contains("0")
                    && accessibilityText("space-cleaning-disk-percentage", host).contains("100%")
                    && frame("space-cleaning-disk-segment-used", host) != nil
                    && frame("space-cleaning-disk-segment-free", host) == nil && frame("space-cleaning-disk-segment-reclaimable", host) == nil,
                  "measured zero availability stays zero with a full used band and no false free-space band")
            try await capture(host, "cleanup-capacity-zero.png")
        } catch { check(false, "capacity fixture: \(error)") }
        return (count, failures)
    }

    private static func capacityFixture(total: UInt64?, available: UInt64?, free: UInt64?, reclaim: UInt64?, light: Bool) -> some View {
        SpaceCleaningCapacityCard(total: total, available: available, immediatelyFree: free, reclaimableEstimate: reclaim,
            volumeName: "Fixture Volume", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
            .background(WorkbenchFluidBackground())
            .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.7, backgroundMotion: false, appearance: light ? .light : .dark)
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            .nativeCheckAccessibility()
    }

    private static func spread(_ values: [CGFloat]) -> CGFloat { (values.max() ?? 0) - (values.min() ?? 0) }

    private static func accessibilityText(_ identifier: String, _ root: NSView) -> String {
        var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>(), strings: [String] = []
        while let object = pending.popLast(), visited.count < 8192 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier {
                for selector in ["accessibilityLabel", "accessibilityValue"] where object.responds(to: NSSelectorFromString(selector)) {
                    if let value = object.value(forKey: selector) as? String { strings.append(value) }
                }
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return strings.joined(separator: " ")
    }

    private static func fixture(model: SpaceCleaningModel, light: Bool) -> some View {
        SpaceCleaningModuleView(model: model).padding(24)
            .background(WorkbenchFluidBackground())
            .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.7, backgroundMotion: false, appearance: light ? .light : .dark)
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            .nativeCheckAccessibility()
    }

    private static func settle(_ window: NSWindow, until ready: () -> Bool) async -> Bool {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(2))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            // Measure final geometry after the production 240ms sidebar
            // transition, never an intermediate resize/animation frame.
            if ContinuousClock.now >= started.advanced(by: .milliseconds(320)), ready() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        } while ContinuousClock.now < deadline
        return ready()
    }

    private static func frame(_ identifier: String, _ root: NSView) -> NSRect? {
        var pending: [NSObject] = [root], visited = Set<ObjectIdentifier>(), frames: [NSRect] = []
        while let object = pending.popLast(), visited.count < 8192 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier,
               object.responds(to: NSSelectorFromString("accessibilityFrame")),
               let rect = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
               rect.width > 0, rect.height > 0 { frames.append(rect) }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return frames.max { $0.width * $0.height < $1.width * $1.height }
    }

    private static func click(_ identifier: String, _ host: NSView) -> Bool {
        guard let rect = frame(identifier, host), let window = host.window else { return false }
        let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        NSApp.postEvent(up, atStart: false); NSApp.sendEvent(down)
        return true
    }

    private static func capture(_ host: NSView, _ name: String) async throws {
        try? await Task.sleep(for: .milliseconds(100))
        try NativeUIFixtureAccessibility.saveView(host, name: name)
    }

    private enum FixtureError: Error { case missing }
    private struct WorkspaceTrash: SpaceCleaningFileOperating {
        let root: URL
        let destination: URL
        func moveToTrash(_ source: URL) throws -> URL {
            guard source.path.hasPrefix(root.path + "/"), destination.path.hasPrefix(root.path + "/") else { throw FixtureError.missing }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let target = destination.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: target)
            return target
        }
    }
}
