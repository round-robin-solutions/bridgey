package dev.bridgey.android.ui

import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.style.Hyphens
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.R
import dev.bridgey.android.RemoteBatteryStatus
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.SpringTabIndicator
import dev.bridgey.android.ui.motion.springIn
import dev.bridgey.android.ui.motion.tabContentTransform
import dev.bridgey.android.ui.theme.Aurora
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.OnBand
import dev.bridgey.android.ui.theme.ScreenBackdrop
import java.util.TimeZone
import dev.bridgey.android.ui.search.settingsSearchScroll

/** One per-device permission row. Find and Ping share a row, as in the design. */
data class PermissionRow(
    val features: List<BridgeyFeature>,
    val checked: Boolean,
    /** Off for every device in Settings: the switch is shown off and disabled. */
    val globallyOff: Boolean,
    /** Turned off on the other device. */
    val remotelyOff: Boolean,
)

data class DeviceState(
    val ring: DeviceRing,
    val battery: RemoteBatteryStatus?,
    val connected: Boolean,
    /** Features usable with this device right now (on both sides and connected). */
    val available: Set<BridgeyFeature>,
    val ringing: Boolean,
    val permissions: List<PermissionRow>,
    val notificationAccess: Boolean,
    val notificationAppsEnabled: Int,
    /** Automatic clipboard for this device (global and per-device both on). */
    val autoClipboard: Boolean,
    /** The global Automatic clipboard switch is on, so the per-device one is worth showing. */
    val autoClipboardGlobalOn: Boolean,
    val activity: List<ActivityItem>,
    val live: List<LiveCard>,
    val now: Long,
    /** What this Mac lets the phone run, while Mac actions is available with it; null hides the card. */
    val macActions: dev.bridgey.android.actions.MacActionCatalog? = null,
    /** Mac action identifiers waiting for the Mac's answer. */
    val runningActions: Set<String> = emptySet(),
    /** The Connection tab. */
    val health: dev.bridgey.android.health.DeviceHealth? = null,
    /** Screen sharing with this Mac, while it is asked for, starting or running; null otherwise. */
    val screen: dev.bridgey.android.screen.ScreenShareState? = null,
    /** Settings sync with this device; null hides the row. */
    val sync: DeviceSyncState? = null,
)

/** "Sync settings with this device": this side's switch, the global switch, and the other side's. */
data class DeviceSyncState(val on: Boolean, val globalOn: Boolean, val offRemote: Boolean)

class DeviceActions(
    val back: () -> Unit = {},
    val forget: () -> Unit = {},
    /** Disconnects this Mac until the user connects again. */
    val disconnect: () -> Unit = {},
    /** Connects again to a Mac the user disconnected. */
    val connect: () -> Unit = {},
    val sendFile: () -> Unit = {},
    val sendLink: () -> Unit = {},
    val ping: () -> Unit = {},
    val find: () -> Unit = {},
    val stopFind: () -> Unit = {},
    val setPermission: (List<BridgeyFeature>, Boolean) -> Unit = { _, _ -> },
    val setAutoClipboard: (Boolean) -> Unit = {},
    val notificationAccess: () -> Unit = {},
    val sendClipboard: () -> Unit = {},
    val sendText: (String) -> Unit = {},
    /** Opens the touchpad and presentation remote for this Mac. */
    val remoteControl: () -> Unit = {},
    /** Opens this Mac's screen on the phone (Mac screen to phone). */
    val seeScreen: () -> Unit = {},
    /** Opens Android's consent dialog to share this phone's screen with this Mac. */
    val shareScreen: () -> Unit = {},
    val stopScreen: () -> Unit = {},
    /** Runs one Mac action; the value only for volume_set. */
    val runMacAction: (String, Int?) -> Unit = { _, _ -> },
    val setSync: (Boolean) -> Unit = {},
    /** Opens the Settings card that holds one of this device's choices, at its chip. */
    val openChoice: (DeviceChoice) -> Unit = {},
    val live: LiveActions = LiveActions(),
)

/** Light mode band: status bar + 56 dp bar + 88 dp header + 16 dp. */
private val DeviceBand = 160.dp

enum class DeviceTab { ACTIVITY, PERMISSIONS, CONNECTION }

/**
 * Device: who it is and how it is connected, four quick actions as one button group, the Mac's
 * actions when it allows them, then its Activity (this device's part of the stream), Permissions
 * and Connection (health). The send bar stays, aimed here.
 */
@Composable
fun DeviceScreen(
    state: DeviceState,
    actions: DeviceActions,
    snackbar: SnackbarHostState,
    deviceName: (ActivityItem) -> String,
    initialTab: DeviceTab = DeviceTab.ACTIVITY,
) {
    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val navBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    var tab by rememberSaveable { mutableStateOf(initialTab) }
    val motion = LocalMotion.current
    ScreenBackdrop(bandHeight = statusTop + DeviceBand) {
        Column(Modifier.fillMaxSize()) {
            OnBand {
                Column {
                    DeviceBar(state, actions)
                    DeviceHeader(state)
                }
            }
            QuickActionGroup(state, actions, Modifier.padding(top = 24.dp))
            // Only while both devices allow it: this Mac granted this phone, and it is on here.
            if (BridgeyFeature.REMOTE_INPUT in state.available) {
                RemoteControlEntry(actions.remoteControl, Modifier.padding(top = 8.dp))
            }
            // Only while both allow it: See Mac screens here, and this Mac lets the phone see its screen.
            if (BridgeyFeature.SCREEN_CONTROL in state.available) {
                MacScreenEntry(state.ring.name, actions.seeScreen, Modifier.padding(top = 8.dp))
            }
            // Only while both devices allow it: Share screen with Macs here, Show phone screens on the Mac.
            if (BridgeyFeature.SCREEN in state.available || state.screen?.active == true) {
                ScreenShareEntry(state, actions, Modifier.padding(top = 8.dp))
            }
            // Only while this Mac allows the phone and sent its list in this session.
            state.macActions?.takeIf { BridgeyFeature.MAC_ACTIONS in state.available }?.let { catalog ->
                MacActionsCard(catalog, state.ring.name, state.runningActions, actions.runMacAction, Modifier.padding(top = 8.dp))
            }
            DeviceTabs(tab, onTab = { tab = it }, modifier = Modifier.padding(top = 16.dp))
            AnimatedContent(
                targetState = tab,
                transitionSpec = { motion.tabContentTransform(forward = targetState.ordinal > initialState.ordinal) },
                label = "deviceTab",
                modifier = Modifier.weight(1f),
            ) { shown ->
                val bottom = 64.dp + 12.dp + navBottom + 24.dp
                when (shown) {
                    DeviceTab.ACTIVITY -> {
                        val rows = remember(state.activity, state.ring.deviceId, state.now) {
                            streamRows(state.activity, StreamFilter.ALL, state.ring.deviceId ?: "", state.now, TimeZone.getDefault())
                        }
                        StreamList(
                            rows = rows,
                            live = state.live,
                            liveActions = actions.live,
                            deviceName = deviceName,
                            now = state.now,
                            state = rememberLazyListState(),
                            contentPadding = PaddingValues(bottom = bottom),
                            empty = { StreamEmpty(stringResource(R.string.device_activity_empty_title), stringResource(R.string.device_activity_empty_body, state.ring.name)) },
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                    DeviceTab.PERMISSIONS -> PermissionsList(state, actions, PaddingValues(bottom = bottom))
                    DeviceTab.CONNECTION -> state.health?.let { ConnectionHealthList(it, state.ring.name, PaddingValues(bottom = bottom)) }
                }
            }
        }
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(bottom = 12.dp)) {
            SnackbarHost(snackbar, Modifier.padding(horizontal = 16.dp)) { data ->
                Snackbar(data, Modifier.springIn(), containerColor = BridgeyTheme.colors.onSurface, contentColor = BridgeyTheme.colors.background, shape = RoundedCornerShape(16.dp))
            }
            DeviceComposer(state, actions)
        }
    }
}

@Composable
private fun DeviceBar(state: DeviceState, actions: DeviceActions) {
    var menu by remember { mutableStateOf(false) }
    PageBar(title = null, onBack = actions.back) {
        Box {
            BarIconButton(BridgeyIcons.MoreVert, stringResource(R.string.device_more), { menu = true })
            DropdownMenu(
                expanded = menu,
                onDismissRequest = { menu = false },
                modifier = Modifier.springIn(),
                containerColor = BridgeyTheme.colors.surface2,
                shape = RoundedCornerShape(16.dp),
            ) {
                if (state.connected) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.device_disconnect, state.ring.name)) },
                        leadingIcon = { Icon(BridgeyIcons.PowerSettingsNew, null) },
                        onClick = {
                            menu = false
                            actions.disconnect()
                        },
                    )
                } else if (state.ring.reconnect?.disconnectedByUser == true) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.device_connect, state.ring.name)) },
                        leadingIcon = { Icon(BridgeyIcons.Link, null) },
                        onClick = {
                            menu = false
                            actions.connect()
                        },
                    )
                }
                if (state.ring.trusted) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.device_forget, state.ring.name), color = BridgeyTheme.colors.warn) },
                        leadingIcon = { Icon(BridgeyIcons.Delete, null, tint = BridgeyTheme.colors.warn) },
                        onClick = {
                            menu = false
                            actions.forget()
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun DeviceHeader(state: DeviceState) {
    val colors = BridgeyTheme.colors
    Row(
        Modifier.fillMaxWidth().height(88.dp).padding(horizontal = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        DeviceGlyph(state.ring.state.style(), deviceIcon(state.ring.platform), 64.dp)
        Column(Modifier.weight(1f)) {
            Text(
                state.ring.name,
                style = BridgeyType.deviceName,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.semantics { heading() },
            )
            Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                RoutePill(state.ring.state, ringStatusLabel(state.ring), state.ring.route)
                state.battery?.let { battery ->
                    val description = stringResource(
                        if (battery.isCharging) R.string.device_battery_charging else R.string.device_battery,
                        battery.level,
                    )
                    Row(
                        Modifier.semantics(mergeDescendants = true) { contentDescription = description },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Icon(
                            if (battery.isCharging) BridgeyIcons.BatteryChargingFull else BridgeyIcons.Battery5Bar,
                            null,
                            tint = colors.onSurfaceVariant,
                            modifier = Modifier.size(16.dp),
                        )
                        Text(
                            java.text.NumberFormat.getPercentInstance(LocalConfiguration.current.locales[0]).format(battery.level / 100.0),
                            style = BridgeyType.itemBody, color = colors.onSurfaceVariant, modifier = Modifier.clearAndSetSemantics {},
                        )
                    }
                }
            }
        }
    }
}

/** File, Link, Ping, Find as one connected button group. 48 dp tall so each is easy to hit. */
@Composable
private fun QuickActionGroup(state: DeviceState, actions: DeviceActions, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    val findOn = BridgeyFeature.FIND_DEVICE in state.available
    data class Action(val label: String, val icon: ImageVector, val enabled: Boolean, val onClick: () -> Unit)
    val items = listOf(
        Action(stringResource(R.string.action_file), BridgeyIcons.AttachFile, BridgeyFeature.FILES in state.available, actions.sendFile),
        Action(stringResource(R.string.action_link), BridgeyIcons.Link, BridgeyFeature.LINKS in state.available, actions.sendLink),
        Action(stringResource(R.string.action_ping), BridgeyIcons.Sensors, BridgeyFeature.PING in state.available, actions.ping),
        if (state.ringing) {
            Action(stringResource(R.string.action_stop), BridgeyIcons.Close, true, actions.stopFind)
        } else {
            Action(stringResource(R.string.action_find), BridgeyIcons.MyLocation, findOn, actions.find)
        },
    )
    // One row of four; with large text two rows of two, so every label stays whole.
    val large = largeText()
    val lines = if (large) items.chunked(2) else listOf(items)
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
      lines.forEachIndexed { line, lineItems ->
        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).heightIn(min = 48.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        lineItems.forEachIndexed { index, item ->
            val first = index == 0
            val last = index == lineItems.lastIndex
            val top = line == 0
            val bottom = line == lines.lastIndex
            val shape = RoundedCornerShape(
                topStart = if (first && top) 24.dp else 6.dp,
                topEnd = if (last && top) 24.dp else 6.dp,
                bottomStart = if (first && bottom) 24.dp else 6.dp,
                bottomEnd = if (last && bottom) 24.dp else 6.dp,
            )
            Row(
                Modifier
                    .weight(1f)
                    .fillMaxSize()
                    .clip(shape)
                    .background(colors.surface2)
                    .clickable(enabled = item.enabled, role = Role.Button, onClick = item.onClick),
                horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val alpha = if (item.enabled) 1f else 0.38f
                Icon(item.icon, null, tint = colors.onTintBlue.copy(alpha = alpha), modifier = Modifier.size(18.dp))
                Text(
                    item.label, style = BridgeyType.label, color = colors.onSurface.copy(alpha = alpha), maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(vertical = if (large) 8.dp else 0.dp),
                )
            }
        }
        }
      }
    }
}

@Composable
private fun RemoteControlEntry(onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier.padding(horizontal = 16.dp)) {
        ListRow(
            shape = RoundedCornerShape(24.dp),
            title = stringResource(R.string.remote_entry_title),
            detail = stringResource(R.string.remote_entry_detail),
            icon = BridgeyIcons.Mouse,
            tint = Tint.BLUE,
            compact = true,
            onClick = onClick,
            role = Role.Button,
            searchable = false,
        ) { Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant) }
    }
}

/** See screen: this Mac's screen on the phone, in its own viewer. */
@Composable
private fun MacScreenEntry(macName: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier.padding(horizontal = 16.dp)) {
        ListRow(
            shape = RoundedCornerShape(24.dp),
            title = stringResource(R.string.display_entry_title),
            detail = stringResource(R.string.display_entry_detail, macName),
            icon = BridgeyIcons.DesktopMac,
            tint = Tint.BLUE,
            compact = true,
            onClick = onClick,
            role = Role.Button,
            searchable = false,
        ) { Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant) }
    }
}

/** Share screen, or the running share with its Stop: Android asks for consent each time. */
@Composable
private fun ScreenShareEntry(state: DeviceState, actions: DeviceActions, modifier: Modifier = Modifier) {
    val screen = state.screen?.takeIf { it.active }
    val colors = BridgeyTheme.colors
    Box(modifier.padding(horizontal = 16.dp)) {
        if (screen == null) {
            ListRow(
                shape = RoundedCornerShape(24.dp),
                title = stringResource(R.string.screen_entry_title),
                detail = stringResource(R.string.screen_entry_detail, state.ring.name),
                icon = BridgeyIcons.ScreenShare,
                tint = Tint.PURPLE,
                compact = true,
                onClick = actions.shareScreen,
                role = Role.Button,
                searchable = false,
            ) { Icon(BridgeyIcons.ChevronRight, null, tint = colors.onSurfaceVariant) }
        } else {
            val stats = screen.stats
            val detail = when {
                screen.phase != dev.bridgey.android.screen.ScreenShareState.Phase.SHARING -> stringResource(R.string.screen_entry_starting, state.ring.name)
                stats != null -> stringResource(R.string.screen_entry_sharing, state.ring.name) + "\n" +
                    stringResource(R.string.screen_entry_stats, stats.latencyMs.toInt(), screenBitrateText(LocalContext.current, stats.sentBitrate), stats.fps)
                else -> stringResource(R.string.screen_entry_sharing, state.ring.name)
            }
            ListRow(
                shape = RoundedCornerShape(24.dp),
                title = stringResource(R.string.screen_entry_stop),
                detail = detail,
                icon = BridgeyIcons.StopCircle,
                tint = Tint.PURPLE,
                compact = true,
                onClick = actions.stopScreen,
                role = Role.Button,
                searchable = false,
            ) { Icon(BridgeyIcons.Close, null, tint = colors.onSurfaceVariant) }
        }
    }
}

/** 2.1 Mb/s, 850 kb/s (2,1 Мбит/с in Russian): the phone's language and decimal mark. */
internal fun screenBitrateText(context: android.content.Context, bitsPerSecond: Long): String =
    if (bitsPerSecond >= 1_000_000) {
        val number = java.text.NumberFormat.getNumberInstance(context.resources.configuration.locales[0]).apply { maximumFractionDigits = 1; minimumFractionDigits = 1 }
        context.getString(R.string.screen_bitrate_mbps, number.format(bitsPerSecond / 1_000_000.0))
    } else {
        context.getString(R.string.screen_bitrate_kbps, (bitsPerSecond / 1000).toInt())
    }

@Composable
private fun DeviceTabs(tab: DeviceTab, onTab: (DeviceTab) -> Unit, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    // 48 dp, taller when large text wraps a label.
    Box(modifier.fillMaxWidth().height(IntrinsicSize.Min).heightIn(min = 48.dp)) {
        Row(Modifier.fillMaxSize().padding(horizontal = 8.dp)) {
            DeviceTab.entries.forEach { entry ->
                val selected = entry == tab
                Box(
                    Modifier.weight(1f).fillMaxSize().selectable(selected = selected, role = Role.Tab) { onTab(entry) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        stringResource(
                            when (entry) {
                                DeviceTab.ACTIVITY -> R.string.device_tab_activity
                                DeviceTab.PERMISSIONS -> R.string.device_tab_permissions
                                DeviceTab.CONNECTION -> R.string.device_tab_connection
                            },
                        ),
                        // Large text in a narrow tab: break long words with a hyphen.
                        style = BridgeyType.label.copy(hyphens = Hyphens.Auto),
                        color = if (selected) colors.onSurface else colors.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 12.dp),
                    )
                }
            }
        }
        Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(1.dp).background(colors.outlineVariant))
        SpringTabIndicator(
            selected = tab.ordinal,
            count = DeviceTab.entries.size,
            brush = Aurora.ringHorizontal(),
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 8.dp),
        )
    }
}

/**
 * What this phone shares with the device, one row per choice. Each choice lives in its feature's card in Settings
 * (the Devices chips, since 26 Nov 2026), so a row opens that card at this device's chip.
 */
@Composable
private fun PermissionsList(state: DeviceState, actions: DeviceActions, contentPadding: PaddingValues) {
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    LazyColumn(
        Modifier.fillMaxSize().settingsSearchScroll(listState),
        state = listState,
        contentPadding = contentPadding,
    ) {
        item(key = "intro") {
            Note(stringResource(R.string.device_permissions_intro, state.ring.name), Modifier.padding(start = 20.dp, end = 20.dp, top = 16.dp))
        }
        item(key = "group") {
            RowGroup(Modifier.padding(top = 12.dp)) {
                state.permissions.forEach { permission ->
                    val feature = permission.features.first()
                    val choice = DeviceChoices.firstOrNull { it.features == permission.features && !it.more } ?: return@forEach
                    row { shape ->
                        val (icon, tint) = permissionVisual(feature)
                        val on = permission.checked && !permission.globallyOff && !permission.remotelyOff
                        val needsAccess = feature == BridgeyFeature.NOTIFICATIONS && !state.notificationAccess && permission.checked
                        val detail = when {
                            permission.globallyOff -> stringResource(R.string.permission_off_everywhere)
                            permission.remotelyOff -> stringResource(R.string.permission_off_remote, state.ring.name)
                            needsAccess -> stringResource(R.string.permission_needs_notification_access)
                            on -> stringResource(R.string.settings_summary_on)
                            else -> stringResource(R.string.settings_summary_off)
                        }
                        ListRow(
                            shape = shape,
                            title = permissionTitle(feature),
                            detail = detail,
                            icon = icon,
                            tint = if (on) tint else Tint.NEUTRAL,
                            compact = true,
                            detailWarning = permission.remotelyOff || permission.globallyOff || needsAccess,
                            onClick = { actions.openChoice(choice) },
                            onClickLabel = stringResource(R.string.device_permissions_change),
                            // A way to the setting's one home, not a setting: search offers the chip instead.
                            searchable = false,
                        ) { Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant) }
                    }
                }
                state.sync?.let { sync ->
                    row { shape ->
                        val shown = sync.on && sync.globalOn && !sync.offRemote
                        ListRow(
                            shape = shape,
                            title = stringResource(R.string.devices_sync_title),
                            detail = when {
                                !sync.globalOn -> stringResource(R.string.permission_off_everywhere)
                                sync.on && sync.offRemote -> stringResource(R.string.permission_off_remote, state.ring.name)
                                shown -> stringResource(R.string.settings_summary_on)
                                else -> stringResource(R.string.settings_summary_off)
                            },
                            icon = BridgeyIcons.Sync,
                            tint = if (shown) Tint.BLUE else Tint.NEUTRAL,
                            compact = true,
                            detailWarning = !sync.globalOn || (sync.on && sync.offRemote),
                            onClick = { actions.openChoice(DeviceChoices.first { it.card == SettingsCard.SYNC }) },
                            onClickLabel = stringResource(R.string.device_permissions_change),
                            searchable = false,
                        ) { Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant) }
                    }
                }
            }
        }
    }
}

fun permissionVisual(feature: BridgeyFeature): Pair<ImageVector, Tint> = when (feature) {
    BridgeyFeature.CLIPBOARD -> BridgeyIcons.ContentPaste to Tint.BLUE
    BridgeyFeature.FILES -> BridgeyIcons.Folder to Tint.GREEN
    BridgeyFeature.NOTIFICATIONS -> BridgeyIcons.Notifications to Tint.PURPLE
    BridgeyFeature.CALLS -> BridgeyIcons.Call to Tint.GREEN
    BridgeyFeature.MEDIA -> BridgeyIcons.MusicNote to Tint.BLUE
    BridgeyFeature.FIND_DEVICE, BridgeyFeature.PING -> BridgeyIcons.Sensors to Tint.BLUE
    BridgeyFeature.LINKS -> BridgeyIcons.Link to Tint.BLUE
    BridgeyFeature.BATTERY -> BridgeyIcons.Battery5Bar to Tint.GREEN
    BridgeyFeature.REMOTE_INPUT -> BridgeyIcons.Mouse to Tint.PURPLE
    BridgeyFeature.MAC_ACTIONS -> BridgeyIcons.Lock to Tint.PURPLE
    BridgeyFeature.CAMERA -> BridgeyIcons.PhotoCamera to Tint.GREEN
    BridgeyFeature.SCREEN -> BridgeyIcons.ScreenShare to Tint.PURPLE
    BridgeyFeature.SMS -> BridgeyIcons.Sms to Tint.GREEN
    BridgeyFeature.CALL_QUIET -> BridgeyIcons.MusicNote to Tint.BLUE
    BridgeyFeature.DIALER -> BridgeyIcons.Call to Tint.GREEN
    BridgeyFeature.SCREEN_CONTROL -> BridgeyIcons.DesktopMac to Tint.BLUE
}

@Composable
fun permissionTitle(feature: BridgeyFeature): String = stringResource(
    when (feature) {
        BridgeyFeature.CLIPBOARD -> R.string.feature_clipboard
        BridgeyFeature.FILES -> R.string.feature_files
        BridgeyFeature.NOTIFICATIONS -> R.string.feature_notifications
        BridgeyFeature.CALLS -> R.string.feature_calls
        BridgeyFeature.MEDIA -> R.string.feature_media
        BridgeyFeature.FIND_DEVICE, BridgeyFeature.PING -> R.string.feature_find_ping
        BridgeyFeature.LINKS -> R.string.feature_links
        BridgeyFeature.BATTERY -> R.string.feature_battery
        BridgeyFeature.REMOTE_INPUT -> R.string.feature_remote_input
        BridgeyFeature.MAC_ACTIONS -> R.string.feature_mac_actions
        BridgeyFeature.CAMERA -> R.string.feature_camera
        BridgeyFeature.SCREEN -> R.string.feature_screen
        BridgeyFeature.SMS -> R.string.feature_sms
        BridgeyFeature.CALL_QUIET -> R.string.call_quiet_title
        BridgeyFeature.DIALER -> R.string.dialer_title
        BridgeyFeature.SCREEN_CONTROL -> R.string.feature_screen_control
    },
)

/** The device page's send bar: attach a file, type a message or leave it empty to send the clipboard. */
@Composable
private fun DeviceComposer(state: DeviceState, actions: DeviceActions) {
    val colors = BridgeyTheme.colors
    var text by rememberSaveable { mutableStateOf("") }
    val canSend = BridgeyFeature.CLIPBOARD in state.available
    val send = {
        if (text.isBlank()) actions.sendClipboard() else actions.sendText(text)
        text = ""
    }
    val hint = stringResource(if (canSend) R.string.composer_clipboard_hint else R.string.composer_unavailable, state.ring.name)
    val fieldLabel = stringResource(R.string.composer_message_label)
    ComposerSurface {
        BarIconButton(
            BridgeyIcons.AttachFile,
            stringResource(R.string.composer_attach),
            actions.sendFile,
            size = 48.dp,
            enabled = BridgeyFeature.FILES in state.available,
        )
        Box(Modifier.weight(1f).padding(horizontal = 4.dp)) {
            Column {
                Text(
                    stringResource(if (text.isEmpty()) R.string.composer_clipboard_label else R.string.composer_message_label),
                    style = BridgeyType.tinyLabel,
                    color = colors.onSurfaceVariant,
                )
                Box {
                    if (text.isEmpty()) {
                        Text(
                            hint,
                            style = BridgeyType.field,
                            color = colors.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    BasicTextField(
                        value = text,
                        onValueChange = { text = it.take(32_000) },
                        enabled = canSend,
                        singleLine = true,
                        textStyle = BridgeyType.field.copy(color = colors.onSurface),
                        cursorBrush = SolidColor(colors.primary),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                        keyboardActions = KeyboardActions(onSend = { if (canSend) send() }),
                        modifier = Modifier.fillMaxWidth().semantics { contentDescription = "$fieldLabel. $hint" },
                    )
                }
            }
        }
        GradientCircleButton(
            BridgeyIcons.Send,
            stringResource(if (text.isBlank()) R.string.composer_send_clipboard else R.string.composer_send_message),
            onClick = send,
            enabled = canSend,
        )
        Spacer(Modifier.size(0.dp))
    }
}
