package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.codes.CodeAccessStatus
import dev.bridgey.android.codes.CodeLinkMac
import dev.bridgey.android.codes.CodeLinkTargets
import dev.bridgey.android.codes.CompanionLinkState
import dev.bridgey.android.codes.LinkFailure
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** Settings > Notifications > Codes from messages (codes are read on the Mac; this phone makes them visible). */
data class CodesSettingsState(
    val access: CodeAccessStatus = CodeAccessStatus.ALLOWED,
    val link: CompanionLinkState = CompanionLinkState.Idle,
    /** Android 15 or newer: the link (and its ADB fallback) matters. */
    val linkApplies: Boolean = false,
    /** A companion link exists (it may still not be honoured; then access says hidden). */
    val linked: Boolean = false,
    val adbCommand: String = "",
    /** Connected Macs that read codes; two or more open the picker before linking. */
    val linkTargets: List<CodeLinkMac> = emptyList(),
    /** The Mac "Link to ..." uses now (the picked, else the selected, else the first). */
    val linkTarget: CodeLinkMac? = null,
    /** The Mac recorded when the last link succeeded. */
    val linkedMac: CodeLinkMac? = null,
) {
    val showAdb: Boolean get() = linkApplies && access != CodeAccessStatus.ALLOWED
}

class CodesSettingsActions(
    val link: () -> Unit = {},
    /** The picker's choice: link with this Mac. */
    val linkTo: (String) -> Unit = {},
    val copyCommand: () -> Unit = {},
)

@Composable
fun codeAccessText(status: CodeAccessStatus): String = stringResource(
    when (status) {
        CodeAccessStatus.ALLOWED -> R.string.codes_access_allowed
        CodeAccessStatus.HIDDEN -> R.string.codes_access_hidden
        CodeAccessStatus.NOT_LINKED -> R.string.codes_access_not_linked
    },
)

@Composable
fun linkStateText(state: CompanionLinkState): String = when (state) {
    CompanionLinkState.Idle -> stringResource(R.string.codes_link_detail)
    CompanionLinkState.AskingMac -> stringResource(R.string.codes_link_asking)
    CompanionLinkState.Searching -> stringResource(R.string.codes_link_searching)
    CompanionLinkState.Linked -> stringResource(R.string.codes_link_done)
    is CompanionLinkState.Failed -> stringResource(
        when (state.reason) {
            LinkFailure.NO_MAC -> R.string.codes_link_failed_no_mac
            LinkFailure.MAC_TOO_OLD -> R.string.codes_link_failed_mac_old
            LinkFailure.MAC_NO_ANSWER -> R.string.codes_link_failed_no_answer
            LinkFailure.MAC_BLUETOOTH_OFF -> R.string.codes_link_failed_bluetooth_off
            LinkFailure.MAC_BLUETOOTH_DENIED -> R.string.codes_link_failed_bluetooth_denied
            LinkFailure.MAC_UNSUPPORTED -> R.string.codes_link_failed_mac_unsupported
            LinkFailure.PHONE_UNSUPPORTED -> R.string.codes_link_failed_phone
            LinkFailure.CANCELLED -> R.string.codes_link_failed_cancelled
            LinkFailure.FAILED -> R.string.codes_link_failed
        },
    )
}

/** The status row, then "Link this phone to the Mac" while Android may hide codes (or a link is under way). */
internal fun GroupScope.codesRows(state: CodesSettingsState, actions: CodesSettingsActions) {
    row { shape ->
        val ok = state.access == CodeAccessStatus.ALLOWED
        ListRow(
            shape, stringResource(R.string.codes_title), codeAccessText(state.access),
            BridgeyIcons.Notifications, if (ok) Tint.GREEN else Tint.NEUTRAL,
            detailWarning = !ok,
        ) { if (ok) androidx.compose.material3.Icon(BridgeyIcons.Check, null, tint = BridgeyTheme.colors.onTintGreen) }
    }
    val busy = state.link == CompanionLinkState.AskingMac || state.link == CompanionLinkState.Searching
    if (state.linkApplies) {
        row { shape -> CodesLinkRow(shape, state, actions, busy) }
    }
}

/** "Link to Personal Mac": which Mac the phone is linked to, and a picker when two or more read codes. */
@Composable
private fun CodesLinkRow(shape: androidx.compose.ui.graphics.Shape, state: CodesSettingsState, actions: CodesSettingsActions, busy: Boolean) {
    var picking by rememberSaveable { mutableStateOf(false) }
    val detail = when {
        state.link != CompanionLinkState.Idle -> linkStateText(state.link)
        state.linked && state.linkedMac != null && state.linkedMac.name.isNotBlank() -> stringResource(R.string.codes_linked_to, state.linkedMac.name)
        state.linked -> stringResource(R.string.codes_linked_unknown)
        else -> stringResource(R.string.codes_not_linked_yet)
    }
    ListRow(
        shape, state.linkTarget?.let { stringResource(R.string.codes_link_to, it.name) } ?: stringResource(R.string.codes_link), detail,
        BridgeyIcons.Link, if (state.linked && state.link == CompanionLinkState.Idle) Tint.GREEN else Tint.BLUE,
        detailWarning = state.link is CompanionLinkState.Failed,
        onClick = when {
            busy -> null
            CodeLinkTargets.needsPicker(state.linkTargets) -> ({ picking = true })
            else -> actions.link
        },
    ) { if (!busy) Chevron() }
    if (picking) {
        CodesLinkPicker(
            state.linkTargets, state.linkTarget?.deviceId,
            onDismiss = { picking = false },
            onLink = { picking = false; actions.linkTo(it) },
        )
    }
}

/** A small radio list of the Macs that read codes, the current target preselected. */
@Composable
fun CodesLinkPicker(macs: List<CodeLinkMac>, current: String?, onDismiss: () -> Unit, onLink: (String) -> Unit) {
    val colors = BridgeyTheme.colors
    var selected by rememberSaveable { mutableStateOf(current ?: macs.firstOrNull()?.deviceId) }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colors.surface2,
        title = { Text(stringResource(R.string.codes_picker_title), style = BridgeyType.cardTitle, color = colors.onSurface) },
        text = {
            Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(stringResource(R.string.codes_picker_body), style = BridgeyType.itemBody, color = colors.onSurfaceVariant, modifier = Modifier.padding(bottom = 8.dp))
                macs.forEach { mac ->
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(RoundedCornerShape(16.dp))
                            .selectable(selected = mac.deviceId == selected, role = Role.RadioButton) { selected = mac.deviceId }
                            .padding(horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        androidx.compose.material3.RadioButton(
                            selected = mac.deviceId == selected,
                            onClick = null,
                            colors = androidx.compose.material3.RadioButtonDefaults.colors(selectedColor = colors.primary, unselectedColor = colors.onSurfaceVariant),
                        )
                        DeviceGlyph(RingStyle.SAME_WIFI, BridgeyIcons.LaptopMac, 36.dp, iconSize = 16.dp)
                        Text(mac.name, style = BridgeyType.itemTitle, color = colors.onSurface, modifier = Modifier.weight(1f))
                    }
                }
            }
        },
        confirmButton = {
            androidx.compose.material3.TextButton(onClick = { selected?.let(onLink) }, enabled = selected != null) {
                Text(stringResource(R.string.codes_picker_link), style = BridgeyType.label, color = colors.primary)
            }
        },
        dismissButton = {
            androidx.compose.material3.TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.action_cancel), style = BridgeyType.label, color = colors.onSurfaceVariant)
            }
        },
    )
}

/** What the section means, and the one-time ADB command when linking is not enough. */
@Composable
fun CodesFootnote(state: CodesSettingsState, actions: CodesSettingsActions) {
    val colors = BridgeyTheme.colors
    Column {
        Note(stringResource(R.string.codes_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp))
        if (state.showAdb) {
            Column(
                Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp).fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(colors.surface1).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(stringResource(R.string.codes_adb_title), style = BridgeyType.itemTitle, color = colors.onSurface)
                CodesStep(1, stringResource(R.string.codes_adb_step1))
                CodesStep(2, stringResource(R.string.codes_adb_step2))
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(colors.surface2).padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        state.adbCommand,
                        style = BridgeyType.small.copy(fontFamily = FontFamily.Monospace),
                        color = colors.onSurface,
                        modifier = Modifier.weight(1f),
                    )
                    OutlinePillButton(stringResource(R.string.action_copy), BridgeyIcons.ContentPaste, actions.copyCommand)
                }
                CodesStep(3, stringResource(R.string.codes_adb_step3))
            }
        }
    }
}

@Composable
private fun CodesStep(number: Int, text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("$number.", style = BridgeyType.itemBody.copy(fontWeight = BridgeyType.label.fontWeight), color = BridgeyTheme.colors.primary)
        Text(text, style = BridgeyType.itemBody, color = BridgeyTheme.colors.onSurfaceVariant)
    }
}

@Composable
private fun Chevron() = androidx.compose.material3.Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant)
