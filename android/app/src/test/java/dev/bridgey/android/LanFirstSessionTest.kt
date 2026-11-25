package dev.bridgey.android

import android.app.Application
import android.content.Context
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
 * The real PairingCoordinator and a fake Mac over loopback: the phone advertises lan_first_draft2, remembers a Mac whose
 * features.update carries both LAN first keys (docs/protocol.md "LAN first"), forgets it as soon as one lacks the second
 * key, and Forget clears it. The rule that reads the memory is in LanFirstTest.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@LooperMode(LooperMode.Mode.PAUSED)
class LanFirstSessionTest {
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

    private fun Peer.sendLanFirst(key: ByteArray, session: String, draft2: Boolean) {
        val features = JSONObject().apply {
            BridgeyFeature.entries.forEach { put(it.key, true) }
            put(LAN_FIRST_FEATURE_KEY, true)
            if (draft2) put(LAN_FIRST_DRAFT2_FEATURE_KEY, true)
        }
        val sealed = Crypto.encrypt(key, JSONObject().put("version", 1).put("features", features).toString().toByteArray())
        sendTagged(key, Message(kind = "features.update", sessionId = session, messageId = UUID.randomUUID().toString(),
            nonce = sealed.nonce, ciphertext = sealed.ciphertext))
    }

    @Test
    fun remembersAMacThatSendsBothKeysUntilItStopsOrIsForgotten() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val (peer, key) = pair(pairing, server)
            peer.socket.soTimeout = 30_000
            val mine = peer.until("features.update")
            val plaintext = Crypto.decrypt(key, mine.nonce!!, mine.ciphertext!!)!!
            assertTrue(decodeFeatureFlag(plaintext, LAN_FIRST_FEATURE_KEY))
            assertTrue("the phone says it remembers", decodeFeatureFlag(plaintext, LAN_FIRST_DRAFT2_FEATURE_KEY))
            val trust = ApplicationProvider.getApplicationContext<Application>().getSharedPreferences("bridgey.trust", Context.MODE_PRIVATE)
            fun remembered() = trust.getBoolean("peer.$macId.lanFirst", false)
            assertFalse("nothing before the Mac's features", remembered())

            peer.sendLanFirst(key, mine.sessionId, draft2 = false)
            assertTrue(waitFor(5_000) { pairing.connections.value.singleOrNull()?.state?.remoteLanFirst == true })
            assertFalse("a Beta 2 to 4 Mac is never remembered", remembered())

            peer.sendLanFirst(key, mine.sessionId, draft2 = true)
            assertTrue(waitFor(5_000) { remembered() })
            peer.sendLanFirst(key, mine.sessionId, draft2 = false)
            assertTrue("a features.update without the key forgets at once", waitFor(5_000) { !remembered() })
            peer.sendLanFirst(key, mine.sessionId, draft2 = true)
            assertTrue(waitFor(5_000) { remembered() })

            pairing.forget(macId)
            assertFalse("Forget", remembered())
            peer.socket.close()
        }
    }
}
