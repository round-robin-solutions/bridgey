package dev.bridgey.android.ui.attach

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.util.LruCache
import android.util.Size
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import dev.bridgey.android.browse.MediaItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

/**
 * Grid thumbnails for the attach sheet: memory first (instant on reopen and while scrolling back), then
 * MediaStore's own thumbnail cache through loadThumbnail, at most four at a time. The cache key is the media ID
 * plus its modified time and size, so an edited photo never shows its old thumbnail.
 */
interface MediaThumbnails {
    fun cached(item: MediaItem): ImageBitmap?

    suspend fun load(item: MediaItem): ImageBitmap?

    /** Loads the next rows in the background, so they are ready before they scroll in. */
    fun prefetch(items: List<MediaItem>)
}

val LocalMediaThumbnails = staticCompositionLocalOf<MediaThumbnails> { NoMediaThumbnails }

object NoMediaThumbnails : MediaThumbnails {
    override fun cached(item: MediaItem): ImageBitmap? = null
    override suspend fun load(item: MediaItem): ImageBitmap? = null
    override fun prefetch(items: List<MediaItem>) = Unit
}

/** Bounded by bytes: an eighth of the app's heap, at most 48 MiB (about 450 thumbnails of 320 px). */
class ThumbnailMemoryCache(maxBytes: Int = defaultBytes()) {
    private val cache = object : LruCache<String, ImageBitmap>(maxBytes) {
        override fun sizeOf(key: String, value: ImageBitmap): Int = (value.width * value.height * 4).coerceAtLeast(1)
    }

    fun get(key: String): ImageBitmap? = cache.get(key)

    fun put(key: String, value: ImageBitmap) {
        cache.put(key, value)
    }

    val size: Int get() = cache.size()

    companion object {
        fun key(item: MediaItem): String = "${item.mediaId}:${item.modifiedMillis}:${item.size}"

        fun defaultBytes(): Int = (Runtime.getRuntime().maxMemory() / 8).coerceAtMost(48L * 1024 * 1024).toInt()
    }
}

class AndroidMediaThumbnails(
    private val resolver: ContentResolver,
    private val cache: ThumbnailMemoryCache = ThumbnailMemoryCache(),
    private val edge: Int = EDGE,
) : MediaThumbnails {
    private val gate = Semaphore(4)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val prefetching = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<String, Boolean>())

    override fun cached(item: MediaItem): ImageBitmap? = cache.get(ThumbnailMemoryCache.key(item))

    override suspend fun load(item: MediaItem): ImageBitmap? {
        val key = ThumbnailMemoryCache.key(item)
        cache.get(key)?.let { return it }
        return withContext(Dispatchers.IO) {
            gate.withPermit {
                cache.get(key) ?: decode(item)?.also { cache.put(key, it) }
            }
        }
    }

    override fun prefetch(items: List<MediaItem>) {
        items.forEach { item ->
            val key = ThumbnailMemoryCache.key(item)
            if (cache.get(key) != null || !prefetching.add(key)) return@forEach
            scope.launch {
                try {
                    load(item)
                } finally {
                    prefetching.remove(key)
                }
            }
        }
    }

    private suspend fun decode(item: MediaItem): ImageBitmap? {
        val uri = Uri.parse(item.uri)
        return runCatching {
            if (Build.VERSION.SDK_INT >= 29) {
                suspendCancellableCoroutine { continuation ->
                    val signal = CancellationSignal()
                    continuation.invokeOnCancellation { signal.cancel() }
                    val bitmap = runCatching { resolver.loadThumbnail(uri, Size(edge, edge), signal) }.getOrNull()
                    continuation.resume(bitmap?.asImageBitmap())
                }
            } else {
                coroutineContextCheck()
                legacy(uri)?.asImageBitmap()
            }
        }.getOrNull()
    }

    private suspend fun coroutineContextCheck() = kotlin.coroutines.coroutineContext.ensureActive()

    /** Android 9 and older: decode a sampled copy (videos show their placeholder). */
    private fun legacy(uri: Uri): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) } ?: return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= edge && bounds.outHeight / (sample * 2) >= edge) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        return resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
    }

    companion object {
        /** A third of a 412 dp screen at 3x is about 400 px; 320 keeps the cache small and still looks sharp. */
        const val EDGE = 320
    }
}
