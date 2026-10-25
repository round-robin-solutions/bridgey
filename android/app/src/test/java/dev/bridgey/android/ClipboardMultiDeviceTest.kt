package dev.bridgey.android

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Automatic clipboard to several Macs: one offer, fetchable by every Mac it went to. */
class ClipboardMultiDeviceTest {
    private class Link(override val deviceId: String) : ClipboardLink {
        override val peerName = deviceId
        val sent = CopyOnWriteArrayList<Pair<String, ByteArray?>>()
        override fun send(kind: String, transferId: String?, payload: ByteArray?, sequence: Long?): Boolean {
            sent += kind to payload
            return true
        }
    }

    private val data = ByteArray(1_000) { it.toByte() }
    private val opener = object : ClipSourceOpener {
        override fun open(source: ClipSource): InputStream = ByteArrayInputStream(data)
        override fun currentSize(source: ClipSource): Long = data.size.toLong()
    }
    private val item = LocalClipItem("content://media/external/images/1", "image/png", "Screenshot.png", data.size.toLong())

    @Test
    fun everyMacTheOfferWentToCanFetchIt() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val outbox = ClipboardOutbox(scope, opener)
        val personal = Link("personal")
        val work = Link("work")
        val stranger = Link("other")
        val (offer, sources) = buildClipOffer(LocalClip.Items(listOf(item), false))!!
        outbox.publish(OutgoingClip(offer, sources, "personal", deviceIds = setOf("personal", "work")), listOf(personal, work), eagerLimitBytes = 0)

        outbox.onFetch(personal, ClipFetchRequest(offer.offerId, 0, UUID.randomUUID().toString()))
        outbox.onFetch(work, ClipFetchRequest(offer.offerId, 0, UUID.randomUUID().toString()))
        outbox.onFetch(stranger, ClipFetchRequest(offer.offerId, 0, UUID.randomUUID().toString()))

        assertEquals("files.offer", personal.sent.last().first)
        assertEquals("files.offer", work.sent.last().first)
        assertEquals(ClipErrorCode.EXPIRED, JSONObject(String(stranger.sent.last().second!!)).getString("code"))
        scope.cancel()
    }

    @Test
    fun eagerItemsArePushedToEachMac() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val outbox = ClipboardOutbox(scope, opener)
        val personal = Link("personal")
        val work = Link("work")
        val (offer, sources) = buildClipOffer(LocalClip.Items(listOf(item), false))!!
        outbox.publish(OutgoingClip(offer, sources, "personal", deviceIds = setOf("personal", "work")), listOf(personal, work), eagerLimitBytes = 10_000_000)
        assertTrue(personal.sent.any { it.first == "files.offer" })
        assertTrue(work.sent.any { it.first == "files.offer" })
        // One Mac disconnecting stops only its own pushes.
        outbox.disconnected("work")
        scope.cancel()
    }
}
