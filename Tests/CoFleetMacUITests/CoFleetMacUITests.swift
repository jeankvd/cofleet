import XCTest

final class CoFleetMacUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCleanLaunchShowsPairingOnboarding() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-cofleetUITesting", "YES"]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["cofleet.root"].waitForExistence(timeout: 8),
            "The root CoFleet window did not appear."
        )
        XCTAssertTrue(app.textFields["cofleet.onboarding.endpoint"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["cofleet.onboarding.code"].exists)
        XCTAssertTrue(app.buttons["cofleet.onboarding.pair"].exists)
    }
}
