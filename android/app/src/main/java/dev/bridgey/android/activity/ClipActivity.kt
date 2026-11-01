package dev.bridgey.android.activity

import dev.bridgey.android.ClipboardSendResult
import java.security.MessageDigest

/** How one device's answer to a clipboard send shows in the stream. */
fun ClipboardSendResult.peerState(): ActivityPeerState = when (this) {
    ClipboardSendResult.DELIVERED -> ActivityPeerState.DELIVERED
    ClipboardSendResult.DISABLED -> ActivityPeerState.OFF
    else -> ActivityPeerState.FAILED
}

/**
 * One copy is one stream item. A copy sent to several devices becomes one item that follows each device's
 * answer ("Copied to MacBook Pro and Work Mac"), recorded when the first device has it (a copy that reached
 * nobody leaves no item, as before). The same clip arriving through a second device within [windowMillis]
 * joins the first item. Kept in memory only; the clip hashes are never stored.
 */
class ClipActivityGroups(private val windowMillis: Long = WINDOW_MILLIS) {
    private class Send(val peers: MutableList<ActivityPeer>, var itemId: Long? = null)
    private class Arrival(val hash: String, val itemId: Long, val atMillis: Long, val peers: MutableList<ActivityPeer>)

    private val sends = LinkedHashMap<String, Send>()
    private val arrivals = ArrayDeque<Arrival>()

    /**
     * A device answered send [groupId] (to [targets], id to name). Returns what to do: record a new item with
     * these peers, update item [Update.itemId], or nothing.
     */
    @Synchronized
    fun answered(groupId: String, targets: List<Pair<String, String>>, deviceId: String, deviceName: String, state: ActivityPeerState): Update? {
        val send = sends.getOrPut(groupId) {
            Send(targets.mapTo(ArrayList()) { (id, name) -> ActivityPeer(id, name, ActivityPeerState.PENDING) })
        }
        while (sends.size > KEPT_GROUPS) sends.remove(sends.keys.first())
        val index = send.peers.indexOfFirst { it.deviceId == deviceId }
        if (index >= 0) {
            send.peers[index] = send.peers[index].copy(deviceName = deviceName, state = state)
        } else {
            send.peers += ActivityPeer(deviceId, deviceName, state)
        }
        val itemId = send.itemId
        return when {
            itemId != null -> Update(itemId, send.peers.toList())
            send.peers.any { it.state == ActivityPeerState.DELIVERED } -> Update(null, send.peers.toList())
            else -> null
        }
    }

    /** The item recorded for [groupId]. */
    @Synchronized
    fun recorded(groupId: String, itemId: Long) {
        sends[groupId]?.itemId = itemId
    }

    /** A clip with [hash] arrived from [deviceId]: the earlier item it joins, with the peers to set, or null for a new item. */
    @Synchronized
    fun arrived(hash: String, deviceId: String, deviceName: String, now: Long): Update? {
        arrivals.removeAll { now - it.atMillis > windowMillis || now < it.atMillis }
        val match = arrivals.lastOrNull { it.hash == hash } ?: return null
        // The same device again is a new copy.
        if (match.peers.any { it.deviceId == deviceId }) return null
        match.peers += ActivityPeer(deviceId, deviceName, ActivityPeerState.DELIVERED)
        return Update(match.itemId, match.peers.toList())
    }

    @Synchronized
    fun rememberArrival(hash: String, itemId: Long, deviceId: String, deviceName: String, now: Long) {
        arrivals.addLast(Arrival(hash, itemId, now, mutableListOf(ActivityPeer(deviceId, deviceName, ActivityPeerState.DELIVERED))))
        while (arrivals.size > KEPT_GROUPS) arrivals.removeFirst()
    }

    /** [itemId] null: record a new item with [peers]. */
    data class Update(val itemId: Long?, val peers: List<ActivityPeer>)

    companion object {
        const val WINDOW_MILLIS = 60_000L
        const val KEPT_GROUPS = 16

        fun textHash(text: String): String =
            MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }
}

/** "A", "A and B", "A, B and C". */
fun joinDeviceNames(names: List<String>, and: String = " and "): String = when (names.size) {
    0 -> ""
    1 -> names[0]
    else -> names.dropLast(1).joinToString(", ") + and + names.last()
}
