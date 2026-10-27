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

    func testOnlyCallsFromOtherAppsAreConfirmed() {
        XCTAssertFalse(CallRequestSource.bridgey.needsConfirmation)
        XCTAssertTrue(CallRequestSource.link.needsConfirmation)
        XCTAssertTrue(CallRequestSource.service.needsConfirmation)
        XCTAssertEqual(callConfirmationTitle(number: "+12345", phoneName: "OnePlus 11"), "Call +12345 from OnePlus 11?")
        XCTAssertEqual(callConfirmationTitle(number: "12345", phoneName: nil), "Call 12345 from your phone?")
        XCTAssertEqual(callConfirmationTitle(number: "12345", phoneName: ""), "Call 12345 from your phone?")
    }

    func testColdLaunchCallWaitsForConnectionAndFeatureNegotiation() {
        XCTAssertFalse(pendingPhoneCallCanDispatch(isConnected: false, featureStateReceived: false))
        XCTAssertFalse(pendingPhoneCallCanDispatch(isConnected: true, featureStateReceived: false))
        XCTAssertTrue(pendingPhoneCallCanDispatch(isConnected: true, featureStateReceived: true))
    }
}
