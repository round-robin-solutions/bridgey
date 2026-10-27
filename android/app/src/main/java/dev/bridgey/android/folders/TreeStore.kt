package dev.bridgey.android.folders

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/** One child of a folder in a [TreeStore]: the store's own handle, the name and whether it is a folder. */
data class TreeNode(val id: String, val name: String, val isDirectory: Boolean)

/**
 * A child with what browsing and sending need (Files 2.0): size, modified time, type and whether the provider
 * makes thumbnails. Unknown values are null. [uri] is the content URI of the item, never sent to the other device.
 */
data class TreeEntry(
    val id: String,
    val name: String,
    val isDirectory: Boolean,
    val size: Long? = null,
    val modifiedMillis: Long? = null,
    val mimeType: String? = null,
    /** The provider makes thumbnails for it (SAF `FLAG_SUPPORTS_THUMBNAIL`, or a MediaStore image or video). */
    val providerThumbnail: Boolean = false,
    val uri: String? = null,
)

/** The place is gone: grant revoked, folder deleted or renamed elsewhere, storage removed (`place_unavailable`). */
class PlaceUnavailableException(message: String = "place unavailable", cause: Throwable? = null) : IOException(message, cause)

/** The storage filled up (`insufficient_space`). */
class StorageFullException(message: String = "storage full", cause: Throwable? = null) : IOException(message, cause)

/**
 * Where a folder lands (6.3): a granted Storage Access Framework tree, the MediaStore fallback for
 * Download/Bridgey, or an in-memory tree in tests. IDs are the store's own handles (document IDs for SAF);
 * names are never turned into file system paths. Every call may block; the folder session calls them on its
 * storage thread only.
 *
 * Bridgey computes every final name itself ([ConflictNames.firstFree] over [children]) and creates exactly
 * that name; a store never numbers names on its own behalf.
 */
interface TreeStore {
    /** The place's own folder. */
    val rootId: String

    /** False for the MediaStore fallback: places.create_folder is not offered and browsing sees only Bridgey's folders. */
    val supportsCreateFolder: Boolean get() = true

    /** Direct children of [dirId], one query. */
    @Throws(IOException::class)
    fun children(dirId: String): List<TreeNode>

    @Throws(IOException::class)
    fun createDirectory(parentId: String, name: String): String

    /** Creates an empty file named exactly [name]. */
    @Throws(IOException::class)
    fun createFile(parentId: String, name: String): String

    @Throws(IOException::class)
    fun openOutput(fileId: String): OutputStream

    /** Renames [id]; returns its ID afterwards (SAF may hand out a new one). */
    @Throws(IOException::class)
    fun rename(id: String, name: String): String

    @Throws(IOException::class)
    fun delete(id: String)

    /** Makes a verified file visible (MediaStore clears IS_PENDING). A no-op elsewhere. */
    @Throws(IOException::class)
    fun publish(fileId: String) = Unit

    /**
     * Called for folders that end up without files. True when the folder exists on its own; the MediaStore
     * fallback can only try a placeholder and may answer false (the folder is then skipped and counted).
     */
    fun keepEmptyDirectory(dirId: String): Boolean = true

    /** Free bytes of the storage, best effort; null when unknown. */
    fun freeBytes(): Long? = null

    /** A stable string for the journal and for "Open" (a document URI for SAF). */
    fun uriOf(id: String): String = id

    /** The ID of a string from [uriOf], or null when it does not belong to this store. */
    fun idOf(uri: String): String? = uri

    /** Direct children with sizes, dates and types, one query (browsing and sending from the phone). */
    @Throws(IOException::class)
    fun entries(dirId: String): List<TreeEntry> = children(dirId).map { TreeEntry(it.id, it.name, it.isDirectory) }

    /** Reads a file (browsing previews, ranges and folders sent from the phone). */
    @Throws(IOException::class)
    fun openInput(fileId: String): InputStream = throw IOException("not readable")

    /** The thumbnail source kind of this store's items. */
    val thumbnailKind: ThumbnailKind get() = ThumbnailKind.NONE
}

enum class ThumbnailKind { NONE, DOCUMENT, MEDIA_STORE }

/** The existing child named exactly [name] (5.3: never a hidden item or a part file), or null. */
@Throws(IOException::class)
fun resolveExistingChild(store: TreeStore, dirId: String, name: String): TreeEntry? {
    if (name.startsWith(".")) return null
    return store.entries(dirId).firstOrNull { it.name == name }
}

/**
 * Resolves an existing path (5.3) inside [store], one listing per component, by exact name among the existing
 * child folders. Never creates anything. Null when a component does not exist.
 */
@Throws(IOException::class)
fun resolveExistingPath(store: TreeStore, path: String): String? {
    var current = store.rootId
    for (component in FolderPaths.components(path)) {
        current = store.children(current).firstOrNull { it.isDirectory && it.name == component }?.id ?: return null
    }
    return current
}

/** Maps a storage failure message to a folder error code. */
fun storageErrorCode(error: Throwable): String = when (error) {
    is PlaceUnavailableException -> FolderCodes.PLACE_UNAVAILABLE
    is StorageFullException -> FolderCodes.INSUFFICIENT_SPACE
    is SecurityException -> FolderCodes.PLACE_UNAVAILABLE
    else -> if (error.message.orEmpty().contains("ENOSPC") || error.message.orEmpty().contains("No space left", ignoreCase = true)) {
        FolderCodes.INSUFFICIENT_SPACE
    } else {
        FolderCodes.IO_ERROR
    }
}
