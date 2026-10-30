package dev.bridgey.android.connect

import android.os.Process
import android.os.SystemClock
import dev.bridgey.android.BridgeyLogging
import dev.bridgey.android.LogCategory

/**
 * The connection waterfall (docs/connect-anywhere-latency.md): every step of reaching a paired device away
 * from home, as one log line with the milliseconds since this process started and the wall clock. The core's
 * own steps arrive as `timing` events; the app adds its own (start, tunnel hand-off, authenticated session).
 * Lines carry step names and short device IDs only, never an address.
 */
object ConnectTiming {
    /** Wall-clock time this process started, so core and app steps share one origin. */
    private val processStartUnixMillis: Long by lazy {
        System.currentTimeMillis() - (SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime())
    }

    fun mark(step: String, peer: String? = null, detail: String? = null, atUnixMillis: Long = System.currentTimeMillis()) {
        val sinceStart = atUnixMillis - processStartUnixMillis
        val extra = buildString {
            if (peer != null) append(" peer=").append(peer.take(8))
            if (!detail.isNullOrEmpty()) append(" detail=").append(detail.take(32))
        }
        BridgeyLogging.i(LogCategory.CONNECTION, "CONNECT timing $step +${sinceStart}ms at=$atUnixMillis$extra")
    }
}
