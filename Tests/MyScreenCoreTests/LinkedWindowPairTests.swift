import XCTest
@testable import MyScreenCore

final class LinkedWindowPairTests: XCTestCase {
    private let bounds = Rect(x: -1440, y: -876, width: 1440, height: 876)
    private func window(_ id: String, _ x: Double, _ width: Double) -> WindowRecord {
        WindowRecord(id: id, bundleID: "test", appName: "Test", title: id, ordinal: 0, displayID: "external",
                     frame: Rect(x: x, y: bounds.y, width: width, height: bounds.height))
    }
    private var windows: [WindowRecord] { [window("left", -1440, 720), window("right", -720, 720)] }

    func testEitherInnerEdgeProducesComplementaryFramesOnNegativeCoordinateScreen() throws {
        let pair = try XCTUnwrap(LinkedWindowPair(windows: windows.reversed(), in: bounds, atX: -720, y: -400))
        for divider in stride(from: -1400.0, through: -40, by: 40) {
            let plan = try XCTUnwrap(pair.placements(divider: divider))
            XCTAssertEqual(plan[0].frame.maxX, plan[1].frame.x)
            XCTAssertEqual(plan[0].frame.intersectionArea(with: plan[1].frame), 0)
            XCTAssertEqual(plan[0].frame.width + plan[1].frame.width, bounds.width)
            XCTAssertEqual(pair.divider(for: "left", current: plan[0].frame), divider)
            XCTAssertEqual(pair.divider(for: "right", current: plan[1].frame), divider)
            XCTAssertEqual(plan[0].frame.y, bounds.y)
            XCTAssertEqual(plan[1].frame.height, bounds.height)
        }
    }

    func testRecognizesUnequalSplitAndSmallRoundingDifferences() {
        let unequal = [window("left", -1440, 900), window("right", -540, 540)]
        XCTAssertNotNil(LinkedWindowPair(windows: unequal, in: bounds, atX: -540, y: -400))
        var rounded = windows
        rounded[0].frame.width -= 1
        rounded[1].frame.x += 1; rounded[1].frame.width -= 1
        XCTAssertNotNil(LinkedWindowPair(windows: rounded, in: bounds, atX: -720, y: -400))
    }

    func testDoesNotLinkPartialCoverageOverlapsDifferentScreensOrThirdWindow() {
        var cases = [Array(windows.prefix(1)), windows + [window("third", -900, 300)]]
        var gap = windows; gap[0].frame.width -= 30; cases.append(gap)
        var overlap = windows; overlap[0].frame.width += 30; cases.append(overlap)
        var partial = windows; partial[1].frame.height -= 30; cases.append(partial)
        var otherScreen = windows; otherScreen[1].displayID = "other"; cases.append(otherScreen)
        for records in cases { XCTAssertNil(LinkedWindowPair(windows: records, in: bounds, atX: -720, y: -400)) }
        XCTAssertNil(LinkedWindowPair(windows: windows, in: bounds, atX: -900, y: -400))
        XCTAssertNil(LinkedWindowPair(windows: windows, in: bounds, atX: -720, y: bounds.y + 2))
        XCTAssertNil(LinkedWindowPair(windows: windows, in: bounds, atX: -720, y: bounds.maxY - 2))
    }

    func testMovesOuterEdgesAndCornerResizesDoNotCountAsDividerResizing() throws {
        let pair = try XCTUnwrap(LinkedWindowPair(windows: windows, in: bounds, atX: -720, y: -400))
        var moved = windows[0].frame; moved.x += 40
        XCTAssertNil(pair.divider(for: "left", current: moved))
        var outer = windows[1].frame; outer.width -= 40
        XCTAssertNil(pair.divider(for: "right", current: outer))
        var corner = windows[0].frame; corner.width += 40; corner.height -= 40
        XCTAssertNil(pair.divider(for: "left", current: corner))
    }

    func testMinimumWidthsClampDividerAndRejectImpossibleOrInvalidLimits() throws {
        let pair = try XCTUnwrap(LinkedWindowPair(windows: windows, in: bounds, atX: -720, y: -400))
        XCTAssertEqual(pair.placements(divider: 0, minimumLeft: 400, minimumRight: 600)?[0].frame.width, 840)
        XCTAssertEqual(pair.placements(divider: -1440, minimumLeft: 400, minimumRight: 600)?[0].frame.width, 400)
        XCTAssertNil(pair.placements(divider: -720, minimumLeft: 900, minimumRight: 900))
        XCTAssertNil(pair.placements(divider: .nan))
        XCTAssertNil(pair.placements(divider: -720, minimumLeft: 0))
    }
}
