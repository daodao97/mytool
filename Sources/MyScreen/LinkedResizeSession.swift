import Foundation
import MyScreenCore

/// Runs on WindowService's AX queue. Geometry readback discovers application size
/// limits, including applications that expose no minimum-size AX attribute.
final class LinkedResizeSession {
    let pair: LinkedWindowPair
    private(set) var activeID: String?
    private(set) var limited = false
    private(set) var failed = false
    private(set) var needsRetry = false
    private(set) var diagnostic: String?
    private var minimumLeft = 1.0
    private var minimumRight = 1.0
    private var lastGood: [WindowPlacement]
    private var undoRecorded = false
    private let read: (String) -> Rect?
    private let write: (String, Rect) -> Int
    private let recordUndo: () -> Void

    init(pair: LinkedWindowPair, read: @escaping (String) -> Rect?, write: @escaping (String, Rect) -> Int,
         recordUndo: @escaping () -> Void) {
        self.pair = pair; self.read = read; self.write = write; self.recordUndo = recordUndo
        lastGood = pair.placements
    }

    var message: String? {
        guard activeID != nil else { return nil }
        if failed { return "联动缩放已停止：应用拒绝调整窗口，已尝试恢复上次完整排布" }
        return limited ? "已联动缩放，分界线已停在应用允许的尺寸" : "已联动缩放两个窗口"
    }

    func update(token: WindowOperationToken, settled: Bool = false) {
        needsRetry = false
        guard !token.isCancelled, !failed,
              let left = read(pair.left.windowID), let right = read(pair.right.windowID) else { needsRetry = true; return }
        if activeID == nil {
            let candidates = pair.placements.filter { placement in
                let current = placement.windowID == pair.left.windowID ? left : right
                return abs(current.width - placement.frame.width) > 1 && pair.divider(for: placement.windowID, current: current) != nil
            }
            // Ambiguous geometry means another manager or display transition intervened.
            guard candidates.count == 1 else { return }
            activeID = candidates[0].windowID
        }
        guard let activeID,
              let requested = pair.divider(for: activeID, current: activeID == pair.left.windowID ? left : right) else { return }
        let peerID = activeID == pair.left.windowID ? pair.right.windowID : pair.left.windowID
        // Native resizing owns the active window; normally only its neighbor is written.
        // Correct the active window only when a peer's minimum size clamps the divider.
        for _ in 0..<3 {
            guard !token.isCancelled,
                  let plan = pair.placements(divider: requested, minimumLeft: minimumLeft, minimumRight: minimumRight) else { break }
            var constrained = false
            for id in [peerID, activeID] {
                guard !token.isCancelled else { return }
                guard let target = plan.first(where: { $0.windowID == id })?.frame,
                      let before = read(id) else { needsRetry = true; return }
                // The native resize loop may already have advanced since requested
                // was sampled. Never push that window back to a stale divider.
                let split = plan[0].frame.maxX
                if id == activeID, !settled, abs(split - requested) <= 1 { continue }
                if Self.matches(before, target) { continue }
                if !undoRecorded { recordUndo(); undoRecorded = true }
                let outcome = write(id, target)
                guard !token.isCancelled else { return }
                guard let actual = read(id) else { needsRetry = true; return }
                if !Self.matches(actual, target) {
                    diagnostic = "AX \(outcome)，目标 \(target)，实际 \(actual)"
                    // AX may acknowledge asynchronously or time out while Chrome
                    // is in its native tracking loop. Retry; it is not a size limit.
                    guard settled, outcome >= 0 else { needsRetry = true; return }
                    // A width larger than requested is a lower bound for this gesture.
                    if actual.width > target.width + 1 {
                        if id == pair.left.windowID { minimumLeft = max(minimumLeft, actual.width) }
                        else { minimumRight = max(minimumRight, actual.width) }
                        limited = true; constrained = true
                        break
                    }
                    needsRetry = true; return
                }
            }
            if constrained { continue }
            guard plan.allSatisfy({ placement in read(placement.windowID).map { Self.matches($0, placement.frame) } ?? false }) else {
                needsRetry = true; return
            }
            lastGood = plan
            return
        }
        needsRetry = !token.isCancelled
    }

    func abandon(token: WindowOperationToken) {
        failed = true
        for placement in lastGood {
            guard !token.isCancelled else { return }
            _ = write(placement.windowID, placement.frame)
        }
    }

    private static func matches(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) < 3 && abs(a.y - b.y) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }
}
