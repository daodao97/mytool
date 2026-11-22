import XCTest
import IOKit.pwr_mgt
@testable import MyActive

final class NativeAssertionTests: XCTestCase {
    func testRealAssertionsRegisterAndReleaseForBothModes() throws {
        guard ProcessInfo.processInfo.environment["MYACTIVE_NATIVE_TESTS"] == "1" else {
            throw XCTSkip("Set MYACTIVE_NATIVE_TESTS=1 to briefly create real macOS power assertions.")
        }
        for mode in AwakeMode.allCases {
            let lease = try XCTUnwrap(try SystemAwakeAssertions().acquire(mode: mode, timeout: 5) as? SystemAwakeLease)
            defer { lease.release() }
            let id = try XCTUnwrap(lease.id)
            let properties = try XCTUnwrap(IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any])
            XCTAssertEqual(properties[kIOPMAssertionTypeKey] as? String,
                           mode == .display ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep)
            XCTAssertEqual(properties[kIOPMAssertionLevelKey] as? Int, Int(kIOPMAssertionLevelOn))
            XCTAssertEqual(properties[kIOPMAssertionTimeoutActionKey] as? String, kIOPMAssertionTimeoutActionTurnOff)
            lease.release(); lease.release()
            XCTAssertNil(lease.id)
            XCTAssertNil(IOPMAssertionCopyProperties(id))
        }
    }

    func testDeadlineReleasesAssertionWithoutApplicationTimer() async throws {
        guard ProcessInfo.processInfo.environment["MYACTIVE_NATIVE_TESTS"] == "1" else {
            throw XCTSkip("Set MYACTIVE_NATIVE_TESTS=1 to test the native timeout.")
        }
        let lease = try XCTUnwrap(try SystemAwakeAssertions().acquire(mode: .system, timeout: 1) as? SystemAwakeLease)
        defer { lease.release() }
        let id = try XCTUnwrap(lease.id)
        var released = false
        // No ActiveModel, UI run loop, or model timer is running in this test.
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            released = lease.id == nil && IOPMAssertionCopyProperties(id) == nil
            if released { break }
        }
        XCTAssertTrue(released, "Deadline must release the native assertion even without the UI timer.")
    }
}
