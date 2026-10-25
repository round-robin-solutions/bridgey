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
 * What happened. Only the kind is kept: never clipboard text, link addresses, notification
 * titles or text, phone numbers or app names. [mergeWindowMillis] folds a burst of the same
 * event on the same device into one item with a count.
 */
enum class ActivityKind(val key: String, val category: ActivityCategory, val mergeWindowMillis: Long = 0) {
    CLIPBOARD_SENT("clipboard_sent", ActivityCategory.CLIPBOARD),
    CLIPBOARD_RECEIVED("clipboard_received", ActivityCategory.CLIPBOARD),
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

    companion object {
        fun fromKey(key: String?): ActivityKind? = entries.firstOrNull { it.key == key }
    }
}

/**
 * One stream item. These fields are the whole record, in memory and on disk; a unit test keeps
 * it that way.
 */
data class ActivityItem(
    val id: Long,
    val kind: ActivityKind,
    val deviceId: String?,
    val deviceName: String,
    val fileName: String?,
    val count: Int,
    val atMillis: Long,
)

/** Bounds and merging, kept pure so they are unit tested. */
object ActivityHistory {
    const val MAX_ITEMS = 200
    const val MAX_AGE_MILLIS = 7L * 24 * 60 * 60 * 1000

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
    ): List<ActivityItem> {
        val newest = items.firstOrNull()
        if (
            newest != null && kind.mergeWindowMillis > 0 && newest.kind == kind && newest.deviceId == deviceId &&
            now >= newest.atMillis && now - newest.atMillis <= kind.mergeWindowMillis
        ) {
            val merged = newest.copy(count = newest.count + 1, atMillis = now, deviceName = cleanName(deviceName))
            return prune(listOf(merged) + items.drop(1), now)
        }
        val item = ActivityItem(
            id = nextId,
            kind = kind,
            deviceId = deviceId?.take(64),
            deviceName = cleanName(deviceName),
            fileName = if (kind.carriesFileName) fileName?.trim()?.take(MAX_FILE_NAME_LENGTH)?.ifBlank { null } else null,
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
    fun record(kind: ActivityKind, deviceId: String?, deviceName: String, fileName: String? = null) {
        val updated = ActivityHistory.add(mutableItems.value, kind, deviceId, deviceName, fileName, clock(), nextId)
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
