package dev.bridgey.android.browse

import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class TreeDocumentIndexTest {
    @get:Rule val temp = TemporaryFolder()

    /** A tree in memory: folder id to children. */
    private class FakeSource(val roots: List<IndexRoot>, val tree: Map<String, List<IndexChild>>) : DocumentTreeSource {
        var queries = 0
        override fun roots(): List<IndexRoot> = roots
        override fun children(root: IndexRoot, dirId: String): List<IndexChild> {
            queries++
            return tree["${root.placeId}:$dirId"].orEmpty()
        }
    }

    private fun file(id: String, name: String, modified: Long, mime: String? = "application/pdf") =
        IndexChild(id, name, false, 1_000, modified, mime, "content://docs/$id")

    private fun dir(id: String, name: String) = IndexChild(id, name, true, 0, 0, "vnd.android.document/directory", "")

    private val now = 1_800_000_000_000L
    private val inline = Executor { it.run() }

    private fun sample(): FakeSource {
        val root = IndexRoot("docs", "Documents", "r", "tree")
        return FakeSource(
            listOf(root),
            mapOf(
                "docs:r" to listOf(
                    file("a", "invoice.pdf", 5), dir("work", "Work"), dir("hidden", ".secrets"),
                    file("p", "photo.jpg", 9, "image/jpeg"), file("v", "clip.mp4", 9, null), file("h", ".env", 8, "text/plain"),
                    file("part", ".x.bridgey-part", 9),
                ),
                "docs:work" to listOf(file("b", "plan.docx", 7, "application/vnd.openxmlformats"), dir("deep", "2026")),
                "docs:deep" to listOf(file("c", "notes.txt", 6, "text/plain")),
                "docs:hidden" to listOf(file("s", "key.pem", 100, "application/x-pem-file")),
            ),
        )
    }

    @Test
    fun indexesDocumentsNewestFirstWithPathsAndSkipsMediaAndHidden() {
        val index = TreeDocumentIndex(sample(), File(temp.root, "index.json"), inline, { now })
        index.refreshIfStale()
        val items = index.recent(0, 10)
        assertEquals(listOf("plan.docx", "notes.txt", "invoice.pdf"), items.map { it.name })
        assertEquals("Work", items[0].path)
        assertEquals("Work/2026", items[1].path)
        assertEquals("Documents/Work/2026", items[1].location)
        assertEquals("", items[2].path)
        assertFalse(index.indexing)
    }

    @Test
    fun walksWithinDepthEntriesAndKeepLimits() {
        val root = IndexRoot("p", "Place", "0", "tree")
        // A chain 12 folders deep, each with one document.
        val tree = (0 until 12).associate { level ->
            "p:$level" to listOf(dir("${level + 1}", "d$level"), file("f$level", "doc$level.pdf", level.toLong()))
        }
        val source = FakeSource(listOf(root), tree)
        val shallow = TreeDocumentIndex(source, File(temp.root, "a.json"), inline, { now }, TreeDocumentIndex.Limits(maxDepth = 3))
        shallow.refreshIfStale()
        assertEquals(4, shallow.recent(0, 100).size)

        val few = TreeDocumentIndex(source, File(temp.root, "b.json"), inline, { now }, TreeDocumentIndex.Limits(maxEntries = 5))
        few.refreshIfStale()
        assertTrue(few.recent(0, 100).size <= 3)

        val kept = TreeDocumentIndex(source, File(temp.root, "c.json"), inline, { now }, TreeDocumentIndex.Limits(keep = 2))
        kept.refreshIfStale()
        assertEquals(listOf("doc8.pdf", "doc7.pdf"), kept.recent(0, 100).map { it.name })
    }

    @Test
    fun timeBudgetStopsTheWalk() {
        var clock = now
        val root = IndexRoot("p", "Place", "0", "tree")
        val tree = (0 until 50).associate { level -> "p:$level" to listOf(dir("${level + 1}", "d$level"), file("f$level", "doc$level.pdf", level.toLong())) }
        val source = object : DocumentTreeSource {
            override fun roots() = listOf(root)
            override fun children(root: IndexRoot, dirId: String): List<IndexChild> {
                clock += 1_000
                return tree["p:$dirId"].orEmpty()
            }
        }
        val index = TreeDocumentIndex(source, File(temp.root, "t.json"), inline, { clock }, TreeDocumentIndex.Limits(maxDepth = 60, budgetMillis = 5_000))
        index.refreshIfStale()
        assertTrue(index.recent(0, 100).size in 1..6)
    }

    @Test
    fun cachedIndexServesAtOnceAndRefreshesOnlyWhenStaleOrPlacesChange() {
        var clock = now
        val target = File(temp.root, "index.json")
        val source = sample()
        TreeDocumentIndex(source, target, inline, { clock }).refreshIfStale()
        val queriesAfterFirst = source.queries

        val reopened = TreeDocumentIndex(source, target, inline, { clock })
        assertEquals(3, reopened.recent(0, 10).size)
        reopened.refreshIfStale()
        assertEquals(queriesAfterFirst, source.queries)

        clock += 6 * 60_000
        reopened.refreshIfStale()
        assertTrue(source.queries > queriesAfterFirst)

        val queries = source.queries
        reopened.placesChanged()
        assertTrue(source.queries > queries)
    }

    @Test
    fun indexFileIsOwnerOnly() {
        val target = File(temp.root, "index.json")
        TreeDocumentIndex(sample(), target, inline, { now }).refreshIfStale()
        assertTrue(target.isFile)
        val permissions = Files.getPosixFilePermissions(target.toPath())
        assertEquals(setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE), permissions)
    }

    @Test
    fun aFailingProviderKeepsTheLastIndex() {
        val target = File(temp.root, "index.json")
        TreeDocumentIndex(sample(), target, inline, { now }).refreshIfStale()
        val broken = object : DocumentTreeSource {
            override fun roots(): List<IndexRoot> = throw IllegalStateException("gone")
            override fun children(root: IndexRoot, dirId: String): List<IndexChild> = emptyList()
        }
        val index = TreeDocumentIndex(broken, target, inline, { now + 10 * 60_000 })
        index.refreshIfStale()
        assertEquals(3, index.recent(0, 10).size)
        assertFalse(index.indexing)
    }

    @Test
    fun documentRules() {
        assertTrue(DocumentRules.isDocument("application/pdf", "a.pdf"))
        assertTrue(DocumentRules.isDocument(null, "notes.txt"))
        assertFalse(DocumentRules.isDocument("image/png", "a.png"))
        assertFalse(DocumentRules.isDocument(null, "IMG_1.HEIC"))
        assertFalse(DocumentRules.isDocument("vnd.android.document/directory", "Work"))
        assertTrue(DocumentRules.hidden(".git"))
        assertTrue(DocumentRules.hidden("a.BRIDGEY-PART"))
        assertFalse(DocumentRules.hidden("report.pdf"))
    }
}
