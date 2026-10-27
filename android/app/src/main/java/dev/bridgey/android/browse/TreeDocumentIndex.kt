package dev.bridgey.android.browse

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.MediaStore
import dev.bridgey.android.folders.DEFAULT_PLACE_ID
import dev.bridgey.android.folders.PlacesStore
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** A folder tree the index walks: a granted place, or Download/Bridgey through MediaStore. */
data class IndexRoot(val placeId: String, val label: String, val rootId: String, val handle: String)

/** One child of a folder as the index sees it. */
data class IndexChild(
    val id: String,
    val name: String,
    val isDirectory: Boolean,
    val size: Long,
    val modifiedMillis: Long,
    val mimeType: String?,
    val documentUri: String,
)

/** Where the index reads from; tests use an in-memory tree. Every call may block. */
interface DocumentTreeSource {
    fun roots(): List<IndexRoot>

    fun children(root: IndexRoot, dirId: String): List<IndexChild>
}

/**
 * Recent documents over the granted places (6.1 of the folders design: shared storage shows other apps'
 * documents only through granted trees). The walk is bounded (depth 8, 20,000 entries, about 10 seconds) and
 * keeps the newest 500 files that are not images or videos; hidden folders and files are skipped. The result is
 * persisted owner-only under no_backup, so the attach sheet and the Mac's Files section open instantly from the
 * last index while a refresh runs in the background (stale after 5 minutes, or when places change).
 *
 * Names and paths stay in this file and in memory; nothing is logged.
 */
class TreeDocumentIndex(
    private val source: DocumentTreeSource,
    private val file: File,
    private val executor: Executor,
    private val clock: () -> Long = System::currentTimeMillis,
    private val limits: Limits = Limits(),
) : DocumentIndex {
    data class Limits(
        val maxDepth: Int = 8,
        val maxEntries: Int = 20_000,
        val budgetMillis: Long = 10_000,
        val keep: Int = 500,
        val staleMillis: Long = 5 * 60_000,
    )

    internal data class Snapshot(val builtAt: Long, val signature: String, val items: List<DocumentItem>)

    @Volatile private var snapshot: Snapshot = load()
    @Volatile private var running = false
    @Volatile private var dirty = false
    private val mutableUpdates = MutableStateFlow(snapshot.builtAt)

    /** The time of the last finished index; the attach sheet reloads when it changes. */
    val updates: StateFlow<Long> = mutableUpdates.asStateFlow()

    override val indexing: Boolean get() = running

    /** When the shown index was built (0: never). */
    val builtAtMillis: Long get() = snapshot.builtAt

    override fun recent(offset: Int, limit: Int): List<DocumentItem> {
        val items = snapshot.items
        if (offset >= items.size || limit <= 0) return emptyList()
        return items.subList(offset.coerceAtLeast(0), minOf(items.size, offset.coerceAtLeast(0) + limit))
    }

    override fun refreshIfStale() {
        val current = snapshot
        if (!dirty && current.builtAt > 0 && clock() - current.builtAt in 0 until limits.staleMillis) return
        start()
    }

    override fun placesChanged() {
        dirty = true
        start()
    }

    @Synchronized
    private fun start() {
        if (running) return
        running = true
        executor.execute {
            try {
                dirty = false
                val built = build()
                snapshot = built
                save(built)
                mutableUpdates.value = built.builtAt
            } catch (_: RuntimeException) {
                // A provider that fails mid-walk keeps the last index; the next refresh tries again.
            } finally {
                running = false
            }
        }
    }

    /** One walk over every root: breadth first, bounded, newest [Limits.keep] documents. */
    internal fun build(): Snapshot {
        val started = clock()
        val roots = source.roots()
        val found = ArrayList<DocumentItem>()
        var visited = 0
        roots@ for (root in roots) {
            val queue = ArrayDeque<Triple<String, String, Int>>()
            queue.addLast(Triple(root.rootId, "", 0))
            while (queue.isNotEmpty()) {
                if (visited >= limits.maxEntries || clock() - started > limits.budgetMillis) break@roots
                val (dirId, path, depth) = queue.removeFirst()
                val children = runCatching { source.children(root, dirId) }.getOrDefault(emptyList())
                for (child in children) {
                    visited++
                    if (visited > limits.maxEntries) break
                    if (DocumentRules.hidden(child.name)) continue
                    if (child.isDirectory) {
                        if (depth + 1 <= limits.maxDepth) queue.addLast(Triple(child.id, if (path.isEmpty()) child.name else "$path/${child.name}", depth + 1))
                    } else if (DocumentRules.isDocument(child.mimeType, child.name)) {
                        found += DocumentItem(
                            placeId = root.placeId,
                            path = path,
                            name = child.name,
                            size = child.size.coerceAtLeast(0),
                            modifiedMillis = child.modifiedMillis,
                            mimeType = child.mimeType,
                            documentUri = child.documentUri,
                            location = (if (path.isEmpty()) root.label else "${root.label}/$path").take(128),
                        )
                    }
                }
            }
        }
        val newest = found.sortedWith(compareByDescending<DocumentItem> { it.modifiedMillis }.thenBy { it.name }).take(limits.keep)
        return Snapshot(clock(), signature(roots), newest)
    }

    private fun signature(roots: List<IndexRoot>): String {
        val digest = MessageDigest.getInstance("SHA-256")
        roots.sortedBy { it.placeId }.forEach { digest.update("${it.placeId}\u001f${it.handle}\u001f${it.label}\n".toByteArray()) }
        return digest.digest().joinToString("") { "%02x".format(it) }.take(16)
    }

    private fun load(): Snapshot = runCatching {
        if (!file.isFile) return@runCatching EMPTY
        val json = JSONObject(file.readText())
        if (json.optInt("v") != 1) return@runCatching EMPTY
        val array = json.optJSONArray("items") ?: JSONArray()
        val items = (0 until minOf(array.length(), limits.keep)).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            DocumentItem(
                placeId = item.optString("p").ifEmpty { return@mapNotNull null },
                path = item.optString("d"),
                name = item.optString("n").ifEmpty { return@mapNotNull null },
                size = item.optLong("s"),
                modifiedMillis = item.optLong("m"),
                mimeType = if (item.isNull("t")) null else item.optString("t"),
                documentUri = item.optString("u").ifEmpty { return@mapNotNull null },
                location = item.optString("l"),
            )
        }
        Snapshot(json.optLong("builtAt"), json.optString("signature"), items)
    }.getOrDefault(EMPTY)

    private fun save(value: Snapshot) {
        val items = JSONArray()
        value.items.forEach {
            items.put(
                JSONObject().put("p", it.placeId).put("d", it.path).put("n", it.name).put("s", it.size).put("m", it.modifiedMillis)
                    .put("t", it.mimeType ?: JSONObject.NULL).put("u", it.documentUri).put("l", it.location),
            )
        }
        val text = JSONObject().put("v", 1).put("builtAt", value.builtAt).put("signature", value.signature).put("items", items).toString()
        runCatching {
            file.parentFile?.mkdirs()
            val temporary = File(file.parentFile, ".${file.name}.tmp")
            temporary.writeText(text)
            ownerOnly(temporary)
            if (!temporary.renameTo(file)) {
                file.writeText(text)
                temporary.delete()
            }
            ownerOnly(file)
        }
    }

    private fun ownerOnly(target: File) {
        target.setReadable(false, false)
        target.setWritable(false, false)
        target.setReadable(true, true)
        target.setWritable(true, true)
    }

    companion object {
        const val FILE_NAME = "document-index.json"
        private val EMPTY = Snapshot(0, "", emptyList())

        /** The app's index: granted places and Download/Bridgey, persisted under no_backup. */
        fun create(context: Context, places: PlacesStore): TreeDocumentIndex = TreeDocumentIndex(
            AndroidDocumentTreeSource(context.applicationContext.contentResolver, places),
            File(context.applicationContext.noBackupFilesDir, FILE_NAME),
            Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "bridgey-document-index").apply { isDaemon = true; priority = Thread.MIN_PRIORITY } },
        )
    }
}

/** Which children count, shared by the index and its tests. */
object DocumentRules {
    /** Dot names (hidden folders and files) and Bridgey's own part files are never indexed. */
    fun hidden(name: String): Boolean = name.startsWith(".") || name.endsWith(".bridgey-part", ignoreCase = true)

    /** Documents are files that are not images or videos (the Photos and Videos tab has those). */
    fun isDocument(mimeType: String?, name: String): Boolean {
        val type = mimeType?.lowercase()
        if (type != null && (type.startsWith("image/") || type.startsWith("video/"))) return false
        if (type == Document.MIME_TYPE_DIR) return false
        val extension = name.substringAfterLast('.', "").lowercase()
        return extension !in mediaExtensions
    }

    private val mediaExtensions = setOf("jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "dng", "mp4", "mov", "mkv", "webm", "3gp")
}

/** Granted trees through DocumentsContract (one child query per folder) and Download/Bridgey through MediaStore. */
class AndroidDocumentTreeSource(private val resolver: ContentResolver, private val places: PlacesStore) : DocumentTreeSource {
    override fun roots(): List<IndexRoot> {
        val roots = ArrayList<IndexRoot>()
        val defaultTree = places.defaultTree.value?.takeIf(places::hasGrant)
        if (defaultTree != null) {
            treeRoot(DEFAULT_PLACE_ID, PlacesStore.DEFAULT_LABEL, defaultTree)?.let(roots::add)
        } else if (Build.VERSION.SDK_INT >= 29) {
            roots += IndexRoot(DEFAULT_PLACE_ID, PlacesStore.DEFAULT_LABEL, MEDIA_ROOT, MEDIA_HANDLE)
        }
        places.places.value.filter { places.hasGrant(it.treeUri) }.forEach { place ->
            treeRoot(place.placeId, place.label, place.treeUri)?.let(roots::add)
        }
        return roots
    }

    private fun treeRoot(placeId: String, label: String, tree: String): IndexRoot? = runCatching {
        IndexRoot(placeId, label, DocumentsContract.getTreeDocumentId(Uri.parse(tree)), tree)
    }.getOrNull()

    override fun children(root: IndexRoot, dirId: String): List<IndexChild> =
        if (root.handle == MEDIA_HANDLE) mediaChildren(dirId) else treeChildren(Uri.parse(root.handle), dirId)

    private fun treeChildren(tree: Uri, dirId: String): List<IndexChild> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, dirId)
        val projection = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED)
        val cursor = runCatching { resolver.query(uri, projection, null, null, null) }.getOrNull() ?: return emptyList()
        return cursor.use {
            val result = ArrayList<IndexChild>(it.count.coerceAtLeast(0))
            while (it.moveToNext()) {
                val id = it.getString(0) ?: continue
                val name = it.getString(1) ?: continue
                val mime = it.getString(2)
                result += IndexChild(
                    id, name, mime == Document.MIME_TYPE_DIR,
                    if (it.isNull(3)) 0 else it.getLong(3),
                    if (it.isNull(4)) 0 else it.getLong(4),
                    mime,
                    DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                )
            }
            result
        }
    }

    /** Bridgey sees only its own Downloads entries without a grant; folders are relative paths ending in "/". */
    private fun mediaChildren(dirId: String): List<IndexChild> {
        if (Build.VERSION.SDK_INT < 29) return emptyList()
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Downloads._ID, MediaStore.Downloads.DISPLAY_NAME, MediaStore.Downloads.RELATIVE_PATH,
            MediaStore.Downloads.SIZE, MediaStore.Downloads.DATE_MODIFIED, MediaStore.Downloads.MIME_TYPE,
        )
        val selection = "${MediaStore.Downloads.RELATIVE_PATH} LIKE ? ESCAPE '\\' AND ${MediaStore.Downloads.IS_PENDING} = 0"
        val escaped = dirId.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        val cursor = runCatching { resolver.query(collection, projection, selection, arrayOf(escaped), null) }.getOrNull() ?: return emptyList()
        val files = ArrayList<IndexChild>()
        val folders = LinkedHashMap<String, IndexChild>()
        cursor.use {
            while (it.moveToNext()) {
                val id = it.getLong(0)
                val name = it.getString(1) ?: continue
                val relative = it.getString(2)?.let { value -> if (value.endsWith("/")) value else "$value/" } ?: continue
                if (!relative.startsWith(dirId)) continue
                if (relative == dirId) {
                    files += IndexChild(
                        relative + name, name, false,
                        if (it.isNull(3)) 0 else it.getLong(3),
                        if (it.isNull(4)) 0 else it.getLong(4) * 1000,
                        it.getString(5),
                        Uri.withAppendedPath(collection, id.toString()).toString(),
                    )
                } else {
                    val child = relative.removePrefix(dirId).substringBefore('/')
                    if (child.isNotEmpty()) folders.getOrPut(child) { IndexChild("$dirId$child/", child, true, 0, 0, Document.MIME_TYPE_DIR, "") }
                }
            }
        }
        return folders.values.toList() + files
    }

    private companion object {
        const val MEDIA_HANDLE = "mediastore"
        const val MEDIA_ROOT = "Download/Bridgey/"
    }
}
