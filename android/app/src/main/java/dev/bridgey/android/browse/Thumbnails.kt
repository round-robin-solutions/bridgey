package dev.bridgey.android.browse

import java.util.concurrent.CopyOnWriteArrayList

/** Where a thumbnail or preview comes from (resolved by the server, never sent to the other device). */
data class ThumbSource(
    /** content:// URI of the item. */
    val uri: String,
    val mimeType: String?,
    val kind: Kind,
    /** The provider makes thumbnails itself (SAF FLAG_SUPPORTS_THUMBNAIL, or a MediaStore image or video). */
    val providerThumbnail: Boolean,
) {
    enum class Kind { MEDIA_STORE, DOCUMENT }

    val isImage: Boolean get() = mimeType?.startsWith("image/") == true
    val isVideo: Boolean get() = mimeType?.startsWith("video/") == true
}

/** Encoded image bytes as they go on the wire. */
class EncodedImage(val bytes: ByteArray, val mimeType: String, val width: Int, val height: Int, val tint: Int?)

/** A cancel flag that storage calls can listen to (Android bridges it to a CancellationSignal). */
class CancelFlag {
    @Volatile var cancelled = false
        private set
    private val listeners = CopyOnWriteArrayList<() -> Unit>()

    fun cancel() {
        if (cancelled) return
        cancelled = true
        listeners.forEach { runCatching(it) }
    }

    fun onCancel(listener: () -> Unit) {
        listeners += listener
        if (cancelled) runCatching(listener)
    }
}

/**
 * Makes thumbnails and previews: at most [size] pixels on the longest edge and [maxBytes] encoded (quality,
 * then size, drop until it fits). Null when the item has no picture. Blocking; called on the media pool.
 */
interface ThumbnailMaker {
    fun make(source: ThumbSource, size: Int, maxBytes: Int, preview: Boolean, cancel: CancelFlag): EncodedImage?
}

object NoThumbnails : ThumbnailMaker {
    override fun make(source: ThumbSource, size: Int, maxBytes: Int, preview: Boolean, cancel: CancelFlag): EncodedImage? = null
}

/** "#rrggbb" for a packed 0xRRGGBB colour. */
fun tintHex(rgb: Int): String = "#%06x".format(rgb and 0xffffff)
