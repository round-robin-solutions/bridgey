package dev.bridgey.android.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.selectionPop
import dev.bridgey.android.ui.motion.springIn
import dev.bridgey.android.ui.motion.tabContentTransform
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.OnBand
import dev.bridgey.android.ui.theme.ScreenBackdrop
import java.util.TimeZone

data class HomeState(
    val rings: List<DeviceRing>,
    val target: DeviceRing?,
    val activity: List<ActivityItem>,
    val live: List<LiveCard>,
    /** Clipboard can be sent to the target right now. */
    val canSendClipboard: Boolean,
    val now: Long,
    /** "Look for devices again" is running. */
    val rediscovering: Boolean = false,
    /** Files can go to the target: the attach button opens the attach sheet. */
    val canAttach: Boolean = false,
)

class HomeActions(
    val openSettings: () -> Unit = {},
    val selectRing: (DeviceRing) -> Unit = {},
    val openDevice: (DeviceRing) -> Unit = {},
    val pairRing: (DeviceRing) -> Unit = {},
    val addDevice: () -> Unit = {},
    val pickTarget: (String) -> Unit = {},
    val sendClipboard: () -> Unit = {},
    /** Opens the attach sheet (photos, documents, folders) for the target. */
    val attach: () -> Unit = {},
    /** Restarts discovery, announces this phone again and retries every paired device now. */
    val lookForDevices: () -> Unit = {},
    val live: LiveActions = LiveActions(),
)

/** Light mode band: status bar + 64 dp app bar + 112 dp rings + 16 dp. */
private val HomeBand = 192.dp

/**
 * Home: device rings, then what moved between them, newest first. The one main action is
 * Send clipboard in the send bar, aimed at the device on its left.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(state: HomeState, actions: HomeActions, snackbar: SnackbarHostState, deviceName: (ActivityItem) -> String) {
    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val navBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    var filter by rememberSaveable { mutableStateOf(StreamFilter.ALL) }
    ScreenBackdrop(bandHeight = statusTop + HomeBand) {
        Column(Modifier.fillMaxSize()) {
            OnBand {
                Column(Modifier.statusBarsPadding()) {
                    HomeAppBar(actions.openSettings, actions.lookForDevices, state.rediscovering)
                    RingStrip(state, actions)
                }
            }
            FilterChips(filter, onFilter = { filter = it }, modifier = Modifier.padding(top = 28.dp))
            val motion = LocalMotion.current
            AnimatedContent(
                targetState = filter,
                transitionSpec = { motion.tabContentTransform(forward = targetState.ordinal > initialState.ordinal) },
                label = "streamFilter",
                modifier = Modifier.weight(1f),
            ) { shownFilter ->
                val rows = remember(state.activity, shownFilter, state.now) {
                    streamRows(state.activity, shownFilter, null, state.now, TimeZone.getDefault())
                }
                // Pull down on the stream: look for devices again.
                PullToRefreshBox(
                    isRefreshing = state.rediscovering,
                    onRefresh = actions.lookForDevices,
                    modifier = Modifier.fillMaxSize(),
                ) {
                    StreamList(
                        rows = rows,
                        live = if (shownFilter == StreamFilter.ALL || shownFilter == StreamFilter.FILES) {
                            state.live.filter { shownFilter == StreamFilter.ALL || it is LiveCard.Transfer }
                        } else {
                            emptyList()
                        },
                        liveActions = actions.live,
                        deviceName = deviceName,
                        now = state.now,
                        state = rememberLazyListState(),
                        contentPadding = PaddingValues(bottom = 64.dp + 12.dp + navBottom + 24.dp),
                        empty = {
                            if (shownFilter == StreamFilter.ALL) {
                                StreamEmpty(stringResource(R.string.stream_empty_title), stringResource(if (state.rings.none { it.trusted }) R.string.stream_empty_unpaired else R.string.stream_empty_body))
                            } else {
                                StreamEmpty(stringResource(R.string.stream_empty_filter_title), stringResource(R.string.stream_empty_filter_body))
                            }
                        },
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }
        }
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding().padding(bottom = 12.dp)) {
            SnackbarHost(snackbar, Modifier.padding(horizontal = 16.dp)) { data ->
                Snackbar(data, Modifier.springIn(), containerColor = BridgeyTheme.colors.onSurface, contentColor = BridgeyTheme.colors.background, shape = RoundedCornerShape(16.dp))
            }
            HomeComposer(state, actions)
        }
    }
}

@Composable
private fun HomeAppBar(openSettings: () -> Unit, lookForDevices: () -> Unit, rediscovering: Boolean) {
    val colors = BridgeyTheme.colors
    Row(
        Modifier.fillMaxWidth().height(64.dp).padding(start = 20.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            Modifier.weight(1f).semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Image(painterResource(R.drawable.ic_app_mark), contentDescription = null, modifier = Modifier.size(30.dp))
            Column {
                Text(stringResource(R.string.brand_name), style = BridgeyType.brand, color = colors.onSurface)
                Text(stringResource(R.string.brand_by), style = BridgeyType.brandSub, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = 3.dp))
            }
        }
        BarIconButton(BridgeyIcons.Refresh, stringResource(R.string.look_again), lookForDevices, enabled = !rediscovering)
        BarIconButton(BridgeyIcons.Settings, stringResource(R.string.settings_title), openSettings)
    }
}

/** Device rings: 92 dp columns, centred, scrolling sideways after five. */
@Composable
private fun RingStrip(state: HomeState, actions: HomeActions) {
    LazyRow(
        Modifier.fillMaxWidth().height(112.dp),
        contentPadding = PaddingValues(start = 10.dp, end = 10.dp, top = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
    ) {
        itemsIndexed(state.rings, key = { _, ring -> ring.key }) { _, ring ->
            val selected = ring.trusted && ring.deviceId != null && ring.deviceId == state.target?.deviceId
            RingItem(ring, selected, actions)
        }
        item(key = "add") { AddRing(actions.addDevice) }
    }
}

@Composable
private fun RingItem(ring: DeviceRing, selected: Boolean, actions: HomeActions) {
    val colors = BridgeyTheme.colors
    val openLabel = stringResource(R.string.ring_open_device)
    val pairLabel = stringResource(R.string.ring_pair_action)
    val selectLabel = stringResource(R.string.ring_select_action)
    val status = if (ring.trusted) ringStatusLabel(ring) else stringResource(R.string.ring_new)
    Column(
        Modifier
            .width(92.dp)
            .clip(RoundedCornerShape(16.dp))
            .then(
                if (ring.trusted) {
                    Modifier.selectable(selected = selected, role = Role.Tab, onClick = {
                        if (selected) actions.openDevice(ring) else actions.selectRing(ring)
                    })
                } else {
                    Modifier.clickable(onClickLabel = pairLabel, role = Role.Button) { actions.pairRing(ring) }
                },
            )
            .semantics(mergeDescendants = true) {
                contentDescription = "${ring.name}, $status"
                if (ring.trusted) {
                    stateDescription = if (selected) openLabel else selectLabel
                    customActions = listOf(CustomAccessibilityAction(openLabel) { actions.openDevice(ring); true })
                }
            },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        DeviceGlyph(ring.state.style(), deviceIcon(ring.platform), 60.dp, Modifier.padding(top = 6.dp).selectionPop(selected), selected = selected)
        Text(
            ring.name,
            style = BridgeyType.smallStrong,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            color = colors.onSurface,
            modifier = Modifier.padding(top = 8.dp),
        )
        Text(
            status,
            style = BridgeyType.tiny,
            color = if (ring.trusted) ringStateColor(ring.state) else colors.onTintBlue,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 2.dp),
        )
    }
}

@Composable
private fun AddRing(onAdd: () -> Unit) {
    val colors = BridgeyTheme.colors
    Column(
        Modifier
            .width(92.dp)
            .clip(RoundedCornerShape(16.dp))
            .clickable(onClickLabel = stringResource(R.string.ring_add_description), role = Role.Button, onClick = onAdd),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        DeviceGlyph(RingStyle.ADD, BridgeyIcons.Add, 60.dp, Modifier.padding(top = 6.dp))
        Text(stringResource(R.string.ring_add), style = BridgeyType.smallStrong, color = colors.onSurface, modifier = Modifier.padding(top = 8.dp))
        Text(stringResource(R.string.ring_pair), style = BridgeyType.tiny, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = 2.dp))
    }
}

@Composable
private fun FilterChips(filter: StreamFilter, onFilter: (StreamFilter) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        StreamFilter.entries.forEach { chip ->
            FilterChip(
                label = stringResource(
                    when (chip) {
                        StreamFilter.ALL -> R.string.filter_all
                        StreamFilter.CLIPBOARD -> R.string.filter_clipboard
                        StreamFilter.FILES -> R.string.filter_files
                        StreamFilter.ALERTS -> R.string.filter_alerts
                        StreamFilter.CALLS -> R.string.filter_calls
                    },
                ),
                selected = chip == filter,
                onClick = { onFilter(chip) },
            )
        }
    }
}

@Composable
private fun FilterChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = BridgeyTheme.colors
    // 32 dp drawn, 48 dp to touch.
    Box(
        Modifier
            .heightIn(min = 48.dp)
            .selectable(selected = selected, role = Role.Tab, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            Modifier
                .height(32.dp)
                .clip(RoundedCornerShape(10.dp))
                .then(if (selected) Modifier.background(colors.tintBlue) else Modifier.border(1.dp, colors.outline, RoundedCornerShape(10.dp)))
                .padding(horizontal = 11.dp)
                .selectionPop(selected),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            if (selected) Icon(BridgeyIcons.Check, null, tint = colors.onTintBlue, modifier = Modifier.size(16.dp))
            Text(label, style = BridgeyType.chip, color = if (selected) colors.onSurface else colors.onSurfaceVariant, maxLines = 1)
        }
    }
}

/** The send bar: who it sends to on the left, Send clipboard on the right. */
@Composable
private fun HomeComposer(state: HomeState, actions: HomeActions) {
    val colors = BridgeyTheme.colors
    var picking by remember { mutableStateOf(false) }
    val target = state.target
    ComposerSurface {
        BarIconButton(BridgeyIcons.AttachFile, stringResource(R.string.composer_attach), actions.attach, size = 48.dp, enabled = state.canAttach)
        Box(Modifier.weight(1f)) {
            Row(
                Modifier
                    .widthIn(max = 220.dp)
                    .height(48.dp)
                    .clip(RoundedCornerShape(24.dp))
                    .clickable(enabled = state.rings.count { it.trusted } > 0, onClickLabel = stringResource(R.string.composer_pick_device), role = Role.Button) { picking = true }
                    .padding(horizontal = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (target != null) {
                    DeviceGlyph(target.state.style(), deviceIcon(target.platform), 36.dp, iconSize = 16.dp)
                } else {
                    DeviceGlyph(RingStyle.OFFLINE, BridgeyIcons.LaptopMac, 36.dp, iconSize = 16.dp)
                }
                Column(Modifier.weight(1f, fill = false)) {
                    Text(stringResource(R.string.composer_send_to), style = BridgeyType.tinyLabel, color = colors.onSurfaceVariant)
                    Text(
                        target?.name ?: stringResource(R.string.composer_no_device),
                        style = BridgeyType.label,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Icon(BridgeyIcons.ArrowDropDown, null, tint = colors.onSurfaceVariant, modifier = Modifier.size(20.dp))
            }
            DropdownMenu(
                expanded = picking,
                onDismissRequest = { picking = false },
                modifier = Modifier.springIn(),
                containerColor = colors.surface2,
                shape = RoundedCornerShape(20.dp),
            ) {
                state.rings.filter { it.trusted && it.deviceId != null }.forEach { ring ->
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(ring.name, style = BridgeyType.label, color = colors.onSurface)
                                Text(ringStatusLabel(ring), style = BridgeyType.small, color = ringStateColor(ring.state))
                            }
                        },
                        leadingIcon = { DeviceGlyph(ring.state.style(), deviceIcon(ring.platform), 36.dp, iconSize = 16.dp) },
                        trailingIcon = if (ring.deviceId == target?.deviceId) ({ Icon(BridgeyIcons.Check, null, tint = colors.primary) }) else null,
                        onClick = {
                            picking = false
                            actions.pickTarget(ring.deviceId!!)
                        },
                        modifier = Modifier.heightIn(min = 56.dp),
                    )
                }
            }
        }
        GradientButton(
            text = stringResource(R.string.composer_send_clipboard),
            icon = BridgeyIcons.ContentPaste,
            onClick = actions.sendClipboard,
            enabled = state.canSendClipboard,
            height = 48.dp,
            textStyle = BridgeyType.label,
            contentPadding = PaddingValues(horizontal = 16.dp),
        )
    }
}

/** The floating bar both composers sit in: 64 dp, fully rounded, 16 dp from the edges. */
@Composable
fun ComposerSurface(content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit) {
    val colors = BridgeyTheme.colors
    Row(
        Modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .height(64.dp)
            .shadow(if (colors.isDark) 16.dp else 8.dp, RoundedCornerShape(32.dp), ambientColor = Color.Black.copy(alpha = if (colors.isDark) 1f else 0.2f), spotColor = Color.Black.copy(alpha = if (colors.isDark) 0.5f else 0.2f))
            .clip(RoundedCornerShape(32.dp))
            .background(colors.composer)
            .then(if (colors.isDark) Modifier else Modifier.border(1.dp, colors.composerOutline, RoundedCornerShape(32.dp)))
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        content = content,
    )
}
