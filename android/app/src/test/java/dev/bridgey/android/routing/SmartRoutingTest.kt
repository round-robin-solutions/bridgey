package dev.bridgey.android.routing

import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SmartRoutingTest {
    @Test fun sameSessionOptOutDoesNotEraseReplayProtection() {
        val store = DevicePresenceStore()
        val messageIds = dev.bridgey.android.ReplayWindow()
        val active = DevicePresencePacket(10, PresenceState.ACTIVE, 0)
        val locked = DevicePresencePacket(20, PresenceState.LOCKED, null)
        assertTrue(messageIds.accept("old-active-frame"))
        assertTrue(store.receive("mac", "session", active, 0))
        assertTrue(store.receive("mac", "session", locked, 1_000))
        store.invalidate("mac")
        assertNull(store.get("mac", "session"))
        // Even when the outer message-ID window no longer remembers the old frame, its
        // authenticated sequence cannot acquire a fresh local timestamp after off/on.
        repeat(257) { assertTrue(messageIds.accept("later-$it")) }
        assertTrue(messageIds.accept("old-active-frame"))
        assertFalse(store.receive("mac", "session", active, 100_000))
        assertNull(store.get("mac", "session"))
        assertTrue(store.receive("mac", "session", active.copy(sequence = 21), 100_000))
        store.remove("mac")
        assertTrue(store.receive("mac", "new-session", active.copy(sequence = 1), 100_001))
    }

    @Test fun removalBetweenRecipientsCannotReselectOrResurrectAnAlert() {
        val routes = NotificationAlertRoutes()
        var activeMac = "A"
        val ticket = routes.plan("notification") { activeMac }!!
        val sent = mutableListOf<Pair<String, Boolean>>()
        val delivered = dispatchNotification(ticket, listOf("A", "B"), false,
            current = { routes.current(ticket) }, deviceId = { it }, send = { mac, alert ->
                sent += mac to alert
                if (mac == "A") { routes.remove("notification"); activeMac = "B" }
                true
            })
        assertEquals(listOf("A"), delivered)
        assertEquals(listOf("A" to true), sent)
        assertFalse(routes.contains("notification"))
        val replacement = routes.plan("notification") { activeMac }!!
        assertEquals("B", replacement.owner)
        assertFalse(routes.current(ticket), "a new lifetime with the same ID cannot validate old work")
        assertTrue(dispatchNotification(ticket, listOf("B"), false, { routes.current(ticket) }, { it },
            { _, _ -> fail("removed work must not send after the removal frame"); true }).isEmpty())
    }

    @Test fun activityChangeDuringFanoutCannotMoveItsCapturedOwner() {
        val routes = NotificationAlertRoutes()
        var activeMac = "A"
        val ticket = routes.plan("notification") { activeMac }!!
        val sent = mutableListOf<Pair<String, Boolean>>()
        dispatchNotification(ticket, listOf("A", "B"), false, { routes.current(ticket) }, { it }, { mac, alert ->
            sent += mac to alert
            activeMac = "B"
            true
        })
        assertEquals(listOf("A" to true, "B" to false), sent)
        assertEquals("A", routes.owner("notification") { activeMac })
    }

    @Test fun listenerRebindRetiresMissingOwnersButKeepsLiveAndTrackedCalls() {
        val routes = NotificationAlertRoutes()
        val live = routes.plan("live") { "A" }!!
        val missing = routes.plan("gone-during-unbind") { "A" }!!
        val call = routes.plan("rekeyed-call") { "A" }!!
        assertEquals(listOf("gone-during-unbind"), routes.retain(setOf("live")) { it == "rekeyed-call" })
        assertTrue(routes.current(live))
        assertTrue(routes.current(call))
        assertFalse(routes.current(missing))
    }

    private fun observed(state: PresenceState = PresenceState.ACTIVE, idle: Long? = 0, at: Long = 0) =
        ObservedPresence("session", DevicePresencePacket(1, state, idle), at)

    @Test fun sharedPresenceVectors() {
        val root = File(System.getProperty("bridgey.repoRoot") ?: "../..")
        val vectors = JSONObject(File(root, "protocol/test-vectors/device-presence-v1.json").readText()).getJSONArray("state")
        for (i in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(i)
            val raw = if (vector.has("raw")) vector.getString("raw") else vector.getJSONObject("plaintext").toString()
            assertEquals(vector.getString("name"), vector.getBoolean("valid"), decodeDevicePresence(raw.toByteArray()) != null)
        }
    }

    @Test fun mostRecentlyUsedWinsIndependentlyOfConnectionOrderOrPreferredChoice() {
        val a = RoutingCandidate("a", observed(idle = 5))
        val b = RoutingCandidate("b", observed(idle = 1))
        for (list in listOf(listOf(a, b), listOf(b, a))) assertEquals(RoutingDecision("b", RoutingReason.ACTIVE), chooseRoutingTarget(list, "a", 1_000))
    }

    @Test fun arrivalAgeIsAddedToIdleWithoutComparingRemoteWallClocks() {
        val a = RoutingCandidate("a", observed(idle = 0, at = 0))
        val b = RoutingCandidate("b", observed(idle = 0, at = 2_000))
        assertEquals("b", chooseRoutingTarget(listOf(a, b), null, 3_000).deviceId)
    }

    @Test fun noActiveOrPreferredMacKeepsTheNotificationOnThePhone() {
        assertEquals(RoutingDecision(null, RoutingReason.PHONE_ONLY), chooseRoutingTarget(listOf(RoutingCandidate("a", observed(PresenceState.IDLE, 120))), "offline", 0))
        assertNull(chooseRoutingTarget(emptyList(), "offline", 0).deviceId)
    }

    @Test fun explicitPreferenceWorksForIdleOrUnknownActivityButNeverKnownLocked() {
        assertEquals(RoutingDecision("a", RoutingReason.PREFERRED), chooseRoutingTarget(listOf(RoutingCandidate("a", null)), "a", 0))
        assertEquals("a", chooseRoutingTarget(listOf(RoutingCandidate("a", observed(PresenceState.IDLE, 120))), "a", 0).deviceId)
        val locked = listOf(RoutingCandidate("a", observed(PresenceState.LOCKED, null)))
        assertNull(chooseRoutingTarget(locked, "a", 0).deviceId)
        assertNull(chooseRoutingTarget(locked, "a", 100_000).deviceId)
    }

    @Test fun staleFutureAndNoLongerActiveSamplesCannotChooseAnActiveMac() {
        val active = listOf(RoutingCandidate("a", observed()))
        assertNull(chooseRoutingTarget(active, null, PRESENCE_FRESH_MILLIS).deviceId)
        assertNull(chooseRoutingTarget(active, null, -1).deviceId)
        assertNull(chooseRoutingTarget(listOf(RoutingCandidate("a", observed(idle = 119))), null, 1_000).deviceId)
    }

    @Test fun equalActivityHasAnOrderIndependentTieBreak() {
        val a = RoutingCandidate("a", observed())
        val b = RoutingCandidate("b", observed())
        assertEquals("a", chooseRoutingTarget(listOf(b, a), null, 0).deviceId)
        assertEquals("b", chooseRoutingTarget(listOf(a, b), "b", 0).deviceId)
    }

    @Test fun sequenceReplaysDoNotRefreshFreshnessAndSessionsDoNotInheritActivity() {
        val store = DevicePresenceStore()
        val p = DevicePresencePacket(4, PresenceState.ACTIVE, 0)
        assertTrue(store.receive("a", "first", p, 0))
        assertFalse(store.receive("a", "first", p, 19_000))
        assertFalse(store.get("a", "first")!!.fresh(20_000))
        assertNull(store.get("a", "second"))
        assertTrue(store.receive("a", "second", p.copy(sequence = 1), 20_000))
        assertNull(store.get("a", "first"))
        store.remove("a")
        assertNull(store.get("a", "second"))
    }

    @Test fun notificationUpdatesAndCallsDoNotMoveOrReplayAnAlert() {
        val routes = NotificationAlertRoutes(capacity = 2)
        assertEquals("a", routes.owner("first") { "a" })
        assertEquals("a", routes.owner("first") { fail("updates must not reselect"); "b" })
        assertNull(routes.owner("phone-only") { null })
        assertNull(routes.owner("phone-only") { "b" })
        // Overflow cannot evict an existing owner and later alert it on a second Mac.
        assertNull(routes.owner("overflow") { "b" })
        assertEquals("a", routes.owner("first") { "b" })
        routes.remove("first")
        assertEquals("b", routes.owner("new") { "b" })
        routes.clear()
        assertEquals("c", routes.owner("first") { "c" })
    }
}
