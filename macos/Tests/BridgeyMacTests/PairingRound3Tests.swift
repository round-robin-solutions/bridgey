import Foundation
import XCTest
@testable import BridgeyMac

/// A monotonic clock the tests move by hand.
final class FakeClock {
    private(set) var now: TimeInterval = 1_000
    func read() -> TimeInterval { now }
    func advance(_ seconds: TimeInterval) { now += seconds }
    func set(_ value: TimeInterval) { now = value }
}

/// Pairing security round 3 (docs/security-review-0.10.md, second re-review): one test per attack.
final class PairingRound3Tests: XCTestCase {
    private func dialler(committed: Bool, hasKey: Bool = true) -> PairingPosition {
        PairingPosition(initiatedLocally: true, committed: committed, holdsRemoteCommitment: false, hasSessionKey: hasKey)
    }

    private func dialled(holdsCommitment: Bool, hasKey: Bool = true) -> PairingPosition {
        PairingPosition(initiatedLocally: false, committed: false, holdsRemoteCommitment: holdsCommitment, hasSessionKey: hasKey)
    }

    // MARK: 1. Trusted IDs and committed pairings

    /// Attack: one end forgot the other; a man in the middle starts a committed pairing under the trusted ID, hoping the
    /// end that still trusts it confirms without showing a code.
    func testACommittedPairingFromATrustedIDPromptsOnBothEnds() {
        XCTAssertFalse(PairingRules.autoConfirms(trusted: true, dialler(committed: true)))
        XCTAssertFalse(PairingRules.autoConfirms(trusted: true, dialled(holdsCommitment: true)))
        XCTAssertTrue(PairingRules.mayPromptUntrusted(dialler(committed: true)))
        XCTAssertTrue(PairingRules.mayPromptUntrusted(dialled(holdsCommitment: true)))
        // Only a plain reconnect skips the code.
        XCTAssertTrue(PairingRules.autoConfirms(trusted: true, dialler(committed: false)))
        XCTAssertTrue(PairingRules.autoConfirms(trusted: true, dialled(holdsCommitment: false)))
        XCTAssertFalse(PairingRules.autoConfirms(trusted: false, dialler(committed: false)))
        XCTAssertFalse(PairingRules.autoConfirms(trusted: false, dialled(holdsCommitment: false)))
    }

    /// Attack: cycle codes through committed offers under a trusted ID, which used to cost nothing.
    func testCommittedOffersFromTrustedIDsUseUpPairingAttempts() {
        XCTAssertTrue(PairingRules.chargesInboundAttempt(initiatedLocally: false, trusted: true, committedOffer: true))
        XCTAssertTrue(PairingRules.chargesInboundAttempt(initiatedLocally: false, trusted: false, committedOffer: true))
        XCTAssertFalse(PairingRules.chargesInboundAttempt(initiatedLocally: false, trusted: true, committedOffer: false))
        XCTAssertFalse(PairingRules.chargesInboundAttempt(initiatedLocally: true, trusted: true, committedOffer: true))
        XCTAssertEqual(PairingRules.inboundOffer(trusted: true, committed: true, remoteProtocol: 2, armed: true),
                       .answer(chargesLimiter: true))
    }

    // MARK: 2. Arming

    /// Attack: a device on the network sends committed offers while nobody is pairing, to put codes in front of a user
    /// who did not ask for them. Refused before the answer, and it costs no slot.
    func testACommittedOfferWhileNotArmedIsRefusedBeforeAnswering() {
        XCTAssertEqual(PairingRules.inboundOffer(trusted: false, committed: true, remoteProtocol: 2, armed: false), .refuse(.notArmed))
        XCTAssertEqual(PairingRules.inboundOffer(trusted: true, committed: true, remoteProtocol: 2, armed: false), .refuse(.notArmed))
        XCTAssertEqual(PairingRules.inboundOffer(trusted: false, committed: true, remoteProtocol: 2, armed: true), .answer(chargesLimiter: true))
        // A plain reconnect never needs arming.
        XCTAssertEqual(PairingRules.inboundOffer(trusted: true, committed: false, remoteProtocol: 2, armed: false), .answer(chargesLimiter: false))
        XCTAssertEqual(PairingRules.inboundOffer(trusted: true, committed: false, remoteProtocol: 1, armed: false), .answer(chargesLimiter: false))
    }

    func testAllowPairingArmsForTwoMinutesOnMonotonicTime() {
        let clock = FakeClock()
        var arming = PairingArming(now: clock.read)
        XCTAssertFalse(arming.isArmed)
        arming.arm()
        XCTAssertEqual(arming.remainingSeconds, 120)
        clock.advance(119.5)
        XCTAssertTrue(arming.isArmed)
        XCTAssertEqual(arming.remainingSeconds, 1)
        clock.advance(0.5)
        XCTAssertFalse(arming.isArmed)
        XCTAssertEqual(arming.remainingSeconds, 0)
        // Each tap starts the two minutes again.
        arming.arm()
        clock.advance(100)
        arming.arm()
        clock.advance(100)
        XCTAssertTrue(arming.isArmed)
        XCTAssertEqual(arming.remainingSeconds, 20)
        arming.disarm()
        XCTAssertFalse(arming.isArmed)
        // An open pairing screen holds it on, with no countdown, until it closes.
        arming.hold(true)
        clock.advance(10_000)
        XCTAssertTrue(arming.isArmed)
        XCTAssertEqual(arming.remainingSeconds, 0)
        arming.hold(false)
        XCTAssertFalse(arming.isArmed)
    }

    /// Attack: keep a pairing screen armed (or catch every Allow pairing) and cycle codes all day: three a minute, and
    /// never more than ten an hour.
    func testOffersCannotCycleCodesFasterThanTenAnHour() {
        let clock = FakeClock()
        var limiter = InboundPairingLimiter(now: clock.read)
        var answered = 0
        for _ in 0..<60 {
            for _ in 0..<5 where limiter.tryAcquire() { answered += 1 }
            clock.advance(60)
        }
        XCTAssertEqual(answered, 10)
        // An hour after the first ones, slots come back.
        clock.set(1_000 + InboundPairingLimiter.hour)
        XCTAssertTrue(limiter.tryAcquire())
    }

    /// Attack: move the Mac's wall clock back or forward so old attempts fall out of the window. The limiter and the
    /// arming read only the monotonic clock.
    func testTheLimiterRunsOnMonotonicTimeNotTheWallClock() {
        let uptime = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(systemUptimeClock(), uptime, accuracy: 1)
        let clock = FakeClock()
        var limiter = InboundPairingLimiter(limit: 3, window: 60, now: clock.read)
        for _ in 0..<3 { XCTAssertTrue(limiter.tryAcquire()) }
        // Whatever Date says, the same monotonic instant stays limited.
        XCTAssertFalse(limiter.tryAcquire())
        clock.advance(59.9)
        XCTAssertFalse(limiter.tryAcquire())
        clock.advance(0.1)
        XCTAssertTrue(limiter.tryAcquire())
    }

    // MARK: 3. Prompt tokens

    /// Attack (race): a second pairing replaces the prompt just as the user taps Codes match for the first; the tap
    /// must not confirm the code the user never saw.
    func testACodesMatchTapForAnEarlierPromptDoesNotConfirmANewOne() {
        XCTAssertTrue(PairingRules.promptMatches(sessionToken: "a1", requested: "a1"))
        XCTAssertFalse(PairingRules.promptMatches(sessionToken: "b2", requested: "a1"))
        XCTAssertFalse(PairingRules.promptMatches(sessionToken: nil, requested: "a1"))
        XCTAssertFalse(PairingRules.promptMatches(sessionToken: "a1", requested: ""))
        XCTAssertFalse(PairingRules.promptMatches(sessionToken: nil, requested: ""))
    }

    // MARK: 5. Pairing frames after authentication, tagged cancel

    /// Attack: inject pairing frames into an authenticated session (a second offer, confirm or reveal), or end it with a
    /// forged cancel.
    func testPairingFramesAfterAuthenticationAreDroppedExceptATaggedCancel() {
        for kind in ["pairing.offer", "pairing.answer", "pairing.reveal", "pairing.confirm"] {
            XCTAssertFalse(PairingRules.admitsPairingFrame(kind: kind, authenticated: true, hasEnvelopeKey: true, tagged: true, tagValid: true), kind)
            XCTAssertFalse(PairingRules.admitsPairingFrame(kind: kind, authenticated: true, hasEnvelopeKey: false, tagged: false, tagValid: false), kind)
        }
        XCTAssertTrue(PairingRules.admitsPairingFrame(kind: "pairing.cancel", authenticated: true, hasEnvelopeKey: true, tagged: true, tagValid: true))
        XCTAssertFalse(PairingRules.admitsPairingFrame(kind: "pairing.cancel", authenticated: true, hasEnvelopeKey: true, tagged: false, tagValid: false))
        XCTAssertFalse(PairingRules.admitsPairingFrame(kind: "pairing.cancel", authenticated: true, hasEnvelopeKey: true, tagged: true, tagValid: false))
        // A protocol 1 session has no tags at all.
        XCTAssertTrue(PairingRules.admitsPairingFrame(kind: "pairing.cancel", authenticated: true, hasEnvelopeKey: false, tagged: false, tagValid: false))
    }

    /// Attack: during the code check, send a cancel with a forged tag (for example a reason that blames the other end).
    func testAForgedTaggedCancelBeforeAuthenticationIsDropped() {
        XCTAssertFalse(PairingRules.admitsPairingFrame(kind: "pairing.cancel", authenticated: false, hasEnvelopeKey: true, tagged: true, tagValid: false))
        XCTAssertTrue(PairingRules.admitsPairingFrame(kind: "pairing.cancel", authenticated: false, hasEnvelopeKey: true, tagged: true, tagValid: true))
        // Untagged cancels are taken (the other end may not have the key yet), and so are tags this end cannot check.
        XCTAssertTrue(PairingRules.admitsPairingFrame(kind: "pairing.cancel", authenticated: false, hasEnvelopeKey: true, tagged: false, tagValid: false))
        XCTAssertTrue(PairingRules.admitsPairingFrame(kind: "pairing.cancel", authenticated: false, hasEnvelopeKey: false, tagged: true, tagValid: false))
        for kind in ["pairing.offer", "pairing.answer", "pairing.reveal", "pairing.confirm"] {
            XCTAssertTrue(PairingRules.admitsPairingFrame(kind: kind, authenticated: false, hasEnvelopeKey: false, tagged: false, tagValid: false), kind)
        }
        // The tag covers the reason: a relabelled reason no longer verifies.
        let key = SessionSecurity.envelopeKey(sessionKey: Data(repeating: 7, count: 32))
        var cancel = PairingMessage(kind: "pairing.cancel", sessionId: "s1", reason: PairingCancelReason.timeout.rawValue)
        cancel.tag = SessionSecurity.tag(envelopeKey: key, senderDeviceID: "phone", message: cancel)
        XCTAssertTrue(SessionSecurity.tagMatches(envelopeKey: key, senderDeviceID: "phone", message: cancel))
        cancel.reason = PairingCancelReason.mismatch.rawValue
        XCTAssertFalse(SessionSecurity.tagMatches(envelopeKey: key, senderDeviceID: "phone", message: cancel))
    }

    // MARK: 6. Uncommitted offers from untrusted devices

    /// Attack: relay an uncommitted (0.9-style) offer to get answered and charged, or to grind the code on the other leg.
    func testAnUntrustedOfferWithoutCommitmentIsRefusedBeforeItCostsAnAttempt() {
        for armed in [false, true] {
            XCTAssertEqual(PairingRules.inboundOffer(trusted: false, committed: false, remoteProtocol: 1, armed: armed), .refuse(.needsProtocol2))
            XCTAssertEqual(PairingRules.inboundOffer(trusted: false, committed: false, remoteProtocol: 2, armed: armed), .refuse(.notTrusted))
        }
    }

    // MARK: Reasons and timeouts

    func testCancelReasonsMapToWhatEachEndShows() {
        XCTAssertEqual(PairingCancelReason(wire: "mismatch"), .mismatch)
        XCTAssertEqual(PairingCancelReason(wire: "not_armed"), .notArmed)
        XCTAssertEqual(PairingCancelReason(wire: "needs_protocol_2"), .needsProtocol2)
        XCTAssertEqual(PairingCancelReason(wire: "something_new"), .cancelled)
        XCTAssertEqual(PairingCancelReason(wire: nil), .cancelled)
        func received(_ reason: PairingCancelReason, local: Bool = false, remote: Bool = false) -> PairingFailure? {
            PairingRules.failure(forCancel: reason, localConfirmed: local, remoteConfirmed: remote)
        }
        XCTAssertEqual(received(.mismatch), .mismatchRemote)
        XCTAssertEqual(received(.cancelled), .cancelledRemote)
        XCTAssertEqual(received(.busy), .busy)
        XCTAssertEqual(received(.rateLimited), .rateLimited)
        XCTAssertNil(received(.notArmed))
        XCTAssertEqual(received(.timeout, local: true), .timeoutRemote)
        XCTAssertEqual(received(.timeout, remote: true), .timeoutLocal)
        XCTAssertEqual(received(.timeout), .timeoutNeither)
        XCTAssertEqual(received(.timeout, local: true, remote: true), .timeoutNeither)
        XCTAssertEqual(PairingRules.timeoutFailure(localConfirmed: true, remoteConfirmed: false), .timeoutRemote)
        XCTAssertEqual(PairingRules.timeoutFailure(localConfirmed: false, remoteConfirmed: true), .timeoutLocal)
        XCTAssertEqual(PairingRules.timeoutFailure(localConfirmed: false, remoteConfirmed: false), .timeoutNeither)
    }

    func testEveryFailureNamesTheDeviceWithoutDashes() {
        let named: Set<PairingFailure> = [.cancelledRemote, .connectionLost, .busy, .mismatchRemote, .mismatchLocal, .timeoutRemote,
                                         .oldVersion, .noAnswer, .notAllowed, .rateLimited]
        for failure in PairingFailure.allCases {
            let message = failure.message(peerName: "Galaxy S24")
            XCTAssertFalse(message.isEmpty, failure.rawValue)
            XCTAssertFalse(message.contains("\u{2014}") || message.contains("\u{2013}"), failure.rawValue)
            XCTAssertEqual(message.contains("Galaxy S24"), named.contains(failure), failure.rawValue)
        }
        XCTAssertEqual(PairingFailure.mismatchRemote.message(peerName: "Galaxy S24"),
                       "Galaxy S24 said the codes don\u{2019}t match. Nothing was paired. Try again and check both screens show the same code.")
        XCTAssertEqual(PairingFailure.timeoutLocal.message(peerName: "Galaxy S24"), "Codes match was not tapped here in time.")
    }

    func testThePairingCodeIsGroupedAndReadDigitByDigit() {
        XCTAssertEqual(formattedPairingCode("482913"), "482 913")
        XCTAssertEqual(formattedPairingCode("482 913"), "482 913")
        XCTAssertEqual(formattedPairingCode("12345"), "12345")
        XCTAssertEqual(pairingCodeSpokenLabel("482913"), "4 8 2 9 1 3")
        XCTAssertEqual(pairingCodeSpokenLabel("482 913"), "4 8 2 9 1 3")
        XCTAssertEqual(pairingCountdownText(118), "1:58")
        XCTAssertEqual(pairingCountdownText(5), "0:05")
        XCTAssertEqual(pairingCountdownText(-3), "0:00")
    }
}
