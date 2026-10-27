package dev.bridgey.android

import dev.bridgey.android.browse.BrowseRef
import dev.bridgey.android.browse.BrowseRefs
import dev.bridgey.android.browse.requestIdOf
import dev.bridgey.android.folders.FolderCancelPayload
import dev.bridgey.android.folders.FolderCompletePayload
import dev.bridgey.android.folders.FolderOfferPayload
import dev.bridgey.android.folders.ManifestPagePayload
import dev.bridgey.android.folders.PlacesChildrenPayload
import dev.bridgey.android.folders.PlacesListedPayload
import dev.bridgey.android.remote.InputSequence
import dev.bridgey.android.remote.RemoteInputCodec
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.nio.charset.CharacterCodingException
import kotlin.random.Random

/**
 * Property-based fuzzing of the frame reader, the envelope decoder and the payload decoders: random
 * bytes, truncated and oversized frames, wrong types, unknown kinds, replayed IDs and huge counts. Each
 * property checks that nothing crashes (only the documented exceptions close a session), that what is
 * accepted stays within the contract's limits, and that a valid message still decodes afterwards.
 *
 * Normal runs use [ITERATIONS] cases per property. Long runs:
 *   BRIDGEY_FUZZ_ITERATIONS=100000 ./gradlew :app:testDebugUnitTest -Pfuzz=100000 --tests '*ProtocolFuzzTest'
 * BRIDGEY_FUZZ_SEED (or -Pfuzz.seed) replays a failing run; the seed is printed on failure.
 */
class ProtocolFuzzTest {
    private val iterations = (System.getProperty("bridgey.fuzzIterations") ?: System.getenv("BRIDGEY_FUZZ_ITERATIONS"))?.toIntOrNull() ?: ITERATIONS
    private val seed = (System.getProperty("bridgey.fuzzSeed") ?: System.getenv("BRIDGEY_FUZZ_SEED"))?.toLongOrNull() ?: System.nanoTime()
    private val random = Random(seed)
    private val vectors = JSONObject(File(File(System.getProperty("bridgey.repoRoot") ?: "../.."), "protocol/test-vectors/protocol-v1.json").readText())
    private val sessionId = vectors.getString("sessionId")
    private val validFrames: List<String> = vectors.getJSONArray("frames").let { array ->
        (0 until array.length()).map(array::getJSONObject).filter { it.has("line") && it.get("expect") is JSONObject }.map { it.getString("line") }
    }

    @Test fun randomBytesNeverCrashTheReader() = property("random bytes") {
        val bytes = random.nextBytes(random.nextInt(0, 3 * MAX_PROTOCOL_FRAME_BYTES))
        // Some LFs, so random data also forms many short frames.
        repeat(random.nextInt(0, 64)) { if (bytes.isNotEmpty()) bytes[random.nextInt(bytes.size)] = '\n'.code.toByte() }
        drain(ByteArrayInputStream(bytes))
    }

    @Test fun mutatedFramesDecodeOrCloseCleanly() = property("mutated frames") {
        val frame = mutate(validFrames.random(random).toByteArray())
        decodeOrClose(frame)?.let(::assertWithinLimits)
    }

    @Test fun truncatedFramesNeverDecodeAsSomethingElse() = property("truncated frames") {
        val frame = validFrames.random(random).trimEnd()
        val cut = random.nextInt(0, frame.length)
        val decoded = decodeOrClose(frame.substring(0, cut).toByteArray())
        // A strict prefix of an object is never a complete object.
        assertTrue("prefix of $frame decoded", decoded == null)
    }

    @Test fun wrongTypesAndUnknownKindsAreHandled() = property("structured envelopes") {
        val json = JSONObject()
        val fields = listOf("kind", "sessionId", "messageId", "deviceId", "deviceName", "publicKey", "nonce", "ciphertext", "transferId", "sequence", "targetDeviceId", "extra")
        fields.filter { random.nextInt(3) != 0 }.forEach { json.put(it, randomJson(depth = 0)) }
        if (random.nextBoolean()) json.put("kind", randomKind())
        if (random.nextBoolean()) json.put("sessionId", sessionId)
        val decoded = decodeOrClose(json.toString().toByteArray())
        if (decoded != null) {
            assertWithinLimits(decoded)
            assertEquals(json.get("kind"), decoded.kind)
        }
        // A frame the strict check accepts must also be readable by org.json.
        if (isStrictJsonObject(json.toString())) assertNotNull(runCatching { JSONObject(json.toString()) }.getOrNull())
    }

    @Test fun oversizedAndDeepFramesClose() = property("oversized and deep frames", scale = 20) {
        val size = MAX_PROTOCOL_FRAME_BYTES + random.nextInt(1, 4096)
        val oversized = ("{\"kind\":\"ping.ack\",\"sessionId\":\"$sessionId\",\"x\":\"" + "a".repeat(size) + "\"}\n").toByteArray()
        assertTrue(readerFails(oversized) is ProtocolFrameTooLargeException)
        val depth = random.nextInt(MAX_PROTOCOL_JSON_DEPTH + 1, 30_000)
        val deep = "{\"kind\":\"x.y\",\"sessionId\":\"$sessionId\",\"x\":" + "[".repeat(depth) + "]".repeat(depth) + "}"
        assertTrue(decodeOrClose(deep.toByteArray()) == null)
        // Unbalanced nesting (only openers) must not recurse either.
        assertTrue(decodeOrClose(("{\"a\":" + "{\"a\":".repeat(depth)).toByteArray()) == null)
    }

    @Test fun framingResynchronisesAfterBadFrames() = property("resynchronise") {
        // Bad frames close the real session; the reader itself must still find the next frame boundary.
        val good = validFrames.random(random)
        val garbage = mutate(validFrames.random(random).toByteArray()).filter { it != '\n'.code.toByte() }.toByteArray()
        val stream = ByteArrayInputStream(garbage + "\n".toByteArray() + good.toByteArray() + "\n".toByteArray())
        runCatching { stream.readProtocolLine() }
        if (garbage.size <= MAX_PROTOCOL_FRAME_BYTES) assertEquals(good, stream.readProtocolLine())
    }

    @Test fun replayWindowMatchesAReferenceModel() = property("replay window") {
        val window = ReplayWindow()
        val reference = ArrayDeque<String>()
        val pool = random.nextInt(10, 2_000)
        repeat(random.nextInt(1, 3_000)) {
            val id = "id-" + random.nextInt(pool)
            val expected = id !in reference
            assertEquals("replay of $id", expected, window.accept(id))
            if (expected) {
                reference.addLast(id)
                if (reference.size > 256) reference.removeFirst()
            }
            assertTrue(window.size <= 256)
        }
        // A replay of the newest IDs is always caught, however many came before.
        reference.takeLast(10).forEach { assertFalse(window.accept(it)) }
    }

    @Test fun payloadDecodersRejectGarbageWithoutThrowing() = property("payload decoders") {
        val payload = randomPayload()
        val text = payload.toString(Charsets.UTF_8)
        decodeFeatureState(payload)
        decodeBatteryStatus(payload)?.let { assertTrue(it.level in 0..100) }
        RichClipboardContent.decode(payload)?.let { assertTrue(it.text.isNotEmpty() && (it.text + it.html).toByteArray().size <= MAX_CLIPBOARD_CONTENT_BYTES) }
        ClipOffer.decode(payload)?.let { offer ->
            assertTrue(offer.items.size in 1..ClipLimits.MAX_ITEMS)
            assertTrue(offer.items.all { it.size in 0..ClipLimits.MAX_ITEM_SIZE })
            assertTrue(offer.items.mapNotNull { it.inline?.size }.sum() <= ClipLimits.MAX_INLINE_TOTAL_BYTES)
        }
        listOf("input.session.started", "input.session.stop", "input.session.start", "input.pointer").forEach { kind ->
            RemoteInputCodec.decodeHostMessage(kind, payload)?.let { assertTrue(it.sequence >= 1) }
        }
        strictJsonObject(text)?.let { json ->
            // Files area decoders take a parsed object; they must not throw on any object.
            PlacesListedPayload.parse(json)
            PlacesChildrenPayload.parse(json)
            FolderOfferPayload.parse(json)
            ManifestPagePayload.parse(json)
            FolderCompletePayload.parse(json)
            FolderCancelPayload.parse(json)
            // Files 2.0 browse requests carry refs; a ref that parses is always one the phone can address.
            (BrowseRefs.parse(json) as? BrowseRef.Media)?.let { assertTrue(it.mediaId >= 0) }
            BrowseRefs.parse(json.optJSONObject("ref"))
            requestIdOf(json)
        }
    }

    @Test fun hugeCountsAreBoundedBeforeAllocation() = property("huge counts", scale = 10) {
        val count = listOf(101, 1_000, 50_000, Int.MAX_VALUE).random(random)
        val offer = JSONObject().put("version", 1).put("offerId", "5b1f3a5e-7d0c-4f6e-9a51-0c2f6f7d1e0b").put("createdAt", 1)
            .put("items", JSONArray().apply { repeat(minOf(count, 5_000)) { put(JSONObject().put("index", it).put("kind", "image").put("mime", "image/png").put("size", Long.MAX_VALUE)) } })
        assertEquals(null, ClipOffer.decode(offer.toString().toByteArray()))
        val folder = JSONObject().put("version", 1).put("folderTransferId", "5b1f3a5e-7d0c-4f6e-9a51-0c2f6f7d1e0b").put("rootName", "x")
            .put("fileCount", count.toLong() * 1_000_000).put("folderCount", count).put("totalSize", Long.MAX_VALUE)
            .put("pageCount", count).put("manifestSha256", "AAAA").put("resume", false)
        assertTrue(FolderOfferPayload.parse(folder) is FolderOfferPayload.Companion.Result.Invalid)
        assertEquals(FeatureStateDecoding.Invalid, decodeFeatureState(("{\"version\":1,\"features\":[" + "1,".repeat(10_000) + "1]}").toByteArray()))
    }

    @Test fun sequenceHighWaterMarksIgnoreReplays() = property("sequences") {
        val sequence = InputSequence()
        var highest = 0L
        repeat(random.nextInt(1, 500)) {
            val next = when (random.nextInt(4)) {
                0 -> highest
                1 -> highest - random.nextLong(0, 10)
                2 -> random.nextLong(-5, Long.MAX_VALUE)
                else -> highest + 1
            }
            val accepted = sequence.accept(next)
            assertEquals(next in 1..JSON_MAX_SAFE_INTEGER && next > highest, accepted)
            if (accepted) highest = next
        }
        val quick = QuickRequestSequence()
        assertTrue(quick.accept("links", 5))
        assertFalse(quick.accept("links", 5))
        assertFalse(quick.accept("automation", 6))
        assertTrue(quick.accept("media", 1))
    }

    // MARK: helpers

    private fun property(name: String, scale: Int = 1, case: () -> Unit) {
        val count = maxOf(1, iterations / scale)
        for (index in 0 until count) {
            try {
                case()
            } catch (error: Throwable) {
                throw AssertionError("fuzz property \"$name\" failed at case $index with seed $seed (BRIDGEY_FUZZ_SEED=$seed): $error", error)
            }
        }
    }

    /** Reads every frame; only the documented session-closing errors may escape. */
    private fun drain(input: InputStream) {
        while (true) {
            val line = try {
                input.readProtocolLine() ?: return
            } catch (_: ProtocolFrameTooLargeException) {
                return
            } catch (_: CharacterCodingException) {
                return
            }
            assertTrue(line.toByteArray().size <= MAX_PROTOCOL_FRAME_BYTES)
            try {
                assertWithinLimits(decodeProtocolMessage(line))
            } catch (_: JSONException) {
                // Closes the session in the app; here the next frame is read.
            }
        }
    }

    private fun decodeOrClose(frame: ByteArray): Message? = try {
        val line = ByteArrayInputStream(frame + '\n'.code.toByte()).readProtocolLine() ?: ""
        decodeProtocolMessage(line)
    } catch (_: JSONException) {
        null
    } catch (_: ProtocolFrameTooLargeException) {
        null
    } catch (_: CharacterCodingException) {
        null
    } catch (error: Throwable) {
        fail("unexpected ${error.javaClass.simpleName} for ${frame.toString(Charsets.UTF_8).take(200)}")
        null
    }

    private fun readerFails(frame: ByteArray): Throwable? = runCatching { ByteArrayInputStream(frame).readProtocolLine() }.exceptionOrNull()

    private fun assertWithinLimits(message: Message) {
        assertTrue(message.kind.isNotEmpty() && message.kind.toByteArray().size <= 64)
        assertTrue(message.sessionId.toByteArray().size <= 128)
        assertTrue(message.sessionId.isNotEmpty() || message.kind == "pairing.cancel")
        message.sequence?.let { assertTrue(kotlin.math.abs(it) <= JSON_MAX_SAFE_INTEGER) }
        listOfNotNull(message.messageId, message.transferId, message.nonce).forEach { assertTrue(it.isNotEmpty()) }
    }

    private fun mutate(bytes: ByteArray): ByteArray {
        var value = bytes
        repeat(random.nextInt(1, 6)) {
            value = when (random.nextInt(6)) {
                0 -> value.copyOf().also { if (it.isNotEmpty()) it[random.nextInt(it.size)] = random.nextInt(256).toByte() }
                1 -> if (value.isEmpty()) value else value.copyOfRange(0, random.nextInt(value.size))
                2 -> value + random.nextBytes(random.nextInt(1, 32))
                3 -> if (value.size < 2) value else { val i = random.nextInt(value.size - 1); value.copyOfRange(0, i) + value.copyOfRange(i + 1, value.size) }
                4 -> value + value
                else -> value.toString(Charsets.UTF_8).replace("\"sessionId\"", if (random.nextBoolean()) "\"sessionid\"" else "\"sessionId\":5,\"x\"").toByteArray()
            }
        }
        return value
    }

    private fun randomKind(): String = when (random.nextInt(5)) {
        0 -> "features.update"
        1 -> "future.kind" + random.nextInt(100)
        2 -> "k." + "x".repeat(random.nextInt(60, 70))
        3 -> ""
        else -> listOf("pairing.cancel", "files.chunk", "input.pointer", "codes.status", "clipboard.offer").random(random)
    }

    private fun randomString(): String = when (random.nextInt(6)) {
        0 -> ""
        1 -> "x".repeat(random.nextInt(0, 300))
        2 -> String(CharArray(random.nextInt(0, 40)) { random.nextInt(0x20, 0x2FFF).toChar() }.filterNot(Char::isSurrogate).toCharArray())
        3 -> "\u0000\u0007\n\"\\"
        4 -> "é".repeat(random.nextInt(0, 80))
        else -> java.util.UUID.randomUUID().toString()
    }

    private fun randomJson(depth: Int): Any = when (random.nextInt(if (depth > 6) 6 else 9)) {
        0 -> randomString()
        1 -> random.nextInt()
        2 -> random.nextLong()
        3 -> random.nextDouble() * 1e6
        4 -> random.nextBoolean()
        5 -> JSONObject.NULL
        6 -> JSONArray().apply { repeat(random.nextInt(0, 5)) { put(randomJson(depth + 1)) } }
        7 -> JSONObject().apply { repeat(random.nextInt(0, 5)) { put(randomString().take(12), randomJson(depth + 1)) } }
        else -> listOf(Long.MAX_VALUE, Long.MIN_VALUE, JSON_MAX_SAFE_INTEGER + 1, 0, -1, 1).random(random)
    }

    private fun randomPayload(): ByteArray {
        val samples = listOf("featuresUpdate", "batteryUpdate", "clipboardRich", "clipboardOffer", "remoteInput", "browseRef").flatMap { group ->
            vectors.getJSONArray(group).let { array -> (0 until array.length()).map { array.getJSONObject(it).let { v -> v.opt("plaintext")?.toString() ?: v.getString("plaintextString") } } }
        }
        return when (random.nextInt(4)) {
            0 -> random.nextBytes(random.nextInt(0, 4096))
            1 -> mutate(samples.random(random).toByteArray())
            2 -> JSONObject().apply {
                listOf("version", "features", "level", "isCharging", "text", "html", "offerId", "createdAt", "items", "inputSessionId", "sequence",
                    "folderTransferId", "requestId", "places", "entries", "pageCount", "mode",
                    "ref", "mediaId", "placeId", "path", "name", "cursor", "sort", "limit", "replaces").filter { random.nextBoolean() }
                    .forEach { put(it, randomJson(0)) }
            }.toString().toByteArray()
            else -> samples.random(random).toByteArray()
        }
    }

    companion object {
        const val ITERATIONS = 300
    }
}
