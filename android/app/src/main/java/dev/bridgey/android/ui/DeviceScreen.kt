package dev.bridgey.android.ui

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
    val activity: List<ActivityItem>,
    val live: List<LiveCard>,
    val now: Long,
)

class DeviceActions(
    val back: () -> Unit = {},
    val forget: () -> Unit = {},
    val sendFile: () -> Unit = {},
    val sendLink: () -> Unit = {},
    val ping: () -> Unit = {},
    val find: () -> Unit = {},
    val stopFind: () -> Unit = {},
    val setPermission: (List<BridgeyFeature>, Boolean) -> Unit = { _, _ -> },
    val notificationAccess: () -> Unit = {},
    val sendClipboard: () -> Unit = {},
    val sendText: (String) -> Unit = {},
    val live: LiveActions = LiveActions(),
)

/** Light mode band: status bar + 56 dp bar + 88 dp header + 16 dp. */
private val DeviceBand = 160.dp

enum class DeviceTab { ACTIVITY, PERMISSIONS }

/**
 * Device: who it is and how it is connected, four quick actions as one button group, then its
 * Activity (this device's part of the stream) and Permissions. The send bar stays, aimed here.
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
                RoutePill(state.ring.state)
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
                        Text("${battery.level}%", style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
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
    Row(modifier.fillMaxWidth().padding(horizontal = 16.dp).height(48.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        items.forEachIndexed { index, item ->
            val shape = when (index) {
                0 -> RoundedCornerShape(topStart = 24.dp, bottomStart = 24.dp, topEnd = 6.dp, bottomEnd = 6.dp)
                items.lastIndex -> RoundedCornerShape(topStart = 6.dp, bottomStart = 6.dp, topEnd = 24.dp, bottomEnd = 24.dp)
                else -> RoundedCornerShape(6.dp)
            }
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
                Text(item.label, style = BridgeyType.label, color = colors.onSurface.copy(alpha = alpha), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun DeviceTabs(tab: DeviceTab, onTab: (DeviceTab) -> Unit, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    Box(modifier.fillMaxWidth().height(48.dp)) {
        Row(Modifier.fillMaxSize().padding(horizontal = 8.dp)) {
            DeviceTab.entries.forEach { entry ->
                val selected = entry == tab
                Box(
                    Modifier.weight(1f).fillMaxSize().selectable(selected = selected, role = Role.Tab) { onTab(entry) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        stringResource(if (entry == DeviceTab.ACTIVITY) R.string.device_tab_activity else R.string.device_tab_permissions),
                        style = BridgeyType.label,
                        color = if (selected) colors.onSurface else colors.onSurfaceVariant,
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

@Composable
private fun PermissionsList(state: DeviceState, actions: DeviceActions, contentPadding: PaddingValues) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = contentPadding) {
        item(key = "intro") {
            Note(stringResource(R.string.device_permissions_intro, state.ring.name), Modifier.padding(start = 20.dp, end = 20.dp, top = 16.dp))
        }
        item(key = "group") {
            RowGroup(Modifier.padding(top = 12.dp)) {
                state.permissions.forEach { permission ->
                    row { shape ->
                        val feature = permission.features.first()
                        val (icon, tint) = permissionVisual(feature)
                        val needsAccess = feature == BridgeyFeature.NOTIFICATIONS && !state.notificationAccess && permission.checked
                        val detail = when {
                            permission.globallyOff -> stringResource(R.string.permission_off_everywhere)
                            permission.remotelyOff -> stringResource(R.string.permission_off_remote, state.ring.name)
                            needsAccess -> stringResource(R.string.permission_needs_notification_access)
                            else -> permissionDetail(feature, state)
                        }
                        if (needsAccess) {
                            ListRow(
                                shape = shape,
                                title = permissionTitle(feature),
                                detail = detail,
                                icon = icon,
                                tint = tint,
                                compact = true,
                                detailWarning = true,
                                onClick = actions.notificationAccess,
                                onClickLabel = stringResource(R.string.action_enable),
                            ) {
                                BridgeySwitch(checked = true, onCheckedChange = { actions.setPermission(permission.features, it) })
                            }
                        } else {
                            SwitchRow(
                                shape = shape,
                                title = permissionTitle(feature),
                                detail = detail,
                                icon = icon,
                                tint = if (permission.checked && !permission.globallyOff && !permission.remotelyOff) tint else Tint.NEUTRAL,
                                checked = permission.checked && !permission.globallyOff && !permission.remotelyOff,
                                onCheckedChange = { actions.setPermission(permission.features, it) },
                                // Off on the other device: shown off, as there is nothing to switch on here.
                                enabled = !permission.globallyOff && !permission.remotelyOff,
                                compact = true,
                                detailWarning = permission.remotelyOff || permission.globallyOff,
                            )
                        }
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
    },
)

@Composable
private fun permissionDetail(feature: BridgeyFeature, state: DeviceState): String = when (feature) {
    BridgeyFeature.CLIPBOARD -> stringResource(R.string.feature_clipboard_detail)
    BridgeyFeature.FILES -> stringResource(R.string.feature_files_detail)
    BridgeyFeature.NOTIFICATIONS -> if (state.notificationAppsEnabled > 0) {
        androidx.compose.ui.res.pluralStringResource(R.plurals.feature_notifications_detail, state.notificationAppsEnabled, state.notificationAppsEnabled, state.ring.name)
    } else {
        stringResource(R.string.feature_notifications_detail_none)
    }
    BridgeyFeature.CALLS -> stringResource(R.string.feature_calls_detail, state.ring.name)
    BridgeyFeature.MEDIA -> stringResource(R.string.feature_media_detail, state.ring.name)
    BridgeyFeature.FIND_DEVICE, BridgeyFeature.PING -> stringResource(R.string.feature_find_ping_detail, state.ring.name)
    BridgeyFeature.LINKS -> stringResource(R.string.feature_links_detail)
    BridgeyFeature.BATTERY -> stringResource(R.string.feature_battery_detail, state.ring.name)
}

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
