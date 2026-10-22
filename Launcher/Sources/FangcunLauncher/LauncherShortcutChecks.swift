import AppKit
import LauncherCore

@MainActor enum LauncherShortcutChecks {
    static func run()->(count:Int,failures:Int) {
        var count=0,failures=0
        func check(_ value:Bool,_ message:String){count += 1;if !value {failures += 1};print("\(value ? "PASS":"FAIL") \(message)")}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-launcher-hotkey-native-\(UUID().uuidString)")
        let owner=LauncherController(dataDirectory:directory),recorder=WorkbenchShortcutRecorder(),blocker=GlobalHotKey()
        owner.configuration.settings.workbenchHotKey=nil
        owner.configurePanel();owner.scanning=true
        defer {recorder.cancel();blocker.unregister();owner.bindingHotKeys.unregister();owner.hotKey.unregister();owner.toastTask?.cancel();owner.panel.orderOut(nil);try? FileManager.default.removeItem(at:directory)}
        do {
            try owner.store.save(owner.configuration)
            let first=BindingHotKey(keyCode:64,control:true,option:true,command:true)
            let next=BindingHotKey(keyCode:106,control:true,option:true,command:true)
            let occupied=BindingHotKey(keyCode:113,control:true,option:true,command:true)
            let workbench=BindingHotKey(keyCode:107,control:true,option:true,command:true)
            check(owner.setLauncherHotKey(first) && owner.hotKey.shortcut == first && owner.hotKey.choice == nil,
                  "recorded arbitrary launcher shortcut installs a real Carbon registration")
            check((try? owner.store.load())?.settings.effectiveLauncherHotKey == first,
                  "arbitrary launcher combination survives store reload")
            let before=try Data(contentsOf:owner.store.url)
            recorder.begin(owner:owner,target:.launcher);recorder.acceptCandidate(next)
            check(recorder.target == .launcher && recorder.draft == next && owner.hotKey.shortcut == first && (try? Data(contentsOf:owner.store.url)) == before,
                  "launcher recorder previews without replacing the active combination")
            recorder.cancel()
            check(owner.hotKey.shortcut == first && (try? Data(contentsOf:owner.store.url)) == before,
                  "cancelled launcher recording preserves configuration and registration")
            recorder.begin(owner:owner,target:.launcher);recorder.acceptCandidate(next)
            check(recorder.save() && owner.hotKey.shortcut == next && owner.configuration.settings.launcherHotKey == next,
                  "launcher recorder explicitly saves its captured combination")
            check(owner.setWorkbenchHotKey(workbench),"independent workbench registration coexists with arbitrary launcher shortcut")
            let saved=try Data(contentsOf:owner.store.url)
            recorder.begin(owner:owner,target:.launcher);recorder.acceptCandidate(workbench)
            check(!recorder.save() && owner.hotKey.shortcut == next && owner.bindingHotKeys.shortcuts[GlobalBindingHotKeys.workbenchKey] == workbench && (try? Data(contentsOf:owner.store.url)) == saved,
                  "launcher-workbench collision preserves both registered groups")
            recorder.cancel()
            check(blocker.register(occupied) == 0,"custom launcher conflict fixture reserves a distinct combination")
            recorder.begin(owner:owner,target:.launcher);recorder.acceptCandidate(occupied)
            check(!recorder.save() && owner.hotKey.shortcut == next && owner.bindingHotKeys.shortcuts[GlobalBindingHotKeys.workbenchKey] == workbench && (try? Data(contentsOf:owner.store.url)) == saved,
                  "external arbitrary launcher conflict restores the previous main and binding groups")
            recorder.cancel();blocker.unregister()

            let damaged=Data("invalid fixture configuration".utf8);try damaged.write(to:owner.store.url)
            recorder.begin(owner:owner,target:.launcher);recorder.acceptCandidate(first)
            check(!recorder.save() && owner.hotKey.shortcut == next && owner.bindingHotKeys.shortcuts[GlobalBindingHotKeys.workbenchKey] == workbench && (try? Data(contentsOf:owner.store.url)) == damaged,
                  "failed custom shortcut persistence rolls back all registrations and preserves damaged bytes")
            recorder.cancel();try saved.write(to:owner.store.url)
            recorder.begin(owner:owner,target:.launcher);recorder.clearCandidate()
            check(recorder.draft == HotKeyChoice.controlOptionSpace.bindingHotKey && owner.hotKey.shortcut == next,
                  "restore-default remains an unsaved launcher candidate until explicit Save")
            recorder.cancel()
        } catch {check(false,"launcher shortcut native fixture: "+error.localizedDescription)}
        return(count,failures)
    }
}
