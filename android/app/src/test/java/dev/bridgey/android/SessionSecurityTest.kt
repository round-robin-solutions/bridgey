package dev.bridgey.android

import java.util.Base64
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Protocol 2 helpers from the v0.10 security review (docs/security-review-0.10.md). */
class SessionSecurityTest {
    @Test
    fun onlyPairingKindsAreAllowedBeforeAuthentication() {
        listOf("pairing.offer", "pairing.answer", "pairing.reveal", "pairing.confirm", "pairing.cancel").forEach {
            assertTrue(it, SessionSecurity.allowedBeforeAuthentication(it))
        }
        listOf(
            "files.cancel", "files.accept", "files.complete.ack", "files.rejected", "files.cancel.ack", "clipboard.ack",
            "clipboard.rejected", "heartbeat.ping", "calls.request", "find.start", "pairing", "pairingx.offer", "",
        ).forEach { assertFalse(it, SessionSecurity.allowedBeforeAuthentication(it)) }
    }

    private fun dialler(committed: Boolean = true, hasKey: Boolean = false) =
        PairingPosition(initiatedLocally = true, committed = committed, holdsRemoteCommitment = false, hasSessionKey = hasKey)

    private fun dialled(holdsCommitment: Boolean = false, hasKey: Boolean = false) =
        PairingPosition(initiatedLocally = false, committed = false, holdsRemoteCommitment = holdsCommitment, hasSessionKey = hasKey)

    /** Attack: commit in the offer, then send an answer with a key chosen after seeing the responder's. */
    @Test
    fun anAnswerSentToTheDialledEndInsteadOfARevealIsRefused() {
        val afterCommittedOffer = dialled(holdsCommitment = true)
        assertFalse(PairingRules.acceptsAnswer(afterCommittedOffer))
        assertTrue(PairingRules.acceptsReveal(afterCommittedOffer))
        assertFalse(PairingRules.acceptsOffer(afterCommittedOffer))
        // Before any offer, and after a plain offer, the dialled end takes no answer either.
        assertFalse(PairingRules.acceptsAnswer(dialled()))
        assertFalse(PairingRules.acceptsAnswer(dialled(hasKey = true)))
        // Once the reveal set the key, nothing else replaces it.
        val afterReveal = dialled(holdsCommitment = true, hasKey = true)
        assertFalse(PairingRules.acceptsReveal(afterReveal))
        assertFalse(PairingRules.acceptsAnswer(afterReveal))
    }

    @Test
    fun theDiallerTakesOnlyOneAnswerAndNeverAnOfferOrReveal() {
        assertTrue(PairingRules.acceptsAnswer(dialler()))
        assertFalse(PairingRules.acceptsAnswer(dialler(hasKey = true)))
        assertFalse(PairingRules.acceptsReveal(dialler()))
        assertFalse(PairingRules.acceptsOffer(dialler()))
        assertTrue(PairingRules.acceptsOffer(dialled()))
        assertFalse(PairingRules.acceptsOffer(dialled(hasKey = true)))
    }

    /** Attack: answer committed offers one after another and give up before each reveal, to try codes for free. */
    @Test
    fun answeredOffersThatNeverRevealStillUseUpPairingAttempts() {
        var now = 0L
        val limiter = InboundPairingLimiter({ now })
        var answered = 0
        for (attempt in 0 until 10) {
            now = attempt * 1_000L
            if (PairingRules.chargesInboundAttempt(initiatedLocally = false, trusted = false, committedOffer = true) && limiter.tryAcquire()) answered++
        }
        assertEquals(3, answered)
        // Plain reconnects from trusted devices and this device's own dials do not count.
        assertFalse(PairingRules.chargesInboundAttempt(initiatedLocally = false, trusted = true, committedOffer = false))
        assertFalse(PairingRules.chargesInboundAttempt(initiatedLocally = true, trusted = false, committedOffer = true))
    }

    /** Attack (round 3, item 1): reuse a trusted device's ID with a commitment, to pair without a prompt or a limit. */
    @Test
    fun aCommittedPairingUnderATrustedDeviceIdPromptsAndIsCharged() {
        // The committed offer from a trusted ID pays for its slot like any new pairing.
        assertTrue(PairingRules.chargesInboundAttempt(initiatedLocally = false, trusted = true, committedOffer = true))
        // Neither end confirms by itself: the dialled end holds the commitment, the dialler committed.
        assertFalse(PairingRules.autoConfirms(dialled(holdsCommitment = true, hasKey = true), trusted = true))
        assertFalse(PairingRules.autoConfirms(dialler(committed = true, hasKey = true), trusted = true))
        // Only a plain reconnect (trusted, nobody committed) confirms without the code.
        assertTrue(PairingRules.autoConfirms(dialled(holdsCommitment = false, hasKey = true), trusted = true))
        assertTrue(PairingRules.autoConfirms(dialler(committed = false, hasKey = true), trusted = true))
        assertFalse(PairingRules.autoConfirms(dialled(holdsCommitment = false, hasKey = true), trusted = false))
    }

    /** Attack (round 3, item 2): send committed offers to a phone nobody is pairing with, to get prompts on its screen. */
    @Test
    fun aCommittedOfferToAnUnarmedPhoneIsRefusedBeforeTheAnswer() {
        assertEquals(OfferVerdict.NOT_ARMED, offer(commitment = "c", armed = false))
        assertEquals(OfferVerdict.NOT_ARMED, offer(commitment = "c", armed = false, trusted = true))
        assertEquals(OfferVerdict.ANSWER, offer(commitment = "c", armed = true))
        // A plain reconnect from a trusted device needs no arming.
        assertEquals(OfferVerdict.ANSWER, offer(publicKey = "k", armed = false, trusted = true))
    }

    /** Attack (round 3, item 2): keep pairing open by tapping once and coming back much later. */
    @Test
    fun allowPairingLastsTwoMinutesOnTheMonotonicClockAndScreensHoldIt() {
        var now = 1_000_000L
        val arming = PairingArming({ now })
        assertFalse(arming.isArmed())
        arming.arm()
        assertTrue(arming.isArmed())
        assertEquals(120, arming.remainingSeconds())
        now += 119_001
        assertEquals(1, arming.remainingSeconds())
        // Each tap restarts the two minutes.
        arming.arm()
        now += 60_000
        assertTrue(arming.isArmed())
        assertEquals(60, arming.remainingSeconds())
        now += 60_000
        assertFalse(arming.isArmed())
        assertEquals(0, arming.remainingSeconds())
        // A pairing screen holds pairing on with no countdown; two screens nest.
        arming.hold(true)
        arming.hold(true)
        arming.hold(false)
        now += 3_600_000
        assertTrue(arming.isArmed())
        assertEquals(0, arming.remainingSeconds())
        arming.hold(false)
        arming.hold(false)
        assertFalse(arming.isArmed())
        arming.arm()
        arming.disarm()
        assertFalse(arming.isArmed())
    }

    /** Attack (round 3, item 2): cycle offers slowly, three a minute, all day. */
    @Test
    fun inboundPairingIsCappedAtTenAnHourOnTheMonotonicClock() {
        var now = 0L
        val limiter = InboundPairingLimiter({ now })
        var answered = 0
        // One attempt every 21 s: never more than 3 a minute, so only the hourly cap stops it.
        repeat(60) {
            if (limiter.tryAcquire()) answered++
            now += 21_000
        }
        assertEquals(10, answered)
        now = 3_600_000L
        assertTrue(limiter.tryAcquire())
    }

    private fun offer(
        deviceId: String? = "mac",
        publicKey: String? = null,
        commitment: String? = null,
        protocolVersion: Long = 2,
        trusted: Boolean = false,
        armed: Boolean = true,
    ) = PairingRules.offerVerdict(deviceId, publicKey, commitment, protocolVersion, trusted, armed)

    /** Attack (round 3, item 6): an offer without a commitment from an unknown device, to skip the commitment. */
    @Test
    fun anUncommittedOfferFromAnUnknownDeviceIsRefusedWithAReason() {
        assertEquals(OfferVerdict.NEEDS_PROTOCOL_2, offer(publicKey = "k", protocolVersion = 1))
        assertEquals(OfferVerdict.NOT_TRUSTED, offer(publicKey = "k", protocolVersion = 2))
        // Refused before arming matters: not armed still says why.
        assertEquals(OfferVerdict.NEEDS_PROTOCOL_2, offer(publicKey = "k", protocolVersion = 1, armed = false))
        // Trusted devices on protocol 1 still reconnect (the pin refuses a downgrade later).
        assertEquals(OfferVerdict.ANSWER, offer(publicKey = "k", protocolVersion = 1, trusted = true))
    }

    /** Attack (round 3, item 6): hold reader threads with offers that can never pair. */
    @Test
    fun aMalformedOfferClosesTheConnection() {
        assertEquals(OfferVerdict.MALFORMED, offer(deviceId = null, commitment = "c"))
        assertEquals(OfferVerdict.MALFORMED, offer(deviceId = "", commitment = "c"))
        assertEquals(OfferVerdict.MALFORMED, offer(publicKey = null, commitment = null))
        assertEquals(OfferVerdict.MALFORMED, offer(commitment = "c", protocolVersion = 1))
    }

    /** Attack (round 3, item 3): a second pairing arrives while the first prompt is on screen, and the tap lands on it. */
    @Test
    fun theCodePromptIsClaimedOnceAndButtonsActOnlyOnTheirToken() {
        data class Fake(val token: String, val closed: Boolean = false)
        val slot = PairingSlot<Fake>()
        val claims = java.util.concurrent.atomic.AtomicInteger()
        val published = java.util.concurrent.atomic.AtomicInteger()
        val start = java.util.concurrent.CountDownLatch(1)
        val threads = List(32) { index ->
            Thread {
                start.await()
                if (slot.claim(Fake("t$index"), busy = { !it.closed }) { published.incrementAndGet() }) claims.incrementAndGet()
            }.also(Thread::start)
        }
        start.countDown()
        threads.forEach(Thread::join)
        assertEquals(1, claims.get())
        assertEquals(1, published.get())
        val owner = slot.current!!
        // A button shown for another pairing does nothing.
        assertEquals(null, slot.withToken("someone-else") { it.token })
        assertEquals(null, slot.takeWithToken("someone-else") { it.token })
        assertEquals(owner, slot.withToken(owner.token) { it.token })
        assertEquals(owner, slot.takeWithToken(owner.token) { it.token })
        assertEquals(null, slot.current)
        // A finished (closed) pairing no longer blocks the next one.
        val closed = Fake("old", closed = true)
        slot.set(closed)
        assertTrue(slot.claim(Fake("new"), busy = { !it.closed }) {})
        assertFalse(slot.releaseIf(closed))
    }

    /** Attack (round 3, item 5): replay pairing frames into an authenticated session, or forge a cancel. */
    @Test
    fun pairingFramesAfterAuthenticationAreDroppedExceptATaggedCancel() {
        fun verdict(kind: String, authenticated: Boolean = true, key: Boolean = true, tagged: Boolean = true, valid: Boolean = true, same: Boolean = true) =
            PairingRules.admitFrame(kind, authenticated, same, key, tagged) { valid }
        listOf("pairing.offer", "pairing.answer", "pairing.reveal", "pairing.confirm").forEach {
            assertEquals(it, FrameVerdict.PAIRING_AFTER_AUTHENTICATION, verdict(it))
        }
        assertEquals(FrameVerdict.ADMIT, verdict("pairing.cancel"))
        assertEquals(FrameVerdict.BAD_TAG, verdict("pairing.cancel", tagged = false, valid = false))
        assertEquals(FrameVerdict.BAD_TAG, verdict("pairing.cancel", valid = false))
        assertEquals(FrameVerdict.UNAUTHENTICATED, verdict("pairing.cancel", same = false))
        // A protocol 1 session has no envelope key: its cancel is taken as before.
        assertEquals(FrameVerdict.ADMIT, verdict("pairing.cancel", key = false, tagged = false, valid = false))
        // Before authentication: pairing frames pass; a tagged cancel must verify once there is a key.
        assertEquals(FrameVerdict.ADMIT, verdict("pairing.confirm", authenticated = false, tagged = false))
        assertEquals(FrameVerdict.ADMIT, verdict("pairing.cancel", authenticated = false, tagged = false, valid = false))
        assertEquals(FrameVerdict.BAD_TAG, verdict("pairing.cancel", authenticated = false, valid = false))
        assertEquals(FrameVerdict.ADMIT, verdict("pairing.cancel", authenticated = false, key = false, valid = false))
        // Everything else needs an authenticated session and a valid tag.
        assertEquals(FrameVerdict.UNAUTHENTICATED, verdict("clipboard.update", authenticated = false))
        assertEquals(FrameVerdict.BAD_TAG, verdict("clipboard.update", valid = false))
        assertEquals(FrameVerdict.ADMIT, verdict("clipboard.update"))
    }

    @Test
    fun cancelReasonsMapToWhatEachEndShows() {
        assertEquals(PairingFailure.MISMATCH_REMOTE, PairingRules.cancelFailure("mismatch", false, false, prompted = true))
        assertEquals(PairingFailure.CANCELLED_REMOTE, PairingRules.cancelFailure(null, false, false, prompted = true))
        assertEquals(PairingFailure.CANCELLED_REMOTE, PairingRules.cancelFailure("something_new", false, false, prompted = true))
        assertEquals(PairingFailure.TIMEOUT_REMOTE, PairingRules.cancelFailure("timeout", localConfirmed = true, remoteConfirmed = false, prompted = true))
        assertEquals(PairingFailure.TIMEOUT_LOCAL, PairingRules.cancelFailure("timeout", localConfirmed = false, remoteConfirmed = true, prompted = true))
        assertEquals(PairingFailure.TIMEOUT_NEITHER, PairingRules.cancelFailure("timeout", false, false, prompted = true))
        assertEquals(PairingFailure.TIMEOUT, PairingRules.cancelFailure("timeout", false, false, prompted = false))
        assertEquals(PairingFailure.BUSY, PairingRules.cancelFailure("busy", false, false, prompted = false))
        assertEquals(PairingFailure.RATE_LIMITED, PairingRules.cancelFailure("rate_limited", false, false, prompted = false))
        assertEquals(PairingFailure.OLD_VERSION, PairingRules.cancelFailure("needs_protocol_2", false, false, prompted = false))
        assertEquals(null, PairingRules.cancelFailure("not_armed", false, false, prompted = false))
        assertEquals("cancelled", PairingCancelReason.normalized("x".repeat(40)))
    }

    /** Attack: answer a reconnect dial under a trusted ID in different letter case, hoping for a code prompt. */
    @Test
    fun aReconnectDialThatDidNotCommitNeverPrompts() {
        assertFalse(PairingRules.mayPromptUntrusted(dialler(committed = false, hasKey = true)))
        assertTrue(PairingRules.mayPromptUntrusted(dialler(committed = true, hasKey = true)))
        assertTrue(PairingRules.mayPromptUntrusted(dialled(holdsCommitment = true, hasKey = true)))
    }

    /** Attack: relay a 0.9-style offer (key, no commitment) to this end and grind the other leg to the same code. */
    @Test
    fun aFirstPairingFromAnOfferWithoutCommitmentNeverPrompts() {
        assertFalse(PairingRules.mayPromptUntrusted(dialled(holdsCommitment = false, hasKey = true)))
    }

    @Test
    fun pendingAdmissionChecksAndAddsInOneStep() {
        val registry = SessionRegistry<Any>("local")
        val admitted = java.util.concurrent.atomic.AtomicInteger()
        val start = java.util.concurrent.CountDownLatch(1)
        val threads = List(64) {
            Thread {
                start.await()
                if (registry.addPendingIf(Any(), initiatedLocally = false) { it.size < 8 }) admitted.incrementAndGet()
            }.also(Thread::start)
        }
        start.countDown()
        threads.forEach(Thread::join)
        assertEquals(8, admitted.get())
        assertEquals(8, registry.pendingSessions().size)
    }

    @Test
    fun pendingConnectionsAreCappedInAllAndPerAddress() {
        assertTrue(admitsPendingConnection(emptyList(), "10.0.0.2"))
        assertTrue(admitsPendingConnection(listOf("10.0.0.2", "10.0.0.2"), "10.0.0.2"))
        assertFalse(admitsPendingConnection(listOf("10.0.0.2", "10.0.0.2", "10.0.0.2"), "10.0.0.2"))
        assertTrue(admitsPendingConnection(listOf("10.0.0.2", "10.0.0.2", "10.0.0.2"), "10.0.0.3"))
        assertFalse(admitsPendingConnection(List(8) { "10.0.0.${it + 10}" }, "10.0.0.3"))
        assertTrue(admitsPendingConnection(List(7) { "10.0.0.${it + 10}" }, null))
    }

    @Test
    fun inboundPairingPromptsAreLimitedPerMinute() {
        val limiter = InboundPairingLimiter({ 0L })
        assertTrue(limiter.tryAcquire(0))
        assertTrue(limiter.tryAcquire(1_000))
        assertTrue(limiter.tryAcquire(2_000))
        assertFalse(limiter.tryAcquire(3_000))
        assertFalse(limiter.tryAcquire(59_999))
        assertTrue(limiter.tryAcquire(60_000))
        assertFalse(limiter.tryAcquire(60_001))
    }

    @Test
    fun peerNamesLoseControlAndBidiCharactersAndAreBounded() {
        assertEquals("Rahul's Mac", sanitizedPeerName("Rahul's Mac", "Mac"))
        assertEquals("Macgpj.exe", sanitizedPeerName("Mac\u202Egpj.exe", "Mac"))
        assertEquals("ab", sanitizedPeerName("a\u0000\nb\u2066", "Mac"))
        assertEquals("Mac", sanitizedPeerName("  \u200F ", "Mac"))
        assertEquals("Mac", sanitizedPeerName(null, "Mac"))
        assertEquals(MAX_PEER_NAME_CHARS, sanitizedPeerName("x".repeat(10_000), "Mac").length)
    }

    @Test
    fun commitmentBindsSessionAndKey() {
        val commitment = SessionSecurity.commitment("s1", "BAAA")
        assertTrue(SessionSecurity.commitmentMatches(commitment, "s1", "BAAA"))
        assertFalse(SessionSecurity.commitmentMatches(commitment, "s2", "BAAA"))
        assertFalse(SessionSecurity.commitmentMatches(commitment, "s1", "BAAB"))
        assertFalse(SessionSecurity.commitmentMatches("not base64 !", "s1", "BAAA"))
        assertFalse(SessionSecurity.commitmentMatches("", "s1", "BAAA"))
    }

    @Test
    fun lengthPrefixingKeepsFieldBoundaries() {
        // Without the prefixes "ab" + "c" and "a" + "bc" would read the same; absent differs from empty.
        assertFalse(SessionSecurity.lengthPrefixed(listOf("ab", "c")).contentEquals(SessionSecurity.lengthPrefixed(listOf("a", "bc"))))
        assertFalse(SessionSecurity.lengthPrefixed(listOf(null)).contentEquals(SessionSecurity.lengthPrefixed(listOf(""))))
        assertFalse(SessionSecurity.lengthPrefixed(listOf("a\u0000", "b")).contentEquals(SessionSecurity.lengthPrefixed(listOf("a", "\u0000b"))))
    }

    /** Fuzz: random envelopes, keys and tags never verify unless the tag was made for exactly that frame. */
    @Test
    fun randomTagsAndMutatedFramesNeverVerify() {
        val random = Random(20261027)
        val key = ByteArray(32).also(random::nextBytes)
        repeat(500) {
            val message = Message(
                kind = listOf("clipboard.update", "calls.request", "find.start", "files.cancel", "x")[random.nextInt(5)],
                sessionId = "s" + random.nextInt(1000),
                messageId = if (random.nextBoolean()) "m" + random.nextLong() else null,
                nonce = if (random.nextBoolean()) Base64.getEncoder().encodeToString(random.nextBytes(12)) else null,
                ciphertext = if (random.nextBoolean()) Base64.getEncoder().encodeToString(random.nextBytes(random.nextInt(64))) else null,
                transferId = if (random.nextBoolean()) "t" + random.nextInt() else null,
                sequence = if (random.nextBoolean()) random.nextLong(0, 1L shl 53) else null,
            )
            val sender = "device-" + random.nextInt(4)
            val good = message.copy(tag = SessionSecurity.tag(key, sender, message))
            assertTrue(SessionSecurity.tagMatches(key, sender, good))
            // An empty field reads as absent after decoding, so the tag treats it the same.
            assertTrue(SessionSecurity.tagMatches(key, sender, good.copy(deviceName = "", targetDeviceId = if (good.targetDeviceId == null) "" else good.targetDeviceId)))
            assertFalse(SessionSecurity.tagMatches(ByteArray(32).also(random::nextBytes), sender, good))
            assertFalse(SessionSecurity.tagMatches(key, sender, good.copy(tag = Base64.getEncoder().encodeToString(random.nextBytes(32)))))
            assertFalse(SessionSecurity.tagMatches(key, sender, good.copy(tag = "%%%")))
            val mutated = when (random.nextInt(5)) {
                0 -> good.copy(kind = good.kind + "x")
                1 -> good.copy(sessionId = good.sessionId + "x")
                2 -> good.copy(messageId = (good.messageId ?: "") + "x")
                3 -> good.copy(transferId = (good.transferId ?: "") + "x")
                else -> good.copy(sequence = (good.sequence ?: 0L) + 1)
            }
            assertFalse(SessionSecurity.tagMatches(key, sender, mutated))
        }
    }
}
