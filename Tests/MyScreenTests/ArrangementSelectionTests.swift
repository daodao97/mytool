import XCTest
import MyScreenCore
@testable import MyScreen

final class ArrangementSelectionTests: XCTestCase {
    private let screen = DisplayInfo(id: "external", name: "External",
        frame: Rect(x: -1200, y: -900, width: 1200, height: 900),
        workArea: Rect(x: -1200, y: -876, width: 1200, height: 876), isBuiltIn: false, isMain: false)

    func testShownPreviewRemainsApplicableWhenReleasedNearItsPointer() {
        let target = Rect(x: -1200, y: -876, width: 600, height: 876)
        let selection = ArrangementSelection(preview: .init(frame: target, action: .left), pointer: CGPoint(x: -1190, y: -500))
        XCTAssertTrue(selection.applies(at: CGPoint(x: -1191, y: -499), displays: [screen]))
        XCTAssertEqual(selection.preview.frame, target)
    }

    func testDistantReleaseAndDisplayChangesInvalidateStalePreview() {
        let selection = ArrangementSelection(preview: .init(frame: screen.workArea, action: .maximize), pointer: CGPoint(x: -600, y: -890))
        XCTAssertFalse(selection.applies(at: CGPoint(x: -600, y: -500), displays: [screen]))
        XCTAssertFalse(selection.applies(at: selection.pointer, displays: []))
        var resized = screen
        resized.workArea.width = 800
        XCTAssertFalse(selection.applies(at: selection.pointer, displays: [resized]))
    }
}
