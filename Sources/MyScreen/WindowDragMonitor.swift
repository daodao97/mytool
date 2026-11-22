import AppKit

/// Uses the existing Accessibility permission; modifier events carry no typed text.
@MainActor
final class WindowDragMonitor {
    struct InputState {
        var leftButtonDown: Bool
        var point: CGPoint?
        var optionHeld: Bool
    }
    var onBegin: ((CGPoint) -> Void)?
    var onChange: ((CGPoint, Bool) -> Void)?
    var onEnd: ((Bool, CGPoint?) -> Void)?
    var onEvent: ((String) -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var isDragging = false
    private var isTracking = false
    private var lastPoint: CGPoint?
    private var startPoint: CGPoint?
    private var releaseTimer: Timer?
    private let readInput: () -> InputState

    init(readInput: @escaping () -> InputState = {
        InputState(leftButtonDown: CGEventSource.buttonState(.combinedSessionState, button: .left),
                   point: CGEvent(source: nil)?.location,
                   optionHeld: CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate))
    }) { self.readInput = readInput }

    func start() {
        guard eventTap == nil, globalMonitor == nil else { return }
        // WindowServer handles native resize borders before AppKit's global
        // monitors see the mouse-down. A listen-only tap observes that gesture
        // without intercepting it or inspecting any keyboard input.
        let eventMask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: eventMask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<WindowDragMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if let native = NSEvent(cgEvent: event) { monitor.handle(native) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) {
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            eventSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventSource = nil; eventTap = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        end(shouldApply: false, point: nil)
    }

    /// WindowServer can consume mouse-up during a native title-bar drag. Read the
    /// physical button state as well, and deliver exactly one end for each gesture.
    func poll() {
        guard isTracking else { return }
        let input = readInput()
        if let point = input.point { lastPoint = point }
        if input.leftButtonDown, let point = lastPoint, let startPoint,
           hypot(point.x - startPoint.x, point.y - startPoint.y) > 2 { isDragging = true }
        if !input.leftButtonDown {
            if isDragging { onEvent?("通过物理按键状态确认拖动结束") }
            end(shouldApply: isDragging && !input.optionHeld, point: lastPoint)
        } else if isDragging, let point = lastPoint {
            onChange?(point, input.optionHeld)
        }
    }

    private func end(shouldApply: Bool, point: CGPoint?) {
        guard isTracking else { return }
        isTracking = false
        isDragging = false
        releaseTimer?.invalidate(); releaseTimer = nil
        let finalPoint = point ?? lastPoint
        lastPoint = nil
        startPoint = nil
        onEnd?(shouldApply, finalPoint)
    }

    func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            isDragging = false
            isTracking = true
            // CGEvent coordinates use the same top-left origin as AX window frames.
            lastPoint = event.cgEvent?.location ?? readInput().point
            startPoint = lastPoint
            if let point = lastPoint { onBegin?(point) }
            releaseTimer?.invalidate()
            let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            releaseTimer = timer
        case .leftMouseDragged:
            guard isTracking else { return }
            isDragging = true
            lastPoint = event.cgEvent?.location ?? lastPoint
            if let point = lastPoint { onChange?(point, event.modifierFlags.contains(.option)) }
        case .flagsChanged:
            if isDragging, let point = event.cgEvent?.location { onChange?(point, event.modifierFlags.contains(.option)) }
        case .leftMouseUp:
            end(shouldApply: isDragging && !event.modifierFlags.contains(.option), point: event.cgEvent?.location)
        default: break
        }
    }
}
