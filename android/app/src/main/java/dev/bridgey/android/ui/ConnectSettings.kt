package dev.bridgey.android.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.connect.ConnectRoute

/** Where Connect anywhere is, in the words the page uses. */
enum class ConnectState { OFF, UNAVAILABLE, LOCAL_ONLY, CONNECTING, ONLINE }

/** Settings > Connect away from home. */
data class ConnectSettingsState(
    val on: Boolean = false,
    val state: ConnectState = ConnectState.OFF,
    /** Paired devices the Round Robin service sees online right now. */
    val reachable: Int = 0,
)

class ConnectSettingsActions(
    val setOn: (Boolean) -> Unit = {},
    val resetIdentity: () -> Unit = {},
)

/**
 * Connect away from home: the switch, where it stands, what it does in plain words, and the
 * identity reset. Off until chosen (the edition's rule).
 */
@Composable
internal fun ConnectAwayPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    var confirmReset by rememberSaveable { mutableStateOf(false) }
    val connect = state.connect
    SettingsPage(stringResource(R.string.settings_connect_away), actions.back, listState) {
        item(key = "connect.switch") {
            RowGroup(Modifier.padding(top = 20.dp)) {
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.settings_connect_away), stringResource(R.string.connect_away_detail),
                        BridgeyIcons.Public, if (connect.on) Tint.BLUE else Tint.NEUTRAL,
                        connect.on && connect.state != ConnectState.UNAVAILABLE, actions.connect.setOn,
                        enabled = connect.state != ConnectState.UNAVAILABLE,
                    )
                }
                if (connect.on) {
                    row { shape ->
                        val (text, tint) = connectStatusText(connect)
                        ListRow(shape, stringResource(R.string.connect_status), text, BridgeyIcons.Cloud, tint, compact = true)
                    }
                }
            }
        }
        item(key = "connect.how") {
            Note(stringResource(R.string.connect_how), Modifier.padding(start = 20.dp, end = 20.dp, top = 16.dp))
        }
        if (connect.on && connect.state != ConnectState.UNAVAILABLE) {
            item(key = "connect.reset") {
                RowGroup(Modifier.padding(top = 24.dp)) {
                    row { shape ->
                        ListRow(
                            shape, stringResource(R.string.connect_reset), stringResource(R.string.connect_reset_detail),
                            BridgeyIcons.Refresh, Tint.NEUTRAL, onClick = { confirmReset = true },
                        )
                    }
                }
            }
        }
    }
    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            title = { Text(stringResource(R.string.connect_reset_confirm_title)) },
            text = { Text(stringResource(R.string.connect_reset_confirm_body)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmReset = false
                    actions.connect.resetIdentity()
                }) { Text(stringResource(R.string.connect_reset_confirm)) }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

@Composable
private fun connectStatusText(connect: ConnectSettingsState): Pair<String, Tint> = when (connect.state) {
    ConnectState.ONLINE -> (
        if (connect.reachable > 0) pluralStringResource(R.plurals.connect_status_online_devices, connect.reachable, connect.reachable)
        else stringResource(R.string.connect_status_online)
        ) to Tint.GREEN
    ConnectState.CONNECTING -> stringResource(R.string.connect_status_connecting) to Tint.BLUE
    ConnectState.LOCAL_ONLY -> stringResource(R.string.connect_status_local) to Tint.BLUE
    ConnectState.UNAVAILABLE -> stringResource(R.string.connect_status_unavailable) to Tint.NEUTRAL
    ConnectState.OFF -> stringResource(R.string.connect_status_off) to Tint.NEUTRAL
}

/** The home row's summary. */
@Composable
internal fun connectSummary(connect: ConnectSettingsState): String = when {
    connect.state == ConnectState.UNAVAILABLE -> stringResource(R.string.connect_status_unavailable)
    !connect.on -> stringResource(R.string.connect_summary_off)
    connect.state == ConnectState.ONLINE -> stringResource(R.string.connect_summary_on)
    else -> stringResource(R.string.connect_status_connecting)
}

/** A connected device's route in plain words: Same Wi-Fi, Private network, Direct, or the relay's city. */
@Composable
fun connectRouteLabel(route: ConnectRoute): String = when (route.route) {
    "lan" -> stringResource(R.string.ring_same_wifi)
    "vpn" -> stringResource(R.string.route_private_network)
    "direct" -> stringResource(R.string.route_direct)
    else -> when (route.relay) {
        "bom" -> stringResource(R.string.route_relay_named, stringResource(R.string.relay_city_bom))
        "sin" -> stringResource(R.string.route_relay_named, stringResource(R.string.relay_city_sin))
        "sxb" -> stringResource(R.string.route_relay_named, stringResource(R.string.relay_city_sxb))
        else -> stringResource(R.string.route_relay)
    }
}
