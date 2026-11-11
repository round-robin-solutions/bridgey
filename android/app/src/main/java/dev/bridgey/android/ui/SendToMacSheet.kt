package dev.bridgey.android.ui

import android.os.SystemClock
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.sharing.ShareFlow
import dev.bridgey.android.sharing.ShareMac
import dev.bridgey.android.sharing.SharePhase
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** Stream's existing bottom-sheet hierarchy: destination, state, one row of controls. */
@Composable
fun SendToMacSheet(
    state: ShareFlow, macs: List<ShareMac>, host: String?, files: Boolean,
    choose: (String) -> Unit, send: () -> Unit, change: () -> Unit, cancel: () -> Unit,
) {
    val colors = BridgeyTheme.colors
    val selected = macs.firstOrNull { it.id == state.target }
    val choosing = state.phase == SharePhase.CHOOSING
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        Column(
            Modifier.capWidth().fillMaxWidth().padding(12.dp).navigationBarsPadding()
                .clip(RoundedCornerShape(28.dp)).background(colors.surface1)
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                IconTile(if (files) BridgeyIcons.Folder else BridgeyIcons.OpenInNew, Tint.BLUE)
                Column(Modifier.weight(1f)) {
                    Text(if (choosing || selected == null) stringResource(R.string.share_to_mac) else selected.name,
                        style = BridgeyType.cardTitle, color = colors.onSurface,
                        modifier = Modifier.semantics { heading() }, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    host?.let { Text(it, style = BridgeyType.itemBody, color = colors.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis) }
                }
            }
            if (choosing) {
                Column(Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    macs.forEach { mac ->
                        val chosen = mac.id == state.target
                        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(colors.surface2)
                            .selectable(chosen, enabled = mac.eligible, role = Role.RadioButton) { choose(mac.id) }
                            .padding(14.dp).alpha(if (mac.eligible) 1f else 0.55f),
                            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(20.dp).clip(CircleShape).background(if (chosen) colors.primary else colors.outline), contentAlignment = Alignment.Center) {
                                Box(Modifier.size(if (chosen) 8.dp else 16.dp).clip(CircleShape).background(if (chosen) colors.onPrimary else colors.surface2))
                            }
                            Column(Modifier.weight(1f)) {
                                Text(mac.name, style = BridgeyType.itemTitle, color = colors.onSurface, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                val label = when {
                                    mac.sessionId == null -> R.string.share_offline
                                    !mac.allowed -> R.string.share_feature_off
                                    mac.presence?.activeAge(SystemClock.elapsedRealtime()) != null -> R.string.share_active
                                    else -> null
                                }
                                label?.let { Text(stringResource(it), style = BridgeyType.itemBody, color = colors.onSurfaceVariant) }
                            }
                        }
                    }
                }
                if (macs.none { it.eligible }) Text(stringResource(R.string.share_no_mac), style = BridgeyType.bodyText, color = colors.onSurfaceVariant)
            } else {
                val text = when (state.phase) {
                    SharePhase.GRACE -> stringResource(R.string.share_sending_soon)
                    SharePhase.SENDING -> stringResource(R.string.share_sending)
                    else -> state.message.orEmpty()
                }
                Text(text, style = BridgeyType.bodyText, color = colors.onSurfaceVariant,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                if (state.phase == SharePhase.GRACE || state.phase == SharePhase.SENDING) {
                    // A determinate grace indicator; no hidden dispatch or looping decorative animation.
                    var started by remember(state.phase) { mutableStateOf(false) }
                    LaunchedEffect(state.phase) { started = true }
                    val progress by animateFloatAsState(if (started) 1f else 0f, tween(1500), label = "shareGrace")
                    LinearProgressIndicator(progress = { if (state.phase == SharePhase.SENDING) 1f else progress },
                        modifier = Modifier.fillMaxWidth(), color = colors.primary, trackColor = colors.surface2)
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                when (state.phase) {
                    SharePhase.CHOOSING -> {
                        OutlinePillButton(stringResource(R.string.action_cancel), null, cancel)
                        GradientButton(stringResource(R.string.share_send), null, send, enabled = selected?.eligible == true,
                            height = 48.dp, textStyle = BridgeyType.label)
                    }
                    SharePhase.GRACE -> {
                        OutlinePillButton(stringResource(R.string.action_cancel), null, cancel)
                        GradientButton(stringResource(R.string.share_change), null, change, height = 48.dp, textStyle = BridgeyType.label)
                    }
                    SharePhase.FAILED -> {
                        OutlinePillButton(stringResource(R.string.share_another), null, change, modifier = Modifier.weight(1f))
                        GradientButton(stringResource(R.string.share_retry), null, send, enabled = selected?.eligible == true,
                            height = 48.dp, textStyle = BridgeyType.label)
                    }
                    SharePhase.SENDING -> Unit
                    else -> OutlinePillButton(stringResource(R.string.action_close), null, cancel)
                }
            }
        }
    }
}
