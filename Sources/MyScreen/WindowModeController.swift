import AppKit
import SwiftUI
import MyScreenCore

/// Installs a suppressing tap only while window mode or its remaining key-ups need it. AX work is dispatched
/// asynchronously; it never runs inside the tap callback or delays keyboard event delivery.
final class WindowModeController {
    var onAction: ((WindowAction) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state = WindowModeState()
    private var bindings: [ShortcutBinding] = []
    private var panel: WindowModePanel?
    private var expanded = false
    private var leaderLabel = "⌥R"
    var isActive: Bool { state.isActive }

    func enter(bindings: [ShortcutBinding], leader: KeyChord) -> Bool {
        guard WindowService.isTrusted else { return false }
        self.bindings = bindings
        leaderLabel = leader.label
        guard installTap() else { return false }
        state.enter()
        expanded = false
        showHint()
        onStateChange?(true)
        return true
    }
    func leave() {
        // Keep the tap alive for key-ups paired with intercepted key-downs. Inactive mode
        // passes every unrelated key through; release the tap after the last paired key-up.
        state.leave()
        panel?.orderOut(nil)
        onStateChange?(false)
        if !state.hasPendingKeyUps { stop() }
    }
    func stop() {
        let wasActive = state.isActive
        state.reset()
        panel?.orderOut(nil)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil
        if wasActive { onStateChange?(false) }
    }
    private func installTap() -> Bool {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<WindowModeController>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else { return false }
        tap = created; source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            state.reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            DispatchQueue.main.async { [weak self] in
                self?.panel?.orderOut(nil)
                self?.onStateChange?(false)
                self?.onFailure?("窗口模式的键盘监听已暂停，已退出；可再次按 leader 进入")
            }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var modifiers: UInt32 = 0
        if flags.contains(.maskCommand) { modifiers |= 256 }
        if flags.contains(.maskShift) { modifiers |= 512 }
        if flags.contains(.maskAlternate) { modifiers |= 2048 }
        if flags.contains(.maskControl) { modifiers |= 4096 }
        let result = state.handle(KeyChord(keyCode: keyCode, modifiers: modifiers), keyDown: type == .keyDown,
                                  isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, bindings: bindings)
        switch result {
        case .passThrough: return Unmanaged.passUnretained(event)
        case .consumed:
            if !state.isActive && !state.hasPendingKeyUps {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.state.isActive, !self.state.hasPendingKeyUps else { return }
                    self.stop()
                }
            }
            return nil
        case .exit:
            DispatchQueue.main.async { [weak self] in self?.leave() }
        case .toggleHelp:
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state.isActive else { return }
                self.expanded.toggle(); self.showHint()
            }
        case .action(let action):
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state.isActive else { return }
                self.onAction?(action)
            }
        }
        return nil
    }
    private func showHint() {
        if panel == nil {
            let hint = WindowModePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            hint.level = .floating
            hint.isOpaque = false
            hint.backgroundColor = .clear
            hint.hasShadow = true
            hint.ignoresMouseEvents = true
            hint.hidesOnDeactivate = false
            hint.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel = hint
        }
        guard let panel else { return }
        let width: CGFloat = 560, height: CGFloat = expanded ? 575 : 148
        panel.contentView = NSHostingView(rootView: WindowModeHint(leader: leaderLabel, expanded: expanded, bindings: bindings))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 28, width: width, height: min(height, area.height - 56)), display: true)
        panel.orderFrontRegardless()
    }
    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}

private final class WindowModePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct WindowModeHint: View {
    let leader: String
    let expanded: Bool
    let bindings: [ShortcutBinding]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("窗口模式", systemImage: "rectangle.3.group.fill").font(.headline)
                Spacer()
                Text("\(leader) 进入 · Esc / Q 退出 · Tab 提示").font(.caption).foregroundStyle(.secondary)
            }
            if expanded {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        ForEach(bindings) { binding in
                            HStack {
                                Text(binding.label).font(.system(.caption, design: .monospaced).weight(.semibold)).frame(width: 64, alignment: .leading)
                                Text(binding.action.title).font(.caption)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            } else {
                Text("WASD 微移 · HJKL 分屏 · Y/O/U/I 四角 · F 填满 · C 居中").font(.callout)
                Text("方向键跨屏 · Space 下一屏 · = / − 缩放 · [ / ] 撤销 / 重做").font(.caption).foregroundStyle(.secondary)
                Text("Shift+H/L 固定左边缩/放 · Shift+K/J 固定上边缩/放").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12)))
    }
}
