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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

/**
 * The real PairingCoordinator and a fake Mac over loopback: a file this phone sends always ends, even when the Mac
 * goes quiet. The other end is told (files.cancel) whenever this phone gives up on an offered file, and a transfer
 * with no progress for 2 minutes is failed with a clear message and Retry.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@LooperMode(LooperMode.Mode.PAUSED)
class StuckTransferSessionTest {
    private val loopback = InetAddress.getLoopbackAddress()
    private val macId = UUID.randomUUID().toString()
    private val phoneId = UUID.randomUUID().toString()
    private val macIdentity = java.security.KeyPairGenerator.getInstance("EC")
        .apply { initialize(java.security.spec.ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    private val macIdentityKey = Crypto.encodePublicKey(macIdentity)

    @Before
    fun keystore() = FakeAndroidKeyStore.install()

    private class Peer(val socket: Socket) {
        val frames = ProtocolStreamReader(socket.getInputStream())
        val output = socket.getOutputStream()

        fun read(): JSONObject = JSONObject((frames.next() as? ProtocolFrame.Json ?: error("closed or binary")).text)

        fun write(frame: JSONObject) {
            output.write((frame.toString() + "\n").toByteArray())
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

    private fun Peer.sendTagged(key: ByteArray, message: Message) {
        val tagged = message.copy(tag = SessionSecurity.tag(SessionSecurity.envelopeKey(key), macId, message))
        write(JSONObject(tagged.encode()))
    }

    /** Pairs, lets the Mac advertise Files without fast transfers (JSON chunks), and returns the session ID. */
    private fun connect(pairing: PairingCoordinator, server: ServerSocket): Triple<Peer, ByteArray, String> {
        val (peer, key) = pair(pairing, server)
        val features = JSONObject().apply {
            BridgeyFeature.entries.forEach { put(it.key, true) }
            put(FILES_FAST_FEATURE_KEY, false)
        }
        val sealed = Crypto.encrypt(key, JSONObject().put("version", 1).put("features", features).toString().toByteArray())
        peer.socket.soTimeout = 30_000
        var session = ""
        while (session.isEmpty()) {
            val message = peer.read()
            if (message.getString("kind") == "features.update") session = message.getString("sessionId")
        }
        peer.sendTagged(key, Message(kind = "features.update", sessionId = session, messageId = UUID.randomUUID().toString(),
            nonce = sealed.nonce, ciphertext = sealed.ciphertext))
        Thread.sleep(500)
        return Triple(peer, key, session)
    }

    private fun sendOneFile(pairing: PairingCoordinator) {
        val source = java.io.File.createTempFile("stuck", ".bin").apply { writeBytes(ByteArray(111_792) { (it * 7).toByte() }) }
        FastFrameSessionTest.TestFileProvider.file = source
        org.robolectric.Robolectric.setupContentProvider(FastFrameSessionTest.TestFileProvider::class.java, "dev.bridgey.test.interop")
        pairing.sendFile(android.net.Uri.parse("content://dev.bridgey.test.interop/interop.bin"), macId)
    }

    private fun coordinator(): PairingCoordinator {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val freePort = ServerSocket(0, 1, loopback).use { it.localPort }
        return PairingCoordinator(context, phoneId, "Test phone", port = freePort, settings = BridgeySettings(context, "Test phone"))
    }

    /** Reads frames until [kind] arrives; returns it. */
    private fun Peer.until(kind: String): Message {
        while (true) {
            val frame = frames.next() ?: error("closed before $kind")
            if (frame is ProtocolFrame.Json) {
                val message = Message.decode(frame.text)
                if (message.kind == kind) return message
            }
        }
    }

    /** The Mac accepted, took every chunk and the completion, then went quiet: 2 minutes later the phone fails it and tells the Mac. */
    @Test
    fun aSilentMacAfterTheLastChunkEndsInAFailedRowAndACancel() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val (peer, key, session) = connect(pairing, server)
            sendOneFile(pairing)
            val offer = peer.until("files.offer")
            val transferId = offer.transferId!!
            peer.sendTagged(key, Message(kind = "files.accept", sessionId = session, transferId = transferId))
            peer.until("files.complete")
            val row = pairing.fileTransfers.value[transferId]
            assertNotNull(row)
            assertTrue("still running", row!!.active)

            pairing.failStalledTransfers(System.currentTimeMillis() + TransferStall.TIMEOUT_MILLIS + 1_000)

            val cancel = peer.until("files.cancel")
            assertEquals(transferId, cancel.transferId)
            val ended = pairing.fileTransfers.value[transferId]!!
            assertFalse(ended.active)
            assertEquals(TransferEnd.FAILED, ended.outcome)
            assertEquals(ApplicationProvider.getApplicationContext<Application>().getString(R.string.file_transfer_stalled), ended.status)
            assertTrue("Retry is offered", ended.retryable)
            assertFalse("nothing stays busy", pairing.fileTransferActive.value)
            peer.socket.close()
        }
    }

    /** A transfer that moved a moment ago is left alone. */
    @Test
    fun aTransferThatIsStillMovingIsNotFailed() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val (peer, key, session) = connect(pairing, server)
            sendOneFile(pairing)
            val transferId = peer.until("files.offer").transferId!!
            peer.sendTagged(key, Message(kind = "files.accept", sessionId = session, transferId = transferId))
            peer.until("files.complete")
            pairing.failStalledTransfers(System.currentTimeMillis() + TransferStall.TIMEOUT_MILLIS - 30_000)
            assertTrue(pairing.fileTransfers.value[transferId]!!.active)
            peer.socket.close()
        }
    }

    /** The Mac never answers the offer: this phone gives up after 10 seconds and tells the Mac, so a late accept leaves nothing behind. */
    @Test
    fun givingUpOnAnUnansweredOfferTellsTheMac() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val (peer, _, _) = connect(pairing, server)
            sendOneFile(pairing)
            val transferId = peer.until("files.offer").transferId!!
            val cancel = peer.until("files.cancel")
            assertEquals(transferId, cancel.transferId)
            assertTrue(waitFor(5_000) { pairing.fileTransfers.value[transferId]?.active == false })
            peer.socket.close()
        }
    }
}
