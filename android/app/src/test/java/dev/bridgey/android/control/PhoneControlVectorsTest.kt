package dev.bridgey.android.control

import dev.bridgey.android.display.Capabilities
import dev.bridgey.android.display.Geometry
import dev.bridgey.android.display.InputCapabilities
import dev.bridgey.android.display.SourceKind
import dev.bridgey.android.screen.ScreenKinds
import dev.bridgey.android.screen.ScreenMacMessage
import dev.bridgey.android.screen.ScreenStartInfo
import dev.bridgey.android.screen.decodeScreenMacMessage
import dev.bridgey.android.screen.screenStartPayload
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * protocol/test-vectors/phone-control-v1.json from the phone's side: what it writes (the control object of screen.start,
 * screen.geometry and screen.control), what it reads from the Mac, its capabilities and where positions land. The Mac
 * (PhoneControlVectorsTests) checks the same file.
 */
class PhoneControlVectorsTest {
    private val root = File(System.getProperty("bridgey.repoRoot") ?: "../..")
    private val vectors = JSONObject(File(root, "protocol/test-vectors/phone-control-v1.json").readText(Charsets.UTF_8))

    /** JSON compared as values: key order and 1 versus 1.0 do not matter. */
    private fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().sorted().associateWith { normalize(value.opt(it)) }
        is JSONArray -> (0 until value.length()).map { normalize(value.opt(it)) }
        is Number -> value.toDouble()
        JSONObject.NULL -> null
        else -> value
    }

    private fun caps(json: JSONObject): Capabilities = Capabilities.fromJson(json)!!
    private fun inputs(json: JSONObject): InputCapabilities = InputCapabilities.fromJson(json)!!
    private fun geometry(json: JSONObject): Geometry = Geometry.fromJson(json)!!

    @Test fun theStartControlObjectsThePhoneWritesMatch() {
        val cases = vectors.getJSONArray("startControl")
        var written = 0
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            if (!case.optBoolean("write")) continue
            val plaintext = case.getJSONObject("plaintext")
            val control = plaintext.getJSONObject("control")
            val offer = PhoneControlOffer(
                control.getLong("stream"), control.getLong("transport"), geometry(control.getJSONObject("geometry")),
                caps(control.getJSONObject("capabilities")), control.getBoolean("allowed"),
            )
            val info = ScreenStartInfo(plaintext.getInt("width"), plaintext.getInt("height"), plaintext.getInt("fps"), plaintext.getLong("bitrate"), plaintext.getString("requestId"))
            val payload = screenStartPayload(plaintext.getString("streamId"), plaintext.getLong("sequence"), info, offer.toJson())
            assertEquals(case.getString("name"), normalize(plaintext), normalize(payload))
            assertTrue("within screen.start's 1,024 bytes", payload.toString().toByteArray().size <= 1_024)
            written++
        }
        assertTrue(written >= 3)
    }

    @Test fun aStartWithoutControlIsTheViewOnlyStart() {
        val payload = screenStartPayload("0d3c2b1a-5948-4776-a5b4-c3d2e1f00a1b", 1, ScreenStartInfo(720, 1600, 30, 4_000_000))
        assertFalse(payload.has("control"))
    }

    @Test fun theStreamMessagesThePhoneWritesMatch() {
        val cases = vectors.getJSONArray("phoneStream")
        var written = 0
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            if (!case.optBoolean("write")) continue
            val plaintext = case.getJSONObject("plaintext")
            val streamId = plaintext.getString("streamId")
            val sequence = plaintext.getLong("sequence")
            val payload = when (case.getString("kind")) {
                ScreenKinds.GEOMETRY -> screenGeometryPayload(streamId, sequence, geometry(plaintext.getJSONObject("geometry")))
                ScreenKinds.CONTROL -> phoneControlPayload(
                    streamId, sequence,
                    when (plaintext.getString("state")) {
                        "waiting" -> PhoneControlUpdate.Waiting
                        "active" -> PhoneControlUpdate.Active(plaintext.getLong("session"), inputs(plaintext.getJSONObject("input")))
                        "ended" -> PhoneControlUpdate.Ended(PhoneControlReason.fromWire(plaintext.getString("reason")))
                        "refused" -> PhoneControlUpdate.Refused(PhoneControlReason.fromWire(plaintext.getString("reason")))
                        "available" -> PhoneControlUpdate.Available(plaintext.getBoolean("allowed"))
                        else -> error("unknown state")
                    },
                )
                else -> error("unknown kind")
            }
            assertEquals(case.getString("name"), normalize(plaintext), normalize(payload))
            written++
        }
        assertTrue(written >= 7)
    }

    @Test fun theMacsControlMessagesDecodeAlike() {
        val cases = vectors.getJSONArray("macStream")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val bytes = case.getJSONObject("plaintext").toString().toByteArray()
            val decoded = decodeMacControl(bytes)
            val expect = case.opt("expect")
            if (expect == JSONObject.NULL) {
                assertNull(case.getString("name"), decoded)
                assertNull(case.getString("name"), decodeScreenMacMessage(ScreenKinds.CONTROL, bytes))
                continue
            }
            expect as JSONObject
            assertNotNull(case.getString("name"), decoded)
            assertEquals(case.getString("name"), expect.getString("action"), decoded!!.action.wire)
            if (expect.has("capabilities")) assertEquals(case.getString("name"), caps(expect.getJSONObject("capabilities")), decoded.capabilities)
            // The stream's own decoder hands it on with its sequence for the guard.
            val message = decodeScreenMacMessage(ScreenKinds.CONTROL, bytes) as ScreenMacMessage.Control
            assertEquals(case.getJSONObject("plaintext").getLong("sequence"), message.sequence)
        }
    }

    @Test fun capabilitiesFollowTheAndroidVersion() {
        val cases = vectors.getJSONArray("capabilities")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            if (case.getString("side") != "phone") continue
            val ours = phoneHostCapabilities(case.getInt("sdk"))
            assertEquals(case.getString("name"), normalize(case.getJSONObject("expect")), normalize(ours.toJson()))
        }
    }

    @Test fun negotiationMatches() {
        val cases = vectors.getJSONArray("negotiated")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val result = Capabilities.negotiatedInput(caps(case.getJSONObject("host")), caps(case.getJSONObject("controller")))
            val expect = case.opt("expect")
            if (expect == JSONObject.NULL) assertNull(case.getString("name"), result) else assertEquals(case.getString("name"), inputs(expect as JSONObject), result)
        }
    }

    @Test fun positionsLandWhereTheVectorsSay() {
        val cases = vectors.getJSONArray("phonePoint")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val g = case.getJSONArray("geometry")
            val d = case.getJSONArray("display")
            val geometry = Geometry(1, 1, SourceKind.DISPLAY, g.getInt(0), g.getInt(1))
            val point = phonePoint(geometry, d.getInt(0), d.getInt(1), case.getDouble("x"), case.getDouble("y"))
            val expect = case.get("expect")
            if (expect == "reject") {
                assertNull(case.getString("name"), point)
                continue
            }
            expect as JSONObject
            val pixel = expect.getJSONArray("pixel")
            assertEquals(case.getString("name"), geometry.pixel(case.getDouble("x"), case.getDouble("y")), dev.bridgey.android.display.PixelPoint(pixel.getInt(0), pixel.getInt(1)))
            val want = expect.getJSONArray("point")
            assertEquals(case.getString("name"), want.getDouble(0), point!!.x, 1e-9)
            assertEquals(case.getString("name"), want.getDouble(1), point.y, 1e-9)
        }
    }

    @Test fun scrollDistancesScaleLikeTheVectors() {
        val cases = vectors.getJSONArray("scrollDelta")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val g = case.getJSONArray("geometry")
            val d = case.getJSONArray("display")
            val delta = scrollDelta(Geometry(1, 1, SourceKind.DISPLAY, g.getInt(0), g.getInt(1)), d.getInt(0), d.getInt(1), case.getInt("dx"), case.getInt("dy"))
            val want = case.getJSONArray("expect")
            assertEquals(case.getString("name"), want.getDouble(0), delta.x, 1e-9)
            assertEquals(case.getString("name"), want.getDouble(1), delta.y, 1e-9)
        }
    }
}
