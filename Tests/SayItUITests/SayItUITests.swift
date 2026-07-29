import XCTest

final class SayItUITests: XCTestCase {
    @MainActor
    func testOnboardingContinuesInIndependentWindow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launch()

        let privacyTitle = app.staticTexts["Private by design"]
        XCTAssertTrue(privacyTitle.waitForExistence(timeout: 10))

        app.buttons["Continue"].click()

        XCTAssertTrue(
            app.staticTexts["Choose a voice"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.windows["Welcome to Say It"].exists)
    }
}
