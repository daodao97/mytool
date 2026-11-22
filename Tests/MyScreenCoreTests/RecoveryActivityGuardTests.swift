import XCTest
@testable import MyScreenCore

final class RecoveryActivityGuardTests: XCTestCase {
    func testLateSystemBounceCanBeRepairedWhenThereWasNoNewInput() {
        let watch = RecoveryActivityGuard(generation: 5, counters: [100, 20, 30])
        XCTAssertTrue(watch.permitsRecovery(generation: 5, counters: [100, 20, 30], isDragging: false))
    }
    func testDragThenReleaseCancelsRepairEvenAfterMouseButtonIsReleased() {
        let watch = RecoveryActivityGuard(generation: 5, counters: [100, 20, 30])
        XCTAssertFalse(watch.permitsRecovery(generation: 5, counters: [101, 45, 30], isDragging: false))
    }
    func testTypingOrClickingCancelsLateRepairs() {
        let watch = RecoveryActivityGuard(generation: 5, counters: [100, 20, 30])
        XCTAssertFalse(watch.permitsRecovery(generation: 5, counters: [100, 20, 31], isDragging: false))
        XCTAssertFalse(watch.permitsRecovery(generation: 5, counters: [101, 20, 30], isDragging: false))
    }
    func testOldRecoveryCannotOverrideNewShortcutOrSessionGeneration() {
        let watch = RecoveryActivityGuard(generation: 5, counters: [100, 20, 30])
        XCTAssertFalse(watch.permitsRecovery(generation: 6, counters: [100, 20, 30], isDragging: false))
    }
    func testDragAlreadyInProgressBlocksLateRecovery() {
        let watch = RecoveryActivityGuard(generation: 5, counters: [100, 20, 30])
        XCTAssertFalse(watch.permitsRecovery(generation: 5, counters: [100, 20, 30], isDragging: true))
    }
}
