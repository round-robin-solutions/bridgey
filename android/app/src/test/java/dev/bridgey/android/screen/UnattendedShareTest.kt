package dev.bridgey.android.screen

import dev.bridgey.android.control.PhoneControlGrantMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Unattended access on the phone: which requests go unattended, and the pace of the screenshot fallback. */
class UnattendedShareTest {
    private fun route(
        grant: PhoneControlGrantMode = PhoneControlGrantMode.ALWAYS,
        unlocked: Boolean = true,
        screenOn: Boolean = true,
        sdkInt: Int = 36,
        service: Boolean = true,
    ) = screenRoute(grant, unlocked, screenOn, sdkInt, service)

    @Test fun onlyAllowWithoutAskingGoesUnattended() {
        assertEquals(ScreenRoute.Screenshots, route())
        assertEquals("Ask each time asks, as before", ScreenRoute.Ask(null), route(grant = PhoneControlGrantMode.ASK))
        assertEquals(ScreenRoute.Ask(null), route(grant = PhoneControlGrantMode.OFF))
    }

    @Test fun whatIsMissingIsSaidRatherThanFailingQuietly() {
        assertEquals(ScreenRoute.Ask(ScreenNeeds.UNLOCK), route(unlocked = false))
        assertEquals(ScreenRoute.Ask(ScreenNeeds.UNLOCK), route(screenOn = false))
        assertEquals("Android 10 has no accessibility screenshots", ScreenRoute.Ask(ScreenNeeds.ANDROID_11), route(sdkInt = 29))
        assertEquals(ScreenRoute.Screenshots, route(sdkInt = 30))
        assertEquals(ScreenRoute.Ask(ScreenNeeds.ACCESSIBILITY), route(service = false))
        assertEquals("a locked phone says unlock first", ScreenRoute.Ask(ScreenNeeds.UNLOCK), route(unlocked = false, sdkInt = 29, service = false))
    }

    @Test fun theWaitingStatusCarriesNeedsOnlyWithWaiting() {
        assertEquals("unlock", screenStatusPayload(REQUEST, ScreenStatus.WAITING, ScreenNeeds.UNLOCK).getString("needs"))
        assertFalse(screenStatusPayload(REQUEST, ScreenStatus.WAITING).has("needs"))
        assertFalse(screenStatusPayload(REQUEST, ScreenStatus.DECLINED, ScreenNeeds.UNLOCK).has("needs"))
    }

    @Test fun aboutThreeScreenshotsASecondAndNeverSoonerThanAndroidAllows() {
        val pacer = StillFramePacer()
        var now = 10_000L
        assertEquals("the first one at once", 0L, pacer.nextDelay(now))
        var frames = 0
        while (now < 20_000L) {
            now += pacer.nextDelay(now)
            pacer.requested(now)
            assertTrue(pacer.inFlight)
            now += 25 // the screenshot's own time
            pacer.succeeded()
            frames++
        }
        assertTrue("about 3 a second over 10 seconds, was $frames", frames in 28..30)
        pacer.requested(now)
        pacer.succeeded()
        assertEquals("one interval after the last request, not after its answer", StillFrameRates.INTERVAL_MILLIS, pacer.nextDelay(now))
        assertTrue(StillFrameRates.INTERVAL_MILLIS > 333)
    }

    @Test fun aSlowScreenshotIsFollowedAtOnce() {
        val pacer = StillFramePacer()
        pacer.requested(0)
        pacer.succeeded()
        assertEquals(0L, pacer.nextDelay(500))
    }

    @Test fun askingTooSoonBacksOffAndRecovers() {
        val pacer = StillFramePacer()
        pacer.requested(0)
        assertEquals(StillFramePacer.Verdict.RETRY, pacer.failed(ShotError.TOO_SOON))
        assertFalse(pacer.inFlight)
        assertEquals(StillFrameRates.INTERVAL_MILLIS + StillFrameRates.TOO_SOON_BACKOFF_MILLIS, pacer.nextDelay(0))
        repeat(20) { pacer.failed(ShotError.TOO_SOON) }
        assertEquals("the back-off is bounded", 2 * StillFrameRates.INTERVAL_MILLIS, pacer.nextDelay(0))
        pacer.requested(1_000)
        pacer.succeeded()
        assertEquals("a frame resets it", StillFrameRates.INTERVAL_MILLIS, pacer.nextDelay(1_000))
    }

    @Test fun otherFailuresRetryUntilFiveInARow() {
        val pacer = StillFramePacer()
        repeat(4) { assertEquals(StillFramePacer.Verdict.RETRY, pacer.failed(ShotError.OTHER)) }
        pacer.succeeded()
        repeat(4) { assertEquals("a frame between resets the count", StillFramePacer.Verdict.RETRY, pacer.failed(ShotError.OTHER)) }
        assertEquals(StillFramePacer.Verdict.STOP, pacer.failed(ShotError.OTHER))
    }

    @Test fun losingTheCapabilityOrTheDisplayEndsTheShare() {
        assertEquals(StillFramePacer.Verdict.STOP, StillFramePacer().failed(ShotError.NO_ACCESS))
        assertEquals(StillFramePacer.Verdict.STOP, StillFramePacer().failed(ShotError.INVALID_DISPLAY))
    }

    @Test fun eachScreenshotIsDrawnWhereAndroidMirrorsADisplay() {
        // A 1080 x 2400 phone in a 720 x 1600 stream fills it; the same phone in landscape (2400 x 1080) is letterboxed.
        assertEquals(dev.bridgey.android.control.MirrorRect(0, 0, 720, 1600), dev.bridgey.android.control.mirrorRect(720, 1600, 1080, 2400))
        val landscape = dev.bridgey.android.control.mirrorRect(720, 1600, 2400, 1080)
        assertEquals(720, landscape.width)
        assertEquals(324, landscape.height)
        assertEquals((1600 - 324) / 2, landscape.top)
    }

    private companion object {
        const val REQUEST = "5a3e4c1b-8f2d-4e6a-9b7c-1d2e3f4a5b6c"
    }
}
