import XCTest

/// The phone's notifications, its call, ringing both ways and its battery, with the scripted peer as an Android phone
/// (peer.rs --phone, started by scripts/rr/build-ios.sh). Skipped without it.
final class AlertsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// An element by its identifier whose label holds `text` (cards combine their text for VoiceOver).
    private func element(_ app: XCUIApplication, _ id: String, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", id, text)).firstMatch
    }

    func testNotificationsCallRingingAndBatteryFromThePhone() throws {
        guard let peer = ScriptedPeer.running(.phone) else { throw XCTSkip("the scripted phone isn't running (scripts/rr/build-ios.sh starts it)") }
        let app = peer.launchAndPair()

        // A message with Reply and Mark as read; reply from the card.
        peer.send(#"notify {"packageName":"com.whatsapp","applicationName":"WhatsApp","notificationId":"wa-1","title":"Ravi","text":"On my way, ten minutes","timestamp":1794000000000,"actions":[{"actionToken":"r1","title":"Reply","allowsReply":true},{"actionToken":"m1","title":"Mark as read","allowsReply":false}]}"#)
        let message = element(app, "alert.content", containing: "On my way, ten minutes")
        XCTAssertTrue(message.waitForExistence(timeout: 15), "the notification shows")
        XCTAssertTrue(app.buttons["Mark as read"].exists)
        keepScreenshot(app, "iphone-light-alerts-live")
        let reply = app.textFields["alert.reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        reply.typeText("See you soon")
        app.buttons["alert.send"].tap()
        XCTAssertTrue(app.staticTexts["Reply sent"].waitForExistence(timeout: 5), "the reply went to the phone")

        // The phone takes it away.
        peer.send("unnotify wa-1")
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: message)
        waitForExpectations(timeout: 10)

        // The phone's incoming call, with its own buttons, until the phone takes it away.
        peer.send(#"notify {"packageName":"com.google.android.dialer","applicationName":"Phone","notificationId":"call-1","title":"Anna Kapoor","text":"Incoming call","timestamp":1794000000000,"callType":"incoming","actions":[{"actionToken":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","title":"Answer","allowsReply":false},{"actionToken":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","title":"Decline","allowsReply":false}]}"#)
        let caller = element(app, "call.caller", containing: "Anna Kapoor")
        XCTAssertTrue(caller.waitForExistence(timeout: 15), "the call card shows")
        XCTAssertTrue(caller.label.contains("Incoming call"))
        XCTAssertTrue(app.buttons["Answer"].exists && app.buttons["Decline"].exists)
        keepScreenshot(app, "iphone-light-call-live")
        app.buttons["Decline"].tap()
        peer.send("unnotify call-1")
        expectation(for: gone, evaluatedWith: caller)
        waitForExpectations(timeout: 10)

        // The phone rings this device; Stop here tells it.
        peer.send("ring")
        let stop = app.buttons["ring.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15), "ringing here")
        XCTAssertTrue(element(app, "ring.title", containing: "is ringing this").exists)
        keepScreenshot(app, "iphone-light-ringing-live")
        stop.tap()
        expectation(for: gone, evaluatedWith: stop)
        waitForExpectations(timeout: 10)

        // This device rings the phone, then stops it.
        let ring = app.buttons["action.ring"]
        XCTAssertTrue(ring.waitForExistence(timeout: 5))
        ring.tap()
        let ringing = element(app, "ring.title", containing: "Ringing \(peer.name)")
        XCTAssertTrue(ringing.waitForExistence(timeout: 15), "the phone says it rings")
        app.buttons["ring.stop"].tap()
        expectation(for: gone, evaluatedWith: ringing)
        waitForExpectations(timeout: 10)

        // Its battery on its chip.
        peer.send("battery 80 1")
        let chip = app.buttons.matching(identifier: "device.chip").containing(NSPredicate(format: "label CONTAINS %@", peer.name)).firstMatch
        expectation(for: NSPredicate(format: "value CONTAINS %@", "80%"), evaluatedWith: chip)
        waitForExpectations(timeout: 15)
    }
}
