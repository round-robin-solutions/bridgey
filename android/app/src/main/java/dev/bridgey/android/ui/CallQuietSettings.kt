package dev.bridgey.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.media.CallMediaMode
import dev.bridgey.android.media.CallMediaPhase
import dev.bridgey.android.media.CallMediaPolicy
import dev.bridgey.android.media.CallMediaRestoration
import dev.bridgey.android.media.CallMediaResult
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

data class CallQuietSettingsState(
    val policy: CallMediaPolicy = CallMediaPolicy(),
    val result: CallMediaResult = CallMediaResult(),
    val phoneState: Boolean = false,
    val notificationAccess: Boolean = false,
    val peers: Map<String, dev.bridgey.android.media.CallQuietResult> = emptyMap(),
)

class CallQuietSettingsActions(
    val setMode: (CallMediaMode) -> Unit = {},
    val setRestoration: (CallMediaRestoration) -> Unit = {},
    val requestPhoneState: () -> Unit = {},
    val openNotificationAccess: () -> Unit = {},
)

internal fun GroupScope.callQuietRows(state: CallQuietSettingsState, actions: CallQuietSettingsActions) {
    row { shape ->
        QuietChoiceRow(shape, stringResource(R.string.call_quiet_mode), state.policy.mode,
            CallMediaMode.entries, { quietModeLabel(it) }, actions.setMode)
    }
    row { shape ->
        QuietChoiceRow(shape, stringResource(R.string.call_quiet_after), state.policy.restoration,
            CallMediaRestoration.entries, { quietRestorationLabel(it) }, actions.setRestoration)
    }
    row { shape ->
        ListRow(shape, stringResource(R.string.call_quiet_phone_state),
            stringResource(if (state.phoneState) R.string.call_quiet_phone_state_on else R.string.call_quiet_phone_state_off),
            BridgeyIcons.Call, if (state.phoneState) Tint.GREEN else Tint.NEUTRAL,
            onClick = if (state.phoneState) null else actions.requestPhoneState) {
            if (!state.phoneState) TonalPillButton(stringResource(R.string.action_enable), actions.requestPhoneState)
        }
    }
    row { shape ->
        ListRow(shape, stringResource(R.string.call_quiet_access),
            stringResource(if (state.notificationAccess) R.string.call_quiet_access_on else R.string.call_quiet_access_off),
            BridgeyIcons.MusicNote, if (state.notificationAccess) Tint.GREEN else Tint.NEUTRAL,
            onClick = actions.openNotificationAccess) {
            Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant)
        }
    }
    row { shape ->
        val detail = when (state.result.phase) {
            CallMediaPhase.IDLE -> stringResource(R.string.call_quiet_ready)
            CallMediaPhase.PENDING -> stringResource(R.string.call_quiet_pending)
            CallMediaPhase.UNAVAILABLE -> stringResource(R.string.call_quiet_unavailable)
            CallMediaPhase.APPLIED, CallMediaPhase.PARTIAL -> stringResource(R.string.call_quiet_counts,
                state.result.paused, if (state.result.muted) 1 else 0, state.result.unsupported)
        }
        ListRow(shape, stringResource(R.string.call_quiet_status), detail, BridgeyIcons.MusicNote,
            if (state.result.phase == CallMediaPhase.PARTIAL || state.result.phase == CallMediaPhase.UNAVAILABLE) Tint.NEUTRAL else Tint.BLUE,
            onClick = null)
    }
    row { shape ->
        val detail = if (state.peers.isEmpty()) stringResource(R.string.call_quiet_peers_waiting)
            else stringResource(R.string.call_quiet_peer_counts, state.peers.size,
                state.peers.values.sumOf { it.paused }, state.peers.values.sumOf { it.muted }, state.peers.values.sumOf { it.limited })
        ListRow(shape, stringResource(R.string.call_quiet_peers), detail, BridgeyIcons.Sensors, Tint.BLUE, onClick = null)
    }
}

@Composable
private fun <T> QuietChoiceRow(shape: Shape, title: String, selected: T, choices: List<T>, label: @Composable (T) -> String, select: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val colors = BridgeyTheme.colors
    Box {
        ListRow(shape, title, label(selected), BridgeyIcons.MusicNote, Tint.BLUE,
            onClick = { open = true }, role = Role.DropdownList) {
            Icon(BridgeyIcons.ArrowDropDown, null, tint = colors.onSurfaceVariant, modifier = Modifier.size(24.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = colors.surface2,
            shape = RoundedCornerShape(20.dp), modifier = Modifier.widthIn(max = 340.dp)) {
            choices.forEach { choice ->
                DropdownMenuItem(text = { Text(label(choice), style = BridgeyType.label, color = colors.onSurface) },
                    trailingIcon = if (choice == selected) ({ Icon(BridgeyIcons.Check, null, tint = colors.primary) }) else null,
                    onClick = { open = false; select(choice) }, modifier = Modifier.heightIn(min = 48.dp))
            }
        }
    }
}

@Composable
internal fun quietModeLabel(mode: CallMediaMode): String = stringResource(when (mode) {
    CallMediaMode.PAUSE_THEN_MUTE -> R.string.call_quiet_pause_mute
    CallMediaMode.PAUSE_ONLY -> R.string.call_quiet_pause_only
    CallMediaMode.MUTE_ONLY -> R.string.call_quiet_mute_only
})

@Composable
internal fun quietRestorationLabel(value: CallMediaRestoration): String = stringResource(when (value) {
    CallMediaRestoration.RESTORE_AND_RESUME -> R.string.call_quiet_restore_resume
    CallMediaRestoration.RESTORE_SOUND -> R.string.call_quiet_restore_sound
    CallMediaRestoration.LEAVE_AS_IS -> R.string.call_quiet_leave_as_is
})
