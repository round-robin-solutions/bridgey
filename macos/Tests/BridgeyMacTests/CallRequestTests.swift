import XCTest
@testable import BridgeyMac

final class CallRequestTests: XCTestCase {
    func testNormalizesCommonPhoneNumberFormatting() {
        XCTAssertEqual(normalizedPhoneNumber(" +7 (999) 123-45-67 "), "+79991234567")
        XCTAssertEqual(normalizedPhoneNumber("12345"), "12345")
    }

    func testRejectsCommandsExtensionsAndInvalidLengths() {
        XCTAssertNil(normalizedPhoneNumber("*100#"))
        XCTAssertNil(normalizedPhoneNumber("+1 555 CALL-NOW"))
        XCTAssertNil(normalizedPhoneNumber("12"))
        XCTAssertNil(normalizedPhoneNumber("1234567890123456"))
        XCTAssertNil(normalizedPhoneNumber("7 +999 123"))
        XCTAssertNil(normalizedPhoneNumber("١٢٣٤٥"))
    }

    func testOnlyCallsFromOtherAppsFollowThePolicy() {
        XCTAssertFalse(CallRequestSource.bridgey.isFromOtherApp)
        XCTAssertTrue(CallRequestSource.link.isFromOtherApp)
        XCTAssertTrue(CallRequestSource.service.isFromOtherApp)
        XCTAssertEqual(callConfirmationTitle(number: "+12345", phoneName: "OnePlus 11"), "Call +12345 from OnePlus 11?")
        XCTAssertEqual(callConfirmationTitle(number: "12345", phoneName: nil), "Call 12345 from your phone?")
        XCTAssertEqual(callConfirmationTitle(number: "12345", phoneName: ""), "Call 12345 from your phone?")
    }

    func testOtherAppCallsFollowThePolicy() {
        for source in [CallRequestSource.link, .service] {
            XCTAssertEqual(otherAppCallDecision(source: source, policy: .ask), .ask, "\(source)")
            XCTAssertEqual(otherAppCallDecision(source: source, policy: .callNow), .callNow, "\(source)")
            XCTAssertEqual(otherAppCallDecision(source: source, policy: .refuse), .refuse, "\(source)")
        }
    }

    func testCallsStartedInBridgeyNeverAskAndAreNeverBlocked() {
        for policy in MacOtherAppCallPolicy.allCases {
            XCTAssertEqual(otherAppCallDecision(source: .bridgey, policy: policy), .callNow, policy.rawValue)
        }
    }

    @MainActor
    func testConfirmationAlertOffersDontAskAgainUnchecked() {
        let alert = makeCallConfirmationAlert(number: "+12345", phoneName: "OnePlus 11")
        XCTAssertEqual(alert.messageText, "Call +12345 from OnePlus 11?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Call", "Cancel"])
        XCTAssertTrue(alert.showsSuppressionButton)
        XCTAssertEqual(alert.suppressionButton?.title, "Don\u{2019}t ask again")
        XCTAssertEqual(alert.suppressionButton?.state, .off, "Don't ask again starts unchecked")
    }

    func testColdLaunchCallWaitsForConnectionAndFeatureNegotiation() {
        XCTAssertFalse(pendingPhoneCallCanDispatch(isConnected: false, featureStateReceived: false))
        XCTAssertFalse(pendingPhoneCallCanDispatch(isConnected: true, featureStateReceived: false))
        XCTAssertTrue(pendingPhoneCallCanDispatch(isConnected: true, featureStateReceived: true))
    }
}
