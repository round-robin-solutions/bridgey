package dev.bridgey.android.codes

/*
 * Codes from messages (edition). The Mac reads codes; the phone marks SMS notifications, reports
 * whether Android hides their text from Bridgey, and makes the companion link that lifts the hiding.
 * The hidden Code reader test (lab builds) also uses the guard, the pre-check and the pattern baseline
 * below, the same rules as the Mac (CodeReader.swift) and the relay (services/otp-proxy).
 *
 * Message text and codes are never logged, whatever Settings > Privacy > Logging says.
 */

/** Draft, edition only: features.update key, `smsDefaultApp`/`redacted` fields and `codes.*` messages. */
const val SMS_CODES_FEATURE_KEY = "sms_codes_draft1"

/** Android 15: the first release that hides code notifications from untrusted listeners. */
const val SENSITIVE_REDACTION_SDK = 35

/** What Android shows Bridgey of code messages, as reported to the Mac in `codes.status`. */
enum class CodeAccessStatus(val wire: String) {
    /** Full text: a companion link, the ADB app-op, or a release that does not hide codes. */
    ALLOWED("allowed"),
    /** Android replaced an SMS notification's text with "Sensitive notification content hidden". */
    HIDDEN("hidden"),
    /** Android 15 or newer, no link and no ADB grant, and nothing observed yet. */
    NOT_LINKED("not_linked"),
}

/**
 * The status from what Bridgey knows. What was actually seen wins: a hidden SMS since the last link
 * means hidden, whatever the link says; a full one means allowed.
 */
fun codeAccessStatus(sdkInt: Int, linked: Boolean, appOpAllowed: Boolean, lastSmsRedacted: Boolean?): CodeAccessStatus = when {
    lastSmsRedacted == true -> CodeAccessStatus.HIDDEN
    sdkInt < SENSITIVE_REDACTION_SDK -> CodeAccessStatus.ALLOWED
    linked || appOpAllowed -> CodeAccessStatus.ALLOWED
    lastSmsRedacted == false -> CodeAccessStatus.ALLOWED
    else -> CodeAccessStatus.NOT_LINKED
}

/** Android's English placeholder, used when the system string cannot be read. */
const val DEFAULT_REDACTED_TEXT = "Sensitive notification content hidden"

/** The notification text is Android's placeholder rather than the message. */
fun isRedactedNotificationText(text: String, systemPlaceholder: String?): Boolean {
    val trimmed = text.trim()
    if (trimmed.isEmpty()) return false
    val placeholder = systemPlaceholder?.trim()?.takeIf { it.isNotEmpty() }
    return trimmed == placeholder || trimmed == DEFAULT_REDACTED_TEXT
}

/** The one-time ADB fallback when the companion link does not work on a phone. */
fun codeAccessAdbCommand(packageName: String): String =
    "adb shell cmd appops set --user 0 $packageName RECEIVE_SENSITIVE_NOTIFICATIONS allow"

private fun Char.isAsciiDigit() = this in '0'..'9'
private fun Char.isAsciiLetter() = this in 'a'..'z' || this in 'A'..'Z'
private fun Char.isAsciiAlphanumeric() = isAsciiDigit() || isAsciiLetter()

/**
 * Accepts a model's code only if it appears in the message as a whole token and looks like a code.
 * Can only refuse. Same rule as the Mac's CodeGuard and `strict_guard` in the model research.
 */
object CodeGuard {
    private const val EDGE_L = "(?<![0-9A-Za-z])"
    private const val EDGE_R = "(?![0-9A-Za-z])"
    /** 3 or more letters or digits with at least one digit. */
    private const val DIGIT_GROUP = "(?=[0-9A-Za-z]*[0-9])[0-9A-Za-z]{3,}"
    /** Lookahead, so overlapping candidates are all tried: an optional 1 or 2 letter prefix, then digit groups. */
    private val SPLIT_TOKEN = Regex("(?=$EDGE_L((?:[A-Za-z]{1,2}[ \\-])?$DIGIT_GROUP(?:[ \\-]$DIGIT_GROUP)*)$EDGE_R)")

    private fun isSeparator(c: Char) = c == ' ' || c == '-' || c.isWhitespace()
    private fun isShortPrefix(part: String) = part.length in 1..2 && part.all { it.isAsciiLetter() }

    /**
     * The code (separators and a 1 or 2 letter prefix such as "G-" removed, letter case as in the
     * message), or null. Every part contains a digit, and when there are several parts each has 3 or
     * more characters; 4 to 8 letters or digits in all; the answer is in the message literally as a
     * whole token, or the message has a split token ("482 913", "PP-301842") whose groups each have 3
     * or more characters and a digit and which equals the answer without separators. A space or
     * hyphen is never allowed between any two characters, so "5minMe" does not match "5 min me".
     */
    fun accept(answer: String?, text: String): String? {
        var raw = answer?.trim().orEmpty()
        if (raw.isEmpty() || raw.length > 24) return null
        var parts = raw.split(Regex("[\\s-]+")).filter { it.isNotEmpty() }
        if (parts.size > 1 && isShortPrefix(parts[0])) {
            parts = parts.drop(1)
            raw = raw.dropWhile { !isSeparator(it) }.dropWhile { isSeparator(it) }
        }
        if (parts.isEmpty() || parts.any { part -> part.none { it.isAsciiDigit() } }) return null
        if (parts.size > 1 && parts.any { it.length < 3 }) return null
        val core = parts.joinToString("")
        if (core.length !in 4..8 || !core.all { it.isAsciiAlphanumeric() }) return null

        Regex(EDGE_L + Regex.escape(raw) + EDGE_R, RegexOption.IGNORE_CASE).find(text)?.let { literal ->
            return literal.value.filter { it.isAsciiAlphanumeric() }
        }
        val wanted = core.uppercase()
        for (match in SPLIT_TOKEN.findAll(text)) {
            val token = match.groupValues[1]
            if (token.none { isSeparator(it) }) continue
            var groups = token.split(' ', '-')
            var prefix = ""
            if (isShortPrefix(groups[0])) {
                prefix = groups[0].uppercase()
                groups = groups.drop(1)
            }
            if (groups.isEmpty() || groups.any { group -> group.none { it.isAsciiDigit() } }) continue
            val joined = groups.joinToString("")
            if (wanted == joined.uppercase() || wanted == prefix + joined.uppercase()) return joined
        }
        return null
    }
}

private val OTP_TOKEN = Regex("(?<![0-9A-Za-z])(?=[0-9A-Za-z]*[0-9])[0-9A-Za-z]{4,10}(?![0-9A-Za-z])")
private val OTP_SPLIT = Regex("(?<![0-9A-Za-z])[0-9]{2,5}[ -][0-9]{2,5}(?![0-9A-Za-z])")

/** The relay's pre-check: a 4 to 10 character token with a digit, or two digit groups ("591-047"). */
fun looksLikeOtpTraffic(text: String): Boolean = OTP_TOKEN.containsMatchIn(text) || OTP_SPLIT.containsMatchIn(text)

/**
 * Comparison only (Code reader test): a context-word pattern matcher in the spirit of Android's own
 * detector. Rahul does not want it to decide, and it never shows a code.
 */
object PatternBaseline {
    private val context = Regex("(otp|code|pin|password|passcode|verification|ओटीपी|कोड)", RegexOption.IGNORE_CASE)
    private val candidate = Regex(
        "(?<![0-9A-Za-z])((?:[A-Z]-)?(?=[0-9A-Z\\- ]{4,9}(?![0-9A-Za-z]))(?=[^\\s]*\\d)[0-9A-Z]{3,4}(?:[\\- ][0-9A-Z]{3})?|[0-9]{4,8}|[0-9A-Z]{6})(?![0-9A-Za-z])",
    )
    private val prefix = Regex("^[A-Z]-")

    fun extract(text: String): String? {
        if (!context.containsMatchIn(text)) return null
        val contextStarts = context.findAll(text).map { it.range.first }.toList()
        var best: Pair<Int, String>? = null
        for (match in candidate.findAll(text)) {
            val value = match.groupValues[1]
            if (value.none { it.isDigit() }) continue
            val start = match.range.first
            val window = text.substring((start - 40).coerceAtLeast(0), (match.range.last + 1 + 40).coerceAtMost(text.length))
            if (!context.containsMatchIn(window)) continue
            val distance = contextStarts.minOf { kotlin.math.abs(start - it) }
            if (best == null || distance < best.first) best = distance to value
        }
        return best?.second?.replace(prefix, "")
    }
}

/** POST /v1/extract on the relay (services/otp-proxy): the same request the Mac sends. */
object CodeRelay {
    const val MAX_TEXT_LENGTH = 600
    const val MAX_SENDER_LENGTH = 64
    const val TIMEOUT_MS = 2_000

    fun isInstallId(value: String): Boolean = value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }

    fun newInstallId(random: java.security.SecureRandom = java.security.SecureRandom()): String =
        ByteArray(32).also(random::nextBytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    /** The JSON body, or null when the text is empty or over the relay's limit (never cut: that could drop the code). */
    fun requestBody(text: String, sender: String?): String? {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || trimmed.length > MAX_TEXT_LENGTH) return null
        val json = org.json.JSONObject().put("v", 1).put("text", trimmed)
        sender?.trim()?.takeIf { it.isNotEmpty() }?.let { json.put("sender", prefixWhole(it, MAX_SENDER_LENGTH)) }
        return json.toString()
    }

    /** At most [limit] UTF-16 units without splitting a surrogate pair. */
    fun prefixWhole(value: String, limit: Int): String {
        if (value.length <= limit) return value
        val end = if (Character.isHighSurrogate(value[limit - 1])) limit - 1 else limit
        return value.substring(0, end)
    }

    sealed interface Answer {
        data class Candidate(val code: String) : Answer
        data object NoCode : Answer
        data class Failed(val reason: String) : Answer
    }

    fun parse(status: Int, body: String): Answer = when (status) {
        200 -> {
            val json = runCatching { org.json.JSONObject(body) }.getOrNull()
            val isOtp = json?.opt("is_otp")
            when {
                json == null || isOtp !is Boolean -> Answer.Failed("invalid_response")
                !isOtp -> Answer.NoCode
                else -> (json.opt("code") as? String)?.takeIf { it.isNotEmpty() }?.let(Answer::Candidate) ?: Answer.NoCode
            }
        }
        422 -> Answer.NoCode
        429 -> Answer.Failed("rate_limited")
        504 -> Answer.Failed("timeout")
        else -> Answer.Failed("unavailable")
    }
}
