package dev.bridgey.android

import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import java.net.Inet4Address
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/*
 * The Android side of reconnecting: the real clock, the address book's storage, the network,
 * Doze and screen watcher, the optional Wi-Fi lock and the power facts that go into diagnostics.
 */

/** Monotonic time that counts deep sleep; timers run on one background thread. */
internal class AndroidReconnectClock : ReconnectClock {
    private val executor = Executors.newSingleThreadScheduledExecutor { Thread(it, "bridgey-reconnect").apply { isDaemon = true } }

    override fun elapsedMillis(): Long = SystemClock.elapsedRealtime()

    override fun wallMillis(): Long = System.currentTimeMillis()

    override fun schedule(delayMillis: Long, action: () -> Unit): ScheduledTask {
        val future = executor.schedule({
            runCatching(action).onFailure { Log.w("Bridgey", "RECONNECT timer failed", it) }
        }, delayMillis.coerceAtLeast(0), TimeUnit.MILLISECONDS)
        return ScheduledTask { future.cancel(false) }
    }
}

internal class SharedPreferencesAddressBookStore(context: Context) : AddressBookStore {
    private val preferences = context.getSharedPreferences("bridgey.reconnect", Context.MODE_PRIVATE)

    override fun load(): String? = preferences.getString(KEY, null)

    override fun save(value: String) {
        preferences.edit().putString(KEY, value).apply()
    }

    private companion object {
        const val KEY = "address_book_v1"
    }
}

/**
 * Reports the moments a dropped Mac is likely reachable again, and which local networks this
 * phone is on. Recovery events: the default network appeared, was lost or changed its addresses,
 * a Wi-Fi or Ethernet network came or went, the phone left Doze, the screen turned on. Other
 * power changes are reported as observations, for diagnostics only. Callbacks are raw; the
 * coordinator debounces them.
 */
internal class NetworkWatcher(
    context: Context,
    private val onRecoveryEvent: (String) -> Unit,
    private val onObservation: (String) -> Unit,
) {
    private val appContext = context.applicationContext
    private val connectivity = appContext.getSystemService(ConnectivityManager::class.java)
    private val power = appContext.getSystemService(PowerManager::class.java)
    private val localLinks = ConcurrentHashMap<Network, List<LocalIPv4Network>>()
    @Volatile private var defaultNetwork: Network? = null
    @Volatile private var defaultSignature: String? = null
    @Volatile private var registered = false
    @Volatile private var initialLocal = true

    /**
     * IPv4 networks of every Wi-Fi and Ethernet link: what the reconnect engine may dial. Before
     * the callbacks have reported anything, the active network is asked directly.
     */
    fun localNetworks(): List<LocalIPv4Network> {
        val known = localLinks.values.flatten().distinct()
        if (known.isNotEmpty()) return known
        return runCatching {
            val network = connectivity.activeNetwork ?: return emptyList()
            val capabilities = connectivity.getNetworkCapabilities(network) ?: return emptyList()
            if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
            ) return emptyList()
            connectivity.getLinkProperties(network)?.let(::ipv4Networks).orEmpty()
        }.getOrDefault(emptyList())
    }

    private fun ipv4Networks(properties: LinkProperties): List<LocalIPv4Network> = properties.linkAddresses.mapNotNull { link ->
        val address = link.address as? Inet4Address ?: return@mapNotNull null
        if (address.isLinkLocalAddress || address.isLoopbackAddress) return@mapNotNull null
        parseIPv4(address.hostAddress ?: return@mapNotNull null)?.let { LocalIPv4Network(it, link.prefixLength) }
    }

    private val defaultCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val previous = defaultNetwork
            defaultNetwork = network
            // The first callback describes the network at registration: not a change.
            if (previous != null && previous != network) onRecoveryEvent("network_available")
        }

        override fun onLost(network: Network) {
            if (network != defaultNetwork) return
            defaultNetwork = null
            defaultSignature = null
            onRecoveryEvent("network_lost")
        }

        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
            if (network != defaultNetwork) return
            val signature = properties.linkAddresses.map { it.toString() }.sorted().joinToString(",") + "|" + properties.interfaceName
            val previous = defaultSignature
            defaultSignature = signature
            if (previous != null && previous != signature) onRecoveryEvent("link_change")
        }
    }

    private val localCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            if (!initialLocal) onRecoveryEvent("local_network_available")
        }

        override fun onLost(network: Network) {
            localLinks.remove(network)
            onRecoveryEvent("local_network_lost")
        }

        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
            val networks = ipv4Networks(properties)
            val previous = localLinks.put(network, networks)
            if (previous != null && previous != networks) onRecoveryEvent("local_address_change")
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED ->
                    if (power.isDeviceIdleMode) onObservation("doze_enter") else onRecoveryEvent("doze_exit")
                PowerManager.ACTION_POWER_SAVE_MODE_CHANGED ->
                    onObservation(if (power.isPowerSaveMode) "battery_saver_on" else "battery_saver_off")
                Intent.ACTION_SCREEN_ON -> onRecoveryEvent("screen_on")
                Intent.ACTION_SCREEN_OFF -> onObservation("screen_off")
            }
        }
    }

    fun start() {
        if (registered) return
        registered = true
        initialLocal = true
        runCatching { connectivity.registerDefaultNetworkCallback(defaultCallback) }
            .onFailure { Log.w(TAG, "RECONNECT default network callback failed", it) }
        val local = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        runCatching { connectivity.registerNetworkCallback(local, localCallback) }
            .onFailure { Log.w(TAG, "RECONNECT local network callback failed", it) }
        // Callbacks for networks already up arrive right after registering; later ones are changes.
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ initialLocal = false }, 3_000)
        val filter = IntentFilter().apply {
            addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            appContext.registerReceiver(receiver, filter)
        }
    }

    fun stop() {
        if (!registered) return
        registered = false
        runCatching { connectivity.unregisterNetworkCallback(defaultCallback) }
        runCatching { connectivity.unregisterNetworkCallback(localCallback) }
        runCatching { appContext.unregisterReceiver(receiver) }
        localLinks.clear()
        defaultNetwork = null
        defaultSignature = null
    }

    private companion object {
        const val TAG = "Bridgey"
    }
}

/**
 * Optional Wi-Fi lock while the connection service runs (Settings, off by default). It only
 * helps on Android 13 and older: from Android 14 a high-performance lock is turned into a
 * low-latency one, which works only while the screen is on and Bridgey is in front, so it does
 * nothing for an overnight connection.
 */
internal class WifiKeeper(context: Context) {
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private var lock: WifiManager.WifiLock? = null

    @Synchronized fun set(enabled: Boolean) {
        if (enabled && SUPPORTED) {
            if (lock?.isHeld == true) return
            @Suppress("DEPRECATION")
            lock = runCatching {
                wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "bridgey:connection").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }.getOrNull()
            Log.i("Bridgey", "RECONNECT wifi lock held=${lock?.isHeld == true}")
        } else {
            lock?.takeIf { it.isHeld }?.release()
            lock = null
        }
    }

    companion object {
        /** Android 13 and older; see the class comment. */
        val SUPPORTED: Boolean get() = Build.VERSION.SDK_INT <= 33
    }
}

/** Power facts for diagnostics and the battery setting: no personal data. */
internal object PowerFacts {
    fun ignoringBatteryOptimizations(context: Context): Boolean =
        context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)

    /** "idle", "power_save", the app standby bucket and the exemption, as one diagnostics token. */
    fun summary(context: Context): String {
        val power = context.getSystemService(PowerManager::class.java)
        val bucket = if (Build.VERSION.SDK_INT >= 28) {
            runCatching { context.getSystemService(UsageStatsManager::class.java).appStandbyBucket.toString() }.getOrDefault("unknown")
        } else {
            "none"
        }
        return listOf(
            if (power.isDeviceIdleMode) "idle" else "awake",
            if (power.isInteractive) "screen_on" else "screen_off",
            if (power.isPowerSaveMode) "saver_on" else "saver_off",
            "bucket_$bucket",
            if (ignoringBatteryOptimizations(context)) "exempt" else "optimised",
        ).joinToString("_")
    }
}
