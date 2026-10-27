import AppKit
import LauncherCore
import SwiftUI

/// Synthetic fixtures use the production Mini without ordering windows or
/// reading accounts, calendars, hardware, or other application content.
@MainActor enum WorkbenchMiniAppearanceChecks {
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let output = ProcessInfo.processInfo.environment["FANGCUN_MINI_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let output { try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        check(await NativeUIFixtureAccessibility.prepareOwnProcessBridge(), "Mini native accessibility bridge is available without presenting windows")
        let saved = (Palette.workbenchTheme, Palette.isLight, Palette.glassOpacity)
        defer { Palette.workbenchTheme = saved.0; Palette.isLight = saved.1; Palette.glassOpacity = saved.2 }
        var records: [[String: Any]] = []
        for light in [false, true] {
            for width: CGFloat in [320, 518, 748, 978] {
                for opacity in [0.5, 0.7, 0.9] {
                    let safeTop: CGFloat = width == 320 ? 0 : 32
                    let notch: CGFloat = width == 320 ? 0 : 220
                    let name = "mini-\(light ? "light" : "dark")-\(Int(width))-\(Int(opacity * 100))"
                    let fixture = Fixture(width: width, safeTop: safeTop, notchWidth: notch, light: light, opacity: opacity)
                    await fixture.settle()
                    check(!fixture.window.isVisible && !fixture.window.isKeyWindow, "\(name): native fixture remains hidden and non-key")
                    check(fixture.surface.bounds.height == 292 && fixture.host.frame == fixture.surface.bounds, "\(name): modular panel has fixed 292 pt height")
                    check(fixture.surface.materialOpacity == opacity && fixture.surface.usesLightAppearance == light, "\(name): shared material follows appearance and opacity")
                    let effects = descendants(fixture.surface).compactMap { $0 as? NSVisualEffectView }
                    check(!effects.isEmpty && effects.allSatisfy { $0.blendingMode == .behindWindow }, "\(name): backdrop samples behind the panel")
                    check(fixture.surface.containsVisiblePoint(.init(x: 12, y: 2)) && !fixture.surface.containsVisiblePoint(.init(x: 2, y: 26)) && fixture.surface.containsVisiblePoint(.init(x: 23, y: 28)), "\(name): shoulder joins the top and straight side")
                    let objects = accessibilityObjects(fixture.host)
                    let actions = frame("mini-header-actions", objects: objects, fixture: fixture)
                    let date = frame("mini-header-date", objects: objects, fixture: fixture)
                    let header = [actions, date].compactMap { $0 }
                    let camera = CGRect(x: (width-notch)/2-8, y: 0, width: notch+16, height: safeTop)
                    check(header.count == 2 && header.allSatisfy { fixture.surface.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) && $0.maxY <= fixture.surface.contentTopInset-4 && (notch == 0 || !$0.intersects(camera)) }, "\(name): date, weather, and settings avoid the actual notch")
                    check(frame("mini-open-workbench", objects: objects, fixture: fixture) == nil, "\(name): obsolete workbench button is absent")
                    let capacity = max(1, Int((width - 68 + 10)/230))
                    let pages = (3 + capacity - 1)/capacity
                    var seen = Set<WorkbenchMiniCardID>()
                    for page in 0..<pages {
                        if page > 0 { check(press("mini-next-page", in: fixture.host), "\(name): next page is reachable"); await fixture.settle() }
                        let values = accessibilityObjects(fixture.host)
                        let frames = WorkbenchMiniCardID.builtIn.compactMap { id -> (WorkbenchMiniCardID, CGRect)? in
                            frame("mini-card-"+id.rawValue, objects: values, fixture: fixture).map { (id, $0) }
                        }
                        seen.formUnion(frames.map(\.0))
                        let bounds = CGRect(x: 34, y: fixture.surface.contentTopInset, width: width-68, height: 236)
                        check(!frames.isEmpty && frames.allSatisfy { bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.1) && abs($0.1.width-220)<0.5 && abs($0.1.height-($0.0.span == 3 ? 113:72))<0.5 }, "\(name): cards retain 220 pt width and approved small/medium heights")
                        let overlap = frames.enumerated().contains { i, a in frames.dropFirst(i+1).contains { a.1.insetBy(dx: 0.5, dy: 0.5).intersects($0.1.insetBy(dx: 0.5, dy: 0.5)) } }
                        check(!overlap, "\(name): packed cards do not overlap")
                        records.append(["fixture":name,"page":page,"cards":frames.map { ["id":$0.0.rawValue,"frame":rectRecord($0.1)] }])
                        if let output, opacity == 0.7 { check(await fixture.savePNG(to: output.appendingPathComponent("\(name)-page\(page+1).png")), "\(name): production content renders offscreen") }
                    }
                    check(seen == Set(WorkbenchMiniCardID.builtIn), "\(name): all eight enabled cards are reachable")
                    fixture.close()
                }
            }
        }
        for scenario in [Scenario.settings, .empty, .missing, .seconds] {
            let fixture = Fixture(width: 518, safeTop: 32, notchWidth: 220, light: false, opacity: 0.7, scenario: scenario)
            await fixture.settle()
            check(fixture.surface.bounds.height == 292 && !fixture.window.isVisible, "\(scenario.rawValue): alternate state retains panel height")
            if scenario == .settings {
                let objects = accessibilityObjects(fixture.host)
                check(WorkbenchMiniCardID.builtIn.allSatisfy { frame("mini-toggle-"+$0.rawValue, objects: objects, fixture: fixture) != nil }, "configuration exposes all eight card choices")
                check(press("mini-toggle-codex", in: fixture.host), "configuration toggle is a native action")
                await fixture.settle()
                check(!fixture.state.preferences.visibleCards.contains(.codex), "native toggle updates the selected cards")
                check(press("mini-show-seconds", in: fixture.host), "seconds display has a native settings action")
                await fixture.settle()
                check(fixture.state.preferences.showSeconds, "seconds display updates through the settings callback")
                check(press("mini-restore", in: fixture.host), "configuration restores defaults")
                await fixture.settle()
                check(fixture.state.preferences.visibleCards == WorkbenchMiniCardID.builtIn && !fixture.state.preferences.showSeconds, "restore reinstates the eight default cards and minute clock")
            } else if scenario == .empty {
                check(press("mini-configure", in: fixture.host), "empty panel can enter editing")
                await fixture.settle()
                check(press("mini-show-configuration", in: fixture.host), "empty panel can open display settings")
                await fixture.settle()
                check(frame("mini-toggle-codex", objects: accessibilityObjects(fixture.host), fixture: fixture) != nil, "empty configuration remains recoverable")
            } else if scenario == .missing {
                let text = accessibilityObjects(fixture.host).flatMap { [string("accessibilityLabel",$0),string("accessibilityValue",$0)] }.joined(separator:" ")
                check(!text.contains("32%") && !text.contains("16°C"), "missing sources never reuse successful fixture readings")
            }
            if scenario == .missing || scenario == .seconds {
                let objects = accessibilityObjects(fixture.host)
                if let header = frame("mini-header-date", objects: objects, fixture: fixture),
                   let button = frame("mini-open-context-date", objects: objects, fixture: fixture) {
                    check(header.insetBy(dx: -0.5, dy: -0.5).contains(button), "\(scenario.rawValue): the full clock button fits its notch-safe wing")
                } else { check(false, "\(scenario.rawValue): the clock exposes measurable bounds") }
                for identifier in ["mini-open-context-date", "mini-open-context-weather"] {
                    let before = fixture.state.contextOpens
                    check(press(identifier, in: fixture.host) && fixture.state.contextOpens == before + 1,
                          "\(scenario.rawValue): \(identifier) opens context settings regardless of city availability")
                }
            }
            if let output { check(await fixture.savePNG(to: output.appendingPathComponent("mini-\(scenario.rawValue).png")), "\(scenario.rawValue): alternate state renders offscreen") }
            fixture.close()
        }
        let navigation = Fixture(width:748,safeTop:32,notchWidth:220,light:false,opacity:0.7)
        await navigation.settle()
        for card in WorkbenchMiniCardID.builtIn {
            check(press("mini-card-"+card.rawValue,in:navigation.host), "\(card.rawValue): whole card activates")
            check(navigation.state.opened.last == card, "\(card.rawValue): whole card preserves its route identity")
        }
        check(press("mini-configure",in:navigation.host), "layout editing is reachable")
        await navigation.settle()
        let before=navigation.state.opened.count
        check(!press("mini-open-context-date", in:navigation.host) && !press("mini-open-context-weather", in:navigation.host), "layout editing hides context navigation controls")
        _=press("mini-card-codex",in:navigation.host)
        check(navigation.state.opened.count == before,"editing a card never navigates away")
        check(customAction("后移", identifier:"mini-card-codex", in:navigation.host), "editing exposes a native reorder action")
        await navigation.settle()
        check(navigation.state.preferences.cardOrder.prefix(2) == [.claude, .codex], "native reorder action updates persistent card order")
        check(customAction("隐藏卡片", identifier:"mini-card-codex", in:navigation.host), "editing exposes a native hide action")
        await navigation.settle()
        check(!navigation.state.preferences.visibleCards.contains(.codex), "native hide action updates the selected cards")
        navigation.close()
        if let output, let data=try? JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:output.appendingPathComponent("mini-geometry.json"),options:.atomic)}
        print("Mini appearance checks: \(count) checks, \(failures) failures")
        return (count,failures)
    }
    private enum Scenario:String {case normal,settings,empty,missing,seconds}
    @MainActor private final class FixtureState:ObservableObject {
        @Published var preferences=WorkbenchTopEntryPreferences()
        var opened:[WorkbenchMiniCardID]=[]
        var contextOpens = 0
    }
    private struct FixtureContent:View {
        @ObservedObject var state:FixtureState
        let context:WorkbenchMiniContextData
        let agenda:WorkbenchMiniAgendaData
        let device:WorkbenchMiniDeviceData
        let providers:[WorkbenchMiniAIData]
        let safeTop:CGFloat
        let notchWidth:CGFloat
        let configuring:Bool
        var body:some View {
            WorkbenchMiniPanelView(context:context,agenda:agenda,device:device,providers:providers,
                preferences:state.preferences,safeTop:safeTop,notchWidth:notchWidth,error:nil,
                open:{state.opened.append($0)},openContext:{state.contextOpens += 1},setVisible:{state.preferences.setCard($0,visible:$1)},
                setHeaderVisible:{state.preferences.showDate=$0;state.preferences.showWeather=$1},
                setSeconds:{state.preferences.showSeconds=$0},
                reorder:{state.preferences.moveCard($0,relativeTo:$1,after:$2)},restore:{state.preferences = .init()},
                finishConfiguration:{},configuring:configuring)
        }
    }
    @MainActor private final class Fixture {
        let window:NSWindow
        let surface:WorkbenchNotchSurface
        let host:NSHostingView<AnyView>
        let state=FixtureState()
        init(width:CGFloat,safeTop:CGFloat,notchWidth:CGFloat,light:Bool,opacity:Double,scenario:Scenario = .normal) {
            Palette.workbenchTheme = .qingbiMist;Palette.isLight=light;Palette.glassOpacity=opacity
            let missing=scenario == .missing
            if scenario == .empty {state.preferences.visibleCards=[]}
            state.preferences.showSeconds = scenario == .seconds
            let context=WorkbenchMiniContextData(time:scenario == .seconds ? "下午 10:24:56":"10:24",date:"10月25日 · 星期日",zone:"UTC−4",zoneHelp:"示例时区 · UTC−4",city:missing ? "未选择城市":"纽约",temperature:missing ? "—":"16°C",condition:missing ? "请先选择城市":"多云",symbol:missing ? "globe":"cloud.sun",weatherNote:nil,shortDate:"10月25日",weekday:"周日")
            let agenda=WorkbenchMiniAgendaData(event:nil,reminder:missing ? nil:.init(title:"整理下周计划",dateText:"10/26 · 09:00",note:nil),eventStatus:"日历未连接",reminderStatus:"暂无未完成待办")
            var device=WorkbenchMiniDeviceData()
            if !missing {
                device.memory="12.4 / 24 GB";device.memoryFraction=0.517;device.memoryPressure="压力低"
                device.disk="672 / 1,000 GB";device.diskFraction=0.672
                device.temperature="48°C";device.gpuTemperature="44°C";device.leftFan="1920 RPM";device.rightFan="1860 RPM";device.thermalState="正常"
                device.download="3.2 MB/s";device.upload="240 KB/s";device.todayTraffic="8.6 GB";device.periodTraffic="128 / 200 GB";device.trafficFraction=0.64
                let now=Date(),segment=UUID()
                for i in 0..<30 {
                    let date=now.addingTimeInterval(Double(i-29)*2)
                    let down=Double(1+i%7)*400_000.0,up=Double(1+i%5)*60_000.0
                    device.networkPoints.append(WorkbenchMiniNetworkPoint(date:date,segment:segment,download:down,upload:up))
                }
            }
            let providers=AIProvider.allCases.enumerated().map { index,provider in
                WorkbenchMiniAIData(provider:provider,title:provider.title,stateText:missing ? "不可用":"已用",detail:"Synthetic quota fixture",isStale:false,windows:[.init(label:"5小时",value:missing ? "—":"32%",fraction:missing ? nil:0.32,reset:"13:00"),.init(label:"每周",value:missing ? "—":"18%",fraction:missing ? nil:0.18,reset:"10/29 09:00")])
            }
            let content=FixtureContent(state:state,context:context,agenda:agenda,device:device,providers:providers,safeTop:safeTop,notchWidth:notchWidth,configuring:scenario == .settings)
            let size=CGSize(width:width,height:WorkbenchMiniLayout.height(safeTop:safeTop))
            window=NSWindow(contentRect:CGRect(origin:.init(x:100,y:100),size:size),styleMask:[.borderless],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.isOpaque=false;window.backgroundColor = .clear;window.ignoresMouseEvents=true
            surface=WorkbenchNotchSurface(size:size,notchWidth:notchWidth,safeTop:safeTop)
            host=NSHostingView(rootView:AnyView(content.environment(\.accessibilityEnabled,true).workbenchThemeEnvironment(theme:.qingbiMist,opacity:opacity,backgroundMotion:false,appearance:light ? .light:.dark)))
            window.contentView=surface;surface.setContent(host);surface.setPhase(.expanded,animated:false)
        }
        func settle() async {try? await Task.sleep(for:.milliseconds(100));surface.layoutSubtreeIfNeeded();host.layoutSubtreeIfNeeded()}
        func savePNG(to url:URL) async->Bool {
            await settle()
            guard let image=surface.bitmapImageRepForCachingDisplay(in:surface.bounds) else {return false}
            surface.cacheDisplay(in:surface.bounds,to:image)
            guard let data=image.representation(using:.png,properties:[:]) else {return false}
            do {try data.write(to:url,options:.atomic);return true} catch {return false}
        }
        func close() {surface.clearContent();window.contentView=nil;window.close()}
    }

    private static func accessibilityObjects(_ root: NSView) -> [NSObject] {
        var pending: [NSObject] = [root], seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        while let object = pending.popLast(), seen.count < 8_192 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            for key in ["accessibilityChildren", "accessibilityContents"] {
                if object.responds(to: NSSelectorFromString(key)),
                   let children = object.value(forKey: key) as? [NSObject] { pending.append(contentsOf: children) }
            }
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
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        for object in accessibilityObjects(host) where string("accessibilityIdentifier", object) == identifier && object.responds(to: selector) {
            if unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector) { return true }
        }
        return false
    }
    private static func customAction(_ name: String, identifier: String, in host: NSView) -> Bool {
        let actions = accessibilityObjects(host).filter { string("accessibilityIdentifier", $0) == identifier }
            .flatMap { object -> [NSAccessibilityCustomAction] in
                guard object.responds(to: NSSelectorFromString("accessibilityCustomActions")) else { return [] }
                return object.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []
            }
        guard let action = actions.first(where: { $0.name == name }) else { return false }
        if let handler = action.handler { return handler() }
        guard let target = action.target as? NSObject, let selector = action.selector, target.responds(to: selector) else { return false }
        if NSStringFromSelector(selector).contains(":") {
            typealias Perform = @convention(c) (AnyObject, Selector, NSAccessibilityCustomAction) -> Bool
            return unsafeBitCast(target.method(for: selector), to: Perform.self)(target, selector, action)
        }
        typealias Perform = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(target.method(for: selector), to: Perform.self)(target, selector)
    }
    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private static func rectRecord(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
}
