package dev.bridgey.android.folders

/**
 * The receiving side's view of its places and settings, and what a folder session reports, as plain types so
 * the session and the places server run on the JVM without Android.
 */

/** A place as the receiver sees it. [label] is for display; [open] gives its storage (may throw when unavailable). */
class PlaceRef(
    val placeId: String,
    val label: String,
    val available: Boolean,
    private val opener: () -> TreeStore,
    /** For "Pictures (USB drive)": the storage's own title, shown under the label. */
    val storageTitle: String? = null,
    /** A one-off grant from "Other folder…": its tree URI, released after the transfer unless it was added. */
    val oneOffTree: String? = null,
) {
    fun open(): TreeStore = opener()
}

interface PlaceDirectory {
    /** `default` first, then granted places by label. */
    fun places(): List<PlaceRef>

    fun place(placeId: String): PlaceRef? = places().firstOrNull { it.placeId == placeId }

    /** A folder picked through "Other folder…" for one transfer. Null when the grant is not usable. */
    fun oneOff(treeUri: String): PlaceRef? = null
}

/** The receiving phone's own settings (3.2, 3.3, Rahul's Replace switch). Never synced except mode and policy, later. */
data class FolderReceiveSettings(
    val mode: DestinationMode = DestinationMode.SENDER_PICKS,
    val policy: ConflictPolicy = ConflictPolicy.ASK,
    val defaultPlaceId: String = DEFAULT_PLACE_ID,
    /** "Allow other devices to change files here" (was "replace"): off by default. Uploads need it too. */
    val allowReplaceFromOtherDevices: Boolean = false,
    /** "Let other devices browse this phone" and Files 2.0 browsing served (files_browse_draft1). Uploads need it. */
    val allowBrowse: Boolean = false,
)

/** Display path: the place's label, then the path inside it ("Pictures/Trip"), at most 128 characters. */
fun destinationLabel(placeLabel: String, path: String): String =
    (if (path.isEmpty()) placeLabel else "$placeLabel/$path").take(FolderLimits.MAX_DESTINATION_LABEL_CHARS)

/** What the phone asks its user. One question per folder at a time. */
data class FolderQuestion(
    val folderTransferId: String,
    val deviceId: String,
    val deviceName: String,
    val rootName: String,
    val fileCount: Int,
    val totalBytes: Long,
    val kind: Kind,
    /** When the question times out, wall clock. */
    val deadlineMillis: Long,
    /** Destination question: why the phone asks. */
    val reason: FolderPolicy.AskReason? = null,
    /** Destination question in mode (c) without its default folder: that folder's label. */
    val unavailableDefaultLabel: String? = null,
    /** Conflict question. */
    val existing: FolderPolicy.Existing = FolderPolicy.Existing.NONE,
    val destinationLabel: String = "",
    val clashingFiles: Int? = null,
    val newFolderName: String = "",
    val choices: List<ConflictChoice> = emptyList(),
    /** The Mac chose Replace and "Allow other devices to replace files here" is off: confirm it here. */
    val confirmsRemoteReplace: Boolean = false,
) {
    enum class Kind { DESTINATION, CONFLICT }
}

/** An answer to the Save to… question: a place (and a folder inside it), or a one-off tree. */
data class DestinationAnswer(val placeId: String? = null, val path: String = "", val oneOffTree: String? = null, val addToPlaces: Boolean = false)

/** How a folder transfer ended, for the row, the notification and the activity stream. */
enum class FolderEnd {
    /** Every entry saved. */
    COMPLETE,

    /** Ended after the accept with entries missing (cancelled by either side, failures, lost access). */
    INCOMPLETE,

    /** Nothing was written: cancelled, declined or rejected before the accept. */
    CANCELLED,

    /** Nobody answered a question within 3 minutes. Nothing written. */
    TIMED_OUT,

    /** The connection dropped. With a journal, it resumes when the device reconnects. */
    INTERRUPTED,
}

/** What the session waits for, shown on the row. */
enum class FolderWaiting { MANIFEST, DESTINATION, CONFLICT_HERE, CONFLICT_ON_SENDER }

data class FolderFailure(val entry: Int, val name: String, val code: String)

/**
 * One folder transfer as the UI sees it. Names stay in memory for the row; logs never see them.
 */
data class FolderSnapshot(
    val folderTransferId: String,
    val deviceId: String,
    val deviceName: String,
    val rootName: String,
    val filesTotal: Int,
    val bytesTotal: Long,
    val filesDone: Int = 0,
    val bytesDone: Long = 0,
    val destinationLabel: String? = null,
    val choice: ConflictChoice? = null,
    val waiting: FolderWaiting? = null,
    val deadlineMillis: Long? = null,
    val currentFile: String? = null,
    val currentFileBytes: Long = 0,
    val currentFileSize: Long = 0,
    val failures: List<FolderFailure> = emptyList(),
    val failedCount: Int = 0,
    /** The last completed names, newest last, at most 200. */
    val recent: List<String> = emptyList(),
    val renamedFiles: Int = 0,
    val replacedFiles: Int = 0,
    val skipped: SkippedCounts = SkippedCounts(),
    /** Empty folders the MediaStore fallback could not keep. */
    val emptyFoldersSkipped: Int = 0,
    val bytesPerSecond: Long = 0,
    val end: FolderEnd? = null,
    /** The error code that ended it, when one did ("timeout", "place_unavailable", ...). */
    val endCode: String? = null,
    /** Who ended it: true when this phone's user cancelled or declined. */
    val endedHere: Boolean = false,
    /** The saved folder's URI, for Open (SAF places only). */
    val rootUri: String? = null,
    /** The journal stays: the folder resumes when the device reconnects. */
    val resumable: Boolean = false,
    /** This phone sends the folder (phone to Mac, or a download the Mac asked for); false when it receives. */
    val outgoing: Boolean = false,
    /** A download the Mac asked for from its Phone files window (outgoing only). */
    val download: Boolean = false,
) {
    val active: Boolean get() = end == null
}
