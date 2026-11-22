import AppKit
import XCTest
@testable import MyScreen

@MainActor
final class WindowDragMonitorTests: XCTestCase {
    private func mouse(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 100), modifierFlags: flags,
            timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    func testClickDoesNotTriggerArrangement() {
        let monitor = WindowDragMonitor()
        var began = 0
        var ended: [Bool] = []
        var previews = 0
        monitor.onBegin = { _ in began += 1 }
        monitor.onChange = { _, _ in previews += 1 }
        monitor.onEnd = { moved, _ in ended.append(moved) }
        monitor.handle(mouse(.leftMouseDown))
        monitor.handle(mouse(.leftMouseUp))
        XCTAssertEqual(began, 1)
        XCTAssertEqual(previews, 0)
        XCTAssertEqual(ended, [false])
    }

    func testDragPreviewsAndOptionReleaseCancelsDrop() {
        let monitor = WindowDragMonitor()
        var options: [Bool] = []
        var ended: [Bool] = []
        monitor.onChange = { _, option in options.append(option) }
        monitor.onEnd = { moved, point in
            ended.append(moved)
            XCTAssertNotNil(point)
        }
        monitor.handle(mouse(.leftMouseDown))
        monitor.handle(mouse(.leftMouseDragged))
        monitor.handle(mouse(.leftMouseDragged, flags: .option))
        monitor.handle(mouse(.leftMouseUp, flags: .option))
        XCTAssertEqual(options, [false, true])
        XCTAssertEqual(ended, [false])
        monitor.handle(mouse(.leftMouseDown))
        monitor.handle(mouse(.leftMouseDragged))
        monitor.handle(mouse(.leftMouseUp))
        XCTAssertEqual(ended, [false, true])
    }

    func testModifierChangesUpdatePreviewWithoutMouseMovement() {
        let monitor = WindowDragMonitor()
        var options: [Bool] = []
        monitor.onChange = { _, option in options.append(option) }
        monitor.handle(mouse(.leftMouseDown))
        monitor.handle(mouse(.leftMouseDragged))
        let optionDown = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .option,
            timestamp: 1, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 58)!
        let optionUp = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
            timestamp: 2, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 58)!
        monitor.handle(optionDown)
        monitor.handle(optionUp)
        XCTAssertEqual(options, [false, true, false])
        monitor.handle(mouse(.leftMouseUp))
        monitor.handle(optionDown)
        XCTAssertEqual(options, [false, true, false])
    }

    func testMissingMouseUpCommitsOnceUsingPhysicalRelease() {
        var input = WindowDragMonitor.InputState(leftButtonDown: true, point: CGPoint(x: 10, y: 400), optionHeld: false)
        let monitor = WindowDragMonitor(readInput: { input })
        var endings: [(Bool, CGPoint?)] = []
        monitor.onEnd = { endings.append(($0, $1)) }
        monitor.handle(mouse(.leftMouseDown))
        monitor.handle(mouse(.leftMouseDragged))
        monitor.poll()
        XCTAssertTrue(endings.isEmpty)
        input.leftButtonDown = false
        monitor.poll()
        XCTAssertEqual(endings.count, 1)
        XCTAssertTrue(endings[0].0)
        XCTAssertEqual(endings[0].1, input.point)
        // A delayed native event must not apply the same drop twice.
        monitor.handle(mouse(.leftMouseUp))
        monitor.poll()
        XCTAssertEqual(endings.count, 1)
    }

    func testPhysicalReleaseRespectsOptionAndDoesNotArrangeClicks() {
        var input = WindowDragMonitor.InputState(leftButtonDown: true, point: CGPoint(x: 10, y: 400), optionHeld: true)
        let monitor = WindowDragMonitor(readInput: { input })
        var endings: [Bool] = []
        monitor.onEnd = { moved, _ in endings.append(moved) }
        monitor.handle(mouse(.leftMouseDown))
        monitor.handle(mouse(.leftMouseDragged))
        input.leftButtonDown = false
        monitor.poll()
        XCTAssertEqual(endings, [false])
        input.optionHeld = false
        input.leftButtonDown = true
        monitor.handle(mouse(.leftMouseDown))
        input.leftButtonDown = false
        monitor.poll()
        XCTAssertEqual(endings, [false, false])
    }

    func testNativeResizeIsTrackedWhenWindowServerConsumesAllDragEvents() {
        let down = mouse(.leftMouseDown)
        let start = down.cgEvent!.location
        var input = WindowDragMonitor.InputState(leftButtonDown: true, point: start, optionHeld: false)
        let monitor = WindowDragMonitor(readInput: { input })
        var changes = 0
        var endings: [Bool] = []
        monitor.onChange = { _, _ in changes += 1 }
        monitor.onEnd = { moved, _ in endings.append(moved) }
        monitor.handle(down)
        monitor.poll()
        XCTAssertEqual(changes, 0)
        input.point = CGPoint(x: start.x + 80, y: start.y)
        monitor.poll()
        XCTAssertEqual(changes, 1)
        input.leftButtonDown = false
        monitor.poll()
        XCTAssertEqual(endings, [true])
        monitor.handle(mouse(.leftMouseUp))
        XCTAssertEqual(endings, [true])
    }
}
