package dev.bridgey.android.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import dev.bridgey.android.R
import dev.bridgey.android.connect.ConnectRoute

/** Where Connect anywhere is, in the words the page uses. */
enum class ConnectState { OFF, UNAVAILABLE, LOCAL_ONLY, CONNECTING, UNREACHABLE, ONLINE }

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

/** Where Connect anywhere stands, in words, with the tint for its status row. */
@Composable
internal fun connectStatusText(connect: ConnectSettingsState): Pair<String, Tint> = when (connect.state) {
    ConnectState.ONLINE -> (
        if (connect.reachable > 0) pluralStringResource(R.plurals.connect_status_online_devices, connect.reachable, connect.reachable)
        else stringResource(R.string.connect_status_online)
        ) to Tint.GREEN
    ConnectState.CONNECTING -> stringResource(R.string.connect_status_connecting) to Tint.BLUE
    ConnectState.UNREACHABLE -> stringResource(R.string.connect_status_unreachable) to Tint.NEUTRAL
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
    connect.state == ConnectState.UNREACHABLE -> stringResource(R.string.connect_summary_unreachable)
    else -> stringResource(R.string.connect_status_connecting)
}

/** A connected device's route in plain words: Same Wi-Fi, Private network, Direct, or the relay's city. */
@Composable
fun connectRouteLabel(route: ConnectRoute): String = when (route.route) {
    "lan" -> stringResource(R.string.ring_same_wifi)
    "vpn" -> stringResource(if (route.vpn == "tailscale") R.string.route_tailscale else R.string.route_private_network)
    "direct" -> stringResource(R.string.route_direct)
    else -> when (route.relay) {
        "bom" -> stringResource(R.string.route_relay_named, stringResource(R.string.relay_city_bom))
        "sin" -> stringResource(R.string.route_relay_named, stringResource(R.string.relay_city_sin))
        "sxb" -> stringResource(R.string.route_relay_named, stringResource(R.string.relay_city_sxb))
        else -> stringResource(R.string.route_relay)
    }
}
