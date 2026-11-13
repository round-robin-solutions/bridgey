import XCTest
@testable import BridgeyMac

@MainActor
final class CallMediaPeersTests: XCTestCase {
    private var clock: TimeInterval = 0
    private var platform: CallMediaTestPlatform!
    private var peers: CallMediaPeers!
    private var allowed = Set<String>()
    private var enabled = true
    private var sent: [(String, String, [String: Any])] = []

    override func setUp() async throws {
        clock = 0; enabled = true; allowed = ["A", "B"]; sent = []
        platform = CallMediaTestPlatform()
        platform.sessions = [CallMediaSession(id: "player", bundleID: "test.media", contentID: "track",
                                              playing: true, position: 10, volume: 50, routeID: "speakers", canMute: true)]
        peers = CallMediaPeers(platform: platform, scheduler: CallMediaTestScheduler(), now: { [unowned self] in self.clock })
        peers.enabled = { [unowned self] in self.enabled }
        peers.allowed = { [unowned self] in self.allowed.contains($0) }
        peers.send = { [unowned self] id, kind, payload in self.sent.append((id, kind, payload)); return true }
    }

    private func ready(_ id: String = "A") { peers.peerReady(id, sessionID: "session-\(id)", permitted: allowed.contains(id)) }
    private func state(_ id: String = "A", revision: Int, calls: [String], uncertain: Bool = false) {
        peers.receiveState(CallMediaStatePacket(revision: revision, calls: calls, uncertain: uncertain),
                           from: id, sessionID: "session-\(id)")
    }

    func testReadinessSendsMinimalSnapshotAndSourceDoesNotDependOnNotificationContent() {
        ready()
        XCTAssertEqual(sent.first?.1, "calls.quiet_state")
        XCTAssertEqual(Set(sent[0].2.keys), ["version", "revision", "calls", "uncertain"])
        state(revision: 7, calls: ["opaque"])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
        let result = sent.last { $0.1 == "calls.quiet_result" }
        XCTAssertEqual(result?.2["revision"] as? Int, 7)
        XCTAssertEqual(result?.2["paused"] as? Int, 1)
        XCTAssertNil(result?.2["title"])
        XCTAssertNil(result?.2["caller"])
    }

    func testUnpermittedAndWrongSessionCannotCreateMediaEffects() {
        allowed.remove("A")
        ready()
        state(revision: 1, calls: ["call"])
        XCTAssertTrue(platform.requested.isEmpty)
        allowed.insert("A"); ready()
        peers.receiveState(CallMediaStatePacket(revision: 1, calls: ["call"]), from: "A", sessionID: "other-session")
        XCTAssertTrue(platform.requested.isEmpty)
        state(revision: 1, calls: ["call"])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
    }

    func testExplicitEndResumesButDisconnectAndExpiryNeverAutoplay() {
        ready()
        state(revision: 1, calls: ["call"])
        platform.completeAll()
        state(revision: 2, calls: [])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .resume])

        state(revision: 3, calls: ["another-call"])
        platform.completeAll()
        peers.drop("A")
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .resume, .pause])
        XCTAssertFalse(platform.sessions[0].playing)

        platform.sessions[0].playing = true
        ready()
        state(revision: 1, calls: ["third-call"])
        platform.completeAll()
        clock = 75
        peers.heartbeat()
        platform.completeAll()
        XCTAssertFalse(platform.sessions[0].playing)
        XCTAssertEqual(platform.applied.filter { $0 == .resume }.count, 1)
    }

    func testSameRevisionRenewsWithoutRepeatingQuietAndChangedSameRevisionDoesNotClear() {
        ready()
        state(revision: 1, calls: ["call"])
        platform.completeAll()
        clock = 50
        state(revision: 1, calls: ["call"])
        state(revision: 1, calls: [])
        clock = 100
        peers.heartbeat()
        XCTAssertEqual(peers.localResult.activeCalls, 1)
        XCTAssertEqual(platform.requested, [.pause])
        state(revision: 2, calls: [])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .resume])
    }

    func testMixedUncertainSourceCannotAutoplayWhenAnotherSourceEndsNormally() {
        ready("A"); ready("B")
        state("A", revision: 1, calls: ["a"])
        platform.completeAll()
        state("B", revision: 1, calls: ["b"])
        state("A", revision: 2, calls: [], uncertain: true)
        state("B", revision: 2, calls: [])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
        XCTAssertFalse(platform.sessions[0].playing)
        state("A", revision: 3, calls: [], uncertain: false)
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause], "lost ownership is not revived by a later unrelated certainty change")
    }

    func testLostOverlappingSourceBlocksThisIntervalButNotTheNextUnrelatedCall() {
        ready("A"); ready("B")
        state("A", revision: 1, calls: ["a"])
        platform.completeAll()
        state("B", revision: 1, calls: ["b"])
        peers.drop("A")
        state("B", revision: 2, calls: [])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
        platform.sessions[0].playing = true // A future unrelated call gets a fresh ownership interval.
        state("B", revision: 3, calls: ["later"])
        platform.completeAll()
        state("B", revision: 4, calls: [])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .pause, .resume])
    }

    func testLegacyCallOnlyBlocksRestorationWithoutStartingAllPlayerQuiet() {
        peers.setLegacyCallActive(true)
        XCTAssertTrue(platform.requested.isEmpty)
        ready()
        state(revision: 1, calls: ["new-protocol-call"])
        platform.completeAll()
        state(revision: 2, calls: [])
        XCTAssertEqual(platform.applied, [.pause])
        peers.setLegacyCallActive(false)
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .resume])
    }

    func testManualMarkFansOutOnlyItsOwnStateAndRenewsAtMostEvery25Seconds() {
        ready("A"); ready("B")
        peers.setManualCall(true)
        platform.completeAll()
        let active = sent.filter { $0.1 == "calls.quiet_state" && ($0.2["calls"] as? [String])?.count == 1 }
        XCTAssertEqual(active.count, 2)
        XCTAssertNotNil((active.first?.2["calls"] as? [String])?.first.flatMap(UUID.init(uuidString:)))
        XCTAssertTrue(platform.localCallActive)
        clock = 24; peers.heartbeat()
        XCTAssertEqual(sent.filter { $0.1 == "calls.quiet_state" }.count, 4)
        clock = 25; peers.heartbeat()
        XCTAssertEqual(sent.filter { $0.1 == "calls.quiet_state" }.count, 6)
        state("A", revision: 1, calls: ["private-remote-call"])
        peers.setManualCall(false)
        let latest = sent.last { $0.1 == "calls.quiet_state" }
        XCTAssertEqual(latest?.2["calls"] as? [String], [])
        XCTAssertFalse((latest?.2["calls"] as? [String] ?? []).contains("private-remote-call"))
    }

    func testResultMustMatchCurrentSessionAndLastSentSourceRevision() {
        ready()
        let result = CallMediaResultPacket(revision: 999, paused: 1, muted: 0, limited: 0, issues: [])
        peers.receiveResult(result, from: "A", sessionID: "session-A")
        XCTAssertNil(peers.remoteResults["A"])
        let matching = CallMediaResultPacket(revision: 1, paused: 1, muted: 0, limited: 0, issues: [])
        peers.receiveResult(matching, from: "A", sessionID: "old-session")
        XCTAssertNil(peers.remoteResults["A"])
        peers.receiveResult(matching, from: "A", sessionID: "session-A")
        XCTAssertEqual(peers.remoteResults["A"], matching)
    }

    func testNewSessionEmptyStateIsNotAnEndOfThePreviousSessionsCall() {
        ready()
        state(revision: 9, calls: ["old-call"])
        platform.completeAll()
        peers.peerReady("A", sessionID: "replacement", permitted: true)
        peers.receiveState(CallMediaStatePacket(revision: 1, calls: []), from: "A", sessionID: "replacement")
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
        XCTAssertFalse(platform.sessions[0].playing)
    }

    func testReplacementSessionCannotEraseOverlapLossAndTheNextEpisodeIsIndependent() {
        ready("A"); ready("B")
        state("A", revision: 1, calls: ["a"])
        platform.completeAll()
        state("B", revision: 1, calls: ["b"])
        peers.peerReady("A", sessionID: "replacement", permitted: true)
        peers.receiveState(CallMediaStatePacket(revision: 1, calls: []), from: "A", sessionID: "replacement")
        state("B", revision: 2, calls: [])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])

        platform.sessions[0].playing = true
        state("B", revision: 3, calls: ["next"])
        platform.completeAll()
        state("B", revision: 4, calls: [])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .pause, .resume])
    }

    func testReturningHandledCallDoesNotRepeatQuietAfterManualPlayback() {
        ready()
        state(revision: 1, calls: ["same-call"])
        platform.completeAll()
        clock = 75; peers.heartbeat()
        platform.completeAll()
        platform.sessions[0].playing = true
        state(revision: 1, calls: ["same-call"])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
        state(revision: 2, calls: [])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
        state(revision: 3, calls: ["new-call"])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .pause])
    }

    func testEachManualActivationHasANewOpaqueCallID() {
        ready()
        peers.setManualCall(true)
        let first = sent.last { $0.1 == "calls.quiet_state" }?.2["calls"] as? [String]
        platform.completeAll()
        peers.setManualCall(false)
        platform.completeAll()
        peers.setManualCall(true)
        let next = sent.last { $0.1 == "calls.quiet_state" }?.2["calls"] as? [String]
        XCTAssertEqual(first?.count, 1)
        XCTAssertEqual(next?.count, 1)
        XCTAssertNotEqual(first, next)
    }

    func testLegacyLossAfterDraftEndCannotAutoplay() {
        ready()
        state(revision: 1, calls: ["draft"])
        platform.completeAll()
        peers.setLegacySources(["legacy"])
        state(revision: 2, calls: [])
        peers.legacySourceLost("legacy")
        peers.setLegacySources([])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
        platform.sessions[0].playing = true
        state(revision: 3, calls: ["next"])
        platform.completeAll()
        state(revision: 4, calls: [])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .pause, .resume])
    }

    func testLegacyLossBeforeDraftEndCannotAutoplay() {
        ready()
        state(revision: 1, calls: ["draft"])
        platform.completeAll()
        peers.setLegacySources(["legacy"])
        peers.legacySourceLost("legacy")
        peers.setLegacySources([])
        state(revision: 2, calls: [])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
    }

}
