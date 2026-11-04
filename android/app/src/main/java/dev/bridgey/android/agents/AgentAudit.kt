package dev.bridgey.android.agents

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** Actions in the activity list (docs/protocol.md, agent devices, Audit). */
object AuditAction {
    const val PAIR = "pair"
    const val GRANT_CHANGE = "grant.change"
    const val GRANT_REQUEST = "grant.request"
    const val GRANT_EXPIRED = "grant.expired"
    const val NOTIFY = "notify"
    const val ASK = "ask"
    const val ANSWER = "answer"
    const val RING = "ring"
    const val PING = "ping"
    const val BATTERY = "battery"
    const val CLIPBOARD_SET = "clipboard.set"
    const val CLIPBOARD_REQUEST = "clipboard.request"
    const val FILES_RECEIVE = "files.receive"
    const val CODES_READ = "codes.read"
    const val CODES_DETECT = "codes.detect"
    const val FORGET = "forget"
}

object AuditOutcome {
    const val OK = "ok"
    const val DELIVERED = "delivered"
    const val DECLINED = "declined"
    const val DISMISSED = "dismissed"
    const val EXPIRED = "expired"
    const val RATE_LIMITED = "rate_limited"
    const val NOT_GRANTED = "not_granted"
    const val INVALID = "invalid"
    fun answered(option: String) = "answered:$option"
}

/** One entry: never clipboard content, answer text, codes or notification text. [detail] at most 120 characters. */
data class AuditEntry(val at: Long, val action: String, val outcome: String, val detail: String? = null)

internal fun auditJson(entry: AuditEntry): JSONObject = JSONObject()
    .put("at", entry.at)
    .put("action", entry.action)
    .put("outcome", entry.outcome)
    .apply { entry.detail?.let { put("detail", it) } }

const val AUDIT_MAX_ENTRIES = 2_000
const val AUDIT_MAX_AGE_MILLIS = 90L * 24 * 3_600_000
const val AUDIT_DETAIL_MAX_CHARS = 120

/**
 * The activity list per agent device: at most 2,000 entries or 90 days, one owner-only file per device in
 * no-backup storage (excluded from backups and device transfer by data_extraction_rules, and never part of the
 * diagnostics export). Files are named by a hash of the device ID.
 */
class AgentAuditLog(private val directory: File, private val clock: () -> Long = System::currentTimeMillis) {
    private val cache = HashMap<String, MutableList<AuditEntry>>()

    private fun file(deviceId: String): File {
        val hash = MessageDigest.getInstance("SHA-256").digest(deviceId.toByteArray()).joinToString("") { "%02x".format(it) }.take(32)
        return File(directory, "$hash.json")
    }

    private fun load(deviceId: String): MutableList<AuditEntry> = cache.getOrPut(deviceId) {
        val text = runCatching { file(deviceId).takeIf { it.isFile }?.readText() }.getOrNull() ?: return@getOrPut ArrayList()
        val list = runCatching { JSONArray(text) }.getOrNull() ?: return@getOrPut ArrayList()
        (0 until list.length()).mapNotNull { index ->
            val entry = list.optJSONObject(index) ?: return@mapNotNull null
            AuditEntry(entry.optLong("at"), entry.optString("action"), entry.optString("outcome"), entry.optString("detail").takeIf { entry.has("detail") })
        }.toMutableList()
    }

    @Synchronized fun record(deviceId: String, action: String, outcome: String, detail: String? = null): AuditEntry {
        val now = clock()
        val entry = AuditEntry(now, action, outcome, detail?.let { cleanAgentText(it) }?.let { if (it.codePointCount(0, it.length) > AUDIT_DETAIL_MAX_CHARS) it.take(AUDIT_DETAIL_MAX_CHARS) else it }?.ifEmpty { null })
        val list = load(deviceId)
        list += entry
        trim(list, now)
        write(deviceId, list)
        return entry
    }

    private fun trim(list: MutableList<AuditEntry>, now: Long) {
        list.removeAll { now - it.at > AUDIT_MAX_AGE_MILLIS }
        while (list.size > AUDIT_MAX_ENTRIES) list.removeAt(0)
    }

    /** Newest first. */
    @Synchronized fun entries(deviceId: String): List<AuditEntry> {
        val list = load(deviceId)
        trim(list, clock())
        return list.asReversed().toList()
    }

    /** The export: the device and every entry, oldest first, as pretty JSON. */
    @Synchronized fun exportJson(deviceId: String, deviceName: String): String = JSONObject()
        .put("device", JSONObject().put("id", deviceId).put("name", deviceName))
        .put("exportedAt", clock())
        .put("entries", JSONArray(load(deviceId).map(::auditJson)))
        .toString(2)

    @Synchronized fun clear(deviceId: String) {
        cache[deviceId] = ArrayList()
        runCatching { file(deviceId).delete() }
    }

    private fun write(deviceId: String, list: List<AuditEntry>) {
        runCatching {
            directory.mkdirs()
            val target = file(deviceId)
            val temporary = File(directory, target.name + ".tmp")
            temporary.writeText(JSONArray(list.map(::auditJson)).toString())
            ownerOnly(temporary)
            if (!temporary.renameTo(target)) temporary.delete()
        }
    }
}

/** Readable and writable by this app's user only. */
internal fun ownerOnly(file: File) {
    file.setReadable(false, false)
    file.setWritable(false, false)
    file.setReadable(true, true)
    file.setWritable(true, true)
}
