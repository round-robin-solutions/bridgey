package dev.bridgey.android

import android.content.ClipboardManager
import android.content.Context
import android.os.SystemClock
import java.io.BufferedReader
import java.io.InputStreamReader
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** How the optional background clipboard source is doing, shown as one status line in Settings. */
enum class BackgroundClipboardStatus { OFF, WAITING_FOR_SETUP, READY, DENIED }

/**
 * A seam for an optional source of clipboard changes that works while Bridgey is closed. The
 * foreground listener and the one-tap sends cover the supported paths; this interface lets an
 * advanced, opt-in source be added without touching the rest. [LogcatClipboardSource] is the only
 * implementation today (KDE Connect's READ_LOGS workaround).
 */
interface ClipboardChangeSource {
    val status: StateFlow<BackgroundClipboardStatus>
    fun start()
    fun stop()
}

/** Matches the system line that denies clipboard access to our package. Anchored on the package. */
internal fun isClipboardDenialLine(line: String, packageName: String): Boolean =
    line.contains(packageName) &&
        line.contains("clipboard", ignoreCase = true) &&
        line.contains("deny", ignoreCase = true)

/** Folds a burst of matches into one action within [windowMillis]. Pure, so it is unit tested. */
internal class Debouncer(private val windowMillis: Long) {
    private var lastFireMillis = Long.MIN_VALUE

    fun shouldFire(nowMillis: Long): Boolean {
        if (lastFireMillis != Long.MIN_VALUE && nowMillis - lastFireMillis < windowMillis) return false
        lastFireMillis = nowMillis
        return true
    }
}

/**
 * The optional background clipboard source (off by default). KDE Connect's approach: with a one-time
 * ADB grant of READ_LOGS (and SYSTEM_ALERT_WINDOW to start an activity from the background), register
 * a clip-change listener and read system logs for the line that denies our own read attempt. On a
 * match, start a transparent, excluded-from-recents activity that reads the clipboard once it has
 * window focus and hands it to the same send path, with the same skip rules. No log content is ever
 * stored, logged or forwarded.
 *
 * This cannot be verified without a device and an ADB grant; the line matcher and debounce are the
 * unit-tested parts.
 */
class LogcatClipboardSource(
    private val context: Context,
    private val packageName: String,
    private val hasLogPermission: () -> Boolean,
    private val onClipboardChangeDenied: () -> Unit,
) : ClipboardChangeSource {
    private val mutableStatus = MutableStateFlow(BackgroundClipboardStatus.OFF)
    override val status: StateFlow<BackgroundClipboardStatus> = mutableStatus.asStateFlow()
    private val debouncer = Debouncer(DEBOUNCE_MILLIS)
    private val clipboard = context.getSystemService(ClipboardManager::class.java)

    @Volatile private var running = false
    private var worker: Thread? = null
    private var process: Process? = null
    private var backoffMillis = INITIAL_BACKOFF_MILLIS

    // A copy triggers a read attempt; in the background the system denies it and logs the denial,
    // which the log reader below catches. Reading never succeeds here, so nothing is leaked.
    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        runCatching { clipboard.primaryClip }
    }

    @Synchronized
    override fun start() {
        if (running) return
        if (!hasLogPermission()) {
            mutableStatus.value = BackgroundClipboardStatus.WAITING_FOR_SETUP
            return
        }
        running = true
        backoffMillis = INITIAL_BACKOFF_MILLIS
        runCatching { clipboard.addPrimaryClipChangedListener(clipListener) }
        worker = Thread(::readLogs, "bridgey-clipboard-logcat").apply { isDaemon = true; start() }
    }

    @Synchronized
    override fun stop() {
        running = false
        runCatching { clipboard.removePrimaryClipChangedListener(clipListener) }
        process?.destroy()
        process = null
        worker = null
        mutableStatus.value = BackgroundClipboardStatus.OFF
    }

    private fun readLogs() {
        while (running) {
            val started = SystemClock.elapsedRealtime()
            val exited = runCatching {
                // -T 1 starts at the newest line, so only new denials are read.
                val proc = ProcessBuilder("logcat", "-T", "1", "-v", "brief").redirectErrorStream(true).start()
                process = proc
                mutableStatus.value = BackgroundClipboardStatus.READY
                BufferedReader(InputStreamReader(proc.inputStream)).use { reader ->
                    while (running) {
                        val line = reader.readLine() ?: break
                        if (isClipboardDenialLine(line, packageName) && debouncer.shouldFire(SystemClock.elapsedRealtime())) {
                            onClipboardChangeDenied()
                        }
                    }
                }
            }.isSuccess
            if (!running) break
            // A quick failure right after a granted start means the Android 13+ log prompt was denied.
            if (!exited || SystemClock.elapsedRealtime() - started < DENIED_THRESHOLD_MILLIS) {
                mutableStatus.value = BackgroundClipboardStatus.DENIED
            }
            runCatching { Thread.sleep(backoffMillis) }
            backoffMillis = (backoffMillis * 2).coerceAtMost(MAX_BACKOFF_MILLIS)
        }
    }

    private companion object {
        const val DEBOUNCE_MILLIS = 500L
        const val INITIAL_BACKOFF_MILLIS = 1_000L
        const val MAX_BACKOFF_MILLIS = 30_000L
        const val DENIED_THRESHOLD_MILLIS = 1_500L
    }
}
