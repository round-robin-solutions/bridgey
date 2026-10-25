package dev.bridgey.android

import android.content.ClipDescription
import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.OutputStream
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** One pipe a pasting app reads from while the data arrives from the Mac. */
internal interface ClipPipe {
    val readSide: ParcelFileDescriptor
    val output: OutputStream
    fun finish()
    fun fail(message: String)
}

internal fun interface ClipPipeFactory {
    fun create(): ClipPipe
}

/** createReliablePipe, so a failure reaches the reader as an error instead of a short file. */
internal object ReliableClipPipeFactory : ClipPipeFactory {
    override fun create(): ClipPipe {
        val (read, write) = ParcelFileDescriptor.createReliablePipe()
        return object : ClipPipe {
            override val readSide = read
            override val output: OutputStream = FileOutputStream(write.fileDescriptor)
            override fun finish() {
                runCatching { output.flush() }
                runCatching { write.close() }
            }
            override fun fail(message: String) {
                runCatching { write.closeWithError(message) }.onFailure { runCatching { write.close() } }
            }
        }
    }
}

/**
 * Serves clips from the Mac to the app that pastes them: content://${applicationId}.clipboard/
 * <offerId>/<index>/<name>. Not exported; the clipboard grants a pasting app temporary read
 * access to the URIs on the clip. Cached items open as files; lazy items stream through a pipe
 * while they arrive. Thumbnail requests never start a transfer.
 */
class ClipboardContentProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    private fun backend(): ClipProviderBackend? = backendOverride ?: runCatching {
        (context?.applicationContext as? BridgeyApplication)?.takeIf { it.isPrimaryUser }?.pairing?.clipboardInbox
    }.getOrNull()

    private fun item(uri: Uri): Pair<String, Int>? {
        val segments = uri.pathSegments
        if (segments.size < 2) return null
        val offerId = segments[0].takeIf(::isUuid) ?: return null
        val index = segments[1].toIntOrNull()?.takeIf { it in 0 until ClipLimits.MAX_ITEMS } ?: return null
        return offerId to index
    }

    private fun describe(uri: Uri): ClipItemInfo? = item(uri)?.let { (offerId, index) -> backend()?.describe(offerId, index) }

    override fun getType(uri: Uri): String? = describe(uri)?.mime

    override fun getStreamTypes(uri: Uri, mimeTypeFilter: String): Array<String>? =
        getType(uri)?.takeIf { ClipDescription.compareMimeTypes(it, mimeTypeFilter) }?.let { arrayOf(it) }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
        val info = describe(uri) ?: return null
        val columns = projection?.takeIf { it.isNotEmpty() } ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns, 1).apply {
            addRow(columns.map { column ->
                when (column) {
                    OpenableColumns.DISPLAY_NAME -> info.name
                    OpenableColumns.SIZE -> info.size
                    MIME_TYPE_COLUMN -> info.mime
                    else -> null
                }
            })
        }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Read only")
        return open(uri, allowFetch = true)
    }

    override fun openTypedAssetFile(uri: Uri, mimeTypeFilter: String, opts: Bundle?): AssetFileDescriptor? {
        // A thumbnail (the clipboard preview, a keyboard's suggestion strip) must not pull a 2 GB
        // item from the Mac; it gets the data only when it is already here.
        if (opts?.containsKey(ContentResolver.EXTRA_SIZE) == true) {
            return AssetFileDescriptor(open(uri, allowFetch = false), 0, AssetFileDescriptor.UNKNOWN_LENGTH)
        }
        return super.openTypedAssetFile(uri, mimeTypeFilter, opts)
    }

    private fun open(uri: Uri, allowFetch: Boolean): ParcelFileDescriptor {
        val (offerId, index) = item(uri) ?: throw FileNotFoundException("Unknown clipboard item")
        val backend = backend() ?: throw FileNotFoundException("Bridgey is not running")
        return when (val result = backend.open(offerId, index, allowFetch)) {
            is ClipOpen.Cached -> ParcelFileDescriptor.open(result.file, ParcelFileDescriptor.MODE_READ_ONLY)
            is ClipOpen.Failed -> throw FileNotFoundException(failureMessage(result.code))
            is ClipOpen.Streaming -> {
                val pipe = pipeFactory.create()
                executor.execute {
                    try {
                        result.stream.copyTo(pipe.output)
                        pipe.finish()
                    } catch (error: ClipStreamException) {
                        pipe.fail(failureMessage(error.code))
                    } catch (_: Exception) {
                        // The reading app went away; the transfer itself carries on into the cache.
                        pipe.fail(failureMessage(ClipErrorCode.CANCELLED))
                    }
                }
                pipe.readSide
            }
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    internal companion object {
        const val MIME_TYPE_COLUMN = "mime_type"

        /** Tests replace the inbox, the pipe and the thread the copy runs on. */
        @Volatile var backendOverride: ClipProviderBackend? = null
        @Volatile var pipeFactory: ClipPipeFactory = ReliableClipPipeFactory
        @Volatile var executor: Executor = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "bridgey-clipboard-pipe").apply { isDaemon = true }
        }

        fun failureMessage(code: String): String = when (code) {
            ClipErrorCode.NOT_CONNECTED -> "The other device is not connected"
            ClipErrorCode.CHANGED -> "The copy changed on the other device"
            ClipErrorCode.EXPIRED, ClipErrorCode.SUPERSEDED -> "Something newer was copied"
            ClipErrorCode.TOO_LARGE -> "Too large"
            ClipErrorCode.DISABLED -> "Clipboard is turned off on the other device"
            ClipErrorCode.TIMEOUT -> "The other device did not respond"
            ClipErrorCode.CANCELLED -> "Cancelled"
            else -> "Not available"
        }
    }
}
