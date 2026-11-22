import Foundation

enum AwakeMode: String, CaseIterable, Identifiable {
    case display, system
    var id: Self { self }
    var title: String { self == .display ? "屏幕常亮" : "仅保持系统运行" }
    var detail: String { self == .display ? "屏幕和系统保持唤醒，适合阅读、演示和会议。" : "允许屏幕自动熄灭，后台任务继续运行。" }
    var symbol: String { self == .display ? "sun.max.fill" : "desktopcomputer" }
}

enum AwakeLimit: Equatable {
    case unlimited, duration(TimeInterval), until(Date)

    func validate(now: Date) throws {
        switch self {
        case .unlimited: break
        case .duration(let seconds):
            guard seconds.isFinite, seconds >= 1, seconds <= 86400 else { throw AwakeError.invalidDuration }
        case .until(let date):
            guard date.timeIntervalSince(now).isFinite, date > now else { throw AwakeError.invalidEndDate }
        }
    }
}

struct AwakeSession: Equatable {
    enum Phase { case active, paused }
    var mode: AwakeMode
    var phase = Phase.active
    let startedAt: Date
    var limit: AwakeLimit
    var uptimeDeadline: TimeInterval?
    var pausedRemaining: TimeInterval?
    var accruedActiveTime: TimeInterval = 0
    var resumedAtUptime: TimeInterval

    init(mode: AwakeMode, limit: AwakeLimit, now: Date, uptime: TimeInterval) {
        self.mode = mode; self.limit = limit; startedAt = now; resumedAtUptime = uptime
        if case .duration(let seconds) = limit { uptimeDeadline = uptime + seconds }
    }

    func remaining(now: Date, uptime: TimeInterval) -> TimeInterval? {
        switch limit {
        case .unlimited: return nil
        case .until(let date): return max(0, date.timeIntervalSince(now))
        case .duration:
            return max(0, phase == .paused ? pausedRemaining ?? 0 : (uptimeDeadline ?? uptime) - uptime)
        }
    }
    func elapsed(uptime: TimeInterval) -> TimeInterval {
        accruedActiveTime + (phase == .active ? max(0, uptime - resumedAtUptime) : 0)
    }
    mutating func pause(now: Date, uptime: TimeInterval) {
        guard phase == .active else { return }
        pausedRemaining = remaining(now: now, uptime: uptime)
        accruedActiveTime = elapsed(uptime: uptime)
        phase = .paused
    }
    mutating func resume(uptime: TimeInterval) {
        guard phase == .paused else { return }
        if case .duration = limit { uptimeDeadline = uptime + (pausedRemaining ?? 0) }
        resumedAtUptime = uptime; phase = .active; pausedRemaining = nil
    }
}

struct PowerSnapshot: Equatable {
    enum Source { case ac, battery, unknown }
    var source: Source
    var batteryPercent: Int?
    static let unknown = PowerSnapshot(source: .unknown, batteryPercent: nil)
    var label: String {
        let source = self.source == .ac ? "外接电源" : self.source == .battery ? "电池供电" : "供电状态未知"
        return source + (batteryPercent.map { " · 电量 \($0)%" } ?? "")
    }
}

enum AwakeError: LocalizedError {
    case invalidDuration, invalidEndDate, requiresAC, lowBattery, assertion(Int32)
    var errorDescription: String? {
        switch self {
        case .invalidDuration: return "请设置 1 分钟至 24 小时的时长。"
        case .invalidEndDate: return "结束时间需要晚于当前时间。"
        case .requiresAC: return "已开启「仅在连接电源时运行」，请连接电源后再开始。"
        case .lowBattery: return "当前电量已达到保护阈值，请充电或调整低电量保护设置。"
        case .assertion(let code): return "无法开启保持唤醒（系统错误 \(code)），请重试。"
        }
    }
}
