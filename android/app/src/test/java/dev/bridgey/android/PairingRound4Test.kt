package dev.bridgey.android

import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pairing fixes from the review of the merged 0.10 branch (docs/security-review-0.10.md). */
class PairingRound4Test {
    /**
     * Attack: after the code is on screen, a man in the middle sends `not_armed`, hoping the phone keeps redialling
     * (and so keeps offering fresh codes) as if the Mac had never answered.
     */
    @Test
    fun notArmedAfterTheAnswerIsACancelNeverAWait() {
        assertNull(PairingRules.cancelFailure("not_armed", false, false, prompted = false, answered = false, hasSessionKey = false))
        assertEquals(
            PairingFailure.CANCELLED_REMOTE,
            PairingRules.cancelFailure("not_armed", false, false, prompted = false, answered = true, hasSessionKey = false),
        )
        assertEquals(
            PairingFailure.CANCELLED_REMOTE,
            PairingRules.cancelFailure("not_armed", false, false, prompted = false, answered = true, hasSessionKey = true),
        )
        assertEquals(
            PairingFailure.CANCELLED_REMOTE,
            PairingRules.cancelFailure("not_armed", localConfirmed = true, remoteConfirmed = false, prompted = true, answered = true, hasSessionKey = true),
        )
        assertTrue(PairingRules.beforeAnswer(answered = false, hasSessionKey = false, prompted = false))
        assertFalse(PairingRules.beforeAnswer(answered = true, hasSessionKey = false, prompted = false))
        assertFalse(PairingRules.beforeAnswer(answered = false, hasSessionKey = true, prompted = false))
        assertFalse(PairingRules.beforeAnswer(answered = false, hasSessionKey = false, prompted = true))
    }

    /** Attack: drip one byte at a time, never ending a frame, so the read never returns and the handshake never ends. */
    @Test
    fun aDripSocketIsClosedAtItsOwnDeadline() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            val client = Socket(InetAddress.getLoopbackAddress(), server.localPort)
            val accepted = server.accept().apply { soTimeout = 10_000 }
            val dripping = AtomicBoolean(true)
            val dripper = Thread {
                runCatching {
                    while (dripping.get()) {
                        client.getOutputStream().apply { write('a'.code); flush() }
                        Thread.sleep(100)
                    }
                }
            }.also(Thread::start)
            val readerEnded = CountDownLatch(1)
            val readError = AtomicBoolean(false)
            Thread {
                try {
                    accepted.getInputStream().readProtocolLine()
                } catch (_: IOException) {
                    readError.set(true)
                }
                readerEnded.countDown()
            }.start()
            val started = System.nanoTime()
            val expiries = AtomicInteger()
            val watchdog = scope.launchPendingWatchdog(
                settled = { accepted.isClosed },
                expired = { System.nanoTime() - started >= TimeUnit.MILLISECONDS.toNanos(1_000) },
                onExpire = {
                    expiries.incrementAndGet()
                    accepted.close()
                },
                pollMillis = 100,
            )
            assertTrue("the read is still blocked on the drip", readerEnded.await(5, TimeUnit.SECONDS))
            val elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
            assertTrue("closed at the deadline, not by the 10 s read timeout ($elapsed ms)", elapsed in 900..3_000)
            assertTrue(readError.get())
            assertEquals(1, expiries.get())
            watchdog.cancel()
            dripping.set(false)
            dripper.join(2_000)
            client.close()
        }
        scope.cancel()
    }

    @Test
    fun aSettledSessionNeverExpires() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val expired = AtomicInteger()
        val job = scope.launchPendingWatchdog(settled = { true }, expired = { true }, onExpire = { expired.incrementAndGet() }, pollMillis = 10)
        Thread.sleep(100)
        assertEquals(0, expired.get())
        assertTrue(job.isCompleted)
        scope.cancel()
    }

    /** Attack: forget a Mac, then answer the phone's still-scheduled background reconnect and hope it becomes a pairing. */
    @Test
    fun aBackgroundReconnectNeverCommitsAndStopsOnceForgotten() {
        assertFalse(PairingRules.diallerCommits(userStarted = false, targetTrusted = true))
        assertFalse(PairingRules.diallerCommits(userStarted = false, targetTrusted = false))
        assertTrue(PairingRules.diallerCommits(userStarted = true, targetTrusted = false))
        assertFalse(PairingRules.diallerCommits(userStarted = true, targetTrusted = true))
        assertFalse(PairingRules.backgroundDialAllowed(targetTrusted = false))
        assertTrue(PairingRules.backgroundDialAllowed(targetTrusted = true))
        // Even if one got through: an uncommitted dial never reaches a code prompt.
        val uncommitted = PairingPosition(initiatedLocally = true, committed = false, holdsRemoteCommitment = false, hasSessionKey = true)
        assertFalse(PairingRules.mayPromptUntrusted(uncommitted))
    }

    /** A pairing the user went through with a Mac they had disconnected finishes, instead of saying the connection was lost. */
    @Test
    fun aDeliberatePairingLiftsTheDisconnectHold() {
        assertFalse(PairingRules.heldBlocksCompletion(held = true, deliberate = true))
        assertTrue(PairingRules.heldBlocksCompletion(held = true, deliberate = false))
        assertFalse(PairingRules.heldBlocksCompletion(held = false, deliberate = false))
        val held = HeldDevices().apply { hold("mac-1") }
        val deliberate = true
        if (deliberate) held.release("mac-1")
        assertFalse(PairingRules.heldBlocksCompletion(held.isHeld("mac-1"), deliberate))
    }
}
