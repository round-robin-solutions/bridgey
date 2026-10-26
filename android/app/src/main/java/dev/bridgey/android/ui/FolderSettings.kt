package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.folders.ConflictPolicy
import dev.bridgey.android.folders.DestinationMode
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** Settings › Files rows for folders (3.6), after the File transfer switch. Phone only; not synced yet. */
data class FolderSettingsState(
    val mode: DestinationMode = DestinationMode.SENDER_PICKS,
    val policy: ConflictPolicy = ConflictPolicy.ASK,
    val defaultPlaceId: String = dev.bridgey.android.folders.DEFAULT_PLACE_ID,
    /** Places the default folder can be: Download/Bridgey first. */
    val places: List<SheetPlace> = listOf(SheetPlace(dev.bridgey.android.folders.DEFAULT_PLACE_ID, "Download/Bridgey", true, isDefault = true)),
    val allowReplace: Boolean = false,
    /** Android 10 or newer (receiving folders, like files, needs scoped storage). */
    val supported: Boolean = true,
    /** The default folder's label, or "Not available" when its place was removed. */
    val defaultLabelOverride: String? = null,
) {
    val defaultLabel: String get() = defaultLabelOverride ?: places.firstOrNull { it.placeId == defaultPlaceId }?.label ?: "Download/Bridgey"
    val addedPlaces: Int get() = places.count { !it.isDefault }
}

class FolderSettingsActions(
    val setMode: (DestinationMode) -> Unit = {},
    val setPolicy: (ConflictPolicy) -> Unit = {},
    val setDefaultPlace: (String) -> Unit = {},
    val setAllowReplace: (Boolean) -> Unit = {},
    val openPlaces: () -> Unit = {},
)

@Composable
fun folderModeLabel(mode: DestinationMode, defaultLabel: String): String = when (mode) {
    DestinationMode.SENDER_PICKS -> stringResource(R.string.folder_mode_sender)
    DestinationMode.RECEIVER_ASKS -> stringResource(R.string.folder_mode_receiver)
    DestinationMode.FIXED -> stringResource(R.string.folder_mode_fixed, defaultLabel)
}

@Composable
fun conflictPolicyLabel(policy: ConflictPolicy): String = stringResource(
    when (policy) {
        ConflictPolicy.ASK -> R.string.conflict_policy_ask
        ConflictPolicy.MERGE -> R.string.conflict_policy_merge
        ConflictPolicy.REPLACE -> R.string.conflict_policy_replace
        ConflictPolicy.NEW_FOLDER -> R.string.conflict_policy_new_folder
    },
)

/** The folder rows inside the Files group. */
internal fun GroupScope.folderRows(state: FolderSettingsState, actions: FolderSettingsActions) {
    row { shape -> FolderModeRow(shape, state, actions) }
    row { shape ->
        ChoiceRow(
            shape, stringResource(R.string.settings_default_folder), state.defaultLabel, BridgeyIcons.Folder,
            state.places.filter { it.available }.map { it.placeId to it.label }, state.defaultPlaceId, actions.setDefaultPlace,
        )
    }
    row { shape ->
        ChoiceRow(
            shape, stringResource(R.string.settings_folder_conflict), conflictPolicyLabel(state.policy), BridgeyIcons.SwapHoriz,
            ConflictPolicy.entries.map { it to conflictPolicyLabel(it) }, state.policy, actions.setPolicy,
        )
    }
    row { shape ->
        SwitchRow(
            shape, stringResource(R.string.settings_allow_replace), stringResource(R.string.settings_allow_replace_detail),
            BridgeyIcons.Sync, if (state.allowReplace) Tint.BLUE else Tint.NEUTRAL, state.allowReplace, actions.setAllowReplace,
        )
    }
    row { shape ->
        val detail = if (state.addedPlaces == 0) stringResource(R.string.settings_places_detail_none)
        else pluralStringResource(R.plurals.settings_places_detail, state.addedPlaces, state.addedPlaces)
        ListRow(shape, stringResource(R.string.settings_places), detail, BridgeyIcons.Download, Tint.GREEN, onClick = actions.openPlaces) {
            Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant)
        }
    }
}

/** "Folders sent to this phone": three radio choices in one row. */
@Composable
private fun FolderModeRow(shape: Shape, state: FolderSettingsState, actions: FolderSettingsActions) {
    Column(Modifier.fillMaxWidth().clip(shape).background(BridgeyTheme.colors.surface1).padding(bottom = 6.dp).selectableGroup()) {
        ListRow(androidx.compose.ui.graphics.RectangleShape, stringResource(R.string.settings_folders_mode), null, BridgeyIcons.Folder, Tint.GREEN)
        DestinationMode.entries.forEach { mode ->
            val selected = mode == state.mode
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .selectable(selected = selected, role = Role.RadioButton) { actions.setMode(mode) }
                    .padding(start = 60.dp, end = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(
                    selected = selected,
                    onClick = null,
                    colors = RadioButtonDefaults.colors(selectedColor = BridgeyTheme.colors.primary, unselectedColor = BridgeyTheme.colors.outline),
                )
                Text(
                    folderModeLabel(mode, state.defaultLabel),
                    style = BridgeyType.bodyText,
                    color = BridgeyTheme.colors.onSurface,
                    modifier = Modifier.padding(start = 12.dp),
                )
            }
        }
    }
}

/** A row with the current choice as its detail and the choices in a menu. */
@Composable
private fun <T> ChoiceRow(
    shape: Shape,
    title: String,
    current: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    choices: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
) {
    val colors = BridgeyTheme.colors
    var open by remember { mutableStateOf(false) }
    Box {
        ListRow(shape, title, current, icon, Tint.BLUE, onClick = { open = true }, role = Role.DropdownList) {
            Icon(BridgeyIcons.ArrowDropDown, null, tint = colors.onSurfaceVariant, modifier = Modifier.size(24.dp))
        }
        DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
            containerColor = colors.surface2,
            shape = RoundedCornerShape(20.dp),
            modifier = Modifier.widthIn(max = 320.dp),
        ) {
            choices.forEach { (value, label) ->
                DropdownMenuItem(
                    text = { Text(label, style = BridgeyType.label, color = colors.onSurface) },
                    trailingIcon = if (value == selected) ({ Icon(BridgeyIcons.Check, null, tint = colors.primary) }) else null,
                    onClick = {
                        open = false
                        onSelect(value)
                    },
                    modifier = Modifier.heightIn(min = 48.dp),
                )
            }
        }
    }
}

/** A place in Settings › Files › Places. */
data class PlaceRow(
    val placeId: String,
    val label: String,
    val storageTitle: String?,
    val available: Boolean,
    val mayBeSlow: Boolean = false,
)

data class PlacesScreenState(
    val places: List<PlaceRow>,
    /** Download/Bridgey has full access (a tree grant). */
    val defaultFullAccess: Boolean,
    val canAdd: Boolean = places.size < dev.bridgey.android.folders.FolderLimits.MAX_PLACES,
)

class PlacesScreenActions(
    val back: () -> Unit = {},
    val add: () -> Unit = {},
    val allowFullAccess: () -> Unit = {},
    val grantAgain: (String) -> Unit = {},
    val remove: (String) -> Unit = {},
    val rename: (String, String) -> Unit = { _, _ -> },
)

/**
 * Places (6.1, 6.2): Download/Bridgey with Allow full access, then each granted folder with its storage,
 * "Access lost · Grant again", Rename and Remove; Add folder… at the end.
 */
@Composable
fun PlacesScreen(state: PlacesScreenState, actions: PlacesScreenActions) {
    var renaming by rememberSaveable { mutableStateOf<String?>(null) }
    var menuFor by remember { mutableStateOf<String?>(null) }
    SettingsPage(stringResource(R.string.settings_places), actions.back) {
        item(key = "intro") { Note(stringResource(R.string.places_intro), Modifier.padding(start = 32.dp, end = 32.dp, top = 20.dp)) }
        item(key = "default") {
            RowGroup(Modifier.padding(top = 16.dp)) {
                row { shape ->
                    ListRow(
                        shape, "Download/Bridgey",
                        stringResource(if (state.defaultFullAccess) R.string.places_default_full else R.string.places_default_limited),
                        BridgeyIcons.Download, Tint.BLUE,
                    ) {
                        if (!state.defaultFullAccess) TonalPillButton(stringResource(R.string.places_allow_full_access), actions.allowFullAccess)
                    }
                }
            }
        }
        if (!state.defaultFullAccess) {
            item(key = "default.note") { Note(stringResource(R.string.places_default_fallback), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) }
        }
        item(key = "places") {
            RowGroup(Modifier.padding(top = 24.dp)) {
                state.places.forEach { place ->
                    row { shape ->
                        val detail = when {
                            !place.available -> stringResource(R.string.places_access_lost)
                            place.mayBeSlow -> listOfNotNull(place.storageTitle, stringResource(R.string.places_may_be_slow)).joinToString(" · ")
                            else -> place.storageTitle
                        }
                        Box {
                            ListRow(
                                shape, place.label, detail, BridgeyIcons.Folder, if (place.available) Tint.GREEN else Tint.NEUTRAL,
                                detailWarning = !place.available, onClick = { menuFor = place.placeId },
                            ) {
                                if (!place.available) {
                                    TonalPillButton(stringResource(R.string.places_grant_again), { actions.grantAgain(place.placeId) })
                                } else {
                                    Icon(BridgeyIcons.MoreVert, stringResource(R.string.places_rename), tint = BridgeyTheme.colors.onSurfaceVariant)
                                }
                            }
                            DropdownMenu(
                                expanded = menuFor == place.placeId,
                                onDismissRequest = { menuFor = null },
                                containerColor = BridgeyTheme.colors.surface2,
                                shape = RoundedCornerShape(20.dp),
                            ) {
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.places_rename), style = BridgeyType.label) },
                                    onClick = {
                                        menuFor = null
                                        renaming = place.placeId
                                    },
                                    modifier = Modifier.heightIn(min = 48.dp),
                                )
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.places_remove), style = BridgeyType.label, color = BridgeyTheme.colors.warn) },
                                    onClick = {
                                        menuFor = null
                                        actions.remove(place.placeId)
                                    },
                                    modifier = Modifier.heightIn(min = 48.dp),
                                )
                            }
                        }
                    }
                }
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.places_add),
                        stringResource(if (state.canAdd) R.string.places_add_detail else R.string.places_full),
                        BridgeyIcons.Add, if (state.canAdd) Tint.BLUE else Tint.NEUTRAL,
                        onClick = if (state.canAdd) actions.add else null,
                    )
                }
            }
        }
    }
    renaming?.let { placeId ->
        val place = state.places.firstOrNull { it.placeId == placeId } ?: return@let
        var value by rememberSaveable(placeId) { mutableStateOf(place.label) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text(stringResource(R.string.places_rename)) },
            text = {
                OutlinedTextField(
                    value = value,
                    onValueChange = { value = it.take(dev.bridgey.android.folders.FolderLimits.MAX_LABEL_CHARS) },
                    label = { Text(stringResource(R.string.places_name)) },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    renaming = null
                    actions.rename(placeId, value)
                }) { Text(stringResource(R.string.action_save)) }
            },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}
