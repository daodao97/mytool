import AppKit
import SwiftUI
import MyToolKit

@MainActor
public final class MyScreenModule: NSObject, ToolModule, NSWindowDelegate {
    static weak var current: MyScreenModule?
    let host: HostContext
    private var window: NSWindow?
    private var menuController: MenuBarController?
    private var started = false
    public let descriptor = ToolDescriptor(id: "myscreen", name: "MyScreen", summary: "管理窗口，记住每一块屏幕的布局。",
                                           symbol: "rectangle.3.group", shortcut: "窗口管理")

    public init(host: HostContext) { self.host = host; super.init(); Self.current = self }

    public func start() throws {
        guard !started else { return }
        try ToolStorage.prepare(name: "MyScreen", legacyBundleID: "dev.daodao.MyScreen")
        AppModel.shared.start()
        menuController = MenuBarController(model: .shared)
        started = true
    }

    public func open() { showWindow() }

    private func showWindow(section: String = "概览") {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "MyScreen"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentMinSize = NSSize(width: 960, height: 650)
            w.contentViewController = NSHostingController(rootView: DashboardView(model: .shared, initialSection: section))
            w.setContentSize(NSSize(width: 1080, height: 760))
            w.center(); w.setFrameAutosaveName("MyTool.MyScreen")
            window = w
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func makeMenu() -> NSMenu? { menuController?.menu }
    public func willTerminate() { if started { AppModel.shared.stop() } }
    func closeWindow() { window?.performClose(nil) }
    public func windowWillClose(_ notification: Notification) { cancelRecording() }
    public func windowDidResignKey(_ notification: Notification) { cancelRecording() }
    public func windowDidBecomeKey(_ notification: Notification) {
        if started { AppModel.shared.refreshPermission() }
    }
    private func cancelRecording() {
        if AppModel.shared.isRecordingAnyShortcut { AppModel.shared.finishRecording(keyCode: nil) }
    }

    #if DEBUG
    /// UI verification never starts window monitors, hotkeys, or data migration.
    public func showPreview(section: String) -> NSView? {
        let model = AppModel.shared
        model.displays = DisplayService.connected()
        model.isTransitioning = false
        model.isTrusted = section == "窗口排布"
        model.notice = model.isTrusted ? "选择常见布局，或一次排布同屏窗口" : "开启辅助功能权限后，即可记忆和移动窗口"
        window?.close(); window = nil
        showWindow(section: section)
        return window?.contentView
    }
    #endif
}
