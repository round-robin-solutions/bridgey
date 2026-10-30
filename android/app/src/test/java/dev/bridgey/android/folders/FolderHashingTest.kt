package dev.bridgey.android.folders

import java.security.MessageDigest
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Hashing four files at a time keeps manifest order, sizes, hashes and the unreadable count of hashing one by one. */
class FolderHashingTest {
    private fun sha(bytes: ByteArray) = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(bytes))

    private fun folder(): Pair<MemoryNode, Map<String, ByteArray>> {
        val root = MemoryNode("root")
        val contents = LinkedHashMap<String, ByteArray>()
        repeat(40) { index ->
            val bytes = ByteArray(1_000 + index * 7_919) { (it * 31 + index).toByte() }
            val parent = if (index % 3 == 0) (root.kids.firstOrNull { it.isDirectory } ?: root.dir("sub")) else root
            parent.file("f%02d.bin".format(index), bytes)
            contents["f%02d.bin".format(index)] = bytes
        }
        return root to contents
    }

    @Test
    fun parallelHashingMatchesOneByOneInManifestOrder() {
        val (root, contents) = folder()
        root.kids.first { it.name == "f05.bin" }.unreadable = true
        val scan = FolderScanner.scanItems(listOf(root))
        val one = FolderHashing.hash(scan, threads = 1)!!
        val four = FolderHashing.hash(scan, threads = 4)!!
        assertEquals(one.entries, four.entries)
        assertEquals(one.nodes, four.nodes)
        assertEquals(1, four.skipped.unreadable - scan.skipped.unreadable)
        for (entry in four.entries.filter { !it.isDirectory }) {
            val bytes = contents.getValue(entry.path.substringAfterLast('/'))
            assertEquals(entry.path, sha(bytes), entry.sha256)
            assertEquals(bytes.size.toLong(), entry.size)
        }
    }

    @Test
    fun cancellingStopsEveryThread() {
        val (root, _) = folder()
        val scan = FolderScanner.scanItems(listOf(root))
        var calls = 0
        assertNull(FolderHashing.hash(scan, cancelled = { synchronized(this) { ++calls > 5 } }, threads = 4))
    }
}
