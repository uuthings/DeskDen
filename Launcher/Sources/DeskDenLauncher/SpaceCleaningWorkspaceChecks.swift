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
            // This hosts the complete module, including its page header and footer.
            // The 690/732-point fixtures additionally account for the production
            // window chrome and its asymmetric page gutters at 1120×758/1260×800.
            // 1040 points leaves about 639 points inside the configuration card,
            // just below its three-column range layout; 1120 covers the other side.
            for size in [NSSize(width: 1040, height: 690), NSSize(width: 1120, height: 690), NSSize(width: 1120, height: 700),
                         NSSize(width: 1260, height: 732), NSSize(width: 1260, height: 742),
                         NSSize(width: 900, height: 562), NSSize(width: 1440, height: 860), NSSize(width: 1600, height: 1000)] {
                window.setContentSize(size)
                _ = await settle(window) { frame("space-cleaning-start", host) != nil }
                let volume = frame("space-cleaning-volume-card", host)
                let start = frame("space-cleaning-start", host)
                check(volume != nil && start != nil && volume!.maxX < start!.minX,
                      "\(Int(size.width))-point preparation keeps disk and scan configuration in separate columns")
                check(start.map { window.frame.contains($0) } == true, "\(Int(size.width))-point preparation keeps the scan action visible")
                let geometry = preparationGeometryChecks(host, window: window, allowsVerticalScrolling: size.height == 562)
                count += geometry.count; failures += geometry.failures
                let captureSize = [690, 732].contains(Int(size.height)) ? "\(Int(size.width))x\(Int(size.height))" : "\(Int(size.width))"
                try await capture(host, "cleanup-home-\(captureSize)-light.png")
            }
            try await capture(host, "cleanup-home-light.png")
            host.rootView = fixture(model: model, light: false)
            _ = await settle(window) { frame("space-cleaning-start", host) != nil }
            check(frame("space-cleaning-start", host).map { window.frame.contains($0) } == true,
                  "dark preparation keeps the same fixed action geometry")
            try await capture(host, "cleanup-home-dark.png")
            host.rootView = fixture(model: model, light: true)
            _ = await settle(window) { frame("space-cleaning-scope-tile-documents", host) != nil }
            let regularSize = host.bounds.size
            for size in [NSSize(width: 1120, height: 690), NSSize(width: 1260, height: 732)] {
                window.setContentSize(size)
                _ = await settle(window) { frame("space-cleaning-mode-largeFiles", host) != nil }
                check(click("space-cleaning-mode-largeFiles", host),
                      "\(Int(size.width))-point preparation opens large-file mode through its real button")
                check(await settle(window) { model.scanMode == .largeFiles && frame("space-cleaning-large-file-options", host) != nil },
                      "\(Int(size.width))-point preparation mounts the large-file settings")
                let geometry = preparationGeometryChecks(host, window: window, allowsVerticalScrolling: false,
                    additionalConfigurationIDs: ["space-cleaning-large-file-options", "space-cleaning-preset-100",
                        "space-cleaning-preset-500", "space-cleaning-preset-1gb", "space-cleaning-minimum-size",
                        "space-cleaning-maximum-size", "space-cleaning-size-unit"])
                count += geometry.count; failures += geometry.failures
                try await capture(host, "cleanup-home-large-files-\(Int(size.width))x\(Int(size.height))-light.png")
                check(click("space-cleaning-mode-cleanup", host),
                      "\(Int(size.width))-point preparation restores regular mode through its real button")
                check(await settle(window) { model.scanMode == .cleanup && frame("space-cleaning-large-file-options", host) == nil },
                      "\(Int(size.width))-point preparation removes large-file options after returning to regular mode")
            }
            // Keep later interaction checks independent if a mode click failed.
            model.selectScanMode(.cleanup)
            window.setContentSize(regularSize)
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
            check(model.historyReturnTitle == "返回处理结果", "history opened from a completion page names that page as its return")
            model.returnFromHistory()
            check(model.screen == .completed && !model.requiresRescan,
                  "return from processed history reopens its completion page without forcing a rescan")
        } catch { check(false, "workspace fixture: \(error)") }
        let capacities = await capacityFixtureChecks()
        return (count + capacities.count, failures + capacities.failures)
    }

    private static func preparationGeometryChecks(_ host: NSView, window: NSWindow, allowsVerticalScrolling: Bool,
                                                  additionalConfigurationIDs: [String] = []) -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        let variant = "\(Int(host.bounds.width))×\(Int(host.bounds.height))-point preparation"
        func check(_ condition: Bool, _ label: String) {
            count += 1; if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(variant) \(label)")
        }
        guard let volume = frame("space-cleaning-volume-card", host),
              let configuration = frame("space-cleaning-configuration-card", host) else {
            check(false, "mounts both complete card surfaces for viewport measurements")
            return (count, failures)
        }
        let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
        let scrolls = visibleScrollViews(in: host)
        let clips = scrolls.map { window.convertToScreen($0.contentView.convert($0.contentView.bounds, to: nil)) }
        let leftClips = clips.filter { volume.insetBy(dx: -1, dy: -1).contains($0) && $0.width > volume.width * 0.7 }
        let rightClips = clips.filter { configuration.insetBy(dx: -1, dy: -1).contains($0) && $0.width > configuration.width * 0.7 }
        let capacityIDs = ["space-cleaning-home-heading", "space-cleaning-disk-occupancy",
                           "space-cleaning-disk-available-breakdown", "space-cleaning-disk-capacity-note", "space-cleaning-disk-updated-at"]
            + ["total", "used", "free", "reclaimable", "available"].flatMap { row in
                ["label", "value", "unit"].map { "space-cleaning-disk-" + row + "-" + $0 }
            }
        let configurationIDs = SpaceCleaningScanMode.allCases.map { "space-cleaning-mode-" + $0.rawValue }
            + CleaningScopeGroup.allCases.map { "space-cleaning-scope-tile-" + $0.rawValue }
            + ["space-cleaning-scope-global", "space-cleaning-scope-custom", "space-cleaning-scope-detail",
               "space-cleaning-scope-detail-title", "space-cleaning-scope-detail-inclusion"]
            + additionalConfigurationIDs
        func contained(_ identifiers: [String], in area: NSRect, clips: [NSRect], vertically: Bool) -> Bool {
            identifiers.allSatisfy { identifier in
                guard let rect = frame(identifier, host) else {
                    print("DETAIL \(variant) missing content=\(identifier)")
                    return false
                }
                let regions = [area, viewport] + clips
                let fits = regions.allSatisfy { region in
                    rect.minX >= region.minX - 1 && rect.maxX <= region.maxX + 1
                        && (!vertically || (rect.minY >= region.minY - 1 && rect.maxY <= region.maxY + 1))
                }
                if !fits { print("DETAIL \(variant) clipped content=\(identifier) frame=\(rect) card=\(area) clips=\(clips)") }
                return fits
            }
        }
        check(viewport.insetBy(dx: -1, dy: -1).contains(volume) && viewport.insetBy(dx: -1, dy: -1).contains(configuration)
                && volume.maxX < configuration.minX,
              "keeps both cards inside the module viewport without overlap")
        check(contained(["space-cleaning-home-actions", "space-cleaning-start"], in: configuration, clips: [], vertically: true)
                && contained(["space-cleaning-rules-link"], in: viewport, clips: [], vertically: true),
              "keeps the complete scan footer and page rules action visible")
        check(!scrolls.isEmpty && scrolls.allSatisfy {
            guard let document = $0.documentView else { return false }
            return document.bounds.width <= $0.contentView.bounds.width + 1
        }, "has no horizontal scroll range in any actual scroll document")
        if allowsVerticalScrolling {
            // The deliberately short window may scroll, but must preserve all
            // mounted content widths and the fixed action. Lazy range rows
            // below this viewport need not have accessibility elements yet.
            let mountedConfigurationIDs = configurationIDs.filter { frame($0, host) != nil }
            check(contained(capacityIDs, in: volume, clips: leftClips, vertically: false)
                    && !mountedConfigurationIDs.isEmpty
                    && contained(mountedConfigurationIDs, in: configuration, clips: rightClips, vertically: false),
                  "keeps narrow-window content within its card widths while allowing vertical scrolling")
        } else {
            check(scrolls.allSatisfy {
                guard let document = $0.documentView else { return false }
                return document.bounds.height <= $0.contentView.bounds.height + 1
            }, "fits every actual scroll document vertically without a hidden scroll range")
            check(contained(capacityIDs, in: volume, clips: leftClips, vertically: true),
                  "shows every capacity row, composition, explanation and update inside the left card viewport")
            check(contained(configurationIDs, in: configuration, clips: rightClips, vertically: true),
                  "shows both scan modes, all six ranges and the complete explanation inside the right card viewport")
        }
        for (scroll, clip) in zip(scrolls, clips) {
            let region = volume.insetBy(dx: -1, dy: -1).contains(clip) ? "capacity" : configuration.insetBy(dx: -1, dy: -1).contains(clip) ? "configuration" : "page"
            print("DETAIL \(variant) \(region) document=\(String(describing: scroll.documentView?.bounds)) clip=\(scroll.contentView.bounds) screen=\(clip)")
        }
        return (count, failures)
    }

    private static func visibleScrollViews(in root: NSView) -> [NSScrollView] {
        var pending = [root], result: [NSScrollView] = []
        while let view = pending.popLast() {
            pending.append(contentsOf: view.subviews)
            if let scroll = view as? NSScrollView, scroll.window === root.window,
               !scroll.isHiddenOrHasHiddenAncestor, scroll.documentView != nil,
               scroll.contentView.bounds.width > 0, scroll.contentView.bounds.height > 0 {
                result.append(scroll)
            }
        }
        return result
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
