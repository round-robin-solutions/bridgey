package dev.bridgey.android.screen

import android.app.Application
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.BridgeySettings
import dev.bridgey.android.FakeAndroidKeyStore
import dev.bridgey.android.PairingCoordinator
import dev.bridgey.android.control.ControlService
import dev.bridgey.android.control.FakeTimers
import dev.bridgey.android.control.GestureSink
import dev.bridgey.android.control.PhoneControlEnvironment
import dev.bridgey.android.control.PhoneControlGrantMode
import dev.bridgey.android.control.PhoneControlGrants
import dev.bridgey.android.control.PhoneControlHub
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.Executor
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Unattended access on the phone, end to end inside the hub: lowering access ends a screenshot share at once (the Mac
 * hears `disabled`), a video share the person approved stays, and a request that waited for the unlock starts its share
 * when the phone is unlocked.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class ScreenShareHubUnattendedTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext<Application>()
    private val mac = UUID.randomUUID().toString()
    private var agent = false
    private var share = true
    private val sent = java.util.concurrent.CopyOnWriteArrayList<Pair<String, JSONObject>>()
    private val link = object : ScreenLink {
        override fun sendJson(kind: String, payload: JSONObject): Boolean { sent += kind to payload; return true }
        override fun sendFrame(plaintext: ByteArray): Boolean = true
    }
    private lateinit var pairing: PairingCoordinator
    private lateinit var control: PhoneControlHub
    private lateinit var hub: ScreenShareHub
    private val started = mutableListOf<String>()

    private val taker = object : ScreenshotTaker, ControlService, GestureSink by NoGestures {
        override fun screenshot(executor: Executor, done: (ScreenShot) -> Unit) = Unit
        override val canType = false
        override fun showIndicator(macName: String, onStop: () -> Unit) = Unit
        override fun hideIndicator() = Unit
        override fun showPrompt(macName: String, answer: (Boolean) -> Unit) = Unit
        override fun hidePrompt() = Unit
    }

    @Before
    fun setUp() {
        FakeAndroidKeyStore.install()
        val port = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        val settings = BridgeySettings(context, "Test phone")
        pairing = PairingCoordinator(context, UUID.randomUUID().toString(), "Test phone", port = port, settings = settings)
        val environment = object : PhoneControlEnvironment {
            override val sdkInt = 36
            override val built = true
            override fun identityKey(deviceId: String) = "key-A"
            override fun isAgent(deviceId: String) = agent
            override fun trusted(deviceId: String) = true
            override fun viewGrant(deviceId: String) = share
            override fun macAdvertises(deviceId: String) = true
            override fun unlocked() = true
            override fun otherDisplayActive() = false
            override fun service(): ControlService? = taker
            override fun serviceEnabled() = true
            override fun showPrompt(deviceId: String, macName: String, promptId: Long) = Unit
            override fun dismissPrompt() = Unit
            override fun controlling(macName: String?) = Unit
            // As BridgeyApplication wires it: every grant or switch change reaches the share.
            override fun grantsChanged(deviceId: String) = hub.accessChanged()
            override fun unattendedChanged() = hub.accessChanged()
        }
        val timers = FakeTimers()
        control = PhoneControlHub(
            environment, PhoneControlGrants(File(Files.createTempDirectory("hub").toFile(), PhoneControlGrants.FILE_NAME)),
            Executor { it.run() }, timers, { timers.now },
        )
        hub = ScreenShareHub(context, pairing, { false }, phoneControl = { control }, screenshots = { taker })
        hub.linkFor = { link }
        hub.startScreenshots = { _, deviceId, _, _ -> started += deviceId }
    }

    private fun screenshotShare(): ScreenStream = hub.begin(mac, "MacBook Air", null, mode = ScreenMode.SCREENSHOTS)!!.also { it.start(720, 1600) }

    /** screen.stop is written on the hub's own writer thread: wait a little for it. */
    private fun stops(expected: Int = 1): List<String> {
        val until = System.currentTimeMillis() + 2_000
        fun now() = sent.filter { it.first == ScreenKinds.STOP }.map { it.second.getString("reason") }
        while (now().size < expected && System.currentTimeMillis() < until) Thread.sleep(10)
        return now()
    }

    @Test
    fun turningAMacOffEndsItsScreenshotShare() {
        val stream = screenshotShare()
        assertTrue(control.setGrant(mac, PhoneControlGrantMode.OFF))
        assertEquals(ScreenStreamPhase.ENDED, stream.phase)
        assertEquals(listOf("disabled"), stops())
        assertEquals(ScreenShareState(), hub.state.value)
    }

    @Test
    fun askEachTimeEndsItToo() {
        val stream = screenshotShare()
        control.setGrant(mac, PhoneControlGrantMode.ASK)
        assertEquals("only Allow without asking may watch unattended", ScreenStreamPhase.ENDED, stream.phase)
    }

    @Test
    fun switchingUnattendedAccessOffEndsTheShareOfAMacOnDefault() {
        val stream = screenshotShare()
        assertTrue(control.setUnattended(false))
        assertEquals(listOf("disabled"), stops())
        assertEquals(ScreenStreamPhase.ENDED, stream.phase)
    }

    @Test
    fun becomingAnAgentEndsIt() {
        val stream = screenshotShare()
        agent = true
        hub.policy(mac, localOn = false, remoteOn = true)
        assertEquals(ScreenStreamPhase.ENDED, stream.phase)
        assertEquals(listOf("disabled"), stops())
    }

    @Test
    fun aVideoShareThePersonApprovedStays() {
        val stream = hub.begin(mac, "MacBook Air", null)!!.also { it.start(720, 1600) }
        control.setGrant(mac, PhoneControlGrantMode.OFF)
        control.setUnattended(false)
        assertEquals(ScreenStreamPhase.STARTING, stream.phase)
        assertTrue(stops(expected = 0).isEmpty())
    }

    @Test
    fun aShareThatIsStillAllowedGoesOn() {
        val stream = screenshotShare()
        control.setGrant(mac, PhoneControlGrantMode.ALWAYS)
        hub.accessChanged()
        assertEquals(ScreenStreamPhase.STARTING, stream.phase)
        assertTrue(stops(expected = 0).isEmpty())
    }

    @Test
    fun aFailedUseVideoLeavesTheScreenshotShareRunning() {
        val stream = screenshotShare()
        hub.projectionFailed()
        assertEquals(ScreenStreamPhase.STARTING, stream.phase)
        assertEquals(ScreenMode.SCREENSHOTS, hub.state.value.mode)
        assertTrue(stops(expected = 0).isEmpty())
    }

    @Test
    fun useVideoReplacesTheScreenshotShareWithoutAStop() {
        val shots = screenshotShare()
        val video = hub.begin(mac, "MacBook Air", null)!!
        assertEquals(ScreenStreamPhase.ENDED, shots.phase)
        assertEquals(ScreenStreamPhase.STARTING, video.phase)
        assertEquals(ScreenMode.VIDEO, hub.state.value.mode)
        assertTrue("the Mac ends the old window when the new one starts", stops(expected = 0).isEmpty())
        // Lowering access now leaves the video the person approved alone.
        control.setGrant(mac, PhoneControlGrantMode.OFF)
        assertEquals(ScreenStreamPhase.STARTING, video.phase)
    }

    @Test
    fun aRequestThatWaitedForTheUnlockStartsWhenThePhoneIsUnlocked() {
        val keyguard = shadowOf(context.getSystemService(KeyguardManager::class.java))
        keyguard.setIsKeyguardLocked(true)
        val requestId = UUID.randomUUID().toString()
        val decision = pairing.screenRequests.receive(
            mac, "MacBook Air", JSONObject().put("version", 1).put("requestId", requestId).toString().toByteArray(), enabled = true, sharing = false,
        )
        val request = (decision as ScreenRequestDecision.Accept).request
        assertEquals(ScreenAnswer.Waiting(ScreenNeeds.UNLOCK), hub.requested(request))
        assertTrue(started.isEmpty())
        // The screen comes on at the lock screen: still locked, still waiting.
        context.sendBroadcast(Intent(Intent.ACTION_SCREEN_ON))
        shadowOf(android.os.Looper.getMainLooper()).idle()
        assertTrue(started.isEmpty())
        keyguard.setIsKeyguardLocked(false)
        context.sendBroadcast(Intent(Intent.ACTION_USER_PRESENT))
        shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals(listOf(mac), started)
        assertNull("the request is answered by the share", pairing.screenRequests.current(mac, requestId))
        assertEquals(ScreenMode.SCREENSHOTS, hub.state.value.mode)
    }

    @Test
    fun aRequestThatWaitedButIsNoLongerAllowedStartsNothing() {
        val keyguard = shadowOf(context.getSystemService(KeyguardManager::class.java))
        keyguard.setIsKeyguardLocked(true)
        val requestId = UUID.randomUUID().toString()
        val request = (pairing.screenRequests.receive(
            mac, "MacBook Air", JSONObject().put("version", 1).put("requestId", requestId).toString().toByteArray(), enabled = true, sharing = false,
        ) as ScreenRequestDecision.Accept).request
        hub.requested(request)
        control.setGrant(mac, PhoneControlGrantMode.ASK)
        keyguard.setIsKeyguardLocked(false)
        hub.unlocked()
        assertTrue(started.isEmpty())
    }

    @Test
    fun aBusyPhoneDoesNotBlameBridgeyControl() {
        hub.markAsking(mac, "MacBook Air")
        val requestId = UUID.randomUUID().toString()
        val request = ScreenRequest(mac, "MacBook Air", requestId, System.currentTimeMillis())
        assertEquals(ScreenAnswer.Waiting(null), hub.requested(request))
    }

    private object NoGestures : GestureSink {
        override fun dispatch(gesture: dev.bridgey.android.control.PlannedGesture, done: (Boolean) -> Unit) = false
        override fun navigate(action: dev.bridgey.android.display.ControlNavigation) = false
        override fun text(text: String) = dev.bridgey.android.control.Typed.FAILED
        override fun key(key: dev.bridgey.android.display.ControlKey, down: Boolean, shift: Boolean) = dev.bridgey.android.control.Typed.FAILED
    }
}
