package dev.bridgey.android

/*
 * LAN first (draft lan_first_draft1, docs/protocol.md "LAN first" under Connect anywhere): a session on the local
 * network replaces a tunnel or VPN session for the same device, no switch ever cancels a transfer, and a device
 * that is connected some other way keeps trying its LAN address. Pure Kotlin, unit tested on the JVM: the tier
 * classifier, the duplicate rule, the active-transfer check, the upgrade candidates and the upgrade loop. The Mac
 * implements the same rules; both ends run the duplicate rule on their own, so they must match.
 */

/** Advertised in features.update by builds with LAN first; a capability, so always true. */
internal const val LAN_FIRST_FEATURE_KEY = "lan_first_draft1"

/**
 * Advertised beside [LAN_FIRST_FEATURE_KEY] by builds that remember it: such a build keeps, per trusted device, whether
 * that device advertised this key ([lanFirstRemembered]) and runs the LAN first rule with a remembered device from the
 * first moment of a session, before its features.update arrives. Builds from 1.0 Beta 2 to 4 never advertise it, so they
 * are never remembered and get the rule exactly as they run it. Read outside the draft list, like the first key.
 */
internal const val LAN_FIRST_DRAFT2_FEATURE_KEY = "lan_first_draft2"

/** What to remember for a device from its features.update: both keys, so only a build that remembers this one too. */
internal fun lanFirstRemembered(draft1: Boolean, draft2: Boolean): Boolean = draft1 && draft2

/** How good a session's path is. Both ends see the same addresses, so both rank a session alike. */
internal enum class SessionTier(val rank: Int, val wire: String) {
    /** A Connect anywhere tunnel, whatever its route: the two ends can label one tunnel differently. */
    TUNNEL(0, "tunnel"),

    /** A socket session over Tailscale, another VPN or a public address. */
    SOCKET(1, "socket"),

    /** A socket session to a private, link-local or loopback address. */
    LAN(2, "lan"),
}

/** The tier of a session: [tunnel] for a Connect anywhere tunnel, else from the socket's remote address. */
internal fun sessionTier(tunnel: Boolean, remoteAddress: String?): SessionTier = when {
    tunnel -> SessionTier.TUNNEL
    remoteAddress != null && isLanAddress(remoteAddress) -> SessionTier.LAN
    else -> SessionTier.SOCKET
}

/**
 * A private address: IPv4 10/8, 172.16/12, 192.168/16, 169.254/16 and loopback; IPv6 fe80::/10, fc00::/7
 * (except Tailscale's fd7a:115c:a1e0::/48) and ::1. IPv4-mapped IPv6 is judged by its IPv4. Brackets and a
 * zone (`%wlan0`) are ignored. Tailscale's 100.64/10 and public addresses are not LAN.
 */
internal fun isLanAddress(raw: String): Boolean {
    val host = raw.trim().removePrefix("[").removeSuffix("]").substringBefore('%')
    parseIPv4(host)?.let { return isLanIPv4(it) }
    val groups = dev.bridgey.android.connect.parseIPv6Literal(host) ?: return false
    if (groups.take(5).all { it == 0 } && groups[5] == 0xffff) return isLanIPv4((groups[6].toLong() shl 16) or groups[7].toLong())
    if (groups.take(7).all { it == 0 } && groups[7] == 1) return true
    if ((groups[0] and 0xffc0) == 0xfe80) return true
    if (groups[0] == 0xfd7a && groups[1] == 0x115c && groups[2] == 0xa1e0) return false
    return (groups[0] and 0xfe00) == 0xfc00
}

private fun isLanIPv4(value: Long): Boolean {
    val a = (value shr 24) and 0xff
    val b = (value shr 16) and 0xff
    return a == 10L || a == 127L || (a == 172L && b in 16L..31L) || (a == 192L && b == 168L) || (a == 169L && b == 254L)
}

/**
 * Ranges that belong to virtual interfaces on a Mac (OrbStack's 192.168.139.0/24 and 192.168.215.0/24, seen
 * live): never advertised in connect.addresses and never dialled for a LAN upgrade. Interface names (bridge,
 * vmnet, utun, docker) are filtered where the addresses are read, in the Connect anywhere core.
 */
internal fun isVirtualInterfaceAddress(host: String): Boolean {
    val value = parseIPv4(host) ?: return false
    return VIRTUAL_IPV4_NETWORKS.any { it.contains(value) }
}

private val VIRTUAL_IPV4_NETWORKS = listOf("192.168.139.0", "192.168.215.0").map { LocalIPv4Network(parseIPv4(it)!!, 24) }

// region Duplicate rule

/** How a second session for one device was settled ([SessionRegistry.authenticate]); [detail] goes to diagnostics. */
internal enum class DuplicateVerdict(val newWins: Boolean, val detail: String?) {
    /** The live session had gone silent: the new one wins whoever dialled it. */
    STALE(true, "stale"),

    /** The socket dialled by the lower device ID wins, the newer one if that side dialled both. */
    DIALLED_NEW(true, null),
    DIALLED_EXISTING(false, null),

    /** LAN first: the live session carries a transfer, so the new one closes quietly. */
    TRANSFER(false, "transfer"),

    /** LAN first: the session with the higher tier wins. */
    TIER_NEW(true, "tier"),
    TIER_EXISTING(false, "tier"),
}

/**
 * The duplicate rule, applied identically on the phone and the Mac (both ends must keep the same session):
 * 1. the live session is stale: the new one wins;
 * 2. the peer did not advertise lan_first_draft1 on the live session ([peerLanFirst]) and is not remembered for
 *    lan_first_draft2 ([peerRemembered]): the rule older builds apply, the lower dialler;
 * 3. the live session carries a transfer: the new one is rejected, whatever its tier;
 * 4. the higher tier wins; equal tiers fall back to the lower dialler.
 * Rule 2 sits before the transfer check so a peer without the key gets exactly the old answer: it cannot see this
 * device's transfers, and two ends that disagree close both sessions. [peerRemembered] covers a live session whose
 * features.update has not arrived yet; the peer remembers this device too, so it runs the same rule at that moment.
 */
internal fun duplicateVerdict(
    existingStale: Boolean,
    peerLanFirst: Boolean,
    peerRemembered: Boolean,
    activeTransfer: Boolean,
    candidateTier: SessionTier,
    existingTier: SessionTier,
    candidateDialledByLower: Boolean,
    existingDialledByLower: Boolean,
): DuplicateVerdict {
    fun dialled() = if (candidateDialledByLower == existingDialledByLower || candidateDialledByLower) {
        DuplicateVerdict.DIALLED_NEW
    } else {
        DuplicateVerdict.DIALLED_EXISTING
    }
    return when {
        existingStale -> DuplicateVerdict.STALE
        !peerLanFirst && !peerRemembered -> dialled()
        activeTransfer -> DuplicateVerdict.TRANSFER
        candidateTier.rank > existingTier.rank -> DuplicateVerdict.TIER_NEW
        candidateTier.rank < existingTier.rank -> DuplicateVerdict.TIER_EXISTING
        else -> dialled()
    }
}

// endregion

// region Active transfer

/**
 * Whether this device has something running with a peer that a session switch would cut: a file transfer that was
 * offered and has not finished, a folder being sent or received (Phone files downloads are folder sends), a clipboard
 * push or paste fetch, or a speed test. Files and folders still waiting in a queue do not count: the peer has not
 * heard of them, and both ends must reach the same answer. [folders] answers for folder sessions, so folder rows in
 * [rows] are not read.
 */
internal class TransferActivity(
    private val rows: () -> Collection<FileTransferState>,
    private val rowDevice: (String) -> String?,
    private val folders: (String) -> Boolean,
    private val clipboard: (String) -> Boolean,
    private val speedTest: (String) -> Boolean,
) {
    fun hasActiveTransfer(deviceId: String): Boolean =
        rows().any { it.kind == TransferKind.FILE && it.active && !it.queued && (rowDevice(it.id) ?: it.deviceId) == deviceId } ||
            folders(deviceId) || clipboard(deviceId) || speedTest(deviceId)
}

// endregion

// region Upgrade candidates

/** A LAN address to dial for an upgrade: [origin] is `nsd` (seen on this network now) or `learned` (connect.addresses). */
internal data class LanCandidate(val host: String, val port: Int, val origin: String)

/**
 * Where a connected device may be reached on this network: NSD's addresses for it, then the `lan` addresses it
 * reported in connect.addresses (at Bridgey's TCP port), each only when it is a LAN address on one of this phone's
 * current Wi-Fi or Ethernet networks (IPv6 from NSD needs a local network up). Nothing on mobile data.
 */
internal fun lanUpgradeCandidates(
    nsdHosts: List<String>,
    nsdPort: Int?,
    learned: List<dev.bridgey.android.connect.LearnedAddress>,
    networks: List<LocalIPv4Network>,
): List<LanCandidate> {
    if (networks.isEmpty()) return emptyList()
    fun usable(host: String): Boolean {
        if (!isLanAddress(host) || isVirtualInterfaceAddress(host)) return false
        val v4 = parseIPv4(host) ?: return true
        return networks.any { it.contains(v4) }
    }
    val seen = HashSet<String>()
    val fromNsd = nsdHosts.mapNotNull(::normalizedHost).filter { parseIPv4(it) != null || it.contains(':') }
        .filter { usable(it) && seen.add(it) }
        .map { LanCandidate(it, nsdPort ?: ReconnectPolicy.LISTENING_PORT, "nsd") }
    val fromLearned = learned.asSequence()
        .filter { it.kind == "lan" && parseIPv4(it.a) != null }
        .sortedByDescending { it.seenAtMillis }
        .map { it.a }
        .filter { usable(it) && seen.add(it) }
        .map { LanCandidate(it, ReconnectPolicy.LISTENING_PORT, "learned") }
        .toList()
    return fromNsd + fromLearned
}

/** connect.addresses this phone sends: its own addresses without the virtual-interface ranges. */
internal fun advertisedConnectAddresses(addresses: List<dev.bridgey.android.connect.ConnectAddress>): List<dev.bridgey.android.connect.ConnectAddress> =
    addresses.filterNot { it.kind == "lan" && isVirtualInterfaceAddress(it.a) }

// endregion

// region Upgrade loop

/** One connected device as the upgrade loop sees it right now. */
internal enum class LanUpgradeCheck {
    /** On the LAN already, not connected, or the peer has no lan_first_draft1: nothing to do. */
    NOT_NEEDED,

    /** An upgrade is wanted but a transfer is running: try again later. */
    TRANSFER,
    READY,
}

/** What the upgrade loop did, for logs and diagnostics (`transport` / `lan_upgrade`). */
internal sealed interface LanUpgradeEvent {
    val deviceId: String

    data class Dial(override val deviceId: String, val address: LanCandidate, val attempt: Int, val reason: String) : LanUpgradeEvent
    data class Won(override val deviceId: String, val address: LanCandidate, val detail: String) : LanUpgradeEvent
    data class Failed(override val deviceId: String, val address: LanCandidate, val reason: String, val failures: Int) : LanUpgradeEvent
    data class SkippedTransfer(override val deviceId: String) : LanUpgradeEvent
}

internal object LanUpgradePolicy {
    /** Between tries while an upgrade is possible but has not worked yet, or while a transfer runs. */
    const val RETRY_MILLIS = 30_000L

    /** After this many failed dials on one network... */
    const val QUICK_FAILURES = 3

    /** ...one try every 5 minutes until the network changes. */
    const val SLOW_RETRY_MILLIS = 300_000L

    /** A dial whose outcome never came back is treated as failed after this long. */
    const val DIAL_GIVE_UP_MILLIS = 60_000L
}

/**
 * Keeps trying to move each connected device that is not on the LAN onto it: when a LAN address appears, it dials
 * there as a reconnect would (same handshake and checks, no prompt), and the duplicate rule lets the new session
 * replace the tunnel. One dial in flight per device; a try at once when something changes ([poke]), then every
 * 30 s; after 3 failures on one network, every 5 minutes until the network changes. With no LAN address it waits
 * for a [poke] and sets no timer, so a phone away from home never wakes up for it. Thread-safe; callbacks are
 * never called while the loop holds its lock.
 */
internal class LanUpgradeEngine(private val clock: ReconnectClock) {
    @Volatile var connectedIds: () -> Collection<String> = { emptyList() }
    @Volatile var check: (String) -> LanUpgradeCheck = { LanUpgradeCheck.NOT_NEEDED }
    @Volatile var candidates: (String) -> List<LanCandidate> = { emptyList() }

    /** Identifies this phone's current networks: a change starts the failure count over. */
    @Volatile var network: () -> String = { "" }

    /** Opens the connection; the coordinator calls [dialEnded] once it authenticated or failed. */
    @Volatile var dial: (String, LanCandidate) -> Unit = { _, _ -> }
    @Volatile var onEvent: (LanUpgradeEvent) -> Unit = {}

    private class Entry(var network: String) {
        var failures = 0
        var attempts = 0
        var nextAtMillis = 0L

        /** No LAN address last time: no timer until a poke. */
        var idle = false
        var dialing: LanCandidate? = null
        var dialStartedAt = 0L
        var skipLogged = false
    }

    private val entries = HashMap<String, Entry>()
    private var timer: ScheduledTask? = null
    private var pendingReason = "timer"

    /** A poke asked for a pass now; no rescheduling may push it out. */
    private var immediate = false

    /**
     * Something that can make an upgrade possible happened (a session came up, discovery or the network changed, a
     * transfer finished): try now, unless a device already failed 3 times on this network.
     */
    fun poke(reason: String) {
        synchronized(this) {
            val now = clock.elapsedMillis()
            entries.values.forEach { entry ->
                entry.idle = false
                if (entry.failures < LanUpgradePolicy.QUICK_FAILURES) entry.nextAtMillis = minOf(entry.nextAtMillis, now)
            }
            pendingReason = reason
            immediate = true
            armLocked(now)
        }
    }

    /** The upgrade dial to [id] ended. [upgraded]: the device is on the LAN now (this dial won, or its own did). */
    fun dialEnded(id: String, upgraded: Boolean, reason: String) {
        val event = synchronized(this) {
            val entry = entries[id] ?: return
            val address = entry.dialing ?: return
            entry.dialing = null
            val now = clock.elapsedMillis()
            val event = if (upgraded) {
                entries.remove(id)
                LanUpgradeEvent.Won(id, address, reason)
            } else {
                entry.failures += 1
                entry.nextAtMillis = now + delayAfter(entry.failures)
                LanUpgradeEvent.Failed(id, address, reason, entry.failures)
            }
            armLocked(now)
            event
        }
        onEvent(event)
    }

    @Synchronized fun isDialing(id: String): Boolean = entries[id]?.dialing != null

    @Synchronized fun failures(id: String): Int = entries[id]?.failures ?: 0

    @Synchronized fun nextAt(id: String): Long? = entries[id]?.takeIf { !it.idle && it.dialing == null }?.nextAtMillis

    private fun delayAfter(failures: Int): Long =
        if (failures >= LanUpgradePolicy.QUICK_FAILURES) LanUpgradePolicy.SLOW_RETRY_MILLIS else LanUpgradePolicy.RETRY_MILLIS

    /** One pass over the connected devices: callbacks first, then the bookkeeping under the lock, then the dials. */
    internal fun run() {
        // Taken before the callbacks run: a poke that arrives meanwhile asks for another pass.
        val reason = synchronized(this) {
            immediate = false
            pendingReason.also { pendingReason = "timer" }
        }
        val ids = runCatching { connectedIds().toSet() }.getOrDefault(emptySet())
        val checks = ids.associateWith { id -> runCatching { check(id) }.getOrDefault(LanUpgradeCheck.NOT_NEEDED) }
        val addresses = checks.filterValues { it != LanUpgradeCheck.NOT_NEEDED }.mapValues { (id, _) -> runCatching { candidates(id) }.getOrDefault(emptyList()) }
        val net = runCatching { network() }.getOrDefault("")
        val events = ArrayList<LanUpgradeEvent>()
        val dials = ArrayList<Pair<String, LanCandidate>>()
        synchronized(this) {
            val now = clock.elapsedMillis()
            // A dial whose answer never came: give up on it so the device is tried again.
            entries.forEach { (id, entry) ->
                val address = entry.dialing ?: return@forEach
                if (now - entry.dialStartedAt < LanUpgradePolicy.DIAL_GIVE_UP_MILLIS) return@forEach
                entry.dialing = null
                entry.failures += 1
                entry.nextAtMillis = now + delayAfter(entry.failures)
                events += LanUpgradeEvent.Failed(id, address, "no_outcome", entry.failures)
            }
            entries.keys.retainAll { it in ids || entries[it]?.dialing != null }
            checks.forEach { (id, check) ->
                if (check == LanUpgradeCheck.NOT_NEEDED) {
                    if (entries[id]?.dialing == null) entries.remove(id)
                    return@forEach
                }
                val entry = entries.getOrPut(id) { Entry(net) }
                if (entry.network != net) {
                    entry.network = net
                    entry.failures = 0
                    entry.nextAtMillis = 0
                }
                if (entry.dialing != null || now < entry.nextAtMillis) return@forEach
                val list = addresses[id].orEmpty()
                if (list.isEmpty()) {
                    entry.idle = true
                    return@forEach
                }
                entry.idle = false
                if (check == LanUpgradeCheck.TRANSFER) {
                    if (!entry.skipLogged) events += LanUpgradeEvent.SkippedTransfer(id)
                    entry.skipLogged = true
                    entry.nextAtMillis = now + LanUpgradePolicy.RETRY_MILLIS
                    return@forEach
                }
                entry.skipLogged = false
                val address = list[entry.attempts % list.size]
                entry.attempts += 1
                entry.dialing = address
                entry.dialStartedAt = now
                events += LanUpgradeEvent.Dial(id, address, entry.attempts, reason)
                dials += id to address
            }
            armLocked(now)
        }
        events.forEach { event -> runCatching { onEvent(event) } }
        dials.forEach { (id, address) -> dial(id, address) }
    }

    /** One timer for every device: the earliest try of a device that has an address and no dial in flight. */
    private fun armLocked(now: Long) {
        timer?.cancel()
        timer = null
        if (immediate) {
            timer = clock.schedule(0) { run() }
            return
        }
        val waiting = entries.values.filter { !it.idle }
        val next = waiting.filter { it.dialing == null }.minOfOrNull { it.nextAtMillis }
        // A dial in flight is checked again when it should have ended, in case its outcome never comes back.
        val giveUp = waiting.mapNotNull { entry -> entry.dialing?.let { entry.dialStartedAt + LanUpgradePolicy.DIAL_GIVE_UP_MILLIS } }.minOrNull()
        val at = listOfNotNull(next, giveUp).minOrNull() ?: return
        timer = clock.schedule((at - now).coerceAtLeast(0)) { run() }
    }
}

// endregion
