import XCTest
@testable import MyScreenCore

final class DisplayRecoveryTests: XCTestCase {
    private var laptop: DisplayInfo {
        DisplayInfo(id: "internal", name: "Laptop", frame: Rect(x: 0, y: 0, width: 1440, height: 900),
                    workArea: Rect(x: 0, y: 25, width: 1440, height: 875), isBuiltIn: true, isMain: true)
    }
    private var external: DisplayInfo {
        DisplayInfo(id: "external", name: "Desk", frame: Rect(x: -500, y: -1440, width: 2560, height: 1440),
                    workArea: Rect(x: -500, y: -1440, width: 2560, height: 1440), isBuiltIn: false, isMain: false)
    }
    private var layout: LayoutProfile {
        let window = WindowRecord(id: "editor", bundleID: "test.editor", appName: "Editor", title: "Document",
                                  ordinal: 0, displayID: external.id, frame: Rect(x: -400, y: -1400, width: 1000, height: 900))
        return LayoutProfile(name: "Desk", isAutomatic: true, displays: [laptop, external], windows: [window])
    }

    func testQuickUnplugReplugRestoresEvenWhenFinalScreensAreIdentical() {
        var tracker = DisplayTransitionTracker()
        XCTAssertTrue(tracker.finish(displays: layout.displays))
        tracker.begin(requiresRecovery: true) // CG begin; NSScreen can still report the old screens.
        tracker.begin() // Later AppKit notifications must not erase the hardware event.
        XCTAssertTrue(tracker.finish(displays: layout.displays))
        XCTAssertFalse(tracker.finish(displays: layout.displays))
    }

    func testKnownHomePreservesItsPositionsAndAdaptsAdditionalOfficeWindows() throws {
        var home = external; home.id = "home"; home.frame.x += 300; home.workArea.x += 300
        var known = layout.windows[0]; known.displayID = home.id
        known.frame = Rect(x: home.workArea.x, y: home.workArea.y, width: 800, height: 900)
        var additional = layout.windows[0]; additional.id = "new-browser"; additional.bundleID = "test.browser"
        additional.frame.x += 1100
        let remembered = LayoutProfile(name: "Home", isAutomatic: true, updatedAt: Date(timeIntervalSince1970: 100),
                                       displays: [laptop, home], windows: [known])
        let office = LayoutProfile(name: "Office", isAutomatic: true, updatedAt: Date(timeIntervalSince1970: 200),
                                   displays: layout.displays, windows: [layout.windows[0], additional])
        for previous in [nil, office] as [LayoutProfile?] {
            guard case .remembered(let result) = LayoutRecovery.resolve(displays: [home, laptop],
                profiles: [remembered, office], previous: previous) else { return XCTFail("Use remembered home") }
            XCTAssertEqual(result.id, remembered.id)
            XCTAssertEqual(result.windows.count, 2)
            XCTAssertEqual(result.windows[0].frame, known.frame)
            XCTAssertEqual(result.windows[1].displayID, home.id)
            XCTAssertEqual(result.windows[1].frame, office.destination(for: additional, on: [home, laptop]))
            XCTAssertEqual(Set(result.windows.map(\.id)).count, result.windows.count)
            XCTAssertTrue(result.windows.allSatisfy { record in result.displays.contains { $0.id == record.displayID } })
        }
    }

    func testSupplementDoesNotResurrectOlderOrNamedDeskWindows() {
        var home = layout; home.updatedAt = Date(timeIntervalSince1970: 200)
        var other = layout; other.displays[1].id = "office"; other.windows[0].displayID = "office"
        other.windows[0].bundleID = "other.app"; other.windows[0].id = "other"
        other.updatedAt = Date(timeIntervalSince1970: 100)
        var named = other; named.isAutomatic = false; named.updatedAt = Date(timeIntervalSince1970: 300)
        guard case .remembered(let result) = LayoutRecovery.resolve(displays: home.displays,
            profiles: [home, other, named], previous: nil) else { return XCTFail("Use home memory") }
        XCTAssertEqual(result, home)
    }

    func testChangedBrowserTitleDoesNotDuplicateExistingHomeSlot() {
        var home = layout; home.updatedAt = Date(timeIntervalSince1970: 100)
        home.windows[0].bundleID = "com.google.Chrome"
        var office = home; office.updatedAt = Date(timeIntervalSince1970: 200)
        office.displays[1].id = "office"; office.windows[0].displayID = "office"
        office.windows[0].id = "new-runtime"; office.windows[0].title = "Another tab"
        guard case .remembered(let result) = LayoutRecovery.resolve(displays: home.displays,
            profiles: [home, office], previous: nil) else { return XCTFail("Use home memory") }
        XCTAssertEqual(result.windows, home.windows)
    }

    func testSecondBrowserWindowIsCarriedOverWithoutMovingKnownHomeWindow() {
        var home = layout; home.updatedAt = Date(timeIntervalSince1970: 100)
        home.windows[0].bundleID = "com.google.Chrome"
        home.windows[0].systemID = "chrome:1"
        var office = home; office.updatedAt = Date(timeIntervalSince1970: 200)
        office.displays[1].id = "office"; office.windows[0].displayID = "office"
        office.windows[0].frame.x += 200
        var second = office.windows[0]; second.id = "second"; second.systemID = "chrome:2"; second.ordinal = 1
        second.frame.x += 1000
        office.windows.append(second)
        guard case .remembered(let result) = LayoutRecovery.resolve(displays: home.displays,
            profiles: [home, office], previous: nil) else { return XCTFail("Use home memory") }
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows[0], home.windows[0])
        XCTAssertEqual(result.windows[1].systemID, second.systemID)
        XCTAssertEqual(result.windows[1].displayID, external.id)
        XCTAssertEqual(result.windows[1].frame, office.destination(for: second, on: home.displays))
    }

    func testWakeRequestSurvivesMultipleDebouncedNotifications() {
        var tracker = DisplayTransitionTracker()
        _ = tracker.finish(displays: layout.displays)
        tracker.begin(requiresRecovery: true)
        for _ in 0..<4 { tracker.begin() }
        XCTAssertTrue(tracker.finish(displays: layout.displays))
    }

    func testEmptyTransientDisplayListDoesNotConsumeRecoveryRequest() {
        var tracker = DisplayTransitionTracker()
        _ = tracker.finish(displays: layout.displays)
        tracker.begin(requiresRecovery: true)
        XCTAssertFalse(tracker.finish(displays: []))
        XCTAssertTrue(tracker.finish(displays: layout.displays))
    }

    func testCosmeticNotificationDoesNotRestoreUnchangedScreens() {
        var tracker = DisplayTransitionTracker()
        _ = tracker.finish(displays: layout.displays)
        tracker.begin()
        XCTAssertFalse(tracker.finish(displays: layout.displays))
        tracker.begin()
        XCTAssertTrue(tracker.finish(displays: [laptop]))
    }

    func testWindowServerMovingWindowBackToLaptopFailsDelayedVerification() {
        var live = layout.windows[0]
        live.displayID = laptop.id
        live.frame = Rect(x: 50, y: 50, width: 1000, height: 800)
        let check = LayoutRestoreVerification(profile: layout, displays: layout.displays, live: [live], isComplete: true)
        XCTAssertEqual(check.matchedCount, 1)
        XCTAssertEqual(check.misplacedCount, 1)
        XCTAssertFalse(check.canResumeAutomaticCapture)
    }

    func testIncompleteOrEmptyReadbackCannotResumeAutomaticSaving() {
        XCTAssertFalse(LayoutRestoreVerification(profile: layout, displays: layout.displays,
                                                live: layout.windows, isComplete: false).canResumeAutomaticCapture)
        let empty = LayoutRestoreVerification(profile: layout, displays: layout.displays, live: [], isComplete: true)
        XCTAssertEqual(empty.missingCount, 1)
        XCTAssertFalse(empty.canResumeAutomaticCapture)
        XCTAssertTrue(LayoutRestoreVerification(profile: layout, displays: layout.displays,
                                               live: layout.windows, isComplete: true).canResumeAutomaticCapture)
    }

    func testReadbackChecksSizeAndOnlyAllowsKnownApplicationConstraints() {
        var live = layout.windows[0]; live.frame.width += 120
        XCTAssertFalse(LayoutRestoreVerification(profile: layout, displays: layout.displays,
                                                live: [live], isComplete: true).canResumeAutomaticCapture)
        XCTAssertTrue(LayoutRestoreVerification(profile: layout, displays: layout.displays, live: [live], isComplete: true,
                                                constrainedFrames: [live.id: live.frame]).canResumeAutomaticCapture)
        var wrongPosition = live; wrongPosition.frame.y += 100
        XCTAssertFalse(LayoutRestoreVerification(profile: layout, displays: layout.displays, live: [wrongPosition], isComplete: true,
                                                 constrainedFrames: [live.id: live.frame]).canResumeAutomaticCapture)
    }

    func testClosedWindowDoesNotBlockRecoveryOfOpenWindows() {
        var saved = layout
        var second = saved.windows[0]; second.id = "second"; second.title = "Another document"
        saved.windows.append(second)
        let check = LayoutRestoreVerification(profile: saved, displays: saved.displays, live: layout.windows, isComplete: true)
        XCTAssertEqual(check.matchedCount, 1)
        XCTAssertEqual(check.missingCount, 1)
        XCTAssertEqual(check.unresolvedCount, 0)
        XCTAssertTrue(check.canResumeAutomaticCapture)
    }

    func testDisconnectVerificationUsesProjectedLaptopDestination() throws {
        var live = layout.windows[0]
        live.frame = try XCTUnwrap(layout.destination(for: live, on: [laptop]))
        live.displayID = laptop.id
        XCTAssertTrue(LayoutRestoreVerification(profile: layout, displays: [laptop], live: [live], isComplete: true).canResumeAutomaticCapture)
    }

    func testQuickReconnectRetainsSavedDeskGeometryUntilItIsVerified() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LayoutStore(url: folder.appendingPathComponent("layouts.json")); try store.load()
        try store.replace([layout])
        var transition = DisplayTransitionTracker(); _ = transition.finish(displays: layout.displays)
        transition.begin(requiresRecovery: true); transition.begin()
        XCTAssertTrue(transition.finish(displays: layout.displays))
        guard case .remembered(let pinned) = LayoutRecovery.resolve(displays: layout.displays, profiles: store.archive.profiles, previous: nil) else {
            return XCTFail("The saved desk layout must be selected on quick reconnect")
        }
        var displaced = pinned.windows[0]; displaced.frame = Rect(x: 30, y: 50, width: 1000, height: 800)
        displaced.displayID = laptop.id
        var stability = LayoutStabilityTracker()
        let wrong = LayoutProfile(name: "Desk", isAutomatic: true, displays: layout.displays, windows: [displaced])
        _ = stability.observe(wrong, at: 0)
        let stableButWrong = try XCTUnwrap(stability.observe(wrong, at: 3))
        let check = LayoutRestoreVerification(profile: pinned, displays: layout.displays, live: stableButWrong.windows, isComplete: true)
        XCTAssertFalse(check.canResumeAutomaticCapture, "Stable WindowServer fallback positions must not overwrite the desk layout")
        XCTAssertEqual(store.archive.profiles.first?.windows.first?.frame, pinned.windows.first?.frame)
    }

    func testTransitionCheckpointSurvivesSubsequentAutomaticSaves() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LayoutStore(url: folder.appendingPathComponent("layouts.json")); try store.load()
        try store.replace([layout]); try store.checkpoint()
        for index in 0..<4 {
            var changed = layout; changed.windows[0].frame.x += Double(index + 1) * 100
            try store.replace([changed])
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("history"), includingPropertiesForKeys: nil)
        let saved = try JSONDecoder().decode(LayoutArchive.self, from: Data(contentsOf: XCTUnwrap(files.first)))
        XCTAssertEqual(saved.profiles.first?.windows, layout.windows)
    }
}
