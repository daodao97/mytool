import SwiftUI
import AppKit
import MyScreenCore

private let accent = Color(red: 0.08, green: 0.48, blue: 0.43)
private let pageBackground = Color(nsColor: .windowBackgroundColor)

private enum Destination: String, CaseIterable, Identifiable {
    case overview = "概览", arrange = "窗口排布", layouts = "布局记忆", shortcuts = "快捷键", settings = "设置"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .arrange: return "rectangle.split.2x2"
        case .layouts: return "rectangle.3.group"
        case .shortcuts: return "command"
        case .settings: return "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "查看屏幕状态，安排每一扇窗口。"
        case .arrange: return "常见分屏与多窗口平铺，一次安排到位。"
        case .layouts: return "记住不同工位，连接时回到熟悉的位置。"
        case .shortcuts: return "手不离开键盘，让窗口各就各位。"
        case .settings: return "让 MyScreen 按你的习惯工作。"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var destination: Destination? = .overview
    @State private var showSaveSheet = false
    @State private var layoutName = ""
    @State private var renaming: LayoutProfile?
    @State private var deleting: LayoutProfile?
    @State private var showAllWindows = false
    @State private var tileLayout: WindowTileLayout = .automatic
    @State private var tileDisplayID = ""
    private var selected: Destination { destination ?? .overview }
    init(model: AppModel, initialSection: String = "概览") {
        self.model = model
        _destination = State(initialValue: Destination(rawValue: initialSection) ?? .overview)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.3.group.fill").font(.system(size: 24)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MyScreen").font(.system(size: 18, weight: .bold, design: .rounded))
                        Text("窗口各就各位").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 19).padding(.top, 30).padding(.bottom, 27)
                VStack(spacing: 6) {
                    ForEach(Destination.allCases) { item in
                        Button { destination = item } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .font(.system(size: 13, weight: selected == item ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 13).padding(.vertical, 11)
                                .foregroundStyle(selected == item ? accent : Color.primary)
                                .background(selected == item ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityValue(selected == item ? "已选择" : "")
                    }
                }.padding(.horizontal, 12)
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 7) {
                        Circle().fill(model.isTrusted ? accent : Color.orange).frame(width: 6, height: 6)
                        Text(model.isTrusted ? "MyScreen 正在运行" : "等待辅助功能权限").font(.caption)
                    }
                    Text("关闭窗口后继续运行，可从 MyTool 重新打开。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(18)
            }
            .frame(width: 205).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !model.isTrusted { permissionCard }
                        if let error = model.errorMessage { errorCard(error) }
                        if model.isAutomaticCaptureProtected && !model.isBusy && !model.isTransitioning {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("恢复尚未完成，原布局已保留", systemImage: "lock.shield")
                                    .font(.callout.weight(.medium))
                                Text("自动记忆已暂停，避免覆盖原位置。可重新恢复，或确认窗口位置后记住当前布局。")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("重新恢复布局") { model.retryRecovery() }.disabled(!model.canOperate)
                                    Button("记住当前位置") { model.rememberCurrentLayout() }.disabled(!model.canOperate)
                                }.buttonStyle(.bordered)
                            }.frame(maxWidth: .infinity, alignment: .leading).card()
                        }
                        switch selected {
                        case .overview: overview
                        case .arrange: windowArrangement
                        case .layouts: layouts
                        case .shortcuts: shortcuts
                        case .settings: settings
                        }
                    }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
                }
                Divider()
                HStack(spacing: 8) {
                    if model.isTransitioning || model.isBusy { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                    Text(model.notice).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if model.isWindowModeActive { Label("窗口模式 · Esc 退出", systemImage: "keyboard").font(.caption).foregroundStyle(accent) }
                    if model.autoRemember {
                        Label(model.isAutomaticCaptureProtected ? "原布局已保护" : model.isWaitingForLayoutStability ? "等待窗口稳定" : "自动记忆",
                              systemImage: model.isAutomaticCaptureProtected ? "lock.shield" : model.isWaitingForLayoutStability ? "clock" : "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(accent)
                    }
                }.padding(.horizontal, 24).padding(.vertical, 12)
            }.background(pageBackground)
        }
        .tint(accent)
        .sheet(isPresented: $showSaveSheet) { nameSheet(isRename: false) }
        .sheet(item: $renaming) { _ in nameSheet(isRename: true) }
        .alert("删除这个布局？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) { if let profile = deleting { model.deleteProfile(profile) }; deleting = nil }
        } message: { Text("已保存的「\(deleting?.name ?? "")」将被删除。自动记忆开启时，当前屏幕组合会再次保存。") }
        .onChange(of: destination) { _, _ in if model.isRecordingAnyShortcut { model.finishRecording(keyCode: nil) } }
        .background {
            if model.isRecordingAnyShortcut {
                ShortcutCaptureView { key, modifiers in model.finishRecording(keyCode: key, modifiers: modifiers) }
                    .frame(width: 0, height: 0)
            }
        }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(selected.rawValue).font(.system(size: 25, weight: .semibold))
                Text(selected.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if selected == .overview || selected == .layouts {
                Button { layoutName = "我的布局"; showSaveSheet = true } label: {
                    Label("保存当前布局", systemImage: "plus")
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canOperate)
            }
        }.padding(.horizontal, 28).padding(.top, 27).padding(.bottom, 23)
    }
    private var permissionCard: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "hand.raised.fill").font(.system(size: 25)).foregroundStyle(accent)
                .frame(width: 48, height: 52).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.permissionNeedsAttention ? "权限尚未生效" : "先允许 MyTool 管理窗口").font(.headline)
                Text(model.permissionNeedsAttention
                     ? "若系统设置中已经开启，请先重启；仍无效时，移除旧 MyTool 条目，再添加当前应用。"
                     : "在系统设置的「辅助功能」中开启 MyTool。授权后返回应用会自动检测。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.permissionNeedsAttention {
                    HStack {
                        Button("重新启动") { model.restartApplication() }
                        Button("定位当前应用") { model.revealApplication() }
                    }.font(.caption)
                }
            }
            Spacer(minLength: 10)
            VStack(spacing: 8) {
                Button("打开系统设置") { model.requestPermission() }.buttonStyle(.bordered).controlSize(.large)
                Button("我已授权，重新检查") { model.refreshPermission(manual: true) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(accent)
            }
        }.padding(18).background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.18)))
    }
    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error).font(.callout).textSelection(.enabled)
            Spacer()
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }.padding(16).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                MetricCard(value: "\(model.displays.count)", title: "已连接显示器", detail: model.externalDisplayCount > 0 ? "含 \(model.externalDisplayCount) 块外接屏幕" : "内置屏幕也可以记忆", symbol: "display")
                MetricCard(value: "\(model.automaticProfiles.count)", title: "已记忆屏幕组合", detail: "识别过 \(model.rememberedDisplayCount) 块外接屏幕", symbol: "rectangle.3.group")
                MetricCard(value: "\(model.windows.count)", title: "可管理窗口", detail: model.isTrusted ? "稳定约 2 秒后自动保存" : "授权后开始检测", symbol: "macwindow")
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("当前屏幕布局").font(.headline)
                    Spacer()
                    Label(model.isTransitioning ? "正在连接" : "\(model.displays.count) 块屏幕在线", systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(accent)
                }
                DisplayMapView(displays: model.displays, windows: model.windows).frame(height: 205)
                HStack(spacing: 12) {
                    ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
                        HStack(spacing: 8) {
                            Text("\(index + 1)").font(.caption.weight(.semibold)).frame(width: 23, height: 23)
                                .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(display.name).font(.caption.weight(.medium)).lineLimit(1)
                                Text("\(Int(display.frame.width)) × \(Int(display.frame.height))\(display.isMain ? " · 主显示器" : "")")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.card()
            windowArrangement
            VStack(alignment: .leading, spacing: 15) {
                HStack { Text("当前窗口").font(.headline); Spacer(); Text("自动排除最小化、隐藏和全屏窗口").font(.caption).foregroundStyle(.secondary) }
                if model.windows.isEmpty {
                    EmptyState(symbol: "macwindow", title: model.isTrusted ? "等待窗口出现" : "授权后，在这里查看窗口",
                               detail: model.isTrusted ? "打开其他应用的普通窗口，MyScreen 会自动检测。" : "只需开启一次辅助功能权限，即可开始使用。")
                } else {
                    ForEach(Array(model.windows.prefix(showAllWindows ? model.windows.count : 8))) { window in
                        HStack(spacing: 11) {
                            AppIcon(bundleID: window.bundleID).frame(width: 29, height: 29)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(window.title.isEmpty ? window.appName : window.title).font(.callout).lineLimit(1)
                                Text(window.appName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(model.displays.first(where: { $0.id == window.displayID })?.name ?? "显示器")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Menu {
                                ForEach(WindowAction.commonLayouts + [.center, .nextDisplay, .previousDisplay]) { action in
                                    Button { model.perform(action, windowID: window.id) } label: {
                                        Label(action.title, systemImage: action.symbol)
                                    }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).frame(width: 24)
                                .help("整理这个窗口").disabled(!model.canOperate)
                        }
                        if window.id != model.windows.prefix(showAllWindows ? model.windows.count : 8).last?.id { Divider() }
                    }
                    if model.windows.count > 8 {
                        Button(showAllWindows ? "收起窗口列表" : "显示全部 \(model.windows.count) 个窗口") { showAllWindows.toggle() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(accent)
                    }
                }
            }.card()
        }
    }
    private var windowArrangement: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("快速整理").font(.headline)
                    Spacer()
                    Button("查看全部快捷键") { destination = .shortcuts }.buttonStyle(.plain).font(.caption).foregroundStyle(accent)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4), spacing: 9) {
                    ForEach(WindowAction.commonLayouts + [.center, .nextDisplay, .undo]) { action in
                        Button { model.perform(action) } label: {
                            HStack(spacing: 8) {
                                if WindowAction.commonLayouts.contains(action) { LayoutGlyph(action: action) }
                                else { Image(systemName: action.symbol).font(.system(size: 16)).frame(width: 24) }
                                Text(action == .nextDisplay ? "切换屏幕" : action == .maximize ? "填满" : action == .undo ? "撤销" : action.title).font(.caption).lineLimit(1)
                            }.frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).disabled(!model.canOperate)
                    }
                }
                Text("快捷键控制当前前台窗口；面板按钮控制最近使用的其他应用窗口。")
                    .font(.caption).foregroundStyle(.secondary)
            }.card()
            VStack(alignment: .leading, spacing: 12) {
                settingToggle("并排窗口联动缩放", detail: "两个窗口左右铺满屏幕后，拖动中间边缘，另一个窗口同步调整。按住 Option 暂停；可整体撤销。", binding: $model.linkedResize)
            }.card()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("多窗口自动排布").font(.headline)
                    Spacer()
                    Button { model.tileWindows(tileLayout, displayID: tileDisplayID.isEmpty ? nil : tileDisplayID) } label: {
                        Label("立即排布", systemImage: "rectangle.3.group")
                    }.buttonStyle(.borderedProminent).disabled(!model.canOperate)
                }
                Divider()
                settingToggle("拖动后自动重排同屏窗口", detail: "开启后会预览所有窗口的位置，松手一起排布；边缘吸附保留所选半屏或四角，其余窗口填入剩余区域。", binding: $model.autoTileWindows)
                if !model.autoArrange {
                    Text("需同时开启设置中的「拖动吸附与自动排版」。").font(.caption).foregroundStyle(.secondary)
                }
                Picker("排布方式", selection: $tileLayout) {
                    ForEach(WindowTileLayout.allCases) { layout in Text(layout.title).tag(layout) }
                }.pickerStyle(.segmented)
                Picker("目标屏幕", selection: $tileDisplayID) {
                    Text("跟随最近使用的窗口").tag("")
                    ForEach(model.displays) { display in Text(display.name).tag(display.id) }
                }
                Text("智能网格按窗口数量和屏幕比例分配空间；分列、分行适合并排对照。只整理目标屏幕当前桌面的普通窗口，可一次撤销。")
                    .font(.caption).foregroundStyle(.secondary)
            }.card()
        }
    }
    private var layouts: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "cable.connector").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("插上屏幕，继续上次的工作").font(.headline)
                    Text("屏幕组合分别记忆。断开连接时恢复剩余屏幕布局；重连时恢复外接屏布局。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("自动恢复", isOn: $model.autoRestore).toggleStyle(.switch).labelsHidden().help("连接变化时自动恢复")
            }.card()
            sectionTitle("自动记忆", trailing: "\(model.automaticProfiles.count) 个屏幕组合")
            if model.automaticProfiles.isEmpty {
                EmptyState(symbol: "display.2", title: "你的第一个工位，等待记忆", detail: "授权并打开应用窗口后，当前显示器组合会自动保存在这里。外接屏无需手动添加。")
                    .card()
            } else { ForEach(model.automaticProfiles) { profile in profileRow(profile) } }
            sectionTitle("我的布局", trailing: "\(model.namedProfiles.count) 个布局")
            if model.namedProfiles.isEmpty {
                EmptyState(symbol: "square.stack", title: "为不同任务留一个位置", detail: "保存「专注工作」「设计」「会议」等布局，随时一键恢复。")
                    .card()
            } else { ForEach(model.namedProfiles) { profile in profileRow(profile) } }
            Text("恢复会匹配已打开的应用与窗口，并适配可用区域和分辨率。首次连接新外屏时会沿用同类外屏布局，之后分别记忆；原外屏上的窗口优先转到新外屏，没有对应外屏时移到主显示器。未打开的应用不会自动启动。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func profileRow(_ profile: LayoutProfile) -> some View {
        let connected = profile.topologyKey == DisplayInfo.topologyKey(model.displays)
        return HStack(spacing: 17) {
            Image(systemName: profile.displays.count > 1 ? "display.2" : "display")
                .font(.system(size: 26)).foregroundStyle(accent)
                .frame(width: 65, height: 65).background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(profile.name).font(.headline).lineLimit(1)
                    if connected { Text("当前组合").font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(accent.opacity(0.09), in: Capsule()) }
                }
                Text("\(profile.displays.count) 块屏幕 · \(profile.windows.count) 个窗口 · \(profile.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if !connected { Text("显示器未全部连接，恢复时将适配到当前屏幕").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Button("恢复布局") { model.restore(profile) }.buttonStyle(.bordered).disabled(!model.canOperate)
            Menu {
                if !profile.isAutomatic {
                    Button("重命名") { layoutName = profile.name; renaming = profile }
                }
                Button("删除布局", role: .destructive) { deleting = profile }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
        }.card()
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Leader 进入，功能键整理，Esc 退出").font(.headline)
                    Text("沿用 Hammerspoon WinWin 的按键。进入后松开修饰键，可连续操作。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用", isOn: $model.shortcutsEnabled).toggleStyle(.switch)
                Button("恢复默认") { model.resetShortcuts() }
            }.card()
            HStack(spacing: 15) {
                Image(systemName: "keyboard").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("进入窗口模式的 Leader").font(.headline)
                    Text("Esc / Q 退出 · Tab 展开提示 · 再按 leader 也可退出").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.beginRecordingLeader() } label: {
                    Text(model.isRecordingLeader ? "按下组合键…" : model.leader.label)
                        .font(.system(.body, design: .monospaced)).frame(minWidth: 100)
                }.buttonStyle(.bordered).controlSize(.large)
                Button("进入模式") { model.toggleWindowMode() }.disabled(!model.canOperate || !model.shortcutsEnabled || model.isRecordingAnyShortcut)
            }.card()
            if model.leaderRegistrationFailed {
                Label("Leader 被其他应用或系统占用，请更换组合，或停用 Hammerspoon 中重复的窗口入口。", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            Text("单边缩放：Shift+H/L 固定左边、调整右边；Shift+K/J 固定上边、调整下边。到达屏幕边缘时停止扩大，固定边不移动。")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(model.bindings.enumerated()), id: \.element.id) { index, binding in
                    HStack(spacing: 13) {
                        Image(systemName: binding.action.symbol).frame(width: 24).foregroundStyle(accent)
                        Text(binding.action.title).font(.callout)
                        Spacer()
                        Button { model.beginRecording(binding.action) } label: {
                            Text(model.recordingShortcut == binding.action ? "按下组合键…" : binding.label)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .frame(minWidth: 116).padding(.vertical, 5)
                        }.buttonStyle(.bordered).tint(model.recordingShortcut == binding.action ? accent : nil)
                    }.padding(.vertical, 11).padding(.horizontal, 18)
                    if index != model.bindings.count - 1 { Divider().padding(.leading, 55) }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.07)))
            Text("下列按键仅在窗口模式中生效，可点击录制单键或组合键；Esc 取消录制。微移与缩放步长为屏幕的 1/30，可长按。撤销与重做各保留最多 20 次。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionTitle("应用入口", trailing: "MyTool")
            HStack {
                Text("菜单栏、Dock 和登录启动在 MyTool 中统一设置。")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("打开 MyTool 设置") { MyScreenModule.current?.host.showSettings() }
            }.card()
            sectionTitle("布局与连接", trailing: "")
            VStack(spacing: 20) {
                settingToggle("拖动吸附与自动排版", detail: "左右及底部半屏、靠近顶部上半屏、贴住最顶端填满，四角四分屏。按住 Option 暂停，松开鼠标应用。", binding: $model.autoArrange)
                Divider()
                settingToggle("拖动后自动重排同屏窗口", detail: "预览并一起调整同屏窗口；关闭时只调整拖动的窗口。批量排布可一次撤销。", binding: $model.autoTileWindows)
                Divider()
                settingToggle("并排窗口联动缩放", detail: "两个窗口左右铺满屏幕时，拖动中间边缘，另一个窗口同步填满剩余区域。按住 Option 暂停；可整体撤销。", binding: $model.linkedResize)
                Divider()
                settingToggle("自动记忆布局", detail: "窗口位置和大小稳定约 2 秒后自动保存，分别记忆每个显示器组合。", binding: $model.autoRemember)
                Divider()
                settingToggle("显示器变化时恢复布局", detail: "拔插、重连或唤醒后，等待屏幕稳定再恢复窗口。", binding: $model.autoRestore)
                Divider()
                settingToggle("启用全局快捷键", detail: "在其他应用中也能移动窗口。", binding: $model.shortcutsEnabled)
            }.card()
            sectionTitle("权限与数据", trailing: "仅保存在本机")
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("辅助功能权限", systemImage: "hand.raised").font(.callout.weight(.medium))
                    Spacer()
                    Text(model.isTrusted ? "已开启" : "未开启").font(.caption).foregroundStyle(model.isTrusted ? accent : .orange)
                    Button("前往系统设置") { model.requestPermission() }
                    Button("重新检查") { model.refreshPermission(manual: true) }
                }
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("本地布局文件").font(.callout.weight(.medium))
                        Text("保存窗口标题、应用标识、文档标识和位置，不上传任何数据。保留上一版备份及最近 20 次显示器切换前的存档。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("在 Finder 中打开") { model.revealData() }
                }
            }.card()
            sectionTitle("最近活动", trailing: "本次运行")
            VStack(alignment: .leading, spacing: 13) {
                if model.activities.isEmpty { Text("开始使用后，这里会显示布局恢复和窗口操作记录。").font(.callout).foregroundStyle(.secondary) }
                ForEach(model.activities) { item in
                    HStack(alignment: .top, spacing: 15) {
                        Text(item.date.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary)
                        Text(item.message)
                    }.font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).card()
            Text("MyScreen 1.0 · 原生 macOS 窗口管理\n全屏、最小化和隐藏窗口会被跳过。部分应用会限制窗口的最小尺寸；Spaces 中不可访问的窗口可能无法恢复。")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(5)
            Button("关闭 MyScreen 窗口") { MyScreenModule.current?.closeWindow() }.buttonStyle(.bordered)
        }
    }
    private func settingToggle(_ title: String, detail: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: binding).toggleStyle(.switch).labelsHidden()
        }
    }
    private func sectionTitle(_ title: String, trailing: String) -> some View {
        HStack { Text(title).font(.headline); Spacer(); Text(trailing).font(.caption).foregroundStyle(.secondary) }
    }
    private func nameSheet(isRename: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isRename ? "重命名布局" : "保存当前布局").font(.title2.weight(.semibold))
            Text(isRename ? "为这个布局起一个容易识别的名字。" : "记住当前已打开窗口的位置和大小，方便下次恢复。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("例如：专注工作", text: $layoutName).textFieldStyle(.roundedBorder)
                .onSubmit { commitName(isRename: isRename) }
            HStack { Spacer(); Button("取消") { showSaveSheet = false; renaming = nil }.keyboardShortcut(.cancelAction)
                Button(isRename ? "重命名" : "保存布局") { commitName(isRename: isRename) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(layoutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 420)
    }
    private func commitName(isRename: Bool) {
        if isRename, let profile = renaming { model.renameProfile(profile, name: layoutName) }
        else { model.saveNamedLayout(name: layoutName) }
        showSaveSheet = false; renaming = nil
    }
}

private struct LayoutGlyph: View {
    let action: WindowAction
    var body: some View {
        Canvas { context, size in
            let area = Rect(x: 0, y: 0, width: size.width, height: size.height)
            if let target = action.target(in: area, current: area) {
                let rect = CGRect(x: target.x, y: target.y, width: target.width, height: target.height).insetBy(dx: 1.5, dy: 1.5)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(accent.opacity(0.7)))
            }
            context.stroke(Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.7, dy: 0.7), cornerRadius: 3),
                           with: .color(.primary), lineWidth: 1.3)
        }.frame(width: 24, height: 18).accessibilityHidden(true)
    }
}

private struct MetricCard: View {
    let value: String, title: String, detail: String, symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer(); Image(systemName: symbol).foregroundStyle(accent) }
            Text(value).font(.system(size: 31, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 17)
    }
}
private struct EmptyState: View {
    let symbol: String, title: String, detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(accent.opacity(0.65))
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}
private struct AppIcon: View {
    let bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else { Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.secondary) }
    }
}
private extension View {
    func card(padding: CGFloat = 20) -> some View {
        self.padding(padding).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

private struct DisplayMapView: View {
    let displays: [DisplayInfo]
    let windows: [WindowRecord]
    var body: some View {
        GeometryReader { geometry in
            let minX = displays.map(\.frame.x).min() ?? 0
            let minY = displays.map(\.frame.y).min() ?? 0
            let width = max(1, (displays.map(\.frame.maxX).max() ?? 1) - minX)
            let height = max(1, (displays.map(\.frame.maxY).max() ?? 1) - minY)
            let scale = min((geometry.size.width - 68) / width, (geometry.size.height - 45) / height)
            let offsetX = (geometry.size.width - width * scale) / 2
            let offsetY = (geometry.size.height - height * scale) / 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.025))
                Canvas { context, size in
                    var dots = Path()
                    for x in stride(from: 12.0, to: size.width, by: 16) {
                        for y in stride(from: 12.0, to: size.height, by: 16) { dots.addEllipse(in: CGRect(x: x, y: y, width: 1.3, height: 1.3)) }
                    }
                    context.fill(dots, with: .color(.secondary.opacity(0.18)))
                }
                ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                    let w = display.frame.width * scale, h = display.frame.height * scale
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                        RoundedRectangle(cornerRadius: 6).fill(accent.opacity(display.isMain ? 0.11 : 0.05))
                        ForEach(windows.filter { $0.displayID == display.id }.prefix(10)) { window in
                            RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.10))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(accent.opacity(0.18), lineWidth: 0.7))
                                .frame(width: max(2, window.frame.width * scale), height: max(2, window.frame.height * scale))
                                .offset(x: (window.frame.x - display.frame.x) * scale, y: (window.frame.y - display.frame.y) * scale)
                        }
                        VStack(spacing: 5) {
                            Text("\(index + 1)").font(.system(size: 23, weight: .semibold, design: .rounded))
                            Text(display.isBuiltIn ? "内置显示器" : display.name).font(.system(size: 10)).lineLimit(1)
                        }.frame(width: w, height: h).foregroundStyle(accent)
                    }
                    .frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(accent.opacity(display.isMain ? 0.6 : 0.3), lineWidth: display.isMain ? 2 : 1))
                    .offset(x: offsetX + (display.frame.x - minX) * scale, y: offsetY + (display.frame.y - minY) * scale)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("显示器 \(index + 1)，\(display.name)\(display.isMain ? "，主显示器" : "")")
                }
            }
        }
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: (UInt32?, UInt32) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }
    func makeNSView(context: Context) -> NSView { context.coordinator.start(); return NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onCapture = onCapture }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }
    final class Coordinator {
        var onCapture: (UInt32?, UInt32) -> Void
        var monitor: Any?
        init(onCapture: @escaping (UInt32?, UInt32) -> Void) { self.onCapture = onCapture }
        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard !event.isARepeat else { return nil }
                if event.keyCode == 53 { self.onCapture(nil, 0) }
                else { self.onCapture(UInt32(event.keyCode), ShortcutBinding.carbonModifiers(event.modifierFlags)) }
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { stop() }
    }
}
