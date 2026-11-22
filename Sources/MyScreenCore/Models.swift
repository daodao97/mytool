import Foundation

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
    public func intersectionArea(with other: Rect) -> Double {
        max(0, min(maxX, other.maxX) - max(x, other.x)) *
        max(0, min(maxY, other.maxY) - max(y, other.y))
    }
    public func constrained(to bounds: Rect) -> Rect {
        let w = min(width, bounds.width), h = min(height, bounds.height)
        return Rect(x: min(max(x, bounds.x), bounds.maxX - w),
                    y: min(max(y, bounds.y), bounds.maxY - h), width: w, height: h)
    }
    public func projected(from source: Rect, to target: Rect) -> Rect {
        guard isValid, source.isValid, target.isValid else { return target }
        return Rect(x: target.x + (x - source.x) / source.width * target.width,
                    y: target.y + (y - source.y) / source.height * target.height,
                    width: width / source.width * target.width,
                    height: height / source.height * target.height).constrained(to: target)
    }
}

public struct DisplayInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var frame: Rect
    public var workArea: Rect
    public var isBuiltIn: Bool
    public var isMain: Bool
    public init(id: String, name: String, frame: Rect, workArea: Rect, isBuiltIn: Bool, isMain: Bool) {
        self.id = id; self.name = name; self.frame = frame; self.workArea = workArea
        self.isBuiltIn = isBuiltIn; self.isMain = isMain
    }
    public static func topologyKey(_ displays: [DisplayInfo]) -> String {
        displays.map(\.id).sorted().joined(separator: "|")
    }
    public static func containing(_ frame: Rect, in displays: [DisplayInfo]) -> DisplayInfo? {
        guard let mostOverlap = displays.max(by: { $0.frame.intersectionArea(with: frame) < $1.frame.intersectionArea(with: frame) }) else { return nil }
        if mostOverlap.frame.intersectionArea(with: frame) > 0 { return mostOverlap }
        // An off-screen window belongs to its nearest screen, rather than an arbitrary last screen.
        let centerX = frame.x + frame.width / 2, centerY = frame.y + frame.height / 2
        func distance(_ display: DisplayInfo) -> Double {
            let dx = max(display.frame.x - centerX, 0, centerX - display.frame.maxX)
            let dy = max(display.frame.y - centerY, 0, centerY - display.frame.maxY)
            return dx * dx + dy * dy
        }
        return displays.min { distance($0) < distance($1) }
    }
}

public struct WindowRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var bundleID: String
    public var appName: String
    public var title: String
    public var document: String
    public var axIdentifier: String
    public var ordinal: Int
    public var displayID: String
    public var frame: Rect
    public var systemID: String?
    public init(id: String, bundleID: String, appName: String, title: String, document: String = "",
                axIdentifier: String = "", ordinal: Int, displayID: String, frame: Rect, systemID: String? = nil) {
        self.id = id; self.bundleID = bundleID; self.appName = appName; self.title = title
        self.document = document; self.axIdentifier = axIdentifier; self.ordinal = ordinal
        self.displayID = displayID; self.frame = frame
        self.systemID = systemID
    }
}

public struct LayoutProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isAutomatic: Bool
    public var updatedAt: Date
    public var displays: [DisplayInfo]
    public var windows: [WindowRecord]
    public var topologyKey: String { DisplayInfo.topologyKey(displays) }
    public init(id: UUID = UUID(), name: String, isAutomatic: Bool, updatedAt: Date = Date(),
                displays: [DisplayInfo], windows: [WindowRecord]) {
        self.id = id; self.name = name; self.isAutomatic = isAutomatic; self.updatedAt = updatedAt
        self.displays = displays; self.windows = windows
    }
    public func destination(for window: WindowRecord, on connected: [DisplayInfo]) -> Rect? {
        guard let source = displays.first(where: { $0.id == window.displayID }),
              let target = destinationDisplay(for: source, on: connected) else { return nil }
        return window.frame.projected(from: source.workArea, to: target.workArea)
    }

    private func destinationDisplay(for source: DisplayInfo, on connected: [DisplayInfo]) -> DisplayInfo? {
        if let same = connected.first(where: { $0.id == source.id }) { return same }
        // Preserve connected screens first; pair only missing external screens with new ones.
        // Spatial order keeps multi-monitor replacements deterministic across enumeration order.
        if !source.isBuiltIn {
            func ordered(_ screens: [DisplayInfo]) -> [DisplayInfo] {
                screens.sorted {
                    if $0.frame.x != $1.frame.x { return $0.frame.x < $1.frame.x }
                    if $0.frame.y != $1.frame.y { return $0.frame.y < $1.frame.y }
                    return $0.id < $1.id
                }
            }
            let connectedIDs = Set(connected.map(\.id))
            let savedIDs = Set(displays.map(\.id))
            let missing = ordered(displays.filter { !$0.isBuiltIn && !connectedIDs.contains($0.id) })
            let replacements = ordered(connected.filter { !$0.isBuiltIn && !savedIDs.contains($0.id) })
            if let index = missing.firstIndex(where: { $0.id == source.id }), index < replacements.count {
                return replacements[index]
            }
        }
        return connected.first(where: \.isMain) ?? connected.first
    }
}

public enum WindowAction: String, Codable, CaseIterable, Identifiable, Sendable {
    public static let commonLayouts: [WindowAction] = [.left, .right, .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight, .maximize]
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    case maximize, center, nextDisplay, previousDisplay, undo, saveLayout, restoreLayout
    case moveLeft, moveRight, moveUp, moveDown, shrinkWidth, growWidth, shrinkHeight, growHeight
    case expand, shrink, screenLeft, screenRight, screenUp, screenDown, redo, centerCursor
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .left: return "左半屏"
        case .right: return "右半屏"
        case .top: return "上半屏"
        case .bottom: return "下半屏"
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        case .maximize: return "填满可用区域"
        case .center: return "居中"
        case .nextDisplay: return "移到下一块屏幕"
        case .previousDisplay: return "移到上一块屏幕"
        case .undo: return "撤销上次移动"
        case .saveLayout: return "保存当前布局"
        case .restoreLayout: return "恢复当前组合布局"
        case .moveLeft: return "向左微移"
        case .moveRight: return "向右微移"
        case .moveUp: return "向上微移"
        case .moveDown: return "向下微移"
        case .shrinkWidth: return "固定左边 · 向左缩小"
        case .growWidth: return "固定左边 · 向右扩大"
        case .shrinkHeight: return "固定上边 · 向上缩小"
        case .growHeight: return "固定上边 · 向下扩大"
        case .expand: return "向外放大"
        case .shrink: return "向内缩小"
        case .screenLeft: return "移到左侧屏幕"
        case .screenRight: return "移到右侧屏幕"
        case .screenUp: return "移到上方屏幕"
        case .screenDown: return "移到下方屏幕"
        case .redo: return "重做窗口移动"
        case .centerCursor: return "鼠标移到窗口中心"
        }
    }
    public var symbol: String {
        switch self {
        case .left: return "rectangle.lefthalf.inset.filled"
        case .right: return "rectangle.righthalf.inset.filled"
        case .top: return "rectangle.tophalf.inset.filled"
        case .bottom: return "rectangle.bottomhalf.inset.filled"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return "rectangle.split.2x2"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .center: return "dot.scope"
        case .nextDisplay, .previousDisplay: return "display.2"
        case .undo: return "arrow.uturn.backward"
        case .saveLayout: return "square.and.arrow.down"
        case .restoreLayout: return "arrow.clockwise"
        case .moveLeft, .moveRight, .moveUp, .moveDown: return "arrow.up.and.down.and.arrow.left.and.right"
        case .shrinkWidth, .growWidth: return "arrow.left.and.right"
        case .shrinkHeight, .growHeight: return "arrow.up.and.down"
        case .expand, .shrink: return "arrow.up.left.and.arrow.down.right"
        case .screenLeft, .screenRight, .screenUp, .screenDown: return "display.2"
        case .redo: return "arrow.uturn.forward"
        case .centerCursor: return "cursorarrow"
        }
    }
    public var isRepeatable: Bool {
        switch self {
        case .moveLeft, .moveRight, .moveUp, .moveDown, .shrinkWidth, .growWidth, .shrinkHeight, .growHeight, .expand, .shrink: return true
        default: return false
        }
    }
    public func target(in bounds: Rect, current: Rect, grid: Rect? = nil) -> Rect? {
        let halfW = bounds.width / 2, halfH = bounds.height / 2
        let stepW = (grid ?? bounds).width / 30, stepH = (grid ?? bounds).height / 30
        switch self {
        case .left: return Rect(x: bounds.x, y: bounds.y, width: halfW, height: bounds.height)
        case .right: return Rect(x: bounds.x + halfW, y: bounds.y, width: halfW, height: bounds.height)
        case .top: return Rect(x: bounds.x, y: bounds.y, width: bounds.width, height: halfH)
        case .bottom: return Rect(x: bounds.x, y: bounds.y + halfH, width: bounds.width, height: halfH)
        case .topLeft: return Rect(x: bounds.x, y: bounds.y, width: halfW, height: halfH)
        case .topRight: return Rect(x: bounds.x + halfW, y: bounds.y, width: halfW, height: halfH)
        case .bottomLeft: return Rect(x: bounds.x, y: bounds.y + halfH, width: halfW, height: halfH)
        case .bottomRight: return Rect(x: bounds.x + halfW, y: bounds.y + halfH, width: halfW, height: halfH)
        case .maximize: return bounds
        case .center:
            let sized = current.constrained(to: bounds)
            return Rect(x: bounds.x + (bounds.width - sized.width) / 2,
                        y: bounds.y + (bounds.height - sized.height) / 2, width: sized.width, height: sized.height)
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            var moved = current
            if self == .moveLeft { moved.x -= stepW }
            if self == .moveRight { moved.x += stepW }
            if self == .moveUp { moved.y -= stepH }
            if self == .moveDown { moved.y += stepH }
            return moved.constrained(to: bounds)
        case .shrinkWidth, .growWidth, .shrinkHeight, .growHeight:
            var resized = current
            if self == .shrinkWidth { resized.width = max(min(80, current.width), current.width - stepW) }
            if self == .growWidth { resized.width += min(stepW, max(0, bounds.maxX - current.maxX)) }
            if self == .shrinkHeight { resized.height = max(min(60, current.height), current.height - stepH) }
            if self == .growHeight { resized.height += min(stepH, max(0, bounds.maxY - current.maxY)) }
            // Clamp only the moving edge. Constraining the whole rectangle shifts the fixed
            // left/top edge when a growing window reaches the right/bottom of the screen.
            return resized
        case .expand, .shrink:
            let sign = self == .expand ? 1.0 : -1.0
            let width = max(80, current.width + sign * 2 * stepW)
            let height = max(60, current.height + sign * 2 * stepH)
            return Rect(x: current.x + (current.width - width) / 2,
                        y: current.y + (current.height - height) / 2,
                        width: width, height: height).constrained(to: bounds)
        default: return nil
        }
    }
    public func destinationDisplay(from current: DisplayInfo, in displays: [DisplayInfo]) -> DisplayInfo? {
        let cx = current.frame.x + current.frame.width / 2, cy = current.frame.y + current.frame.height / 2
        let candidates = displays.compactMap { display -> (display: DisplayInfo, score: Double)? in
            guard display.id != current.id else { return nil }
            let dx = display.frame.x + display.frame.width / 2 - cx
            let dy = display.frame.y + display.frame.height / 2 - cy
            let forward: Double, sideways: Double
            switch self {
            case .screenLeft: forward = -dx; sideways = abs(dy)
            case .screenRight: forward = dx; sideways = abs(dy)
            case .screenUp: forward = -dy; sideways = abs(dx)
            case .screenDown: forward = dy; sideways = abs(dx)
            default: return nil
            }
            guard forward > 0.5 else { return nil }
            return (display, hypot(dx, dy) + sideways * 2)
        }
        return candidates.min {
            $0.score == $1.score ? $0.display.id < $1.display.id : $0.score < $1.score
        }?.display
    }
}
