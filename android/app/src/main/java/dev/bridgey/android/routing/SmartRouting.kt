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

/** Pin an alert to its original presenter: updates and ongoing calls never chase the latest activity. */
class NotificationAlertRoutes(private val capacity: Int = 1_024) {
    private val owners = linkedMapOf<String, String?>()
    @Synchronized fun owner(id: String, choose: () -> String?): String? {
        if (owners.containsKey(id)) return owners[id]
        // Never evict a live owner's identity and accidentally alert it twice on a later update.
        if (owners.size >= capacity) return null
        val result = choose()
        owners[id] = result
        return result
    }
    @Synchronized fun remove(id: String) { owners.remove(id) }
    @Synchronized fun clear() { owners.clear() }
}
