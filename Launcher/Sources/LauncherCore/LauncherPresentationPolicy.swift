import Foundation

/// Presentation choices never disable a configured view or erase its bindings.
public enum LauncherPresentationPolicy {
    public static func initialView(_ settings:LauncherSettings) -> LauncherDefaultView {
        if !settings.actionsEnabled {return .applications}
        if !settings.applicationsEnabled {return .keys}
        return settings.defaultView
    }
    public static func visibleKeys(settings:LauncherSettings,bindings:[String:KeyBinding],editing:Bool) -> [String] {
        KeyboardLayout.keys.filter{editing || !settings.hideUnboundKeys || bindings[$0] != nil}
    }
}

/// A candidate remains separate until LauncherController validates registration
/// and atomically saves it. Duplicate applications move only after confirmation.
public enum LauncherBindingMutation {
    public static func duplicateApplicationKey(_ binding:KeyBinding,key:String,in configuration:LauncherConfiguration) -> String? {
        guard binding.target.kind == .app else {return nil}
        return KeyboardLayout.keys.first{$0 != key && configuration.bindings[$0]?.target.id == binding.target.id}
    }
    public static func replacing(_ binding:KeyBinding?,key:String,in configuration:LauncherConfiguration,movingDuplicate:Bool=false) throws -> LauncherConfiguration {
        guard KeyboardLayout.keys.contains(key) else {throw LauncherError.invalidTarget("不支持这个键位。")}
        var candidate=configuration
        if let binding {
            try binding.target.validate()
            guard binding.alias.count <= 64 else {throw LauncherError.invalidTarget("显示名称最多 64 个字符。")}
            if let duplicate=duplicateApplicationKey(binding,key:key,in:configuration) {
                guard movingDuplicate else {throw LauncherError.invalidTarget("这个应用已绑定在 \(duplicate)，需要确认移动。")}
                candidate.bindings.removeValue(forKey:duplicate)
            }
            candidate.bindings[key]=binding
        } else {candidate.bindings.removeValue(forKey:key)}
        candidate.bindingHotKeys=candidate.bindingHotKeys.filter{candidate.bindings[$0.key] != nil}
        try candidate.validate()
        return candidate
    }
}
