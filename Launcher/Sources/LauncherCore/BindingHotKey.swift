import Foundation

/// A physical-key shortcut, independent of the current keyboard input source.
public struct BindingHotKey: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool
    public init(keyCode: UInt16, control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.keyCode = keyCode; self.control = control; self.option = option; self.shift = shift; self.command = command
    }
    public var title: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + (Self.keyName(for: keyCode) ?? "?")
    }
    public func validate() throws {
        guard control || option || command else { throw LauncherError.invalidTarget("快捷键至少需要包含 ⌃、⌥ 或 ⌘ 中的一个。") }
        guard Self.keyName(for: keyCode) != nil else { throw LauncherError.invalidTarget("请选择字母、数字、方向键、功能键或空格等按键。") }
    }
    public static func keyName(for code: UInt16) -> String? {
        KeyboardLayout.keyCodes[code] ?? [49:"空格",48:"Tab",36:"↵",76:"⌤",53:"Esc",51:"⌫",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",115:"Home",119:"End",116:"Page Up",121:"Page Down",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"][code]
    }
}

/// Shared modifier prefix for physical launcher keys. Nil in settings disables it.
public struct KeyShortcutPrefix: Codable, Equatable, Hashable, Sendable {
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool
    public init(control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.control = control; self.option = option; self.shift = shift; self.command = command
    }
    private enum CodingKeys: String, CodingKey { case control, option, shift, command }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        control = try values.decodeIfPresent(Bool.self, forKey: .control) ?? false
        option = try values.decodeIfPresent(Bool.self, forKey: .option) ?? false
        shift = try values.decodeIfPresent(Bool.self, forKey: .shift) ?? false
        command = try values.decodeIfPresent(Bool.self, forKey: .command) ?? false
    }
    public var title: String { (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") }
    public func validate() throws {
        guard control || option || command else { throw LauncherError.invalidTarget("统一前缀至少需要包含 ⌃、⌥ 或 ⌘ 中的一个。") }
    }
    public func shortcut(for key: String) -> BindingHotKey? {
        guard let code = KeyboardLayout.keyCodes.first(where: { $0.value == key })?.key else { return nil }
        return BindingHotKey(keyCode: code, control: control, option: option, shift: shift, command: command)
    }
}

public extension HotKeyChoice {
    var bindingHotKey: BindingHotKey {
        BindingHotKey(keyCode: 49, control: self != .optionSpace, option: self != .controlSpace)
    }
}
