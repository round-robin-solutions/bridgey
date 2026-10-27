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

/**
 * Whether a picture may have transparent pixels, from the first bytes of its file. MediaStore's ready-made
 * thumbnails are JPEGs, so a sticker's transparent background came out black in the Mac's grid; pictures that
 * may have alpha are decoded directly instead (and sent as WebP, which keeps it). Pure, so it is tested on the JVM.
 */
object ImageAlpha {
    /** Bytes read from the start of the file: PNG's tRNS chunk comes before the image data. */
    const val HEADER_BYTES = 4096

    fun mayHaveAlpha(header: ByteArray, mimeType: String?): Boolean = when {
        isPng(header) -> pngAlpha(header)
        isWebp(header) -> webpAlpha(header)
        mimeType == "image/gif" || isGif(header) -> true
        else -> false
    }

    private fun isPng(bytes: ByteArray) = bytes.size >= 26 && bytes[0] == 0x89.toByte() && bytes[1] == 'P'.code.toByte() &&
        bytes[2] == 'N'.code.toByte() && bytes[3] == 'G'.code.toByte()

    private fun isWebp(bytes: ByteArray) = bytes.size >= 16 && text(bytes, 0, 4) == "RIFF" && text(bytes, 8, 4) == "WEBP"

    private fun isGif(bytes: ByteArray) = bytes.size >= 6 && text(bytes, 0, 4) == "GIF8"

    private fun text(bytes: ByteArray, at: Int, count: Int): String =
        if (at + count > bytes.size) "" else String(bytes, at, count, Charsets.ISO_8859_1)

    private fun int32(bytes: ByteArray, at: Int): Int =
        ((bytes[at].toInt() and 0xff) shl 24) or ((bytes[at + 1].toInt() and 0xff) shl 16) or
            ((bytes[at + 2].toInt() and 0xff) shl 8) or (bytes[at + 3].toInt() and 0xff)

    /** Grey or RGB with alpha (colour types 4 and 6), or a tRNS chunk before IDAT (palette or one clear colour). */
    private fun pngAlpha(bytes: ByteArray): Boolean {
        val colourType = bytes[25].toInt() and 0xff
        if (colourType == 4 || colourType == 6) return true
        var at = 8
        while (at + 8 <= bytes.size) {
            val length = int32(bytes, at)
            when (text(bytes, at + 4, 4)) {
                "tRNS" -> return true
                "IDAT", "IEND" -> return false
            }
            // A damaged length ends the search; never an index past the header.
            val next = at.toLong() + 12 + length.toLong()
            if (length < 0 || next > bytes.size) return false
            at = next.toInt()
        }
        return false
    }

    /** VP8X carries an alpha flag; lossless VP8L an alpha hint; plain lossy VP8 has none. */
    private fun webpAlpha(bytes: ByteArray): Boolean = when (text(bytes, 12, 4)) {
        "VP8X" -> bytes.size > 20 && (bytes[20].toInt() and 0x10) != 0
        "VP8L" -> bytes.size > 24 && (bytes[24].toInt() and 0x10) != 0
        else -> false
    }
}
