import XCTest
import MyScreenCore
@testable import MyScreen

final class LinkedResizeSessionTests: XCTestCase {
    private final class Harness {
        let bounds = Rect(x: 0, y: 24, width: 1200, height: 800)
        var frames = ["left": Rect(x: 0, y: 24, width: 600, height: 800),
                      "right": Rect(x: 600, y: 24, width: 600, height: 800)]
        var minimums: [String: Double] = [:]
        var rejected: Set<String> = []
        var writes: [String] = []
        var undos = 0
        var afterWrite: ((String) -> Void)?
        var deferWrites = false
        var pending: [(String, Rect)] = []
        let token = WindowOperationToken()
        lazy var session: LinkedResizeSession = {
            let windows = frames.map { id, frame in
                WindowRecord(id: id, bundleID: "test", appName: "Test", title: id, ordinal: 0, displayID: "screen", frame: frame)
            }
            let pair = LinkedWindowPair(windows: windows, in: bounds, atX: 600, y: 400)!
            return LinkedResizeSession(pair: pair, read: { self.frames[$0] }, write: { id, target in
                self.writes.append(id)
                guard !self.rejected.contains(id) else { return -1 }
                if self.deferWrites { self.pending.append((id, target)); return 0 }
                var actual = target
                actual.width = max(actual.width, self.minimums[id] ?? 1)
                self.frames[id] = actual
                self.afterWrite?(id)
                return actual == target ? 0 : 1
            }, recordUndo: { self.undos += 1 })
        }()
        func begin() { _ = session }
        func resize(_ id: String, divider: Double) {
            if id == "left" { frames[id]?.width = divider }
            else { frames[id]?.x = divider; frames[id]?.width = bounds.maxX - divider }
            session.update(token: token)
        }
        func assertFilled(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(frames["left"]?.maxX, frames["right"]?.x, file: file, line: line)
            XCTAssertEqual(frames["left"]?.x, bounds.x, file: file, line: line)
            XCTAssertEqual(frames["right"]?.maxX, bounds.maxX, file: file, line: line)
        }
    }

    func testEitherWindowCanDriveLiveResizeWithOneUndoAndNoRedundantWrites() {
        for active in ["left", "right"] {
            let h = Harness(); h.begin()
            for split in [720.0, 800, 500, 600] { h.resize(active, divider: split); h.assertFilled() }
            XCTAssertEqual(h.undos, 1)
            XCTAssertEqual(Set(h.writes), [active == "left" ? "right" : "left"])
            let count = h.writes.count
            h.session.update(token: h.token)
            XCTAssertEqual(h.writes.count, count)
        }
    }

    func testPeerMinimumWidthClampsBothWindowsAndAllowsDraggingBack() {
        for active in ["left", "right"] {
            let h = Harness(); h.begin()
            let peer = active == "left" ? "right" : "left"
            h.minimums[peer] = 450
            h.resize(active, divider: active == "left" ? 1000 : 200)
            h.session.update(token: h.token, settled: true)
            h.assertFilled()
            XCTAssertEqual(h.frames[peer]?.width, 450)
            XCTAssertTrue(h.session.limited)
            XCTAssertFalse(h.session.failed)
            h.resize(active, divider: 600)
            h.assertFilled()
            XCTAssertEqual(h.frames[peer]?.width, 600)
            XCTAssertEqual(h.undos, 1)
        }
    }

    func testRejectedPeerRestoresLastCompleteLayoutAndStopsFurtherWrites() {
        let h = Harness(); h.begin()
        h.resize("left", divider: 700)
        h.rejected.insert("right")
        h.resize("left", divider: 800)
        XCTAssertFalse(h.session.failed)
        XCTAssertTrue(h.session.needsRetry)
        h.session.update(token: h.token, settled: true)
        h.session.abandon(token: h.token)
        h.assertFilled()
        XCTAssertEqual(h.frames["left"]?.width, 700)
        XCTAssertTrue(h.session.failed)
        let count = h.writes.count
        h.session.update(token: h.token)
        XCTAssertEqual(h.writes.count, count)
    }

    func testCancelledTokenAndClosedPeerDoNotMoveSurvivingWindow() {
        let cancelled = Harness(); cancelled.begin(); cancelled.token.cancel()
        cancelled.resize("left", divider: 800)
        XCTAssertTrue(cancelled.writes.isEmpty)
        XCTAssertEqual(cancelled.undos, 0)
        let closed = Harness(); closed.begin(); closed.frames["right"] = nil
        closed.resize("left", divider: 800)
        XCTAssertTrue(closed.writes.isEmpty)
    }

    func testClicksTitleMovesAndVerticalResizesDoNotLinkWindows() {
        let h = Harness(); h.begin()
        h.session.update(token: h.token)
        h.frames["left"]?.x = 40
        h.session.update(token: h.token)
        h.frames["left"]?.x = 0; h.frames["left"]?.height = 700
        h.resize("left", divider: 800)
        XCTAssertNil(h.session.activeID)
        XCTAssertTrue(h.writes.isEmpty)
        XCTAssertEqual(h.undos, 0)
    }

    func testNativeGeometryBounceAfterReleaseIsReconciledWithoutSecondUndo() {
        let h = Harness(); h.begin()
        h.resize("right", divider: 500)
        h.frames["right"] = Rect(x: 480, y: 24, width: 720, height: 800)
        h.session.update(token: h.token)
        h.assertFilled()
        XCTAssertEqual(h.frames["left"]?.width, 480)
        XCTAssertEqual(h.undos, 1)
    }

    func testNativeResizeAdvancingDuringPeerWriteIsNeverPushedBackOrRolledBack() {
        let h = Harness(); h.begin()
        h.afterWrite = { id in if id == "right" { h.frames["left"]?.width = 840 } }
        h.resize("left", divider: 800)
        XCTAssertEqual(h.frames["left"]?.width, 840)
        XCTAssertEqual(h.writes, ["right"])
        XCTAssertFalse(h.session.failed)
        h.afterWrite = nil
        h.session.update(token: h.token, settled: true)
        h.assertFilled()
        XCTAssertEqual(h.frames["left"]?.width, 840)
        XCTAssertEqual(h.undos, 1)
    }

    func testTransientRejectionDuringNativeTrackingRecoversAfterMouseUp() {
        let h = Harness(); h.begin()
        h.rejected.insert("right")
        h.resize("left", divider: 800)
        XCTAssertTrue(h.session.needsRetry)
        XCTAssertFalse(h.session.failed)
        h.rejected.removeAll()
        h.session.update(token: h.token, settled: true)
        h.assertFilled()
        XCTAssertFalse(h.session.needsRetry)
        XCTAssertFalse(h.session.failed)
    }

    func testDelayedWindowServerGeometryIsNotMistakenForMinimumWidth() {
        let h = Harness(); h.begin(); h.deferWrites = true
        h.resize("left", divider: 800)
        XCTAssertFalse(h.session.failed)
        XCTAssertFalse(h.session.limited)
        XCTAssertTrue(h.session.needsRetry)
        h.deferWrites = false
        for (id, frame) in h.pending { h.frames[id] = frame }
        h.session.update(token: h.token, settled: true)
        h.assertFilled()
        XCTAssertFalse(h.session.limited)
        XCTAssertFalse(h.session.needsRetry)
    }
}
