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
        val limiter = InboundPairingLimiter()
        var answered = 0
        for (attempt in 0 until 10) {
            if (PairingRules.chargesInboundAttempt(initiatedLocally = false, trusted = false) && limiter.tryAcquire(attempt * 1_000L)) answered++
        }
        assertEquals(3, answered)
        // Trusted reconnects and this device's own dials do not count.
        assertFalse(PairingRules.chargesInboundAttempt(initiatedLocally = false, trusted = true))
        assertFalse(PairingRules.chargesInboundAttempt(initiatedLocally = true, trusted = false))
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
        val limiter = InboundPairingLimiter(limit = 3, windowMillis = 60_000L)
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
