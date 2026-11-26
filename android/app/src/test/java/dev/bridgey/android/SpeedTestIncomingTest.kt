package dev.bridgey.android

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Security review 1.0: any connected paired device could start a speed test here at any time, with Files off, and
 * repeat it at once, so this phone kept sending at full speed (also over mobile data or a relay).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class SpeedTestIncomingTest {
    private class RecordingLink : SpeedTestLink {
        val ready = CopyOnWriteArrayList<SpeedPayload.Ready>()
        override fun sendEncrypted(kind: String, payload: ByteArray): Boolean = true.also {
            if (kind == SpeedKinds.READY) ready += SpeedPayload.decode(kind, payload) as SpeedPayload.Ready
        }
        override fun sendOuter(kind: String, testId: String, sequence: Long?): Boolean = true
        override fun sendData(testId: String, sequence: Long, plaintext: ByteArray) = true
        override fun localLink(lockHeld: Boolean) = SpeedLink(platform = "android", network = "wifi")
    }

    private fun start(test: SpeedTest, device: String) {
        val payload = SpeedPayload.Start(UUID.randomUUID().toString(), 7, SpeedLink(platform = "macos", network = "wifi")).encode()
        test.receive(device, SpeedKinds.START, payload, null, null)
    }

    @Test
    fun testsFromAnotherDeviceNeedFilesAndAreLimited() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val link = RecordingLink()
        var now = 1_000_000L
        var filesOn = false
        val test = SpeedTest(scope, TransferPowerLock(context, scope), linkFor = { link }, nameOf = { "Mac" },
            allowIncoming = { filesOn }, clock = { now })
        // Files off for that device: refused, and nothing about this phone's network goes back.
        start(test, "mac")
        assertEquals("disabled", link.ready.last().status)
        assertEquals(null, link.ready.last().link)
        filesOn = true
        start(test, "mac")
        assertEquals("ready", link.ready.last().status)
        test.disconnected("mac")
        // Again at once: refused; ten seconds later: taken.
        start(test, "mac")
        assertEquals("busy", link.ready.last().status)
        now += SpeedLimits.INCOMING_SPACING_MILLIS
        start(test, "mac")
        assertEquals("ready", link.ready.last().status)
        test.disconnected("mac")
        // Six an hour, then refused until the hour has passed.
        repeat(4) {
            now += SpeedLimits.INCOMING_SPACING_MILLIS
            start(test, "mac")
            assertEquals("ready", link.ready.last().status)
            test.disconnected("mac")
        }
        now += SpeedLimits.INCOMING_SPACING_MILLIS
        start(test, "mac")
        assertEquals("busy", link.ready.last().status)
        // Another device has its own allowance.
        start(test, "other-mac")
        assertEquals("ready", link.ready.last().status)
        test.disconnected("other-mac")
        now += 3_600_000L
        start(test, "mac")
        assertTrue(link.ready.last().status == "ready")
        scope.cancel()
    }
}
