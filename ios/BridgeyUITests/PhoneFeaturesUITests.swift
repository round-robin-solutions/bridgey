import XCTest

/// Text messages and the phone's files with a scripted Android phone (the peer's --phone): turn Text messages on,
/// read a conversation and reply; open a folder and download a file. scripts/rr/build-ios.sh starts the peer and
/// checks its log afterwards.
final class PhoneFeaturesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var idiom: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    func testMessagesTurnOnReadAndReply() throws {
        guard let phone = ScriptedPeer.running(.phone) else { throw XCTSkip("BRIDGEY_PHONE is not set (scripts/rr/build-ios.sh sets it)") }
        let app = phone.launchAndPair()

        let open = app.buttons["action.messages"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "Messages shows once the phone offers its texts")
        open.tap()
        let turnOn = app.buttons["messages.turnOn"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10), "Text messages is off until chosen")
        keepScreenshot(app, "\(idiom)-peer-messages-off")
        turnOn.tap()

        let asha = app.buttons.matching(identifier: "messages.conversation").containing(NSPredicate(format: "label CONTAINS %@", "Asha")).firstMatch
        XCTAssertTrue(asha.waitForExistence(timeout: 20), "the phone's conversations show")
        keepScreenshot(app, "\(idiom)-peer-messages")
        asha.tap()
        let bubble = app.descendants(matching: .any).matching(identifier: "messages.bubble").containing(NSPredicate(format: "label CONTAINS %@", "See you at 6")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 15), "the conversation's messages show")

        let field = app.textFields["messages.field"].exists ? app.textFields["messages.field"] : app.textViews["messages.field"]
        field.tap()
        field.typeText("On my way")
        app.buttons["messages.send"].tap()
        let delivered = app.descendants(matching: .any).matching(identifier: "messages.bubble")
            .containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "On my way", "Delivered")).firstMatch
        XCTAssertTrue(delivered.waitForExistence(timeout: 20), "the reply is delivered")
        keepScreenshot(app, "\(idiom)-peer-conversation")
    }

    func testPhoneFilesBrowseAndDownload() throws {
        guard let phone = ScriptedPeer.running(.phone) else { throw XCTSkip("BRIDGEY_PHONE is not set (scripts/rr/build-ios.sh sets it)") }
        let app = phone.launchAndPair()

        let open = app.buttons["action.files"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "Files shows once the phone allows browsing")
        open.tap()
        let place = app.buttons.matching(identifier: "files.place").containing(NSPredicate(format: "label CONTAINS %@", "Download/Bridgey")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 20), "the phone's places show")
        place.tap()
        let trip = app.buttons.matching(identifier: "files.folder").containing(NSPredicate(format: "label CONTAINS %@", "Trip")).firstMatch
        XCTAssertTrue(trip.waitForExistence(timeout: 15), "the place's folders show")
        trip.tap()
        let photo = app.buttons.matching(identifier: "files.file").containing(NSPredicate(format: "label CONTAINS %@", "IMG_0002.jpg")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "the folder's files show")
        keepScreenshot(app, "\(idiom)-peer-files")
        photo.tap()
        let download = app.buttons["files.confirmDownload"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        let done = app.descendants(matching: .any).matching(identifier: "files.transfer").containing(NSPredicate(format: "label CONTAINS %@", "Done")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30), "the download finishes")
        keepScreenshot(app, "\(idiom)-peer-files-downloaded")
    }
}
