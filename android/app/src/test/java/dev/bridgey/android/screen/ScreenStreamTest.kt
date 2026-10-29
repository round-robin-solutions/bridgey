package dev.bridgey.android.screen

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenStreamTest {
    private var now = 1_000L
    private val json = mutableListOf<Pair<String, JSONObject>>()
    private val frames = mutableListOf<ByteArray>()
    private var linkUp = true
    private val keyRequests = mutableListOf<Long>()
    private val bitrates = mutableListOf<Long>()
    private var ended: Pair<ScreenStopReason, Boolean>? = null

    private val link = object : ScreenLink {
        override fun sendJson(kind: String, payload: JSONObject): Boolean { if (linkUp) json += kind to payload; return linkUp }
        override fun sendFrame(plaintext: ByteArray): Boolean { if (linkUp) frames += plaintext; return linkUp }
    }

    private fun make(requestId: String? = null): ScreenStream {
        val stream = ScreenStream("mac", "MacBook", requestId, link, clock = { now }, streamId = STREAM)
        stream.encoder = object : ScreenEncoderControl {
            override fun requestKeyFrame() { keyRequests += now }
            override fun setBitrate(bitsPerSecond: Long) { bitrates += bitsPerSecond }
        }
        stream.onEnded = { reason, told -> ended = reason to told }
        return stream
    }

    private fun started(stream: ScreenStream, sequence: Long = 1) = stream.receive(ScreenMacMessage.Started(STREAM, sequence))

    private fun key(size: Int = 100) = ByteArray(size).also { it[3] = 1; it[4] = 0x67 }

    @Test fun startCarriesTheSizeAndRequest() {
        val stream = make(requestId = REQUEST)
        assertTrue(stream.start(720, 1600))
        val (kind, payload) = json.single()
        assertEquals(ScreenKinds.START, kind)
        assertEquals(1L, payload.getLong("sequence"))
        assertEquals(REQUEST, payload.getString("requestId"))
        assertEquals(720, payload.getInt("width"))
        assertEquals(4_000_000L, payload.getLong("bitrate"))
    }

    @Test fun framesWaitForStartedThenAKeyFrame() {
        val stream = make()
        stream.start(720, 1600)
        stream.onEncodedFrame(key(), key = true, parameterSets = true, captureMillis = now, captureMicros = 1)
        assertTrue("nothing before screen.started", frames.isEmpty())
        started(stream)
        assertEquals(ScreenStreamPhase.STREAMING, stream.phase)
        assertEquals("started asks for a key frame", 1, keyRequests.size)
        stream.onEncodedFrame(ByteArray(50).also { it[2] = 1 }, key = false, parameterSets = false, captureMillis = now, captureMicros = 2)
        assertTrue("a P frame before the key frame is skipped", frames.isEmpty())
        stream.onEncodedFrame(key(), key = true, parameterSets = true, captureMillis = now, captureMicros = 3)
        val (header, _) = ScreenFrameCodec.decode(frames.single())!!
        assertEquals(2L, header.sequence)
        assertEquals(1L, header.frame)
        assertTrue(header.key && header.parameterSets && header.last)
        assertTrue("skips are not congestion", bitrates.isEmpty())
    }

    @Test fun sequencesStayInOrderAcrossFramesStatsAndStop() {
        val stream = make()
        stream.start(720, 1600)
        started(stream)
        stream.onEncodedFrame(key(40_000), key = true, parameterSets = true, captureMillis = now, captureMicros = 1)
        now += 1000
        stream.tick()
        stream.stop(ScreenStopReason.USER)
        val frameSequences = frames.map { ScreenFrameCodec.decode(it)!!.first.sequence }
        assertEquals(listOf(2L, 3L), frameSequences)
        assertEquals(listOf(ScreenKinds.START to 1L, ScreenKinds.STATS to 4L, ScreenKinds.STOP to 5L), json.map { it.first to it.second.getLong("sequence") })
        assertEquals("user", json.last().second.getString("reason"))
        assertEquals(ScreenStopReason.USER to true, ended)
    }

    @Test fun acksMoveTheWindowAndReplaysAreIgnored() {
        val stream = make()
        stream.start(720, 1600)
        started(stream)
        repeat(6) { stream.onEncodedFrame(if (it == 0) key() else ByteArray(100).also { b -> b[2] = 1 }, it == 0, it == 0, now, 1) }
        assertEquals(6, frames.size)
        stream.onEncodedFrame(ByteArray(100).also { it[2] = 1 }, false, false, now, 1)
        assertEquals("the seventh waits for an ack: dropped", 6, frames.size)
        assertEquals(listOf(3_000_000L), bitrates)
        stream.receive(ScreenMacMessage.Ack(STREAM, 2, 6, 1, false))
        stream.receive(ScreenMacMessage.Ack(STREAM, 2, 6, 1, true))
        assertEquals("a replayed sequence is ignored", 1, keyRequests.size)
        stream.onEncodedFrame(key(), true, true, now, 1)
        assertEquals(7, frames.size)
    }

    @Test fun keyframeAskFromTheMacIsHonoured() {
        val stream = make()
        stream.start(720, 1600)
        started(stream)
        now += 1000
        stream.receive(ScreenMacMessage.Ack(STREAM, 2, 1, 0, true))
        assertEquals(2, keyRequests.size)
        stream.onEncodedFrame(ByteArray(10).also { it[2] = 1 }, false, false, now, 1)
        assertTrue(frames.isEmpty())
    }

    @Test fun noStartedWithinFiveSecondsTimesOut() {
        val stream = make()
        stream.start(720, 1600)
        now += 4_999
        stream.tick()
        assertNull(ended)
        now += 1
        stream.tick()
        assertEquals(ScreenStopReason.TIMEOUT to true, ended)
        assertEquals("timeout", json.last().second.getString("reason"))
    }

    @Test fun noAckForSixSecondsTimesOut() {
        val stream = make()
        stream.start(720, 1600)
        started(stream)
        stream.onEncodedFrame(key(), true, true, now, 1)
        now += 5_000
        stream.tick()
        assertNull(ended)
        now += 1_000
        stream.tick()
        assertEquals(ScreenStopReason.TIMEOUT to true, ended)
    }

    @Test fun theMacStoppingEndsWithoutAnAnswer() {
        val stream = make()
        stream.start(720, 1600)
        started(stream)
        stream.receive(ScreenMacMessage.Stop(STREAM, 2, ScreenStopReason.CLOSED))
        assertEquals(ScreenStopReason.CLOSED to false, ended)
        assertEquals(ScreenKinds.START, json.single().first)
    }

    @Test fun anotherStreamsMessagesAreIgnored() {
        val stream = make()
        stream.start(720, 1600)
        stream.receive(ScreenMacMessage.Started("00000000-0000-4000-8000-000000000000", 1))
        assertEquals(ScreenStreamPhase.STARTING, stream.phase)
    }

    @Test fun aFailedWriteEndsTheStreamQuietly() {
        val stream = make()
        stream.start(720, 1600)
        started(stream)
        linkUp = false
        stream.onEncodedFrame(key(), true, true, now, 1)
        assertEquals(ScreenStopReason.FAILED to false, ended)
        assertFalse(stream.phase != ScreenStreamPhase.ENDED)
    }

    @Test fun statsGoOutOnceASecond() {
        val stream = make()
        var seen = 0
        stream.onStats = { seen++ }
        stream.start(720, 1600)
        started(stream)
        stream.onEncodedFrame(key(1000), true, true, now, 1)
        stream.receive(ScreenMacMessage.Ack(STREAM, 2, 1, 2, false))
        now += 1000
        stream.tick()
        val stats = json.last { it.first == ScreenKinds.STATS }.second
        assertEquals(1, stats.getInt("fps"))
        assertEquals(8000L, stats.getLong("sentBitrate"))
        assertEquals(1, seen)
    }

    private companion object {
        const val STREAM = "6c2e9a14-3b5d-4e7f-8a90-1b2c3d4e5f60"
        const val REQUEST = "8a5d9c3e-2b47-4f1a-9e60-7c1d2b3a4f5e"
    }
}
