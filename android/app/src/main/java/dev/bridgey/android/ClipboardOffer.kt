package dev.bridgey.android

import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/*
 * Clipboard offers (draft protocol clipboard_files_draft1, docs/protocol.md): images, files and long
 * text. The other device learns about a copy at once and the data moves when someone pastes; small
 * items are pushed straight away. Everything in this file is pure, so it is unit tested on the JVM.
 */

/** The features.update key both peers must advertise before any of this is used. */
internal const val CLIPBOARD_FILES_FEATURE_KEY = "clipboard_files_draft1"

internal object ClipLimits {
    const val VERSION = 1
    const val MAX_ITEMS = 100
    const val MAX_OFFER_PLAINTEXT_BYTES = 40 * 1024
    const val MAX_INLINE_TOTAL_BYTES = 16 * 1024
    const val MAX_ITEM_SIZE = 10L * 1024 * 1024 * 1024
    const val MAX_NAME_LENGTH = 255
    const val MAX_MIME_LENGTH = 255
    const val CHUNK_SIZE = 24 * 1024

    /**
     * Text up to this size (text and HTML together) is fetched at once and set as plain text.
     * ClipData crosses Binder, whose transaction buffer is 1 MB per process, so 8 MB of text would
     * fail with TransactionTooLargeException; longer text is offered as a .txt URI instead.
     */
    const val TEXT_IN_MEMORY_BYTES = 256 * 1024

    const val FETCH_START_TIMEOUT_MILLIS = 15_000L
    const val STALL_TIMEOUT_MILLIS = 30_000L
    const val ACCEPT_TIMEOUT_MILLIS = 10_000L
    const val COMPLETE_ACK_TIMEOUT_MILLIS = 15_000L
    const val MAX_CONCURRENT_SENDS = 4
    const val BUSY_RETRY_MILLIS = 400L
    const val BUSY_RETRIES = 25

    const val CACHE_MAX_AGE_MILLIS = 24L * 60 * 60 * 1000
    const val CACHE_MAX_BYTES = 2_000_000_000L

    /** Settings > Clipboard > Send right away up to. 0 is "Always ask when pasting". */
    val EAGER_LIMIT_CHOICES = listOf(5_000_000L, 25_000_000L, 100_000_000L, 0L)
    const val DEFAULT_EAGER_LIMIT = 25_000_000L
}

enum class ClipItemKind(val key: String) {
    TEXT("text"), HTML("html"), IMAGE("image"), FILE("file");

    companion object {
        fun fromKey(key: String?): ClipItemKind? = entries.firstOrNull { it.key == key }
    }
}

/** Error codes of clipboard.error. */
internal object ClipErrorCode {
    const val EXPIRED = "expired"
    const val CHANGED = "changed"
    const val TOO_LARGE = "too_large"
    const val UNAVAILABLE = "unavailable"
    const val DISABLED = "disabled"
    const val BUSY = "busy"

    val all = setOf(EXPIRED, CHANGED, TOO_LARGE, UNAVAILABLE, DISABLED, BUSY)

    // Local outcomes, never sent on the wire.
    const val NOT_CONNECTED = "not_connected"
    const val TIMEOUT = "timeout"
    const val CANCELLED = "cancelled"
    const val INVALID = "invalid"
    const val SUPERSEDED = "superseded"
}

class ClipOfferItem(
    val index: Int,
    val kind: ClipItemKind,
    val mime: String,
    val name: String?,
    val size: Long,
    /** Base64 SHA-256, when the sender knows it at offer time. */
    val sha256: String?,
    val inline: ByteArray?,
) {
    fun withoutInline(): ClipOfferItem = ClipOfferItem(index, kind, mime, name, size, sha256, null)

    fun withName(value: String?): ClipOfferItem = ClipOfferItem(index, kind, mime, value, size, sha256, inline)

    fun toJson(includeInline: Boolean = true): JSONObject = JSONObject().apply {
        put("index", index)
        put("kind", kind.key)
        put("mime", mime)
        if (kind == ClipItemKind.FILE && name != null) put("name", name)
        put("size", size)
        sha256?.let { put("sha256", it) }
        if (includeInline) inline?.let { put("inline", Base64.getEncoder().encodeToString(it)) }
    }

    override fun equals(other: Any?): Boolean = other is ClipOfferItem && index == other.index && kind == other.kind &&
        mime == other.mime && name == other.name && size == other.size && sha256 == other.sha256 &&
        (inline?.contentEquals(other.inline ?: return false) ?: (other.inline == null))

    override fun hashCode(): Int = listOf(index, kind, mime, name, size, sha256, inline?.contentHashCode()).hashCode()
}

data class ClipOffer(
    val offerId: String,
    val createdAt: Long,
    val sensitive: Boolean,
    val items: List<ClipOfferItem>,
) {
    val isText: Boolean get() = items.firstOrNull()?.kind == ClipItemKind.TEXT
    val totalSize: Long get() = items.sumOf { it.size }

    fun toJson(includeInline: Boolean = true): JSONObject = JSONObject().apply {
        put("version", ClipLimits.VERSION)
        put("offerId", offerId)
        put("createdAt", createdAt)
        if (sensitive) put("sensitive", true)
        put("items", JSONArray().apply { items.forEach { put(it.toJson(includeInline)) } })
    }

    fun encode(): ByteArray = toJson().toString().toByteArray(Charsets.UTF_8)

    companion object {
        /** Parses and validates a decrypted offer; null when anything is out of bounds. */
        fun decode(bytes: ByteArray): ClipOffer? {
            if (bytes.size > ClipLimits.MAX_OFFER_PLAINTEXT_BYTES) return null
            val json = runCatching { JSONObject(bytes.toString(Charsets.UTF_8)) }.getOrNull() ?: return null
            return fromJson(json)
        }

        fun fromJson(json: JSONObject): ClipOffer? = runCatching {
            if (json.integer("version") != ClipLimits.VERSION.toLong()) return null
            val offerId = json.opt("offerId") as? String ?: return null
            if (!isUuid(offerId)) return null
            val createdAt = json.integer("createdAt")?.takeIf { it >= 0 } ?: return null
            val sensitive = when (val value = json.opt("sensitive")) {
                null -> false
                is Boolean -> value
                else -> return null
            }
            val array = json.opt("items") as? JSONArray ?: return null
            if (array.length() !in 1..ClipLimits.MAX_ITEMS) return null
            var inlineTotal = 0L
            val items = (0 until array.length()).map { position ->
                val item = array.opt(position) as? JSONObject ?: return null
                val parsed = parseItem(item, position) ?: return null
                parsed.inline?.let { inlineTotal += it.size }
                parsed
            }
            if (inlineTotal > ClipLimits.MAX_INLINE_TOTAL_BYTES) return null
            if (!validShape(items)) return null
            ClipOffer(offerId.lowercase(), createdAt, sensitive, items)
        }.getOrNull()

        private fun parseItem(item: JSONObject, position: Int): ClipOfferItem? {
            if (item.integer("index") != position.toLong()) return null
            val kind = ClipItemKind.fromKey(item.opt("kind") as? String) ?: return null
            val mime = item.opt("mime") as? String ?: return null
            if (!validMime(mime)) return null
            val size = item.integer("size")?.takeIf { it in 0..ClipLimits.MAX_ITEM_SIZE } ?: return null
            val name = if (kind == ClipItemKind.FILE) {
                val raw = item.opt("name") as? String ?: return null
                sanitizeClipName(raw)?.takeIf { raw.length <= ClipLimits.MAX_NAME_LENGTH } ?: return null
            } else {
                null
            }
            val sha256 = when (val value = item.opt("sha256")) {
                null -> null
                is String -> value.takeIf { decodeSha(it) != null } ?: return null
                else -> return null
            }
            val inline = when (val value = item.opt("inline")) {
                null -> null
                is String -> {
                    val data = runCatching { Base64.getDecoder().decode(value) }.getOrNull() ?: return null
                    if (data.size.toLong() != size || sha256 == null || sha256Base64(data) != sha256) return null
                    data
                }
                else -> return null
            }
            return ClipOfferItem(position, kind, mime, name, size, sha256, inline)
        }

        /** Text (one text item, optionally then one html item) or one or more images and files. */
        fun validShape(items: List<ClipOfferItem>): Boolean {
            if (items.isEmpty()) return false
            val kinds = items.map(ClipOfferItem::kind)
            return when (kinds.first()) {
                ClipItemKind.TEXT -> kinds == listOf(ClipItemKind.TEXT) || kinds == listOf(ClipItemKind.TEXT, ClipItemKind.HTML)
                ClipItemKind.HTML -> false
                else -> kinds.all { it == ClipItemKind.IMAGE || it == ClipItemKind.FILE }
            }
        }

        private fun JSONObject.integer(key: String): Long? = when (val value = opt(key)) {
            is Int -> value.toLong()
            is Long -> value
            else -> null
        }
    }
}

internal fun isUuid(value: String): Boolean =
    value.length == 36 && runCatching { UUID.fromString(value) }.isSuccess

internal fun validMime(mime: String): Boolean =
    mime.length in 3..ClipLimits.MAX_MIME_LENGTH && mime.none { it.isISOControl() || it.isWhitespace() } &&
        mime.indexOf('/') in 1 until mime.length - 1

/** The last path component, control characters and colons replaced; null when nothing is left. */
internal fun sanitizeClipName(name: String): String? {
    val leaf = name.substringAfterLast('/').substringAfterLast('\\')
        .replace(Regex("[\\u0000-\\u001f:]"), "_")
        .trim()
        .take(ClipLimits.MAX_NAME_LENGTH)
    return leaf.takeIf { it.isNotEmpty() && it != "." && it != ".." }
}

internal fun decodeSha(value: String): ByteArray? =
    runCatching { Base64.getDecoder().decode(value) }.getOrNull()?.takeIf { it.size == 32 }

internal fun sha256Base64(data: ByteArray): String =
    Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(data))

/**
 * The items pushed right after an offer: in index order, skipping any item that would take the
 * total past [limitBytes]. Inline items are already there. A limit of 0 ("Always ask when pasting")
 * pushes nothing.
 */
internal fun eagerIndices(items: List<ClipOfferItem>, limitBytes: Long): List<Int> {
    if (limitBytes <= 0) return emptyList()
    var total = 0L
    return items.filter { item ->
        if (item.inline != null) return@filter false
        if (total + item.size > limitBytes) return@filter false
        total += item.size
        true
    }.map(ClipOfferItem::index)
}

/**
 * Makes an offer fit [ClipLimits.MAX_OFFER_PLAINTEXT_BYTES]: drops inline data, then shortens file
 * names (keeping the extension), then drops trailing items. Returns null when even one item does
 * not fit.
 */
internal fun fitOffer(offer: ClipOffer): ClipOffer? {
    fun fits(candidate: ClipOffer) = candidate.encode().size <= ClipLimits.MAX_OFFER_PLAINTEXT_BYTES
    if (fits(offer)) return offer
    var current = offer.copy(items = offer.items.map(ClipOfferItem::withoutInline))
    if (fits(current)) return current
    current = current.copy(items = current.items.map { it.withName(it.name?.let(::shortName)) })
    if (fits(current)) return current
    var count = current.items.size
    while (count > 1) {
        count -= 1
        val trimmed = current.copy(items = current.items.take(count))
        if (fits(trimmed)) return trimmed
    }
    return null
}

private fun shortName(name: String): String {
    if (name.length <= 64) return name
    val extension = name.substringAfterLast('.', "").takeIf { it.isNotEmpty() && it.length <= 10 }
    return if (extension == null) name.take(64) else name.take(63 - extension.length) + "." + extension
}

/** The mime of an image item, and the file extension Android receivers use for its display name. */
internal fun imageExtension(mime: String): String = when (mime.lowercase()) {
    "image/png" -> "png"
    "image/jpeg", "image/jpg" -> "jpg"
    "image/heic" -> "heic"
    "image/heif" -> "heif"
    "image/gif" -> "gif"
    "image/webp" -> "webp"
    "image/tiff" -> "tiff"
    else -> "img"
}

/** The display name an item has on this phone: the file's name, "image.png", or a .txt for long text. */
internal fun clipDisplayName(item: ClipOfferItem): String = when (item.kind) {
    ClipItemKind.FILE -> item.name ?: "file"
    ClipItemKind.IMAGE -> "image.${imageExtension(item.mime)}"
    ClipItemKind.TEXT -> "Clipboard text.txt"
    ClipItemKind.HTML -> "Clipboard text.html"
}

/** What the activity stream calls an offer: its content kind, count, total size and single name. */
internal data class ClipSummary(val content: String, val count: Int, val bytes: Long, val name: String?)

internal fun ClipOffer.summary(): ClipSummary {
    val content = when {
        isText -> "text"
        items.all { it.kind == ClipItemKind.IMAGE } -> "image"
        else -> "file"
    }
    val count = if (isText) 1 else items.size
    val bytes = if (isText) items.first().size else totalSize
    val name = items.singleOrNull()?.takeIf { it.kind == ClipItemKind.FILE }?.name
    return ClipSummary(content, count, bytes, name)
}

/** clipboard.fetch payload. */
internal fun clipFetchPayload(offerId: String, index: Int, transferId: String): ByteArray = JSONObject()
    .put("version", ClipLimits.VERSION)
    .put("offerId", offerId)
    .put("index", index)
    .put("transferId", transferId)
    .toString().toByteArray(Charsets.UTF_8)

/** clipboard.error payload. */
internal fun clipErrorPayload(offerId: String, index: Int, transferId: String, code: String): ByteArray = JSONObject()
    .put("version", ClipLimits.VERSION)
    .put("offerId", offerId)
    .put("index", index)
    .put("transferId", transferId)
    .put("code", code)
    .toString().toByteArray(Charsets.UTF_8)

internal data class ClipFetchRequest(val offerId: String, val index: Int, val transferId: String)

/** A fetch or error reference: version 1, UUID offer and transfer IDs, index 0 to 99. */
internal fun parseClipReference(bytes: ByteArray, outerTransferId: String?): ClipFetchRequest? = runCatching {
    if (bytes.size > 4096) return null
    val json = JSONObject(bytes.toString(Charsets.UTF_8))
    if (json.opt("version") != 1) return null
    val offerId = json.opt("offerId") as? String ?: return null
    val transferId = json.opt("transferId") as? String ?: return null
    val index = json.opt("index")
    if (index !is Int || index !in 0 until ClipLimits.MAX_ITEMS) return null
    if (!isUuid(offerId) || !isUuid(transferId)) return null
    if (outerTransferId != null && outerTransferId != transferId) return null
    ClipFetchRequest(offerId.lowercase(), index, transferId)
}.getOrNull()

/** The clipboard purpose fields of a decrypted files.offer, or null for an ordinary file. */
internal data class ClipTransferOffer(
    val transferId: String,
    val offerId: String,
    val index: Int,
    val size: Long,
    val sha256: String?,
)

internal fun parseClipTransferOffer(payload: JSONObject): ClipTransferOffer? {
    if (payload.optString("purpose") != "clipboard") return null
    val transferId = payload.optString("transferId")
    val offerId = payload.optString("offerId")
    val index = payload.opt("index")
    val size = payload.opt("size")
    if (!isUuid(transferId) || !isUuid(offerId) || index !is Int || (size !is Int && size !is Long)) return null
    val sha = (payload.opt("sha256") as? String)?.takeIf(String::isNotEmpty)
    if (sha != null && decodeSha(sha) == null) return null
    return ClipTransferOffer(transferId, offerId.lowercase(), index, (size as Number).toLong(), sha)
}

internal fun clipTransferOfferPayload(
    transferId: String,
    offerId: String,
    item: ClipOfferItem,
    sha256: String?,
): ByteArray = JSONObject()
    .put("transferId", transferId)
    .put("name", clipDisplayName(item))
    .put("mimeType", item.mime)
    .put("size", item.size)
    .apply { sha256?.let { put("sha256", it) } }
    .put("purpose", "clipboard")
    .put("offerId", offerId)
    .put("index", item.index)
    .toString().toByteArray(Charsets.UTF_8)
