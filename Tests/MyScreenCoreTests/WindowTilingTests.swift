import XCTest
@testable import MyScreenCore

final class WindowTilingTests: XCTestCase {
    private let area = Rect(x: -1200, y: -800, width: 1200, height: 800)

    private func check(_ frames: [Rect], in bounds: Rect, fills: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(frame.isValid, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.x, bounds.x - 0.001, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.y, bounds.y - 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 0.001, file: file, line: line)
            for other in frames.dropFirst(index + 1) { XCTAssertEqual(frame.intersectionArea(with: other), 0, accuracy: 0.001, file: file, line: line) }
        }
        if fills {
            XCTAssertEqual(frames.reduce(0) { $0 + $1.width * $1.height }, bounds.width * bounds.height, accuracy: 0.001, file: file, line: line)
        }
    }

    func testAutomaticLayoutsFillNegativeCoordinateScreensWithoutOverlapOrHoles() {
        for count in 1...24 {
            let frames = WindowTiling.frames(count: count, in: area)
            XCTAssertEqual(frames.count, count)
            check(frames, in: area)
        }
    }

    func testTwoWindowsUseColumnsOnLandscapeAndRowsOnPortrait() {
        XCTAssertEqual(WindowTiling.frames(count: 2, in: area), [
            Rect(x: -1200, y: -800, width: 600, height: 800), Rect(x: -600, y: -800, width: 600, height: 800)
        ])
        let portrait = Rect(x: 0, y: 34, width: 800, height: 1200)
        XCTAssertEqual(WindowTiling.frames(count: 2, in: portrait), [
            Rect(x: 0, y: 34, width: 800, height: 600), Rect(x: 0, y: 634, width: 800, height: 600)
        ])
    }

    func testThreeWindowsHaveNoUnusedFourthCell() {
        let frames = WindowTiling.frames(count: 3, in: area)
        XCTAssertEqual(frames.map(\.width), [600, 600, 1200])
        check(frames, in: area)
    }

    func testExplicitRowsAndColumnsAreEqualAndFillTheArea() {
        for layout in [WindowTileLayout.rows, .columns] {
            let frames = WindowTiling.frames(count: 3, in: area, layout: layout)
            check(frames, in: area)
            XCTAssertEqual(frames[0].width, layout == .rows ? 1200 : 400)
            XCTAssertEqual(frames[0].height, layout == .rows ? 800 / 3 : 800, accuracy: 0.001)
        }
    }

    func testSnappedHalfIsPreservedWhileTwoNeighborsFillTheOtherHalf() {
        let anchor = WindowAction.left.target(in: area, current: area)!
        let others = WindowTiling.frames(count: 2, in: area, reserving: anchor)
        XCTAssertEqual(others, [Rect(x: -600, y: -800, width: 600, height: 400), Rect(x: -600, y: -400, width: 600, height: 400)])
        check([anchor] + others, in: area)
    }

    func testCornerAndThreeNeighborsBecomeFourQuarters() {
        let anchor = WindowAction.topLeft.target(in: area, current: area)!
        let others = WindowTiling.frames(count: 3, in: area, reserving: anchor)
        XCTAssertEqual(others.count, 3)
        XCTAssertTrue(others.allSatisfy { $0.width == 600 && $0.height == 400 })
        check([anchor] + others, in: area)
    }

    func testLShapedRemainderWithOneNeighborUsesLargestRectangleWithoutOverlap() {
        let anchor = WindowAction.topLeft.target(in: area, current: area)!
        let others = WindowTiling.frames(count: 1, in: area, reserving: anchor)
        XCTAssertEqual(others, [Rect(x: -600, y: -800, width: 600, height: 800)])
        check([anchor] + others, in: area, fills: false)
        XCTAssertTrue(WindowTiling.frames(count: 2, in: area, reserving: area).isEmpty)
    }

    private func record(_ id: String, frame: Rect) -> WindowRecord {
        WindowRecord(id: id, bundleID: "test", appName: "Test", title: id, ordinal: 0, displayID: "external", frame: frame)
    }

    func testDraggedWindowChoosesNearestSlotAndOrderingDoesNotDependOnAXEnumeration() {
        let left = record("left", frame: Rect(x: -1150, y: -750, width: 300, height: 200))
        let dragged = record("moving", frame: Rect(x: -450, y: -700, width: 400, height: 300))
        let plan = WindowTiling.plan(windows: [dragged, left], in: area, movingWindowID: dragged.id)
        XCTAssertEqual(plan, WindowTiling.plan(windows: [left, dragged], in: area, movingWindowID: dragged.id))
        XCTAssertEqual(plan.first?.windowID, dragged.id)
        XCTAssertEqual(plan.first?.frame.x, -600)
        XCTAssertEqual(Set(plan.map(\.windowID)), ["left", "moving"])
        check(plan.map(\.frame), in: area)
    }

    func testAnchoredPlanPreservesDraggedWindowAndAssignsEveryOtherWindowOnce() {
        let windows = (0..<4).map { record("\($0)", frame: Rect(x: Double($0 * 100) - 1000, y: -600, width: 300, height: 300)) }
        let anchor = WindowAction.bottomRight.target(in: area, current: area)!
        let plan = WindowTiling.plan(windows: windows, in: area, movingWindowID: "2", anchor: anchor)
        XCTAssertEqual(plan.first, WindowPlacement(windowID: "2", frame: anchor))
        XCTAssertEqual(Set(plan.map(\.windowID)).count, windows.count)
        check(plan.map(\.frame), in: area)
    }

    func testEmptyInvalidAndOutOfBoundsInputsAreRejected() {
        XCTAssertTrue(WindowTiling.frames(count: 0, in: area).isEmpty)
        XCTAssertTrue(WindowTiling.frames(count: -1, in: area).isEmpty)
        XCTAssertTrue(WindowTiling.frames(count: 2, in: Rect(x: 0, y: 0, width: .nan, height: 1)).isEmpty)
        XCTAssertTrue(WindowTiling.plan(windows: [record("a", frame: area)], in: area, movingWindowID: "a",
            anchor: Rect(x: 0, y: 0, width: 500, height: 400)).isEmpty)
    }
}
