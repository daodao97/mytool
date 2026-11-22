import AppKit
import Combine
import IOKit.ps
import MyToolKit

@MainActor
final class ActiveModel: NSObject, ObservableObject {
    @Published private(set) var session: AwakeSession?
    @Published private(set) var mode: AwakeMode
    @Published private(set) var power: PowerSnapshot
    @Published private(set) var now: Date
    @Published private(set) var uptime: TimeInterval
    @Published var error: String?
    @Published private(set) var message = "选择时长，开始保持唤醒。"
    @Published var onlyOnAC: Bool {
        didSet { defaults?.set(onlyOnAC, forKey: "onlyOnAC"); refreshPower() }
    }
    @Published var lowBatteryProtection: Bool {
        didSet { defaults?.set(lowBatteryProtection, forKey: "lowBatteryProtection"); refreshPower() }
    }
    @Published var lowBatteryThreshold: Int {
        didSet {
            lowBatteryThreshold = min(50, max(5, lowBatteryThreshold))
            defaults?.set(lowBatteryThreshold, forKey: "lowBatteryThreshold"); refreshPower()
        }
    }
    @Published var endOnLock: Bool { didSet { defaults?.set(endOnLock, forKey: "endOnLock") } }

    private let assertions: any AwakeAssertionProviding
    private let wallClock: () -> Date
    private let monotonicClock: () -> TimeInterval
    private let readPower: () -> PowerSnapshot
    private let defaults: UserDefaults?
    private var lease: (any AwakeLease)?
    private var leaseDeadlineUptime: TimeInterval?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var monitoring = false

    init(assertions: any AwakeAssertionProviding = SystemAwakeAssertions(), defaults: UserDefaults? = nil,
         wallClock: @escaping () -> Date = Date.init,
         monotonicClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         readPower: @escaping () -> PowerSnapshot = SystemPower.snapshot) {
        self.assertions = assertions; self.defaults = defaults
        self.wallClock = wallClock; self.monotonicClock = monotonicClock; self.readPower = readPower
        mode = AwakeMode(rawValue: defaults?.string(forKey: "mode") ?? "") ?? .display
        onlyOnAC = defaults?.object(forKey: "onlyOnAC") as? Bool ?? false
        lowBatteryProtection = defaults?.object(forKey: "lowBatteryProtection") as? Bool ?? true
        lowBatteryThreshold = min(50, max(5, defaults?.object(forKey: "lowBatteryThreshold") as? Int ?? 20))
        endOnLock = defaults?.object(forKey: "endOnLock") as? Bool ?? true
        now = wallClock(); uptime = monotonicClock(); power = readPower()
        super.init()
    }

    var isActive: Bool { session?.phase == .active }
    var remaining: TimeInterval? { session?.remaining(now: now, uptime: uptime) }
    var elapsed: TimeInterval { session?.elapsed(uptime: uptime) ?? 0 }
    var status: ToolStatus {
        Self.status(for: session)
    }
    var statusPublisher: AnyPublisher<ToolStatus, Never> {
        $session.map { Self.status(for: $0) }.removeDuplicates().eraseToAnyPublisher()
    }
    private static func status(for session: AwakeSession?) -> ToolStatus {
        guard let session else { return ToolStatus(label: "未开启", isActive: false) }
        return ToolStatus(label: session.phase == .paused ? "已暂停" : session.mode.title, isActive: session.phase == .active)
    }
    var timeLabel: String {
        if let remaining { return Self.formatTime(remaining) }
        return session == nil ? "按系统设置休眠" : "不限时"
    }
    static func formatTime(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(ceil(seconds)))
        let hours = value / 3600, minutes = value % 3600 / 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, value % 60)
            : String(format: "%02d:%02d", minutes, value % 60)
    }

    func start(limit: AwakeLimit) throws {
        refreshClock()
        try limit.validate(now: now)
        power = readPower(); try validatePower()
        let candidate = AwakeSession(mode: mode, limit: limit, now: now, uptime: uptime)
        try replace(with: candidate)
        error = nil; message = "保持唤醒已开启，关闭窗口后仍会继续。"
    }
    func stop(reason: String = "会话已结束，恢复系统休眠设置。") {
        lease?.release(); lease = nil; leaseDeadlineUptime = nil; session = nil
        message = reason; updateTimer()
    }
    func pause() {
        tick()
        guard var candidate = session, candidate.phase == .active else { return }
        candidate.pause(now: now, uptime: uptime)
        lease?.release(); lease = nil; leaseDeadlineUptime = nil; session = candidate
        message = "已暂停，当前遵循系统休眠设置。"; updateTimer()
    }
    func resume() throws {
        tick()
        guard var candidate = session, candidate.phase == .paused else { return }
        power = readPower(); try validatePower()
        candidate.resume(uptime: uptime)
        try replace(with: candidate)
        error = nil; message = "保持唤醒已继续。"
    }
    func changeMode(_ mode: AwakeMode) throws {
        tick()
        guard mode != self.mode else { return }
        if var candidate = session {
            candidate.mode = mode
            try replace(with: candidate)
        }
        self.mode = mode; defaults?.set(mode.rawValue, forKey: "mode"); error = nil
    }
    func extend(by seconds: TimeInterval = 900) throws {
        tick()
        guard seconds.isFinite, seconds > 0, var candidate = session,
              let remaining = candidate.remaining(now: now, uptime: uptime) else { return }
        switch candidate.limit {
        case .unlimited: return
        case .duration:
            let total = remaining + seconds
            guard total <= 86400 else { throw AwakeError.invalidDuration }
            candidate.limit = .duration(total)
            if candidate.phase == .paused { candidate.pausedRemaining = total }
            else { candidate.uptimeDeadline = uptime + total }
        case .until(let date): candidate.limit = .until(date.addingTimeInterval(seconds))
        }
        try replace(with: candidate)
        error = nil; message = "会话已延长 \(Int(seconds / 60)) 分钟。"
    }

    /// Replacements acquire first, so a failed mode change or extension preserves the old session.
    private func replace(with candidate: AwakeSession) throws {
        let timeout = candidate.remaining(now: now, uptime: uptime)
        let replacement = candidate.phase == .active ? try assertions.acquire(mode: candidate.mode, timeout: timeout) : nil
        let previous = lease
        lease = replacement; session = candidate
        leaseDeadlineUptime = candidate.phase == .active ? timeout.map { uptime + $0 } : nil
        previous?.release(); updateTimer()
    }
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
    private func refreshClock() { now = wallClock(); uptime = monotonicClock() }
    func tick() {
        refreshClock()
        if let session, let remaining = session.remaining(now: now, uptime: uptime), remaining <= 0 {
            stop(reason: "已到结束时间，恢复系统休眠设置。")
            return
        }
        // Fixed clock times follow wall-clock adjustments; duration sessions remain monotonic.
        if let session, session.phase == .active, case .until = session.limit,
           let deadline = leaseDeadlineUptime, let remaining,
           abs(remaining - (deadline - uptime)) > 1 {
            do { try replace(with: session) }
            catch {
                self.error = error.localizedDescription
                stop(reason: "系统时间变化后无法更新唤醒会话，请重新开始。")
            }
        }
    }
    func refreshPower() {
        power = readPower()
        guard session != nil else { return }
        do { try validatePower() }
        catch { stop(reason: error.localizedDescription) }
    }
    private func validatePower() throws {
        if onlyOnAC && power.source != .ac { throw AwakeError.requiresAC }
        if lowBatteryProtection && power.source == .battery,
           let percent = power.batteryPercent, percent <= lowBatteryThreshold { throw AwakeError.lowBattery }
    }
    func screenLocked() { if endOnLock && session != nil { stop(reason: "屏幕已锁定，本次会话已结束。") } }
    func systemWillSleep() { if session != nil { stop(reason: "系统进入睡眠，本次会话已结束。") } }

    func startMonitoring() {
        guard !monitoring else { return }; monitoring = true
        refreshPower()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemWillSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick(); self?.refreshPower() }
        })
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockNotification),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil, suspensionBehavior: .deliverImmediately)
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let model = Unmanaged<ActiveModel>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { model.refreshPower() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        updateTimer()
    }
    @objc private func lockNotification() { screenLocked() }
    private func updateTimer() {
        timer?.invalidate(); timer = nil
        guard monitoring, let session else { return }
        if session.phase == .paused { guard case .until = session.limit else { return } }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func shutdown() {
        stop(); monitoring = false
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll(); DistributedNotificationCenter.default().removeObserver(self)
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
    }
}
