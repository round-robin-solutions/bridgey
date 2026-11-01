package dev.bridgey.android.activity

import dev.bridgey.android.ClipboardSendResult
import dev.bridgey.android.PeerActivity
import dev.bridgey.android.PeerEvent
import java.io.File
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** One copy is one stream item, with each device's state; one clip through two devices is one item too. */
class ClipActivityTest {
    @get:Rule
    val folder = TemporaryFolder()

    private var now = 1_800_000_000_000L
    private val direct = java.util.concurrent.Executor { it.run() }
    private fun log(file: File? = null) = ActivityLog(file, direct) { now }

    private val targets = listOf("mbp" to "MacBook Pro", "work" to "Work Mac")

    private fun sent(device: String, name: String, result: ClipboardSendResult, group: String = "g1") = PeerEvent(
        PeerActivity.CLIPBOARD_SENT, device, name, "hello", automatic = true,
        groupId = group, groupTargets = targets, result = result,
    )

    @Test
    fun oneCopyToTwoMacsIsOneItemThatFollowsEachAnswer() {
        val file = File(folder.root, ActivityLog.FILE_NAME)
        val log = log(file)
        val groups = ClipActivityGroups()
        recordPeerEvent(log, sent("mbp", "MacBook Pro", ClipboardSendResult.DELIVERED), previews = true, groups = groups) { now }
        val first = log.items.value.single()
        assertEquals(listOf(ActivityPeerState.DELIVERED, ActivityPeerState.PENDING), first.peers!!.map { it.state })
        now += 500
        recordPeerEvent(log, sent("work", "Work Mac", ClipboardSendResult.DELIVERED), previews = true, groups = groups) { now }
        val item = log.items.value.single()
        assertEquals(first.id, item.id)
        assertEquals(first.atMillis, item.atMillis)
        assertEquals(listOf("MacBook Pro", "Work Mac"), item.peers!!.map { it.deviceName })
        assertTrue(item.peers!!.all { it.state == ActivityPeerState.DELIVERED })
        // Kept across a restart: names and states only.
        val reloaded = log(file).items.value.single()
        assertEquals(item.peers, reloaded.peers)
        val json = JSONArray(file.readText()).getJSONObject(0).getJSONArray("peers").getJSONObject(0)
        assertEquals(setOf("deviceId", "deviceName", "state"), json.keys().asSequence().toSet())
    }

    @Test
    fun aDeviceThatMissesItStaysOnTheItem() {
        val log = log()
        val groups = ClipActivityGroups()
        recordPeerEvent(log, sent("work", "Work Mac", ClipboardSendResult.NO_ACKNOWLEDGEMENT), previews = true, groups = groups) { now }
        // Nothing reached anyone yet: no item.
        assertTrue(log.items.value.isEmpty())
        recordPeerEvent(log, sent("mbp", "MacBook Pro", ClipboardSendResult.DELIVERED), previews = true, groups = groups) { now }
        val item = log.items.value.single()
        assertEquals(
            mapOf("MacBook Pro" to ActivityPeerState.DELIVERED, "Work Mac" to ActivityPeerState.FAILED),
            item.peers!!.associate { it.deviceName to it.state },
        )
    }

    @Test
    fun twoCopiesAreTwoItems() {
        val log = log()
        val groups = ClipActivityGroups()
        recordPeerEvent(log, sent("mbp", "MacBook Pro", ClipboardSendResult.DELIVERED, "g1"), previews = true, groups = groups) { now }
        now += 1_000
        recordPeerEvent(log, sent("mbp", "MacBook Pro", ClipboardSendResult.DELIVERED, "g2"), previews = true, groups = groups) { now }
        assertEquals(2, log.items.value.size)
    }

    @Test
    fun aManualSendThatFailedLeavesNoItem() {
        val log = log()
        recordPeerEvent(log, PeerEvent(PeerActivity.CLIPBOARD_SENT, "mbp", "MacBook Pro", "x", result = ClipboardSendResult.DISABLED), previews = true)
        assertTrue(log.items.value.isEmpty())
    }

    @Test
    fun theSameClipThroughTwoMacsIsOneItem() {
        val log = log()
        val groups = ClipActivityGroups()
        val fromMbp = PeerEvent(PeerActivity.CLIPBOARD_RECEIVED, "mbp", "MacBook Pro", "Room 2 at 4", automatic = true)
        recordPeerEvent(log, fromMbp, previews = true, groups = groups) { now }
        now += 800
        recordPeerEvent(log, fromMbp.copy(deviceId = "work", deviceName = "Work Mac"), previews = true, groups = groups) { now }
        val item = log.items.value.single()
        assertEquals("MacBook Pro", item.deviceName)
        assertEquals(listOf("MacBook Pro", "Work Mac"), item.peers!!.map { it.deviceName })
        // The same device again, other text, or after a minute: a new item.
        now += 1_000
        recordPeerEvent(log, fromMbp, previews = true, groups = groups) { now }
        recordPeerEvent(log, fromMbp.copy(clipboardText = "other", deviceId = "work"), previews = true, groups = groups) { now }
        now += ClipActivityGroups.WINDOW_MILLIS + 1
        recordPeerEvent(log, fromMbp.copy(deviceId = "work2", deviceName = "Old Mac"), previews = true, groups = groups) { now }
        assertEquals(4, log.items.value.size)
    }

    @Test
    fun offersMatchByItemHashes() {
        val log = log()
        val groups = ClipActivityGroups()
        val offer = PeerEvent(
            PeerActivity.CLIP_OFFER_RECEIVED, "mbp", "MacBook Pro", automatic = true,
            clipContent = "image", clipCount = 1, clipBytes = 2_000, clipHash = "abc",
        )
        recordPeerEvent(log, offer, previews = true, groups = groups) { now }
        recordPeerEvent(log, offer.copy(deviceId = "work", deviceName = "Work Mac"), previews = true, groups = groups) { now }
        assertEquals(1, log.items.value.size)
        recordPeerEvent(log, offer.copy(deviceId = "work", deviceName = "Work Mac", clipHash = "offer:2"), previews = true, groups = groups) { now }
        assertEquals(2, log.items.value.size)
    }

    @Test
    fun peersAreBoundedAndOnlyOnClipboardKinds() {
        val many = (0 until 40).map { ActivityPeer("d$it", "Device $it", ActivityPeerState.DELIVERED) }
        assertEquals(ActivityHistory.MAX_PEERS, ActivityHistory.cleanPeers(ActivityKind.CLIPBOARD_SENT, many)!!.size)
        assertNull(ActivityHistory.cleanPeers(ActivityKind.PING_SENT, many))
        val json = """[{"id":1,"kind":"clipboard_sent","deviceId":"a","deviceName":"A","count":1,"at":$now,
            "peers":[{"deviceId":"a","deviceName":"A","state":"delivered"},{"deviceName":"B","state":"teleported"}]}]"""
        assertEquals(listOf("A"), ActivityHistory.decode(json, now).single().peers!!.map { it.deviceName })
        assertFalse(ActivityHistory.encode(listOf(ActivityHistory.decode(json, now).single().copy(peers = null))).contains("peers"))
    }

    @Test
    fun namesJoinPlainly() {
        assertEquals("A", joinDeviceNames(listOf("A")))
        assertEquals("A and B", joinDeviceNames(listOf("A", "B")))
        assertEquals("A, B and C", joinDeviceNames(listOf("A", "B", "C")))
    }
}
