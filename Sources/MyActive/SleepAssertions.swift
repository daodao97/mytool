import Foundation
import IOKit.pwr_mgt
import IOKit.ps

protocol AwakeLease: AnyObject { func release() }
protocol AwakeAssertionProviding {
    func acquire(mode: AwakeMode, timeout: TimeInterval?) throws -> any AwakeLease
}

struct SystemAwakeAssertions: AwakeAssertionProviding {
    func acquire(mode: AwakeMode, timeout: TimeInterval?) throws -> any AwakeLease {
        var properties: [String: Any] = [
            kIOPMAssertionTypeKey: mode == .display ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep,
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            kIOPMAssertionNameKey: "MyTool · MyActive · \(mode.title)",
            kIOPMAssertionHumanReadableReasonKey: "用户开启 MyActive 保持唤醒会话"
        ]
        if let timeout {
            properties[kIOPMAssertionTimeoutKey] = max(1, timeout)
            // Ask powerd for a timeout too; the lease has an independent expiry timer.
            properties[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionTurnOff
        }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
        guard result == kIOReturnSuccess else { throw AwakeError.assertion(result) }
        return SystemAwakeLease(id: id, timeout: timeout)
    }
}

final class SystemAwakeLease: AwakeLease, @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?
    private var timer: DispatchSourceTimer?
    var id: IOPMAssertionID? {
        lock.lock(); defer { lock.unlock() }
        return assertionID
    }
    init(id: IOPMAssertionID, timeout: TimeInterval?) {
        assertionID = id
        if let timeout {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.release() }
            self.timer = timer; timer.resume()
        }
    }
    func release() {
        lock.lock()
        let id = assertionID, timer = self.timer
        assertionID = nil; self.timer = nil
        lock.unlock()
        timer?.cancel()
        if let id { IOPMAssertionRelease(id) }
    }
    deinit { release() }
}

enum SystemPower {
    static func snapshot() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .unknown }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let source: PowerSnapshot.Source = providing == kIOPSACPowerValue ? .ac : providing == kIOPSBatteryPowerValue ? .battery : .unknown
        var percent: Int?
        if let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for item in sources {
                guard let data = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                      data[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = data[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = data[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                percent = min(100, max(0, Int(Double(current) / Double(maximum) * 100)))
                break
            }
        }
        return PowerSnapshot(source: source, batteryPercent: percent)
    }
}
