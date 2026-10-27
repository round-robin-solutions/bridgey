package dev.bridgey.android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import dev.bridgey.android.browse.DocumentItem
import dev.bridgey.android.browse.FolderSource
import dev.bridgey.android.browse.MediaAccess
import dev.bridgey.android.browse.MediaAccessRules
import dev.bridgey.android.browse.MediaItem
import dev.bridgey.android.browse.MediaStoreLibrary
import dev.bridgey.android.browse.TreeDocumentIndex
import dev.bridgey.android.folders.DEFAULT_PLACE_ID
import dev.bridgey.android.folders.PlacesStore
import dev.bridgey.android.ui.attach.AndroidMediaThumbnails
import dev.bridgey.android.ui.attach.AttachActions
import dev.bridgey.android.ui.attach.AttachFolder
import dev.bridgey.android.ui.attach.AttachKeys
import dev.bridgey.android.ui.attach.AttachSelection
import dev.bridgey.android.ui.attach.AttachSheetContent
import dev.bridgey.android.ui.attach.AttachState
import dev.bridgey.android.ui.attach.AttachTab
import dev.bridgey.android.ui.attach.AttachTarget
import dev.bridgey.android.ui.attach.LocalMediaThumbnails
import dev.bridgey.android.ui.attach.MediaPrompt
import dev.bridgey.android.ui.attach.MediaThumbnails
import dev.bridgey.android.ui.theme.BridgeyTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The last tab, target and whether the documents card was put away. On this phone only. */
class AttachPreferences(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("bridgey.attach", Context.MODE_PRIVATE)

    var tab: AttachTab
        get() = AttachTab.entries.firstOrNull { it.name == preferences.getString(KEY_TAB, null) } ?: AttachTab.MEDIA
        set(value) = preferences.edit().putString(KEY_TAB, value.name).apply()

    var lastTarget: String?
        get() = preferences.getString(KEY_TARGET, null)
        set(value) = preferences.edit().putString(KEY_TARGET, value).apply()

    var documentsCardDismissed: Boolean
        get() = preferences.getBoolean(KEY_DOCUMENTS_CARD, false)
        set(value) = preferences.edit().putBoolean(KEY_DOCUMENTS_CARD, value).apply()

    var mediaAsked: Boolean
        get() = preferences.getBoolean(KEY_MEDIA_ASKED, false)
        set(value) = preferences.edit().putBoolean(KEY_MEDIA_ASKED, value).apply()

    private companion object {
        const val KEY_TAB = "tab"
        const val KEY_TARGET = "target"
        const val KEY_DOCUMENTS_CARD = "documents_card_dismissed"
        const val KEY_MEDIA_ASKED = "media_asked"
    }
}

/** Opens the attach sheet aimed at a device (null: the selected one). */
class AttachUi internal constructor(
    val open: (deviceId: String?) -> Unit,
    internal val visible: Boolean,
    internal val state: AttachState,
    internal val actions: AttachActions,
    internal val thumbnails: MediaThumbnails,
)

private const val MEDIA_PAGE = 120

/** Where "Let Bridgey see your documents" opens the folder picker: Documents on internal storage. */
private val DOCUMENTS_URI: Uri get() = DocumentsContract.buildDocumentUri(PlacesStore.EXTERNAL_STORAGE_AUTHORITY, "primary:Documents")

@Composable
fun rememberAttachUi(pairing: PairingCoordinator, snackbar: SnackbarHostState): AttachUi {
    val context = LocalContext.current
    val activity = context as? Activity
    val scope = rememberCoroutineScope()
    val preferences = remember { AttachPreferences(context) }
    val thumbnails = remember { AndroidMediaThumbnails(context.contentResolver) }
    val connections by pairing.connections.collectAsStateWithLifecycle()
    val places by pairing.placesStore.places.collectAsStateWithLifecycle()
    var visible by remember { mutableStateOf(false) }
    var tab by remember { mutableStateOf(preferences.tab) }
    var targetId by remember { mutableStateOf<String?>(null) }
    var selection by remember { mutableStateOf(emptyList<String>()) }
    var access by remember { mutableStateOf(MediaAccess.NONE) }
    var prompt by remember { mutableStateOf(MediaPrompt.ASK) }
    var media by remember { mutableStateOf(emptyList<MediaItem>()) }
    var mediaMore by remember { mutableStateOf(false) }
    var loadingMedia by remember { mutableStateOf(false) }
    var documents by remember { mutableStateOf(emptyList<DocumentItem>()) }
    var indexing by remember { mutableStateOf(false) }
    var folders by remember { mutableStateOf(emptyList<AttachFolder>()) }
    var cardDismissed by remember { mutableStateOf(preferences.documentsCardDismissed) }
    var reload by remember { mutableIntStateOf(0) }

    fun refreshAccess() {
        access = pairing.mediaLibrary.access()
    }

    fun say(text: String) {
        scope.launch {
            snackbar.currentSnackbarData?.dismiss()
            snackbar.showSnackbar(text)
        }
    }

    val targets = connections.filter { pairing.isFeatureAvailable(BridgeyFeature.FILES, it.deviceId) }.map { AttachTarget(it.deviceId, it.peerName) }

    val mediaPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        preferences.mediaAsked = true
        refreshAccess()
        if (access == MediaAccess.NONE && activity != null) {
            val main = MediaAccessRules.request(Build.VERSION.SDK_INT).first()
            if (!activity.shouldShowRequestPermissionRationale(main)) prompt = MediaPrompt.OPEN_SETTINGS
        }
        reload++
    }
    val documentsTree = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch(Dispatchers.IO) {
            when (val result = pairing.placesStore.add(uri)) {
                is PlacesStore.AddResult.Added -> say(context.getString(R.string.places_added, result.place.label))
                is PlacesStore.AddResult.Existing -> Unit
                PlacesStore.AddResult.Full -> say(context.getString(R.string.places_full))
                PlacesStore.AddResult.NotUsable -> say(context.getString(R.string.attach_documents_not_usable))
            }
            pairing.documentIndex.placesChanged()
            withContext(Dispatchers.Main) { reload++ }
        }
    }
    val browseFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) {
            pairing.sendFiles(uris, targetId)
            visible = false
        }
    }
    val browseFolder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        // Persisted, so a folder that resumes after a restart can still be read; the sender releases it after.
        pairing.placesStore.takeOneOff(uri)
        pairing.sendFolder(FolderSource.Tree(uri.toString()), targetId)
        visible = false
    }

    // Access can change in system Settings while the app is away.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            val before = access
            refreshAccess()
            if (access != before) reload++
        }
    }

    // Photos and videos: the first page as soon as the sheet opens, again when MediaStore changes.
    val generation = (pairing.mediaLibrary as? MediaStoreLibrary)?.generations?.collectAsStateWithLifecycle()?.value ?: 0L
    LaunchedEffect(visible, access, generation, reload) {
        if (!visible || access == MediaAccess.NONE) {
            if (access == MediaAccess.NONE) media = emptyList()
            return@LaunchedEffect
        }
        val first = withContext(Dispatchers.IO) { pairing.mediaLibrary.page(0, MEDIA_PAGE) }
        media = first
        mediaMore = first.size >= MEDIA_PAGE
        thumbnails.prefetch(first.take(24))
    }

    // Documents from the cached index at once; the refresh replaces them when it finishes.
    val indexUpdates = (pairing.documentIndex as? TreeDocumentIndex)?.updates?.collectAsStateWithLifecycle()?.value ?: 0L
    LaunchedEffect(visible, indexUpdates, reload, places) {
        if (!visible) return@LaunchedEffect
        pairing.documentIndex.refreshIfStale()
        val list = withContext(Dispatchers.IO) { pairing.documentIndex.recent(0, 500) }
        documents = list
        indexing = pairing.documentIndex.indexing
        val refs = withContext(Dispatchers.IO) { pairing.placeDirectory.places() }
        folders = refs.map { ref ->
            AttachFolder(
                ref.placeId, ref.label,
                if (ref.placeId == DEFAULT_PLACE_ID) context.getString(R.string.place_default_detail) else ref.storageTitle,
                ref.available, isDefault = ref.placeId == DEFAULT_PLACE_ID,
            )
        }
    }

    val target = targets.firstOrNull { it.deviceId == targetId } ?: targets.firstOrNull()
    val state = AttachState(
        tab = tab,
        mediaAccess = access,
        mediaPrompt = prompt,
        media = media,
        mediaMore = mediaMore,
        documents = documents,
        documentsIndexing = indexing,
        showDocumentsCard = places.isEmpty() && !cardDismissed,
        hasDocumentPlace = places.isNotEmpty(),
        folders = folders,
        canSendFolders = target != null && pairing.canSendFolders(target.deviceId),
        selection = selection,
        targets = targets,
        targetId = target?.deviceId,
    )

    fun openSettings() {
        context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
    }

    val actions = AttachActions(
        selectTab = {
            tab = it
            preferences.tab = it
        },
        toggle = { key -> selection = AttachSelection.toggle(selection, key) },
        requestMedia = { mediaPermission.launch(MediaAccessRules.request(Build.VERSION.SDK_INT)) },
        // Android 14 shows its photo picker again for the selected-photos permission.
        selectMorePhotos = { mediaPermission.launch(MediaAccessRules.request(Build.VERSION.SDK_INT)) },
        allowAllPhotos = ::openSettings,
        loadMoreMedia = {
            if (!loadingMedia && mediaMore) {
                loadingMedia = true
                scope.launch {
                    val offset = media.size
                    val next = withContext(Dispatchers.IO) { pairing.mediaLibrary.page(offset, MEDIA_PAGE) }
                    if (media.size == offset) media = media + next
                    mediaMore = next.size >= MEDIA_PAGE
                    loadingMedia = false
                }
            }
        },
        grantDocuments = { documentsTree.launch(DOCUMENTS_URI) },
        dismissDocumentsCard = {
            cardDismissed = true
            preferences.documentsCardDismissed = true
        },
        addFolder = { documentsTree.launch(null) },
        browseFiles = { browseFiles.launch(arrayOf("*/*")) },
        browseFolder = { browseFolder.launch(null) },
        pickTarget = {
            targetId = it
            preferences.lastTarget = it
        },
        send = send@{
            val deviceId = target?.deviceId ?: return@send
            val byKey = HashMap<String, Uri>()
            media.forEach { byKey[AttachKeys.media(it)] = Uri.parse(it.uri) }
            val files = selection.mapNotNull { key ->
                when {
                    key.startsWith(AttachKeys.MEDIA) -> byKey[key]
                    key.startsWith(AttachKeys.DOCUMENT) -> Uri.parse(key.removePrefix(AttachKeys.DOCUMENT))
                    else -> null
                }
            }
            if (files.isNotEmpty()) pairing.sendFiles(files, deviceId)
            selection.filter { it.startsWith(AttachKeys.FOLDER) }.forEach { key ->
                pairing.sendFolder(FolderSource.Place(key.removePrefix(AttachKeys.FOLDER)), deviceId)
            }
            preferences.lastTarget = deviceId
            selection = emptyList()
            visible = false
        },
        close = { visible = false },
    )

    return AttachUi(
        open = { deviceId ->
            targetId = deviceId ?: preferences.lastTarget?.takeIf { id -> connections.any { it.deviceId == id } }
            refreshAccess()
            selection = emptyList()
            visible = true
        },
        visible = visible,
        state = state,
        actions = actions,
        thumbnails = thumbnails,
    )
}

/** The attach sheet while Bridgey is open. Swiping it away keeps nothing selected for next time. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AttachSheetHost(ui: AttachUi) {
    if (!ui.visible) return
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = ui.actions.close, sheetState = sheet, containerColor = BridgeyTheme.colors.surface2) {
        CompositionLocalProvider(LocalMediaThumbnails provides ui.thumbnails) {
            AttachSheetContent(ui.state, ui.actions)
        }
    }
}
