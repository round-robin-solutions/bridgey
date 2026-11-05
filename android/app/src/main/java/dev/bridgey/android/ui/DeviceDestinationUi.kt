package dev.bridgey.android.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Text
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.PairingCoordinator
import dev.bridgey.android.R
import dev.bridgey.android.routing.RoutingReason
import dev.bridgey.android.ui.motion.selectionPop
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** A named destination stays in the list when it is offline; availability never changes its identity. */
data class DeviceDestination(
    val deviceId: String,
    val name: String,
    val available: Boolean,
    val detail: String,
    val suggested: Boolean = false,
)

/** A recommendation orders rows; it never replaces a deliberate choice or authorizes a send. */
object DeviceDestinationSelection {
    fun ordered(choices: List<DeviceDestination>): List<DeviceDestination> =
        choices.sortedByDescending { it.suggested }

    fun selected(choices: List<DeviceDestination>, selectedId: String?): DeviceDestination? =
        choices.firstOrNull { it.deviceId == selectedId }

    fun canSend(choices: List<DeviceDestination>, selectedId: String?): Boolean =
        selected(choices, selectedId)?.available == true
}

/** Call from a surface observing connections, trustedDevices, settings and presenceRevision. */
fun destinationChoices(context: Context, pairing: PairingCoordinator, feature: BridgeyFeature): List<DeviceDestination> {
    val connected = pairing.connections.value.associateBy { it.deviceId }
    val suggestion = pairing.suggestedDevice(feature)
    return DeviceDestinationSelection.ordered(pairing.trustedDevices.value.filterNot { it.isAgent }.map { device ->
        val available = connected.containsKey(device.id) && pairing.isFeatureAvailable(feature, device.id)
        val suggested = available && suggestion.deviceId == device.id
        val detail = when {
            !connected.containsKey(device.id) -> context.getString(R.string.destination_offline)
            !available -> context.getString(R.string.destination_feature_off)
            suggested && suggestion.reason == RoutingReason.ACTIVE -> context.getString(R.string.destination_active)
            suggested && suggestion.reason == RoutingReason.PREFERRED -> context.getString(R.string.destination_preferred)
            else -> pairing.deviceActivityLabel(device.id) ?: context.getString(R.string.destination_connected)
        }
        DeviceDestination(device.id, device.name, available, detail, suggested)
    })
}

@Composable
fun DeviceDestinationList(
    choices: List<DeviceDestination>,
    selectedId: String?,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
    showHeading: Boolean = true,
) {
    val colors = BridgeyTheme.colors
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (showHeading) Text(stringResource(R.string.destination_choose), style = BridgeyType.label, color = colors.onSurface)
        if (choices.isEmpty()) {
            Text(stringResource(R.string.destination_none), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
        } else {
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 280.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                items(choices, key = { it.deviceId }) { choice ->
                    val selected = choice.deviceId == selectedId
                    Row(
                        Modifier.fillMaxWidth()
                            .clip(groupShape(choices.indexOf(choice), choices.size, outer = 16.dp, inner = 4.dp))
                            .background(colors.surface2)
                            .selectable(selected, enabled = choice.available, role = Role.RadioButton) { onSelect(choice.deviceId) }
                            .heightIn(min = 60.dp)
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Box(Modifier.size(20.dp).selectionPop(selected).clip(CircleShape)
                            .background(if (selected) colors.primary else colors.outline), contentAlignment = Alignment.Center) {
                            Box(Modifier.size(if (selected) 8.dp else 16.dp).clip(CircleShape)
                                .background(if (selected) colors.onPrimary else colors.surface2))
                        }
                        Column(Modifier.weight(1f)) {
                            Text(choice.name, style = BridgeyType.itemTitle,
                                color = if (choice.available) colors.onSurface else colors.onSurfaceVariant,
                                maxLines = 2, overflow = TextOverflow.Ellipsis)
                            if (choice.detail.isNotBlank()) Text(choice.detail, style = BridgeyType.small, color = colors.onSurfaceVariant,
                                maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                        if (choice.suggested) Text(stringResource(R.string.destination_suggested),
                            style = BridgeyType.tinyLabel, color = colors.primary)
                    }
                }
            }
        }
    }
}
