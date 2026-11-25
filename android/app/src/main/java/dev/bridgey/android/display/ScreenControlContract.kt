package dev.bridgey.android.display

import dev.bridgey.android.strictJsonObject
import java.math.BigInteger
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.json.JSONArray
import org.json.JSONObject

/*
 * The shared screen/control contract (bridgey-screen-control-draft1, rust/proto/src/screen_control.rs and
 * docs/screen-control-core.md), the viewer and controller side only: capabilities, geometry and input packets with
 * the same decoding rules as the Rust reference, checked against rust/proto/test-vectors/screen-control-v1.json.
 * This phone is not an input host in this slice, so the host reducer is not ported here.
 */

object ScreenControl {
    const val PROTOCOL = "bridgey-screen-control-draft1"
    const val VERSION = 1
    const val MAX_SEQUENCE = 9_007_199_254_740_991L
    const val MAX_PACKET_BYTES = 2_048
    const val MAX_TEXT_BYTES = 1_024
    const val MAX_TEXT_SCALARS = 256
    const val IDLE_MILLIS = 6_000L
    const val MAX_DIMENSION = 32_768
    const val MAX_PIXELS = 67_108_864L
    const val MAX_CONTACTS = 10
    const val MAX_SCROLL = 1_000

    /** Token buckets the host applies; the controller keeps within them before assigning a sequence number. */
    const val MOTION_PER_SECOND = 120
    const val DISCRETE_PER_SECOND = 20
    const val CONTROL_PER_SECOND = 10
    const val HEARTBEAT_MILLIS = 2_000L

    const val CONNECTION_BYTES = 16
    private const val CONNECTION_LABEL = "bridgey-screen-control-connection-v1"

    fun validCounter(value: Long): Boolean = value in 1..MAX_SEQUENCE

    fun validCoordinate(value: Double): Boolean = value.isFinite() && value in 0.0..1.0

    /**
     * The 16-byte connection nonce both ends derive from the current session: HMAC-SHA256(session key, UTF-8 label,
     * 0x00, UTF-8 session ID), first 16 bytes. Every session has a fresh key, so it is never reused.
     */
    fun connectionNonce(sessionKey: ByteArray, sessionId: String): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(sessionKey, "HmacSHA256"))
        mac.update(CONNECTION_LABEL.toByteArray(Charsets.UTF_8))
        mac.update(0.toByte())
        return mac.doFinal(sessionId.toByteArray(Charsets.UTF_8)).copyOf(CONNECTION_BYTES)
    }

    /** Typed text the host accepts: 1 to 256 scalars, at most 1,024 UTF-8 bytes, no control characters. */
    fun validText(text: String): Boolean {
        if (text.isEmpty() || text.toByteArray(Charsets.UTF_8).size > MAX_TEXT_BYTES) return false
        var scalars = 0
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            if (Character.getType(codePoint) == Character.CONTROL.toInt()) return false
            // A lone surrogate is not a Unicode scalar.
            if (codePoint in 0xD800..0xDFFF) return false
            scalars++
            index += Character.charCount(codePoint)
        }
        return scalars <= MAX_TEXT_SCALARS
    }
}

/** A JSON integer as serde reads a Rust integer: no fraction or exponent form, within [min, max]. */
internal fun strictJsonLong(value: Any?, min: Long, max: Long): Long? {
    val result = when (value) {
        is Int -> value.toLong()
        is Long -> value
        is Short -> value.toLong()
        is Byte -> value.toLong()
        is BigInteger -> if (value.bitLength() < 64) value.toLong() else return null
        else -> return null
    }
    return result.takeIf { it in min..max }
}

/** A JSON number as serde reads an f64. */
internal fun jsonDouble(value: Any?): Double? = (value as? Number)?.toDouble()?.takeIf { it.isFinite() }

/** Every key of [json] is in [allowed] (serde deny_unknown_fields). */
private fun onlyKeys(json: JSONObject, allowed: Set<String>): Boolean = json.keys().asSequence().all { it in allowed }

/** Support for each input operation. Missing flags are false; unknown flags are ignored. */
data class InputCapabilities(
    val pointer: Boolean = false,
    val touch: Boolean = false,
    val keys: Boolean = false,
    val text: Boolean = false,
    val navigation: Boolean = false,
) {
    fun any(): Boolean = pointer || touch || keys || text || navigation

    fun intersect(other: InputCapabilities): InputCapabilities = InputCapabilities(
        pointer && other.pointer, touch && other.touch, keys && other.keys, text && other.text, navigation && other.navigation,
    )

    fun toJson(): JSONObject = JSONObject()
        .put("pointer", pointer).put("touch", touch).put("keys", keys).put("text", text).put("navigation", navigation)

    companion object {
        /** Null when a present flag is not a boolean (serde rejects it). */
        fun fromJson(json: JSONObject): InputCapabilities? {
            fun flag(name: String): Boolean? = if (!json.has(name)) false else json.opt(name) as? Boolean
            return InputCapabilities(
                flag("pointer") ?: return null,
                flag("touch") ?: return null,
                flag("keys") ?: return null,
                flag("text") ?: return null,
                flag("navigation") ?: return null,
            )
        }
    }
}

/** What a device can do as a screen source, viewer, input host or controller. Support, never permission. */
data class Capabilities(
    val v: Int = ScreenControl.VERSION,
    val screenSource: Boolean = false,
    val screenViewer: Boolean = false,
    val fullDisplaySource: Boolean = false,
    val h264Encode: Boolean = false,
    val h264Decode: Boolean = false,
    val inputHost: InputCapabilities = InputCapabilities(),
    val inputController: InputCapabilities = InputCapabilities(),
    val captureRequiresPrompt: Boolean = false,
    val captureRestoreSupported: Boolean = false,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("v", v)
        .put("screenSource", screenSource)
        .put("screenViewer", screenViewer)
        .put("fullDisplaySource", fullDisplaySource)
        .put("h264Encode", h264Encode)
        .put("h264Decode", h264Decode)
        .put("inputHost", inputHost.toJson())
        .put("inputController", inputController.toJson())
        .put("captureRequiresPrompt", captureRequiresPrompt)
        .put("captureRestoreSupported", captureRestoreSupported)

    companion object {
        /** The bytes of one capabilities object: at most 2,048 bytes, strict JSON, v 1. */
        fun decode(bytes: ByteArray): Capabilities? {
            if (bytes.size > ScreenControl.MAX_PACKET_BYTES) return null
            return fromJson(strictJsonObject(bytes) ?: return null)
        }

        /** Null for any v other than 1 (also a missing v), a non-boolean flag or a non-object input map. */
        fun fromJson(json: JSONObject): Capabilities? {
            if (strictJsonLong(json.opt("v"), 0, 255) != ScreenControl.VERSION.toLong()) return null
            fun flag(name: String): Boolean? = if (!json.has(name)) false else json.opt(name) as? Boolean
            fun inputs(name: String): InputCapabilities? =
                if (!json.has(name)) InputCapabilities() else (json.opt(name) as? JSONObject)?.let(InputCapabilities::fromJson)
            return Capabilities(
                v = ScreenControl.VERSION,
                screenSource = flag("screenSource") ?: return null,
                screenViewer = flag("screenViewer") ?: return null,
                fullDisplaySource = flag("fullDisplaySource") ?: return null,
                h264Encode = flag("h264Encode") ?: return null,
                h264Decode = flag("h264Decode") ?: return null,
                inputHost = inputs("inputHost") ?: return null,
                inputController = inputs("inputController") ?: return null,
                captureRequiresPrompt = flag("captureRequiresPrompt") ?: return null,
                captureRestoreSupported = flag("captureRestoreSupported") ?: return null,
            )
        }

        /**
         * The input both may use: the host must be a full-display H.264 source and the controller an H.264 viewer, and
         * at least one operation must be on both sides. Null otherwise (Unsupported).
         */
        fun negotiatedInput(host: Capabilities, controller: Capabilities): InputCapabilities? {
            if (host.v != ScreenControl.VERSION || controller.v != ScreenControl.VERSION) return null
            if (!host.screenSource || !host.fullDisplaySource || !host.h264Encode || !controller.screenViewer || !controller.h264Decode) return null
            return host.inputHost.intersect(controller.inputController).takeIf { it.any() }
        }
    }
}

enum class SourceKind(val wire: String) {
    DISPLAY("display"),
    WINDOW("window"),
    ;

    companion object {
        fun fromWire(value: Any?): SourceKind? = entries.firstOrNull { it.wire == value }
    }
}

/** A captured pixel. */
data class PixelPoint(val x: Int, val y: Int)

/** One host-selected source and its captured size, with a generation that increases on every change. */
data class Geometry(val generation: Long, val source: Long, val kind: SourceKind, val width: Int, val height: Int) {
    fun valid(): Boolean =
        ScreenControl.validCounter(generation) && ScreenControl.validCounter(source) &&
            width > 0 && height > 0 && width <= ScreenControl.MAX_DIMENSION && height <= ScreenControl.MAX_DIMENSION &&
            width.toLong() * height.toLong() <= ScreenControl.MAX_PIXELS

    /** Fractions of the full captured source (letterbox already removed) to a captured pixel; null outside [0, 1]. */
    fun pixel(x: Double, y: Double): PixelPoint? {
        if (!valid() || !ScreenControl.validCoordinate(x) || !ScreenControl.validCoordinate(y)) return null
        // Round half away from zero, as Rust's f64::round; the values are never negative here.
        return PixelPoint(Math.round(x * (width - 1)).toInt(), Math.round(y * (height - 1)).toInt())
    }

    fun toJson(): JSONObject = JSONObject()
        .put("generation", generation).put("source", source).put("kind", kind.wire).put("width", width).put("height", height)

    companion object {
        private val FIELDS = setOf("generation", "source", "kind", "width", "height")

        /** Decodes the object (unknown fields rejected, every field required); call [valid] for the bounds. */
        fun fromJson(json: JSONObject): Geometry? {
            if (!onlyKeys(json, FIELDS)) return null
            return Geometry(
                generation = strictJsonLong(json.opt("generation"), 0, Long.MAX_VALUE) ?: return null,
                source = strictJsonLong(json.opt("source"), 0, Long.MAX_VALUE) ?: return null,
                kind = SourceKind.fromWire(json.opt("kind")) ?: return null,
                width = strictJsonLong(json.opt("width"), 0, 0xFFFF_FFFFL)?.takeIf { it <= Int.MAX_VALUE }?.toInt() ?: return null,
                height = strictJsonLong(json.opt("height"), 0, 0xFFFF_FFFFL)?.takeIf { it <= Int.MAX_VALUE }?.toInt() ?: return null,
            )
        }
    }
}

enum class ControlButton(val wire: String) {
    PRIMARY("primary"),
    SECONDARY("secondary"),
    MIDDLE("middle"),
    ;

    companion object {
        fun fromWire(value: Any?): ControlButton? = entries.firstOrNull { it.wire == value }
    }
}

enum class ControlKey(val wire: String) {
    ENTER("enter"),
    TAB("tab"),
    BACKSPACE("backspace"),
    ESCAPE("escape"),
    LEFT("left"),
    RIGHT("right"),
    UP("up"),
    DOWN("down"),
    HOME("home"),
    END("end"),
    PAGE_UP("page_up"),
    PAGE_DOWN("page_down"),
    DELETE("delete"),
    SHIFT("shift"),
    CONTROL("control"),
    ALT("alt"),
    META("meta"),
    ;

    companion object {
        fun fromWire(value: Any?): ControlKey? = entries.firstOrNull { it.wire == value }
    }
}

enum class ControlNavigation(val wire: String) {
    BACK("back"),
    HOME("home"),
    RECENTS("recents"),
    ;

    companion object {
        fun fromWire(value: Any?): ControlNavigation? = entries.firstOrNull { it.wire == value }
    }
}

enum class TouchPhase(val wire: String) {
    DOWN("down"),
    MOVE("move"),
    UP("up"),
    ;

    companion object {
        fun fromWire(value: Any?): TouchPhase? = entries.firstOrNull { it.wire == value }
    }
}

/** One input operation. toString never shows typed text, keys or positions. */
sealed class ControlInput(val op: String) {
    data object GeometryAck : ControlInput("geometry_ack")
    data class Pointer(val x: Double, val y: Double) : ControlInput("pointer")
    data class Button(val button: ControlButton, val down: Boolean, val x: Double, val y: Double) : ControlInput("button")
    data class Scroll(val dx: Int, val dy: Int, val x: Double, val y: Double) : ControlInput("scroll")
    data class Key(val key: ControlKey, val down: Boolean) : ControlInput("key")
    data class Text(val text: String) : ControlInput("text")
    data class Navigate(val action: ControlNavigation) : ControlInput("navigate")
    data class Touch(val contact: Int, val phase: TouchPhase, val x: Double, val y: Double) : ControlInput("touch")
    data object Heartbeat : ControlInput("heartbeat")
    data object Stop : ControlInput("stop")

    /** Rate class on the host: motion (120/s), discrete (20/s) or control (10/s, Stop exempt). */
    val isMotion: Boolean get() = this is Pointer || this is Scroll || (this is Touch && phase == TouchPhase.MOVE)
    val isControl: Boolean get() = this is GeometryAck || this is Heartbeat || this is Stop
    val isDiscrete: Boolean get() = !isMotion && !isControl

    final override fun toString(): String = when (this) {
        is Text -> "text([redacted])"
        GeometryAck, Heartbeat, Stop -> op
        else -> "$op(..)"
    }

    fun toJson(): JSONObject {
        val json = JSONObject().put("op", op)
        when (this) {
            GeometryAck, Heartbeat, Stop -> Unit
            is Pointer -> json.put("x", x).put("y", y)
            is Button -> json.put("button", button.wire).put("down", down).put("x", x).put("y", y)
            is Scroll -> json.put("dx", dx).put("dy", dy).put("x", x).put("y", y)
            is Key -> json.put("key", key.wire).put("down", down)
            is Text -> json.put("text", text)
            is Navigate -> json.put("action", action.wire)
            is Touch -> json.put("contact", contact).put("phase", phase.wire).put("x", x).put("y", y)
        }
        return json
    }

    companion object {
        /** Strict: an unknown op, a missing or extra field or a wrong type rejects (serde deny_unknown_fields). */
        fun fromJson(json: JSONObject): ControlInput? {
            fun only(vararg fields: String) = onlyKeys(json, setOf("op", *fields)) && fields.all(json::has)
            fun double(name: String) = jsonDouble(json.opt(name))
            fun bool(name: String) = json.opt(name) as? Boolean
            fun int32(name: String) = strictJsonLong(json.opt(name), Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong())?.toInt()
            return when (json.opt("op")) {
                "geometry_ack" -> GeometryAck.takeIf { only() }
                "heartbeat" -> Heartbeat.takeIf { only() }
                "stop" -> Stop.takeIf { only() }
                "pointer" -> if (!only("x", "y")) null else Pointer(double("x") ?: return null, double("y") ?: return null)
                "button" -> if (!only("button", "down", "x", "y")) null else Button(
                    ControlButton.fromWire(json.opt("button")) ?: return null, bool("down") ?: return null,
                    double("x") ?: return null, double("y") ?: return null,
                )
                "scroll" -> if (!only("dx", "dy", "x", "y")) null else Scroll(
                    int32("dx") ?: return null, int32("dy") ?: return null, double("x") ?: return null, double("y") ?: return null,
                )
                "key" -> if (!only("key", "down")) null else Key(ControlKey.fromWire(json.opt("key")) ?: return null, bool("down") ?: return null)
                "text" -> if (!only("text")) null else Text(json.opt("text") as? String ?: return null)
                "navigate" -> if (!only("action")) null else Navigate(ControlNavigation.fromWire(json.opt("action")) ?: return null)
                "touch" -> if (!only("contact", "phase", "x", "y")) null else Touch(
                    strictJsonLong(json.opt("contact"), 0, 255)?.toInt() ?: return null, TouchPhase.fromWire(json.opt("phase")) ?: return null,
                    double("x") ?: return null, double("y") ?: return null,
                )
                else -> null
            }
        }
    }
}

/** One input packet: bound to the control session, the transport, the connection nonce, the stream and the geometry. */
class ControlPacket(
    val session: Long,
    val transport: Long,
    connection: ByteArray,
    val stream: Long,
    val geometry: Long,
    val seq: Long,
    val input: ControlInput,
    val v: Int = ScreenControl.VERSION,
) {
    private val connectionBytes = connection.copyOf()
    val connection: ByteArray get() = connectionBytes.copyOf()

    fun toJson(): JSONObject = JSONObject()
        .put("v", v)
        .put("session", session)
        .put("transport", transport)
        .put("connection", JSONArray().apply { connectionBytes.forEach { put(it.toInt() and 0xFF) } })
        .put("stream", stream)
        .put("geometry", geometry)
        .put("seq", seq)
        .put("input", input.toJson())

    fun encode(): ByteArray = toJson().toString().toByteArray(Charsets.UTF_8)

    override fun equals(other: Any?): Boolean = other is ControlPacket && v == other.v && session == other.session &&
        transport == other.transport && connectionBytes.contentEquals(other.connectionBytes) && stream == other.stream &&
        geometry == other.geometry && seq == other.seq && input == other.input

    override fun hashCode(): Int = listOf(v, session, transport, connectionBytes.contentHashCode(), stream, geometry, seq, input).hashCode()

    override fun toString(): String = "ControlPacket(session=$session, seq=$seq, input=$input)"

    companion object {
        private val FIELDS = setOf("v", "session", "transport", "connection", "stream", "geometry", "seq", "input")

        /** Bounded before parsing; strict JSON; unknown fields and operations fail closed; counters 1 to 2^53-1. */
        fun decode(bytes: ByteArray): ControlPacket? {
            if (bytes.size > ScreenControl.MAX_PACKET_BYTES) return null
            val json = strictJsonObject(bytes) ?: return null
            if (!onlyKeys(json, FIELDS) || !FIELDS.all(json::has)) return null
            if (strictJsonLong(json.opt("v"), 0, 255) != ScreenControl.VERSION.toLong()) return null
            val array = json.opt("connection") as? JSONArray ?: return null
            if (array.length() != ScreenControl.CONNECTION_BYTES) return null
            val connection = ByteArray(ScreenControl.CONNECTION_BYTES)
            for (index in 0 until ScreenControl.CONNECTION_BYTES) {
                connection[index] = (strictJsonLong(array.opt(index), 0, 255) ?: return null).toByte()
            }
            if (connection.all { it == 0.toByte() }) return null
            fun counter(name: String) = strictJsonLong(json.opt(name), 0, Long.MAX_VALUE)?.takeIf(ScreenControl::validCounter)
            val input = (json.opt("input") as? JSONObject)?.let(ControlInput::fromJson) ?: return null
            return ControlPacket(
                session = counter("session") ?: return null,
                transport = counter("transport") ?: return null,
                connection = connection,
                stream = counter("stream") ?: return null,
                geometry = counter("geometry") ?: return null,
                seq = counter("seq") ?: return null,
                input = input,
            )
        }
    }
}
