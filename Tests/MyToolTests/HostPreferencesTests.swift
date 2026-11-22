import XCTest
@testable import MyTool

final class HostPreferencesTests: XCTestCase {
    @MainActor
    func testAppearanceChangeWaitsForBindingSetterToReturn() async {
        let defaults = makeDefaults()
        let preferences = HostPreferences(defaults: defaults)
        let applied = expectation(description: "Appearance applied after the setter")
        var insideSetter = true
        preferences.applyAppearance = {
            XCTAssertFalse(insideSetter)
            XCTAssertFalse(preferences.showDockIcon)
            applied.fulfill()
        }

        preferences.showDockIcon = false
        XCTAssertFalse(defaults.bool(forKey: "showDockIcon"))
        insideSetter = false
        await fulfillment(of: [applied], timeout: 1)
        preferences.applyAppearance = nil
    }

    @MainActor
    func testRapidChangesApplyLatestAppearanceOnceAndAllowAnotherUpdate() async {
        let preferences = HostPreferences(defaults: makeDefaults())
        let first = expectation(description: "Coalesced appearance update")
        var calls = 0
        preferences.applyAppearance = {
            calls += 1
            XCTAssertTrue(preferences.showDockIcon)
            XCTAssertFalse(preferences.showMenuBarIcon)
            first.fulfill()
        }
        preferences.showDockIcon = false
        preferences.showMenuBarIcon = false
        preferences.showDockIcon = true
        XCTAssertEqual(calls, 0)
        await fulfillment(of: [first], timeout: 1)
        XCTAssertEqual(calls, 1)

        let second = expectation(description: "Subsequent appearance update")
        preferences.applyAppearance = {
            calls += 1
            XCTAssertFalse(preferences.showDockIcon)
            second.fulfill()
        }
        preferences.showDockIcon = false
        await fulfillment(of: [second], timeout: 1)
        XCTAssertEqual(calls, 2)
        preferences.applyAppearance = nil
    }

    private func makeDefaults() -> UserDefaults {
        let name = "MyToolTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
