import Foundation
import XCTest
@testable import BridgeyMac

final class SmsSourceRulesTests: XCTestCase {
    private func link(sms: Bool = true, confirmed: Bool = false, mac: Bool = false) -> PhoneLinkState {
        var link = PhoneLinkState()
        link.featureStateReceived = true
        link.remoteSms = sms
        link.smsProviderConfirmed = confirmed
        link.remoteHandoffTakeover = mac
        return link
    }

    private var status: Data {
        try! JSONSerialization.data(withJSONObject: ["version": 1, "read": true, "send": true, "contacts": true,
                                                     "sims": [], "cursor": ["sms": 1, "mms": 0]])
    }

    func testMacClientWithTextMessagesOnCannotBecomeASourceOrReceiveRequests() {
        let mac = link(confirmed: true, mac: true)
        XCTAssertFalse(SmsSourceRules.isPhone(mac, restricted: false))
        XCTAssertFalse(SmsSourceRules.canRequest(mac, restricted: false))
        XCTAssertFalse(SmsSourceRules.acceptsStatus(status, link: mac, restricted: false))
    }

    func testOldMacWithoutHandoffMarkerIsNotAProviderJustBecauseItAdvertisesSms() {
        let oldMac = link()
        XCTAssertFalse(SmsSourceRules.isPhone(oldMac, restricted: false))
        XCTAssertFalse(SmsSourceRules.canRequest(oldMac, restricted: false))
    }

    func testOlderAndroidCanProveItsRoleWithoutDiscoveryOrPlatformMetadata() {
        var android = link()
        XCTAssertNil(android.updateStatus)
        XCTAssertFalse(SmsSourceRules.canRequest(android, restricted: false))
        XCTAssertTrue(SmsSourceRules.acceptsStatus(status, link: android, restricted: false))
        android.smsProviderConfirmed = true
        XCTAssertTrue(SmsSourceRules.isPhone(android, restricted: false))
        XCTAssertTrue(SmsSourceRules.canRequest(android, restricted: false))
    }

    func testMalformedStatusAndUnnegotiatedOrDisabledPeersCannotSupplyProof() {
        XCTAssertFalse(SmsSourceRules.acceptsStatus(Data("{}".utf8), link: link(), restricted: false))
        XCTAssertFalse(SmsSourceRules.acceptsStatus(status, link: link(sms: false), restricted: false))
        XCTAssertFalse(SmsSourceRules.acceptsStatus(status, link: PhoneLinkState(), restricted: false))
        XCTAssertFalse(SmsSourceRules.canRequest(nil, restricted: false))
    }

    func testRestrictedServerNeverQualifiesEvenWithStatusAndSmsCapabilities() {
        let server = link(confirmed: true)
        XCTAssertFalse(SmsSourceRules.isPhone(server, restricted: true))
        XCTAssertFalse(SmsSourceRules.canRequest(server, restricted: true))
        XCTAssertFalse(SmsSourceRules.acceptsStatus(status, link: server, restricted: true))
    }

    func testAuthenticatedPlatformExcludesOlderMacsAndIdentifiesAndroidBeforeStatus() {
        var peer = link(confirmed: true)
        peer.updateStatus = PeerUpdateStatus(platform: .macos, edition: "rr", app: "1.0", build: 1,
                                            channel: .stable, state: .current, remoteStart: false, checkedAt: 0)
        XCTAssertFalse(SmsSourceRules.canRequest(peer, restricted: false))
        XCTAssertFalse(SmsSourceRules.acceptsStatus(status, link: peer, restricted: false))
        peer.updateStatus?.platform = .android
        peer.smsProviderConfirmed = false
        XCTAssertTrue(SmsSourceRules.canRequest(peer, restricted: false))
    }

    func testPhoneWithSmsOffStaysAPhoneButCannotReceiveRequests() {
        let phone = link(sms: false, confirmed: true)
        XCTAssertTrue(SmsSourceRules.isPhone(phone, restricted: false))
        XCTAssertFalse(SmsSourceRules.canRequest(phone, restricted: false))
    }

    func testReplacementSessionMustSupplyItsOwnProviderProof() {
        let registry = SessionRegistry<NSObject>(localDeviceID: "local")
        let old = NSObject()
        registry.addPending(old, initiatedLocally: true)
        _ = registry.authenticate(old, deviceID: "phone", peerName: "OnePlus 11")
        registry.update("phone") { $0 = link(confirmed: true) }
        XCTAssertTrue(SmsSourceRules.canRequest(registry.state(for: "phone"), restricted: false))
        let replacement = NSObject()
        registry.addPending(replacement, initiatedLocally: true)
        _ = registry.authenticate(replacement, deviceID: "phone", peerName: "OnePlus 11", isStale: { _ in true })
        XCTAssertEqual(registry.state(for: "phone")?.remoteSms, true)
        XCTAssertFalse(SmsSourceRules.canRequest(registry.state(for: "phone"), restricted: false))
    }

    @MainActor func testMacConnectingBeforeThePhoneDoesNotStealTheSourceOrItsThread() {
        let peers = [PhoneConnection(id: "mac", name: "Personal Mac", state: link(mac: true)),
                     PhoneConnection(id: "phone", name: "OnePlus 11", state: link(confirmed: true))]
        let sources = peers.filter { SmsSourceRules.canRequest($0.state, restricted: false) }
            .map { MessagesPhone(id: $0.id, name: $0.name) }
        XCTAssertEqual(sources.map(\.id), ["phone"])
        let selection = MessagesSelection()
        selection.phoneID = "mac"
        selection.target = .thread(7)
        selection.selected = [7, 8]
        selection.selecting = true
        selection.rangeStart = 7
        selection.query = "old source query"
        selection.focusMessage = "s1"
        selection.unread = MessagesUnreadAnchor(thread: 7, readThrough: nil, count: 1)
        selection.forwardText = "old source forward"
        XCTAssertNil(selection.selectedPhone(in: sources), "no implicit fallback before old thread state is retired")
        XCTAssertTrue(selection.reconcilePhones(sources))
        XCTAssertEqual(selection.phoneID, "phone")
        XCTAssertNil(selection.target)
        XCTAssertTrue(selection.selected.isEmpty)
        XCTAssertFalse(selection.selecting)
        XCTAssertNil(selection.rangeStart)
        XCTAssertEqual(selection.query, "")
        XCTAssertNil(selection.focusMessage)
        XCTAssertNil(selection.unread)
        XCTAssertNil(selection.forwardText)
    }

    @MainActor func testOnlyMacsClearsTheStaleSourceAndPhoneArrivingLaterIsSelected() {
        let selection = MessagesSelection()
        selection.phoneID = "mac"
        selection.target = .thread(7)
        XCTAssertTrue(selection.reconcilePhones([]))
        XCTAssertNil(selection.phoneID)
        XCTAssertNil(selection.target)
        let sources = [MessagesPhone(id: "phone", name: "OnePlus 11")]
        XCTAssertTrue(selection.reconcilePhones(sources))
        XCTAssertEqual(selection.phoneID, "phone")
        selection.target = .thread(42)
        XCTAssertFalse(selection.reconcilePhones(sources), "ordinary status/name updates keep the same phone's conversation")
        XCTAssertEqual(selection.target, .thread(42))
    }
}
