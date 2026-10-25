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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalClipboardTest {
    private val image = LocalClipItem("content://media/external/images/1", "image/png", "Screenshot.png", 2_100_000)
    private val video = LocalClipItem("content://media/external/video/2", "video/mp4", "video.mp4", 340_000_000)

    @Test
    fun withAnOlderPeerTextBehavesExactlyAsBefore() {
        val long = LocalClip.Text("a".repeat(MAX_CLIPBOARD_CONTENT_BYTES + 1), null, false)
        assertEquals(ClipboardAutoDecision.SKIP_TOO_LARGE, autoClipDecision(long, available = true, offersAvailable = false, lastHash = null))
        assertEquals(ClipboardAutoDecision.SEND, autoClipDecision(LocalClip.Text("hi", null, false), true, false, null))
        assertEquals(ClipboardAutoDecision.SKIP_SENSITIVE, autoClipDecision(LocalClip.Text("pin", null, true), true, false, null))
        assertEquals(ClipboardAutoDecision.SKIP_UNAVAILABLE, autoClipDecision(LocalClip.Items(listOf(image), false), true, false, null))
    }

    @Test
    fun longTextImagesAndFilesBecomeOffers() {
        val long = LocalClip.Text("a".repeat(MAX_CLIPBOARD_CONTENT_BYTES + 1), null, false)
        assertEquals(ClipboardAutoDecision.SEND_OFFER, autoClipDecision(long, true, true, null))
        assertEquals(ClipboardAutoDecision.SEND, autoClipDecision(LocalClip.Text("short", null, false), true, true, null), "short text keeps clipboard.update")
        assertEquals(ClipboardAutoDecision.SEND_OFFER, autoClipDecision(LocalClip.Items(listOf(image, video), false), true, true, null))
        assertEquals(ClipboardAutoDecision.SKIP_SENSITIVE, autoClipDecision(LocalClip.Items(listOf(image), true), true, true, null))
        assertEquals(ClipboardAutoDecision.SKIP_UNAVAILABLE, autoClipDecision(LocalClip.Items(listOf(image), false), false, true, null))
    }

    @Test
    fun clipsFromTheMacNeverBounceBack() {
        assertEquals(ClipboardAutoDecision.SKIP_DUPLICATE, autoClipDecision(LocalClip.Own, true, true, null))
        assertNull(LocalClip.Own.hash())
    }

    @Test
    fun duplicateFilesAreDetectedWithoutReadingThem() {
        val clip = LocalClip.Items(listOf(video), false)
        val hash = clip.hash()
        assertEquals(ClipboardAutoDecision.SKIP_DUPLICATE, autoClipDecision(LocalClip.Items(listOf(video), false), true, true, hash))
        val changed = LocalClip.Items(listOf(video.copy(size = video.size + 1)), false)
        assertEquals(ClipboardAutoDecision.SEND_OFFER, autoClipDecision(changed, true, true, hash), "a different size is a different copy")
    }

    @Test
    fun textAndHtmlTogetherDecideTheOldLimit() {
        assertTrue(textFitsLegacy("a".repeat(1000), "<b>${"a".repeat(1000)}</b>"))
        assertTrue(!textFitsLegacy("a".repeat(20_000), "b".repeat(20_000)))
        assertTrue(!textFitsLegacy("", null))
    }

    @Test
    fun offersDescribeImagesAndFiles() {
        val (offer, sources) = buildClipOffer(LocalClip.Items(listOf(image, video), false), offerId = UUID.randomUUID().toString())!!
        assertEquals(listOf(ClipItemKind.IMAGE, ClipItemKind.FILE), offer.items.map(ClipOfferItem::kind))
        assertEquals(listOf(null, "video.mp4"), offer.items.map(ClipOfferItem::name))
        assertEquals(listOf(2_100_000L, 340_000_000L), offer.items.map(ClipOfferItem::size))
        assertTrue("no content read at offer time", offer.items.all { it.sha256 == null && it.inline == null })
        assertEquals(ClipSource.Content(video.uri, video.size), sources[1])
    }

    @Test
    fun longTextOffersInlineOnlyWhatFits() {
        val text = "z".repeat(40_000)
        val (offer, _) = buildClipOffer(LocalClip.Text(text, "<p>x</p>", false))!!
        assertEquals(listOf(ClipItemKind.TEXT, ClipItemKind.HTML), offer.items.map(ClipOfferItem::kind))
        assertNull("40 KB of text is not inline", offer.items[0].inline)
        assertTrue("the small HTML is", offer.items[1].inline != null)
        assertTrue(offer.items.all { it.sha256 != null })
    }

    @Test
    fun atMostAHundredItemsAreOffered() {
        val many = (0 until 150).map { image.copy(uri = "content://x/$it") }
        assertEquals(100, buildClipOffer(LocalClip.Items(many, false))!!.first.items.size)
    }

    private class Recorder : ClipboardLink {
        override val deviceId = "mac"
        override val peerName = "Work MacBook"
        val sent = CopyOnWriteArrayList<Pair<String, ByteArray?>>()
        override fun send(kind: String, transferId: String?, payload: ByteArray?, sequence: Long?): Boolean {
            sent += kind to payload
            return true
        }
    }

    @Test
    fun theSenderAnswersStaleAndChangedFetches() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        var size = 100L
        val opener = object : ClipSourceOpener {
            override fun open(source: ClipSource): InputStream = ByteArrayInputStream(ByteArray(size.toInt()))
            override fun currentSize(source: ClipSource): Long = size
        }
        val outbox = ClipboardOutbox(scope, opener)
        val link = Recorder()
        val (offer, sources) = buildClipOffer(LocalClip.Items(listOf(video.copy(size = 100)), false))!!
        outbox.publish(OutgoingClip(offer, sources, "mac"), link, eagerLimitBytes = 0)
        fun code(): String = JSONObject(String(link.sent.last().second!!)).getString("code")

        outbox.onFetch(link, ClipFetchRequest(UUID.randomUUID().toString(), 0, UUID.randomUUID().toString()))
        assertEquals(ClipErrorCode.EXPIRED, code())
        outbox.onFetch(link, ClipFetchRequest(offer.offerId, 5, UUID.randomUUID().toString()))
        assertEquals(ClipErrorCode.EXPIRED, code())
        size = 101
        outbox.onFetch(link, ClipFetchRequest(offer.offerId, 0, UUID.randomUUID().toString()))
        assertEquals(ClipErrorCode.CHANGED, code())
        size = 100
        outbox.invalidate(link)
        outbox.onFetch(link, ClipFetchRequest(offer.offerId, 0, UUID.randomUUID().toString()))
        assertEquals(ClipErrorCode.CHANGED, code(), "the clipboard changed since the offer")
        scope.cancel()
    }

    @Test
    fun theSenderStreamsAFetchedItemAsAClipboardTransfer() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val data = ByteArray(60_000) { (it % 7).toByte() }
        val opener = object : ClipSourceOpener {
            override fun open(source: ClipSource): InputStream = ByteArrayInputStream(data)
            override fun currentSize(source: ClipSource): Long = data.size.toLong()
        }
        val outbox = ClipboardOutbox(scope, opener)
        val link = Recorder()
        val (offer, sources) = buildClipOffer(LocalClip.Items(listOf(video.copy(size = data.size.toLong())), false))!!
        outbox.publish(OutgoingClip(offer, sources, "mac"), link, eagerLimitBytes = 0)
        val transferId = UUID.randomUUID().toString()
        outbox.onFetch(link, ClipFetchRequest(offer.offerId, 0, transferId))
        val transferOffer = JSONObject(String(link.sent.last().second!!))
        assertEquals("files.offer", link.sent.last().first)
        assertEquals("clipboard", transferOffer.getString("purpose"))
        outbox.onAccepted(transferId)
        val chunks = link.sent.filter { it.first == "files.chunk" }
        assertEquals(3, chunks.size)
        assertEquals(data.toList(), chunks.flatMap { it.second!!.toList() })
        val completion = JSONObject(String(link.sent.last { it.first == "files.complete" }.second!!))
        assertEquals(sha256Base64(data), completion.getString("sha256"))
        outbox.onCompleteAcknowledged(transferId)
        assertTrue(!outbox.handles(transferId))
        scope.cancel()
    }

    @Test
    fun smallItemsArePushedRightAfterTheOffer() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val opener = object : ClipSourceOpener {
            override fun open(source: ClipSource): InputStream = ByteArrayInputStream(ByteArray(10))
            override fun currentSize(source: ClipSource): Long = 10
        }
        val outbox = ClipboardOutbox(scope, opener)
        val link = Recorder()
        val (offer, sources) = buildClipOffer(LocalClip.Items(listOf(image.copy(size = 10), video), false))!!
        outbox.publish(OutgoingClip(offer, sources, "mac"), link, eagerLimitBytes = 25_000_000)
        val pushes = link.sent.filter { it.first == "files.offer" }.map { JSONObject(String(it.second!!)).getInt("index") }
        assertEquals("the 340 MB video waits for a paste", listOf(0), pushes)
        scope.cancel()
    }

    @Test
    fun anOfferSurvivesAReconnectUnlessTheClipboardChanged() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val opener = object : ClipSourceOpener {
            override fun open(source: ClipSource): InputStream = ByteArrayInputStream(ByteArray(10))
            override fun currentSize(source: ClipSource): Long = 10
        }
        val outbox = ClipboardOutbox(scope, opener)
        val link = Recorder()
        val clip = LocalClip.Items(listOf(video.copy(size = 10)), false)
        val (offer, sources) = buildClipOffer(clip)!!
        outbox.publish(OutgoingClip(offer, sources, "mac", clip.hash()), link, 0)
        outbox.disconnected()
        outbox.noteLocalClip(clip.hash())
        outbox.onFetch(link, ClipFetchRequest(offer.offerId, 0, UUID.randomUUID().toString()))
        assertEquals("files.offer", link.sent.last().first)
        outbox.noteLocalClip(LocalClip.Text("new", null, false).hash())
        outbox.onFetch(link, ClipFetchRequest(offer.offerId, 0, UUID.randomUUID().toString()))
        assertEquals(ClipErrorCode.CHANGED, JSONObject(String(link.sent.last().second!!)).getString("code"))
        scope.cancel()
    }

    private fun <T> assertEquals(expected: T, actual: T, message: String) = org.junit.Assert.assertEquals(message, expected, actual)
}
