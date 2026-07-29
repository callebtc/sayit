import XCTest

final class SayItUITests: XCTestCase {
    @MainActor
    func testMenuBarUtilityRemainsRunningAfterLaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launch()

        let deadline = Date.now.addingTimeInterval(10)
        while app.state == .notRunning, Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        }

        XCTAssertNotEqual(app.state, .notRunning)
    }
}
