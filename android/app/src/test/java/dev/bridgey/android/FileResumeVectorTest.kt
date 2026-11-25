package dev.bridgey.android

import java.io.File
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
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
 * protocol/test-vectors/files-resume-v1.json with this app's own code (FileResume.kt): the prefix hashes, both
 * payloads, the receiver's decision from a record and the bytes on disk, the sender's answer from its kept block hashes,
 * retention, and the designed folder rules. rust/client and the Mac check the same file.
 */
class FileResumeVectorTest {
    private val vector = JSONObject(
        File(System.getProperty("bridgey.repoRoot") ?: "../..", "protocol/test-vectors/files-resume-v1.json").readText(Charsets.UTF_8),
    )

    private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map(::getJSONObject)
    private fun b64(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)
    private fun sha(bytes: ByteArray) = b64(MessageDigest.getInstance("SHA-256").digest(bytes))

    private fun source(): ByteArray {
        val s = vector.getJSONObject("source")
        assertEquals("byte i is (i * 31) mod 251", s.getString("pattern"))
        return ByteArray(s.getInt("size")) { (it * 31 % 251).toByte() }
    }

    private fun plaintext(case: JSONObject): ByteArray =
        if (case.has("plaintextString")) case.getString("plaintextString").toByteArray(Charsets.UTF_8)
        else case.getJSONObject("plaintext").toString().toByteArray(Charsets.UTF_8)

    /** Two JSON objects with the same fields and values, whatever the order. */
    private fun assertSameJson(message: String, expected: JSONObject, actual: JSONObject) {
        val keys = expected.keys().asSequence().toSet()
        assertEquals(message, keys, actual.keys().asSequence().toSet())
        for (key in keys) assertEquals("$message: $key", expected.get(key).toString(), actual.get(key).toString())
    }

    @Test
    fun limitsAreTheProtocols() {
        val limits = vector.getJSONObject("limits")
        assertEquals(FileResume.BLOCK, limits.getLong("blockBytes"))
        assertEquals(FileResume.LIFETIME_MILLIS, limits.getLong("lifetimeMs"))
        assertEquals(FileResume.PER_DEVICE, limits.getInt("perDevice"))
        assertEquals(FileResume.TOTAL, limits.getInt("total"))
        assertEquals(FileResume.MAX_KEPT_BYTES, limits.getLong("maxKeptBytes"))
        assertEquals(FileResume.MAX_MESSAGE, limits.getInt("maxPlaintextBytes"))
        assertEquals(FileResume.CHECKPOINT_EVERY, limits.getLong("checkpointEveryBytes"))
        assertEquals(FileResume.BLOCK, limits.getLong("resumableAbove"))
        assertEquals(FileResume.ANSWER_WINDOW_MILLIS / 1000, limits.getLong("answerWithinSeconds"))
        assertFalse(FileResume.resumable(FileResume.BLOCK))
        assertTrue(FileResume.resumable(FileResume.BLOCK + 1))
    }

    @Test
    fun prefixHashesMatchAndTheRunningHashContinuesToTheWholeFile() {
        val data = source()
        val whole = vector.getJSONObject("source").getString("sha256")
        assertEquals(whole, sha(data))
        for (p in vector.getJSONArray("prefixes").objects()) {
            val n = p.getLong("offset")
            val (digest, prefix) = RunningHash.prefixOf(data.inputStream(), n)
            assertEquals("prefix $n", p.getString("prefixSha256"), b64(prefix))
            // The receiver's running hash continues from the verified prefix to the whole file's SHA-256.
            val resumed = RunningHash.resumed(digest, n, prefix)
            resumed.update(data, n.toInt(), data.size - n.toInt())
            assertEquals("continued from $n", whole, b64(resumed.finish()))
        }
        assertTrue(runCatching { RunningHash.prefixOf(data.inputStream(), data.size + 1L) }.isFailure)
        // The sender's pass keeps every block's hash; the receiver's checkpoint is a block boundary or the whole file.
        val (sha256, size, blocks) = RunningHash.of(data.inputStream(), ByteArray(24 * 1024 + 7))
        assertEquals(whole, b64(sha256))
        assertEquals(data.size.toLong(), size)
        assertEquals((size / FileResume.BLOCK).toInt(), blocks.count)
        val running = RunningHash(keepAll = false)
        var at = 0
        while (at < data.size) {
            val n = minOf(24 * 1024 + 7, data.size - at)
            running.update(data, at, n)
            at += n
            val (length, digest) = running.checkpoint(size)
            assertTrue(length == size || length % FileResume.BLOCK == 0L)
            assertEquals(b64(RunningHash.prefixOf(data.inputStream(), length).second), b64(digest))
        }
        for (p in vector.getJSONArray("prefixes").objects()) {
            val n = p.getLong("offset")
            val kept = if (n == size) sha256 else blocks.prefix(n)
            assertEquals("block hash at $n", p.getString("prefixSha256"), kept?.let(::b64))
        }
        assertNull(blocks.prefix(FileResume.BLOCK + 1))
        assertNull(blocks.prefix(0))
        assertNull(blocks.prefix(4 * FileResume.BLOCK))
    }

    @Test
    fun resumePayloadsDecodeAsTheVectorsSay() {
        val cases = vector.getJSONArray("resumePayload").objects()
        assertTrue(cases.size >= 10)
        for (case in cases) {
            val name = case.getString("name")
            val got = FileResume.parseResume(plaintext(case), case.getString("transferId"), case.getLong("size"))
            val expect = case.get("expect")
            if (expect == "invalid") {
                assertNull("$name is invalid", got)
                continue
            }
            expect as JSONObject
            assertNotNull("$name decodes", got)
            assertEquals(name, expect.getLong("offset"), got!!.first)
            assertEquals(name, expect.getString("prefixSha256"), b64(got.second))
            if (case.optBoolean("write")) {
                val written = JSONObject(String(FileResume.resumePayload(case.getString("transferId"), got.first, got.second), Charsets.UTF_8))
                assertSameJson("$name writes the same fields", case.getJSONObject("plaintext"), written)
            }
        }
    }

    @Test
    fun acksDecodeAsTheVectorsSay() {
        for (case in vector.getJSONArray("ackPayload").objects()) {
            val name = case.getString("name")
            val got = FileResume.parseAck(plaintext(case), case.getString("transferId"), case.getLong("proposed"))
            when (case.getString("expect")) {
                "invalid" -> assertNull(name, got)
                "resume" -> assertEquals(name, case.getLong("proposed"), got)
                "restart" -> assertEquals(name, 0L, got)
                else -> error(name)
            }
            if (case.optBoolean("write")) {
                val p = case.getJSONObject("plaintext")
                val written = JSONObject(String(FileResume.ackPayload(p.getString("transferId"), p.getLong("offset"), p.optString("reason").ifEmpty { null }), Charsets.UTF_8))
                assertSameJson("$name writes the same fields", p, written)
            }
        }
    }

    /** The receiver's decision for an offer from its record and what is on disk, as the session makes it. */
    @Test
    fun receiverDecisionsFollowTheVectors() {
        val data = source()
        val dir = kotlin.io.path.createTempDirectory("resume-decide").toFile()
        try {
            for (case in vector.getJSONArray("receiverDecision").objects()) {
                val name = case.getString("name")
                val r = case.getJSONObject("record")
                val part = File(dir, ".bridgey-${UUID.randomUUID()}.part")
                val onDisk = data.copyOf(r.getInt("partLength"))
                if (r.has("flipByte")) onDisk[r.getInt("flipByte")] = (onDisk[r.getInt("flipByte")].toInt() xor 0xFF).toByte()
                if (r.optBoolean("partExists", true)) part.writeBytes(onDisk)
                val record = ResumeRecord(
                    peer = r.getString("peer"), size = r.getLong("size"), sha256 = r.getString("sha256"), length = r.getLong("length"),
                    prefix = r.getString("prefixSha256"), dir = FileResume.RECEIVE_DIR, part = part.path, name = r.getString("name"), updated = 0,
                )
                var store = ResumeStore()
                store.save(record, r.getLong("updatedMs"))
                store.release(part.path, keep = true)
                val now = case.getLong("nowMs")
                if (case.optBoolean("afterRestart")) {
                    store = ResumeStore.decode(store.encode()) { true }
                    store.sweep(now) { path -> File(path).takeIf(File::exists)?.length() }.forEach { File(it).delete() }
                }
                val o = case.getJSONObject("offer")
                val (found, gone) = store.claim(o.getString("peer"), o.getLong("size"), o.getString("sha256"), o.getString("name"), FileResume.RECEIVE_DIR, now)
                gone.forEach { File(it).delete() }
                // What the session does with a claimed record: read its prefix again and compare.
                val verified = found?.let { f ->
                    runCatching { File(f.part).inputStream().use { RunningHash.prefixOf(it, f.length) } }.getOrNull()
                        ?.takeIf { b64(it.second) == f.prefix }?.let { f.length }
                }
                val expect = case.getJSONObject("expect")
                assertEquals("$name: resume offset", if (expect.isNull("resumeAt")) null else expect.getLong("resumeAt"), verified)
                if (expect.has("dropsRecord")) {
                    assertEquals("$name: the record is dropped", expect.getBoolean("dropsRecord"), store.records.none { it.part == part.path })
                }
                part.delete()
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    /** The sender's answer to a files.resume from its own file: from the block hashes kept while hashing, and read again. */
    @Test
    fun senderDecisionsFollowTheVectors() {
        val data = source()
        for (case in vector.getJSONArray("senderDecision").objects()) {
            val name = case.getString("name")
            var file = data.copyOf()
            if (case.has("senderFlipByte")) file[case.getInt("senderFlipByte")] = (file[case.getInt("senderFlipByte")].toInt() xor 0xFF).toByte()
            if (case.has("senderLength")) file = file.copyOf(case.getInt("senderLength"))
            val t = case.getString("transferId")
            val plain = case.getJSONObject("resume").toString().toByteArray(Charsets.UTF_8)
            val (sha256, size, blocks) = RunningHash.of(file.inputStream())
            val (offset, reason) = FileResume.senderAnswer(plain, t, size, sha256, blocks)
            val expect = case.getJSONObject("expect")
            assertEquals(name, expect.getLong("offset"), offset)
            assertEquals(name, if (expect.isNull("reason")) null else expect.getString("reason"), reason)
            val reread = FileResume.parseResume(plain, t, size)?.let { (n, prefix) ->
                val ours = RunningHash.prefixOf(file.inputStream(), n).second
                if (MessageDigest.isEqual(ours, prefix)) n to null else 0L to "mismatch"
            } ?: (0L to "invalid")
            assertEquals("$name: read again", offset to reason, reread)
        }
    }

    @Test
    fun retentionFollowsTheVectors() {
        for (case in vector.getJSONArray("retention").objects()) {
            val name = case.getString("name")
            val store = ResumeStore()
            val labels = mutableMapOf<String, String>()
            fun record(peer: String, n: Long, length: Long?): ResumeRecord {
                val l = length ?: 10L
                return ResumeRecord(peer, maxOf(1000 + n, l), sha(longToBytes(n)), l, sha("x".toByteArray()), FileResume.RECEIVE_DIR,
                    "content://media/external/downloads/${UUID.randomUUID()}", "file$n.bin", 0)
            }
            for (k in case.getJSONArray("kept").objects()) {
                val r = record(k.getString("peer"), k.getLong("n"), if (k.has("length")) k.getLong("length") else null)
                labels[r.part] = k.getString("label")
                store.save(r, k.getLong("updatedMs"))
                if (!k.optBoolean("inUse")) store.release(r.part, keep = true)
            }
            val n = case.getJSONObject("new")
            val gone = store.save(record(n.getString("peer"), 9999, if (n.has("length")) n.getLong("length") else null), n.getLong("updatedMs"))
            val expected = case.getJSONArray("evicted").let { a -> (0 until a.length()).map(a::getString) }
            assertEquals(name, expected, gone.map { labels.getValue(it) })
        }
    }

    /** Folders are designed, not built: the rules from docs/protocol.md, so the vectors are checked here too. */
    @Test
    fun folderVectorsFollowTheDesignedRules() {
        for (case in vector.getJSONArray("folderAccept").objects()) {
            val name = case.getString("name")
            val decoded: Any? = if (case.isNull("partial")) "none" else run {
                val p = case.getJSONObject("partial")
                val entry = jsonInteger(p.opt("entry"))?.takeIf { it >= 0 } ?: return@run null
                val size = case.getJSONObject("entrySizes").optLong(entry.toString(), -1).takeIf { it >= 0 } ?: return@run null
                val offset = jsonInteger(p.opt("offset"))?.takeIf { it in 1..size && (it % FileResume.BLOCK == 0L || it == size) } ?: return@run null
                val prefix = FileResume.hash32(p.optString("prefixSha256")) ?: return@run null
                JSONObject().put("entry", entry).put("offset", offset).put("prefixSha256", b64(prefix))
            }
            when (val expect = case.get("expect")) {
                "none" -> assertEquals(name, "none", decoded)
                "invalid" -> assertNull(name, decoded)
                else -> assertSameJson(name, expect as JSONObject, decoded as JSONObject)
            }
        }
        for (case in vector.getJSONArray("entryOffer").objects()) {
            val name = case.getString("name")
            val partial = if (case.isNull("receiverPartial")) null else case.getJSONObject("receiverPartial")
            val offer = case.getJSONObject("entryOffer")
            val expect = case.getJSONObject("expect")
            val sameEntry = partial != null && partial.getInt("entry") == offer.getInt("entry")
            if (!offer.has("offset")) {
                assertEquals(name, 0L, expect.getLong("startAt"))
                assertEquals(name, sameEntry, expect.optBoolean("discardsPartial"))
            } else {
                val n = offer.getLong("offset")
                if (sameEntry && partial!!.getLong("offset") == n && n <= offer.getLong("size")) assertEquals(name, n, expect.getLong("startAt"))
                else assertEquals(name, "invalid_message", expect.getString("entryFailed"))
            }
        }
    }

    @Test
    fun recordsSurviveEncodingAndBadOnesAreDropped() {
        val good = ResumeRecord("7E57D00D-0000-4000-8000-0000000000AA", 5_000_000, sha("a".toByteArray()), 1_048_576, sha("b".toByteArray()),
            FileResume.RECEIVE_DIR, "content://media/external/downloads/42", "photo.jpg", 5)
        val store = ResumeStore()
        store.save(good, 5)
        val back = ResumeStore.decode(store.encode()) { it.startsWith("content://media/") }
        assertEquals(store.records, back.records)
        assertEquals("peer IDs are kept lowercase", good.peer.lowercase(), back.records.single().peer)
        val json = good.toJson()
        val bad = listOf(
            JSONObject(json.toString()).put("part", "file:///data/data/dev.bridgey/shared_prefs/x.xml"),
            JSONObject(json.toString()).put("prefix", "AAAA"),
            JSONObject(json.toString()).put("length", good.size + 1),
            JSONObject(json.toString()).put("peer", "not a device"),
            JSONObject(json.toString()).put("length", "1048576"),
        )
        val doc = JSONObject().put("version", 1).put("records", JSONArray(bad + json))
        assertEquals(1, ResumeStore.decode(doc.toString().toByteArray()) { it.startsWith("content://media/") }.records.size)
        assertTrue(ResumeStore.decode("{\"version\":2,\"records\":[]}".toByteArray()) { true }.records.isEmpty())
        assertTrue(ResumeStore.decode("not json".toByteArray()) { true }.records.isEmpty())
        assertTrue(ResumeStore.decode(null) { true }.records.isEmpty())
    }

    @Test
    fun claimsArePerDeviceOneAtATimeAndOnlyInTheReceiveFolder() {
        val peer = "7e57d00d-0000-4000-8000-0000000000aa"
        val other = "7e57d00d-0000-4000-8000-0000000000bb"
        val store = ResumeStore()
        val r = ResumeRecord(peer, 5_000_000, sha("a".toByteArray()), 1_048_576, sha("b".toByteArray()), FileResume.RECEIVE_DIR, "content://media/x/1", "a.bin", 0)
        store.save(r, 100)
        store.release(r.part, keep = true)
        assertNull("another device never gets it", store.claim(other, r.size, r.sha256, r.name, FileResume.RECEIVE_DIR, 200).first)
        assertEquals("nor disturbs it", 1, store.records.size)
        assertEquals(r.part, store.claim(peer, r.size, r.sha256, r.name, FileResume.RECEIVE_DIR, 200).first?.part)
        val (again, gone) = store.claim(peer, r.size, r.sha256, r.name, FileResume.RECEIVE_DIR, 200)
        assertNull("a partial in use serves one transfer", again)
        assertTrue(gone.isEmpty())
        assertTrue(store.release(r.part, keep = false))
        assertTrue(store.records.isEmpty())
        store.save(r, 300)
        store.release(r.part, keep = true)
        val (elsewhere, dropped) = store.claim(peer, r.size, r.sha256, r.name, "Download/Elsewhere/", 300)
        assertNull("only in the folder files land in now", elsewhere)
        assertEquals("the same content kept elsewhere can no longer be resumed", listOf(r.part), dropped)
        store.save(r, 400)
        store.release(r.part, keep = true)
        assertEquals(listOf(r.part), store.forget(peer.uppercase()))
        assertTrue(store.records.isEmpty())
    }

    private fun longToBytes(n: Long) = java.nio.ByteBuffer.allocate(8).putLong(n).array()

    @Test
    fun theFeatureKeyIsKnownAndListed() {
        assertTrue(FILES_RESUME_FEATURE_KEY in KNOWN_DRAFT_FEATURE_KEYS)
        assertEquals(KNOWN_DRAFT_FEATURE_KEYS.indexOf(FILES_FAST_FEATURE_KEY) + 1, KNOWN_DRAFT_FEATURE_KEYS.indexOf(FILES_RESUME_FEATURE_KEY))
        assertArrayEquals(FileResume.hash32(b64(ByteArray(32))), ByteArray(32))
    }
}
