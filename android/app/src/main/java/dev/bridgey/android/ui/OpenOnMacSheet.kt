package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** One Mac Open on Mac can send to. */
data class OpenOnMacTarget(val deviceId: String, val name: String, val available: Boolean = true, val detail: String = "", val suggested: Boolean = false)

sealed interface OpenOnMacPhase {
    /** Waiting for the person's tap: nothing is sent before it. */
    data object Confirm : OpenOnMacPhase
    data class Sending(val macName: String) : OpenOnMacPhase
    data class Finished(val message: String, val success: Boolean) : OpenOnMacPhase

    /** Nothing to send: no web link, or no Mac with Web links on. */
    data class Nothing(val message: String) : OpenOnMacPhase
}

data class OpenOnMacState(
    /** Only the link's host is shown, never the whole address. */
    val host: String?,
    val targets: List<OpenOnMacTarget>,
    val selected: String?,
    val phase: OpenOnMacPhase,
    val message: String? = null,
)

class OpenOnMacActions(
    val select: (String) -> Unit = {},
    val open: () -> Unit = {},
    val cancel: () -> Unit = {},
)

/**
 * Open on Mac (share target): a small sheet at the bottom. It names the host and the Mac, offers
 * a choice when several Macs could take it, and sends only after Open.
 */
@Composable
fun OpenOnMacSheet(state: OpenOnMacState, actions: OpenOnMacActions) {
    val colors = BridgeyTheme.colors
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        Column(
            Modifier
                .capWidth()
                .fillMaxWidth()
                .padding(12.dp)
                .navigationBarsPadding()
                .clip(RoundedCornerShape(28.dp))
                .background(colors.surface1)
                .padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            val selectedName = state.targets.firstOrNull { it.deviceId == state.selected }?.name ?: state.targets.firstOrNull()?.name.orEmpty()
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                IconTile(BridgeyIcons.OpenInNew, Tint.BLUE)
                Column(Modifier.weight(1f)) {
                    val title = if (state.phase !is OpenOnMacPhase.Confirm) {
                        stringResource(R.string.open_on_mac_title, selectedName.ifEmpty { "Mac" })
                    } else {
                        stringResource(R.string.open_on_mac_pick)
                    }
                    Text(
                        if (state.phase is OpenOnMacPhase.Nothing) stringResource(R.string.open_on_mac_label) else title,
                        style = BridgeyType.cardTitle, color = colors.onSurface, modifier = Modifier.semantics { heading() },
                    )
                    state.host?.let {
                        Text(it, style = BridgeyType.itemBody, color = colors.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            when (val phase = state.phase) {
                OpenOnMacPhase.Confirm -> {
                    DeviceDestinationList(
                        state.targets.map { DeviceDestination(it.deviceId, it.name, it.available, it.detail, it.suggested) },
                        state.selected, actions.select,
                    )
                    state.message?.let { Text(it, style = BridgeyType.itemBody, color = colors.onTintPurple) }
                    Text(stringResource(R.string.open_on_mac_body), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                        OutlinePillButton(stringResource(R.string.action_cancel), null, actions.cancel)
                        GradientButton(stringResource(R.string.action_open), null, actions.open, enabled = state.targets.any { it.deviceId == state.selected && it.available }, height = 40.dp, textStyle = BridgeyType.label)
                    }
                }
                is OpenOnMacPhase.Sending -> Text(stringResource(R.string.open_on_mac_sending, phase.macName), style = BridgeyType.bodyText, color = colors.onSurfaceVariant)
                is OpenOnMacPhase.Finished -> {
                    Text(phase.message, style = BridgeyType.bodyText, color = if (phase.success) colors.onSurface else colors.onTintPurple)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        OutlinePillButton(stringResource(R.string.action_close), null, actions.cancel)
                    }
                }
                is OpenOnMacPhase.Nothing -> {
                    Text(phase.message, style = BridgeyType.bodyText, color = colors.onSurfaceVariant)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        OutlinePillButton(stringResource(R.string.action_close), null, actions.cancel)
                    }
                }
            }
        }
    }
}
