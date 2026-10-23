import AppKit
import XCTest

final class SayItUITests: XCTestCase {
    @MainActor
    func testLaunchOpensMainWindow() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingComplete", "YES",
            "-backgroundServiceUserDisabled", "YES"
        ]
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(app.windows["Say It"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["Voices"].firstMatch.exists)
    }

    @MainActor
    func testReopeningRestoresMainWindowWithoutRestarting() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingComplete", "YES",
            "-backgroundServiceUserDisabled", "YES"
        ]
        defer { app.terminate() }
        app.launch()

        let window = app.windows["Say It"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        app.descendants(matching: .any)["Voices"].firstMatch.click()
        XCTAssertTrue(app.popUpButtons["Model"].waitForExistence(timeout: 5))

        XCTAssertEqual(app.state, .runningForeground)
        let running = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        let url = try XCTUnwrap(running.bundleURL)
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        XCTAssertFalse(running.isTerminated, "Closing the window must keep hotkeys available")

        // Launch Services sends the same reopen event as Spotlight or Finder.
        let reopened = try await NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration()
        )
        XCTAssertEqual(reopened.processIdentifier, running.processIdentifier)
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(app.popUpButtons["Model"].exists, "Keep the selected settings pane")

        _ = try await NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration()
        )
        app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(app.windows.matching(identifier: "Say It").count, 1)
    }

    @MainActor
    func testOnboardingContinuesInIndependentWindow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingComplete", "NO",
            "-backgroundServiceUserDisabled", "YES"
        ]
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
