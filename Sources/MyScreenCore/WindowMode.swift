import Foundation

public struct KeyChord: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32 = 0) { self.keyCode = keyCode; self.modifiers = modifiers }
    public static let leader = KeyChord(keyCode: 15, modifiers: 2048) // Option + R, matching resizeM.
}

public struct ShortcutBinding: Codable, Equatable, Identifiable, Sendable {
    public var action: WindowAction
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var id: String { action.rawValue }
    public var chord: KeyChord { KeyChord(keyCode: keyCode, modifiers: modifiers) }
    public init(action: WindowAction, keyCode: UInt32, modifiers: UInt32 = 0) {
        self.action = action; self.keyCode = keyCode; self.modifiers = modifiers
    }
    /// Physical ANSI keys from the local Hammerspoon resizeM / WinWin configuration.
    public static let defaults: [ShortcutBinding] = [
        .init(action: .moveLeft, keyCode: 0), .init(action: .moveRight, keyCode: 2),
        .init(action: .moveUp, keyCode: 13), .init(action: .moveDown, keyCode: 1),
        .init(action: .left, keyCode: 4), .init(action: .right, keyCode: 37),
        .init(action: .top, keyCode: 40), .init(action: .bottom, keyCode: 38),
        .init(action: .topLeft, keyCode: 16), .init(action: .topRight, keyCode: 31),
        .init(action: .bottomLeft, keyCode: 32), .init(action: .bottomRight, keyCode: 34),
        .init(action: .maximize, keyCode: 3), .init(action: .center, keyCode: 8),
        .init(action: .expand, keyCode: 24), .init(action: .shrink, keyCode: 27),
        .init(action: .shrinkWidth, keyCode: 4, modifiers: 512),
        .init(action: .growWidth, keyCode: 37, modifiers: 512),
        .init(action: .shrinkHeight, keyCode: 40, modifiers: 512),
        .init(action: .growHeight, keyCode: 38, modifiers: 512),
        .init(action: .screenLeft, keyCode: 123), .init(action: .screenRight, keyCode: 124),
        .init(action: .screenUp, keyCode: 126), .init(action: .screenDown, keyCode: 125),
        .init(action: .nextDisplay, keyCode: 49), .init(action: .undo, keyCode: 33),
        .init(action: .redo, keyCode: 30), .init(action: .centerCursor, keyCode: 50),
        // MyScreen additions; all original WinWin keys above retain their meaning.
        .init(action: .previousDisplay, keyCode: 49, modifiers: 512),
        .init(action: .saveLayout, keyCode: 1, modifiers: 4096),
        .init(action: .restoreLayout, keyCode: 15, modifiers: 4096)
    ]
}

public enum WindowModeKeyResult: Equatable {
    case passThrough, consumed, exit, toggleHelp, action(WindowAction)
}

/// Key routing is independent of the event tap so exit and key-up behavior can be regression tested.
public struct WindowModeState {
    public private(set) var isActive = false
    private var suppressedKeys = Set<UInt32>()
    public var hasPendingKeyUps: Bool { !suppressedKeys.isEmpty }
    public init() {}
    public mutating func enter() { isActive = true }
    public mutating func leave() { isActive = false }
    public mutating func reset() { isActive = false; suppressedKeys.removeAll() }
    public static func isReserved(_ chord: KeyChord) -> Bool {
        chord.keyCode == 53 || (chord.modifiers == 0 && [12, 48].contains(chord.keyCode))
    }
    public mutating func handle(_ chord: KeyChord, keyDown: Bool, isRepeat: Bool = false,
                                bindings: [ShortcutBinding]) -> WindowModeKeyResult {
        if !keyDown { return suppressedKeys.remove(chord.keyCode) == nil ? .passThrough : .consumed }
        // A function key held while Escape exits must not start typing repeat characters
        // into the application before its matching key-up arrives.
        guard isActive else { return suppressedKeys.contains(chord.keyCode) ? .consumed : .passThrough }
        if chord.keyCode == 53 || (chord.keyCode == 12 && chord.modifiers == 0) {
            suppressedKeys.insert(chord.keyCode)
            isActive = false
            return .exit
        }
        if chord == KeyChord(keyCode: 48) {
            suppressedKeys.insert(chord.keyCode)
            return isRepeat ? .consumed : .toggleHelp
        }
        guard let binding = bindings.first(where: { $0.chord == chord }) else { return .passThrough }
        suppressedKeys.insert(chord.keyCode)
        return isRepeat && !binding.action.isRepeatable ? .consumed : .action(binding.action)
    }
}
