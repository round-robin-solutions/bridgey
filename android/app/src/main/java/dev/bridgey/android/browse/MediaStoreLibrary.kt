package dev.bridgey.android.browse

import android.Manifest
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Photos and videos from MediaStore (the Files collection filtered to images and videos), newest first by
 * DATE_TAKEN, else DATE_ADDED. Read with READ_MEDIA_IMAGES and READ_MEDIA_VIDEO (Android 13+), the user's
 * selection (READ_MEDIA_VISUAL_USER_SELECTED, Android 14+) or READ_EXTERNAL_STORAGE (up to Android 12).
 * Content URIs stay on the phone; names and URIs are never logged.
 */
class MediaStoreLibrary(context: Context) : MediaLibrary {
    private val appContext = context.applicationContext
    private val resolver: ContentResolver = appContext.contentResolver
    private val counter = AtomicLong(0)
    private val mutableGeneration = MutableStateFlow(0L)
    private val observing = AtomicBoolean(false)

    /** Bumps on every MediaStore change, for the attach sheet to reload. */
    val generations: StateFlow<Long> = mutableGeneration.asStateFlow()

    override val generation: Long get() {
        observe()
        return counter.get()
    }

    override fun access(): MediaAccess = MediaAccessRules.access(Build.VERSION.SDK_INT) { permission ->
        appContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    override fun page(offset: Int, limit: Int): List<MediaItem> {
        if (access() == MediaAccess.NONE || limit <= 0) return emptyList()
        observe()
        return query(MediaQuery.SELECTION, null, offset.coerceAtLeast(0), limit.coerceAtMost(MediaQuery.MAX_PAGE))
    }

    override fun item(mediaId: Long): MediaItem? {
        if (access() == MediaAccess.NONE || mediaId < 0) return null
        return query("${MediaQuery.SELECTION} AND ${MediaStore.MediaColumns._ID} = ?", arrayOf(mediaId.toString()), 0, 1).firstOrNull()
    }

    override fun open(mediaId: Long): InputStream? {
        val item = item(mediaId) ?: return null
        return try {
            resolver.openInputStream(Uri.parse(item.uri))
        } catch (error: SecurityException) {
            throw IOException(error)
        }
    }

    private fun query(selection: String, args: Array<String>?, offset: Int, limit: Int): List<MediaItem> {
        val collection = MediaStore.Files.getContentUri("external")
        val cursor = try {
            if (Build.VERSION.SDK_INT >= 30) {
                val bundle = Bundle().apply {
                    putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                    if (args != null) putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args)
                    putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, MediaQuery.SORT)
                    putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
                    putInt(ContentResolver.QUERY_ARG_OFFSET, offset)
                }
                resolver.query(collection, MediaQuery.projection, bundle, null)
            } else {
                // Android 10 and older accept LIMIT inside the sort order.
                resolver.query(collection, MediaQuery.projection, selection, args, "${MediaQuery.SORT} LIMIT $limit OFFSET $offset")
            }
        } catch (error: SecurityException) {
            null
        } ?: return emptyList()
        return cursor.use { rows -> MediaQuery.read(rows) }
    }

    /** One observer for the process, registered on first use. */
    private fun observe() {
        if (!observing.compareAndSet(false, true)) return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                mutableGeneration.value = counter.incrementAndGet()
            }
        }
        runCatching { resolver.registerContentObserver(MediaStore.Files.getContentUri("external"), true, observer) }
            .onFailure { observing.set(false) }
    }
}

/** Which permissions give which access; pure, so every Android version is tested on the JVM. */
object MediaAccessRules {
    /** What the attach sheet asks for, once and inline. */
    fun request(sdk: Int): Array<String> = when {
        sdk >= 34 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        sdk >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    /**
     * Partial only means the photos the person chose (Android 14+: READ_MEDIA_VISUAL_USER_SELECTED without
     * READ_MEDIA_IMAGES), since the Mac and the attach sheet then say "Showing the photos you chose". All
     * photos (READ_MEDIA_IMAGES, as Send a fresh screenshot asks for) is full even before videos are allowed.
     */
    fun access(sdk: Int, granted: (String) -> Boolean): MediaAccess = when {
        sdk < 33 -> if (granted(Manifest.permission.READ_EXTERNAL_STORAGE)) MediaAccess.FULL else MediaAccess.NONE
        granted(Manifest.permission.READ_MEDIA_IMAGES) -> MediaAccess.FULL
        sdk >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> MediaAccess.PARTIAL
        granted(Manifest.permission.READ_MEDIA_VIDEO) -> MediaAccess.FULL
        else -> MediaAccess.NONE
    }

    /** Everything Files needs: all photos and all videos (setup keeps asking until both are allowed). */
    fun complete(sdk: Int, granted: (String) -> Boolean): Boolean = when {
        sdk < 33 -> granted(Manifest.permission.READ_EXTERNAL_STORAGE)
        else -> granted(Manifest.permission.READ_MEDIA_IMAGES) && granted(Manifest.permission.READ_MEDIA_VIDEO)
    }
}

/** The MediaStore query and its row mapping, apart from the resolver so it is tested with a MatrixCursor. */
object MediaQuery {
    const val MAX_PAGE = 500

    private const val TYPE_IMAGE = MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE
    private const val TYPE_VIDEO = MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO

    val SELECTION = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN ($TYPE_IMAGE, $TYPE_VIDEO) AND ${MediaStore.MediaColumns.SIZE} > 0"

    /** Newest first: date taken (ms), else date added (s) in ms; the ID breaks ties so pages never overlap. */
    val SORT = "COALESCE(${MediaStore.MediaColumns.DATE_TAKEN}, ${MediaStore.MediaColumns.DATE_ADDED} * 1000) DESC, ${MediaStore.MediaColumns._ID} DESC"

    val projection: Array<String> = arrayOf(
        MediaStore.MediaColumns._ID,
        MediaStore.MediaColumns.DISPLAY_NAME,
        MediaStore.MediaColumns.SIZE,
        MediaStore.MediaColumns.DATE_MODIFIED,
        MediaStore.MediaColumns.DATE_TAKEN,
        MediaStore.MediaColumns.DATE_ADDED,
        MediaStore.MediaColumns.MIME_TYPE,
        MediaStore.MediaColumns.WIDTH,
        MediaStore.MediaColumns.HEIGHT,
        MediaStore.MediaColumns.DURATION,
        MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
        MediaStore.Files.FileColumns.MEDIA_TYPE,
    )

    fun read(cursor: Cursor): List<MediaItem> {
        fun index(column: String) = cursor.getColumnIndex(column)
        val id = index(MediaStore.MediaColumns._ID)
        val name = index(MediaStore.MediaColumns.DISPLAY_NAME)
        val size = index(MediaStore.MediaColumns.SIZE)
        val modified = index(MediaStore.MediaColumns.DATE_MODIFIED)
        val taken = index(MediaStore.MediaColumns.DATE_TAKEN)
        val added = index(MediaStore.MediaColumns.DATE_ADDED)
        val mime = index(MediaStore.MediaColumns.MIME_TYPE)
        val width = index(MediaStore.MediaColumns.WIDTH)
        val height = index(MediaStore.MediaColumns.HEIGHT)
        val duration = index(MediaStore.MediaColumns.DURATION)
        val bucket = index(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
        val type = index(MediaStore.Files.FileColumns.MEDIA_TYPE)
        fun long(column: Int): Long? = if (column < 0 || cursor.isNull(column)) null else cursor.getLong(column)
        fun string(column: Int): String? = if (column < 0 || cursor.isNull(column)) null else cursor.getString(column)
        val result = ArrayList<MediaItem>(cursor.count.coerceAtLeast(0))
        while (cursor.moveToNext()) {
            val mediaId = long(id) ?: continue
            val video = long(type)?.toInt() == TYPE_VIDEO
            val mimeType = string(mime)?.takeIf { it.contains('/') } ?: if (video) "video/*" else "image/*"
            val addedMillis = (long(added) ?: 0L) * 1000
            val modifiedMillis = long(modified)?.times(1000) ?: addedMillis
            result += MediaItem(
                mediaId = mediaId,
                name = string(name) ?: "",
                size = long(size) ?: 0L,
                modifiedMillis = modifiedMillis,
                sortMillis = long(taken)?.takeIf { it > 0 } ?: addedMillis,
                mimeType = mimeType,
                width = long(width)?.toInt()?.takeIf { it > 0 },
                height = long(height)?.toInt()?.takeIf { it > 0 },
                durationMs = if (video) long(duration)?.takeIf { it > 0 } else null,
                location = string(bucket),
                uri = itemUri(mediaId, video).toString(),
            )
        }
        return result
    }

    /** The typed collection URI (loadThumbnail and openInputStream want it), never the Files one. */
    fun itemUri(mediaId: Long, video: Boolean): Uri =
        ContentUris.withAppendedId(if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI, mediaId)
}
