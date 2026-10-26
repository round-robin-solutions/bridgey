package dev.bridgey.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.bridgey.android.LoggingPolicy
import dev.bridgey.android.R
import dev.bridgey.android.ui.theme.BridgeyTheme

/**
 * Settings > Privacy > Logging: one switch per category, content switches under their category,
 * then Export diagnostics and Clear logs. Per phone.
 */
@Composable
fun LoggingSettingsGroup(
    policy: LoggingPolicy,
    setPolicy: (LoggingPolicy) -> Unit,
    exportDiagnostics: () -> Unit,
    clearLogs: () -> Unit,
) {
    var confirmClear by rememberSaveable { mutableStateOf(false) }
    Column {
        Note(stringResource(R.string.logging_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 16.dp))
        RowGroup(Modifier.padding(top = 8.dp)) {
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.logging_connection), stringResource(R.string.logging_connection_detail),
                    BridgeyIcons.Wifi, tintFor(policy.connection), policy.connection, { setPolicy(policy.copy(connection = it)) },
                )
            }
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.logging_calls), stringResource(R.string.logging_calls_detail),
                    BridgeyIcons.Call, tintFor(policy.calls), policy.calls, { setPolicy(policy.copy(calls = it)) },
                )
            }
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.logging_call_numbers), stringResource(R.string.logging_call_numbers_detail),
                    null, tintFor(policy.callNumbers), policy.callNumbers, { setPolicy(policy.copy(callNumbers = it)) },
                    enabled = policy.calls, compact = true,
                )
            }
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.logging_notifications), stringResource(R.string.logging_notifications_detail),
                    BridgeyIcons.Notifications, tintFor(policy.notifications), policy.notifications,
                    { setPolicy(policy.copy(notifications = it)) },
                )
            }
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.logging_notification_content), stringResource(R.string.logging_notification_content_detail),
                    null, tintFor(policy.notificationContent), policy.notificationContent,
                    { setPolicy(policy.copy(notificationContent = it)) }, enabled = policy.notifications, compact = true,
                )
            }
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.logging_clipboard), stringResource(R.string.logging_clipboard_detail),
                    BridgeyIcons.ContentPaste, tintFor(policy.clipboard), policy.clipboard, { setPolicy(policy.copy(clipboard = it)) },
                )
            }
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.logging_clipboard_previews), stringResource(R.string.logging_clipboard_previews_detail),
                    null, tintFor(policy.clipboardPreviews), policy.clipboardPreviews,
                    { setPolicy(policy.copy(clipboardPreviews = it)) }, enabled = policy.clipboard, compact = true,
                )
            }
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.logging_file_names), stringResource(R.string.logging_file_names_detail),
                    BridgeyIcons.Folder, tintFor(policy.fileNames), policy.fileNames, { setPolicy(policy.copy(fileNames = it)) },
                )
            }
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.logging_remote), stringResource(R.string.logging_remote_detail),
                    BridgeyIcons.Mouse, tintFor(policy.remoteControl), policy.remoteControl, { setPolicy(policy.copy(remoteControl = it)) },
                )
            }
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.settings_diagnostics), stringResource(R.string.settings_diagnostics_detail),
                    BridgeyIcons.BugReport, Tint.NEUTRAL, onClick = exportDiagnostics, onClickLabel = stringResource(R.string.action_share),
                ) { Icon(BridgeyIcons.IosShare, null, tint = BridgeyTheme.colors.onSurfaceVariant, modifier = Modifier.size(20.dp)) }
            }
            row { shape ->
                ListRow(shape, stringResource(R.string.logging_clear), stringResource(R.string.logging_clear_detail), BridgeyIcons.Delete, Tint.NEUTRAL) {
                    OutlinePillButton(stringResource(R.string.action_clear), null, { confirmClear = true })
                }
            }
        }
    }
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text(stringResource(R.string.logging_clear_title)) },
            text = { Text(stringResource(R.string.logging_clear_body)) },
            confirmButton = { TextButton(onClick = { confirmClear = false; clearLogs() }) { Text(stringResource(R.string.action_clear)) } },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

private fun tintFor(on: Boolean): Tint = if (on) Tint.BLUE else Tint.NEUTRAL
