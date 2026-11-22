import AppKit
import Carbon
import MyScreenCore

extension ShortcutBinding {
    var label: String { chord.label }
    static func keyName(_ code: UInt32) -> String { KeyChord.keyName(code) }
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 { KeyChord.carbonModifiers(flags) }
}

extension KeyChord {
    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }
    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4",
            22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"−", 28:"8", 29:"0", 30:"]", 31:"O", 32:"U",
            33:"[", 34:"I", 35:"P", 36:"↩", 37:"L", 38:"J", 39:"′", 40:"K", 41:";", 42:"\\", 43:",",
            44:"/", 45:"N", 46:"M", 47:".", 48:"⇥", 49:"Space", 50:"`", 51:"⌫", 53:"Esc", 123:"←", 124:"→", 125:"↓", 126:"↑",
            122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        return names[code] ?? "Key \(code)"
    }
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

final class HotKeyManager {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onLeader: (() -> Void)?
    static let signature: OSType = 0x4D534352 // MSCR
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr, key.signature == HotKeyManager.signature else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
            if key.id == 1 { manager.onLeader?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ leader: KeyChord, enabled: Bool) -> Bool {
        unregister()
        guard enabled else { return true }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(leader.keyCode, leader.modifiers,
            EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        references.append(reference)
        return true
    }
    func unregister() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
    }
    deinit { unregister(); if let handler { RemoveEventHandler(handler) } }
}
