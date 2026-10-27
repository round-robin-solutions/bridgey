package dev.bridgey.android.browse

import dev.bridgey.android.folders.FolderLimits
import dev.bridgey.android.folders.FolderPaths
import dev.bridgey.android.folders.isPlaceId
import dev.bridgey.android.folders.isWireId
import dev.bridgey.android.folders.utf8Length
import org.json.JSONObject

/*
 * Files 2.0 browse messages (protocol.md "Draft: phone files, media and folders both ways"): kinds, limits,
 * refs and small payload helpers. Pure JSON, so the server and its tests run on the JVM. macOS reads the same
 * fields in its PhoneFilesController.
 */

object BrowseKinds {
    const val PLACES_FILES = "places.files"
    const val PLACES_FILES_PAGE = "places.files_page"
    const val MEDIA_LIST = "media.list"
    const val MEDIA_PAGE = "media.page"
    const val MEDIA_THUMBNAILS = "media.thumbnails"
    const val MEDIA_THUMBNAILS_BATCH = "media.thumbnails_batch"
    const val MEDIA_PREVIEW = "media.preview"
    const val MEDIA_PREVIEW_PART = "media.preview_part"
    const val MEDIA_RANGE = "media.range"
    const val MEDIA_RANGE_PART = "media.range_part"
    const val MEDIA_CANCEL = "media.cancel"
    const val PLACES_DOWNLOAD = "places.download"
    const val PLACES_DOWNLOAD_STARTED = "places.download_started"

    /** Requests this phone serves (places.list with purpose browse goes through the places router). */
    val requests = setOf(PLACES_FILES, MEDIA_LIST, MEDIA_THUMBNAILS, MEDIA_PREVIEW, MEDIA_RANGE, MEDIA_CANCEL, PLACES_DOWNLOAD)

    /** Answers a phone never accepts (it only serves): dropped quietly. */
    val answers = setOf(PLACES_FILES_PAGE, MEDIA_PAGE, MEDIA_THUMBNAILS_BATCH, MEDIA_PREVIEW_PART, MEDIA_RANGE_PART, PLACES_DOWNLOAD_STARTED)

    val mediaLane = setOf(MEDIA_THUMBNAILS, MEDIA_PREVIEW, MEDIA_RANGE)

    /** Every request is small. */
    fun requestPlaintextLimit(kind: String): Int = FolderLimits.SMALL_PLAINTEXT
}

object BrowseLimits {
    const val FILES_PAGE_ENTRIES = 200
    const val MEDIA_PAGE_DEFAULT = 100
    const val MEDIA_PAGE_MAX = 200

    /** places.files_page and media.page plaintext. */
    const val PAGE_PLAINTEXT = 32 * 1024

    /** media.thumbnails_batch, media.preview_part and media.range_part plaintext. */
    const val MEDIA_PLAINTEXT = 45_056

    const val THUMB_ITEMS = 64
    const val THUMB_MIN = 64
    const val THUMB_MAX = 512
    const val THUMB_DEFAULT = 256
    const val THUMB_MAX_BYTES = 24 * 1024

    const val PREVIEW_MIN = 512
    const val PREVIEW_MAX = 2048
    const val PREVIEW_MAX_BYTES = 1024 * 1024

    /** Image or file bytes per preview or range part. */
    const val PART_BYTES = 32 * 1024
    const val RANGE_MAX = 4L * 1024 * 1024

    const val DOWNLOAD_ITEMS = 100

    const val BROWSE_IN_FLIGHT = 4
    const val BROWSE_PER_WINDOW = 40
    const val MEDIA_ACTIVE = 4
    const val MEDIA_PER_WINDOW = 60
    const val WINDOW_MILLIS = 10_000L

    const val MAX_LOCATION_CHARS = 128
}

private val keyPattern = Regex("^[A-Za-z0-9_-]{1,64}$")
private val mediaIdPattern = Regex("^[0-9]{1,20}$")

fun isThumbnailKey(value: String?): Boolean = value != null && keyPattern.matches(value)

/** One existing component (5.3): 1 to 255 bytes, no separator, NUL or control characters, never "." or "..". */
fun isExistingName(name: String?): Boolean = name != null && name.isNotEmpty() && name != "." && name != ".." &&
    !name.contains('/') && utf8Length(name) <= FolderLimits.MAX_EXISTING_COMPONENT_BYTES && name.none { it.code < 0x20 || it.code == 0x7f }

private fun JSONObject.string(key: String): String? = if (has(key) && !isNull(key)) opt(key) as? String else null

object BrowseRefs {
    /** A `ref` object, strictly: a place item with existing-path rules and an exact name, or digits for a media ID. */
    fun parse(json: JSONObject?): BrowseRef? {
        if (json == null) return null
        val mediaId = json.string("mediaId")
        if (mediaId != null) {
            if (json.has("placeId") || !mediaIdPattern.matches(mediaId)) return null
            return mediaId.toLongOrNull()?.takeIf { it >= 0 }?.let(BrowseRef::Media)
        }
        val placeId = json.string("placeId")?.takeIf(::isPlaceId) ?: return null
        val path = json.string("path")?.takeIf(FolderPaths::isValidExistingPath) ?: return null
        val name = json.string("name")?.takeIf(::isExistingName) ?: return null
        return BrowseRef.Place(placeId, path, name)
    }

    fun toJson(ref: BrowseRef): JSONObject = when (ref) {
        is BrowseRef.Media -> JSONObject().put("mediaId", ref.mediaId.toString())
        is BrowseRef.Place -> JSONObject().put("placeId", ref.placeId).put("path", ref.path).put("name", ref.name)
    }
}

/** The request ID of any browse request, or null. */
fun requestIdOf(json: JSONObject): String? = json.string("requestId")?.takeIf(::isWireId)

fun JSONObject.versionIsOne(): Boolean = (opt("version") as? Number)?.toLong() == 1L
