import ApplicationServices
import Foundation

/// AX notifications also cover native/synthetic resizing that bypasses mouse monitors.
/// Registration and delivery use the main run loop; AX work stays in WindowService.
final class WindowResizeObserver {
    var onResize: ((AXUIElement) -> Void)?
    private var observers: [pid_t: AXObserver] = [:]
    private var registered: [pid_t: [AXUIElement]] = [:]

    deinit {
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    /// Called after every window scan, so membership checks use CFHash buckets
    /// instead of nested CFEqual sweeps.
    func watch(_ windows: [(pid_t, AXUIElement)]) {
        var live: [pid_t: [AXUIElement]] = [:]
        for (pid, window) in windows { live[pid, default: []].append(window) }
        for pid in Array(observers.keys) where live[pid] == nil {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            registered.removeValue(forKey: pid)
        }
        for (pid, elements) in live {
            if observers[pid] == nil {
                var observer: AXObserver?
                let status = AXObserverCreate(pid, { _, element, _, context in
                    guard let context else { return }
                    let owner = Unmanaged<WindowResizeObserver>.fromOpaque(context).takeUnretainedValue()
                    owner.onResize?(element)
                }, &observer)
                guard status == .success, let observer else { continue }
                observers[pid] = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            guard let observer = observers[pid] else { continue }
            let liveIndex = Self.index(elements)
            var kept: [AXUIElement] = []
            for window in registered[pid] ?? [] {
                if Self.contains(liveIndex, window) { kept.append(window) }
                else { AXObserverRemoveNotification(observer, window, kAXResizedNotification as CFString) }
            }
            var keptIndex = Self.index(kept)
            for window in elements where !Self.contains(keptIndex, window) {
                let status = AXObserverAddNotification(observer, window, kAXResizedNotification as CFString,
                    Unmanaged.passUnretained(self).toOpaque())
                if status == .success || status == .notificationAlreadyRegistered {
                    kept.append(window)
                    keptIndex[CFHash(window), default: []].append(window)
                }
            }
            registered[pid] = kept
        }
    }

    private static func index(_ elements: [AXUIElement]) -> [CFHashCode: [AXUIElement]] {
        var buckets: [CFHashCode: [AXUIElement]] = [:]
        for element in elements { buckets[CFHash(element), default: []].append(element) }
        return buckets
    }

    private static func contains(_ buckets: [CFHashCode: [AXUIElement]], _ element: AXUIElement) -> Bool {
        buckets[CFHash(element)]?.contains(where: { CFEqual($0, element) }) == true
    }
}
