package dev.bridgey.android.activity

import dev.bridgey.android.FileTransferState
import dev.bridgey.android.TransferEnd
import dev.bridgey.android.TransferKind
import dev.bridgey.android.folders.ConflictChoice
import dev.bridgey.android.folders.FolderEnd
import dev.bridgey.android.folders.FolderSnapshot
import dev.bridgey.android.folders.SkippedCounts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FolderActivityTest {
    @get:Rule val temp = TemporaryFolder()

    private fun file(outcome: TransferEnd?, active: Boolean = false, retryable: Boolean = false) =
        FileTransferState("t", "a.pdf", "whatever the status says", active, null, retryable = retryable, outcome = outcome)

    @Test
    fun fileOutcomesComeFromTheExplicitFieldNotTheStatusText() {
        assertEquals(TransferOutcome.SENT, transferOutcome(file(TransferEnd.SENT)))
        assertEquals(TransferOutcome.RECEIVED, transferOutcome(file(TransferEnd.RECEIVED)))
        assertEquals(TransferOutcome.FAILED, transferOutcome(file(TransferEnd.FAILED)))
        assertNull("a failure with Retry is its own record", transferOutcome(file(TransferEnd.FAILED, retryable = true)))
        assertNull(transferOutcome(file(TransferEnd.CANCELLED)))
        assertNull(transferOutcome(file(TransferEnd.INTERRUPTED)))
        assertNull(transferOutcome(file(null, active = true)))
        // The old status strings no longer decide anything.
        assertEquals(TransferOutcome.FAILED, transferOutcome(file(null).copy(status = "a.pdf saved to Download/Bridgey")))
    }

    private fun folder(
        end: FolderEnd?,
        choice: ConflictChoice? = ConflictChoice.NONE,
        code: String? = null,
        resumable: Boolean = false,
        failed: Int = 0,
        renamed: Int = 0,
        replaced: Int = 0,
        skipped: SkippedCounts = SkippedCounts(),
        done: Int = 124,
    ): FileTransferState {
        val snapshot = FolderSnapshot(
            "f", "mac-1", "MacBook Pro", "Photos", 124, 2_469_606_195, filesDone = done, bytesDone = 2_469_606_195,
            destinationLabel = "Pictures/Trip".takeIf { choice != null }, choice = choice, end = end, endCode = code, resumable = resumable,
            failedCount = failed, renamedFiles = renamed, replacedFiles = replaced, skipped = skipped,
        )
        return FileTransferState("f", "Photos", "", end == null, null, kind = TransferKind.FOLDER, folder = snapshot)
    }

    @Test
    fun foldersMapToTheirOwnKindsWithCountsDestinationAndDetail() {
        val complete = folderRecord(folder(FolderEnd.COMPLETE, skipped = SkippedCounts(links = 3, hidden = 12)))!!
        assertEquals(ActivityKind.FOLDER_RECEIVED, complete.kind)
        assertEquals(124, complete.fileCount)
        assertEquals(2_469_606_195, complete.bytes)
        assertEquals("Pictures/Trip", complete.destination)
        assertEquals("links=3,hidden=12", complete.detail)

        assertEquals("merged=12", folderRecord(folder(FolderEnd.COMPLETE, ConflictChoice.MERGE, renamed = 12))!!.detail)
        assertEquals("replaced=12", folderRecord(folder(FolderEnd.COMPLETE, ConflictChoice.REPLACE, replaced = 12))!!.detail)
        assertEquals("saved_as_copy", folderRecord(folder(FolderEnd.COMPLETE, ConflictChoice.NEW_FOLDER))!!.detail)

        val cancelled = folderRecord(folder(FolderEnd.INCOMPLETE, code = "cancelled", done = 37))!!
        assertEquals(ActivityKind.FOLDER_INCOMPLETE, cancelled.kind)
        assertEquals("cancelled", cancelled.detail)
        assertEquals("failed=3", folderRecord(folder(FolderEnd.INCOMPLETE, code = "too_many_failures", failed = 3))!!.detail)
        assertEquals("lost_access", folderRecord(folder(FolderEnd.INCOMPLETE, code = "place_unavailable"))!!.detail)

        val nobody = folderRecord(folder(FolderEnd.TIMED_OUT, choice = null, code = "timeout", done = 0))!!
        assertEquals(ActivityKind.FOLDER_INCOMPLETE, nobody.kind)
        assertEquals("timeout", nobody.detail)
        assertEquals("no_space", folderRecord(folder(FolderEnd.CANCELLED, choice = null, code = "insufficient_space", done = 0))!!.detail)
    }

    @Test
    fun runningResumableOrDeclinedFoldersRecordNothing() {
        assertNull(folderRecord(folder(null)))
        assertNull(folderRecord(folder(FolderEnd.INTERRUPTED, resumable = true)))
        assertNull("declined on this phone", folderRecord(folder(FolderEnd.CANCELLED, choice = null, code = "declined", done = 0)))
        assertNull("cancelled by the Mac before anything was written", folderRecord(folder(FolderEnd.CANCELLED, choice = null, code = "cancelled", done = 0)))
        assertNull("files are not folders", folderRecord(file(TransferEnd.RECEIVED)))
        assertNull("folders are not files", transferOutcome(folder(FolderEnd.COMPLETE)))
        assertEquals("connection_lost", folderRecord(folder(FolderEnd.INTERRUPTED, resumable = false))!!.detail)
    }

    @Test
    fun folderFieldsAreStoredOnlyOnFolderItemsAndSurviveAReload() {
        val target = java.io.File(temp.root, ActivityLog.FILE_NAME)
        val direct = java.util.concurrent.Executor { it.run() }
        val log = ActivityLog(target, direct) { 1_800_000_000_000L }
        log.record(ActivityKind.FOLDER_RECEIVED, "mac", "Mac", fileName = "Photos", bytes = 10, fileCount = 3, destination = "Pictures/Trip", detail = "merged=1,links=2")
        log.record(ActivityKind.FILE_RECEIVED, "mac", "Mac", fileName = "a.pdf", bytes = 10, fileCount = 3, destination = "x", detail = "merged=1")
        log.record(ActivityKind.FOLDER_INCOMPLETE, "mac", "Mac", fileName = "Photos", detail = "not a valid token list!", destination = "D".repeat(300))
        val reloaded = ActivityLog(target, direct) { 1_800_000_000_000L }.items.value
        val (incomplete, file, folder) = reloaded
        assertEquals(3, folder.fileCount)
        assertEquals("Pictures/Trip", folder.destination)
        assertEquals("merged=1,links=2", folder.detail)
        assertEquals(10L, folder.bytes)
        assertNull(file.fileCount)
        assertNull(file.destination)
        assertNull(file.detail)
        assertNull("invalid detail is dropped", incomplete.detail)
        assertEquals(128, incomplete.destination!!.length)
        assertEquals(ActivityCategory.FILES, ActivityKind.FOLDER_RECEIVED.category)
        assertEquals("folder_incomplete", ActivityKind.FOLDER_INCOMPLETE.key)
    }
}
