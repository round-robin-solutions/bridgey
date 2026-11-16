import XCTest

/// Light and dark screenshots of every screen, with sample devices (BRIDGEY_DEMO). scripts/rr/build-ios.sh exports
/// the attachments as PNGs named <device>-<appearance>-<screen>.png.
final class ScreenshotTests: XCTestCase {
    private var device: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    override func setUp() {
        continueAfterFailure = true
    }

    func testLightScreens() { capture("light") }

    func testDarkScreens() { capture("dark") }

    private func launch(_ appearance: String, demo: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["BRIDGEY_DEMO": demo, "BRIDGEY_APPEARANCE": appearance, "BRIDGEY_DATA": "memory", "BRIDGEY_DISCOVERY": "0"]
        app.launch()
        return app
    }

    private func capture(_ appearance: String) {
        var app = launch(appearance, demo: "setup")
        XCTAssertTrue(app.buttons["setup.continue"].waitForExistence(timeout: 10))
        shot(app, appearance, "setup-welcome")
        app.buttons["setup.continue"].tap()
        XCTAssertTrue(app.buttons["setup.allow"].waitForExistence(timeout: 5))
        shot(app, appearance, "setup-local-network")
        app.terminate()

        app = launch(appearance, demo: "empty")
        XCTAssertTrue(app.buttons["toolbar.settings"].waitForExistence(timeout: 10))
        shot(app, appearance, "home-empty")
        app.terminate()

        app = launch(appearance, demo: "home")
        XCTAssertTrue(app.buttons["toolbar.settings"].waitForExistence(timeout: 10))
        _ = app.buttons.matching(identifier: "activity.row").firstMatch.waitForExistence(timeout: 5)
        shot(app, appearance, "home")

        app.buttons["toolbar.settings"].tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5))
        shot(app, appearance, "settings")
        let about = app.buttons["settings.about"]
        if !about.isHittable { app.swipeUp() }
        about.tap()
        XCTAssertTrue(app.staticTexts["about.version"].waitForExistence(timeout: 5) || app.otherElements["about.version"].exists)
        shot(app, appearance, "about")
        app.terminate()

        app = launch(appearance, demo: "pair")
        XCTAssertTrue(app.buttons["toolbar.pair"].waitForExistence(timeout: 10))
        app.buttons["toolbar.pair"].tap()
        XCTAssertTrue(app.buttons["pair.done"].waitForExistence(timeout: 5))
        shot(app, appearance, "pair")
        app.terminate()
    }

    private func shot(_ app: XCUIApplication, _ appearance: String, _ screen: String) {
        // Let springs settle.
        Thread.sleep(forTimeInterval: 0.8)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(device)-\(appearance)-\(screen)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
