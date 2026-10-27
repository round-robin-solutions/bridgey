package dev.bridgey.android.folders

import android.content.ContentResolver
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.BufferedOutputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * A granted Storage Access Framework tree (6.3), through [DocumentsContract] directly: one child query per
 * folder, `createDocument` with `application/octet-stream` so the provider keeps the exact name, and
 * `renameDocument`/`deleteDocument` for part files and Replace. IDs are document IDs. A revoked grant or a
 * missing folder surfaces as [PlaceUnavailableException]; a full disk as [StorageFullException].
 */
class SafTreeStore(private val resolver: ContentResolver, val treeUri: Uri) : TreeStore {
    override val rootId: String = DocumentsContract.getTreeDocumentId(treeUri)

    private fun documentUri(id: String): Uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)

    private inline fun <T> guarded(block: () -> T): T = try {
        block()
    } catch (error: SecurityException) {
        throw PlaceUnavailableException(cause = error)
    } catch (error: FileNotFoundException) {
        throw PlaceUnavailableException(cause = error)
    } catch (error: IllegalArgumentException) {
        // Providers throw this for documents that no longer exist.
        throw PlaceUnavailableException(cause = error)
    } catch (error: IOException) {
        throw if (storageErrorCode(error) == FolderCodes.INSUFFICIENT_SPACE) StorageFullException(cause = error) else error
    } catch (error: RuntimeException) {
        // ParcelableException wraps a provider's IOException across the binder.
        val cause = error.cause
        throw when {
            cause is FileNotFoundException -> PlaceUnavailableException(cause = cause)
            cause is IOException && storageErrorCode(cause) == FolderCodes.INSUFFICIENT_SPACE -> StorageFullException(cause = cause)
            cause is IOException -> cause
            else -> IOException(error)
        }
    }

    override fun children(dirId: String): List<TreeNode> = guarded {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, dirId)
        val projection = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE)
        val cursor = resolver.query(uri, projection, null as android.os.Bundle?, null) ?: throw PlaceUnavailableException()
        cursor.use {
            val result = ArrayList<TreeNode>(it.count.coerceAtLeast(0))
            while (it.moveToNext()) {
                val id = it.getString(0) ?: continue
                val name = it.getString(1) ?: continue
                result += TreeNode(id, name, it.getString(2) == Document.MIME_TYPE_DIR)
            }
            result
        }
    }

    override fun entries(dirId: String): List<TreeEntry> = guarded {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, dirId)
        val projection = arrayOf(
            Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS,
        )
        val cursor = resolver.query(uri, projection, null as android.os.Bundle?, null) ?: throw PlaceUnavailableException()
        cursor.use {
            val result = ArrayList<TreeEntry>(it.count.coerceAtLeast(0))
            while (it.moveToNext()) {
                val id = it.getString(0) ?: continue
                val name = it.getString(1) ?: continue
                val mime = it.getString(2)
                val isDirectory = mime == Document.MIME_TYPE_DIR
                result += TreeEntry(
                    id = id,
                    name = name,
                    isDirectory = isDirectory,
                    size = if (isDirectory || it.isNull(3)) null else it.getLong(3),
                    modifiedMillis = if (it.isNull(4)) null else it.getLong(4).takeIf { value -> value > 0 },
                    mimeType = mime.takeUnless { isDirectory },
                    providerThumbnail = !it.isNull(5) && (it.getInt(5) and Document.FLAG_SUPPORTS_THUMBNAIL) != 0,
                    uri = documentUri(id).toString(),
                )
            }
            result
        }
    }

    override fun openInput(fileId: String): InputStream = guarded {
        resolver.openInputStream(documentUri(fileId)) ?: throw IOException("open failed")
    }

    override val thumbnailKind: ThumbnailKind get() = ThumbnailKind.DOCUMENT

    override fun createDirectory(parentId: String, name: String): String = create(parentId, Document.MIME_TYPE_DIR, name)

    override fun createFile(parentId: String, name: String): String = create(parentId, "application/octet-stream", name)

    private fun create(parentId: String, mimeType: String, name: String): String = guarded {
        val created = DocumentsContract.createDocument(resolver, documentUri(parentId), mimeType, name) ?: throw IOException("create failed")
        DocumentsContract.getDocumentId(created)
    }

    override fun openOutput(fileId: String): OutputStream = guarded {
        val descriptor = resolver.openFileDescriptor(documentUri(fileId), "w") ?: throw IOException("open failed")
        BufferedOutputStream(SyncingOutputStream(descriptor), 256 * 1024)
    }

    override fun rename(id: String, name: String): String = guarded {
        DocumentsContract.renameDocument(resolver, documentUri(id), name)?.let(DocumentsContract::getDocumentId) ?: id
    }

    override fun delete(id: String) {
        guarded { if (!DocumentsContract.deleteDocument(resolver, documentUri(id))) throw IOException("delete failed") }
    }

    /**
     * `findDocumentPath` gives the root and its `COLUMN_AVAILABLE_BYTES` is the free space. Providers hide the
     * root of a tree URI from apps (DocumentsProvider strips it), so for internal storage, SD cards and USB
     * drives the volume is read from the document ID ("primary:Pictures", "1A2B-3C4D:Trip") instead. Best effort.
     */
    override fun freeBytes(): Long? {
        runCatching {
            val rootOfPath = DocumentsContract.findDocumentPath(resolver, documentUri(rootId))?.rootId
            if (rootOfPath != null) {
                resolver.query(DocumentsContract.buildRootUri(treeUri.authority, rootOfPath), arrayOf(DocumentsContract.Root.COLUMN_AVAILABLE_BYTES), null as android.os.Bundle?, null)
                    ?.use { cursor -> if (cursor.moveToFirst() && !cursor.isNull(0)) return cursor.getLong(0).takeIf { it >= 0 } }
            }
        }
        if (treeUri.authority != PlacesStore.EXTERNAL_STORAGE_AUTHORITY) return null
        return runCatching {
            val volume = rootId.substringBefore(':')
            @Suppress("DEPRECATION")
            val directory = if (volume == "primary") android.os.Environment.getExternalStorageDirectory() else java.io.File("/storage/$volume")
            android.os.StatFs(directory.path).availableBytes
        }.getOrNull()
    }

    override fun uriOf(id: String): String = documentUri(id).toString()

    override fun idOf(uri: String): String? = runCatching {
        val parsed = Uri.parse(uri)
        if (parsed.authority != treeUri.authority) return null
        DocumentsContract.getDocumentId(parsed)
    }.getOrNull()

    /** The display name of the tree's own folder ("Pictures"), for a new place's label. */
    fun rootName(): String? = runCatching {
        resolver.query(documentUri(rootId), arrayOf(Document.COLUMN_DISPLAY_NAME), null as android.os.Bundle?, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }.getOrNull()

    /** Whether the root can still be read: the grant holds and the folder exists. One query of the root itself. */
    fun reachable(): Boolean = runCatching {
        resolver.query(documentUri(rootId), arrayOf(Document.COLUMN_DOCUMENT_ID), null as android.os.Bundle?, null)?.use { it.moveToFirst() } == true
    }.getOrDefault(false)

    /** The root accepts new documents (`FLAG_DIR_SUPPORTS_CREATE`). */
    fun supportsCreate(): Boolean = runCatching {
        resolver.query(documentUri(rootId), arrayOf(Document.COLUMN_FLAGS), null as android.os.Bundle?, null)?.use { cursor ->
            cursor.moveToFirst() && (cursor.getInt(0) and Document.FLAG_DIR_SUPPORTS_CREATE) != 0
        } == true
    }.getOrDefault(false)

    /** Writes through the descriptor and syncs it on close, so a verified file is on disk before the ack. */
    private class SyncingOutputStream(private val descriptor: ParcelFileDescriptor) : OutputStream() {
        private val output = FileOutputStream(descriptor.fileDescriptor)

        override fun write(b: Int) = output.write(b)
        override fun write(b: ByteArray, off: Int, len: Int) = output.write(b, off, len)

        override fun close() {
            try {
                output.flush()
                runCatching { output.fd.sync() }
                output.close()
            } finally {
                descriptor.close()
            }
        }
    }
}
