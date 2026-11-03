package dev.bridgey.android.agents

import org.json.JSONArray
import org.json.JSONObject

/** One grant of one agent device as stored: on with its window, or off; [waitingUntil] after agent.grant_request. */
data class GrantRecord(
    val on: Boolean = false,
    val window: GrantWindow? = null,
    val grantedAt: Long? = null,
    val expiresAt: Long? = null,
    val waitingUntil: Long? = null,
)

/** A grant whose window ended, for the audit (`grant.expired`) and features.update. */
data class ExpiredGrant(val deviceId: String, val grant: AgentGrant, val window: GrantWindow?)

/** Where grants live between runs: one JSON text per agent device. */
interface GrantStore {
    fun load(): Map<String, String>
    fun save(deviceId: String, json: String)
    fun remove(deviceId: String)
}

/** How long agent.grant_request marks grants as waiting. */
const val GRANT_WAITING_MILLIS = 24L * 3_600_000

/**
 * Every agent device's grants, decided and enforced on this phone. Every grant starts off, whatever the global
 * switches say. A window that ended reads as off at once ([isOn] checks the time on every use); [expireDue] turns
 * it off for good and reports it, so features.update and agent.grants go out.
 */
class AgentGrantBook(
    private val store: GrantStore,
    private val clock: () -> Long = System::currentTimeMillis,
    private val zone: () -> java.time.ZoneId = { java.time.ZoneId.systemDefault() },
) {
    private val grants = HashMap<String, MutableMap<AgentGrant, GrantRecord>>()

    init {
        store.load().forEach { (deviceId, json) -> grants[deviceId] = decodeGrants(json) }
    }

    @Synchronized fun record(deviceId: String, grant: AgentGrant): GrantRecord = grants[deviceId]?.get(grant) ?: GrantRecord()

    /** On now: switched on and its window not over. Read your notifications is never on. */
    @Synchronized fun isOn(deviceId: String, grant: AgentGrant, now: Long = clock()): Boolean {
        if (!grant.grantable) return false
        val record = grants[deviceId]?.get(grant) ?: return false
        return record.on && (record.expiresAt == null || now < record.expiresAt)
    }

    /** Switches [grant] on for [window] (from now) or off. Returns false when nothing changed. */
    @Synchronized fun set(deviceId: String, grant: AgentGrant, on: Boolean, window: GrantWindow?, now: Long = clock()): Boolean {
        if (on && (!grant.grantable || window == null)) return false
        val map = grants.getOrPut(deviceId, ::HashMap)
        val before = map[grant] ?: GrantRecord()
        val after = if (on) {
            GrantRecord(on = true, window = window, grantedAt = now, expiresAt = window!!.expiresAt(now, zone()))
        } else {
            GrantRecord()
        }
        if (before == after) return false
        map[grant] = after
        persist(deviceId)
        return true
    }

    /** agent.grant_request: grants that are off now wait for Rahul for 24 hours. Returns the ones newly waiting. */
    @Synchronized fun markWaiting(deviceId: String, requested: List<AgentGrant>, now: Long = clock()): List<AgentGrant> {
        val map = grants.getOrPut(deviceId, ::HashMap)
        val marked = requested.filter { it.grantable && !isOn(deviceId, it, now) }
        marked.forEach { grant -> map[grant] = (map[grant] ?: GrantRecord()).copy(waitingUntil = now + GRANT_WAITING_MILLIS) }
        if (marked.isNotEmpty()) persist(deviceId)
        return marked
    }

    /** Turns off every grant whose window ended; drops waiting marks older than 24 hours. */
    @Synchronized fun expireDue(now: Long = clock()): List<ExpiredGrant> {
        val ended = ArrayList<ExpiredGrant>()
        grants.forEach { (deviceId, map) ->
            var changed = false
            map.entries.forEach { entry ->
                val record = entry.value
                if (record.on && record.expiresAt != null && now >= record.expiresAt) {
                    ended += ExpiredGrant(deviceId, entry.key, record.window)
                    entry.setValue(GrantRecord())
                    changed = true
                } else if (record.waitingUntil != null && now >= record.waitingUntil) {
                    entry.setValue(record.copy(waitingUntil = null))
                    changed = true
                }
            }
            if (changed) persist(deviceId)
        }
        return ended
    }

    /** The next moment something ends (a window or a waiting mark), or null. */
    @Synchronized fun nextChangeAt(): Long? = grants.values.flatMap { it.values }
        .flatMap { listOfNotNull(it.expiresAt?.takeIf { _ -> it.on }, it.waitingUntil) }
        .minOrNull()

    /** What the agent sees, in the wording table order; [scope] for Send you files. */
    @Synchronized fun views(deviceId: String, filesScope: String, now: Long = clock()): List<GrantView> = AgentGrant.entries.map { grant ->
        val record = grants[deviceId]?.get(grant) ?: GrantRecord()
        when {
            isOn(deviceId, grant, now) -> GrantView(
                grant, GrantShown.ON, record.window, record.grantedAt, record.expiresAt,
                scope = filesScope.takeIf { grant == AgentGrant.FILES },
            )
            record.waitingUntil != null && now < record.waitingUntil && grant.grantable -> GrantView(grant, GrantShown.WAITING)
            else -> GrantView(grant, GrantShown.OFF)
        }
    }

    @Synchronized fun forget(deviceId: String) {
        grants.remove(deviceId)
        store.remove(deviceId)
    }

    private fun persist(deviceId: String) {
        store.save(deviceId, encodeGrants(grants[deviceId].orEmpty()))
    }
}

internal fun encodeGrants(map: Map<AgentGrant, GrantRecord>): String = JSONArray(map.entries.filter { it.value != GrantRecord() }.map { (grant, record) ->
    JSONObject().put("key", grant.key).put("on", record.on).apply {
        record.window?.let { put("window", it.wire) }
        record.grantedAt?.let { put("grantedAt", it) }
        record.expiresAt?.let { put("expiresAt", it) }
        record.waitingUntil?.let { put("waitingUntil", it) }
    }
}).toString()

internal fun decodeGrants(json: String): MutableMap<AgentGrant, GrantRecord> {
    val map = HashMap<AgentGrant, GrantRecord>()
    val list = runCatching { JSONArray(json) }.getOrNull() ?: return map
    for (index in 0 until list.length()) {
        val entry = list.optJSONObject(index) ?: continue
        val grant = AgentGrant.of(entry.optString("key")) ?: continue
        fun long(name: String): Long? = if (entry.has(name)) entry.optLong(name) else null
        val window = GrantWindow.of(entry.optString("window").takeIf { it.isNotEmpty() })
        val on = entry.optBoolean("on") && grant.grantable && window != null
        map[grant] = GrantRecord(on, window.takeIf { on }, long("grantedAt").takeIf { on }, long("expiresAt").takeIf { on }, long("waitingUntil"))
    }
    return map
}

/** Grants in memory only, for tests. */
class MemoryGrantStore(private val initial: Map<String, String> = emptyMap()) : GrantStore {
    val saved = HashMap<String, String>(initial)
    override fun load(): Map<String, String> = initial
    override fun save(deviceId: String, json: String) {
        saved[deviceId] = json
    }
    override fun remove(deviceId: String) {
        saved.remove(deviceId)
    }
}

/** The presets on the device page after an invite pairing (Codes is never in one). */
enum class GrantPreset(val grants: List<AgentGrant>) {
    MESSAGES(listOf(AgentGrant.NOTIFY, AgentGrant.ASK)),
    FILES(listOf(AgentGrant.FILES)),
    FIND(listOf(AgentGrant.RING, AgentGrant.BATTERY)),
}
