import XCTest
@testable import BridgeyMac

final class ShareFlowTests: XCTestCase {
    @MainActor func testUnsetLinksOpenAndExplicitOffSurvivesReload() {
        let name = "BridgeyShareTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(SetupSetting.openLinksRightAway.defaultValue, "true")
        XCTAssertTrue(BridgeySettings(defaults: defaults).openLinksRightAway)
        defaults.set(false, forKey: "settings.links.openRightAway")
        XCTAssertFalse(BridgeySettings(defaults: defaults).openLinksRightAway)
        defaults.set(true, forKey: "settings.links.openRightAway")
        XCTAssertTrue(BridgeySettings(defaults: defaults).openLinksRightAway)
        XCTAssertTrue(BridgeySettings(defaults: defaults).shareActivityStatus)
        BridgeySettings(defaults: defaults).setShareActivityStatus(false)
        XCTAssertFalse(BridgeySettings(defaults: defaults).shareActivityStatus)
    }

    @MainActor func testParkedLinksReplaceAndRateLimitIsPerPhone() {
        let actions = QuickActions()
        actions.availableFor = { _, _ in true }
        actions.openRightAway = { false }
        var replies: [[String: Any]] = []
        var now = Date(timeIntervalSince1970: 100)
        actions.clock = { now }
        actions.send = { _, payload in replies.append(payload); return true }
        func receive(_ path: String, from phone: String = "phone") {
            actions.receive("quick.request", payload: ["version": 1, "requestId": UUID().uuidString,
                "feature": "links", "action": "open", "value": "https://example.com/\(path)"], from: phone)
        }
        receive("first")
        receive("limited")
        XCTAssertEqual(replies.last?["reason"] as? String, "rate_limited")
        XCTAssertEqual(actions.receivedLink, "https://example.com/first")
        now = now.addingTimeInterval(3)
        receive("replacement")
        XCTAssertEqual(replies.last?["accepted"] as? Bool, true)
        XCTAssertEqual(replies.last?["opened"] as? Bool, false)
        XCTAssertEqual(actions.receivedLink, "https://example.com/replacement")
        receive("other", from: "tablet")
        XCTAssertEqual(actions.receivedLink, "https://example.com/other")
    }

    @MainActor func testActivityNamesTheSenderAndBrowserFailureIsExplicit() {
        let actions = QuickActions()
        actions.availableFor = { _, _ in true }
        actions.openURL = { _ in true }
        var events: [(ActivityKind, String)] = []
        var reply: [String: Any] = [:]
        actions.onActivity = { events.append(($0, $1)) }
        actions.send = { _, payload in reply = payload; return true }
        func request(from phone: String) {
            actions.receive("quick.request", payload: ["version": 1, "requestId": UUID().uuidString,
                "feature": "links", "action": "open", "value": "https://example.com"], from: phone)
        }
        request(from: "OnePlus")
        XCTAssertEqual(events.last?.1, "OnePlus")
        XCTAssertEqual(events.last?.0, .linkReceived)
        XCTAssertEqual(reply["opened"] as? Bool, true)
        actions.openURL = { _ in false }
        request(from: "other-phone")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(reply["accepted"] as? Bool, false)
        XCTAssertEqual(reply["reason"] as? String, "browser_failed")
        actions.availableFor = { _, _ in false }
        request(from: "denied-phone")
        XCTAssertEqual(reply["accepted"] as? Bool, false)
        XCTAssertNil(actions.receivedLink)
    }
}
