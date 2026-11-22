import AppKit
import SwiftUI
import MyToolKit
import MyScreen
import MyClip
import MyActive
import Combine

@main
enum MyToolApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences = HostPreferences()
    private let state = LauncherState()
    private var registry: ToolRegistry!
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var workspaceObserver: NSObjectProtocol?
    private var previousApplication: NSRunningApplication?
    private var previewWindow: NSWindow?
    private var statusSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let previewOutput = ProcessInfo.processInfo.environment["MYTOOL_UI_SMOKE_OUTPUT"]
        #else
        let previewOutput: String? = nil
        #endif
        if previewOutput == nil, let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSWorkspace.shared.openApplication(at: existing.bundleURL ?? Bundle.main.bundleURL,
                                              configuration: .init(), completionHandler: nil)
            NSApp.terminate(nil)
            return
        }

        let context = HostContext(showHome: { [weak self] in self?.showHome() },
                                  showSettings: { [weak self] in self?.showSettings() },
                                  restart: { [weak self] in self?.restart() },
                                  previousApplication: { [weak self] in self?.previousApplication })
        // Register new modules here. The launcher and menus derive their entries from this list.
        let screen = MyScreenModule(host: context)
        let clip = MyClipModule(host: context)
        let active = MyActiveModule(host: context)
        do { registry = try ToolRegistry(modules: [screen, clip, active]) }
        catch {
            let alert = NSAlert(); alert.messageText = "无法启动 MyTool"
            alert.informativeText = error.localizedDescription; alert.runModal()
            NSApp.terminate(nil); return
        }
        installMainMenu()

        #if DEBUG
        if let output = previewOutput {
            NSApp.setActivationPolicy(.regular)
            let section = ProcessInfo.processInfo.environment["MYTOOL_UI_SMOKE_SECTION"] ?? "home"
            let view: NSView?
            if section.hasPrefix("active:") {
                view = active.showPreview(state: String(section.dropFirst(7)))
            } else if section.hasPrefix("screen:") {
                view = screen.showPreview(section: String(section.dropFirst(7)))
            } else if section == "clip:json-panel" || section == "clip:json-cards" {
                do { view = try clip.showPreview(json: true, expanded: section == "clip:json-panel") } catch { exit(1) }
            } else if section.hasPrefix("clip:json") {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 650),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                w.title = "MyClip · JSON 预览"
                w.contentView = clip.jsonPreview(search: section.hasSuffix("path") ? "path" : section.hasSuffix("fuzzy") ? "fuzzy" : "")
                w.center(); w.makeKeyAndOrderFront(nil); previewWindow = w; view = w.contentView
            } else if section == "clip:panel" {
                do { view = try clip.showPreview() } catch { exit(1) }
            } else if section == "clip:settings" {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.title = "MyClip 设置"; w.contentView = clip.settingsPreview()
                w.center(); w.makeKeyAndOrderFront(nil); previewWindow = w
                view = w.contentView
            } else {
                if section == "settings" { state.destination = .settings }
                showHostWindow(); view = window?.contentView
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let view, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                do {
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
                    try data.write(to: URL(fileURLWithPath: output))
                    if ProcessInfo.processInfo.environment["MYTOOL_UI_SMOKE_KEEP_OPEN"] != "1" { NSApp.terminate(nil) }
                } catch { exit(1) }
            }
            return
        }
        #endif

        rememberFrontmostApplication()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rememberFrontmostApplication() }
            }
        registry.startAll()
        statusSubscription = registry.$statuses.sink { [weak self] statuses in self?.updateStatusIndicator(statuses) }
        preferences.applyAppearance = { [weak self] in self?.applyAppearance() }
        applyAppearance()
        showHome()
    }

    private func rememberFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular else { return }
        previousApplication = app
    }

    private func showHome() { state.destination = .home; showHostWindow() }
    private func showSettings() { state.destination = .settings; showHostWindow() }
    private func showHostWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "MyTool"; w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 740, height: 540)
            w.contentViewController = NSHostingController(rootView: LauncherView(registry: registry, preferences: preferences, state: state))
            w.setContentSize(NSSize(width: 1040, height: 620)); w.center()
            #if DEBUG
            if ProcessInfo.processInfo.environment["MYTOOL_UI_SMOKE_OUTPUT"] == nil { w.setFrameAutosaveName("MyTool.Home") }
            #else
            w.setFrameAutosaveName("MyTool.Home")
            #endif
            window = w
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAppearance() {
        let visible = NSApp.windows.filter(\.isVisible)
        let key = NSApp.keyWindow
        let wasActive = NSApp.isActive
        let policy: NSApplication.ActivationPolicy = preferences.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            if NSApp.setActivationPolicy(policy) {
                // Let AppKit finish the policy transition before restoring focus.
                DispatchQueue.main.async {
                    guard NSApp.activationPolicy() == policy else { return }
                    for w in visible { w.orderFrontRegardless() }
                    key?.makeKeyAndOrderFront(nil)
                    if wasActive { NSApp.activate(ignoringOtherApps: true) }
                }
            } else {
                preferences.error = "无法切换 Dock 图标，请重试。"
            }
        }
        if preferences.showMenuBarIcon {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "MyTool")
                image?.isTemplate = true; item.button?.image = image; item.button?.toolTip = "MyTool"
                let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
                item.menu = menu; statusItem = item
            }
        } else if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
        updateStatusIndicator(registry.statuses)
    }

    private func updateStatusIndicator(_ statuses: [String: ToolStatus]) {
        let active = registry.modules.compactMap { module -> String? in
            guard let status = statuses[module.descriptor.id], status.isActive else { return nil }
            return "\(module.descriptor.name) · \(status.label)"
        }
        let image = NSImage(systemSymbolName: active.isEmpty ? "square.grid.2x2" : "square.grid.2x2.fill", accessibilityDescription: "MyTool")
        image?.isTemplate = true; statusItem?.button?.image = image
        statusItem?.button?.toolTip = (["MyTool"] + active).joined(separator: "\n")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(menuAction("打开 MyTool") { [weak self] in self?.showHome() })
        menu.addItem(.separator())
        for module in registry.modules {
            let id = module.descriptor.id
            let title = registry.failures[id] == nil ? "打开 \(module.descriptor.name)" : "重试启动 \(module.descriptor.name)"
            menu.addItem(menuAction(title) { [weak self] in self?.registry.open(id) })
            if let submenu = module.makeMenu() {
                let item = NSMenuItem(title: "\(module.descriptor.name) 操作", action: nil, keyEquivalent: "")
                item.submenu = submenu; menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(menuAction("设置…") { [weak self] in self?.showSettings() })
        menu.addItem(menuAction("退出 MyTool", key: "q") { NSApp.terminate(nil) })
    }

    private func installMainMenu() {
        let main = NSMenu()
        let app = NSMenu(title: "MyTool")
        app.addItem(withTitle: "关于 MyTool", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(menuAction("设置…", key: ",") { [weak self] in self?.showSettings() })
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 MyTool", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hide = app.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "退出 MyTool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appendMenu(app, to: main)
        let file = NSMenu(title: "文件")
        file.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appendMenu(file, to: main)
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
                                       ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        appendMenu(edit, to: main)
        let windows = NSMenu(title: "窗口")
        windows.addItem(menuAction("MyTool", key: "1") { [weak self] in self?.showHome() })
        for (index, module) in registry.modules.enumerated() {
            let id = module.descriptor.id
            windows.addItem(menuAction(module.descriptor.name, key: index < 8 ? String(index + 2) : "") { [weak self] in self?.registry.open(id) })
        }
        windows.addItem(.separator())
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        appendMenu(windows, to: main)
        NSApp.mainMenu = main; NSApp.windowsMenu = windows
    }

    private func appendMenu(_ menu: NSMenu, to parent: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu; parent.addItem(item)
    }

    private func restart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "mytool-restart", Bundle.main.bundlePath]
        do { try process.run(); NSApp.terminate(nil) }
        catch { preferences.error = "重新启动失败：\(error.localizedDescription)"; showSettings() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHome(); return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        registry?.willTerminate()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }
}

@MainActor
private final class MenuCallback: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: NSMenuItem) { action() }
}

@MainActor
private func menuAction(_ title: String, key: String = "", action: @escaping () -> Void) -> NSMenuItem {
    let callback = MenuCallback(action)
    let item = NSMenuItem(title: title, action: #selector(MenuCallback.invoke(_:)), keyEquivalent: key)
    item.target = callback; item.representedObject = callback
    return item
}
