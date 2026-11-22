import XCTest
@testable import MyScreenCore

final class AutomaticArrangementTests: XCTestCase {
    private let bounds = Rect(x: 0, y: 24, width: 1200, height: 800)

    private var display: DisplayInfo {
        DisplayInfo(id: "main", name: "Main", frame: Rect(x: 0, y: 0, width: 1200, height: 900),
                    workArea: bounds, isBuiltIn: true, isMain: true)
    }

    func testEdgesAndCornersSelectExpectedSnapRegions() {
        let points: [(Double, Double, WindowAction)] = [
            (0, 400, .left), (1199, 400, .right), (600, 0, .maximize), (600, 40, .top), (600, 899, .bottom),
            (0, 0, .topLeft), (1199, 0, .topRight), (0, 899, .bottomLeft), (1199, 899, .bottomRight),
            (60, 10, .topLeft), (1140, 10, .topRight), (10, 85, .topLeft), (1190, 85, .topRight)
        ]
        for (x, y, action) in points {
            XCTAssertEqual(AutomaticArrangement.snapAction(atX: x, y: y, on: display), action, "point \\(x), \\(y)")
        }
        XCTAssertNil(AutomaticArrangement.snapAction(atX: 600, y: 400, on: display))
    }

    func testSnapUsesWorkAreaAndExcludesMenuBarAndDock() {
        let action = AutomaticArrangement.snapAction(atX: 0, y: 400, on: display)
        XCTAssertEqual(action?.target(in: bounds, current: bounds), Rect(x: 0, y: 24, width: 600, height: 800))
        XCTAssertEqual(AutomaticArrangement.snapAction(atX: 600, y: 0, on: display)?.target(in: bounds, current: bounds), bounds)
    }

    func testSnapExitBufferPreventsBoundaryFlicker() {
        XCTAssertEqual(AutomaticArrangement.snapAction(atX: 24, y: 400, on: display), .left)
        XCTAssertNil(AutomaticArrangement.snapAction(atX: 32, y: 400, on: display))
        XCTAssertEqual(AutomaticArrangement.snapAction(atX: 32, y: 400, on: display, previous: .left), .left)
        XCTAssertNil(AutomaticArrangement.snapAction(atX: 41, y: 400, on: display, previous: .left))
    }

    func testSnapHandlesNegativeCoordinatesAndRejectsOtherScreens() {
        let external = DisplayInfo(id: "external", name: "External", frame: Rect(x: -1600, y: -900, width: 1600, height: 900),
            workArea: Rect(x: -1600, y: -876, width: 1600, height: 852), isBuiltIn: false, isMain: false)
        XCTAssertEqual(AutomaticArrangement.snapAction(atX: -1600, y: -500, on: external), .left)
        XCTAssertEqual(AutomaticArrangement.snapAction(atX: -1, y: -899, on: external), .topRight)
        XCTAssertNil(AutomaticArrangement.snapAction(atX: 0, y: -500, on: external))
        XCTAssertNil(AutomaticArrangement.snapAction(atX: .nan, y: 0, on: external))
        XCTAssertNil(AutomaticArrangement.snapAction(atX: 600, y: 900, on: display))
    }

    func testSingleWindowFillsWorkArea() {
        XCTAssertEqual(AutomaticArrangement.target(for: Rect(x: 80, y: 80, width: 500, height: 400),
            in: bounds, avoiding: []), bounds)
    }

    func testFillsSpaceBesideAnotherWindow() {
        let occupied = Rect(x: 700, y: 24, width: 500, height: 800)
        XCTAssertEqual(AutomaticArrangement.target(for: Rect(x: 80, y: 80, width: 500, height: 400),
            in: bounds, avoiding: [occupied]), Rect(x: 0, y: 24, width: 700, height: 800))
    }

    func testFindsLargestRectangleAroundIrregularObstacles() {
        let occupied = [Rect(x: 600, y: 24, width: 600, height: 400),
                        Rect(x: 900, y: 424, width: 300, height: 400)]
        let moved = Rect(x: 350, y: 450, width: 500, height: 300)
        XCTAssertEqual(AutomaticArrangement.target(for: moved, in: bounds, avoiding: occupied),
                       Rect(x: 0, y: 424, width: 900, height: 400))
    }

    func testOccupiedCenterAndNarrowGapsPreservePlacement() {
        let moved = Rect(x: 80, y: 80, width: 500, height: 400)
        XCTAssertNil(AutomaticArrangement.target(for: moved, in: bounds, avoiding: [bounds]))
        let gapWindow = Rect(x: 0, y: 80, width: 80, height: 200)
        XCTAssertNil(AutomaticArrangement.target(for: gapWindow, in: bounds,
            avoiding: [Rect(x: 100, y: 24, width: 1100, height: 800)]))
    }

    func testNegativeDisplayOriginsAndOffScreenObstacles() {
        let workArea = Rect(x: -1600, y: -900, width: 1600, height: 875)
        let moved = Rect(x: -1500, y: -800, width: 500, height: 500)
        let occupied = [Rect(x: -800, y: -1000, width: 900, height: 1000),
                        Rect(x: 0, y: 24, width: 1200, height: 800)]
        XCTAssertEqual(AutomaticArrangement.target(for: moved, in: workArea, avoiding: occupied),
                       Rect(x: -1600, y: -900, width: 800, height: 875))
    }

    func testChoosesAreaOverWidthAndIsIndependentOfWindowEnumerationOrder() {
        let moved = Rect(x: 10, y: 30, width: 200, height: 200)
        let occupied = [Rect(x: 500, y: 24, width: 700, height: 500),
                        Rect(x: 250, y: 524, width: 950, height: 300)]
        let target = AutomaticArrangement.target(for: moved, in: bounds, avoiding: occupied)
        XCTAssertEqual(target, Rect(x: 0, y: 24, width: 500, height: 500))
        XCTAssertEqual(target, AutomaticArrangement.target(for: moved, in: bounds, avoiding: occupied.reversed()))
    }

    func testRejectsInvalidFramesAndOffScreenCenter() {
        XCTAssertNil(AutomaticArrangement.target(for: Rect(x: .nan, y: 30, width: 400, height: 300), in: bounds, avoiding: []))
        XCTAssertNil(AutomaticArrangement.target(for: Rect(x: 1300, y: 30, width: 400, height: 300), in: bounds, avoiding: []))
        XCTAssertEqual(AutomaticArrangement.target(for: Rect(x: 80, y: 80, width: 500, height: 400), in: bounds,
            avoiding: [Rect(x: .infinity, y: 0, width: 400, height: 400)]), bounds)
    }

    func testOnlyWindowTranslationTriggersArrangement() {
        let initial = Rect(x: 80, y: 80, width: 500, height: 400)
        XCTAssertFalse(AutomaticArrangement.isWindowMove(from: initial, to: initial))
        XCTAssertFalse(AutomaticArrangement.isWindowMove(from: initial, to: Rect(x: 81, y: 81, width: 500, height: 400)))
        XCTAssertFalse(AutomaticArrangement.isWindowMove(from: initial, to: Rect(x: 50, y: 50, width: 530, height: 430)))
        XCTAssertTrue(AutomaticArrangement.isWindowMove(from: initial, to: Rect(x: -1200, y: 80, width: 500, height: 400)))
    }
}
