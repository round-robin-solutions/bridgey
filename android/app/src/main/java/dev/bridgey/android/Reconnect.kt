package dev.bridgey.android

import org.json.JSONArray
import org.json.JSONObject

/*
 * Reconnecting to trusted devices without relying on NSD alone. Pure Kotlin, unit tested on the
 * JVM: the policy (every knob in one place), the per-device address book, the retry schedule,
 * the event debouncer, the on-link check and the engine that drives dials. Mirrors
 * macos/Sources/BridgeyMac/Reconnect.swift and ReconnectEngine.swift. The trade-offs behind
 * each value are in docs/reconnect-reliability.md.
 */

object ReconnectPolicy {
    /** Delays between attempts after a drop. The last repeats for the rest of the fast phase. */
    val FAST_DELAYS_MILLIS = longArrayOf(2_000, 5_000, 15_000, 30_000, 60_000)

    /** How long the fast delays apply after a drop, a network change, Doze exit, screen on or a manual retry. */
    const val FAST_PHASE_MILLIS = 3_600_000L

    /** After the fast phase the device has been away for a while: one attempt every 10 minutes. */
    const val SLOW_DELAY_MILLIS = 600_000L

    /** After this many failed attempts the device shows "Can't reach" rather than "Reconnecting". */
    const val STRUGGLING_AFTER_ATTEMPTS = 4

    /** NSD restarts (re-register and browse again) this often while a trusted device is away... */
    const val DISCOVERY_RESTART_INTERVAL_MILLIS = 300_000L

    /** ...for this long after it went away (or after the last network event). Then only events and the manual action restart it. */
    const val DISCOVERY_RESTART_WINDOW_MILLIS = 3_600_000L

    /** Network, Doze and screen events this close together collapse into one recovery... */
    const val EVENT_QUIET_MILLIS = 2_000L

    /** ...which still runs this long after the first event of a long burst. */
    const val EVENT_MAX_WAIT_MILLIS = 10_000L

    /** Event-driven NSD restarts are at least this far apart, so a flapping Wi-Fi cannot cause a storm. */
    const val EVENT_RESTART_SPACING_MILLIS = 30_000L

    /** A reconnect dial that has not connected by then is abandoned; the schedule tries again. */
    const val CONNECT_TIMEOUT_MILLIS = 8_000

    /** Addresses remembered per device. */
    const val ADDRESSES_PER_DEVICE = 4

    /** "Look for devices again" waits this long for devices to answer before reporting. */
    const val REDISCOVER_WINDOW_MILLIS = 10_000L

    /** Heartbeat: a ping every 10 s; a link silent for 30 s is dead. */
    const val HEARTBEAT_INTERVAL_MILLIS = 10_000L
    const val HEARTBEAT_TIMEOUT_MILLIS = 30_000L

    /** Bridgey's listening port. Inbound connections come from a random port, so their address is stored with this one. */
    const val LISTENING_PORT = 42_458

    fun delayMillis(attempts: Int, elapsedMillis: Long): Long =
        if (elapsedMillis >= FAST_PHASE_MILLIS) SLOW_DELAY_MILLIS
        else FAST_DELAYS_MILLIS[attempts.coerceIn(0, FAST_DELAYS_MILLIS.lastIndex)]
}

// region Address book

enum class AddressSource(val key: String) {
    /** Seen in NSD: an untrusted hint until a connection there authenticates. */
    DISCOVERY("discovery"),

    /** This phone dialled the device there and the connection authenticated. */
    OUTBOUND("outbound"),

    /** The device connected from there and the connection authenticated. */
    INBOUND("inbound"),
    ;

    val authenticated: Boolean get() = this != DISCOVERY

    companion object {
        fun of(key: String?): AddressSource? = entries.firstOrNull { it.key == key }
    }
}

data class KnownAddress(val host: String, val port: Int, val source: AddressSource, val lastSeenMillis: Long)

data class DeviceAddressRecord(
    /** Most recent first. */
    val addresses: List<KnownAddress> = emptyList(),
    /** Wall-clock time the device was last connected: when its link dropped, or the latest heartbeat. */
    val lastConnectedAtMillis: Long? = null,
)

interface AddressBookStore {
    fun load(): String?
    fun save(value: String)
}

/**
 * Where each trusted device was last reachable, learned from NSD, from this phone's own dials and
 * from the remote end of connections the device made to this phone. Persisted, so a restart of
 * either app still knows where to look.
 */
class KnownAddressBook(private val store: AddressBookStore, limit: Int = ReconnectPolicy.ADDRESSES_PER_DEVICE) {
    private val limit = limit.coerceAtLeast(1)
    private val records = HashMap<String, DeviceAddressRecord>()
    private val persistedSeen = HashMap<String, Long>()

    init {
        runCatching { store.load()?.let(::decode)?.let(records::putAll) }
    }

    /** Remembers that [deviceId] was at [rawHost]. Returns false for a host that is not an address. */
    @Synchronized fun learn(deviceId: String, rawHost: String, port: Int, source: AddressSource, atMillis: Long): Boolean {
        val host = normalizedHost(rawHost) ?: return false
        if (port !in 1..65_535) return false
        val record = records[deviceId] ?: DeviceAddressRecord()
        val existing = record.addresses.firstOrNull { it.host == host }
        val entry = KnownAddress(
            host = host,
            port = port,
            // A discovery sighting never downgrades an address that authenticated.
            source = if (existing != null && !source.authenticated && existing.source.authenticated) existing.source else source,
            lastSeenMillis = maxOf(existing?.lastSeenMillis ?: atMillis, atMillis),
        )
        records[deviceId] = record.copy(addresses = trimmed(listOf(entry) + record.addresses.filter { it.host != host }))
        persist()
        return true
    }

    /** Most recent first. */
    @Synchronized fun addresses(deviceId: String): List<KnownAddress> =
        records[deviceId]?.addresses.orEmpty().sortedByDescending { it.lastSeenMillis }

    @Synchronized fun lastConnected(deviceId: String): Long? = records[deviceId]?.lastConnectedAtMillis

    /**
     * The link is up now, or just dropped: either way the device was last seen at [atMillis]. With
     * [persistAfterMillis], a heartbeat's update is written only when the stored time is older.
     */
    @Synchronized fun markSeen(deviceId: String, atMillis: Long, persistAfterMillis: Long = 0) {
        records[deviceId] = (records[deviceId] ?: DeviceAddressRecord()).copy(lastConnectedAtMillis = atMillis)
        val written = persistedSeen[deviceId]
        if (persistAfterMillis > 0 && written != null && atMillis - written < persistAfterMillis) return
        persistedSeen[deviceId] = atMillis
        persist()
    }

    @Synchronized fun forget(deviceId: String) {
        if (records.remove(deviceId) != null) persist()
    }

    /** Drops records of devices that are no longer trusted. */
    @Synchronized fun retain(deviceIds: Set<String>) {
        if (records.keys.retainAll(deviceIds)) persist()
    }

    /** Keeps the newest [limit], but discovery hints never push out the newest authenticated address. */
    private fun trimmed(addresses: List<KnownAddress>): List<KnownAddress> {
        val sorted = addresses.sortedByDescending { it.lastSeenMillis }
        if (sorted.size <= limit) return sorted
        val kept = sorted.take(limit).toMutableList()
        if (kept.none { it.source.authenticated }) {
            sorted.firstOrNull { it.source.authenticated }?.let { kept[kept.lastIndex] = it }
        }
        return kept
    }

    private fun persist() {
        runCatching { store.save(encode()) }
    }

    private fun encode(): String = JSONObject().apply {
        records.forEach { (id, record) ->
            put(id, JSONObject().apply {
                record.lastConnectedAtMillis?.let { put("lastConnectedAt", it) }
                put("addresses", JSONArray().apply {
                    record.addresses.forEach { address ->
                        put(JSONObject().apply {
                            put("host", address.host)
                            put("port", address.port)
                            put("source", address.source.key)
                            put("lastSeen", address.lastSeenMillis)
                        })
                    }
                })
            })
        }
    }.toString()

    private fun decode(value: String): Map<String, DeviceAddressRecord> {
        val root = JSONObject(value)
        return root.keys().asSequence().associateWith { id ->
            val item = root.getJSONObject(id)
            val array = item.optJSONArray("addresses") ?: JSONArray()
            DeviceAddressRecord(
                addresses = (0 until array.length()).mapNotNull { index ->
                    val address = array.getJSONObject(index)
                    val host = normalizedHost(address.optString("host")) ?: return@mapNotNull null
                    val source = AddressSource.of(address.optString("source")) ?: return@mapNotNull null
                    KnownAddress(host, address.optInt("port", ReconnectPolicy.LISTENING_PORT), source, address.optLong("lastSeen"))
                },
                lastConnectedAtMillis = if (item.has("lastConnectedAt")) item.getLong("lastConnectedAt") else null,
            )
        }
    }
}

/** An IP literal (IPv4-mapped IPv6 unwrapped) or a `.local` host name; null for anything else. */
fun normalizedHost(raw: String?): String? {
    var host = raw?.trim() ?: return null
    if (host.startsWith("[") && host.endsWith("]")) host = host.substring(1, host.length - 1)
    host = host.substringBefore('%')
    if (host.startsWith("::ffff:", ignoreCase = true) && parseIPv4(host.substring(7)) != null) host = host.substring(7)
    if (host.isEmpty() || host.length > 253) return null
    if (parseIPv4(host) != null) return host
    if (isIPv6Literal(host)) return host.lowercase().takeUnless { it.startsWith("fe80") }
    val name = host.removeSuffix(".")
    return name.takeIf { it.endsWith(".local", ignoreCase = true) && it.all { c -> c.isLetterOrDigit() || c == '-' || c == '.' } }
}

/** A short, non-identifying tag for logs: the address family and the last IPv4 octet. */
fun addressTag(host: String): String = when {
    parseIPv4(host) != null -> "v4.${host.substringAfterLast('.')}"
    isIPv6Literal(host) -> "v6"
    else -> "name"
}

/** A dotted-quad IPv4 literal as an unsigned 32-bit value, without any DNS lookup. */
fun parseIPv4(text: String): Long? {
    val parts = text.split('.')
    if (parts.size != 4) return null
    var value = 0L
    for (part in parts) {
        if (part.isEmpty() || part.length > 3 || !part.all(Char::isDigit)) return null
        val octet = part.toInt()
        if (octet > 255) return null
        value = (value shl 8) or octet.toLong()
    }
    return value
}

private fun isIPv6Literal(text: String): Boolean =
    text.count { it == ':' } >= 2 && text.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' || it == ':' || it == '.' }

// endregion

// region On-link check

/** One IPv4 network this phone is on. */
data class LocalIPv4Network(val address: Long, val prefixLength: Int) {
    private val mask: Long get() = if (prefixLength <= 0) 0L else (0xFFFF_FFFFL shl (32 - prefixLength.coerceAtMost(32))) and 0xFFFF_FFFFL

    fun contains(other: Long): Boolean = (other and mask) == (address and mask)
}

/**
 * Only addresses on a network this phone is on are dialled: on mobile data or another Wi-Fi, the
 * old home address is unreachable or someone else's, and dialling it would wake the radio for
 * nothing. IPv6 and `.local` names are dialled whenever a local network is up.
 */
fun isDialable(host: String, networks: List<LocalIPv4Network>): Boolean {
    if (networks.isEmpty()) return false
    val value = parseIPv4(host) ?: return true
    return networks.any { it.contains(value) }
}

// endregion

// region Schedule

/** One trusted device's reconnect episode. Times are on the monotonic clock. */
data class ReconnectEntry(val attempts: Int, val phaseStartMillis: Long, val nextAtMillis: Long)

/**
 * Per device: when to try next. A drop starts an episode; each attempt pushes the next one out
 * along [ReconnectPolicy]; a network change, Doze exit, screen on, NSD seeing the device or
 * "Retry now" resets it to "now" with a fresh fast phase; connecting ends it. Not thread-safe:
 * the engine guards it.
 */
class ReconnectSchedule(private val delayFor: (Int, Long) -> Long = ReconnectPolicy::delayMillis) {
    private val entries = HashMap<String, ReconnectEntry>()

    fun entry(id: String): ReconnectEntry? = entries[id]

    fun ids(): Set<String> = entries.keys.toSet()

    fun disconnected(id: String, nowMillis: Long) {
        if (id in entries) return
        entries[id] = ReconnectEntry(0, nowMillis, nowMillis + delayFor(0, 0))
    }

    fun connected(id: String) {
        entries.remove(id)
    }

    fun reset(id: String, nowMillis: Long) {
        entries[id] = ReconnectEntry(0, nowMillis, nowMillis)
    }

    fun resetAll(nowMillis: Long) = entries.keys.toList().forEach { reset(it, nowMillis) }

    fun due(nowMillis: Long): List<String> = entries.filterValues { it.nextAtMillis <= nowMillis }.keys.sorted()

    /** An attempt for [id] starts now. Returns its number in the episode, from 1. */
    fun attemptStarted(id: String, nowMillis: Long): Int {
        val entry = entries[id] ?: ReconnectEntry(0, nowMillis, nowMillis)
        val attempts = entry.attempts + 1
        entries[id] = entry.copy(attempts = attempts, nextAtMillis = nowMillis + delayFor(attempts, nowMillis - entry.phaseStartMillis))
        return attempts
    }

    fun nextDue(exclude: (String) -> Boolean): Long? = entries.filterKeys { !exclude(it) }.values.minOfOrNull { it.nextAtMillis }
}

// endregion

// region Clock and debounce

fun interface ScheduledTask {
    fun cancel()
}

/** The clocks and timer the reconnect logic runs on; tests use a manual one. */
interface ReconnectClock {
    /** Monotonic, counting deep sleep (SystemClock.elapsedRealtime on Android). */
    fun elapsedMillis(): Long

    /** Wall clock, for "last seen". */
    fun wallMillis(): Long

    fun schedule(delayMillis: Long, action: () -> Unit): ScheduledTask
}

/**
 * Collapses a burst of events (Wi-Fi returning brings onAvailable, several link property changes
 * and a Doze exit) into one call with every reason: it fires once nothing new arrived for
 * [quietMillis], and at the latest [maxWaitMillis] after the burst's first event.
 */
class EventDebouncer(
    private val clock: ReconnectClock,
    private val quietMillis: Long = ReconnectPolicy.EVENT_QUIET_MILLIS,
    private val maxWaitMillis: Long = ReconnectPolicy.EVENT_MAX_WAIT_MILLIS,
    private val fire: (List<String>) -> Unit,
) {
    private val reasons = LinkedHashSet<String>()
    private var burstStart: Long? = null
    private var pending: ScheduledTask? = null

    @Synchronized fun note(reason: String) {
        val now = clock.elapsedMillis()
        reasons += reason
        val start = burstStart ?: now
        burstStart = start
        pending?.cancel()
        val deadline = minOf(now + quietMillis, start + maxWaitMillis)
        pending = clock.schedule(deadline - now) { flush() }
    }

    private fun flush() {
        val fired = synchronized(this) {
            val list = reasons.toList()
            reasons.clear()
            burstStart = null
            pending = null
            list
        }
        if (fired.isNotEmpty()) fire(fired)
    }
}

// endregion

// region Engine

/** What the engine did, for logs and diagnostics. */
sealed interface ReconnectEvent {
    data class Dial(val deviceId: String, val address: KnownAddress, val attempt: Int, val reason: String) : ReconnectEvent

    /** Nothing to dial on this network. Reported for the first attempt and every tenth. */
    data class NoAddress(val deviceId: String, val attempt: Int, val reason: String) : ReconnectEvent
    data class FoundByDiscovery(val deviceId: String, val addresses: Int) : ReconnectEvent
}

/** A trusted device that is not connected while both apps keep trying to reach it. */
data class ReconnectDisplay(
    /** Wall-clock time it was last connected. */
    val lastSeenMillis: Long?,
    /** Several attempts failed: "Can't reach" rather than "Reconnecting". */
    val struggling: Boolean,
)

/** What NSD shows for one trusted device right now. */
data class LivePeer(val deviceId: String, val addresses: List<String>, val port: Int)

/**
 * Keeps dialling trusted devices that are not connected, at every address they are known at, on
 * [ReconnectPolicy]'s schedule, whichever side dialled before: both apps run one, and the session
 * registry keeps a single socket when both dial at once. Thread-safe. The coordinator owns the
 * sockets and reports connects, drops and dial results here.
 */
class ReconnectEngine(
    val addressBook: KnownAddressBook,
    private val clock: ReconnectClock,
    delayFor: (Int, Long) -> Long = ReconnectPolicy::delayMillis,
) {
    private val schedule = ReconnectSchedule(delayFor)
    @Volatile var networks: () -> List<LocalIPv4Network> = { emptyList() }
    @Volatile var isTrusted: (String) -> Boolean = { false }
    @Volatile var isConnected: (String) -> Boolean = { false }

    /** Opens a connection to the device at the address; the coordinator calls [dialEnded] when it authenticates or fails. */
    @Volatile var dial: (String, KnownAddress) -> Unit = { _, _ -> }
    @Volatile var onEvent: (ReconnectEvent) -> Unit = {}

    /** The schedule changed: the UI's reconnect state may have too. Called outside the engine's lock. */
    @Volatile var onChange: () -> Unit = {}
    private var livePeers: List<LivePeer> = emptyList()
    private val dialing = HashMap<String, Int>()
    private var timer: ScheduledTask? = null

    /** The device's link dropped. [seenNow] is false at launch, where it was last seen whenever the book says. */
    fun disconnected(id: String, seenNow: Boolean = true) {
        if (!isTrusted(id)) return
        if (seenNow) addressBook.markSeen(id, clock.wallMillis())
        synchronized(this) {
            schedule.disconnected(id, clock.elapsedMillis())
            armLocked()
        }
        onChange()
    }

    /** A heartbeat: "last seen" stays current even if the app is killed. */
    fun stillConnected(id: String) = addressBook.markSeen(id, clock.wallMillis(), persistAfterMillis = 60_000)

    /** The device authenticated over a connection with [host] at its other end. */
    fun connected(id: String, host: String?, port: Int, source: AddressSource) {
        val now = clock.wallMillis()
        if (host != null) addressBook.learn(id, host, port, source, now)
        addressBook.markSeen(id, now)
        synchronized(this) {
            schedule.connected(id)
            armLocked()
        }
        onChange()
    }

    fun dialEnded(id: String) {
        synchronized(this) {
            dialing[id] = ((dialing[id] ?: 1) - 1).coerceAtLeast(0)
            armLocked()
        }
        onChange()
    }

    @Synchronized fun isDialing(id: String): Boolean = (dialing[id] ?: 0) > 0

    fun forget(id: String) {
        addressBook.forget(id)
        synchronized(this) {
            schedule.connected(id)
            armLocked()
        }
        onChange()
    }

    /** NSD's current view. Trusted devices in it are remembered; one that is not connected and just appeared (or moved) is tried now. */
    fun discoveryChanged(peers: List<LivePeer>) {
        val now = clock.wallMillis()
        synchronized(this) {
            val previous = livePeers
            livePeers = peers
            peers.forEach { peer ->
                if (!isTrusted(peer.deviceId)) return@forEach
                peer.addresses.forEach { addressBook.learn(peer.deviceId, it, peer.port, AddressSource.DISCOVERY, now) }
                if (isConnected(peer.deviceId)) return@forEach
                val before = previous.firstOrNull { it.deviceId == peer.deviceId }
                if (before == null || before.addresses != peer.addresses || before.port != peer.port) {
                    onEvent(ReconnectEvent.FoundByDiscovery(peer.deviceId, peer.addresses.size))
                    schedule.reset(peer.deviceId, clock.elapsedMillis())
                }
            }
            armLocked()
        }
        onChange()
    }

    /** A network change, Doze exit or screen on: every listed device is tried now, with the fast delays again. */
    fun resetAll(ids: Collection<String>) {
        synchronized(this) {
            val now = clock.elapsedMillis()
            ids.filter { isTrusted(it) && !isConnected(it) }.forEach { schedule.reset(it, now) }
            armLocked()
        }
        onChange()
    }

    /** "Retry now" and "Look for devices again": dial every known address at once. */
    fun dialEverywhere(id: String, reason: String) {
        if (!isTrusted(id) || isConnected(id)) return
        synchronized(this) {
            val now = clock.elapsedMillis()
            schedule.reset(id, now)
            val attempt = schedule.attemptStarted(id, now)
            val candidates = candidatesLocked(id)
            if (candidates.isEmpty()) onEvent(ReconnectEvent.NoAddress(id, attempt, reason))
            candidates.forEach { startDialLocked(id, it, attempt, reason) }
            armLocked()
        }
        onChange()
    }

    fun display(id: String): ReconnectDisplay? {
        if (!isTrusted(id) || isConnected(id)) return null
        val attempts = synchronized(this) { schedule.entry(id)?.attempts ?: 0 }
        return ReconnectDisplay(addressBook.lastConnected(id), attempts >= ReconnectPolicy.STRUGGLING_AFTER_ATTEMPTS)
    }

    @Synchronized fun entry(id: String): ReconnectEntry? = schedule.entry(id)

    @Synchronized fun candidates(id: String): List<KnownAddress> = candidatesLocked(id)

    private fun candidatesLocked(id: String): List<KnownAddress> {
        val now = clock.wallMillis()
        val live = livePeers.firstOrNull { it.deviceId == id }
            ?.let { peer -> peer.addresses.mapNotNull { host -> normalizedHost(host)?.let { KnownAddress(it, peer.port, AddressSource.DISCOVERY, now) } } }
            .orEmpty()
        // NSD just saw the live addresses on a local network, so they are always worth a try; the
        // remembered ones only on a network this phone is on now.
        val networks = networks()
        val seen = HashSet<String>()
        return live.filter { seen.add(it.host) } + addressBook.addresses(id).filter { seen.add(it.host) && isDialable(it.host, networks) }
    }

    /** One timer for every device: it fires at the earliest due attempt of a device with no dial in flight. */
    private fun armLocked() {
        timer?.cancel()
        timer = null
        val next = schedule.nextDue(exclude = { (dialing[it] ?: 0) > 0 }) ?: return
        timer = clock.schedule((next - clock.elapsedMillis()).coerceAtLeast(0)) { runDue() }
    }

    private fun runDue() {
        synchronized(this) {
            timer = null
            val now = clock.elapsedMillis()
            schedule.due(now).filter { (dialing[it] ?: 0) == 0 }.forEach { id ->
                if (!isTrusted(id) || isConnected(id)) {
                    schedule.connected(id)
                    return@forEach
                }
                val attempt = schedule.attemptStarted(id, now)
                val candidates = candidatesLocked(id)
                if (candidates.isEmpty()) {
                    // Nothing to dial here; NSD, a network change or the user brings it forward.
                    if (attempt == 1 || attempt % 10 == 0) onEvent(ReconnectEvent.NoAddress(id, attempt, "backoff"))
                    return@forEach
                }
                // Successive attempts rotate through the addresses, newest first.
                startDialLocked(id, candidates[(attempt - 1) % candidates.size], attempt, "backoff")
            }
            armLocked()
        }
        onChange()
    }

    private fun startDialLocked(id: String, address: KnownAddress, attempt: Int, reason: String) {
        dialing[id] = (dialing[id] ?: 0) + 1
        onEvent(ReconnectEvent.Dial(id, address, attempt, reason))
        dial(id, address)
    }
}

// endregion
