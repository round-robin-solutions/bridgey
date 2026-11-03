package dev.bridgey.android

import android.os.Handler

/**
 * Runs [action] once, as soon as the window has input focus, or after [timeoutMs] if focus never
 * arrives. Android 10+ lets only the focused app read the clipboard, and from the Quick Settings tile
 * the shade's collapse animation can keep focus away for well over 150 ms.
 */
internal class FocusGatedRun(
    private val handler: Handler,
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    private val settleMs: Long = SETTLE_MS,
    private val action: () -> Unit,
) {
    private var armed = false
    private var done = false
    private val fire = Runnable {
        if (done) return@Runnable
        done = true
        action()
    }

    /** Starts the fallback timer. Safe to call again: only the first call counts. */
    fun arm() {
        if (armed) return
        armed = true
        handler.postDelayed(fire, timeoutMs)
    }

    /** Call from Activity.onWindowFocusChanged. Ignored until [arm] has been called. */
    fun onWindowFocusChanged(hasFocus: Boolean) {
        if (!hasFocus || !armed || done) return
        handler.removeCallbacks(fire)
        handler.postDelayed(fire, settleMs)
    }

    fun cancel() {
        done = true
        handler.removeCallbacks(fire)
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 1_500L
        const val SETTLE_MS = 30L
    }
}
