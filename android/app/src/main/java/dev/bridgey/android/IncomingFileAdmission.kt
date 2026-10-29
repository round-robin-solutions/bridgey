package dev.bridgey.android

import dev.bridgey.android.folders.FolderCodes
import dev.bridgey.android.folders.FolderLimits

/** Single files (outside folder transfers) one Mac may send at once. */
internal const val MAX_INCOMING_FILES_PER_DEVICE = 4

/** Single files all Macs together may send at once. */
internal const val MAX_INCOMING_FILES_TOTAL = 8

/** A single-file offer is accepted, or refused with a [FolderCodes] code (and, for space, the bytes it needs). */
internal sealed class IncomingFileAdmission {
    object Accept : IncomingFileAdmission()
    object Busy : IncomingFileAdmission()
    data class NoSpace(val neededBytes: Long, val freeBytes: Long) : IncomingFileAdmission()
}

/**
 * Decides a single-file offer of [size] bytes. [deviceInFlight] and [totalInFlight] count the single files
 * being received now; [reservedBytes] is what they still have to write. Unknown free space ([freeBytes] null)
 * does not refuse, as before.
 */
internal fun incomingFileAdmission(
    size: Long,
    deviceInFlight: Int,
    totalInFlight: Int,
    reservedBytes: Long,
    freeBytes: Long?,
    margin: Long = FolderLimits.SPACE_MARGIN,
): IncomingFileAdmission {
    if (deviceInFlight >= MAX_INCOMING_FILES_PER_DEVICE || totalInFlight >= MAX_INCOMING_FILES_TOTAL) {
        return IncomingFileAdmission.Busy
    }
    val needed = size + reservedBytes.coerceAtLeast(0) + margin
    if (freeBytes != null && freeBytes < needed) return IncomingFileAdmission.NoSpace(needed, freeBytes)
    return IncomingFileAdmission.Accept
}
