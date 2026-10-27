package dev.bridgey.android.folders

import java.io.IOException
import org.json.JSONObject

/**
 * Serves places.* for one device session (4.5, 5.4, section 9). `places.list` always answers with this phone's
 * mode; browsing and folder creation only in `sender_picks`. Folder names and two counts only: never URIs, file
 * names, sizes or dates. At most 4 requests in flight and 20 per 10 seconds, else `busy`.
 *
 * Requests run on [run] (storage calls can be slow); answers go through [send] as encrypted payloads.
 */
class PlacesServer(
    private val places: PlaceDirectory,
    private val settings: () -> FolderReceiveSettings,
    private val send: (kind: String, payload: JSONObject) -> Unit,
    private val run: (() -> Unit) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
) {
    private val window = ArrayDeque<Long>()
    private var inFlight = 0

    /** Repeated create requests answer the first answer and create nothing (per session). */
    private val created = LinkedHashMap<String, Pair<String, JSONObject>>()

    /** [json] is the decrypted payload of a places.list, places.browse or places.create_folder. */
    fun handle(kind: String, json: JSONObject) {
        val requestId = json.optString("requestId").takeIf(::isWireId) ?: return
        synchronized(this) {
            created[requestId]?.let { (answerKind, answer) ->
                send(answerKind, answer)
                return
            }
            val now = clock()
            while (window.isNotEmpty() && now - window.first() >= FolderLimits.PLACES_WINDOW_MILLIS) window.removeFirst()
            if (inFlight >= FolderLimits.PLACES_IN_FLIGHT || window.size >= FolderLimits.PLACES_PER_WINDOW) {
                log("PLACES busy")
                send(FolderKinds.PLACES_ERROR, placesErrorJson(requestId, FolderCodes.BUSY))
                return
            }
            window.addLast(now)
            inFlight++
        }
        run {
            try {
                val (answerKind, answer) = answer(kind, requestId, json)
                if (kind == FolderKinds.PLACES_CREATE_FOLDER) synchronized(this) {
                    created[requestId] = answerKind to answer
                    while (created.size > 256) created.remove(created.keys.first())
                }
                send(answerKind, answer)
            } finally {
                synchronized(this) { inFlight-- }
            }
        }
    }

    private fun error(requestId: String, code: String): Pair<String, JSONObject> {
        log("PLACES error code=$code")
        return FolderKinds.PLACES_ERROR to placesErrorJson(requestId, code)
    }

    private fun answer(kind: String, requestId: String, json: JSONObject): Pair<String, JSONObject> {
        val current = settings()
        return when (kind) {
            FolderKinds.PLACES_LIST -> {
                PlacesListPayload.parse(json) ?: return error(requestId, FolderCodes.INVALID_MESSAGE)
                FolderKinds.PLACES_LISTED to listed(requestId, current).toJson()
            }
            FolderKinds.PLACES_BROWSE -> {
                val request = PlacesBrowsePayload.parse(json) ?: return error(requestId, FolderCodes.INVALID_MESSAGE)
                if (current.mode != DestinationMode.SENDER_PICKS) return error(requestId, FolderCodes.POLICY)
                browse(request)
            }
            FolderKinds.PLACES_CREATE_FOLDER -> {
                val request = PlacesCreateFolderPayload.parse(json) ?: return error(requestId, FolderCodes.INVALID_MESSAGE)
                if (current.mode != DestinationMode.SENDER_PICKS) return error(requestId, FolderCodes.POLICY)
                create(request)
            }
            else -> error(requestId, FolderCodes.UNSUPPORTED)
        }
    }

    private fun listed(requestId: String, current: FolderReceiveSettings): PlacesListedPayload {
        val list = if (current.mode == DestinationMode.SENDER_PICKS) {
            places.places().take(FolderLimits.MAX_PLACES + 1).map { place ->
                val free = if (place.available) runCatching { place.open().freeBytes() }.getOrNull() else null
                PlaceInfo(place.placeId, place.label, place.available, free)
            }
        } else {
            emptyList()
        }
        val fixedLabel = if (current.mode == DestinationMode.FIXED) places.place(current.defaultPlaceId)?.label else null
        return PlacesListedPayload(requestId, current.mode, list, fixedLabel, defaultFreeBytes(places, current))
    }

    private fun openDir(placeId: String, path: String): Pair<TreeStore, String>? {
        val place = places.place(placeId)?.takeIf { it.available } ?: throw PlaceUnavailableException()
        val store = runCatching { place.open() }.getOrElse { throw PlaceUnavailableException(cause = it) }
        val dirId = resolveExistingPath(store, path) ?: return null
        return store to dirId
    }

    private fun browse(request: PlacesBrowsePayload): Pair<String, JSONObject> {
        val (store, dirId) = try {
            openDir(request.placeId, request.path)
        } catch (error: IOException) {
            return error(request.requestId, FolderCodes.PLACE_UNAVAILABLE)
        } ?: return error(request.requestId, FolderCodes.NOT_FOUND)
        val children = try {
            store.children(dirId)
        } catch (error: IOException) {
            return error(request.requestId, FolderCodes.PLACE_UNAVAILABLE)
        }
        // Hidden items (names starting with ".", part files included) are neither listed nor counted.
        val visible = children.filterNot { it.name.startsWith(".") }
        val folders = visible.filter { it.isDirectory }.map { it.name }
            .sortedWith(compareBy<String> { caseKey(it) }.thenBy { it })
        val start = decodeCursor(request.cursor)?.coerceIn(0, folders.size) ?: 0
        val page = ArrayList<String>()
        var bytes = BROWSE_OVERHEAD_BYTES + utf8Length(request.path) + utf8Length(request.placeId)
        var index = start
        while (index < folders.size && page.size < FolderLimits.MAX_BROWSE_NAMES) {
            // Escaped JSON can be larger than the name: count it as written.
            val size = JSONObject.quote(folders[index]).toByteArray(Charsets.UTF_8).size + 1
            if (bytes + size > FolderLimits.LARGE_PLAINTEXT && page.isNotEmpty()) break
            page += folders[index]
            bytes += size
            index++
        }
        val next = if (index < folders.size) encodeCursor(index) else null
        val payload = PlacesChildrenPayload(
            requestId = request.requestId,
            placeId = request.placeId,
            path = request.path,
            folders = page,
            fileCount = visible.count { !it.isDirectory },
            folderCount = folders.size,
            nextCursor = next,
        )
        return FolderKinds.PLACES_CHILDREN to payload.toJson()
    }

    private fun create(request: PlacesCreateFolderPayload): Pair<String, JSONObject> {
        if (!PortableName.isPortable(request.name)) return error(request.requestId, FolderCodes.INVALID_NAME)
        val (store, dirId) = try {
            openDir(request.placeId, request.path)
        } catch (error: IOException) {
            return error(request.requestId, FolderCodes.PLACE_UNAVAILABLE)
        } ?: return error(request.requestId, FolderCodes.NOT_FOUND)
        // The MediaStore fallback cannot make folders on its own.
        if (!store.supportsCreateFolder) return error(request.requestId, FolderCodes.POLICY)
        return try {
            if (store.children(dirId).any { caseKey(it.name) == caseKey(request.name) }) return error(request.requestId, FolderCodes.EXISTS)
            store.createDirectory(dirId, request.name)
            log("PLACES folder created")
            FolderKinds.PLACES_FOLDER_CREATED to placesFolderCreatedJson(request)
        } catch (error: IOException) {
            error(request.requestId, storageErrorCode(error).let { if (it == FolderCodes.IO_ERROR) FolderCodes.PLACE_UNAVAILABLE else it })
        }
    }

    private fun encodeCursor(index: Int): String = "o$index"

    private fun decodeCursor(cursor: String?): Int? = cursor?.takeIf { it.startsWith("o") }?.drop(1)?.toIntOrNull()

    private companion object {
        /** Everything in places.children except the names, with room to spare. */
        const val BROWSE_OVERHEAD_BYTES = 512
    }
}
