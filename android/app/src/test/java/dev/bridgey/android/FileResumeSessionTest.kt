package dev.bridgey.android

import android.app.Application
import android.content.ContentProvider
import android.content.ContentUris
import android.content.ContentValues
import android.database.MatrixCursor
import android.net.Uri
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

/**
 * Resuming files (draft files_resume_draft1) with the real PairingCoordinator and a fake Mac over loopback, both ways:
 * the phone answering a Mac that kept part of a file, the phone keeping a partial in a (fake) MediaStore when the Mac
 * drops, reconnects or the phone restarts, and starting from zero when there is nothing safe to resume (tampered,
 * expired, changed source, a peer without the key), cancels and forgetting, the 120-second wait kept open by
 * files.resume.wait, and Resume interrupted files automatically on and off.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@LooperMode(LooperMode.Mode.PAUSED)
class FileResumeSessionTest {
    private val loopback = InetAddress.getLoopbackAddress()
    private val macId = "7e57d00d-0000-4000-8000-0000000000aa"
    private val phoneId = UUID.randomUUID().toString()
    private val macIdentity = java.security.KeyPairGenerator.getInstance("EC")
        .apply { initialize(java.security.spec.ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    private val macIdentityKey = Crypto.encodePublicKey(macIdentity)
    private val context get() = ApplicationProvider.getApplicationContext<Application>()
    private val recordFile get() = File(context.noBackupFilesDir, "file-resume.json")
    private lateinit var storeDir: File

    @Before
    fun setUp() {
        org.robolectric.shadows.ShadowLog.stream = System.out
        FakeAndroidKeyStore.install()
        storeDir = kotlin.io.path.createTempDirectory("fake-mediastore").toFile()
        FakeMediaStore.reset(storeDir)
        Robolectric.setupContentProvider(FakeMediaStore::class.java, "media")
        // Room in Download for the phone's free-space check (Robolectric reports none by default).
        org.robolectric.shadows.ShadowStatFs.registerStats(
            android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS), 1_000_000, 1_000_000, 1_000_000,
        )
        recordFile.delete()
    }

    @After
    fun tearDown() {
        storeDir.deleteRecursively()
    }

    // MARK: The fake Mac

    private class Peer(val socket: Socket) {
        val frames = ProtocolStreamReader(socket.getInputStream())
        val output = socket.getOutputStream()

        fun read(): JSONObject = JSONObject((frames.next() as? ProtocolFrame.Json ?: error("closed or binary")).text)

        fun write(frame: JSONObject) {
            synchronized(this) {
                output.write((frame.toString() + "\n").toByteArray())
                output.flush()
            }
        }
    }

    /** An authenticated protocol 2 session with the phone. */
    private inner class Link(val peer: Peer, val key: ByteArray, val session: String) {
        fun send(message: Message) {
            val tagged = message.copy(tag = SessionSecurity.tag(SessionSecurity.envelopeKey(key), macId, message))
            peer.write(JSONObject(tagged.encode()))
        }

        fun outer(kind: String, transferId: String, sequence: Long? = null) =
            send(Message(kind = kind, sessionId = session, transferId = transferId, sequence = sequence))

        fun encrypted(kind: String, payload: ByteArray, transferId: String? = null, sequence: Long? = null) {
            val sealed = Crypto.encrypt(key, payload)
            send(Message(kind = kind, sessionId = session, messageId = UUID.randomUUID().toString(), transferId = transferId, sequence = sequence,
                nonce = sealed.nonce, ciphertext = sealed.ciphertext))
        }

        fun open(message: Message): ByteArray = Crypto.decrypt(key, message.nonce!!, message.ciphertext!!)!!

        /** Frames until [kind] (everything else is skipped), failing after 30 seconds without it. */
        fun until(kind: String): Message = next(setOf(kind), 30_000) ?: error("no $kind within 30 s")

        /** The next frame of one of [kinds], or null when the phone sends none within [millis]. */
        fun next(kinds: Set<String>, millis: Long): Message? {
            val end = System.currentTimeMillis() + millis
            try {
                while (true) {
                    val left = end - System.currentTimeMillis()
                    if (left <= 0) return null
                    peer.socket.soTimeout = left.toInt()
                    val frame = try {
                        peer.frames.next()
                    } catch (_: java.net.SocketTimeoutException) {
                        return null
                    } ?: return null
                    if (frame is ProtocolFrame.Json) {
                        val message = Message.decode(frame.text)
                        if (message.kind in kinds) return message
                    }
                }
            } finally {
                runCatching { peer.socket.soTimeout = 30_000 }
            }
        }

        fun features(resume: Boolean, fast: Boolean = false) {
            val features = JSONObject().apply {
                BridgeyFeature.entries.forEach { put(it.key, true) }
                put(FILES_FAST_FEATURE_KEY, fast)
                put(FILES_RESUME_FEATURE_KEY, resume)
            }
            encrypted("features.update", JSONObject().put("version", 1).put("features", features).toString().toByteArray())
            Thread.sleep(300)
        }

        fun close() = runCatching { peer.socket.close() }
    }

    private fun waitFor(timeoutMillis: Long, condition: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < end) {
            // Work the coordinator posts to the main thread (retries, Main.immediate from other threads) runs here.
            shadowOf(Looper.getMainLooper()).idle()
            if (condition()) return true
            Thread.sleep(50)
        }
        return condition()
    }

    private fun freePort() = ServerSocket(0, 1, loopback).use { it.localPort }

    private fun coordinator(port: Int = freePort()): PairingCoordinator =
        PairingCoordinator(context, phoneId, "Test phone", port = port, settings = BridgeySettings(context, "Test phone"))

    /** A first pairing the phone starts with the fake Mac, then both features maps. */
    private fun pair(pairing: PairingCoordinator, server: ServerSocket, resume: Boolean = true, fast: Boolean = false): Link {
        pairing.pair(loopback.hostAddress!!, server.localPort, "Fake Mac")
        server.soTimeout = 10_000
        var peer: Peer
        var offer: JSONObject
        while (true) {
            peer = Peer(server.accept())
            offer = runCatching { peer.read() }.getOrNull() ?: continue
            if (offer.optString("kind") == "pairing.offer") break
        }
        peer.socket.soTimeout = 30_000
        val sessionId = offer.getString("sessionId")
        val mine = Crypto.generateKeyPair()
        val minePublic = Crypto.encodePublicKey(mine)
        peer.write(JSONObject().put("kind", "pairing.answer").put("sessionId", sessionId).put("deviceId", macId)
            .put("deviceName", "Fake Mac").put("publicKey", minePublic).put("protocolVersion", 2))
        val phonePublic = peer.read().getString("publicKey")
        val material = Crypto.pairingMaterial(mine, phonePublic, sessionId, sasKeys = phonePublic to minePublic)
        assertTrue(waitFor(5_000) { pairing.pairingFlow.value is PairingState.Verification })
        pairing.confirm((pairing.pairingFlow.value as PairingState.Verification).token)
        assertEquals("pairing.confirm", peer.read().getString("kind"))
        peer.write(confirm(sessionId, material.key, listOf(phoneId, macId, phonePublic, minePublic)))
        assertTrue("paired", waitFor(5_000) { connected(pairing) })
        val link = Link(peer, material.key, sessionId)
        // The fake Mac reads the phone's binary frames when it shows files_fast_draft1 (and skips them).
        peer.frames.binaryAllowed = fast
        link.until("features.update")
        link.features(resume, fast)
        return link
    }

    /** The fake Mac reconnects as the trusted device it is: it dials the phone, no code. */
    private fun reconnect(pairing: PairingCoordinator, port: Int, resume: Boolean = true): Link {
        assertTrue("the old session ended", waitFor(10_000) { !connected(pairing) })
        val peer = Peer(Socket(loopback, port).apply { soTimeout = 30_000 })
        val sessionId = UUID.randomUUID().toString()
        val mine = Crypto.generateKeyPair()
        val minePublic = Crypto.encodePublicKey(mine)
        peer.write(JSONObject().put("kind", "pairing.offer").put("sessionId", sessionId).put("deviceId", macId).put("deviceName", "Fake Mac")
            .put("publicKey", minePublic).put("targetDeviceId", phoneId).put("protocolVersion", 2))
        val answer = peer.read()
        assertEquals("pairing.answer", answer.getString("kind"))
        val phonePublic = answer.getString("publicKey")
        val material = Crypto.pairingMaterial(mine, phonePublic, sessionId)
        peer.write(confirm(sessionId, material.key, listOf(macId, phoneId, minePublic, phonePublic)))
        assertTrue("reconnected", waitFor(10_000) { connected(pairing) })
        val link = Link(peer, material.key, sessionId)
        link.until("features.update")
        link.features(resume)
        return link
    }

    private fun confirm(sessionId: String, key: ByteArray, transcriptParts: List<String>): JSONObject {
        val transcript = (listOf("bridgey-auth-v1", sessionId) + transcriptParts).joinToString("\u0000").toByteArray()
        val signature = java.security.Signature.getInstance("SHA256withECDSA").apply { initSign(macIdentity.private); update(transcript) }.sign()
        return JSONObject().put("kind", "pairing.confirm").put("sessionId", sessionId).put("deviceId", macId).put("identityKey", macIdentityKey)
            .put("proof", Crypto.confirmationProof(key, sessionId, macId, macIdentityKey))
            .put("signature", Base64.getEncoder().encodeToString(signature))
    }

    private fun connected(pairing: PairingCoordinator) = pairing.connections.value.any { it.deviceId == macId }

    // MARK: Files

    private val mib = FileResume.BLOCK
    /** Not a whole number of blocks, so the tail is short. */
    private val size = 3 * 1024 * 1024 + 12_345
    private fun pattern(length: Int = size, salt: Int = 0) = ByteArray(length) { ((it * 31 % 251) xor salt).toByte() }
    private fun sha(bytes: ByteArray, length: Int = bytes.size): ByteArray = MessageDigest.getInstance("SHA-256").apply { update(bytes, 0, length) }.digest()
    private fun b64(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)

    private fun records(): List<JSONObject> = runCatching {
        JSONObject(recordFile.readText()).getJSONArray("records").let { a -> (0 until a.length()).map(a::getJSONObject) }
    }.getOrDefault(emptyList())

    /** The fake Mac offers [data] as `video.mov`; returns the transfer ID. */
    private fun offer(link: Link, data: ByteArray, resumable: Boolean = true, name: String = "video.mov"): String {
        val id = UUID.randomUUID().toString()
        val payload = JSONObject().put("transferId", id).put("name", name).put("mimeType", "video/quicktime").put("size", data.size)
            .put("sha256", b64(sha(data))).apply { if (resumable) put("resumable", true) }
        link.encrypted("files.offer", payload.toString().toByteArray(), transferId = id)
        return id
    }

    /** JSON chunks of 24 KiB from [from] to [to], numbered from 0; waits until the phone acknowledged the last. */
    private fun chunks(link: Link, id: String, data: ByteArray, from: Int, to: Int) {
        var sequence = 0L
        var at = from
        while (at < to) {
            val n = minOf(24 * 1024, to - at)
            link.encrypted("files.chunk", data.copyOfRange(at, at + n), transferId = id, sequence = sequence++)
            at += n
        }
        if (sequence == 0L) return
        while (true) {
            val ack = link.until("files.chunk.ack")
            if (ack.transferId == id && ack.sequence == sequence - 1) return
        }
    }

    private fun complete(link: Link, id: String, data: ByteArray) {
        link.encrypted("files.complete", JSONObject().put("transferId", id).put("sha256", b64(sha(data))).toString().toByteArray())
        assertEquals(id, link.until("files.complete.ack").transferId)
    }

    /** The phone keeps the first 2 MiB of a file the Mac stopped sending 3 chunks past them, then the Mac drops. */
    private fun interruptedReceive(link: Link, data: ByteArray): String {
        val id = offer(link, data)
        assertEquals(id, link.until("files.accept").transferId)
        chunks(link, id, data, 0, (2 * mib + 3 * 24 * 1024).toInt())
        link.close()
        assertTrue("the partial is recorded: ${records()}", waitFor(10_000) { records().singleOrNull()?.getLong("length") == 2 * mib })
        return id
    }

    private fun theRow(): FakeMediaStore.Row = FakeMediaStore.rows.values.single()

    // MARK: Receiving

    @Test
    fun aMacThatDropsMidFileResumesFromTheKeptBlocks() {
        ServerSocket(0, 8, loopback).use { server ->
            val port = freePort()
            val pairing = coordinator(port)
            pairing.start()
            // The phone re-reads its partial slowly enough to say it is still reading.
            pairing.resumeRereadHoldMillis = 1_000
            pairing.resumeWaitEveryMillis = 300
            val data = pattern()
            interruptedReceive(pair(pairing, server), data)
            val row = theRow()
            assertTrue("kept as a pending entry", row.pending)
            assertTrue(FakeMediaStore.file(row.id).length() >= 2 * mib)

            val link = reconnect(pairing, port)
            val id = offer(link, data)
            val wait = link.next(setOf("files.resume.wait"), 5_000)
            assertEquals("still reading", id, wait?.transferId)
            assertNull("outer only", wait?.ciphertext)
            val resume = link.until("files.resume")
            assertEquals(id, resume.transferId)
            val (offset, prefix) = FileResume.parseResume(link.open(resume), id, data.size.toLong())!!
            assertEquals(2 * mib, offset)
            assertArrayEquals(sha(data, offset.toInt()), prefix)
            link.encrypted("files.resume.ack", FileResume.ackPayload(id, offset, null), transferId = id)
            chunks(link, id, data, offset.toInt(), data.size)
            complete(link, id, data)
            assertArrayEquals("the whole file, in the same entry", data, FakeMediaStore.file(row.id).readBytes())
            assertFalse(theRow().pending)
            assertTrue("no record left", records().isEmpty())
            assertEquals(TransferEnd.RECEIVED, pairing.fileTransfers.value[id]?.outcome)
            link.close()
            pairing.stop()
        }
    }

    @Test
    fun afterARestartTheKeptPartialStillResumes() {
        ServerSocket(0, 8, loopback).use { server ->
            val port = freePort()
            val first = coordinator(port)
            first.start()
            val data = pattern()
            interruptedReceive(pair(first, server), data)
            first.stop()
            // A new process: the record and the pending entry are all that is left.
            val pairing = coordinator(port)
            pairing.start()
            Thread.sleep(500)
            assertEquals("the sweep at start keeps a good partial", 1, FakeMediaStore.rows.size)
            val link = reconnect(pairing, port)
            val id = offer(link, data)
            val (offset, _) = FileResume.parseResume(link.open(link.until("files.resume")), id, data.size.toLong())!!
            assertEquals(2 * mib, offset)
            link.encrypted("files.resume.ack", FileResume.ackPayload(id, offset, null), transferId = id)
            chunks(link, id, data, offset.toInt(), data.size)
            complete(link, id, data)
            assertArrayEquals(data, FakeMediaStore.file(theRow().id).readBytes())
            link.close()
            pairing.stop()
        }
    }

    @Test
    fun theSenderAnsweringZeroEmptiesThePartialAndTheFileComesWhole() {
        ServerSocket(0, 8, loopback).use { server ->
            val port = freePort()
            val pairing = coordinator(port)
            pairing.start()
            val data = pattern()
            interruptedReceive(pair(pairing, server), data)
            val link = reconnect(pairing, port)
            val id = offer(link, data)
            link.until("files.resume")
            link.encrypted("files.resume.ack", FileResume.ackPayload(id, 0, "mismatch"), transferId = id)
            chunks(link, id, data, 0, data.size)
            complete(link, id, data)
            assertArrayEquals(data, FakeMediaStore.file(theRow().id).readBytes())
            link.close()
            pairing.stop()
        }
    }

    @Test
    fun anAckWithAnotherOffsetCancelsAndDeletesThePartial() {
        ServerSocket(0, 8, loopback).use { server ->
            val port = freePort()
            val pairing = coordinator(port)
            pairing.start()
            val data = pattern()
            interruptedReceive(pair(pairing, server), data)
            val link = reconnect(pairing, port)
            val id = offer(link, data)
            link.until("files.resume")
            link.encrypted("files.resume.ack", FileResume.ackPayload(id, mib, null), transferId = id)
            assertEquals(id, link.next(setOf("files.cancel"), 5_000)?.transferId)
            assertTrue(waitFor(5_000) { FakeMediaStore.rows.isEmpty() && records().isEmpty() })
            link.close()
            pairing.stop()
        }
    }

    /** A kept partial needs room only for the rest: with too little space for the whole file, the resume still goes. */
    @Test
    fun aResumeNeedsRoomOnlyForTheRest() {
        ServerSocket(0, 8, loopback).use { server ->
            val port = freePort()
            val pairing = coordinator(port)
            pairing.start()
            val data = pattern()
            interruptedReceive(pair(pairing, server), data)
            // Room for the 64 MiB margin and the last 1.1 MB, not for the whole 3.1 MB file.
            val downloads = android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS)
            val room = dev.bridgey.android.folders.FolderLimits.SPACE_MARGIN + (data.size - 2 * mib) + 100_000
            org.robolectric.shadows.ShadowStatFs.registerStats(downloads, 1_000_000, (room / 4096).toInt(), (room / 4096).toInt())
            val link = reconnect(pairing, port)
            val id = offer(link, data)
            assertEquals("files.resume", link.next(setOf("files.resume", "files.cancel", "files.accept"), 10_000)?.kind)
            link.encrypted("files.resume.ack", FileResume.ackPayload(id, 2 * mib, null), transferId = id)
            chunks(link, id, data, (2 * mib).toInt(), data.size)
            complete(link, id, data)
            // The same file offered whole now does not fit.
            val other = pattern(salt = 0x33)
            offer(link, other, name = "other.mov")
            assertEquals("files.cancel", link.next(setOf("files.resume", "files.cancel", "files.accept"), 10_000)?.kind)
            link.close()
            pairing.stop()
        }
    }

    @Test
    fun aTamperedPartialStartsFromZero() {
        ServerSocket(0, 8, loopback).use { server ->
            val port = freePort()
            val pairing = coordinator(port)
            pairing.start()
            val data = pattern()
            interruptedReceive(pair(pairing, server), data)
            val file = FakeMediaStore.file(theRow().id)
            val bytes = file.readBytes()
            bytes[1000] = (bytes[1000].toInt() xor 0xFF).toByte()
            file.writeBytes(bytes)
            val link = reconnect(pairing, port)
            val id = offer(link, data)
            assertEquals("the kept bytes no longer match their record", "files.accept", link.next(setOf("files.accept", "files.resume"), 10_000)?.kind)
            assertEquals(0L, records().single().getLong("length"))
            chunks(link, id, data, 0, data.size)
            complete(link, id, data)
            assertArrayEquals(data, FakeMediaStore.file(theRow().id).readBytes())
            link.close()
            pairing.stop()
        }
    }

    @Test
    fun aChangedSourceDropsTheOldPartial() {
        ServerSocket(0, 8, loopback).use { server ->
            val port = freePort()
            val pairing = coordinator(port)
            pairing.start()
            interruptedReceive(pair(pairing, server), pattern())
            val old = theRow().id
            val link = reconnect(pairing, port)
            // Same name and size, other bytes.
            offer(link, pattern(salt = 0x5A))
            assertEquals("files.accept", link.next(setOf("files.accept", "files.resume"), 10_000)?.kind)
            assertNull("the old partial went", FakeMediaStore.rows[old])
            link.close()
            pairing.stop()
        }
    }

    @Test
    fun anExpiredPartialAndAnOrphanEntryAreSweptAtStart() {
        ServerSocket(0, 8, loopback).use { server ->
            val port = freePort()
            val first = coordinator(port)
            first.start()
            interruptedReceive(pair(first, server), pattern())
            first.stop()
            val kept = theRow().id
            // A day and a minute later.
            val doc = JSONObject(recordFile.readText())
            val record = doc.getJSONArray("records").getJSONObject(0)
            record.put("updated", record.getLong("updated") - FileResume.LIFETIME_MILLIS - 60_000)
            recordFile.writeText(doc.toString())
            // A pending entry no record names (a process death used to leave these), a finished file, and a folder's.
            val resolver = context.contentResolver
            fun entry(name: String, pending: Int, path: String = "Download/Bridgey") = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.RELATIVE_PATH, path)
                put(MediaStore.Downloads.IS_PENDING, pending)
            })!!
            val orphan = entry("lost.bin", 1)
            val finished = entry("done.bin", 0)
            val folderEntry = entry("inside-a-folder.bin", 1, "Download/Bridgey/Photos")
            val pairing = coordinator(port)
            pairing.start()
            assertTrue("swept", waitFor(5_000) { FakeMediaStore.rows[kept] == null && FakeMediaStore.rows[ContentUris.parseId(orphan)] == null })
            assertTrue(records().isEmpty())
            assertNotNull("finished files stay", FakeMediaStore.rows[ContentUris.parseId(finished)])
            assertNotNull("folders keep their own", FakeMediaStore.rows[ContentUris.parseId(folderEntry)])
            pairing.stop()
        }
    }

    @Test
    fun aCancelFromTheMacDeletesThePartial() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val link = pair(pairing, server)
            val data = pattern()
            val id = offer(link, data)
            link.until("files.accept")
            chunks(link, id, data, 0, (2 * mib + 24 * 1024).toInt())
            link.outer("files.cancel", id)
            link.until("files.cancel.ack")
            assertTrue(waitFor(5_000) { FakeMediaStore.rows.isEmpty() })
            assertTrue(records().isEmpty())
            link.close()
            assertTrue(waitFor(5_000) { !connected(pairing) })
            Thread.sleep(300)
            assertTrue("nothing kept after the drop either", FakeMediaStore.rows.isEmpty() && records().isEmpty())
        }
    }

    @Test
    fun aCancelOnThePhoneDeletesThePartial() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val link = pair(pairing, server)
            val data = pattern()
            val id = offer(link, data)
            link.until("files.accept")
            chunks(link, id, data, 0, (2 * mib + 24 * 1024).toInt())
            pairing.cancelFileTransfer(id)
            assertEquals(id, link.until("files.cancel").transferId)
            assertTrue(waitFor(5_000) { FakeMediaStore.rows.isEmpty() && records().isEmpty() })
            link.close()
        }
    }

    @Test
    fun forgettingTheMacDeletesItsPartials() {
        ServerSocket(0, 8, loopback).use { server ->
            val port = freePort()
            val pairing = coordinator(port)
            pairing.start()
            interruptedReceive(pair(pairing, server), pattern())
            assertEquals(1, FakeMediaStore.rows.size)
            pairing.forget(macId)
            assertTrue(waitFor(5_000) { FakeMediaStore.rows.isEmpty() })
            assertTrue(records().isEmpty())
            pairing.stop()
        }
    }

    @Test
    fun aMacWithoutTheKeyKeepsTheOldBehaviour() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val link = pair(pairing, server, resume = false)
            val data = pattern()
            // Even an offer marked resumable is not, from a Mac without the key.
            val id = offer(link, data, resumable = true)
            link.until("files.accept")
            chunks(link, id, data, 0, (2 * mib + 24 * 1024).toInt())
            link.close()
            assertTrue(waitFor(10_000) { !connected(pairing) })
            assertTrue("the partial goes on an interruption", waitFor(5_000) { FakeMediaStore.rows.isEmpty() })
            assertTrue(records().isEmpty())
        }
    }

    @Test
    fun aSmallFileIsNeverKept() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val link = pair(pairing, server)
            val data = pattern(length = mib.toInt())
            val id = offer(link, data, resumable = true)
            link.until("files.accept")
            chunks(link, id, data, 0, 500_000)
            link.close()
            assertTrue(waitFor(10_000) { !connected(pairing) && FakeMediaStore.rows.isEmpty() })
            assertTrue(records().isEmpty())
        }
    }

    // MARK: Sending

    private fun sourceFile(data: ByteArray): File {
        val source = File.createTempFile("resume", ".bin").apply { writeBytes(data) }
        FastFrameSessionTest.TestFileProvider.file = source
        Robolectric.setupContentProvider(FastFrameSessionTest.TestFileProvider::class.java, "dev.bridgey.test.interop")
        return source
    }

    private val sourceUri = Uri.parse("content://dev.bridgey.test.interop/interop.bin")

    /** Reads the phone's JSON chunks of [id] up to files.complete: the bytes, their first sequence and the hash sent. */
    private fun receiveChunks(link: Link, id: String): Triple<ByteArray, Long?, String> {
        val out = java.io.ByteArrayOutputStream()
        var first: Long? = null
        var next = 0L
        while (true) {
            val frame = link.peer.frames.next() ?: error("closed")
            if (frame !is ProtocolFrame.Json) continue
            val message = Message.decode(frame.text)
            when (message.kind) {
                "files.chunk" -> if (message.transferId == id) {
                    if (first == null) first = message.sequence
                    assertEquals("sequences follow on", next++, message.sequence)
                    out.write(link.open(message))
                    link.outer("files.chunk.ack", id, message.sequence)
                }
                "files.complete" -> {
                    val payload = JSONObject(String(link.open(message), Charsets.UTF_8))
                    if (payload.getString("transferId") == id) return Triple(out.toByteArray(), first, payload.getString("sha256"))
                }
            }
        }
    }

    private fun offerFromPhone(link: Link): Pair<String, JSONObject> {
        val message = link.until("files.offer")
        return message.transferId!! to JSONObject(String(link.open(message), Charsets.UTF_8))
    }

    @Test
    fun aMacThatKeptPartOfTheFileGetsOnlyTheRest() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val link = pair(pairing, server)
            val data = pattern()
            sourceFile(data)
            pairing.sendFile(sourceUri, macId)
            val (id, offer) = offerFromPhone(link)
            assertTrue("offered resumable", offer.getBoolean("resumable"))
            link.encrypted("files.resume", FileResume.resumePayload(id, 2 * mib, sha(data, (2 * mib).toInt())), transferId = id)
            val ack = link.until("files.resume.ack")
            assertEquals(2 * mib, FileResume.parseAck(link.open(ack), id, 2 * mib))
            assertFalse("no reason when it agrees", JSONObject(String(link.open(ack), Charsets.UTF_8)).has("reason"))
            val (tail, first, hash) = receiveChunks(link, id)
            assertEquals(0L, first)
            assertArrayEquals("only the bytes after the offset", data.copyOfRange((2 * mib).toInt(), data.size), tail)
            assertEquals(b64(sha(data)), hash)
            link.outer("files.complete.ack", id)
            assertTrue(waitFor(5_000) { pairing.fileTransfers.value[id]?.outcome == TransferEnd.SENT })
            link.close()
        }
    }

    /** The sender keeps nothing: a phone that restarted answers from its own file, hashed again for the new offer. */
    @Test
    fun aRestartedPhoneStillAnswersFromItsOwnFile() {
        ServerSocket(0, 8, loopback).use { server ->
            val first = coordinator()
            val data = pattern()
            sourceFile(data)
            pair(first, server).close()
            first.stop()
            val pairing = coordinator()
            val link = pair(pairing, server)
            pairing.sendFile(sourceUri, macId)
            val (id, _) = offerFromPhone(link)
            link.encrypted("files.resume", FileResume.resumePayload(id, 3 * mib, sha(data, (3 * mib).toInt())), transferId = id)
            assertEquals(3 * mib, FileResume.parseAck(link.open(link.until("files.resume.ack")), id, 3 * mib))
            assertArrayEquals(data.copyOfRange((3 * mib).toInt(), data.size), receiveChunks(link, id).first)
            link.close()
        }
    }

    @Test
    fun aPrefixThatDiffersSendsTheWholeFileAndSaysWhy() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val link = pair(pairing, server)
            val data = pattern()
            sourceFile(data)
            pairing.sendFile(sourceUri, macId)
            val (id, _) = offerFromPhone(link)
            link.encrypted("files.resume", FileResume.resumePayload(id, 2 * mib, sha(data, mib.toInt())), transferId = id)
            val ack = JSONObject(String(link.open(link.until("files.resume.ack")), Charsets.UTF_8))
            assertEquals(0L, ack.getLong("offset"))
            assertEquals("mismatch", ack.getString("reason"))
            val (whole, first, _) = receiveChunks(link, id)
            assertEquals(0L, first)
            assertArrayEquals(data, whole)
            link.close()
        }
    }

    @Test
    fun theWholeFileKeptCompletesWithoutAChunk() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val link = pair(pairing, server)
            val data = pattern()
            sourceFile(data)
            pairing.sendFile(sourceUri, macId)
            val (id, _) = offerFromPhone(link)
            link.encrypted("files.resume", FileResume.resumePayload(id, data.size.toLong(), sha(data)), transferId = id)
            assertEquals(data.size.toLong(), FileResume.parseAck(link.open(link.until("files.resume.ack")), id, data.size.toLong()))
            val (rest, first, hash) = receiveChunks(link, id)
            assertEquals(0, rest.size)
            assertNull(first)
            assertEquals(b64(sha(data)), hash)
            link.close()
        }
    }

    @Test
    fun waitsFromTheMacKeepTheOfferOpenPastTheWindow() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            pairing.resumeAnswerWindowMillis = 1_000
            val link = pair(pairing, server)
            val data = pattern()
            sourceFile(data)
            pairing.sendFile(sourceUri, macId)
            val (id, _) = offerFromPhone(link)
            // Two and a half windows of re-reading, with a wait every 300 ms.
            repeat(8) {
                Thread.sleep(300)
                link.outer("files.resume.wait", id)
            }
            assertNull("no cancel while the Mac is still reading", link.next(setOf("files.cancel"), 200))
            link.encrypted("files.resume", FileResume.resumePayload(id, 2 * mib, sha(data, (2 * mib).toInt())), transferId = id)
            assertEquals(2 * mib, FileResume.parseAck(link.open(link.until("files.resume.ack")), id, 2 * mib))
            link.close()
        }
    }

    @Test
    fun withoutWaitsThePhoneGivesUpAtTheWindow() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            pairing.resumeAnswerWindowMillis = 1_000
            val link = pair(pairing, server)
            sourceFile(pattern())
            pairing.sendFile(sourceUri, macId)
            val (id, _) = offerFromPhone(link)
            assertEquals(id, link.next(setOf("files.cancel"), 5_000)?.transferId)
            assertTrue(waitFor(5_000) { pairing.fileTransfers.value[id]?.active == false })
            link.close()
        }
    }

    @Test
    fun aMacWithoutTheKeyAndASmallFileGetPlainOffers() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val link = pair(pairing, server, resume = false)
            sourceFile(pattern())
            pairing.sendFile(sourceUri, macId)
            val (id, offer) = offerFromPhone(link)
            assertFalse("not resumable to a Mac without the key", offer.has("resumable"))
            link.outer("files.cancel", id)
            link.close()
        }
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val link = pair(pairing, server)
            sourceFile(pattern(length = mib.toInt()))
            pairing.sendFile(sourceUri, macId)
            val (id, offer) = offerFromPhone(link)
            assertFalse("1 MiB or less is never resumable", offer.has("resumable"))
            link.outer("files.cancel", id)
            link.close()
        }
    }

    @Test
    fun aResumeForAnOfferThatWasNotResumableEndsTheFile() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val link = pair(pairing, server)
            val data = pattern(length = mib.toInt())
            sourceFile(data)
            pairing.sendFile(sourceUri, macId)
            val (id, _) = offerFromPhone(link)
            link.encrypted("files.resume", FileResume.resumePayload(id, data.size.toLong(), sha(data)), transferId = id)
            assertEquals(id, link.next(setOf("files.cancel"), 5_000)?.transferId)
            assertTrue(waitFor(5_000) { pairing.fileTransfers.value[id]?.active == false })
            link.close()
        }
    }

    /**
     * A resumable file whose receiver stops acknowledging (binary frames, the byte window fills) was interrupted, not
     * refused: no files.cancel, which would delete the receiver's partial, and Retry stays.
     */
    @Test
    fun aResumableSendThatStopsMovingEndsInterruptedWithoutACancel() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val link = pair(pairing, server, fast = true)
            sourceFile(pattern())
            pairing.sendFile(sourceUri, macId)
            val (id, _) = offerFromPhone(link)
            link.outer("files.accept", id)
            // Binary frames come and are never acknowledged: after 10 s the phone stops.
            assertNull("no cancel for a resumable file", link.next(setOf("files.cancel"), 14_000))
            assertTrue(waitFor(5_000) { pairing.fileTransfers.value[id]?.outcome == TransferEnd.INTERRUPTED })
            assertTrue("Retry stays", pairing.fileTransfers.value[id]!!.retryable)
            link.close()
        }
    }

    /** The phone sends, the Mac drops after taking part of it, then comes back. */
    private fun interruptedSend(autoResume: Boolean): Pair<PairingCoordinator, Link> {
        val server = ServerSocket(0, 8, loopback)
        val port = freePort()
        BridgeySettings(context, "Test phone").setAutoResumeFiles(autoResume)
        val pairing = coordinator(port)
        pairing.start()
        val link = pair(pairing, server)
        sourceFile(pattern())
        pairing.sendFile(sourceUri, macId)
        val (id, _) = offerFromPhone(link)
        link.outer("files.accept", id)
        link.until("files.chunk")
        link.close()
        server.close()
        assertTrue("interrupted", waitFor(10_000) { pairing.fileTransfers.value[id]?.outcome == TransferEnd.INTERRUPTED })
        assertTrue("Retry stays", pairing.fileTransfers.value[id]!!.retryable)
        return pairing to reconnect(pairing, port)
    }

    @Test
    fun interruptedFilesGoAgainWhenTheMacReconnects() {
        val (pairing, link) = interruptedSend(autoResume = true)
        val data = pattern()
        var again: Message? = null
        assertTrue("sent again by itself", waitFor(10_000) { again = link.next(setOf("files.offer"), 100); again != null })
        val id = again!!.transferId!!
        assertTrue(JSONObject(String(link.open(again!!), Charsets.UTF_8)).getBoolean("resumable"))
        link.encrypted("files.resume", FileResume.resumePayload(id, mib, sha(data, mib.toInt())), transferId = id)
        assertEquals(mib, FileResume.parseAck(link.open(link.until("files.resume.ack")), id, mib))
        val (tail, _, _) = receiveChunks(link, id)
        assertArrayEquals(data.copyOfRange(mib.toInt(), data.size), tail)
        link.close()
        pairing.stop()
    }

    @Test
    fun withTheSettingOffInterruptedFilesWaitForRetry() {
        val (pairing, link) = interruptedSend(autoResume = false)
        var again: Message? = null
        assertFalse("nothing sent by itself", waitFor(3_000) { again = link.next(setOf("files.offer"), 100); again != null })
        val row = pairing.fileTransfers.value.values.single()
        assertEquals(TransferEnd.INTERRUPTED, row.outcome)
        assertTrue(row.retryable)
        link.close()
        pairing.stop()
        BridgeySettings(context, "Test phone").setAutoResumeFiles(true)
    }
}

/**
 * Just enough of MediaStore's Downloads for single files: pending entries in a temp folder, opened with the mode asked
 * for ("w" truncates, "rw" does not), and the pending-entry query the start-up sweep makes.
 */
class FakeMediaStore : ContentProvider() {
    class Row(val id: Long, @Volatile var name: String, val path: String, @Volatile var pending: Boolean)

    companion object {
        lateinit var dir: File
        val rows = ConcurrentHashMap<Long, Row>()
        private val next = AtomicLong(1)

        fun reset(folder: File) {
            dir = folder
            rows.clear()
        }

        fun file(id: Long) = File(dir, "row-$id")
    }

    override fun onCreate() = true

    override fun insert(uri: Uri, values: ContentValues?): Uri {
        val id = next.getAndIncrement()
        val path = values?.getAsString(MediaStore.Downloads.RELATIVE_PATH).orEmpty().let { if (it.endsWith("/")) it else "$it/" }
        rows[id] = Row(id, values?.getAsString(MediaStore.Downloads.DISPLAY_NAME).orEmpty(), path, values?.getAsInteger(MediaStore.Downloads.IS_PENDING) == 1)
        file(id).createNewFile()
        return ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, id)
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val id = ContentUris.parseId(uri)
        if (rows[id] == null) throw java.io.FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file(id), ParcelFileDescriptor.parseMode(mode))
    }

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int {
        val row = rows[ContentUris.parseId(uri)] ?: return 0
        values?.getAsInteger(MediaStore.Downloads.IS_PENDING)?.let { row.pending = it == 1 }
        values?.getAsString(MediaStore.Downloads.DISPLAY_NAME)?.let { row.name = it }
        return 1
    }

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int {
        val id = runCatching { ContentUris.parseId(uri) }.getOrNull() ?: return 0
        val row = rows.remove(id) ?: return 0
        file(row.id).delete()
        return 1
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): android.database.Cursor {
        val cursor = MatrixCursor(arrayOf(MediaStore.Downloads._ID))
        val path = selectionArgs?.firstOrNull()
        if (selection?.contains(MediaStore.Downloads.IS_PENDING) == true && path != null) {
            rows.values.filter { it.pending && it.path == path }.forEach { cursor.addRow(arrayOf<Any>(it.id)) }
        }
        return cursor
    }

    override fun getType(uri: Uri) = "application/octet-stream"
}
