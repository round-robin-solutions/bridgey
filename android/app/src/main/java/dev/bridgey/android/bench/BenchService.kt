package dev.bridgey.android.bench

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.StatFs
import dev.bridgey.android.BuildConfig
import dev.bridgey.android.R
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File

sealed interface BenchUiState {
    data object Idle : BenchUiState
    data class Running(val mode: BenchMode, val modeIndex: Int, val modeCount: Int, val fraction: Float) : BenchUiState
    data class Done(val report: BenchReport) : BenchUiState
    data class Failed(val reason: Reason, val detail: String = "") : BenchUiState
    enum class Reason { NO_SPACE, NO_NATIVE, VECTORS, IO, CANCELLED }
}

/** Where the screen reads progress from; the service writes it. */
object BenchState {
    private val mutable = MutableStateFlow<BenchUiState>(BenchUiState.Idle)
    val state: StateFlow<BenchUiState> = mutable
    fun set(value: BenchUiState) { mutable.value = value }
    val running: Boolean get() = mutable.value is BenchUiState.Running
}

/**
 * Runs the performance test in a foreground service (connectedDevice, like the connection
 * service) with a wake lock held only while the test runs.
 */
class BenchService : Service() {
    @Volatile private var cancelled = false
    private var worker: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CANCEL -> cancelled = true
            ACTION_START -> start(intent.getLongExtra(EXTRA_BYTES, QUICK_BYTES))
            else -> if (worker == null) stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun start(bytes: Long) {
        if (worker != null) return
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, getString(R.string.perf_channel), NotificationManager.IMPORTANCE_LOW),
        )
        val notification = notification(getString(R.string.perf_notification_text))
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        cancelled = false
        BenchState.set(BenchUiState.Running(BenchMode.WRITE_ONLY, 0, BenchMode.entries.size, 0f))
        val lock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bridgey:perf-test")
            .also { it.acquire(WAKE_LOCK_MAX_MS) }
        wakeLock = lock
        worker = Thread({
            try {
                BenchState.set(execute(applicationContext, bytes) { cancelled })
            } finally {
                if (lock.isHeld) lock.release()
                wakeLock = null
                worker = null
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }, "bridgey-perf-test").also { it.start() }
    }

    override fun onDestroy() {
        cancelled = true
        wakeLock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    private fun notification(text: String): Notification =
        Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(getString(R.string.perf_title))
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()

    companion object {
        const val ACTION_START = "dev.bridgey.android.bench.START"
        const val ACTION_CANCEL = "dev.bridgey.android.bench.CANCEL"
        const val EXTRA_BYTES = "bytes"
        private const val CHANNEL_ID = "perf_test"
        private const val NOTIFICATION_ID = 7301
        private const val WAKE_LOCK_MAX_MS = 30L * 60 * 1000
        const val READ_BACK_NOTE =
            "Read-back may be served from the page cache, so a real flash read can cost more than shown."

        fun start(context: Context, bytes: Long) {
            val i = Intent(context, BenchService::class.java).setAction(ACTION_START).putExtra(EXTRA_BYTES, bytes)
            context.startForegroundService(i)
        }

        fun cancel(context: Context) {
            context.startService(Intent(context, BenchService::class.java).setAction(ACTION_CANCEL))
        }

        /** The whole run on the calling thread; kept out of the service so it reads straight through. */
        internal fun execute(context: Context, bytes: Long, isCancelled: () -> Boolean): BenchUiState {
            if (!Blake3Native.available) return BenchUiState.Failed(BenchUiState.Reason.NO_NATIVE)
            val dir = File(context.cacheDir, "perf-test").also { it.mkdirs() }
            val free = StatFs(dir.path).availableBytes
            if (!hasEnoughSpace(free, bytes)) {
                dir.deleteRecursively()
                return BenchUiState.Failed(BenchUiState.Reason.NO_SPACE, "$free")
            }
            if (Blake3Vectors.failures(Blake3Native::newHasher).isNotEmpty()) {
                dir.deleteRecursively()
                return BenchUiState.Failed(BenchUiState.Reason.VECTORS)
            }
            return try {
                val bench = HashBenchmark(dir, AndroidBenchProbe(context), Blake3Native::newHasher, isCancelled = isCancelled)
                val modes = BenchMode.entries
                val results = bench.runAll(bytes, modes) { fraction, mode ->
                    BenchState.set(BenchUiState.Running(mode, modes.indexOf(mode), modes.size, fraction))
                }
                BenchUiState.Done(
                    BenchReport(
                        hashImplementation = Blake3Native.LABEL,
                        nativeBlake3 = true,
                        vectorsPassed = true,
                        sizeBytes = bytes,
                        startedAtMillis = System.currentTimeMillis(),
                        device = "${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE}",
                        appVersion = BuildConfig.VERSION_NAME,
                        pluggedIn = AndroidBenchProbe.isPluggedIn(context),
                        readBackNote = READ_BACK_NOTE,
                        results = results,
                    ),
                )
            } catch (_: BenchCancelled) {
                BenchUiState.Failed(BenchUiState.Reason.CANCELLED)
            } catch (e: java.io.IOException) {
                BenchUiState.Failed(BenchUiState.Reason.IO, e.message ?: "")
            } finally {
                dir.deleteRecursively()
            }
        }
    }
}
