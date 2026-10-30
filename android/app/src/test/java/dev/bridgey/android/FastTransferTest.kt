package dev.bridgey.android

import dev.bridgey.android.ProtocolGoldenVectorsTest.Companion.normalize
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.util.Base64
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * protocol/test-vectors/files-fast-v1.json (binary frames, speed.* payloads, the verdict): the macOS suite
 * (FastTransferVectorsTests) decodes the same vectors. Regenerate with protocol/tools/fast_vectors.py.
 */
class FastTransferVectorsTest {
    private val root = File(System.getProperty("bridgey.repoRoot") ?: "../..")
    private val vectors = JSONObject(File(root, "protocol/test-vectors/files-fast-v1.json").readText())
    private val key = Base64.getDecoder().decode(vectors.getString("keyBase64"))
    private val sender = vectors.getString("senderDeviceId")

    private fun each(group: String, check: (JSONObject) -> Boolean) {
        val array = vectors.getJSONArray(group)
        assertTrue(array.length() > 5)
        val failed = (0 until array.length()).map(array::getJSONObject).filterNot { runCatching { check(it) }.getOrDefault(false) }.map { it.getString("name") }
        assertEquals("$group vectors that decode differently from the contract", emptyList<String>(), failed)
    }

    /** The frame through the session's reader, then the body decoder: decoded fields, "skip" or "reject". */
    private fun decode(frame: ByteArray): Any = runCatching {
        val reader = ProtocolStreamReader(ByteArrayInputStream(frame)).apply { binaryAllowed = true }
        val next = reader.next() as? ProtocolFrame.Binary ?: return@runCatching "reject"
        // As the read loop: the tag first, whatever the kind; then a genuine unknown kind is skipped.
        val payload = openFastFrameBody(next.kind, next.body, key, sender)
        if (next.kind != FastFrame.CHUNK_KIND && next.kind != FastFrame.SPEED_KIND) return@runCatching "skip"
        mapOf(
            "kind" to next.kind.toLong(), "id" to payload.id, "sequence" to payload.sequence,
            "plaintextBase64" to Base64.getEncoder().encodeToString(payload.plaintext),
        )
    }.getOrDefault("reject")

    @Test fun frameKeyIsDerivedFromTheSessionKey() {
        val vector = vectors.getJSONObject("frameKey")
        val sessionKey = Base64.getDecoder().decode(vector.getString("sessionKeyBase64"))
        assertArrayEquals(Base64.getDecoder().decode(vector.getString("frameKeyBase64")), SessionSecurity.fastFrameKey(sessionKey))
    }

    @Test fun fastFrames() = each("fastFrame") { vector ->
        var frame = Base64.getDecoder().decode(vector.getString("frameBase64"))
        if (vector.has("zeroPadTo")) frame += ByteArray(vector.getInt("zeroPadTo") - frame.size)
        if (decode(frame) != normalize(vector.get("expect"))) return@each false
        if (!vector.optBoolean("write")) return@each true
        val expect = vector.getJSONObject("expect")
        val written = sealFastFrame(
            expect.getInt("kind"), expect.getString("id"), expect.getLong("sequence"),
            Base64.getDecoder().decode(expect.getString("plaintextBase64")), key, sender,
            nonce = Base64.getDecoder().decode(vector.getString("nonceBase64")),
        )
        written.contentEquals(frame)
    }

    @Test fun speedPayloads() = each("speedPayload") { vector ->
        val plaintext = (if (vector.has("plaintextString")) vector.getString("plaintextString") else vector.get("plaintext").toString()).toByteArray()
        fun link(value: SpeedLink?): Map<String, Any?>? = value?.let {
            mapOf(
                "platform" to it.platform, "network" to it.network, "band" to it.band, "linkMbps" to it.linkMbps?.toLong(),
                "standard" to it.standard?.toLong(), "widthMhz" to it.widthMhz?.toLong(), "lockHeld" to it.lockHeld, "screenOn" to it.screenOn,
            )
        }
        val decoded: Any = when (val payload = SpeedPayload.decode(vector.getString("kind"), plaintext)) {
            null -> "reject"
            is SpeedPayload.Start -> mapOf("testId" to payload.testId, "seconds" to payload.seconds.toLong(), "link" to link(payload.link))
            is SpeedPayload.Ready -> mapOf("testId" to payload.testId, "status" to payload.status, "link" to link(payload.link))
            is SpeedPayload.Turn -> mapOf("testId" to payload.testId, "bytesPerSecond" to payload.bytesPerSecond)
            is SpeedPayload.Done -> mapOf("testId" to payload.testId, "bytesPerSecond" to payload.bytesPerSecond)
            is SpeedPayload.Result -> mapOf(
                "testId" to payload.testId, "forward" to payload.forward, "back" to payload.back,
                "roundTripMs" to payload.roundTripMs?.let { jsonInteger(it) ?: it }, "loadedRoundTripMs" to payload.loadedRoundTripMs?.let { jsonInteger(it) ?: it },
            )
        }
        decoded == normalize(vector.get("expect"))
    }

    @Test fun speedVerdicts() = each("speedVerdict") { vector ->
        val mac = SpeedLink.decode(vector.getJSONObject("mac"))
        val phone = SpeedLink.decode(vector.getJSONObject("phone"))!!
        val verdict = SpeedVerdict.evaluate(mac, phone, vector.getDouble("bestBytesPerSecond"))
        val route = when (verdict.route) {
            SpeedVerdict.Route.SAME_ROUTER -> "sameRouter"
            SpeedVerdict.Route.MAC_WIRED -> "macWired"
            SpeedVerdict.Route.HOTSPOT -> "hotspot"
            SpeedVerdict.Route.UNKNOWN -> "unknown"
        }
        val advice = verdict.advice.map {
            when (it) {
                SpeedVerdict.Advice.PHONE_24 -> "phone24"
                SpeedVerdict.Advice.MAC_24 -> "mac24"
                SpeedVerdict.Advice.SCREEN_OFF -> "screenOff"
                SpeedVerdict.Advice.WEAK_LINK -> "weakLink"
                SpeedVerdict.Advice.TRY_HOTSPOT -> "tryHotspot"
            }
        }
        val basis = when (verdict.basis) {
            SpeedVerdict.Basis.LINK_RATES -> "linkRates"
            SpeedVerdict.Basis.TYPICAL -> "typical"
            SpeedVerdict.Basis.NONE -> "none"
        }
        mapOf("route" to route, "basis" to basis, "low" to verdict.expectedLow.toLong(), "high" to verdict.expectedHigh.toLong(),
            "asExpected" to verdict.asExpected, "advice" to advice) == normalize(vector.get("expect"))
    }

    /** The new reader takes every protocol-v1 frame vector exactly as readProtocolLine did. */
    @Test fun streamReaderMatchesTheLineReaderOnTheFrameVectors() {
        val golden = JSONObject(File(root, "protocol/test-vectors/protocol-v1.json").readText())
        val sessionId = golden.getString("sessionId")
        val prefix = "{\"kind\":\"pairing.offer\",\"sessionId\":\"$sessionId\",\"deviceName\":\""
        val frames = golden.getJSONArray("frames")
        for (index in 0 until frames.length()) {
            val vector = frames.getJSONObject(index)
            val bytes = when {
                vector.has("lineBase64") -> Base64.getDecoder().decode(vector.getString("lineBase64"))
                vector.has("nest") -> ("{\"kind\":\"x.y\",\"sessionId\":\"$sessionId\",\"x\":" + "[".repeat(vector.getInt("nest") - 1) + "]".repeat(vector.getInt("nest") - 1) + "}").toByteArray()
                vector.has("padTo") -> (prefix + "a".repeat(vector.getInt("padTo") - prefix.length - 2) + "\"}").toByteArray()
                else -> vector.getString("line").toByteArray()
            } + vector.optString("lineEnding", "\n").toByteArray()
            val old = runCatching { decodeProtocolMessage(ByteArrayInputStream(bytes).readProtocolLine()!!) }.getOrNull()
            val new = runCatching { decodeProtocolMessage((ProtocolStreamReader(ByteArrayInputStream(bytes)).next() as ProtocolFrame.Json).text) }.getOrNull()
            assertEquals(vector.getString("name"), old, new)
        }
    }
}

class FastTransferTest {
    private val key = ByteArray(32) { it.toByte() }

    /** Delivers [data] in pieces of [split] bytes, as a socket would. */
    private class Pieces(private val data: ByteArray, private val split: Int) : InputStream() {
        private var offset = 0
        override fun read(): Int = if (offset < data.size) data[offset++].toInt() and 0xFF else -1
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (offset >= data.size) return -1
            val count = minOf(len, split, data.size - offset)
            System.arraycopy(data, offset, b, off, count)
            offset += count
            return count
        }
    }

    @Test fun oneMebibyteRoundTripsAndOneByteMoreIsRefused() {
        val plaintext = ByteArray(FastFrame.MAXIMUM_PLAINTEXT) { (it * 13).toByte() }
        val frame = sealFastFrame(FastFrame.CHUNK_KIND, "t", 9, plaintext, key, "phone")
        val read = ProtocolStreamReader(ByteArrayInputStream(frame)).apply { binaryAllowed = true }.next() as ProtocolFrame.Binary
        assertArrayEquals(plaintext, openFastFrameBody(read.kind, read.body, key, "phone").plaintext)
        assertThrows(FastFrameException::class.java) { sealFastFrame(1, "t", 0, ByteArray(FastFrame.MAXIMUM_PLAINTEXT + 1), key, "phone") }
    }

    @Test fun offsetAndLengthSealOnlyThatPart() {
        val buffer = ByteArray(100) { it.toByte() }
        val frame = sealFastFrame(FastFrame.CHUNK_KIND, "t", 0, buffer, key, "phone", 10, 20)
        val read = ProtocolStreamReader(ByteArrayInputStream(frame)).apply { binaryAllowed = true }.next() as ProtocolFrame.Binary
        assertArrayEquals(buffer.copyOfRange(10, 30), openFastFrameBody(read.kind, read.body, key, "phone").plaintext)
    }

    @Test fun readerMixesJsonAndBinaryFramesAcrossAnySplit() {
        val json1 = "{\"kind\":\"files.chunk.ack\",\"sessionId\":\"s\",\"transferId\":\"t\",\"sequence\":1}\n".toByteArray()
        val binary = sealFastFrame(FastFrame.CHUNK_KIND, "t", 2, ByteArray(300_000) { '\n'.code.toByte() }, key, "mac")
        val json2 = "{\"kind\":\"heartbeat.ping\",\"sessionId\":\"s\",\"messageId\":\"m\"}\r\n".toByteArray()
        val stream = json1 + binary + json2
        for (split in listOf(1, 2, 5, 6, 7, 100, 4096, 65_536, 262_144, stream.size)) {
            val reader = ProtocolStreamReader(Pieces(stream, split)).apply { binaryAllowed = true }
            val kinds = generateSequence { reader.next() }.map { frame ->
                when (frame) {
                    is ProtocolFrame.Json -> decodeProtocolMessage(frame.text).kind
                    is ProtocolFrame.Binary -> {
                        assertEquals(2L, openFastFrameBody(frame.kind, frame.body, key, "mac").sequence)
                        "binary"
                    }
                }
            }.toList()
            assertEquals("split $split", listOf("files.chunk.ack", "binary", "heartbeat.ping"), kinds)
        }
    }

    /** Without binaryAllowed the marker starts a JSON frame, and as invalid UTF-8 it closes the session, as before. */
    @Test fun withoutBinaryAllowedTheMarkerIsAnInvalidJsonFrame() {
        assertThrows(java.nio.charset.CharacterCodingException::class.java) {
            ProtocolStreamReader(ByteArrayInputStream(byteArrayOf(FastFrame.MARKER, 1, 0, 0, 0, 1, 0x41, 0x0A))).next()
        }
    }

    @Test fun oversizedJsonAndBinaryFramesThrow() {
        val long = ByteArray(MAX_PROTOCOL_FRAME_BYTES + 2) { 'a'.code.toByte() }
        assertThrows(ProtocolFrameTooLargeException::class.java) { ProtocolStreamReader(ByteArrayInputStream(long)).next() }
        val header = byteArrayOf(FastFrame.MARKER, 1) + java.nio.ByteBuffer.allocate(4).putInt(FastFrame.MAXIMUM_BODY + 1).array()
        assertThrows(ProtocolFrameTooLargeException::class.java) {
            ProtocolStreamReader(ByteArrayInputStream(header)).apply { binaryAllowed = true }.next()
        }
    }

    @Test fun aStreamEndingInsideABinaryFrameThrows() {
        val frame = sealFastFrame(FastFrame.CHUNK_KIND, "t", 0, ByteArray(1000), key, "mac")
        assertThrows(java.io.EOFException::class.java) {
            ProtocolStreamReader(ByteArrayInputStream(frame.copyOf(500))).apply { binaryAllowed = true }.next()
        }
    }

    @Test fun replayGuardRefusesASequenceAlreadyTaken() {
        val guard = FastReplayGuard()
        val first = FastFramePayload(1, "t", 0, ByteArray(0))
        assertTrue(guard.accept(first))
        assertFalse("the same frame again", guard.accept(first))
        assertTrue(guard.accept(FastFramePayload(1, "t", 1, ByteArray(0))))
        assertFalse("an older frame after a newer one", guard.accept(first))
        assertTrue("another kind is its own stream", guard.accept(FastFramePayload(2, "t", 0, ByteArray(0))))
        assertTrue("another transfer is its own stream", guard.accept(FastFramePayload(1, "u", 0, ByteArray(0))))
    }

    /** Security review 2026-10-30: a long transfer stays remembered while 256 short ones come and go. */
    @Test fun replayGuardForgetsTheLeastRecentlyUsedTransfer() {
        val guard = FastReplayGuard()
        assertTrue(guard.accept(FastFramePayload(1, "long", 0, ByteArray(0))))
        for (index in 0 until 300) {
            assertTrue(guard.accept(FastFramePayload(1, "short-$index", 0, ByteArray(0))))
            assertTrue(guard.accept(FastFramePayload(1, "long", index + 1L, ByteArray(0))))
        }
        assertFalse("the long transfer's old frame is still refused", guard.accept(FastFramePayload(1, "long", 5, ByteArray(0))))
        // The oldest short transfer was forgotten; the most recent ones are not.
        assertTrue(guard.accept(FastFramePayload(1, "short-0", 0, ByteArray(0))))
        assertFalse(guard.accept(FastFramePayload(1, "short-299", 0, ByteArray(0))))
    }

    @Test fun legacyPacerKeepsSixtyFourChunks() {
        val pacer = TransferPacer(fast = false)
        assertEquals(24 * 1024, pacer.chunkSize)
        repeat(64) {
            assertTrue(pacer.canSend(pacer.chunkSize))
            pacer.didSend("t", it.toLong(), pacer.chunkSize)
        }
        assertFalse(pacer.canSend(pacer.chunkSize))
        pacer.acknowledged("t", 0)
        assertTrue(pacer.canSend(pacer.chunkSize))
    }

    @Test fun fastWindowGrowsOnQuickAcknowledgementsAndShrinksOnQueueing() {
        var clock = 100_000_000_000L
        val pacer = TransferPacer(fast = true) { clock }
        assertEquals(TransferPacer.INITIAL_WINDOW, pacer.window)
        var sequence = 0L
        repeat(200) {
            while (pacer.canSend(pacer.chunkSize)) pacer.didSend("t", sequence++, pacer.chunkSize)
            clock += 2_000_000
            pacer.acknowledged("t", sequence - 1)
        }
        val grown = pacer.window
        assertTrue("grown $grown", grown > TransferPacer.INITIAL_WINDOW * 4 && grown <= TransferPacer.MAXIMUM_WINDOW)
        repeat(20) {
            while (pacer.canSend(pacer.chunkSize)) pacer.didSend("t", sequence++, pacer.chunkSize)
            clock += 200_000_000
            pacer.acknowledged("t", sequence - 1)
        }
        assertTrue("shrunk ${pacer.window}", pacer.window < grown / 4 && pacer.window >= 2L * FastFrame.CHUNK_SIZE)
    }

    @Test fun waitForRoomReturnsOnAnAcknowledgementAndFailsOnCancel() {
        val pacer = TransferPacer(fast = true)
        pacer.didSend("t", 0, TransferPacer.INITIAL_WINDOW.toInt())
        Thread { Thread.sleep(100); pacer.acknowledged("t", 0) }.start()
        assertTrue(pacer.waitForRoom(FastFrame.CHUNK_SIZE, 5_000))
        pacer.didSend("t", 1, pacer.window.toInt())
        Thread { Thread.sleep(100); pacer.cancel() }.start()
        assertFalse(pacer.waitForRoom(FastFrame.CHUNK_SIZE, 5_000))
    }

    @Test fun forgetFreesTheWindow() {
        val pacer = TransferPacer(fast = true)
        pacer.didSend("a", 0, TransferPacer.INITIAL_WINDOW.toInt())
        assertFalse(pacer.canSend(FastFrame.CHUNK_SIZE))
        pacer.forget("a")
        assertEquals(0L, pacer.unacknowledgedBytes)
        assertTrue(pacer.canSend(FastFrame.CHUNK_SIZE))
    }

    @Test fun speedPayloadsRoundTrip() {
        val id = java.util.UUID.randomUUID().toString()
        val link = SpeedLink("android", "wifi", "5", 1201, 6, 80, lockHeld = true, screenOn = false)
        listOf(
            SpeedKinds.START to SpeedPayload.Start(id, 7, link),
            SpeedKinds.READY to SpeedPayload.Ready(id, "busy", null),
            SpeedKinds.TURN to SpeedPayload.Turn(id, 123),
            SpeedKinds.DONE to SpeedPayload.Done(id, 0),
            SpeedKinds.RESULT to SpeedPayload.Result(id, 1, 2, 3.5, null),
        ).forEach { (kind, payload) -> assertEquals(payload, SpeedPayload.decode(kind, payload.encode())) }
        assertNull(SpeedPayload.decode(SpeedKinds.TURN, "{}".toByteArray()))
        assertNotNull(SpeedReport(1e6, 2e6, 3.0, 4.0, null, link).plainText("x"))
    }
}
