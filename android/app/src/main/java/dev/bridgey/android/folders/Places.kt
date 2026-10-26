package dev.bridgey.android.folders

import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import java.security.SecureRandom
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** A folder the user granted once (6.1). The tree URI never leaves the phone. */
data class Place(
    val placeId: String,
    val treeUri: String,
    val label: String,
    val storageTitle: String?,
    val addedAtMillis: Long,
    /** Not on ExternalStorageProvider (internal storage, SD card, USB drive): allowed, marked "May be slow". */
    val otherProvider: Boolean = false,
)

/** A place as Settings shows it. */
data class PlaceStatus(val place: Place, val available: Boolean)

/**
 * The places store: granted SAF trees in owner-only app preferences (the app has allowBackup off), plus the
 * optional full-access grant of Download/Bridgey. Keeps Android's persisted grants in step: Add takes one,
 * Remove releases it.
 */
class PlacesStore(context: Context) {
    private val appContext = context.applicationContext
    private val resolver: ContentResolver = context.applicationContext.contentResolver
    private val preferences = context.applicationContext.getSharedPreferences("bridgey.places", Context.MODE_PRIVATE)
    private val mutablePlaces = MutableStateFlow(load())
    private val mutableDefaultTree = MutableStateFlow(preferences.getString(KEY_DEFAULT_TREE, null))

    val places: StateFlow<List<Place>> = mutablePlaces.asStateFlow()

    /** Download/Bridgey with full access: its tree, or null for the MediaStore fallback. */
    val defaultTree: StateFlow<String?> = mutableDefaultTree.asStateFlow()

    sealed interface AddResult {
        data class Added(val place: Place) : AddResult
        data class Existing(val place: Place) : AddResult
        data object Full : AddResult
        data object NotUsable : AddResult
    }

    /** Takes the persistable grant and stores the place. The picker's result URI. */
    @Synchronized
    fun add(treeUri: Uri, now: Long = System.currentTimeMillis()): AddResult {
        mutablePlaces.value.firstOrNull { it.treeUri == treeUri.toString() }?.let { return AddResult.Existing(it) }
        if (mutablePlaces.value.size >= FolderLimits.MAX_PLACES) return AddResult.Full
        if (!takeGrant(treeUri)) return AddResult.NotUsable
        val store = runCatching { SafTreeStore(resolver, treeUri) }.getOrNull()
        if (store == null || !store.supportsCreate()) {
            release(treeUri)
            return AddResult.NotUsable
        }
        val name = (store.rootName() ?: "Folder").take(FolderLimits.MAX_LABEL_CHARS)
        val title = storageTitle(treeUri)
        val clash = mutablePlaces.value.any { caseKey(it.label) == caseKey(name) } || caseKey(name) == caseKey(DEFAULT_LABEL)
        val label = (if (clash && title != null) "$name ($title)" else name).take(FolderLimits.MAX_LABEL_CHARS)
        val place = Place(newPlaceId(), treeUri.toString(), label, title, now, otherProvider = treeUri.authority != EXTERNAL_STORAGE_AUTHORITY)
        save(mutablePlaces.value + place)
        return AddResult.Added(place)
    }

    @Synchronized
    fun remove(placeId: String) {
        val place = mutablePlaces.value.firstOrNull { it.placeId == placeId } ?: return
        save(mutablePlaces.value - place)
        release(Uri.parse(place.treeUri))
    }

    @Synchronized
    fun rename(placeId: String, label: String) {
        val clean = label.trim().take(FolderLimits.MAX_LABEL_CHARS).ifBlank { return }
        save(mutablePlaces.value.map { if (it.placeId == placeId) it.copy(label = clean) else it })
    }

    /** "Allow full access" for Download/Bridgey: the picked tree becomes the default place's storage. */
    @Synchronized
    fun setDefaultTree(treeUri: Uri?): Boolean {
        val previous = mutableDefaultTree.value
        if (treeUri != null && !takeGrant(treeUri)) return false
        preferences.edit().putString(KEY_DEFAULT_TREE, treeUri?.toString()).apply()
        mutableDefaultTree.value = treeUri?.toString()
        if (previous != null && previous != treeUri?.toString()) release(Uri.parse(previous))
        return true
    }

    /** A one-off "Other folder…" grant, used for one transfer. */
    fun takeOneOff(treeUri: Uri): Boolean = takeGrant(treeUri)

    /** Releases a one-off grant unless a place (or the default folder) uses the same tree. */
    fun releaseOneOff(treeUri: String) {
        if (mutablePlaces.value.any { it.treeUri == treeUri } || mutableDefaultTree.value == treeUri) return
        release(Uri.parse(treeUri))
    }

    /** "Internal storage", "SanDisk SD card", "USB drive": the volume of an ExternalStorageProvider tree. */
    private fun storageTitle(treeUri: Uri): String? = runCatching {
        if (treeUri.authority != EXTERNAL_STORAGE_AUTHORITY) return null
        val volume = DocumentsContract.getTreeDocumentId(treeUri).substringBefore(':')
        val storage = appContext.getSystemService(android.os.storage.StorageManager::class.java)
        val match = storage.storageVolumes.firstOrNull { if (volume == "primary") it.isPrimary else it.uuid.equals(volume, ignoreCase = true) }
        match?.getDescription(appContext)
    }.getOrNull()

    fun hasGrant(treeUri: String): Boolean = resolver.persistedUriPermissions.any {
        it.uri.toString() == treeUri && it.isReadPermission && it.isWritePermission
    }

    /** Checked against the persisted grants first, then one query of the folder itself. */
    fun isAvailable(treeUri: String): Boolean =
        hasGrant(treeUri) && runCatching { SafTreeStore(resolver, Uri.parse(treeUri)).reachable() }.getOrDefault(false)

    fun statuses(): List<PlaceStatus> = mutablePlaces.value.map { PlaceStatus(it, isAvailable(it.treeUri)) }

    private fun takeGrant(treeUri: Uri): Boolean = runCatching {
        resolver.takePersistableUriPermission(treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        true
    }.getOrDefault(false)

    private fun release(treeUri: Uri) {
        runCatching {
            resolver.releasePersistableUriPermission(treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
    }

    private fun save(list: List<Place>) {
        val json = JSONArray()
        list.forEach { place ->
            json.put(
                JSONObject().put("placeId", place.placeId).put("treeUri", place.treeUri).put("label", place.label)
                    .put("storageTitle", place.storageTitle ?: JSONObject.NULL).put("addedAt", place.addedAtMillis)
                    .put("otherProvider", place.otherProvider),
            )
        }
        preferences.edit().putString(KEY_PLACES, json.toString()).apply()
        mutablePlaces.value = list
    }

    private fun load(): List<Place> = runCatching {
        val json = JSONArray(preferences.getString(KEY_PLACES, "[]"))
        (0 until json.length()).mapNotNull { index ->
            val item = json.optJSONObject(index) ?: return@mapNotNull null
            Place(
                placeId = item.optString("placeId").takeIf(::isPlaceId) ?: return@mapNotNull null,
                treeUri = item.optString("treeUri").ifBlank { return@mapNotNull null },
                label = item.optString("label").take(FolderLimits.MAX_LABEL_CHARS),
                storageTitle = if (item.isNull("storageTitle")) null else item.optString("storageTitle"),
                addedAtMillis = item.optLong("addedAt"),
                otherProvider = item.optBoolean("otherProvider", false),
            )
        }
    }.getOrDefault(emptyList())

    companion object {
        const val DEFAULT_LABEL = "Download/Bridgey"
        const val EXTERNAL_STORAGE_AUTHORITY = "com.android.externalstorage.documents"
        private const val KEY_PLACES = "places"
        private const val KEY_DEFAULT_TREE = "default.tree"
        private val random = SecureRandom()

        /** 16 random bytes, base64url without padding: 22 characters. */
        fun newPlaceId(): String {
            val bytes = ByteArray(16).also(random::nextBytes)
            return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        }

        /** Where the folder picker opens for "Allow full access". */
        val DOWNLOAD_BRIDGEY_URI: Uri get() = DocumentsContract.buildDocumentUri(EXTERNAL_STORAGE_AUTHORITY, "primary:Download/Bridgey")

        /** Makes sure Download/Bridgey exists before the picker opens there (through MediaStore). */
        fun ensureDownloadBridgey(resolver: ContentResolver) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
            runCatching {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, ".bridgey-keep")
                    put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                    put(MediaStore.Downloads.RELATIVE_PATH, MediaStoreTreeStore.ROOT)
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)?.let { resolver.delete(it, null, null) }
            }
        }

        /** Whether a picked tree is Download/Bridgey itself. */
        fun isDownloadBridgey(treeUri: Uri): Boolean = treeUri.authority == EXTERNAL_STORAGE_AUTHORITY &&
            runCatching { DocumentsContract.getTreeDocumentId(treeUri) }.getOrNull()?.equals("primary:Download/Bridgey", ignoreCase = true) == true
    }
}

/** The phone's places for the folder session and the places server: `default` first, then granted places by label. */
class AndroidPlaceDirectory(private val resolver: ContentResolver, private val store: PlacesStore) : PlaceDirectory {
    override fun places(): List<PlaceRef> = listOf(defaultPlace()) + store.places.value
        .sortedWith(compareBy<Place> { caseKey(it.label) }.thenBy { it.placeId })
        .map { place ->
            val tree = Uri.parse(place.treeUri)
            PlaceRef(place.placeId, place.label, store.isAvailable(place.treeUri), { SafTreeStore(resolver, tree) }, place.storageTitle)
        }

    override fun place(placeId: String): PlaceRef? = if (placeId == DEFAULT_PLACE_ID) defaultPlace() else places().firstOrNull { it.placeId == placeId }

    private fun defaultPlace(): PlaceRef {
        val tree = store.defaultTree.value?.takeIf(store::isAvailable)
        return if (tree != null) {
            PlaceRef(DEFAULT_PLACE_ID, PlacesStore.DEFAULT_LABEL, true, { SafTreeStore(resolver, Uri.parse(tree)) })
        } else {
            PlaceRef(DEFAULT_PLACE_ID, PlacesStore.DEFAULT_LABEL, Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q, { MediaStoreTreeStore(resolver) })
        }
    }

    override fun oneOff(treeUri: String): PlaceRef? {
        if (!store.hasGrant(treeUri)) return null
        val saf = SafTreeStore(resolver, Uri.parse(treeUri))
        return PlaceRef("-", saf.rootName() ?: "Folder", saf.reachable(), { saf }, oneOffTree = treeUri)
    }
}
