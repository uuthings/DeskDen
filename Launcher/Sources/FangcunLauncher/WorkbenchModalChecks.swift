import AppKit
import Combine
import LauncherCore
import SwiftUI

/// Exercises SwiftUI mounting, nested drafts and moving the same hosting view
/// between native windows, rather than only the coordinator's array operations.
@MainActor enum WorkbenchModalChecks {
    static func run() async -> (count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ message:String){count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") \(message)")}
        let fixture=ModalLifecycleFixture(),modals=WorkbenchModalCoordinator()
        let first=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
        let second=NSWindow(contentRect:first.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        for window in [first,second] {window.alphaValue=0;window.ignoresMouseEvents=true;window.isReleasedWhenClosed=false}
        let host=NSHostingView(rootView:ModalLifecycleRoot(fixture:fixture,modals:modals).nativeCheckAccessibility())
        first.contentView=host;modals.hostWindow=first;first.orderFront(nil)
        defer {modals.clear();first.orderOut(nil);second.orderOut(nil);first.contentView=nil;second.contentView=nil;fixture.readDraft=nil;fixture.writeDraft=nil}
        fixture.parent=true;await settle()
        check(modals.isPresented && modals.presentations.count == 1,"shared modal mounts an app-owned parent dialog")
        host.layoutSubtreeIfNeeded()
        let panels=descendants(host).compactMap{$0 as? NSVisualEffectView}.filter{abs($0.bounds.width-470)<1}
        check(!panels.isEmpty && panels.allSatisfy{$0.bounds.height>20 && $0.bounds.height<150},"shared modal material follows compact content instead of stretching to the window height")
        fixture.writeDraft?("synthetic unsaved draft")
        let identity=fixture.readDraft?().id
        fixture.child=true;await settle()
        check(modals.presentations.count == 2,"nested discard confirmation mounts above its draft")
        check(fixture.readDraft?().text == "synthetic unsaved draft" && fixture.readDraft?().id == identity,"opening nested confirmation retains parent view state and draft identity")
        fixture.child=false;await settle()
        check(modals.presentations.count == 1 && fixture.readDraft?().text == "synthetic unsaved draft","cancelling nested confirmation restores the existing parent draft")
        first.orderOut(nil);await settle()
        check(modals.isPresented && fixture.readDraft?().id == identity,"hiding native window preserves the modal and draft")
        first.contentView=nil;second.contentView=host;modals.hostWindow=second;second.orderFront(nil);await settle()
        check(fixture.readDraft?().id == identity && fixture.readDraft?().text == "synthetic unsaved draft","moving shared hosting view to another native window preserves draft identity")
        fixture.child=true;await settle();fixture.parent=false;modals.prune();await settle()
        check(!modals.isPresented && modals.presentations.isEmpty && !fixture.child,"closing parent also invalidates nested dialog bindings without leaving an orphan")
        fixture.parent=true;await settle()
        check(modals.presentations.count == 1 && !fixture.child,"reopening parent cannot resurrect a dismissed child confirmation")
        fixture.child=true;await settle();modals.clear();await settle()
        check(!fixture.parent && !fixture.child && !modals.isPresented,"shutting down shared modal host clears all live presentation bindings")
        return(count,failures)
    }
    private static func settle() async {try? await Task.sleep(for:.milliseconds(40))}
    private static func descendants(_ view:NSView)->[NSView] {view.subviews.flatMap{[$0]+descendants($0)}}
}
@MainActor private final class ModalLifecycleFixture:ObservableObject {
    @Published var parent=false
    @Published var child=false
    var readDraft:(()->(id:UUID,text:String))?
    var writeDraft:((String)->Void)?
}
private struct ModalLifecycleRoot:View {
    @ObservedObject var fixture:ModalLifecycleFixture
    @ObservedObject var modals:WorkbenchModalCoordinator
    var body:some View {
        ZStack {
            Text("Fixture").workbenchModal(isPresented:$fixture.parent) {ModalLifecycleEditor(fixture:fixture)}
            WorkbenchModalHost(coordinator:modals)
        }.environment(\.workbenchModals,modals).workbenchThemeEnvironment(theme:.arWorld,opacity:0.7,backgroundMotion:false)
    }
}
private struct ModalLifecycleEditor:View {
    @ObservedObject var fixture:ModalLifecycleFixture
    @State private var identity=UUID()
    @State private var text=""
    var body:some View {
        TextField("Synthetic draft",text:$text).padding(18)
            .onAppear {fixture.readDraft={ (identity,text) };fixture.writeDraft={text=$0}}
            .workbenchModal(isPresented:$fixture.child) {Text("Synthetic discard confirmation").padding(18)}
    }
}

/// Background-only appearance checks. These never order a window on screen,
/// activate the application, post input or read the user's saved preferences.
@MainActor enum WorkbenchAppearanceChecks {
    static func run() async -> Int {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let output = ProcessInfo.processInfo.environment["FANGCUN_APPEARANCE_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let output { try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for theme in LauncherTheme.allCases {
            for light in [false, true] {
                for opacity in [0.5, 0.7, 0.9] {
                    let palette = ThemePalette(theme: theme, opacity: opacity, light: light)
                    check(NSColor(palette.overlay) == NSColor(palette.surface), "floating surface uses card tint and opacity: \(theme.rawValue) / \(light) / \(opacity)")
                    let content = HStack(spacing: 20) {
                        Text("卡片").frame(width: 250, height: 160).background(WorkbenchMaterialSurface())
                        Text("弹窗").frame(width: 250, height: 160).background(WorkbenchMaterialSurface(kind: .panel))
                    }.foregroundStyle(palette.text).padding(30)
                        .background(WorkbenchSceneBackground(theme: theme, motionEnabled: false, active: false))
                        .workbenchThemeEnvironment(theme: theme, opacity: opacity, backgroundMotion: false, appearance: light ? .light : .dark)
                    let image = await capture(content, size: CGSize(width: 580, height: 220))
                    check(image != nil, "card and floating surface render offscreen")
                    if let output, let image, opacity == 0.7 {
                        try? image.write(to: output.appendingPathComponent("surfaces-\(theme.rawValue)-\(light ? "light" : "dark").png"))
                    }
                }
            }
        }
        for width: CGFloat in [340, 633, 900] {
            for x: CGFloat in [20, width / 2, width - 20] {
                for y: CGFloat in [0, 70, 140] {
                    let anchor = CGRect(x: x - 8, y: y, width: 16, height: 150 - y)
                    let p = WBChartCalloutPlacement(anchor: anchor, canvas: CGSize(width: width, height: 157), size: CGSize(width: 218, height: 112))
                    check(!p.frame.contains(p.tip) && p.tip == CGPoint(x: x, y: y) && p.frame.minX >= 0 && p.frame.maxX <= width && p.frame.minY >= 0 && p.frame.maxY <= 157,
                          "callout arrow points to its actual mark without covering it: \(width)/\(x)/\(y)")
                }
            }
        }
        let calendar = Calendar.current, now = Date()
        let snapshots = (0..<31).compactMap { offset -> AIQuotaSnapshot? in
            guard offset % 7 != 2, let date = calendar.date(byAdding: .day, value: -offset, to: now),
                  let window = try? AIQuotaWindow(usedPercent: Double((offset * 17) % 101), durationMinutes: 300, resetsAt: date.addingTimeInterval(18_000)) else { return nil }
            return AIQuotaSnapshot(provider: .codex, observedAt: date, source: .manual, shortWindow: window, weeklyWindow: nil)
        }
        let history = AIQuotaDailyHistory.build(snapshots, provider: .codex, now: now, calendar: calendar)
        let records = snapshots.enumerated().map { index, snapshot in
            AITokenRecord(id: String(index), provider: .codex, timestamp: snapshot.observedAt, model: "synthetic", tokens: .init(input: Int64(index * 127), output: Int64(index * 31)))
        }
        let tokens = AIDailyTokenHistory.totals(records, provider: .codex, now: now, calendar: calendar)
        for width: CGFloat in [736, 864, 1360] {
            let content = VStack(alignment: .leading, spacing: 22) {
                Text("每日额度与 Token").font(.system(size: 17, weight: .semibold))
                Text("额度是当天最后观测的窗口已用比例；Token 是本机当天记录的消耗。").font(.system(size: 11))
                AIDailyUsageBars(days: history.series[0].days, title: "5 小时窗口 · 已用比例", calendar: calendar, identifier: "fixture.quota", tokens: tokens)
                AIDailyUsageBars(days: history.days, title: "每日 Token · 本机记录", calendar: calendar, identifier: "fixture.tokens", tokens: tokens, showsTokens: true)
            }.padding(14).foregroundStyle(.white).background(WorkbenchMaterialSurface()).padding(24)
                .background(WorkbenchSceneBackground(motionEnabled: false, active: false))
                .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.7, backgroundMotion: false)
            let image = await capture(content, size: CGSize(width: width, height: 520))
            check(image != nil, "daily quota and token bar charts render at \(width) pt without activating a window")
            if let output, let image { try? image.write(to: output.appendingPathComponent("daily-bars-\(Int(width)).png")) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-appearance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = WorkbenchContextModel(dataDirectory: directory)
        let close = WorkbenchDraftCloseCoordinator()
        let city = WorkbenchWeatherDialog(model: context, close: close).frame(width: 470)
            .background(WorkbenchMaterialSurface(kind: .panel, radius: 14)).padding(40)
            .background(WorkbenchSceneBackground(motionEnabled: false, active: false))
            .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.7, backgroundMotion: false)
        let cityImage = await capture(city, size: CGSize(width: 550, height: 480))
        check(cityImage != nil, "city list renders with the shared card material and overlay scrollbar")
        if let output, let cityImage { try? cityImage.write(to: output.appendingPathComponent("city-picker.png")) }
        let callout = WBChartCallout(anchor: CGRect(x: 380, y: 74, width: 20, height: 76), canvas: CGSize(width: 580, height: 157), size: CGSize(width: 218, height: 112)) {
            VStack(alignment: .leading, spacing: 10) {
                Text("10 月 25 日").font(.system(size: 12, weight: .medium))
                Text("下载                 128 MB")
                Text("上传                   24 MB")
                Text("合计                 152 MB")
            }.font(.system(size: 11)).foregroundStyle(.white).padding(12)
        }.frame(width: 580, height: 157).padding(24)
            .background(WorkbenchSceneBackground(motionEnabled: false, active: false))
            .workbenchThemeEnvironment(theme: .qingbiMist, opacity: 0.7, backgroundMotion: false)
        if let output, let image = await capture(callout, size: CGSize(width: 628, height: 205)) {
            try? image.write(to: output.appendingPathComponent("chart-callout.png"))
        }
        print("Background appearance checks: \(count) checks, \(failures) failures")
        return failures
    }

    private static func capture<V: View>(_ view: V, size: CGSize) async -> Data? {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size); window.contentView = host
        defer { window.contentView = nil; window.close() }
        try? await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
