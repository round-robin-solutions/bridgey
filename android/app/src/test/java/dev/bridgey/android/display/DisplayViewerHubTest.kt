package dev.bridgey.android.display

import dev.bridgey.android.screen.ScreenFrameCodec
import dev.bridgey.android.screen.ScreenFrameHeader
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The viewer's lifecycle against a scripted Mac: asking, the Mac's answers, the stream, acknowledgements, control and
 * every ending, with the sender run in place and a synchronous decoder.
 */
class DisplayViewerHubTest {
    private var now = 100_000L
    private val mac = "mac-1"
    private val sent = mutableListOf<Pair<String, JSONObject>>()
    private val sentInput = mutableListOf<ControlPacket>()
    private var linkUp = true
    private var available = true
    private var enabledHere = true
    private val connection = ByteArray(16) { 3 }

    private val link = object : DisplayLink {
        override val connection: ByteArray get() = this@DisplayViewerHubTest.connection
        override fun send(kind: String, payload: ByteArray): Boolean {
            if (!linkUp) return false
            if (kind == DisplayKinds.INPUT) sentInput += ControlPacket.decode(payload)!! else sent += kind to JSONObject(String(payload))
            return true
        }
    }

    private val host = object : DisplayHost {
        override fun link(deviceId: String) = if (available && deviceId == mac) link else null
        override fun available(deviceId: String) = available && deviceId == mac
        override fun enabledHere(deviceId: String) = enabledHere
    }

    /** Decodes in place: every frame "decodes" in 2 ms unless the next outcome says otherwise. */
    private val outcomes = ArrayDeque<DisplayDecodeLogic.Outcome>()
    private var offers = 0
    private var acceptOffers = true

    private val hub = DisplayViewerHub(
        host, { now }, sender = { it.run() }, timer = null,
        makeDecoder = { _, onResult ->
            object : FrameDecoder {
                override val codecName: String? = "fake"
                override fun offer(frame: AssembledFrame, width: Int, height: Int): Boolean {
                    offers++
                    if (!acceptOffers) return false
                    onResult(frame, outcomes.removeFirstOrNull() ?: DisplayDecodeLogic.Outcome.Decoded(2))
                    return true
                }
                override fun attach(surface: Any?) = Unit
                override fun clear() = Unit
                override fun release() = Unit
            }
        },
    )

    private val streamId = UUID.randomUUID().toString()
    private val geometry = Geometry(1, 69_734_662, SourceKind.DISPLAY, 1920, 1246)

    private fun requestId(): String = sent.last { it.first == DisplayKinds.REQUEST }.second.getString("requestId")

    private fun start(requestId: String = requestId(), id: String = streamId, control: Boolean = true, sequence: Long = 1): ByteArray =
        JSONObject()
            .put("version", 1).put("streamId", id).put("sequence", sequence).put("requestId", requestId).put("codec", "h264")
            .put("fps", 30).put("bitrate", 4_000_000).put("stream", 7).put("transport", 2).put("geometry", geometry.toJson())
            .put("capabilities", Capabilities(screenSource = true, fullDisplaySource = true, h264Encode = true,
                inputHost = InputCapabilities(pointer = true, keys = true, text = true)).toJson())
            .put("control", control).put("displayName", "Built-in Retina Display")
            .toString().toByteArray()

    private var macSequence = 1L

    private fun macMessage(vararg pairs: Pair<String, Any>): ByteArray =
        JSONObject().put("version", 1).put("streamId", streamId).put("sequence", ++macSequence).apply { pairs.forEach { (k, v) -> put(k, v) } }
            .toString().toByteArray()

    private val keyFrame = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0, 0x1F, 0, 0, 0, 1, 0x68, 0xCE.toByte(), 0, 0, 0, 1, 0x65, 0x88.toByte())
    private val pFrame = byteArrayOf(0, 0, 0, 1, 0x41, 0x9A.toByte())

    private fun frame(number: Long, key: Boolean, data: ByteArray = if (key) keyFrame else pFrame): ByteArray =
        ScreenFrameCodec.encode(ScreenFrameHeader(streamId, ++macSequence, number, 0, key, key, true, 0), data)

    private fun streaming(control: Boolean = true, id: String = streamId) {
        hub.open(mac, "MacBook Pro")
        hub.onStatus(mac, JSONObject().put("version", 1).put("requestId", requestId()).put("status", "waiting").toString().toByteArray())
        hub.onStart(mac, start(id = id, control = control), link)
    }

    private fun acks() = sent.filter { it.first == DisplayKinds.ACK }.map { it.second }

    @Test fun askingThenWaitingThenDeclined() {
        hub.open(mac, "MacBook Pro")
        assertEquals(DisplayViewState.Phase.ASKING, hub.state.value.phase)
        val request = sent.single()
        assertEquals(DisplayKinds.REQUEST, request.first)
        val caps = Capabilities.fromJson(request.second.getJSONObject("capabilities"))!!
        assertTrue(caps.screenViewer && caps.h264Decode && caps.inputController.pointer && !caps.screenSource)
        val id = requestId()
        hub.onStatus(mac, JSONObject().put("version", 1).put("requestId", id).put("status", "waiting").toString().toByteArray())
        assertEquals(DisplayViewState.Phase.WAITING, hub.state.value.phase)
        // Another request's answer changes nothing.
        hub.onStatus(mac, JSONObject().put("version", 1).put("requestId", UUID.randomUUID().toString()).put("status", "declined").toString().toByteArray())
        assertEquals(DisplayViewState.Phase.WAITING, hub.state.value.phase)
        hub.onStatus(mac, JSONObject().put("version", 1).put("requestId", id).put("status", "declined").toString().toByteArray())
        assertEquals(DisplayViewState.Phase.ENDED, hub.state.value.phase)
        assertEquals(DisplayOutcome.Refused(DisplayStatus.DECLINED), hub.state.value.outcome)
    }

    @Test fun everyStatusEndsWithItsOwnOutcome() {
        for (status in DisplayStatus.entries - DisplayStatus.WAITING) {
            now += 10_000
            hub.open(mac, "MacBook Pro")
            hub.onStatus(mac, JSONObject().put("version", 1).put("requestId", requestId()).put("status", status.wire).toString().toByteArray())
            assertEquals(DisplayOutcome.Refused(status), hub.state.value.outcome)
        }
    }

    @Test fun oneRequestEveryThreeSecondsAndItExpiresAfterTwoMinutes() {
        hub.open(mac, "MacBook Pro")
        hub.close(DisplayStopReason.LEFT_SCREEN)
        hub.open(mac, "MacBook Pro")
        assertEquals(1, sent.count { it.first == DisplayKinds.REQUEST })
        now += 3_000
        hub.open(mac, "MacBook Pro")
        assertEquals(2, sent.count { it.first == DisplayKinds.REQUEST })
        now += 120_000
        hub.tick()
        assertEquals(DisplayOutcome.NoAnswer, hub.state.value.outcome)
    }

    @Test fun notAvailableSendsNothing() {
        available = false
        hub.open(mac, "MacBook Pro")
        assertEquals(DisplayOutcome.Unavailable, hub.state.value.outcome)
        assertTrue(sent.isEmpty())
    }

    @Test fun aValidStartStreamsAndIsAnsweredOnce() {
        streaming()
        val view = hub.state.value
        assertEquals(DisplayViewState.Phase.STREAMING, view.phase)
        assertEquals(geometry, view.geometry)
        assertTrue(view.controlAllowed)
        assertEquals("Built-in Retina Display", view.displayName)
        val started = sent.single { it.first == DisplayKinds.STARTED }.second
        assertEquals(streamId, started.getString("streamId"))
        assertEquals(1, started.getInt("sequence"))
        // The same start again is ignored.
        hub.onStart(mac, start(id = streamId), link)
        assertEquals(1, sent.count { it.first == DisplayKinds.STARTED })
    }

    @Test fun aStartNobodyAskedForIsRefused() {
        hub.onStart(mac, start(requestId = UUID.randomUUID().toString()), link)
        val stop = sent.single()
        assertEquals(DisplayKinds.STOP, stop.first)
        assertEquals("left_screen", stop.second.getString("reason"))
        assertEquals(1, stop.second.getInt("sequence"))
        assertFalse(hub.state.value.streaming)
    }

    @Test fun anInvalidStartIsRefusedAsInvalid() {
        hub.open(mac, "MacBook Pro")
        val bad = JSONObject(String(start())).put("codec", "h265").toString().toByteArray()
        hub.onStart(mac, bad, link)
        assertEquals("invalid", sent.last().second.getString("reason"))
        assertFalse(hub.state.value.streaming)
    }

    @Test fun framesAreAcknowledgedAndAKeyFrameIsAskedForAfterALoss() {
        streaming()
        hub.onFrame(mac, frame(1, key = false))
        assertEquals(0, offers)
        assertTrue(acks().last().getBoolean("keyframe"))
        hub.onFrame(mac, frame(2, key = true))
        assertEquals(1, offers)
        assertEquals(2, acks().last().getInt("frame"))
        assertEquals(2, acks().last().getInt("decodeMs"))
        assertFalse(acks().last().has("keyframe"))
        hub.onFrame(mac, frame(3, key = false))
        assertEquals(2, offers)
        // A part of frame 5 arriving before frame 4 ended loses frame 4; at most one key frame request a second.
        now += 1_000
        hub.onFrame(mac, ScreenFrameCodec.encode(ScreenFrameHeader(streamId, ++macSequence, 4, 0, false, false, false, 0), pFrame))
        hub.onFrame(mac, ScreenFrameCodec.encode(ScreenFrameHeader(streamId, ++macSequence, 5, 0, false, false, true, 0), pFrame))
        assertEquals(5, acks().last().getInt("frame"))
        assertTrue(acks().last().getBoolean("keyframe"))
        val requests = acks().count { it.optBoolean("keyframe") }
        hub.onFrame(mac, frame(6, key = false))
        assertEquals(requests, acks().count { it.optBoolean("keyframe") })
        now += 1_000
        hub.onFrame(mac, frame(7, key = false))
        assertEquals(requests + 1, acks().count { it.optBoolean("keyframe") })
    }

    @Test fun aFullDecoderQueueDropsUntilTheNextKeyFrame() {
        streaming()
        hub.onFrame(mac, frame(1, key = true))
        acceptOffers = false
        hub.onFrame(mac, frame(2, key = false))
        acceptOffers = true
        val offered = offers
        hub.onFrame(mac, frame(3, key = false))
        assertEquals(offered, offers)
        hub.onFrame(mac, frame(4, key = true))
        assertEquals(offered + 1, offers)
    }

    @Test fun repeatedOrOtherStreamsFramesAreDropped() {
        streaming()
        val one = frame(1, key = true)
        hub.onFrame(mac, one)
        hub.onFrame(mac, one)
        assertEquals(1, offers)
        hub.onFrame(mac, ScreenFrameCodec.encode(ScreenFrameHeader(UUID.randomUUID().toString(), 999, 9, 0, true, true, true, 0), keyFrame))
        hub.onFrame("other-mac", frame(2, key = true))
        assertEquals(1, offers)
    }

    @Test fun controlStartsWithTheGeometryAckAndInputIsBoundToTheStream() {
        streaming()
        assertFalse(hub.input(DisplayAction.Pointer(0.5, 0.5)))
        hub.beginControl()
        assertEquals("begin", sent.last().second.getString("action"))
        assertEquals(DisplayViewState.ControlPhase.STARTING, hub.state.value.control)
        hub.onStreamMessage(mac, DisplayKinds.CONTROL, macMessage("state" to "active", "session" to 1, "input" to JSONObject().put("pointer", true).put("keys", true).put("text", true)))
        assertEquals(DisplayViewState.ControlPhase.ACTIVE, hub.state.value.control)
        val ack = sentInput.single()
        assertEquals(ControlInput.GeometryAck, ack.input)
        assertEquals(1L, ack.session)
        assertEquals(2L, ack.transport)
        assertEquals(7L, ack.stream)
        assertEquals(1L, ack.geometry)
        assertTrue(ack.connection.contentEquals(connection))
        assertTrue(hub.input(DisplayAction.Button(ControlButton.PRIMARY, true, 0.25, 0.75)))
        assertTrue(hub.input(DisplayAction.Button(ControlButton.PRIMARY, false, 0.25, 0.75)))
        assertEquals(listOf(1L, 2L, 3L), sentInput.map { it.seq })
        hub.input(DisplayAction.Pointer(0.3, 0.3))
        hub.flushControl()
        assertEquals(ControlInput.Pointer(0.3, 0.3), sentInput.last().input)
    }

    @Test fun aGeometryChangeFencesInputUntilTheNewGenerationIsAcknowledged() {
        streaming()
        hub.beginControl()
        hub.onStreamMessage(mac, DisplayKinds.CONTROL, macMessage("state" to "active", "session" to 1, "input" to JSONObject().put("pointer", true)))
        hub.input(DisplayAction.Button(ControlButton.PRIMARY, true, 0.5, 0.5))
        hub.input(DisplayAction.Pointer(0.6, 0.6))
        val epoch = hub.state.value.gestureEpoch
        val resized = geometry.copy(generation = 2, width = 1600, height = 1000)
        hub.onStreamMessage(mac, DisplayKinds.GEOMETRY, macMessage("geometry" to resized.toJson()))
        assertEquals(resized, hub.state.value.geometry)
        assertTrue(hub.state.value.gestureEpoch > epoch)
        val ack = sentInput.last()
        assertEquals(ControlInput.GeometryAck, ack.input)
        assertEquals(2L, ack.geometry)
        // The pending pointer was dropped, the held button is not released from here, and new input is generation 2.
        hub.flushControl()
        assertEquals(ack, sentInput.last())
        assertFalse(hub.input(DisplayAction.Button(ControlButton.PRIMARY, false, 0.5, 0.5)))
        hub.input(DisplayAction.Pointer(0.1, 0.1))
        hub.flushControl()
        assertEquals(2L, sentInput.last().geometry)
    }

    @Test fun controlCanEndOnEitherSideWhileThePictureStays() {
        streaming()
        hub.beginControl()
        hub.onStreamMessage(mac, DisplayKinds.CONTROL, macMessage("state" to "active", "session" to 1, "input" to JSONObject().put("pointer", true)))
        hub.endControl()
        assertEquals(ControlInput.Stop, sentInput.last().input)
        assertEquals(DisplayViewState.ControlPhase.OFF, hub.state.value.control)
        assertTrue(hub.state.value.streaming)
        hub.beginControl()
        hub.onStreamMessage(mac, DisplayKinds.CONTROL, macMessage("state" to "active", "session" to 2, "input" to JSONObject().put("pointer", true)))
        hub.onStreamMessage(mac, DisplayKinds.CONTROL, macMessage("state" to "ended", "reason" to "focus"))
        assertEquals(DisplayViewState.ControlPhase.OFF, hub.state.value.control)
        assertEquals(DisplayControlReason.FOCUS, hub.state.value.controlNote)
        assertFalse(hub.input(DisplayAction.Pointer(0.5, 0.5)))
        assertTrue(hub.state.value.streaming)
    }

    @Test fun anUnaskedActiveIsEndedAtOnce() {
        streaming()
        hub.onStreamMessage(mac, DisplayKinds.CONTROL, macMessage("state" to "active", "session" to 1, "input" to JSONObject().put("pointer", true)))
        assertEquals(DisplayViewState.ControlPhase.OFF, hub.state.value.control)
        assertEquals("end", sent.last().second.getString("action"))
    }

    @Test fun controlIsNotOfferedWhenTheMacSaidNo() {
        streaming(control = false)
        hub.beginControl()
        assertTrue(sent.none { it.first == DisplayKinds.CONTROL })
    }

    @Test fun stopOnTheMacEndsItAndNothingRestartsByItself() {
        streaming()
        hub.onStreamMessage(mac, DisplayKinds.STOP, macMessage("reason" to "local_stop"))
        assertEquals(DisplayOutcome.Stopped(DisplayStopReason.LOCAL_STOP, byMac = true), hub.state.value.outcome)
        val count = sent.size
        hub.onFrame(mac, frame(1, key = true))
        assertEquals(0, offers)
        assertEquals(count, sent.size)
        // The same stream cannot start again; Start again is a new request.
        hub.onStart(mac, start(requestId = UUID.randomUUID().toString(), id = streamId), link)
        assertEquals(count, sent.size)
        now += 3_000
        hub.startAgain()
        assertEquals(DisplayKinds.REQUEST, sent.last().first)
    }

    @Test fun aDisconnectEndsTheStreamAndControlWithoutResurrecting() {
        streaming()
        hub.beginControl()
        hub.onStreamMessage(mac, DisplayKinds.CONTROL, macMessage("state" to "active", "session" to 1, "input" to JSONObject().put("pointer", true)))
        val inputs = sentInput.size
        hub.disconnected(mac)
        assertEquals(DisplayOutcome.Disconnected, hub.state.value.outcome)
        assertEquals(DisplayViewState.ControlPhase.OFF, hub.state.value.control)
        // Nothing goes to a disconnected Mac: no stop, no input.
        assertEquals(inputs, sentInput.size)
        assertTrue(sent.none { it.first == DisplayKinds.STOP })
        assertFalse(hub.input(DisplayAction.Pointer(0.5, 0.5)))
        hub.onStreamMessage(mac, DisplayKinds.STATS, macMessage("latencyMs" to 1, "rttMs" to 1, "bitrate" to 1, "sentBitrate" to 1, "fps" to 1, "dropped" to 0))
        assertNull(hub.state.value.stats)
        assertEquals(DisplayViewState.Phase.ENDED, hub.state.value.phase)
    }

    @Test fun aFailedWriteEndsTheStream() {
        streaming()
        linkUp = false
        hub.onFrame(mac, frame(1, key = true))
        assertEquals(DisplayOutcome.Disconnected, hub.state.value.outcome)
    }

    @Test fun leavingTheScreenTellsTheMac() {
        streaming()
        hub.beginControl()
        hub.onStreamMessage(mac, DisplayKinds.CONTROL, macMessage("state" to "active", "session" to 1, "input" to JSONObject().put("pointer", true)))
        hub.close(DisplayStopReason.LEFT_SCREEN)
        assertEquals(ControlInput.Stop, sentInput.last().input)
        assertEquals("left_screen", sent.last().second.getString("reason"))
        assertEquals(DisplayOutcome.Stopped(DisplayStopReason.LEFT_SCREEN, byMac = false), hub.state.value.outcome)
    }

    @Test fun sixSecondsWithoutFramesOrStatsTimesOut() {
        streaming()
        now += 5_000
        hub.onStreamMessage(mac, DisplayKinds.STATS, macMessage("latencyMs" to 20, "rttMs" to 5, "bitrate" to 4_000_000, "sentBitrate" to 3_000_000, "fps" to 30, "dropped" to 0))
        assertEquals(20L, hub.state.value.stats?.latencyMs)
        now += 5_999
        hub.tick()
        assertTrue(hub.state.value.streaming)
        now += 1
        hub.tick()
        assertEquals("timeout", sent.last().second.getString("reason"))
        assertEquals(DisplayViewState.Phase.ENDED, hub.state.value.phase)
    }

    @Test fun turningItOffHereTellsTheMacButOffOnTheMacSendsNothing() {
        streaming()
        available = false
        enabledHere = false
        hub.policy(mac)
        assertEquals("disabled", sent.last().second.getString("reason"))
        now += 3_000
        available = true
        enabledHere = true
        streaming(id = UUID.randomUUID().toString())
        assertTrue(hub.state.value.streaming)
        val count = sent.size
        available = false
        hub.policy(mac)
        assertEquals(count, sent.size)
        assertEquals(DisplayOutcome.Stopped(DisplayStopReason.DISABLED, byMac = true), hub.state.value.outcome)
    }

    @Test fun aNewSurfaceAsksForAKeyFrameAtOnce() {
        streaming()
        hub.onFrame(mac, frame(1, key = true))
        hub.onFrame(mac, frame(2, key = false))
        hub.surface("new surface")
        val ack = acks().last()
        assertEquals(2, ack.getInt("frame"))
        assertTrue(ack.getBoolean("keyframe"))
        // Until the key frame, nothing is decoded.
        val offered = offers
        hub.onFrame(mac, frame(3, key = false))
        assertEquals(offered, offers)
    }

    @Test fun viewerSequencesIncreaseAcrossEveryMessageOfTheStream() {
        streaming()
        hub.onFrame(mac, frame(1, key = true))
        hub.beginControl()
        hub.onFrame(mac, frame(2, key = false))
        hub.close(DisplayStopReason.USER)
        val sequences = sent.filter { it.first != DisplayKinds.REQUEST }.map { it.second.getLong("sequence") }
        assertEquals((1L..sequences.size).toList(), sequences)
        assertEquals("user", sent.last().second.getString("reason"))
    }
}
