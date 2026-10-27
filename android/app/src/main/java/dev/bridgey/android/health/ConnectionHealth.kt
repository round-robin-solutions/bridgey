package dev.bridgey.android.health

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

/*
 * Connection health (docs/protocol.md, "Connection health"): how each paired device's link is
 * doing, for the device page's Connection tab and the diagnostics report. Private by design: the
 * route is a class, never the address; the device is the first eight characters of its ID; the
 * disconnect reason is a token. Nothing here goes on the wire.
 */

enum class RouteClass(val token: String) {
    /** A private LAN address (RFC 1918, link-local, IPv6 unique local or link-local, loopback). */
    SAME_NETWORK("same_network"),

    /** A private overlay network: 100.64.0.0/10 (Tailscale and other carrier-grade NAT) or Tailscale's IPv6 prefix. */
    PRIVATE_NETWORK("private_network"),
    OTHER("other"),
    UNKNOWN("unknown"),
}

/** Classifies a numeric host without resolving names. Hostnames and junk are [RouteClass.UNKNOWN]. */
fun classifyRoute(rawHost: String?): RouteClass {
    val host = rawHost?.trim()?.removePrefix("[")?.removeSuffix("]")?.substringBefore('%')?.lowercase()
    if (host.isNullOrEmpty()) return RouteClass.UNKNOWN
    ipv4(host)?.let { return classifyIpv4(it) }
    if (!host.contains(':') || host.any { !(it.isDigit() || it in 'a'..'f' || it == ':' || it == '.') }) return RouteClass.UNKNOWN
    // IPv4-mapped IPv6 (::ffff:192.168.1.4).
    if (host.startsWith("::ffff:")) ipv4(host.removePrefix("::ffff:"))?.let { return classifyIpv4(it) }
    if (host == "::1") return RouteClass.SAME_NETWORK
    val first = host.substringBefore(':').ifEmpty { "0" }.padStart(4, '0')
    if (host.startsWith("fd7a:115c:a1e0:")) return RouteClass.PRIVATE_NETWORK
    val value = first.toIntOrNull(16) ?: return RouteClass.UNKNOWN
    return when {
        (value and 0xffc0) == 0xfe80 -> RouteClass.SAME_NETWORK
        (value and 0xfe00) == 0xfc00 -> RouteClass.SAME_NETWORK
        else -> RouteClass.OTHER
    }
}

private fun ipv4(host: String): IntArray? {
    val parts = host.split('.')
    if (parts.size != 4) return null
    val bytes = parts.map { part -> if (part.isEmpty() || part.length > 3 || part.any { !it.isDigit() }) return null else part.toInt() }
    if (bytes.any { it > 255 }) return null
    return bytes.toIntArray()
}

private fun classifyIpv4(b: IntArray): RouteClass = when {
    b[0] == 10 -> RouteClass.SAME_NETWORK
    b[0] == 172 && b[1] in 16..31 -> RouteClass.SAME_NETWORK
    b[0] == 192 && b[1] == 168 -> RouteClass.SAME_NETWORK
    b[0] == 169 && b[1] == 254 -> RouteClass.SAME_NETWORK
    b[0] == 127 -> RouteClass.SAME_NETWORK
    b[0] == 100 && b[1] in 64..127 -> RouteClass.PRIVATE_NETWORK
    else -> RouteClass.OTHER
}

/** A diagnostics-style token: lower case letters, digits, `_`, `.` and `-`, at most 64; anything like an IPv4 address becomes `addr`. */
internal fun healthToken(value: String): String = value.lowercase()
    .replace(Regex("[0-9]{1,3}(\\.[0-9]{1,3}){3}"), "addr")
    .replace(Regex("[^a-z0-9_.-]"), "_")
    .take(64)

/** One device's health right now. Only classes, tokens, times and counts. */
data class DeviceHealth(
    /** The first eight characters of the device ID. */
    val device: String,
    val connected: Boolean,
    val route: RouteClass,
    /** True when this phone dialled; null when not connected. */
    val dialledHere: Boolean?,
    val connectedSinceMillis: Long?,
    val lastRttMillis: Long?,
    val medianRttMillis: Long?,
    val rttSamples: Int,
    val lastDisconnectReason: String?,
    val lastDisconnectAtMillis: Long?,
    val reconnectAttemptsToday: Int,
    val discoverySeesNow: Boolean,
    /** Phone only: Bridgey is exempt from battery optimisation. */
    val batteryOptimisationExempt: Boolean?,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("device", device)
        put("connected", connected)
        put("route", route.token)
        dialledHere?.let { put("dialledBy", if (it) "this_device" else "other_device") }
        connectedSinceMillis?.let { put("connectedSince", Instant.ofEpochMilli(it).toString()) }
        lastRttMillis?.let { put("lastRttMs", it) }
        medianRttMillis?.let { put("medianRttMs", it) }
        put("rttSamples", rttSamples)
        lastDisconnectReason?.let { put("lastDisconnectReason", it) }
        lastDisconnectAtMillis?.let { put("lastDisconnectAt", Instant.ofEpochMilli(it).toString()) }
        put("reconnectAttemptsToday", reconnectAttemptsToday)
        put("discoverySeesNow", discoverySeesNow)
        batteryOptimisationExempt?.let { put("batteryOptimisationExempt", it) }
    }
}

/** The median of [samples] (the lower middle for an even count), or null. */
internal fun medianOf(samples: Collection<Long>): Long? {
    if (samples.isEmpty()) return null
    val sorted = samples.sorted()
    return sorted[(sorted.size - 1) / 2]
}

/**
 * Health facts for every device, kept in memory (a restart starts a new day count). Thread safe.
 * [changes] ticks whenever something shown changes, so the tab can redraw.
 */
class ConnectionHealthBook(
    private val zone: () -> ZoneId = ZoneId::systemDefault,
) {
    private class Facts {
        var connected = false
        var route = RouteClass.UNKNOWN
        var dialledHere: Boolean? = null
        var connectedSince: Long? = null
        val pings = LinkedHashMap<String, Long>()
        val rtts = ArrayDeque<Long>()
        var lastDisconnectReason: String? = null
        var lastDisconnectAt: Long? = null
        var attemptsDay: LocalDate? = null
        var attempts = 0
    }

    private val facts = HashMap<String, Facts>()
    private val mutableChanges = MutableStateFlow(0L)
    val changes: StateFlow<Long> = mutableChanges.asStateFlow()

    private fun of(deviceId: String) = facts.getOrPut(deviceId, ::Facts)
    private fun changed() { mutableChanges.value = mutableChanges.value + 1 }

    /** [deviceId] authenticated; [host] is used only to pick the route class and is not kept. */
    @Synchronized fun connected(deviceId: String, host: String?, dialledHere: Boolean, wallMillis: Long) {
        of(deviceId).apply {
            connected = true
            route = classifyRoute(host)
            this.dialledHere = dialledHere
            connectedSince = wallMillis
            pings.clear()
            rtts.clear()
        }
        changed()
    }

    @Synchronized fun disconnected(deviceId: String, reason: String, wallMillis: Long) {
        of(deviceId).apply {
            connected = false
            dialledHere = null
            connectedSince = null
            pings.clear()
            lastDisconnectReason = healthToken(reason)
            lastDisconnectAt = wallMillis
        }
        changed()
    }

    /** A reconnect dial to [deviceId] started. */
    @Synchronized fun dialAttempt(deviceId: String, wallMillis: Long) {
        of(deviceId).apply {
            val today = Instant.ofEpochMilli(wallMillis).atZone(zone()).toLocalDate()
            if (attemptsDay != today) {
                attemptsDay = today
                attempts = 0
            }
            attempts += 1
        }
        changed()
    }

    @Synchronized fun heartbeatSent(deviceId: String, messageId: String, elapsedMillis: Long) {
        val pings = of(deviceId).pings
        pings[messageId] = elapsedMillis
        while (pings.size > MAX_PENDING_PINGS) pings.remove(pings.keys.first())
    }

    /** A `heartbeat.pong` echoing [messageId]; one we did not send is ignored. */
    @Synchronized fun heartbeatAnswered(deviceId: String, messageId: String?, elapsedMillis: Long) {
        val entry = facts[deviceId] ?: return
        val sentAt = messageId?.let(entry.pings::remove) ?: return
        val rtt = (elapsedMillis - sentAt).coerceAtLeast(0)
        entry.rtts.addLast(rtt)
        while (entry.rtts.size > RTT_SAMPLES) entry.rtts.removeFirst()
        changed()
    }

    @Synchronized fun forget(deviceId: String) {
        facts.remove(deviceId)
        changed()
    }

    @Synchronized fun snapshot(deviceId: String, discoverySeesNow: Boolean, batteryOptimisationExempt: Boolean?, nowMillis: Long): DeviceHealth {
        val entry = facts[deviceId]
        val today = Instant.ofEpochMilli(nowMillis).atZone(zone()).toLocalDate()
        return DeviceHealth(
            device = healthToken(deviceId.take(8)),
            connected = entry?.connected == true,
            route = if (entry?.connected == true) entry.route else RouteClass.UNKNOWN,
            dialledHere = entry?.dialledHere,
            connectedSinceMillis = entry?.connectedSince,
            lastRttMillis = entry?.rtts?.lastOrNull(),
            medianRttMillis = entry?.rtts?.let(::medianOf),
            rttSamples = entry?.rtts?.size ?: 0,
            lastDisconnectReason = entry?.lastDisconnectReason,
            lastDisconnectAtMillis = entry?.lastDisconnectAt,
            reconnectAttemptsToday = if (entry?.attemptsDay == today) entry.attempts else 0,
            discoverySeesNow = discoverySeesNow,
            batteryOptimisationExempt = batteryOptimisationExempt,
        )
    }

    companion object {
        const val RTT_SAMPLES = 10
        const val MAX_PENDING_PINGS = 8
    }
}
