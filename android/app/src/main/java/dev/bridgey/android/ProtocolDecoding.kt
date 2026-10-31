package dev.bridgey.android

import dev.bridgey.android.actions.LINKS_OPEN_FEATURE_KEY
import dev.bridgey.android.camera.CAMERA_FEATURE_KEY
import dev.bridgey.android.codes.SMS_CODES_FEATURE_KEY
import dev.bridgey.android.focus.FOCUS_SYNC_FEATURE_KEY
import dev.bridgey.android.folders.FILES_BROWSE_FEATURE_KEY
import dev.bridgey.android.folders.FOLDERS_FEATURE_KEY
import dev.bridgey.android.folders.FOLDERS_RECEIVE_FEATURE_KEY
import dev.bridgey.android.folders.PLACES_FEATURE_KEY
import dev.bridgey.android.sync.SETTINGS_SYNC_FEATURE_KEY
import dev.bridgey.android.updates.UPDATES_FEATURE_KEY
import dev.bridgey.android.sms.SMS_FEATURE_KEY
import org.json.JSONException
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.floor

/*
 * Bridgey Protocol v1 decoding shared by the session and the tests: strict JSON, nesting, replay and
 * the payload decoders that protocol/test-vectors/protocol-v1.json pins for both platforms. The rules
 * are in docs/protocol-contract.md; the Mac has the same functions in ProtocolDecoding.swift.
 */

/** The deepest JSON nesting a frame may have (the outer object counts as 1). */
internal const val MAX_PROTOCOL_JSON_DEPTH = 32

/** The largest integer JSON carries exactly on both platforms (2^53 - 1). */
internal const val JSON_MAX_SAFE_INTEGER = 9_007_199_254_740_991L

/**
 * True when [text] is one strict RFC 8259 JSON object (what the Mac's JSONSerialization accepts) nested
 * at most [maxDepth] deep. org.json alone also takes comments, single quotes and unquoted names, so a
 * frame that the Mac would reject could otherwise be accepted here.
 */
internal fun isStrictJsonObject(text: String, maxDepth: Int = MAX_PROTOCOL_JSON_DEPTH): Boolean =
    StrictJson(text, maxDepth).objectDocument()

private class StrictJson(private val text: String, private val maxDepth: Int) {
    private var index = 0
    private var depth = 0

    fun objectDocument(): Boolean {
        skipSpace()
        if (peek() != '{') return false
        if (!value()) return false
        skipSpace()
        return index == text.length
    }

    private fun peek(): Char? = if (index < text.length) text[index] else null

    private fun skipSpace() {
        while (index < text.length && text[index].let { it == ' ' || it == '\t' || it == '\n' || it == '\r' }) index++
    }

    private fun value(): Boolean {
        skipSpace()
        return when (peek()) {
            '{' -> container('}') { if (!string()) false else { skipSpace(); if (peek() != ':') false else { index++; value() } } }
            '[' -> container(']') { value() }
            '"' -> string()
            't' -> literal("true")
            'f' -> literal("false")
            'n' -> literal("null")
            else -> number()
        }
    }

    private inline fun container(close: Char, member: () -> Boolean): Boolean {
        if (++depth > maxDepth) return false
        index++
        skipSpace()
        if (peek() == close) {
            index++
            depth--
            return true
        }
        while (true) {
            skipSpace()
            if (!member()) return false
            skipSpace()
            when (peek()) {
                ',' -> index++
                close -> {
                    index++
                    depth--
                    return true
                }
                else -> return false
            }
        }
    }

    private fun literal(word: String): Boolean {
        if (!text.startsWith(word, index)) return false
        index += word.length
        return true
    }

    private fun number(): Boolean {
        val start = index
        if (peek() == '-') index++
        when (peek()) {
            '0' -> index++
            in '1'..'9' -> while (peek() in '0'..'9') index++
            else -> return false
        }
        if (peek() == '.') {
            index++
            if (peek() !in '0'..'9') return false
            while (peek() in '0'..'9') index++
        }
        if (peek() == 'e' || peek() == 'E') {
            index++
            if (peek() == '+' || peek() == '-') index++
            if (peek() !in '0'..'9') return false
            while (peek() in '0'..'9') index++
        }
        return index > start
    }

    private fun string(): Boolean {
        if (peek() != '"') return false
        index++
        while (true) {
            val c = peek() ?: return false
            index++
            when {
                c == '"' -> return true
                c < ' ' -> return false
                c == '\\' -> when (peek()) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' -> index++
                    'u' -> {
                        val unit = hex() ?: return false
                        if (unit in 0xDC00..0xDFFF) return false
                        if (unit in 0xD800..0xDBFF) {
                            if (peek() != '\\') return false
                            index++
                            if ((hex() ?: return false) !in 0xDC00..0xDFFF) return false
                        }
                    }
                    else -> return false
                }
                c.isSurrogate() -> {
                    // Raw surrogates come only in valid pairs (a UTF-8 decode never makes lone ones).
                    if (!c.isHighSurrogate() || peek()?.isLowSurrogate() != true) return false
                    index++
                }
            }
        }
    }

    /** After a backslash: `uXXXX`, returning the code unit. */
    private fun hex(): Int? {
        if (peek() != 'u' || index + 5 > text.length) return null
        val digits = text.substring(index + 1, index + 5)
        if (!digits.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        index += 5
        return digits.toInt(16)
    }
}

/** A strict JSON object, or null for anything else (see [isStrictJsonObject]). */
internal fun strictJsonObject(text: String): JSONObject? =
    if (!isStrictJsonObject(text)) null else runCatching { JSONObject(text) }.getOrNull()

internal fun strictJsonObject(bytes: ByteArray): JSONObject? = strictJsonObject(bytes.toString(Charsets.UTF_8))

/**
 * An integral JSON number within +-(2^53 - 1), as the Mac reads one: 3, 3.0 and 3e0 are 3; 3.5, true,
 * "3" and larger numbers are not integers.
 */
internal fun jsonInteger(value: Any?): Long? {
    val number = value as? Number ?: return null
    val result = when (number) {
        is Int, is Long, is Short, is Byte -> number.toLong()
        is java.math.BigInteger -> if (number.bitLength() < 63) number.toLong() else return null
        else -> {
            val double = number.toDouble()
            if (!double.isFinite() || double != floor(double) || abs(double) > JSON_MAX_SAFE_INTEGER) return null
            double.toLong()
        }
    }
    return result.takeIf { abs(it) <= JSON_MAX_SAFE_INTEGER }
}

/** The last [capacity] accepted message IDs of one session, oldest evicted first. */
internal class ReplayWindow(private val capacity: Int = 256) {
    private val ids = LinkedHashSet<String>()

    val size: Int @Synchronized get() = ids.size

    /** False for an ID already in the window; otherwise remembers it. */
    @Synchronized fun accept(id: String): Boolean {
        if (!ids.add(id)) return false
        while (ids.size > capacity) ids.remove(ids.first())
        return true
    }
}

/**
 * Decodes one frame (without its LF) or throws [JSONException] when the frame must close the session:
 * not a strict JSON object, nested deeper than 32, `kind` missing or over 64 bytes, `sessionId` missing,
 * over 128 bytes or empty (except in `pairing.cancel`), or an envelope field of the wrong type. Unknown
 * fields are ignored; an empty optional string counts as absent.
 */
internal fun decodeProtocolMessage(line: String): Message {
    if (!isStrictJsonObject(line)) throw JSONException("not a strict JSON object")
    val json = JSONObject(line)
    fun string(name: String): String? = when (val value = json.opt(name)) {
        null, JSONObject.NULL -> null
        is String -> value
        else -> throw JSONException("$name is not a string")
    }
    fun optional(name: String): String? = string(name)?.takeIf(String::isNotEmpty)
    val kind = string("kind")?.takeIf { it.isNotEmpty() && it.toByteArray(Charsets.UTF_8).size <= 64 }
        ?: throw JSONException("invalid kind")
    val sessionId = string("sessionId")
        ?.takeIf { it.toByteArray(Charsets.UTF_8).size <= 128 && (it.isNotEmpty() || kind == "pairing.cancel") }
        ?: throw JSONException("invalid sessionId")
    val sequence = when (val value = json.opt("sequence")) {
        null, JSONObject.NULL -> null
        else -> jsonInteger(value) ?: throw JSONException("sequence is not an integer")
    }
    val protocolVersion = when (val value = json.opt("protocolVersion")) {
        null, JSONObject.NULL -> null
        else -> jsonInteger(value) ?: throw JSONException("protocolVersion is not an integer")
    }
    // pairing.cancel's reason is at most 32 bytes; a longer one closes the session like any bad envelope field.
    val reason = optional("reason")
    if (reason != null && reason.toByteArray(Charsets.UTF_8).size > 32) throw JSONException("reason over 32 bytes")
    return Message(
        kind = kind,
        sessionId = sessionId,
        deviceId = optional("deviceId"),
        deviceName = optional("deviceName"),
        publicKey = optional("publicKey"),
        identityKey = optional("identityKey"),
        proof = optional("proof"),
        signature = optional("signature"),
        messageId = optional("messageId"),
        nonce = optional("nonce"),
        ciphertext = optional("ciphertext"),
        transferId = optional("transferId"),
        sequence = sequence,
        targetDeviceId = optional("targetDeviceId"),
        commitment = optional("commitment"),
        protocolVersion = protocolVersion,
        tag = optional("tag"),
        reason = reason,
    )
}

/** What a received features.update means for the session. */
internal sealed interface FeatureStateDecoding {
    /** Close the session: not JSON, no `features` map, a missing original key or a non-boolean known key. */
    data object Invalid : FeatureStateDecoding

    /** A version this client does not know: keep the session and the previous state. */
    data object Ignored : FeatureStateDecoding

    /** The peer's feature map; [drafts] holds the draft keys this client knows. */
    data class State(val features: Map<BridgeyFeature, Boolean>, val drafts: Map<String, Boolean>) : FeatureStateDecoding
}

/**
 * Draft feature keys this client reads from features.update. Files 2.0: the phone acts on folders_receive_draft1
 * (the Mac accepts folders); files_browse_draft1 is read too, so both platforms decode the golden vectors alike.
 * Automation (v0.9): mac_actions_draft1, links_open_draft1, focus_sync_draft1 and camera_draft1. Update all:
 * updates_draft1. Screen sharing (v0.9): screen_draft1, a switch here like the camera. Text messages: sms_draft1
 * (a switch here too). Settings sync (v0.10): settings_sync_draft1. Connect anywhere: connect_draft1. Fast transfers:
 * files_fast_draft1. Codes from email: email_codes_draft1, last. Connection health has no key (no wire change). The Mac
 * has the same list in the same order.
 */
internal val KNOWN_DRAFT_FEATURE_KEYS = listOf(
    CLIPBOARD_FILES_FEATURE_KEY, FOLDERS_FEATURE_KEY, PLACES_FEATURE_KEY, SMS_CODES_FEATURE_KEY,
    FOLDERS_RECEIVE_FEATURE_KEY, FILES_BROWSE_FEATURE_KEY,
    BridgeyFeature.MAC_ACTIONS.key, LINKS_OPEN_FEATURE_KEY, FOCUS_SYNC_FEATURE_KEY, CAMERA_FEATURE_KEY,
    UPDATES_FEATURE_KEY,
    dev.bridgey.android.screen.SCREEN_FEATURE_KEY,
    SMS_FEATURE_KEY,
    SETTINGS_SYNC_FEATURE_KEY,
    dev.bridgey.android.connect.CONNECT_FEATURE_KEY,
    // Fast transfers (FastTransfer.kt).
    FILES_FAST_FEATURE_KEY,
    // Codes from email (docs/codes-from-email.md).
    dev.bridgey.android.codes.EMAIL_CODES_FEATURE_KEY,
)

internal fun decodeFeatureState(plaintext: ByteArray): FeatureStateDecoding {
    val payload = strictJsonObject(plaintext) ?: return FeatureStateDecoding.Invalid
    val values = payload.opt("features") as? JSONObject ?: return FeatureStateDecoding.Invalid
    if (jsonInteger(payload.opt("version")) != 1L) return FeatureStateDecoding.Ignored
    val features = HashMap<BridgeyFeature, Boolean>()
    for (feature in BridgeyFeature.entries) {
        // A draft key that is also a switch here (Mac actions, camera) reads like every draft key: true only
        // when it is JSON true. The Mac keeps camera_draft1 as a draft key only, so both decode it alike.
        if (feature.key in KNOWN_DRAFT_FEATURE_KEYS) {
            features[feature] = values.opt(feature.key) == true
            continue
        }
        if (!values.has(feature.key)) {
            if (featureEnabledByLegacyPeer(feature)) return FeatureStateDecoding.Invalid
            features[feature] = false
            continue
        }
        features[feature] = values.opt(feature.key) as? Boolean ?: return FeatureStateDecoding.Invalid
    }
    val drafts = KNOWN_DRAFT_FEATURE_KEYS.associateWith { values.opt(it) == true }
    return FeatureStateDecoding.State(features, drafts)
}

/** A battery.update payload, or null when malformed or out of range. */
internal fun decodeBatteryStatus(plaintext: ByteArray): RemoteBatteryStatus? {
    val payload = strictJsonObject(plaintext) ?: return null
    val level = jsonInteger(payload.opt("level"))?.takeIf { it in 0..100 } ?: return null
    val charging = payload.opt("isCharging") as? Boolean ?: return null
    return RemoteBatteryStatus(level.toInt(), charging)
}
