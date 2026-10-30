package dev.bridgey.android

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Keeps Wi-Fi out of power saving and the CPU awake while a transfer or a speed test runs, and only then
 * (docs/transfer-speed.md). Android 10 and later get a low-latency Wi-Fi lock; Android 10 to 13 also a
 * high-performance one, which there works with the screen off too; older versions only the high-performance one.
 * From Android 14 the high-performance mode is gone and the low-latency lock works only while the screen is on and
 * Bridgey is in front, so a transfer with the screen off can still be slowed by power saving; the speed test says so.
 * A partial wake lock with a timeout keeps the CPU running. Released two seconds after the last holder lets go, so a
 * run of downloads does not flap it.
 */
internal class TransferPowerLock(context: Context, private val scope: CoroutineScope) {
    private val appContext = context.applicationContext
    private val wifi: WifiManager? = appContext.getSystemService(WifiManager::class.java)
    private val power: PowerManager? = appContext.getSystemService(PowerManager::class.java)
    private var wifiLocks: List<WifiManager.WifiLock> = emptyList()
    private var wakeLock: PowerManager.WakeLock? = null
    private val holders = HashSet<String>()
    private var releaseJob: Job? = null

    /** True while the locks are held. */
    @Volatile var held = false
        private set

    @Synchronized fun acquire(holder: String) {
        holders += holder
        releaseJob?.cancel()
        releaseJob = null
        if (held) {
            // Renew the wake lock's timeout for a long transfer.
            runCatching { wakeLock?.acquire(WAKE_TIMEOUT_MILLIS) }
            return
        }
        wifiLocks = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                wifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY)?.let(::add)
            }
            if (Build.VERSION.SDK_INT <= 33) {
                @Suppress("DEPRECATION")
                wifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF)?.let(::add)
            }
        }
        wakeLock = runCatching {
            power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bridgey:transfer")?.apply {
                setReferenceCounted(false)
                acquire(WAKE_TIMEOUT_MILLIS)
            }
        }.getOrNull()
        held = wifiLocks.isNotEmpty()
        BridgeyLogging.i(LogCategory.FILES, "POWER transfer locks wifi=${wifiLocks.size} wake=${wakeLock?.isHeld == true}")
    }

    @Synchronized fun release(holder: String) {
        if (!holders.remove(holder) || holders.isNotEmpty() || releaseJob != null) return
        releaseJob = scope.launch {
            delay(LINGER_MILLIS)
            synchronized(this@TransferPowerLock) {
                releaseJob = null
                if (holders.isEmpty()) releaseNow()
            }
        }
    }

    /** The screen is on: Android applies the low-latency lock only then. */
    val screenOn: Boolean get() = power?.isInteractive == true

    private fun releaseNow() {
        wifiLocks.forEach { lock -> runCatching { if (lock.isHeld) lock.release() } }
        wifiLocks = emptyList()
        runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
        wakeLock = null
        held = false
        BridgeyLogging.i(LogCategory.FILES, "POWER transfer locks released")
    }

    private fun wifiLock(mode: Int): WifiManager.WifiLock? = runCatching {
        wifi?.createWifiLock(mode, "bridgey:transfer")?.apply {
            setReferenceCounted(false)
            acquire()
        }
    }.getOrNull()

    private companion object {
        const val WAKE_TIMEOUT_MILLIS = 10 * 60 * 1000L
        const val LINGER_MILLIS = 2_000L
    }
}
