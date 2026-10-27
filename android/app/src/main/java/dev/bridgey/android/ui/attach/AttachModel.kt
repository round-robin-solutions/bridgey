package dev.bridgey.android.ui.attach

import dev.bridgey.android.browse.DocumentItem
import dev.bridgey.android.browse.MediaAccess
import dev.bridgey.android.browse.MediaItem

/*
 * The attach sheet (Files 2.0): one in-app sheet for sending from the phone, so the system pickers are the rare
 * fallback ("Browse…"), not the main path. Tabs: Photos and Videos, Files (recent documents), Folders (granted
 * places). Plain state, so the sheet renders the same in the app and in screenshots.
 */

enum class AttachTab { MEDIA, FILES, FOLDERS }

/** A place in the Folders tab. */
data class AttachFolder(
    val placeId: String,
    val label: String,
    val detail: String?,
    val available: Boolean,
    val isDefault: Boolean = false,
)

data class AttachTarget(val deviceId: String, val name: String)

/** What the photo permission card shows. */
enum class MediaPrompt {
    /** Never asked, or asked and Android may ask again: the inline Allow button asks. */
    ASK,

    /** "Don't allow" twice: only app settings can change it. */
    OPEN_SETTINGS,
}

data class AttachState(
    val tab: AttachTab = AttachTab.MEDIA,
    val mediaAccess: MediaAccess = MediaAccess.NONE,
    val mediaPrompt: MediaPrompt = MediaPrompt.ASK,
    val media: List<MediaItem> = emptyList(),
    /** More media can load (the grid pages as it scrolls). */
    val mediaMore: Boolean = false,
    val documents: List<DocumentItem> = emptyList(),
    val documentsIndexing: Boolean = false,
    /** No granted place yet and the card was not put away: "Let Bridgey see your documents". */
    val showDocumentsCard: Boolean = false,
    /** At least one granted place: documents can be indexed. */
    val hasDocumentPlace: Boolean = false,
    val folders: List<AttachFolder> = emptyList(),
    /** The target receives folders (it advertised folders_receive_draft1). */
    val canSendFolders: Boolean = false,
    /** Selected keys in the order they were picked ([AttachKeys]). */
    val selection: List<String> = emptyList(),
    val targets: List<AttachTarget> = emptyList(),
    val targetId: String? = null,
) {
    val target: AttachTarget? get() = targets.firstOrNull { it.deviceId == targetId } ?: targets.firstOrNull()

    /** 1-based pick order for the counters, keyed like [selection]. */
    val order: Map<String, Int> get() = AttachSelection.order(selection)

    /** Bytes of the selected files (folders count 0: their size is known only once they are read). */
    val selectedBytes: Long get() = AttachSelection.bytes(selection, media, documents)

    val selectedFolders: Int get() = selection.count { it.startsWith(AttachKeys.FOLDER) }
}

class AttachActions(
    val selectTab: (AttachTab) -> Unit = {},
    val toggle: (String) -> Unit = {},
    val requestMedia: () -> Unit = {},
    val selectMorePhotos: () -> Unit = {},
    val allowAllPhotos: () -> Unit = {},
    val loadMoreMedia: () -> Unit = {},
    /** "Let Bridgey see your documents": the folder picker at Documents, then a new place. */
    val grantDocuments: () -> Unit = {},
    val dismissDocumentsCard: () -> Unit = {},
    /** Another granted folder ("Add another folder"). */
    val addFolder: () -> Unit = {},
    val browseFiles: () -> Unit = {},
    val browseFolder: () -> Unit = {},
    val pickTarget: (String) -> Unit = {},
    val send: () -> Unit = {},
    val close: () -> Unit = {},
)

/** Selection keys: one string per item, the same across tabs, so a send can mix photos, documents and folders. */
object AttachKeys {
    const val MEDIA = "m:"
    const val DOCUMENT = "d:"
    const val FOLDER = "f:"

    fun media(item: MediaItem): String = MEDIA + item.mediaId
    fun document(item: DocumentItem): String = DOCUMENT + item.documentUri
    fun folder(placeId: String): String = FOLDER + placeId
}

object AttachSelection {
    /** Bridgey sends one file after another; a hundred per send keeps the queue readable. */
    const val MAX = 100

    /** Adds [key] at the end, or removes it (later picks move up one). Full selections ignore new keys. */
    fun toggle(selection: List<String>, key: String, max: Int = MAX): List<String> = when {
        key in selection -> selection - key
        selection.size >= max -> selection
        else -> selection + key
    }

    fun order(selection: List<String>): Map<String, Int> {
        val result = HashMap<String, Int>(selection.size * 2)
        selection.forEachIndexed { index, key -> result[key] = index + 1 }
        return result
    }

    fun bytes(selection: List<String>, media: List<MediaItem>, documents: List<DocumentItem>): Long {
        if (selection.isEmpty()) return 0
        val wanted = selection.toHashSet()
        var total = 0L
        media.forEach { if (AttachKeys.media(it) in wanted) total += it.size }
        documents.forEach { if (AttachKeys.document(it) in wanted) total += it.size }
        return total
    }

    /** Keys whose items are gone (deleted, access removed) drop out, keeping the order of the rest. */
    fun prune(selection: List<String>, media: List<MediaItem>, documents: List<DocumentItem>, folders: List<AttachFolder>): List<String> {
        if (selection.isEmpty()) return selection
        val known = HashSet<String>(media.size + documents.size + folders.size)
        media.forEach { known += AttachKeys.media(it) }
        documents.forEach { known += AttachKeys.document(it) }
        folders.forEach { known += AttachKeys.folder(it.placeId) }
        return selection.filter { it in known }
    }

    /** "0:42", "12:05", "1:02:09". */
    fun duration(millis: Long): String {
        val seconds = (millis / 1000).coerceAtLeast(0)
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }
}
