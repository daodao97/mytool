import XCTest
@testable import MyScreenCore

final class LayoutTests: XCTestCase {
    private func screen(_ id: String, x: Double = 0, y: Double = 0, width: Double = 1440, height: Double = 900, main: Bool = false) -> DisplayInfo {
        let frame = Rect(x: x, y: y, width: width, height: height)
        return DisplayInfo(id: id, name: id, frame: frame,
                           workArea: Rect(x: x, y: y + 25, width: width, height: height - 25), isBuiltIn: id == "internal", isMain: main)
    }
    private func window(_ id: String, title: String = "Document", document: String = "", identifier: String = "", ordinal: Int = 0, displayID: String = "external") -> WindowRecord {
        WindowRecord(id: id, bundleID: "test.editor", appName: "Editor", title: title,
                     document: document, axIdentifier: identifier, ordinal: ordinal,
                     displayID: displayID, frame: Rect(x: -1800, y: 100, width: 900, height: 650))
    }
    func testTopologyUsesStableIdentitiesIndependentOfOrderOrPosition() {
        let a = screen("internal", main: true), b = screen("external", x: -1920, width: 1920)
        let movedB = screen("external", x: 1440, width: 2560)
        XCTAssertEqual(DisplayInfo.topologyKey([a, b]), DisplayInfo.topologyKey([movedB, a]))
        XCTAssertNotEqual(DisplayInfo.topologyKey([a, b]), DisplayInfo.topologyKey([a, screen("different-external")]))
    }
    func testProjectionSupportsNegativeAndVerticallyStackedDisplays() {
        let source = Rect(x: -1920, y: -1055, width: 1920, height: 1055)
        let destination = Rect(x: 1440, y: 25, width: 2560, height: 1415)
        let frame = Rect(x: -1920, y: -1055, width: 960, height: 1055)
        XCTAssertEqual(frame.projected(from: source, to: destination), Rect(x: 1440, y: 25, width: 1280, height: 1415))
    }
    func testUnpluggedScreenProjectsWindowToRemainingMainDisplay() throws {
        let builtIn = screen("internal", main: true)
        let external = screen("external", x: -1920, width: 1920, height: 1080)
        let oldWindow = window("1")
        let profile = LayoutProfile(name: "Desk", isAutomatic: true, displays: [builtIn, external], windows: [oldWindow])
        let frame = try XCTUnwrap(profile.destination(for: oldWindow, on: [builtIn]))
        XCTAssertGreaterThanOrEqual(frame.x, builtIn.workArea.x)
        XCTAssertGreaterThanOrEqual(frame.y, builtIn.workArea.y)
        XCTAssertLessThanOrEqual(frame.maxX, builtIn.workArea.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, builtIn.workArea.maxY)
        let reconnected = try XCTUnwrap(profile.destination(for: oldWindow, on: [builtIn, external]))
        XCTAssertEqual(reconnected, oldWindow.frame)
    }
    func testOversizedWindowIsClampedInsideWorkArea() {
        let bounds = Rect(x: -1000, y: -700, width: 1000, height: 700)
        let frame = Rect(x: -3000, y: 200, width: 3000, height: 2000)
        XCTAssertEqual(frame.constrained(to: bounds), bounds)
    }
    func testInvalidGeometryIsRejectedAndProjectionDoesNotDivideByZero() {
        let target = Rect(x: 0, y: 25, width: 1440, height: 875)
        XCTAssertFalse(Rect(x: .nan, y: 0, width: 1, height: 1).isValid)
        XCTAssertEqual(target.projected(from: Rect(x: 0, y: 0, width: 0, height: 0), to: target), target)
    }
    func testHalfAndQuarterActionsRespectMenuBarAndNegativeCoordinates() throws {
        let bounds = Rect(x: -1920, y: 25, width: 1920, height: 1055)
        let right = try XCTUnwrap(WindowAction.right.target(in: bounds, current: bounds))
        XCTAssertEqual(right, Rect(x: -960, y: 25, width: 960, height: 1055))
        let bottom = try XCTUnwrap(WindowAction.bottomRight.target(in: bounds, current: bounds))
        XCTAssertEqual(bottom, Rect(x: -960, y: 552.5, width: 960, height: 527.5))
    }
    func testDocumentMatchSurvivesTitleChangesAndWindowReordering() {
        let saved = [window("old-a", title: "A", document: "file:///a", ordinal: 0), window("old-b", title: "B", document: "file:///b", ordinal: 1)]
        let live = [window("new-b", title: "B edited", document: "file:///b", ordinal: 0), window("new-a", title: "A edited", document: "file:///a", ordinal: 1)]
        let pairs = WindowMatcher.match(saved: saved, live: live)
        XCTAssertEqual(pairs.first(where: { $0.saved == 0 })?.live, 1)
        XCTAssertEqual(pairs.first(where: { $0.saved == 1 })?.live, 0)
    }
    func testStrongMatchCannotBeStolenByOrdinalFallback() {
        let saved = [window("a", title: "", ordinal: 0), window("b", title: "Keep", ordinal: 1)]
        let live = [window("b", title: "Keep", ordinal: 0)]
        let result = WindowMatcher.match(saved: saved, live: live)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.saved, 1)
    }
    func testDifferentTitledWindowsAreNotBlindlyMatched() {
        XCTAssertTrue(WindowMatcher.match(saved: [window("a", title: "Closed")], live: [window("b", title: "Unrelated")]).isEmpty)
    }
    func testConflictingDocumentsAreNotMatchedByGenericIdentifier() {
        XCTAssertTrue(WindowMatcher.match(
            saved: [window("old", document: "file:///old", identifier: "main")],
            live: [window("new", document: "file:///new", identifier: "main")]).isEmpty)
    }
    func testKnownCombinationWinsOnDisconnectAndReconnect() throws {
        let internalScreen = screen("internal", main: true), external = screen("external", x: -1920, width: 1920)
        let laptop = LayoutProfile(name: "Laptop", isAutomatic: true, displays: [internalScreen], windows: [window("a", displayID: "internal")])
        let desk = LayoutProfile(name: "Desk", isAutomatic: true, displays: [internalScreen, external], windows: [window("a")])
        guard case .remembered(let unplugged) = LayoutRecovery.resolve(displays: [internalScreen], profiles: [desk, laptop], previous: desk) else {
            return XCTFail("Disconnect must restore the laptop layout")
        }
        XCTAssertEqual(unplugged.id, laptop.id)
        guard case .remembered(let reconnected) = LayoutRecovery.resolve(displays: [external, internalScreen], profiles: [desk, laptop], previous: laptop) else {
            return XCTFail("Reconnect must restore the external display layout")
        }
        XCTAssertEqual(reconnected.id, desk.id)
    }
    func testNewCombinationAdaptsPreviousLayoutWithoutUsingNamedSnapshots() {
        let previous = LayoutProfile(name: "A", isAutomatic: true, displays: [screen("external")], windows: [window("a")])
        let newScreen = screen("different-external", main: true)
        let named = LayoutProfile(name: "Manual", isAutomatic: false, displays: [newScreen], windows: [window("b", displayID: newScreen.id)])
        guard case .adapted(let fallback) = LayoutRecovery.resolve(displays: [newScreen], profiles: [named, previous], previous: previous) else {
            return XCTFail("A fresh combination must adapt the previous stable layout")
        }
        XCTAssertEqual(fallback.id, previous.id)
        XCTAssertNil(LayoutRecovery.resolve(displays: [], profiles: [previous], previous: previous))
        XCTAssertNil(LayoutRecovery.resolve(displays: [newScreen], profiles: [], previous: nil))
    }
    func testReplacementExternalReceivesOfficeWindowsWhileLaptopRemainsMain() throws {
        let laptop = screen("internal", main: true)
        let office = screen("office", x: -1920, width: 1920, height: 1080)
        let home = screen("home", x: 1440, y: -500, width: 2560, height: 1440)
        var externalWindow = window("editor", displayID: office.id)
        externalWindow.frame = Rect(x: office.workArea.x, y: office.workArea.y,
                                    width: office.workArea.width / 2, height: office.workArea.height)
        var internalWindow = window("chat", displayID: laptop.id)
        internalWindow.frame = Rect(x: 100, y: 100, width: 600, height: 500)
        let saved = LayoutProfile(name: "Office", isAutomatic: true, displays: [laptop, office],
                                  windows: [externalWindow, internalWindow])
        let destination = try XCTUnwrap(saved.destination(for: externalWindow, on: [laptop, home]))
        XCTAssertEqual(destination, Rect(x: home.workArea.x, y: home.workArea.y,
                                         width: home.workArea.width / 2, height: home.workArea.height))
        XCTAssertEqual(saved.destination(for: internalWindow, on: [home, laptop]), internalWindow.frame)
        var live = [externalWindow, internalWindow]
        live[0].displayID = home.id; live[0].frame = destination
        XCTAssertTrue(LayoutRestoreVerification(profile: saved, displays: [laptop, home], live: live,
                                                isComplete: true).canResumeAutomaticCapture)
    }
    func testReplacementMappingPreservesExistingExternalAndIgnoresEnumerationOrder() {
        let laptop = screen("internal", main: true)
        let retained = screen("retained", x: -3000)
        let officeLeft = screen("office-left", x: -1440)
        let officeRight = screen("office-right", x: 1440)
        let homeLeft = screen("home-left", x: -1440)
        let homeRight = screen("home-right", x: 1440)
        let windows = [window("a", displayID: retained.id), window("b", displayID: officeLeft.id),
                       window("c", displayID: officeRight.id)]
        let saved = LayoutProfile(name: "Office", isAutomatic: true,
                                  displays: [officeRight, laptop, officeLeft, retained], windows: windows)
        let connected = [homeRight, retained, laptop, homeLeft]
        for (record, source, target) in [(windows[0], retained, retained), (windows[1], officeLeft, homeLeft),
                                         (windows[2], officeRight, homeRight)] {
            let expected = record.frame.projected(from: source.workArea, to: target.workArea)
            XCTAssertEqual(saved.destination(for: record, on: connected), expected)
            XCTAssertEqual(saved.destination(for: record, on: connected.reversed()), expected)
        }
    }
    func testNewHomeUsesOfficeLayoutAcrossLaptopSessionAndRestart() {
        let laptop = screen("internal", main: true), office = screen("office", x: -1440)
        let home = screen("home", x: 1440)
        let desk = LayoutProfile(name: "Office", isAutomatic: true, updatedAt: Date(timeIntervalSince1970: 100),
                                 displays: [laptop, office], windows: [window("a", displayID: office.id)])
        let portable = LayoutProfile(name: "Laptop", isAutomatic: true, updatedAt: Date(timeIntervalSince1970: 200),
                                     displays: [laptop], windows: [window("a", displayID: laptop.id)])
        for previous in [portable, nil] as [LayoutProfile?] {
            guard case .adapted(let selected) = LayoutRecovery.resolve(displays: [laptop, home],
                profiles: [desk, portable], previous: previous) else { return XCTFail("Must copy the office desk layout") }
            XCTAssertEqual(selected.id, desk.id)
        }
        let rememberedHome = LayoutProfile(name: "Home", isAutomatic: true, updatedAt: Date(timeIntervalSince1970: 50),
                                           displays: [laptop, home], windows: [window("a", displayID: home.id)])
        guard case .remembered(let selected) = LayoutRecovery.resolve(displays: [laptop, home],
            profiles: [desk, portable, rememberedHome], previous: portable) else { return XCTFail("Known home must win") }
        XCTAssertEqual(selected.id, rememberedHome.id)
    }
    func testNewDeskSelectsLatestComparableAutomaticLayout() {
        let laptop = screen("internal", main: true), office = screen("office"), home = screen("home")
        let first = LayoutProfile(name: "First", isAutomatic: true, updatedAt: Date(timeIntervalSince1970: 100),
                                  displays: [laptop, office], windows: [window("a", displayID: office.id)])
        var latest = first; latest.id = UUID(); latest.updatedAt = Date(timeIntervalSince1970: 200)
        var named = latest; named.id = UUID(); named.isAutomatic = false; named.updatedAt = Date(timeIntervalSince1970: 400)
        var otherLaptop = named; otherLaptop.isAutomatic = true
        otherLaptop.displays[0].id = "other-laptop"
        var twoExternals = otherLaptop; twoExternals.displays = [laptop, office, screen("second")]
        var empty = latest; empty.windows = []; empty.updatedAt = Date(timeIntervalSince1970: 500)
        guard case .adapted(let selected) = LayoutRecovery.resolve(displays: [laptop, home],
            profiles: [named, otherLaptop, twoExternals, empty, first, latest], previous: nil) else {
            return XCTFail("Must choose a comparable automatic layout")
        }
        XCTAssertEqual(selected.id, latest.id)
        var unsaved = latest; unsaved.id = UUID(); unsaved.updatedAt = Date(timeIntervalSince1970: 600)
        guard case .adapted(let selectedPrevious) = LayoutRecovery.resolve(displays: [laptop, home],
            profiles: [latest], previous: unsaved) else { return XCTFail("Must include the last stable layout") }
        XCTAssertEqual(selectedPrevious.id, unsaved.id)
    }
    func testOffscreenWindowUsesNearestDisplay() {
        let near = screen("near", main: true), far = screen("far", x: 5000)
        let frame = Rect(x: -900, y: 30, width: 400, height: 400)
        XCTAssertEqual(DisplayInfo.containing(frame, in: [near, far])?.id, near.id)
    }
    func testOneLiveWindowIsNeverRestoredTwice() {
        let result = WindowMatcher.match(saved: [window("a"), window("b")], live: [window("c")])
        XCTAssertEqual(result.count, 1)
    }
    func testDuplicateAXIdentifierDoesNotOverrideDistinctTitles() {
        let saved = [window("a", title: "Alpha", identifier: "generic", ordinal: 0), window("b", title: "Beta", identifier: "generic", ordinal: 1)]
        let live = [window("c", title: "Beta", identifier: "generic", ordinal: 0), window("d", title: "Alpha", identifier: "generic", ordinal: 1)]
        let pairs = WindowMatcher.match(saved: saved, live: live)
        XCTAssertEqual(pairs.first(where: { $0.saved == 0 })?.live, 1)
        XCTAssertEqual(pairs.first(where: { $0.saved == 1 })?.live, 0)
    }
    func testPersistenceRoundTripAndCorruptionRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layouts.json")
        let store = LayoutStore(url: url); try store.load()
        let first = LayoutProfile(name: "Office", isAutomatic: true, displays: [screen("external")], windows: [window("a")])
        try store.replace([first])
        var updated = first; updated.name = "Home"
        try store.replace([updated])
        let reopened = LayoutStore(url: url); try reopened.load()
        XCTAssertEqual(reopened.archive.profiles.first?.name, "Home")
        try Data("broken".utf8).write(to: url)
        let recovered = LayoutStore(url: url); try recovered.load()
        XCTAssertEqual(recovered.archive.profiles.first?.name, "Office")
        XCTAssertNotNil(recovered.recoveryMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("damaged").path))
    }
    func testCorruptArchiveWithoutBackupCannotBeOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layouts.json")
        let corrupt = Data("do not erase".utf8); try corrupt.write(to: url)
        let store = LayoutStore(url: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.replace([]))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
    func testFutureArchiveVersionIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layouts.json")
        let data = Data("{\"version\":99,\"profiles\":[]}".utf8); try data.write(to: url)
        try Data("{\"version\":1,\"profiles\":[]}".utf8).write(to: url.appendingPathExtension("backup"))
        let store = LayoutStore(url: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
