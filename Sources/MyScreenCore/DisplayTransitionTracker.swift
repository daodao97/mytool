import Foundation

/// A hardware event must survive notification coalescing, even when a quick unplug/replug
/// ends on exactly the same screens. Cosmetic AppKit notifications alone need no recovery.
public struct DisplayTransitionTracker {
    private var stableDisplays: [DisplayInfo] = []
    private var recoveryRequested = false

    public init() {}

    public mutating func begin(requiresRecovery: Bool = false, interruptingRecovery: Bool = false) {
        recoveryRequested = recoveryRequested || requiresRecovery || interruptingRecovery
    }

    public mutating func finish(displays: [DisplayInfo]) -> Bool {
        guard !displays.isEmpty else { return false }
        let needsRecovery = recoveryRequested || displays != stableDisplays
        stableDisplays = displays
        recoveryRequested = false
        return needsRecovery
    }
}
