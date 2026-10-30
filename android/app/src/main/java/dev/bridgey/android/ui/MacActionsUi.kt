package dev.bridgey.android.ui

import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.actions.MacActionCatalog
import dev.bridgey.android.actions.MacActionEntry
import dev.bridgey.android.actions.MacActionIds
import dev.bridgey.android.actions.MacActionKind
import dev.bridgey.android.health.DeviceHealth
import dev.bridgey.android.health.RouteClass
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import java.util.Date

/** The translated name of a fixed action, or the Mac's title for an app or a Shortcut. */
@Composable
fun macActionTitle(entry: MacActionEntry): String = when (entry.id) {
    MacActionIds.LOCK -> stringResource(R.string.action_mac_lock)
    MacActionIds.SLEEP -> stringResource(R.string.action_mac_sleep)
    MacActionIds.SCREENSAVER -> stringResource(R.string.action_mac_screensaver)
    MacActionIds.VOLUME_UP -> stringResource(R.string.action_mac_volume_up)
    MacActionIds.VOLUME_DOWN -> stringResource(R.string.action_mac_volume_down)
    MacActionIds.VOLUME_MUTE -> stringResource(R.string.action_mac_mute)
    MacActionIds.VOLUME_SET -> stringResource(R.string.mac_volume)
    else -> entry.title ?: entry.id
}

fun macActionIcon(entry: MacActionEntry): ImageVector = when (entry.id) {
    MacActionIds.LOCK -> BridgeyIcons.Lock
    MacActionIds.SLEEP -> BridgeyIcons.Bedtime
    MacActionIds.SCREENSAVER -> BridgeyIcons.Screensaver
    MacActionIds.VOLUME_UP -> BridgeyIcons.VolumeUp
    MacActionIds.VOLUME_DOWN -> BridgeyIcons.VolumeDown
    MacActionIds.VOLUME_MUTE -> BridgeyIcons.VolumeOff
    else -> if (entry.kind == MacActionKind.SHORTCUT) BridgeyIcons.Bolt else BridgeyIcons.Apps
}

/**
 * Device page: what this Mac allows the phone to run. Lock, Sleep and Screen saver, then the
 * volume, then the Mac's apps and Shortcuts as a scrolling row. An entry the Mac cannot run yet
 * (it needs a permission there) is dimmed and explained underneath.
 */
@Composable
fun MacActionsCard(
    catalog: MacActionCatalog,
    macName: String,
    running: Set<String>,
    onRun: (actionId: String, value: Int?) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = BridgeyTheme.colors
    Column(
        modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(colors.surface2)
            .padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.feature_mac_actions), style = BridgeyType.smallStrong, color = colors.onSurfaceVariant, modifier = Modifier.weight(1f))
            catalog.volume?.takeIf { catalog.volumeEntries.isNotEmpty() }?.let { volume ->
                Text(
                    if (volume.muted) stringResource(R.string.mac_volume_muted) else stringResource(R.string.mac_volume_level, volume.level),
                    style = BridgeyType.small,
                    color = colors.onSurfaceVariant,
                )
            }
        }
        if (catalog.isEmpty) {
            Text(stringResource(R.string.mac_actions_empty, macName), style = BridgeyType.itemBody, color = colors.onSurfaceVariant, modifier = Modifier.padding(horizontal = 4.dp))
            return@Column
        }
        val system = catalog.system
        if (system.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().height(56.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                system.forEach { entry ->
                    ActionButton(macActionTitle(entry), macActionIcon(entry), enabled = entry.blocked == null, running = entry.id in running, stacked = true) { onRun(entry.id, null) }
                }
            }
        }
        val stepIds = listOf(MacActionIds.VOLUME_DOWN, MacActionIds.VOLUME_MUTE, MacActionIds.VOLUME_UP).filter(catalog::has)
        if (stepIds.isNotEmpty()) {
            val muted = catalog.volume?.muted == true
            Row(Modifier.fillMaxWidth().height(48.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                stepIds.forEach { id ->
                    val entry = catalog.entry(id)!!
                    val label = when (id) {
                        MacActionIds.VOLUME_MUTE -> stringResource(if (muted) R.string.action_mac_unmute else R.string.action_mac_mute)
                        else -> macActionTitle(entry)
                    }
                    val icon = if (id == MacActionIds.VOLUME_MUTE && muted) BridgeyIcons.VolumeUp else macActionIcon(entry)
                    // Down and up are icons only (named for screen readers); Mute keeps its word.
                    ActionButton(label, icon, enabled = entry.blocked == null, running = id in running, iconOnly = id != MacActionIds.VOLUME_MUTE) { onRun(id, null) }
                }
            }
        }
        val launchers = catalog.apps + catalog.shortcuts
        if (launchers.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                launchers.forEach { entry ->
                    LauncherChip(macActionTitle(entry), macActionIcon(entry), running = entry.id in running) { onRun(entry.id, null) }
                }
            }
        }
        catalog.entries.firstOrNull { it.blocked != null }?.let { blocked ->
            Text(
                stringResource(R.string.mac_actions_blocked, macActionTitle(blocked), macName),
                style = BridgeyType.small,
                color = colors.onTintPurple,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
    }
}

@Composable
private fun RowScope.ActionButton(
    label: String,
    icon: ImageVector,
    enabled: Boolean,
    running: Boolean,
    stacked: Boolean = false,
    iconOnly: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = BridgeyTheme.colors
    val alpha = when {
        !enabled -> 0.38f
        running -> 0.6f
        else -> 1f
    }
    val base = Modifier
        .weight(1f)
        .fillMaxSize()
        .clip(RoundedCornerShape(16.dp))
        .background(colors.surface1)
        .clickable(enabled = enabled && !running, role = Role.Button, onClick = onClick)
        .padding(horizontal = 6.dp)
    if (stacked) {
        Column(base, verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, null, tint = colors.onTintPurple.copy(alpha = alpha), modifier = Modifier.size(20.dp))
            Text(label, style = BridgeyType.smallStrong, color = colors.onSurface.copy(alpha = alpha), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        return
    }
    Row(
        if (iconOnly) base.semantics { contentDescription = label } else base,
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = colors.onTintPurple.copy(alpha = alpha), modifier = Modifier.size(if (iconOnly) 22.dp else 18.dp))
        if (!iconOnly) Text(label, style = BridgeyType.label, color = colors.onSurface.copy(alpha = alpha), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun LauncherChip(label: String, icon: ImageVector, running: Boolean, onClick: () -> Unit) {
    val colors = BridgeyTheme.colors
    val alpha = if (running) 0.6f else 1f
    Row(
        Modifier
            .height(40.dp)
            .clip(RoundedCornerShape(20.dp))
            .background(colors.surface1)
            .clickable(enabled = !running, role = Role.Button, onClick = onClick)
            .padding(start = 12.dp, end = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = colors.onTintBlue.copy(alpha = alpha), modifier = Modifier.size(18.dp))
        Text(label, style = BridgeyType.chip, color = colors.onSurface.copy(alpha = alpha), maxLines = 1)
    }
}

/** A drop reason token in plain words; unknown tokens show as they are. */
@Composable
fun dropReasonText(token: String): String = when (token) {
    "heartbeat_timeout" -> stringResource(R.string.health_reason_heartbeat)
    "user_disconnect" -> stringResource(R.string.health_reason_user)
    "closed_by_peer", "reset_by_peer", "broken_pipe", "cancelled_remote" -> stringResource(R.string.health_reason_peer)
    "network_unreachable", "host_unreachable" -> stringResource(R.string.health_reason_network)
    "network_changed" -> stringResource(R.string.health_reason_network_changed)
    "timed_out", "handshake_timeout" -> stringResource(R.string.health_reason_timeout)
    "replaced", "duplicate" -> stringResource(R.string.health_reason_replaced)
    else -> stringResource(R.string.health_reason_other, token)
}

@Composable
fun routeText(route: RouteClass): String = stringResource(
    when (route) {
        RouteClass.SAME_NETWORK -> R.string.health_route_same
        RouteClass.PRIVATE_NETWORK -> R.string.health_route_private
        RouteClass.DIRECT -> R.string.health_route_direct
        RouteClass.RELAY -> R.string.health_route_relay
        RouteClass.OTHER -> R.string.health_route_other
        RouteClass.UNKNOWN -> R.string.health_route_unknown
    },
)

/** Device page > Connection: the link's health in rows, then what is kept and where. */
@Composable
fun ConnectionHealthList(health: DeviceHealth, macName: String, contentPadding: PaddingValues) {
    val context = LocalContext.current
    val time = { millis: Long -> DateFormat.getTimeFormat(context).format(Date(millis)) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = contentPadding) {
        item(key = "health") {
            RowGroup(Modifier.padding(top = 16.dp)) {
                row { shape ->
                    ListRow(shape, stringResource(R.string.health_route), routeText(health.route), BridgeyIcons.Lan,
                        if (health.connected) Tint.BLUE else Tint.NEUTRAL, compact = true)
                }
                row { shape ->
                    val since = health.connectedSinceMillis
                    val detail = when {
                        !health.connected || since == null -> stringResource(R.string.health_not_connected)
                        health.dialledHere == true -> stringResource(R.string.health_connected_since_here, time(since))
                        else -> stringResource(R.string.health_connected_since_there, time(since), macName)
                    }
                    ListRow(shape, stringResource(R.string.health_connected), detail, BridgeyIcons.Link, if (health.connected) Tint.GREEN else Tint.NEUTRAL, compact = true)
                }
                row { shape ->
                    val last = health.lastRttMillis
                    val median = health.medianRttMillis
                    val detail = if (health.connected && last != null && median != null) {
                        stringResource(R.string.health_latency_value, last.toInt(), median.toInt())
                    } else {
                        stringResource(R.string.health_latency_measuring)
                    }
                    ListRow(shape, stringResource(R.string.health_latency), detail, BridgeyIcons.Timer, Tint.PURPLE, compact = true)
                }
                row { shape ->
                    val reason = health.lastDisconnectReason
                    val at = health.lastDisconnectAtMillis
                    val detail = if (reason != null && at != null) {
                        stringResource(R.string.health_last_drop_value, dropReasonText(reason), time(at))
                    } else {
                        stringResource(R.string.health_last_drop_none)
                    }
                    ListRow(shape, stringResource(R.string.health_last_drop), detail, BridgeyIcons.WifiOff, Tint.NEUTRAL, compact = true)
                }
                row { shape ->
                    ListRow(shape, stringResource(R.string.health_reconnects), null, BridgeyIcons.Refresh, Tint.NEUTRAL, compact = true) {
                        Text(
                            health.reconnectAttemptsToday.toString(),
                            style = BridgeyType.itemTitle,
                            color = BridgeyTheme.colors.onSurface,
                            modifier = Modifier.semantics { contentDescription = health.reconnectAttemptsToday.toString() },
                        )
                        Spacer(Modifier.width(4.dp))
                    }
                }
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.health_discovery),
                        stringResource(if (health.discoverySeesNow) R.string.health_discovery_seen else R.string.health_discovery_unseen),
                        BridgeyIcons.Wifi, if (health.discoverySeesNow) Tint.BLUE else Tint.NEUTRAL, compact = true,
                    )
                }
                health.batteryOptimisationExempt?.let { exempt ->
                    row { shape ->
                        ListRow(
                            shape, stringResource(R.string.health_battery),
                            stringResource(if (exempt) R.string.health_battery_off else R.string.health_battery_on),
                            BridgeyIcons.Battery5Bar, if (exempt) Tint.GREEN else Tint.PURPLE, compact = true, detailWarning = !exempt,
                        )
                    }
                }
            }
        }
        item(key = "health.note") {
            Note(stringResource(R.string.health_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 12.dp))
        }
    }
}
