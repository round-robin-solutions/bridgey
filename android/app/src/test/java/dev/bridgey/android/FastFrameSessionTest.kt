package dev.bridgey.android

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

/**
 * Binary frames on a real authenticated protocol 2 session (the real PairingCoordinator and a fake Mac over loopback):
 * a forged, reflected or replayed frame is dropped and counted like a frame with a bad envelope tag, the session stays
 * up below 16, and 16 close it, while genuine frames never count.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@LooperMode(LooperMode.Mode.PAUSED)
class FastFrameSessionTest {
    private val loopback = InetAddress.getLoopbackAddress()
    private val macId = UUID.randomUUID().toString()
    private val phoneId = UUID.randomUUID().toString()
    private val macIdentity = java.security.KeyPairGenerator.getInstance("EC")
        .apply { initialize(java.security.spec.ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    private val macIdentityKey = Crypto.encodePublicKey(macIdentity)

    @Before
    fun keystore() = FakeAndroidKeyStore.install()

    private class Peer(val socket: Socket) {
        /** The app's own frame reader, so the fake Mac can read binary frames once the session is authenticated. */
        val frames = ProtocolStreamReader(socket.getInputStream())
        val output = socket.getOutputStream()

        fun read(): JSONObject = JSONObject((frames.next() as? ProtocolFrame.Json ?: error("closed or binary")).text)

        fun write(frame: JSONObject) {
            output.write((frame.toString() + "\n").toByteArray())
            output.flush()
        }

        fun writeBinary(frame: ByteArray) {
            output.write(frame)
            output.flush()
        }
    }

    private fun waitFor(timeoutMillis: Long, condition: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < end) {
            if (condition()) return true
            Thread.sleep(50)
        }
        return condition()
    }

    /** A committed first pairing with the fake Mac as the dialled end; the session key once both confirmed. */
    private fun pair(pairing: PairingCoordinator, server: ServerSocket): Pair<Peer, ByteArray> {
        pairing.pair(loopback.hostAddress!!, server.localPort, "Fake Mac")
        server.soTimeout = 10_000
        var peer: Peer
        var offer: JSONObject
        while (true) {
            peer = Peer(server.accept())
            offer = runCatching { peer.read() }.getOrNull() ?: continue
            if (offer.optString("kind") == "pairing.offer") break
        }
        val sessionId = offer.getString("sessionId")
        val mine = Crypto.generateKeyPair()
        val minePublic = Crypto.encodePublicKey(mine)
        peer.write(
            JSONObject().put("kind", "pairing.answer").put("sessionId", sessionId).put("deviceId", macId)
                .put("deviceName", "Fake Mac").put("publicKey", minePublic).put("protocolVersion", 2),
        )
        val reveal = peer.read()
        val phonePublic = reveal.getString("publicKey")
        val material = Crypto.pairingMaterial(mine, phonePublic, sessionId, sasKeys = phonePublic to minePublic)
        assertTrue(waitFor(5_000) { pairing.pairingFlow.value is PairingState.Verification })
        pairing.confirm((pairing.pairingFlow.value as PairingState.Verification).token)
        assertEquals("pairing.confirm", peer.read().getString("kind"))
        val transcript = listOf("bridgey-auth-v1", sessionId, phoneId, macId, phonePublic, minePublic).joinToString("\u0000").toByteArray()
        val signature = java.security.Signature.getInstance("SHA256withECDSA").apply {
            initSign(macIdentity.private)
            update(transcript)
        }.sign()
        peer.write(
            JSONObject().put("kind", "pairing.confirm").put("sessionId", sessionId).put("deviceId", macId)
                .put("identityKey", macIdentityKey)
                .put("proof", Crypto.confirmationProof(material.key, sessionId, macId, macIdentityKey))
                .put("signature", java.util.Base64.getEncoder().encodeToString(signature)),
        )
        assertTrue("paired", waitFor(5_000) { pairing.connections.value.any { it.deviceId == macId } })
        return peer to material.key
    }

    private fun connected(pairing: PairingCoordinator) = pairing.connections.value.any { it.deviceId == macId }

    @Test
    fun forgedReflectedAndReplayedBinaryFramesAreDroppedAndSixteenCloseTheSession() {
        ServerSocket(0, 8, loopback).use { server ->
            val context = ApplicationProvider.getApplicationContext<Application>()
            val freePort = ServerSocket(0, 1, loopback).use { it.localPort }
            val pairing = PairingCoordinator(context, phoneId, "Test phone", port = freePort, settings = BridgeySettings(context, "Test phone"))
            val (peer, sessionKey) = pair(pairing, server)
            // Binary frames use their own key, derived from the session key.
            val key = SessionSecurity.fastFrameKey(sessionKey)
            val testId = UUID.randomUUID().toString()
            val bytes = ByteArray(4096) { it.toByte() }

            // Genuine speed test bytes from the Mac (no test runs, so they are taken and ignored): never counted.
            for (sequence in 0L until 40L) peer.writeBinary(sealFastFrame(FastFrame.SPEED_KIND, testId, sequence, bytes, key, macId))
            Thread.sleep(500)
            assertTrue("40 genuine frames keep the session", connected(pairing))

            // Forged (another key), reflected (sealed as the phone itself) and replayed (sequence 3 again): 15 drops.
            repeat(4) { peer.writeBinary(sealFastFrame(FastFrame.SPEED_KIND, testId, 100L + it, bytes, ByteArray(32) { 9 }, macId)) }
            // Sealed with the session key itself instead of the derived frame key: forged too.
            peer.writeBinary(sealFastFrame(FastFrame.SPEED_KIND, testId, 104L, bytes, sessionKey, macId))
            repeat(5) { peer.writeBinary(sealFastFrame(FastFrame.SPEED_KIND, testId, 200L + it, bytes, key, phoneId)) }
            repeat(5) { peer.writeBinary(sealFastFrame(FastFrame.SPEED_KIND, testId, 3, bytes, key, macId)) }
            Thread.sleep(500)
            assertTrue("15 dropped frames keep the session", connected(pairing))

            // The 16th closes it, as 16 frames with bad envelope tags would.
            peer.writeBinary(sealFastFrame(FastFrame.SPEED_KIND, testId, 39, bytes, key, macId))
            assertTrue("the 16th dropped frame closes the session", waitFor(5_000) { !connected(pairing) })
            assertFalse(connected(pairing))
            peer.socket.close()
        }
    }

    /**
     * Before authentication binary frames are not read at all: a frame that starts with the marker is a JSON line that
     * is not UTF-8 text, so the pairing ends. Even one sealed with a key the attacker chose never reaches a transfer.
     */
    @Test
    fun aBinaryFrameBeforeAuthenticationEndsThePairing() {
        ServerSocket(0, 8, loopback).use { server ->
            val context = ApplicationProvider.getApplicationContext<Application>()
            val freePort = ServerSocket(0, 1, loopback).use { it.localPort }
            val pairing = PairingCoordinator(context, phoneId, "Test phone", port = freePort, settings = BridgeySettings(context, "Test phone"))
            pairing.pair(loopback.hostAddress!!, server.localPort, "Fake Mac")
            server.soTimeout = 10_000
            var peer: Peer
            while (true) {
                peer = Peer(server.accept())
                val offer = runCatching { peer.read() }.getOrNull() ?: continue
                if (offer.optString("kind") == "pairing.offer") break
            }
            // Instead of an answer: a well-formed binary frame (an ID, a sequence and a tag over a key of our own).
            peer.writeBinary(sealFastFrame(FastFrame.CHUNK_KIND, UUID.randomUUID().toString(), 0, ByteArray(4096) { 10 }, ByteArray(32) { 1 }, macId))
            peer.socket.soTimeout = 5_000
            // The phone closes the socket (any frame it still sends first is a cancel) and never shows a code.
            val rest = generateSequence { runCatching { peer.read() }.getOrNull() }.toList()
            assertTrue("only a cancel may come back: $rest", rest.all { it.getString("kind") == "pairing.cancel" })
            assertFalse(pairing.pairingFlow.value is PairingState.Verification)
            assertFalse(connected(pairing))
            peer.socket.close()
        }
    }

    /** Serves one file to the coordinator as a content URI with a name and a size, like a document picker would. */
    class TestFileProvider : android.content.ContentProvider() {
        override fun onCreate() = true
        override fun query(uri: android.net.Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?) =
            android.database.MatrixCursor(arrayOf(android.provider.OpenableColumns.DISPLAY_NAME, android.provider.OpenableColumns.SIZE))
                .apply { addRow(arrayOf<Any>("interop.bin", file!!.length())) }
        override fun getType(uri: android.net.Uri) = "application/octet-stream"
        override fun openFile(uri: android.net.Uri, mode: String) =
            android.os.ParcelFileDescriptor.open(file, android.os.ParcelFileDescriptor.MODE_READ_ONLY)
        override fun insert(uri: android.net.Uri, values: android.content.ContentValues?) = null
        override fun delete(uri: android.net.Uri, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun update(uri: android.net.Uri, values: android.content.ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0

        companion object {
            var file: java.io.File? = null
        }
    }

    /** An encrypted, tagged message from the fake Mac. */
    private fun Peer.sendTagged(key: ByteArray, message: Message) {
        val tagged = message.copy(tag = SessionSecurity.tag(SessionSecurity.envelopeKey(key), macId, message))
        write(JSONObject(tagged.encode()))
    }

    /**
     * Sends a 1 MiB file from the real phone to a fake Mac that advertises files_fast_draft1 or not, and returns the
     * plaintext size of every chunk with whether it came as a binary frame.
     */
    private fun phoneSendsAFile(macAdvertisesFast: Boolean): List<Pair<Boolean, Int>> {
        val bytes = ByteArray(1_048_576 + 100) { (it * 31).toByte() }
        val source = java.io.File.createTempFile("interop", ".bin").apply { writeBytes(bytes) }
        TestFileProvider.file = source
        org.robolectric.Robolectric.setupContentProvider(TestFileProvider::class.java, "dev.bridgey.test.interop")
        val chunks = mutableListOf<Pair<Boolean, Int>>()
        ServerSocket(0, 8, loopback).use { server ->
            val context = ApplicationProvider.getApplicationContext<Application>()
            val freePort = ServerSocket(0, 1, loopback).use { it.localPort }
            val pairing = PairingCoordinator(context, phoneId, "Test phone", port = freePort, settings = BridgeySettings(context, "Test phone"))
            val (peer, key) = pair(pairing, server)
            peer.frames.binaryAllowed = true
            val features = JSONObject().apply {
                BridgeyFeature.entries.forEach { put(it.key, true) }
                put(FILES_FAST_FEATURE_KEY, macAdvertisesFast)
            }
            val sealed = Crypto.encrypt(key, JSONObject().put("version", 1).put("features", features).toString().toByteArray())
            peer.socket.soTimeout = 20_000
            // The session ID: from the phone's own features.update, which arrives right after pairing.
            var session = ""
            while (session.isEmpty()) {
                val message = peer.read()
                if (message.getString("kind") == "features.update") session = message.getString("sessionId")
            }
            peer.sendTagged(key, Message(kind = "features.update", sessionId = session, messageId = UUID.randomUUID().toString(),
                nonce = sealed.nonce, ciphertext = sealed.ciphertext))
            Thread.sleep(500)
            pairing.sendFile(android.net.Uri.parse("content://dev.bridgey.test.interop/interop.bin"), macId)
            var transferId: String? = null
            val received = java.io.ByteArrayOutputStream()
            while (true) {
                when (val frame = peer.frames.next() ?: error("closed")) {
                    is ProtocolFrame.Binary -> {
                        val payload = openFastFrameBody(frame.kind, frame.body, SessionSecurity.fastFrameKey(key), phoneId)
                        chunks += true to payload.plaintext.size
                        received.write(payload.plaintext)
                        peer.sendTagged(key, Message(kind = "files.chunk.ack", sessionId = session, transferId = payload.id, sequence = payload.sequence))
                    }
                    is ProtocolFrame.Json -> {
                        val message = Message.decode(frame.text)
                        when (message.kind) {
                            "files.offer" -> {
                                transferId = message.transferId
                                peer.sendTagged(key, Message(kind = "files.accept", sessionId = session, transferId = transferId))
                            }
                            "files.chunk" -> {
                                val plaintext = Crypto.decrypt(key, message.nonce!!, message.ciphertext!!)!!
                                chunks += false to plaintext.size
                                received.write(plaintext)
                                peer.sendTagged(key, Message(kind = "files.chunk.ack", sessionId = session, transferId = message.transferId, sequence = message.sequence))
                            }
                            "files.complete" -> {
                                peer.sendTagged(key, Message(kind = "files.complete.ack", sessionId = session, transferId = transferId))
                                break
                            }
                        }
                    }
                }
            }
            assertTrue("every byte arrived in order", received.toByteArray().contentEquals(bytes))
            peer.socket.close()
        }
        source.delete()
        return chunks
    }

    /** Interop: a Mac without files_fast_draft1 (an older build, or transfers.fastOff) gets 24 KiB JSON chunks. */
    @Test
    fun aMacWithoutTheKeyGetsJsonChunks() {
        val chunks = phoneSendsAFile(macAdvertisesFast = false)
        assertTrue("no binary frame: $chunks", chunks.none { it.first })
        assertTrue("every chunk at most 24 KiB: $chunks", chunks.all { it.second in 1..24 * 1024 })
        assertTrue("43 or more chunks for 1 MiB: ${chunks.size}", chunks.size >= 43)
    }

    /** With the key on both sides the same file goes as 256 KiB binary frames. */
    @Test
    fun aMacWithTheKeyGetsBinaryFrames() {
        val chunks = phoneSendsAFile(macAdvertisesFast = true)
        assertTrue("only binary frames: $chunks", chunks.all { it.first })
        assertEquals(listOf(262_144, 262_144, 262_144, 262_144, 100), chunks.map { it.second })
    }
}
