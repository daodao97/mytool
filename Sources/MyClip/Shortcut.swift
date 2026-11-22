import AppKit
import Carbon

/// 快捷键，modifiers 为 Carbon 修饰键掩码
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    /// 只比较按键和修饰键，label 仅用于显示
    static func == (a: Shortcut, b: Shortcut) -> Bool {
        a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }

    func matches(_ event: NSEvent) -> Bool {
        UInt32(event.keyCode) == keyCode && Self.carbonModifiers(event.modifierFlags) == modifiers
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static let specialKeys: [UInt16: String] = [
        49: "空格", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

extension Shortcut {
    /// 从按键事件生成；必须包含 ⌘、⌥ 或 ⌃（F1–F12 除外），否则返回 nil
    init?(event: NSEvent) {
        let mods = Self.carbonModifiers(event.modifierFlags)
        let functionKey = Self.functionKeys[event.keyCode]
        guard functionKey != nil || mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }

        let label = functionKey
            ?? Self.specialKeys[event.keyCode]
            ?? event.characters(byApplyingModifiers: [])?.uppercased()
            ?? "?"
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, label: label)
    }
}
