package dev.bridgey.android

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Portable classification contract; Android intents and clipboard access stay in this adapter. */
internal enum class ClipboardContextKind { LINK, CALL, EMAIL }

/** Notification metadata only. The keyed fingerprint cannot reveal a short copied number. */
internal data class ClipboardContextAction(val kind: ClipboardContextKind, val fingerprint: String)

internal data class ClipboardContextTarget(val kind: ClipboardContextKind, val value: String) {
    fun intent(): Intent = (when (kind) {
        ClipboardContextKind.LINK -> Intent(Intent.ACTION_VIEW, Uri.parse(value).normalizeScheme()).addCategory(Intent.CATEGORY_BROWSABLE)
        ClipboardContextKind.CALL -> Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", value, null))
        ClipboardContextKind.EMAIL -> Intent(Intent.ACTION_SENDTO, Uri.fromParts("mailto", value, null))
    }).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
}

/** Whole, unambiguous values only: never extract a destination from prose, an OTP or a USSD code. */
internal fun classifyClipboardContext(text: String, sensitive: Boolean = false): ClipboardContextTarget? {
    if (sensitive || text.length > 8_192) return null
    val value = text.trim()
    if (value.isEmpty() || value.any { it.isISOControl() || Character.getType(it) == Character.FORMAT.toInt() }) return null
    val uri = runCatching { URI(value) }.getOrNull()
    if (uri != null && uri.scheme?.lowercase() in setOf("http", "https") &&
        !uri.host.isNullOrBlank() && uri.rawUserInfo == null && uri.port in -1..65_535 && !value.any(Char::isWhitespace)
    ) return ClipboardContextTarget(ClipboardContextKind.LINK, uri.toASCIIString())

    if (value.length <= 254 && EMAIL.matches(value) && !value.substringBefore('@').let { it.startsWith('.') || it.endsWith('.') || ".." in it }) {
        return ClipboardContextTarget(ClipboardContextKind.EMAIL, value)
    }
    if (!PHONE.matches(value)) return null
    val number = value.filter { it in '0'..'9' || it == '+' }
    val digits = number.count { it in '0'..'9' }
    // Short bare numbers are commonly one-time codes. Only longer bare numbers, or a formatted
    // international/local phone number, receive a Call action. * and # never reach the dialler.
    val explicitPhone = value.startsWith('+') || '(' in value
    if (digits !in 7..15 || (!explicitPhone && digits < 10)) return null
    if (value.count { it == '(' } != value.count { it == ')' }) return null
    return ClipboardContextTarget(ClipboardContextKind.CALL, number)
}

private val EMAIL = Regex("[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+")
private val PHONE = Regex("\\+?[0-9(][0-9 ()\\-.]*[0-9)]")

/** No coercion or provider I/O: one text/web-URI item, respecting sensitive clips. */
internal fun readClipboardContext(context: Context): LocalClip.Text? = runCatching {
    val clipboard = context.getSystemService(ClipboardManager::class.java)
    val clip = clipboard.primaryClip?.takeIf { it.itemCount == 1 } ?: return@runCatching null
    val item = clip.getItemAt(0)
    if (item.intent != null) return@runCatching null
    val uri = item.uri
    val text = if (uri != null) {
        // A raw web URI needs no provider access. Mixed payloads and content/file URIs
        // stay with Send rather than being coerced into a local destination.
        if (item.text != null || uri.scheme?.lowercase() !in setOf("http", "https")) return@runCatching null
        uri.toString().takeIf { it.length <= 8_192 } ?: return@runCatching null
    } else {
        val source = item.text?.takeIf { it.length <= 8_192 } ?: return@runCatching null
        source.toString()
    }
    LocalClip.Text(text, null, clip.description.isMarkedSensitive())
}.getOrNull()

/** Process-only knowledge. It is invalidated when Bridgey can no longer observe the clipboard. */
internal class ClipboardContextActions(secret: ByteArray = ByteArray(32).also(SecureRandom()::nextBytes)) {
    private val key = SecretKeySpec(secret.copyOf(), "HmacSHA256")
    private val mutableAction = MutableStateFlow<ClipboardContextAction?>(null)
    val action = mutableAction.asStateFlow()

    fun observe(clip: LocalClip.Text?) {
        mutableAction.value = clip?.let { current ->
            classifyClipboardContext(current.text, current.sensitive)?.let { ClipboardContextAction(it.kind, fingerprint(current.text)) }
        }
    }

    fun clear() { mutableAction.value = null }

    /** Called only after a user tap and a focused read; an old action never opens a different clip. */
    fun resolve(expected: ClipboardContextAction, current: LocalClip.Text?): ClipboardContextTarget? {
        current ?: return null
        val target = classifyClipboardContext(current.text, current.sensitive) ?: return null
        if (target.kind != expected.kind || !expected.fingerprint.matches(Regex("[0-9a-f]{64}"))) return null
        val actual = fingerprint(current.text).toByteArray(Charsets.US_ASCII)
        if (!MessageDigest.isEqual(expected.fingerprint.toByteArray(Charsets.US_ASCII), actual)) return null
        return target
    }

    private fun fingerprint(text: String): String = Mac.getInstance("HmacSHA256").run {
        init(key)
        doFinal(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }
}

internal enum class ClipboardContextOpenResult { OPENED, CHANGED, NO_HANDLER }

/** One explicitly local action. The injected boundary makes focus, re-read and failure behavior testable. */
internal fun executeClipboardContext(
    actions: ClipboardContextActions,
    expected: ClipboardContextAction?,
    focused: Boolean,
    enabled: Boolean,
    read: () -> LocalClip.Text?,
    open: (Intent) -> Unit,
): ClipboardContextOpenResult {
    if (!focused || !enabled || expected == null) {
        actions.clear()
        return ClipboardContextOpenResult.CHANGED
    }
    val current = runCatching(read).getOrNull()
    val target = actions.resolve(expected, current)
    actions.observe(current)
    if (target == null) return ClipboardContextOpenResult.CHANGED
    return if (runCatching { open(target.intent()) }.isSuccess) ClipboardContextOpenResult.OPENED else ClipboardContextOpenResult.NO_HANDLER
}
