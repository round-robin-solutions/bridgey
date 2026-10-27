package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.setup.OemBattery
import dev.bridgey.android.setup.OemChecklist
import dev.bridgey.android.setup.OemStep
import dev.bridgey.android.setup.OemStepKind
import dev.bridgey.android.setup.OemVendor
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** The phone maker's own battery steps, each with an Open button, and where they come from. */
@Composable
fun OemChecklistCard(checklist: OemChecklist, onOpen: (OemStep) -> Unit, openUrl: (String) -> Unit, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    Column(
        modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(colors.surface1)
            .padding(start = 20.dp, end = 12.dp, top = 16.dp, bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.padding(end = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                stringResource(R.string.oem_title, oemVendorName(checklist.vendor)),
                style = BridgeyType.itemTitle,
                color = colors.onSurface,
                modifier = Modifier.semantics { heading() },
            )
            Text(stringResource(R.string.oem_intro), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
        }
        checklist.steps.forEachIndexed { index, step ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("${index + 1}.", style = BridgeyType.label, color = colors.primary, modifier = Modifier.align(Alignment.Top).width(18.dp))
                Column(Modifier.weight(1f)) {
                    Text(oemStepTitle(step.kind), style = BridgeyType.label, color = colors.onSurface)
                    Text(oemStepDetail(checklist.vendor, step.kind), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
                }
                OutlinePillButton(stringResource(R.string.action_open), null, { onOpen(step) })
            }
        }
        Row(
            Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button) { openUrl(OemBattery.SOURCE_URL) },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(stringResource(R.string.oem_source), style = BridgeyType.smallStrong, color = colors.primary)
            Icon(BridgeyIcons.OpenInNew, null, tint = colors.primary, modifier = Modifier.size(14.dp))
        }
    }
}

@Composable
fun oemVendorName(vendor: OemVendor): String = stringResource(
    when (vendor) {
        OemVendor.ONEPLUS -> R.string.oem_vendor_oneplus
        OemVendor.COLOROS -> R.string.oem_vendor_coloros
        OemVendor.XIAOMI -> R.string.oem_vendor_xiaomi
        OemVendor.SAMSUNG -> R.string.oem_vendor_samsung
        OemVendor.VIVO -> R.string.oem_vendor_vivo
    },
)

@Composable
private fun oemStepTitle(kind: OemStepKind): String = stringResource(
    when (kind) {
        OemStepKind.AUTO_START -> R.string.oem_step_auto_start
        OemStepKind.BACKGROUND_ACTIVITY -> R.string.oem_step_background
        OemStepKind.BATTERY_OPTIMISATION -> R.string.oem_step_battery
        OemStepKind.NEVER_SLEEPING -> R.string.oem_step_never_sleeping
    },
)

@Composable
private fun oemStepDetail(vendor: OemVendor, kind: OemStepKind): String = stringResource(
    when (vendor) {
        OemVendor.ONEPLUS -> when (kind) {
            OemStepKind.AUTO_START -> R.string.oem_oneplus_auto_start
            OemStepKind.BACKGROUND_ACTIVITY -> R.string.oem_oneplus_background
            else -> R.string.oem_oneplus_battery
        }
        OemVendor.COLOROS -> when (kind) {
            OemStepKind.AUTO_START -> R.string.oem_coloros_auto_start
            OemStepKind.BACKGROUND_ACTIVITY -> R.string.oem_coloros_background
            else -> R.string.oem_coloros_battery
        }
        OemVendor.XIAOMI -> when (kind) {
            OemStepKind.AUTO_START -> R.string.oem_xiaomi_auto_start
            OemStepKind.BACKGROUND_ACTIVITY -> R.string.oem_xiaomi_background
            else -> R.string.oem_xiaomi_battery
        }
        OemVendor.SAMSUNG -> when (kind) {
            OemStepKind.NEVER_SLEEPING -> R.string.oem_samsung_never_sleeping
            OemStepKind.BATTERY_OPTIMISATION -> R.string.oem_samsung_battery
            else -> R.string.oem_samsung_background
        }
        OemVendor.VIVO -> when (kind) {
            OemStepKind.AUTO_START -> R.string.oem_vivo_auto_start
            OemStepKind.BACKGROUND_ACTIVITY -> R.string.oem_vivo_background
            else -> R.string.oem_vivo_battery
        }
    },
)
