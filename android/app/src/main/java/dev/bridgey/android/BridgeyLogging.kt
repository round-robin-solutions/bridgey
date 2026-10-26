package dev.bridgey.android

import android.util.Log

/**
 * Settings > Privacy > Logging: what Bridgey writes to Logcat and to exported diagnostics.
 * Per device; privacy-leaning defaults except call events, which stay on so call problems can
 * be traced. Content fields (numbers, notification text, clipboard previews, file names) are off
 * by default and only ever reach the local log, never exported diagnostics.
 */
data class LoggingPolicy(
    /** Discovery, pairing, transport and reconnects. */
    val connection: Boolean = true,
    /** Call state changes and the caller's name. */
    val calls: Boolean = true,
    /** Phone numbers in call events; off means numbers are masked. */
    val callNumbers: Boolean = false,
    /** Which app posted a notification and what happened to it. */
    val notifications: Boolean = true,
    /** Notification titles and text. */
    val notificationContent: Boolean = false,
    /** Clipboard sends and receipts. */
    val clipboard: Boolean = true,
    /** The first characters of clipboard text. */
    val clipboardPreviews: Boolean = false,
    /** File and folder names in transfer events (the events themselves are always logged). */
    val fileNames: Boolean = false,
    /** Remote control session start and end. The Mac's remote control audit is separate. */
    val remoteControl: Boolean = true,
)

enum class LogCategory { CONNECTION, CALLS, NOTIFICATIONS, CLIPBOARD, FILES, REMOTE_CONTROL, GENERAL }

internal fun LoggingPolicy.allows(category: LogCategory): Boolean = when (category) {
    LogCategory.CONNECTION -> connection
    LogCategory.CALLS -> calls
    LogCategory.NOTIFICATIONS -> notifications
    LogCategory.CLIPBOARD -> clipboard
    LogCategory.REMOTE_CONTROL -> remoteControl
    LogCategory.FILES, LogCategory.GENERAL -> true
}

/** The logging category of a diagnostics event category. */
internal fun diagnosticLogCategory(category: String): LogCategory = when (category) {
    "discovery", "pairing", "reconnect", "transport", "protocol", "power", "link" -> LogCategory.CONNECTION
    "call", "calls" -> LogCategory.CALLS
    "notification" -> LogCategory.NOTIFICATIONS
    "clipboard" -> LogCategory.CLIPBOARD
    "transfer", "folder" -> LogCategory.FILES
    "remote" -> LogCategory.REMOTE_CONTROL
    else -> LogCategory.GENERAL
}

private val phoneNumberPattern = Regex("""[+(]?\d[\d\s().-]{4,}\d""")

/** Masks anything that looks like a phone number (6 or more digits with separators). */
internal fun maskPhoneNumbers(text: String): String = text.replace(phoneNumberPattern) { match ->
    if (match.value.count(Char::isDigit) >= 6) "[number]" else match.value
}

/**
 * Builds Logcat lines from only the fields the policy allows. Each function returns null when
 * the category is off, so nothing is written. Pure, so tests pin what can reach the log.
 */
internal object LogLines {
    fun call(policy: LoggingPolicy, event: String, id: String?, reason: String, caller: String? = null): String? {
        if (!policy.calls) return null
        val name = caller?.trim()?.takeIf(String::isNotEmpty)?.let { if (policy.callNumbers) it else maskPhoneNumbers(it) }
        return buildString {
            append("CALL ").append(event).append(" id=").append(id?.take(8) ?: "-").append(" reason=").append(reason)
            if (name != null) append(" caller=\"").append(name.take(80)).append('"')
        }
    }

    fun notification(policy: LoggingPolicy, event: String, appName: String, title: String? = null, text: String? = null): String? {
        if (!policy.notifications) return null
        return buildString {
            append("NOTIFICATION ").append(event).append(" app=\"").append(appName.take(64)).append('"')
            if (policy.notificationContent) {
                title?.takeIf(String::isNotBlank)?.let { append(" title=\"").append(it.take(80)).append('"') }
                text?.takeIf(String::isNotBlank)?.let { append(" text=\"").append(it.take(160)).append('"') }
            }
        }
    }

    fun clipboard(policy: LoggingPolicy, event: String, preview: String? = null): String? {
        if (!policy.clipboard) return null
        return buildString {
            append("CLIPBOARD ").append(event)
            if (policy.clipboardPreviews) {
                preview?.trim()?.takeIf(String::isNotEmpty)?.let {
                    append(" preview=\"").append(it.replace('\n', ' ').take(40)).append('"')
                }
            }
        }
    }

    fun file(policy: LoggingPolicy, event: String, transferId: String, name: String? = null, extra: String = ""): String = buildString {
        append("FILE ").append(event).append(" transfer=").append(transferId.take(8))
        if (extra.isNotEmpty()) append(' ').append(extra)
        if (policy.fileNames) name?.takeIf(String::isNotBlank)?.let { append(" name=\"").append(it.take(120)).append('"') }
    }
}

/** Logcat for Bridgey (tag "Bridgey"), filtered by the current [LoggingPolicy]. */
object BridgeyLogging {
    @Volatile
    var policy: LoggingPolicy = LoggingPolicy()
        set(value) {
            field = value
            dev.bridgey.core.discovery.DiscoveryLog.enabled = value.connection
        }

    private const val TAG = "Bridgey"

    fun allows(category: LogCategory): Boolean = policy.allows(category)

    internal fun allowsDiagnostic(category: String): Boolean = policy.allows(diagnosticLogCategory(category))

    fun i(category: LogCategory, message: String) {
        if (allows(category)) Log.i(TAG, message)
    }

    fun d(category: LogCategory, message: String) {
        if (allows(category)) Log.d(TAG, message)
    }

    fun w(category: LogCategory, message: String, error: Throwable? = null) {
        if (!allows(category)) return
        if (error != null) Log.w(TAG, message, error) else Log.w(TAG, message)
    }

    /** Writes a line built by [LogLines]; null (category off) writes nothing. */
    fun line(line: String?) {
        if (line != null) Log.i(TAG, line)
    }
}
