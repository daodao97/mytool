import XCTest
@testable import MyScreenCore

final class WindowRecoveryMatchingTests: XCTestCase {
    private let laptop = DisplayInfo(id: "internal", name: "Laptop", frame: Rect(x: 0, y: 0, width: 1512, height: 982),
        workArea: Rect(x: 0, y: 34, width: 1512, height: 948), isBuiltIn: true, isMain: true)
    private let external = DisplayInfo(id: "external", name: "Desk", frame: Rect(x: -495, y: -1440, width: 2560, height: 1440),
        workArea: Rect(x: -495, y: -1440, width: 2560, height: 1440), isBuiltIn: false, isMain: false)

    private func window(_ id: String, title: String, ordinal: Int, frame: Rect,
                        display: String = "external", systemID: String? = nil, document: String = "") -> WindowRecord {
        WindowRecord(id: id, bundleID: "com.google.Chrome", appName: "Chrome", title: title, document: document,
                     ordinal: ordinal, displayID: display, frame: frame, systemID: systemID)
    }

    func testSystemIdentitySurvivesTitleChangesAndWindowReorderingAcrossMyScreenRestart() {
        let frame = laptop.workArea
        let saved = [window("old-a", title: "Page A", ordinal: 0, frame: frame, systemID: "123:100:45"),
                     window("old-b", title: "Page B", ordinal: 1, frame: frame, systemID: "123:100:46")]
        let live = [window("new-b", title: "Page A", ordinal: 0, frame: frame, systemID: "123:100:46"),
                    window("new-a", title: "Different tab", ordinal: 1, frame: frame, systemID: "123:100:45")]
        let pairs = WindowMatcher.match(saved: saved, live: live, recoveringLayout: true, displays: [laptop, external])
        XCTAssertEqual(pairs.first(where: { $0.saved == 0 })?.live, 1)
        XCTAssertEqual(pairs.first(where: { $0.saved == 1 })?.live, 0)
    }

    func testLegacyChromeLayoutMigratesChangedTitlesUsingDistinctClampedWindowSizes() throws {
        let left = window("old-left", title: "Old dashboard", ordinal: 0,
                          frame: Rect(x: -495, y: -1440, width: 1728, height: 1440), document: "https://example.test/old-dashboard")
        let right = window("old-right", title: "Old video", ordinal: 1,
                           frame: Rect(x: 1234, y: -1440, width: 831, height: 1440), document: "https://example.test/old-video")
        let repo = window("old-repo", title: "Repository", ordinal: 2, frame: laptop.workArea, display: "internal")
        let live = [window("new-right", title: "Different video", ordinal: 0,
                           frame: right.frame.constrained(to: laptop.workArea), display: "internal", systemID: "right", document: "https://example.test/new-video"),
                    window("new-left", title: "Different dashboard", ordinal: 1,
                           frame: left.frame.constrained(to: laptop.workArea), display: "internal", systemID: "left", document: "https://example.test/new-dashboard"),
                    window("new-repo", title: "Repository", ordinal: 2, frame: laptop.workArea, display: "internal", systemID: "repo")]
        let pairs = WindowMatcher.match(saved: [left, right, repo], live: live, recoveringLayout: true, displays: [laptop, external])
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(pairs.first(where: { $0.saved == 0 })?.live, 1)
        XCTAssertEqual(pairs.first(where: { $0.saved == 1 })?.live, 0)
        XCTAssertEqual(pairs.first(where: { $0.saved == 2 })?.live, 2)
        let profile = LayoutProfile(name: "Desk", isAutomatic: true, displays: [laptop, external], windows: [left, right, repo])
        var restored = live
        for pair in pairs {
            restored[pair.live].frame = try XCTUnwrap(profile.destination(for: profile.windows[pair.saved], on: profile.displays))
            restored[pair.live].displayID = profile.windows[pair.saved].displayID
        }
        XCTAssertTrue(LayoutRestoreVerification(profile: profile, displays: profile.displays, live: restored, isComplete: true).canResumeAutomaticCapture)
    }

    func testFallbackCannotStealWindowFromExactDocumentMatch() {
        let saved = [window("old", title: "Old tab", ordinal: 0, frame: laptop.workArea),
                     window("document", title: "Keep", ordinal: 1, frame: laptop.workArea, document: "file:///keep")]
        let live = [window("current", title: "Keep edited", ordinal: 0, frame: laptop.workArea, document: "file:///keep")]
        let pairs = WindowMatcher.match(saved: saved, live: live, recoveringLayout: true)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.saved, 1)
    }

    func testChangedBrowserTabsRecoverRemainingSlotsAfterOneWindowCloses() {
        let saved = [
            window("left", title: "Old left tab", ordinal: 0,
                   frame: Rect(x: -495, y: -1440, width: 1728, height: 1440), systemID: "old:0", document: "https://example.test/left"),
            window("right", title: "Old right tab", ordinal: 1,
                   frame: Rect(x: 1234, y: -1440, width: 831, height: 1440), systemID: "old:1", document: "https://example.test/right"),
            window("closed", title: "Closed tab", ordinal: 2, frame: laptop.workArea, display: "internal", systemID: "old:2")
        ]
        let live = [
            window("new-right", title: "New right tab", ordinal: 1,
                   frame: Rect(x: 459, y: 34, width: 1053, height: 948), display: "internal", systemID: "new:1", document: "https://example.test/other-right"),
            window("new-left", title: "New left tab", ordinal: 0,
                   frame: Rect(x: 0, y: 34, width: 1506, height: 948), display: "internal", systemID: "new:0", document: "https://example.test/other-left")
        ]
        let pairs = WindowMatcher.match(saved: saved, live: live, recoveringLayout: true, displays: [laptop, external])
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.first(where: { $0.saved == 0 })?.live, 1)
        XCTAssertEqual(pairs.first(where: { $0.saved == 1 })?.live, 0)
        XCTAssertNil(pairs.first(where: { $0.saved == 2 }))
        XCTAssertTrue(WindowMatcher.match(saved: saved, live: live).isEmpty)
        let profile = LayoutProfile(name: "Desk", isAutomatic: true, displays: [laptop, external], windows: saved)
        var restored = live
        for pair in pairs { restored[pair.live].frame = saved[pair.saved].frame }
        let check = LayoutRestoreVerification(profile: profile, displays: profile.displays, live: restored, isComplete: true)
        XCTAssertEqual(check.missingCount, 1)
        XCTAssertEqual(check.unresolvedCount, 0)
        XCTAssertTrue(check.canResumeAutomaticCapture)
    }

    func testUnequalWindowCountsStillReserveStrongMatchesBeforeSlotFallback() {
        let saved = [window("old", title: "Old tab", ordinal: 0, frame: laptop.workArea),
                     window("exact", title: "Old exact", ordinal: 1, frame: laptop.workArea, systemID: "same"),
                     window("closed", title: "Closed", ordinal: 2, frame: laptop.workArea)]
        let live = [window("exact-now", title: "Changed", ordinal: 0, frame: laptop.workArea, systemID: "same"),
                    window("new", title: "New tab", ordinal: 2, frame: laptop.workArea)]
        let pairs = WindowMatcher.match(saved: saved, live: live, recoveringLayout: true)
        XCTAssertEqual(pairs.first(where: { $0.saved == 1 })?.live, 0)
        XCTAssertEqual(pairs.first(where: { $0.saved == 2 })?.live, 1)
    }

    func testUnequalWindowCountsDoNotPairConflictingFileDocumentsBySlot() {
        let saved = [window("old", title: "Old file", ordinal: 0, frame: laptop.workArea, document: "file:///old"),
                     window("closed", title: "Closed", ordinal: 1, frame: Rect(x: 0, y: 34, width: 500, height: 400))]
        let live = [window("new", title: "New file", ordinal: 0, frame: laptop.workArea, document: "file:///new")]
        XCTAssertTrue(WindowMatcher.match(saved: saved, live: live, recoveringLayout: true, displays: [laptop]).isEmpty)
    }

    func testDuplicateOrdinalsCannotGuessSlotsWhenWindowCountsDiffer() {
        let saved = [window("a", title: "Old A", ordinal: 0, frame: laptop.workArea),
                     window("b", title: "Old B", ordinal: 0, frame: laptop.workArea),
                     window("c", title: "Old C", ordinal: 1, frame: laptop.workArea)]
        let live = [window("x", title: "New X", ordinal: 0, frame: laptop.workArea),
                    window("y", title: "New Y", ordinal: 0, frame: laptop.workArea)]
        XCTAssertTrue(WindowMatcher.match(saved: saved, live: live, recoveringLayout: true, displays: [laptop]).isEmpty)
    }

    func testConflictingDocumentsAreNeverMatchedByGeometryOrAppWindowOrder() {
        let old = window("old", title: "Old", ordinal: 0, frame: laptop.workArea, document: "file:///old")
        let new = window("new", title: "New", ordinal: 0, frame: laptop.workArea, document: "file:///new")
        XCTAssertTrue(WindowMatcher.match(saved: [old], live: [new], recoveringLayout: true, displays: [laptop]).isEmpty)
    }

    func testStillOpenUnmatchedWindowKeepsLayoutProtected() {
        let kept = window("kept", title: "Keep", ordinal: 0, frame: laptop.workArea, display: "internal")
        let old = window("old", title: "Old document", ordinal: 1, frame: laptop.workArea, document: "file:///old")
        let new = window("new", title: "Different document", ordinal: 1, frame: laptop.workArea, document: "file:///new")
        let profile = LayoutProfile(name: "Desk", isAutomatic: true, displays: [laptop, external], windows: [kept, old])
        let check = LayoutRestoreVerification(profile: profile, displays: profile.displays, live: [kept, new], isComplete: true)
        XCTAssertEqual(check.unresolvedCount, 1)
        XCTAssertFalse(check.canResumeAutomaticCapture)
    }

    func testOldArchivesDecodeWithoutSystemIdentityAndNewIdentityPersists() throws {
        var record = window("a", title: "A", ordinal: 0, frame: laptop.workArea)
        let original = try JSONEncoder().encode(record)
        XCTAssertNil(try JSONDecoder().decode(WindowRecord.self, from: original).systemID)
        record.systemID = "pid:launch:window"
        XCTAssertEqual(try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(record)).systemID, record.systemID)
    }

    func testMinimumWindowWidthMayClampAtExternalDisplayRightEdge() {
        let saved = window("right", title: "Browser", ordinal: 0,
                           frame: Rect(x: 1234, y: -1440, width: 831, height: 1440))
        let profile = LayoutProfile(name: "Desk", isAutomatic: true, displays: [laptop, external], windows: [saved])
        var live = saved
        live.frame = Rect(x: 1097, y: -1440, width: 968, height: 1440)
        XCTAssertTrue(LayoutRestoreVerification(profile: profile, displays: profile.displays, live: [live], isComplete: true,
                                                constrainedFrames: [saved.id: live.frame]).canResumeAutomaticCapture)
        var bounced = live; bounced.frame = laptop.workArea; bounced.displayID = laptop.id
        XCTAssertFalse(LayoutRestoreVerification(profile: profile, displays: profile.displays, live: [bounced], isComplete: true,
                                                 constrainedFrames: [saved.id: live.frame]).canResumeAutomaticCapture)
    }
}
