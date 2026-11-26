package dev.bridgey.android.screen

import dev.bridgey.android.control.PhoneControlGrantMode

/*
 * Unattended access (Rahul, 26 Nov; docs/screen-control-decision.md): a Mac allowed without asking may see this phone
 * with nobody here. Android still asks for its own video consent every time, so when nobody approves it the share falls
 * back to accessibility screenshots (AccessibilityService.takeScreenshot, Android 11 and later) at about 3 a second,
 * encoded into the same H.264 stream and marked `mode: screenshots` in screen.start. Pure Kotlin, tested on the JVM.
 */

/** How a share's frames are made. */
enum class ScreenMode(val wire: String?) {
    /** MediaProjection, after the person approved Android's prompt. */
    VIDEO(null),

    /** Accessibility screenshots, about 3 a second: nobody approved video. */
    SCREENSHOTS("screenshots"),
}

/** Why a Mac allowed without asking still waits for someone on the phone (screen.status `needs`). */
enum class ScreenNeeds(val wire: String) {
    /** Bridgey control is off in Android's accessibility settings. */
    ACCESSIBILITY("accessibility"),

    /** Screenshots need Android 11 or later. */
    ANDROID_11("android_11"),

    /** The phone is locked or its screen is off. */
    UNLOCK("unlock"),
}

/** What a request from a Mac does here. */
sealed interface ScreenRoute {
    /** Ask the person (Android's dialog or a notification); [needs] says why it could not go unattended. */
    data class Ask(val needs: ScreenNeeds?) : ScreenRoute

    /** Share accessibility screenshots now, without asking. */
    data object Screenshots : ScreenRoute
}

/** What the hub answered a request with. */
sealed interface ScreenAnswer {
    /** screen.status waiting, with [needs] when the Mac is allowed without asking. */
    data class Waiting(val needs: ScreenNeeds? = null) : ScreenAnswer

    /** An unattended share is starting: screen.start follows, no status. */
    data object Sharing : ScreenAnswer
}

/**
 * The route for a request from a Mac whose grant here is [grant]. Only Allow without asking goes unattended, and only
 * with the phone unlocked and its screen on (control refuses a locked phone anyway), on Android 11 or later, with Bridgey
 * control connected. Anything else asks the person, as before unattended access.
 */
fun screenRoute(grant: PhoneControlGrantMode, unlocked: Boolean, screenOn: Boolean, sdkInt: Int, serviceConnected: Boolean): ScreenRoute = when {
    grant != PhoneControlGrantMode.ALWAYS -> ScreenRoute.Ask(null)
    !unlocked || !screenOn -> ScreenRoute.Ask(ScreenNeeds.UNLOCK)
    sdkInt < StillFrameRates.MIN_SDK -> ScreenRoute.Ask(ScreenNeeds.ANDROID_11)
    !serviceConnected -> ScreenRoute.Ask(ScreenNeeds.ACCESSIBILITY)
    else -> ScreenRoute.Screenshots
}

object StillFrameRates {
    /** AccessibilityService.takeScreenshot: Android 11. */
    const val MIN_SDK = 30

    /** Android refuses a screenshot within 333 ms of the last one; a little more keeps clear of that. */
    const val INTERVAL_MILLIS = 340L
    const val FPS = 3

    /** Lower than video's 4 Mb/s: a third of a second of change goes into each frame. */
    const val START_BITRATE = 1_500_000L

    /** After a refusal for asking too soon, the next try waits this much longer. */
    const val TOO_SOON_BACKOFF_MILLIS = 60L

    /** This many failures in a row (other than asking too soon) end the share. */
    const val MAX_FAILURES = 5

    /** A screenshot that has not answered after this long counts as a failure, so one lost callback cannot stall it. */
    const val ANSWER_TIMEOUT_MILLIS = 2_000L
}

/** Why a screenshot did not come, from AccessibilityService's error codes. */
enum class ShotError {
    /** ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT: asked within 333 ms of the last one. */
    TOO_SOON,

    /** ERROR_TAKE_SCREENSHOT_NO_ACCESSIBILITY_ACCESS: the service lost the capability. */
    NO_ACCESS,

    /** The display went away or is off. */
    INVALID_DISPLAY,

    /** Anything else (internal error, a secure window, no answer in time). */
    OTHER,
}

/**
 * The pace of a screenshot share: one screenshot in flight at a time, one every 340 ms at most (about 3 a second), never
 * sooner than Android allows; a refusal for asking too soon backs off, other failures retry until five in a row, and
 * losing the capability or the display ends the share. Milliseconds from one monotonic clock.
 */
class StillFramePacer(
    private val intervalMillis: Long = StillFrameRates.INTERVAL_MILLIS,
    private val maxFailures: Int = StillFrameRates.MAX_FAILURES,
) {
    enum class Verdict { RETRY, STOP }

    private var lastRequestAt: Long? = null
    private var extraMillis = 0L
    private var failures = 0

    /** A screenshot was asked for and has not answered yet. */
    var inFlight = false
        private set

    /** Frames that came, for the log. */
    var frames = 0L
        private set

    /** How long to wait at [now] before asking for the next screenshot. */
    @Synchronized fun nextDelay(now: Long): Long {
        val last = lastRequestAt ?: return 0
        return (last + intervalMillis + extraMillis - now).coerceAtLeast(0)
    }

    @Synchronized fun requested(now: Long) {
        lastRequestAt = now
        inFlight = true
    }

    @Synchronized fun succeeded() {
        inFlight = false
        failures = 0
        extraMillis = 0
        frames++
    }

    @Synchronized fun failed(error: ShotError): Verdict {
        inFlight = false
        return when (error) {
            ShotError.TOO_SOON -> {
                extraMillis = (extraMillis + StillFrameRates.TOO_SOON_BACKOFF_MILLIS).coerceAtMost(intervalMillis)
                Verdict.RETRY
            }
            ShotError.NO_ACCESS, ShotError.INVALID_DISPLAY -> Verdict.STOP
            ShotError.OTHER -> if (++failures >= maxFailures) Verdict.STOP else Verdict.RETRY
        }
    }
}
