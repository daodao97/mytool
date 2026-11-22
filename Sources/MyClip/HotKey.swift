import Carbon

/// 基于 Carbon 的全局快捷键，不需要辅助功能权限；可以同时存在多个实例
final class HotKey {
    private static let signature = OSType(0x4D59_434C) // 'MYCL'
    private static var nextID: UInt32 = 1

    private let hotKeyID: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var currentShortcut: Shortcut?
    var action: (@MainActor () -> Void)?

    init() {
        hotKeyID = Self.nextID
        Self.nextID += 1

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // 每个实例各装一个处理器，只响应自己的 id，其他按键交给下一个处理器
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            guard pressed.signature == HotKey.signature, pressed.id == hotKey.hotKeyID else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated { hotKey.action?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// 注册新快捷键（会先注销旧的），失败返回 false
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        if shortcut == currentShortcut, hotKeyRef != nil { return true }
        let previous = currentShortcut
        unregister()
        let id = EventHotKeyID(signature: Self.signature, id: hotKeyID)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr { currentShortcut = shortcut; return true }
        if let previous {
            _ = RegisterEventHotKey(previous.keyCode, previous.modifiers, id,
                                   GetApplicationEventTarget(), 0, &hotKeyRef)
            if hotKeyRef != nil { currentShortcut = previous }
        }
        return false
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        currentShortcut = nil
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
