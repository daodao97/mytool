import Foundation

public enum SessionEvent: Sendable {
    case locked, unlocked, systemWillSleep, systemDidWake
    case screensDidSleep, screensDidWake, sessionInactive, sessionActive
}

public enum SessionChange: Equatable, Sendable { case paused, resumed }

/// Desktop availability is independent of display geometry. Keep each blocker until
/// its corresponding resume event; waking the screens does not unlock the session.
public struct SessionRecoveryState {
    public private(set) var locked = false
    public private(set) var systemSleeping = false
    public private(set) var screensSleeping = false
    public private(set) var sessionInactive = false
    public private(set) var readyNotBefore: TimeInterval = -.infinity
    public let resumeDelay: TimeInterval
    public var isSuspended: Bool { locked || systemSleeping || screensSleeping || sessionInactive }

    public init(resumeDelay: TimeInterval = 0.4) { self.resumeDelay = resumeDelay }

    public func isReady(at time: TimeInterval) -> Bool { !isSuspended && time >= readyNotBefore }

    public mutating func handle(_ event: SessionEvent, at time: TimeInterval) -> SessionChange? {
        let wasSuspended = isSuspended
        var resumeEvent = false
        switch event {
        case .locked: locked = true
        case .unlocked: locked = false; resumeEvent = true
        case .systemWillSleep: systemSleeping = true
        case .systemDidWake: systemSleeping = false; resumeEvent = true
        case .screensDidSleep: screensSleeping = true
        case .screensDidWake: screensSleeping = false; resumeEvent = true
        case .sessionInactive: sessionInactive = true
        case .sessionActive: sessionInactive = false; resumeEvent = true
        }
        return transition(wasSuspended: wasSuspended, requestRecovery: resumeEvent, at: time)
    }

    /// Polling recovers from a missed notification, including launch into a locked session.
    public mutating func observe(locked: Bool, onConsole: Bool, screensAwake: Bool, at time: TimeInterval) -> SessionChange? {
        let wasSuspended = isSuspended
        self.locked = locked
        sessionInactive = !onConsole
        screensSleeping = !screensAwake
        return transition(wasSuspended: wasSuspended, requestRecovery: false, at: time)
    }

    private mutating func transition(wasSuspended: Bool, requestRecovery: Bool, at time: TimeInterval) -> SessionChange? {
        if isSuspended { return wasSuspended ? nil : .paused }
        guard wasSuspended || requestRecovery else { return nil }
        readyNotBefore = time + resumeDelay
        return .resumed
    }
}
