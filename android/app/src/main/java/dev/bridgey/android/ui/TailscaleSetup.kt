package dev.bridgey.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.bridgey.android.R
import dev.bridgey.android.tailscale.AndroidTailscaleAppAccess
import dev.bridgey.android.tailscale.TailscaleSetup
import dev.bridgey.android.tailscale.TailscaleSetupActions
import dev.bridgey.android.tailscale.TailscaleSetupState
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** Resuming the UI refreshes install state after external setup. No polling or network scan. */
@Composable
internal fun rememberTailscaleSetup(): Pair<TailscaleSetupState, TailscaleSetupActions> {
    val context = LocalContext.current.applicationContext
    val setup = remember(context) { TailscaleSetup(AndroidTailscaleAppAccess(context)) }
    val state by setup.state.collectAsStateWithLifecycle()
    androidx.lifecycle.compose.LifecycleResumeEffect(setup) {
        setup.refresh(clearResult = false)
        onPauseOrDispose { }
    }
    return state to TailscaleSetupActions(setup::open, { setup.refresh() })
}

/** Installed is intentionally not called signed in or connected. Same guidance in Pair and Settings. */
@Composable
@OptIn(ExperimentalLayoutApi::class)
internal fun TailscaleSetupGuidance(
    state: TailscaleSetupState,
    actions: TailscaleSetupActions,
    modifier: Modifier = Modifier,
    forPairing: Boolean = true,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(R.string.tailscale_title), style = BridgeyType.itemTitle)
        val status = when {
            state.openFailed -> R.string.tailscale_open_failed
            state.openedDownload -> R.string.tailscale_download_opened
            state.installed == true -> R.string.tailscale_installed
            state.installed == false -> R.string.tailscale_not_installed
            else -> R.string.tailscale_unknown
        }
        Text(stringResource(status), style = BridgeyType.itemBody, color = BridgeyTheme.colors.onSurfaceVariant,
            minLines = 5, modifier = Modifier.testTag("tailscale-availability"))
        Text(stringResource(if (forPairing) R.string.tailscale_setup_steps else R.string.tailscale_settings_steps),
            style = BridgeyType.itemBody, color = BridgeyTheme.colors.onSurfaceVariant)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = actions.open, modifier = Modifier.testTag("tailscale-open")) {
                Text(stringResource(if (state.installed == false) R.string.tailscale_install else R.string.tailscale_open))
            }
            TextButton(onClick = actions.refresh, modifier = Modifier.testTag("tailscale-refresh")) {
                Text(stringResource(R.string.tailscale_check_again))
            }
        }
    }
}
