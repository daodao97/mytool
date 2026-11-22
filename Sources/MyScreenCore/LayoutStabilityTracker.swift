import Foundation

/// Only complete, unchanged observations qualify for automatic persistence.
/// Callers supply monotonic time, so wall-clock adjustments cannot trigger an early save.
public struct LayoutStabilityTracker {
    public let quietInterval: TimeInterval
    private var candidate: LayoutProfile?
    private var unchangedSince: TimeInterval?
    private var lastObservation: TimeInterval?

    public init(quietInterval: TimeInterval = 2) {
        precondition(quietInterval.isFinite && quietInterval > 0)
        self.quietInterval = quietInterval
    }

    public mutating func reset() {
        candidate = nil
        unchangedSince = nil
        lastObservation = nil
    }

    public mutating func observe(_ layout: LayoutProfile, at time: TimeInterval,
                                 isComplete: Bool = true, isInteracting: Bool = false) -> LayoutProfile? {
        guard isComplete, !isInteracting, time.isFinite,
              !layout.displays.isEmpty, !layout.windows.isEmpty,
              layout.windows.allSatisfy({ $0.frame.isValid }) else {
            reset()
            return nil
        }
        if lastObservation.map({ time < $0 }) == true { reset() }
        if candidate.map({ !Self.sameArrangement($0, layout) }) ?? true {
            unchangedSince = time
        }
        // Titles and enumeration order can change without a window moving. Keep the newest
        // matching metadata, but do not restart the geometry quiet period for those changes.
        candidate = layout
        lastObservation = time
        guard let unchangedSince, time - unchangedSince >= quietInterval else { return nil }
        return layout
    }

    private static func sameArrangement(_ lhs: LayoutProfile, _ rhs: LayoutProfile) -> Bool {
        guard lhs.displays.sorted(by: { $0.id < $1.id }) == rhs.displays.sorted(by: { $0.id < $1.id }),
              lhs.windows.count == rhs.windows.count else { return false }
        let left = lhs.windows.sorted { $0.id < $1.id }
        let right = rhs.windows.sorted { $0.id < $1.id }
        return zip(left, right).allSatisfy { a, b in
            a.id == b.id && a.bundleID == b.bundleID && a.displayID == b.displayID && a.frame == b.frame
        }
    }
}
