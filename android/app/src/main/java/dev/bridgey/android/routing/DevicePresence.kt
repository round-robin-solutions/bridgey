package dev.bridgey.android.routing

import dev.bridgey.android.jsonInteger
import dev.bridgey.android.strictJsonObject
import org.json.JSONTokener

const val DEVICE_PRESENCE_FEATURE_KEY = "device_presence_draft1"
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
    private val sequences = mutableMapOf<String, Pair<String, Long>>()
    @Synchronized fun receive(deviceId: String, sessionId: String, packet: DevicePresencePacket, now: Long): Boolean {
        val prior = sequences[deviceId]
        if (prior?.first == sessionId && packet.sequence <= prior.second) return false
        sequences[deviceId] = sessionId to packet.sequence
        values[deviceId] = ObservedPresence(sessionId, packet, now)
        return true
    }
    @Synchronized fun get(deviceId: String, sessionId: String): ObservedPresence? = values[deviceId]?.takeIf { it.sessionId == sessionId }
    /** A same-session opt-out forgets activity, never its replay high-water mark. */
    @Synchronized fun invalidate(deviceId: String) { values.remove(deviceId) }
    @Synchronized fun remove(deviceId: String) { values.remove(deviceId); sequences.remove(deviceId) }
    @Synchronized fun clear() { values.clear(); sequences.clear() }
}
