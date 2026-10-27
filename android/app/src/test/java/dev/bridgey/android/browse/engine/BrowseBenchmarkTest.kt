package dev.bridgey.android.browse.engine

import dev.bridgey.android.browse.BrowseKinds
import dev.bridgey.android.browse.BrowseLimits
import dev.bridgey.android.browse.EncodedImage
import dev.bridgey.android.browse.ThumbnailBatcher
import dev.bridgey.android.browse.engine.BrowseHarness.Companion.PICTURES
import dev.bridgey.android.browse.engine.BrowseHarness.Companion.items
import dev.bridgey.android.browse.engine.BrowseHarness.Companion.mediaRef
import dev.bridgey.android.folders.FolderHashing
import dev.bridgey.android.folders.FolderScanner
import dev.bridgey.android.folders.FolderSendPlan
import dev.bridgey.android.folders.MemoryNode
import dev.bridgey.android.folders.utf8Length
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Server-side numbers on the JVM (no device): listing 10,000 entries, packing thumbnail batches, building and
 * hashing a 2,000-file manifest. Printed as "BENCH name=value"; budgets are loose so CI noise never fails them.
 * On the phone, storage queries and thumbnail decoding dominate; see the device test steps for those.
 */
class BrowseBenchmarkTest {
    private fun millis(block: () -> Unit): Double {
        val start = System.nanoTime()
        block()
        return (System.nanoTime() - start) / 1e6
    }

    @Test
    fun listingTenThousandEntries() {
        var now = 0L
        // One request every 300 ms of fake time: within the browse lane's 40 per 10 s.
        val phone = BrowseHarness(clock = { now += 300; now })
        repeat(10_000) { phone.pictures.put("Big/IMG_${"%05d".format(it)}.jpg", ByteArray(it % 5)) }
        // Warm up the JIT once.
        phone.request(BrowseKinds.PLACES_FILES, JSONObject().put("placeId", PICTURES).put("path", "Big"))
        var pages = 0
        var first = 0.0
        val total = millis {
            var cursor: Any = JSONObject.NULL
            do {
                val started = System.nanoTime()
                val id = phone.request(BrowseKinds.PLACES_FILES, JSONObject().put("placeId", PICTURES).put("path", "Big").put("cursor", cursor).put("sort", "modified"))
                if (pages == 0) first = (System.nanoTime() - started) / 1e6
                cursor = phone.answer(id)!!.second.opt("nextCursor")
                pages++
            } while (cursor != JSONObject.NULL)
        }
        println("BENCH listing_10000_pages=$pages listing_10000_total_ms=${"%.1f".format(total)} listing_first_page_ms=${"%.1f".format(first)}")
        assertEquals(50, pages)
        assertTrue(first < 2_000)
    }

    @Test
    fun thumbnailBatchPackingThroughput() {
        var batches = 0
        var bytes = 0L
        val image = EncodedImage(ByteArray(9_000) { it.toByte() }, "image/webp", 256, 192, 0x445566)
        val elapsed = millis {
            val batcher = ThumbnailBatcher("6f1c3a52-0000-4000-8000-000000000000") { batch ->
                batches++
                bytes += utf8Length(batch.toString())
            }
            repeat(3_000) { batcher.add("k$it", image) }
            batcher.flush(done = true)
        }
        val perSecond = 3_000 / (elapsed / 1000)
        println("BENCH thumbs_packed=3000 batches=$batches thumbs_per_batch=${"%.1f".format(3_000.0 / batches)} pack_ms=${"%.1f".format(elapsed)} thumbs_per_s=${"%.0f".format(perSecond)} avg_batch_bytes=${bytes / batches}")
        assertTrue(bytes / batches <= BrowseLimits.MEDIA_PLAINTEXT)
    }

    @Test
    fun thumbnailRequestEndToEndWithAFastMaker() {
        val phone = BrowseHarness()
        repeat(64) { phone.media.add(it.toLong() + 1, "IMG_$it.jpg", it.toLong()) }
        phone.thumbs.bytes = 9_000
        val request = items(*(1..64).map { "k$it" to mediaRef(it.toLong()) }.toTypedArray())
        phone.request(BrowseKinds.MEDIA_THUMBNAILS, JSONObject().put("items", request))
        val elapsed = millis { phone.request(BrowseKinds.MEDIA_THUMBNAILS, JSONObject().put("items", request)) }
        println("BENCH thumbnails_64_request_ms=${"%.1f".format(elapsed)} (fake maker, server and packing only)")
    }

    @Test
    fun manifestForTwoThousandFiles() {
        val root = MemoryNode("Camera").apply {
            repeat(20) { folder -> dir("Day $folder").apply { repeat(100) { file("IMG_$it.jpg", ByteArray(10_000) { b -> (b + folder).toByte() }) } } }
        }
        var scanMs = 0.0
        var hashMs = 0.0
        var pagesMs = 0.0
        var pages = 0
        scanMs = millis {
            val scan = FolderScanner.scanFolder(root)
            hashMs = millis {
                val hashed = FolderHashing.hash(scan)!!
                pagesMs = millis {
                    val plan = FolderSendPlan("6f1c3a52-0000-4000-8000-000000000000", hashed.rootName, hashed.entries, { throw IllegalStateException() },
                        hashed.skipped, false, null, false)
                    pages = plan.pages.size
                }
            }
        }
        println("BENCH manifest_2000_files_scan_hash_ms=${"%.1f".format(scanMs)} hash_ms=${"%.1f".format(hashMs)} pages=$pages pages_ms=${"%.1f".format(pagesMs)} bytes_hashed=20000000")
        assertTrue(pages in 8..20)
    }
}
