import AppKit
import CoreGraphics
import MyScreenCore

@MainActor
final class SessionMonitor: NSObject {
    struct Snapshot: Sendable { var locked: Bool; var onConsole: Bool; var screensAwake: Bool }
    private var state = SessionRecoveryState()
    private let workspaceCenter: NotificationCenter
    private let readSnapshot: () -> Snapshot
    private let clock: () -> TimeInterval
    private var observers: [NSObjectProtocol] = []
    private var started = false
    var onChange: ((SessionChange) -> Void)?
    var onEvent: ((SessionEvent) -> Void)?
    var isSuspended: Bool { state.isSuspended }
    var isReady: Bool { state.isReady(at: clock()) }
    var readinessDelay: TimeInterval { max(0, state.readyNotBefore - clock()) }

    init(workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         readSnapshot: @escaping () -> Snapshot = { SessionMonitor.systemSnapshot() }) {
        self.workspaceCenter = workspaceCenter
        self.clock = clock
        self.readSnapshot = readSnapshot
        super.init()
    }

    private let workspaceEvents: [(Notification.Name, SessionEvent)] = [
        (NSWorkspace.willSleepNotification, .systemWillSleep),
        (NSWorkspace.didWakeNotification, .systemDidWake),
        (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
        (NSWorkspace.screensDidWakeNotification, .screensDidWake),
        (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive),
        (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive)
    ]

    func start() {
        guard !started else { return }; started = true
        for (name, event) in workspaceEvents {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handle(event) }
            })
        }
        // These are the lock/unlock notifications also used by Hammerspoon's caffeinate watcher.
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockNotification(_:)),
                name: Notification.Name(name), object: nil, suspensionBehavior: .deliverImmediately)
        }
        poll()
    }

    func stop() {
        for observer in observers { workspaceCenter.removeObserver(observer) }
        observers.removeAll()
        DistributedNotificationCenter.default().removeObserver(self)
        started = false
    }

    @objc private func lockNotification(_ notification: Notification) {
        handle(notification.name.rawValue == "com.apple.screenIsLocked" ? .locked : .unlocked)
    }

    private func handle(_ event: SessionEvent) {
        onEvent?(event)
        if let change = state.handle(event, at: clock()) { onChange?(change) }
    }

    func poll() {
        let snapshot = readSnapshot()
        if let change = state.observe(locked: snapshot.locked, onConsole: snapshot.onConsole,
                                      screensAwake: snapshot.screensAwake, at: clock()) { onChange?(change) }
    }

    nonisolated private static func systemSnapshot() -> Snapshot {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let onConsole = (session?[kCGSessionOnConsoleKey as String] as? Bool) == true
        // Lock status is an optional WindowServer dictionary field; notifications remain
        // the primary signal, with this readback covering missed delivery and cold starts.
        let locked = (session?["CGSSessionScreenIsLocked"] as? Bool) == true
        var count: UInt32 = 0
        let status = CGGetActiveDisplayList(0, nil, &count)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: max(1, Int(count)))
        let fetched = CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &count)
        let screensAwake = status == .success && fetched == .success &&
            displayIDs.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
        return Snapshot(locked: locked, onConsole: onConsole, screensAwake: screensAwake)
    }
}
