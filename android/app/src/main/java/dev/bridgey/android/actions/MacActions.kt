package dev.bridgey.android.actions

import android.content.Context
import dev.bridgey.android.jsonInteger
import dev.bridgey.android.strictJsonObject
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/*
 * Mac actions, draft `mac_actions_draft1` (docs/protocol.md, "Mac actions"). The Mac publishes a
 * list of what this phone may run (`actions.catalog`); the phone picks one entry by its identifier
 * (`actions.run`) and the Mac answers once (`actions.result`). The phone never sends a command,
 * a Shortcut name or any text: only an identifier from the Mac's own list, and an integer for
 * `volume_set`.
 */

/** The draft key in `features.update` the Mac sets when Web links understands `action: "open"`. */
const val LINKS_OPEN_FEATURE_KEY = "links_open_draft1"

enum class MacActionKind { SYSTEM, VOLUME, APP, SHORTCUT }

object MacActionIds {
    const val LOCK = "lock"
    const val SLEEP = "sleep"
    const val SCREENSAVER = "screensaver"
    const val VOLUME_UP = "volume_up"
    const val VOLUME_DOWN = "volume_down"
    const val VOLUME_MUTE = "volume_mute"
    const val VOLUME_SET = "volume_set"

    val SYSTEM = listOf(LOCK, SLEEP, SCREENSAVER)
    val VOLUME = listOf(VOLUME_DOWN, VOLUME_MUTE, VOLUME_UP, VOLUME_SET)
    private val APP = Regex("^app:[A-Za-z0-9.-]{1,155}$")
    private val SHORTCUT = Regex("^shortcut:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

    /** The kind of an identifier, or null when it is not one the protocol allows. */
    fun kind(id: String): MacActionKind? = when {
        id in SYSTEM -> MacActionKind.SYSTEM
        id in VOLUME -> MacActionKind.VOLUME
        APP.matches(id) -> MacActionKind.APP
        SHORTCUT.matches(id) -> MacActionKind.SHORTCUT
        else -> null
    }
}

/** The reasons a Mac may give for `refused`; anything else reads as `failed`. */
val MacActionReasons = setOf("not_allowed", "invalid", "rate_limited", "busy", "permission_required", "unavailable", "failed")

/** One entry the Mac allows this phone. [title] is set for apps and Shortcuts only. */
data class MacActionEntry(val id: String, val title: String? = null, val blocked: String? = null) {
    val kind: MacActionKind get() = MacActionIds.kind(id) ?: MacActionKind.SYSTEM
}

data class MacVolume(val level: Int, val muted: Boolean)

data class MacActionCatalog(val entries: List<MacActionEntry>, val volume: MacVolume? = null) {
    fun entry(id: String): MacActionEntry? = entries.firstOrNull { it.id == id }
    fun has(id: String): Boolean = entries.any { it.id == id }
    val system: List<MacActionEntry> get() = MacActionIds.SYSTEM.mapNotNull(::entry)
    val volumeEntries: List<MacActionEntry> get() = MacActionIds.VOLUME.mapNotNull(::entry)
    val apps: List<MacActionEntry> get() = entries.filter { it.kind == MacActionKind.APP }
    val shortcuts: List<MacActionEntry> get() = entries.filter { it.kind == MacActionKind.SHORTCUT }
    val isEmpty: Boolean get() = entries.isEmpty()

    fun toJson(): JSONObject = JSONObject().apply {
        put("version", 1)
        put("actions", JSONArray().apply {
            entries.forEach { entry ->
                put(JSONObject().apply {
                    put("id", entry.id)
                    entry.title?.let { put("title", it) }
                    entry.blocked?.let { put("blocked", it) }
                })
            }
        })
        volume?.let { put("volume", it.toJson()) }
    }

    companion object {
        const val MAX_ENTRIES = 64
        const val MAX_TITLE = 64
    }
}

internal fun MacVolume.toJson(): JSONObject = JSONObject().put("level", level).put("muted", muted)

/** `{level, muted}` with an integral level 0 to 100 and a boolean, else null. */
internal fun parseMacVolume(value: Any?): MacVolume? {
    val json = value as? JSONObject ?: return null
    val level = jsonInteger(json.opt("level"))
    val muted = json.opt("muted")
    if (level == null || level !in 0L..100L || muted !is Boolean) return null
    return MacVolume(level.toInt(), muted)
}

/** A shown title: 1 to 64 characters, no control characters. */
internal fun validActionTitle(value: Any?): String? {
    val text = value as? String ?: return null
    val length = text.codePointCount(0, text.length)
    if (length !in 1..MacActionCatalog.MAX_TITLE || text.isBlank()) return null
    if (text.any { Character.getType(it) == Character.CONTROL.toInt() || it == '\u2028' || it == '\u2029' }) return null
    return text
}

/**
 * Strict parse of an `actions.catalog` plaintext. Null for a malformed catalog (wrong version, no
 * array, more than 64 entries). Single entries with an unknown identifier, a missing or bad title
 * (apps and Shortcuts) or a repeated identifier are dropped; a bad `volume` is dropped.
 */
fun parseMacActionCatalog(payload: JSONObject): MacActionCatalog? {
    if (jsonInteger(payload.opt("version")) != 1L) return null
    val array = payload.opt("actions") as? JSONArray ?: return null
    if (array.length() > MacActionCatalog.MAX_ENTRIES) return null
    val seen = HashSet<String>()
    val entries = (0 until array.length()).mapNotNull { index ->
        val item = array.opt(index) as? JSONObject ?: return@mapNotNull null
        val id = item.opt("id") as? String ?: return@mapNotNull null
        val kind = MacActionIds.kind(id) ?: return@mapNotNull null
        if (!seen.add(id)) return@mapNotNull null
        val title = if (kind == MacActionKind.APP || kind == MacActionKind.SHORTCUT) {
            validActionTitle(item.opt("title")) ?: return@mapNotNull null
        } else null
        val blocked = (item.opt("blocked") as? String)?.takeIf { it == "permission_required" }
        MacActionEntry(id, title, blocked)
    }
    return MacActionCatalog(entries, parseMacVolume(payload.opt("volume")))
}

/** An `actions.catalog` plaintext as it arrives: at most 8 KiB of strict JSON (docs/protocol-contract.md). */
fun decodeMacActionCatalog(plaintext: ByteArray): MacActionCatalog? =
    plaintext.takeIf { it.size <= MacActionsClient.MAX_CATALOG_BYTES }?.let(::strictJsonObject)?.let(::parseMacActionCatalog)

/** A decoded `actions.result`. [reason] is set for `refused` only, and is one of [MacActionReasons]. */
data class MacActionResult(val requestId: String, val action: String, val done: Boolean, val reason: String?, val volume: MacVolume?)

/**
 * Strict parse of an `actions.result` plaintext: `version` 1, string `requestId` and `action`, `status` done or
 * refused. An unknown or missing reason on a refusal reads as `failed`; a bad `volume` is dropped.
 */
fun parseMacActionResult(payload: JSONObject): MacActionResult? {
    if (jsonInteger(payload.opt("version")) != 1L) return null
    val requestId = payload.opt("requestId") as? String ?: return null
    val action = payload.opt("action") as? String ?: return null
    val done = when (payload.opt("status")) {
        "done" -> true
        "refused" -> false
        else -> return null
    }
    val reason = if (done) null else (payload.opt("reason") as? String)?.takeIf { it in MacActionReasons } ?: "failed"
    return MacActionResult(requestId, action, done, reason, parseMacVolume(payload.opt("volume")))
}

/** An `actions.result` plaintext as it arrives: at most 1 KiB of strict JSON. */
fun decodeMacActionResult(plaintext: ByteArray): MacActionResult? =
    plaintext.takeIf { it.size <= MacActionsClient.MAX_RESULT_BYTES }?.let(::strictJsonObject)?.let(::parseMacActionResult)

/** The `actions.run` plaintext: an identifier from the Mac's catalog, the sequence and, for `volume_set` only, the level. */
fun macActionRunPayload(requestId: String, action: String, sequence: Long, value: Int? = null): JSONObject =
    JSONObject()
        .put("version", 1)
        .put("requestId", requestId)
        .put("action", action)
        .put("sequence", sequence)
        .apply { if (value != null) put("value", value) }

/** What happened to the last run the person started. */
enum class MacActionOutcome { RUNNING, DONE, REFUSED, NOT_CONFIRMED, NOT_SENT }

data class MacActionStatus(
    val deviceId: String,
    val actionId: String,
    val outcome: MacActionOutcome,
    /** For REFUSED: one of [MacActionReasons]. */
    val reason: String? = null,
    /** Increments with each status, so the same outcome twice still shows twice. */
    val serial: Long = 0,
)

/** Schedules a timeout; the returned function cancels it. */
fun interface ActionTimer {
    fun schedule(delayMillis: Long, block: () -> Unit): () -> Unit
}

/** The last known catalog per Mac, kept on this phone for Device Controls and widgets while offline. */
interface MacActionCatalogStore {
    fun load(): Map<String, MacActionCatalog>
    fun save(deviceId: String, catalog: MacActionCatalog?)
}

class SharedPreferencesCatalogStore(context: Context) : MacActionCatalogStore {
    private val preferences = context.getSharedPreferences("bridgey.mac_actions", Context.MODE_PRIVATE)

    override fun load(): Map<String, MacActionCatalog> = preferences.all.mapNotNull { (key, value) ->
        if (!key.startsWith(PREFIX) || value !is String) return@mapNotNull null
        val catalog = strictJsonObject(value)?.let(::parseMacActionCatalog) ?: return@mapNotNull null
        key.removePrefix(PREFIX) to catalog
    }.toMap()

    override fun save(deviceId: String, catalog: MacActionCatalog?) {
        val editor = preferences.edit()
        if (catalog == null) editor.remove(PREFIX + deviceId) else editor.putString(PREFIX + deviceId, catalog.toJson().toString())
        editor.apply()
    }

    private companion object {
        const val PREFIX = "catalog."
    }
}

class MemoryCatalogStore : MacActionCatalogStore {
    val saved = mutableMapOf<String, MacActionCatalog>()
    override fun load(): Map<String, MacActionCatalog> = saved.toMap()
    override fun save(deviceId: String, catalog: MacActionCatalog?) {
        if (catalog == null) saved.remove(deviceId) else saved[deviceId] = catalog
    }
}

/**
 * The phone's side of Mac actions, one instance for every Mac. Catalogs arrive per Mac and replace
 * the previous one; a run is sent only for an identifier in the catalog that Mac sent in this
 * session, at most one pending run per Mac and identifier, and ends with the Mac's result or a
 * timeout (10 seconds, 70 for a Shortcut).
 */
class MacActionsClient(
    private val store: MacActionCatalogStore,
    private val timer: ActionTimer,
    /** Mac actions is on here for the Mac and the Mac's latest `features.update` shows it. */
    private val available: (deviceId: String) -> Boolean,
    private val send: (deviceId: String, kind: String, payload: JSONObject) -> Boolean,
    private val newRequestId: () -> String = { UUID.randomUUID().toString() },
) {
    private class Pending(val deviceId: String, val actionId: String, val cancel: () -> Unit)

    private val mutableCatalogs = MutableStateFlow(store.load())

    /** The last catalog of every Mac, also while it is offline. */
    val catalogs: StateFlow<Map<String, MacActionCatalog>> = mutableCatalogs.asStateFlow()
    private val mutableLive = MutableStateFlow<Set<String>>(emptySet())

    /** Macs whose catalog arrived in their current session: only these can run actions. */
    val live: StateFlow<Set<String>> = mutableLive.asStateFlow()
    private val mutableRunning = MutableStateFlow<Set<Pair<String, String>>>(emptySet())

    /** (Mac, identifier) pairs waiting for a result. */
    val running: StateFlow<Set<Pair<String, String>>> = mutableRunning.asStateFlow()
    private val mutableStatus = MutableStateFlow<MacActionStatus?>(null)
    val status: StateFlow<MacActionStatus?> = mutableStatus.asStateFlow()
    private val pending = LinkedHashMap<String, Pending>()
    private val sequence = AtomicLong(0)
    private var serial = 0L

    /** The catalog [deviceId] can run now: live and available. */
    fun usableCatalog(deviceId: String): MacActionCatalog? =
        mutableCatalogs.value[deviceId]?.takeIf { deviceId in mutableLive.value && available(deviceId) }

    /** Runs [actionId] on [deviceId]; [value] only for `volume_set`. False when nothing was sent. */
    @Synchronized fun run(deviceId: String, actionId: String, value: Int? = null): Boolean {
        val catalog = usableCatalog(deviceId)
        if (catalog == null || !catalog.has(actionId)) return report(deviceId, actionId, MacActionOutcome.NOT_SENT)
        if (actionId == MacActionIds.VOLUME_SET) {
            if (value == null || value !in 0..100) return false
        } else if (value != null) return false
        if (pending.values.any { it.deviceId == deviceId && it.actionId == actionId }) return false
        val requestId = newRequestId()
        val payload = macActionRunPayload(requestId, actionId, sequence.incrementAndGet(), value)
        val timeout = if (MacActionIds.kind(actionId) == MacActionKind.SHORTCUT) SHORTCUT_TIMEOUT_MILLIS else TIMEOUT_MILLIS
        val cancel = timer.schedule(timeout) { expire(requestId) }
        pending[requestId] = Pending(deviceId, actionId, cancel)
        publishRunning()
        report(deviceId, actionId, MacActionOutcome.RUNNING)
        if (!send(deviceId, "actions.run", payload)) {
            pending.remove(requestId)?.cancel?.invoke()
            publishRunning()
            return report(deviceId, actionId, MacActionOutcome.NOT_SENT)
        }
        return true
    }

    /** An `actions.catalog` or `actions.result` plaintext from [deviceId] (already decrypted and replay-checked). */
    @Synchronized fun receive(deviceId: String, kind: String, payload: JSONObject) {
        when (kind) {
            "actions.catalog" -> {
                if (!available(deviceId)) return
                val catalog = parseMacActionCatalog(payload) ?: return
                setCatalog(deviceId, catalog)
                mutableLive.value = mutableLive.value + deviceId
                // Runs for entries the Mac no longer lists will be refused; let them time out normally.
            }
            "actions.result" -> {
                val result = parseMacActionResult(payload) ?: return
                val run = pending[result.requestId] ?: return
                if (run.deviceId != deviceId || result.action != run.actionId) return
                pending.remove(result.requestId)
                run.cancel()
                publishRunning()
                result.volume?.let { volume ->
                    mutableCatalogs.value[deviceId]?.let { setCatalog(deviceId, it.copy(volume = volume)) }
                }
                report(deviceId, run.actionId, if (result.done) MacActionOutcome.DONE else MacActionOutcome.REFUSED, result.reason)
            }
        }
    }

    /** [deviceId]'s session ended: its runs are not confirmed, its catalog stays for offline display. */
    @Synchronized fun sessionEnded(deviceId: String) {
        mutableLive.value = mutableLive.value - deviceId
        endPending(deviceId)
    }

    /**
     * Mac actions is no longer available with [deviceId] (turned off here, or the Mac's map says
     * false): pending runs end and its catalog is forgotten, so controls and widgets stop offering it.
     */
    @Synchronized fun revoked(deviceId: String) {
        mutableLive.value = mutableLive.value - deviceId
        endPending(deviceId)
        setCatalog(deviceId, null)
    }

    /** Forgotten Mac. */
    fun forget(deviceId: String) = revoked(deviceId)

    /** Every session ended (Bridgey turned off). */
    @Synchronized fun reset() {
        mutableLive.value.forEach(::endPending)
        mutableLive.value = emptySet()
    }

    private fun endPending(deviceId: String) {
        val ended = pending.filterValues { it.deviceId == deviceId }
        ended.forEach { (id, run) ->
            pending.remove(id)
            run.cancel()
            report(deviceId, run.actionId, MacActionOutcome.NOT_CONFIRMED)
        }
        if (ended.isNotEmpty()) publishRunning()
    }

    @Synchronized private fun expire(requestId: String) {
        val run = pending.remove(requestId) ?: return
        publishRunning()
        report(run.deviceId, run.actionId, MacActionOutcome.NOT_CONFIRMED)
    }

    private fun setCatalog(deviceId: String, catalog: MacActionCatalog?) {
        mutableCatalogs.value = if (catalog == null) mutableCatalogs.value - deviceId else mutableCatalogs.value + (deviceId to catalog)
        store.save(deviceId, catalog)
    }

    private fun publishRunning() {
        mutableRunning.value = pending.values.map { it.deviceId to it.actionId }.toSet()
    }

    private fun report(deviceId: String, actionId: String, outcome: MacActionOutcome, reason: String? = null): Boolean {
        serial += 1
        mutableStatus.value = MacActionStatus(deviceId, actionId, outcome, reason, serial)
        return outcome == MacActionOutcome.RUNNING
    }

    companion object {
        const val TIMEOUT_MILLIS = 10_000L
        const val SHORTCUT_TIMEOUT_MILLIS = 70_000L
        const val MAX_CATALOG_BYTES = 8_192
        const val MAX_RESULT_BYTES = 1_024
    }
}
