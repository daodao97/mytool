import XCTest
@testable import MyScreenCore

final class LayoutStabilityTests: XCTestCase {
    private func layout(x: Double = 50, width: Double = 600) -> LayoutProfile {
        let display = DisplayInfo(id: "internal", name: "Built-in", frame: Rect(x: 0, y: 0, width: 1440, height: 900),
                                  workArea: Rect(x: 0, y: 25, width: 1440, height: 875), isBuiltIn: true, isMain: true)
        let window = WindowRecord(id: "editor-window", bundleID: "test.editor", appName: "Editor", title: "A",
                                  ordinal: 0, displayID: display.id, frame: Rect(x: x, y: 50, width: width, height: 400))
        return LayoutProfile(name: "Laptop", isAutomatic: true, displays: [display], windows: [window])
    }

    func testSavesOnlyAfterTwoSecondsOfUnchangedGeometry() {
        var tracker = LayoutStabilityTracker()
        XCTAssertNil(tracker.observe(layout(), at: 0))
        XCTAssertNil(tracker.observe(layout(), at: 1.99))
        XCTAssertEqual(tracker.observe(layout(), at: 2)?.windows.first?.frame, layout().windows.first?.frame)
    }

    func testMovingAndResizingRestartQuietPeriod() {
        var tracker = LayoutStabilityTracker()
        XCTAssertNil(tracker.observe(layout(), at: 0))
        XCTAssertNil(tracker.observe(layout(x: 100), at: 1))
        XCTAssertNil(tracker.observe(layout(x: 200), at: 2))
        XCTAssertNil(tracker.observe(layout(x: 200, width: 700), at: 3))
        XCTAssertNil(tracker.observe(layout(x: 200, width: 700), at: 4.99))
        XCTAssertEqual(tracker.observe(layout(x: 200, width: 700), at: 5)?.windows.first?.frame.width, 700)
    }

    func testPausingDuringADragDoesNotSaveUntilMouseReleasedAndSettled() {
        var tracker = LayoutStabilityTracker()
        XCTAssertNil(tracker.observe(layout(), at: 0))
        XCTAssertNil(tracker.observe(layout(), at: 1, isInteracting: true))
        XCTAssertNil(tracker.observe(layout(), at: 20, isInteracting: true))
        XCTAssertNil(tracker.observe(layout(), at: 21))
        XCTAssertNil(tracker.observe(layout(), at: 22.99))
        XCTAssertNotNil(tracker.observe(layout(), at: 23))
    }

    func testTitleChangesAndEnumerationOrderDoNotDelaySaving() throws {
        var tracker = LayoutStabilityTracker()
        var original = layout()
        var second = original.windows[0]; second.id = "second-window"; second.ordinal = 1
        original.windows.append(second)
        XCTAssertNil(tracker.observe(original, at: 0))
        var changed = original
        changed.windows.reverse()
        changed.windows[1].title = "Edited document"
        changed.windows[1].ordinal = 1
        XCTAssertNil(tracker.observe(changed, at: 1))
        let ready = try XCTUnwrap(tracker.observe(changed, at: 2))
        XCTAssertEqual(ready.windows[1].title, "Edited document")
    }

    func testAddedWindowAndChangedScreenWorkAreaRestartQuietPeriod() {
        var tracker = LayoutStabilityTracker()
        var original = layout()
        XCTAssertNil(tracker.observe(original, at: 0))
        var added = original.windows[0]; added.id = "new-window"
        original.windows.append(added)
        XCTAssertNil(tracker.observe(original, at: 1))
        XCTAssertNil(tracker.observe(original, at: 2))
        original.displays[0].workArea.height -= 50
        XCTAssertNil(tracker.observe(original, at: 3))
        XCTAssertNil(tracker.observe(original, at: 4))
        XCTAssertNotNil(tracker.observe(original, at: 5))
    }

    func testIncompleteAndEmptyScansRequireFreshStableObservations() {
        var tracker = LayoutStabilityTracker()
        XCTAssertNil(tracker.observe(layout(), at: 0))
        XCTAssertNil(tracker.observe(layout(), at: 2, isComplete: false))
        XCTAssertNil(tracker.observe(layout(), at: 3))
        XCTAssertNil(tracker.observe(layout(), at: 4))
        XCTAssertNotNil(tracker.observe(layout(), at: 5))
        var empty = layout(); empty.windows = []
        XCTAssertNil(tracker.observe(empty, at: 6))
        XCTAssertNil(tracker.observe(layout(), at: 7))
        XCTAssertNotNil(tracker.observe(layout(), at: 9))
    }

    func testScreenTransitionResetDiscardsOldQuietPeriod() {
        var tracker = LayoutStabilityTracker()
        XCTAssertNil(tracker.observe(layout(), at: 0))
        tracker.reset()
        XCTAssertNil(tracker.observe(layout(), at: 10))
        XCTAssertNil(tracker.observe(layout(), at: 11))
        XCTAssertNotNil(tracker.observe(layout(), at: 12))
    }

    func testUnstableAndIncompleteSamplesCannotReplacePersistedLayout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LayoutStore(url: directory.appendingPathComponent("layouts.json"))
        try store.load()
        let original = layout()
        try store.replace([original])
        var tracker = LayoutStabilityTracker()
        let samples: [(Double, Double, Bool)] = [(0, 100, true), (1, 200, true), (2, 300, true), (4, 300, false)]
        for (time, x, complete) in samples {
            if let ready = tracker.observe(layout(x: x), at: time, isComplete: complete) {
                try store.replace([ready])
            }
        }
        XCTAssertEqual(store.archive.profiles.first?.windows.first?.frame.x, 50)
        XCTAssertNil(tracker.observe(layout(x: 300), at: 5))
        if let ready = tracker.observe(layout(x: 300), at: 7) { try store.replace([ready]) }
        let reopened = LayoutStore(url: store.url); try reopened.load()
        XCTAssertEqual(reopened.archive.profiles.first?.windows.first?.frame.x, 300)
    }
}
