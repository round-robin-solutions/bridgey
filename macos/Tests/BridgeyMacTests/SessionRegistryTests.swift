import XCTest
@testable import BridgeyMac

/// Mirrors android/.../SessionRegistryTest.kt: several phones per Mac, duplicates, isolation.
final class SessionRegistryTests: XCTestCase {
    private final class FakeSession {
        let name: String
        init(_ name: String) { self.name = name }
    }

    // The Mac's id sorts between the two phones: "a-phone" dials it, it dials "z-phone".
    private let macID = "m-mac"
    private let phoneA = "a-phone"
    private let phoneZ = "z-phone"

    private func connect(_ registry: SessionRegistry<FakeSession>, _ session: FakeSession, _ id: String, local: Bool) -> SessionRegistry<FakeSession>.Admission {
        registry.addPending(session, initiatedLocally: local)
        return registry.authenticate(session, deviceID: id, peerName: session.name)
    }

    func testSeveralPhonesSideBySide() {
        let registry = SessionRegistry<FakeSession>(localDeviceID: macID)
        let a = FakeSession("OnePlus 11")
        let z = FakeSession("Pixel 9")
        XCTAssertEqual(connect(registry, a, phoneA, local: false), .accepted(replaced: nil))
        XCTAssertEqual(connect(registry, z, phoneZ, local: true), .accepted(replaced: nil))
        XCTAssertEqual(registry.connectedIDs, [phoneA, phoneZ])
        XCTAssertTrue(registry.session(for: phoneA) === a)
        XCTAssertEqual(registry.connections.map(\.name), ["OnePlus 11", "Pixel 9"])
    }

    /// The reported bug, Mac side: a pairing waits for its code while a trusted phone reconnects.
    func testPairingSurvivesTrustedPhoneReconnecting() {
        let registry = SessionRegistry<FakeSession>(localDeviceID: macID)
        let stale = FakeSession("OnePlus (old)")
        _ = connect(registry, stale, phoneA, local: false)
        let pairing = FakeSession("New phone pairing")
        registry.addPending(pairing, initiatedLocally: false)
        let reconnect = FakeSession("OnePlus (reconnect)")
        XCTAssertEqual(connect(registry, reconnect, phoneA, local: false), .accepted(replaced: stale))
        XCTAssertTrue(registry.isPending(pairing))
        XCTAssertNil(registry.remove(stale))
        XCTAssertTrue(registry.session(for: phoneA) === reconnect)
        XCTAssertEqual(registry.authenticate(pairing, deviceID: phoneZ, peerName: "Pixel 9"), .accepted(replaced: nil))
        XCTAssertEqual(registry.connectedIDs, [phoneA, phoneZ])
        XCTAssertTrue(registry.pendingSessions.isEmpty)
    }

    func testDuplicateKeepsSocketDialledByLowerID() {
        // m-mac < z-phone: the Mac dials, so its socket wins either way round.
        let registry = SessionRegistry<FakeSession>(localDeviceID: macID)
        let macDialled = FakeSession("mac dialled")
        let phoneDialled = FakeSession("phone dialled")
        _ = connect(registry, macDialled, phoneZ, local: true)
        XCTAssertEqual(connect(registry, phoneDialled, phoneZ, local: false), .rejected)
        XCTAssertTrue(registry.session(for: phoneZ) === macDialled)
    }

    func testDuplicateRuleAgreesWithThePhone() {
        // The same pair seen from both ends keeps the same socket (A, dialled by the lower id).
        final class Tag { let value: String; init(_ value: String) { self.value = value } }
        let a = Tag("A"), b = Tag("B")
        let mac = SessionRegistry<Tag>(localDeviceID: "z-mac")
        mac.addPending(a, initiatedLocally: false); _ = mac.authenticate(a, deviceID: "m-phone", peerName: "Phone")
        mac.addPending(b, initiatedLocally: true); _ = mac.authenticate(b, deviceID: "m-phone", peerName: "Phone")
        XCTAssertEqual(mac.session(for: "m-phone")?.value, "A")
    }

    func testPerPhoneStateIsIsolated() {
        let registry = SessionRegistry<FakeSession>(localDeviceID: macID)
        _ = connect(registry, FakeSession("a"), phoneA, local: false)
        _ = connect(registry, FakeSession("z"), phoneZ, local: true)
        registry.update(phoneA) {
            $0.battery = RemoteBatteryStatus(level: 80, isCharging: true)
            $0.ringing = true
            $0.remoteFeatures[.clipboard] = false
        }
        XCTAssertEqual(registry.state(for: phoneA)?.battery, RemoteBatteryStatus(level: 80, isCharging: true))
        XCTAssertNil(registry.state(for: phoneZ)?.battery)
        XCTAssertEqual(registry.state(for: phoneZ)?.ringing, false)
        XCTAssertEqual(registry.state(for: phoneZ)?.remoteFeatures, PhoneLinkState().remoteFeatures)
        XCTAssertFalse(registry.update("unknown") { _ in })
    }

    func testBroadcastTargetsOnlyPhonesWithTheFeature() {
        let registry = SessionRegistry<FakeSession>(localDeviceID: macID)
        let a = FakeSession("a")
        _ = connect(registry, a, phoneA, local: false)
        _ = connect(registry, FakeSession("z"), phoneZ, local: true)
        registry.update(phoneZ) { $0.remoteFeatures[.battery] = false }
        registry.addPending(FakeSession("pairing"), initiatedLocally: false)
        let targets = registry.broadcastTargets { _, state in state.remoteFeatures[.battery] != false }
        XCTAssertEqual(targets.map(\.0), [phoneA])
        XCTAssertTrue(targets.first?.1 === a)
        XCTAssertEqual(registry.broadcastTargets { _, _ in true }.count, 2)
    }

    func testTargetIsSelectionWhileConnectedElseLatest() {
        let registry = SessionRegistry<FakeSession>(localDeviceID: macID)
        XCTAssertNil(registry.target(selected: nil))
        _ = connect(registry, FakeSession("a"), phoneA, local: false)
        _ = connect(registry, FakeSession("z"), phoneZ, local: true)
        XCTAssertEqual(registry.target(selected: nil), phoneZ)
        XCTAssertEqual(registry.target(selected: phoneA), phoneA)
        XCTAssertEqual(registry.target(selected: "gone"), phoneZ)
        XCTAssertEqual(registry.remove(registry.session(for: phoneZ)!), phoneZ)
        XCTAssertEqual(registry.target(selected: nil), phoneA)
    }

    func testCallsAreRemovedPerPhone() {
        var calls = ActiveRemoteCalls()
        let call = { (id: String, device: String) in
            RemoteCallStatus(notificationID: id, deviceID: device, applicationName: "Phone", caller: "Asha",
                             detail: "", type: "incoming", actions: [])
        }
        calls.update(call("1", phoneA))
        calls.update(call("2", phoneZ))
        XCTAssertEqual(calls.removeAll(deviceID: phoneA).map(\.notificationID), ["1"])
        XCTAssertEqual(calls.mostRelevant?.deviceID, phoneZ)
    }

    func testMultiDeviceRings() {
        let trusted = [TrustedDeviceInfo(id: phoneA, name: "OnePlus 11"), TrustedDeviceInfo(id: phoneZ, name: "Pixel 9")]
        let connected = [
            PhoneConnection(id: phoneA, name: "OnePlus 11", state: PhoneLinkState()),
            PhoneConnection(id: phoneZ, name: "Pixel 9", state: PhoneLinkState()),
        ]
        let rings = deviceRings(trusted: trusted, peers: [], connected: connected, pairing: .verification(PairingPrompt(peerName: "Galaxy", code: "123456")))
        XCTAssertEqual(rings.filter { $0.state == .connected }.count, 2)
        XCTAssertEqual(connectionSummary(connected, pairing: .idle), "Connected to 2 devices")
        XCTAssertEqual(connectionSummary(Array(connected.prefix(1)), pairing: .idle), "Connected to OnePlus 11")
    }
}
