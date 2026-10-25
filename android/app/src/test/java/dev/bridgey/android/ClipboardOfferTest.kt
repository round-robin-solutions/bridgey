package dev.bridgey.android

import java.util.Base64
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardOfferTest {
    private val offerId = "5b1f3a5e-7d0c-4f6e-9a51-0c2f6f7d1e0b"

    private fun item(index: Int, kind: ClipItemKind = ClipItemKind.FILE, size: Long = 10, inline: ByteArray? = null, name: String? = "a.bin") =
        ClipOfferItem(index, kind, if (kind == ClipItemKind.IMAGE) "image/png" else "application/octet-stream",
            if (kind == ClipItemKind.FILE) name else null, size, inline?.let(::sha256Base64), inline)

    private fun offer(vararg items: ClipOfferItem) = ClipOffer(offerId, 1_786_550_000_000, false, items.toList())

    private fun json(mutate: JSONObject.() -> Unit): ByteArray =
        JSONObject(String(offer(item(0, ClipItemKind.IMAGE, 4)).encode())).apply(mutate).toString().toByteArray()

    @Test
    fun roundTripsAnOfferWithInlineData() {
        val data = "hello".toByteArray()
        val original = ClipOffer(offerId, 1_786_550_000_000, true, listOf(
            ClipOfferItem(0, ClipItemKind.TEXT, "text/plain", null, data.size.toLong(), sha256Base64(data), data),
            ClipOfferItem(1, ClipItemKind.HTML, "text/html", null, 300_000, null, null),
        ))
        val decoded = ClipOffer.decode(original.encode())
        assertEquals(original, decoded)
        assertTrue(decoded!!.sensitive)
        assertTrue(decoded.isText)
    }

    @Test
    fun acceptsImagesAndFilesTogether() {
        val decoded = ClipOffer.decode(offer(item(0, ClipItemKind.IMAGE), item(1), item(2, name = "video.mp4")).encode())
        assertEquals(listOf("a.bin", "video.mp4"), decoded!!.items.mapNotNull(ClipOfferItem::name))
        assertNull("images carry no name", decoded.items[0].name)
    }

    @Test
    fun rejectsMalformedAndOversizedOffers() {
        assertNull("over 100 items", ClipOffer.decode(ClipOffer(offerId, 0, false, (0..100).map { item(it) }).toJson().toString().toByteArray()))
        assertNull("html without text", ClipOffer.decode(offer(ClipOfferItem(0, ClipItemKind.HTML, "text/html", null, 1, null, null)).encode()))
        assertNull("text mixed with a file", ClipOffer.decode(offer(ClipOfferItem(0, ClipItemKind.TEXT, "text/plain", null, 1, null, null), item(1)).encode()))
        assertNull("two text items", ClipOffer.decode(offer(
            ClipOfferItem(0, ClipItemKind.TEXT, "text/plain", null, 1, null, null),
            ClipOfferItem(1, ClipItemKind.TEXT, "text/plain", null, 1, null, null),
        ).encode()))
        assertNull("no items", ClipOffer.decode(json { put("items", JSONArray()) }))
        assertNull("wrong version", ClipOffer.decode(json { put("version", 2) }))
        assertNull("bad offer id", ClipOffer.decode(json { put("offerId", "not-a-uuid") }))
        assertNull("negative time", ClipOffer.decode(json { put("createdAt", -1) }))
        assertNull("index out of order", ClipOffer.decode(json { getJSONArray("items").getJSONObject(0).put("index", 1) }))
        assertNull("unknown kind", ClipOffer.decode(json { getJSONArray("items").getJSONObject(0).put("kind", "folder") }))
        assertNull("bad mime", ClipOffer.decode(json { getJSONArray("items").getJSONObject(0).put("mime", "image") }))
        assertNull("over 10 GiB", ClipOffer.decode(json { getJSONArray("items").getJSONObject(0).put("size", ClipLimits.MAX_ITEM_SIZE + 1) }))
        assertNull("bad hash", ClipOffer.decode(json { getJSONArray("items").getJSONObject(0).put("sha256", "AAAA") }))
        assertNull("file without a name", ClipOffer.decode(offer(item(0, name = null)).encode()))
        assertNull("not JSON", ClipOffer.decode("{".toByteArray()))
        assertNull("plaintext over 40 KiB", ClipOffer.decode(ByteArray(ClipLimits.MAX_OFFER_PLAINTEXT_BYTES + 1) { ' '.code.toByte() }))
    }

    @Test
    fun inlineDataMustMatchItsSizeAndHash() {
        val data = ByteArray(8) { it.toByte() }
        val good = offer(item(0, ClipItemKind.IMAGE, data.size.toLong(), data))
        assertNotNull(ClipOffer.decode(good.encode()))
        val wrongSize = JSONObject(String(good.encode())).apply { getJSONArray("items").getJSONObject(0).put("size", 9) }
        assertNull(ClipOffer.decode(wrongSize.toString().toByteArray()))
        val wrongHash = JSONObject(String(good.encode())).apply { getJSONArray("items").getJSONObject(0).put("sha256", sha256Base64(ByteArray(8))) }
        assertNull(ClipOffer.decode(wrongHash.toString().toByteArray()))
        val noHash = JSONObject(String(good.encode())).apply { getJSONArray("items").getJSONObject(0).remove("sha256") }
        assertNull(ClipOffer.decode(noHash.toString().toByteArray()))
    }

    @Test
    fun inlineDataIsLimitedTo16KiBPerOffer() {
        val half = ByteArray(9 * 1024) { 1 }
        val tooMuch = offer(item(0, ClipItemKind.IMAGE, half.size.toLong(), half), item(1, ClipItemKind.IMAGE, half.size.toLong(), half))
        assertNull(ClipOffer.decode(tooMuch.encode()))
        val fits = ByteArray(16 * 1024) { 2 }
        assertNotNull(ClipOffer.decode(offer(item(0, ClipItemKind.IMAGE, fits.size.toLong(), fits)).encode()))
    }

    @Test
    fun receiversKeepOnlyTheLastPathComponentOfNames() {
        val decoded = ClipOffer.decode(offer(item(0, name = "../../etc/passwd")).encode())!!
        assertEquals("passwd", decoded.items.single().name)
        assertNull(ClipOffer.decode(offer(item(0, name = "dir/")).encode()))
        assertEquals("a_b", sanitizeClipName("a:b"))
    }

    @Test
    fun eagerItemsStayWithinTheThresholdInIndexOrder() {
        val items = listOf(item(0, size = 10_000_000), item(1, size = 20_000_000), item(2, size = 5_000_000), item(3, size = 30_000_000))
        assertEquals(listOf(0, 2), eagerIndices(items, 25_000_000), "cumulative, and a big item is skipped, not a stop")
        assertEquals(listOf(0, 1, 2), eagerIndices(items, 100_000_000).take(3))
        assertEquals(emptyList<Int>(), eagerIndices(items, 0), "Always ask when pasting pushes nothing")
        assertEquals(listOf(2), eagerIndices(items, 5_000_000))
        assertEquals(listOf(0, 1), eagerIndices(listOf(item(0, size = 25_000_000), item(1, size = 0)), 25_000_000), "at the threshold counts")
    }

    @Test
    fun inlineItemsAreNeverPushed() {
        val data = ByteArray(4)
        assertEquals(listOf(1), eagerIndices(listOf(item(0, ClipItemKind.IMAGE, 4, data), item(1, size = 4)), 25_000_000))
    }

    @Test
    fun bigOffersDropInlineDataFirst() {
        val inline = ByteArray(16 * 1024) { 3 }
        val withInline = ClipOffer(offerId, 0, false, listOf(item(0, ClipItemKind.IMAGE, inline.size.toLong(), inline)) +
            (1 until 100).map { item(it, name = "x".repeat(250) + ".mp4") })
        assertTrue(withInline.encode().size > ClipLimits.MAX_OFFER_PLAINTEXT_BYTES)
        val fitted = fitOffer(withInline)!!
        assertEquals(100, fitted.items.size)
        assertNull(fitted.items[0].inline)
        assertTrue("the hash stays", fitted.items[0].sha256 != null)
        assertTrue(fitted.items.all { it.name == null || it.name!!.length == 254 })
    }

    @Test
    fun bigOffersThenShortenNamesKeepingTheExtension() {
        val mime = "application/" + "x".repeat(243)
        val many = ClipOffer(offerId, 0, false, (0 until 100).map {
            ClipOfferItem(it, ClipItemKind.FILE, mime, "y".repeat(250) + ".mp4", 10, null, null)
        })
        assertTrue(many.encode().size > ClipLimits.MAX_OFFER_PLAINTEXT_BYTES)
        val fitted = fitOffer(many)!!
        assertTrue(fitted.encode().size <= ClipLimits.MAX_OFFER_PLAINTEXT_BYTES)
        assertTrue(fitted.items.isNotEmpty())
        assertTrue("names keep their extension", fitted.items.all { it.name!!.endsWith(".mp4") && it.name!!.length <= 64 })
        assertNotNull(ClipOffer.decode(fitted.encode()))
    }

    @Test
    fun fetchAndErrorReferencesAreValidated() {
        val transferId = UUID.randomUUID().toString()
        val parsed = parseClipReference(clipFetchPayload(offerId, 3, transferId), transferId)
        assertEquals(ClipFetchRequest(offerId, 3, transferId), parsed)
        assertNull("outer transfer ID must match", parseClipReference(clipFetchPayload(offerId, 3, transferId), UUID.randomUUID().toString()))
        assertNull("index out of range", parseClipReference(clipFetchPayload(offerId, 100, transferId), null))
        assertNotNull(parseClipReference(clipErrorPayload(offerId, 0, transferId, ClipErrorCode.CHANGED), transferId))
    }

    @Test
    fun clipboardPurposeIsReadFromAFileOffer() {
        val transferId = UUID.randomUUID().toString()
        val payload = JSONObject(String(clipTransferOfferPayload(transferId, offerId, item(2, size = 99), null)))
        assertEquals(ClipTransferOffer(transferId, offerId, 2, 99, null), parseClipTransferOffer(payload))
        assertEquals("a.bin", payload.getString("name"))
        assertTrue("no hash when the sender hashes while streaming", !payload.has("sha256"))
        payload.remove("purpose")
        assertNull("an ordinary file offer keeps the files path", parseClipTransferOffer(payload))
    }

    @Test
    fun summariesNameOnlyASingleFile() {
        assertEquals(ClipSummary("file", 1, 10, "a.bin"), offer(item(0)).summary())
        assertEquals(ClipSummary("file", 2, 20, null), offer(item(0), item(1, name = "b")).summary())
        assertEquals(ClipSummary("image", 2, 20, null), offer(item(0, ClipItemKind.IMAGE), item(1, ClipItemKind.IMAGE)).summary())
        val text = ClipOffer(offerId, 0, false, listOf(
            ClipOfferItem(0, ClipItemKind.TEXT, "text/plain", null, 70_000, null, null),
            ClipOfferItem(1, ClipItemKind.HTML, "text/html", null, 90_000, null, null),
        ))
        assertEquals(ClipSummary("text", 1, 70_000, null), text.summary())
        assertEquals("image.jpg", clipDisplayName(ClipOfferItem(0, ClipItemKind.IMAGE, "image/jpeg", null, 1, null, null)))
        assertEquals(Base64.getEncoder().encodeToString(ByteArray(32)).length, sha256Base64(ByteArray(0)).length)
    }

    private fun <T> assertEquals(expected: T, actual: T, message: String) = org.junit.Assert.assertEquals(message, expected, actual)
}
