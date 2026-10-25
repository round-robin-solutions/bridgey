package dev.bridgey.android

import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ClipboardInboxTest {
    @get:Rule val folder = TemporaryFolder()

    private class Sent(val kind: String, val transferId: String?, val payload: ByteArray?)

    private class FakeLink(override val deviceId: String = "mac", override val peerName: String = "Work MacBook") : ClipboardLink {
        val sent = CopyOnWriteArrayList<Sent>()
        var connected = true
        override fun send(kind: String, transferId: String?, payload: ByteArray?, sequence: Long?): Boolean {
            if (!connected) return false
            sent += Sent(kind, transferId, payload)
            return true
        }
        fun kinds() = sent.map(Sent::kind)
        fun last(kind: String) = sent.last { it.kind == kind }
    }

    private val written = CopyOnWriteArrayList<IncomingClip>()
    private val events = CopyOnWriteArrayList<ClipInboxEvent>()
    private var now = 1_786_550_000_000L
    private val cacheDir by lazy { File(folder.root, "clipboard-cache") }
    private val cache by lazy { ClipboardCache(cacheDir, { now }) }

    private fun inbox(link: FakeLink? = FakeLink()): Pair<ClipboardInbox, FakeLink?> {
        val inbox = ClipboardInbox(cache, { written += it; true }, { now }, startWatchdog = false)
        inbox.link = link
        inbox.listener = { events += it }
        return inbox to link
    }

    private val video = ByteArray(60_000) { (it % 251).toByte() }

    private fun fileOffer(vararg sizes: Long, offerId: String = UUID.randomUUID().toString()) = ClipOffer(
        offerId, now, false,
        sizes.mapIndexed { index, size -> ClipOfferItem(index, ClipItemKind.FILE, "video/mp4", "video$index.mp4", size, null, null) },
    )

    /** What the Mac does after a fetch: clipboard-purpose files.offer, chunks, files.complete. */
    private fun deliver(inbox: ClipboardInbox, link: FakeLink, offer: ClipOffer, index: Int, transferId: String, data: ByteArray, hash: String = sha256Base64(data)) {
        inbox.onTransferOffer(link, ClipTransferOffer(transferId, offer.offerId, index, data.size.toLong(), null))
        assertEquals("files.accept", link.sent.last().kind)
        data.toList().chunked(ClipLimits.CHUNK_SIZE).forEachIndexed { sequence, chunk ->
            assertTrue(inbox.onChunk(transferId, sequence.toLong(), chunk.toByteArray()))
        }
        inbox.onComplete(link, transferId, hash)
    }

    @Test
    fun anOfferPutsContentUrisOnTheClipboardWithoutMovingData() {
        val (inbox, link) = inbox()
        val offer = fileOffer(2_000_000_000)
        inbox.accept(offer, link!!)
        val clip = written.single() as IncomingClip.Items
        assertEquals(listOf(IncomingClipItem(0, "video/mp4", "video0.mp4")), clip.items)
        assertTrue("nothing was fetched", link.sent.isEmpty())
        assertTrue(events.single() is ClipInboxEvent.Received)
        assertEquals(ClipItemInfo("video0.mp4", "video/mp4", 2_000_000_000), inbox.describe(offer.offerId, 0))
    }

    @Test
    fun pastingALazyItemFetchesAndStreamsIt() {
        val (inbox, link) = inbox()
        val offer = fileOffer(video.size.toLong())
        inbox.accept(offer, link!!)
        val open = inbox.open(offer.offerId, 0, allowFetch = true) as ClipOpen.Streaming
        val fetch = link.last("clipboard.fetch")
        val request = parseClipReference(fetch.payload!!, fetch.transferId)!!
        assertEquals(offer.offerId to 0, request.offerId to request.index)
        assertEquals(1, inbox.progress.value.size)

        val output = ByteArrayOutputStream()
        val reader = Thread { open.stream.copyTo(output) }.apply { start() }
        deliver(inbox, link, offer, 0, request.transferId, video)
        reader.join(5_000)
        assertArrayEquals(video, output.toByteArray())
        assertEquals("files.complete.ack", link.sent.last().kind)
        assertTrue(cache.isComplete(offer.offerId, 0))
        assertTrue(events.any { it is ClipInboxEvent.Pasted })
        assertTrue(inbox.progress.value.isEmpty())
        // A second paste reads the cache, with no new transfer.
        assertTrue(inbox.open(offer.offerId, 0, allowFetch = true) is ClipOpen.Cached)
        assertEquals(1, link.kinds().count { it == "clipboard.fetch" })
    }

    @Test
    fun aPasteDuringAnEagerPushWaitsForThatPush() {
        val (inbox, link) = inbox()
        val offer = fileOffer(video.size.toLong())
        inbox.accept(offer, link!!)
        val transferId = UUID.randomUUID().toString()
        inbox.onTransferOffer(link, ClipTransferOffer(transferId, offer.offerId, 0, video.size.toLong(), null))
        assertTrue(inbox.onChunk(transferId, 0, video.copyOfRange(0, ClipLimits.CHUNK_SIZE)))
        val open = inbox.open(offer.offerId, 0, allowFetch = true) as ClipOpen.Streaming
        assertFalse("no second transfer", link.kinds().contains("clipboard.fetch"))
        val output = ByteArrayOutputStream()
        val reader = Thread { open.stream.copyTo(output) }.apply { start() }
        video.toList().chunked(ClipLimits.CHUNK_SIZE).drop(1).forEachIndexed { sequence, chunk ->
            assertTrue(inbox.onChunk(transferId, sequence + 1L, chunk.toByteArray()))
        }
        inbox.onComplete(link, transferId, sha256Base64(video))
        reader.join(5_000)
        assertArrayEquals(video, output.toByteArray())
        assertFalse("an eager push is not a paste-time move", events.any { it is ClipInboxEvent.Pasted })
    }

    @Test
    fun eagerItemsAreServedStraightFromTheCache() {
        val (inbox, link) = inbox()
        val small = ByteArray(5_000) { 7 }
        val offer = fileOffer(small.size.toLong())
        inbox.accept(offer, link!!)
        deliver(inbox, link, offer, 0, UUID.randomUUID().toString(), small)
        val open = inbox.open(offer.offerId, 0, allowFetch = true) as ClipOpen.Cached
        assertArrayEquals(small, open.file.readBytes())
        assertTrue(cache.isHandedOut(offer.offerId, 0))
    }

    @Test
    fun aNewOfferSupersedesTheOldOne() {
        val (inbox, link) = inbox()
        val first = fileOffer(video.size.toLong(), 10)
        inbox.accept(first, link!!)
        deliver(inbox, link, first, 1, UUID.randomUUID().toString(), ByteArray(10)) // eager, never pasted
        val open = inbox.open(first.offerId, 0, allowFetch = true) as ClipOpen.Streaming
        val fetchId = link.last("clipboard.fetch").transferId
        inbox.onTransferOffer(link, ClipTransferOffer(fetchId!!, first.offerId, 0, video.size.toLong(), null))

        inbox.accept(fileOffer(5), link)
        assertTrue("the running fetch is cancelled", link.sent.any { it.kind == "files.cancel" && it.transferId == fetchId })
        assertFalse("its chunks are refused", inbox.onChunk(fetchId, 0, ByteArray(1)))
        assertFalse("the unpasted eager item is deleted", cache.isComplete(first.offerId, 1))
        try {
            open.stream.copyTo(ByteArrayOutputStream())
            fail("the waiting paste fails")
        } catch (error: ClipStreamException) {
            assertEquals(ClipErrorCode.SUPERSEDED, error.code)
        }
        assertFalse("superseding is not reported as a failed paste", events.any { it is ClipInboxEvent.PasteFailed })
    }

    @Test
    fun aPushForAnUnknownOrSupersededOfferIsDeclined() {
        val (inbox, link) = inbox()
        val old = fileOffer(10)
        inbox.accept(old, link!!)
        inbox.accept(fileOffer(10), link)
        val transferId = UUID.randomUUID().toString()
        inbox.onTransferOffer(link, ClipTransferOffer(transferId, old.offerId, 0, 10, null))
        assertEquals(Sent("files.cancel", transferId, null).kind, link.sent.last().kind)
        assertEquals(transferId, link.sent.last().transferId)
        assertFalse(inbox.handles(transferId))
        // A size that does not match the offer is declined too.
        val other = UUID.randomUUID().toString()
        inbox.onTransferOffer(link, ClipTransferOffer(other, inbox.currentOfferId!!, 0, 11, null))
        assertEquals("files.cancel", link.sent.last().kind)
    }

    @Test
    fun aWrongHashFailsThePasteAndKeepsNothing() {
        val (inbox, link) = inbox()
        val offer = fileOffer(video.size.toLong())
        inbox.accept(offer, link!!)
        val open = inbox.open(offer.offerId, 0, allowFetch = true) as ClipOpen.Streaming
        val transferId = link.last("clipboard.fetch").transferId!!
        deliver(inbox, link, offer, 0, transferId, video, hash = sha256Base64(ByteArray(1)))
        try {
            open.stream.copyTo(ByteArrayOutputStream())
            fail("verification failure reaches the pasting app")
        } catch (error: ClipStreamException) {
            assertEquals(ClipErrorCode.INVALID, error.code)
        }
        assertFalse(cache.dataFile(offer.offerId, 0).exists())
        assertTrue(events.any { it is ClipInboxEvent.PasteFailed })
    }

    @Test
    fun anErrorFromTheSenderReachesThePastingApp() {
        val (inbox, link) = inbox()
        val offer = fileOffer(100)
        inbox.accept(offer, link!!)
        val open = inbox.open(offer.offerId, 0, allowFetch = true) as ClipOpen.Streaming
        inbox.onError(link.last("clipboard.fetch").transferId!!, ClipErrorCode.CHANGED)
        try {
            open.stream.copyTo(ByteArrayOutputStream())
            fail()
        } catch (error: ClipStreamException) {
            assertEquals(ClipErrorCode.CHANGED, error.code)
        }
    }

    @Test
    fun pastingWhileDisconnectedFailsAtOnce() {
        val (inbox, link) = inbox()
        val offer = fileOffer(100)
        inbox.accept(offer, link!!)
        inbox.disconnected()
        assertEquals(ClipOpen.Failed(ClipErrorCode.NOT_CONNECTED), inbox.open(offer.offerId, 0, allowFetch = true))
        assertTrue(events.any { it is ClipInboxEvent.PasteFailed && it.code == ClipErrorCode.NOT_CONNECTED })
    }

    @Test
    fun disconnectingMidTransferFailsTheReader() {
        val (inbox, link) = inbox()
        val offer = fileOffer(video.size.toLong())
        inbox.accept(offer, link!!)
        val open = inbox.open(offer.offerId, 0, allowFetch = true) as ClipOpen.Streaming
        val transferId = link.last("clipboard.fetch").transferId!!
        inbox.onTransferOffer(link, ClipTransferOffer(transferId, offer.offerId, 0, video.size.toLong(), null))
        inbox.onChunk(transferId, 0, video.copyOfRange(0, 100))
        inbox.disconnected()
        val output = ByteArrayOutputStream()
        try {
            open.stream.copyTo(output)
            fail()
        } catch (error: ClipStreamException) {
            assertEquals(ClipErrorCode.NOT_CONNECTED, error.code)
        }
        assertEquals("what arrived was streamed first", 100, output.size())
    }

    @Test
    fun thumbnailsNeverStartATransfer() {
        val (inbox, link) = inbox()
        val offer = fileOffer(100)
        inbox.accept(offer, link!!)
        assertEquals(ClipOpen.Failed(ClipErrorCode.UNAVAILABLE), inbox.open(offer.offerId, 0, allowFetch = false))
        assertTrue(link.sent.isEmpty())
    }

    @Test
    fun unansweredFetchesTimeOut() {
        val (inbox, link) = inbox()
        val offer = fileOffer(100)
        inbox.accept(offer, link!!)
        val open = inbox.open(offer.offerId, 0, allowFetch = true) as ClipOpen.Streaming
        now += ClipLimits.FETCH_START_TIMEOUT_MILLIS + 1
        inbox.checkTimeouts()
        try {
            open.stream.copyTo(ByteArrayOutputStream())
            fail()
        } catch (error: ClipStreamException) {
            assertEquals(ClipErrorCode.TIMEOUT, error.code)
        }
        assertEquals("files.cancel", link.sent.last().kind)
    }

    @Test
    fun aBusySenderGetsTheFetchAgain() {
        val timer = Executors.newSingleThreadScheduledExecutor()
        val link = FakeLink()
        val inbox = ClipboardInbox(cache, { written += it; true }, { now }, timer, startWatchdog = false).apply { this.link = link }
        val offer = fileOffer(100)
        inbox.accept(offer, link)
        inbox.open(offer.offerId, 0, allowFetch = true)
        val transferId = link.last("clipboard.fetch").transferId!!
        inbox.onError(transferId, ClipErrorCode.BUSY)
        timer.shutdown()
        timer.awaitTermination(5, TimeUnit.SECONDS)
        assertEquals(2, link.sent.count { it.kind == "clipboard.fetch" && it.transferId == transferId })
        assertTrue(inbox.handles(transferId))
    }

    @Test
    fun shortLongTextIsFetchedAndSetAsText() {
        val (inbox, link) = inbox()
        val text = "a".repeat(50_000)
        val bytes = text.toByteArray()
        val offer = ClipOffer(UUID.randomUUID().toString(), now, false, listOf(ClipOfferItem(0, ClipItemKind.TEXT, "text/plain", null, bytes.size.toLong(), sha256Base64(bytes), null)))
        inbox.accept(offer, link!!)
        assertTrue("nothing on the clipboard until it arrives", written.isEmpty())
        val fetch = link.last("clipboard.fetch")
        deliver(inbox, link, offer, 0, fetch.transferId!!, bytes)
        assertEquals(IncomingClip.Text(offer.offerId, text, null, false), written.single())
        assertTrue(events.any { it is ClipInboxEvent.TextWritten })
    }

    @Test
    fun inlineTextIsWrittenAtOnce() {
        val (inbox, link) = inbox()
        val text = "short but sent as an offer".toByteArray()
        val html = "<b>x</b>".toByteArray()
        val offer = ClipOffer(UUID.randomUUID().toString(), now, true, listOf(
            ClipOfferItem(0, ClipItemKind.TEXT, "text/plain", null, text.size.toLong(), sha256Base64(text), text),
            ClipOfferItem(1, ClipItemKind.HTML, "text/html", null, html.size.toLong(), sha256Base64(html), html),
        ))
        inbox.accept(offer, link!!)
        assertEquals(IncomingClip.Text(offer.offerId, String(text), String(html), true), written.single())
        assertTrue(link.sent.isEmpty())
    }

    @Test
    fun veryLongTextBecomesATextFile() {
        val (inbox, link) = inbox()
        val offer = ClipOffer(UUID.randomUUID().toString(), now, false, listOf(
            ClipOfferItem(0, ClipItemKind.TEXT, "text/plain", null, ClipLimits.TEXT_IN_MEMORY_BYTES + 1L, null, null),
            ClipOfferItem(1, ClipItemKind.HTML, "text/html", null, 10, null, null),
        ))
        inbox.accept(offer, link!!)
        val clip = written.single() as IncomingClip.Items
        assertEquals(listOf(IncomingClipItem(0, "text/plain", "Clipboard text.txt")), clip.items)
        assertTrue(link.sent.isEmpty())
    }

    @Test
    fun clearAllDeletesTheCacheAndStopsTransfers() {
        val (inbox, link) = inbox()
        val offer = fileOffer(10, 100)
        inbox.accept(offer, link!!)
        deliver(inbox, link, offer, 0, UUID.randomUUID().toString(), ByteArray(10))
        inbox.open(offer.offerId, 0, allowFetch = true)
        inbox.open(offer.offerId, 1, allowFetch = true)
        inbox.clearAll()
        assertFalse(cacheDir.exists())
        assertTrue(link.kinds().contains("files.cancel"))
        assertEquals(null, inbox.currentOfferId)
    }

    @Test
    fun completionHashMustMatchTheTransfer() {
        val transferId = UUID.randomUUID().toString()
        val hash = Base64.getEncoder().encodeToString(ByteArray(32))
        assertEquals(hash, parseClipCompletion(JSONObject().put("transferId", transferId).put("sha256", hash), transferId))
        assertEquals(null, parseClipCompletion(JSONObject().put("transferId", UUID.randomUUID().toString()).put("sha256", hash), transferId))
        assertNotNull(hash)
    }
}
