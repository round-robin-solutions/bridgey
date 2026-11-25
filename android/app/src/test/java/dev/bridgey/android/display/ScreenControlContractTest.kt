package dev.bridgey.android.display

import java.io.File
import java.math.BigDecimal
import java.math.BigInteger
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The shared contract's golden wire (rust/proto/test-vectors/screen-control-v1.json), decoded by this app's own code:
 * the Rust reference (rust/proto/src/screen_control/tests.rs) and the Mac (ScreenControlContractTests) read the same file.
 */
class ScreenControlContractTest {
    private val root = File(System.getProperty("bridgey.repoRoot") ?: "../..")
    private val fixture = JSONObject(File(root, "rust/proto/test-vectors/screen-control-v1.json").readText(Charsets.UTF_8))

    private val allInputs = InputCapabilities(pointer = true, touch = true, keys = true, text = true, navigation = true)
    private val host = Capabilities(screenSource = true, fullDisplaySource = true, h264Encode = true, inputHost = allInputs, captureRequiresPrompt = true)
    private val controller = Capabilities(screenViewer = true, h264Decode = true, inputController = allInputs)
    private val geometry = Geometry(1, 9, SourceKind.DISPLAY, 1920, 1080)

    @Test fun protocolNameMatches() = assertEquals(ScreenControl.PROTOCOL, fixture.getString("protocol"))

    @Test fun goldenCapabilitiesDecodeAndEncodeAlike() {
        for ((name, expected) in listOf("host" to host, "controller" to controller)) {
            val json = fixture.getJSONObject(name)
            assertEquals(name, expected, Capabilities.decode(json.toString().toByteArray()))
            assertEquals(name, normalize(json), normalize(expected.toJson()))
        }
    }

    @Test fun goldenGeometry() {
        val json = fixture.getJSONObject("geometry")
        assertEquals(geometry, Geometry.fromJson(json))
        assertEquals(normalize(json), normalize(geometry.toJson()))
        assertEquals(PixelPoint(480, 809), geometry.pixel(0.25, 0.75))
    }

    @Test fun everyGoldenPacketDecodesAndEncodesToTheSameJson() {
        val packets = fixture.getJSONArray("packets")
        assertTrue(packets.length() >= 10)
        for (index in 0 until packets.length()) {
            val json = packets.getJSONObject(index)
            val decoded = ControlPacket.decode(json.toString().toByteArray())
            assertNotNull("packet $index", decoded)
            assertEquals("packet $index", index + 1L, decoded!!.seq)
            assertEquals("packet $index", normalize(json), normalize(decoded.toJson()))
            assertEquals("packet $index", decoded, ControlPacket.decode(decoded.encode()))
        }
    }

    @Test fun everyGoldenInvalidPacketIsRejected() {
        val invalid = fixture.getJSONArray("invalidPackets")
        assertTrue(invalid.length() >= 10)
        for (index in 0 until invalid.length()) {
            assertNull("invalid packet $index: ${invalid.get(index)}", ControlPacket.decode(invalid.getJSONObject(index).toString().toByteArray()))
        }
    }

    @Test fun capabilitiesNeverInventPermissionOrRoles() {
        val missing = Capabilities.decode("""{"v":1,"futureCapability":true}""".toByteArray())!!
        assertEquals(InputCapabilities(), missing.inputHost)
        assertFalse(missing.screenSource)
        assertNull(Capabilities.negotiatedInput(missing, controller))
        assertNull(Capabilities.decode("""{"v":2,"screenSource":true}""".toByteArray()))
        assertNull(Capabilities.decode("""{"screenSource":true}""".toByteArray()))
        assertNull(Capabilities.decode("""{"v":1,"screenSource":"yes"}""".toByteArray()))
        assertNull(Capabilities.decode("""{"v":1,"inputHost":true}""".toByteArray()))
        assertNull(Capabilities.decode("""{"v":1,"inputHost":{"pointer":1}}""".toByteArray()))
        assertNull(Capabilities.decode(ByteArray(ScreenControl.MAX_PACKET_BYTES + 1) { ' '.code.toByte() }))
    }

    @Test fun negotiationIntersectsWithoutInventingText() {
        val noText = host.copy(inputHost = allInputs.copy(text = false))
        val input = Capabilities.negotiatedInput(noText, controller)!!
        assertFalse(input.text)
        assertTrue(input.pointer && input.navigation)
        assertNull(Capabilities.negotiatedInput(host.copy(inputHost = InputCapabilities()), controller))
        assertNull(Capabilities.negotiatedInput(host.copy(fullDisplaySource = false), controller))
        assertNull(Capabilities.negotiatedInput(host, controller.copy(h264Decode = false)))
        // What this phone sends against what the Mac sends (docs/protocol.md): pointer, keys and text.
        val mac = Capabilities(screenSource = true, fullDisplaySource = true, h264Encode = true, captureRestoreSupported = true,
            inputHost = InputCapabilities(pointer = true, keys = true, text = true))
        assertEquals(InputCapabilities(pointer = true, keys = true, text = true), Capabilities.negotiatedInput(mac, viewerCapabilities()))
    }

    @Test fun geometryBoundsAndCoordinates() {
        assertTrue(geometry.valid())
        assertFalse(geometry.copy(generation = 0).valid())
        assertFalse(geometry.copy(source = ScreenControl.MAX_SEQUENCE + 1).valid())
        assertFalse(geometry.copy(width = 0).valid())
        assertFalse(geometry.copy(width = 32_769).valid())
        assertFalse(geometry.copy(width = 8_200, height = 8_200).valid())
        assertTrue(geometry.copy(width = 32_768, height = 2_048).valid())
        assertNull(geometry.pixel(Double.NaN, 0.5))
        assertNull(geometry.pixel(0.5, Double.POSITIVE_INFINITY))
        assertNull(geometry.pixel(-0.000001, 0.5))
        assertNull(geometry.pixel(0.5, 1.000001))
        assertEquals(PixelPoint(0, 0), geometry.pixel(0.0, 0.0))
        assertEquals(PixelPoint(1919, 1079), geometry.pixel(1.0, 1.0))
        // Every fraction of a deterministic corpus stays inside the selected pixels.
        for (step in 0..1000) {
            val p = geometry.pixel(step / 1000.0, (1000 - step) / 1000.0)!!
            assertTrue(p.x in 0 until 1920 && p.y in 0 until 1080)
        }
        assertNull(Geometry.fromJson(JSONObject("""{"generation":1,"source":9,"kind":"display","width":1920,"height":1080,"scale":2}""")))
        assertNull(Geometry.fromJson(JSONObject("""{"generation":1,"source":9,"kind":"display","width":1920}""")))
        assertNull(Geometry.fromJson(JSONObject("""{"generation":1,"source":9,"kind":"app","width":1920,"height":1080}""")))
        assertNull(Geometry.fromJson(JSONObject("""{"generation":1.5,"source":9,"kind":"display","width":1920,"height":1080}""")))
    }

    @Test fun everyInputRoundTripsAndDebugTextIsRedacted() {
        val connection = ByteArray(16) { 7 }
        val inputs = listOf(
            ControlInput.GeometryAck, ControlInput.Pointer(0.25, 0.75), ControlInput.Button(ControlButton.SECONDARY, true, 0.0, 1.0),
            ControlInput.Scroll(-3, 120, 0.5, 0.5), ControlInput.Key(ControlKey.PAGE_DOWN, false), ControlInput.Text("Hi 👋"),
            ControlInput.Navigate(ControlNavigation.RECENTS), ControlInput.Touch(9, TouchPhase.MOVE, 0.1, 0.9),
            ControlInput.Heartbeat, ControlInput.Stop,
        )
        inputs.forEachIndexed { index, input ->
            val packet = ControlPacket(1, 2, connection, 3, 4, index + 1L, input)
            assertEquals(packet, ControlPacket.decode(packet.encode()))
        }
        assertEquals("text([redacted])", ControlInput.Text("secret").toString())
        assertFalse(ControlInput.Pointer(0.123, 0.456).toString().contains("0.123"))
        assertFalse(ControlPacket(1, 2, connection, 3, 4, 5, ControlInput.Text("secret")).toString().contains("secret"))
    }

    @Test fun packetBoundsAreCheckedBeforeParsing() {
        val connection = ByteArray(16) { 7 }
        val long = ControlPacket(1, 1, connection, 1, 1, 1, ControlInput.Text("x".repeat(3000))).encode()
        assertTrue(long.size > ScreenControl.MAX_PACKET_BYTES)
        assertNull(ControlPacket.decode(long))
        assertNull(ControlPacket.decode("{v:1}".toByteArray()))
        val max = ControlPacket(ScreenControl.MAX_SEQUENCE, ScreenControl.MAX_SEQUENCE, connection, ScreenControl.MAX_SEQUENCE,
            ScreenControl.MAX_SEQUENCE, ScreenControl.MAX_SEQUENCE, ControlInput.Heartbeat)
        assertEquals(max, ControlPacket.decode(max.encode()))
        assertNull(ControlPacket.decode(ControlPacket(1, 1, ByteArray(16), 1, 1, 1, ControlInput.Heartbeat).encode()))
    }

    @Test fun textLimitsMatchTheHost() {
        assertTrue(ScreenControl.validText("Hello, Привет 👋"))
        assertTrue(ScreenControl.validText("x".repeat(256)))
        assertFalse(ScreenControl.validText("x".repeat(257)))
        assertFalse(ScreenControl.validText(""))
        assertFalse(ScreenControl.validText("line\nbreak"))
        assertFalse(ScreenControl.validText("tab\t"))
        assertFalse(ScreenControl.validText("é".repeat(513)))
        assertTrue(ScreenControl.validText("👋".repeat(256)))
        assertFalse(ScreenControl.validText("\uD83D"))
    }

    @Test fun connectionNonceIsSixteenBytesBoundToKeyAndSession() {
        val key = ByteArray(32) { it.toByte() }
        val nonce = ScreenControl.connectionNonce(key, "a")
        assertEquals(16, nonce.size)
        assertArrayEquals(nonce, ScreenControl.connectionNonce(key, "a"))
        assertFalse(nonce.contentEquals(ScreenControl.connectionNonce(key, "b")))
        assertFalse(nonce.contentEquals(ScreenControl.connectionNonce(ByteArray(32) { 1 }, "a")))
    }

    @Test fun rateClassesMatchTheContract() {
        assertTrue(ControlInput.Pointer(0.0, 0.0).isMotion)
        assertTrue(ControlInput.Scroll(0, 1, 0.0, 0.0).isMotion)
        assertTrue(ControlInput.Touch(0, TouchPhase.MOVE, 0.0, 0.0).isMotion)
        assertTrue(ControlInput.Touch(0, TouchPhase.DOWN, 0.0, 0.0).isDiscrete)
        assertTrue(ControlInput.Button(ControlButton.PRIMARY, true, 0.0, 0.0).isDiscrete)
        assertTrue(ControlInput.Text("a").isDiscrete)
        assertTrue(ControlInput.Heartbeat.isControl && ControlInput.GeometryAck.isControl && ControlInput.Stop.isControl)
    }

    companion object {
        /** JSON as plain values: integers as Long, other numbers as Double, so encoders compare by value. */
        fun normalize(value: Any?): Any? = when (value) {
            is JSONObject -> value.keys().asSequence().associateWith { normalize(value.opt(it)) }
            is JSONArray -> (0 until value.length()).map { normalize(value.opt(it)) }
            is Int, is Long, is Short, is Byte -> (value as Number).toLong()
            is BigInteger -> value.toLong()
            is BigDecimal, is Double, is Float -> (value as Number).toDouble()
            JSONObject.NULL -> null
            else -> value
        }
    }
}
