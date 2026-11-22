import AppKit
import Combine
import MyScreenCore

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    let menu = NSMenu(title: "MyScreen")
    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let model = self.model
        let title = NSMenuItem(title: "MyScreen · \(model.displays.count) 块显示器", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        if !model.isTrusted { menu.addItem(actionItem("开启辅助功能权限…") { model.requestPermission() }) }
        menu.addItem(actionItem("重新检查权限与窗口") { model.refreshPermission(manual: true) })
        menu.addItem(actionItem(model.isWindowModeActive ? "退出窗口模式" : "进入窗口模式（\(model.leader.label)）",
                                enabled: model.canOperate || model.isWindowModeActive) { model.toggleWindowMode() })
        menu.addItem(.separator())
        menu.addItem(actionItem("打开控制面板") { MyScreenModule.current?.open() })
        menu.addItem(actionItem("保存当前布局", enabled: model.canOperate) { model.perform(.saveLayout) })
        menu.addItem(actionItem("恢复当前组合布局", enabled: model.canOperate && model.currentAutomaticProfile != nil) { model.perform(.restoreLayout) })
        if !model.namedProfiles.isEmpty {
            let saved = NSMenu(title: "恢复已保存布局"); saved.autoenablesItems = false
            for profile in model.namedProfiles {
                saved.addItem(actionItem(profile.name, enabled: model.canOperate) { model.restore(profile) })
            }
            let entry = NSMenuItem(title: "恢复已保存布局", action: nil, keyEquivalent: ""); entry.submenu = saved; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let common = NSMenu(title: "常见窗口布局"); common.autoenablesItems = false
        for action in WindowAction.commonLayouts {
            common.addItem(actionItem(action.title, enabled: model.canOperate) { model.perform(action) })
        }
        let commonEntry = NSMenuItem(title: "常见窗口布局", action: nil, keyEquivalent: "")
        commonEntry.submenu = common; menu.addItem(commonEntry)
        for action in [WindowAction.center, .nextDisplay, .undo] {
            menu.addItem(actionItem(action.title, enabled: model.canOperate) { model.perform(action) })
        }
        let tiling = NSMenu(title: "多窗口自动排布"); tiling.autoenablesItems = false
        for layout in WindowTileLayout.allCases {
            tiling.addItem(actionItem(layout.title, enabled: model.canOperate) { model.tileWindows(layout) })
        }
        tiling.addItem(.separator())
        for display in model.displays {
            let options = NSMenu(title: display.name); options.autoenablesItems = false
            for layout in WindowTileLayout.allCases {
                options.addItem(actionItem(layout.title, enabled: model.canOperate) { model.tileWindows(layout, displayID: display.id) })
            }
            let entry = NSMenuItem(title: display.name, action: nil, keyEquivalent: "")
            entry.submenu = options; tiling.addItem(entry)
        }
        let tileEntry = NSMenuItem(title: "多窗口自动排布", action: nil, keyEquivalent: "")
        tileEntry.submenu = tiling; menu.addItem(tileEntry)
        menu.addItem(.separator())
        menu.addItem(actionItem("拖动吸附与自动排版", checked: model.autoArrange) { model.autoArrange.toggle() })
        menu.addItem(actionItem("拖动后自动重排同屏窗口", checked: model.autoTileWindows) { model.autoTileWindows.toggle() })
        menu.addItem(actionItem("并排窗口联动缩放", checked: model.linkedResize) { model.linkedResize.toggle() })
        menu.addItem(actionItem("自动记忆布局", checked: model.autoRemember) { model.autoRemember.toggle() })
        menu.addItem(actionItem("连接变化时自动恢复", checked: model.autoRestore) { model.autoRestore.toggle() })
        menu.addItem(actionItem("启用全局快捷键", checked: model.shortcutsEnabled) { model.shortcutsEnabled.toggle() })
        menu.addItem(.separator())
        menu.addItem(actionItem("打开 MyTool") { MyScreenModule.current?.host.showHome() })
    }
}

@MainActor
private final class MenuAction: NSObject {
    let invoke: () -> Void
    init(_ invoke: @escaping () -> Void) { self.invoke = invoke }
    @objc func perform(_ sender: NSMenuItem) { invoke() }
}

@MainActor
func actionItem(_ title: String, key: String = "", enabled: Bool = true, checked: Bool? = nil,
                action: @escaping () -> Void) -> NSMenuItem {
    let handler = MenuAction(action)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.perform(_:)), keyEquivalent: key)
    item.target = handler
    item.representedObject = handler // NSMenuItem.target alone does not retain its callback.
    item.isEnabled = enabled
    if let checked { item.state = checked ? .on : .off }
    return item
}
