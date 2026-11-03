package dev.bridgey.android

import android.os.Handler
import android.os.Looper
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class FocusGatedRunTest {
    private val looper = Looper.getMainLooper()
    private fun advance(ms: Long) = shadowOf(looper).idleFor(ms, TimeUnit.MILLISECONDS)

    @Test
    fun doesNotRunAt150msWithoutFocus() {
        var runs = 0
        FocusGatedRun(Handler(looper)) { runs++ }.arm()
        advance(200)
        assertEquals(0, runs)
    }

    @Test
    fun runsOnceShortlyAfterFocusEvenIfShadeIsSlow() {
        var runs = 0
        val gate = FocusGatedRun(Handler(looper)) { runs++ }
        gate.arm()
        advance(900)
        gate.onWindowFocusChanged(true)
        advance(100)
        assertEquals(1, runs)
        gate.onWindowFocusChanged(true)
        advance(2_000)
        assertEquals(1, runs)
    }

    @Test
    fun fallsBackAfterTimeoutWhenFocusNeverArrives() {
        var runs = 0
        FocusGatedRun(Handler(looper)) { runs++ }.arm()
        advance(1_400)
        assertEquals(0, runs)
        advance(200)
        assertEquals(1, runs)
    }

    @Test
    fun focusLossAndCancelDoNothing() {
        var runs = 0
        val gate = FocusGatedRun(Handler(looper)) { runs++ }
        gate.arm()
        gate.onWindowFocusChanged(false)
        gate.cancel()
        advance(3_000)
        assertEquals(0, runs)
    }

    @Test
    fun focusBeforeArmIsIgnored() {
        var runs = 0
        val gate = FocusGatedRun(Handler(looper)) { runs++ }
        gate.onWindowFocusChanged(true)
        advance(100)
        assertEquals(0, runs)
    }
}
