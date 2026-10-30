package dev.bridgey.android.folders

import android.annotation.TargetApi
import android.content.ContentResolver
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * `Download/Bridgey` without a grant (6.2): files go through `MediaStore.Downloads` with
 * `RELATIVE_PATH = "Download/Bridgey/<root>/<sub>/"` and `IS_PENDING` until verified. Folders are virtual
 * (a relative path ending in "/"): they exist once a file is inside. Limits, said in Settings: browsing sees
 * only folders with files Bridgey saved; no New Folder; empty folders get a placeholder attempt; files Bridgey
 * did not save are invisible, so MediaStore may number a clash on its own.
 *
 * Relative paths are built only from validated portable names (5.1) and existing names Bridgey read back.
 */
@TargetApi(Build.VERSION_CODES.Q)
class MediaStoreTreeStore(private val resolver: ContentResolver) : TreeStore {
    override val rootId: String = ROOT
    override val supportsCreateFolder: Boolean = false
    private val collection: Uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI

    override fun children(dirId: String): List<TreeNode> {
        require(dirId.endsWith("/"))
        val projection = arrayOf(MediaStore.Downloads._ID, MediaStore.Downloads.DISPLAY_NAME, MediaStore.Downloads.RELATIVE_PATH)
        val selection = "${MediaStore.Downloads.RELATIVE_PATH} LIKE ? ESCAPE '\\'"
        val files = ArrayList<TreeNode>()
        val folders = LinkedHashMap<String, TreeNode>()
        resolver.query(collection, projection, selection, arrayOf(escapeLike(dirId) + "%"), null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                val name = cursor.getString(1) ?: continue
                val relative = cursor.getString(2)?.let { if (it.endsWith("/")) it else "$it/" } ?: continue
                if (!relative.startsWith(dirId)) continue
                if (relative == dirId) {
                    files += TreeNode(Uri.withAppendedPath(collection, id.toString()).toString(), name, false)
                } else {
                    val child = relative.removePrefix(dirId).substringBefore('/')
                    if (child.isNotEmpty()) folders.getOrPut(child) { TreeNode("$dirId$child/", child, true) }
                }
            }
        } ?: throw IOException("query failed")
        return folders.values.toList() + files
    }

    /** Like [children], with sizes, dates and types (DATE_MODIFIED is in seconds). Only Bridgey's own files show. */
    override fun entries(dirId: String): List<TreeEntry> {
        require(dirId.endsWith("/"))
        val projection = arrayOf(
            MediaStore.Downloads._ID, MediaStore.Downloads.DISPLAY_NAME, MediaStore.Downloads.RELATIVE_PATH, MediaStore.Downloads.SIZE,
            MediaStore.Downloads.DATE_MODIFIED, MediaStore.Downloads.MIME_TYPE, MediaStore.Downloads.IS_PENDING,
        )
        val selection = "${MediaStore.Downloads.RELATIVE_PATH} LIKE ? ESCAPE '\\'"
        val files = ArrayList<TreeEntry>()
        val folders = LinkedHashMap<String, TreeEntry>()
        resolver.query(collection, projection, selection, arrayOf(escapeLike(dirId) + "%"), null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                val name = cursor.getString(1) ?: continue
                val relative = cursor.getString(2)?.let { if (it.endsWith("/")) it else "$it/" } ?: continue
                if (!relative.startsWith(dirId)) continue
                if (relative == dirId) {
                    if (!cursor.isNull(6) && cursor.getInt(6) != 0) continue
                    val uri = Uri.withAppendedPath(collection, id.toString()).toString()
                    val mime = cursor.getString(5)
                    files += TreeEntry(
                        id = uri, name = name, isDirectory = false,
                        size = if (cursor.isNull(3)) null else cursor.getLong(3),
                        modifiedMillis = if (cursor.isNull(4)) null else cursor.getLong(4) * 1000,
                        mimeType = mime,
                        providerThumbnail = mime?.startsWith("image/") == true || mime?.startsWith("video/") == true,
                        uri = uri,
                    )
                } else {
                    val child = relative.removePrefix(dirId).substringBefore('/')
                    if (child.isNotEmpty()) folders.getOrPut(child) { TreeEntry("$dirId$child/", child, true) }
                }
            }
        } ?: throw IOException("query failed")
        return folders.values.toList() + files
    }

    override fun openInput(fileId: String): InputStream {
        if (!fileId.startsWith("content://")) throw IOException("not a file")
        return resolver.openInputStream(Uri.parse(fileId)) ?: throw IOException("open failed")
    }

    override val thumbnailKind: ThumbnailKind get() = ThumbnailKind.MEDIA_STORE

    override fun createDirectory(parentId: String, name: String): String = "$parentId$name/"

    override fun createFile(parentId: String, name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, parentId)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        return try {
            resolver.insert(collection, values)?.toString() ?: throw IOException("insert failed")
        } catch (error: IllegalStateException) {
            throw IOException(error)
        }
    }

    override fun openOutput(fileId: String): OutputStream =
        resolver.openOutputStream(Uri.parse(fileId), "w") ?: throw IOException("open failed")

    override fun rename(id: String, name: String): String {
        val values = ContentValues().apply { put(MediaStore.Downloads.DISPLAY_NAME, name) }
        if (resolver.update(Uri.parse(id), values, null, null) < 1) throw IOException("rename failed")
        return id
    }

    /** One update instead of two: each is a round trip to MediaProvider (live test 2026-10-30: about a quarter of the
     * receiving thread's time per 5 MB file on the emulator went to these updates). */
    override fun renameAndPublish(id: String, name: String): String {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.IS_PENDING, 0)
        }
        if (resolver.update(Uri.parse(id), values, null, null) < 1) throw IOException("rename failed")
        return id
    }

    override fun delete(id: String) {
        if (!id.startsWith("content://")) return
        resolver.delete(Uri.parse(id), null, null)
    }

    override fun publish(fileId: String) {
        val values = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
        if (resolver.update(Uri.parse(fileId), values, null, null) < 1) throw IOException("publish failed")
    }

    /** MediaStore keeps a folder only while something is inside: insert and delete a placeholder, best effort. */
    override fun keepEmptyDirectory(dirId: String): Boolean = runCatching {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, ".bridgey-keep")
            put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
            put(MediaStore.Downloads.RELATIVE_PATH, dirId)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values) ?: return false
        resolver.openOutputStream(uri, "w")?.close()
        resolver.delete(uri, null, null)
        true
    }.getOrDefault(false)

    @Suppress("DEPRECATION")
    override fun freeBytes(): Long? = runCatching {
        StatFs(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).path).availableBytes
    }.getOrNull()

    override fun uriOf(id: String): String = id

    override fun idOf(uri: String): String? = uri.takeIf { it.startsWith("content://") || it.startsWith(ROOT) }

    private fun escapeLike(value: String): String = value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

    companion object {
        val ROOT = "${Environment.DIRECTORY_DOWNLOADS}/Bridgey/"
    }
}
