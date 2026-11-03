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
            for size in [NSSize(width: 1120, height: 700), NSSize(width: 900, height: 562), NSSize(width: 1440, height: 860)] {
                window.setContentSize(size)
                _ = await settle(window) { frame("space-cleaning-start", host) != nil }
                let volume = frame("space-cleaning-volume-card", host)
                let start = frame("space-cleaning-start", host)
                check(volume != nil && start != nil && volume!.maxX < start!.minX,
                      "\(Int(size.width))-point preparation keeps disk and scan configuration in separate columns")
                check(start.map { window.frame.contains($0) } == true, "\(Int(size.width))-point preparation keeps the scan action visible")
            }
            try await capture(host, "cleanup-home-light.png")
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
        return (count, failures)
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
