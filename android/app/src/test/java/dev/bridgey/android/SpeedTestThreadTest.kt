package dev.bridgey.android

import android.app.Application
import androidx.test.core.app.ApplicationProvider
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
 * Live test 2026-10-30: Test with <Mac> on the phone failed at once ("data stopped arriving"), because the screen's tap
 * sent speed.start on the main thread and Android refused the socket write (NetworkOnMainThreadException). Start and
 * Stop now send from the coordinator's scope.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class SpeedTestThreadTest {
    private class RecordingLink : SpeedTestLink {
        val threads = CopyOnWriteArrayList<Pair<String, Thread>>()
        override fun sendEncrypted(kind: String, payload: ByteArray): Boolean = true.also { threads += kind to Thread.currentThread() }
        override fun sendOuter(kind: String, testId: String, sequence: Long?): Boolean = true.also { threads += kind to Thread.currentThread() }
        override fun sendData(testId: String, sequence: Long, plaintext: ByteArray) = true
        override fun localLink(lockHeld: Boolean) = SpeedLink(platform = "android", network = "other")
    }

    @Test
    fun startAndStopNeverSendOnTheCallingThread() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val link = RecordingLink()
        val test = SpeedTest(scope, TransferPowerLock(context, scope), linkFor = { link }, nameOf = { "Mac" })
        val caller = Thread.currentThread()
        test.start("mac")
        assertTrue("speed.start sent", waitFor { link.threads.any { it.first == SpeedKinds.START } })
        assertEquals(SpeedTestState.Phase.CONNECTING, test.state.value.phase)
        test.cancel()
        assertTrue("speed.cancel sent", waitFor { link.threads.any { it.first == SpeedKinds.CANCEL } })
        assertTrue("never on the caller's thread: ${link.threads}", link.threads.none { it.second === caller })
        assertEquals("cancelled", test.state.value.failure)
        scope.cancel()
    }

    private fun waitFor(condition: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < end) {
            if (condition()) return true
            Thread.sleep(20)
        }
        return condition()
    }
}
