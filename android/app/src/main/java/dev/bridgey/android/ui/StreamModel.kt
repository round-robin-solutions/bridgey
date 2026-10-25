package dev.bridgey.android.ui

import dev.bridgey.android.DeviceConnection
import dev.bridgey.android.DeviceLinkState
import dev.bridgey.android.FileTransferState
import dev.bridgey.android.PairingState
import dev.bridgey.android.TrustedDevice
import dev.bridgey.android.activity.ActivityCategory
import dev.bridgey.android.activity.ActivityHistory
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.core.discovery.DiscoveredPeer
import java.util.Calendar
import java.util.TimeZone

/*
 * Pure UI-state mapping for the Stream screens, unit tested without Android.
 */

/** How a device is reached right now. Each has its own ring style. */
enum class RingState {
    /** Connected over the local network (same Wi-Fi): the aurora gradient ring. */
    CONNECTED,

    /** Pairing or reconnecting. */
    CONNECTING,

    /** Seen on the network but not connected: dashed ring. */
    NEARBY,

    /** Paired but not seen: plain outline ring. */
    OFFLINE,
}

data class DeviceRing(
    /** Stable key for lists; the device id when known. */
    val key: String,
    val deviceId: String?,
    val name: String,
    val state: RingState,
    val trusted: Boolean,
    /** Platform from discovery ("macos", "android"); null when unknown. */
    val platform: String?,
    /** Where to connect to pair or reconnect; null when not on the network. */
    val peer: DiscoveredPeer?,
)

/**
 * Every trusted device plus every device on the network, in reading order: connected, then
 * connecting, nearby paired, offline paired, and new devices last.
 */
fun deviceRings(
    trusted: List<TrustedDevice>,
    peers: List<DiscoveredPeer>,
    state: PairingState,
): List<DeviceRing> {
    val connected = (state as? PairingState.Connected)?.let { listOf(DeviceConnection(it.deviceId, it.peerName, DeviceLinkState())) }.orEmpty()
    return deviceRings(trusted, peers, connected, state)
}

/**
 * Multi-device: every connected device shows as connected at once; [pairing] (the pairing flow)
 * marks the device being paired as connecting.
 */
fun deviceRings(
    trusted: List<TrustedDevice>,
    peers: List<DiscoveredPeer>,
    connections: List<DeviceConnection>,
    pairing: PairingState,
): List<DeviceRing> {
    val connectedIds = connections.mapTo(HashSet()) { it.deviceId }
    val connectingName = when (pairing) {
        is PairingState.Connecting -> pairing.peerName
        is PairingState.Verification -> pairing.peerName
        else -> null
    }
    val trustedIds = trusted.mapTo(HashSet()) { it.id }
    val rings = trusted.map { device ->
        val peer = peers.firstOrNull { it.deviceIdHint == device.id }
        val ringState = when {
            device.id in connectedIds -> RingState.CONNECTED
            connectingName != null && (connectingName == device.name || connectingName == peer?.deviceNameHint) -> RingState.CONNECTING
            peer != null -> RingState.NEARBY
            else -> RingState.OFFLINE
        }
        DeviceRing(device.id, device.id, device.name, ringState, trusted = true, platform = peer?.platformHint, peer = peer)
    }.toMutableList()
    connections.filter { it.deviceId !in trustedIds }.forEach { connected ->
        val peer = peers.firstOrNull { it.deviceIdHint == connected.deviceId }
        rings += DeviceRing(connected.deviceId, connected.deviceId, connected.peerName, RingState.CONNECTED, trusted = true, platform = peer?.platformHint, peer = peer)
    }
    peers
        .filter { peer -> peer.deviceIdHint == null || (peer.deviceIdHint !in trustedIds && peer.deviceIdHint !in connectedIds) }
        .forEach { peer ->
            val ringState = if (connectingName != null && connectingName == peer.deviceNameHint) RingState.CONNECTING else RingState.NEARBY
            rings += DeviceRing("peer:${peer.key}", peer.deviceIdHint, peer.deviceNameHint, ringState, trusted = false, platform = peer.platformHint, peer = peer)
        }
    return rings.withIndex()
        .sortedWith(compareBy({ order(it.value) }, { it.index }))
        .map { it.value }
}

private fun order(ring: DeviceRing): Int = when {
    ring.state == RingState.CONNECTED -> 0
    ring.state == RingState.CONNECTING -> 1
    ring.trusted && ring.state == RingState.NEARBY -> 2
    ring.trusted -> 3
    else -> 4
}

/** The device the send bar aims at: the user's pick when it still exists, else the connected one, else the first paired. */
fun sendTarget(rings: List<DeviceRing>, pickedId: String?): DeviceRing? =
    rings.firstOrNull { it.trusted && it.deviceId != null && it.deviceId == pickedId }
        ?: rings.firstOrNull { it.state == RingState.CONNECTED }
        ?: rings.firstOrNull { it.trusted }

/** The filter chips on Home. */
enum class StreamFilter(val category: ActivityCategory?) {
    ALL(null),
    CLIPBOARD(ActivityCategory.CLIPBOARD),
    FILES(ActivityCategory.FILES),
    ALERTS(ActivityCategory.ALERTS),
    CALLS(ActivityCategory.CALLS),
}

enum class DaySection { TODAY, YESTERDAY, EARLIER }

sealed interface StreamRow {
    val key: String

    data class Header(val section: DaySection) : StreamRow {
        override val key: String get() = "header:${section.name}"
    }

    /** [first] and [last] are within the item's day section; they shape the timeline rail. */
    data class Item(val item: ActivityItem, val section: DaySection, val first: Boolean, val last: Boolean) : StreamRow {
        override val key: String get() = "item:${item.id}"
    }
}

fun daySection(atMillis: Long, now: Long, zone: TimeZone): DaySection {
    val today = startOfDay(now, zone)
    return when {
        atMillis >= today -> DaySection.TODAY
        atMillis >= startOfDay(today - 1, zone) -> DaySection.YESTERDAY
        else -> DaySection.EARLIER
    }
}

private fun startOfDay(millis: Long, zone: TimeZone): Long = Calendar.getInstance(zone).run {
    timeInMillis = millis
    set(Calendar.HOUR_OF_DAY, 0)
    set(Calendar.MINUTE, 0)
    set(Calendar.SECOND, 0)
    set(Calendar.MILLISECOND, 0)
    timeInMillis
}

/**
 * The stream as list rows: newest first, filtered by category and (on a device page) by device,
 * grouped under Today, Yesterday and Earlier. Items past the seven day limit are dropped even
 * before the log prunes them.
 */
fun streamRows(
    items: List<ActivityItem>,
    filter: StreamFilter,
    deviceId: String?,
    now: Long,
    zone: TimeZone,
): List<StreamRow> {
    val visible = ActivityHistory.prune(items, now)
        .filter { filter.category == null || it.kind.category == filter.category }
        .filter { deviceId == null || it.deviceId == deviceId }
    val rows = mutableListOf<StreamRow>()
    visible.groupBy { daySection(it.atMillis, now, zone) }
        .toSortedMap()
        .forEach { (section, sectionItems) ->
            rows += StreamRow.Header(section)
            sectionItems.forEachIndexed { index, item ->
                rows += StreamRow.Item(item, section, first = index == 0, last = index == sectionItems.lastIndex)
            }
        }
    return rows
}

/** Transfers that need a card with an action: running ones (Cancel) and failed ones that can be retried. */
fun liveTransfers(transfers: Map<String, FileTransferState>): List<FileTransferState> =
    transfers.values.filter { it.active || it.retryable }.sortedByDescending { it.startedAtMillis }

/** Notification apps that may forward, out of all seen. */
fun notificationAppCounts(applications: Map<String, String>, disabled: Set<String>): Pair<Int, Int> =
    applications.keys.count { it !in disabled } to applications.size

/**
 * Remembers which list keys were added after the list was first shown, so only those animate
 * in. Keys that come back into view by scrolling never count as new.
 */
class ArrivalTracker {
    private var known: Set<String>? = null
    private val arrived = LinkedHashSet<String>()

    /** Call with the current keys, in composition; idempotent for the same keys. */
    fun update(keys: List<String>) {
        val previous = known
        if (previous != null) keys.filter { it !in previous }.forEach { arrived += it }
        known = previous.orEmpty() + keys
        while (arrived.size > 64) arrived.remove(arrived.first())
    }

    /** True once for a key that arrived after the first update. */
    fun consume(key: String): Boolean = arrived.remove(key)
}
