import SwiftUI
import ApplicationServices
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(Preferences.shared))
            let w = NSWindow(contentViewController: hosting)
            w.title = "MyClip 设置"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // 菜单栏应用默认不在前台，需要先激活才能看到窗口
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Button("打开 MyTool 设置…") { prefs.openHostSettings() }
                Text("登录启动、菜单栏和 Dock 由 MyTool 统一管理。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("快捷键") {
                if let warning = prefs.shortcutWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.title) { ShortcutRecorder(action: action) }
                }
                Toggle("⌃⌥1–9 直接粘贴第 1–9 条", isOn: $prefs.quickPaste)
            }

            Section {
                Picker("搜索", selection: $prefs.searchMode) {
                    ForEach(SearchMode.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("精确：包含关键词　模糊：关键词的字符按顺序出现　正则：正则表达式　混合：依次按精确、正则、模糊匹配")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("行为") {
                Toggle("自动粘贴", isOn: $prefs.autoPaste)
                if prefs.autoPaste && !AXIsProcessTrusted() {
                    HStack {
                        Text("自动粘贴需要辅助功能权限").foregroundStyle(.orange)
                        Spacer()
                        Button("去授权") {
                            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                        }
                    }
                    .font(.caption)
                }
                Toggle("纯文本粘贴", isOn: $prefs.plainTextPaste)
                Text("""
                自定义选择项目时的行为：
                • 按住 ⌥ 选择项目以复制。
                • 按住 ⇧⌘ 选择项目以复制并粘贴。
                • 按住 ⌘ 选择项目以复制并匹配格式粘贴。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("最多保留", selection: $prefs.maxHistory) {
                    ForEach([100, 200, 500, 1000, 5000], id: \.self) { Text("\($0) 条").tag($0) }
                }
                Picker("保留时长", selection: $prefs.retentionDays) {
                    Text("1 天").tag(1)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("永久").tag(0)
                }
                Toggle("记录图片", isOn: $prefs.recordImages)
                Toggle("记录文件", isOn: $prefs.recordFiles)
                Toggle("识别图片中的文字", isOn: $prefs.recognizeText)
            } header: {
                Text("存储")
            } footer: {
                Text("收藏和置顶的条目不受数量和时长限制。图片保存在 ~/Library/Application Support/MyTool/MyClip/images。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(prefs.ignoredApps, id: \.self) { IgnoredAppRow(bundleID: $0) }
                Button("添加 App…", action: addIgnoredApps)
            } header: {
                Text("忽略的 App")
            } footer: {
                Text("从这些 App 复制的内容不会被记录。密码管理器标记为隐藏的内容始终不记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 680)
    }

    private func addIgnoredApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "忽略"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { prefs.ignoreApp(id) }
        }
    }
}

struct IgnoredAppRow: View {
    @EnvironmentObject var prefs: Preferences
    let bundleID: String

    var body: some View {
        let info = AppInfo.get(bundleID)
        HStack(spacing: 8) {
            Image(nsImage: info.icon).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name)
                Text(bundleID).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { prefs.unignoreApp(bundleID) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("移除")
        }
    }
}

/// 点击后录制快捷键，ⓧ 清除，esc 取消
struct ShortcutRecorder: View {
    @EnvironmentObject var prefs: Preferences
    let action: ShortcutAction
    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        let shortcut = prefs.shortcuts[action]
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button { recording ? stop() : start() } label: {
                    Text(recording ? "按下快捷键…" : (shortcut?.display ?? "未设置"))
                        .foregroundStyle(recording ? Color.accentColor : (shortcut == nil ? Color.secondary : Color.primary))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if shortcut != nil && !recording {
                    Button { error = prefs.setShortcut(nil, for: action) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 200, height: 26)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.12)))

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        error = nil
        recording = true
        if action == .open { prefs.pauseOpenShortcut(true) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        if action == .open { prefs.pauseOpenShortcut(false) }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53, Shortcut.carbonModifiers(event.modifierFlags) == 0 { // esc 取消
            error = nil
            stop()
            return
        }
        guard let shortcut = Shortcut(event: event) else {
            error = "需要包含 ⌘、⌥ 或 ⌃"
            return
        }
        error = prefs.setShortcut(shortcut, for: action)
        if error == nil { stop() }
    }
}
