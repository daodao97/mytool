import XCTest
@testable import MyScreenCore

final class SessionRecoveryTests: XCTestCase {
    func testUnlockWithoutDisplayChangeRequestsRecoveryAfterDesktopDelay() {
        var state = SessionRecoveryState()
        XCTAssertEqual(state.handle(.locked, at: 1), .paused)
        XCTAssertFalse(state.isReady(at: 1000))
        XCTAssertEqual(state.handle(.unlocked, at: 1001), .resumed)
        XCTAssertFalse(state.isReady(at: 1001.39))
        XCTAssertTrue(state.isReady(at: 1001.41))
    }
    func testScreenWakeDoesNotRecoverWhileStillLocked() {
        var state = SessionRecoveryState()
        _ = state.handle(.locked, at: 0)
        _ = state.handle(.screensDidSleep, at: 1)
        _ = state.handle(.systemWillSleep, at: 2)
        XCTAssertNil(state.handle(.systemDidWake, at: 100))
        XCTAssertNil(state.handle(.screensDidWake, at: 101))
        XCTAssertFalse(state.isReady(at: 200))
        XCTAssertEqual(state.handle(.unlocked, at: 201), .resumed)
        XCTAssertTrue(state.isReady(at: 204))
    }
    func testUnlockBeforeScreenWakeStillWaitsForScreen() {
        var state = SessionRecoveryState()
        _ = state.handle(.locked, at: 0)
        _ = state.handle(.screensDidSleep, at: 1)
        XCTAssertNil(state.handle(.unlocked, at: 10))
        XCTAssertFalse(state.isReady(at: 20))
        XCTAssertEqual(state.handle(.screensDidWake, at: 21), .resumed)
        XCTAssertTrue(state.isReady(at: 24))
    }
    func testUnlockRecoversWhenLockNotificationWasMissed() {
        var state = SessionRecoveryState()
        XCTAssertEqual(state.handle(.unlocked, at: 10), .resumed)
        XCTAssertFalse(state.isReady(at: 10.39))
        XCTAssertTrue(state.isReady(at: 10.41))
    }
    func testPollingDetectsColdStartLockedAndMissedUnlock() {
        var state = SessionRecoveryState()
        XCTAssertEqual(state.observe(locked: true, onConsole: true, screensAwake: true, at: 0), .paused)
        XCTAssertNil(state.observe(locked: true, onConsole: true, screensAwake: true, at: 10))
        XCTAssertEqual(state.observe(locked: false, onConsole: true, screensAwake: true, at: 20), .resumed)
        XCTAssertTrue(state.isReady(at: 23))
        XCTAssertNil(state.observe(locked: false, onConsole: true, screensAwake: true, at: 30))
    }
    func testUserSwitchingAndScreenSleepHaveIndependentBlockers() {
        var state = SessionRecoveryState()
        XCTAssertEqual(state.handle(.sessionInactive, at: 0), .paused)
        _ = state.handle(.screensDidSleep, at: 1)
        XCTAssertNil(state.handle(.sessionActive, at: 5))
        XCTAssertFalse(state.isReady(at: 100))
        XCTAssertEqual(state.handle(.screensDidWake, at: 101), .resumed)
        XCTAssertTrue(state.isReady(at: 104))
    }
    func testRelockingDuringDesktopDelayPreventsCapture() {
        var state = SessionRecoveryState()
        _ = state.handle(.locked, at: 0)
        _ = state.handle(.unlocked, at: 10)
        XCTAssertEqual(state.handle(.locked, at: 11), .paused)
        XCTAssertFalse(state.isReady(at: 1000))
        _ = state.handle(.unlocked, at: 1001)
        XCTAssertTrue(state.isReady(at: 1004))
    }
    func testInterruptedRestoreSurvivesLateCosmeticDisplayNotification() {
        let display = DisplayInfo(id: "monitor", name: "Monitor", frame: Rect(x: 0, y: 0, width: 1920, height: 1080),
                                  workArea: Rect(x: 0, y: 25, width: 1920, height: 1055), isBuiltIn: false, isMain: true)
        var transition = DisplayTransitionTracker()
        _ = transition.finish(displays: [display])
        transition.begin(requiresRecovery: true)
        XCTAssertTrue(transition.finish(displays: [display]))
        transition.begin(interruptingRecovery: true)
        transition.begin()
        XCTAssertTrue(transition.finish(displays: [display]))
        transition.begin()
        XCTAssertFalse(transition.finish(displays: [display]))
    }
}
