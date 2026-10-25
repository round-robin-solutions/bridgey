package dev.bridgey.android.activity

import java.io.File
import java.util.concurrent.Executor
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** The filter chips on Home. */
enum class ActivityCategory { CLIPBOARD, FILES, ALERTS, CALLS, OTHER }

/**
 * What happened. Clipboard events keep a one-line preview (or "hidden" for sensitive clips),
 * alerts keep the app's name, incoming calls keep the caller when the call notification shows
 * one. Never link addresses, notification titles or text, or phone numbers.
 * [mergeWindowMillis] folds a burst of the same event (same device, app and caller) into one
 * item with a count.
 */
enum class ActivityKind(val key: String, val category: ActivityCategory, val mergeWindowMillis: Long = 0) {
    CLIPBOARD_SENT("clipboard_sent", ActivityCategory.CLIPBOARD),
    CLIPBOARD_RECEIVED("clipboard_received", ActivityCategory.CLIPBOARD),
    CLIPBOARD_RECEIVE_FAILED("clipboard_receive_failed", ActivityCategory.CLIPBOARD),
    FILE_SENT("file_sent", ActivityCategory.FILES),
    FILE_RECEIVED("file_received", ActivityCategory.FILES),
    FILE_FAILED("file_failed", ActivityCategory.FILES),
    LINK_SENT("link_sent", ActivityCategory.OTHER),
    LINK_RECEIVED("link_received", ActivityCategory.OTHER),
    NOTIFICATIONS_SHOWN("notifications_shown", ActivityCategory.ALERTS, mergeWindowMillis = 15 * 60_000L),
    CALL_SHOWN("call_shown", ActivityCategory.CALLS, mergeWindowMillis = 60_000L),
    CALL_STARTED("call_started", ActivityCategory.CALLS),
    PING_SENT("ping_sent", ActivityCategory.OTHER),
    PING_RECEIVED("ping_received", ActivityCategory.OTHER),
    FIND_MAC("find_mac", ActivityCategory.OTHER),
    FIND_PHONE("find_phone", ActivityCategory.OTHER),
    PAIRED("paired", ActivityCategory.OTHER),
    ;

    /** Only file events carry a name: the name of the file the user sent or received. */
    val carriesFileName: Boolean get() = category == ActivityCategory.FILES

    /** Clipboard events carry a text preview; incoming calls the caller. */
    val carriesPreview: Boolean get() = this == CLIPBOARD_SENT || this == CLIPBOARD_RECEIVED || this == CALL_SHOWN

    val carriesAppName: Boolean get() = this == NOTIFICATIONS_SHOWN

    companion object {
        fun fromKey(key: String?): ActivityKind? = entries.firstOrNull { it.key == key }
    }
}

/**
 * One stream item. These fields are the whole record, in memory and on disk; a unit test keeps
 * it that way. Kept out of diagnostics and logs.
 */
data class ActivityItem(
    val id: Long,
    val kind: ActivityKind,
    val deviceId: String?,
    val deviceName: String,
    val fileName: String?,
    /** Clipboard preview (at most 80 characters, one line) or caller. */
    val preview: String?,
    /** Forwarded notifications: the app's name. */
    val appName: String?,
    /** A clip marked sensitive: shown as "Hidden", no text kept. */
    val sensitive: Boolean,
    /** Automatic clipboard moved this item, rather than a manual Send. */
    val automatic: Boolean,
    val count: Int,
    val atMillis: Long,
)

/** One line, whitespace collapsed, at most [ActivityHistory.MAX_PREVIEW_LENGTH] characters ending with an ellipsis when cut. */
fun clipboardPreview(text: String?): String? {
    val line = text?.replace(Regex("\\s+"), " ")?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    if (line.length <= ActivityHistory.MAX_PREVIEW_LENGTH) return line
    var end = ActivityHistory.MAX_PREVIEW_LENGTH - 1
    if (Character.isHighSurrogate(line[end - 1])) end -= 1
    return line.substring(0, end).trimEnd() + "\u2026"
}

/** Bounds and merging, kept pure so they are unit tested. */
object ActivityHistory {
    const val MAX_ITEMS = 200
    const val MAX_AGE_MILLIS = 7L * 24 * 60 * 60 * 1000
    const val MAX_PREVIEW_LENGTH = 80

    /** A clock set back should not leave items stuck on top for days. */
    private const val FUTURE_TOLERANCE_MILLIS = 5L * 60 * 1000
    private const val MAX_NAME_LENGTH = 128
    private const val MAX_FILE_NAME_LENGTH = 255

    fun prune(items: List<ActivityItem>, now: Long): List<ActivityItem> =
        items.asSequence()
            .filter { it.atMillis >= now - MAX_AGE_MILLIS && it.atMillis <= now + FUTURE_TOLERANCE_MILLIS }
            .sortedByDescending { it.atMillis }
            .take(MAX_ITEMS)
            .toList()

    /** Newest first. Returns the new list; [nextId] is used only when a new item is created. */
    fun add(
        items: List<ActivityItem>,
        kind: ActivityKind,
        deviceId: String?,
        deviceName: String,
        fileName: String?,
        now: Long,
        nextId: Long,
        preview: String? = null,
        appName: String? = null,
        sensitive: Boolean = false,
        automatic: Boolean = false,
    ): List<ActivityItem> {
        val isSensitive = sensitive && kind.carriesPreview
        val cleanPreview = if (kind.carriesPreview && !isSensitive) clipboardPreview(preview) else null
        val cleanApp = if (kind.carriesAppName) appName?.trim()?.take(MAX_NAME_LENGTH)?.ifBlank { null } else null
        if (kind.mergeWindowMillis > 0) {
            val match = items.firstOrNull {
                it.kind == kind && it.deviceId == deviceId && it.appName == cleanApp && it.preview == cleanPreview &&
                    now >= it.atMillis && now - it.atMillis <= kind.mergeWindowMillis
            }
            if (match != null) {
                val merged = match.copy(count = match.count + 1, atMillis = now, deviceName = cleanName(deviceName))
                return prune(listOf(merged) + items.filter { it.id != match.id }, now)
            }
        }
        val item = ActivityItem(
            id = nextId,
            kind = kind,
            deviceId = deviceId?.take(64),
            deviceName = cleanName(deviceName),
            fileName = if (kind.carriesFileName) fileName?.trim()?.take(MAX_FILE_NAME_LENGTH)?.ifBlank { null } else null,
            preview = cleanPreview,
            appName = cleanApp,
            sensitive = isSensitive,
            automatic = automatic && kind.category == ActivityCategory.CLIPBOARD,
            count = 1,
            atMillis = now,
        )
        return prune(listOf(item) + items, now)
    }

    private fun cleanName(value: String): String = value.trim().take(MAX_NAME_LENGTH)

    fun encode(items: List<ActivityItem>): String = JSONArray().apply {
        items.forEach { item ->
            put(
                JSONObject()
                    .put("id", item.id)
                    .put("kind", item.kind.key)
                    .put("deviceId", item.deviceId ?: JSONObject.NULL)
                    .put("deviceName", item.deviceName)
                    .put("fileName", item.fileName ?: JSONObject.NULL)
                    .put("preview", item.preview ?: JSONObject.NULL)
                    .put("appName", item.appName ?: JSONObject.NULL)
                    .put("sensitive", item.sensitive)
                    .put("automatic", item.automatic)
                    .put("count", item.count)
                    .put("at", item.atMillis),
            )
        }
    }.toString()

    fun decode(json: String, now: Long): List<ActivityItem> {
        val array = runCatching { JSONArray(json) }.getOrNull() ?: return emptyList()
        val items = (0 until minOf(array.length(), MAX_ITEMS * 2)).mapNotNull { index ->
            val value = array.optJSONObject(index) ?: return@mapNotNull null
            val kind = ActivityKind.fromKey(value.optString("kind")) ?: return@mapNotNull null
            ActivityItem(
                id = value.optLong("id", -1L).takeIf { it >= 0 } ?: return@mapNotNull null,
                kind = kind,
                deviceId = value.optString("deviceId").takeIf { !value.isNull("deviceId") && it.isNotEmpty() }?.take(64),
                deviceName = cleanName(value.optString("deviceName")),
                fileName = if (kind.carriesFileName && !value.isNull("fileName")) {
                    value.optString("fileName").take(MAX_FILE_NAME_LENGTH).ifBlank { null }
                } else {
                    null
                },
                preview = if (kind.carriesPreview && !value.isNull("preview")) clipboardPreview(value.optString("preview")) else null,
                appName = if (kind.carriesAppName && !value.isNull("appName")) value.optString("appName").take(MAX_NAME_LENGTH).ifBlank { null } else null,
                sensitive = kind.carriesPreview && value.optBoolean("sensitive", false),
                automatic = kind.category == ActivityCategory.CLIPBOARD && value.optBoolean("automatic", false),
                count = value.optInt("count", 1).coerceIn(1, 9_999),
                atMillis = value.optLong("at", 0L),
            )
        }
        return prune(items, now)
    }
}

/**
 * The local activity stream: in memory, plus a bounded copy in an owner-only file in the app's
 * no-backup directory (like the Mac app's notification history). Newest first, at most
 * [ActivityHistory.MAX_ITEMS] items, none older than seven days. Cleared from Settings.
 */
class ActivityLog(
    private val file: File?,
    private val io: Executor,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val mutableItems = MutableStateFlow(load())
    val items: StateFlow<List<ActivityItem>> = mutableItems.asStateFlow()
    private var nextId = (mutableItems.value.maxOfOrNull { it.id } ?: 0L) + 1

    @Synchronized
    fun record(
        kind: ActivityKind,
        deviceId: String?,
        deviceName: String,
        fileName: String? = null,
        preview: String? = null,
        appName: String? = null,
        sensitive: Boolean = false,
        automatic: Boolean = false,
    ) {
        val updated = ActivityHistory.add(mutableItems.value, kind, deviceId, deviceName, fileName, clock(), nextId, preview, appName, sensitive, automatic)
        if (updated.any { it.id == nextId }) nextId += 1
        mutableItems.value = updated
        persist(updated)
    }

    /** Drops expired items; called when the stream is shown. */
    @Synchronized
    fun prune() {
        val pruned = ActivityHistory.prune(mutableItems.value, clock())
        if (pruned != mutableItems.value) {
            mutableItems.value = pruned
            persist(pruned)
        }
    }

    @Synchronized
    fun clear() {
        mutableItems.value = emptyList()
        val target = file ?: return
        io.execute { synchronized(fileLock) { target.delete() } }
    }

    private val fileLock = Any()

    private fun load(): List<ActivityItem> {
        val target = file ?: return emptyList()
        return runCatching {
            if (!target.isFile || target.length() > MAX_FILE_BYTES) return emptyList()
            ActivityHistory.decode(target.readText(Charsets.UTF_8), clock())
        }.getOrDefault(emptyList())
    }

    private fun persist(items: List<ActivityItem>) {
        val target = file ?: return
        val json = ActivityHistory.encode(items)
        io.execute {
            synchronized(fileLock) {
                runCatching {
                    target.parentFile?.mkdirs()
                    val temporary = File(target.parentFile, "${target.name}.tmp")
                    temporary.writeText(json, Charsets.UTF_8)
                    ownerOnly(temporary)
                    if (!temporary.renameTo(target)) {
                        target.delete()
                        temporary.renameTo(target)
                    }
                    ownerOnly(target)
                }
            }
        }
    }

    private fun ownerOnly(target: File) {
        target.setReadable(false, false)
        target.setReadable(true, true)
        target.setWritable(false, false)
        target.setWritable(true, true)
        target.setExecutable(false, false)
    }

    companion object {
        const val FILE_NAME = "activity-stream.json"
        private const val MAX_FILE_BYTES = 512L * 1024
    }
}
