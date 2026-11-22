import AppKit
import SwiftUI
import ApplicationServices
import MyToolKit

enum HostDestination { case home, settings }

@MainActor
final class LauncherState: ObservableObject {
    @Published var destination: HostDestination = .home
}

struct LauncherView: View {
    @ObservedObject var registry: ToolRegistry
    @ObservedObject var preferences: HostPreferences
    @ObservedObject var state: LauncherState

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Image(systemName: "square.grid.2x2.fill").font(.title2).foregroundStyle(.tint)
                    Text("MyTool").font(.system(size: 20, weight: .semibold))
                }.padding(.horizontal, 16).padding(.top, 32).padding(.bottom, 30)
                navigation("全部应用", symbol: "square.grid.2x2", destination: .home)
                navigation("设置", symbol: "gearshape", destination: .settings)
                Spacer()
                Text("日常小工具，一个入口。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 22)
            }.padding(.horizontal, 10).frame(width: 180).background(.thinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if state.destination == .home { home } else { settings }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }.tint(Color(red: 0.13, green: 0.40, blue: 0.46))
    }

    private func navigation(_ title: String, symbol: String, destination: HostDestination) -> some View {
        Button { state.destination = destination } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: state.destination == destination ? .semibold : .regular))
                .foregroundStyle(state.destination == destination ? Color.accentColor : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(state.destination == destination ? Color.primary.opacity(0.06) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityValue(state.destination == destination ? "已选择" : "")
    }

    @ViewBuilder private var home: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("你的日常工具").font(.system(size: 27, weight: .semibold))
            Text("选择应用，在独立窗口中使用。")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 28)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 16)], spacing: 16) {
                ForEach(registry.modules, id: \.descriptor.id) { module in
                    ToolCard(descriptor: module.descriptor, running: registry.started.contains(module.descriptor.id),
                             error: registry.failures[module.descriptor.id], status: registry.statuses[module.descriptor.id]) { registry.open(module.descriptor.id) }
                }
            }.padding(.horizontal, 32).padding(.bottom, 24)
        }
        Divider()
        HStack(spacing: 7) {
            Image(systemName: "circle.inset.filled").foregroundStyle(.secondary)
            Text("\(registry.started.count) 个应用在后台运行 · 关闭窗口后继续工作")
            Spacer()
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 32).padding(.vertical, 15)
    }

    @ViewBuilder private var settings: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("设置").font(.system(size: 27, weight: .semibold))
            Text("统一管理 MyTool 和所有子应用的入口。")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 20)
        Form {
            Section("启动与入口") {
                Toggle("登录时启动 MyTool", isOn: Binding(get: { preferences.loginEnabled }, set: preferences.setLaunchAtLogin))
                Toggle("显示菜单栏图标", isOn: $preferences.showMenuBarIcon)
                Toggle("显示 Dock 图标", isOn: $preferences.showDockIcon)
                Text("隐藏入口后仍会在后台运行。通过 Spotlight 或再次打开 MyTool.app 回到主页。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("辅助功能") {
                Text("MyScreen 的窗口管理与 MyClip 的自动粘贴共用 MyTool 的辅助功能权限。")
                HStack {
                    Button("打开系统设置") {
                        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    Button("在 Finder 中定位 MyTool") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
            }
            Section("本地数据") {
                Text("首次启动会复制独立版的历史、布局与设置，原数据保留。所有工具的数据均保存在本机。")
                Button("打开数据文件夹") {
                    NSWorkspace.shared.open(ToolStorage.directory("MyScreen").deletingLastPathComponent())
                }
            }
            if let error = preferences.error {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                HStack {
                    Text("MyTool 1.0").foregroundStyle(.secondary)
                    Spacer()
                    Button("退出 MyTool") { NSApp.terminate(nil) }
                }
            }
        }.formStyle(.grouped).onAppear { preferences.refreshLogin() }
    }
}

private struct ToolCard: View {
    let descriptor: ToolDescriptor
    let running: Bool
    let error: String?
    let status: ToolStatus?
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    if let url = Bundle.main.url(forResource: descriptor.name, withExtension: "icns"),
                       let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().frame(width: 68, height: 68)
                    } else {
                        Image(systemName: descriptor.symbol).font(.system(size: 34))
                            .foregroundStyle(.tint).frame(width: 68, height: 68)
                    }
                    Spacer()
                    Image(systemName: error == nil ? "arrow.up.forward" : "arrow.clockwise")
                        .foregroundStyle(.secondary).padding(.top, 8)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(descriptor.name).font(.system(size: 19, weight: .semibold))
                    Text(descriptor.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HStack {
                    Label(error != nil ? "点击重试" : running ? status?.label ?? "运行中" : "待启动",
                          systemImage: error == nil ? "circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(error != nil ? Color.orange : status?.isActive == true ? Color.green : Color.secondary)
                    Spacer()
                    Text(descriptor.shortcut).foregroundStyle(.secondary)
                }.font(.caption)
                if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(hovered ? 0.2 : 0.07)))
                .contentShape(RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain).onHover { hovered = $0 }.help("打开 \(descriptor.name)")
            .accessibilityLabel("打开 \(descriptor.name)")
    }
}
