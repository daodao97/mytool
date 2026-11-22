import SwiftUI

private enum SessionChoice: String, CaseIterable, Identifiable {
    case unlimited = "不限时", duration = "倒计时", until = "指定时间"
    var id: Self { self }
}

struct ActiveView: View {
    @ObservedObject var model: ActiveModel
    let showHome: () -> Void
    @State private var choice: SessionChoice = .duration
    @State private var minutes = 30
    @State private var endDate = Date().addingTimeInterval(3600)

    private var accent: Color { Color(red: 0.60, green: 0.35, blue: 0.08) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill").font(.system(size: 27)).foregroundStyle(accent)
                    .frame(width: 52, height: 52).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text("MyActive").font(.system(size: 23, weight: .semibold))
                    Text("让屏幕陪你多亮一会儿。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("返回 MyTool", action: showHome).buttonStyle(.borderless)
            }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sessionCard
                    if let error = model.error {
                        HStack(alignment: .top) {
                            Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                            Spacer()
                            Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                                .accessibilityLabel("关闭错误提示")
                        }
                    }
                    modePicker
                    if model.session == nil { configuration } else { sessionDetails }
                    protections
                }.padding(.horizontal, 28).padding(.bottom, 24)
            }
            Divider()
            HStack {
                Image(systemName: model.isActive ? "sun.max" : "info.circle")
                Text(model.message).lineLimit(2)
                Spacer(minLength: 0)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 13)
        }.background(Color(nsColor: .windowBackgroundColor)).tint(accent)
    }

    private var sessionCard: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Label(model.status.label, systemImage: model.session?.phase == .paused ? "pause.circle" : model.isActive ? model.mode.symbol : "moon.zzz")
                    .font(.callout.weight(.medium)).foregroundStyle(model.isActive ? accent : .secondary)
                Text(model.timeLabel).font(.system(size: model.session == nil ? 27 : 37, weight: .medium, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText())
                Text(model.session == nil ? "按需开启，到时自动结束。" : model.session?.phase == .paused ? "倒计时暂停计时；指定结束时间仍然有效。" : model.mode.detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if let session = model.session {
                VStack(spacing: 10) {
                    Button {
                        if session.phase == .active { model.pause() } else { model.perform { try model.resume() } }
                    } label: {
                        Label(session.phase == .active ? "暂停" : "继续", systemImage: session.phase == .active ? "pause.fill" : "play.fill")
                            .frame(minWidth: 72)
                    }.buttonStyle(.borderedProminent)
                    Button("结束会话") { model.stop() }.buttonStyle(.bordered).frame(minWidth: 90)
                }.controlSize(.large)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(model.isActive ? 0.28 : 0.09)))
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("唤醒模式", selection: Binding(get: { model.mode }, set: { value in model.perform { try model.changeMode(value) } })) {
                ForEach(AwakeMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
            }.pickerStyle(.segmented).labelsHidden()
            Text(model.mode.detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("结束方式", selection: $choice) {
                ForEach(SessionChoice.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            switch choice {
            case .unlimited:
                Text("保持唤醒，直到手动结束或触发保护条件。").font(.callout).foregroundStyle(.secondary)
            case .duration:
                HStack(spacing: 7) {
                    ForEach([15, 30, 60, 120, 240], id: \.self) { value in
                        Button(value < 60 ? "\(value) 分钟" : "\(value / 60) 小时") { minutes = value }
                            .buttonStyle(.bordered).tint(minutes == value ? accent : .secondary)
                    }
                    Spacer(minLength: 0)
                }.controlSize(.small)
                HStack {
                    Text("自定义").foregroundStyle(.secondary)
                    TextField("分钟", value: $minutes, format: .number).textFieldStyle(.roundedBorder).frame(width: 65)
                        .accessibilityLabel("保持唤醒分钟数")
                    Stepper("分钟", value: $minutes, in: 1...1440).fixedSize()
                    Spacer()
                    Text("最长 24 小时").font(.caption).foregroundStyle(.secondary)
                }.font(.callout)
            case .until:
                DatePicker("结束时间", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field).font(.callout)
            }
            Button {
                model.perform {
                    let limit: AwakeLimit = choice == .unlimited ? .unlimited : choice == .duration ? .duration(Double(minutes) * 60) : .until(endDate)
                    try model.start(limit: limit)
                }
            } label: { Label("开始保持唤醒", systemImage: "play.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private var sessionDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    if let session = model.session {
                        Text("开始于 \(session.startedAt.formatted(date: .omitted, time: .shortened))")
                        if case .until(let date) = session.limit {
                            Text("结束于 \(date.formatted(date: .abbreviated, time: .shortened))")
                        } else if let remaining = model.remaining, session.phase == .active {
                            Text("预计 \(model.now.addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened)) 结束")
                        }
                    }
                    Text("累计保持唤醒 \(ActiveModel.formatTime(model.elapsed))").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.remaining != nil {
                    Button { model.perform { try model.extend() } } label: { Label("延长 15 分钟", systemImage: "plus") }
                        .buttonStyle(.bordered)
                }
            }
            Text("关闭窗口后会话继续，菜单栏中也可暂停或结束。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var protections: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("电源与结束条件").font(.callout.weight(.semibold))
                Spacer()
                Label(model.power.label, systemImage: model.power.source == .ac ? "powerplug" : "battery.50")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                switchRow("仅在连接电源时运行", value: $model.onlyOnAC)
                Divider()
                HStack {
                    Text("低电量时结束")
                    Spacer()
                    Picker("低电量阈值", selection: $model.lowBatteryThreshold) {
                        ForEach([5, 10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
                    }.labelsHidden().frame(width: 76).disabled(!model.lowBatteryProtection)
                    Toggle("低电量时结束", isOn: $model.lowBatteryProtection).labelsHidden()
                }
                Divider()
                switchRow("锁屏或切换用户时结束", value: $model.endOnLock)
            }.toggleStyle(.switch).controlSize(.small).font(.callout).padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            Text("手动睡眠与合盖遵循 macOS 行为。会话结束后恢复系统休眠设置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func switchRow(_ title: String, value: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: value).labelsHidden()
        }
    }
}
