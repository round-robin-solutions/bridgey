package dev.bridgey.android.browse

import java.io.IOException
import java.io.InputStream

/*
 * Files 2.0, second slice (draft, protocol.md "Draft: phone files, media and folders both ways"): the phone's
 * local sources shared by the in-app attach sheet (Photos and Videos, Files, Folders) and the browse server
 * that answers the Mac (media.list, media.thumbnails, places.download). Plain types so the server and its
 * tests run on the JVM with fakes. Every call may block: call them off the main thread.
 */

/** Photo and video access (READ_MEDIA_IMAGES / READ_MEDIA_VIDEO, or the user's partial selection). */
enum class MediaAccess(val wire: String) { FULL("full"), PARTIAL("partial"), NONE("none") }

/** An item on the phone, as the protocol's `ref`: in a place, or a MediaStore photo or video. */
sealed interface BrowseRef {
    data class Place(val placeId: String, val path: String, val name: String) : BrowseRef
    data class Media(val mediaId: Long) : BrowseRef
}

/** A photo or video from MediaStore (the Files collection's `_ID`, so images and videos share one ID space). */
data class MediaItem(
    val mediaId: Long,
    val name: String,
    val size: Long,
    val modifiedMillis: Long,
    /** DATE_TAKEN when known, else DATE_ADDED: the order of the gallery. */
    val sortMillis: Long,
    val mimeType: String,
    val width: Int?,
    val height: Int?,
    val durationMs: Long?,
    /** "Camera", "Screenshots": the bucket display name, for display only. */
    val location: String?,
    /** content:// URI, never sent to the other device. */
    val uri: String,
) {
    val isVideo: Boolean get() = mimeType.startsWith("video/")
}

interface MediaLibrary {
    fun access(): MediaAccess

    /** Photos and videos, newest first ([MediaItem.sortMillis] descending, then ID). Empty without access. */
    @Throws(IOException::class)
    fun page(offset: Int, limit: Int): List<MediaItem>

    fun item(mediaId: Long): MediaItem?

    @Throws(IOException::class)
    fun open(mediaId: Long): InputStream?

    /** Bumps when MediaStore changes (a ContentObserver), so caches and pages can refresh. */
    val generation: Long get() = 0
}

/** A recent document: a file in a granted place that is not an image or video. */
data class DocumentItem(
    val placeId: String,
    /** The folder inside the place ("" is the place itself). */
    val path: String,
    val name: String,
    val size: Long,
    val modifiedMillis: Long,
    val mimeType: String?,
    /** content:// document URI, never sent to the other device. */
    val documentUri: String,
    /** "Documents/Invoices": place label plus path, for display. */
    val location: String,
)

/**
 * Recent documents over the granted places (Android shared storage shows other apps' documents only through
 * granted trees). Persisted on the phone (no_backup, owner-only) so the Files tab and the Mac's Files section
 * open instantly from the last index; refreshed in the background.
 */
interface DocumentIndex {
    /** True while a refresh runs. */
    val indexing: Boolean

    /** Newest first by modified. */
    fun recent(offset: Int, limit: Int): List<DocumentItem>

    /** Starts a background refresh when the index is older than a few minutes (or never ran). */
    fun refreshIfStale()

    /** Places changed (added, removed, regranted): drop what is gone, index what is new. */
    fun placesChanged() = Unit
}

/** Nothing until the real source is wired: no access, no items. */
object EmptyMediaLibrary : MediaLibrary {
    override fun access(): MediaAccess = MediaAccess.NONE
    override fun page(offset: Int, limit: Int): List<MediaItem> = emptyList()
    override fun item(mediaId: Long): MediaItem? = null
    override fun open(mediaId: Long): InputStream? = null
}

object EmptyDocumentIndex : DocumentIndex {
    override val indexing: Boolean = false
    override fun recent(offset: Int, limit: Int): List<DocumentItem> = emptyList()
    override fun refreshIfStale() = Unit
}

/** Where a folder sent from this phone comes from (phone to Mac). */
sealed interface FolderSource {
    /** A tree picked with the system folder picker ("Browse…"), used for this send only. */
    data class Tree(val treeUri: String) : FolderSource

    /** A folder inside a granted place (the attach sheet's Folders tab). "" is the place itself. */
    data class Place(val placeId: String, val path: String = "") : FolderSource
}
