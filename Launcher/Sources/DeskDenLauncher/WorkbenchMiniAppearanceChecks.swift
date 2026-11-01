import AppKit
import ApplicationServices
import LauncherCore
import SwiftUI

/// Synthetic fixtures use the production Mini without reading accounts,
/// calendars, hardware, or other application content. Only the explicit
/// CUA drag-fixture entry point presents a window.
@MainActor enum WorkbenchMiniAppearanceChecks {
    /// A foreground synthetic fixture for CUA acceptance. This entry point
    /// observes the production panel; all pointer interaction belongs to CUA.
    static func runPointerDrag() async {
        let requestedWidth = ProcessInfo.processInfo.environment["DESKDEN_MINI_DRAG_WIDTH"]
        let width: CGFloat = requestedWidth == "518" ? 518 : 748
        let saved = (Palette.workbenchTheme, Palette.isLight, Palette.glassOpacity)
        let fixture = Fixture(width: width, safeTop: 32, notchWidth: 220, light: false, opacity: 0.7, interactive: true)
        defer {
            fixture.close()
            Palette.workbenchTheme = saved.0; Palette.isLight = saved.1; Palette.glassOpacity = saved.2
        }
        func log(_ message: String) {
            FileHandle.standardOutput.write(Data((message + "\n").utf8))
        }
        fixture.window.title = "Mini drag fixture — \(Int(width))"
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        fixture.window.setFrameOrigin(CGPoint(x: visible.midX - width / 2, y: visible.midY - fixture.window.frame.height / 2))
        let mounted = await NativeUIFixtureWindow.prepare(window: fixture.window) {
            NativeUIFixtureWindow.hasAccessibilityElement("mini-configure", in: fixture.host)
        }
        log("MINI_DRAG_FIXTURE width=\(Int(width)) mounted=\(mounted) synthetic=true; awaiting CUA interaction until app termination")
        var lastSaves = -1
        var lastPresentation = ""
        while !Task.isCancelled {
            if fixture.state.saves != lastSaves {
                lastSaves = fixture.state.saves
                let active = fixture.state.preferences.activeCards(available: fixture.availableCards).map(\.rawValue).joined(separator: ",")
                let order = fixture.state.preferences.cardOrder.map(\.rawValue).joined(separator: ",")
                log("MINI_DRAG_SAVED saves=\(lastSaves) active=[\(active)] order=[\(order)] seconds=\(fixture.state.preferences.showSeconds)")
            }
            let objects = accessibilityObjects(fixture.host)
            let editing = frame("mini-cancel", objects: objects, fixture: fixture) != nil
            let placeholder = frame("mini-drag-placeholder", objects: objects, fixture: fixture) != nil
            let visibleCards = fixture.availableCards.compactMap { card -> (WorkbenchMiniCardID, CGRect)? in
                frame("mini-card-" + card.rawValue, objects: objects, fixture: fixture).map { (card, $0) }
            }.sorted { lhs, rhs in
                abs(lhs.1.minX - rhs.1.minX) > 1 ? lhs.1.minX < rhs.1.minX : lhs.1.minY < rhs.1.minY
            }.map { $0.0.rawValue }.joined(separator: ",")
            let presentation = "editing=\(editing) placeholder=\(placeholder) visible=[\(visibleCards)] opened=\(fixture.state.opened.count)"
            if presentation != lastPresentation {
                lastPresentation = presentation
                log("MINI_DRAG_OBSERVED " + presentation)
            }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
        }
    }
    static func run() async -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(message)")
        }
        let output = ProcessInfo.processInfo.environment["DESKDEN_MINI_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let output { try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        check(await NativeUIFixtureAccessibility.prepareOwnProcessBridge(), "Mini native accessibility bridge is available without presenting windows")
        let saved = (Palette.workbenchTheme, Palette.isLight, Palette.glassOpacity)
        defer { Palette.workbenchTheme = saved.0; Palette.isLight = saved.1; Palette.glassOpacity = saved.2 }
        var records: [[String: Any]] = []
        let defaults = WorkbenchMiniCardID.defaultVisible
        check(WorkbenchMiniLayout.size(cards: defaults, screenWidth: 1728, safeTop: 32, notchWidth: 220) == CGSize(width: 748, height: 292), "seven default cards naturally occupy three columns")
        let sourceCards: [WorkbenchMiniCardID] = [.provider(UUID()), .apiBalance(UUID())]
        check(WorkbenchMiniLayout.size(cards: defaults + sourceCards, screenWidth: 1728, safeTop: 32, notchWidth: 220) == CGSize(width: 978, height: 292), "two connected services expand the default layout to four columns")
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
                        let frames = defaults.compactMap { id -> (WorkbenchMiniCardID, CGRect)? in
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
                    check(seen == Set(defaults), "\(name): all seven default cards are reachable without the optional traffic card")
                    fixture.close()
                }
            }
        }
        for scenario in [Scenario.settings, .empty, .missing, .seconds, .fourColumns, .thermalWarning, .thermalCritical] {
            let fixture = Fixture(width: scenario == .fourColumns ? 978 : 518, safeTop: 32, notchWidth: 220, light: false, opacity: 0.7, scenario: scenario)
            await fixture.settle()
            check(fixture.surface.bounds.height == 292 && !fixture.window.isVisible, "\(scenario.rawValue): alternate state retains panel height")
            if scenario == .settings {
                let objects = accessibilityObjects(fixture.host)
                check(WorkbenchMiniCardID.builtIn.allSatisfy { frame("mini-toggle-"+$0.rawValue, objects: objects, fixture: fixture) != nil }, "configuration exposes all eight card choices")
                check(press("mini-toggle-codex", in: fixture.host), "configuration toggle is a native action")
                await fixture.settle()
                check(fixture.state.preferences.visibleCards.contains(.codex), "configuration edits remain a draft before confirmation")
                check(press("mini-show-seconds", in: fixture.host), "seconds display has a native settings action")
                await fixture.settle()
                check(!fixture.state.preferences.showSeconds, "seconds editing also remains an unsaved draft")
                check(press("mini-cancel", in: fixture.host), "compact cancel action discards the complete configuration draft")
                await fixture.settle()
                check(fixture.state.preferences.visibleCards == defaults && !fixture.state.preferences.showSeconds && fixture.state.saves == 0, "cancel restores layout and header without writing preferences")
                check(press("mini-configure", in: fixture.host), "configuration can be reopened after cancel")
                await fixture.settle()
                check(press("mini-show-configuration", in: fixture.host), "reopened editor can enter the card library")
                await fixture.settle()
                _ = press("mini-toggle-codex", in: fixture.host); _ = press("mini-show-seconds", in: fixture.host)
                await fixture.settle()
                check(press("mini-configure", in: fixture.host), "compact checkmark confirms all configuration changes")
                await fixture.settle()
                check(!fixture.state.preferences.visibleCards.contains(.codex) && fixture.state.preferences.showSeconds && fixture.state.saves == 1, "save commits card and header choices together")
                _ = press("mini-configure", in: fixture.host); await fixture.settle()
                _ = press("mini-show-configuration", in: fixture.host); await fixture.settle()
                check(press("mini-restore", in: fixture.host), "configuration restores defaults")
                await fixture.settle()
                check(!fixture.state.preferences.visibleCards.contains(.codex) && fixture.state.preferences.showSeconds, "restore defaults remains a draft until confirmed")
                _ = press("mini-configure", in: fixture.host); await fixture.settle()
                check(fixture.state.preferences.visibleCards == defaults && !fixture.state.preferences.showSeconds && fixture.state.preferences.usesDefaultLayout, "confirmed restore reinstates seven default cards, minute clock and automatic source inclusion")
            } else if scenario == .empty {
                check(press("mini-configure", in: fixture.host), "empty panel can enter editing")
                await fixture.settle()
                check(press("mini-show-configuration", in: fixture.host), "empty panel can open display settings")
                await fixture.settle()
                check(frame("mini-toggle-codex", objects: accessibilityObjects(fixture.host), fixture: fixture) != nil, "empty configuration remains recoverable")
            } else if scenario == .missing {
                let text = accessibilityObjects(fixture.host).flatMap { [string("accessibilityLabel",$0),string("accessibilityValue",$0)] }.joined(separator:" ")
                check(!text.contains("32%") && !text.contains("16°C"), "missing sources never reuse successful fixture readings")
            } else if scenario == .fourColumns {
                let values = accessibilityObjects(fixture.host)
                let visible = defaults + fixture.availableCards.filter { $0.providerID != nil || $0.apiBalanceID != nil }
                check(visible.count == 9 && visible.allSatisfy { frame("mini-card-" + $0.rawValue, objects: values, fixture: fixture) != nil }, "four-column Mini shows built-in cards and connected traffic/balance sources together")
                check(frame("mini-next-page", objects: values, fixture: fixture) == nil, "four columns do not create unnecessary pagination")
            } else if scenario == .thermalWarning || scenario == .thermalCritical {
                let text = accessibilityObjects(fixture.host).flatMap { [string("accessibilityLabel", $0), string("accessibilityValue", $0)] }.joined(separator: " ")
                check(text.contains(scenario == .thermalWarning ? "温度偏高" : "系统高温"), "\(scenario.rawValue): thermal status has an explicit accessible label in addition to color")
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
        let frontBefore = NSWorkspace.shared.frontmostApplication
        let navigation = Fixture(width:748,safeTop:32,notchWidth:220,light:false,opacity:0.7,interactive:true)
        let mounted = await NativeUIFixtureWindow.prepare(window: navigation.window) {
            NativeUIFixtureWindow.hasAccessibilityElement("mini-configure", in: navigation.host)
        }
        check(mounted, "named accessibility actions have an explicitly foreground native fixture")
        defer {
            navigation.close()
            if let frontBefore, frontBefore.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                frontBefore.activate(options: [.activateIgnoringOtherApps])
            }
        }
        await navigation.settle()
        for card in defaults {
            check(press("mini-card-"+card.rawValue,in:navigation.host), "\(card.rawValue): whole card activates")
            check(navigation.state.opened.last == card, "\(card.rawValue): whole card preserves its route identity")
        }
        check(press("mini-configure",in:navigation.host), "layout editing is reachable")
        await navigation.settle()
        let editObjects = accessibilityObjects(navigation.host)
        if let cancel = frame("mini-cancel", objects: editObjects, fixture: navigation), let save = frame("mini-configure", objects: editObjects, fixture: navigation) {
            check(abs(cancel.width-save.width)<0.5 && abs(cancel.height-save.height)<0.5 && cancel.width <= 28 && cancel.height <= 28, "cancel and confirm share the same compact icon geometry")
        } else { check(false, "compact edit actions expose measurable bounds") }
        let before=navigation.state.opened.count
        check(!press("mini-open-context-date", in:navigation.host) && !press("mini-open-context-weather", in:navigation.host), "layout editing hides context navigation controls")
        _=press("mini-card-codex",in:navigation.host)
        check(navigation.state.opened.count == before,"editing a card never navigates away")
        check(await customAction("后移", identifier:"mini-card-codex"), "editing exposes a native reorder action")
        await navigation.settle()
        let movedObjects = accessibilityObjects(navigation.host)
        if let codex = frame("mini-card-codex", objects: movedObjects, fixture: navigation), let claude = frame("mini-card-claude", objects: movedObjects, fixture: navigation) {
            check(claude.minY < codex.minY, "native reorder changes the visible draft order before saving")
        } else { check(false, "native reorder retains both measurable quota cards") }
        check(navigation.state.preferences.cardOrder == WorkbenchMiniCardID.builtIn, "native reorder action does not persist until save")
        check(await customAction("隐藏卡片", identifier:"mini-card-codex"), "editing exposes a native hide action")
        await navigation.settle()
        check(frame("mini-card-codex", objects: accessibilityObjects(navigation.host), fixture: navigation) == nil, "native hide removes the card from the visible draft")
        check(navigation.state.preferences.visibleCards.contains(.codex), "native hide action also remains in the draft")
        check(press("mini-configure", in: navigation.host), "accessible edits can be confirmed")
        await navigation.settle()
        check(!navigation.state.preferences.visibleCards.contains(.codex) && navigation.state.preferences.cardOrder.firstIndex(of: .claude)! < navigation.state.preferences.cardOrder.firstIndex(of: .codex)!, "save persists the reordered layout and hidden card together")
        navigation.close()
        if let output, let data=try? JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:output.appendingPathComponent("mini-geometry.json"),options:.atomic)}
        print("Mini appearance checks: \(count) checks, \(failures) failures")
        return (count,failures)
    }
    private enum Scenario:String {case normal,settings,empty,missing,seconds,fourColumns,thermalWarning,thermalCritical}
    @MainActor private final class FixtureState:ObservableObject {
        @Published var preferences=WorkbenchTopEntryPreferences()
        var opened:[WorkbenchMiniCardID]=[]
        var contextOpens = 0
        var saves = 0
    }
    private struct FixtureContent:View {
        @ObservedObject var state:FixtureState
        let context:WorkbenchMiniContextData
        let agenda:WorkbenchMiniAgendaData
        let device:WorkbenchMiniDeviceData
        let providers:[WorkbenchMiniAIData]
        let externalProviders:[WorkbenchMiniExternalProviderData]
        let balances:[WorkbenchMiniAPIBalanceData]
        let thermalStatus:DeviceThermalPresentation
        let safeTop:CGFloat
        let notchWidth:CGFloat
        let configuring:Bool
        var body:some View {
            WorkbenchMiniPanelView(context:context,agenda:agenda,device:device,providers:providers,externalProviders:externalProviders,balances:balances,thermalStatus:thermalStatus,
                preferences:state.preferences,safeTop:safeTop,notchWidth:notchWidth,error:nil,
                open:{state.opened.append($0)},openContext:{state.contextOpens += 1},setVisible:{state.preferences.setCard($0,visible:$1)},
                setHeaderVisible:{state.preferences.showDate=$0;state.preferences.showWeather=$1},
                setSeconds:{state.preferences.showSeconds=$0},
                reorder:{state.preferences.moveCard($0,relativeTo:$1,after:$2)},restore:{state.preferences = .init()},
                finishConfiguration:{},saveLayout:{state.preferences=$0;state.saves += 1;return true},configuring:configuring)
        }
    }
    @MainActor private final class Fixture {
        let window:NSWindow
        let surface:WorkbenchNotchSurface
        let host:NSHostingView<AnyView>
        let state=FixtureState()
        let availableCards:[WorkbenchMiniCardID]
        init(width:CGFloat,safeTop:CGFloat,notchWidth:CGFloat,light:Bool,opacity:Double,scenario:Scenario = .normal,interactive:Bool = false) {
            Palette.workbenchTheme = .qingbiMist;Palette.isLight=light;Palette.glassOpacity=opacity
            let missing=scenario == .missing
            if scenario == .empty {state.preferences.visibleCards=[]}
            state.preferences.showSeconds = scenario == .seconds
            let context=WorkbenchMiniContextData(time:scenario == .seconds ? "下午 10:24:56":"10:24",date:"10月25日 · 星期日",zone:"UTC−4",zoneHelp:"示例时区 · UTC−4",city:missing ? "未选择城市":"纽约",temperature:missing ? "—":"16°C",condition:missing ? "请先选择城市":"多云",symbol:missing ? "globe":"cloud.sun",weatherNote:nil,shortDate:"10月25日",weekday:"周日")
            let agenda=WorkbenchMiniAgendaData(event:nil,reminder:missing ? nil:.init(title:"整理下周计划",dateText:"10/26 · 09:00",note:nil),eventStatus:"日历未连接",reminderStatus:"暂无未完成待办")
            var device=WorkbenchMiniDeviceData()
            if !missing {
                device.memory="12.4 / 24 GB";device.memoryFraction=0.517;device.memoryPressure="压力低";device.memoryPressureState = .normal
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
                WorkbenchMiniAIData(provider:provider,title:provider.title,stateText:missing ? "不可用":"已用",detail:"Synthetic quota fixture",isStale:false,windows:[.init(label:"5小时",value:missing ? "—":"70%",fraction:missing ? nil:0.70,reset:"23时59分后"),.init(label:"每周",value:missing ? "—":"90%",fraction:missing ? nil:0.90,reset:"等待更新")])
            }
            let externalProviders:[WorkbenchMiniExternalProviderData] = scenario == .fourColumns ? [.init(id:UUID(),title:"示例流量服务",stateText:"已连接",amount:"899.95 / 1,000 GB",fraction:0.89995,detail:"Synthetic traffic fixture",isStale:false,remaining:"100.05",unit:"GB",reset:"1小时13分钟后重置")] : []
            let balances:[WorkbenchMiniAPIBalanceData] = scenario == .fourColumns ? [.init(id:UUID(),title:"示例余额服务",amount:"¥ 48.32",stateText:"已连接",detail:"Synthetic balance fixture",isStale:false)] : []
            availableCards = WorkbenchMiniCardID.builtIn + externalProviders.map { .provider($0.id) } + balances.map { .apiBalance($0.id) }
            let thermalStatus:DeviceThermalPresentation
            if scenario == .thermalCritical {
                device.temperature="96°C"; device.gpuTemperature="89°C";device.thermalState="系统高温"
                thermalStatus = .init(cpu:96,gpu:89,state:.serious)
            } else if scenario == .thermalWarning {
                device.temperature="87°C";device.gpuTemperature="68°C";device.thermalState="温度偏高"
                thermalStatus = .init(cpu:87,gpu:68,state:.nominal)
            } else {thermalStatus = .init(cpu:missing ? nil:48,gpu:missing ? nil:44,state:missing ? .unknown:.nominal)}
            let content=FixtureContent(state:state,context:context,agenda:agenda,device:device,providers:providers,externalProviders:externalProviders,balances:balances,thermalStatus:thermalStatus,safeTop:safeTop,notchWidth:notchWidth,configuring:scenario == .settings)
            let size=CGSize(width:width,height:WorkbenchMiniLayout.height(safeTop:safeTop))
            if interactive { window=NativeUIFixtureWindow(contentRect:CGRect(origin:.init(x:100,y:100),size:size),styleMask:[.borderless],backing:.buffered,defer:false) }
            else { window=NSWindow(contentRect:CGRect(origin:.init(x:100,y:100),size:size),styleMask:[.borderless],backing:.buffered,defer:false) }
            window.isReleasedWhenClosed=false;window.isOpaque=false;window.backgroundColor = .clear;window.ignoresMouseEvents = !interactive
            window.acceptsMouseMovedEvents = interactive
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
    private static func customAction(_ name: String, identifier: String) async -> Bool {
        // System AX messages must run off the main actor so AppKit can answer
        // queries and execute SwiftUI's real named secondary action handlers.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let result = await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
            let application = AXUIElementCreateApplication(ownPID)
            AXUIElementSetMessagingTimeout(application, 1)
            var pending = [application], visited: [AXUIElement] = []
            var details: [String] = []
            while let element = pending.popLast(), visited.count < 8_192 {
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                var rawIdentifier: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &rawIdentifier) == .success,
                   rawIdentifier as? String == identifier {
                    var rawActions: CFArray?
                    let error = AXUIElementCopyActionNames(element, &rawActions)
                    let actions = rawActions as? [String] ?? []
                    details.append("names=\(actions) query=\(error.rawValue)")
                    for action in actions {
                        var rawDescription: CFString?
                        AXUIElementCopyActionDescription(element, action as CFString, &rawDescription)
                        let description = rawDescription as String? ?? ""
                        details.append("action=\(action) description=\(description)")
                        guard action == name || description == name else { continue }
                        let performed = AXUIElementPerformAction(element, action as CFString)
                        return (performed == .success, "action=\(action) description=\(description) result=\(performed.rawValue)")
                    }
                }
                for attribute in [kAXWindowsAttribute, kAXChildrenAttribute] {
                    var children: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, attribute as CFString, &children) == .success,
                       let values = children as? [AXUIElement] { pending.append(contentsOf: values) }
                }
            }
            return (false, "visited=\(visited.count) " + details.joined(separator: "; "))
        }.value
        print("DETAIL Mini system AX action identifier=\(identifier) requested=\(name) \(result.1)")
        return result.0
    }
    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private static func rectRecord(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
}
