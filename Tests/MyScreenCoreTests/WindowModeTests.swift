import XCTest
@testable import MyScreenCore

final class WindowModeTests: XCTestCase {
    private let bindings = ShortcutBinding.defaults
    private func chord(_ code: UInt32, shift: Bool = false) -> KeyChord { KeyChord(keyCode: code, modifiers: shift ? 512 : 0) }
    private func screen(_ id: String, x: Double, y: Double) -> DisplayInfo {
        let frame = Rect(x: x, y: y, width: 1440, height: 900)
        return DisplayInfo(id: id, name: id, frame: frame, workArea: frame, isBuiltIn: false, isMain: id == "main")
    }
    func testDefaultLeaderAndBindingsMatchWinWinInsteadOfOldDirectShortcuts() {
        XCTAssertEqual(KeyChord.leader, KeyChord(keyCode: 15, modifiers: 2048))
        let expected: [(UInt32, WindowAction)] = [(0,.moveLeft),(2,.moveRight),(13,.moveUp),(1,.moveDown),
            (4,.left),(37,.right),(40,.top),(38,.bottom),(16,.topLeft),(31,.topRight),(32,.bottomLeft),(34,.bottomRight),
            (3,.maximize),(8,.center),(24,.expand),(27,.shrink),(123,.screenLeft),(124,.screenRight),
            (126,.screenUp),(125,.screenDown),(49,.nextDisplay),(33,.undo),(30,.redo),(50,.centerCursor)]
        for (key, action) in expected {
            XCTAssertEqual(bindings.first(where: { $0.chord == chord(key) })?.action, action)
        }
        XCTAssertEqual(Set(bindings.map(\.action)), Set(WindowAction.allCases))
        XCTAssertEqual(Set(bindings.map { "\($0.keyCode):\($0.modifiers)" }).count, bindings.count)
        XCTAssertTrue(bindings.allSatisfy { !WindowModeState.isReserved($0.chord) })
    }
    func testKeysOutsideModeRemainNormalTyping() {
        var state = WindowModeState()
        for key: UInt32 in [0, 4, 12, 48, 53, 123] {
            XCTAssertEqual(state.handle(chord(key), keyDown: true, bindings: bindings), .passThrough)
            XCTAssertEqual(state.handle(chord(key), keyDown: false, bindings: bindings), .passThrough)
        }
    }
    func testMultipleCommandsStayInModeUntilEscapeAndConsumeTheirKeyUps() {
        var state = WindowModeState(); state.enter()
        XCTAssertEqual(state.handle(chord(4), keyDown: true, bindings: bindings), .action(.left))
        XCTAssertEqual(state.handle(chord(4), keyDown: false, bindings: bindings), .consumed)
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.handle(chord(37), keyDown: true, bindings: bindings), .action(.right))
        XCTAssertEqual(state.handle(chord(53), keyDown: true, bindings: bindings), .exit)
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.hasPendingKeyUps)
        XCTAssertEqual(state.handle(chord(37), keyDown: false, bindings: bindings), .consumed)
        XCTAssertEqual(state.handle(chord(53), keyDown: false, bindings: bindings), .consumed)
        XCTAssertFalse(state.hasPendingKeyUps)
        XCTAssertEqual(state.handle(chord(4), keyDown: true, bindings: bindings), .passThrough)
    }
    func testQExitsAndTabTogglesHelpWithoutLeaving() {
        var state = WindowModeState(); state.enter()
        XCTAssertEqual(state.handle(chord(48), keyDown: true, bindings: bindings), .toggleHelp)
        XCTAssertEqual(state.handle(chord(48), keyDown: true, isRepeat: true, bindings: bindings), .consumed)
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.handle(chord(12), keyDown: true, bindings: bindings), .exit)
        XCTAssertFalse(state.isActive)
    }
    func testShiftResizeAndRepeatableMovement() {
        var state = WindowModeState(); state.enter()
        XCTAssertEqual(state.handle(chord(4, shift: true), keyDown: true, bindings: bindings), .action(.shrinkWidth))
        XCTAssertEqual(state.handle(chord(37, shift: true), keyDown: true, isRepeat: true, bindings: bindings), .action(.growWidth))
        XCTAssertEqual(state.handle(chord(0), keyDown: true, isRepeat: true, bindings: bindings), .action(.moveLeft))
        XCTAssertEqual(state.handle(chord(3), keyDown: true, isRepeat: true, bindings: bindings), .consumed)
        XCTAssertEqual(state.handle(chord(33), keyDown: true, isRepeat: true, bindings: bindings), .consumed)
    }
    func testUnboundAndModifiedKeysPassThroughWhileModeIsActive() {
        var state = WindowModeState(); state.enter()
        XCTAssertEqual(state.handle(KeyChord(keyCode: 4, modifiers: 256), keyDown: true, bindings: bindings), .passThrough)
        XCTAssertEqual(state.handle(chord(6), keyDown: true, bindings: bindings), .passThrough)
        XCTAssertTrue(state.isActive)
    }
    func testKeyUpIsConsumedEvenIfModifierReleasedFirst() {
        var state = WindowModeState(); state.enter()
        XCTAssertEqual(state.handle(chord(4, shift: true), keyDown: true, bindings: bindings), .action(.shrinkWidth))
        state.leave()
        XCTAssertEqual(state.handle(chord(4), keyDown: false, bindings: bindings), .consumed)
        XCTAssertFalse(state.hasPendingKeyUps)
    }
    func testExitingWhileHoldingMovementKeyDoesNotLeakRepeatCharacters() {
        var state = WindowModeState(); state.enter()
        XCTAssertEqual(state.handle(chord(0), keyDown: true, bindings: bindings), .action(.moveLeft))
        XCTAssertEqual(state.handle(chord(53), keyDown: true, bindings: bindings), .exit)
        XCTAssertEqual(state.handle(chord(0), keyDown: true, isRepeat: true, bindings: bindings), .consumed)
        XCTAssertEqual(state.handle(chord(37), keyDown: true, bindings: bindings), .passThrough)
        XCTAssertEqual(state.handle(chord(0), keyDown: false, bindings: bindings), .consumed)
        XCTAssertEqual(state.handle(chord(0), keyDown: true, bindings: bindings), .passThrough)
    }
    func testStepMovementUsesOneThirtiethOfDisplayAndClampsToWorkArea() throws {
        let bounds = Rect(x: -1500, y: 25, width: 1500, height: 875)
        let grid = Rect(x: -1500, y: 0, width: 1500, height: 900)
        let current = Rect(x: -1400, y: 100, width: 600, height: 400)
        let moved = try XCTUnwrap(WindowAction.moveLeft.target(in: bounds, current: current, grid: grid))
        XCTAssertEqual(moved.x, -1450)
        let up = try XCTUnwrap(WindowAction.moveUp.target(in: bounds, current: current, grid: grid))
        XCTAssertEqual(up.y, 70)
        XCTAssertEqual(WindowAction.moveLeft.target(in: bounds, current: Rect(x: -1500, y: 25, width: 600, height: 400), grid: grid)?.x, -1500)
    }
    func testExpandShrinkKeepCenterAndSizePositive() throws {
        let bounds = Rect(x: 0, y: 0, width: 1500, height: 900)
        let current = Rect(x: 300, y: 200, width: 600, height: 400)
        let expanded = try XCTUnwrap(WindowAction.expand.target(in: bounds, current: current))
        XCTAssertEqual(expanded, Rect(x: 250, y: 170, width: 700, height: 460))
        XCTAssertEqual(WindowAction.shrink.target(in: bounds, current: expanded), current)
        let tiny = Rect(x: 200, y: 200, width: 90, height: 70)
        let shrunken = try XCTUnwrap(WindowAction.shrink.target(in: bounds, current: tiny))
        XCTAssertTrue(shrunken.isValid)
        XCTAssertEqual(shrunken.width, 80)
        XCTAssertEqual(shrunken.height, 60)
    }
    func testOneSidedResizeKeepsLeftAndTopEdgesAndOtherDimensionFixed() throws {
        let bounds = Rect(x: -1500, y: -900, width: 1500, height: 900)
        let current = Rect(x: -1000, y: -600, width: 600, height: 400)
        for action in [WindowAction.shrinkWidth, .growWidth, .shrinkHeight, .growHeight] {
            let resized = try XCTUnwrap(action.target(in: bounds, current: current))
            XCTAssertEqual(resized.x, current.x)
            XCTAssertEqual(resized.y, current.y)
            if action == .shrinkWidth || action == .growWidth { XCTAssertEqual(resized.height, current.height) }
            else { XCTAssertEqual(resized.width, current.width) }
        }
        XCTAssertEqual(WindowAction.shrinkWidth.target(in: bounds, current: current)?.width, 550)
        XCTAssertEqual(WindowAction.growWidth.target(in: bounds, current: current)?.width, 650)
        XCTAssertEqual(WindowAction.shrinkHeight.target(in: bounds, current: current)?.height, 370)
        XCTAssertEqual(WindowAction.growHeight.target(in: bounds, current: current)?.height, 430)
    }
    func testOneSidedExpansionAtBoundaryStopsInsteadOfMovingFixedEdge() {
        let bounds = Rect(x: -1500, y: -900, width: 1500, height: 900)
        let atRight = Rect(x: -600, y: -600, width: 600, height: 400)
        XCTAssertEqual(WindowAction.growWidth.target(in: bounds, current: atRight), atRight)
        let atBottom = Rect(x: -1000, y: -400, width: 600, height: 400)
        XCTAssertEqual(WindowAction.growHeight.target(in: bounds, current: atBottom), atBottom)
    }
    func testOneSidedExpansionUsesRemainingSpaceWithoutMovingAnchor() throws {
        let bounds = Rect(x: 0, y: 25, width: 1500, height: 875)
        let current = Rect(x: 880, y: 490, width: 600, height: 400)
        let wider = try XCTUnwrap(WindowAction.growWidth.target(in: bounds, current: current))
        XCTAssertEqual(wider, Rect(x: 880, y: 490, width: 620, height: 400))
        let taller = try XCTUnwrap(WindowAction.growHeight.target(in: bounds, current: current))
        XCTAssertEqual(taller, Rect(x: 880, y: 490, width: 600, height: 410))
    }
    func testShrinkingSmallWindowNeverEnlargesItOrChangesItsAnchor() {
        let bounds = Rect(x: 0, y: 0, width: 1500, height: 900)
        let tiny = Rect(x: 100, y: 100, width: 60, height: 40)
        XCTAssertEqual(WindowAction.shrinkWidth.target(in: bounds, current: tiny), tiny)
        XCTAssertEqual(WindowAction.shrinkHeight.target(in: bounds, current: tiny), tiny)
    }
    func testDirectionalScreenMovementSupportsAboveAndBelowInsteadOfCycling() {
        let main = screen("main", x: 0, y: 0)
        let above = screen("above", x: 0, y: -900)
        let left = screen("left", x: -1440, y: 0)
        let below = screen("below", x: 0, y: 900)
        let displays = [main, left, above, below]
        XCTAssertEqual(WindowAction.screenUp.destinationDisplay(from: main, in: displays)?.id, "above")
        XCTAssertEqual(WindowAction.screenLeft.destinationDisplay(from: main, in: displays)?.id, "left")
        XCTAssertEqual(WindowAction.screenDown.destinationDisplay(from: main, in: displays)?.id, "below")
        XCTAssertNil(WindowAction.screenRight.destinationDisplay(from: main, in: displays))
    }
}
