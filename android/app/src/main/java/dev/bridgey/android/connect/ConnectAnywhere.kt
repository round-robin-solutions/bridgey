package dev.bridgey.android.connect

import dev.bridgey.android.BridgeyLogging
import dev.bridgey.android.LogCategory
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.net.InetSocketAddress
import java.net.Socket
import java.util.Base64

/**
 * The Connect anywhere core (rust/core, `libbridgey_connect.so`) through JNI: JSON commands in,
 * JSON events out. Loading fails softly: a build without the library shows "not available".
 */
internal object ConnectCore {
    val loaded: Boolean by lazy {
        runCatching { System.loadLibrary("bridgey_connect") }
            .onFailure { BridgeyLogging.w(LogCategory.CONNECTION, "CONNECT core not loaded", it) }
            .isSuccess
    }

    @JvmStatic external fun nativeStart(config: String): String?
    @JvmStatic external fun nativeCommand(handle: Long, json: String): String?
    @JvmStatic external fun nativeNextEvent(handle: Long, timeoutMs: Int): String?
    @JvmStatic external fun nativeStop(handle: Long)
}

/** A route as the device page shows it: lan, vpn, direct or relay, and the relay's ID. */
data class ConnectRoute(val route: String, val relay: String? = null, val vpn: String? = null)

/** What the core says about a new tunnel; the app runs the normal session over its bridge socket. */
data class TunnelInfo(
    val tunnelId: String,
    val exporter: String,
    val route: ConnectRoute,
    /** This side is the QUIC client and sends pairing.offer. */
    val quicClient: Boolean,
    /** The paired device the core dialled; null for an inbound direct dial (the handshake tells). */
    val peer: String?,
)

/** One paired device as the core needs it. */
data class ConnectPeer(val id: String, val side: Int, val pairSecret: ByteArray, val addresses: List<LearnedAddress>, val connected: Boolean)

sealed interface ConnectStatus {
    /** The setting is off (or Bridgey is off). */
    data object Off : ConnectStatus

    /** This build has no core library. */
    data object Unavailable : ConnectStatus

    /** On, with routes over learned addresses only: there is no control service in this build. */
    data object LocalOnly : ConnectStatus

    /** On, but the control service cannot be reached (no internet, or the service is down). LAN and VPN still work. */
    data object Unreachable : ConnectStatus

    data object Connecting : ConnectStatus

    /** Reachable away from home; [peersOnline] are the paired devices the control service sees. */
    data class Online(val peersOnline: Set<String>) : ConnectStatus
}

/**
 * Owns the core while "Connect away from home" is on: the node key, signatures for the control
 * service, the event thread, and the hand-off of each tunnel to [onTunnel].
 */
class ConnectAnywhere(
    private val nodeKey: ConnectNodeKey,
    private val appVersion: String,
    /** The core's own state between runs (relay round trips, the warm relay; no credentials). No backup. */
    private val stateFile: java.io.File? = null,
    /** The current network costs per byte (mobile data): no relay allocation is kept warm there. */
    private val metered: () -> Boolean = { false },
) {
    @Volatile private var handle: Long = 0
    @Volatile private var events: Thread? = null
    @Volatile var udpPort: Int = 0
        private set
    private val mutableStatus = MutableStateFlow<ConnectStatus>(ConnectStatus.Off)
    val status: StateFlow<ConnectStatus> = mutableStatus.asStateFlow()

    /** Set by the coordinator: a tunnel's bridge socket, ready for the session. */
    @Volatile var onTunnel: (Socket, TunnelInfo) -> Unit = { socket, _ -> runCatching { socket.close() } }

    /** Set by the coordinator: a tunnel moved to another path (an upgrade, or a relay after a failure). */
    @Volatile var onRoute: (tunnelId: String, route: ConnectRoute, rttMillis: Long) -> Unit = { _, _, _ -> }

    /** Set by the coordinator: a tunnel ended in the core (its QUIC connection timed out or closed). */
    @Volatile var onTunnelClosed: (tunnelId: String) -> Unit = { }

    val running: Boolean get() = handle != 0L

    /** Starts the core; [controlUrl] empty means learned addresses only. */
    @Synchronized fun start(controlUrl: String, relayOnly: Boolean): Boolean {
        if (handle != 0L) return true
        if (!ConnectCore.loaded) {
            mutableStatus.value = ConnectStatus.Unavailable
            return false
        }
        val config = JSONObject()
            .put("port", 42_458)
            .put("controlUrl", controlUrl)
            .put("app", "bridgey-rr/$appVersion android")
            .put("nodeKey", nodeKey.publicKey())
            .put("relayOnly", relayOnly)
            // A warm relay with a keep-alive every 25 s only off mobile data: there each one would wake the radio.
            .put("relayKeepaliveS", if (runCatching(metered).getOrDefault(true)) 0 else RELAY_KEEPALIVE_SECONDS)
        readState()?.let { config.put("state", it) }
        val reply = runCatching { JSONObject(ConnectCore.nativeStart(config.toString()) ?: "{}") }.getOrNull()
        if (reply?.optBoolean("ok") != true) {
            BridgeyLogging.w(LogCategory.CONNECTION, "CONNECT start failed: ${reply?.optString("error")}")
            mutableStatus.value = ConnectStatus.Unavailable
            return false
        }
        ConnectTiming.mark("app.core_started")
        handle = reply.getLong("handle")
        udpPort = reply.optInt("udpPort")
        mutableStatus.value = if (controlUrl.isEmpty()) ConnectStatus.LocalOnly else ConnectStatus.Connecting
        val current = handle
        events = Thread({ eventLoop(current) }, "bridgey-connect-events").apply {
            isDaemon = true
            start()
        }
        BridgeyLogging.i(LogCategory.CONNECTION, "CONNECT started udp=$udpPort control=${controlUrl.isNotEmpty()} relayOnly=$relayOnly")
        return true
    }

    @Synchronized fun stop() {
        val current = handle
        if (current == 0L) {
            if (mutableStatus.value !is ConnectStatus.Unavailable) mutableStatus.value = ConnectStatus.Off
            return
        }
        handle = 0
        runCatching { ConnectCore.nativeStop(current) }
        events = null
        udpPort = 0
        mutableStatus.value = ConnectStatus.Off
        BridgeyLogging.i(LogCategory.CONNECTION, "CONNECT stopped")
    }

    private fun command(json: JSONObject): JSONObject? {
        val current = handle
        if (current == 0L) return null
        return runCatching { JSONObject(ConnectCore.nativeCommand(current, json.toString()) ?: return null) }.getOrNull()
    }

    fun setPeers(peers: List<ConnectPeer>) {
        ConnectTiming.mark("app.peers", detail = "${peers.size}_${peers.count { it.connected }}")
        val list = JSONArray(peers.map { peer ->
            JSONObject()
                .put("id", peer.id)
                .put("side", peer.side)
                .put("pairSecret", Base64.getEncoder().encodeToString(peer.pairSecret))
                .put("connected", peer.connected)
                .put("addresses", JSONArray(peer.addresses.map { address ->
                    JSONObject().put("a", address.a).put("p", address.port).put("kind", address.kind).apply { address.vpn?.let { put("vpn", it) } }
                }))
        })
        command(JSONObject().put("c", "peers").put("peers", list))
    }

    /** A session on this tunnel authenticated: the core resets the peer's back-off. */
    fun tunnelAuthenticated(tunnelId: String) {
        command(JSONObject().put("c", "authenticated").put("tunnel", tunnelId))
    }

    /** Try every route to this device now (Connect on its page). */
    fun connectNow(deviceId: String) {
        command(JSONObject().put("c", "connect").put("peer", deviceId))
    }

    fun networkChanged(reason: String) {
        command(JSONObject().put("c", "network").put("reason", reason).put("metered", runCatching(metered).getOrDefault(true)))
    }

    /** Forgets the core's saved state (Reset away-from-home identity). */
    fun forgetState() {
        runCatching { stateFile?.delete() }
    }

    private fun readState(): JSONObject? = runCatching {
        stateFile?.takeIf { it.isFile && it.length() in 1..MAX_STATE_BYTES }?.readText()?.let(::JSONObject)
    }.getOrNull()

    private fun writeState(state: JSONObject) {
        val file = stateFile ?: return
        runCatching {
            val text = state.toString()
            if (text.length > MAX_STATE_BYTES) return
            val temporary = java.io.File(file.parentFile, file.name + ".tmp")
            temporary.writeText(text)
            if (!temporary.renameTo(file)) temporary.delete()
        }
    }

    fun foreground() {
        command(JSONObject().put("c", "foreground"))
    }

    fun setRelayOnly(on: Boolean) {
        command(JSONObject().put("c", "debug").put("relayOnly", on))
    }

    /** This phone's addresses for connect.addresses (LAN, VPN and global IPv6). */
    fun localAddresses(): List<ConnectAddress> {
        val reply = command(JSONObject().put("c", "addresses")) ?: return emptyList()
        val list = reply.optJSONArray("addrs") ?: return emptyList()
        return (0 until list.length()).mapNotNull { index ->
            val entry = list.optJSONObject(index) ?: return@mapNotNull null
            ConnectAddress(entry.optString("a"), entry.optString("kind"), entry.optString("vpn").takeIf { it.isNotEmpty() && it != "null" })
        }.filter { isUsableIpLiteral(it.a) }
    }

    fun status(): JSONObject? = command(JSONObject().put("c", "status"))

    private fun eventLoop(current: Long) {
        while (handle == current) {
            val text = runCatching { ConnectCore.nativeNextEvent(current, 500) }.getOrNull() ?: continue
            val event = runCatching { JSONObject(text) }.getOrNull() ?: continue
            runCatching { dispatch(event) }.onFailure { BridgeyLogging.w(LogCategory.CONNECTION, "CONNECT event failed", it) }
        }
    }

    private fun dispatch(event: JSONObject) {
        when (event.optString("e")) {
            "sign" -> {
                val data = Base64.getDecoder().decode(event.getString("data"))
                val signature = runCatching { nodeKey.sign(data) }.getOrNull()
                command(JSONObject().put("c", "sign.result").put("id", event.getLong("id")).put("sig", signature?.let { Base64.getEncoder().encodeToString(it) } ?: JSONObject.NULL))
            }
            "presence" -> {
                val peers = event.optJSONArray("peers")?.let { array -> (0 until array.length()).map(array::getString).toSet() }.orEmpty()
                mutableStatus.value = when (event.optString("state")) {
                    "online" -> ConnectStatus.Online(peers)
                    "disabled" -> ConnectStatus.LocalOnly
                    "unreachable" -> ConnectStatus.Unreachable
                    else -> ConnectStatus.Connecting
                }
            }
            "tunnel" -> openTunnel(event)
            "state" -> event.optJSONObject("state")?.let(::writeState)
            "timing" -> ConnectTiming.mark(
                "core.${event.optString("step")}",
                event.optString("peer").takeIf { it.isNotEmpty() && it != "null" },
                event.optString("detail").takeIf { it.isNotEmpty() && it != "null" },
                event.optLong("at", System.currentTimeMillis()),
            )
            "route" -> onRoute(event.getString("tunnel"), ConnectRoute(event.getString("route"), event.optString("relay").takeIf { it.isNotEmpty() && it != "null" }), event.optLong("rttMs"))
            else -> {
                // "log", the end of a tunnel and failed attempts: diagnostics, never addresses. Core event names are
                // not session message kinds, so they are read with dots as underscores (as on the Mac).
                val detail = event.optString("msg").ifEmpty { event.optString("reason") }
                BridgeyLogging.i(LogCategory.CONNECTION, "CONNECT ${event.optString("e")} $detail")
                if (event.optString("e").replace('.', '_') == "tunnel_closed") onTunnelClosed(event.optString("tunnel"))
            }
        }
    }

    private companion object {
        const val RELAY_KEEPALIVE_SECONDS = 25
        const val MAX_STATE_BYTES = 16_384L
    }

    private fun openTunnel(event: JSONObject) {
        val info = TunnelInfo(
            tunnelId = event.getString("tunnel"),
            exporter = event.getString("exporter"),
            route = ConnectRoute(
                event.getString("route"),
                event.optString("relay").takeIf { it.isNotEmpty() && it != "null" },
                event.optString("vpn").takeIf { it.isNotEmpty() && it != "null" },
            ),
            quicClient = event.getBoolean("quicClient"),
            peer = event.optString("peer").takeIf { it.isNotEmpty() && it != "null" },
        )
        val port = event.getInt("port")
        val token = event.getString("token")
        BridgeyLogging.i(LogCategory.CONNECTION, "CONNECT tunnel ${info.tunnelId} route=${info.route.route} relay=${info.route.relay} client=${info.quicClient} rttMs=${event.optLong("rttMs")}")
        Thread({
            val socket = runCatching {
                Socket().apply {
                    tcpNoDelay = true
                    connect(InetSocketAddress("127.0.0.1", port), 2_000)
                    getOutputStream().apply {
                        write("$token\n".toByteArray())
                        flush()
                    }
                }
            }.getOrNull() ?: return@Thread
            ConnectTiming.mark("app.bridge_connected", info.peer)
            onTunnel(socket, info)
        }, "bridgey-connect-bridge").apply { isDaemon = true }.start()
    }
}
