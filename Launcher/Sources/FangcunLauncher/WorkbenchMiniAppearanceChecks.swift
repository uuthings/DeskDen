import AppKit
import LauncherCore
import SwiftUI

/// Synthetic production-view fixtures. No window is ordered, made key or
/// activated, and no system input, account data or live provider is used.
@MainActor enum WorkbenchMiniAppearanceChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let output = ProcessInfo.processInfo.environment["FANGCUN_MINI_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let output { try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let originalTheme = Palette.workbenchTheme, originalLight = Palette.isLight, originalOpacity = Palette.glassOpacity
        defer { Palette.workbenchTheme = originalTheme; Palette.isLight = originalLight; Palette.glassOpacity = originalOpacity }
        var geometryRecords: [[String: Any]] = []

        for light in [false, true] {
            for width: CGFloat in [480, 520, 760] {
                for opacity in [0.5, 0.7, 0.9] {
                    let safeTop: CGFloat = width == 480 ? 0 : 32
                    let notchWidth: CGFloat = width == 480 ? 0 : 220
                    let name = "mini-\(light ? "light" : "dark")-\(Int(width))-\(Int(opacity * 100))"
                    let fixture = Fixture(width: width, safeTop: safeTop, notchWidth: notchWidth, light: light, opacity: opacity)
                    defer { fixture.close() }
                    await fixture.settle()
                    check(!fixture.window.isVisible && !fixture.window.isKeyWindow && !fixture.window.isMainWindow,
                          "\(name): native fixture remains hidden and non-key")
                    check(fixture.surface.bounds.height == 200 && fixture.host.frame == fixture.surface.bounds,
                          "\(name): compact outer height is 200 and content occupies the full contour")
                    check(fixture.surface.materialOpacity == opacity && fixture.surface.usesLightAppearance == light,
                          "\(name): outer material follows shared appearance and opacity")
                    let effects = descendants(fixture.surface).compactMap { $0 as? NSVisualEffectView }
                    check(!effects.isEmpty && effects.allSatisfy { $0.blendingMode == .behindWindow },
                          "\(name): one shared backdrop samples behind the Mini window")
                    check(fixture.surface.containsVisiblePoint(CGPoint(x: 12, y: 2)) &&
                          !fixture.surface.containsVisiblePoint(CGPoint(x: 2, y: 26)) &&
                          fixture.surface.containsVisiblePoint(CGPoint(x: 23, y: 28)) &&
                          !fixture.surface.containsVisiblePoint(CGPoint(x: 23, y: 199)),
                          "\(name): broad top attachment narrows through the shoulder to straight sides and rounded bottom")

                    let objects = accessibilityObjects(fixture.host)
                    if let output, width == 520, !light, opacity == 0.7 {
                        let rows = objects.map { object in
                            ["type": String(describing: type(of: object)), "identifier": string("accessibilityIdentifier", object),
                             "role": string("accessibilityRole", object), "label": string("accessibilityLabel", object),
                             "frame": localFrame(object, fixture: fixture).map { NSStringFromRect($0) } ?? ""]
                        }
                        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: output.appendingPathComponent("mini-accessibility.json"), options: .atomic)
                        }
                    }
                    let openFrame = frame("mini-open-workbench", objects: objects, fixture: fixture)
                    let configureFrame = frame("mini-configure", objects: objects, fixture: fixture)
                    let brandFrame = frame("mini-brand", objects: objects, fixture: fixture)
                    check(openFrame != nil && configureFrame != nil && brandFrame != nil,
                          "\(name): real header controls expose measurable accessibility frames")
                    let headerFrames = [openFrame, configureFrame, brandFrame].compactMap { $0 }
                    let camera = CGRect(x: (width - notchWidth) / 2 - 8, y: 0, width: notchWidth + 16, height: safeTop)
                    check(headerFrames.count == 3 && headerFrames.allSatisfy {
                        fixture.surface.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) && $0.maxY <= fixture.surface.contentTopInset - 4 &&
                        (notchWidth == 0 || !$0.intersects(camera))
                    }, "\(name): brand and actions remain inside the surface and clear the camera by 8 pt")

                    var seen = Set<String>()
                    for page in 0..<(width < 760 ? 2 : 1) {
                        if page > 0 {
                            check(press("mini-page-\(page)", in: fixture.host), "\(name): isolated accessibility action opens page \(page + 1)")
                            await fixture.settle()
                        }
                        let pageObjects = accessibilityObjects(fixture.host)
                        let sectionFrames = WorkbenchMiniSection.allCases.compactMap { section -> (String, CGRect)? in
                            guard let rect = frame("mini-section-\(section.rawValue)", objects: pageObjects, fixture: fixture) else { return nil }
                            return (section.rawValue, rect)
                        }
                        seen.formUnion(sectionFrames.map(\.0))
                        let expected = width < 760 ? 2 : 4
                        check(sectionFrames.count == expected, "\(name): page \(page + 1) exposes \(expected) information regions")
                        let body = CGRect(x: WorkbenchMiniLayout.horizontalInset, y: fixture.surface.contentTopInset,
                                          width: width - 2 * WorkbenchMiniLayout.horizontalInset, height: WorkbenchMiniLayout.sectionHeight)
                        check(!sectionFrames.isEmpty && sectionFrames.allSatisfy { body.insetBy(dx: -0.5, dy: -0.5).contains($0.1) },
                              "\(name): all regions fit the fixed 148 pt information row")
                        let ordered = sectionFrames.sorted { $0.1.minX < $1.1.minX }
                        check(zip(ordered, ordered.dropFirst()).allSatisfy { $0.0.1.maxX <= $0.1.1.minX + 0.5 },
                              "\(name): information regions do not overlap")
                        let textFrames = pageObjects.compactMap { object -> CGRect? in
                            guard string("accessibilityRole", object) == "AXStaticText" else { return nil }
                            return localFrame(object, fixture: fixture)
                        }.filter { $0.width > 0 && $0.height > 0 }
                        check(!textFrames.isEmpty && textFrames.allSatisfy { fixture.surface.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) },
                              "\(name): rendered text frames stay inside the compact panel")
                        geometryRecords.append([
                            "fixture": name, "page": page, "height": fixture.surface.bounds.height,
                            "header": headerFrames.map(rectRecord), "regions": sectionFrames.map { ["id": $0.0, "frame": rectRecord($0.1)] },
                            "textCount": textFrames.count
                        ])
                        if let output, opacity == 0.7 {
                            check(await fixture.savePNG(to: output.appendingPathComponent("\(name)-page\(page + 1).png")),
                                  "\(name): page \(page + 1) captures the production panel offscreen")
                        }
                    }
                    check(seen == Set(WorkbenchMiniSection.allCases.map(\.rawValue)), "\(name): every enabled region is reachable")
                    fixture.surface.setPhase(.closed, animated: false)
                    fixture.surface.clearContent()
                    check(fixture.host.superview == nil && fixture.surface.hitTest(CGPoint(x: width / 2, y: 100)) == nil && !fixture.window.isVisible,
                          "\(name): collapse releases the content host and stops its interactions")
                }
            }
        }

        for scenario in [Scenario.settings, .empty, .missing] {
            for light in [false, true] {
                let name = "mini-\(scenario.rawValue)-\(light ? "light" : "dark")-520"
                let fixture = Fixture(width: 520, safeTop: 32, notchWidth: 220, light: light, opacity: 0.7, scenario: scenario)
                defer { fixture.close() }
                await fixture.settle()
                check(fixture.surface.bounds.height == 200 && !fixture.window.isVisible,
                      "\(name): alternate state retains the fixed hidden surface")
                let objects = accessibilityObjects(fixture.host)
                if let output { check(await fixture.savePNG(to: output.appendingPathComponent("\(name).png")), "\(name): alternate state captures offscreen") }
                if scenario == .settings {
                    let toggles = WorkbenchMiniSection.allCases.compactMap { frame("mini-toggle-\($0.rawValue)", objects: objects, fixture: fixture) }
                    check(toggles.count == 4 && toggles.allSatisfy { fixture.surface.bounds.contains($0) },
                          "\(name): all four display toggles fit without growing the panel")
                    check(frame("mini-restore", objects: objects, fixture: fixture) != nil,
                          "\(name): configuration retains a reachable restore action")
                } else if scenario == .empty {
                    check(objects.contains { string("accessibilityLabel", $0).contains("已隐藏全部信息") || string("accessibilityValue", $0).contains("已隐藏全部信息") },
                          "\(name): hiding every region keeps an explicit recoverable empty state")
                    check(press("mini-configure", in: fixture.host), "\(name): empty panel can enter configuration")
                    await fixture.settle()
                    check(WorkbenchMiniSection.allCases.allSatisfy { frame("mini-toggle-\($0.rawValue)", objects: accessibilityObjects(fixture.host), fixture: fixture) != nil },
                          "\(name): configuration is reachable after every region is hidden")
                } else {
                    let text = objects.flatMap { [string("accessibilityLabel", $0), string("accessibilityValue", $0)] }.joined(separator: " ")
                    check(text.contains("未选择城市") && text.contains("日历未连接"), "\(name): absent sources have explicit states")
                    check(!text.contains("16°C") && !text.contains("32%"), "\(name): absent readings never reuse synthetic success values")
                }
            }
        }
        if let output, let data = try? JSONSerialization.data(withJSONObject: geometryRecords, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("mini-geometry.json"), options: .atomic)
        }
        print("Mini appearance checks: \(count) checks, \(failures) failures")
        return (count, failures)
    }

    private enum Scenario: String { case normal, settings, empty, missing }

    @MainActor private final class Fixture {
        let window: NSWindow
        let surface: WorkbenchNotchSurface
        let host: NSHostingView<AnyView>

        init(width: CGFloat, safeTop: CGFloat, notchWidth: CGFloat, light: Bool, opacity: Double, scenario: Scenario = .normal) {
            Palette.workbenchTheme = .qingbiMist; Palette.isLight = light; Palette.glassOpacity = opacity
            let missing = scenario == .missing
            let context = WorkbenchMiniContextData(time: "10:24", date: "10月25日 · 星期日", zone: "UTC−4", zoneHelp: "示例时区 · UTC−4",
                city: missing ? "未选择城市" : "纽约", temperature: missing ? "—" : "16°C", condition: missing ? "请先选择城市" : "多云",
                symbol: missing ? "globe" : "cloud.sun", weatherNote: missing ? nil : "体感 15°C")
            let agenda = WorkbenchMiniAgendaData(
                event: missing ? nil : .init(title: "阅读与整理", dateText: "10/25 · 11:00", note: nil),
                reminder: missing ? nil : .init(title: "整理下周计划", dateText: "10/26 · 09:00", note: nil),
                eventStatus: "日历未连接", reminderStatus: "暂无未完成待办")
            let device = WorkbenchMiniDeviceData(cpu: missing ? "—" : "18%", memory: missing ? "—" : "12.4 / 24 GB",
                temperature: missing ? "—" : "48°C", download: missing ? "—" : "3.2 MB/s", upload: missing ? "—" : "240 KB/s", note: missing ? "正在读取本机数据" : nil)
            let providers = AIProvider.allCases.enumerated().map { index, provider in
                WorkbenchMiniAIData(provider: provider, title: provider.title, stateText: missing ? "不可用" : "已用", detail: "Synthetic quota fixture", isStale: false,
                    windows: [.init(label: "5小时", value: missing ? "—" : (index == 0 ? "32%" : "46%"), fraction: missing ? nil : (index == 0 ? 0.32 : 0.46)),
                              .init(label: "每周", value: missing ? "—" : (index == 0 ? "18%" : "27%"), fraction: missing ? nil : (index == 0 ? 0.18 : 0.27))])
            }
            let panel = WorkbenchMiniPanelView(context: context, agenda: agenda, device: device, providers: providers,
                sections: scenario == .empty ? [] : WorkbenchMiniSection.allCases, safeTop: safeTop, notchWidth: notchWidth,
                error: nil, open: {}, setVisible: { _, _ in }, restore: {}, finishConfiguration: {}, configuring: scenario == .settings)
            let size = CGSize(width: width, height: WorkbenchMiniLayout.height(safeTop: safeTop))
            window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear; window.ignoresMouseEvents = true
            surface = WorkbenchNotchSurface(size: size, notchWidth: notchWidth, safeTop: safeTop)
            host = NSHostingView(rootView: AnyView(panel.environment(\.accessibilityEnabled, true)
                .workbenchThemeEnvironment(theme: .qingbiMist, opacity: opacity, backgroundMotion: false, appearance: light ? .light : .dark)))
            window.contentView = surface; surface.setContent(host); surface.setPhase(.expanded, animated: false)
        }
        func settle() async {
            try? await Task.sleep(for: .milliseconds(120))
            surface.layoutSubtreeIfNeeded(); host.layoutSubtreeIfNeeded()
        }
        func savePNG(to url: URL) async -> Bool {
            await settle()
            guard let image = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { return false }
            surface.cacheDisplay(in: surface.bounds, to: image)
            guard let data = image.representation(using: .png, properties: [:]) else { return false }
            do { try data.write(to: url, options: .atomic); return true } catch { return false }
        }
        func close() { surface.clearContent(); window.contentView = nil; window.close() }
    }

    private static func accessibilityObjects(_ root: NSView) -> [NSObject] {
        var pending: [NSObject] = [root], seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        while let object = pending.popLast(), seen.count < 8_192 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] { pending.append(contentsOf: children) }
        }
        return result
    }
    private static func string(_ key: String, _ object: NSObject) -> String {
        guard object.responds(to: NSSelectorFromString(key)) else { return "" }
        return object.value(forKey: key) as? String ?? ""
    }
    private static func localFrame(_ object: NSObject, fixture: Fixture) -> CGRect? {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")), let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        let rect = value.rectValue
        guard rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else { return nil }
        return fixture.surface.convert(fixture.window.convertFromScreen(rect), from: nil)
    }
    private static func frame(_ identifier: String, objects: [NSObject], fixture: Fixture) -> CGRect? {
        let frames = objects.filter { string("accessibilityIdentifier", $0) == identifier }.compactMap { localFrame($0, fixture: fixture) }
        return frames.reduce(nil) { (result: CGRect?, frame: CGRect) in result.map { $0.union(frame) } ?? frame }
    }
    private static func press(_ identifier: String, in host: NSView) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let object = accessibilityObjects(host).first(where: { string("accessibilityIdentifier", $0) == identifier && $0.responds(to: selector) }) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private static func rectRecord(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
}
