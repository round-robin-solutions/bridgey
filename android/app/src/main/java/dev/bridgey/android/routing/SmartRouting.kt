package dev.bridgey.android.routing

import dev.bridgey.android.jsonInteger
import dev.bridgey.android.strictJsonObject
import org.json.JSONTokener

const val DEVICE_PRESENCE_FEATURE_KEY = "device_presence_draft1"
const val NOTIFICATION_ROUTING_FEATURE_KEY = "notification_routing_draft1"
const val PRESENCE_FRESH_MILLIS = 20_000L
const val ACTIVE_INPUT_MILLIS = 120_000L

enum class PresenceState(val wire: String) { ACTIVE("active"), IDLE("idle"), LOCKED("locked"), UNKNOWN("unknown") }

data class DevicePresencePacket(val sequence: Long, val state: PresenceState, val idleSeconds: Long?)

/** No wall clocks, foreground app names, input events or screen content cross this boundary. */
fun decodeDevicePresence(bytes: ByteArray): DevicePresencePacket? {
    if (bytes.size > 512) return null
    val p = strictJsonObject(bytes) ?: return null
    // Android's JSON implementation may keep the last duplicate; decode keys before accepting it.
    val unique = runCatching {
        val tokens = JSONTokener(bytes.toString(Charsets.UTF_8))
        val keys = mutableSetOf<String>()
        require(tokens.nextClean() == '{')
        if (tokens.nextClean() != '}') {
            tokens.back()
            while (true) {
                val key = tokens.nextValue() as? String ?: error("key")
                require(keys.add(key) && tokens.nextClean() == ':')
                tokens.nextValue()
                when (tokens.nextClean()) {
                    '}' -> break
                    ',' -> Unit
                    else -> error("separator")
                }
            }
        }
        true
    }.getOrDefault(false)
    if (!unique) return null
    if (jsonInteger(p.opt("version")) != 1L) return null
    val sequence = jsonInteger(p.opt("sequence"))?.takeIf { it in 1..9_007_199_254_740_991L } ?: return null
    val state = PresenceState.entries.firstOrNull { it.wire == p.opt("state") } ?: return null
    val allowed = if (state == PresenceState.ACTIVE || state == PresenceState.IDLE)
        setOf("version", "sequence", "state", "idleSeconds") else setOf("version", "sequence", "state")
    if (p.keys().asSequence().toSet() != allowed) return null
    val idle = if (state == PresenceState.ACTIVE || state == PresenceState.IDLE) {
        jsonInteger(p.opt("idleSeconds"))?.takeIf { it in 0..86_400 } ?: return null
    } else {
        if (p.has("idleSeconds")) return null
        null
    }
    if (state == PresenceState.ACTIVE && idle!! >= 120 || state == PresenceState.IDLE && idle!! < 120) return null
    return DevicePresencePacket(sequence, state, idle)
}

data class ObservedPresence(val sessionId: String, val packet: DevicePresencePacket, val receivedAt: Long) {
    fun fresh(now: Long): Boolean = now >= receivedAt && now - receivedAt < PRESENCE_FRESH_MILLIS
    fun activeAge(now: Long): Long? = if (fresh(now) && packet.state == PresenceState.ACTIVE) {
        (packet.idleSeconds!! * 1_000 + now - receivedAt).takeIf { it < ACTIVE_INPUT_MILLIS }
    } else null
}

/** Session-scoped sequence high-water marks survive sample expiration but never a reconnect. */
class DevicePresenceStore {
    private val values = mutableMapOf<String, ObservedPresence>()
    @Synchronized fun receive(deviceId: String, sessionId: String, packet: DevicePresencePacket, now: Long): Boolean {
        val prior = values[deviceId]
        if (prior?.sessionId == sessionId && packet.sequence <= prior.packet.sequence) return false
        values[deviceId] = ObservedPresence(sessionId, packet, now)
        return true
    }
    @Synchronized fun get(deviceId: String, sessionId: String): ObservedPresence? = values[deviceId]?.takeIf { it.sessionId == sessionId }
    @Synchronized fun remove(deviceId: String) { values.remove(deviceId) }
    @Synchronized fun clear() { values.clear() }
}

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
