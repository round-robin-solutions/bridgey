import XCTest

/// Messages and the phone's files with sample data (BRIDGEY_DEMO=messages, files), light and dark, on iPhone and iPad.
extension ScreenshotTests {
    @objc func testPhoneScreensLight() { capturePhone("light") }

    @objc func testPhoneScreensDark() { capturePhone("dark") }

    private func capturePhone(_ appearance: String) {
        var app = launch(appearance, demo: "messages")
        let asha = app.buttons.matching(identifier: "messages.conversation").containing(NSPredicate(format: "label CONTAINS %@", "Asha")).firstMatch
        XCTAssertTrue(asha.waitForExistence(timeout: 10))
        shot(app, appearance, "messages")
        asha.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "messages.bubble").firstMatch.waitForExistence(timeout: 5))
        shot(app, appearance, "conversation")
        app.terminate()

        app = launch(appearance, demo: "files")
        let place = app.buttons.matching(identifier: "files.place").firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 10))
        place.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "files.folder").firstMatch.waitForExistence(timeout: 5))
        shot(app, appearance, "files")
        // Back to the places (the folder's bar is named after its place).
        app.navigationBars["Download/Bridgey"].buttons.element(boundBy: 0).tap()
        let photos = app.buttons["files.photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        photos.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "files.photo").firstMatch.waitForExistence(timeout: 5))
        shot(app, appearance, "photos")
        app.terminate()
    }
}
