import AppKit
import ApplicationServices
import MyScreenCore

final class WindowOperationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct WindowScan {
    var windows: [WindowRecord]
    var isComplete: Bool
}

struct WindowOperationResult {
    var resolvedProfile: LayoutProfile?
    var constrainedFrames: [String: Rect] = [:]
    var moved = 0
    var unchanged = 0
    var limited = 0
    var failed = 0
    var unmatched = 0
    var message: String {
        if moved == 0 && limited == 0 && failed == 0 {
            return unchanged > 0 ? "\(unchanged) 个窗口已在目标位置" : "没有找到可恢复的窗口，请先打开保存布局中的应用和窗口"
        }
        var parts = ["已移动 \(moved) 个窗口"]
        if limited > 0 { parts.append("\(limited) 个窗口受应用尺寸限制") }
        if failed > 0 { parts.append("\(failed) 个窗口无法移动") }
        if unmatched > 0 { parts.append("\(unmatched) 个保存窗口尚未打开或无法匹配") }
        return parts.joined(separator: "，")
    }
}

/// All AX calls run on a serial worker; a slow application cannot block SwiftUI.
final class WindowService {
    private struct LiveWindow { let element: AXUIElement; let pid: pid_t; var record: WindowRecord }
    private struct SystemWindow { let pid: pid_t; let number: UInt32; let frame: Rect; let title: String }
    private struct UndoMove { let element: AXUIElement; let frame: Rect }
    private let queue = DispatchQueue(label: "app.myscreen.accessibility", qos: .userInitiated)
    private var identities: [(element: AXUIElement, id: String, systemID: String?)] = []
    private var history: [[UndoMove]] = []
    private var future: [[UndoMove]] = []
    private let resizeObserver = WindowResizeObserver()
    var onWindowResized: ((AXUIElement) -> Void)? {
        didSet { resizeObserver.onResize = onWindowResized }
    }
    var onEvent: ((String) -> Void)?
    private var linkedResizeCandidates: [LiveWindow] = []
    private var observedResize: (token: WindowOperationToken, session: LinkedResizeSession)?
    private struct ArrangementDrag {
        let token: WindowOperationToken
        let element: AXUIElement
        let frame: Rect
        var obstacles: [Rect]?
        var confirmedMove = false
        var snapAction: WindowAction?
        var snapDisplayID: String?
        var peers: [LiveWindow]?
        var linkedResize: LinkedResizeSession?
    }
    private var arrangementDrag: ArrangementDrag?

    static var isTrusted: Bool { AXIsProcessTrusted() }
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func scan(displays: [DisplayInfo], token: WindowOperationToken? = nil, completion: @escaping (WindowScan) -> Void) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        queue.async {
            let live = self.enumerate(apps: apps, displays: displays, token: token)
            if live.isComplete, self.arrangementDrag?.token.isCancelled != false,
               self.observedResize?.token.isCancelled != false {
                self.linkedResizeCandidates = self.visibleWindows(live.windows)
            }
            let result = WindowScan(windows: live.windows.map(\.record), isComplete: live.isComplete)
            DispatchQueue.main.async {
                if self.onWindowResized != nil { self.resizeObserver.watch(live.windows.map { ($0.pid, $0.element) }) }
                completion(result)
            }
        }
    }
    func beginArrangementDrag(at point: CGPoint, linkedResize: Bool, displays: [DisplayInfo], token: WindowOperationToken) {
        let apps = linkedResize ? arrangementApps() : []
        // Capture WindowServer geometry at mouse-down, before a slow AX scan can
        // observe a divider that has already moved and miss the original pair.
        let initialWindows = linkedResize ? systemWindows(onScreenOnly: true) : []
        queue.async {
            self.arrangementDrag = nil
            guard !token.isCancelled, Self.isTrusted else { return }
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.2)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                  var element = hit else { return }
            // A hit may be a title bar, tab or content element. Resolve its owning window.
            for _ in 0..<12 {
                AXUIElementSetMessagingTimeout(element, 0.2)
                if self.attribute(element, kAXRoleAttribute) as? String == kAXWindowRole { break }
                let parent = self.attribute(element, kAXWindowAttribute) ?? self.attribute(element, kAXParentAttribute)
                guard let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return }
                element = parent as! AXUIElement
            }
            var pid: pid_t = 0
            guard !token.isCancelled, self.isEligible(element),
                  AXUIElementGetPid(element, &pid) == .success,
                  pid != ProcessInfo.processInfo.processIdentifier, let frame = self.frame(element) else { return }
            var drag = ArrangementDrag(token: token, element: element, frame: frame)
            if linkedResize, let screen = DisplayInfo.containing(frame, in: displays),
               initialWindows.contains(where: { min(abs(point.x - $0.frame.x), abs(point.x - $0.frame.maxX)) <= 12 && $0.frame.intersectionArea(with: screen.workArea) > 0 }),
               point.y > screen.workArea.y + 16, point.y < screen.workArea.maxY - 16 {
                let scan = self.enumerate(apps: apps, displays: displays, token: token)
                let windows = scan.windows.compactMap { window -> LiveWindow? in
                    let candidates = initialWindows.filter {
                        $0.pid == window.pid && (window.record.systemID?.hasSuffix(":\($0.number)") == true || Self.sameFrame($0.frame, window.record.frame))
                    }
                    guard candidates.count == 1, let initial = candidates.first,
                          DisplayInfo.containing(initial.frame, in: displays)?.id == screen.id else { return nil }
                    var original = window
                    original.record.frame = initial.frame
                    return original
                }
                if scan.isComplete, windows.contains(where: { CFEqual($0.element, element) }),
                   let pair = LinkedWindowPair(windows: windows.map(\.record), in: screen.workArea, atX: point.x, y: point.y) {
                    drag.linkedResize = self.linkedResizeSession(pair: pair, windows: windows, token: token)
                    self.emit("联动缩放：鼠标边缘手势识别成功")
                }
            }
            self.arrangementDrag = drag
        }
    }

    private func linkedResizeSession(pair: LinkedWindowPair, windows: [LiveWindow], token: WindowOperationToken) -> LinkedResizeSession {
        LinkedResizeSession(pair: pair, read: { id in
            guard let window = windows.first(where: { $0.record.id == id }) else { return nil }
            // Read the visible native geometry without waiting for an application's
            // AX event loop, which can stall while a resize is in progress.
            if let identity = window.record.systemID {
                return self.systemWindows(onScreenOnly: true).first {
                    $0.pid == window.pid && identity.hasSuffix(":\($0.number)")
                }?.frame
            }
            return self.isEligible(window.element) ? self.frame(window.element) : nil
        }, write: { id, target in
            guard !token.isCancelled, let window = windows.first(where: { $0.record.id == id }) else { return -1 }
            return self.setFrame(window.element, to: target)
        }, recordUndo: {
            self.pushUndo(windows.map { UndoMove(element: $0.element, frame: $0.record.frame) })
        })
    }

    func observedWindowResize(_ element: AXUIElement, displays: [DisplayInfo], token: WindowOperationToken,
                              completion: @escaping (Bool) -> Void) {
        queue.async {
            func finish(_ linked: Bool) { DispatchQueue.main.async { completion(linked) } }
            guard !token.isCancelled, !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) else { finish(false); return }
            var resize = self.arrangementDrag.flatMap { $0.token === token ? $0.linkedResize : nil } ??
                self.observedResize.flatMap { $0.token === token ? $0.session : nil }
            if resize == nil {
                guard let original = self.linkedResizeCandidates.first(where: { CFEqual($0.element, element) }),
                      let screen = displays.first(where: { $0.id == original.record.displayID }) else { finish(false); return }
                let windows = self.linkedResizeCandidates.filter { $0.record.displayID == screen.id }
                let ordered = windows.sorted { $0.record.frame.x < $1.record.frame.x }
                guard let first = ordered.first,
                      let pair = LinkedWindowPair(windows: windows.map(\.record), in: screen.workArea,
                          atX: first.record.frame.maxX, y: screen.workArea.y + screen.workArea.height / 2),
                      let current = self.frame(element), pair.divider(for: original.record.id, current: current) != nil,
                      abs(current.width - original.record.frame.width) > 1 else { finish(false); return }
                let session = self.linkedResizeSession(pair: pair, windows: windows, token: token)
                if self.arrangementDrag?.token === token { self.arrangementDrag?.linkedResize = session }
                else { self.observedResize = (token, session) }
                resize = session
                self.emit("联动缩放：通过窗口尺寸通知识别并排窗口")
            }
            guard let resize else { finish(false); return }
            resize.update(token: token)
            finish(resize.activeID != nil)
        }
    }

    func finishObservedResize(token: WindowOperationToken, completion: @escaping (String?) -> Void) {
        queue.async {
            guard let observed = self.observedResize, observed.token === token else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            self.observedResize = nil
            self.finishLinkedResize(observed.session, token: token, completion: completion)
        }
    }

    private func finishLinkedResize(_ resize: LinkedResizeSession, token: WindowOperationToken, attempt: Int = 0,
                                    completion: @escaping (String?) -> Void) {
        guard !token.isCancelled else { DispatchQueue.main.async { completion(nil) }; return }
        resize.update(token: token, settled: true)
        // Application replies and WindowServer geometry need not arrive together.
        if attempt < 3 {
            queue.asyncAfter(deadline: .now() + 0.12) {
                self.finishLinkedResize(resize, token: token, attempt: attempt + 1, completion: completion)
            }
        } else {
            if resize.needsRetry {
                emit("联动缩放复核未通过：\(resize.diagnostic ?? "窗口暂不可访问")")
                resize.abandon(token: token)
            }
            let ids = Set(resize.pair.placements.map(\.windowID))
            for index in linkedResizeCandidates.indices where ids.contains(linkedResizeCandidates[index].record.id) {
                if let current = frame(linkedResizeCandidates[index].element) { linkedResizeCandidates[index].record.frame = current }
            }
            DispatchQueue.main.async { completion(resize.message) }
        }
    }

    private func emit(_ message: String) {
        DispatchQueue.main.async { self.onEvent?(message) }
    }

    func previewArrangementDrag(at point: CGPoint, arrange: Bool, reflow: Bool, displays: [DisplayInfo], token: WindowOperationToken,
                                completion: @escaping (ArrangementPreview?) -> Void) {
        let apps = arrangementApps()
        queue.async {
            var preview: ArrangementPreview?
            guard !token.isCancelled, CGEventSource.buttonState(.combinedSessionState, button: .left),
                  !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            if let drag = self.arrangementDrag, drag.token === token, let resize = drag.linkedResize {
                resize.update(token: token)
                DispatchQueue.main.async { completion(nil) }; return
            }
            if arrange, var drag = self.arrangementDrag, drag.token === token, !token.isCancelled,
               let current = self.frame(drag.element), AutomaticArrangement.isWindowMove(from: drag.frame, to: current) {
                drag.confirmedMove = true
                preview = self.arrangementPreview(drag: &drag, current: current, point: point,
                                                  displays: displays, apps: apps, refreshObstacles: false, reflow: reflow)
                self.arrangementDrag = drag
            }
            let result = preview
            DispatchQueue.main.async { completion(result) }
        }
    }

    func finishArrangementDrag(at point: CGPoint, selection: ArrangementSelection?, arrange: Bool, reflow: Bool, displays: [DisplayInfo], token: WindowOperationToken, completion: @escaping (String?) -> Void) {
        let apps = arrangementApps()
        queue.async {
            func finish(_ message: String? = nil) { DispatchQueue.main.async { completion(message) } }
            if let observed = self.observedResize, observed.token === token {
                self.observedResize = nil
                self.finishLinkedResize(observed.session, token: token, completion: completion)
                return
            }
            guard var drag = self.arrangementDrag, drag.token === token else { finish(); return }
            self.arrangementDrag = nil
            guard !token.isCancelled, !CGEventSource.buttonState(.combinedSessionState, button: .left) else { finish(); return }
            if let resize = drag.linkedResize {
                self.finishLinkedResize(resize, token: token, completion: completion)
                return
            }
            guard arrange else { finish(); return }
            guard let current = self.frame(drag.element), self.isEligible(drag.element) else {
                finish(selection == nil ? nil : "吸附未执行：目标窗口暂不可访问"); return
            }
            // A displayed preview has already confirmed a real window move. Do not
            // discard it because native tiling changed the size while releasing.
            guard drag.confirmedMove || AutomaticArrangement.isWindowMove(from: drag.frame, to: current) else { finish(); return }
            let accepted = selection.flatMap { $0.applies(at: point, displays: displays) ? $0.preview : nil }
            guard let preview = accepted ?? self.arrangementPreview(drag: &drag, current: current, point: point,
                displays: displays, apps: apps, refreshObstacles: true, reflow: reflow) else { finish(); return }
            if !preview.placements.isEmpty {
                self.applyPlacements(preview.placements, to: drag.peers ?? [], token: token) { message in finish(message) }
                return
            }
            let success = preview.action.map { "已吸附到\($0.title)" } ?? "已自动排版，窗口填充所在空闲区域"
            let element = drag.element
            ArrangementDropApplier(queue: self.queue).apply(target: preview.frame, token: token,
                isDragging: { CGEventSource.buttonState(.combinedSessionState, button: .left) },
                readFrame: { self.frame(element) }, setFrame: { self.setFrame(element, to: $0) },
                recordUndo: {
                    if !Self.sameFrame(current, preview.frame) { self.pushUndo([UndoMove(element: element, frame: current)]) }
                }) { result in
                    switch result {
                    case .applied: finish(success)
                    case .limited: finish("已自动排版，窗口尺寸受应用限制")
                    case .failed: finish("吸附未完成：应用或系统未保留目标位置")
                    case .cancelled: finish()
                    }
                }
        }
    }

    private func arrangementApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    private func systemWindows(onScreenOnly: Bool) -> [SystemWindow] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return SystemWindow(pid: pid, number: number, frame: Rect(rect), title: entry[kCGWindowName as String] as? String ?? "")
        }
    }

    private func arrangementPreview(drag: inout ArrangementDrag, current: Rect, point: CGPoint,
                                    displays: [DisplayInfo], apps: [NSRunningApplication], refreshObstacles: Bool, reflow: Bool) -> ArrangementPreview? {
        guard !drag.token.isCancelled else { return nil }
        let pointerScreen = displays.first {
            point.x >= $0.frame.x && point.x < $0.frame.maxX && point.y >= $0.frame.y && point.y < $0.frame.maxY
        }
        let previous = pointerScreen?.id == drag.snapDisplayID ? drag.snapAction : nil
        if let screen = pointerScreen,
           let action = AutomaticArrangement.snapAction(atX: point.x, y: point.y, on: screen, previous: previous),
           let target = action.target(in: screen.workArea, current: current) {
            drag.snapAction = action; drag.snapDisplayID = screen.id
            if reflow, action != .maximize {
                return tilingPreview(drag: &drag, current: current, screen: screen, anchor: target, action: action,
                                     displays: displays, apps: apps, refresh: refreshObstacles)
            }
            return ArrangementPreview(frame: target, action: action)
        }
        drag.snapAction = nil; drag.snapDisplayID = nil
        guard let screen = DisplayInfo.containing(current, in: displays) else { return nil }
        if reflow {
            return tilingPreview(drag: &drag, current: current, screen: screen, anchor: nil, action: nil,
                                 displays: displays, apps: apps, refresh: refreshObstacles)
        }
        if refreshObstacles || drag.obstacles == nil {
            let scan = enumerate(apps: apps, displays: displays, token: drag.token)
            guard scan.isComplete, scan.windows.contains(where: { CFEqual($0.element, drag.element) }) else { return nil }
            // Only ordinary windows on the current Space occupy its free area.
            let visible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { entry -> (pid_t, Rect)? in
                guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
                return (pid, Rect(frame))
            }
            drag.obstacles = scan.windows.filter { window in
                !CFEqual(window.element, drag.element) && visible.contains { $0.0 == window.pid && Self.sameFrame($0.1, window.record.frame) }
            }.map(\.record.frame)
        }
        guard let target = AutomaticArrangement.target(for: current, in: screen.workArea, avoiding: drag.obstacles ?? []),
              !Self.sameFrame(current, target), !drag.token.isCancelled else { return nil }
        return ArrangementPreview(frame: target, action: nil)
    }

    private func visibleWindows(_ windows: [LiveWindow]) -> [LiveWindow] {
        let metadata = systemWindows(onScreenOnly: true)
        return windows.filter { window in metadata.contains { $0.pid == window.pid && Self.sameFrame($0.frame, window.record.frame) } }
    }

    private func tilingPreview(drag: inout ArrangementDrag, current: Rect, screen: DisplayInfo, anchor: Rect?, action: WindowAction?,
                               displays: [DisplayInfo], apps: [NSRunningApplication], refresh: Bool) -> ArrangementPreview? {
        if drag.peers == nil || refresh {
            let scan = enumerate(apps: apps, displays: displays, token: drag.token)
            guard scan.isComplete else { return nil }
            let visible = visibleWindows(scan.windows)
            guard let moving = scan.windows.first(where: { CFEqual($0.element, drag.element) }) else { return nil }
            drag.peers = visible.filter { !CFEqual($0.element, drag.element) } + [moving]
        }
        guard let peers = drag.peers, var moving = peers.first(where: { CFEqual($0.element, drag.element) })?.record else { return nil }
        moving.frame = current
        let records = peers.filter { !CFEqual($0.element, drag.element) && $0.record.displayID == screen.id }.map(\.record) + [moving]
        let plan = WindowTiling.plan(windows: records, in: screen.workArea, movingWindowID: moving.id, anchor: anchor)
        guard let target = plan.first(where: { $0.windowID == moving.id }), !drag.token.isCancelled else { return nil }
        return ArrangementPreview(frame: target.frame, action: action, placements: plan,
                                  label: action == nil ? "智能平铺 · \(plan.count) 个窗口" : nil)
    }

    func tileWindows(_ layout: WindowTileLayout, displayID: String?, pid: pid_t?, displays: [DisplayInfo], token: WindowOperationToken,
                     completion: @escaping (String) -> Void) {
        let apps = arrangementApps()
        queue.async {
            guard !token.isCancelled else { DispatchQueue.main.async { completion("排布已取消") }; return }
            var focusedFrame: Rect?
            if let pid {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                if let value = self.attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                    focusedFrame = self.frame(value as! AXUIElement)
                }
            }
            guard let screen = displays.first(where: { $0.id == displayID }) ??
                focusedFrame.flatMap({ DisplayInfo.containing($0, in: displays) }) ?? displays.first(where: \.isMain) ?? displays.first else {
                DispatchQueue.main.async { completion("没有可用的显示器") }; return
            }
            let scan = self.enumerate(apps: apps, displays: displays, token: token)
            guard scan.isComplete, !token.isCancelled else {
                DispatchQueue.main.async { completion("窗口扫描未完成，已保留原布局，请稍后重试") }; return
            }
            let windows = self.visibleWindows(scan.windows).filter { $0.record.displayID == screen.id }
            let plan = WindowTiling.plan(windows: windows.map(\.record), in: screen.workArea, layout: layout)
            self.applyPlacements(plan, to: windows, token: token) { message in
                DispatchQueue.main.async { completion("\(screen.name) · \(layout.title)：\(message)") }
            }
        }
    }

    /// All moves in a tiling plan share one undo entry and the drop verification path.
    private func applyPlacements(_ placements: [WindowPlacement], to windows: [LiveWindow], token: WindowOperationToken,
                                 completion: @escaping (String) -> Void) {
        var result = WindowOperationResult()
        var undo: [UndoMove] = []
        var pending = 0
        var started = false
        func finishIfReady() {
            guard started, pending == 0 else { return }
            self.pushUndo(undo)
            completion(result.message)
        }
        for placement in placements {
            guard !token.isCancelled else { break }
            guard let window = windows.first(where: { $0.record.id == placement.windowID }),
                  isEligible(window.element), let current = frame(window.element) else { result.failed += 1; continue }
            if Self.sameFrame(current, placement.frame) { result.unchanged += 1; continue }
            pending += 1
            ArrangementDropApplier(queue: queue).apply(target: placement.frame, token: token,
                isDragging: { CGEventSource.buttonState(.combinedSessionState, button: .left) },
                readFrame: { self.frame(window.element) }, setFrame: { self.setFrame(window.element, to: $0) },
                recordUndo: { undo.append(UndoMove(element: window.element, frame: current)) }) { outcome in
                    switch outcome {
                    case .applied: result.moved += 1
                    case .limited: result.limited += 1
                    case .failed: result.failed += 1
                    case .cancelled: break
                    }
                    pending -= 1
                    finishIfReady()
                }
        }
        started = true
        if placements.isEmpty { completion("当前屏幕没有可排布的普通窗口") }
        else { finishIfReady() }
    }
    func restore(_ profile: LayoutProfile, displays: [DisplayInfo], token: WindowOperationToken,
                 recordUndo: Bool = true, completion: @escaping (WindowOperationResult) -> Void) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        queue.async {
            let live = self.enumerate(apps: apps, displays: displays, token: token).windows
            let matches = WindowMatcher.match(saved: profile.windows, live: live.map(\.record), recoveringLayout: true, displays: displays)
            var result = WindowOperationResult(); result.unmatched = profile.windows.count - matches.count
            var resolved = profile
            for pair in matches {
                resolved.windows[pair.saved].id = live[pair.live].record.id
                resolved.windows[pair.saved].systemID = live[pair.live].record.systemID
            }
            result.resolvedProfile = resolved
            var undo: [UndoMove] = []
            for pair in matches {
                guard !token.isCancelled else { break }
                let window = live[pair.live]
                guard let target = profile.destination(for: profile.windows[pair.saved], on: displays) else { continue }
                if Self.sameFrame(window.record.frame, target) { result.unchanged += 1; continue }
                let outcome = self.setFrame(window.element, to: target)
                if outcome == 1, let actual = self.frame(window.element) {
                    result.constrainedFrames[resolved.windows[pair.saved].id] = actual
                }
                if outcome >= 0 { undo.append(UndoMove(element: window.element, frame: window.record.frame)) }
                self.count(outcome, into: &result)
            }
            if recordUndo { self.pushUndo(undo) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func perform(_ action: WindowAction, pid: pid_t?, windowID: String? = nil, displays: [DisplayInfo], token: WindowOperationToken, completion: @escaping (String) -> Void) {
        queue.async {
            guard !token.isCancelled else { DispatchQueue.main.async { completion("屏幕配置已变化，操作已取消") }; return }
            if action == .undo || action == .redo {
                let moves = action == .undo ? self.history.popLast() : self.future.popLast()
                guard let moves else {
                    DispatchQueue.main.async { completion(action == .undo ? "还没有可以撤销的窗口移动" : "还没有可以重做的窗口移动") }; return
                }
                var result = WindowOperationResult()
                var inverse: [UndoMove] = []
                for move in moves {
                    guard !token.isCancelled else { break }
                    guard let current = self.frame(move.element) else { result.failed += 1; continue }
                    // Monitor unplugged since this undo? Keep the window reachable on an active display.
                    let display = DisplayInfo.containing(move.frame, in: displays)
                    let target = display.map { move.frame.constrained(to: $0.workArea) } ?? move.frame
                    let outcome = self.setFrame(move.element, to: target)
                    self.count(outcome, into: &result)
                    if outcome >= 0 { inverse.append(UndoMove(element: move.element, frame: current)) }
                }
                if !inverse.isEmpty {
                    if action == .undo { self.future.append(inverse) }
                    else { self.history.append(inverse) }
                }
                DispatchQueue.main.async { completion((action == .undo ? "撤销：" : "重做：") + result.message) }; return
            }
            var selectedWindow: AXUIElement?
            if let windowID {
                selectedWindow = self.identities.first(where: { $0.id == windowID })?.element
            } else if let pid {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.25)
                if let value = self.attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                    selectedWindow = (value as! AXUIElement)
                }
            }
            guard let window = selectedWindow,
                  self.isEligible(window), let current = self.frame(window),
                  let screen = DisplayInfo.containing(current, in: displays) else {
                DispatchQueue.main.async { completion("无法控制该窗口：请选择未最小化、非全屏的普通窗口") }; return
            }
            var target: Rect?
            if action == .centerCursor {
                let status = CGWarpMouseCursorPosition(CGPoint(x: current.x + current.width / 2, y: current.y + current.height / 2))
                DispatchQueue.main.async { completion(status == .success ? "鼠标已移到窗口中心" : "无法移动鼠标") }
                return
            }
            if action == .nextDisplay || action == .previousDisplay {
                guard displays.count > 1, let index = displays.firstIndex(where: { $0.id == screen.id }) else {
                    DispatchQueue.main.async { completion("当前只有一块显示器") }; return
                }
                let offset = action == .nextDisplay ? 1 : displays.count - 1
                let destination = displays[(index + offset) % displays.count]
                target = current.projected(from: screen.workArea, to: destination.workArea)
            } else if [.screenLeft, .screenRight, .screenUp, .screenDown].contains(action) {
                guard let destination = action.destinationDisplay(from: screen, in: displays) else {
                    DispatchQueue.main.async { completion("该方向没有可用的显示器") }; return
                }
                target = current.projected(from: screen.workArea, to: destination.workArea)
            } else { target = action.target(in: screen.workArea, current: current, grid: screen.frame) }
            guard let target else { DispatchQueue.main.async { completion("不支持的窗口操作") }; return }
            guard !token.isCancelled else { DispatchQueue.main.async { completion("屏幕配置已变化，操作已取消") }; return }
            guard target != current else {
                DispatchQueue.main.async { completion("窗口已在目标位置或达到尺寸边界") }; return
            }
            let result = self.setFrame(window, to: target)
            if result >= 0 { self.pushUndo([UndoMove(element: window, frame: current)]) }
            let message = result == 0 ? "已\(action.title)" : (result == 1 ? "已移动，窗口尺寸受应用限制" : "应用拒绝移动窗口，请检查辅助功能权限")
            DispatchQueue.main.async { completion(message) }
        }
    }
    private func enumerate(apps: [NSRunningApplication], displays: [DisplayInfo], token: WindowOperationToken? = nil) -> (windows: [LiveWindow], isComplete: Bool) {
        guard AXIsProcessTrusted() else { return ([], false) }
        var result: [LiveWindow] = []
        var complete = true
        // Bucket retained identities by CFHash so each window lookup is O(1) rather than a
        // CFEqual sweep over up to 1024 entries. Indices stay ascending to keep first-match order.
        var identityBuckets: [CFHashCode: [Int]] = [:]
        for (index, entry) in identities.enumerated() { identityBuckets[CFHash(entry.element), default: []].append(index) }
        for running in apps {
            if token?.isCancelled == true { return (result, false) }
            guard let bundleID = running.bundleIdentifier else { continue }
            let app = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.2)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            if status == .cannotComplete || status == .apiDisabled { complete = false }
            guard status == .success, let windows = value as? [AXUIElement] else { continue }
            for (ordinal, window) in windows.enumerated() {
                if token?.isCancelled == true { return (result, false) }
                AXUIElementSetMessagingTimeout(window, 0.2)
                guard isEligible(window), let frame = frame(window), frame.isValid,
                      let screen = DisplayInfo.containing(frame, in: displays) else { continue }
                let previous = identityBuckets[CFHash(window)]?.lazy.map { self.identities[$0] }
                    .first(where: { CFEqual($0.element, window) })
                let id = previous?.id ?? UUID().uuidString
                result.append(LiveWindow(element: window, pid: running.processIdentifier, record: WindowRecord(
                    id: id, bundleID: bundleID, appName: running.localizedName ?? bundleID,
                    title: attribute(window, kAXTitleAttribute) as? String ?? "",
                    document: attribute(window, kAXDocumentAttribute) as? String ?? "",
                    axIdentifier: attribute(window, kAXIdentifierAttribute) as? String ?? "",
                    ordinal: ordinal, displayID: screen.id, frame: frame, systemID: previous?.systemID)))
            }
        }
        // Public WindowServer metadata supplies a window number that survives MyScreen
        // restarting and browser tab/title changes. No image capture is performed.
        let systemByPID = Dictionary(grouping: systemWindows(onScreenOnly: false), by: \.pid)
        // Frames and titles are not modified below, so grouping a snapshot is equivalent.
        let liveByPID = Dictionary(grouping: result, by: \.pid)
        var launchDates: [pid_t: Date?] = [:]
        for app in apps where launchDates[app.processIdentifier] == nil { launchDates[app.processIdentifier] = app.launchDate }
        for index in result.indices {
            let item = result[index]
            var candidates = (systemByPID[item.pid] ?? []).filter { Self.sameFrame($0.frame, item.record.frame) }
            let sameAXBounds = (liveByPID[item.pid] ?? []).filter { Self.sameFrame($0.record.frame, item.record.frame) }
            if candidates.count != 1 || sameAXBounds.count != 1 {
                candidates = candidates.filter { !$0.title.isEmpty && $0.title == item.record.title }
                guard sameAXBounds.filter({ $0.record.title == item.record.title }).count == 1 else { continue }
            }
            guard candidates.count == 1, let system = candidates.first,
                  let launched = launchDates[item.pid] ?? nil else { continue }
            let identity = "\(item.pid):\(launched.timeIntervalSince1970):\(system.number)"
            result[index].record.systemID = identity
            result[index].record.id = "system:\(identity)"
        }
        let nextIdentities = result.map { (element: $0.element, id: $0.record.id, systemID: $0.record.systemID) }
        // An application's AX window list can be temporarily empty during display changes.
        // Retain recent identities so a later title change does not break the reconnect match.
        let nextIDs = Set(nextIdentities.map(\.id))
        let retained = identities.filter { !nextIDs.contains($0.id) }
        identities = Array((nextIdentities + retained).prefix(1024))
        return (result, complete)
    }
    private static func sameFrame(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) < 2 && abs(a.y - b.y) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func isEligible(_ element: AXUIElement) -> Bool {
        guard attribute(element, kAXRoleAttribute) as? String == kAXWindowRole,
              attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              attribute(element, kAXMinimizedAttribute) as? Bool != true,
              attribute(element, "AXFullScreen") as? Bool != true else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
    }
    private func frame(_ element: AXUIElement) -> Rect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return Rect(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }
    /// 0 = exact; 1 = application constrained; -1 = rejected. Read back actual bounds.
    private func setFrame(_ window: AXUIElement, to target: Rect) -> Int {
        guard AXIsProcessTrusted(), target.isValid, isEligible(window) else { return -1 }
        // Chromium can animate or defer AX frame writes in enhanced UI mode.
        // Scope this workaround to the adjustment and preserve assistive technology.
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let canSuspendEnhancedUI = !NSWorkspace.shared.isVoiceOverEnabled && !NSWorkspace.shared.isSwitchControlEnabled
        let enhanced = canSuspendEnhancedUI && attribute(app, "AXEnhancedUserInterface") as? Bool == true
        let suspended = enhanced && AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) == .success
        defer { if suspended { _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        var dimensions = CGSize(width: target.width, height: target.height)
        var position = CGPoint(x: target.x, y: target.y)
        guard let sizeValue = AXValueCreate(.cgSize, &dimensions), let pointValue = AXValueCreate(.cgPoint, &position) else { return -1 }
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        guard positionResult == .success, let actual = frame(window) else { return -1 }
        let exact = abs(actual.x - target.x) < 3 && abs(actual.y - target.y) < 3 &&
            abs(actual.width - target.width) < 3 && abs(actual.height - target.height) < 3
        if !exact { emit("窗口调整受限：目标 \(target)，实际 \(actual)，位置响应 \(positionResult.rawValue)，增强界面 \(enhanced)") }
        return exact ? 0 : 1
    }
    private func pushUndo(_ moves: [UndoMove]) {
        guard !moves.isEmpty else { return }
        future.removeAll()
        history.append(moves)
        if history.count > 20 { history.removeFirst() }
    }
    private func count(_ outcome: Int, into result: inout WindowOperationResult) {
        if outcome == 0 { result.moved += 1 }
        else if outcome == 1 { result.limited += 1 }
        else { result.failed += 1 }
    }
}
