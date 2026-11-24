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

    // MARK: LAN first (lan_first_draft1)

    private final class TieredSession {
        let name: String
        let tier: SessionTier
        init(_ name: String, _ tier: SessionTier) {
            self.name = name
            self.tier = tier
        }
    }

    /// One side of the pair. `peerSupports`: the existing session's peer advertised lan_first_draft1.
    private func duplicate(local: String, remote: String, existing: (SessionTier, Bool), candidate: (SessionTier, Bool),
                           peerSupports: Bool, stale: Bool = false, transfer: Bool = false) -> String {
        let registry = SessionRegistry<TieredSession>(localDeviceID: local)
        let old = TieredSession("existing", existing.0)
        let new = TieredSession("candidate", candidate.0)
        registry.addPending(old, initiatedLocally: existing.1)
        _ = registry.authenticate(old, deviceID: remote, peerName: "Peer")
        registry.update(remote) { $0.remoteLanFirst = peerSupports }
        registry.addPending(new, initiatedLocally: candidate.1)
        _ = registry.authenticate(new, deviceID: remote, peerName: "Peer", isStale: { $0 === old && stale },
                                  tier: { $0.tier }, hasActiveTransfer: { $0 == remote && transfer })
        return registry.session(for: remote)?.name ?? "none"
    }

    func testLanFirstHigherTierWinsWhicheverSideDialled() {
        for (existingLocal, candidateLocal) in [(true, true), (true, false), (false, true), (false, false)] {
            XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.tunnel, existingLocal), candidate: (.lan, candidateLocal),
                                     peerSupports: true), "candidate", "LAN replaces the tunnel")
            XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.socket, existingLocal), candidate: (.lan, candidateLocal),
                                     peerSupports: true), "candidate", "LAN replaces Tailscale")
            XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.tunnel, existingLocal), candidate: (.socket, candidateLocal),
                                     peerSupports: true), "candidate", "a socket replaces the tunnel")
            XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.lan, existingLocal), candidate: (.tunnel, candidateLocal),
                                     peerSupports: true), "existing", "a tunnel never replaces LAN")
            XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.lan, existingLocal), candidate: (.socket, candidateLocal),
                                     peerSupports: true), "existing", "Tailscale never replaces LAN")
        }
    }

    func testLanFirstEqualTiersKeepTheDialledByLowerIDRule() {
        // m-mac < z-phone: the Mac's dial wins; a-phone < m-mac: the phone's dial wins; same side dialled: the newer one.
        XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.lan, true), candidate: (.lan, false), peerSupports: true), "existing")
        XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.lan, false), candidate: (.lan, true), peerSupports: true), "candidate")
        XCTAssertEqual(duplicate(local: macID, remote: phoneA, existing: (.tunnel, true), candidate: (.tunnel, false), peerSupports: true), "candidate")
        XCTAssertEqual(duplicate(local: macID, remote: phoneA, existing: (.tunnel, false), candidate: (.tunnel, true), peerSupports: true), "existing")
        XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.socket, true), candidate: (.socket, true), peerSupports: true), "candidate")
    }

    func testLanFirstNeverReplacesASessionWithATransferRunning() {
        XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.tunnel, false), candidate: (.lan, true),
                                 peerSupports: true, transfer: true), "existing", "no switch cancels a transfer")
        XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.lan, false), candidate: (.lan, true),
                                 peerSupports: true, transfer: true), "existing")
        XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.tunnel, false), candidate: (.lan, true),
                                 peerSupports: true, stale: true, transfer: true), "candidate", "a stale session loses first")
        XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.lan, true), candidate: (.tunnel, false),
                                 peerSupports: true, stale: true), "candidate", "even to a lower tier")
    }

    /// A peer without the key: exactly the rule before, tiers and transfers aside.
    func testWithoutTheKeyTodaysRuleExactly() {
        XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.lan, true), candidate: (.tunnel, true), peerSupports: false), "candidate")
        XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.tunnel, true), candidate: (.lan, false), peerSupports: false), "existing")
        XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.tunnel, false), candidate: (.lan, true),
                                 peerSupports: false, transfer: true), "candidate", "the transfer rule needs the key")
        XCTAssertEqual(duplicate(local: macID, remote: phoneZ, existing: (.lan, true), candidate: (.tunnel, false),
                                 peerSupports: false, stale: true), "candidate")
    }

    /// Both ends of one pair, each with its own view of who dialled, keep the same session.
    func testBothEndsAgree() {
        let tiers: [SessionTier] = [.tunnel, .socket, .lan]
        for existingTier in tiers {
            for candidateTier in tiers {
                for macDialledExisting in [true, false] {
                    for macDialledCandidate in [true, false] {
                        let mac = duplicate(local: macID, remote: phoneZ, existing: (existingTier, macDialledExisting),
                                            candidate: (candidateTier, macDialledCandidate), peerSupports: true)
                        let phone = duplicate(local: phoneZ, remote: macID, existing: (existingTier, !macDialledExisting),
                                              candidate: (candidateTier, !macDialledCandidate), peerSupports: true)
                        XCTAssertEqual(mac, phone, "\(existingTier) then \(candidateTier)")
                    }
                }
            }
        }
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

    /// Seen on the Work Mac (2026-11-01): it kept its own dial to the OnePlus (the Mac has the lower id) after the
    /// phone had dropped it, and refused 20 redials from the phone in 56 s. A silent live session loses whoever dialled.
    func testStaleSessionLosesToNewSessionWhoeverDialled() {
        let registry = SessionRegistry<FakeSession>(localDeviceID: macID)
        let own = FakeSession("Mac dialled")
        XCTAssertEqual(connect(registry, own, phoneZ, local: true), .accepted(replaced: nil))
        let redial = FakeSession("Phone redial")
        registry.addPending(redial, initiatedLocally: false)
        // Fresh: the lower id's socket stays (the duplicate rule).
        XCTAssertEqual(registry.authenticate(redial, deviceID: phoneZ, peerName: "Phone redial", isStale: { _ in false }), .rejected)
        let second = FakeSession("Phone redial 2")
        registry.addPending(second, initiatedLocally: false)
        XCTAssertEqual(registry.authenticate(second, deviceID: phoneZ, peerName: "Phone redial 2", isStale: { $0 === own }),
                       .accepted(replaced: own))
        XCTAssertTrue(registry.session(for: phoneZ) === second)
    }

    func testSessionLooksStaleAfterOneAndAHalfHeartbeats() {
        let now = Date()
        XCTAssertFalse(sessionLooksStale(supported: true, lastReceivedAt: now.addingTimeInterval(-14), tunnel: false, now: now))
        XCTAssertTrue(sessionLooksStale(supported: true, lastReceivedAt: now.addingTimeInterval(-15), tunnel: false, now: now))
        // A tunnel's heartbeat runs every 25 s.
        XCTAssertFalse(sessionLooksStale(supported: true, lastReceivedAt: now.addingTimeInterval(-30), tunnel: true, now: now))
        XCTAssertTrue(sessionLooksStale(supported: true, lastReceivedAt: now.addingTimeInterval(-40), tunnel: true, now: now))
        // A peer without heartbeats is never judged by silence.
        XCTAssertFalse(sessionLooksStale(supported: false, lastReceivedAt: now.addingTimeInterval(-600), tunnel: false, now: now))
    }

    func testDisconnectDetailNamesRouteDirectionAgeAndSilence() {
        let now = Date()
        XCTAssertEqual(disconnectDetail(tunnel: false, initiatedLocally: false, createdAt: now.addingTimeInterval(-94.6),
                                        lastReceivedAt: now.addingTimeInterval(-31.2), now: now), "tcp_in_age94_silent31")
        XCTAssertEqual(disconnectDetail(tunnel: true, initiatedLocally: true, createdAt: now, lastReceivedAt: now, now: now),
                       "tunnel_out_age0_silent0")
    }
}
