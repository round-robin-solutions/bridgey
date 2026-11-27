import XCTest

/// The phone's and the Mac's screens through the real UI, against the scripted peers (--phone and --mac): pair, open
/// Screen, see the stream live, turn Control on, touch the picture, Stop. scripts/rr/build-ios.sh checks afterwards
/// that the peers got the input.
final class ScreenUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func openScreen(_ peer: ScriptedPeer) -> XCUIApplication {
        let app = peer.launchAndPair()
        let action = app.buttons["action.screen"]
        XCTAssertTrue(action.waitForExistence(timeout: 20), "Screen is offered for \(peer.name)")
        action.tap()
        let surface = app.descendants(matching: .any)["screen.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 20), "the screen opens")
        expectation(for: NSPredicate(format: "value == %@", "Live"), evaluatedWith: surface)
        waitForExpectations(timeout: 30)
        return app
    }

    private func turnOnControl(_ app: XCUIApplication) {
        let control = app.switches["screen.control"]
        XCTAssertTrue(control.waitForExistence(timeout: 10), "Control is offered")
        // The switch itself, not its label.
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "On"), evaluatedWith: control)
        waitForExpectations(timeout: 15)
    }

    private func stop(_ app: XCUIApplication) {
        app.buttons["screen.stop"].tap()
        XCTAssertTrue(app.buttons["action.screen"].waitForExistence(timeout: 10), "back on the home")
    }

    func testAPhonesScreen() throws {
        guard let peer = ScriptedPeer.running(.phone) else { throw XCTSkip("the scripted phone is not running (scripts/rr/build-ios.sh starts it)") }
        let app = openScreen(peer)
        XCTAssertTrue(app.staticTexts["screen.slower"].exists, "screenshots from the phone say Slower mode")
        turnOnControl(app)
        XCTAssertTrue(app.buttons["screen.home"].waitForExistence(timeout: 5), "the phone's buttons show while controlling")
        app.descendants(matching: .any)["screen.surface"].tap()
        app.buttons["screen.back"].tap()
        keepScreenshot(app, "iphone-light-screen-phone-peer")
        stop(app)
    }

    func testAMacsScreen() throws {
        guard let peer = ScriptedPeer.running(.mac) else { throw XCTSkip("the scripted Mac is not running (scripts/rr/build-ios.sh starts it)") }
        let app = openScreen(peer)
        XCTAssertFalse(app.staticTexts["screen.slower"].exists, "a Mac streams video")
        turnOnControl(app)
        app.descendants(matching: .any)["screen.surface"].tap()
        keepScreenshot(app, "iphone-light-screen-mac-peer")
        stop(app)
    }
}
