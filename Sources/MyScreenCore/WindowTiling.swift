import Foundation

public enum WindowTileLayout: String, CaseIterable, Identifiable, Sendable {
    case automatic, columns, rows
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "智能网格"
        case .columns: return "左右分列"
        case .rows: return "上下分行"
        }
    }
}

public struct WindowPlacement: Equatable, Sendable {
    public let windowID: String
    public let frame: Rect
    public init(windowID: String, frame: Rect) { self.windowID = windowID; self.frame = frame }
}

public enum WindowTiling {
    public static func frames(count: Int, in bounds: Rect, layout: WindowTileLayout = .automatic) -> [Rect] {
        guard count > 0, bounds.isValid else { return [] }
        if layout == .columns { return grid(count: count, rows: 1, bounds: bounds) }
        if layout == .rows { return grid(count: count, rows: count, bounds: bounds) }
        // Evaluate complete rows, allowing a short final row to use its full width.
        // A landscape window is preferable to a tall sliver on wide displays.
        let rows = (1...count).min { a, b in
            func score(_ rows: Int) -> Double {
                let base = count / rows, extra = count % rows
                return (0..<rows).reduce(0) { total, row in
                    let columns = base + (row < extra ? 1 : 0)
                    let aspect = (bounds.width / Double(columns)) / (bounds.height / Double(rows))
                    return total + Double(columns) * pow(log(aspect / 1.4), 2)
                }
            }
            let sa = score(a), sb = score(b)
            return abs(sa - sb) < 0.000001 ? a < b : sa < sb
        } ?? 1
        return grid(count: count, rows: rows, bounds: bounds)
    }

    /// Preserve an explicitly snapped window, then distribute its neighbors among
    /// disjoint rectangles in the remaining work area. A full-screen anchor leaves none.
    public static func frames(count: Int, in bounds: Rect, reserving anchor: Rect) -> [Rect] {
        guard count > 0, bounds.isValid, anchor.isValid,
              anchor.x >= bounds.x, anchor.y >= bounds.y, anchor.maxX <= bounds.maxX, anchor.maxY <= bounds.maxY else { return [] }
        var spaces = [
            Rect(x: bounds.x, y: bounds.y, width: anchor.x - bounds.x, height: bounds.height),
            Rect(x: anchor.maxX, y: bounds.y, width: bounds.maxX - anchor.maxX, height: bounds.height),
            Rect(x: anchor.x, y: bounds.y, width: anchor.width, height: anchor.y - bounds.y),
            Rect(x: anchor.x, y: anchor.maxY, width: anchor.width, height: bounds.maxY - anchor.maxY)
        ].filter(\.isValid).sorted {
            let a = $0.width * $0.height, b = $1.width * $1.height
            if a != b { return a > b }
            return $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y
        }
        spaces = Array(spaces.prefix(count))
        guard !spaces.isEmpty else { return [] }
        var counts = Array(repeating: 1, count: spaces.count)
        for _ in spaces.count..<count {
            let index = spaces.indices.max {
                spaces[$0].width * spaces[$0].height / Double(counts[$0]) <
                spaces[$1].width * spaces[$1].height / Double(counts[$1])
            } ?? 0
            counts[index] += 1
        }
        return spaces.indices.flatMap { frames(count: counts[$0], in: spaces[$0]) }.sorted {
            $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y
        }
    }

    public static func plan(windows: [WindowRecord], in bounds: Rect, layout: WindowTileLayout = .automatic,
                            movingWindowID: String? = nil, anchor: Rect? = nil) -> [WindowPlacement] {
        guard bounds.isValid else { return [] }
        if let anchor {
            guard anchor.isValid, anchor.x >= bounds.x, anchor.y >= bounds.y,
                  anchor.maxX <= bounds.maxX, anchor.maxY <= bounds.maxY else { return [] }
        }
        let ordered = windows.filter { $0.frame.isValid }.sorted {
            if $0.frame.y != $1.frame.y { return $0.frame.y < $1.frame.y }
            if $0.frame.x != $1.frame.x { return $0.frame.x < $1.frame.x }
            return $0.id < $1.id
        }
        guard let moving = ordered.first(where: { $0.id == movingWindowID }) else {
            return zip(ordered, frames(count: ordered.count, in: bounds, layout: layout)).map {
                WindowPlacement(windowID: $0.0.id, frame: $0.1)
            }
        }
        let others = ordered.filter { $0.id != moving.id }
        if let anchor {
            let rest = frames(count: others.count, in: bounds, reserving: anchor)
            return [WindowPlacement(windowID: moving.id, frame: anchor)] + zip(others, rest).map {
                WindowPlacement(windowID: $0.0.id, frame: $0.1)
            }
        }
        var slots = frames(count: ordered.count, in: bounds, layout: layout)
        func distance(_ slot: Rect) -> Double {
            pow(slot.x + slot.width / 2 - moving.frame.x - moving.frame.width / 2, 2) +
            pow(slot.y + slot.height / 2 - moving.frame.y - moving.frame.height / 2, 2)
        }
        guard let index = slots.indices.min(by: { distance(slots[$0]) < distance(slots[$1]) }) else { return [] }
        let chosen = slots.remove(at: index)
        return [WindowPlacement(windowID: moving.id, frame: chosen)] + zip(others, slots).map {
            WindowPlacement(windowID: $0.0.id, frame: $0.1)
        }
    }

    private static func grid(count: Int, rows: Int, bounds: Rect) -> [Rect] {
        let base = count / rows, extra = count % rows
        return (0..<rows).flatMap { row -> [Rect] in
            let columns = base + (row < extra ? 1 : 0)
            let y = bounds.y + bounds.height * Double(row) / Double(rows)
            let bottom = bounds.y + bounds.height * Double(row + 1) / Double(rows)
            return (0..<columns).map { column in
                let x = bounds.x + bounds.width * Double(column) / Double(columns)
                let right = bounds.x + bounds.width * Double(column + 1) / Double(columns)
                return Rect(x: x, y: y, width: right - x, height: bottom - y)
            }
        }
    }
}
