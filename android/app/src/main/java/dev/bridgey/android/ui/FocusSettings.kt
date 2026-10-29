package dev.bridgey.android.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import dev.bridgey.android.R

/** Settings > Notifications > Focus sync: each direction its own switch, both off by default. */
data class FocusSettingsState(
    /** Share Do Not Disturb with Macs: this phone's Do Not Disturb turns on the Mac's Focus. */
    val share: Boolean = false,
    /** Follow the Mac's Focus: the Mac's Focus turns on Do Not Disturb here. */
    val follow: Boolean = false,
    /** Android lets Bridgey change Do Not Disturb (Do Not Disturb access). */
    val access: Boolean = false,
)

class FocusSettingsActions(
    val setShare: (Boolean) -> Unit = {},
    /** Turning Follow on without access also opens Android's Do Not Disturb access page. */
    val setFollow: (Boolean) -> Unit = {},
    val openAccess: () -> Unit = {},
)

/** Share, Follow, and while Follow lacks access, the row that opens Android's access page. */
internal fun GroupScope.focusRows(
    state: FocusSettingsState,
    actions: FocusSettingsActions,
    sync: dev.bridgey.android.sync.SyncUiState = dev.bridgey.android.sync.SyncUiState(),
    syncActions: SyncSettingsActions = SyncSettingsActions(),
) {
    row { shape ->
        SwitchRow(
            shape, stringResource(R.string.focus_share_title), stringResource(R.string.focus_share_detail),
            BridgeyIcons.Bedtime, if (state.share) Tint.PURPLE else Tint.NEUTRAL, state.share, actions.setShare,
            synced = sync.syncs(dev.bridgey.android.sync.SyncKey.FOCUS_SHARE),
        )
    }
    syncRows(dev.bridgey.android.sync.SyncKey.FOCUS_SHARE, sync, syncActions)
    row { shape ->
        SwitchRow(
            shape, stringResource(R.string.focus_follow_title), stringResource(R.string.focus_follow_detail),
            BridgeyIcons.Bedtime, if (state.follow) Tint.PURPLE else Tint.NEUTRAL, state.follow, actions.setFollow,
            synced = sync.syncs(dev.bridgey.android.sync.SyncKey.FOCUS_FOLLOW),
        )
    }
    syncRows(dev.bridgey.android.sync.SyncKey.FOCUS_FOLLOW, sync, syncActions)
    if (state.follow) {
        row { shape -> FocusAccessRow(shape, state, actions) }
    }
}

@Composable
private fun FocusAccessRow(shape: androidx.compose.ui.graphics.Shape, state: FocusSettingsState, actions: FocusSettingsActions) {
    ListRow(
        shape, stringResource(R.string.focus_access_title),
        stringResource(if (state.access) R.string.focus_access_on else R.string.focus_access_off),
        BridgeyIcons.Shield, if (state.access) Tint.GREEN else Tint.NEUTRAL,
        detailWarning = !state.access,
        onClick = actions.openAccess,
    ) {
        if (state.access) {
            androidx.compose.material3.Icon(BridgeyIcons.ChevronRight, null, tint = dev.bridgey.android.ui.theme.BridgeyTheme.colors.onSurfaceVariant)
        } else {
            TonalPillButton(stringResource(R.string.action_enable), actions.openAccess)
        }
    }
}
