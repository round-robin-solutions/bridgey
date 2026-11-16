import XCTest

/// Pairs the app with a scripted Bridgey peer (rust/client/examples/peer.rs) through the real UI, then sends text
/// both ways. scripts/rr/build-ios.sh starts the peer on the Mac running the simulator and passes its address as
/// TEST_RUNNER_BRIDGEY_PEER; without it the test is skipped.
final class PairingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testPairWithAScriptedPeerAndSendTextBothWays() throws {
        let env = ProcessInfo.processInfo.environment
        guard let peer = env["BRIDGEY_PEER"], !peer.isEmpty else { throw XCTSkip("BRIDGEY_PEER is not set (scripts/rr/build-ios.sh sets it)") }
        let peerName = env["BRIDGEY_PEER_NAME"] ?? "Test Mac"
        let peerText = env["BRIDGEY_PEER_TEXT"] ?? "Hello from the peer"

        let app = XCUIApplication()
        app.launchEnvironment = [
            "BRIDGEY_DATA": "memory",
            "BRIDGEY_PORT": env["BRIDGEY_APP_PORT"] ?? "42471",
            "BRIDGEY_DISCOVERY": "0",
            "BRIDGEY_SKIP_SETUP": "1",
        ]
        app.launch()

        // No devices yet: pair by address.
        let pairButton = app.buttons["home.pair"]
        XCTAssertTrue(pairButton.waitForExistence(timeout: 10))
        pairButton.tap()
        let address = app.textFields["pair.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText(peer)
        app.buttons["pair.addressButton"].tap()

        // The peer confirms its side by itself; the person here compares and confirms.
        let code = app.staticTexts["pairing.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 20), "the code shows")
        attach(app, "pairing-code")
        app.buttons["pairing.match"].tap()
        XCTAssertTrue(app.staticTexts["pairing.paired"].waitForExistence(timeout: 20) || app.otherElements["pairing.paired"].exists, "paired")
        app.buttons["pair.done"].tap()

        // The peer sends its text once it has this device's switches.
        let received = app.buttons.matching(identifier: "activity.row").containing(NSPredicate(format: "label CONTAINS %@", peerText)).firstMatch
        XCTAssertTrue(received.waitForExistence(timeout: 20), "text from the peer arrives")
        XCTAssertTrue(app.buttons.matching(identifier: "device.chip").containing(NSPredicate(format: "label CONTAINS %@", peerName)).firstMatch.exists)

        // And this device sends text back; the row says Delivered once the peer acknowledged it.
        let field = app.textFields["send.field"]
        field.tap()
        field.typeText("Hello from iOS")
        app.buttons["send.button"].tap()
        let sent = app.buttons.matching(identifier: "activity.row").containing(NSPredicate(format: "label CONTAINS %@", "Hello from iOS")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        let delivered = NSPredicate(format: "value CONTAINS %@", "Delivered")
        expectation(for: delivered, evaluatedWith: sent)
        waitForExpectations(timeout: 15)
        attach(app, "paired-home")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
