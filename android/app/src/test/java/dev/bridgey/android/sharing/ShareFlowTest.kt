package dev.bridgey.android.sharing

import dev.bridgey.android.routing.*
import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ShareFlowTest {
    private fun presence(state: PresenceState = PresenceState.ACTIVE, idle: Long? = 0, at: Long = 0) =
        ObservedPresence("session", DevicePresencePacket(1, state, idle), at)
    private fun mac(id: String, sample: ObservedPresence? = null) = ShareMac(id, id, "session", true, sample)

    @Test fun activeBeatsLastUsedAndConnectionOrder() {
        val a = mac("a", presence(idle = 20))
        val b = mac("b", presence(idle = 1))
        for (order in listOf(listOf(a,b), listOf(b,a))) assertEquals("b", shareDestination(order, "a", 1000))
    }
    @Test fun localArrivalAgeCountsAndTiesAreStable() {
        assertEquals("b", shareDestination(listOf(mac("a", presence(at = 0)), mac("b", presence(at = 2000))), null, 3000))
        assertEquals("a", shareDestination(listOf(mac("b", presence()), mac("a", presence())), null, 0))
    }
    @Test fun staleLockedUnknownAndIdleNeverCountAsActive() {
        for (p in listOf(presence(at = 0), presence(PresenceState.LOCKED, null, 20000),
                presence(PresenceState.UNKNOWN, null, 20000), presence(PresenceState.IDLE, 120, 20000))) {
            assertEquals("fallback", shareDestination(listOf(mac("active", p), mac("fallback")), "fallback", 20000))
            assertNull(shareDestination(listOf(mac("active", p), mac("fallback")), null, 20000))
        }
        assertNotNull(presence().activeAge(19999))
        assertNull(presence().activeAge(20000))
        assertNull(presence(idle = 119).activeAge(1000))
        assertNull(presence(at = 100).activeAge(99))
    }
    @Test fun connectedLastThenSingleOtherwiseAskWithDisabledPeersExcluded() {
        val a = mac("a"); val b = mac("b")
        assertEquals("b", shareDestination(listOf(a,b), "b", 0))
        assertNull(shareDestination(listOf(a,b), "offline", 0))
        assertEquals("a", shareDestination(listOf(a,b.copy(sessionId = null)), "b", 0))
        assertEquals("a", shareDestination(listOf(a,b.copy(allowed = false)), "b", 0))
        assertNull(shareDestination(listOf(a.copy(allowed = false)), "a", 0))
    }
    @Test fun alwaysAskPreselectsActiveWithoutSendingEvenForOneMac() {
        val a = mac("a", presence())
        val state = ShareFlow.begin(listOf(a), null, true, 0)
        assertEquals(SharePhase.CHOOSING, state.phase)
        assertEquals("a", state.target)
        assertEquals(SharePhase.GRACE, ShareFlow.begin(listOf(a), null, false, 0).phase)
    }
    @Test fun changeAndCancelInvalidateGraceAndLateResults() {
        val a = mac("a"); val b = mac("b")
        val initial = ShareFlow.begin(listOf(a), null, false, 0)
        assertEquals(SharePhase.CHOOSING, initial.change().phase)
        assertEquals("b", initial.change().choose(b).target)
        val cancelled = initial.cancel()
        assertEquals(cancelled, cancelled.send(listOf(a), "offline"))
        assertEquals(cancelled, cancelled.finish(true, "late"))
    }
    @Test fun destinationDoesNotFollowPresenceAndReconnectCannotStealTheSend() {
        val a = mac("a", presence()); val b = mac("b")
        val grace = ShareFlow.begin(listOf(a,b), null, false, 0)
        assertEquals("a", grace.send(listOf(a.copy(presence = null), b.copy(presence = presence())), "offline").target)
        assertEquals(SharePhase.FAILED, grace.send(listOf(a.copy(sessionId = "new"), b), "offline").phase)
        assertEquals(SharePhase.FAILED, grace.send(listOf(a.copy(allowed = false)), "off").phase)
        val sending = grace.send(listOf(a), "offline")
        assertEquals(sending, sending.send(listOf(a), "duplicate"))
        assertEquals(sending, sending.change())
        assertEquals(SharePhase.SUCCEEDED, sending.finish(true, "Opened").phase)
        assertEquals(SharePhase.PARKED, sending.finish(true, "Find it in the menu bar", parked = true).phase)
        val failed = sending.finish(false, "timeout")
        assertEquals(SharePhase.SENDING, failed.send(listOf(a), "offline").phase)
        assertEquals(SharePhase.CHOOSING, failed.change().phase)
    }
    @Test fun presenceSessionAndSequenceFencesSurviveOptOutAndExpire() {
        val store = DevicePresenceStore()
        val packet = DevicePresencePacket(10, PresenceState.ACTIVE, 0)
        assertTrue(store.receive("mac", "s1", packet, 0))
        assertFalse(store.receive("mac", "s1", packet.copy(sequence = 9), 1))
        assertNull(store.get("mac", "s2"))
        store.invalidate("mac")
        assertNull(store.get("mac", "s1"))
        assertFalse(store.receive("mac", "s1", packet, 30000))
        assertTrue(store.receive("mac", "s1", packet.copy(sequence = 11), 30001))
        store.remove("mac")
        assertTrue(store.receive("mac", "s2", packet.copy(sequence = 1), 30002))
        store.clear()
        assertNull(store.get("mac", "s2"))
    }
    @Test fun sharedPresenceVectors() {
        val vectors = JSONObject(File(System.getProperty("bridgey.repoRoot"), "protocol/test-vectors/device-presence-v1.json").readText()).getJSONArray("state")
        for (i in 0 until vectors.length()) {
            val v = vectors.getJSONObject(i)
            val bytes = (if (v.has("raw")) v.getString("raw") else v.getJSONObject("plaintext").toString()).toByteArray()
            assertEquals(v.getString("name"), v.getBoolean("valid"), decodeDevicePresence(bytes) != null)
        }
    }
}
