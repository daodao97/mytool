import XCTest
import MyScreenCore
@testable import MyScreen

final class ArrangementDropApplierTests: XCTestCase {
    private let target = Rect(x: -1200, y: 24, width: 600, height: 800)
    private let initial = Rect(x: -800, y: 100, width: 500, height: 350)

    func testNativeBounceAfterInitialSuccessIsReappliedAndUndoRecordedOnce() async {
        let done = expectation(description: "Drop survives WindowServer bounce")
        let queue = DispatchQueue(label: "test.drop.bounce")
        let target = target, initial = initial
        var actual = initial, applies = 0, reads = 0, undos = 0
        queue.async {
            ArrangementDropApplier(queue: queue, verificationDelay: 0.01).apply(target: target, token: WindowOperationToken(),
                isDragging: { false }, readFrame: {
                    reads += 1
                    if reads == 2 { actual = initial } // Native final move arrives after our first set.
                    return actual
                }, setFrame: { frame in applies += 1; actual = frame; return 0 }, recordUndo: { undos += 1 }) { result in
                    XCTAssertEqual(result, .applied)
                    XCTAssertEqual(actual, target)
                    XCTAssertEqual(applies, 2)
                    XCTAssertEqual(undos, 1)
                    done.fulfill()
                }
        }
        await fulfillment(of: [done], timeout: 2)
    }

    func testTemporaryAXRejectionRetriesTheSelectedPreview() async {
        let done = expectation(description: "Retries a temporarily unavailable window")
        let queue = DispatchQueue(label: "test.drop.retry")
        let target = target
        var actual = initial, applies = 0, undos = 0
        queue.async {
            ArrangementDropApplier(queue: queue, verificationDelay: 0.01).apply(target: target, token: WindowOperationToken(),
                isDragging: { false }, readFrame: { actual }, setFrame: { frame in
                    applies += 1
                    if applies == 1 { return -1 }
                    actual = frame; return 0
                }, recordUndo: { undos += 1 }) { result in
                    XCTAssertEqual(result, .applied)
                    XCTAssertEqual(applies, 2)
                    XCTAssertEqual(undos, 1)
                    done.fulfill()
                }
        }
        await fulfillment(of: [done], timeout: 2)
    }

    func testApplicationMinimumSizeIsReportedWithoutEndlessRetries() async {
        let done = expectation(description: "Accepts stable application size constraint")
        let queue = DispatchQueue(label: "test.drop.limited")
        let target = target
        var actual = initial, applies = 0
        queue.async {
            ArrangementDropApplier(queue: queue, verificationDelay: 0.01).apply(target: target, token: WindowOperationToken(),
                isDragging: { false }, readFrame: { actual }, setFrame: { frame in
                    applies += 1
                    actual = Rect(x: frame.x, y: frame.y, width: 700, height: frame.height); return 1
                }, recordUndo: {}) { result in
                    XCTAssertEqual(result, .limited)
                    XCTAssertEqual(applies, 1)
                    done.fulfill()
                }
        }
        await fulfillment(of: [done], timeout: 2)
    }

    func testNewGestureCancelsLateReapply() async {
        let done = expectation(description: "New gesture stops retries")
        let queue = DispatchQueue(label: "test.drop.cancel")
        let token = WindowOperationToken(), target = target, initial = initial
        var actual = initial, applies = 0
        queue.async {
            ArrangementDropApplier(queue: queue, verificationDelay: 0.01).apply(target: target, token: token,
                isDragging: { false }, readFrame: { actual }, setFrame: { frame in
                    applies += 1; actual = frame; return 0
                }, recordUndo: {}) { result in
                    XCTAssertEqual(result, .cancelled)
                    XCTAssertEqual(applies, 1)
                    XCTAssertEqual(actual, initial)
                    done.fulfill()
                }
            actual = initial
            token.cancel()
        }
        await fulfillment(of: [done], timeout: 2)
    }

    func testContinuedRejectionStopsAfterThreeAttempts() async {
        let done = expectation(description: "Bounded failure")
        let queue = DispatchQueue(label: "test.drop.failure")
        let target = target
        var applies = 0
        queue.async {
            ArrangementDropApplier(queue: queue, verificationDelay: 0.01).apply(target: target, token: WindowOperationToken(),
                isDragging: { false }, readFrame: { nil }, setFrame: { _ in applies += 1; return -1 }, recordUndo: {
                    XCTFail("Rejected moves must not record undo")
                }) { result in
                    XCTAssertEqual(result, .failed)
                    XCTAssertEqual(applies, 3)
                    done.fulfill()
                }
        }
        await fulfillment(of: [done], timeout: 2)
    }

    func testSuccessfulReadbackRecordsUndoEvenIfAXReplyWasLost() async {
        let done = expectation(description: "Readback confirms a lost AX reply")
        let queue = DispatchQueue(label: "test.drop.reply")
        let target = target
        var actual = initial, undos = 0
        queue.async {
            ArrangementDropApplier(queue: queue, verificationDelay: 0.01).apply(target: target, token: WindowOperationToken(),
                isDragging: { false }, readFrame: { actual }, setFrame: { frame in actual = frame; return -1 },
                recordUndo: { undos += 1 }) { result in
                    XCTAssertEqual(result, .applied)
                    XCTAssertEqual(undos, 1)
                    done.fulfill()
                }
        }
        await fulfillment(of: [done], timeout: 2)
    }
}
