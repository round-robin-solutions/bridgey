package dev.bridgey.android.migrations

import dev.bridgey.android.AddressBookStore
import dev.bridgey.android.AddressSource
import dev.bridgey.android.ClipboardCache
import dev.bridgey.android.KnownAddressBook
import dev.bridgey.android.ReceivedClipOffer
import dev.bridgey.android.folders.ConflictChoice
import dev.bridgey.android.folders.FolderJournals
import dev.bridgey.android.migrations.MigrationFixtures.BASE_MILLIS
import dev.bridgey.android.migrations.MigrationFixtures.HOUR
import dev.bridgey.android.migrations.MigrationFixtures.MAC_A
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Folder transfer journals (Beta 10), the clipboard cache's offer records (Beta 5) and a damaged
 * reconnect address book (the good one is in [SharedPrefsMigrationTest]).
 */
class FileStoreMigrationTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val journalId = "5d674f55-b8a9-401c-9355-5ee93731c294"
    private val unknownVersionJournalId = "f15ea229-4c8f-4ff9-906a-6fb9c15382fd"
    private val offerId = "7128e2f0-3296-4d06-9af8-136a4a16cac5"

    private fun journals(now: Long): Pair<File, FolderJournals> {
        val directory = File(folder.root, "folder-transfers").apply { mkdirs() }
        MigrationFixtures.file("folder-transfers").listFiles().orEmpty().forEach { source ->
            val target = source.copyTo(File(directory, source.name), overwrite = true)
            // The journal's modification time is its last progress.
            target.setLastModified(BASE_MILLIS)
        }
        return directory to FolderJournals(directory) { now }
    }

    @Test
    fun aBeta10JournalResumesWithEveryFinishedFileAndOpenPart() {
        val (directory, store) = journals(BASE_MILLIS + HOUR)
        val record = store.read(journalId) ?: error("the Beta 10 journal was not read")
        val root = "content://com.android.externalstorage.documents/tree/primary%3ADownload/document/primary%3ADownload%2FBridgey%2FTrip 2026"
        assertEquals(MAC_A, record.header.peerId)
        assertEquals("99d35512273e0bf7ceb7a67b0ec97805a5c6cfb2b30a8852e5c452c6cf6a108f", record.header.manifestSha256)
        assertEquals(BASE_MILLIS, record.header.createdAtMillis)
        assertEquals("default", record.header.placeId)
        assertEquals(ConflictChoice.MERGE, record.header.choice)
        assertEquals("Trip 2026", record.header.rootName)
        assertEquals(root, record.header.rootUri)
        assertEquals("Download/Bridgey", record.header.destinationLabel)
        assertNull(record.header.oneOffTree)
        assertEquals(BASE_MILLIS, record.lastProgressMillis)
        assertEquals(mapOf(0 to "$root%2FDay 1"), record.dirs)
        assertEquals(setOf(1, 4), record.done)
        assertEquals("unknown and malformed lines are ignored", mapOf(2 to "$root%2Fb.jpg.bridgey-part"), record.openParts)
        assertEquals(setOf(3), record.openReplaces.keys)
        assertEquals("c.jpg", record.openReplaces.getValue(3).finalName)

        // A journal with a header this build does not know is not resumed, and is removed.
        assertNull(store.read(unknownVersionJournalId))
        assertEquals(listOf(journalId), store.all().map { it.folderTransferId })
        assertFalse(File(directory, "$unknownVersionJournalId.journal").exists())
    }

    @Test
    fun aJournalPastTheResumeWindowIsDroppedOnStart() {
        val (directory, store) = journals(BASE_MILLIS + 25 * HOUR)
        val dropped = store.recover { null }
        assertEquals(listOf(journalId), dropped.map { it.folderTransferId })
        assertFalse(File(directory, "$journalId.journal").exists())
    }

    @Test
    fun aBeta5OfferRecordStillResolvesAPaste() {
        val record = ReceivedClipOffer.decode(MigrationFixtures.file("clipboard-cache/$offerId/offer.json").readText())
        assertNotNull(record)
        record!!
        assertEquals(offerId, record.offer.offerId)
        assertEquals(MAC_A, record.deviceId)
        assertEquals("Test Mac A", record.peerName)
        assertEquals(BASE_MILLIS + 1_000, record.receivedAt)
        assertEquals(listOf("image/png", "application/pdf"), record.offer.items.map { it.mime })
        assertEquals("report.pdf", record.offer.items[1].name)
        // The record re-encodes to the same shape it was read from.
        assertEquals(record, ReceivedClipOffer.decode(record.encode()))
    }

    @Test
    fun theCacheKeepsAFreshBeta5OfferAndAgesOutAnOldOne() {
        val root = File(folder.root, "clipboard")
        val offerDirectory = File(root, offerId).apply { mkdirs() }
        MigrationFixtures.file("clipboard-cache/$offerId/offer.json").copyTo(File(offerDirectory, "offer.json"))
        File(offerDirectory, "0").mkdirs()
        File(offerDirectory, "0/data").writeBytes(ByteArray(16))
        File(offerDirectory, "0/complete").createNewFile()

        ClipboardCache(root, clock = { BASE_MILLIS + HOUR }).apply {
            removePartials()
            evict()
            assertTrue(isComplete(offerId, 0))
        }
        ClipboardCache(root, clock = { BASE_MILLIS + 25 * HOUR }).evict()
        assertFalse("nothing is kept past 24 hours", offerDirectory.exists())
    }

    @Test
    fun malformedOfferRecordsAreRejectedWithoutCrashing() {
        assertNull(ReceivedClipOffer.decode("{ not json"))
        assertNull(ReceivedClipOffer.decode("""{"offer":{"version":2,"offerId":"$offerId","createdAt":1,"items":[]},"deviceId":"x","peerName":"y","receivedAt":1}"""))
        assertNull(ReceivedClipOffer.decode("""{"deviceId":"x","peerName":"y","receivedAt":1}"""))
    }

    @Test
    fun aDamagedAddressBookCostsOnlyTheCacheAndNeverCrashes() {
        // The book is a cache rebuilt from NSD and connections. Today an entry that is not an object
        // drops the whole book (a bad address inside an entry is dropped on its own); the next write
        // starts a clean book.
        val store = object : AddressBookStore {
            var value: String? = """{"$MAC_A":"not an object","95b2dd40-4f91-44e7-9f28-d6655fcbd197":{"addresses":[]}}"""
            override fun load(): String? = value
            override fun save(value: String) { this.value = value }
        }
        val book = KnownAddressBook(store)
        assertTrue(book.addresses(MAC_A).isEmpty())
        assertTrue(book.learn(MAC_A, "192.168.1.20", 42_458, AddressSource.OUTBOUND, BASE_MILLIS))
        assertEquals(listOf("192.168.1.20"), KnownAddressBook(store).addresses(MAC_A).map { it.host })
    }
}
