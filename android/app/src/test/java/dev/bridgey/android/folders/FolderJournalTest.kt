package dev.bridgey.android.folders

import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FolderJournalTest {
    @get:Rule val temp = TemporaryFolder()

    private val clock = FakeClock()
    private val id = "4b0c9d5e-1111-4222-8333-944455556666"

    private fun header(rootUri: String = "root", oneOff: String? = null) = FolderJournals.Header(
        "mac-1", "q1f3+/=", clock.now, "q3Jx0bVv1eG7tq8Wm2l5wA", ConflictChoice.MERGE, "Photos (1) é", rootUri, "Pictures/Trip 2026", oneOff,
    )

    @Test
    fun linesReplayIntoTheRecord() {
        val dir = temp.newFolder()
        val journals = FolderJournals(dir, clock::read)
        journals.create(id, header()).apply {
            dir(0, "content://x/document/a b")
            part(1, "content://x/document/p1")
            done(1)
            part(2, "content://x/document/p2")
            replace(3, "old3", "part3", "name 3.txt")
            part(4, "p4")
            abandoned(4)
            close()
        }
        val record = journals.read(id)!!
        assertEquals(header(), record.header)
        assertEquals(mapOf(0 to "content://x/document/a b"), record.dirs)
        assertEquals(setOf(1), record.done)
        assertEquals(mapOf(2 to "content://x/document/p2"), record.openParts)
        assertEquals(mapOf(3 to FolderJournals.Replace("old3", "part3", "name 3.txt")), record.openReplaces)
        assertEquals(clock.now, record.lastProgressMillis)
        // Owner-only.
        val file = File(dir, "$id.journal")
        assertTrue(file.canRead())
        // Empty fields and one-off trees survive too.
        journals.create(id, header(rootUri = "", oneOff = "content://tree/x y")).close()
        assertEquals("", journals.read(id)!!.header.rootUri)
        assertEquals("content://tree/x y", journals.read(id)!!.header.oneOffTree)
    }

    @Test
    fun recoveryDeletesPartFilesAndFinishesInterruptedReplaces() {
        val store = MemoryTreeStore()
        store.mkdirs("Photos")
        val old = store.put("Photos/a.txt", "old".toByteArray())
        val part = store.put("Photos/.a.txt.bridgey-part", "new".toByteArray())
        val half = store.put("Photos/b.txt", "hal".toByteArray())
        val bigPart = store.put("Photos/.c.bin.bridgey-part", "partial".toByteArray())
        val journals = FolderJournals(temp.newFolder(), clock::read)
        journals.create(id, header()).apply {
            part(0, store.uriOf(part))
            replace(0, store.uriOf(old), store.uriOf(part), "a.txt")
            part(1, store.uriOf(half))
            part(2, store.uriOf(bigPart))
            close()
        }
        val dropped = journals.recover { store }
        assertTrue(dropped.isEmpty())
        assertEquals(listOf("Photos/", "Photos/a.txt"), store.tree())
        assertArrayEquals("new".toByteArray(), store.find("Photos/a.txt")!!.content)
        val record = journals.read(id)!!
        assertEquals(setOf(0), record.done)
        assertTrue(record.openParts.isEmpty())
        assertTrue(record.openReplaces.isEmpty())
    }

    @Test
    fun aReplaceWhoseOldFileIsAlreadyGoneStillFinishes() {
        val store = MemoryTreeStore()
        val part = store.put("Photos/.a.txt.bridgey-part", "new".toByteArray())
        val journals = FolderJournals(temp.newFolder(), clock::read)
        journals.create(id, header()).apply {
            part(0, store.uriOf(part))
            replace(0, "gone", store.uriOf(part), "a.txt")
            close()
        }
        journals.recover { store }
        assertEquals(listOf("Photos/", "Photos/a.txt"), store.tree())
    }

    @Test
    fun journalsOlderThanTheWindowAreDroppedAndForgetDeviceDropsItsOwn() {
        val dir = temp.newFolder()
        val journals = FolderJournals(dir, clock::read)
        journals.create(id, header()).close()
        val other = "4b0c9d5e-1111-4222-8333-000000000000"
        journals.create(other, header().copy(peerId = "mac-2")).close()
        clock.now += FolderTimeouts.RESUME_WINDOW_MILLIS - 1_000
        assertTrue(journals.recover { null }.isEmpty())
        assertNotNull(journals.read(id))
        assertEquals(listOf(id), journals.deleteForPeer("mac-1").map { it.folderTransferId })
        assertNull(journals.read(id))
        assertNotNull(journals.read(other))
        clock.now += 1_000
        assertEquals(listOf(other), journals.recover { null }.map { it.folderTransferId })
        assertTrue(dir.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun aCorruptJournalIsDiscarded() {
        val dir = temp.newFolder()
        File(dir, "$id.journal").writeText("v0 nonsense\n")
        val journals = FolderJournals(dir, clock::read)
        assertNull(journals.read(id))
        assertTrue(journals.all().isEmpty())
        assertTrue(dir.listFiles().orEmpty().isEmpty())
    }
}
