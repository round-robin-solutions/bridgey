package dev.bridgey.android

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import java.io.BufferedReader
import java.io.InputStreamReader
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
        val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
        val output = socket.getOutputStream()

        fun read(): JSONObject = JSONObject(reader.readLine() ?: error("closed"))

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
            val (peer, key) = pair(pairing, server)
            val testId = UUID.randomUUID().toString()
            val bytes = ByteArray(4096) { it.toByte() }

            // Genuine speed test bytes from the Mac (no test runs, so they are taken and ignored): never counted.
            for (sequence in 0L until 40L) peer.writeBinary(sealFastFrame(FastFrame.SPEED_KIND, testId, sequence, bytes, key, macId))
            Thread.sleep(500)
            assertTrue("40 genuine frames keep the session", connected(pairing))

            // Forged (another key), reflected (sealed as the phone itself) and replayed (sequence 3 again): 15 drops.
            repeat(5) { peer.writeBinary(sealFastFrame(FastFrame.SPEED_KIND, testId, 100L + it, bytes, ByteArray(32) { 9 }, macId)) }
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
}
