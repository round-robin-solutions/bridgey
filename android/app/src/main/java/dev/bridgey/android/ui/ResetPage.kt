package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.setup.LocalDataReset
import dev.bridgey.android.setup.ResetChoice
import dev.bridgey.android.setup.ResetItem
import dev.bridgey.android.setup.ResetKept
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/**
 * Settings > Privacy > Reset Bridgey on this device: four choices, each with its own confirm
 * dialog. [confirming] is the open dialog, [done] the last finished choice (its confirmation shows).
 */
@Composable
fun ResetScreen(
    confirming: ResetChoice?,
    done: ResetChoice?,
    onBack: () -> Unit,
    onChoose: (ResetChoice?) -> Unit,
    onConfirm: (ResetChoice) -> Unit,
) {
    SettingsPage(stringResource(R.string.reset_title), onBack) {
        item(key = "intro") { Note(stringResource(R.string.reset_intro), Modifier.padding(start = 32.dp, end = 32.dp, top = 20.dp, bottom = 12.dp)) }
        item(key = "choices") {
            RowGroup {
                ResetChoice.entries.forEach { choice ->
                    row { shape ->
                        ListRow(
                            shape, resetChoiceTitle(choice), resetChoiceSummary(choice), BridgeyIcons.Delete,
                            if (choice == ResetChoice.EVERYTHING) Tint.PURPLE else Tint.NEUTRAL,
                            onClick = { onChoose(choice) },
                        ) { androidx.compose.material3.Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant) }
                    }
                }
            }
        }
        if (done != null) {
            item(key = "done") {
                Row(Modifier.padding(start = 32.dp, end = 32.dp, top = 16.dp)) {
                    StatusPill(resetDoneText(done), BridgeyIcons.Check, Tint.GREEN)
                }
            }
        }
    }
    confirming?.let { choice -> ResetConfirmDialog(choice, onDismiss = { onChoose(null) }, onConfirm = { onConfirm(choice) }) }
}

/** Exactly what goes and what stays, then a destructive Delete (Reset Bridgey for Everything). */
@Composable
fun ResetConfirmDialog(choice: ResetChoice, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    val colors = BridgeyTheme.colors
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colors.surface2,
        title = { Text(resetConfirmTitle(choice), style = BridgeyType.cardTitle, color = colors.onSurface) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(R.string.reset_deleted), style = BridgeyType.smallStrong, color = colors.warn, modifier = Modifier.semantics { heading() })
                LocalDataReset.items(choice).forEach { Bullet(resetItemText(it)) }
                Text(
                    stringResource(R.string.reset_kept),
                    style = BridgeyType.smallStrong,
                    color = colors.onTintGreen,
                    modifier = Modifier.padding(top = 8.dp).semantics { heading() },
                )
                LocalDataReset.kept(choice).forEach { Bullet(resetKeptText(it)) }
                when (choice) {
                    ResetChoice.EVERYTHING -> Text(stringResource(R.string.reset_everything_note), style = BridgeyType.itemBody, color = colors.onSurface, modifier = Modifier.padding(top = 8.dp))
                    ResetChoice.SETTINGS -> Text(stringResource(R.string.reset_restart_note), style = BridgeyType.itemBody, color = colors.onSurface, modifier = Modifier.padding(top = 8.dp))
                    else -> Unit
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(
                    stringResource(if (choice == ResetChoice.EVERYTHING) R.string.reset_bridgey else R.string.reset_delete),
                    style = BridgeyType.label,
                    color = colors.warn,
                )
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel), style = BridgeyType.label, color = colors.onSurfaceVariant) } },
    )
}

@Composable
private fun Bullet(text: String) {
    val colors = BridgeyTheme.colors
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.padding(top = 7.dp).size(5.dp).clip(CircleShape).background(colors.onSurfaceVariant))
        Text(text, style = BridgeyType.itemBody, color = colors.onSurface, modifier = Modifier.weight(1f))
    }
}

@Composable
fun resetChoiceTitle(choice: ResetChoice): String = stringResource(
    when (choice) {
        ResetChoice.ACTIVITY_AND_LOGS -> R.string.reset_choice_activity
        ResetChoice.MODELS_AND_CACHES -> R.string.reset_choice_caches
        ResetChoice.SETTINGS -> R.string.reset_choice_settings
        ResetChoice.EVERYTHING -> R.string.reset_choice_everything
    },
)

@Composable
private fun resetChoiceSummary(choice: ResetChoice): String = stringResource(
    when (choice) {
        ResetChoice.ACTIVITY_AND_LOGS -> R.string.reset_choice_activity_summary
        ResetChoice.MODELS_AND_CACHES -> R.string.reset_choice_caches_summary
        ResetChoice.SETTINGS -> R.string.reset_choice_settings_summary
        ResetChoice.EVERYTHING -> R.string.reset_choice_everything_summary
    },
)

@Composable
private fun resetConfirmTitle(choice: ResetChoice): String = stringResource(
    when (choice) {
        ResetChoice.ACTIVITY_AND_LOGS -> R.string.reset_confirm_activity
        ResetChoice.MODELS_AND_CACHES -> R.string.reset_confirm_caches
        ResetChoice.SETTINGS -> R.string.reset_confirm_settings
        ResetChoice.EVERYTHING -> R.string.reset_confirm_everything
    },
)

@Composable
fun resetDoneText(choice: ResetChoice): String = stringResource(
    when (choice) {
        ResetChoice.ACTIVITY_AND_LOGS -> R.string.reset_done_activity
        ResetChoice.MODELS_AND_CACHES -> R.string.reset_done_caches
        ResetChoice.SETTINGS -> R.string.reset_done_settings
        ResetChoice.EVERYTHING -> R.string.reset_done_everything
    },
)

@Composable
private fun resetItemText(item: ResetItem): String = stringResource(
    when (item) {
        ResetItem.ACTIVITY -> R.string.reset_item_activity
        ResetItem.DIAGNOSTICS -> R.string.reset_item_diagnostics
        ResetItem.TRANSFER_HISTORY -> R.string.reset_item_transfers
        ResetItem.LOG_FILES -> R.string.reset_item_logs
        ResetItem.UPDATE_APKS -> R.string.reset_item_updates
        ResetItem.CLIPBOARD_CACHE -> R.string.reset_item_clipboard
        ResetItem.FOLDER_JOURNALS -> R.string.reset_item_folders
        ResetItem.OTHER_CACHES -> R.string.reset_item_caches
        ResetItem.FEATURE_SETTINGS -> R.string.reset_item_features
        ResetItem.APP_PREFERENCES -> R.string.reset_item_app
        ResetItem.UPDATE_CHANNEL -> R.string.reset_item_channel
        ResetItem.FOLDER_PLACES -> R.string.reset_item_places
        ResetItem.SETUP -> R.string.reset_item_setup
        ResetItem.TRUSTED_DEVICES -> R.string.reset_item_trusted
        ResetItem.IDENTITY -> R.string.reset_item_identity
        ResetItem.RECONNECT_ADDRESSES -> R.string.reset_item_reconnect
        ResetItem.CODES_LINK -> R.string.reset_item_codes
        ResetItem.WHATS_NEW -> R.string.reset_item_whats_new
    },
)

@Composable
private fun resetKeptText(kept: ResetKept): String = stringResource(
    when (kept) {
        ResetKept.SETTINGS -> R.string.reset_keep_settings
        ResetKept.PAIRINGS -> R.string.reset_keep_pairings
        ResetKept.HISTORY -> R.string.reset_keep_history
        ResetKept.CACHES -> R.string.reset_keep_caches
        ResetKept.APP -> R.string.reset_keep_app
    },
)
