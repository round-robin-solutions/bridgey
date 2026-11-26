package dev.bridgey.android.browse

import dev.bridgey.android.browse.engine.BrowseHarness
import dev.bridgey.android.folders.DownloadTicket
import dev.bridgey.android.folders.TreeEntry
import dev.bridgey.android.strictJsonObject
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Base64

/**
 * protocol/test-vectors/browse-v1.json (generator protocol/tools/browse_vectors.py): the browse answers this phone
 * writes, and the requests from a Mac it reads. The Mac checks the same file from the other side.
 */
class BrowseVectorsTest {
    private val vectors = JSONObject(File(File(System.getProperty("bridgey.repoRoot") ?: "../.."), "protocol/test-vectors/browse-v1.json").readText())

    private fun cases(name: String): List<JSONObject> =
        vectors.getJSONArray(name).let { list -> (0 until list.length()).map(list::getJSONObject) }.also { assertTrue(name, it.isNotEmpty()) }

    /** The cases this phone's encoder writes exactly. */
    private fun written(name: String): List<JSONObject> = cases(name).filter { it.optBoolean("write") }.also { assertTrue(name, it.isNotEmpty()) }

    private fun rejects(case: JSONObject) = case.opt("expect") == "reject"

    /** JSON as plain Kotlin values, numbers as Long or Double, so two documents compare whatever their key order. */
    private fun plain(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { plain(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { plain(value.get(it)) }
        is Int -> value.toLong()
        is Long -> value
        is Number -> value.toDouble().let { if (it == Math.floor(it)) it.toLong() else it }
        else -> value
    }

    private fun assertJson(expected: JSONObject, actual: JSONObject, label: String) =
        assertEquals(label, plain(expected), plain(JSONObject(actual.toString())))

    private fun bytes(base64: String): ByteArray = Base64.getDecoder().decode(base64)

    private fun tint(value: Any?): Int? = (value as? String)?.removePrefix("#")?.toInt(16)

    private fun longOrNull(json: JSONObject, key: String): Long? = if (json.isNull(key)) null else json.getLong(key)

    // MARK: what this phone writes

    @Test fun placesFilesPageEncoding() {
        written("placesFilesPage").forEach { case ->
            val p = case.getJSONObject("plaintext")
            val list = p.getJSONArray("entries")
            val shown = (0 until list.length()).map { index ->
                val e = list.getJSONObject(index)
                TreeEntry(
                    id = "id$index", name = e.getString("name"), isDirectory = e.getBoolean("dir"), size = longOrNull(e, "size"),
                    modifiedMillis = longOrNull(e, "modified"), mimeType = if (e.isNull("mimeType")) null else e.getString("mimeType"),
                    providerThumbnail = e.getBoolean("thumb"),
                )
            }
            val page = BrowseServer.filesPage(p.getString("requestId"), p.getString("placeId"), p.getString("path"), shown, 0, p.getBoolean("writable"))
            assertJson(p, page, case.getString("name"))
        }
    }

    @Test fun placesDownloadStartedEncoding() {
        written("placesDownloadStarted").forEach { case ->
            val p = case.getJSONObject("plaintext")
            val ticket = DownloadTicket(p.getString("folderTransferId"), p.getString("rootName"), p.getInt("fileCount"), p.getInt("folderCount"), p.getLong("totalSize"))
            assertJson(p, downloadStartedJson(p.getString("requestId"), ticket), case.getString("name"))
        }
    }

    @Test fun mediaThumbnailsBatchEncoding() {
        written("mediaThumbnailsBatch").forEach { case ->
            val p = case.getJSONObject("plaintext")
            val batches = ArrayList<JSONObject>()
            val batcher = ThumbnailBatcher(p.getString("requestId")) { batches += it }
            val thumbs = p.getJSONArray("thumbs")
            for (index in 0 until thumbs.length()) {
                val t = thumbs.getJSONObject(index)
                batcher.add(t.getString("key"), EncodedImage(bytes(t.getString("data")), t.getString("mimeType"), t.getInt("width"), t.getInt("height"), tint(t.opt("tint"))))
            }
            val missing = p.getJSONArray("missing")
            for (index in 0 until missing.length()) batcher.missing(missing.getString(index))
            batcher.flush(done = p.getBoolean("done"))
            assertEquals(case.getString("name"), 1, batches.size)
            assertJson(p, batches.single(), case.getString("name"))
        }
    }

    @Test fun mediaPreviewPartEncoding() {
        written("mediaPreviewPart").forEach { case ->
            val p = case.getJSONObject("plaintext")
            val image = EncodedImage(ByteArray(0), p.getString("mimeType"), p.getInt("width"), p.getInt("height"), tint(p.opt("tint")))
            val part = bytes(p.getString("data"))
            assertTrue(case.getString("name"), part.size <= BrowseLimits.PART_BYTES && p.getInt("count") * BrowseLimits.PART_BYTES <= BrowseLimits.PREVIEW_MAX_BYTES)
            assertJson(p, previewPartJson(p.getString("requestId"), p.getInt("index"), p.getInt("count"), image, part), case.getString("name"))
        }
    }

    @Test fun mediaRangePartEncoding() {
        written("mediaRangePart").forEach { case ->
            val p = case.getJSONObject("plaintext")
            val data = bytes(p.getString("data"))
            assertTrue(case.getString("name"), data.size <= BrowseLimits.PART_BYTES)
            val part = rangePartJson(p.getString("requestId"), p.getLong("offset"), p.getLong("fileSize"), longOrNull(p, "modified"), data, p.getBoolean("last"))
            assertJson(p, part, case.getString("name"))
        }
    }

    // MARK: what this phone reads

    /** media.list, read as the browse server reads it; a request it refuses is never answered with media.page. */
    @Test fun mediaList() {
        cases("mediaList").forEach { case ->
            val name = case.getString("name")
            val json = strictJsonObject(case.getJSONObject("plaintext").toString().toByteArray()) ?: error("$name is not strict JSON")
            val phone = BrowseHarness()
            try {
                phone.server.handle(BrowseKinds.MEDIA_LIST, JSONObject(json.toString()))
                val answer = phone.sent.lastOrNull()
                if (rejects(case)) return@forEach assertNotEquals(name, BrowseKinds.MEDIA_PAGE, answer?.first)
                assertEquals(name, BrowseKinds.MEDIA_PAGE, answer?.first)
                val request = MediaListRequest.parse(json)
                assertEquals(name, request.kind, answer!!.second.getString("kind"))
                val actual = JSONObject().put("requestId", requestIdOf(json)).put("kind", request.kind).put("limit", request.limit)
                    .put("cursor", request.cursor ?: JSONObject.NULL)
                assertEquals(name, plain(case.getJSONObject("expect")), plain(actual))
            } finally {
                phone.pool.shutdownNow()
            }
        }
    }

    /** media.cancel: the request ID is all the phone reads (BrowseServer.handle); it is never answered. */
    @Test fun mediaCancel() {
        cases("mediaCancel").forEach { case ->
            val name = case.getString("name")
            val json = strictJsonObject(case.getJSONObject("plaintext").toString().toByteArray()) ?: error("$name is not strict JSON")
            val requestId = requestIdOf(json)
            if (rejects(case)) return@forEach assertNull(name, requestId)
            assertEquals(name, plain(case.getJSONObject("expect")), plain(JSONObject().put("requestId", requestId)))
        }
    }
}
