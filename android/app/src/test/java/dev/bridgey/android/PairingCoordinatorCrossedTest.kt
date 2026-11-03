package dev.bridgey.android

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

/**
 * Crossed pairing on the real PairingCoordinator over loopback (security review of 0.10.0-rr.1-beta.19). The fake Mac
 * listens on 127.0.0.1, where the user tapped it; a spoofer on the same LAN connects from 127.0.0.2.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@LooperMode(LooperMode.Mode.PAUSED)
class PairingCoordinatorCrossedTest {
    private val loopback = InetAddress.getByName("127.0.0.1")
    private val spooferAddress = InetAddress.getByName("127.0.0.2")

    @Before
    fun keystore() = FakeAndroidKeyStore.install()

    private class Phone(val pairing: PairingCoordinator, val port: Int)

    private fun phone(phoneId: String): Phone {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val freePort = ServerSocket(0, 1, loopback).use { it.localPort }
        val pairing = PairingCoordinator(context, phoneId, "Test phone", port = freePort, settings = BridgeySettings(context, "Test phone"))
        pairing.start()
        return Phone(pairing, freePort)
    }

    private class Peer(val socket: Socket) {
        val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
        val writer = OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8)

        fun read(): JSONObject? = runCatching { reader.readLine() }.getOrNull()?.let(::JSONObject)

        fun write(frame: JSONObject) {
            writer.write(frame.toString() + "\n")
            writer.flush()
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

    /** The next connection to the fake Mac whose first line is a Bridgey frame (closed dials are skipped). */
    private fun nextDial(server: ServerSocket, millis: Int): Pair<Peer, JSONObject>? {
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
            socket.close()
        }
    }

    /** Under load the phone's listener can come up a moment after the test starts dialling: retry briefly. */
    private fun connectWithRetry(from: InetAddress, port: Int): Socket {
        val deadline = System.currentTimeMillis() + 5_000
        while (true) {
            val socket = Socket()
            try {
                socket.bind(InetSocketAddress(from, 0))
                socket.connect(InetSocketAddress(loopback, port), 5_000)
                socket.soTimeout = 5_000
                return socket
            } catch (e: java.net.ConnectException) {
                socket.close()
                if (System.currentTimeMillis() > deadline) throw e
                Thread.sleep(50)
            }
        }
    }

    private fun notArmed(sessionId: String) = JSONObject().put("kind", "pairing.cancel").put("sessionId", sessionId).put("reason", "not_armed")

    /** A committed first-pairing offer to the phone from [from], claiming [deviceId]. */
    private fun offerFrom(from: InetAddress, phone: Phone, deviceId: String): Peer = committedOffer(from, phone, deviceId).peer

    /** A committed offer on [peer] with [sessionId], committing to [publicKey] (sent in a later pairing.reveal). */
    private class Offer(val peer: Peer, val sessionId: String, val publicKey: String) {
        fun reveal() = peer.write(JSONObject().put("kind", "pairing.reveal").put("sessionId", sessionId).put("publicKey", publicKey))
    }

    private fun committedOffer(from: InetAddress, phone: Phone, deviceId: String): Offer {
        val socket = connectWithRetry(from, phone.port)
        val sessionId = UUID.randomUUID().toString()
        val key = Crypto.encodePublicKey(Crypto.generateKeyPair())
        val peer = Peer(socket)
        peer.write(
            JSONObject().put("kind", "pairing.offer").put("sessionId", sessionId).put("deviceId", deviceId)
                .put("deviceName", "Work Mac").put("commitment", SessionSecurity.commitment(sessionId, key)).put("protocolVersion", 2),
        )
        return Offer(peer, sessionId, key)
    }

    /**
     * A LAN device claims the tapped Mac's ID (or a lower one) while the user waits for Allow pairing on that Mac. Its
     * offers are refused, the user's own pairing keeps dialling, and the real Mac's crossed offer from its own address
     * is answered. When that crossed pairing drops before its code, the user's wait for Allow pairing resumes.
     */
    @Test
    fun aSpoofedCrossedOfferDuringTheAllowWaitLeavesTheUsersPairingAlone() {
        val macId = "00000000-0000-4000-8000-00000000000a"
        val lower = "00000000-0000-4000-8000-000000000001"
        ServerSocket(0, 8, loopback).use { mac ->
            val phone = phone("ffffffff-ffff-4fff-bfff-ffffffffffff")
            val pairing = phone.pairing
            pairing.pair(loopback.hostAddress!!, mac.localPort, "Work Mac", macId, addresses = listOf(loopback.hostAddress!!))
            val (first, offer) = nextDial(mac, 10_000) ?: error("no dial")
            assertTrue("a first pairing commits", offer.has("commitment"))
            first.write(notArmed(offer.getString("sessionId")))
            assertTrue(waitFor(5_000) { pairing.pairingFlow.value is PairingState.WaitingForAllow })

            // The spoofer, under the Mac's ID and under a lower one: refused as not armed, nothing else changes.
            for (claimed in listOf(macId, lower)) {
                val spoofer = offerFrom(spooferAddress, phone, claimed)
                val reply = spoofer.read()
                assertEquals("pairing.cancel", reply?.getString("kind"))
                assertEquals("not_armed", reply?.getString("reason"))
                spoofer.socket.close()
                assertTrue("still waiting: ${pairing.pairingFlow.value}", pairing.pairingFlow.value is PairingState.WaitingForAllow)
            }
            val (second, again) = nextDial(mac, 8_000) ?: error("the user's pairing stopped dialling")
            assertEquals("pairing.offer", again.getString("kind"))
            second.write(notArmed(again.getString("sessionId")))

            // The Mac itself started pairing too: its offer from its own address is answered (lower ID wins)...
            val crossed = offerFrom(loopback, phone, macId)
            assertEquals("pairing.answer", crossed.read()?.getString("kind"))
            assertTrue(waitFor(5_000) { pairing.pairingFlow.value is PairingState.Connecting })
            // ...and drops before its reveal: the wait for Allow pairing resumes and dials the Mac again.
            crossed.socket.close()
            assertTrue("resumed: ${pairing.pairingFlow.value}", waitFor(5_000) { pairing.pairingFlow.value is PairingState.WaitingForAllow })
            val (third, resumed) = nextDial(mac, 8_000) ?: error("no dial after the crossed pairing dropped")
            assertEquals("pairing.offer", resumed.getString("kind"))
            assertTrue(resumed.has("commitment"))
            pairing.cancel()
            listOf(first, second, third).forEach { it.socket.close() }
        }
    }

    /**
     * The same spoofer while this phone is armed (Allow pairing, or setup's pair step holds it) during the wait for
     * Allow pairing on the tapped Mac: its offer is answered like any armed offer, but between the user's dials the
     * prompt slot is empty, and its reveal must not take the code step from the user's pairing. It gets `busy`, the
     * user's pairing keeps waiting and dialling, and the Mac's own answer still brings up the code.
     */
    @Test
    fun aSpoofedOfferWhileArmedDuringTheAllowWaitIsBusyAndTheUsersPairingGoesOn() {
        val macId = "00000000-0000-4000-8000-00000000000a"
        ServerSocket(0, 8, loopback).use { mac ->
            val phone = phone("ffffffff-ffff-4fff-bfff-ffffffffffff")
            val pairing = phone.pairing
            pairing.armPairing()
            pairing.pair(loopback.hostAddress!!, mac.localPort, "Work Mac", macId, addresses = listOf(loopback.hostAddress!!))
            val (first, offer) = nextDial(mac, 10_000) ?: error("no dial")
            first.write(notArmed(offer.getString("sessionId")))
            assertTrue(waitFor(5_000) { pairing.pairingFlow.value is PairingState.WaitingForAllow })

            // Between the user's dials (one every 3 s): answered, as armed, then refused at the code step.
            val spoofer = committedOffer(spooferAddress, phone, macId)
            assertEquals("pairing.answer", spoofer.peer.read()?.getString("kind"))
            spoofer.reveal()
            val refused = spoofer.peer.read()
            assertEquals("pairing.cancel", refused?.getString("kind"))
            assertEquals("busy", refused?.getString("reason"))
            spoofer.peer.socket.close()
            assertTrue("still waiting: ${pairing.pairingFlow.value}", pairing.pairingFlow.value is PairingState.WaitingForAllow)

            // The user's pairing dials again, and the Mac (now allowing pairing) answers it: its code shows.
            val (second, again) = nextDial(mac, 8_000) ?: error("the user's pairing stopped dialling")
            val sessionId = again.getString("sessionId")
            assertTrue(again.has("commitment"))
            second.write(
                JSONObject().put("kind", "pairing.answer").put("sessionId", sessionId).put("deviceId", macId)
                    .put("deviceName", "Work Mac").put("publicKey", Crypto.encodePublicKey(Crypto.generateKeyPair())).put("protocolVersion", 2),
            )
            assertEquals("pairing.reveal", second.read()?.getString("kind"))
            assertTrue("the user's code shows: ${pairing.pairingFlow.value}", waitFor(5_000) { pairing.pairingFlow.value is PairingState.Verification })
            pairing.cancel()
            listOf(first, second).forEach { it.socket.close() }
        }
    }

    /**
     * The Mac does not know this phone's ID (it found the phone by address), so it never answers crossed. The phone has
     * the lower ID and keeps its own dial once; when that dial meets not_armed, the Mac's offer gets the usual request
     * card and Allow pairing answers it, instead of a two-minute stall.
     */
    @Test
    fun theLowerEndFallsBackWhenTheOtherEndDoesNotKnowItsID() {
        val macId = "ffffffff-ffff-4fff-bfff-fffffffffff0"
        ServerSocket(0, 8, loopback).use { mac ->
            val phone = phone("00000000-0000-4000-8000-000000000002")
            val pairing = phone.pairing
            pairing.pair(loopback.hostAddress!!, mac.localPort, "Work Mac", macId, addresses = listOf(loopback.hostAddress!!))
            val (first, offer) = nextDial(mac, 10_000) ?: error("no dial")

            // The Mac's crossed offer while the phone's dial is pending: the phone keeps its own (no card).
            val kept = offerFrom(loopback, phone, macId)
            assertEquals("not_armed", kept.read()?.optString("reason"))
            kept.socket.close()
            assertNull("no card for a crossed pairing this phone keeps", pairing.pairingRequest.value)

            // The Mac is not armed for the phone either: fall back to the usual rules for it.
            first.write(notArmed(offer.getString("sessionId")))
            assertTrue(waitFor(5_000) { pairing.pairingFlow.value is PairingState.WaitingForAllow })
            val carded = offerFrom(loopback, phone, macId)
            assertEquals("not_armed", carded.read()?.optString("reason"))
            carded.socket.close()
            assertTrue("the request card shows", waitFor(5_000) { pairing.pairingRequest.value?.deviceId == macId })

            // Allow pairing here answers the Mac's next offer, which becomes the user's pairing.
            pairing.armPairing()
            val answered = offerFrom(loopback, phone, macId)
            assertEquals("pairing.answer", answered.read()?.getString("kind"))
            assertTrue(waitFor(5_000) { pairing.pairingFlow.value is PairingState.Connecting })
            pairing.cancel()
            answered.socket.close()
            first.socket.close()
        }
    }
}
