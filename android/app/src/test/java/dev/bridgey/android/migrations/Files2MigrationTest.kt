package dev.bridgey.android.migrations

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.AttachPreferences
import dev.bridgey.android.BridgeySettings
import dev.bridgey.android.browse.DocumentTreeSource
import dev.bridgey.android.browse.IndexChild
import dev.bridgey.android.browse.IndexRoot
import dev.bridgey.android.browse.TreeDocumentIndex
import dev.bridgey.android.folders.FolderSendJournals
import dev.bridgey.android.folders.ManifestEntry
import dev.bridgey.android.folders.SkippedCounts
import dev.bridgey.android.migrations.MigrationFixtures.BASE_MILLIS
import dev.bridgey.android.migrations.MigrationFixtures.HOUR
import dev.bridgey.android.migrations.MigrationFixtures.MAC_A
import dev.bridgey.android.migrations.MigrationFixtures.MAC_B
import dev.bridgey.android.ui.attach.AttachTab
import java.io.File
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Files 2.0 (0.8.0-rr.1) stores on the phone: folder send journals (`folder-sends`), the recent documents index
 * (`document-index.json`), the browse switch (`files.allow_browse`) and the attach sheet's preferences
 * (`bridgey.attach`). Fixtures in `protocol/test-vectors/migrations/android/`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class Files2MigrationTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val context: Context get() = ApplicationProvider.getApplicationContext<Application>()

    private val sendId = "3b0c8f9e-5a41-4d7c-9e21-6f0a2b4c8d13"
    private val downloadId = "c41d7e2b-9f03-4a6e-b5d8-2e7f1a0c3b94"
    private val newerVersionId = "b7e4d2a1-0c3f-4e58-8a96-1d2e3f4a5b6c"
    private val damagedId = "e9a0b1c2-d3e4-4f56-8789-0a1b2c3d4e5f"

    // MARK: Folder send journals (no_backup/folder-sends/<id>.plan and <id>.done)

    private fun sendJournals(now: Long): Pair<File, FolderSendJournals> {
        val directory = File(folder.root, "folder-sends").apply { mkdirs() }
        MigrationFixtures.file("folder-sends").listFiles().orEmpty().forEach { source ->
            // The later of the two files' modification times is the journal's last progress.
            source.copyTo(File(directory, source.name), overwrite = true).setLastModified(BASE_MILLIS)
        }
        return directory to FolderSendJournals(directory) { now }
    }

    @Test
    fun aFolderSendResumesWithItsManifestSourcesAndConfirmedEntries() {
        val (_, store) = sendJournals(BASE_MILLIS + HOUR)
        val record = store.read(sendId) ?: error("the 0.8.0-rr.1 send journal was not read")
        with(record.header) {
            assertEquals(sendId, folderTransferId)
            assertEquals(MAC_A, peerId)
            assertEquals("Test Mac A", peerName)
            assertEquals("Trip 2026", rootName)
            assertFalse(into)
            assertNull(downloadRequestId)
            assertEquals(SkippedCounts(links = 1, hidden = 2), skipped)
            assertEquals(BASE_MILLIS, createdAtMillis)
            assertEquals("content://com.android.externalstorage.documents/tree/primary%3APictures%2FTrip%202026", releaseTree)
        }
        assertEquals(listOf("Day 1", "Day 1/a.jpg", "Day 1/b.mp4", "Day 2", "notes.txt"), record.entries.map { it.path })
        assertEquals(ManifestEntry.Type.DIR, record.entries[0].type)
        assertNull(record.entries[0].sha256)
        assertNull(record.entries[0].modified)
        assertEquals(10_485_760L, record.entries[2].size)
        assertEquals(BASE_MILLIS - 24 * HOUR, record.entries[1].modified)
        assertNull("-1 is no modification time", record.entries[4].modified)
        assertNull(record.sources[0])
        assertTrue(record.sources[1]!!.endsWith("Day%201%2Fa.jpg"))
        assertEquals("out-of-range and malformed lines are ignored", setOf(1, 4), record.done)
        assertEquals(BASE_MILLIS, record.lastProgressMillis)

        // A write in this build appends to the same journal.
        store.markDone(sendId, listOf(2))
        assertEquals(setOf(1, 2, 4), store.read(sendId)!!.done)
    }

    @Test
    fun aDownloadTheMacAskedForResumesAsAnIntoTransfer() {
        val (_, store) = sendJournals(BASE_MILLIS + HOUR)
        val record = store.read(downloadId) ?: error("the download journal was not read")
        assertEquals(MAC_B, record.header.peerId)
        assertTrue(record.header.into)
        assertEquals("8a2f6c1e-4b7d-4e90-a3c5-6d1f0e9b2a47", record.header.downloadRequestId)
        assertNull(record.header.releaseTree)
        assertEquals(SkippedCounts(), record.header.skipped)
        assertEquals(listOf("content://media/external/images/media/1234"), record.sources.take(1))
        assertTrue(record.done.isEmpty())
    }

    @Test
    fun unknownVersionAndDamagedJournalsAreRemovedOnTheirOwn() {
        val (directory, store) = sendJournals(BASE_MILLIS + HOUR)
        assertNull(store.read(newerVersionId))
        assertNull(store.read(damagedId))
        assertEquals(setOf(sendId, downloadId), store.prune().map { it.header.folderTransferId }.toSet())
        assertEquals(
            setOf("$sendId.plan", "$sendId.done", "$downloadId.plan", "$downloadId.done"),
            directory.list().orEmpty().toSet(),
        )
    }

    @Test
    fun journalsPastTheResumeWindowAreDropped() {
        val (directory, store) = sendJournals(BASE_MILLIS + 25 * HOUR)
        assertTrue(store.prune().isEmpty())
        assertTrue(directory.list().orEmpty().isEmpty())
    }

    // MARK: Recent documents index (no_backup/document-index.json)

    private val noRoots = object : DocumentTreeSource {
        override fun roots(): List<IndexRoot> = emptyList()
        override fun children(root: IndexRoot, dirId: String): List<IndexChild> = emptyList()
    }

    /** Never runs a refresh: what the attach sheet and the Mac see first, from the file. */
    private val never = Executor { }

    private fun index(fixture: String): TreeDocumentIndex {
        val file = File(folder.root, "document-index.json")
        MigrationFixtures.file("document-index/$fixture").copyTo(file, overwrite = true)
        return TreeDocumentIndex(noRoots, file, never, clock = { BASE_MILLIS + 60_000 })
    }

    @Test
    fun theDocumentIndexLoadsAndDropsBadItemsOneByOne() {
        val index = index("document-index.json")
        assertEquals(BASE_MILLIS, index.builtAtMillis)
        val items = index.recent(0, 100)
        assertEquals(listOf("Invoice 42.pdf", "notes.txt", "Plan.docx"), items.map { it.name })
        with(items[0]) {
            assertEquals("q3Jx0bVv1eG7tq8Wm2l5wA", placeId)
            assertEquals("Invoices", path)
            assertEquals(52_000L, size)
            assertEquals(BASE_MILLIS - 60_000, modifiedMillis)
            assertEquals("application/pdf", mimeType)
            assertEquals("Documents/Invoices", location)
        }
        assertNull(items[1].mimeType)
    }

    @Test
    fun anUnknownVersionOrDamagedIndexStartsEmptyWithoutCrashing() {
        for (fixture in listOf("document-index.version-2.json", "document-index.malformed.json")) {
            val index = index(fixture)
            assertEquals(fixture, 0L, index.builtAtMillis)
            assertTrue(fixture, index.recent(0, 100).isEmpty())
        }
    }

    // MARK: Preferences: files.allow_browse in bridgey.settings, and bridgey.attach

    @Test
    fun files2PreferencesSurvive() {
        MigrationFixtures.installSharedPrefs(context, 13)
        MigrationFixtures.installSharedPrefs(context, MigrationFixtures.FILES_2_SNAPSHOT)
        val settings = BridgeySettings(context, "Default name")
        assertFalse("browsing was turned off", settings.state.value.allowBrowseFromOtherDevices)
        assertTrue(settings.state.value.allowReplaceFromOtherDevices)
        assertEquals("Test Phone", settings.state.value.deviceName)
        val attach = AttachPreferences(context)
        assertEquals(AttachTab.FILES, attach.tab)
        assertEquals(MAC_A, attach.lastTarget)
        assertTrue(attach.documentsCardDismissed)
        assertTrue(attach.mediaAsked)

        // Written by this build, the other values stay.
        settings.setAllowBrowseFromOtherDevices(true)
        val reloaded = BridgeySettings(context, "Default name").state.value
        assertTrue(reloaded.allowBrowseFromOtherDevices)
        assertTrue(reloaded.allowReplaceFromOtherDevices)
    }

    @Test
    fun anAttachTabThisBuildDoesNotKnowFallsBackToPhotos() {
        context.getSharedPreferences("bridgey.attach", Context.MODE_PRIVATE).edit().putString("tab", "FUTURE").commit()
        assertEquals(AttachTab.MEDIA, AttachPreferences(context).tab)
    }
}
