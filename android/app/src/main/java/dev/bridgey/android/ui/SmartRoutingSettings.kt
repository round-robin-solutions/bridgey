package dev.bridgey.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.routing.RoutingReason

/** Notification fallback is an explicit preference, separate from each share's deliberate choice. */
data class PreferredRoutingDevice(val id: String, val name: String)
data class SmartRoutingSettingsState(
    val enabled: Boolean = true,
    val preferredId: String? = null,
    val devices: List<PreferredRoutingDevice> = emptyList(),
    val destinationId: String? = null,
    val reason: RoutingReason = RoutingReason.PHONE_ONLY,
)
class SmartRoutingSettingsActions(
    val setEnabled: (Boolean) -> Unit = {},
    val setPreferred: (String?) -> Unit = {},
)

@Composable
fun SmartRoutingSettings(state: SmartRoutingSettingsState, actions: SmartRoutingSettingsActions) {
    var choosing by remember { mutableStateOf(false) }
    val preferredName = state.devices.firstOrNull { it.id == state.preferredId }?.name
    val destinationName = state.devices.firstOrNull { it.id == state.destinationId }?.name
    val status = when {
        !state.enabled -> stringResource(R.string.smart_routing_all_status)
        state.reason == RoutingReason.ACTIVE && destinationName != null -> stringResource(R.string.smart_routing_active_status, destinationName)
        state.reason == RoutingReason.PREFERRED && destinationName != null -> stringResource(R.string.smart_routing_preferred_status, destinationName)
        else -> stringResource(R.string.smart_routing_phone_status)
    }
    RowGroup {
        row { shape -> SwitchRow(shape, stringResource(R.string.smart_routing_title), stringResource(R.string.smart_routing_detail),
            BridgeyIcons.Notifications, Tint.PURPLE, state.enabled, actions.setEnabled) }
        row { shape -> ListRow(shape, stringResource(R.string.smart_routing_preferred),
            preferredName ?: stringResource(R.string.smart_routing_none), BridgeyIcons.LaptopMac, Tint.BLUE,
            onClick = { choosing = true }) { Text(stringResource(R.string.smart_routing_change)) } }
        row { shape -> ListRow(shape, stringResource(R.string.smart_routing_status), status,
            BridgeyIcons.Notifications, Tint.NEUTRAL, searchable = false) }
    }
    if (choosing) {
        AlertDialog(
            onDismissRequest = { choosing = false },
            title = { Text(stringResource(R.string.smart_routing_preferred)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    DeviceDestinationList(
                        choices = listOf(DeviceDestination("", stringResource(R.string.smart_routing_none_option), true, stringResource(R.string.smart_routing_none))) +
                            state.devices.map { DeviceDestination(it.id, it.name, true, "") },
                        selectedId = state.preferredId ?: "",
                        onSelect = { actions.setPreferred(it.takeIf(String::isNotEmpty)); choosing = false },
                        showHeading = false,
                    )
                }
            },
            confirmButton = { TextButton(onClick = { choosing = false }) { Text(stringResource(R.string.action_close)) } },
        )
    }
}
