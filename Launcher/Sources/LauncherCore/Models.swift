import Foundation

public enum KeyboardLayout {
    public static let rows = ["1234567890-=", "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"].map { $0.map(String.init) }
    public static let keys = rows.flatMap { $0 }
    // Physical ANSI positions, independent of the active input source.
    public static let keyCodes: [UInt16: String] = [18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",27:"-",24:"=",12:"Q",13:"W",14:"E",15:"R",17:"T",16:"Y",32:"U",34:"I",31:"O",35:"P",0:"A",1:"S",2:"D",3:"F",5:"G",4:"H",38:"J",40:"K",37:"L",6:"Z",7:"X",8:"C",9:"V",11:"B",45:"N",46:"M"]
}

public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    case full, key, name, icon, list
    public var title: String { switch self { case .full: "图标、按键与名称"; case .key: "图标与按键"; case .name: "图标与名称"; case .icon: "仅图标"; case .list: "列表" } }
    public var showsName: Bool { self == .full || self == .name || self == .list }
    public var showsKey: Bool { self == .full || self == .key || self == .list }
    public var width: Double { 1080 }
    public var keySize: Double { 80 }
    public var iconSize: Double { switch self { case .full: 45; case .name: 54; case .key: 50; case .icon: 57; case .list: 28 } }
    public var rowGap: Double { 0 }
    public var rowHeight: Double { switch self { case .full: 98; case .name: 92; case .key, .icon: 82; case .list: 48 } }
    public var height: Double { 560 }
}

public enum TargetKind: String, Codable, CaseIterable, Sendable {
    case app, file, folder, web, shortcut, tool, shell
    public var title: String { switch self { case .app: "应用"; case .file: "文件"; case .folder: "文件夹"; case .web: "网页"; case .shortcut: "快捷指令"; case .tool: "方寸工具"; case .shell: "Shell 脚本" } }
    public var symbol: String { switch self { case .app: "app"; case .file: "doc"; case .folder: "folder"; case .web: "globe"; case .shortcut: "square.stack.3d.up"; case .tool: "rectangle.3.group"; case .shell: "terminal" } }
    public var isFileSystem: Bool { [.app,.file,.folder,.shell].contains(self) }
}

public struct LaunchTarget: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var kind: TargetKind
    public var name: String
    public var location: String
    public var bundleIdentifier: String?
    public var bookmark: Data?
    /// A small, normalized PNG. Optional so configurations written before custom icons remain readable.
    public var iconData: Data?
    /// True only for a user-selected image; automatic website icons refresh when the destination changes.
    public var iconIsCustom: Bool?
    public var keywords: String
    public var id: String { kind.rawValue + ":" + location }
    public init(kind: TargetKind, name: String, location: String, bundleIdentifier: String? = nil, bookmark: Data? = nil, keywords: String = "", iconData: Data? = nil, iconIsCustom: Bool? = nil) {
        self.kind = kind; self.name = name; self.location = location; self.bundleIdentifier = bundleIdentifier; self.bookmark = bookmark; self.keywords = keywords; self.iconData = iconData; self.iconIsCustom = iconIsCustom
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 256, !location.isEmpty, location.count <= 8192 else { throw LauncherError.invalidTarget("目标名称或地址无效。") }
        guard iconData == nil || iconData!.count <= 131_072 else { throw LauncherError.invalidTarget("图标过大，请重新选择图片。") }
        if kind == .web {
            _ = try WebURLTemplate(location)
        }
        if kind.isFileSystem {
            guard location.hasPrefix("/"), !location.contains("\0") else { throw LauncherError.invalidTarget("请选择有效的本地目标。") }
            if kind == .app && URL(fileURLWithPath: location).pathExtension.lowercased() != "app" { throw LauncherError.invalidTarget("请选择 .app 应用。") }
            if kind == .shell && URL(fileURLWithPath: location).pathExtension.lowercased() != "sh" { throw LauncherError.invalidTarget("请选择 .sh 脚本文件。") }
        }
    }
}

public struct KeyBinding: Codable, Equatable, Sendable {
    public var target: LaunchTarget
    public var alias: String
    public var title: String { alias.isEmpty ? target.name : alias }
    public init(target: LaunchTarget, alias: String = "") { self.target = target; self.alias = alias.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum HotKeyChoice: String, Codable, CaseIterable, Sendable {
    case controlOptionSpace, optionSpace, controlSpace
    public var title: String { switch self { case .controlOptionSpace: "⌃ ⌥ 空格"; case .optionSpace: "⌥ 空格"; case .controlSpace: "⌃ 空格" } }
}
// Keep the legacy `list` value so saved preferences now open the vertical icon grid.
public enum ResultLayout: String, Codable, Sendable { case grid, list; public var pageSize: Int { 21 } }
public enum SearchInputMode: String, Codable, CaseIterable, Sendable {
    case quick, text
    public var title: String { self == .quick ? "按键搜索" : "文字输入" }
}
public enum LauncherDefaultView:String,Codable,CaseIterable,Sendable {
    case keys,applications
    public var title:String {self == .keys ? "按键":"应用"}
}
/// The actions view precedes the paged applications view. Scrolling within the
/// application grid retains page navigation; crossing its leading edge returns
/// to actions only when both views and cross-view scrolling are enabled.
public enum HorizontalNavigation: Equatable, Sendable {
    case none, actions, applications, page(Int)
    public static func destination(applications:Bool,page:Int,direction:Int,settings:LauncherSettings) -> Self {
        guard direction != 0, settings.resultLayout == .grid else { return .none }
        let canSwitch = settings.scrollSwitchesViews && settings.actionsEnabled && settings.applicationsEnabled
        if !applications { return canSwitch && direction > 0 ? .applications : .none }
        guard settings.applicationsEnabled else { return .none }
        if direction < 0, page == 0, canSwitch { return .actions }
        return .page(direction < 0 ? -1 : 1)
    }
}
/// The five environments share their layout and status semantics.
/// Legacy prototype names decode here so an obsolete theme cannot create an
/// additional appearance that the native app no longer supports.
public enum LauncherTheme: String, Codable, CaseIterable, Sendable {
    case qingbiMist, moonCloudSea, warmSunset, arWorld, thunderCabin

    public var title: String {
        switch self {
        case .qingbiMist: "青碧晨雾"
        case .moonCloudSea: "月白云海"
        case .warmSunset: "暖霞悬山"
        case .arWorld: "AR 世界"
        case .thunderCabin: "雷霆机舱"
        }
    }
    public var backgroundResource: String {
        switch self {
        case .qingbiMist: "qingbi-chenwu"
        case .moonCloudSea: "yuebai-yunhai"
        case .warmSunset: "nuanxia-xuanshan"
        case .arWorld: "ar-world"
        case .thunderCabin: "thunder-cabin"
        }
    }
    public var isMountain: Bool { self == .qingbiMist || self == .moonCloudSea || self == .warmSunset }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "qingbiMist": self = .qingbiMist
        case "moonCloudSea": self = .moonCloudSea
        case "warmSunset": self = .warmSunset
        case "thunderCabin", "dusk", "mecha": self = .thunderCabin
        default: self = .arWorld
        }
    }
}

public enum LauncherAppearance: String, Codable, CaseIterable, Sendable {
    case dark, light, system
    public var title: String {
        switch self { case .dark: "深色"; case .light: "浅色"; case .system: "跟随系统" }
    }
}

public enum ButtonHoverCursor: String, Codable, CaseIterable, Sendable {
    case pointingHand, arrow
    public var title: String { self == .pointingHand ? "小手" : "箭头" }
}

public struct LauncherSettings: Codable, Equatable, Sendable {
    public static let defaultLauncherHotKey = BindingHotKey(keyCode: 2, option: true)
    public static let defaultWorkbenchHotKey = BindingHotKey(keyCode: 3, option: true)
    public var display: DisplayMode = .name
    public var hotKey: HotKeyChoice = .controlOptionSpace
    /// Nil preserves the legacy three-choice preference; recorded combinations override it.
    public var launcherHotKey: BindingHotKey? = Self.defaultLauncherHotKey
    public var effectiveLauncherHotKey:BindingHotKey {launcherHotKey ?? hotKey.bindingHotKey}
    public var directLaunchPrefix: KeyShortcutPrefix?
    public var applicationViewHotKey: BindingHotKey?
    /// New installations receive a dedicated workbench shortcut. Missing legacy
    /// fields stay disabled so migration cannot claim an already-used combination.
    public var workbenchHotKey: BindingHotKey? = Self.defaultWorkbenchHotKey
    public var hideOnLaunch = true
    public var resultLayout: ResultLayout = .grid
    public var reduceMotion = false
    public var buttonHoverCursor: ButtonHoverCursor = .pointingHand
    public var lightAppearance = false
    public var glassOpacity: Double = 0.70
    public var workbenchTheme: LauncherTheme = .qingbiMist
    public var workbenchAppearance: LauncherAppearance = .dark
    public var backgroundMotionEnabled = true
    // A saved version distinguishes a legal old value that needs clamping from
    // a malformed current value, which must be preserved for explicit recovery.
    private var interfaceMaterialVersion = 2
    public var appSort: AppSortMode = .nameAscending
    public var defaultSearchInputMode: SearchInputMode = .quick
    public var defaultView:LauncherDefaultView = .keys
    public var hideUnboundKeys=false
    public var actionsEnabled = true
    public var applicationsEnabled = true
    public var scrollSwitchesViews = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case display, hotKey, launcherHotKey, hideOnLaunch, resultLayout, reduceMotion, buttonHoverCursor, lightAppearance, glassOpacity, workbenchTheme, workbenchAppearance, backgroundMotionEnabled, interfaceMaterialVersion, appSort, directLaunchPrefix, applicationViewHotKey, workbenchHotKey, defaultSearchInputMode, defaultView, hideUnboundKeys, actionsEnabled, applicationsEnabled, scrollSwitchesViews }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        display = try values.decodeIfPresent(DisplayMode.self, forKey: .display) ?? .name
        hotKey = try values.decodeIfPresent(HotKeyChoice.self, forKey: .hotKey) ?? .controlOptionSpace
        launcherHotKey = try values.decodeIfPresent(BindingHotKey.self, forKey: .launcherHotKey)
        directLaunchPrefix = try values.decodeIfPresent(KeyShortcutPrefix.self, forKey: .directLaunchPrefix)
        applicationViewHotKey = try values.decodeIfPresent(BindingHotKey.self, forKey: .applicationViewHotKey)
        workbenchHotKey = try values.decodeIfPresent(BindingHotKey.self, forKey: .workbenchHotKey)
        hideOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .hideOnLaunch) ?? true
        resultLayout = try values.decodeIfPresent(ResultLayout.self, forKey: .resultLayout) ?? .grid
        reduceMotion = try values.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
        buttonHoverCursor = try values.decodeIfPresent(ButtonHoverCursor.self, forKey: .buttonHoverCursor) ?? .pointingHand
        lightAppearance = try values.decodeIfPresent(Bool.self, forKey: .lightAppearance) ?? false
        let materialVersion = try values.decodeIfPresent(Int.self, forKey: .interfaceMaterialVersion)
        guard materialVersion == nil || materialVersion == 2 else {
            throw LauncherError.invalidTarget("界面材质配置来自更新版本，原文件已保留。")
        }
        let storedOpacity = try values.decodeIfPresent(Double.self, forKey: .glassOpacity)
        if materialVersion == nil, let storedOpacity {
            guard storedOpacity.isFinite, (0.30...1).contains(storedOpacity) else {
                throw LauncherError.invalidTarget("原界面不透明度无效，原文件已保留。")
            }
            glassOpacity = min(0.90, max(0.50, storedOpacity))
        } else {
            glassOpacity = storedOpacity ?? 0.70
        }
        workbenchTheme = try values.decodeIfPresent(LauncherTheme.self, forKey: .workbenchTheme) ?? .arWorld
        workbenchAppearance = try values.decodeIfPresent(LauncherAppearance.self, forKey: .workbenchAppearance) ?? (lightAppearance ? .light : .dark)
        backgroundMotionEnabled = try values.decodeIfPresent(Bool.self, forKey: .backgroundMotionEnabled) ?? true
        appSort = try values.decodeIfPresent(AppSortMode.self, forKey: .appSort) ?? .nameAscending
        defaultSearchInputMode = try values.decodeIfPresent(SearchInputMode.self, forKey: .defaultSearchInputMode) ?? .quick
        defaultView = try values.decodeIfPresent(LauncherDefaultView.self,forKey:.defaultView) ?? .keys
        hideUnboundKeys = try values.decodeIfPresent(Bool.self,forKey:.hideUnboundKeys) ?? false
        actionsEnabled = try values.decodeIfPresent(Bool.self, forKey: .actionsEnabled) ?? true
        applicationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .applicationsEnabled) ?? true
        scrollSwitchesViews = try values.decodeIfPresent(Bool.self, forKey: .scrollSwitchesViews) ?? true
    }
}
public struct LauncherConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var settings = LauncherSettings()
    public var bindings: [String: KeyBinding] = [:]
    public var bindingHotKeys: [String:BindingHotKey] = [:]
    public var addedApplications: [LaunchTarget] = []
    public var applicationOrder: [String] = []
    public var scanDirectories: [String] = []
    public var hiddenApplications: [String] = []
    public var starredApplications: [String] = []
    public var applicationMetadata: [String:ApplicationMetadata] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, settings, bindings, bindingHotKeys, addedApplications, applicationOrder, scanDirectories, hiddenApplications, starredApplications, applicationMetadata }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        settings = try values.decode(LauncherSettings.self, forKey: .settings)
        bindings = try values.decode([String:KeyBinding].self, forKey: .bindings)
        bindingHotKeys = try values.decodeIfPresent([String:BindingHotKey].self, forKey: .bindingHotKeys) ?? [:]
        addedApplications = try values.decodeIfPresent([LaunchTarget].self, forKey: .addedApplications) ?? []
        applicationOrder = try values.decodeIfPresent([String].self, forKey: .applicationOrder) ?? []
        scanDirectories = try values.decodeIfPresent([String].self, forKey: .scanDirectories) ?? []
        hiddenApplications = try values.decodeIfPresent([String].self, forKey: .hiddenApplications) ?? []
        starredApplications = try values.decodeIfPresent([String].self, forKey: .starredApplications) ?? []
        applicationMetadata = try values.decodeIfPresent([String:ApplicationMetadata].self, forKey: .applicationMetadata) ?? [:]
    }
    /// An explicit shortcut replaces the shared prefix for its own physical key.
    public var effectiveBindingHotKeys: [String:BindingHotKey] {
        var shortcuts = bindingHotKeys.filter { bindings[$0.key] != nil }
        if let prefix = settings.directLaunchPrefix {
            for key in bindings.keys where shortcuts[key] == nil { shortcuts[key] = prefix.shortcut(for:key) }
        }
        return shortcuts
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw LauncherError.unsupportedVersion(schemaVersion) }
        guard settings.glassOpacity.isFinite, (0.50...0.90).contains(settings.glassOpacity) else { throw LauncherError.invalidTarget("界面不透明度须在 50% 到 90% 之间。") }
        guard settings.actionsEnabled || settings.applicationsEnabled else { throw LauncherError.invalidTarget("请至少保留动作面板或应用面板中的一个。") }
        guard bindings.keys.allSatisfy({ KeyboardLayout.keys.contains($0) }) else { throw LauncherError.invalidTarget("配置包含不支持的键位。") }
        guard bindingHotKeys.keys.allSatisfy({ KeyboardLayout.keys.contains($0) }), Set(bindingHotKeys.values).count == bindingHotKeys.count else { throw LauncherError.invalidTarget("配置包含无效或重复的全局快捷键。") }
        for hotKey in bindingHotKeys.values { try hotKey.validate() }
        try settings.directLaunchPrefix?.validate()
        try settings.launcherHotKey?.validate()
        let effective = effectiveBindingHotKeys
        guard Set(effective.values).count == effective.count else {
            throw LauncherError.invalidTarget("统一前缀与独立快捷键冲突，请调整对应键位的独立快捷键。")
        }
        guard !effective.values.contains(settings.effectiveLauncherHotKey) else {
            throw LauncherError.invalidTarget("启动器快捷键与目标快捷键重复，请选择其他组合。")
        }
        if let applicationHotKey = settings.applicationViewHotKey {
            try applicationHotKey.validate()
            guard applicationHotKey != settings.effectiveLauncherHotKey, !effective.values.contains(applicationHotKey) else {
                throw LauncherError.invalidTarget("应用视图快捷键与启动器或目标快捷键重复，请选择其他组合。")
            }
        }
        if let workbenchHotKey = settings.workbenchHotKey {
            try workbenchHotKey.validate()
            guard workbenchHotKey != settings.effectiveLauncherHotKey,
                  workbenchHotKey != settings.applicationViewHotKey,
                  !effective.values.contains(workbenchHotKey) else {
                throw LauncherError.invalidTarget("工作台快捷键与启动器、应用面板或目标快捷键重复，请选择其他组合。")
            }
        }
        for binding in bindings.values {
            try binding.target.validate()
            guard binding.alias.count <= 64 else { throw LauncherError.invalidTarget("显示名称最多 64 个字符。") }
        }
        for app in addedApplications { guard app.kind == .app else { throw LauncherError.invalidTarget("补充应用记录无效。") }; try app.validate() }
        guard scanDirectories.count <= 100, scanDirectories.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.count <= 8192 }) else {
            throw LauncherError.invalidTarget("应用扫描目录无效。")
        }
        guard applicationOrder.count <= 50_000, hiddenApplications.count <= 50_000, starredApplications.count <= 50_000, applicationMetadata.count <= 50_000 else {
            throw LauncherError.invalidTarget("应用管理记录过多。")
        }
        for metadata in applicationMetadata.values {
            guard metadata.addedAt.timeIntervalSinceReferenceDate.isFinite,
                  metadata.installedAt?.timeIntervalSinceReferenceDate.isFinite != false,
                  metadata.lastUsedAt?.timeIntervalSinceReferenceDate.isFinite != false else { throw LauncherError.invalidTarget("应用日期记录无效。") }
        }
    }
}

public enum LauncherError: LocalizedError, Equatable {
    case invalidTarget(String), unsupportedVersion(Int), unavailable(String), storage(String)
    public var errorDescription: String? {
        switch self {
        case .invalidTarget(let message), .unavailable(let message), .storage(let message): message
        case .unsupportedVersion(let version): "配置格式 \(version) 暂不受支持，原文件已保留。"
        }
    }
}

/// All board edits go through value snapshots. Cancel never writes a draft to disk.
public struct BindingEditor: Sendable {
    public private(set) var bindings: [String: KeyBinding]
    public private(set) var history: [[String: KeyBinding]] = []
    public init(_ bindings: [String: KeyBinding]) { self.bindings = bindings }
    public mutating func set(_ binding: KeyBinding, at key: String, movingFrom source: String? = nil, alsoRemoving duplicate: String? = nil) {
        guard KeyboardLayout.keys.contains(key) else { return }
        checkpoint()
        if let duplicate, duplicate != key { bindings.removeValue(forKey: duplicate) }
        if let source, source != key { bindings.removeValue(forKey: source) }
        bindings[key] = binding
    }
    public mutating func remove(_ key: String) { guard bindings[key] != nil else { return }; checkpoint(); bindings.removeValue(forKey: key) }
    public mutating func swap(_ first: String, _ second: String) {
        guard first != second, KeyboardLayout.keys.contains(first), KeyboardLayout.keys.contains(second), bindings[first] != nil || bindings[second] != nil else { return }
        checkpoint(); let previous = bindings[first]; bindings[first] = bindings[second]; bindings[second] = previous
    }
    public mutating func undo() { if let last = history.popLast() { bindings = last } }
    private mutating func checkpoint() { history.append(bindings); if history.count > 100 { history.removeFirst() } }
}
