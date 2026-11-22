import XCTest
@testable import MyActive

private final class FakeLease: AwakeLease {
    private(set) var releases = 0
    func release() { releases += 1 }
}
private final class FakeAssertions: AwakeAssertionProviding {
    var requests: [(AwakeMode, TimeInterval?)] = []
    var leases: [FakeLease] = []
    var shouldFail = false
    func acquire(mode: AwakeMode, timeout: TimeInterval?) throws -> any AwakeLease {
        if shouldFail { throw AwakeError.assertion(-1) }
        requests.append((mode, timeout))
        let lease = FakeLease(); leases.append(lease); return lease
    }
}

@MainActor
final class ActiveModelTests: XCTestCase {
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    private var uptime: TimeInterval = 100
    private var power = PowerSnapshot(source: .ac, batteryPercent: 80)
    private func model(_ backend: FakeAssertions) -> ActiveModel {
        ActiveModel(assertions: backend, wallClock: { self.date }, monotonicClock: { self.uptime }, readPower: { self.power })
    }

    func testStartupDoesNotPreventSleepUntilUserStartsSession() async throws {
        let backend = FakeAssertions(), model = model(backend)
        XCTAssertNil(model.session); XCTAssertFalse(model.status.isActive); XCTAssertEqual(backend.requests.count, 0)
        try model.start(limit: .duration(60))
        XCTAssertTrue(model.status.isActive)
        XCTAssertEqual(backend.requests.first?.0, .display)
        XCTAssertEqual(backend.requests.first?.1, 60)
        model.stop(); model.stop()
        XCTAssertEqual(backend.leases[0].releases, 1)
        XCTAssertNil(model.session)
    }

    func testTimedSessionExpiresAndReleasesItsAssertion() async throws {
        let backend = FakeAssertions(), model = model(backend)
        try model.start(limit: .duration(60))
        uptime += 59; model.tick(); XCTAssertTrue(model.isActive); XCTAssertEqual(model.remaining, 1)
        uptime += 1; model.tick()
        XCTAssertNil(model.session); XCTAssertEqual(backend.leases[0].releases, 1)
    }

    func testDurationUsesMonotonicTimeAcrossClockChanges() async throws {
        let backend = FakeAssertions(), model = model(backend)
        try model.start(limit: .duration(60))
        date += 3600; uptime += 10; model.tick(); XCTAssertEqual(model.remaining, 50)
        date -= 7200; uptime += 50; model.tick(); XCTAssertNil(model.session)
    }

    func testPauseFreezesDurationAndResumeUsesRemainingTime() async throws {
        let backend = FakeAssertions(), model = model(backend)
        try model.start(limit: .duration(60))
        uptime += 20; model.pause()
        XCTAssertEqual(model.remaining, 40); XCTAssertEqual(model.elapsed, 20)
        XCTAssertFalse(model.status.isActive); XCTAssertEqual(backend.leases[0].releases, 1)
        uptime += 1000; date += 1000; model.tick(); XCTAssertEqual(model.remaining, 40)
        try model.resume(); XCTAssertEqual(backend.requests.last?.1, 40)
        uptime += 40; model.tick(); XCTAssertNil(model.session)
        XCTAssertEqual(backend.leases.last?.releases, 1)
    }

    func testFixedDeadlineStillExpiresWhenPaused() async throws {
        let backend = FakeAssertions(), model = model(backend)
        try model.start(limit: .until(date.addingTimeInterval(60)))
        model.pause(); date += 60; model.tick()
        XCTAssertNil(model.session); XCTAssertEqual(backend.requests.count, 1)
        try model.resume(); XCTAssertNil(model.session)
    }

    func testFixedDeadlineRearmsAfterWallClockMovesBackwards() async throws {
        let backend = FakeAssertions(), model = model(backend)
        try model.start(limit: .until(date.addingTimeInterval(60)))
        uptime += 10; date -= 20; model.tick()
        XCTAssertEqual(model.remaining, 80)
        XCTAssertEqual(backend.requests.last?.1, 80)
        XCTAssertEqual(backend.requests.count, 2)
        XCTAssertEqual(backend.leases[0].releases, 1)
        date += 100; model.tick()
        XCTAssertNil(model.session)
        XCTAssertEqual(backend.leases[1].releases, 1)
    }

    func testFailedDeadlineRearmEndsSessionInsteadOfShowingFalseActiveState() async throws {
        let backend = FakeAssertions(), model = model(backend)
        try model.start(limit: .until(date.addingTimeInterval(60)))
        backend.shouldFail = true; date -= 100; model.tick()
        XCTAssertNil(model.session); XCTAssertNotNil(model.error)
        XCTAssertEqual(backend.leases[0].releases, 1)
    }

    func testIndefiniteSessionHasNoKernelTimeoutAndCanPauseResume() async throws {
        let backend = FakeAssertions(), model = model(backend)
        try model.start(limit: .unlimited)
        XCTAssertNil(backend.requests[0].1)
        uptime += 100000; date += 100000; model.tick(); XCTAssertTrue(model.isActive)
        model.pause(); XCTAssertNil(model.remaining)
        try model.resume(); XCTAssertNil(backend.requests.last?.1)
        model.shutdown(); XCTAssertEqual(backend.leases.last?.releases, 1)
    }

    func testFailedReplacementPreservesPreviousLeaseDeadlineAndMode() async throws {
        let backend = FakeAssertions(), model = model(backend)
        try model.start(limit: .duration(60))
        let previous = model.session
        backend.shouldFail = true
        XCTAssertThrowsError(try model.changeMode(.system))
        XCTAssertEqual(model.mode, .display); XCTAssertEqual(model.session, previous)
        XCTAssertEqual(backend.leases[0].releases, 0)
        XCTAssertThrowsError(try model.start(limit: .unlimited))
        XCTAssertThrowsError(try model.extend())
        XCTAssertEqual(model.session, previous)
        model.stop(); XCTAssertEqual(backend.leases[0].releases, 1)
    }

    func testModeSwitchReplacesLeaseWithoutResettingCountdown() async throws {
        let backend = FakeAssertions(), model = model(backend)
        try model.start(limit: .duration(60))
        uptime += 10; try model.changeMode(.system)
        XCTAssertEqual(model.remaining, 50); XCTAssertEqual(model.mode, .system)
        XCTAssertEqual(backend.requests.last?.0, .system)
        XCTAssertEqual(backend.requests.last?.1, 50)
        XCTAssertEqual(backend.leases[0].releases, 1)
        model.pause(); try model.changeMode(.display)
        XCTAssertEqual(backend.requests.count, 2)
        try model.resume(); XCTAssertEqual(backend.requests.last?.0, .display)
    }

    func testExtensionsWorkForActivePausedAndFixedTimeSessions() async throws {
        let backend = FakeAssertions(), model = model(backend)
        try model.start(limit: .duration(60)); uptime += 10
        try model.extend(by: 30); XCTAssertEqual(model.remaining, 80)
        model.pause(); try model.extend(by: 20); XCTAssertEqual(model.remaining, 100)
        XCTAssertEqual(backend.requests.count, 2)
        try model.start(limit: .until(date.addingTimeInterval(60)))
        try model.extend(by: 30); XCTAssertEqual(model.remaining, 90)
    }

    func testLowBatteryEndsSessionOnlyOnBatteryPower() async throws {
        let backend = FakeAssertions(), model = model(backend)
        power = PowerSnapshot(source: .ac, batteryPercent: 10)
        try model.start(limit: .unlimited); XCTAssertTrue(model.isActive)
        power.source = .battery; model.refreshPower()
        XCTAssertNil(model.session); XCTAssertEqual(backend.leases[0].releases, 1)
        XCTAssertThrowsError(try model.start(limit: .unlimited))
        model.lowBatteryProtection = false
        try model.start(limit: .unlimited); XCTAssertTrue(model.isActive)
    }

    func testACOnlyEndsOnUnplugAndRejectsUnknownPower() async throws {
        let backend = FakeAssertions(), model = model(backend)
        model.onlyOnAC = true; try model.start(limit: .unlimited)
        power.source = .battery; model.refreshPower(); XCTAssertNil(model.session)
        power = .unknown
        XCTAssertThrowsError(try model.start(limit: .duration(30)))
        XCTAssertEqual(backend.requests.count, 1)
    }

    func testLockSleepAndShutdownReleaseOwnedAssertions() async throws {
        let backend = FakeAssertions(), model = model(backend)
        try model.start(limit: .unlimited); model.screenLocked(); XCTAssertNil(model.session)
        model.endOnLock = false; try model.start(limit: .unlimited); model.screenLocked(); XCTAssertTrue(model.isActive)
        model.systemWillSleep(); XCTAssertNil(model.session)
        try model.start(limit: .unlimited); model.shutdown(); XCTAssertNil(model.session)
        XCTAssertTrue(backend.leases.allSatisfy { $0.releases == 1 })
    }

    func testInvalidDurationsAndDatesDoNotAcquireAssertions() async {
        let backend = FakeAssertions(), model = model(backend)
        for limit in [AwakeLimit.duration(0), .duration(-1), .duration(.nan), .duration(.infinity), .duration(86401), .until(date)] {
            XCTAssertThrowsError(try model.start(limit: limit))
        }
        XCTAssertEqual(backend.requests.count, 0); XCTAssertNil(model.session)
    }
}
