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

    /** A copy on this phone, offered to the other device (images, files, long text). */
    CLIP_OFFER_SENT("clip_offer_sent", ActivityCategory.CLIPBOARD),

    /** A copy on the other device, ready to paste here. */
    CLIP_OFFER_RECEIVED("clip_offer_received", ActivityCategory.CLIPBOARD),

    /** An item moved when it was pasted here. A burst from one paste folds into one item. */
    CLIP_PASTED("clip_pasted", ActivityCategory.CLIPBOARD, mergeWindowMillis = 60_000L),
    CLIP_PASTE_FAILED("clip_paste_failed", ActivityCategory.CLIPBOARD, mergeWindowMillis = 60_000L),

    /** A whole folder: name in fileName, plus file count, bytes, destination and a detail line (3.5). */
    FOLDER_SENT("folder_sent", ActivityCategory.FILES),
    FOLDER_RECEIVED("folder_received", ActivityCategory.FILES),
    FOLDER_INCOMPLETE("folder_incomplete", ActivityCategory.FILES),

    /**
     * Update all devices automatically (keys shared with the Mac; older readers drop unknown kinds). The
     * content is a short token: the version for done, the busy key for waiting, the skip reason for
     * skipped, the run failure for failed. deviceId null means this phone.
     */
    UPDATE_AUTO_DONE("update_auto_done", ActivityCategory.OTHER),
    UPDATE_AUTO_WAITING("update_auto_waiting", ActivityCategory.OTHER),
    UPDATE_AUTO_SKIPPED("update_auto_skipped", ActivityCategory.OTHER),
    UPDATE_AUTO_STARTED_BY("update_auto_started_by", ActivityCategory.OTHER),
    UPDATE_AUTO_FAILED("update_auto_failed", ActivityCategory.OTHER),
    /** Settings sync: a paired device changed settings here. The changes are tokens in detail ([SyncDetail]). */
    SETTINGS_SYNCED("settings_synced", ActivityCategory.OTHER),
    ;

    val isFolder: Boolean get() = this == FOLDER_SENT || this == FOLDER_RECEIVED || this == FOLDER_INCOMPLETE

    /** Update all devices automatically: a version, a busy key, a skip reason or a failure in [ActivityItem.content]. */
    val isAutoUpdate: Boolean
        get() = this == UPDATE_AUTO_DONE || this == UPDATE_AUTO_WAITING || this == UPDATE_AUTO_SKIPPED || this == UPDATE_AUTO_STARTED_BY || this == UPDATE_AUTO_FAILED

    /** Clipboard offers: what moved (text, image or file), how many and how big. */
    val isClipOffer: Boolean get() = this == CLIP_OFFER_SENT || this == CLIP_OFFER_RECEIVED || this == CLIP_PASTED || this == CLIP_PASTE_FAILED

    /** File events carry the file's name; clipboard offers the name of a single file, when previews are on. */
    val carriesFileName: Boolean get() = category == ActivityCategory.FILES || isClipOffer

    /** Clipboard events carry a text preview; incoming calls the caller. */
    val carriesPreview: Boolean get() = this == CLIPBOARD_SENT || this == CLIPBOARD_RECEIVED || this == CALL_SHOWN

    val carriesAppName: Boolean get() = this == NOTIFICATIONS_SHOWN

    /** The detail field: folder tokens, or settings sync tokens. */
    fun cleanDetail(value: String?): String? = when {
        isFolder -> FolderDetail.clean(value)
        this == SETTINGS_SYNCED -> dev.bridgey.android.sync.SyncDetail.clean(value)
        else -> null
    }

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
    /** Clipboard offers: total size in bytes. */
    val bytes: Long? = null,
    /** Clipboard offers: "text", "image" or "file". Automatic updates: a version or a short key ([ActivityKind.isAutoUpdate]). */
    val content: String? = null,
    /** Folders: how many files were saved (or sent). */
    val fileCount: Int? = null,
    /** Folders: display path of where it landed ("Pictures/Trip"), at most 128 characters. */
    val destination: String? = null,
    /**
     * Folders: what the detail line says, as tokens without names ("merged=12,links=3,failed=2", "timeout").
     * See [FolderDetail]. Settings synced: the changes as tokens ("calls=1,reduce_motion=0"), see SyncDetail.
     */
    val detail: String? = null,
)

/** The folder detail tokens (3.5): counts and states only, never names. */
object FolderDetail {
    const val MERGED = "merged"
    const val REPLACED = "replaced"
    const val SAVED_AS_COPY = "saved_as_copy"
    const val LINKS = "links"
    const val HIDDEN = "hidden"
    const val SYSTEM = "system"
    const val OTHER_SKIPPED = "skipped"
    const val FAILED = "failed"
    const val EMPTY_SKIPPED = "empty_skipped"
    const val CANCELLED = "cancelled"
    const val CONNECTION_LOST = "connection_lost"
    const val TIMEOUT = "timeout"
    const val LOST_ACCESS = "lost_access"
    const val NO_SPACE = "no_space"

    private val pattern = Regex("^[a-z_]{1,24}(=[0-9]{1,7})?(,[a-z_]{1,24}(=[0-9]{1,7})?){0,15}$")

    fun encode(tokens: List<Pair<String, Int?>>): String? =
        tokens.joinToString(",") { (key, count) -> if (count == null) key else "$key=$count" }.takeIf { it.isNotEmpty() && pattern.matches(it) }

    fun decode(value: String?): List<Pair<String, Int?>> {
        if (value == null || !pattern.matches(value)) return emptyList()
        return value.split(',').map { token -> token.substringBefore('=') to token.substringAfter('=', "").toIntOrNull() }
    }

    fun clean(value: String?): String? = value?.takeIf { pattern.matches(it) }
}

/** The content kinds a clipboard offer item can record. */
internal val ClipContents = setOf("text", "image", "file")

/** An automatic update's token: a version name ("0.10.0-rr.1-beta.11") or a key ("call", "remote_off"). Never free text. */
private val AutoUpdateContent = Regex("^[A-Za-z0-9._+-]{1,64}$")

/** The content an item of [kind] may keep. */
internal fun cleanContent(kind: ActivityKind, content: String?): String? = when {
    kind.isClipOffer -> content?.takeIf { it in ClipContents }
    kind.isAutoUpdate -> content?.takeIf { AutoUpdateContent.matches(it) }
    else -> null
}

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
    private const val MAX_DESTINATION_LENGTH = 128

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
        bytes: Long? = null,
        content: String? = null,
        itemCount: Int = 1,
        fileCount: Int? = null,
        destination: String? = null,
        detail: String? = null,
    ): List<ActivityItem> {
        val isSensitive = sensitive && kind.carriesPreview
        val cleanPreview = if (kind.carriesPreview && !isSensitive) clipboardPreview(preview) else null
        val cleanApp = if (kind.carriesAppName) appName?.trim()?.take(MAX_NAME_LENGTH)?.ifBlank { null } else null
        val cleanBytes = if (kind.isClipOffer || kind.isFolder) bytes?.coerceAtLeast(0) else null
        val cleanContent = cleanContent(kind, content)
        val cleanCount = if (kind.isClipOffer) itemCount.coerceIn(1, 9_999) else 1
        if (kind.isClipOffer && kind.mergeWindowMillis > 0) {
            val newest = items.firstOrNull()
            if (newest != null && newest.kind == kind && newest.deviceId == deviceId &&
                now >= newest.atMillis && now - newest.atMillis <= kind.mergeWindowMillis
            ) {
                val merged = newest.copy(
                    count = (newest.count + cleanCount).coerceAtMost(9_999),
                    bytes = if (newest.bytes == null || cleanBytes == null) null else newest.bytes + cleanBytes,
                    content = if (newest.content == cleanContent) cleanContent else "file",
                    fileName = null,
                    atMillis = now,
                    deviceName = cleanName(deviceName),
                )
                return prune(listOf(merged) + items.drop(1), now)
            }
        } else if (kind.mergeWindowMillis > 0) {
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
            count = cleanCount,
            atMillis = now,
            bytes = cleanBytes,
            content = cleanContent,
            fileCount = if (kind.isFolder) fileCount?.coerceIn(0, 1_000_000) else null,
            destination = if (kind.isFolder) destination?.trim()?.take(MAX_DESTINATION_LENGTH)?.ifBlank { null } else null,
            detail = kind.cleanDetail(detail),
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
                    .put("at", item.atMillis)
                    .put("bytes", item.bytes ?: JSONObject.NULL)
                    .put("content", item.content ?: JSONObject.NULL)
                    .put("fileCount", item.fileCount ?: JSONObject.NULL)
                    .put("destination", item.destination ?: JSONObject.NULL)
                    .put("detail", item.detail ?: JSONObject.NULL),
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
                bytes = if ((kind.isClipOffer || kind.isFolder) && !value.isNull("bytes") && value.has("bytes")) value.optLong("bytes", -1L).takeIf { it >= 0 } else null,
                content = if (!value.isNull("content") && value.has("content")) cleanContent(kind, value.optString("content")) else null,
                fileCount = if (kind.isFolder && value.has("fileCount") && !value.isNull("fileCount")) value.optInt("fileCount", -1).takeIf { it >= 0 } else null,
                destination = if (kind.isFolder && value.has("destination") && !value.isNull("destination")) {
                    value.optString("destination").take(MAX_DESTINATION_LENGTH).ifBlank { null }
                } else {
                    null
                },
                detail = if (value.has("detail") && !value.isNull("detail")) kind.cleanDetail(value.optString("detail")) else null,
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
        bytes: Long? = null,
        content: String? = null,
        itemCount: Int = 1,
        fileCount: Int? = null,
        destination: String? = null,
        detail: String? = null,
    ) {
        val updated = ActivityHistory.add(
            mutableItems.value, kind, deviceId, deviceName, fileName, clock(), nextId, preview, appName, sensitive, automatic,
            bytes, content, itemCount, fileCount, destination, detail,
        )
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
