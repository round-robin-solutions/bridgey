import XCTest

/// A scripted Bridgey device for UI tests (rust/client/examples/peer.rs), started by scripts/rr/build-ios.sh on the
/// Mac running the simulator: `phone` answers as an Android phone (--phone), `mac` as a Mac sharing its screen
/// (--mac). The app finds it through BRIDGEY_FOUND, pairs with it through the Pair sheet, and the test sends it
/// commands (peer.rs lists them) by appending lines to its commands file.
struct ScriptedPeer {
    enum Kind: String {
        case phone = "PHONE"
        case mac = "MAC"
    }

    /// `id|name|platform|host|port`, as BRIDGEY_FOUND takes it.
    let found: String
    let name: String
    let commands: URL

    /// The peer the build script started, or nil (the test is then skipped).
    static func running(_ kind: Kind) -> ScriptedPeer? {
        let env = ProcessInfo.processInfo.environment
        guard let found = env["BRIDGEY_\(kind.rawValue)"], !found.isEmpty, let commands = env["BRIDGEY_\(kind.rawValue)_COMMANDS"] else { return nil }
        let parts = found.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return nil }
        return ScriptedPeer(found: found, name: String(parts[1]), commands: URL(fileURLWithPath: commands))
    }

    /// One command line for the peer (`notify {...}`, `phone 4 {...}`, `battery 80 1`, ...).
    func send(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: commands) else { return XCTFail("the peer's commands file is missing") }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    /// Launches the app with this peer on the network and pairs with it through the Pair sheet, as a person would.
    /// `environment` adds launch settings (BRIDGEY_APPEARANCE, ...).
    func launchAndPair(port: String = "42473", environment: [String: String] = [:], file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "BRIDGEY_DATA": "memory",
            "BRIDGEY_PORT": ProcessInfo.processInfo.environment["BRIDGEY_APP_PORT"] ?? port,
            "BRIDGEY_DISCOVERY": "0",
            "BRIDGEY_SKIP_SETUP": "1",
            "BRIDGEY_FOUND": found,
        ].merging(environment) { _, new in new }
        app.launch()
        let pair = app.buttons["home.pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10), "Pair a device shows", file: file, line: line)
        pair.tap()
        let nearby = app.buttons.matching(identifier: "pair.nearby").containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(nearby.waitForExistence(timeout: 10), "\(name) is nearby", file: file, line: line)
        nearby.tap()
        let match = app.buttons["pairing.match"]
        XCTAssertTrue(match.waitForExistence(timeout: 20), "the code shows", file: file, line: line)
        match.tap()
        XCTAssertTrue(app.staticTexts["pairing.paired"].waitForExistence(timeout: 20) || app.otherElements["pairing.paired"].exists, "paired", file: file, line: line)
        app.buttons["pair.done"].tap()
        let chip = app.buttons.matching(identifier: "device.chip").containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "\(name) is listed", file: file, line: line)
        return app
    }
}

extension XCTestCase {
    /// A screenshot kept in the result bundle; scripts/rr/build-ios.sh exports it as `<name>.png`.
    func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
