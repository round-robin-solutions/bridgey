package dev.bridgey.android.display

import dev.bridgey.android.display.ScreenControlContractTest.Companion.normalize
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * protocol/test-vectors/display-v1.json (Mac screen to phone, screen_control_draft1) with this app's own code: what the
 * phone reads (connection, status, start, viewerStream, frame, letterbox) and what it writes (its request, started, ack,
 * control and stop match what the Mac reads in request and sourceStream). The Mac checks the same file
 * (DisplayVectorsTests). Regenerate with protocol/tools/display_vectors.py.
 */
class DisplayVectorsTest {
    private val vectors = JSONObject(
        File(System.getProperty("bridgey.repoRoot") ?: "../..", "protocol/test-vectors/display-v1.json").readText(Charsets.UTF_8),
    )

    @Test fun format() = assertEquals("bridgey.display.v1", vectors.getString("format"))

    @Test fun connection() = each("connection", minimum = 3) { vector ->
        val key = hex(vector.getString("keyHex"))
        val nonce = ScreenControl.connectionNonce(key, vector.getString("sessionId")).map { it.toLong() and 0xFF }
        nonce == normalize(vector.getJSONArray("expect"))
    }

    @Test fun status() = each("status") { vector ->
        val result: Any = decodeDisplayStatus(plaintext(vector))?.let { mapOf("requestId" to it.requestId, "status" to it.status.wire) } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    @Test fun start() = each("start") { vector ->
        val result: Any = decodeDisplayStart(plaintext(vector))?.let { start ->
            mapOf(
                "streamId" to start.streamId, "sequence" to start.sequence, "requestId" to start.requestId, "fps" to start.fps.toLong(),
                "bitrate" to start.bitrate, "stream" to start.stream, "transport" to start.transport,
                "geometry" to normalize(start.geometry.toJson()), "capabilities" to normalize(start.capabilities.toJson()),
                "control" to start.control, "displayName" to start.displayName,
            )
        } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    @Test fun startNamesItsStreamEvenWhenInvalid() {
        val array = vectors.getJSONArray("start")
        val invalid = (0 until array.length()).map(array::getJSONObject).filter { it.opt("expect") == "reject" && it.has("plaintext") }
        assertTrue(invalid.isNotEmpty())
        invalid.forEach { assertEquals(it.getString("name"), "6c1b2a39-4857-4f6e-8d7c-0b1a29384756", displayStartStreamId(plaintext(it))) }
    }

    @Test fun viewerStream() = each("viewerStream") { vector ->
        val data = plaintext(vector)
        val result: Any = when (vector.getString("kind").substringAfter('.')) {
            "stats" -> decodeDisplayStats(data)?.let {
                mapOf("streamId" to it.streamId, "sequence" to it.sequence, "latencyMs" to it.latencyMs, "rttMs" to it.rttMs,
                    "bitrate" to it.bitrate, "sentBitrate" to it.sentBitrate, "fps" to it.fps.toLong(), "dropped" to it.dropped.toLong())
            }
            "geometry" -> decodeDisplayGeometry(data)?.let { mapOf("streamId" to it.streamId, "sequence" to it.sequence, "geometry" to normalize(it.geometry.toJson())) }
            "control" -> decodeDisplayControlFromSource(data)?.let {
                mapOf("streamId" to it.streamId, "sequence" to it.sequence, "state" to it.state.wire, "session" to it.session,
                    "input" to it.input?.let { input -> normalize(input.toJson()) }, "reason" to it.reason?.wire)
            }
            "stop" -> decodeDisplayStop(data)?.let { mapOf("streamId" to it.streamId, "sequence" to it.sequence, "reason" to it.reason.wire) }
            else -> error("unknown kind")
        } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    @Test fun frame() = each("frame") { vector ->
        val result: Any = decodeDisplayFrame(hex(vector.getString("hex")))?.let { (header, payload) ->
            mapOf(
                "streamId" to header.streamId, "sequence" to header.sequence, "frame" to header.frame, "part" to header.part.toLong(),
                "key" to header.key, "parameterSets" to header.parameterSets, "last" to header.last, "captureMicros" to header.captureMicros,
                "payloadHex" to payload.joinToString("") { "%02x".format(it) },
            )
        } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    @Test fun letterbox() = each("letterbox") { vector ->
        val view = vector.getJSONArray("view")
        val video = vector.getJSONArray("video")
        val touch = vector.getJSONArray("touch")
        val rect = letterboxRect(view.getDouble(0), view.getDouble(1), video.getInt(0), video.getInt(1))
        val fraction = letterboxFraction(rect, touch.getDouble(0), touch.getDouble(1))
        val expect = vector.opt("expect")
        if (expect == null || expect == JSONObject.NULL) fraction == null
        else fraction != null && close(fraction.first, (expect as JSONArray).getDouble(0)) && close(fraction.second, expect.getDouble(1))
    }

    @Test fun captureSize() = each("captureSize") { vector ->
        val native = vector.getJSONArray("native")
        val (width, height) = displayCaptureSize(native.getInt(0), native.getInt(1))
        listOf(width.toLong(), height.toLong()) == normalize(vector.getJSONArray("expect"))
    }

    /** The phone's request matches what the Mac expects to read from the same values. */
    @Test fun requestThePhoneWrites() = each("request") { vector ->
        val expect = vector.opt("expect") as? JSONObject ?: return@each true
        val capabilities = Capabilities.fromJson(expect.getJSONObject("capabilities"))!!
        val written = displayRequestPayload(expect.getString("requestId"), capabilities)
        normalize(written) == normalize(JSONObject(expect.toString()).put("version", 1))
    }

    /** started, ack, control and stop as the phone writes them read back as the Mac's expected values. */
    @Test fun sourceStreamThePhoneWrites() = each("sourceStream") { vector ->
        val expect = vector.opt("expect") as? JSONObject ?: return@each true
        val streamId = expect.getString("streamId")
        val sequence = expect.getLong("sequence")
        val written = when (vector.getString("kind").substringAfter('.')) {
            "started" -> displayStartedPayload(streamId, sequence)
            "ack" -> displayAckPayload(streamId, sequence, expect.getLong("frame"), expect.getLong("decodeMs"), expect.getBoolean("keyframe"))
            "control" -> displayControlPayload(streamId, sequence, DisplayControlAction.entries.first { it.wire == expect.getString("action") })
            "stop" -> {
                val reason = DisplayStopReason.fromWire(expect.getString("reason"))
                // Only the reasons this phone sends; an unknown one is a read rule, not a write.
                if (vector.getJSONObject("plaintext").getString("reason") != reason.wire) return@each true
                displayStopPayload(streamId, sequence, reason)
            }
            else -> error("unknown kind")
        }
        val expected = JSONObject(expect.toString()).put("version", 1)
        if (expected.optBoolean("keyframe", true) == false) expected.remove("keyframe")
        normalize(written) == normalize(expected)
    }

    private fun each(group: String, minimum: Int = 5, check: (JSONObject) -> Boolean) {
        val array = vectors.getJSONArray(group)
        assertTrue("$group has at least $minimum vectors", array.length() >= minimum)
        val failed = (0 until array.length()).map(array::getJSONObject)
            .filterNot { runCatching { check(it) }.getOrDefault(false) }.map { it.getString("name") }
        assertEquals("$group vectors that decode differently from the contract", emptyList<String>(), failed)
    }

    private fun plaintext(vector: JSONObject): ByteArray =
        (if (vector.has("plaintextString")) vector.getString("plaintextString") else vector.get("plaintext").toString()).toByteArray()

    private fun hex(text: String): ByteArray = ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun close(a: Double, b: Double) = kotlin.math.abs(a - b) <= 1e-9
}
