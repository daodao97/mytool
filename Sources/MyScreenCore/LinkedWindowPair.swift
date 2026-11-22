import Foundation

/// A pair must already cover the work area before a divider gesture can link it.
public struct LinkedWindowPair: Sendable {
    public let left: WindowPlacement
    public let right: WindowPlacement
    public let bounds: Rect
    private static let tolerance = 4.0

    public init?(windows: [WindowRecord], in bounds: Rect, atX x: Double, y: Double) {
        guard bounds.isValid, windows.count == 2, x.isFinite, y.isFinite else { return nil }
        let ordered = windows.sorted { $0.frame.x < $1.frame.x }
        let a = ordered[0], b = ordered[1], t = Self.tolerance
        guard a.id != b.id, a.displayID == b.displayID, a.frame.isValid, b.frame.isValid,
              abs(a.frame.x - bounds.x) <= t, abs(b.frame.maxX - bounds.maxX) <= t,
              abs(a.frame.maxX - b.frame.x) <= t,
              [a.frame, b.frame].allSatisfy({ abs($0.y - bounds.y) <= t && abs($0.maxY - bounds.maxY) <= t }),
              abs(x - (a.frame.maxX + b.frame.x) / 2) <= 12,
              y > bounds.y + 16, y < bounds.maxY - 16 else { return nil }
        left = WindowPlacement(windowID: a.id, frame: a.frame)
        right = WindowPlacement(windowID: b.id, frame: b.frame)
        self.bounds = bounds
    }

    public var placements: [WindowPlacement] { [left, right] }

    /// Title-bar moves, outer-edge resizing and corner resizing are not divider gestures.
    public func divider(for windowID: String, current: Rect) -> Double? {
        guard current.isValid, abs(current.y - bounds.y) <= Self.tolerance,
              abs(current.maxY - bounds.maxY) <= Self.tolerance else { return nil }
        if windowID == left.windowID, abs(current.x - bounds.x) <= Self.tolerance { return current.maxX }
        if windowID == right.windowID, abs(current.maxX - bounds.maxX) <= Self.tolerance { return current.x }
        return nil
    }

    public func placements(divider: Double, minimumLeft: Double = 1, minimumRight: Double = 1) -> [WindowPlacement]? {
        guard divider.isFinite, minimumLeft.isFinite, minimumRight.isFinite,
              minimumLeft > 0, minimumRight > 0, minimumLeft + minimumRight <= bounds.width else { return nil }
        let split = min(max(divider, bounds.x + minimumLeft), bounds.maxX - minimumRight)
        return [
            WindowPlacement(windowID: left.windowID, frame: Rect(x: bounds.x, y: bounds.y, width: split - bounds.x, height: bounds.height)),
            WindowPlacement(windowID: right.windowID, frame: Rect(x: split, y: bounds.y, width: bounds.maxX - split, height: bounds.height))
        ]
    }
}
