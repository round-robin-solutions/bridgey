package dev.bridgey.android.agents

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

enum class AskState { OPEN, ANSWERED, DISMISSED, EXPIRED, CANCELLED }

/** One question from an agent and how it ended. The answer text stays only until [keepUntil], never in logs. */
data class AskRecord(
    val deviceId: String,
    val askId: String,
    val title: String,
    val body: String?,
    val options: List<AskOption>,
    val allowText: Boolean,
    val textHint: String?,
    val requireUnlock: Boolean,
    val expiresAt: Long,
    val from: String?,
    val postedAt: Long,
    /** The notification's ID (stable per ask). */
    val notificationId: Int,
    val state: AskState = AskState.OPEN,
    val option: String? = null,
    val text: String? = null,
    val endedAt: Long? = null,
) {
    /** Kept 24 hours after it ends, so an agent that was offline still hears the ending. */
    val keepUntil: Long get() = (endedAt ?: expiresAt) + ASK_KEEP_MILLIS
}

const val ASK_KEEP_MILLIS = 24L * 3_600_000
const val ASKS_PENDING_PER_AGENT = 3
const val ASKS_PENDING_ON_PHONE = 10

/**
 * The agents' questions: open ones (at most 3 per agent and 10 on the phone), and ended ones for 24 hours, so
 * the ending is sent again at each session start until then. A repeated askId never posts twice. Stored in
 * no-backup storage, owner-only.
 */
class AgentAskBook(private val file: File?, private val clock: () -> Long = System::currentTimeMillis) {
    private val asks = LinkedHashMap<String, AskRecord>()

    init {
        load()
        prune()
    }

    private fun key(deviceId: String, askId: String) = "$deviceId/$askId"

    @Synchronized fun get(deviceId: String, askId: String): AskRecord? = asks[key(deviceId, askId)]

    @Synchronized fun byNotification(notificationId: Int): AskRecord? = asks.values.firstOrNull { it.notificationId == notificationId }

    @Synchronized fun openCount(deviceId: String? = null): Int =
        asks.values.count { it.state == AskState.OPEN && (deviceId == null || it.deviceId == deviceId) }

    @Synchronized fun open(): List<AskRecord> = asks.values.filter { it.state == AskState.OPEN }

    @Synchronized fun add(record: AskRecord) {
        asks[key(record.deviceId, record.askId)] = record
        save()
    }

    /** Ends an open ask; returns the ended record, or null when it was not open. */
    @Synchronized fun end(deviceId: String, askId: String, state: AskState, option: String? = null, text: String? = null): AskRecord? {
        val current = asks[key(deviceId, askId)]?.takeIf { it.state == AskState.OPEN } ?: return null
        val ended = current.copy(state = state, option = option, text = text, endedAt = clock())
        asks[key(deviceId, askId)] = ended
        save()
        return ended
    }

    /** Open asks whose expiry passed. */
    @Synchronized fun expiredOpen(now: Long = clock()): List<AskRecord> = asks.values.filter { it.state == AskState.OPEN && now >= it.expiresAt }

    /** Ended asks of [deviceId] still within 24 hours: their ending goes again at the session start. */
    @Synchronized fun endedFor(deviceId: String): List<AskRecord> {
        prune()
        return asks.values.filter { it.deviceId == deviceId && it.state != AskState.OPEN && it.state != AskState.CANCELLED }
    }

    @Synchronized fun nextExpiry(): Long? = asks.values.filter { it.state == AskState.OPEN }.minOfOrNull { it.expiresAt }

    @Synchronized fun forget(deviceId: String): List<AskRecord> {
        val gone = asks.values.filter { it.deviceId == deviceId }
        gone.forEach { asks.remove(key(it.deviceId, it.askId)) }
        save()
        return gone
    }

    private fun prune() {
        val now = clock()
        if (asks.values.removeAll { it.state != AskState.OPEN && now > it.keepUntil }) save()
    }

    private fun load() {
        val text = runCatching { file?.takeIf { it.isFile }?.readText() }.getOrNull() ?: return
        val list = runCatching { JSONArray(text) }.getOrNull() ?: return
        for (index in 0 until list.length()) {
            val entry = list.optJSONObject(index) ?: continue
            val record = runCatching { decodeAsk(entry) }.getOrNull() ?: continue
            asks[key(record.deviceId, record.askId)] = record
        }
    }

    private fun save() {
        val target = file ?: return
        runCatching {
            target.parentFile?.mkdirs()
            val temporary = File(target.parentFile, target.name + ".tmp")
            temporary.writeText(JSONArray(asks.values.map(::encodeAsk)).toString())
            ownerOnly(temporary)
            if (!temporary.renameTo(target)) temporary.delete()
        }
    }
}

private fun encodeAsk(record: AskRecord): JSONObject = JSONObject()
    .put("deviceId", record.deviceId)
    .put("askId", record.askId)
    .put("title", record.title)
    .put("options", JSONArray(record.options.map { JSONObject().put("id", it.id).put("label", it.label) }))
    .put("allowText", record.allowText)
    .put("requireUnlock", record.requireUnlock)
    .put("expiresAt", record.expiresAt)
    .put("postedAt", record.postedAt)
    .put("notificationId", record.notificationId)
    .put("state", record.state.name)
    .apply {
        record.body?.let { put("body", it) }
        record.textHint?.let { put("textHint", it) }
        record.from?.let { put("from", it) }
        record.option?.let { put("option", it) }
        record.text?.let { put("text", it) }
        record.endedAt?.let { put("endedAt", it) }
    }

private fun decodeAsk(entry: JSONObject): AskRecord {
    fun optional(name: String): String? = if (entry.has(name)) entry.getString(name) else null
    val options = entry.getJSONArray("options").let { list ->
        (0 until list.length()).map { list.getJSONObject(it).let { option -> AskOption(option.getString("id"), option.getString("label")) } }
    }
    return AskRecord(
        deviceId = entry.getString("deviceId"),
        askId = entry.getString("askId"),
        title = entry.getString("title"),
        body = optional("body"),
        options = options,
        allowText = entry.getBoolean("allowText"),
        textHint = optional("textHint"),
        requireUnlock = entry.getBoolean("requireUnlock"),
        expiresAt = entry.getLong("expiresAt"),
        from = optional("from"),
        postedAt = entry.getLong("postedAt"),
        notificationId = entry.getInt("notificationId"),
        state = AskState.valueOf(entry.getString("state")),
        option = optional("option"),
        text = optional("text"),
        endedAt = if (entry.has("endedAt")) entry.getLong("endedAt") else null,
    )
}
