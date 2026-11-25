package dev.bridgey.android.control

import dev.bridgey.android.display.Capabilities
import dev.bridgey.android.display.Geometry
import dev.bridgey.android.display.InputCapabilities
import dev.bridgey.android.display.ScreenControl
import dev.bridgey.android.display.SourceKind
import dev.bridgey.android.jsonInteger
import dev.bridgey.android.screen.canonicalUuid
import dev.bridgey.android.strictJsonObject
import org.json.JSONObject

/*
 * The Mac controls the phone (draft phone_control_draft1, docs/protocol.md "Mac controls the phone"): the phone's side of
 * the wire, inside a screen_draft1 stream. Pure Kotlin and org.json, checked against protocol/test-vectors/phone-control-v1.json.
 * The input packets themselves are the shared contract's (ScreenControlContract.kt), checked by the host reducer.
 */

/** Gates screen.geometry, screen.control, screen.input and the control object of screen.start, with screen_draft1. */
const val PHONE_CONTROL_FEATURE_KEY = "phone_control_draft1"

object PhoneControlLimits {
    const val MESSAGE_MAX_BYTES = 512
    const val INPUT_MAX_BYTES = ScreenControl.MAX_PACKET_BYTES

    /** Ask each time: the prompt on the phone expires after a minute (refused, declined). */
    const val PROMPT_LIFETIME_MILLIS = 60_000L

    /** Typing works through the accessibility input method from Android 13. */
    const val TYPING_SDK = 33
}

enum class PhoneControlState(val wire: String) {
    WAITING("waiting"),
    ACTIVE("active"),
    ENDED("ended"),
    REFUSED("refused"),
    AVAILABLE("available"),
}

enum class PhoneControlAction(val wire: String) {
    BEGIN("begin"),
    END("end"),
    ;

    companion object {
        fun fromWire(value: Any?): PhoneControlAction? = entries.firstOrNull { it.wire == value }
    }
}

enum class PhoneControlReason(val wire: String) {
    USER("user"),
    LOCAL_STOP("local_stop"),
    DECLINED("declined"),
    DISABLED("disabled"),
    PERMISSION("permission"),
    LOCKED("locked"),
    FOCUS("focus"),
    TIMEOUT("timeout"),
    RATE("rate"),
    INVALID("invalid"),
    SOURCE_CHANGED("source_changed"),
    FAILED("failed"),
    ;

    companion object {
        /** An unknown or missing reason reads as failed. */
        fun fromWire(value: Any?): PhoneControlReason = entries.firstOrNull { it.wire == value } ?: FAILED
    }
}

/**
 * What this phone can do as a source and input host: full-display H.264 capture behind Android's prompt, touch, a
 * pointer (for scrolling) and navigation; keys and text only from Android 13. Support, never permission.
 */
fun phoneHostCapabilities(sdkInt: Int): Capabilities {
    val typing = sdkInt >= PhoneControlLimits.TYPING_SDK
    return Capabilities(
        screenSource = true,
        fullDisplaySource = true,
        h264Encode = true,
        captureRequiresPrompt = true,
        inputHost = InputCapabilities(pointer = true, touch = true, keys = typing, text = typing, navigation = true),
    )
}

/** The control object of a control-capable screen.start. */
data class PhoneControlOffer(
    val stream: Long,
    val transport: Long,
    val geometry: Geometry,
    val capabilities: Capabilities,
    /** Control may be asked for now: the accessibility service is on. */
    val allowed: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("stream", stream)
        .put("transport", transport)
        .put("geometry", geometry.toJson())
        .put("capabilities", capabilities.toJson())
        .put("allowed", allowed)
}

/** The contract geometry of the phone's stream: Android's display ID plus one, the stream's size. */
fun phoneStreamGeometry(generation: Long, displayId: Int, width: Int, height: Int): Geometry =
    Geometry(generation, displayId.toLong() + 1, SourceKind.DISPLAY, width, height)

private fun streamBase(streamId: String, sequence: Long): JSONObject =
    JSONObject().put("version", 1).put("streamId", streamId).put("sequence", sequence)

fun screenGeometryPayload(streamId: String, sequence: Long, geometry: Geometry): JSONObject =
    streamBase(streamId, sequence).put("geometry", geometry.toJson())

/** screen.control from this phone. Each state carries only its own fields. */
sealed interface PhoneControlUpdate {
    data object Waiting : PhoneControlUpdate
    data class Active(val session: Long, val input: InputCapabilities) : PhoneControlUpdate
    data class Ended(val reason: PhoneControlReason) : PhoneControlUpdate
    data class Refused(val reason: PhoneControlReason) : PhoneControlUpdate
    data class Available(val allowed: Boolean) : PhoneControlUpdate
}

fun phoneControlPayload(streamId: String, sequence: Long, update: PhoneControlUpdate): JSONObject {
    val json = streamBase(streamId, sequence)
    when (update) {
        PhoneControlUpdate.Waiting -> json.put("state", PhoneControlState.WAITING.wire)
        is PhoneControlUpdate.Active -> json.put("state", PhoneControlState.ACTIVE.wire).put("session", update.session).put("input", update.input.toJson())
        is PhoneControlUpdate.Ended -> json.put("state", PhoneControlState.ENDED.wire).put("reason", update.reason.wire)
        is PhoneControlUpdate.Refused -> json.put("state", PhoneControlState.REFUSED.wire).put("reason", update.reason.wire)
        is PhoneControlUpdate.Available -> json.put("state", PhoneControlState.AVAILABLE.wire).put("allowed", update.allowed)
    }
    return json
}

/** screen.control from the Mac; [capabilities] with begin (the Mac's contract capabilities). */
data class MacControlMessage(val streamId: String, val sequence: Long, val action: PhoneControlAction, val capabilities: Capabilities? = null)

/**
 * Null for anything malformed (dropped, never answered): over 512 bytes, version not 1, an unknown action, a begin without
 * valid capabilities.
 */
fun decodeMacControl(plaintext: ByteArray): MacControlMessage? {
    if (plaintext.size > PhoneControlLimits.MESSAGE_MAX_BYTES) return null
    val json = strictJsonObject(plaintext) ?: return null
    if (jsonInteger(json.opt("version")) != 1L) return null
    val streamId = canonicalUuid(json.opt("streamId")) ?: return null
    val sequence = jsonInteger(json.opt("sequence"))?.takeIf { it in 1..ScreenControl.MAX_SEQUENCE } ?: return null
    return when (PhoneControlAction.fromWire(json.opt("action")) ?: return null) {
        PhoneControlAction.BEGIN -> {
            val capabilities = (json.opt("capabilities") as? JSONObject)?.let(Capabilities::fromJson) ?: return null
            MacControlMessage(streamId, sequence, PhoneControlAction.BEGIN, capabilities)
        }
        PhoneControlAction.END -> MacControlMessage(streamId, sequence, PhoneControlAction.END)
    }
}

/** A point on the phone's display, in its current rotation's pixels. */
data class DisplayPoint(val x: Double, val y: Double)

/** Where Android mirrors a display of [displayWidth] by [displayHeight] inside the stream: aspect kept, centred, as AOSP does. */
data class MirrorRect(val left: Int, val top: Int, val width: Int, val height: Int)

fun mirrorRect(geometry: Geometry, displayWidth: Int, displayHeight: Int): MirrorRect {
    val w = geometry.width.toLong()
    val h = geometry.height.toLong()
    val (cw, ch) = if (w * displayHeight < h * displayWidth) w to displayHeight * w / displayWidth else displayWidth * h / displayHeight to h
    return MirrorRect(((w - cw) / 2).toInt(), ((h - ch) / 2).toInt(), cw.toInt(), ch.toInt())
}

/**
 * A contract position on the phone's display: the captured pixel (Geometry.pixel), then its centre mapped back through
 * Android's mirroring onto the real display of [displayWidth] by [displayHeight] pixels. Null outside [0, 1]; never
 * outside the display (a point on a mirroring bar lands on the display's edge).
 */
fun phonePoint(geometry: Geometry, displayWidth: Int, displayHeight: Int, x: Double, y: Double): DisplayPoint? {
    if (displayWidth <= 0 || displayHeight <= 0) return null
    val pixel = geometry.pixel(x, y) ?: return null
    val mirror = mirrorRect(geometry, displayWidth, displayHeight)
    if (mirror.width <= 0 || mirror.height <= 0) return null
    val px = ((pixel.x + 0.5 - mirror.left) * displayWidth / mirror.width).coerceIn(0.0, displayWidth - 1.0)
    val py = ((pixel.y + 0.5 - mirror.top) * displayHeight / mirror.height).coerceIn(0.0, displayHeight - 1.0)
    return DisplayPoint(px, py)
}

/** Stream pixels the content moves, as display pixels the finger moves. */
fun scrollDelta(geometry: Geometry, displayWidth: Int, displayHeight: Int, dx: Int, dy: Int): DisplayPoint {
    val mirror = mirrorRect(geometry, displayWidth, displayHeight)
    if (mirror.width <= 0 || mirror.height <= 0) return DisplayPoint(0.0, 0.0)
    return DisplayPoint(dx.toDouble() * displayWidth / mirror.width, dy.toDouble() * displayHeight / mirror.height)
}

/**
 * Another display than the default one is on (an external screen, desktop mode): Bridgey cannot tell which display a
 * focused editor is on, so typing is refused. Bridgey's own capture display is not counted.
 */
fun otherDisplayActive(displays: android.hardware.display.DisplayManager?): Boolean =
    displays?.displays.orEmpty().any { display ->
        display.displayId != android.view.Display.DEFAULT_DISPLAY && display.name != "Bridgey screen" &&
            display.state != android.view.Display.STATE_OFF && display.flags and android.view.Display.FLAG_PRIVATE == 0
    }
