import Foundation

/// Read back after WindowServer and applications have had time to react to a move.
public struct LayoutRestoreVerification {
    public let matchedCount: Int
    public let misplacedCount: Int
    public let missingCount: Int
    public let unresolvedCount: Int
    public let isComplete: Bool

    public var canResumeAutomaticCapture: Bool {
        isComplete && matchedCount > 0 && misplacedCount == 0 && unresolvedCount == 0
    }

    public init(profile: LayoutProfile, displays: [DisplayInfo], live: [WindowRecord], isComplete: Bool,
                constrainedFrames: [String: Rect] = [:]) {
        self.isComplete = isComplete
        let pairs = WindowMatcher.match(saved: profile.windows, live: live, recoveringLayout: true, displays: displays)
        matchedCount = pairs.count
        missingCount = profile.windows.count - pairs.count
        let usedSaved = Set(pairs.map(\.saved)), usedLive = Set(pairs.map(\.live))
        // Closed/hidden/minimized windows are unavailable, not failed restores. Still
        // protect the layout when an unmatched, eligible window from that app is present.
        let unmatchedLiveApps = Set(live.indices.filter { !usedLive.contains($0) }.map { live[$0].bundleID })
        unresolvedCount = profile.windows.indices.filter {
            !usedSaved.contains($0) && unmatchedLiveApps.contains(profile.windows[$0].bundleID)
        }.count
        misplacedCount = pairs.filter { pair in
            let saved = profile.windows[pair.saved]
            guard let target = profile.destination(for: saved, on: displays) else { return true }
            let actual = live[pair.live].frame
            let expectedSize = constrainedFrames[saved.id] ?? target
            var positionAgrees = abs(actual.x - target.x) < 3 && abs(actual.y - target.y) < 3
            if let limited = constrainedFrames[saved.id], let screen = DisplayInfo.containing(target, in: displays) {
                // Increasing to an app's minimum width may push its right edge beyond
                // the display. Accept the corresponding clamp on the intended screen.
                let adjusted = Rect(x: target.x, y: target.y, width: limited.width, height: limited.height).constrained(to: screen.workArea)
                positionAgrees = positionAgrees || (abs(actual.x - adjusted.x) < 3 && abs(actual.y - adjusted.y) < 3)
            }
            // Minimum-size constraints are legitimate; a different position or screen is not.
            return !positionAgrees ||
                abs(actual.width - expectedSize.width) >= 3 || abs(actual.height - expectedSize.height) >= 3 ||
                DisplayInfo.containing(actual, in: displays)?.id != DisplayInfo.containing(target, in: displays)?.id
        }.count
    }
}
