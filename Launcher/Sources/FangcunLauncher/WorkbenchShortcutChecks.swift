import AppKit
import LauncherCore

/// Isolated native transaction checks. The caller supplies the normal test app
/// lifecycle; no real configuration, launch target or permission is touched.
@MainActor
enum WorkbenchShortcutChecks {
    static func run() -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-workbench-shortcut-native-\(UUID().uuidString)")
        let owner = LauncherController(dataDirectory: directory)
        let recorder = WorkbenchShortcutRecorder(), blocker = GlobalBindingHotKeys()
        owner.configuration.settings.workbenchHotKey = nil
        owner.configurePanel(); owner.scanning = true
        defer {
            recorder.cancel(); blocker.unregister(); owner.bindingHotKeys.unregister(); owner.hotKey.unregister()
            owner.toastTask?.cancel(); owner.panel.orderOut(nil)
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            try owner.store.save(owner.configuration)
            let initial = BindingHotKey(keyCode: 90, control: true, option: true, command: true)
            let next = BindingHotKey(keyCode: 80, control: true, option: true, command: true)
            let occupied = BindingHotKey(keyCode: 79, control: true, option: true, command: true)
            check(owner.setWorkbenchHotKey(initial) && owner.bindingHotKeys.shortcuts[GlobalBindingHotKeys.workbenchKey] == initial,
                  "workbench shortcut registers through the production transaction")
            let beforeDraft = try Data(contentsOf: owner.store.url)
            recorder.begin(owner: owner); recorder.acceptCandidate(next)
            check(recorder.isPresented && recorder.draft == next && owner.configuration.settings.workbenchHotKey == initial
                  && owner.bindingHotKeys.shortcuts[GlobalBindingHotKeys.workbenchKey] == initial
                  && (try? Data(contentsOf: owner.store.url)) == beforeDraft,
                  "recording only changes its candidate, never the active shortcut or saved bytes")
            recorder.cancel()
            check(!recorder.isPresented && owner.workbenchShortcutRecorder == nil && (try? Data(contentsOf: owner.store.url)) == beforeDraft,
                  "cancel removes recorder ownership and preserves saved shortcut")
            recorder.begin(owner: owner); recorder.acceptCandidate(next)
            check(recorder.save() && owner.configuration.settings.workbenchHotKey == next
                  && owner.bindingHotKeys.shortcuts[GlobalBindingHotKeys.workbenchKey] == next
                  && (try? owner.store.load())?.settings.workbenchHotKey == next,
                  "explicit save persists and installs the captured workbench combination")

            let saved = try Data(contentsOf: owner.store.url)
            recorder.begin(owner: owner); recorder.acceptCandidate(owner.configuration.settings.effectiveLauncherHotKey)
            check(!recorder.save() && recorder.error != nil && owner.configuration.settings.workbenchHotKey == next
                  && owner.bindingHotKeys.shortcuts[GlobalBindingHotKeys.workbenchKey] == next
                  && (try? Data(contentsOf: owner.store.url)) == saved,
                  "launcher shortcut collision keeps the recorder open and preserves old registration")
            recorder.cancel()

            check(blocker.register([GlobalBindingHotKeys.workbenchKey: occupied]) == 0,
                  "native conflict fixture reserves a separate combination")
            recorder.begin(owner: owner); recorder.acceptCandidate(occupied)
            check(!recorder.save() && recorder.error != nil && owner.configuration.settings.workbenchHotKey == next
                  && owner.bindingHotKeys.shortcuts[GlobalBindingHotKeys.workbenchKey] == next
                  && (try? Data(contentsOf: owner.store.url)) == saved,
                  "OS registration conflict rolls back without replacing the working shortcut")
            recorder.cancel(); blocker.unregister()

            recorder.begin(owner: owner); recorder.attach(window: owner.panel)
            check(!recorder.captureRegisteredHotKey(next), "a hidden window cannot consume a registered shortcut")
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: owner.panel)
            check(!recorder.isPresented && owner.workbenchShortcutRecorder == nil,
                  "window focus loss cancels production shortcut recording")
            recorder.begin(owner: owner); recorder.attach(window: owner.panel)
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: owner.panel)
            check(!recorder.isPresented && (try? Data(contentsOf: owner.store.url)) == saved,
                  "closing the recording host cancels without saving")

            check(owner.setWorkbenchHotKey(nil) && owner.bindingHotKeys.shortcuts[GlobalBindingHotKeys.workbenchKey] == nil
                  && (try? owner.store.load())?.settings.workbenchHotKey == nil,
                  "clearing the workbench shortcut unregisters it and survives reload")
        } catch { check(false, "workbench shortcut fixture: \(error.localizedDescription)") }
        return (count, failures)
    }
}
