package dev.bridgey.android.browse.engine

import dev.bridgey.android.browse.BrowseEnvironment
import dev.bridgey.android.browse.BrowseServer
import dev.bridgey.android.browse.BrowseSettings
import dev.bridgey.android.browse.CancelFlag
import dev.bridgey.android.browse.DocumentIndex
import dev.bridgey.android.browse.DocumentItem
import dev.bridgey.android.browse.EncodedImage
import dev.bridgey.android.browse.MediaAccess
import dev.bridgey.android.browse.MediaItem
import dev.bridgey.android.browse.MediaLibrary
import dev.bridgey.android.browse.ThumbSource
import dev.bridgey.android.browse.ThumbnailMaker
import dev.bridgey.android.folders.DEFAULT_PLACE_ID
import dev.bridgey.android.folders.DownloadRefused
import dev.bridgey.android.folders.DownloadTicket
import dev.bridgey.android.folders.FolderReceiveSettings
import dev.bridgey.android.folders.FolderScanner
import dev.bridgey.android.folders.MemoryPlaces
import dev.bridgey.android.folders.MemoryTreeStore
import dev.bridgey.android.folders.SendNode
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject

class FakeMedia(var access: MediaAccess = MediaAccess.FULL) : MediaLibrary {
    val items = ArrayList<MediaItem>()
    val contents = HashMap<Long, ByteArray>()

    fun add(id: Long, name: String, sortMillis: Long, bytes: ByteArray = ByteArray(1000) { (it + id).toByte() }, mime: String = "image/jpeg") {
        items += MediaItem(id, name, bytes.size.toLong(), sortMillis, sortMillis, mime, 4000, 3000, null, "Camera", "content://media/external/file/$id")
        contents[id] = bytes
    }

    override fun access(): MediaAccess = access
    override fun page(offset: Int, limit: Int): List<MediaItem> =
        items.sortedWith(compareByDescending<MediaItem> { it.sortMillis }.thenByDescending { it.mediaId }).drop(offset).take(limit)
    override fun item(mediaId: Long): MediaItem? = items.firstOrNull { it.mediaId == mediaId }
    override fun open(mediaId: Long): InputStream? = contents[mediaId]?.let(::ByteArrayInputStream)
}

class FakeDocuments(val items: MutableList<DocumentItem> = ArrayList()) : DocumentIndex {
    override var indexing: Boolean = false
    var refreshes = 0
    override fun recent(offset: Int, limit: Int): List<DocumentItem> = items.sortedByDescending { it.modifiedMillis }.drop(offset).take(limit)
    override fun refreshIfStale() {
        refreshes++
    }
}

/** Thumbnails of a fixed size in bytes (the URI's hash colours the tint); [gate] holds them back when set. */
class FakeThumbs(var bytes: Int = 9_000) : ThumbnailMaker {
    val made = java.util.Collections.synchronizedList(ArrayList<String>())
    @Volatile var gate: CountDownLatch? = null
    @Volatile var fail: Set<String> = emptySet()

    override fun make(source: ThumbSource, size: Int, maxBytes: Int, preview: Boolean, cancel: CancelFlag): EncodedImage? {
        gate?.await(5, TimeUnit.SECONDS)
        if (cancel.cancelled || source.uri in fail || !(source.isImage || source.isVideo)) return null
        made += source.uri
        val count = minOf(bytes, maxBytes)
        return EncodedImage(ByteArray(count) { (it % 251).toByte() }, "image/webp", size, size * 3 / 4, 0x336699)
    }
}

/** A phone's browse server with in-memory places, media and documents; answers are recorded in order. */
class BrowseHarness(
    var allowed: Boolean = true,
    var writable: Boolean = false,
    clock: () -> Long = { System.currentTimeMillis() },
) {
    val places = MemoryPlaces()
    val downloads = MemoryTreeStore(supportsCreateFolder = false)
    val pictures = MemoryTreeStore()
    val media = FakeMedia()
    val documents = FakeDocuments()
    val thumbs = FakeThumbs()
    val sent = java.util.Collections.synchronizedList(ArrayList<Pair<String, JSONObject>>())
    val low = java.util.Collections.synchronizedList(ArrayList<Pair<String, JSONObject>>())
    val pool = Executors.newFixedThreadPool(3)
    val started = ArrayList<List<SendNode>>()
    var refuseDownload: String? = null

    init {
        places.entries += MemoryPlaces.Entry(DEFAULT_PLACE_ID, "Download/Bridgey", downloads)
        places.entries += MemoryPlaces.Entry(PICTURES, "Pictures", pictures)
    }

    val server = BrowseServer(
        BrowseEnvironment(
            places = places,
            media = { media },
            documents = { documents },
            thumbnails = thumbs,
            settings = { BrowseSettings(allowed, writable) },
            folderSettings = { FolderReceiveSettings() },
            download = { _, roots ->
                refuseDownload?.let { throw DownloadRefused(it) }
                started += roots
                val scan = FolderScanner.scanItems(roots)
                DownloadTicket(UUID.randomUUID().toString(), scan.rootName, scan.fileCount, scan.folderCount, scan.totalSize)
            },
            runBrowse = { it() },
            runMedia = { it() },
            mediaPool = pool,
            clock = clock,
        ),
        send = { kind, payload -> sent += kind to JSONObject(payload.toString()) },
        sendLow = { kind, payload -> low += kind to JSONObject(payload.toString()) },
    )

    fun request(kind: String, fields: JSONObject = JSONObject()): String {
        val id = fields.optString("requestId").ifEmpty { UUID.randomUUID().toString() }
        server.handle(kind, fields.put("version", 1).put("requestId", id))
        return id
    }

    fun answer(id: String): Pair<String, JSONObject>? = synchronized(sent) { sent.lastOrNull { it.second.optString("requestId") == id } }
    fun lowFor(id: String): List<Pair<String, JSONObject>> = synchronized(low) { low.filter { it.second.optString("requestId") == id } }

    companion object {
        const val PICTURES = "q3Jx0bVv1eG7tq8Wm2l5wA"

        fun placeRef(placeId: String, path: String, name: String): JSONObject = JSONObject().put("placeId", placeId).put("path", path).put("name", name)
        fun mediaRef(id: Long): JSONObject = JSONObject().put("mediaId", id.toString())
        fun items(vararg pairs: Pair<String, JSONObject>): JSONArray = JSONArray().apply { pairs.forEach { (key, ref) -> put(JSONObject().put("key", key).put("ref", ref)) } }
    }
}
