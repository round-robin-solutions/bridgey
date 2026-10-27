package dev.bridgey.android.screen

import dev.bridgey.android.JSON_MAX_SAFE_INTEGER
import dev.bridgey.android.jsonInteger
import dev.bridgey.android.strictJsonObject
import java.nio.ByteBuffer
import java.util.UUID
import org.json.JSONObject

/*
 * Phone screen to Mac (draft screen_draft1, docs/protocol.md "Phone screen to Mac"): the wire side.
 * Pure Kotlin and org.json, so every rule is tested on the JVM against the golden vectors.
 */

/** Same key as BridgeyFeature.SCREEN. */
const val SCREEN_FEATURE_KEY = "screen_draft1"

object ScreenKinds {
    const val REQUEST = "screen.request"
    const val STATUS = "screen.status"
    const val START = "screen.start"
    const val STARTED = "screen.started"
    const val FRAME = "screen.frame"
    const val ACK = "screen.ack"
    const val STATS = "screen.stats"
    const val STOP = "screen.stop"
}

object ScreenLimits {
    /** screen.request, screen.status and every stream message but screen.start. */
    const val MESSAGE_MAX_BYTES = 512
    const val START_MAX_BYTES = 1_024
    const val HEADER_BYTES = 40
    const val PART_MAX_BYTES = 32_768
    const val FRAME_MAX_PLAINTEXT_BYTES = HEADER_BYTES + PART_MAX_BYTES
    const val MAX_PARTS = 64
    const val MAX_FRAME_NUMBER = 4_294_967_295L
    const val MAX_SEQUENCE = JSON_MAX_SAFE_INTEGER
    const val MAX_MILLIS = 60_000L
    const val MAX_BITRATE = 50_000_000L
    const val MIN_START_BITRATE = 100_000L

    /** One open request per Mac, at most one every 3 seconds; it expires after 2 minutes. */
    const val REQUEST_SPACING_MILLIS = 3_000L
    const val REQUEST_LIFETIME_MILLIS = 120_000L

    /** The phone gives up after 5 seconds without screen.started, or 6 seconds without an ack while frames are out. */
    const val STARTED_TIMEOUT_MILLIS = 5_000L
    const val ACK_TIMEOUT_MILLIS = 6_000L
}

enum class ScreenStatus(val wire: String) {
    WAITING("waiting"),
    DECLINED("declined"),
    BUSY("busy"),
    DISABLED("disabled"),
    FAILED("failed"),
}

enum class ScreenStopReason(val wire: String) {
    USER("user"),
    CLOSED("closed"),
    ENDED("ended"),
    SCREEN_OFF("screen_off"),
    DISABLED("disabled"),
    INVALID("invalid"),
    TIMEOUT("timeout"),
    FAILED("failed"),
    ;

    companion object {
        /** An unknown or missing reason reads as failed. */
        fun fromWire(value: Any?): ScreenStopReason = entries.firstOrNull { it.wire == value } ?: FAILED
    }
}

/** A UUID string in canonical 8-4-4-4-12 form, lowercased; null otherwise. */
internal fun canonicalUuid(value: Any?): String? {
    val text = value as? String ?: return null
    if (text.length != 36) return null
    return runCatching { UUID.fromString(text) }.getOrNull()?.takeIf { it.toString().equals(text, ignoreCase = true) }?.toString()
}

/** The requestId of a well-formed screen.request plaintext, lowercased; null when malformed. */
fun decodeScreenRequest(plaintext: ByteArray): String? {
    if (plaintext.size > ScreenLimits.MESSAGE_MAX_BYTES) return null
    val json = strictJsonObject(plaintext) ?: return null
    if (jsonInteger(json.opt("version")) != 1L) return null
    return canonicalUuid(json.opt("requestId"))
}

fun screenStatusPayload(requestId: String, status: ScreenStatus): JSONObject =
    JSONObject().put("version", 1).put("requestId", requestId).put("status", status.wire)

/** What the Mac sends on a stream, decoded. */
sealed interface ScreenMacMessage {
    val streamId: String
    val sequence: Long

    data class Started(override val streamId: String, override val sequence: Long) : ScreenMacMessage

    data class Ack(override val streamId: String, override val sequence: Long, val frame: Long, val decodeMs: Long, val keyframe: Boolean) : ScreenMacMessage

    data class Stop(override val streamId: String, override val sequence: Long, val reason: ScreenStopReason) : ScreenMacMessage
}

/** screen.started, screen.ack or screen.stop from the Mac; null for anything malformed (dropped, never answered). */
fun decodeScreenMacMessage(kind: String, plaintext: ByteArray): ScreenMacMessage? {
    if (plaintext.size > ScreenLimits.MESSAGE_MAX_BYTES) return null
    val json = strictJsonObject(plaintext) ?: return null
    if (jsonInteger(json.opt("version")) != 1L) return null
    val streamId = canonicalUuid(json.opt("streamId")) ?: return null
    val sequence = jsonInteger(json.opt("sequence"))?.takeIf { it in 1..ScreenLimits.MAX_SEQUENCE } ?: return null
    return when (kind) {
        ScreenKinds.STARTED -> ScreenMacMessage.Started(streamId, sequence)
        ScreenKinds.ACK -> {
            val frame = jsonInteger(json.opt("frame"))?.takeIf { it in 1..ScreenLimits.MAX_FRAME_NUMBER } ?: return null
            val decodeMs = jsonInteger(json.opt("decodeMs"))?.takeIf { it in 0..ScreenLimits.MAX_MILLIS } ?: return null
            val keyframe = when (val value = json.opt("keyframe")) {
                null, JSONObject.NULL -> false
                is Boolean -> value
                else -> return null
            }
            ScreenMacMessage.Ack(streamId, sequence, frame, decodeMs, keyframe)
        }
        ScreenKinds.STOP -> ScreenMacMessage.Stop(streamId, sequence, ScreenStopReason.fromWire(json.opt("reason")))
        else -> null
    }
}

/** What the phone puts in screen.start. */
data class ScreenStartInfo(val width: Int, val height: Int, val fps: Int, val bitrate: Long, val requestId: String? = null)

private fun streamBase(streamId: String, sequence: Long): JSONObject =
    JSONObject().put("version", 1).put("streamId", streamId).put("sequence", sequence)

fun screenStartPayload(streamId: String, sequence: Long, info: ScreenStartInfo): JSONObject =
    streamBase(streamId, sequence).apply {
        info.requestId?.let { put("requestId", it) }
        put("codec", "h264")
        put("width", info.width)
        put("height", info.height)
        put("fps", info.fps)
        put("bitrate", info.bitrate)
    }

/** One second of the phone's view of the stream, for screen.stats and the log. */
data class ScreenStats(
    val latencyMs: Long,
    val rttMs: Long,
    val bitrate: Long,
    val sentBitrate: Long,
    val fps: Int,
    val dropped: Int,
) {
    /** Clamped to the ranges the Mac accepts. */
    fun bounded(): ScreenStats = ScreenStats(
        latencyMs.coerceIn(0, ScreenLimits.MAX_MILLIS),
        rttMs.coerceIn(0, ScreenLimits.MAX_MILLIS),
        bitrate.coerceIn(0, ScreenLimits.MAX_BITRATE),
        sentBitrate.coerceIn(0, ScreenLimits.MAX_BITRATE),
        fps.coerceIn(0, 120),
        dropped.coerceIn(0, 1000),
    )
}

fun screenStatsPayload(streamId: String, sequence: Long, stats: ScreenStats): JSONObject {
    val s = stats.bounded()
    return streamBase(streamId, sequence)
        .put("latencyMs", s.latencyMs).put("rttMs", s.rttMs).put("bitrate", s.bitrate)
        .put("sentBitrate", s.sentBitrate).put("fps", s.fps).put("dropped", s.dropped)
}

fun screenStopPayload(streamId: String, sequence: Long, reason: ScreenStopReason): JSONObject =
    streamBase(streamId, sequence).put("reason", reason.wire)

/** The 40-byte binary header of one screen.frame part. */
data class ScreenFrameHeader(
    val streamId: String,
    val sequence: Long,
    val frame: Long,
    val part: Int,
    val key: Boolean,
    val parameterSets: Boolean,
    val last: Boolean,
    val captureMicros: Long,
) {
    val flags: Int get() = (if (key) 1 else 0) or (if (parameterSets) 2 else 0) or (if (last) 4 else 0)
}

object ScreenFrameCodec {
    /** Header then [payload] (1 to 32,768 bytes), big-endian, exactly as docs/protocol.md lays it out. */
    fun encode(header: ScreenFrameHeader, payload: ByteArray, offset: Int = 0, length: Int = payload.size - offset): ByteArray {
        require(length in 1..ScreenLimits.PART_MAX_BYTES && header.part in 0 until ScreenLimits.MAX_PARTS)
        val uuid = UUID.fromString(header.streamId)
        return ByteBuffer.allocate(ScreenLimits.HEADER_BYTES + length).apply {
            put(1.toByte())
            put(header.flags.toByte())
            putShort(header.part.toShort())
            putLong(uuid.mostSignificantBits)
            putLong(uuid.leastSignificantBits)
            putLong(header.sequence)
            putInt(header.frame.toInt())
            putLong(header.captureMicros)
            put(payload, offset, length)
        }.array()
    }

    /**
     * The header of a frame plaintext and where its payload starts, or null when it breaks a rule. The phone
     * never receives frames; this is the Mac's reader, kept here so the phone's writer is checked against it.
     */
    fun decode(plaintext: ByteArray): Pair<ScreenFrameHeader, ByteArray>? {
        if (plaintext.size !in ScreenLimits.HEADER_BYTES + 1..ScreenLimits.FRAME_MAX_PLAINTEXT_BYTES) return null
        val buffer = ByteBuffer.wrap(plaintext)
        if (buffer.get().toInt() != 1) return null
        val flags = buffer.get().toInt() and 0xFF
        val part = buffer.short.toInt() and 0xFFFF
        val streamId = UUID(buffer.long, buffer.long).toString()
        val sequence = buffer.long
        val frame = buffer.int.toLong() and 0xFFFF_FFFFL
        val capture = buffer.long
        if (part >= ScreenLimits.MAX_PARTS || sequence !in 1..ScreenLimits.MAX_SEQUENCE || frame < 1 || capture < 0) return null
        val payload = plaintext.copyOfRange(ScreenLimits.HEADER_BYTES, plaintext.size)
        if (part == 0 && AnnexB.startCodeLength(payload, 0) == 0) return null
        return ScreenFrameHeader(streamId, sequence, frame, part, flags and 1 != 0, flags and 2 != 0, flags and 4 != 0, capture) to payload
    }

    /** One access unit cut into parts of at most 32,768 bytes, each with its header. */
    fun parts(
        streamId: String,
        firstSequence: Long,
        frame: Long,
        key: Boolean,
        parameterSets: Boolean,
        captureMicros: Long,
        accessUnit: ByteArray,
    ): List<ByteArray> {
        require(accessUnit.isNotEmpty())
        val count = (accessUnit.size + ScreenLimits.PART_MAX_BYTES - 1) / ScreenLimits.PART_MAX_BYTES
        require(count <= ScreenLimits.MAX_PARTS) { "frame of ${accessUnit.size} bytes is over 64 parts" }
        return (0 until count).map { index ->
            val offset = index * ScreenLimits.PART_MAX_BYTES
            val length = minOf(ScreenLimits.PART_MAX_BYTES, accessUnit.size - offset)
            encode(
                ScreenFrameHeader(streamId, firstSequence + index, frame, index, key, parameterSets, index == count - 1, captureMicros),
                accessUnit, offset, length,
            )
        }
    }
}

/** Annex B helpers: start codes and NAL unit types. */
object AnnexB {
    /** 4 or 3 when a start code (00 00 00 01 or 00 00 01) begins at [index], else 0. */
    fun startCodeLength(data: ByteArray, index: Int): Int = when {
        index + 4 <= data.size && data[index] == 0.toByte() && data[index + 1] == 0.toByte() && data[index + 2] == 0.toByte() && data[index + 3] == 1.toByte() -> 4
        index + 3 <= data.size && data[index] == 0.toByte() && data[index + 1] == 0.toByte() && data[index + 2] == 1.toByte() -> 3
        else -> 0
    }

    /** The NAL unit types in an Annex B buffer, in order. */
    fun nalTypes(data: ByteArray): List<Int> {
        val types = mutableListOf<Int>()
        var i = 0
        while (i < data.size) {
            val length = startCodeLength(data, i)
            if (length > 0) {
                if (i + length < data.size) types += data[i + length].toInt() and 0x1F
                i += length
            } else {
                i++
            }
        }
        return types
    }

    /** The access unit starts with an SPS (type 7). */
    fun startsWithSps(data: ByteArray): Boolean = nalTypes(data).firstOrNull() == 7

    /** The buffer holds an IDR slice (type 5). */
    fun hasIdr(data: ByteArray): Boolean = 5 in nalTypes(data)
}
