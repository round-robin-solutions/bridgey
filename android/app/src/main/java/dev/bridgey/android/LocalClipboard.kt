package dev.bridgey.android

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PersistableBundle
import android.provider.OpenableColumns
import java.io.ByteArrayInputStream
import java.io.FileNotFoundException
import java.io.InputStream
import java.util.UUID

/** What is on this phone's clipboard, read while Bridgey may read it (foreground or one tap). */
sealed interface LocalClip {
    val sensitive: Boolean

    data class Text(val text: String, val html: String?, override val sensitive: Boolean) : LocalClip

    /** Images, videos and files: content:// URIs with what their providers report. */
    data class Items(val items: List<LocalClipItem>, override val sensitive: Boolean) : LocalClip

    /** Bridgey put it there itself (a clip from the Mac); never sent back. */
    data object Own : LocalClip {
        override val sensitive: Boolean = false
    }
}

data class LocalClipItem(val uri: String, val mime: String, val name: String?, val size: Long)

/** The authority of the clipboard content provider ([ClipboardContentProvider]). */
internal fun clipboardAuthority(packageName: String) = "$packageName.clipboard"

/** A fingerprint for de-duplication: the text, or the URIs with their sizes (no content is read). */
internal fun LocalClip.hash(): String? = when (this) {
    is LocalClip.Text -> clipboardHash(text)
    is LocalClip.Items -> clipboardHash(items.joinToString("\n") { "${it.uri}\u0000${it.size}\u0000${it.mime}" })
    LocalClip.Own -> null
}

/**
 * Automatic clipboard for any clip. Skip rules as for text: unavailable, empty, sensitive, our own
 * write, a duplicate. Text that fits 32 KiB (text and HTML together) goes as before; larger text,
 * images and files become an offer when [offersAvailable], and otherwise text over the limit is
 * skipped as before.
 */
internal fun autoClipDecision(
    clip: LocalClip?,
    available: Boolean,
    offersAvailable: Boolean,
    lastHash: String?,
): ClipboardAutoDecision {
    if (!available) return ClipboardAutoDecision.SKIP_UNAVAILABLE
    return when (clip) {
        null -> ClipboardAutoDecision.SKIP_EMPTY
        LocalClip.Own -> ClipboardAutoDecision.SKIP_DUPLICATE
        is LocalClip.Text -> when {
            clip.text.isEmpty() -> ClipboardAutoDecision.SKIP_EMPTY
            clip.sensitive -> ClipboardAutoDecision.SKIP_SENSITIVE
            !offersAvailable && !clipboardTextFits(clip.text) -> ClipboardAutoDecision.SKIP_TOO_LARGE
            lastHash != null && lastHash == clip.hash() -> ClipboardAutoDecision.SKIP_DUPLICATE
            !offersAvailable || textFitsLegacy(clip.text, clip.html) -> ClipboardAutoDecision.SEND
            else -> ClipboardAutoDecision.SEND_OFFER
        }
        is LocalClip.Items -> when {
            clip.items.isEmpty() -> ClipboardAutoDecision.SKIP_EMPTY
            clip.sensitive -> ClipboardAutoDecision.SKIP_SENSITIVE
            !offersAvailable -> ClipboardAutoDecision.SKIP_UNAVAILABLE
            lastHash != null && lastHash == clip.hash() -> ClipboardAutoDecision.SKIP_DUPLICATE
            else -> ClipboardAutoDecision.SEND_OFFER
        }
    }
}

/** True when the text (with its HTML, if any) fits the 32 KiB clipboard.update/clipboard.rich limit. */
internal fun textFitsLegacy(text: String, html: String?): Boolean {
    if (text.isEmpty()) return false
    val htmlBytes = html?.takeIf(String::isNotBlank)?.toByteArray(Charsets.UTF_8)?.size ?: 0
    return text.toByteArray(Charsets.UTF_8).size + htmlBytes <= MAX_CLIPBOARD_CONTENT_BYTES
}

/** An offer for [clip], with where each item's bytes come from. Null when nothing can be offered. */
internal fun buildClipOffer(
    clip: LocalClip,
    offerId: String = UUID.randomUUID().toString(),
    now: Long = System.currentTimeMillis(),
): Pair<ClipOffer, List<ClipSource>>? {
    val pairs: List<Pair<ClipOfferItem, ClipSource>> = when (clip) {
        is LocalClip.Text -> {
            val text = clip.text.toByteArray(Charsets.UTF_8)
            val html = clip.html?.takeIf(String::isNotBlank)?.toByteArray(Charsets.UTF_8)
            var inlineBudget = ClipLimits.MAX_INLINE_TOTAL_BYTES.toLong()
            listOfNotNull(text.let { "text/plain" to it }, html?.let { "text/html" to it }).mapIndexed { index, (mime, bytes) ->
                val inline = bytes.takeIf { it.size <= inlineBudget }?.also { inlineBudget -= it.size }
                ClipOfferItem(
                    index, if (index == 0) ClipItemKind.TEXT else ClipItemKind.HTML, mime, null,
                    bytes.size.toLong(), sha256Base64(bytes), inline,
                ) to ClipSource.Bytes(bytes)
            }
        }
        is LocalClip.Items -> clip.items.filter { it.size in 0..ClipLimits.MAX_ITEM_SIZE }.take(ClipLimits.MAX_ITEMS).mapIndexed { index, item ->
            val image = item.mime.startsWith("image/", ignoreCase = true)
            val name = if (image) null else sanitizeClipName(item.name ?: "") ?: "file"
            ClipOfferItem(index, if (image) ClipItemKind.IMAGE else ClipItemKind.FILE, item.mime.take(ClipLimits.MAX_MIME_LENGTH), name, item.size, null, null) to
                ClipSource.Content(item.uri, item.size)
        }
        LocalClip.Own -> emptyList()
    }
    if (pairs.isEmpty()) return null
    val offer = fitOffer(ClipOffer(offerId, now, clip.sensitive, pairs.map { it.first })) ?: return null
    return offer to pairs.take(offer.items.size).map { it.second }
}

/**
 * Reads the primary clip. [offersAvailable] false keeps today's path exactly: item 0 coerced to
 * text. Our own clips (from the Mac) are recognised by the provider authority and never re-sent.
 */
internal fun readLocalClip(context: Context, offersAvailable: Boolean, includeHtml: Boolean): LocalClip? {
    val clipboard = context.getSystemService(ClipboardManager::class.java)
    val clip = clipboard.primaryClip?.takeIf { it.itemCount > 0 } ?: return null
    val description = clipboard.primaryClipDescription ?: clip.description
    val sensitive = description.isMarkedSensitive()
    val authority = clipboardAuthority(context.packageName)
    val uris = (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }.filter { it.scheme == ContentResolver.SCHEME_CONTENT }
    if (uris.any { it.authority == authority }) return LocalClip.Own
    val first = clip.getItemAt(0)
    if (!offersAvailable || uris.isEmpty()) {
        val text = runCatching { first.coerceToText(context)?.toString() }.getOrNull()?.takeIf(String::isNotEmpty) ?: return null
        return LocalClip.Text(text, if (includeHtml) first.htmlText else null, sensitive)
    }
    val resolver = context.contentResolver
    val items = uris.take(ClipLimits.MAX_ITEMS).mapNotNull { uri -> describeUri(resolver, uri, description) }
    return LocalClip.Items(items, sensitive).takeIf { items.isNotEmpty() }
}

private fun describeUri(resolver: ContentResolver, uri: Uri, description: ClipDescription?): LocalClipItem? = runCatching {
    // Keep access past this foreground moment when the provider allows it; most clipboard grants
    // last until the clip changes anyway.
    runCatching { resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
    var name: String? = null
    var size = -1L
    resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) {
            cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 && !cursor.isNull(it) }?.let { name = cursor.getString(it) }
            cursor.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !cursor.isNull(it) }?.let { size = cursor.getLong(it) }
        }
    }
    if (size < 0) size = resolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1
    if (size < 0) return null
    val mime = resolver.getType(uri)?.takeIf(::validMime)
        ?: description?.takeIf { it.mimeTypeCount > 0 }?.getMimeType(0)?.takeIf { validMime(it) && it != ClipDescription.MIMETYPE_TEXT_URILIST }
        ?: "application/octet-stream"
    LocalClipItem(uri.toString(), mime, name ?: uri.lastPathSegment, size)
}.getOrNull()

/** Reads offered items: text from memory, URIs through the content resolver. */
internal class ContentClipSourceOpener(private val resolver: ContentResolver) : ClipSourceOpener {
    override fun open(source: ClipSource): InputStream = when (source) {
        is ClipSource.Bytes -> ByteArrayInputStream(source.data)
        is ClipSource.Content -> resolver.openInputStream(Uri.parse(source.uri)) ?: throw FileNotFoundException()
    }

    override fun currentSize(source: ClipSource): Long? = when (source) {
        is ClipSource.Bytes -> source.data.size.toLong()
        is ClipSource.Content -> runCatching {
            resolver.query(Uri.parse(source.uri), arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                val column = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (cursor.moveToFirst() && column >= 0 && !cursor.isNull(column)) cursor.getLong(column) else null
            }
        }.getOrElse { if (it is SecurityException) throw it else null }
    }
}

/** Writes clips from the Mac to this phone's clipboard. Allowed from the background. */
internal class AndroidClipWriter(private val context: Context) : ClipWriter {
    private val authority = clipboardAuthority(context.packageName)

    override fun write(clip: IncomingClip): Boolean {
        val data = when (clip) {
            is IncomingClip.Text -> if (clip.html.isNullOrBlank()) {
                ClipData.newPlainText(LABEL, clip.text)
            } else {
                ClipData.newHtmlText(LABEL, clip.text, clip.html)
            }
            is IncomingClip.Items -> {
                val uris = clip.items.map { clipItemUri(authority, clip.offerId, it.index, it.displayName) }
                ClipData(ClipDescription(LABEL, clip.items.map(IncomingClipItem::mime).distinct().toTypedArray()), ClipData.Item(uris.first())).apply {
                    uris.drop(1).forEach { addItem(ClipData.Item(it)) }
                }
            }
        }
        if (Build.VERSION.SDK_INT >= 33) {
            data.description.extras = PersistableBundle().apply {
                if (clip.sensitive) putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                putBoolean(ClipDescription.EXTRA_IS_REMOTE_DEVICE, true)
            }
        }
        return runCatching { context.getSystemService(ClipboardManager::class.java).setPrimaryClip(data) }.isSuccess
    }

    private companion object {
        const val LABEL = "Bridgey"
    }
}

internal fun clipItemUri(authority: String, offerId: String, index: Int, displayName: String): Uri = Uri.Builder()
    .scheme(ContentResolver.SCHEME_CONTENT)
    .authority(authority)
    .appendPath(offerId)
    .appendPath(index.toString())
    .appendPath(displayName)
    .build()
