package dev.bridgey.android

import android.content.ClipDescription
import android.os.Build
import java.security.MessageDigest
import org.json.JSONObject

internal const val MAX_CLIPBOARD_CONTENT_BYTES = 32 * 1024

/** A clip read on resume counts as fresh only within this window (ClipDescription.getTimestamp). */
internal const val AUTO_CLIPBOARD_MAX_AGE_MILLIS = 10L * 60 * 1000

/** What automatic clipboard decided to do with a change, kept pure so it is unit tested. */
internal enum class ClipboardAutoDecision { SEND, SEND_OFFER, SKIP_UNAVAILABLE, SKIP_EMPTY, SKIP_SENSITIVE, SKIP_TOO_LARGE, SKIP_DUPLICATE }

/** A stable fingerprint of clipboard content, for de-duplication and loop prevention. */
internal fun clipboardHash(text: String): String =
    MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

/**
 * Whether a clip read on resume is recent enough to send. API 26+ (our minSdk) always has a
 * timestamp; a missing or zero timestamp is treated as not fresh, so stale clips are not sent.
 */
internal fun clipIsFresh(timestampMillis: Long, nowMillis: Long): Boolean =
    timestampMillis > 0L && (nowMillis - timestampMillis) in 0..AUTO_CLIPBOARD_MAX_AGE_MILLIS

/**
 * Decides whether automatic clipboard should send [text]. Skip rules: unavailable (feature off on
 * either side, or automatic off), empty, sensitive, over the size limit, or identical to the last
 * content sent to or received from this device (de-duplication and loop prevention via [lastHash]).
 */
internal fun autoClipboardDecision(
    text: String?,
    sensitive: Boolean,
    available: Boolean,
    lastHash: String?,
): ClipboardAutoDecision = when {
    !available -> ClipboardAutoDecision.SKIP_UNAVAILABLE
    text.isNullOrEmpty() -> ClipboardAutoDecision.SKIP_EMPTY
    sensitive -> ClipboardAutoDecision.SKIP_SENSITIVE
    !clipboardTextFits(text) -> ClipboardAutoDecision.SKIP_TOO_LARGE
    lastHash != null && lastHash == clipboardHash(text) -> ClipboardAutoDecision.SKIP_DUPLICATE
    else -> ClipboardAutoDecision.SEND
}

/**
 * The last clipboard content handled per device, so identical content is not re-sent and a clip
 * written because the peer sent it is never bounced back. Keyed by remote device id.
 */
internal class AutoClipboardTracker {
    private val lastHash = HashMap<String, String>()

    @Synchronized fun isDuplicate(deviceId: String, hash: String): Boolean = lastHash[deviceId] == hash

    @Synchronized fun lastHash(deviceId: String): String? = lastHash[deviceId]

    @Synchronized fun record(deviceId: String, hash: String) { lastHash[deviceId] = hash }

    @Synchronized fun clear(deviceId: String) { lastHash.remove(deviceId) }
}

internal data class RichClipboardContent(val text: String, val html: String) {
    fun encode(): ByteArray = JSONObject()
        .put("version", 1)
        .put("text", text)
        .put("html", html)
        .toString()
        .toByteArray(Charsets.UTF_8)

    companion object {
        fun create(text: String, html: String?): RichClipboardContent? {
            val rich = html?.takeIf(String::isNotBlank) ?: return null
            if (text.isEmpty() || text.toByteArray().size + rich.toByteArray().size > MAX_CLIPBOARD_CONTENT_BYTES) return null
            return RichClipboardContent(text, rich)
        }

        fun decode(bytes: ByteArray): RichClipboardContent? = runCatching {
            val objectValue = JSONObject(bytes.toString(Charsets.UTF_8))
            if (objectValue.optInt("version") != 1 || objectValue.opt("text") !is String || objectValue.opt("html") !is String) return null
            create(objectValue.getString("text"), objectValue.getString("html"))
        }.getOrNull()
    }
}

internal fun clipboardTextFits(text: String): Boolean =
    text.isNotEmpty() && text.toByteArray(Charsets.UTF_8).size <= MAX_CLIPBOARD_CONTENT_BYTES

/** Android 13+ lets apps mark a clip as sensitive (passwords, codes). */
internal fun ClipDescription?.isMarkedSensitive(): Boolean =
    Build.VERSION.SDK_INT >= 33 && this?.extras?.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE) == true
