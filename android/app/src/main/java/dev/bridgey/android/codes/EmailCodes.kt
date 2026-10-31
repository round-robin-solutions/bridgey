package dev.bridgey.android.codes

import dev.bridgey.android.LogLines
import dev.bridgey.android.LoggingPolicy

/*
 * Codes from email, phase 1 (edition; docs/codes-from-email.md). The phone marks notifications from the four
 * supported mail apps and, for a Mac that showed `email_codes_draft1`, adds the expanded text the phone already
 * shows (`preview`). The Mac reads codes with its own model; the phone only decides what to send.
 *
 * Kept free of Android types so the unit tests run on the JVM. Mail text, previews and codes are never logged,
 * whatever Settings > Privacy > Logging says.
 */

/** Draft, edition only: features.update key that gates `emailApp`, `preview` and `redacted` on mail notifications. */
const val EMAIL_CODES_FEATURE_KEY = "email_codes_draft1"

/** The longest preview, in UTF-16 units (the relay's and the Mac reader's limit too). */
const val EMAIL_PREVIEW_MAX_LENGTH = 600

/** "Also read codes in email" while nobody chose: on (Rahul, 2026-10-31). */
const val EMAIL_CODES_DEFAULT = true

/**
 * The supported mail apps (Rahul, 2026-10-31; packages checked on Google Play): Gmail, Outlook, Proton Mail and
 * Spark Mail by Readdle. Only these four, never other apps that post CATEGORY_EMAIL.
 */
val EMAIL_APP_PACKAGES: Set<String> = setOf(
    "com.google.android.gm",
    "com.microsoft.office.outlook",
    "ch.protonmail.android",
    "com.readdle.spark",
)

fun isMailAppPackage(packageName: String): Boolean = packageName in EMAIL_APP_PACKAGES

/**
 * A notification that counts as mail for codes: from one of the four apps, not a group summary ("3 new emails"),
 * not a call, and not Bridgey's own.
 */
fun isEmailAppNotification(packageName: String, ownPackage: String, groupSummary: Boolean, isCall: Boolean): Boolean =
    packageName != ownPackage && !groupSummary && !isCall && isMailAppPackage(packageName)

/** One MessagingStyle message as the notification extras hold it. */
data class StyleMessage(val text: String?, val time: Long)

/**
 * What a mail notification shows, read from its extras: EXTRA_TEXT (the subject in Gmail, Outlook, Proton Mail and
 * Spark), EXTRA_BIG_TEXT, EXTRA_TEXT_LINES (InboxStyle) and EXTRA_MESSAGES (MessagingStyle).
 */
data class EmailNotificationContent(
    val text: String?,
    val bigText: String? = null,
    val textLines: List<String>? = null,
    val messages: List<StyleMessage>? = null,
)

/**
 * The expanded text before the gate and the cap, or null for a multi-mail summary or an empty notification.
 * InboxStyle with two or more lines stands for several mails: no preview. MessagingStyle: the newest message.
 * Otherwise EXTRA_BIG_TEXT with the subject (EXTRA_TEXT) in front when the big text does not already hold it,
 * else EXTRA_TEXT.
 */
fun emailExpandedText(content: EmailNotificationContent): String? {
    val lines = content.textLines.orEmpty().filter { it.isNotBlank() }
    if (lines.size > 1) return null
    content.messages?.takeIf { it.isNotEmpty() }?.let { messages ->
        // Newest by time; on a tie the later one in the list (Android appends new messages at the end).
        val newest = messages.withIndex().maxWithOrNull(compareBy<IndexedValue<StyleMessage>> { it.value.time }.thenBy { it.index })
        return newest?.value?.text?.trim()?.takeIf { it.isNotEmpty() }
    }
    val subject = content.text?.trim().orEmpty()
    val big = content.bigText?.trim().orEmpty()
    val expanded = when {
        big.isNotEmpty() && subject.isNotEmpty() && !big.contains(subject) -> "$subject\n$big"
        big.isNotEmpty() -> big
        subject.isNotEmpty() -> subject
        else -> lines.singleOrNull()?.trim().orEmpty()
    }
    return expanded.takeIf { it.isNotEmpty() }
}

/**
 * At most [limit] UTF-16 units, cut at the last whitespace at or before [limit] so no token (and no surrogate pair)
 * is split. Null when there is no whitespace to cut at: a cut inside a token could drop part of the code.
 */
fun capEmailPreview(text: String, limit: Int = EMAIL_PREVIEW_MAX_LENGTH): String? {
    val trimmed = text.trim()
    if (trimmed.length <= limit) return trimmed.takeIf { it.isNotEmpty() }
    var index = limit
    while (index > 0 && !trimmed[index].isWhitespace()) index--
    if (index == 0) return null
    return trimmed.substring(0, index).trimEnd().takeIf { it.isNotEmpty() }
}

/**
 * The `preview` field for a mail notification, or null: not for a hidden (redacted) notification, not for a
 * multi-mail summary, and only when the capped text passes [looksLikeOtpTraffic] (the relay's pre-check), so a
 * mail without anything code-shaped never leaves the phone as a preview.
 */
fun emailPreview(content: EmailNotificationContent, redacted: Boolean): String? {
    if (redacted) return null
    val expanded = emailExpandedText(content) ?: return null
    val capped = capEmailPreview(expanded) ?: return null
    return capped.takeIf(::looksLikeOtpTraffic)
}

/** The notification's text (or big text) is Android's "Sensitive notification content hidden". */
fun isRedactedEmailNotification(content: EmailNotificationContent, systemPlaceholder: String?): Boolean =
    isRedactedNotificationText(content.text.orEmpty(), systemPlaceholder) ||
        isRedactedNotificationText(content.bigText.orEmpty(), systemPlaceholder)

/**
 * The email fields of one Mac's notifications.post, in wire order. Empty unless the notification is mail, the Mac's
 * latest features.update showed [EMAIL_CODES_FEATURE_KEY] and this phone's "Also read codes in email" is on: every
 * other Mac gets exactly the payload it got before codes from email.
 */
fun emailPayloadFields(emailApp: Boolean, preview: String?, redacted: Boolean?, peerReadsEmail: Boolean, switchOn: Boolean): Map<String, Any> {
    if (!emailApp || !peerReadsEmail || !switchOn) return emptyMap()
    val fields = LinkedHashMap<String, Any>()
    fields["emailApp"] = true
    if (redacted != null) fields["redacted"] = redacted
    if (redacted != true) preview?.let { fields["preview"] = it }
    return fields
}

/** What this phone advertises to one Mac: notifications on for it and the switch on. */
fun emailCodesAdvertised(notificationsOn: Boolean, switchOn: Boolean): Boolean = notificationsOn && switchOn

/** SMS from the default SMS app and anything from a mail app can carry codes: their title and text never reach the log. */
fun hidesNotificationContentInLogs(packageName: String, smsDefaultApp: Boolean): Boolean =
    smsDefaultApp || isMailAppPackage(packageName)

/** The "sent" log line for a forwarded notification, without title and text for SMS and mail. */
fun forwardedNotificationLogLine(
    policy: LoggingPolicy,
    applicationName: String,
    packageName: String,
    smsDefaultApp: Boolean,
    title: String,
    text: String,
): String? {
    val hide = hidesNotificationContentInLogs(packageName, smsDefaultApp)
    return LogLines.notification(policy, "sent", applicationName, if (hide) null else title, if (hide) null else text)
}
