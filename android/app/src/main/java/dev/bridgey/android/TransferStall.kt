package dev.bridgey.android

/**
 * An accepted transfer always ends: received, failed, cancelled, or (here) timed out. One with no progress
 * for [TIMEOUT_MILLIS] is failed, and until then it stops counting as busy for an automatic update.
 * 2026-11-04: a 112 KB receive stayed active for 40 minutes and blocked Update all on the Mac.
 */
object TransferStall {
    const val TIMEOUT_MILLIS = 120_000L
    const val SWEEP_MILLIS = 15_000L

    fun isStalled(lastProgressAtMillis: Long, nowMillis: Long): Boolean = nowMillis - lastProgressAtMillis >= TIMEOUT_MILLIS

    /** Active and still moving: the person's activity for the busy rule. */
    fun isBusy(transfer: FileTransferState, nowMillis: Long): Boolean =
        transfer.active && !isStalled(transfer.lastProgressAtMillis, nowMillis)

    /**
     * The transfers to fail now: single files that were offered (in [tracked]), are active, not waiting in a queue
     * and silent for the timeout. Folders have their own session; queued and preparing files are not offered yet.
     */
    fun stalledIds(rows: Collection<FileTransferState>, tracked: Set<String>, nowMillis: Long): List<String> =
        rows.filter {
            it.active && !it.queued && it.kind == TransferKind.FILE && it.id in tracked && isStalled(it.lastProgressAtMillis, nowMillis)
        }.map { it.id }.sorted()
}
