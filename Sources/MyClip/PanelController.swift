import AppKit
import SwiftUI
import ApplicationServices
import Carbon
import Combine

/// 无边框面板默认不能成为 key window，这里放开以便接收键盘输入
final class ClipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelState: ObservableObject {
    @Published var query = ""
    @Published var showFavorites = false
    @Published var selection = 0
    @Published var previewing = false
    @Published var trusted = AXIsProcessTrusted()
    /// 每次呼出面板时变化，用于重新聚焦搜索框、滚回开头
    @Published private(set) var openToken = UUID()

    func reset() {
        query = ""
        showFavorites = false
        selection = 0
        previewing = false
        trusted = AXIsProcessTrusted()
        openToken = UUID()
    }
}

struct PanelActions {
    /// 按修饰键决定复制还是粘贴
    let select: @MainActor (ClipItem, NSEvent.ModifierFlags) -> Void
    let paste: @MainActor (ClipItem, _ plain: Bool) -> Void
    let copy: @MainActor (ClipItem) -> Void
    let close: @MainActor () -> Void
    let openSettings: @MainActor () -> Void
    let transform: @MainActor (ClipItem, TextTransform) -> Void
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let store: ClipStore
    private let previousApplication: () -> NSRunningApplication?
    private var pasteTarget: NSRunningApplication?
    private let prefs = Preferences.shared
    private let state = PanelState()
    private let panel: ClipPanel
    private let hotKey = HotKey()
    private let settingsWindow = SettingsWindowController()
    private var keyMonitor: Any?
    private let panelHeight: CGFloat = 340
    private var quickPasteKeys: [HotKey] = []
    private var cancellables = Set<AnyCancellable>()

    init(store: ClipStore, previousApplication: @escaping () -> NSRunningApplication?, registerHotKeys: Bool = true) {
        self.store = store
        self.previousApplication = previousApplication
        // nonactivatingPanel：面板可以接收键盘，但不会抢走当前 App 的前台状态，粘贴才能回到原 App
        panel = ClipPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let actions = PanelActions(
            select: { [weak self] in self?.select($0, modifiers: $1) },
            paste: { [weak self] in self?.paste($0, plain: $1) },
            copy: { [weak self] in self?.copyOnly($0) },
            close: { [weak self] in self?.hide() },
            openSettings: { [weak self] in self?.openSettings() },
            transform: { [weak self] in self?.transform($0, $1) }
        )
        let hosting = NSHostingView(rootView: ContentView(actions: actions)
            .environmentObject(store)
            .environmentObject(state)
            .environmentObject(prefs))
        hosting.sizingOptions = []

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.roundedMask(radius: 18)
        hosting.frame = blur.bounds
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)
        panel.contentView = blur

        if registerHotKeys {
            hotKey.action = { [weak self] in self?.toggle() }
            prefs.registerOpen = { [weak self] shortcut in
                guard let self else { return false }
                guard let shortcut else {
                    self.hotKey.unregister()
                    return true
                }
                let registered = self.hotKey.register(shortcut)
                self.prefs.shortcutWarning = registered ? nil : "\(shortcut.display) 已被占用，请更换打开快捷键。"
                return registered
            }
            if let shortcut = prefs.shortcuts[.open], !hotKey.register(shortcut) {
                prefs.shortcutWarning = "\(shortcut.display) 已被占用，请更换打开快捷键。原设置已保留。"
            }

            // 订阅时会先收到当前值，完成首次注册
            prefs.$quickPaste
                .sink { [weak self] on in MainActor.assumeIsolated { self?.setQuickPaste(on) } }
                .store(in: &cancellables)
        }

        state.$previewing
            .removeDuplicates()
            .sink { [weak self] previewing in
                MainActor.assumeIsolated { self?.resizeForPreview(previewing) }
            }
            .store(in: &cancellables)
    }

    // MARK: - 显示 / 隐藏

    #if DEBUG
    var previewContentView: NSView? { panel.contentView }
    func openPreviewForSmokeTest() { state.previewing = true }
    #endif

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        capturePasteTarget()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }

        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.minX + 12, y: vf.minY + 12, width: vf.width - 24, height: panelHeight)
        state.reset()

        panel.setFrame(frame.offsetBy(dx: 0, dy: -30), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                // A preview opened during the slide-in must not be shrunk by its final frame.
                self.resizeForPreview(self.state.previewing)
            }
        })

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard event.window === self.panel else { return event }
                return self.handleKey(event)
            }
        }
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.orderOut(nil)
    }

    private func resizeForPreview(_ previewing: Bool) {
        guard panel.isVisible, let screen = panel.screen else { return }
        var frame = panel.frame
        let availableHeight = screen.visibleFrame.maxY - frame.minY - 12
        frame.size.height = min(previewing ? 720 : panelHeight, availableHeight)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        // 点击面板外部时收起
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panel.isKeyWindow else { return }
            self.hide()
        }
    }

    private func openSettings() {
        hide()
        settingsWindow.show()
    }

    // MARK: - 快速粘贴

    /// ⌃⌥1–9 不打开面板，直接粘贴面板里的第 1–9 条（置顶的排在最前）
    private func setQuickPaste(_ on: Bool) {
        quickPasteKeys = []
        guard on else { return }
        let keyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, keyCode) in keyCodes.enumerated() {
            let key = HotKey()
            key.action = { [weak self] in self?.quickPaste(index) }
            key.register(Shortcut(keyCode: UInt32(keyCode), modifiers: UInt32(controlKey | optionKey),
                                  label: "\(index + 1)"))
            quickPasteKeys.append(key)
        }
    }

    private func quickPaste(_ index: Int) {
        capturePasteTarget()
        let items = store.filtered(query: "", favorites: false, mode: prefs.searchMode)
        guard items.indices.contains(index) else { return NSSound.beep() }
        select(items[index], modifiers: [])
    }

    /// 转换后的文本作为新条目粘贴，转换失败时提示音
    private func transform(_ item: ClipItem, _ transform: TextTransform) {
        guard let text = transform.apply(item.text) else { return NSSound.beep() }
        select(ClipItem(text: text, date: Date(), sourceApp: item.sourceApp), modifiers: [])
    }

    // MARK: - 动作

    /// ⌥ 仅复制；⇧⌘ 复制并粘贴；⌘ 以纯文本粘贴（匹配目标格式）；否则按「自动粘贴」设置
    private func select(_ item: ClipItem, modifiers: NSEvent.ModifierFlags) {
        let mods = modifiers.intersection([.command, .option, .shift, .control])
        if mods.contains(.option) {
            copyOnly(item)
        } else if mods == [.command, .shift] {
            paste(item, plain: prefs.plainTextPaste)
        } else if mods == .command {
            paste(item, plain: true)
        } else if prefs.autoPaste {
            paste(item, plain: prefs.plainTextPaste)
        } else {
            copyOnly(item)
        }
    }

    private func paste(_ item: ClipItem, plain: Bool) {
        store.copy(item, plain: plain)
        hide()
        // 有辅助功能权限时模拟 ⌘V 直接粘贴到原 App，否则只复制
        guard AXIsProcessTrusted(), let target = pasteTarget, !target.isTerminated else { return }
        target.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func capturePasteTarget() {
        let front = NSWorkspace.shared.frontmostApplication
        pasteTarget = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? previousApplication() : front
    }

    func shutdown() {
        hide()
        hotKey.unregister()
        quickPasteKeys.removeAll()
        cancellables.removeAll()
        prefs.registerOpen = nil
    }

    private func copyOnly(_ item: ClipItem) {
        store.copy(item, plain: prefs.plainTextPaste)
        hide()
    }

    private var visibleItems: [ClipItem] {
        store.filtered(query: state.query, favorites: state.showFavorites, mode: prefs.searchMode)
    }

    private func clampSelection() {
        state.selection = max(0, min(state.selection, visibleItems.count - 1))
    }

    /// 置顶、收藏后条目位置会变，让选中框跟着它走
    private func keepSelection(on id: UUID) {
        if let i = visibleItems.firstIndex(where: { $0.id == id }) {
            state.selection = i
        } else {
            clampSelection()
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let items = visibleItems
        let selected = items.indices.contains(state.selection) ? items[state.selection] : nil
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])

        // 可在设置中自定义的面板内快捷键
        if prefs.shortcuts[.preview]?.matches(event) == true {
            state.previewing = !state.previewing && selected != nil
            return nil
        }
        // A JSON preview contains its own search field, disclosure controls and text selection.
        // Let those views handle arrows, Tab and Return instead of pasting/deleting the record.
        if state.previewing {
            if event.keyCode == 53 { state.previewing = false; return nil }
            if event.keyCode == 43, mods == .command { openSettings(); return nil }
            return event
        }
        if prefs.shortcuts[.pin]?.matches(event) == true {
            if let selected { store.togglePin(selected); keepSelection(on: selected.id) }
            return nil
        }
        if prefs.shortcuts[.delete]?.matches(event) == true {
            if let selected { store.delete(selected); clampSelection() }
            return nil
        }

        switch event.keyCode {
        case 53: // esc
            if state.previewing { state.previewing = false } else { hide() }
        case 123: // ←
            state.selection = max(0, state.selection - 1)
        case 124: // →
            state.selection = min(max(items.count - 1, 0), state.selection + 1)
        case 36, 76: // return / enter
            if let selected { select(selected, modifiers: mods) }
        case 48: // tab
            state.showFavorites.toggle()
        case 1 where mods == .command: // ⌘S
            if let selected { store.toggleFavorite(selected); keepSelection(on: selected.id) }
        case 43 where mods == .command: // ⌘,
            openSettings()
        default:
            guard mods.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() else { return event }
            if let n = Int(chars), (1...9).contains(n) {
                if items.indices.contains(n - 1) { select(items[n - 1], modifiers: []) }
                return nil
            }
            // 没有主菜单，搜索框里的编辑快捷键需要手动转发
            let editActions: [String: Selector] = [
                "a": #selector(NSText.selectAll(_:)),
                "c": #selector(NSText.copy(_:)),
                "v": #selector(NSText.paste(_:)),
                "x": #selector(NSText.cut(_:)),
                "z": Selector(("undo:")),
            ]
            guard let action = editActions[chars] else { return event }
            NSApp.sendAction(action, to: nil, from: nil)
        }
        return nil
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let size = radius * 2 + 1
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
