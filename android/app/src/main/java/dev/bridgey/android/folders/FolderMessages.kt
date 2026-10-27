package dev.bridgey.android.folders

import org.json.JSONArray
import org.json.JSONObject

/**
 * Payloads of the draft folders and places messages (section 4.5). Each is the decrypted JSON of one
 * encrypted message. `parse` returns null when a payload decrypts but is invalid; the caller answers with an
 * error and keeps the session (4.2). Unknown fields are ignored. macOS: FolderMessages.swift, same fields.
 */
object FolderKinds {
    const val PLACES_LIST = "places.list"
    const val PLACES_LISTED = "places.listed"
    const val PLACES_BROWSE = "places.browse"
    const val PLACES_CHILDREN = "places.children"
    const val PLACES_CREATE_FOLDER = "places.create_folder"
    const val PLACES_FOLDER_CREATED = "places.folder_created"
    const val PLACES_ERROR = "places.error"
    const val OFFER = "folders.offer"
    const val MANIFEST = "folders.manifest"
    const val WAITING = "folders.waiting"
    const val CONFLICT = "folders.conflict"
    const val RESOLVE = "folders.resolve"
    const val ACCEPT = "folders.accept"
    const val REJECTED = "folders.rejected"
    const val ENTRY_FAILED = "folders.entry_failed"
    const val COMPLETE = "folders.complete"
    const val RESULT = "folders.result"
    const val CANCEL = "folders.cancel"
    const val CANCEL_ACK = "folders.cancel.ack"

    val placesKinds = setOf(PLACES_LIST, PLACES_LISTED, PLACES_BROWSE, PLACES_CHILDREN, PLACES_CREATE_FOLDER, PLACES_FOLDER_CREATED, PLACES_ERROR)
    val folderKinds = setOf(OFFER, MANIFEST, WAITING, CONFLICT, RESOLVE, ACCEPT, REJECTED, ENTRY_FAILED, COMPLETE, RESULT, CANCEL, CANCEL_ACK)

    /** Plaintext limit per kind (4.2). */
    fun plaintextLimit(kind: String): Int = when (kind) {
        MANIFEST, COMPLETE, RESULT, PLACES_LISTED, PLACES_CHILDREN -> FolderLimits.LARGE_PLAINTEXT
        else -> FolderLimits.SMALL_PLAINTEXT
    }
}

const val FOLDER_PROTOCOL_VERSION = 1

private val uuidPattern = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
private val placeIdPattern = Regex("^[A-Za-z0-9_-]{22}$")

fun isWireId(value: String?): Boolean = value != null && uuidPattern.matches(value)

fun isPlaceId(value: String?): Boolean = value == DEFAULT_PLACE_ID || (value != null && placeIdPattern.matches(value))

const val DEFAULT_PLACE_ID = "default"

private fun JSONObject.stringOrNull(key: String): String? = if (has(key) && !isNull(key)) opt(key) as? String else null
private fun JSONObject.longOrNull(key: String): Long? = if (has(key) && !isNull(key)) (opt(key) as? Number)?.toLong() else null
private fun JSONObject.intOrNull(key: String): Int? = longOrNull(key)?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()
private fun JSONObject.versionOk(): Boolean = longOrNull("version") == FOLDER_PROTOCOL_VERSION.toLong()
private fun Any?.orNull(): Any = this ?: JSONObject.NULL

/** Destination mode of the receiving device (3.2). */
enum class DestinationMode(val wire: String) {
    SENDER_PICKS("sender_picks"), RECEIVER_ASKS("receiver_asks"), FIXED("fixed");

    companion object {
        fun fromWire(value: String?): DestinationMode? = entries.firstOrNull { it.wire == value }
    }
}

/** "When a folder already exists" (3.3). */
enum class ConflictPolicy(val wire: String) {
    ASK("ask"), MERGE("merge"), REPLACE("replace"), NEW_FOLDER("new_folder");

    companion object {
        fun fromWire(value: String?): ConflictPolicy? = entries.firstOrNull { it.wire == value }
    }
}

/** An answer to the conflict question, and the `choice` field of folders.accept. */
enum class ConflictChoice(val wire: String) {
    NONE("none"), MERGE("merge"), REPLACE("replace"), NEW_FOLDER("new_folder"), CANCEL("cancel");

    companion object {
        fun fromWire(value: String?): ConflictChoice? = entries.firstOrNull { it.wire == value }
    }
}

data class PlacesListPayload(val requestId: String) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("requestId", requestId)

    companion object {
        fun parse(json: JSONObject): PlacesListPayload? {
            if (!json.versionOk()) return null
            return PlacesListPayload(json.stringOrNull("requestId")?.takeIf(::isWireId) ?: return null)
        }
    }
}

data class PlaceInfo(val placeId: String, val label: String, val available: Boolean, val freeBytes: Long?) {
    fun toJson(): JSONObject = JSONObject().put("placeId", placeId).put("label", label.take(FolderLimits.MAX_LABEL_CHARS))
        .put("available", available).put("freeBytes", freeBytes.orNull())

    companion object {
        fun parse(json: JSONObject): PlaceInfo? = PlaceInfo(
            json.stringOrNull("placeId")?.takeIf(::isPlaceId) ?: return null,
            json.stringOrNull("label")?.take(FolderLimits.MAX_LABEL_CHARS) ?: return null,
            json.opt("available") as? Boolean ?: return null,
            json.longOrNull("freeBytes"),
        )
    }
}

data class PlacesListedPayload(
    val requestId: String,
    val mode: DestinationMode,
    val places: List<PlaceInfo>,
    val fixedLabel: String?,
    /** Free bytes where something sent now lands by default (the default folder in `fixed` mode), in every mode. */
    val defaultFreeBytes: Long? = null,
) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("requestId", requestId).put("mode", mode.wire)
        .put("places", JSONArray().apply { places.forEach { put(it.toJson()) } })
        .put("fixedLabel", fixedLabel?.take(FolderLimits.MAX_DESTINATION_LABEL_CHARS).orNull())
        .put("defaultFreeBytes", defaultFreeBytes.orNull())

    companion object {
        fun parse(json: JSONObject): PlacesListedPayload? {
            if (!json.versionOk()) return null
            val array = json.optJSONArray("places") ?: JSONArray()
            if (array.length() > FolderLimits.MAX_PLACES + 1) return null
            return PlacesListedPayload(
                json.stringOrNull("requestId")?.takeIf(::isWireId) ?: return null,
                DestinationMode.fromWire(json.stringOrNull("mode")) ?: return null,
                (0 until array.length()).map { PlaceInfo.parse(array.optJSONObject(it) ?: return null) ?: return null },
                json.stringOrNull("fixedLabel"),
                json.longOrNull("defaultFreeBytes"),
            )
        }
    }
}

data class PlacesBrowsePayload(val requestId: String, val placeId: String, val path: String, val cursor: String?) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("requestId", requestId).put("placeId", placeId)
        .put("path", path).put("cursor", cursor.orNull())

    companion object {
        fun parse(json: JSONObject): PlacesBrowsePayload? {
            if (!json.versionOk()) return null
            val path = json.stringOrNull("path") ?: return null
            if (!FolderPaths.isValidExistingPath(path)) return null
            return PlacesBrowsePayload(
                json.stringOrNull("requestId")?.takeIf(::isWireId) ?: return null,
                json.stringOrNull("placeId")?.takeIf(::isPlaceId) ?: return null,
                path,
                json.stringOrNull("cursor")?.take(64),
            )
        }
    }
}

data class PlacesChildrenPayload(
    val requestId: String,
    val placeId: String,
    val path: String,
    val folders: List<String>,
    val fileCount: Int,
    val folderCount: Int,
    val nextCursor: String?,
) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("requestId", requestId).put("placeId", placeId).put("path", path)
        .put("folders", JSONArray(folders)).put("fileCount", fileCount).put("folderCount", folderCount).put("nextCursor", nextCursor.orNull())

    companion object {
        fun parse(json: JSONObject): PlacesChildrenPayload? {
            if (!json.versionOk()) return null
            val array = json.optJSONArray("folders") ?: return null
            if (array.length() > FolderLimits.MAX_BROWSE_NAMES) return null
            return PlacesChildrenPayload(
                json.stringOrNull("requestId")?.takeIf(::isWireId) ?: return null,
                json.stringOrNull("placeId")?.takeIf(::isPlaceId) ?: return null,
                json.stringOrNull("path") ?: return null,
                (0 until array.length()).map { array.opt(it) as? String ?: return null },
                json.intOrNull("fileCount") ?: 0,
                json.intOrNull("folderCount") ?: 0,
                json.stringOrNull("nextCursor"),
            )
        }
    }
}

data class PlacesCreateFolderPayload(val requestId: String, val placeId: String, val path: String, val name: String) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("requestId", requestId).put("placeId", placeId).put("path", path).put("name", name)

    companion object {
        /** Null for a malformed payload. A name that is not portable parses, so the receiver can answer invalid_name. */
        fun parse(json: JSONObject): PlacesCreateFolderPayload? {
            if (!json.versionOk()) return null
            val path = json.stringOrNull("path") ?: return null
            if (!FolderPaths.isValidExistingPath(path)) return null
            return PlacesCreateFolderPayload(
                json.stringOrNull("requestId")?.takeIf(::isWireId) ?: return null,
                json.stringOrNull("placeId")?.takeIf(::isPlaceId) ?: return null,
                path,
                json.stringOrNull("name") ?: return null,
            )
        }
    }
}

/** places.folder_created repeats the create request's fields. */
fun placesFolderCreatedJson(request: PlacesCreateFolderPayload): JSONObject = request.toJson()

fun placesErrorJson(requestId: String, code: String): JSONObject = JSONObject().put("version", 1).put("requestId", requestId).put("code", code)

data class FolderDestination(val placeId: String, val path: String) {
    fun toJson(): JSONObject = JSONObject().put("placeId", placeId).put("path", path)

    companion object {
        fun parse(json: JSONObject): FolderDestination? {
            val path = json.stringOrNull("path") ?: return null
            if (!FolderPaths.isValidExistingPath(path)) return null
            return FolderDestination(json.stringOrNull("placeId")?.takeIf(::isPlaceId) ?: return null, path)
        }
    }
}

/** What the sender left out, for the receiver's activity item. Unknown counters are ignored. */
data class SkippedCounts(
    val links: Int = 0,
    val hidden: Int = 0,
    val system: Int = 0,
    val unreadable: Int = 0,
    val tooLarge: Int = 0,
    val notDownloaded: Int = 0,
    val tooLong: Int = 0,
    val other: Int = 0,
) {
    val total: Int get() = links + hidden + system + unreadable + tooLarge + notDownloaded + tooLong + other

    fun toJson(): JSONObject = JSONObject().put("links", links).put("hidden", hidden).put("system", system).put("unreadable", unreadable)
        .put("tooLarge", tooLarge).put("notDownloaded", notDownloaded).put("tooLong", tooLong).put("other", other)

    companion object {
        fun parse(json: JSONObject?): SkippedCounts {
            if (json == null) return SkippedCounts()
            fun count(key: String) = json.intOrNull(key)?.coerceIn(0, 1_000_000) ?: 0
            return SkippedCounts(count("links"), count("hidden"), count("system"), count("unreadable"), count("tooLarge"),
                count("notDownloaded"), count("tooLong"), count("other"))
        }
    }
}

data class FolderOfferPayload(
    val folderTransferId: String,
    val rootName: String,
    val fileCount: Int,
    val folderCount: Int,
    val totalSize: Long,
    val pageCount: Int,
    val manifestSha256: String,
    val destination: FolderDestination?,
    val resume: Boolean,
    val skipped: SkippedCounts,
    /** Files 2.0: the entries land directly in the destination folder; no root folder (uploads, downloads). */
    val into: Boolean = false,
    /** Files 2.0: this offer answers the receiver's places.download. */
    val downloadRequestId: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("folderTransferId", folderTransferId).put("rootName", rootName)
        .put("fileCount", fileCount).put("folderCount", folderCount).put("totalSize", totalSize).put("pageCount", pageCount)
        .put("manifestSha256", manifestSha256).apply { destination?.let { put("destination", it.toJson()) } }
        .put("resume", resume).put("skipped", skipped.toJson())
        .apply {
            if (into) put("into", true)
            downloadRequestId?.let { put("downloadRequestId", it) }
        }

    companion object {
        sealed interface Result {
            data class Valid(val offer: FolderOfferPayload) : Result
            data class Invalid(val code: String) : Result
        }

        /** Checks fields and limits; a valid offer may still fail on its manifest. */
        fun parse(json: JSONObject): Result {
            if (!json.versionOk()) return Result.Invalid(FolderCodes.UNSUPPORTED)
            val invalid = Result.Invalid(FolderCodes.INVALID_MESSAGE)
            val id = json.stringOrNull("folderTransferId")?.takeIf(::isWireId) ?: return invalid
            val rootName = json.stringOrNull("rootName") ?: return invalid
            if (!PortableName.isPortable(rootName)) return Result.Invalid(FolderCodes.INVALID_MANIFEST)
            val fileCount = json.intOrNull("fileCount") ?: return invalid
            val folderCount = json.intOrNull("folderCount") ?: return invalid
            val totalSize = json.longOrNull("totalSize") ?: return invalid
            val pageCount = json.intOrNull("pageCount") ?: return invalid
            val digest = json.stringOrNull("manifestSha256") ?: return invalid
            if (runCatching { java.util.Base64.getDecoder().decode(digest).size == 32 }.getOrDefault(false).not()) return invalid
            // An empty folder has no entries and no pages (an edition call; the draft says 1 to 128 pages).
            if (fileCount < 0 || folderCount < 0 || totalSize < 0 || pageCount < 0) return invalid
            if ((fileCount + folderCount == 0) != (pageCount == 0)) return Result.Invalid(FolderCodes.INVALID_MANIFEST)
            if (fileCount > FolderLimits.MAX_FILES || folderCount > FolderLimits.MAX_FOLDERS || totalSize > FolderLimits.MAX_TOTAL_SIZE ||
                pageCount > FolderLimits.MAX_PAGES
            ) return Result.Invalid(FolderCodes.LIMIT_EXCEEDED)
            if (fileCount + folderCount > pageCount * FolderLimits.MAX_ENTRIES_PER_PAGE || fileCount + folderCount < pageCount) {
                return Result.Invalid(FolderCodes.INVALID_MANIFEST)
            }
            val destination = json.optJSONObject("destination")?.let { FolderDestination.parse(it) ?: return invalid }
            val downloadRequestId = json.stringOrNull("downloadRequestId")
            if (downloadRequestId != null && !isWireId(downloadRequestId)) return invalid
            return Result.Valid(FolderOfferPayload(id, rootName, fileCount, folderCount, totalSize, pageCount, digest, destination,
                json.opt("resume") == true, SkippedCounts.parse(json.optJSONObject("skipped")), json.opt("into") == true, downloadRequestId))
        }
    }
}

data class ManifestPagePayload(val folderTransferId: String, val page: Int, val entries: List<ManifestEntry>) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("folderTransferId", folderTransferId).put("page", page)
        .put("entries", JSONArray().apply { entries.forEach { put(entryJson(it)) } })

    companion object {
        fun entryJson(entry: ManifestEntry): JSONObject = JSONObject().put("type", entry.type.wire).put("path", entry.path).apply {
            if (!entry.isDirectory) {
                put("size", entry.size)
                put("sha256", entry.sha256)
                entry.modified?.let { put("modified", it) }
            }
        }

        /** Null for a malformed page; entry-level rules are the assembler's. */
        fun parse(json: JSONObject): ManifestPagePayload? {
            if (!json.versionOk()) return null
            val array = json.optJSONArray("entries") ?: return null
            if (array.length() !in 1..FolderLimits.MAX_ENTRIES_PER_PAGE) return null
            val entries = (0 until array.length()).map { index ->
                val item = array.optJSONObject(index) ?: return null
                val path = item.stringOrNull("path") ?: return null
                when (item.stringOrNull("type")) {
                    "dir" -> ManifestEntry(ManifestEntry.Type.DIR, path)
                    "file" -> ManifestEntry(
                        ManifestEntry.Type.FILE,
                        path,
                        item.longOrNull("size") ?: return null,
                        item.stringOrNull("sha256") ?: return null,
                        item.longOrNull("modified"),
                    )
                    else -> return null
                }
            }
            return ManifestPagePayload(
                json.stringOrNull("folderTransferId")?.takeIf(::isWireId) ?: return null,
                json.intOrNull("page") ?: return null,
                entries,
            )
        }
    }
}

fun foldersWaitingJson(id: String, reason: String, timeoutSeconds: Int = FolderTimeouts.QUESTION_SECONDS): JSONObject =
    JSONObject().put("version", 1).put("folderTransferId", id).put("reason", reason).put("timeoutSeconds", timeoutSeconds)

object WaitingReasons {
    const val DESTINATION = "destination"
    const val CONFLICT = "conflict"
}

data class FolderConflictPayload(
    val folderTransferId: String,
    val existing: String,
    val clashingFiles: Int?,
    val clashingFolders: Int?,
    val newFolderName: String,
    val choices: List<ConflictChoice>,
    val timeoutSeconds: Int,
) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("folderTransferId", folderTransferId).put("existing", existing)
        .put("clashingFiles", clashingFiles.orNull()).put("clashingFolders", clashingFolders.orNull()).put("newFolderName", newFolderName)
        .put("choices", JSONArray(choices.map { it.wire })).put("timeoutSeconds", timeoutSeconds)

    companion object {
        const val EXISTING_FOLDER = "folder"
        const val EXISTING_FILE = "file"
    }
}

data class FolderResolvePayload(val folderTransferId: String, val choice: ConflictChoice) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("folderTransferId", folderTransferId).put("choice", choice.wire)

    companion object {
        fun parse(json: JSONObject): FolderResolvePayload? {
            if (!json.versionOk()) return null
            val choice = ConflictChoice.fromWire(json.stringOrNull("choice"))?.takeIf { it != ConflictChoice.NONE } ?: return null
            return FolderResolvePayload(json.stringOrNull("folderTransferId")?.takeIf(::isWireId) ?: return null, choice)
        }
    }
}

data class FolderAcceptPayload(
    val folderTransferId: String,
    val rootName: String,
    val destinationLabel: String,
    val choice: ConflictChoice,
    val completedBitmap: String?,
    /** Free bytes of the chosen destination's storage, best effort. */
    val freeBytes: Long? = null,
) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("folderTransferId", folderTransferId).put("rootName", rootName)
        .put("destinationLabel", destinationLabel.take(FolderLimits.MAX_DESTINATION_LABEL_CHARS)).put("choice", choice.wire)
        .put("completedBitmap", completedBitmap.orNull()).put("freeBytes", freeBytes.orNull())
}

fun foldersRejectedJson(id: String, code: String, entry: Int? = null, neededBytes: Long? = null, freeBytes: Long? = null): JSONObject =
    JSONObject().put("version", 1).put("folderTransferId", id).put("code", code).put("entry", entry.orNull())
        .put("neededBytes", neededBytes.orNull()).put("freeBytes", freeBytes.orNull())

fun foldersEntryFailedJson(id: String, entry: Int, transferId: String, code: String): JSONObject =
    JSONObject().put("version", 1).put("folderTransferId", id).put("entry", entry).put("transferId", transferId).put("code", code)

data class FailedEntry(val entry: Int, val code: String) {
    fun toJson(): JSONObject = JSONObject().put("entry", entry).put("code", code)
}

data class FolderCompletePayload(val folderTransferId: String, val sentFiles: Int, val failedCount: Int, val failed: List<FailedEntry>) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("folderTransferId", folderTransferId).put("sentFiles", sentFiles)
        .put("failedCount", failedCount).put("failed", JSONArray().apply { failed.take(FolderLimits.MAX_REPORTED_FAILURES).forEach { put(it.toJson()) } })

    companion object {
        fun parse(json: JSONObject): FolderCompletePayload? {
            if (!json.versionOk()) return null
            val array = json.optJSONArray("failed") ?: JSONArray()
            return FolderCompletePayload(
                json.stringOrNull("folderTransferId")?.takeIf(::isWireId) ?: return null,
                json.intOrNull("sentFiles") ?: return null,
                json.intOrNull("failedCount") ?: 0,
                (0 until minOf(array.length(), FolderLimits.MAX_REPORTED_FAILURES)).mapNotNull { index ->
                    val item = array.optJSONObject(index) ?: return@mapNotNull null
                    FailedEntry(item.intOrNull("entry") ?: return@mapNotNull null, item.stringOrNull("code") ?: FolderCodes.IO_ERROR)
                },
            )
        }
    }
}

data class FolderResultPayload(
    val folderTransferId: String,
    val complete: Boolean,
    val savedFiles: Int,
    val savedBytes: Long,
    val createdFolders: Int,
    val renamedFiles: Int,
    val replacedFiles: Int,
    val failedCount: Int,
    val failed: List<FailedEntry>,
) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("folderTransferId", folderTransferId)
        .put("status", if (complete) "complete" else "incomplete").put("savedFiles", savedFiles).put("savedBytes", savedBytes)
        .put("createdFolders", createdFolders).put("renamedFiles", renamedFiles).put("replacedFiles", replacedFiles)
        .put("failedCount", failedCount).put("failed", JSONArray().apply { failed.take(FolderLimits.MAX_REPORTED_FAILURES).forEach { put(it.toJson()) } })
}

object CancelReasons {
    const val USER = "user"
    const val TIMEOUT = "timeout"
    const val POLICY = "policy"
    const val ERROR = "error"
}

data class FolderCancelPayload(val folderTransferId: String, val reason: String, val code: String?) {
    fun toJson(): JSONObject = JSONObject().put("version", 1).put("folderTransferId", folderTransferId).put("reason", reason).put("code", code.orNull())

    companion object {
        fun parse(json: JSONObject): FolderCancelPayload? {
            if (!json.versionOk()) return null
            return FolderCancelPayload(
                json.stringOrNull("folderTransferId")?.takeIf(::isWireId) ?: return null,
                json.stringOrNull("reason") ?: CancelReasons.ERROR,
                json.stringOrNull("code"),
            )
        }
    }
}

/** The folder fields a files.offer carries inside a folder transfer (4.6). Null when absent. */
data class FolderFileFields(val folderTransferId: String, val entry: Int, val path: String) {
    companion object {
        fun parse(json: JSONObject): FolderFileFields? {
            val id = json.stringOrNull("folderTransferId") ?: return null
            return FolderFileFields(id, json.intOrNull("entry") ?: -1, json.stringOrNull("path").orEmpty())
        }
    }
}

/** folders.waiting from the receiver: `destination` or `conflict`, with its countdown. */
data class FolderWaitingPayload(val folderTransferId: String, val reason: String, val timeoutSeconds: Int) {
    companion object {
        fun parse(json: JSONObject): FolderWaitingPayload? {
            if (!json.versionOk()) return null
            return FolderWaitingPayload(
                json.stringOrNull("folderTransferId")?.takeIf(::isWireId) ?: return null,
                json.stringOrNull("reason") ?: return null,
                (json.intOrNull("timeoutSeconds") ?: FolderTimeouts.QUESTION_SECONDS).coerceIn(1, FolderTimeouts.QUESTION_SECONDS),
            )
        }
    }
}

/** folders.accept as the sender reads it. */
fun parseFolderAccept(json: JSONObject): FolderAcceptPayload? {
    if (!json.versionOk()) return null
    return FolderAcceptPayload(
        json.stringOrNull("folderTransferId")?.takeIf(::isWireId) ?: return null,
        json.stringOrNull("rootName") ?: return null,
        json.stringOrNull("destinationLabel").orEmpty().take(FolderLimits.MAX_DESTINATION_LABEL_CHARS),
        ConflictChoice.fromWire(json.stringOrNull("choice")) ?: ConflictChoice.NONE,
        json.stringOrNull("completedBitmap"),
        json.longOrNull("freeBytes"),
    )
}

/** folders.rejected as the sender reads it. */
data class FolderRejectedPayload(val folderTransferId: String, val code: String, val neededBytes: Long?, val freeBytes: Long?) {
    companion object {
        fun parse(json: JSONObject): FolderRejectedPayload? {
            if (!json.versionOk()) return null
            return FolderRejectedPayload(
                json.stringOrNull("folderTransferId")?.takeIf(::isWireId) ?: return null,
                json.stringOrNull("code") ?: FolderCodes.INVALID_MESSAGE,
                json.longOrNull("neededBytes"),
                json.longOrNull("freeBytes"),
            )
        }
    }
}

/** folders.entry_failed as the sender reads it. */
data class FolderEntryFailedPayload(val folderTransferId: String, val entry: Int, val transferId: String?, val code: String) {
    companion object {
        fun parse(json: JSONObject): FolderEntryFailedPayload? {
            if (!json.versionOk()) return null
            return FolderEntryFailedPayload(
                json.stringOrNull("folderTransferId")?.takeIf(::isWireId) ?: return null,
                json.intOrNull("entry") ?: return null,
                json.stringOrNull("transferId"),
                json.stringOrNull("code") ?: FolderCodes.IO_ERROR,
            )
        }
    }
}

/** folders.result as the sender reads it. */
fun parseFolderResult(json: JSONObject): FolderResultPayload? {
    if (!json.versionOk()) return null
    val array = json.optJSONArray("failed") ?: JSONArray()
    return FolderResultPayload(
        json.stringOrNull("folderTransferId")?.takeIf(::isWireId) ?: return null,
        json.stringOrNull("status") == "complete",
        json.intOrNull("savedFiles") ?: 0,
        json.longOrNull("savedBytes") ?: 0,
        json.intOrNull("createdFolders") ?: 0,
        json.intOrNull("renamedFiles") ?: 0,
        json.intOrNull("replacedFiles") ?: 0,
        json.intOrNull("failedCount") ?: 0,
        (0 until minOf(array.length(), FolderLimits.MAX_REPORTED_FAILURES)).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            FailedEntry(item.intOrNull("entry") ?: return@mapNotNull null, item.stringOrNull("code") ?: FolderCodes.IO_ERROR)
        },
    )
}
