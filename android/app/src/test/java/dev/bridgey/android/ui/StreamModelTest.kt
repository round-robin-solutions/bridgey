package dev.bridgey.android.ui

import dev.bridgey.android.FileTransferState
import dev.bridgey.android.PairingState
import dev.bridgey.android.TrustedDevice
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.activity.ActivityKind
import dev.bridgey.android.activity.TransferOutcome
import dev.bridgey.android.activity.transferOutcome
import dev.bridgey.android.ui.motion.MotionMode
import dev.bridgey.android.ui.motion.resolveMotion
import dev.bridgey.core.discovery.DiscoveredPeer
import java.util.Calendar
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamModelTest {
    private val zone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now = Calendar.getInstance(zone).apply {
        set(2026, Calendar.OCTOBER, 25, 9, 41, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private fun peer(id: String?, name: String) = DiscoveredPeer("svc-$name", id, name, "macos", 1, "10.0.0.2", 42_458)

    private fun item(id: Long, kind: ActivityKind, device: String, minutesAgo: Long) =
        ActivityItem(id, kind, device, device, if (kind.carriesFileName) "f.pdf" else null, null, null, false, false, 1, now - minutesAgo * 60_000)

    @Test
    fun ringsShowEveryTrustedDeviceAndNearbyOnesInReadingOrder() {
        val trusted = listOf(TrustedDevice("a", "Mac mini"), TrustedDevice("b", "Work MacBook"), TrustedDevice("c", "Personal Mac"))
        val peers = listOf(peer("c", "Personal Mac"), peer("z", "Studio"), peer(null, "Unknown"))
        val rings = deviceRings(trusted, peers, PairingState.Connected("b", "Work MacBook"))
        assertEquals(listOf("Work MacBook", "Personal Mac", "Mac mini", "Studio", "Unknown"), rings.map { it.name })
        assertEquals(listOf(RingState.CONNECTED, RingState.NEARBY, RingState.OFFLINE, RingState.NEARBY, RingState.NEARBY), rings.map { it.state })
        assertEquals(listOf(true, true, true, false, false), rings.map { it.trusted })
    }

    @Test
    fun aConnectedDeviceNotYetInTheTrustListStillShows() {
        val rings = deviceRings(emptyList(), emptyList(), PairingState.Connected("x", "New Mac"))
        assertEquals(RingState.CONNECTED, rings.single().state)
        assertTrue(rings.single().trusted)
    }

    @Test
    fun connectingIsShownOnTheMatchingRing() {
        val rings = deviceRings(listOf(TrustedDevice("a", "Mac mini")), listOf(peer("a", "Mac mini")), PairingState.Connecting("Mac mini"))
        assertEquals(RingState.CONNECTING, rings.single().state)
    }

    @Test
    fun sendTargetPrefersThePickThenTheConnectedDevice() {
        val rings = deviceRings(
            listOf(TrustedDevice("a", "Mac mini"), TrustedDevice("b", "Work MacBook")),
            emptyList(),
            PairingState.Connected("b", "Work MacBook"),
        )
        assertEquals("b", sendTarget(rings, null)?.deviceId)
        assertEquals("a", sendTarget(rings, "a")?.deviceId)
        assertEquals("b", sendTarget(rings, "gone")?.deviceId)
        assertNull(sendTarget(emptyList(), null))
    }

    @Test
    fun streamGroupsByDayFiltersAndMarksRailEnds() {
        val items = listOf(
            item(5, ActivityKind.CLIPBOARD_SENT, "b", 1),
            item(4, ActivityKind.CALL_SHOWN, "b", 30),
            item(3, ActivityKind.FILE_RECEIVED, "c", 60),
            item(2, ActivityKind.NOTIFICATIONS_SHOWN, "b", 60 * 24),
            item(1, ActivityKind.PING_SENT, "a", 60 * 24 * 3),
        )
        val rows = streamRows(items, StreamFilter.ALL, null, now, zone)
        assertEquals(
            listOf("header:TODAY", "item:5", "item:4", "item:3", "header:YESTERDAY", "item:2", "header:EARLIER", "item:1"),
            rows.map { it.key },
        )
        val today = rows.filterIsInstance<StreamRow.Item>().filter { it.section == DaySection.TODAY }
        assertEquals(listOf(true, false, false), today.map { it.first })
        assertEquals(listOf(false, false, true), today.map { it.last })

        assertEquals(listOf("header:TODAY", "item:3"), streamRows(items, StreamFilter.FILES, null, now, zone).map { it.key })
        assertEquals(listOf("header:TODAY", "item:4"), streamRows(items, StreamFilter.CALLS, null, now, zone).map { it.key })
        assertEquals(listOf("header:YESTERDAY", "item:2"), streamRows(items, StreamFilter.ALERTS, null, now, zone).map { it.key })
        assertEquals(
            listOf("header:TODAY", "item:5", "item:4", "header:YESTERDAY", "item:2"),
            streamRows(items, StreamFilter.ALL, "b", now, zone).map { it.key },
        )
    }

    @Test
    fun streamDropsItemsPastSevenDays() {
        val items = listOf(item(1, ActivityKind.PING_SENT, "a", 60 * 24 * 8))
        assertTrue(streamRows(items, StreamFilter.ALL, null, now, zone).isEmpty())
    }

    @Test
    fun liveTransfersAreRunningOrRetryable() {
        val transfers = listOf(
            FileTransferState("1", "a.pdf", "Sending a.pdf: 40%", active = true, progressPercent = 40, startedAtMillis = 1),
            FileTransferState("2", "b.pdf", "b.pdf saved on Mac", active = false, progressPercent = null, startedAtMillis = 2),
            FileTransferState("3", "c.pdf", "File transfer failed", active = false, progressPercent = null, startedAtMillis = 3, retryable = true),
        ).associateBy { it.id }
        assertEquals(listOf("3", "1"), liveTransfers(transfers).map { it.id })
    }

    @Test
    fun finishedTransfersMapToStreamEvents() {
        fun t(status: String, active: Boolean = false, retryable: Boolean = false) =
            FileTransferState("1", "a.pdf", status, active, null, retryable = retryable)
        assertNull(transferOutcome(t("Sending a.pdf: 10%", active = true)))
        assertEquals(TransferOutcome.SENT, transferOutcome(t("a.pdf saved on Mac")))
        assertEquals(TransferOutcome.RECEIVED, transferOutcome(t("a.pdf saved to Download/Bridgey")))
        assertNull(transferOutcome(t("Transfer cancelled")))
        assertNull(transferOutcome(t("Transfer cancelled by Mac")))
        assertNull(transferOutcome(t("File transfer failed", retryable = true)))
        assertEquals(TransferOutcome.FAILED, transferOutcome(t("File transfer failed")))
    }

    @Test
    fun onlyKeysAddedAfterTheFirstShowArrive() {
        val tracker = ArrivalTracker()
        tracker.update(listOf("item:2", "item:1"))
        assertFalse(tracker.consume("item:2"))
        tracker.update(listOf("item:3", "item:2", "item:1"))
        tracker.update(listOf("item:3", "item:2", "item:1"))
        assertTrue(tracker.consume("item:3"))
        assertFalse(tracker.consume("item:3"))
        // A key that was shown, removed and shown again is not new.
        tracker.update(listOf("item:3"))
        tracker.update(listOf("item:3", "item:1"))
        assertFalse(tracker.consume("item:1"))
    }

    @Test
    fun motionStillsWhenReducedOrAnimatorScaleIsZero() {
        assertEquals(MotionMode.Full, resolveMotion(1f, reduceMotion = false).mode)
        assertEquals(MotionMode.Fade, resolveMotion(1f, reduceMotion = true).mode)
        assertEquals(MotionMode.Instant, resolveMotion(0f, reduceMotion = false).mode)
        assertEquals(MotionMode.Instant, resolveMotion(0f, reduceMotion = true).mode)
        val full = resolveMotion(1f, false)
        assertEquals(0.5f, full.pop.dampingRatio)
        assertEquals(600f, full.pop.stiffness)
        assertEquals(0.6f, full.small.dampingRatio)
        assertEquals(800f, full.small.stiffness)
        assertEquals(1600f, full.effects.stiffness)
        assertEquals(380f, full.page.stiffness)
        assertEquals(0.15f, full.pageSlideFraction)
        assertEquals(0.92f, full.pressScaleButton)
        assertEquals(150, resolveMotion(1f, true).fade.durationMillis)
    }

    @Test
    fun notificationAppCountsExcludeDisabled() {
        assertEquals(2 to 3, notificationAppCounts(mapOf("a" to "A", "b" to "B", "c" to "C"), setOf("b")))
    }
}
