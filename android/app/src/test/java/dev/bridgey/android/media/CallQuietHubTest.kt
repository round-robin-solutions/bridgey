package dev.bridgey.android.media

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallQuietHubTest {
    private class Clock : CallMediaScheduler {
        private data class Task(val at: Long, val run: () -> Unit, var cancelled: Boolean = false)
        private val tasks = mutableListOf<Task>()
        var now = 0L
        override fun schedule(delayMs: Long, task: () -> Unit): () -> Unit {
            val entry = Task(now + delayMs, task); tasks += entry
            return { entry.cancelled = true }
        }
        fun advance(ms: Long) {
            val until = now + ms
            while (true) {
                val next = tasks.filter { !it.cancelled && it.at <= until }.minByOrNull { it.at } ?: break
                tasks.remove(next); now = next.at; next.run()
            }
            now = until
        }
    }
    private class Effects : CallQuietEffects {
        var active = emptySet<String>()
        var localCall = false
        var restores = 0
        var adoptions = 0
        private var ownsPlayback = false
        val released = mutableListOf<CallMediaReleaseReason>()
        override fun updateCalls(active: Set<String>, policy: CallMediaPolicy, localCallActive: Boolean) {
            if (this.active.isNotEmpty() && active.isEmpty() && ownsPlayback) { restores += 1; ownsPlayback = false }
            if (this.active.isEmpty() && active.isNotEmpty()) ownsPlayback = true
            this.active = active; localCall = localCallActive
        }
        override fun updatePolicy(policy: CallMediaPolicy) {}
        override fun release(reason: CallMediaReleaseReason) { released += reason; active = emptySet(); ownsPlayback = false }
        override fun adoptCalls(active: Set<String>, policy: CallMediaPolicy, localCallActive: Boolean) {
            adoptions += 1; this.active = active; localCall = localCallActive; ownsPlayback = false
        }
    }
    private val clock = Clock()
    private val effects = Effects()
    private var enabled = true
    private val a = CallQuietPeer("device-a", "session-a")
    private val b = CallQuietPeer("device-b", "session-b")
    private var peers = listOf(a, b)
    private val sent = mutableListOf<Triple<CallQuietPeer, String, JSONObject>>()
    private val hub = CallQuietHub(effects, clock, { clock.now }, { enabled }, { CallMediaPolicy() }, { peers },
        send = { peer, kind, payload -> sent += Triple(peer, kind, payload); true })

    @Test fun onlyCurrentPermittedSessionCanOriginateState() {
        assertFalse(hub.receiveState(a.copy(sessionId = "old"), CallQuietState(1, setOf("call"))))
        assertFalse(hub.receiveState(CallQuietPeer("unpaired", "x"), CallQuietState(1, setOf("call"))))
        assertTrue(effects.active.isEmpty())
        assertTrue(hub.receiveState(a, CallQuietState(1, setOf("call"))))
        assertEquals(setOf("device-a/call"), effects.active)
    }

    @Test fun endingOneSourceDoesNotRestoreUnderAnother() {
        hub.receiveState(a, CallQuietState(1, setOf("one")))
        hub.receiveState(b, CallQuietState(1, setOf("two")))
        hub.receiveState(a, CallQuietState(2, emptySet()))
        assertEquals(setOf("device-b/two"), effects.active)
        assertEquals(0, effects.restores)
        hub.receiveState(b, CallQuietState(2, emptySet()))
        assertEquals(1, effects.restores)
    }

    @Test fun identicalRevisionRenewsOnlyIdenticalCallsAndUncertainty() {
        hub.receiveState(a, CallQuietState(4, setOf("call")))
        clock.advance(50_000)
        assertFalse(hub.receiveState(a, CallQuietState(4, emptySet())))
        assertFalse(hub.receiveState(a, CallQuietState(4, setOf("call"), uncertain = true)))
        assertFalse(hub.receiveState(a, CallQuietState(3, setOf("call"))))
        clock.advance(25_000)
        assertTrue(effects.active.isEmpty())
        assertEquals(0, effects.restores)
        assertTrue(CallMediaReleaseReason.DISCONNECTED in effects.released)
    }

    @Test fun validRenewalExtendsTheBoundedSourceLease() {
        hub.receiveState(a, CallQuietState(4, setOf("call")))
        clock.advance(50_000)
        assertTrue(hub.receiveState(a, CallQuietState(4, setOf("call"))))
        clock.advance(74_999)
        assertTrue(effects.active.isNotEmpty())
        clock.advance(1)
        assertTrue(effects.active.isEmpty())
        assertEquals(0, effects.restores)
    }

    @Test fun uncertainVoipLossThenCellularEndNeverAutoplays() {
        hub.localCallsChanged(setOf("voip", "cell"))
        hub.localCallsChanged(setOf("cell"), uncertain = true)
        assertEquals(setOf("local/cell"), effects.active)
        hub.localCallsChanged(emptySet(), uncertain = true)
        assertTrue(effects.active.isEmpty())
        assertEquals(0, effects.restores)
        hub.localCallsChanged(emptySet(), uncertain = false)
        assertEquals(0, effects.restores)
    }

    @Test fun peerUncertaintyAlsoSurvivesAnUnrelatedCallsEnd() {
        hub.receiveState(a, CallQuietState(1, setOf("cell", "voip")))
        hub.receiveState(a, CallQuietState(2, setOf("cell"), uncertain = true))
        hub.receiveState(a, CallQuietState(3, emptySet(), uncertain = true))
        assertEquals(0, effects.restores)
        assertTrue(effects.active.isEmpty())
        hub.receiveState(a, CallQuietState(4, emptySet(), uncertain = false))
        assertEquals(0, effects.restores)
    }

    @Test fun activeAndUncertainSourceSnapshotsRenewAtMostEvery25Seconds() {
        hub.localCallsChanged(setOf("cell"))
        val initial = sent.count { it.second == "calls.quiet_state" }
        clock.advance(24_999)
        assertEquals(initial, sent.count { it.second == "calls.quiet_state" })
        clock.advance(1)
        assertEquals(initial + 2, sent.count { it.second == "calls.quiet_state" })
        hub.localCallsChanged(emptySet(), uncertain = true)
        val uncertain = sent.count { it.second == "calls.quiet_state" }
        clock.advance(25_000)
        assertEquals(uncertain + 2, sent.count { it.second == "calls.quiet_state" })
        assertTrue(sent.last { it.second == "calls.quiet_state" }.third.getBoolean("uncertain"))
    }

    @Test fun noRemoteSourceIsForwardedAsALocalCall() {
        hub.receiveState(a, CallQuietState(1, setOf("call")))
        hub.peersChanged()
        val states = sent.filter { it.second == "calls.quiet_state" }
        assertTrue(states.isNotEmpty())
        assertTrue(states.all { it.third.getJSONArray("calls").length() == 0 })
    }

    @Test fun featureRevocationAndSessionLossReleaseWithoutAutoplay() {
        hub.receiveState(a, CallQuietState(1, setOf("call")))
        peers = listOf(b); hub.peersChanged()
        assertTrue(effects.active.isEmpty())
        assertEquals(0, effects.restores)
        assertTrue(CallMediaReleaseReason.PERMISSION_LOST in effects.released)
    }

    @Test fun aNewSessionCannotTurnTheOldSessionsLossIntoAConfirmedCallEnd() {
        hub.receiveState(a, CallQuietState(1, setOf("call")))
        val replacement = a.copy(sessionId = "replacement")
        peers = listOf(replacement)
        hub.receiveState(replacement, CallQuietState(1, emptySet()))
        assertEquals(0, effects.restores)
        assertTrue(CallMediaReleaseReason.DISCONNECTED in effects.released)
    }

    @Test fun resultsMustMatchTheLatestLocalRevisionAndSession() {
        hub.localCallsChanged(setOf("call"))
        val revision = sent.first { it.second == "calls.quiet_state" }.third.getInt("revision")
        assertFalse(hub.receiveResult(a, CallQuietResult(revision - 1, 1, 0, 0, emptySet())))
        assertFalse(hub.receiveResult(a.copy(sessionId = "old"), CallQuietResult(revision, 1, 0, 0, emptySet())))
        assertTrue(hub.receiveResult(a, CallQuietResult(revision, 1, 0, 0, emptySet())))
    }

    @Test fun resultAcksAreCoalescedUntilObservedEffectsChange() {
        hub.receiveState(a, CallQuietState(1, setOf("call")))
        val count = sent.count { it.second == "calls.quiet_result" }
        hub.receiveState(a, CallQuietState(1, setOf("call")))
        assertEquals(count, sent.count { it.second == "calls.quiet_result" })
        hub.effectsChanged(CallMediaResult(CallMediaPhase.APPLIED, paused = 2))
        assertEquals(count + 1, sent.count { it.second == "calls.quiet_result" })
    }

    @Test fun lossUnderAnotherCallDoesNotAutoplayAndDoesNotPoisonTheNextInterval() {
        hub.receiveState(a, CallQuietState(1, setOf("a")))
        hub.receiveState(b, CallQuietState(1, setOf("b")))
        hub.disconnected(a.deviceId)
        hub.receiveState(b, CallQuietState(2, emptySet()))
        assertEquals(0, effects.restores)
        assertTrue(effects.active.isEmpty())
        hub.receiveState(b, CallQuietState(3, setOf("next")))
        hub.receiveState(b, CallQuietState(4, emptySet()))
        assertEquals(1, effects.restores)
    }

    @Test fun expiryUnderAnotherRenewedCallAlsoLeavesARestorationBarrier() {
        hub.receiveState(a, CallQuietState(1, setOf("a")))
        hub.receiveState(b, CallQuietState(1, setOf("b")))
        clock.advance(50_000)
        hub.receiveState(b, CallQuietState(1, setOf("b")))
        clock.advance(25_000)
        hub.receiveState(b, CallQuietState(2, emptySet()))
        assertEquals(0, effects.restores)
    }

    @Test fun leaseExpiryDoesNotResetTheCurrentSessionsRevisionFence() {
        hub.receiveState(a, CallQuietState(4, setOf("current")))
        clock.advance(75_000)
        assertFalse(hub.receiveState(a, CallQuietState(3, setOf("old"))))
        assertFalse(hub.receiveState(a, CallQuietState(4, setOf("changed"))))
        assertTrue(effects.active.isEmpty())
        assertTrue(hub.receiveState(a, CallQuietState(5, setOf("fresh"))))
    }

    @Test fun returningAlreadyHandledCallIsAdoptedWithoutQuietingManualPlaybackAgain() {
        hub.receiveState(a, CallQuietState(1, setOf("same-call")))
        hub.disconnected(a.deviceId)
        val returning = a.copy(sessionId = "returning")
        peers = listOf(returning)
        hub.receiveState(returning, CallQuietState(1, setOf("same-call")))
        assertEquals(1, effects.adoptions)
        hub.receiveState(returning, CallQuietState(2, emptySet()))
        hub.receiveState(returning, CallQuietState(3, setOf("new-call")))
        assertEquals(1, effects.adoptions)
    }
}
