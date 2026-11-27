import XCTest

/// Light and dark screenshots of a phone's and a Mac's screen (BRIDGEY_DEMO=screen-phone and screen-mac: drawn
/// pictures through the real decoder), on iPhone and iPad.
extension ScreenshotTests {
    func testScreenLight() { captureScreens("light") }

    func testScreenDark() { captureScreens("dark") }

    private func captureScreens(_ appearance: String) {
        for (demo, name) in [("screen-phone", "screen-phone"), ("screen-mac", "screen-mac")] {
            let app = launch(appearance, demo: demo)
            let surface = app.descendants(matching: .any)["screen.surface"]
            XCTAssertTrue(surface.waitForExistence(timeout: 15), "\(demo): the screen opens")
            expectation(for: NSPredicate(format: "value == %@", "Live"), evaluatedWith: surface)
            waitForExpectations(timeout: 20)
            shot(app, appearance, name)
            app.terminate()
        }
    }
}
