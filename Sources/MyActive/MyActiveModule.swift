import AppKit
import SwiftUI
import Combine
import MyToolKit

@MainActor
public final class MyActiveModule: NSObject, ToolModule, NSWindowDelegate, NSMenuDelegate {
    public let descriptor = ToolDescriptor(id: "myactive", name: "MyActive", summary: "让屏幕保持明亮，后台任务安心运行。",
                                           symbol: "sun.max.fill", shortcut: "保持唤醒")
    private let host: HostContext
    private lazy var model = ActiveModel(defaults: ToolStorage.defaults("MyActive"))
    private var window: NSWindow?
    private weak var displayedModel: ActiveModel?
    private lazy var menu: NSMenu = { let menu = NSMenu(title: "MyActive"); menu.delegate = self; menu.autoenablesItems = false; return menu }()
    public var statusPublisher: AnyPublisher<ToolStatus, Never>? { model.statusPublisher }

    public init(host: HostContext) { self.host = host; super.init() }
    public func start() throws { model.startMonitoring() }
    public func open() { showWindow(model: model) }
    public func makeMenu() -> NSMenu? { menu }
    public func willTerminate() { model.shutdown() }

    private func showWindow(model: ActiveModel) {
        if window == nil {
            displayedModel = model
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "MyActive"; w.isReleasedWhenClosed = false; w.delegate = self
            w.contentMinSize = NSSize(width: 620, height: 600)
            w.contentViewController = NSHostingController(rootView: ActiveView(model: model, showHome: host.showHome))
            w.setContentSize(NSSize(width: 700, height: 760)); w.center(); w.setFrameAutosaveName("MyTool.MyActive")
            window = w
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    public func windowDidBecomeKey(_ notification: Notification) { displayedModel?.tick(); displayedModel?.refreshPower() }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        model.tick(); model.refreshPower()
        menu.removeAllItems()
        let status = NSMenuItem(title: model.session == nil ? "MyActive · 未开启" : "\(model.status.label) · \(model.timeLabel)", action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status)
        menu.addItem(item("打开 MyActive") { [weak self] in self?.open() })
        menu.addItem(.separator())
        if let session = model.session {
            menu.addItem(item(session.phase == .active ? "暂停会话" : "继续会话") { [weak self] in
                guard let self else { return }
                if self.model.isActive { self.model.pause() } else { self.model.perform { try self.model.resume() } }
            })
            if model.remaining != nil { menu.addItem(item("延长 15 分钟") { [weak self] in self?.model.perform { try self?.model.extend() } }) }
            menu.addItem(item("结束会话") { [weak self] in self?.model.stop() })
        } else {
            for minutes in [15, 30, 60, 120] {
                menu.addItem(item("保持唤醒 \(minutes) 分钟") { [weak self] in self?.model.perform { try self?.model.start(limit: .duration(Double(minutes) * 60)) } })
            }
            menu.addItem(item("保持唤醒，不限时") { [weak self] in self?.model.perform { try self?.model.start(limit: .unlimited) } })
        }
        menu.addItem(.separator())
        for mode in AwakeMode.allCases {
            let entry = item(mode.title) { [weak self] in self?.model.perform { try self?.model.changeMode(mode) } }
            entry.state = model.mode == mode ? .on : .off; menu.addItem(entry)
        }
        if let error = model.error {
            let entry = NSMenuItem(title: error, action: nil, keyEquivalent: ""); entry.isEnabled = false
            menu.addItem(.separator()); menu.addItem(entry)
        }
    }
    private func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let callback = ActiveMenuCallback(action)
        let item = NSMenuItem(title: title, action: #selector(ActiveMenuCallback.invoke(_:)), keyEquivalent: "")
        item.target = callback; item.representedObject = callback; return item
    }

    #if DEBUG
    public func showPreview(state: String) -> NSView? {
        let preview = ActiveModel(assertions: PreviewAssertions(), readPower: { PowerSnapshot(source: .ac, batteryPercent: 83) })
        if state != "idle" { try? preview.start(limit: .duration(90 * 60)) }
        if state == "paused" { preview.pause() }
        showWindow(model: preview)
        return window?.contentView
    }
    #endif
}

@MainActor
private final class ActiveMenuCallback: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: NSMenuItem) { action() }
}

#if DEBUG
private struct PreviewAssertions: AwakeAssertionProviding {
    func acquire(mode: AwakeMode, timeout: TimeInterval?) throws -> any AwakeLease { PreviewLease() }
}
private final class PreviewLease: AwakeLease { func release() {} }
#endif
