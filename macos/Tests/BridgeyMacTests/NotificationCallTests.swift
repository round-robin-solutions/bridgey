import XCTest
@testable import BridgeyMac

final class NotificationCallTests: XCTestCase {
    func testAcceptsOnlyKnownCallTypes() {
        XCTAssertEqual(normalizedRemoteCallType("incoming"), "incoming")
        XCTAssertEqual(normalizedRemoteCallType("ongoing"), "ongoing")
        XCTAssertEqual(normalizedRemoteCallType("screening"), "screening")
        XCTAssertEqual(normalizedRemoteCallType("unknown"), "unknown")
        XCTAssertNil(normalizedRemoteCallType("decline"))
        XCTAssertNil(normalizedRemoteCallType(nil))
    }

    func testProvidesSafeCallTitles() {
        XCTAssertEqual(remoteCallStatusTitle("incoming"), "Incoming call")
        XCTAssertEqual(remoteCallStatusTitle("ongoing"), "Call in progress")
        XCTAssertEqual(remoteCallStatusTitle("screening"), "Call screening")
        XCTAssertEqual(remoteCallStatusTitle("unknown"), "Phone call")
    }

    func testRemovesStaleGenericAndroidCallDescriptionAfterStateTransition() {
        XCTAssertEqual(remoteCallDetail("Incoming call", type: "ongoing"), "")
        XCTAssertEqual(remoteCallDetail("Call in progress", type: "ongoing"), "")
        XCTAssertEqual(remoteCallDetail("  Verified caller  ", type: "incoming"), "Verified caller")
    }

    func testCallOverlayReplacesOnlySystemCallNotifications() {
        XCTAssertTrue(shouldUseSystemNotification(callType: nil))
        XCTAssertFalse(shouldUseSystemNotification(callType: "incoming"))
        XCTAssertFalse(shouldUseSystemNotification(callType: "ongoing"))
    }

    func testCallOverlayPlacesAnswerBeforeDecline() {
        let decline = RemoteCallAction(id: "decline", title: "Decline")
        let answer = RemoteCallAction(id: "answer", title: "Answer")
        XCTAssertEqual(orderedCallActions([decline, answer]), [answer, decline])
    }

    func testCallWaitingShowsIncomingCallAndFallsBackWhenItEnds() {
        var calls = ActiveRemoteCalls()
        calls.update(remoteCall("first", type: "ongoing"))
        calls.update(remoteCall("second", type: "incoming"))
        XCTAssertEqual(calls.mostRelevant?.notificationID, "second")

        calls.update(remoteCall("first", type: "ongoing", caller: "Updated"))
        XCTAssertEqual(calls.mostRelevant?.notificationID, "second")

        XCTAssertEqual(calls.remove(notificationID: "second", deviceID: "phone")?.notificationID, "second")
        XCTAssertEqual(calls.mostRelevant?.notificationID, "first")
        XCTAssertEqual(calls.mostRelevant?.caller, "Updated")
        XCTAssertTrue(calls.pausesMedia)
    }

    func testNewestCallWinsWhenNoneIsIncoming() {
        var calls = ActiveRemoteCalls()
        calls.update(remoteCall("held", type: "ongoing"))
        calls.update(remoteCall("answered", type: "ongoing"))
        XCTAssertEqual(calls.mostRelevant?.notificationID, "answered")
        calls.update(remoteCall("held", type: "ongoing"))
        XCTAssertEqual(calls.mostRelevant?.notificationID, "answered")
    }

    func testCallsAreKeyedByDeviceAndNotification() {
        var calls = ActiveRemoteCalls()
        calls.update(remoteCall("call", type: "ongoing", deviceID: "phone-a"))
        calls.update(remoteCall("call", type: "ongoing", deviceID: "phone-b"))
        XCTAssertNil(calls.remove(notificationID: "call", deviceID: "phone-c"))
        calls.remove(notificationID: "call", deviceID: "phone-b")
        XCTAssertEqual(calls.mostRelevant?.deviceID, "phone-a")
    }

    func testMediaStaysPausedUntilTheLastCallEnds() {
        var calls = ActiveRemoteCalls()
        XCTAssertFalse(calls.pausesMedia)
        calls.update(remoteCall("first", type: "ongoing"))
        calls.update(remoteCall("second", type: "incoming"))
        calls.remove(notificationID: "second", deviceID: "phone")
        XCTAssertTrue(calls.pausesMedia)
        calls.remove(notificationID: "first", deviceID: "phone")
        XCTAssertFalse(calls.pausesMedia)
        XCTAssertNil(calls.mostRelevant)
    }

    func testScreeningAloneDoesNotPauseMedia() {
        var calls = ActiveRemoteCalls()
        calls.update(remoteCall("screened", type: "screening"))
        XCTAssertFalse(calls.pausesMedia)
    }

    func testRemoveAllReturnsEveryCall() {
        var calls = ActiveRemoteCalls()
        calls.update(remoteCall("first", type: "ongoing"))
        calls.update(remoteCall("second", type: "incoming"))
        XCTAssertEqual(calls.removeAll().map(\.notificationID), ["first", "second"])
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(calls.mostRelevant)
    }

    private func remoteCall(
        _ notificationID: String,
        type: String,
        deviceID: String = "phone",
        caller: String = "Caller"
    ) -> RemoteCallStatus {
        RemoteCallStatus(
            notificationID: notificationID,
            deviceID: deviceID,
            applicationName: "Phone",
            caller: caller,
            detail: "",
            type: type,
            actions: []
        )
    }
}
