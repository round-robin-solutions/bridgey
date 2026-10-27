package dev.bridgey.android.browse.engine

import dev.bridgey.android.browse.BrowseKinds
import dev.bridgey.android.browse.BrowseLimits
import dev.bridgey.android.browse.BrowseRef
import dev.bridgey.android.browse.BrowseRefs
import dev.bridgey.android.browse.DocumentItem
import dev.bridgey.android.browse.MediaAccess
import dev.bridgey.android.browse.engine.BrowseHarness.Companion.PICTURES
import dev.bridgey.android.browse.engine.BrowseHarness.Companion.items
import dev.bridgey.android.browse.engine.BrowseHarness.Companion.mediaRef
import dev.bridgey.android.browse.engine.BrowseHarness.Companion.placeRef
import dev.bridgey.android.folders.FolderCodes
import dev.bridgey.android.folders.FolderKinds
import dev.bridgey.android.folders.utf8Length
import java.util.concurrent.CountDownLatch
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BrowseServerTest {
    private fun names(page: JSONObject): List<String> = page.getJSONArray("entries").let { array -> (0 until array.length()).map { array.getJSONObject(it).getString("name") } }

    @Test
    fun listingPagesThroughEveryEntryFoldersFirstWithoutHiddenOrPartFiles() {
        val phone = BrowseHarness()
        repeat(450) { phone.pictures.put("Trip/IMG_${"%04d".format(it)}.jpg", ByteArray(it % 7)) }
        phone.pictures.mkdirs("Trip/Zeta")
        phone.pictures.mkdirs("Trip/alpha")
        phone.pictures.put("Trip/.hidden", ByteArray(1))
        phone.pictures.put("Trip/.IMG_1.jpg.bridgey-part", ByteArray(1))
        val seen = ArrayList<String>()
        var cursor: Any = JSONObject.NULL
        var pages = 0
        do {
            val id = phone.request(BrowseKinds.PLACES_FILES, JSONObject().put("placeId", PICTURES).put("path", "Trip").put("cursor", cursor))
            val (kind, page) = phone.answer(id)!!
            assertEquals(BrowseKinds.PLACES_FILES_PAGE, kind)
            assertTrue(page.getJSONArray("entries").length() <= BrowseLimits.FILES_PAGE_ENTRIES)
            assertTrue(utf8Length(page.toString()) <= BrowseLimits.PAGE_PLAINTEXT)
            assertEquals(2, page.getInt("folderCount"))
            assertEquals(450, page.getInt("fileCount"))
            seen += names(page)
            cursor = page.opt("nextCursor")
            pages++
        } while (cursor != JSONObject.NULL)
        assertEquals(3, pages)
        assertEquals(452, seen.size)
        assertEquals(seen.toSet().size, seen.size)
        assertEquals(listOf("alpha", "Zeta"), seen.take(2))
        assertFalse(seen.any { it.startsWith(".") })
    }

    @Test
    fun listingSortsBySizeDescendingAndCarriesFileFields() {
        val phone = BrowseHarness(writable = true)
        phone.pictures.put("a.txt", ByteArray(10))
        phone.pictures.put("b.jpg", ByteArray(300))
        phone.pictures.put("c.pdf", ByteArray(20))
        phone.pictures.mkdirs("Folder")
        val id = phone.request(BrowseKinds.PLACES_FILES, JSONObject().put("placeId", PICTURES).put("path", "").put("sort", "size").put("descending", true))
        val page = phone.answer(id)!!.second
        assertEquals(listOf("Folder", "b.jpg", "c.pdf", "a.txt"), names(page))
        val image = page.getJSONArray("entries").getJSONObject(1)
        assertEquals(300, image.getLong("size"))
        assertEquals("image/jpeg", image.getString("mimeType"))
        assertTrue(image.getBoolean("thumb"))
        assertTrue(page.getJSONArray("entries").getJSONObject(0).isNull("size"))
        assertTrue(page.getBoolean("writable"))
    }

    @Test
    fun missingFoldersHiddenPathsAndRevokedPlacesAnswerErrors() {
        val phone = BrowseHarness()
        phone.pictures.mkdirs(".secret")
        fun code(path: String, place: String = PICTURES): String {
            val id = phone.request(BrowseKinds.PLACES_FILES, JSONObject().put("placeId", place).put("path", path))
            val (kind, answer) = phone.answer(id)!!
            assertEquals(FolderKinds.PLACES_ERROR, kind)
            return answer.getString("code")
        }
        assertEquals(FolderCodes.NOT_FOUND, code("Nope"))
        assertEquals(FolderCodes.NOT_FOUND, code(".secret"))
        assertEquals(FolderCodes.INVALID_MESSAGE, code("../etc"))
        phone.places.entries[1].available = false
        assertEquals(FolderCodes.PLACE_UNAVAILABLE, code(""))
    }

    @Test
    fun browsingOffAnswersPolicyForEveryRequest() {
        val phone = BrowseHarness(allowed = false)
        listOf(BrowseKinds.PLACES_FILES, BrowseKinds.MEDIA_LIST, BrowseKinds.MEDIA_THUMBNAILS, BrowseKinds.MEDIA_RANGE, BrowseKinds.PLACES_DOWNLOAD).forEach { kind ->
            val id = phone.request(kind, JSONObject().put("placeId", PICTURES).put("path", ""))
            assertEquals(kind, FolderCodes.POLICY, phone.answer(id)!!.second.getString("code"))
        }
        assertTrue(phone.low.isEmpty())
    }

    @Test
    fun placesForBrowsingListEveryPlaceWithWritableAndMediaAccess() {
        val phone = BrowseHarness(writable = false)
        phone.media.access = MediaAccess.PARTIAL
        val id = java.util.UUID.randomUUID().toString()
        phone.server.placesForBrowsing(JSONObject().put("version", 1).put("requestId", id).put("purpose", "browse"))
        val (kind, answer) = phone.answer(id)!!
        assertEquals(FolderKinds.PLACES_LISTED, kind)
        assertEquals(2, answer.getJSONArray("places").length())
        assertFalse(answer.getBoolean("writable"))
        assertEquals("partial", answer.getString("media"))
        assertTrue(answer.getBoolean("documents"))
    }

    @Test
    fun mediaListPagesNewestFirstWithRefsNeverUris() {
        val phone = BrowseHarness()
        repeat(150) { phone.media.add(it.toLong() + 1, "IMG_$it.jpg", sortMillis = 1_000L * it) }
        val first = phone.answer(phone.request(BrowseKinds.MEDIA_LIST, JSONObject().put("kind", "media").put("limit", 100)))!!.second
        val items = first.getJSONArray("items")
        assertEquals(100, items.length())
        assertEquals("150", items.getJSONObject(0).getJSONObject("ref").getString("mediaId"))
        assertFalse(first.toString().contains("content://"))
        val second = phone.answer(phone.request(BrowseKinds.MEDIA_LIST, JSONObject().put("kind", "media").put("cursor", first.getString("nextCursor"))))!!.second
        assertEquals(50, second.getJSONArray("items").length())
        assertTrue(second.isNull("nextCursor"))
        assertEquals("full", second.getString("access"))
    }

    @Test
    fun mediaWithoutAccessIsEmptyAndRecentMixesDocuments() {
        val phone = BrowseHarness()
        phone.media.add(1, "new.jpg", sortMillis = 5_000)
        phone.media.add(2, "old.jpg", sortMillis = 1_000)
        phone.documents.items += DocumentItem(PICTURES, "Docs", "invoice.pdf", 10, 3_000, "application/pdf", "content://doc", "Pictures/Docs")
        val recent = phone.answer(phone.request(BrowseKinds.MEDIA_LIST, JSONObject().put("kind", "recent")))!!.second.getJSONArray("items")
        assertEquals(listOf("new.jpg", "invoice.pdf", "old.jpg"), (0 until recent.length()).map { recent.getJSONObject(it).getString("name") })
        assertEquals("Docs", recent.getJSONObject(1).getJSONObject("ref").getString("path"))
        assertEquals(1, phone.documents.refreshes)
        phone.media.access = MediaAccess.NONE
        val none = phone.answer(phone.request(BrowseKinds.MEDIA_LIST, JSONObject().put("kind", "media")))!!.second
        assertEquals(0, none.getJSONArray("items").length())
        assertEquals("none", none.getString("access"))
    }

    @Test
    fun thumbnailsArriveInOrderBatchedWithinBoundsAndMissingNamed() {
        val phone = BrowseHarness()
        repeat(20) { phone.media.add(it.toLong() + 1, "IMG_$it.jpg", sortMillis = it.toLong()) }
        phone.pictures.put("doc.txt", ByteArray(3))
        val request = items(*(1..20).map { "k$it" to mediaRef(it.toLong()) }.toTypedArray()).apply {
            put(JSONObject().put("key", "gone").put("ref", mediaRef(999)))
            put(JSONObject().put("key", "text").put("ref", placeRef(PICTURES, "", "doc.txt")))
        }
        val id = phone.request(BrowseKinds.MEDIA_THUMBNAILS, JSONObject().put("items", request).put("size", 256))
        val batches = phone.lowFor(id).map { it.second }
        assertTrue(batches.all { utf8Length(it.toString()) <= BrowseLimits.MEDIA_PLAINTEXT })
        assertTrue(batches.last().getBoolean("done"))
        assertTrue(batches.dropLast(1).none { it.getBoolean("done") })
        val keys = batches.flatMap { batch -> batch.getJSONArray("thumbs").let { array -> (0 until array.length()).map { array.getJSONObject(it).getString("key") } } }
        assertEquals((1..20).map { "k$it" }, keys)
        val missing = batches.flatMap { batch -> batch.getJSONArray("missing").let { array -> (0 until array.length()).map { array.getString(it) } } }
        assertEquals(listOf("gone", "text"), missing)
        val thumb = batches.first().getJSONArray("thumbs").getJSONObject(0)
        assertEquals("#336699", thumb.getString("tint"))
        assertTrue(java.util.Base64.getDecoder().decode(thumb.getString("data")).size <= BrowseLimits.THUMB_MAX_BYTES)
    }

    @Test
    fun thumbnailSizeIsClampedAndOversizedImagesAreNeverSent() {
        val phone = BrowseHarness()
        phone.media.add(1, "a.jpg", 1)
        phone.thumbs.bytes = 40_000
        val id = phone.request(BrowseKinds.MEDIA_THUMBNAILS, JSONObject().put("items", items("a" to mediaRef(1))).put("size", 4096))
        val batch = phone.lowFor(id).single().second
        // The maker was asked for at most 24 KiB at 512 px: the fake clamps to the budget.
        val thumb = batch.getJSONArray("thumbs").getJSONObject(0)
        assertEquals(512, thumb.getInt("width"))
        assertEquals(BrowseLimits.THUMB_MAX_BYTES, java.util.Base64.getDecoder().decode(thumb.getString("data")).size)
        val tooMany = items(*(1..65).map { "k$it" to mediaRef(1) }.toTypedArray())
        val rejected = phone.request(BrowseKinds.MEDIA_THUMBNAILS, JSONObject().put("items", tooMany))
        assertEquals(FolderCodes.INVALID_MESSAGE, phone.answer(rejected)!!.second.getString("code"))
        val badKey = phone.request(BrowseKinds.MEDIA_THUMBNAILS, JSONObject().put("items", items("bad key!" to mediaRef(1))))
        assertEquals(FolderCodes.INVALID_MESSAGE, phone.answer(badKey)!!.second.getString("code"))
    }

    @Test
    fun replacesAndCancelStopAThumbnailRequest() {
        val phone = BrowseHarness()
        repeat(10) { phone.media.add(it.toLong() + 1, "IMG_$it.jpg", it.toLong()) }
        val gate = CountDownLatch(1)
        phone.thumbs.gate = gate
        val first = java.util.UUID.randomUUID().toString()
        val second = java.util.UUID.randomUUID().toString()
        // Both run on their own threads; the first is held on the gate until the second replaces it.
        val firstRunner = Thread {
            phone.request(BrowseKinds.MEDIA_THUMBNAILS, JSONObject().put("requestId", first).put("items", items(*(1..10).map { "k$it" to mediaRef(it.toLong()) }.toTypedArray())))
        }
        firstRunner.start()
        while (phone.server.activeMediaRequests == 0) Thread.sleep(1)
        val secondRunner = Thread {
            phone.request(BrowseKinds.MEDIA_THUMBNAILS, JSONObject().put("requestId", second).put("replaces", first).put("items", items("x" to mediaRef(1))))
        }
        secondRunner.start()
        Thread.sleep(100)
        phone.thumbs.gate = null
        gate.countDown()
        firstRunner.join(5_000)
        secondRunner.join(5_000)
        assertTrue(phone.lowFor(first).none { it.second.optBoolean("done") })
        assertTrue(phone.lowFor(second).last().second.getBoolean("done"))
        // media.cancel is never answered.
        val before = phone.sent.size
        phone.request(BrowseKinds.MEDIA_CANCEL, JSONObject().put("requestId", java.util.UUID.randomUUID().toString()))
        assertEquals(before, phone.sent.size)
    }

    @Test
    fun batcherPacksAsManyAsFitAndNeverExceedsTheLimit() {
        val batches = ArrayList<JSONObject>()
        val batcher = dev.bridgey.android.browse.ThumbnailBatcher("6f1c3a52-0000-4000-8000-000000000000") { batches += it }
        repeat(20) { batcher.add("k$it", dev.bridgey.android.browse.EncodedImage(ByteArray(9_000), "image/webp", 256, 192, 0x112233)) }
        batcher.missing("gone")
        batcher.flush(done = true)
        // 9 KB images are 12 KB in base64: three fit in 44 KiB.
        assertEquals(7, batches.size)
        assertTrue(batches.all { utf8Length(it.toString()) <= BrowseLimits.MEDIA_PLAINTEXT })
        assertEquals(3, batches.first().getJSONArray("thumbs").length())
        assertTrue(batches.last().getBoolean("done"))
        // The largest allowed thumbnail still fits alone.
        val big = ArrayList<JSONObject>()
        val single = dev.bridgey.android.browse.ThumbnailBatcher("6f1c3a52-0000-4000-8000-000000000000") { big += it }
        repeat(2) { single.add("b$it", dev.bridgey.android.browse.EncodedImage(ByteArray(BrowseLimits.THUMB_MAX_BYTES), "image/jpeg", 512, 512, null)) }
        single.flush(done = true)
        assertEquals(2, big.size)
        assertTrue(big.all { utf8Length(it.toString()) <= BrowseLimits.MEDIA_PLAINTEXT })
    }

    @Test
    fun mediaLaneBudgetAnswersBusy() {
        var now = 0L
        val phone = BrowseHarness(clock = { now })
        phone.media.add(1, "a.jpg", 1)
        val codes = (1..61).map {
            val id = phone.request(BrowseKinds.MEDIA_THUMBNAILS, JSONObject().put("items", items("a" to mediaRef(1))))
            phone.answer(id)?.second?.optString("code")
        }
        assertEquals(60, codes.count { it == null })
        assertEquals(FolderCodes.BUSY, codes.last())
        now += BrowseLimits.WINDOW_MILLIS
        val again = phone.request(BrowseKinds.MEDIA_THUMBNAILS, JSONObject().put("items", items("a" to mediaRef(1))))
        assertNull(phone.answer(again))
    }

    @Test
    fun browseLaneBudgetAnswersBusy() {
        var now = 0L
        val phone = BrowseHarness(clock = { now })
        val codes = (1..41).map { phone.answer(phone.request(BrowseKinds.MEDIA_LIST, JSONObject().put("kind", "media")))!!.second.optString("code") }
        assertEquals(40, codes.count { it.isEmpty() })
        assertEquals(FolderCodes.BUSY, codes.last())
    }

    @Test
    fun previewComesInPartsThatReassemble() {
        val phone = BrowseHarness()
        phone.media.add(7, "big.jpg", 1)
        phone.thumbs.bytes = 300_000
        val id = phone.request(BrowseKinds.MEDIA_PREVIEW, JSONObject().put("ref", mediaRef(7)).put("size", 2048))
        val parts = phone.lowFor(id).map { it.second }
        assertEquals(10, parts.size)
        assertTrue(parts.all { it.getInt("count") == 10 && utf8Length(it.toString()) <= BrowseLimits.MEDIA_PLAINTEXT })
        val total = parts.sumOf { java.util.Base64.getDecoder().decode(it.getString("data")).size }
        assertEquals(300_000, total)
        val folder = phone.request(BrowseKinds.MEDIA_PREVIEW, JSONObject().put("ref", mediaRef(8)))
        assertEquals(FolderCodes.NOT_FOUND, phone.answer(folder)!!.second.getString("code"))
    }

    @Test
    fun rangesReturnExactBytesInPartsAndStopAtTheEnd() {
        val phone = BrowseHarness()
        val content = ByteArray(100_000) { (it * 7).toByte() }
        phone.pictures.put("clip.mp4", content)
        val id = phone.request(BrowseKinds.MEDIA_RANGE, JSONObject().put("ref", placeRef(PICTURES, "", "clip.mp4")).put("offset", 10_000).put("length", 80_000))
        val parts = phone.lowFor(id).map { it.second }
        val bytes = parts.flatMap { java.util.Base64.getDecoder().decode(it.getString("data")).toList() }.toByteArray()
        assertTrue(bytes.contentEquals(content.copyOfRange(10_000, 90_000)))
        assertTrue(parts.last().getBoolean("last"))
        assertEquals(100_000, parts.first().getLong("fileSize"))
        val tail = phone.request(BrowseKinds.MEDIA_RANGE, JSONObject().put("ref", placeRef(PICTURES, "", "clip.mp4")).put("offset", 95_000).put("length", 4_000_000))
        val tailBytes = phone.lowFor(tail).sumOf { java.util.Base64.getDecoder().decode(it.second.getString("data")).size }
        assertEquals(5_000, tailBytes)
        val tooLong = phone.request(BrowseKinds.MEDIA_RANGE, JSONObject().put("ref", placeRef(PICTURES, "", "clip.mp4")).put("offset", 0).put("length", BrowseLimits.RANGE_MAX + 1))
        assertEquals(FolderCodes.INVALID_MESSAGE, phone.answer(tooLong)!!.second.getString("code"))
    }

    @Test
    fun downloadsResolveRefsAndAnswerStartedOnce() {
        val phone = BrowseHarness()
        phone.pictures.put("Trip/a.jpg", ByteArray(10))
        phone.pictures.put("Trip/Day 1/b.jpg", ByteArray(20))
        phone.media.add(3, "c.jpg", 1, ByteArray(30))
        val request = JSONObject().put("items", JSONArray().put(placeRef(PICTURES, "", "Trip")).put(mediaRef(3)))
        val id = phone.request(BrowseKinds.PLACES_DOWNLOAD, request)
        val (kind, started) = phone.answer(id)!!
        assertEquals(BrowseKinds.PLACES_DOWNLOAD_STARTED, kind)
        assertEquals(3, started.getInt("fileCount"))
        assertEquals(2, started.getInt("folderCount"))
        assertEquals(60, started.getLong("totalSize"))
        // A repeated request ID answers the first answer and starts nothing new.
        phone.request(BrowseKinds.PLACES_DOWNLOAD, JSONObject(request.toString()).put("requestId", id))
        assertEquals(1, phone.started.size)
        assertEquals(started.getString("folderTransferId"), phone.answer(id)!!.second.getString("folderTransferId"))
        val missing = phone.request(BrowseKinds.PLACES_DOWNLOAD, JSONObject().put("items", JSONArray().put(placeRef(PICTURES, "", "nope.jpg"))))
        assertEquals(FolderCodes.NOT_FOUND, phone.answer(missing)!!.second.getString("code"))
        phone.refuseDownload = FolderCodes.LIMIT_EXCEEDED
        val refused = phone.request(BrowseKinds.PLACES_DOWNLOAD, JSONObject().put("items", JSONArray().put(mediaRef(3))))
        assertEquals(FolderCodes.LIMIT_EXCEEDED, phone.answer(refused)!!.second.getString("code"))
    }

    @Test
    fun refsAreValidatedStrictly() {
        assertEquals(BrowseRef.Media(42), BrowseRefs.parse(JSONObject().put("mediaId", "42")))
        assertNull(BrowseRefs.parse(JSONObject().put("mediaId", "4x2")))
        assertNull(BrowseRefs.parse(JSONObject().put("mediaId", "1".repeat(21))))
        assertNull(BrowseRefs.parse(JSONObject().put("mediaId", "1").put("placeId", PICTURES)))
        assertNotNull(BrowseRefs.parse(placeRef(PICTURES, "Trip/Day 1", "IMG.jpg")))
        assertNull(BrowseRefs.parse(placeRef(PICTURES, "../x", "a")))
        assertNull(BrowseRefs.parse(placeRef(PICTURES, "", "a/b")))
        assertNull(BrowseRefs.parse(placeRef(PICTURES, "", "..")))
        assertNull(BrowseRefs.parse(placeRef(PICTURES, "", "a\u0000")))
        assertNull(BrowseRefs.parse(placeRef("content://x", "", "a")))
        assertNull(BrowseRefs.parse(placeRef(PICTURES, "", "")))
        // Hidden items parse but never resolve.
        val phone = BrowseHarness()
        phone.pictures.put(".env", ByteArray(3))
        val id = phone.request(BrowseKinds.MEDIA_RANGE, JSONObject().put("ref", placeRef(PICTURES, "", ".env")).put("offset", 0).put("length", 3))
        assertEquals(FolderCodes.NOT_FOUND, phone.answer(id)!!.second.getString("code"))
    }
}
