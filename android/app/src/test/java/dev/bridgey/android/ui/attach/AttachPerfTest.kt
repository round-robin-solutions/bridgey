package dev.bridgey.android.ui.attach

import android.database.MatrixCursor
import android.graphics.Bitmap
import android.provider.MediaStore
import androidx.compose.ui.graphics.asImageBitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.bridgey.android.browse.DocumentTreeSource
import dev.bridgey.android.browse.IndexChild
import dev.bridgey.android.browse.IndexRoot
import dev.bridgey.android.browse.MediaItem
import dev.bridgey.android.browse.MediaQuery
import dev.bridgey.android.browse.TreeDocumentIndex
import java.io.File
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * JVM timings for the attach sheet's hot paths (printed as PERF lines; generous ceilings so CI never flakes).
 * Device numbers (MediaStore query, loadThumbnail, first frame) need the OnePlus 11.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = android.app.Application::class)
class AttachPerfTest {
    private fun median(runs: Int = 15, block: () -> Unit): Double {
        repeat(3) { block() }
        return (1..runs).map {
            val start = System.nanoTime()
            block()
            (System.nanoTime() - start) / 1_000_000.0
        }.sorted()[runs / 2]
    }

    private fun media(count: Int) = (1..count).map { id ->
        MediaItem(id.toLong(), "IMG_$id.jpg", 3_000_000L + id, id.toLong(), id.toLong(), "image/jpeg", 4000, 3000, null, "Camera", "content://media/external/images/media/$id")
    }

    @Test
    fun gridModelFor5000Items() {
        val items = media(5_000)
        val selection = items.shuffled(java.util.Random(7)).take(100).map(AttachKeys::media)
        var state = AttachState(media = items, selection = selection)
        val ms = median {
            state = state.copy(selection = AttachSelection.toggle(state.selection, AttachKeys.media(items[42])))
            val order = state.order
            var shown = 0
            items.forEach { if (order[AttachKeys.media(it)] != null) shown++ }
            check(shown in 99..101)
            check(state.selectedBytes > 0)
        }
        println("PERF attach.grid_model items=5000 selected=100 median_ms=%.2f".format(ms))
        assertTrue(ms < 250)
    }

    @Test
    fun mediaStoreRowsFor5000Items() {
        val cursor = { MatrixCursor(MediaQuery.projection, 5_000).apply {
            for (id in 1..5_000L) addRow(arrayOf<Any?>(id, "IMG_$id.jpg", 3_000_000L, 1_790_000_000L, 1_790_000_000_000L, 1_790_000_000L, "image/jpeg", 4000, 3000, null, "Camera", MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE))
        } }
        val prepared = (1..5).map { cursor() }.toMutableList()
        var mapped = 0
        val ms = median(runs = 5) {
            val rows = if (prepared.isNotEmpty()) prepared.removeAt(0) else cursor()
            mapped = MediaQuery.read(rows).size
        }
        assertEquals(5_000, mapped)
        println("PERF attach.mediastore_rows rows=5000 median_ms=%.2f".format(ms))
        assertTrue(ms < 2_000)
    }

    @Test
    fun thumbnailCacheHit() {
        val cache = ThumbnailMemoryCache(48 * 1024 * 1024)
        val items = media(100)
        val image = Bitmap.createBitmap(320, 320, Bitmap.Config.ARGB_8888).asImageBitmap()
        items.forEach { cache.put(ThumbnailMemoryCache.key(it), image) }
        val perHit = median {
            var hits = 0
            repeat(10) { items.forEach { if (cache.get(ThumbnailMemoryCache.key(it)) != null) hits++ } }
            check(hits == 1_000)
        } / 1_000 * 1_000
        println("PERF attach.thumbnail_cache_hit items=100 edge=320 cached_bytes=${cache.size} median_us_per_hit=%.3f".format(perHit))
        assertTrue(perHit < 50)
    }

    @Test
    fun documentIndexWalkOf20000Entries() {
        val root = IndexRoot("p", "Documents", "r", "tree")
        // 200 folders of 100 files each.
        val source = object : DocumentTreeSource {
            override fun roots() = listOf(root)
            override fun children(root: IndexRoot, dirId: String): List<IndexChild> = if (dirId == "r") {
                (0 until 200).map { IndexChild("d$it", "Folder $it", true, 0, 0, "vnd.android.document/directory", "") }
            } else {
                (0 until 100).map { IndexChild("$dirId/$it", "file $it.pdf", false, 1000, (dirId.drop(1).toLong() * 100 + it), "application/pdf", "content://x/$dirId/$it") }
            }
        }
        val dir = kotlin.io.path.createTempDirectory("index").toFile()
        val inline = Executor { it.run() }
        var kept = 0
        val ms = median(runs = 5) {
            val index = TreeDocumentIndex(source, File(dir, "i${System.nanoTime()}.json"), inline)
            index.placesChanged()
            kept = index.recent(0, 1_000).size
        }
        dir.deleteRecursively()
        assertEquals(500, kept)
        println("PERF documents.index_walk entries=20000 kept=500 median_ms=%.2f (fake provider; device time is dominated by provider queries)".format(ms))
        assertTrue(ms < 5_000)
    }
}
