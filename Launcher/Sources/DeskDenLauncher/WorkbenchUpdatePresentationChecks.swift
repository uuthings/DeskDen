import AppKit
import Combine
import SwiftUI

/// A single mounted window exercises the production entry, dialog and shared
/// modal host. Offers are local fixtures; no engine, network or install is started.
@MainActor enum WorkbenchUpdatePresentationChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") update presentation: \(message)")
        }
        let suite = "test.deskden-update-presentation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check(false, "isolated preferences are available"); return (count, failures)
        }
        let information: [String: Any] = [
            "SUFeedURL": "https://example.invalid/appcast.xml",
            "SUPublicEDKey": Data(repeating: 0, count: 32).base64EncodedString(),
            "SUEnableAutomaticChecks": true, "SUAutomaticallyUpdate": false,
            "SUAllowsAutomaticUpdates": false, "SUVerifyUpdateBeforeExtraction": true,
            "SURequireSignedFeed": true
        ]
        let updates = AppUpdateController(defaults: defaults, information: information,
                                          allowsStarting: false, observesSystemEvents: false)
        let state = UpdatePresentationFixtureState(), modals = WorkbenchModalCoordinator()
        let window = NativeUIFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 758),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "隔离更新界面检查"; window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear
        let host = NSHostingView(rootView: UpdatePresentationFixtureRoot(updates: updates, state: state, modals: modals).nativeCheckAccessibility())
        host.frame = window.contentLayoutRect; host.autoresizingMask = [.width, .height]
        window.contentView = host; modals.hostWindow = window; window.center()
        let previousApplication = NSWorkspace.shared.frontmostApplication, previousPolicy = NSApp.activationPolicy()
        defer {
            updates.dismissDialog(); modals.clear()
            window.orderOut(nil); window.contentView = nil; window.close()
            defaults.removePersistentDomain(forName: suite)
            NSApp.setActivationPolicy(previousPolicy)
            if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication?.activate(options: []) }
        }
        var downloadChoices = 0
        let shortRelease = release(notes: [.init(title: "启动器悬停反馈", detail: "图标与按键框轻微上浮、放大，移开后恢复。")])
        updates.offerUpdate(shortRelease, userInitiated: false) { _ in downloadChoices += 1 }
        guard await NativeUIFixtureWindow.prepare(window: window, until: { frame("updates-sidebar-entry", in: host) != nil }) else {
            check(false, "production entry mounts its accessibility tree"); return (count, failures)
        }
        let entryFrame = frame("updates-sidebar-entry", in: host)
        check(entryFrame.map { $0.height >= 31 && $0.height <= 40 && $0.width <= 160.5 } == true
              && !updates.isDialogPresented && modals.presentations.isEmpty,
              "a background offer creates one compact single-line entry without opening a dialog")
        check(press("updates-sidebar-entry", in: host), "the real sidebar entry opens the update dialog")
        check(await settle(window) { modals.presentations.count == 1 && frame("updates-dialog", in: host).map { abs($0.width - 520) < 2 } == true },
              "release notes mount at the accepted 520-point width")
        let identity = modals.top?.id
        // SwiftUI's AX group omits decorative top/bottom padding. Measure the
        // actual native material surface for the dialog's full outer height.
        _ = await settle(window) {
            materialFrame(in: host).map { $0.height > 210 && $0.height < 310 } == true
        }
        let shortFrame = materialFrame(in: host)
        print("DETAIL update short dialog frame=\(String(describing: shortFrame))")
        check(shortFrame.map { $0.height > 210 && $0.height < 310 } == true,
              "a short release note shrinks the dialog to its natural height")
        save(host, name: "update-short-dark.png")

        check(pressLabel("稍后", in: host), "the actual later button dismisses without discarding the offer")
        check(await settle(window) { !updates.isDialogPresented && modals.presentations.isEmpty && frame("updates-sidebar-entry", in: host) != nil },
              "later keeps the version entry available")
        _ = press("updates-sidebar-entry", in: host)
        _ = await settle(window) { frame("updates-download", in: host) != nil }
        let activeIdentity = modals.top?.id
        check(identity != nil && activeIdentity != nil, "reopening uses the same retained update session")
        check(press("updates-download", in: host) && downloadChoices == 1,
              "the production download button submits one explicit choice")
        updates.downloadStarted(cancellation: {})
        updates.downloadExpected(48_600_000); updates.downloadReceived(12_150_000)
        check(await settle(window) { modals.top?.id == activeIdentity && modals.presentations.count == 1 && frame("updates-dialog", in: host).map { abs($0.width - 420) < 2 } == true },
              "downloading changes the existing dialog to 420 points without stacking or recreating it")
        check(updates.progress == 0.25 && text("updates-task-status", in: host).contains("正在下载"),
              "the mounted compact task follows the live download state")
        save(host, name: "update-downloading-dark.png")
        _ = press("updates-dialog-close", in: host)
        _ = await settle(window) { modals.presentations.isEmpty }
        updates.downloadReceived(12_150_000)
        check(press("updates-sidebar-entry", in: host), "the single-line entry reopens an ongoing download")
        check(await settle(window) { frame("updates-dialog", in: host).map { abs($0.width - 420) < 2 } == true && updates.progress == 0.5 },
              "closing and reopening preserves download progress")
        let downloadingIdentity = modals.top?.id
        updates.readyToInstall { _ in }
        check(await settle(window) { modals.top?.id == downloadingIdentity && modals.presentations.count == 1 && frame("updates-dialog", in: host).map { abs($0.width - 520) < 2 } == true && frame("updates-install", in: host) != nil },
              "ready-to-install restores 520-point notes with a separate install action")

        let longNotes = (1...16).map { AppUpdateReleaseNote(title: "更新条目 \($0)", detail: "这是一条隔离的更新说明，用于验证长内容可滚动，正文不会挤压底部操作。") }
        updates.offerUpdate(release(notes: longNotes), userInitiated: false) { _ in }
        for sample in [(1120, 758, false, "regular-dark"), (900, 620, true, "narrow-light")] {
            state.light = sample.2; window.setContentSize(NSSize(width: CGFloat(sample.0), height: CGFloat(sample.1)))
            _ = await settle(window) { bodyScroll(in: host).map { ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 30 } == true }
            guard let scroll = bodyScroll(in: host), let document = scroll.documentView,
                  let dialog = materialFrame(in: host), let footerBefore = frame("updates-download", in: host) else {
                check(false, "\(sample.3) mounts the real scroll body and footer"); continue
            }
            let screenBounds = window.convertToScreen(host.convert(host.bounds, to: nil))
            check(dialog.height <= 522 && screenBounds.contains(dialog) && document.bounds.height > scroll.contentSize.height,
                  "\(sample.3) constrains long notes while retaining all content")
            let offset = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height) : document.bounds.minY
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset)); scroll.reflectScrolledClipView(scroll.contentView)
            _ = await settle(window) { abs(scroll.contentView.bounds.origin.y - offset) < 1 }
            let visibleBody = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
            let last = labeledFrames("更新条目 16", in: host).first { visibleBody.insetBy(dx: -1, dy: -1).contains($0) }
            check(last != nil && frame("updates-download", in: host) == footerBefore && screenBounds.contains(footerBefore),
                  "\(sample.3) reveals the last note without moving or clipping the footer")
            check(scroll.scrollerStyle == .overlay && abs(scroll.contentSize.width - scroll.bounds.width) < 1,
                  "\(sample.3) uses the shared overlay scrollbar without narrowing the document")
            save(host, name: "update-long-\(sample.3).png")
        }
        let retainedIdentity = modals.top?.id
        window.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(70))
        check(modals.top?.id == retainedIdentity && updates.isDialogPresented,
              "hiding the host window retains the existing update presentation")
        check(await NativeUIFixtureWindow.prepare(window: window, until: { frame("updates-download", in: host) != nil }),
              "showing the same host restores its existing controls")
        _ = press("updates-dialog-close", in: host)
        check(await settle(window) { modals.presentations.isEmpty && frame("updates-sidebar-entry", in: host) != nil },
              "closing the final dialog leaves only the version entry")
        check(defaults.persistentDomain(forName: suite)?.isEmpty != false && downloadChoices == 1,
              "UI checks never start an updater, install anything or change real preferences")
        return (count, failures)
    }

    private static func release(notes: [AppUpdateReleaseNote]) -> AppUpdateRelease {
        .init(version: "0.2.1", publishedAt: Date(timeIntervalSince1970: 1_793_347_200), notes: notes,
              downloadSize: 48_600_000, informationURL: nil, informationOnly: false)
    }
    private static func settle(_ window: NSWindow, until predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if predicate() {
                try? await Task.sleep(for: .milliseconds(50)); window.contentView?.layoutSubtreeIfNeeded()
                if predicate() { return true }
            }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return predicate()
    }
    private static func objects(in root: NSObject) -> [NSObject] {
        var pending = [root], seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        while let object = pending.popLast(), seen.count < 16_384 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }; result.append(object)
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return result
    }
    private static func value(_ key: String, of object: NSObject) -> String {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) as? String ?? "" : ""
    }
    private static func rect(_ object: NSObject) -> NSRect? {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")), let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        let rect = value.rectValue
        return rect.width > 0 && rect.height > 0 && rect.width.isFinite && rect.height.isFinite ? rect : nil
    }
    private static func frame(_ identifier: String, in host: NSView) -> NSRect? {
        objects(in: host).filter { value("accessibilityIdentifier", of: $0) == identifier }.compactMap(rect).max { $0.width * $0.height < $1.width * $1.height }
    }
    private static func materialFrame(in host: NSView) -> NSRect? {
        objects(in: host).compactMap { $0 as? NSVisualEffectView }.compactMap { view -> NSRect? in
            guard !view.isHiddenOrHasHiddenAncestor, abs(view.bounds.width - 520) < 2, let window = view.window else { return nil }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }.max { $0.height < $1.height }
    }
    private static func text(_ identifier: String, in host: NSView) -> String {
        objects(in: host).filter { value("accessibilityIdentifier", of: $0) == identifier }.flatMap { objects(in: $0) }
            .flatMap { [value("accessibilityLabel", of: $0), value("accessibilityValue", of: $0)] }.joined(separator: " ")
    }
    private static func labeledFrames(_ label: String, in host: NSView) -> [NSRect] {
        objects(in: host).filter { value("accessibilityLabel", of: $0).contains(label) || value("accessibilityValue", of: $0).contains(label) }.compactMap(rect)
    }
    private static func press(_ identifier: String, in host: NSView) -> Bool {
        performPress(objects(in: host).first { value("accessibilityIdentifier", of: $0) == identifier && $0.responds(to: NSSelectorFromString("accessibilityPerformPress")) })
    }
    private static func pressLabel(_ label: String, in host: NSView) -> Bool {
        performPress(objects(in: host).first { value("accessibilityLabel", of: $0) == label && $0.responds(to: NSSelectorFromString("accessibilityPerformPress")) })
    }
    private static func performPress(_ object: NSObject?) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let object else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
    private static func bodyScroll(in host: NSView) -> NSScrollView? {
        objects(in: host).compactMap { $0 as? NSScrollView }.first {
            !$0.isHiddenOrHasHiddenAncestor && $0.documentView != nil && abs($0.bounds.width - 520) < 2
        }
    }
    private static func save(_ host: NSView, name: String) {
        guard let path = ProcessInfo.processInfo.environment["DESKDEN_UPDATE_OUTPUT"],
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch { print("DETAIL update screenshot was not saved: \(error.localizedDescription)") }
    }
}

@MainActor private final class UpdatePresentationFixtureState: ObservableObject {
    @Published var light = false
}
private struct UpdatePresentationFixtureRoot: View {
    @ObservedObject var updates: AppUpdateController
    @ObservedObject var state: UpdatePresentationFixtureState
    @ObservedObject var modals: WorkbenchModalCoordinator
    var body: some View {
        ZStack(alignment: .leading) {
            WorkbenchSceneBackground(theme: .qingbiMist, motionEnabled: false, active: false)
            HStack(spacing: 0) {
                VStack {
                    Text("方寸").font(.system(size: 12, weight: .medium)).padding(.top, 22)
                    Spacer()
                    UpdatePresentationFixtureEntry(updates: updates)
                }.padding(.horizontal, 12).padding(.bottom, 15).frame(width: 184)
                    .background(WorkbenchMaterialSurface(kind: .sidebar, radius: 0))
                Spacer()
            }.blur(radius: modals.isPresented ? 8 : 0).disabled(modals.isPresented)
                .accessibilityHidden(modals.isPresented)
            WorkbenchModalHost(coordinator: modals)
            WorkbenchUpdatePresentation(updates: updates)
        }.environment(\.workbenchModals, modals)
            .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.7, backgroundMotion: false, appearance: state.light ? .light : .dark)
    }
}

/// The former sidebar entry, kept only as this check's trigger: production shows
/// the update entry in the top bar (现行规范 9.4, X1).
private struct UpdatePresentationFixtureEntry: View {
    @ObservedObject var updates: AppUpdateController
    @Environment(\.workbenchPalette) private var palette
    private var title: String {
        switch updates.phase {
        case .downloading: "正在下载更新"
        case .extracting: "正在准备更新"
        case .readyToInstall: "待安装 v" + (updates.release?.version ?? "")
        case .installing: "正在安装更新"
        default: "新版本 v" + (updates.release?.version ?? "")
        }
    }
    var body: some View {
        if updates.release != nil {
            Button(action: updates.showUpdateDialog) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 13)).accessibilityHidden(true)
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }.frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .background(WorkbenchMaterialSurface(kind: .control, radius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.accent.opacity(0.4)))
            }.buttonStyle(WBSelectableButtonStyle(cornerRadius: 8, drawsSelection: false))
                .foregroundStyle(palette.accent).padding(.top, 6)
                .accessibilityLabel(title).accessibilityHint("打开软件更新窗口")
                .accessibilityIdentifier("updates-sidebar-entry")
        }
    }
}
