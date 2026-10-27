package dev.bridgey.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.setup.OemChecklist
import dev.bridgey.android.setup.OemStep
import dev.bridgey.android.ui.theme.BridgeyTheme

/** The v0.10 rows in Settings: Privacy (Permissions, Reset), General (OEM checklist, Run setup again), About (Obtainium). */
data class SetupSettingsState(
    /** This phone's maker stops background apps: its steps (General). */
    val oem: OemChecklist? = null,
)

class SetupSettingsActions(
    val openPermissions: () -> Unit = {},
    val openReset: () -> Unit = {},
    val runSetup: () -> Unit = {},
    val openOemStep: (OemStep) -> Unit = {},
    val addToObtainium: () -> Unit = {},
)

/** Privacy: Permissions, then Reset Bridgey on this device. */
@Composable
fun PrivacySetupRows(actions: SetupSettingsActions) {
    RowGroup(Modifier.padding(top = 24.dp)) {
        row { shape ->
            ListRow(
                shape, stringResource(R.string.perm_page_title), stringResource(R.string.perm_page_detail),
                BridgeyIcons.Shield, Tint.BLUE, onClick = actions.openPermissions,
            ) { SetupChevron() }
        }
        row { shape ->
            ListRow(
                shape, stringResource(R.string.reset_title), stringResource(R.string.reset_detail),
                BridgeyIcons.Delete, Tint.NEUTRAL, onClick = actions.openReset,
            ) { SetupChevron() }
        }
    }
}

/** General: this phone maker's battery checklist, when it has one. */
@Composable
fun GeneralOemChecklist(state: SetupSettingsState, actions: SetupSettingsActions, openUrl: (String) -> Unit) {
    val checklist = state.oem ?: return
    OemChecklistCard(checklist, actions.openOemStep, openUrl, Modifier.padding(top = 16.dp))
}

/** General: Run setup again. */
@Composable
fun GeneralSetupRows(actions: SetupSettingsActions) {
    Column {
        RowGroup(Modifier.padding(top = 24.dp)) {
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.setup_run_again), stringResource(R.string.setup_run_again_detail),
                    BridgeyIcons.Refresh, Tint.BLUE, onClick = actions.runSetup,
                ) { SetupChevron() }
            }
        }
    }
}

/** About: Add to Obtainium, for the app's current update channel. */
@Composable
fun ObtainiumRow(channel: UpdateChannel, actions: SetupSettingsActions) {
    RowGroup(Modifier.padding(top = 24.dp)) {
        row { shape ->
            ListRow(
                shape, stringResource(R.string.obtainium_title), stringResource(R.string.obtainium_detail, channelTitle(channel)),
                BridgeyIcons.Download, Tint.GREEN, onClick = actions.addToObtainium,
            ) { Icon(BridgeyIcons.OpenInNew, null, tint = BridgeyTheme.colors.onSurfaceVariant) }
        }
    }
}

@Composable
private fun SetupChevron() = Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant)
