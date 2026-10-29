package dev.bridgey.android

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

/**
 * The real PairingCoordinator dials a fake Mac over loopback (review bug 1 of the merged 0.10 branch): `not_armed` is a
 * reason to wait and dial again only before the Mac answered; after the answer it is a plain cancel, never a redial.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@LooperMode(LooperMode.Mode.PAUSED)
class PairingCoordinatorNotArmedTest {
    private val loopback = InetAddress.getLoopbackAddress()
    private val macId = UUID.randomUUID().toString()

    @Before
    fun keystore() = FakeAndroidKeyStore.install()

    private fun coordinator(): PairingCoordinator {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val freePort = ServerSocket(0, 1, loopback).use { it.localPort }
        return PairingCoordinator(context, UUID.randomUUID().toString(), "Test phone", port = freePort, settings = BridgeySettings(context, "Test phone"))
    }

    private class Peer(val socket: Socket) {
        val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
        val writer = OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8)

        fun read(): JSONObject = JSONObject(reader.readLine() ?: error("closed"))

        fun write(vararg frames: JSONObject) {
            writer.write(frames.joinToString("") { it.toString() + "\n" })
            writer.flush()
        }
    }

    private fun answer(sessionId: String) = JSONObject()
        .put("kind", "pairing.answer").put("sessionId", sessionId).put("deviceId", macId).put("deviceName", "Fake Mac")
        .put("publicKey", Crypto.encodePublicKey(Crypto.generateKeyPair())).put("protocolVersion", 2)

    private fun notArmed(sessionId: String) = JSONObject().put("kind", "pairing.cancel").put("sessionId", sessionId).put("reason", "not_armed")

    private fun waitFor(timeoutMillis: Long, condition: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < end) {
            if (condition()) return true
            Thread.sleep(50)
        }
        return condition()
    }

    /** Other things on a CI host sometimes probe open loopback ports (an HTTP GET was seen); only Bridgey frames count. */
    private val strangers = CopyOnWriteArrayList<String>()

    /** The next connection whose first line is a Bridgey frame, within [millis]; null when none came. */
    private fun nextBridgeyDial(server: ServerSocket, millis: Int): Pair<Peer, JSONObject>? {
        val end = System.currentTimeMillis() + millis
        while (true) {
            val left = (end - System.currentTimeMillis()).toInt()
            if (left <= 0) return null
            server.soTimeout = left
            val socket = try {
                server.accept()
            } catch (_: SocketTimeoutException) {
                return null
            }
            socket.soTimeout = 5_000
            val peer = Peer(socket)
            val line = runCatching { peer.reader.readLine() }.getOrNull()
            if (line != null && line.startsWith("{")) return peer to JSONObject(line)
            strangers += line.orEmpty().take(40)
            socket.close()
        }
    }

    private fun noDialWithin(server: ServerSocket, millis: Int): Boolean =
        nextBridgeyDial(server, millis)?.let { (peer, first) ->
            peer.socket.close()
            fail("dialled again: ${first.optString("kind")} (other connections: $strangers)")
            false
        } ?: true

    @Test
    fun notArmedAfterTheAnswerFailsAsCancelledAndNeverRedials() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            pairing.pair(loopback.hostAddress!!, server.localPort, "Fake Mac")
            val (peer, offer) = nextBridgeyDial(server, 10_000) ?: error("no dial")
            assertEquals("pairing.offer", offer.getString("kind"))
            assertTrue("a first pairing commits to its key", offer.has("commitment") && !offer.has("publicKey"))
            val sessionId = offer.getString("sessionId")
            peer.write(answer(sessionId))
            assertEquals("pairing.reveal", peer.read().getString("kind"))
            assertTrue("the code is shown", waitFor(5_000) { pairing.pairingFlow.value is PairingState.Verification })
            peer.write(notArmed(sessionId))
            assertTrue(waitFor(5_000) { pairing.pairingFlow.value is PairingState.Failed })
            assertEquals(PairingFailure.CANCELLED_REMOTE, (pairing.pairingFlow.value as PairingState.Failed).reason)
            assertTrue("no second dial within 4 s", noDialWithin(server, 4_000))
            assertTrue(pairing.pairingFlow.value is PairingState.Failed)
            peer.socket.close()
        }
    }

    @Test
    fun notArmedBeforeTheAnswerWaitsForAllowPairingAndDialsAgain() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            pairing.pair(loopback.hostAddress!!, server.localPort, "Fake Mac")
            val (first, offer) = nextBridgeyDial(server, 10_000) ?: error("no dial")
            first.write(notArmed(offer.getString("sessionId")))
            assertTrue(waitFor(5_000) { pairing.pairingFlow.value is PairingState.WaitingForAllow })
            val (second, again) = nextBridgeyDial(server, 8_000) ?: error("no second dial")
            assertEquals("pairing.offer", again.getString("kind"))
            pairing.cancel()
            first.socket.close()
            second.socket.close()
        }
    }

    /** The fake Mac's long-term identity, as AndroidIdentity keeps the phone's. */
    private val macIdentity = java.security.KeyPairGenerator.getInstance("EC").apply { initialize(java.security.spec.ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    private val macIdentityKey = Crypto.encodePublicKey(macIdentity)

    /**
     * The fake Mac as the dialled end of a committed first pairing, through to both confirmations. Returns once the
     * phone has sent its pairing.confirm and the Mac has sent its own.
     */
    private fun pairAsDialledMac(pairing: PairingCoordinator, peer: Peer, offer: JSONObject, phoneId: String) {
        val sessionId = offer.getString("sessionId")
        val mine = Crypto.generateKeyPair()
        val minePublic = Crypto.encodePublicKey(mine)
        peer.write(
            JSONObject().put("kind", "pairing.answer").put("sessionId", sessionId).put("deviceId", macId)
                .put("deviceName", "Fake Mac").put("publicKey", minePublic).put("protocolVersion", 2),
        )
        val reveal = peer.read()
        assertEquals("pairing.reveal", reveal.getString("kind"))
        val phonePublic = reveal.getString("publicKey")
        assertTrue(SessionSecurity.commitmentMatches(offer.getString("commitment"), sessionId, phonePublic))
        val material = Crypto.pairingMaterial(mine, phonePublic, sessionId, sasKeys = phonePublic to minePublic)
        assertTrue("the code is shown", waitFor(5_000) { pairing.pairingFlow.value is PairingState.Verification })
        val shown = pairing.pairingFlow.value as PairingState.Verification
        assertEquals(material.code, shown.code)
        pairing.confirm(shown.token)
        val phoneConfirm = peer.read()
        assertEquals("pairing.confirm", phoneConfirm.getString("kind"))
        // The phone dialled: its transcript lists phone, Mac, then the phone's and the Mac's ephemeral keys.
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
    }

    /** Review bug 5: pairing again with a Mac the user disconnected on this phone finishes and stays connected. */
    @Test
    fun aDeliberatePairingWithADisconnectedMacFinishesAndStaysConnected() {
        ServerSocket(0, 8, loopback).use { server ->
            val context = ApplicationProvider.getApplicationContext<Application>()
            val phoneId = UUID.randomUUID().toString()
            val freePort = ServerSocket(0, 1, loopback).use { it.localPort }
            val pairing = PairingCoordinator(context, phoneId, "Test phone", port = freePort, settings = BridgeySettings(context, "Test phone"))

            pairing.pair(loopback.hostAddress!!, server.localPort, "Fake Mac")
            val (first, offer) = nextBridgeyDial(server, 10_000) ?: error("no dial")
            pairAsDialledMac(pairing, first, offer, phoneId)
            assertTrue("paired", waitFor(5_000) { pairing.pairingFlow.value is PairingState.Paired })
            assertTrue(waitFor(5_000) { pairing.connections.value.any { it.deviceId == macId } })

            // The user disconnects the Mac on its device page: it is held.
            pairing.disconnectByUser(macId)
            assertTrue(waitFor(5_000) { pairing.connections.value.none { it.deviceId == macId } })
            first.socket.close()
            pairing.dismiss()

            // The user pairs with it again on purpose.
            pairing.pair(loopback.hostAddress!!, server.localPort, "Fake Mac")
            val (second, again) = nextBridgeyDial(server, 10_000) ?: error("no second dial")
            assertTrue("a pairing the user started commits", again.has("commitment"))
            pairAsDialledMac(pairing, second, again, phoneId)
            assertTrue("paired again, not connection lost: ${pairing.pairingFlow.value}", waitFor(5_000) { pairing.pairingFlow.value is PairingState.Paired })
            Thread.sleep(1_000)
            assertTrue("still connected after the pairing", pairing.connections.value.any { it.deviceId == macId })
            second.socket.close()
        }
    }

    /** Follow-up: a cancel and an answer in one write: nothing after the cancel is read, so no code ever shows. */
    @Test
    fun framesAfterACancelInTheSameWriteAreNeverRead() {
        ServerSocket(0, 8, loopback).use { server ->
            val pairing = coordinator()
            val states = CopyOnWriteArrayList<PairingState>()
            val watcher = Thread {
                var last: PairingState? = null
                while (!Thread.currentThread().isInterrupted) {
                    val now = pairing.pairingFlow.value
                    if (now != last) {
                        states += now
                        last = now
                    }
                    try {
                        Thread.sleep(2)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            }.also(Thread::start)
            pairing.pair(loopback.hostAddress!!, server.localPort, "Fake Mac")
            val (peer, offer) = nextBridgeyDial(server, 10_000) ?: error("no dial")
            val sessionId = offer.getString("sessionId")
            peer.write(notArmed(sessionId), answer(sessionId))
            assertTrue(waitFor(5_000) { pairing.pairingFlow.value is PairingState.WaitingForAllow })
            Thread.sleep(500)
            watcher.interrupt()
            watcher.join(1_000)
            assertFalse("no code for a closed session: $states", states.any { it is PairingState.Verification })
            pairing.cancel()
            peer.socket.close()
            if (states.isEmpty()) fail("no states seen")
        }
    }
}
