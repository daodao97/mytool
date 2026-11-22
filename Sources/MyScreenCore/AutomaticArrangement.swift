import Foundation

/// Finds the largest unobstructed rectangle around the moved window's center.
/// All coordinates use the display's AX work area, including negative origins.
public enum AutomaticArrangement {
    /// Pointer-based edge zones take priority over free-space filling. A wider exit
    /// band keeps an armed zone stable when the pointer wobbles near its boundary.
    public static func snapAction(atX x: Double, y: Double, on display: DisplayInfo,
                                  previous: WindowAction? = nil) -> WindowAction? {
        let frame = display.frame, area = display.workArea
        guard frame.isValid, area.isValid, x.isFinite, y.isFinite,
              x >= frame.x, x < frame.maxX, y >= frame.y, y < frame.maxY else { return nil }
        func zone(edge: Double, corner: Double) -> WindowAction? {
            let left = x <= area.x + edge, right = x >= area.maxX - edge
            let top = y <= area.y + edge, bottom = y >= area.maxY - edge
            let nearLeft = x <= area.x + min(corner, area.width / 4)
            let nearRight = x >= area.maxX - min(corner, area.width / 4)
            let nearTop = y <= area.y + min(corner, area.height / 4)
            let nearBottom = y >= area.maxY - min(corner, area.height / 4)
            if (left && nearTop) || (top && nearLeft) { return .topLeft }
            if (right && nearTop) || (top && nearRight) { return .topRight }
            if (left && nearBottom) || (bottom && nearLeft) { return .bottomLeft }
            if (right && nearBottom) || (bottom && nearRight) { return .bottomRight }
            if left { return .left }
            if right { return .right }
            if top { return y <= frame.y + 8 ? .maximize : .top }
            if bottom { return .bottom }
            return nil
        }
        if let action = zone(edge: 24, corner: 80) { return action }
        if let previous, zone(edge: 40, corner: 96) == previous { return previous }
        return nil
    }

    public static func target(for window: Rect, in bounds: Rect, avoiding windows: [Rect]) -> Rect? {
        guard window.isValid, bounds.isValid else { return nil }
        let cx = window.x + window.width / 2, cy = window.y + window.height / 2
        guard cx > bounds.x, cx < bounds.maxX, cy > bounds.y, cy < bounds.maxY else { return nil }
        let obstacles = windows.filter(\.isValid).compactMap { frame -> Rect? in
            let x = max(frame.x, bounds.x), y = max(frame.y, bounds.y)
            let clipped = Rect(x: x, y: y, width: min(frame.maxX, bounds.maxX) - x,
                               height: min(frame.maxY, bounds.maxY) - y)
            return clipped.isValid ? clipped : nil
        }
        // Dropping over an occupied area preserves the user's placement.
        guard !obstacles.contains(where: { cx > $0.x && cx < $0.maxX && cy > $0.y && cy < $0.maxY }) else { return nil }
        let edges = Set([bounds.x, bounds.maxX] + obstacles.flatMap { [$0.x, $0.maxX] }).sorted()
        var best: Rect?
        for left in edges where left < cx {
            for right in edges where right > cx {
                var top = bounds.y, bottom = bounds.maxY
                var blocked = false
                for obstacle in obstacles where obstacle.x < right && obstacle.maxX > left {
                    if obstacle.maxY <= cy { top = max(top, obstacle.maxY) }
                    else if obstacle.y >= cy { bottom = min(bottom, obstacle.y) }
                    else { blocked = true; break }
                }
                guard !blocked else { continue }
                let candidate = Rect(x: left, y: top, width: right - left, height: bottom - top)
                guard candidate.width >= min(160, bounds.width), candidate.height >= min(120, bounds.height) else { continue }
                if let previous = best {
                    let area = candidate.width * candidate.height, previousArea = previous.width * previous.height
                    if area < previousArea { continue }
                    if area == previousArea && candidate.intersectionArea(with: window) <= previous.intersectionArea(with: window) { continue }
                }
                best = candidate
            }
        }
        return best
    }

    /// Only a translation counts: clicks, content drags and manual resizing must not arrange.
    public static func isWindowMove(from initial: Rect, to current: Rect) -> Bool {
        initial.isValid && current.isValid &&
            abs(initial.width - current.width) < 2 && abs(initial.height - current.height) < 2 &&
            hypot(initial.x - current.x, initial.y - current.y) > 3
    }
}
