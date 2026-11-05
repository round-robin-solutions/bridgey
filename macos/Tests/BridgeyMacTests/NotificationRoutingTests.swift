import XCTest
@testable import BridgeyMac

final class NotificationRoutingTests: XCTestCase {
    func testSameMessageAfterReconnectOrPermissionToggleCannotReplaySoundButNewMessageCan() {
        var ledger = NotificationPresentationLedger()
        var alerted = AlertedNotificationIdentifiers()
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let first = ledger.receive(deviceID: "phone", notificationID: "conversation", sessionID: "S", presentation: .alert)
        XCTAssertTrue(alerted.insert(first.identifier, eventID: a, deviceID: "phone"))
        // Disconnect and Notifications off/on both invalidate asynchronous tickets, but the
        // production sound cache survives them. Replaying the same event must remain silent.
        for session in ["reconnected", "permission-reenabled"] {
            ledger.remove(deviceID: "phone")
            XCTAssertFalse(ledger.isCurrent(first))
            let repost = ledger.receive(deviceID: "phone", notificationID: "conversation", sessionID: session, presentation: .alert)
            XCTAssertFalse(alerted.insert(repost.identifier, eventID: a, deviceID: "phone"))
        }
        let next = ledger.receive(deviceID: "phone", notificationID: "conversation", sessionID: "new", presentation: .alert)
        XCTAssertTrue(alerted.insert(next.identifier, eventID: b, deviceID: "phone"))
        XCTAssertFalse(alerted.insert(next.identifier, eventID: b, deviceID: "phone"))
        let quiet = ledger.receive(deviceID: "phone", notificationID: "conversation", sessionID: "new", presentation: .quiet)
        XCTAssertFalse(ledger.allowsAlert(quiet))
        // An actual Android removal or forgetting the phone clears the appropriate event.
        alerted.remove(next.identifier)
        XCTAssertTrue(alerted.insert(next.identifier, eventID: b, deviceID: "phone"))
        alerted.remove(deviceID: "phone")
        XCTAssertTrue(alerted.insert(next.identifier, eventID: b, deviceID: "phone"))
    }

    func testLegacySoundIdentityAdoptsMessageMetadataWithoutReplayingAndStaysBounded() {
        var alerted = AlertedNotificationIdentifiers(capacity: 2)
        XCTAssertTrue(alerted.insert("legacy", deviceID: "A"))
        XCTAssertFalse(alerted.insert("legacy", eventID: "event-one", deviceID: "A"))
        XCTAssertTrue(alerted.insert("legacy", eventID: "event-two", deviceID: "A"))
        XCTAssertTrue(alerted.insert("other", eventID: "x", deviceID: "B"))
        alerted.remove(deviceID: "A")
        XCTAssertFalse(alerted.insert("other", eventID: "x", deviceID: "B"))
        XCTAssertTrue(alerted.insert("third", eventID: "y", deviceID: "B"))
        XCTAssertTrue(alerted.insert("fourth", eventID: "z", deviceID: "B"))
        XCTAssertTrue(alerted.insert("other", eventID: "x", deviceID: "B"), "eviction removes matching message identity too")
    }

    func testMessageEventIdentityIsStrictNegotiatedAndNeverAttachedToCalls() {
        let valid = String(repeating: "a", count: 64)
        XCTAssertEqual(decode("{\"presentation\":\"alert\",\"eventId\":\"\(valid)\"}"), .alert)
        XCTAssertNil(decode("{\"eventId\":\"\(valid)\"}", negotiated: false))
        XCTAssertNil(decode("{\"eventId\":\"\(valid)\",\"callType\":\"incoming\"}"))
        for value in ["null", "true", "1", "\"short\"", "\"\(String(repeating: "A", count: 64))\""] {
            XCTAssertNil(decode("{\"eventId\":\(value)}"))
        }
    }

    func testHeldCodeResultsAreRevokedForAlertAndQuietWithoutRevokingOrdinaryNotification() throws {
        for presentation in [NotificationPresentation.alert, .quiet] {
            for channel in [CodeChannel.sms, .email] {
                var permissions = CodeReadPermissionFence()
                permissions.update(enabled: true, emailEnabled: true)
                let read = try XCTUnwrap(permissions.ticket(for: channel))
                var notifications = NotificationPresentationLedger()
                let notification = notifications.receive(deviceID: "phone", notificationID: "held",
                    sessionID: "S", presentation: presentation)
                // The model response is held while the switch changes. The notification itself
                // is still current, so it may fall back to its ordinary alert/quiet behavior.
                permissions.update(enabled: false, emailEnabled: true)
                XCTAssertFalse(permissions.permits(read), "a held result cannot reach any code side effect")
                XCTAssertTrue(notifications.isCurrent(notification))
                XCTAssertEqual(notifications.allowsAlert(notification), presentation == .alert)
            }
        }
    }

    func testOffOnCycleCannotReviveHeldSMSOrEmailRead() throws {
        for channel in [CodeChannel.sms, .email] {
            var permissions = CodeReadPermissionFence()
            permissions.update(enabled: true, emailEnabled: true)
            let held = try XCTUnwrap(permissions.ticket(for: channel))
            permissions.update(enabled: false, emailEnabled: true)
            permissions.update(enabled: true, emailEnabled: true)
            XCTAssertFalse(permissions.permits(held))
            XCTAssertTrue(permissions.permits(try XCTUnwrap(permissions.ticket(for: channel))))
        }
    }

    func testEmailRevocationDoesNotCancelAnUnrelatedSMSReadAndOffOnDoesNotReviveEmail() throws {
        var permissions = CodeReadPermissionFence()
        permissions.update(enabled: true, emailEnabled: true)
        let sms = try XCTUnwrap(permissions.ticket(for: .sms))
        let email = try XCTUnwrap(permissions.ticket(for: .email))
        permissions.update(enabled: true, emailEnabled: false)
        XCTAssertTrue(permissions.permits(sms))
        XCTAssertFalse(permissions.permits(email))
        XCTAssertNil(permissions.ticket(for: .email))
        permissions.update(enabled: true, emailEnabled: true)
        XCTAssertTrue(permissions.permits(sms))
        XCTAssertFalse(permissions.permits(email))
        XCTAssertTrue(permissions.permits(try XCTUnwrap(permissions.ticket(for: .email))))
    }

    func testRepeatedPermissionValuesDoNotInvalidateReadsAndDisabledCannotStartOne() throws {
        var permissions = CodeReadPermissionFence()
        XCTAssertNil(permissions.ticket(for: .sms))
        XCTAssertNil(permissions.ticket(for: .email))
        permissions.update(enabled: false, emailEnabled: true)
        XCTAssertNil(permissions.ticket(for: .email))
        permissions.update(enabled: true, emailEnabled: true)
        let held = try XCTUnwrap(permissions.ticket(for: .email))
        permissions.update(enabled: true, emailEnabled: true)
        XCTAssertTrue(permissions.permits(held))
    }

    func testPresentationRequiresNegotiationAndExactEnumButMissingKeepsLegacyAlerts() {
        XCTAssertEqual(decode("{}", negotiated: false), .alert)
        XCTAssertEqual(decode("{}"), .alert)
        XCTAssertEqual(decode("{\"presentation\":\"alert\"}"), .alert)
        XCTAssertEqual(decode("{\"presentation\":\"quiet\"}"), .quiet)
        XCTAssertNil(decode("{\"presentation\":\"quiet\"}", negotiated: false))
        for invalid in ["null", "true", "1", "{}", "[]", "\"Quiet\"", "\"unknown\""] {
            XCTAssertNil(decode("{\"presentation\":" + invalid + "}"), invalid)
        }
        XCTAssertNil(decode("{\"presentation\":\"quiet\",\"presentation\":\"alert\"}"))
        XCTAssertNil(decode("{\"presentation\":\"quiet\",\"present\\u0061tion\":\"alert\"}"))
    }

    func testLateDecoderResultCannotAlertAfterQuietUpdateOrRemoval() {
        var ledger = NotificationPresentationLedger()
        let old = ledger.receive(deviceID: "phone", notificationID: "one", sessionID: "S", presentation: .alert)
        XCTAssertTrue(ledger.allowsAlert(old))
        let quiet = ledger.receive(deviceID: "phone", notificationID: "one", sessionID: "S", presentation: .quiet)
        XCTAssertFalse(ledger.isCurrent(old))
        XCTAssertFalse(ledger.allowsAlert(old))
        XCTAssertTrue(ledger.isCurrent(quiet), "a current quiet result may still enrich private history/report permitted codes")
        XCTAssertFalse(ledger.allowsAlert(quiet), "quiet code results cannot float, notify or auto-copy")
        ledger.remove(deviceID: "phone", notificationID: "one")
        XCTAssertFalse(ledger.isCurrent(quiet))
    }

    func testOtherPhoneCannotInvalidateATicketAndReplacingSessionCannotReuseOne() {
        var ledger = NotificationPresentationLedger()
        let a = ledger.receive(deviceID: "A", notificationID: "same", sessionID: "A1", presentation: .alert)
        let b = ledger.receive(deviceID: "B", notificationID: "same", sessionID: "B1", presentation: .alert)
        _ = ledger.receive(deviceID: "A", notificationID: "same", sessionID: "A2", presentation: .quiet)
        XCTAssertFalse(ledger.allowsAlert(a))
        XCTAssertTrue(ledger.allowsAlert(b))
        ledger.remove(deviceID: "A")
        XCTAssertTrue(ledger.allowsAlert(b))
        ledger.remove(deviceID: "B")
        XCTAssertFalse(ledger.allowsAlert(b))
    }

    func testBoundedLedgerEvictionCannotResurrectOldCallback() {
        var ledger = NotificationPresentationLedger(limit: 2)
        let first = ledger.receive(deviceID: "P", notificationID: "1", sessionID: "S", presentation: .alert)
        _ = ledger.receive(deviceID: "P", notificationID: "2", sessionID: "S", presentation: .quiet)
        _ = ledger.receive(deviceID: "P", notificationID: "3", sessionID: "S", presentation: .alert)
        XCTAssertFalse(ledger.isCurrent(first))
        let recreated = ledger.receive(deviceID: "P", notificationID: "1", sessionID: "S", presentation: .alert)
        XCTAssertTrue(ledger.allowsAlert(recreated))
        XCTAssertFalse(ledger.allowsAlert(first))
    }

    func testQuietIncomingCallsRemainMediaBarriersAndManualControlsWithoutRingingOrOverlay() {
        var calls = ActiveRemoteCalls()
        var quiet = call("quiet", type: "incoming")
        quiet.presentation = .quiet
        calls.update(quiet)
        XCTAssertTrue(calls.pausesMedia)
        XCTAssertEqual(calls.mostRelevant?.notificationID, "quiet", "manual call controls remain available")
        XCTAssertNil(calls.mostRelevantPresented)
        XCTAssertTrue(ringingRemoteCallIdentities(calls.all, enabled: true, silenced: [], identity: { $0.notificationID }).isEmpty)
        calls.update(quiet)
        XCTAssertNil(calls.mostRelevantPresented, "a repost cannot silently re-enable its alert")
        calls.remove(notificationID: "quiet", deviceID: "phone")
        XCTAssertFalse(calls.pausesMedia)
    }

    func testQuietCallDoesNotCoverAnotherPhonesSelectedAlertAndCanBecomeQuietWithoutEnding() {
        var calls = ActiveRemoteCalls()
        let alert = call("selected", type: "incoming")
        var quiet = call("other", type: "incoming")
        quiet.presentation = .quiet
        calls.update(alert)
        calls.update(quiet)
        XCTAssertEqual(calls.mostRelevantPresented?.notificationID, "selected")
        XCTAssertEqual(ringingRemoteCallIdentities(calls.all, enabled: true, silenced: [], identity: { $0.notificationID }), ["selected"])
        var changed = alert; changed.presentation = .quiet
        calls.update(changed)
        XCTAssertTrue(calls.pausesMedia)
        XCTAssertEqual(calls.all.count, 2)
        XCTAssertNil(calls.mostRelevantPresented)
        XCTAssertTrue(ringingRemoteCallIdentities(calls.all, enabled: true, silenced: [], identity: { $0.notificationID }).isEmpty)
    }

    private func decode(_ text: String, negotiated: Bool = true) -> NotificationPresentation? {
        NotificationPresentation.decode(Data(text.utf8), negotiated: negotiated)
    }
    private func call(_ id: String, type: String) -> RemoteCallStatus {
        RemoteCallStatus(notificationID: id, deviceID: "phone", applicationName: "Phone", caller: "Caller", detail: "", type: type, actions: [])
    }
}
