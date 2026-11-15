package dev.bridgey.android.media

import dev.bridgey.android.jsonInteger
import dev.bridgey.android.strictJsonObject
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

const val CALL_QUIET_FEATURE_KEY = "call_quiet_draft1"
const val CALL_QUIET_RENEW_MS = 25_000L
const val CALL_QUIET_EXPIRE_MS = 75_000L
const val CALL_QUIET_STATE_MAX_BYTES = 2_048
const val CALL_QUIET_RESULT_MAX_BYTES = 1_024
private val quietCallId = Regex("[A-Za-z0-9_-]{1,64}")

data class CallQuietState(val revision: Int, val calls: Set<String>, val uncertain: Boolean = false) {
    fun encode(): JSONObject = JSONObject().put("version", 1).put("revision", revision)
        .put("calls", JSONArray(calls.sorted())).put("uncertain", uncertain)
}

data class CallQuietResult(val revision: Int, val paused: Int, val muted: Int, val limited: Int, val issues: Set<String>) {
    fun encode(): JSONObject = JSONObject().put("version", 1).put("revision", revision)
        .put("paused", paused).put("muted", muted).put("limited", limited)
        .put("issues", JSONArray(issues.sorted()))
}

internal val CALL_QUIET_ISSUES = setOf(
    "permission_needed", "unsupported", "call_audio_protected", "changed_by_user", "session_gone",
    "command_failed", "cancelled", "other_players_limited", "selective_mute_unavailable",
)

fun decodeCallQuietState(plaintext: ByteArray): CallQuietState? {
    if (plaintext.size > CALL_QUIET_STATE_MAX_BYTES) return null
    val value = quietObject(plaintext) ?: return null
    if (value.keys().asSequence().toSet() != setOf("version", "revision", "calls", "uncertain")) return null
    if (jsonInteger(value.opt("version")) != 1L) return null
    val revision = jsonInteger(value.opt("revision"))?.takeIf { it in 1..Int.MAX_VALUE.toLong() }?.toInt() ?: return null
    val values = value.opt("calls") as? JSONArray ?: return null
    val uncertain = value.opt("uncertain") as? Boolean ?: return null
    if (values.length() > 16) return null
    val calls = linkedSetOf<String>()
    for (i in 0 until values.length()) {
        val call = values.opt(i) as? String ?: return null
        if (!quietCallId.matches(call) || !calls.add(call)) return null
    }
    return CallQuietState(revision, calls, uncertain)
}

fun decodeCallQuietResult(plaintext: ByteArray): CallQuietResult? {
    if (plaintext.size > CALL_QUIET_RESULT_MAX_BYTES) return null
    val value = quietObject(plaintext) ?: return null
    if (value.keys().asSequence().toSet() != setOf("version", "revision", "paused", "muted", "limited", "issues")) return null
    if (jsonInteger(value.opt("version")) != 1L) return null
    val revision = jsonInteger(value.opt("revision"))?.takeIf { it in 1..Int.MAX_VALUE.toLong() }?.toInt() ?: return null
    fun count(key: String): Int? = jsonInteger(value.opt(key))?.takeIf { it in 0L..64L }?.toInt()
    val paused = count("paused") ?: return null
    val muted = count("muted") ?: return null
    val limited = count("limited") ?: return null
    val values = value.opt("issues") as? JSONArray ?: return null
    if (values.length() > 16) return null
    val issues = linkedSetOf<String>()
    for (i in 0 until values.length()) {
        val issue = values.opt(i) as? String ?: return null
        if (issue !in CALL_QUIET_ISSUES || !issues.add(issue)) return null
    }
    return CallQuietResult(revision, paused, muted, limited, issues)
}

fun CallMediaResult.wireResult(revision: Int): CallQuietResult = CallQuietResult(
    revision = revision,
    paused = paused.coerceIn(0, 64),
    muted = if (muted) 1 else 0,
    limited = unsupported.coerceIn(0, 64),
    issues = reasons.mapTo(linkedSetOf()) { reason ->
        when (reason) {
            CallMediaReason.PERMISSION_NEEDED -> "permission_needed"
            CallMediaReason.PLATFORM_UNAVAILABLE, CallMediaReason.PAUSE_UNSUPPORTED -> "unsupported"
            CallMediaReason.CALL_AUDIO_PROTECTED -> "call_audio_protected"
            CallMediaReason.PAUSE_UNCONFIRMED -> "command_failed"
            CallMediaReason.MUTE_UNAVAILABLE -> "selective_mute_unavailable"
            CallMediaReason.SESSION_LIMIT, CallMediaReason.RESTORE_UNVERIFIED, CallMediaReason.UNEXPOSED_PLAYBACK -> "other_players_limited"
            CallMediaReason.MANUAL_PLAYBACK, CallMediaReason.STATE_CHANGED -> "changed_by_user"
        }
    },
)

/** This draft rejects duplicate/escaped-equivalent keys as well as malformed UTF-8. */
private fun quietObject(bytes: ByteArray): JSONObject? {
    val text = runCatching {
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
    }.getOrNull() ?: return null
    val value = strictJsonObject(text) ?: return null
    val keys = mutableSetOf<String>()
    var depth = 0
    var i = 0
    while (i < text.length) {
        when (text[i]) {
            '{', '[' -> depth += 1
            '}', ']' -> depth -= 1
            '"' -> {
                val start = i++
                while (i < text.length) {
                    if (text[i] == '\\') i += 2
                    else if (text[i++] == '"') break
                }
                var next = i
                while (next < text.length && text[next].isWhitespace()) next += 1
                if (depth == 1 && next < text.length && text[next] == ':') {
                    val key = runCatching { JSONTokener(text.substring(start, i)).nextValue() as? String }.getOrNull() ?: return null
                    if (!keys.add(key)) return null
                }
                continue
            }
        }
        i += 1
    }
    return value
}
