package dev.bridgey.core.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import java.net.Inet4Address
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Publishes this phone and browses for Bridgey devices with NsdManager.
 *
 * NsdManager is easy to wedge, so every call and every callback runs on one thread, in order:
 * - each start uses fresh listener objects (a listener may not be reused while registered);
 * - a restart unregisters and stops first, then starts again after [RESTART_GAP_MILLIS], so the
 *   new registration never collides with the old one;
 * - resolves run one at a time (older releases fail a second concurrent resolve);
 * - callbacks from an earlier start are ignored.
 * Peers stay listed across a restart; any not seen again within [PRUNE_AFTER_RESTART_MILLIS]
 * are dropped, so a restart never makes devices blink out of the screen.
 */
class NsdDiscoveryService(
    context: Context,
    private var identity: LocalDiscoveryIdentity,
    private val servicePort: Int = DEFAULT_PORT,
) : DiscoveryService {
    private val nsd = context.applicationContext.getSystemService(NsdManager::class.java)
    private val worker = Executors.newSingleThreadScheduledExecutor { Thread(it, "bridgey-nsd").apply { isDaemon = true } }
    private val found = LinkedHashMap<String, DiscoveredPeer>()
    private val mutablePeers = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    override val peers: StateFlow<List<DiscoveredPeer>> = mutablePeers.asStateFlow()

    /** Called on the NSD thread: ("restarted", reason), ("publish_failed", code), ("browse_failed", code). */
    @Volatile var onEvent: ((event: String, detail: String) -> Unit)? = null

    // Everything below is touched on the worker thread only.
    private var wanted = false
    private var generation = 0
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var restartTask: ScheduledFuture<*>? = null
    private var pruneTask: ScheduledFuture<*>? = null
    private var refreshed = HashSet<String>()
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving: String? = null
    private var resolveTimeout: ScheduledFuture<*>? = null

    private val registeredServiceName get() = "Bridgey-${identity.deviceId.take(8)}"

    override fun start() = post {
        if (wanted) return@post
        wanted = true
        begin()
        Log.i(TAG, "DISCOVERY browsing started")
    }

    override fun stop() = post {
        if (!wanted) return@post
        wanted = false
        restartTask?.cancel(false)
        restartTask = null
        pruneTask?.cancel(false)
        pruneTask = null
        tearDown()
        found.clear()
        emitPeers()
        Log.i(TAG, "DISCOVERY browsing stopped")
    }

    /**
     * Unregisters and stops browsing, then starts both again: the phone announces itself afresh
     * and asks the network again. Calls while a restart is pending collapse into one.
     */
    fun restart(reason: String) = post {
        if (!wanted || restartTask != null) return@post
        Log.i(TAG, "DISCOVERY restart reason=$reason")
        tearDown()
        pruneTask?.cancel(false)
        refreshed = HashSet()
        restartTask = worker.schedule({
            restartTask = null
            if (!wanted) return@schedule
            begin()
            onEvent?.invoke("restarted", reason)
            pruneTask = worker.schedule({
                pruneTask = null
                val gone = found.keys.filter { it !in refreshed }
                if (gone.isEmpty()) return@schedule
                gone.forEach(found::remove)
                emitPeers()
                Log.i(TAG, "DISCOVERY restart dropped peers=${gone.size}")
            }, PRUNE_AFTER_RESTART_MILLIS, TimeUnit.MILLISECONDS)
        }, RESTART_GAP_MILLIS, TimeUnit.MILLISECONDS)
    }

    fun updateDeviceName(value: String) = post {
        val name = value.trim().take(64).ifBlank { "Android device" }
        if (name == identity.deviceName) return@post
        identity = identity.copy(deviceName = name)
        if (wanted) {
            // restart() posts; it runs right after this block.
            restart("rename")
        }
    }

    private fun post(block: () -> Unit) {
        worker.execute { runCatching(block).onFailure { Log.w(TAG, "DISCOVERY call failed", it) } }
    }

    private fun begin() {
        val current = ++generation
        val info = NsdServiceInfo().apply {
            serviceName = registeredServiceName
            serviceType = SERVICE_TYPE
            port = servicePort
            setAttribute("id", identity.deviceId)
            setAttribute("name", identity.deviceName.take(64))
            setAttribute("version", PROTOCOL_VERSION.toString())
            setAttribute("platform", "android")
        }
        val registrationListener = registrationListener(current)
        val discoveryListener = discoveryListener(current)
        registration = registrationListener
        discovery = discoveryListener
        runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registrationListener) }
            .onFailure { Log.w(TAG, "DISCOVERY publish call failed", it) }
        runCatching { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener) }
            .onFailure { Log.w(TAG, "DISCOVERY browse call failed", it) }
    }

    private fun tearDown() {
        generation++
        registration?.let { listener -> runCatching { nsd.unregisterService(listener) } }
        discovery?.let { listener -> runCatching { nsd.stopServiceDiscovery(listener) } }
        registration = null
        discovery = null
        resolveQueue.clear()
        resolving = null
        resolveTimeout?.cancel(false)
        resolveTimeout = null
    }

    private fun registrationListener(owner: Int) = object : NsdManager.RegistrationListener {
        override fun onServiceRegistered(info: NsdServiceInfo) = post {
            Log.i(TAG, "DISCOVERY service published name=${info.serviceName} current=${owner == generation}")
        }
        override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) = post {
            Log.w(TAG, "DISCOVERY publish failed code=$errorCode")
            if (owner == generation) onEvent?.invoke("publish_failed", errorCode.toString())
        }
        override fun onServiceUnregistered(info: NsdServiceInfo) = post {
            Log.i(TAG, "DISCOVERY service unpublished")
        }
        override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = post {
            Log.w(TAG, "DISCOVERY unpublish failed code=$errorCode")
        }
    }

    private fun discoveryListener(owner: Int) = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(type: String) = post {
            Log.i(TAG, "DISCOVERY browse started current=${owner == generation}")
        }
        override fun onDiscoveryStopped(type: String) = post {
            Log.i(TAG, "DISCOVERY browse stopped")
        }
        override fun onStartDiscoveryFailed(type: String, errorCode: Int) = post {
            Log.w(TAG, "DISCOVERY browse start failed code=$errorCode")
            if (owner == generation) {
                discovery = null
                onEvent?.invoke("browse_failed", errorCode.toString())
            }
        }
        override fun onStopDiscoveryFailed(type: String, errorCode: Int) = post {
            Log.w(TAG, "DISCOVERY browse stop failed code=$errorCode")
        }
        override fun onServiceFound(info: NsdServiceInfo) = post {
            if (owner != generation || info.serviceName == registeredServiceName) return@post
            if (resolveQueue.none { it.serviceName == info.serviceName } && resolving != info.serviceName) {
                resolveQueue.addLast(info)
            }
            resolveNext()
        }
        override fun onServiceLost(info: NsdServiceInfo) = post {
            if (owner != generation) return@post
            resolveQueue.removeAll { it.serviceName == info.serviceName }
            if (found.remove(info.serviceName) != null) emitPeers()
            Log.i(TAG, "DISCOVERY peer lost service=${info.serviceName}")
        }
    }

    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (resolving != null) return
        val next = resolveQueue.removeFirstOrNull() ?: return
        val owner = generation
        resolving = next.serviceName
        val listener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = post {
                Log.w(TAG, "DISCOVERY resolve failed code=$errorCode")
                finishResolve(owner, serviceInfo.serviceName)
            }
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) = post {
                if (owner == generation) accept(serviceInfo)
                finishResolve(owner, serviceInfo.serviceName)
            }
        }
        // A resolve whose callback never comes must not block the queue.
        resolveTimeout = worker.schedule({ finishResolve(owner, next.serviceName) }, RESOLVE_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)
        // The legacy resolver is the minSdk-compatible path; discovery hints stay untrusted.
        runCatching { nsd.resolveService(next, listener) }.onFailure {
            Log.w(TAG, "DISCOVERY resolve call failed", it)
            finishResolve(owner, next.serviceName)
        }
    }

    private fun finishResolve(owner: Int, serviceName: String) {
        if (owner != generation || resolving != serviceName) return
        resolving = null
        resolveTimeout?.cancel(false)
        resolveTimeout = null
        resolveNext()
    }

    private fun accept(info: NsdServiceInfo) {
        val attributes = info.attributes.mapValues { it.value ?: byteArrayOf() }
        val parsed = DiscoveryTxtRecord.parse(info.serviceName, attributes)
        // A renamed copy of this phone's own service (name conflict after a restart) is not a peer.
        if (parsed.deviceIdHint == identity.deviceId) return
        val addresses = orderedAddresses(resolvedHosts(info))
        found[parsed.key] = parsed.copy(
            host = addresses.firstOrNull(),
            port = info.port.takeIf { it in 1..65535 },
            addresses = addresses,
        )
        refreshed += parsed.key
        emitPeers()
        Log.i(TAG, "DISCOVERY peer discovered service=${info.serviceName} addresses=${addresses.size}")
    }

    @Suppress("DEPRECATION")
    private fun resolvedHosts(info: NsdServiceInfo): List<InetAddress> =
        if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)

    private fun emitPeers() {
        mutablePeers.value = found.values.sortedBy { it.deviceNameHint.lowercase() }
    }

    companion object {
        const val SERVICE_TYPE = "_bridgey._tcp."
        const val DEFAULT_PORT = 42_458
        const val PROTOCOL_VERSION = 1
        private const val TAG = "Bridgey"
        private const val RESTART_GAP_MILLIS = 1_000L
        private const val PRUNE_AFTER_RESTART_MILLIS = 8_000L
        private const val RESOLVE_TIMEOUT_MILLIS = 10_000L

        /** IPv4 first, then IPv6 that is not link-local (a link-local address needs a scope to dial). */
        fun orderedAddresses(addresses: List<InetAddress>): List<String> {
            val v4 = addresses.filterIsInstance<Inet4Address>().mapNotNull { it.hostAddress }
            val v6 = addresses.filter { it !is Inet4Address && !it.isLinkLocalAddress }.mapNotNull { it.hostAddress?.substringBefore('%') }
            return (v4 + v6).distinct()
        }
    }
}

data class LocalDiscoveryIdentity(val deviceId: String, val deviceName: String) {
    init { require(runCatching { UUID.fromString(deviceId) }.isSuccess) }
}
