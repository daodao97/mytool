import XCTest
import AppKit
@testable import MyScreen

@MainActor
final class SessionMonitorTests: XCTestCase {
    func testWorkspaceSleepAndWakeNotificationsReachTheMonitor() async {
        let center = NotificationCenter()
        var now: TimeInterval = 0
        let monitor = SessionMonitor(workspaceCenter: center, clock: { now },
            readSnapshot: { .init(locked: false, onConsole: true, screensAwake: true) })
        monitor.start(); defer { monitor.stop() }
        let paused = expectation(description: "Pauses on workspace sleep")
        let resumed = expectation(description: "Recovers on workspace wake")
        monitor.onChange = { if $0 == .paused { paused.fulfill() } else { resumed.fulfill() } }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fulfillment(of: [paused], timeout: 2)
        XCTAssertTrue(monitor.isSuspended)
        XCTAssertFalse(monitor.isReady)
        now = 100
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertFalse(monitor.isReady)
        XCTAssertLessThanOrEqual(monitor.readinessDelay, 0.401)
        now = 100.41
        XCTAssertTrue(monitor.isReady)
    }

    func testPollingRecoversMissedLockUnlockWithoutHardwareChanges() async {
        var snapshot = SessionMonitor.Snapshot(locked: false, onConsole: true, screensAwake: true)
        var now: TimeInterval = 0
        let monitor = SessionMonitor(workspaceCenter: NotificationCenter(), clock: { now }, readSnapshot: { snapshot })
        monitor.start(); defer { monitor.stop() }
        var changes: [String] = []
        monitor.onChange = { changes.append(String(describing: $0)) }
        snapshot.locked = true; monitor.poll()
        XCTAssertTrue(monitor.isSuspended)
        now = 1000; monitor.poll()
        XCTAssertEqual(changes, ["paused"])
        snapshot.locked = false; monitor.poll()
        XCTAssertEqual(changes, ["paused", "resumed"])
        XCTAssertFalse(monitor.isReady)
        now = 1000.41
        XCTAssertTrue(monitor.isReady)
        monitor.poll()
        XCTAssertEqual(changes.count, 2)
    }
}
