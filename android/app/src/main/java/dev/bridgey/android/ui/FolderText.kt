package dev.bridgey.android.ui

import android.content.Context
import android.text.format.Formatter
import dev.bridgey.android.R
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.activity.ActivityKind
import dev.bridgey.android.activity.FolderDetail
import dev.bridgey.android.folders.FolderCodes
import dev.bridgey.android.folders.FolderEnd
import dev.bridgey.android.folders.FolderPolicy
import dev.bridgey.android.folders.FolderSnapshot
import dev.bridgey.android.folders.FolderWaiting

/**
 * Folder text for the Stream, the sheets and the notifications, from resources only (English and Russian).
 * Never logged.
 */
object FolderText {
    fun size(context: Context, bytes: Long): String = Formatter.formatShortFileSize(context, bytes.coerceAtLeast(0))

    fun files(context: Context, count: Int): String = context.resources.getQuantityString(R.plurals.folder_files, count, count)

    fun duration(context: Context, seconds: Long): String = when {
        seconds < 60 -> context.getString(R.string.duration_seconds, seconds.coerceAtLeast(1).toInt())
        seconds < 3_600 -> context.getString(R.string.duration_minutes, ((seconds + 30) / 60).toInt())
        else -> context.getString(R.string.duration_hours, (seconds / 3_600).toInt(), ((seconds % 3_600) / 60).toInt())
    }

    fun countdown(deadlineMillis: Long?, now: Long): String =
        FolderPolicy.countdown(if (deadlineMillis == null) 0 else ((deadlineMillis - now + 999) / 1000).toInt().coerceAtLeast(0))

    /**
     * "Photos from MacBook Pro › Pictures/Trip"; for folders this phone sends, "Sending Photos to MacBook Pro"
     * or, for a download the Mac asked for, "MacBook Pro is downloading 3 files".
     */
    fun cardTitle(context: Context, folder: FolderSnapshot): String = when {
        folder.outgoing && folder.download -> if (folder.filesTotal == 1) {
            context.getString(R.string.live_download_title_one, folder.deviceName, folder.rootName)
        } else {
            context.resources.getQuantityString(R.plurals.live_download_title, folder.filesTotal, folder.deviceName, folder.filesTotal)
        }
        folder.outgoing -> folder.destinationLabel?.let {
            context.getString(R.string.live_send_folder_title, folder.rootName, folder.deviceName, it)
        } ?: context.getString(R.string.live_send_folder_title_plain, folder.rootName, folder.deviceName)
        else -> folder.destinationLabel?.let {
            context.getString(R.string.live_folder_title, folder.rootName, folder.deviceName, it)
        } ?: context.getString(R.string.live_folder_title_plain, folder.rootName, folder.deviceName)
    }

    /** "37 of 124 files · 812 MB of 2.3 GB · 12 MB/s · 2 min left", or the waiting line. */
    fun statusLine(context: Context, folder: FolderSnapshot, now: Long): String {
        if (folder.end == FolderEnd.INTERRUPTED) return context.getString(R.string.live_folder_interrupted, folder.deviceName)
        // Sending: the questions show on the other device; this phone only waits for its answer.
        if (folder.outgoing) when (folder.waiting) {
            FolderWaiting.MANIFEST -> return context.getString(R.string.live_send_preparing)
            FolderWaiting.DESTINATION -> return context.getString(R.string.live_send_waiting_destination, folder.deviceName, countdown(folder.deadlineMillis, now))
            FolderWaiting.CONFLICT_HERE, FolderWaiting.CONFLICT_ON_SENDER ->
                return context.getString(R.string.live_send_waiting_conflict, folder.deviceName, countdown(folder.deadlineMillis, now))
            null -> Unit
        }
        when (folder.waiting) {
            FolderWaiting.MANIFEST -> return context.getString(R.string.live_folder_checking)
            FolderWaiting.DESTINATION -> return context.getString(R.string.live_folder_waiting_destination, countdown(folder.deadlineMillis, now))
            FolderWaiting.CONFLICT_HERE -> return context.getString(R.string.live_folder_waiting_conflict, countdown(folder.deadlineMillis, now))
            FolderWaiting.CONFLICT_ON_SENDER -> return context.getString(R.string.live_folder_waiting_sender, folder.deviceName, countdown(folder.deadlineMillis, now))
            null -> Unit
        }
        val parts = ArrayList<String>()
        parts += context.resources.getQuantityString(R.plurals.folder_files_progress, folder.filesTotal, folder.filesDone, folder.filesTotal)
        parts += context.getString(R.string.folder_bytes_progress, size(context, folder.bytesDone), size(context, folder.bytesTotal))
        if (folder.bytesPerSecond > 0 && folder.end == null) {
            parts += context.getString(R.string.folder_speed, size(context, folder.bytesPerSecond))
            val left = (folder.bytesTotal - folder.bytesDone).coerceAtLeast(0)
            if (left > 0) parts += context.getString(R.string.folder_time_left, duration(context, left / folder.bytesPerSecond))
        }
        return parts.joinToString(" · ")
    }

    /** Overall progress by bytes, 0 to 1; null while nothing is known yet. */
    fun progress(folder: FolderSnapshot): Float? = when {
        folder.waiting != null -> null
        folder.bytesTotal <= 0L -> if (folder.filesTotal == 0) 1f else folder.filesDone.toFloat() / folder.filesTotal
        else -> (folder.bytesDone.toDouble() / folder.bytesTotal).toFloat().coerceIn(0f, 1f)
    }

    fun failureReason(context: Context, code: String): String = context.getString(
        when (code) {
            FolderCodes.IO_ERROR -> R.string.folder_reason_io_error
            FolderCodes.VERIFICATION_FAILED -> R.string.folder_reason_verification_failed
            FolderCodes.INVALID_MESSAGE -> R.string.folder_reason_invalid_message
            FolderCodes.SOURCE_CHANGED -> R.string.folder_reason_source_changed
            FolderCodes.UNREADABLE -> R.string.folder_reason_unreadable
            FolderCodes.PLACE_UNAVAILABLE -> R.string.folder_detail_lost_access
            FolderCodes.INSUFFICIENT_SPACE -> R.string.folder_detail_no_space
            else -> R.string.folder_reason_other
        },
    )

    /** "Received folder Photos (124 files, 2.3 GB)" and the other folder titles of 3.5. */
    fun itemTitle(context: Context, item: ActivityItem, device: String): String {
        val name = item.fileName ?: context.getString(R.string.stream_file_unnamed)
        val count = item.fileCount ?: 0
        val bytes = size(context, item.bytes ?: 0)
        val tokens = FolderDetail.decode(item.detail).map { it.first }
        return when (item.kind) {
            ActivityKind.FOLDER_SENT -> context.getString(R.string.stream_folder_sent_title, name, files(context, count), bytes)
            ActivityKind.FOLDER_RECEIVED -> context.getString(R.string.stream_folder_received_title, name, files(context, count), bytes)
            else -> when {
                FolderDetail.TIMEOUT in tokens && count == 0 -> context.getString(R.string.stream_folder_timeout_title, device)
                count == 0 && item.destination == null -> context.getString(R.string.stream_folder_not_saved_title, name, device)
                else -> context.resources.getQuantityString(R.plurals.stream_folder_incomplete_title, count, count, name, bytes)
            }
        }
    }

    /** The detail line: what happened, or where it came from and went. */
    fun itemDetail(context: Context, item: ActivityItem, device: String): String {
        val line = detailLine(context, item)
        if (line != null) return line
        val destination = item.destination
        return when {
            item.kind == ActivityKind.FOLDER_SENT && destination != null -> context.getString(R.string.stream_folder_sent_to, device, destination)
            destination != null -> context.getString(R.string.stream_folder_from_to, device, destination)
            else -> context.getString(R.string.stream_folder_from, device)
        }
    }

    /** "Merged, 12 kept as copies · 3 links and 12 hidden items skipped · 3 files failed". Null when there is nothing to say. */
    fun detailLine(context: Context, item: ActivityItem): String? {
        val res = context.resources
        val parts = ArrayList<String>()
        val skipped = ArrayList<String>()
        FolderDetail.decode(item.detail).forEach { (key, count) ->
            val n = count ?: 0
            when (key) {
                FolderDetail.MERGED -> parts += if (n > 0) res.getQuantityString(R.plurals.folder_detail_merged_copies, n, n) else context.getString(R.string.folder_detail_merged)
                FolderDetail.REPLACED -> if (n > 0) parts += res.getQuantityString(R.plurals.folder_detail_replaced, n, n)
                FolderDetail.SAVED_AS_COPY -> item.fileName?.let { parts += context.getString(R.string.folder_detail_saved_as, it) }
                FolderDetail.LINKS -> skipped += res.getQuantityString(R.plurals.folder_detail_links, n, n)
                FolderDetail.HIDDEN -> skipped += res.getQuantityString(R.plurals.folder_detail_hidden, n, n)
                FolderDetail.SYSTEM -> skipped += res.getQuantityString(R.plurals.folder_detail_system, n, n)
                FolderDetail.OTHER_SKIPPED -> skipped += res.getQuantityString(R.plurals.folder_detail_other_skipped, n, n)
                FolderDetail.EMPTY_SKIPPED -> parts += res.getQuantityString(R.plurals.folder_detail_empty_skipped, n, n)
                FolderDetail.FAILED -> parts += res.getQuantityString(R.plurals.folder_detail_failed, n, n)
                FolderDetail.CANCELLED -> parts += context.getString(R.string.folder_detail_cancelled)
                FolderDetail.CONNECTION_LOST -> parts += context.getString(R.string.folder_detail_connection_lost)
                FolderDetail.LOST_ACCESS -> parts += context.getString(R.string.folder_detail_lost_access)
                FolderDetail.NO_SPACE -> parts += context.getString(R.string.folder_detail_no_space)
                FolderDetail.TIMEOUT -> if ((item.fileCount ?: 0) > 0) parts += context.getString(R.string.folder_detail_timeout)
            }
        }
        if (skipped.isNotEmpty()) parts += context.getString(R.string.folder_detail_skipped, list(context, skipped))
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
    }

    /** "a and b", "a, b and c". */
    fun list(context: Context, items: List<String>): String = when (items.size) {
        0 -> ""
        1 -> items[0]
        else -> context.getString(R.string.list_two, items.dropLast(1).reduce { acc, next -> context.getString(R.string.list_more, acc, next) }, items.last())
    }
}
