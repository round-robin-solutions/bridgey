package dev.bridgey.android.display

import dev.bridgey.android.jsonInteger
import dev.bridgey.android.screen.ScreenFrameCodec
import dev.bridgey.android.screen.ScreenFrameHeader
import dev.bridgey.android.screen.canonicalUuid
import dev.bridgey.android.strictJsonObject
import org.json.JSONObject

/*
 * Mac screen to phone (draft screen_control_draft1, docs/protocol.md "Mac screen to phone"): the viewer's side of the
 * wire. Pure Kotlin and org.json, checked against protocol/test-vectors/display-v1.json. The kinds themselves are in
 * DisplayKinds; here every decoder is named after what it reads.
 */

/** Same key as BridgeyFeature.SCREEN_CONTROL. */
const val SCREEN_CONTROL_FEATURE_KEY = "screen_control_draft1"

object DisplayLimits {
    const val REQUEST_MAX_BYTES = 1_024
    const val START_MAX_BYTES = 2_048
    const val MESSAGE_MAX_BYTES = 512
    const val INPUT_MAX_BYTES = ScreenControl.MAX_PACKET_BYTES
    const val DISPLAY_NAME_MAX_BYTES = 64
    const val MIN_SIDE = 16
    const val MAX_FPS = 60
    const val MIN_BITRATE = 100_000L
    const val MAX_BITRATE = 50_000_000L
    const val MAX_FRAME_NUMBER = 4_294_967_295L
    const val MAX_MILLIS = 60_000L

    /** One open request per Mac, at most one every 3 seconds; it expires after 2 minutes. */
    const val REQUEST_SPACING_MILLIS = 3_000L
    const val REQUEST_LIFETIME_MILLIS = 120_000L

    /** The viewer stops after 6 seconds without a frame or stats. */
    const val STREAM_TIMEOUT_MILLIS = 6_000L
    const val REMEMBERED_STREAMS = 16

    /** The long side of the stream is at most this many pixels. */
    const val MAX_LONG_SIDE = 1_920
}

enum class DisplayStatus(val wire: String) {
    WAITING("waiting"),
    DECLINED("declined"),
    BUSY("busy"),
    DISABLED("disabled"),
    PERMISSION("permission"),
    LOCKED("locked"),
    FAILED("failed"),
    ;

    companion object {
        fun fromWire(value: Any?): DisplayStatus? = entries.firstOrNull { it.wire == value }
    }
}

enum class DisplayStopReason(val wire: String) {
    USER("user"),
    LEFT_SCREEN("left_screen"),
    SCREEN_OFF("screen_off"),
    LOCAL_STOP("local_stop"),
    DISABLED("disabled"),
    PERMISSION("permission"),
    LOCKED("locked"),
    SOURCE_CHANGED("source_changed"),
    INVALID("invalid"),
    TIMEOUT("timeout"),
    FAILED("failed"),
    ;

    companion object {
        /** An unknown or missing reason reads as failed. */
        fun fromWire(value: Any?): DisplayStopReason = entries.firstOrNull { it.wire == value } ?: FAILED
    }
}

enum class DisplayControlState(val wire: String) {
    ACTIVE("active"),
    ENDED("ended"),
    REFUSED("refused"),
    ;

    companion object {
        fun fromWire(value: Any?): DisplayControlState? = entries.firstOrNull { it.wire == value }
    }
}

enum class DisplayControlAction(val wire: String) {
    BEGIN("begin"),
    END("end"),
}

enum class DisplayControlReason(val wire: String) {
    USER("user"),
    LOCAL_STOP("local_stop"),
    DISABLED("disabled"),
    PERMISSION("permission"),
    LOCKED("locked"),
    BUSY("busy"),
    FOCUS("focus"),
    TIMEOUT("timeout"),
    RATE("rate"),
    INVALID("invalid"),
    SOURCE_CHANGED("source_changed"),
    FAILED("failed"),
    ;

    companion object {
        /** An unknown or missing reason reads as failed. */
        fun fromWire(value: Any?): DisplayControlReason = entries.firstOrNull { it.wire == value } ?: FAILED
    }
}

/** The capabilities this phone sends: an H.264 viewer that controls with a pointer, keys and text. */
fun viewerCapabilities(h264Decode: Boolean = true): Capabilities = Capabilities(
    screenViewer = true,
    h264Decode = h264Decode,
    inputController = InputCapabilities(pointer = true, keys = true, text = true),
)

private fun displayObject(plaintext: ByteArray, limit: Int): JSONObject? {
    if (plaintext.size > limit) return null
    val json = strictJsonObject(plaintext) ?: return null
    return json.takeIf { jsonInteger(it.opt("version")) == 1L }
}

/** The stream ID and the sender's sequence every stream message carries. */
private fun streamHeader(json: JSONObject): Pair<String, Long>? {
    val streamId = canonicalUuid(json.opt("streamId")) ?: return null
    val sequence = jsonInteger(json.opt("sequence"))?.takeIf { it in 1..ScreenControl.MAX_SEQUENCE } ?: return null
    return streamId to sequence
}

private fun counter(value: Any?): Long? = jsonInteger(value)?.takeIf(ScreenControl::validCounter)

/** A geometry the stream may use: valid, a display, even sides of at least 16 pixels. */
fun streamGeometry(value: Any?): Geometry? {
    val geometry = (value as? JSONObject)?.let(Geometry::fromJson) ?: return null
    if (!geometry.valid() || geometry.kind != SourceKind.DISPLAY) return null
    if (geometry.width < DisplayLimits.MIN_SIDE || geometry.height < DisplayLimits.MIN_SIDE) return null
    if (geometry.width % 2 != 0 || geometry.height % 2 != 0) return null
    return geometry
}

// MARK: Asking

data class DisplayStatusMessage(val requestId: String, val status: DisplayStatus)

/** The answer to this phone's request; null when malformed or the status is unknown (dropped). */
fun decodeDisplayStatus(plaintext: ByteArray): DisplayStatusMessage? {
    val json = displayObject(plaintext, DisplayLimits.MESSAGE_MAX_BYTES) ?: return null
    val requestId = canonicalUuid(json.opt("requestId")) ?: return null
    val status = DisplayStatus.fromWire(json.opt("status")) ?: return null
    return DisplayStatusMessage(requestId, status)
}

fun displayRequestPayload(requestId: String, capabilities: Capabilities = viewerCapabilities()): JSONObject =
    JSONObject().put("version", 1).put("requestId", requestId).put("capabilities", capabilities.toJson())

// MARK: The stream

data class DisplayStart(
    val streamId: String,
    val sequence: Long,
    val requestId: String,
    val fps: Int,
    val bitrate: Long,
    val stream: Long,
    val transport: Long,
    val geometry: Geometry,
    val capabilities: Capabilities,
    /** Control may be asked for now. */
    val control: Boolean,
    val displayName: String?,
)

/** A display.start from the Mac; null when any field breaks the rules (the phone refuses it with `invalid`). */
fun decodeDisplayStart(plaintext: ByteArray): DisplayStart? {
    val json = displayObject(plaintext, DisplayLimits.START_MAX_BYTES) ?: return null
    val (streamId, sequence) = streamHeader(json) ?: return null
    val requestId = canonicalUuid(json.opt("requestId")) ?: return null
    if (json.opt("codec") != "h264") return null
    val fps = jsonInteger(json.opt("fps"))?.takeIf { it in 1..DisplayLimits.MAX_FPS } ?: return null
    val bitrate = jsonInteger(json.opt("bitrate"))?.takeIf { it in DisplayLimits.MIN_BITRATE..DisplayLimits.MAX_BITRATE } ?: return null
    val stream = counter(json.opt("stream")) ?: return null
    val transport = counter(json.opt("transport")) ?: return null
    val geometry = streamGeometry(json.opt("geometry")) ?: return null
    val capabilities = (json.opt("capabilities") as? JSONObject)?.let(Capabilities::fromJson) ?: return null
    val control = json.opt("control") as? Boolean ?: return null
    val displayName = when (val value = json.opt("displayName")) {
        null, JSONObject.NULL -> null
        is String -> value.takeIf { it.toByteArray(Charsets.UTF_8).size <= DisplayLimits.DISPLAY_NAME_MAX_BYTES } ?: return null
        else -> return null
    }
    return DisplayStart(streamId, sequence, requestId, fps.toInt(), bitrate, stream, transport, geometry, capabilities, control, displayName)
}

/** The stream a start that failed validation names, so the phone can answer `invalid`. */
fun displayStartStreamId(plaintext: ByteArray): String? {
    if (plaintext.size > DisplayLimits.START_MAX_BYTES) return null
    return canonicalUuid(strictJsonObject(plaintext)?.opt("streamId"))
}

/** What the Mac sends on a stream after display.start. */
sealed interface DisplaySourceMessage {
    val streamId: String
    val sequence: Long

    data class Stats(
        override val streamId: String,
        override val sequence: Long,
        val latencyMs: Long,
        val rttMs: Long,
        val bitrate: Long,
        val sentBitrate: Long,
        val fps: Int,
        val dropped: Int,
    ) : DisplaySourceMessage

    data class GeometryChanged(override val streamId: String, override val sequence: Long, val geometry: Geometry) : DisplaySourceMessage

    data class Control(
        override val streamId: String,
        override val sequence: Long,
        val state: DisplayControlState,
        /** With [DisplayControlState.ACTIVE]. */
        val session: Long?,
        /** The negotiated input, with [DisplayControlState.ACTIVE]. */
        val input: InputCapabilities?,
        /** With ended or refused. */
        val reason: DisplayControlReason?,
    ) : DisplaySourceMessage

    data class Stop(override val streamId: String, override val sequence: Long, val reason: DisplayStopReason) : DisplaySourceMessage
}

fun decodeDisplayStats(plaintext: ByteArray): DisplaySourceMessage.Stats? {
    val json = displayObject(plaintext, DisplayLimits.MESSAGE_MAX_BYTES) ?: return null
    val (streamId, sequence) = streamHeader(json) ?: return null
    fun bounded(name: String, max: Long) = jsonInteger(json.opt(name))?.takeIf { it in 0..max }
    return DisplaySourceMessage.Stats(
        streamId, sequence,
        latencyMs = bounded("latencyMs", DisplayLimits.MAX_MILLIS) ?: return null,
        rttMs = bounded("rttMs", DisplayLimits.MAX_MILLIS) ?: return null,
        bitrate = bounded("bitrate", DisplayLimits.MAX_BITRATE) ?: return null,
        sentBitrate = bounded("sentBitrate", DisplayLimits.MAX_BITRATE) ?: return null,
        fps = bounded("fps", 120)?.toInt() ?: return null,
        dropped = bounded("dropped", 1_000)?.toInt() ?: return null,
    )
}

fun decodeDisplayGeometry(plaintext: ByteArray): DisplaySourceMessage.GeometryChanged? {
    val json = displayObject(plaintext, DisplayLimits.MESSAGE_MAX_BYTES) ?: return null
    val (streamId, sequence) = streamHeader(json) ?: return null
    return DisplaySourceMessage.GeometryChanged(streamId, sequence, streamGeometry(json.opt("geometry")) ?: return null)
}

/** The Mac's form of display.control: `state` (a viewer's `action` is not read here). */
fun decodeDisplayControlFromSource(plaintext: ByteArray): DisplaySourceMessage.Control? {
    val json = displayObject(plaintext, DisplayLimits.MESSAGE_MAX_BYTES) ?: return null
    val (streamId, sequence) = streamHeader(json) ?: return null
    return when (val state = DisplayControlState.fromWire(json.opt("state")) ?: return null) {
        DisplayControlState.ACTIVE -> {
            val session = counter(json.opt("session")) ?: return null
            val input = (json.opt("input") as? JSONObject)?.let(InputCapabilities::fromJson) ?: return null
            DisplaySourceMessage.Control(streamId, sequence, state, session, input, null)
        }
        DisplayControlState.ENDED, DisplayControlState.REFUSED ->
            DisplaySourceMessage.Control(streamId, sequence, state, null, null, DisplayControlReason.fromWire(json.opt("reason")))
    }
}

/** display.stop from either side; an unknown or missing reason reads as failed. */
fun decodeDisplayStop(plaintext: ByteArray): DisplaySourceMessage.Stop? {
    val json = displayObject(plaintext, DisplayLimits.MESSAGE_MAX_BYTES) ?: return null
    val (streamId, sequence) = streamHeader(json) ?: return null
    return DisplaySourceMessage.Stop(streamId, sequence, DisplayStopReason.fromWire(json.opt("reason")))
}

/** A display.frame plaintext: the screen.frame layout, header and payload; null when it breaks a rule. */
fun decodeDisplayFrame(plaintext: ByteArray): Pair<ScreenFrameHeader, ByteArray>? = ScreenFrameCodec.decode(plaintext)

private fun streamBase(streamId: String, sequence: Long): JSONObject =
    JSONObject().put("version", 1).put("streamId", streamId).put("sequence", sequence)

fun displayStartedPayload(streamId: String, sequence: Long): JSONObject = streamBase(streamId, sequence)

/** `keyframe` is written only when true. */
fun displayAckPayload(streamId: String, sequence: Long, frame: Long, decodeMs: Long, keyframe: Boolean): JSONObject =
    streamBase(streamId, sequence).put("frame", frame).put("decodeMs", decodeMs.coerceIn(0, DisplayLimits.MAX_MILLIS)).apply {
        if (keyframe) put("keyframe", true)
    }

fun displayControlPayload(streamId: String, sequence: Long, action: DisplayControlAction): JSONObject =
    streamBase(streamId, sequence).put("action", action.wire)

fun displayStopPayload(streamId: String, sequence: Long, reason: DisplayStopReason): JSONObject =
    streamBase(streamId, sequence).put("reason", reason.wire)

// MARK: Geometry rules

/** The captured size for a display of this many native pixels: aspect kept, long side at most 1,920, even sides. */
fun displayCaptureSize(nativeWidth: Int, nativeHeight: Int): Pair<Int, Int> {
    val scale = minOf(1.0, DisplayLimits.MAX_LONG_SIDE.toDouble() / maxOf(nativeWidth, nativeHeight).coerceAtLeast(1))
    fun side(value: Int) = maxOf(DisplayLimits.MIN_SIDE, (Math.floor(value * scale / 2) * 2).toInt())
    return side(nativeWidth) to side(nativeHeight)
}

/** Where the picture sits in a view: letterboxed, centred. */
data class ContentRect(val left: Double, val top: Double, val width: Double, val height: Double) {
    val right: Double get() = left + width
    val bottom: Double get() = top + height
}

/** The picture of [videoWidth] by [videoHeight] fitted into a view of [viewWidth] by [viewHeight] pixels. */
fun letterboxRect(viewWidth: Double, viewHeight: Double, videoWidth: Int, videoHeight: Int): ContentRect {
    if (viewWidth <= 0 || viewHeight <= 0 || videoWidth <= 0 || videoHeight <= 0) return ContentRect(0.0, 0.0, 0.0, 0.0)
    val k = minOf(viewWidth / videoWidth, viewHeight / videoHeight)
    val width = videoWidth * k
    val height = videoHeight * k
    return ContentRect((viewWidth - width) / 2, (viewHeight - height) / 2, width, height)
}

/** A touch at ([x], [y]) in the view as fractions of the full picture; null on the letterbox (it sends nothing). */
fun letterboxFraction(rect: ContentRect, x: Double, y: Double): Pair<Double, Double>? {
    if (rect.width <= 0 || rect.height <= 0) return null
    val fx = (x - rect.left) / rect.width
    val fy = (y - rect.top) / rect.height
    if (!fx.isFinite() || !fy.isFinite() || fx !in 0.0..1.0 || fy !in 0.0..1.0) return null
    return fx to fy
}

/** The same for a drag that started on the picture: kept on its edge instead of ending the gesture. */
fun letterboxFractionClamped(rect: ContentRect, x: Double, y: Double): Pair<Double, Double>? {
    if (rect.width <= 0 || rect.height <= 0) return null
    val fx = ((x - rect.left) / rect.width).takeIf { it.isFinite() } ?: return null
    val fy = ((y - rect.top) / rect.height).takeIf { it.isFinite() } ?: return null
    return fx.coerceIn(0.0, 1.0) to fy.coerceIn(0.0, 1.0)
}
