package dev.bridgey.android.browse

import dev.bridgey.android.folders.DEFAULT_PLACE_ID
import dev.bridgey.android.folders.DestinationMode
import dev.bridgey.android.folders.DownloadRefused
import dev.bridgey.android.folders.DownloadTicket
import dev.bridgey.android.folders.FolderCodes
import dev.bridgey.android.folders.FolderPaths
import dev.bridgey.android.folders.FolderReceiveSettings
import dev.bridgey.android.folders.PlaceDirectory
import dev.bridgey.android.folders.PlaceInfo
import dev.bridgey.android.folders.PlaceUnavailableException
import dev.bridgey.android.folders.PlacesListedPayload
import dev.bridgey.android.folders.SendNode
import dev.bridgey.android.folders.ThumbnailKind
import dev.bridgey.android.folders.TreeEntry
import dev.bridgey.android.folders.TreeSendNode
import dev.bridgey.android.folders.TreeStore
import dev.bridgey.android.folders.caseKey
import dev.bridgey.android.folders.placesErrorJson
import dev.bridgey.android.folders.resolveExistingPath
import dev.bridgey.android.folders.utf8Length
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Future
import org.json.JSONArray
import org.json.JSONObject

/** What browsing may do right now on this phone, for one device. */
data class BrowseSettings(
    /** files_browse_draft1: Files on for the device, Android 10 or newer, "Let other devices browse this phone" on. */
    val allowed: Boolean,
    /** "Allow other devices to change files here": uploads allowed. */
    val writable: Boolean,
)

class BrowseEnvironment(
    val places: PlaceDirectory,
    val media: () -> MediaLibrary,
    val documents: () -> DocumentIndex,
    val thumbnails: ThumbnailMaker,
    val settings: () -> BrowseSettings,
    val folderSettings: () -> FolderReceiveSettings,
    /** Starts a download (scan now, hash and send later); throws [DownloadRefused]. */
    val download: (requestId: String, roots: List<SendNode>) -> DownloadTicket,
    /** Browse lane work (listings, downloads): storage calls, off the socket reader. */
    val runBrowse: (() -> Unit) -> Unit,
    /** One coordinator per media request (it waits for the pool and packs batches). */
    val runMedia: (() -> Unit) -> Unit,
    /** Makes thumbnails and previews, about 3 threads. */
    val mediaPool: ExecutorService,
    val clock: () -> Long = System::currentTimeMillis,
    /** Codes, counts and short IDs only: never names, paths or listings. */
    val log: (String) -> Unit = {},
)

/**
 * Serves the Files 2.0 browse requests of one device session (protocol.md "Draft: phone files, media and
 * folders both ways"): places for browsing, folder listings, the media library and recent documents,
 * thumbnails in batches, previews, byte ranges and downloads. Two lanes with their own budgets; media answers
 * go through [sendLow], which never gets ahead of file chunks, acknowledgements or control messages.
 */
class BrowseServer(
    private val env: BrowseEnvironment,
    private val send: (kind: String, payload: JSONObject) -> Unit,
    private val sendLow: (kind: String, payload: JSONObject) -> Unit,
) {
    private val browseWindow = ArrayDeque<Long>()
    private var browseInFlight = 0
    private val mediaWindow = ArrayDeque<Long>()
    private val mediaJobs = LinkedHashMap<String, CancelFlag>()
    private val downloadAnswers = LinkedHashMap<String, Pair<String, JSONObject>>()
    @Volatile private var closed = false

    /** A short-lived cache of folder listings, so thumbnails and ranges of one folder cost one query. */
    private class Listing(val store: TreeStore, val dirId: String, val entries: List<TreeEntry>, val at: Long) {
        val byName: Map<String, TreeEntry> = entries.associateBy { it.name }
    }

    private val listings = object : LinkedHashMap<String, Listing>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Listing>?): Boolean = size > LISTING_CACHE
    }

    // Entry points.

    fun handle(kind: String, json: JSONObject) {
        if (closed) return
        val requestId = requestIdOf(json) ?: return
        if (kind == BrowseKinds.MEDIA_CANCEL) {
            synchronized(this) { mediaJobs.remove(requestId) }?.cancel()
            return
        }
        if (!json.versionIsOne()) return error(requestId, FolderCodes.UNSUPPORTED)
        if (!env.settings().allowed) return error(requestId, FolderCodes.POLICY)
        when (kind) {
            BrowseKinds.PLACES_FILES, BrowseKinds.MEDIA_LIST, BrowseKinds.PLACES_DOWNLOAD -> browseLane(requestId) {
                when (kind) {
                    BrowseKinds.PLACES_FILES -> files(requestId, json)
                    BrowseKinds.MEDIA_LIST -> mediaList(requestId, json)
                    else -> download(requestId, json)
                }
            }
            BrowseKinds.MEDIA_THUMBNAILS, BrowseKinds.MEDIA_PREVIEW, BrowseKinds.MEDIA_RANGE -> mediaLane(requestId, json) { flag ->
                when (kind) {
                    BrowseKinds.MEDIA_THUMBNAILS -> thumbnails(requestId, json, flag)
                    BrowseKinds.MEDIA_PREVIEW -> preview(requestId, json, flag)
                    else -> range(requestId, json, flag)
                }
            }
            else -> error(requestId, FolderCodes.UNSUPPORTED)
        }
    }

    /** places.list with `purpose: "browse"`: every place whatever the folder mode, plus writable, media and documents. */
    fun placesForBrowsing(json: JSONObject) {
        val requestId = requestIdOf(json) ?: return
        if (!env.settings().allowed) return error(requestId, FolderCodes.POLICY)
        browseLane(requestId) {
            val folderSettings = env.folderSettings()
            val list = env.places.places().map { place ->
                val free = if (place.available) runCatching { place.open().freeBytes() }.getOrNull() else null
                PlaceInfo(place.placeId, place.label, place.available, free)
            }
            val fixedLabel = if (folderSettings.mode == DestinationMode.FIXED) env.places.place(folderSettings.defaultPlaceId)?.label else null
            val answer = PlacesListedPayload(requestId, folderSettings.mode, list, fixedLabel,
                dev.bridgey.android.folders.defaultFreeBytes(env.places, folderSettings)).toJson()
                .put("writable", env.settings().writable)
                .put("media", runCatching { env.media().access() }.getOrDefault(MediaAccess.NONE).wire)
                .put("documents", list.any { it.placeId != DEFAULT_PLACE_ID })
            send(dev.bridgey.android.folders.FolderKinds.PLACES_LISTED, answer)
        }
    }

    /** The device session ended: running media requests stop. */
    fun close() {
        closed = true
        val flags = synchronized(this) { mediaJobs.values.toList().also { mediaJobs.clear() } }
        flags.forEach(CancelFlag::cancel)
    }

    // Lanes.

    private fun browseLane(requestId: String, work: () -> Unit) {
        synchronized(this) {
            val now = env.clock()
            while (browseWindow.isNotEmpty() && now - browseWindow.first() >= BrowseLimits.WINDOW_MILLIS) browseWindow.removeFirst()
            if (browseInFlight >= BrowseLimits.BROWSE_IN_FLIGHT || browseWindow.size >= BrowseLimits.BROWSE_PER_WINDOW) {
                env.log("BROWSE busy lane=browse")
                return error(requestId, FolderCodes.BUSY)
            }
            browseWindow.addLast(now)
            browseInFlight++
        }
        env.runBrowse {
            try {
                work()
            } catch (_: PlaceUnavailableException) {
                error(requestId, FolderCodes.PLACE_UNAVAILABLE)
            } catch (_: SecurityException) {
                error(requestId, FolderCodes.PLACE_UNAVAILABLE)
            } catch (_: IOException) {
                error(requestId, FolderCodes.IO_ERROR)
            } finally {
                synchronized(this) { browseInFlight-- }
            }
        }
    }

    private fun mediaLane(requestId: String, json: JSONObject, work: (CancelFlag) -> Unit) {
        val flag = CancelFlag()
        synchronized(this) {
            if (mediaJobs.containsKey(requestId)) return
            json.optString("replaces").takeIf { it.isNotEmpty() }?.let { replaced -> mediaJobs.remove(replaced)?.cancel() }
            val now = env.clock()
            while (mediaWindow.isNotEmpty() && now - mediaWindow.first() >= BrowseLimits.WINDOW_MILLIS) mediaWindow.removeFirst()
            if (mediaJobs.size >= BrowseLimits.MEDIA_ACTIVE || mediaWindow.size >= BrowseLimits.MEDIA_PER_WINDOW) {
                env.log("BROWSE busy lane=media")
                return error(requestId, FolderCodes.BUSY)
            }
            mediaWindow.addLast(now)
            mediaJobs[requestId] = flag
        }
        env.runMedia {
            try {
                if (!flag.cancelled) work(flag)
            } catch (_: PlaceUnavailableException) {
                if (!flag.cancelled) error(requestId, FolderCodes.PLACE_UNAVAILABLE)
            } catch (_: IOException) {
                if (!flag.cancelled) error(requestId, FolderCodes.IO_ERROR)
            } finally {
                synchronized(this) { if (mediaJobs[requestId] === flag) mediaJobs.remove(requestId) }
            }
        }
    }

    /** Active media requests (tests). */
    val activeMediaRequests: Int get() = synchronized(this) { mediaJobs.size }

    private fun error(requestId: String, code: String) {
        env.log("BROWSE error code=$code")
        send(dev.bridgey.android.folders.FolderKinds.PLACES_ERROR, placesErrorJson(requestId, code))
    }

    // Listings.

    private fun listing(placeId: String, path: String, fresh: Boolean): Listing? {
        if (FolderPaths.components(path).any { it.startsWith(".") }) return null
        val key = "$placeId\u0000$path"
        if (!fresh) synchronized(listings) { listings[key] }?.takeIf { env.clock() - it.at < LISTING_TTL_MILLIS }?.let { return it }
        val place = env.places.place(placeId)?.takeIf { it.available } ?: throw PlaceUnavailableException()
        val store = runCatching { place.open() }.getOrElse { throw PlaceUnavailableException(cause = it) }
        val dirId = resolveExistingPath(store, path) ?: return null
        val listing = Listing(store, dirId, store.entries(dirId), env.clock())
        synchronized(listings) { listings[key] = listing }
        return listing
    }

    private fun visible(entry: TreeEntry): Boolean = !entry.name.startsWith(".") && !entry.name.endsWith(".bridgey-part", ignoreCase = true)

    private fun files(requestId: String, json: JSONObject) {
        val placeId = json.optString("placeId").takeIf { dev.bridgey.android.folders.isPlaceId(it) } ?: return error(requestId, FolderCodes.INVALID_MESSAGE)
        val path = (json.opt("path") as? String)?.takeIf(FolderPaths::isValidExistingPath) ?: return error(requestId, FolderCodes.INVALID_MESSAGE)
        val cursor = (json.opt("cursor") as? String)?.take(64)
        val offset = cursor?.takeIf { it.startsWith("o") }?.drop(1)?.toIntOrNull()?.coerceAtLeast(0) ?: 0
        val sort = (json.opt("sort") as? String) ?: "name"
        val descending = json.optBoolean("descending", false)
        val listing = listing(placeId, path, fresh = cursor == null) ?: return error(requestId, FolderCodes.NOT_FOUND)
        val shown = sortEntries(listing.entries.filter(::visible), sort, descending)
        val payload = filesPage(requestId, placeId, path, shown, offset, env.settings().writable)
        send(BrowseKinds.PLACES_FILES_PAGE, payload)
    }

    private fun download(requestId: String, json: JSONObject) {
        synchronized(this) { downloadAnswers[requestId] }?.let { (kind, answer) -> return send(kind, answer) }
        val array = json.optJSONArray("items") ?: return error(requestId, FolderCodes.INVALID_MESSAGE)
        if (array.length() !in 1..BrowseLimits.DOWNLOAD_ITEMS) return error(requestId, FolderCodes.LIMIT_EXCEEDED)
        val refs = (0 until array.length()).map { BrowseRefs.parse(array.optJSONObject(it)) ?: return error(requestId, FolderCodes.INVALID_MESSAGE) }
        val nodes = refs.map { ref -> resolveNode(ref) ?: return error(requestId, FolderCodes.NOT_FOUND) }
        val answer = try {
            val ticket = env.download(requestId, nodes)
            BrowseKinds.PLACES_DOWNLOAD_STARTED to JSONObject().put("version", 1).put("requestId", requestId)
                .put("folderTransferId", ticket.folderTransferId).put("rootName", ticket.rootName).put("fileCount", ticket.fileCount)
                .put("folderCount", ticket.folderCount).put("totalSize", ticket.totalSize)
        } catch (refused: DownloadRefused) {
            dev.bridgey.android.folders.FolderKinds.PLACES_ERROR to placesErrorJson(requestId, refused.code)
        }
        synchronized(this) {
            downloadAnswers[requestId] = answer
            while (downloadAnswers.size > 64) downloadAnswers.remove(downloadAnswers.keys.first())
        }
        env.log("BROWSE download items=${nodes.size} answer=${answer.first}")
        send(answer.first, answer.second)
    }

    private fun mediaList(requestId: String, json: JSONObject) {
        val kind = (json.opt("kind") as? String) ?: "media"
        val limit = ((json.opt("limit") as? Number)?.toInt() ?: BrowseLimits.MEDIA_PAGE_DEFAULT).coerceIn(1, BrowseLimits.MEDIA_PAGE_MAX)
        val cursor = (json.opt("cursor") as? String)?.take(64)
        val media = env.media()
        val documents = env.documents()
        val access = runCatching { media.access() }.getOrDefault(MediaAccess.NONE)
        if (kind != "media") documents.refreshIfStale()
        val (items, next) = when (kind) {
            "media" -> {
                val offset = cursor?.removePrefix("m")?.toIntOrNull()?.coerceAtLeast(0) ?: 0
                val page = if (access == MediaAccess.NONE) emptyList() else media.page(offset, limit + 1)
                val list = page.take(limit).map(::mediaItemJson)
                list to if (page.size > limit) "m${offset + limit}" else null
            }
            "files" -> {
                val offset = cursor?.removePrefix("d")?.toIntOrNull()?.coerceAtLeast(0) ?: 0
                val page = documents.recent(offset, limit + 1)
                page.take(limit).map(::documentJson) to if (page.size > limit) "d${offset + limit}" else null
            }
            "recent" -> recent(cursor, limit, media, documents, access)
            else -> return error(requestId, FolderCodes.INVALID_MESSAGE)
        }
        // At most 32 KiB: keep whole items, and the cursor moves only past what was sent.
        val array = JSONArray()
        var bytes = PAGE_OVERHEAD
        var sent = 0
        for (item in items) {
            val size = utf8Length(item.toString()) + 1
            if (bytes + size > BrowseLimits.PAGE_PLAINTEXT && sent > 0) break
            array.put(item)
            bytes += size
            sent++
        }
        val nextCursor = if (sent < items.size) adjustCursor(kind, cursor, items.subList(0, sent)) else next
        val payload = JSONObject().put("version", 1).put("requestId", requestId).put("kind", kind).put("items", array)
            .put("nextCursor", nextCursor ?: JSONObject.NULL).put("access", access.wire).put("indexing", documents.indexing)
        send(BrowseKinds.MEDIA_PAGE, payload)
    }

    /** A cursor that continues right after [sent] (used when the byte budget cut the page short). */
    private fun adjustCursor(kind: String, cursor: String?, sent: List<JSONObject>): String {
        return when (kind) {
            "media" -> "m${(cursor?.removePrefix("m")?.toIntOrNull() ?: 0) + sent.size}"
            "files" -> "d${(cursor?.removePrefix("d")?.toIntOrNull() ?: 0) + sent.size}"
            else -> {
                val (m, d) = recentOffsets(cursor)
                val mediaSent = sent.count { it.optJSONObject("ref")?.has("mediaId") == true }
                "r${m + mediaSent}.${d + sent.size - mediaSent}"
            }
        }
    }

    private fun recentOffsets(cursor: String?): Pair<Int, Int> {
        val parts = cursor?.takeIf { it.startsWith("r") }?.drop(1)?.split('.')
        return (parts?.getOrNull(0)?.toIntOrNull() ?: 0).coerceAtLeast(0) to (parts?.getOrNull(1)?.toIntOrNull() ?: 0).coerceAtLeast(0)
    }

    private fun recent(cursor: String?, limit: Int, media: MediaLibrary, documents: DocumentIndex, access: MediaAccess): Pair<List<JSONObject>, String?> {
        val (mediaOffset, docOffset) = recentOffsets(cursor)
        val mediaItems = if (access == MediaAccess.NONE) emptyList() else media.page(mediaOffset, limit + 1)
        val docs = documents.recent(docOffset, limit + 1)
        val result = ArrayList<JSONObject>()
        var m = 0
        var d = 0
        while (result.size < limit && (m < mediaItems.size || d < docs.size)) {
            val takeMedia = when {
                m >= mediaItems.size -> false
                d >= docs.size -> true
                else -> maxOf(mediaItems[m].sortMillis, mediaItems[m].modifiedMillis) >= docs[d].modifiedMillis
            }
            if (takeMedia) result += mediaItemJson(mediaItems[m++]) else result += documentJson(docs[d++])
        }
        val more = m < mediaItems.size || d < docs.size
        return result to if (more) "r${mediaOffset + m}.${docOffset + d}" else null
    }

    private fun mediaItemJson(item: MediaItem): JSONObject = JSONObject()
        .put("ref", BrowseRefs.toJson(BrowseRef.Media(item.mediaId))).put("name", item.name).put("size", item.size)
        .put("modified", item.modifiedMillis).put("mimeType", item.mimeType).put("width", item.width ?: JSONObject.NULL)
        .put("height", item.height ?: JSONObject.NULL).put("durationMs", item.durationMs ?: JSONObject.NULL).put("thumb", true)
        .put("location", item.location?.take(BrowseLimits.MAX_LOCATION_CHARS) ?: JSONObject.NULL)

    private fun documentJson(item: DocumentItem): JSONObject = JSONObject()
        .put("ref", BrowseRefs.toJson(BrowseRef.Place(item.placeId, item.path, item.name))).put("name", item.name).put("size", item.size)
        .put("modified", item.modifiedMillis).put("mimeType", item.mimeType ?: JSONObject.NULL).put("width", JSONObject.NULL)
        .put("height", JSONObject.NULL).put("durationMs", JSONObject.NULL)
        .put("thumb", item.mimeType?.let { it.startsWith("image/") || it.startsWith("video/") } == true)
        .put("location", item.location.take(BrowseLimits.MAX_LOCATION_CHARS))

    // Resolving refs.

    private class Resolved(val name: String, val size: Long, val modified: Long?, val thumb: ThumbSource?, val open: () -> InputStream, val node: SendNode)

    private fun resolve(ref: BrowseRef): Resolved? = when (ref) {
        is BrowseRef.Media -> {
            val media = env.media()
            if (media.access() == MediaAccess.NONE) null else media.item(ref.mediaId)?.let { item ->
                Resolved(item.name, item.size, item.modifiedMillis, ThumbSource(item.uri, item.mimeType, ThumbSource.Kind.MEDIA_STORE, true),
                    { media.open(ref.mediaId) ?: throw IOException("gone") }, MediaSendNode(item, media))
            }
        }
        is BrowseRef.Place -> {
            if (ref.name.startsWith(".") || ref.name.endsWith(".bridgey-part", ignoreCase = true)) {
                null
            } else {
                val listing = listing(ref.placeId, ref.path, fresh = false)
                val entry = listing?.byName?.get(ref.name) ?: listing(ref.placeId, ref.path, fresh = true)?.byName?.get(ref.name)
                val store = listing?.store
                if (entry == null || store == null) {
                    null
                } else {
                    val uri = entry.uri ?: store.uriOf(entry.id)
                    val kind = if (store.thumbnailKind == ThumbnailKind.MEDIA_STORE) ThumbSource.Kind.MEDIA_STORE else ThumbSource.Kind.DOCUMENT
                    val thumb = if (entry.isDirectory) null else ThumbSource(uri, entry.mimeType, kind, entry.providerThumbnail)
                    Resolved(entry.name, entry.size ?: 0, entry.modifiedMillis, thumb, { store.openInput(entry.id) }, TreeSendNode(store, entry))
                }
            }
        }
    }

    private fun resolveNode(ref: BrowseRef): SendNode? = resolve(ref)?.node

    // Media lane.

    private fun thumbnails(requestId: String, json: JSONObject, flag: CancelFlag) {
        val array = json.optJSONArray("items")
        if (array == null || array.length() !in 1..BrowseLimits.THUMB_ITEMS) return error(requestId, FolderCodes.INVALID_MESSAGE)
        val size = ((json.opt("size") as? Number)?.toInt() ?: BrowseLimits.THUMB_DEFAULT).coerceIn(BrowseLimits.THUMB_MIN, BrowseLimits.THUMB_MAX)
        val items = (0 until array.length()).map { index ->
            val item = array.optJSONObject(index)
            val key = item?.optString("key")?.takeIf(::isThumbnailKey) ?: return error(requestId, FolderCodes.INVALID_MESSAGE)
            key to BrowseRefs.parse(item.optJSONObject("ref"))
        }
        val futures: List<Future<EncodedImage?>> = items.map { (_, ref) ->
            env.mediaPool.submit(Callable {
                if (flag.cancelled || ref == null) return@Callable null
                val source = runCatching { resolve(ref) }.getOrNull()?.thumb ?: return@Callable null
                runCatching { env.thumbnails.make(source, size, BrowseLimits.THUMB_MAX_BYTES, preview = false, cancel = flag) }.getOrNull()
                    ?.takeIf { it.bytes.size <= BrowseLimits.THUMB_MAX_BYTES }
            })
        }
        flag.onCancel { futures.forEach { it.cancel(false) } }
        val packer = ThumbnailBatcher(requestId) { batch -> if (!flag.cancelled) sendLow(BrowseKinds.MEDIA_THUMBNAILS_BATCH, batch) }
        for ((index, future) in futures.withIndex()) {
            if (flag.cancelled) return
            val image = runCatching { future.get() }.getOrNull()
            val key = items[index].first
            if (image == null) packer.missing(key) else packer.add(key, image)
            // Latency first: what is ready goes out before waiting on a slow one.
            if (index + 1 < futures.size && !futures[index + 1].isDone) packer.flush(done = false)
        }
        if (!flag.cancelled) packer.flush(done = true)
    }

    private fun preview(requestId: String, json: JSONObject, flag: CancelFlag) {
        val ref = BrowseRefs.parse(json.optJSONObject("ref")) ?: return error(requestId, FolderCodes.INVALID_MESSAGE)
        val size = ((json.opt("size") as? Number)?.toInt() ?: 1600).coerceIn(BrowseLimits.PREVIEW_MIN, BrowseLimits.PREVIEW_MAX)
        val resolved = resolve(ref) ?: return error(requestId, FolderCodes.NOT_FOUND)
        val source = resolved.thumb ?: return error(requestId, FolderCodes.UNSUPPORTED)
        val image = env.mediaPool.submit(Callable {
            runCatching { env.thumbnails.make(source, size, BrowseLimits.PREVIEW_MAX_BYTES, preview = true, cancel = flag) }.getOrNull()
        }).let { future ->
            flag.onCancel { future.cancel(false) }
            runCatching { future.get() }.getOrNull()
        }
        if (flag.cancelled) return
        if (image == null || image.bytes.size > BrowseLimits.PREVIEW_MAX_BYTES) return error(requestId, FolderCodes.UNSUPPORTED)
        val count = ((image.bytes.size + BrowseLimits.PART_BYTES - 1) / BrowseLimits.PART_BYTES).coerceAtLeast(1)
        for (index in 0 until count) {
            if (flag.cancelled) return
            val from = index * BrowseLimits.PART_BYTES
            val part = image.bytes.copyOfRange(from, minOf(image.bytes.size, from + BrowseLimits.PART_BYTES))
            sendLow(
                BrowseKinds.MEDIA_PREVIEW_PART,
                JSONObject().put("version", 1).put("requestId", requestId).put("index", index).put("count", count).put("mimeType", image.mimeType)
                    .put("width", image.width).put("height", image.height).put("tint", image.tint?.let(::tintHex) ?: JSONObject.NULL)
                    .put("data", java.util.Base64.getEncoder().encodeToString(part)),
            )
        }
    }

    private fun range(requestId: String, json: JSONObject, flag: CancelFlag) {
        val ref = BrowseRefs.parse(json.optJSONObject("ref")) ?: return error(requestId, FolderCodes.INVALID_MESSAGE)
        val offset = (json.opt("offset") as? Number)?.toLong()?.takeIf { it >= 0 } ?: return error(requestId, FolderCodes.INVALID_MESSAGE)
        val length = (json.opt("length") as? Number)?.toLong()?.takeIf { it in 1..BrowseLimits.RANGE_MAX } ?: return error(requestId, FolderCodes.INVALID_MESSAGE)
        val resolved = resolve(ref) ?: return error(requestId, FolderCodes.NOT_FOUND)
        if (resolved.node.isDirectory) return error(requestId, FolderCodes.UNSUPPORTED)
        val fileSize = resolved.size
        fun part(at: Long, data: ByteArray, last: Boolean) = sendLow(
            BrowseKinds.MEDIA_RANGE_PART,
            JSONObject().put("version", 1).put("requestId", requestId).put("offset", at).put("fileSize", fileSize)
                .put("modified", resolved.modified ?: JSONObject.NULL).put("data", java.util.Base64.getEncoder().encodeToString(data)).put("last", last),
        )
        if (offset >= fileSize) return part(offset, ByteArray(0), true)
        resolved.open().use { input ->
            var skipped = 0L
            while (skipped < offset) {
                val step = input.skip(offset - skipped)
                if (step <= 0) {
                    if (input.read() < 0) return part(offset, ByteArray(0), true)
                    skipped++
                } else {
                    skipped += step
                }
            }
            val end = minOf(fileSize, offset + length)
            var at = offset
            val buffer = ByteArray(BrowseLimits.PART_BYTES)
            while (at < end && !flag.cancelled) {
                val wanted = minOf(BrowseLimits.PART_BYTES.toLong(), end - at).toInt()
                var count = 0
                while (count < wanted) {
                    val read = input.read(buffer, count, wanted - count)
                    if (read < 0) break
                    count += read
                }
                val eof = count < wanted
                part(at, buffer.copyOf(count), last = eof || at + count >= end)
                at += count
                if (eof || count == 0) break
            }
        }
    }

    companion object {
        const val LISTING_CACHE = 16
        const val LISTING_TTL_MILLIS = 15_000L

        /** Everything in a page except its entries, with room to spare. */
        const val PAGE_OVERHEAD = 512

        fun comparator(sort: String): Comparator<TreeEntry> {
            val byName = compareBy<TreeEntry>({ caseKey(it.name) }, { it.name })
            return when (sort) {
                "modified" -> compareBy<TreeEntry> { it.modifiedMillis ?: Long.MIN_VALUE }.then(byName)
                "size" -> compareBy<TreeEntry> { it.size ?: -1L }.then(byName)
                "kind" -> compareBy<TreeEntry> { it.mimeType ?: it.name.substringAfterLast('.', "").lowercase() }.then(byName)
                else -> byName
            }
        }

        /** Folders first, then files, each in [sort] order. */
        fun sortEntries(entries: List<TreeEntry>, sort: String, descending: Boolean): List<TreeEntry> {
            val order = comparator(sort).let { if (descending) it.reversed() else it }
            return entries.filter { it.isDirectory }.sortedWith(order) + entries.filter { !it.isDirectory }.sortedWith(order)
        }

        fun entryJson(entry: TreeEntry): JSONObject = JSONObject().put("name", entry.name).put("dir", entry.isDirectory)
            .put("size", if (entry.isDirectory) JSONObject.NULL else entry.size ?: JSONObject.NULL)
            .put("modified", entry.modifiedMillis ?: JSONObject.NULL)
            .put("mimeType", if (entry.isDirectory) JSONObject.NULL else entry.mimeType ?: JSONObject.NULL)
            .put("thumb", !entry.isDirectory && (entry.providerThumbnail || entry.mimeType?.startsWith("image/") == true || entry.mimeType?.startsWith("video/") == true))

        /** One places.files_page: at most 200 entries and 32 KiB, from [offset] of the sorted listing. */
        fun filesPage(requestId: String, placeId: String, path: String, shown: List<TreeEntry>, offset: Int, writable: Boolean): JSONObject {
            val start = offset.coerceIn(0, shown.size)
            val array = JSONArray()
            var bytes = PAGE_OVERHEAD + utf8Length(JSONObject.quote(path)) + utf8Length(placeId)
            var index = start
            while (index < shown.size && array.length() < BrowseLimits.FILES_PAGE_ENTRIES) {
                val item = entryJson(shown[index])
                val size = utf8Length(item.toString()) + 1
                if (bytes + size > BrowseLimits.PAGE_PLAINTEXT && array.length() > 0) break
                array.put(item)
                bytes += size
                index++
            }
            return JSONObject().put("version", 1).put("requestId", requestId).put("placeId", placeId).put("path", path).put("entries", array)
                .put("folderCount", shown.count { it.isDirectory }).put("fileCount", shown.count { !it.isDirectory })
                .put("nextCursor", if (index < shown.size) "o$index" else JSONObject.NULL).put("writable", writable)
        }
    }
}

/**
 * Packs thumbnails into media.thumbnails_batch messages of at most 44 KiB plaintext, in the order added.
 * [flush] sends what is waiting (with the missing keys); the last call has `done: true`.
 */
class ThumbnailBatcher(private val requestId: String, private val emit: (JSONObject) -> Unit) {
    private var thumbs = JSONArray()
    private var missing = JSONArray()
    private var bytes = OVERHEAD
    var batches = 0
        private set

    fun add(key: String, image: EncodedImage) {
        val data = java.util.Base64.getEncoder().encodeToString(image.bytes)
        val thumb = JSONObject().put("key", key).put("mimeType", image.mimeType).put("width", image.width).put("height", image.height)
            .put("tint", image.tint?.let(::tintHex) ?: JSONObject.NULL).put("data", data)
        // As written: JSON escapes "/" in base64 as "\/"; the other fields are short ASCII.
        val size = data.length + data.count { it == '/' } + key.length + image.mimeType.length + THUMB_FIELDS
        if (bytes + size > BrowseLimits.MEDIA_PLAINTEXT && (thumbs.length() > 0 || missing.length() > 0)) flush(done = false)
        thumbs.put(thumb)
        bytes += size
    }

    fun missing(key: String) {
        val size = key.length + 3
        if (bytes + size > BrowseLimits.MEDIA_PLAINTEXT) flush(done = false)
        missing.put(key)
        bytes += size
    }

    fun flush(done: Boolean) {
        if (!done && thumbs.length() == 0 && missing.length() == 0) return
        emit(JSONObject().put("version", 1).put("requestId", requestId).put("thumbs", thumbs).put("missing", missing).put("done", done))
        batches++
        thumbs = JSONArray()
        missing = JSONArray()
        bytes = OVERHEAD
    }

    private companion object {
        /** The batch without thumbnails: version, requestId, the arrays and done. */
        const val OVERHEAD = 160

        /** A thumbnail's field names, numbers, tint and punctuation, with room to spare. */
        const val THUMB_FIELDS = 120
    }
}

/** A MediaStore photo or video as a file of a download. */
class MediaSendNode(private val item: MediaItem, private val media: MediaLibrary) : SendNode {
    override val name: String get() = item.name
    override val isDirectory: Boolean get() = false
    override val size: Long get() = item.size
    override val modifiedMillis: Long? get() = item.modifiedMillis
    override val source: String? get() = item.uri
    override fun children(): List<SendNode> = emptyList()
    override fun open(): InputStream = media.open(item.mediaId) ?: throw IOException("gone")
}
