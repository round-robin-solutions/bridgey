package dev.bridgey.android

import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ClipboardCacheTest {
    @get:Rule val folder = TemporaryFolder()

    private var now = 1_786_550_000_000L
    private fun cache(maxBytes: Long = ClipLimits.CACHE_MAX_BYTES) = ClipboardCache(File(folder.root, "clipboard-cache"), { now }, maxBytes = maxBytes)

    private fun saved(cache: ClipboardCache, items: Int = 2, at: Long = now): String {
        val id = UUID.randomUUID().toString()
        val offer = ClipOffer(id, at, false, (0 until items).map { ClipOfferItem(it, ClipItemKind.FILE, "application/octet-stream", "f$it", 100, null, null) })
        cache.saveOffer(ReceivedClipOffer(offer, "mac", "Work MacBook", at))
        return id
    }

    @Test
    fun supersedeDeletesItemsNoAppOpenedAndKeepsHandedOutOnes() {
        val cache = cache()
        val id = saved(cache, items = 3)
        cache.writeComplete(id, 0, ByteArray(100))
        cache.writeComplete(id, 1, ByteArray(100))
        cache.markHandedOut(id, 1)
        cache.createData(id, 2).writeBytes(ByteArray(10)) // partial, handed out
        cache.markHandedOut(id, 2)
        cache.supersede(id)
        assertFalse("eager item never pasted", cache.isComplete(id, 0))
        assertTrue("a pasted file stays readable", cache.isComplete(id, 1))
        assertFalse("a partial is never kept", cache.dataFile(id, 2).exists())
        assertNotNull("its description stays with it", cache.loadOffer(id))
    }

    @Test
    fun canHoldCountsKeptOffersOnly() {
        val cache = cache(maxBytes = 250)
        val kept = saved(cache)
        cache.writeComplete(kept, 0, ByteArray(100))
        val other = saved(cache)
        cache.writeComplete(other, 0, ByteArray(100))
        val keptBytes = File(folder.root, "clipboard-cache/$kept").walkTopDown().filter(File::isFile).sumOf(File::length)
        assertTrue("an offer that could be evicted makes room", cache.canHold(250 - keptBytes, setOf(kept)))
        assertFalse("the kept offer counts toward the cap", cache.canHold(250 - keptBytes + 1, setOf(kept)))
        assertTrue(cache.canHold(250, emptySet()))
    }

    @Test
    fun supersedeRemovesTheWholeOfferWhenNothingWasHandedOut() {
        val cache = cache()
        val id = saved(cache)
        cache.writeComplete(id, 0, ByteArray(100))
        cache.supersede(id)
        assertFalse(File(folder.root, "clipboard-cache/$id").exists())
    }

    @Test
    fun nothingIsKeptLongerThan24Hours() {
        val cache = cache()
        val old = saved(cache, at = now - ClipLimits.CACHE_MAX_AGE_MILLIS - 1)
        cache.writeComplete(old, 0, ByteArray(100))
        cache.markHandedOut(old, 0)
        val fresh = saved(cache, at = now - 60_000)
        cache.writeComplete(fresh, 0, ByteArray(100))
        cache.evict()
        assertFalse("handed out, but too old", cache.isComplete(old, 0))
        assertTrue(cache.isComplete(fresh, 0))
    }

    @Test
    fun theCapEvictsOldestFirstAndNeverOffersInUse() {
        val cache = cache(maxBytes = 25_000)
        val oldest = saved(cache, at = now - 3_000).also { cache.writeComplete(it, 0, ByteArray(10_000)) }
        val middle = saved(cache, at = now - 2_000).also { cache.writeComplete(it, 0, ByteArray(10_000)) }
        val newest = saved(cache, at = now - 1_000).also { cache.writeComplete(it, 0, ByteArray(10_000)) }
        cache.evict(keep = setOf(oldest))
        assertTrue("in use, kept despite its age", cache.isComplete(oldest, 0))
        assertFalse("next oldest goes", cache.isComplete(middle, 0))
        assertTrue(cache.isComplete(newest, 0))
        assertTrue(cache.totalBytes() <= 25_000)
    }

    @Test
    fun startUpRemovesPartialsAndOrphans() {
        val cache = cache()
        val id = saved(cache)
        cache.writeComplete(id, 0, ByteArray(100))
        cache.createData(id, 1).writeBytes(ByteArray(5))
        val orphan = File(folder.root, "clipboard-cache/${UUID.randomUUID()}/0").apply { mkdirs() }
        File(orphan, "data").writeBytes(ByteArray(5))
        cache.removePartials()
        assertTrue(cache.isComplete(id, 0))
        assertFalse(cache.dataFile(id, 1).exists())
        assertFalse(orphan.parentFile!!.exists())
    }

    @Test
    fun clearDeletesEverything() {
        val cache = cache()
        val id = saved(cache)
        cache.writeComplete(id, 0, ByteArray(100))
        cache.markHandedOut(id, 0)
        cache.clear()
        assertEquals(0L, cache.totalBytes())
        assertFalse(File(folder.root, "clipboard-cache").exists())
    }
}
