import XCTest

final class CoFleetIOSUITests: XCTestCase {
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
            "The root CoFleet surface did not appear."
        )
        XCTAssertTrue(app.textFields["cofleet.onboarding.endpoint"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["cofleet.onboarding.code"].exists)
        XCTAssertTrue(app.buttons["cofleet.onboarding.pair"].exists)
    }

    @MainActor
    func testPairingDraftSurvivesBackgrounding() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-cofleetUITesting", "YES"]
        app.launch()

        let codeField = app.textFields["cofleet.onboarding.code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 8))
        codeField.tap()
        codeField.typeText("ABCDEFGH23")

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(codeField.waitForExistence(timeout: 8))
        XCTAssertEqual(codeField.value as? String, "ABCDEFGH23")
    }
}
