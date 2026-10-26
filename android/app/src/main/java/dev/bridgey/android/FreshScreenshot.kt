package dev.bridgey.android

import android.Manifest
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import kotlin.math.abs
import kotlinx.coroutines.delay

/*
 * Settings > Clipboard > Send a fresh screenshot: Send copied item (notification, Quick Settings tile,
 * in-app send) sends a screenshot taken in the last minute instead of the clipboard. The choice is
 * pure ([pickFreshScreenshot], [FreshScreenshotFinder]) so it is unit tested with a fake MediaStore.
 */

/** A screenshot this recent (and newer than the clip) is sent instead of the clipboard. */
internal const val FRESH_SCREENSHOT_WINDOW_MILLIS = 60_000L

/** How long Send copied item waits for a screenshot that is still being written. */
internal const val SCREENSHOT_WRITE_WAIT_MILLIS = 1_000L
internal const val SCREENSHOT_POLL_MILLIS = 100L

/** The phone clock and MediaStore can disagree a little; a screenshot this far "in the future" still counts. */
internal const val SCREENSHOT_CLOCK_SKEW_MILLIS = 5_000L

/** DATE_TAKEN is used (it has milliseconds) only when it agrees with DATE_ADDED this closely. */
private const val DATE_TAKEN_AGREEMENT_MILLIS = 5_000L

/** One MediaStore image row, only the columns the choice needs. */
internal data class ScreenshotRow(
    val id: Long,
    /** RELATIVE_PATH (Android 10+), for example "DCIM/Screenshots/". */
    val relativePath: String?,
    /** BUCKET_DISPLAY_NAME, for example "Screenshots". */
    val bucket: String?,
    /** DATA (Android 9 and older), the file path. */
    val dataPath: String?,
    val dateAddedSeconds: Long,
    val dateTakenMillis: Long,
    val size: Long,
    val pending: Boolean,
    val mime: String?,
    val name: String?,
) {
    val inScreenshotsFolder: Boolean get() = isScreenshotsFolder(relativePath, bucket, dataPath)

    /** When it was taken: DATE_TAKEN when it agrees with DATE_ADDED (EXIF can carry a wrong zone), else DATE_ADDED. */
    val timeMillis: Long
        get() {
            val added = dateAddedSeconds * 1000
            return when {
                added <= 0 -> dateTakenMillis
                dateTakenMillis > 0 && abs(dateTakenMillis - added) <= DATE_TAKEN_AGREEMENT_MILLIS -> dateTakenMillis
                else -> added
            }
        }

    /** Written: not pending and has bytes. */
    val ready: Boolean get() = !pending && size > 0
}

/**
 * Screenshots folders: DCIM/Screenshots, Pictures/Screenshots (OxygenOS uses either), any path
 * segment or bucket named "Screenshots", matched case-insensitively.
 */
internal fun isScreenshotsFolder(relativePath: String?, bucket: String?, dataPath: String?): Boolean {
    fun segments(path: String?) = path.orEmpty().split('/', '\\').filter(String::isNotEmpty)
    if (bucket?.trim()?.equals(SCREENSHOTS, ignoreCase = true) == true) return true
    if (segments(relativePath).any { it.equals(SCREENSHOTS, ignoreCase = true) }) return true
    // DATA ends with the file name: only its folders count.
    return segments(dataPath).dropLast(1).any { it.equals(SCREENSHOTS, ignoreCase = true) }
}

private const val SCREENSHOTS = "Screenshots"

internal sealed interface ScreenshotPick {
    /** Send the clipboard as before. */
    data object None : ScreenshotPick

    /** Send this screenshot. */
    data class Ready(val row: ScreenshotRow) : ScreenshotPick

    /** This screenshot qualifies but is still being written: wait for it. */
    data class Writing(val row: ScreenshotRow) : ScreenshotPick
}

/**
 * The newest screenshot, when it was taken within [windowMillis] of [nowMillis], after the clip
 * on the clipboard ([clipTimestampMillis], 0 when the clipboard is empty), and is not [lastSentId].
 * Only the newest screenshot is considered: an older one is never sent because the newest was.
 */
internal fun pickFreshScreenshot(
    rows: List<ScreenshotRow>,
    nowMillis: Long,
    clipTimestampMillis: Long,
    lastSentId: Long?,
    windowMillis: Long = FRESH_SCREENSHOT_WINDOW_MILLIS,
): ScreenshotPick {
    val newest = rows.filter { it.inScreenshotsFolder }
        .maxWithOrNull(compareBy<ScreenshotRow>({ it.timeMillis }, { it.id })) ?: return ScreenshotPick.None
    if (newest.id == lastSentId) return ScreenshotPick.None
    val age = nowMillis - newest.timeMillis
    if (age !in -SCREENSHOT_CLOCK_SKEW_MILLIS..windowMillis) return ScreenshotPick.None
    if (clipTimestampMillis > 0 && newest.timeMillis <= clipTimestampMillis) return ScreenshotPick.None
    return if (newest.ready) ScreenshotPick.Ready(newest) else ScreenshotPick.Writing(newest)
}

/** Where screenshots are listed: MediaStore on the phone, a fake in tests. */
internal interface ScreenshotSource {
    /** Images added at or after [sinceMillis], pending ones included where the platform shows them. */
    fun recentImages(sinceMillis: Long): List<ScreenshotRow>

    /** The row for [id] now, or null when it is gone. */
    fun image(id: Long): ScreenshotRow?
}

/** Finds the screenshot to send, waiting up to [SCREENSHOT_WRITE_WAIT_MILLIS] for one still being written. */
internal class FreshScreenshotFinder(
    private val source: ScreenshotSource,
    private val now: () -> Long = System::currentTimeMillis,
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    suspend fun find(clipTimestampMillis: Long, lastSentId: Long?): ScreenshotRow? {
        val start = now()
        val rows = runCatching { source.recentImages(start - FRESH_SCREENSHOT_WINDOW_MILLIS - SCREENSHOT_CLOCK_SKEW_MILLIS) }
            .getOrDefault(emptyList())
        return when (val pick = pickFreshScreenshot(rows, start, clipTimestampMillis, lastSentId)) {
            ScreenshotPick.None -> null
            is ScreenshotPick.Ready -> pick.row
            is ScreenshotPick.Writing -> {
                var waited = 0L
                while (waited < SCREENSHOT_WRITE_WAIT_MILLIS) {
                    sleep(SCREENSHOT_POLL_MILLIS)
                    waited += SCREENSHOT_POLL_MILLIS
                    val row = runCatching { source.image(pick.row.id) }.getOrNull() ?: return null
                    if (row.ready) return row
                }
                null
            }
        }
    }
}

/** The screenshot as a clip for the clipboard-files offer path, so it pastes on the Mac as an image. */
internal fun ScreenshotRow.asClip(): LocalClip.Items {
    val mime = mime?.takeIf { validMime(it) && it.startsWith("image/", ignoreCase = true) } ?: "image/png"
    val uri = imageUri(id).toString()
    return LocalClip.Items(listOf(LocalClipItem(uri, mime, name, size)), sensitive = false)
}

private fun imageUri(id: Long): Uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)

/** Photo access for Send a fresh screenshot: Android 14+ can grant selected photos only. */
enum class PhotoAccess { FULL, PARTIAL, NONE }

internal object PhotoPermissions {
    /** What to ask for. On 14+ the selected-photos permission is declared too, so partial access is reported, not hidden. */
    val request: Array<String>
        get() = when {
            Build.VERSION.SDK_INT >= 34 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
            Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
            else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    /** The permission whose rationale flag tells a first "Don't allow" from "don't ask again". */
    val main: String
        get() = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE

    fun access(context: Context): PhotoAccess {
        fun granted(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        return when {
            granted(main) -> PhotoAccess.FULL
            Build.VERSION.SDK_INT >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> PhotoAccess.PARTIAL
            else -> PhotoAccess.NONE
        }
    }
}

/** MediaStore images, newest first; pending rows included on Android 11+ where the provider shows them. */
internal class MediaStoreScreenshotSource(private val resolver: ContentResolver) : ScreenshotSource {
    private val collection: Uri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI

    private val projection: Array<String> = buildList {
        add(MediaStore.Images.Media._ID)
        add(MediaStore.Images.Media.DATE_ADDED)
        add(MediaStore.Images.Media.DATE_TAKEN)
        add(MediaStore.Images.Media.SIZE)
        add(MediaStore.Images.Media.MIME_TYPE)
        add(MediaStore.Images.Media.DISPLAY_NAME)
        add(MediaStore.Images.Media.BUCKET_DISPLAY_NAME)
        if (Build.VERSION.SDK_INT >= 29) {
            add(MediaStore.Images.Media.RELATIVE_PATH)
            add(MediaStore.Images.Media.IS_PENDING)
        } else {
            @Suppress("DEPRECATION")
            add(MediaStore.Images.Media.DATA)
        }
    }.toTypedArray()

    override fun recentImages(sinceMillis: Long): List<ScreenshotRow> =
        query("${MediaStore.Images.Media.DATE_ADDED} >= ?", arrayOf((sinceMillis / 1000).toString()), limit = 20)

    override fun image(id: Long): ScreenshotRow? =
        query("${MediaStore.Images.Media._ID} = ?", arrayOf(id.toString()), limit = 1).firstOrNull()

    private fun query(selection: String, args: Array<String>, limit: Int): List<ScreenshotRow> {
        val order = "${MediaStore.Images.Media.DATE_ADDED} DESC, ${MediaStore.Images.Media._ID} DESC"
        val cursor = if (Build.VERSION.SDK_INT >= 30) {
            resolver.query(
                collection,
                projection,
                Bundle().apply {
                    putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                    putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args)
                    putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, order)
                    putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
                    putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
                },
                null,
            )
        } else {
            @Suppress("DEPRECATION")
            val uri = if (Build.VERSION.SDK_INT == 29) MediaStore.setIncludePending(collection) else collection
            resolver.query(uri, projection, selection, args, order)
        }
        return cursor?.use { c -> buildList { while (c.moveToNext() && size < limit) add(c.row()) } }.orEmpty()
    }

    private fun Cursor.row(): ScreenshotRow {
        fun long(column: String): Long = getColumnIndex(column).takeIf { it >= 0 && !isNull(it) }?.let { getLong(it) } ?: 0L
        fun string(column: String): String? = getColumnIndex(column).takeIf { it >= 0 && !isNull(it) }?.let { getString(it) }
        @Suppress("DEPRECATION")
        val data = if (Build.VERSION.SDK_INT < 29) string(MediaStore.Images.Media.DATA) else null
        return ScreenshotRow(
            id = long(MediaStore.Images.Media._ID),
            relativePath = if (Build.VERSION.SDK_INT >= 29) string(MediaStore.Images.Media.RELATIVE_PATH) else null,
            bucket = string(MediaStore.Images.Media.BUCKET_DISPLAY_NAME),
            dataPath = data,
            dateAddedSeconds = long(MediaStore.Images.Media.DATE_ADDED),
            dateTakenMillis = long(MediaStore.Images.Media.DATE_TAKEN),
            size = long(MediaStore.Images.Media.SIZE),
            pending = Build.VERSION.SDK_INT >= 29 && long(MediaStore.Images.Media.IS_PENDING) != 0L,
            mime = string(MediaStore.Images.Media.MIME_TYPE),
            name = string(MediaStore.Images.Media.DISPLAY_NAME),
        )
    }
}

/**
 * Send a fresh screenshot on this phone: whether it can run now, the finder, and the last screenshot
 * sent (kept across restarts, so the same screenshot never goes twice).
 */
internal class FreshScreenshots(
    private val context: Context,
    private val enabled: () -> Boolean,
    private val finder: FreshScreenshotFinder = FreshScreenshotFinder(MediaStoreScreenshotSource(context.contentResolver)),
) {
    private val preferences = context.getSharedPreferences("bridgey.screenshot", Context.MODE_PRIVATE)

    /** The setting is on and Bridgey can see every photo. */
    fun active(): Boolean = enabled() && PhotoPermissions.access(context) == PhotoAccess.FULL

    suspend fun find(clipTimestampMillis: Long): ScreenshotRow? = finder.find(clipTimestampMillis, lastSentId())

    @Synchronized fun lastSentId(): Long? = preferences.getLong(KEY_LAST_SENT, -1L).takeIf { it >= 0 }

    /** Remembered as soon as the send starts, so a second tap does not send it again. */
    @Synchronized fun markSent(id: Long) = preferences.edit().putLong(KEY_LAST_SENT, id).apply()

    /** The send did not go out: a later tap may try this screenshot again. */
    @Synchronized fun unmarkSent(id: Long) {
        if (lastSentId() == id) preferences.edit().remove(KEY_LAST_SENT).apply()
    }

    private companion object {
        const val KEY_LAST_SENT = "last_sent_id"
    }
}

/** The clip's own time ([android.content.ClipDescription.getTimestamp]); 0 when the clipboard is empty. */
internal fun readClipTimestamp(context: Context): Long = runCatching {
    context.getSystemService(android.content.ClipboardManager::class.java).primaryClipDescription?.timestamp ?: 0L
}.getOrDefault(0L)
