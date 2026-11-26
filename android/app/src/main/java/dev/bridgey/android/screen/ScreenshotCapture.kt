package dev.bridgey.android.screen

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.Handler
import android.os.SystemClock
import android.view.Surface
import dev.bridgey.android.BridgeyLogging
import dev.bridgey.android.LogCategory
import dev.bridgey.android.control.mirrorRect
import java.util.concurrent.Executor

/** One screenshot of the default display, or why there is none. */
sealed interface ScreenShot {
    /** [bitmap] is valid until [close]. */
    class Frame(val bitmap: Bitmap, val close: () -> Unit) : ScreenShot

    class Failed(val error: ShotError) : ScreenShot
}

/** Bridgey control's screenshots (AccessibilityService.takeScreenshot, Android 11 and later). */
interface ScreenshotTaker {
    /** Asks for one screenshot of the default display; [done] runs once on [executor]. */
    fun screenshot(executor: Executor, done: (ScreenShot) -> Unit)
}

/**
 * Accessibility screenshots onto the encoder's surface, about 3 a second ([StillFramePacer]), for a Mac allowed without
 * asking when nobody approved Android's video prompt. Each screenshot is drawn as Android mirrors a display (aspect
 * kept, centred, black around it), so phone control maps positions exactly as it does for video. Everything runs on the
 * capture thread: the screenshot answers there, so a retarget never races a draw.
 */
class ScreenshotFrameSource(
    private val taker: ScreenshotTaker,
    private val onFailure: (ScreenStopReason) -> Unit,
    private val clock: () -> Long = SystemClock::elapsedRealtime,
    private val pacer: StillFramePacer = StillFramePacer(),
) : ScreenFrameSource {
    override val fps: Int = StillFrameRates.FPS
    override val repeatsFrames: Boolean = false

    private var handler: Handler? = null
    @Volatile private var surface: Surface? = null
    private var width = 0
    private var height = 0
    @Volatile private var released = false
    private var attempt = 0L
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val next = Runnable { request() }

    override fun attach(surface: Surface, width: Int, height: Int, densityDpi: Int, handler: Handler) {
        this.handler = handler
        retarget(surface, width, height, densityDpi)
        schedule()
    }

    override fun retarget(surface: Surface, width: Int, height: Int, densityDpi: Int) {
        this.surface = surface
        this.width = width
        this.height = height
    }

    override fun release() {
        released = true
        handler?.removeCallbacks(next)
        surface = null
        BridgeyLogging.i(LogCategory.REMOTE_CONTROL, "SCREEN screenshots ended frames=${pacer.frames}")
    }

    private fun schedule() {
        val handler = handler ?: return
        if (released || pacer.inFlight) return
        handler.postDelayed(next, pacer.nextDelay(clock()))
    }

    private fun request() {
        val handler = handler ?: return
        if (released || pacer.inFlight) return
        pacer.requested(clock())
        val current = ++attempt
        var answered = false
        val executor = Executor { task -> handler.post(task) }
        // One lost callback must not stall the share: no answer in time counts as a failure.
        val timeout = Runnable {
            if (!answered && current == attempt) {
                answered = true
                failed(ShotError.OTHER)
            }
        }
        handler.postDelayed(timeout, StillFrameRates.ANSWER_TIMEOUT_MILLIS)
        val asked = runCatching {
            taker.screenshot(executor) { shot ->
                if (answered || current != attempt) {
                    (shot as? ScreenShot.Frame)?.close?.invoke()
                    return@screenshot
                }
                answered = true
                handler.removeCallbacks(timeout)
                when (shot) {
                    is ScreenShot.Frame -> {
                        if (!released) draw(shot.bitmap)
                        shot.close()
                        pacer.succeeded()
                        schedule()
                    }
                    is ScreenShot.Failed -> failed(shot.error)
                }
            }
        }
        if (asked.isFailure) {
            answered = true
            handler.removeCallbacks(timeout)
            BridgeyLogging.w(LogCategory.REMOTE_CONTROL, "SCREEN screenshot refused", asked.exceptionOrNull())
            failed(ShotError.NO_ACCESS)
        }
    }

    private fun failed(error: ShotError) {
        if (released) return
        when (pacer.failed(error)) {
            StillFramePacer.Verdict.RETRY -> schedule()
            StillFramePacer.Verdict.STOP -> {
                BridgeyLogging.i(LogCategory.REMOTE_CONTROL, "SCREEN screenshots stopped error=${error.name.lowercase()}")
                onFailure(ScreenStopReason.FAILED)
            }
        }
    }

    private fun draw(bitmap: Bitmap) {
        val target = surface ?: return
        if (width <= 0 || height <= 0 || bitmap.width <= 0 || bitmap.height <= 0) return
        val fit = mirrorRect(width, height, bitmap.width, bitmap.height)
        runCatching {
            val canvas = target.lockHardwareCanvas()
            try {
                canvas.drawColor(Color.BLACK)
                canvas.drawBitmap(bitmap, null, Rect(fit.left, fit.top, fit.left + fit.width, fit.top + fit.height), paint)
            } finally {
                target.unlockCanvasAndPost(canvas)
            }
        }.onFailure { BridgeyLogging.w(LogCategory.REMOTE_CONTROL, "SCREEN screenshot not drawn", it) }
    }
}
