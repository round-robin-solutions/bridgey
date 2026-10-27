package dev.bridgey.android.browse

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Point
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.provider.DocumentsContract
import android.util.Size
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.roundToInt

/** When a ready-made thumbnail is too small to use for the size asked. */
object ThumbnailFit {
    /** Its longest edge is under three quarters of the asked size (a picture smaller than that decodes to the same). */
    fun tooSmall(longest: Int, size: Int): Boolean = longest * 4 < size * 3
}

/**
 * Thumbnails and previews on the phone: MediaStore's own thumbnail cache (ContentResolver.loadThumbnail) for
 * MediaStore items, the provider's thumbnails (DocumentsContract.getDocumentThumbnail) for SAF documents that
 * support them, else a sampled decode for images and a scaled frame for videos. Encoded as WebP (Android 11
 * and later) or JPEG, quality and then size lowered until it fits the byte budget.
 */
class AndroidThumbnails(private val resolver: ContentResolver, private val context: android.content.Context) : ThumbnailMaker {
    private companion object {
        /** Formats that can be transparent; anything else never pays for the header read. */
        val ALPHA_TYPES = setOf("image/png", "image/webp", "image/gif")
    }

    override fun make(source: ThumbSource, size: Int, maxBytes: Int, preview: Boolean, cancel: CancelFlag): EncodedImage? {
        if (cancel.cancelled) return null
        val signal = CancellationSignal()
        cancel.onCancel { runCatching(signal::cancel) }
        val bitmap = runCatching { load(source, size, preview, signal) }.getOrNull() ?: return null
        return try {
            if (cancel.cancelled) null else encode(fit(bitmap, size), maxBytes)
        } finally {
            if (!bitmap.isRecycled) bitmap.recycle()
        }
    }

    private fun load(source: ThumbSource, size: Int, preview: Boolean, signal: CancellationSignal): Bitmap? {
        val uri = Uri.parse(source.uri)
        // Previews of images decode the original (a provider thumbnail is often small); thumbnails use the caches.
        if (preview && source.isImage) decodeImage(uri, size)?.let { return it }
        // A picture that may be transparent (a sticker, a logo): MediaStore's thumbnail is a JPEG and would make the
        // transparent parts black, so decode it here and send WebP, which keeps them (JPEG before Android 11 cannot).
        if (source.isImage && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && mayHaveAlpha(uri, source.mimeType)) {
            decodeImage(uri, size)?.let { return it }
        }
        if (source.kind == ThumbSource.Kind.MEDIA_STORE && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && source.providerThumbnail) {
            val cached = runCatching { resolver.loadThumbnail(uri, Size(size, size), signal) }.getOrNull()
            // MediaStore hands back a photo's embedded EXIF thumbnail as it is (160 x 120 from many cameras)
            // whatever size is asked: decode the picture instead, and keep the cached one if that fails.
            if (cached != null && !ThumbnailFit.tooSmall(max(cached.width, cached.height), size)) return cached
            val decoded = if (source.isImage) decodeImage(uri, size) else if (source.isVideo) videoFrame(uri, size) else null
            if (decoded != null && (cached == null || max(decoded.width, decoded.height) > max(cached.width, cached.height))) {
                cached?.recycle()
                return decoded
            }
            decoded?.recycle()
            if (cached != null) return cached
        }
        if (source.kind == ThumbSource.Kind.DOCUMENT && source.providerThumbnail) {
            runCatching { DocumentsContract.getDocumentThumbnail(resolver, uri, Point(size, size), signal) }.getOrNull()?.let { return it }
        }
        if (source.isImage) return decodeImage(uri, size)
        if (source.isVideo) return videoFrame(uri, size)
        return null
    }

    private fun decodeImage(uri: Uri, size: Int): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return runCatching {
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
                    val longest = max(info.size.width, info.size.height).coerceAtLeast(1)
                    if (longest > size) {
                        val scale = size.toFloat() / longest
                        decoder.setTargetSize((info.size.width * scale).roundToInt().coerceAtLeast(1), (info.size.height * scale).roundToInt().coerceAtLeast(1))
                    }
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }
            }.getOrNull()
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        val longest = max(bounds.outWidth, bounds.outHeight)
        if (longest <= 0) return null
        var sample = 1
        while (longest / (sample * 2) >= size) sample *= 2
        return resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
    }

    private fun mayHaveAlpha(uri: Uri, mimeType: String?): Boolean {
        if (mimeType != null && mimeType !in ALPHA_TYPES) return false
        val header = runCatching {
            resolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(ImageAlpha.HEADER_BYTES)
                var count = 0
                while (count < buffer.size) {
                    val read = input.read(buffer, count, buffer.size - count)
                    if (read < 0) break
                    count += read
                }
                buffer.copyOf(count)
            }
        }.getOrNull() ?: return false
        return ImageAlpha.mayHaveAlpha(header, mimeType)
    }

    private fun videoFrame(uri: Uri, size: Int): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                retriever.getScaledFrameAtTime(1_000_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, size, size)
            } else {
                retriever.getFrameAtTime(1_000_000)
            }
        } catch (_: Exception) {
            null
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun fit(bitmap: Bitmap, size: Int): Bitmap {
        val longest = max(bitmap.width, bitmap.height)
        if (longest <= size) return bitmap
        val scale = size.toFloat() / longest
        return Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).roundToInt().coerceAtLeast(1), (bitmap.height * scale).roundToInt().coerceAtLeast(1), true)
    }

    private fun encode(original: Bitmap, maxBytes: Int): EncodedImage? {
        val tint = runCatching {
            val pixel = Bitmap.createScaledBitmap(original, 1, 1, true)
            pixel.getPixel(0, 0).also { if (pixel !== original) pixel.recycle() } and 0xffffff
        }.getOrNull()
        val format = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Bitmap.CompressFormat.WEBP_LOSSY else Bitmap.CompressFormat.JPEG
        val mime = if (format == Bitmap.CompressFormat.JPEG) "image/jpeg" else "image/webp"
        var bitmap = original
        repeat(5) {
            for (quality in intArrayOf(80, 70, 60, 50, 40)) {
                val out = ByteArrayOutputStream(maxBytes.coerceAtMost(64 * 1024))
                if (!bitmap.compress(format, quality, out)) return null
                if (out.size() <= maxBytes) {
                    val result = EncodedImage(out.toByteArray(), mime, bitmap.width, bitmap.height, tint)
                    if (bitmap !== original) bitmap.recycle()
                    return result
                }
            }
            val smaller = Bitmap.createScaledBitmap(bitmap, (bitmap.width * 0.75f).roundToInt().coerceAtLeast(1), (bitmap.height * 0.75f).roundToInt().coerceAtLeast(1), true)
            if (bitmap !== original) bitmap.recycle()
            bitmap = smaller
        }
        if (bitmap !== original) bitmap.recycle()
        return null
    }
}
