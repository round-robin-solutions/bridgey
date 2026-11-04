package dev.bridgey.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** An accepted transfer always ends. 2026-11-04: a stuck 112 KB receive blocked Update all on the Mac for 40 minutes. */
class TransferStallTest {
    private val now = 1_800_000_000_000L

    private fun row(id: String, silentMillis: Long, active: Boolean = true, queued: Boolean = false, kind: TransferKind = TransferKind.FILE) =
        FileTransferState(id, "n", "Receiving", active, null, queued = queued, kind = kind, lastProgressAtMillis = now - silentMillis)

    @Test
    fun theTimeoutIsTwoMinutes() {
        assertEquals(120_000L, TransferStall.TIMEOUT_MILLIS)
        assertFalse(TransferStall.isStalled(now - 119_999, now))
        assertTrue(TransferStall.isStalled(now - 120_000, now))
    }

    @Test
    fun onlyAMovingActiveTransferIsBusy() {
        assertTrue(TransferStall.isBusy(row("a", 0), now))
        assertTrue(TransferStall.isBusy(row("a", 119_000), now))
        assertFalse(TransferStall.isBusy(row("a", 120_000), now))
        assertFalse("40 minutes with no data", TransferStall.isBusy(row("a", 40 * 60_000L), now))
        assertFalse(TransferStall.isBusy(row("a", 0, active = false), now))
    }

    @Test
    fun onlyAnOfferedActiveSilentSingleFileIsFailed() {
        val rows = listOf(
            row("stuck-b", 300_000),
            row("stuck-a", 121_000),
            row("fresh", 10_000),
            row("done", 900_000, active = false),
            row("waiting", 900_000, queued = true),
            row("folder", 900_000, kind = TransferKind.FOLDER),
            row("preparing", 900_000),
        )
        val tracked = setOf("stuck-a", "stuck-b", "fresh", "done", "waiting", "folder")
        assertEquals(listOf("stuck-a", "stuck-b"), TransferStall.stalledIds(rows, tracked, now))
    }
}
