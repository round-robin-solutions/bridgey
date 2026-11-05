package dev.bridgey.android.routing

/**
 * Notification routing on top of the share presence state (DevicePresence.kt). Presence decoding,
 * freshness and sequence fencing live there; this file only picks the alert presenter.
 */
const val NOTIFICATION_ROUTING_FEATURE_KEY = "notification_routing_draft1"

enum class RoutingReason { ACTIVE, PREFERRED, PHONE_ONLY, ALL_DEVICES, UNAVAILABLE }
data class RoutingDecision(val deviceId: String?, val reason: RoutingReason)
data class RoutingCandidate(val deviceId: String, val presence: ObservedPresence?)

/** The caller supplies only connected, trusted peers with the operation allowed at both ends. */
fun chooseRoutingTarget(candidates: List<RoutingCandidate>, preferred: String?, now: Long): RoutingDecision {
    val active = candidates.mapNotNull { c -> c.presence?.activeAge(now)?.let { c to it } }
    val best = active.sortedWith(compareBy<Pair<RoutingCandidate, Long>> { it.second }
        .thenBy { if (it.first.deviceId == preferred) 0 else 1 }.thenBy { it.first.deviceId }).firstOrNull()
    if (best != null) return RoutingDecision(best.first.deviceId, RoutingReason.ACTIVE)
    // An explicit preference works even with an older Mac, or activity sharing turned off.
    // A known locked Mac cannot become a fallback simply because its sample expired.
    val fallback = candidates.firstOrNull { it.deviceId == preferred && it.presence?.packet?.state != PresenceState.LOCKED }
    return if (fallback != null) RoutingDecision(fallback.deviceId, RoutingReason.PREFERRED)
        else RoutingDecision(null, RoutingReason.PHONE_ONLY)
}

data class NotificationDispatchTicket(val notificationId: String, val generation: Long, val owner: String?)

/** Pin an alert to its original presenter and invalidate queued work on removal/reconciliation. */
class NotificationAlertRoutes(private val capacity: Int = 1_024) {
    private data class Record(val generation: Long, val owner: String?, val chosen: Boolean)
    private val owners = linkedMapOf<String, Record>()
    private var generation = 0L

    @Synchronized fun plan(id: String, pinOwner: Boolean = true, choose: () -> String?): NotificationDispatchTicket? {
        val old = owners[id]
        if (old != null && (old.chosen || !pinOwner)) return NotificationDispatchTicket(id, old.generation, old.owner)
        // Never evict a live owner's identity and accidentally alert it twice on a later update.
        if (old == null && owners.size >= capacity) return null
        val record = Record(++generation, if (pinOwner) choose() else null, pinOwner)
        owners[id] = record
        return NotificationDispatchTicket(id, record.generation, record.owner)
    }
    @Synchronized fun owner(id: String, choose: () -> String?): String? = plan(id, choose = choose)?.owner
    @Synchronized fun contains(id: String): Boolean = id in owners
    @Synchronized fun current(ticket: NotificationDispatchTicket): Boolean = owners[ticket.notificationId]?.generation == ticket.generation
    @Synchronized fun remove(id: String): Boolean = owners.remove(id) != null
    @Synchronized fun retain(active: Set<String>, keep: (String) -> Boolean = { false }): List<String> {
        val removed = owners.keys.filter { it !in active && !keep(it) }
        removed.forEach(owners::remove)
        return removed
    }
    @Synchronized fun clear() { owners.clear() }
}

/** Executed on the coordinator's serial notification lane, using an immutable owner per fanout. */
fun <T> dispatchNotification(
    ticket: NotificationDispatchTicket,
    recipients: List<T>,
    allDevices: Boolean,
    current: () -> Boolean,
    deviceId: (T) -> String,
    send: (recipient: T, alert: Boolean) -> Boolean,
): List<T> {
    val delivered = mutableListOf<T>()
    for (recipient in recipients) {
        if (!current()) break
        if (send(recipient, allDevices || deviceId(recipient) == ticket.owner)) delivered += recipient
    }
    return delivered
}
