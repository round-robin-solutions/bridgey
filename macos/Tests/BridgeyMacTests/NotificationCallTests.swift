import AppKit
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

    func testCallOverlayKeepsAndroidActionOrder() {
        let decline = RemoteCallAction(id: "decline", title: "Decline")
        let answer = RemoteCallAction(id: "answer", title: "Answer")
        XCTAssertEqual(visibleCallActions([decline, answer], limit: 2), [decline, answer])
        XCTAssertEqual(visibleCallActions([answer, decline], limit: 2), [answer, decline])
    }

    func testCallOverlayNeverDropsHangUp() {
        let speaker = RemoteCallAction(id: "speaker", title: "Speaker")
        let mute = RemoteCallAction(id: "mute", title: "Mute")
        let hangUp = RemoteCallAction(id: "hang-up", title: "Hang Up")
        XCTAssertEqual(visibleCallActions([speaker, mute, hangUp], limit: 2), [speaker, hangUp])
        XCTAssertEqual(visibleCallActions([hangUp, speaker, mute], limit: 2), [hangUp, speaker])
        XCTAssertEqual(visibleCallActions([speaker, mute], limit: 2), [speaker, mute])
        XCTAssertEqual(visibleCallActions([speaker, mute, hangUp], limit: 3), [speaker, mute, hangUp])
    }

    func testCallActionRolesMatchEnglishAndRussianTitles() {
        XCTAssertEqual(callActionRole("Answer"), .answer)
        XCTAssertEqual(callActionRole("Ответить"), .answer)
        XCTAssertEqual(callActionRole("Decline"), .end)
        XCTAssertEqual(callActionRole("Hang Up"), .end)
        XCTAssertEqual(callActionRole("ОТКЛОНИТЬ"), .end)
        XCTAssertEqual(callActionRole("Завершить"), .end)
        XCTAssertEqual(callActionRole("Speaker"), .other)
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

    // The reported bug, Mac side: the phone retracts the call notification and re-posts it at once
    // (a dialer swapping its notification). The card must survive.
    func testRetractedCallRepostedWithinGraceKeepsItsCard() {
        var calls = ActiveRemoteCalls()
        let now = Date()
        calls.update(remoteCall("call", type: "incoming"))

        XCTAssertTrue(calls.scheduleRemoval(notificationID: "call", deviceID: "phone", deadline: now.addingTimeInterval(remoteCallRemovalGrace)))
        XCTAssertEqual(calls.mostRelevant?.notificationID, "call")
        XCTAssertTrue(calls.update(remoteCall("call", type: "incoming")))
        XCTAssertTrue(calls.removeExpired(now: now.addingTimeInterval(10)).isEmpty)
        XCTAssertEqual(calls.mostRelevant?.notificationID, "call")
    }

    func testRetractedCallWithoutRepostGoesAfterGrace() {
        var calls = ActiveRemoteCalls()
        let now = Date()
        calls.update(remoteCall("call", type: "incoming"))
        calls.scheduleRemoval(notificationID: "call", deviceID: "phone", deadline: now.addingTimeInterval(remoteCallRemovalGrace))

        XCTAssertTrue(calls.removeExpired(now: now.addingTimeInterval(remoteCallRemovalGrace - 0.1)).isEmpty)
        XCTAssertEqual(calls.removeExpired(now: now.addingTimeInterval(remoteCallRemovalGrace)).map(\.notificationID), ["call"])
        XCTAssertNil(calls.mostRelevant)
    }

    func testSecondRetractionDoesNotExtendTheGrace() {
        var calls = ActiveRemoteCalls()
        let now = Date()
        calls.update(remoteCall("call", type: "incoming"))
        calls.scheduleRemoval(notificationID: "call", deviceID: "phone", deadline: now.addingTimeInterval(2))
        calls.scheduleRemoval(notificationID: "call", deviceID: "phone", deadline: now.addingTimeInterval(9))

        XCTAssertEqual(calls.removeExpired(now: now.addingTimeInterval(2)).count, 1)
    }

    func testRetractionOfAnotherNotificationLeavesTheCallCard() {
        var calls = ActiveRemoteCalls()
        calls.update(remoteCall("call", type: "incoming"))

        XCTAssertFalse(calls.scheduleRemoval(notificationID: "chat", deviceID: "phone", deadline: Date()))
        XCTAssertNil(calls.remove(notificationID: "chat", deviceID: "phone"))
        XCTAssertTrue(calls.removeExpired(now: Date().addingTimeInterval(60)).isEmpty)
        XCTAssertEqual(calls.mostRelevant?.notificationID, "call")
    }

    func testOrdinaryNotificationNeverReachesTheCallCard() {
        // updateRemoteCall only acts on a known call type; an ordinary notification has none.
        XCTAssertNil(normalizedRemoteCallType(nil))
        XCTAssertTrue(shouldUseSystemNotification(callType: nil))
        var calls = ActiveRemoteCalls()
        calls.update(remoteCall("call", type: "incoming"))
        let before = calls.all
        XCTAssertNil(calls.remove(notificationID: "message", deviceID: "phone"))
        XCTAssertEqual(calls.all, before)
    }

    func testCallOverlayStaysAboveNotificationBannersOnEverySpace() {
        // Notification banners are drawn at window level 21; the card must sit above them.
        XCTAssertGreaterThan(callOverlayWindowLevel.rawValue, 21)
        XCTAssertLessThan(callOverlayWindowLevel.rawValue, NSWindow.Level.popUpMenu.rawValue)
        XCTAssertTrue(callOverlayCollectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(callOverlayCollectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(callOverlayCollectionBehavior.contains(.stationary))
        XCTAssertFalse(callOverlayCollectionBehavior.contains(.transient))
    }

    func testIncomingCallsRingUntilSilencedOrTurnedOff() {
        let identity: (RemoteCallStatus) -> String = { $0.notificationID }
        let calls = [remoteCall("ongoing", type: "ongoing"), remoteCall("ringing", type: "incoming")]

        XCTAssertEqual(ringingRemoteCallIdentities(calls, enabled: true, silenced: [], identity: identity), ["ringing"])
        XCTAssertTrue(ringingRemoteCallIdentities(calls, enabled: true, silenced: ["ringing"], identity: identity).isEmpty)
        XCTAssertTrue(ringingRemoteCallIdentities(calls, enabled: false, silenced: [], identity: identity).isEmpty)
        XCTAssertTrue(ringingRemoteCallIdentities([remoteCall("ongoing", type: "ongoing")], enabled: true, silenced: [], identity: identity).isEmpty)
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

    /// Rahul's phone sent every call of 2026-10-28 as f50c2274: the dialer's one notification.
    func testAnotherCallerOnAGoingCardIsANewCall() {
        let first = RemoteCallStatus(notificationID: "f50c2274", deviceID: "phone", applicationName: "Phone",
                                     caller: "Rtr. Kamakshi Aggarwal", detail: "", type: "ongoing", actions: [])
        XCTAssertTrue(isNewCallOnSameNotification(previous: first, pendingRemoval: true, caller: "Ghazal"))
        XCTAssertFalse(isNewCallOnSameNotification(previous: first, pendingRemoval: true, caller: "Rtr. Kamakshi Aggarwal "),
                       "the same call re-posted during the grace keeps its card")
        XCTAssertFalse(isNewCallOnSameNotification(previous: first, pendingRemoval: false, caller: "Ghazal"),
                       "a live call whose title changes (a contact name resolving) is the same call")
        XCTAssertFalse(isNewCallOnSameNotification(previous: first, pendingRemoval: true, caller: ""))
    }
}
