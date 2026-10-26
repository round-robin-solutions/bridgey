package dev.bridgey.android

import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.bridgey.android.folders.DEFAULT_PLACE_ID
import dev.bridgey.android.folders.DestinationAnswer
import dev.bridgey.android.folders.FolderQuestion
import dev.bridgey.android.folders.PlacesStore
import dev.bridgey.android.folders.destinationLabel
import dev.bridgey.android.ui.FolderQuestionSheet
import dev.bridgey.android.ui.FolderSettingsActions
import dev.bridgey.android.ui.FolderSettingsState
import dev.bridgey.android.ui.FolderSheetActions
import dev.bridgey.android.ui.PlaceRow
import dev.bridgey.android.ui.PlacesScreenActions
import dev.bridgey.android.ui.PlacesScreenState
import dev.bridgey.android.ui.SheetPlace
import dev.bridgey.android.ui.SheetRecent
import dev.bridgey.android.ui.theme.BridgeyTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What the folder tree picker is open for. */
private sealed interface TreePurpose {
    data object AddPlace : TreePurpose
    data object DefaultFullAccess : TreePurpose
    data class Regrant(val placeId: String) : TreePurpose
    data class OneOff(val folderTransferId: String, val addToPlaces: Boolean) : TreePurpose
}

/** The app's folder pieces: places for the sheet and Settings, the tree picker, and which question shows. */
class FolderUi internal constructor(
    val settingsState: FolderSettingsState,
    val settingsActions: FolderSettingsActions,
    val placesState: PlacesScreenState,
    val placesActions: PlacesScreenActions,
    /** Opens the sheet of a waiting folder (the card's Choose or Answer). */
    val showQuestion: (String) -> Unit,
    internal val question: FolderQuestion?,
    internal val sheetPlaces: List<SheetPlace>,
    internal val recent: List<SheetRecent>,
    internal val sheetActions: FolderSheetActions,
    internal val hide: (String) -> Unit,
)

@Composable
fun rememberFolderUi(
    pairing: PairingCoordinator,
    settings: BridgeySettings,
    snackbar: SnackbarHostState,
    openPlaces: () -> Unit,
    focusQuestion: String?,
    onFocusHandled: () -> Unit,
): FolderUi {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val questions by pairing.folderQuestions.collectAsStateWithLifecycle()
    val places by pairing.placesStore.places.collectAsStateWithLifecycle()
    val defaultTree by pairing.placesStore.defaultTree.collectAsStateWithLifecycle()
    val settingsState by settings.state.collectAsStateWithLifecycle()
    var refresh by remember { mutableStateOf(0) }
    // Availability needs a query per place: off the main thread, again when places or questions change.
    val resolved by produceState(Triple(emptyList<SheetPlace>(), emptyList<PlaceRow>(), false), places, defaultTree, questions.size, refresh) {
        value = withContext(Dispatchers.IO) {
            val refs = pairing.placeDirectory.places()
            val sheet = refs.map { SheetPlace(it.placeId, it.label, it.available, isDefault = it.placeId == DEFAULT_PLACE_ID, storageTitle = it.storageTitle) }
            val rows = pairing.placesStore.statuses().sortedBy { dev.bridgey.android.folders.caseKey(it.place.label) }.map {
                PlaceRow(it.place.placeId, it.place.label, it.place.storageTitle, it.available, it.place.otherProvider)
            }
            val full = defaultTree?.let(pairing.placesStore::isAvailable) == true
            Triple(sheet, rows, full)
        }
    }
    val (sheetPlaces, placeRows, defaultFullAccess) = resolved
    var hidden by remember { mutableStateOf(emptySet<String>()) }
    var focused by remember { mutableStateOf<String?>(null) }
    var purpose by remember { mutableStateOf<TreePurpose?>(null) }
    LaunchedEffect(focusQuestion) {
        if (focusQuestion != null) {
            hidden = hidden - focusQuestion
            focused = focusQuestion
            onFocusHandled()
        }
    }

    fun say(text: String) {
        scope.launch {
            snackbar.currentSnackbarData?.dismiss()
            snackbar.showSnackbar(text)
        }
    }

    fun addPlace(uri: Uri): String? = when (val result = pairing.placesStore.add(uri)) {
        is PlacesStore.AddResult.Added -> {
            say(context.getString(R.string.places_added, result.place.label))
            result.place.placeId
        }
        is PlacesStore.AddResult.Existing -> result.place.placeId
        PlacesStore.AddResult.Full -> null.also { say(context.getString(R.string.places_full)) }
        PlacesStore.AddResult.NotUsable -> null.also { say(context.getString(R.string.places_not_usable)) }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        val reason = purpose
        purpose = null
        if (uri == null || reason == null) return@rememberLauncherForActivityResult
        scope.launch(Dispatchers.IO) {
            when (reason) {
                TreePurpose.AddPlace -> addPlace(uri)
                TreePurpose.DefaultFullAccess ->
                    if (PlacesStore.isDownloadBridgey(uri)) pairing.placesStore.setDefaultTree(uri) else addPlace(uri)
                is TreePurpose.Regrant -> {
                    pairing.placesStore.regrant(reason.placeId, uri)
                    refresh++
                }
                is TreePurpose.OneOff -> {
                    val answer = if (reason.addToPlaces) {
                        addPlace(uri)?.let { DestinationAnswer(placeId = it) }
                    } else if (pairing.placesStore.takeOneOff(uri)) {
                        DestinationAnswer(oneOffTree = uri.toString())
                    } else {
                        say(context.getString(R.string.places_not_usable))
                        null
                    }
                    answer?.let { pairing.answerFolderDestination(reason.folderTransferId, it) }
                }
            }
        }
    }

    val question = questions.firstOrNull { it.folderTransferId == focused && it.folderTransferId !in hidden }
        ?: questions.firstOrNull { it.folderTransferId !in hidden }
    val recent = settingsState.recentFolderDestinations.mapNotNull { destination ->
        val place = sheetPlaces.firstOrNull { it.placeId == destination.placeId && it.available } ?: return@mapNotNull null
        SheetRecent(destination.placeId, destination.path, destinationLabel(place.label, destination.path))
    }
    val folderSettings = settingsState.let { state ->
        val defaultLabel = sheetPlaces.firstOrNull { it.placeId == state.folderDefaultPlace }?.label
            ?: if (state.folderDefaultPlace == DEFAULT_PLACE_ID) "Download/Bridgey" else context.getString(R.string.place_not_available)
        FolderSettingsState(
            mode = state.folderMode,
            policy = state.folderConflict,
            defaultPlaceId = state.folderDefaultPlace,
            places = sheetPlaces.ifEmpty { FolderSettingsState().places },
            allowReplace = state.allowReplaceFromOtherDevices,
            supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q,
            defaultLabelOverride = defaultLabel,
        )
    }
    return FolderUi(
        settingsState = folderSettings,
        settingsActions = FolderSettingsActions(
            setMode = settings::setFolderMode,
            setPolicy = settings::setFolderConflict,
            setDefaultPlace = settings::setFolderDefaultPlace,
            setAllowReplace = settings::setAllowReplaceFromOtherDevices,
            openPlaces = openPlaces,
        ),
        placesState = PlacesScreenState(placeRows, defaultFullAccess),
        placesActions = PlacesScreenActions(
            add = {
                purpose = TreePurpose.AddPlace
                picker.launch(null)
            },
            allowFullAccess = {
                purpose = TreePurpose.DefaultFullAccess
                scope.launch {
                    withContext(Dispatchers.IO) { PlacesStore.ensureDownloadBridgey(context.contentResolver) }
                    picker.launch(PlacesStore.DOWNLOAD_BRIDGEY_URI)
                }
            },
            grantAgain = { placeId ->
                purpose = TreePurpose.Regrant(placeId)
                picker.launch(places.firstOrNull { it.placeId == placeId }?.treeUri?.let(Uri::parse))
            },
            remove = { placeId ->
                val label = places.firstOrNull { it.placeId == placeId }?.label
                pairing.placesStore.remove(placeId)
                settings.forgetPlace(placeId)
                // Mode (c) whose default went asks on the phone from now on (D15); it never falls back silently.
                if (settingsState.folderDefaultPlace == placeId && label != null) say(context.getString(R.string.places_removed_default, label))
            },
            rename = { placeId, label -> pairing.placesStore.rename(placeId, label) },
        ),
        showQuestion = { id ->
            hidden = hidden - id
            focused = id
        },
        question = question,
        sheetPlaces = sheetPlaces,
        recent = recent,
        sheetActions = FolderSheetActions(
            choose = { placeId, path -> question?.let { pairing.answerFolderDestination(it.folderTransferId, DestinationAnswer(placeId = placeId, path = path)) } },
            otherFolder = { add ->
                question?.let {
                    purpose = TreePurpose.OneOff(it.folderTransferId, add)
                    picker.launch(null)
                }
            },
            answer = { choice -> question?.let { pairing.answerFolderConflict(it.folderTransferId, choice) } },
            cancel = { question?.let { pairing.cancelFileTransfer(it.folderTransferId) } },
        ),
        hide = { id -> hidden = hidden + id },
    )
}

/**
 * The folder question as a bottom sheet while Bridgey is open (no activity starts from the background).
 * Swiping it away only hides it; the card's Choose or Answer brings it back, and the countdown keeps running.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderQuestionHost(ui: FolderUi) {
    val question = ui.question ?: return
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = { ui.hide(question.folderTransferId) },
        sheetState = state,
        containerColor = BridgeyTheme.colors.surface2,
    ) {
        FolderQuestionSheet(question, ui.sheetPlaces, ui.recent, ui.sheetActions)
    }
}
