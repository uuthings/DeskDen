import AppKit
import SwiftUI
import LauncherCore

/// Offscreen native views use the production cached-modal infrastructure and
/// the actual context dialogs. Fixture drafts replace only initial UI state;
/// an injected offline provider prevents any real weather request or location use.
@MainActor enum WorkbenchContextDraftChecks {
    static func run() async -> (count: Int, failures: Int) {
        #if DEBUG
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) { count += 1; if !condition { failures += 1 }; print("\(condition ? "PASS" : "FAIL") \(name)") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-context-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkbenchContextModel(dataDirectory: directory, provider: ContextDraftOfflineProvider())
        defer { model.stop() }
        do {
            check(model.saveClock(zone: "UTC", twelveHour: false), "context draft fixture starts from saved clock preferences")
            let saved = try Data(contentsOf: directory.appendingPathComponent("context.json"))
            var clock = WorkbenchClockDraft(settings: model.settings)
            check(!clock.hasChanges, "clock draft starts clean from persisted zone and hour format")
            clock.zone = "Asia/Tokyo"
            check(clock.hasChanges, "changed display zone is an unsaved clock draft")
            clock.zone = "UTC"; clock.twelveHour = true
            check(clock.hasChanges, "hour-format change independently makes the clock draft dirty")
            clock.twelveHour = false
            check(!clock.hasChanges, "reverting both clock fields restores a clean draft")
            clock.zone = "Asia/Tokyo"; clock.twelveHour = true

            let clockClose = WorkbenchDraftCloseCoordinator(), clockModals = WorkbenchModalCoordinator()
            model.showClock = true
            let clockWindow = mount(model: model, close: clockClose, coordinator: clockModals, clock: clock)
            defer { clockModals.clear(); clockWindow.close() }
            let clockMounted = await wait(window: clockWindow) { clockModals.presentations.count == 1 }
            check(clockMounted, "actual clock dialog mounts through the cached shared native modal")
            clockModals.dismissTop()
            let clockConfirmed = await wait(window: clockWindow) { clockClose.confirmingDiscard && clockModals.presentations.count == 2 }
            check(clockConfirmed && model.showClock, "outside or Escape close reaches the observed clock child and opens a second discard layer")
            clockModals.dismissTop()
            let clockContinued = await wait(window: clockWindow) { !clockClose.confirmingDiscard && clockModals.presentations.count == 1 }
            check(clockContinued && model.showClock, "closing discard confirmation continues clock editing without closing the parent")
            clockModals.dismissTop()
            let clockConfirmedAgain = await wait(window: clockWindow) { clockClose.confirmingDiscard && clockModals.presentations.count == 2 }
            check(clockConfirmedAgain && clockClose.closeRequests == 2,
                  "clock close signals remain observable after cached presentation and continued editing retains dirty draft")
            check((try? Data(contentsOf: directory.appendingPathComponent("context.json"))) == saved && model.settings.timeZoneIdentifier == "UTC" && !model.settings.twelveHour,
                  "clock confirmation and continued editing cannot persist either draft field")
            clockClose.discardChanges { model.showClock = false }
            let clockDiscarded = await wait(window: clockWindow) { clockModals.presentations.isEmpty }
            check(clockDiscarded && !model.showClock && (try? Data(contentsOf: directory.appendingPathComponent("context.json"))) == saved,
                  "explicit clock discard removes both modal layers while preserving saved preference bytes")
            clockModals.clear(); clockWindow.close(); clockWindow.contentView = nil

            let cleanClose = WorkbenchDraftCloseCoordinator(), cleanModals = WorkbenchModalCoordinator()
            model.showClock = true
            let cleanWindow = mount(model: model, close: cleanClose, coordinator: cleanModals, clock: WorkbenchClockDraft(settings: model.settings))
            defer { cleanModals.clear(); cleanWindow.close() }
            _ = await wait(window: cleanWindow) { cleanModals.presentations.count == 1 }
            cleanModals.dismissTop()
            let cleanDismissed = await wait(window: cleanWindow) { !model.showClock && cleanModals.presentations.isEmpty }
            check(cleanDismissed && !cleanClose.confirmingDiscard,
                  "unchanged actual clock dialog closes directly without a discard question")
            cleanModals.clear(); cleanWindow.close(); cleanWindow.contentView = nil

            let berlin = WeatherCity(id: "draft:berlin", name: "Berlin", latitude: 52.5, longitude: 13.4, timeZoneIdentifier: "Europe/Berlin")
            var weather = WorkbenchWeatherDraft(city: nil)
            check(!weather.hasChanges, "unset weather city starts as a clean draft")
            weather.city = berlin
            check(weather.hasChanges, "choosing a city creates an unsaved weather draft")
            let weatherClose = WorkbenchDraftCloseCoordinator(), weatherModals = WorkbenchModalCoordinator()
            model.showWeather = true
            let weatherWindow = mount(model: model, close: weatherClose, coordinator: weatherModals, weather: weather)
            defer { weatherModals.clear(); weatherWindow.close() }
            _ = await wait(window: weatherWindow) { weatherModals.presentations.count == 1 }
            weatherModals.dismissTop()
            let weatherConfirmed = await wait(window: weatherWindow) { weatherClose.confirmingDiscard && weatherModals.presentations.count == 2 }
            check(weatherConfirmed && model.showWeather && model.settings.city == nil,
                  "actual weather dialog opens discard confirmation instead of saving or closing its selected-city draft")
            weatherModals.dismissTop()
            _ = await wait(window: weatherWindow) { !weatherClose.confirmingDiscard && weatherModals.presentations.count == 1 }
            weatherModals.dismissTop()
            let weatherAgain = await wait(window: weatherWindow) { weatherClose.confirmingDiscard && weatherModals.presentations.count == 2 }
            check(weatherAgain && weatherClose.closeRequests == 2 && model.showWeather,
                  "continuing weather editing retains the actual city draft and later close signals are not stale")
            weatherClose.discardChanges { model.showWeather = false }
            let weatherDiscarded = await wait(window: weatherWindow) { weatherModals.presentations.isEmpty }
            check(weatherDiscarded && model.settings.city == nil && (try? Data(contentsOf: directory.appendingPathComponent("context.json"))) == saved,
                  "weather discard clears both layers and cannot persist preview city or change the clock")
            weatherModals.clear(); weatherWindow.close(); weatherWindow.contentView = nil
            var cleared = WorkbenchWeatherDraft(city: berlin); cleared.city = nil
            check(cleared.hasChanges, "clearing an existing saved city also requires discard protection")
            weather.city = nil
            check(!weather.hasChanges, "reverting selected city to the saved nil value makes weather clean again")
            model.showClock = true
            check(model.saveClock(zone: clock.zone, twelveHour: clock.twelveHour) && !model.showClock,
                  "explicit clock save uses the real model and closes normally with both draft values saved")
            let reloaded = WorkbenchContextModel(dataDirectory: directory, provider: ContextDraftOfflineProvider())
            check(reloaded.settings.timeZoneIdentifier == "Asia/Tokyo" && reloaded.settings.twelveHour,
                  "successful draft save survives an independent context reload")
            reloaded.stop()
        } catch { check(false, "context draft fixture setup: \(error.localizedDescription)") }
        return (count, failures)
        #else
        return (0, 0)
        #endif
    }
    #if DEBUG
    private static func mount(model: WorkbenchContextModel, close: WorkbenchDraftCloseCoordinator,
                              coordinator: WorkbenchModalCoordinator, clock: WorkbenchClockDraft? = nil, weather: WorkbenchWeatherDraft? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = ContextDraftModalFixture(model: model, close: close, coordinator: coordinator, clock: clock, weather: weather)
        window.contentView = NSHostingView(rootView: view.nativeCheckAccessibility())
        window.contentView?.frame = NSRect(x: 0, y: 0, width: 900, height: 760)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }
    private static func wait(window: NSWindow, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < deadline
        return condition()
    }
    #endif
}

#if DEBUG
private struct ContextDraftModalFixture: View {
    @ObservedObject var model: WorkbenchContextModel
    @ObservedObject var close: WorkbenchDraftCloseCoordinator
    @ObservedObject var coordinator: WorkbenchModalCoordinator
    let clock: WorkbenchClockDraft?
    let weather: WorkbenchWeatherDraft?
    var body: some View {
        ZStack {
            if let clock {
                Color.clear.workbenchModal(isPresented: $model.showClock, onRequestDismiss: close.requestClose) {
                    WorkbenchContextDialogViewsForChecks.clock(model: model, close: close, draft: clock)
                }
            }
            if let weather {
                Color.clear.workbenchModal(isPresented: $model.showWeather, onRequestDismiss: close.requestClose) {
                    WorkbenchContextDialogViewsForChecks.weather(model: model, close: close, draft: weather)
                }
            }
            WorkbenchModalHost(coordinator: coordinator)
        }.environment(\.workbenchModals, coordinator)
    }
}
#endif

private actor ContextDraftOfflineProvider: WeatherProviding {
    nonisolated let providerID = "context-draft-offline-fixture"
    func searchCities(query: String, language: String) async throws -> [WeatherCity] { [] }
    func currentWeather(for city: WeatherCity, receivedAt: Date) async throws -> WeatherSnapshot { throw URLError(.notConnectedToInternet) }
}

/// Exercise the real native window dispatch rather than calling the model's
/// cancellation helper. The existing workbench host avoids a second AX/window
/// lifecycle, and the clock child retains its actual unsaved-draft protection.
@MainActor enum WorkbenchCancelOperationChecks {
    static func run(model:WorkbenchAppModel,workbench:WorkbenchWindowController,owner:LauncherController) async -> (count:Int,failures:Int) {
        #if DEBUG
        var count=0,failures=0
        func check(_ condition:Bool,_ name:String) {count+=1;if !condition {failures+=1};print("\(condition ? "PASS":"FAIL") \(name)")}
        guard let window=workbench.window,let root=window.contentView,!model.modals.isPresented,!model.confirmingQuit else {
            check(false,"native cancel fixture starts in the existing idle workbench window");return(count,failures)
        }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-native-cancel-\(UUID().uuidString)")
        let context=WorkbenchContextModel(dataDirectory:directory,provider:ContextDraftOfflineProvider())
        let close=WorkbenchDraftCloseCoordinator()
        let originalMenu=model.brandMenuPresented
        let oldReply=owner.replyToSystemTermination,oldTerminate=owner.terminateApplication
        var replies:[Bool]=[],terminations=0
        owner.replyToSystemTermination={replies.append($0)};owner.terminateApplication={terminations+=1}
        var presenter:NSView?
        defer {
            context.showClock=false;context.stop();model.modals.clear();model.confirmingQuit=false
            model.brandMenuPresented=originalMenu
            window.makeFirstResponder(nil);presenter?.removeFromSuperview()
            workbench.present()
            owner.replyToSystemTermination=oldReply;owner.terminateApplication=oldTerminate
            try? FileManager.default.removeItem(at:directory)
        }
        do {
            guard context.saveClock(zone:"UTC",twelveHour:false) else {throw ReminderError.invalid("取消检查无法建立隔离时区偏好。")}
            let saved=try Data(contentsOf:directory.appendingPathComponent("context.json"))
            var draft=WorkbenchClockDraft(settings:context.settings);draft.zone="Asia/Tokyo"
            let source=NSHostingView(rootView:CancelClockPresenter(context:context,close:close,coordinator:model.modals,draft:draft).nativeCheckAccessibility())
            source.frame=NSRect(x:0,y:0,width:1,height:1);root.addSubview(source);presenter=source
            context.showClock=true
            let mounted=await wait(window){model.modals.presentations.count == 1}
            let parentID=model.modals.top?.id
            check(mounted && parentID != nil,"native cancel mounts the actual dirty clock in the existing workbench host")
            let noInputFocus=sendEscape(to:window)
            let guarded=await wait(window){close.confirmingDiscard && model.modals.presentations.count == 2}
            check(noInputFocus && guarded && context.showClock && close.closeRequests == 1,
                  "Escape without an input responder reaches the real dirty-form close request exactly once")
            _=sendEscape(to:window)
            let continued=await wait(window){!close.confirmingDiscard && model.modals.presentations.count == 1}
            check(continued && model.modals.top?.id == parentID && context.showClock && (try? Data(contentsOf:directory.appendingPathComponent("context.json"))) == saved,
                  "a second unfocused Escape closes only the nested discard layer and preserves the original unsaved editor")

            let text=CancelOwningTextView(frame:NSRect(x:4,y:4,width:100,height:24))
            text.isEditable=true;text.isRichText=false;root.addSubview(text)
            let focused=window.makeFirstResponder(text)
            sendEscapeEvent(to:window)
            _=await wait(window){text.cancellations == 1}
            check(focused && window.firstResponder === text && text.cancellations == 1 && !close.confirmingDiscard && model.modals.top?.id == parentID,
                  "a focused text responder consumes its local Escape before the window fallback can close the form")
            window.makeFirstResponder(nil);text.removeFromSuperview()
            _=sendEscape(to:window)
            let guardedAgain=await wait(window){close.confirmingDiscard && model.modals.presentations.count == 2}
            check(guardedAgain && close.closeRequests == 2 && context.settings.timeZoneIdentifier == "UTC",
                  "after local text handling, an unfocused Escape still reopens draft protection without saving")
            close.discardChanges{context.showClock=false}
            _=await wait(window){model.modals.presentations.isEmpty}
            source.removeFromSuperview();presenter=nil

            model.brandMenuPresented=true
            _=sendEscape(to:window)
            check(!model.brandMenuPresented && window.isVisible,"unfocused Escape dismisses the real brand menu while leaving the workbench open")
            let reply=owner.applicationShouldTerminate(NSApp)
            _=await wait(window){model.confirmingQuit}
            let noQuitFocus=sendEscape(to:window)
            _=await wait(window){!model.confirmingQuit}
            check(reply == .terminateLater && noQuitFocus && !model.confirmingQuit && !owner.systemTerminationPending && replies == [false] && terminations == 0 && window.isVisible,
                  "unfocused Escape cancels native quit confirmation and replies false exactly once without terminating or hiding")
            _=model.requestQuit();_=await wait(window){model.confirmingQuit}
            _=sendEscape(to:window)
            check(!model.confirmingQuit && replies == [false] && terminations == 0 && !model.quitting,
                  "the same unfocused cancel path dismisses in-app quit without preparing or executing termination")

            workbench.presentFromTopEntry()
            let topMounted=await wait(window){workbench.presentationWindow is NSPanel && model.isTopEntryPresentation}
            if let panel=workbench.presentationWindow,topMounted {
                model.brandMenuPresented=true
                let topNoInput=sendEscape(to:panel)
                check(topNoInput && !model.brandMenuPresented && panel.isVisible && workbench.presentationWindow === panel,
                      "the nonactivating top panel shares the unfocused cancel fallback without closing or replacing its host")
            } else {check(false,"the top-entry panel mounts for native cancellation")}
            workbench.present()
        } catch {check(false,"native cancel setup: \(error.localizedDescription)")}
        return(count,failures)
        #else
        return(0,0)
        #endif
    }
    #if DEBUG
    private static func sendEscape(to window:NSWindow)->Bool {
        window.makeFirstResponder(nil)
        let noInput=window.firstResponder == nil || window.firstResponder === window
        sendEscapeEvent(to:window)
        return noInput
    }
    private static func sendEscapeEvent(to window:NSWindow) {
        guard let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) else {return}
        window.sendEvent(event)
    }
    private static func wait(_ window:NSWindow,_ condition:@MainActor ()->Bool) async -> Bool {
        let deadline=ContinuousClock.now.advanced(by:.seconds(1))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() {return true}
            try? await Task.sleep(for:.milliseconds(2))
        } while ContinuousClock.now < deadline
        return condition()
    }
    #endif
}

#if DEBUG
private struct CancelClockPresenter:View {
    @ObservedObject var context:WorkbenchContextModel
    @ObservedObject var close:WorkbenchDraftCloseCoordinator
    let coordinator:WorkbenchModalCoordinator
    let draft:WorkbenchClockDraft
    var body:some View {
        Color.clear.workbenchModal(isPresented:$context.showClock,onRequestDismiss:close.requestClose) {
            WorkbenchContextDialogViewsForChecks.clock(model:context,close:close,draft:draft)
        }.environment(\.workbenchModals,coordinator)
    }
}

@MainActor private final class CancelOwningTextView:NSTextView {
    private(set) var cancellations=0
    override func cancelOperation(_ sender:Any?) {cancellations+=1}
}
#endif
