package dev.bridgey.android.ui

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.R
import dev.bridgey.android.sync.SyncChange
import dev.bridgey.android.sync.SyncFeatureKeys
import dev.bridgey.android.sync.SyncKey
import dev.bridgey.android.sync.SyncRowStatus
import dev.bridgey.android.sync.SyncUiState
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** Settings sync in Settings: the switches, Choose what syncs, and each row's Apply to all and Allow. */
class SyncSettingsActions(
    val setEnabled: (Boolean) -> Unit = {},
    val setSyncs: (SyncKey, Boolean) -> Unit = { _, _ -> },
    val applyToAll: (SyncKey) -> Unit = {},
    /** On here but waiting for a permission: the Permissions page. */
    val allow: (SyncKey) -> Unit = {},
)

/**
 * The settings Choose what syncs offers: the ones this phone has (27). Codes from messages is a Mac setting: the phone
 * only stores and relays it, as the Mac does for Photos for the Mac.
 */
val ChoosableSyncKeys: List<SyncKey> = SyncKey.entries - SyncKey.CODES

/** The sync key behind a feature's global switch. */
fun syncKeyFor(feature: BridgeyFeature): SyncKey? = SyncFeatureKeys.entries.firstOrNull { it.value == feature }?.key

/** A setting's name in sync texts ("Calls", "Reduce motion"). */
fun syncKeyName(context: Context, key: SyncKey): String = context.getString(
    when (key) {
        SyncKey.FOLDER_DESTINATION -> R.string.sync_name_folder_destination
        SyncKey.FOLDER_CONFLICT -> R.string.sync_name_folder_conflict
        SyncKey.ACTIVITY_PREVIEWS -> R.string.sync_name_previews
        SyncKey.REDUCE_MOTION -> R.string.sync_name_reduce_motion
        SyncKey.CLIPBOARD -> R.string.sync_name_clipboard
        SyncKey.FILES -> R.string.sync_name_files
        SyncKey.NOTIFICATIONS -> R.string.sync_name_notifications
        SyncKey.BATTERY -> R.string.sync_name_battery
        SyncKey.FIND_DEVICE -> R.string.sync_name_find_device
        SyncKey.PING -> R.string.sync_name_ping
        SyncKey.LINKS -> R.string.sync_name_links
        SyncKey.MEDIA -> R.string.sync_name_media
        SyncKey.CALLS -> R.string.sync_name_calls
        SyncKey.REMOTE_INPUT -> R.string.sync_name_remote_input
        SyncKey.MAC_ACTIONS -> R.string.sync_name_mac_actions
        SyncKey.CAMERA -> R.string.sync_name_camera
        SyncKey.AUTO_CLIPBOARD -> R.string.sync_name_auto_clipboard
        SyncKey.CLIPBOARD_FILES -> R.string.sync_name_clipboard_files
        SyncKey.FOCUS_SHARE -> R.string.sync_name_focus_share
        SyncKey.FOCUS_FOLLOW -> R.string.sync_name_focus_follow
        SyncKey.CODES -> R.string.sync_name_codes
        SyncKey.SCREEN -> R.string.sync_name_screen
        SyncKey.SMS -> R.string.sync_name_sms
        SyncKey.CONNECT_AWAY -> R.string.settings_connect_away
        SyncKey.AUTO_UPDATE_ALL -> R.string.sync_name_auto_update_all
        SyncKey.FOLDER_INCLUDE_HIDDEN -> R.string.sync_name_folder_include_hidden
        SyncKey.FOLDER_INCLUDE_SYSTEM -> R.string.sync_name_folder_include_system
        SyncKey.EMAIL_CODES -> R.string.sync_name_codes_email
    },
)

/** "Calls turned on", "Folders: ask where to save". */
fun syncChangeLabel(context: Context, change: SyncChange): String = when (change.key) {
    SyncKey.FOLDER_DESTINATION -> context.getString(
        when (change.value) {
            "receiver_asks" -> R.string.sync_folder_receiver_asks
            "fixed" -> R.string.sync_folder_fixed
            else -> R.string.sync_folder_sender_picks
        },
    )
    SyncKey.FOLDER_CONFLICT -> context.getString(
        when (change.value) {
            "merge" -> R.string.sync_conflict_merge
            "replace" -> R.string.sync_conflict_replace
            "new_folder" -> R.string.sync_conflict_new_folder
            else -> R.string.sync_conflict_ask
        },
    )
    else -> context.getString(if (change.value == true) R.string.sync_turned_on else R.string.sync_turned_off, syncKeyName(context, change.key))
}

/** The detail line of a settings_synced item, or null when nothing decodes. */
fun syncChangesText(context: Context, changes: List<SyncChange>): String? =
    changes.takeIf { it.isNotEmpty() }?.joinToString(", ") { syncChangeLabel(context, it) }

/** "Different on Work Mac", "Different on Work Mac +1". */
@Composable
private fun deviceList(names: List<String>): String =
    if (names.size == 1) names.first() else stringResource(R.string.settings_sync_devices_more, names.first(), names.size - 1)

/** The lines under a synced row: waiting here (Allow), different elsewhere (Apply to all), waiting elsewhere. */
fun GroupScope.syncRows(key: SyncKey?, sync: SyncUiState, actions: SyncSettingsActions) {
    val status = key?.let(sync::row) ?: return
    if (status.waitingHere) row { shape -> SyncLine(shape, stringResource(R.string.settings_sync_waiting_here), true, stringResource(R.string.settings_sync_allow)) { actions.allow(key) } }
    if (status.differentOn.isNotEmpty()) {
        row { shape ->
            SyncLine(shape, stringResource(R.string.settings_sync_different, deviceList(status.differentOn)), false, stringResource(R.string.settings_sync_apply_all)) {
                actions.applyToAll(key)
            }
        }
    }
    if (status.waitingOn.isNotEmpty()) {
        row { shape -> SyncLine(shape, stringResource(R.string.settings_sync_needs_permission_on, deviceList(status.waitingOn)), true, null) {} }
    }
}

/** True when [status] would add a line. */
fun SyncRowStatus.shows(): Boolean = waitingHere || differentOn.isNotEmpty() || waitingOn.isNotEmpty()

@Composable
private fun SyncLine(shape: Shape, text: String, warning: Boolean, action: String?, onAction: () -> Unit) {
    ListRow(
        shape = shape,
        title = text,
        detail = null,
        icon = if (warning) BridgeyIcons.Error else BridgeyIcons.Sync,
        tint = if (warning) Tint.PURPLE else Tint.NEUTRAL,
        compact = true,
    ) {
        if (action != null) OutlinePillButton(action, null, onAction)
    }
}

/** General: the sync switch and Choose what syncs. */
@Composable
fun SyncSettingsGroup(sync: SyncUiState, actions: SyncSettingsActions, modifier: Modifier = Modifier) {
    var choosing by rememberSaveable { mutableStateOf(false) }
    val enabled = sync.switches.enabled
    RowGroup(modifier) {
        row { shape ->
            SwitchRow(
                shape, stringResource(R.string.settings_sync_title), stringResource(R.string.settings_sync_detail),
                BridgeyIcons.Sync, if (enabled) Tint.BLUE else Tint.NEUTRAL, enabled, actions.setEnabled,
            )
        }
        if (enabled) {
            row { shape ->
                val total = ChoosableSyncKeys.size
                ListRow(
                    shape, stringResource(R.string.settings_sync_choose),
                    stringResource(R.string.settings_sync_choose_detail, ChoosableSyncKeys.count { it !in sync.switches.excluded }, total),
                    BridgeyIcons.Settings, Tint.NEUTRAL, onClick = { choosing = true },
                ) { Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant) }
            }
        }
    }
    if (choosing) ChooseWhatSyncsDialog(sync, actions) { choosing = false }
}

/** Every synced setting with a check: unchecked stays on this phone. */
@Composable
internal fun ChooseWhatSyncsDialog(sync: SyncUiState, actions: SyncSettingsActions, onDone: () -> Unit) {
    val context = LocalContext.current
    val colors = BridgeyTheme.colors
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text(stringResource(R.string.settings_sync_choose)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(stringResource(R.string.settings_sync_choose_note), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
                ChoosableSyncKeys.forEach { key ->
                    val checked = key !in sync.switches.excluded
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 48.dp)
                            .clickable(role = Role.Checkbox) { actions.setSyncs(key, !checked) },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Checkbox(
                            checked = checked, onCheckedChange = null,
                            colors = CheckboxDefaults.colors(checkedColor = colors.switchOn),
                        )
                        Text(syncKeyName(context, key), style = BridgeyType.itemTitle, color = colors.onSurface)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDone) { Text(stringResource(R.string.settings_sync_choose_done)) } },
    )
}

/** The small mark after a synced row's title. */
@Composable
internal fun SyncedMark() {
    Icon(
        BridgeyIcons.Sync, stringResource(R.string.settings_sync_mark),
        tint = BridgeyTheme.colors.onSurfaceVariant, modifier = Modifier.padding(start = 6.dp).size(14.dp),
    )
}

/**
 * First connect with a device (8.4): "Use the same settings as <device>?". Asked once per device, in the app only;
 * nothing moves between the two until it is answered. Not dismissed by tapping outside, so it is never lost.
 */
@Composable
fun FirstConnectQuestion(deviceName: String, onUse: () -> Unit, onKeep: () -> Unit) {
    AlertDialog(
        onDismissRequest = {},
        icon = { Icon(BridgeyIcons.Sync, null) },
        title = { Text(stringResource(R.string.sync_first_title, deviceName)) },
        text = { Text(stringResource(R.string.sync_first_body, deviceName)) },
        confirmButton = { TextButton(onClick = onUse) { Text(stringResource(R.string.sync_first_use)) } },
        dismissButton = { TextButton(onClick = onKeep) { Text(stringResource(R.string.sync_first_keep)) } },
        properties = androidx.compose.ui.window.DialogProperties(dismissOnClickOutside = false, dismissOnBackPress = false),
    )
}
